{-# LANGUAGE OverloadedStrings #-}
-- | The Telegram chat-channel adapter. Implements 'ChatChannel' for
-- 'TelegramChatChannel', wrapping the transport + inbox + allow-list.
-- Mirrors the Signal adapter in structure.
module Seal.Channels.Chat.Telegram
  ( TelegramChatChannel (..)
  , withTelegramChatChannel
  , TelegramChatTransport (..)
  , mkMockTelegramChatTransport
  , chunkMessage
  ) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.STM
  (TQueue, atomically, newTQueueIO, tryReadTQueue, writeTQueue)
import Control.Exception (bracket, SomeException, try)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Channels.Chat.Class (ChatChannel (..))
import Seal.Channels.Chat.Types
  (InboundMessage (..), ChatMessageId (..))
import Seal.Gateway.Types.AllowList (AllowList (..))
import Seal.Gateway.Types.ChannelKind (ChannelKind (..))
import Seal.Gateway.Types.MessageSource
  (UserId, mkMessageSource, mkConversationId)

-- | The testability seam over the Telegram Bot API. Mirrors the existing
-- 'Seal.Channels.Telegram.Transport.TelegramTransport' but in the
-- chat-channels package namespace.
data TelegramChatTransport = TelegramChatTransport
  { tctReceive :: IO (Either Text Text)
    -- ^ Next inbound message body (from Bot API long-poll).
  , tctSend    :: Text -> Text -> IO ()
    -- ^ Send a message: chat id, body.
  , tctSendWithId :: Text -> Text -> IO (Maybe Text)
    -- ^ Send a message and return the message_id.
  , tctEditMessage :: Text -> Text -> Text -> IO Bool
    -- ^ Edit a previously sent message: chat id, message_id, new content.
  , tctClose   :: IO ()
  }

-- | Chunk a message to the given character limit. Telegram's hard limit
-- is 4096; we leave headroom.
chunkMessage :: Int -> Text -> [Text]
chunkMessage limit msg
  | T.length msg <= limit = [msg]
  | otherwise = go msg
  where
    go t
      | T.null t = []
      | T.length t <= limit = [t]
      | otherwise = T.take limit t : go (T.drop limit t)

-- | A mock transport backed by a 'TQueue' of inbound message bodies and
-- an 'IORef' of captured sends. For testing.
mkMockTelegramChatTransport :: [Text] -> IO (TelegramChatTransport, IO [Text])
mkMockTelegramChatTransport scripted = do
  q <- newTQueueIO
  mapM_ (atomically . writeTQueue q) scripted
  capRef <- newIORef []
  msgIdRef <- newIORef (0 :: Int)
  let transport = TelegramChatTransport
        { tctReceive = do
            m <- atomically (tryReadTQueue q)
            case m of
              Just body -> pure (Right body)
              Nothing -> pure (Left "inbox empty")
        , tctSend = \_c b -> modifyIORef' capRef (b :)
        , tctSendWithId = \_c _b -> do
            n <- readIORef msgIdRef
            writeIORef msgIdRef (n + 1)
            pure (Just (T.pack (show (n + 1))))
        , tctEditMessage = \_c _mid _content -> pure True
        , tctClose = pure ()
        }
      getCaptured = reverse <$> readIORef capRef
  pure (transport, getCaptured)

-- | The live Telegram chat channel state.
data TelegramChatChannel = TelegramChatChannel
  { tccAllowList  :: AllowList UserId
  , tccChunkLimit :: Int
  , tccInbox      :: TQueue InboundMessage
  , tccTransport  :: TelegramChatTransport
  , tccLastChat   :: IORef (Maybe Text)
  , tccReaderAlive :: IORef Bool
  }

instance ChatChannel TelegramChatChannel where
  ccReceive ch = do
    mMsg <- atomically (tryReadTQueue (tccInbox ch))
    case mMsg of
      Just msg -> pure (Just msg)
      Nothing -> do
        alive <- readIORef (tccReaderAlive ch)
        if alive
          then threadDelay 1000 >> ccReceive ch
          else pure Nothing

  ccSend ch t =
    mapM_ (sendRaw ch) (chunkMessage (tccChunkLimit ch) t)

  ccSendWithId ch t = do
    mChat <- readIORef (tccLastChat ch)
    case mChat of
      Nothing -> pure Nothing
      Just chatId -> do
        mId <- tctSendWithId (tccTransport ch) chatId t
        pure (ChatMessageId <$> mId)

  ccEditMessage ch (ChatMessageId msgId) content = do
    mChat <- readIORef (tccLastChat ch)
    case mChat of
      Nothing -> pure False
      Just chatId -> tctEditMessage (tccTransport ch) chatId msgId content

  ccLabel _ = "telegram"

-- | Send one chunk verbatim to the last chat.
sendRaw :: TelegramChatChannel -> Text -> IO ()
sendRaw ch t = do
  mChat <- readIORef (tccLastChat ch)
  case mChat of
    Nothing -> pure ()
    Just chatId -> tctSend (tccTransport ch) chatId t

-- | Run the reader thread with cleanup. Spawns a background thread that
-- loops 'tctReceive', allow-lists the sender, and pushes 'InboundMessage's
-- to 'tccInbox'. On transport close or exception, the thread exits.
withTelegramChatChannel
  :: AllowList UserId
  -> Int
  -> TelegramChatTransport
  -> (TelegramChatChannel -> IO a)
  -> IO a
withTelegramChatChannel allow chunkLimit transport action =
  bracket before after (action . snd)
  where
    before = do
      inbox <- newTQueueIO
      lastChat <- newIORef (Just ("test-chat" :: Text))
      alive <- newIORef True
      let ch = TelegramChatChannel
            { tccAllowList = allow
            , tccChunkLimit = chunkLimit
            , tccInbox = inbox
            , tccTransport = transport
            , tccLastChat = lastChat
            , tccReaderAlive = alive
            }
      tid <- forkIO (readerLoop ch)
      pure (tid, ch)
    after (tid, _) = do
      killThread tid
      tctClose transport

-- | The background reader: loop 'tctReceive', allow-list the sender, and
-- push to the inbox. Exits when 'tctReceive' returns 'Left'.
readerLoop :: TelegramChatChannel -> IO ()
readerLoop ch = go
  where
    go = do
      eVal <- try (tctReceive (tccTransport ch)) :: IO (Either SomeException (Either Text Text))
      case eVal of
        Left _ -> writeIORef (tccReaderAlive ch) False
        Right (Left _) -> writeIORef (tccReaderAlive ch) False
        Right (Right body)
          | not (T.null body) -> do
              case mkConversationId "conv" of
                Right cid ->
                  case mkMessageSource cid Telegram Nothing mempty of
                    Right ms -> atomically (writeTQueue (tccInbox ch) (InboundMessage ms body))
                    Left _ -> pure ()
                Left _ -> pure ()
              go
          | otherwise -> go
