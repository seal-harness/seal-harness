{-# LANGUAGE OverloadedStrings #-}
-- | Provider favicon resolution: fetch the root page of an OpenAI-compatible
-- provider's base URL, find the first @<link rel="icon">@ (or
-- @apple-touch-icon@) tag, resolve the @href@ to an absolute URL, and fetch
-- the icon image bytes.
--
-- This is a backend proxy: the frontend's @<img src="/api/providers/:name/icon">@
-- hits this module through the REST API, which fetches the provider's website
-- server-side. This avoids CORS (the browser cannot read cross-origin HTML)
-- and network-reachability issues (the backend can reach private endpoints).
--
-- Results are cached in-memory per root URL with a TTL so repeated renders
-- do not refetch.
module Seal.Gateway.ProviderIcon
  ( resolveProviderIconBytes
  , IconResult (..)
  , IconCache
  , newIconCache
  , cachedIcon
  , storeIcon
  , deriveRootUrl
  , extractIconHref
  , resolveIconUrl
  ) where

import Control.Exception (try, SomeException)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import Network.HTTP.Client
  ( Manager, Response, httpLbs, parseRequest
  , responseBody, responseHeaders, responseStatus, responseTimeout, responseTimeoutMicro )
import Network.HTTP.Types (statusCode, hContentType)

-- | The result of resolving a provider icon.
data IconResult
  = IconFound ByteString Text
    -- ^ The icon image bytes and its content-type (e.g. "image/png").
  | IconNotFound
    -- ^ No icon link found on the root page, or the page could not be fetched.
  deriving stock (Show, Eq)

-- | An in-memory cache of resolved icons, keyed by root URL.
newtype IconCache = IconCache
  { icEntries :: IORef (Map.Map Text (IconResult, UTCTime))
  }

-- | Create a new empty icon cache.
newIconCache :: IO IconCache
newIconCache = IconCache <$> newIORef Map.empty

-- | Cache TTL in seconds. A provider's favicon changes rarely; 10 minutes
-- keeps the badge responsive to operator config changes without refetching
-- on every page load.
iconCacheTtlSeconds :: NominalDiffTime
iconCacheTtlSeconds = 600

-- | Look up a cached icon entry. Returns 'Nothing' when the cache has no
-- entry or the entry has expired.
cachedIcon :: IconCache -> Text -> IO (Maybe IconResult)
cachedIcon cache rootUrl = do
  entries <- readIORef (icEntries cache)
  case Map.lookup rootUrl entries of
    Nothing -> pure Nothing
    Just (result, cachedAt) -> do
      now <- getCurrentTime
      if diffUTCTime now cachedAt > iconCacheTtlSeconds
        then pure Nothing
        else pure (Just result)

-- | Store an icon result in the cache.
storeIcon :: IconCache -> Text -> IconResult -> IO ()
storeIcon cache rootUrl result = do
  now <- getCurrentTime
  modifyIORef' (icEntries cache) (Map.insert rootUrl (result, now))

-- | Resolve a provider's favicon: fetch the root page, extract the icon
-- @<link>@ href, resolve it to an absolute URL, fetch the image bytes, and
-- return them with the content-type. Uses the cache to avoid refetching.
resolveProviderIconBytes :: IconCache -> Manager -> Text -> IO IconResult
resolveProviderIconBytes cache mgr baseUrl = do
  let rootUrl = deriveRootUrl baseUrl
  case rootUrl of
    Nothing -> pure IconNotFound
    Just root -> do
      mCached <- cachedIcon cache root
      case mCached of
        Just result -> pure result
        Nothing -> do
          result <- fetchProviderIcon mgr root
          storeIcon cache root result
          pure result

-- | Derive the root page URL (origin only) from a provider base URL.
-- Strips @/v1@ and any trailing path. Returns 'Nothing' when the input is
-- empty or not a parseable URL.
--
--   "https://api.openai.com/v1"      → "https://api.openai.com"
--   "http://localhost:8000/v1/"      → "http://localhost:8000"
--   "https://api.example.com/api/v2" → "https://api.example.com"
deriveRootUrl :: Text -> Maybe Text
deriveRootUrl baseUrl = do
  let trimmed = T.strip baseUrl
  if T.null trimmed then Nothing
  else case T.breakOn "://" trimmed of
    (scheme, rest) | not (T.null rest) ->
      let hostPart = T.takeWhile (\c -> c /= '/' && c /= '?') (T.drop 3 rest)
      in if T.null hostPart then Nothing
         else Just (scheme <> "://" <> hostPart)
    _ -> Nothing

-- | Extract the first icon @<link>@ tag's @href@ value from an HTML string.
-- Searches for @rel="icon"@, @rel="shortcut icon"@, and
-- @rel="apple-touch-icon"@ (case-insensitive), in that preference order.
-- Returns 'Nothing' when no icon link is found.
extractIconHref :: ByteString -> Maybe Text
extractIconHref html =
  case findMatchingLinks "icon" of
    Just href -> Just href
    Nothing -> case findMatchingLinks "shortcut icon" of
      Just href -> Just href
      Nothing -> findMatchingLinks "apple-touch-icon"
  where
    -- The full HTML as lowercase Text for case-insensitive scanning.
    htmlText = TE.decodeUtf8With TEE.lenientDecode html
    htmlLower = T.toLower htmlText
    -- Find all <link ...> tags whose rel attribute matches the pattern,
    -- and return the href of the first one.
    findMatchingLinks :: Text -> Maybe Text
    findMatchingLinks relPattern = findLinkTagWithRel htmlText htmlLower relPattern 0

-- | Scan the HTML text for @<link>@ tags, checking each one's @rel@
-- attribute (case-insensitive via the lowercase copy) against the pattern.
-- Returns the @href@ value of the first match.
findLinkTagWithRel :: Text -> Text -> Text -> Int -> Maybe Text
findLinkTagWithRel orig lower relPattern start =
  case T.breakOn "<link" (T.drop start lower) of
    (_, "") -> Nothing  -- no more <link tags
    (pre, tagStart) ->
      let afterLink = T.drop 5 tagStart  -- skip "<link"
      in case T.breakOn ">" afterLink of
        (tagContent, _) ->
          let tagLower = tagContent
              tagOrig = T.take (T.length tagContent) (T.drop (T.length pre + 5) orig)
          in if containsRel relPattern tagLower
               then extractHrefValue tagOrig
               else findLinkTagWithRel orig lower relPattern (T.length pre + 5 + T.length tagContent + 1)

-- | Check whether a tag's content contains @rel="...icon..."@ (already
-- lowercased). We check for @rel@ followed by @=@ and the pattern.
containsRel :: Text -> Text -> Bool
containsRel relPattern tagContent =
  case T.breakOn "rel" tagContent of
    (_, "") -> False
    (_, afterRel) ->
      let afterRelWord = T.dropWhile (\c -> c == ' ' || c == '\t' || c == '\n') (T.drop 3 afterRel)
      in case T.uncons afterRelWord of
           Just ('=', afterEq) ->
             let afterEq' = T.dropWhile (\c -> c == ' ' || c == '\t' || c == '\n') afterEq
             in case T.uncons afterEq' of
                  Just ('"', afterQuote) ->
                    relPattern `T.isPrefixOf` T.toLower (T.takeWhile (/= '"') afterQuote)
                  Just ('\'', afterQuote) ->
                    relPattern `T.isPrefixOf` T.toLower (T.takeWhile (/= '\'') afterQuote)
                  _ -> relPattern `T.isPrefixOf` T.dropWhile (\c -> c == ' ' || c == '\t') afterEq'
           _ -> False

-- | Extract the @href@ value from a tag's attribute string.
-- Looks for @href="..."@ or @href='...'@.
extractHrefValue :: Text -> Maybe Text
extractHrefValue tag =
  case T.breakOn "href" (T.toLower tag) of
    (_, "") -> Nothing
    (_, afterHref) ->
      let afterHrefWord = T.dropWhile (\c -> c == ' ' || c == '\t' || c == '\n') (T.drop 4 afterHref)
      in case T.uncons afterHrefWord of
           Just ('=', afterEq) ->
             let afterEq' = T.dropWhile (\c -> c == ' ' || c == '\t' || c == '\n') afterEq
             in case T.uncons afterEq' of
                  Just ('"', afterQuote) -> Just (T.takeWhile (/= '"') afterQuote)
                  Just ('\'', afterQuote) -> Just (T.takeWhile (/= '\'') afterQuote)
                  _ -> Just (T.takeWhile (\c -> c /= ' ' && c /= '>' && c /= '\t' && c /= '\n') afterEq')
           _ -> Nothing

-- | Resolve an icon @href@ (which may be absolute, protocol-relative, or
-- root-relative) to an absolute URL using the provider's root URL as the
-- base. Returns 'Nothing' when the href is empty.
resolveIconUrl :: Text -> Text -> Maybe Text
resolveIconUrl rootUrl href = do
  let h = T.strip href
  if T.null h then Nothing
  else if "//" `T.isPrefixOf` h then
    case T.breakOn "://" rootUrl of
      (scheme, _) | not (T.null scheme) -> Just (scheme <> ":" <> h)
      _ -> Nothing
  else if "://" `T.isInfixOf` h then Just h
  else if "/" `T.isPrefixOf` h then Just (rootUrl <> h)
  else Just (rootUrl <> "/" <> h)

-- | Fetch the provider's root page, extract the icon, fetch the image bytes.
fetchProviderIcon :: Manager -> Text -> IO IconResult
fetchProviderIcon mgr rootUrl = do
  eHtml <- tryFetch mgr rootUrl
  case eHtml of
    Left _ -> pure IconNotFound
    Right resp ->
      let code = statusCode (responseStatus resp)
      in if code < 200 || code > 299
           then pure IconNotFound
           else case extractIconHref (BL.toStrict (responseBody resp)) of
             Nothing -> pure IconNotFound
             Just href -> case resolveIconUrl rootUrl href of
               Nothing -> pure IconNotFound
               Just iconUrl -> do
                 eIcon <- tryFetch mgr iconUrl
                 case eIcon of
                   Left _ -> pure IconNotFound
                   Right iconResp ->
                     let icCode = statusCode (responseStatus iconResp)
                     in if icCode < 200 || icCode > 299
                          then pure IconNotFound
                          else
                            let ct = contentTypeFromResponse iconResp
                            in pure (IconFound (BL.toStrict (responseBody iconResp)) ct)

-- | Fetch a URL and return the response, or Left on any error.
tryFetch :: Manager -> Text -> IO (Either SomeException (Response BL.ByteString))
tryFetch mgr url = try (do
  req <- parseRequest (T.unpack url)
  let req' = req { responseTimeout = responseTimeoutMicro 5000000 }
  httpLbs req' mgr)

-- | Extract the Content-Type header value from a response, defaulting to
-- "image/png" when absent (most favicons are PNG or ICO).
contentTypeFromResponse :: Response BL.ByteString -> Text
contentTypeFromResponse resp =
  case lookup hContentType (responseHeaders resp) of
    Just ct -> TE.decodeUtf8With TEE.lenientDecode ct
    Nothing -> "image/png"
