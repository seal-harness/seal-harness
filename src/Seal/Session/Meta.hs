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
    <*> o .:  "created_at"
    <*> o .:  "last_active"
