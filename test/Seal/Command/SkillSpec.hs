{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.SkillSpec (spec) where

import Data.IORef (modifyIORef')
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Skill (renderSkillInfo, renderSkillLine, skillCommandSpec)
import Seal.Command.Spec (CommandSpec (..), runCommandAction)
import Seal.Core.Types (SessionId (..))
import Seal.Skills.Backend (noneBackend, sbCreate)
import Seal.Skills.Types (Skill (..), mkSkillId)
import Seal.TestHelpers.FakeCaps (FakeCaps (..), getSent, makeFakeCaps)

aTime :: UTCTime
aTime = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)

mkSkill :: Text -> Text -> Text -> IO Skill
mkSkill sid desc body =
  case mkSkillId sid of
    Right i  -> pure Skill
      { skId = i, skDescription = desc, skBody = body
      , skCreatedAt = aTime, skUpdatedAt = aTime, skSession = SessionId "s1" }
    Left e   -> error ("invalid skill id: " <> T.unpack e)

-- | Run a /skill command against a backend preloaded with the given skills.
runSkillWith :: [Skill] -> [String] -> FakeCaps -> IO ()
runSkillWith skills argv fc = do
  backend <- noneBackend
  mapM_ (sbCreate backend) skills
  let caps = ChannelCaps
        { ccSend         = \t -> modifyIORef' (fcSent fc) (t :)
        , ccPrompt       = \_ -> pure ""
        , ccPromptSecret = \_ -> pure ""
        }
  case execParserPure defaultPrefs (csParserInfo (skillCommandSpec backend)) argv of
    Success act -> runCommandAction act caps
    _           -> expectationFailure ("parse failed: " <> show argv)

spec :: Spec
spec = describe "Seal.Command.Skill" $ do
  describe "pure renderers" $ do
    it "renderSkillLine shows id + description" $ do
      s <- mkSkill "greet" "greeting skill" "say hi"
      renderSkillLine s `shouldBe` "greet  greeting skill"

    it "renderSkillInfo includes id, description, and body" $ do
      s <- mkSkill "greet" "greeting skill" "say hello warmly"
      let ls = T.unlines (renderSkillInfo s)
      ls `shouldSatisfy` ("greet" `T.isInfixOf`)
      ls `shouldSatisfy` ("greeting skill" `T.isInfixOf`)
      ls `shouldSatisfy` ("say hello warmly" `T.isInfixOf`)

  describe "/skill commands" $ do
    it "list shows defined skills" $ do
      (fc, _) <- makeFakeCaps []
      s1 <- mkSkill "greet" "greeting skill" "say hi"
      s2 <- mkSkill "farewell" "farewell skill" "bye"
      runSkillWith [s1, s2] ["list"] fc
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("greet" `T.isInfixOf`)
      T.unlines sent `shouldSatisfy` ("farewell" `T.isInfixOf`)

    it "list reports none when empty" $ do
      (fc, _) <- makeFakeCaps []
      runSkillWith [] ["list"] fc
      sent <- getSent fc
      sent `shouldBe` ["no skills defined"]

    it "info shows the full body of a skill" $ do
      (fc, _) <- makeFakeCaps []
      s <- mkSkill "greet" "greeting skill" "say hello warmly"
      runSkillWith [s] ["info", "greet"] fc
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("say hello warmly" `T.isInfixOf`)

    it "info reports not found for a missing skill" $ do
      (fc, _) <- makeFakeCaps []
      runSkillWith [] ["info", "nope"] fc
      sent <- getSent fc
      sent `shouldBe` ["skill not found: nope"]

    it "info rejects an invalid id" $ do
      (fc, _) <- makeFakeCaps []
      runSkillWith [] ["info", "bad/id"] fc
      sent <- getSent fc
      sent `shouldBe` ["invalid skill id: \"bad/id\""]