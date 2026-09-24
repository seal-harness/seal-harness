{-# LANGUAGE OverloadedStrings #-}
-- | WebSocket client for the gateway's stream server. Connects, sends
-- @FocusOp@s to change the focused session, and spawns a background thread
-- that decodes incoming @ServerEvent@s and calls a callback for each.
--
-- One WS connection per conversation (per the design's open question #4).
-- The connection's focused session changes on @/N@ focus.
module Seal.Channels.Chat.WsClient
  ( WsClient (..)
  , startWsClient
  , WsEventCallback
  ) where

import Control.Concurrent (forkIO)
import Control.Monad (void)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Network.WebSockets
  (ClientApp, Connection, receiveData, runClient, sendTextData, sendClose)
import System.Timeout (timeout)

import Seal.Gateway.Types.Core (SessionId, sessionIdText)
import Seal.Gateway.Types.Stream
  (FocusOp (..), ServerEvent, decodeServerEvent)

-- | The callback the background reader calls for each decoded 'ServerEvent'.
type WsEventCallback = ServerEvent -> IO ()

-- | A handle to a running WS client connection.
data WsClient = WsClient
  { wcFocus      :: SessionId -> IO ()
    -- ^ Send a 'FocusOp' for the given session (change focus).
  , wcFocusSince :: SessionId -> Maybe Text -> IO ()
    -- ^ Send a 'FocusOp' with an optional @since@ entry id (for replay).
  , wcClose      :: IO ()
    -- ^ Close the WS connection and stop the background reader.
  }

-- | Connect to the gateway's WS server. Forks the connection in a
-- background thread and returns a 'WsClient' handle immediately. Returns
-- 'Left' if the connection fails within 5 seconds.
startWsClient
  :: Text    -- ^ Host (e.g. @"127.0.0.1"@)
  -> Int     -- ^ Port (e.g. 8081)
  -> WsEventCallback
  -> IO (Either Text WsClient)
startWsClient host port callback = do
  connRef <- newIORef Nothing
  readyVar <- newEmptyMVar
  let app :: ClientApp ()
      app conn = do
        writeIORef connRef (Just conn)
        putMVar readyVar ()
        readerLoop conn callback
  -- Fork the client connection so we can return immediately.
  _ <- forkIO $ void (try (runClient (T.unpack host) port "/" app) :: IO (Either SomeException ()))
  -- Wait up to 5s for the connection to be established.
  mReady <- timeout 5000000 (takeMVar readyVar)
  case mReady of
    Nothing -> pure (Left ("WS connect timeout: " <> host <> ":" <> T.pack (show port)))
    Just () -> do
      let client = WsClient
            { wcFocus = \sid -> sendFocusOpRef connRef sid Nothing
            , wcFocusSince = sendFocusOpRef connRef
            , wcClose = closeConnRef connRef
            }
      pure (Right client)

-- | The read loop: decode incoming frames, call the callback for each.
-- Exits when the connection closes or an error occurs.
readerLoop :: Connection -> WsEventCallback -> IO ()
readerLoop conn callback = go
  where
    go = do
      eData <- try (receiveData conn) :: IO (Either SomeException BL.ByteString)
      case eData of
        Left _ -> pure ()  -- connection closed
        Right bs ->
          case decodeServerEvent bs of
            Just ev -> callback ev >> go
            Nothing -> go  -- unparseable frame; skip

-- | Send a 'FocusOp' via the connection stored in the 'IORef'.
sendFocusOpRef :: IORef (Maybe Connection) -> SessionId -> Maybe Text -> IO ()
sendFocusOpRef ref sid mSince = do
  mConn <- readIORef ref
  case mConn of
    Nothing -> pure ()  -- connection not established or closed
    Just conn -> sendFocusOp conn sid mSince

-- | Close the connection stored in the 'IORef'.
closeConnRef :: IORef (Maybe Connection) -> IO ()
closeConnRef ref = do
  mConn <- readIORef ref
  case mConn of
    Nothing -> pure ()
    Just conn -> do
      _ <- try (sendClose conn ("client closed" :: Text)) :: IO (Either SomeException ())
      writeIORef ref Nothing

-- | Send a 'FocusOp' over the WS connection.
sendFocusOp :: Connection -> SessionId -> Maybe Text -> IO ()
sendFocusOp conn sid mSince =
  sendTextData conn (A.encode (FocusOp (sessionIdText sid) mSince))
