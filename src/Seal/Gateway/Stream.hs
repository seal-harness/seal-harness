{-# LANGUAGE OverloadedStrings #-}
-- | The WebSocket stream endpoint. Runs on a separate port from the REST +
-- static WARP server (the @wai-app-websockets@ bridge isn't available; a
-- separate port is the clean 7a path). Every connection is gated by the
-- Origin allowlist + the broker's global cap. The wire protocol: on
-- connect, a one-shot @hello@; then a reader/writer race forwards
-- 'BrokerEvent's from the broker to the WS peer while accepting @focus@
-- ops from the client.
module Seal.Gateway.Stream
  ( runStreamServer
  , StreamGuard (..)
  ) where

import Control.Exception (SomeException, catch)
import Control.Monad (forever)
import Data.Aeson (object, (.=), (.:))
import Data.Aeson qualified as A
import Data.CaseInsensitive qualified as CI
import Data.IORef (newIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.WebSockets
  ( PendingConnection, acceptRequest, receiveData, sendTextData
  , withPingThread )
import Network.WebSockets qualified as WS
import System.IO (hPutStrLn, stderr)

import Seal.Core.Types (mkSessionId)
import Seal.Gateway.StreamBroker
  ( BrokerEvent (..), StreamBroker, subscribe )

-- | The per-connection guard: the Origin allowlist + the global cap.
data StreamGuard = StreamGuard
  { sgAllowedOrigins :: [Text]
  , sgGlobalCap :: Int
  }

-- | Run the WebSocket stream server on the given port. Blocks (run in a
-- forked thread from @seal serve@).
runStreamServer :: Text -> Int -> StreamGuard -> StreamBroker -> IO ()
runStreamServer host port guard broker =
  WS.runServer (T.unpack host) port (streamApp guard broker)

-- | The per-connection WS app: check the Origin, accept, send hello, then
-- race the broker-forwarder against the focus-reader.
streamApp :: StreamGuard -> StreamBroker -> PendingConnection -> IO ()
streamApp guard broker pending = do
  let reqHead = WS.pendingRequest pending
      origin = lookupHeader "origin" reqHead
      allowed = map T.unpack (sgAllowedOrigins guard)
  case origin of
    Nothing                   -> acceptConn  -- no Origin header (local dev client); accept
    Just _  | null allowed    -> acceptConn  -- wildcard mode (host=0.0.0.0); accept any
    Just o | o `elem` allowed -> acceptConn
    Just o                    -> hPutStrLn stderr ("ws: rejected Origin " <> show o)
  where
    acceptConn = do
      conn <- acceptRequest pending
      sendTextData conn (A.encode (object ["type" .= ("hello" :: Text)]))
      let sendEvent (BeEntryRecorded _ v)   = sendTextData conn (A.encode v)
          sendEvent (BeHarnessStatus v)    = sendTextData conn (A.encode v)
          sendEvent (BeListsSnapshot v)    = sendTextData conn (A.encode v)
      let defaultSid = case mkSessionId "default" of Right s -> s; Left _ -> error "sid"
      subscribe broker defaultSid sendEvent
      sessionRef <- newIORef defaultSid
      withPingThread conn 30 (pure ()) $ do
        let readerLoop = forever $ do
              msg <- receiveData conn
              case A.decode msg of
                Just (focusOp :: FocusOp) ->
                  case mkSessionId (foSession focusOp) of
                    Right s  -> writeIORef sessionRef s
                    Left _e  -> sendTextData conn (A.encode (object ["type" .= ("error" :: Text), "message" .= ("invalid session id" :: Text)]))
                Nothing -> sendTextData conn (A.encode (object ["type" .= ("error" :: Text), "message" .= ("expected a focus op" :: Text)]))
        readerLoop `catch` \(_e :: SomeException) -> pure ()

-- | The focus op the client sends to change its focused session.
newtype FocusOp = FocusOp { foSession :: Text }
  deriving stock (Eq, Show)

instance A.FromJSON FocusOp where
  parseJSON = A.withObject "focus" $ \o -> FocusOp <$> o .: "session"

-- | Look up a header value from the pending request headers (case-insensitive).
lookupHeader :: Text -> WS.RequestHead -> Maybe String
lookupHeader name req =
  case lookup (CI.mk (TE.encodeUtf8 $ T.toLower name)) (WS.requestHeaders req) of
    Just v  -> Just (T.unpack (TE.decodeUtf8 v))
    Nothing -> Nothing