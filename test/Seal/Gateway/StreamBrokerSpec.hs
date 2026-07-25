{-# LANGUAGE OverloadedStrings #-}
module Seal.Gateway.StreamBrokerSpec (spec) where

import Data.Aeson (object, (.=))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Control.Exception (Exception, throwIO)
import Test.Hspec

import Seal.Core.Types (mkSessionId, SessionId)
import Seal.Gateway.StreamBroker

mkSid :: T.Text -> SessionId
mkSid t = case mkSessionId t of Right s -> s; Left _ -> error "bad sid"

-- | A controlled exception type so tests can simulate a dead connection
-- (mirrors 'Network.WebSockets.ConnectionClosed' without pulling in the
-- websockets dependency).
data DeadConnection = DeadConnection
  deriving stock (Show)

instance Exception DeadConnection

spec :: Spec
spec = describe "Seal.Gateway.StreamBroker" $ do
  it "broadcast fans events to subscribers filtered by session" $ do
    broker <- newStreamBroker 10
    refA <- newIORef ([] :: [BrokerEvent])
    refB <- newIORef ([] :: [BrokerEvent])
    _ <- subscribe broker (mkSid "a") (\e -> modifyIORef' refA (e :))
    _ <- subscribe broker (mkSid "b") (\e -> modifyIORef' refB (e :))
    let entry = object ["id" .= ("e1" :: T.Text)]
    broadcast broker (BeEntryRecorded (mkSid "a") entry)
    a <- readIORef refA
    b <- readIORef refB
    length a `shouldBe` 1  -- received (session a matches)
    length b `shouldBe` 0  -- filtered out (session b != a)

  it "broadcastLists delivers to all subscribers" $ do
    broker <- newStreamBroker 10
    refA <- newIORef ([] :: [BrokerEvent])
    refB <- newIORef ([] :: [BrokerEvent])
    _ <- subscribe broker (mkSid "a") (\e -> modifyIORef' refA (e :))
    _ <- subscribe broker (mkSid "b") (\e -> modifyIORef' refB (e :))
    let snap = object ["tabs" .= ([] :: [T.Text])]
    broadcastLists broker snap
    a <- readIORef refA
    b <- readIORef refB
    length a `shouldBe` 1
    length b `shouldBe` 1

  it "subscribe over the global cap is rejected" $ do
    broker <- newStreamBroker 1
    refA <- newIORef ([] :: [BrokerEvent])
    refB <- newIORef ([] :: [BrokerEvent])
    _ <- subscribe broker (mkSid "a") (\e -> modifyIORef' refA (e :))
    _ <- subscribe broker (mkSid "b") (\e -> modifyIORef' refB (e :))  -- over cap
    -- the first subscriber still works
    let entry = object ["id" .= ("e1" :: T.Text)]
    broadcast broker (BeEntryRecorded (mkSid "a") entry)
    a <- readIORef refA
    b <- readIORef refB
    length a `shouldBe` 1
    length b `shouldBe` 0  -- the over-cap subscriber was never added

  it "BeListsSnapshot is the event the W6 broadcast triggers fire" $ do
    -- Smoke test: the broker delivers a BeListsSnapshot to all subscribers
    -- (the broadcastListsSnapshot helper in Seal.Gateway.Broadcast emits
    -- these after every state change). This pins the contract the W6 API
    -- triggers depend on.
    broker <- newStreamBroker 10
    ref <- newIORef ([] :: [BrokerEvent])
    _ <- subscribe broker (mkSid "a") (\e -> modifyIORef' ref (e :))
    let snap = object ["type" .= ("lists" :: T.Text), "tabs" .= ([] :: [T.Text])]
    broadcastLists broker snap
    events <- readIORef ref
    case events of
      [BeListsSnapshot _] -> pure ()
      _                  -> expectationFailure ("expected exactly one BeListsSnapshot, got " <> show events)

  -- Regression: a subscriber whose send throws (e.g. a closed WebSocket
  -- raising ConnectionClosed) must NOT propagate the exception to the
  -- caller. Before the fix, any slash command that triggered a lists
  -- broadcast 500ed the HTTP request once the single WS subscriber's
  -- connection had dropped.
  it "broadcast swallows a throwing subscriber and does not propagate" $ do
    broker <- newStreamBroker 10
    refHealthy <- newIORef ([] :: [BrokerEvent])
    _ <- subscribe broker (mkSid "a") (\_e -> throwIO DeadConnection)
    _ <- subscribe broker (mkSid "a") (\e -> modifyIORef' refHealthy (e :))
    let entry = object ["id" .= ("e1" :: T.Text)]
    broadcast broker (BeEntryRecorded (mkSid "a") entry)
    -- The healthy subscriber still received the event.
    h <- readIORef refHealthy
    length h `shouldBe` 1
    -- The dead subscriber was pruned (no longer in the subscriber list).
    count <- subscriberCount broker
    count `shouldBe` 1

  it "broadcast swallows a throwing subscriber for BeListsSnapshot (all-subscriber)" $ do
    broker <- newStreamBroker 10
    refHealthy <- newIORef ([] :: [BrokerEvent])
    _ <- subscribe broker (mkSid "a") (\_e -> throwIO DeadConnection)
    _ <- subscribe broker (mkSid "b") (\e -> modifyIORef' refHealthy (e :))
    let snap = object ["tabs" .= ([] :: [T.Text])]
    broadcastLists broker snap
    h <- readIORef refHealthy
    length h `shouldBe` 1
    count <- subscriberCount broker
    count `shouldBe` 1