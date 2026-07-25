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
  , subscriberCount
  ) where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (SomeException, catch)
import Control.Monad (when, filterM)
import Data.Aeson (Value)

import Seal.Core.Types (SessionId)

-- | One event the broker fans out to subscribers.
data BrokerEvent
  = BeEntryRecorded SessionId Value   -- ^ a transcript entry (the JSON the WS peer receives)
  | BeHarnessStatus Value             -- ^ a harness liveness change
  | BeListsSnapshot Value             -- ^ a refreshed tab/session snapshot
  | BeAsk SessionId Value             -- ^ a pending human-question from ASK_HUMAN (the JSON the WS peer renders)
  | BeAskResolved SessionId Value      -- ^ a pending question was answered/cancelled (the JSON carries the ask id)
  deriving stock (Eq, Show)

-- | The per-subscriber state: the focused session (via an 'IORef' so the
-- connection thread can update it on focus without re-subscribing) + a
-- send action.
data Subscriber = Subscriber
  { subSessionRef :: TVar SessionId
  , subSend    :: BrokerEvent -> IO ()
  }

-- | The in-process broker. STM-backed: a 'TVar' of subscribers + a global cap.
data StreamBroker = StreamBroker
  { sbSubs :: TVar [Subscriber]
  , sbCap :: Int
  }

-- | Build a new broker with the given global subscriber cap.
newStreamBroker :: Int -> IO StreamBroker
newStreamBroker cap = StreamBroker <$> newTVarIO [] <*> pure cap

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
    -- Decide whether this event targets the subscriber's focused session,
    -- attempt the send, and return False (swallowing the exception) if the
    -- send threw so the caller can prune the dead subscriber.
    deliverTo ev s =
      (do
         ok <- shouldSend ev s
         if ok then subSend s ev >> pure True else pure True)
        `catch` \(_e :: SomeException) -> pure False
    -- All-subscriber events vs session-filtered events.
    shouldSend ev s = case ev of
      BeListsSnapshot _  -> pure True
      BeHarnessStatus _  -> pure True
      BeEntryRecorded sid _ -> matchSession s sid
      BeAsk sid _          -> matchSession s sid
      BeAskResolved sid _  -> matchSession s sid
    matchSession s sid = do
      subSid <- readTVarIO (subSessionRef s)
      pure (subSid == sid)

-- | Push a refreshed tab/session snapshot to every connection.
broadcastLists :: StreamBroker -> Value -> IO ()
broadcastLists broker snap = broadcast broker (BeListsSnapshot snap)

-- | The current subscriber count (for diagnostics / the global cap check).
subscriberCount :: StreamBroker -> IO Int
subscriberCount broker = length <$> readTVarIO (sbSubs broker)