{-# LANGUAGE OverloadedStrings #-}
module Seal.Audited.TypesSpec (spec) where

import Data.Aeson (decode, encode, object, (.=))
import Data.ByteString qualified as BS
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec
import Test.QuickCheck

import Seal.Audited.Types
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
  , aePayload = object ["id" .= ("m1" :: String), "content" .= ("hello" :: String)]
  }

spec :: Spec
spec = describe "Seal.Audited.Types" $ do
  describe "AuditedKind" $ do
    it "round-trips through JSON" $ do
      decode (encode AKMemory)   `shouldBe` Just AKMemory
      decode (encode AKSkill)    `shouldBe` Just AKSkill
      decode (encode AKAgentDef) `shouldBe` Just AKAgentDef
      decode (encode AKConfig)   `shouldBe` Just AKConfig

    it "rejects unknown tags" $
      (decode "\"bogus\"" :: Maybe AuditedKind) `shouldBe` Nothing

  describe "AuditedEntry" $ do
    it "round-trips through JSON" $
      property $ \e ->
        (decode (encode (e :: AuditedEntry)) :: Maybe AuditedEntry) === Just e

    it "encodeAuditedEntryRaw produces non-empty bytes with no trailing newline" $ do
      let raw = encodeAuditedEntryRaw sampleEntry
      BS.length raw `shouldSatisfy` (> 0)
      BS.last raw `shouldNotBe` 0x0a