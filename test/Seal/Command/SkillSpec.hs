{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.SkillSpec (spec) where

import Data.Aeson (object)
import Data.IORef (modifyIORef')
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Call (CallDispatcher)
import Seal.Command.Skill (renderSkillInfo, renderSkillLine, skillCommandSpec)
import Seal.Command.Spec (CommandSpec (..), runCommandAction)
import Seal.Core.Types (OpName (..), SessionId (..))
import Seal.ISA.Dispatch (DispatchError (..))
import Seal.ISA.Opcode (OpResult (..))
import Seal.Providers.Class (ToolResultPart (..))
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

-- | A canned 'Right' dispatcher that returns a fixed text body. Used for the
-- /skill load happy path.
fakeLoadDispatcher :: [Text] -> Bool -> CallDispatcher
fakeLoadDispatcher parts isErr _opName _val =
  pure (Right (OpResult (map TrpText parts) isErr (object [])))

-- | A canned 'Left' dispatcher for the /skill load error path.
fakeErrorDispatcher :: DispatchError -> CallDispatcher
fakeErrorDispatcher e _opName _val = pure (Left e)

-- | Run a /skill command against a backend preloaded with the given skills,
-- using a supplied CallDispatcher for /skill load.
runSkillWith :: [Skill] -> CallDispatcher -> [String] -> FakeCaps -> IO ()
runSkillWith skills dispatcher argv fc = do
  backend <- noneBackend
  mapM_ (sbCreate backend) skills
  let caps = ChannelCaps
        { ccSend         = \t -> modifyIORef' (fcSent fc) (t :)
        , ccPrompt       = \_ -> pure ""
        , ccPromptSecret = \_ -> pure ""
        }
  case execParserPure defaultPrefs (csParserInfo (skillCommandSpec backend dispatcher)) argv of
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
    -- A placeholder dispatcher for the list/info tests (which don't invoke it).
    let noLoad = fakeErrorDispatcher (OpNotFound (OpName "SKILL_LOAD"))

    it "list shows defined skills" $ do
      (fc, _) <- makeFakeCaps []
      s1 <- mkSkill "greet" "greeting skill" "say hi"
      s2 <- mkSkill "farewell" "farewell skill" "bye"
      runSkillWith [s1, s2] noLoad ["list"] fc
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("greet" `T.isInfixOf`)
      T.unlines sent `shouldSatisfy` ("farewell" `T.isInfixOf`)

    it "list reports none when empty" $ do
      (fc, _) <- makeFakeCaps []
      runSkillWith [] noLoad ["list"] fc
      sent <- getSent fc
      sent `shouldBe` ["no skills defined"]

    it "info shows the full body of a skill" $ do
      (fc, _) <- makeFakeCaps []
      s <- mkSkill "greet" "greeting skill" "say hello warmly"
      runSkillWith [s] noLoad ["info", "greet"] fc
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("say hello warmly" `T.isInfixOf`)

    it "info reports not found for a missing skill" $ do
      (fc, _) <- makeFakeCaps []
      runSkillWith [] noLoad ["info", "nope"] fc
      sent <- getSent fc
      sent `shouldBe` ["skill not found: nope"]

    it "info rejects an invalid id" $ do
      (fc, _) <- makeFakeCaps []
      runSkillWith [] noLoad ["info", "bad/id"] fc
      sent <- getSent fc
      sent `shouldBe` ["invalid skill id: \"bad/id\""]

  describe "/skill load" $ do
    it "renders the body and an echo header line on a valid id" $ do
      (fc, _) <- makeFakeCaps []
      let dispatcher = fakeLoadDispatcher ["# greet\n\ngreeting skill\n\n---\n\nsay hi"] False
      runSkillWith [] dispatcher ["load", "greet"] fc
      sent <- getSent fc
      case sent of
        (echo : rest) -> do
          echo `shouldBe` "$ /skill load greet"
          T.unlines rest `shouldSatisfy` ("say hi" `T.isInfixOf`)
        _ -> expectationFailure "expected at least the echo line"

    it "reports skill not found when the dispatcher returns an error result" $ do
      (fc, _) <- makeFakeCaps []
      let dispatcher = fakeLoadDispatcher ["skill not found"] True
      runSkillWith [] dispatcher ["load", "nope"] fc
      sent <- getSent fc
      case sent of
        (echo : rest) -> do
          echo `shouldBe` "$ /skill load nope"
          T.unlines rest `shouldSatisfy` ("skill not found" `T.isInfixOf`)
        _ -> expectationFailure "expected at least the echo line"

    it "renders a dispatcher Left (OpNotFound) gracefully" $ do
      (fc, _) <- makeFakeCaps []
      let dispatcher = fakeErrorDispatcher (OpNotFound (OpName "SKILL_LOAD"))
      runSkillWith [] dispatcher ["load", "greet"] fc
      sent <- getSent fc
      case sent of
        (echo : rest) -> do
          echo `shouldBe` "$ /skill load greet"
          T.unlines rest `shouldSatisfy` ("opcode not found" `T.isInfixOf`)
        _ -> expectationFailure "expected at least the echo line"