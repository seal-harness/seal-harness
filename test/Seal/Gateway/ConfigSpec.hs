{-# LANGUAGE OverloadedStrings #-}
module Seal.Gateway.ConfigSpec (spec) where

import Control.Monad (unless)
import Data.Text qualified as T
import Data.Maybe (isJust)
import Data.Text.IO qualified as TIO
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Toml qualified

import Validation (Validation (..))

import Seal.Gateway.Config

spec :: Spec
spec = describe "Seal.Gateway.Config" $ do
  describe "defaultGatewayConfig" $ do
    it "has port 8080, host localhost" $ do
      gcPort defaultGatewayConfig `shouldBe` 8080
      -- The WS stream shares the HTTP port (single-port gateway), so the
      -- deprecated ws_port defaults to the same value.
      gcWsPort defaultGatewayConfig `shouldBe` 8080
      gcHost defaultGatewayConfig `shouldBe` "localhost"
      gcStaticDir defaultGatewayConfig `shouldBe` Nothing
      gcAllowedOrigins defaultGatewayConfig `shouldBe` ["http://localhost:8080"]

  -- `host` is handed straight to Warp (see Server.warpSettingsFor), so a value
  -- that can never bind is now a boot refusal rather than a cosmetic string.
  describe "gatewayHostError" $ do
    it "refuses an empty or blank host" $ do
      gatewayHostError "" `shouldSatisfy` isJust
      gatewayHostError "   " `shouldSatisfy` isJust

    it "refuses a pasted URL, a path, or a bracketed IPv6 literal" $ do
      map gatewayHostError ["http://localhost", "localhost/seal", "[::1]"]
        `shouldSatisfy` all isJust

    -- The validator must inspect the exact string Warp receives. A value that
    -- is accepted here but padded fails inside the bind, after the banner.
    it "refuses surrounding whitespace instead of trimming it away" $ do
      map gatewayHostError [" localhost", "localhost ", "localhost\t"]
        `shouldSatisfy` all isJust

    it "resolution-checks the same string Warp binds" $ do
      e <- gatewayHostResolutionError (\h -> pure (h == "localhost")) "localhost "
      e `shouldSatisfy` maybe False (T.isInfixOf "[gateway] host")

    it "accepts names, IPv4 literals, and bare IPv6 literals" $
      map gatewayHostError ["localhost", "0.0.0.0", "::1", "seal.lan", "192.168.1.42"]
        `shouldBe` replicate 5 Nothing

    it "names the key it wants changed" $
      gatewayHostError "" `shouldSatisfy` maybe False (T.isInfixOf "[gateway] host")

  describe "gatewayHostResolutionError" $ do
    it "refuses a host that does not resolve, naming the key" $ do
      e <- gatewayHostResolutionError (const (pure False)) "seal.invalid"
      e `shouldSatisfy` maybe False (T.isInfixOf "[gateway] host")

    it "accepts a host that resolves" $
      gatewayHostResolutionError (const (pure True)) "seal.lan" `shouldReturn` Nothing

  describe "hostResolves" $ do
    it "resolves numeric literals without consulting DNS" $
      mapM hostResolves ["127.0.0.1", "0.0.0.0", "::1"] `shouldReturn` [True, True, True]

    it "resolves localhost" $ do
      ok <- hostResolves "localhost"
      unless ok (pendingWith "localhost does not resolve in this environment")
      ok `shouldBe` True

  describe "withGatewayDefaults" $ do
    it "fills in defaults for missing fields" $ do
      let partial = PartialGatewayConfig { pgcPort = Just 9090, pgcWsPort = Nothing, pgcHost = Just "0.0.0.0", pgcStaticDir = Nothing, pgcAllowedOrigins = [], pgcTlsCert = Nothing, pgcTlsKey = Nothing, pgcTls = Nothing, pgcTlsHosts = [] }
          full = withGatewayDefaults partial
      gcPort full `shouldBe` 9090
      gcWsPort full `shouldBe` 8080   -- default (same as the HTTP port)
      gcHost full `shouldBe` "0.0.0.0"
      gcStaticDir full `shouldBe` Nothing
      gcAllowedOrigins full `shouldBe` ["http://localhost:8080"]  -- default (empty → safe default)

    it "preserves all set fields" $ do
      let partial = PartialGatewayConfig { pgcPort = Just 9090, pgcWsPort = Just 9091, pgcHost = Just "0.0.0.0", pgcStaticDir = Just "/srv/seal", pgcAllowedOrigins = ["http://example.com"], pgcTlsCert = Nothing, pgcTlsKey = Nothing, pgcTls = Nothing, pgcTlsHosts = [] }
          full = withGatewayDefaults partial
      gcPort full `shouldBe` 9090
      gcWsPort full `shouldBe` 9091
      gcHost full `shouldBe` "0.0.0.0"
      gcStaticDir full `shouldBe` Just "/srv/seal"
      gcAllowedOrigins full `shouldBe` ["http://example.com"]

  -- The table lives in security.toml; the codec and the read-only legacy
  -- reader are shared, so they are tested here rather than in FileSpec.
  describe "gatewayTableCodec / loadLegacyGatewayTable" $ do
    let full = PartialGatewayConfig
          { pgcPort = Just 9090
          , pgcWsPort = Just 9091
          , pgcHost = Just "0.0.0.0"
          , pgcStaticDir = Just "/srv/seal"
          , pgcAllowedOrigins = ["http://example.com", "http://localhost:8080"]
          , pgcTlsCert = Just "/srv/seal/fullchain.pem"
          , pgcTlsKey = Just "/srv/seal/privkey.pem"
          , pgcTls = Just True
          , pgcTlsHosts = ["seal.example.com"]
          }

    it "round-trips the table through the codec" $
      case Toml.parse (Toml.encode gatewayTableCodec (Just full)) of
        Left err -> expectationFailure (T.unpack (Toml.unTomlParseError err))
        Right toml ->
          Toml.runTomlCodec gatewayTableCodec toml `shouldBe` Success (Just full)

    it "decodes the table out of a document that holds other sections" $
      withSystemTempDirectory "seal-gw-cfg" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ T.unlines
          [ "default_provider = \"anthropic\""
          , ""
          , "[gateway]"
          , "host = \"0.0.0.0\""
          , "port = 9090"
          , ""
          , "[retrieval]"
          , "max_scan_bytes = 1024"
          ]
        table <- loadLegacyGatewayTable path
        fmap pgcHost table `shouldBe` Just (Just "0.0.0.0")
        fmap pgcPort table `shouldBe` Just (Just 9090)

    it "is Nothing for an absent file, an unparseable file, or no table" $
      withSystemTempDirectory "seal-gw-cfg" $ \dir -> do
        loadLegacyGatewayTable (dir </> "absent.toml") `shouldReturn` Nothing
        TIO.writeFile (dir </> "bad.toml") "port = [not toml"
        loadLegacyGatewayTable (dir </> "bad.toml") `shouldReturn` Nothing
        TIO.writeFile (dir </> "clean.toml") "default_provider = \"anthropic\"\n"
        loadLegacyGatewayTable (dir </> "clean.toml") `shouldReturn` Nothing

  -- TLS is what makes a passkey ceremony possible without a reverse proxy:
  -- WebAuthn needs a secure context, and a plain http LAN address is not one.
  describe "TLS" $ do
    let tlsCfg cert key = defaultGatewayConfig { gcTlsCert = cert, gcTlsKey = key }

    it "is off by default" $ do
      tlsEnabled defaultGatewayConfig `shouldBe` False
      tlsConfigError defaultGatewayConfig `shouldBe` Nothing

    it "is on only when both the certificate and the key are set" $ do
      tlsEnabled (tlsCfg (Just "cert.pem") (Just "key.pem")) `shouldBe` True
      tlsEnabled (tlsCfg (Just "cert.pem") Nothing) `shouldBe` False
      tlsEnabled (tlsCfg Nothing (Just "key.pem")) `shouldBe` False

    it "refuses a half-configured pair rather than failing in the handshake" $ do
      tlsConfigError (tlsCfg (Just "cert.pem") (Just "key.pem")) `shouldBe` Nothing
      tlsConfigError (tlsCfg (Just "cert.pem") Nothing) `shouldSatisfy` isJust
      tlsConfigError (tlsCfg Nothing (Just "key.pem")) `shouldSatisfy` isJust

    it "requires an https origin once TLS is on" $ do
      tlsOriginError False (Just "http://localhost:8080") `shouldBe` Nothing
      tlsOriginError True (Just "https://seal.example.com") `shouldBe` Nothing
      tlsOriginError True Nothing `shouldBe` Nothing
      -- The derived loopback origin, and any explicit http one, would fail
      -- every ceremony's origin check against an https listener.
      tlsOriginError True (Just "http://localhost:8080") `shouldSatisfy` isJust
      tlsOriginError True (Just "http://192.168.0.107:8080") `shouldSatisfy` isJust

    -- `tls = true` is meant to be the whole configuration: the PEM paths are
    -- implied, and an explicit one only overrides its side of the pair.
    it "defaults both paths, and lets either be overridden" $ do
      let cfg = defaultGatewayConfig { gcTls = True }
      effectiveTlsPaths "/k/tls/cert.pem" "/k/tls/key.pem" cfg
        `shouldBe` ("/k/tls/cert.pem", "/k/tls/key.pem")
      effectiveTlsPaths "/k/tls/cert.pem" "/k/tls/key.pem"
        cfg { gcTlsCert = Just "/etc/ssl/fullchain.pem" }
        `shouldBe` ("/etc/ssl/fullchain.pem", "/k/tls/key.pem")
      effectiveTlsPaths "/k/tls/cert.pem" "/k/tls/key.pem"
        cfg { gcTlsKey = Just "/etc/ssl/privkey.pem" }
        `shouldBe` ("/k/tls/cert.pem", "/etc/ssl/privkey.pem")

    it "is on when the flag is set, or when both paths are given" $ do
      tlsEnabled defaultGatewayConfig `shouldBe` False
      tlsEnabled (defaultGatewayConfig { gcTls = True }) `shouldBe` True
