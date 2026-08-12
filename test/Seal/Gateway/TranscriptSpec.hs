{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Gateway.Transcript.reconEntryToFrontend' — the filter
-- that decides which reconstructed 'EKHarness' entries surface to the web
-- frontend SPA. v1 whitelists @op.name == "SKILL_LOAD"@ so /skill load
-- invocations appear as distinct harness entries; non-whitelisted opcodes
-- (e.g. @SHELL_EXEC@) are dropped (preserving the pre-v1 behavior); and
-- approval-bearing entries still surface (preserving the existing
-- confirmation-evidence rendering).
--
-- Also covers 'renderServerTiming' — the @Server-Timing@ header formatter
-- used by the @/transcript@ handler to expose per-phase durations to the
-- browser so optimization work can be directed by measurement.
module Seal.Gateway.TranscriptSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BC
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import Seal.Gateway.Transcript
  ( TranscriptSource (..)
  , TranscriptTimings (..)
  , reconEntryToFrontend
  , renderServerTiming
  , setEncodeMs
  )
import Seal.Transcript.Types (Direction (..), TranscriptEntry (..))

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 21) (secondsToDiffTime 0)

-- | Build a TranscriptEntry mimicking what 'reconstruct' produces for an
-- EKHarness entry: the payload is the 'harnessPayload' output (an object
-- with @messages@, @harness@, and — after the v1 fix — @op@). The direction
-- is 'Request' (matching 'reconstruct' line 94: harness entries are
-- reconstructed as Request-direction entries).
mkHarnessTe :: Value -> TranscriptEntry
mkHarnessTe payload = TranscriptEntry
  { teId = ""
  , teTimestamp = sampleTime
  , teModel = Nothing
  , teDirection = Request
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

-- | A SETUP_REPO harness payload (no approval key) — mirrors the shape
-- 'recordSetupRepoResult' (Dispatch.hs) writes: @op.name = SETUP_REPO@ +
-- @input@ (the repo url) + @result@ (the clone/no-op/conflict/failure
-- outcome). The frontend's 'transcriptToMessages' (ChatArea.tsx) has
-- explicit rendering for SETUP_REPO result entries; this entry must
-- surface through 'reconEntryToFrontend' so the user sees the clone
-- outcome in the chat when a session is created with an attached repo.
setupRepoPayload :: Value
setupRepoPayload = object
  [ "messages" .= ([] :: [Value])
  , "harness"  .= Null
  , "op"       .= object [ "name" .= String "SETUP_REPO" ]
  , "input"    .= object ["url" .= String "git@github.com:seal-harness/seal-harness.git"]
  , "result"   .= object ["status" .= String "cloned", "target" .= String "/path/to/workdir"]
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

  it "surfaces a SETUP_REPO harness entry (whitelisted)" $ do
    let te = mkHarnessTe setupRepoPayload
    case reconEntryToFrontend 0 te of
      Just _  -> pure ()
      Nothing -> expectationFailure "expected Just (SETUP_REPO entry surfaces), got Nothing"

  it "drops a SHELL_EXEC harness entry (not whitelisted, no approval)" $ do
    let te = mkHarnessTe shellExecPayload
    reconEntryToFrontend 0 te `shouldBe` Nothing

  it "surfaces an approval-bearing harness entry (regression guard)" $ do
    let te = mkHarnessTe approvalPayload
    case reconEntryToFrontend 0 te of
      Just val -> do
        -- The approval key must be present in the surfaced payload. The
        -- `payload` field is now a JSON object (not a string), so we look
        -- it up as an Object and check for the "approval" key. The `raw`
        -- field is empty for the reconstructed path.
        case val of
          Object o ->
            case KeyMap.lookup (Key.fromString "payload") o of
              Just (Object p) -> case KeyMap.lookup (Key.fromString "approval") p of
                Just _  -> pure ()
                Nothing -> expectationFailure "expected 'approval' key in payload object"
              other -> expectationFailure ("expected 'payload' object in frontend entry, got " ++ show other)
          _ -> expectationFailure "expected object value"
      Nothing -> expectationFailure "expected Just (approval entry surfaces), got Nothing"

  -- ── renderServerTiming ───────────────────────────────────────────────

  describe "Seal.Gateway.Transcript.renderServerTiming" $ do
    -- A sample timings value used by several of the assertions below.
    let sampleTt = TranscriptTimings
          { ttSource        = TSConvEntries
          , ttEntryCount    = 127
          , ttFileReadMs    = 3
          , ttParseMs       = 18
          , ttReconstructMs = 12
          , ttRewriteMs     = 0
          , ttEncodeMs      = 8
          , ttTotalMs       = 42
          }

    it "emits a `tt` token with the total duration" $ do
      renderServerTiming sampleTt `shouldSatisfy` BC.isInfixOf "tt;dur=42;desc=\"total\""

    it "emits one token per measured phase" $ do
      let h = renderServerTiming sampleTt
      h `shouldSatisfy` BC.isInfixOf "fr;dur=3;desc=\"file-read\""
      h `shouldSatisfy` BC.isInfixOf "pr;dur=18;desc=\"parse\""
      h `shouldSatisfy` BC.isInfixOf "rc;dur=12;desc=\"reconstruct\""
      h `shouldSatisfy` BC.isInfixOf "en;dur=8;desc=\"encode\""

    it "names the transcript source in a `src` desc token" $ do
      renderServerTiming sampleTt
        `shouldSatisfy` BC.isInfixOf "src;desc=\"conv+entries\""

    it "names legacy / conv-only / missing sources distinctly" $ do
      let legacy = sampleTt { ttSource = TSLegacy }
          convOnly = sampleTt { ttSource = TSConvOnly }
          missing = sampleTt { ttSource = TSMissing }
      renderServerTiming legacy    `shouldSatisfy` BC.isInfixOf "src;desc=\"legacy\""
      renderServerTiming convOnly  `shouldSatisfy` BC.isInfixOf "src;desc=\"conv-only\""
      renderServerTiming missing   `shouldSatisfy` BC.isInfixOf "src;desc=\"missing\""

    it "includes the entry count in an `n` desc token" $ do
      renderServerTiming sampleTt `shouldSatisfy` BC.isInfixOf "n;desc=\"127\""

    it "emits zero-duration phases for paths that did not run" $ do
      let legacyTt = TranscriptTimings
            { ttSource        = TSLegacy
            , ttEntryCount    = 5
            , ttFileReadMs    = 1
            , ttParseMs       = 2
            , ttReconstructMs = 0  -- legacy path never runs reconstruct
            , ttRewriteMs     = 1
            , ttEncodeMs      = 0
            , ttTotalMs       = 4
            }
      renderServerTiming legacyTt `shouldSatisfy` BC.isInfixOf "rc;dur=0;desc=\"reconstruct\""

    it "emits all-zero durations for the missing-source case" $ do
      let missingTt = TranscriptTimings
            { ttSource        = TSMissing
            , ttEntryCount    = 0
            , ttFileReadMs    = 0
            , ttParseMs       = 0
            , ttReconstructMs = 0
            , ttRewriteMs     = 0
            , ttEncodeMs      = 0
            , ttTotalMs       = 0
            }
      let h = renderServerTiming missingTt
      -- All phase durations are 0; the source desc is "missing" and the
      -- entry count is 0. The header still has all 8 tokens so the frontend's
      -- parser can rely on a stable shape.
      BC.split ',' h `shouldSatisfy` (\parts -> length parts == 8)
      h `shouldSatisfy` BC.isInfixOf "tt;dur=0;desc=\"total\""
      h `shouldSatisfy` BC.isInfixOf "en;dur=0;desc=\"encode\""
      h `shouldSatisfy` BC.isInfixOf "src;desc=\"missing\""
      h `shouldSatisfy` BC.isInfixOf "n;desc=\"0\""

    it "setEncodeMs sets the encode phase and bumps the total" $ do
      let tt0 = sampleTt { ttEncodeMs = 0, ttTotalMs = 30 }
          tt1 = setEncodeMs 12 50 tt0
      ttEncodeMs tt1 `shouldBe` 12
      ttTotalMs tt1 `shouldBe` 50
      -- Other phases are untouched:
      ttFileReadMs tt1 `shouldBe` ttFileReadMs tt0
      ttSource tt1 `shouldBe` ttSource tt0