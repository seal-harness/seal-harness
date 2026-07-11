{-# LANGUAGE OverloadedStrings #-}
module Seal.Transcript.ReconstructSpec (spec) where

import Data.Aeson (Value (..), decode, encode, object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import qualified Data.Vector as V

import Seal.Core.Types (ModelId (..), OpName (..), ToolCallId (..))
import Seal.Providers.Class
  ( ContentBlock (..), Message (..), Role (..), ToolResultPart (..), Usage (..) )
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

-- | An 'EKHarness' entry mirroring the dispatcher's shape: convLen=0 (no
-- conversation lines added), the opcode name + input in erMeta.
harnessEntry :: Int -> EntryRecord
harnessEntry convLen = EntryRecord
  { erId = "h"
  , erTimestamp = sampleTime
  , erKind = EKHarness
  , erConvLen = convLen
  , erEnvelope = Nothing
  , erUsage = Nothing
  , erStop = Nothing
  , erDurationMs = Nothing
  , erHarness = Nothing
  , erCorrelation = Nothing
  , erMeta = Map.fromList [("op", object ["name" .= String "FILE_READ"])]
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

  -- Regression: erConvLen is ABSOLUTE (the total conversation length at that
  -- point), not a relative count of new lines. The reconstruct fold must
  -- slice @conv[start:end]@ (take (end - start) (drop start)), NOT
  -- @take end (drop start)@ — the latter takes @end@ elements after @start@,
  -- bleeding into the next turn's messages. For a response at convLen=2 with
  -- start=1, @take 2 (drop 1)@ returns 2 elements (the assistant reply AND
  -- the next user message), so the frontend renders the next user's prompt
  -- underneath the first assistant response.
  it "a response entry's payload does not include the next turn's user message" $ do
    let conv =
          [ Message User [CbText "hello"]
          , Message Assistant [CbText "hi there"]
          , Message User [CbText "what is 2+2?"]
          , Message Assistant [CbText "it's 4"]
          ]
        entries =
          [ reqEntry  emptyEnvelopeDelta 1
          , respEntry 2
          , reqEntry  emptyEnvelopeDelta 3
          , respEntry 4
          ]
    case reconstruct conv entries of
      [req1, resp1, _req2, _resp2] -> do
        -- The first response must carry ONLY the first assistant message
        -- ("hi there"), not the next user message ("what is 2+2?").
        case payloadField "content" resp1 of
          Just (A.Array arr) -> do
            length arr `shouldBe` 1
            case V.toList arr of
              [blk] -> case blk of
                A.Object o | KeyMap.lookup (Key.fromText "contents") o == Just (A.String "hi there") -> pure ()
                other -> expectationFailure ("expected 'hi there' CbText block, got " ++ show other)
              other -> expectationFailure ("expected 1 element, got " ++ show other)
          other -> expectationFailure ("expected a content array, got " ++ show other)
        -- The first request must carry only the first user message.
        case payloadField "messages" req1 of
          Just (A.Array arr) -> length arr `shouldBe` 1
          other -> expectationFailure ("expected a messages array, got " ++ show other)
      other -> expectationFailure ("expected 4 entries, got " ++ show (length other))

  -- Regression: an 'EKHarness' entry (an opcode invocation, e.g. FILE_READ)
  -- has convLen=0 and adds no conversation lines. The reconstruct fold must
  -- NOT reset the conversation cursor (start) to 0 on such an entry — doing
  -- so makes the next response entry's slice (take end (drop 0 conv)) return
  -- the ENTIRE conversation, which the frontend renders as one giant duplicate
  -- response row containing all prior user + assistant messages. The harness
  -- entry must preserve the cursor so the following response slices only its
  -- own new assistant content.
  it "a harness entry with convLen=0 does not reset the conversation cursor" $ do
    let conv =
          [ Message User [CbText "hello"]
          , Message Assistant [CbText "hi there"]
          , Message User [CbText "what is 2+2?"]
          , Message Assistant [CbText "let me check", CbToolUse (ToolCallId "c0") (OpName "FILE_READ") (object ["path" .= String "/tmp/data"])]
          , Message User [CbToolResult (ToolCallId "c0") [TrpText "<redacted>"] True]
          , Message Assistant [CbText "it's 4"]
          ]
        entries =
          [ reqEntry  emptyEnvelopeDelta 1
          , respEntry 2
          , reqEntry  emptyEnvelopeDelta 3
          , respEntry 4
          , harnessEntry 0
          , respEntry 6
          ]
    case reconstruct conv entries of
      [_req1, _resp1, _req2, _resp2, _harness, resp3] -> do
        -- The final response must carry only the content blocks added since
        -- the prior turn (the tool_result + the final assistant text = 2
        -- blocks), not the entire conversation. Before the fix it carried
        -- all 7 content blocks from all 6 conversation lines.
        case payloadField "content" resp3 of
          Just (A.Array arr) -> length arr `shouldBe` 2
          other -> expectationFailure ("expected a 2-element content array, got " ++ show other)
      other -> expectationFailure ("expected 6 entries, got " ++ show (length other))

isJustArray :: Maybe Value -> Bool
isJustArray (Just (Array _)) = True
isJustArray _                = False