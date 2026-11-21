{-# LANGUAGE OverloadedStrings #-}
-- | The cron scheduler: a background thread that ticks at a configurable
-- interval, checks for due jobs, and fires them via a 'CronFireDelegate'.
-- Includes anti-runaway blocklist, overlap protection, max concurrent runs,
-- error handling (backoff + auto-disable), and one-shot auto-disable.
module Seal.Cron.Scheduler
  ( CronScheduler (..)
  , startCronScheduler
  , tick
  , cronSpawnBlocklist
  , defaultTickInterval
  , defaultMaxConcurrent
  , maxConsecutiveFailures
  , backoffDelays
  , applyRunOutcome
  , markRunning
  , isRunActive
  , cronStaleAfterSeconds
  , reconcileStaleRuns
  , checkAutoDisable
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, readTVarIO)
import Control.Monad (when, unless)
import Data.Maybe (fromMaybe)
import Data.Int (Int64)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, diffUTCTime)
import Seal.Core.Types (OpName (..))
import Seal.Core.Types qualified as SCT (sessionIdText)
import Seal.Cron.Types
import Seal.Cron.Store
import Seal.ISA.Ops.Cron (CronFireDelegate)

-- | Opcodes removed from cron-spawned session registries.
-- These are removed via 'filterBlocklistedWith' (ops-list removal, not
-- catalog hiding) so 'lookupOp' returns 'Nothing' for them.
cronSpawnBlocklist :: Set OpName
cronSpawnBlocklist = Set.fromList
  [ OpName "CRON_MANAGE"
  , OpName "SECRET_MANAGE"
  , OpName "AGENT_MANAGE"
  , OpName "AGENT_DEF_MANAGE"
  ]

-- | Default tick interval in seconds (60s).
defaultTickInterval :: Int
defaultTickInterval = 60

-- | Default max concurrent cron runs.
defaultMaxConcurrent :: Int
defaultMaxConcurrent = 5

-- | Max consecutive failures before auto-disable.
maxConsecutiveFailures :: Int
maxConsecutiveFailures = 5

-- | Exponential backoff delays in seconds: 30s → 1m → 5m → 15m → 60m.
backoffDelays :: [Int]
backoffDelays = [30, 60, 300, 900, 3600]

-- | The scheduler configuration. The 'csFireDelegate' fires a job and
-- returns the spawned session id. The 'csNotifyHuman' callback is used
-- for SHOW_HUMAN notifications (e.g. auto-disable after failures).
-- The 'csClock' is injectable for deterministic testing.
data CronScheduler = CronScheduler
  { csStore         :: CronStore
  , csFireDelegate  :: CronFireDelegate
  , csClock         :: IO UTCTime
  , csTickInterval  :: Int               -- ^ seconds
  , csStopSignal    :: TVar Bool
  , csMaxConcurrent :: Int
  , csNotifyHuman   :: Text -> IO ()     -- ^ SHOW_HUMAN callback
  }

-- | Start the cron scheduler. Forks a thread that ticks every
-- 'csTickInterval' seconds, checks for due jobs, and fires them.
-- Returns immediately (the scheduler runs in a forked thread).
startCronScheduler :: CronScheduler -> IO ()
startCronScheduler scheduler = do
  stop <- readTVarIO (csStopSignal scheduler)
  unless stop $ do
    tick scheduler
    threadDelay (csTickInterval scheduler * 1_000_000)
    startCronScheduler scheduler

-- | One tick: check for due jobs and fire them.
tick :: CronScheduler -> IO ()
tick scheduler = do
  now <- csClock scheduler
  jobs <- csList (csStore scheduler) True  -- enabled only
  mapM_ (fireIfDue scheduler now) jobs

-- | Fire a job if it's due (next_fire <= now) and not overlapping.
-- The next fire time is computed from the job's last fire time (or
-- creation time if never fired), not from @now@ — this is the standard
-- cron pattern: "the scheduled time for the next run has arrived."
-- Computing from @now@ would always return a future time (the next
-- minute boundary after now), so no job would ever be due.
fireIfDue :: CronScheduler -> UTCTime -> CronJob -> IO ()
fireIfDue scheduler now job = do
  let refTime = fromMaybe (cjCreatedAt job) (cjLastFire job)
  mNextFire <- computeNextFire (cjSchedule job) (cjTimezone job) refTime
  case mNextFire of
    Nothing -> pure ()
    Just nextFire
      | nextFire > now -> pure ()  -- next scheduled fire is still in the future
      | otherwise -> do
          -- Check overlap: previous run still pending/running
          runs <- csListRuns (csStore scheduler) (cjId job) 1
          case runs of
            (r:_) | isRunActive now r -> pure ()  -- overlap, skip
            _ -> do
              -- Check max concurrent
              activeCount <- countActiveRuns scheduler now
              when (activeCount < csMaxConcurrent scheduler) $ do
                fireJob scheduler now job

-- | Count currently active runs (Pending or Running) across all jobs.
countActiveRuns :: CronScheduler -> UTCTime -> IO Int
countActiveRuns scheduler now = do
  allJobs <- csList (csStore scheduler) True
  activeRuns <- mapM countJobActive allJobs
  pure (sum activeRuns)
  where
    countJobActive job = do
      runs <- csListRuns (csStore scheduler) (cjId job) 10
      pure (length (filter (isRunActive now) runs))

-- | Fire a single job: record a Pending run, call the fire delegate,
-- update the run status on completion.
fireJob :: CronScheduler -> UTCTime -> CronJob -> IO ()
fireJob scheduler now job = do
  let jid = cjId job
  -- Record a Pending run
  let pendingRun = CronRun
        { crJobId = jid
        , crSessionId = ""  -- stamped once the delegate returns a session id
        , crStartedAt = now
        , crEndedAt = Nothing
        , crStatus = CrPending
        , crError = Nothing
        }
  -- Persist the run BEFORE firing. The dispatcher's ACK-before-execute
  -- principle applies here for the same reason: a completion callback can
  -- arrive as soon as the turn starts, and it can only update a row that
  -- already exists. (The original code only wrote a row after the delegate
  -- returned, so a fast turn's completion matched nothing and the job wedged.)
  csRecordRun (csStore scheduler) jid pendingRun
  -- Fire the job
  eResult <- csFireDelegate scheduler job
  case eResult of
    Left err -> do
      -- Fire failed: move the pending row to Failed
      csUpdateRun (csStore scheduler) jid
        (applyRunOutcome now (Left err))
      -- Check consecutive failures for auto-disable
      checkAutoDisable (csStore scheduler) (csNotifyHuman scheduler) now job
    Right sessionId -> do
      -- Fire succeeded: stamp the session id and move Pending -> Running.
      -- If a completion already landed, markRunning leaves the terminal row
      -- alone (terminal rows are never regressed).
      csUpdateRun (csStore scheduler) jid
        (markRunning (SCT.sessionIdText sessionId) now)
      -- Update job's lastFire and runCount
      updateJobAfterFire scheduler now job
      -- One-shot auto-disable
      when (cjOneShot job) $ do
        mJob <- csRead (csStore scheduler) jid
        case mJob of
          Just j -> do
            now' <- csClock scheduler
            csSave (csStore scheduler) j { cjEnabled = False, cjUpdatedAt = now' }
          Nothing -> pure ()

-- | Is this run still occupying a concurrency slot at @now@?
--
-- A run counts as active only while it is genuinely in flight. Two things make
-- that false: a terminal status, and a run older than 'cronStaleAfterSeconds'
-- (whose completion callback was lost, or which belonged to a process that
-- died). Without the age bound, a single lost completion wedges scheduling
-- until restart; that is the bug this predicate exists to prevent.
isRunActive :: UTCTime -> CronRun -> Bool
isRunActive now r =
  (crStatus r == CrPending || crStatus r == CrRunning)
    && diffUTCTime now (crStartedAt r) < fromIntegral cronStaleAfterSeconds

-- | How long a Pending/Running run is trusted before it is treated as stale.
-- Six hours: long enough that no realistic turn is cut off (a turn that runs
-- longer has its own problems), short enough that a lost completion recovers
-- without an operator restarting the daemon.
cronStaleAfterSeconds :: Int64
cronStaleAfterSeconds = 6 * 60 * 60

-- | Apply a turn outcome to a run row. Idempotent: an already-terminal row is
-- returned unchanged, so a duplicate completion callback cannot regress a
-- completed run back to failed.
applyRunOutcome :: UTCTime -> Either Text () -> CronRun -> CronRun
applyRunOutcome now outcome r
  | isTerminal (crStatus r) = r
  | otherwise = case outcome of
      Right () -> r { crStatus = CrCompleted, crEndedAt = Just now }
      Left e   -> r { crStatus = CrFailed, crEndedAt = Just now, crError = Just e }

-- | Stamp the session id and move @Pending -> Running@. Leaves a terminal row
-- alone: a completion can arrive before the delegate returns, and the late
-- "Running" write must not overwrite it.
markRunning :: Text -> UTCTime -> CronRun -> CronRun
markRunning sid _now r
  | isTerminal (crStatus r) = r
  | otherwise = r { crSessionId = sid, crStatus = CrRunning }

isTerminal :: CronRunStatus -> Bool
isTerminal CrCompleted = True
isTerminal CrFailed    = True
isTerminal _           = False

-- | Mark every run left @Pending@/@Running@ as failed, returning how many were
-- repaired. Called once at startup: a row still active at process start cannot
-- belong to the current process, so no turn can be in flight for it. Without
-- this, a store wedged by the completion bug would stay wedged after the fix
-- ships.
reconcileStaleRuns :: CronStore -> UTCTime -> IO Int
reconcileStaleRuns store now = do
  jobs <- csList store False
  counts <- mapM (reconcileJob store now) jobs
  pure (sum counts)

-- | Reconcile one job's run history. Every row still marked Pending/Running is
-- repairable regardless of age: at startup the current process has performed no
-- fires, so *any* active row belongs to a previous process, and no turn can be
-- in flight for it. 'csUpdateRun' maps the transformation over the whole
-- history, which is what repairs a store wedged by repeated fires rather than
-- only its newest row.
reconcileJob :: CronStore -> UTCTime -> CronJob -> IO Int
reconcileJob store now job = do
  runs <- csListRuns store (cjId job) maxRetainedRuns
  let stale = length (filter isStillActive runs)
  when (stale > 0) $
    csUpdateRun store (cjId job) (applyRunOutcome now (Left reconcileMessage))
  pure stale
  where
    isStillActive r = crStatus r == CrPending || crStatus r == CrRunning

-- | The store's run-retention window. Reconciliation inspects this many rows so
-- no row the store would show is left unrepaired.
maxRetainedRuns :: Int
maxRetainedRuns = 100

reconcileMessage :: Text
reconcileMessage =
  "reconciled at startup: run did not complete before the previous process exited"

-- | Update job's lastFire and runCount after a successful fire.
updateJobAfterFire :: CronScheduler -> UTCTime -> CronJob -> IO ()
updateJobAfterFire scheduler now job = do
  csSave (csStore scheduler) job
    { cjLastFire = Just now
    , cjRunCount = cjRunCount job + 1
    , cjUpdatedAt = now
    }

-- | Check if a job should be auto-disabled after consecutive failures.
checkAutoDisable :: CronStore -> (Text -> IO ()) -> UTCTime -> CronJob -> IO ()
checkAutoDisable store notifyHuman now job = do
  runs <- csListRuns store (cjId job) maxConsecutiveFailures
  let recentFailures = length (filter (\r -> crStatus r == CrFailed) runs)
  when (recentFailures >= maxConsecutiveFailures) $ do
    -- Auto-disable the job
    csSave store job
      { cjEnabled = False
      , cjUpdatedAt = now
      , cjConsecutiveFailures = recentFailures
      }
    -- Notify operator via SHOW_HUMAN
    notifyHuman
      ("cron job '" <> cjName job <> "' (id: " <> cronJobIdText (cjId job)
       <> ") auto-disabled after " <> T.pack (show maxConsecutiveFailures) <> " consecutive failures")
