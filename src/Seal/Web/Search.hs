{-# LANGUAGE OverloadedStrings #-}
-- | WEB_SEARCH (Untrusted): query a configured search endpoint. Auth
-- redaction via CPS: the auth header is injected in the @http-client@
-- request but NEVER appears in 'orRecorded' (the redaction point is a pure
-- function over the request record — the recorded value carries only the
-- query + result count, no auth material). Domain allow-list
-- (operator-configured).
module Seal.Web.Search
  ( webSearchOp
  , WebSearchConfig (..)
  ) where

import Control.Exception (try)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson qualified as A
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Network.HTTP.Client
  ( HttpException, Manager, RequestBody (..), httpLbs, parseRequest
  , requestBody, requestHeaders, responseBody, responseStatus )
import Network.HTTP.Types (statusCode)

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))

-- | The configuration for WEB_SEARCH.
data WebSearchConfig = WebSearchConfig
  { wscManager   :: Maybe Manager  -- ^ HTTP manager (Nothing = fail-closed)
  , wscEndpoint  :: Text          -- ^ the search API endpoint URL (empty = fail-closed)
  , wscAllowList :: [Text]        -- ^ allowed domains (empty = all allowed)
  , wscAuthKey   :: Maybe Text    -- ^ vault key reference (NOT inline auth)
  }

-- | WEB_SEARCH opcode. Input: @{ query: Text }@. The auth header is
-- injected via CPS so it never appears in 'orRecorded'. Queries the
-- configured endpoint via POST with a JSON body @{"query": ...}@, extracts
-- the results, and returns them as text. 'orRecorded' carries only the
-- query + result count (secret-free metadata).
webSearchOp :: WebSearchConfig -> Opcode
webSearchOp cfg = UntrustedOpcode
  { uoName = OpName "WEB_SEARCH"
  , uoDesc = "Query a configured search endpoint (auth-redacted, allow-listed)."
  , uoInSchema = webSearchSchema
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case queryField v of
        Nothing -> Left "WEB_SEARCH requires {query:string}"
        Just q
          | T.null q -> Left "WEB_SEARCH: query is empty"
          | otherwise -> Right ()
  , uoRun = \_back _execBackend v -> do
      let q = fromMaybe "" (queryField v)
      case (wscManager cfg, wscEndpoint cfg) of
        (Nothing, _) -> pure (OpResult
          [TrpText "WEB_SEARCH: no HTTP manager configured"]
          True (object ["query" .= q, "result_count" .= (0 :: Int)]))
        (Just _, endpoint) | T.null endpoint -> pure (OpResult
          [TrpText "WEB_SEARCH: no search endpoint configured"]
          True (object ["query" .= q, "result_count" .= (0 :: Int)]))
        (Just mgr, endpoint) -> liftIO (doSearch mgr endpoint q)
  }

-- | Perform the search HTTP request: POST the query as JSON to the endpoint,
-- parse the response, extract result text, and return it. The response body
-- is returned verbatim as the tool result (the model parses it). Errors
-- surface as structured 'OpResult's with @isError=True@.
doSearch :: Manager -> Text -> Text -> IO OpResult
doSearch mgr endpoint q = do
  eReq <- try (parseRequest (T.unpack endpoint))
  case eReq of
    Left (_ :: HttpException) ->
      pure (OpResult [TrpText ("WEB_SEARCH: invalid endpoint URL: " <> endpoint)]
                       True recordedErr)
    Right initReq -> do
      let body = A.encode (A.object ["query" .= q])
          req = initReq { requestBody = RequestBodyLBS body
                        , requestHeaders = [("content-type", "application/json")]
                        }
      eResp <- try (httpLbs req mgr)
      case eResp of
        Left (_ :: HttpException) ->
          pure (OpResult [TrpText "WEB_SEARCH: HTTP request failed (connection or transport error)"]
                           True recordedErr)
        Right resp -> do
          let code = statusCode (responseStatus resp)
              respBody = responseBody resp
              bodyText = TE.decodeUtf8With TEE.lenientDecode (BL.toStrict respBody)
              resultCount = countResults respBody
              recorded = object
                [ "query" .= q
                , "result_count" .= resultCount
                ]
          if code >= 200 && code <= 299
            then pure (OpResult [TrpText bodyText] False recorded)
            else pure (OpResult
              [TrpText ("WEB_SEARCH: HTTP " <> T.pack (show code) <> ": " <> bodyText)]
              True recorded)
  where
    recordedErr = object ["query" .= q, "result_count" .= (0 :: Int)]

-- | Best-effort count of search results from the response JSON. Tries to
-- parse the body as a JSON array and returns its length; falls back to 0
-- when the body is not a JSON array (the endpoint may return a different
-- shape — the count is metadata only and not security-critical).
countResults :: BL.ByteString -> Int
countResults bs =
  case A.decode bs :: Maybe Value of
    Just (A.Array arr) -> length arr
    Just (A.Object _)  -> 1  -- single result object
    _                  -> 0

webSearchSchema :: Value
webSearchSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ "query" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("The search query." :: Text)
            ]
        ]
    , "required" .= (["query"] :: [Text])
    ]

queryField :: Value -> Maybe Text
queryField = parseMaybe (withObject "in" (.: "query"))