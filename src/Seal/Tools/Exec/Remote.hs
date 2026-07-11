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
  , RemoteRunner (..)
  , mkRealRemoteRunner
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

-- | The SSH runner seam — a function that takes the argv and returns the
-- result. The real implementation uses 'System.Process'; tests supply a
-- fake that simulates unreachable / host-key-mismatch.
newtype RemoteRunner = RemoteRunner
  { runRemote :: [String] -> IO (Either ExecError Text) }

-- | The real SSH runner via 'System.Process'. Fail-closed: any IOError or
-- non-zero exit becomes a structured 'ExecError'. Exit code 255 with a
-- "Host key verification failed" stderr → 'ExecHostKeyMismatch' (hard
-- failure, never bypassed).
mkRealRemoteRunner :: RemoteRunner
mkRealRemoteRunner = RemoteRunner runReal
  where
    runReal argv = do
      let (program, args) = case argv of
            (p : as) -> (p, as)
            []       -> error "runReal: empty argv (unreachable)"
          cp = (proc program args)
                 { std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe }
      res <- try @IOError
             (withCreateProcess cp $ \_ mOut mErr ph -> do
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