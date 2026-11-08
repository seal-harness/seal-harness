{-# LANGUAGE OverloadedStrings #-}
-- | The mutation guard's verdict: may this request mutate state?
--
-- The gateway's REST API is reachable from any page in the operator's browser.
-- Passkey sessions do not fix that on their own: a cookie is sent on a
-- cross-origin request, so a hostile page can drive @POST@/@PUT@/@DELETE@
-- against the gateway (CSRF). The passkey layer decides *network* identity; this
-- module decides whether the *request origin* is the gateway's own.
--
-- The canonical origin is resolved once at boot by 'Seal.Config.BootPlan' and is
-- the same value WebAuthn verifies @clientDataJSON.origin@ against. The
-- WebSocket allowlist is derived separately, from @[gateway] host@ + @port@, and
-- is exact: a browser opened at @http:\/\/127.0.0.1:<port>@ can use the REST API
-- here but not the live stream. Open the URL the boot banner prints.
--
-- Pure on purpose: the whole verdict (including the loopback-alias cases that
-- keep @vite dev@ and the e2e harness working) is testable without a socket.
module Seal.Gateway.OriginGuard
  ( GuardHeaders (..)
  , GuardVerdict (..)
  , sameOriginVerdict
  , guardHeadersFrom
  ) where

import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types (HeaderName, hOrigin)
import Network.Wai (Request, requestHeaders)

-- | The only two headers the verdict needs.
data GuardHeaders = GuardHeaders
  { ghOrigin       :: !(Maybe Text)
    -- ^ @Origin@. Absent for curl/HTTP clients and for same-origin GETs.
  , ghSecFetchSite :: !(Maybe Text)
    -- ^ @Sec-Fetch-Site@. Browsers send it on every request; @cross-site@ on a
    -- cross-origin one.
  } deriving stock (Eq, Show)

-- | The verdict. A rejection carries a short reason for the log and the 403
-- body (never request content beyond the fact that it did not match).
data GuardVerdict = Allowed | Rejected !Text
  deriving stock (Eq, Show)

-- | @Sec-Fetch-Site@ has no constant in @http-types@; header names are
-- case-insensitive and @HeaderName@ is @IsString@ over the lowercased form.
hSecFetchSite :: HeaderName
hSecFetchSite = "sec-fetch-site"

-- | Decide whether a request may mutate state.
--
-- @Nothing@ is the boot plan's explicit "no origin could be resolved" (a
-- wildcard bind with @mode = none@): the operator waived access control and
-- there is no canonical origin to compare against, so everything is allowed.
--
-- A loopback canonical origin accepts any loopback alias on any port. That is
-- load-bearing: the boot plan canonicalises a loopback bind to
-- @http:\/\/localhost:\<port\>@, while the SPA is reached at
-- @http:\/\/127.0.0.1:\<port\>@ (the e2e harness) or
-- @http:\/\/localhost:5173@ (the vite dev proxy). Only code already running on
-- the host can serve from a loopback name.
sameOriginVerdict :: Maybe Text -> GuardHeaders -> GuardVerdict
sameOriginVerdict Nothing _headers = Allowed
sameOriginVerdict (Just canonical) headers =
  case ghOrigin headers of
    Nothing -> allowWithoutOrigin
    Just raw
      | T.toLower (T.strip raw) == "null" ->
          Rejected "Origin: null is not an acceptable origin"
      | otherwise -> case (parseOrigin canonical, parseOrigin raw) of
          (Just canon, Just origin)
            | identicalOrigin canon origin -> Allowed
            | poScheme canon == poScheme origin
            , isLoopbackHost (poHost canon)
            , isLoopbackHost (poHost origin) -> Allowed
            | otherwise ->
                Rejected ("origin does not match the gateway origin (" <> raw <> ")")
          _ -> Rejected "Origin header is not a well-formed http(s) origin"
  where
    -- A browser cannot issue a cross-site request without telling us so. Absent
    -- metadata means a non-browser client (curl, the chat channels, tests).
    allowWithoutOrigin = case ghSecFetchSite headers of
      Just site
        | T.toLower (T.strip site) `elem` ["cross-site", "same-site"] ->
            Rejected "cross-site fetch metadata without Origin"
      _ -> Allowed

-- | Extract the two headers from a WAI request. Lenient UTF-8 decoding matches
-- the rest of the gateway: a malformed header simply fails to match.
guardHeadersFrom :: Request -> GuardHeaders
guardHeadersFrom req = GuardHeaders
  { ghOrigin       = lookupText hOrigin
  , ghSecFetchSite = lookupText hSecFetchSite
  }
  where
    lookupText :: HeaderName -> Maybe Text
    lookupText name = TE.decodeUtf8Lenient <$> lookup name (requestHeaders req)

-- ---------------------------------------------------------------------------
-- Origin parsing
-- ---------------------------------------------------------------------------

-- | A parsed origin: scheme, host (lowercased, brackets kept for IPv6) and the
-- effective port (explicit, else the scheme default). Nothing else is carried —
-- an origin with a path, query or fragment is not an origin.
data ParsedOrigin = ParsedOrigin
  { poScheme :: !Text
  , poHost   :: !Text
  , poPort   :: !Int
  } deriving stock (Eq, Show)

parseOrigin :: Text -> Maybe ParsedOrigin
parseOrigin raw = do
  let stripped = T.strip raw
      -- Browsers never send a trailing slash, but some tools do; tolerate one.
      cleaned = if "/" `T.isSuffixOf` stripped then T.dropEnd 1 stripped else stripped
  (scheme, afterScheme) <- splitScheme cleaned
  host <- splitHost afterScheme
  port <- splitPort scheme afterScheme
  pure (ParsedOrigin (T.toLower scheme) host port)

splitScheme :: Text -> Maybe (Text, Text)
splitScheme t =
  case T.breakOn "://" t of
    (scheme, rest)
      | T.null rest                -> Nothing
      | T.null scheme             -> Nothing
      | T.toLower scheme `notElem` ["http", "https"] -> Nothing
      | otherwise                 -> Just (scheme, T.drop 3 rest)

-- | The host part of an authority, with a validation that nothing hostile
-- follows it. A path/query/fragment anywhere in the authority is rejected.
splitHost :: Text -> Maybe Text
splitHost authority
  | T.null authority = Nothing
  | T.any (`elem` ("/?#" :: String)) authority = Nothing
  | "[" `T.isPrefixOf` authority =
      case T.breakOn "]" authority of
        (h, rest)
          | T.null rest -> Nothing
          | otherwise   ->
              let after = T.drop 1 rest
              in if T.null after || validPortSuffix after
                   then Just (T.toLower h <> "]")
                   else Nothing
  | otherwise =
      case T.breakOn ":" authority of
        (h, rest)
          | T.null h -> Nothing
          | T.null rest -> Just (T.toLower h)
          | validPortSuffix rest -> Just (T.toLower h)
          | otherwise -> Nothing

splitPort :: Text -> Text -> Maybe Int
splitPort scheme authority
  | "[" `T.isPrefixOf` authority =
      case T.breakOn "]" authority of
        (_, rest) -> portFrom (T.drop 1 rest) (defaultPort scheme)
  | otherwise =
      case T.breakOn ":" authority of
        (_, rest) -> portFrom rest (defaultPort scheme)

portFrom :: Text -> Int -> Maybe Int
portFrom rest fallback
  | T.null rest = Just fallback
  | validPortSuffix rest =
      case reads (T.unpack (T.drop 1 rest)) of
        [(n, "")] -> Just n
        _         -> Nothing
  | otherwise = Nothing

validPortSuffix :: Text -> Bool
validPortSuffix t =
  case T.uncons t of
    Just (':', digits) -> not (T.null digits) && T.all isDigit digits && T.length digits <= 5
    _                  -> False

defaultPort :: Text -> Int
defaultPort scheme = if T.toLower scheme == "https" then 443 else 80

identicalOrigin :: ParsedOrigin -> ParsedOrigin -> Bool
identicalOrigin a b =
  poScheme a == poScheme b && poHost a == poHost b && poPort a == poPort b

-- | @localhost@, any @127.0.0.0\/8@ address, and IPv6 @::1@ (with or without
-- brackets). Everything else — including @localhost.evil.com@ and @10.x@ — is
-- not loopback.
isLoopbackHost :: Text -> Bool
isLoopbackHost host
  | h == "localhost" = True
  | h == "[::1]" || h == "::1" = True
  | otherwise = case T.splitOn "." h of
      [a, b, c, d] -> a == "127" && all numeric [b, c, d]
      _            -> False
  where
    h = T.toLower host
    numeric part = not (T.null part) && T.all isDigit part
