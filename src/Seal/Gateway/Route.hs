-- | The declarative route spec for the Seal Harness REST API (design §4.2).
--
-- One 'SealRoute' constructor per route. The 'routeMeta' table maps each
-- constructor to its path shape + HTTP method + capture/body codecs. The
-- 'sealRouter' is the 'Trasa.Core.Router' built from 'allRoutes'.
--
-- This module is pure: no 'IO', no 'ApiDeps'. The handler functions live in
-- 'Seal.Gateway.API' and are dispatched by the wrapper there.
--
-- This module is now a thin re-export from 'Seal.Gateway.Types.Route' (the
-- canonical home in the 'seal-gateway-types' library stanza).
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
  , respCodec
  , reqCodec
  , answerReqCodec
  ) where

import Seal.Gateway.Types.Route
