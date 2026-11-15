{-# LANGUAGE OverloadedStrings #-}
module Seal.Cron.SchedulerSpec (spec) where

import Data.Int (Int64)
import Data.IORef
import Control.Monad (replicateM_)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import Seal.Core.Types (OpName (..), mkSystemSessionId, sessionIdText)
import Seal.Cron.Types
import Seal.Cron.Store
import Seal.Cron.Scheduler

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 10 14) (secondsToDiffTime (9 * 3600))

-- | Two minutes before sampleTime. Jobs created at this time with a
-- @* * * * *@ schedule have a next-fire (the minute after creation) that
-- is in the past relative to @sampleTime@, so @tick@ considers them due.
createdTime :: UTCTime
createdTime = UTCTime (fromGregorian 2026 10 14) (secondsToDiffTime (9 * 3600 - 120))

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
  , cjProvider = Nothing
  , cjModel = Nothing
  , cjEnabled = True
  , cjOneShot = False
  , cjCreatedAt = createdTime
  , cjUpdatedAt = createdTime
  , cjLastFire = Nothing
  , cjRunCount = 0
  , cjConsecutiveFailures = 0
  }

sampleRun :: CronRun
sampleRun = CronRun
  { crJobId = sampleJobId
  , crSessionId = "session-1"
  , crStartedAt = sampleTime
  , crEndedAt = Nothing
  , crStatus = CrRunning
  , crError = Nothing
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

    it "records the session id from a successful fire" $ do
      store <- memoryCronStore
      csCreate store sampleJob
      let scheduler = CronScheduler
            { csStore = store
            , csFireDelegate = \_job -> pure (Right (mkSystemSessionId "cron-session-42"))
            , csClock = pure sampleTime
            , csTickInterval = 60
            , csStopSignal = error "unused in tick"
            , csMaxConcurrent = 5
            , csNotifyHuman = \_ -> pure ()
            }
      tick scheduler
      runs <- csListRuns store sampleJobId 10
      case runs of
        (r:_) -> do
          crStatus r `shouldBe` CrRunning
          crSessionId r `shouldBe` sessionIdText (mkSystemSessionId "cron-session-42")
        [] -> False `shouldBe` True
      mJob <- csRead store sampleJobId
      case mJob of
        Just job -> do
          cjRunCount job `shouldBe` 1
          cjLastFire job `shouldBe` Just sampleTime
        Nothing -> False `shouldBe` True

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

  describe "run lifecycle" $ do
    it "persists a Pending row before invoking the delegate" $ do
      store <- memoryCronStore
      csCreate store sampleJob
      seen <- newIORef ([] :: [CronRunStatus])
      let scheduler = CronScheduler
            { csStore = store
            , csFireDelegate = \job -> do
                runs <- csListRuns store (cjId job) 1
                writeIORef seen (map crStatus runs)
                pure (Right (mkSystemSessionId "cron-1"))
            , csClock = pure sampleTime
            , csTickInterval = 60
            , csStopSignal = error "unused in tick"
            , csMaxConcurrent = 5
            , csNotifyHuman = \_ -> pure ()
            }
      tick scheduler
      readIORef seen `shouldReturn` [CrPending]

    it "keeps exactly one run row per fire (no append-per-status)" $ do
      store <- memoryCronStore
      csCreate store sampleJob
      let scheduler = CronScheduler
            { csStore = store
            , csFireDelegate = \_ -> pure (Right (mkSystemSessionId "cron-1"))
            , csClock = pure sampleTime
            , csTickInterval = 60
            , csStopSignal = error "unused in tick"
            , csMaxConcurrent = 5
            , csNotifyHuman = \_ -> pure ()
            }
      tick scheduler
      runs <- csListRuns store sampleJobId 10
      length runs `shouldBe` 1

    -- The reported bug: the first fire left a permanent CrRunning row, so
    -- every later tick skipped the job as "overlapping itself".
    it "fires again on the next due tick" $ do
      store <- memoryCronStore
      csCreate store sampleJob
      fireCount <- newIORef (0 :: Int)
      let mkSched clock = CronScheduler
            { csStore = store
            , csFireDelegate = \_ -> do
                modifyIORef' fireCount (+1)
                pure (Right (mkSystemSessionId "cron-x"))
            , csClock = clock
            , csTickInterval = 60
            , csStopSignal = error "unused in tick"
            , csMaxConcurrent = 5
            , csNotifyHuman = \_ -> pure ()
            }
      tick (mkSched (pure sampleTime))
      -- The delegate returns a session id and the turn then finishes; here the
      -- completion is simulated directly, because delivery of the real one is
      -- WU-3's job (startPlainTurn -> sdTurnComplete). Until a run reaches a
      -- terminal state it is legitimately still "in flight", so overlap
      -- protection correctly skips the job — that is the behaviour under test.
      csUpdateRun store sampleJobId (applyRunOutcome sampleTime (Right ()))
      tick (mkSched (pure (sampleTime { utctDayTime = utctDayTime sampleTime + 120 })))
      readIORef fireCount `shouldReturn` 2

    -- The second failure mode: five stale rows exhausted the global
    -- concurrency budget, blocking every job including healthy ones.
    it "resumes firing after startup reconciliation of a wedged store" $ do
      store <- memoryCronStore
      csCreate store sampleJob
      let wedged = [ CronRun { crJobId = sampleJobId, crSessionId = T.pack ("old-" <> show n)
                             , crStartedAt = createdTime, crEndedAt = Nothing
                             , crStatus = CrRunning, crError = Nothing }
                   | n <- [1 .. 5 :: Int] ]
      mapM_ (csRecordRun store sampleJobId) wedged
      fixed <- reconcileStaleRuns store sampleTime
      -- All five wedged rows are repaired, not just the newest: a store wedged
      -- by repeated fires has one stuck row per fire.
      fixed `shouldBe` 5
      runs <- csListRuns store sampleJobId 10
      map crStatus runs `shouldSatisfy` all (== CrFailed)
      fireCount <- newIORef (0 :: Int)
      let scheduler = CronScheduler
            { csStore = store
            , csFireDelegate = \_ -> do
                modifyIORef' fireCount (+1)
                pure (Right (mkSystemSessionId "cron-after"))
            , csClock = pure sampleTime
            , csTickInterval = 60
            , csStopSignal = error "unused in tick"
            , csMaxConcurrent = 5
            , csNotifyHuman = \_ -> pure ()
            }
      tick scheduler
      readIORef fireCount `shouldReturn` 1

    it "does not let five completed runs of other jobs block a healthy job" $ do
      store <- memoryCronStore
      mapM_ (\i -> do
        let jid = case mkCronJobId (T.pack ("done-" <> show i)) of Right j -> j; Left _ -> error "u"
        -- Disabled so only the job under test is schedulable: this asserts the
        -- concurrency budget, not the due-ness of the fixtures.
        csCreate store sampleJob { cjId = jid, cjName = "Done", cjEnabled = False }
        csRecordRun store jid CronRun
          { crJobId = jid, crSessionId = "s", crStartedAt = sampleTime
          , crEndedAt = Just sampleTime, crStatus = CrCompleted, crError = Nothing })
        [1 .. 5 :: Int]
      csCreate store sampleJob
      fireCount <- newIORef (0 :: Int)
      let scheduler = CronScheduler
            { csStore = store
            , csFireDelegate = \_ -> do
                modifyIORef' fireCount (+1)
                pure (Right (mkSystemSessionId "cron-healthy"))
            , csClock = pure sampleTime
            , csTickInterval = 60
            , csStopSignal = error "unused in tick"
            , csMaxConcurrent = 5
            , csNotifyHuman = \_ -> pure ()
            }
      tick scheduler
      readIORef fireCount `shouldReturn` 1


  -- End-to-end of the composition the bug lived in: a store, a scheduler, and a
  -- completion arriving after the fire. This is the assertion the previous
  -- attempt lacked (it asserted CrRunning, encoding the bug).
  describe "end-to-end: fire -> completion -> CrCompleted -> next fire" $
    it "completes the run and fires again on the next tick" $ do
      store <- memoryCronStore
      csCreate store sampleJob
      fireCount <- newIORef (0 :: Int)
      let completeRun outcome =
            csUpdateRun store sampleJobId (applyRunOutcome sampleTime outcome)
      let mkSched clock = CronScheduler
            { csStore = store
            , csFireDelegate = \_job -> do
                modifyIORef' fireCount (+1)
                let sid = mkSystemSessionId "cron-e2e"
                -- Simulate the turn finishing successfully right after the fire,
                -- which is what sdTurnComplete does in production.
                completeRun (Right ())
                pure (Right sid)
            , csClock = clock
            , csTickInterval = 60
            , csStopSignal = error "unused in tick"
            , csMaxConcurrent = 5
            , csNotifyHuman = \_ -> pure ()
            }
      tick (mkSched (pure sampleTime))
      runs <- csListRuns store sampleJobId 10
      case runs of
        (r:_) -> do
          crStatus r `shouldBe` CrCompleted
          crEndedAt r `shouldBe` Just sampleTime
        [] -> expectationFailure "expected a run row"
      tick (mkSched (pure (sampleTime { utctDayTime = utctDayTime sampleTime + 120 })))
      readIORef fireCount `shouldReturn` 2

  describe "applyRunOutcome / markRunning" $ do
    let pendingRun = CronRun
          { crJobId = sampleJobId, crSessionId = "", crStartedAt = sampleTime
          , crEndedAt = Nothing, crStatus = CrPending, crError = Nothing }

    it "marks success as Completed with an end time" $ do
      let r = applyRunOutcome sampleTime (Right ()) pendingRun
      crStatus r `shouldBe` CrCompleted
      crEndedAt r `shouldBe` Just sampleTime

    it "marks failure as Failed with the error text" $ do
      let r = applyRunOutcome sampleTime (Left "boom") pendingRun
      crStatus r `shouldBe` CrFailed
      crError r `shouldBe` Just "boom"
      crEndedAt r `shouldBe` Just sampleTime

    it "preserves the start time" $
      crStartedAt (applyRunOutcome sampleTime (Right ()) pendingRun) `shouldBe` sampleTime

    it "is idempotent: a duplicate callback cannot regress a completed run" $ do
      let done = applyRunOutcome sampleTime (Right ()) pendingRun
          again = applyRunOutcome sampleTime (Left "late error") done
      crStatus again `shouldBe` CrCompleted
      crError again `shouldBe` Nothing

    -- The round-2 gate caught this: a completion can land before the delegate
    -- returns, and the late Running write must not overwrite it.
    it "markRunning does not regress an already-completed run" $ do
      let done = applyRunOutcome sampleTime (Right ()) pendingRun
          late = markRunning "session-late" sampleTime done
      crStatus late `shouldBe` CrCompleted
      crSessionId late `shouldBe` ""

    it "markRunning moves Pending to Running and stamps the session" $ do
      let r = markRunning "session-1" sampleTime pendingRun
      crStatus r `shouldBe` CrRunning
      crSessionId r `shouldBe` "session-1"

  describe "isRunActive" $ do
    let at :: Int64 -> UTCTime
        at s = sampleTime { utctDayTime = utctDayTime sampleTime + realToFrac s }

    it "counts a fresh Running run as active" $
      isRunActive sampleTime (sampleRun { crStatus = CrRunning, crStartedAt = sampleTime })
        `shouldBe` True

    it "does not count a terminal run as active" $ do
      isRunActive sampleTime (sampleRun { crStatus = CrCompleted }) `shouldBe` False
      isRunActive sampleTime (sampleRun { crStatus = CrFailed }) `shouldBe` False

    it "treats a run older than the staleness horizon as not active" $ do
      let old = sampleRun { crStatus = CrRunning, crStartedAt = at 0 }
      isRunActive (at (cronStaleAfterSeconds + 1)) old `shouldBe` False

    it "still counts a run just inside the horizon as active" $ do
      let old = sampleRun { crStatus = CrRunning, crStartedAt = at 0 }
      isRunActive (at (cronStaleAfterSeconds - 1)) old `shouldBe` True

  describe "checkAutoDisable" $ do
    it "disables a job after five consecutive failures and notifies" $ do
      store <- memoryCronStore
      csCreate store sampleJob
      let failed = CronRun
            { crJobId = sampleJobId, crSessionId = "s", crStartedAt = sampleTime
            , crEndedAt = Just sampleTime, crStatus = CrFailed, crError = Just "e" }
      mapM_ (const (csRecordRun store sampleJobId failed)) [1 .. 5 :: Int]
      noticed <- newIORef ([] :: [Text])
      checkAutoDisable store (\m -> modifyIORef' noticed (++ [m])) sampleTime sampleJob
      mJob <- csRead store sampleJobId
      case mJob of
        Just j -> cjEnabled j `shouldBe` False
        Nothing -> expectationFailure "job missing"
      msgs <- readIORef noticed
      length msgs `shouldBe` 1
