{-# LANGUAGE OverloadedStrings #-}
module Seal.Skills.BackendSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import Seal.Audited.Replay (AuditedEvent (..))
import Seal.Audited.Types (AuditedKind (..))
import Seal.Core.Types (OpName (..), SessionId (..))
import Seal.Skills.Backend
import Seal.Skills.Types (Skill (..), SkillId (..), mkSkillId)
import Seal.TestHelpers.Arbitrary ()

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)

sampleSkillId :: SkillId
sampleSkillId = case mkSkillId "s1" of
  Right sid -> sid
  Left _    -> SkillId "fallback"

mkSkill :: Text -> Text -> Skill
mkSkill desc body = Skill
  { skId = sampleSkillId
  , skDescription = desc
  , skBody = body
  , skCreatedAt = sampleTime
  , skUpdatedAt = sampleTime
  , skSession = SessionId "s1"
  }

-- | An AuditedEvent for a SKILL_CREATE. The payload is the opcode INPUT shape
-- (id/description/body); the event's timestamp and session supply the rest.
createEvent :: Skill -> AuditedEvent
createEvent s = AuditedEvent
  { aeEvOpcode = OpName "SKILL_CREATE"
  , aeEvKind = AKSkill
  , aeEvPayload = object
      [ "id" .= skId s
      , "description" .= skDescription s
      , "body" .= skBody s
      ]
  , aeEvSession = skSession s
  , aeEvTs = skCreatedAt s
  }

-- | An AuditedEvent for a non-skill kind (should be ignored by the materializer).
nonSkillEvent :: AuditedEvent
nonSkillEvent = AuditedEvent
  { aeEvOpcode = OpName "MEMORY_STORE"
  , aeEvKind = AKMemory
  , aeEvPayload = object []
  , aeEvSession = SessionId "s1"
  , aeEvTs = sampleTime
  }

spec :: Spec
spec = describe "Seal.Skills.Backend" $ do
  describe "noneBackend direct ops" $ do
    it "create then read round-trips" $ do
      backend <- noneBackend
      sbCreate backend (mkSkill "d" "b")
      sbRead backend sampleSkillId `shouldReturn` Just (mkSkill "d" "b")

    it "update replaces an existing skill" $ do
      backend <- noneBackend
      sbCreate backend (mkSkill "old" "old-body")
      sbUpdate backend (mkSkill "new" "new-body")
      sbRead backend sampleSkillId `shouldReturn` Just (mkSkill "new" "new-body")

    it "list returns all entries" $ do
      backend <- noneBackend
      sbCreate backend (mkSkill "a" "b")
      sbList backend `shouldReturn` [mkSkill "a" "b"]

    it "read of a missing id returns Nothing" $ do
      backend <- noneBackend
      sbRead backend sampleSkillId `shouldReturn` Nothing

  describe "materializeSkills" $ do
    it "replaying a CREATE event populates the backend" $ do
      backend <- noneBackend
      let events = [createEvent (mkSkill "from-replay" "body")]
      materializeSkills events backend
      sbRead backend sampleSkillId `shouldReturn` Just (mkSkill "from-replay" "body")

    it "ignores non-skill events" $ do
      backend <- noneBackend
      let events = [nonSkillEvent, createEvent (mkSkill "kept" "kb")]
      materializeSkills events backend
      sbList backend `shouldReturn` [mkSkill "kept" "kb"]

    it "replaying the same log twice is idempotent" $ do
      backend <- noneBackend
      let events = [createEvent (mkSkill "x" "y")]
      materializeSkills events backend
      materializeSkills events backend
      sbList backend `shouldReturn` [mkSkill "x" "y"]

    it "replaying an empty log leaves the backend empty" $ do
      backend <- noneBackend
      materializeSkills [] backend
      sbList backend `shouldReturn` []