-- | The in-process broker that fans 'BrokerEvent's to every subscribed WS
-- connection, filtering by each connection's focused session. STM-backed:
-- a 'TVar' of subscribers + a global cap.
module Seal.Gateway.StreamBroker
  ( BrokerEvent (..)
  , Subscriber (..)
  , StreamBroker (..)
  , newStreamBroker
  , subscribe
  , broadcast
  , broadcastLists
  , subscriberCount
  ) where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Monad (when)
import Data.Aeson (Value)

import Seal.Core.Types (SessionId)

-- | One event the broker fans out to subscribers.
data BrokerEvent
  = BeEntryRecorded SessionId Value   -- ^ a transcript entry (the JSON the WS peer receives)
  | BeHarnessStatus Value             -- ^ a harness liveness change
  | BeListsSnapshot Value             -- ^ a refreshed tab/session snapshot
  deriving stock (Eq, Show)

-- | The per-subscriber state: the focused session + a send action.
data Subscriber = Subscriber
  { subSession :: SessionId
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
subscribe :: StreamBroker -> SessionId -> (BrokerEvent -> IO ()) -> IO ()
subscribe broker session sendfn = atomically $ do
  subs <- readTVar (sbSubs broker)
  when (length subs < sbCap broker) $
    writeTVar (sbSubs broker) (subs <> [Subscriber session sendfn])

-- | Fan one event to every subscriber whose focused session matches. For
-- 'BeListsSnapshot' (a broadcast to all), every subscriber receives it
-- regardless of focus.
broadcast :: StreamBroker -> BrokerEvent -> IO ()
broadcast broker event = do
  subs <- readTVarIO (sbSubs broker)
  case event of
    BeListsSnapshot _ -> mapM_ (`subSend` event) subs
    BeEntryRecorded sid _ -> mapM_ (\s -> when (subSession s == sid) (subSend s event)) subs
    BeHarnessStatus _ -> mapM_ (`subSend` event) subs  -- harness status → all (the frontend's sidebar shows all harnesses)

-- | Push a refreshed tab/session snapshot to every connection.
broadcastLists :: StreamBroker -> Value -> IO ()
broadcastLists broker snap = broadcast broker (BeListsSnapshot snap)

-- | The current subscriber count (for diagnostics / the global cap check).
subscriberCount :: StreamBroker -> IO Int
subscriberCount broker = length <$> readTVarIO (sbSubs broker)