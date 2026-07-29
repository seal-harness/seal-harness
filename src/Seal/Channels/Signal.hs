{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
-- | The Signal channel: a 'SignalChannel' record (resolved allow-list +
-- chunk limit + account + inbox 'TQueue' + transport + last-sender 'IORef'
-- + logger) and its 'Channel' instance. The reader thread parses signal-cli
-- output, allow-lists the sender, and pushes envelopes to the inbox; sends
-- are chunked via 'Seal.Channels.Signal.Transport.chunkMessage' to the
-- configured limit and addressed to the last sender.
module Seal.Channels.Signal
  ( SignalChannel (..)
  , withSignalChannel
  ) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.STM (TQueue, atomically, newTQueueIO, tryReadTQueue, writeTQueue)
import Control.Exception (bracket, SomeException, try, AsyncException (..), fromException)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Channels.Class (Channel (..))
import Seal.Channels.Signal.Transport
  ( SignalEnvelope (..), SignalTransport (..), chunkMessage, parseSignalEnvelope )
import Seal.Core.AllowList (AllowList (..), isAllowed)
import Seal.Core.ChannelKind (ChannelKind (..))
import Seal.Core.MessageSource
  ( MessageSource, UserId, mkMessageSource, userIdText )
import Seal.Handles.Channel (ChannelHandle (..), Deferral (..))
import Seal.Logging.Logger (SealLogger, logIO)
import Seal.Signal.Config (SignalAccount (..))

import Katip (Severity (..), ls)

-- | The live Signal channel state.
data SignalChannel = SignalChannel
  { scAllowList    :: AllowList UserId  -- ^ resolved sender allow-list
  , scChunkLimit   :: Int               -- ^ chunk limit for sends
  , scAccount      :: SignalAccount
  , scInbox        :: TQueue (MessageSource, Text)
  , scTransport    :: SignalTransport
  , scLastSender   :: IORef (Maybe UserId)
  , scReaderAlive  :: IORef Bool
    -- ^ 'True' while the reader thread is running. 'chReceive' stops
    -- returning once the inbox drains and this is 'False'.
  , scLogger       :: SealLogger
    -- ^ The shared logger for structured katip logging.
  }

instance Channel SignalChannel where
  toHandle ch = ChannelHandle
    { chLabel       = "signal"
    , chSend         = sendChunked ch
    , chSendError    = \t -> sendChunked ch ("error: " <> t)
    , chSendChunk    = sendRaw ch
    , chPrompt       = \_ -> pure (Left Deferred)   -- Signal can't answer inline
    , chPromptSecret = \_ -> pure (Left Deferred)
    , chStreaming    = True
    , chReadSecret   = pure Nothing                  -- vault is reached via the vault handle
    , chReceive      = receiveFromInbox ch
    }

-- | Run the reader thread with cleanup. Spawns a background thread that
-- loops 'stReceive' + 'parseSignalEnvelope', allow-lists the sender, and
-- pushes @(MessageSource, body)@ to 'scInbox'. On transport close or
-- exception, the thread exits. The action runs with the channel; on exit
-- the transport is closed and the reader is killed.
withSignalChannel
  :: (AllowList UserId, Int)
  -> SignalAccount
  -> SignalTransport
  -> SealLogger
  -> (SignalChannel -> IO a)
  -> IO a
withSignalChannel (allow, chunkLimit) account transport logger action =
  bracket before after (action . snd)
  where
    before = do
      inbox      <- newTQueueIO
      lastSender <- newIORef Nothing
      alive      <- newIORef True
      let ch = SignalChannel
            { scAllowList  = allow
            , scChunkLimit = chunkLimit
            , scAccount    = account
            , scInbox      = inbox
            , scTransport  = transport
            , scLastSender = lastSender
            , scReaderAlive = alive
            , scLogger     = logger
            }
      tid <- forkIO (readerLoop ch)
      pure (tid, ch)
    after (tid, _ch) = do
      killThread tid
      stClose transport

-- | The background reader: loop 'stReceive', parse each inbound value,
-- allow-list the sender, and push to the inbox. A malformed line or a
-- non-allow-listed sender is logged via 'logIO' and dropped (not fatal).
-- Exits when 'stReceive' returns 'Left' (the channel is closing).
-- 'ThreadKilled' is logged at 'InfoS' (normal shutdown); other
-- 'AsyncException's at 'WarningS'; synchronous exceptions at 'ErrorS'.
readerLoop :: SignalChannel -> IO ()
readerLoop ch = go
  where
    logger = scLogger ch
    go = do
      eVal <- try @SomeException (stReceive (scTransport ch))
      case eVal of
        Left e -> do
          case (fromException e :: Maybe AsyncException) of
            Just ThreadKilled ->
              logIO logger InfoS "reader thread stopped (channel shutting down)"
            Just _ ->
              logIO logger WarningS ("reader thread terminated by async exception: " <> ls (T.pack (show e)))
            Nothing ->
              logIO logger ErrorS ("reader thread exception: " <> ls (T.pack (show e)))
          writeIORef (scReaderAlive ch) False
        Right (Left err) -> do
          logIO logger ErrorS ("reader exiting: " <> ls err)
          writeIORef (scReaderAlive ch) False
        Right (Right val) -> do
          case parseSignalEnvelope val of
            Left err -> logIO logger WarningS ("envelope parse error: " <> ls err)
            Right env -> do
              let sender = seSender env
              if isAllowed sender (scAllowList ch)
                then do
                  case mkMessageSource (seConversationId env) Signal (Just sender) mempty of
                    Left err -> logIO logger WarningS ("MessageSource construction failed: " <> ls err)
                    Right ms -> do
                      writeIORef (scLastSender ch) (Just sender)
                      atomically (writeTQueue (scInbox ch) (ms, seBody env))
                else logIO logger InfoS ("dropped non-allow-listed sender: " <> ls (userIdText sender))
          go

-- | Send a message, chunked to 'scChunkLimit', addressed to the last sender.
-- If no peer has been seen yet, the send is dropped with a warning log.
sendChunked :: SignalChannel -> Text -> IO ()
sendChunked ch t = do
  mSender <- readIORef (scLastSender ch)
  case mSender of
    Nothing -> logIO (scLogger ch) WarningS "signal: dropping send — no last sender yet"
    Just _  -> mapM_ (sendRaw ch) (chunkMessage (scChunkLimit ch) t)

-- | Send one chunk verbatim to the last sender (no further splitting).
-- Used by 'chSendChunk' (the caller pre-split) and by 'sendChunked' for
-- each split chunk. Addressed to the last sender.
sendRaw :: SignalChannel -> Text -> IO ()
sendRaw ch t = do
  mSender <- readIORef (scLastSender ch)
  case mSender of
    Nothing -> logIO (scLogger ch) WarningS "signal: dropping chunk — no last sender yet"
    Just uid -> stSend (scTransport ch) (userIdText uid) t

-- | Pull the next @(MessageSource, body)@ from the inbox. Non-blocking:
-- returns @(Nothing, "")@ when the inbox is empty AND the reader thread has
-- exited (transport closed / EOF). Returns @(Nothing, "")@ immediately in
-- that state so 'runSignalLoop' can terminate rather than block forever.
receiveFromInbox :: SignalChannel -> IO (Maybe MessageSource, Text)
receiveFromInbox ch = do
  mNext <- atomically (tryReadTQueue (scInbox ch))
  case mNext of
    Just (ms, body) -> pure (Just ms, body)
    Nothing -> do
      alive <- readIORef (scReaderAlive ch)
      if alive
        then do
          -- Inbox momentarily empty but reader still running: retry once
          -- after a brief yield to let the reader push the next envelope.
          -- (A real transport blocks in stReceive; a mock drains fast.)
          threadDelay 1000  -- 1ms
          receiveFromInbox ch
        else pure (Nothing, "")