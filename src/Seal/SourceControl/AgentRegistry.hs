{-# LANGUAGE OverloadedStrings #-}
-- | The persistent ssh-agent registry (#88). Each unique repo (identified
-- by its vault key) gets an entry recording the @SSH_AUTH_SOCK@ /
-- @SSH_AGENT_PID@ of the ssh-agent process that holds its deploy key. The
-- registry persists to @~\/.seal\/state\/ssh-agents\/registry.json@ so
-- agents survive @seal serve@ restarts — a second seal process reuses the
-- running agent instead of spawning a new one.
--
-- At startup, 'arProbeAndSweep' probes each persisted agent
-- (@ssh-add -l@ with @SSH_AUTH_SOCK@) and removes dead entries (PID gone
-- or socket removed). This GCs agents from unexpected shutdowns where
-- cleanup didn't happen.
--
-- Security: the registry file contains only @auth_sock@ + @agent_pid@
-- (non-secret values — the socket path + PID are not secrets; the key
-- material lives only in the agent's memory). Mode 0600 to prevent other
-- users from reading the socket path (defense-in-depth).
module Seal.SourceControl.AgentRegistry
  ( AgentRegistryHandle
  , mkAgentRegistryHandle
  , arUpsert
  , arRemove
  , arLoad
  , arIsLive
  , arProbeAndSweep
  , probeAgent
  , AgentStatus (..)
  , parseAgentEnv
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (try)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as AK
import Data.Aeson.KeyMap qualified as AKM
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist, renameFile)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Process (CreateProcess (..), StdStream (..), proc, readCreateProcessWithExitCode)

import Seal.Tools.Ssh.Agent (SshAgentEnv (..))

----------------------------------------------------------------------------
-- Types
----------------------------------------------------------------------------

-- | The liveness of a persisted agent, determined by 'probeAgent'.
data AgentStatus = AgentAlive | AgentDead
  deriving stock (Eq, Show)

-- | A JSON-serializable registry entry. The 'Text' key is the repo's vault
-- key (the repo identity — see 'Seal.SourceControl.Clone.cdAgentRegistry').
newtype AgentRegistry = AgentRegistry (Map Text SshAgentEnv)
  deriving stock (Eq, Show)

instance ToJSON AgentRegistry where
  toJSON (AgentRegistry m) =
    object [ AK.fromString (T.unpack k) .= object [ "auth_sock" .= saeAuthSock v
                                                  , "agent_pid" .= saeAgentPid v ]
           | (k, v) <- Map.toList m ]

instance FromJSON AgentRegistry where
  parseJSON = withObject "AgentRegistry" $ \o -> do
    let keys = AKM.keys o
    entries <- traverse (\k -> do
      v <- o .: k
      pure (AK.toText k, v)) keys
    pure (AgentRegistry (Map.fromList entries))

----------------------------------------------------------------------------
-- Handle
----------------------------------------------------------------------------

-- | A handle to the persistent agent registry, closing over the directory
-- where the registry file lives. All operations are serialized behind a
-- process-wide MVar to prevent lost-update races (mirrors
-- 'Seal.SourceControl.Registry.repoRegistryWriteLock').
data AgentRegistryHandle = AgentRegistryHandle
  { arhDir    :: FilePath
    -- ^ The directory holding @registry.json@.
  , arhLock   :: MVar ()
    -- ^ Serializes read-modify-write cycles.
  , arhCache  :: IORef (Maybe AgentRegistry)
    -- ^ In-memory cache of the last-loaded registry (avoids re-reading the
    -- file on every 'arLoad' when no writes have occurred in between).
  , arhLive   :: IORef (Set Text)
    -- ^ Keys of agents started in THIS process (not loaded from disk).
    -- Reuse of a live agent skips the liveness probe (the agent was just
    -- started — it's alive). Only agents loaded from a prior process's
    -- persisted registry are probed.
  }

-- | The registry file name (lives inside 'arhDir').
registryFileName :: FilePath
registryFileName = "registry.json"

-- | Build an 'AgentRegistryHandle' closing over @dir@. The directory is
-- created if it doesn't exist (the caller's 'ensureSealDirs' is responsible
-- for creating it; this is a best-effort idempotent creation).
mkAgentRegistryHandle :: FilePath -> IO AgentRegistryHandle
mkAgentRegistryHandle dir = do
  lock  <- newMVar ()
  cache <- newIORef Nothing
  live  <- newIORef Set.empty
  pure AgentRegistryHandle
    { arhDir = dir
    , arhLock = lock
    , arhCache = cache
    , arhLive = live
    }

----------------------------------------------------------------------------
-- Load / Save (atomic)
----------------------------------------------------------------------------

-- | Load the registry from disk. Absent file → empty registry. Caches the
-- result in 'arhCache'.
arLoad :: AgentRegistryHandle -> IO (Map Text SshAgentEnv)
arLoad h = do
  mCached <- readIORef (arhCache h)
  case mCached of
    Just (AgentRegistry m) -> pure m
    Nothing -> do
      m <- loadFromDisk (arhDir h)
      writeIORef (arhCache h) (Just (AgentRegistry m))
      pure m

loadFromDisk :: FilePath -> IO (Map Text SshAgentEnv)
loadFromDisk dir = do
  let path = dir </> registryFileName
  exists <- doesFileExist path
  if not exists
    then pure Map.empty
    else do
      bytes <- BL.readFile path
      case A.decode bytes of
        Just (AgentRegistry m) -> pure m
        Nothing                -> pure Map.empty

-- | Save the registry to disk atomically: write @registry.json.tmp@, then
-- rename. The file is created mode 0600 (defense-in-depth — the socket
-- path is not a secret but shouldn't be world-readable).
saveToDisk :: FilePath -> Map Text SshAgentEnv -> IO ()
saveToDisk dir m = do
  let path = dir </> registryFileName
      tmp  = path <> ".tmp"
      encoded = A.encode (AgentRegistry m)
  BL.writeFile tmp encoded
  setFileMode tmp 0o600
  renameFile tmp path

----------------------------------------------------------------------------
-- Mutation (lock-serialized)
----------------------------------------------------------------------------

-- | Insert or overwrite an agent entry (keyed by vault key). Also marks
-- the agent as live in this process (so subsequent reuse skips the liveness
-- probe).
arUpsert :: AgentRegistryHandle -> Text -> SshAgentEnv -> IO ()
arUpsert h key env = withMVar (arhLock h) $ \_ -> do
  m <- loadFromDisk (arhDir h)
  let m' = Map.insert key env m
  saveToDisk (arhDir h) m'
  writeIORef (arhCache h) (Just (AgentRegistry m'))
  modifyIORef' (arhLive h) (Set.insert key)

-- | Remove an agent entry (no-op if absent).
arRemove :: AgentRegistryHandle -> Text -> IO ()
arRemove h key = withMVar (arhLock h) $ \_ -> do
  m <- loadFromDisk (arhDir h)
  let m' = Map.delete key m
  saveToDisk (arhDir h) m'
  writeIORef (arhCache h) (Just (AgentRegistry m'))
  modifyIORef' (arhLive h) (Set.delete key)

-- | Check if an agent was started in THIS process (live, no probe needed).
arIsLive :: AgentRegistryHandle -> Text -> IO Bool
arIsLive h key = Set.member key <$> readIORef (arhLive h)

----------------------------------------------------------------------------
-- Probe + Sweep (liveness check + GC dead entries)
----------------------------------------------------------------------------

-- | Probe a persisted agent to determine if it's still alive. Runs
-- @ssh-add -l@ with @SSH_AUTH_SOCK=<sock>@:
--
--   * Exit 0 → alive (keys are loaded).
--   * Exit 1 → alive (agent is running, but no keys loaded — still alive).
--   * Exit 2 → dead (can't contact the agent — socket gone or PID dead).
--   * IOException → dead (the @ssh-add@ binary couldn't run or the socket
--     path is invalid).
probeAgent :: SshAgentEnv -> IO AgentStatus
probeAgent env = do
  let cp = (proc "ssh-add" ["-l"])
        { close_fds = True
        , env = Just [("SSH_AUTH_SOCK", saeAuthSock env)]
        , std_out = CreatePipe
        , std_err = CreatePipe
        }
  eRes <- try @IOError (readCreateProcessWithExitCode cp "")
  case eRes of
    Left _ioErr -> pure AgentDead
    Right (ec, _out, _err) -> case ec of
      ExitSuccess     -> pure AgentAlive
      ExitFailure 1   -> pure AgentAlive
      ExitFailure _n  -> pure AgentDead

-- | Probe every persisted agent and remove dead entries. Called at seal
-- startup (before serving) so stale agents from a crashed/seal-killed
-- process are GC'd. Lock-serialized so a concurrent 'arUpsert' can't race
-- the sweep.
arProbeAndSweep :: AgentRegistryHandle -> IO ()
arProbeAndSweep h = withMVar (arhLock h) $ \_ -> do
  m <- loadFromDisk (arhDir h)
  -- Probe each entry; collect the alive ones.
  aliveEntries <- traverse (\(k, env) -> do
    status <- probeAgent env
    pure (k, env, status)) (Map.toList m)
  let m' = Map.fromList [ (k, env) | (k, env, AgentAlive) <- aliveEntries ]
  -- Only write if something changed (avoid unnecessary disk writes).
  if Map.size m /= Map.size m'
    then do
      saveToDisk (arhDir h) m'
      writeIORef (arhCache h) (Just (AgentRegistry m'))
    else writeIORef (arhCache h) (Just (AgentRegistry m))

----------------------------------------------------------------------------
-- Parse ssh-agent -s output (re-exported from Ssh.Agent for the test)
----------------------------------------------------------------------------

-- | Parse @ssh-agent -s@ stdout for @SSH_AUTH_SOCK@ and @SSH_AGENT_PID@.
-- Re-exported here so the test can start a real agent and parse its output.
parseAgentEnv :: String -> Maybe SshAgentEnv
parseAgentEnv out = do
  sock <- findAssign "SSH_AUTH_SOCK"
  pid  <- findAssign "SSH_AGENT_PID"
  Just SshAgentEnv { saeAuthSock = sock, saeAgentPid = pid }
  where
    ls = lines out
    findAssign name =
      let prefix = name <> "="
      in case filter (prefix `isPrefixOf'`) ls of
           (l : _) -> Just (takeWhile (/= ';') (drop (length prefix) l))
           []      -> Nothing
    isPrefixOf' p s = take (length p) s == p