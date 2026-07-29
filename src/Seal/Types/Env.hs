module Seal.Types.Env
  ( Env(..)
  , mkEnv
  ) where

import Control.Lens
import Data.Text (Text)

import Seal.Logging.Logger (SealLogger)
import Seal.Types.Config

-- | The runtime environment, built from the resolved 'Config'. Holds resolved
-- config values; a mutable resource (counter 'IORef', HTTP 'Manager', DB pool,
-- etc.) would live here as well.
data Env = Env
  { envLogLevel :: !Text
  , envServerHost :: !Text
  , envServerPort :: !Int
  , envLogger :: !SealLogger
  -- , envHttpManager :: !Manager
  }

-- | Build the runtime 'Env' from the resolved configuration and the shared
-- 'SealLogger' (built once at startup via 'withSealLogger').
mkEnv :: SealLogger -> Config -> IO Env
mkEnv logger cfg = pure Env
  { envLogLevel = view config_logLevel cfg
  , envServerHost = view (config_server . serverConfig_host) cfg
  , envServerPort = view (config_server . serverConfig_port) cfg
  , envLogger = logger
  }