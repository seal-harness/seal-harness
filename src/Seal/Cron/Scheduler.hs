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
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, readTVarIO)
import Control.Monad (when, unless)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
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
fireIfDue :: CronScheduler -> UTCTime -> CronJob -> IO ()
fireIfDue scheduler now job = do
  mNextFire <- computeNextFire (cjSchedule job) (cjTimezone job) now
  case mNextFire of
    Nothing -> pure ()
    Just nextFire
      | nextFire > now -> pure ()  -- not due yet
      | otherwise -> do
          -- Check overlap: previous run still pending/running
          runs <- csListRuns (csStore scheduler) (cjId job) 1
          case runs of
            (r:_) | crStatus r == CrPending || crStatus r == CrRunning -> pure ()  -- overlap, skip
            _ -> do
              -- Check max concurrent
              activeCount <- countActiveRuns scheduler
              when (activeCount < csMaxConcurrent scheduler) $ do
                fireJob scheduler now job

-- | Count currently active runs (Pending or Running) across all jobs.
countActiveRuns :: CronScheduler -> IO Int
countActiveRuns scheduler = do
  allJobs <- csList (csStore scheduler) True
  activeRuns <- mapM countJobActive allJobs
  pure (sum activeRuns)
  where
    countJobActive job = do
      runs <- csListRuns (csStore scheduler) (cjId job) 10
      pure (length (filter isActive runs))
    isActive r = crStatus r == CrPending || crStatus r == CrRunning

-- | Fire a single job: record a Pending run, call the fire delegate,
-- update the run status on completion.
fireJob :: CronScheduler -> UTCTime -> CronJob -> IO ()
fireJob scheduler now job = do
  let jid = cjId job
  -- Record a Pending run
  let pendingRun = CronRun
        { crJobId = jid
        , crSessionId = ""  -- filled in after fire
        , crStartedAt = now
        , crEndedAt = Nothing
        , crStatus = CrPending
        , crError = Nothing
        }
  -- Fire the job
  eResult <- csFireDelegate scheduler job
  case eResult of
    Left err -> do
      -- Fire failed: record a Failed run
      let failedRun = pendingRun
            { crStatus = CrFailed
            , crEndedAt = Just now
            , crError = Just err
            }
      csRecordRun (csStore scheduler) jid failedRun
      -- Check consecutive failures for auto-disable
      checkAutoDisable scheduler now job
    Right sessionId -> do
      -- Fire succeeded: record a Running run
      let runningRun = pendingRun
            { crSessionId = SCT.sessionIdText sessionId
            , crStatus = CrRunning
            }
      csRecordRun (csStore scheduler) jid runningRun
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

-- | Update job's lastFire and runCount after a successful fire.
updateJobAfterFire :: CronScheduler -> UTCTime -> CronJob -> IO ()
updateJobAfterFire scheduler now job = do
  csSave (csStore scheduler) job
    { cjLastFire = Just now
    , cjRunCount = cjRunCount job + 1
    , cjUpdatedAt = now
    }

-- | Check if a job should be auto-disabled after consecutive failures.
checkAutoDisable :: CronScheduler -> UTCTime -> CronJob -> IO ()
checkAutoDisable scheduler now job = do
  runs <- csListRuns (csStore scheduler) (cjId job) maxConsecutiveFailures
  let recentFailures = length (filter (\r -> crStatus r == CrFailed) runs)
  when (recentFailures >= maxConsecutiveFailures) $ do
    -- Auto-disable the job
    csSave (csStore scheduler) job
      { cjEnabled = False
      , cjUpdatedAt = now
      , cjConsecutiveFailures = recentFailures
      }
    -- Notify operator via SHOW_HUMAN
    csNotifyHuman scheduler
      ("cron job '" <> cjName job <> "' (id: " <> cronJobIdText (cjId job)
       <> ") auto-disabled after " <> T.pack (show maxConsecutiveFailures) <> " consecutive failures")
