{-# LANGUAGE OverloadedStrings #-}
-- | The on-disk session metadata record ('session.json'): the session's
-- selected provider label + model id (never a key), its channel of origin, the
-- bound agent definition (if any — set at init from @default_agent@), its
-- cloned repo, the execution machine it is pinned to, and timestamps. The
-- 'FromJSON' is tolerant (missing 'channel' defaults to @\"cli\"@, missing
-- 'agent' defaults to 'Nothing') so older/partial files still load.
--
-- Also home to the single reader for that file ('readSessionMeta') — a leaf
-- module, so every layer (the turn engine, the gateway, the delegation
-- worker, the opcodes) and the tests can load a session without import
-- cycles.
--
-- @exec_machine@ is the one field whose JSON is written by hand with an
-- explicit /omit/: see the 'ToJSON' instance.
module Seal.Session.Meta
  ( SessionMeta (..)
  , defaultSessionMeta
  , setExecMachine
  , readSessionMeta
  ) where

import Data.Aeson
  ( FromJSON (..), ToJSON (..), Value (Object, String), object, withObject, (.:)
  , (.:?), (.!=), (.=) )
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Object, Parser)
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Katip (Severity (..))
import System.Directory (doesFileExist)

import Seal.Agent.Def.Types (AgentDefId (..))
import Seal.Config.Paths (SealPaths, sessionMetaPath)
import Seal.Core.Types (SessionId)
import Seal.Execution.Types (MachineName, machineNameText, mkMachineName)
import Seal.Logging.Global (globalLogIO)
import Seal.Util.StrictIO (decodeFileStrict)

-- | Load a session's 'SessionMeta' from
-- @\<state\>\/sessions\/\<sid\>\/session.json@. Returns 'Nothing' when the
-- file is missing or undecodable. The existence check is required:
-- 'decodeFileStrict' reads with @sourceFile@, which throws on a missing path.
readSessionMeta :: SealPaths -> SessionId -> IO (Maybe SessionMeta)
readSessionMeta paths sid = do
  let mp = sessionMetaPath paths sid
  exists <- doesFileExist mp
  if not exists then pure Nothing else do
    decoded <- decodeFileStrict mp
    case decoded of
      -- Only a session whose pin decoded to Nothing can be hiding a
      -- malformed one; check for the warning case and report it.
      Just m | Nothing <- smExecMachine m -> do
        warnIfMalformed mp
        pure (Just m)
      other -> pure other

-- | Warn when @session.json@ carries an @exec_machine@ that is present but
-- unparseable.
--
-- Deliberately a log line and not a decode error. The decode stays tolerant
-- (see 'parseExecMachine'): 'readSessionMeta' has no error channel and 30 call
-- sites depend on that, and making a hand-edited session unreadable entirely
-- is a harsher outcome than the case it would prevent. §5 row 0 already
-- fail-closes the case that matters — a /valid/ pin naming a removed machine.
warnIfMalformed :: FilePath -> IO ()
warnIfMalformed path = do
  raw <- decodeFileStrict path
  case raw of
    Just (Object o) -> case KM.lookup (K.fromText "exec_machine") o of
      Just (String txt)
        | Left _ <- mkMachineName txt ->
            globalLogIO WarningS (fromString
              ("session.json: ignoring malformed exec_machine "
                <> show (T.take 80 txt) <> " in " <> path))
      _ -> pure ()
    _ -> pure ()

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
  , smExecMachine :: Maybe MachineName
    -- ^ The execution machine this session is /pinned/ to, or 'Nothing' for
    -- \"use the effective default\". v1 persists the name the user asked
    -- for, never a resolved 'Seal.Tools.Exec.Types.SshConfig': storing a
    -- resolution would freeze a fingerprint of mutable config.
    --
    -- A pin is a /request/, so it does not survive its machine being removed:
    -- resolution fails closed on an unknown pin rather than falling back.
  , smCreatedAt  :: UTCTime
  , smLastActive :: UTCTime
  } deriving stock (Eq, Show)

-- | A session's metadata with every \"no opinion\" field at its default.
--
-- Exists so the ~27 record-literal construction sites can be read as
-- @defaultSessionMeta sid now { … }@ — the site then states only what it
-- means to state. It is /not/ a schema default: 'readSessionMeta' still
-- decodes field by field.
defaultSessionMeta :: SessionId -> UTCTime -> SessionMeta
defaultSessionMeta sid now = SessionMeta
  { smId              = sid
  , smProvider        = "anthropic"
  , smModel           = ""
  , smChannel         = "cli"
  , smParent          = Nothing
  , smAgent           = Nothing
  , smSystemOverride  = Nothing
  , smAgentName       = Nothing
  , smDescription     = Nothing
  , smSealFrontMatter = True
  , smRepoUrl         = Nothing
  , smRepoBranch      = Nothing
  , smExecMachine     = Nothing
  , smCreatedAt       = now
  , smLastActive      = now
  }

-- | Pin a session to a machine. Total, so a caller cannot end up with an
-- unpinned session by accident.
setExecMachine :: MachineName -> SessionMeta -> SessionMeta
setExecMachine n m = m { smExecMachine = Just n }

-- | @exec_machine@ is the one key written by hand so that 'Nothing' **omits**
-- it, rather than emitting @null@.
--
-- This is load-bearing, not tidiness. Meta.hs's house style is
-- @"repo_url" .= smRepoUrl m@ (a 'Maybe' becomes @null@). Copying that here
-- would put a /present/ @exec_machine@ key on every post-deploy session, and
-- the falsification metric's premise — \"a present key means the user
-- deliberately changed the picker\" — would then be false on exactly the
-- population that metric measures (design §9).
instance ToJSON SessionMeta where
  toJSON m = object $
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
    ]
    <> [ "exec_machine" .= machineNameText n | Just n <- [smExecMachine m] ]
    <> [ "created_at"  .= smCreatedAt m
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
    <*> parseExecMachine o
    <*> o .:  "created_at"
    <*> o .:  "last_active"

-- | Decode @exec_machine@. Three cases, and only one is a decode concern:
--
--   * /absent/ ⇒ 'Nothing'. This is the normal case: every session created
--     before this field existed, and every session where the user left the
--     picker on its sentinel option.
--   * /present but malformed/ (hand-edited, corrupt) ⇒ 'Nothing'. The
--     warning is emitted by 'readSessionMeta', the only IO layer that can
--     log; 'readSessionMeta' returns @IO (Maybe SessionMeta)@ with no error
--     channel and 30 call sites depend on that, and propagating a decode
--     failure would make a hand-edited session unreadable entirely, which is
--     a harsher outcome than the case it would prevent.
--   * /present and valid/ but naming a machine that no longer exists ⇒ this
--     is **not** a decode concern. It decodes to @Just name@ and resolution
--     fails closed at §5 row 0.
parseExecMachine :: Object -> Parser (Maybe MachineName)
parseExecMachine o = do
  raw <- o .:? "exec_machine"
  case raw of
    Nothing   -> pure Nothing
    Just txt  -> case mkMachineName txt of
      Right n -> pure (Just n)
      -- Malformed: drop it here, and let 'readSessionMeta' report it.
      Left _ -> pure Nothing
