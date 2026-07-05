{-# LANGUAGE OverloadedStrings #-}
module Seal.Memory.BackendSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import Seal.Audited.Replay (AuditedEvent (..))
import Seal.Audited.Types (AuditedKind (..))
import Seal.Core.Types (OpName (..), SessionId (..))
import Seal.Memory.Backend
import Seal.Memory.Types (MemoryEntry (..), MemoryId (..), mkMemoryId)
import Seal.TestHelpers.Arbitrary ()

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)

sampleMemoryId :: MemoryId
sampleMemoryId = case mkMemoryId "m1" of
  Right mid -> mid
  Left _    -> MemoryId "fallback"

mkEntry :: Text -> MemoryEntry
mkEntry content = MemoryEntry
  { meId = sampleMemoryId
  , meContent = content
  , meTags = []
  , meCreatedAt = sampleTime
  , meUpdatedAt = sampleTime
  , meSession = SessionId "s1"
  }

-- | An AuditedEvent for a MEMORY_STORE. The payload is the opcode INPUT shape
-- (id/content/tags); the event's timestamp and session supply the rest.
storeEvent :: MemoryEntry -> AuditedEvent
storeEvent e = AuditedEvent
  { aeEvOpcode = OpName "MEMORY_STORE"
  , aeEvKind = AKMemory
  , aeEvPayload = object
      [ "id" .= meId e
      , "content" .= meContent e
      , "tags" .= meTags e
      ]
  , aeEvSession = meSession e
  , aeEvTs = meCreatedAt e
  }

-- | An AuditedEvent for a MEMORY_DELETE of the given id.
deleteEvent :: MemoryId -> AuditedEvent
deleteEvent mid = AuditedEvent
  { aeEvOpcode = OpName "MEMORY_DELETE"
  , aeEvKind = AKMemory
  , aeEvPayload = object ["id" .= mid]
  , aeEvSession = SessionId "s1"
  , aeEvTs = sampleTime
  }

-- | An AuditedEvent for a non-memory kind (should be ignored by the materializer).
nonMemoryEvent :: AuditedEvent
nonMemoryEvent = AuditedEvent
  { aeEvOpcode = OpName "SKILL_CREATE"
  , aeEvKind = AKSkill
  , aeEvPayload = object []
  , aeEvSession = SessionId "s1"
  , aeEvTs = sampleTime
  }

spec :: Spec
spec = describe "Seal.Memory.Backend" $ do
  describe "noneBackend direct ops" $ do
    it "store then recall round-trips" $ do
      backend <- noneBackend
      mbStore backend (mkEntry "hello")
      mbRecall backend sampleMemoryId `shouldReturn` Just (mkEntry "hello")

    it "delete removes the entry" $ do
      backend <- noneBackend
      mbStore backend (mkEntry "hello")
      mbDelete backend sampleMemoryId
      mbRecall backend sampleMemoryId `shouldReturn` Nothing

    it "delete is idempotent (deleting a missing id does not throw)" $ do
      backend <- noneBackend
      mbDelete backend sampleMemoryId
      mbRecall backend sampleMemoryId `shouldReturn` Nothing

    it "list returns all entries" $ do
      backend <- noneBackend
      mbStore backend (mkEntry "a")
      mbList backend `shouldReturn` [mkEntry "a"]

  describe "materializeMemory" $ do
    it "replaying a STORE event populates the backend" $ do
      backend <- noneBackend
      let events = [storeEvent (mkEntry "from-replay")]
      materializeMemory events backend
      mbRecall backend sampleMemoryId `shouldReturn` Just (mkEntry "from-replay")

    it "replaying STORE then DELETE leaves the backend empty" $ do
      backend <- noneBackend
      let events = [storeEvent (mkEntry "x"), deleteEvent sampleMemoryId]
      materializeMemory events backend
      mbRecall backend sampleMemoryId `shouldReturn` Nothing

    it "ignores non-memory events" $ do
      backend <- noneBackend
      let events = [nonMemoryEvent, storeEvent (mkEntry "kept")]
      materializeMemory events backend
      mbList backend `shouldReturn` [mkEntry "kept"]

    it "replaying the same log twice is idempotent" $ do
      backend <- noneBackend
      let events = [storeEvent (mkEntry "x")]
      materializeMemory events backend
      materializeMemory events backend
      mbList backend `shouldReturn` [mkEntry "x"]

    it "replaying an empty log leaves the backend empty" $ do
      backend <- noneBackend
      materializeMemory [] backend
      mbList backend `shouldReturn` []