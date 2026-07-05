{-# LANGUAGE OverloadedStrings #-}
module Seal.Agent.Def.BackendSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import Seal.Agent.Def.Backend
import Seal.Agent.Def.Types (AgentDef (..), AgentDefId (..), mkAgentDefId)
import Seal.Audited.Replay (AuditedEvent (..))
import Seal.Audited.Types (AuditedKind (..))
import Seal.Core.Types (ModelId (..), OpName (..), SessionId (..))
import Seal.Security.Policy (AllowList (..))
import Seal.TestHelpers.Arbitrary ()

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)

sampleDefId :: AgentDefId
sampleDefId = case mkAgentDefId "a1" of
  Right aid -> aid
  Left _    -> AgentDefId "fallback"

mkDef :: Text -> AgentDef
mkDef name = AgentDef
  { adId = sampleDefId
  , adName = name
  , adProvider = "ollama"
  , adModel = ModelId "llama3"
  , adSystem = Nothing
  , adTools = AllowAll
  , adCreatedAt = sampleTime
  , adUpdatedAt = sampleTime
  , adSession = SessionId "s1"
  }

-- | An AuditedEvent for an AGENT_DEF_CREATE. The payload is the opcode INPUT
-- shape (id/name/provider/model/system/tools); the event's timestamp and
-- session supply the rest.
createEvent :: AgentDef -> AuditedEvent
createEvent d = AuditedEvent
  { aeEvOpcode = OpName "AGENT_DEF_CREATE"
  , aeEvKind = AKAgentDef
  , aeEvPayload = object
      [ "id" .= adId d
      , "name" .= adName d
      , "provider" .= adProvider d
      , "model" .= adModel d
      , "tools" .= ("all" :: Text)
      ]
  , aeEvSession = adSession d
  , aeEvTs = adCreatedAt d
  }

-- | An AuditedEvent for a non-agent-def kind (should be ignored by the
-- materializer).
nonAgentDefEvent :: AuditedEvent
nonAgentDefEvent = AuditedEvent
  { aeEvOpcode = OpName "MEMORY_STORE"
  , aeEvKind = AKMemory
  , aeEvPayload = object []
  , aeEvSession = SessionId "s1"
  , aeEvTs = sampleTime
  }

spec :: Spec
spec = describe "Seal.Agent.Def.Backend" $ do
  describe "noneBackend direct ops" $ do
    it "update then read round-trips" $ do
      backend <- noneBackend
      adbUpdate backend (mkDef "greeter")
      adbRead backend sampleDefId `shouldReturn` Just (mkDef "greeter")

    it "update replaces an existing def" $ do
      backend <- noneBackend
      adbUpdate backend (mkDef "old")
      adbUpdate backend (mkDef "new")
      m <- adbRead backend sampleDefId
      case m of
        Just d  -> adName d `shouldBe` "new"
        Nothing -> expectationFailure "def not found"

    it "list returns all defs" $ do
      backend <- noneBackend
      adbUpdate backend (mkDef "a")
      adbList backend `shouldReturn` [mkDef "a"]

    it "read of a missing id returns Nothing" $ do
      backend <- noneBackend
      adbRead backend sampleDefId `shouldReturn` Nothing

  describe "materializeAgentDefs" $ do
    it "replaying a CREATE event populates the backend" $ do
      backend <- noneBackend
      let events = [createEvent (mkDef "from-replay")]
      materializeAgentDefs events backend
      m <- adbRead backend sampleDefId
      case m of
        Just d  -> adName d `shouldBe` "from-replay"
        Nothing -> expectationFailure "def not materialized"

    it "ignores non-agent-def events" $ do
      backend <- noneBackend
      let events = [nonAgentDefEvent, createEvent (mkDef "kept")]
      materializeAgentDefs events backend
      adbList backend `shouldReturn` [mkDef "kept"]

    it "replaying the same log twice is idempotent" $ do
      backend <- noneBackend
      let events = [createEvent (mkDef "x")]
      materializeAgentDefs events backend
      materializeAgentDefs events backend
      adbList backend `shouldReturn` [mkDef "x"]

    it "replaying an empty log leaves the backend empty" $ do
      backend <- noneBackend
      materializeAgentDefs [] backend
      adbList backend `shouldReturn` []

    it "replays AllowOnly tools from an array payload" $ do
      backend <- noneBackend
      let ev = (createEvent (mkDef "toolsy")) { aeEvPayload = object
                [ "id" .= sampleDefId
                , "name" .= ("toolsy" :: Text)
                , "provider" .= ("ollama" :: Text)
                , "model" .= ("llama3" :: Text)
                , "tools" .= (["FILE_READ" :: Text, "ASK_HUMAN"] :: [Text])
                ] }
      materializeAgentDefs [ev] backend
      m <- adbRead backend sampleDefId
      case m of
        Just d  -> adTools d `shouldBe` AllowOnly (Set.fromList [OpName "FILE_READ", OpName "ASK_HUMAN"])
        Nothing -> expectationFailure "def not materialized"