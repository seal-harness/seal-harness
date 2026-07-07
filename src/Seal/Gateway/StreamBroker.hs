{-# LANGUAGE OverloadedStrings #-}
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

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, writeTVar)
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
  if length subs < sbCap broker
    then writeTVar (sbSubs broker) (subs <> [Subscriber session sendfn])
    else pure ()  -- over cap: silently drop (the WS handler should close)

-- | Fan one event to every subscriber whose focused session matches. For
-- 'BeListsSnapshot' (a broadcast to all), every subscriber receives it
-- regardless of focus.
broadcast :: StreamBroker -> BrokerEvent -> IO ()
broadcast broker event = do
  subs <- atomically (readTVar (sbSubs broker))
  case event of
    BeListsSnapshot _ -> mapM_ (\s -> subSend s event) subs
    BeEntryRecorded sid _ -> mapM_ (\s -> if subSession s == sid then subSend s event else pure ()) subs
    BeHarnessStatus _ -> mapM_ (\s -> subSend s event) subs  -- harness status → all (the frontend's sidebar shows all harnesses)

-- | Push a refreshed tab/session snapshot to every connection.
broadcastLists :: StreamBroker -> Value -> IO ()
broadcastLists broker snap = broadcast broker (BeListsSnapshot snap)

-- | The current subscriber count (for diagnostics / the global cap check).
subscriberCount :: StreamBroker -> IO Int
subscriberCount broker = length <$> atomically (readTVar (sbSubs broker))