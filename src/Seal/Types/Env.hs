module Seal.Types.Env
  ( Env(..)
  , mkEnv
  ) where

import Control.Lens
import Data.Text (Text)

import Seal.Types.Config

-- | The runtime environment, built from the resolved 'Config'. Holds resolved
-- config values; a mutable resource (counter 'IORef', HTTP 'Manager', DB pool,
-- etc.) would live here as well.
data Env = Env
  { envLogLevel :: !Text
  , envServerHost :: !Text
  , envServerPort :: !Int
  -- , envHttpManager :: !Manager
  }

-- | Build the runtime 'Env' from the resolved configuration.
mkEnv :: Config -> IO Env
mkEnv cfg = pure Env
  { envLogLevel = view config_logLevel cfg
  , envServerHost = view (config_server . serverConfig_host) cfg
  , envServerPort = view (config_server . serverConfig_port) cfg
  }