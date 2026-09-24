{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.Loop' — the generic chat-channel loop.
-- Tests the pure helper functions (extractEntryText, extractActivityKind,
-- etc.) and the loop's streaming behavior with a mock channel (segment
-- breaks on tool calls, late-update handling after finalize, state reset).
module Seal.Channels.Chat.LoopSpec (spec) where

import Control.Concurrent.STM (newTVarIO)
import Data.IORef
import Data.Aeson ((.=))
import Data.Aeson qualified as A
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Network.HTTP.Client (newManager, defaultManagerSettings)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Seal.Channels.Chat.Class (ChatChannel (..), QuestionOption (..))
import Seal.Channels.Chat.Loop
import Seal.Channels.Chat.RateLimit (defaultStreamProgressConfig)
import Seal.Channels.Chat.Types
  ( ChatMessageId (..)
  , ConversationKey (..)
  , newStreamingState
  , defaultGatewayConfig
  )
import Seal.Channels.Chat.WsClient (WsClient (..))
import Seal.Gateway.Types.Core (SessionId, mkSessionId)
import Seal.Gateway.Types.Stream (ServerEvent (..))

-- | A mock 'ChatChannel' that records every send, sendWithId, and edit.
-- Mirrors the shape used by SignalAdapterSpec but lives here so the
-- generic loop tests have no adapter dependency.
data MockChan = MockChan
  { mcSends    :: IORef [Text]
  , mcSendIds  :: IORef [(Text, Text)]
    -- ^ (content, returned id) pairs, in order.
  , mcEdits    :: IORef [(Text, Text)]
    -- ^ (id, new content) pairs, in order.
  , mcNextId   :: IORef Int
  }

instance ChatChannel MockChan where
  ccReceive _ = pure Nothing
  ccSend ch t = modifyIORef' (mcSends ch) (t :)
  ccSendWithId ch t = do
    n <- readIORef (mcNextId ch)
    writeIORef (mcNextId ch) (n + 1)
    modifyIORef' (mcSendIds ch) ((t, T.pack (show n)) :)
    pure (Just (ChatMessageId (T.pack (show n))))
  ccEditMessage ch (ChatMessageId i) content = do
    modifyIORef' (mcEdits ch) ((i, content) :)
    pure True
  ccLabel _ = "mock"

mkMockChan :: IO MockChan
mkMockChan = MockChan
  <$> newIORef []
  <*> newIORef []
  <*> newIORef []
  <*> newIORef 0

getSends :: MockChan -> IO [Text]
getSends ch = reverse <$> readIORef (mcSends ch)

getSendIds :: MockChan -> IO [Text]
getSendIds ch = map fst . reverse <$> readIORef (mcSendIds ch)

getEdits :: MockChan -> IO [Text]
getEdits ch = map snd . reverse <$> readIORef (mcEdits ch)

-- | A stub WS client (the streaming handlers never use it).
stubWs :: WsClient
stubWs = WsClient
  { wcFocus = \_ -> pure ()
  , wcFocusSince = \_ _ -> pure ()
  , wcClose = pure ()
  }

-- | Build a streaming entry-update / entry JSON payload (same shape the
-- server's streamingEntryJson and recorded entries produce).
streamingJsonFor :: Text -> A.Value
streamingJsonFor t = A.object
  [ "id" .= ("streaming" :: T.Text)
  , "direction" .= ("response" :: T.Text)
  , "payload" .= A.object
      [ "content" .= A.Array
          (V.fromList [A.object ["text" .= t, "type" .= ("text" :: T.Text)]])
      ]
  ]

-- | A recorded response entry payload (the finalize input).
entryJsonFor :: Text -> A.Value
entryJsonFor = streamingJsonFor

-- | A tool-call activity payload.
toolCallJson :: Text -> A.Value
toolCallJson tool = A.object
  [ "kind" .= ("tool-call" :: T.Text)
  , "tool" .= tool
  , "input" .= ("{}" :: T.Text)
  ]

-- | A harness-status activity payload.
statusJson :: Text -> A.Value
statusJson st = A.object
  [ "kind" .= ("harness-status" :: T.Text)
  , "status" .= st
  ]

-- | Helper: make a 'SessionId' for testing (crashes on invalid — test-only).
mkSid :: Text -> SessionId
mkSid t = case mkSessionId t of
  Right s -> s
  Left e -> error ("test mkSid: " <> show e)

-- | The last element of a list (crashes on empty — test-only).
lastOrCrash :: [a] -> a
lastOrCrash = last

spec :: Spec
spec = do
  describe "loop streaming behavior (issue #198 follow-up)" $ do
    it "finalizes the pre-tool bubble when a tool call fires, so post-tool text starts a new message" $ do
      -- Symptom 1: pre-tool text, tool line, and post-tool text were
      -- landing in the same platform message. The loop must finalize
      -- the pre-tool bubble (edit without cursor) when a tool-call
      -- activity fires, then reset ssMsgId so the next entry-update
      -- creates a NEW bubble below the tool line.
      chan <- mkMockChan
      let key = ConversationKey "signal" "conv1"
      mgr <- newManager defaultManagerSettings
      let cfg = (defaultChatChannelConfig mgr defaultGatewayConfig)
                    { cccStreamCfg = defaultStreamProgressConfig }
      ss <- newStreamingState
      conns <- newTVarIO (Map.singleton key (stubWs, ss))
      pendingAsks <- newTVarIO Map.empty
      tabTracker <- newTVarIO Map.empty
      let sid = mkSid "sess1"
          fire t = handleServerEvent cfg chan key conns pendingAsks tabTracker sid
                    (SeEntryUpdate sid (streamingJsonFor t))
      fire "pre-tool text streams in here"
      -- A tool call fires.
      handleServerEvent cfg chan key conns pendingAsks tabTracker sid (SeActivity sid (toolCallJson "SHELL_EXEC"))
      -- Post-tool text streams in.
      handleServerEvent cfg chan key conns pendingAsks tabTracker sid (SeEntryUpdate sid (streamingJsonFor "post-tool text"))
      -- The tool line was sent as its own platform message.
      sends <- getSends chan
      sends `shouldSatisfy` any (T.isInfixOf "SHELL_EXEC")
      -- The post-tool text must NOT be edited into the pre-tool bubble:
      -- the pre-tool bubble was finalized (edit without cursor), and
      -- the post-tool text went to a NEW bubble (a new sendWithId).
      sendIds <- getSendIds chan
      sendIds `shouldSatisfy` any (T.isPrefixOf "post-tool text")
      edits <- getEdits chan
      -- The finalize edit stripped the cursor: no edit content carries
      -- the cursor character.
      edits `shouldSatisfy` not . any (T.isInfixOf "\x2589")

    it "ignores late entry-updates after the response entry finalizes the turn" $ do
      -- Symptom 2: the final message kept streaming in (trailing edits)
      -- because a late SeEntryUpdate could overwrite the finalized text
      -- and re-add the cursor. After the entry finalize, late updates
      -- must be ignored.
      chan <- mkMockChan
      let key = ConversationKey "signal" "conv1"
      mgr <- newManager defaultManagerSettings
      let cfg = (defaultChatChannelConfig mgr defaultGatewayConfig)
                    { cccStreamCfg = defaultStreamProgressConfig }
      ss <- newStreamingState
      conns <- newTVarIO (Map.singleton key (stubWs, ss))
      pendingAsks <- newTVarIO Map.empty
      tabTracker <- newTVarIO Map.empty
      let sid = mkSid "sess2"
          fire t = handleServerEvent cfg chan key conns pendingAsks tabTracker sid
                    (SeEntryUpdate sid (streamingJsonFor t))
      -- Stream some text (creates the bubble), then the final recorded
      -- entry arrives (finalize), then a LATE entry-update arrives.
      fire "partial text"
      handleServerEvent cfg chan key conns pendingAsks tabTracker sid
        (SeEntry sid (entryJsonFor "the complete final text"))
      editsAfterFinalize0 <- getEdits chan
      -- A LATE update arrives with enough NEW codepoints to pass the
      -- rate-limit gate (> 80 new) — the bug lets it overwrite the
      -- finalized text and re-add the cursor. The fix must ignore it
      -- regardless of rate-limit timing.
      fire (T.replicate 200 "z")
      editsAfterFinalize1 <- getEdits chan
      -- The late update produced no additional edits — the finalized
      -- text stands, without the cursor.
      editsAfterFinalize1 `shouldBe` editsAfterFinalize0
      lastEdit <- lastOrCrash <$> getEdits chan
      lastEdit `shouldBe` "the complete final text"

    it "resets all streaming state on idle, so the next turn starts a fresh bubble" $ do
      -- Symptom 3: a stale prefix persisted into the next turn. The
      -- idle activity must reset msgId, accumulated, lastEdit, and
      -- lastLen — and the next turn's first entry-update must create a
      -- NEW bubble rather than editing the old one.
      chan <- mkMockChan
      let key = ConversationKey "signal" "conv1"
      mgr <- newManager defaultManagerSettings
      let cfg = (defaultChatChannelConfig mgr defaultGatewayConfig)
                    { cccStreamCfg = defaultStreamProgressConfig }
      ss <- newStreamingState
      conns <- newTVarIO (Map.singleton key (stubWs, ss))
      pendingAsks <- newTVarIO Map.empty
      tabTracker <- newTVarIO Map.empty
      let sid = mkSid "sess3"
          fire t = handleServerEvent cfg chan key conns pendingAsks tabTracker sid
                    (SeEntryUpdate sid (streamingJsonFor t))
      -- Turn 1: stream + go idle (finalize path).
      fire "turn one text"
      handleServerEvent cfg chan key conns pendingAsks tabTracker sid (SeActivity sid (statusJson "idle"))
      -- Turn 2: fresh text must create a NEW bubble.
      -- (Production sequence: the server broadcasts harness-status
      -- "thinking" at turn start, which clears the finalized flag —
      -- then entry-updates stream. The test mirrors that.)
      handleServerEvent cfg chan key conns pendingAsks tabTracker sid (SeActivity sid (statusJson "thinking"))
      sendIdsBefore <- getSendIds chan
      fire "turn two text"
      sendIdsAfter <- getSendIds chan
      -- The new turn's text became a new sendWithId (new bubble), not
      -- an edit of the old one.
      length sendIdsAfter `shouldBe` length sendIdsBefore + 1
      edits <- getEdits chan
      -- And nothing edited the old bubble with turn-two text.
      edits `shouldSatisfy` not . any (T.isInfixOf "turn two text")

  describe "extractEntryText" $ do
    it "extracts text from a payload with content array" $ do
      let val = A.object
            [ "payload" .= A.object
                [ "content" .= A.Array (V.fromList
                    [ A.object ["text" .= ("hello " :: Text), "type" .= ("text" :: Text)]
                    , A.object ["text" .= ("world" :: Text), "type" .= ("text" :: Text)]
                ])
                ]
            ]
      extractEntryText val `shouldBe` "hello world"

    it "extracts text from a payload with string content" $ do
      let val = A.object
            [ "payload" .= A.object ["content" .= ("just text" :: Text)]
            ]
      extractEntryText val `shouldBe` "just text"

    it "returns empty for missing payload" $ do
      let val = A.object ["other" .= ("stuff" :: Text)]
      extractEntryText val `shouldBe` ""

    it "returns empty for non-object" $ do
      extractEntryText (A.String "not an object") `shouldBe` ""

  describe "extractActivityKind" $ do
    it "extracts the kind field" $ do
      let val = A.object ["kind" .= ("harness-status" :: Text), "status" .= ("idle" :: Text)]
      extractActivityKind val `shouldBe` "harness-status"

    it "returns empty for missing kind" $ do
      let val = A.object ["status" .= ("idle" :: Text)]
      extractActivityKind val `shouldBe` ""

  describe "extractActivityStatus" $ do
    it "extracts the status field" $ do
      let val = A.object ["kind" .= ("harness-status" :: Text), "status" .= ("thinking" :: Text)]
      extractActivityStatus val `shouldBe` "thinking"

    it "returns empty for missing status" $ do
      let val = A.object ["kind" .= ("harness-status" :: Text)]
      extractActivityStatus val `shouldBe` ""

  describe "extractAskQuestion" $ do
    it "extracts the question field" $ do
      let val = A.object ["id" .= ("q1" :: Text), "question" .= ("Do you want to proceed?" :: Text)]
      extractAskQuestion val `shouldBe` "Do you want to proceed?"

    it "returns empty for missing question" $ do
      let val = A.object ["id" .= ("q1" :: Text)]
      extractAskQuestion val `shouldBe` ""

  describe "extractToolName" $ do
    it "extracts the tool field from a tool-call activity" $ do
      let val = A.object ["kind" .= ("tool-call" :: Text), "tool" .= ("SHELL_EXEC" :: Text), "input" .= ("ls" :: Text)]
      extractToolName val `shouldBe` Just "SHELL_EXEC"

    it "returns Nothing when kind is not tool-call" $ do
      let val = A.object ["kind" .= ("harness-status" :: Text), "tool" .= ("SHELL_EXEC" :: Text)]
      extractToolName val `shouldBe` Nothing

    it "returns Nothing when tool field is missing" $ do
      let val = A.object ["kind" .= ("tool-call" :: Text), "input" .= ("ls" :: Text)]
      extractToolName val `shouldBe` Nothing

  describe "extractToolInput" $ do
    it "extracts the input field from a tool-call activity" $ do
      let val = A.object ["kind" .= ("tool-call" :: Text), "tool" .= ("FILE_READ" :: Text), "input" .= ("README.md" :: Text)]
      extractToolInput val `shouldBe` Just "README.md"

    it "returns Nothing when kind is not tool-call" $ do
      let val = A.object ["kind" .= ("harness-status" :: Text), "input" .= ("ls" :: Text)]
      extractToolInput val `shouldBe` Nothing

  describe "lastAssistantText" $ do
    it "extracts the last response entry's text" $ do
      let entries =
            [ A.object ["direction" .= ("request" :: Text), "payload" .= A.object ["content" .= ("hi" :: Text)]]
            , A.object ["direction" .= ("response" :: Text), "payload" .= A.object ["content" .= ("hello!" :: Text)]]
            , A.object ["direction" .= ("request" :: Text), "payload" .= A.object ["content" .= ("bye" :: Text)]]
            ]
      lastAssistantText entries `shouldBe` Just "hello!"

    it "returns Nothing when no response entries" $ do
      let entries =
            [ A.object ["direction" .= ("request" :: Text), "payload" .= A.object ["content" .= ("hi" :: Text)]]
            ]
      lastAssistantText entries `shouldBe` (Nothing :: Maybe Text)

    it "returns Nothing for empty list" $ do
      lastAssistantText [] `shouldBe` (Nothing :: Maybe Text)

  describe "tool call emoji rendering" $ do
    it "sends a tool line with the emoji prefix when a tool-call activity fires" $ do
      chan <- mkMockChan
      let key = ConversationKey "signal" "conv1"
      mgr <- newManager defaultManagerSettings
      let cfg = (defaultChatChannelConfig mgr defaultGatewayConfig)
                    { cccStreamCfg = defaultStreamProgressConfig }
      ss <- newStreamingState
      conns <- newTVarIO (Map.singleton key (stubWs, ss))
      pendingAsks <- newTVarIO Map.empty
      tabTracker <- newTVarIO Map.empty
      let sid = mkSid "emoji-test"
      handleServerEvent cfg chan key conns pendingAsks tabTracker sid
        (SeActivity sid (toolCallJson "SHELL_EXEC"))
      sends <- getSends chan
      sends `shouldSatisfy` any (T.isInfixOf "\x1F4BB")
      sends `shouldSatisfy` any (T.isInfixOf "SHELL_EXEC")

    it "sends a tool line with the gear emoji for BIN_EXEC" $ do
      chan <- mkMockChan
      let key = ConversationKey "signal" "conv1"
      mgr <- newManager defaultManagerSettings
      let cfg = (defaultChatChannelConfig mgr defaultGatewayConfig)
                    { cccStreamCfg = defaultStreamProgressConfig }
      ss <- newStreamingState
      conns <- newTVarIO (Map.singleton key (stubWs, ss))
      pendingAsks <- newTVarIO Map.empty
      tabTracker <- newTVarIO Map.empty
      let sid = mkSid "emoji-test2"
      handleServerEvent cfg chan key conns pendingAsks tabTracker sid
        (SeActivity sid (toolCallJson "BIN_EXEC"))
      sends <- getSends chan
      sends `shouldSatisfy` any (T.isInfixOf "\x2699\xFE0F")

    it "sends a tool line with the brain emoji for MEMORY_MANAGE" $ do
      chan <- mkMockChan
      let key = ConversationKey "signal" "conv1"
      mgr <- newManager defaultManagerSettings
      let cfg = (defaultChatChannelConfig mgr defaultGatewayConfig)
                    { cccStreamCfg = defaultStreamProgressConfig }
      ss <- newStreamingState
      conns <- newTVarIO (Map.singleton key (stubWs, ss))
      pendingAsks <- newTVarIO Map.empty
      tabTracker <- newTVarIO Map.empty
      let sid = mkSid "emoji-test3"
      handleServerEvent cfg chan key conns pendingAsks tabTracker sid
        (SeActivity sid (toolCallJson "MEMORY_MANAGE"))
      sends <- getSends chan
      sends `shouldSatisfy` any (T.isInfixOf "\x1F9E0")

  describe "parseCallbackData" $ do
    it "parses a valid callback_data string" $ do
      parseCallbackData "abcdef12:0" `shouldBe` Just ("abcdef12", 0)
      parseCallbackData "a1b2c3d4:3" `shouldBe` Just ("a1b2c3d4", 3)

    it "returns Nothing for invalid prefix length" $ do
      parseCallbackData "abc:0" `shouldBe` Nothing
      parseCallbackData "abcdefgh:0" `shouldBe` Nothing

    it "returns Nothing for invalid format" $ do
      parseCallbackData "abcdef12" `shouldBe` Nothing
      parseCallbackData "abcdef12:abc" `shouldBe` Nothing
      parseCallbackData "abcdef12:-1" `shouldBe` Nothing

  describe "extractAskId" $ do
    it "extracts the id field from an ask event payload" $ do
      let val = A.object ["id" .= ("q123" :: Text), "question" .= ("hello?" :: Text)]
      extractAskId val `shouldBe` "q123"

    it "returns empty for missing id" $ do
      let val = A.object ["question" .= ("hello?" :: Text)]
      extractAskId val `shouldBe` ""

  describe "extractAskOptions" $ do
    it "extracts options with label and description" $ do
      let val = A.object
            [ "options" .= A.Array (V.fromList
              [ A.object ["label" .= ("yes" :: Text), "description" .= ("proceed" :: Text)]
              , A.object ["label" .= ("no" :: Text), "description" .= ("" :: Text)]
              ])
            ]
      extractAskOptions val `shouldBe`
        [ QuestionOption "yes" "proceed"
        , QuestionOption "no" ""
        ]

    it "returns empty list for missing options" $ do
      let val = A.object ["question" .= ("hello?" :: Text)]
      extractAskOptions val `shouldBe` []

  describe "formatQuestionWithOptions" $ do
    it "formats a question with options as a numbered list" $ do
      formatQuestionWithOptions "Which?" [QuestionOption "yes" "proceed", QuestionOption "no" ""]
        `shouldBe` "Which?\n\n1) yes \8212 proceed\n2) no\n\nReply with a number or type your own answer."

    it "returns just the question when no options" $ do
      formatQuestionWithOptions "Hello?" [] `shouldBe` "Hello?"
