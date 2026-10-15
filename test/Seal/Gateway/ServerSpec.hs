{-# LANGUAGE OverloadedStrings #-}
module Seal.Gateway.ServerSpec (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.CaseInsensitive (mk)
import Data.List (isInfixOf)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Time (UTCTime(..), fromGregorian)
import Control.Monad (when)
import Network.HTTP.Types (methodGet, methodPost, status200, statusCode)
import Network.Wai
  ( Application, Request, Response, defaultRequest, pathInfo, requestMethod
  , responseLBS, responseHeaders, responseStatus )
import Network.Wai.Internal (ResponseReceived (..))
import System.IO.Temp (withSystemTempDirectory)
import System.IO.Unsafe (unsafePerformIO)
import System.Directory (createDirectoryIfMissing)
import Data.ByteString.Char8 qualified as BC
import Test.Hspec

import Seal.Agent.Def.Backend (noneBackend)
import Seal.Config.Paths (SealPaths (..), sshAgentsDir)
import Seal.Config.Security (defaultSecurityConfig)
import Seal.Core.Types (mkSessionId)
import Seal.Gateway.Server (gatewayApp, requestTimingMiddlewareWith)
import Seal.Gateway.Embedded (embeddedAssetCount)
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Providers.Registry (knownProviders)
import Seal.Security.Adoption (ConsentChannel (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..))
import Seal.Tools.Exec.Abort (SessionAbortRegistry, newSessionAbortRegistry)
import Seal.Skills.Backend qualified as Skill (noneBackend)
import Seal.SourceControl.AgentRegistry (mkAgentRegistryHandle)
import Seal.SourceControl.Registry (RepoRegistryHandle (..))
import Seal.Command.Tab (noTabCloseNotifier)
import Seal.Git.Repo (openConfigRepo)
import Seal.Logging.Logger (SealLogger, testSealLogger)
import System.FilePath ((</>))
import Seal.Tabs (newTabsHandle)
import Seal.Gateway.API (ApiDeps (..))
import Seal.TestHelpers.FakeVault (fakeLockedVaultRuntime)
import Seal.Web.UiState (newUiStateHandle)

-- | A shared test abort registry (top-level, created once via unsafePerformIO).
testAbortReg :: SessionAbortRegistry
testAbortReg = unsafePerformIO newSessionAbortRegistry
{-# NOINLINE testAbortReg #-}

-- | A shared test logger (no-op scribe — tests don't assert log output).
testLogger :: SealLogger
testLogger = unsafePerformIO testSealLogger
{-# NOINLINE testLogger #-}

fakePaths :: SealPaths
fakePaths = SealPaths { spHome = "", spState = "", spConfig = "", spKeys = "", spCache = "" }

fakeMeta :: SessionMeta
fakeMeta =
  let sid = case mkSessionId "test" of Right s -> s; Left _ -> error "sid"
  in SessionMeta sid "ollama" "llama3" "cli" Nothing Nothing Nothing Nothing Nothing (UTCTime (fromGregorian 2026 1 1) 0) (UTCTime (fromGregorian 2026 1 1) 0)

runAppStatus :: Application -> Request -> IO Int
runAppStatus app req = do
  mv <- newEmptyMVar
  _rr <- app req (\resp -> putMVar mv (statusCode (responseStatus resp)) >> pure ResponseReceived)
  takeMVar mv

-- | Run an app and capture the full Response (for header/body inspection).
runAppResp :: Application -> Request -> IO Response
runAppResp app req = do
  mv <- newEmptyMVar
  _rr <- app req (\resp -> putMVar mv resp >> pure ResponseReceived)
  takeMVar mv

-- | Check if a response has a specific header value (case-insensitive).
hasHeader :: Response -> BC.ByteString -> BC.ByteString -> Bool
hasHeader resp name value =
  any (\(n, v) -> n == mk name && v == value) (responseHeaders resp)

mkDeps :: IO ApiDeps
mkDeps = do
  tabsH <- newTabsHandle
  reg   <- newHarnessRegistry
  adb   <- noneBackend
  skills <- Skill.noneBackend
  activeRef <- newIORef fakeMeta
  uiState <- newUiStateHandle fakePaths
  let sr = SessionRuntime { srPaths = fakePaths, srConfigPath = "", srActive = activeRef }
      repoRegH = RepoRegistryHandle
        { rrhList   = pure (Right [])
        , rrhMutate = \_ -> pure (Right ())
        }
  agentRegH <- mkAgentRegistryHandle (sshAgentsDir fakePaths)
  pure (ApiDeps
    { adSessionRuntime = sr
    , adTabsHandle = tabsH
    , adHarnessRegistry = reg
    , adAdoptConsent = Just CcWeb
    , adAgentDefs = adb
    , adSkills = skills
    , adProviders = pure knownProviders
    , adUiState = uiState
    , adSend = Nothing
    , adDefaultAgent = pure Nothing
    , adBroker = Nothing
    , adTabCloseNotifier = noTabCloseNotifier
    , adRepoRegistry = repoRegH
    , adAgentRegistry = agentRegH
    , adConfigRepo = openConfigRepo "/tmp/nonexistent-seal-test"
    , adVault = fakeLockedVaultRuntime
    , adPaths = fakePaths
    , adWsPort = 8081
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
    , adAbortReg = testAbortReg
    })

spec :: Spec
spec = describe "Seal.Gateway.Server" $ do
  it "gatewayApp routes /api/health to the API" $ do
    deps <- mkDeps
    let app = gatewayApp testLogger deps Nothing
    status <- runAppStatus app (defaultRequest { pathInfo = ["api", "health"] })
    status `shouldBe` 200

  it "gatewayApp returns 404 for a non-api path with no static dir" $ do
    deps <- mkDeps
    let app = gatewayApp testLogger deps Nothing
    status <- runAppStatus app (defaultRequest { pathInfo = ["foo", "bar"] })
    -- When assets are embedded: SPA fallback → 200.
    -- When no assets (fresh checkout): emptyEmbedResponse → 404.
    if embeddedAssetCount > 0
      then status `shouldBe` 200
      else status `shouldBe` 404

  -- ── Embedded serving tests (only when assets are embedded) ─────────

  it "serveEmbedded: GET / returns 200 (index.html) when assets embedded" $
    when (embeddedAssetCount > 0) $ do
      deps <- mkDeps
      let app = gatewayApp testLogger deps Nothing
      status <- runAppStatus app (defaultRequest { pathInfo = [] })
      status `shouldBe` 200

  it "serveEmbedded: GET /some/spa/route returns 200 (SPA fallback) when assets embedded" $
    when (embeddedAssetCount > 0) $ do
      deps <- mkDeps
      let app = gatewayApp testLogger deps Nothing
      status <- runAppStatus app (defaultRequest { pathInfo = ["some", "spa", "route"] })
      status `shouldBe` 200

  it "serveEmbedded: GET /assets/nonexistent.js returns 404 (asset miss)" $
    when (embeddedAssetCount > 0) $ do
      deps <- mkDeps
      let app = gatewayApp testLogger deps Nothing
      status <- runAppStatus app (defaultRequest { pathInfo = ["assets", "nonexistent.js"] })
      status `shouldBe` 404

  it "serveEmbedded: GET /user.profile returns 200 (SPA fallback, .profile not in assetExtensions)" $
    when (embeddedAssetCount > 0) $ do
      deps <- mkDeps
      let app = gatewayApp testLogger deps Nothing
      status <- runAppStatus app (defaultRequest { pathInfo = ["user.profile"] })
      status `shouldBe` 200

  it "serveEmbedded: all responses have X-Content-Type-Options: nosniff" $
    when (embeddedAssetCount > 0) $ do
      deps <- mkDeps
      let app = gatewayApp testLogger deps Nothing
      resp <- runAppResp app (defaultRequest { pathInfo = [] })
      responseStatus resp `shouldBe` status200
      hasHeader resp "X-Content-Type-Options" "nosniff" `shouldBe` True

  it "gatewayApp serves index.html for the root with a static dir" $
    withSystemTempDirectory "seal-static-test" $ \dir -> do
      BC.writeFile (dir </> "index.html") "<html>ok</html>"
      deps <- mkDeps
      let app = gatewayApp testLogger deps (Just dir)
      status <- runAppStatus app (defaultRequest { pathInfo = [] })
      status `shouldBe` 200

  -- ── Disk-path traversal tests ──────────────────────────────────────

  it "serveStatic: GET /../ does not return 200" $
    withSystemTempDirectory "seal-static-test" $ \dir -> do
      BC.writeFile (dir </> "index.html") "<html>ok</html>"
      deps <- mkDeps
      let app = gatewayApp testLogger deps (Just dir)
      status <- runAppStatus app (defaultRequest { pathInfo = [".."] })
      status `shouldNotBe` 200

  it "serveStatic: GET /subdir/file serves nested files" $
    withSystemTempDirectory "seal-static-test" $ \dir -> do
      createDirectoryIfMissing True (dir </> "assets")
      BC.writeFile (dir </> "assets" </> "test.js") "console.log('hi');"
      BC.writeFile (dir </> "index.html") "<html>ok</html>"
      deps <- mkDeps
      let app = gatewayApp testLogger deps (Just dir)
      status <- runAppStatus app (defaultRequest { pathInfo = ["assets", "test.js"] })
      status `shouldBe` 200

  it "serveStatic: GET /nonexistent.js returns 404 (asset miss, not HTML)" $
    withSystemTempDirectory "seal-static-test" $ \dir -> do
      BC.writeFile (dir </> "index.html") "<html>ok</html>"
      deps <- mkDeps
      let app = gatewayApp testLogger deps (Just dir)
      status <- runAppStatus app (defaultRequest { pathInfo = ["nonexistent.js"] })
      status `shouldBe` 404

  it "gatewayApp serves /api/openapi.json as JSON" $ do
    deps <- mkDeps
    let app = gatewayApp testLogger deps Nothing
    status <- runAppStatus app (defaultRequest { pathInfo = ["api", "openapi.json"], requestMethod = methodGet })
    status `shouldBe` 200

  it "gatewayApp serves /api/openapi as HTML (Swagger UI)" $ do
    deps <- mkDeps
    let app = gatewayApp testLogger deps Nothing
    status <- runAppStatus app (defaultRequest { pathInfo = ["api", "openapi"], requestMethod = methodGet })
    status `shouldBe` 200

  -- ── requestTimingMiddleware ─────────────────────────────────────────

  describe "Seal.Gateway.Server.requestTimingMiddlewareWith" $ do
    let okApp _ respond = respond (responseLBS status200 [] "ok")

    it "logs the HTTP method, path, status, and duration for each request" $ do
      logRef <- newIORef ([] :: [String])
      let logger msg = modifyIORef' logRef (++ [msg])
          timedApp = requestTimingMiddlewareWith logger okApp
      status <- runAppStatus timedApp (defaultRequest { pathInfo = ["api", "lists"], requestMethod = methodGet })
      status `shouldBe` 200
      logs <- readIORef logRef
      length logs `shouldBe` 1
      case logs of
        (entry : _) -> do
          entry `shouldSatisfy` ("GET" `isInfixOf`)
          entry `shouldSatisfy` ("api/lists" `isInfixOf`)
          entry `shouldSatisfy` ("200" `isInfixOf`)
          entry `shouldSatisfy` ("ms" `isInfixOf`)
        [] -> expectationFailure "expected at least one log entry"

    it "is transparent — the response is unchanged" $ do
      logRef <- newIORef ([] :: [String])
      let logger msg = modifyIORef' logRef (++ [msg])
          timedApp = requestTimingMiddlewareWith logger okApp
      status <- runAppStatus timedApp (defaultRequest { pathInfo = ["api", "health"], requestMethod = methodGet })
      status `shouldBe` 200

    it "logs POST method correctly" $ do
      logRef <- newIORef ([] :: [String])
      let logger msg = modifyIORef' logRef (++ [msg])
          timedApp = requestTimingMiddlewareWith logger okApp
      _ <- runAppStatus timedApp (defaultRequest { pathInfo = ["api", "sessions", "new"], requestMethod = methodPost })
      logs <- readIORef logRef
      case logs of
        (entry : _) -> entry `shouldSatisfy` ("POST" `isInfixOf`)
        [] -> expectationFailure "expected at least one log entry"
