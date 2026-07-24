{-# LANGUAGE OverloadedStrings #-}
module Seal.Skills.AutoloadSpec (spec) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import Seal.Core.Types (mkSystemSessionId)
import Seal.Skills.Autoload (injectAutoloadSkill, renderSkillForPrompt)
import Seal.Skills.Backend (SkillBackend (..))
import Seal.Skills.Types (Skill (..), SkillId (..), mkSkillId)

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)

mkSkill :: Text -> Text -> Text -> Skill
mkSkill sid desc body =
  case mkSkillId sid of
    Right i  -> Skill
      { skId = i
      , skDescription = desc
      , skBody = body
      , skCreatedAt = sampleTime
      , skUpdatedAt = sampleTime
      , skSession = mkSystemSessionId "test"
      }
    Left _err -> error "invalid skill id in test fixture"

-- | A tiny in-memory backend backed by an IORef, so the spec does not
-- touch disk. Equivalent to 'noneBackend' but built inline for clarity.
memBackend :: IO SkillBackend
memBackend = do
  ref <- newIORef (Map.empty :: Map.Map SkillId Skill)
  pure SkillBackend
    { sbCreate = \s -> modifyIORef' ref (Map.insert (skId s) s)
    , sbRead   = \sid -> Map.lookup sid <$> readIORef ref
    , sbList   = Map.elems <$> readIORef ref
    , sbUpdate = \s -> modifyIORef' ref (Map.insert (skId s) s)
    , sbDelete = modifyIORef' ref . Map.delete
    }

spec :: Spec
spec = describe "Seal.Skills.Autoload" $ do
  describe "injectAutoloadSkill" $ do
    it "appends the skill body to an existing system prompt" $ do
      backend <- memBackend
      sbCreate backend (mkSkill "seal-usage" "workdir contract" "stay in your workdir")
      result <- injectAutoloadSkill backend (Just "seal-usage") (Just "base prompt")
      case result of
        Just t  -> do
          T.unpack t `shouldContain` "base prompt"
          T.unpack t `shouldContain` "stay in your workdir"
          T.unpack t `shouldContain` "Auto-loaded skill: seal-usage"
        Nothing -> expectationFailure "expected a system prompt"

    it "uses the skill body as the whole prompt when base is Nothing" $ do
      backend <- memBackend
      sbCreate backend (mkSkill "seal-usage" "workdir contract" "stay in your workdir")
      result <- injectAutoloadSkill backend (Just "seal-usage") Nothing
      case result of
        Just t  -> do
          T.unpack t `shouldContain` "stay in your workdir"
          T.unpack t `shouldContain` "Auto-loaded skill: seal-usage"
          T.unpack t `shouldNotContain` "\n\n\n"
        Nothing -> expectationFailure "expected a system prompt"

    it "returns the prompt unchanged when autoload id is Nothing (disabled)" $ do
      backend <- memBackend
      result <- injectAutoloadSkill backend Nothing (Just "base prompt")
      result `shouldBe` Just "base prompt"

    it "returns Nothing when disabled and base is Nothing" $ do
      backend <- memBackend
      result <- injectAutoloadSkill backend Nothing Nothing
      result `shouldBe` (Nothing :: Maybe Text)

    it "soft-fails (returns prompt unchanged) when the skill is missing" $ do
      backend <- memBackend
      -- No skill created
      result <- injectAutoloadSkill backend (Just "seal-usage") (Just "base prompt")
      result `shouldBe` Just "base prompt"

    it "soft-fails when the skill id is invalid" $ do
      backend <- memBackend
      result <- injectAutoloadSkill backend (Just "bad id!") (Just "base prompt")
      result `shouldBe` Just "base prompt"

  describe "renderSkillForPrompt" $ do
    it "prepends the skill header + body to the base prompt" $ do
      let skill = mkSkill "seal-usage" "desc" "the body"
          out = renderSkillForPrompt (Just "base") skill
      T.unpack out `shouldContain` "base"
      T.unpack out `shouldContain` "the body"
      T.unpack out `shouldContain` "Auto-loaded skill: seal-usage"

    it "uses just the rendered skill when base is Nothing" $ do
      let skill = mkSkill "seal-usage" "desc" "the body"
          out = renderSkillForPrompt Nothing skill
      T.unpack out `shouldContain` "the body"
      T.unpack out `shouldNotContain` "\n\n\n"