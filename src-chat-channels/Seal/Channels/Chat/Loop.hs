{-# LANGUAGE OverloadedStrings #-}
-- | The generic chat-channel main loop. Handles routing (@/N@ focus, slash
-- commands, plain text), WS focus + streaming, HTTP send, session tracking,
module Seal.Channels.Chat.Loop
  ( runChatChannel
  , ChatChannelConfig (..)
  , defaultChatChannelConfig
    -- * Event handlers (for testing)
  , handleInbound
  , handleFocus
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
  , extractThinkingSessionIds
  , lastAssistantText
  , formatQuestionWithOptions
  , parseCallbackData
    -- * Watch-all-tabs (for testing)
  , WatchState
  , ThinkingTabs
  , newWatchState
  , newThinkingTabs
  , handleWatchToggle
  , handleWatchActivity
  , lookupWatch
  , toggleWatch
  , newPersistingWatchState
  , seedWatchState
  , snapshotWatch
  ) where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, modifyTVar', readTVar, readTVarIO, writeTVar)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (SomeException, catch)
import Control.Monad (when, unless, void)
import Data.Foldable (for_)
import Data.Aeson (Value)
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef (readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Char (isDigit)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import System.IO (hPutStrLn, stderr)
import Network.HTTP.Client (Manager)

import Seal.Channels.Chat.Class (ChatChannel (..), QuestionOption (..))
import Seal.Channels.Chat.HttpClient
  (httpSend, httpGetTabs, httpGetSessions, httpNewSession, httpGetTranscript, httpAnswerQuestion,
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
import Seal.Gateway.Types.Tab (TabIndex, mkTabIndex, tabIndexToInt, tabIndexToChar)

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

-- | Per-conversation watch-all-tabs toggle state. When 'True' for a
-- conversation, the channel receives a notification every time any
-- non-focused tab finishes thinking (harness-status transitions from
-- @thinking@ to @idle@). Thread-safe via 'TVar'.
data WatchState = WatchState
  { wsVar  :: TVar (Map ConversationKey Bool)
  , wsSave :: Maybe (IO ())
  -- ^ The save action (snapshots the TVar and writes to disk). Called
  -- inside the 'wsLock' critical section so the snapshot is consistent
  -- with the mutation.
  , wsLock :: MVar ()
  -- ^ Serializes the mutation+persist sequence so a stale snapshot from
  -- one thread cannot overwrite a newer on-disk write from another.
  -- Without this lock, concurrent toggles from Signal + Telegram (which
  -- share one 'WatchState') can lose state after a restart.
  }

-- | Create a new empty watch-state map (watch mode off for all
-- conversations).
newWatchState :: IO WatchState
newWatchState = do
  tv <- newTVarIO Map.empty
  lock <- newMVar ()
  pure (WatchState tv Nothing lock)

-- | Create a persisting watch-state store. The supplied save function is
-- called after every mutation (snapshotting the full current map, so the
-- last writer wins with a consistent view). Mirrors
-- 'Seal.Channels.Cursor.newPersistingCursorStore'.
newPersistingWatchState :: (Map ConversationKey Bool -> IO ()) -> IO WatchState
newPersistingWatchState saveFn = do
  tv <- newTVarIO Map.empty
  lock <- newMVar ()
  let ws = WatchState tv (Just (saveAction ws)) lock
      saveAction s = saveFn =<< snapshotWatch s
  pure ws

-- | Replace the store's map in one STM transaction. Used at boot to seed
-- the in-memory store from the persisted @watch_state.json@. Does NOT
-- persist (the caller is loading FROM disk).
seedWatchState :: WatchState -> Map ConversationKey Bool -> IO ()
seedWatchState ws m = atomically (writeTVar (wsVar ws) m)

-- | Snapshot the current map. Used by the save action.
snapshotWatch :: WatchState -> IO (Map ConversationKey Bool)
snapshotWatch ws = readTVarIO (wsVar ws)

-- | Look up whether watch mode is enabled for a conversation. 'False'
-- when the conversation has no entry (the default).
lookupWatch :: WatchState -> ConversationKey -> IO Bool
lookupWatch ws key = fromMaybe False . Map.lookup key <$> readTVarIO (wsVar ws)

-- | Toggle watch mode for a conversation. Returns the new state.
toggleWatch :: WatchState -> ConversationKey -> IO Bool
toggleWatch ws key = do
  -- Hold the lock through mutation+persist so no concurrent thread can
  -- mutate the TVar between our snapshot and our save (which would let a
  -- stale snapshot overwrite a newer on-disk write).
  withMVar (wsLock ws) $ \_ -> do
    newVal <- atomically $ do
      m <- readTVar (wsVar ws)
      let v = not (fromMaybe False (Map.lookup key m))
      writeTVar (wsVar ws) (Map.insert key v m)
      pure v
    persistWatch ws
    pure newVal

-- | Run the persist action (if any) after a successful mutation. A save
-- failure is logged to stderr and swallowed — the in-memory store stays
-- authoritative within the session; the next successful mutation will
-- retry the save (writing the full current map, so a missed save
-- self-heals). Mirrors 'Seal.Channels.Cursor.persistCursor'.
persistWatch :: WatchState -> IO ()
persistWatch ws =
  case wsSave ws of
    Nothing  -> pure ()
    Just act -> act `catch` \e ->
      dbg ("[watch] watch_state.json save failed: " <> T.pack (show (e :: SomeException)))

-- | Per-conversation set of non-focused sessions currently in a thinking
-- turn. Used to detect the thinking→idle transition so a watch
-- notification is sent exactly once per completed turn (not on every
-- idle activity for a session that was never thinking). Thread-safe via
-- 'TVar'.
type ThinkingTabs = TVar (Map ConversationKey (Set SessionId))

-- | Create a new empty thinking-tabs map.
newThinkingTabs :: IO ThinkingTabs
newThinkingTabs = newTVarIO Map.empty

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
runChatChannel :: ChatChannel c => ChatChannelConfig -> c -> WatchState -> IO ()
runChatChannel cfg chan watchState = do
  sessions <- newSessionMap
  -- Map of conversation keys to their WS client + streaming state.
  wsConns <- newTVarIO Map.empty :: IO (TVar (Map ConversationKey (WsClient, StreamingState)))
  pendingAsks <- newTVarIO Map.empty :: IO PendingAsks
  tabTracker <- newTVarIO Map.empty :: IO (TVar (Map ConversationKey (SessionId, [TabJson])))
  thinkingTabs <- newThinkingTabs
  loop sessions wsConns pendingAsks tabTracker watchState thinkingTabs
  where
    loop sessions wsConns pendingAsks tabTracker ws tt = do
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
              handleInbound cfg chan sessions wsConns pendingAsks tabTracker ws tt key body
          loop sessions wsConns pendingAsks tabTracker ws tt

-- | Handle one inbound message: resolve the session, route, and dispatch.
handleInbound
  :: ChatChannel c
  => ChatChannelConfig -> c -> SessionMap
  -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> PendingAsks
  -> TVar (Map ConversationKey (SessionId, [TabJson]))
  -> WatchState
  -> ThinkingTabs
  -> ConversationKey -> Text
  -> IO ()
handleInbound cfg chan sessions wsConns pendingAsks tabTracker watchState thinkingTabs key body = do
  let apiBase = gcApiBase (cccGateway cfg)
      mgr = cccHttpManager cfg
  -- Intercept /watch (and /watch on|off) before normal routing — it
  -- toggles per-conversation loop state, not a gateway command.
  if isWatchCommand body
    then do
      dbg ("[watch] /watch command received, key=" <> ckConv key)
      handleWatchToggle chan watchState key body
      -- When watch mode is turned ON, ensure a WS connection exists so
      -- the channel receives BeActivity events for all tabs. Without
      -- this, /watch as the first message would enable watch mode but
      -- never receive any events (no WS connection = no event source).
      watchOn <- lookupWatch watchState key
      dbg ("[watch] watchOn=" <> (if watchOn then "true" else "false") <> ", ensuring WS conn")
      when watchOn $
        void (resolveSession cfg chan sessions wsConns pendingAsks tabTracker watchState thinkingTabs key)
    else case parseTabFocus body of
    Just idx -> do
      handleFocus cfg chan sessions wsConns pendingAsks tabTracker watchState thinkingTabs key idx
    Nothing -> case route body of
      Right (ChatFocus idx) ->
        handleFocus cfg chan sessions wsConns pendingAsks tabTracker watchState thinkingTabs key idx
      Right (ChatInject idx payload) -> do
        -- Send the payload to the target tab's session WITHOUT changing
        -- the focused tab (no FocusOp, no "focused tab N" confirmation).
        handleInject cfg chan idx payload
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
        handleNewSession cfg chan sessions wsConns pendingAsks tabTracker watchState thinkingTabs key args
      Right (ChatSlash _cmd) ->
        sendSlash cfg chan sessions wsConns pendingAsks tabTracker watchState thinkingTabs key body
      Right (ChatTabCommand _) ->
        -- Tab commands go through the HTTP API (the gateway routes them).
        sendSlash cfg chan sessions wsConns pendingAsks tabTracker watchState thinkingTabs key body
      Right (ChatPlain text) ->
        sendPlain cfg chan sessions wsConns pendingAsks tabTracker watchState thinkingTabs key text
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
  -> WatchState
  -> ThinkingTabs
  -> ConversationKey -> TabIndex
  -> IO ()
handleFocus cfg chan sessions wsConns pendingAsks tabTracker watchState thinkingTabs key idx = do
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
                ensureWsConn cfg chan wsConns pendingAsks tabTracker watchState thinkingTabs key sid
                -- Send "focused tab N" confirmation.
                ccSend chan ("focused tab " <> T.singleton (tabIndexToChar idx))
                -- Fetch and send the last assistant reply for context.
                sendLastReply cfg chan sid

-- | Handle an inject command (@\/N payload@): resolve the tab index to a
-- session id via @GET /api/tabs@, then send the payload to that session
-- via @POST /api/sessions/:id/send@. Unlike 'handleFocus', this does NOT
-- change the focused tab, send a FocusOp over WS, update the session map,
-- send a "focused tab N" confirmation, or send the last assistant reply.
-- The payload is delivered to the target session; any response will be
-- visible when the user later focuses on that tab.
handleInject
  :: ChatChannel c
  => ChatChannelConfig -> c -> TabIndex -> Text
  -> IO ()
handleInject cfg chan idx payload = do
  let apiBase = gcApiBase (cccGateway cfg)
      mgr = cccHttpManager cfg
  eTabs <- httpGetTabs mgr apiBase
  case eTabs of
    Left e -> ccSend chan ("inject failed: " <> e)
    Right tabs ->
      case [ t | t <- tabs, tjIndex t == tabIndexToInt idx ] of
        [] -> ccSend chan "inject failed: tab index out of range"
        (tab : _) ->
          case tjSessionId tab of
            Nothing -> ccSend chan "inject failed: tab has no session"
            Just sidText -> case mkSessionId sidText of
              Left _ -> ccSend chan "inject failed: invalid session id"
              Right sid -> do
                -- Send the payload to the target session via HTTP.
                -- Do NOT update the session map, send a FocusOp, or
                -- send a focus confirmation — the current focused tab
                -- is unchanged.
                eResult <- httpSend mgr apiBase sid payload
                case eResult of
                  Right sr | srKind sr == "error" -> ccSend chan (fromMaybe "error" (srError sr))
                  Right sr | not (T.null (srResponse sr)) -> ccSend chan (srResponse sr)
                  Right _ -> pure ()  -- assistant response comes via WS
                  Left e -> ccSend chan ("error: " <> e)

-- | Ensure a WS connection exists for the conversation. If one exists,
-- send a FocusOp to change focus. If not, start a new WS connection with
-- the streaming event handler and send a FocusOp.
ensureWsConn
  :: ChatChannel c
  => ChatChannelConfig -> c
  -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> PendingAsks
  -> TVar (Map ConversationKey (SessionId, [TabJson]))
  -> WatchState
  -> ThinkingTabs
  -> ConversationKey -> SessionId
  -> IO ()
ensureWsConn cfg chan wsConns pendingAsks tabTracker watchState thinkingTabs key sid = do
  let gwCfg = cccGateway cfg
  conns <- readTVarIO wsConns
  dbg ("[watch] ensureWsConn key=" <> ckConv key <> " hasConn=" <> (case Map.lookup key conns of Just _ -> "true"; Nothing -> "false"))
  case Map.lookup key conns of
    Just (ws, _) -> wcFocus ws sid  -- already connected; just change focus
    Nothing -> do
      -- Start a new WS connection with the streaming event handler.
      let callback = handleServerEvent cfg chan key wsConns pendingAsks tabTracker watchState thinkingTabs sid
      eWs <- startWsClient (gcHost gwCfg) (gcWsPort gwCfg) callback
      case eWs of
        Left e -> dbg ("[watch] WS connect FAILED: " <> e)
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
  -> WatchState
  -> ThinkingTabs
  -> SessionId -> ServerEvent -> IO ()
handleServerEvent cfg chan key wsConns pendingAsks tabTracker watchState thinkingTabs focusedSid ev =
  case ev of
    SeEntryUpdate sid val
      | sid == focusedSid -> handleEntryUpdate cfg chan key wsConns val
    SeEntry sid val
      | sid == focusedSid -> handleEntry cfg chan key wsConns val
    SeActivity sid val
      | sid == focusedSid -> do
          dbg ("[watch] SeActivity focused sid=" <> sessionIdText sid <> " kind=" <> extractActivityKind val <> " status=" <> extractActivityStatus val)
          handleActivity cfg chan key wsConns val
      | otherwise         -> do
          dbg ("[watch] SeActivity non-focused sid=" <> sessionIdText sid <> " focusedSid=" <> sessionIdText focusedSid <> " kind=" <> extractActivityKind val <> " status=" <> extractActivityStatus val)
          handleWatchActivity cfg chan key watchState thinkingTabs focusedSid sid val
    -- Tool-call events are BeActivity with kind="tool-call", broadcast
    -- by the server's aeOnToolCall hook. They arrive as SeActivity.
    -- handleActivity dispatches on kind internally.
    SeAsk sid val
      | sid == focusedSid -> handleAsk cfg chan key pendingAsks sid val
    SeLists val -> handleLists cfg chan key tabTracker watchState thinkingTabs val
    _ -> pure ()  -- ignore events for other sessions or irrelevant types

-- | Check whether the inbound body is a @/watch@ command (bare @/watch@,
-- or @/watch on@ / @/watch off@ / @/watch status@ / @/watch -h@). Pure.
isWatchCommand :: Text -> Bool
isWatchCommand body =
  case T.words (T.toLower (T.strip body)) of
    ["/watch"]           -> True
    ["/watch", "on"]     -> True
    ["/watch", "off"]    -> True
    ["/watch", "status"] -> True
    ["/watch", "-h"]     -> True
    _                    -> False

-- | Handle the @/watch@ slash command: toggle (or set) watch-all-tabs
-- mode for the conversation and send a confirmation to the platform.
-- @/watch@ toggles; @/watch on@ and @/watch off@ set explicitly;
-- @/watch status@ prints the current state; @/watch -h@ prints help.
handleWatchToggle
  :: ChatChannel c => c -> WatchState -> ConversationKey -> Text -> IO ()
handleWatchToggle chan watchState key body =
  case T.words (T.toLower body) of
    ["/watch", "on"]  -> setWatch True
    ["/watch", "off"] -> setWatch False
    ["/watch", "status"] -> do
      cur <- lookupWatch watchState key
      ccSend chan (watchStatusMsg cur)
    ["/watch", "-h"] -> ccSend chan watchHelp
    _ -> do  -- bare /watch — toggle
      cur <- lookupWatch watchState key
      dbg ("[watch] toggle: currently " <> (if cur then "on" else "off"))
      newVal <- toggleWatch watchState key
      ccSend chan (watchConfirm newVal)
  where
    setWatch v = do
      -- Hold the lock through mutation+persist (same reason as
      -- 'toggleWatch').
      withMVar (wsLock watchState) $ \_ -> do
        atomically (modifyTVar' (wsVar watchState) (Map.insert key v))
        persistWatch watchState
      ccSend chan (watchConfirm v)

-- | The confirmation message for a watch-mode change.
watchConfirm :: Bool -> Text
watchConfirm True =
  "watch mode enabled — you will be notified when any tab finishes thinking"
watchConfirm False =
  "watch mode disabled"

-- | The status message for the current watch-mode state.
watchStatusMsg :: Bool -> Text
watchStatusMsg True  = "watch mode is on"
watchStatusMsg False = "watch mode is off"

-- | The help text for @/watch@, rendered in the same style as the
-- optparse-applicative help used by all other slash commands.
watchHelp :: Text
watchHelp = T.unlines
  [ "Toggle watch-all-tabs notifications for this conversation"
  , ""
  , "Usage: /watch [on|off|status]"
  , ""
  , "Available commands:"
  , "  on          Enable watch mode — notify when any tab finishes thinking"
  , "  off         Disable watch mode"
  , "  status      Show the current watch mode state"
  , ""
  , "Options:"
  , "  -h          Show this help"
  , ""
  , "With no subcommand, /watch toggles the current state."
  ]

-- | Handle a @harness-status@ activity event for a non-focused session.
-- When watch mode is enabled for the conversation:
--
-- * @thinking@ — record the session as thinking (so we can detect the
--   transition to @idle@).
-- * @idle@ — if the session was previously thinking, remove it from the
--   thinking set and send a \"tab finished thinking\" notification with
--   the last assistant reply.
--
-- When watch mode is disabled, this is a no-op.
handleWatchActivity
  :: ChatChannel c
  => ChatChannelConfig -> c -> ConversationKey
  -> WatchState -> ThinkingTabs
  -> SessionId -> SessionId -> Value -> IO ()
handleWatchActivity cfg chan key watchState thinkingTabs _focusedSid sid val = do
  watchOn <- lookupWatch watchState key
  dbg ("[watch] handleWatchActivity sid=" <> sessionIdText sid <> " watchOn=" <> (if watchOn then "true" else "false"))
  when watchOn $ do
    let kind = extractActivityKind val
    dbg ("[watch] kind=" <> kind <> " status=" <> extractActivityStatus val)
    case kind of
      "harness-status" -> do
        let status = extractActivityStatus val
        case status of
          "thinking" -> do
            dbg ("[watch] adding to thinking set: sid=" <> sessionIdText sid)
            atomically (modifyTVar' thinkingTabs (Map.insertWith Set.union key (Set.singleton sid)))
          "idle" -> do
            wasThinking <- atomically $ do
              m <- readTVar thinkingTabs
              case Map.lookup key m of
                Just sids | sid `Set.member` sids -> do
                  let sids' = Set.delete sid sids
                  writeTVar thinkingTabs (if Set.null sids' then Map.delete key m else Map.insert key sids' m)
                  pure True
                _ -> pure False
            dbg ("[watch] idle received, wasThinking=" <> (if wasThinking then "true" else "false") <> " sid=" <> sessionIdText sid)
            when wasThinking $
              sendWatchNotification cfg chan sid
          _ -> pure ()
      _ -> pure ()

-- | Send a \"tab finished thinking\" notification to the channel. Fetches
-- the tab list (to resolve the tab label) and the transcript (to get the
-- last assistant reply). If either fetch fails, the notification is still
-- sent with whatever information is available — the notification must not
-- be silently dropped just because a gateway call failed.
sendWatchNotification
  :: ChatChannel c
  => ChatChannelConfig -> c -> SessionId -> IO ()
sendWatchNotification cfg chan sid = do
  let apiBase = gcApiBase (cccGateway cfg)
      mgr = cccHttpManager cfg
      sidText = sessionIdText sid
  dbg ("[watch] sendWatchNotification sid=" <> sidText)
  -- Resolve the tab index (for the "Tab N" prefix) from GET /api/tabs,
  -- and the session display title (the same label the web frontend's
  -- sidebar shows) from GET /api/sessions. The title cascade mirrors
  -- the frontend's sessionDisplayTitle: description, autoSummary,
  -- firstMessageSnippet, agent, short id.
  tabIdx <- do
    eTabs <- httpGetTabs mgr apiBase
    case eTabs of
      Right tabs ->
        case [ t | t <- tabs, tjSessionId t == Just sidText ] of
          (t : _) -> pure (case mkTabIndex (tjIndex t) of
            Right idx -> T.singleton (tabIndexToChar idx)
            Left _    -> T.pack (show (tjIndex t)))
          []      -> pure "?"
      Left _ -> pure "?"
  sessionTitle <- do
    eSessions <- httpGetSessions mgr apiBase
    case eSessions of
      Right sessions ->
        case [ s | s <- sessions, sessionJsonId s == Just sidText ] of
          (s : _) -> pure (sessionDisplayTitle s)
          []      -> pure sidText
      Left _ -> pure sidText
  mReply <- do
    eEntries <- httpGetTranscript mgr apiBase sid
    case eEntries of
      Right entries -> pure (lastAssistantText entries)
      Left _        -> pure Nothing
  dbg ("[watch] notification tabIdx=" <> tabIdx <> " sessionTitle=" <> sessionTitle <> " hasReply=" <> (case mReply of Just _ -> "true"; Nothing -> "false"))
  let header = "\x1F4D4 Tab " <> tabIdx <> " (" <> sessionTitle <> ") finished thinking"
  case mReply of
    Just reply | not (T.null reply) -> ccSend chan (header <> ":\n" <> reply)
    _ -> ccSend chan header

-- | Extract the @id@ field from a session info JSON object (from
-- @GET /api/sessions@). Returns 'Nothing' when the field is missing or
-- not a string. Pure.
sessionJsonId :: Value -> Maybe Text
sessionJsonId (A.Object o) = asText =<< KeyMap.lookup (Key.fromText "id") o
sessionJsonId _ = Nothing

-- | Derive the display title from a session info JSON object, mirroring
-- the web frontend's @sessionDisplayTitle@ cascade:
-- @description -> autoSummary -> firstMessageSnippet -> agent -> short id@.
-- Pure.
sessionDisplayTitle :: Value -> Text
sessionDisplayTitle val =
  case val of
    A.Object o ->
      fromMaybe (shortId o) (firstNonEmpty
        [ asText =<< KeyMap.lookup (Key.fromText "description") o
        , asText =<< KeyMap.lookup (Key.fromText "auto_summary") o
        , asText =<< KeyMap.lookup (Key.fromText "autoSummary") o
        , asText =<< KeyMap.lookup (Key.fromText "first_message_snippet") o
        , asText =<< KeyMap.lookup (Key.fromText "firstMessageSnippet") o
        , asText =<< KeyMap.lookup (Key.fromText "agent") o
        ])
    _ -> "?"
  where
    firstNonEmpty = foldr (\m acc -> case m of
      Just t | not (T.null t) -> Just t
      _                       -> acc) Nothing
    shortId o =
      maybe "?" (T.take 12)
        (asText =<< KeyMap.lookup (Key.fromText "id") o)


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
            -- For channels that don't support streaming (Signal), just
            -- accumulate the text without sending intermediate edits.
            -- The final text is sent as a single message when the
            -- recorded entry or idle status arrives (finalizeBubble).
            when (ccSupportsStreaming chan) $ do
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
              -- For non-streaming channels, the recorded entry's text
              -- is the authoritative full response — send it even if
              -- we already sent the accumulated text via idle (the
              -- recorded entry is the canonical source). Skip if we
              -- already delivered via finalizeBubble (mMsgId was set
              -- and finalized).
              alreadyDelivered <- readIORef (ssFinalized ss)
              if alreadyDelivered
                then pure ()
                else finalizeBubble cfg chan ss text True

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
            -- For non-streaming channels (Signal), the accumulated text
            -- is the full response. Send it as a new message (mMsgId is
            -- Nothing because no streaming bubble was created). For
            -- streaming channels, only finalize if there's an active
            -- streaming bubble (mMsgId is Just).
            -- Don't mark as finalized — the recorded entry is the
            -- canonical finalize path. This is just a safety net.
            when (not (T.null accum) &&
                  (not (ccSupportsStreaming chan) || isJust mMsgId)) $
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
    -- For non-streaming channels, finalize when there's accumulated text
    -- even without a streaming bubble (mMsgId is Nothing). For streaming
    -- channels, only finalize when there's an in-progress bubble.
    when (not (T.null accum) &&
          (not (ccSupportsStreaming chan) || isJust mMsgId)) $
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
  -> WatchState -> ThinkingTabs
  -> ConversationKey -> Text
  -> IO ()
sendPlain cfg chan sessions wsConns pendingAsks tabTracker watchState thinkingTabs key text = do
  sid <- resolveSession cfg chan sessions wsConns pendingAsks tabTracker watchState thinkingTabs key
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
  -> WatchState -> ThinkingTabs
  -> ConversationKey -> Text
  -> IO ()
sendSlash = sendPlain  -- same mechanism; the gateway routes slash commands

-- | Handle /new: create a new session via HTTP, update the session map.
handleNewSession
  :: ChatChannel c
  => ChatChannelConfig -> c -> SessionMap -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> PendingAsks -> TVar (Map ConversationKey (SessionId, [TabJson]))
  -> WatchState -> ThinkingTabs
  -> ConversationKey -> Text
  -> IO ()
handleNewSession cfg chan sessions wsConns pendingAsks tabTracker watchState thinkingTabs key _args = do
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
        ensureWsConn cfg chan wsConns pendingAsks tabTracker watchState thinkingTabs key sid
        ccSend chan ("new session " <> sessionIdText sid)

-- | Resolve the conversation's session. If the conversation has no session
-- yet, create one via the HTTP API.
resolveSession
  :: ChatChannel c => ChatChannelConfig -> c -> SessionMap -> TVar (Map ConversationKey (WsClient, StreamingState))
  -> PendingAsks -> TVar (Map ConversationKey (SessionId, [TabJson]))
  -> WatchState -> ThinkingTabs
  -> ConversationKey
  -> IO SessionId
resolveSession cfg chan sessions wsConns pendingAsks tabTracker watchState thinkingTabs key = do
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
            ensureWsConn cfg chan wsConns pendingAsks tabTracker watchState thinkingTabs key sid
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
-- message creates a fresh tab. Also seeds the 'ThinkingTabs' set from the
-- snapshot's @thinkingSessionIds@ so tabs already thinking before the WS
-- connection was established still trigger a finished notification.
handleLists
  :: ChatChannel c
  => ChatChannelConfig -> c -> ConversationKey
  -> TVar (Map ConversationKey (SessionId, [TabJson]))
  -> WatchState -> ThinkingTabs -> Value -> IO ()
handleLists cfg chan key tabTracker watchState thinkingTabs val = do
  -- Seed the thinking-tabs set from the snapshot's thinkingSessionIds.
  -- This is the core fix for the "missed thinking event" problem: when a
  -- WS connection is established (or a lists snapshot is broadcast on tab
  -- changes), sessions that were already thinking before the connection
  -- existed are included in the snapshot. Without this seeding, the
  -- ThinkingTabs set starts empty and the thinking→idle transition is
  -- never detected for those sessions (the idle event arrives but
  -- wasThinking is false → no notification).
  seedThinkingTabsFromLists watchState thinkingTabs key val
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

-- | Seed the 'ThinkingTabs' set for a conversation from the
-- @thinkingSessionIds@ field in a @lists@ WS event payload. This ensures
-- sessions that were already thinking before the WS connection was
-- established are tracked, so their eventual @idle@ transition triggers a
-- watch notification. Replaces the per-conversation thinking set (rather
-- than unioning) so sessions that finished between snapshots are not kept
-- stale — the next @thinking@ activity event will re-add them if needed.
-- No-op when watch mode is off (the thinking set is only consulted by
-- 'handleWatchActivity', which itself checks watch mode, but seeding
-- when off would waste memory for no benefit).
seedThinkingTabsFromLists :: WatchState -> ThinkingTabs -> ConversationKey -> Value -> IO ()
seedThinkingTabsFromLists watchState thinkingTabs key val = do
  watchOn <- lookupWatch watchState key
  when watchOn $ do
    let sids = extractThinkingSessionIds val
    unless (null sids) $ do
      dbg ("[watch] seeding thinking tabs from lists snapshot: key=" <> ckConv key
        <> " count=" <> T.pack (show (length sids)))
      atomically (modifyTVar' thinkingTabs (Map.insert key (Set.fromList sids)))

-- | Extract the @thinkingSessionIds@ array from a @lists@ WS event
-- payload. Returns the list of valid 'SessionId's. Pure.
extractThinkingSessionIds :: Value -> [SessionId]
extractThinkingSessionIds val =
  case val of
    A.Object o -> case KeyMap.lookup (Key.fromText "thinkingSessionIds") o of
      Just (A.Array arr) -> mapMaybe (\case
        A.String t -> either (const Nothing) Just (mkSessionId t)
        _           -> Nothing) (foldr (:) [] arr)
      _ -> []
    _ -> []

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
