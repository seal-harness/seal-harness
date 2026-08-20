{-# LANGUAGE OverloadedStrings #-}
-- | The WebSocket stream endpoint. Runs on a separate port from the REST +
-- static WARP server (the @wai-app-websockets@ bridge isn't available; a
-- separate port is the clean 7a path). Every connection is gated by the
-- Origin allowlist + the broker's global cap. The wire protocol: on
-- connect, a one-shot @hello@ (carrying @protocolVersion@ +
-- @serverStartedAt@ so the client can detect server restarts); then a
-- reader/writer race forwards 'BrokerEvent's from the broker to the WS
-- peer while accepting @focus@ ops from the client.
--
-- When a @focus@ op carries a @since@ field (an entry id), the server
-- replays all transcript entries after that id from disk, sends them as
-- @entry@ events, then sends a @replay-end@ event so the client transitions
-- from @replaying@ back to @live@. This closes the gap: entries broadcast
-- while the WS was disconnected are no longer permanently lost.
module Seal.Gateway.Stream
  ( runStreamServer
  , StreamGuard (..)
  , FocusOp (..)
  , filterAfterId
  , extractId
  ) where

import Control.Applicative ((<|>))
import Control.Exception (SomeException, catch)
import Control.Monad (forever, forM_)
import Data.Maybe (fromMaybe)
import Data.Aeson (object, (.=), (.:), (.:?))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.CaseInsensitive qualified as CI
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (getCurrentTime)
import Network.WebSockets
  ( PendingConnection, acceptRequest, receiveData, sendTextData
  , withPingThread, sendClose, Connection )
import Network.WebSockets qualified as WS

import Katip (Severity (..), ls)
import Seal.Config.Paths (SealPaths)
import Seal.Core.Types (mkSessionId, sessionIdText, SessionId)
import Seal.Core.TurnEngine (loadSessionMeta)
import Seal.Gateway.Broadcast (broadcastListsSnapshot)
import Seal.Gateway.StreamBroker
  ( BrokerEvent (..), StreamBroker, subscribe, updateSubscriberSession )
import Seal.Gateway.Transcript (readTranscriptEntries, showIso)
import Seal.Logging.Global (globalLogIO)
import Seal.Session.Meta (smModel, smCreatedAt)
import Seal.Tabs (TabsHandle)

-- | The per-connection guard: the Origin allowlist + the global cap.
-- Also carries the TabsHandle + SealPaths so the stream can send an
-- initial @lists@ snapshot on connect (the frontend's @wsListsReceived@
-- flag requires at least one @lists@ frame to switch from polling to WS).
data StreamGuard = StreamGuard
  { sgAllowedOrigins :: [Text]
  , sgGlobalCap :: Int
  , sgTabsHandle :: TabsHandle
  , sgPaths :: SealPaths
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
    Just o                    -> globalLogIO InfoS ("ws: rejected Origin " <> ls (T.pack (show o)))
  where
    acceptConn = do
      conn <- acceptRequest pending
      startedAt <- getCurrentTime
      sendTextData conn (A.encode (object
        [ "type" .= ("hello" :: Text)
        , "protocolVersion" .= ("v1" :: Text)
        , "serverStartedAt" .= T.pack (showIso startedAt)
        ]))
      let sendEvent (BeEntryRecorded sid v) =
            sendTextData conn (A.encode (object
              [ "type" .= ("entry" :: Text)
              , "sessionId" .= sessionIdText sid
              , "entry" .= v
              ]))
          sendEvent (BeHarnessStatus v)    = sendTextData conn (A.encode v)
          sendEvent (BeListsSnapshot v)    = sendTextData conn (A.encode v)
          sendEvent (BeActivity sid v)     =
            sendTextData conn (A.encode (object
              [ "type" .= ("activity" :: Text)
              , "sessionId" .= sessionIdText sid
              , "activity" .= v
              ]))
          sendEvent (BeAsk sid v)          =
            sendTextData conn (A.encode (object
              [ "type" .= ("ask" :: Text)
              , "sessionId" .= sessionIdText sid
              , "ask" .= v
              ]))
          sendEvent (BeAskResolved sid v)  =
            sendTextData conn (A.encode (object
              [ "type" .= ("ask_resolved" :: Text)
              , "sessionId" .= sessionIdText sid
              , "ask" .= v
              ]))
          sendEvent BeAgentDefsChanged =
            sendTextData conn (A.encode (object
              [ "type" .= ("agent-defs-changed" :: Text)
              ]))
          sendEvent BeSkillsChanged =
            sendTextData conn (A.encode (object
              [ "type" .= ("skills-changed" :: Text)
              ]))
          sendEvent BeReposChanged =
            sendTextData conn (A.encode (object
              [ "type" .= ("repos-changed" :: Text)
              ]))
      let defaultSid = case mkSessionId "default" of Right s -> s; Left _ -> error "sid"
          closeConn = sendClose conn ("subscriber evicted" :: Text)
      subSessionRef <- subscribe broker defaultSid sendEvent closeConn
      globalLogIO InfoS "[ws] connected, initial focus=default"
      -- Send an initial lists snapshot AFTER subscribing so this connection
      -- is in the broker's subscriber list and actually receives the frame.
      -- Without this, the snapshot is broadcast to zero subscribers, the
      -- frontend never flips wsLive, and REST /api/lists polling stays on.
      broadcastListsSnapshot broker (sgTabsHandle guard) (sgPaths guard)
      withPingThread conn 30 (pure ()) $ do
        let readerLoop = forever $ do
              msg <- receiveData conn
              case A.decode msg of
                Just (focusOp :: FocusOp) ->
                  case mkSessionId (foSession focusOp) of
                    Right s  -> do
                      globalLogIO InfoS ("[ws] focus → " <> ls (sessionIdText s))
                      updateSubscriberSession subSessionRef s
                      -- When the client sends a `since` entry id, replay
                      -- all transcript entries after that id from disk so
                      -- entries broadcast during the WS gap are recovered.
                      forM_ (foSince focusOp) $ \sinceId ->
                        replayEntriesSince conn (sgPaths guard) s sinceId
                    Left _e  -> sendTextData conn (A.encode (object ["type" .= ("error" :: Text), "message" .= ("invalid session id" :: Text)]))
                Nothing -> sendTextData conn (A.encode (object ["type" .= ("error" :: Text), "message" .= ("expected a focus op" :: Text)]))
        readerLoop `catch` \(_e :: SomeException) -> pure ()

-- | Replay transcript entries after the given entry id, then send a
-- @replay-end@ event so the client transitions from @replaying@ to @live@.
-- Reads the full transcript from disk and filters to entries whose id is
-- strictly after @sinceId@ (by position — the entry id is compared as a
-- string, and entries with ids lexicographically greater than @sinceId@
-- are sent). The frontend dedupes by id so any overlap with entries the
-- client already has is harmless. Errors during replay are logged and
-- swallowed (the client will still receive @replay-end@ and transition to
-- @live@, falling back to the HTTP seed for any missing entries).
--
-- Entry ids are either the on-disk @teId@ (a Text) or a synthetic index
-- (@\"0\"@, @\"1\"@, ...) when the two-file format has no per-entry id. We
-- compare by the @id@ field in the frontend JSON shape, which is the same
-- shape @readTranscriptEntries@ returns.
replayEntriesSince
  :: Connection -> SealPaths -> SessionId -> Text -> IO ()
replayEntriesSince conn paths sid sinceId = do
  let go = do
        mMeta <- loadSessionMeta paths sid
        let model = maybe "" smModel mMeta
            fallbackTs = maybe "" (showIso . smCreatedAt) mMeta
        entries <- readTranscriptEntries paths model fallbackTs sid
        let after = filterAfterId sinceId entries
        forM_ after $ \entry -> do
          sendTextData conn (A.encode (object
            [ "type" .= ("entry" :: Text)
            , "sessionId" .= sessionIdText sid
            , "entry" .= entry
            ]))
        -- Send replay-end with the last replayed entry id (or null when
        -- no entries were replayed — the client keeps its current
        -- lastEntryId in that case).
        let mLastId = case reverse after of
              [] -> Nothing
              (last_ : _) -> Just (extractId last_)
        sendTextData conn (A.encode (object
          [ "type" .= ("replay-end" :: Text)
          , "sessionId" .= sessionIdText sid
          , "lastReplayedEntryId" .= mLastId
          ]))
  go `catch` \(e :: SomeException) -> do
    globalLogIO InfoS ("[ws] replay error: " <> ls (T.pack (show e)))
    -- Even on error, send replay-end so the client isn't stuck in
    -- replaying status. lastReplayedEntryId is null (no confirmed replay).
    sendTextData conn (A.encode (object
      [ "type" .= ("replay-end" :: Text)
      , "sessionId" .= sessionIdText sid
      , "lastReplayedEntryId" .= (Nothing :: Maybe Text)
      ]))

-- | Filter the frontend-shaped transcript entries to those whose @id@
-- field is strictly after @sinceId@. Entry ids from the two-file format
-- are synthetic line indices (@\"0\"@, @\"1\"@, ...) which sort
-- lexicographically the same as numerically for single-digit counts but
-- diverge for multi-digit (e.g. @\"10\"@ < @\"2\"@ lexically). To be
-- robust, we find the position of @sinceId@ in the list and take everything
-- after it; if not found, we fall back to sending all entries (the
-- frontend dedupes by id, so overlap is harmless — and this handles the
-- case where the client's @lastEntryId@ is from a different transcript
-- shape or the session was rebuilt).
filterAfterId :: Text -> [A.Value] -> [A.Value]
filterAfterId sinceId entries =
  fromMaybe entries (breakOnId sinceId entries)

-- | Find the position of the entry whose @id@ matches @sinceId@ and
-- return everything after it. Returns 'Nothing' when the id is not found.
breakOnId :: Text -> [A.Value] -> Maybe [A.Value]
breakOnId sinceId = go
  where
    go [] = Nothing
    go (v : vs) =
      if extractId v == sinceId
        then Just vs
        else go vs

-- | Extract the @id@ field from a frontend-shaped transcript entry JSON.
extractId :: A.Value -> Text
extractId v = case v of
  A.Object o -> case KeyMap.lookup (Key.fromText "id") o of
    Just (A.String t) -> t
    _                 -> ""
  _ -> ""

-- | The focus op the client sends to change its focused session. Accepts
-- both the frontend's shape (@{"op":"focus","sessionId":"..."}@) and the
-- legacy shape (@{"session":"..."}@) for robustness. The optional @since@
-- field requests replay of entries after the given entry id.
data FocusOp = FocusOp
  { foSession :: Text
  , foSince   :: Maybe Text
  }
  deriving stock (Eq, Show)

instance A.FromJSON FocusOp where
  parseJSON = A.withObject "focus" $ \o ->
    FocusOp
      <$> (o .: "sessionId" <|> o .: "session")
      <*> (o .:? "since")

-- | Look up a header value from the pending request headers (case-insensitive).
lookupHeader :: Text -> WS.RequestHead -> Maybe String
lookupHeader name req =
  case lookup (CI.mk (TE.encodeUtf8 $ T.toLower name)) (WS.requestHeaders req) of
    Just v  -> Just (T.unpack (TE.decodeUtf8 v))
    Nothing -> Nothing
