{-# LANGUAGE OverloadedStrings #-}
module Seal.Transcript.EntriesSpec (spec) where

import Data.Aeson (decode, encode)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec
import Test.QuickCheck

import Seal.Core.Types (ModelId (..))
import Seal.Providers.Class (StopReason (..), ToolChoice (..), Usage (..))
import Seal.TestHelpers.Arbitrary ()
import Seal.Transcript.Entries

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)

baseEnv :: Envelope
baseEnv = Envelope (ModelId "m1") Nothing [] ToolAuto 1024

-- A request entry with a delta that changes the model.
reqEntry :: EnvelopeDelta -> EntryRecord
reqEntry d = EntryRecord
  { erId = "r1"
  , erTimestamp = sampleTime
  , erKind = EKRequest
  , erConvLen = 1
  , erEnvelope = Just d
  , erUsage = Nothing
  , erStop = Nothing
  , erDurationMs = Nothing
  , erHarness = Nothing
  , erCorrelation = Nothing
  , erMeta = Map.empty
  }

respEntry :: EntryRecord
respEntry = EntryRecord
  { erId = "p1"
  , erTimestamp = sampleTime
  , erKind = EKResponse
  , erConvLen = 1
  , erEnvelope = Nothing
  , erUsage = Just (Usage 5 7)
  , erStop = Just StopEnd
  , erDurationMs = Just 12
  , erHarness = Nothing
  , erCorrelation = Just "r1"
  , erMeta = Map.empty
  }

spec :: Spec
spec = describe "Seal.Transcript.Entries" $ do
  describe "EntryKind" $ do
    it "round-trips through JSON" $ do
      decode (encode EKRequest)    `shouldBe` Just EKRequest
      decode (encode EKResponse)   `shouldBe` Just EKResponse
      decode (encode EKHarness)    `shouldBe` Just EKHarness
      decode (encode EKCompaction) `shouldBe` Just EKCompaction

    it "rejects unknown tags" $
      (decode "{\"kind\":\"bogus\"}" :: Maybe EntryKind) `shouldBe` Nothing

  describe "EnvelopeDelta" $ do
    it "round-trips through JSON" $
      property $ \d ->
        (decode (encode (d :: EnvelopeDelta)) :: Maybe EnvelopeDelta) === Just d

    it "emptyEnvelopeDelta round-trips as an empty object" $
      decode (encode emptyEnvelopeDelta) `shouldBe` Just emptyEnvelopeDelta

  describe "applyDelta" $ do
    it "inherits unchanged fields" $
      applyDelta baseEnv emptyEnvelopeDelta `shouldBe` baseEnv

    it "applies a model-only delta" $
      applyDelta baseEnv emptyEnvelopeDelta { edModel = Just (ModelId "m2") }
        `shouldBe` baseEnv { envModel = ModelId "m2" }

    it "distinguishes inherit-system from clear-system" $ do
      let envWithSystem = baseEnv { envSystem = Just "you are helpful" }
      -- Nothing inherits
      applyDelta envWithSystem emptyEnvelopeDelta `shouldBe` envWithSystem
      -- Just Nothing clears
      applyDelta envWithSystem emptyEnvelopeDelta { edSystem = Just Nothing }
        `shouldBe` envWithSystem { envSystem = Nothing }

  describe "effectiveEnvelope" $ do
    it "folds deltas so each request sees the envelope in effect at that turn" $ do
      let entries =
            [ reqEntry emptyEnvelopeDelta { edModel = Just (ModelId "m2") }
            , respEntry
            , reqEntry emptyEnvelopeDelta { edMaxTokens = Just 2048 }
            ]
          result = map snd (effectiveEnvelope baseEnv entries)
      result `shouldBe`
        [ baseEnv { envModel = ModelId "m2" }
        , baseEnv { envModel = ModelId "m2" }
        , baseEnv { envModel = ModelId "m2", envMaxTokens = 2048 }
        ]

    it "non-request entries inherit the prior envelope unchanged" $
      case effectiveEnvelope baseEnv [respEntry] of
        [(_, env)] -> env `shouldBe` baseEnv
        _          -> expectationFailure "expected exactly one entry"

  describe "EntryRecord JSON" $ do
    it "round-trips a request entry" $
      property $ \d convLen ->
        let e = reqEntry d
            e' = e { erConvLen = convLen }
        in (decode (encode e') :: Maybe EntryRecord) === Just e'

    it "round-trips a response entry" $
      (decode (encode respEntry) :: Maybe EntryRecord) `shouldBe` Just respEntry

    it "encodeEntryRecordRaw produces non-empty bytes with no trailing newline" $ do
      let raw = encodeEntryRecordRaw respEntry
      BS.length raw `shouldSatisfy` (> 0)
      BS.last raw `shouldNotBe` 0x0a