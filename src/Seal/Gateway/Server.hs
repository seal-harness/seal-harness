{-# LANGUAGE OverloadedStrings #-}
-- | The assembled Warp application: the REST API routes + static file
-- serving with SPA fallback + the non-loopback bind warning. The WS stream
-- server runs separately (on @gcWsPort@) via 'Seal.Gateway.Stream'.
module Seal.Gateway.Server
  ( gatewayApp
  , runGateway
  ) where

import Data.ByteString.Char8 qualified as BC
import Data.Text qualified as T
import Network.HTTP.Types (status200, status404)
import Network.Wai
  ( Application, pathInfo, responseFile, responseLBS )
import Network.Wai.Handler.Warp (run)
import System.Directory (doesFileExist)
import System.FilePath ((</>), takeExtension)
import System.IO (hPutStrLn, stderr)

import Seal.Gateway.API (apiApp, ApiDeps (..))
import Seal.Gateway.Config (GatewayConfig (..))

-- | The assembled WAI application: the REST API routes, then static file
-- serving with SPA fallback (if the static dir is configured).
gatewayApp :: ApiDeps -> Maybe FilePath -> Application
gatewayApp deps mStaticDir req respond =
  case pathInfo req of
    ("api" : _) -> apiApp deps req respond
    _ -> case mStaticDir of
      Nothing -> respond (responseLBS status404 [("Content-Type", "application/json")] "{\"error\":\"not found\"}")
      Just staticDir -> serveStatic staticDir req respond

-- | Serve a static file with SPA fallback (serve @index.html@ if the path
-- doesn't match a file).
serveStatic :: FilePath -> Application
serveStatic staticDir req respond = do
  let pathParts = map T.unpack (pathInfo req)
      filePath = staticDir </> case pathParts of
        [] -> "index.html"
        _ -> case xs of
          [p] -> p
          _ -> T.unpack (T.intercalate "/" (map T.pack xs))
      xs = pathParts
  exists <- doesFileExist filePath
  if exists
    then respond (responseFile status200 [("Content-Type", contentTypeFor (takeExtension filePath))] filePath Nothing)
    else respond (responseFile status200 [("Content-Type", "text/html")] (staticDir </> "index.html") Nothing)

-- | The content-type for a file extension.
contentTypeFor :: String -> BC.ByteString
contentTypeFor ext = case ext of
  ".html" -> "text/html"
  ".js"   -> "application/javascript"
  ".css"  -> "text/css"
  ".json" -> "application/json"
  ".svg"  -> "image/svg+xml"
  ".png"  -> "image/png"
  ".ico"  -> "image/x-icon"
  _       -> "application/octet-stream"

-- | Run the gateway. Prints a startup banner with the bind address + the
-- served static dir. When the host is non-loopback:
--   - If @failClosedOnNonLoopback@ is True (mode=remote), REFUSES to start
--     (design V6: a non-loopback gateway is a config-tamper surface — the
--     unauthenticated @updateRuntimeConfig@ caller is reachable by anything
--     that can reach the address).
--   - Otherwise, warns (the full slash-command surface is reachable).
runGateway :: GatewayConfig -> Bool -> ApiDeps -> IO ()
runGateway cfg failClosedOnNonLoopback deps = do
  let host = gcHost cfg
      port = gcPort cfg
  hPutStrLn stderr "Seal Harness gateway"
  hPutStrLn stderr ("  URL:      http://" <> T.unpack host <> ":" <> show port)
  if host /= "127.0.0.1" && host /= "::1" && host /= "localhost"
    then
      if failClosedOnNonLoopback
        then do
          hPutStrLn stderr ("ERROR: refusing to start gateway on non-loopback address " <> T.unpack host
                            <> " in remote-only mode — bind 127.0.0.1 or disable remote-only")
          pure ()  -- do NOT call run; exit without serving
        else do
          hPutStrLn stderr ("Warning: binding to " <> T.unpack host
                            <> " — the full slash-command surface is reachable by anything that can reach this address")
          let mStaticDir = fmap T.unpack (gcStaticDir cfg)
              app = gatewayApp deps mStaticDir
          run port app
    else do
      let mStaticDir = fmap T.unpack (gcStaticDir cfg)
          app = gatewayApp deps mStaticDir
      run port app