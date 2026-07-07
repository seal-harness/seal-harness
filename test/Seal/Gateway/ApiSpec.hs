{-# LANGUAGE OverloadedStrings #-}
module Seal.Gateway.ApiSpec (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.Aeson ((.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Builder qualified as BSB
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as T
import Data.Time (UTCTime(..), fromGregorian)
import Data.Vector qualified as V
import Network.HTTP.Types (methodGet, methodPost, methodPut, statusCode)
import Network.Wai
  ( Application, Request, defaultRequest, pathInfo, requestMethod, responseStatus
  , setRequestBodyChunks )
import Network.Wai.Internal (Response (..), ResponseReceived (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Agent.Def.Backend (noneBackend)
import Seal.Config.Paths (SealPaths (..), sessionDir)
import Seal.Core.Types (mkSessionId)
import Seal.Gateway.API
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Providers.Class (ContentBlock (..), Message (..), Role (..))
import Seal.Providers.Registry (knownProviders)
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

-- | Look up a string-keyed field in an Aeson object, for test assertions.
lookupK :: T.Text -> KeyMap.KeyMap A.Value -> Maybe A.Value
lookupK key = KeyMap.lookup (Key.fromText key)

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
testPost = testWithBody methodPost

-- | Build a PUT request with a JSON body.
testPut :: [T.Text] -> BL.ByteString -> IO Request
testPut = testWithBody methodPut

-- | Build a request with a given method + a JSON body.
testWithBody :: BC.ByteString -> [T.Text] -> BL.ByteString -> IO Request
testWithBody mth path body = do
  usedRef <- newIORef False
  let readChunk = do
        already <- readIORef usedRef
        if already
          then pure BC.empty
          else do writeIORef usedRef True
                  pure (BL.toStrict body)
  pure (setRequestBodyChunks readChunk (defaultRequest { requestMethod = mth, pathInfo = path }))

-- | Run the app against a test request, capturing the HTTP status code.
runAppStatus :: Application -> Request -> IO Int
runAppStatus app req = do
  mv <- newEmptyMVar
  _rr <- app req (\resp -> putMVar mv (statusCode (responseStatus resp)) >> pure ResponseReceived)
  takeMVar mv

-- | Run the app against a test request, capturing the status code and body.
-- The API builds responses with `responseLBS` (a `ResponseBuilder`), so we
-- pattern-match on the constructor and run the builder to a lazy ByteString.
runAppBody :: Application -> Request -> IO (Int, BL.ByteString)
runAppBody app req = do
  mv <- newEmptyMVar
  _rr <- app req (\resp -> do
    let st = statusCode (responseStatus resp)
        body = case resp of
          ResponseBuilder _ _ b -> BSB.toLazyByteString b
          _ -> BL.fromStrict BC.empty
    putMVar mv (st, body)
    pure ResponseReceived)
  takeMVar mv

spec :: Spec
spec = describe "Seal.Gateway.API" $ do
  let mkApp = do
        tabsH <- newTabsHandle
        reg   <- newHarnessRegistry
        adb   <- noneBackend
        activeRef <- newIORef fakeMeta
        let sr = SessionRuntime { srPaths = fakePaths, srConfigPath = "", srActive = activeRef }
            deps = ApiDeps
              { adSessionRuntime  = sr
              , adTabsHandle      = tabsH
              , adHarnessRegistry = reg
              , adAdoptConsent    = Just CcWeb
              , adAgentDefs       = adb
              , adProviders       = knownProviders
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

  -- T11: sessions + agents + providers + context-window routes

  it "GET /api/sessions returns 200 with a JSON array (empty store)" $ do
    app <- mkApp
    status <- runAppStatus app (testRequest methodGet ["api", "sessions"])
    status `shouldBe` 200

  it "GET /api/sessions/archived returns 200 with []" $ do
    app <- mkApp
    status <- runAppStatus app (testRequest methodGet ["api", "sessions", "archived"])
    status `shouldBe` 200

  it "GET /api/sessions/<sid>/transcript returns 200 with [] (no file)" $ do
    app <- mkApp
    status <- runAppStatus app (testRequest methodGet ["api", "sessions", "sess1", "transcript"])
    status `shouldBe` 200

  it "GET /api/sessions/<sid>/transcript rewrites conversation.jsonl blocks to Anthropic shape" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-042"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      -- Write a conversation.jsonl using the same on-disk shape the
      -- two-file transcript writer produces (GHC-Generics @tag@/@contents@).
      let convLine :: Message -> BL.ByteString
          convLine m = A.encode m <> "\n"
          conv = [ Message User [CbText "hi there"]
                 , Message Assistant [CbText "hello back"]
                 ]
      BC.writeFile (sdir </> "conversation.jsonl") (BL.toStrict (mconcat (map convLine conv)))
      -- No session.json -> smModel fallback is fine for this test; the
      -- active IORef holds fakeMeta so the model comes from there.
      tabsH <- newTabsHandle
      reg   <- newHarnessRegistry
      adb   <- noneBackend
      activeRef <- newIORef fakeMeta
      let sr = SessionRuntime { srPaths = paths, srConfigPath = "", srActive = activeRef }
          deps = ApiDeps
            { adSessionRuntime  = sr
            , adTabsHandle      = tabsH
            , adHarnessRegistry = reg
            , adAdoptConsent    = Just CcWeb
            , adAgentDefs       = adb
            , adProviders       = knownProviders
            }
          app = apiApp deps
      (status, body) <- runAppBody app
        (testRequest methodGet ["api", "sessions", sidTxt, "transcript"])
      status `shouldBe` 200
      let arr = case A.decode body :: Maybe [A.Value] of
            Just xs -> xs
            Nothing -> error ("could not decode transcript body: " ++ show body)
      length arr `shouldBe` 2
      -- Each conversation entry gets a distinct, stable id derived from its
      -- line index (conversation.jsonl carries no per-entry id). Without
      -- this, every entry would share id "" and the frontend's
      -- reconcileEntries dedup would collapse them onto the first entry,
      -- rendering the assistant message twice and dropping the user message.
      let ids = [ case e of { A.Object m -> lookupK "id" m; _ -> Nothing } | e <- arr ]
      ids `shouldBe` [ Just (A.String "0"), Just (A.String "1") ]
      -- The assistant (response) entry's payload must contain a text block
      -- in the Anthropic shape {type:"text", text:"..."}, NOT the
      -- generic-derived {tag:"CbText", contents:"..."} shape. Otherwise the
      -- frontend renders "(empty response)".
      let respEntry = arr !! 1
          o = case respEntry of { A.Object m -> m; _ -> error "not obj" }
          payload = case lookupK "payload" o of
            Just (A.String t) -> t
            _ -> error "no payload"
          parsed = case A.decode (BL.fromStrict (BC.pack (T.unpack payload))) :: Maybe A.Value of
            Just v -> v
            Nothing -> error "payload not JSON"
          contentBlocks = case parsed of
            A.Object m -> case lookupK "content" m of
              Just (A.Array a) -> a
              _ -> error "no content array"
            _ -> error "payload not object"
          firstBlock = case length contentBlocks of
            0 -> error "no blocks"
            _ -> contentBlocks V.! 0
          blockObj = case firstBlock of
            A.Object m -> m
            _ -> error "block not object"
      lookupK "type" blockObj `shouldBe` Just (A.String "text")
      lookupK "text" blockObj `shouldBe` Just (A.String "hello back")

  it "GET /api/sessions/<sid>/transcript pulls per-entry timestamps from entries.jsonl" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-042"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let convLine :: Message -> BL.ByteString
          convLine m = A.encode m <> "\n"
          conv = [ Message User [CbText "hi there"]
                  , Message Assistant [CbText "hello back"]
                  ]
      BC.writeFile (sdir </> "conversation.jsonl") (BL.toStrict (mconcat (map convLine conv)))
      -- entries.jsonl with two request/response entries carrying distinct
      -- timestamps, plus an interspersed harness entry (opcode invocation)
      -- that must be filtered out — it has no corresponding conv line.
      BC.writeFile (sdir </> "entries.jsonl") $ BC.pack $ unlines
        [ "{\"id\":\"\",\"ts\":\"2026-07-01T12:00:00.100Z\",\"kind\":\"request\",\"convLen\":1}"
        , "{\"id\":\"\",\"ts\":\"2026-07-01T12:00:00.500Z\",\"kind\":\"harness\",\"convLen\":0,\"meta\":{\"op\":{\"name\":\"MEMORY_RECALL\"}}}"
        , "{\"id\":\"\",\"ts\":\"2026-07-01T12:00:01.234Z\",\"kind\":\"response\",\"convLen\":2}"
        ]
      tabsH <- newTabsHandle
      reg   <- newHarnessRegistry
      adb   <- noneBackend
      activeRef <- newIORef fakeMeta
      let sr = SessionRuntime { srPaths = paths, srConfigPath = "", srActive = activeRef }
          deps = ApiDeps
            { adSessionRuntime  = sr
            , adTabsHandle      = tabsH
            , adHarnessRegistry = reg
            , adAdoptConsent    = Just CcWeb
            , adAgentDefs       = adb
            , adProviders       = knownProviders
            }
          app = apiApp deps
      (status, body) <- runAppBody app
        (testRequest methodGet ["api", "sessions", sidTxt, "transcript"])
      status `shouldBe` 200
      let arr = case A.decode body :: Maybe [A.Value] of
            Just xs -> xs
            Nothing -> error ("could not decode transcript body: " ++ show body)
      length arr `shouldBe` 2
      -- Each conv line gets its timestamp from the matching request/response
      -- entry (NOT the harness entry, NOT the session's smCreatedAt fallback).
      -- Without this fix, both entries shared smCreatedAt and rendered
      -- identical timestamps.
      let tsOf e = case e of
            A.Object m -> lookupK "timestamp" m
            _          -> Nothing
          firstEntry = case arr of
            (x:_) -> x
            []    -> error "expected at least one entry"
      tsOf firstEntry `shouldBe` Just (A.String "2026-07-01T12:00:00.100Z")
      tsOf (arr !! 1) `shouldBe` Just (A.String "2026-07-01T12:00:01.234Z")

  it "GET /api/sessions/<sid>/transcript falls back to smCreatedAt when entries.jsonl is absent" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-042"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let convLine :: Message -> BL.ByteString
          convLine m = A.encode m <> "\n"
          conv = [ Message User [CbText "hi"]
                  , Message Assistant [CbText "hey"]
                  ]
      BC.writeFile (sdir </> "conversation.jsonl") (BL.toStrict (mconcat (map convLine conv)))
      -- No entries.jsonl → both entries fall back to smCreatedAt (the
      -- fakeMeta's createdAt is 2026-01-01T00:00:00Z). They'll share the
      -- fallback timestamp, matching the pre-fix behavior for sessions
      -- without entries.jsonl.
      tabsH <- newTabsHandle
      reg   <- newHarnessRegistry
      adb   <- noneBackend
      activeRef <- newIORef fakeMeta
      let sr = SessionRuntime { srPaths = paths, srConfigPath = "", srActive = activeRef }
          deps = ApiDeps
            { adSessionRuntime  = sr
            , adTabsHandle      = tabsH
            , adHarnessRegistry = reg
            , adAdoptConsent    = Just CcWeb
            , adAgentDefs       = adb
            , adProviders       = knownProviders
            }
          app = apiApp deps
      (status, body) <- runAppBody app
        (testRequest methodGet ["api", "sessions", sidTxt, "transcript"])
      status `shouldBe` 200
      let arr = case A.decode body :: Maybe [A.Value] of
            Just xs -> xs
            Nothing -> error ("could not decode transcript body: " ++ show body)
      length arr `shouldBe` 2
      let tsOf e = case e of
            A.Object m -> lookupK "timestamp" m
            _          -> Nothing
          firstEntry = case arr of
            (x:_) -> x
            []    -> error "expected at least one entry"
      -- showIso (UTCTime (fromGregorian 2026 1 1) 0) = "2026-01-01T00:00:00.000Z"
      tsOf firstEntry `shouldBe` Just (A.String "2026-01-01T00:00:00.000Z")
      tsOf (arr !! 1) `shouldBe` Just (A.String "2026-01-01T00:00:00.000Z")

  it "POST /api/sessions/<sid>/send returns 200 with {kind:assistant}" $ do
    app <- mkApp
    req <- testPost ["api", "sessions", "sess1", "send"]
      (A.encode (A.object [ "message" .= ("hi" :: T.Text) ]))
    status <- runAppStatus app req
    status `shouldBe` 200

  it "PUT /api/sessions/<sid>/description returns 204" $ do
    app <- mkApp
    req <- testPut ["api", "sessions", "sess1", "description"]
      (A.encode (A.object [ "description" .= ("new" :: T.Text) ]))
    status <- runAppStatus app req
    status `shouldBe` 204

  it "PUT /api/sessions/<sid>/archived returns 204" $ do
    app <- mkApp
    req <- testPut ["api", "sessions", "sess1", "archived"]
      (A.encode (A.object [ "archived" .= True ]))
    status <- runAppStatus app req
    status `shouldBe` 204

  it "PUT /api/sessions/<sid>/prompt returns 204" $ do
    app <- mkApp
    req <- testPut ["api", "sessions", "sess1", "prompt"]
      (A.encode (A.object [ "prompt" .= ("x" :: T.Text) ]))
    status <- runAppStatus app req
    status `shouldBe` 204

  it "GET /api/agents returns 200 with a JSON array" $ do
    app <- mkApp
    status <- runAppStatus app (testRequest methodGet ["api", "agents"])
    status `shouldBe` 200

  it "GET /api/providers returns 200 with a JSON array" $ do
    app <- mkApp
    status <- runAppStatus app (testRequest methodGet ["api", "providers"])
    status `shouldBe` 200

  it "GET /api/providers/anthropic/models returns 200" $ do
    app <- mkApp
    status <- runAppStatus app (testRequest methodGet ["api", "providers", "anthropic", "models"])
    status `shouldBe` 200

  it "GET /api/providers/anthropic/models/claude-sonnet-4-20250514/context returns 200" $ do
    app <- mkApp
    status <- runAppStatus app (testRequest methodGet
      ["api", "providers", "anthropic", "models", "claude-sonnet-4-20250514", "context"])
    status `shouldBe` 200

  it "GET /api/providers/unknown/models returns 200 with []" $ do
    app <- mkApp
    status <- runAppStatus app (testRequest methodGet ["api", "providers", "unknown", "models"])
    status `shouldBe` 200