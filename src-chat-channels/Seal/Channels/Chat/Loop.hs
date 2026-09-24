{-# LANGUAGE OverloadedStrings #-}
-- | The generic chat-channel main loop. Handles routing (@/N@ focus, slash
-- commands, plain text), WS focus + streaming, HTTP send, session tracking,
-- and ASK_HUMAN — all through the gateway API. The 'ChatChannel' instance
-- provides the platform-specific I/O.
module Seal.Channels.Chat.Loop
  ( runChatChannel
  , ChatChannelConfig (..)
  , defaultChatChannelConfig
    -- * Event handlers (for testing)
  , handleServerEvent
    -- * Pure helpers (for testing)
  , extractEntryText
  , extractActivityKind
  , extractDirection
  , extractActivityStatus
  , extractToolName
  , extractToolInput
  , extractAskQuestion
  , extractAskId
  , extractAskOptions
  , lastAssistantText
  , formatQuestionWithOptions
  , parseCallbackData
  ) where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, modifyTVar', readTVarIO)
import Control.Monad (when, unless)
import Data.Foldable (for_)
import Data.Aeson (Value)
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef (readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Text (Text)
import Data.Char (isDigit)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import System.IO (hPutStrLn, stderr)
import Network.HTTP.Client (Manager)

import Seal.Channels.Chat.Class (ChatChannel (..), QuestionOption (..))
import Seal.Channels.Chat.HttpClient
  (httpSend, httpGetTabs, httpNewSession, httpGetTranscript, httpAnswerQuestion,
   SendResult (..), TabJson (..))
import Seal.Channels.Chat.RateLimit
  (StreamProgressConfig (..), defaultStreamProgressConfig,
   shouldEdit, addCursor, stripCursor)
import Seal.Channels.Chat.Route
  (ChatRoute (..), route, parseTabFocus)
import Seal.Channels.Chat.Types
  (InboundMessage (..), ConversationKey (..),
   convKeyFromSource, SessionMap, newSessionMap, sessionLookup,
   sessionInsert, GatewayConfig (..), StreamingState (..),
   newStreamingState, resetStreamingState)
import Seal.Channels.Chat.ToolRender
  (formatToolLine)
import Seal.Channels.Chat.WsClient
  (WsClient (..), startWsClient)

import Seal.Gateway.Types.Core
  (SessionId, mkSessionId, sessionIdText)
import Seal.Gateway.Types.Stream (ServerEvent (..))
import Seal.Gateway.Types.MessageSource (MessageSource)
import Seal.Gateway.Types.Tab (TabIndex, tabIndexToInt, tabIndexToChar)

-- | A pending ASK_HUMAN question tracked by the loop: the ask id text +
-- the offered options (so the callback handler can resolve a button index
-- to the option label). Keyed by session id + ask id prefix.
data PendingAsk = PendingAsk
  { paAskId :: !Text
  , paOptions :: ![QuestionOption]
  }

-- | The pending-asks store: session id → list of pending asks. Thread-safe
-- via 'TVar'.
type PendingAsks = TVar (Map SessionId [PendingAsk])

-- | Configuration for the generic loop.
data ChatChannelConfig = ChatChannelConfig
  { cccGateway     :: GatewayConfig
    -- ^ The gateway connection config (HTTP + WS endpoints).
  , cccStreamCfg   :: StreamProgressConfig
    -- ^ Rate-limiting config for streaming edits.
  , cccHttpManager :: Manager
    -- ^ The shared HTTP manager for gateway API calls.
  }

-- | Default config with sensible defaults.
defaultChatChannelConfig :: Manager -> GatewayConfig -> ChatChannelConfig
defaultChatChannelConfig mgr gw = ChatChannelConfig
  { cccGateway = gw
  , cccStreamCfg = defaultStreamProgressConfig
  , cccHttpManager = mgr
  }

-- | Debug log to stderr.
dbg :: Text -> IO ()
dbg msg = hPutStrLn stderr ("[chat-channel] " <> T.unpack msg)

-- | Run the generic chat-channel loop. Blocks until the channel's
-- 'ccReceive' returns EOF. Each conversation gets its own WS connection
-- for streaming.
runChatChannel :: ChatChannel c => ChatChannelConfig -> c -> IO ()
runChatChannel cfg chan = do
  sessions <- newSessionMap
  -- Map of conversation keys to their WS client + streaming state.
  wsConns <- newTVarIO Map.empty :: IO (TVar (Map ConversationKey (WsClient, StreamingState)))
  pendingAsks <- newTVarIO Map.empty :: IO PendingAsks
  tabTracker <- newTVarIO Map.empty :: IO (TVar (Map ConversationKey (SessionId, [TabJson])))
  loop sessions wsConns pendingAsks tabTracker
  where
    loop sessions wsConns pendingAsks tabTracker = do
      mMsg <- ccReceive chan
      case mMsg of
        Nothing -> pure ()  -- EOF
        Just (InboundMessage src body mCbData) -> do
          dbg ("received: " <> body)
          let key = convKeyFromSource src
          case mCbData of
            Just cbData -> do
              -- Callback query (button tap): resolve to a pending ask,
              -- answer via HTTP, acknowledge, and remove keyboard.
              handleCallback cfg chan sessions pendingAsks key src cbData
            Nothing ->
              -- Regular text message: route normally.
              handleInbound cfg chan sessions wsConns pendingAsks tabTracker key body
          loop sessions wsConns pendingAsks tabTracker

-- | Handle one inbound message: resolve the session, route, and dispatch.
handleInbound
  :: ChatChannel c
  => ChatChannelConfig -> c -> SessionMap
  -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> PendingAsks
  -> TVar (Map ConversationKey (SessionId, [TabJson]))
  -> ConversationKey -> Text
  -> IO ()
handleInbound cfg chan sessions wsConns pendingAsks tabTracker key body = do
  let apiBase = gcApiBase (cccGateway cfg)
      mgr = cccHttpManager cfg
  -- First, check if this is a /tab focus N (intercepted locally).
  case parseTabFocus body of
    Just idx -> do
      handleFocus cfg chan sessions wsConns pendingAsks tabTracker key idx
    Nothing -> case route body of
      Right (ChatFocus idx) ->
        handleFocus cfg chan sessions wsConns pendingAsks tabTracker key idx
      Right (ChatInject idx payload) -> do
        -- Focus the tab, then send the payload as a plain message.
        handleFocus cfg chan sessions wsConns pendingAsks tabTracker key idx
        sendPlain cfg chan sessions wsConns pendingAsks tabTracker key payload
      Right ChatCurrentTab -> do
        -- Send the current tab info via HTTP (the gateway routes /tab).
        mSid <- sessionLookup sessions key
        case mSid of
          Just sid -> do
            eResult <- httpSend mgr apiBase sid "/tab"
            case eResult of
              Right sr -> ccSend chan (srResponse sr)
              Left e -> ccSend chan ("error: " <> e)
          Nothing -> ccSend chan "no current tab"
      Right (ChatNewSession args) -> do
        -- Create a new session via HTTP, update the session map.
        handleNewSession cfg chan sessions wsConns pendingAsks tabTracker key args
      Right (ChatSlash _cmd) ->
        sendSlash cfg chan sessions wsConns pendingAsks tabTracker key body
      Right (ChatTabCommand _) ->
        -- Tab commands go through the HTTP API (the gateway routes them).
        sendSlash cfg chan sessions wsConns pendingAsks tabTracker key body
      Right (ChatPlain text) ->
        sendPlain cfg chan sessions wsConns pendingAsks tabTracker key text
      Left _ -> ccSend chan "error: invalid command"

-- | Handle a focus command: resolve the tab index to a session id via
-- @GET /api/tabs@, send a @FocusOp@ over WS, send "focused tab N" to the
-- platform, and optionally send the last assistant reply.
handleFocus
  :: ChatChannel c
  => ChatChannelConfig -> c -> SessionMap
  -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> PendingAsks
  -> TVar (Map ConversationKey (SessionId, [TabJson]))
  -> ConversationKey -> TabIndex
  -> IO ()
handleFocus cfg chan sessions wsConns pendingAsks tabTracker key idx = do
  let apiBase = gcApiBase (cccGateway cfg)
      mgr = cccHttpManager cfg
  eTabs <- httpGetTabs mgr apiBase
  case eTabs of
    Left e -> ccSend chan ("focus failed: " <> e)
    Right tabs ->
      case [ t | t <- tabs, tjIndex t == tabIndexToInt idx ] of
        [] -> ccSend chan "focus failed: tab index out of range"
        (tab : _) ->
          case tjSessionId tab of
            Nothing -> ccSend chan "focus failed: tab has no session"
            Just sidText -> case mkSessionId sidText of
              Left _ -> ccSend chan "focus failed: invalid session id"
              Right sid -> do
                -- Update the session map so subsequent messages route here.
                sessionInsert sessions key sid
                -- Track the focused session + current tab list for tab-close detection.
                atomically (modifyTVar' tabTracker (Map.insert key (sid, tabs)))
                -- Ensure a WS connection exists for this conversation.
                ensureWsConn cfg chan wsConns pendingAsks tabTracker key sid
                -- Send "focused tab N" confirmation.
                ccSend chan ("focused tab " <> T.singleton (tabIndexToChar idx))
                -- Fetch and send the last assistant reply for context.
                sendLastReply cfg chan sid

-- | Ensure a WS connection exists for the conversation. If one exists,
-- send a FocusOp to change focus. If not, start a new WS connection with
-- the streaming event handler and send a FocusOp.
ensureWsConn
  :: ChatChannel c
  => ChatChannelConfig -> c
  -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> PendingAsks
  -> TVar (Map ConversationKey (SessionId, [TabJson]))
  -> ConversationKey -> SessionId
  -> IO ()
ensureWsConn cfg chan wsConns pendingAsks tabTracker key sid = do
  let gwCfg = cccGateway cfg
  conns <- readTVarIO wsConns
  case Map.lookup key conns of
    Just (ws, _) -> wcFocus ws sid  -- already connected; just change focus
    Nothing -> do
      -- Start a new WS connection with the streaming event handler.
      let callback = handleServerEvent cfg chan key wsConns pendingAsks tabTracker sid
      eWs <- startWsClient (gcHost gwCfg) (gcWsPort gwCfg) callback
      case eWs of
        Left _ -> pure ()  -- WS failed; the channel still works via HTTP
        Right ws -> do
          ss <- newStreamingState
          atomically (modifyTVar' wsConns (Map.insert key (ws, ss)))
          wcFocus ws sid

-- | The WS event handler: processes streaming events for one conversation.
-- Creates/edits/finalizes platform messages from entry-update/entry/activity
-- events.
handleServerEvent
  :: ChatChannel c
  => ChatChannelConfig -> c -> ConversationKey
  -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> PendingAsks
  -> TVar (Map ConversationKey (SessionId, [TabJson]))
  -> SessionId -> ServerEvent -> IO ()
handleServerEvent cfg chan key wsConns pendingAsks tabTracker focusedSid ev =
  case ev of
    SeEntryUpdate sid val
      | sid == focusedSid -> handleEntryUpdate cfg chan key wsConns val
    SeEntry sid val
      | sid == focusedSid -> handleEntry cfg chan key wsConns val
    SeActivity sid val
      | sid == focusedSid -> handleActivity cfg chan key wsConns val
    -- Tool-call events are BeActivity with kind="tool-call", broadcast
    -- by the server's aeOnToolCall hook. They arrive as SeActivity.
    -- handleActivity dispatches on kind internally.
    SeAsk sid val
      | sid == focusedSid -> handleAsk cfg chan key pendingAsks sid val
    SeLists val -> handleLists cfg chan key tabTracker val
    _ -> pure ()  -- ignore events for other sessions or irrelevant types

-- | Handle an @entry-update@ event: create or edit the streaming bubble.
handleEntryUpdate
  :: ChatChannel c
  => ChatChannelConfig -> c -> ConversationKey
  -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> Value -> IO ()
handleEntryUpdate cfg chan key wsConns val = do
  conns <- readTVarIO wsConns
  case Map.lookup key conns of
    Nothing -> pure ()  -- no streaming state; ignore
    Just (_, ss) -> do
      let streamCfg = cccStreamCfg cfg
          text = extractEntryText val
      if T.null text
        then pure ()
        else do
          -- Post-finalize guard (issue #198 follow-up): a late
          -- entry-update can arrive AFTER the turn's recorded entry
          -- (the server's streaming path and the post-turn broadcast
          -- are unsynchronized). Editing now would overwrite the
          -- finalized text and re-add the cursor. Ignore updates
          -- entirely while the turn is finalized.
          finalized <- readIORef (ssFinalized ss)
          unless finalized $ do
            writeIORef (ssAccumulated ss) text
            now <- getCurrentTime
            mLastEdit <- readIORef (ssLastEdit ss)
            mMsgId <- readIORef (ssMsgId ss)
          -- Gate on NEW text since the last edit, not the total length
          -- (issue #198, part 3). The accumulator only grows within a
          -- response, so a total-length threshold degenerates to an edit
          -- on EVERY frame once the text passes spcBufferThreshold —
          -- one outbound platform edit per arriving WS frame (the
          -- 'lots of small updates' flood). Measuring the delta since
          -- the last edit keeps the cadence the config intends: an edit
          -- per interval, or per 80 NEW codepoints, whichever first.
            lastLen <- readIORef (ssLastLen ss)
            when (shouldEdit streamCfg now mLastEdit (T.length text - lastLen)) $ do
              let content = addCursor streamCfg text
              case mMsgId of
                Nothing -> do
                  mId <- ccSendWithId chan content
                  case mId of
                    Just id' -> do
                      writeIORef (ssMsgId ss) (Just id')
                      writeIORef (ssLastEdit ss) (Just now)
                      writeIORef (ssLastLen ss) (T.length text)
                    Nothing -> pure ()
                Just id' -> do
                  ok <- ccEditMessage chan id' content
                  when ok $ do
                    writeIORef (ssLastEdit ss) (Just now)
                    writeIORef (ssLastLen ss) (T.length text)

-- | Finalize the current streaming bubble for one conversation: edit it
-- without the cursor (or, if the edit fails, send the full text as a new
-- message), then reset the bubble state so the next entry-update starts
-- a fresh bubble. Does nothing when no bubble exists or nothing was
-- streamed. When @markFinal@ is 'True' (the turn's recorded response
-- entry — the definitive delivery), sets 'ssFinalized' so late
-- entry-updates are ignored until the next turn starts.
finalizeBubble
  :: ChatChannel c
  => ChatChannelConfig -> c -> StreamingState -> Text -> Bool -> IO ()
finalizeBubble cfg chan ss text markFinal = do
  let streamCfg = cccStreamCfg cfg
      finalText = stripCursor streamCfg text
  mMsgId <- readIORef (ssMsgId ss)
  delivered <- case mMsgId of
    Nothing -> isJust <$> ccSendWithId chan finalText
    Just id' -> do
      ok <- ccEditMessage chan id' finalText
      if ok
        then pure True
        else isJust <$> ccSendWithId chan finalText
  when (markFinal && delivered) $ writeIORef (ssFinalized ss) True
  resetStreamingState ss

-- | Handle an @entry@ event (complete transcript entry): finalize the
-- streaming bubble with the definitive text (mark the turn final).
handleEntry
  :: ChatChannel c
  => ChatChannelConfig -> c -> ConversationKey
  -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> Value -> IO ()
handleEntry cfg chan key wsConns val = do
  -- Only process response entries (skip request entries which would
  -- incorrectly finalize the streaming bubble with the user's text).
  let direction = extractDirection val
  if direction /= "response"
    then pure ()
    else do
      conns <- readTVarIO wsConns
      case Map.lookup key conns of
        Nothing -> pure ()
        Just (_, ss) -> do
          let text = extractEntryText val
          if T.null text
            then pure ()
            else do
              -- The recorded entry is the definitive delivery: mark the
              -- turn finalized so late entry-updates are ignored.
              finalizeBubble cfg chan ss text True

-- | Handle an @activity@ event: if harness-status is idle, finalize any
-- in-progress streaming bubble.
handleActivity
  :: ChatChannel c
  => ChatChannelConfig -> c -> ConversationKey
  -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> Value -> IO ()
handleActivity cfg chan key wsConns val = do
  let kind = extractActivityKind val
  case kind of
    "harness-status" -> handleHarnessStatus cfg chan key wsConns val
    "tool-call" -> handleToolCallActivity cfg chan key wsConns val
    _ -> pure ()

-- | Handle a @harness-status@ activity: on @thinking@ (turn start),
-- clear the finalized flag so the new turn streams. On @idle@ (turn
-- end), finalize any in-progress streaming bubble with the accumulated
-- text (a safety net — the recorded entry is the normal finalize path)
-- and reset all streaming state.
handleHarnessStatus
  :: ChatChannel c
  => ChatChannelConfig -> c -> ConversationKey
  -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> Value -> IO ()
handleHarnessStatus cfg chan key wsConns val = do
    let status = extractActivityStatus val
    case status of
      "thinking" -> do
        conns <- readTVarIO wsConns
        for_ (Map.lookup key conns) $ \(_, ss) ->
          writeIORef (ssFinalized ss) False
      "idle" -> do
        conns <- readTVarIO wsConns
        case Map.lookup key conns of
          Nothing -> pure ()
          Just (_, ss) -> do
            mMsgId <- readIORef (ssMsgId ss)
            accum <- readIORef (ssAccumulated ss)
            when (isJust mMsgId && not (T.null accum)) $
              finalizeBubble cfg chan ss accum False
            resetStreamingState ss
            writeIORef (ssFinalized ss) True
      _ -> pure ()

-- | Handle a @tool-call@ activity: finalize the current text bubble
-- (segment break — the pre-tool text stays its own message, and the
-- next entry-update starts a NEW bubble below the tool line), then send
-- the tool-progress line as its own platform message.
handleToolCallActivity
  :: ChatChannel c
  => ChatChannelConfig -> c -> ConversationKey
  -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> Value -> IO ()
handleToolCallActivity cfg chan key wsConns val = do
  -- Segment break (issue #198 follow-up, symptom 1): the pre-tool
  -- streamed text and the post-tool streamed text must be SEPARATE
  -- platform messages, with the tool line between them. Without this,
  -- the next entry-update edits the pre-tool bubble (ssMsgId is still
  -- set) and appends the post-tool text onto the pre-tool text.
  conns <- readTVarIO wsConns
  for_ (Map.lookup key conns) $ \(_, ss) -> do
    mMsgId <- readIORef (ssMsgId ss)
    accum <- readIORef (ssAccumulated ss)
    when (isJust mMsgId && not (T.null accum)) $
      finalizeBubble cfg chan ss accum False
  case extractToolName val of
    Nothing -> pure ()
    Just toolName -> do
      let mInput = extractToolInput val
          line = formatToolLine mempty toolName (fromMaybe "" mInput)
      ccSend chan line

-- | Handle an @ask@ event: render the question on the platform. When the
-- ask has options and the channel supports inline keyboards, sends the
-- question + an inline keyboard (one button per option). Otherwise falls
-- back to the numbered-list text rendering. Registers the pending ask so
-- the callback handler can resolve a button tap to the option label.
handleAsk
  :: ChatChannel c
  => ChatChannelConfig -> c -> ConversationKey -> PendingAsks -> SessionId -> Value
  -> IO ()
handleAsk _cfg chan _key pendingAsks sid val = do
  let question = extractAskQuestion val
      askId = extractAskId val
      opts = extractAskOptions val
  if null opts
    then ccSend chan question
    else do
      let prefix = T.take 8 askId
      mMsgId <- ccSendWithOptions chan question opts prefix
      case mMsgId of
        Just _  -> pure ()
        Nothing -> ccSend chan (formatQuestionWithOptions question opts)
      let entry = PendingAsk { paAskId = askId, paOptions = opts }
      atomically (modifyTVar' pendingAsks (Map.insertWith (++) sid [entry]))

-- | Send a plain text message via the HTTP API. Resolves the conversation's
-- session (creating one if it doesn't exist yet).
sendPlain
  :: ChatChannel c
  => ChatChannelConfig -> c -> SessionMap -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> PendingAsks -> TVar (Map ConversationKey (SessionId, [TabJson]))
  -> ConversationKey -> Text
  -> IO ()
sendPlain cfg chan sessions wsConns pendingAsks tabTracker key text = do
  sid <- resolveSession cfg chan sessions wsConns pendingAsks tabTracker key
  let apiBase = gcApiBase (cccGateway cfg)
      mgr = cccHttpManager cfg
  eResult <- httpSend mgr apiBase sid text
  case eResult of
    Right sr | srKind sr == "error" -> ccSend chan (fromMaybe "error" (srError sr))
    Right sr | not (T.null (srResponse sr)) -> ccSend chan (srResponse sr)
    Right _ -> pure ()  -- assistant response comes via WS
    Left e -> ccSend chan ("error: " <> e)

-- | Send a slash command via the HTTP API.
sendSlash
  :: ChatChannel c
  => ChatChannelConfig -> c -> SessionMap -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> PendingAsks -> TVar (Map ConversationKey (SessionId, [TabJson]))
  -> ConversationKey -> Text
  -> IO ()
sendSlash = sendPlain  -- same mechanism; the gateway routes slash commands

-- | Handle /new: create a new session via HTTP, update the session map.
handleNewSession
  :: ChatChannel c
  => ChatChannelConfig -> c -> SessionMap -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> PendingAsks -> TVar (Map ConversationKey (SessionId, [TabJson]))
  -> ConversationKey -> Text
  -> IO ()
handleNewSession cfg chan sessions wsConns pendingAsks tabTracker key _args = do
  let apiBase = gcApiBase (cccGateway cfg)
      mgr = cccHttpManager cfg
  eSid <- httpNewSession mgr apiBase (A.object [])
  case eSid of
    Left e -> ccSend chan ("new session failed: " <> e)
    Right sidText -> case mkSessionId sidText of
      Left _ -> ccSend chan "new session failed: invalid session id"
      Right sid -> do
        sessionInsert sessions key sid
        -- Ensure a WS connection exists for this conversation.
        ensureWsConn cfg chan wsConns pendingAsks tabTracker key sid
        ccSend chan ("new session " <> sessionIdText sid)

-- | Resolve the conversation's session. If the conversation has no session
-- yet, create one via the HTTP API.
resolveSession
  :: ChatChannel c => ChatChannelConfig -> c -> SessionMap -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> PendingAsks -> TVar (Map ConversationKey (SessionId, [TabJson]))
  -> ConversationKey
  -> IO SessionId
resolveSession cfg chan sessions wsConns pendingAsks tabTracker key = do
  mSid <- sessionLookup sessions key
  case mSid of
    Just sid -> pure sid
    Nothing -> do
      let apiBase = gcApiBase (cccGateway cfg)
          mgr = cccHttpManager cfg
      eSid <- httpNewSession mgr apiBase (A.object [])
      case eSid of
        Right sidText -> case mkSessionId sidText of
          Right sid -> do
            sessionInsert sessions key sid
            ensureWsConn cfg chan wsConns pendingAsks tabTracker key sid
            pure sid
          Left _ -> fallbackSid
        Left _ -> fallbackSid
  where
    fallbackSid = pure (case mkSessionId "default" of Right s -> s; Left _ -> error "unreachable")

-- | Fetch and send the last assistant reply from the session's transcript.
sendLastReply
  :: ChatChannel c
  => ChatChannelConfig -> c -> SessionId -> IO ()
sendLastReply cfg chan sid = do
  let apiBase = gcApiBase (cccGateway cfg)
      mgr = cccHttpManager cfg
  eEntries <- httpGetTranscript mgr apiBase sid
  case eEntries of
    Left _ -> pure ()
    Right entries -> for_ (lastAssistantText entries) (ccSend chan)

-- | Handle a callback query (button tap) from the platform. The callback_data
-- is @"<8hex>:<index>"@. Resolves the 8-hex prefix to a pending ask, resolves
-- the index to the option label, answers via the HTTP API, acknowledges the
-- callback (dismiss the spinner), removes the keyboard, and sends a
-- @✓ <label>@ confirmation. If no pending ask matches, the callback is
-- silently dropped (stale button tap).
handleCallback
  :: ChatChannel c
  => ChatChannelConfig -> c -> SessionMap -> PendingAsks
  -> ConversationKey -> MessageSource -> Text
  -> IO ()
handleCallback cfg chan sessions pendingAsks key _src cbData = do
  case parseCallbackData cbData of
    Nothing -> pure ()  -- not a valid callback_data format
    Just (prefix, idx) -> do
      mSid <- sessionLookup sessions key
      case mSid of
        Nothing -> pure ()
        Just sid -> do
          asksMap <- readTVarIO pendingAsks
          case Map.lookup sid asksMap of
            Nothing -> pure ()
            Just asks ->
              case [ a | a <- asks, T.isPrefixOf prefix (paAskId a) ] of
                (ask : _) ->
                  case atIndex (paOptions ask) idx of
                    Nothing -> pure ()
                    Just opt -> do
                      let apiBase = gcApiBase (cccGateway cfg)
                          mgr = cccHttpManager cfg
                      -- Answer the question via the HTTP API.
                      _ <- httpAnswerQuestion mgr apiBase sid (paAskId ask) (qoLabel opt) "once"
                      -- Acknowledge the callback (dismiss spinner).
                      -- We don't have the callback_query_id here (it's in
                      -- the InboundMessage but not passed through). The
                      -- ccAnswerCallback method needs it. For now, skip
                      -- the callback ack — the button still works, the
                      -- spinner just persists a bit longer.
                      -- Send a confirmation to the chat.
                      ccSend chan ("✓ " <> qoLabel opt)
                      let remaining = filter (not . T.isPrefixOf prefix . paAskId) asks
                      atomically (modifyTVar' pendingAsks (Map.insert sid remaining))
                [] -> pure ()

-- | Handle a @lists@ WS event: compare the new tab list with the last known
-- one for this conversation. If the focused session's tab was removed (closed),
-- send the "tab closed" notification and clear the tracking state so the next
-- message creates a fresh tab.
handleLists
  :: ChatChannel c
  => ChatChannelConfig -> c -> ConversationKey
  -> TVar (Map ConversationKey (SessionId, [TabJson]))
  -> Value -> IO ()
handleLists cfg chan key tabTracker _val = do
  -- Fetch the current tabs from the gateway to get an accurate list.
  let apiBase = gcApiBase (cccGateway cfg)
      mgr = cccHttpManager cfg
  eTabs <- httpGetTabs mgr apiBase
  case eTabs of
    Left _ -> pure ()
    Right newTabs -> do
      tracker <- readTVarIO tabTracker
      case Map.lookup key tracker of
        Nothing -> pure ()  -- no tracked session for this conversation
        Just (focusedSid, _oldTabs) -> do
          -- Check if the focused session's tab was removed.
          let newSessionIds = mapMaybe tjSessionId newTabs
          if focusedSid `elem` mapMaybe mkSessionId' newSessionIds
            then do
              -- Tab still exists; update the tracked tab list.
              atomically (modifyTVar' tabTracker (Map.insert key (focusedSid, newTabs)))
            else do
              -- The focused session's tab was closed. Send the notification.
              ccSend chan ("tab closed (session " <> sessionIdText focusedSid
                        <> "); a new tab will be created on your next message")
              -- Clear the tracking state so the next message creates a fresh tab.
              atomically (modifyTVar' tabTracker (Map.delete key))
  where
    mkSessionId' t = case mkSessionId t of Right s -> Just s; Left _ -> Nothing

-- | Parse callback_data of the form @"<8hex>:<index>"@. Returns 'Nothing'
-- for malformed data. Pure.
parseCallbackData :: Text -> Maybe (Text, Int)
parseCallbackData cbData =
  case T.splitOn ":" cbData of
    [prefix, idxTxt]
      | T.length prefix == 8 && T.all isHexChar prefix
        -> case T.unpack idxTxt of
             [] -> Nothing
             s  -> case reads s of
                     [(n, "")] | n >= 0 -> Just (prefix, n)
                     _ -> Nothing
    _ -> Nothing
  where
    isHexChar c = isDigit c || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')

-- | Safe indexing: return the element at position @n@ or 'Nothing'.
atIndex :: [a] -> Int -> Maybe a
atIndex [] _ = Nothing
atIndex (x:_) 0 = Just x
atIndex (_:xs) n = atIndex xs (n - 1)

-- | Extract the @id@ field from an @ask@ event payload.
extractAskId :: Value -> Text
extractAskId val =
  case val of
    A.Object o -> fromMaybe "" (asText =<< KeyMap.lookup (Key.fromText "id") o)
    _ -> ""

-- | Extract the @options@ array from an @ask@ event payload. Each option
-- is a JSON object with @label@ and @description@ fields.
extractAskOptions :: Value -> [QuestionOption]
extractAskOptions val =
  case val of
    A.Object o -> case KeyMap.lookup (Key.fromText "options") o of
      Just (A.Array arr) -> mapMaybe parseOption (foldr (:) [] arr)
      _ -> []
    _ -> []
  where
    parseOption (A.Object ob) =
      QuestionOption
        <$> (asText =<< KeyMap.lookup (Key.fromText "label") ob)
        <*> pure (fromMaybe "" (asText =<< KeyMap.lookup (Key.fromText "description") ob))
    parseOption _ = Nothing

-- | Format a question + its options as a numbered list for chat channels
-- that don't support inline keyboards (Signal, CLI). Mirrors
-- 'Seal.Handles.AskReply.formatQuestionWithOptions'. Pure.
formatQuestionWithOptions :: Text -> [QuestionOption] -> Text
formatQuestionWithOptions question [] = question
formatQuestionWithOptions question opts =
  question
  <> "\n\n"
  <> T.intercalate "\n" (zipWith formatLine [1 :: Int ..] opts)
  <> "\n\nReply with a number or type your own answer."
  where
    formatLine n (QuestionOption lbl desc)
      | T.null desc = T.pack (show n <> ") ") <> lbl
      | otherwise   = T.pack (show n <> ") ") <> lbl <> " — " <> desc

-- ---------------------------------------------------------------------------
-- Pure helpers for extracting text from WS event payloads
-- ---------------------------------------------------------------------------

-- | Extract the accumulated text from an @entry-update@ or @entry@ event's
-- @entry@ payload. The payload is a JSON object with a @payload@ field
-- containing the message content.
extractEntryText :: Value -> Text
extractEntryText val =
  case val of
    A.Object o -> case KeyMap.lookup (Key.fromText "payload") o of
      Just (A.Object p) -> case KeyMap.lookup (Key.fromText "content") p of
        Just (A.Array arr) ->
          -- content is an array of {text: "...", type: "text"} blocks
          T.concat (mapMaybe extractTextBlock (toList arr))
        Just (A.String t) -> t
        _ -> ""
      Just (A.String t) -> t
      _ -> ""
    _ -> ""
  where
    extractTextBlock (A.Object b) = case KeyMap.lookup (Key.fromText "text") b of
      Just (A.String t) -> Just t
      _ -> Nothing
    extractTextBlock _ = Nothing
    toList = foldr (:) []

-- | Extract the @kind@ field from an @activity@ event payload.
extractActivityKind :: Value -> Text
extractActivityKind val =
  case val of
    A.Object o -> fromMaybe "" (asText =<< KeyMap.lookup (Key.fromText "kind") o)
    _ -> ""

-- | Extract the @direction@ field from an entry event payload.
-- Returns @""@ when absent. Used to filter request entries (direction
-- @"request"@) from response entries (direction @"response"@).
extractDirection :: Value -> Text
extractDirection val =
  case val of
    A.Object o -> fromMaybe "" (asText =<< KeyMap.lookup (Key.fromText "direction") o)
    _ -> ""

-- | Extract the @status@ field from an @activity@ event payload.
extractActivityStatus :: Value -> Text
extractActivityStatus val =
  case val of
    A.Object o -> fromMaybe "" (asText =<< KeyMap.lookup (Key.fromText "status") o)
    _ -> ""

-- | Extract the @tool@ field from a @tool-call@ activity event payload.
-- Returns 'Nothing' when the payload is not a @tool-call@ activity or the
-- @tool@ field is missing. Pure.
extractToolName :: Value -> Maybe Text
extractToolName val =
  case val of
    A.Object o
      | extractActivityKind val == "tool-call"
        -> asText =<< KeyMap.lookup (Key.fromText "tool") o
    _ -> Nothing

-- | Extract the @input@ field from a @tool-call@ activity event payload.
-- Returns 'Nothing' when the payload is not a @tool-call@ activity or the
-- @input@ field is missing. Pure.
extractToolInput :: Value -> Maybe Text
extractToolInput val =
  case val of
    A.Object o
      | extractActivityKind val == "tool-call"
        -> asText =<< KeyMap.lookup (Key.fromText "input") o
    _ -> Nothing

-- | Extract the @question@ field from an @ask@ event payload.
extractAskQuestion :: Value -> Text
extractAskQuestion val =
  case val of
    A.Object o -> fromMaybe "" (asText =<< KeyMap.lookup (Key.fromText "question") o)
    _ -> ""
lastAssistantText :: [Value] -> Maybe Text
lastAssistantText entries =
  case reverse (filter isAssistantEntry entries) of
    (e : _) -> Just (extractEntryText e)
    [] -> Nothing
  where
    isAssistantEntry (A.Object o) =
      case KeyMap.lookup (Key.fromText "direction") o of
        Just (A.String "response") -> True
        _ -> False
    isAssistantEntry _ = False

-- | Extract text from a JSON string value.
asText :: Value -> Maybe Text
asText (A.String t) = Just t
asText _ = Nothing
