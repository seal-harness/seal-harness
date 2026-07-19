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
module Seal.Tools.Exec.Local
  ( mkLocalExecHandle
  , mkLocalExecHandleFromFns
  , LocalExecHandle (..)
  ) where

import Control.Exception (try)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Exit (ExitCode (..))
import System.Process
  ( CreateProcess (..), StdStream (..), proc, waitForProcess, withCreateProcess
  )

import Seal.Security.Path (WorkspaceRoot (..), mkSafePath, getSafePath)
import Seal.Tools.Args
  (BinName, BinArg, ShellCommand, textBinName, textBinArg, textShellCommand)
import Seal.Tools.Exec.Types

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
  , lehExecBin = \bin bargs ->
      let binName  = T.unpack (textBinName bin)
          argTexts = map (T.unpack . textBinArg) bargs
          argv     = binName : argTexts
      in runProgram argv Nothing
  }

-- | A 'LocalExecHandle' built from explicit IO action functions — the form
-- the opcode tests use (mirrors the 'TmuxRunner' fake pattern). Real
-- callers use 'mkLocalExecHandle'.
mkLocalExecHandleFromFns
  :: (ShellCommand -> Maybe RemotePath -> IO (Either ExecError Text))
  -> (BinName -> [BinArg] -> IO (Either ExecError Text))
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
runFixedArgv :: Bool -> [String] -> Maybe String -> IO (Either ExecError Text)
runFixedArgv treat127AsMissing argv mCwd = do
  let (program, args) = case argv of
        (p : as) -> (p, as)
        []       -> error "runFixedArgv: empty argv (unreachable)"
      cp = (proc program args)
             { std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe
             , cwd = mCwd
             }
      -- ^ The validated newtypes guarantee no shell metacharacters reach here.
  res <- try @IOError
         (withCreateProcess cp $ \_ mOut mErr ph -> do
            (hOut, hErr) <- case (mOut, mErr) of
              (Just a, Just b) -> pure (a, b)
              _                -> error "runFixedArgv: pipe creation failed (unreachable)"
            out <- TE.decodeUtf8 <$> BS.hGetContents hOut
            err <- TE.decodeUtf8 <$> BS.hGetContents hErr
            ec  <- waitForProcess ph
            pure (ec, out, err))
  case res of
    Left _ioErr                     -> pure (Left ExecNotImplemented)  -- binary missing/launch fail
    Right (ExitSuccess, out, _)     -> pure (Right out)
    Right (ExitFailure 127, _, _)
      | treat127AsMissing            -> pure (Left ExecNotImplemented)  -- binary not on PATH
    Right (ExitFailure n, out, err)  -> pure (Right (formatExitResult n out err))

-- | Format a non-zero exit result for the tool-call consumer. Combines stdout
-- and stderr (if non-empty) and annotates the exit code so the frontend can
-- surface it. The result is returned via 'Right' (not an 'ExecError') so the
-- dispatcher records @is_error = False@ — the command ran successfully, it just
-- returned a non-zero exit code. The frontend treats the exit code annotation
-- as the success/failure signal.
formatExitResult :: Int -> Text -> Text -> Text
formatExitResult n out err =
  let parts = [ t | t <- [out, err], not (T.null (T.strip t)) ]
      body  = if null parts then "" else T.intercalate "\n" parts
  in body <> "\n[exit code: " <> T.pack (show n) <> "]"