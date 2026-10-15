{-# LANGUAGE OverloadedStrings #-}
-- | The assembled Warp application: the REST API routes + static file
-- serving with SPA fallback + the non-loopback bind warning. The WS stream
-- server runs separately (on @gcWsPort@) via 'Seal.Gateway.Stream'.
module Seal.Gateway.Server
  ( gatewayApp
  , requestTimingMiddleware
  , requestTimingMiddlewareWith
  , runGateway
  ) where

import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Char (toLower)
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import Katip (Severity (..), ls)
import Network.HTTP.Types (status200, status404)
import Network.HTTP.Types qualified as HT (statusCode)
import Network.HTTP.Types.Header (ResponseHeaders)
import Network.Wai
  ( Application, pathInfo, requestMethod, responseFile
  , responseLBS, responseStatus, Response )
import Network.Wai.Handler.Warp (run)
import System.Directory (doesFileExist)
import System.FilePath ((</>), takeExtension)

import Seal.Gateway.API (apiApp, ApiDeps (..))
import Seal.Gateway.Config (GatewayConfig (..))
import Seal.Gateway.Embedded (embeddedAssets)
import Seal.Logging.Logger (SealLogger, logIO)
import Seal.Security.Path
  ( PathError (..)
  , WorkspaceRoot (..)
  , getSafePath
  , mkSafePath
  )

-- | The assembled WAI application: the REST API routes, then static file
-- serving. When a @static_dir@ is configured, serves from disk (dev path);
-- otherwise falls back to the compile-time-embedded asset map (release
-- default). Each request is wrapped with 'requestTimingMiddleware' so the
-- method, path, status, and duration are logged via Katip for observability.
gatewayApp :: SealLogger -> ApiDeps -> Maybe FilePath -> Application
gatewayApp logger deps mStaticDir =
  requestTimingMiddleware logger $ \req respond ->
    case pathInfo req of
      ("api" : _) -> apiApp deps req respond
      _ -> case mStaticDir of
        Just staticDir -> serveStatic staticDir req respond
        Nothing        -> serveEmbedded req respond

-- | WAI middleware that logs each request's HTTP method, path, response
-- status, and total duration (in milliseconds) via the Katip 'SealLogger'.
requestTimingMiddleware :: SealLogger -> Application -> Application
requestTimingMiddleware logger = requestTimingMiddlewareWith (logIO logger InfoS . ls)

-- | Like 'requestTimingMiddleware' but with an injectable logger (for
-- tests).
requestTimingMiddlewareWith :: (String -> IO ()) -> Application -> Application
requestTimingMiddlewareWith logger innerApp req respond = do
  startTime <- getCurrentTime
  innerApp req $ \resp -> do
    endTime <- getCurrentTime
    let durationMs = floor (diffUTCTime endTime startTime * 1000) :: Int
        method = BC.unpack (requestMethod req)
        path = "/" <> T.unpack (T.intercalate "/" (pathInfo req))
        status = HT.statusCode (responseStatus resp)
    logger ("HTTP " <> method <> " " <> path <> " -> " <> show status <> " (" <> show durationMs <> "ms)")
    respond resp

-- | Serve from the compile-time-embedded asset map. Traversal is
-- structurally impossible (pure Map lookup, no filesystem involved).
-- SPA routes fall back to the embedded @index.html@; misses on
-- asset-like extensions 404 (so a bad asset URL never returns HTML).
-- When the map is empty (fresh checkout / pure nix build), returns a
-- helpful HTML page explaining the situation.
serveEmbedded :: Application
serveEmbedded req respond =
  let segs = pathInfo req
      key  = T.intercalate "/" segs
  in case Map.lookup (T.unpack key) embeddedAssets of
       Just bytes -> respond (embeddedResponse (T.unpack key) bytes)
       Nothing
         | isAssetPath segs -> respond notFoundResponse
         | Just idx <- Map.lookup "index.html" embeddedAssets ->
             respond (indexResponse idx)
         | otherwise -> respond emptyEmbedResponse

-- | Serve a static file from disk with SPA fallback. Routes through
-- 'mkSafePath' for traversal containment (lexical collapse +
-- canonicalizePath + symlink containment + blocked-name filtering).
-- The root path (@pathInfo = []@) is special-cased to serve @index.html@
-- directly, bypassing @mkSafePath@ (which would return the directory
-- itself). Asset-extension misses 404 instead of returning HTML.
serveStatic :: FilePath -> Application
serveStatic staticDir req respond = do
  let segs = pathInfo req
  case segs of
    [] -> respond (responseFile status200
                     (contentTypeHeader ".html" <> cacheHeadersFor "index.html" <> nosniffHeader)
                     (staticDir </> "index.html") Nothing)
    _  -> do
      let key = T.unpack (T.intercalate "/" segs)
      eSafe <- mkSafePath (WorkspaceRoot staticDir) key
      case eSafe of
        Left (PathEscapesWorkspace _) -> respond notFoundResponse
        Left (PathIsBlocked _)        -> respond notFoundResponse
        Left (PathInsecureMode _)     -> respond notFoundResponse
        Left (PathDoesNotExist _)
          | isAssetPath segs -> respond notFoundResponse
          | otherwise        -> respond (responseFile status200
                                          (contentTypeHeader ".html" <> cacheHeadersFor "index.html" <> nosniffHeader)
                                          (staticDir </> "index.html") Nothing)
        Right safePath -> do
          let fp = getSafePath safePath
          exists <- doesFileExist fp
          if exists
            then respond (responseFile status200
                           (contentTypeHeader (takeExtension fp) <> cacheHeadersFor key <> nosniffHeader)
                           fp Nothing)
            else respond notFoundResponse

-- | Build a 200 response for an embedded asset with MIME + cache + nosniff.
embeddedResponse :: FilePath -> BC.ByteString -> Network.Wai.Response
embeddedResponse key bytes =
  responseLBS status200
    (contentTypeHeader (takeExtension key) <> cacheHeadersFor key <> nosniffHeader)
    (LBS.fromStrict bytes)

-- | Build a 200 response for SPA fallback (index.html) with no-cache.
indexResponse :: BC.ByteString -> Network.Wai.Response
indexResponse bytes =
  responseLBS status200
    [("Content-Type", "text/html; charset=utf-8")
    ,("Cache-Control", "no-cache")
    ,("X-Content-Type-Options", "nosniff")]
    (LBS.fromStrict bytes)

-- | 404 for missing asset-like paths (prevents content-type confusion).
notFoundResponse :: Network.Wai.Response
notFoundResponse =
  responseLBS status404
    [("Content-Type", "text/plain")
    ,("Cache-Control", "no-cache")
    ,("X-Content-Type-Options", "nosniff")]
    "not found"

-- | Helpful HTML page when no assets are embedded (fresh checkout / nix).
emptyEmbedResponse :: Network.Wai.Response
emptyEmbedResponse =
  responseLBS status404
    [("Content-Type", "text/html; charset=utf-8")
    ,("Cache-Control", "no-cache")
    ,("X-Content-Type-Options", "nosniff")]
    "<html><body><h1>No UI embedded in this build</h1>\
    \<p>Run <code>make build</code> with the frontend built, or set\
    \[gateway] static_dir in config.toml.</p></body></html>"

-- | Content-Type header from a file extension (case-insensitive).
contentTypeHeader :: String -> ResponseHeaders
contentTypeHeader ext =
  [("Content-Type", contentTypeFor (map toLower ext))]

-- | Cache-Control headers per §4.4 policy: @assets\/@ prefix → immutable,
-- everything else (index.html, SPA fallback) → no-cache.
cacheHeadersFor :: FilePath -> ResponseHeaders
cacheHeadersFor key
  | "assets/" `isPrefixOf` key = [("Cache-Control", "public, max-age=31536000, immutable")]
  | otherwise                  = [("Cache-Control", "no-cache")]

-- | @X-Content-Type-Options: nosniff@ — prevents MIME-sniffing. Present
-- on ALL static responses in M1.
nosniffHeader :: ResponseHeaders
nosniffHeader = [("X-Content-Type-Options", "nosniff")]

-- | Whether the path looks like a static asset (has a known extension in
-- the final segment). EXCLUDES @.html@ so extensionless SPA routes
-- always fall back to @index.html@. Case-insensitive via 'T.toLower'.
isAssetPath :: [T.Text] -> Bool
isAssetPath segs = case segs of
  [] -> False
  _  -> let ext = T.toLower (T.pack (takeExtension (T.unpack (last segs))))
        in ext `elem` assetExtensions

-- | Pinned asset extension set (20 extensions, excludes @.html@).
assetExtensions :: [T.Text]
assetExtensions =
  [ ".js", ".mjs", ".css", ".map", ".json", ".txt", ".webmanifest"
  , ".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".svg", ".ico"
  , ".woff", ".woff2", ".ttf", ".otf", ".wasm"
  ]

-- | The content-type for a file extension (case-insensitive — caller
-- should lowercase the input via 'contentTypeHeader' or pre-normalize).
contentTypeFor :: String -> BC.ByteString
contentTypeFor ext = case ext of
  ".html"        -> "text/html; charset=utf-8"
  ".js"          -> "application/javascript"
  ".mjs"         -> "application/javascript"
  ".css"         -> "text/css"
  ".json"        -> "application/json"
  ".txt"         -> "text/plain"
  ".webmanifest" -> "application/manifest+json"
  ".svg"         -> "image/svg+xml"
  ".png"         -> "image/png"
  ".jpg"         -> "image/jpeg"
  ".jpeg"        -> "image/jpeg"
  ".gif"         -> "image/gif"
  ".webp"        -> "image/webp"
  ".avif"        -> "image/avif"
  ".ico"         -> "image/x-icon"
  ".woff"        -> "font/woff"
  ".woff2"       -> "font/woff2"
  ".ttf"         -> "font/ttf"
  ".otf"         -> "font/otf"
  ".wasm"        -> "application/wasm"
  _              -> "application/octet-stream"

-- | Run the gateway. Logs a startup banner with the bind address via the
-- Katip 'SealLogger'. When the host is non-loopback:
--   - If @failClosedOnNonLoopback@ is True (mode=remote), REFUSES to start.
--   - Otherwise, warns (the full slash-command surface is reachable).
runGateway :: SealLogger -> GatewayConfig -> Bool -> ApiDeps -> IO ()
runGateway logger cfg failClosedOnNonLoopback deps = do
  let host = gcHost cfg
      port = gcPort cfg
  logIO logger InfoS "Seal Harness gateway"
  logIO logger InfoS ("  URL:      http://" <> ls host <> ":" <> ls (show port))
  if host /= "127.0.0.1" && host /= "::1" && host /= "localhost"
    then
      if failClosedOnNonLoopback
        then do
          logIO logger ErrorS ("refusing to start gateway on non-loopback address " <> ls host
                               <> " in remote-only mode — bind 127.0.0.1 or disable remote-only")
          pure ()
        else do
          logIO logger WarningS ("binding to " <> ls host
                                 <> " — the full slash-command surface is reachable by anything that can reach this address")
          let mStaticDir = fmap T.unpack (gcStaticDir cfg)
              app = gatewayApp logger deps mStaticDir
          run port app
    else do
      let mStaticDir = fmap T.unpack (gcStaticDir cfg)
          app = gatewayApp logger deps mStaticDir
      run port app
