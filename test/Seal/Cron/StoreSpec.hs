{-# LANGUAGE OverloadedStrings #-}
module Seal.Cron.StoreSpec (spec) where

import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Cron.Types
import Seal.Cron.Store
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 10 14) (secondsToDiffTime 0)

sampleJobId :: CronJobId
sampleJobId = case mkCronJobId "test-job" of
  Right jid -> jid
  Left _ -> CronJobId "fallback"

sampleJob :: CronJob
sampleJob = CronJob
  { cjId = sampleJobId
  , cjName = "Test Job"
  , cjSchedule = case mkCronExpr "0 9 * * 1-5" of
      Right e -> e
      Left _ -> error "unreachable"
  , cjTimezone = Nothing
  , cjPrompt = "Review the code"
  , cjAgentDefId = Nothing
  , cjEnabled = True
  , cjOneShot = False
  , cjCreatedAt = sampleTime
  , cjUpdatedAt = sampleTime
  , cjLastFire = Nothing
  , cjRunCount = 0
  , cjConsecutiveFailures = 0
  }

sampleRun :: CronRun
sampleRun = CronRun
  { crJobId = sampleJobId
  , crSessionId = "session-123"
  , crStartedAt = sampleTime
  , crEndedAt = Nothing
  , crStatus = CrPending
  , crError = Nothing
  }

spec :: Spec
spec = do
  describe "memoryCronStore" $ do
    it "creates and reads a job" $ do
      store <- memoryCronStore
      csCreate store sampleJob
      mJob <- csRead store sampleJobId
      mJob `shouldBe` Just sampleJob

    it "lists all jobs sorted by id" $ do
      store <- memoryCronStore
      let job2Id = case mkCronJobId "aaa-job" of Right j -> j; Left _ -> error "u"
          job2 = sampleJob { cjId = job2Id, cjName = "AAA Job" }
      csCreate store sampleJob
      csCreate store job2
      jobs <- csList store False
      length jobs `shouldBe` 2
      case jobs of
        (j:_) -> cronJobIdText (cjId j) `shouldBe` "aaa-job"
        [] -> expectationFailure "expected non-empty list"

    it "lists only enabled jobs when enabledOnly=True" $ do
      store <- memoryCronStore
      let disId = case mkCronJobId "disabled" of Right j -> j; Left _ -> error "u"
          disabledJob = sampleJob { cjId = disId, cjEnabled = False }
      csCreate store sampleJob
      csCreate store disabledJob
      enabled <- csList store True
      length enabled `shouldBe` 1
      case enabled of
        (j:_) -> cronJobIdText (cjId j) `shouldBe` "test-job"
        [] -> expectationFailure "expected non-empty list"

    it "deletes a job (idempotent)" $ do
      store <- memoryCronStore
      csCreate store sampleJob
      csDelete store sampleJobId
      mJob <- csRead store sampleJobId
      mJob `shouldBe` Nothing
      csDelete store sampleJobId

    it "records and lists runs" $ do
      store <- memoryCronStore
      csRecordRun store sampleJobId sampleRun
      runs <- csListRuns store sampleJobId 10
      length runs `shouldBe` 1
      case runs of
        (r:_) -> crStatus r `shouldBe` CrPending
        [] -> expectationFailure "expected non-empty list"

    it "rotates runs to last 100" $ do
      store <- memoryCronStore
      let runs = [ sampleRun { crSessionId = "s-" <> T.pack (show n) } | n <- [(1 :: Int)..105] ]
      mapM_ (csRecordRun store sampleJobId) runs
      stored <- csListRuns store sampleJobId 200
      length stored `shouldBe` 100

    it "returns empty runs for non-existent job" $ do
      store <- memoryCronStore
      runs <- csListRuns store sampleJobId 10
      runs `shouldBe` []

  describe "fileCronStore" $ do
    it "creates and reads a job from disk" $ do
      withSystemTempDirectory "seal-cron" $ \root -> do
        let cfgRoot = root </> "config"
        ensureConfigRepo cfgRoot
        let repo = openConfigRepo cfgRoot
            cronDir = cfgRoot </> "cron"
        store <- fileCronStore cronDir repo
        csCreate store sampleJob
        mJob <- csRead store sampleJobId
        mJob `shouldBe` Just sampleJob

    it "lists jobs from disk" $ do
      withSystemTempDirectory "seal-cron" $ \root -> do
        let cfgRoot = root </> "config"
        ensureConfigRepo cfgRoot
        let repo = openConfigRepo cfgRoot
            cronDir = cfgRoot </> "cron"
        store <- fileCronStore cronDir repo
        csCreate store sampleJob
        jobs <- csList store False
        length jobs `shouldBe` 1
        case jobs of
          (j:_) -> cjName j `shouldBe` "Test Job"
          [] -> expectationFailure "expected non-empty list"

    it "deletes a job from disk (idempotent)" $ do
      withSystemTempDirectory "seal-cron" $ \root -> do
        let cfgRoot = root </> "config"
        ensureConfigRepo cfgRoot
        let repo = openConfigRepo cfgRoot
            cronDir = cfgRoot </> "cron"
        store <- fileCronStore cronDir repo
        csCreate store sampleJob
        csDelete store sampleJobId
        mJob <- csRead store sampleJobId
        mJob `shouldBe` Nothing

    it "records and lists runs from disk" $ do
      withSystemTempDirectory "seal-cron" $ \root -> do
        let cfgRoot = root </> "config"
        ensureConfigRepo cfgRoot
        let repo = openConfigRepo cfgRoot
            cronDir = cfgRoot </> "cron"
        store <- fileCronStore cronDir repo
        csRecordRun store sampleJobId sampleRun
        runs <- csListRuns store sampleJobId 10
        length runs `shouldBe` 1

    it "rotates runs to last 100 on disk" $ do
      withSystemTempDirectory "seal-cron" $ \root -> do
        let cfgRoot = root </> "config"
        ensureConfigRepo cfgRoot
        let repo = openConfigRepo cfgRoot
            cronDir = cfgRoot </> "cron"
        store <- fileCronStore cronDir repo
        let runs = [ sampleRun { crSessionId = "s-" <> T.pack (show n) } | n <- [(1 :: Int)..105] ]
        mapM_ (csRecordRun store sampleJobId) runs
        stored <- csListRuns store sampleJobId 200
        length stored `shouldBe` 100
