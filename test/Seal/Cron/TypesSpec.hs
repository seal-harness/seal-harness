{-# LANGUAGE OverloadedStrings #-}
module Seal.Cron.TypesSpec (spec) where

import Data.Aeson (decode, encode, object, (.=))
import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec
import Test.QuickCheck

import Seal.Cron.Types
import Seal.TestHelpers.Arbitrary ()

-- | QuickCheck generator for valid CronJobId characters.
newtype ValidJobIdText = ValidJobIdText Text
  deriving stock (Eq, Show)

instance Arbitrary ValidJobIdText where
  arbitrary = do
    n <- choose (1, 32)
    chars <- vectorOf n (elements (['a'..'z'] ++ ['0'..'9'] ++ "-"))
    pure (ValidJobIdText (T.pack (dropWhile (== '-') chars)))

spec :: Spec
spec = do
  describe "mkCronJobId" $ do
    it "accepts valid ids" $ do
      mkCronJobId "morning-review" `shouldBe` Right (CronJobId "morning-review")
      mkCronJobId "job-1" `shouldBe` Right (CronJobId "job-1")
      mkCronJobId "a" `shouldBe` Right (CronJobId "a")

    it "rejects empty" $
      mkCronJobId "" `shouldSatisfy` isLeft

    it "rejects too long (>64 chars)" $ do
      let longId = T.replicate 65 "a"
      mkCronJobId longId `shouldSatisfy` isLeft

    it "rejects leading dash" $
      mkCronJobId "-job" `shouldSatisfy` isLeft

    it "rejects invalid chars (uppercase, slashes, dots)" $ do
      mkCronJobId "Job" `shouldSatisfy` isLeft
      mkCronJobId "job/id" `shouldSatisfy` isLeft
      mkCronJobId "job.id" `shouldSatisfy` isLeft
      mkCronJobId "job test" `shouldSatisfy` isLeft
      mkCronJobId "../seal" `shouldSatisfy` isLeft

    it "accepts max length (64 chars)" $ do
      let maxId = T.replicate 64 "a"
      mkCronJobId maxId `shouldBe` Right (CronJobId maxId)

  describe "mkCronExpr" $ do
    it "accepts valid 5-field cron expressions" $ do
      mkCronExpr "0 9 * * 1-5" `shouldSatisfy` isRight
      mkCronExpr "*/5 * * * *" `shouldSatisfy` isRight
      mkCronExpr "0 0 1 1 *" `shouldSatisfy` isRight
      mkCronExpr "30 2 * * *" `shouldSatisfy` isRight
      mkCronExpr "0,30 * * * *" `shouldSatisfy` isRight

    it "rejects empty" $
      mkCronExpr "" `shouldSatisfy` isLeft

    it "rejects invalid expressions" $ do
      mkCronExpr "* * * *" `shouldSatisfy` isLeft
      mkCronExpr "* * * * * *" `shouldSatisfy` isLeft
      mkCronExpr "99 * * * *" `shouldSatisfy` isLeft
      mkCronExpr "* 99 * * *" `shouldSatisfy` isLeft
      mkCronExpr "abc * * * *" `shouldSatisfy` isLeft

  describe "mkCronTimeZone" $ do
    it "accepts valid IANA timezones" $ do
      mkCronTimeZone "America/New_York" `shouldSatisfy` isRight
      mkCronTimeZone "Europe/London" `shouldSatisfy` isRight
      mkCronTimeZone "Asia/Tokyo" `shouldSatisfy` isRight
      mkCronTimeZone "US/Pacific" `shouldSatisfy` isRight
      mkCronTimeZone "America/Argentina/Buenos_Aires" `shouldSatisfy` isRight

    it "rejects empty" $
      mkCronTimeZone "" `shouldSatisfy` isLeft

    it "rejects invalid format" $ do
      mkCronTimeZone "UTC" `shouldSatisfy` isLeft
      mkCronTimeZone "New_York" `shouldSatisfy` isLeft
      mkCronTimeZone "/" `shouldSatisfy` isLeft
      mkCronTimeZone "America/" `shouldSatisfy` isLeft

  describe "slugify" $ do
    it "converts to lowercase" $
      slugify "Morning Review" `shouldBe` "morning-review"

    it "replaces non-alphanumeric with dashes" $ do
      slugify "daily code review!" `shouldBe` "daily-code-review"
      slugify "job_1" `shouldBe` "job-1"

    it "collapses consecutive dashes" $
      slugify "a   b" `shouldBe` "a-b"

    it "strips leading/trailing dashes" $
      slugify "---test---" `shouldBe` "test"

    it "truncates to 32 chars" $ do
      let longName = T.replicate 50 "a"
          result = slugify longName
      T.length result `shouldBe` 32

    it "returns 'job' for empty or all-special-chars input" $ do
      slugify "" `shouldBe` "job"
      slugify "!!!" `shouldBe` "job"
      slugify "---" `shouldBe` "job"

    it "is deterministic" $
      slugify "Daily Code Review" `shouldBe` slugify "Daily Code Review"

  describe "computeNextFire" $ do
    it "computes next fire for every-minute schedule" $ do
      let expr = case mkCronExpr "* * * * *" of Right e -> e; Left _ -> error "unreachable"
          refTime = UTCTime (fromGregorian 2026 10 14) (secondsToDiffTime 0)
      result <- computeNextFire expr Nothing refTime
      case result of
        Just nextFire -> nextFire `shouldBe` UTCTime (fromGregorian 2026 10 14) (secondsToDiffTime 60)
        Nothing -> expectationFailure "expected Just, got Nothing"

    it "computes next fire for daily 9am schedule" $ do
      let expr = case mkCronExpr "0 9 * * *" of Right e -> e; Left _ -> error "unreachable"
          refTime = UTCTime (fromGregorian 2026 10 14) (secondsToDiffTime (8 * 3600))
      result <- computeNextFire expr Nothing refTime
      case result of
        Just nextFire -> do
          utctDay nextFire `shouldBe` fromGregorian 2026 10 14
          floor (utctDayTime nextFire) `shouldBe` (9 * 3600 :: Int)
        Nothing -> expectationFailure "expected Just, got Nothing"

    it "computes next fire for weekday schedule (skips weekend)" $ do
      let expr = case mkCronExpr "0 9 * * 1-5" of Right e -> e; Left _ -> error "unreachable"
          refTime = UTCTime (fromGregorian 2026 10 17) (secondsToDiffTime 0)
      result <- computeNextFire expr Nothing refTime
      case result of
        Just nextFire -> do
          utctDay nextFire `shouldBe` fromGregorian 2026 10 19
          floor (utctDayTime nextFire) `shouldBe` (9 * 3600 :: Int)
        Nothing -> expectationFailure "expected Just, got Nothing"

  describe "ToJSON/FromJSON round-trip" $ do
    it "CronJobId round-trips via object" $ do
      let cid = case mkCronJobId "test-job" of Right c -> c; Left _ -> error "unreachable"
      let jsonStr = encode (object ["id" .= cronJobIdText cid])
      decode jsonStr `shouldBe` Just cid

    it "CronExpr round-trips via text" $ do
      let expr = case mkCronExpr "0 9 * * 1-5" of Right e -> e; Left _ -> error "unreachable"
      decode (encode expr) `shouldBe` Just expr

    it "CronRunStatus round-trips" $ do
      decode (encode CrPending) `shouldBe` Just CrPending
      decode (encode CrRunning) `shouldBe` Just CrRunning
      decode (encode CrCompleted) `shouldBe` Just CrCompleted
      decode (encode CrFailed) `shouldBe` Just CrFailed

  describe "QuickCheck properties" $ do
    it "CronJobId round-trip: mkCronJobId (cronJobIdText id) == Right id" $
      property $ \(ValidJobIdText t) ->
        case mkCronJobId t of
          Right cid -> mkCronJobId (cronJobIdText cid) == Right cid
          Left _ -> True  -- generated text might not be valid; skip

    it "CronJobId is path-safe (no slashes, dots, or ..)" $
      property $ \(ValidJobIdText t) ->
        case mkCronJobId t of
          Right cid ->
            let txt = cronJobIdText cid
            in not ("/" `T.isInfixOf` txt)
               && not ("." `T.isInfixOf` txt)
               && not (".." `T.isInfixOf` txt)
          Left _ -> True

    it "slugify is deterministic" $
      property $ \(name :: Text) -> slugify name == slugify name

    it "slugify result contains only [a-z0-9-] or is 'job'" $
      property $ \(name :: Text) ->
        let result = slugify name
        in result == "job" || T.all (\c -> isAsciiLower c || isDigit c || c == '-') result

    it "slugify result is at most 32 chars" $
      property $ \(name :: Text) -> T.length (slugify name) <= 32

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft (Right _) = False

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left _) = False
