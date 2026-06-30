{-# LANGUAGE OverloadedStrings #-}
-- | Append-only JSONL transcript with a single-writer daemon. 'recordAndAck'
-- returns ONLY after the entry is fsync'd to disk — the durability primitive
-- the Untrusted dispatch gate depends on (ACK-before-execute).
module Seal.Handles.Transcript
  ( TranscriptHandle (..)
  , withTranscript
  , fakeTranscript
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (bracket)
import Control.Monad (void)
import Data.ByteString qualified as BS
import Data.ByteString.Unsafe qualified as BSU
import Data.Word (Word8)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (..)
  , closeFd
  , defaultFileFlags
  , fdWriteBuf
  , openFd
  )
import System.Posix.Types (Fd, FileMode)
import System.Posix.Unistd (fileSynchronise)

import Seal.Transcript.Types

-- | Handle to the transcript writer. All fields are functions so the type is
-- uniform between the real (file-backed) and fake (in-memory) variants.
data TranscriptHandle = TranscriptHandle
  { recordAndAck :: TranscriptEntry -> IO ()
  -- ^ Enqueue an entry and block until it is flushed and fsync'd to disk.
  , recordAsync :: TranscriptEntry -> IO ()
  -- ^ Fire-and-forget enqueue; no durability guarantee before return.
  , closeTranscript :: IO ()
  -- ^ No-op for the file-backed handle (bracket closes the fd); available
  -- for callers that want an explicit close point.
  }

-- | A unit of work for the single-writer daemon. 'Write' carries an entry and
-- an optional ack slot (filled after fsync). 'Shutdown' tells the daemon to
-- drain any remaining queued writes, fill its ack slot, and exit.
data Item
  = Write TranscriptEntry (Maybe (TMVar ()))
  | Shutdown (TMVar ())

-- | Write the strict 'ByteString' to 'fd' using the Posix primitive, which
-- bypasses any user-space buffer. Loops until the whole buffer is written,
-- advancing past each (possibly short) write; 'fdWriteBuf' itself retries the
-- underlying syscall on @EINTR@, so an interrupted write resumes rather than
-- truncating the line.
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

-- | Open the transcript file in O_APPEND mode, spawn the single-writer daemon,
-- run @action@, then close. Every 'recordAndAck' blocks until 'fileSynchronise'
-- returns, guaranteeing the entry is durable before the caller proceeds.
withTranscript :: FilePath -> (TranscriptHandle -> IO a) -> IO a
withTranscript path action = do
  q <- newTQueueIO
  let flags = defaultFileFlags
        { append = True
        , creat = Just (0o600 :: FileMode)
        }
      ack = maybe (pure ()) (\tv -> atomically (putTMVar tv ()))
      writeEntry fd e = do
        writeFd fd (encodeEntryRaw e <> "\n")
        fileSynchronise fd
      -- Drain every currently-queued write (used at shutdown), fsyncing and
      -- acking each, so nothing is lost before the fd is closed.
      drain fd = do
        next <- atomically (tryReadTQueue q)
        case next of
          Nothing -> pure ()
          Just (Write e mack) -> writeEntry fd e >> ack mack >> drain fd
          Just (Shutdown done) -> atomically (putTMVar done ()) >> drain fd
      -- Single-writer daemon: process writes; on Shutdown, drain the queue,
      -- signal completion, and exit (no 'forever', so it stops deterministically).
      daemon fd = do
        item <- atomically (readTQueue q)
        case item of
          Write e mack -> writeEntry fd e >> ack mack >> daemon fd
          Shutdown done -> drain fd >> atomically (putTMVar done ())
      -- Cleanup: tell the daemon to drain+exit and WAIT for it before closing
      -- the fd, so no queued write races (or writes to) a closed fd.
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
    action TranscriptHandle
      { recordAndAck = ackWrite
      , recordAsync = enqueue
      , closeTranscript = pure ()
      }

-- | In-memory handle for tests. Records entries in invocation order. No file
-- IO, no daemon thread. The second element of the pair reads back the log.
fakeTranscript :: IO (TranscriptHandle, IO [TranscriptEntry])
fakeTranscript = do
  ref <- newMVar ([] :: [TranscriptEntry])
  let push e = modifyMVar_ ref (pure . (++ [e]))
  pure
    ( TranscriptHandle
        { recordAndAck = push
        , recordAsync = push
        , closeTranscript = pure ()
        }
    , readMVar ref
    )
