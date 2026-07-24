{-# LANGUAGE OverloadedStrings #-}
-- | The delegation pipeline — the Seal analog of Hermes' @delegate_task@.
--
-- 'runDelegate' spawns one or more child agents with isolated context, runs each
-- against a goal to completion (synchronously), and returns a structured
-- result per child. The parent blocks until all children finish (or time out).
--
-- Each child gets:
--
--   * a fresh 'SessionId' and its own two-file transcript nested under
--     @\<parent-session\>\/agents\/\<child-id\>@ (the worker-builder opens it);
--   * a focused system prompt built from the def's @adSystem@ + the goal +
--     optional context (the worker-builder assembles it);
--   * a narrowed tool set: the def's @adTools@ allow-list with the delegation
--     blocklist always stripped (no recursive spawning, no def mutation, no
--     lifecycle introspection) — the worker-builder is responsible for
--     applying the blocklist when it constructs the child ISA registry.
--
-- Features ported from @delegate_task@:
--
--   * batch mode ('tasks' array) with a concurrency cap
--     (@delegation.max_concurrent_children@);
--   * depth cap (@delegation.max_spawn_depth@, default 1, clamped to [1,3])
--     + @orchestrator_enabled@ kill switch (the role field is accepted but the
--     wiring layer enforces the effective role when it builds the child's
--     ISA registry);
--   * timeout (@delegation.child_timeout_seconds@, default 600s, floor 30s)
--     via 'System.Timeout.timeout';
--   * a heartbeat thread that touches a parent-activity cell every 30s so a
--     gateway inactivity timeout doesn't fire while the child works;
--   * a spawn-pause flag so an operator can freeze new fan-out without
--     interrupting running children;
--   * per-child provider\/model override via @[delegation] provider/model/base_url@
--     (the worker-builder reads the override and resolves the child provider
--     from it instead of inheriting the parent's);
--   * rich result aggregation: summary, status, exit_reason, tokens,
--     tool_trace, files read/written (the worker reports via the
--     'ChildRunHooks' accumulators).
--
-- Differences from @delegate_task@ (by design):
--
--   * Children are /transcripted/ — each child's conversation + entries land
--     on disk under the parent's @agents\/\<child-id\>@ dir, surviving restart.
--   * The child run is the existing 'Seal.Agent.Loop.runTurn' with the goal as
--     the first user message — there is no separate child AIAgent class.
module Seal.Agent.Runtime.Delegation
  ( -- * Config
    DelegationConfig (..)
  , defaultDelegationConfig
  , resolveDelegationConfig
  , fromFileConfig
    -- * Identity
  , SubagentId (..)
  , mkSubagentId
  , subagentIdText
    -- * Tasks & results
  , ChildTask (..)
  , ChildResult (..)
  , ChildExitReason (..)
  , ChildStatus (..)
  , ToolTraceEntry (..)
    -- * Worker builder
  , AgentWorkerBuilder
  , ChildRunHooks (..)
  , ChildWorkerOutcome (..)
    -- * Run
  , DelegateInput (..)
  , runDelegate
    -- * Pause control
  , SpawnPauseFlag (..)
  , newSpawnPauseFlag
  , setSpawnPaused
  , isSpawnPaused
    -- * Parent activity heartbeat
  , ParentActivity (..)
  , newParentActivity
  , touchParentActivity
  ) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar
  ( MVar, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar, tryPutMVar
  , tryTakeMVar )
import Control.Concurrent.STM
  ( TVar, atomically, newTVarIO, readTVarIO, writeTVar )
import Control.Exception (SomeException, catch)
import Control.Monad (forM, void, when)
import Data.Foldable (for_)
import Data.IORef (IORef, newIORef, readIORef)
import Data.Maybe (fromMaybe)
import Data.Aeson (object, ToJSON (..), (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import System.Random (randomRIO)
import System.Timeout (timeout)

import Seal.Agent.Def.Types (AgentDef (..))
import Seal.Core.Types (SessionId, sessionIdText)
import qualified Seal.Config.File as ConfigFile

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

-- | The @[delegation]@ section of @config.toml@. Every field is optional; a
-- missing key decodes as 'Nothing' and the resolver falls back to a default.
data DelegationConfig = DelegationConfig
  { dcMaxConcurrentChildren :: Maybe Int
    -- ^ Cap on parallel children per 'runDelegate' batch. Default 3, floor 1.
  , dcChildTimeoutSeconds :: Maybe Double
    -- ^ Hard per-child timeout in seconds. Default 600, floor 30.
  , dcMaxSpawnDepth :: Maybe Int
    -- ^ Max delegation tree depth. Default 1 (flat), clamped to [1,3].
  , dcOrchestratorEnabled :: Maybe Bool
    -- ^ Kill switch for the orchestrator role. Default True.
  , dcProvider :: Maybe Text
    -- ^ Per-child provider override (e.g. route subagents to a cheaper model).
  , dcModel :: Maybe Text
    -- ^ Per-child model override.
  , dcBaseUrl :: Maybe Text
    -- ^ Per-child base URL override (OpenAI-compatible direct endpoint).
  , dcApiKey :: Maybe Text
    -- ^ Per-child API key override (when @dcBaseUrl@ is set).
  , dcApiMode :: Maybe Text
    -- ^ Per-child API mode override (@chat_completions@ / @anthropic_messages@).
  , dcSubagentAutoApprove :: Maybe Bool
    -- ^ Whether subagent dangerous-command approvals auto-approve. Default
    -- False (auto-deny). Not yet wired (no approval callback in the child
    -- worker); reserved for future use.
  } deriving stock (Eq, Show)

-- | All fields absent — the operator did not set them.
defaultDelegationConfig :: DelegationConfig
defaultDelegationConfig = DelegationConfig
  { dcMaxConcurrentChildren = Nothing
  , dcChildTimeoutSeconds   = Nothing
  , dcMaxSpawnDepth          = Nothing
  , dcOrchestratorEnabled    = Nothing
  , dcProvider               = Nothing
  , dcModel                  = Nothing
  , dcBaseUrl                 = Nothing
  , dcApiKey                  = Nothing
  , dcApiMode                 = Nothing
  , dcSubagentAutoApprove    = Nothing
  }

-- | Compiled-in defaults used when the config is absent.
defaultMaxConcurrentChildren :: Int
defaultMaxConcurrentChildren = 3

defaultChildTimeoutSeconds :: Double
defaultChildTimeoutSeconds = 600

defaultMaxSpawnDepth :: Int
defaultMaxSpawnDepth = 1

minSpawnDepth :: Int
minSpawnDepth = 1

maxSpawnDepthCap :: Int
maxSpawnDepthCap = 3

minChildTimeoutSeconds :: Double
minChildTimeoutSeconds = 30

-- | Resolve a loaded 'DelegationConfig' to its effective numeric knobs, with
-- the documented clamps applied. Provider/model/base_url/api_key/api_mode
-- overrides are read directly from the config (they're 'Maybe'-typed).
resolveDelegationConfig :: DelegationConfig
                       -> (Int, Double, Int, Bool)
resolveDelegationConfig cfg =
  ( maxConc
  , childTimeout
  , maxDepth
  , orchEnabled
  )
  where
    maxConc = max 1 $ fromMaybe defaultMaxConcurrentChildren (dcMaxConcurrentChildren cfg)
    childTimeout = max minChildTimeoutSeconds $
                     fromMaybe defaultChildTimeoutSeconds (dcChildTimeoutSeconds cfg)
    rawDepth = fromMaybe defaultMaxSpawnDepth (dcMaxSpawnDepth cfg)
    maxDepth = max minSpawnDepth (min maxSpawnDepthCap rawDepth)
    orchEnabled = fromMaybe True (dcOrchestratorEnabled cfg)

-- | Convert a loaded 'DelegationFileConfig' (from 'Seal.Config.File') to a
-- 'DelegationConfig'. 'Nothing' maps to 'defaultDelegationConfig'.
fromFileConfig :: Maybe ConfigFile.DelegationFileConfig -> DelegationConfig
fromFileConfig Nothing = defaultDelegationConfig
fromFileConfig (Just dfc) = DelegationConfig
  { dcMaxConcurrentChildren = ConfigFile.dfcMaxConcurrentChildren dfc
  , dcChildTimeoutSeconds   = ConfigFile.dfcChildTimeoutSeconds dfc
  , dcMaxSpawnDepth          = ConfigFile.dfcMaxSpawnDepth dfc
  , dcOrchestratorEnabled    = ConfigFile.dfcOrchestratorEnabled dfc
  , dcProvider               = ConfigFile.dfcProvider dfc
  , dcModel                  = ConfigFile.dfcModel dfc
  , dcBaseUrl                 = ConfigFile.dfcBaseUrl dfc
  , dcApiKey                  = ConfigFile.dfcApiKey dfc
  , dcApiMode                 = ConfigFile.dfcApiMode dfc
  , dcSubagentAutoApprove    = ConfigFile.dfcSubagentAutoApprove dfc
  }

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------

-- | Opaque identifier for one live subagent. Smart-constructed from the def
-- id + a short random suffix so multiple concurrent children of the same def
-- don't collide.
newtype SubagentId = SubagentId { unSubagentId :: Text }
  deriving stock (Eq, Ord, Show)

-- | Mint a fresh 'SubagentId' from a def-id text + 8 hex chars. The def id is
-- embedded for debuggability (the TUI can show which def a subagent ran);
-- the random suffix disambiguates concurrent spawns.
mkSubagentId :: Text -> IO SubagentId
mkSubagentId defIdText = do
  suffix <- randomRIO (0 :: Int, 0xFFFFFFFF)
  pure (SubagentId (defIdText <> "-" <> showHexI32 suffix))

subagentIdText :: SubagentId -> Text
subagentIdText (SubagentId t) = t

-- | Show an 'Int' as 8-char zero-padded lowercase hex.
showHexI32 :: Int -> Text
showHexI32 n = T.justifyRight 8 '0' (T.pack (go n))
  where
    go x
      | x <= 0    = "0"
      | otherwise = loop x ""
    loop y acc
      | y == 0    = acc
      | otherwise = let (q, r) = y `divMod` 16
                        c = if r < 10 then toEnum (r + fromEnum '0')
                                      else toEnum (r - 10 + fromEnum 'a')
                    in loop q (c : acc)

-- ---------------------------------------------------------------------------
-- Tasks & results
-- ---------------------------------------------------------------------------

-- | One task to delegate. The def id resolves the provider/model/system/tools
-- template; the goal is the first user message; the context is optional
-- background appended to the system prompt.
data ChildTask = ChildTask
  { ctDefId   :: !Text
    -- ^ The agent def id to spawn from (must already exist via AGENT_DEF_WRITE).
  , ctGoal    :: !Text
    -- ^ The task goal — becomes the first user message in the child's turn.
  , ctContext :: !(Maybe Text)
    -- ^ Optional background context appended to the system prompt.
  , ctRole    :: !(Maybe Text)
    -- ^ @\"leaf\"@ (default) or @\"orchestrator\"@. Per-task role beats the
    -- top-level one. Orchestrators may spawn their own subagents, bounded by
    -- @max_spawn_depth@.
  } deriving stock (Eq, Show)

-- | Why a child stopped.
data ChildExitReason
  = CerCompleted
    -- ^ The child produced a final text response with no further tool calls.
  | CerMaxIterations
    -- ^ The child exhausted its per-run iteration budget (aeMaxTurns).
  | CerTimeout
    -- ^ The child hit @child_timeout_seconds@.
  | CerInterrupted
    -- ^ The parent (or operator) requested an interrupt.
  | CerError
    -- ^ The child raised an exception or the provider failed.
  deriving stock (Eq, Show)

-- | Aggregate status for the result entry.
data ChildStatus
  = CsCompleted
  | CsFailed
  | CsTimeout
  | CsInterrupted
  | CsError
  deriving stock (Eq, Show)

-- | One entry in the per-child tool-call trace.
data ToolTraceEntry = ToolTraceEntry
  { tteTool        :: !Text
    -- ^ The opcode name.
  , tteArgsBytes   :: !Int
    -- ^ Size of the JSON-encoded input in bytes.
  , tteResultBytes :: !Int
    -- ^ Size of the tool-result content in bytes.
  , tteIsError     :: !Bool
    -- ^ Whether the tool result carried an error.
  } deriving stock (Eq, Show)

instance ToJSON ToolTraceEntry where
  toJSON t = object
    [ "tool"         .= tteTool t
    , "args_bytes"   .= tteArgsBytes t
    , "result_bytes" .= tteResultBytes t
    , "is_error"     .= tteIsError t
    ]

-- | The structured result of one delegated child. Mirrors the @entry@ dict
-- returned by @delegate_task@'s @_run_single_child@.
data ChildResult = ChildResult
  { crTaskIndex       :: !Int
  , crStatus          :: !ChildStatus
  , crSummary         :: !(Maybe Text)
    -- ^ The child's final text response (or an error message).
  , crExitReason      :: !ChildExitReason
  , crDurationSeconds :: !Double
  , crSubagentId      :: !SubagentId
  , crTokensInput     :: !Int
  , crTokensOutput    :: !Int
  , crToolTrace       :: ![ToolTraceEntry]
  , crError           :: !(Maybe Text)
    -- ^ Present only when status is CsError / CsTimeout / CsInterrupted.
  , crFilesRead       :: ![Text]
    -- ^ File paths the child read (worker reports via hooks; may be empty).
  , crFilesWritten    :: ![Text]
    -- ^ File paths the child wrote (worker reports via hooks; may be empty).
  , crChildSession    :: !(Maybe SessionId)
    -- ^ The fresh 'SessionId' the child ran under (for transcript lookup).
  } deriving stock (Eq, Show)

instance ToJSON ChildResult where
  toJSON r = object
    [ "task_index"       .= crTaskIndex r
    , "subagent_id"      .= subagentIdText (crSubagentId r)
    , "status"           .= T.pack (show (crStatus r))
    , "summary"          .= crSummary r
    , "exit_reason"      .= T.pack (show (crExitReason r))
    , "duration_seconds" .= crDurationSeconds r
    , "tokens_input"     .= crTokensInput r
    , "tokens_output"    .= crTokensOutput r
    , "tool_trace"       .= crToolTrace r
    , "error"            .= crError r
    , "files_read"       .= crFilesRead r
    , "files_written"    .= crFilesWritten r
    , "child_session"    .= fmap sessionIdText (crChildSession r)
    ]

-- ---------------------------------------------------------------------------
-- Worker builder
-- ---------------------------------------------------------------------------

-- | A worker-builder: given a def + fresh session id + the task + the run
-- hooks, run the child turn to completion and return the outcome.
--
-- The wiring layer (Cli.hs, Channels.Loop.hs, Gateway.Send.hs) closes over
-- the per-turn 'AgentEnv' deps (caps, execBackend, appEnv, eCfg, parent
-- session id, parent depth) and produces the IO action. Keeping this as a
-- parameter decouples the opcode from 'Seal.Agent.Loop.runTurn' / provider
-- resolution so the opcode is unit-testable with a fake worker.
type AgentWorkerBuilder
  =  AgentDef
  -> SessionId
  -> ChildTask
  -> ChildRunHooks
  -> IO ChildWorkerOutcome

-- | Thread-safe accumulators the worker-builder writes to during the child
-- run. 'runDelegate' reads them after the worker returns to populate the
-- 'ChildResult'. The worker appends to these via 'atomicModifyIORef'' (the
-- IORefs are single-writer-per-child, but atomicModify is cheap and safe).
data ChildRunHooks = ChildRunHooks
  { crhToolTrace    :: IORef [ToolTraceEntry]
    -- ^ Append-only tool-trace accumulator.
  , crhFilesRead    :: IORef [Text]
    -- ^ Append-only file-read accumulator.
  , crhFilesWritten :: IORef [Text]
    -- ^ Append-only file-written accumulator.
  , crhInterrupted  :: IORef Bool
    -- ^ Polled by the worker between iterations; when 'True' the worker
    -- should stop at its next turn boundary and return 'CwoInterrupted'.
  }

-- | What the worker-builder reports back to 'runDelegate'. The builder does
-- NOT fill @crTaskIndex@ / @crSubagentId@ / @crDurationSeconds@ — those are
-- filled in by the orchestrator. It DOES fill in the summary, tokens, exit
-- reason, and child session id it observed.
data ChildWorkerOutcome = ChildWorkerOutcome
  { cwoSummary      :: !(Maybe Text)
    -- ^ The final text response from the child (or an error message).
  , cwoExitReason   :: !ChildExitReason
    -- ^ How the child's run ended (from the worker's perspective).
  , cwoTokensInput  :: !Int
  , cwoTokensOutput :: !Int
  , cwoChildSession :: !(Maybe SessionId)
    -- ^ The 'SessionId' the worker ran under (so the parent can look up the
    -- child's transcript later).
  }

-- ---------------------------------------------------------------------------
-- Pause control
-- ---------------------------------------------------------------------------

-- | A process-global flag that, when paused, makes 'runDelegate' reject new
-- spawns with a structured error. Running children keep running; only NEW
-- 'runDelegate' calls fail fast until 'setSpawnPaused' clears the flag.
newtype SpawnPauseFlag = SpawnPauseFlag (TVar Bool)

newSpawnPauseFlag :: IO SpawnPauseFlag
newSpawnPauseFlag = SpawnPauseFlag <$> newTVarIO False

setSpawnPaused :: SpawnPauseFlag -> Bool -> IO Bool
setSpawnPaused (SpawnPauseFlag tv) paused = do
  atomically (writeTVar tv paused)
  pure paused

isSpawnPaused :: SpawnPauseFlag -> IO Bool
isSpawnPaused (SpawnPauseFlag tv) = readTVarIO tv

-- ---------------------------------------------------------------------------
-- Parent activity heartbeat
-- ---------------------------------------------------------------------------

-- | A mutable cell the parent's gateway/loop touches to record \"the parent
-- is alive and working\". 'runDelegate' starts a heartbeat thread that
-- periodically touches this while a child runs, so the parent's gateway
-- inactivity timeout doesn't fire during a long delegation.
newtype ParentActivity = ParentActivity (MVar ())

newParentActivity :: IO ParentActivity
newParentActivity = ParentActivity <$> newMVar ()

-- | Touch the parent-activity cell (idempotent, never blocks).
touchParentActivity :: ParentActivity -> IO ()
touchParentActivity (ParentActivity mv) =
  void (tryPutMVar mv () >> tryTakeMVar mv)

-- ---------------------------------------------------------------------------
-- Run
-- ---------------------------------------------------------------------------

-- | The input to 'runDelegate' — one task to run (single mode) or many
-- (batch mode). The caller (the AGENT_START opcode) normalizes the model's
-- input to this before calling.
data DelegateInput
  = DiSingle !ChildTask
  | DiBatch ![ChildTask]

-- | The top-level delegation runner. Spawns one or more child agents, runs
-- each against its goal to completion (synchronously), and returns a
-- 'ChildResult' per task. The parent blocks until all children finish (or
-- time out). See the module header for the feature list.
runDelegate
  :: DelegationConfig
  -> SpawnPauseFlag
  -> Maybe ParentActivity
  -> Int
     -- ^ the parent's current delegation depth (0 = top-level parent)
  -> DelegateInput
  -> (ChildTask -> IO (Either Text (AgentDef, AgentWorkerBuilder, SessionId)))
     -- ^ resolver: look up the def, build the worker, mint a fresh child
     -- 'SessionId'. 'Left' = def not found / invalid / depth would be
     -- exceeded. Per-task so the caller can cache or re-resolve.
  -> IO (Either Text [ChildResult])
runDelegate cfg pauseFlag mParentActivity parentDepth input resolveTask = do
  paused <- isSpawnPaused pauseFlag
  if paused
    then pure (Left "Delegation spawning is paused. Clear the pause via the TUI or the AGENT_INTERRUPT RPC before retrying.")
    else do
      let (maxConc, childTimeout, maxDepth, _orchEnabled) = resolveDelegationConfig cfg
      if parentDepth >= maxDepth
        then pure (Left ("Delegation depth limit reached (depth=" <> T.pack (show parentDepth)
                          <> ", max_spawn_depth=" <> T.pack (show maxDepth)
                          <> "). Raise delegation.max_spawn_depth in config.toml if deeper nesting is required (cap: "
                          <> T.pack (show maxSpawnDepthCap) <> ")."))
        else do
          tasks <- case input of
            DiSingle t -> pure [t]
            DiBatch ts -> pure ts
          if null tasks
            then pure (Left "No tasks provided.")
            else do
              when (length tasks > maxConc) $
                -- We don't reject oversize batches; the semaphore caps
                -- parallelism. (delegate_task rejects; we cap.)
                pure ()
              runBatch maxConc childTimeout tasks
  where
    -- Run all tasks with a concurrency cap. Single-task short-cut avoids the
    -- thread-pool overhead.
    runBatch :: Int -> Double -> [ChildTask] -> IO (Either Text [ChildResult])
    runBatch maxConc childTimeout tasks =
      case tasks of
        [t] -> do
          r <- runOne 0 t childTimeout
          pure (Right [r])
        _   -> do
          sem <- newMVar maxConc
          mvars <- forM (zip [0 ..] tasks) $ \(idx, task) -> do
            resMVar <- newEmptyMVar
            void (forkIO $
              bracketSem sem $
                runOne idx task childTimeout >>= putMVar resMVar)
            pure resMVar
          results <- forM mvars readMVar
          pure (Right results)

    -- Acquire / release the semaphore MVar around an IO action.
    bracketSem :: MVar Int -> IO a -> IO a
    bracketSem sem act =
      takeMVar sem *> act <* putMVar sem (maxBound :: Int)
      -- The putMVar value doesn't matter; we just need to release the slot.
      -- Using maxBound is a no-op marker (the sem is a counting semaphore via
      -- takeMVar/putMVar).

    -- Run a single task to completion with a hard timeout and a heartbeat
    -- thread that touches the parent-activity cell.
    runOne :: Int -> ChildTask -> Double -> IO ChildResult
    runOne idx task childTimeout = do
      subagentId <- mkSubagentId (ctDefId task)
      let micros = round (childTimeout * 1000000) :: Int
      start <- getCurrentTime
      -- Thread-safe accumulators the worker writes to.
      traceRef     <- newIORef []
      readRef     <- newIORef []
      writtenRef  <- newIORef []
      interruptedRef <- newIORef False
      let hooks = ChildRunHooks traceRef readRef writtenRef interruptedRef
      mRes <- resolveTask task >>= \case
        Left err -> pure (Left err)
        Right (def, worker, childSid) -> do
          -- Start the heartbeat thread.
          hbStop <- newEmptyMVar
          hbThreadId <- forkIO (heartbeatLoop mParentActivity hbStop)
          let runWithCatch =
                worker def childSid task hooks
                  `catch` \e -> pure (ChildWorkerOutcome
                                       (Just (T.pack (show (e :: SomeException))))
                                       CerError 0 0 (Just childSid))
          mOutcome <- timeout micros runWithCatch
          -- Stop the heartbeat.
          void (tryPutMVar hbStop ())
          killThread hbThreadId
          pure (maybe (Left "timeout") Right mOutcome)
      end <- getCurrentTime
      let dur = realToFrac (end `diffUTCTime` start) :: Double
      case mRes of
        Left err ->
          pure (ChildResult
                  { crTaskIndex = idx
                  , crStatus = if err == "timeout" then CsTimeout else CsError
                  , crSummary = Nothing
                  , crExitReason = if err == "timeout" then CerTimeout else CerError
                  , crDurationSeconds = dur
                  , crSubagentId = subagentId
                  , crTokensInput = 0
                  , crTokensOutput = 0
                  , crToolTrace = []
                  , crError = Just (if err == "timeout"
                                      then "Subagent timed out after " <> T.pack (show childTimeout) <> "s."
                                      else err)
                  , crFilesRead = []
                  , crFilesWritten = []
                  , crChildSession = Nothing
                  })
        Right outcome -> do
          traceList <- readIORef traceRef
          filesRead <- readIORef readRef
          filesWritten <- readIORef writtenRef
          pure (ChildResult
                  { crTaskIndex = idx
                  , crStatus = childStatusFor (cwoExitReason outcome)
                  , crSummary = cwoSummary outcome
                  , crExitReason = cwoExitReason outcome
                  , crDurationSeconds = dur
                  , crSubagentId = subagentId
                  , crTokensInput = cwoTokensInput outcome
                  , crTokensOutput = cwoTokensOutput outcome
                  , crToolTrace = reverse traceList
                  , crError = Nothing
                  , crFilesRead = reverse filesRead
                  , crFilesWritten = reverse filesWritten
                  , crChildSession = cwoChildSession outcome
                  })

-- | Map a worker-reported exit reason to the aggregate status.
childStatusFor :: ChildExitReason -> ChildStatus
childStatusFor = \case
  CerCompleted    -> CsCompleted
  CerMaxIterations -> CsFailed
  CerTimeout      -> CsTimeout
  CerInterrupted  -> CsInterrupted
  CerError        -> CsError

-- | A 30s heartbeat that touches the parent-activity cell while the child
-- runs. Stops when the stop-MVar is filled.
heartbeatLoop :: Maybe ParentActivity -> MVar () -> IO ()
heartbeatLoop mParentActivity stopRef = loop
  where
    loop = do
      stop <- tryTakeMVar stopRef
      case stop of
        Just ()  -> pure ()
        Nothing  -> do
          for_ mParentActivity touchParentActivity
          threadDelay 30000000  -- 30s
          loop