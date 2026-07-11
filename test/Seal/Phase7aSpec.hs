{-# LANGUAGE OverloadedStrings #-}
-- | Phase 7a capstone: the gateway + WS broker work end-to-end. A test
-- server (the API + the WS stream server) is started on test ports, a WS
-- client connects and receives hello + a broadcast event, and the REST
-- API responds. The 7a milestone gate.
module Seal.Phase7aSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.IORef (newIORef)

import Data.Time (UTCTime(..), fromGregorian)
import Network.HTTP.Types (methodGet, statusCode)
import Network.Wai
  ( Application, Request, defaultRequest, pathInfo, requestMethod, responseStatus )
import Network.Wai.Internal (ResponseReceived (..))
import Network.WebSockets (ClientApp, runClient, receiveData)
import Test.Hspec

import Seal.Agent.Def.Backend (noneBackend)
import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (mkSessionId)
import Seal.Gateway.API (ApiDeps (..))
import Seal.Gateway.Server (gatewayApp)
import Seal.Gateway.Stream (StreamGuard (..), runStreamServer)
import Seal.Gateway.StreamBroker (newStreamBroker, broadcastLists)
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Providers.Registry (knownProviders)
import Seal.Security.Adoption (ConsentChannel (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..))
import Seal.Tabs (newTabsHandle)

fakePaths :: SealPaths
fakePaths = SealPaths { spHome = "", spState = "", spConfig = "", spKeys = "" }

fakeMeta :: SessionMeta
fakeMeta =
  let sid = case mkSessionId "capstone" of Right s -> s; Left _ -> error "sid"
  in SessionMeta sid "ollama" "llama3" "cli" Nothing (UTCTime (fromGregorian 2026 1 1) 0) (UTCTime (fromGregorian 2026 1 1) 0)

runAppStatus :: Application -> Request -> IO Int
runAppStatus app req = do
  mv <- newEmptyMVar
  _rr <- app req (\resp -> putMVar mv (statusCode (responseStatus resp)) >> pure ResponseReceived)
  takeMVar mv

spec :: Spec
spec = describe "Seal.Phase7aSpec" $ do
  it "the assembled gateway serves /api/health (200)" $ do
    tabsH <- newTabsHandle
    reg   <- newHarnessRegistry
    adb   <- noneBackend
    activeRef <- newIORef fakeMeta
    let sr = SessionRuntime { srPaths = fakePaths, srConfigPath = "", srActive = activeRef }
        deps = ApiDeps
          { adSessionRuntime = sr
          , adTabsHandle = tabsH
          , adHarnessRegistry = reg
          , adAdoptConsent = Just CcWeb
          , adAgentDefs = adb
          , adProviders = pure knownProviders
          , adSend = Nothing
          }
        app = gatewayApp deps Nothing
    status <- runAppStatus app (defaultRequest { requestMethod = methodGet, pathInfo = ["api", "health"] })
    status `shouldBe` 200

  it "a WS client connects, receives hello + a broadcastLists event" $ do
    broker <- newStreamBroker 10
    let guard = StreamGuard { sgAllowedOrigins = ["http://localhost:8080"], sgGlobalCap = 10 }
        port = 18095
    _ <- forkIO (runStreamServer "127.0.0.1" port guard broker)
    threadDelay 200000
    let client :: ClientApp ()
        client conn = do
          hello <- receiveData conn :: IO BL.ByteString
          case A.decode hello :: Maybe A.Value of
            Just _ -> pure ()
            Nothing -> error "expected hello JSON"
          broadcastLists broker (A.object ["tabs" A..= ([] :: [String])])
          threadDelay 100000
          msg <- receiveData conn :: IO BL.ByteString
          case A.decode msg :: Maybe A.Value of
            Just _ -> pure ()
            Nothing -> error "expected an event JSON"
    runClient "127.0.0.1" port "/" client

  it "GET /api/tabs returns 200 via the assembled gateway" $ do
    tabsH <- newTabsHandle
    reg   <- newHarnessRegistry
    adb   <- noneBackend
    activeRef <- newIORef fakeMeta
    let sr = SessionRuntime { srPaths = fakePaths, srConfigPath = "", srActive = activeRef }
        deps = ApiDeps
          { adSessionRuntime = sr
          , adTabsHandle = tabsH
          , adHarnessRegistry = reg
          , adAdoptConsent = Just CcWeb
          , adAgentDefs = adb
          , adProviders = pure knownProviders
          , adSend = Nothing
          }
        app = gatewayApp deps Nothing
    status <- runAppStatus app (defaultRequest { requestMethod = methodGet, pathInfo = ["api", "tabs"] })
    status `shouldBe` 200