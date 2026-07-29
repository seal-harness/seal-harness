module Seal.AppMain
  ( appMain
  , withDefaultArgs
  ) where

import Control.Monad.IO.Class (liftIO)
import Control.Lens (view)
import System.Environment (getArgs, withArgs)
import qualified Configuration.Utils as CUtils

import Seal.Logging.Logger (withSealLogger)
import Seal.Logging.Global (setGlobalLogger)
import Seal.Types.Config
import Seal.Types.Command
import Seal.Types.Env
import Seal.Types.App
import qualified Seal.Tui
import qualified Seal.Channels.Signal.Run
import qualified Seal.Channels.Telegram.Run
import qualified Seal.Command.Serve

-- | Program information for 'runWithConfiguration'. Provides @--config-file@,
-- @--print-config@, and @--help@ automatically.
programInfo :: CUtils.ProgramInfo Config
programInfo = CUtils.programInfo "seal — secure AI agent execution around the SealOp ISA"
  pConfig defaultConfig

-- | Dispatch on the selected command, running it in 'App'. The 'SealLogger'
-- is built once via 'withSealLogger' (a bracket that closes the scribe on
-- exit) and threaded into 'Env' so 'App'-level 'logMsg' and 'IO'-level
-- 'logIO' reach the same scribe.
dispatch :: Config -> IO ()
dispatch cfg =
  withSealLogger (view config_logLevel cfg) $ \logger -> do
    setGlobalLogger logger
    env <- mkEnv logger cfg
    runApp env $ case _config_command cfg of
      CommandNoOp   -> pure ()
      CommandTui autonomy -> liftIO (Seal.Tui.runTui autonomy logger)
      CommandSignal autonomy -> liftIO (Seal.Channels.Signal.Run.runSignalMain autonomy logger)
      CommandTelegram autonomy -> liftIO (Seal.Channels.Telegram.Run.runTelegramMain autonomy logger)
      CommandServe autonomy -> liftIO (Seal.Command.Serve.runServeMain autonomy logger)

-- | Map the process arguments so that an empty argument list behaves as if
-- @--help@ was passed. Running @seal@ with no arguments should print usage
-- rather than silently doing nothing. Any non-empty argument list is passed
-- through unchanged.
withDefaultArgs :: [String] -> [String]
withDefaultArgs [] = ["--help"]
withDefaultArgs as = as

-- | Entry point: parse defaults + config file + CLI flags, then dispatch.
-- With no arguments, fall back to @--help@.
appMain :: IO ()
appMain = do
  args <- getArgs
  withArgs (withDefaultArgs args) (CUtils.runWithConfiguration programInfo dispatch)