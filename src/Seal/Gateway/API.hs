{-# LANGUAGE OverloadedStrings #-}
-- | The REST API surface the SPA calls: sessions/tabs/agents/providers + send.
-- A manual WAI router (no servant/scotty dep) using @http-types@.
module Seal.Gateway.API
  ( apiApp
  , ApiDeps (..)
  ) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as A
import Data.ByteString.Char8 qualified as BC
import Data.CaseInsensitive qualified as CI
import Data.IORef (readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Types (Header, HeaderName, methodGet, methodOptions, status200, status404)
import Network.Wai (Application, Response, pathInfo, requestMethod, responseLBS)

import Seal.Core.Types (sessionIdText)
import Seal.Handles.Tab qualified
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..))
import Seal.Tabs (TabsHandle, snapshotTabs)
import Seal.Tabs.Types (tlTabs, Tab (..))

-- | The dependencies the API needs (injected so the test can supply fakes).
data ApiDeps = ApiDeps
  { adSessionRuntime :: SessionRuntime
  , adTabsHandle     :: TabsHandle
  }

-- | The REST API as a WAI Application.
apiApp :: ApiDeps -> Application
apiApp deps req respond =
  case (requestMethod req, pathInfo req) of
    (m', ["api", "health"]) | m' == methodGet -> do
      respond (jsonOk (object ["status" .= ("ok" :: Text)]))
    (m', ["api", "tabs"]) | m' == methodGet -> do
      tl <- snapshotTabs (adTabsHandle deps)
      let tabsJson = map tabToJson (tlTabs tl)
      respond (jsonOk (object ["tabs" .= tabsJson]))
    (m', ["api", "sessions"]) | m' == methodGet -> do
      active <- readIORef (srActive (adSessionRuntime deps))
      respond (jsonOk (object ["id" .= sessionIdText (smId active), "provider" .= smProvider active, "model" .= smModel active]))
    (m', _) | m' == methodOptions ->
      respond (responseLBS status200 corsHeaders "")
    _ -> respond (responseLBS status404 [("Content-Type", "application/json")] "{\"error\":\"not found\"}")

-- | One tab as JSON.
tabToJson :: Tab -> Value
tabToJson t = object
  [ "index" .= T.singleton (Seal.Handles.Tab.tabIndexToChar (tIndex t))
  , "kind" .= T.pack (show (tKind t))
  , "label" .= tLabel t
  ]

-- | A 200 OK with a JSON body + CORS headers.
jsonOk :: Value -> Response
jsonOk v = responseLBS status200 (corsHeaders <> [jsonHeader]) (A.encode v)

-- | CORS headers (echo an allowed Origin).
corsHeaders :: [Header]
corsHeaders =
  [ (mkHN "Access-Control-Allow-Origin", "*")
  , (mkHN "Access-Control-Allow-Methods", "GET, POST, OPTIONS")
  , (mkHN "Access-Control-Allow-Headers", "Content-Type")
  ]

jsonHeader :: Header
jsonHeader = (mkHN "Content-Type", "application/json")

-- | Make a HeaderName from a String.
mkHN :: String -> HeaderName
mkHN = CI.mk . BC.pack