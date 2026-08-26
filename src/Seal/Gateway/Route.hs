{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The declarative route spec for the Seal Harness REST API (design §4.2).
--
-- One 'SealRoute' constructor per route. The 'routeMeta' table maps each
-- constructor to its path shape + HTTP method + capture/body codecs. The
-- 'sealRouter' is the 'Trasa.Core.Router' built from 'allRoutes'.
--
-- This module is pure: no 'IO', no 'ApiDeps'. The handler functions live in
-- 'Seal.Gateway.API' and are dispatched by the wrapper there.
module Seal.Gateway.Route
  ( SealRoute (..)
  , routeMeta
  , allRoutes
  , sealRouter
  , Resp
  , Req
  , AnswerReq (..)
  , SessionIdOrErr (..)
  , AgentDefIdOrErr (..)
  , SkillIdOrErr (..)
  , RepoIdOrErr (..)
  , TabIndexOrErr (..)
  , AskIdOrErr (..)
  , sessionIdCapture
  , agentDefIdCapture
  , skillIdCapture
  , repoIdCapture
  , tabIndexCapture
  , askIdCapture
  , textCapture
  , freeFormBodyCodec
  ) where

import Control.Lens ((&), (?~))
import Data.ByteString.Lazy qualified as BL
import Data.Either (fromRight)
import Data.Kind (Type)
import Data.List.NonEmpty (NonEmpty (..))
import Data.OpenApi
  ( OpenApiType (..), OpenApiTypeValue (..), ToParamSchema (..), ToSchema (..)
  , AdditionalProperties (..), NamedSchema (..), Schema, type_, additionalProperties )
import Data.Text (Text)
import Trasa.Codec (BodyCodec (..))
import Trasa.Core
  ( Router, Meta (..), MetaCodec, CaptureCodec (..)
  , Bodiedness (..), Param
  , match, end, capture, qend, bodyless, body, one, (./), resp
  , routerWith, mapMeta, Constructed (..), captureCodecToCaptureDecoding )
import qualified Trasa.Method as M

-- | The response type for all JSON routes. The handler builds the full
-- 'Response' itself (the wrapper passes it verbatim); this type is just the
-- route's response type index. It carries no data — the actual JSON is
-- produced by the handler.
data Resp

-- | The request-body type for JSON-body routes. The wrapper parses the body
-- bytes itself (ignoring Content-Type) and hands them to the handler; this
-- type is just the route's request-body type index.
data Req

-- | The Seal Harness route GADT. One constructor per REST route. The type
-- parameters are: @caps@ (path captures), @qrys@ (query params, always @'[]@
-- here — all routes are queryless), @req@ (request body bodiedness), @resp@
-- (response type).
--
-- Captures use 'Text' for unvalidated captures and the validated capture
-- newtypes ('SessionIdOrErr', etc.) for validated ones. The handler
-- pattern-matches via the 'withSessionId' / 'withAgentDefId' / etc. helpers
-- (in 'Seal.Gateway.Route.Codec') to emit the exact legacy error messages.
data SealRoute :: [Type] -> [Param] -> Bodiedness -> Type -> Type where
  -- Health
  RouteHealth        :: SealRoute '[] '[] Bodyless Text
  -- Tabs
  RouteTabsList       :: SealRoute '[] '[] Bodyless Resp
  RouteTabsNew       :: SealRoute '[] '[] (Body Req) Resp
  RouteTabsClose     :: SealRoute '[TabIndexOrErr] '[] Bodyless Resp
  RouteTabsDismiss   :: SealRoute '[TabIndexOrErr] '[] Bodyless Resp
  RouteTabsAcknowledge :: SealRoute '[TabIndexOrErr] '[] Bodyless Resp
  RouteTabsRelease   :: SealRoute '[TabIndexOrErr] '[] Bodyless Resp
  RouteTabsDestroy   :: SealRoute '[TabIndexOrErr] '[] Bodyless Resp
  -- Lists
  RouteLists         :: SealRoute '[] '[] Bodyless Resp
  -- Sessions
  RouteSessionsList  :: SealRoute '[] '[] Bodyless Resp
  RouteSessionsArchived :: SealRoute '[] '[] Bodyless Resp
  RouteSessionTranscript :: SealRoute '[SessionIdOrErr] '[] Bodyless Resp
  RouteSessionSend   :: SealRoute '[SessionIdOrErr] '[] (Body Req) Resp
  RouteSessionStop   :: SealRoute '[SessionIdOrErr] '[] Bodyless Resp
  RouteSessionSetupRepo :: SealRoute '[SessionIdOrErr] '[] (Body Req) Resp
  RouteSessionAgents :: SealRoute '[SessionIdOrErr] '[] Bodyless Resp
  RouteSessionDescription :: SealRoute '[SessionIdOrErr] '[] (Body Req) Resp
  RouteSessionArchived :: SealRoute '[SessionIdOrErr] '[] (Body Req) Resp
  RouteSessionPrompt :: SealRoute '[SessionIdOrErr] '[] (Body Req) Resp
  RouteSessionAgent  :: SealRoute '[SessionIdOrErr] '[] (Body Req) Resp
  RouteSessionQuestions :: SealRoute '[SessionIdOrErr] '[] Bodyless Resp
  RouteSessionAnswer :: SealRoute '[SessionIdOrErr, AskIdOrErr] '[] (Body AnswerReq) Resp
  RouteSessionAskCancel :: SealRoute '[SessionIdOrErr, AskIdOrErr] '[] Bodyless Resp
  RouteSessionNew    :: SealRoute '[] '[] (Body Req) Resp
  RouteSessionNewFrom :: SealRoute '[SessionIdOrErr] '[] (Body Req) Resp
  -- Harnesses
  RouteHarnesses      :: SealRoute '[] '[] Bodyless Resp
  RouteHarnessDiscover :: SealRoute '[] '[] Bodyless Resp
  -- Agents
  RouteAgentsList    :: SealRoute '[] '[] Bodyless Resp
  RouteAgentDefaultGet :: SealRoute '[] '[] Bodyless Resp
  RouteAgentDefaultPut :: SealRoute '[] '[] (Body Req) Resp
  RouteAgentGet      :: SealRoute '[AgentDefIdOrErr] '[] Bodyless Resp
  RouteAgentCreate   :: SealRoute '[] '[] (Body Req) Resp
  RouteAgentUpdate   :: SealRoute '[AgentDefIdOrErr] '[] (Body Req) Resp
  RouteAgentDelete   :: SealRoute '[AgentDefIdOrErr] '[] Bodyless Resp
  -- Skills
  RouteSkillsList    :: SealRoute '[] '[] Bodyless Resp
  RouteSkillGet      :: SealRoute '[SkillIdOrErr] '[] Bodyless Resp
  RouteSkillCreate   :: SealRoute '[] '[] (Body Req) Resp
  RouteSkillUpdate   :: SealRoute '[SkillIdOrErr] '[] (Body Req) Resp
  RouteSkillDelete   :: SealRoute '[SkillIdOrErr] '[] Bodyless Resp
  -- Repos
  RouteReposList     :: SealRoute '[] '[] Bodyless Resp
  RouteRepoCreate    :: SealRoute '[] '[] (Body Req) Resp
  RouteRepoGet       :: SealRoute '[RepoIdOrErr] '[] Bodyless Resp
  RouteRepoUpdate    :: SealRoute '[RepoIdOrErr] '[] (Body Req) Resp
  RouteRepoDelete    :: SealRoute '[RepoIdOrErr] '[] Bodyless Resp
  RouteRepoDeployKey :: SealRoute '[RepoIdOrErr] '[] Bodyless Resp
  RouteRepoDeployKeyGenerate :: SealRoute '[RepoIdOrErr] '[] (Body Req) Resp
  -- Providers
  RouteProvidersList :: SealRoute '[] '[] Bodyless Resp
  RouteProviderModels :: SealRoute '[Text] '[] Bodyless Resp
  RouteProviderModelContext :: SealRoute '[Text, Text] '[] Bodyless Resp
  -- UI
  RouteUiStateGet    :: SealRoute '[] '[] Bodyless Resp
  RouteUiStatePut    :: SealRoute '[] '[] (Body Req) Resp
  RouteUiCustomModels :: SealRoute '[] '[] (Body Req) Resp
  RouteUiRepos       :: SealRoute '[] '[] (Body Req) Resp
  -- Adopt
  RouteAdopt         :: SealRoute '[] '[] (Body Req) Resp

-- | The 'Meta' table — one arm per 'SealRoute' constructor. Uses @./@ for
-- path building, @end@ for path termination, @capture@ for path captures.
-- All routes are queryless (@qend@). Body-bearing routes use @body (one
-- aesonBodyCodec)@; bodyless routes use @bodyless@.
routeMeta :: SealRoute caps qrys req resp -> MetaCodec caps qrys req resp
routeMeta = \case
  RouteHealth -> Meta (match "health" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteTabsList -> Meta (match "tabs" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteTabsNew -> Meta (match "tabs" ./ match "new" ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.post
  RouteTabsClose -> Meta (match "tabs" ./ capture tabIndexCapture ./ match "close" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.post
  RouteTabsDismiss -> Meta (match "tabs" ./ capture tabIndexCapture ./ match "dismiss" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.post
  RouteTabsAcknowledge -> Meta (match "tabs" ./ capture tabIndexCapture ./ match "acknowledge" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.post
  RouteTabsRelease -> Meta (match "tabs" ./ capture tabIndexCapture ./ match "release" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.post
  RouteTabsDestroy -> Meta (match "tabs" ./ capture tabIndexCapture ./ match "destroy" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.post
  RouteLists -> Meta (match "lists" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteSessionsList -> Meta (match "sessions" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteSessionsArchived -> Meta (match "sessions" ./ match "archived" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteSessionTranscript -> Meta (match "sessions" ./ capture sessionIdCapture ./ match "transcript" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteSessionSend -> Meta (match "sessions" ./ capture sessionIdCapture ./ match "send" ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.post
  RouteSessionStop -> Meta (match "sessions" ./ capture sessionIdCapture ./ match "stop" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.post
  RouteSessionSetupRepo -> Meta (match "sessions" ./ capture sessionIdCapture ./ match "setup-repo" ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.post
  RouteSessionAgents -> Meta (match "sessions" ./ capture sessionIdCapture ./ match "agents" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteSessionDescription -> Meta (match "sessions" ./ capture sessionIdCapture ./ match "description" ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.put
  RouteSessionArchived -> Meta (match "sessions" ./ capture sessionIdCapture ./ match "archived" ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.put
  RouteSessionPrompt -> Meta (match "sessions" ./ capture sessionIdCapture ./ match "prompt" ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.put
  RouteSessionAgent -> Meta (match "sessions" ./ capture sessionIdCapture ./ match "agent" ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.put
  RouteSessionQuestions -> Meta (match "sessions" ./ capture sessionIdCapture ./ match "questions" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteSessionAnswer -> Meta (match "sessions" ./ capture sessionIdCapture ./ match "questions" ./ capture askIdCapture ./ match "answer" ./ end) qend (body (one (error "answerReqCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.post
  RouteSessionAskCancel -> Meta (match "sessions" ./ capture sessionIdCapture ./ match "questions" ./ capture askIdCapture ./ match "cancel" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.post
  RouteSessionNew -> Meta (match "sessions" ./ match "new" ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.post
  RouteSessionNewFrom -> Meta (match "sessions" ./ capture sessionIdCapture ./ match "new" ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.post
  RouteHarnesses -> Meta (match "harnesses" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteHarnessDiscover -> Meta (match "harnesses" ./ match "discover" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteAgentsList -> Meta (match "agents" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteAgentDefaultGet -> Meta (match "agents" ./ match "default" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteAgentDefaultPut -> Meta (match "agents" ./ match "default" ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.put
  RouteAgentGet -> Meta (match "agents" ./ capture agentDefIdCapture ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteAgentCreate -> Meta (match "agents" ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.post
  RouteAgentUpdate -> Meta (match "agents" ./ capture agentDefIdCapture ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.put
  RouteAgentDelete -> Meta (match "agents" ./ capture agentDefIdCapture ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.delete
  RouteSkillsList -> Meta (match "skills" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteSkillGet -> Meta (match "skills" ./ capture skillIdCapture ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteSkillCreate -> Meta (match "skills" ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.post
  RouteSkillUpdate -> Meta (match "skills" ./ capture skillIdCapture ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.put
  RouteSkillDelete -> Meta (match "skills" ./ capture skillIdCapture ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.delete
  RouteReposList -> Meta (match "repos" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteRepoCreate -> Meta (match "repos" ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.post
  RouteRepoGet -> Meta (match "repos" ./ capture repoIdCapture ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteRepoUpdate -> Meta (match "repos" ./ capture repoIdCapture ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.put
  RouteRepoDelete -> Meta (match "repos" ./ capture repoIdCapture ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.delete
  RouteRepoDeployKey -> Meta (match "repos" ./ capture repoIdCapture ./ match "deploy-key" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteRepoDeployKeyGenerate -> Meta (match "repos" ./ capture repoIdCapture ./ match "deploy-key" ./ match "generate" ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.post
  RouteProvidersList -> Meta (match "providers" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteProviderModels -> Meta (match "providers" ./ capture textCapture ./ match "models" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteProviderModelContext -> Meta (match "providers" ./ capture textCapture ./ match "models" ./ capture textCapture ./ match "context" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteUiStateGet -> Meta (match "ui" ./ match "state" ./ end) qend bodyless (resp (one (error "respCodec: TODO"))) M.get
  RouteUiStatePut -> Meta (match "ui" ./ match "state" ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.put
  RouteUiCustomModels -> Meta (match "ui" ./ match "custom-models" ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.post
  RouteUiRepos -> Meta (match "ui" ./ match "repos" ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.post
  RouteAdopt -> Meta (match "adopt" ./ end) qend (body (one (error "aesonBodyCodec: TODO"))) (resp (one (error "respCodec: TODO"))) M.post

-- | All routes, listed as 'Constructed' values (existential 'SealRoute').
-- The order controls literal-vs-capture matching at the FIRST segment only
-- (trasa tries literal matches before captures at each segment).
allRoutes :: [Constructed SealRoute]
allRoutes =
  [ Constructed RouteHealth
  , Constructed RouteTabsList
  , Constructed RouteTabsNew
  , Constructed RouteTabsClose
  , Constructed RouteTabsDismiss
  , Constructed RouteTabsAcknowledge
  , Constructed RouteTabsRelease
  , Constructed RouteTabsDestroy
  , Constructed RouteLists
  , Constructed RouteSessionsList
  , Constructed RouteSessionsArchived
  , Constructed RouteSessionTranscript
  , Constructed RouteSessionSend
  , Constructed RouteSessionStop
  , Constructed RouteSessionSetupRepo
  , Constructed RouteSessionAgents
  , Constructed RouteSessionDescription
  , Constructed RouteSessionArchived
  , Constructed RouteSessionPrompt
  , Constructed RouteSessionAgent
  , Constructed RouteSessionQuestions
  , Constructed RouteSessionAnswer
  , Constructed RouteSessionAskCancel
  , Constructed RouteSessionNew
  , Constructed RouteSessionNewFrom
  , Constructed RouteHarnesses
  , Constructed RouteHarnessDiscover
  , Constructed RouteAgentsList
  , Constructed RouteAgentDefaultGet
  , Constructed RouteAgentDefaultPut
  , Constructed RouteAgentGet
  , Constructed RouteAgentCreate
  , Constructed RouteAgentUpdate
  , Constructed RouteAgentDelete
  , Constructed RouteSkillsList
  , Constructed RouteSkillGet
  , Constructed RouteSkillCreate
  , Constructed RouteSkillUpdate
  , Constructed RouteSkillDelete
  , Constructed RouteReposList
  , Constructed RouteRepoCreate
  , Constructed RouteRepoGet
  , Constructed RouteRepoUpdate
  , Constructed RouteRepoDelete
  , Constructed RouteRepoDeployKey
  , Constructed RouteRepoDeployKeyGenerate
  , Constructed RouteProvidersList
  , Constructed RouteProviderModels
  , Constructed RouteProviderModelContext
  , Constructed RouteUiStateGet
  , Constructed RouteUiStatePut
  , Constructed RouteUiCustomModels
  , Constructed RouteUiRepos
  , Constructed RouteAdopt
  ]

-- | The 'Router' for 'SealRoute', built from 'allRoutes' + 'routeMeta'.
sealRouter :: Router SealRoute
sealRouter = routerWith (mapMeta captureCodecToCaptureDecoding captureCodecToCaptureDecoding id id . routeMeta) allRoutes

-- ---------------------------------------------------------------------------
-- Capture codecs (design §4.3 — the always-succeed pattern)
-- ---------------------------------------------------------------------------

-- | A validated 'SessionId' capture (or the parse error). The codec never
-- returns 'Nothing', so trasa's path-not-found interception is never
-- triggered by a capture decode failure.
newtype SessionIdOrErr = SessionIdOrErr (Either Text Text)

sessionIdCapture :: CaptureCodec SessionIdOrErr
sessionIdCapture = CaptureCodec
  { captureCodecEncode = \(SessionIdOrErr e) -> fromRight "" e
  , captureCodecDecode = Just . SessionIdOrErr . Right
  }

-- | A validated 'AgentDefId' capture (or the parse error).
newtype AgentDefIdOrErr = AgentDefIdOrErr (Either Text Text)

agentDefIdCapture :: CaptureCodec AgentDefIdOrErr
agentDefIdCapture = CaptureCodec
  { captureCodecEncode = \(AgentDefIdOrErr e) -> fromRight "" e
  , captureCodecDecode = Just . AgentDefIdOrErr . Right
  }

-- | A validated 'SkillId' capture (or the parse error).
newtype SkillIdOrErr = SkillIdOrErr (Either Text Text)

skillIdCapture :: CaptureCodec SkillIdOrErr
skillIdCapture = CaptureCodec
  { captureCodecEncode = \(SkillIdOrErr e) -> fromRight "" e
  , captureCodecDecode = Just . SkillIdOrErr . Right
  }

-- | A validated 'RepoId' capture (or the parse error).
newtype RepoIdOrErr = RepoIdOrErr (Either Text Text)

repoIdCapture :: CaptureCodec RepoIdOrErr
repoIdCapture = CaptureCodec
  { captureCodecEncode = \(RepoIdOrErr e) -> fromRight "" e
  , captureCodecDecode = Just . RepoIdOrErr . Right
  }

-- | A tab index capture (or the parse error).
newtype TabIndexOrErr = TabIndexOrErr (Either Text Text)

tabIndexCapture :: CaptureCodec TabIndexOrErr
tabIndexCapture = CaptureCodec
  { captureCodecEncode = \(TabIndexOrErr e) -> fromRight "" e
  , captureCodecDecode = Just . TabIndexOrErr . Right
  }

-- | An 'AskId' capture (or the parse error).
newtype AskIdOrErr = AskIdOrErr (Either Text Text)

askIdCapture :: CaptureCodec AskIdOrErr
askIdCapture = CaptureCodec
  { captureCodecEncode = \(AskIdOrErr e) -> fromRight "" e
  , captureCodecDecode = Just . AskIdOrErr . Right
  }

-- | A plain 'Text' capture (unvalidated — used for provider labels + model
-- names where the legacy router did no validation).
textCapture :: CaptureCodec Text
textCapture = CaptureCodec
  { captureCodecEncode = id
  , captureCodecDecode = Just
  }

-- ---------------------------------------------------------------------------
-- ToParamSchema instances for the capture newtypes (OpenAPI generation)
-- ---------------------------------------------------------------------------

-- | All the validated-capture newtypes ('SessionIdOrErr', 'AgentDefIdOrErr',
-- etc.) represent path segments serialized as strings. The 'ToParamSchema'
-- instance renders a plain string schema so @trasa-openapi-hs@ can emit a
-- 'OpenApiSchema' for each path parameter without needing the underlying
-- validated type.
instance ToParamSchema SessionIdOrErr where
  toParamSchema _ = mempty & type_ ?~ OpenApiTypeSingle OpenApiString
instance ToParamSchema AgentDefIdOrErr where
  toParamSchema _ = mempty & type_ ?~ OpenApiTypeSingle OpenApiString
instance ToParamSchema SkillIdOrErr where
  toParamSchema _ = mempty & type_ ?~ OpenApiTypeSingle OpenApiString
instance ToParamSchema RepoIdOrErr where
  toParamSchema _ = mempty & type_ ?~ OpenApiTypeSingle OpenApiString
instance ToParamSchema TabIndexOrErr where
  toParamSchema _ = mempty & type_ ?~ OpenApiTypeSingle OpenApiString
instance ToParamSchema AskIdOrErr where
  toParamSchema _ = mempty & type_ ?~ OpenApiTypeSingle OpenApiString

-- ---------------------------------------------------------------------------
-- Body + response codecs (TODO W6b — implement in Seal.Gateway.Route.Codec)
-- ---------------------------------------------------------------------------

-- | The 'AnswerReq' sum body type.
data AnswerReq = AnswerReq
  { arAnswer :: !Text
  , arScope :: !Text
  } deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Free-form JSON schema + dummy JSON instances for the opaque body/response
-- marker types (OpenAPI generation). The handlers build 'Value's directly, so
-- these instances exist solely so 'Trasa.OpenApi.Codec.openApiJsonBody' can
-- produce an 'OpenApiBodyCodec' for each route. The 'ToJSON'/'FromJSON'
-- instances are never called by the OpenAPI generator (it only reads the
-- schema + media types); they're total dummies that satisfy the class
-- constraints. The 'ToSchema' instances render a free-form object schema
-- (@{"type":"object","additionalProperties":true}@).
-- ---------------------------------------------------------------------------

freeFormObjectSchema :: Schema
freeFormObjectSchema = mempty
  & type_ ?~ OpenApiTypeSingle OpenApiObject
  & additionalProperties ?~ AdditionalPropertiesAllowed True

instance ToSchema Resp where
  declareNamedSchema _ = pure (NamedSchema Nothing freeFormObjectSchema)
instance ToSchema Req where
  declareNamedSchema _ = pure (NamedSchema Nothing freeFormObjectSchema)
instance ToSchema AnswerReq where
  declareNamedSchema _ = pure (NamedSchema Nothing freeFormObjectSchema)

-- | A dummy 'BodyCodec' for the opaque marker types ('Resp', 'Req',
-- 'AnswerReq'). The OpenAPI generator only reads the media types from
-- 'bodyCodecNames' (the encode/decode functions are never called — the
-- generator builds a schema document, not a server). The functions are total
-- bottoms ('Left "unused") so they can't accidentally produce a value of the
-- uninhabited 'Resp'/'Req' types.
freeFormBodyCodec :: BodyCodec a
freeFormBodyCodec = BodyCodec
  { bodyCodecNames = "application/json" :| []
  , bodyCodecEncode = const BL.empty
  , bodyCodecDecode = \_ -> Left "freeFormBodyCodec: unused (OpenAPI generation only)"
  }