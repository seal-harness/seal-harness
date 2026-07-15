{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
-- | The Telegram channel: a 'TelegramChannel' record (resolved allow-list +
-- chunk limit + inbox 'TQueue' + transport + last-sender 'IORef') and its
-- 'Channel' instance. The reader thread loops 'tgReceive', allow-lists the
-- sender, and pushes @(MessageSource, body)@ to the inbox; sends are
-- chunked via 'Seal.Channels.Telegram.Transport.chunkMessage' to the
-- configured limit and addressed to the last sender's chat id. Mirrors
-- "Seal.Channels.Signal" in structure.
module Seal.Channels.Telegram
  ( TelegramChannel (..)
  , withTelegramChannel
  ) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.STM
  (TQueue, atomically, newTQueueIO, tryReadTQueue, writeTQueue)
import Control.Exception (bracket, SomeException, try)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import System.IO (hPutStrLn, stderr)

import Seal.Channels.Class (Channel (..))
import Seal.Channels.Telegram.Transport
  ( TelegramTransport (..), TelegramUpdate (..), chunkMessage )
import Seal.Core.AllowList (AllowList (..), isAllowed)
import Seal.Core.ChannelKind (ChannelKind (..))
import Seal.Core.MessageSource
  ( MessageSource, UserId, mkMessageSource, userIdText )
import Seal.Handles.Channel (ChannelHandle (..), Deferral (..))

-- | The live Telegram channel state.
data TelegramChannel = TelegramChannel
  { tcgAllowList   :: AllowList UserId   -- ^ resolved sender allow-list
  , tcgChunkLimit  :: Int                -- ^ chunk limit for sends
  , tcgInbox       :: TQueue (MessageSource, Text)
  , tcgTransport   :: TelegramTransport
  , tcgLastChat    :: IORef (Maybe Text)  -- ^ last sender's chat id (for replies)
  , tcgReaderAlive :: IORef Bool
    -- ^ 'True' while the reader thread is running. 'chReceive' stops
    -- returning once the inbox drains and this is 'False'.
  }

instance Channel TelegramChannel where
  toHandle ch = ChannelHandle
    { chSend         = sendChunked ch
    , chSendError    = \t -> sendChunked ch ("error: " <> t)
    , chSendChunk    = sendRaw ch
    , chPrompt       = \_ -> pure (Left Deferred)  -- Telegram can't answer inline
    , chPromptSecret = \_ -> pure (Left Deferred)
    , chStreaming    = True
    , chReadSecret   = pure Nothing
    , chReceive      = receiveFromInbox ch
    }

-- | Run the reader thread with cleanup. Spawns a background thread that
-- loops 'tgReceive', allow-lists the sender, and pushes
-- @(MessageSource, body)@ to 'tcgInbox'. On transport close or exception,
-- the thread exits. The action runs with the channel; on exit the transport
-- is closed and the reader is killed. Mirrors 'withSignalChannel'.
withTelegramChannel
  :: (AllowList UserId, Int)
  -> TelegramTransport
  -> (TelegramChannel -> IO a)
  -> IO a
withTelegramChannel (allow, chunkLimit) transport action =
  bracket before after (action . snd)
  where
    before = do
      inbox   <- newTQueueIO
      lastChat <- newIORef Nothing
      alive   <- newIORef True
      let ch = TelegramChannel
            { tcgAllowList   = allow
            , tcgChunkLimit  = chunkLimit
            , tcgInbox       = inbox
            , tcgTransport   = transport
            , tcgLastChat    = lastChat
            , tcgReaderAlive = alive
            }
      tid <- forkIO (readerLoop ch)
      pure (tid, ch)
    after (tid, _ch) = do
      killThread tid
      tgClose transport

-- | The background reader: loop 'tgReceive', allow-list the sender, and push
-- to the inbox. A malformed update or a non-allow-listed sender is logged to
-- stderr and dropped (not fatal). Exits when 'tgReceive' returns 'Left' (the
-- transport is closing).
readerLoop :: TelegramChannel -> IO ()
readerLoop ch = go
  where
    go = do
      eUpd <- try @SomeException (tgReceive (tcgTransport ch))
      case eUpd of
        Left e -> do
          logErr ("reader thread exception: " <> T.pack (show e))
          writeIORef (tcgReaderAlive ch) False
        Right (Left err) -> do
          logErr ("reader exiting: " <> err)
          writeIORef (tcgReaderAlive ch) False
        Right (Right upd) -> do
          let sender = tuSender upd
          if isAllowed sender (tcgAllowList ch)
            then do
              writeIORef (tcgLastChat ch) (Just (tuChatId upd))
              case mkMessageSource (tuConversationId upd) Telegram (Just sender) mempty of
                Left err -> logErr ("MessageSource construction failed: " <> err)
                Right ms -> atomically (writeTQueue (tcgInbox ch) (ms, tuBody upd))
            else logErr ("dropped non-allow-listed sender: " <> userIdText sender)
          go
    logErr t = hPutStrLn stderr (T.unpack t)

-- | Send a message, chunked to 'tcgChunkLimit', addressed to the last chat.
-- If no chat has been seen yet, the send is dropped with a stderr log.
sendChunked :: TelegramChannel -> Text -> IO ()
sendChunked ch t = do
  mChat <- readIORef (tcgLastChat ch)
  case mChat of
    Nothing -> hPutStrLn stderr "telegram: dropping send — no last chat yet"
    Just _  -> mapM_ (sendRaw ch) (chunkMessage (tcgChunkLimit ch) t)

-- | Send one chunk verbatim to the last chat (no further splitting).
sendRaw :: TelegramChannel -> Text -> IO ()
sendRaw ch t = do
  mChat <- readIORef (tcgLastChat ch)
  case mChat of
    Nothing -> hPutStrLn stderr "telegram: dropping chunk — no last chat yet"
    Just chatId -> tgSend (tcgTransport ch) chatId t

-- | Pull the next @(MessageSource, body)@ from the inbox. Non-blocking:
-- returns @(Nothing, "")@ when the inbox is empty AND the reader thread has
-- exited. Returns @(Nothing, "")@ immediately in that state so the loop can
-- terminate rather than block forever. Mirrors 'receiveFromInbox' in Signal.
receiveFromInbox :: TelegramChannel -> IO (Maybe MessageSource, Text)
receiveFromInbox ch = do
  mNext <- atomically (tryReadTQueue (tcgInbox ch))
  case mNext of
    Just (ms, body) -> pure (Just ms, body)
    Nothing -> do
      alive <- readIORef (tcgReaderAlive ch)
      if alive
        then do
          threadDelay 1000  -- 1ms
          receiveFromInbox ch
        else pure (Nothing, "")