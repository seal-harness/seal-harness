{-# LANGUAGE OverloadedStrings #-}
-- | Integration tests for the file explorer API routes (design §5.4).
--
-- Tests all three routes (list, content, download) against a local
-- 'FileExplorerHandle' backed by a temp directory. Covers success, 404,
-- 400, and 403 (disabled) cases.
module Seal.Gateway.ApiFilesSpec (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Builder (Builder, toLazyByteString)
import Data.Text.Encoding (decodeUtf8)
import Data.IORef (newIORef, modifyIORef', readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Maybe (fromMaybe)
import Data.Time (UTCTime (..), fromGregorian)
import Network.HTTP.Types (status200, status400, status403, status404, status413, status500)
import Network.Wai
  ( Application, Request, defaultRequest, pathInfo, queryString
  , requestMethod, requestHeaders, responseHeaders, responseStatus
  , responseToStream )
import Network.Wai.Internal (Response (..), ResponseReceived (..))
import System.Directory (createDirectoryIfMissing, createFileLink)
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
import Seal.TestHelpers.ApiTestHarness (noOllamaReadiness)
import Seal.Cron.Store (CronStore (..))

stubCronStore :: CronStore
stubCronStore = CronStore
  { csCreate    = \_ -> error "cron store stub: csCreate"
  , csRead      = \_ -> error "cron store stub: csRead"
  , csList      = \_ -> error "cron store stub: csList"
  , csSave      = \_ -> error "cron store stub: csSave"
  , csDelete    = \_ -> error "cron store stub: csDelete"
  , csRecordRun = \_ _ -> error "cron store stub: csRecordRun"
  , csListRuns  = \_ _ -> error "cron store stub: csListRuns"
  , csUpdateRun = \_ _ -> error "cron store stub: csUpdateRun"
  , csLock = error "cron store stub: csLock"
  }

spec :: Spec
spec = describe "Seal.Gateway.ApiFilesSpec" $ do
  describe "GET /api/files" $ do
    it "returns 200 with a directory listing for a valid path" $ do
      withSystemTempDirectory "seal-files-test" $ \tmp -> do
        createDirectoryIfMissing True (tmp </> "subdir")
        TIO.writeFile (tmp </> "hello.txt") "hello world"
        let fe = mkLocalFileExplorer 131072 131072
        deps <- mkDeps fe True
        resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files"] [("path", Just (T.pack tmp))])
        responseStatus resp `shouldBe` status200

    it "returns rail listings when `paths` is supplied" $ do
      withSystemTempDirectory "seal-files-batch" $ \tmp -> do
        createDirectoryIfMissing True (tmp </> "a")
        createDirectoryIfMissing True (tmp </> "b")
        TIO.writeFile (tmp </> "a" </> "one.txt") "1"
        TIO.writeFile (tmp </> "b" </> "two.txt") "22"
        let fe = mkLocalFileExplorer 131072 131072
        deps <- mkDeps fe True
        resp <- runAppResp (apiApp deps)
          (mkGetReq ["api", "files"]
            [ ("path", Just (T.pack tmp))
            , ("paths", Just (T.pack (tmp </> "a")))
            , ("paths", Just (T.pack (tmp </> "b")))
            ])
        responseStatus resp `shouldBe` status200
        body <- responseBodyText resp
        -- both rail listings are present, in request order
        body `shouldSatisfy` T.isInfixOf "\"rail\""
        body `shouldSatisfy` T.isInfixOf "one.txt"
        body `shouldSatisfy` T.isInfixOf "two.txt"

    it "omits `rail` when `paths` is absent" $ do
      withSystemTempDirectory "seal-files-nobatch" $ \tmp -> do
        let fe = mkLocalFileExplorer 131072 131072
        deps <- mkDeps fe True
        resp <- runAppResp (apiApp deps)
          (mkGetReq ["api", "files"] [("path", Just (T.pack tmp))])
        body <- responseBodyText resp
        body `shouldSatisfy` (not . T.isInfixOf "\"rail\"")

    it "returns 403 when file explorer is disabled" $ do
      deps <- mkDeps mkFailClosedFileExplorer False
      resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files"] [("path", Just "/tmp")])
      responseStatus resp `shouldBe` status403

    it "returns 400 when path is empty" $ do
      deps <- mkDeps (mkLocalFileExplorer 131072 131072) True
      resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files"] [("path", Just "")])
      responseStatus resp `shouldBe` status400

    it "returns 404 for a non-existent path" $ do
      deps <- mkDeps (mkLocalFileExplorer 131072 131072) True
      resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files"] [("path", Just "/nonexistent/path/that/does/not/exist")])
      responseStatus resp `shouldBe` status404

    it "returns 200 when path is absent (defaults to feResolveHome)" $ do
      withSystemTempDirectory "seal-files-test" $ \tmp -> do
        createDirectoryIfMissing True (tmp </> "subdir")
        let fe = (mkLocalFileExplorer 131072 131072) { feResolveHome = pure (Right tmp) }
        deps <- mkDeps fe True
        resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files"] [])
        responseStatus resp `shouldBe` status200

    it "returns 500 (not 400) when feResolveHome fails with FeExec" $ do
      let fe = (mkLocalFileExplorer 131072 131072) { feResolveHome = pure (Left (FeExec "SSH unreachable")) }
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
        let fe = mkLocalFileExplorer 131072 131072
        deps <- mkDeps fe True
        resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files", "content"] [("path", Just (T.pack (tmp </> "test.txt")))])
        responseStatus resp `shouldBe` status200

    it "returns 403 when file explorer is disabled" $ do
      deps <- mkDeps mkFailClosedFileExplorer False
      resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files", "content"] [("path", Just "/tmp/test.txt")])
      responseStatus resp `shouldBe` status403

    it "returns 400 when path is empty" $ do
      deps <- mkDeps (mkLocalFileExplorer 131072 131072) True
      resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files", "content"] [("path", Just "")])
      responseStatus resp `shouldBe` status400

    it "returns 404 for a non-existent file" $ do
      deps <- mkDeps (mkLocalFileExplorer 131072 131072) True
      resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files", "content"] [("path", Just "/nonexistent/file.txt")])
      responseStatus resp `shouldBe` status404

  describe "GET /api/files/download" $ do
    it "returns 200 with octet-stream and Content-Disposition for a valid file" $ do
      withSystemTempDirectory "seal-files-test" $ \tmp -> do
        TIO.writeFile (tmp </> "data.bin") "binary data here"
        let fe = mkLocalFileExplorer 131072 131072
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
      deps <- mkDeps (mkLocalFileExplorer 131072 131072) True
      resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files", "download"] [("path", Just "")])
      responseStatus resp `shouldBe` status400

    it "returns 404 for a non-existent file" $ do
      deps <- mkDeps (mkLocalFileExplorer 131072 131072) True
      resp <- runAppResp (apiApp deps) (mkGetReq ["api", "files", "download"] [("path", Just "/nonexistent/file.bin")])
      responseStatus resp `shouldBe` status404

  -- Inline image preview: `inline=1` on the download route swaps the
  -- hardened octet-stream contract for a renderable Content-Type, gated by
  -- the MediaType allowlist and a size ceiling.
  describe "GET /api/files/download?inline=1" $ do
    it "serves a PNG with a real Content-Type and inline disposition" $
      withSystemTempDirectory "seal-inline" $ \tmp -> do
        let p = tmp </> "photo.png"
            payload = BC.pack "\137PNG\r\n\26\n-fake-png-body"
        BC.writeFile p payload
        deps <- mkDeps (mkLocalFileExplorer 131072 4194304) True
        resp <- runAppResp (apiApp deps)
                  (mkGetReq ["api", "files", "download"]
                    [("path", Just (T.pack p)), ("inline", Just "1")])
        responseStatus resp `shouldBe` status200
        let hdrs = responseHeaders resp
        -- The whole point: a type the browser will decode as an image.
        lookup "Content-Type" hdrs `shouldBe` Just "image/png"
        -- Still nosniff: our declared type wins over content sniffing.
        lookup "X-Content-Type-Options" hdrs `shouldBe` Just "nosniff"
        -- inline, not attachment, so <img> renders rather than downloads.
        lookup "Content-Disposition" hdrs `shouldBe` Just "inline; filename=\"photo.png\""
        body <- responseBodyStrict resp
        body `shouldBe` payload

    it "serves the FULL file, past the 128 KiB viewer ceiling" $
      withSystemTempDirectory "seal-inline-big" $ \tmp -> do
        -- A real photo is far larger than the viewer ceiling; the inline
        -- path must not truncate it into an undecodable fragment.
        let p = tmp </> "big.png"
            payload = BC.replicate 400000 'x'
        BC.writeFile p payload
        deps <- mkDeps (mkLocalFileExplorer 131072 4194304) True
        resp <- runAppResp (apiApp deps)
                  (mkGetReq ["api", "files", "download"]
                    [("path", Just (T.pack p)), ("inline", Just "1")])
        responseStatus resp `shouldBe` status200
        lookup "X-Truncated" (responseHeaders resp) `shouldBe` Nothing
        body <- responseBodyStrict resp
        BC.length body `shouldBe` 400000

    it "streams a preview across many bounded chunks with exact bytes" $
      withSystemTempDirectory "seal-inline-stream" $ \tmp -> do
        -- Force many chunks so the streaming loop's offset arithmetic is
        -- exercised. The bytes vary, so an overlap/duplication bug shows up
        -- as a content mismatch rather than merely a length mismatch.
        let p = tmp </> "big.png"
            payload = BC.pack
              [ toEnum (i `mod` 251) | i <- [0 .. 399999 :: Int] ]
        BC.writeFile p payload
        deps0 <- mkDeps (mkLocalFileExplorer 131072 4194304) True
        let deps = deps0 { adDownloadChunkBytes = 1000 }
        resp <- runAppResp (apiApp deps)
                  (mkGetReq ["api", "files", "download"]
                    [("path", Just (T.pack p)), ("inline", Just "1")])
        responseStatus resp `shouldBe` status200
        lookup "Content-Length" (responseHeaders resp)
          `shouldBe` Just (BC.pack (show (BC.length payload)))
        body <- responseBodyStrict resp
        body `shouldBe` payload

    it "refuses a file over the preview ceiling with 413, not a truncated image" $
      withSystemTempDirectory "seal-inline-huge" $ \tmp -> do
        let p = tmp </> "huge.png"
        BC.writeFile p (BC.replicate 200 'y')
        -- Explorer + deps wired with a tiny ceiling via a local override.
        deps0 <- mkDeps (mkLocalFileExplorer 131072 4194304) True
        let deps = deps0 { adMediaPreviewBytes = 100 }
        resp <- runAppResp (apiApp deps)
                  (mkGetReq ["api", "files", "download"]
                    [("path", Just (T.pack p)), ("inline", Just "1")])
        responseStatus resp `shouldBe` status413

    it "falls back to attachment for a non-allowlisted extension (HTML)" $
      withSystemTempDirectory "seal-inline-svg" $ \tmp -> do
        let p = tmp </> "page.html"
        BC.writeFile p "<html><script>alert(1)</script></html>"
        deps <- mkDeps (mkLocalFileExplorer 131072 4194304) True
        resp <- runAppResp (apiApp deps)
                  (mkGetReq ["api", "files", "download"]
                    [("path", Just (T.pack p)), ("inline", Just "1")])
        responseStatus resp `shouldBe` status200
        let hdrs = responseHeaders resp
        lookup "Content-Type" hdrs `shouldBe` Just "application/octet-stream"
        lookup "Content-Disposition" hdrs `shouldBe` Just "attachment; filename=\"page.html\""

    -- SVG is served inline (users want to see the drawing, not the markup),
    -- but ONLY with the hardening CSP. The file stays reachable as a
    -- document at this same URL; without the CSP, navigating there runs its
    -- script in the gateway's authenticated origin.
    it "serves an SVG inline as image/svg+xml" $
      withSystemTempDirectory "seal-inline-svg2" $ \tmp -> do
        let p = tmp </> "drawing.svg"
        BC.writeFile p "<svg xmlns='http://www.w3.org/2000/svg'/>"
        deps <- mkDeps (mkLocalFileExplorer 131072 4194304) True
        resp <- runAppResp (apiApp deps)
                  (mkGetReq ["api", "files", "download"]
                    [("path", Just (T.pack p)), ("inline", Just "1")])
        responseStatus resp `shouldBe` status200
        let hdrs = responseHeaders resp
        lookup "Content-Type" hdrs `shouldBe` Just "image/svg+xml"
        lookup "Content-Disposition" hdrs `shouldBe` Just "inline; filename=\"drawing.svg\""

    it "attaches the hardening CSP to an inline SVG" $
      withSystemTempDirectory "seal-inline-svg3" $ \tmp -> do
        let p = tmp </> "drawing.svg"
        BC.writeFile p "<svg xmlns='http://www.w3.org/2000/svg'/>"
        deps <- mkDeps (mkLocalFileExplorer 131072 4194304) True
        resp <- runAppResp (apiApp deps)
                  (mkGetReq ["api", "files", "download"]
                    [("path", Just (T.pack p)), ("inline", Just "1")])
        responseStatus resp `shouldBe` status200
        let csp = lookup "Content-Security-Policy" (responseHeaders resp)
        csp `shouldSatisfy` isJust
        let policy = fromMaybe "" csp
        -- The directives that stop document-mode script execution.
        policy `shouldSatisfy` BC.isInfixOf "sandbox"
        policy `shouldSatisfy` BC.isInfixOf "script-src 'none'"
        policy `shouldSatisfy` BC.isInfixOf "object-src 'none'"
        -- `allow-scripts` would defeat the sandbox entirely.
        policy `shouldNotSatisfy` BC.isInfixOf "allow-scripts"

    -- Raster images must NOT carry the SVG sandbox policy: it is
    -- unnecessary for a bitmap, and `sandbox` on an image response has no
    -- meaningful effect while widening the diff surface.
    it "does not attach the SVG CSP to a raster image" $
      withSystemTempDirectory "seal-inline-png-csp" $ \tmp -> do
        let p = tmp </> "photo.png"
        BC.writeFile p "pngbytes"
        deps <- mkDeps (mkLocalFileExplorer 131072 4194304) True
        resp <- runAppResp (apiApp deps)
                  (mkGetReq ["api", "files", "download"]
                    [("path", Just (T.pack p)), ("inline", Just "1")])
        responseStatus resp `shouldBe` status200
        lookup "Content-Security-Policy" (responseHeaders resp) `shouldBe` Nothing

    it "leaves the default (no inline) contract untouched" $
      withSystemTempDirectory "seal-inline-default" $ \tmp -> do
        let p = tmp </> "photo.png"
        BC.writeFile p "pngbytes"
        deps <- mkDeps (mkLocalFileExplorer 131072 4194304) True
        resp <- runAppResp (apiApp deps)
                  (mkGetReq ["api", "files", "download"] [("path", Just (T.pack p))])
        responseStatus resp `shouldBe` status200
        let hdrs = responseHeaders resp
        lookup "Content-Type" hdrs `shouldBe` Just "application/octet-stream"
        lookup "Content-Disposition" hdrs `shouldBe` Just "attachment; filename=\"photo.png\""

    it "returns 403 when file explorer is disabled" $ do
      deps <- mkDeps mkFailClosedFileExplorer False
      resp <- runAppResp (apiApp deps)
                (mkGetReq ["api", "files", "download"]
                  [("path", Just "/tmp/x.png"), ("inline", Just "1")])
      responseStatus resp `shouldBe` status403

    it "returns 404 for a missing image" $ do
      deps <- mkDeps (mkLocalFileExplorer 131072 4194304) True
      resp <- runAppResp (apiApp deps)
                (mkGetReq ["api", "files", "download"]
                  [("path", Just "/nonexistent/x.png"), ("inline", Just "1")])
      responseStatus resp `shouldBe` status404

  -- The harness's per-session workdirs live under ~/.seal/cache/workdirs, so
  -- the SEC-B3 blocklist would otherwise make the operator's own agent output
  -- undownloadable. Downloads must be allowed there, while a symlink that
  -- resolves out of the workdir is still blocked.
  describe "workdirs-cache download exemption" $ do
    it "serves a stat for a file under <cache>/workdirs" $ do
      withSystemTempDirectory "seal-workdir-download" $ \tmp -> do
        let cacheRoot = tmp </> ".seal" </> "cache"
            workdir = cacheRoot </> "workdirs" </> "s1"
            file = workdir </> "out.bin"
        createDirectoryIfMissing True workdir
        TIO.writeFile file "workdir output"
        deps <- mkDepsWithCache cacheRoot (mkLocalFileExplorer 131072 131072) True
        resp <- runAppResp (apiApp deps)
          (mkGetReq ["api", "files", "stat"] [("path", Just (T.pack file))])
        responseStatus resp `shouldBe` status200

    it "serves a manifest for a file under <cache>/workdirs" $ do
      withSystemTempDirectory "seal-workdir-download" $ \tmp -> do
        let cacheRoot = tmp </> ".seal" </> "cache"
            workdir = cacheRoot </> "workdirs" </> "s1"
            file = workdir </> "out.bin"
        createDirectoryIfMissing True workdir
        TIO.writeFile file "workdir output"
        deps <- mkDepsWithCache cacheRoot (mkLocalFileExplorer 131072 131072) True
        resp <- runAppResp (apiApp deps)
          (mkGetReq ["api", "files", "download", "manifest"] [("path", Just (T.pack file))])
        responseStatus resp `shouldBe` status200
        body <- responseBodyText resp
        body `shouldSatisfy` T.isInfixOf "\"chunkCount\""

    it "serves a chunk for a file under <cache>/workdirs" $ do
      withSystemTempDirectory "seal-workdir-download" $ \tmp -> do
        let cacheRoot = tmp </> ".seal" </> "cache"
            workdir = cacheRoot </> "workdirs" </> "s1"
            file = workdir </> "out.bin"
        createDirectoryIfMissing True workdir
        TIO.writeFile file "workdir output"
        deps <- mkDepsWithCache cacheRoot (mkLocalFileExplorer 131072 131072) True
        resp <- runAppResp (apiApp deps)
          (mkGetReq ["api", "files", "download", "chunk"]
            [ ("path", Just (T.pack file))
            , ("index", Just "0")
            , ("size", Just "14")
            ])
        responseStatus resp `shouldBe` status200
        lookup "X-Chunk-SHA256" (responseHeaders resp) `shouldSatisfy` isJust

    it "still blocks a blocked name outside the workdirs cache" $ do
      withSystemTempDirectory "seal-workdir-download" $ \tmp -> do
        let cacheRoot = tmp </> ".seal" </> "cache"
            file = tmp </> ".ssh" </> "id_rsa"
        createDirectoryIfMissing True (tmp </> ".ssh")
        TIO.writeFile file "secret"
        deps <- mkDepsWithCache cacheRoot (mkLocalFileExplorer 131072 131072) True
        resp <- runAppResp (apiApp deps)
          (mkGetReq ["api", "files", "download", "manifest"] [("path", Just (T.pack file))])
        responseStatus resp `shouldBe` status403

    it "still blocks a workdirs symlink that resolves into a blocked location" $ do
      withSystemTempDirectory "seal-workdir-download" $ \tmp -> do
        let cacheRoot = tmp </> ".seal" </> "cache"
            workdir = cacheRoot </> "workdirs" </> "s1"
            target = tmp </> ".ssh" </> "id_rsa"
            link = workdir </> "innocent-looking.bin"
        createDirectoryIfMissing True workdir
        createDirectoryIfMissing True (tmp </> ".ssh")
        TIO.writeFile target "secret"
        createFileLink target link
        deps <- mkDepsWithCache cacheRoot (mkLocalFileExplorer 131072 131072) True
        resp <- runAppResp (apiApp deps)
          (mkGetReq ["api", "files", "download", "manifest"] [("path", Just (T.pack link))])
        responseStatus resp `shouldBe` status403

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Build minimal ApiDeps for file explorer tests. Uses 'undefined' for
-- fields the file explorer routes never touch (the dispatch is a pure
-- pattern match on method + pathInfo before any field is read).
mkDeps :: FileExplorerHandle -> Bool -> IO ApiDeps
mkDeps = mkDepsWithCache "/tmp"

-- | Build deps with a specific @spCache@ so the workdirs-cache download
-- exemption can be exercised against a temp directory.
mkDepsWithCache :: FilePath -> FileExplorerHandle -> Bool -> IO ApiDeps
mkDepsWithCache cacheRoot fe enabled = do
  abortReg <- newSessionAbortRegistry
  let paths = SealPaths
        { spHome = "/tmp", spState = "/tmp", spConfig = "/tmp"
        , spKeys = "/tmp", spCache = cacheRoot
        }
      meta0 = SessionMeta
        (case mkSessionId "test" of Right s -> s; Left _ -> error "sid")
        "ollama" "llama3.2" "web" Nothing Nothing Nothing Nothing Nothing True Nothing Nothing Nothing
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
    , adOllamaReadiness = noOllamaReadiness
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
    , adCronStore = stubCronStore
    , adFileExplorer = fe
    , adFileExplorerEnabled = enabled
, adDownloadPromptBytes = 268435456
, adDownloadChunkBytes = 4194304
, adMediaPreviewBytes = 33554432
, adDownloadAllowBlocked = False
, adHttpManager = Nothing
, adIconCache = Nothing
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

-- | Read a 'Response' body as strict 'Text' for assertions. The file-explorer
-- handlers reply with 'responseLBS', so the body is always 'ResponseBuilder'.
responseBodyText :: Response -> IO Text
responseBodyText (ResponseBuilder _ _ builderBody) =
  decodeUtf8 . BL.toStrict <$> runBuilder builderBody
responseBodyText (ResponseRaw _ _) = pure ""
responseBodyText ResponseFile {} = pure ""
responseBodyText ResponseStream {} = pure ""

-- | Read a 'Response' body as strict 'ByteString' — needed by the image
-- preview tests, whose payloads are arbitrary bytes and must not be
-- round-tripped through 'Text'. Handles both builder responses and the
-- streamed inline-preview body.
responseBodyStrict :: Response -> IO BC.ByteString
responseBodyStrict resp = do
  let (_, _, withBody) = responseToStream resp
  withBody $ \body -> do
    chunks <- newIORef []
    body
      (\b -> modifyIORef' chunks (BL.toStrict (toLazyByteString b) :))
      (pure ())
    BC.concat . reverse <$> readIORef chunks

-- | Run a Builder into a lazy ByteString.
runBuilder :: Builder -> IO BL.ByteString
runBuilder b = pure (toLazyByteString b)

-- | Check that a Maybe is Just.
isJust :: Maybe a -> Bool
isJust Nothing = False
isJust (Just _) = True
