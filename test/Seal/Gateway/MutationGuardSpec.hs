{-# LANGUAGE OverloadedStrings #-}
-- | RED tests for the mutation guard's wiring (issue #302, WU4).
--
-- These are API-level: they drive the real 'apiApp' and assert the status code
-- and headers. They deliberately do not touch the request builders in
-- 'Seal.Gateway.ApiSpec' — the guard reads headers that already exist, and the
-- canonical origin is 'Nothing' in every other test fixture, so the existing
-- suite keeps its old behaviour.
--
-- The fixture mirrors 'Seal.Gateway.ServerSpec' (a compact 'ApiDeps' over the
-- shared fakes) rather than the full integration harness: none of these cases
-- needs a session turn, a provider, or a repo.
module Seal.Gateway.MutationGuardSpec (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as BSB
import Data.ByteString.Lazy qualified as BL
import Data.CaseInsensitive (mk)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
import Network.HTTP.Types
  ( Header, Status, methodDelete, methodOptions, methodPost, methodPut, statusCode )
import Network.Wai
  ( Application, Request, defaultRequest, pathInfo, requestHeaders, requestMethod
  , responseHeaders, responseStatus, responseToStream, setRequestBodyChunks )
import Network.Wai.Internal (Response (..), ResponseReceived (..))
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec

import Seal.Agent.Def.Backend (noneBackend)
import Seal.Command.Tab (noTabCloseNotifier)
import Seal.Config.Paths (SealPaths (..), sshAgentsDir)
import Seal.Config.Security (defaultSecurityConfig)
import Seal.Core.Types (mkSessionId)
import Seal.Gateway.API (ApiDeps (..), apiApp)
import Seal.Gateway.Setup (collectBodyLimited, maxSetupBodyBytes, stubSetupDeps)
import Seal.Gateway.Stream (StreamHealth (..))
import Seal.Git.Repo (openConfigRepo)
import Seal.Harness.Registry (newHarnessRegistry)
import Seal.Providers.Registry (knownProviders)
import Seal.Security.Adoption (ConsentChannel (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..))
import Seal.Skills.Backend qualified as Skill (noneBackend)
import Seal.SourceControl.AgentRegistry (mkAgentRegistryHandle)
import Seal.SourceControl.Registry (RepoRegistryHandle (..))
import Seal.Tabs (newTabsHandle)
import Seal.TestHelpers.FakeVault (fakeLockedVaultRuntime)
import Seal.Tools.Exec.Abort (SessionAbortRegistry, newSessionAbortRegistry)
import Seal.Web.UiState (newUiStateHandle)

spec :: Spec
spec = describe "Seal.Gateway mutation guard" $ do

  describe "with a canonical origin (http://localhost:8080)" $ do
    it "rejects a foreign Origin on a mutation, with the error envelope" $ do
      app <- mkApp (Just canonical)
      (status, body) <- runAppBody app (request methodPost ["api", "providers"] [origin "https://evil.example"])
      statusCode status `shouldBe` 403
      -- The shared error envelope is what the frontend parses.
      T.unpack (TE.decodeUtf8Lenient (BL.toStrict body)) `shouldContain` "\"error\""

    it "accepts the SPA's own loopback origin (127.0.0.1 vs localhost)" $ do
      app <- mkApp (Just canonical)
      resp <- runApp app (request methodPost stopPath [origin "http://127.0.0.1:5173"])
      statusCode (responseStatus resp) `shouldBe` 200

    it "rejects a cross-site fetch with no Origin" $ do
      app <- mkApp (Just canonical)
      resp <- runApp app (request methodPost stopPath [secFetchSite "cross-site"])
      statusCode (responseStatus resp) `shouldBe` 403

    it "accepts a request with no Origin at all (curl, chat channels)" $ do
      app <- mkApp (Just canonical)
      resp <- runApp app (request methodPost stopPath [])
      statusCode (responseStatus resp) `shouldBe` 200

    it "guards POST, PUT and DELETE on existing mutating routes" $ do
      app <- mkApp (Just canonical)
      forM_ [ (methodPost, ["api", "providers"])
            , (methodPut, ["api", "providers", "default"])
            , (methodDelete, ["api", "secrets", "SOME_KEY"])
            ] $ \(mth, path) -> do
        resp <- runApp app (request mth path [origin "https://evil.example"])
        statusCode (responseStatus resp) `shouldBe` 403

    it "does not guard reads" $ do
      app <- mkApp (Just canonical)
      health <- runApp app (request "GET" ["api", "health"] [origin "https://evil.example"])
      statusCode (responseStatus health) `shouldBe` 200
      lists <- runApp app (request "GET" ["api", "lists"] [origin "https://evil.example"])
      statusCode (responseStatus lists) `shouldBe` 200

  describe "with no canonical origin (mode = none on a wildcard bind)" $
    it "allows a mutation from any Origin" $ do
      app <- mkApp Nothing
      resp <- runApp app (request methodPost stopPath [origin "https://evil.example"])
      statusCode (responseStatus resp) `shouldBe` 200

  describe "CORS removal" $ do
    it "sets no Access-Control-Allow-Origin on a success response" $ do
      app <- mkApp (Just canonical)
      resp <- runApp app (request "GET" ["api", "health"] [])
      hasAcao resp `shouldBe` False
      statusCode (responseStatus resp) `shouldBe` 200

    it "sets no Access-Control-Allow-Origin on a rejection" $ do
      app <- mkApp (Just canonical)
      resp <- runApp app (request methodPost stopPath [origin "https://evil.example"])
      hasAcao resp `shouldBe` False
      statusCode (responseStatus resp) `shouldBe` 403

    it "sets no Access-Control-Allow-Origin on a list response (jsonLBS)" $ do
      app <- mkApp (Just canonical)
      resp <- runApp app (request "GET" ["api", "lists"] [])
      hasAcao resp `shouldBe` False

    it "answers OPTIONS without a CORS grant" $ do
      app <- mkApp (Just canonical)
      resp <- runApp app (request methodOptions ["api", "sessions"] [])
      statusCode (responseStatus resp) `shouldBe` 204
      hasAcao resp `shouldBe` False

  describe "collectBodyLimited" $ do
    it "returns the body under the cap" $ do
      req <- bodyReq (BL.replicate (fromIntegral maxSetupBodyBytes) 97)
      result <- collectBodyLimited maxSetupBodyBytes req
      either (\_ -> expectationFailure "expected the body to be accepted")
             (\body -> BS.length body `shouldBe` maxSetupBodyBytes)
             result

    it "rejects a body over the cap" $ do
      req <- bodyReq (BL.replicate (fromIntegral maxSetupBodyBytes + 1) 97)
      result <- collectBodyLimited maxSetupBodyBytes req
      either (const (pure ())) (\_ -> expectationFailure "expected rejection") result

-- Fixture -------------------------------------------------------------------

canonical :: Text
canonical = "http://localhost:8080"

stopPath :: [Text]
stopPath = ["api", "sessions", "test", "stop"]

origin :: Text -> Header
origin t = (mk "Origin", TE.encodeUtf8 t)

secFetchSite :: Text -> Header
secFetchSite t = (mk "Sec-Fetch-Site", TE.encodeUtf8 t)

request :: ByteString -> [Text] -> [Header] -> Request
request mth path hdrs = defaultRequest
  { requestMethod = mth
  , pathInfo = path
  , requestHeaders = hdrs
  }

runApp :: Application -> Request -> IO Response
runApp app req = do
  mv <- newEmptyMVar
  _ <- app req (\resp -> putMVar mv resp >> pure ResponseReceived)
  takeMVar mv

-- | Run the app and capture the status plus the full body, for the cases that
-- assert on the error envelope.
runAppBody :: Application -> Request -> IO (Status, BL.ByteString)
runAppBody app req = do
  mv <- newEmptyMVar
  _ <- app req $ \resp -> do
    let (st, _hdrs, withBody) = responseToStream resp
    ref <- newIORef []
    withBody $ \streamingBody ->
      streamingBody (\builder -> modifyIORef' ref (builder :)) (pure ())
    builders <- readIORef ref
    putMVar mv (st, BSB.toLazyByteString (mconcat (reverse builders)))
    pure ResponseReceived
  takeMVar mv

hasAcao :: Response -> Bool
hasAcao resp = any (\(n, _) -> n == mk "Access-Control-Allow-Origin") (responseHeaders resp)

bodyReq :: BL.ByteString -> IO Request
bodyReq body = do
  -- One-shot body: the first read returns the bytes, the next signals EOF.
  usedRef <- newIORef False
  let readChunk = do
        already <- readIORef usedRef
        if already
          then pure BS.empty
          else writeIORef usedRef True >> pure (BL.toStrict body)
  pure (setRequestBodyChunks readChunk defaultRequest { requestMethod = methodPost })

-- | The compact 'ApiDeps' fixture (see 'Seal.Gateway.ServerSpec').
mkApp :: Maybe Text -> IO Application
mkApp canonicalOrigin = do
  tabsH <- newTabsHandle
  reg <- newHarnessRegistry
  adb <- noneBackend
  skills <- Skill.noneBackend
  activeRef <- newIORef fakeMeta
  uiState <- newUiStateHandle fakePaths
  agentRegH <- mkAgentRegistryHandle (sshAgentsDir fakePaths)
  let sr = SessionRuntime { srPaths = fakePaths, srConfigPath = "", srActive = activeRef }
      repoRegH = RepoRegistryHandle { rrhList = pure (Right []), rrhMutate = \_ -> pure (Right ()) }
  pure $ apiApp ApiDeps
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
    , adCanonicalOrigin = canonicalOrigin
    , adSetup = stubSetupDeps
    , adWsHealth = pure (StreamHealth "up" 8081)
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
    , adAbortReg = testAbortReg
    }

testAbortReg :: SessionAbortRegistry
testAbortReg = unsafePerformIO newSessionAbortRegistry
{-# NOINLINE testAbortReg #-}

fakePaths :: SealPaths
fakePaths = SealPaths { spHome = "", spState = "", spConfig = "", spKeys = "", spCache = "" }

fakeMeta :: SessionMeta
fakeMeta =
  let sid' = case mkSessionId "test" of
        Right s -> s
        Left e  -> error ("test session id: " <> show e)
  in SessionMeta sid' "ollama" "llama3" "cli" Nothing Nothing Nothing Nothing Nothing True
       Nothing Nothing
       (UTCTime (fromGregorian 2026 1 1) 0) (UTCTime (fromGregorian 2026 1 1) 0)
