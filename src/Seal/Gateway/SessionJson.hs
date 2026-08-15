{-# LANGUAGE OverloadedStrings #-}
-- | The JSON encoders for tabs and sessions, shared between
-- 'Seal.Gateway.API' (the REST endpoints) and 'Seal.Gateway.ListsSnapshot'
-- (the WS @lists@ frame + the @GET /api/lists@ body). Lives one level below
-- 'Seal.Gateway.API' so 'Seal.Gateway.ListsSnapshot' can import these
-- without creating a source-level module cycle with 'Seal.Gateway.API'
-- (which imports 'Seal.Gateway.ListsSnapshot' for the /api/lists route).
module Seal.Gateway.SessionJson
  ( tabToJson
  , tabKindWire
  , statusWire
  , sessionWire
  , sessionInfoJson
  , sessionInfoJsonWithSnippet
  ) where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)

import Seal.Agent.Def.Types (agentDefIdText)
import Seal.Config.Paths (SealPaths)
import Seal.Core.Types (sessionIdText)
import Seal.Gateway.Transcript (firstUserMessageSnippet, lastUserMessageAt)
import Seal.Handles.Tab (TabKind (..), tabIndexToInt)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Tabs.Types (Tab (..), TabRef (..), TabStatus (..))

import Control.Applicative ((<|>))

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
-- @description@ is the user-set title (persisted via @PUT
-- /api/sessions/:id/description@); @autoSummary@ and @channelUserId@ are
-- fields the backend doesn't track yet and are returned as @null@.
-- @firstMessageSnippet@ is derived from the session's transcript (the
-- first user message), so a session has a readable title before the user
-- sets an explicit description.
--
-- @agent@ is the display label for the session's active agent (used by
-- the sidebar / chat header). It prefers 'smAgentName' (set whenever an
-- agent is effective — either a bound 'smAgent' or a one-off uploaded
-- file's frontmatter id), falling back to 'smAgent'\'s id for
-- backwards-compat with old session.json files that predate smAgentName.
sessionInfoJson :: Maybe Text -> Maybe Text -> SessionMeta -> Value
sessionInfoJson mSnippet mLastUserMessageAt m = object
  [ "id" .= sessionIdText (smId m)
  , "agent" .= ( smAgentName m <|> (agentDefIdText <$> smAgent m) )
  , "runtime" .= ("session:" <> smProvider m)
  , "model" .= smModel m
  , "lastActive" .= smLastActive m
  , "createdAt" .= smCreatedAt m
  , "description" .= smDescription m
  , "autoSummary" .= (Nothing :: Maybe Text)
  , "firstMessageSnippet" .= mSnippet
  , "channel" .= smChannel m
  , "channelUserId" .= (Nothing :: Maybe Text)
  , "lastUserMessageAt" .= mLastUserMessageAt
  , "repo" .= smRepo m
  ]

-- | Build the 'SessionInfo' JSON for a session, reading the first user
-- message snippet and the last user-message timestamp from the transcript
-- so the session has a default title before the user sets an explicit
-- description and the sidebar can sort tabs by last-user-message time.
sessionInfoJsonWithSnippet :: SealPaths -> SessionMeta -> IO Value
sessionInfoJsonWithSnippet paths m = do
  mSnippet <- firstUserMessageSnippet paths (smId m)
  mLastUserMessageAt <- lastUserMessageAt paths (smId m)
  pure (sessionInfoJson mSnippet mLastUserMessageAt m)