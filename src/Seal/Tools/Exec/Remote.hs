{-# LANGUAGE OverloadedStrings #-}
-- | The remote SSH executor (the 'EbRemote' arm of 'ExecBackend'). Shells
-- out to the system @ssh@ binary via fixed argv (no shell interpreter)
-- with **mandatory host-key pinning**: @StrictHostKeyChecking=yes@ and a
-- pinned @UserKnownHostsFile@. A host-key mismatch is a hard security
-- failure ('ExecHostKeyMismatch'), never bypassed. Batch mode
-- (@BatchMode=yes@) prevents interactive prompts (a headless run cannot
-- confirm a new host key, so adoption fail-closes).
module Seal.Tools.Exec.Remote
  ( sshExecArgv
  , runRemoteShell
  , runRemoteWithStdin
  , RemoteRunner (..)
  , mkRealRemoteRunner
  , mkFakeRemoteRunner
  , mkFakeRemoteRunnerRecording
  ) where

import Control.Exception (try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Exit (ExitCode (..))
import System.IO (hClose)
import System.Process
  ( CreateProcess (..), StdStream (..), proc, waitForProcess, withCreateProcess
  )

import Seal.Tools.Args (ShellCommand, textShellCommand)
import Seal.Tools.Exec.Types

-- | Build the fixed argv for an SSH exec. The argv is:
--
-- @ssh -o StrictHostKeyChecking=yes -o BatchMode=yes -o
-- UserKnownHostsFile=\<pinned\> [-p \<port\>] [-i \<identity\>] user\@host
-- -- \<command\>@
--
-- The @--@ separator guards against option injection from the command
-- (the validated 'ShellCommand' is passed as a single arg, not
-- interpreted as ssh flags). No @-c@ shell interpreter — the command runs
-- as the remote user's default shell, but the command string is a single
-- argv element (ssh itself passes it to the remote shell, but the
-- *local* argv is fixed, no shell wrapping).
sshExecArgv :: SshConfig -> Text -> [String]
sshExecArgv cfg cmd =
  [ "ssh"
  , "-o", "StrictHostKeyChecking=yes"
  , "-o", "BatchMode=yes"
  , "-o", "UserKnownHostsFile=" <> scKnownHosts cfg
  ]
  <> portArg
  <> identityArg
  <> [ userAtHost
     , "--"
     , T.unpack cmd
     ]
  where
    userAtHost = T.unpack (getSshUser (scUser cfg)) <> "@"
                 <> T.unpack (getSshHost (scHost cfg))
    portArg = case scPort cfg of
      22 -> []
      p  -> ["-p", show p]
    identityArg = case scIdentity cfg of
      Nothing -> []
      Just f  -> ["-i", f]

-- | The SSH runner seam — a record of two IO actions:
--
--   * 'runRemote' runs an argv with no stdin (the existing path, used by
--     'runRemoteShell' and the command opcodes).
--   * 'runRemoteStdin' runs an argv with a stdin payload (used by the
--     remote 'UntrustedIO' arm for file writes — the content is piped
--     over the SSH channel, never interpolated into the command string).
--
-- The real implementation ('mkRealRemoteRunner') uses 'System.Process';
-- tests supply a fake (via 'mkFakeRemoteRunner' or
-- 'mkFakeRemoteRunnerRecording') that simulates unreachable /
-- host-key-mismatch / canned-stdout, and records the argv + stdin for
-- assertions.
data RemoteRunner = RemoteRunner
  { runRemote      :: [String] -> IO (Either ExecError Text)
  , runRemoteStdin :: [String] -> ByteString -> IO (Either ExecError Text)
  }

-- | The real SSH runner via 'System.Process'. Fail-closed: any IOError or
-- non-zero exit becomes a structured 'ExecError'. Exit code 255 with a
-- "Host key verification failed" stderr → 'ExecHostKeyMismatch' (hard
-- failure, never bypassed).
mkRealRemoteRunner :: RemoteRunner
mkRealRemoteRunner = RemoteRunner
  { runRemote      = runReal Nothing
  , runRemoteStdin = \argv stdinBytes -> runReal (Just stdinBytes) argv
  }
  where
    runReal :: Maybe ByteString -> [String] -> IO (Either ExecError Text)
    runReal mStdin argv = do
      let (program, args) = case argv of
            (p : as) -> (p, as)
            []       -> error "runReal: empty argv (unreachable)"
          cp0 = (proc program args)
                  { std_out = CreatePipe, std_err = CreatePipe }
          cp = case mStdin of
            Nothing -> cp0 { std_in = NoStream }
            Just _  -> cp0 { std_in = CreatePipe }
      res <- try @IOError
             (withCreateProcess cp $ \mIn mOut mErr ph -> do
                -- Pipe the stdin payload (if any) to the process and close
                -- the write end so the remote @cat@/@tee@ sees EOF.
                case (mIn, mStdin) of
                  (Just hIn, Just bs) -> do
                    BS.hPut hIn bs
                    hClose hIn
                  _ -> pure ()
                (hOut, hErr) <- case (mOut, mErr) of
                  (Just a, Just b) -> pure (a, b)
                  _                -> error "runReal: pipe creation failed (unreachable)"
                out <- TE.decodeUtf8 <$> BS.hGetContents hOut
                err <- TE.decodeUtf8 <$> BS.hGetContents hErr
                ec  <- waitForProcess ph
                pure (ec, out, err))
      case res of
        Left _ioErr -> pure (Left ExecRemoteUnreachable)  -- launch fail = unreachable
        Right (ExitSuccess, out, _) -> pure (Right out)
        Right (ExitFailure 255, _, err)
          | "Host key verification failed" `T.isInfixOf` err
          -> pure (Left ExecHostKeyMismatch)
          | otherwise
          -> pure (Left ExecRemoteUnreachable)
        Right (ExitFailure 127, _, _)  -> pure (Left ExecRemoteUnreachable)  -- ssh not on PATH
        Right (ExitFailure _n, _, _err) -> pure (Left ExecRemoteUnreachable)

-- | Run a shell command via the remote SSH executor. The command is a
-- validated 'ShellCommand' (NUL rejected). Returns the stdout or a
-- structured 'ExecError'.
runRemoteShell :: RemoteRunner -> SshConfig -> ShellCommand -> IO (Either ExecError Text)
runRemoteShell runner cfg cmd =
  let argv = sshExecArgv cfg (textShellCommand cmd)
  in runRemote runner argv

-- | Run a shell command via the remote SSH executor WITH a stdin payload.
-- The bytes are piped to the remote process's stdin — used by the remote
-- 'UntrustedIO' arm for file writes (the file content goes over the SSH
-- channel, never interpolated into the command string, so content with
-- quotes/backticks/@$()@ is safe). The argv is the same fixed
-- 'sshExecArgv' shape; the stdin is a runtime parameter.
runRemoteWithStdin
  :: RemoteRunner -> SshConfig -> ShellCommand -> ByteString
  -> IO (Either ExecError Text)
runRemoteWithStdin runner cfg cmd stdinBytes =
  let argv = sshExecArgv cfg (textShellCommand cmd)
  in runRemoteStdin runner argv stdinBytes

-- | A fake 'RemoteRunner' that always returns a canned result (the
-- 'Either' is supplied by the caller). The argv + stdin are ignored.
-- Useful for the unreachable / host-key-mismatch tests.
mkFakeRemoteRunner :: Either ExecError Text -> RemoteRunner
mkFakeRemoteRunner canned = RemoteRunner
  { runRemote      = \_argv -> pure canned
  , runRemoteStdin = \_argv _stdin -> pure canned
  }

-- | A fake 'RemoteRunner' that records every call's argv + stdin into an
-- 'IORef' (oldest-last) and returns a canned result. Used by the remote
-- 'UntrustedIO' tests to assert the SSH argv + piped content are correct
-- (file ops go through SSH, not the local FS). The recorded entry is
-- @(argv, mStdin)@ — 'Nothing' for the no-stdin path, @'Just' bytes@ for
-- the stdin path.
mkFakeRemoteRunnerRecording
  :: IORef [([String], Maybe ByteString)]
  -> Either ExecError Text
  -> RemoteRunner
mkFakeRemoteRunnerRecording ref canned = RemoteRunner
  { runRemote      = \argv -> do
      modifyIORef' ref (++ [(argv, Nothing)])
      pure canned
  , runRemoteStdin = \argv stdin -> do
      modifyIORef' ref (++ [(argv, Just stdin)])
      pure canned
  }