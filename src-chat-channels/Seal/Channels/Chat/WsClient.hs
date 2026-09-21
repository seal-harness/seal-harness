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

import Control.Concurrent.MVar (newEmptyMVar, putMVar, tryTakeMVar)
import Control.Exception (SomeException, try)
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Network.WebSockets
  (ClientApp, Connection, receiveData, runClient, sendTextData, sendClose)

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

-- | Connect to the gateway's WS server. Spawns a background thread that
-- reads events and calls the callback for each. Returns 'Left' if the
-- connection fails.
startWsClient
  :: Text    -- ^ Host (e.g. @"127.0.0.1"@)
  -> Int     -- ^ Port (e.g. 8081)
  -> WsEventCallback
  -> IO (Either Text WsClient)
startWsClient host port callback = do
  connVar <- newEmptyMVar
  let app :: ClientApp ()
      app conn = do
        -- Store the connection so the main thread can build the WsClient.
        putMVar connVar conn
        -- Run the reader loop in this thread (blocks until connection closes).
        readerLoop conn callback
  -- Run the client in a background thread so we can return the WsClient
  -- handle immediately after the connection is established.
  -- The connVar is filled once 'app' receives the Connection.
  _ <- try (runClient (T.unpack host) port "/" app) :: IO (Either SomeException ())
  -- Try to get the connection — if it was filled, we connected successfully.
  mConn <- tryTakeMVar connVar
  case mConn of
    Nothing -> pure (Left ("WS connect failed: " <> host <> ":" <> T.pack (show port)))
    Just conn -> do
      -- Re-put the connection so close can access it.
      putMVar connVar conn
      let client = WsClient
            { wcFocus = \sid -> sendFocusOp conn sid Nothing
            , wcFocusSince = sendFocusOp conn
            , wcClose = do
                _ <- try (sendClose conn ("client closed" :: Text)) :: IO (Either SomeException ())
                pure ()
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

-- | Send a 'FocusOp' over the WS connection.
sendFocusOp :: Connection -> SessionId -> Maybe Text -> IO ()
sendFocusOp conn sid mSince =
  sendTextData conn (A.encode (FocusOp (sessionIdText sid) mSince))
