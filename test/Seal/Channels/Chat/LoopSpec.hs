{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.Loop' — the generic chat-channel loop.
-- Tests the pure helper functions (extractEntryText, extractActivityKind,
-- etc.) and the loop's streaming behavior with a mock channel (segment
-- breaks on tool calls, late-update handling after finalize, state reset).
module Seal.Channels.Chat.LoopSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, withAsync)
import Control.Concurrent.STM (newTVarIO, readTVarIO, TVar)
import Data.IORef
import Data.Aeson ((.=))
import Data.Aeson qualified as A
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Network.HTTP.Client (Manager, newManager, defaultManagerSettings)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy, expectationFailure)

import Seal.Channels.Chat.Class (ChatChannel (..), QuestionOption (..))
import Seal.Channels.Chat.Loop
import Seal.Channels.Chat.HttpClient
  ( ListsJson (..), NewSessionResult (..), SendResult (..), TabJson (..) )
import Seal.Channels.Chat.RateLimit (defaultStreamProgressConfig)
import Seal.Channels.Chat.Types
  ( ChatMessageId (..)
  , ConversationKey (..)
  , newSessionMap
  , newStreamingState
  , defaultGatewayConfig
  , sessionInsert
  , sessionLookup
  )
import Seal.Channels.Chat.WsClient (WsClient (..), WsEventCallback)
import Seal.Gateway.Types.ChannelKind (ChannelKind (..))
import Seal.Gateway.Types.Core (SessionId, mkSessionId, sessionIdText)
import Seal.Gateway.Types.MessageSource
  ( MessageSource, mkConversationId, mkMessageSource )
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
  , mcWithOpts :: IORef [(Text, [Text])]
    -- ^ (question, option labels) pairs passed to 'ccSendWithOptions', in
    -- order.
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
  ccSendWithOptions ch question opts _prefix = do
    modifyIORef' (mcWithOpts ch) ((question, map qoLabel opts) :)
    pure (Just (ChatMessageId "with-options"))
  ccLabel _ = "mock"

mkMockChan :: IO MockChan
mkMockChan = MockChan
  <$> newIORef []
  <*> newIORef []
  <*> newIORef []
  <*> newIORef []
  <*> newIORef 0

getSends :: MockChan -> IO [Text]
getSends ch = reverse <$> readIORef (mcSends ch)

getSendIds :: MockChan -> IO [Text]
getSendIds ch = map fst . reverse <$> readIORef (mcSendIds ch)

getEdits :: MockChan -> IO [Text]
getEdits ch = map snd . reverse <$> readIORef (mcEdits ch)

-- | The (question, option labels) pairs handed to 'ccSendWithOptions'.
getWithOptions :: MockChan -> IO [(Text, [Text])]
getWithOptions ch = reverse <$> readIORef (mcWithOpts ch)


-- | Everything the loop posted on the channel — plain sends and
-- id-returning sends (the reply path uses 'ccSendWithId').
getAllSent :: MockChan -> IO [Text]
getAllSent ch = (++) <$> getSends ch <*> getSendIds ch
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

-- ---------------------------------------------------------------------------
-- /bg (background session) scaffolding
-- ---------------------------------------------------------------------------

-- | A 'WsClient' stub that records the sessions it was asked to focus and
-- how many times it was closed. Used for both the conversation's own
-- connection (where \"no focus\" is the observable) and a bg session's
-- dedicated connection.
data WsRecorder = WsRecorder
  { wrFocused :: IORef [SessionId]
  , wrCloses  :: IORef Int
  }

mkWsRecorder :: IO WsRecorder
mkWsRecorder = WsRecorder <$> newIORef [] <*> newIORef 0

recorderClient :: WsRecorder -> WsClient
recorderClient r = WsClient
  { wcFocus = \sid -> modifyIORef' (wrFocused r) (sid :)
  , wcFocusSince = \sid _ -> modifyIORef' (wrFocused r) (sid :)
  , wcClose = modifyIORef' (wrCloses r) (+ 1)
  }

getFocused :: WsRecorder -> IO [SessionId]
getFocused = fmap reverse . readIORef . wrFocused

getCloses :: WsRecorder -> IO Int
getCloses = readIORef . wrCloses

-- | The recorded calls into a stub config's gateway seams, plus the canned
-- results each seam returns (popped from a queue, so a test can script
-- mint / connect / send outcomes in call order).
data Seams = Seams
  { smMints     :: IORef [A.Value]
    -- ^ Bodies passed to the mint seam, in call order.
  , smRebinds   :: IORef [(SessionId, A.Value)]
    -- ^ (old session, body) pairs passed to the rebind seam, in call order.
  , smRepoSetups :: IORef [(SessionId, A.Value)]
    -- ^ (session, body) pairs passed to the setup-repo seam, in call order.
  , smSends     :: IORef [(SessionId, Text)]
    -- ^ (session, prompt) pairs passed to the send seam, in call order.
  , smCallbacks :: IORef [WsEventCallback]
    -- ^ The event callbacks handed to the WS seam, in call order.
  , smRecorders :: IORef [WsRecorder]
    -- ^ The WS clients handed back by the WS seam, in call order.
  , smMintQueue :: IORef [Either Text Text]
    -- ^ Queued mint results; an empty queue yields a mint failure.
  , smRebindQueue :: IORef [Either Text NewSessionResult]
    -- ^ Queued rebind results; an empty queue yields a rebind failure.
  , smRepoSetupQueue :: IORef [Either Text ()]
    -- ^ Queued setup-repo results; an empty queue yields success.
  , smReposQueue :: IORef [Either Text [A.Value]]
    -- ^ Queued @GET \/api\/repos@ results; an empty queue yields @[]@.
  , smSendQueue :: IORef [Either Text SendResult]
    -- ^ Queued send results; an empty queue yields a successful send.
  , smWsQueue   :: IORef [Either Text WsRecorder]
    -- ^ Queued connect results; an empty queue yields a fresh recorder.
  , smAnswers   :: IORef [(SessionId, Text, Text)]
    -- ^ (session, ask id, answer) triples passed to the answer seam.
  , smAnswerQueue :: IORef [Either Text Bool]
    -- ^ Queued answer results (Right False = already resolved); an empty
    -- queue yields an accepted answer.
  }

mkSeams :: IO Seams
mkSeams = Seams
  <$> newIORef [] <*> newIORef [] <*> newIORef [] <*> newIORef []
  <*> newIORef [] <*> newIORef [] <*> newIORef []
  <*> newIORef [] <*> newIORef [] <*> newIORef [] <*> newIORef []
  <*> newIORef [] <*> newIORef [] <*> newIORef []

-- | Pop the next queued result, falling back to a default when the queue is
-- empty.
nextQueued :: IORef [a] -> a -> IO a
nextQueued ref dflt = do
  queued <- readIORef ref
  case queued of
    (x : rest) -> writeIORef ref rest >> pure x
    []         -> pure dflt

-- | A successful @POST /send@ result (the reply arrives over WS).
okSendResult :: SendResult
okSendResult = SendResult
  { srKind = "assistant"
  , srResponse = ""
  , srSessionId = Nothing
  , srError = Nothing
  }

-- | A 'ChatChannelConfig' whose gateway seams are stubbed: every call is
-- recorded in the 'Seams', and the result comes from the corresponding
-- queue.
stubCfg :: Manager -> Seams -> ChatChannelConfig
stubCfg mgr seams = (defaultChatChannelConfig mgr defaultGatewayConfig)
  { cccNewSession = \_mgr _apiBase body -> do
      modifyIORef' (smMints seams) (body :)
      nextQueued (smMintQueue seams) (Left "no session minted for this test")
  , cccRebindNew = \_mgr _apiBase oldSid body -> do
      modifyIORef' (smRebinds seams) ((oldSid, body) :)
      nextQueued (smRebindQueue seams) (Left "no rebind queued for this test")
  , cccSetupRepo = \_mgr _apiBase sid body -> do
      modifyIORef' (smRepoSetups seams) ((sid, body) :)
      nextQueued (smRepoSetupQueue seams) (Right ())
  , cccGetRepos = \_mgr _apiBase ->
      nextQueued (smReposQueue seams) (Right [])
  , cccSendMessage = \_mgr _apiBase sid prompt -> do
      modifyIORef' (smSends seams) ((sid, prompt) :)
      nextQueued (smSendQueue seams) (Right okSendResult)
  , cccStartWs = \_host _port cb -> do
      modifyIORef' (smCallbacks seams) (cb :)
      queued <- readIORef (smWsQueue seams)
      case queued of
        (Left e : rest) -> do
          writeIORef (smWsQueue seams) rest
          pure (Left e)
        (Right rec : rest) -> do
          writeIORef (smWsQueue seams) rest
          modifyIORef' (smRecorders seams) (rec :)
          pure (Right (recorderClient rec))
        [] -> do
          rec <- mkWsRecorder
          modifyIORef' (smRecorders seams) (rec :)
          pure (Right (recorderClient rec))
  , cccAnswerQuestion = \_mgr _apiBase sid askId answer -> do
      modifyIORef' (smAnswers seams) ((sid, askId, answer) :)
      nextQueued (smAnswerQueue seams) (Right True)
  }

getMints :: Seams -> IO [A.Value]
getMints = fmap reverse . readIORef . smMints

-- | The rebind-seam calls recorded so far, in order.
getRebinds :: Seams -> IO [(SessionId, A.Value)]
getRebinds = fmap reverse . readIORef . smRebinds

-- | The setup-repo-seam calls recorded so far, in order.
getRepoSetups :: Seams -> IO [(SessionId, A.Value)]
getRepoSetups = fmap reverse . readIORef . smRepoSetups

-- | Queue rebind results, in call order.
queueRebinds :: Seams -> [Either Text NewSessionResult] -> IO ()
queueRebinds seams = writeIORef (smRebindQueue seams)

-- | A successful rebind result with the given session id + provider/model.
rebindOk :: Text -> Text -> Text -> NewSessionResult
rebindOk sid prov model = NewSessionResult
  { nsrSessionId   = sid
  , nsrTabIndex    = Just 0
  , nsrRebound     = True
  , nsrRebindError = Nothing
  , nsrProvider    = prov
  , nsrModel       = model
  }

-- | Make the setup-repo seam fail.
queueRepoSetupFailure :: Seams -> Text -> IO ()
queueRepoSetupFailure seams e = writeIORef (smRepoSetupQueue seams) [Left e]

-- | Queue the @GET \/api\/repos@ results, in call order.
queueRepos :: Seams -> [Either Text [A.Value]] -> IO ()
queueRepos seams = writeIORef (smReposQueue seams)

getSendCalls :: Seams -> IO [(SessionId, Text)]
getSendCalls = fmap reverse . readIORef . smSends

getCallbacks :: Seams -> IO [WsEventCallback]
getCallbacks = fmap reverse . readIORef . smCallbacks

getRecorders :: Seams -> IO [WsRecorder]
getRecorders = fmap reverse . readIORef . smRecorders

-- | A 'MessageSource' for a conversation id. The callback handler ignores
-- it (callback taps carry no message body), but its signature needs one.
mkSourceFor :: Text -> MessageSource
mkSourceFor cid =
  case mkConversationId cid of
    Left _   -> error "mkSourceFor: bad conversation id"
    Right c  -> case mkMessageSource c Signal Nothing Map.empty of
      Left _   -> error "mkSourceFor: MessageSource construction failed"
      Right ms -> ms

-- | The answer-seam calls recorded so far, in order.
getAnswers :: Seams -> IO [(SessionId, Text, Text)]
getAnswers = fmap reverse . readIORef . smAnswers

-- | Make the answer seam fail.
queueAnswerFailure :: Seams -> Text -> IO ()
queueAnswerFailure seams e = writeIORef (smAnswerQueue seams) [Left e]

-- | Make the answer seam report "already resolved" (200 accepted:false).
queueAnswerNotAccepted :: Seams -> IO ()
queueAnswerNotAccepted seams = writeIORef (smAnswerQueue seams) [Right False]

-- | Queue the session ids the mint seam returns, in call order.
queueMints :: Seams -> [Text] -> IO ()
queueMints seams = writeIORef (smMintQueue seams) . map Right

-- | Make the mint seam fail.
queueMintFailure :: Seams -> Text -> IO ()
queueMintFailure seams e = writeIORef (smMintQueue seams) [Left e]

-- | Queue the WS clients the connect seam returns, in call order.

-- | Make the connect seam fail.
queueConnectFailure :: Seams -> Text -> IO ()
queueConnectFailure seams e = writeIORef (smWsQueue seams) [Left e]

-- | Make the send seam fail.
queueSendFailure :: Seams -> Text -> IO ()
queueSendFailure seams e = writeIORef (smSendQueue seams) [Left e]

-- | A recorded response entry for the given text (the bg reply).
bgReplyJson :: Text -> A.Value
bgReplyJson = entryJsonFor

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
      conns <- newTVarIO (Map.singleton key (mkSid "conn-sid", stubWs, ss))
      pendingAsks <- newPendingAsks
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      bg <- newBgSessions
      let sid = mkSid "sess1"
          fire t = handleServerEvent cfg chan key conns pendingAsks bg tabTracker watchState thinkingTabs sid
                    (SeEntryUpdate sid (streamingJsonFor t))
      fire "pre-tool text streams in here"
      -- A tool call fires.
      handleServerEvent cfg chan key conns pendingAsks bg tabTracker watchState thinkingTabs sid (SeActivity sid (toolCallJson "SHELL_EXEC"))
      -- Post-tool text streams in.
      handleServerEvent cfg chan key conns pendingAsks bg tabTracker watchState thinkingTabs sid (SeEntryUpdate sid (streamingJsonFor "post-tool text"))
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
      conns <- newTVarIO (Map.singleton key (mkSid "conn-sid", stubWs, ss))
      pendingAsks <- newPendingAsks
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      bg <- newBgSessions
      let sid = mkSid "sess2"
          fire t = handleServerEvent cfg chan key conns pendingAsks bg tabTracker watchState thinkingTabs sid
                    (SeEntryUpdate sid (streamingJsonFor t))
      -- Stream some text (creates the bubble), then the final recorded
      -- entry arrives (finalize), then a LATE entry-update arrives.
      fire "partial text"
      handleServerEvent cfg chan key conns pendingAsks bg tabTracker watchState thinkingTabs sid
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
      conns <- newTVarIO (Map.singleton key (mkSid "conn-sid", stubWs, ss))
      pendingAsks <- newPendingAsks
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      bg <- newBgSessions
      let sid = mkSid "sess3"
          fire t = handleServerEvent cfg chan key conns pendingAsks bg tabTracker watchState thinkingTabs sid
                    (SeEntryUpdate sid (streamingJsonFor t))
      -- Turn 1: stream + go idle (finalize path).
      fire "turn one text"
      handleServerEvent cfg chan key conns pendingAsks bg tabTracker watchState thinkingTabs sid (SeActivity sid (statusJson "idle"))
      -- Turn 2: fresh text must create a NEW bubble.
      -- (Production sequence: the server broadcasts harness-status
      -- "thinking" at turn start, which clears the finalized flag —
      -- then entry-updates stream. The test mirrors that.)
      handleServerEvent cfg chan key conns pendingAsks bg tabTracker watchState thinkingTabs sid (SeActivity sid (statusJson "thinking"))
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


  describe "extractThinkingSessionIds" $ do
    it "extracts valid session IDs from the thinkingSessionIds array" $ do
      let val = A.object
            [ "type" .= ("lists" :: Text)
            , "thinkingSessionIds" .= ["abc-123" :: Text, "def-456" :: Text]
            ]
      extractThinkingSessionIds val `shouldBe` [mkSid "abc-123", mkSid "def-456"]

    it "returns empty list when thinkingSessionIds is missing" $ do
      let val = A.object ["type" .= ("lists" :: Text)]
      extractThinkingSessionIds val `shouldBe` []

    it "filters out invalid session IDs" $ do
      let val = A.object
            [ "thinkingSessionIds" .= ["valid-id" :: Text, ".invalid" :: Text]
            ]
      extractThinkingSessionIds val `shouldBe` [mkSid "valid-id"]

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
      conns <- newTVarIO (Map.singleton key (mkSid "conn-sid", stubWs, ss))
      pendingAsks <- newPendingAsks
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      bg <- newBgSessions
      let sid = mkSid "emoji-test"
      handleServerEvent cfg chan key conns pendingAsks bg tabTracker watchState thinkingTabs sid
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
      conns <- newTVarIO (Map.singleton key (mkSid "conn-sid", stubWs, ss))
      pendingAsks <- newPendingAsks
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      bg <- newBgSessions
      let sid = mkSid "emoji-test2"
      handleServerEvent cfg chan key conns pendingAsks bg tabTracker watchState thinkingTabs sid
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
      conns <- newTVarIO (Map.singleton key (mkSid "conn-sid", stubWs, ss))
      pendingAsks <- newPendingAsks
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      bg <- newBgSessions
      let sid = mkSid "emoji-test3"
      handleServerEvent cfg chan key conns pendingAsks bg tabTracker watchState thinkingTabs sid
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
  describe "handleInbound inject behavior" $ do
    -- When the user sends "/N payload" (ChatInject), the message should
    -- be sent to tab N's session WITHOUT changing the focused tab. The
    -- key observable: the channel must NOT receive "focused tab N" (or
    -- any "focus failed" message) — handleFocus is not called at all.
    -- These tests run without a live gateway, so HTTP calls fail; the
    -- assertion is that no focus-related message is produced.
    let injectKey = ConversationKey "test" "conv-inject"

    it "does not send 'focused tab' when processing /N payload (ChatInject)" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      let cfg = defaultChatChannelConfig mgr defaultGatewayConfig
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty :: IO (TVar (Map ConversationKey WsConn))
      pendingAsks <- newPendingAsks
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      bg <- newBgSessions
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker watchState thinkingTabs injectKey "/6 hello world"
      sends <- getSends chan
      sends `shouldSatisfy` not . any ("focused tab" `T.isInfixOf`)

    it "does not send 'focus failed' when processing /N payload (ChatInject)" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      let cfg = defaultChatChannelConfig mgr defaultGatewayConfig
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty :: IO (TVar (Map ConversationKey WsConn))
      pendingAsks <- newPendingAsks
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      bg <- newBgSessions
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker watchState thinkingTabs injectKey "/6 hello world"
      sends <- getSends chan
      sends `shouldSatisfy` not . any ("focus" `T.isInfixOf`)

    it "does send 'focus failed' when processing /N without payload (ChatFocus)" $ do
      -- Sanity check: bare /N (ChatFocus) still produces a focus-related
      -- message (it fails because no gateway is running, but the
      -- "focus failed" message proves handleFocus was called).
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      let cfg = defaultChatChannelConfig mgr defaultGatewayConfig
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty :: IO (TVar (Map ConversationKey WsConn))
      pendingAsks <- newPendingAsks
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      bg <- newBgSessions
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker watchState thinkingTabs injectKey "/6"
      sends <- getSends chan
      sends `shouldSatisfy` any ("focus" `T.isInfixOf`)
  describe "watch-all-tabs" $ do
    it "/watch toggles watch mode on and sends a confirmation" $ do
      chan <- mkMockChan
      watchState <- newWatchState
      let key = ConversationKey "signal" "conv1"
      handleWatchToggle chan watchState key "/watch"
      sends <- getSends chan
      sends `shouldSatisfy` any (T.isInfixOf "watch mode enabled")
      watchOn <- lookupWatch watchState key
      watchOn `shouldBe` True

    it "/watch toggles watch mode off when already on" $ do
      chan <- mkMockChan
      watchState <- newWatchState
      let key = ConversationKey "signal" "conv1"
      handleWatchToggle chan watchState key "/watch"
      _ <- getSends chan
      handleWatchToggle chan watchState key "/watch"
      sends <- getSends chan
      sends `shouldSatisfy` any (T.isInfixOf "watch mode disabled")
      watchOn <- lookupWatch watchState key
      watchOn `shouldBe` False

    it "/watch on sets watch mode explicitly" $ do
      chan <- mkMockChan
      watchState <- newWatchState
      let key = ConversationKey "signal" "conv1"
      handleWatchToggle chan watchState key "/watch on"
      sends <- getSends chan
      sends `shouldSatisfy` any (T.isInfixOf "watch mode enabled")
      watchOn <- lookupWatch watchState key
      watchOn `shouldBe` True

    it "/watch off disables watch mode explicitly" $ do
      chan <- mkMockChan
      watchState <- newWatchState
      let key = ConversationKey "signal" "conv1"
      handleWatchToggle chan watchState key "/watch on"
      _ <- getSends chan
      handleWatchToggle chan watchState key "/watch off"
      sends <- getSends chan
      sends `shouldSatisfy` any (T.isInfixOf "watch mode disabled")
      watchOn <- lookupWatch watchState key
      watchOn `shouldBe` False

    it "/watch status shows 'off' when watch is disabled" $ do
      chan <- mkMockChan
      watchState <- newWatchState
      let key = ConversationKey "signal" "conv1"
      handleWatchToggle chan watchState key "/watch status"
      sends <- getSends chan
      sends `shouldSatisfy` any (T.isInfixOf "off")
      watchOn <- lookupWatch watchState key
      watchOn `shouldBe` False

    it "/watch status shows 'on' when watch is enabled" $ do
      chan <- mkMockChan
      watchState <- newWatchState
      let key = ConversationKey "signal" "conv1"
      handleWatchToggle chan watchState key "/watch on"
      _ <- getSends chan
      handleWatchToggle chan watchState key "/watch status"
      sends <- getSends chan
      sends `shouldSatisfy` any (T.isInfixOf "on")
      watchOn <- lookupWatch watchState key
      watchOn `shouldBe` True

    it "/watch -h prints help and does not change state" $ do
      chan <- mkMockChan
      watchState <- newWatchState
      let key = ConversationKey "signal" "conv1"
      handleWatchToggle chan watchState key "/watch -h"
      sends <- getSends chan
      sends `shouldSatisfy` any (T.isInfixOf "on")
      sends `shouldSatisfy` any (T.isInfixOf "off")
      sends `shouldSatisfy` any (T.isInfixOf "status")
      sends `shouldSatisfy` any (T.isInfixOf "/watch")
      watchOn <- lookupWatch watchState key
      watchOn `shouldBe` False

    it "watch is per-conversation — toggling one does not affect another" $ do
      chan <- mkMockChan
      watchState <- newWatchState
      let key1 = ConversationKey "signal" "conv1"
          key2 = ConversationKey "signal" "conv2"
      handleWatchToggle chan watchState key1 "/watch"
      _ <- getSends chan
      watchOn1 <- lookupWatch watchState key1
      watchOn2 <- lookupWatch watchState key2
      watchOn1 `shouldBe` True
      watchOn2 `shouldBe` False

    it "persist calls are serialized — no stale-snapshot overwrite race" $ do
      -- A save function that tracks concurrent executions. Without a
      -- mutation+persist lock, two concurrent toggleWatch calls can have
      -- overlapping save invocations, and a stale snapshot (taken before
      -- the other thread's mutation) can overwrite the newer on-disk
      -- state — the "watch flag spontaneously changes from on to off"
      -- bug. With the lock, saves are serialized and each save reflects
      -- the latest in-memory state.
      activeSaves   <- newIORef (0 :: Int)
      maxConcurrent <- newIORef (0 :: Int)
      savedMaps     <- newIORef ([] :: [Map ConversationKey Bool])
      let saveFn m = do
            cur <- atomicModifyIORef' activeSaves (\n -> (n + 1, n + 1))
            atomicModifyIORef' maxConcurrent (\m' -> (max m' cur, ()))
            threadDelay 10000  -- 10 ms — widen the race window
            modifyIORef' savedMaps (m :)
            atomicModifyIORef' activeSaves (\n -> (n - 1, ()))
      watchState <- newPersistingWatchState saveFn
      let key1 = ConversationKey "signal" "conv1"
          key2 = ConversationKey "signal" "conv2"
      withAsync (toggleWatch watchState key1) $ \a1 ->
        withAsync (toggleWatch watchState key2) $ \a2 -> do
          _ <- wait a1
          _ <- wait a2
          pure ()
      maxC <- readIORef maxConcurrent
      maxC `shouldBe` 1  -- saves never overlap
      saves <- readIORef savedMaps
      case saves of
        (m:_) -> Map.size m `shouldBe` 2
        []    -> expectationFailure "expected at least one save"

    it "non-focused session thinking then idle sends a notification when watch is on" $ do
      chan <- mkMockChan
      let key = ConversationKey "signal" "conv1"
      mgr <- newManager defaultManagerSettings
      let cfg = defaultChatChannelConfig mgr defaultGatewayConfig
      ss <- newStreamingState
      conns <- newTVarIO (Map.singleton key (mkSid "conn-sid", stubWs, ss))
      pendingAsks <- newPendingAsks
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      bg <- newBgSessions
      let focusedSid = mkSid "focused"
          otherSid = mkSid "other"
      handleWatchToggle chan watchState key "/watch on"
      _ <- getSends chan
      handleServerEvent cfg chan key conns pendingAsks bg tabTracker
        watchState thinkingTabs focusedSid
        (SeActivity otherSid (statusJson "thinking"))
      handleServerEvent cfg chan key conns pendingAsks bg tabTracker
        watchState thinkingTabs focusedSid
        (SeActivity otherSid (statusJson "idle"))
      sends <- getSends chan
      sends `shouldSatisfy` any (T.isInfixOf "finished thinking")

    it "non-focused session idle does NOT send a notification when watch is off" $ do
      chan <- mkMockChan
      let key = ConversationKey "signal" "conv1"
      mgr <- newManager defaultManagerSettings
      let cfg = defaultChatChannelConfig mgr defaultGatewayConfig
      ss <- newStreamingState
      conns <- newTVarIO (Map.singleton key (mkSid "conn-sid", stubWs, ss))
      pendingAsks <- newPendingAsks
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      bg <- newBgSessions
      let focusedSid = mkSid "focused"
          otherSid = mkSid "other"
      handleServerEvent cfg chan key conns pendingAsks bg tabTracker
        watchState thinkingTabs focusedSid
        (SeActivity otherSid (statusJson "thinking"))
      handleServerEvent cfg chan key conns pendingAsks bg tabTracker
        watchState thinkingTabs focusedSid
        (SeActivity otherSid (statusJson "idle"))
      sends <- getSends chan
      sends `shouldSatisfy` not . any (T.isInfixOf "finished thinking")

    it "non-focused session idle without prior thinking does NOT notify" $ do
      chan <- mkMockChan
      let key = ConversationKey "signal" "conv1"
      mgr <- newManager defaultManagerSettings
      let cfg = defaultChatChannelConfig mgr defaultGatewayConfig
      ss <- newStreamingState
      conns <- newTVarIO (Map.singleton key (mkSid "conn-sid", stubWs, ss))
      pendingAsks <- newPendingAsks
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      bg <- newBgSessions
      let focusedSid = mkSid "focused"
          otherSid = mkSid "other"
      handleWatchToggle chan watchState key "/watch on"
      _ <- getSends chan
      handleServerEvent cfg chan key conns pendingAsks bg tabTracker
        watchState thinkingTabs focusedSid
        (SeActivity otherSid (statusJson "idle"))
      sends <- getSends chan
      sends `shouldSatisfy` not . any (T.isInfixOf "finished thinking")

    it "non-focused session thinking adds to the thinking set when watch is on" $ do
      chan <- mkMockChan
      let key = ConversationKey "signal" "conv1"
      mgr <- newManager defaultManagerSettings
      let cfg = defaultChatChannelConfig mgr defaultGatewayConfig
      ss <- newStreamingState
      conns <- newTVarIO (Map.singleton key (mkSid "conn-sid", stubWs, ss))
      pendingAsks <- newPendingAsks
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      bg <- newBgSessions
      let focusedSid = mkSid "focused"
          otherSid = mkSid "other"
      handleWatchToggle chan watchState key "/watch on"
      _ <- getSends chan
      handleServerEvent cfg chan key conns pendingAsks bg tabTracker
        watchState thinkingTabs focusedSid
        (SeActivity otherSid (statusJson "thinking"))
      thinkingMap <- readTVarIO thinkingTabs
      case Map.lookup key thinkingMap of
        Just sids -> otherSid `shouldSatisfy` (`Set.member` sids)
        Nothing   -> expectationFailure "expected thinking set to contain the session"

    it "non-focused session tool-call activity does NOT trigger a notification" $ do
      chan <- mkMockChan
      let key = ConversationKey "signal" "conv1"
      mgr <- newManager defaultManagerSettings
      let cfg = defaultChatChannelConfig mgr defaultGatewayConfig
      ss <- newStreamingState
      conns <- newTVarIO (Map.singleton key (mkSid "conn-sid", stubWs, ss))
      pendingAsks <- newPendingAsks
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      bg <- newBgSessions
      let focusedSid = mkSid "focused"
          otherSid = mkSid "other"
      handleWatchToggle chan watchState key "/watch on"
      _ <- getSends chan
      handleServerEvent cfg chan key conns pendingAsks bg tabTracker
        watchState thinkingTabs focusedSid
        (SeActivity otherSid (toolCallJson "SHELL_EXEC"))
      sends <- getSends chan
      sends `shouldSatisfy` not . any (T.isInfixOf "finished thinking")

    it "SeLists seeds thinking tabs from snapshot — idle after lists notifies" $ do
      -- The core fix: when a SeLists event arrives (e.g. on WS connect),
      -- the thinkingSessionIds from the snapshot seed the ThinkingTabs
      -- set. This means tabs that were already thinking BEFORE the WS
      -- connection was established will still trigger a notification when
      -- they finish (idle event arrives, wasThinking is true).
      chan <- mkMockChan
      let key = ConversationKey "signal" "conv1"
      mgr <- newManager defaultManagerSettings
      let cfg = defaultChatChannelConfig mgr defaultGatewayConfig
      ss <- newStreamingState
      conns <- newTVarIO (Map.singleton key (mkSid "conn-sid", stubWs, ss))
      pendingAsks <- newPendingAsks
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      bg <- newBgSessions
      let focusedSid = mkSid "focused"
          otherSid = mkSid "other"
          listsVal = A.object
            [ "type" .= ("lists" :: T.Text)
            , "thinkingSessionIds" .= [sessionIdText otherSid]
            ]
      handleWatchToggle chan watchState key "/watch on"
      _ <- getSends chan
      -- Simulate the SeLists event arriving on WS connect (no prior
      -- thinking event was received — the turn started before WS connect).
      handleServerEvent cfg chan key conns pendingAsks bg tabTracker
        watchState thinkingTabs focusedSid
        (SeLists listsVal)
      -- Now the idle event arrives — should notify because the thinking
      -- set was seeded from the lists snapshot.
      handleServerEvent cfg chan key conns pendingAsks bg tabTracker
        watchState thinkingTabs focusedSid
        (SeActivity otherSid (statusJson "idle"))
      sends <- getSends chan
      sends `shouldSatisfy` any (T.isInfixOf "finished thinking")

    it "SeLists without thinkingSessionIds does not seed thinking tabs" $ do
      chan <- mkMockChan
      let key = ConversationKey "signal" "conv1"
      mgr <- newManager defaultManagerSettings
      let cfg = defaultChatChannelConfig mgr defaultGatewayConfig
      ss <- newStreamingState
      conns <- newTVarIO (Map.singleton key (mkSid "conn-sid", stubWs, ss))
      pendingAsks <- newPendingAsks
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      bg <- newBgSessions
      let focusedSid = mkSid "focused"
          otherSid = mkSid "other"
          listsVal = A.object
            [ "type" .= ("lists" :: T.Text)
            , "thinkingSessionIds" .= ([] :: [T.Text])
            ]
      handleWatchToggle chan watchState key "/watch on"
      _ <- getSends chan
      handleServerEvent cfg chan key conns pendingAsks bg tabTracker
        watchState thinkingTabs focusedSid
        (SeLists listsVal)
      handleServerEvent cfg chan key conns pendingAsks bg tabTracker
        watchState thinkingTabs focusedSid
        (SeActivity otherSid (statusJson "idle"))
      sends <- getSends chan
      sends `shouldSatisfy` not . any (T.isInfixOf "finished thinking")

  describe "/bg (background sessions)" $ do
    let bgKey = ConversationKey "signal" "conv-bg"
        convSid = mkSid "conversation-session"
        bgSid1 = mkSid "bgsid-1"
        bgSid2 = mkSid "bgsid-2"

    it "answers a bare /bg with usage and creates nothing" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg"
      getSends chan `shouldReturn` ["usage: /bg <prompt>"]
      getMints seams `shouldReturn` []
      getSendCalls seams `shouldReturn` []
      recs <- getRecorders seams
      length recs `shouldBe` 0

    it "answers /bg -h with the command help and creates nothing" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg -h"
      sends <- getSends chan
      -- The help text is distinguishable from the usage line: it explains
      -- the headless contract (the usage line alone would satisfy a
      -- "/bg <prompt>" infix assertion).
      T.concat sends `shouldSatisfy` T.isInfixOf "The background session is created headless"
      getMints seams `shouldReturn` []
      getSendCalls seams `shouldReturn` []
      recs <- getRecorders seams
      length recs `shouldBe` 0

    it "answers /bg --help the same way, creating nothing" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg --help"
      sends <- getSends chan
      T.concat sends `shouldSatisfy` T.isInfixOf "The background session is created headless"
      getMints seams `shouldReturn` []
      getSendCalls seams `shouldReturn` []

    it "mints a headless session, runs the prompt on it, and leaves the conversation untouched" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      sessions <- newSessionMap
      sessionInsert sessions bgKey convSid
      ss <- newStreamingState
      convRec <- mkWsRecorder
      wsConns <- newTVarIO (Map.singleton bgKey (convSid, recorderClient convRec, ss))
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg hi"
      -- The mint body asks for a headless session.
      getMints seams `shouldReturn` [A.object ["headless" .= A.Bool True]]
      -- The prompt went to the NEW session, never the conversation's.
      getSendCalls seams `shouldReturn` [(bgSid1, "hi")]
      -- The conversation's focused session is unchanged and its client
      -- received no FocusOp.
      mConvSid <- sessionLookup sessions bgKey
      mConvSid `shouldBe` Just convSid
      getFocused convRec `shouldReturn` []
      -- The bg connection was focused on the bg session.
      recs <- getRecorders seams
      case recs of
        (bgRec : _) -> getFocused bgRec `shouldReturn` [bgSid1]
        []          -> expectationFailure "expected a bg WS connection"
      -- The bg session is tracked, and the confirmation was posted.
      sids <- map bgSid <$> bgSessionsFor bg bgKey
      sids `shouldBe` [bgSid1]
      getSends chan `shouldReturn` ["bg session bgsid-1 started"]

    it "works when the conversation has no session yet" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg hi"
      getSendCalls seams `shouldReturn` [(bgSid1, "hi")]
      mConvSid <- sessionLookup sessions bgKey
      mConvSid `shouldBe` Nothing

    it "posts the recorded response entry from the bg connection" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg hi"
      cbs <- getCallbacks seams
      case cbs of
        (cb : _) -> cb (SeEntry bgSid1 (bgReplyJson "the background answer"))
        []       -> expectationFailure "expected a bg WS callback"
      sent <- getAllSent chan
      sent `shouldSatisfy` any (T.isInfixOf "the background answer")

    it "ignores entry-updates, list snapshots, and other sessions on the bg connection" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg hi"
      cbs <- getCallbacks seams
      case cbs of
        (cb : _) -> do
          cb (SeEntryUpdate bgSid1 (streamingJsonFor "half a streamed reply"))
          cb (SeLists (A.object [ "type" .= ("lists" :: Text)
                                , "thinkingSessionIds" .= ([] :: [Text]) ]))
          cb (SeEntry (mkSid "some-other-session") (bgReplyJson "not my reply"))
        [] -> expectationFailure "expected a bg WS callback"
      -- Nothing but the /bg confirmation was posted: no streamed delta, no
      -- list handling, no reply for a foreign session. getAllSent covers
      -- ccSendWithId (which the streaming/finalize path uses), so a
      -- regression that routed any of these events into the streaming
      -- handlers is observable here.
      sent <- getAllSent chan
      sent `shouldBe` ["bg session bgsid-1 started"]
      getWithOptions chan `shouldReturn` []
      getEdits chan `shouldReturn` []

    it "closes the bg connection on harness-status idle, exactly once" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg hi"
      cbs <- getCallbacks seams
      case cbs of
        (cb : _) -> do
          cb (SeEntry bgSid1 (bgReplyJson "the answer"))
          cb (SeActivity bgSid1 (statusJson "idle"))
          -- A second idle event must not close (or report) again.
          cb (SeActivity bgSid1 (statusJson "idle"))
        [] -> expectationFailure "expected a bg WS callback"
      recs <- getRecorders seams
      case recs of
        (bgRec : _) -> getCloses bgRec `shouldReturn` 1
        []          -> expectationFailure "expected a bg WS connection"
      sids <- map bgSid <$> bgSessionsFor bg bgKey
      sids `shouldBe` []
      sent <- getAllSent chan
      sent `shouldSatisfy` not . any (T.isInfixOf "produced no reply")

    it "posts a tool-progress line for a bg turn's tool-call activity" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg hi"
      cbs <- getCallbacks seams
      case cbs of
        (cb : _) -> cb (SeActivity bgSid1 (toolCallJson "SHELL_EXEC"))
        [] -> expectationFailure "expected a bg WS callback"
      sends <- getSends chan
      sends `shouldSatisfy` any (T.isInfixOf "SHELL_EXEC")

    it "registers a bg ask that offers options, and one that offers none" $ do
      -- Option-less asks (open-ended ASK_HUMAN, or the confirmation gate's
      -- bare prompt) must be registered too, so a text answer can resolve
      -- and dequeue them instead of letting them leak.
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1", "bgsid-2"]
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg one"
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg two"
      cbs <- getCallbacks seams
      case cbs of
        (cb1 : cb2 : _) -> do
          cb1 (SeAsk bgSid1 (A.object
            [ "id" .= ("aaaaaaaa-0000-0000-0000-000000000000" :: Text)
            , "question" .= ("Pick one" :: Text)
            , "options" .= [A.object [ "label" .= ("red" :: Text), "description" .= ("" :: Text) ]]
            ]))
          cb2 (SeAsk bgSid2 (A.object
            [ "id" .= ("bbbbbbbb-0000-0000-0000-000000000000" :: Text)
            , "question" .= ("Type something" :: Text)
            , "options" .= ([] :: [A.Value])
            ]))
        _ -> expectationFailure "expected two bg WS callbacks"
      -- The option-ful ask rendered as an inline keyboard.
      opts <- getWithOptions chan
      map snd opts `shouldBe` [["red"]]
      -- Both asks are pending, keyed by their own (bg) session.
      asks <- pendingAsksFor pendingAsks
      (length <$> Map.lookup bgSid1 asks) `shouldBe` Just 1
      (length <$> Map.lookup bgSid2 asks) `shouldBe` Just 1
      -- The option-less one rendered as plain question text (no keyboard),
      -- yet is still registered (that is the fix).
      sends <- getSends chan
      sends `shouldSatisfy` any (T.isInfixOf "Type something")

    it "drops a bg session's pending asks when the session retires" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg hi"
      cbs <- getCallbacks seams
      case cbs of
        (cb : _) -> do
          cb (SeAsk bgSid1 (A.object
            [ "id" .= ("aaaaaaaa-0000-0000-0000-000000000000" :: Text)
            , "question" .= ("Pick one" :: Text)
            , "options" .= ([] :: [A.Value])
            ]))
          asksBefore <- pendingAsksFor pendingAsks
          Map.member bgSid1 asksBefore `shouldBe` True
          cb (SeActivity bgSid1 (statusJson "idle"))
        _ -> expectationFailure "expected a bg WS callback"
      asksAfter <- pendingAsksFor pendingAsks
      Map.member bgSid1 asksAfter `shouldBe` False

    it "reports a bg turn that produced no reply when it goes idle" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg hi"
      cbs <- getCallbacks seams
      case cbs of
        (cb : _) -> cb (SeActivity bgSid1 (statusJson "idle"))
        []       -> expectationFailure "expected a bg WS callback"
      sent <- getAllSent chan
      sent `shouldSatisfy` any (T.isInfixOf "bg session bgsid-1 produced no reply")
      recs <- getRecorders seams
      case recs of
        (bgRec : _) -> getCloses bgRec `shouldReturn` 1
        []          -> expectationFailure "expected a bg WS connection"

    it "reports a mint failure and tracks nothing" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMintFailure seams "gateway down"
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg hi"
      getSends chan `shouldReturn` ["bg session failed: gateway down"]
      getSendCalls seams `shouldReturn` []
      sids <- map bgSid <$> bgSessionsFor bg bgKey
      sids `shouldBe` []

    it "reports a connect failure and tracks nothing" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      queueConnectFailure seams "ws refused"
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg hi"
      getSends chan `shouldReturn` ["bg session failed: ws refused"]
      -- The prompt was never delivered and nothing is tracked.
      getSendCalls seams `shouldReturn` []
      sids <- map bgSid <$> bgSessionsFor bg bgKey
      sids `shouldBe` []

    it "reports a send failure, closes the connection, and tracks nothing" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      queueSendFailure seams "send refused"
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg hi"
      getSends chan `shouldReturn` ["bg session failed: send refused"]
      sids <- map bgSid <$> bgSessionsFor bg bgKey
      sids `shouldBe` []
      recs <- getRecorders seams
      case recs of
        (bgRec : _) -> getCloses bgRec `shouldReturn` 1
        []          -> expectationFailure "expected a bg WS connection"

    it "tracks two concurrent bg sessions and delivers both replies" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1", "bgsid-2"]
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
          run = handleInbound cfg chan sessions wsConns pendingAsks bg
                  tabTracker watchState thinkingTabs bgKey
      run "/bg one"
      run "/bg two"
      sids <- map bgSid <$> bgSessionsFor bg bgKey
      sids `shouldBe` [bgSid1, bgSid2]
      getSendCalls seams `shouldReturn` [(bgSid1, "one"), (bgSid2, "two")]
      cbs <- getCallbacks seams
      case cbs of
        (cb1 : cb2 : _) -> do
          cb1 (SeEntry bgSid1 (bgReplyJson "first answer"))
          cb2 (SeEntry bgSid2 (bgReplyJson "second answer"))
        _ -> expectationFailure "expected two bg WS callbacks"
      sent <- getAllSent chan
      sent `shouldSatisfy` any (T.isInfixOf "first answer")
      sent `shouldSatisfy` any (T.isInfixOf "second answer")

    it "evicts the oldest bg session when a fifth starts" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1", "bgsid-2", "bgsid-3", "bgsid-4", "bgsid-5"]
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
          run = handleInbound cfg chan sessions wsConns pendingAsks bg
                  tabTracker watchState thinkingTabs bgKey
      mapM_ (\n -> run ("/bg prompt " <> T.pack (show n))) [1 :: Int, 2, 3, 4, 5]
      bgSessionsFor bg bgKey
        >>= (`shouldBe` map mkSid ["bgsid-2", "bgsid-3", "bgsid-4", "bgsid-5"])
          . map bgSid
      recs <- getRecorders seams
      mapM getCloses recs `shouldReturn` [1, 0, 0, 0, 0]

    it "never routes a bg session's non-focused activity to watch mode" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      sessions <- newSessionMap
      sessionInsert sessions bgKey convSid
      ss <- newStreamingState
      convRec <- mkWsRecorder
      wsConns <- newTVarIO (Map.singleton bgKey (convSid, recorderClient convRec, ss))
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
          fire _sid = handleServerEvent cfg chan bgKey wsConns pendingAsks bg
                       tabTracker watchState thinkingTabs convSid
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg hi"
      handleWatchToggle chan watchState bgKey "/watch on"
      fire bgSid1 (SeActivity bgSid1 (statusJson "thinking"))
      fire bgSid1 (SeActivity bgSid1 (statusJson "idle"))
      sends <- getSends chan
      sends `shouldSatisfy` not . any (T.isInfixOf "finished thinking")
      -- Sanity check: a non-bg session still notifies, so the exclusion
      -- above is not vacuous.
      let otherSid = mkSid "another-tab"
      fire otherSid (SeActivity otherSid (statusJson "thinking"))
      fire otherSid (SeActivity otherSid (statusJson "idle"))
      sends' <- getSends chan
      sends' `shouldSatisfy` any (T.isInfixOf "finished thinking")

    it "answers a bg ask with a numeric plain-text reply (1-based option)" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      sessions <- newSessionMap
      sessionInsert sessions bgKey convSid
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
          run = handleInbound cfg chan sessions wsConns pendingAsks bg
                  tabTracker watchState thinkingTabs bgKey
      run "/bg hi"
      cbs <- getCallbacks seams
      case cbs of
        (cb : _) -> cb (SeAsk bgSid1 (A.object
          [ "id" .= ("aaaaaaaa-0000-0000-0000-000000000000" :: Text)
          , "question" .= ("Pick one" :: Text)
          , "options" .=
              [ A.object [ "label" .= ("red" :: Text), "description" .= ("" :: Text) ]
              , A.object [ "label" .= ("green" :: Text), "description" .= ("" :: Text) ]
              ]
          ]))
        [] -> expectationFailure "expected a bg WS callback"
      -- "2" selects the second option's label.
      run "2"
      answers <- getAnswers seams
      answers `shouldBe`
        [(bgSid1, "aaaaaaaa-0000-0000-0000-000000000000", "green")]
      sent <- getSends chan
      sent `shouldSatisfy` any (T.isInfixOf "✓ green")
      -- The answer was consumed: it never became a turn on the focused
      -- session.
      getSendCalls seams `shouldReturn` [(bgSid1, "hi")]
      -- ...and the ask was dequeued, so the NEXT plain message routes
      -- normally again.
      run "hello"
      calls <- getSendCalls seams
      calls `shouldBe` [(bgSid1, "hi"), (convSid, "hello")]

    it "answers a bg ask with a non-numeric plain-text reply verbatim" $ do
      -- This covers the confirmation gate (@AskPrompt prompt []@): its
      -- reply is parsed server-side (y/yes → once, else rejected).
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      sessions <- newSessionMap
      sessionInsert sessions bgKey convSid
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
          run = handleInbound cfg chan sessions wsConns pendingAsks bg
                  tabTracker watchState thinkingTabs bgKey
      run "/bg hi"
      cbs <- getCallbacks seams
      case cbs of
        (cb : _) -> cb (SeAsk bgSid1 (A.object
          [ "id" .= ("bbbbbbbb-0000-0000-0000-000000000000" :: Text)
          , "question" .= ("Allow SHELL_EXEC? [y/N] " :: Text)
          , "options" .= ([] :: [A.Value])
          ]))
        [] -> expectationFailure "expected a bg WS callback"
      run "y"
      answers <- getAnswers seams
      answers `shouldBe` [(bgSid1, "bbbbbbbb-0000-0000-0000-000000000000", "y")]
      -- Not routed to the focused session.
      getSendCalls seams `shouldReturn` [(bgSid1, "hi")]

    it "answers the oldest pending bg ask first" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1", "bgsid-2"]
      sessions <- newSessionMap
      sessionInsert sessions bgKey convSid
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
          run = handleInbound cfg chan sessions wsConns pendingAsks bg
                  tabTracker watchState thinkingTabs bgKey
      run "/bg one"
      run "/bg two"
      cbs <- getCallbacks seams
      case cbs of
        (cb1 : cb2 : _) -> do
          -- The NEWER session (bgSid2) asks first, then the older session
          -- (bgSid1) asks. The globally oldest ask is therefore the newer
          -- session's one: answering must follow arrival order, not session
          -- creation order.
          cb2 (SeAsk bgSid2 (A.object
            [ "id" .= ("bbbbbbbb-0000-0000-0000-000000000000" :: Text)
            , "question" .= ("newer-session ask" :: Text)
            , "options" .= ([] :: [A.Value])
            ]))
          cb1 (SeAsk bgSid1 (A.object
            [ "id" .= ("aaaaaaaa-0000-0000-0000-000000000000" :: Text)
            , "question" .= ("older-session ask" :: Text)
            , "options" .= ([] :: [A.Value])
            ]))
        _ -> expectationFailure "expected two bg WS callbacks"
      run "y"
      answers <- getAnswers seams
      answers `shouldBe`
        [(bgSid2, "bbbbbbbb-0000-0000-0000-000000000000", "y")]
      -- Repeating the answer now answers the remaining (later-arrived) ask.
      run "y"
      answers' <- getAnswers seams
      answers' `shouldBe`
        [ (bgSid2, "bbbbbbbb-0000-0000-0000-000000000000", "y")
        , (bgSid1, "aaaaaaaa-0000-0000-0000-000000000000", "y")
        ]

    it "answers the oldest ask of one bg session first (list tail)" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      sessions <- newSessionMap
      sessionInsert sessions bgKey convSid
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
          run = handleInbound cfg chan sessions wsConns pendingAsks bg
                  tabTracker watchState thinkingTabs bgKey
      run "/bg hi"
      cbs <- getCallbacks seams
      case cbs of
        (cb : _) -> do
          cb (SeAsk bgSid1 (A.object
            [ "id" .= ("11111111-0000-0000-0000-000000000000" :: Text)
            , "question" .= ("first" :: Text)
            , "options" .= ([] :: [A.Value])
            ]))
          cb (SeAsk bgSid1 (A.object
            [ "id" .= ("22222222-0000-0000-0000-000000000000" :: Text)
            , "question" .= ("second" :: Text)
            , "options" .= ([] :: [A.Value])
            ]))
        [] -> expectationFailure "expected a bg WS callback"
      run "y"
      answers <- getAnswers seams
      -- handleAsk prepends, so the oldest ask is the list tail.
      answers `shouldBe` [(bgSid1, "11111111-0000-0000-0000-000000000000", "y")]

    it "does not claim success when the question was already resolved" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      queueAnswerNotAccepted seams
      sessions <- newSessionMap
      sessionInsert sessions bgKey convSid
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
          run = handleInbound cfg chan sessions wsConns pendingAsks bg
                  tabTracker watchState thinkingTabs bgKey
      run "/bg hi"
      cbs <- getCallbacks seams
      case cbs of
        (cb : _) -> cb (SeAsk bgSid1 (A.object
          [ "id" .= ("33333333-0000-0000-0000-000000000000" :: Text)
          , "question" .= ("Pick one" :: Text)
          , "options" .= ([] :: [A.Value])
          ]))
        [] -> expectationFailure "expected a bg WS callback"
      run "y"
      sent <- getSends chan
      sent `shouldSatisfy` any (T.isInfixOf "already resolved")
      sent `shouldSatisfy` not . any (T.isInfixOf "✓")
      -- The ask is resolved, so it is dequeued either way.
      asks <- pendingAsksFor pendingAsks
      Map.member bgSid1 asks `shouldBe` False

    it "forgets a foreground ask when it is resolved elsewhere (ask_resolved)" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      sessions <- newSessionMap
      sessionInsert sessions bgKey convSid
      ss <- newStreamingState
      convRec <- mkWsRecorder
      wsConns <- newTVarIO (Map.singleton bgKey (convSid, recorderClient convRec, ss))
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
          fire = handleServerEvent cfg chan bgKey wsConns pendingAsks bg
                   tabTracker watchState thinkingTabs convSid
      fire (SeAsk convSid (A.object
        [ "id" .= ("44444444-0000-0000-0000-000000000000" :: Text)
        , "question" .= ("Pick one" :: Text)
        , "options" .= ([] :: [A.Value])
        ]))
      asksBefore <- pendingAsksFor pendingAsks
      Map.member convSid asksBefore `shouldBe` True
      fire (SeAskResolved convSid (A.object
        [ "id" .= ("44444444-0000-0000-0000-000000000000" :: Text)
        , "resolution" .= ("answered" :: Text)
        ]))
      asksAfter <- pendingAsksFor pendingAsks
      Map.member convSid asksAfter `shouldBe` False

    it "reports an answer failure and keeps the ask pending" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      queueAnswerFailure seams "HTTP 500"
      sessions <- newSessionMap
      sessionInsert sessions bgKey convSid
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
          run = handleInbound cfg chan sessions wsConns pendingAsks bg
                  tabTracker watchState thinkingTabs bgKey
      run "/bg hi"
      cbs <- getCallbacks seams
      case cbs of
        (cb : _) -> cb (SeAsk bgSid1 (A.object
          [ "id" .= ("ffffffff-0000-0000-0000-000000000000" :: Text)
          , "question" .= ("Pick one" :: Text)
          , "options" .= ([] :: [A.Value])
          ]))
        [] -> expectationFailure "expected a bg WS callback"
      run "y"
      sent <- getSends chan
      sent `shouldSatisfy` any (T.isInfixOf "answer failed: HTTP 500")
      -- The failed answer is still pending, so the user can retry.
      asks <- pendingAsksFor pendingAsks
      (length <$> Map.lookup bgSid1 asks) `shouldBe` Just 1
      -- ...and the message was not routed to the focused session instead.
      getSendCalls seams `shouldReturn` [(bgSid1, "hi")]

    it "does not consume commands as answers to a pending bg ask" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      sessions <- newSessionMap
      sessionInsert sessions bgKey convSid
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
          run = handleInbound cfg chan sessions wsConns pendingAsks bg
                  tabTracker watchState thinkingTabs bgKey
      run "/bg hi"
      cbs <- getCallbacks seams
      case cbs of
        (cb : _) -> cb (SeAsk bgSid1 (A.object
          [ "id" .= ("cccccccc-0000-0000-0000-000000000000" :: Text)
          , "question" .= ("Pick one" :: Text)
          , "options" .=
              [ A.object [ "label" .= ("red" :: Text), "description" .= ("" :: Text) ] ]
          ]))
        [] -> expectationFailure "expected a bg WS callback"
      run "/1"
      run "/watch status"
      run "/new"
      run "/bg another prompt"
      getAnswers seams `shouldReturn` []
      -- The ask is still pending.
      asks <- pendingAsksFor pendingAsks
      (length <$> Map.lookup bgSid1 asks) `shouldBe` Just 1

    it "resolves a bg ask from an inline-button tap, scoped to the conversation" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      sessions <- newSessionMap
      sessionInsert sessions bgKey convSid
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg hi"
      cbs <- getCallbacks seams
      case cbs of
        (cb : _) -> cb (SeAsk bgSid1 (A.object
          [ "id" .= ("dddddddd-0000-0000-0000-000000000000" :: Text)
          , "question" .= ("Pick one" :: Text)
          , "options" .=
              [ A.object [ "label" .= ("red" :: Text), "description" .= ("" :: Text) ] ]
          ]))
        [] -> expectationFailure "expected a bg WS callback"
      -- A tap in a DIFFERENT conversation must not resolve it.
      let otherKey = ConversationKey "signal" "conv-other"
      handleCallback cfg chan sessions pendingAsks bg otherKey
        (mkSourceFor "conv-other") "dddddddd:0"
      getAnswers seams `shouldReturn` []
      -- A tap in the owning conversation resolves it against the bg sid.
      handleCallback cfg chan sessions pendingAsks bg bgKey
        (mkSourceFor "conv-bg") "dddddddd:0"
      answers <- getAnswers seams
      answers `shouldBe` [(bgSid1, "dddddddd-0000-0000-0000-000000000000", "red")]
      sent <- getSends chan
      sent `shouldSatisfy` any (T.isInfixOf "✓ red")

    it "forgets a bg ask when it is resolved elsewhere (ask_resolved)" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg hi"
      cbs <- getCallbacks seams
      case cbs of
        (cb : _) -> do
          cb (SeAsk bgSid1 (A.object
            [ "id" .= ("eeeeeeee-0000-0000-0000-000000000000" :: Text)
            , "question" .= ("Pick one" :: Text)
            , "options" .= ([] :: [A.Value])
            ]))
          asksBefore <- pendingAsksFor pendingAsks
          Map.member bgSid1 asksBefore `shouldBe` True
          cb (SeAskResolved bgSid1 (A.object
            [ "id" .= ("eeeeeeee-0000-0000-0000-000000000000" :: Text)
            , "resolution" .= ("answered" :: Text)
            ]))
        [] -> expectationFailure "expected a bg WS callback"
      asksAfter <- pendingAsksFor pendingAsks
      Map.member bgSid1 asksAfter `shouldBe` False

    it "keeps a retired bg session out of watch mode (late activity events)" $ do
      -- BeActivity is broadcast to every subscriber, so the conversation's
      -- own connection also sees the bg session's idle — possibly after the
      -- bg connection's reader retired it. The exclusion must survive
      -- retirement, or every /bg turn would emit a bogus "Tab ?" line plus
      -- a duplicate reply.
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["bgsid-1"]
      sessions <- newSessionMap
      sessionInsert sessions bgKey convSid
      ss <- newStreamingState
      convRec <- mkWsRecorder
      wsConns <- newTVarIO (Map.singleton bgKey (convSid, recorderClient convRec, ss))
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
          fire = handleServerEvent cfg chan bgKey wsConns pendingAsks bg
                   tabTracker watchState thinkingTabs convSid
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs bgKey "/bg hi"
      handleWatchToggle chan watchState bgKey "/watch on"
      -- The bg connection retires the session first...
      cbs <- getCallbacks seams
      case cbs of
        (cb : _) -> cb (SeActivity bgSid1 (statusJson "idle"))
        [] -> expectationFailure "expected a bg WS callback"
      sids <- map bgSid <$> bgSessionsFor bg bgKey
      sids `shouldBe` []
      -- ...and only then does the conversation's own connection process the
      -- same all-subscriber activity.
      fire (SeActivity bgSid1 (statusJson "thinking"))
      fire (SeActivity bgSid1 (statusJson "idle"))
      sends <- getSends chan
      sends `shouldSatisfy` not . any (T.isInfixOf "finished thinking")

  describe "/tab list (client-side renderer)" $ do
    it "sends one D5-formatted message per tab" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      let rows =
            [ TabJson 0 (Just "s1") "session:ai" (Just "first") Nothing
            , TabJson 1 (Just "s2") "session:ai" Nothing Nothing
            ]
          lists = ListsJson
            { ljTabs = rows
            , ljTabSessions = [A.object [ "id" .= ("s2" :: Text), "description" .= ("second" :: Text) ]]
            , ljThinkingSessionIds = ["s1"]
            }
          cfg = (stubCfg mgr seams) { cccGetLists = \_ _ -> pure (Right lists) }
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty :: IO (TVar (Map ConversationKey WsConn))
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let key = ConversationKey "signal" "tablist-conv"
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker watchState thinkingTabs key "/tab list"
      sends <- getSends chan
      sends `shouldBe` ["0 busy: first", "1 idle: second"]

    it "replies 'no tabs' when the list is empty" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      let cfg = (stubCfg mgr seams)
                  { cccGetLists = \_ _ -> pure (Right (ListsJson [] [] [])) }
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty :: IO (TVar (Map ConversationKey WsConn))
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let key = ConversationKey "signal" "tablist-empty"
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker watchState thinkingTabs key "/tab list"
      sends <- getSends chan
      sends `shouldBe` ["no tabs"]

    it "replies 'tab list failed: <e>' when the fetch fails" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      let cfg = (stubCfg mgr seams)
                  { cccGetLists = \_ _ -> pure (Left "boom") }
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty :: IO (TVar (Map ConversationKey WsConn))
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let key = ConversationKey "signal" "tablist-fail"
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker watchState thinkingTabs key "/tab list"
      sends <- getSends chan
      sends `shouldBe` ["tab list failed: boom"]

  -- ── /new: slash-command parity (WU-7) ──────────────────────────────────
  describe "/new (slash-command parity)" $ do
    let newKey = ConversationKey "signal" "new-conv"
        oldSid = mkSid "old-sid"
        newSid = mkSid "new-sid"
        freshSid = mkSid "fresh-sid"
        confirmNew = "new session new-sid (p/m) — prior session old-sid kept in /session list"

    it "rebinds (exactly one mint) when the conversation already has a session" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueRebinds seams [Right (rebindOk "new-sid" "anthropic" "claude-sonnet-4")]
      sessions <- newSessionMap
      sessionInsert sessions newKey oldSid
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
          run = handleInbound cfg chan sessions wsConns pendingAsks bg
                  tabTracker watchState thinkingTabs newKey
      run "/new"
      -- ONE mint: the rebind call mints; the plain mint seam must not run.
      getMints seams `shouldReturn` []
      getRebinds seams `shouldReturn`
        [(oldSid, A.object ["channel" .= ("mock" :: Text)])]
      getSends chan `shouldReturn`
        ["new session new-sid (anthropic/claude-sonnet-4) — prior session old-sid kept in /session list"]
      -- The conversation now routes to the new session.
      sessionLookup sessions newKey `shouldReturn` Just newSid
      run "hello"
      getSendCalls seams `shouldReturn` [(newSid, "hello")]

    it "mints once with the provider/model flags when there is no prior session" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["fresh-sid"]
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs newKey "/new -p anthropic -m claude-sonnet-4"
      getMints seams `shouldReturn`
        [A.object
          [ "provider" .= ("anthropic" :: Text)
          , "model" .= ("claude-sonnet-4" :: Text) ]]
      getRebinds seams `shouldReturn` []
      -- No prior session: nothing to warn about and nothing to resume.
      getSends chan `shouldReturn` ["new session fresh-sid"]
      sessionLookup sessions newKey `shouldReturn` Just freshSid

    it "warns about a failed tab rebind, then still confirms the new session" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueRebinds seams
        [Right ((rebindOk "new-sid" "p" "m")
                  { nsrRebound = False
                  , nsrTabIndex = Nothing
                  , nsrRebindError = Just "tab index out of range" })]
      sessions <- newSessionMap
      sessionInsert sessions newKey oldSid
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs newKey "/new"
      getSends chan `shouldReturn`
        [ "warning: /new tab rebind failed: tab index out of range"
        , confirmNew ]

    it "confirms without a warning when no tab was bound (rebound false, no error)" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueRebinds seams
        [Right ((rebindOk "new-sid" "p" "m")
                  { nsrRebound = False, nsrTabIndex = Nothing })]
      sessions <- newSessionMap
      sessionInsert sessions newKey oldSid
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs newKey "/new"
      getSends chan `shouldReturn` [confirmNew]

    it "keeps the conversation's session when the rebind call fails" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueRebinds seams [Left "session not found"]
      sessions <- newSessionMap
      sessionInsert sessions newKey oldSid
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs newKey "/new"
      getSends chan `shouldReturn` ["new session failed: session not found"]
      sessionLookup sessions newKey `shouldReturn` Just oldSid

    it "resolves -r against the repo registry and sets the repo up on the NEW session" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueRebinds seams [Right (rebindOk "new-sid" "p" "m")]
      queueRepos seams
        [Right [A.object
          [ "id" .= ("seal" :: Text)
          , "url" .= ("git@github.com:o/r.git" :: Text) ]]]
      sessions <- newSessionMap
      sessionInsert sessions newKey oldSid
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs newKey "/new -r seal"
      getRepoSetups seams `shouldReturn`
        [(newSid, A.object ["url" .= ("git@github.com:o/r.git" :: Text)])]
      -- A successful setup is silent: only the confirmation.
      getSends chan `shouldReturn` [confirmNew]

    it "uses -r verbatim when the repo registry cannot be read" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueMints seams ["fresh-sid"]
      queueRepos seams [Left "boom"]
      sessions <- newSessionMap
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs newKey "/new -r https://github.com/o/r.git"
      getRepoSetups seams `shouldReturn`
        [(freshSid, A.object ["url" .= ("https://github.com/o/r.git" :: Text)])]
      getSends chan `shouldReturn` ["new session fresh-sid"]

    it "orders the rebind warning before the repo failure before the confirmation" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      queueRebinds seams
        [Right ((rebindOk "new-sid" "p" "m") { nsrRebindError = Just "no tab" })]
      queueRepos seams [Right []]
      queueRepoSetupFailure seams "clone failed: denied"
      sessions <- newSessionMap
      sessionInsert sessions newKey oldSid
      wsConns <- newTVarIO Map.empty
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
      handleInbound cfg chan sessions wsConns pendingAsks bg tabTracker
        watchState thinkingTabs newKey "/new -r https://x/y.git"
      getSends chan `shouldReturn`
        [ "warning: /new tab rebind failed: no tab"
        , "repo setup failed: clone failed: denied"
        , confirmNew ]

  -- ── WU-5: a /new re-target must rebuild the WS connection ─────────────
  --
  -- 'handleServerEvent' closes over the focused session BY VALUE, so a
  -- FocusOp cannot re-target an existing connection's filter: after /new
  -- the old connection keeps dropping the new session's entries and asks.
  -- Asserting "a focus was recorded on the new sid" would pass while the
  -- bug persists — the pin must be a SECOND connect + a close of the old
  -- client + delivery through the NEW callback.
  describe "/new WS re-target (WU-5)" $ do
    it "rebuilds the conversation's WS connection when /new switches session" $ do
      chan <- mkMockChan
      mgr <- newManager defaultManagerSettings
      seams <- mkSeams
      let key = ConversationKey "signal" "conn-retarget"
          sidA = mkSid "sid-a"
          sidB = mkSid "sid-b"
      queueRebinds seams [Right (rebindOk "sid-b" "p" "m")]
      sessions <- newSessionMap
      -- The conversation is already focused on sid A, with a live connection
      -- whose callback was built for A.
      sessionInsert sessions key sidA
      ss <- newStreamingState
      recA <- mkWsRecorder
      wsConns <- newTVarIO (Map.singleton key (sidA, recorderClient recA, ss))
      pendingAsks <- newPendingAsks
      bg <- newBgSessions
      tabTracker <- newTVarIO Map.empty
      watchState <- newWatchState
      thinkingTabs <- newThinkingTabs
      let cfg = stubCfg mgr seams
          run = handleInbound cfg chan sessions wsConns pendingAsks bg
                  tabTracker watchState thinkingTabs key
      -- /new switches the conversation to sid B.
      run "/new"
      recs <- getRecorders seams
      cbs <- getCallbacks seams
      -- A SECOND connect (the old one could not be re-targeted) ...
      length cbs `shouldBe` 1
      case (recs, cbs) of
        ([recB], [cbB]) -> do
          -- ... the old client was closed ...
          getCloses recA `shouldReturn` 1
          -- ... and the new connection is focused on the new session.
          getFocused recB `shouldReturn` [sidB]
          -- The pin that matters: an entry for B dispatched through the NEW
          -- callback reaches the platform (it is no longer filtered out by a
          -- callback closed over A).
          cbB (SeEntry sidB (bgReplyJson "reply on B"))
          sent <- getAllSent chan
          sent `shouldSatisfy` any (T.isInfixOf "reply on B")
        _ -> expectationFailure "expected exactly one new WS connection"
