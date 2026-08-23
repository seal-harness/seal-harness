{-# LANGUAGE OverloadedStrings #-}
-- | The remote SSH executor (the 'EbRemote' arm of 'ExecBackend'). Shells
-- out to the system @ssh@ binary via fixed argv (no shell interpreter)
-- with **mandatory host-key pinning**: @StrictHostKeyChecking=yes@ and a
-- pinned @UserKnownHostsFile@. A host-key mismatch is a hard security
-- failure ('ExecHostKeyMismatch'), never bypassed. Batch mode
-- (@BatchMode=yes@) prevents interactive prompts (a headless run cannot
-- confirm a new host key, so adoption fail-closes).
--
-- == Connection multiplexing
--
-- Every invocation joins one of TWO DISJOINT @ControlMaster=auto@ pools,
-- keyed by the 'ControlPath' suffix:
--
--   * @m-%C@ — plain sessions (never @-A@): discovery snapshots, file
--     reads/writes, shell execs.
--   * @a-%C@ — agent-forwarding sessions only (the git-credential ops that
--     pass @-A@).
--
-- The split preserves the §5.6 opt-in invariant: agent forwarding over a
-- multiplexed connection requires the /master/ process to have been started
-- with @-A@, so a plain op can never ride an agent-forwarding master (and a
-- forwarding op never upgrades the shared plain pool). The first op to each
-- pool pays the TCP + key-exchange + auth handshake; every subsequent op for
-- ~10 minutes ('ControlPersist') rides the persistent master socket — turning
-- N serialized round trips from N handshakes into 1 + N fast channel opens.
--
-- Security posture is unchanged: the master itself was established under the
-- same pinning options (same argv shape ⇒ same config), @BatchMode=yes@
-- still forbids interactive prompts, and a stale socket (master killed) is
-- detected by @ControlMaster=auto@, which falls back to a fresh direct
-- connection. The socket directory is private (mode 0700) under @~/.seal/@.
module Seal.Tools.Exec.Remote
  ( sshExecArgv
  , sshExecArgvForwarding
  , runRemoteShell
  , runRemoteShellForwarding
  , runRemoteWithStdin
  , runRemoteWithStdinForwarding
  , RemoteRunner (..)
  , mkRealRemoteRunner
  , mkFakeRemoteRunner
  , mkFakeRemoteRunnerRecording
  ) where

import Control.Exception (try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (createDirectoryIfMissing, getHomeDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Files (setFileMode)
import System.Process
  ( CreateProcess (..), StdStream (..), proc, waitForProcess
  )

import Seal.Tools.Args (ShellCommand, textShellCommand)
import Seal.Tools.Exec.Local (readBounded, withManagedProcess)
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
--
-- Agent forwarding is OFF (no @-A@) — this is the default for all
-- non-credential ops (SHELL_EXEC, file writes, process ops). Git-credential
-- ops (clone/fetch/pull/push with a deploy key) use 'sshExecArgvForwarding'
-- to opt in to @-A@ so the forwarded @SSH_AUTH_SOCK@ reaches the remote
-- @git@. A blanket @-A@ would widen the signing-oracle surface; opt-in
-- per git-op is the security-critical invariant (design §5.6, W2 DoD).
sshExecArgv :: SshConfig -> Text -> [String]
sshExecArgv cfg cmd =
  [ "ssh"
  , "-o", "StrictHostKeyChecking=yes"
  , "-o", "BatchMode=yes"
  , "-o", "UserKnownHostsFile=" <> scKnownHosts cfg
  ]
  <> muxArgs "m"
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

-- | Variant of 'sshExecArgv' that adds @-A@ (forward the agent). Used by
-- git-credential ops (clone/fetch/pull/push with a deploy key) so the
-- remote @git@ can sign via the forwarded @SSH_AUTH_SOCK@. The @-A@ is
-- opt-in per git-op — non-credential remote ops use 'sshExecArgv' (no
-- @-A@) to keep the signing-oracle surface minimal (design §5.6).
--
-- The remote arm of 'uioShellExecGitEnv' (UntrustedIO.hs) uses this via
-- 'runRemoteShellForwarding' for deploy-key ops. The @SSH_AUTH_SOCK@ /
-- @SSH_AGENT_PID@ are stripped from the env prefix (the forwarded socket
-- replaces them) and the @known_hosts@ content is written to a remote
-- temp file so @GIT_SSH_COMMAND@'s @UserKnownHostsFile=@ resolves on the
-- remote machine. PAT ops work on both executors (token in argv, no
-- agent).
sshExecArgvForwarding :: SshConfig -> Text -> [String]
sshExecArgvForwarding cfg cmd =
  [ "ssh", "-A"
  , "-o", "StrictHostKeyChecking=yes"
  , "-o", "BatchMode=yes"
  , "-o", "UserKnownHostsFile=" <> scKnownHosts cfg
  ]
  <> muxArgs "a"
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

-- | The multiplexing options for one master pool. @pool@ is @\"m\"@ (plain)
-- or @\"a\"@ (agent-forwarding); the ControlPath suffix keeps the pools
-- disjoint. @%C@ is ssh's hash of |local host|local port|remote host|remote
-- port, so each target gets its own master even within one pool.
muxArgs :: String -> [String]
muxArgs pool =
  [ "-o", "ControlMaster=auto"
  , "-o", "ControlPath=" <> sshMuxBaseDir </> (pool <> "-%C")
  , "-o", "ControlPersist=600"
  ]

-- | The absolute mux socket directory, @~/.seal/ssh-mux@ (mode 0700),
-- created once at first use. An absolute path (not a @~@-form) so the argv
-- builder stays pure without relying on ssh's tilde expansion of @-o@
-- values; 'ensureMuxDir' re-ensures it before every spawn.
{-# NOINLINE sshMuxBaseDir #-}
sshMuxBaseDir :: FilePath
sshMuxBaseDir = unsafePerformIO $ do
  home <- getHomeDirectory
  let d = home </> ".seal" </> "ssh-mux"
  ensureMuxDirAt d
  pure d

-- | Idempotently create the mux socket directory with private permissions.
ensureMuxDirAt :: FilePath -> IO ()
ensureMuxDirAt d = do
  createDirectoryIfMissing True d
  setFileMode d 0o700

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
  , runRemoteEnv   :: [(String, String)] -> [String] -> IO (Either ExecError Text)
    -- ^ Run an argv with local env overrides MERGED over the inherited
    -- environment. Used by the deploy-key remote clone path: the local
    -- @ssh -A@ process needs the SEAL agent's @SSH_AUTH_SOCK@ (not the
    -- ambient one) so the forwarded agent has the deploy key loaded.
  }

-- | The real SSH runner via 'System.Process'. Fail-closed: any IOError or
-- non-zero exit becomes a structured 'ExecError'. Exit code 255 with a
-- "Host key verification failed" stderr → 'ExecHostKeyMismatch' (hard
-- failure, never bypassed).
mkRealRemoteRunner :: RemoteRunner
mkRealRemoteRunner = RemoteRunner
  { runRemote      = runReal Nothing []
  , runRemoteStdin = \argv stdinBytes -> runReal (Just stdinBytes) [] argv
  , runRemoteEnv   = runReal Nothing
  }
  where
    runReal :: Maybe ByteString -> [(String, String)] -> [String] -> IO (Either ExecError Text)
    runReal mStdin envExtras argv = do
      -- Re-ensure the mux socket dir before every spawn (guards against a
      -- mid-run deletion; ssh fatals if ControlPath is uncreatable).
      ensureMuxDirAt sshMuxBaseDir
      let (program, args) = case argv of
            (p : as) -> (p, as)
            []       -> error "runReal: empty argv (unreachable)"
          cp0 = (proc program args)
                  { std_out = CreatePipe, std_err = CreatePipe
                  , create_group = True
                  }
          -- ^ @create_group = True@ puts the ssh child in its own POSIX
          -- process group so 'withManagedProcess' can kill the whole group
          -- on cleanup (SIGTERM → grace → SIGKILL). Killing the local ssh
          -- process closes the SSH channel, which terminates the remote
          -- command (design Risks §2 — a backgrounded remote child via
          -- @setsid ... &@ survives, accepted v1 limitation).
          cp1 = case mStdin of
            Nothing -> cp0 { std_in = NoStream }
            Just _  -> cp0 { std_in = CreatePipe }
      mEnv <- case envExtras of
        [] -> pure Nothing
        xs -> Just <$> mergeEnvReal xs
      let cp = cp1 { env = mEnv }
          maxOutput = 50_000  -- bounded output cap (Task 4)
      res <- try @IOError
             (withManagedProcess cp $ \ph mIn hOut hErr -> do
                -- Pipe the stdin payload (if any) to the process and close
                -- the write end so the remote @cat@/@tee@ sees EOF.
                case (mIn, mStdin) of
                  (Just hIn, Just bs) -> do
                    BS.hPut hIn bs
                    hClose hIn
                  _ -> pure ()
                out <- readBounded hOut maxOutput
                err <- readBounded hErr maxOutput
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
-- structured 'ExecError'. Agent forwarding is OFF (no @-A@) — use
-- 'runRemoteShellForwarding' for git-credential ops.
runRemoteShell :: RemoteRunner -> SshConfig -> ShellCommand -> IO (Either ExecError Text)
runRemoteShell runner cfg cmd =
  let argv = sshExecArgv cfg (textShellCommand cmd)
  in runRemote runner argv

-- | Variant of 'runRemoteShell' that forwards the agent (@-A@). Used by
-- git-credential ops (clone/fetch/pull/push with a deploy key).
runRemoteShellForwarding
  :: RemoteRunner -> SshConfig -> ShellCommand -> IO (Either ExecError Text)
runRemoteShellForwarding runner cfg cmd =
  let argv = sshExecArgvForwarding cfg (textShellCommand cmd)
  in runRemote runner argv

-- | Run a shell command via the remote SSH executor WITH a stdin payload.
-- The bytes are piped to the remote process's stdin — used by the remote
-- 'UntrustedIO' arm for file writes (the file content goes over the SSH
-- channel, never interpolated into the command string, so content with
-- quotes/backticks/@$()@ is safe). The argv is the same fixed
-- 'sshExecArgv' shape; the stdin is a runtime parameter. Agent forwarding
-- is OFF — use 'runRemoteWithStdinForwarding' for git-credential ops.
runRemoteWithStdin
  :: RemoteRunner -> SshConfig -> ShellCommand -> ByteString
  -> IO (Either ExecError Text)
runRemoteWithStdin runner cfg cmd stdinBytes =
  let argv = sshExecArgv cfg (textShellCommand cmd)
  in runRemoteStdin runner argv stdinBytes

-- | Variant of 'runRemoteWithStdin' that forwards the agent (@-A@). Used
-- by git-credential ops that pipe stdin (e.g. writing @known_hosts@ over
-- SSH before a clone with a deploy key).
runRemoteWithStdinForwarding
  :: RemoteRunner -> SshConfig -> ShellCommand -> ByteString
  -> IO (Either ExecError Text)
runRemoteWithStdinForwarding runner cfg cmd stdinBytes =
  let argv = sshExecArgvForwarding cfg (textShellCommand cmd)
  in runRemoteStdin runner argv stdinBytes

-- | A fake 'RemoteRunner' that always returns a canned result (the
-- 'Either' is supplied by the caller). The argv + stdin are ignored.
-- Useful for the unreachable / host-key-mismatch tests.
mkFakeRemoteRunner :: Either ExecError Text -> RemoteRunner
mkFakeRemoteRunner canned = RemoteRunner
  { runRemote      = \_argv -> pure canned
  , runRemoteStdin = \_argv _stdin -> pure canned
  , runRemoteEnv   = \_env _argv -> pure canned
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
  , runRemoteEnv = \_env argv -> do
      modifyIORef' ref (++ [(argv, Nothing)])
      pure canned
  }

-- | Merge env overrides over the inherited environment (overrides win).
-- Mirrors 'mergeEnv' in 'UntrustedIO.hs' but kept local to avoid a
-- circular import.
mergeEnvReal :: [(String, String)] -> IO [(String, String)]
mergeEnvReal overrides =
  Map.toList . Map.union (Map.fromList overrides) . Map.fromList <$> getEnvironment