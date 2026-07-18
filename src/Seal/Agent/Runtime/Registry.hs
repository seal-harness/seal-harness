{-# LANGUAGE OverloadedStrings #-}
-- | The in-process agent runtime registry. Tracks live subagent instances
-- spawned by AGENT_START so the parent (or operator) can list them, read
-- status, and interrupt by id.
--
-- The registry is keyed by 'SubagentId' (def-id + random suffix), so multiple
-- concurrent children of the same def don't collide. Each 'AgentInstance'
-- binds a 'SubagentId' to its def id, fresh 'SessionId', status, the forked
-- worker's 'ThreadId' (for interrupt), and the parent's delegation depth.
--
-- Scope: in-process instances only — no tmux/harness integration (that is
-- the separate Phase 3 Harnesses group, a different concern). Lifecycle ops
-- (@AGENT_INSTANCES@ / @AGENT_START@ / @AGENT_STATUS@ / @AGENT_STOP@ /
-- @AGENT_INTERRUPT@) are Trusted (not Audited) because running an instance is
-- harness-internal, not an evolutionary mutation.
--
-- 'startAgent' takes the worker action @IO ()@ as a parameter so the
-- registry is testable without dragging in 'Seal.Agent.Loop.runTurn' /
-- 'Seal.Types.Env'. The 'Seal.ISA.Ops.Agent' opcode builds the worker from a
-- fresh 'AgentEnv' over a def's provider/model/system/tools and passes it in.
module Seal.Agent.Runtime.Registry
  ( AgentStatus (..)
  , AgentInstance (..)
  , AgentRuntime
  , newAgentRuntime
  , startAgent
  , stopAgent
  , interruptAgent
  , listAgents
  , agentStatus
  , agentInstanceBySubagentId
  ) where

import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.Concurrent.STM
import Control.Exception (SomeException, catch)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Agent.Def.Types (AgentDefId)
import Seal.Agent.Runtime.Delegation (SubagentId (..))
import Seal.Core.Types (SessionId)

-- | The lifecycle status of a running agent instance. 'Crashed' carries the
-- exception message; 'Interrupted' means the parent/operator requested a
-- stop via 'interruptAgent' (sets a flag the worker polls between turns).
data AgentStatus = Starting | Running | Idle | Stopped | Interrupted | Crashed Text
  deriving stock (Eq, Show)

-- | One running agent instance, bound to a definition, a fresh session, and
-- a subagent id (the registry key).
data AgentInstance = AgentInstance
  { aiId         :: AgentDefId
    -- ^ The def the child was spawned from (for display / lookup).
  , aiSubagentId :: SubagentId
    -- ^ The registry key (def-id + random suffix). Unique per spawn.
  , aiSession    :: SessionId
    -- ^ The fresh session the child runs under.
  , aiStatus     :: AgentStatus
  , aiThreadId   :: ThreadId
    -- ^ The forked worker thread (killed on stop / interrupt).
  , aiDepth      :: Int
    -- ^ The parent's delegation depth (0 = top-level parent). The child's
    -- depth is @aiDepth + 1@; checked against @max_spawn_depth@ before
    -- spawning.
  } deriving stock (Eq, Show)

-- | The STM-backed registry of running instances, keyed by 'SubagentId'. No
-- two running instances share a subagent id: 'startAgent' generates a fresh
-- one per spawn. 'stopAgent' removes the entry.
newtype AgentRuntime = AgentRuntime (TVar (Map SubagentId AgentInstance))

-- | Build an empty runtime.
newAgentRuntime :: IO AgentRuntime
newAgentRuntime = AgentRuntime <$> newTVarIO Map.empty

-- | Start a new agent instance bound to the given def id + fresh session +
-- subagent id. The worker action is forked; its 'ThreadId' is recorded.
-- Returns @Left err@ if an instance is already running for this subagent id
-- (shouldn't happen since subagent ids are freshly minted, but the check is
-- race-safe). The worker's status transitions to 'Running' once the fork
-- succeeds, or 'Crashed' on exception.
startAgent :: AgentRuntime -> AgentDefId -> SubagentId -> SessionId -> Int -> IO () -> IO (Either Text AgentInstance)
startAgent (AgentRuntime tv) aid subagentId session depth worker = do
  tid <- forkIO (runWorker tv subagentId worker)
  mInst <- atomically $ do
    insts <- readTVar tv
    if Map.member subagentId insts
      then pure Nothing  -- lost the race; shouldn't happen with random ids
      else do
        let inst = AgentInstance aid subagentId session Running tid depth
        writeTVar tv (Map.insert subagentId inst insts)
        pure (Just inst)
  case mInst of
    Just inst -> pure (Right inst)
    Nothing   -> do
      killThread tid
      pure (Left "agent already running for this subagent id")

-- | Run the worker action, transitioning the instance to 'Crashed' on
-- exception. A normal completion leaves the status as 'Running' until the
-- registry's 'stopAgent' is called (the worker is the child turn; reaching
-- its end without exception is a clean completion that the orchestrator
-- observes via 'runDelegate').
runWorker :: TVar (Map SubagentId AgentInstance) -> SubagentId -> IO () -> IO ()
runWorker tv subagentId worker =
  catch worker $ \(e :: SomeException) ->
    atomically (modifyTVar' tv (Map.adjust (\i -> i { aiStatus = Crashed (T.pack (show e)) }) subagentId))

-- | Stop a running agent instance: kill the thread, remove the entry.
-- Idempotent (stopping a non-running subagent id is a success with a
-- \"not running\" message, not an error). Always leaves the registry without
-- an entry for this subagent id, so a fresh 'startAgent' can proceed.
stopAgent :: AgentRuntime -> SubagentId -> IO (Either Text ())
stopAgent (AgentRuntime tv) subagentId = do
  mInst <- atomically $ do
    insts <- readTVar tv
    case Map.lookup subagentId insts of
      Nothing -> pure Nothing
      Just i  -> do
        writeTVar tv (Map.delete subagentId insts)
        pure (Just i)
  case mInst of
    Nothing -> pure (Right ())
    Just i  -> do
      killThread (aiThreadId i)
      pure (Right ())

-- | Request that a single running subagent stop at its next iteration
-- boundary. Does NOT hard-kill the worker thread (Haskell can't safely); sets
-- the instance's status to 'Interrupted' so the worker (which polls its
-- 'crhInterrupted' hook between turns) can exit cleanly. Returns 'True' if a
-- matching subagent was found.
--
-- The worker-builder is responsible for polling the 'crhInterrupted' IORef
-- between turn iterations and returning 'CerInterrupted' when it flips. The
-- registry cannot force the worker to stop — only the worker can decide to
-- exit. 'interruptAgent' /sets the flag and the status/; the worker /observes
-- the flag/.
interruptAgent :: AgentRuntime -> SubagentId -> IO Bool
interruptAgent (AgentRuntime tv) subagentId = do
  mInst <- atomically $ do
    insts <- readTVar tv
    case Map.lookup subagentId insts of
      Nothing -> pure Nothing
      Just i  -> do
        let i' = i { aiStatus = Interrupted }
        writeTVar tv (Map.insert subagentId i' insts)
        pure (Just i')
  pure (isJust mInst)

-- | Snapshot all running instances.
listAgents :: AgentRuntime -> IO [AgentInstance]
listAgents (AgentRuntime tv) = Map.elems <$> readTVarIO tv

-- | Read one instance's status. @Nothing@ if not running.
agentStatus :: AgentRuntime -> SubagentId -> IO (Maybe AgentStatus)
agentStatus (AgentRuntime tv) subagentId =
  fmap aiStatus . Map.lookup subagentId <$> readTVarIO tv

-- | Look up a full instance by subagent id (for the opcode to read its def
-- id, session id, depth, etc.).
agentInstanceBySubagentId :: AgentRuntime -> SubagentId -> IO (Maybe AgentInstance)
agentInstanceBySubagentId (AgentRuntime tv) subagentId =
  Map.lookup subagentId <$> readTVarIO tv