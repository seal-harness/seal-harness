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
module Seal.Util.StrictIO
  ( readFileStrict
  , readFileTextStrict
  , decodeFileStrict
  ) where

import Conduit ( runConduitRes, sinkLazy, sourceFile, (.|) )
import Data.Aeson (FromJSON, decode)
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

-- | Read and decode a JSON file strictly. The handle is closed before the
-- decode runs. Returns 'Nothing' on a decode failure (the caller is
-- expected to 'doesFileExist'-guard the path first).
decodeFileStrict :: FromJSON a => FilePath -> IO (Maybe a)
decodeFileStrict path = decode <$> readFileStrict path