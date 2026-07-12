{-# LANGUAGE OverloadedStrings #-}
module Seal.Gateway.StreamBrokerSpec (spec) where

import Data.Aeson (object, (.=))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Test.Hspec

import Seal.Core.Types (mkSessionId, SessionId)
import Seal.Gateway.StreamBroker

mkSid :: T.Text -> SessionId
mkSid t = case mkSessionId t of Right s -> s; Left _ -> error "bad sid"

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