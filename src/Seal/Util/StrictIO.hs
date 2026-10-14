-- | Strict, resource-safe file-reading helpers built on @conduit@ + @resourcet@.
--
-- The lazy 'Data.ByteString.Lazy.readFile' / 'Data.Text.IO.readFile' helpers
-- keep the file handle open until the lazy structure is fully consumed, which
-- is GC-dependent. The 'Seal.Gateway.ListsSnapshot.buildListsSnapshot' hot
-- path reads hundreds of small files per request (111 sessions × multiple
-- files each) and the lazy handles pile up faster than the GC reclaims them,
-- hitting the OS soft FD limit ('EMFILE' / @resource exhausted (Too many
-- open files)@).
--
-- @conduit@'s 'sourceFile' opens the handle inside a 'ResourceT' scope, so the
-- handle is released as soon as 'runConduitRes' returns — regardless of when
-- (or whether) the resulting lazy 'ByteString' is forced. The bytes are
-- materialized eagerly by 'sinkLazy' before the 'ResourceT' closes the handle,
-- so the decode sees the full file with the fd already released.
--
-- Also provides 'streamFirstMatch' for early-termination line streaming —
-- reads a file line-by-line via conduit and returns the first line where a
-- predicate returns 'Just', without materializing the entire file. Used by
-- 'firstUserMessageSnippetFast' to avoid reading multi-MB conversation files
-- when only the first user message is needed.
module Seal.Util.StrictIO
  ( readFileStrict
  , readFileTextStrict
  , streamFirstMatch
  , streamDecodeLines
  , streamDecodeAfter
  , decodeFileStrict
  ) where

import Conduit ( await, runConduitRes, sinkLazy, sourceFile, (.|) )
import Data.Aeson (FromJSON, decode)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text.Encoding qualified as TE

-- | Read a file strictly into a lazy 'ByteString', closing the underlying
-- handle before the helper returns. The handle is acquired and released by
-- the 'ResourceT' scope of 'runConduitRes'; the bytes are materialized by
-- 'sinkLazy' before the scope exits. Callers 'doesFileExist'-guard the path
-- first (the lazy variants they replace did the same).
readFileStrict :: FilePath -> IO BL.ByteString
readFileStrict path = runConduitRes (sourceFile path .| sinkLazy)

-- | Read a file strictly as 'Text' by reading bytes strictly then decoding.
-- The handle is closed before the decode runs.
readFileTextStrict :: FilePath -> IO Text
readFileTextStrict path = TE.decodeUtf8 . BL.toStrict <$> readFileStrict path

-- | Stream lines from a file, applying a predicate to each line. Returns
-- the first line where the predicate returns 'Just a', stopping the stream
-- early. The file handle is released as soon as the match is found (or the
-- file is exhausted) by conduit's 'ResourceT' scope. Each line is a strict
-- 'ByteString' without the trailing newline.
--
-- This avoids materializing the entire file when only an early line is
-- needed — e.g. @conversation.jsonl@ files averaging 2.7 MB where the
-- first user message is typically in the first few lines. The line
-- splitting is done in-stream (accumulating chunks until a newline is
-- found) so no intermediate @conduit-extra@ dependency is needed.
streamFirstMatch :: (ByteString -> Maybe a) -> FilePath -> IO (Maybe a)
streamFirstMatch test path = runConduitRes
  (sourceFile path .| lineLoop BS.empty)
  where
    -- | Accumulate chunks until a newline (0x0A) is found, then apply the
    -- predicate to the complete line. Stops early on the first match.
    lineLoop acc = do
      mChunk <- await
      case mChunk of
        Nothing -> processRemaining acc
        Just chunk -> do
          let combined = acc <> chunk
          case BS.elemIndex 10 combined of
            Nothing -> lineLoop combined
            Just idx ->
              let line = BS.take idx combined
                  rest = BS.drop (idx + 1) combined
              in case test line of
                Just a  -> pure (Just a)
                Nothing -> lineLoop rest

    -- | Process remaining lines in the accumulator after EOF. The
    -- accumulator may contain multiple newline-separated lines if the
    -- source yielded a large chunk on the last await.
    processRemaining bs
      | BS.null bs = pure Nothing
      | otherwise = case BS.elemIndex 10 bs of
          Nothing -> case test bs of
            Just a  -> pure (Just a)
            Nothing -> pure Nothing
          Just idx ->
            let line = BS.take idx bs
                rest = BS.drop (idx + 1) bs
            in case test line of
              Just a  -> pure (Just a)
              Nothing -> processRemaining rest

-- | Read and decode a JSON file strictly. The handle is closed before the
-- decode runs. Returns 'Nothing' on a decode failure (the caller is
-- expected to 'doesFileExist'-guard the path first).
decodeFileStrict :: FromJSON a => FilePath -> IO (Maybe a)
decodeFileStrict path = decode <$> readFileStrict path
-- | Stream a file line-by-line via conduit, decoding each non-empty line as
-- JSON. Unlike 'readFileTextStrict' which materializes the entire file as a
-- single contiguous 'Text' (potentially hundreds of MB for large transcripts),
-- this reads and decodes one line at a time. The file handle is released by
-- the 'ResourceT' scope when the stream completes.
--
-- Empty lines (blank lines between entries) are skipped. Unparseable lines
-- are silently dropped (matching the @mapMaybe A.decode@ pattern used by the
-- existing 'readTranscriptEntriesTimed').
streamDecodeLines :: FromJSON a => FilePath -> IO [a]
streamDecodeLines path = runConduitRes
  (sourceFile path .| lineDecodeLoop BS.empty)
  where
    lineDecodeLoop acc = do
      mChunk <- await
      case mChunk of
        Nothing -> processRemaining acc
        Just chunk -> splitLines (acc <> chunk)
    -- | Split and decode all complete lines in the buffer, then await more.
    -- When no newline is found in the buffer, await the next chunk. This
    -- handles the case where a single chunk contains multiple lines (the
    -- common case when @sourceFile@ delivers a large chunk).
    splitLines bs =
      case BS.elemIndex 10 bs of
        Nothing -> lineDecodeLoop bs
        Just idx ->
          let line = BS.take idx bs
              rest = BS.drop (idx + 1) bs
          in decodeLine line (splitLines rest)
    processRemaining bs
      | BS.null bs = pure []
      | otherwise = decodeLine bs (pure [])
    decodeLine line cont =
      if BS.null line
        then cont
        else case decode (BL.fromStrict line) of
               Just a  -> fmap (a :) cont
               Nothing -> cont

-- | Stream a file line-by-line, skipping the first @skipCount@ non-empty
-- lines, then decoding the remaining lines as JSON. This avoids both (a)
-- materializing the entire file as a single 'Text' and (b) decoding lines
-- that will be discarded. Used by 'readTranscriptEntriesTimed' when a
-- 'ReadLastN' limit is set: the first @startConvLen@ conversation lines are
-- skipped without decoding, and only the tail is decoded.
--
-- Empty lines are not counted toward @skipCount@ (matching the
-- @filter (not . T.null) (T.lines raw)@ semantics of the existing code).
streamDecodeAfter :: FromJSON a => Int -> FilePath -> IO [a]
streamDecodeAfter skipCount path = runConduitRes
  (sourceFile path .| skipThenDecode BS.empty skipCount)
  where
    skipThenDecode acc skip
      | skip <= 0 = decodeLoop acc
      | otherwise = do
          mChunk <- await
          case mChunk of
            Nothing -> processRemainingSkip acc skip
            Just chunk -> splitSkip (acc <> chunk) skip
    -- | Split lines in the buffer, skipping non-empty ones until skip is
    -- exhausted, then switching to decode mode. Handles multi-line chunks.
    splitSkip bs skip
      | skip <= 0 = splitDecode bs
      | otherwise =
          case BS.elemIndex 10 bs of
            Nothing -> skipThenDecode bs skip
            Just idx ->
              let line = BS.take idx bs
                  rest = BS.drop (idx + 1) bs
              in if BS.null line
                   then splitSkip rest skip
                   else splitSkip rest (skip - 1)
    processRemainingSkip bs skip
      | skip <= 0 = processRemainingDecode bs
      | BS.null bs = pure []
      | otherwise =
          case BS.elemIndex 10 bs of
            Nothing -> pure []  -- remaining bytes are one last skipped line
            Just idx ->
              let line = BS.take idx bs
                  rest = BS.drop (idx + 1) bs
              in if BS.null line
                   then processRemainingSkip rest skip
                   else processRemainingSkip rest (skip - 1)
    -- Decoding phase (skip exhausted): same as streamDecodeLines' loop.
    decodeLoop acc = do
      mChunk <- await
      case mChunk of
        Nothing -> processRemainingDecode acc
        Just chunk -> splitDecode (acc <> chunk)
    -- | Split and decode all complete lines in the buffer, then await more.
    splitDecode bs =
      case BS.elemIndex 10 bs of
        Nothing -> decodeLoop bs
        Just idx ->
          let line = BS.take idx bs
              rest = BS.drop (idx + 1) bs
          in decodeLine line (splitDecode rest)
    processRemainingDecode bs
      | BS.null bs = pure []
      | otherwise = decodeLine bs (pure [])
    decodeLine line cont =
      if BS.null line
        then cont
        else case decode (BL.fromStrict line) of
               Just a  -> fmap (a :) cont
               Nothing -> cont
