{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
-- | Generate an OpenAPI 3.1 specification from the 'SealRoute' declarative
-- route spec (design §2.2 + Phase 4 — the §1a UC3 follow-up).
--
-- This module is pure: no 'IO', no 'ApiDeps'. It builds a
-- 'Data.OpenApi.OpenApi' document by feeding an OpenAPI-flavored 'Meta' table
-- (parallel to the runtime 'Seal.Gateway.Route.routeMeta') to
-- 'Trasa.OpenApi.toOpenApi'. Every path is prefixed with @\/api@ (matching the
-- gateway's @("api" : _) -> apiApp@ dispatch in 'Seal.Gateway.Server').
--
-- The handlers build JSON 'Value's directly (the 'Resp'/'Req' types are
-- opaque markers), so request and response bodies are typed as free-form JSON
-- objects for v1. The spec documents routes, methods, capture names, and media
-- types honestly without overpromising a typed body shape the handlers don't
-- yet enforce. High-value bodies can later get dedicated 'ToSchema' instances.
module Seal.Gateway.OpenApi
  ( sealOpenApi
  , encodeOpenApi
  , openApiMeta
  ) where

import Data.Aeson qualified as A
import Data.ByteString.Lazy (ByteString)
import Data.OpenApi (OpenApi (..), Info (..), ToSchema)
import Data.Text (Text)
import Trasa.Core
  ( Meta (..), Many, Path, Query, Rec
  , RequestBody, ResponseBody
  , match, end, capture, qend, bodyless, body, one, (./), resp )
import Trasa.OpenApi
import qualified Trasa.Method as M

import Seal.Gateway.Route
  ( SealRoute (..), allRoutes
  , SessionIdOrErr (..), AgentDefIdOrErr (..), SkillIdOrErr (..)
  , RepoIdOrErr (..), TabIndexOrErr (..), AskIdOrErr (..)
  , sessionIdCapture, agentDefIdCapture, skillIdCapture
  , repoIdCapture, tabIndexCapture, askIdCapture, textCapture
  , freeFormBodyCodec
  )

-- | The complete Seal Harness OpenAPI 3.1 document, generated from
-- 'allRoutes' + 'openApiMeta'. The 'Data.OpenApi.Info' is stamped with the
-- project title + version (the 'mempty' default has empty strings).
sealOpenApi :: OpenApi
sealOpenApi = baseDoc
  { _openApiInfo = (_openApiInfo baseDoc)
      { _infoTitle = "Seal Harness Gateway API"
      , _infoVersion = "0.1.0.0"
      } }
  where
    baseDoc = Trasa.OpenApi.toOpenApi openApiMeta allRoutes

-- | The OpenAPI document encoded as compact JSON. This is what
-- @seal gen-openapi@ writes to stdout and what @GET \/api\/openapi.json@ serves.
encodeOpenApi :: ByteString
encodeOpenApi = A.encode sealOpenApi

-- | The OpenAPI-flavored 'Meta' table — one arm per 'SealRoute' constructor.
-- Mirrors 'Seal.Gateway.Route.routeMeta' but:
--
--   * every path is prefixed with @match "api"@ (the gateway strips @\/api@
--     before dispatching to the manual router; the OpenAPI spec documents the
--     full path the client sees);
--   * captures use 'OpenApiCaptureCodec' (the existing 'CaptureCodec's wrapped
--     with the 'ToParamSchema' string schema);
--   * request/response bodies use 'Trasa.OpenApi.Codec.openApiJsonBody' (the
--     opaque 'Resp'/'Req'/'AnswerReq' types carry free-form JSON 'ToSchema'
--     instances defined in 'Seal.Gateway.Route'; 'Text' uses its native
--     schema).
openApiMeta :: SealRoute caps qrys req resp
            -> Meta OpenApiCaptureCodec OpenApiCaptureCodec
                     (Many OpenApiBodyCodec) (Many OpenApiBodyCodec)
                     caps qrys req resp
openApiMeta = \case
  RouteHealth -> api (match "health" ./ end) qend bodyless (resp (one openApiJsonBody)) M.get
  RouteTabsList -> api (match "tabs" ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteTabsNew -> api (match "tabs" ./ match "new" ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.post
  RouteTabsClose -> api (match "tabs" ./ capture oaTabIndex ./ match "close" ./ end) qend bodyless (resp (one ffBody)) M.post
  RouteTabsDismiss -> api (match "tabs" ./ capture oaTabIndex ./ match "dismiss" ./ end) qend bodyless (resp (one ffBody)) M.post
  RouteTabsAcknowledge -> api (match "tabs" ./ capture oaTabIndex ./ match "acknowledge" ./ end) qend bodyless (resp (one ffBody)) M.post
  RouteTabsRelease -> api (match "tabs" ./ capture oaTabIndex ./ match "release" ./ end) qend bodyless (resp (one ffBody)) M.post
  RouteTabsDestroy -> api (match "tabs" ./ capture oaTabIndex ./ match "destroy" ./ end) qend bodyless (resp (one ffBody)) M.post
  RouteLists -> api (match "lists" ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteSessionsList -> api (match "sessions" ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteSessionsArchived -> api (match "sessions" ./ match "archived" ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteSessionTranscript -> api (match "sessions" ./ capture oaSessionId ./ match "transcript" ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteSessionSend -> api (match "sessions" ./ capture oaSessionId ./ match "send" ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.post
  RouteSessionStop -> api (match "sessions" ./ capture oaSessionId ./ match "stop" ./ end) qend bodyless (resp (one ffBody)) M.post
  RouteSessionSetupRepo -> api (match "sessions" ./ capture oaSessionId ./ match "setup-repo" ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.post
  RouteSessionAgents -> api (match "sessions" ./ capture oaSessionId ./ match "agents" ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteSessionDescription -> api (match "sessions" ./ capture oaSessionId ./ match "description" ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.put
  RouteSessionArchived -> api (match "sessions" ./ capture oaSessionId ./ match "archived" ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.put
  RouteSessionPrompt -> api (match "sessions" ./ capture oaSessionId ./ match "prompt" ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.put
  RouteSessionAgent -> api (match "sessions" ./ capture oaSessionId ./ match "agent" ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.put
  RouteSessionQuestions -> api (match "sessions" ./ capture oaSessionId ./ match "questions" ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteSessionAnswer -> api (match "sessions" ./ capture oaSessionId ./ match "questions" ./ capture oaAskId ./ match "answer" ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.post
  RouteSessionAskCancel -> api (match "sessions" ./ capture oaSessionId ./ match "questions" ./ capture oaAskId ./ match "cancel" ./ end) qend bodyless (resp (one ffBody)) M.post
  RouteSessionNew -> api (match "sessions" ./ match "new" ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.post
  RouteSessionNewFrom -> api (match "sessions" ./ capture oaSessionId ./ match "new" ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.post
  RouteHarnesses -> api (match "harnesses" ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteHarnessDiscover -> api (match "harnesses" ./ match "discover" ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteAgentsList -> api (match "agents" ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteAgentDefaultGet -> api (match "agents" ./ match "default" ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteAgentDefaultPut -> api (match "agents" ./ match "default" ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.put
  RouteAgentGet -> api (match "agents" ./ capture oaAgentDefId ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteAgentCreate -> api (match "agents" ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.post
  RouteAgentUpdate -> api (match "agents" ./ capture oaAgentDefId ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.put
  RouteAgentDelete -> api (match "agents" ./ capture oaAgentDefId ./ end) qend bodyless (resp (one ffBody)) M.delete
  RouteSkillsList -> api (match "skills" ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteSkillGet -> api (match "skills" ./ capture oaSkillId ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteSkillCreate -> api (match "skills" ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.post
  RouteSkillUpdate -> api (match "skills" ./ capture oaSkillId ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.put
  RouteSkillDelete -> api (match "skills" ./ capture oaSkillId ./ end) qend bodyless (resp (one ffBody)) M.delete
  RouteReposList -> api (match "repos" ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteRepoCreate -> api (match "repos" ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.post
  RouteRepoGet -> api (match "repos" ./ capture oaRepoId ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteRepoUpdate -> api (match "repos" ./ capture oaRepoId ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.put
  RouteRepoDelete -> api (match "repos" ./ capture oaRepoId ./ end) qend bodyless (resp (one ffBody)) M.delete
  RouteRepoDeployKey -> api (match "repos" ./ capture oaRepoId ./ match "deploy-key" ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteRepoDeployKeyGenerate -> api (match "repos" ./ capture oaRepoId ./ match "deploy-key" ./ match "generate" ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.post
  RouteProvidersList -> api (match "providers" ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteProviderModels -> api (match "providers" ./ capture oaText ./ match "models" ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteProviderModelContext -> api (match "providers" ./ capture oaText ./ match "models" ./ capture oaText ./ match "context" ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteUiStateGet -> api (match "ui" ./ match "state" ./ end) qend bodyless (resp (one ffBody)) M.get
  RouteUiStatePut -> api (match "ui" ./ match "state" ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.put
  RouteUiCustomModels -> api (match "ui" ./ match "custom-models" ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.post
  RouteUiRepos -> api (match "ui" ./ match "repos" ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.post
  RouteAdopt -> api (match "adopt" ./ end) qend (body (one ffBody)) (resp (one ffBody)) M.post

-- | Prefix a path with @match "api"@ so the rendered OpenAPI paths include the
-- @\/api@ prefix the client sees (the gateway strips it before dispatching to
-- the manual router).
api
  :: Path OpenApiCaptureCodec caps
  -> Rec (Query OpenApiCaptureCodec) qrys
  -> RequestBody (Many OpenApiBodyCodec) req
  -> ResponseBody (Many OpenApiBodyCodec) resp
  -> M.Method
  -> Meta OpenApiCaptureCodec OpenApiCaptureCodec
           (Many OpenApiBodyCodec) (Many OpenApiBodyCodec)
           caps qrys req resp
api p = Meta (match "api" ./ p)

-- ---------------------------------------------------------------------------
-- OpenAPI-flavored capture codecs
-- ---------------------------------------------------------------------------

-- | Each capture codec wraps the existing 'CaptureCodec' from
-- 'Seal.Gateway.Route' with the 'ToParamSchema' string schema via
-- 'openApiCaptureCodec'.
oaSessionId :: OpenApiCaptureCodec SessionIdOrErr
oaSessionId = openApiCaptureCodec sessionIdCapture

oaAgentDefId :: OpenApiCaptureCodec AgentDefIdOrErr
oaAgentDefId = openApiCaptureCodec agentDefIdCapture

oaSkillId :: OpenApiCaptureCodec SkillIdOrErr
oaSkillId = openApiCaptureCodec skillIdCapture

oaRepoId :: OpenApiCaptureCodec RepoIdOrErr
oaRepoId = openApiCaptureCodec repoIdCapture

oaTabIndex :: OpenApiCaptureCodec TabIndexOrErr
oaTabIndex = openApiCaptureCodec tabIndexCapture

oaAskId :: OpenApiCaptureCodec AskIdOrErr
oaAskId = openApiCaptureCodec askIdCapture

oaText :: OpenApiCaptureCodec Text
oaText = openApiCaptureCodec textCapture

-- | The free-form JSON body codec for the opaque marker types ('Resp', 'Req',
-- 'AnswerReq'). Wraps 'Seal.Gateway.Route.freeFormBodyCodec' (a dummy
-- 'BodyCodec' whose encode/decode are never called) with the 'ToSchema'
-- free-form object schema via 'openApiBodyCodec'. Each route arm specializes
-- the polymorphic type to its own response/request type.
ffBody :: ToSchema a => OpenApiBodyCodec a
ffBody = openApiBodyCodec freeFormBodyCodec