{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the WebSocket stream endpoint's liveness reporting.
--
-- Background: the WS server used to be a SEPARATE listener, forked with no
-- exception handling, so a bind failure (the port already in use by another
-- process) killed the WS thread SILENTLY while the HTTP gateway stayed up
-- and @\/api\/health@ went on advertising the dead port. The web frontend
-- then connected to a non-WebSocket port and its transcript froze
-- permanently.
--
-- The gateway is now SINGLE-PORT: the WS stream is mounted in the HTTP
-- application, so there is no second bind to fail — one listener, one
-- port. These tests pin that arrangement: the WS is served by the same
-- HTTP server, and the health state reports the truth.
module Seal.Gateway.StreamHealthSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Client (defaultManagerSettings, newManager, parseRequest)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (status404)
import Network.Wai (Application, responseLBS)
import Network.Wai.Handler.Warp (run)
import Network.WebSockets (receiveData, runClient)
import System.Timeout (timeout)
import Test.Hspec

import Seal.Config.Paths (SealPaths (..))
import Seal.Gateway.Stream
  ( StreamGuard (..), StreamHealth (..), streamHealthMessage
  , streamHealthStatus, streamMiddleware )
import Seal.Gateway.StreamBroker (StreamBroker, newStreamBroker)
import Seal.Tabs (newTabsHandle)
import Seal.TestHelpers.FreePort (withFreePort)

fakePaths :: SealPaths
fakePaths = SealPaths { spHome = "", spState = "", spConfig = "", spKeys = "", spCache = "" }

mkGuard :: IO StreamGuard
mkGuard = do
  tabsH <- newTabsHandle
  pure StreamGuard
    { sgAllowedOrigins = ["http://localhost:8080"]
    , sgGlobalCap = 10
    , sgTabsHandle = tabsH
    , sgPaths = fakePaths
    , sgHeartbeatSeconds = 3600
    , sgAccessControl = Nothing
    }

-- | The WS middleware mounted on an HTTP application — the production
-- arrangement (one port serving both).
streamAppWithFallback :: StreamGuard -> StreamBroker -> Application
streamAppWithFallback guard broker =
  streamMiddleware guard broker (\_req respond -> respond (responseLBS status404 [] "not found"))

-- | Run an action against a Warp server bound to @port@.
--
-- The server runs in a forked thread. A leaked listener would add load
-- to every later test in the suite (the suite has timing-sensitive
-- tests), so the port is allocated from the ephemeral range and the
-- action is bounded by a timeout.
withServer
  :: Int
  -> StreamGuard
  -> StreamBroker
  -> IO a
  -> IO (Maybe a)
withServer port guard broker action = do
  _ <- forkIO (run port (streamAppWithFallback guard broker))
  threadDelay 200000
  timeout 5_000_000 action

spec :: Spec
spec = describe "Seal.Gateway.Stream health" $ do
  it "serves the WebSocket stream on the SAME port as the HTTP app" $ do
    -- The regression: the WS used to be a separate listener on its own
    -- port, so it could die (bind failure) while HTTP kept serving. Now
    -- the WS upgrade is handled by the same Warp listener.
    broker <- newStreamBroker 10
    guard <- mkGuard
    withFreePort $ \port -> do
      ok <- withServer port guard broker $ do
        -- A WS client connects to the HTTP port and gets the hello frame.
        runClient "127.0.0.1" port "/" $ \conn -> do
          hello <- receiveData conn :: IO BL.ByteString
          case A.decode hello :: Maybe A.Value of
            Just v -> case KeyMap.lookup (Key.fromText "type") (objOf v) of
              Just (A.String "hello") -> pure ()
              other -> expectationFailure ("expected a hello frame, got " <> show other)
            Nothing -> expectationFailure "expected hello JSON"
      ok `shouldBe` Just ()

  it "falls through to the HTTP app for non-WebSocket requests" $ do
    -- The WS middleware must not swallow ordinary HTTP traffic.
    broker <- newStreamBroker 10
    guard <- mkGuard
    withFreePort $ \port -> do
      body <- withServer port guard broker (httpGet port)
      body `shouldBe` Just "not found"


  it "renders the health status verbatim" $ do
    streamHealthStatus (StreamHealth "up" 8080) `shouldBe` "up"
    streamHealthStatus (StreamHealth "down" 8080) `shouldBe` "down"
    streamHealthStatus (StreamHealth "failed" 8080) `shouldBe` "failed"
    streamHealthStatus (StreamHealth "starting" 8080) `shouldBe` "starting"

  it "renders a failed health state with an actionable message" $ do
    let msg = streamHealthMessage (StreamHealth "failed" 9092)
    msg `shouldSatisfy` T.isInfixOf "9092"
    msg `shouldSatisfy` T.isInfixOf "FAILED"

  it "renders a healthy health state naming the port" $ do
    let msg = streamHealthMessage (StreamHealth "up" 9092)
    msg `shouldSatisfy` T.isInfixOf "9092"
    msg `shouldSatisfy` T.isInfixOf "listening"

-- | Extract a field from a JSON object.
objOf :: A.Value -> KeyMap.KeyMap A.Value
objOf (A.Object o) = o
objOf _            = KeyMap.empty

-- | A minimal HTTP GET returning the response body.
httpGet :: Int -> IO T.Text
httpGet port = do
  mgr <- newManager defaultManagerSettings
  req <- parseRequest ("http://127.0.0.1:" <> show port <> "/")
  res <- HTTP.httpLbs req mgr
  pure (TE.decodeUtf8 (BL.toStrict (HTTP.responseBody res)))
