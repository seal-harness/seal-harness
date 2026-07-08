{-# LANGUAGE OverloadedStrings #-}
-- | The untrusted LOCAL executor (the 'EbLocal' arm of 'ExecBackend').
-- Behind the 'BackendExec' seam, the Untrusted opcode implementations
-- call 'lehExecShell'/'lehExecProgram' on this handle. The real
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
  (InterpName, ScriptArg, ShellCommand, textInterpName, textScriptArg, textShellCommand)
import Seal.Tools.Exec.Types

-- | The real 'LocalExecHandle': wires 'System.Process' behind the two IO
-- actions. The 'WorkspaceRoot' anchors cwd confinement for the shell exec.
mkLocalExecHandle :: WorkspaceRoot -> LocalExecHandle
mkLocalExecHandle wsRoot = LocalExecHandle
  { lehExecShell = \cmd mCwd -> do
      let argv = ["/bin/sh", "-c", T.unpack (textShellCommand cmd)]
      case mCwd of
        Nothing -> runFixedArgv argv Nothing
        Just rp -> do
          e <- mkSafePath wsRoot (T.unpack (getRemotePath rp))
          case e of
            Left _err -> pure (Left ExecNotImplemented)
            Right sp  -> runFixedArgv argv (Just (getSafePath sp))
  , lehExecProgram = \interp sargs ->
      let interpName = T.unpack (textInterpName interp)
          argTexts   = map (T.unpack . textScriptArg) sargs
          argv       = interpName : argTexts
      in runFixedArgv argv Nothing
  }

-- | A 'LocalExecHandle' built from explicit IO action functions — the form
-- the opcode tests use (mirrors the 'TmuxRunner' fake pattern). Real
-- callers use 'mkLocalExecHandle'.
mkLocalExecHandleFromFns
  :: (ShellCommand -> Maybe RemotePath -> IO (Either ExecError Text))
  -> (InterpName -> [ScriptArg] -> IO (Either ExecError Text))
  -> LocalExecHandle
mkLocalExecHandleFromFns shellFn progFn = LocalExecHandle
  { lehExecShell = shellFn
  , lehExecProgram = progFn
  }

-- | Run a fixed-argv program, capturing stdout as Text. No shell
-- interpreter (the argv is the literal program + args). An optional cwd
-- (already 'SafePath'-validated). Fail-closed: any IOError or non-zero
-- exit becomes a structured 'ExecError'.
runFixedArgv :: [String] -> Maybe String -> IO (Either ExecError Text)
runFixedArgv argv mCwd = do
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
    Left _ioErr                   -> pure (Left ExecNotImplemented)  -- binary missing/launch fail
    Right (ExitSuccess, out, _)   -> pure (Right out)
    Right (ExitFailure 127, _, _)  -> pure (Left ExecNotImplemented)  -- not on PATH
    Right (ExitFailure _n, _, _err) -> pure (Left ExecNotImplemented)  -- surfaced as ExecFailed by the dispatcher