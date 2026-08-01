{-# LANGUAGE OverloadedStrings #-}
module Seal.Skills.PromptSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import Seal.Core.Types (mkSystemSessionId)
import Seal.Skills.Backend (SkillBackend (..), noneBackend)
import Seal.Skills.Prompt (availableSkillsBlock, availableSkillsBudget, injectAvailableSkills)
import Seal.Skills.Types (Skill (..), mkSkillId)

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)

mkSkill :: Text -> Text -> Text -> Maybe Text -> Skill
mkSkill sid desc body mGroup =
  case mkSkillId sid of
    Right i  -> Skill
      { skId = i
      , skDescription = desc
      , skBody = body
      , skGroup = mGroup
      , skCreatedAt = sampleTime
      , skUpdatedAt = sampleTime
      , skSession = mkSystemSessionId "test"
      }
    Left _err -> error "invalid skill id in test fixture"

spec :: Spec
spec = describe "Seal.Skills.Prompt" $ do
  describe "availableSkillsBlock" $ do
    it "returns the empty string when there are no skills" $
      availableSkillsBlock [] `shouldBe` ""

    it "wraps a single skill in <available_skills> tags with id + description" $ do
      let block = availableSkillsBlock [ mkSkill "greet" "say hello" "body" Nothing ]
      T.isInfixOf "<available_skills>" block `shouldBe` True
      T.isInfixOf "</available_skills>" block `shouldBe` True
      T.isInfixOf "- greet: say hello" block `shouldBe` True
      T.isInfixOf "SKILL_LOAD" block `shouldBe` True

    it "groups skills by skGroup with a header per group" $ do
      let block = availableSkillsBlock
            [ mkSkill "alpha" "a desc" "b" (Just "core")
            , mkSkill "beta"  "b desc" "b" (Just "ops")
            , mkSkill "gamma" "g desc" "b" (Just "core")
            ]
      T.isInfixOf "## core" block `shouldBe` True
      T.isInfixOf "## ops" block `shouldBe` True
      -- core group has alpha + gamma; ops has beta.
      T.isInfixOf "- alpha: a desc" block `shouldBe` True
      T.isInfixOf "- gamma: g desc" block `shouldBe` True
      T.isInfixOf "- beta: b desc" block `shouldBe` True

    it "renders ungrouped skills under a default '## Skills' header" $ do
      let block = availableSkillsBlock [ mkSkill "solo" "no group" "b" Nothing ]
      T.isInfixOf "## Skills" block `shouldBe` True
      T.isInfixOf "- solo: no group" block `shouldBe` True

    it "uses '(no description)' for an empty description" $ do
      let block = availableSkillsBlock [ mkSkill "blank" "" "b" Nothing ]
      T.isInfixOf "- blank: (no description)" block `shouldBe` True

    it "truncates a block that exceeds the budget" $ do
      -- Build a skill with a huge body... but the catalog only carries id
      -- + description, so make many skills with long descriptions to
      -- exceed the budget.
      let longDesc = T.replicate 256 "x"
          skills = [ mkSkill (T.pack ("s" <> show n)) longDesc "b" (Just "g")
                   | n <- [1 .. 200 :: Int] ]
          block = availableSkillsBlock skills
      T.length block `shouldSatisfy` (<= availableSkillsBudget + 200) -- truncation marker slack
      T.isInfixOf "truncated" block `shouldBe` True

  describe "injectAvailableSkills" $ do
    it "appends the catalog after an existing prompt" $ do
      backend <- noneBackend
      let s = mkSkill "greet" "say hello" "body" Nothing
      sbCreate backend s
      mOut <- injectAvailableSkills backend (Just "BASE PROMPT")
      case mOut of
        Nothing     -> expectationFailure "expected a prompt"
        Just out -> do
          T.isPrefixOf "BASE PROMPT" out `shouldBe` True
          T.isInfixOf "<available_skills>" out `shouldBe` True
          T.isInfixOf "- greet: say hello" out `shouldBe` True

    it "makes the catalog the entire prompt when there was none" $ do
      backend <- noneBackend
      let s = mkSkill "greet" "say hello" "body" Nothing
      sbCreate backend s
      mOut <- injectAvailableSkills backend Nothing
      case mOut of
        Nothing -> expectationFailure "expected a prompt"
        Just out -> T.isPrefixOf "<available_skills>" out `shouldBe` True

    it "returns the prompt unchanged when the backend has no skills" $ do
      backend <- noneBackend
      mOut <- injectAvailableSkills backend (Just "BASE PROMPT")
      mOut `shouldBe` Just "BASE PROMPT"

    it "returns Nothing when the backend has no skills and there was no prompt" $ do
      backend <- noneBackend
      mOut <- injectAvailableSkills backend Nothing
      mOut `shouldBe` Nothing