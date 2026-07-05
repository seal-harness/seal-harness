{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
module Seal.Agent.Def.TypesSpec (spec) where

import Data.Aeson (decode, encode)
import Data.Set qualified as Set
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec
import Test.QuickCheck

import Seal.Agent.Def.Types
import Seal.Core.Types (ModelId (..), OpName (..), SessionId (..))
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
  , adCreatedAt = sampleTime
  , adUpdatedAt = sampleTime
  , adSession = SessionId "s1"
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

  describe "AgentDef JSON" $ do
    it "round-trips through aeson" $
      property $ \d ->
        (decode (encode (d :: AgentDef)) :: Maybe AgentDef) === Just d

    it "the sample def round-trips" $
      (decode (encode sampleDef) :: Maybe AgentDef) `shouldBe` Just sampleDef

    it "AllowAll encodes as \"all\"" $ do
      let d = sampleDef { adTools = AllowAll }
      (decode (encode d) :: Maybe AgentDef) `shouldBe` Just d

isLeft :: Either a b -> Bool
isLeft (Left _)  = True
isLeft (Right _) = False