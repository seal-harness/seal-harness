{-# LANGUAGE OverloadedStrings #-}
-- | URL safety checks — blocks requests to private/internal network
-- addresses (SSRF defense). Mirrors the Hermes @tools/url_safety.py@
-- @is_safe_url@ check: resolve the hostname to an IP, reject if it's
-- private, loopback, link-local, reserved, multicast, unspecified, or in
-- the CGNAT range (@100.64.0.0/10@). Cloud-metadata endpoints
-- (@169.254.169.254@, @metadata.google.internal@, etc.) are /always/
-- blocked regardless of any toggle. Fails closed: DNS errors and parse
-- errors block the request.
module Seal.Web.UrlSafety
  ( isSafeUrl
  , isAlwaysBlockedUrl
  , UrlSafetyError (..)
  , renderUrlSafetyError
  ) where

import Control.Exception (IOException, try)
import Data.Bits ((.&.), shiftR)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32)
import Network.Socket
  ( AddrInfo (..), Family (..), HostAddress6, SockAddr (..)
  , SocketType (..), getAddrInfo, defaultHints, hostAddressToTuple )
import Text.Read (readMaybe)

-- | The reason a URL was blocked (for logging / error messages).
data UrlSafetyError
  = UseInvalidScheme Text
  | UseNoHost
  | UseBlockedHost Text
  | UseBlockedIp Text
  | UseDnsFailed Text
  | UseParseError Text
  deriving stock (Eq, Show)

-- | Render a 'UrlSafetyError' as a human-readable 'Text'.
renderUrlSafetyError :: UrlSafetyError -> Text
renderUrlSafetyError = \case
  UseInvalidScheme s -> "invalid scheme '" <> s <> "' (only http/https allowed)"
  UseNoHost          -> "no host in URL"
  UseBlockedHost h   -> "blocked hostname: " <> h
  UseBlockedIp h     -> "blocked IP (private/internal/metadata): " <> h
  UseDnsFailed h     -> "DNS resolution failed for: " <> h
  UseParseError msg  -> "URL parse error: " <> msg

-- | The cloud-metadata hostnames that are /always/ blocked regardless of
-- any toggle. An attacker could use these to steal instance credentials.
blockedHostnames :: [Text]
blockedHostnames =
  [ "metadata.google.internal"
  , "metadata.goog"
  ]

-- | The cloud-metadata IPs that are /always/ blocked. These are the #1
-- SSRF target — AWS/GCP/Azure/DO/Oracle metadata, AWS ECS task metadata,
-- Azure IMDS wire server, AWS metadata (IPv6), Alibaba Cloud metadata.
alwaysBlockedIps :: [Text]
alwaysBlockedIps =
  [ "169.254.169.254"   -- AWS/GCP/Azure/DO/Oracle metadata
  , "169.254.170.2"     -- AWS ECS task metadata
  , "169.254.169.253"   -- Azure IMDS wire server
  , "fd00:ec2::254"     -- AWS metadata (IPv6)
  , "100.100.100.200"   -- Alibaba Cloud metadata
  ]

-- | Check whether a URL is safe to fetch: the scheme is http/https, the
-- host is not a cloud-metadata endpoint, and the resolved IP is not
-- private/loopback/link-local/reserved/multicast/unspecified or in the
-- CGNAT range. Performs DNS resolution (IO) to check the IP. Fails closed
-- (returns 'Left' on any error — the caller blocks the request).
isSafeUrl :: Text -> IO (Either UrlSafetyError ())
isSafeUrl url =
  case preCheck url of
    Left err   -> pure (Left err)
    Right host -> isSafeHost host

-- | Pure pre-check: scheme + host extraction + always-blocked hostname/IP
-- literal checks. Returns the host to DNS-resolve, or an error.
preCheck :: Text -> Either UrlSafetyError Text
preCheck url = do
  let (scheme, afterScheme) = breakScheme url
  if scheme /= "http" && scheme /= "https"
    then Left (UseInvalidScheme scheme)
    else case extractHost afterScheme of
      Nothing -> Left UseNoHost
      Just host
        | host `elem` blockedHostnames -> Left (UseBlockedHost host)
        | isAlwaysBlockedIpLiteral host -> Left (UseBlockedIp host)
        | isIpv4Literal host ->
            if isIpv4Private host then Left (UseBlockedIp host) else Right host
        | isIpv6Literal host ->
            if isIpv6Private host then Left (UseBlockedIp host) else Right host
        | otherwise -> Right host

-- | Check only the always-blocked floor (cloud-metadata endpoints). This
-- is narrower than 'isSafeUrl' — it doesn't block ordinary private
-- addresses or do DNS. Pure.
isAlwaysBlockedUrl :: Text -> Bool
isAlwaysBlockedUrl url =
  case extractHost (snd (breakScheme url)) of
    Nothing -> False
    Just host ->
      host `elem` blockedHostnames
      || any (`T.isPrefixOf` host) alwaysBlockedIps

-- | Resolve the hostname via DNS and check each resolved IP. Fails closed
-- on DNS errors.
isSafeHost :: Text -> IO (Either UrlSafetyError ())
isSafeHost host = do
  let hints = defaultHints { addrFamily = AF_UNSPEC, addrSocketType = Stream }
  eResult <- try (getAddrInfo (Just hints) (Just (T.unpack host)) Nothing)
                :: IO (Either IOException [AddrInfo])
  pure $ case eResult of
    Left _ioErr -> Left (UseDnsFailed host)
    Right addrInfos -> checkAddrs host addrInfos

-- | Check each resolved address. IPv4 addresses are checked via
-- 'isIpv4Private'; IPv6 via 'isIpv6Private'.
checkAddrs :: Text -> [AddrInfo] -> Either UrlSafetyError ()
checkAddrs _ [] = Right ()
checkAddrs host (ai : rest) =
  case addrAddress ai of
    SockAddrInet _ ha ->
      let ipText = word32ToIp ha
      in if ipText `elem` alwaysBlockedIps || isIpv4Private ipText
           then Left (UseBlockedIp host)
           else checkAddrs host rest
    SockAddrInet6 _ _ ha6 _ ->
      let ipText = host6ToIp ha6
      in if ipText `elem` alwaysBlockedIps || isIpv6Private ipText
           then Left (UseBlockedIp host)
           else checkAddrs host rest
    _ -> checkAddrs host rest

-- | Convert a 'Word32' (host-order) to a dotted-quad 'Text'.
word32ToIp :: Word32 -> Text
word32ToIp w =
  let (a, b, c, d) = hostAddressToTuple w
  in T.pack (show a <> "." <> show b <> "." <> show c <> "." <> show d)

-- | Convert an IPv6 'HostAddress6' (4-tuple of Word32) to a colon-separated
-- 'Text'. Uses the standard @x:x:x:x:x:x:x:x@ form (no zero compression).
host6ToIp :: HostAddress6 -> Text
host6ToIp (w1, w2, w3, w4) =
  T.intercalate ":" (concatMap toGroups [w1, w2, w3, w4])
  where
    toGroups w = [ word32ToHex16 (fromIntegral (w `shiftR` 16) :: Int)
                 , word32ToHex16 (fromIntegral (w .&. 0xFFFF) :: Int) ]

-- | Format a 16-bit integer as 1-4 lowercase hex digits (no leading zeros).
word32ToHex16 :: Int -> Text
word32ToHex16 n = T.pack (showHex n "")
  where
    showHex 0 s = s
    showHex x s = showHex (x `div` 16) (hexDigit (x `mod` 16) : s)
    hexDigit d | d < 10 = toEnum (fromEnum '0' + d)
               | otherwise = toEnum (fromEnum 'a' + d - 10)

-- | Check if a text is a literal IPv4 address (d.d.d.d).
isIpv4Literal :: Text -> Bool
isIpv4Literal t =
  case T.splitOn "." t of
    [a, b, c, d] ->
      all (\part -> case readMaybe (T.unpack part) :: Maybe Int of
                      Just n -> n >= 0 && n <= 255
                      Nothing -> False)
          [a, b, c, d]
    _ -> False

-- | Check if a text is a literal IPv6 address (contains @:@).
isIpv6Literal :: Text -> Bool
isIpv6Literal t = T.any (== ':') t && T.any (/= ':') t

-- | Check if a literal IP is in the always-blocked set (cloud metadata).
isAlwaysBlockedIpLiteral :: Text -> Bool
isAlwaysBlockedIpLiteral ipText = ipText `elem` alwaysBlockedIps

-- | IPv4 private ranges: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
-- 127.0.0.0/8, 169.254.0.0/16, 0.0.0.0/8, 224.0.0.0/4, 240.0.0.0/4,
-- 100.64.0.0/10 (CGNAT).
isIpv4Private :: Text -> Bool
isIpv4Private ipText =
  case T.splitOn "." ipText of
    [a, b, _, _] ->
      case (readMaybe (T.unpack a) :: Maybe Int, readMaybe (T.unpack b) :: Maybe Int) of
        (Just a', Just b') ->
          a' == 10                           -- 10.0.0.0/8
          || (a' == 172 && b' >= 16 && b' <= 31)  -- 172.16.0.0/12
          || (a' == 192 && b' == 168)         -- 192.168.0.0/16
          || a' == 127                         -- 127.0.0.0/8 (loopback)
          || (a' == 169 && b' == 254)          -- 169.254.0.0/16 (link-local)
          || a' == 0                           -- 0.0.0.0/8 (unspecified)
          || (a' >= 224 && a' <= 239)          -- 224.0.0.0/4 (multicast)
          || a' >= 240                          -- 240.0.0.0/4 (reserved)
          || (a' == 100 && b' >= 64 && b' <= 127)  -- 100.64.0.0/10 (CGNAT)
        _ -> False
    _ -> False

-- | IPv6 private/loopback/link-local ranges: ::1 (loopback), fe80::/10
-- (link-local), fc00::/7 (unique local), ff00::/8 (multicast), :: (unspec).
isIpv6Private :: Text -> Bool
isIpv6Private ipText =
  ipText == "::1"                               -- loopback
  || ipText == "::"                              -- unspecified
  || T.isPrefixOf "fe80:" ipText                 -- link-local fe80::/10
  || T.isPrefixOf "fe9" ipText                   -- link-local fe9x:
  || T.isPrefixOf "fea" ipText                   -- link-local feax:
  || T.isPrefixOf "feb" ipText                   -- link-local febx:
  || T.isPrefixOf "fc" ipText                    -- unique local fc00::/7
  || T.isPrefixOf "fd" ipText                    -- unique local fd00::/7
  || T.isPrefixOf "ff" ipText                    -- multicast ff00::/8

-- ---------------------------------------------------------------------------
-- URL parsing helpers
-- ---------------------------------------------------------------------------

-- | Break a URL into (scheme, rest). The scheme is lowercased.
breakScheme :: Text -> (Text, Text)
breakScheme url =
  case T.breakOn "://" url of
    (_, rest) | T.null rest -> ("", url)
    (sch, _) -> (T.toLower sch, T.drop 3 (snd (T.breakOn "://" url)))

-- | Extract the host from the post-scheme part of a URL. Handles
-- @host/path@, @host:port/path@, @host?query@, @host#fragment@.
extractHost :: Text -> Maybe Text
extractHost afterScheme =
  let authority = T.takeWhile (\c -> c /= '/' && c /= '?' && c /= '#') afterScheme
      host = T.takeWhile (/= ':') authority  -- strip port
  in if T.null host then Nothing else Just (T.toLower host)