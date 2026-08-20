{-# LANGUAGE OverloadedStrings #-}
-- | The @\/stop@ slash command: abort a session's in-flight tool call (and
-- any future tool call until the next turn starts). Wires the
-- 'SessionAbortRegistry' (design Blocker Resolution #2) to the channel
-- command surface.
--
-- The target session is resolved by an @'IO' 'SessionId'@ action closed
-- over at construction time, so the same spec serves both wiring shapes:
--
-- * Single-session channels (CLI, Signal, Telegram) use
--   'stopCommandSpec' with the process-global @srActive@ ref — the
--   channel owns one session at a time.
-- * The multi-session web gateway builds a per-request spec via
--   'stopCommandSpecForSession' closing over the request's explicit
--   'SessionId' (mirroring the per-request @call@/@skill@ rebuild in
--   'Seal.Gateway.Send.runSlash'). A @\/stop@ typed in tab 3 must abort
--   tab 3's session, not whatever @srActive@ happens to point at.
module Seal.Command.Stop
  ( stopCommandSpec
  , stopCommandSpecForSession
  ) where

import Data.IORef (readIORef)
import Options.Applicative

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Core.Types (SessionId, sessionIdText)
import Seal.Session.Store (SessionRuntime (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Tools.Exec.Abort (SessionAbortRegistry, setSessionAbort)

-- | The @\/stop@ command spec for single-session channels (CLI, Signal,
-- Telegram). Closes over the 'SessionAbortRegistry' + 'SessionRuntime';
-- the action reads @srActive@ at dispatch time to resolve the target
-- session. The command takes no arguments.
stopCommandSpec :: SessionAbortRegistry -> SessionRuntime -> CommandSpec
stopCommandSpec abortReg sr = stopCommandSpecWith abortReg resolveActive
  where
    resolveActive = smId <$> readIORef (srActive sr)

-- | The @\/stop@ command spec for the multi-session web gateway. Closes
-- over the 'SessionAbortRegistry' + an explicit 'SessionId' (the
-- request's sid from the URL, threaded in via the per-request registry
-- rebuild in 'Seal.Gateway.Send.runSlash'). The command takes no
-- arguments.
stopCommandSpecForSession :: SessionAbortRegistry -> SessionId -> CommandSpec
stopCommandSpecForSession abortReg sid = stopCommandSpecWith abortReg (pure sid)

-- | The core spec builder, parameterized by the session-id resolution
-- action. Both public constructors delegate here.
stopCommandSpecWith :: SessionAbortRegistry -> IO SessionId -> CommandSpec
stopCommandSpecWith abortReg resolveSid = CommandSpec
  { csName         = CommandName "stop"
  , csAliases      = []
  , csGroup        = GroupSession
  , csSynopsis     = "Abort the active session's in-flight tool call"
  , csParserInfo   = stopParserInfo abortReg resolveSid
  , csAvailability = InteractiveOnly
  }

stopParserInfo :: SessionAbortRegistry -> IO SessionId -> ParserInfo CommandAction
stopParserInfo abortReg resolveSid =
  info (pure (stopAction abortReg resolveSid))
    (  progDesc "Abort the active session's in-flight tool call"
    <> header   "stop — abort the active session's in-flight tool call"
    )

stopAction :: SessionAbortRegistry -> IO SessionId -> CommandAction
stopAction abortReg resolveSid = CommandAction $ \caps -> do
  sid <- resolveSid
  setSessionAbort abortReg sid
  ccSend caps ("aborted session " <> sessionIdText sid)