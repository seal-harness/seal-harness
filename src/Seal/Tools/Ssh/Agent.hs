{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
-- | The SSH-agent capability seam — a record-of-IO-actions (mirrors
-- 'Seal.Tools.Exec.Remote.RemoteRunner' and 'Seal.Security.Vault.VaultHandle')
-- so the ssh-agent lifecycle is testable without spawning a real
-- @ssh-agent@ / @ssh-add@ (unit-test-speed; no process spawning in the
-- test suite).
--
-- Security model (shared agent, per-op key scoping):
--
--   * The agent is started ONCE (at startup or lazily on first use) and
--     kept alive for the session. The @-t <lifetime>@ flag is
--     defense-in-depth: the agent forgets keys after @lifetime@ seconds
--     even if @sahDeleteAll@ is skipped.
--   * @sahAddKey@ runs @ssh-add <keyfile>@ per-op, loading exactly one
--     key into the shared agent. The passphrase is supplied via an
--     @SSH_ASKPASS@ helper script + @SSH_ASKPASS_REQUIRE=force@ (portable:
--     works on macOS where stdin piping doesn't bypass the TTY). The
--     agent decrypts the encrypted keyfile into memory; the cleartext
--     key lives only in agent memory.
--   * @sahDeleteAll@ runs @ssh-add -D@ per-op (forgets all keys) — this is
--     the per-op scoping invariant: exactly one key is live at forwarding
--     time. Even though the agent process persists, the key is removed
--     after the op.
--   * @sahGetAuthEnv@ yields the @SSH_AUTH_SOCK@ / @SSH_AGENT_PID@ env to
--     forward to the untrusted git run.
--
-- The untrusted machine NEVER sees the keyfile (encrypted or otherwise) —
-- only the forwarded @SSH_AUTH_SOCK@ via @ssh -A@ (the W2 opt-in
-- 'ForwardAgent' flag on 'sshExecArgv'). The agent keeps passwords in
-- memory, not on disk, which makes attacks significantly harder.
module Seal.Tools.Ssh.Agent
  ( SshAgentEnv (..)
  , SshAgentHandle (..)
  , mkRealSshAgentHandle
  , mkFakeSshAgentHandle
  , FakeAgentCall (..)
  ) where

import Control.Exception (try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef
import Data.List (isInfixOf, isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (createDirectoryIfMissing, removeFile)
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
-- agent starts; reused across all ops in the session.
data SshAgentEnv = SshAgentEnv
  { saeAuthSock :: String
  , saeAgentPid :: String
  }

-- | The capability seam. Each field is an IO action the clone/git opcode
-- calls; the smart constructors wire the real or fake implementation.
-- The constructor is NOT exported — only the smart constructors are.
--
-- The lifecycle is shared-agent, per-op-key:
--   @sahStart@ (once) → per-op: @sahAddKey@ → run → @sahDeleteAll@.
-- The agent process persists across ops; only the key is loaded/removed
-- per-op (the per-op scoping invariant — exactly one key live at
-- forwarding time).
data SshAgentHandle = SshAgentHandle
  { sahStart      :: IO (Either Text SshAgentEnv)
    -- ^ Start the shared @ssh-agent -s -t <lifetime>@ (once, at startup
    -- or lazily on first use). Parse @SSH_AUTH_SOCK@ /
    -- @SSH_AGENT_PID@ from its stdout. Returns the env to reuse across
    -- all ops.
  , sahAddKey     :: SshAgentEnv -> FilePath -> ByteString -> IO (Either Text ())
    -- ^ @ssh-add <keyfile>@: the passphrase (the 'ByteString') is supplied
    -- via an @SSH_ASKPASS@ helper script +
    -- @SSH_ASKPASS_REQUIRE=force@ (portable: works on macOS). The keyfile
    -- path is the arg. The agent decrypts the encrypted keyfile into
    -- memory. Called per-op.
  , sahDeleteAll  :: SshAgentEnv -> IO ()
    -- ^ @ssh-add -D@ — forget all keys. Called per-op (after the git run).
  , sahKill       :: SshAgentEnv -> IO ()
    -- ^ @ssh-agent -k@ — terminate the agent. Called once at shutdown (NOT
    -- per-op).
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
-- process once (the @-t <lifetime>@ is defense-in-depth: the agent forgets
-- keys after @lifetime@ seconds even if @sahDeleteAll@ is skipped). Per-op,
-- @sahAddKey@ loads one key + @sahDeleteAll@ removes it.
mkRealSshAgentHandle :: Maybe Int -> SshAgentHandle
mkRealSshAgentHandle mLifetime = SshAgentHandle
  { sahStart = do
      let agentArgv = case mLifetime of
            Nothing -> ["ssh-agent", "-s"]
            Just lt -> ["ssh-agent", "-s", "-t", show lt]
      eRes <- try @IOError (readProcessCollect agentArgv "")
      pure $ case eRes of
        Left _ioErr -> Left "ssh-agent: failed to start (unreachable)"
        Right (ExitSuccess, out, _err) -> case parseAgentEnv out of
          Nothing -> Left "ssh-agent: could not parse SSH_AUTH_SOCK/SSH_AGENT_PID"
          Just env -> Right env
        Right (ExitFailure _n, _out, _err) -> Left "ssh-agent: non-zero exit"
  , sahAddKey = \env keyfile passphrase -> do
      let askpassScript = "#!/bin/sh\necho " <> shellQuoteStr (TE.decodeUtf8Lenient passphrase) <> "\n"
      (askpassPath, askpassCleanup) <- writeAskpassHelper askpassScript
      let addEnv = [ ("SSH_ASKPASS", askpassPath)
                   , ("SSH_ASKPASS_REQUIRE", "force")
                   , ("DISPLAY", ":0")
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

-- | Run a process with a given env + stdin 'ByteString', capturing
-- stdout/stderr as 'Text'.
runProcessEnv
  :: [(String, String)] -> String -> [String] -> ByteString
  -> IO (ExitCode, Text, Text)
runProcessEnv env program args stdinBytes = do
  let cp = (proc program args)
          { std_in = CreatePipe, std_out = CreatePipe
          , std_err = CreatePipe, env = Just env
          }
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
    (p : as) -> readCreateProcessWithExitCode (proc p as) stdinStr
    []       -> error "readProcessCollect: empty argv (unreachable)"

----------------------------------------------------------------------------
-- Askpass helper (write a tiny script that echoes the passphrase)
----------------------------------------------------------------------------

-- | Write a tiny @SSH_ASKPASS@ helper script that echoes the passphrase.
-- The script is written to a temp file (0700), used once by @ssh-add@,
-- then removed. Portable: on macOS, @ssh-add@ reads the passphrase from
-- the TTY even when stdin is piped; @SSH_ASKPASS_REQUIRE=force@ forces it
-- to use the helper instead.
writeAskpassHelper :: Text -> IO (FilePath, IO ())
writeAskpassHelper script = do
  let dir = "/tmp"
  createDirectoryIfMissing True dir
  (path, h) <- openBinaryTempFile dir "seal-askpass-"
  BS.hPutStr h (TE.encodeUtf8 script)
  hClose h
  setFileMode path 0o700
  let cleanup = do
        _ <- try @IOError (removeFile path)
        pure ()
  pure (path, cleanup)

-- | Single-quote a value for a shell @echo@ command.
shellQuoteStr :: Text -> Text
shellQuoteStr t = "'" <> T.concatMap (\c -> if c == '\'' then "'\\''" else T.singleton c) t <> "'"

----------------------------------------------------------------------------
-- Fake (records calls in an IORef; no real process)
----------------------------------------------------------------------------

-- | A recorded fake call (for the per-op scoping test — assert exactly one
-- @SahAddKey@ + one @SahDeleteAll@ per op; @SahStart@ once at startup).
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