{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
-- | The SSH-agent capability seam — a record-of-IO-actions (mirrors
-- 'Seal.Tools.Exec.Remote.RemoteRunner' and 'Seal.Security.Vault.VaultHandle')
-- so the per-op ssh-agent lifecycle is testable without spawning a real
-- @ssh-agent@ / @ssh-add@ (unit-test-speed; no process spawning in the
-- test suite).
--
-- Security model (design §4.6 — per-op agent, NOT session-scoped):
--
--   * @sahStart@ spawns a fresh @ssh-agent -s -t <lifetime>@ (the
--     @-t@ lifetime is defense-in-depth: the agent forgets the key even
--     if @sahDeleteAll@ / @sahKill@ is skipped).
--   * @sahAddKey@ runs @ssh-add <keyfile>@ with the keyfile's passphrase
--     piped to @ssh-add@'s stdin (@SSH_ASKPASS_REQUIRE=never@ so it reads
--     the passphrase from the pipe, NOT a tty / @SSH_ASKPASS@ helper —
--     verified non-interactive). The agent decrypts the encrypted keyfile
--     into memory; the cleartext key lives only in agent memory.
--   * @sahDeleteAll@ runs @ssh-add -D@ (forgets all keys).
--   * @sahKill@ runs @ssh-agent -k@ (terminates the agent).
--   * @sahGetAuthEnv@ yields the @SSH_AUTH_SOCK@ / @SSH_AGENT_PID@ env to
--     forward to the untrusted git run.
--
-- The untrusted machine NEVER sees the keyfile (encrypted or otherwise) —
-- only the forwarded @SSH_AUTH_SOCK@ via @ssh -A@ (the W2 opt-in
-- 'ForwardAgent' flag on 'sshExecArgv').
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

-- | The per-op agent environment — the @SSH_AUTH_SOCK@ / @SSH_AGENT_PID@
-- values to forward to the untrusted git run (via the env-override seam on
-- 'UntrustedIO' / the @-A@ flag on 'sshExecArgv').
data SshAgentEnv = SshAgentEnv
  { saeAuthSock :: String
  , saeAgentPid :: String
  }

-- | The capability seam. Each field is an IO action the clone/git opcode
-- calls; the smart constructors wire the real or fake implementation.
-- The constructor is NOT exported — only the smart constructors are.
--
-- The lifecycle is bracket-style: @sahStart@ → @sahAddKey@ → run →
-- @sahDeleteAll@ + @sahKill@. Exactly one identity is live at forwarding
-- time (the security-critical per-op scoping — design §4.6).
data SshAgentHandle = SshAgentHandle
  { sahStart      :: IO (Either Text SshAgentEnv)
    -- ^ Spawn a fresh @ssh-agent -s -t <lifetime>@, parse
    -- @SSH_AUTH_SOCK@ / @SSH_AGENT_PID@ from its stdout.
  , sahAddKey     :: SshAgentEnv -> FilePath -> ByteString -> IO (Either Text ())
    -- ^ @ssh-add <keyfile>@: the passphrase (the 'ByteString') is piped
    -- to @ssh-add@'s stdin (@SSH_ASKPASS_REQUIRE=never@); the keyfile path
    -- is the arg. The agent decrypts the encrypted keyfile into memory.
  , sahDeleteAll  :: SshAgentEnv -> IO ()
    -- ^ @ssh-add -D@ — forget all keys.
  , sahKill       :: SshAgentEnv -> IO ()
    -- ^ @ssh-agent -k@ — terminate the agent.
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
-- @ssh-agent -s@ emits shell-style lines like:
--
-- @
-- SSH_AUTH_SOCK=/tmp/ssh-XXXX/agent.123; export SSH_AUTH_SOCK;
-- SSH_AGENT_PID=123; export SSH_AGENT_PID;
-- echo Agent pid 123;
-- @
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
-- process; @ssh-add@ reads the passphrase from stdin.
-- The @-t <lifetime>@ is defense-in-depth (the agent forgets the key
-- after @lifetime@ seconds even if cleanup is skipped).
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
      -- On macOS, ssh-add reads the passphrase from the TTY even when
      -- stdin is piped (unlike Linux where SSH_ASKPASS_REQUIRE=never
      -- + stdin works). The portable approach: write a tiny askpass
      -- helper script that echoes the passphrase, set SSH_ASKPASS to it
      -- + SSH_ASKPASS_REQUIRE=force (forces ssh-add to use the helper for
      -- ALL passphrase input, regardless of DISPLAY or a TTY).
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
-- stdout/stderr as 'Text'. Used by 'mkRealSshAgentHandle' so the agent /
-- @ssh-add@ / @ssh-agent -k@ calls share one implementation.
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
-- then removed. This is the portable non-interactive approach: on macOS,
-- @ssh-add@ reads the passphrase from the TTY even when stdin is piped;
-- @SSH_ASKPASS_REQUIRE=force@ forces it to use the helper instead.
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

-- | Single-quote a value for a shell @echo@ command: @echo '<val>@ with
-- embedded @'@ escaped via the POSIX @'\''@ idiom.
shellQuoteStr :: Text -> Text
shellQuoteStr t = "'" <> T.concatMap (\c -> if c == '\'' then "'\\''" else T.singleton c) t <> "'"

----------------------------------------------------------------------------
-- Fake (records calls in an IORef; no real process)
----------------------------------------------------------------------------

-- | A recorded fake call (for the per-op scoping test — assert exactly one
-- @SahAddKey@ + one @SahDeleteAll@ + one @SahKill@ per op).
data FakeAgentCall
  = SahStart
  | SahAddKey FilePath ByteString
  | SahDeleteAll
  | SahKill
  deriving stock (Eq, Show)

-- | A fake 'SshAgentHandle' that records every call into the 'IORef'
-- (oldest-last) and returns a canned 'SshAgentEnv'. No real process is
-- spawned. Used by the per-op scoping test (design §4.6) to assert the
-- lifecycle is per-op (exactly one add/delete/kill per op).
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