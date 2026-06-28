module Seal.ConfigSpec (spec) where

import Data.Aeson

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