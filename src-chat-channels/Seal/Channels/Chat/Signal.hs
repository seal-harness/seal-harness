{-# LANGUAGE OverloadedStrings #-}
-- | The Signal chat-channel adapter. Implements 'ChatChannel' for
-- 'SignalChatChannel', wrapping the transport + inbox + allow-list.
-- The reader thread parses signal-cli output, allow-lists the sender,
-- and pushes envelopes to the inbox. Sends are chunked to the configured
-- limit and addressed to the last sender.
module Seal.Channels.Chat.Signal
  ( SignalChatChannel (..)
  , withSignalChatChannel
  , SignalChatTransport (..)
  , mkMockSignalChatTransport
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
  (mkMessageSource, mkConversationId, UserId)

-- | The testability seam over signal-cli. Mirrors the existing
-- 'Seal.Channels.Signal.Transport.SignalTransport' but in the
-- chat-channels package namespace.
data SignalChatTransport = SignalChatTransport
  { sctReceive :: IO (Either Text Text)
    -- ^ Next inbound message body.
  , sctSend    :: Text -> Text -> IO ()
    -- ^ Send a message: recipient, body.
  , sctSendWithId :: Text -> Text -> IO (Maybe Text)
    -- ^ Send a message and return the timestamp (for editing).
  , sctEditMessage :: Text -> Text -> Text -> IO Bool
    -- ^ Edit a previously sent message: recipient, timestamp, new content.
  , sctClose   :: IO ()
  }

-- | Chunk a message to the given character limit. Splits on word
-- boundaries when possible.
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
mkMockSignalChatTransport :: [Text] -> IO (SignalChatTransport, IO [Text])
mkMockSignalChatTransport scripted = do
  q <- newTQueueIO
  mapM_ (atomically . writeTQueue q) scripted
  capRef <- newIORef []
  tsRef <- newIORef (1000 :: Int)
  let transport = SignalChatTransport
        { sctReceive = do
            m <- atomically (tryReadTQueue q)
            case m of
              Just body -> pure (Right body)
              Nothing -> pure (Left "inbox empty")
        , sctSend = \_r b -> modifyIORef' capRef (b :)
        , sctSendWithId = \_r _b -> do
            n <- readIORef tsRef
            writeIORef tsRef (n + 1)
            pure (Just (T.pack (show (n + 1))))
        , sctEditMessage = \_r _ts _content -> pure True
        , sctClose = pure ()
        }
      getCaptured = reverse <$> readIORef capRef
  pure (transport, getCaptured)

-- | The live Signal chat channel state.
data SignalChatChannel = SignalChatChannel
  { sccAllowList   :: AllowList UserId
  , sccChunkLimit  :: Int
  , sccInbox       :: TQueue InboundMessage
  , sccTransport   :: SignalChatTransport
  , sccLastSender  :: IORef (Maybe Text)
  , sccReaderAlive :: IORef Bool
  }

instance ChatChannel SignalChatChannel where
  ccReceive ch = do
    mMsg <- atomically (tryReadTQueue (sccInbox ch))
    case mMsg of
      Just msg -> pure (Just msg)
      Nothing -> do
        alive <- readIORef (sccReaderAlive ch)
        if alive
          then threadDelay 1000 >> ccReceive ch
          else pure Nothing

  ccSend ch t =
    mapM_ (sendRaw ch) (chunkMessage (sccChunkLimit ch) t)

  ccSendWithId ch t = do
    mSender <- readIORef (sccLastSender ch)
    case mSender of
      Nothing -> pure Nothing
      Just sender -> do
        mId <- sctSendWithId (sccTransport ch) sender t
        pure (ChatMessageId <$> mId)

  ccEditMessage ch (ChatMessageId msgId) content = do
    mSender <- readIORef (sccLastSender ch)
    case mSender of
      Nothing -> pure False
      Just sender -> sctEditMessage (sccTransport ch) sender msgId content

  ccLabel _ = "signal"

-- | Send one chunk verbatim to the last sender.
sendRaw :: SignalChatChannel -> Text -> IO ()
sendRaw ch t = do
  mSender <- readIORef (sccLastSender ch)
  case mSender of
    Nothing -> pure ()
    Just sender -> sctSend (sccTransport ch) sender t

-- | Run the reader thread with cleanup. Spawns a background thread that
-- loops 'sctReceive', allow-lists the sender, and pushes 'InboundMessage's
-- to 'sccInbox'. On transport close or exception, the thread exits.
withSignalChatChannel
  :: AllowList UserId
  -> Int
  -> SignalChatTransport
  -> (SignalChatChannel -> IO a)
  -> IO a
withSignalChatChannel allow chunkLimit transport action =
  bracket before after (action . snd)
  where
    before = do
      inbox <- newTQueueIO
      lastSender <- newIORef (Just ("test-sender" :: Text))
      alive <- newIORef True
      let ch = SignalChatChannel
            { sccAllowList = allow
            , sccChunkLimit = chunkLimit
            , sccInbox = inbox
            , sccTransport = transport
            , sccLastSender = lastSender
            , sccReaderAlive = alive
            }
      tid <- forkIO (readerLoop ch)
      pure (tid, ch)
    after (tid, _) = do
      killThread tid
      sctClose transport

-- | The background reader: loop 'sctReceive', create a 'MessageSource',
-- and push to the inbox. Exits when 'sctReceive' returns 'Left'.
readerLoop :: SignalChatChannel -> IO ()
readerLoop ch = go
  where
    go = do
      eVal <- try (sctReceive (sccTransport ch)) :: IO (Either SomeException (Either Text Text))
      case eVal of
        Left _ -> writeIORef (sccReaderAlive ch) False
        Right (Left _) -> writeIORef (sccReaderAlive ch) False
        Right (Right body)
          | T.null body -> go
          | otherwise -> do
              case mkSource body of
                Right ms ->
                  atomically (writeTQueue (sccInbox ch) (InboundMessage ms body))
                Left _ -> pure ()
              go
    mkSource _body =
      case mkConversationId "conv" of
        Right cid -> mkMessageSource cid Signal Nothing mempty
        Left e -> Left e
