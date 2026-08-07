{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
-- | The SSH-agent capability seam — a record-of-IO-actions (mirrors
-- 'Seal.Tools.Exec.Remote.RemoteRunner' and 'Seal.Security.Vault.VaultHandle')
-- so the ssh-agent lifecycle is testable without spawning a real
-- @ssh-agent@ / @ssh-add@ (unit-test-speed; no process spawning in the
-- test suite).
--
-- Security model (one agent per repo, key persists for the harness lifetime):
--
--   * Each unique repo (identified by its vault key) gets its own
--     @ssh-agent -s@ process, started lazily on first use. The agent
--     persists until the harness shuts down (no @-t@ lifetime, no
--     per-op @sahDeleteAll@).
--   * @sahAddKey@ runs @ssh-add <keyfile>@ once per repo (when the agent
--     is first started). The passphrase is supplied via an
--     @SSH_ASKPASS@ helper script + @SSH_ASKPASS_REQUIRE=force@. The
--     helper script reads the passphrase from the @SEAL_ASKPASS_SECRET@
--     environment variable — the script itself contains NO secret, so it
--     can be written to a temp file without violating the "no secret on
--     disk" requirement. The passphrase flows: vault (encrypted at rest)
--     → Haskell process memory → @ssh-add@'s env → askpass helper's
--     inherited env → stdout → @ssh-add@. Never touches disk.
--   * @sahGetAuthEnv@ yields the @SSH_AUTH_SOCK@ / @SSH_AGENT_PID@ env to
--     forward to the untrusted git run (via @ssh -A@ agent forwarding).
--
-- The untrusted machine NEVER sees the keyfile (encrypted or otherwise) —
-- only the forwarded @SSH_AUTH_SOCK@ via @ssh -A@. The agent keeps
-- passwords in memory, not on disk.
module Seal.Tools.Ssh.Agent
  ( SshAgentEnv (..)
  , SshAgentHandle (..)
  , mkRealSshAgentHandle
  , mkFakeSshAgentHandle
  , FakeAgentCall (..)
  , agentCreateProcess_close_fds
  , addKeyCreateProcess_close_fds
  , killCreateProcess_close_fds
  ) where

import Control.Exception (try)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.=), (.:))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef
import Data.List (isInfixOf, isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (removeFile)
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose, hFlush)
import System.IO.Temp (openBinaryTempFile)
import System.Posix.Files (setFileMode)
import System.Process
  ( CreateProcess (..), StdStream (..), proc, readCreateProcessWithExitCode
  , waitForProcess, withCreateProcess
  )

----------------------------------------------------------------------------
-- Types
----------------------------------------------------------------------------

-- | The shared agent environment — the @SSH_AUTH_SOCK@ / @SSH_AGENT_PID@
-- values to forward to the untrusted git run (via the env-override seam on
-- 'UntrustedIO' / the @-A@ flag on 'sshExecArgv'). Built once when the
-- agent starts; reused across all ops for that repo.
data SshAgentEnv = SshAgentEnv
  { saeAuthSock :: String
  , saeAgentPid :: String
  }
  deriving stock (Eq, Show)

-- | JSON codec for persistence (the agent registry serializes these to
-- @~\/.seal\/state\/ssh-agents\/registry.json@). The values are non-secret
-- (a socket path + PID); the key material lives only in the agent's memory.
instance ToJSON SshAgentEnv where
  toJSON env = object [ "auth_sock" .= saeAuthSock env
                      , "agent_pid" .= saeAgentPid env ]

instance FromJSON SshAgentEnv where
  parseJSON = withObject "SshAgentEnv" $ \o -> do
    sock <- o .: "auth_sock"
    pid  <- o .: "agent_pid"
    pure SshAgentEnv { saeAuthSock = sock, saeAgentPid = pid }

-- | The capability seam. Each field is an IO action the clone/git opcode
-- calls; the smart constructors wire the real or fake implementation.
-- The constructor is NOT exported — only the smart constructors are.
--
-- The lifecycle is one-agent-per-repo:
--   @sahStart@ (once per repo) → @sahAddKey@ (once per repo) → run.
-- The agent process + key persist for the harness lifetime; @sahKill@
-- is called at shutdown.
data SshAgentHandle = SshAgentHandle
  { sahStart      :: IO (Either Text SshAgentEnv)
    -- ^ Start @ssh-agent -s@ (once per repo, lazily on first use). Parse
    -- @SSH_AUTH_SOCK@ / @SSH_AGENT_PID@ from its stdout.
  , sahAddKey     :: SshAgentEnv -> FilePath -> ByteString -> IO (Either Text ())
    -- ^ @ssh-add <keyfile>@: the passphrase (the 'ByteString') is supplied
    -- via an @SSH_ASKPASS@ helper script that reads it from the
    -- @SEAL_ASKPASS_SECRET@ environment variable (no secret on disk). The
    -- agent decrypts the encrypted keyfile into memory. Called once per
    -- repo (when the agent is first started).
  , sahDeleteAll  :: SshAgentEnv -> IO ()
    -- ^ @ssh-add -D@ — forget all keys. Not called per-op in the
    -- one-agent-per-repo model; retained for fail-closed cleanup on
    -- @sahAddKey@ failure.
  , sahKill       :: SshAgentEnv -> IO ()
    -- ^ @ssh-agent -k@ — terminate the agent. Called once at harness
    -- shutdown.
  , sahGetAuthEnv :: SshAgentEnv -> [(String, String)]
    -- ^ The @SSH_AUTH_SOCK@ / @SSH_AGENT_PID@ env to forward.
  }

----------------------------------------------------------------------------
-- Helpers (render env extras, parse agent stdout)
----------------------------------------------------------------------------

-- | Render the env extras for forwarding to the untrusted git run.
saeGetAuthEnv :: SshAgentEnv -> [(String, String)]
saeGetAuthEnv env =
  [ ("SSH_AUTH_SOCK", saeAuthSock env)
  , ("SSH_AGENT_PID", saeAgentPid env)
  ]

-- | Parse @ssh-agent -s@ stdout for @SSH_AUTH_SOCK@ and @SSH_AGENT_PID@.
parseAgentEnv :: String -> Maybe SshAgentEnv
parseAgentEnv out = do
  sock <- findAssign "SSH_AUTH_SOCK"
  pid  <- findAssign "SSH_AGENT_PID"
  Just SshAgentEnv { saeAuthSock = sock, saeAgentPid = pid }
  where
    ls = lines out
    findAssign name =
      let prefix = name <> "="
      in case filter (prefix `isPrefixOf`) ls of
           (l : _) -> Just (takeWhile (/= ';') (drop (length prefix) l))
           []      -> Nothing

----------------------------------------------------------------------------
-- Real implementation (spawns ssh-agent / ssh-add)
----------------------------------------------------------------------------

-- | The real @ssh-agent@ / @ssh-add@ implementation. Spawns a real agent
-- process per repo (no @-t@ lifetime — the key persists for the harness
-- lifetime). @sahAddKey@ loads the key once per repo using an env-var
-- askpass helper (no secret on disk).
mkRealSshAgentHandle :: SshAgentHandle
mkRealSshAgentHandle = SshAgentHandle
  { sahStart = do
      let agentArgv = ["ssh-agent", "-s"]
      eRes <- try @IOError (readProcessCollect agentArgv "")
      pure $ case eRes of
        Left _ioErr -> Left "ssh-agent: failed to start (unreachable)"
        Right (ExitSuccess, out, _err) -> case parseAgentEnv out of
          Nothing -> Left "ssh-agent: could not parse SSH_AUTH_SOCK/SSH_AGENT_PID"
          Just env -> Right env
        Right (ExitFailure _n, _out, _err) -> Left "ssh-agent: non-zero exit"
  , sahAddKey = \env keyfile passphrase -> do
      -- The askpass helper script contains NO secret — it reads the
      -- passphrase from the SEAL_ASKPASS_SECRET environment variable.
      -- The passphrase flows: Haskell memory → ssh-add's env → askpass
      -- helper's inherited env → stdout → ssh-add. Never touches disk.
      -- The script is written to a 0700 temp file, used once, then removed.
      (askpassPath, askpassCleanup) <- writeAskpassHelper
      let addEnv =
            [ ("SSH_ASKPASS", askpassPath)
            , ("SSH_ASKPASS_REQUIRE", "force")
            , ("SEAL_ASKPASS_SECRET", T.unpack (TE.decodeUtf8Lenient passphrase))
            ] ++ saeGetAuthEnv env
      eRes <- try @IOError (runProcessEnv addEnv "ssh-add" [keyfile] "")
      askpassCleanup
      pure $ case eRes of
        Left _ioErr -> Left "ssh-add: failed to start"
        Right (ExitSuccess, _out, _err) -> Right ()
        Right (ExitFailure _n, _out, err)
          | "Enter passphrase" `isInfixOf` T.unpack err ->
              Left "ssh-add: passphrase rejected (wrong passphrase?)"
          | T.null err -> Left "ssh-add: non-zero exit"
          | otherwise -> Left ("ssh-add: " <> err)
  , sahDeleteAll = \env -> do
      _ <- try @IOError (runProcessEnv (saeGetAuthEnv env) "ssh-add" ["-D"] "")
      pure ()
  , sahKill = \env -> do
      _ <- try @IOError (runProcessEnv (saeGetAuthEnv env) "ssh-agent" ["-k"] "")
      pure ()
  , sahGetAuthEnv = saeGetAuthEnv
  }

-- | The 'CreateProcess' for @ssh-agent -s@ (sahStart). Exposed for the
-- FD-leak regression test (#88): @close_fds = True@ ensures ssh-agent does
-- NOT inherit seal's TCP sockets (the WS stream port) + transcript file
-- handles. Without this, a crashed seal leaves ssh-agent holding the
-- gateway's ports hostage.
agentCreateProcess :: [String] -> CreateProcess
agentCreateProcess argv =
  case argv of
    (p : as) -> mkCloseFds (proc p as)
    []       -> error "agentCreateProcess: empty argv (unreachable)"
  where
    mkCloseFds cp = cp { close_fds = True }

-- | The 'CreateProcess' for @ssh-add@ (sahAddKey / sahDeleteAll).
addKeyCreateProcess :: [(String, String)] -> String -> [String] -> CreateProcess
addKeyCreateProcess env program args =
  (proc program args) { close_fds = True, std_in = CreatePipe
                      , std_out = CreatePipe, std_err = CreatePipe
                      , env = Just env }

-- | The 'CreateProcess' for @ssh-agent -k@ (sahKill).
killCreateProcess :: [(String, String)] -> CreateProcess
killCreateProcess env =
  (proc "ssh-agent" ["-k"]) { close_fds = True
                             , std_in = CreatePipe
                             , std_out = CreatePipe
                             , std_err = CreatePipe
                             , env = Just env }

-- | Test-visible projections of the 'close_fds' field (the FD-leak
-- regression test asserts these are 'True').
agentCreateProcess_close_fds :: Bool
agentCreateProcess_close_fds =
  close_fds (agentCreateProcess ["ssh-agent", "-s"])

addKeyCreateProcess_close_fds :: Bool
addKeyCreateProcess_close_fds =
  close_fds (addKeyCreateProcess [] "ssh-add" ["-D"])

killCreateProcess_close_fds :: Bool
killCreateProcess_close_fds = close_fds (killCreateProcess [])

-- | Run a process with a given env + stdin 'ByteString', capturing
-- stdout/stderr as 'Text'.
runProcessEnv
  :: [(String, String)] -> String -> [String] -> ByteString
  -> IO (ExitCode, Text, Text)
runProcessEnv env program args stdinBytes = do
  let cp = addKeyCreateProcess env program args
  withCreateProcess cp $ \mIn mOut mErr ph -> do
    case mIn of
      Just hIn -> do
        BS.hPutStr hIn stdinBytes
        hFlush hIn
        hClose hIn
      Nothing -> pure ()
    out <- readHandle mOut
    err <- readHandle mErr
    ec  <- waitForProcess ph
    pure (ec, out, err)
  where
    readHandle :: Maybe Handle -> IO Text
    readHandle Nothing  = pure ""
    readHandle (Just h) = TE.decodeUtf8Lenient <$> BS.hGetContents h

-- | Run a process with inherited env + a 'String' stdin, capturing
-- stdout/stderr as 'String' (used by 'sahStart' to parse the agent env).
readProcessCollect :: [String] -> String -> IO (ExitCode, String, String)
readProcessCollect argv stdinStr =
  case argv of
    (_ : _) -> readCreateProcessWithExitCode (agentCreateProcess argv) stdinStr
    []       -> error "readProcessCollect: empty argv (unreachable)"

----------------------------------------------------------------------------
-- Askpass helper (generic script that reads passphrase from env var)
----------------------------------------------------------------------------

-- | Write a generic @SSH_ASKPASS@ helper script that reads the passphrase
-- from the @SEAL_ASKPASS_SECRET@ environment variable. The script contains
-- NO secret — only the env var *name*. It can be written to a temp file
-- without violating the "no secret on disk" requirement. The temp file is
-- 0700 (private), used once by @ssh-add@, then removed.
writeAskpassHelper :: IO (FilePath, IO ())
writeAskpassHelper = do
  let script = "#!/bin/sh\necho $SEAL_ASKPASS_SECRET\n"
  (path, h) <- openBinaryTempFile "/tmp" "seal-askpass-"
  BS.hPutStr h (TE.encodeUtf8 (T.pack script))
  hClose h
  setFileMode path 0o700
  let cleanup = do
        _ <- try @IOError (removeFile path)
        pure ()
  pure (path, cleanup)

 ----------------------------------------------------------------------------
-- Fake (records calls in an IORef; no real process)
----------------------------------------------------------------------------

-- | A recorded fake call (for the per-repo scoping test — assert exactly one
-- @SahStart@ + one @SahAddKey@ per repo; no per-op @SahDeleteAll@).
data FakeAgentCall
  = SahStart
  | SahAddKey FilePath ByteString
  | SahDeleteAll
  | SahKill
  deriving stock (Eq, Show)

-- | A fake 'SshAgentHandle' that records every call into the 'IORef'
-- (oldest-last) and returns a canned 'SshAgentEnv'. No real process is
-- spawned.
mkFakeSshAgentHandle :: IORef [FakeAgentCall] -> SshAgentEnv -> SshAgentHandle
mkFakeSshAgentHandle ref cannedEnv = SshAgentHandle
  { sahStart = do
      modifyIORef' ref (++ [SahStart])
      pure (Right cannedEnv)
  , sahAddKey = \_env keyfile pass -> do
      modifyIORef' ref (++ [SahAddKey keyfile pass])
      pure (Right ())
  , sahDeleteAll = \_env -> do
      modifyIORef' ref (++ [SahDeleteAll])
      pure ()
  , sahKill = \_env -> do
      modifyIORef' ref (++ [SahKill])
      pure ()
  , sahGetAuthEnv = saeGetAuthEnv
  }