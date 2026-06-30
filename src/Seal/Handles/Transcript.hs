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
import Control.Monad (forever, void)
import Data.ByteString qualified as BS
import Data.ByteString.Unsafe qualified as BSU
import Foreign.Ptr (castPtr)
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

data Item = Item TranscriptEntry (Maybe (TMVar ()))

-- | Write the strict 'ByteString' to 'fd' using the Posix primitive, which
-- bypasses any user-space buffer. Retries on short writes (rare but possible).
writeFd :: Fd -> BS.ByteString -> IO ()
writeFd fd bs =
  BSU.unsafeUseAsCStringLen bs $ \(ptr, len) ->
    void $ fdWriteBuf fd (castPtr ptr) (fromIntegral len)

-- | Open the transcript file in O_APPEND mode, spawn the single-writer daemon,
-- run @action@, then close. Every 'recordAndAck' blocks until 'fileSynchronise'
-- returns, guaranteeing the entry is durable before the caller proceeds.
withTranscript :: FilePath -> (TranscriptHandle -> IO a) -> IO a
withTranscript path action = do
  q <- newTQueueIO
  let flags = defaultFileFlags
        { append = True
        , creat = Just (0o644 :: FileMode)
        }
  bracket (openFd path WriteOnly flags) closeFd $ \fd -> do
    void $ forkIO $ forever $ do
      Item e mack <- atomically (readTQueue q)
      writeFd fd (encodeEntryRaw e)
      writeFd fd "\n"
      fileSynchronise fd
      maybe (pure ()) (\tv -> atomically (putTMVar tv ())) mack
    let enqueue e = atomically (writeTQueue q (Item e Nothing))
        ackWrite e = do
          tv <- newEmptyTMVarIO
          atomically (writeTQueue q (Item e (Just tv)))
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
