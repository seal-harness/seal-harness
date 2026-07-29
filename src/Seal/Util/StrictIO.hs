-- | Strict file-reading helpers that close the underlying file descriptor
-- immediately after the bytes are read.
--
-- The lazy 'Data.ByteString.Lazy.readFile' / 'Data.Text.IO.readFile' helpers
-- keep the file handle open until the lazy structure is fully consumed, which
-- is GC-dependent. The 'Seal.Gateway.ListsSnapshot.buildListsSnapshot' hot
-- path reads hundreds of small files per request (111 sessions × multiple
-- files each) and the lazy handles pile up faster than the GC reclaims them,
-- hitting the OS soft FD limit ('EMFILE' / @resource exhausted (Too many
-- open files)@).
--
-- 'readFileStrict' reads the whole file strictly inside a 'withFile' bracket
-- and forces the result to the file's reported length, so the handle is
-- closed before the helper returns. Use these instead of the lazy 'readFile'
-- variants for any path that's called repeatedly across many files.
module Seal.Util.StrictIO
  ( readFileStrict
  , readFileTextStrict
  , decodeFileStrict
  ) where

import Data.Aeson (FromJSON, decode')
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import System.IO (withFile, IOMode (ReadMode))

-- | Read a file strictly as a 'ByteString' inside a 'withFile' bracket and
-- force the result so the handle is closed before the helper returns. The
-- whole file is read into memory. Callers 'doesFileExist'-guard the path
-- first (the lazy variants they replace did the same).
readFileStrict :: FilePath -> IO ByteString
readFileStrict path =
  withFile path ReadMode $ \h -> do
    bs <- BS.hGetContents h
    -- 'BS.hGetContents' returns a strict ByteString (the strict-interface
    -- version reads the whole handle eagerly), but force the length to be
    -- explicit about the read completing before the bracket closes.
    let !_ = BS.length bs
    pure bs

-- | Read a file strictly as 'Text' by reading bytes strictly then decoding.
-- The handle is closed before the decode runs.
readFileTextStrict :: FilePath -> IO Text
readFileTextStrict path = TE.decodeUtf8 <$> readFileStrict path

-- | Read and decode a JSON file strictly. The handle is closed before the
-- decode runs. Returns 'Nothing' on a decode failure (the caller is
-- expected to 'doesFileExist'-guard the path first).
decodeFileStrict :: FromJSON a => FilePath -> IO (Maybe a)
decodeFileStrict path = decode' . BL.fromStrict <$> readFileStrict path