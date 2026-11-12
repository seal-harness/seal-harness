{-# LANGUAGE OverloadedStrings #-}
-- | The on-disk session metadata record ('session.json'): the session's
-- selected provider label + model id (never a key), its channel of origin, the
-- bound agent definition (if any — set at init from @default_agent@), its
-- cloned repo, and timestamps. The 'FromJSON' is tolerant (missing 'channel'
-- defaults to @\"cli\"@, missing 'agent' defaults to 'Nothing') so
-- older/partial files still load.
--
-- Also home to the single reader for that file ('readSessionMeta') — a leaf
-- module, so every layer (the turn engine, the gateway, the delegation
-- worker, the opcodes) and the tests can load a session without import
-- cycles.
module Seal.Session.Meta
  ( SessionMeta (..)
  , readSessionMeta
  ) where

import Data.Aeson
  ( FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.!=), (.=) )
import Data.Text (Text)
import Data.Time (UTCTime)
import System.Directory (doesFileExist)

import Seal.Agent.Def.Types (AgentDefId (..))
import Seal.Config.Paths (SealPaths, sessionMetaPath)
import Seal.Core.Types (SessionId)
import Seal.Util.StrictIO (decodeFileStrict)

-- | Load a session's 'SessionMeta' from
-- @\<state\>\/sessions\/\<sid\>\/session.json@. Returns 'Nothing' when the
-- file is missing or undecodable. The existence check is required:
-- 'decodeFileStrict' reads with @sourceFile@, which throws on a missing path.
readSessionMeta :: SealPaths -> SessionId -> IO (Maybe SessionMeta)
readSessionMeta paths sid = do
  let mp = sessionMetaPath paths sid
  exists <- doesFileExist mp
  if exists then decodeFileStrict mp else pure Nothing

data SessionMeta = SessionMeta
  { smId         :: SessionId
  , smProvider   :: Text      -- ^ Provider label, e.g. @\"anthropic\"@.
  , smModel      :: Text      -- ^ Model id, e.g. @\"claude-opus-4-8\"@.
  , smChannel    :: Text      -- ^ Channel that created the session, e.g. @\"cli\"@.
  , smParent     :: !(Maybe SessionId)
    -- ^ The session that spawned this session ('Nothing' for top-level
    -- sessions). Written by the delegation worker when a child transcript
    -- is created. Audit metadata only — the lineage guard uses the
    -- baked chain threaded through the spawn path, not this field.
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
  , smSealFrontMatter :: Bool
    -- ^ Whether the harness injects its own front matter into the session's
    -- system prompt (the static behavioral guidance blocks, the auto-loaded
    -- @seal-usage@ skill, the codegraph skill, and the available-skills /
    -- available-agents catalogs). 'True' (the default) injects it;
    -- 'False' means the system prompt is the selected agent's prompt and
    -- nothing else. Set by the session-setup form's "Add Seal Harness
    -- front matter" toggle.
  , smRepoUrl :: Maybe Text
    -- ^ The URL of the repository cloned into the session's workdir via
    -- @SETUP_REPO@ (either agent-invoked or the web setup-repo endpoint).
    -- 'Nothing' when no repo has been cloned. Persisted to @session.json@
    -- so the sidebar can show the repo name without scanning the workdir.
  , smRepoBranch :: Maybe Text
    -- ^ The branch or tag requested for 'smRepoUrl' through @SETUP_REPO@'s
    -- optional @branch@ argument. 'Nothing' means the remote's default
    -- branch (the *request*, not a resolved ref -- no git query is made).
    -- Recorded so a later clone can repeat the same checkout: an
    -- @AGENT_MANAGE action=handoff@ session inherits both the repo and
    -- this branch from the session that handed off.
  , smCreatedAt  :: UTCTime
  , smLastActive :: UTCTime
  } deriving stock (Eq, Show)

instance ToJSON SessionMeta where
  toJSON m = object
    [ "id"          .= smId m
    , "provider"    .= smProvider m
    , "model"       .= smModel m
    , "channel"     .= smChannel m
    , "parent"      .= smParent m
    , "agent"       .= smAgent m
    , "system_override" .= smSystemOverride m
    , "agent_name"  .= smAgentName m
    , "description" .= smDescription m
    , "seal_front_matter" .= smSealFrontMatter m
    , "repo_url"    .= smRepoUrl m
    , "repo_branch" .= smRepoBranch m
    , "created_at"  .= smCreatedAt m
    , "last_active" .= smLastActive m
    ]

instance FromJSON SessionMeta where
  parseJSON = withObject "SessionMeta" $ \o -> SessionMeta
    <$> o .:  "id"
    <*> o .:  "provider"
    <*> o .:  "model"
    <*> o .:? "channel" .!= "cli"
    <*> o .:? "parent"
    <*> o .:? "agent"
    <*> o .:? "system_override"
    <*> o .:? "agent_name"
    <*> o .:? "description"
    <*> o .:? "seal_front_matter" .!= True
    <*> o .:? "repo_url"
    <*> o .:? "repo_branch"
    <*> o .:  "created_at"
    <*> o .:  "last_active"
