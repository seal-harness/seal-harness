{-# LANGUAGE OverloadedStrings #-}
-- | Integration tests for the file explorer API routes (design §5.4).
--
-- Tests all three routes (list, content, download) against a local
-- 'FileExplorerHandle' backed by a temp directory. Covers success, 404,
-- 400, and 403 (disabled) cases.
module Seal.Gateway.ApiFilesSpec (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.ByteString.Char8 qualified as BC
import Data.IORef (newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime (..), fromGregorian)
import Network.HTTP.Types (status200, status400, status403, status404, status500)
import Network.Wai
  ( Application, Request, defaultRequest, pathInfo, queryString
  , requestMethod, requestHeaders, responseHeaders, responseStatus )
import Network.Wai.Internal (Response (..), ResponseReceived (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Config.Paths (SealPaths (..))
import Seal.Config.Security (defaultSecurityConfig)
import Seal.Core.Types (mkSessionId)
import Seal.Gateway.API (ApiDeps (..), apiApp)
import Seal.Gateway.Setup (stubSetupDeps)
import Seal.Gateway.Stream (StreamHealth (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..))
import Seal.Tools.Exec.Abort (newSessionAbortRegistry)
import Seal.Tools.Exec.FileExplorer
  ( FileExplorerHandle (..)
  , FileExplorerErr (..)
  , mkLocalFileExplorer
  , mkFailClosedFileExplorer
  )

spec :: Spec
spec = describe "Seal.Gateway.ApiFilesSpec" $ do
  describe "GET /api/files" $ do
    it "returns 200 with a directory listing for a valid path" $ do
      withSystemTempDirectory "seal-files-test" $ \tmp -> do
        createDirectoryIfMissing True (tmp </> "subdir")
        TIO.writeFile (tmp </> "hello.txt") "hello world"
        let fe = mkLocalFileExplorer 131072
        deps <- mkDeps fe True
        resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files"] [("path", Just (T.pack tmp))])
        responseStatus resp `shouldBe` status200

    it "returns 403 when file explorer is disabled" $ do
      deps <- mkDeps mkFailClosedFileExplorer False
      resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files"] [("path", Just "/tmp")])
      responseStatus resp `shouldBe` status403

    it "returns 400 when path is empty" $ do
      deps <- mkDeps (mkLocalFileExplorer 131072) True
      resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files"] [("path", Just "")])
      responseStatus resp `shouldBe` status400

    it "returns 404 for a non-existent path" $ do
      deps <- mkDeps (mkLocalFileExplorer 131072) True
      resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files"] [("path", Just "/nonexistent/path/that/does/not/exist")])
      responseStatus resp `shouldBe` status404

    it "returns 200 when path is absent (defaults to feResolveHome)" $ do
      withSystemTempDirectory "seal-files-test" $ \tmp -> do
        createDirectoryIfMissing True (tmp </> "subdir")
        let fe = (mkLocalFileExplorer 131072) { feResolveHome = pure (Right tmp) }
        deps <- mkDeps fe True
        resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files"] [])
        responseStatus resp `shouldBe` status200

    it "returns 500 (not 400) when feResolveHome fails with FeExec" $ do
      let fe = (mkLocalFileExplorer 131072) { feResolveHome = pure (Left (FeExec "SSH unreachable")) }
      deps <- mkDeps fe True
      resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files"] [])
      responseStatus resp `shouldBe` status500

    it "returns 403 (not 400) when feResolveHome fails with FeDisabled" $ do
      deps <- mkDeps mkFailClosedFileExplorer True
      resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files"] [])
      responseStatus resp `shouldBe` status403

  describe "GET /api/files/content" $ do
    it "returns 200 with file content as JSON" $ do
      withSystemTempDirectory "seal-files-test" $ \tmp -> do
        TIO.writeFile (tmp </> "test.txt") "line 1\nline 2\n"
        let fe = mkLocalFileExplorer 131072
        deps <- mkDeps fe True
        resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files", "content"] [("path", Just (T.pack (tmp </> "test.txt")))])
        responseStatus resp `shouldBe` status200

    it "returns 403 when file explorer is disabled" $ do
      deps <- mkDeps mkFailClosedFileExplorer False
      resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files", "content"] [("path", Just "/tmp/test.txt")])
      responseStatus resp `shouldBe` status403

    it "returns 400 when path is empty" $ do
      deps <- mkDeps (mkLocalFileExplorer 131072) True
      resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files", "content"] [("path", Just "")])
      responseStatus resp `shouldBe` status400

    it "returns 404 for a non-existent file" $ do
      deps <- mkDeps (mkLocalFileExplorer 131072) True
      resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files", "content"] [("path", Just "/nonexistent/file.txt")])
      responseStatus resp `shouldBe` status404

  describe "GET /api/files/download" $ do
    it "returns 200 with octet-stream and Content-Disposition for a valid file" $ do
      withSystemTempDirectory "seal-files-test" $ \tmp -> do
        TIO.writeFile (tmp </> "data.bin") "binary data here"
        let fe = mkLocalFileExplorer 131072
        deps <- mkDeps fe True
        resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files", "download"] [("path", Just (T.pack (tmp </> "data.bin")))])
        responseStatus resp `shouldBe` status200
        let hdrs = responseHeaders resp
        lookup "Content-Disposition" hdrs `shouldSatisfy` isJust
        lookup "X-Content-Type-Options" hdrs `shouldBe` Just "nosniff"
        lookup "X-Truncated" hdrs `shouldBe` Just "false"

    it "returns 403 when file explorer is disabled" $ do
      deps <- mkDeps mkFailClosedFileExplorer False
      resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files", "download"] [("path", Just "/tmp/test.txt")])
      responseStatus resp `shouldBe` status403

    it "returns 400 when path is empty" $ do
      deps <- mkDeps (mkLocalFileExplorer 131072) True
      resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files", "download"] [("path", Just "")])
      responseStatus resp `shouldBe` status400

    it "returns 404 for a non-existent file" $ do
      deps <- mkDeps (mkLocalFileExplorer 131072) True
      resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files", "download"] [("path", Just "/nonexistent/file.bin")])
      responseStatus resp `shouldBe` status404

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Build minimal ApiDeps for file explorer tests. Uses 'undefined' for
-- fields the file explorer routes never touch (the dispatch is a pure
-- pattern match on method + pathInfo before any field is read).
mkDeps :: FileExplorerHandle -> Bool -> IO ApiDeps
mkDeps fe enabled = do
  abortReg <- newSessionAbortRegistry
  let paths = SealPaths
        { spHome = "/tmp", spState = "/tmp", spConfig = "/tmp"
        , spKeys = "/tmp", spCache = "/tmp"
        }
      meta0 = SessionMeta
        (case mkSessionId "test" of Right s -> s; Left _ -> error "sid")
        "ollama" "llama3.2" "web" Nothing Nothing Nothing Nothing Nothing True Nothing Nothing
        (UTCTime (fromGregorian 2026 1 1) 0) (UTCTime (fromGregorian 2026 1 1) 0)
  activeRef <- newIORef meta0
  let sr = SessionRuntime
        { srPaths = paths, srConfigPath = "/tmp/config.toml"
        , srActive = activeRef }
  pure ApiDeps
    { adSessionRuntime = sr
    , adTabsHandle = undefined
    , adHarnessRegistry = undefined
    , adAdoptConsent = Nothing
    , adAgentDefs = undefined
    , adSkills = undefined
    , adProviders = pure []
    , adUiState = undefined
    , adSend = Nothing
    , adDefaultAgent = pure Nothing
    , adBroker = Nothing
    , adTabCloseNotifier = const (pure ())
    , adRepoRegistry = undefined
    , adAgentRegistry = undefined
    , adConfigRepo = undefined
    , adVault = undefined
    , adPaths = paths
    , adCanonicalOrigin = Nothing
    , adSetup = stubSetupDeps
    , adWsHealth = pure (StreamHealth "up" 8081)
    , adSecurityConfig = defaultSecurityConfig
    , adMkSessionExec = Nothing
    , adAbortReg = abortReg
    , adFileExplorer = fe
    , adFileExplorerEnabled = enabled
    }

-- | Build a GET request with path segments and query params.
mkGetReq :: [Text] -> [(Text, Maybe Text)] -> Request
mkGetReq segments params = defaultRequest
  { requestMethod = "GET"
  , pathInfo = segments
  , queryString = map (\(k, v) -> (BC.pack (T.unpack k), fmap (BC.pack . T.unpack) v)) params
  , requestHeaders = []
  }

-- | Run an app against a request and capture the full Response.
runAppResp :: Application -> Request -> IO Response
runAppResp app req = do
  mv <- newEmptyMVar
  _rr <- app req (\resp -> putMVar mv resp >> pure ResponseReceived)
  takeMVar mv

-- | Check that a Maybe is Just.
isJust :: Maybe a -> Bool
isJust Nothing = False
isJust (Just _) = True
