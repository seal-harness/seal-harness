module Seal.AppMain
  ( appMain
  , withDefaultArgs
  ) where

import Control.Monad.IO.Class (liftIO)
import Control.Lens ((^.))
import System.Environment (getArgs, withArgs)
import qualified Configuration.Utils as CUtils

import Seal.Types.Config
import Seal.Types.Command
import Seal.Types.Env
import Seal.Types.App
import qualified Seal.Tui
import qualified Seal.Channels.Signal.Run
import qualified Seal.Command.Serve

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
    CommandNoOp   -> pure ()
    CommandTui   -> liftIO Seal.Tui.runTui
    CommandSignal -> liftIO Seal.Channels.Signal.Run.runSignalMain
    CommandServe  -> liftIO (Seal.Command.Serve.runServeMain (cfg ^. config_autonomy))

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