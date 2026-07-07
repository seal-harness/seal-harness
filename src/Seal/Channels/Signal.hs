{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
-- | The Signal channel: a 'SignalChannel' record (resolved allow-list +
-- chunk limit + account + inbox 'TQueue' + transport + last-sender 'IORef')
-- and its 'Channel' instance. The reader thread parses signal-cli output,
-- allow-lists the sender, and pushes envelopes to the inbox; sends are
-- chunked via 'Seal.Channels.Signal.Transport.chunkMessage' to the
-- configured limit and addressed to the last sender.
module Seal.Channels.Signal
  ( SignalChannel (..)
  , withSignalChannel
  ) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.STM (TQueue, atomically, newTQueueIO, tryReadTQueue, writeTQueue)
import Control.Exception (bracket, SomeException, try)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import System.IO (hPutStrLn, stderr)

import Seal.Channels.Class (Channel (..))
import Seal.Channels.Signal.Transport
  ( SignalEnvelope (..), SignalTransport (..), chunkMessage, parseSignalEnvelope )
import Seal.Core.AllowList (AllowList (..), isAllowed)
import Seal.Core.ChannelKind (ChannelKind (..))
import Seal.Core.MessageSource
  ( MessageSource, UserId, mkMessageSource, userIdText )
import Seal.Handles.Channel (ChannelHandle (..), Deferral (..))
import Seal.Signal.Config (SignalAccount (..))

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
  }

instance Channel SignalChannel where
  toHandle ch = ChannelHandle
    { chSend         = sendChunked ch
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
  -> (SignalChannel -> IO a)
  -> IO a
withSignalChannel (allow, chunkLimit) account transport action =
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
            }
      tid <- forkIO (readerLoop ch)
      pure (tid, ch)
    after (tid, _ch) = do
      killThread tid
      stClose transport

-- | The background reader: loop 'stReceive', parse each inbound value,
-- allow-list the sender, and push to the inbox. A malformed line or a
-- non-allow-listed sender is logged to stderr and dropped (not fatal).
-- Exits when 'stReceive' returns 'Left' repeatedly — but to keep the loop
-- from spinning on a permanently-empty mock inbox, a 'Left' breaks the
-- loop (the channel is closing anyway). For a real transport, a closed
-- stdout EOF is the natural exit.
readerLoop :: SignalChannel -> IO ()
readerLoop ch = go
  where
    go = do
      eVal <- try @SomeException (stReceive (scTransport ch))
      case eVal of
        Left e -> do
          logErr ("reader thread exception: " <> T.pack (show e))
          writeIORef (scReaderAlive ch) False
        Right (Left err) -> do
          -- Transport reports an error / closed inbox. Stop the reader so
          -- 'chReceive' can return EOF rather than block forever.
          logErr ("reader exiting: " <> err)
          writeIORef (scReaderAlive ch) False
        Right (Right val) -> do
          case parseSignalEnvelope val of
            Left err -> logErr ("envelope parse error: " <> err)
            Right env -> do
              let sender = seSender env
              if isAllowed sender (scAllowList ch)
                then do
                  case mkMessageSource (seConversationId env) Signal (Just sender) mempty of
                    Left err -> logErr ("MessageSource construction failed: " <> err)
                    Right ms -> do
                      writeIORef (scLastSender ch) (Just sender)
                      atomically (writeTQueue (scInbox ch) (ms, seBody env))
                else logErr ("dropped non-allow-listed sender: " <> userIdText sender)
          go
    logErr t = hPutStrLn stderr (T.unpack t)

-- | Send a message, chunked to 'scChunkLimit', addressed to the last sender.
-- If no peer has been seen yet, the send is dropped with a stderr log.
sendChunked :: SignalChannel -> Text -> IO ()
sendChunked ch t = do
  mSender <- readIORef (scLastSender ch)
  case mSender of
    Nothing -> hPutStrLn stderr "signal: dropping send — no last sender yet"
    Just _  -> mapM_ (sendRaw ch) (chunkMessage (scChunkLimit ch) t)

-- | Send one chunk verbatim to the last sender (no further splitting).
-- Used by 'chSendChunk' (the caller pre-split) and by 'sendChunked' for
-- each split chunk. Addressed to the last sender.
sendRaw :: SignalChannel -> Text -> IO ()
sendRaw ch t = do
  mSender <- readIORef (scLastSender ch)
  case mSender of
    Nothing -> hPutStrLn stderr "signal: dropping chunk — no last sender yet"
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