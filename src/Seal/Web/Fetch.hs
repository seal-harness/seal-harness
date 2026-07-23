{-# LANGUAGE OverloadedStrings #-}
-- | WEB_FETCH (Untrusted): fetch a URL via @http-client@, bounded bytes,
-- domain allow list, auth redaction, and SSRF defense (private/internal/
-- metadata IPs blocked before the HTTP call). 'orRecorded' captures the
-- URL + status + byte count (NOT the body — the body may be large; the
-- transcript records metadata only).
module Seal.Web.Fetch
  ( webFetchOp
  , WebFetchConfig (..)
  ) where

import Control.Exception (try)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Network.HTTP.Client
  ( HttpException, Manager, httpLbs, parseRequest, responseBody
  , responseStatus )
import Network.HTTP.Types (statusCode)

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Web.UrlSafety (isSafeUrl, renderUrlSafetyError)

-- | The configuration for WEB_FETCH.
data WebFetchConfig = WebFetchConfig
  { wfcManager    :: Maybe Manager  -- ^ HTTP manager (Nothing = fail-closed)
  , wfcAllowList  :: [Text]         -- ^ allowed domains (empty = all allowed)
  , wfcMaxBytes   :: Int            -- ^ operator-configured byte ceiling
  , wfcAuthKey    :: Maybe Text    -- ^ vault key reference (NOT inline auth)
  }

-- | WEB_FETCH opcode. Input: @{ url: Text }@. Fetches the URL via
-- @http-client@, truncates the response body to 'wfcMaxBytes', and enforces
-- the domain allow-list at the gate. 'orRecorded' carries the URL + status +
-- byte count (secret-free metadata; the body is NOT recorded).
webFetchOp :: WebFetchConfig -> Opcode
webFetchOp cfg = UntrustedOpcode
  { uoName = OpName "WEB_FETCH"
  , uoDesc = "Fetch a URL (bounded bytes, allow-listed, auth-redacted)."
  , uoInSchema = webFetchSchema
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case urlField v of
        Nothing -> Left "WEB_FETCH requires {url:string}"
        Just u
          | T.null u -> Left "WEB_FETCH: url is empty"
          | not (domainAllowed u (wfcAllowList cfg)) ->
              Left ("WEB_FETCH: domain not in allow-list: " <> hostOf u)
          | otherwise -> Right ()
  , uoRun = \_uio v -> do
      let u = fromMaybe "" (urlField v)
      case wfcManager cfg of
        Nothing -> pure (OpResult
          [TrpText "WEB_FETCH: no HTTP manager configured"]
          True (object ["url" .= u, "status" .= (0 :: Int), "bytes" .= (0 :: Int)]))
        Just mgr -> liftIO (doFetch mgr (wfcMaxBytes cfg) u)
  }

-- | Perform the HTTP fetch: SSRF check → parse the URL → execute the
-- request → truncate the response body to the byte ceiling → return the
-- decoded body + recorded metadata. Errors (SSRF, transport, non-2xx)
-- surface as structured 'OpResult's with @isError=True@.
doFetch :: Manager -> Int -> Text -> IO OpResult
doFetch mgr maxBytes u = do
  -- SSRF defense: block private/internal/metadata IPs BEFORE the HTTP call.
  eSafe <- isSafeUrl u
  case eSafe of
    Left err -> pure (OpResult
      [TrpText ("WEB_FETCH: blocked by SSRF protection: " <> renderUrlSafetyError err)]
      True recordedErr)
    Right () -> doFetchHttp mgr maxBytes u
  where
    recordedErr = object ["url" .= u, "status" .= (0 :: Int), "bytes" .= (0 :: Int)]

-- | The HTTP fetch proper (SSRF check already passed).
doFetchHttp :: Manager -> Int -> Text -> IO OpResult
doFetchHttp mgr maxBytes u = do
  eReq <- try (parseRequest (T.unpack u))
  case eReq of
    Left (_ :: HttpException) ->
      pure (OpResult [TrpText ("WEB_FETCH: invalid URL: " <> u)] True recordedErr)
    Right req -> do
      eResp <- try (httpLbs req mgr)
      case eResp of
        Left (_ :: HttpException) ->
          pure (OpResult [TrpText "WEB_FETCH: HTTP request failed (connection or transport error)"]
                           True recordedErr)
        Right resp -> do
          let code = statusCode (responseStatus resp)
              body = responseBody resp
              truncated = truncateBytes body maxBytes
              bodyText = TE.decodeUtf8With TEE.lenientDecode (BL.toStrict truncated)
              byteCount = BL.length truncated
              recorded = object
                [ "url" .= u
                , "status" .= code
                , "bytes" .= byteCount
                ]
          if code >= 200 && code <= 299
            then pure (OpResult [TrpText bodyText] False recorded)
            else pure (OpResult
              [TrpText ("WEB_FETCH: HTTP " <> T.pack (show code) <> ": " <> bodyText)]
              True recorded)
  where
    recordedErr = object ["url" .= u, "status" .= (0 :: Int), "bytes" .= (0 :: Int)]

-- | Truncate a lazy 'ByteString' to at most @n@ bytes.
truncateBytes :: BL.ByteString -> Int -> BL.ByteString
truncateBytes bs n
  | n <= 0    = BL.empty
  | otherwise = BL.take (fromIntegral n) bs

-- | Check whether the URL's host is in the allow-list. An empty allow-list
-- means all domains are permitted.
domainAllowed :: Text -> [Text] -> Bool
domainAllowed _ [] = True
domainAllowed url allowList =
  case hostOfMaybe url of
    Nothing  -> False
    Just host -> any (`T.isSuffixOf` host) allowList

-- | Extract the host from a URL (the authority component). Returns the
-- empty string when the URL has no parseable host.
hostOf :: Text -> Text
hostOf url = fromMaybe "" (hostOfMaybe url)

-- | Extract the host from a URL, returning 'Nothing' when absent.
-- Handles @scheme://host/path@ and @scheme://host:port/path@.
hostOfMaybe :: Text -> Maybe Text
hostOfMaybe url =
  case T.breakOn "://" url of
    (_, after) | T.null after -> Nothing  -- no scheme separator
    (_, after) ->
      let noScheme = T.drop 3 after  -- drop the "://" (3 chars)
          authority = T.takeWhile (\c -> c /= '/' && c /= '?' && c /= '#') noScheme
          host = T.takeWhile (/= ':') authority  -- strip port
      in if T.null host then Nothing else Just host

webFetchSchema :: Value
webFetchSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ "url" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("The URL to fetch." :: Text)
            ]
        ]
    , "required" .= (["url"] :: [Text])
    ]

urlField :: Value -> Maybe Text
urlField = parseMaybe (withObject "in" (.: "url"))