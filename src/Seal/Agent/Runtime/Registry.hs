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
  , SpawnOrigin (..)
  , StopOutcome (..)
  , Delivery (..)
  , AgentRuntime
  , newAgentRuntime
  , startAgent
  , registerRunningAgent
  , registerRunningChild
  , registerFinishedAgent
  , registerFinishedChild
  , registerCompletedAgentResult
  , registerRunResult
  , registerRunCrash
  , endRun
  , resumeAgent
  , stopAgent
  , interruptAgent
  , listAgents
  , listAgentsFor
  , agentStatusFor
  , ownsChild
  , workerSettled
  , countRunningChildren
  , countFinishedChildren
  , pruneRetained
  , pollUntil
  , hasRunningChildren
  ) where

import Control.Concurrent (ThreadId, forkIO, killThread, myThreadId, threadDelay)
import Control.Concurrent.STM
import Control.Exception (SomeException, catch, mask, try)
import Control.Monad (forM_, void)
import GHC.Conc (ThreadStatus (..), threadStatus)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)

import Katip (Severity (..), ls)
import Seal.Logging.Global (globalLogIO)
import Seal.Agent.Def.Types (AgentDef, AgentDefId)
import Seal.Agent.Runtime.Delegation
  (ChildResult (..), ChildStatus (..), ChildTask, SubagentId (..), subagentIdText)
import Seal.Core.Types (SessionId, sessionIdText)

-- | The lifecycle status of a running agent instance. 'Crashed' carries the
-- exception message; 'Interrupted' means the parent/operator requested a
-- stop via 'interruptAgent' (sets a flag the worker polls between turns).
data AgentStatus = Starting | Running | Idle | Stopped | Interrupted | Crashed Text
  deriving stock (Eq, Show)

-- | What produced the current run. The mode is part of the origin because
-- delivery differs: foreground replies are returned in-band, background runs
-- append a completion message and wake the parent.
data SpawnOrigin
  = SoStartForeground
  | SoStartBackground
  | SoContinueForeground
  | SoContinueBackground
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
  , aiWorkerThread :: !(Maybe ThreadId)
    -- ^ The worker thread of the CURRENT run — the only handle 'stopAgent'
    -- may kill. 'Nothing' when no run is in flight (post-hoc registration, or
    -- a run that already settled). Never a bookkeeping thread: storing the
    -- *completing* thread here made 'stopAgent' able to kill the parent's own
    -- turn.
  , aiDepth      :: Int
    -- ^ The parent's delegation depth (0 = top-level parent). The child's
    -- depth is @aiDepth + 1@; checked against @max_spawn_depth@ before
    -- spawning.
  , aiParentSession :: SessionId
    -- ^ The parent session that spawned this child. Used by
    -- 'hasRunningChildren' to check whether a parent session has pending
    -- background children before transitioning it to idle.
  , aiResult     :: Maybe ChildResult
    -- ^ The 'ChildResult' when the child has completed ('Nothing' while
    -- running, 'Just' after completion). Populated by
    -- 'registerCompletedAgentResult'. Allows 'AGENT_STATUS' to return
    -- summary + child_session + exit_reason after the child finishes.
  , aiTask       :: !(Maybe ChildTask)
    -- ^ Spawn snapshot: context / role / isolate_workdir, plus the goal used
    -- only as the empty-history fallback when a run is resumed.
  , aiDef        :: !(Maybe AgentDef)
    -- ^ The def the child was BUILT from. Pinned: a resumed run uses it
    -- verbatim, so a def edited (or shadowed by a repo-local def) after the
    -- spawn cannot widen the child's authority.
  , aiTaskIndex  :: !Int
    -- ^ Batch index of the task, reused so a resumed run reports the same one.
  , aiGeneration :: !Int
    -- ^ Bumped by every claim. Status/result writes carry the generation they
    -- observed, so a late completion from run N cannot clobber run N+1.
  , aiOrigin     :: !SpawnOrigin
    -- ^ What produced the current run (drives wording; surfaced by status).
  , aiRuns       :: !Int
    -- ^ Runs so far (1 = the original spawn); the @#n@ ordinal and the
    -- per-child continue budget.
  , aiLastActivity :: !UTCTime
    -- ^ Bumped on claim and on every terminal write; the retention-pruning
    -- key.
  } deriving stock (Eq)

-- | Debugging only, and deliberately lossy: the task, the def, and the result
-- carry model-authored text (goal, system prompt, child summary) that must
-- never reach a log line.
instance Show AgentInstance where
  show i =
    "AgentInstance {aiId = " <> show (aiId i)
      <> ", aiSubagentId = " <> show (aiSubagentId i)
      <> ", aiSession = " <> show (aiSession i)
      <> ", aiStatus = " <> show (aiStatus i)
      <> ", aiWorkerThread = " <> maybe "Nothing" (const "Just <thread>") (aiWorkerThread i)
      <> ", aiDepth = " <> show (aiDepth i)
      <> ", aiParentSession = " <> show (aiParentSession i)
      <> ", aiResult = " <> elided (aiResult i)
      <> ", aiTask = " <> elided (aiTask i)
      <> ", aiDef = " <> elided (aiDef i)
      <> ", aiTaskIndex = " <> show (aiTaskIndex i)
      <> ", aiGeneration = " <> show (aiGeneration i)
      <> ", aiOrigin = " <> show (aiOrigin i)
      <> ", aiRuns = " <> show (aiRuns i)
      <> ", aiLastActivity = " <> show (aiLastActivity i)
      <> "}"
    where
      elided :: Maybe a -> String
      elided Nothing  = "Nothing"
      elided (Just _) = "Just <elided>"

-- | The STM-backed registry of running instances, keyed by 'SubagentId'. No
-- two running instances share a subagent id: 'startAgent' generates a fresh
-- one per spawn. 'stopAgent' removes the entry.
newtype AgentRuntime = AgentRuntime (TVar (Map SubagentId AgentInstance))

-- | Build an empty runtime.
newAgentRuntime :: IO AgentRuntime
newAgentRuntime = AgentRuntime <$> newTVarIO Map.empty

-- | Check whether a parent session has any children still in a Running or
-- Starting state. Used by the turn engine to decide whether to broadcast
-- \"idle\" when a turn ends: if background children are still running, the
-- parent session should stay \"thinking\" until the last child completes.
hasRunningChildren :: AgentRuntime -> SessionId -> IO Bool
hasRunningChildren (AgentRuntime tv) parentSid = do
  insts <- readTVarIO tv
  let allInsts = Map.elems insts
      matching = filter (\i -> aiParentSession i == parentSid) allInsts
      running = filter (isRunning . aiStatus) matching
      result = not (null running)
  globalLogIO DebugS (ls ("[idle-diag] hasRunningChildren: sid=" <> sessionIdText parentSid
    <> " result=" <> (if result then "true" else "false")
    <> " totalInstances=" <> T.pack (show (length allInsts))
    <> " matchingChildren=" <> T.pack (show (length matching))
    <> " runningChildren=" <> T.pack (show (length running))
    <> " childStatuses=[" <> T.intercalate "," (map (statusText . aiStatus) matching) <> "]"))
  pure result
  where
    isRunning Starting = True
    isRunning Running  = True
    isRunning _        = False
    statusText s = T.pack (show s)

-- | Start a new agent instance bound to the given def id + fresh session +
-- subagent id. The worker action is forked; its 'ThreadId' is recorded.
-- Returns @Left err@ if an instance is already running for this subagent id
-- (shouldn't happen since subagent ids are freshly minted, but the check is
-- race-safe). The worker's status transitions to 'Running' once the fork
-- succeeds, or 'Crashed' on exception.
startAgent :: AgentRuntime -> AgentDefId -> SubagentId -> SessionId -> SessionId -> Int -> IO () -> IO (Either Text AgentInstance)
startAgent (AgentRuntime tv) aid subagentId parentSession session depth worker = do
  now <- getCurrentTime
  -- Insert BEFORE forking. 'runWorker' records a crash with 'Map.adjust', so a
  -- worker that throws on its first instruction would otherwise write into an
  -- empty map, lose the 'Crashed' transition, and leave the entry 'Running'
  -- for ever. An instantly-throwing worker does win this race under load.
  claimed <- atomically $ do
    insts <- readTVar tv
    if Map.member subagentId insts
      then pure Nothing  -- lost the race; shouldn't happen with random ids
      else do
        let inst = AgentInstance
              { aiId = aid
              , aiSubagentId = subagentId
              , aiSession = session
              , aiStatus = Starting
              , aiWorkerThread = Nothing
              , aiDepth = depth
              , aiParentSession = parentSession
              , aiResult = Nothing
              , aiTask = Nothing
              , aiDef = Nothing
              , aiTaskIndex = 0
              , aiGeneration = 1
              , aiOrigin = SoStartBackground
              , aiRuns = 1
              , aiLastActivity = now
              }
        writeTVar tv (Map.insert subagentId inst insts)
        pure (Just inst)
  case claimed of
    Nothing -> pure (Left "agent already running for this subagent id")
    Just inst -> do
      -- The worker waits for its own handle to be recorded, so there is no
      -- window in which 'stopAgent' finds an instance it cannot kill.
      gate <- newEmptyTMVarIO
      tid <- forkIO $ do
        atomically (takeTMVar gate)
        runWorker tv subagentId 1 worker
      recorded <- atomically $ do
        insts <- readTVar tv
        case Map.lookup subagentId insts of
          Just i | aiGeneration i == 1 && aiStatus i == Starting -> do
            writeTVar tv (Map.insert subagentId
                            (i { aiStatus = Running, aiWorkerThread = Just tid }) insts)
            pure True
          _ -> pure False
      if recorded
        then do
          atomically (putTMVar gate ())
          pure (Right inst { aiStatus = Running, aiWorkerThread = Just tid })
        else do
          -- A stop (or an interrupt) claimed the instance before its handle
          -- existed: the body must never run.
          killThread tid
          pure (Right inst { aiStatus = Stopped, aiWorkerThread = Nothing })

-- | Register a running agent instance WITHOUT forking a worker thread.
-- Used by 'runDelegateAsync' which forks its own threads (via 'forkIO')
-- and needs the instance in the registry at spawn time so 'AGENT_INSTANCES'
-- lists it while running. The 'ThreadId' is the CHILD's forked thread id
-- (passed in by 'spawnOne' after the fork) so 'stopAgent' can kill the
-- correct thread. Idempotent: re-registering overwrites.
registerRunningAgent
  :: AgentRuntime -> AgentDefId -> SubagentId -> SessionId -> SessionId -> Int -> ThreadId -> IO ()
registerRunningAgent rt aid subagentId parentSession session depth tid =
  registerRunningChild rt aid subagentId parentSession session depth tid Nothing Nothing 0 SoStartBackground

-- | Register a running child WITH its full spawn snapshot. This is the
-- production path: the snapshot is what makes the child resumable, and the
-- recorded thread is what makes it stoppable.
registerRunningChild
  :: AgentRuntime
  -> AgentDefId
  -> SubagentId
  -> SessionId
  -> SessionId
  -> Int
  -> ThreadId
  -> Maybe ChildTask
  -> Maybe AgentDef
  -> Int
  -> SpawnOrigin
  -> IO ()
registerRunningChild (AgentRuntime tv) aid subagentId parentSession session depth tid mTask mDef taskIndex origin =
  do
    now <- getCurrentTime
    atomically $ do
      let inst = AgentInstance
            { aiId = aid
            , aiSubagentId = subagentId
            , aiSession = session
            , aiStatus = Running
            , aiWorkerThread = Just tid
            , aiDepth = depth
            , aiParentSession = parentSession
            , aiResult = Nothing
            , aiTask = mTask
            , aiDef = mDef
            , aiTaskIndex = taskIndex
            , aiGeneration = 1
            , aiOrigin = origin
            , aiRuns = 1
            , aiLastActivity = now
            }
      modifyTVar' tv (Map.insert subagentId inst)
    -- Log outside STM (globalLogIO is IO). This is the critical registration
    -- point: if the bracket cleanup's hasRunningChildren check runs before
    -- this line, the child is invisible and idle is broadcast prematurely.
    globalLogIO DebugS (ls ("[idle-diag] registerRunningAgent: subagent=" <> subagentIdText subagentId
      <> " parentSid=" <> sessionIdText parentSession
      <> " childSid=" <> sessionIdText session
      <> " depth=" <> T.pack (show depth)))

-- | Register a synchronously-completed child in the runtime registry. The
-- synchronous delegation model runs the worker to completion BEFORE this is
-- called (the 'ChildResult' payload IS the post-hoc record), so the instance
-- is recorded with status 'Stopped' (the child has already finished) and NO
-- worker handle (there is no live thread to kill). This makes the child
-- visible to 'AGENT_INSTANCES' / 'AGENT_STATUS' / 'AGENT_STOP' after the
-- synchronous run completes, and continuable. Idempotent: re-registering the
-- same subagent id overwrites the prior entry (the second registration wins).
registerFinishedAgent
  :: AgentRuntime -> AgentDefId -> SubagentId -> SessionId -> SessionId -> Int -> IO ()
registerFinishedAgent (AgentRuntime tv) aid subagentId parentSession session depth = do
  tid <- myThreadId
  now <- getCurrentTime
  atomically $ do
    insts <- readTVar tv
    let inst = AgentInstance
          { aiId = aid
          , aiSubagentId = subagentId
          , aiSession = session
          , aiStatus = Stopped
          , aiWorkerThread = Nothing
          , aiDepth = depth
          , aiParentSession = parentSession
          , aiResult = Nothing
          , aiTask = Nothing
          , aiDef = Nothing
          , aiTaskIndex = 0
          , aiGeneration = 1
          , aiOrigin = SoStartForeground
          , aiRuns = 1
          , aiLastActivity = now
          }
    writeTVar tv (Map.insert subagentId inst insts)
  globalLogIO DebugS (ls ("[idle-diag] registerFinishedAgent: subagent=" <> subagentIdText subagentId
    <> " thread=" <> T.pack (show tid)))

-- | Register a child that ran to completion synchronously, WITH its spawn
-- snapshot — the foreground-@start@ path, whose children must stay continuable
-- exactly like background ones. No worker handle (there is no live thread).
registerFinishedChild
  :: AgentRuntime
  -> AgentDefId
  -> SubagentId
  -> SessionId
  -> SessionId
  -> Int
  -> Maybe ChildTask
  -> Maybe AgentDef
  -> Int
  -> SpawnOrigin
  -> IO ()
registerFinishedChild (AgentRuntime tv) aid subagentId parentSession session depth mTask mDef taskIndex origin = do
  now <- getCurrentTime
  atomically $ do
    insts <- readTVar tv
    let inst = AgentInstance
          { aiId = aid
          , aiSubagentId = subagentId
          , aiSession = session
          , aiStatus = Stopped
          , aiWorkerThread = Nothing
          , aiDepth = depth
          , aiParentSession = parentSession
          , aiResult = Nothing
          , aiTask = mTask
          , aiDef = mDef
          , aiTaskIndex = taskIndex
          , aiGeneration = 1
          , aiOrigin = origin
          , aiRuns = 1
          , aiLastActivity = now
          }
    writeTVar tv (Map.insert subagentId inst insts)
  globalLogIO DebugS (ls ("[idle-diag] registerFinishedChild: subagent=" <> subagentIdText subagentId
    <> " taskIndex=" <> T.pack (show taskIndex)))

-- | Register a completed async child's result in the runtime registry.
-- Updates the existing entry's status to 'Stopped' (or 'Crashed' if the
-- result status is 'CsError') and stores the full 'ChildResult' in
-- 'aiResult' so 'AGENT_STATUS' can return summary + child_session +
-- exit_reason after the child finishes. If no entry exists for this
-- subagent id (e.g. the child was a resolve error that never registered),
-- this is a no-op.
registerCompletedAgentResult
  :: AgentRuntime -> SubagentId -> ChildResult -> IO ()
registerCompletedAgentResult (AgentRuntime tv) subagentId result = do
  atomically $ do
    insts <- readTVar tv
    case Map.lookup subagentId insts of
      Nothing -> pure ()  -- resolve-error child never registered
      Just inst -> do
        let newStatus = case crStatus result of
              CsError -> Crashed (fromMaybe "unknown error" (crError result))
              _       -> Stopped
            -- Deliberately does NOT touch 'aiWorkerThread': that handle
            -- belongs to the run's own thread, which records/clears it.
            inst' = inst { aiStatus = newStatus, aiResult = Just result }
        writeTVar tv (Map.insert subagentId inst' insts)
  -- Log outside STM. If this fires before registerRunningAgent (the race
  -- the in-fork spawnCallback was meant to fix), this is a no-op and the
  -- log will show the child was never registered.
  globalLogIO DebugS (ls ("[idle-diag] registerCompletedAgentResult: subagent=" <> subagentIdText subagentId
    <> " newStatus=" <> (case crStatus result of CsError -> "Crashed"; _ -> "Stopped")))

-- | Run the worker action, transitioning the instance to 'Crashed' on
-- exception. A normal completion leaves the status as 'Running' until the
-- registry's 'stopAgent' is called (the worker is the child turn; reaching
-- its end without exception is a clean completion that the orchestrator
-- observes via 'runDelegate').
runWorker :: TVar (Map SubagentId AgentInstance) -> SubagentId -> Int -> IO () -> IO ()
runWorker tv subagentId gen worker =
  catch worker $ \(e :: SomeException) ->
    atomically (modifyTVar' tv (Map.adjust (crashIfCurrent e) subagentId))
  where
    -- Generation-guarded: a stop bumps the generation before killing, so the
    -- killed worker's own crash write must not overwrite 'Stopped'.
    crashIfCurrent e i
      | aiGeneration i == gen = i { aiStatus = Crashed (T.pack (show e)) }
      | otherwise = i

-- | Outcome of a stop request.
data StopOutcome
  = StopOk
    -- ^ The child is stopped (and retained, so it stays continuable).
  | StillShuttingDown
    -- ^ The worker did not settle inside the bound. The status is left
    -- untouched so the operator is never told a live writer is stopped.
  deriving stock (Eq, Show)

-- | Whether a completed run's result should be delivered to the parent.
-- 'SuppressDelivery' is returned for an intentional termination, so a killed
-- child does not fabricate a @status=failed@ completion message.
data Delivery = DeliverResult | SuppressDelivery
  deriving stock (Eq, Show)

-- | Only the session that spawned a child may read, stop, interrupt, or
-- continue it. The runtime is process-global, so this is the whole
-- authorization story for every model-reachable agent-runtime path.
ownsChild :: SessionId -> AgentInstance -> Bool
ownsChild owner i = aiParentSession i == owner

-- | Stop a child: bump its run generation (so the dying run's report is
-- suppressed), kill its worker thread, wait — bounded — for it to settle, and
-- RETAIN the entry as 'Stopped' (so it stays resumable). Kills only
-- 'aiWorkerThread', never a bookkeeping thread. Idempotent.
stopAgent :: AgentRuntime -> SessionId -> SubagentId -> IO (Either Text StopOutcome)
stopAgent (AgentRuntime tv) owner subagentId = do
  now <- getCurrentTime
  claimed <- atomically $ do
    insts <- readTVar tv
    case Map.lookup subagentId insts of
      Nothing -> pure (Right Nothing)  -- idempotent: nothing to stop
      Just i
        | not (ownsChild owner i) -> pure (Left notOwnerMsg)
        | isTerminal (aiStatus i) -> pure (Right Nothing)
        | otherwise -> do
            let i' = i { aiStatus = Stopped
                       , aiWorkerThread = Nothing
                       , aiGeneration = aiGeneration i + 1
                       , aiLastActivity = now
                       }
            writeTVar tv (Map.insert subagentId i' insts)
            pure (Right (aiWorkerThread i))
  case claimed of
    Left e -> pure (Left e)
    Right Nothing -> pure (Right StopOk)
    Right (Just tid) -> do
      -- 'killThread' is 'throwTo', which blocks until the target accepts the
      -- exception; a masked worker could block it indefinitely, so the kill
      -- runs in its own thread and is raced against the settle poll.
      _ <- forkIO (killThread tid)
      settled <- pollUntil 500 (workerSettledThread tid)
      pure (Right (if settled then StopOk else StillShuttingDown))
  where
    workerSettledThread tid = do
      st <- threadStatus tid
      pure $ case st of
        ThreadFinished -> True
        ThreadDied     -> True
        _              -> False

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
interruptAgent :: AgentRuntime -> SessionId -> SubagentId -> IO (Either Text Bool)
interruptAgent (AgentRuntime tv) owner subagentId = do
  now <- getCurrentTime
  atomically $ do
    insts <- readTVar tv
    case Map.lookup subagentId insts of
      Nothing -> pure (Right False)  -- no match: nothing to interrupt
      Just i
        | not (ownsChild owner i) -> pure (Left notOwnerMsg)
        | otherwise -> do
            let i' = i { aiStatus = Interrupted
                       , aiGeneration = aiGeneration i + 1
                       , aiLastActivity = now
                       }
            writeTVar tv (Map.insert subagentId i' insts)
            pure (Right True)

-- | Snapshot all running instances.
listAgents :: AgentRuntime -> IO [AgentInstance]
listAgents (AgentRuntime tv) = Map.elems <$> readTVarIO tv

-- | Snapshot the instances owned by one session (the model-facing view).
listAgentsFor :: AgentRuntime -> SessionId -> IO [AgentInstance]
listAgentsFor rt owner = filter (ownsChild owner) <$> listAgents rt

-- | Read one instance, refusing a child owned by another session.
agentStatusFor :: AgentRuntime -> SessionId -> SubagentId -> IO (Either Text AgentInstance)
agentStatusFor (AgentRuntime tv) owner subagentId = do
  insts <- readTVarIO tv
  pure $ case Map.lookup subagentId insts of
    Nothing -> Left (unknownIdMsg subagentId)
    Just i
      | ownsChild owner i -> Right i
      | otherwise         -> Left notOwnerMsg

-- | Clear the run handle for a run that has finished — but only when the
-- handle is this thread's, so a completed run can never clear a newer run's
-- handle. This is what lets the parent's wake turn continue immediately after
-- reading a reply.
endRun :: AgentRuntime -> SubagentId -> IO ()
endRun (AgentRuntime tv) subagentId = do
  me <- myThreadId
  now <- getCurrentTime
  atomically $ modifyTVar' tv
    (Map.adjust (\i -> case aiWorkerThread i of
       Just t | t == me -> i { aiWorkerThread = Nothing, aiLastActivity = now }
       _                -> i) subagentId)

-- | Record a run's terminal result, generation-guarded:
--   * current generation -> terminal status + result, 'DeliverResult';
--   * stale generation, instance already terminal (an intentional stop) ->
--     keep the answer but 'SuppressDelivery';
--   * stale generation, a NEWER run owns the entry -> no-op.
registerRunResult :: AgentRuntime -> SubagentId -> Int -> ChildResult -> IO Delivery
registerRunResult rt@(AgentRuntime tv) subagentId gen result = do
  now <- getCurrentTime
  insts0 <- readTVarIO tv
  let mParent = aiParentSession <$> Map.lookup subagentId insts0
  delivery <- atomically $ do
    insts <- readTVar tv
    case Map.lookup subagentId insts of
      Nothing -> pure SuppressDelivery
      Just i
        | aiGeneration i == gen -> do
            let newStatus = case crStatus result of
                  CsError -> Crashed (fromMaybe "unknown error" (crError result))
                  _       -> Stopped
                i' = i { aiStatus = newStatus, aiResult = Just result, aiLastActivity = now }
            writeTVar tv (Map.insert subagentId i' insts)
            pure DeliverResult
        | isTerminal (aiStatus i) -> do
            let i' = i { aiResult = Just result, aiLastActivity = now }
            writeTVar tv (Map.insert subagentId i' insts)
            pure SuppressDelivery
        | otherwise -> pure SuppressDelivery
  forM_ mParent (pruneRetained rt)
  pure delivery

-- | Record a run that died outside the worker's own catch (kill, async
-- exception), generation-guarded.
registerRunCrash :: AgentRuntime -> SubagentId -> Int -> SomeException -> IO ()
registerRunCrash (AgentRuntime tv) subagentId gen e = do
  now <- getCurrentTime
  atomically $ modifyTVar' tv (Map.adjust (apply now) subagentId)
  globalLogIO DebugS (ls ("[idle-diag] registerRunCrash: subagent=" <> subagentIdText subagentId
    <> " err=" <> T.pack (show e)))
  where
    apply now' i
      | aiGeneration i == gen = i { aiStatus = Crashed (T.pack (show e)), aiLastActivity = now' }
      | otherwise = i

-- | Claim a terminal instance and fork a new run of it.
--
-- The claim, the fork and the handle recording are ordered so no failure path
-- leaves a permanent 'Starting' entry: the claim is undone on any exception,
-- the handle is recorded in the parent (the child inherits the mask, so it
-- cannot run its body yet), and the body runs under 'restore' so it is
-- interruptible exactly like a normally-spawned child. The returned 'TMVar' is
-- always filled — with the result and its 'Delivery' verdict, or with the
-- exception that killed the run — so a foreground caller can never hang.
resumeAgent
  :: AgentRuntime
  -> SessionId
  -> SubagentId
  -> SpawnOrigin
  -> IO ChildResult
  -> IO (Either Text (AgentInstance, TMVar (Either SomeException (Delivery, ChildResult))))
resumeAgent rt@(AgentRuntime tv) owner subagentId origin body = mask $ \restore -> do
  now <- getCurrentTime
  claimed <- atomically $ do
    insts <- readTVar tv
    case Map.lookup subagentId insts of
      Nothing -> pure (Left (unknownIdMsg subagentId))
      Just i
        | not (ownsChild owner i) -> pure (Left notOwnerMsg)
        | not (isTerminal (aiStatus i)) -> pure (Left stillRunningMsg)
        | isNothing (aiTask i) || isNothing (aiDef i) -> pure (Left noSnapshotMsg)
        | aiRuns i >= maxContinuesPerChild -> pure (Left runBudgetMsg)
        | otherwise -> do
            let claimed' = i { aiStatus = Starting
                             , aiResult = Nothing
                             , aiGeneration = aiGeneration i + 1
                             , aiOrigin = origin
                             , aiRuns = aiRuns i + 1
                             , aiLastActivity = now
                             }
            writeTVar tv (Map.insert subagentId claimed' insts)
            pure (Right claimed')
  case claimed of
    Left e -> pure (Left e)
    Right inst -> do
      let gen = aiGeneration inst
      sink <- newEmptyTMVarIO
      -- The body waits for its own handle to be recorded. Without the gate a
      -- fast run can finish (and write its terminal result) before the CAS
      -- below, which then loses and reports a spurious "stopped while being
      -- resumed" — and, worse, kills a thread that already reported.
      gate <- newEmptyTMVarIO
      tid <- forkIO $ do
        atomically (takeTMVar gate)
        outcome <- try (restore body)
        case outcome of
          Right result -> do
            delivery <- registerRunResult rt subagentId gen result
            endRun rt subagentId
            atomically (void (tryPutTMVar sink (Right (delivery, result))))
          Left e -> do
            registerRunCrash rt subagentId gen e
            endRun rt subagentId
            atomically (void (tryPutTMVar sink (Left e)))
      ok <- atomically $ do
        insts <- readTVar tv
        case Map.lookup subagentId insts of
          Just i | aiGeneration i == gen && aiStatus i == Starting -> do
            writeTVar tv (Map.insert subagentId
                            (i { aiStatus = Running, aiWorkerThread = Just tid }) insts)
            pure True
          _ -> pure False
      if ok
        then do
          atomically (putTMVar gate ())
          pure (Right (inst, sink))
        else do
          killThread tid
          pure (Left "the child was stopped while it was being resumed; retry.")

-- | Has the current run's worker thread finished (or is there no run)?
workerSettled :: AgentInstance -> IO Bool
workerSettled i = case aiWorkerThread i of
  Nothing -> pure True
  Just tid -> do
    st <- threadStatus tid
    pure $ case st of
      ThreadFinished -> True
      ThreadDied     -> True
      _              -> False

-- | Children of this parent that are starting or running.
countRunningChildren :: AgentRuntime -> SessionId -> IO Int
countRunningChildren rt owner =
  length . filter (isLive . aiStatus) <$> listAgentsFor rt owner

-- | Children of this parent that are known but finished (retained).
countFinishedChildren :: AgentRuntime -> SessionId -> IO Int
countFinishedChildren rt owner =
  length . filter (isTerminal . aiStatus) <$> listAgentsFor rt owner

-- | Bound the retained entries per parent: keep the most recently active
-- 'retainedChildrenCap' finished children and drop the rest. Running (or
-- mid-claim) children are never pruned.
pruneRetained :: AgentRuntime -> SessionId -> IO ()
pruneRetained (AgentRuntime tv) owner =
  atomically $ modifyTVar' tv keep
  where
    keep insts =
      let finished = [ (k, i) | (k, i) <- Map.toList insts
                               , ownsChild owner i
                               , isTerminal (aiStatus i) ]
          excess = length finished - retainedChildrenCap
          doomed
            | excess <= 0 = []
            | otherwise = take excess (map fst (sortOn (aiLastActivity . snd) finished))
      in foldr Map.delete insts doomed

-- | Poll a predicate every 10 ms up to a bound in ms; exits as soon as it
-- holds.
pollUntil :: Int -> IO Bool -> IO Bool
pollUntil budgetMs act = go (max 0 budgetMs)
  where
    go remaining = do
      ok <- act
      if ok || remaining <= 0
        then pure ok
        else threadDelay 10000 >> go (remaining - 10)

-- ---------------------------------------------------------------------------
-- Limits and messages
-- ---------------------------------------------------------------------------

maxContinuesPerChild :: Int
maxContinuesPerChild = 50

retainedChildrenCap :: Int
retainedChildrenCap = 32

isTerminal :: AgentStatus -> Bool
isTerminal Stopped     = True
isTerminal Interrupted = True
isTerminal (Crashed _) = True
isTerminal _           = False

isLive :: AgentStatus -> Bool
isLive Starting = True
isLive Running  = True
isLive _        = False

unknownIdMsg :: SubagentId -> Text
unknownIdMsg sid =
  "unknown subagent id \"" <> subagentIdText sid
    <> "\". It was not spawned by this session, or was lost to a restart or to retention pruning."

notOwnerMsg :: Text
notOwnerMsg =
  "that subagent belongs to a different session; a session may only act on the children it spawned."

stillRunningMsg :: Text
stillRunningMsg = "the subagent is still running. Stop or interrupt it before continuing."

noSnapshotMsg :: Text
noSnapshotMsg =
  "the subagent was registered without a task snapshot and cannot be continued; start a new child."

runBudgetMsg :: Text
runBudgetMsg =
  "the subagent has been continued " <> T.pack (show maxContinuesPerChild)
    <> " times; start a fresh child for new work."
