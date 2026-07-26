{-# LANGUAGE OverloadedStrings #-}
-- | Auto-setup for SearXNG: checks if a local instance is reachable,
-- and if not, starts one via Docker with JSON format enabled.
module Seal.Web.SearXngSetup
  ( ensureSearXng
  , searXngDefaultUrl
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client
  ( HttpException, Manager, httpLbs, parseRequest
  , responseStatus )
import Network.HTTP.Types (statusCode)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

searXngDefaultUrl :: Text
searXngDefaultUrl = "http://localhost:8888"

-- | Check if SearXNG is reachable at the given URL. Returns 'True' if
-- the instance responds with HTTP 200 on the @/search@ endpoint.
isSearXngRunning :: Manager -> Text -> IO Bool
isSearXngRunning mgr url = do
  eReq <- try (parseRequest (T.unpack (url <> "/search?q=test&format=json")))
  case eReq of
    Left (_ :: HttpException) -> pure False
    Right req -> do
      eResp <- try (httpLbs req mgr)
      case eResp of
        Left (_ :: HttpException) -> pure False
        Right resp -> pure (statusCode (responseStatus resp) == 200)

-- | Ensure a SearXNG instance is running. If the configured URL is the
-- default localhost:8888 and no instance is reachable, attempt to start
-- one via Docker. Returns 'True' if an instance is reachable after setup.
-- Returns 'False' if Docker is not available or the container fails to start.
ensureSearXng :: Manager -> Text -> IO Bool
ensureSearXng mgr url = do
  running <- isSearXngRunning mgr url
  if running
    then pure True
    else do
      if not (isLocalhost url)
        then pure False
        else tryDockerInstall
  where
    isLocalhost u = "localhost" `T.isInfixOf` u || "127.0.0.1" `T.isInfixOf` u

    tryDockerInstall :: IO Bool
    tryDockerInstall = do
      (exitCode, _, _) <- readProcessWithExitCode "docker" ["--version"] ""
      case exitCode of
        ExitFailure _ -> pure False
        ExitSuccess -> do
          (ec, out, _) <- readProcessWithExitCode "docker"
            ["ps", "-a", "-q", "--filter", "name=seal-harness-searxng"] ""
          case ec of
            ExitFailure _ -> pure False
            ExitSuccess ->
              if not (null (dropWhile (=='\n') out))
                then do
                  _ <- readProcessWithExitCode "docker"
                    ["start", "seal-harness-searxng"] ""
                  threadDelay 3000000  -- 3 seconds
                  isSearXngRunning mgr url
                else do
                  _ <- readProcessWithExitCode "docker"
                    ["pull", "searxng/searxng:latest"] ""
                  let dockerArgs =
                        [ "run", "-d"
                        , "--name", "seal-harness-searxng"
                        , "-p", "8888:8080"
                        , "-e", "SEARXNG_BASE_URL=http://localhost:8888/"
                        , "searxng/searxng:latest"
                        ]
                  (ec2, _, _) <- readProcessWithExitCode "docker" dockerArgs ""
                  case ec2 of
                    ExitFailure _ -> pure False
                    ExitSuccess -> do
                      threadDelay 5000000  -- 5 seconds
                      _ <- readProcessWithExitCode "docker"
                        ["exec", "seal-harness-searxng"
                        , "sh", "-c"
                        , "sed -i 's/formats: \\[html\\]/formats: [html, json]/' /etc/searxng/settings.yml || true"
                        ] ""
                      _ <- readProcessWithExitCode "docker"
                        ["restart", "seal-harness-searxng"] ""
                      threadDelay 3000000  -- 3 seconds
                      isSearXngRunning mgr url