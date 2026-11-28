{-# LANGUAGE OverloadedStrings #-}
-- | The untrusted LOCAL executor (the 'EbLocal' arm of 'ExecBackend').
-- Behind the 'BackendExec' seam, the Untrusted opcode implementations
-- call 'lehExecShell'/'lehExecBin' on this handle. The real
-- implementation uses 'System.Process' (mirrors
-- 'Seal.Harness.Tmux.readTmuxNoInput': fixed argv, no shell interpreter
-- for the program path; @/bin/sh -c@ ONLY for 'SHELL_EXEC' with a validated
-- 'ShellCommand'). 'SafePath' cwd confinement: the cwd is the workspace
-- root; @..@/absolute rejected at the call site.
--
-- This module imports the 'LocalExecHandle' TYPE+CONSTRUCTOR from
-- 'Seal.Tools.Exec.Types' (Haskell requires them co-located) and provides
-- the smart constructor 'mkLocalExecHandle' that wires the real
-- 'System.Process'-backed IO actions.
--
-- = Process-group killing + bounded output (Task 3 + Task 4)
--
-- 'runFixedArgv' uses 'withManagedProcess' instead of 'withCreateProcess'.
-- 'withManagedProcess' spawns the child with @create_group = True@ (so the
-- child is in its own POSIX process group), and on cleanup kills the whole
-- group: SIGTERM → grace period → SIGKILL. This ensures that when the
-- dispatch wrapper ('Seal.Tools.Exec.Timeout.runWithTimeoutAbortRetry')
-- cancels the Haskell worker thread (via 'async'\'s 'cancel'), the bracket
-- cleanup runs and kills the OS process group — no orphans. The zombie reap
-- is bounded (a non-blocking 'getProcessExitCode' poll with a 1s deadline)
-- so cleanup never hangs. Output capture is bounded via 'readBounded'
-- (default 50KB) with a truncation marker.
module Seal.Tools.Exec.Local
  ( mkLocalExecHandle
  , mkLocalExecHandleFromFns
  , LocalExecHandle (..)
  , withManagedProcess
  , killProcessGroup
  , readBounded
  , readBoundedBytes
  ) where

import Control.Exception (try)
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import System.Process
  ( CreateProcess (..), StdStream (..), proc, waitForProcess )

import Seal.Security.Path (WorkspaceRoot (..), mkSafePath, getSafePath)
import Seal.Tools.Args
  (BinName, BinArg, ShellCommand, textBinName, textBinArg, textShellCommand)
import Seal.Tools.Exec.Types
import Seal.Tools.Exec.Proc
  ( killProcessGroup, readBounded, readBoundedBytes, withManagedProcess )

-- | The default bounded-output cap (50KB). Matches
-- 'Seal.Tools.Timeout.ttcMaxOutputBytes'.
defaultMaxOutputBytes :: Int
defaultMaxOutputBytes = 50_000

-- ('defaultKillGraceMicros' lives in "Seal.Tools.Exec.Proc" with the
-- process-group helpers it belongs to.)

-- | The real 'LocalExecHandle': wires 'System.Process' behind the two IO
-- actions. The 'WorkspaceRoot' anchors cwd confinement for the shell exec.
mkLocalExecHandle :: WorkspaceRoot -> LocalExecHandle
mkLocalExecHandle wsRoot = LocalExecHandle
  { lehExecShell = \cmd mCwd -> do
      let argv = ["/bin/sh", "-c", T.unpack (textShellCommand cmd)]
      case mCwd of
        Nothing -> runShell argv Nothing
        Just rp -> do
          e <- mkSafePath wsRoot (T.unpack (getRemotePath rp))
          case e of
            Left _err -> pure (Left ExecNotImplemented)
            Right sp  -> runShell argv (Just (getSafePath sp))
  , lehExecBin = \bin bargs mCwd ->
      let binName  = T.unpack (textBinName bin)
          argTexts = map (T.unpack . textBinArg) bargs
          argv     = binName : argTexts
      in case mCwd of
           Nothing  -> runProgram argv Nothing
           Just rp  -> do
             e <- mkSafePath wsRoot (T.unpack (getRemotePath rp))
             case e of
               Left _err -> pure (Left ExecNotImplemented)
               Right sp  -> runProgram argv (Just (getSafePath sp))
  }

-- | A 'LocalExecHandle' built from explicit IO action functions — the form
-- the opcode tests use (mirrors the 'TmuxRunner' fake pattern). Real
-- callers use 'mkLocalExecHandle'.
mkLocalExecHandleFromFns
  :: (ShellCommand -> Maybe RemotePath -> IO (Either ExecError Text))
  -> (BinName -> [BinArg] -> Maybe RemotePath -> IO (Either ExecError Text))
  -> LocalExecHandle
mkLocalExecHandleFromFns shellFn binFn = LocalExecHandle
  { lehExecShell = shellFn
  , lehExecBin = binFn
  }

-- | Run a shell command via @/bin/sh -c@. The shell itself always launches
-- (it's at a fixed path), so a non-zero exit — including 127 ("command not
-- found" inside the shell) — is a normal command failure, returned via
-- 'Right' with the output + exit code annotation. Only an IOError (the shell
-- binary itself couldn't launch) becomes 'Left ExecNotImplemented'.
runShell :: [String] -> Maybe String -> IO (Either ExecError Text)
runShell = runFixedArgv False

-- | Run a named binary (resolved on PATH or by path). A 127 exit
-- here means the binary itself is not on PATH, so it's mapped to
-- 'Left ExecNotImplemented' (the executor is not available). Other non-zero
-- exits are normal failures, returned via 'Right' with the output + exit code.
runProgram :: [String] -> Maybe String -> IO (Either ExecError Text)
runProgram = runFixedArgv True

-- | Run a fixed-argv program, capturing stdout and stderr as Text. An optional
-- cwd (already 'SafePath'-validated). When @treat127AsMissing@ is True, a 127
-- exit is mapped to 'Left ExecNotImplemented' (the binary is not on PATH).
-- Otherwise (shell mode), 127 is a normal command-not-found failure, returned
-- via 'Right' with the exit code annotation. Any IOError becomes 'Left
-- ExecNotImplemented'.
--
-- Uses 'withManagedProcess' (process-group spawning + kill-on-cleanup) and
-- 'readBounded' (bounded output capture, default 50KB).
runFixedArgv :: Bool -> [String] -> Maybe String -> IO (Either ExecError Text)
runFixedArgv treat127AsMissing argv mCwd = do
  let (program, args) = case argv of
        (p : as) -> (p, as)
        []       -> error "runFixedArgv: empty argv (unreachable)"
      cp = (proc program args)
             { std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe
             , cwd = mCwd
             , create_group = True
             }
      -- ^ @create_group = True@ puts the child in its own POSIX process
      -- group so 'withManagedProcess' can kill the whole group on cleanup
      -- (SIGTERM → grace → SIGKILL). This prevents orphans when the
      -- dispatch wrapper cancels the Haskell worker thread.
  res <- try @IOError
         (withManagedProcess cp $ \ph _mIn hOut hErr -> do
            out <- readBounded hOut defaultMaxOutputBytes
            err <- readBounded hErr defaultMaxOutputBytes
            ec  <- waitForProcess ph
            pure (ec, out, err))
  case res of
    Left _ioErr                     -> pure (Left ExecNotImplemented)  -- binary missing/launch fail
    Right (ExitSuccess, out, _)     -> pure (Right out)
    Right (ExitFailure 127, _, _)
      | treat127AsMissing            -> pure (Left ExecNotImplemented)  -- binary not on PATH
    Right (ExitFailure n, out, err)  -> pure (Right (formatExitResult n out err))

-- | Subprocess primitives — re-exported from "Seal.Tools.Exec.Proc".
--
-- They live there rather than here because @-f remote-only-untrusted@ removes
-- THIS module from @exposed-modules@, and the remote arm, the remote
-- 'UntrustedIO' arm and the agent-metadata cache all need them to drive
-- their own local child processes (@ssh@, @rsync@). Importing them from here
-- made the hardened build fail to link. Re-exported so existing callers keep
-- working; new code should import "Seal.Tools.Exec.Proc" directly.
