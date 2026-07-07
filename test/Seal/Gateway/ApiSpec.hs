{-# LANGUAGE OverloadedStrings #-}
module Seal.Gateway.ApiSpec (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.ByteString.Char8 qualified as BC
import Data.IORef (newIORef)
import Data.Text qualified as T
import Data.Time (UTCTime(..), fromGregorian)
import Network.HTTP.Types (methodGet, statusCode)
import Network.Wai
  ( Application, Request, defaultRequest
  , pathInfo, requestMethod, responseStatus )
import Network.Wai.Internal (ResponseReceived (..))
import Test.Hspec

import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (mkSessionId)
import Seal.Gateway.API
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..))
import Seal.Tabs (newTabsHandle)

fakePaths :: SealPaths
fakePaths = SealPaths
  { spHome = "", spState = "", spConfig = "", spKeys = "" }

fakeMeta :: SessionMeta
fakeMeta =
  let sid = case mkSessionId "test" of Right s -> s; Left _ -> error "sid"
  in SessionMeta sid "ollama" "llama3" "cli" Nothing (UTCTime (fromGregorian 2026 1 1) 0) (UTCTime (fromGregorian 2026 1 1) 0)

-- | Build a test request with a given method + path.
testRequest :: BC.ByteString -> [T.Text] -> Request
testRequest mth path = defaultRequest
  { requestMethod = mth
  , pathInfo = path
  }

-- | Run the app against a test request, capturing the HTTP status code.
runAppStatus :: Application -> Request -> IO Int
runAppStatus app req = do
  mv <- newEmptyMVar
  _rr <- app req (\resp -> putMVar mv (statusCode (responseStatus resp)) >> pure ResponseReceived)
  takeMVar mv

spec :: Spec
spec = describe "Seal.Gateway.API" $ do
  let mkApp = do
        tabsH <- newTabsHandle
        activeRef <- newIORef fakeMeta
        let sr = SessionRuntime { srPaths = fakePaths, srConfigPath = "", srActive = activeRef }
            deps = ApiDeps { adSessionRuntime = sr, adTabsHandle = tabsH }
        pure (apiApp deps)

  it "GET /api/health returns 200" $ do
    app <- mkApp
    status <- runAppStatus app (testRequest methodGet ["api", "health"])
    status `shouldBe` 200

  it "GET /api/tabs returns 200" $ do
    app <- mkApp
    status <- runAppStatus app (testRequest methodGet ["api", "tabs"])
    status `shouldBe` 200

  it "GET /api/sessions returns 200" $ do
    app <- mkApp
    status <- runAppStatus app (testRequest methodGet ["api", "sessions"])
    status `shouldBe` 200

  it "GET /api/nonexistent returns 404" $ do
    app <- mkApp
    status <- runAppStatus app (testRequest methodGet ["api", "nonexistent"])
    status `shouldBe` 404