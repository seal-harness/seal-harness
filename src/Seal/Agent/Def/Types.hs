{-# LANGUAGE OverloadedStrings #-}
-- | The agent-definition model. 'AgentDefId' is a smart-constructed newtype with
-- the same charset predicate as 'Seal.Core.Types.SessionId'
-- (@[A-Za-z0-9_-]+@, non-empty, no leading dot). An 'AgentDef' is a named
-- configuration (provider + model + system prompt + tool exposure) that a
-- running agent instance is bound to. The definition store is canonical in the
-- Audited log; this module's backend is a materialized view.
module Seal.Agent.Def.Types
  ( AgentDefId (..)
  , mkAgentDefId
  , isValidAgentDefId
  , agentDefIdText
  , AgentDef (..)
  , sanitizeAgentTextField
  , sanitizeAgentDefFields
  , agentFieldCapSmall
  , agentFieldCapName
  ) where

import Data.Aeson
  ( FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=) )
import Data.Aeson.Types (Value (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Vector qualified as V
import GHC.Generics (Generic)

import Seal.Core.Types (ModelId (..), OpName (..), SessionId)
import Seal.Security.Policy (AllowList (..))

-- | Opaque agent-definition key. Smart-constructed via 'mkAgentDefId'.
newtype AgentDefId = AgentDefId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

-- | @[A-Za-z0-9_-]+@, non-empty, no leading dot. Mirrors 'isValidMemoryId'.
isValidAgentDefId :: Text -> Bool
isValidAgentDefId t =
  not (T.null t)
    && T.head t /= '.'
    && T.all (`elem` chars) t
  where
    chars = ['A' .. 'Z'] <> ['a' .. 'z'] <> ['0' .. '9'] <> "_-"

mkAgentDefId :: Text -> Either Text AgentDefId
mkAgentDefId t
  | isValidAgentDefId t = Right (AgentDefId t)
  | otherwise           = Left ("invalid agent def id: " <> T.pack (show t))

agentDefIdText :: AgentDefId -> Text
agentDefIdText (AgentDefId t) = t

-- | One agent definition. 'adProvider' is a provider label (e.g. @\"ollama\"@);
-- 'adTools' is the opcode allow-list (which opcodes this agent may call). The
-- system prompt and tool list are agent-visible data (not vault secrets); they
-- are recorded in full in both the session transcript and the Audited log.
-- 'adSession' is the originating session (provenance). 'adUpdatedAt' is bumped
-- on each 'AGENT_DEF_UPDATE'.
--
-- 'adGroup' is an optional category for display grouping, mirroring 'skGroup'
-- on 'Seal.Skills.Types.Skill'. It is derived from the on-disk parent
-- directory name (@config\/agents\/\<group\>\/\<id\>.md@) and may be
-- overridden via a @group:@ frontmatter key. 'Nothing' means the def belongs
-- to the default (ungrouped) section. The def /id/ stays flat regardless of
-- group (the charset predicate forbids @\/@), so group is purely display
-- metadata — opcodes, file mapping, and lookups all key on 'adId'.
data AgentDef = AgentDef
  { adId        :: AgentDefId
  , adName      :: Text
  , adProvider  :: Text
  , adModel     :: ModelId
  , adSystem    :: Maybe Text
  , adTools     :: AllowList OpName
  , adGroup     :: Maybe Text
  , adRole      :: Maybe Text
    -- ^ @\"orchestrator\"@ | @\"leaf\"@ | 'Nothing' (≡ leaf). Authoritative —
    -- the def author (or operator) decides; AGENT_START's per-task role may
    -- only NARROW (orchestrator → leaf), never widen. Validated at
    -- AGENT_DEF_WRITE (rejects anything else) and passed through the
    -- field validators at decode time.
  , adDescription :: Maybe Text
    -- ^ One-line human/model-facing summary rendered into the
    -- @\<available_agents\>@ catalog and AGENT_DEF_LIST output.
    -- Sanitized (single line, no control chars, no catalog-fence tokens,
    -- capped) — the same injection defense as every other def field.
  , adCreatedAt :: UTCTime
  , adUpdatedAt :: UTCTime
  , adSession   :: SessionId
  } deriving stock (Eq, Show, Generic)

-- | The small per-field cap (role, description, group, provider, model):
-- these render into prompt catalogs / tool output, so they are bounded
-- tightly. 256 chars.
agentFieldCapSmall :: Int
agentFieldCapSmall = 256

-- | The name cap. 1024 chars (names may be longer than the small cap).
agentFieldCapName :: Int
agentFieldCapName = 1024

-- | Catalog-fence tokens a def field must never carry (they would let a
-- def field forge or close the @\<available_agents\>@ /
-- @\<available_skills\>@ catalog block, or forge frontmatter fences on
-- re-encode).
agentFenceTokens :: [Text]
agentFenceTokens = ["</available_agents>", "</available_skills>", "---"]

-- | Sanitize one agent-def text field for prompt/catalog rendering:
-- newlines, carriage returns, and tabs become spaces, C0 control
-- characters are stripped, the catalog fence tokens become underscores,
-- and the result is truncated at @cap@ characters with a truncation
-- marker. Pure; used by both decode paths and AGENT_DEF_WRITE (single
-- chokepoint each).
sanitizeAgentTextField :: Int -> Text -> Text
sanitizeAgentTextField cap = truncateField cap . T.strip . replaceFences . stripControl . singleLine
  where
    singleLine = T.replace "\r" " " . T.replace "\n" " " . T.replace "\t" " "
    stripControl = T.filter (>= ' ')
    replaceFences t = foldl' (\acc tok -> T.replace tok "_" acc) t agentFenceTokens
    truncateField n txt
      | T.length txt <= n = txt
      | otherwise = T.take n txt <> "[...truncated]"

-- | Sanitize every renderable field of an 'AgentDef' (role, description,
-- group, provider, model, name) with the per-field cap matrix:
-- @agentFieldCapSmall@ (256) for role/description/group/provider/model,
-- @agentFieldCapName@ (1024) for name. Pure; applied by both decode paths
-- and AGENT_DEF_WRITE so no unsanitized field can reach a prompt or tool
-- output.
sanitizeAgentDefFields :: AgentDef -> AgentDef
sanitizeAgentDefFields d = d
  { adName        = sanitizeAgentTextField agentFieldCapName (adName d)
  , adProvider    = sanitizeAgentTextField agentFieldCapSmall (adProvider d)
  , adModel       = ModelId (sanitizeAgentTextField agentFieldCapSmall m)
  , adGroup       = sanitizeMaybe agentFieldCapSmall (adGroup d)
  , adRole        = sanitizeMaybe agentFieldCapSmall (adRole d)
  , adDescription = sanitizeMaybe agentFieldCapSmall (adDescription d)
  }
  where
    m = case adModel d of ModelId t -> t
    sanitizeMaybe cap = fmap (sanitizeAgentTextField cap)

-- | Encode an 'AllowList OpName' as a JSON value: @\"all\"@ for 'AllowAll', or
-- an array of opcode-name strings for 'AllowOnly'.
allowListToValue :: AllowList OpName -> Value
allowListToValue AllowAll       = String "all"
allowListToValue (AllowOnly xs) = toJSON (map unOpNameText (Set.toList xs))
  where
    unOpNameText (OpName t) = t

-- | Decode an 'AllowList OpName' from @\"all\"@ or an array of opcode-name
-- strings. Unknown shapes default to 'AllowAll' (fail-closed would block the
-- agent from calling anything; the wiring layer validates input before
-- construction, so a malformed stored def is treated permissively).
allowListFromValue :: Value -> AllowList OpName
allowListFromValue (String "all") = AllowAll
allowListFromValue (Array xs)     = AllowOnly (Set.fromList [ OpName t | String t <- V.toList xs ])
allowListFromValue _               = AllowAll

instance ToJSON AgentDef where
  toJSON d = object
    [ "id"         .= adId d
    , "name"       .= adName d
    , "provider"   .= adProvider d
    , "model"      .= adModel d
    , "system"     .= adSystem d
    , "tools"      .= allowListToValue (adTools d)
    , "group"      .= adGroup d
    , "role"       .= adRole d
    , "description" .= adDescription d
    , "created_at" .= adCreatedAt d
    , "updated_at" .= adUpdatedAt d
    , "session"    .= adSession d
    ]

instance FromJSON AgentDef where
  parseJSON = withObject "AgentDef" $ \o -> AgentDef
    <$> o .:  "id"
    <*> o .:  "name"
    <*> o .:  "provider"
    <*> o .:  "model"
    <*> o .:? "system"
    <*> (allowListFromValue <$> o .: "tools")
    <*> o .:? "group"
    <*> o .:? "role"
    <*> o .:? "description"
    <*> o .:  "created_at"
    <*> o .:  "updated_at"
    <*> o .:  "session"