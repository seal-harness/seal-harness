{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- | WEB_SEARCH (Untrusted): multi-provider web search. Dispatches to one of
-- five backends (Parallel, SearXNG, Exa, Firecrawl, Custom) selected via
-- 'wscProvider'. Parallel is the zero-config default (free MCP endpoint, no
-- API key). API keys are vault references resolved at runtime via
-- 'vaultGetByName' — they are injected into HTTP requests but NEVER appear in
-- 'orRecorded' (the transcript records only query, result count, and provider
-- name). Domain allow-list is operator-configured.
module Seal.Web.Search
  ( webSearchOp
  , WebSearchConfig (..)
  , SearchProvider (..)
  , SearchResult (..)
  , parseProvider
  , providerName
  , encodeResults
  , dispatchSearch
  ) where

import Control.Exception (try)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, withObject, (.:), (.:?), (.!=), (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy qualified as BL
import Data.Function (on)
import Data.List (sortBy)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Data.Vector qualified as V
import Network.HTTP.Client
  ( HttpException, Manager, RequestBody (..), httpLbs, method, parseRequest
  , requestBody, requestHeaders, responseBody, responseStatus )
import Network.HTTP.Types (methodPost, statusCode, urlEncode)

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.ISA.Ops.Secret (vaultGetByName)
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Vault.Commands (VaultRuntime)
import Seal.Web.SearXngSetup (ensureSearXng)

-- | Which search backend to use. 'ProviderParallel' is the zero-config
-- default (free MCP endpoint, no API key needed).
data SearchProvider
  = ProviderParallel    -- ^ Parallel Search (free MCP or REST with key)
  | ProviderSearXNG     -- ^ Self-hosted SearXNG instance
  | ProviderExa         -- ^ Exa search API (requires key)
  | ProviderFirecrawl   -- ^ Firecrawl search API (requires key)
  | ProviderCustom      -- ^ User-configured custom endpoint (legacy behavior)
  deriving stock (Eq, Show)

-- | Parse a provider name from config text. Unknown values default to
-- 'ProviderParallel' (the zero-config default).
parseProvider :: Text -> SearchProvider
parseProvider t = case T.toLower t of
  "searxng"   -> ProviderSearXNG
  "exa"       -> ProviderExa
  "firecrawl" -> ProviderFirecrawl
  "custom"    -> ProviderCustom
  _           -> ProviderParallel

-- | Render a provider to its canonical string name (for 'orRecorded').
providerName :: SearchProvider -> Text
providerName ProviderParallel  = "parallel"
providerName ProviderSearXNG   = "searxng"
providerName ProviderExa       = "exa"
providerName ProviderFirecrawl = "firecrawl"
providerName ProviderCustom    = "custom"

-- | A single normalized search result. All providers decode their
-- provider-specific JSON into this shape before re-encoding for the model.
data SearchResult = SearchResult
  { srTitle       :: Text
  , srUrl         :: Text
  , srDescription :: Text
  , srPosition    :: Int
  } deriving stock (Eq, Show)

-- | Encode search results as JSON for the model ('orParts'). The shape is
-- @{"results": [{"title","url","description","position"}, ...]}@.
encodeResults :: [SearchResult] -> Text
encodeResults results = TE.decodeUtf8 (BL.toStrict (A.encode body))
  where
    body = A.object ["results" .= map toValue results]
    toValue (SearchResult title url desc pos) = A.object
      [ "title"       .= title
      , "url"         .= url
      , "description" .= desc
      , "position"    .= pos
      ]

-- | The configuration for WEB_SEARCH.
data WebSearchConfig = WebSearchConfig
  { wscManager     :: Maybe Manager     -- ^ HTTP manager (Nothing = fail-closed)
  , wscProvider    :: SearchProvider    -- ^ which backend to use
  , wscEndpoint    :: Text             -- ^ endpoint URL (empty = use provider default)
  , wscAllowList   :: [Text]           -- ^ allowed domains (empty = all allowed)
  , wscAuthKey     :: Maybe Text       -- ^ vault key reference for API key
  , wscMaxResults  :: Int              -- ^ max results to return (0 = provider default)
  , wscVault       :: Maybe VaultRuntime  -- ^ vault for resolving API keys
  , wscSearXngUrl  :: Maybe Text       -- ^ SearXNG instance URL (Nothing = localhost:8888)
  }

-- | WEB_SEARCH opcode. Input: @{ query: Text, limit?: Int }@. Dispatches to
-- the configured provider ('wscProvider'). 'orRecorded' carries only the
-- query, result count, and provider name — never API keys or response bodies.
webSearchOp :: WebSearchConfig -> Opcode
webSearchOp cfg = UntrustedOpcode
  { uoName = OpName "WEB_SEARCH"
  , uoDesc = "Search the web using the configured provider (parallel, searxng, exa, firecrawl, or custom). Returns ranked results with title, URL, and description."
  , uoInSchema = webSearchSchema
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case queryField v of
        Nothing -> Left "WEB_SEARCH requires {query:string}"
        Just q
          | T.null q -> Left "WEB_SEARCH: query is empty"
          | otherwise -> case limitField v of
              Just n | n < 1 -> Left "WEB_SEARCH: limit must be >= 1"
              _ -> Right ()
  , uoRun = \_uio v -> do
      let q = fromMaybe "" (queryField v)
          userLimit = limitField v
          cfg' = cfg { wscMaxResults = fromMaybe (wscMaxResults cfg) userLimit }
      case wscManager cfg' of
        Nothing -> pure (OpResult
          [TrpText "WEB_SEARCH: no HTTP manager configured"]
          True (recorded cfg' q 0))
        Just mgr -> liftIO (dispatchSearch mgr cfg' q)
  }

-- | Build the secret-free 'orRecorded' metadata value for a search call.
recorded :: WebSearchConfig -> Text -> Int -> Value
recorded cfg q n = object
  [ "query"        .= q
  , "result_count" .= n
  , "provider"     .= providerName (wscProvider cfg)
  ]

-- | A standalone 'recorded' that takes the provider name directly (used by
-- stub/error paths that don't have a full config in scope).
recorded' :: Text -> Text -> Int -> Value
recorded' q provider n = object
  [ "query"        .= q
  , "result_count" .= n
  , "provider"     .= provider
  ]

-- | Construct an error 'OpResult' with recorded metadata.
mkError :: Text -> Text -> Text -> OpResult
mkError q provider msg = OpResult
  [TrpText msg]
  True (recorded' q provider 0)

-- | Decode a response body to 'Text' (lenient — never throws on bad UTF-8).
bodyText :: BL.ByteString -> Text
bodyText = TE.decodeUtf8With TEE.lenientDecode . BL.toStrict

-- | Dispatch to the appropriate provider search function.
dispatchSearch :: Manager -> WebSearchConfig -> Text -> IO OpResult
dispatchSearch mgr cfg q = case wscProvider cfg of
  ProviderParallel  -> searchParallel mgr cfg q
  ProviderSearXNG   -> searchSearXNG mgr cfg q
  ProviderExa       -> searchExa mgr cfg q
  ProviderFirecrawl -> searchFirecrawl mgr cfg q
  ProviderCustom    -> searchCustom mgr cfg q

-- | Resolve an API key from the vault if configured. Returns 'Nothing' if
-- no vault key is configured or the vault is unavailable. The resolved key
-- never appears in 'orRecorded' — it is injected only into the HTTP request.
resolveApiKey :: WebSearchConfig -> IO (Maybe Text)
resolveApiKey cfg = case (wscVault cfg, wscAuthKey cfg) of
  (Just rt, Just keyName) -> do
    eVal <- vaultGetByName rt keyName
    pure (either (const Nothing) Just eVal)
  _ -> pure Nothing

-- ---------------------------------------------------------------------------
-- Provider 1: Parallel (zero-config MCP + REST with key)
-- ---------------------------------------------------------------------------

searchParallel :: Manager -> WebSearchConfig -> Text -> IO OpResult
searchParallel mgr cfg q = do
  mKey <- resolveApiKey cfg
  case mKey of
    Just key -> searchParallelRest mgr cfg q key
    Nothing  -> searchParallelMcp mgr cfg q

-- | Mode A — MCP endpoint (zero-config, no API key). Uses JSON-RPC over HTTP
-- (Streamable HTTP transport). The response may be @application/json@
-- (plain JSON-RPC) or @text/event-stream@ (SSE).
searchParallelMcp :: Manager -> WebSearchConfig -> Text -> IO OpResult
searchParallelMcp mgr _cfg q = do
  eReq <- try (parseRequest "https://search.parallel.ai/mcp")
  case eReq of
    Left (_ :: HttpException) ->
      pure (mkError q "parallel" "WEB_SEARCH: failed to parse Parallel MCP URL")
    Right initReq -> do
      let body = A.encode $ A.object
            [ "jsonrpc" .= ("2.0" :: Text)
            , "method"  .= ("tools/call" :: Text)
            , "params"  .= A.object
                [ "name"      .= ("web_search" :: Text)
                , "arguments" .= A.object ["query" .= q]
                ]
            , "id"      .= (1 :: Int)
            ]
          req = initReq
            { method = methodPost
            , requestBody = RequestBodyLBS body
            , requestHeaders =
                [ ("content-type", "application/json")
                , ("accept", "application/json, text/event-stream")
                ]
            }
      eResp <- try (httpLbs req mgr)
      case eResp of
        Left (_ :: HttpException) ->
          pure (mkError q "parallel" "WEB_SEARCH: Parallel MCP request failed")
        Right resp -> do
          let code = statusCode (responseStatus resp)
              respBody = responseBody resp
          if code >= 200 && code <= 299
            then parseParallelMcpResponse q respBody
            else pure (mkError q "parallel" $
              "WEB_SEARCH: Parallel MCP HTTP " <> T.pack (show code) <> ": "
              <> bodyText respBody)

-- | Extract text content from the MCP @result.content@ array. Each item has
-- @{type: "text", text: "..."}@; we concatenate all text items.
extractMcpContentText :: Value -> Text
extractMcpContentText val = fromMaybe "" $
  parseMaybe (withObject "result" (.: "content")) val >>= \case
    A.Array arr -> Just $ T.intercalate "\n"
      [ fromMaybe "" (parseMaybe (withObject "item" (.: "text")) item)
      | item <- V.toList arr
      , hasTextType item
      ]
    _ -> Nothing
  where
    hasTextType v =
      parseMaybe (withObject "item" (.: "type")) v == Just ("text" :: Text)

-- | Parse the text content from Parallel MCP into a 'SearchResult' list.
-- The text may be JSON with a @results@ array, or a bare JSON array, or
-- plain text (in which case we return no structured results).
parseParallelResults :: Text -> [SearchResult]
parseParallelResults txt =
  case A.decode (BL.fromStrict (TE.encodeUtf8 txt)) :: Maybe Value of
    Just (A.Object o) ->
      case parseMaybe (withObject "r" (.: "results")) (A.Object o) of
        Just (A.Array arr) -> zipWith fromParallelJson [1..] (V.toList arr)
        _ -> []
    Just (A.Array arr) -> zipWith fromParallelJson [1..] (V.toList arr)
    _ -> []
  where
    fromParallelJson :: Int -> Value -> SearchResult
    fromParallelJson pos v = fromMaybe (SearchResult "" "" "" pos) $
      parseMaybe (withObject "result" $ \obj -> do
        url      <- obj .: "url"
        title    <- obj .: "title"
        excerpts <- obj .:? "excerpts" .!= []
        let desc = T.intercalate " " (map asText excerpts)
        pure (SearchResult title url desc pos)) v

    asText :: Value -> Text
    asText (A.String s) = s
    asText _ = ""

parseParallelMcpResponse :: Text -> BL.ByteString -> IO OpResult
parseParallelMcpResponse q respBody =
  case A.decode respBody :: Maybe Value of
    Nothing -> pure (mkError q "parallel" "WEB_SEARCH: Parallel MCP returned non-JSON")
    Just val -> case parseMaybe (withObject "rpc" (.: "result")) val of
      Nothing -> pure (mkError q "parallel" "WEB_SEARCH: Parallel MCP missing result field")
      Just resultVal -> do
        let contentText = extractMcpContentText resultVal
            results = parseParallelResults contentText
        pure (OpResult
          [TrpText (encodeResults results)]
          False (recorded' q "parallel" (length results)))

-- | Mode B — REST API (with API key for higher limits).
searchParallelRest :: Manager -> WebSearchConfig -> Text -> Text -> IO OpResult
searchParallelRest mgr cfg q apiKey = do
  let endpoint = if T.null (wscEndpoint cfg)
                   then "https://api.parallel.ai/v1/search"
                   else wscEndpoint cfg
      maxR = min (wscMaxResults cfg) 20
      body = A.encode $ A.object
        [ "objective"      .= q
        , "search_queries" .= [q]
        , "mode"           .= ("fast" :: Text)
        , "max_results"    .= maxR
        ]
  eReq <- try (parseRequest (T.unpack endpoint))
  case eReq of
    Left (_ :: HttpException) ->
      pure (mkError q "parallel" "WEB_SEARCH: invalid Parallel REST endpoint URL")
    Right initReq -> do
      let req = initReq
            { method = methodPost
            , requestBody = RequestBodyLBS body
            , requestHeaders =
                [ ("content-type", "application/json")
                , ("x-api-key", TE.encodeUtf8 apiKey)
                ]
            }
      eResp <- try (httpLbs req mgr)
      case eResp of
        Left (_ :: HttpException) ->
          pure (mkError q "parallel" "WEB_SEARCH: Parallel REST request failed")
        Right resp -> do
          let code = statusCode (responseStatus resp)
              respBody = responseBody resp
          if code >= 200 && code <= 299
            then parseParallelRestResponse q respBody
            else pure (mkError q "parallel" $
              "WEB_SEARCH: Parallel REST HTTP " <> T.pack (show code) <> ": "
              <> bodyText respBody)

parseParallelRestResponse :: Text -> BL.ByteString -> IO OpResult
parseParallelRestResponse q respBody =
  case A.decode respBody :: Maybe Value of
    Nothing -> pure (mkError q "parallel" "WEB_SEARCH: Parallel REST returned non-JSON")
    Just val -> case parseMaybe (withObject "r" (.: "results")) val of
      Just (A.Array arr) -> do
        let results = zipWith fromParallelJson [1..] (V.toList arr)
        pure (OpResult [TrpText (encodeResults results)] False (recorded' q "parallel" (length results)))
      _ -> pure (mkError q "parallel" "WEB_SEARCH: Parallel REST missing results array")
  where
    fromParallelJson pos v = fromMaybe (SearchResult "" "" "" pos) $
      parseMaybe (withObject "result" $ \obj -> do
        url      <- obj .: "url"
        title    <- obj .: "title"
        excerpts <- obj .:? "excerpts" .!= []
        let desc = T.intercalate " " (map asText excerpts)
        pure (SearchResult title url desc pos)) v

    asText (A.String s) = s
    asText _ = ""

-- ---------------------------------------------------------------------------
-- Provider 2: SearXNG (self-hosted, free)
-- ---------------------------------------------------------------------------

-- | URL-encode a 'Text' for use in a query string.
urlEncodeText :: Text -> Text
urlEncodeText = TE.decodeUtf8 . urlEncode False . TE.encodeUtf8

searchSearXNG :: Manager -> WebSearchConfig -> Text -> IO OpResult
searchSearXNG mgr cfg q = do
  let baseUrl = fromMaybe "http://localhost:8888" (wscSearXngUrl cfg)
  result <- searXngSearchOnce mgr cfg q baseUrl
  case result of
    Right opRes -> pure opRes
    Left errMsg -> do
      installed <- ensureSearXng mgr baseUrl
      if installed
        then do
          result2 <- searXngSearchOnce mgr cfg q baseUrl
          case result2 of
            Right opRes    -> pure opRes
            Left errMsg2   -> pure (mkError q "searxng" errMsg2)
        else pure (mkError q "searxng" $
          errMsg <> " Auto-install attempted but failed. Ensure Docker is running or start SearXNG manually.")

searXngSearchOnce :: Manager -> WebSearchConfig -> Text -> Text -> IO (Either Text OpResult)
searXngSearchOnce mgr cfg q baseUrl = do
  let endpoint = baseUrl <> "/search"
      maxR = wscMaxResults cfg
      fullUrl = endpoint <> "?" <> "q=" <> urlEncodeText q <> "&format=json&pageno=1"
  eReq <- try (parseRequest (T.unpack fullUrl))
  case eReq of
    Left (_ :: HttpException) ->
      pure (Left "WEB_SEARCH: invalid SearXNG URL")
    Right initReq -> do
      let req = initReq { requestHeaders = [("accept", "application/json")] }
      eResp <- try (httpLbs req mgr)
      case eResp of
        Left (_ :: HttpException) ->
          pure (Left "WEB_SEARCH: SearXNG request failed (is the instance running?)")
        Right resp -> do
          let code = statusCode (responseStatus resp)
              respBody = responseBody resp
          if code >= 200 && code <= 299
            then Right <$> parseSearXngResponse q maxR respBody
            else pure (Left $ "WEB_SEARCH: SearXNG HTTP " <> T.pack (show code) <> ": " <> bodyText respBody)

parseSearXngResponse :: Text -> Int -> BL.ByteString -> IO OpResult
parseSearXngResponse q maxR respBody =
  case A.decode respBody :: Maybe Value of
    Nothing -> pure (mkError q "searxng" "WEB_SEARCH: SearXNG returned non-JSON (is JSON format enabled in settings.yml?)")
    Just val -> case parseMaybe (withObject "r" (.: "results")) val of
      Just (A.Array arr) -> do
        let rawResults = V.toList arr
            scored = [(scoreOf r, r) | r <- rawResults]
            sorted = map snd (sortBy (flip compare `on` fst) scored)
            taken = take maxR sorted
            results = zipWith fromSearXngJson [1..] taken
        pure (OpResult [TrpText (encodeResults results)] False (recorded' q "searxng" (length results)))
      _ -> pure (mkError q "searxng" "WEB_SEARCH: SearXNG missing results array")
  where
    scoreOf :: Value -> Double
    scoreOf v = fromMaybe 0 $
      parseMaybe (withObject "r" (.: "score")) v >>= \case
        A.Number n -> Just (realToFrac n)
        _ -> Nothing

    fromSearXngJson :: Int -> Value -> SearchResult
    fromSearXngJson pos v = fromMaybe (SearchResult "" "" "" pos) $
      parseMaybe (withObject "r" $ \obj -> do
        url     <- obj .:  "url"
        title   <- obj .:  "title"
        content <- obj .:? "content" .!= ""
        pure (SearchResult title url content pos)) v

-- ---------------------------------------------------------------------------
-- Provider 3: Exa (API key required)
-- ---------------------------------------------------------------------------

searchExa :: Manager -> WebSearchConfig -> Text -> IO OpResult
searchExa mgr cfg q = do
  mKey <- resolveApiKey cfg
  case mKey of
    Nothing -> pure (mkError q "exa"
      "WEB_SEARCH: Exa requires an API key. Set vault key 'exa_api_key' and configure [web] search_auth_key.")
    Just apiKey -> do
      let endpoint = if T.null (wscEndpoint cfg)
                       then "https://api.exa.ai/search"
                       else wscEndpoint cfg
          maxR = wscMaxResults cfg
          body = A.encode $ A.object
            [ "query"       .= q
            , "numResults"  .= maxR
            , "contents"    .= A.object ["highlights" .= True]
            ]
      eReq <- try (parseRequest (T.unpack endpoint))
      case eReq of
        Left (_ :: HttpException) ->
          pure (mkError q "exa" "WEB_SEARCH: invalid Exa endpoint URL")
        Right initReq -> do
          let req = initReq
                { method = methodPost
                , requestBody = RequestBodyLBS body
                , requestHeaders =
                    [ ("content-type", "application/json")
                    , ("x-api-key", TE.encodeUtf8 apiKey)
                    ]
                }
          eResp <- try (httpLbs req mgr)
          case eResp of
            Left (_ :: HttpException) ->
              pure (mkError q "exa" "WEB_SEARCH: Exa request failed")
            Right resp -> do
              let code = statusCode (responseStatus resp)
                  respBody = responseBody resp
              if code >= 200 && code <= 299
                then parseExaResponse q respBody
                else pure (mkError q "exa" $
                  "WEB_SEARCH: Exa HTTP " <> T.pack (show code) <> ": "
                  <> bodyText respBody)

parseExaResponse :: Text -> BL.ByteString -> IO OpResult
parseExaResponse q respBody =
  case A.decode respBody :: Maybe Value of
    Nothing -> pure (mkError q "exa" "WEB_SEARCH: Exa returned non-JSON")
    Just val -> case parseMaybe (withObject "r" (.: "results")) val of
      Just (A.Array arr) -> do
        let results = zipWith fromExaJson [1..] (V.toList arr)
        pure (OpResult [TrpText (encodeResults results)] False (recorded' q "exa" (length results)))
      _ -> pure (mkError q "exa" "WEB_SEARCH: Exa missing results array")
  where
    fromExaJson pos v = fromMaybe (SearchResult "" "" "" pos) $
      parseMaybe (withObject "r" $ \obj -> do
        url        <- obj .:  "url"
        title      <- obj .:  "title"
        highlights <- obj .:? "highlights" .!= []
        let desc = T.intercalate " " (map asText highlights)
        pure (SearchResult title url desc pos)) v

    asText (A.String s) = s
    asText _ = ""

-- ---------------------------------------------------------------------------
-- Provider 4: Firecrawl (API key required)
-- ---------------------------------------------------------------------------

searchFirecrawl :: Manager -> WebSearchConfig -> Text -> IO OpResult
searchFirecrawl mgr cfg q = do
  mKey <- resolveApiKey cfg
  case mKey of
    Nothing -> pure (mkError q "firecrawl"
      "WEB_SEARCH: Firecrawl requires an API key. Set vault key 'firecrawl_api_key' and configure [web] search_auth_key.")
    Just apiKey -> do
      let endpoint = if T.null (wscEndpoint cfg)
                       then "https://api.firecrawl.dev/v2/search"
                       else wscEndpoint cfg
          maxR = wscMaxResults cfg
          body = A.encode $ A.object
            [ "query" .= q
            , "limit" .= maxR
            ]
      eReq <- try (parseRequest (T.unpack endpoint))
      case eReq of
        Left (_ :: HttpException) ->
          pure (mkError q "firecrawl" "WEB_SEARCH: invalid Firecrawl endpoint URL")
        Right initReq -> do
          let req = initReq
                { method = methodPost
                , requestBody = RequestBodyLBS body
                , requestHeaders =
                    [ ("content-type", "application/json")
                    , ("authorization", "Bearer " <> TE.encodeUtf8 apiKey)
                    ]
                }
          eResp <- try (httpLbs req mgr)
          case eResp of
            Left (_ :: HttpException) ->
              pure (mkError q "firecrawl" "WEB_SEARCH: Firecrawl request failed")
            Right resp -> do
              let code = statusCode (responseStatus resp)
                  respBody = responseBody resp
              if code >= 200 && code <= 299
                then parseFirecrawlResponse q respBody
                else pure (mkError q "firecrawl" $
                  "WEB_SEARCH: Firecrawl HTTP " <> T.pack (show code) <> ": "
                  <> bodyText respBody)

parseFirecrawlResponse :: Text -> BL.ByteString -> IO OpResult
parseFirecrawlResponse q respBody =
  case A.decode respBody :: Maybe Value of
    Nothing -> pure (mkError q "firecrawl" "WEB_SEARCH: Firecrawl returned non-JSON")
    Just val -> do
      let results = extractFirecrawlResults val
      if null results
        then pure (mkError q "firecrawl" "WEB_SEARCH: Firecrawl returned no results")
        else pure (OpResult [TrpText (encodeResults results)] False (recorded' q "firecrawl" (length results)))

-- | Extract results from a Firecrawl response, trying multiple shapes:
-- v2: @data.web[]@ → @data.results[]@ → @web[]@ → @results[]@ → @data@ (flat list, v1).
extractFirecrawlResults :: Value -> [SearchResult]
extractFirecrawlResults val =
  case tryPath [fromText "data", fromText "web"] val of
    Just rs -> rs
    Nothing -> case tryPath [fromText "data", fromText "results"] val of
      Just rs -> rs
      Nothing -> case tryPath [fromText "web"] val of
        Just rs -> rs
        Nothing -> case tryPath [fromText "results"] val of
          Just rs -> rs
          Nothing -> case parseMaybe (withObject "r" (.: "data")) val of
            Just (A.Array arr) -> zipWith fromFirecrawlJson [1..] (V.toList arr)
            _ -> []
  where
    tryPath :: [A.Key] -> Value -> Maybe [SearchResult]
    tryPath keys v = do
      let go []     val' = Just val'
          go (k:ks) val' = parseMaybe (withObject "o" (.: k)) val' >>= go ks
      resultVal <- go keys v
      case resultVal of
        A.Array arr -> Just (zipWith fromFirecrawlJson [1..] (V.toList arr))
        _ -> Nothing

    fromFirecrawlJson :: Int -> Value -> SearchResult
    fromFirecrawlJson pos v = fromMaybe (SearchResult "" "" "" pos) $
      parseMaybe (withObject "r" $ \obj -> do
        url   <- obj .:  "url"
        title <- obj .:  "title"
        desc  <- obj .:? "description" .!= ""
        pos'  <- obj .:? "position" .!= pos
        pure (SearchResult title url desc pos')) v

-- ---------------------------------------------------------------------------
-- Provider 5: Custom (legacy single-endpoint compatibility)
-- ---------------------------------------------------------------------------

searchCustom :: Manager -> WebSearchConfig -> Text -> IO OpResult
searchCustom mgr cfg q
  | T.null (wscEndpoint cfg) = pure (mkError q "custom"
      "WEB_SEARCH: no search endpoint configured and no provider selected. Set [web] search_provider or search_endpoint.")
  | otherwise = do
      eReq <- try (parseRequest (T.unpack (wscEndpoint cfg)))
      case eReq of
        Left (_ :: HttpException) ->
          pure (mkError q "custom" ("WEB_SEARCH: invalid endpoint URL: " <> wscEndpoint cfg))
        Right initReq -> do
          let body = A.encode (A.object ["query" .= q])
              req = initReq
                { method = methodPost
                , requestBody = RequestBodyLBS body
                , requestHeaders = [("content-type", "application/json")]
                }
          eResp <- try (httpLbs req mgr)
          case eResp of
            Left (_ :: HttpException) ->
              pure (mkError q "custom" "WEB_SEARCH: HTTP request failed (connection or transport error)")
            Right resp -> do
              let code = statusCode (responseStatus resp)
                  respBody = responseBody resp
                  resultCount = countResults respBody
              if code >= 200 && code <= 299
                then pure (OpResult [TrpText (bodyText respBody)] False (recorded' q "custom" resultCount))
                else pure (mkError q "custom" $
                  "WEB_SEARCH: HTTP " <> T.pack (show code) <> ": " <> bodyText respBody)

-- | Best-effort count of search results from the response JSON. Tries to
-- parse the body as a JSON array and returns its length; falls back to 0
-- when the body is not a JSON array (the count is metadata only and not
-- security-critical).
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
        , "limit" .= object
            [ "type" .= ("integer" :: Text)
            , "description" .= ("Maximum number of results to return (default: 10)." :: Text)
            ]
        ]
    , "required" .= (["query"] :: [Text])
    ]

queryField :: Value -> Maybe Text
queryField = parseMaybe (withObject "in" (.: "query"))

-- | Optional per-call limit override (overrides 'wscMaxResults').
limitField :: Value -> Maybe Int
limitField = parseMaybe (withObject "in" (.: "limit"))