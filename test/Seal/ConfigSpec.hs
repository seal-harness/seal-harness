{-# LANGUAGE OverloadedStrings #-}
module Seal.ConfigSpec (spec) where

import Data.Aeson (Value (..), decode, encode)
import Data.Aeson.KeyMap qualified as KeyMap

import Test.Hspec

import Seal.Types.Config

spec :: Spec
spec = describe "Config" $ do
  it "defaultConfig survives a ToJSON → FromJSON-update round trip" $ do
    let encoded = encode defaultConfig
        update  = decode encoded :: Maybe (Config -> Config)
    case update of
      Nothing  -> expectationFailure "failed to parse defaultConfig JSON"
      Just f   -> f defaultConfig `shouldBe` defaultConfig

  -- The gateway's bind host/port live in security.toml. The legacy `[server]`
  -- scaffold was never wired to the listener and has been removed.
  it "--print-config does not emit a server section" $
    case decode (encode defaultConfig) :: Maybe Value of
      Just (Object o) -> KeyMap.member "server" o `shouldBe` False
      other           -> expectationFailure ("expected a JSON object, got: " <> show other)
