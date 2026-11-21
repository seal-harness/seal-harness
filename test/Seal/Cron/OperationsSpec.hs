{-# LANGUAGE OverloadedStrings #-}
module Seal.Cron.OperationsSpec (spec) where

import Control.Exception (bracket)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import Test.Hspec

import Seal.Cron.Types
import Seal.Cron.Store
import Seal.Cron.Operations (createJob, updateJob, setJobEnabled, deleteJob, CronUpdate (..))

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 10 14) (secondsToDiffTime 0)

spec :: Spec
spec = do
  describe "Seal.Cron.Types.validateCronTimeZone" $ do
    it "accepts a valid IANA timezone that exists in the tz database" $ do
      let tz = case mkCronTimeZone "America/New_York" of Right t -> t; Left _ -> error "unreachable"
      r <- validateCronTimeZone tz
      r `shouldBe` Right ()

    it "falls back to the embedded tz database when TZDIR is missing" $ do
      let tz = case mkCronTimeZone "America/New_York" of Right t -> t; Left _ -> error "unreachable"
      bracket
        (do prev <- lookupEnv "TZDIR"
            setEnv "TZDIR" "/nonexistent/seal-test-tzdir"
            pure prev)
        (maybe (unsetEnv "TZDIR") (setEnv "TZDIR"))
        (\_ -> validateCronTimeZone tz `shouldReturn` Right ())

    it "rejects a format-valid-but-nonexistent timezone" $ do
      let tz = case mkCronTimeZone "Not/AZone" of Right t -> t; Left _ -> error "unreachable"
      r <- validateCronTimeZone tz
      r `shouldSatisfy` isLeft

    it "rejects a format-invalid timezone" $ do
      r <- validateCronTimeZone (CronTimeZone "Not/A/Zone")
      r `shouldSatisfy` isLeft

  describe "Seal.Cron.Types.computeNextFire (totality)" $ do
    it "returns Nothing for an unknown timezone rather than throwing" $ do
      let tz = case mkCronTimeZone "Not/AZone" of Right t -> t; Left _ -> error "unreachable"
          expr = case mkCronExpr "0 9 * * 1-5" of Right e -> e; Left _ -> error "unreachable"
      r <- computeNextFire expr (Just tz) sampleTime
      r `shouldBe` Nothing

    it "computes next fire for a valid timezone" $ do
      let tz = case mkCronTimeZone "America/New_York" of Right t -> t; Left _ -> error "unreachable"
          expr = case mkCronExpr "0 9 * * 1-5" of Right e -> e; Left _ -> error "unreachable"
      r <- computeNextFire expr (Just tz) sampleTime
      r `shouldSatisfy` isJust

    it "computes next fire without a timezone" $ do
      let expr = case mkCronExpr "0 9 * * 1-5" of Right e -> e; Left _ -> error "unreachable"
      r <- computeNextFire expr Nothing sampleTime
      r `shouldSatisfy` isJust

  describe "Seal.Cron.Operations.createJob" $ do
    it "slugifies the name and dedups against existing ids" $ do
      store <- memoryCronStore
      eJob1 <- createJob store "Daily Review" "0 9 * * 1-5" Nothing "Review code" Nothing Nothing Nothing False False
      case eJob1 of
        Right job1 -> cronJobIdText (cjId job1) `shouldBe` "daily-review"
        Left e -> expectationFailure (T.unpack e)
      eJob2 <- createJob store "Daily Review" "0 9 * * 1-5" Nothing "Review code" Nothing Nothing Nothing False False
      case eJob2 of
        Right job2 -> cronJobIdText (cjId job2) `shouldBe` "daily-review-2"
        Left e -> expectationFailure (T.unpack e)

    it "rejects a name over 100 chars" $ do
      store <- memoryCronStore
      let longName = T.replicate 101 "x"
      eJob <- createJob store longName "0 9 * * 1-5" Nothing "prompt" Nothing Nothing Nothing False False
      eJob `shouldSatisfy` isLeft

    it "rejects a prompt over 4000 chars" $ do
      store <- memoryCronStore
      let longPrompt = T.replicate 4001 "x"
      eJob <- createJob store "name" "0 9 * * 1-5" Nothing longPrompt Nothing Nothing Nothing False False
      eJob `shouldSatisfy` isLeft

    it "rejects an invalid cron expression" $ do
      store <- memoryCronStore
      eJob <- createJob store "name" "not-a-cron-expr" Nothing "prompt" Nothing Nothing Nothing False False
      eJob `shouldSatisfy` isLeft

    it "rejects a format-invalid timezone" $ do
      store <- memoryCronStore
      eJob <- createJob store "name" "0 9 * * 1-5" (Just "Not/A/Zone") "prompt" Nothing Nothing Nothing False False
      eJob `shouldSatisfy` isLeft

    it "rejects a format-valid-but-nonexistent timezone" $ do
      store <- memoryCronStore
      eJob <- createJob store "name" "0 9 * * 1-5" (Just "Not/AZone") "prompt" Nothing Nothing Nothing False False
      eJob `shouldSatisfy` isLeft

    it "rejects an invalid agent_def_id" $ do
      store <- memoryCronStore
      eJob <- createJob store "name" "0 9 * * 1-5" Nothing "prompt" (Just ".bad") Nothing Nothing False False
      eJob `shouldSatisfy` isLeft

    it "enforces the 100-job cap" $ do
      store <- memoryCronStore
      -- Create 100 jobs
      mapM_ (\n -> createJob store (T.pack ("job-" <> show n)) "0 9 * * 1-5" Nothing "p" Nothing Nothing Nothing False False) [(1 :: Int)..100]
      eJob <- createJob store "overflow" "0 9 * * 1-5" Nothing "prompt" Nothing Nothing Nothing False False
      eJob `shouldSatisfy` isLeft

    it "defaults enabled to False" $ do
      store <- memoryCronStore
      eJob <- createJob store "test" "0 9 * * 1-5" Nothing "prompt" Nothing Nothing Nothing False False
      case eJob of
        Right job -> cjEnabled job `shouldBe` False
        Left e -> expectationFailure (T.unpack e)

    it "accepts a valid timezone" $ do
      store <- memoryCronStore
      eJob <- createJob store "test" "0 9 * * 1-5" (Just "America/New_York") "prompt" Nothing Nothing Nothing False False
      case eJob of
        Right job -> cjTimezone job `shouldSatisfy` isJust
        Left e -> expectationFailure (T.unpack e)

  describe "Seal.Cron.Operations.createJob provider + model" $ do
    it "stores a supplied provider and model" $ do
      store <- memoryCronStore
      eJob <- createJob store "test" "0 9 * * 1-5" Nothing "prompt" Nothing
        (Just "anthropic") (Just "claude-opus-4-8") False False
      case eJob of
        Right job -> do
          cjProvider job `shouldBe` Just "anthropic"
          cjModel job `shouldBe` Just "claude-opus-4-8"
        Left e -> expectationFailure (T.unpack e)

    it "stores Nothing when neither is supplied" $ do
      store <- memoryCronStore
      eJob <- createJob store "test" "0 9 * * 1-5" Nothing "prompt" Nothing
        Nothing Nothing False False
      case eJob of
        Right job -> do
          cjProvider job `shouldBe` Nothing
          cjModel job `shouldBe` Nothing
        Left e -> expectationFailure (T.unpack e)

    -- An empty form field means "no explicit choice", not a provider named "".
    it "treats an empty provider and model as absent" $ do
      store <- memoryCronStore
      eJob <- createJob store "test" "0 9 * * 1-5" Nothing "prompt" Nothing
        (Just "") (Just "") False False
      case eJob of
        Right job -> do
          cjProvider job `shouldBe` Nothing
          cjModel job `shouldBe` Nothing
        Left e -> expectationFailure (T.unpack e)

    it "rejects a provider name with path separators" $ do
      store <- memoryCronStore
      eJob <- createJob store "test" "0 9 * * 1-5" Nothing "prompt" Nothing
        (Just "../seal") Nothing False False
      eJob `shouldSatisfy` isLeft

    it "rejects a provider name with spaces and uppercase" $ do
      store <- memoryCronStore
      eJob <- createJob store "test" "0 9 * * 1-5" Nothing "prompt" Nothing
        (Just "Not A Provider") Nothing False False
      eJob `shouldSatisfy` isLeft

    it "accepts a syntactically valid custom provider instance name" $ do
      store <- memoryCronStore
      eJob <- createJob store "test" "0 9 * * 1-5" Nothing "prompt" Nothing
        (Just "my-vllm") (Just "some-model") False False
      case eJob of
        Right job -> cjProvider job `shouldBe` Just "my-vllm"
        Left e -> expectationFailure (T.unpack e)

    -- The fields are independent (D4): a model on its own is stored and will
    -- be used against whatever provider resolves at fire time.
    it "stores a model with no provider" $ do
      store <- memoryCronStore
      eJob <- createJob store "test" "0 9 * * 1-5" Nothing "prompt" Nothing
        Nothing (Just "claude-opus-4-8") False False
      case eJob of
        Right job -> do
          cjProvider job `shouldBe` Nothing
          cjModel job `shouldBe` Just "claude-opus-4-8"
        Left e -> expectationFailure (T.unpack e)

  describe "prompt validation (slash guard)" $ do
    -- A '/'-leading prompt is routed by the gateway to the slash-command path,
    -- which never starts a plain turn, so the run could never report completion
    -- and would look permanently in-flight. Rejected at the write boundary.
    it "rejects a create with a '/'-leading prompt" $ do
      store <- memoryCronStore
      eJob <- createJob store "test" "0 9 * * 1-5" Nothing "/new"
        Nothing Nothing Nothing False False
      eJob `shouldSatisfy` isLeft

    it "rejects a '/'-leading prompt even with leading whitespace" $ do
      store <- memoryCronStore
      eJob <- createJob store "test" "0 9 * * 1-5" Nothing "  /skill list"
        Nothing Nothing Nothing False False
      eJob `shouldSatisfy` isLeft

    it "accepts a prompt containing a slash that does not lead" $ do
      store <- memoryCronStore
      eJob <- createJob store "test" "0 9 * * 1-5" Nothing "check src/main"
        Nothing Nothing Nothing False False
      eJob `shouldSatisfy` isRight

  describe "Seal.Cron.Operations.updateJob" $ do
    it "rejects an update that would introduce a '/'-leading prompt" $ do
      store <- memoryCronStore
      Right job <- createJob store "test" "0 9 * * 1-5" Nothing "fine"
        Nothing Nothing Nothing False False
      eUpdated <- updateJob store (cjId job) (CronUpdate
        { cuName = Nothing, cuSchedule = Nothing, cuTimezone = Nothing
        , cuPrompt = Just "/new", cuAgentDefId = Nothing
        , cuProvider = Nothing, cuModel = Nothing
        , cuEnabled = Nothing, cuOneShot = Nothing })
      eUpdated `shouldSatisfy` isLeft

    it "patches only supplied fields and leaves the rest alone" $ do
      store <- memoryCronStore
      Right job <- createJob store "test" "0 9 * * 1-5" Nothing "original prompt" Nothing Nothing Nothing False False
      let jid = cjId job
      eUpdated <- updateJob store jid (CronUpdate
        { cuName = Just "new name"
        , cuSchedule = Nothing
        , cuTimezone = Nothing
        , cuPrompt = Just "new prompt"
        , cuAgentDefId = Nothing
        , cuProvider = Nothing
        , cuModel = Nothing
        , cuEnabled = Nothing
        , cuOneShot = Nothing
        })
      case eUpdated of
        Right updated -> do
          cjName updated `shouldBe` "new name"
          cjPrompt updated `shouldBe` "new prompt"
          cronExprText (cjSchedule updated) `shouldBe` "0 9 * * 1-5"
        Left e -> expectationFailure (T.unpack e)

    it "rejects an invalid schedule on update" $ do
      store <- memoryCronStore
      Right job <- createJob store "test" "0 9 * * 1-5" Nothing "prompt" Nothing Nothing Nothing False False
      eUpdated <- updateJob store (cjId job) (CronUpdate
        { cuName = Nothing, cuSchedule = Just "bad-expr", cuTimezone = Nothing
        , cuPrompt = Nothing, cuAgentDefId = Nothing, cuProvider = Nothing, cuModel = Nothing
        , cuEnabled = Nothing, cuOneShot = Nothing })
      eUpdated `shouldSatisfy` isLeft

    it "rejects a nonexistent timezone on update" $ do
      store <- memoryCronStore
      Right job <- createJob store "test" "0 9 * * 1-5" Nothing "prompt" Nothing Nothing Nothing False False
      eUpdated <- updateJob store (cjId job) (CronUpdate
        { cuName = Nothing, cuSchedule = Nothing, cuTimezone = Just "Not/AZone"
        , cuPrompt = Nothing, cuAgentDefId = Nothing, cuProvider = Nothing, cuModel = Nothing
        , cuEnabled = Nothing, cuOneShot = Nothing })
      eUpdated `shouldSatisfy` isLeft

    it "rejects an over-long name on update" $ do
      store <- memoryCronStore
      Right job <- createJob store "test" "0 9 * * 1-5" Nothing "prompt" Nothing Nothing Nothing False False
      eUpdated <- updateJob store (cjId job) (CronUpdate
        { cuName = Just (T.replicate 101 "x"), cuSchedule = Nothing, cuTimezone = Nothing
        , cuPrompt = Nothing, cuAgentDefId = Nothing, cuProvider = Nothing, cuModel = Nothing
        , cuEnabled = Nothing, cuOneShot = Nothing })
      eUpdated `shouldSatisfy` isLeft

    it "rejects an over-long prompt on update" $ do
      store <- memoryCronStore
      Right job <- createJob store "test" "0 9 * * 1-5" Nothing "prompt" Nothing Nothing Nothing False False
      eUpdated <- updateJob store (cjId job) (CronUpdate
        { cuName = Nothing, cuSchedule = Nothing, cuTimezone = Nothing
        , cuPrompt = Just (T.replicate 4001 "x"), cuAgentDefId = Nothing, cuProvider = Nothing, cuModel = Nothing
        , cuEnabled = Nothing, cuOneShot = Nothing })
      eUpdated `shouldSatisfy` isLeft

    it "rejects an invalid agent_def_id on update" $ do
      store <- memoryCronStore
      Right job <- createJob store "test" "0 9 * * 1-5" Nothing "prompt" Nothing Nothing Nothing False False
      eUpdated <- updateJob store (cjId job) (CronUpdate
        { cuName = Nothing, cuSchedule = Nothing, cuTimezone = Nothing
        , cuPrompt = Nothing, cuAgentDefId = Just ".bad", cuProvider = Nothing, cuModel = Nothing
        , cuEnabled = Nothing, cuOneShot = Nothing })
      eUpdated `shouldSatisfy` isLeft

    it "returns Left for an unknown job id" $ do
      store <- memoryCronStore
      let jid = case mkCronJobId "nonexistent" of Right j -> j; Left _ -> error "u"
      eUpdated <- updateJob store jid (CronUpdate
        { cuName = Just "x", cuSchedule = Nothing, cuTimezone = Nothing
        , cuPrompt = Nothing, cuAgentDefId = Nothing, cuProvider = Nothing, cuModel = Nothing
        , cuEnabled = Nothing, cuOneShot = Nothing })
      eUpdated `shouldSatisfy` isLeft

  describe "Seal.Cron.Operations.updateJob provider + model" $ do
    -- Build a job that already carries a provider+model, so the update tests
    -- can distinguish "left alone" from "cleared".
    let seededJob = do
          store <- memoryCronStore
          eJob <- createJob store "test" "0 9 * * 1-5" Nothing "prompt" Nothing
            (Just "anthropic") (Just "claude-opus-4-8") False False
          case eJob of
            Right job -> pure (store, job)
            Left e    -> expectationFailure (T.unpack e) >> error "unreachable"

    it "leaves provider and model unchanged when neither is supplied" $ do
      (store, job) <- seededJob
      eUpdated <- updateJob store (cjId job) (CronUpdate
        { cuName = Just "renamed", cuSchedule = Nothing, cuTimezone = Nothing
        , cuPrompt = Nothing, cuAgentDefId = Nothing
        , cuProvider = Nothing, cuModel = Nothing
        , cuEnabled = Nothing, cuOneShot = Nothing })
      case eUpdated of
        Right updated -> do
          cjProvider updated `shouldBe` Just "anthropic"
          cjModel updated `shouldBe` Just "claude-opus-4-8"
        Left e -> expectationFailure (T.unpack e)

    it "sets a new provider and model" $ do
      (store, job) <- seededJob
      eUpdated <- updateJob store (cjId job) (CronUpdate
        { cuName = Nothing, cuSchedule = Nothing, cuTimezone = Nothing
        , cuPrompt = Nothing, cuAgentDefId = Nothing
        , cuProvider = Just "ollama", cuModel = Just "llama3.2"
        , cuEnabled = Nothing, cuOneShot = Nothing })
      case eUpdated of
        Right updated -> do
          cjProvider updated `shouldBe` Just "ollama"
          cjModel updated `shouldBe` Just "llama3.2"
        Left e -> expectationFailure (T.unpack e)

    -- "" is the wire signal for "the operator emptied the field" (D4): the
    -- field is cleared so the job falls back to the configured default.
    it "clears provider and model when given an empty string" $ do
      (store, job) <- seededJob
      eUpdated <- updateJob store (cjId job) (CronUpdate
        { cuName = Nothing, cuSchedule = Nothing, cuTimezone = Nothing
        , cuPrompt = Nothing, cuAgentDefId = Nothing
        , cuProvider = Just "", cuModel = Just ""
        , cuEnabled = Nothing, cuOneShot = Nothing })
      case eUpdated of
        Right updated -> do
          cjProvider updated `shouldBe` Nothing
          cjModel updated `shouldBe` Nothing
        Left e -> expectationFailure (T.unpack e)

    it "leaves other fields untouched when clearing the provider" $ do
      (store, job) <- seededJob
      eUpdated <- updateJob store (cjId job) (CronUpdate
        { cuName = Nothing, cuSchedule = Nothing, cuTimezone = Nothing
        , cuPrompt = Nothing, cuAgentDefId = Nothing
        , cuProvider = Just "", cuModel = Nothing
        , cuEnabled = Nothing, cuOneShot = Nothing })
      case eUpdated of
        Right updated -> do
          cjProvider updated `shouldBe` Nothing
          cjModel updated `shouldBe` Just "claude-opus-4-8"
          cjName updated `shouldBe` "test"
          cjPrompt updated `shouldBe` "prompt"
        Left e -> expectationFailure (T.unpack e)

    -- The update path must apply the same validator as create, or it becomes a
    -- way to smuggle in a value createJob would reject.
    it "rejects an invalid provider on update" $ do
      (store, job) <- seededJob
      eUpdated <- updateJob store (cjId job) (CronUpdate
        { cuName = Nothing, cuSchedule = Nothing, cuTimezone = Nothing
        , cuPrompt = Nothing, cuAgentDefId = Nothing
        , cuProvider = Just "../seal", cuModel = Nothing
        , cuEnabled = Nothing, cuOneShot = Nothing })
      eUpdated `shouldSatisfy` isLeft

  describe "Seal.Cron.Operations.setJobEnabled" $ do
    it "enables a job" $ do
      store <- memoryCronStore
      Right job <- createJob store "test" "0 9 * * 1-5" Nothing "prompt" Nothing Nothing Nothing False False
      eUpdated <- setJobEnabled store (cjId job) True
      case eUpdated of
        Right updated -> cjEnabled updated `shouldBe` True
        Left e -> expectationFailure (T.unpack e)

    it "disables a job" $ do
      store <- memoryCronStore
      Right job <- createJob store "test" "0 9 * * 1-5" Nothing "prompt" Nothing Nothing Nothing True False
      eUpdated <- setJobEnabled store (cjId job) False
      case eUpdated of
        Right updated -> cjEnabled updated `shouldBe` False
        Left e -> expectationFailure (T.unpack e)

    it "is idempotent (enabling an already-enabled job)" $ do
      store <- memoryCronStore
      Right job <- createJob store "test" "0 9 * * 1-5" Nothing "prompt" Nothing Nothing Nothing True False
      e1 <- setJobEnabled store (cjId job) True
      e2 <- setJobEnabled store (cjId job) True
      case (e1, e2) of
        (Right u1, Right u2) -> (cjEnabled u1, cjEnabled u2) `shouldBe` (True, True)
        _ -> expectationFailure "expected both to succeed"

    it "returns Left for an unknown job id" $ do
      store <- memoryCronStore
      let jid = case mkCronJobId "nonexistent" of Right j -> j; Left _ -> error "u"
      e <- setJobEnabled store jid True
      e `shouldSatisfy` isLeft

  describe "Seal.Cron.Operations.deleteJob" $ do
    it "deletes a job" $ do
      store <- memoryCronStore
      Right job <- createJob store "test" "0 9 * * 1-5" Nothing "prompt" Nothing Nothing Nothing False False
      r1 <- deleteJob store (cjId job)
      r1 `shouldBe` Right ()
      mJob <- csRead store (cjId job)
      mJob `shouldBe` Nothing

    it "is idempotent (deleting a non-existent job succeeds)" $ do
      store <- memoryCronStore
      let jid = case mkCronJobId "ghost" of Right j -> j; Left _ -> error "u"
      r <- deleteJob store jid
      r `shouldBe` Right ()

-- Helper predicates (avoid importing Data.Either's isLeft/isJull to keep
-- the module self-contained for the test-suite).
isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft (Right _) = False

isJust :: Maybe a -> Bool
isJust Nothing = False
isJust (Just _) = True

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left _) = False
