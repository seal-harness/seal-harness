{-# LANGUAGE OverloadedStrings #-}
module Seal.ConfigSpec (spec) where

import Data.Aeson

import Test.Hspec

import Seal.Types.Config

spec :: Spec
spec = describe "Config" $ do
  -- The legacy Configuration.Utils surface (`--print-config`, `--server-host`)
  -- is not wired to the gateway, but it must not advertise a default the
  -- gateway no longer uses.
  it "defaults --print-config's server host to localhost" $
    _serverConfig_host defaultServerConfig `shouldBe` "localhost"

  it "defaultConfig survives a ToJSON → FromJSON-update round trip" $ do
    let encoded = encode defaultConfig
        update  = decode encoded :: Maybe (Config -> Config)
    case update of
      Nothing  -> expectationFailure "failed to parse defaultConfig JSON"
      Just f   -> f defaultConfig `shouldBe` defaultConfig