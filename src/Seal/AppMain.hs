module Seal.AppMain (appMain) where

import qualified Configuration.Utils as CUtils

import Seal.Types.Config
import Seal.Types.Command
import Seal.Types.Env
import Seal.Types.App
import Seal.Commands.Greet
import Seal.Commands.Tick

-- | Program information for 'runWithConfiguration'. Provides @--config-file@,
-- @--print-config@, and @--help@ automatically.
programInfo :: CUtils.ProgramInfo Config
programInfo = CUtils.programInfo "seal — secure AI agent execution around the SealOp ISA"
  pConfig defaultConfig

-- | Dispatch on the selected command, running it in 'App'.
dispatch :: Config -> IO ()
dispatch cfg = do
  env <- mkEnv cfg
  runApp env $ case _config_command cfg of
    CommandNoOp     -> pure ()
    CommandGreet n  -> greet n
    CommandTick n   -> tick n

-- | Entry point: parse defaults + config file + CLI flags, then dispatch.
appMain :: IO ()
appMain = CUtils.runWithConfiguration programInfo dispatch