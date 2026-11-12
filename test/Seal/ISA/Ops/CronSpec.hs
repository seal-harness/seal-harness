{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.CronSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Text qualified as DT
import Data.Text (Text)
import Test.Hspec

import Seal.Core.Types (SessionId, mkSystemSessionId)
import Seal.ISA.Opcode
import Seal.ISA.Ops.Cron
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Cron.Store
import Seal.Cron.Types
import Seal.Types.App (App, runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)
import Seal.Logging.Logger (testSealLogger)

runTestApp :: App a -> IO a
runTestApp act = do
  logger <- testSealLogger
  env <- mkEnv logger defaultConfig
  runApp env act

sampleSession :: SessionId
sampleSession = mkSystemSessionId "test-cron"

spec :: Spec
spec = describe "Seal.ISA.Ops.Cron" $ do
  describe "CRON_MANAGE create" $ do
    it "creates a job with slugified id and returns next_fire" $ do
      store <- memoryCronStore
      let op = cronManageOp Nothing store sampleSession
      r <- runTestApp (opRun op localBackend (object
        [ "action" .= ("create" :: Text)
        , "name" .= ("Morning Review" :: Text)
        , "schedule" .= ("0 9 * * 1-5" :: Text)
        , "prompt" .= ("Review yesterday's commits" :: Text)
        ]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText msg] -> msg `shouldSatisfy` isInText "morning-review"
        _ -> expectationFailure "expected TrpText"

    it "sets enabled=false by default" $ do
      store <- memoryCronStore
      let op = cronManageOp Nothing store sampleSession
      _ <- runTestApp (opRun op localBackend (object
        [ "action" .= ("create" :: Text)
        , "name" .= ("Test Job" :: Text)
        , "schedule" .= ("0 9 * * *" :: Text)
        , "prompt" .= ("test" :: Text)
        ]))
      jobs <- csList store False
      length jobs `shouldBe` 1
      cjEnabled (case jobs of (j:_) -> j; [] -> error "unreachable") `shouldBe` False

    it "deduplicates slug with numeric suffix" $ do
      store <- memoryCronStore
      let op = cronManageOp Nothing store sampleSession
          createJob nm = runTestApp (opRun op localBackend (object
            [ "action" .= ("create" :: Text)
            , "name" .= (nm :: Text)
            , "schedule" .= ("0 9 * * *" :: Text)
            , "prompt" .= ("test" :: Text)
            ]))
      _ <- createJob "Daily Review"
      _ <- createJob "Daily Review"
      jobs <- csList store False
      length jobs `shouldBe` 2
      let ids = map (cronJobIdText . cjId) jobs
      ids `shouldContain` ["daily-review"]
      ids `shouldContain` ["daily-review-2"]

    it "rejects missing required fields" $ do
      store <- memoryCronStore
      let op = cronManageOp Nothing store sampleSession
      r <- runTestApp (opRun op localBackend (object
        [ "action" .= ("create" :: Text)
        , "name" .= ("Test" :: Text)
        ]))
      orIsError r `shouldBe` True

  describe "CRON_MANAGE read" $ do
    it "reads an existing job" $ do
      store <- memoryCronStore
      let op = cronManageOp Nothing store sampleSession
      _ <- runTestApp (opRun op localBackend (object
        [ "action" .= ("create" :: Text)
        , "name" .= ("Test" :: Text)
        , "schedule" .= ("0 9 * * *" :: Text)
        , "prompt" .= ("test" :: Text)
        ]))
      r <- runTestApp (opRun op localBackend (object
        [ "action" .= ("read" :: Text)
        , "id" .= ("test" :: Text)
        ]))
      orIsError r `shouldBe` False

    it "returns error for non-existent job" $ do
      store <- memoryCronStore
      let op = cronManageOp Nothing store sampleSession
      r <- runTestApp (opRun op localBackend (object
        [ "action" .= ("read" :: Text)
        , "id" .= ("nonexistent" :: Text)
        ]))
      orIsError r `shouldBe` True

  describe "CRON_MANAGE list" $ do
    it "lists all jobs" $ do
      store <- memoryCronStore
      let op = cronManageOp Nothing store sampleSession
      _ <- runTestApp (opRun op localBackend (object
        [ "action" .= ("create" :: Text)
        , "name" .= ("Job A" :: Text)
        , "schedule" .= ("0 9 * * *" :: Text)
        , "prompt" .= ("a" :: Text)
        ]))
      r <- runTestApp (opRun op localBackend (object
        [ "action" .= ("list" :: Text)
        ]))
      orIsError r `shouldBe` False

    it "lists empty store" $ do
      store <- memoryCronStore
      let op = cronManageOp Nothing store sampleSession
      r <- runTestApp (opRun op localBackend (object
        [ "action" .= ("list" :: Text)
        ]))
      orIsError r `shouldBe` False

  describe "CRON_MANAGE delete" $ do
    it "deletes an existing job" $ do
      store <- memoryCronStore
      let op = cronManageOp Nothing store sampleSession
      _ <- runTestApp (opRun op localBackend (object
        [ "action" .= ("create" :: Text)
        , "name" .= ("Test" :: Text)
        , "schedule" .= ("0 9 * * *" :: Text)
        , "prompt" .= ("test" :: Text)
        ]))
      r <- runTestApp (opRun op localBackend (object
        [ "action" .= ("delete" :: Text)
        , "id" .= ("test" :: Text)
        ]))
      orIsError r `shouldBe` False

    it "delete is idempotent for non-existent job" $ do
      store <- memoryCronStore
      let op = cronManageOp Nothing store sampleSession
      r <- runTestApp (opRun op localBackend (object
        [ "action" .= ("delete" :: Text)
        , "id" .= ("nonexistent" :: Text)
        ]))
      orIsError r `shouldBe` False

  describe "CRON_MANAGE enable/disable" $ do
    it "enables a disabled job" $ do
      store <- memoryCronStore
      let op = cronManageOp Nothing store sampleSession
      _ <- runTestApp (opRun op localBackend (object
        [ "action" .= ("create" :: Text)
        , "name" .= ("Test" :: Text)
        , "schedule" .= ("0 9 * * *" :: Text)
        , "prompt" .= ("test" :: Text)
        ]))
      r <- runTestApp (opRun op localBackend (object
        [ "action" .= ("enable" :: Text)
        , "id" .= ("test" :: Text)
        ]))
      orIsError r `shouldBe` False
      jobs <- csList store True
      length jobs `shouldBe` 1

    it "disables an enabled job" $ do
      store <- memoryCronStore
      let op = cronManageOp Nothing store sampleSession
      _ <- runTestApp (opRun op localBackend (object
        [ "action" .= ("create" :: Text)
        , "name" .= ("Test" :: Text)
        , "schedule" .= ("0 9 * * *" :: Text)
        , "prompt" .= ("test" :: Text)
        , "enabled" .= True
        ]))
      r <- runTestApp (opRun op localBackend (object
        [ "action" .= ("disable" :: Text)
        , "id" .= ("test" :: Text)
        ]))
      orIsError r `shouldBe` False
      enabled <- csList store True
      length enabled `shouldBe` 0

  describe "CRON_MANAGE trigger" $ do
    it "returns error when no fire delegate" $ do
      store <- memoryCronStore
      let op = cronManageOp Nothing store sampleSession
      _ <- runTestApp (opRun op localBackend (object
        [ "action" .= ("create" :: Text)
        , "name" .= ("Test" :: Text)
        , "schedule" .= ("0 9 * * *" :: Text)
        , "prompt" .= ("test" :: Text)
        ]))
      r <- runTestApp (opRun op localBackend (object
        [ "action" .= ("trigger" :: Text)
        , "id" .= ("test" :: Text)
        ]))
      orIsError r `shouldBe` True

  describe "CRON_MANAGE update" $ do
    it "updates schedule on existing job" $ do
      store <- memoryCronStore
      let op = cronManageOp Nothing store sampleSession
      _ <- runTestApp (opRun op localBackend (object
        [ "action" .= ("create" :: Text)
        , "name" .= ("Test" :: Text)
        , "schedule" .= ("0 9 * * *" :: Text)
        , "prompt" .= ("test" :: Text)
        ]))
      r <- runTestApp (opRun op localBackend (object
        [ "action" .= ("update" :: Text)
        , "id" .= ("test" :: Text)
        , "schedule" .= ("0 10 * * *" :: Text)
        ]))
      orIsError r `shouldBe` False
      mJob <- csRead store (case mkCronJobId "test" of Right j -> j; Left _ -> error "u")
      case mJob of
        Just job -> cronExprText (cjSchedule job) `shouldBe` "0 10 * * *"
        Nothing -> False `shouldBe` True

    it "returns error for non-existent job" $ do
      store <- memoryCronStore
      let op = cronManageOp Nothing store sampleSession
      r <- runTestApp (opRun op localBackend (object
        [ "action" .= ("update" :: Text)
        , "id" .= ("nonexistent" :: Text)
        , "schedule" .= ("0 10 * * *" :: Text)
        ]))
      orIsError r `shouldBe` True

isInText :: Text -> Text -> Bool
isInText needle haystack = needle `DT.isInfixOf` haystack
