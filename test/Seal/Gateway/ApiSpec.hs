{-# LANGUAGE OverloadedStrings #-}
module Seal.Gateway.ApiSpec (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.Aeson ((.=))
import Data.Aeson qualified as A
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as T
import Data.Time (UTCTime(..), fromGregorian)
import Network.HTTP.Types (methodGet, methodPost, statusCode)
import Network.Wai
  ( Application, Request, defaultRequest, pathInfo, requestMethod, responseStatus, setRequestBodyChunks )
import Network.Wai.Internal (ResponseReceived (..))
import Test.Hspec

import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (mkSessionId)
import Seal.Gateway.API
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Security.Adoption (ConsentChannel (..))
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

-- | Build a POST request with a JSON body. The body is delivered as one
-- chunk (then empty, which signals end-of-body to wai). Runs in IO because
-- the body-chunk action holds a one-shot IORef.
testPost :: [T.Text] -> BL.ByteString -> IO Request
testPost path body = do
  usedRef <- newIORef False
  let readChunk = do
        already <- readIORef usedRef
        if already
          then pure BC.empty
          else do writeIORef usedRef True
                  pure (BL.toStrict body)
  pure (setRequestBodyChunks readChunk (defaultRequest { requestMethod = methodPost, pathInfo = path }))

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
        reg   <- newHarnessRegistry
        activeRef <- newIORef fakeMeta
        let sr = SessionRuntime { srPaths = fakePaths, srConfigPath = "", srActive = activeRef }
            deps = ApiDeps
              { adSessionRuntime  = sr
              , adTabsHandle      = tabsH
              , adHarnessRegistry = reg
              , adAdoptConsent    = Just CcWeb
              }
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

  it "POST /api/tabs/new with kind=provider returns 200" $ do
    app <- mkApp
    req <- testPost ["api", "tabs", "new"]
      (A.encode (A.object [ "kind" .= ("provider" :: T.Text), "provider" .= ("anthropic" :: T.Text), "model" .= ("claude-sonnet-4" :: T.Text) ]))
    status <- runAppStatus app req
    status `shouldBe` 200

  it "POST /api/tabs/new with kind=shell returns 501" $ do
    app <- mkApp
    req <- testPost ["api", "tabs", "new"]
      (A.encode (A.object [ "kind" .= ("shell" :: T.Text) ]))
    status <- runAppStatus app req
    status `shouldBe` 501

  it "GET /api/harnesses returns 200" $ do
    app <- mkApp
    status <- runAppStatus app (testRequest methodGet ["api", "harnesses"])
    status `shouldBe` 200

  it "GET /api/harnesses/discover returns 200" $ do
    app <- mkApp
    status <- runAppStatus app (testRequest methodGet ["api", "harnesses", "discover"])
    status `shouldBe` 200

  it "POST /api/adopt without consent_confirmed returns 400" $ do
    app <- mkApp
    req <- testPost ["api", "adopt"]
      (A.encode (A.object [ "session" .= ("s" :: T.Text), "window" .= ("w" :: T.Text) ]))
    status <- runAppStatus app req
    status `shouldBe` 400

  it "POST /api/adopt with consent_confirmed=true returns 200" $ do
    app <- mkApp
    req <- testPost ["api", "adopt"]
      (A.encode (A.object [ "session" .= ("s" :: T.Text), "window" .= ("w" :: T.Text), "consent_confirmed" .= True ]))
    status <- runAppStatus app req
    status `shouldBe` 200

  it "POST /api/tabs/0/close returns 204 after a tab is created" $ do
    app <- mkApp
    req1 <- testPost ["api", "tabs", "new"]
      (A.encode (A.object [ "kind" .= ("provider" :: T.Text) ]))
    _ <- runAppStatus app req1
    req2 <- testPost ["api", "tabs", "0", "close"] BL.empty
    status <- runAppStatus app req2
    status `shouldBe` 204

  it "POST /api/tabs/0/close returns 404 when no tab exists" $ do
    app <- mkApp
    req <- testPost ["api", "tabs", "0", "close"] BL.empty
    status <- runAppStatus app req
    status `shouldBe` 404

  it "POST /api/tabs/0/dismiss returns 204" $ do
    app <- mkApp
    req1 <- testPost ["api", "tabs", "new"]
      (A.encode (A.object [ "kind" .= ("provider" :: T.Text) ]))
    _ <- runAppStatus app req1
    req2 <- testPost ["api", "tabs", "0", "dismiss"] BL.empty
    status <- runAppStatus app req2
    status `shouldBe` 204

  it "POST /api/tabs/0/acknowledge returns 204" $ do
    app <- mkApp
    req1 <- testPost ["api", "tabs", "new"]
      (A.encode (A.object [ "kind" .= ("provider" :: T.Text) ]))
    _ <- runAppStatus app req1
    req2 <- testPost ["api", "tabs", "0", "acknowledge"] BL.empty
    status <- runAppStatus app req2
    status `shouldBe` 204

  it "POST /api/tabs/0/release returns 204" $ do
    app <- mkApp
    req1 <- testPost ["api", "tabs", "new"]
      (A.encode (A.object [ "kind" .= ("provider" :: T.Text) ]))
    _ <- runAppStatus app req1
    req2 <- testPost ["api", "tabs", "0", "release"] BL.empty
    status <- runAppStatus app req2
    status `shouldBe` 204

  it "POST /api/tabs/0/destroy returns 204" $ do
    app <- mkApp
    req1 <- testPost ["api", "tabs", "new"]
      (A.encode (A.object [ "kind" .= ("provider" :: T.Text) ]))
    _ <- runAppStatus app req1
    req2 <- testPost ["api", "tabs", "0", "destroy"] BL.empty
    status <- runAppStatus app req2
    status `shouldBe` 204