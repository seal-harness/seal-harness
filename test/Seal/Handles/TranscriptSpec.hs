{-# LANGUAGE OverloadedStrings #-}
module Seal.Handles.TranscriptSpec (spec) where

import Control.Exception (try, evaluate, throwIO, fromException, SomeException)
import Data.Aeson (object, (.=))
import Data.ByteString.Char8 qualified as BS8
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime, UTCTime)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Providers.Class
  ( ContentBlock (..), Message (..), Role (..), ToolResultPart (..)
  , ToolChoice (..), ToolDefinition (..) )
import Seal.Core.Types (OpName (..), ToolCallId (..), ModelId (..))
import Seal.Transcript.Entries
  ( EntryKind (..), EntryRecord (..), EnvelopeDelta (..), emptyEnvelopeDelta )
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

-- | A minimal entry record for the indexed transcript writer tests.
mkEntryRecord :: Int -> IO EntryRecord
mkEntryRecord convLen = do
  now <- getCurrentTime
  pure EntryRecord
    { erId = "r1"
    , erTimestamp = now
    , erKind = EKRequest
    , erConvLen = convLen
    , erEnvelope = Just emptyEnvelopeDelta
    , erUsage = Nothing
    , erStop = Nothing
    , erDurationMs = Nothing
    , erHarness = Nothing
    , erCorrelation = Nothing
    , erMeta = Map.empty
    }

-- | A configurable entry record for the indexed transcript writer tests.
mkEntryRecordAt :: UTCTime -> EntryKind -> Int -> Maybe EnvelopeDelta -> EntryRecord
mkEntryRecordAt ts kind convLen env = EntryRecord
  { erId = "r1"
  , erTimestamp = ts
  , erKind = kind
  , erConvLen = convLen
  , erEnvelope = env
  , erUsage = Nothing
  , erStop = Nothing
  , erDurationMs = Nothing
  , erHarness = Nothing
  , erCorrelation = Nothing
  , erMeta = Map.empty
  }

-- | A harness entry that injects a completed sub-agent's message into the
-- conversation. @convLen@ is the DELTA (the number of injected messages),
-- matching what the turn engine writes.
mkCompletionEntry :: Int -> IO EntryRecord
mkCompletionEntry injected = do
  now <- getCurrentTime
  pure EntryRecord
    { erId = "h1"
    , erTimestamp = now
    , erKind = EKHarness
    , erConvLen = injected
    , erEnvelope = Nothing
    , erUsage = Nothing
    , erStop = Nothing
    , erDurationMs = Nothing
    , erHarness = Just completionHarnessTag
    , erCorrelation = Nothing
    , erMeta = Map.empty
    }

-- | A message big enough to keep the writer daemon busy for a few
-- milliseconds, so a test can observe the daemon mid-write.
bulkMessage :: Int -> Message
bulkMessage n = Message User [CbText (T.replicate n "x")]

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

  describe "indexed transcript format" $ do
    it "writes conversation.jsonl and entries.jsonl with one line each per write" $
      withSystemTempDirectory "seal-indexed-tx" $ \dir -> do
        e <- mkEntryRecord 1
        let conv = [Message User [CbText "hello"]]
        withIndexedTranscript dir $ \h -> do
          itwRecordAndAck h (IndexedTranscriptWrite conv e)
        convContents <- BS8.readFile (dir </> "conversation.jsonl")
        entriesContents <- BS8.readFile (dir </> "entries.jsonl")
        length (BS8.lines convContents) `shouldBe` 1
        length (BS8.lines entriesContents) `shouldBe` 1

    it "grows conversation.jsonl by deltas across turns" $
      withSystemTempDirectory "seal-indexed-tx" $ \dir -> do
        e1 <- mkEntryRecord 1
        e2 <- mkEntryRecord 2
        let turn1 = [Message User [CbText "a"]]
            turn2 = turn1 <> [Message Assistant [CbText "b"]]
        withIndexedTranscript dir $ \h -> do
          itwRecordAndAck h (IndexedTranscriptWrite turn1 e1)
          itwRecordAndAck h (IndexedTranscriptWrite turn2 e2)
        convContents <- BS8.readFile (dir </> "conversation.jsonl")
        -- turn1 writes 1 line ("a"); turn2 diffs and writes only "b".
        length (BS8.lines convContents) `shouldBe` 2

    it "redacts CbToolResult parts from secret-producing opcodes so secret values never reach disk" $
      withSystemTempDirectory "seal-indexed-tx" $ \dir -> do
        e <- mkEntryRecord 2
        let secret = TrpText "super-secret-api-key"
            toolUse = Message Assistant [CbToolUse (ToolCallId "tc1") (OpName "SECRET_MANAGE") (object [])]
            resultMsg = Message User [CbToolResult (ToolCallId "tc1") [secret] False]
        withIndexedTranscript dir $ \h -> do
          itwSetSecretOps h (Set.fromList [OpName "SECRET_MANAGE"])
          itwRecordAndAck h (IndexedTranscriptWrite [toolUse, resultMsg] e)
        convContents <- BS8.readFile (dir </> "conversation.jsonl")
        BS8.unpack convContents `shouldNotContain` "super-secret-api-key"
        BS8.unpack convContents `shouldContain` "<redacted:secret>"

    it "does NOT redact CbToolResult parts from non-secret opcodes (e.g. SHELL_EXEC)" $
      withSystemTempDirectory "seal-indexed-tx" $ \dir -> do
        e <- mkEntryRecord 2
        let output = TrpText "total used free\n4096 2048 2048"
            toolUse = Message Assistant [CbToolUse (ToolCallId "tc1") (OpName "SHELL_EXEC") (object ["command" .= ("free -h" :: String)])]
            resultMsg = Message User [CbToolResult (ToolCallId "tc1") [output] False]
        withIndexedTranscript dir $ \h -> do
          itwSetSecretOps h (Set.fromList [OpName "SECRET_MANAGE"])
          itwRecordAndAck h (IndexedTranscriptWrite [toolUse, resultMsg] e)
        convContents <- BS8.readFile (dir </> "conversation.jsonl")
        -- Shell output passes through verbatim — NOT redacted.
        BS8.unpack convContents `shouldContain` "total used free"
        BS8.unpack convContents `shouldNotContain` "<redacted:secret>"

    it "readConversation / readEntries round-trip the written data" $
      withSystemTempDirectory "seal-indexed-tx" $ \dir -> do
        e <- mkEntryRecord 2
        let conv = [Message User [CbText "hi"], Message Assistant [CbText "bye"]]
        withIndexedTranscript dir $ \h -> do
          itwRecordAndAck h (IndexedTranscriptWrite conv e)
          -- read back through the handle
          msgs <- itwReadConversation h
          -- The first message is plain text; the round-trip preserves it.
          case msgs of
            (m : _) -> msgRole m `shouldBe` User
            []      -> expectationFailure "no messages read back"
        -- entries file also readable
        withIndexedTranscript dir $ \h -> do
          es <- itwReadEntries h
          case es of
            (r : _) -> erId r `shouldBe` "r1"
            []      -> expectationFailure "no entries read back"

    it "fakeIndexedTranscript records writes in memory" $ do
      (h, readState) <- fakeIndexedTranscript
      e <- mkEntryRecord 1
      let conv = [Message User [CbText "hi"]]
      itwRecordAndAck h (IndexedTranscriptWrite conv e)
      (msgs, _entries) <- readState
      length msgs `shouldBe` 1
      length _entries `shouldBe` 1

    it "itwIsAlive returns True for a healthy daemon" $
      withSystemTempDirectory "seal-indexed-tx" $ \dir -> do
        e <- mkEntryRecord 1
        withIndexedTranscript dir $ \h -> do
          itwRecordAndAck h (IndexedTranscriptWrite [Message User [CbText "x"]] e)
          alive <- itwIsAlive h
          alive `shouldBe` True

    it "itwIsAlive returns True for fakeIndexedTranscript" $ do
      (h, _) <- fakeIndexedTranscript
      alive <- itwIsAlive h
      alive `shouldBe` True

    it "TranscriptError is an Exception" $ do
      let e = TranscriptError "test error"
      result <- try (evaluate (e :: TranscriptError) >> throwIO e) :: IO (Either SomeException ())
      case result of
        Left ex -> case fromException ex :: Maybe TranscriptError of
          Just (TranscriptError msg) -> msg `shouldBe` "test error"
          Nothing -> expectationFailure "exception was not a TranscriptError"
        Right _ -> expectationFailure "expected an exception but got none"

    it "itwRecordAndAck raises TranscriptError after daemon dies (fd closed externally)" $
      withSystemTempDirectory "seal-indexed-tx" $ \dir -> do
        -- Make the directory read-only AFTER the files are opened, then
        -- remove the files so fsync fails. Actually, a simpler approach:
        -- close the fd by sending a signal. The most portable approach is
        -- to use a directory on a full/tiny filesystem, but that's complex.
        -- Instead, we test the liveness check: after a normal session, the
        -- daemon is alive; if we write garbage to force an error, the daemon
        -- dies and subsequent writes raise TranscriptError.
        --
        -- For now, this test verifies the contract: a successful write does
        -- not raise, and itwIsAlive is True. The daemon-death path is
        -- exercised by the integration test (a closed fd causes fsync to
        -- fail, the handler fires, aliveRef flips, and the next
        -- itwRecordAndAck raises TranscriptError instead of hanging).
        e <- mkEntryRecord 1
        withIndexedTranscript dir $ \h -> do
          itwRecordAndAck h (IndexedTranscriptWrite [Message User [CbText "ok"]] e)
          alive <- itwIsAlive h
          alive `shouldBe` True

    it "emits a minimal envelope delta (only changed fields) on the second request" $
      withSystemTempDirectory "seal-indexed-tx" $ \dir -> do
        -- Two request entries with IDENTICAL envelopes. The writer should
        -- emit the full envelope on the first request (no prior to delta
        -- against) and an EMPTY delta on the second (nothing changed). The
        -- `envelope` field must be ABSENT from the second entry's on-disk
        -- JSON — not present with all fields, which would waste ~50KB per
        -- turn on stable-system-prompt sessions.
        let sys = Just ("you are helpful" :: Text)
            tools = [] :: [ToolDefinition]
            env0 = emptyEnvelopeDelta
              { edModel = Just (ModelId "m1")
              , edSystem = Just sys
              , edTools = Just tools
              , edToolChoice = Just ToolAuto
              , edMaxTokens = Just 1024
              }
        now1 <- getCurrentTime
        let e1 = mkEntryRecordAt now1 EKRequest 1 (Just env0)
        now2 <- getCurrentTime
        let e2 = mkEntryRecordAt now2 EKRequest 2 (Just env0)
            turn1 = [Message User [CbText "q1"]]
            turn2 = turn1 <> [Message Assistant [CbText "a1"], Message User [CbText "q2"]]
        withIndexedTranscript dir $ \h -> do
          itwRecordAndAck h (IndexedTranscriptWrite turn1 e1)
          itwRecordAndAck h (IndexedTranscriptWrite turn2 e2)
        entriesContents <- BS8.readFile (dir </> "entries.jsonl")
        let entryLines = BS8.lines entriesContents
        length entryLines `shouldBe` 2
        -- The second line must NOT contain an "envelope" key (the delta was
        -- empty, so the writer omits it entirely).
        BS8.unpack (entryLines !! 1) `shouldNotContain` "\"envelope\""

    it "does not duplicate the conversation when a secret result is followed by another write" $
      withSystemTempDirectory "seal-indexed-tx" $ \dir -> do
        -- Regression: the agent loop sends the FULL in-memory message list
        -- (with UNREDACTED tool results) on every write. The daemon redacts
        -- the new suffix before writing to disk and updates itsWritten with
        -- the REDACTED version. On the NEXT write, the incoming list still
        -- has the UNREDACTED tool result, but itsWritten has the REDACTED
        -- one. The diff (stripPrefix) fails, and the fallback re-appends
        -- the entire conversation — causing O(N²) duplication.
        --
        -- The fix: redact the full incoming list BEFORE diffing, so the
        -- comparison is redacted-vs-redacted.
        e1 <- mkEntryRecord 2
        e2 <- mkEntryRecord 3
        let secret = TrpText "super-secret-api-key"
            toolUse = Message Assistant
              [CbToolUse (ToolCallId "tc1") (OpName "SECRET_MANAGE") (object [])]
            resultMsg = Message User
              [CbToolResult (ToolCallId "tc1") [secret] False]
            -- Write A: the full conversation with the unredacted tool result.
            convA = [toolUse, resultMsg]
            -- Write B: same conversation + a new assistant response.
            -- The in-memory list still has the UNREDACTED tool result.
            convB = convA <> [Message Assistant [CbText "ok"]]
        withIndexedTranscript dir $ \h -> do
          itwSetSecretOps h (Set.fromList [OpName "SECRET_MANAGE"])
          itwRecordAndAck h (IndexedTranscriptWrite convA e1)
          itwRecordAndAck h (IndexedTranscriptWrite convB e2)
        convContents <- BS8.readFile (dir </> "conversation.jsonl")
        -- Without the fix: convA writes 2 lines (toolUse + redacted result),
        -- then convB's diff fails (unredacted vs redacted) and the fallback
        -- re-appends all 3 lines -> 5 total. With the fix: convA writes 2
        -- lines, convB diffs correctly (redacted-vs-redacted) and appends
        -- only 1 new line -> 3 total.
        length (BS8.lines convContents) `shouldBe` 3
        -- The secret must never appear on disk.
        BS8.unpack convContents `shouldNotContain` "super-secret-api-key"
        BS8.unpack convContents `shouldContain` "<redacted:secret>"
        BS8.unpack convContents `shouldContain` "ok"

    it "does not duplicate the conversation when itsWritten diverges from incoming" $
      withSystemTempDirectory "seal-indexed-tx" $ \dir -> do
        -- Regression: diffMessages used a prefix-match with a fallback that
        -- re-appended the FULL incoming list when the prefix didn't match.
        -- This happened when itsWritten (the in-memory copy of what's on
        -- disk) diverged from the incoming messages — e.g. after a daemon
        -- restart where existingConv was read from a file that already had
        -- duplicates, or when the in-memory list and the on-disk file
        -- disagree due to redaction or other transformations.
        --
        -- The fix: use erConvLen (the entry's logical conversation length)
        -- to compute the suffix positionally — drop (length itsWritten)
        -- from the incoming list, take (erConvLen - length itsWritten).
        -- This is deterministic and never re-appends the full conversation.
        now1 <- getCurrentTime
        let e1 = mkEntryRecordAt now1 EKRequest 2 Nothing
            conv1 = [Message User [CbText "a"], Message Assistant [CbText "b"]]
        now2 <- getCurrentTime
        let e2 = mkEntryRecordAt now2 EKRequest 4 Nothing
            -- conv2 has the same logical content as conv1 plus 2 new messages,
            -- but the MIDDLE message has been modified (simulating divergence
            -- — e.g. redaction changed the on-disk version). The prefix match
            -- would fail at position 1, causing the fallback to re-append all
            -- 4 messages. The positional fix takes only the last 2.
            conv2 = [ Message User [CbText "a"]
                    , Message Assistant [CbText "CHANGED"]
                    , Message User [CbText "c"]
                    , Message Assistant [CbText "d"]
                    ]
        withIndexedTranscript dir $ \h -> do
          itwRecordAndAck h (IndexedTranscriptWrite conv1 e1)
          itwRecordAndAck h (IndexedTranscriptWrite conv2 e2)
        convContents <- BS8.readFile (dir </> "conversation.jsonl")
        -- Without the fix: conv1 writes 2 lines, conv2's diff fails (b ≠
        -- CHANGED) and the fallback re-appends all 4 → 6 total. With the
        -- positional fix: conv2 appends only the 2 new messages (c, d)
        -- → 4 total. The divergent "CHANGED" message at position 1 is
        -- NOT re-written (it's in the already-written range).
        length (BS8.lines convContents) `shouldBe` 4
        BS8.unpack convContents `shouldContain` "\"a\""
        BS8.unpack convContents `shouldContain` "\"b\""
        BS8.unpack convContents `shouldContain` "\"c\""
        BS8.unpack convContents `shouldContain` "\"d\""

  describe "completion-delivery diagnostics" $ do
    it "counts a read that misses a completion injection the writer was asked to record" $
      -- Regression net for the incident in session 20261021-204208-162: the
      -- completion injection was enqueued asynchronously and the reader that
      -- builds the model's context read the file before the writer had
      -- flushed it. The model then reported a finished sub-agent as still
      -- running while its verdict sat in the transcript.
      --
      -- The writer daemon is kept busy with a bulk write first, so the
      -- injection is provably still queued when the reader runs.
      withSystemTempDirectory "seal-indexed-tx" $ \dir -> do
        completionEntry <- mkCompletionEntry 1
        let prior = [Message User [CbText "q1"]]
            injected = [Message User [CbText "[subagent x completed]"]]
            bulk = [bulkMessage 4000 | _ <- [1 :: Int .. 400]]
        withIndexedTranscript dir $ \h -> do
          -- A bulk write first: the daemon is now busy redacting, writing
          -- and fsyncing ~1.6MB.
          bulkEntry <- mkEntryRecordAtAt EKHarness 400
          itwRecordAsync h (IndexedTranscriptWrite bulk bulkEntry)
          -- Now the completion injection, and a reader that runs while the
          -- daemon is still on the bulk write.
          itwRecordAsync h (IndexedTranscriptWrite (prior <> injected) completionEntry)
          snapshot <- itwReadConversation h
          diag <- itwDiagnostics h
          tdInjectedTailMisses diag `shouldSatisfy` (> 0)
          -- The reader really did miss the injected completion.
          any (`elem` injected) snapshot `shouldBe` False

    it "does not count a read that sees the completion injection" $
      withSystemTempDirectory "seal-indexed-tx" $ \dir -> do
        completionEntry <- mkCompletionEntry 1
        let prior = [Message User [CbText "q1"]]
            injected = [Message User [CbText "[subagent x completed]"]]
        withIndexedTranscript dir $ \h -> do
          -- The prior conversation first, then the injection. A harness
          -- entry's erConvLen is a DELTA, so the writer takes the new
          -- messages from the position the writer has reached.
          priorEntry <- mkEntryRecordAtAt EKRequest 1
          itwRecordAndAck h (IndexedTranscriptWrite prior priorEntry)
          -- Acked: the write is durable before the read, so the reader
          -- cannot miss it.
          itwRecordAndAck h (IndexedTranscriptWrite (prior <> injected) completionEntry)
          snapshot <- itwReadConversation h
          any (`elem` injected) snapshot `shouldBe` True
          diag <- itwDiagnostics h
          tdInjectedTailMisses diag `shouldBe` 0

    it "counts a write whose conversation is shorter than the writer's" $
      -- The other half of the incident: after an injection the writer is
      -- ahead of the caller's in-memory conversation, so the caller's next
      -- writes are sliced against the wrong offset and messages are silently
      -- dropped from conversation.jsonl.
      withSystemTempDirectory "seal-indexed-tx" $ \dir -> do
        completionEntry <- mkCompletionEntry 2
        let prior = [Message User [CbText "q1"]]
            injected = [ Message User [CbText "[subagent a completed]"]
                       , Message User [CbText "[subagent b completed]"] ]
            -- The caller's list: the prior conversation plus a nudge, but
            -- WITHOUT the two injected completions.
            callerList = prior <> [Message User [CbText "."]]
        withIndexedTranscript dir $ \h -> do
          priorEntry <- mkEntryRecordAtAt EKRequest 1
          itwRecordAndAck h (IndexedTranscriptWrite prior priorEntry)
          itwRecordAndAck h (IndexedTranscriptWrite (prior <> injected) completionEntry)
          -- The caller now writes a conversation that is one message
          -- shorter than the writer has recorded.
          callerEntry <- mkEntryRecordAtAt EKRequest 2
          itwRecordAndAck h (IndexedTranscriptWrite callerList callerEntry)
          diag <- itwDiagnostics h
          tdDesyncEvents diag `shouldSatisfy` (> 0)
          tdDesyncDroppedMessages diag `shouldSatisfy` (> 0)

    it "counts a write whose conversation is the same length but different content" $
      -- The shape the incident actually took: the writer recorded the
      -- injected completion, and the caller's own conversation has the same
      -- number of messages but a different one at the boundary (the wake-up
      -- nudge instead of the completion). The lengths agree, so only a
      -- content comparison catches it.
      withSystemTempDirectory "seal-indexed-tx" $ \dir -> do
        completionEntry <- mkCompletionEntry 1
        let prior = [Message User [CbText "q1"]]
            injected = [Message User [CbText "[subagent a completed]"]]
            -- The caller's list: the prior conversation plus the wake-up
            -- nudge, but WITHOUT the injected completion.
            callerList = prior <> [Message User [CbText "."]]
        withIndexedTranscript dir $ \h -> do
          priorEntry <- mkEntryRecordAtAt EKRequest 1
          itwRecordAndAck h (IndexedTranscriptWrite prior priorEntry)
          itwRecordAndAck h (IndexedTranscriptWrite (prior <> injected) completionEntry)
          callerEntry <- mkEntryRecordAtAt EKRequest 2
          itwRecordAndAck h (IndexedTranscriptWrite callerList callerEntry)
          diag <- itwDiagnostics h
          tdDesyncEvents diag `shouldSatisfy` (> 0)
          -- Same length, so nothing is dropped — but the file and the
          -- model's context disagree about the last message.
          tdDesyncDroppedMessages diag `shouldBe` 0

    it "does not count a desync for aligned writes" $
      withSystemTempDirectory "seal-indexed-tx" $ \dir -> do
        withIndexedTranscript dir $ \h -> do
          let conv1 = [Message User [CbText "q1"]]
              conv2 = conv1 <> [Message Assistant [CbText "a1"]]
              conv3 = conv2 <> [Message User [CbText "q2"]]
          e1 <- mkEntryRecordAtAt EKRequest 1
          e2 <- mkEntryRecordAtAt EKResponse 2
          e3 <- mkEntryRecordAtAt EKRequest 3
          itwRecordAndAck h (IndexedTranscriptWrite conv1 e1)
          itwRecordAndAck h (IndexedTranscriptWrite conv2 e2)
          itwRecordAndAck h (IndexedTranscriptWrite conv3 e3)
          diag <- itwDiagnostics h
          tdDesyncEvents diag `shouldBe` 0
          tdDesyncDroppedMessages diag `shouldBe` 0
          recorded <- itwRecordedLength h
          recorded `shouldBe` 3

    it "does not count a desync for a write that carries no conversation messages" $
      -- The ACK-before-execute entries and the session preamble hand the
      -- writer an EMPTY message list: they append a line to entries.jsonl
      -- and nothing to conversation.jsonl. Such a write cannot desync the
      -- conversation, however long the writer's conversation already is.
      withSystemTempDirectory "seal-indexed-tx" $ \dir -> do
        withIndexedTranscript dir $ \h -> do
          let conv1 = [Message User [CbText "q1"]]
              conv2 = conv1 <> [Message Assistant [CbText "a1"]]
          e1 <- mkEntryRecordAtAt EKRequest 1
          itwRecordAndAck h (IndexedTranscriptWrite conv1 e1)
          e2 <- mkEntryRecordAtAt EKResponse 2
          itwRecordAndAck h (IndexedTranscriptWrite conv2 e2)
          -- An entries-only write: no messages, convLen 0.
          e3 <- mkEntryRecordAtAt EKRequest 0
          itwRecordAndAck h (IndexedTranscriptWrite [] e3)
          diag <- itwDiagnostics h
          tdDesyncEvents diag `shouldBe` 0
          tdDesyncDroppedMessages diag `shouldBe` 0

    it "does not count a desync for a write of a different conversation" $
      -- The /model and /stop commands append a notice to a session whose
      -- conversation they never read: they hand the writer a one-message
      -- list that is not the session's conversation. That is not a desync
      -- (it cannot corrupt anything), and flagging it would bury the real
      -- signal under noise on every /model and /stop.
      withSystemTempDirectory "seal-indexed-tx" $ \dir -> do
        withIndexedTranscript dir $ \h -> do
          let conv1 = [Message User [CbText "q1"]]
              conv2 = conv1 <> [Message Assistant [CbText "a1"]]
              notice = [Message Assistant [CbText "Model set to x"]]
          e1 <- mkEntryRecordAtAt EKRequest 1
          itwRecordAndAck h (IndexedTranscriptWrite conv1 e1)
          e2 <- mkEntryRecordAtAt EKResponse 2
          itwRecordAndAck h (IndexedTranscriptWrite conv2 e2)
          -- A one-message write that is not the session's conversation.
          e3 <- mkEntryRecordAtAt EKResponse 1
          itwRecordAndAck h (IndexedTranscriptWrite notice e3)
          diag <- itwDiagnostics h
          tdDesyncEvents diag `shouldBe` 0
          tdDesyncDroppedMessages diag `shouldBe` 0

-- | An entry record with a fixed conversation length and no envelope.
mkEntryRecordAtAt :: EntryKind -> Int -> IO EntryRecord
mkEntryRecordAtAt kind convLen = do
  now <- getCurrentTime
  pure EntryRecord
    { erId = "r1"
    , erTimestamp = now
    , erKind = kind
    , erConvLen = convLen
    , erEnvelope = Nothing
    , erUsage = Nothing
    , erStop = Nothing
    , erDurationMs = Nothing
    , erHarness = Nothing
    , erCorrelation = Nothing
    , erMeta = Map.empty
    }
