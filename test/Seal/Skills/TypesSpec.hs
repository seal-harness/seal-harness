{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
module Seal.Skills.TypesSpec (spec) where

import Data.Aeson (decode, encode)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec
import Test.QuickCheck

import Seal.Core.Types (mkSystemSessionId)
import Seal.Skills.Types
import Seal.TestHelpers.Arbitrary ()

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)

-- | A known-good sample skill id, total construction via 'mkSkillId'.
sampleSkillId :: SkillId
sampleSkillId = case mkSkillId "s1" of
  Right sid -> sid
  Left _    -> SkillId "fallback"  -- unreachable; "s1" always validates

sampleSkill :: Skill
sampleSkill = Skill
  { skId = sampleSkillId
  , skDescription = "greeting skill"
  , skBody = "say hello"
  , skCreatedAt = sampleTime
  , skUpdatedAt = sampleTime
  , skSession = mkSystemSessionId "s1"
  }

spec :: Spec
spec = describe "Seal.Skills.Types" $ do
  describe "mkSkillId" $ do
    it "accepts a valid id" $
      mkSkillId "my_skill-1" `shouldBe` Right (SkillId "my_skill-1")

    it "rejects an empty id" $
      mkSkillId "" `shouldSatisfy` isLeft

    it "rejects a leading-dot id" $
      mkSkillId ".hidden" `shouldSatisfy` isLeft

    it "rejects an id with disallowed chars" $
      mkSkillId "bad/id" `shouldSatisfy` isLeft

    it "round-trips valid ids through the predicate (property)" $
      property $ \case
        SkillId t -> mkSkillId t === Right (SkillId t)

  describe "Skill JSON" $ do
    it "round-trips through aeson" $
      property $ \s ->
        (decode (encode (s :: Skill)) :: Maybe Skill) === Just s

    it "the sample skill round-trips" $
      (decode (encode sampleSkill) :: Maybe Skill) `shouldBe` Just sampleSkill

isLeft :: Either a b -> Bool
isLeft (Left _)  = True
isLeft (Right _) = False