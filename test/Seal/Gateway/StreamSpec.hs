{-# LANGUAGE OverloadedStrings #-}
module Seal.Gateway.StreamSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Network.WebSockets (ClientApp, runClient, receiveData)
import Test.Hspec

import Seal.Gateway.Stream
import Seal.Gateway.StreamBroker

spec :: Spec
spec = describe "Seal.Gateway.Stream" $ do
  it "a client connects and receives hello" $ do
    broker <- newStreamBroker 10
    let guard = StreamGuard { sgAllowedOrigins = ["http://localhost:8080"], sgGlobalCap = 10 }
        port = 18080
    _ <- forkIO (runStreamServer "127.0.0.1" port guard broker)
    threadDelay 100000  -- wait for the server to bind
    let client :: ClientApp ()
        client conn = do
          hello <- receiveData conn :: IO BL.ByteString
          case A.decode hello :: Maybe A.Value of
            Just _ -> pure ()
            Nothing -> error "expected hello JSON"
    runClient "127.0.0.1" port "/" client

  it "broadcastLists delivers to a connected client" $ do
    broker <- newStreamBroker 10
    let guard = StreamGuard { sgAllowedOrigins = ["http://localhost:8080"], sgGlobalCap = 10 }
        port = 18081
    _ <- forkIO (runStreamServer "127.0.0.1" port guard broker)
    threadDelay 100000
    let client :: ClientApp ()
        client conn = do
          _hello <- receiveData conn :: IO BL.ByteString
          broadcastLists broker (object ["tabs" .= ([] :: [String])])
          threadDelay 100000
          msg <- receiveData conn :: IO BL.ByteString
          case A.decode msg :: Maybe A.Value of
            Just _ -> pure ()
            Nothing -> error "expected an event JSON"
    runClient "127.0.0.1" port "/" client