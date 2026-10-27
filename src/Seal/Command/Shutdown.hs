{-# LANGUAGE OverloadedStrings #-}
-- | Shutdown logging for @seal serve@.
--
-- Ctrl-C is the normal way to stop the server, and it is also the moment when
-- every in-process sub-agent dies: children run as forked threads in this
-- process ('Seal.Agent.Runtime.Registry'), so terminating the server
-- terminates them. Nothing marks that in the log today, which makes
-- "my sub-agents died and never came back" hard to correlate with "I stopped
-- the server". This module closes that gap:
--
-- * On 'UserInterrupt' (what the GHC RTS raises on the main thread for SIGINT)
--   it logs a shutdown marker plus an inventory of the live sub-agents — id,
--   parent session, child session, depth, status — and then exits with
--   'shutdownExitCode' (130, the conventional @128 + SIGINT@).
-- * Every other async exception is re-raised untouched: this handler must
--   never swallow 'ThreadKilled' or a timeout.
--
-- No POSIX signal handler is installed. The RTS already converts SIGINT into
-- 'UserInterrupt' and restores the default SIGINT disposition first, so a
-- second Ctrl-C still hard-kills a wedged process. Installing our own handler
-- would take that escape hatch away.
module Seal.Command.Shutdown
  ( handleServeInterrupt
  , isLiveSubagent
  , renderLiveSubagents
  , shutdownExitCode
  ) where

import Control.Exception (AsyncException (..), throwIO)
import Data.IORef (IORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..), exitWith)

import Katip (Severity (..), ls)

import Seal.Agent.Runtime.Delegation (subagentIdText)
import Seal.Agent.Runtime.Registry
  ( AgentInstance (..), AgentRuntime, AgentStatus (..), listAgents )
import Seal.Core.Types (sessionIdText)
import Seal.Logging.Logger (SealLogger, logIO)

-- | What a SIGINT-killed server exits with: 128 + 2 (SIGINT). Scripts and
-- @make serve@ then see an interrupted server rather than a clean exit 0.
shutdownExitCode :: ExitCode
shutdownExitCode = ExitFailure 130

-- | Handle an async exception raised on the @seal serve@ main thread.
--
-- 'UserInterrupt' (Ctrl-C) logs the shutdown marker + the live sub-agent
-- inventory and exits with 'shutdownExitCode'. The inventory comes from the
-- @IORef@ the serve wiring fills in once 'Seal.Core.Backends.newBackends' has
-- run; 'Nothing' means the interrupt landed during startup, before there was
-- a runtime to report on.
--
-- Any other async exception is re-raised as-is.
handleServeInterrupt :: SealLogger -> IORef (Maybe AgentRuntime) -> AsyncException -> IO ()
handleServeInterrupt logger runtimeRef = \case
  UserInterrupt -> do
    logShutdown logger runtimeRef
    exitWith shutdownExitCode
  other -> throwIO other

-- | Emit the shutdown marker followed by one line per live sub-agent.
logShutdown :: SealLogger -> IORef (Maybe AgentRuntime) -> IO ()
logShutdown logger runtimeRef = do
  mRuntime <- readIORef runtimeRef
  case mRuntime of
    Nothing ->
      logIO logger InfoS
        "SIGINT received (Ctrl-C); shutting down during startup\
        \ (the sub-agent runtime was not created yet)"
    Just runtime -> do
      instances <- listAgents runtime
      let live = filter isLiveSubagent instances
      logIO logger InfoS (ls (headline (length live)))
      mapM_ (logIO logger InfoS . ls) (renderLiveSubagents live)
  where
    -- Plain ASCII on purpose: 'Seal.Logging.Logger.logIO' renders messages
    -- through 'show', so a non-ASCII glyph shows up escaped (@\\8212@ for an
    -- em dash) in seal.log.
    headline :: Int -> Text
    headline 0 = "SIGINT received (Ctrl-C); shutting down: no live sub-agents"
    headline 1 =
      "SIGINT received (Ctrl-C); shutting down: 1 live sub-agent\
      \ will be killed with this process"
    headline n =
      "SIGINT received (Ctrl-C); shutting down: " <> T.pack (show n)
        <> " live sub-agents will be killed with this process"

-- | A sub-agent whose worker thread is still alive in this process, and so
-- dies with it. 'Starting' and 'Running' are the statuses that carry a live
-- forked worker; the rest ('Stopped', 'Crashed', 'Interrupted') linger in the
-- registry as history.
isLiveSubagent :: AgentInstance -> Bool
isLiveSubagent inst = case aiStatus inst of
  Starting -> True
  Running  -> True
  _        -> False

-- | Render one line per live sub-agent: id, parent session, child session,
-- depth, status. Non-live entries are dropped. The id already embeds the
-- agent def id (see 'Seal.Agent.Runtime.Delegation.mkSubagentId'), so the def
-- is not repeated here.
renderLiveSubagents :: [AgentInstance] -> [Text]
renderLiveSubagents = map render . filter isLiveSubagent
  where
    render inst =
      "  sub-agent " <> subagentIdText (aiSubagentId inst)
        <> " parent=" <> sessionIdText (aiParentSession inst)
        <> " child=" <> sessionIdText (aiSession inst)
        <> " depth=" <> T.pack (show (aiDepth inst))
        <> " status=" <> statusText (aiStatus inst)
    statusText = \case
      Starting    -> "starting"
      Running     -> "running"
      Idle        -> "idle"
      Stopped     -> "stopped"
      Interrupted -> "interrupted"
      Crashed err -> "crashed: " <> err
