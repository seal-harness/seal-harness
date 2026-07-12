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
import Data.Maybe (fromMaybe)

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read (decimal)
import Network.HTTP.Types
  ( Header, HeaderName, Status, methodGet, methodOptions, methodPost, methodPut
  , status200, status204, status400, status403, status404, status500, status501 )
import Network.Wai
  ( Application, Request, Response, getRequestBodyChunk, pathInfo
  , requestMethod, responseLBS )

import Seal.Agent.Def.Backend (AgentDefBackend (..))
import Seal.Agent.Def.Types (AgentDef (..), AgentDefId, agentDefIdText, mkAgentDefId)
import Seal.Config.Paths (SealPaths)
import Seal.Core.Types (SessionId (..), mkSessionId, sessionIdText)
import Seal.Gateway.Send
  ( SendDeps (..), handleSend, sendOutcomeJson )
import Seal.Gateway.Transcript (firstUserMessageSnippet, readTranscriptEntries, showIso)
import Seal.Handles.Tab (TabIndex, TabKind (..), mkTabIndex, tabIndexToInt)
import Seal.Harness.Id (newHarnessId)
import Seal.Harness.Registry (HarnessRegistry, snapshot)
import Seal.Providers.ContextWindow (modelContextWindow, modelMaxOutputTokens)
import Seal.Providers.Registry
  ( KnownProvider (..), parseProvider, providerLabel )
import Seal.Security.Adoption
  (AdoptError (..), ConsentChannel, authorizeAdoption)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), listSessions, newSession)
import Seal.Tabs (TabsHandle, insertTabH, removeTabH, snapshotTabs)
import Seal.Tabs.Types (Tab (..), TabRef (..), TabStatus (..), tlTabs)
import Seal.Web.UiState
  ( LastOptions (..), UiState (..), UiStateHandle
  , addCustomModel, getUiState, setLastOptions )

-- | The dependencies the API needs (injected so the test can supply fakes).
data ApiDeps = ApiDeps
  { adSessionRuntime  :: SessionRuntime
  , adTabsHandle      :: TabsHandle
  , adHarnessRegistry :: HarnessRegistry    -- ^ the live harness registry
  , adAdoptConsent    :: Maybe ConsentChannel  -- ^ 'Just CcWeb' for the web gateway; 'Nothing' headless
  , adAgentDefs       :: AgentDefBackend      -- ^ for /api/agents (T11)
  , adProviders       :: IO [KnownProvider]   -- ^ for /api/providers; an action that yields the *configured* provider list (T11)
  , adUiState         :: UiStateHandle        -- ^ for /api/ui/state + /api/ui/custom-models (persisted UI recall)
  , adSend            :: Maybe SendDeps       -- ^ the agent-loop plumbing for POST /send; Nothing = stub responses (tests)
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
    -- T11: GET /api/sessions -> the recent, non-archived sessions. The
    -- backend does not persist an @archived@ flag on 'SessionMeta' yet, so
    -- this returns ALL sessions; @/api/sessions/archived@ returns @[]@ (the
    -- archive flag is a UI hint the backend doesn't track yet).
    (m', ["api", "sessions"]) | m' == methodGet -> do
      metas <- listSessions (srPaths (adSessionRuntime deps))
      infos <- mapM (sessionInfoJsonWithSnippet (srPaths (adSessionRuntime deps))) metas
      respond (jsonLBS status200 (A.encode infos))
    -- T11: archived sessions — the backend doesn't persist an archive flag,
    -- so this is always @[]@ for now.
    (m', ["api", "sessions", "archived"]) | m' == methodGet ->
      respond (jsonLBS status200 (A.encode ([] :: [Value])))
    -- T11: GET /api/sessions/:id/transcript -> the parsed @entries.jsonl@
    -- lines, as a JSON array. Missing file -> @[]@; unparseable lines are
    -- skipped.
    (m', ["api", "sessions", sid, "transcript"]) | m' == methodGet ->
      respond =<< handleTranscript deps sid
    -- POST /api/sessions/:id/send. When the agent-loop plumbing is wired
    -- ('adSend' = 'Just'), route the message through the real agent loop
    -- (slash registry vs plain turn) and return the outcome. When 'adSend'
    -- is 'Nothing' (tests without the full runtime), fall back to the stub
    -- response so the contract is preserved.
    (m', ["api", "sessions", sid, "send"]) | m' == methodPost -> do
      body <- collectBody req
      case adSend deps of
        Nothing -> respond (jsonOk (object ["kind" .= ("assistant" :: Text)]))
        Just sendDeps -> do
          let msg = parseSendMessage body
          case mkSessionId sid of
            Left e   -> respond (errJson status400 ("invalid session id: " <> e))
            Right sId -> do
              outcome <- handleSend sendDeps sId msg
              let (code, val) = sendOutcomeJson outcome
              respond (jsonLBS (statusFromInt code) (A.encode val))
    -- T11 STUB: PUT /api/sessions/:id/description — 204 (no persistence yet;
    -- 'SessionMeta' has no description field).
    (m', ["api", "sessions", _sid, "description"]) | m' == methodPut -> do
      _body <- collectBody req
      respond noContent
    -- T11 STUB: PUT /api/sessions/:id/archived — 204 (no persistence yet).
    (m', ["api", "sessions", _sid, "archived"]) | m' == methodPut -> do
      _body <- collectBody req
      respond noContent
    -- T11 STUB: PUT /api/sessions/:id/prompt — 204 (no persistence yet).
    (m', ["api", "sessions", _sid, "prompt"]) | m' == methodPut -> do
      _body <- collectBody req
      respond noContent
    (m', ["api", "harnesses"]) | m' == methodGet -> do
      entries <- snapshot (adHarnessRegistry deps)
      respond (jsonLBS status200 (A.encode entries))
    (m', ["api", "harnesses", "discover"]) | m' == methodGet ->
      respond (jsonLBS status200 (A.encode ([] :: [Value])))
    -- T11: GET /api/agents -> the agent defs. @isDefault@ is a UI
    -- convenience; 'ApiDeps' doesn't carry the configured default agent id,
    -- so T11 returns @isDefault: false@ for all.
    (m', ["api", "agents"]) | m' == methodGet -> do
      defs <- adbList (adAgentDefs deps)
      respond (jsonLBS status200 (A.encode (map agentInfoJson defs)))
    -- T11: GET /api/providers -> the configured provider list. @isDefault@
    -- and @defaultModel@ are UI conveniences not threaded into 'ApiDeps' for
    -- T11, so only @name@ is emitted.
    (m', ["api", "providers"]) | m' == methodGet -> do
      providers <- adProviders deps
      respond (jsonLBS status200 (A.encode (map providerInfoJson providers)))
    -- T11: GET /api/providers/:p/models -> a STATIC list of models for the
    -- provider (the real /v1/models upstream call needs vault credentials +
    -- a live HTTP request and is out of scope). Context windows come from
    -- 'Seal.Providers.ContextWindow'.
    (m', ["api", "providers", p, "models"]) | m' == methodGet ->
      respond (jsonLBS status200 (A.encode (providerModelsJson p)))
    -- T11: GET /api/providers/:p/models/:m/context -> the context-window +
    -- max-output-tokens for the model (from 'Seal.Providers.ContextWindow').
    (m', ["api", "providers", _p, "models", m, "context"]) | m' == methodGet ->
      respond (jsonOk (object
        [ "contextWindow" .= modelContextWindow m
        , "maxOutputTokens" .= modelMaxOutputTokens m
        ]))
    -- GET /api/ui/state -> the persisted last-chosen "new tab" options and
    -- the custom-model id history. The frontend loads this on mount so the
    -- form opens with the last-used selection; the custom-model combobox
    -- is populated from the history list.
    (m', ["api", "ui", "state"]) | m' == methodGet -> do
      st <- getUiState (adUiState deps)
      respond (jsonLBS status200 (A.encode (uiStateJson st)))
    -- PUT /api/ui/state -> replace the last-chosen options. The body is the
    -- `last_options` object (the frontend's NewTabSpec shape). Custom-model
    -- history is NOT touched here (it's append-only via /api/ui/custom-models).
    (m', ["api", "ui", "state"]) | m' == methodPut -> do
      body <- collectBody req
      case A.decode body :: Maybe A.Value of
        Just v  -> respond =<< handleUiStatePut deps v
        Nothing -> respond (errJson status400 "invalid JSON body")
    -- POST /api/ui/custom-models -> add a custom model id to the persisted
    -- history. Body: { "model": "<id>" }. Idempotent + deduped + capped.
    (m', ["api", "ui", "custom-models"]) | m' == methodPost -> do
      body <- collectBody req
      case A.decode body :: Maybe A.Value of
        Just v  -> respond =<< handleUiCustomModelAdd deps v
        Nothing -> respond (errJson status400 "invalid JSON body")
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

-- | Parse the @message@ field from a POST /send body. Returns "" on a
-- missing/invalid body so the agent loop receives an empty turn (the routing
-- grammar treats empty input as 'Plain ""').
parseSendMessage :: BL.ByteString -> Text
parseSendMessage body =
  case A.decode body :: Maybe A.Value of
    Just (A.Object o) -> case KeyMap.lookup (Key.fromText "message") o of
      Just (A.String t) -> t
      _                 -> ""
    _ -> ""

-- | Map an integer HTTP status code to a 'Status'. The send outcome carries
-- an Int (so 'Seal.Gateway.Send' doesn't depend on @http-types@); this
-- rehydrates it. Unknown codes fall back to 500.
statusFromInt :: Int -> Status
statusFromInt 200 = status200
statusFromInt 400 = status400
statusFromInt 404 = status404
statusFromInt 500 = status500
statusFromInt _   = status500

-- | Parse the @kind@ field from a JSON body.
parseKind :: A.Value -> Maybe Text
parseKind (A.Object o) = case KeyMap.lookup (Key.fromText "kind") o of
  Just (A.String k) -> Just k
  _                 -> Nothing
parseKind _ = Nothing

-- | Parse the @provider@ and @model@ fields from a POST /api/tabs/new body.
-- Defaults to @("ollama", "llama3.2")@ when either is missing — the frontend
-- always sends both (the NewTabComposer preselects them), so the fallback is
-- purely defensive.
parseProviderModel :: A.Value -> (Text, Text)
parseProviderModel v = case v of
  A.Object o ->
    let lookupT k = case KeyMap.lookup (Key.fromText k) o of
          Just (A.String t) | not (T.null t) -> Just t
          _                                   -> Nothing
    in ( fromMaybe "ollama" (lookupT "provider")
       , fromMaybe "llama3.2" (lookupT "model") )
  _ -> ("ollama", "llama3.2")

-- | Parse the optional @agent@ field from a POST /api/tabs/new body into an
-- 'AgentDefId'. Returns 'Nothing' when absent/empty/invalid.
parseAgentField :: A.Value -> Maybe AgentDefId
parseAgentField (A.Object o) =
  case KeyMap.lookup (Key.fromText "agent") o of
    Just (A.String t) | not (T.null t) -> eitherToMaybe (mkAgentDefId t)
    _                                  -> Nothing
  where eitherToMaybe (Right x) = Just x
        eitherToMaybe (Left _)   = Nothing
parseAgentField _ = Nothing

-- | Handle POST /api/tabs/new.
handleTabNew :: ApiDeps -> A.Value -> IO Response
handleTabNew deps v =
  case parseKind v of
    Nothing       -> pure (errJson status400 "missing or invalid 'kind' field")
    Just "shell"  -> pure (errJson status501 "shell/ssh tabs require Phase 4 untrusted execution")
    Just "ssh"    -> pure (errJson status501 "shell/ssh tabs require Phase 4 untrusted execution")
    Just "attach" -> pure (errJson status501 "attach flow goes through /api/adopt")
    Just "provider" -> do
      -- Persist session.json so /send can resolve the provider+model. The
      -- provider/model default to the config defaults when the body omits
      -- them; the agent is bound when supplied. newSession mints its own
      -- session id; we bind the tab to THAT id (not a pre-minted one) so
      -- the tab and session.json agree.
      let paths = srPaths (adSessionRuntime deps)
          (provider, model) = parseProviderModel v
          mAgent = parseAgentField v
      meta <- newSession paths provider model "web" mAgent
      let sid = smId meta
      res <- insertTabH (adTabsHandle deps) (BoundSession sid) KindProvider Nothing
      pure (tabInsertResponse res (Just sid) "session:provider")
    Just "harness" -> do
      hid <- newHarnessId
      let label = parseHarnessLabel v
      res <- insertTabH (adTabsHandle deps) (BoundHarness hid) KindHarness label
      pure (tabInsertResponse res Nothing "harness")
    Just _ -> pure (errJson status400 "unknown 'kind' field")

-- | Encode the persisted 'UiState' for GET /api/ui/state. The shape mirrors
-- the on-disk JSON: an object with @last_options@ (the LastOptions record)
-- and @custom_models@ (a list of strings, most-recent first).
uiStateJson :: UiState -> Value
uiStateJson s = object
  [ "last_options"  .= usLastOptions s
  , "custom_models" .= usCustomModels s
  ]

-- | Handle PUT /api/ui/state. The body is the @last_options@ object (the
-- frontend's NewTabSpec shape). Decodes the `kind` field defensively (the
-- frontend always sends it); an invalid body yields a 400.
handleUiStatePut :: ApiDeps -> A.Value -> IO Response
handleUiStatePut deps v =
  case A.fromJSON v :: A.Result LastOptions of
    A.Success opts -> do
      setLastOptions (adUiState deps) opts
      pure (jsonOk (object ["ok" .= True]))
    A.Error err     -> pure (errJson status400 ("invalid last_options: " <> T.pack err))

-- | Handle POST /api/ui/custom-models. The body is @{"model":"<id>"}@. A
-- blank/missing model is a no-op success (the frontend shouldn't send one,
-- but the store is defensive).
handleUiCustomModelAdd :: ApiDeps -> A.Value -> IO Response
handleUiCustomModelAdd deps v = do
  let mModel = parseModelField v
  case mModel of
    Nothing -> pure (errJson status400 "missing 'model' field")
    Just m  -> do
      addCustomModel (adUiState deps) m
      pure (jsonOk (object ["ok" .= True]))

-- | Parse the @model@ field from a JSON body.
parseModelField :: A.Value -> Maybe Text
parseModelField (A.Object o) = case KeyMap.lookup (Key.fromText "model") o of
  Just (A.String t) -> Just t
  _                -> Nothing
parseModelField _ = Nothing

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

-- | Map a 'SessionMeta' to the frontend's 'SessionInfo' JSON shape
-- (camelCase). The on-disk 'SessionMeta' uses snake_case; the gateway maps
-- to the frontend's shape without changing 'SessionMeta's instance.
-- Fields the backend doesn't track yet (@description@, @autoSummary@,
-- @channelUserId@) are returned as @null@. @firstMessageSnippet@ is derived
-- from the session's transcript (the first user message), so a session
-- has a readable title before the user sets an explicit description.
sessionInfoJson :: Maybe Text -> SessionMeta -> Value
sessionInfoJson mSnippet m = object
  [ "id" .= sessionIdText (smId m)
  , "agent" .= (agentDefIdText <$> smAgent m)
  , "runtime" .= ("session:" <> smProvider m)
  , "model" .= smModel m
  , "lastActive" .= smLastActive m
  , "createdAt" .= smCreatedAt m
  , "description" .= (Nothing :: Maybe Text)
  , "autoSummary" .= (Nothing :: Maybe Text)
  , "firstMessageSnippet" .= mSnippet
  , "channel" .= smChannel m
  , "channelUserId" .= (Nothing :: Maybe Text)
  ]

-- | Build the 'SessionInfo' JSON for a session, reading the first user
-- message snippet from the transcript so the session has a default title
-- before the user sets an explicit description.
sessionInfoJsonWithSnippet :: SealPaths -> SessionMeta -> IO Value
sessionInfoJsonWithSnippet paths m = do
  mSnippet <- firstUserMessageSnippet paths (smId m)
  pure (sessionInfoJson mSnippet m)

-- | T11: handle GET /api/sessions/:id/transcript. Returns the session's
-- transcript as the frontend's @TranscriptEntry@ shape
-- (@id@/@timestamp@/@direction@/@payload@/@model@/@harness@/@raw@).
--
-- Two on-disk formats are supported:
--   1. The legacy @transcript.jsonl@ (one Haskell 'TranscriptEntry' per line,
--      @te*@-prefixed fields). Each line is mapped to the frontend shape.
--   2. The new two-file @conversation.jsonl@ (one 'Message' per line,
--      @msgRole@/@msgContent@). Each line is synthesized into a
--      @TranscriptEntry@-shaped JSON (User → request, Assistant → response);
--      timestamps/model are not available in this file so they're set to
--      the session's @smCreatedAt@/@smModel@ from @session.json@.
--
-- Missing files -> @[]@; unparseable lines are skipped.
handleTranscript :: ApiDeps -> Text -> IO Response
handleTranscript deps sidTxt =
  case mkSessionId sidTxt of
    Left _  -> pure (jsonLBS status200 (A.encode ([] :: [Value])))
    Right sid -> do
      let paths = srPaths (adSessionRuntime deps)
      active <- readIORef (srActive (adSessionRuntime deps))
      entries <- readTranscriptEntries paths (smModel active) (showIso (smCreatedAt active)) sid
      pure (jsonLBS status200 (A.encode entries))

-- | Map an 'AgentDef' to the frontend's 'AgentInfo' JSON shape. @isDefault@
-- is a UI convenience; T11 returns @false@ for all (the configured default
-- agent id is not threaded into 'ApiDeps').
agentInfoJson :: AgentDef -> Value
agentInfoJson d = object
  [ "name" .= adName d
  , "isDefault" .= False
  ]

-- | Map a 'KnownProvider' to the frontend's 'ProviderInfo' JSON shape. T11
-- emits only @name@; @isDefault@ / @defaultModel@ are UI conveniences not
-- threaded into 'ApiDeps' for T11.
providerInfoJson :: KnownProvider -> Value
providerInfoJson p = object ["name" .= providerLabel p]

-- | T11: the STATIC model list for a provider. The real @/v1/models@
-- upstream call needs vault credentials + a live HTTP request and is out of
-- scope. Unknown providers -> @[]@. Each model's @contextWindow@ comes from
-- 'Seal.Providers.ContextWindow'.
providerModelsJson :: Text -> [Value]
providerModelsJson pTxt =
  case parseProvider pTxt of
    Nothing -> []
    Just p  -> map (modelEntryJson p) (staticModelsFor p)

-- | The static model id list for a provider (T11 best-known table).
staticModelsFor :: KnownProvider -> [Text]
staticModelsFor AnthropicProvider =
  [ "claude-sonnet-4-20250514"
  , "claude-opus-4-8"
  , "claude-haiku-4-5"
  ]
staticModelsFor OllamaProvider = ["llama3.2", "llama3.1"]

-- | One model entry: @{name, contextWindow}@.
modelEntryJson :: KnownProvider -> Text -> Value
modelEntryJson _p mName = object
  [ "name" .= mName
  , "contextWindow" .= modelContextWindow mName
  ]

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
  , (mkHN "Access-Control-Allow-Methods", "GET, POST, PUT, OPTIONS")
  , (mkHN "Access-Control-Allow-Headers", "Content-Type")
  ]

jsonHeader :: Header
jsonHeader = (mkHN "Content-Type", "application/json")

-- | Make a HeaderName from a String.
mkHN :: String -> HeaderName
mkHN = CI.mk . BC.pack