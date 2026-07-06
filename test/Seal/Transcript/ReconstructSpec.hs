{-# LANGUAGE OverloadedStrings #-}
module Seal.Transcript.ReconstructSpec (spec) where

import Data.Aeson (Value (..), decode, encode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import Seal.Core.Types (ModelId (..))
import Seal.Providers.Class
  ( ContentBlock (..), Message (..), Role (..), Usage (..) )
import Seal.TestHelpers.Arbitrary ()
import Seal.Transcript.Entries
import Seal.Transcript.Reconstruct
import Seal.Transcript.Types (Direction (..), TranscriptEntry (..))

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)

reqEntry :: EnvelopeDelta -> Int -> EntryRecord
reqEntry d convLen = EntryRecord
  { erId = "r"
  , erTimestamp = sampleTime
  , erKind = EKRequest
  , erConvLen = convLen
  , erEnvelope = Just d
  , erUsage = Nothing
  , erStop = Nothing
  , erDurationMs = Nothing
  , erHarness = Nothing
  , erCorrelation = Nothing
  , erMeta = Map.empty
  }

respEntry :: Int -> EntryRecord
respEntry convLen = EntryRecord
  { erId = "p"
  , erTimestamp = sampleTime
  , erKind = EKResponse
  , erConvLen = convLen
  , erEnvelope = Nothing
  , erUsage = Just (Usage 1 2)
  , erStop = Nothing
  , erDurationMs = Just 10
  , erHarness = Nothing
  , erCorrelation = Nothing
  , erMeta = Map.empty
  }

compactionEntry :: Int -> EntryRecord
compactionEntry convLen = EntryRecord
  { erId = "c"
  , erTimestamp = sampleTime
  , erKind = EKCompaction
  , erConvLen = convLen
  , erEnvelope = Nothing
  , erUsage = Nothing
  , erStop = Nothing
  , erDurationMs = Nothing
  , erHarness = Nothing
  , erCorrelation = Nothing
  , erMeta = Map.empty
  }

-- | Pull a field out of a 'TranscriptEntry' payload (assumed to be an object).
payloadField :: String -> TranscriptEntry -> Maybe Value
payloadField k te =
  case decode (encode (tePayload te)) :: Maybe Value of
    Just (Object o) -> KeyMap.lookup (Key.fromString k) o
    _ -> Nothing

spec :: Spec
spec = describe "Seal.Transcript.Reconstruct" $ do
  it "reconstructs a request entry with the conversation prefix + envelope" $ do
    let conv = [ Message User [CbText "hi"], Message Assistant [CbText "hello"] ]
        entries = [reqEntry emptyEnvelopeDelta 2]
    case reconstruct conv entries of
      [te] -> do
        teDirection te `shouldBe` Request
        teId te `shouldBe` "r"
        payloadField "messages" te `shouldSatisfy` isJustArray
      _ -> expectationFailure "expected exactly one reconstructed entry"

  it "reconstructs a response entry with the assistant content blocks" $ do
    let conv = [ Message User [CbText "hi"], Message Assistant [CbText "hello there"] ]
        entries = [ reqEntry emptyEnvelopeDelta 1, respEntry 2 ]
    case reconstruct conv entries of
      [_req, resp] -> do
        teDirection resp `shouldBe` Response
        payloadField "content" resp `shouldSatisfy` isJustArray
      _ -> expectationFailure "expected exactly two reconstructed entries"

  it "folds envelope deltas so a later request sees the updated model" $ do
    let conv = [ Message User [CbText "a"], Message Assistant [CbText "b"], Message User [CbText "c"] ]
        entries =
          [ reqEntry emptyEnvelopeDelta { edModel = Just (ModelId "m1") } 1
          , respEntry 2
          , reqEntry emptyEnvelopeDelta { edModel = Just (ModelId "m2") } 3
          ]
    case reconstruct conv entries of
      [e1, _, e3] -> do
        payloadField "model" e1 `shouldBe` Just (String "m1")
        payloadField "model" e3 `shouldBe` Just (String "m2")
      _ -> expectationFailure "expected exactly three reconstructed entries"

  it "compaction entries pass through as boundary markers" $
    case reconstruct [] [compactionEntry 1] of
      [te] -> do
        teDirection te `shouldBe` Request
        tePayload te `shouldBe` Null
      _ -> expectationFailure "expected exactly one reconstructed entry"

  it "reconstruction is total on empty inputs" $
    reconstruct [] [] `shouldBe` []

isJustArray :: Maybe Value -> Bool
isJustArray (Just (Array _)) = True
isJustArray _                = False