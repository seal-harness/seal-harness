{-# LANGUAGE OverloadedStrings #-}
-- | The WebSocket stream endpoint. Runs on a separate port from the REST +
-- static WARP server. Every connection is gated by the
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
  , runStreamServerWithHealth
  , StreamGuard (..)
  , StreamHealth (..)
  , streamHealthStatus
  , streamHealthMessage
  , FocusOp (..)
  , handleRequestEntries
  , RequestEntriesOp (..)
  , ClientMessage (..)
  , filterAfterId
  , extractId
  , entriesBeforeId
  , clampLimit
  , sendErrorFrame
  ) where

import Control.Concurrent (forkIO)
import Control.Exception (SomeException, bracket, catch, try)
import Control.Monad (forever, forM_, void)
import Data.IORef (IORef, newIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.CaseInsensitive qualified as CI
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (getCurrentTime)
import Network.Socket (Socket)
import Network.Socket qualified as Sock
import Network.WebSockets
  ( PendingConnection, acceptRequest, receiveData, sendTextData
  , withPingThread, sendClose, Connection
  , defaultConnectionOptions, makeListenSocket, makePendingConnection )
import Network.WebSockets qualified as WS

import Katip (Severity (..), ls)
import Seal.Config.Paths (SealPaths)
import Seal.Core.Types (mkSessionId, sessionIdText, SessionId)
import Seal.Core.TurnEngine (loadSessionMeta)
import Seal.Gateway.Broadcast (broadcastListsSnapshot)
import Seal.Gateway.StreamBroker
  ( BrokerEvent (..), StreamBroker, subscribe, updateSubscriberSession )
import Seal.Gateway.Transcript (readTranscriptEntriesTimed, ttEntryCount, showIso, ReadLimit (..))
import Seal.Logging.Global (globalLogIO)
import Seal.Session.Meta (smModel, smCreatedAt)
import Seal.Tabs (TabsHandle)

import Seal.Gateway.Types.Stream (FocusOp (..), RequestEntriesOp (..), ClientMessage (..))

-- | The liveness of the WebSocket stream server, as reported by
-- @\/api\/health@. The health endpoint used to report the CONFIGURED
-- @ws_port@ unconditionally, so a server whose WS had failed to bind
-- (port already in use) still advertised the dead port and the frontend
-- connected to a non-WebSocket port and froze. The status is now derived
-- from what actually happened at bind time.
data StreamHealth = StreamHealth
  { shStatus :: Text
    -- ^ @\"starting\"@ (bind not yet attempted), @\"up\"@ (bound and
    -- accepting), @\"failed\"@ (the bind failed).
  , shPort  :: Int
    -- ^ The port the server was asked to bind.
  } deriving stock (Eq, Show)

-- | The status string of a 'StreamHealth', as surfaced in @\/api\/health@.
streamHealthStatus :: StreamHealth -> Text
streamHealthStatus = shStatus

-- | A human-readable, actionable description of a 'StreamHealth'. For a
-- failed bind this names the port so the operator can see WHICH port
-- collided — the whole point of reporting the failure.
streamHealthMessage :: StreamHealth -> Text
streamHealthMessage h =
  case shStatus h of
    "up"      -> "WebSocket stream server listening on port " <> tshow (shPort h)
    "failed"  -> "WebSocket stream server FAILED to bind port " <> tshow (shPort h)
                  <> " (port already in use?) — live transcript updates are unavailable"
    "down"    -> "WebSocket stream server is not running"
    _         -> "WebSocket stream server is starting on port " <> tshow (shPort h)
  where
    tshow :: Int -> Text
    tshow = T.pack . show

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
--
-- This wrapper does not report liveness; 'runStreamServerWithHealth' is
-- what production uses. A bind failure is still LOGGED either way.
runStreamServer :: Text -> Int -> StreamGuard -> StreamBroker -> IO ()
runStreamServer host port guard broker = do
  healthRef <- newIORef (StreamHealth "starting" port)
  runStreamServerWithHealth host port guard broker healthRef

-- | Run the WebSocket stream server, reporting its liveness into the given
-- 'IORef'.
--
-- The bind is performed HERE (via 'makeListenSocket') rather than inside
-- 'WS.runServer', so that a bind failure is caught and REPORTED instead of
-- killing the calling thread. The historical implementation used
-- @WS.runServer@ directly, so a port collision (e.g. another process
-- already holding the port) raised an exception that unwound the forked
-- thread and was silently discarded: the HTTP gateway kept running and
-- @\/api\/health@ went on advertising the dead port, so the web frontend
-- connected to a non-WebSocket port and its transcript froze permanently.
--
-- On a successful bind the health state becomes @\"up\"@; on failure it
-- becomes @\"failed\"@ and the error is logged at 'ErrorS' severity.
runStreamServerWithHealth
  :: Text
  -> Int
  -> StreamGuard
  -> StreamBroker
  -> IORef StreamHealth
  -> IO ()
runStreamServerWithHealth host port guard broker healthRef = do
  writeIORef healthRef (StreamHealth "starting" port)
  bindResult <- try (makeListenSocket (T.unpack host) port)
  case bindResult of
    Left (e :: SomeException) -> do
      writeIORef healthRef (StreamHealth "failed" port)
      globalLogIO ErrorS
        ("[ws] FAILED to bind port " <> ls (T.pack (show port)) <> ": " <> ls (T.pack (show e))
         <> " — live transcript updates are UNAVAILABLE (the port may already be in use)")
    Right sock -> do
      writeIORef healthRef (StreamHealth "up" port)
      globalLogIO InfoS ("[ws] stream server listening on " <> ls (T.unpack host) <> ":" <> ls (T.pack (show port)))
      -- The accept loop runs against the socket we already bound, so the
      -- "we know the bind succeeded" property is preserved.
      acceptLoop sock guard broker

-- | Accept loop over an already-bound listening socket. Mirrors
-- 'WS.runServer' but takes the socket, so the caller controls the bind.
--
-- Mirrors the upstream 'Network.WebSockets.Server' accept loop: accept a
-- connection socket, turn it into a 'PendingConnection', then run the
-- per-connection app. Each connection is handled in its own thread so a
-- slow client cannot stall the accept loop.
acceptLoop :: Socket -> StreamGuard -> StreamBroker -> IO ()
acceptLoop sock guard broker = forever $ do
  (conn, _addr) <- Sock.accept sock
  void (forkIO (handleConnection conn guard broker))

-- | Run the per-connection app for an accepted socket. The
-- 'PendingConnection' and its socket are closed when the app returns.
handleConnection :: Sock.Socket -> StreamGuard -> StreamBroker -> IO ()
handleConnection conn guard broker =
  bracket
    (makePendingConnection conn defaultConnectionOptions)
    (\_pending -> Sock.close conn)
    (streamApp guard broker)

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
          sendEvent (BeEntryUpdate sid v) =
            sendTextData conn (A.encode (object
              [ "type" .= ("entry-update" :: Text)
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
              case A.decode msg :: Maybe ClientMessage of
                Just (CmFocus focusOp) ->
                  case mkSessionId (foSession focusOp) of
                    Right s  -> do
                      globalLogIO InfoS ("[ws] focus → " <> ls (sessionIdText s))
                      updateSubscriberSession subSessionRef s
                      -- When the client sends a `since` entry id, replay
                      -- all transcript entries after that id from disk so
                      -- entries broadcast during the WS gap are recovered.
                      forM_ (foSince focusOp) $ \sinceId ->
                        replayEntriesSince conn (sgPaths guard) s sinceId
                    Left _e  -> sendErrorFrame conn "invalid session id"
                Just (CmRequestEntries reqOp) ->
                  handleRequestEntries conn (sgPaths guard) reqOp
                Nothing -> sendErrorFrame conn "unknown op"
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
-- (@\"0\"@, @\"1\"@, ...) when the indexed transcript format has no per-entry id. We
-- compare by the @id@ field in the frontend JSON shape, which is the same
-- shape @readTranscriptEntries@ returns.
replayEntriesSince
  :: Connection -> SealPaths -> SessionId -> Text -> IO ()
replayEntriesSince conn paths sid sinceId = do
  let go = do
        mMeta <- loadSessionMeta paths sid
        let model = maybe "" smModel mMeta
            fallbackTs = maybe "" (showIso . smCreatedAt) mMeta
        -- Read only the last 200 entries (limit) to avoid flooding the
        -- Read only the last 50 entries (limit) to avoid flooding the
        -- frontend with thousands of WS entry events on large sessions.
        -- The frontend dedupes by id, and the HTTP seed already provided
        -- the initial page. The replay only needs to catch up entries
        -- that arrived since the last visit.
        putStrLn "[ws] replayEntriesSince: calling readTranscriptEntriesTimed (ReadLastN 50)"
        (entries, _tt) <- readTranscriptEntriesTimed paths model fallbackTs sid (ReadLastN 50)
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
-- field is strictly after @sinceId@. Entry ids from the indexed transcript format
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

-- | Handle a @request-entries@ op: read the transcript from disk, slice it
-- to the requested chunk, and send an @entries-chunk@ event. Includes a
-- catch handler so a corrupt/missing transcript sends an error frame
-- instead of propagating to the readerLoop's top-level catch and
-- disconnecting the entire WS connection.
handleRequestEntries :: Connection -> SealPaths -> RequestEntriesOp -> IO ()
handleRequestEntries conn paths (RequestEntriesOp sidTxt mBefore mLimit) =
  case mkSessionId sidTxt of
    Left _ -> sendErrorFrame conn "invalid session id"
    Right sid -> do
      let go = do
            mMeta <- loadSessionMeta paths sid
            let model = maybe "" smModel mMeta
                fallbackTs = maybe "" (showIso . smCreatedAt) mMeta
                limit = clampLimit mLimit
            putStrLn $ "[ws] handleRequestEntries: limit=" <> show limit <> " mBefore=" <> show mBefore
            -- Use the paginated read to avoid loading all entries into
            -- memory. For the initial chunk (mBefore == Nothing), read
            -- only the last `limit` entries. For before/id pagination,
            -- read a wider window. For __beginning__, we need the FIRST
            -- entries — use ReadFirstN to read only the first `limit`
            -- entries instead of loading the entire transcript.
            (allEntries, tt) <- readTranscriptEntriesTimed paths model fallbackTs sid
              (case mBefore of
                Nothing              -> ReadLastN limit
                Just "__beginning__" -> ReadFirstN limit
                Just _               -> ReadLastN (limit * 3))
            -- totalCount comes from the timings (full entry count before
            -- limiting), NOT from length allEntries (which is the limited count).
            let totalCount = ttEntryCount tt
                (chunk, hasMore) = case mBefore of
                  Nothing ->
                    -- allEntries already contains only the last `limit`
                    -- entries; the chunk is all of them, hasMore = totalCount > limit
                    (allEntries, totalCount > limit)
                  Just before ->
                   if before == "__beginning__"
                     -- allEntries already contains only the first `limit`
                     -- entries (ReadFirstN); no take needed.
                     then (allEntries, totalCount > limit)
                     else
                    case entriesBeforeId before allEntries of
                      Just beforeEntries ->
                        let taken = drop (max 0 (length beforeEntries - limit)) beforeEntries
                            hasMoreBefore = length beforeEntries > limit
                        in (taken, hasMoreBefore)
                      Nothing -> ([], False)
            sendTextData conn (A.encode (A.object
              [ "type" A..= ("entries-chunk" :: Text)
              , "sessionId" A..= sidTxt
              , "entries" A..= chunk
              , "hasMore" A..= hasMore
              , "totalCount" A..= totalCount
              , "requestBefore" A..= mBefore
              ]))
      go `catch` \(e :: SomeException) -> do
        globalLogIO InfoS ("[ws] request-entries error: " <> ls (T.pack (show e)))
        sendTextData conn (A.encode (A.object
          [ "type" A..= ("entries-chunk" :: Text)
          , "sessionId" A..= sidTxt
          , "entries" A..= ([] :: [A.Value])
          , "requestBefore" A..= mBefore
          ]))

-- | Return entries before the entry with id @before@ (exclusive).
-- Returns 'Nothing' when the id is not found (distinct from
-- 'filterAfterId' which falls back to all entries on a miss).
entriesBeforeId :: Text -> [A.Value] -> Maybe [A.Value]
entriesBeforeId beforeId = go
  where
    go [] = Nothing
    go (v : vs) =
      if extractId v == beforeId
        then Just []
        else case go vs of
          Just rest -> Just (v : rest)
          Nothing   -> Nothing

-- | Clamp the limit to [1, 200], defaulting to 50.
clampLimit :: Maybe Int -> Int
clampLimit = min 200 . max 1 . fromMaybe 50

-- | Send an error frame to the WS peer. Extracted from the inline
-- pattern in 'readerLoop' for reuse.
sendErrorFrame :: Connection -> Text -> IO ()
sendErrorFrame conn msg = sendTextData conn (A.encode (object
  [ "type" .= ("error" :: Text), "message" .= msg ]))

-- | Look up a header value from the pending request headers (case-insensitive).
lookupHeader :: Text -> WS.RequestHead -> Maybe String
lookupHeader name req =
  case lookup (CI.mk (TE.encodeUtf8 $ T.toLower name)) (WS.requestHeaders req) of
    Just v  -> Just (T.unpack (TE.decodeUtf8 v))
    Nothing -> Nothing
