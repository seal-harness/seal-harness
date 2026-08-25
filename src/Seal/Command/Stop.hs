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
--
-- The stop message is recorded to the session's transcript (as an
-- assistant @\"(stopped)\"@ message) so it appears cross-channel — a
-- @\/stop@ from Telegram is visible in the web frontend's transcript
-- view, and vice versa. The transcript write is delegated to a
-- 'StopTranscriptWriter' built at the wiring site (it needs the
-- 'SealPaths' + broker + session metadata).
module Seal.Command.Stop
  ( stopCommandSpec
  , stopCommandSpecForSession
  , StopTranscriptWriter
  , noStopTranscriptWriter
  , mkStopTranscriptWriter
  ) where

import Data.IORef (readIORef)
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Options.Applicative

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Config.Paths (SealPaths, sessionDir)
import Seal.Core.Types (SessionId, sessionIdText)
import Seal.Core.TurnEngine (broadcastNewEntries, loadSessionMeta)
import Seal.Gateway.StreamBroker (StreamBroker)
import Seal.Handles.Transcript (TwoFileHandle (..), TwoFileWrite (..), withTwoFileTranscript)
import Seal.Providers.Class (Message (..), Role (..), ContentBlock (..))
import Seal.Session.Store (SessionRuntime (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Tools.Exec.Abort (SessionAbortRegistry, setSessionAbort)
import Seal.Transcript.Entries (EntryKind (..), EntryRecord (..))

-- | A function that records the stop message to the session's transcript
-- and broadcasts the new entry to WS subscribers. Built at the wiring
-- site from 'SealPaths' + the broker + session metadata. 'Nothing' (via
-- 'noStopTranscriptWriter') skips the transcript write — used in tests
-- or contexts without a transcript.
newtype StopTranscriptWriter = StopTranscriptWriter (Maybe (SessionId -> Text -> IO ()))

-- | The no-op writer (no transcript write). Used in tests or contexts
-- without a transcript.
noStopTranscriptWriter :: StopTranscriptWriter
noStopTranscriptWriter = StopTranscriptWriter Nothing

-- | Build a 'StopTranscriptWriter' from the shared dependencies. Opens
-- the session's transcript, writes the stop message as an assistant
-- 'EKResponse' entry, and broadcasts the new entry via the broker.
mkStopTranscriptWriter :: SealPaths -> Maybe StreamBroker -> StopTranscriptWriter
mkStopTranscriptWriter paths mBroker =
  StopTranscriptWriter $ Just $ \sid stopMsg -> do
    let dir = sessionDir paths sid
    mMeta <- loadSessionMeta paths sid
    now <- getCurrentTime
    let model = maybe "" smModel mMeta
        createdAt = maybe now smCreatedAt mMeta
    withTwoFileTranscript dir $ \h -> do
      let assistantMsg = Message Assistant [CbText stopMsg]
          entry = EntryRecord
            { erId = ""
            , erTimestamp = now
            , erKind = EKResponse
            , erConvLen = 1
            , erEnvelope = Nothing
            , erUsage = Nothing
            , erStop = Nothing
            , erDurationMs = Nothing
            , erHarness = Nothing
            , erCorrelation = Nothing
            , erMeta = mempty
            }
      tfwRecordAndAck h (TwoFileWrite [assistantMsg] entry)
      broadcastNewEntries mBroker paths sid model createdAt

-- | The @\/stop@ command spec for single-session channels (CLI, Signal,
-- Telegram). Closes over the 'SessionAbortRegistry' + 'SessionRuntime' +
-- 'StopTranscriptWriter'; the action reads @srActive@ at dispatch time
-- to resolve the target session. The command takes no arguments.
stopCommandSpec :: SessionAbortRegistry -> SessionRuntime -> StopTranscriptWriter -> CommandSpec
stopCommandSpec abortReg sr = stopCommandSpecWith abortReg (smId <$> readIORef (srActive sr))

-- | The @\/stop@ command spec for the multi-session web gateway. Closes
-- over the 'SessionAbortRegistry' + an explicit 'SessionId' (the
-- request's sid from the URL, threaded in via the per-request registry
-- rebuild in 'Seal.Gateway.Send.runSlash') + 'StopTranscriptWriter'.
stopCommandSpecForSession :: SessionAbortRegistry -> SessionId -> StopTranscriptWriter -> CommandSpec
stopCommandSpecForSession abortReg sid = stopCommandSpecWith abortReg (pure sid)

-- | The core spec builder, parameterized by the session-id resolution
-- action + the transcript writer. Both public constructors delegate here.
stopCommandSpecWith :: SessionAbortRegistry -> IO SessionId -> StopTranscriptWriter -> CommandSpec
stopCommandSpecWith abortReg resolveSid writer = CommandSpec
  { csName         = CommandName "stop"
  , csAliases      = []
  , csGroup        = GroupSession
  , csSynopsis     = "Abort the active session's in-flight tool call"
  , csParserInfo   = stopParserInfo abortReg resolveSid writer
  , csAvailability = InteractiveOnly
  }

stopParserInfo :: SessionAbortRegistry -> IO SessionId -> StopTranscriptWriter -> ParserInfo CommandAction
stopParserInfo abortReg resolveSid writer =
  info (pure (stopAction abortReg resolveSid writer) <**> helper)
    (  progDesc "Abort the active session's in-flight tool call"
    <> header   "stop — abort the active session's in-flight tool call"
    )

stopAction :: SessionAbortRegistry -> IO SessionId -> StopTranscriptWriter -> CommandAction
stopAction abortReg resolveSid (StopTranscriptWriter mWriter) = CommandAction $ \caps -> do
  sid <- resolveSid
  setSessionAbort abortReg sid
  let stopMsg = "(stopped)"
  case mWriter of
    Just writer -> writer sid stopMsg
    Nothing     -> pure ()
  ccSend caps ("aborted session " <> sessionIdText sid)