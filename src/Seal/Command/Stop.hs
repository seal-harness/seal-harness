{-# LANGUAGE OverloadedStrings #-}
-- | The @\/stop@ slash command: abort the active session's in-flight tool
-- call (and any future tool call until the next turn starts). Wires the
-- 'SessionAbortRegistry' (design Blocker Resolution #2) to the channel
-- command surface. Available on Signal, Telegram, and the CLI (each
-- channel's command registry includes this spec).
module Seal.Command.Stop
  ( stopCommandSpec
  ) where

import Data.IORef (readIORef)
import Options.Applicative

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Core.Types (sessionIdText)
import Seal.Session.Store (SessionRuntime (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Tools.Exec.Abort (SessionAbortRegistry, setSessionAbort)

-- | The @\/stop@ command spec. Closes over the 'SessionAbortRegistry' +
-- 'SessionRuntime' (to read the active session id). The command takes no
-- arguments — it always targets the active session.
stopCommandSpec :: SessionAbortRegistry -> SessionRuntime -> CommandSpec
stopCommandSpec abortReg sr = CommandSpec
  { csName         = CommandName "stop"
  , csAliases      = []
  , csGroup        = GroupSession
  , csSynopsis     = "Abort the active session's in-flight tool call"
  , csParserInfo   = stopParserInfo
  , csAvailability = InteractiveOnly
  }
  where
    stopParserInfo =
      info (pure stopAction)
        (  progDesc "Abort the active session's in-flight tool call"
        <> header   "stop — abort the active session's in-flight tool call"
        )
    stopAction = CommandAction $ \caps -> do
      active <- readIORef (srActive sr)
      let sid = smId active
      setSessionAbort abortReg sid
      ccSend caps ("aborted session " <> sessionIdText sid)