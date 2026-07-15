{-# LANGUAGE OverloadedStrings #-}
-- | Per-session concurrency control + reply fan-out.
--
-- Two concerns are handled here:
--
-- 1. **Write lock**: a per-session 'MVar' serializes turns on the same
--    session. Both the channel 'plainTurn' and the web 'plainTurn' acquire
--    the session's lock before calling 'withTwoFileTranscript', preventing
--    concurrent writes from corrupting the two-file transcript format.
--    Different sessions run concurrently; only turns on the SAME session
--    queue.
--
-- 2. **Reply fan-out**: a registry of 'ChannelHandle's subscribed to a
--    session. When a turn completes (from any source — web, Telegram,
--    Signal), the reply is sent to every registered channel handle for
--    that session via 'chSend'. The web frontend already receives entries
--    via the WS broker ('BeEntryRecorded'); the fan-out handles chat
--    channels, which need an explicit 'chSend' to deliver the reply to
--    the peer.
module Seal.Session.Lock
  ( SessionLocks
  , newSessionLocks
  , withSessionLock
  , ReplyRegistry
  , newReplyRegistry
  , replySubscribe
  , replyUnsubscribe
  , replyFanout
  ) where

import Control.Concurrent.MVar
  ( MVar, newMVar, withMVar )
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (IOException, catch)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import System.IO (hPutStrLn, stderr)

import Seal.Core.Types (SessionId)
import Seal.Handles.Channel (ChannelHandle (..))

-- ---------------------------------------------------------------------------
-- Write locks
-- ---------------------------------------------------------------------------

-- | The per-session lock map. Each session gets its own 'MVar' on first
-- use; subsequent turns on the same session acquire that 'MVar'.
newtype SessionLocks = SessionLocks (TVar (Map SessionId (MVar ())))

-- | Build a new empty lock map.
newSessionLocks :: IO SessionLocks
newSessionLocks = SessionLocks <$> newTVarIO Map.empty

-- | Acquire the session's lock, run the action, release. Creates the
-- 'MVar' on first use. Different sessions run concurrently; only turns on
-- the SAME session serialize.
withSessionLock :: SessionLocks -> SessionId -> IO a -> IO a
withSessionLock (SessionLocks tv) sid action = do
  lock <- do
    m <- readTVarIO tv
    case Map.lookup sid m of
      Just l  -> pure l
      Nothing -> do
        l <- newMVar ()
        atomically $ do
          m' <- readTVar tv
          case Map.lookup sid m' of
            Just existing -> pure existing
            Nothing -> do
              writeTVar tv (Map.insert sid l m')
              pure l
  withMVar lock (const action)

-- ---------------------------------------------------------------------------
-- Reply fan-out
-- ---------------------------------------------------------------------------

-- | A reply sink wraps a 'ChannelHandle' and an 'IORef' guard so the
-- same handle can be subscribed to at most one session at a time. The
-- guard carries the 'SessionId' the handle is currently subscribed to;
-- 'replyUnsubscribe' only removes it if the guard matches (preventing a
-- race where the handle already re-subscribed to a different session).
data ReplySink = ReplySink
  { rsHandle :: ChannelHandle
  , rsGuard  :: IORef (Maybe SessionId)
  }

-- | The per-session reply registry. Maps each 'SessionId' to the set of
-- 'ReplySink's that should receive replies for that session. STM-backed
-- so subscribe/unsubscribe/fan-out are race-safe.
newtype ReplyRegistry = ReplyRegistry (TVar (Map SessionId [ReplySink]))

-- | Build a new empty reply registry.
newReplyRegistry :: IO ReplyRegistry
newReplyRegistry = ReplyRegistry <$> newTVarIO Map.empty

-- | Subscribe a 'ChannelHandle' to a session's replies. The handle is
-- associated with an 'IORef' guard (returned to the caller) so it can be
-- later unsubscribed. If the handle was previously subscribed to a
-- different session, it is removed from that session's list first
-- (a handle tracks at most one session at a time).
replySubscribe
  :: ReplyRegistry -> ChannelHandle -> SessionId
  -> IO (IORef (Maybe SessionId))
replySubscribe (ReplyRegistry tv) h sid = do
  guard <- newIORef (Just sid)
  atomically $ do
    m <- readTVar tv
    writeTVar tv (Map.insertWith (++) sid [ReplySink h guard] m)
  pure guard

-- | Unsubscribe a handle from a session. The 'IORef' guard must match
-- the session id; if it doesn't (the handle already re-subscribed to a
-- different session), this is a no-op. This prevents a stale unsubscribe
-- from removing a handle that's now listening to a different session.
replyUnsubscribe :: ReplyRegistry -> IORef (Maybe SessionId) -> SessionId -> IO ()
replyUnsubscribe (ReplyRegistry tv) guard sid = do
  g <- readIORef guard
  case g of
    Just s | s == sid -> do
      atomically $ do
        m <- readTVar tv
        let m' = Map.adjust (filter (\sink -> rsGuard sink /= guard)) sid m
        writeTVar tv (Map.filter (not . null) m')
      writeIORef guard Nothing
    _ -> pure ()

-- | Fan out a reply to every 'ChannelHandle' subscribed to a session.
-- The reply text is sent via 'chSend' to each handle. The web frontend
-- already receives entries via the WS broker, so it does not appear in
-- this registry (only chat channels do). Errors are logged to stderr and
-- swallowed (a dead channel handle should not prevent other handles from
-- receiving the reply).
replyFanout :: ReplyRegistry -> SessionId -> Text -> IO ()
replyFanout (ReplyRegistry tv) sid text = do
  m <- readTVarIO tv
  case Map.lookup sid m of
    Nothing -> pure ()
    Just sinks -> mapM_ (\sink -> safeSend (rsHandle sink) text) sinks
  where
    safeSend h t = chSend h t `catch` \e ->
      hPutStrLn stderr ("reply fanout: send failed: " <> show (e :: IOException))