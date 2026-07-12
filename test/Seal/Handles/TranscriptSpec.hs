{-# LANGUAGE OverloadedStrings #-}
module Seal.Handles.TranscriptSpec (spec) where

import Data.Aeson (object, (.=))
import Data.ByteString.Char8 qualified as BS8
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Time (getCurrentTime)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Providers.Class
  ( ContentBlock (..), Message (..), Role (..), ToolResultPart (..) )
import Seal.Core.Types (OpName (..), ToolCallId (..))
import Seal.Transcript.Entries
  ( EntryKind (..), EntryRecord (..), emptyEnvelopeDelta )
import Seal.Transcript.Types
import Seal.Handles.Transcript

mkEntry :: IO TranscriptEntry
mkEntry = do
  now <- getCurrentTime
  pure TranscriptEntry
    { teId = "e1"
    , teTimestamp = now
    , teModel = Nothing
    , teDirection = Request
    , tePayload = object ["x" .= (1 :: Int)]
    , teDurationMs = Nothing
    , teCorrelation = Nothing
    , teMeta = Map.empty
    }

-- | A minimal entry record for the two-file writer tests.
mkEntryRecord :: IO EntryRecord
mkEntryRecord = do
  now <- getCurrentTime
  pure EntryRecord
    { erId = "r1"
    , erTimestamp = now
    , erKind = EKRequest
    , erConvLen = 1
    , erEnvelope = Just emptyEnvelopeDelta
    , erUsage = Nothing
    , erStop = Nothing
    , erDurationMs = Nothing
    , erHarness = Nothing
    , erCorrelation = Nothing
    , erMeta = Map.empty
    }

spec :: Spec
spec = describe "Seal.Handles.Transcript" $ do
  describe "legacy single-file" $ do
    it "recordAndAck durably appends one JSONL line per entry" $
      withSystemTempDirectory "seal-tx" $ \dir -> do
        let path = dir </> "transcript.jsonl"
        e <- mkEntry
        withTranscript path $ \h -> do
          recordAndAck h e
          recordAndAck h e
        contents <- BS8.readFile path
        length (BS8.lines contents) `shouldBe` 2

    it "drains a recordAsync entry queued just before scope exit" $
      withSystemTempDirectory "seal-tx" $ \dir -> do
        let path = dir </> "transcript.jsonl"
        e <- mkEntry
        withTranscript path $ \h ->
          recordAsync h e
        contents <- BS8.readFile path
        length (BS8.lines contents) `shouldBe` 1

    it "fakeTranscript records invocation order for assertions" $ do
      (h, readLog) <- fakeTranscript
      e <- mkEntry
      recordAndAck h e
      logged <- readLog
      map teId logged `shouldBe` ["e1"]

  describe "two-file format" $ do
    it "writes conversation.jsonl and entries.jsonl with one line each per write" $
      withSystemTempDirectory "seal-twofile" $ \dir -> do
        e <- mkEntryRecord
        let conv = [Message User [CbText "hello"]]
        withTwoFileTranscript dir $ \h -> do
          tfwRecordAndAck h (TwoFileWrite conv e)
        convContents <- BS8.readFile (dir </> "conversation.jsonl")
        entriesContents <- BS8.readFile (dir </> "entries.jsonl")
        length (BS8.lines convContents) `shouldBe` 1
        length (BS8.lines entriesContents) `shouldBe` 1

    it "grows conversation.jsonl by deltas across turns" $
      withSystemTempDirectory "seal-twofile" $ \dir -> do
        e1 <- mkEntryRecord
        e2 <- mkEntryRecord
        let turn1 = [Message User [CbText "a"]]
            turn2 = turn1 <> [Message Assistant [CbText "b"]]
        withTwoFileTranscript dir $ \h -> do
          tfwRecordAndAck h (TwoFileWrite turn1 e1)
          tfwRecordAndAck h (TwoFileWrite turn2 e2)
        convContents <- BS8.readFile (dir </> "conversation.jsonl")
        -- turn1 writes 1 line ("a"); turn2 diffs and writes only "b".
        length (BS8.lines convContents) `shouldBe` 2

    it "redacts CbToolResult parts from secret-producing opcodes so secret values never reach disk" $
      withSystemTempDirectory "seal-twofile" $ \dir -> do
        e <- mkEntryRecord
        let secret = TrpText "super-secret-api-key"
            toolUse = Message Assistant [CbToolUse (ToolCallId "tc1") (OpName "SECRET_GET") (object [])]
            resultMsg = Message User [CbToolResult (ToolCallId "tc1") [secret] False]
        withTwoFileTranscript dir $ \h -> do
          tfwSetSecretOps h (Set.fromList [OpName "SECRET_GET"])
          tfwRecordAndAck h (TwoFileWrite [toolUse, resultMsg] e)
        convContents <- BS8.readFile (dir </> "conversation.jsonl")
        BS8.unpack convContents `shouldNotContain` "super-secret-api-key"
        BS8.unpack convContents `shouldContain` "<redacted:secret>"

    it "does NOT redact CbToolResult parts from non-secret opcodes (e.g. SHELL_EXEC)" $
      withSystemTempDirectory "seal-twofile" $ \dir -> do
        e <- mkEntryRecord
        let output = TrpText "total used free\n4096 2048 2048"
            toolUse = Message Assistant [CbToolUse (ToolCallId "tc1") (OpName "SHELL_EXEC") (object ["command" .= ("free -h" :: String)])]
            resultMsg = Message User [CbToolResult (ToolCallId "tc1") [output] False]
        withTwoFileTranscript dir $ \h -> do
          tfwSetSecretOps h (Set.fromList [OpName "SECRET_GET"])
          tfwRecordAndAck h (TwoFileWrite [toolUse, resultMsg] e)
        convContents <- BS8.readFile (dir </> "conversation.jsonl")
        -- Shell output passes through verbatim — NOT redacted.
        BS8.unpack convContents `shouldContain` "total used free"
        BS8.unpack convContents `shouldNotContain` "<redacted:secret>"

    it "readConversation / readEntries round-trip the written data" $
      withSystemTempDirectory "seal-twofile" $ \dir -> do
        e <- mkEntryRecord
        let conv = [Message User [CbText "hi"], Message Assistant [CbText "bye"]]
        withTwoFileTranscript dir $ \h -> do
          tfwRecordAndAck h (TwoFileWrite conv e)
          -- read back through the handle
          msgs <- tfwReadConversation h
          -- The first message is plain text; the round-trip preserves it.
          case msgs of
            (m : _) -> msgRole m `shouldBe` User
            []      -> expectationFailure "no messages read back"
        -- entries file also readable
        withTwoFileTranscript dir $ \h -> do
          es <- tfwReadEntries h
          case es of
            (r : _) -> erId r `shouldBe` "r1"
            []      -> expectationFailure "no entries read back"

    it "fakeTwoFileTranscript records writes in memory" $ do
      (h, readState) <- fakeTwoFileTranscript
      e <- mkEntryRecord
      let conv = [Message User [CbText "hi"]]
      tfwRecordAndAck h (TwoFileWrite conv e)
      (msgs, _entries) <- readState
      length msgs `shouldBe` 1
      length _entries `shouldBe` 1
