{-# LANGUAGE OverloadedStrings #-}
module Seal.Gateway.ConfigSpec (spec) where

import Data.Text qualified as T
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Config.File (FileConfig (..), defaultFileConfig, loadFileConfig, saveFileConfig)
import Seal.Gateway.Config

spec :: Spec
spec = describe "Seal.Gateway.Config" $ do
  describe "defaultGatewayConfig" $ do
    it "has port 8080, ws_port 8081, host 127.0.0.1" $ do
      gcPort defaultGatewayConfig `shouldBe` 8080
      gcWsPort defaultGatewayConfig `shouldBe` 8081
      gcHost defaultGatewayConfig `shouldBe` "127.0.0.1"
      gcStaticDir defaultGatewayConfig `shouldBe` Nothing
      gcAllowedOrigins defaultGatewayConfig `shouldBe` ["http://localhost:8080"]

  describe "withGatewayDefaults" $ do
    it "fills in defaults for missing fields" $ do
      let partial = PartialGatewayConfig { pgcPort = Just 9090, pgcWsPort = Nothing, pgcHost = Just "0.0.0.0", pgcStaticDir = Nothing, pgcAllowedOrigins = [] }
          full = withGatewayDefaults partial
      gcPort full `shouldBe` 9090
      gcWsPort full `shouldBe` 8081   -- default
      gcHost full `shouldBe` "0.0.0.0"
      gcStaticDir full `shouldBe` Nothing
      gcAllowedOrigins full `shouldBe` ["http://localhost:8080"]  -- default (empty → safe default)

    it "preserves all set fields" $ do
      let partial = PartialGatewayConfig { pgcPort = Just 9090, pgcWsPort = Just 9091, pgcHost = Just "0.0.0.0", pgcStaticDir = Just "/srv/seal", pgcAllowedOrigins = ["http://example.com"] }
          full = withGatewayDefaults partial
      gcPort full `shouldBe` 9090
      gcWsPort full `shouldBe` 9091
      gcHost full `shouldBe` "0.0.0.0"
      gcStaticDir full `shouldBe` Just "/srv/seal"
      gcAllowedOrigins full `shouldBe` ["http://example.com"]

  describe "TOML round-trip" $ do
    it "round-trips a [gateway] section with all fields set" $
      withSystemTempDirectory "seal-gw-cfg" $ \dir -> do
        let path = dir </> "config.toml"
            partial = PartialGatewayConfig
              { pgcPort = Just 9090
              , pgcWsPort = Just 9091
              , pgcHost = Just "0.0.0.0"
              , pgcStaticDir = Just "/srv/seal"
              , pgcAllowedOrigins = ["http://example.com", "http://localhost:8080"]
              }
            cfg = defaultFileConfig { fcGateway = Just partial }
        saveFileConfig path cfg
        result <- loadFileConfig path
        case result of
          Left err -> expectationFailure ("load failed: " <> T.unpack err)
          Right loaded -> fcGateway loaded `shouldBe` Just partial

    it "round-trips a [gateway] section with only some fields set (rest default)" $
      withSystemTempDirectory "seal-gw-cfg" $ \dir -> do
        let path = dir </> "config.toml"
            -- A user who sets only host + port, omitting ws_port + static_dir.
            partial = PartialGatewayConfig
              { pgcPort = Just 9090
              , pgcWsPort = Nothing
              , pgcHost = Just "0.0.0.0"
              , pgcStaticDir = Nothing
              , pgcAllowedOrigins = []
              }
            cfg = defaultFileConfig { fcGateway = Just partial }
        saveFileConfig path cfg
        result <- loadFileConfig path
        case result of
          Left err -> expectationFailure ("load failed: " <> T.unpack err)
          Right loaded -> do
            fcGateway loaded `shouldBe` Just partial
            -- The merge fills in ws_port + allowed_origins from defaults.
            let full = maybe defaultGatewayConfig withGatewayDefaults (fcGateway loaded)
            gcWsPort full `shouldBe` 8081
            gcAllowedOrigins full `shouldBe` ["http://localhost:8080"]

    it "absent section decodes as Nothing" $
      withSystemTempDirectory "seal-gw-cfg" $ \dir -> do
        let path = dir </> "config.toml"
        saveFileConfig path defaultFileConfig
        result <- loadFileConfig path
        case result of
          Right loaded -> fcGateway loaded `shouldBe` Nothing
          Left err -> expectationFailure ("load failed: " <> T.unpack err)