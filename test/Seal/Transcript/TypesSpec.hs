{-# LANGUAGE OverloadedStrings #-}
module Seal.Transcript.TypesSpec (spec) where

import Data.Aeson (decode, object, (.=))
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import Seal.Core.Types (ModelId (..))
import Seal.Transcript.Types

sampleEntry :: TranscriptEntry
sampleEntry = TranscriptEntry
  { teId = "uuid-1"
  , teTimestamp = UTCTime (fromGregorian 2026 6 30) (secondsToDiffTime 0)
  , teModel = Just (ModelId "claude-opus-4-8")
  , teDirection = Request
  , tePayload = object ["kind" .= ("hello" :: String)]
  , teDurationMs = Nothing
  , teCorrelation = Just "corr-1"
  , teMeta = Map.empty
  }

spec :: Spec
spec = describe "Seal.Transcript.Types" $ do
  it "JSON round-trips through aeson" $
    decode (A.encode sampleEntry) `shouldBe` Just sampleEntry

  it "encodeEntryRaw is a single line with no trailing newline" $ do
    let raw = encodeEntryRaw sampleEntry
    BL.elem 0x0a (BL.fromStrict raw) `shouldBe` False

  it "encodeEntryRaw equals the canonical aeson encoding (view-raw hides nothing)" $
    encodeEntryRaw sampleEntry `shouldBe` BL.toStrict (A.encode sampleEntry)
