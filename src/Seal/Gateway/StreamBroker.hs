{-# LANGUAGE OverloadedStrings #-}
-- | The in-process broker that fans 'BrokerEvent's to every subscribed WS
-- connection, filtering by each connection's focused session. STM-backed:
-- a 'TVar' of subscribers + a global cap.
--
-- 'BrokerEvent' is re-exported from 'Seal.Gateway.Types.Stream' (the
-- canonical home in the 'seal-gateway-types' library stanza). The runtime
-- types ('Subscriber', 'StreamBroker') and all IO functions stay here
-- because they carry STM state — a server-internal concern.
module Seal.Gateway.StreamBroker
  ( BrokerEvent (..)
  , Subscriber (..)
  , StreamBroker (..)
  , newStreamBroker
  , subscribe
  , updateSubscriberSession
  , broadcast
  , takeNewEntries
  , readEntryCursor
  , broadcastLists
  , broadcastAgentDefsChanged
  , broadcastSkillsChanged
  , broadcastReposChanged
  , subscriberCount
  , thinkingSessions
  , setThinking
  , reconcileStaleThinking
  ) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, stateTVar, writeTVar)
import Control.Exception (SomeException, catch)
import Control.Monad (when, unless, filterM, forM_)
import Data.Aeson (Value, object, (.=))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime, diffUTCTime)

import Seal.Gateway.Types.Core (SessionId)
import Seal.Gateway.Types.Stream (BrokerEvent (..))

-- | The per-subscriber state: the focused session (via an 'TVar' so the
-- connection thread can update it on focus without re-subscribing), a
-- send action, and an optional close action. The close action is called
-- when 'subSend' throws (dead connection) so the WS socket is actively
-- closed — this triggers the client's @onclose@ handler and reconnect
-- rather than leaving a zombie connection that never receives another
-- event but also never detects the failure.
data Subscriber = Subscriber
  { subSessionRef :: TVar SessionId
  , subSend       :: BrokerEvent -> IO ()
  , subClose      :: IO ()
  }

-- | The in-process broker. STM-backed: a 'TVar' of subscribers + a global
-- cap. Also tracks the set of sessions currently in a @thinking@ turn so
-- a freshly-connected web client can hydrate its sidebar without waiting
-- for the next harness-status event (which would only arrive at the next
-- turn boundary — leaving a mid-turn refresh stuck on Idle). The thinking
-- map records /when/ thinking started so 'reconcileStaleThinking' can
-- detect sessions stuck longer than a threshold (e.g. an unanswered
-- ASK_HUMAN blocking the turn indefinitely).
data StreamBroker = StreamBroker
  { sbSubs :: TVar [Subscriber]
  , sbCap :: Int
  , sbThinking :: TVar (Map.Map SessionId UTCTime)
  , sbEntryCursors :: TVar (Map.Map SessionId Int)
  }

-- | Build a new broker with the given subscriber cap.
newStreamBroker :: Int -> IO StreamBroker
newStreamBroker cap =
  StreamBroker <$> newTVarIO [] <*> pure cap <*> newTVarIO Map.empty <*> newTVarIO Map.empty

-- | Read the per-session entry broadcast cursor: the number of entries
-- already fanned out for this session. Zero for a never-broadcast session.
readEntryCursor :: StreamBroker -> SessionId -> IO Int
readEntryCursor broker sid =
  fromMaybe 0 . Map.lookup sid <$> readTVarIO (sbEntryCursors broker)

-- | Incremental entry broadcast (issue #198): given the session's FULL
-- frontend-shaped transcript (as 'readTranscriptEntries' returns it),
-- return only the entries that have not been broadcast for this session
-- yet, and advance the per-session cursor. The cursor is positional
-- (the number of entries already sent), so successive calls during a
-- turn fan out each entry exactly once — linear broadcast volume instead
-- of the historical O(N²) full-transcript re-send per recorded entry.
--
-- A cursor AHEAD of the transcript (the session was rebuilt / the
-- transcript shrank) clamps to zero and resends everything: subscribers
-- see an idempotent replay rather than silently missing entries. The web
-- frontend dedupes by entry id, and idempotent replays are the failure
-- mode every consumer already tolerates.
--
-- Concurrency: 'Seal.Core.TurnEngine.runTurnBody' runs turns under
-- 'withSessionLock' so per-session calls are serialized; the atomic
-- stateTVar below keeps the cursor consistent even when the
-- slash-command writers ('mkModelTranscriptWriter',
-- 'mkStopTranscriptWriter') race a turn.
takeNewEntries
  :: StreamBroker -> SessionId -> [(Int, a)] -> IO [(Int, a)]
takeNewEntries broker sid entries = do
  let total = length entries
  start <- atomically $ stateTVar (sbEntryCursors broker) $ \cursors ->
    let prior = fromMaybe 0 (Map.lookup sid cursors)
    in if prior > total
         then (0, Map.insert sid total cursors)
         else (prior, Map.insert sid total cursors)
  pure (drop start entries)

-- | Subscribe a new connection. If the global cap is exceeded, the subscribe
-- is a no-op (the over-cap subscriber is never added — it should close).
-- Returns the session 'TVar' so the caller can update the focused session
-- via 'updateSubscriberSession' when the client sends a @focus@ op.
--
-- The @close@ action is called when the broker detects this subscriber's
-- send has thrown (dead connection), so the WS socket is actively closed
-- and the client reconnects. Pass @pure ()@ when no cleanup is needed
-- (tests).
subscribe :: StreamBroker -> SessionId -> (BrokerEvent -> IO ()) -> IO () -> IO (TVar SessionId)
subscribe broker session sendfn closefn = do
  ref <- newTVarIO session
  atomically $ do
    subs <- readTVar (sbSubs broker)
    when (length subs < sbCap broker) $
      writeTVar (sbSubs broker) (subs <> [Subscriber ref sendfn closefn])
  pure ref

-- | Update a subscriber's focused session. Called when the client sends a
-- @focus@ op so subsequent 'BeEntryRecorded' events for the new session are
-- delivered.
updateSubscriberSession :: TVar SessionId -> SessionId -> IO ()
updateSubscriberSession ref sid = atomically (writeTVar ref sid)

-- | Fan one event to every subscriber whose focused session matches. For
-- 'BeListsSnapshot' (a broadcast to all), every subscriber receives it
-- regardless of focus.
--
-- A subscriber whose 'subSend' throws (e.g. a closed WebSocket connection
-- raising 'Network.WebSockets.ConnectionClosed') is pruned from the
-- subscriber list and its 'subClose' action is invoked. Closing the
-- connection actively (rather than just silently removing it from the
-- list) ensures the client's @onclose@ fires and it reconnects — without
-- this, a dead connection would linger as a zombie: the reader loop is
-- still alive, the client thinks it's connected, but no events arrive.
-- The close action is best-effort (swallowed if it throws) so a failure
-- during cleanup never propagates to the caller (e.g. a @seal serve@
-- request thread running 'triggerBroadcast' after a slash command).
broadcast :: StreamBroker -> BrokerEvent -> IO ()
broadcast broker event = do
  subs <- readTVarIO (sbSubs broker)
  live <- filterM (deliverTo event) subs
  -- Drop any subscribers whose send threw (dead connections). Call their
  -- close actions so the WS socket is actively closed and the client
  -- reconnects. The length check avoids a needless STM write when everyone
  -- survived.
  when (length live < length subs) $ do
    let dead = filter (\s -> subSessionRef s `notElem` map subSessionRef live) subs
    forM_ dead $ \s -> subClose s `catch` \(_ :: SomeException) -> pure ()
    atomically $ writeTVar (sbSubs broker) live
  where
    deliverTo ev s =
      (do
         ok <- shouldSend ev s
         if ok then subSend s ev >> pure True else pure True)
        `catch` \(_e :: SomeException) -> pure False
    -- All-subscriber events vs session-filtered events.
    -- BeActivity is ALL-subscriber: the sidebar renders tab status for
    -- EVERY open tab, so a turn on a channel-originated session (e.g.
    -- Telegram) must surface to a web client focused on a different
    -- session. The activity envelope carries its own sessionId, so the
    -- frontend's useSessionActivityStream keys it per-session without
    -- relying on the broker's focus filter.
    shouldSend ev s = case ev of
      BeListsSnapshot _  -> pure True
      BeHarnessStatus _  -> pure True
      BeActivity _ _      -> pure True
      BeAgentDefsChanged  -> pure True
      BeSkillsChanged     -> pure True
      BeReposChanged      -> pure True
      BeEntryRecorded sid _ -> matchSession s sid
      BeEntryUpdate sid _   -> matchSession s sid
      BeAsk sid _          -> matchSession s sid
      BeAskResolved sid _  -> matchSession s sid
    matchSession s sid = do
      subSid <- readTVarIO (subSessionRef s)
      pure (subSid == sid)

-- | Push a refreshed tab/session snapshot to every connection.
broadcastLists :: StreamBroker -> Value -> IO ()
broadcastLists broker snap = broadcast broker (BeListsSnapshot snap)
-- | Push an @agent-defs-changed@ invalidation signal to every connection.
-- All subscribers receive it (agent defs are not session-scoped).
broadcastAgentDefsChanged :: StreamBroker -> IO ()
broadcastAgentDefsChanged broker = broadcast broker BeAgentDefsChanged

-- | Push a @skills-changed@ invalidation signal to every connection.
-- All subscribers receive it (skills are not session-scoped).
broadcastSkillsChanged :: StreamBroker -> IO ()
broadcastSkillsChanged broker = broadcast broker BeSkillsChanged

-- | Push a @repos-changed@ invalidation signal to every connection.
-- All subscribers receive it (the repo registry is not session-scoped).
broadcastReposChanged :: StreamBroker -> IO ()
broadcastReposChanged broker = broadcast broker BeReposChanged

-- | The current subscriber count (for diagnostics / the global cap check).
subscriberCount :: StreamBroker -> IO Int
subscriberCount broker = length <$> readTVarIO (sbSubs broker)

-- | Read the set of sessions currently in a @thinking@ turn. Used by the
-- lists-snapshot builders to hydrate a freshly-connected web client's
-- sidebar (so a mid-turn refresh does not blank the thinking indicator).
thinkingSessions :: StreamBroker -> IO (Set SessionId)
thinkingSessions broker =
  Map.keysSet <$> readTVarIO (sbThinking broker)

-- | Add ('True') or remove ('False') a session from the thinking set.
-- Idempotent. Called by 'broadcastHarnessStatus' so the broker's
-- in-memory state mirrors the events it fans out. When adding, records
-- the current time so 'reconcileStaleThinking' can detect sessions that
-- have been stuck thinking longer than a threshold (e.g. an unanswered
-- ASK_HUMAN blocking the turn indefinitely — session
-- 20260912-183908-767 issue #3).
setThinking :: StreamBroker -> SessionId -> Bool -> IO ()
setThinking broker sid thinking = do
  now <- getCurrentTime
  atomically $ modifyTVar' (sbThinking broker)
    (\m -> if thinking then Map.insert sid now m else Map.delete sid m)

-- | Remove sessions that have been in the thinking set longer than the
-- given threshold (in seconds). Returns the set of sessions that were
-- cleared. Broadcasts an @idle@ harness-status for each cleared session
-- so the web frontend updates. This is a safety net: a session blocked
-- on an unanswered ASK_HUMAN (or a dead provider connection that slipped
-- past the stream timeout) leaves the session permanently thinking in
-- the broker's in-memory state. Without reconciliation, a page refresh
-- shows the session as thinking forever.
reconcileStaleThinking :: StreamBroker -> Int -> IO (Set SessionId)
reconcileStaleThinking broker maxAgeSec = do
  now <- getCurrentTime
  let threshold = fromIntegral maxAgeSec :: Double
  stale <- atomically $ do
    m <- readTVar (sbThinking broker)
    let isStale t = realToFrac (now `diffUTCTime` t) >= threshold
        staleMap = Map.filter isStale m
        staleSids = Map.keysSet staleMap
    unless (Set.null staleSids) $
      writeTVar (sbThinking broker) (Map.difference m staleMap)
    pure staleSids
  -- Broadcast idle for each cleared session so the frontend updates.
  forM_ (Set.toList stale) $ \sid ->
    broadcast broker (BeActivity sid (object
      [ "kind" .= ("harness-status" :: Text)
      , "status" .= ("idle" :: Text)
      ]))
  pure stale
