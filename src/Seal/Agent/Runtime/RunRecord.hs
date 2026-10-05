{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
-- | The durable sub-agent run record registry. Tracks every spawned child's
-- full lifecycle from creation through completion (or cancellation), with
-- generation tokens to prevent stale completions, lifecycle hook emission,
-- session cleanup, and disk persistence for restart recovery.
--
-- This module is the foundation for push-based completion notification:
-- instead of the parent polling @AGENT_MANAGE status@, the harness tracks
-- each child run in a 'SubagentRunRecord' and delivers completion
-- automatically via the sidecar mechanism (see 'Seal.Handles.Transcript').
--
-- The registry is STM-backed (like 'Seal.Agent.Runtime.Registry') and
-- thread-safe. Records are keyed by run id (the 'SubagentId' text).
module Seal.Agent.Runtime.RunRecord
  ( -- * Record type
    SubagentRunRecord (..)
  , RunId
  , RunOutcome (..)
  , EndReason (..)
  , SpawnMode (..)
  , CleanupMode (..)
  , GenerationToken (..)
    -- * Registry
  , RunRecordRegistry
  , newRunRecordRegistry
    -- * Operations
  , createRun
  , completeRun
  , listRunsForParent
  , findLatestRunForChild
  , countPendingDescendants
  , cancelRunsForParent
    -- * Lifecycle hooks
  , registerEndedHook
    -- * Persistence
  , runRecordPath
  , saveRunRecordToDisk
  , loadRunRecord
  ) where

import Control.Concurrent.STM
import Control.Exception (try, IOException)
import Control.Monad (forM_)
import Data.Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import GHC.Generics (Generic)
import System.Directory
  (createDirectoryIfMissing, doesFileExist, renameFile)
import System.FilePath ((</>), takeDirectory, (<.>))
import System.Random (randomRIO)

import Seal.Agent.Runtime.Delegation
  (SubagentId (..), subagentIdText, ChildResult (..), ChildStatus (..))
import Seal.Core.Types (SessionId, mkSystemSessionId, sessionIdText)

----------------------------------------------------------------------------
-- Types
----------------------------------------------------------------------------

-- | Unique run identifier. Currently the 'SubagentId' text, but kept as a
-- distinct type for clarity and future evolution.
type RunId = Text

-- | The terminal outcome of a run.
data RunOutcome
  = OutcomeOk
  | OutcomeError
  | OutcomeTimeout
  | OutcomeKilled
  | OutcomeUnknown
  deriving stock (Eq, Show)

instance ToJSON RunOutcome where
  toJSON = \case
    OutcomeOk      -> "ok"
    OutcomeError   -> "error"
    OutcomeTimeout -> "timeout"
    OutcomeKilled  -> "killed"
    OutcomeUnknown -> "unknown"

instance FromJSON RunOutcome where
  parseJSON = withText "RunOutcome" $ \case
    "ok"      -> pure OutcomeOk
    "error"   -> pure OutcomeError
    "timeout" -> pure OutcomeTimeout
    "killed"  -> pure OutcomeKilled
    "unknown" -> pure OutcomeUnknown
    other     -> fail ("unknown RunOutcome: " <> T.unpack other)

-- | Why the run ended.
data EndReason
  = EndComplete
  | EndError
  | EndTimeout
  | EndKilled
  deriving stock (Eq, Show)

instance ToJSON EndReason where
  toJSON = \case
    EndComplete -> "complete"
    EndError    -> "error"
    EndTimeout  -> "timeout"
    EndKilled   -> "killed"

instance FromJSON EndReason where
  parseJSON = withText "EndReason" $ \case
    "complete" -> pure EndComplete
    "error"    -> pure EndError
    "timeout"  -> pure EndTimeout
    "killed"   -> pure EndKilled
    other      -> fail ("unknown EndReason: " <> T.unpack other)

-- | How the child was spawned.
data SpawnMode
  = SpawnForeground
  | SpawnBackground
  deriving stock (Eq, Show)

instance ToJSON SpawnMode where
  toJSON SpawnForeground = "foreground"
  toJSON SpawnBackground = "background"

instance FromJSON SpawnMode where
  parseJSON = withText "SpawnMode" $ \case
    "foreground" -> pure SpawnForeground
    "background" -> pure SpawnBackground
    other        -> fail ("unknown SpawnMode: " <> T.unpack other)

-- | What to do with the child session on completion.
data CleanupMode
  = CleanupDelete
  | CleanupKeep
  deriving stock (Eq, Show)

instance ToJSON CleanupMode where
  toJSON CleanupDelete = "delete"
  toJSON CleanupKeep   = "keep"

instance FromJSON CleanupMode where
  parseJSON = withText "CleanupMode" $ \case
    "delete" -> pure CleanupDelete
    "keep"   -> pure CleanupKeep
    other    -> fail ("unknown CleanupMode: " <> T.unpack other)

-- | A generation token prevents stale completions from corrupting re-spawned
-- jobs. Each 'createRun' mints a fresh token; 'completeRun' rejects calls
-- whose token doesn't match the current record's token.
newtype GenerationToken = GenerationToken Int
  deriving stock (Eq, Show)
  deriving newtype (ToJSON, FromJSON)

-- | The core tracking record for each spawned child. Stored in the in-memory
-- registry AND persisted to disk so completion can be recovered after
-- restarts. See the design doc for the full field-by-field rationale.
data SubagentRunRecord = SubagentRunRecord
  { rrrRunId                    :: !RunId
    -- ^ Unique run identifier (the 'SubagentId' text).
  , rrrSubagentId               :: !SubagentId
    -- ^ The 'SubagentId' for cross-referencing with 'AgentRuntime'.
  , rrrChildSessionKey          :: !SessionId
    -- ^ The child's session ID.
  , rrrParentSessionKey         :: !SessionId
    -- ^ The parent's session ID.
  , rrrControllerSessionKey     :: !SessionId
    -- ^ Who controls this run (usually the parent).
  , rrrStartedAt                :: !UTCTime
    -- ^ When the run was created.
  , rrrEndedAt                  :: !(Maybe UTCTime)
    -- ^ Set when the run reaches a terminal state.
  , rrrOutcome                  :: !RunOutcome
    -- ^ Terminal outcome (ok \/ error \/ timeout \/ killed \/ unknown).
  , rrrEndedReason              :: !(Maybe EndReason)
    -- ^ Why the run ended.
  , rrrExpectsCompletionMessage :: !Bool
    -- ^ Does the parent want push notification? 'False' for foreground mode.
  , rrrFrozenResultText         :: !(Maybe Text)
    -- ^ The child's final output, captured at completion.
  , rrrAnnounceRetryCount       :: !Int
    -- ^ Delivery retry counter.
  , rrrLastAnnounceRetryAt      :: !(Maybe UTCTime)
    -- ^ When the last delivery retry was attempted.
  , rrrSpawnMode                :: !SpawnMode
    -- ^ Foreground (blocking) or background (async with push).
  , rrrCleanup                  :: !CleanupMode
    -- ^ Whether to delete or keep the child session on completion.
  , rrrDepth                    :: !Int
    -- ^ Spawn depth (guard against runaway recursion).
  , rrrWakeOnDescendantSettle   :: !Bool
    -- ^ Re-invoke the child after its own descendants finish.
  , rrrCleanupHandled           :: !Bool
    -- ^ Has session cleanup been performed?
  , rrrCleanupCompletedAt       :: !(Maybe UTCTime)
    -- ^ When cleanup was completed.
  , rrrEndedHookEmittedAt       :: !(Maybe UTCTime)
    -- ^ When the @subagent_ended@ hook was emitted (idempotency guard).
  , rrrSuppressAnnounceReason   :: !(Maybe Text)
    -- ^ If set, completion announcement is suppressed (e.g. \"killed\").
  , rrrGenerationToken          :: !(Maybe GenerationToken)
    -- ^ Unique per-spawn token; stale tokens are rejected by 'completeRun'.
  } deriving stock (Eq, Show)
    deriving (Generic)

instance ToJSON SubagentRunRecord where
  toJSON r = object
    [ "run_id"                     .= rrrRunId r
    , "subagent_id"                .= subagentIdText (rrrSubagentId r)
    , "child_session_key"          .= sessionIdText (rrrChildSessionKey r)
    , "parent_session_key"         .= sessionIdText (rrrParentSessionKey r)
    , "controller_session_key"     .= sessionIdText (rrrControllerSessionKey r)
    , "started_at"                 .= rrrStartedAt r
    , "ended_at"                   .= rrrEndedAt r
    , "outcome"                    .= rrrOutcome r
    , "ended_reason"               .= rrrEndedReason r
    , "expects_completion_message" .= rrrExpectsCompletionMessage r
    , "frozen_result_text"         .= rrrFrozenResultText r
    , "announce_retry_count"       .= rrrAnnounceRetryCount r
    , "last_announce_retry_at"     .= rrrLastAnnounceRetryAt r
    , "spawn_mode"                 .= rrrSpawnMode r
    , "cleanup"                    .= rrrCleanup r
    , "depth"                      .= rrrDepth r
    , "wake_on_descendant_settle"  .= rrrWakeOnDescendantSettle r
    , "cleanup_handled"            .= rrrCleanupHandled r
    , "cleanup_completed_at"       .= rrrCleanupCompletedAt r
    , "ended_hook_emitted_at"      .= rrrEndedHookEmittedAt r
    , "suppress_announce_reason"   .= rrrSuppressAnnounceReason r
    , "generation_token"           .= rrrGenerationToken r
    ]

instance FromJSON SubagentRunRecord where
  parseJSON = withObject "SubagentRunRecord" $ \o -> do
    runId          <- o .:  "run_id"
    subagentIdT    <- o .:  "subagent_id"
    childSessionT  <- o .:  "child_session_key"
    parentSessionT <- o .:  "parent_session_key"
    controllerT    <- o .:  "controller_session_key"
    startedAt      <- o .:  "started_at"
    endedAt        <- o .:? "ended_at"
    outcome        <- o .:  "outcome"
    endedReason    <- o .:? "ended_reason"
    expectsMsg     <- o .:  "expects_completion_message"
    frozenResult   <- o .:? "frozen_result_text"
    retryCount     <- o .:  "announce_retry_count"
    lastRetryAt    <- o .:? "last_announce_retry_at"
    spawnMode      <- o .:  "spawn_mode"
    cleanup        <- o .:  "cleanup"
    depth          <- o .:  "depth"
    wakeOnSettle   <- o .:  "wake_on_descendant_settle"
    cleanupHandled <- o .:  "cleanup_handled"
    cleanupDoneAt  <- o .:? "cleanup_completed_at"
    hookEmittedAt  <- o .:? "ended_hook_emitted_at"
    suppressReason <- o .:? "suppress_announce_reason"
    genToken       <- o .:? "generation_token"
    pure SubagentRunRecord
      { rrrRunId                    = runId
      , rrrSubagentId               = SubagentId subagentIdT
      , rrrChildSessionKey          = mkSystemSessionId childSessionT
      , rrrParentSessionKey         = mkSystemSessionId parentSessionT
      , rrrControllerSessionKey     = mkSystemSessionId controllerT
      , rrrStartedAt                = startedAt
      , rrrEndedAt                  = endedAt
      , rrrOutcome                  = outcome
      , rrrEndedReason              = endedReason
      , rrrExpectsCompletionMessage = expectsMsg
      , rrrFrozenResultText         = frozenResult
      , rrrAnnounceRetryCount       = retryCount
      , rrrLastAnnounceRetryAt      = lastRetryAt
      , rrrSpawnMode                = spawnMode
      , rrrCleanup                  = cleanup
      , rrrDepth                    = depth
      , rrrWakeOnDescendantSettle   = wakeOnSettle
      , rrrCleanupHandled           = cleanupHandled
      , rrrCleanupCompletedAt       = cleanupDoneAt
      , rrrEndedHookEmittedAt       = hookEmittedAt
      , rrrSuppressAnnounceReason   = suppressReason
      , rrrGenerationToken          = genToken
      }

----------------------------------------------------------------------------
-- Registry
----------------------------------------------------------------------------

-- | The STM-backed registry of run records, keyed by 'RunId'. Thread-safe.
-- Lifecycle hooks are stored in an 'IORef' list (appended on registration).
data RunRecordRegistry = RunRecordRegistry
  { rrrRegistry :: !(TVar (Map RunId SubagentRunRecord))
  , rrrHooks    :: !(IORef [SubagentRunRecord -> IO ()])
  }

-- | Build an empty registry.
newRunRecordRegistry :: IO RunRecordRegistry
newRunRecordRegistry = do
  tv <- newTVarIO Map.empty
  hooksRef <- newIORef []
  pure (RunRecordRegistry tv hooksRef)

----------------------------------------------------------------------------
-- Operations
----------------------------------------------------------------------------

-- | Create a new run record and store it in the registry. The generation
-- token is freshly minted; 'completeRun' will reject calls with a
-- different token.
createRun
  :: RunRecordRegistry
  -> SubagentId
  -> SessionId
     -- ^ child session
  -> SessionId
     -- ^ parent session (also the controller by default)
  -> Int
     -- ^ spawn depth
  -> SpawnMode
  -> IO SubagentRunRecord
createRun reg subagentId childSid parentSid depth mode = do
  now <- getCurrentTime
  token <- GenerationToken <$> randomRIO (1, maxBound :: Int)
  let runId = subagentIdText subagentId
      expectsMsg = case mode of
        SpawnForeground -> False
        SpawnBackground -> True
      rec = SubagentRunRecord
        { rrrRunId                    = runId
        , rrrSubagentId               = subagentId
        , rrrChildSessionKey          = childSid
        , rrrParentSessionKey         = parentSid
        , rrrControllerSessionKey     = parentSid
        , rrrStartedAt                = now
        , rrrEndedAt                  = Nothing
        , rrrOutcome                  = OutcomeUnknown
        , rrrEndedReason              = Nothing
        , rrrExpectsCompletionMessage = expectsMsg
        , rrrFrozenResultText         = Nothing
        , rrrAnnounceRetryCount       = 0
        , rrrLastAnnounceRetryAt      = Nothing
        , rrrSpawnMode                = mode
        , rrrCleanup                  = CleanupDelete
        , rrrDepth                    = depth
        , rrrWakeOnDescendantSettle   = False
        , rrrCleanupHandled           = False
        , rrrCleanupCompletedAt       = Nothing
        , rrrEndedHookEmittedAt       = Nothing
        , rrrSuppressAnnounceReason   = Nothing
        , rrrGenerationToken          = Just token
        }
  atomically $ modifyTVar' (rrrRegistry reg) (Map.insert runId rec)
  pure rec

-- | Mark a run as completed. Checks the generation token — if the token
-- doesn't match (or is 'Nothing' when the record has one), the call is
-- rejected (returns 'Nothing'). This prevents stale completions from
-- corrupting re-spawned jobs. Idempotent: completing an already-completed
-- run returns 'Nothing'. Emits the @subagent_ended@ lifecycle hook exactly
-- once (guarded by 'rrrEndedHookEmittedAt').
completeRun
  :: RunRecordRegistry
  -> RunId
  -> Maybe GenerationToken
  -> ChildResult
  -> UTCTime
  -> IO (Maybe SubagentRunRecord)
completeRun reg runId mToken result now = do
  mRec <- atomically $ do
    records <- readTVar (rrrRegistry reg)
    case Map.lookup runId records of
      Nothing -> pure Nothing
      Just rec
        | isJust (rrrEndedAt rec) -> pure Nothing
            -- Already completed — idempotent no-op.
        | tokenMismatch (rrrGenerationToken rec) mToken -> pure Nothing
            -- Stale token — reject.
        | otherwise -> do
            let (outcome, endReason) = outcomeForResult result
                rec' = rec
                  { rrrEndedAt = Just now
                  , rrrOutcome = outcome
                  , rrrEndedReason = Just endReason
                  , rrrFrozenResultText = frozenText result
                  , rrrEndedHookEmittedAt = Just now
                  }
            writeTVar (rrrRegistry reg) (Map.insert runId rec' records)
            pure (Just rec')
  -- Emit lifecycle hooks OUTSIDE the STM transaction (callbacks are IO).
  forM_ mRec $ \rec -> do
    hooks <- readIORef (rrrHooks reg)
    forM_ hooks $ \hook -> hook rec
  pure mRec

-- | List all runs for a given parent session.
listRunsForParent :: RunRecordRegistry -> SessionId -> IO [SubagentRunRecord]
listRunsForParent reg parentSid = do
  records <- readTVarIO (rrrRegistry reg)
  pure (filter (\r -> rrrParentSessionKey r == parentSid)
               (Map.elems records))

-- | Find the latest run for a given child session (most recently created).
findLatestRunForChild
  :: RunRecordRegistry -> SessionId -> IO (Maybe SubagentRunRecord)
findLatestRunForChild reg childSid = do
  records <- readTVarIO (rrrRegistry reg)
  let matching = filter (\r -> rrrChildSessionKey r == childSid)
                         (Map.elems records)
  pure (case matching of
          [] -> Nothing
          xs -> Just (latestByStartedAt xs))
  where
    latestByStartedAt = foldr1 (\a b ->
      if rrrStartedAt a >= rrrStartedAt b then a else b)

-- | Count non-terminal (pending) runs for a given session as parent.
countPendingDescendants :: RunRecordRegistry -> SessionId -> IO Int
countPendingDescendants reg parentSid = do
  records <- readTVarIO (rrrRegistry reg)
  pure (length (filter (\r -> rrrParentSessionKey r == parentSid
                          && isNothing (rrrEndedAt r))
                       (Map.elems records)))

-- | Cancel all pending runs for a parent session. Marks them as killed and
-- sets the suppress reason. Returns the cancelled records. Already-
-- completed runs are not affected.
cancelRunsForParent
  :: RunRecordRegistry
  -> SessionId
  -> UTCTime
  -> Text
     -- ^ suppress reason (e.g. \"killed\")
  -> IO [SubagentRunRecord]
cancelRunsForParent reg parentSid now reason = do
  cancelled <- atomically $ do
    records <- readTVar (rrrRegistry reg)
    let pending = filter (\r -> rrrParentSessionKey r == parentSid
                                && isNothing (rrrEndedAt r))
                         (Map.elems records)
        updated = map (\r -> r { rrrEndedAt = Just now
                               , rrrOutcome = OutcomeKilled
                               , rrrEndedReason = Just EndKilled
                               , rrrSuppressAnnounceReason = Just reason
                               , rrrEndedHookEmittedAt = Just now
                               })
                      pending
        newMap = foldr (\r m -> Map.insert (rrrRunId r) r m) records updated
    writeTVar (rrrRegistry reg) newMap
    pure updated
  -- Emit hooks for cancelled runs
  hooks <- readIORef (rrrHooks reg)
  forM_ cancelled $ \rec -> forM_ hooks $ \hook -> hook rec
  pure cancelled

----------------------------------------------------------------------------
-- Lifecycle hooks
----------------------------------------------------------------------------

-- | Register a callback to be invoked when a run reaches a terminal state
-- (completion or cancellation). The callback receives the final
-- 'SubagentRunRecord'. Callbacks are called outside STM transactions.
registerEndedHook
  :: RunRecordRegistry -> (SubagentRunRecord -> IO ()) -> IO ()
registerEndedHook reg hook =
  atomicModifyIORef' (rrrHooks reg) (\hooks -> (hooks ++ [hook], ()))

----------------------------------------------------------------------------
-- Persistence
----------------------------------------------------------------------------

-- | The file path for a run record on disk.
runRecordPath :: FilePath -> RunId -> FilePath
runRecordPath sessionDirPath runId =
  sessionDirPath </> "agents" </> T.unpack runId </> "run-record.json"

-- | Save a run record to disk as JSON (atomic write). Creates the parent
-- directory if needed. Best-effort: IO errors are swallowed.
saveRunRecordToDisk :: FilePath -> SubagentRunRecord -> IO ()
saveRunRecordToDisk sessionDirPath rec = do
  let path = runRecordPath sessionDirPath (rrrRunId rec)
      tmp  = path <.> "tmp"
  eWrite <- try @IOException $ do
    createDirectoryIfMissing True (takeDirectory path)
    BS.writeFile tmp (BSL.toStrict (encode rec))
    renameFile tmp path
  case eWrite of
    Left _err -> pure ()  -- best-effort
    Right _   -> pure ()

-- | Load a run record from a JSON file. Returns 'Nothing' if the file
-- doesn't exist or can't be parsed.
loadRunRecord :: FilePath -> RunId -> IO (Maybe SubagentRunRecord)
loadRunRecord sessionDirPath runId = do
  let path = runRecordPath sessionDirPath runId
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      eRaw <- try @IOException (BS.readFile path)
      case eRaw of
        Left _ -> pure Nothing
        Right raw -> case eitherDecodeStrict' raw of
          Left _   -> pure Nothing
          Right rec -> pure (Just rec)

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

-- | Check whether a provided token matches the record's token.
tokenMismatch :: Maybe GenerationToken -> Maybe GenerationToken -> Bool
tokenMismatch (Just expected) (Just provided) = expected /= provided
tokenMismatch (Just _)        Nothing         = True
tokenMismatch Nothing         _               = False

-- | Map a 'ChildResult' to its 'RunOutcome' and 'EndReason'.
outcomeForResult :: ChildResult -> (RunOutcome, EndReason)
outcomeForResult result =
  case crStatus result of
    CsCompleted   -> (OutcomeOk, EndComplete)
    CsFailed      -> (OutcomeOk, EndComplete)
    CsTimeout     -> (OutcomeTimeout, EndTimeout)
    CsInterrupted -> (OutcomeKilled, EndKilled)
    CsError       -> (OutcomeError, EndError)

-- | Extract the frozen result text from a 'ChildResult'. Prefers the
-- summary; falls back to the error message.
frozenText :: ChildResult -> Maybe Text
frozenText result =
  case crSummary result of
    Just s  -> Just s
    Nothing -> crError result
