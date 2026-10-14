{-# LANGUAGE OverloadedStrings #-}
module Seal.Cron.SchedulerSpec (spec) where

import Data.IORef
import Control.Monad (replicateM_)
import Data.Set qualified as Set
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import Seal.Core.Types (OpName (..), mkSystemSessionId)
import Seal.Cron.Types
import Seal.Cron.Store
import Seal.Cron.Scheduler

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 10 14) (secondsToDiffTime (9 * 3600))

sampleJobId :: CronJobId
sampleJobId = case mkCronJobId "test-job" of Right j -> j; Left _ -> error "u"

sampleJob :: CronJob
sampleJob = CronJob
  { cjId = sampleJobId
  , cjName = "Test Job"
  , cjSchedule = case mkCronExpr "* * * * *" of Right e -> e; Left _ -> error "u"
  , cjTimezone = Nothing
  , cjPrompt = "Run test"
  , cjAgentDefId = Nothing
  , cjEnabled = True
  , cjOneShot = False
  , cjCreatedAt = sampleTime
  , cjUpdatedAt = sampleTime
  , cjLastFire = Nothing
  , cjRunCount = 0
  , cjConsecutiveFailures = 0
  }

spec :: Spec
spec = do
  describe "cronSpawnBlocklist" $ do
    it "contains CRON_MANAGE, SECRET_MANAGE, AGENT_MANAGE, AGENT_DEF_MANAGE" $ do
      Set.member (OpName "CRON_MANAGE") cronSpawnBlocklist `shouldBe` True
      Set.member (OpName "SECRET_MANAGE") cronSpawnBlocklist `shouldBe` True
      Set.member (OpName "AGENT_MANAGE") cronSpawnBlocklist `shouldBe` True
      Set.member (OpName "AGENT_DEF_MANAGE") cronSpawnBlocklist `shouldBe` True

    it "does NOT contain non-blocklisted opcodes" $ do
      Set.member (OpName "SHOW_HUMAN") cronSpawnBlocklist `shouldBe` False
      Set.member (OpName "FILE_READ") cronSpawnBlocklist `shouldBe` False
      Set.member (OpName "SHELL_EXEC") cronSpawnBlocklist `shouldBe` False

  describe "tick" $ do
    it "fires a due job" $ do
      store <- memoryCronStore
      csCreate store sampleJob
      fireCount <- newIORef (0 :: Int)
      let scheduler = CronScheduler
            { csStore = store
            , csFireDelegate = \_job -> do
                modifyIORef' fireCount (+1)
                pure (Right (mkSystemSessionId "cron-session-1"))
            , csClock = pure sampleTime
            , csTickInterval = 60
            , csStopSignal = error "unused in tick"
            , csMaxConcurrent = 5
            , csNotifyHuman = \_ -> pure ()
            }
      tick scheduler
      count <- readIORef fireCount
      count `shouldBe` 1
      -- Check run was recorded
      runs <- csListRuns store sampleJobId 10
      length runs `shouldBe` 1

    it "does not fire disabled jobs" $ do
      store <- memoryCronStore
      csCreate store sampleJob { cjEnabled = False }
      fireCount <- newIORef (0 :: Int)
      let scheduler = CronScheduler
            { csStore = store
            , csFireDelegate = \_job -> do
                modifyIORef' fireCount (+1)
                pure (Right (mkSystemSessionId "cron-session-1"))
            , csClock = pure sampleTime
            , csTickInterval = 60
            , csStopSignal = error "unused in tick"
            , csMaxConcurrent = 5
            , csNotifyHuman = \_ -> pure ()
            }
      tick scheduler
      count <- readIORef fireCount
      count `shouldBe` 0

    it "records error on fire failure" $ do
      store <- memoryCronStore
      csCreate store sampleJob
      let scheduler = CronScheduler
            { csStore = store
            , csFireDelegate = \_job -> pure (Left "agent def not found")
            , csClock = pure sampleTime
            , csTickInterval = 60
            , csStopSignal = error "unused in tick"
            , csMaxConcurrent = 5
            , csNotifyHuman = \_ -> pure ()
            }
      tick scheduler
      runs <- csListRuns store sampleJobId 10
      length runs `shouldBe` 1
      case runs of
        (r:_) -> crStatus r `shouldBe` CrFailed
        [] -> False `shouldBe` True

    it "auto-disables after consecutive failures" $ do
      store <- memoryCronStore
      csCreate store sampleJob
      -- Pre-populate 4 failed runs
      let failedRun = CronRun
            { crJobId = sampleJobId
            , crSessionId = ""
            , crStartedAt = sampleTime
            , crEndedAt = Just sampleTime
            , crStatus = CrFailed
            , crError = Just "error"
            }
      replicateM_ 4 (csRecordRun store sampleJobId failedRun)
      notified <- newIORef False
      let scheduler = CronScheduler
            { csStore = store
            , csFireDelegate = \_job -> pure (Left "another failure")
            , csClock = pure sampleTime
            , csTickInterval = 60
            , csStopSignal = error "unused in tick"
            , csMaxConcurrent = 5
            , csNotifyHuman = \_msg -> writeIORef notified True
            }
      tick scheduler
      -- Job should be disabled
      mJob <- csRead store sampleJobId
      case mJob of
        Just job -> cjEnabled job `shouldBe` False
        Nothing -> False `shouldBe` True
      -- Operator should be notified
      wasNotified <- readIORef notified
      wasNotified `shouldBe` True

    it "auto-disables one-shot job after first fire" $ do
      store <- memoryCronStore
      csCreate store sampleJob { cjOneShot = True }
      let scheduler = CronScheduler
            { csStore = store
            , csFireDelegate = \_job -> pure (Right (mkSystemSessionId "cron-1"))
            , csClock = pure sampleTime
            , csTickInterval = 60
            , csStopSignal = error "unused in tick"
            , csMaxConcurrent = 5
            , csNotifyHuman = \_ -> pure ()
            }
      tick scheduler
      mJob <- csRead store sampleJobId
      case mJob of
        Just job -> cjEnabled job `shouldBe` False
        Nothing -> False `shouldBe` True

    it "skips overlapping job (previous run still running)" $ do
      store <- memoryCronStore
      csCreate store sampleJob
      -- Pre-populate a Running run
      let runningRun = CronRun
            { crJobId = sampleJobId
            , crSessionId = "prev-session"
            , crStartedAt = sampleTime
            , crEndedAt = Nothing
            , crStatus = CrRunning
            , crError = Nothing
            }
      csRecordRun store sampleJobId runningRun
      fireCount <- newIORef (0 :: Int)
      let scheduler = CronScheduler
            { csStore = store
            , csFireDelegate = \_job -> do
                modifyIORef' fireCount (+1)
                pure (Right (mkSystemSessionId "cron-2"))
            , csClock = pure sampleTime
            , csTickInterval = 60
            , csStopSignal = error "unused in tick"
            , csMaxConcurrent = 5
            , csNotifyHuman = \_ -> pure ()
            }
      tick scheduler
      count <- readIORef fireCount
      count `shouldBe` 0  -- should skip due to overlap
