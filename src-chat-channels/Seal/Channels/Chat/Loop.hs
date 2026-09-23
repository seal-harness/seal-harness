{-# LANGUAGE OverloadedStrings #-}
-- | The generic chat-channel main loop. Handles routing (@/N@ focus, slash
-- commands, plain text), WS focus + streaming, HTTP send, session tracking,
-- and ASK_HUMAN — all through the gateway API. The 'ChatChannel' instance
-- provides the platform-specific I/O.
module Seal.Channels.Chat.Loop
  ( runChatChannel
  , ChatChannelConfig (..)
  , defaultChatChannelConfig
    -- * Pure helpers (for testing)
  , extractEntryText
  , extractActivityKind
  , extractActivityStatus
  , extractToolName
  , extractToolInput
  , extractAskQuestion
  , lastAssistantText
  ) where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, modifyTVar', readTVarIO)
import Control.Monad (void, when, unless)
import Data.Foldable (for_)
import Data.Aeson (Value)
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef (readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Network.HTTP.Client (Manager)

import Seal.Channels.Chat.Class (ChatChannel (..))
import Seal.Channels.Chat.HttpClient
  (httpSend, httpGetTabs, httpNewSession, httpGetTranscript,
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
   newStreamingState)
import Seal.Channels.Chat.WsClient
  (WsClient (..), startWsClient)

import Seal.Gateway.Types.Core
  (SessionId, mkSessionId, sessionIdText)
import Seal.Gateway.Types.Stream (ServerEvent (..))
import Seal.Gateway.Types.Tab (TabIndex, tabIndexToInt, tabIndexToChar)

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

-- | Run the generic chat-channel loop. Blocks until the channel's
-- 'ccReceive' returns EOF. Each conversation gets its own WS connection
-- for streaming.
runChatChannel :: ChatChannel c => ChatChannelConfig -> c -> IO ()
runChatChannel cfg chan = do
  sessions <- newSessionMap
  -- Map of conversation keys to their WS client + streaming state.
  wsConns <- newTVarIO Map.empty :: IO (TVar (Map ConversationKey (WsClient, StreamingState)))
  loop sessions wsConns
  where
    loop sessions wsConns = do
      mMsg <- ccReceive chan
      case mMsg of
        Nothing -> pure ()  -- EOF
        Just (InboundMessage src body) -> do
          let key = convKeyFromSource src
          handleInbound cfg chan sessions wsConns key body
          loop sessions wsConns

-- | Handle one inbound message: resolve the session, route, and dispatch.
handleInbound
  :: ChatChannel c
  => ChatChannelConfig -> c -> SessionMap
  -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> ConversationKey -> Text
  -> IO ()
handleInbound cfg chan sessions wsConns key body = do
  let apiBase = gcApiBase (cccGateway cfg)
      mgr = cccHttpManager cfg
  -- First, check if this is a /tab focus N (intercepted locally).
  case parseTabFocus body of
    Just idx -> do
      handleFocus cfg chan sessions wsConns key idx
    Nothing -> case route body of
      Right (ChatFocus idx) ->
        handleFocus cfg chan sessions wsConns key idx
      Right (ChatInject idx payload) -> do
        -- Focus the tab, then send the payload as a plain message.
        handleFocus cfg chan sessions wsConns key idx
        sendPlain cfg chan sessions wsConns key payload
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
        handleNewSession cfg chan sessions wsConns key args
      Right (ChatSlash _cmd) ->
        sendSlash cfg chan sessions wsConns key body
      Right (ChatTabCommand _) ->
        -- Tab commands go through the HTTP API (the gateway routes them).
        sendSlash cfg chan sessions wsConns key body
      Right (ChatPlain text) ->
        sendPlain cfg chan sessions wsConns key text
      Left _ -> ccSend chan "error: invalid command"

-- | Handle a focus command: resolve the tab index to a session id via
-- @GET /api/tabs@, send a @FocusOp@ over WS, send "focused tab N" to the
-- platform, and optionally send the last assistant reply.
handleFocus
  :: ChatChannel c
  => ChatChannelConfig -> c -> SessionMap
  -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> ConversationKey -> TabIndex
  -> IO ()
handleFocus cfg chan sessions wsConns key idx = do
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
                -- Ensure a WS connection exists for this conversation.
                ensureWsConn cfg chan wsConns key sid
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
  -> ConversationKey -> SessionId
  -> IO ()
ensureWsConn cfg chan wsConns key sid = do
  let gwCfg = cccGateway cfg
  conns <- readTVarIO wsConns
  case Map.lookup key conns of
    Just (ws, _) -> wcFocus ws sid  -- already connected; just change focus
    Nothing -> do
      -- Start a new WS connection with the streaming event handler.
      let callback = handleServerEvent cfg chan key wsConns sid
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
  -> SessionId -> ServerEvent -> IO ()
handleServerEvent cfg chan key wsConns focusedSid ev =
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
      | sid == focusedSid -> handleAsk cfg chan key sid val
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
          writeIORef (ssAccumulated ss) text
          now <- getCurrentTime
          mLastEdit <- readIORef (ssLastEdit ss)
          mMsgId <- readIORef (ssMsgId ss)
          when (shouldEdit streamCfg now mLastEdit (T.length text)) $ do
            let content = addCursor streamCfg text
            case mMsgId of
              Nothing -> do
                mId <- ccSendWithId chan content
                case mId of
                  Just id' -> do
                    writeIORef (ssMsgId ss) (Just id')
                    writeIORef (ssLastEdit ss) (Just now)
                  Nothing -> pure ()
              Just id' -> do
                ok <- ccEditMessage chan id' content
                when ok $ writeIORef (ssLastEdit ss) (Just now)

-- | Handle an @entry@ event (complete transcript entry): finalize the
-- streaming bubble (edit without cursor).
handleEntry
  :: ChatChannel c
  => ChatChannelConfig -> c -> ConversationKey
  -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> Value -> IO ()
handleEntry cfg chan key wsConns val = do
  conns <- readTVarIO wsConns
  case Map.lookup key conns of
    Nothing -> pure ()
    Just (_, ss) -> do
      let streamCfg = cccStreamCfg cfg
          text = extractEntryText val
      if T.null text
        then pure ()
        else do
          mMsgId <- readIORef (ssMsgId ss)
          let finalText = stripCursor streamCfg text
          case mMsgId of
            Nothing -> void (ccSendWithId chan finalText)
            Just id' -> do
              ok <- ccEditMessage chan id' finalText
              unless ok $ void (ccSendWithId chan finalText)
          -- Reset streaming state for the next turn.
          writeIORef (ssMsgId ss) Nothing
          writeIORef (ssAccumulated ss) ""
          writeIORef (ssLastEdit ss) Nothing

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
    "tool-call" -> handleToolCallActivity cfg chan key val
    _ -> pure ()

-- | Handle a @harness-status@ activity: if status is idle, finalize any
-- in-progress streaming bubble.
handleHarnessStatus
  :: ChatChannel c
  => ChatChannelConfig -> c -> ConversationKey
  -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> Value -> IO ()
handleHarnessStatus cfg chan key wsConns val = do
    let status = extractActivityStatus val
    when (status == "idle") $ do
      conns <- readTVarIO wsConns
      case Map.lookup key conns of
        Nothing -> pure ()
        Just (_, ss) -> do
          mMsgId <- readIORef (ssMsgId ss)
          accum <- readIORef (ssAccumulated ss)
          when (isJust mMsgId && not (T.null accum)) $ do
            let streamCfg = cccStreamCfg cfg
                finalText = stripCursor streamCfg accum
            case mMsgId of
              Just id' -> do
                ok <- ccEditMessage chan id' finalText
                unless ok $ void (ccSendWithId chan finalText)
              Nothing -> pure ()
          writeIORef (ssMsgId ss) Nothing
          writeIORef (ssAccumulated ss) ""
          writeIORef (ssLastEdit ss) Nothing

-- | Handle a @tool-call@ activity: send the tool-progress line to the
-- platform as a separate message. This renders the tool-call progress
-- bubble (tool name + truncated/redacted input) that the user sees while
-- the agent is executing tools.
handleToolCallActivity
  :: ChatChannel c
  => ChatChannelConfig -> c -> ConversationKey -> Value
  -> IO ()
handleToolCallActivity _cfg chan _key val = do
  case extractToolName val of
    Nothing -> pure ()
    Just toolName -> do
      let mInput = extractToolInput val
          line = case mInput of
            Just inp | not (T.null inp) -> toolName <> " " <> inp
            _ -> toolName
      ccSend chan line

-- | Handle an @ask@ event: render the question on the platform. The answer
-- will come as the next inbound message (the loop's normal receive path).
-- For now, we send the question text and wait — the ASK_HUMAN answer flow
-- will be fully wired in a follow-up (it requires matching the next
-- inbound message to the pending ask id).
handleAsk
  :: ChatChannel c
  => ChatChannelConfig -> c -> ConversationKey -> SessionId -> Value
  -> IO ()
handleAsk _cfg chan _key _sid val = do
  let question = extractAskQuestion val
  ccSend chan question

-- | Send a plain text message via the HTTP API. Resolves the conversation's
-- session (creating one if it doesn't exist yet).
sendPlain
  :: ChatChannel c
  => ChatChannelConfig -> c -> SessionMap -> TVar (Map ConversationKey (WsClient, StreamingState)) -> ConversationKey -> Text
  -> IO ()
sendPlain cfg chan sessions wsConns key text = do
  sid <- resolveSession cfg chan sessions wsConns key
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
  => ChatChannelConfig -> c -> SessionMap -> TVar (Map ConversationKey (WsClient, StreamingState)) -> ConversationKey -> Text
  -> IO ()
sendSlash = sendPlain  -- same mechanism; the gateway routes slash commands

-- | Handle /new: create a new session via HTTP, update the session map.
handleNewSession
  :: ChatChannel c
  => ChatChannelConfig -> c -> SessionMap -> TVar (Map ConversationKey (WsClient, StreamingState)) -> ConversationKey -> Text
  -> IO ()
handleNewSession cfg chan sessions wsConns key _args = do
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
        ensureWsConn cfg chan wsConns key sid
        ccSend chan ("new session " <> sessionIdText sid)

-- | Resolve the conversation's session. If the conversation has no session
-- yet, create one via the HTTP API.
resolveSession
  :: ChatChannel c => ChatChannelConfig -> c -> SessionMap -> TVar (Map ConversationKey (WsClient, StreamingState)) -> ConversationKey
  -> IO SessionId
resolveSession cfg chan sessions wsConns key = do
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
            ensureWsConn cfg chan wsConns key sid
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

-- | Map maybe helper (to avoid importing Data.Maybe.mapMaybe explicitly).
mapMaybe :: (a -> Maybe b) -> [a] -> [b]
mapMaybe _ [] = []
mapMaybe f (x:xs) = case f x of
  Just b -> b : mapMaybe f xs
  Nothing -> mapMaybe f xs
