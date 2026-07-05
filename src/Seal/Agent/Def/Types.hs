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

import Seal.Core.Types (ModelId, OpName (..), SessionId)
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
data AgentDef = AgentDef
  { adId        :: AgentDefId
  , adName      :: Text
  , adProvider  :: Text
  , adModel     :: ModelId
  , adSystem    :: Maybe Text
  , adTools     :: AllowList OpName
  , adCreatedAt :: UTCTime
  , adUpdatedAt :: UTCTime
  , adSession   :: SessionId
  } deriving stock (Eq, Show, Generic)

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
    <*> o .:  "created_at"
    <*> o .:  "updated_at"
    <*> o .:  "session"