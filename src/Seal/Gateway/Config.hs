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
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Toml ((.=))
import Toml qualified

-- | The gateway config section.
data GatewayConfig = GatewayConfig
  { gcPort           :: Int        -- ^ default 8080 (REST + static)
  , gcWsPort         :: Int        -- ^ default 8081 (WS stream)
  , gcHost           :: Text       -- ^ default "127.0.0.1"
  , gcStaticDir      :: Maybe Text  -- ^ the frontend dist dir (Nothing = no static serving)
  , gcAllowedOrigins :: [Text]     -- ^ the WS Origin allowlist (default localhost:8080)
  } deriving stock (Eq, Show)

-- | The compiled-in default. Loopback + port 8080 + the local origin.
defaultGatewayConfig :: GatewayConfig
defaultGatewayConfig = GatewayConfig
  { gcPort = 8080
  , gcWsPort = 8081
  , gcHost = "127.0.0.1"
  , gcStaticDir = Nothing
  , gcAllowedOrigins = ["http://localhost:8080"]
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

-- | A partial gateway config where every field is optional. 'withGatewayDefaults'
-- merges it with 'defaultGatewayConfig' to produce a complete 'GatewayConfig'.
data PartialGatewayConfig = PartialGatewayConfig
  { pgcPort           :: Maybe Int
  , pgcWsPort         :: Maybe Int
  , pgcHost           :: Maybe Text
  , pgcStaticDir      :: Maybe Text
  , pgcAllowedOrigins :: [Text]
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
  }

-- | Codec for the @allowed_origins@ array (a TOML array of strings).
originsCodec :: Toml.TomlCodec [Text]
originsCodec = Toml.dimap Just maybeToList (Toml.dioptional (Toml.arrayOf Toml._Text "allowed_origins"))
  where
    maybeToList Nothing   = []
    maybeToList (Just xs) = xs