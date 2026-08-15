{-# LANGUAGE OverloadedStrings #-}
-- | The on-disk session metadata record ('session.json'). Holds the session's
-- selected provider label + model id (never a key), its channel of origin, the
-- bound agent definition (if any — set at init from @default_agent@), and
-- timestamps. The 'FromJSON' is tolerant (missing 'channel' defaults to
-- @\"cli\"@, missing 'agent' defaults to 'Nothing') so older/partial files
-- still load.
module Seal.Session.Meta
  ( SessionMeta (..)
  ) where

import Data.Aeson
  ( FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.!=), (.=) )
import Data.Text (Text)
import Data.Time (UTCTime)

import Seal.Agent.Def.Types (AgentDefId (..))
import Seal.Core.Types (SessionId)

data SessionMeta = SessionMeta
  { smId         :: SessionId
  , smProvider   :: Text      -- ^ Provider label, e.g. @\"anthropic\"@.
  , smModel      :: Text      -- ^ Model id, e.g. @\"claude-opus-4-8\"@.
  , smChannel    :: Text      -- ^ Channel that created the session, e.g. @\"cli\"@.
  , smAgent      :: Maybe AgentDefId
    -- ^ The agent definition bound to this session at init (from
    -- @default_agent@ in @config.toml@). 'Nothing' means no agent is bound.
  , smSystemOverride :: Maybe Text
    -- ^ An ad-hoc system prompt supplied via the Session setup screen's
    -- \"Use a one-off agent file\" upload. When 'Just', 'plainTurn' prefers
    -- this over the bound agent's 'adSystem'. 'Nothing' means no override
    -- (the agent's prompt, if any, is used).
  , smAgentName :: Maybe Text
    -- ^ Display label for the session's active agent (shown in the
    -- sidebar / chat header as the @agent@ field of 'SessionInfo').
    -- Populated whenever the session has an effective agent — either the
    -- bound 'smAgent' (set to the agent def's id) or a one-off uploaded
    -- file (set to the file's frontmatter @id@, or the filename when the
    -- file has no frontmatter). 'Nothing' when no agent is active.
  , smDescription :: Maybe Text
    -- ^ A user-set display title for the session (the chat-header pencil).
    -- 'Nothing' means no explicit title; the UI then falls back to the
    -- auto-summary, first-message snippet, or agent name. Persisted to
    -- @session.json@ so it survives restarts and propagates to the
    -- sidebar (which reads the live session list, not a client-side
    -- override).
  , smRepo :: Maybe Text
    -- ^ The id (registered 'RepoId' text, or the sanitized repo name for a
    -- bare-URL clone) of the repository most recently cloned into the
    -- session's workdir via @SETUP_REPO@. 'Nothing' when no repo has been
    -- set up. Persisted so the sidebar can surface the associated repo
    -- without re-reading the transcript. Cleared only by a new session.
  , smCreatedAt  :: UTCTime
  , smLastActive :: UTCTime
  } deriving stock (Eq, Show)

instance ToJSON SessionMeta where
  toJSON m = object
    [ "id"          .= smId m
    , "provider"    .= smProvider m
    , "model"       .= smModel m
    , "channel"     .= smChannel m
    , "agent"       .= smAgent m
    , "system_override" .= smSystemOverride m
    , "agent_name"  .= smAgentName m
    , "description" .= smDescription m
    , "repo"        .= smRepo m
    , "created_at"  .= smCreatedAt m
    , "last_active" .= smLastActive m
    ]

instance FromJSON SessionMeta where
  parseJSON = withObject "SessionMeta" $ \o -> SessionMeta
    <$> o .:  "id"
    <*> o .:  "provider"
    <*> o .:  "model"
    <*> o .:? "channel" .!= "cli"
    <*> o .:? "agent"
    <*> o .:? "system_override"
    <*> o .:? "agent_name"
    <*> o .:? "description"
    <*> o .:? "repo"
    <*> o .:  "created_at"
    <*> o .:  "last_active"
