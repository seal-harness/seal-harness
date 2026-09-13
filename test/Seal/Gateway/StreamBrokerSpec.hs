{-# LANGUAGE OverloadedStrings #-}
module Seal.Gateway.StreamBrokerSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (getCurrentTime, addUTCTime)
import Control.Concurrent.STM (TVar, atomically, writeTVar)
import Control.Exception (Exception, throwIO)
import Control.Monad (void)
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

-- | Subscribe with a no-op close action (tests don't need real WS close).
subscribeTest :: StreamBroker -> SessionId -> (BrokerEvent -> IO ()) -> IO (TVar SessionId)
subscribeTest broker sid sendfn = subscribe broker sid sendfn (pure ())

spec :: Spec
spec = describe "Seal.Gateway.StreamBroker" $ do
  it "broadcast fans events to subscribers filtered by session" $ do
    broker <- newStreamBroker 10
    refA <- newIORef ([] :: [BrokerEvent])
    refB <- newIORef ([] :: [BrokerEvent])
    void $ subscribeTest broker (mkSid "a") (\e -> modifyIORef' refA (e :))
    void $ subscribeTest broker (mkSid "b") (\e -> modifyIORef' refB (e :))
    let entry = object ["id" .= ("e1" :: T.Text)]
    broadcast broker (BeEntryRecorded (mkSid "a") entry)
    a <- readIORef refA
    b <- readIORef refB
    length a `shouldBe` 1  -- received (session a matches)
    length b `shouldBe` 0  -- filtered out (session b != a)

  it "BeEntryUpdate is session-filtered like BeEntryRecorded" $ do
    broker <- newStreamBroker 10
    refA <- newIORef ([] :: [BrokerEvent])
    refB <- newIORef ([] :: [BrokerEvent])
    void $ subscribeTest broker (mkSid "a") (\e -> modifyIORef' refA (e :))
    void $ subscribeTest broker (mkSid "b") (\e -> modifyIORef' refB (e :))
    let entry = object ["id" .= ("streaming" :: T.Text)]
    broadcast broker (BeEntryUpdate (mkSid "a") entry)
    a <- readIORef refA
    b <- readIORef refB
    length a `shouldBe` 1  -- received (session a matches)
    length b `shouldBe` 0  -- filtered out (session b != a)

  it "broadcastLists delivers to all subscribers" $ do
    broker <- newStreamBroker 10
    refA <- newIORef ([] :: [BrokerEvent])
    refB <- newIORef ([] :: [BrokerEvent])
    void $ subscribeTest broker (mkSid "a") (\e -> modifyIORef' refA (e :))
    void $ subscribeTest broker (mkSid "b") (\e -> modifyIORef' refB (e :))
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
    void $ subscribeTest broker (mkSid "a") (\e -> modifyIORef' refA (e :))
    void $ subscribeTest broker (mkSid "b") (\e -> modifyIORef' refB (e :))  -- over cap
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
    void $ subscribeTest broker (mkSid "a") (\e -> modifyIORef' ref (e :))
    let snap = object ["type" .= ("lists" :: T.Text), "tabs" .= ([] :: [T.Text])]
    broadcastLists broker snap
    events <- readIORef ref
    case events of
      [BeListsSnapshot _] -> pure ()
      _                  -> expectationFailure ("expected exactly one BeListsSnapshot, got " <> show events)

  it "BeActivity is delivered to ALL subscribers (sidebar needs every tab's status, not just the focused session's)" $ do
    broker <- newStreamBroker 10
    refA <- newIORef ([] :: [BrokerEvent])
    refB <- newIORef ([] :: [BrokerEvent])
    void $ subscribeTest broker (mkSid "a") (\e -> modifyIORef' refA (e :))
    void $ subscribeTest broker (mkSid "b") (\e -> modifyIORef' refB (e :))
    let payload = object ["kind" .= ("harness-status" :: T.Text), "status" .= ("thinking" :: T.Text)]
    broadcast broker (BeActivity (mkSid "a") payload)
    a <- readIORef refA
    b <- readIORef refB
    -- Both subscribers receive the activity even though only one is
    -- focused on session "a" — the sidebar renders tab status for every
    -- open tab (e.g. a Telegram-originated turn must surface to a web
    -- client focused on a different session).
    length a `shouldBe` 1
    length b `shouldBe` 1

  -- Regression: a subscriber whose send throws (e.g. a closed WebSocket
  -- raising ConnectionClosed) must NOT propagate the exception to the
  -- caller. Before the fix, any slash command that triggered a lists
  -- broadcast 500ed the HTTP request once the single WS subscriber's
  -- connection had dropped.
  it "broadcast swallows a throwing subscriber and does not propagate" $ do
    broker <- newStreamBroker 10
    refHealthy <- newIORef ([] :: [BrokerEvent])
    void $ subscribeTest broker (mkSid "a") (\_e -> throwIO DeadConnection)
    void $ subscribeTest broker (mkSid "a") (\e -> modifyIORef' refHealthy (e :))
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
    void $ subscribeTest broker (mkSid "a") (\_e -> throwIO DeadConnection)
    void $ subscribeTest broker (mkSid "b") (\e -> modifyIORef' refHealthy (e :))
    let snap = object ["tabs" .= ([] :: [T.Text])]
    broadcastLists broker snap
    h <- readIORef refHealthy
    length h `shouldBe` 1
    count <- subscriberCount broker
    count `shouldBe` 1

  it "broadcast calls subClose when a subscriber's send throws" $ do
    -- When a subscriber is evicted (send threw), the broker should call
    -- its subClose action so the WS connection is actively closed and the
    -- client reconnects (rather than silently lingering as a zombie).
    broker <- newStreamBroker 10
    closedRef <- newIORef False
    void $ subscribe broker (mkSid "a") (\_e -> throwIO DeadConnection)
           (modifyIORef' closedRef (const True))
    let entry = object ["id" .= ("e1" :: T.Text)]
    broadcast broker (BeEntryRecorded (mkSid "a") entry)
    closed <- readIORef closedRef
    closed `shouldBe` True

  -- ── reconcileStaleThinking ──────────────────────────────────────────

  describe "Seal.Gateway.StreamBroker.reconcileStaleThinking" $ do
    it "clears sessions that have been thinking longer than the threshold" $ do
      broker <- newStreamBroker 10
      setThinking broker (mkSid "stale") True
      -- Manually backdate the thinking timestamp so it's older than 1 second.
      now <- getCurrentTime
      atomically $ writeTVar (sbThinking broker)
        (Map.insert (mkSid "stale") (addUTCTime (-120) now) Map.empty)
      cleared <- reconcileStaleThinking broker 60
      cleared `shouldBe` Set.fromList [mkSid "stale"]
      remaining <- thinkingSessions broker
      Set.null remaining `shouldBe` True

    it "does NOT clear sessions that started thinking recently" $ do
      broker <- newStreamBroker 10
      setThinking broker (mkSid "fresh") True
      cleared <- reconcileStaleThinking broker 3600
      Set.null cleared `shouldBe` True
      remaining <- thinkingSessions broker
      remaining `shouldBe` Set.fromList [mkSid "fresh"]

    it "broadcasts an idle harness-status for each cleared session" $ do
      broker <- newStreamBroker 10
      ref <- newIORef ([] :: [BrokerEvent])
      void $ subscribeTest broker (mkSid "stale") (\e -> modifyIORef' ref (e :))
      setThinking broker (mkSid "stale") True
      now <- getCurrentTime
      atomically $ writeTVar (sbThinking broker)
        (Map.insert (mkSid "stale") (addUTCTime (-120) now) Map.empty)
      void $ reconcileStaleThinking broker 60
      events <- readIORef ref
      -- BeActivity is all-subscriber, so the subscriber focused on "stale"
      -- receives the idle event.
      any isIdleActivity events `shouldBe` True
      where
        isIdleActivity (BeActivity _ payload) =
          case payload of
            A.Object o -> case KM.lookup "status" o of
              Just (A.String "idle") -> True
              _ -> False
            _ -> False
        isIdleActivity _ = False
