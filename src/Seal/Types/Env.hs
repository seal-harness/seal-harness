module Seal.Types.Env
  ( Env(..)
  , mkEnv
  ) where

import Control.Lens
import Data.IORef
import Data.Text (Text)

import Seal.Types.Config

-- | The runtime environment, built from the resolved 'Config'. Holds resolved
-- config values plus mutable state as 'IORef's — here an invocation/tick
-- counter — demonstrating the IORef-over-@StateT@ approach.
data Env = Env
  { envGreeting :: !Text
  , envLogLevel :: !Text
  , envServerHost :: !Text
  , envServerPort :: !Int
  -- | Mutable state: a simple counter incremented by the @tick@ command.
  , envCounter :: !(IORef Int)
  -- A long-lived resource (HTTP 'Manager', DB pool, etc.) would live here.
  -- , envHttpManager :: !Manager
  }

-- | Build the runtime 'Env' from the resolved configuration.
mkEnv :: Config -> IO Env
mkEnv cfg = do
  counter <- newIORef 0
  pure Env
    { envGreeting = view config_greeting cfg
    , envLogLevel = view config_logLevel cfg
    , envServerHost = view (config_server . serverConfig_host) cfg
    , envServerPort = view (config_server . serverConfig_port) cfg
    , envCounter = counter
    }