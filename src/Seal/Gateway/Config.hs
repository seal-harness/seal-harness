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
  , tlsConfigError
  , tlsOriginError
  ) where

import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Toml ((.=))
import Toml qualified

-- | The gateway config section.
data GatewayConfig = GatewayConfig
  { gcPort           :: Int        -- ^ default 8080 (REST + static + the WS stream)
  , gcWsPort         :: Int        -- ^ DEPRECATED: the WS stream shares @gcPort@; kept only so old config files still parse
  , gcHost           :: Text       -- ^ default "127.0.0.1"
  , gcStaticDir      :: Maybe Text  -- ^ the frontend dist dir (Nothing = no static serving)
  , gcAllowedOrigins :: [Text]     -- ^ the WS Origin allowlist (default localhost:8080)
  , gcTlsCert        :: Maybe Text
    -- ^ PEM certificate chain. Set together with 'gcTlsKey' to serve HTTPS
    -- directly, with no reverse proxy in front.
  , gcTlsKey         :: Maybe Text
    -- ^ PEM private key.
  } deriving stock (Eq, Show)

-- | The compiled-in default. Loopback + port 8080 + the local origin.
defaultGatewayConfig :: GatewayConfig
defaultGatewayConfig = GatewayConfig
  { gcPort = 8080
  , gcWsPort = 8080
  , gcHost = "127.0.0.1"
  , gcStaticDir = Nothing
  , gcAllowedOrigins = ["http://localhost:8080"]
  , gcTlsCert = Nothing
  , gcTlsKey = Nothing
  }

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
  }

-- | Codec for the @allowed_origins@ array (a TOML array of strings).
originsCodec :: Toml.TomlCodec [Text]
originsCodec = Toml.dimap Just maybeToList (Toml.dioptional (Toml.arrayOf Toml._Text "allowed_origins"))
  where
    maybeToList Nothing   = []
    maybeToList (Just xs) = xs

-- | Is the gateway configured to terminate TLS itself?
--
-- Serving HTTPS in-process means no reverse proxy is needed, which matters for
-- passkeys: a WebAuthn ceremony requires a secure context, and a bare
-- @http://@ LAN address is not one.
tlsEnabled :: GatewayConfig -> Bool
tlsEnabled cfg = isJust (gcTlsCert cfg) && isJust (gcTlsKey cfg)

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
