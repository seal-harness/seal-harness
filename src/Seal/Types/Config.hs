{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
module Seal.Types.Config
  ( Config(..)
  , defaultConfig
  , pConfig
  -- * Lenses
  , config_command, config_logLevel
  ) where

import Data.Text (Text)

import Configuration.Utils
import Control.Lens hiding ((.=))

import Seal.Types.Command

-- | The resolved program configuration. The '_config_command' field is
-- CLI-only (it is not part of the 'FromJSON'/'ToJSON' instances) and holds
-- the selected subcommand plus its per-command arguments.
--
-- The gateway's bind host/port live in @~/.seal/security.toml@ (see
-- 'Seal.Gateway.Config'), not here: they decide who can reach the agent and
-- are agent-immutable. The old @[server]@/@--server-host@ scaffold was never
-- wired to the listener and has been removed.
data Config = Config
  { _config_command :: !Command
  , _config_logLevel :: !Text
  } deriving (Eq, Show)

makeLenses ''Config

defaultConfig :: Config
defaultConfig = Config
  { _config_command = CommandNoOp
  , _config_logLevel = "Info"
  }

-- | Config-file 'FromJSON' instance (update-function style). The '_config_command'
-- field is intentionally excluded: commands are not config-file data.
instance FromJSON (Config -> Config) where
  parseJSON = withObject "Config" $ \o -> id
    <$< config_logLevel ..: "log-level" % o

-- | Hand-written 'ToJSON' for '--print-config'. Excludes '_config_command'.
instance ToJSON Config where
  toJSON c = object
    [ "log-level" .= _config_logLevel c
    ]

-- | CLI parser. The command is a flat field parsed with '.::' from an
-- 'hsubparser'; everything else mirrors the config-file structure.
pConfig :: MParser Config
pConfig = id
  <$< config_command .:: pCommand
  <*< config_logLevel .:: strOption
      ( long "log-level"
      <> help "Minimum log severity (Debug|Info|Notice|Warning|Error)" )
