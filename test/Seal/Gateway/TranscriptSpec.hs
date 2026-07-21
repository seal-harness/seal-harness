{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Gateway.Transcript.reconEntryToFrontend' — the filter
-- that decides which reconstructed 'EKHarness' entries surface to the web
-- frontend SPA. v1 whitelists @op.name == "SKILL_LOAD"@ so /skill load
-- invocations appear as distinct harness entries; non-whitelisted opcodes
-- (e.g. @SHELL_EXEC@) are dropped (preserving the pre-v1 behavior); and
-- approval-bearing entries still surface (preserving the existing
-- confirmation-evidence rendering).
module Seal.Gateway.TranscriptSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import Seal.Gateway.Transcript (reconEntryToFrontend)
import Seal.Transcript.Types (Direction (..), TranscriptEntry (..))

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 21) (secondsToDiffTime 0)

-- | Build a TranscriptEntry mimicking what 'reconstruct' produces for an
-- EKHarness entry: the payload is the 'harnessPayload' output (an object
-- with @messages@, @harness@, and — after the v1 fix — @op@).
mkHarnessTe :: Value -> TranscriptEntry
mkHarnessTe payload = TranscriptEntry
  { teId = ""
  , teTimestamp = sampleTime
  , teModel = Nothing
  , teDirection = Response
  , tePayload = payload
  , teDurationMs = Nothing
  , teCorrelation = Nothing
  , teMeta = Map.empty
  }

-- | A SKILL_LOAD harness payload (no approval key) — the v1 /skill load
-- surface. After the harnessPayload fix, this includes @op@ in the base.
skillLoadPayload :: Value
skillLoadPayload = object
  [ "messages" .= ([] :: [Value])
  , "harness"  .= Null
  , "op"       .= object [ "name" .= String "SKILL_LOAD"
                         , "input" .= object ["id" .= String "greet"]
                         ]
  ]

-- | A SHELL_EXEC harness payload (no approval key, op not whitelisted).
-- Should be dropped by reconEntryToFrontend.
shellExecPayload :: Value
shellExecPayload = object
  [ "messages" .= ([] :: [Value])
  , "harness"  .= Null
  , "op"       .= object [ "name" .= String "SHELL_EXEC" ]
  ]

-- | An approval-bearing harness payload (the existing confirmation-evidence
-- surface). Should still surface (not dropped).
approvalPayload :: Value
approvalPayload = object
  [ "messages"  .= ([] :: [Value])
  , "harness"   .= Null
  , "op"        .= object [ "name" .= String "SHELL_EXEC" ]
  , "approval"  .= object [ "scope" .= String "once" ]
  ]

spec :: Spec
spec = describe "Seal.Gateway.Transcript.reconEntryToFrontend" $ do
  it "surfaces a SKILL_LOAD harness entry (whitelisted)" $ do
    let te = mkHarnessTe skillLoadPayload
    case reconEntryToFrontend 0 te of
      Just _  -> pure ()
      Nothing -> expectationFailure "expected Just (SKILL_LOAD entry surfaces), got Nothing"

  it "drops a SHELL_EXEC harness entry (not whitelisted, no approval)" $ do
    let te = mkHarnessTe shellExecPayload
    reconEntryToFrontend 0 te `shouldBe` Nothing

  it "surfaces an approval-bearing harness entry (regression guard)" $ do
    let te = mkHarnessTe approvalPayload
    case reconEntryToFrontend 0 te of
      Just val -> do
        -- The approval key must be present in the surfaced payload's raw JSON.
        case val of
          Object o ->
            case KeyMap.lookup (Key.fromString "raw") o of
              Just raw -> show raw `shouldContain` "approval"
              Nothing  -> expectationFailure "expected 'raw' field in frontend entry"
          _ -> expectationFailure "expected object value"
      Nothing -> expectationFailure "expected Just (approval entry surfaces), got Nothing"