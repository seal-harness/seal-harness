{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
module Seal.Types.Config
  ( Config(..)
  , defaultConfig
  , ServerConfig(..)
  , defaultServerConfig
  , pConfig
  -- * Lenses
  , config_command, config_greeting, config_logLevel, config_server
  , serverConfig_host, serverConfig_port
  ) where

import Data.Text (Text)

import Configuration.Utils
import Control.Lens hiding ((.=))

import Seal.Types.Command

-- | A nested sub-record that stands in for "large amounts of configuration."
-- Demonstrates nested config parsing via '%.:' (config file) and '%::' (CLI).
data ServerConfig = ServerConfig
  { _serverConfig_host :: !Text
  , _serverConfig_port :: !Int
  } deriving (Eq, Show)

makeLenses ''ServerConfig

defaultServerConfig :: ServerConfig
defaultServerConfig = ServerConfig
  { _serverConfig_host = "127.0.0.1"
  , _serverConfig_port = 8080
  }

instance FromJSON (ServerConfig -> ServerConfig) where
  parseJSON = withObject "ServerConfig" $ \o -> id
    <$< serverConfig_host ..: "host" % o
    <*< serverConfig_port ..: "port" % o

instance ToJSON ServerConfig where
  toJSON s = object
    [ "host" .= _serverConfig_host s
    , "port" .= _serverConfig_port s
    ]

pServerConfig :: MParser ServerConfig
pServerConfig = id
  <$< serverConfig_host .:: strOption
      ( long "server-host"
      <> help "Server host" )
  <*< serverConfig_port .:: option auto
      ( long "server-port"
      <> metavar "PORT"
      <> help "Server port" )

-- | The resolved program configuration. The '_config_command' field is
-- CLI-only (it is not part of the 'FromJSON'/'ToJSON' instances) and holds
-- the selected subcommand plus its per-command arguments.
data Config = Config
  { _config_command :: !Command
  , _config_greeting :: !Text
  , _config_logLevel :: !Text
  , _config_server :: !ServerConfig
  } deriving (Eq, Show)

makeLenses ''Config

defaultConfig :: Config
defaultConfig = Config
  { _config_command = CommandNoOp
  , _config_greeting = "Hello"
  , _config_logLevel = "Info"
  , _config_server = defaultServerConfig
  }

-- | Config-file 'FromJSON' instance (update-function style). The '_config_command'
-- field is intentionally excluded: commands are not config-file data.
instance FromJSON (Config -> Config) where
  parseJSON = withObject "Config" $ \o -> id
    <$< config_greeting ..: "greeting" % o
    <*< config_logLevel ..: "log-level" % o
    <*< config_server %.: "server" % o

-- | Hand-written 'ToJSON' for '--print-config'. Excludes '_config_command'.
instance ToJSON Config where
  toJSON c = object
    [ "greeting" .= _config_greeting c
    , "log-level" .= _config_logLevel c
    , "server" .= _config_server c
    ]

-- | CLI parser. The command is a flat field parsed with '.::' from an
-- 'hsubparser'; everything else mirrors the config-file structure.
pConfig :: MParser Config
pConfig = id
  <$< config_command .:: pCommand
  <*< config_greeting .:: strOption
      ( long "greeting"
      <> help "Greeting word to use" )
  <*< config_logLevel .:: strOption
      ( long "log-level"
      <> help "Minimum log severity (Debug|Info|Notice|Warning|Error)" )
  <*< config_server %:: pServerConfig