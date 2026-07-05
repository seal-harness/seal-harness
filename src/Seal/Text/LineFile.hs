{-# LANGUAGE OverloadedStrings #-}
-- | The reusable line-oriented text-file abstraction.
--
-- A 'LineWindow' is built on 'Seal.Core.Paging'. The pure core ('windowLines')
-- windows a list of lines already split; the bounded IO function
-- 'readLineWindow' reads an opaque 'SafePath' and produces a window WITHOUT
-- materializing the whole file (peak memory is @O(window) + O(1)@). Lines are
-- produced by 'Data.Text.lines' (never @T.splitOn "\\n"@) — see the line
-- semantics table in the design spec.
module Seal.Text.LineFile
  ( LineWindow (..)
  , windowLines
  , readLineWindow
  , renderWindow
  , maxScanBytes
  ) where

import Control.Monad (when)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.IO (Handle, IOMode (ReadMode), SeekMode (AbsoluteSeek), hSeek, withFile)

import Seal.Core.Paging
  (PageParams, Page (..), clamp, paginate, windowSize)
import Seal.Security.Path (SafePath, getSafePath)

-- | A windowed slice of a line-oriented text file. The @lw*@ counts are
-- 0-based line indices.
data LineWindow = LineWindow
  { lwLines     :: ![Text]  -- ^ the windowed lines, in file order
  , lwStart     :: !Int     -- ^ 0-based index of first returned line (== 'pgOffset')
  , lwEnd       :: !Int     -- ^ 0-based index just past the last returned line
                            --   (@lwStart + length lwLines@)
  , lwTotal     :: !Int     -- ^ total line count (lower bound if 'lwTruncated')
  , lwHasMore   :: !Bool    -- ^ @lwEnd < lwTotal || lwTruncated@
  , lwTruncated :: !Bool    -- ^ @True@ if the file exceeded the scan byte ceiling
                            --   (then 'lwTotal' is a lower bound)
  } deriving stock (Eq, Show)

-- | Pure: window over a list of lines already split. Built directly on
-- 'Seal.Core.Paging'. @lwTruncated = False@.
windowLines :: PageParams -> Int -> Maybe Int -> [Text] -> LineWindow
windowLines params offset mLimit ls =
  let Page items off total hasMore = paginate params offset mLimit ls
  in LineWindow
       { lwLines     = items
       , lwStart     = off
       , lwEnd       = off + length items
       , lwTotal     = total
       , lwHasMore   = hasMore
       , lwTruncated = False
       }

-- | The compiled-in default scan byte ceiling (>= 65536, the prior FILE_READ
-- bound). Used by callers that do not have an operator-configured ceiling;
-- 'FILE_READ' resolves the ceiling from the @[retrieval]@ config section (via
-- 'Seal.Config.File.retrievalMaxScanBytes') and passes it in, so this default
-- only applies to bare reuse (e.g. tests, future CRUD) that wants the same
-- out-of-the-box bound.
maxScanBytes :: Int
maxScanBytes = 131072   -- 128 KiB

-- | Bounded IO: read an opaque, already-confined 'SafePath' and window it
-- WITHOUT materializing the whole file. The @maxScanBytes@ argument is the
-- byte ceiling for both streaming passes; the caller ('FILE_READ') resolves
-- it from the config-layer operator bound and the call-layer model request
-- (clamped down, never above the operator bound). Two streaming passes over
-- the file 'Handle', each reading at most @maxScanBytes@ bytes:
--
--   1. __Count pass__: stream lines, counting @lwTotal@, holding O(1) memory.
--      The byte ceiling is enforced at the chunk level while accumulating a
--      line (never read a whole line and then check), so a single newline-free
--      file cannot blow the bound before the check runs. If the ceiling is hit
--      before EOF, stop; set @lwTruncated = True@ and let @lwTotal@ be the
--      count so far (a lower bound; may be @0@ for a newline-free file).
--   2. __Window pass__: stream again, @drop lwStart@, @take size@ lines into the
--      window (O(window) memory).
readLineWindow :: PageParams -> Int -> Maybe Int -> Int -> SafePath -> IO LineWindow
readLineWindow params offset mLimit scanBytes safe =
  withFile (getSafePath safe) ReadMode $ \h -> do
    (total, truncated) <- countLines h scanBytes
    hSeek h AbsoluteSeek 0
    let size  = windowSize params total mLimit
        start = clamp 0 total offset
    win <- windowPass h start size scanBytes truncated
    pure LineWindow
      { lwLines     = win
      , lwStart     = start
      , lwEnd       = start + length win
      , lwTotal     = total
      , lwHasMore   = start + length win < total || truncated
      , lwTruncated = truncated
      }

-- | Count complete lines in the file, streaming, up to @maxScanBytes@.
-- Returns @(count, truncated)@. At EOF (not truncated) a non-empty trailing
-- partial line is counted (matching @Data.Text.lines@). If the byte ceiling is
-- hit before EOF, the in-progress partial line is NOT counted (so @lwTotal@ is
-- a lower bound; a newline-free file yields @0@).
countLines :: Handle -> Int -> IO (Int, Bool)
countLines h scanBytes = do
  bytesRef <- newIORef (0 :: Int)
  countRef <- newIORef (0 :: Int)
  resRef   <- newIORef BS.empty
  let go = do
        bytes <- readIORef bytesRef
        if bytes >= scanBytes
          then pure True
          else do
            chunk <- BS.hGet h 4096
            if BS.null chunk
              then do
                res <- readIORef resRef
                if BS.null res
                  then pure False
                  else do modifyIORef' countRef (+ 1); pure False
              else do
                -- Enforce the ceiling at the byte/chunk level: truncate this
                -- chunk to the remaining budget so a single read never blows
                -- the bound. If the chunk is clipped, the next loop iteration
                -- sees bytes == scanBytes and stops (truncated).
                let remaining = scanBytes - bytes
                    chunk'    = if BS.length chunk <= remaining
                                  then chunk
                                  else BS.take remaining chunk
                    clipped   = BS.length chunk' < BS.length chunk
                modifyIORef' bytesRef (+ BS.length chunk')
                res0 <- readIORef resRef
                let (ls, newRes) = splitLines (res0 <> chunk')
                writeIORef resRef newRes
                modifyIORef' countRef (+ length ls)
                if clipped
                  then pure True   -- hit the ceiling mid-chunk
                  else go
  truncated <- go
  count <- readIORef countRef
  pure (count, truncated)

-- | Re-stream the file, drop @start@ complete lines, take up to @size@ into the
-- window. Stops at @maxScanBytes@ or EOF. When @not truncated@, a non-empty
-- trailing partial line at EOF is emitted as a final line (matching
-- @Data.Text.lines@); when @truncated@ the trailing partial is discarded (it
-- was not counted in the count pass).
windowPass :: Handle -> Int -> Int -> Int -> Bool -> IO [Text]
windowPass h start size scanBytes truncated
  | size <= 0 = pure []
  | otherwise = do
      bytesRef    <- newIORef (0 :: Int)
      curRef      <- newIORef BS.empty     -- bytes of the in-progress line
      skippedRef  <- newIORef (0 :: Int)   -- complete lines passed over
      takenRef    <- newIORef (0 :: Int)   -- lines added to the window
      winRef      <- newIORef ([] :: [Text])  -- collected in reverse
      let stop = do taken <- readIORef takenRef; pure (taken >= size)
          processChunk chunk = do
            cur0 <- readIORef curRef
            let (completeLines, residual) = splitLines (cur0 <> chunk)
            writeIORef curRef residual
            mapM_ emitLine completeLines
          emitLine lbs = do
            skipped <- readIORef skippedRef
            taken   <- readIORef takenRef
            if skipped < start
              then modifyIORef' skippedRef (+ 1)
              else if taken < size
                     then do modifyIORef' winRef (TE.decodeUtf8Lenient lbs :)
                             modifyIORef' takenRef (+ 1)
                     else modifyIORef' skippedRef (+ 1)
          go = do
            done <- stop
            if done
              then pure ()
              else do
                bytes <- readIORef bytesRef
                if bytes >= scanBytes
                  then pure ()
                  else do
                    chunk <- BS.hGet h 4096
                    if BS.null chunk
                      then pure ()
                      else do
                        -- Truncate this chunk to the remaining byte budget so
                        -- a single read never blows the bound; matches the
                        -- count pass.
                        let remaining = scanBytes - bytes
                            chunk'    = if BS.length chunk <= remaining
                                          then chunk
                                          else BS.take remaining chunk
                        modifyIORef' bytesRef (+ BS.length chunk')
                        processChunk chunk'
                        go
      go
      -- Flush a trailing partial line at EOF (only when not truncated; if we
      -- stopped at the byte ceiling, the partial is not a counted line).
      cur     <- readIORef curRef
      taken   <- readIORef takenRef
      skipped <- readIORef skippedRef
      when (not truncated && taken < size && not (BS.null cur) && skipped >= start)
        (modifyIORef' winRef (TE.decodeUtf8Lenient cur :))
      reverse <$> readIORef winRef

-- | Split a ByteString into complete lines (without their trailing newline)
-- plus the residual partial line. A line is complete when it ends with a
-- newline (@0x0A@); the newline is consumed. Matches @Data.Text.lines@: a
-- trailing newline does NOT produce an empty final line, and a final partial
-- line (no trailing newline) is returned as the residual.
splitLines :: BS.ByteString -> ([BS.ByteString], BS.ByteString)
splitLines s
  | BS.null s = ([], BS.empty)
  | otherwise =
      case BS.elemIndex 0x0A s of
        Nothing -> ([], s)
        Just i  ->
          let line = BS.take i s
              rest = BS.drop (i + 1) s
              (ls, residual) = splitLines rest
          in (line : ls, residual)

-- | Render the window: content + a machine-actionable footer telling the model
-- how to page forward. Lines are joined with @"\n"@ (@T.intercalate@,
-- preserving line content), then a blank line, then exactly one footer line.
-- Footers use ASCII hyphen-minus and 1-based inclusive display line numbers
-- (@lwStart+1 .. lwEnd@); the @offset=@ value in the footer is the **0-based**
-- @lwEnd@ (copy-paste ready).
--
-- The footer states overlap (an empty window at end-of-file satisfies both
-- "offset past end" and "final"; a newline-free file over the cap satisfies
-- both "empty" and "truncated"), so the footer is chosen by a **total, ordered**
-- guard — first match wins. Implemented in exactly this order.
renderWindow :: LineWindow -> Text
renderWindow lw =
  let body   = T.intercalate "\n" (lwLines lw)
      footer = renderFooter lw
  in if T.null body then footer else body <> "\n\n" <> footer

renderFooter :: LineWindow -> Text
renderFooter lw =
  let n     = lwTotal lw
      s     = lwStart lw
      e     = lwEnd lw
      trunc = lwTruncated lw
  in
    -- Guard 1: empty file but truncated (newline-free file over the cap).
    if n == 0 && trunc
      then "[no line break within the scan limit; file may be a single long line or non-line-oriented]"
    -- Guard 2: genuinely empty file (0 lines, not truncated).
    else if n == 0
      then "[empty file (0 lines)]"
    -- Guard 3: empty window on a non-empty file (offset at/past the counted end).
    else if s == e
      then if trunc
             then "[offset " <> tshow s <> " reached the scan limit (" <> tshow n <> "+ lines counted so far); read with offset=0 to restart]"
             else "[offset " <> tshow s <> " is past end of file (" <> tshow n <> " lines); read with offset=0 to start over]"
    -- Guards 4-6 fire only when s < e, so no inverted range is possible.
    -- Guard 4: truncated (file exceeds scan limit; more may exist).
    else if trunc
      then "[lines " <> tshow (s + 1) <> "-" <> tshow e <> " of >=" <> tshow n <> " (file exceeds scan limit; more may exist) - read with offset=" <> tshow e <> " for the next window]"
    -- Guard 5: more lines remain.
    else if e < n
      then "[lines " <> tshow (s + 1) <> "-" <> tshow e <> " of " <> tshow n <> "; " <> tshow (n - e) <> " more - read with offset=" <> tshow e <> " for the next window]"
    -- Guard 6: final window (e == n, s < e).
    else
      "[lines " <> tshow (s + 1) <> "-" <> tshow e <> " of " <> tshow n <> " (end of file)]"

-- | Show an 'Int' into 'Text' (used for footer formatting).
tshow :: Int -> Text
tshow = T.pack . show