-- | The in-process broker that fans 'BrokerEvent's to every subscribed WS
-- connection, filtering by each connection's focused session. STM-backed:
-- a 'TVar' of subscribers + a global cap.
module Seal.Gateway.StreamBroker
  ( BrokerEvent (..)
  , Subscriber (..)
  , StreamBroker (..)
  , newStreamBroker
  , subscribe
  , updateSubscriberSession
  , broadcast
  , broadcastLists
  , broadcastAgentDefsChanged
  , broadcastSkillsChanged
  , broadcastReposChanged
  , subscriberCount
  , thinkingSessions
  , setThinking
  ) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (SomeException, catch)
import Control.Monad (unless, when, filterM)
import Data.Aeson (Value)
import Data.Set (Set)
import Data.Set qualified as Set

import Katip (Severity (..), ls)
import Seal.Core.Types (SessionId, sessionIdText)
import Seal.Logging.Global (globalLogIO)

-- | One event the broker fans out to subscribers.
data BrokerEvent
  = BeEntryRecorded SessionId Value   -- ^ a transcript entry (the JSON the WS peer receives)
  | BeHarnessStatus Value             -- ^ a harness liveness change
  | BeListsSnapshot Value             -- ^ a refreshed tab/session snapshot
  | BeAsk SessionId Value             -- ^ a pending human-question from ASK_HUMAN (the JSON the WS peer renders)
  | BeAskResolved SessionId Value      -- ^ a pending question was answered/cancelled (the JSON carries the ask id)
  | BeActivity SessionId Value          -- ^ a per-session activity signal (harness-status / reply-delivered) the WS peer renders as an @activity@ envelope
  | BeAgentDefsChanged                 -- ^ agent defs were created/updated/deleted; clients should re-fetch
  | BeSkillsChanged                    -- ^ skills were created/updated/deleted; clients should re-fetch
  | BeReposChanged                     -- ^ the source-control repo registry was mutated; clients should re-fetch /api/repos
  deriving stock (Eq, Show)

-- | The per-subscriber state: the focused session (via an 'IORef' so the
-- connection thread can update it on focus without re-subscribing) + a
-- send action.
data Subscriber = Subscriber
  { subSessionRef :: TVar SessionId
  , subSend    :: BrokerEvent -> IO ()
  }

-- | The in-process broker. STM-backed: a 'TVar' of subscribers + a global
-- cap. Also tracks the set of sessions currently in a @thinking@ turn so
-- a freshly-connected web client can hydrate its sidebar without waiting
-- for the next harness-status event (which would only arrive at the next
-- turn boundary — leaving a mid-turn refresh stuck on Idle).
data StreamBroker = StreamBroker
  { sbSubs :: TVar [Subscriber]
  , sbCap :: Int
  , sbThinking :: TVar (Set SessionId)
  }

-- | Build a new broker with the given subscriber cap.
newStreamBroker :: Int -> IO StreamBroker
newStreamBroker cap =
  StreamBroker <$> newTVarIO [] <*> pure cap <*> newTVarIO Set.empty

-- | Subscribe a new connection. If the global cap is exceeded, the subscribe
-- is a no-op (the over-cap subscriber is never added — it should close).
-- Returns the session 'TVar' so the caller can update the focused session
-- via 'updateSubscriberSession' when the client sends a @focus@ op.
subscribe :: StreamBroker -> SessionId -> (BrokerEvent -> IO ()) -> IO (TVar SessionId)
subscribe broker session sendfn = do
  ref <- newTVarIO session
  atomically $ do
    subs <- readTVar (sbSubs broker)
    when (length subs < sbCap broker) $
      writeTVar (sbSubs broker) (subs <> [Subscriber ref sendfn])
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
-- raising 'Network.WebSockets.ConnectionClosed') is silently dropped from
-- the subscriber list and skipped for this event — a dead connection must
-- never propagate an exception to the caller (e.g. a @seal serve@ request
-- thread running 'triggerBroadcast' after a slash command). Without this,
-- any slash command that triggers a lists broadcast 500s the HTTP response
-- once the single WS subscriber's connection has dropped.
broadcast :: StreamBroker -> BrokerEvent -> IO ()
broadcast broker event = do
  subs <- readTVarIO (sbSubs broker)
  live <- filterM (deliverTo event) subs
  -- Drop any subscribers whose send threw (dead connections). The length
  -- check avoids a needless STM write when everyone survived.
  when (length live < length subs) $ atomically $ writeTVar (sbSubs broker) live
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
      BeAsk sid _          -> matchSession s sid
      BeAskResolved sid _  -> matchSession s sid
    matchSession s sid = do
      subSid <- readTVarIO (subSessionRef s)
      let matched = subSid == sid
      unless matched $
        globalLogIO DebugS (ls ("[broker] filter: entry sid=" :: String) <> ls (sessionIdText sid)
          <> ls (" != subSid=" :: String) <> ls (sessionIdText subSid))
      pure matched

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
thinkingSessions broker = readTVarIO (sbThinking broker)

-- | Add ('True') or remove ('False') a session from the thinking set.
-- Idempotent. Called by 'broadcastHarnessStatus' so the broker's
-- in-memory state mirrors the events it fans out.
setThinking :: StreamBroker -> SessionId -> Bool -> IO ()
setThinking broker sid thinking =
  atomically $ modifyTVar' (sbThinking broker)
    (\s -> if thinking then Set.insert sid s else Set.delete sid s)