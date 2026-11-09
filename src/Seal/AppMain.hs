module Seal.AppMain
  ( appMain
  , reorderGlobalArgs
  , withDefaultArgs
  ) where

import Control.Monad.IO.Class (liftIO)
import Control.Lens (view)
import System.Environment (getArgs, withArgs)
import qualified Configuration.Utils as CUtils
import System.Exit (exitWith)
import System.Posix.Resource
  ( ResourceLimits (..), ResourceLimit (..), Resource (ResourceOpenFiles)
  , getResourceLimit, setResourceLimit )

import Seal.Logging.Logger (withSealLogger)
import Seal.Logging.Global (setGlobalLogger)
import Seal.Types.Config
import Seal.Types.Command
import Seal.Types.Env
import Seal.Types.App
import qualified Seal.Tui
import qualified Seal.Command.AccessControl
import qualified Seal.Command.Serve
import qualified Seal.Gateway.OpenApi

import Data.ByteString.Lazy qualified as BL
import System.IO (stdout)

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
  withSealLogger (view config_logLevel cfg) (Just "seal.log") $ \logger -> do
    setGlobalLogger logger
    env <- mkEnv logger cfg
    runApp env $ case _config_command cfg of
      CommandNoOp   -> pure ()
      CommandTui autonomy -> liftIO (Seal.Tui.runTui autonomy logger)
      CommandServe autonomy mStaticDir noEnrollToken -> liftIO (Seal.Command.Serve.runServeMain autonomy mStaticDir noEnrollToken logger)
      CommandAccessControl action -> do
        -- The command returns its code; exiting stays here so every code is
        -- assertable in-process (design §12).
        code <- liftIO (Seal.Command.AccessControl.runAccessControl action)
        liftIO (exitWith code)
      CommandGenOpenApi -> liftIO (BL.hPutStr stdout Seal.Gateway.OpenApi.encodeOpenApi)

-- | Map the process arguments so that an empty argument list behaves as if
-- @--help@ was passed. Running @seal@ with no arguments should print usage
-- rather than silently doing nothing. Any non-empty argument list is passed
-- through unchanged.
withDefaultArgs :: [String] -> [String]
withDefaultArgs [] = ["--help"]
withDefaultArgs as = as

-- | Raise the soft FD limit to the hard limit. The default macOS soft limit
-- is 256, which the gateway's @buildListsSnapshot@ hot path blows through
-- (hundreds of small files per request, historically via lazy IO that left
-- handles open for the GC). Even with strict reads, raising the soft limit
-- to the hard ceiling is cheap defense-in-depth against FD exhaustion. The
-- raise is best-effort: a failure (e.g. a sandboxed runner that blocks
-- @setrlimit@) is swallowed so the binary still starts.
raiseFdLimit :: IO ()
raiseFdLimit = do
  limits <- getResourceLimit ResourceOpenFiles
  case hardLimit limits of
    ResourceLimit _hard | softLimit limits /= hardLimit limits ->
      setResourceLimit ResourceOpenFiles limits { softLimit = hardLimit limits }
    _ -> pure ()

-- | Entry point: parse defaults + config file + CLI flags, then dispatch.
-- With no arguments, fall back to @--help@.
appMain :: IO ()
appMain = do
  raiseFdLimit
  args <- getArgs
  withArgs (withDefaultArgs (reorderGlobalArgs args)) (CUtils.runWithConfiguration programInfo dispatch)

-- | Move global options (those defined at the @pConfig@ level, outside any
-- @hsubparser@) before the subcommand keyword. @Options.Applicative@'s
-- @hsubparser@ creates a hard parser boundary: once the subcommand keyword
-- (e.g. @serve@) is seen, only subcommand-specific options are recognised.
-- A global option like @--log-level@ that appears after @serve@ is rejected.
--
-- This preprocessing lets @make serve ARGS="--yolo --log-level debug
-- --no-enrollment-token"@ work: @--log-level@ is hoisted before @serve@,
-- and the subcommand options (@--yolo@, @--no-enrollment-token@) stay after.
-- Options that are already before the subcommand are left in place.
-- @--flag=value@ syntax is a single token and passes through unchanged
-- (it does not match the bare @--flag@ name).
reorderGlobalArgs :: [String] -> [String]
reorderGlobalArgs args =
  case break isSubcommand args of
    (_, []) -> args
    (pre, cmd : post) -> pre ++ hoistGlobals post ++ [cmd] ++ stripGlobals post
  where
    subcommands = ["serve", "tui", "access-control", "gen-openapi"]
    isSubcommand s = s `elem` subcommands

    -- Global option names (defined in pConfig / pServerConfig, outside any
    -- hsubparser). Each takes exactly one argument.
    globalOpts = ["--log-level", "--server-host", "--server-port"]
    isGlobalOpt s = s `elem` globalOpts

    -- Extract global option pairs (flag + value) from the post-subcommand
    -- args, preserving order, for hoisting before the subcommand keyword.
    hoistGlobals = go []
      where
        go acc [] = reverse acc
        go acc (f : v : rest) | isGlobalOpt f = go (v : f : acc) rest
        go acc (_ : rest) = go acc rest

    -- Remove global option pairs from the post-subcommand args, leaving
    -- only subcommand-specific options.
    stripGlobals = go
      where
        go [] = []
        go (f : _v : rest) | isGlobalOpt f = go rest
        go (x : rest) = x : go rest
