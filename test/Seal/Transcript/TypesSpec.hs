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
  , teConvLen = Just 7
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

  -- WU-1: the branch anchor rides on the wire as `convLen`.
  it "encodes the conversation anchor as `convLen`" $
    A.toJSON sampleEntry `shouldBe` object
      [ "id"          .= ("uuid-1" :: String)
      , "timestamp"   .= UTCTime (fromGregorian 2026 6 30) (secondsToDiffTime 0)
      , "model"       .= Just (ModelId "claude-opus-4-8")
      , "direction"   .= Request
      , "payload"     .= object ["kind" .= ("hello" :: String)]
      , "durationMs"  .= (Nothing :: Maybe Int)
      , "correlation" .= Just ("corr-1" :: String)
      , "convLen"     .= Just (7 :: Int)
      , "meta"        .= (Map.empty :: Map.Map String A.Value)
      ]

  it "round-trips convLen = Nothing (rows with no anchor)" $
    let e = sampleEntry { teConvLen = Nothing }
    in decode (A.encode e) `shouldBe` Just e

  -- Backwards compatibility: legacy on-disk lines predate `convLen`, and
  -- `TranscriptEntry` IS decoded from JSON on the legacy title-snippet path
  -- (Gateway/Transcript.hs:1006). A required field would silently blank the
  -- sidebar title for every old session.
  it "decodes a legacy line that has NO convLen key" $ do
    let legacyJson = A.object
          [ "id"        .= ("uuid-legacy" :: String)
          , "timestamp" .= UTCTime (fromGregorian 2026 6 30) (secondsToDiffTime 0)
          , "model"     .= (Nothing :: Maybe ModelId)
          , "direction" .= Request
          , "payload"   .= object ["kind" .= ("old" :: String)]
          , "durationMs" .= (Nothing :: Maybe Int)
          , "correlation" .= (Nothing :: Maybe String)
          , "meta"      .= (Map.empty :: Map.Map String A.Value)
          -- NOTE: deliberately NO "convLen" key — this is the pre-change
          -- on-disk shape.
          ]
    (teConvLen <$> (decode (A.encode legacyJson) :: Maybe TranscriptEntry))
      `shouldBe` Just Nothing
