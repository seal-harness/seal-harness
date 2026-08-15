{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
module Seal.Gateway.ApiSpec (spec) where

import Control.Exception (try, SomeException)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent (threadDelay)
import Control.Monad (replicateM_, void)
import Data.Aeson ((.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Builder qualified as BSB
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust, isJust)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime(..), fromGregorian)
import Data.Vector qualified as V
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Network.HTTP.Types (Header, methodDelete, methodGet, methodPost, methodPut, statusCode)
import Network.Wai
  ( Application, Request, defaultRequest, pathInfo, requestMethod, responseStatus
  , setRequestBodyChunks )
import Network.Wai.Internal (Response (..), ResponseReceived (..))
import System.Directory (createDirectoryIfMissing, doesFileExist, removeDirectoryRecursive)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Agent.Def.Backend (noneBackend, adbUpdate)
import Seal.Agent.Def.Types (AgentDef (..), mkAgentDefId)
import Seal.Channel.Cli (Backends (..), newBackends)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Command.Spec (mkRegistry)
import Seal.Command.Skill (skillCommandSpec)
import Seal.Config.File (RuntimeConfig (..), defaultRuntimeConfig, loadRuntimeConfig, saveRuntimeConfig)
import Seal.Config.Paths (SealPaths (..), sessionDir, sessionMetaPath)
import Seal.Config.Security (defaultSecurityConfig)
import Seal.Core.AllowList (AllowList (..))
import Seal.Core.Types (ModelId (..), mkSystemSessionId, mkSessionId, ToolCallId (..), OpName (..))
import Seal.Gateway.API
import Seal.Gateway.Send (SendDeps (..), SendOutcome (..), sendOutcomeJson, webCallDispatcher)
import Seal.Gateway.StreamBroker (newStreamBroker, setThinking)
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
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Security.Policy qualified as Policy (AutonomyLevel (Full))
import Seal.Session.Workdir (SessionExec (..))
import Seal.SourceControl.Clone (stubCloneDeps)
import Seal.Tools.Exec.Types (RemotePath, mkRemotePath)
import Seal.Tools.Exec.UIO.Internal (mkTestUIOEnv)
import Seal.Tools.Exec.UntrustedIO (mkRemoteUntrustedIOStub)
import Seal.Tools.Exec.WorkdirFs (StubEntry (..), mkInMemWorkdirFs)
import Seal.Security.Vault (VaultHandle)
import Seal.TestHelpers.FakeVault (fakeLockedVaultRuntime)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), listSessions, saveSessionMeta)
import Seal.Session.Lock (newSessionLocks, newReplyRegistry)
import Seal.Skills.Backend qualified as Skill (noneBackend, sbCreate)
import Seal.Skills.Types (Skill (..), mkSkillId)
import Seal.SourceControl.Registry (RepoRegistryHandle (..), mkRepoRegistryHandle)
import Seal.Handles.Tab (TabKind (KindAi, KindHarness))
import Seal.Harness.Id (newHarnessId)
import Seal.Command.Tab (noTabCloseNotifier)
import Seal.Tabs (newTabsHandle, insertTabH)
import Seal.Tabs.Types (TabRef (BoundSession, BoundHarness))
import Seal.Util.StrictIO (decodeFileStrict)
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
  { spHome = "", spState = "", spConfig = "", spKeys = "" , spCache = ""}

fakeMeta :: SessionMeta
fakeMeta =
  let sid = case mkSessionId "test" of Right s -> s; Left _ -> error "sid"
  in SessionMeta sid "ollama" "llama3" "cli" Nothing Nothing Nothing Nothing (UTCTime (fromGregorian 2026 1 1) 0) (UTCTime (fromGregorian 2026 1 1) 0)

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

-- | Build a DELETE request (no body).
testDelete :: [T.Text] -> IO Request
testDelete path = pure (defaultRequest { requestMethod = methodDelete, pathInfo = path })

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

-- | Run the app against a test request, capturing the status code, body, and
-- response headers. Used by tests that assert on headers (e.g. the
-- @Server-Timing@ header on @GET /transcript@).
runAppBodyHeaders :: Application -> Request -> IO (Int, BL.ByteString, [Header])
runAppBodyHeaders app req = do
  mv <- newEmptyMVar
  _rr <- app req (\resp -> do
    let st = statusCode (responseStatus resp)
        (body, hdrs) = case resp of
          ResponseBuilder _ hs b -> (BSB.toLazyByteString b, hs)
          _ -> (BL.fromStrict BC.empty, [])
    putMVar mv (st, body, hdrs)
    pure ResponseReceived)
  takeMVar mv

-- | Build 'ApiDeps' against the given paths with the common test fakes.
-- Used by the transcript tests that need a per-test temp dir.
mkDepsFor :: SealPaths -> IO ApiDeps
mkDepsFor paths = do
  tabsH <- newTabsHandle
  reg   <- newHarnessRegistry
  adb   <- noneBackend
  skills <- Skill.noneBackend
  activeRef <- newIORef fakeMeta
  uiState <- newUiStateHandle paths
  repoRegH <- mkFakeRepoRegistryHandle
  let sr = SessionRuntime { srPaths = paths, srConfigPath = "", srActive = activeRef }
  pure ApiDeps
    { adSessionRuntime  = sr
    , adTabsHandle      = tabsH
    , adHarnessRegistry = reg
    , adAdoptConsent    = Just CcWeb
    , adAgentDefs       = adb
    , adSkills          = skills
    , adProviders       = pure knownProviders
    , adUiState         = uiState
    , adSend            = Nothing
    , adDefaultAgent    = pure Nothing
    , adBroker          = Nothing
    , adTabCloseNotifier = noTabCloseNotifier
    , adRepoRegistry     = repoRegH
    , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
    }

-- | A fake 'RepoRegistryHandle' whose @rrhList@ always returns an empty
-- registry and whose @rrhMutate@ always succeeds (no disk I/O). Used by
-- tests that need an 'ApiDeps' but don't exercise the repo CRUD path.
mkFakeRepoRegistryHandle :: IO RepoRegistryHandle
mkFakeRepoRegistryHandle = pure fakeRepoRegistryHandle

-- | The pure 'RepoRegistryHandle' value backing 'mkFakeRepoRegistryHandle'.
-- Used by the inline @deps = ApiDeps {…}@ literals (which are in a pure
-- @let@ context) so they don't need an IO action.
fakeRepoRegistryHandle :: RepoRegistryHandle
fakeRepoRegistryHandle = RepoRegistryHandle
  { rrhList   = pure (Right [])
  , rrhMutate = \_ -> pure (Right ())
  }

-- | A fake 'RepoRegistryHandle' whose @rrhList@ always returns 'Left'
-- (simulating a corrupt @repos.toml@). Used to assert GET /api/repos
-- surfaces a corrupt registry as 500 (the AC5/S2 mitigation), NOT a silent
-- empty list.
mkCorruptRepoRegistryHandle :: IO RepoRegistryHandle
mkCorruptRepoRegistryHandle = pure RepoRegistryHandle
  { rrhList   = pure (Left "corrupt repos.toml: parse error")
  , rrhMutate = \_ -> pure (Right ())
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

  it "POST /api/tabs/new with kind=provider does NOT leave an orphan session when the tab insert fails (full tab list)" $ do
    -- Use a FRESH temp dir so sessions from other tests don't leak in and
    -- masquerade as orphans (every test gets its own TabsHandle, so a
    -- session created by another test has no backing tab in THIS handle).
    dir <- withSystemTempDirectory "seal-api-orphan" $ \d -> do
      createDirectoryIfMissing True (d </> "sessions")
      pure d
    let paths = fakePaths { spState = dir }
    deps <- mkDepsFor paths
    -- Fill the tab list to capacity (36 slots) so the next insert fails.
    -- The provider branch mints a session id and attempts the insert; the
    -- session.json must NOT be persisted when the insert fails, otherwise
    -- the orphan surfaces in Recent Sessions with no backing tab.
    replicateM_ 36 $ do
      hid <- newHarnessId
      void $ insertTabH (adTabsHandle deps) (BoundHarness hid) KindHarness Nothing
    -- Drive the request through the real handler so the orphan-prevention
    -- logic in handleTabNew is exercised.
    let appFull = apiApp deps
    req <- testPost ["api", "tabs", "new"]
      (A.encode (A.object [ "kind" .= ("provider" :: T.Text), "provider" .= ("anthropic" :: T.Text), "model" .= ("claude-sonnet-4" :: T.Text) ]))
    status <- runAppStatus appFull req
    status `shouldBe` 400
    -- No session.json should have been written for the failed insert —
    -- the fresh dir started empty, and the 36 harness tabs carry no
    -- session, so any on-disk session here is an orphan from this call.
    sessions <- listSessions paths
    sessions `shouldSatisfy` null

  it "POST /api/tabs/new with kind=shell returns 501" $ do
    app <- mkApp
    req <- testPost ["api", "tabs", "new"]
      (A.encode (A.object [ "kind" .= ("shell" :: T.Text) ]))
    status <- runAppStatus app req
    status `shouldBe` 501

  it "POST /api/sessions/new creates a bare session and returns 200 + session_id" $ do
    app <- mkApp
    req <- testPost ["api", "sessions", "new"]
      (A.encode (A.object [ "provider" .= ("anthropic" :: T.Text), "model" .= ("claude-sonnet-4" :: T.Text) ]))
    (status, body) <- runAppBody app req
    status `shouldBe` 200
    case A.decode body :: Maybe A.Value of
      Just (A.Object o) -> case KeyMap.lookup (Key.fromText "session_id") o of
        Just (A.String sid) -> T.length sid `shouldSatisfy` (> 0)
        _ -> expectationFailure ("expected session_id string, got: " <> show body)
      _ -> expectationFailure ("expected JSON object, got: " <> show body)
    -- No tab should have been inserted (bare session).
    app2 <- mkApp
    ( _, body2) <- runAppBody app2 (testRequest methodGet ["api", "tabs"])
    case A.decode body2 :: Maybe [A.Value] of
      Just tabs -> tabs `shouldSatisfy` null
      Nothing   -> expectationFailure "expected a tabs array"

  it "POST /api/sessions/:id/new on a nonexistent session returns 404" $ do
    app <- mkApp
    req <- testPost ["api", "sessions", "99999999-000000-000", "new"] (A.encode (A.object []))
    status <- runAppStatus app req
    status `shouldBe` 404

  it "POST /api/sessions/:id/new on an existing session rebinds its tab + returns 200" $ do
    app <- mkApp
    -- First create a provider tab (which mints a session).
    req1 <- testPost ["api", "tabs", "new"]
      (A.encode (A.object [ "kind" .= ("provider" :: T.Text), "provider" .= ("anthropic" :: T.Text), "model" .= ("claude-sonnet-4" :: T.Text) ]))
    (s1, b1) <- runAppBody app req1
    s1 `shouldBe` 200
    oldSid <- case A.decode b1 :: Maybe A.Value of
      Just (A.Object o) -> case KeyMap.lookup (Key.fromText "session_id") o of
        Just (A.String sid) -> pure sid
        _ -> pure (error "expected session_id in tab-new response")
      _ -> pure (error "expected JSON object")
    -- Sleep >1ms so the new session mints a distinct id (formatSessionId is
    -- millisecond-precision; back-to-back mint calls in the same ms would
    -- collide).
    threadDelay 5000  -- 5ms
    -- Now POST /api/sessions/<oldSid>/new — should rebind the tab to a fresh sid.
    req2 <- testPost ["api", "sessions", oldSid, "new"] (A.encode (A.object []))
    (s2, b2) <- runAppBody app req2
    s2 `shouldBe` 200
    let mResp = A.decode b2 :: Maybe A.Value
    case mResp of
      Just (A.Object o) -> do
        case KeyMap.lookup (Key.fromText "session_id") o of
          Just (A.String newSid) -> newSid `shouldNotBe` oldSid
          _ -> expectationFailure ("expected session_id, got: " <> show b2)
        case KeyMap.lookup (Key.fromText "rebound") o of
          Just (A.Bool r) -> r `shouldBe` True
          _ -> expectationFailure ("expected rebound: true, got: " <> show b2)
        case KeyMap.lookup (Key.fromText "tab_index") o of
          Just (A.Number n) -> n `shouldBe` 0
          _ -> expectationFailure ("expected tab_index: 0, got: " <> show b2)
      _ -> expectationFailure ("expected JSON object, got: " <> show b2)
    -- The tab should now be bound to the NEW sid (one tab; ref != oldSid).
    ( _, tabsBody) <- runAppBody app (testRequest methodGet ["api", "tabs"])
    case A.decode tabsBody :: Maybe [A.Value] of
      Just [A.Object tabObj] ->
        case KeyMap.lookup (Key.fromText "session_id") tabObj of
          Just (A.String sid') -> sid' `shouldNotBe` oldSid
          _ -> expectationFailure "expected session_id in tab row"
      Just xs -> expectationFailure ("expected one tab, got " <> show (length xs))
      Nothing -> expectationFailure "expected a tabs array"

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
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
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
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
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
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
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

  it "GET /api/sessions surfaces lastUserMessageAt = the most recent request entry's timestamp" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-042"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      let convLine :: Message -> BL.ByteString
          convLine m = A.encode m <> "\n"
          -- Two user turns + one assistant turn so the LAST user message is
          -- the SECOND request entry, not the first.
          conv = [ Message User [CbText "first question"]
                  , Message Assistant [CbText "first answer"]
                  , Message User [CbText "second question"]
                  ]
      BC.writeFile (sdir </> "conversation.jsonl") (BL.toStrict (mconcat (map convLine conv)))
      -- entries.jsonl: request / response / request. The most recent
      -- request entry's timestamp (2026-07-01T12:00:05.000Z) is what
      -- lastUserMessageAt must return.
      BC.writeFile (sdir </> "entries.jsonl") $ BC.pack $ unlines
        [ "{\"id\":\"\",\"ts\":\"2026-07-01T12:00:00.100Z\",\"kind\":\"request\",\"convLen\":1}"
        , "{\"id\":\"\",\"ts\":\"2026-07-01T12:00:01.234Z\",\"kind\":\"response\",\"convLen\":2}"
        , "{\"id\":\"\",\"ts\":\"2026-07-01T12:00:05.000Z\",\"kind\":\"request\",\"convLen\":3}"
        ]
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
      lookupK "lastUserMessageAt" o `shouldBe` Just (A.String "2026-07-01T12:00:05.000Z")

  it "GET /api/sessions returns null lastUserMessageAt when no conversation exists" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-042"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
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
      lookupK "lastUserMessageAt" o `shouldBe` Just A.Null

  it "GET /api/sessions/archived returns 200 with [] when none archived" $ do
    app <- mkApp
    status <- runAppStatus app (testRequest methodGet ["api", "sessions", "archived"])
    status `shouldBe` 200

  it "GET /api/sessions/<sid>/transcript returns 200 with [] (no file)" $ do
    app <- mkApp
    status <- runAppStatus app (testRequest methodGet ["api", "sessions", "sess1", "transcript"])
    status `shouldBe` 200

  it "GET /api/sessions/<sid>/transcript emits a Server-Timing header (missing source)" $ do
    app <- mkApp
    (status, _body, hdrs) <- runAppBodyHeaders app
      (testRequest methodGet ["api", "sessions", "sess1", "transcript"])
    status `shouldBe` 200
    -- The header must be present, name-cased correctly, and carry the
    -- `missing` source desc so the frontend can distinguish an empty
    -- response from a not-found session.
    let timing = lookup "Server-Timing" hdrs
    timing `shouldSatisfy` isJust
    BC.unpack (fromJust timing) `shouldContain` "src;desc=\"missing\""
    BC.unpack (fromJust timing) `shouldContain` "tt;dur=0;desc=\"total\""

  it "GET /api/sessions/<sid>/transcript emits a Server-Timing header naming the source and entry count" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-042"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      -- Two-file format: write conversation.jsonl only (no entries.jsonl
      -- sidecar) so the source is TSConvOnly.
      let convLine :: Message -> BL.ByteString
          convLine m = A.encode m <> "\n"
          conv = [ Message User [CbText "hi there"]
                 , Message Assistant [CbText "hello back"]
                 ]
      BC.writeFile (sdir </> "conversation.jsonl") (BL.toStrict (mconcat (map convLine conv)))
      app <- apiApp <$> mkDepsFor paths
      (status, _body, hdrs) <- runAppBodyHeaders app
        (testRequest methodGet ["api", "sessions", sidTxt, "transcript"])
      status `shouldBe` 200
      let timing = lookup "Server-Timing" hdrs
      timing `shouldSatisfy` isJust
      let t = BC.unpack (fromJust timing)
      t `shouldContain` "src;desc=\"conv-only\""
      t `shouldContain` "n;desc=\"2\""

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
          parsed = case lookupK "payload" o of
            Just v -> v
            Nothing -> error "no payload"
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
          rparsed = case lookupK "payload" ro of
            Just v -> v
            Nothing -> error "no resp payload"
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
          qparsed = case lookupK "payload" qo of
            Just v -> v
            Nothing -> error "no req payload"
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
          rparsed = case lookupK "payload" ro of
            Just v -> v
            Nothing -> error "no req payload"
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
          rparsed = case lookupK "payload" ro of
            Just v -> v
            Nothing -> error "no req payload"
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

  it "PUT /api/sessions/<sid>/description returns 200 {ok:true}, persists the description, and surfaces it in /api/sessions" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-050"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      deps <- mkDepsFor paths
      let app = apiApp deps
      req <- testPut ["api", "sessions", sidTxt, "description"]
        (A.encode (A.object [ "description" .= ("my tab name" :: T.Text) ]))
      (status, body) <- runAppBody app req
      status `shouldBe` 200
      case A.decode body :: Maybe A.Value of
        Just (A.Object o) -> lookupK "ok" o `shouldBe` Just (A.Bool True)
        other -> error ("unexpected description body: " ++ show other)
      -- The description was persisted to session.json.
      mMeta <- decodeFileStrict (sessionMetaPath paths sid) :: IO (Maybe SessionMeta)
      smDescription <$> mMeta `shouldBe` Just (Just "my tab name")
      -- The new label surfaces in the session listing (the sidebar reads
      -- this — the bug was that the sidebar + a refresh lost the name).
      (_, listingBody) <- runAppBody app (testRequest methodGet ["api", "sessions"])
      let arr = case A.decode listingBody :: Maybe A.Value of
            Just (A.Array v) -> V.toList v
            _                -> error "expected an array"
          ours = filter (\case A.Object o -> lookupK "id" o == Just (A.String sidTxt); _ -> False) arr
      length ours `shouldBe` 1
      case ours of
        [A.Object o] -> lookupK "description" o `shouldBe` Just (A.String "my tab name")
        _            -> expectationFailure "expected exactly one matching session"

  it "PUT /api/sessions/<sid>/description with an empty/whitespace body clears the description" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-052"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = (SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0))
                  { smDescription = Just "old name" }
      saveSessionMeta paths meta
      deps <- mkDepsFor paths
      let app = apiApp deps
      req <- testPut ["api", "sessions", sidTxt, "description"]
        (A.encode (A.object [ "description" .= ("   " :: T.Text) ]))
      status <- runAppStatus app req
      status `shouldBe` 200
      mMeta <- decodeFileStrict (sessionMetaPath paths sid) :: IO (Maybe SessionMeta)
      smDescription <$> mMeta `shouldBe` Just Nothing

  it "PUT /api/sessions/<sid>/description returns 404 when the session has no session.json" $ do
    app <- mkApp
    req <- testPut ["api", "sessions", "missing", "description"]
      (A.encode (A.object [ "description" .= ("new" :: T.Text) ]))
    status <- runAppStatus app req
    status `shouldBe` 404

  it "PUT /api/sessions/<sid>/description returns 400 on invalid JSON" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-053"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      deps <- mkDepsFor paths
      let app = apiApp deps
      req <- testPut ["api", "sessions", sidTxt, "description"] "{not json"
      status <- runAppStatus app req
      status `shouldBe` 400

  it "PUT /api/sessions/<sid>/archived returns 200 {ok:true} and moves the session to /archived" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-051"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      deps <- mkDepsFor paths
      let app = apiApp deps
      -- Archive
      req <- testPut ["api", "sessions", sidTxt, "archived"]
        (A.encode (A.object [ "archived" .= True ]))
      (status, body) <- runAppBody app req
      status `shouldBe` 200
      case A.decode body :: Maybe A.Value of
        Just (A.Object o) -> lookupK "ok" o `shouldBe` Just (A.Bool True)
        other -> error ("unexpected archived body: " ++ show other)
      -- Marker file now exists on disk
      doesFileExist (sdir </> "archived") >>= (`shouldBe` True)
      -- /api/sessions no longer lists it
      (status2, body2) <- runAppBody app (testRequest methodGet ["api", "sessions"])
      status2 `shouldBe` 200
      case A.decode body2 :: Maybe [A.Value] of
        Just xs -> xs `shouldBe` []
        Nothing -> error "could not decode sessions body"
      -- /api/sessions/archived now lists it
      (status3, body3) <- runAppBody app (testRequest methodGet ["api", "sessions", "archived"])
      status3 `shouldBe` 200
      case A.decode body3 :: Maybe [A.Value] of
        Just [A.Object o] -> lookupK "id" o `shouldBe` Just (A.String sidTxt)
        Just xs          -> error ("expected exactly 1 archived session, got " ++ show (length xs))
        Nothing          -> error "could not decode archived body"

  it "GET /api/lists returns 200 with the partitioned shape (empty)" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
      deps <- mkDepsFor paths
      let app = apiApp deps
      (status, body) <- runAppBody app (testRequest methodGet ["api", "lists"])
      status `shouldBe` 200
      case A.decode body :: Maybe A.Value of
        Just (A.Object o) -> do
          lookupK "tabs" o `shouldBe` Just (A.Array mempty)
          lookupK "recentSessions" o `shouldBe` Just (A.Array mempty)
          lookupK "archivedSessions" o `shouldBe` Just (A.Array mempty)
          lookupK "tabSessions" o `shouldBe` Just (A.Array mempty)
          -- thinkingSessionIds is [] when the broker has no thinking
          -- turns in flight (and when adBroker is Nothing in tests).
          lookupK "thinkingSessionIds" o `shouldBe` Just (A.Array mempty)
        other -> error ("unexpected lists body: " ++ show other)

  it "GET /api/lists surfaces thinkingSessionIds from the broker's in-memory thinking set" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
      deps <- mkDepsFor paths
      -- Build a real broker and mark two sessions as thinking so the
      -- snapshot hydrates the sidebar on a mid-turn refresh.
      broker <- newStreamBroker 64
      let sidA = case mkSessionId "20260701-120000-aaa" of Right s -> s; Left _ -> error "sidA"
          sidB = case mkSessionId "20260701-120000-bbb" of Right s -> s; Left _ -> error "sidB"
      setThinking broker sidA True
      setThinking broker sidB True
      let app = apiApp deps { adBroker = Just broker }
      (status, body) <- runAppBody app (testRequest methodGet ["api", "lists"])
      status `shouldBe` 200
      case A.decode body :: Maybe A.Value of
        Just (A.Object o) ->
          case lookupK "thinkingSessionIds" o of
            Just (A.Array xs) ->
              -- The set is serialized as a sorted JSON array of session-id
              -- texts (Set.toList is ordered by SessionId, which matches
              -- the text order for these same-prefix ids).
              length xs `shouldBe` 2
            other -> error ("unexpected thinkingSessionIds: " ++ show other)
        other -> error ("unexpected lists body: " ++ show other)

  it "GET /api/lists partitions: a session with a tab appears in tabSessions, not recentSessions" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-061"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      deps <- mkDepsFor paths
      -- Insert a tab binding this sid
      _ <- insertTabH (adTabsHandle deps) (BoundSession sid) KindAi Nothing
      let app = apiApp deps
      (status, body) <- runAppBody app (testRequest methodGet ["api", "lists"])
      status `shouldBe` 200
      case A.decode body :: Maybe A.Value of
        Just (A.Object o) -> do
          -- tabSessions contains the sid
          case lookupK "tabSessions" o of
            Just (A.Array xs) -> length xs `shouldBe` 1
            other -> error ("unexpected tabSessions: " ++ show other)
          -- recentSessions is empty (the only session is tab-bound)
          lookupK "recentSessions" o `shouldBe` Just (A.Array mempty)
          -- tabs has the one tab
          case lookupK "tabs" o of
            Just (A.Array xs) -> length xs `shouldBe` 1
            other -> error ("unexpected tabs: " ++ show other)
        other -> error ("unexpected lists body: " ++ show other)

  it "GET /api/lists partitions: an archived session appears in archivedSessions" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-062"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      writeFile (sdir </> "archived") ""
      deps <- mkDepsFor paths
      let app = apiApp deps
      (status, body) <- runAppBody app (testRequest methodGet ["api", "lists"])
      status `shouldBe` 200
      case A.decode body :: Maybe A.Value of
        Just (A.Object o) -> do
          case lookupK "archivedSessions" o of
            Just (A.Array xs) -> length xs `shouldBe` 1
            other -> error ("unexpected archivedSessions: " ++ show other)
          lookupK "recentSessions" o `shouldBe` Just (A.Array mempty)
          lookupK "tabSessions" o `shouldBe` Just (A.Array mempty)
        other -> error ("unexpected lists body: " ++ show other)

  it "GET /api/lists partitions: an archived+tab-bound session appears in tabSessions (tab wins)" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-063"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      writeFile (sdir </> "archived") ""
      deps <- mkDepsFor paths
      _ <- insertTabH (adTabsHandle deps) (BoundSession sid) KindAi Nothing
      let app = apiApp deps
      (status, body) <- runAppBody app (testRequest methodGet ["api", "lists"])
      status `shouldBe` 200
      case A.decode body :: Maybe A.Value of
        Just (A.Object o) -> do
          case lookupK "tabSessions" o of
            Just (A.Array xs) -> length xs `shouldBe` 1
            other -> error ("unexpected tabSessions: " ++ show other)
          -- NOT in archivedSessions (the tab wins)
          lookupK "archivedSessions" o `shouldBe` Just (A.Array mempty)
        other -> error ("unexpected lists body: " ++ show other)

  it "PUT /api/sessions/<sid>/archived with archived:false unarchives (removes marker, returns to /sessions)" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-052"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
                  (UTCTime (fromGregorian 2026 7 1) 0)
                  (UTCTime (fromGregorian 2026 7 1) 0)
      saveSessionMeta paths meta
      writeFile (sdir </> "archived") ""
      deps <- mkDepsFor paths
      let app = apiApp deps
      req <- testPut ["api", "sessions", sidTxt, "archived"]
        (A.encode (A.object [ "archived" .= False ]))
      status <- runAppStatus app req
      status `shouldBe` 200
      doesFileExist (sdir </> "archived") >>= (`shouldBe` False)
      -- /api/sessions lists it again
      (_, body2) <- runAppBody app (testRequest methodGet ["api", "sessions"])
      case A.decode body2 :: Maybe [A.Value] of
        Just xs -> length xs `shouldBe` 1
        Nothing -> error "could not decode sessions body"

  it "PUT /api/sessions/<sid>/archived returns 404 when the session doesn't exist" $ do
    app <- mkApp
    req <- testPut ["api", "sessions", "nonexistent", "archived"]
      (A.encode (A.object [ "archived" .= True ]))
    status <- runAppStatus app req
    status `shouldBe` 404

  it "PUT /api/sessions/<sid>/archived returns 400 on a missing archived field" $ do
    app <- mkApp
    req <- testPut ["api", "sessions", "sess1", "archived"]
      (A.encode (A.object [ "other" .= (1 :: Int) ]))
    status <- runAppStatus app req
    status `shouldBe` 400

  it "PUT /api/sessions/<sid>/prompt returns 200 when the session exists" $
    withSystemTempDirectory "seal-api" $ \stateDir -> do
      let paths = fakePaths { spState = stateDir }
          sidTxt = "20260701-120000-051"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          sdir = sessionDir paths sid
      createDirectoryIfMissing True sdir
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
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
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
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
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
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
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
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
          meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" (Just aid) (Just "one-off") Nothing Nothing
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
          meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" (Just aid) Nothing Nothing Nothing
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
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing (Just "one-off") Nothing Nothing
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
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
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
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
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
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing Nothing Nothing
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
      let meta = SessionMeta sid "anthropic" "claude-sonnet-4" "web" Nothing Nothing (Just "my-uploaded-agent") Nothing
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
          skills <- Skill.noneBackend
          activeRef <- newIORef fakeMeta
          uiState <- newUiStateHandle mkPaths
          let now = UTCTime (fromGregorian 2026 7 1) 0
          let zoeId  = case mkAgentDefId "zoe" of Right x -> x; Left _ -> error "zoe"
              devId  = case mkAgentDefId "dev" of Right x -> x; Left _ -> error "dev"
              mkZoe = AgentDef zoeId "zoe" "" (ModelId "") Nothing AllowAll now now (mkSystemSessionId "manual")
              mkDev = AgentDef devId "dev" "" (ModelId "") Nothing AllowAll now now (mkSystemSessionId "manual")
          adbUpdate adb mkZoe
          adbUpdate adb mkDev
          let sr = SessionRuntime { srPaths = mkPaths, srConfigPath = "", srActive = activeRef }
              deps = ApiDeps
                { adSessionRuntime  = sr
                , adTabsHandle      = tabsH
                , adHarnessRegistry = reg
                , adAdoptConsent    = Just CcWeb
                , adAgentDefs       = adb
                , adSkills          = skills
                , adProviders       = pure knownProviders
                , adUiState         = uiState
                , adSend            = Nothing
                 , adDefaultAgent    = pure (Just "zoe")
                 , adBroker          = Nothing
    , adTabCloseNotifier = noTabCloseNotifier
    , adRepoRegistry     = fakeRepoRegistryHandle
    , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
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

  -- ── Default-agent endpoint ──────────────────────────────────────────
  -- GET /api/agents/default returns the configured default; PUT sets it
  -- (persisted to config.toml) or clears it. The named agent must exist.

  it "GET /api/agents/default returns 200 + {agent: null} when no default configured" $ do
    app <- mkApp
    (_, body) <- runAppBody app (testRequest methodGet ["api", "agents", "default"])
    case A.decode body :: Maybe A.Value of
      Just (A.Object o) -> lookupK "agent" o `shouldBe` Just A.Null
      _ -> expectationFailure "expected JSON object"

  it "PUT /api/agents/default sets the default + persists to config.toml" $
    withSystemTempDirectory "seal-default" $ \tmp -> do
      let cfgRoot = tmp </> "config"
      createDirectoryIfMissing True cfgRoot
      ensureConfigRepo cfgRoot
      let repo = openConfigRepo cfgRoot
      backends <- newBackends cfgRoot repo
      tabsH <- newTabsHandle
      reg <- newHarnessRegistry
      activeRef <- newIORef fakeMeta
      uiState <- newUiStateHandle (fakePaths { spState = tmp })
      let now = UTCTime (fromGregorian 2026 7 1) 0
          adb = bAgentDefs backends
          zoeId = case mkAgentDefId "zoe" of Right x -> x; Left _ -> error "zoe"
          zoe = AgentDef zoeId "zoe" "" (ModelId "") Nothing AllowAll now now (mkSystemSessionId "manual")
      adbUpdate adb zoe
      let paths = fakePaths { spState = tmp, spConfig = cfgRoot }
          sr = SessionRuntime { srPaths = paths, srConfigPath = cfgRoot </> "config.toml", srActive = activeRef }
          deps = ApiDeps
            { adSessionRuntime  = sr
            , adTabsHandle      = tabsH
            , adHarnessRegistry = reg
            , adAdoptConsent    = Just CcWeb
            , adAgentDefs       = adb
            , adSkills          = bSkills backends
            , adProviders       = pure knownProviders
            , adUiState         = uiState
            , adSend            = Nothing
             , adDefaultAgent    = do
                c <- loadRuntimeConfig (cfgRoot </> "config.toml")
                pure (case c of Right cfg -> rcDefaultAgent cfg; Left _ -> Nothing)
            , adBroker          = Nothing
    , adTabCloseNotifier = noTabCloseNotifier
    , adRepoRegistry     = fakeRepoRegistryHandle
    , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
            }
          app = apiApp deps
      req <- testPut ["api", "agents", "default"]
        (A.encode (A.object [ "agent" .= ("zoe" :: T.Text) ]))
      (status, body) <- runAppBody app req
      status `shouldBe` 200
      case A.decode body :: Maybe A.Value of
        Just (A.Object o) -> lookupK "agent" o `shouldBe` Just (A.String "zoe")
        _ -> expectationFailure "expected JSON object"
      -- The default landed on disk.
      eCfg <- loadRuntimeConfig (cfgRoot </> "config.toml")
      case eCfg of
        Right cfg -> rcDefaultAgent cfg `shouldBe` Just "zoe"
        Left e    -> expectationFailure ("config load failed: " <> T.unpack e)
      -- A follow-up GET /api/agents reflects the new default (zoe isDefault=true).
      (_, bodyList) <- runAppBody app (testRequest methodGet ["api", "agents"])
      case A.decode bodyList :: Maybe [A.Value] of
        Just xs -> do
          let isDefaultOf v = case v of
                A.Object o -> case lookupK "isDefault" o of Just (A.Bool b) -> Just b; _ -> Nothing
                _ -> Nothing
              nameOf v = case v of
                A.Object o -> case lookupK "name" o of Just (A.String n) -> Just n; _ -> Nothing
                _ -> Nothing
          case filter (\v -> nameOf v == Just "zoe") xs of
            (z:_) -> isDefaultOf z `shouldBe` Just True
            _     -> expectationFailure "zoe missing from list"
        Nothing -> expectationFailure "expected a list"

  it "PUT /api/agents/default with agent=null clears the default" $
    withSystemTempDirectory "seal-default" $ \tmp -> do
      let cfgRoot = tmp </> "config"
      createDirectoryIfMissing True cfgRoot
      ensureConfigRepo cfgRoot
      let repo = openConfigRepo cfgRoot
      backends <- newBackends cfgRoot repo
      tabsH <- newTabsHandle
      reg <- newHarnessRegistry
      activeRef <- newIORef fakeMeta
      uiState <- newUiStateHandle (fakePaths { spState = tmp })
      let adb = bAgentDefs backends
          cfgPath = cfgRoot </> "config.toml"
      -- Seed config.toml with a default already set.
      saveRuntimeConfig cfgPath defaultRuntimeConfig { rcDefaultAgent = Just "zoe" }
      let paths = fakePaths { spState = tmp, spConfig = cfgRoot }
          sr = SessionRuntime { srPaths = paths, srConfigPath = cfgPath, srActive = activeRef }
          deps = ApiDeps
            { adSessionRuntime  = sr
            , adTabsHandle      = tabsH
            , adHarnessRegistry = reg
            , adAdoptConsent    = Just CcWeb
            , adAgentDefs       = adb
            , adSkills          = bSkills backends
            , adProviders       = pure knownProviders
            , adUiState         = uiState
            , adSend            = Nothing
            , adDefaultAgent    = do
                c <- loadRuntimeConfig cfgPath
                pure (case c of Right cfg -> rcDefaultAgent cfg; Left _ -> Nothing)
            , adBroker          = Nothing
    , adTabCloseNotifier = noTabCloseNotifier
    , adRepoRegistry     = fakeRepoRegistryHandle
    , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
            }
          app = apiApp deps
      req <- testPut ["api", "agents", "default"]
        (A.encode (A.object [ "agent" .= (Nothing :: Maybe T.Text) ]))
      (status, body) <- runAppBody app req
      status `shouldBe` 200
      case A.decode body :: Maybe A.Value of
        Just (A.Object o) -> lookupK "agent" o `shouldBe` Just A.Null
        _ -> expectationFailure "expected JSON object"
      eCfg <- loadRuntimeConfig cfgPath
      case eCfg of
        Right cfg -> rcDefaultAgent cfg `shouldBe` Nothing
        Left e    -> expectationFailure ("config load failed: " <> T.unpack e)

  it "PUT /api/agents/default returns 404 when the named agent doesn't exist" $ do
    app <- mkApp
    req <- testPut ["api", "agents", "default"]
      (A.encode (A.object [ "agent" .= ("ghost" :: T.Text) ]))
    status <- runAppStatus app req
    status `shouldBe` 404

  it "PUT /api/agents/default returns 400 on a malformed agent id" $ do
    app <- mkApp
    req <- testPut ["api", "agents", "default"]
      (A.encode (A.object [ "agent" .= ("bad id!" :: T.Text) ]))
    status <- runAppStatus app req
    status `shouldBe` 400

  -- ── Agent CRUD ───────────────────────────────────────────────────────
  -- GET /api/agents now returns the full def (provider/model/system/tools)
  -- so the Agents UI can render + edit every field. POST creates, PUT
  -- updates (preserving created_at), GET one fetches, DELETE is idempotent.

  it "GET /api/agents returns the full def (provider/model/system/tools)" $ do
    -- Seed a def directly through the backend so the test is independent
    -- of POST. mkDepsFor uses the in-memory noneBackend; reach in via a
    -- second app built with the seeded backend.
    adb <- noneBackend
    skills <- Skill.noneBackend
    tabsH <- newTabsHandle
    reg <- newHarnessRegistry
    activeRef <- newIORef fakeMeta
    uiState <- newUiStateHandle mkPaths
    let now = UTCTime (fromGregorian 2026 7 1) 0
        aid = case mkAgentDefId "full" of Right x -> x; Left _ -> error "aid"
        d = AgentDef aid "Full Name" "anthropic" (ModelId "claude-sonnet-4") (Just "be terse")
            (AllowOnly (Set.fromList [OpName "FILE_READ", OpName "ASK_HUMAN"])) now now (mkSystemSessionId "manual")
    adbUpdate adb d
    let sr = SessionRuntime { srPaths = mkPaths, srConfigPath = "", srActive = activeRef }
        deps = ApiDeps
          { adSessionRuntime  = sr
          , adTabsHandle      = tabsH
          , adHarnessRegistry = reg
          , adAdoptConsent    = Just CcWeb
          , adAgentDefs       = adb
          , adSkills          = skills
          , adProviders       = pure knownProviders
          , adUiState         = uiState
          , adSend            = Nothing
          , adDefaultAgent    = pure Nothing
          , adBroker          = Nothing
    , adTabCloseNotifier = noTabCloseNotifier
    , adRepoRegistry     = fakeRepoRegistryHandle
    , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
          }
        app' = apiApp deps
    (_, body) <- runAppBody app' (testRequest methodGet ["api", "agents"])
    let arr = case A.decode body :: Maybe [A.Value] of
          Just xs -> xs
          Nothing -> error ("could not decode agents body: " ++ show body)
    length arr `shouldBe` 1
    case arr of
      (A.Object o : _) -> do
        lookupK "id" o `shouldBe` Just (A.String "full")
        lookupK "displayName" o `shouldBe` Just (A.String "Full Name")
        lookupK "provider" o `shouldBe` Just (A.String "anthropic")
        lookupK "model" o `shouldBe` Just (A.String "claude-sonnet-4")
        lookupK "system" o `shouldBe` Just (A.String "be terse")
        -- tools is an array of opcode names (AllowOnly)
        case lookupK "tools" o of
          Just (A.Array xs) -> length xs `shouldBe` 2
          _ -> expectationFailure "expected tools array"
      _ -> expectationFailure "first agent not an object"

  it "POST /api/agents creates a def and GET /api/agents/:id returns it" $ do
    app <- mkApp
    req <- testPost ["api", "agents"]
      (A.encode (A.object
        [ "id" .= ("planner" :: T.Text)
        , "name" .= ("Planner" :: T.Text)
        , "provider" .= ("ollama" :: T.Text)
        , "model" .= ("llama3.2" :: T.Text)
        , "system" .= ("You plan tasks." :: T.Text)
        , "tools" .= (["FILE_READ", "ASK_HUMAN"] :: [T.Text])
        ]))
    (status, body) <- runAppBody app req
    status `shouldBe` 201
    case A.decode body :: Maybe A.Value of
      Just (A.Object o) -> lookupK "id" o `shouldBe` Just (A.String "planner")
      _ -> expectationFailure "expected JSON object"
    -- Fetch it back via GET /api/agents/planner
    -- The noneBackend in mkApp is fresh each call, so POST + GET must share
    -- the SAME app. Use the first app for the GET.
    (_, body2) <- runAppBody app (testRequest methodGet ["api", "agents", "planner"])
    case A.decode body2 :: Maybe A.Value of
      Just (A.Object o) -> do
        lookupK "id" o `shouldBe` Just (A.String "planner")
        lookupK "provider" o `shouldBe` Just (A.String "ollama")
        lookupK "system" o `shouldBe` Just (A.String "You plan tasks.")
      _ -> expectationFailure "expected JSON object for GET one"

  it "POST /api/agents rejects a malformed id with 400" $ do
    app <- mkApp
    req <- testPost ["api", "agents"]
      (A.encode (A.object [ "id" .= ("bad id!" :: T.Text) ]))
    status <- runAppStatus app req
    status `shouldBe` 400

  it "POST /api/agents rejects a missing id with 400" $ do
    app <- mkApp
    req <- testPost ["api", "agents"] (A.encode (A.object [ "name" .= ("no id" :: T.Text) ]))
    status <- runAppStatus app req
    status `shouldBe` 400

  it "PUT /api/agents/:id updates an existing def and preserves created_at" $ do
    -- Build a seeded backend + app, then PUT a change and verify created_at
    -- is preserved while updated_at advances.
    adb <- noneBackend
    skills <- Skill.noneBackend
    tabsH <- newTabsHandle
    reg <- newHarnessRegistry
    activeRef <- newIORef fakeMeta
    uiState <- newUiStateHandle mkPaths
    let oldCreated = UTCTime (fromGregorian 2026 1 1) 0
        aid = case mkAgentDefId "eddy" of Right x -> x; Left _ -> error "aid"
        seed = AgentDef aid "Eddy" "ollama" (ModelId "llama3.2") Nothing AllowAll oldCreated oldCreated (mkSystemSessionId "manual")
    adbUpdate adb seed
    let sr = SessionRuntime { srPaths = mkPaths, srConfigPath = "", srActive = activeRef }
        deps = ApiDeps
          { adSessionRuntime  = sr
          , adTabsHandle      = tabsH
          , adHarnessRegistry = reg
          , adAdoptConsent    = Just CcWeb
          , adAgentDefs       = adb
          , adSkills          = skills
          , adProviders       = pure knownProviders
          , adUiState         = uiState
          , adSend            = Nothing
          , adDefaultAgent    = pure Nothing
          , adBroker          = Nothing
    , adTabCloseNotifier = noTabCloseNotifier
    , adRepoRegistry     = fakeRepoRegistryHandle
    , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
          }
        app = apiApp deps
    req <- testPut ["api", "agents", "eddy"]
      (A.encode (A.object
        [ "name" .= ("Eddy 2" :: T.Text)
        , "provider" .= ("anthropic" :: T.Text)
        , "model" .= ("claude-sonnet-4" :: T.Text)
        , "system" .= ("be nice" :: T.Text)
        ]))
    (status, body) <- runAppBody app req
    status `shouldBe` 200
    case A.decode body :: Maybe A.Value of
      Just (A.Object o) -> do
        lookupK "displayName" o `shouldBe` Just (A.String "Eddy 2")
        lookupK "provider" o `shouldBe` Just (A.String "anthropic")
        case lookupK "created_at" o of
          Just (A.String t) -> t `shouldSatisfy` ("2026-01-01" `T.isInfixOf`)
          _ -> expectationFailure "expected created_at string"
      _ -> expectationFailure "expected JSON object for PUT"

  it "PUT /api/agents/:id on a missing def returns 404" $ do
    app <- mkApp
    req <- testPut ["api", "agents", "ghost"]
      (A.encode (A.object [ "name" .= ("Ghost" :: T.Text) ]))
    status <- runAppStatus app req
    status `shouldBe` 404

  it "PUT /api/agents/:id with new_id renames the def (old id gone, new id present)" $ do
    adb <- noneBackend
    skills <- Skill.noneBackend
    tabsH <- newTabsHandle
    reg <- newHarnessRegistry
    activeRef <- newIORef fakeMeta
    uiState <- newUiStateHandle mkPaths
    let oldCreated = UTCTime (fromGregorian 2026 1 1) 0
        oldId = case mkAgentDefId "alpha" of Right x -> x; Left _ -> error "aid"
        seed = AgentDef oldId "Alpha" "ollama" (ModelId "llama3.2") Nothing AllowAll oldCreated oldCreated (mkSystemSessionId "manual")
    adbUpdate adb seed
    let sr = SessionRuntime { srPaths = mkPaths, srConfigPath = "", srActive = activeRef }
        deps = ApiDeps
          { adSessionRuntime  = sr
          , adTabsHandle      = tabsH
          , adHarnessRegistry = reg
          , adAdoptConsent    = Just CcWeb
          , adAgentDefs       = adb
          , adSkills          = skills
          , adProviders       = pure knownProviders
          , adUiState         = uiState
          , adSend            = Nothing
          , adDefaultAgent    = pure Nothing
          , adBroker          = Nothing
    , adTabCloseNotifier = noTabCloseNotifier
    , adRepoRegistry     = fakeRepoRegistryHandle
    , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
          }
        app = apiApp deps
    req <- testPut ["api", "agents", "alpha"]
      (A.encode (A.object [ "new_id" .= ("beta" :: T.Text), "name" .= ("Beta" :: T.Text) ]))
    (status, body) <- runAppBody app req
    status `shouldBe` 200
    case A.decode body :: Maybe A.Value of
      Just (A.Object o) -> do
        lookupK "id" o `shouldBe` Just (A.String "beta")
        lookupK "displayName" o `shouldBe` Just (A.String "Beta")
        -- created_at preserved from the seed
        case lookupK "created_at" o of
          Just (A.String t) -> t `shouldSatisfy` ("2026-01-01" `T.isInfixOf`)
          _ -> expectationFailure "expected created_at string"
      _ -> expectationFailure "expected JSON object for rename"
    -- The old id is gone.
    (_, bodyOld) <- runAppBody app (testRequest methodGet ["api", "agents", "alpha"])
    case A.decode bodyOld :: Maybe A.Value of
      Just (A.Object o) -> lookupK "error" o `shouldSatisfy` isJust
      _ -> expectationFailure "expected 404 object for old id"
    -- The new id is readable.
    (_, bodyNew) <- runAppBody app (testRequest methodGet ["api", "agents", "beta"])
    case A.decode bodyNew :: Maybe A.Value of
      Just (A.Object o) -> lookupK "id" o `shouldBe` Just (A.String "beta")
      _ -> expectationFailure "expected JSON object for new id"

  it "PUT /api/agents/:id with a malformed new_id returns 400" $ do
    adb <- noneBackend
    skills <- Skill.noneBackend
    tabsH <- newTabsHandle
    reg <- newHarnessRegistry
    activeRef <- newIORef fakeMeta
    uiState <- newUiStateHandle mkPaths
    let now = UTCTime (fromGregorian 2026 7 1) 0
        aid = case mkAgentDefId "keep" of Right x -> x; Left _ -> error "aid"
        seed = AgentDef aid "Keep" "" (ModelId "") Nothing AllowAll now now (mkSystemSessionId "manual")
    adbUpdate adb seed
    let sr = SessionRuntime { srPaths = mkPaths, srConfigPath = "", srActive = activeRef }
        deps = ApiDeps
          { adSessionRuntime  = sr
          , adTabsHandle      = tabsH
          , adHarnessRegistry = reg
          , adAdoptConsent    = Just CcWeb
          , adAgentDefs       = adb
          , adSkills          = skills
          , adProviders       = pure knownProviders
          , adUiState         = uiState
          , adSend            = Nothing
          , adDefaultAgent    = pure Nothing
          , adBroker          = Nothing
    , adTabCloseNotifier = noTabCloseNotifier
    , adRepoRegistry     = fakeRepoRegistryHandle
    , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
          }
        app = apiApp deps
    req <- testPut ["api", "agents", "keep"]
      (A.encode (A.object [ "new_id" .= ("bad id!" :: T.Text) ]))
    status <- runAppStatus app req
    status `shouldBe` 400

  it "DELETE /api/agents/:id returns 204 and the def is gone" $ do
    adb <- noneBackend
    skills <- Skill.noneBackend
    tabsH <- newTabsHandle
    reg <- newHarnessRegistry
    activeRef <- newIORef fakeMeta
    uiState <- newUiStateHandle mkPaths
    let now = UTCTime (fromGregorian 2026 7 1) 0
        aid = case mkAgentDefId "delme" of Right x -> x; Left _ -> error "aid"
        seed = AgentDef aid "delme" "" (ModelId "") Nothing AllowAll now now (mkSystemSessionId "manual")
    adbUpdate adb seed
    let sr = SessionRuntime { srPaths = mkPaths, srConfigPath = "", srActive = activeRef }
        deps = ApiDeps
          { adSessionRuntime  = sr
          , adTabsHandle      = tabsH
          , adHarnessRegistry = reg
          , adAdoptConsent    = Just CcWeb
          , adAgentDefs       = adb
          , adSkills          = skills
          , adProviders       = pure knownProviders
          , adUiState         = uiState
          , adSend            = Nothing
          , adDefaultAgent    = pure Nothing
          , adBroker          = Nothing
    , adTabCloseNotifier = noTabCloseNotifier
    , adRepoRegistry     = fakeRepoRegistryHandle
    , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
          }
        app = apiApp deps
    req <- testDelete ["api", "agents", "delme"]
    status <- runAppStatus app req
    status `shouldBe` 204
    -- Subsequent GET returns 404.
    (_, body) <- runAppBody app (testRequest methodGet ["api", "agents", "delme"])
    case A.decode body :: Maybe A.Value of
      Just (A.Object o) -> lookupK "error" o `shouldSatisfy` isJust
      _ -> expectationFailure "expected JSON object for GET after delete"

  it "DELETE /api/agents/:id is idempotent (204 for missing def)" $ do
    app <- mkApp
    req <- testDelete ["api", "agents", "never-existed"]
    status <- runAppStatus app req
    status `shouldBe` 204

  it "DELETE /api/agents/:id rejects a malformed id with 400" $ do
    app <- mkApp
    req <- testDelete ["api", "agents", "bad id!"]
    status <- runAppStatus app req
    status `shouldBe` 400

  -- ── Skill CRUD ───────────────────────────────────────────────────────

  it "GET /api/skills returns 200 with a JSON array" $ do
    app <- mkApp
    status <- runAppStatus app (testRequest methodGet ["api", "skills"])
    status `shouldBe` 200

  it "POST /api/skills creates a skill and GET /api/skills/:id returns it" $ do
    app <- mkApp
    req <- testPost ["api", "skills"]
      (A.encode (A.object
        [ "id" .= ("coding" :: T.Text)
        , "description" .= ("Coding skill" :: T.Text)
        , "body" .= ("## Coding\n\nWrite code carefully." :: T.Text)
        ]))
    (status, body) <- runAppBody app req
    status `shouldBe` 201
    case A.decode body :: Maybe A.Value of
      Just (A.Object o) -> do
        lookupK "id" o `shouldBe` Just (A.String "coding")
        lookupK "description" o `shouldBe` Just (A.String "Coding skill")
        lookupK "body" o `shouldBe` Just (A.String "## Coding\n\nWrite code carefully.")
      _ -> expectationFailure "expected JSON object for POST skill"
    -- GET it back (same app — the in-memory backend is shared).
    (_, body2) <- runAppBody app (testRequest methodGet ["api", "skills", "coding"])
    case A.decode body2 :: Maybe A.Value of
      Just (A.Object o) -> lookupK "id" o `shouldBe` Just (A.String "coding")
      _ -> expectationFailure "expected JSON object for GET skill one"

  it "GET /api/skills/:id on a missing skill returns 404" $ do
    app <- mkApp
    (_, body) <- runAppBody app (testRequest methodGet ["api", "skills", "ghost"])
    case A.decode body :: Maybe A.Value of
      Just (A.Object o) -> lookupK "error" o `shouldSatisfy` isJust
      _ -> expectationFailure "expected JSON object for missing skill"

  it "PUT /api/skills/:id updates an existing skill and preserves created_at" $ do
    adb <- noneBackend
    skills <- Skill.noneBackend
    tabsH <- newTabsHandle
    reg <- newHarnessRegistry
    activeRef <- newIORef fakeMeta
    uiState <- newUiStateHandle mkPaths
    let oldCreated = UTCTime (fromGregorian 2026 1 1) 0
        sid = case mkSkillId "writer" of Right x -> x; Left _ -> error "sid"
        seed = Skill sid "Writer" "draft text" Nothing oldCreated oldCreated (mkSystemSessionId "manual")
    Skill.sbCreate skills seed
    let sr = SessionRuntime { srPaths = mkPaths, srConfigPath = "", srActive = activeRef }
        deps = ApiDeps
          { adSessionRuntime  = sr
          , adTabsHandle      = tabsH
          , adHarnessRegistry = reg
          , adAdoptConsent    = Just CcWeb
          , adAgentDefs       = adb
          , adSkills          = skills
          , adProviders       = pure knownProviders
          , adUiState         = uiState
          , adSend            = Nothing
          , adDefaultAgent    = pure Nothing
          , adBroker          = Nothing
    , adTabCloseNotifier = noTabCloseNotifier
    , adRepoRegistry     = fakeRepoRegistryHandle
    , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
          }
        app = apiApp deps
    req <- testPut ["api", "skills", "writer"]
      (A.encode (A.object
        [ "description" .= ("Writer 2" :: T.Text)
        , "body" .= ("## Writer\n\nUpdated body." :: T.Text)
        ]))
    (status, body) <- runAppBody app req
    status `shouldBe` 200
    case A.decode body :: Maybe A.Value of
      Just (A.Object o) -> do
        lookupK "description" o `shouldBe` Just (A.String "Writer 2")
        lookupK "body" o `shouldBe` Just (A.String "## Writer\n\nUpdated body.")
        case lookupK "created_at" o of
          Just (A.String t) -> t `shouldSatisfy` ("2026-01-01" `T.isInfixOf`)
          _ -> expectationFailure "expected created_at string"
      _ -> expectationFailure "expected JSON object for PUT skill"

  it "PUT /api/skills/:id on a missing skill returns 404" $ do
    app <- mkApp
    req <- testPut ["api", "skills", "ghost"]
      (A.encode (A.object [ "description" .= ("x" :: T.Text) ]))
    status <- runAppStatus app req
    status `shouldBe` 404

  it "PUT /api/skills/:id with new_id renames the skill (old id gone, new id present)" $ do
    adb <- noneBackend
    skills <- Skill.noneBackend
    tabsH <- newTabsHandle
    reg <- newHarnessRegistry
    activeRef <- newIORef fakeMeta
    uiState <- newUiStateHandle mkPaths
    let oldCreated = UTCTime (fromGregorian 2026 1 1) 0
        sid = case mkSkillId "alpha" of Right x -> x; Left _ -> error "sid"
        seed = Skill sid "Alpha" "body" Nothing oldCreated oldCreated (mkSystemSessionId "manual")
    Skill.sbCreate skills seed
    let sr = SessionRuntime { srPaths = mkPaths, srConfigPath = "", srActive = activeRef }
        deps = ApiDeps
          { adSessionRuntime  = sr
          , adTabsHandle      = tabsH
          , adHarnessRegistry = reg
          , adAdoptConsent    = Just CcWeb
          , adAgentDefs       = adb
          , adSkills          = skills
          , adProviders       = pure knownProviders
          , adUiState         = uiState
          , adSend            = Nothing
          , adDefaultAgent    = pure Nothing
          , adBroker          = Nothing
    , adTabCloseNotifier = noTabCloseNotifier
    , adRepoRegistry     = fakeRepoRegistryHandle
    , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
          }
        app = apiApp deps
    req <- testPut ["api", "skills", "alpha"]
      (A.encode (A.object [ "new_id" .= ("beta" :: T.Text), "description" .= ("Beta" :: T.Text) ]))
    (status, body) <- runAppBody app req
    status `shouldBe` 200
    case A.decode body :: Maybe A.Value of
      Just (A.Object o) -> do
        lookupK "id" o `shouldBe` Just (A.String "beta")
        lookupK "description" o `shouldBe` Just (A.String "Beta")
        case lookupK "created_at" o of
          Just (A.String t) -> t `shouldSatisfy` ("2026-01-01" `T.isInfixOf`)
          _ -> expectationFailure "expected created_at string"
      _ -> expectationFailure "expected JSON object for skill rename"
    -- Old id gone, new id readable.
    (_, bodyOld) <- runAppBody app (testRequest methodGet ["api", "skills", "alpha"])
    case A.decode bodyOld :: Maybe A.Value of
      Just (A.Object o) -> lookupK "error" o `shouldSatisfy` isJust
      _ -> expectationFailure "expected 404 object for old skill id"
    (_, bodyNew) <- runAppBody app (testRequest methodGet ["api", "skills", "beta"])
    case A.decode bodyNew :: Maybe A.Value of
      Just (A.Object o) -> lookupK "id" o `shouldBe` Just (A.String "beta")
      _ -> expectationFailure "expected JSON object for new skill id"

  it "DELETE /api/skills/:id returns 204 and the skill is gone" $ do
    adb <- noneBackend
    skills <- Skill.noneBackend
    tabsH <- newTabsHandle
    reg <- newHarnessRegistry
    activeRef <- newIORef fakeMeta
    uiState <- newUiStateHandle mkPaths
    let now = UTCTime (fromGregorian 2026 7 1) 0
        sid = case mkSkillId "gone" of Right x -> x; Left _ -> error "sid"
        seed = Skill sid "Gone" "body" Nothing now now (mkSystemSessionId "manual")
    Skill.sbCreate skills seed
    let sr = SessionRuntime { srPaths = mkPaths, srConfigPath = "", srActive = activeRef }
        deps = ApiDeps
          { adSessionRuntime  = sr
          , adTabsHandle      = tabsH
          , adHarnessRegistry = reg
          , adAdoptConsent    = Just CcWeb
          , adAgentDefs       = adb
          , adSkills          = skills
          , adProviders       = pure knownProviders
          , adUiState         = uiState
          , adSend            = Nothing
          , adDefaultAgent    = pure Nothing
          , adBroker          = Nothing
    , adTabCloseNotifier = noTabCloseNotifier
    , adRepoRegistry     = fakeRepoRegistryHandle
    , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
          }
        app = apiApp deps
    req <- testDelete ["api", "skills", "gone"]
    status <- runAppStatus app req
    status `shouldBe` 204
    (_, body) <- runAppBody app (testRequest methodGet ["api", "skills", "gone"])
    case A.decode body :: Maybe A.Value of
      Just (A.Object o) -> lookupK "error" o `shouldSatisfy` isJust
      _ -> expectationFailure "expected JSON object for GET after skill delete"

  it "DELETE /api/skills/:id is idempotent (204 for missing skill)" $ do
    app <- mkApp
    req <- testDelete ["api", "skills", "never-existed"]
    status <- runAppStatus app req
    status `shouldBe` 204

  it "GET /api/skills lists all skills sorted by id" $ do
    adb <- noneBackend
    skills <- Skill.noneBackend
    tabsH <- newTabsHandle
    reg <- newHarnessRegistry
    activeRef <- newIORef fakeMeta
    uiState <- newUiStateHandle mkPaths
    let now = UTCTime (fromGregorian 2026 7 1) 0
        mkS n = case mkSkillId n of
          Right sid -> Skill sid n "body" Nothing now now (mkSystemSessionId "manual")
          Left _    -> error "sid"
    Skill.sbCreate skills (mkS "zeta")
    Skill.sbCreate skills (mkS "alpha")
    let sr = SessionRuntime { srPaths = mkPaths, srConfigPath = "", srActive = activeRef }
        deps = ApiDeps
          { adSessionRuntime  = sr
          , adTabsHandle      = tabsH
          , adHarnessRegistry = reg
          , adAdoptConsent    = Just CcWeb
          , adAgentDefs       = adb
          , adSkills          = skills
          , adProviders       = pure knownProviders
          , adUiState         = uiState
          , adSend            = Nothing
          , adDefaultAgent    = pure Nothing
          , adBroker          = Nothing
    , adTabCloseNotifier = noTabCloseNotifier
    , adRepoRegistry     = fakeRepoRegistryHandle
    , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
          }
        app = apiApp deps
    (_, body) <- runAppBody app (testRequest methodGet ["api", "skills"])
    case A.decode body :: Maybe [A.Value] of
      Just xs -> do
        length xs `shouldBe` 2
        let idOf v = case v of
              A.Object o -> case lookupK "id" o of
                Just (A.String t) -> t
                _ -> ""
              _ -> ""
            ids = map idOf xs
        ids `shouldBe` ["alpha", "zeta"]
      Nothing -> expectationFailure "expected a skills array"

  -- ── Repo CRUD (W4) ───────────────────────────────────────────────────
  -- The /api/repos surface: GET (list), POST (idempotent upsert, 201),
  -- GET/:id, PUT/:id (200, 404 if missing), DELETE/:id (idempotent 204).
  -- Validation: mkRepoId, urlShapeValid, host allow-list, parseVcsKind,
  -- parseCredentialKind. A corrupt repos.toml surfaces as 500 (AC5/S2).
  -- The credential object carries only vault key NAMES (never secret
  -- bytes) — the no-secret-in-response guard asserts the descriptor never
  -- leaks a token/value/secret/password field.
  describe "/api/repos" $ do
    -- Build an ApiDeps whose adRepoRegistry points at a REAL repos.toml
    -- in a per-test temp dir (so upsert/remove persist across requests
    -- within the test). The adConfigRepo is a nonexistent path — the
    -- best-effort gitCommitAll is wrapped in try, so a missing repo is
    -- harmless.
    let mkRepoApp :: FilePath -> IO ApiDeps
        mkRepoApp tmp = do
          tabsH <- newTabsHandle
          reg   <- newHarnessRegistry
          adb   <- noneBackend
          skills <- Skill.noneBackend
          activeRef <- newIORef fakeMeta
          uiState <- newUiStateHandle mkPaths
          repoRegH <- mkRepoRegistryHandle (tmp </> "repos.toml")
          let sr = SessionRuntime { srPaths = mkPaths, srConfigPath = "", srActive = activeRef }
          pure ApiDeps
            { adSessionRuntime  = sr
            , adTabsHandle      = tabsH
            , adHarnessRegistry = reg
            , adAdoptConsent    = Just CcWeb
            , adAgentDefs       = adb
            , adSkills          = skills
            , adProviders       = pure knownProviders
            , adUiState         = uiState
            , adSend            = Nothing
            , adDefaultAgent    = pure Nothing
            , adBroker          = Nothing
            , adTabCloseNotifier = noTabCloseNotifier
            , adRepoRegistry     = repoRegH
            , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
            }

    it "GET /api/repos returns 200 + [] when the registry is empty" $
      withSystemTempDirectory "seal-repos" $ \tmp -> do
        deps <- mkRepoApp tmp
        let app = apiApp deps
        (status, body) <- runAppBody app (testRequest methodGet ["api", "repos"])
        status `shouldBe` 200
        case A.decode body :: Maybe [A.Value] of
          Just xs -> xs `shouldBe` []
          Nothing -> expectationFailure "expected a JSON array"

    it "POST /api/repos creates a PAT repo (201) and GET /api/repos/:id returns it" $
      withSystemTempDirectory "seal-repos" $ \tmp -> do
        deps <- mkRepoApp tmp
        let app = apiApp deps
        req <- testPost ["api", "repos"]
          (A.encode (A.object
            [ "id"       .= ("myrepo" :: T.Text)
            , "url"      .= ("git@github.com:owner/myrepo.git" :: T.Text)
            , "vcs_kind" .= ("git" :: T.Text)
            , "credential" .= A.object
                [ "kind"      .= ("pat" :: T.Text)
                , "vault_key" .= ("github_pat" :: T.Text)
                ]
            ]))
        (status, body) <- runAppBody app req
        status `shouldBe` 201
        case A.decode body :: Maybe A.Value of
          Just (A.Object o) -> do
            lookupK "id" o `shouldBe` Just (A.String "myrepo")
            lookupK "url" o `shouldBe` Just (A.String "git@github.com:owner/myrepo.git")
            lookupK "vcs_kind" o `shouldBe` Just (A.String "git")
            case lookupK "credential" o of
              Just (A.Object co) -> do
                lookupK "kind" co `shouldBe` Just (A.String "pat")
                lookupK "vault_key" co `shouldBe` Just (A.String "github_pat")
                lookupK "username" co `shouldBe` Nothing
              _ -> expectationFailure "expected credential object"
          _ -> expectationFailure "expected JSON object for POST repo"
        -- GET it back.
        (_, body2) <- runAppBody app (testRequest methodGet ["api", "repos", "myrepo"])
        case A.decode body2 :: Maybe A.Value of
          Just (A.Object o) -> lookupK "id" o `shouldBe` Just (A.String "myrepo")
          _ -> expectationFailure "expected JSON object for GET repo"

    it "POST /api/repos is idempotent upsert (same id, new url → 201 + updated)" $
      withSystemTempDirectory "seal-repos" $ \tmp -> do
        deps <- mkRepoApp tmp
        let app = apiApp deps
        let postRepo urlStr = testPost ["api", "repos"]
              (A.encode (A.object
                [ "id"       .= ("r1" :: T.Text)
                , "url"      .= (urlStr :: T.Text)
                , "vcs_kind" .= ("github" :: T.Text)
                , "credential" .= A.object
                    [ "kind" .= ("pat" :: T.Text), "vault_key" .= ("k" :: T.Text) ]
                ]))
        req1 <- postRepo "https://github.com/owner/r1.git"
        (st1, b1) <- runAppBody app req1
        st1 `shouldBe` 201
        case A.decode b1 :: Maybe A.Value of
          Just (A.Object o) -> lookupK "url" o `shouldBe` Just (A.String "https://github.com/owner/r1.git")
          _ -> expectationFailure "expected first POST body"
        req2 <- postRepo "https://github.com/owner/r1-renamed.git"
        (st2, b2) <- runAppBody app req2
        st2 `shouldBe` 201
        case A.decode b2 :: Maybe A.Value of
          Just (A.Object o) -> lookupK "url" o `shouldBe` Just (A.String "https://github.com/owner/r1-renamed.git")
          _ -> expectationFailure "expected second POST body"
        -- GET reflects the updated url.
        (_, b3) <- runAppBody app (testRequest methodGet ["api", "repos", "r1"])
        case A.decode b3 :: Maybe A.Value of
          Just (A.Object o) -> lookupK "url" o `shouldBe` Just (A.String "https://github.com/owner/r1-renamed.git")
          _ -> expectationFailure "expected GET after upsert"

    it "POST /api/repos with missing id returns 400" $
      withSystemTempDirectory "seal-repos" $ \tmp -> do
        deps <- mkRepoApp tmp
        let app = apiApp deps
        req <- testPost ["api", "repos"]
          (A.encode (A.object
            [ "url"      .= ("https://github.com/o/r.git" :: T.Text)
            , "vcs_kind" .= ("git" :: T.Text)
            , "credential" .= A.object [ "kind" .= ("pat" :: T.Text), "vault_key" .= ("k" :: T.Text) ]
            ]))
        status <- runAppStatus app req
        status `shouldBe` 400

    it "POST /api/repos with a bad id (slash) returns 400" $
      withSystemTempDirectory "seal-repos" $ \tmp -> do
        deps <- mkRepoApp tmp
        let app = apiApp deps
        req <- testPost ["api", "repos"]
          (A.encode (A.object
            [ "id"       .= ("bad/id" :: T.Text)
            , "url"      .= ("https://github.com/o/r.git" :: T.Text)
            , "vcs_kind" .= ("git" :: T.Text)
            , "credential" .= A.object [ "kind" .= ("pat" :: T.Text), "vault_key" .= ("k" :: T.Text) ]
            ]))
        status <- runAppStatus app req
        status `shouldBe` 400

    it "POST /api/repos with an empty url returns 400" $
      withSystemTempDirectory "seal-repos" $ \tmp -> do
        deps <- mkRepoApp tmp
        let app = apiApp deps
        req <- testPost ["api", "repos"]
          (A.encode (A.object
            [ "id"       .= ("r2" :: T.Text)
            , "url"      .= ("" :: T.Text)
            , "vcs_kind" .= ("git" :: T.Text)
            , "credential" .= A.object [ "kind" .= ("pat" :: T.Text), "vault_key" .= ("k" :: T.Text) ]
            ]))
        status <- runAppStatus app req
        status `shouldBe` 400

    it "POST /api/repos with a malformed url (not SSH/HTTPS) returns 400" $
      withSystemTempDirectory "seal-repos" $ \tmp -> do
        deps <- mkRepoApp tmp
        let app = apiApp deps
        req <- testPost ["api", "repos"]
          (A.encode (A.object
            [ "id"       .= ("r3" :: T.Text)
            , "url"      .= ("not-a-url" :: T.Text)
            , "vcs_kind" .= ("git" :: T.Text)
            , "credential" .= A.object [ "kind" .= ("pat" :: T.Text), "vault_key" .= ("k" :: T.Text) ]
            ]))
        status <- runAppStatus app req
        status `shouldBe` 400

    it "POST /api/repos with a disallowed host returns 400" $
      withSystemTempDirectory "seal-repos" $ \tmp -> do
        deps <- mkRepoApp tmp
        let app = apiApp deps
        req <- testPost ["api", "repos"]
          (A.encode (A.object
            [ "id"       .= ("r4" :: T.Text)
            , "url"      .= ("git@evil.com:owner/repo.git" :: T.Text)
            , "vcs_kind" .= ("git" :: T.Text)
            , "credential" .= A.object [ "kind" .= ("pat" :: T.Text), "vault_key" .= ("k" :: T.Text) ]
            ]))
        status <- runAppStatus app req
        status `shouldBe` 400

    it "POST /api/repos with an unknown credential.kind returns 400" $
      withSystemTempDirectory "seal-repos" $ \tmp -> do
        deps <- mkRepoApp tmp
        let app = apiApp deps
        req <- testPost ["api", "repos"]
          (A.encode (A.object
            [ "id"       .= ("r5" :: T.Text)
            , "url"      .= ("https://github.com/o/r.git" :: T.Text)
            , "vcs_kind" .= ("git" :: T.Text)
            , "credential" .= A.object [ "kind" .= ("magic" :: T.Text), "vault_key" .= ("k" :: T.Text) ]
            ]))
        status <- runAppStatus app req
        status `shouldBe` 400

    it "POST /api/repos with machine_user but no username returns 400" $
      withSystemTempDirectory "seal-repos" $ \tmp -> do
        deps <- mkRepoApp tmp
        let app = apiApp deps
        req <- testPost ["api", "repos"]
          (A.encode (A.object
            [ "id"       .= ("r6" :: T.Text)
            , "url"      .= ("https://github.com/o/r.git" :: T.Text)
            , "vcs_kind" .= ("git" :: T.Text)
            , "credential" .= A.object
                [ "kind" .= ("machine_user" :: T.Text), "vault_key" .= ("k" :: T.Text) ]
            ]))
        status <- runAppStatus app req
        status `shouldBe` 400

    it "PUT /api/repos/:id on a missing repo returns 404" $
      withSystemTempDirectory "seal-repos" $ \tmp -> do
        deps <- mkRepoApp tmp
        let app = apiApp deps
        req <- testPut ["api", "repos", "ghost"]
          (A.encode (A.object
            [ "url"      .= ("https://github.com/o/ghost.git" :: T.Text)
            , "vcs_kind" .= ("git" :: T.Text)
            , "credential" .= A.object [ "kind" .= ("pat" :: T.Text), "vault_key" .= ("k" :: T.Text) ]
            ]))
        status <- runAppStatus app req
        status `shouldBe` 404

    it "PUT /api/repos/:id updates an existing repo (200 + updated descriptor)" $
      withSystemTempDirectory "seal-repos" $ \tmp -> do
        deps <- mkRepoApp tmp
        let app = apiApp deps
        createReq <- testPost ["api", "repos"]
          (A.encode (A.object
            [ "id"       .= ("putr" :: T.Text)
            , "url"      .= ("https://github.com/o/putr.git" :: T.Text)
            , "vcs_kind" .= ("git" :: T.Text)
            , "credential" .= A.object [ "kind" .= ("pat" :: T.Text), "vault_key" .= ("k" :: T.Text) ]
            ]))
        (createSt, _) <- runAppBody app createReq
        createSt `shouldBe` 201
        putReq <- testPut ["api", "repos", "putr"]
          (A.encode (A.object
            [ "url"      .= ("https://github.com/o/putr-v2.git" :: T.Text)
            , "vcs_kind" .= ("github" :: T.Text)
            , "credential" .= A.object [ "kind" .= ("deploy_key" :: T.Text), "vault_key" .= ("dk" :: T.Text) ]
            ]))
        (st, body) <- runAppBody app putReq
        st `shouldBe` 200
        case A.decode body :: Maybe A.Value of
          Just (A.Object o) -> do
            lookupK "id" o `shouldBe` Just (A.String "putr")
            lookupK "url" o `shouldBe` Just (A.String "https://github.com/o/putr-v2.git")
            lookupK "vcs_kind" o `shouldBe` Just (A.String "github")
            case lookupK "credential" o of
              Just (A.Object co) -> lookupK "kind" co `shouldBe` Just (A.String "deploy_key")
              _ -> expectationFailure "expected credential object"
          _ -> expectationFailure "expected JSON object for PUT repo"

    it "DELETE /api/repos/:id returns 204 and is idempotent" $
      withSystemTempDirectory "seal-repos" $ \tmp -> do
        deps <- mkRepoApp tmp
        let app = apiApp deps
        createReq <- testPost ["api", "repos"]
          (A.encode (A.object
            [ "id"       .= ("delr" :: T.Text)
            , "url"      .= ("https://github.com/o/delr.git" :: T.Text)
            , "vcs_kind" .= ("git" :: T.Text)
            , "credential" .= A.object [ "kind" .= ("pat" :: T.Text), "vault_key" .= ("k" :: T.Text) ]
            ]))
        (createSt, _) <- runAppBody app createReq
        createSt `shouldBe` 201
        delReq1 <- testDelete ["api", "repos", "delr"]
        st1 <- runAppStatus app delReq1
        st1 `shouldBe` 204
        -- GET → 404.
        (_, body) <- runAppBody app (testRequest methodGet ["api", "repos", "delr"])
        case A.decode body :: Maybe A.Value of
          Just (A.Object o) -> lookupK "error" o `shouldSatisfy` isJust
          _ -> expectationFailure "expected 404 object after delete"
        -- Delete again → still 204 (idempotent).
        delReq2 <- testDelete ["api", "repos", "delr"]
        st2 <- runAppStatus app delReq2
        st2 `shouldBe` 204

    it "DELETE /api/repos/:id with a malformed id returns 400" $
      withSystemTempDirectory "seal-repos" $ \tmp -> do
        deps <- mkRepoApp tmp
        let app = apiApp deps
        req <- testDelete ["api", "repos", "bad/id"]
        status <- runAppStatus app req
        status `shouldBe` 400

    it "GET /api/repos/:id with a malformed id returns 400" $
      withSystemTempDirectory "seal-repos" $ \tmp -> do
        deps <- mkRepoApp tmp
        let app = apiApp deps
        (_, body) <- runAppBody app (testRequest methodGet ["api", "repos", "bad/id"])
        case A.decode body :: Maybe A.Value of
          Just (A.Object o) -> lookupK "error" o `shouldSatisfy` isJust
          _ -> expectationFailure "expected 400 error object"

    it "never leaks a secret value in the repo descriptor (vault_key is a NAME)" $
      withSystemTempDirectory "seal-repos" $ \tmp -> do
        deps <- mkRepoApp tmp
        let app = apiApp deps
            secretValue = "ghp_SUPERSECRET_never_in_response_12345"
        -- POST a repo whose vault_key is a known name; the registry never
        -- stores the secret VALUE, so no response field should match it.
        createReq <- testPost ["api", "repos"]
          (A.encode (A.object
            [ "id"       .= ("sec" :: T.Text)
            , "url"      .= ("https://github.com/o/sec.git" :: T.Text)
            , "vcs_kind" .= ("git" :: T.Text)
            , "credential" .= A.object
                [ "kind" .= ("machine_user" :: T.Text)
                , "vault_key" .= ("github_token" :: T.Text)
                , "username" .= ("bot-account" :: T.Text)
                ]
            ]))
        (st, body) <- runAppBody app createReq
        st `shouldBe` 201
        let bodyText = T.pack (BC.unpack (BL.toStrict body))
        -- The secret value must not appear anywhere in the response.
        secretValue `T.isInfixOf` bodyText `shouldBe` False
        -- The credential object carries the vault key NAME + username, and
        -- has NO token/value/secret/password field.
        case A.decode body :: Maybe A.Value of
          Just (A.Object o) -> case lookupK "credential" o of
            Just (A.Object co) -> do
              lookupK "vault_key" co `shouldBe` Just (A.String "github_token")
              lookupK "username" co `shouldBe` Just (A.String "bot-account")
              lookupK "token" co `shouldBe` Nothing
              lookupK "value" co `shouldBe` Nothing
              lookupK "secret" co `shouldBe` Nothing
              lookupK "password" co `shouldBe` Nothing
            _ -> expectationFailure "expected credential object"
          _ -> expectationFailure "expected JSON object"
        -- GET the list and the single repo — same guard.
        (_, listBody) <- runAppBody app (testRequest methodGet ["api", "repos"])
        let listText = T.pack (BC.unpack (BL.toStrict listBody))
        secretValue `T.isInfixOf` listText `shouldBe` False
        (_, oneBody) <- runAppBody app (testRequest methodGet ["api", "repos", "sec"])
        let oneText = T.pack (BC.unpack (BL.toStrict oneBody))
        secretValue `T.isInfixOf` oneText `shouldBe` False

    it "GET /api/repos surfaces a corrupt repos.toml as 500 (NOT empty 200)" $ do
      -- Build an ApiDeps whose adRepoRegistry returns Left on rrhList
      -- (simulating a corrupt repos.toml). The handler must propagate the
      -- error as 500, not silently return [].
      tabsH <- newTabsHandle
      reg   <- newHarnessRegistry
      adb   <- noneBackend
      skills <- Skill.noneBackend
      activeRef <- newIORef fakeMeta
      uiState <- newUiStateHandle mkPaths
      corruptH <- mkCorruptRepoRegistryHandle
      let sr = SessionRuntime { srPaths = mkPaths, srConfigPath = "", srActive = activeRef }
          deps = ApiDeps
            { adSessionRuntime  = sr
            , adTabsHandle      = tabsH
            , adHarnessRegistry = reg
            , adAdoptConsent    = Just CcWeb
            , adAgentDefs       = adb
            , adSkills          = skills
            , adProviders       = pure knownProviders
            , adUiState         = uiState
            , adSend            = Nothing
            , adDefaultAgent    = pure Nothing
            , adBroker          = Nothing
            , adTabCloseNotifier = noTabCloseNotifier
            , adRepoRegistry     = corruptH
            , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
            }
          app = apiApp deps
      (status, body) <- runAppBody app (testRequest methodGet ["api", "repos"])
      status `shouldBe` 500
      case A.decode body :: Maybe A.Value of
        Just (A.Object o) -> lookupK "error" o `shouldSatisfy` isJust
        _ -> expectationFailure "expected a 500 error JSON object"

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
          skills <- Skill.noneBackend
          activeRef <- newIORef fakeMeta
          uiState <- newUiStateHandle mkPaths
          let sr = SessionRuntime { srPaths = mkPaths, srConfigPath = "", srActive = activeRef }
              deps = ApiDeps
                { adSessionRuntime  = sr
                , adTabsHandle      = tabsH
                , adHarnessRegistry = reg
                , adAdoptConsent    = Just CcWeb
                , adAgentDefs       = adb
                , adSkills          = skills
                , adProviders       = pure [OllamaProvider]
                , adUiState         = uiState
                , adSend            = Nothing
                , adDefaultAgent    = pure Nothing
                , adBroker          = Nothing
    , adTabCloseNotifier = noTabCloseNotifier
    , adRepoRegistry     = fakeRepoRegistryHandle
    , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
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

  it "POST /api/ui/repos appends and lists via GET" $
    withSystemTempDirectory "seal-ui-repos" $ \tmp -> do
      let paths = fakePaths { spState = tmp }
      deps <- mkDepsFor paths
      let app = apiApp deps
      addReq <- testPost ["api", "ui", "repos"]
        (A.encode (A.object [ "url" .= ("https://github.com/foo/bar" :: T.Text) ]))
      addStatus <- runAppStatus app addReq
      addStatus `shouldBe` 200
      -- A second URL keeps both, most-recent first.
      addReq2 <- testPost ["api", "ui", "repos"]
        (A.encode (A.object [ "url" .= ("git@github.com:x/y" :: T.Text) ]))
      _ <- runAppStatus app addReq2
      -- A duplicate dedupes (moves to front).
      addReq3 <- testPost ["api", "ui", "repos"]
        (A.encode (A.object [ "url" .= ("https://github.com/foo/bar" :: T.Text) ]))
      _ <- runAppStatus app addReq3
      -- Reload from disk to prove persistence.
      deps2 <- mkDepsFor paths
      let app2 = apiApp deps2
      (_, getBody) <- runAppBody app2 (testRequest methodGet ["api", "ui", "state"])
      let rh = case A.decode getBody :: Maybe A.Value of
            Just (A.Object o) -> case lookupK "repo_history" o of
              Just (A.Array a) -> V.toList a
              _               -> error "no repo_history array"
            _ -> error "could not decode GET body"
          toText v = case v of { A.String t -> t; _ -> "" }
      map toText rh `shouldBe` ["https://github.com/foo/bar", "git@github.com:x/y"]

  it "GET /api/ui/state includes repo_history as an empty array by default" $ do
    app <- mkApp
    (_, body) <- runAppBody app (testRequest methodGet ["api", "ui", "state"])
    let rh = case A.decode body :: Maybe A.Value of
          Just (A.Object o) -> lookupK "repo_history" o
          _ -> Nothing
    rh `shouldBe` Just (A.Array V.empty)

  -- ── Wired send path (adSend = Just SendDeps) ──────────────────────────
  -- A session that doesn't exist on disk returns 404. This exercises the
  -- handleSend -> loadSessionMeta -> Nothing path without needing a real
  -- provider/vault (the lookup happens before provider resolution).
  it "sendOutcomeJson (SendSlash with new sid) includes session_id" $ do
    let sid = case mkSessionId "20260719-120000-001" of
          Right s -> s
          Left _  -> error "invalid sid"
        (code, val) = sendOutcomeJson (SendSlash "new session minted" (Just sid))
    code `shouldBe` 200
    case val of
      A.Object o -> do
        case KeyMap.lookup (Key.fromText "kind") o of
          Just (A.String k) -> k `shouldBe` "slash"
          _ -> expectationFailure "expected kind: slash"
        case KeyMap.lookup (Key.fromText "session_id") o of
          Just (A.String s) -> s `shouldBe` "20260719-120000-001"
          _ -> expectationFailure "expected session_id string"
      _ -> expectationFailure "expected JSON object"

  describe "/api/sessions/:id/agents (session-scoped agent defs)" $ do
    -- Build a session.json + a workdir with a repo carrying
    -- .agents/agents.md + a sub-agent, plus a user agent-def backend with
    -- one def. @mDefault@ sets the configured default_agent (Nothing = none).
    -- Returns an Application ready to query. The temp dir lives for the
    -- test's duration (manual cleanup at start).
    let mkSessionAgentsApp :: Maybe T.Text -> IO (Application, T.Text)
        mkSessionAgentsApp mDefault = do
          -- Use a fixed temp dir under /tmp (cleaned at start; OS cleans /tmp).
          let tmp = "/tmp/seal-api-session-agents-test"
              stateRoot = tmp </> "state"
              cacheRoot = tmp </> "cache"
              sessionRoot = stateRoot </> "sessions"
          void (try (removeDirectoryRecursive tmp) :: IO (Either SomeException ()))
          createDirectoryIfMissing True stateRoot
          createDirectoryIfMissing True cacheRoot
          createDirectoryIfMissing True sessionRoot
          let sidTxt = "20260809-120000-sag"
              sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          -- Persist a session.json so the 404 check passes.
          let meta = fakeMeta { smId = sid }
          saveSessionMeta (fakePaths { spState = stateRoot, spCache = cacheRoot }) meta
          -- Build the workdir with a repo carrying .agents/ (protocol).
          let wd = cacheRoot </> "workdirs" </> T.unpack sidTxt
              repoDir = wd </> "my-repo"
          createDirectoryIfMissing True (repoDir </> ".agents" </> "agents" </> "foo-agent")
          writeFile (repoDir </> ".agents" </> "agents.md")
            "---\nkind: agents\n---\nProject guidelines.\n"
          writeFile (repoDir </> ".agents" </> "agents" </> "foo-agent" </> "agent.md")
            "---\nname: Foo\nprovider: ollama\n---\nYou are foo.\n"
          -- A user agent-def backend with one def "user-agent".
          userAdb <- noneBackend
          case mkAgentDefId "user-agent" of
            Right uid -> adbUpdate userAdb (AgentDef
              { adId = uid, adName = "User Agent", adProvider = ""
              , adModel = ModelId "", adSystem = Just "user prompt"
              , adTools = AllowAll
              , adCreatedAt = UTCTime (fromGregorian 2026 1 1) 0
              , adUpdatedAt = UTCTime (fromGregorian 2026 1 1) 0
              , adSession = mkSystemSessionId "manual" })
            Left _ -> expectationFailure "invalid user-agent id"
          -- Build ApiDeps with the user backend + the configured default.
          tabsH <- newTabsHandle
          reg <- newHarnessRegistry
          uiState <- newUiStateHandle fakePaths
          skillsBackend <- Skill.noneBackend
          repoRegH <- mkFakeRepoRegistryHandle
          activeRef <- newIORef meta
          let paths = fakePaths { spState = stateRoot, spCache = cacheRoot }
              sr = SessionRuntime { srPaths = paths, srConfigPath = "", srActive = activeRef }
              deps = ApiDeps
                { adSessionRuntime = sr, adTabsHandle = tabsH
                , adHarnessRegistry = reg, adAdoptConsent = Just CcWeb
                , adAgentDefs = userAdb, adSkills = skillsBackend
                , adProviders = pure knownProviders, adUiState = uiState
                , adSend = Nothing, adDefaultAgent = pure mDefault
                , adBroker = Nothing, adTabCloseNotifier = noTabCloseNotifier
                , adRepoRegistry = repoRegH, adConfigRepo = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault = fakeLockedVaultRuntime, adPaths = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
                }
          pure (apiApp deps, sidTxt)

    it "returns 200 + the unioned agent list (workdir ⊕ user) for a known session with .agents/" $ do
      (app, sid) <- mkSessionAgentsApp Nothing
      (status, body) <- runAppBody app (testRequest methodGet ["api", "sessions", sid, "agents"])
      status `shouldBe` 200
      case A.decode body :: Maybe A.Value of
        Just (A.Array xs) -> do
          let names = [ n | A.Object o <- V.toList xs
                          , Just (A.String n) <- [KeyMap.lookup (Key.fromText "name") o] ]
          -- Workdir defs: my-repo--agents-md, my-repo--foo-agent. User def: user-agent.
          names `shouldContain` ["my-repo--agents-md", "my-repo--foo-agent", "user-agent"]
        _ -> expectationFailure "expected a JSON array"

    it "marks agents-md as default when no user default_agent is configured" $ do
      (app, sid) <- mkSessionAgentsApp Nothing
      (status, body) <- runAppBody app (testRequest methodGet ["api", "sessions", sid, "agents"])
      status `shouldBe` 200
      case A.decode body :: Maybe A.Value of
        Just (A.Array xs) -> do
          let defaults = [ (n, isDef)
                       | A.Object o <- V.toList xs
                       , Just (A.String n) <- [KeyMap.lookup (Key.fromText "name") o]
                       , Just (A.Bool isDef) <- [KeyMap.lookup (Key.fromText "isDefault") o]
                       ]
          -- Exactly one entry is marked default: my-repo--agents-md.
          filter snd defaults `shouldBe` [("my-repo--agents-md", True)]
        _ -> expectationFailure "expected a JSON array"

    it "repo agents.md wins over a configured user default_agent (repo > user precedence)" $ do
      (app, sid) <- mkSessionAgentsApp (Just "user-agent")
      (status, body) <- runAppBody app (testRequest methodGet ["api", "sessions", sid, "agents"])
      status `shouldBe` 200
      case A.decode body :: Maybe A.Value of
        Just (A.Array xs) -> do
          let defaults = [ (n, isDef)
                       | A.Object o <- V.toList xs
                       , Just (A.String n) <- [KeyMap.lookup (Key.fromText "name") o]
                       , Just (A.Bool isDef) <- [KeyMap.lookup (Key.fromText "isDefault") o]
                       ]
          -- The repo's agents-md wins (repo > user default_agent); the
          -- user's configured default (user-agent) is NOT marked default.
          filter snd defaults `shouldBe` [("my-repo--agents-md", True)]
          defaults `shouldNotSatisfy` (("user-agent", True) `elem`)
        _ -> expectationFailure "expected a JSON array"

    it "returns 404 for an unknown session id" $ do
      app <- apiApp <$> mkDepsFor fakePaths
      status <- runAppStatus app (testRequest methodGet ["api", "sessions", "99999999-000000-nope", "agents"])
      status `shouldBe` 404

    -- W6 RED (headline integration test): GET /api/sessions/:id/agents in
    -- mode=remote (with mkSessionExec injected with a stub-remote WorkdirFs
    -- seeded with a fixture repo's .agents/agents.md) returns ≥1 repo-local
    -- def. This is the user-visible success metric for the remote-workdir FS
    -- seam — repo-agent discovery works over the remote arm without a live
    -- SSH connection. The test injects adMkSessionExec = Just (const (pure
    -- stubExec)) so handleSessionAgents bypasses the real mkSessionExec
    -- (which would shell out over SSH) and uses the in-memory WorkdirFs
    -- instead.
    it "GET /api/sessions/:id/agents in mode=remote discovers ≥1 repo-local def via stub-remote WorkdirFs" $ do
      let tmp = "/tmp/seal-api-session-agents-remote-test"
          stateRoot = tmp </> "state"
          cacheRoot = tmp </> "cache"
          sessionRoot = stateRoot </> "sessions"
      void (try (removeDirectoryRecursive tmp) :: IO (Either SomeException ()))
      createDirectoryIfMissing True stateRoot
      createDirectoryIfMissing True cacheRoot
      createDirectoryIfMissing True sessionRoot
      let sidTxt = "20260815-120000-rem"
          sid = case mkSessionId sidTxt of Right s -> s; Left _ -> error "sid"
          meta = fakeMeta { smId = sid }
      saveSessionMeta (fakePaths { spState = stateRoot, spCache = cacheRoot }) meta
      -- Seed a stub-remote WorkdirFs with a fixture repo carrying
      -- .agents/agents.md (the project-level def) + a sub-agent.
      let agentsMd = "---\nkind: agents\n---\n# Project\nDo good work.\n"
          fooMd = "---\nname: Foo Agent\nprovider: ollama\nmodel: llama3\nenabled: true\n---\nYou are a foo specialist.\n"
          rp :: T.Text -> RemotePath
          rp t = case mkRemotePath t of Right p -> p; Left _ -> error "bad remote path"
          seed = Map.fromList
            [ (rp ".", Directory ["my-repo"])
            , (rp "my-repo", Directory [".agents"])
            , (rp "my-repo/.agents", Directory ["agents.md", "agents"])
            , (rp "my-repo/.agents/agents.md", FileContent agentsMd)
            , (rp "my-repo/.agents/agents", Directory ["foo-agent"])
            , (rp "my-repo/.agents/agents/foo-agent", Directory ["agent.md"])
            , (rp "my-repo/.agents/agents/foo-agent/agent.md", FileContent fooMd)
            ]
          wfs = mkInMemWorkdirFs seed
          -- A stub SessionExec: the WorkdirFs is the in-memory seed; the
          -- UIOEnv carries the stub UntrustedIO (no real SSH). The workspace
          -- root is the stub's /workspace.
          stubExec = SessionExec
            { seUIOEnv = mkTestUIOEnv mkRemoteUntrustedIOStub stubCloneDeps
            , seWorkdirFs = wfs
            , seWorkspaceRoot = WorkspaceRoot "/workspace"
            }
      -- A user agent-def backend with one def "user-agent" (so the union is
      -- non-empty even without the workdir, proving the workdir defs are
      -- discovered on top).
      userAdb <- noneBackend
      case mkAgentDefId "user-agent" of
        Right uid -> adbUpdate userAdb (AgentDef
          { adId = uid, adName = "User Agent", adProvider = ""
          , adModel = ModelId "", adSystem = Just "user prompt"
          , adTools = AllowAll
          , adCreatedAt = UTCTime (fromGregorian 2026 1 1) 0
          , adUpdatedAt = UTCTime (fromGregorian 2026 1 1) 0
          , adSession = mkSystemSessionId "manual" })
        Left _ -> expectationFailure "invalid user-agent id"
      tabsH <- newTabsHandle
      reg <- newHarnessRegistry
      uiState <- newUiStateHandle fakePaths
      skillsBackend <- Skill.noneBackend
      repoRegH <- mkFakeRepoRegistryHandle
      activeRef <- newIORef meta
      let paths = fakePaths { spState = stateRoot, spCache = cacheRoot }
          sr = SessionRuntime { srPaths = paths, srConfigPath = "", srActive = activeRef }
          deps = ApiDeps
            { adSessionRuntime = sr, adTabsHandle = tabsH
            , adHarnessRegistry = reg, adAdoptConsent = Just CcWeb
            , adAgentDefs = userAdb, adSkills = skillsBackend
            , adProviders = pure knownProviders, adUiState = uiState
            , adSend = Nothing, adDefaultAgent = pure Nothing
            , adBroker = Nothing, adTabCloseNotifier = noTabCloseNotifier
            , adRepoRegistry = repoRegH, adConfigRepo = openConfigRepo "/tmp/nonexistent-seal-test"
            , adVault = fakeLockedVaultRuntime, adPaths = fakePaths, adWsPort = 8081
            , adSecurityConfig = defaultSecurityConfig
            , adMkSessionExec = Just (const (pure stubExec))
            }
          app = apiApp deps
      (status, body) <- runAppBody app (testRequest methodGet ["api", "sessions", sidTxt, "agents"])
      status `shouldBe` 200
      case A.decode body :: Maybe A.Value of
        Just (A.Array xs) -> do
          let names = [ n | A.Object o <- V.toList xs
                          , Just (A.String n) <- [KeyMap.lookup (Key.fromText "name") o] ]
          -- The repo-local defs (my-repo--agents-md, my-repo--foo-agent) are
          -- discovered via the stub-remote WorkdirFs, alongside the user def.
          names `shouldContain` ["my-repo--agents-md", "my-repo--foo-agent", "user-agent"]
          -- At least one repo-local def is present (the headline success metric).
          names `shouldSatisfy` any ("--agents-md" `T.isSuffixOf`)
        _ -> expectationFailure "expected a JSON array"

  it "sendOutcomeJson (SendSlash with no new sid) omits/nulls session_id" $ do
    let (code, val) = sendOutcomeJson (SendSlash "/help output" Nothing)
    code `shouldBe` 200
    case val of
      A.Object o ->
        case KeyMap.lookup (Key.fromText "session_id") o of
          Just A.Null -> pure ()  -- explicit null is fine
          Nothing     -> pure ()  -- omitted is also fine
          _ -> expectationFailure "expected null/absent session_id"
      _ -> expectationFailure "expected JSON object"

  it "POST /api/sessions/<sid>/send with adSend wired returns 404 for a missing session" $ do
    withSystemTempDirectory "seal-send" $ \tmp -> do
      tabsH <- newTabsHandle
      reg   <- newHarnessRegistry
      adb   <- noneBackend
      skills <- Skill.noneBackend
      activeRef <- newIORef fakeMeta
      uiState <- newUiStateHandle (fakePaths { spState = tmp })
      let sr = SessionRuntime { srPaths = fakePaths { spState = tmp }, srConfigPath = "", srActive = activeRef }
          sendDeps = SendDeps
            { sdPaths      = fakePaths { spState = tmp }
            , sdVault      = error "sdVault: unused on the 404 path"
            , sdRepoReg    = fakeRepoRegistryHandle
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
            , sdTabsHandle  = error "sdTabsHandle: unused on the 404 path"
            , sdLogger      = error "sdLogger: unused on the 404 path"
            , sdIsRemote    = False
            }
          deps = ApiDeps
            { adSessionRuntime  = sr
            , adTabsHandle      = tabsH
            , adHarnessRegistry = reg
            , adAdoptConsent    = Just CcWeb
            , adAgentDefs       = adb
            , adSkills          = skills
            , adProviders       = pure knownProviders
            , adUiState         = uiState
            , adSend            = Just sendDeps
            , adDefaultAgent    = pure Nothing
            , adBroker          = Nothing
    , adTabCloseNotifier = noTabCloseNotifier
    , adRepoRegistry     = fakeRepoRegistryHandle
    , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
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
      -- A real ProviderRuntime whose config path is nonexistent (loadRuntimeConfig
      -- fails -> defaults: 128KiB ceiling + fail-closed exec). The vault ref
      -- holds Nothing so resolveSessionProvider would fail — but sdResolve is
      -- stubbed, so the vault is never consulted.
      vaultRef <- newIORef (Nothing :: Maybe VaultHandle)
      mgr <- newManager defaultManagerSettings
      cntRef <- newIORef 0
      let rt = VaultRuntime { vrPaths = paths, vrConfigPath = configRoot </> "config.toml", vrHandleRef = vaultRef }
          pr = ProviderRuntime { prConfigPath = configRoot </> "config.toml", prVault = rt, prManager = mgr, prCallCounter = cntRef }
          paths = SealPaths
            { spHome = tmp, spState = stateRoot, spConfig = configRoot, spKeys = tmp </> "keys" , spCache = ""}
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
            , sdRepoReg    = fakeRepoRegistryHandle
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
            , sdTabsHandle  = tabsH
            , sdLogger      = error "sdLogger: set below"
            , sdIsRemote    = False
            }
          deps = ApiDeps
            { adSessionRuntime  = sr
            , adTabsHandle      = tabsH
            , adHarnessRegistry = reg
            , adAdoptConsent    = Just CcWeb
            , adAgentDefs       = adb
            , adSkills          = bSkills backends
            , adProviders       = pure knownProviders
            , adUiState         = uiState
            , adSend            = Just sendDeps
            , adDefaultAgent    = pure Nothing
            , adBroker          = Nothing
    , adTabCloseNotifier = noTabCloseNotifier
    , adRepoRegistry     = fakeRepoRegistryHandle
    , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
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
  -- ── Regression: benign slash commands must not navigate ─────────────
  -- The web gateway is multi-session: srActive is a process-global ref
  -- that may point at a DIFFERENT session than the one a request targets.
  -- A benign slash command (e.g. /skill list) must NOT cause the
  -- frontend to navigate away. The SendSlash outcome's session_id must
  -- be null/absent when the slash command didn't actually swap the
  -- active session during this call. See the runSlash
  -- newSessionIdIfChangedFrom fix in Seal.Gateway.Send.
  it "regression: /skill list on a non-active session returns no session_id" $
    withSystemTempDirectory "seal-slash" $ \tmp -> do
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
      let paths = SealPaths
            { spHome = tmp, spState = stateRoot, spConfig = configRoot, spKeys = tmp </> "keys" , spCache = ""}
          -- Two sessions on disk: the "active" one and the "request" one.
          -- The request will target the non-active one.
          activeSidTxt = "20260720-214230-238"
          requestSidTxt = "20260720-214349-258"
          activeSid = case mkSessionId activeSidTxt of Right s -> s; Left _ -> error "active sid"
          requestSid = case mkSessionId requestSidTxt of Right s -> s; Left _ -> error "request sid"
          activeMeta = fakeMeta { smId = activeSid }
          requestMeta = fakeMeta { smId = requestSid }
      -- Persist the request session's meta so handleSend's loadSessionMeta finds it.
      saveSessionMeta paths requestMeta
      -- The process-global active ref points at the OTHER session.
      activeRef <- newIORef activeMeta
      vaultRef <- newIORef (Nothing :: Maybe VaultHandle)
      mgr <- newManager defaultManagerSettings
      cntRef <- newIORef 0
      let rt = VaultRuntime { vrPaths = paths, vrConfigPath = configRoot </> "config.toml", vrHandleRef = vaultRef }
          pr = ProviderRuntime { prConfigPath = configRoot </> "config.toml", prVault = rt, prManager = mgr, prCallCounter = cntRef }
          sr = SessionRuntime { srPaths = paths, srConfigPath = configRoot </> "config.toml", srActive = activeRef }
          registry = mkRegistry [ skillCommandSpec (bSkills backends) (webCallDispatcher sendDeps) ]
          sendDeps = SendDeps
            { sdPaths      = paths
            , sdVault      = rt
            , sdRepoReg    = fakeRepoRegistryHandle
            , sdProvider   = pr
            , sdSession    = sr
            , sdBackends   = backends
            , sdConfigRepo = repo
            , sdPreprocess = emptyChain
            , sdRegistry   = registry
            , sdResolve    = \_ -> pure (Left "unused")
            , sdAutonomy   = Policy.Full
            , sdBroker     = Nothing
            , sdHarnessRegistry = reg
            , sdTmuxRunner  = tmuxR
            , sdHttpManager = Nothing
            , sdAskReply    = askReply
            , sdApprovals   = approvals
            , sdReplies     = error "sdReplies: unused on the slash path"
            , sdLocks       = error "sdLocks: unused on the slash path"
            , sdTabsHandle  = tabsH
            , sdLogger      = error "sdLogger: set below"
            , sdIsRemote    = False
            }
          deps = ApiDeps
            { adSessionRuntime  = sr
            , adTabsHandle      = tabsH
            , adHarnessRegistry = reg
            , adAdoptConsent    = Just CcWeb
            , adAgentDefs       = bAgentDefs backends
            , adSkills          = bSkills backends
            , adProviders       = pure knownProviders
            , adUiState         = error "adUiState: unused on the slash path"
            , adSend            = Just sendDeps
            , adDefaultAgent    = pure Nothing
            , adBroker          = Nothing
    , adTabCloseNotifier = noTabCloseNotifier
    , adRepoRegistry     = fakeRepoRegistryHandle
    , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
            }
          app = apiApp deps
      -- Send /skill list to the REQUEST session (not the active one).
      sendReq <- testPost ["api", "sessions", requestSidTxt, "send"]
        (A.encode (A.object [ "message" .= ("/skill list" :: T.Text) ]))
      (status, body) <- runAppBody app sendReq
      status `shouldBe` 200
      case A.decode body :: Maybe A.Value of
        Just (A.Object o) -> do
          -- kind must be "slash"
          case KeyMap.lookup (Key.fromText "kind") o of
            Just (A.String k) -> k `shouldBe` "slash"
            _ -> expectationFailure "expected kind: slash"
          -- session_id must be absent or null — the slash command did NOT
          -- swap the active session, so the frontend must NOT navigate.
          case KeyMap.lookup (Key.fromText "session_id") o of
            Nothing         -> pure ()
            Just A.Null     -> pure ()
            Just other      -> expectationFailure ("expected no session_id, got: " <> show other)
        _ -> expectationFailure "expected JSON object"

  -- ── Regression: /skill load must record the SKILL_LOAD transcript entry
  -- on the REQUEST session, not the process-global active session ──────
  -- webCallDispatcher reads srActive (the process-global active session
  -- ref) to decide which session's transcript to record the SKILL_LOAD
  -- result entry on. On a multi-session web gateway, the request's session
  -- may differ from srActive. The entry MUST land on the request session
  -- (the one the frontend is focused on / will re-seed from), otherwise
  -- the skill-load tool-call box never appears in the UI. This test sends
  -- /skill load to a non-active session and asserts the SKILL_LOAD entry
  -- is present in THAT session's transcript (via GET /transcript).
  it "regression: /skill load records the SKILL_LOAD entry on the request session" $
    withSystemTempDirectory "seal-skill-load" $ \tmp -> do
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
      let paths = SealPaths
            { spHome = tmp, spState = stateRoot, spConfig = configRoot, spKeys = tmp </> "keys" , spCache = ""}
          activeSidTxt = "20260720-214230-238"
          requestSidTxt = "20260720-214349-258"
          activeSid = case mkSessionId activeSidTxt of Right s -> s; Left _ -> error "active sid"
          requestSid = case mkSessionId requestSidTxt of Right s -> s; Left _ -> error "request sid"
          activeMeta = fakeMeta { smId = activeSid }
          requestMeta = fakeMeta { smId = requestSid }
      -- Persist BOTH sessions so the transcript seed read for either one
      -- resolves (readTranscriptEntries falls back to the session.json
      -- model/createdAt when reconstructing).
      saveSessionMeta paths activeMeta
      saveSessionMeta paths requestMeta
      -- The process-global active ref points at the OTHER session.
      activeRef <- newIORef activeMeta
      vaultRef <- newIORef (Nothing :: Maybe VaultHandle)
      mgr <- newManager defaultManagerSettings
      cntRef <- newIORef 0
      let rt = VaultRuntime { vrPaths = paths, vrConfigPath = configRoot </> "config.toml", vrHandleRef = vaultRef }
          pr = ProviderRuntime { prConfigPath = configRoot </> "config.toml", prVault = rt, prManager = mgr, prCallCounter = cntRef }
          sr = SessionRuntime { srPaths = paths, srConfigPath = configRoot </> "config.toml", srActive = activeRef }
          registry = mkRegistry [ skillCommandSpec (bSkills backends) (webCallDispatcher sendDeps) ]
          sendDeps = SendDeps
            { sdPaths      = paths
            , sdVault      = rt
            , sdRepoReg    = fakeRepoRegistryHandle
            , sdProvider   = pr
            , sdSession    = sr
            , sdBackends   = backends
            , sdConfigRepo = repo
            , sdPreprocess = emptyChain
            , sdRegistry   = registry
            , sdResolve    = \_ -> pure (Left "unused")
            , sdAutonomy   = Policy.Full
            , sdBroker     = Nothing
            , sdHarnessRegistry = reg
            , sdTmuxRunner  = tmuxR
            , sdHttpManager = Nothing
            , sdAskReply    = askReply
            , sdApprovals   = approvals
            , sdReplies     = error "sdReplies: unused on the slash path"
            , sdLocks       = error "sdLocks: unused on the slash path"
            , sdTabsHandle  = tabsH
            , sdLogger      = error "sdLogger: set below"
            , sdIsRemote    = False
            }
          deps = ApiDeps
            { adSessionRuntime  = sr
            , adTabsHandle      = tabsH
            , adHarnessRegistry = reg
            , adAdoptConsent    = Just CcWeb
            , adAgentDefs       = bAgentDefs backends
            , adSkills          = bSkills backends
            , adProviders       = pure knownProviders
            , adUiState         = error "adUiState: unused on the slash path"
            , adSend            = Just sendDeps
            , adDefaultAgent    = pure Nothing
            , adBroker          = Nothing
    , adTabCloseNotifier = noTabCloseNotifier
    , adRepoRegistry     = fakeRepoRegistryHandle
    , adConfigRepo       = openConfigRepo "/tmp/nonexistent-seal-test"
                , adVault            = fakeLockedVaultRuntime
                , adPaths            = fakePaths, adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
            }
          app = apiApp deps
      -- Send /skill load seal-usage to the REQUEST session (not the active one).
      sendReq <- testPost ["api", "sessions", requestSidTxt, "send"]
        (A.encode (A.object [ "message" .= ("/skill load seal-usage" :: T.Text) ]))
      (status, body) <- runAppBody app sendReq
      status `shouldBe` 200
      -- The slash response is the echo line (the body lives in the transcript).
      case A.decode body :: Maybe A.Value of
        Just (A.Object o) ->
          case KeyMap.lookup (Key.fromText "kind") o of
            Just (A.String k) -> k `shouldBe` "slash"
            _ -> expectationFailure "expected kind: slash"
        _ -> expectationFailure "expected JSON object"
      -- Read the REQUEST session's transcript back via the GET endpoint and
      -- assert it carries the SKILL_LOAD result entry (op.name = SKILL_LOAD
      -- with a result.body). This is the surface the frontend renders as the
      -- collapsible skill-load tool-call box.
      let transcriptReq = testRequest methodGet ["api", "sessions", requestSidTxt, "transcript"]
      (tStatus, tBody) <- runAppBody app transcriptReq
      tStatus `shouldBe` 200
      let entries = case A.decode tBody :: Maybe A.Value of
            Just (A.Array a) -> V.toList a
            _                -> []
      entries `shouldSatisfy` (not . null)
      let hasSkillLoad = any hasSkillLoadResult entries
      hasSkillLoad `shouldBe` True
      -- And the ACTIVE session's transcript must NOT carry the entry (it
      -- was not the target of the request).
      let activeTReq = testRequest methodGet ["api", "sessions", activeSidTxt, "transcript"]
      (_aStatus, aBody) <- runAppBody app activeTReq
      let activeEntries = case A.decode aBody :: Maybe A.Value of
            Just (A.Array a) -> V.toList a
            _                -> []
      any hasSkillLoadResult activeEntries `shouldBe` False
  where
    -- | Predicate: a transcript-entry Value is a SKILL_LOAD result entry
    -- (the frontend's ChatArea.tsx renders these as a collapsible
    -- tool-call box). The frontend's @transcriptToMessages@ parses the
    -- @payload@ field (the rewritten, frontend-facing shape) — NOT @raw@
    -- — so the test asserts the @payload@ carries @op.name = "SKILL_LOAD"@
    -- AND a @result@ object with a @body@ string. (Before the fix,
    -- @rewritePayload@ dropped @input@/@result@ from Request-direction
    -- harness entries, so @payload@ had only @op@ and the box never
    -- rendered even though @raw@ carried the full payload.)
    hasSkillLoadResult :: A.Value -> Bool
    hasSkillLoadResult v =
      case v of
        A.Object o ->
          case KeyMap.lookup (Key.fromText "payload") o of
            -- The payload is now a JSON object (not a string) in the
            -- reconstructed path, so we pattern-match directly.
            Just (A.Object ro) ->
              case ( KeyMap.lookup (Key.fromText "op") ro
                   , KeyMap.lookup (Key.fromText "result") ro ) of
                ( Just (A.Object op)
                 , Just (A.Object res)
                 ) ->
                  case KeyMap.lookup (Key.fromText "name") op of
                    Just (A.String n) -> n == "SKILL_LOAD" && KeyMap.member (Key.fromText "body") res
                    _ -> False
                _ -> False
            -- Legacy path: payload may still be a string (teLineToFrontend
            -- decodes it to an object, but defensively handle a string).
            Just (A.String payloadTxt) ->
              case A.decode (BL.fromStrict (TE.encodeUtf8 payloadTxt)) :: Maybe A.Value of
                Just (A.Object ro') ->
                  case ( KeyMap.lookup (Key.fromText "op") ro'
                       , KeyMap.lookup (Key.fromText "result") ro' ) of
                    ( Just (A.Object op)
                     , Just (A.Object res)
                     ) ->
                      case KeyMap.lookup (Key.fromText "name") op of
                        Just (A.String n) -> n == "SKILL_LOAD" && KeyMap.member (Key.fromText "body") res
                        _ -> False
                    _ -> False
                _ -> False
            _ -> False
        _ -> False
