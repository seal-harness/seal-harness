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
    it "has port 8080, host 127.0.0.1" $ do
      gcPort defaultGatewayConfig `shouldBe` 8080
      gcHost defaultGatewayConfig `shouldBe` "127.0.0.1"
      gcStaticDir defaultGatewayConfig `shouldBe` Nothing
      gcAllowedOrigins defaultGatewayConfig `shouldBe` ["http://localhost:8080"]

  describe "TOML round-trip" $ do
    it "round-trips a [gateway] section" $
      withSystemTempDirectory "seal-gw-cfg" $ \dir -> do
        let path = dir </> "config.toml"
            cfg = defaultFileConfig
                    { fcGateway = Just defaultGatewayConfig
                        { gcPort = 9090
                        , gcHost = "0.0.0.0"
                        , gcStaticDir = Just "/srv/seal"
                        , gcAllowedOrigins = ["http://example.com", "http://localhost:8080"]
                        }
                    }
        saveFileConfig path cfg
        result <- loadFileConfig path
        case result of
          Left err -> expectationFailure ("load failed: " <> T.unpack err)
          Right loaded -> fcGateway loaded `shouldBe` fcGateway cfg

    it "absent section decodes as Nothing" $
      withSystemTempDirectory "seal-gw-cfg" $ \dir -> do
        let path = dir </> "config.toml"
        saveFileConfig path defaultFileConfig
        result <- loadFileConfig path
        case result of
          Right loaded -> fcGateway loaded `shouldBe` Nothing
          Left err -> expectationFailure ("load failed: " <> T.unpack err)