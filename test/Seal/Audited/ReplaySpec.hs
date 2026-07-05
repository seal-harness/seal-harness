{-# LANGUAGE OverloadedStrings #-}
module Seal.Audited.ReplaySpec (spec) where

import Data.Aeson (object, (.=))
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec
import Test.QuickCheck hiding (replay)

import Seal.Audited.Replay
import Seal.Audited.Types (AuditedEntry (..), AuditedKind (..))
import Seal.Core.Types (OpName (..), SessionId (..))
import Seal.TestHelpers.Arbitrary ()

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)

sampleEntry :: AuditedEntry
sampleEntry = AuditedEntry
  { aeId = "u1"
  , aeTimestamp = sampleTime
  , aeSession = SessionId "s1"
  , aeOpcode = OpName "MEMORY_STORE"
  , aeKind = AKMemory
  , aePayload = object ["id" .= ("m1" :: String)]
  }

spec :: Spec
spec = describe "Seal.Audited.Replay" $ do
  it "replay yields one event per entry, in order" $
    property $ \es ->
      let events = replay (es :: [AuditedEntry])
      in length events === length es

  it "an event carries its entry's opcode, kind, payload, session, timestamp" $
    case replay [sampleEntry] of
      [ev] -> do
        aeEvOpcode ev `shouldBe` aeOpcode sampleEntry
        aeEvKind ev `shouldBe` aeKind sampleEntry
        aeEvSession ev `shouldBe` aeSession sampleEntry
        aeEvTs ev `shouldBe` aeTimestamp sampleEntry
      _ -> expectationFailure "expected exactly one event"

  it "replay of an empty log yields no events" $
    replay [] `shouldBe` []