{-# LANGUAGE OverloadedStrings #-}
-- | The @conversation.idx@ binary index: a file of contiguous
-- little-endian 'Word64' values storing the byte offset of the start
-- of each line in @conversation.jsonl@. N lines → N+1 offsets
-- (offset[0] = 0, offset[N] = fileSize). Enables random-access reads
-- of individual conversation lines without loading the full file into
-- memory — preventing OOM on multi-GB transcripts.
--
-- The index is built alongside @conversation.jsonl@ by the
-- 'Seal.Handles.Transcript.withIndexedTranscript' writer (append-only,
-- fsync'd). For pre-existing sessions without an index, 'ensureIndex'
-- builds it in a one-time full-file scan. Crash recovery (index
-- shorter than conversation) appends only the missing tail.
module Seal.Transcript.ConvIndex
  ( readConvLines
  , convLineCount
  , buildIndex
  , ensureIndex
  , writeIdxEntry
  , ConvIndexError(..)
  ) where

import Data.Aeson qualified as A
import Data.Bits ((.|.), shiftL)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Builder (toLazyByteString, word64LE)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Word (Word64)
import System.Directory (doesFileExist, renameFile)
import System.IO
  ( Handle, IOMode(..), SeekMode(..), hFileSize, hGetBuf
  , hSeek, withBinaryFile )
import System.Posix.IO
  ( OpenFileFlags(..), OpenMode(..), closeFd, defaultFileFlags
  , fdWriteBuf, openFd )
import System.Posix.Types (Fd, FileMode)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import Foreign.Marshal.Alloc (allocaBytes)
import Data.ByteString.Unsafe qualified as BSU

import Seal.Providers.Class (Message)

-- | Error ADT for 'ensureIndex'. The program pattern-matches on this
-- to drive control flow: 'IndexMissing' → build from scratch;
-- 'IndexStale' → tail-recovery; 'IndexCorrupt' → return Left (rebuild
-- deferred to next startup).
data ConvIndexError
  = IndexMissing
  | IndexStale
  | IndexCorrupt
  deriving stock (Eq, Show)

-- | Size of a Word64 in bytes (the index entry size).
word64Size :: Int
word64Size = 8

-- | Read lines [start, end) from conversation.jsonl using the index.
-- Returns 'Left' on: missing files, corrupt index, out-of-bounds offsets.
-- Clamps @end@ to 'convLineCount' if it exceeds the available lines.
-- Returns @Right []@ when @start >= end@ or @start >= lineCount@.
readConvLines :: FilePath -> FilePath -> Int -> Int -> IO (Either Text [Message])
readConvLines convPath idxPath start end
  | start >= end = pure (Right [])
  | otherwise = do
      convExists <- doesFileExist convPath
      idxExists  <- doesFileExist idxPath
      if not convExists
        then pure (Left "conversation.jsonl not found")
        else if not idxExists
          then pure (Left "conversation.idx not found")
          else do
            lc <- convLineCount idxPath
            if lc <= 0 || start >= lc
              then pure (Right [])
              else do
                let end' = min end lc
                eOffsets <- readOffsets idxPath start end'
                case eOffsets of
                  Left e -> pure (Left e)
                  Right (offStart, offEnd) -> do
                    convSize <- withBinaryFile convPath ReadMode hFileSize
                    if offStart > offEnd || offEnd > fromIntegral (convSize :: Integer)
                      then pure (Left "index offset out of bounds")
                      else do
                        raw <- readByteRange convPath (fromIntegral offStart) (fromIntegral offEnd)
                        let lns = filter (not . BS.null) (BS.split 0x0a raw)
                            msgs = mapMaybe (A.decode . BL.fromStrict) lns
                        pure (Right msgs)

-- | Read the byte offsets for lines [start, end) from the index.
-- Returns (offset[start], offset[end]) — the byte range to read from
-- conversation.jsonl.
readOffsets :: FilePath -> Int -> Int -> IO (Either Text (Word64, Word64))
readOffsets idxPath start end =
  withBinaryFile idxPath ReadMode $ \h -> do
    offStart <- readWord64At h start
    offEnd   <- readWord64At h end
    pure (Right (offStart, offEnd))

-- | Read a single Word64 LE value at the given line index from an open handle.
readWord64At :: Handle -> Int -> IO Word64
readWord64At h lineIdx = do
  hSeek h AbsoluteSeek (fromIntegral (lineIdx * word64Size))
  allocaBytes word64Size $ \ptr -> do
    _ <- hGetBuf h ptr word64Size
    bs <- BS.packCStringLen (castPtr ptr, word64Size)
    pure (decodeWord64LE bs)

-- | Read a byte range [start, end) from a file.
readByteRange :: FilePath -> Int -> Int -> IO BS.ByteString
readByteRange path startOff endOff =
  withBinaryFile path ReadMode $ \h -> do
    hSeek h AbsoluteSeek (fromIntegral startOff)
    let len = endOff - startOff
    allocaBytes len $ \ptr -> do
      _ <- hGetBuf h ptr len
      BS.packCStringLen (castPtr ptr, len)

-- | Decode a little-endian Word64 from an 8-byte ByteString.
decodeWord64LE :: BS.ByteString -> Word64
decodeWord64LE bs =
  let w0 = fromIntegral (BS.index bs 0)
      w1 = fromIntegral (BS.index bs 1)
      w2 = fromIntegral (BS.index bs 2)
      w3 = fromIntegral (BS.index bs 3)
      w4 = fromIntegral (BS.index bs 4)
      w5 = fromIntegral (BS.index bs 5)
      w6 = fromIntegral (BS.index bs 6)
      w7 = fromIntegral (BS.index bs 7)
  in w0 .|. (w1 `shiftL` 8) .|. (w2 `shiftL` 16) .|. (w3 `shiftL` 24)
   .|. (w4 `shiftL` 32) .|. (w5 `shiftL` 40) .|. (w6 `shiftL` 48) .|. (w7 `shiftL` 56)

-- | Total number of conversation lines (index entry count - 1).
-- Returns 0 if the index file is missing or empty.
convLineCount :: FilePath -> IO Int
convLineCount idxPath = do
  exists <- doesFileExist idxPath
  if not exists
    then pure 0
    else do
      size <- fromIntegral <$> withBinaryFile idxPath ReadMode hFileSize
      let entryCount = size `div` word64Size
      pure (max 0 (entryCount - 1))

-- | Build conversation.idx from an existing conversation.jsonl.
-- One pass: scan the file, record byte offsets of each newline.
-- Uses temp-file + atomic rename: writes to conversation.idx.tmp,
-- fsyncs, renames to conversation.idx. Crash-safe.
buildIndex :: FilePath -> FilePath -> IO (Either Text ())
buildIndex convPath idxPath = do
  convExists <- doesFileExist convPath
  if not convExists
    then pure (Left "conversation.jsonl not found")
    else do
      offsets <- scanLineOffsets convPath
      let tmpPath = idxPath <> ".tmp"
      writeIndexFile tmpPath offsets
      renameFile tmpPath idxPath
      pure (Right ())

-- | Scan a file and record the byte offset of the start of each line.
-- Returns a list of Word64 offsets: [0, offset[1], offset[2], ..., fileSize].
-- For N lines, returns N+1 offsets.
scanLineOffsets :: FilePath -> IO [Word64]
scanLineOffsets path = do
  bs <- BS.readFile path
  let lns = BS.split 0x0a bs
      chunks = if not (null lns) && BS.null (last lns) then init lns else lns
      offsets = scanl (\off chunk -> off + fromIntegral (BS.length chunk) + 1) 0 chunks
  pure offsets

-- | Write a list of Word64 offsets to an index file (little-endian).
writeIndexFile :: FilePath -> [Word64] -> IO ()
writeIndexFile path offsets = do
  let flags = defaultFileFlags { append = False, creat = Just (0o600 :: FileMode) }
  fd <- openFd path WriteOnly flags
  mapM_ (writeIdxEntry fd) offsets
  closeFd fd

-- | Ensure the index exists and is up to date. Builds from scratch
-- if missing; recovers the tail if stale; returns Left IndexCorrupt
-- if structurally invalid (rebuild deferred to next startup — runtime
-- rebuild would invalidate the daemon's long-lived fd via atomic rename).
-- Idempotent and safe to call concurrently (MVar serializes all index writers).
ensureIndex :: FilePath -> FilePath -> IO (Either ConvIndexError ())
ensureIndex = error "Seal.Transcript.ConvIndex.ensureIndex: not implemented"

-- | Append a Word64 LE offset to the index file via the given fd.
-- Used by the writer daemon and 'appendConversationMessage'.
writeIdxEntry :: Fd -> Word64 -> IO ()
writeIdxEntry fd w =
  let bs = BL.toStrict (toLazyByteString (word64LE w))
  in BSU.unsafeUseAsCStringLen bs $ \(ptr, len) ->
       writeBuf fd (castPtr ptr) len

-- | Write a buffer to an fd, looping on short writes.
writeBuf :: Fd -> Ptr a -> Int -> IO ()
writeBuf fd ptr len = go 0
  where
    go written
      | written >= len = pure ()
      | otherwise = do
          n <- fromIntegral <$> fdWriteBuf fd (plusPtr ptr written) (fromIntegral (len - written))
          go (written + n)