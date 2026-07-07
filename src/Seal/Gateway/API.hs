{-# LANGUAGE OverloadedStrings #-}
-- | The REST API surface the SPA calls: sessions/tabs/agents/providers + send.
-- A manual WAI router (no servant/scotty dep) using @http-types@.
module Seal.Gateway.API
  ( apiApp
  , ApiDeps (..)
  ) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.CaseInsensitive qualified as CI
import Data.IORef (readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read (decimal)
import Network.HTTP.Types
  ( Header, HeaderName, Status, methodGet, methodOptions, methodPost
  , status200, status204, status400, status403, status404, status501 )
import Network.Wai
  ( Application, Request, Response, getRequestBodyChunk, pathInfo
  , requestMethod, responseLBS )

import Seal.Core.Types (SessionId (..), mkSessionId, sessionIdText)
import Seal.Handles.Tab (TabIndex, TabKind (..), mkTabIndex, tabIndexToInt)
import Seal.Harness.Id (HarnessId (..), newHarnessId)
import Seal.Harness.Registry (HarnessRegistry, snapshot)
import Seal.Security.Adoption
  (AdoptError (..), ConsentChannel, authorizeAdoption)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..))
import Seal.Tabs (TabsHandle, insertTabH, removeTabH, snapshotTabs)
import Seal.Tabs.Types (Tab (..), TabRef (..), TabStatus (..), tlTabs)

-- | The dependencies the API needs (injected so the test can supply fakes).
data ApiDeps = ApiDeps
  { adSessionRuntime  :: SessionRuntime
  , adTabsHandle      :: TabsHandle
  , adHarnessRegistry :: HarnessRegistry    -- ^ the live harness registry
  , adAdoptConsent    :: Maybe ConsentChannel  -- ^ 'Just CcWeb' for the web gateway; 'Nothing' headless
  }

-- | The REST API as a WAI Application.
apiApp :: ApiDeps -> Application
apiApp deps req respond =
  case (requestMethod req, pathInfo req) of
    (m', ["api", "health"]) | m' == methodGet ->
      respond (jsonOk (object ["status" .= ("ok" :: Text)]))
    (m', ["api", "tabs"]) | m' == methodGet -> do
      tl <- snapshotTabs (adTabsHandle deps)
      let tabsJson = map tabToJson (tlTabs tl)
      respond (jsonLBS status200 (A.encode tabsJson))
    (m', ["api", "sessions"]) | m' == methodGet -> do
      active <- readIORef (srActive (adSessionRuntime deps))
      respond (jsonOk (object ["id" .= sessionIdText (smId active), "provider" .= smProvider active, "model" .= smModel active]))
    (m', ["api", "harnesses"]) | m' == methodGet -> do
      entries <- snapshot (adHarnessRegistry deps)
      respond (jsonLBS status200 (A.encode entries))
    (m', ["api", "harnesses", "discover"]) | m' == methodGet ->
      respond (jsonLBS status200 (A.encode ([] :: [Value])))
    (m', ["api", "tabs", "new"]) | m' == methodPost -> do
      body <- collectBody req
      case A.decode body :: Maybe A.Value of
        Just v  -> respond =<< handleTabNew deps v
        Nothing -> respond (errJson status400 "invalid JSON body")
    (m', ["api", "tabs", idx, "close"]) | m' == methodPost ->
      respond =<< handleTabRemove deps idx
    (m', ["api", "tabs", idx, "dismiss"]) | m' == methodPost ->
      respond =<< handleTabRemove deps idx
    (m', ["api", "tabs", idx, "acknowledge"]) | m' == methodPost ->
      respond =<< handleTabAck deps idx
    (m', ["api", "tabs", idx, "release"]) | m' == methodPost ->
      respond =<< handleTabAck deps idx
    (m', ["api", "tabs", idx, "destroy"]) | m' == methodPost -> do
      body <- collectBody req
      respond =<< handleTabDestroy deps idx body
    (m', ["api", "adopt"]) | m' == methodPost -> do
      body <- collectBody req
      respond =<< handleAdopt deps body
    (m', _) | m' == methodOptions ->
      respond (responseLBS status200 corsHeaders "")
    _ -> respond (responseLBS status404 [("Content-Type", "application/json")] "{\"error\":\"not found\"}")

-- | Read the entire request body (collect chunks until empty).
collectBody :: Request -> IO BL.ByteString
collectBody req = go []
  where
    go acc = do
      chunk <- getRequestBodyChunk req
      if BC.null chunk
        then pure (BL.fromChunks (reverse acc))
        else go (chunk : acc)

-- | Parse the @kind@ field from a JSON body.
parseKind :: A.Value -> Maybe Text
parseKind (A.Object o) = case KeyMap.lookup (Key.fromText "kind") o of
  Just (A.String k) -> Just k
  _                 -> Nothing
parseKind _ = Nothing

-- | Handle POST /api/tabs/new.
handleTabNew :: ApiDeps -> A.Value -> IO Response
handleTabNew deps v =
  case parseKind v of
    Nothing       -> pure (errJson status400 "missing or invalid 'kind' field")
    Just "shell"  -> pure (errJson status501 "shell/ssh tabs require Phase 4 untrusted execution")
    Just "ssh"    -> pure (errJson status501 "shell/ssh tabs require Phase 4 untrusted execution")
    Just "attach" -> pure (errJson status501 "attach flow goes through /api/adopt")
    Just "provider" -> do
      sid <- mintSessionId
      res <- insertTabH (adTabsHandle deps) (BoundSession sid) KindProvider Nothing
      pure (tabInsertResponse res (Just sid) "session:provider")
    Just "harness" -> do
      hid <- newHarnessId
      let label = parseHarnessLabel v
      res <- insertTabH (adTabsHandle deps) (BoundHarness hid) KindHarness label
      pure (tabInsertResponse res Nothing "harness")
    Just _ -> pure (errJson status400 "unknown 'kind' field")

-- | Mint a fresh SessionId. The real session store is T11; for T10 we mint a
-- unique id derived from a fresh 'HarnessId' (UUID v4) suffix. The candidate
-- is built from the hex prefix of a UUID (chars in the allowed alphabet),
-- so 'mkSessionId' always succeeds; the fallback is a known-good constant.
mintSessionId :: IO SessionId
mintSessionId = do
  HarnessId t <- newHarnessId
  let candidate = "sess" <> T.take 8 t
  case mkSessionId candidate of
    Right s  -> pure s
    Left _e  -> case mkSessionId "sessfallback" of
                  Right s  -> pure s
                  Left _e2 -> pure (SessionId "sessfallback")  -- unreachable: literal is valid

-- | Parse the @harness_id@ field (the flavour-name or @custom:<binary>@
-- encoding) into the tab's label.
parseHarnessLabel :: A.Value -> Maybe Text
parseHarnessLabel (A.Object o) = case KeyMap.lookup (Key.fromText "harness_id") o of
  Just (A.String h) -> Just h
  _                 -> Nothing
parseHarnessLabel _ = Nothing

-- | Build the 200 response for a tab insert (Right idx) or a 400 error
-- (Left err). The body is the widened NewTabResponse.
tabInsertResponse :: Either Text TabIndex -> Maybe SessionId -> Text -> Response
tabInsertResponse (Left e) _ _ = errJson status400 e
tabInsertResponse (Right idx) mSid kind =
  jsonOk (object
    [ "tab_index" .= tabIndexToInt idx
    , "session_id" .= (sessionIdText <$> mSid)
    , "kind" .= kind
    ])

-- | Handle POST /api/tabs/:index/close + /dismiss (remove the tab).
handleTabRemove :: ApiDeps -> Text -> IO Response
handleTabRemove deps idxTxt =
  case parseIndex idxTxt of
    Nothing   -> pure (errJson status400 "invalid tab index")
    Just idx  -> do
      r <- removeTabH (adTabsHandle deps) idx
      case r of
        Left _  -> pure (errJson status404 "tab index out of range")
        Right _ -> pure noContent

-- | Handle POST /api/tabs/:index/acknowledge + /release (no-op for T10).
handleTabAck :: ApiDeps -> Text -> IO Response
handleTabAck _deps idxTxt =
  case parseIndex idxTxt of
    Nothing   -> pure (errJson status400 "invalid tab index")
    Just _idx -> pure noContent

-- | Handle POST /api/tabs/:index/destroy (remove + delete from registry if
-- harness; for T10 just remove).
handleTabDestroy :: ApiDeps -> Text -> BL.ByteString -> IO Response
handleTabDestroy deps idxTxt _body =
  case parseIndex idxTxt of
    Nothing   -> pure (errJson status400 "invalid tab index")
    Just idx  -> do
      r <- removeTabH (adTabsHandle deps) idx
      case r of
        Left _  -> pure (errJson status404 "tab index out of range")
        Right _ -> pure noContent

-- | Handle POST /api/adopt (consent-gated; the actual adoption wiring is
-- Phase 6a's domain).
handleAdopt :: ApiDeps -> BL.ByteString -> IO Response
handleAdopt deps body =
  case A.decode body :: Maybe A.Value of
    Nothing -> pure (errJson status400 "invalid JSON body")
    Just v  -> case parseConsent v of
      Nothing       -> pure (errJson status400 "consent_confirmed is required")
      Just consent  -> case authorizeAdoption (adAdoptConsent deps) consent of
        Left AeConsentMissing      -> pure (errJson status400 "consent_confirmed is required")
        Left AeHeadlessNoConsent   -> pure (errJson status403 "headless runs cannot confirm adoption consent")
        Left (AeAlreadyManaged _)  -> pure (errJson status403 "window already managed")
        Right ()                   -> pure (jsonOk (object ["ok" .= True, "session_id" .= (Nothing :: Maybe Text)]))

-- | Parse the @consent_confirmed@ field from a JSON body.
parseConsent :: A.Value -> Maybe Bool
parseConsent (A.Object o) = case KeyMap.lookup (Key.fromText "consent_confirmed") o of
  Just (A.Bool b) -> Just b
  _               -> Nothing
parseConsent _ = Nothing

-- | Parse a tab index from its text form (a non-negative integer).
parseIndex :: Text -> Maybe TabIndex
parseIndex t =
  case decimal t of
    Right (n, rest) | T.null rest, n >= 0 ->
      case mkTabIndex n of
        Right idx -> Just idx
        Left _    -> Nothing
    _ -> Nothing

-- | One tab as JSON (the widened TabInfoWire shape the frontend expects).
tabToJson :: Tab -> Value
tabToJson t = object
  [ "index" .= tabIndexToInt (tIndex t)
  , "kind" .= tabKindWire (tKind t)
  , "label" .= tLabel t
  , "status" .= statusWire (tKind t) (tStatus t)
  , "session_id" .= sessionWire (tRef t)
  , "ext_modified" .= False
  , "stale" .= False
  , "origin" .= (Nothing :: Maybe Text)
  , "attach_command" .= (Nothing :: Maybe Text)
  ]

-- | Map a 'TabKind' to the frontend's wire vocab.
tabKindWire :: TabKind -> Text
tabKindWire k = case k of
  KindHarness  -> "harness"
  KindProvider -> "session:provider"
  KindAi       -> "session:ai"
  KindShell    -> "shell"
  KindSsh      -> "shell:ssh"
  KindTmux     -> "tmux"

-- | Map ('TabKind', 'TabStatus') to the frontend's status vocab.
statusWire :: TabKind -> TabStatus -> Text
statusWire _ Dead = "exited"
statusWire KindHarness Live = "running"
statusWire _ Live = "idle"

-- | Derive the @session_id@ wire field from a 'TabRef'.
sessionWire :: TabRef -> Maybe Text
sessionWire (BoundSession sid) = Just (sessionIdText sid)
sessionWire (BoundHarness _)   = Nothing

-- | A 200 OK with a JSON body + CORS headers.
jsonOk :: Value -> Response
jsonOk v = jsonLBS status200 (A.encode v)

-- | A response with a raw JSON bytestring + CORS headers.
jsonLBS :: Status -> BL.ByteString -> Response
jsonLBS st = responseLBS st (corsHeaders <> [jsonHeader])

-- | A 204 No Content (no body).
noContent :: Response
noContent = responseLBS status204 corsHeaders ""

-- | A JSON error response with a status code.
errJson :: Status -> Text -> Response
errJson st msg = responseLBS st (corsHeaders <> [jsonHeader])
  (A.encode (object ["error" .= msg]))

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