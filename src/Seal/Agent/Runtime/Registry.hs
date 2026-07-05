{-# LANGUAGE OverloadedStrings #-}
-- | The in-process agent runtime registry: an STM-backed map of running agent
-- instances. Race-safe CRUD mirroring the harness-registry pattern. An
-- 'AgentInstance' binds an 'AgentDefId' to a fresh 'SessionId', a status, and
-- the forked worker's 'ThreadId'.
--
-- Scope (M4): in-process instances only — no tmux/harness integration (that is
-- the separate Phase 3 Harnesses group, a different concern). Lifecycle ops
-- (@AGENT_LIST/START/STATUS/STOP@) are Trusted (not Audited) because running an
-- instance is harness-internal, not an evolutionary mutation.
--
-- 'startAgent' takes the worker action @IO ()@ as a parameter so the registry
-- is testable without dragging in 'Seal.Agent.Loop.runTurn' / 'Seal.Types.Env'.
-- The 'Seal.ISA.Ops.Agent' opcode builds the worker from a fresh 'AgentEnv'
-- over a def's provider/model/system/tools and passes it in.
module Seal.Agent.Runtime.Registry
  ( AgentStatus (..)
  , AgentInstance (..)
  , AgentRuntime
  , newAgentRuntime
  , startAgent
  , stopAgent
  , listAgents
  , agentStatus
  ) where

import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.Concurrent.STM
import Control.Exception (SomeException, catch)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Agent.Def.Types (AgentDefId)
import Seal.Core.Types (SessionId)

-- | The lifecycle status of a running agent instance. 'Crashed' carries the
-- exception message; 'Idle' is reserved for a future no-pending-turn state.
data AgentStatus = Starting | Running | Idle | Stopped | Crashed Text
  deriving stock (Eq, Show)

-- | One running agent instance, bound to a definition and a fresh session.
data AgentInstance = AgentInstance
  { aiId       :: AgentDefId
  , aiSession  :: SessionId
  , aiStatus   :: AgentStatus
  , aiThreadId :: ThreadId
  } deriving stock (Eq, Show)

-- | The STM-backed registry of running instances, keyed by 'AgentDefId'. No two
-- running instances share a def id: 'startAgent' rejects a duplicate;
-- 'stopAgent' removes the entry.
newtype AgentRuntime = AgentRuntime (TVar (Map AgentDefId AgentInstance))

-- | Build an empty runtime.
newAgentRuntime :: IO AgentRuntime
newAgentRuntime = AgentRuntime <$> newTVarIO Map.empty

-- | Start a new agent instance bound to the given def id + fresh session. The
-- worker action is forked; its 'ThreadId' is recorded. Returns @Left err@ if an
-- instance is already running for this def id (race-safe: the check-and-insert
-- is one STM transaction). The worker's status transitions to 'Running' once
-- the fork succeeds, or 'Crashed' on exception. The caller is responsible for
-- building the worker from the def (see 'Seal.ISA.Ops.Agent').
startAgent :: AgentRuntime -> AgentDefId -> SessionId -> IO () -> IO (Either Text AgentInstance)
startAgent (AgentRuntime tv) aid session worker = do
  -- Check-and-reserve: reject if already running. The reservation is not yet
  -- in the map; the fork + insert happens next. A concurrent 'startAgent' for
  -- the same def id races past this check, but the insert-if-absent transaction
  -- below resolves it: the loser kills its forked thread and returns Left.
  occupied <- atomically (Map.member aid <$> readTVar tv)
  if occupied
    then pure (Left "agent already running")
    else do
      tid <- forkIO (runWorker tv aid worker)
      mInst <- atomically $ do
        insts <- readTVar tv
        if Map.member aid insts
          then pure Nothing  -- lost the race; caller kills the thread
          else do
            let inst = AgentInstance aid session Running tid
            writeTVar tv (Map.insert aid inst insts)
            pure (Just inst)
      case mInst of
        Just inst -> pure (Right inst)
        Nothing   -> do
          killThread tid
          pure (Left "agent already running")

-- | Run the worker action, transitioning the instance to 'Crashed' on
-- exception. A normal completion leaves the status as 'Running' (the worker is
-- a long-running loop; reaching its end without exception is a clean stop that
-- 'stopAgent' observes). On exception the status is set to 'Crashed msg'.
runWorker :: TVar (Map AgentDefId AgentInstance) -> AgentDefId -> IO () -> IO ()
runWorker tv aid worker =
  catch worker $ \(e :: SomeException) ->
    atomically (modifyTVar' tv (Map.adjust (\i -> i { aiStatus = Crashed (T.pack (show e)) }) aid))

-- | Stop a running agent instance: kill the thread, remove the entry. Idempotent
-- (stopping a non-running def id is a success with a "not running" message, not
-- an error). Always leaves the registry without an entry for this def id, so a
-- fresh 'startAgent' can proceed.
stopAgent :: AgentRuntime -> AgentDefId -> IO (Either Text ())
stopAgent (AgentRuntime tv) aid = do
  mInst <- atomically $ do
    insts <- readTVar tv
    case Map.lookup aid insts of
      Nothing -> pure Nothing
      Just i  -> do
        writeTVar tv (Map.delete aid insts)
        pure (Just i)
  case mInst of
    Nothing -> pure (Right ())
    Just i  -> do
      killThread (aiThreadId i)
      pure (Right ())

-- | Snapshot all running instances.
listAgents :: AgentRuntime -> IO [AgentInstance]
listAgents (AgentRuntime tv) = Map.elems <$> readTVarIO tv

-- | Read one instance's status. @Nothing@ if not running.
agentStatus :: AgentRuntime -> AgentDefId -> IO (Maybe AgentStatus)
agentStatus (AgentRuntime tv) aid = fmap aiStatus . Map.lookup aid <$> readTVarIO tv