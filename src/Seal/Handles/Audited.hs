{-# LANGUAGE OverloadedStrings #-}
-- | The Audited log handle: an append-only, cross-session log with a
-- single-writer daemon and fsync durability, mirroring 'Seal.Handles.Transcript'.
-- 'auditedAck' returns ONLY after the entry is fsync'd to disk (and the mirror
-- hook, if any, has been invoked) — the durability primitive for Audited
-- opcodes.
--
-- A mirror hook fires after the local fsync, before the ack TMVar is filled,
-- so a slow mirror back-pressures the writer (fail-closed for durability). A
-- later flag can make the mirror async-only. The default mirror is a no-op.
module Seal.Handles.Audited
  ( AuditedHandle (..)
  , withAuditedLog
  , withAuditedLogMirror
  , fakeAuditedLog
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (bracket)
import Control.Monad (void)
import Data.ByteString qualified as BS
import Data.ByteString.Unsafe qualified as BSU
import Data.Maybe (mapMaybe)
import Data.Aeson (decode)
import Data.ByteString.Lazy qualified as BL
import Data.Word (Word8)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import System.Directory (doesFileExist)
import System.Posix.IO
  ( OpenFileFlags (..), OpenMode (..), closeFd, defaultFileFlags
  , fdWriteBuf, openFd )
import System.Posix.Types (Fd, FileMode)
import System.Posix.Unistd (fileSynchronise)

import Seal.Audited.Types
  ( AuditedEntry (..), encodeAuditedEntryRaw )

-- | Handle to the Audited log writer. The mirror hook runs after each local
-- fsync; 'auditedAck' blocks until both the local write is durable AND the
-- mirror has returned (fail-closed).
data AuditedHandle = AuditedHandle
  { auditedAck    :: AuditedEntry -> IO ()
  -- ^ Enqueue an entry and block until it is fsync'd locally and the mirror
  -- hook has returned.
  , auditedAsync  :: AuditedEntry -> IO ()
  -- ^ Fire-and-forget enqueue; no durability guarantee before return.
  , readAudited   :: IO [AuditedEntry]
  -- ^ Read back the on-disk log (for tests / replay materialization).
  , closeAudited  :: IO ()
  -- ^ No-op for the file-backed handle (bracket closes the fd); available
  -- for callers that want an explicit close point.
  }

-- | A work item for the single-writer daemon.
data Item
  = Write AuditedEntry (Maybe (TMVar ()))
  | Shutdown (TMVar ())

-- | Write the strict 'ByteString' to 'fd' via the Posix primitive, looping
-- past short writes; 'fdWriteBuf' retries on EINTR.
writeFd :: Fd -> BS.ByteString -> IO ()
writeFd fd bs =
  BSU.unsafeUseAsCStringLen bs $ \(ptr, len) ->
    go (castPtr ptr) len
  where
    go :: Ptr Word8 -> Int -> IO ()
    go _ 0 = pure ()
    go ptr remaining = do
      written <- fromIntegral <$> fdWriteBuf fd ptr (fromIntegral remaining)
      go (ptr `plusPtr` written) (remaining - written)

-- | Open the Audited log file in O_APPEND mode, spawn the single-writer daemon,
-- run @action@, then close. Every 'auditedAck' blocks until 'fileSynchronise'
-- returns AND the mirror hook has returned, guaranteeing the entry is durable
-- before the caller proceeds.
--
-- The @mirror@ hook is invoked with each entry after the local fsync. The
-- default (no-op) mirror is 'const (pure ())'.
withAuditedLog
  :: FilePath -> (AuditedHandle -> IO a) -> IO a
withAuditedLog = withAuditedLogMirror (const (pure ()))

-- | Like 'withAuditedLog' but with a custom mirror hook that runs after each
-- local fsync. Used by the wiring layer to wire up an off-box mirror target.
withAuditedLogMirror
  :: (AuditedEntry -> IO ())  -- ^ mirror hook (runs after local fsync)
  -> FilePath                 -- ^ log file path
  -> (AuditedHandle -> IO a)
  -> IO a
withAuditedLogMirror mirror path action = do
  q <- newTQueueIO
  let flags = defaultFileFlags
        { append = True
        , creat = Just (0o600 :: FileMode)
        }
      ack = maybe (pure ()) (\tv -> atomically (putTMVar tv ()))
      writeEntry fd e = do
        writeFd fd (encodeAuditedEntryRaw e <> "\n")
        fileSynchronise fd
        mirror e
      drain fd = do
        next <- atomically (tryReadTQueue q)
        case next of
          Nothing -> pure ()
          Just (Write e mack) -> writeEntry fd e >> ack mack >> drain fd
          Just (Shutdown done) -> atomically (putTMVar done ()) >> drain fd
      daemon fd = do
        item <- atomically (readTQueue q)
        case item of
          Write e mack -> writeEntry fd e >> ack mack >> daemon fd
          Shutdown done -> drain fd >> atomically (putTMVar done ())
      shutdown fd = do
        done <- newEmptyTMVarIO
        atomically (writeTQueue q (Shutdown done))
        atomically (takeTMVar done)
        closeFd fd
  bracket (openFd path WriteOnly flags) shutdown $ \fd -> do
    void $ forkIO (daemon fd)
    let enqueue e = atomically (writeTQueue q (Write e Nothing))
        ackWrite e = do
          tv <- newEmptyTMVarIO
          atomically (writeTQueue q (Write e (Just tv)))
          atomically (takeTMVar tv)
    action AuditedHandle
      { auditedAck   = ackWrite
      , auditedAsync = enqueue
      , readAudited  = readAuditedFile path
      , closeAudited = pure ()
      }

-- | Read back the log file, skipping malformed lines.
readAuditedFile :: FilePath -> IO [AuditedEntry]
readAuditedFile path = do
  exists <- doesFileExist path
  if not exists
    then pure []
    else do
      bs <- BS.readFile path
      pure (mapMaybe (decode . BL.fromStrict)
                     (filter (not . BS.null) (BS.split 0x0a bs)))

-- | In-memory handle for tests. Records entries in invocation order. No file
-- IO, no daemon thread. The second element of the pair reads back the log.
fakeAuditedLog :: IO (AuditedHandle, IO [AuditedEntry])
fakeAuditedLog = do
  ref <- newMVar ([] :: [AuditedEntry])
  let push e = modifyMVar_ ref (pure . (++ [e]))
  pure
    ( AuditedHandle
        { auditedAck   = push
        , auditedAsync = push
        , readAudited  = readMVar ref
        , closeAudited = pure ()
        }
    , readMVar ref
    )