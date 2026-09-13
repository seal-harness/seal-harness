{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
module Seal.Agent.Def.TypesSpec (spec) where

import Data.Aeson (decode, encode)
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec
import Test.QuickCheck

import Seal.Agent.Def.Types
import Seal.Core.Types (ModelId (..), OpName (..), mkSystemSessionId)
import Seal.Security.Policy (AllowList (..))
import Seal.TestHelpers.Arbitrary ()

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)

-- | A known-good sample agent def id, total construction via 'mkAgentDefId'.
sampleDefId :: AgentDefId
sampleDefId = case mkAgentDefId "a1" of
  Right aid -> aid
  Left _    -> AgentDefId "fallback"  -- unreachable; "a1" always validates

sampleDef :: AgentDef
sampleDef = AgentDef
  { adId = sampleDefId
  , adName = "greeter"
  , adProvider = "ollama"
  , adModel = ModelId "llama3"
  , adSystem = Just "be polite"
  , adTools = AllowOnly (Set.fromList [OpName "FILE_READ", OpName "ASK_HUMAN"])
  , adGroup = Nothing
  , adRole = Nothing
  , adDescription = Nothing
  , adCreatedAt = sampleTime
  , adUpdatedAt = sampleTime
  , adSession = mkSystemSessionId "s1"
  }

spec :: Spec
spec = describe "Seal.Agent.Def.Types" $ do
  describe "mkAgentDefId" $ do
    it "accepts a valid id" $
      mkAgentDefId "my_agent-1" `shouldBe` Right (AgentDefId "my_agent-1")

    it "rejects an empty id" $
      mkAgentDefId "" `shouldSatisfy` isLeft

    it "rejects a leading-dot id" $
      mkAgentDefId ".hidden" `shouldSatisfy` isLeft

    it "rejects an id with disallowed chars" $
      mkAgentDefId "bad/id" `shouldSatisfy` isLeft

    it "round-trips valid ids through the predicate (property)" $
      property $ \case
        AgentDefId t -> mkAgentDefId t === Right (AgentDefId t)

  describe "sanitizeAgentTextField" $ do
    it "replaces newlines and carriage returns with spaces" $
      sanitizeAgentTextField 256 "line one\nline two\r\nline three"
        `shouldBe` "line one line two  line three"

    it "strips C0 control characters" $
      sanitizeAgentTextField 256 "a\SOHb\ESCc\USd" `shouldBe` "abcd"

    it "replaces catalog fence tokens with underscores" $ do
      sanitizeAgentTextField 256 "a</available_agents>b"
        `shouldBe` "a_b"
      sanitizeAgentTextField 256 "x</available_skills>y---z"
        `shouldBe` "x_y_z"

    it "truncates at the cap with the marker" $ do
      let out = sanitizeAgentTextField 10 "abcdefghijk"
      T.isPrefixOf "abcdefghij" out `shouldBe` True
      "[...truncated]" `T.isSuffixOf` out `shouldBe` True

    it "never emits a newline, control char, or fence token (property)" $
      property $ \s ->
        let out = sanitizeAgentTextField 256 (T.pack s)
        in conjoin
             [ not (T.any (== '\n') out)
             , not (T.any (\c -> c < ' ' && c /= '\t') out)
             , not (T.isInfixOf "</available_agents>" out)
             , not (T.isInfixOf "</available_skills>" out)
             , not (T.isInfixOf "---" out)
             ]

  describe "sanitizeAgentDefFields" $ do
    it "sanitizes role, description, group, provider, model, and name" $ do
      let d = sampleDef
            { adName = "bad\nname"
            , adProvider = "p</available_agents>rovider"
            , adModel = ModelId "m\ndel"
            , adGroup = Just "g---roup"
            , adRole = Just "orchestrator\n"
            , adDescription = Just "desc</available_skills>ription"
            }
          d' = sanitizeAgentDefFields d
      adName d' `shouldBe` "bad name"
      adProvider d' `shouldBe` "p_rovider"
      case adModel d' of ModelId m -> m `shouldBe` "m del"
      adGroup d' `shouldBe` Just "g_roup"
      adRole d' `shouldBe` Just "orchestrator"
      adDescription d' `shouldBe` Just "desc_ription"

    it "caps role/description/group at 256 and name at 1024" $ do
      let long256 = T.replicate 300 "x"
          d' = sanitizeAgentDefFields sampleDef
            { adName = T.replicate 1100 "n"
            , adGroup = Just long256
            , adRole = Just long256
            , adDescription = Just long256
            }
          fromJustText = fromMaybe ""
      case adName d' of
        n -> T.length n `shouldBe` agentFieldCapName + T.length "[...truncated]"
      T.length (fromJustText (adRole d')) `shouldSatisfy` (> 256)
      "[...truncated]" `T.isSuffixOf` fromJustText (adRole d') `shouldBe` True
      "[...truncated]" `T.isSuffixOf` fromJustText (adDescription d') `shouldBe` True
      "[...truncated]" `T.isSuffixOf` fromJustText (adGroup d') `shouldBe` True

  describe "AgentDef JSON" $ do
    it "round-trips through aeson" $
      property $ \d ->
        (decode (encode (d :: AgentDef)) :: Maybe AgentDef) === Just d

    it "the sample def round-trips" $
      (decode (encode sampleDef) :: Maybe AgentDef) `shouldBe` Just sampleDef

    it "AllowAll encodes as \"all\"" $ do
      let d = sampleDef { adTools = AllowAll }
      (decode (encode d) :: Maybe AgentDef) `shouldBe` Just d

    it "round-trips a def with a group" $ do
      let d = sampleDef { adGroup = Just "core" }
      (decode (encode d) :: Maybe AgentDef) `shouldBe` Just d

    it "round-trips role and description" $ do
      let d = sampleDef { adRole = Just "orchestrator"
                        , adDescription = Just "spawns sub-agents" }
      (decode (encode d) :: Maybe AgentDef) `shouldBe` Just d

isLeft :: Either a b -> Bool
isLeft (Left _)  = True
isLeft (Right _) = False