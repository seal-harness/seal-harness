{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.SkillSpec (spec) where

import Data.Aeson (object)
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as AKey
import Data.Aeson.KeyMap qualified as KM
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps (..))
import Data.Default (def)
import Seal.Command.Call (CallDispatcher)
import Seal.Command.Skill (PostLoadTurn, renderSkillInfo, renderSkillLine, skillCommandSpec)
import Seal.Command.Spec (CommandSpec (..), runCommandAction)
import Seal.Core.Types (OpName (..), mkSystemSessionId)
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
      { skId = i, skDescription = desc, skBody = body, skGroup = Nothing
      , skCreatedAt = aTime, skUpdatedAt = aTime, skSession = mkSystemSessionId "s1" }
    Left e   -> error ("invalid skill id: " <> T.unpack e)

-- | A canned 'Right' dispatcher that returns a fixed text body. Used for the
-- /skill load happy path.
fakeLoadDispatcher :: [Text] -> Bool -> CallDispatcher
fakeLoadDispatcher parts isErr _opName _val =
  pure (Right (OpResult (map TrpText parts) isErr (object [])))

-- | A canned 'Left' dispatcher for the /skill load error path.
fakeErrorDispatcher :: DispatchError -> CallDispatcher
fakeErrorDispatcher e _opName _val = pure (Left e)

-- | A recording dispatcher that captures the input Value it was called with
-- and returns a successful result. Used to verify the /skill load parser
-- forwards the trailing message in the opcode input.
recordingDispatcher :: IO (CallDispatcher, IO A.Value)
recordingDispatcher = do
  ref <- newIORef (A.Null :: A.Value)
  let disp _opName val = do
        modifyIORef' ref (const val)
        pure (Right (OpResult [TrpText "ok"] False (object [])))
  pure (disp, readIORef ref)

-- | Extract a required text field from an Aeson object Value, failing the
-- test if the value isn't an object or the field is absent/non-string.
requireTextField :: A.Value -> Text -> IO Text
requireTextField v key =
  case v of
    A.Object o -> case KM.lookup (AKey.fromText key) o of
      Just (A.String t) -> pure t
      other -> expectationFailure ("expected field " <> T.unpack key <> " (string) in input, got " <> show other) >> pure ""
    _ -> expectationFailure ("expected object input, got " <> show v) >> pure ""

-- | Run a /skill command against a backend preloaded with the given skills,
-- using a supplied CallDispatcher for /skill load.
runSkillWith :: [Skill] -> CallDispatcher -> [String] -> FakeCaps -> IO ()
runSkillWith skills dispatcher argv fc = do
  backend <- noneBackend
  mapM_ (sbCreate backend) skills
  let caps = def
        { ccSend         = \t -> modifyIORef' (fcSent fc) (t :)
        , ccPrompt       = \_ -> pure ""
        , ccPromptSecret = \_ -> pure ""
  , ccStreaming    = True  -- tests: streaming by default
        }
  case execParserPure defaultPrefs (csParserInfo (skillCommandSpec backend dispatcher Nothing)) argv of
    Success act -> runCommandAction act caps
    _           -> expectationFailure ("parse failed: " <> show argv)

-- | Run a /skill command with a PostLoadTurn callback. Used to test the
-- auto-turn behavior after a successful skill load.
runSkillWithPostLoad :: [Skill] -> CallDispatcher -> Maybe PostLoadTurn -> [String] -> FakeCaps -> IO ()
runSkillWithPostLoad skills dispatcher mPostLoad argv fc = do
  backend <- noneBackend
  mapM_ (sbCreate backend) skills
  let caps = def
        { ccSend         = \t -> modifyIORef' (fcSent fc) (t :)
        , ccPrompt       = \_ -> pure ""
        , ccPromptSecret = \_ -> pure ""
  , ccStreaming    = True
        }
  case execParserPure defaultPrefs (csParserInfo (skillCommandSpec backend dispatcher mPostLoad)) argv of
    Success act -> runCommandAction act caps
    _           -> expectationFailure ("parse failed: " <> show argv)

-- | A recording PostLoadTurn that captures whether it was called and with
-- what message text.
recordingPostLoad :: IO (PostLoadTurn, IO (Maybe Text))
recordingPostLoad = do
  ref <- newIORef (Nothing :: Maybe Text)
  let cb msg = writeIORef ref (Just msg)
  pure (cb, readIORef ref)

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
    it "echoes only the header line on a successful load (body goes to transcript)" $ do
      (fc, _) <- makeFakeCaps []
      let dispatcher = fakeLoadDispatcher ["# greet\n\ngreeting skill\n\n---\n\nsay hi"] False
      runSkillWith [] dispatcher ["load", "greet"] fc
      sent <- getSent fc
      sent `shouldBe` ["$ /skill load greet"]

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

    it "forwards the trailing message in the opcode input" $ do
      -- /skill load start #123 should dispatch SKILL_LOAD with
      -- input.message = "#123" so recordSkillLoadResult appends it to
      -- conversation.jsonl after the skill body.
      (fc, _) <- makeFakeCaps []
      (dispatcher, getInput) <- recordingDispatcher
      runSkillWith [] dispatcher ["load", "start", "#123"] fc
      val <- getInput
      requireTextField val "id" `shouldReturn` "start"
      requireTextField val "message" `shouldReturn` "#123"

    it "omits the message (empty string) when no trailing text is supplied" $ do
      (fc, _) <- makeFakeCaps []
      (dispatcher, getInput) <- recordingDispatcher
      runSkillWith [] dispatcher ["load", "greet"] fc
      val <- getInput
      requireTextField val "id" `shouldReturn` "greet"
      requireTextField val "message" `shouldReturn` ""

    it "joins multiple trailing words with spaces" $ do
      (fc, _) <- makeFakeCaps []
      (dispatcher, getInput) <- recordingDispatcher
      runSkillWith [] dispatcher ["load", "start", "do", "something", "now"] fc
      val <- getInput
      requireTextField val "message" `shouldReturn` "do something now"

  describe "/skill load auto-turn" $ do
    it "calls PostLoadTurn with the trailing message after a successful load" $ do
      (fc, _) <- makeFakeCaps []
      (dispatcher, _getInput) <- recordingDispatcher
      (postLoad, getPostLoad) <- recordingPostLoad
      runSkillWithPostLoad [] dispatcher (Just postLoad) ["load", "start", "do", "something"] fc
      mCalled <- getPostLoad
      mCalled `shouldBe` Just "do something"

    it "does NOT call PostLoadTurn when no trailing message is supplied" $ do
      (fc, _) <- makeFakeCaps []
      (dispatcher, _getInput) <- recordingDispatcher
      (postLoad, getPostLoad) <- recordingPostLoad
      runSkillWithPostLoad [] dispatcher (Just postLoad) ["load", "greet"] fc
      mCalled <- getPostLoad
      mCalled `shouldBe` Nothing

    it "does NOT call PostLoadTurn when the load fails (error result)" $ do
      (fc, _) <- makeFakeCaps []
      let dispatcher = fakeLoadDispatcher ["skill not found"] True
      (postLoad, getPostLoad) <- recordingPostLoad
      runSkillWithPostLoad [] dispatcher (Just postLoad) ["load", "nope", "do", "something"] fc
      mCalled <- getPostLoad
      mCalled `shouldBe` Nothing

    it "does NOT call PostLoadTurn when the dispatch returns Left" $ do
      (fc, _) <- makeFakeCaps []
      let dispatcher = fakeErrorDispatcher (OpNotFound (OpName "SKILL_LOAD"))
      (postLoad, getPostLoad) <- recordingPostLoad
      runSkillWithPostLoad [] dispatcher (Just postLoad) ["load", "greet", "do", "something"] fc
      mCalled <- getPostLoad
      mCalled `shouldBe` Nothing

    it "does NOT call PostLoadTurn when callback is Nothing" $ do
      (fc, _) <- makeFakeCaps []
      (dispatcher, _getInput) <- recordingDispatcher
      runSkillWithPostLoad [] dispatcher Nothing ["load", "start", "do", "something"] fc
      -- No assertion needed — the test passes if it doesn't crash.
      -- The behavior is: no turn is triggered (Nothing callback).
      pure ()

    it "does NOT call PostLoadTurn for whitespace-only trailing message" $ do
      (fc, _) <- makeFakeCaps []
      (dispatcher, _getInput) <- recordingDispatcher
      (postLoad, getPostLoad) <- recordingPostLoad
      runSkillWithPostLoad [] dispatcher (Just postLoad) ["load", "greet", "   "] fc
      mCalled <- getPostLoad
      mCalled `shouldBe` Nothing
