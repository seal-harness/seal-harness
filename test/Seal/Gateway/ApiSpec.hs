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
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text qualified as T
import Data.Time (UTCTime(..), fromGregorian)
import Data.Vector qualified as V
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Network.HTTP.Types (methodGet, methodPost, methodPut, statusCode)
import Network.Wai
  ( Application, Request, defaultRequest, pathInfo, requestMethod, responseStatus
  , setRequestBodyChunks )
import Network.Wai.Internal (Response (..), ResponseReceived (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Agent.Def.Backend (noneBackend, adbUpdate)
import Seal.Agent.Def.Types (AgentDef (..), mkAgentDefId)
import Seal.Channel.Cli (Backends (..), newBackends)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec (mkRegistry)
import Seal.Config.Paths (SealPaths (..), sessionDir, sessionMetaPath)
import Seal.Core.AllowList (AllowList (..))
import Seal.Core.Types (ModelId (..), SessionId (..), mkSessionId, ToolCallId (..), OpName (..))
import Seal.Gateway.API
import Seal.Gateway.Send (SendDeps (..))
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Harness.Tmux (mkRealTmuxRunner)
import Seal.Handles.AskReply (newApprovalCache, newAskReplyStore)
import Seal.Ingest (emptyChain)
import Seal.Providers.Class
  ( ContentBlock (..), Message (..), Role (..), ToolResultPart (..)
  , SomeProvider (..), Provider (..), CompletionResponse (..), StopReason (..), Usage (..) )
import Seal.Providers.Registry (KnownProvider (..), knownProviders)
import Seal.Security.Adoption (ConsentChannel (..))
import Seal.Security.Policy qualified as Policy (AutonomyLevel (Full))
import Seal.Security.Vault (VaultHandle)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), saveSessionMeta)
import Seal.Session.Lock (newSessionLocks, newReplyRegistry)
import Seal.Tabs (newTabsHandle)
import Seal.Vault.Commands (VaultRuntime (..))
import Seal.Web.UiState (newUiStateHandle)

-- | A provider that returns a scripted list of responses, one per call
-- (mirrors the test helpers in LoopSpec/Phase5Spec). Used by the e2e send
-- test so it's deterministic (no live Ollama/Anthropic call).
newtype ScriptProvider = ScriptProvider (IORef [CompletionResponse])
instance Provider ScriptProvider where
  listModels _ = pure (Right [])
  complete (ScriptProvider ref) _ = do
    rs <- readIORef ref
    case rs of
      (x:xs) -> writeIORef ref xs >> pure (Right x)
      [] -> pure (Right (CompletionResponse [CbText "done"] StopEnd (Usage 0 0)))

fakePaths :: SealPaths
fakePaths = SealPaths
  { spHome = "", spState = "", spConfig = "", spKeys = "" }

fakeMeta :: SessionMeta
fakeMeta =
  let sid = case mkSessionId "test" of Right s -> s; Left _ -> error "sid"
  in SessionMeta sid "ollama" "llama3" "cli" Nothing Nothing Nothing (UTCTime (fromGregorian 2026 1 1) 0) (UTCTime (fromGregorian 2026 1 1) 0)

-- | Look up a string-keyed field in an Aeson object, for test assertions.
lookupK :: T.Text -> KeyMap.KeyMap A.Value -> Maybe A.Value
lookupK key = KeyMap.lookup (Key.fromText key)

-- | Predicate: the 'Value' is a JSON array.
isJustArray :: Maybe A.Value -> Bool
isJustArray (Just (A.Array _)) = True
isJustArray _                  = False

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

-- | Build 'ApiDeps' against the given paths with the common test fakes.
-- Used by the transcript tests that need a per-test temp dir.
mkDepsFor :: SealPaths -> IO ApiDeps
mkDepsFor paths = do
  tabsH <- newTabsHandle
  reg   <- newHarnessRegistry
  adb   <- noneBackend
  activeRef <- newIORef fakeMeta
  uiState <- newUiStateHandle paths
  let sr = SessionRuntime { srPaths = paths, srConfigPath = "", srActive = activeRef }
  pure ApiDeps
    { adSessionRuntime  = sr
    , adTabsHandle      = tabsH
    , adHarnessRegistry = reg
    , adAdoptConsent    = Just CcWeb
    , adAgentDefs       = adb
    , adProviders       = pure knownProviders
    , adUiState         = uiState
    , adSend            = Nothing
    , adDefaultAgent    = Nothing
    }

spec :: Spec
spec = describe "Seal.Gateway.API" $ do
  -- Shared temp dir for all mkApp-based tests. POST /api/tabs/new with
  -- kind=provider calls newSession, which writes session.json under
  -- spState/sessions/. With spState="" that resolves to ./sessions/ in the
  -- CWD, polluting the repo root. The temp dir isolates these writes.
  -- runIO runs at spec-construction time; the OS cleans up $TMPDIR
  -- (/var/folders/... on macOS) automatically.
  sharedStateDir <- runIO $ do
    dir <- withSystemTempDirectory "seal-api-spec" pure
    createDirectoryIfMissing True (dir </> "sessions")
    pure dir

  let mkPaths = fakePaths { spState = sharedStateDir }
      mkApp = apiApp <$> mkDepsFor mkPaths

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

  it "GET /api/sessions includes firstMessageSnippet from conversation.jsonl" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-042"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      let convLine :: Message -> BL.ByteString
          convLine m = A.encode m <> "\n"
          conv = [ Message User [CbText "Fix the login bug please"]
                  , Message Assistant [CbText "Sure, let me look"]
                  ]
      BC.writeFile (sdir </> "conversation.jsonl") (BL.toStrict (mconcat (map convLine conv)))
      deps <- mkDepsFor paths
      let app = apiApp deps
      (status, body) <- runAppBody app (testRequest methodGet ["api", "sessions"])
      status `shouldBe` 200
      let arr = case A.decode body :: Maybe [A.Value] of
            Just xs -> xs
            Nothing -> error ("could not decode sessions body: " ++ show body)
      length arr `shouldBe` 1
      let o = case arr of
            (A.Object m : _) -> m
            _ -> error "first session not an object"
      lookupK "firstMessageSnippet" o `shouldBe` Just (A.String "Fix the login bug please")

  it "GET /api/sessions truncates long firstMessageSnippet to 80 chars + ellipsis" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-042"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      let longMsg = T.replicate 100 "x"
          convLine :: Message -> BL.ByteString
          convLine m = A.encode m <> "\n"
      BC.writeFile (sdir </> "conversation.jsonl") (BL.toStrict (convLine (Message User [CbText longMsg])))
      deps <- mkDepsFor paths
      let app = apiApp deps
      (status, body) <- runAppBody app (testRequest methodGet ["api", "sessions"])
      status `shouldBe` 200
      let arr = case A.decode body :: Maybe [A.Value] of
            Just xs -> xs
            Nothing -> error ("could not decode sessions body: " ++ show body)
      let o = case arr of
            (A.Object m : _) -> m
            _ -> error "first session not an object"
      case lookupK "firstMessageSnippet" o of
        Just (A.String snippet) -> do
          T.length snippet `shouldBe` 81
          T.drop 80 snippet `shouldBe` "…"
        other -> error ("unexpected snippet: " ++ show other)

  it "GET /api/sessions returns null firstMessageSnippet when no conversation exists" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-042"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      deps <- mkDepsFor paths
      let app = apiApp deps
      (status, body) <- runAppBody app (testRequest methodGet ["api", "sessions"])
      status `shouldBe` 200
      let arr = case A.decode body :: Maybe [A.Value] of
            Just xs -> xs
            Nothing -> error ("could not decode sessions body: " ++ show body)
      let o = case arr of
            (A.Object m : _) -> m
            _ -> error "first session not an object"
      lookupK "firstMessageSnippet" o `shouldBe` Just A.Null

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
      deps <- mkDepsFor paths
      let app = apiApp deps
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

  it "GET /api/sessions/<sid>/transcript rewrites CbToolUse and CbToolResult blocks to Anthropic shape" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-042"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      -- Write a conversation with tool_use (Assistant) + tool_result (User).
      -- The on-disk shape is aeson's default TaggedObject: CbToolUse fields
      -- are at the TOP LEVEL alongside "tag" (no "contents" wrapper). If
      -- cbToFrontend looks for them under "contents", it falls back to a
      -- text block with raw JSON — which is the bug this test guards against.
      let convLine :: Message -> BL.ByteString
          convLine m = A.encode m <> "\n"
          conv = [ Message User [CbText "list files"]
                  , Message Assistant
                      [ CbToolUse (ToolCallId "call_0") (OpName "FILE_READ")
                          (A.object ["path" .= ("src/main.hs" :: T.Text)])
                      ]
                  , Message User
                      [ CbToolResult (ToolCallId "call_0")
                          [TrpText "module Main where"]
                          False
                      ]
                  , Message Assistant [CbText "done"]
                  ]
      BC.writeFile (sdir </> "conversation.jsonl") (BL.toStrict (mconcat (map convLine conv)))
      deps <- mkDepsFor paths
      let app = apiApp deps
      (status, body) <- runAppBody app
        (testRequest methodGet ["api", "sessions", sidTxt, "transcript"])
      status `shouldBe` 200
      let arr = case A.decode body :: Maybe [A.Value] of
            Just xs -> xs
            Nothing -> error ("could not decode transcript body: " ++ show body)
      length arr `shouldBe` 4
      -- Entry 1 (Assistant tool_use) must produce a tool_use block, NOT a
      -- fallback text block with raw JSON.
      let respEntry = arr !! 1
          ro = case respEntry of { A.Object m -> m; _ -> error "resp not obj" }
          rpayload = case lookupK "payload" ro of
            Just (A.String t) -> t
            _ -> error "no resp payload"
          rparsed = case A.decode (BL.fromStrict (BC.pack (T.unpack rpayload))) :: Maybe A.Value of
            Just v -> v
            Nothing -> error "resp payload not JSON"
          rcontent = case rparsed of
            A.Object m -> case lookupK "content" m of
              Just (A.Array a) -> a
              _ -> error "no resp content array"
            _ -> error "resp payload not object"
          toolUseBlock = case rcontent V.! 0 of
            A.Object m -> m
            _ -> error "tool_use block not object"
      lookupK "type" toolUseBlock `shouldBe` Just (A.String "tool_use")
      lookupK "id"   toolUseBlock `shouldBe` Just (A.String "call_0")
      lookupK "name" toolUseBlock `shouldBe` Just (A.String "FILE_READ")
      -- Entry 2 (User tool_result) must produce a tool_result block, NOT a
      -- fallback text block. This is the entry that was rendering as a "You"
      -- message with raw JSON.
      let reqEntry = arr !! 2
          qo = case reqEntry of { A.Object m -> m; _ -> error "req not obj" }
          qpayload = case lookupK "payload" qo of
            Just (A.String t) -> t
            _ -> error "no req payload"
          qparsed = case A.decode (BL.fromStrict (BC.pack (T.unpack qpayload))) :: Maybe A.Value of
            Just v -> v
            Nothing -> error "req payload not JSON"
          qmsgs = case qparsed of
            A.Object m -> case lookupK "messages" m of
              Just (A.Array a) -> a
              _ -> error "no messages array"
            _ -> error "req payload not object"
          qmsg = case qmsgs V.! 0 of
            A.Object m -> case lookupK "content" m of
              Just (A.Array a) -> a
              _ -> error "no msg content array"
            _ -> error "msg not object"
          toolResultBlock = case qmsg V.! 0 of
            A.Object m -> m
            _ -> error "tool_result block not object"
      lookupK "type"        toolResultBlock `shouldBe` Just (A.String "tool_result")
      lookupK "tool_use_id" toolResultBlock `shouldBe` Just (A.String "call_0")
      lookupK "is_error"    toolResultBlock `shouldBe` Just (A.Bool False)
      -- The content field must be rewritten from the on-disk ToolResultPart
      -- encoding (bare strings: ["module Main where"]) to the Anthropic
      -- shape: [{type:"text", text:"module Main where"}].
      case lookupK "content" toolResultBlock of
        Just (A.Array parts) -> do
          let p0 = case V.toList parts of (x : _) -> x; [] -> error "empty parts"
          case p0 of
            A.Object po -> do
              lookupK "type" po `shouldBe` Just (A.String "text")
              lookupK "text" po `shouldBe` Just (A.String "module Main where")
            _ -> error ("content part is not an object: " ++ show p0)
        other -> error ("content is not an array: " ++ show other)

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
      deps <- mkDepsFor paths
      let app = apiApp deps
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

  it "GET /api/sessions/<sid>/transcript includes the system prompt in request payloads (two-file format)" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-042"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let convLine :: Message -> BL.ByteString
          convLine m = A.encode m <> "\n"
          conv = [ Message User [CbText "hello"] ]
      BC.writeFile (sdir </> "conversation.jsonl") (BL.toStrict (mconcat (map convLine conv)))
      -- entries.jsonl: one request entry carrying an envelope delta with
      -- system = "You are a helpful assistant." The reconstruct path folds
      -- this delta and the frontend's transcriptToMessages extracts the
      -- `system` field into a collapsed "System" row at the top of the
      -- session. Without the system field in the payload, the row is absent.
      BC.writeFile (sdir </> "entries.jsonl") $ BC.pack $ unlines
        [ "{\"id\":\"e1\",\"ts\":\"2026-07-01T12:00:00.000Z\",\"kind\":\"request\",\"convLen\":1,\"envelope\":{\"model\":\"claude-sonnet-4-20250514\",\"system\":\"You are a helpful assistant.\",\"tools\":[],\"toolChoice\":\"ToolAuto\",\"maxTokens\":8192}}"
        ]
      deps <- mkDepsFor paths
      let app = apiApp deps
      (status, body) <- runAppBody app
        (testRequest methodGet ["api", "sessions", sidTxt, "transcript"])
      status `shouldBe` 200
      let arr = case A.decode body :: Maybe [A.Value] of
            Just xs -> xs
            Nothing -> error ("could not decode transcript body: " ++ show body)
      length arr `shouldBe` 1
      -- The request entry's payload must carry a `system` field with the
      -- system prompt text. The frontend reads `parsed.system` to synthesize
      -- the collapsed "System" row.
      let reqEntry = case arr of
            (x:_) -> x
            []    -> error "expected at least one entry"
          ro = case reqEntry of { A.Object m -> m; _ -> error "req not obj" }
          rpayload = case lookupK "payload" ro of
            Just (A.String t) -> t
            _                 -> error "no req payload"
          rparsed = case A.decode (BL.fromStrict (BC.pack (T.unpack rpayload))) :: Maybe A.Value of
            Just v -> v
            Nothing -> error "req payload not JSON"
          systemField = case rparsed of
            A.Object m -> lookupK "system" m
            _          -> Nothing
      systemField `shouldBe` Just (A.String "You are a helpful assistant.")

  it "GET /api/sessions/<sid>/transcript lowercases message roles for the frontend (two-file format)" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-042"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let convLine :: Message -> BL.ByteString
          convLine m = A.encode m <> "\n"
          conv = [ Message User [CbText "hello world"] ]
      BC.writeFile (sdir </> "conversation.jsonl") (BL.toStrict (mconcat (map convLine conv)))
      BC.writeFile (sdir </> "entries.jsonl") $ BC.pack $ unlines
        [ "{\"id\":\"e1\",\"ts\":\"2026-07-01T12:00:00.000Z\",\"kind\":\"request\",\"convLen\":1,\"envelope\":{\"model\":\"claude-sonnet-4-20250514\",\"system\":\"You are helpful.\",\"tools\":[],\"toolChoice\":\"ToolAuto\",\"maxTokens\":8192}}"
        ]
      deps <- mkDepsFor paths
      let app = apiApp deps
      (status, body) <- runAppBody app
        (testRequest methodGet ["api", "sessions", sidTxt, "transcript"])
      status `shouldBe` 200
      let arr = case A.decode body :: Maybe [A.Value] of
            Just xs -> xs
            Nothing -> error ("could not decode transcript body: " ++ show body)
      length arr `shouldBe` 1
      let reqEntry = case arr of
            (x:_) -> x
            []    -> error "expected at least one entry"
          ro = case reqEntry of { A.Object m -> m; _ -> error "req not obj" }
          rpayload = case lookupK "payload" ro of
            Just (A.String t) -> t
            _                 -> error "no req payload"
          rparsed = case A.decode (BL.fromStrict (BC.pack (T.unpack rpayload))) :: Maybe A.Value of
            Just v -> v
            Nothing -> error "req payload not JSON"
          msgs = case rparsed of
            A.Object m -> case lookupK "messages" m of
              Just (A.Array a) -> a
              _                -> error "no messages array"
            _ -> error "payload not object"
          firstMsg = case msgs V.! 0 of
            A.Object m -> m
            _          -> error "msg not object"
      -- GHC-Generics encodes Role as "User"/"Assistant" (capitalized); the
      -- frontend checks `msg.role === "user"` (lowercase). The rewrite must
      -- lowercase the role or the user's first message won't render.
      lookupK "role" firstMsg `shouldBe` Just (A.String "user")
      lookupK "content" firstMsg `shouldSatisfy` isJustArray

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
      deps <- mkDepsFor paths
      let app = apiApp deps
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

  it "PUT /api/sessions/<sid>/prompt returns 200 when the session exists" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-051"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      deps <- mkDepsFor paths
      let app = apiApp deps
      req <- testPut ["api", "sessions", sidTxt, "prompt"]
        (A.encode (A.object [ "prompt" .= ("be concise" :: T.Text) ]))
      status <- runAppStatus app req
      status `shouldBe` 200

  it "PUT /api/sessions/<sid>/prompt with empty body clears the override" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-052"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      deps <- mkDepsFor paths
      let app = apiApp deps
      req <- testPut ["api", "sessions", sidTxt, "prompt"]
        (A.encode (A.object [ "prompt" .= ("" :: T.Text) ]))
      status <- runAppStatus app req
      status `shouldBe` 200

  it "PUT /api/sessions/<sid>/prompt returns 404 when the session is missing" $ do
    app <- mkApp
    req <- testPut ["api", "sessions", "20260701-999999-998", "prompt"]
      (A.encode (A.object [ "prompt" .= ("x" :: T.Text) ]))
    status <- runAppStatus app req
    status `shouldBe` 404

  it "PUT /api/sessions/<sid>/agent returns 200 when the session exists" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-042"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      deps <- mkDepsFor paths
      let app = apiApp deps
      req <- testPut ["api", "sessions", sidTxt, "agent"]
        (A.encode (A.object [ "agent" .= ("dev" :: T.Text) ]))
      status <- runAppStatus app req
      status `shouldBe` 200

  it "PUT /api/sessions/<sid>/agent with empty body clears the binding" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-043"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      deps <- mkDepsFor paths
      let app = apiApp deps
      req <- testPut ["api", "sessions", sidTxt, "agent"]
        (A.encode (A.object [ "agent" .= ("" :: T.Text) ]))
      status <- runAppStatus app req
      status `shouldBe` 200

  it "PUT /api/sessions/<sid>/agent returns 404 when the session is missing" $ do
    app <- mkApp
    req <- testPut ["api", "sessions", "20260701-999999-999", "agent"]
      (A.encode (A.object [ "agent" .= ("dev" :: T.Text) ]))
    status <- runAppStatus app req
    status `shouldBe` 404

  it "PUT /api/sessions/<sid>/agent returns 400 on an invalid agent id" $ do
    app <- mkApp
    req <- testPut ["api", "sessions", "sess1", "agent"]
      (A.encode (A.object [ "agent" .= ("bad/id with spaces" :: T.Text) ]))
    status <- runAppStatus app req
    status `shouldBe` 400

  it "PUT /api/sessions/<sid>/agent atomically clears an existing system_override" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-061"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let aid = case mkAgentDefId "dev" of Right x -> x; Left _ -> error "aid"
          meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" (Just aid) (Just "one-off") Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      deps <- mkDepsFor paths
      let app = apiApp deps
      req <- testPut ["api", "sessions", sidTxt, "agent"]
        (A.encode (A.object [ "agent" .= ("zoe" :: T.Text) ]))
      status <- runAppStatus app req
      status `shouldBe` 200
      -- Reload session.json and verify smAgent=zoe, smSystemOverride=Nothing
      let mp = sessionMetaPath paths sid
      mSaved <- A.decode <$> BL.readFile mp :: IO (Maybe A.Value)
      case mSaved of
        Just (A.Object o) -> do
          lookupK "agent" o `shouldBe` Just (A.String "zoe")
          lookupK "system_override" o `shouldBe` Just A.Null
        _ -> expectationFailure "session.json missing or unparseable"

  it "PUT /api/sessions/<sid>/prompt atomically clears an existing agent binding" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-062"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let aid = case mkAgentDefId "dev" of Right x -> x; Left _ -> error "aid"
          meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" (Just aid) Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      deps <- mkDepsFor paths
      let app = apiApp deps
      req <- testPut ["api", "sessions", sidTxt, "prompt"]
        (A.encode (A.object [ "prompt" .= ("be concise" :: T.Text) ]))
      status <- runAppStatus app req
      status `shouldBe` 200
      let mp = sessionMetaPath paths sid
      mSaved <- A.decode <$> BL.readFile mp :: IO (Maybe A.Value)
      case mSaved of
        Just (A.Object o) -> do
          lookupK "agent" o `shouldBe` Just A.Null
          lookupK "system_override" o `shouldBe` Just (A.String "be concise")
        _ -> expectationFailure "session.json missing or unparseable"

  it "PUT /api/sessions/<sid>/agent with empty body does NOT clobber an active system_override" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-063"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing (Just "one-off") Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      deps <- mkDepsFor paths
      let app = apiApp deps
      req <- testPut ["api", "sessions", sidTxt, "agent"]
        (A.encode (A.object [ "agent" .= ("" :: T.Text) ]))
      status <- runAppStatus app req
      status `shouldBe` 200
      let mp = sessionMetaPath paths sid
      mSaved <- A.decode <$> BL.readFile mp :: IO (Maybe A.Value)
      case mSaved of
        Just (A.Object o) -> do
          lookupK "agent" o `shouldBe` Just A.Null
          lookupK "system_override" o `shouldBe` Just (A.String "one-off")
        _ -> expectationFailure "session.json missing or unparseable"

  it "PUT /api/sessions/<sid>/agent sets agent_name to the agent's id" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-071"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      deps <- mkDepsFor paths
      let app = apiApp deps
      req <- testPut ["api", "sessions", sidTxt, "agent"]
        (A.encode (A.object [ "agent" .= ("zoe" :: T.Text) ]))
      status <- runAppStatus app req
      status `shouldBe` 200
      let mp = sessionMetaPath paths sid
      mSaved <- A.decode <$> BL.readFile mp :: IO (Maybe A.Value)
      case mSaved of
        Just (A.Object o) -> lookupK "agent_name" o `shouldBe` Just (A.String "zoe")
        _ -> expectationFailure "session.json missing or unparseable"

  it "PUT /api/sessions/<sid>/prompt sets agent_name from the file's frontmatter id" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-072"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
          fileContent = "---\nid: my-uploaded-agent\n---\nYou are a helpful agent."
      saveSessionMeta paths meta
      deps <- mkDepsFor paths
      let app = apiApp deps
      req <- testPut ["api", "sessions", sidTxt, "prompt"]
        (A.encode (A.object [ "prompt" .= (fileContent :: T.Text), "name" .= ("my-agent.md" :: T.Text) ]))
      status <- runAppStatus app req
      status `shouldBe` 200
      let mp = sessionMetaPath paths sid
      mSaved <- A.decode <$> BL.readFile mp :: IO (Maybe A.Value)
      case mSaved of
        Just (A.Object o) -> do
          lookupK "agent" o `shouldBe` Just A.Null
          lookupK "system_override" o `shouldBe` Just (A.String fileContent)
          lookupK "agent_name" o `shouldBe` Just (A.String "my-uploaded-agent")
        _ -> expectationFailure "session.json missing or unparseable"

  it "PUT /api/sessions/<sid>/prompt falls back to the name field when no frontmatter id" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-073"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
          fileContent = "You are a helpful agent with no frontmatter."
      saveSessionMeta paths meta
      deps <- mkDepsFor paths
      let app = apiApp deps
      req <- testPut ["api", "sessions", sidTxt, "prompt"]
        (A.encode (A.object [ "prompt" .= (fileContent :: T.Text), "name" .= ("random-prompt.md" :: T.Text) ]))
      status <- runAppStatus app req
      status `shouldBe` 200
      let mp = sessionMetaPath paths sid
      mSaved <- A.decode <$> BL.readFile mp :: IO (Maybe A.Value)
      case mSaved of
        Just (A.Object o) ->
          lookupK "agent_name" o `shouldBe` Just (A.String "random-prompt.md")
        _ -> expectationFailure "session.json missing or unparseable"

  it "GET /api/sessions emits agent from agent_name when set" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-074"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing (Just "my-uploaded-agent")
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      deps <- mkDepsFor paths
      let app = apiApp deps
      (_, body) <- runAppBody app (testRequest methodGet ["api", "sessions"])
      let arr = case A.decode body :: Maybe [A.Value] of
            Just xs -> xs
            Nothing -> error ("could not decode sessions body: " ++ show body)
      length arr `shouldBe` 1
      case arr of
        (A.Object o : _) -> lookupK "agent" o `shouldBe` Just (A.String "my-uploaded-agent")
        _                -> expectationFailure "no session row"

  it "GET /api/agents returns 200 with a JSON array" $ do
    app <- mkApp
    status <- runAppStatus app (testRequest methodGet ["api", "agents"])
    status `shouldBe` 200

  it "GET /api/agents marks the configured default agent isDefault=true" $ do
    -- Seed two agent defs, configure `default_agent = "zoe"`, and verify
    -- the zoe entry has isDefault=true and the other false.
    let mkAppDefault = do
          tabsH <- newTabsHandle
          reg   <- newHarnessRegistry
          adb   <- noneBackend
          activeRef <- newIORef fakeMeta
          uiState <- newUiStateHandle mkPaths
          let now = UTCTime (fromGregorian 2026 7 1) 0
          let zoeId  = case mkAgentDefId "zoe" of Right x -> x; Left _ -> error "zoe"
              devId  = case mkAgentDefId "dev" of Right x -> x; Left _ -> error "dev"
              mkZoe = AgentDef zoeId "zoe" "" (ModelId "") Nothing AllowAll now now (SessionId "manual")
              mkDev = AgentDef devId "dev" "" (ModelId "") Nothing AllowAll now now (SessionId "manual")
          adbUpdate adb mkZoe
          adbUpdate adb mkDev
          let sr = SessionRuntime { srPaths = mkPaths, srConfigPath = "", srActive = activeRef }
              deps = ApiDeps
                { adSessionRuntime  = sr
                , adTabsHandle      = tabsH
                , adHarnessRegistry = reg
                , adAdoptConsent    = Just CcWeb
                , adAgentDefs       = adb
                , adProviders       = pure knownProviders
                , adUiState         = uiState
                , adSend            = Nothing
                , adDefaultAgent    = Just "zoe"
                }
          pure (apiApp deps)
    app <- mkAppDefault
    (_, body) <- runAppBody app (testRequest methodGet ["api", "agents"])
    let arr = case A.decode body :: Maybe [A.Value] of
          Just xs -> xs
          Nothing -> error ("could not decode agents body: " ++ show body)
    length arr `shouldBe` 2
    let isDefaultOf v = case v of
          A.Object o -> case lookupK "isDefault" o of
            Just (A.Bool b) -> Just b
            _               -> Nothing
          _ -> Nothing
        nameOf v = case v of
          A.Object o -> case lookupK "name" o of
            Just (A.String n) -> Just n
            _                  -> Nothing
          _ -> Nothing
    let zoe = filter (\v -> nameOf v == Just "zoe") arr
        dev = filter (\v -> nameOf v == Just "dev") arr
    length zoe `shouldBe` 1
    length dev `shouldBe` 1
    case zoe of (z:_) -> isDefaultOf z `shouldBe` Just True
                _     -> expectationFailure "zoe missing"
    case dev of (d:_) -> isDefaultOf d `shouldBe` Just False
                _     -> expectationFailure "dev missing"

  it "GET /api/providers returns 200 with a JSON array" $ do
    app <- mkApp
    status <- runAppStatus app (testRequest methodGet ["api", "providers"])
    status `shouldBe` 200

  it "GET /api/providers returns only the configured providers" $ do
    -- adProviders is an IO action; a filtered list means only the configured
    -- providers appear (here: ollama only, since no vault/credentials).
    let mkAppFiltered = do
          tabsH <- newTabsHandle
          reg   <- newHarnessRegistry
          adb   <- noneBackend
          activeRef <- newIORef fakeMeta
          uiState <- newUiStateHandle mkPaths
          let sr = SessionRuntime { srPaths = mkPaths, srConfigPath = "", srActive = activeRef }
              deps = ApiDeps
                { adSessionRuntime  = sr
                , adTabsHandle      = tabsH
                , adHarnessRegistry = reg
                , adAdoptConsent    = Just CcWeb
                , adAgentDefs       = adb
                , adProviders       = pure [OllamaProvider]
                , adUiState         = uiState
                , adSend            = Nothing
                , adDefaultAgent    = Nothing
                }
          pure (apiApp deps)
    app <- mkAppFiltered
    (_, body) <- runAppBody app (testRequest methodGet ["api", "providers"])
    let arr = case A.decode body :: Maybe [A.Value] of
          Just xs -> xs
          Nothing -> error ("could not decode providers body: " ++ show body)
    length arr `shouldBe` 1
    let nm = case arr of
          (A.Object o : _) -> case lookupK "name" o of
            Just (A.String n) -> n
            _ -> error "no name field"
          _ -> error "not an object"
    nm `shouldBe` "ollama"

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

  -- ── UI state (persisted "new tab" recall) ─────────────────────────────
  -- GET /api/ui/state returns the empty state by default (no file). PUT
  -- /api/ui/state persists the last-chosen options; a follow-up GET
  -- round-trips them. POST /api/ui/custom-models appends to the history;
  -- a follow-up GET lists it.
  it "GET /api/ui/state returns 200 with empty state by default" $ do
    app <- mkApp
    (status, body) <- runAppBody app (testRequest methodGet ["api", "ui", "state"])
    status `shouldBe` 200
    let obj = case A.decode body :: Maybe A.Value of
          Just o -> o
          Nothing -> error ("could not decode ui state: " ++ show body)
        lo = case obj of { A.Object o -> lookupK "last_options" o; _ -> Nothing }
        cms = case obj of { A.Object o -> lookupK "custom_models" o; _ -> Nothing }
    -- last_options is null (Nothing encoded as JSON null); custom_models
    -- is an empty array.
    lo `shouldBe` Just A.Null
    cms `shouldBe` Just (A.Array V.empty)

  it "PUT /api/ui/state persists last_options and round-trips via GET" $
    withSystemTempDirectory "seal-ui-state" $ \tmp -> do
      let paths = fakePaths { spState = tmp }
      deps <- mkDepsFor paths
      let app = apiApp deps
      let opts = A.object
            [ "kind"           .= ("provider" :: T.Text)
            , "provider"       .= ("ollama" :: T.Text)
            , "model"          .= ("llama3.2" :: T.Text)
            , "useCustomModel" .= False
            , "agent"          .= ("" :: T.Text)
            , "flavour"        .= ("claude-code" :: T.Text)
            , "customBinary"   .= ("" :: T.Text)
            , "attachSession"  .= ("" :: T.Text)
            , "attachWindow"   .= ("" :: T.Text)
            , "attachManual"   .= False
            ]
      putReq <- testPut ["api", "ui", "state"] (A.encode opts)
      putStatus <- runAppStatus app putReq
      putStatus `shouldBe` 200
      -- Reload the handle from disk to prove the write persisted.
      deps2 <- mkDepsFor paths
      let app2 = apiApp deps2
      (getStatus, getBody) <- runAppBody app2 (testRequest methodGet ["api", "ui", "state"])
      getStatus `shouldBe` 200
      let lo = case A.decode getBody :: Maybe A.Value of
            Just (A.Object o) -> lookupK "last_options" o
            _                 -> error ("could not decode GET body: " ++ show getBody)
      lo `shouldSatisfy` \case
        Just (A.Object o) -> case lookupK "model" o of
          Just (A.String m) -> m == "llama3.2"
          _                 -> False
        _ -> False

  it "POST /api/ui/custom-models appends and lists via GET" $
    withSystemTempDirectory "seal-ui-models" $ \tmp -> do
      let paths = fakePaths { spState = tmp }
      deps <- mkDepsFor paths
      let app = apiApp deps
      addReq <- testPost ["api", "ui", "custom-models"]
        (A.encode (A.object [ "model" .= ("claude-3-opus" :: T.Text) ]))
      addStatus <- runAppStatus app addReq
      addStatus `shouldBe` 200
      -- Adding a second model keeps both, most-recent first.
      addReq2 <- testPost ["api", "ui", "custom-models"]
        (A.encode (A.object [ "model" .= ("gpt-4o" :: T.Text) ]))
      _ <- runAppStatus app addReq2
      -- Adding a duplicate dedupes (moves to front).
      addReq3 <- testPost ["api", "ui", "custom-models"]
        (A.encode (A.object [ "model" .= ("claude-3-opus" :: T.Text) ]))
      _ <- runAppStatus app addReq3
      -- Reload from disk to prove persistence.
      deps2 <- mkDepsFor paths
      let app2 = apiApp deps2
      (_, getBody) <- runAppBody app2 (testRequest methodGet ["api", "ui", "state"])
      let cms = case A.decode getBody :: Maybe A.Value of
            Just (A.Object o) -> case lookupK "custom_models" o of
              Just (A.Array a) -> V.toList a
              _               -> error "no custom_models array"
            _ -> error "could not decode GET body"
      let toText v = case v of { A.String t -> t; _ -> "" }
      map toText cms `shouldBe` ["claude-3-opus", "gpt-4o"]

  -- ── Wired send path (adSend = Just SendDeps) ──────────────────────────
  -- A session that doesn't exist on disk returns 404. This exercises the
  -- handleSend -> loadSessionMeta -> Nothing path without needing a real
  -- provider/vault (the lookup happens before provider resolution).
  it "POST /api/sessions/<sid>/send with adSend wired returns 404 for a missing session" $ do
    withSystemTempDirectory "seal-send" $ \tmp -> do
      tabsH <- newTabsHandle
      reg   <- newHarnessRegistry
      adb   <- noneBackend
      activeRef <- newIORef fakeMeta
      uiState <- newUiStateHandle (fakePaths { spState = tmp })
      let sr = SessionRuntime { srPaths = fakePaths { spState = tmp }, srConfigPath = "", srActive = activeRef }
          sendDeps = SendDeps
            { sdPaths      = fakePaths { spState = tmp }
            , sdVault      = error "sdVault: unused on the 404 path"
            , sdProvider   = error "sdProvider: unused on the 404 path"
            , sdSession    = sr
            , sdBackends   = error "sdBackends: unused on the 404 path"
            , sdConfigRepo = error "sdConfigRepo: unused on the 404 path"
            , sdPreprocess = error "sdPreprocess: unused on the 404 path"
            , sdRegistry   = error "sdRegistry: unused on the 404 path"
            , sdResolve    = error "sdResolve: unused on the 404 path"
            , sdAutonomy   = error "sdAutonomy: unused on the 404 path"
            , sdBroker     = Nothing
            , sdHarnessRegistry = error "sdHarnessRegistry: unused on the 404 path"
            , sdTmuxRunner  = error "sdTmuxRunner: unused on the 404 path"
            , sdHttpManager = error "sdHttpManager: unused on the 404 path"
            , sdAskReply    = error "sdAskReply: unused on the 404 path"
            , sdApprovals   = error "sdApprovals: unused on the 404 path"
            , sdReplies     = error "sdReplies: unused on the 404 path"
            , sdLocks       = error "sdLocks: unused on the 404 path"
            }
          deps = ApiDeps
            { adSessionRuntime  = sr
            , adTabsHandle      = tabsH
            , adHarnessRegistry = reg
            , adAdoptConsent    = Just CcWeb
            , adAgentDefs       = adb
            , adProviders       = pure knownProviders
            , adUiState         = uiState
            , adSend            = Just sendDeps
            , adDefaultAgent    = Nothing
            }
          app = apiApp deps
      req <- testPost ["api", "sessions", "no-such-session", "send"]
        (A.encode (A.object [ "message" .= ("hi" :: T.Text) ]))
      status <- runAppStatus app req
      status `shouldBe` 404

  -- ── End-to-end: tabs/new -> send -> transcript ───────────────────────
  -- Creates a provider session via POST /api/tabs/new, sends a message via
  -- POST /api/sessions/:id/send, then reads the transcript back via GET
  -- /api/sessions/:id/transcript and asserts the assistant reply landed.
  -- A fake provider (ScriptProvider) is injected via sdResolve so the test
  -- is deterministic (no live Ollama/Anthropic call).
  it "e2e: tabs/new -> send -> transcript contains the assistant reply" $
    withSystemTempDirectory "seal-e2e" $ \tmp -> do
      let stateRoot  = tmp </> "state"
          configRoot = tmp </> "config"
          sessionRoot = stateRoot </> "sessions"
      createDirectoryIfMissing True stateRoot
      createDirectoryIfMissing True configRoot
      createDirectoryIfMissing True sessionRoot
      ensureConfigRepo configRoot
      let repo = openConfigRepo configRoot
      backends <- newBackends configRoot repo
      tabsH <- newTabsHandle
      reg   <- newHarnessRegistry
      tmuxR <- mkRealTmuxRunner
      askReply <- newAskReplyStore 0
      approvals <- newApprovalCache
      let adb = bAgentDefs backends
      -- A fake provider that returns one canned assistant reply.
      providerRef <- newIORef
        [ CompletionResponse [CbText "Hello from the fake provider"] StopEnd (Usage 0 0) ]
      -- A real ProviderRuntime whose config path is nonexistent (loadFileConfig
      -- fails -> defaults: 128KiB ceiling + fail-closed exec). The vault ref
      -- holds Nothing so resolveSessionProvider would fail — but sdResolve is
      -- stubbed, so the vault is never consulted.
      vaultRef <- newIORef (Nothing :: Maybe VaultHandle)
      mgr <- newManager defaultManagerSettings
      cntRef <- newIORef 0
      let rt = VaultRuntime { vrPaths = paths, vrConfigPath = configRoot </> "config.toml", vrHandleRef = vaultRef }
          pr = ProviderRuntime { prConfigPath = configRoot </> "config.toml", prVault = rt, prManager = mgr, prCallCounter = cntRef }
          paths = SealPaths
            { spHome = tmp, spState = stateRoot, spConfig = configRoot, spKeys = tmp </> "keys" }
          meta0 = fakeMeta { smId = case mkSessionId "e2e" of Right s -> s; Left _ -> error "sid" }
      activeRef' <- newIORef meta0
      uiState <- newUiStateHandle paths
      testReplies <- newReplyRegistry
      testLocks <- newSessionLocks
      let sr = SessionRuntime { srPaths = paths, srConfigPath = configRoot </> "config.toml", srActive = activeRef' }
          resolveStub :: SessionMeta -> IO (Either T.Text (SomeProvider, ModelId))
          resolveStub _ = pure (Right (SomeProvider (ScriptProvider providerRef), ModelId "llama3.2"))
          sendDeps = SendDeps
            { sdPaths      = paths
            , sdVault      = rt
            , sdProvider   = pr
            , sdSession    = sr
            , sdBackends   = backends
            , sdConfigRepo = repo
            , sdPreprocess = emptyChain
            , sdRegistry   = mkRegistry []
            , sdResolve    = resolveStub
            , sdAutonomy   = Policy.Full
            , sdBroker     = Nothing
            , sdHarnessRegistry = reg
            , sdTmuxRunner  = tmuxR
            , sdHttpManager = Nothing
            , sdAskReply    = askReply
            , sdApprovals   = approvals
            , sdReplies     = testReplies
            , sdLocks       = testLocks
            }
          deps = ApiDeps
            { adSessionRuntime  = sr
            , adTabsHandle      = tabsH
            , adHarnessRegistry = reg
            , adAdoptConsent    = Just CcWeb
            , adAgentDefs       = adb
            , adProviders       = pure knownProviders
            , adUiState         = uiState
            , adSend            = Just sendDeps
            , adDefaultAgent    = Nothing
            }
          app = apiApp deps
      -- 1. Create a provider tab (persists session.json).
      newReq <- testPost ["api", "tabs", "new"]
        (A.encode (A.object
          [ "kind" .= ("provider" :: T.Text)
          , "provider" .= ("ollama" :: T.Text)
          , "model" .= ("llama3.2" :: T.Text)
          ]))
      (newStatus, newBody) <- runAppBody app newReq
      newStatus `shouldBe` 200
      let newResp = A.decode newBody :: Maybe A.Value
          mSid = case newResp of
            Just (A.Object o) -> case KeyMap.lookup (Key.fromText "session_id") o of
              Just (A.String s) -> Just s
              _ -> Nothing
            _ -> Nothing
      case mSid of
        Nothing -> expectationFailure "tabs/new did not return a session_id"
        Just sidTxt -> do
          -- 2. Send a message.
          sendReq <- testPost ["api", "sessions", sidTxt, "send"]
            (A.encode (A.object [ "message" .= ("hello" :: T.Text) ]))
          (sendStatus, _sendBody) <- runAppBody app sendReq
          sendStatus `shouldBe` 200
          -- 3. Read the transcript; it should contain the assistant reply.
          let transcriptReq = testRequest methodGet ["api", "sessions", sidTxt, "transcript"]
          (transcriptStatus, transcriptBody) <- runAppBody app transcriptReq
          transcriptStatus `shouldBe` 200
          let arr = case A.decode transcriptBody :: Maybe A.Value of
                Just (A.Array a) -> V.toList a
                _ -> []
          -- The transcript should have at least 2 entries (user request +
          -- assistant response).
          length arr `shouldSatisfy` (>= 2)
          -- The canned reply text appears somewhere in the transcript JSON
          -- (the frontend's block payload encodes it).
          T.isInfixOf "Hello from the fake provider" (T.pack (show transcriptBody))
            `shouldBe` True