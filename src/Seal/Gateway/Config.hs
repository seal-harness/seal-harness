{-# LANGUAGE OverloadedStrings #-}
-- | The @[gateway]@ config section: port, bind host, static dir, allowed
-- origins. The server binds loopback by default; a non-loopback host emits
-- a runtime warning (the full slash-command surface is reachable by
-- anything that can reach the address).
module Seal.Gateway.Config
  ( GatewayConfig (..)
  , defaultGatewayConfig
  , gatewayConfigCodec
  ) where

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

-- | Bidirectional tomland codec for the @[gateway]@ section.
gatewayConfigCodec :: Toml.TomlCodec GatewayConfig
gatewayConfigCodec = GatewayConfig
  <$> Toml.int  "port"            .= gcPort
  <*> Toml.int  "ws_port"         .= gcWsPort
  <*> Toml.text "host"            .= gcHost
  <*> Toml.dioptional (Toml.text "static_dir") .= gcStaticDir
  <*> originsCodec                 .= gcAllowedOrigins

-- | Codec for the @allowed_origins@ array (a TOML array of strings).
originsCodec :: Toml.TomlCodec [Text]
originsCodec = Toml.dimap Just maybeToList (Toml.dioptional (Toml.arrayOf Toml._Text "allowed_origins"))
  where
    maybeToList Nothing   = []
    maybeToList (Just xs) = xs