{-# LANGUAGE OverloadedStrings #-}
-- | Append-only session transcript with a single-writer daemon.
--
-- Two coexisting on-disk formats:
--
-- [Legacy] @transcript.jsonl@ — one 'TranscriptEntry' per line, the old O(N²)
-- format where each 'Request' entry re-serializes the whole prior
-- conversation. Read-only for new sessions; old sessions are still readable.
--
-- [New] @conversation.jsonl@ + @entries.jsonl@ — the change-log sidecar
-- format. @conversation.jsonl@ is one raw 'Message' per line (the pure content
-- list, grown by deltas). @entries.jsonl@ is one 'EntryRecord' per event
-- (payload-free, with an envelope-delta recorded only when changed). The new
-- format is what the writer produces for sessions that did not already have a
-- @transcript.jsonl@.
--
-- 'recordAndAck' returns ONLY after the entry is fsync'd to disk — the
-- durability primitive the Untrusted dispatch gate depends on
-- (ACK-before-execute).
--
-- Integrity rests on the append-only single-writer + fsync, and on keeping
-- untrusted actions off the box that holds the log — not on a hash chain.
module Seal.Handles.Transcript
  ( TranscriptHandle (..)
  , withTranscript
  , fakeTranscript
  , withTwoFileTranscript
  , fakeTwoFileTranscript
  , TwoFileHandle (..)
  , TwoFileWrite (..)
  , TranscriptError (..)
  , defaultAckTimeoutUs
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Concurrent.STM
  ( TMVar, atomically, newEmptyTMVarIO, newTQueueIO, newTVarIO
  , orElse, putTMVar, readTQueue, readTVar, readTVarIO, retry, takeTMVar
  , tryPutTMVar, tryReadTQueue, writeTQueue, writeTVar )
import Control.Exception (bracket, catch, Exception, SomeException, throwIO)
import Control.Monad (void)
import Data.Aeson (decode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Unsafe qualified as BSU
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Word (Word8)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Posix.IO
  ( OpenFileFlags (..), OpenMode (..), closeFd, defaultFileFlags
  , fdWriteBuf, openFd )
import System.Posix.Types (Fd, FileMode)
import System.Posix.Unistd (fileSynchronise)

import Seal.Core.Types (OpName, ToolCallId)
import Seal.Providers.Class
  ( ContentBlock (..), Message (..), ToolResultPart (..) )
import Seal.Transcript.Conv (ConvLine (..), encodeConvLine, readConversation)
import Seal.Transcript.Entries
  ( EntryRecord (..), encodeEntryRecordRaw )
import Seal.Transcript.Types
  ( TranscriptEntry (..), encodeEntryRaw )

-- | Exception raised by 'tfwRecordAndAck' when the single-writer daemon has
-- died (an I/O error in @writeOne@ killed it). Without this, a dead daemon
-- leaves the ACK 'TMVar' empty and the caller blocks forever — the
-- root-cause of session @20260724-113851-844@ silently hanging mid-dispatch.
newtype TranscriptError = TranscriptError T.Text
  deriving newtype (Eq, Show)

instance Exception TranscriptError

-- | Handle to the legacy single-file transcript writer. All fields are
-- functions so the type is uniform between the real (file-backed) and fake
-- (in-memory) variants.
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

-- ---------------------------------------------------------------------------
-- Two-file format (conversation.jsonl + entries.jsonl)
-- ---------------------------------------------------------------------------

-- | A structured write request for the two-file writer. The writer diffs
-- @tfwMessages@ against the conversation as it exists on disk and appends only
-- the new lines (with @CbToolResult@ parts redacted), then appends the entry
-- record. Crash semantics: messages first, then the entry line, so a torn tail
-- leaves at most orphan message lines / a malformed last line — both already
-- tolerated by the skip-malformed decode path.
data TwoFileWrite = TwoFileWrite
  { tfwMessages :: [Message]
  -- ^ The full message list in effect at this turn (the conversation prefix +
  -- any new messages). The writer diffs against the on-disk conversation and
  -- appends only the new lines.
  , tfwEntry    :: EntryRecord
  -- ^ The event line to append to @entries.jsonl@.
  }

-- | Handle to the two-file writer. 'tfwRecordAndAck' blocks until both files
-- are fsync'd; 'tfwRecordAsync' is fire-and-forget.
data TwoFileHandle = TwoFileHandle
  { tfwRecordAndAck :: TwoFileWrite -> IO ()
  , tfwRecordAsync  :: TwoFileWrite -> IO ()
  , tfwReadConversation :: IO [Message]
  -- ^ Read back the on-disk conversation (for tests / replay).
  , tfwReadEntries     :: IO [EntryRecord]
  -- ^ Read back the on-disk entry log.
  , tfwSetSecretOps    :: Set OpName -> IO ()
  -- ^ Set the set of opcode names whose tool results should be redacted from
  -- the on-disk conversation file. Call this after building the ISA registry
  -- so the writer knows which 'CbToolResult's may carry secrets. Results from
  -- opcodes NOT in this set (e.g. SHELL_EXEC, FILE_READ) pass through verbatim.
  , tfwCloseTranscript :: IO ()
  , tfwIsAlive :: IO Bool
  -- ^ Is the single-writer daemon still running? Returns 'False' after a
  -- write error killed it. Callers that depend on durability (the dispatch
  -- ACK-before-execute gate) should check this before trusting a prior write.
  }

-- | Default ACK timeout (30 seconds). If the daemon does not acknowledge a
-- write within this window, 'tfwRecordAndAck' raises 'TranscriptError' instead
-- of hanging forever. Tuned generously — normal writes complete in
-- milliseconds; 30s is a fail-safe for a stuck/dead daemon, not a performance
-- bound.
defaultAckTimeoutUs :: Int
defaultAckTimeoutUs = 30_000_000

-- | The daemon's accumulated state: the conversation lines written so far (so
-- the diff can be computed without re-reading the file each turn) and the
-- fsync'd fds.
data TwoFileState = TwoFileState
  { tfsConvFd :: Fd
  , tfsEntriesFd :: Fd
  , tfsWritten :: [Message]
  -- ^ The conversation as it exists on disk, in order. Grown by each write
  -- so the next diff can be computed in-memory.
  , tfsSecretOpsRef :: IORef (Set OpName)
  -- ^ The set of opcode names whose tool results may carry secrets and must
  -- be redacted from the on-disk conversation file. An IORef so the caller
  -- can set it after building the registry (the registry construction may
  -- depend on values only available inside the 'withTwoFileTranscript'
  -- callback, e.g. session id or worker functions).
  }

-- | A work item for the two-file daemon.
data TwoFileItem
  = TFWWrite TwoFileWrite (Maybe (TMVar ()))
  | TFWShutdown (TMVar ())

-- | Open both files in O_APPEND mode, spawn the single-writer daemon, run
-- @action@, then close. Every 'tfwRecordAndAck' blocks until both files are
-- fsync'd.
--
-- If the session directory already contains a legacy @transcript.jsonl@ and no
-- @conversation.jsonl@, the legacy file is left untouched (the legacy read path
-- handles it); the new writer simply creates the two new files alongside it.
withTwoFileTranscript :: FilePath -> (TwoFileHandle -> IO a) -> IO a
withTwoFileTranscript dir action = do
  q <- newTQueueIO
  aliveRef <- newTVarIO True
  let convPath     = dir </> "conversation.jsonl"
      entriesPath  = dir </> "entries.jsonl"
      flags = defaultFileFlags
        { append = True
        , creat = Just (0o600 :: FileMode)
        }
      ack = maybe (pure ()) (\tv -> atomically (putTMVar tv ()))
      writeOne st (TwoFileWrite msgs entry) = do
        secretOps <- readIORef (tfsSecretOpsRef st)
        let new = diffMessages msgs (tfsWritten st)
            redacted = redactMessages secretOps msgs new
        -- 1. Append new conversation lines, fsync.
        mapM_ (\m -> writeFd (tfsConvFd st) (encodeConvLine (ConvLine m) <> "\n")) redacted
        fileSynchronise (tfsConvFd st)
        -- 2. Append the entry line, fsync.
        writeFd (tfsEntriesFd st) (encodeEntryRecordRaw entry <> "\n")
        fileSynchronise (tfsEntriesFd st)
        pure st { tfsWritten = tfsWritten st <> redacted }
      drain st = do
        next <- atomically (tryReadTQueue q)
        case next of
          Nothing -> pure st
          Just (TFWWrite w mack) -> do
            st' <- writeOne st w
            ack mack
            drain st'
          Just (TFWShutdown done) -> do
            atomically (putTMVar done ())
            drain st
      daemon st = do
        item <- atomically (readTQueue q)
        case item of
          TFWWrite w mack -> do
            st' <- writeOne st w
            ack mack
            daemon st'
          TFWShutdown done -> do
            st' <- drain st
            atomically (putTMVar done ())
            pure st'
      shutdown convFd entriesFd done = do
        atomically (writeTQueue q (TFWShutdown done))
        atomically (takeTMVar done)
        closeFd convFd
        closeFd entriesFd
  -- Read existing conversation (if any) so the diff starts from the right
  -- baseline. A torn legacy file or a fresh session yields [].
  existingConv <- do
    exists <- doesFileExist convPath
    if exists
      then readConversation <$> BS.readFile convPath
      else pure []
  bracket
    (do convFd     <- openFd convPath    WriteOnly flags
        entriesFd  <- openFd entriesPath WriteOnly flags
        pure (convFd, entriesFd))
    (\(convFd, entriesFd) -> do
        done <- newEmptyTMVarIO
        shutdown convFd entriesFd done)
    $ \(convFd, entriesFd) -> do
        secretOpsRef <- newIORef Set.empty
        let st0 = TwoFileState convFd entriesFd existingConv secretOpsRef
            -- The daemon with an exception handler: if writeOne throws, mark
            -- the daemon dead, fail every queued ACK (so callers blocked on
            -- takeTMVar unblock immediately), and log to stderr. The daemon
            -- then exits — no further writes are attempted.
            safeDaemon st =
              daemon st `catch` \e -> do
                atomically (writeTVar aliveRef False)
                hPutStrLn stderr ("[transcript] writer daemon died: " <> show (e :: SomeException))
                -- Drain remaining queue items WITHOUT filling their ACK slots
                -- (the writes never completed). Callers blocked on takeTMVar
                -- unblock via the aliveRef check in ackWrite's orElse. Shutdown
                -- items still get their done signal so the bracket cleanup
                -- completes.
                let drainRemaining = do
                      item <- atomically (tryReadTQueue q)
                      case item of
                        Nothing -> pure ()
                        Just (TFWWrite _ _mack) -> drainRemaining
                        Just (TFWShutdown done) -> do
                          atomically (putTMVar done ())
                drainRemaining
                pure st
        void $ forkIO (void (safeDaemon st0))
        let enqueue w = atomically (writeTQueue q (TFWWrite w Nothing))
            ackWrite w = do
              alive <- readTVarIO aliveRef
              if not alive
                then throwIO (TranscriptError "transcript writer daemon is dead")
                else do
                  tv <- newEmptyTMVarIO
                  timeoutVar <- newEmptyTMVarIO
                  atomically (writeTQueue q (TFWWrite w (Just tv)))
                  void $ forkIO $ do
                    threadDelay defaultAckTimeoutUs
                    void $ atomically (tryPutTMVar timeoutVar ())
                  mResult <- atomically $
                    (Right <$> takeTMVar tv)
                      `orElse` (Left <$> takeTMVar timeoutVar)
                      `orElse` (do
                         stillAlive <- readTVar aliveRef
                         if stillAlive then retry else pure (Left ()))
                  case mResult of
                    Right () -> pure ()
                    Left ()  -> do
                      stillAlive <- readTVarIO aliveRef
                      if stillAlive
                        then throwIO (TranscriptError "transcript write timed out (daemon stuck)")
                        else throwIO (TranscriptError "transcript writer daemon died during write")
        action TwoFileHandle
          { tfwRecordAndAck = ackWrite
          , tfwRecordAsync  = enqueue
          , tfwReadConversation = readConversation <$> BS.readFile convPath
          , tfwReadEntries     = readEntries entriesPath
          , tfwSetSecretOps    = writeIORef secretOpsRef
          , tfwCloseTranscript = pure ()
          , tfwIsAlive = readTVarIO aliveRef
          }

-- | Read back the entries file, skipping malformed lines.
readEntries :: FilePath -> IO [EntryRecord]
readEntries path = do
  exists <- doesFileExist path
  if not exists
    then pure []
    else do
      bs <- BS.readFile path
      let ls = filter (not . BS.null) (BS.split 0x0a bs)
      pure (mapMaybe (decode . BL.fromStrict) ls)

-- | In-memory two-file handle for tests. No file IO, no daemon.
fakeTwoFileTranscript :: IO (TwoFileHandle, IO ([Message], [EntryRecord]))
fakeTwoFileTranscript = do
  convRef    <- newMVar ([] :: [Message])
  entriesRef <- newMVar ([] :: [EntryRecord])
  secretOpsRef <- newIORef Set.empty
  let pushConv m = modifyMVar_ convRef (pure . (++ [m]))
      pushEntry e = modifyMVar_ entriesRef (pure . (++ [e]))
      handle w = do
        secretOps <- readIORef secretOpsRef
        written <- readMVar convRef
        let new = diffMessages (tfwMessages w) written
            redacted = redactMessages secretOps (tfwMessages w) new
        mapM_ pushConv redacted
        pushEntry (tfwEntry w)
  pure
    ( TwoFileHandle
        { tfwRecordAndAck = handle
        , tfwRecordAsync  = handle
        , tfwReadConversation = readMVar convRef
        , tfwReadEntries     = readMVar entriesRef
        , tfwSetSecretOps    = writeIORef secretOpsRef
        , tfwCloseTranscript = pure ()
        , tfwIsAlive = pure True
        }
    , do cs <- readMVar convRef
         es <- readMVar entriesRef
         pure (cs, es)
    )

-- | The new-message suffix beyond the written conversation prefix. Mirrors
-- 'Seal.Transcript.Conv.diffNew' (kept local so this module is self-contained).
diffMessages :: [Message] -> [Message] -> [Message]
diffMessages incoming written = fromMaybe incoming (stripPrefixMsg written incoming)
  where
    stripPrefixMsg [] is             = Just is
    stripPrefixMsg _  []             = Nothing
    stripPrefixMsg (w:ws) (i:is)
      | w == i    = stripPrefixMsg ws is
      | otherwise = Nothing

-- | Redact tool-result parts that may carry secret values. Only results from
-- secret-producing opcodes (those whose name is in the provided set) are
-- redacted — Untrusted opcodes (SHELL_EXEC, FILE_READ, etc.) produce non-secret
-- output that passes through verbatim so the frontend can display it.
--
-- The @allMsgs@ list (the full conversation) is scanned for 'CbToolUse' blocks
-- whose 'cbName' is in the secret-opcode-name set; their 'cbId's form the set
-- of tool-call ids whose results should be redacted. Only the @newMsgs@ are
-- returned (after redaction); @allMsgs@ is only used for the scan.
redactMessages :: Set OpName -> [Message] -> [Message] -> [Message]
redactMessages secretOps allMsgs newMsgs =
  let secretIds = buildSecretIds secretOps allMsgs
  in map (redactMessage secretIds) newMsgs
  where
    buildSecretIds :: Set OpName -> [Message] -> Set ToolCallId
    buildSecretIds ops = foldr go mempty
      where
        go (Message _ blocks) acc = acc <> foldr goBlock mempty blocks
          where
            goBlock (CbToolUse tcid name _) a
              | name `Set.member` ops = tcid `Set.insert` a
              | otherwise             = a
            goBlock _ a = a

    redactMessage :: Set ToolCallId -> Message -> Message
    redactMessage secretIds (Message role blocks) =
      Message role (map (redactBlock secretIds) blocks)
      where
        redactBlock ids (CbToolResult tcid parts isErr)
          | tcid `Set.member` ids = CbToolResult tcid (map redactPart parts) isErr
          | otherwise             = CbToolResult tcid parts isErr
        redactBlock _ other = other

        redactPart (TrpText t)
          | not (T.null t) = TrpText "<redacted:secret>"
          | otherwise      = TrpText t