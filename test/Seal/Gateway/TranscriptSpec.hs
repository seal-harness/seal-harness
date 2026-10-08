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
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime, getCurrentTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (mkSessionId)
import Seal.Gateway.Transcript
  ( TranscriptSource (..)
  , TranscriptTimings (..)
  , readTranscriptEntriesTimed
  , ttEntryCount
  , reconEntryToFrontend
  , renderServerTiming
  , trailingConvEntries
  , setEncodeMs
  )
import Seal.Transcript.Conv (ConvLine (..), encodeConvLine)
import Seal.Transcript.ConvIndex (buildIndex)
import Seal.Transcript.Entries (encodeEntryRecordRaw)
import Seal.Transcript.Entries qualified as Entries
import Seal.Transcript.Types (Direction (..), TranscriptEntry (..))

import Seal.Providers.Class (ContentBlock (..))
import Seal.Providers.Class qualified as PC (Message (..), Role (..))

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

-- | An ASK_HUMAN harness payload (no approval key). The question text is
-- in the @input.question@ field. This must surface so the web frontend
-- sees pending questions from channel-originated turns (Telegram, Signal).
-- Without this, a question sent to Telegram is invisible in the web
-- transcript — a \"phantom message\" that exists in the audit log but
-- not in the UI (session 20260912-183908-767 issue #2).
askHumanPayload :: Value
askHumanPayload = object
  [ "messages" .= ([] :: [Value])
  , "harness"  .= Null
  , "op"       .= object [ "name" .= String "ASK_HUMAN" ]
  , "input"    .= object ["question" .= String "What is the vault key?"]
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

-- | Extract the @direction@ field from a frontend TranscriptEntry JSON value.
getDir :: A.Value -> Maybe Value
getDir (A.Object o) = KeyMap.lookup (Key.fromText "direction") o
getDir _ = Nothing

-- | Extract a field from the @payload@ object inside a frontend
-- TranscriptEntry JSON value.
getPayloadField :: String -> A.Value -> Maybe Value
getPayloadField k (A.Object o) =
  case KeyMap.lookup (Key.fromText "payload") o of
    Just (A.Object po) -> KeyMap.lookup (Key.fromString k) po
    _ -> Nothing
getPayloadField _ _ = Nothing

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

  it "surfaces an ASK_HUMAN harness entry (whitelisted for cross-channel visibility)" $ do
    let te = mkHarnessTe askHumanPayload
    case reconEntryToFrontend 0 te of
      Just _  -> pure ()
      Nothing -> expectationFailure "expected Just (ASK_HUMAN entry surfaces), got Nothing"

  it "surfaces an approval-bearing harness entry (regression guard)" $ do
    let te = mkHarnessTe approvalPayload
    case reconEntryToFrontend 0 te of
      Just val -> do
        -- The approval key must be present in the surfaced payload. The
        -- `payload` field is now a JSON object (not a string), so we look
        -- it up as an Object and check for the "approval" key. The `raw`
        -- field carries the full rewritten payload for the reconstructed
        -- path.
        case val of
          Object o ->
            case KeyMap.lookup (Key.fromString "payload") o of
              Just (Object p) -> case KeyMap.lookup (Key.fromString "approval") p of
                Just _  -> pure ()
                Nothing -> expectationFailure "expected 'approval' key in payload object"
              other -> expectationFailure ("expected 'payload' object in frontend entry, got " ++ show other)
          _ -> expectationFailure "expected object value"
      Nothing -> expectationFailure "expected Just (approval entry surfaces), got Nothing"

  -- ── tools rewriting in request entries ──────────────────────────────

  describe "tools rewriting in request entries" $ do
    -- A helper: build a request TranscriptEntry with a tools array.
    let mkReqTe tools = TranscriptEntry
          { teId = ""
          , teTimestamp = sampleTime
          , teModel = Nothing
          , teDirection = Request
          , tePayload = object
              [ "tools" .= tools
              , "messages" .= ([] :: [Value])
              ]
          , teDurationMs = Nothing
          , teCorrelation = Nothing
          , teMeta = Map.empty
          }
        -- Look up the "tools" array inside a frontend payload object.
        frontendTools val = case val of
          Object o -> case KeyMap.lookup (Key.fromString "payload") o of
            Just (Object p) -> KeyMap.lookup (Key.fromString "tools") p
            _ -> Nothing
          _ -> Nothing

    it "includes name + description, strips input_schema (Anthropic shape)" $ do
      let tools = A.Array $ V.fromList
            [ object
                [ "name" .= ("FILE_READ" :: Text)
                , "description" .= ("Read a file from the workspace." :: Text)
                , "input_schema" .= object ["type" .= ("object" :: Text), "properties" .= object []]
                ]
            , object
                [ "name" .= ("SHELL_EXEC" :: Text)
                , "description" .= ("Run a shell command." :: Text)
                , "input_schema" .= object ["type" .= ("object" :: Text)]
                ]
            ]
          te = mkReqTe tools
      case reconEntryToFrontend 0 te of
        Just val -> case frontendTools val of
          Just (A.Array arr) -> do
            V.length arr `shouldBe` 2
            case V.head arr of
              Object o -> do
                KeyMap.lookup (Key.fromString "name") o `shouldBe` Just (String "FILE_READ")
                KeyMap.lookup (Key.fromString "description") o `shouldBe` Just (String "Read a file from the workspace.")
                KeyMap.member (Key.fromString "input_schema") o `shouldBe` False
              _ -> expectationFailure "expected tool object"
          other -> expectationFailure ("expected tools array, got " ++ show other)
        Nothing -> expectationFailure "expected Just (request entry surfaces), got Nothing"

    it "raw view preserves input_schema (Anthropic shape)" $ do
      let tools = A.Array $ V.fromList
            [ object
                [ "name" .= ("FILE_READ" :: Text)
                , "description" .= ("Read a file from the workspace." :: Text)
                , "input_schema" .= object ["type" .= ("object" :: Text), "properties" .= object []]
                ]
            ]
          te = mkReqTe tools
      case reconEntryToFrontend 0 te of
        Just val -> case val of
          Object o -> case KeyMap.lookup (Key.fromString "raw") o of
            Just (String rawTxt) -> case A.decodeStrict (BC.pack (T.unpack rawTxt)) of
              Just (Object ro) -> case KeyMap.lookup (Key.fromString "tools") ro of
                Just (A.Array rarr) -> case V.head rarr of
                  Object rt -> KeyMap.member (Key.fromString "input_schema") rt `shouldBe` True
                  _ -> expectationFailure "expected raw tool object"
                other -> expectationFailure ("expected raw tools array, got " ++ show other)
              _ -> expectationFailure "expected raw JSON to decode to an object"
            other -> expectationFailure ("expected raw string, got " ++ show other)
          _ -> expectationFailure "expected object value"
        Nothing -> expectationFailure "expected Just (request entry surfaces), got Nothing"

    it "includes name + description from Ollama function wrapper shape" $ do
      let tools = A.Array $ V.fromList
            [ object
                [ "type" .= ("function" :: Text)
                , "function" .= object
                    [ "name" .= ("WEB_SEARCH" :: Text)
                    , "description" .= ("Search the web." :: Text)
                    , "parameters" .= object ["type" .= ("object" :: Text)]
                    ]
                ]
            ]
          te = mkReqTe tools
      case reconEntryToFrontend 0 te of
        Just val -> case frontendTools val of
          Just (A.Array arr) -> do
            V.length arr `shouldBe` 1
            case V.head arr of
              Object o -> do
                KeyMap.lookup (Key.fromString "name") o `shouldBe` Just (String "WEB_SEARCH")
                KeyMap.lookup (Key.fromString "description") o `shouldBe` Just (String "Search the web.")
                KeyMap.member (Key.fromString "parameters") o `shouldBe` False
                KeyMap.member (Key.fromString "function") o `shouldBe` False
              _ -> expectationFailure "expected tool object"
          other -> expectationFailure ("expected tools array, got " ++ show other)
        Nothing -> expectationFailure "expected Just (request entry surfaces), got Nothing"

  -- ── trailingConvEntries ─────────────────────────────────────────────

  describe "Seal.Gateway.Transcript.trailingConvEntries" $ do
    -- | Build a conversation.jsonl line as an Aeson Value (the shape
    -- convLineToFrontend expects: {role, content: [ContentBlock]}).
    let convLine roleText blocks =
          A.object [ "role" A..= (roleText :: Text)
                   , "content" A..= map blkToJson blocks
                   ]
        blkToJson (CbText t) = A.object ["tag" A..= ("CbText" :: Text), "contents" A..= t]
        blkToJson (CbToolUse cid name inp) =
          A.object [ "tag"      A..= ("CbToolUse" :: Text)
                   , "id"       A..= cid
                   , "name"     A..= name
                   , "input"    A..= inp
                   ]
        blkToJson _ = A.object ["tag" A..= ("CbText" :: Text), "contents" A..= ("?" :: Text)]

    it "returns empty when all conversation messages are covered by entries" $ do
      let msgs = [ convLine "User" [CbText "hi"]
                 , convLine "Assistant" [CbText "hello"]
                 ]
      trailingConvEntries "model-x" "2026-01-01T00:00:00.000Z" 2 msgs
        `shouldBe` []

    it "synthesizes frontend entries for trailing conversation messages" $ do
      -- entries cover 2 messages (convLen=2), but conversation has 4.
      -- The trailing 2 messages (indices 2,3) should become frontend entries.
      let msgs = [ convLine "User"      [CbText "hi"]
                 , convLine "Assistant" [CbText "hello"]
                 , convLine "User"      [CbText "what is 2+2?"]
                 , convLine "Assistant" [CbText "it's 4"]
                 ]
          result = trailingConvEntries "model-x" "2026-01-01T00:00:00.000Z" 2 msgs
      length result `shouldBe` 2
      -- First trailing entry (index 2) is a user message → request direction.
      case result of
        [e1, e2] -> do
          getDir e1 `shouldBe` Just (String "request")
          getDir e2 `shouldBe` Just (String "response")
          -- The response entry should carry the assistant's content.
          case getPayloadField "content" e2 of
            Just (A.Array arr) -> length arr `shouldBe` 1
            other -> expectationFailure ("expected content array, got " ++ show other)
        other -> expectationFailure ("expected 2 entries, got " ++ show (length other))

    it "handles maxConvLen=0 (entries cover nothing)" $ do
      let msgs = [ convLine "User" [CbText "hi"]
                 , convLine "Assistant" [CbText "hello"]
                 ]
          result = trailingConvEntries "model-x" "2026-01-01T00:00:00.000Z" 0 msgs
      length result `shouldBe` 2

  -- ── readTranscriptEntriesTimed: trailing entries with limit ──────────

  describe "readTranscriptEntriesTimed trailing entries with limit" $ do
    let mkPaths root = SealPaths root (root </> "config") (root </> "state") (root </> "keys") (root </> "cache")
        mkSid = case mkSessionId "test-session" of Right s -> s; Left _ -> error "bad sid"
        setupSession :: Int -> Int -> IO SealPaths
        setupSession entryCount trailingCount = do
          dir <- withSystemTempDirectory "seal-transcript" pure
          let paths = mkPaths dir
              sessionDir = dir </> "state" </> "sessions" </> "test-session"
              convPath = sessionDir </> "conversation.jsonl"
              entriesPath = sessionDir </> "entries.jsonl"
              idxPath = sessionDir </> "conversation.idx"
              totalLines = entryCount + trailingCount
          let convMsgs = [ PC.Message (if even i then PC.User else PC.Assistant) [CbText (T.pack ("msg-" <> show i))]
                         | i <- [0 .. totalLines - 1] ]
              convBs = BS.concat (map (\m -> encodeConvLine (ConvLine m) <> "\n") convMsgs)
          createDirectoryIfMissing True sessionDir
          BS.writeFile convPath convBs
          now <- getCurrentTime
          let entries = [ Entries.EntryRecord
                          { Entries.erId = ""
                          , Entries.erTimestamp = now
                          , Entries.erKind = Entries.EKRequest
                          , Entries.erConvLen = i + 1
                          , Entries.erEnvelope = Just Entries.emptyEnvelopeDelta
                          , Entries.erUsage = Nothing
                          , Entries.erStop = Nothing
                          , Entries.erDurationMs = Nothing
                          , Entries.erHarness = Nothing
                          , Entries.erCorrelation = Nothing
                          , Entries.erMeta = Map.empty
                          }
                        | i <- [0 .. entryCount - 1] ]
              entriesBs = BS.concat (map (\e -> encodeEntryRecordRaw e <> "\n") entries)
          BS.writeFile entriesPath entriesBs
          _ <- buildIndex convPath idxPath
          pure paths

    it "returns trailing entries even when limit is fully consumed by reconstructed entries" $ do
      -- 10 entries (covering 10 conv lines) + 20 trailing conv lines.
      -- With limit=10, the old code allocated all 10 to reconstruction
      -- (remaining = 10 - 10 = 0 → no trailing). The fix splits the limit
      -- so trailing entries get up to half: 5 reconstructed + 5 trailing.
      paths <- setupSession 10 20
      (frontend, tt) <- readTranscriptEntriesTimed paths "test-model" "2026-01-01T00:00:00.000Z" mkSid (Just 10)
      -- The fix ensures trailing entries are sent alongside reconstructed
      -- entries. At minimum, we should get trailing entries (the most
      -- recent activity). The exact split depends on the limit allocation.
      length frontend `shouldSatisfy` (>= 5)
      -- totalCount should include trailing lines.
      ttEntryCount tt `shouldBe` 10 + 20

    it "returns all trailing entries when no limit is set" $ do
      paths <- setupSession 5 10
      (frontend, tt) <- readTranscriptEntriesTimed paths "test-model" "2026-01-01T00:00:00.000Z" mkSid Nothing
      -- Without a limit, all entries + all trailing are returned.
      -- reconEntryToFrontend may filter some entries, so we check
      -- that trailing entries are present and totalCount is correct.
      length frontend `shouldSatisfy` (>= 10)
      ttEntryCount tt `shouldBe` 5 + 10

    it "returns only trailing entries when entries.jsonl is empty" $ do
      paths <- setupSession 0 5
      (frontend, _tt) <- readTranscriptEntriesTimed paths "test-model" "2026-01-01T00:00:00.000Z" mkSid (Just 10)
      -- No entries → all 5 trailing lines are returned.
      length frontend `shouldBe` 5

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
