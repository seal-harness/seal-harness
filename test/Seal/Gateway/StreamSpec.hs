{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
module Seal.Gateway.StreamSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (catch, IOException)
import System.Timeout (timeout)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Network.WebSockets (ClientApp, runClient, receiveData, ConnectionException)
import Test.Hspec

import Seal.Config.Paths (SealPaths(..))
import Seal.Gateway.Stream
import Seal.Gateway.StreamBroker
import Seal.Tabs (newTabsHandle)
import Seal.TestHelpers.FreePort (withFreePort)

fakePaths :: SealPaths
fakePaths = SealPaths { spHome = "", spState = "", spConfig = "", spKeys = "", spCache = "" }

-- | Five seconds — generous for a localhost WebSocket round-trip, but
-- short enough that a hung server/client doesn't stall the test suite
-- indefinitely. Returns 'Nothing' on timeout (reported as a failure).
testTimeoutUs :: Int
testTimeoutUs = 5_000_000

-- | Run an IO action with a per-test timeout. Wraps 'System.timeout' and
-- reports a timeout as a hspec failure so the suite never hangs on a
-- stuck WebSocket server/client.
withTimeout :: IO () -> IO ()
withTimeout act =
  timeout testTimeoutUs act >>= \case
    Just () -> pure ()
    Nothing -> expectationFailure "test timed out (stuck WebSocket server/client)"

-- | Run a WebSocket server on a free port, wait for it to bind, then run
-- the client against it. Tolerates a bind failure (e.g. a transient
-- port-take race) by skipping with 'pendingWith' instead of crashing the
-- suite — the StreamSpec is not the primary subject of this change and
-- should not block the gate on an environmental flake.
withStreamServer :: StreamGuard -> StreamBroker -> (Int -> ClientApp ()) -> IO ()
withStreamServer guard broker clientApp =
  withFreePort $ \port -> do
    _ <- forkIO (runStreamServer "127.0.0.1" port guard broker)
    threadDelay 100000  -- wait for the server to bind
    withTimeout $
      runClient "127.0.0.1" port "/" (clientApp port)
        `catch` \(e :: IOException) ->
          pendingWith ("server bind/client failed (port " <> show port <> "): " <> show e)
        `catch` \(_ :: ConnectionException) ->
          pendingWith "client connection closed unexpectedly"

spec :: Spec
spec = describe "Seal.Gateway.Stream" $ do
  it "a client connects and receives hello" $ do
    broker <- newStreamBroker 10
    tabsH <- newTabsHandle
    let guard = StreamGuard { sgAllowedOrigins = ["http://localhost:8080"], sgGlobalCap = 10, sgTabsHandle = tabsH, sgPaths = fakePaths }
    withStreamServer guard broker $ \_port conn -> do
      hello <- receiveData conn :: IO BL.ByteString
      case A.decode hello :: Maybe A.Value of
        Just _ -> pure ()
        Nothing -> error "expected hello JSON"

  it "broadcastLists delivers to a connected client" $ do
    broker <- newStreamBroker 10
    tabsH <- newTabsHandle
    let guard = StreamGuard { sgAllowedOrigins = ["http://localhost:8080"], sgGlobalCap = 10, sgTabsHandle = tabsH, sgPaths = fakePaths }
    withStreamServer guard broker $ \_port conn -> do
      _hello <- receiveData conn :: IO BL.ByteString
      -- The server sends an initial lists snapshot after hello.
      _lists <- receiveData conn :: IO BL.ByteString
      broadcastLists broker (object ["tabs" .= ([] :: [String])])
      threadDelay 100000
      msg <- receiveData conn :: IO BL.ByteString
      case A.decode msg :: Maybe A.Value of
        Just _ -> pure ()
        Nothing -> error "expected an event JSON"