{-# LANGUAGE OverloadedStrings #-}
-- | The @[gateway]@ config section: port, bind host, static dir, allowed
-- origins. The server binds loopback by default; a non-loopback host emits
-- a runtime warning (the full slash-command surface is reachable by
-- anything that can reach the address).
module Seal.Gateway.Config
  ( GatewayConfig (..)
  , PartialGatewayConfig (..)
  , defaultGatewayConfig
  , gatewayConfigCodec
  , withGatewayDefaults
  , tlsEnabled
  , effectiveTlsPaths
  , tlsConfigError
  , tlsOriginError
  , gatewayHostError
  , hostResolves
  , gatewayHostResolutionError
  ) where

import Control.Exception (IOException, try)
import Data.Char (isSpace)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Network.Socket
  ( AddrInfo (..), AddrInfoFlag (AI_PASSIVE), SocketType (Stream), defaultHints
  , getAddrInfo )
import Toml ((.=))
import Toml qualified

-- | The gateway config section.
data GatewayConfig = GatewayConfig
  { gcPort           :: Int        -- ^ default 8080 (REST + static + the WS stream)
  , gcWsPort         :: Int        -- ^ DEPRECATED: the WS stream shares @gcPort@; kept only so old config files still parse
  , gcHost           :: Text
    -- ^ default "localhost" — the one loopback name browsers treat as a
    -- passkey-capable secure context. Handed to Warp as the bind address.
  , gcStaticDir      :: Maybe Text  -- ^ the frontend dist dir (Nothing = no static serving)
  , gcAllowedOrigins :: [Text]     -- ^ the WS Origin allowlist (default localhost:8080)
  , gcTlsCert        :: Maybe Text
    -- ^ PEM certificate chain. Set together with 'gcTlsKey' to serve HTTPS
    -- directly, with no reverse proxy in front.
  , gcTlsKey         :: Maybe Text
    -- ^ PEM private key.
  , gcTls            :: Bool
    -- ^ Serve HTTPS. The PEM paths default to @keys\/tls\/@{cert,key}@.on.pem
    -- under @SEAL_HOME@, so this flag alone is the whole configuration.
  , gcTlsHosts       :: [Text]
    -- ^ Names to put in a generated certificate's subject alternative name.
    -- These come first, in order. Everything else is derived: the origin's
    -- host, the bind host (if it names a machine), the machine hostname, every
    -- local interface address, and loopback — see
    -- 'Seal.Security.TlsCert.sanHostsFor'.
  } deriving stock (Eq, Show)

-- | The compiled-in default. Loopback + port 8080 + the local origin.
defaultGatewayConfig :: GatewayConfig
defaultGatewayConfig = GatewayConfig
  { gcPort = 8080
  , gcWsPort = 8080
  , gcHost = "localhost"
  , gcStaticDir = Nothing
  , gcAllowedOrigins = ["http://localhost:8080"]
  , gcTlsCert = Nothing
  , gcTlsKey = Nothing
  , gcTls = False
  , gcTlsHosts = []
  }

-- ---------------------------------------------------------------------------
-- Host validation
-- ---------------------------------------------------------------------------
--
-- @[gateway] host@ is handed straight to Warp (see 'Seal.Gateway.Server.warpSettingsFor'),
-- so a value that cannot bind is now a boot refusal. Before the host was wired
-- to the listener, any string was survivable: it only fed the printed URL, the
-- derived origins, and the exposed-bind warning.

-- | A @[gateway] host@ value that could never be bound. Purely syntactic.
--
-- 'gatewayHostResolutionError' asks the resolver about the values that pass
-- this check, so the two refusals stay independently testable.
-- Every clause inspects @raw@, never a trimmed copy: the caller hands this
-- exact string to Warp ('Seal.Gateway.Server.warpSettingsFor'), so a value that
-- passes here has to be one the resolver will accept. Trimming first would let
-- @host = " localhost "@ through both gates and fail inside the bind, after the
-- banner, with a message that names neither the key nor the mistake.
gatewayHostError :: Text -> Maybe Text
gatewayHostError raw
  | T.null (T.strip raw) = Just (hostRefusal "it is empty or blank" emptyFix)
  | T.any isSpace raw    = Just (hostRefusal "it contains whitespace" spacedFix)
  | T.any (== '/') raw   = Just (hostRefusal "it looks like a URL or a path" bareFix)
  | T.any (`elem` bracketed) raw =
      Just (hostRefusal "it is bracketed"
             "write an IPv6 literal without brackets, e.g. \"::1\"")
  | otherwise = Nothing
  where
    bracketed = "[]" :: String
    emptyFix = "set a hostname (\"localhost\") or a wildcard (\"0.0.0.0\")"
    spacedFix = "remove the surrounding or embedded whitespace: \"localhost\""
    bareFix = "write the bare host or address, e.g. \"localhost\" or \"0.0.0.0\""

hostRefusal :: Text -> Text -> Text
hostRefusal why fix =
  "[gateway] host is not a bindable address: " <> why <> ".\n  " <> fix

-- | Does @host@ resolve to at least one address?
--
-- "Resolvable", not "local": Warp may legitimately bind any address this
-- machine has, and a tailnet or LAN address is a normal @[gateway] host@ value.
-- A name that resolves to an address the machine does not own still fails at
-- bind time with Warp's own error; this check exists to catch typos and
-- unusable spellings before anything starts listening.
hostResolves :: Text -> IO Bool
hostResolves raw = do
  let hints = defaultHints { addrFlags = [AI_PASSIVE], addrSocketType = Stream }
  resolved <-
    try (getAddrInfo (Just hints) (Just (T.unpack raw)) Nothing)
      :: IO (Either IOException [AddrInfo])
  pure (either (const False) (not . null) resolved)

-- | The resolver-backed half of the host check.
--
-- The resolver is a parameter so the refusal branch is testable without DNS;
-- @seal serve@ passes 'hostResolves'.
gatewayHostResolutionError :: (Text -> IO Bool) -> Text -> IO (Maybe Text)
gatewayHostResolutionError resolves raw = do
  ok <- resolves raw
  pure $ if ok
    then Nothing
    else Just
      ("[gateway] host = \"" <> raw <> "\" does not resolve to any address.\n"
        <> "  Fix or remove the line (the default is \"localhost\"), or set\n"
        <> "  host = \"0.0.0.0\" to bind every interface.")

-- | Bidirectional tomland codec for the @[gateway]@ section. Every field is
-- optional: a missing key decodes as 'Nothing', then 'withGatewayDefaults'
-- (called by 'Seal.Command.Serve.runServeMain') fills in the
-- 'defaultGatewayConfig' values. This lets a user set just @host@ or just
-- @port@ without specifying the rest.
gatewayConfigCodec :: Toml.TomlCodec PartialGatewayConfig
gatewayConfigCodec = PartialGatewayConfig
  <$> Toml.dimap (fmap fromIntegral) (fmap fromIntegral) (Toml.dioptional (Toml.integer "port")) .= pgcPort
  <*> Toml.dimap (fmap fromIntegral) (fmap fromIntegral) (Toml.dioptional (Toml.integer "ws_port")) .= pgcWsPort
  <*> Toml.dioptional (Toml.text "host") .= pgcHost
  <*> Toml.dioptional (Toml.text "static_dir") .= pgcStaticDir
  <*> originsCodec .= pgcAllowedOrigins
  <*> Toml.dioptional (Toml.text "tls_cert") .= pgcTlsCert
  <*> Toml.dioptional (Toml.text "tls_key") .= pgcTlsKey
  <*> Toml.dioptional (Toml.bool "tls") .= pgcTls
  <*> hostsCodec .= pgcTlsHosts

-- | A partial gateway config where every field is optional. 'withGatewayDefaults'
-- merges it with 'defaultGatewayConfig' to produce a complete 'GatewayConfig'.
data PartialGatewayConfig = PartialGatewayConfig
  { pgcPort           :: Maybe Int
  , pgcWsPort         :: Maybe Int
  , pgcHost           :: Maybe Text
  , pgcStaticDir      :: Maybe Text
  , pgcAllowedOrigins :: [Text]
  , pgcTlsCert        :: Maybe Text
  , pgcTlsKey         :: Maybe Text
  , pgcTls            :: Maybe Bool
  , pgcTlsHosts       :: [Text]
  } deriving stock (Eq, Show)

-- | Merge a partial gateway config with the compiled-in defaults, producing
-- a complete 'GatewayConfig'. Each 'Nothing' field falls back to
-- 'defaultGatewayConfig'; an empty 'pgcAllowedOrigins' also falls back (so
-- omitting @allowed_origins@ keeps the safe loopback default rather than
-- opening to all origins).
withGatewayDefaults :: PartialGatewayConfig -> GatewayConfig
withGatewayDefaults p = GatewayConfig
  { gcPort           = fromMaybe (gcPort defaultGatewayConfig) (pgcPort p)
  , gcWsPort         = fromMaybe (gcWsPort defaultGatewayConfig) (pgcWsPort p)
  , gcHost           = fromMaybe (gcHost defaultGatewayConfig) (pgcHost p)
  , gcStaticDir      = pgcStaticDir p  -- Nothing = no static serving (the default)
  , gcAllowedOrigins = if null (pgcAllowedOrigins p)
                         then gcAllowedOrigins defaultGatewayConfig
                         else pgcAllowedOrigins p
  , gcTlsCert        = pgcTlsCert p
  , gcTlsKey         = pgcTlsKey p
  , gcTls            = fromMaybe False (pgcTls p)
  , gcTlsHosts       = pgcTlsHosts p
  }

-- | Codec for the @allowed_origins@ array (a TOML array of strings).
originsCodec :: Toml.TomlCodec [Text]
originsCodec = Toml.dimap Just maybeToList (Toml.dioptional (Toml.arrayOf Toml._Text "allowed_origins"))
  where
    maybeToList Nothing   = []
    maybeToList (Just xs) = xs

-- | Codec for the @tls_hosts@ array (a TOML array of strings).
hostsCodec :: Toml.TomlCodec [Text]
hostsCodec = Toml.dimap Just maybeToList (Toml.dioptional (Toml.arrayOf Toml._Text "tls_hosts"))
  where
    maybeToList Nothing   = []
    maybeToList (Just xs) = xs

-- | Is the gateway configured to terminate TLS itself?
--
-- Serving HTTPS in-process means no reverse proxy is needed, which matters for
-- passkeys: a WebAuthn ceremony requires a secure context, and a bare
-- @http://@ LAN address is not one.
tlsEnabled :: GatewayConfig -> Bool
tlsEnabled cfg = gcTls cfg || (isJust (gcTlsCert cfg) && isJust (gcTlsKey cfg))

-- | The PEM paths to load, given the defaults for this @SEAL_HOME@.
--
-- 'gcTls' opts in; an explicit path overrides the default; and setting both
-- paths still turns TLS on by itself, which is the spelling the README used
-- before the flag existed.
effectiveTlsPaths :: FilePath -> FilePath -> GatewayConfig -> (FilePath, FilePath)
effectiveTlsPaths defaultCert defaultKey cfg =
  ( maybe defaultCert T.unpack (gcTlsCert cfg)
  , maybe defaultKey T.unpack (gcTlsKey cfg) )

-- | A TLS setting that cannot be served.
--
-- The two PEM paths are only meaningful together. A certificate without its
-- key (or the reverse) is a typo, and saying so at boot beats failing inside
-- the TLS handshake on the first connection.
tlsConfigError :: GatewayConfig -> Maybe Text
tlsConfigError cfg = case (gcTlsCert cfg, gcTlsKey cfg) of
  (Nothing, Nothing) -> Nothing
  (Just _, Just _)   -> Nothing
  (Just _, Nothing)  ->
    Just "[gateway] tls_cert is set but tls_key is not: both are required to serve HTTPS."
  (Nothing, Just _)  ->
    Just "[gateway] tls_key is set but tls_cert is not: both are required to serve HTTPS."

-- | Is the configured origin consistent with serving HTTPS?
--
-- Once TLS is on, browsers reach the gateway at @https:\/\/@, so a verified
-- origin that says @http:\/\/@ can never match: every registration and every
-- assertion would be refused as an origin mismatch. The derived loopback
-- origin (@http:\/\/localhost:\<port\>@) is exactly that case, so enabling TLS
-- on a loopback bind also requires an explicit @origin@.
tlsOriginError :: Bool -> Maybe Text -> Maybe Text
tlsOriginError tls mOrigin
  | not tls = Nothing
  | otherwise = case mOrigin of
      Nothing -> Nothing
      Just o
        | "https://" `T.isPrefixOf` o -> Nothing
        | otherwise ->
            Just ("[gateway] tls_cert/tls_key are set but [access_control] origin is \""
                   <> o <> "\".\n  Clients will reach this gateway over https, so set origin to "
                   <> "the https URL they use (rp_id follows from its host).")
