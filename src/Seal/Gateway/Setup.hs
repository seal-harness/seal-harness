{-# LANGUAGE OverloadedStrings #-}
-- | Shared plumbing for the setup endpoints: the body cap and the JSON/error
-- helpers they answer with.
--
-- This module deliberately holds no handlers yet (they arrive with the setup
-- wizard, issue #303). It exists now because the bounded body reader is part of
-- the mutation-guard change: every future setup handler must read its body
-- through 'collectBodyLimited' rather than the unbounded 'Seal.Gateway.API.collectBody'.
--
-- @Seal.Gateway.Setup@ never imports @Seal.Gateway.API@ (that module imports
-- this one), so the helpers are self-contained.
module Seal.Gateway.Setup
  ( maxSetupBodyBytes
  , collectBodyLimited
  , setupJson
  , setupErr
  ) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as A
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.CaseInsensitive qualified as CI
import Data.Text (Text)
import Network.HTTP.Types (Header, HeaderName, Status)
import Network.Wai (Request, Response, getRequestBodyChunk, responseLBS)

-- | Setup request bodies are small JSON documents (a backend tag, a recipient,
-- a path). 8 KiB is two orders of magnitude above the largest legitimate body
-- and keeps a hostile peer from buffering a gigabyte.
maxSetupBodyBytes :: Int
maxSetupBodyBytes = 8192

-- | Read a request body, counting bytes as they arrive.
--
-- 'Left' means the body exceeded the limit; the caller answers @413@. Reading
-- stops at the cap, so the excess is never buffered (the reason to prefer this
-- over a @Content-Length@ check alone, which a chunked request can omit).
collectBodyLimited :: Int -> Request -> IO (Either () ByteString)
collectBodyLimited limit req = go 0 []
  where
    go !bytes acc = do
      chunk <- getRequestBodyChunk req
      if BC.null chunk
        then pure (Right (BS.concat (reverse acc)))
        else
          let bytes' = bytes + BS.length chunk
          in if bytes' > limit
               then pure (Left ())
               else go bytes' (chunk : acc)

-- | A JSON response for a setup handler (no CORS grant, matching the rest of
-- the mutation surface after the guard landed).
setupJson :: Status -> Value -> Response
setupJson st = responseLBS st [jsonHeader] . A.encode

-- | The shared error envelope: @{"error": …, "hint": …?}@. The hint is a
-- copy-pasteable next step (a command, a path to repair); it never carries key
-- material or an identity file's contents.
setupErr :: Status -> Text -> Maybe Text -> Response
setupErr st err mHint = setupJson st $ object $
  ["error" .= err] <> maybe [] (\h -> ["hint" .= h]) mHint

jsonHeader :: Header
jsonHeader = (mkHN "Content-Type", "application/json")

mkHN :: String -> HeaderName
mkHN = CI.mk . BC.pack
