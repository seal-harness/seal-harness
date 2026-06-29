module Seal.AppMainSpec (spec) where

import Test.Hspec

import Seal.AppMain (withDefaultArgs)

spec :: Spec
spec = describe "Seal.AppMain.withDefaultArgs" $ do
  it "rewrites an empty argument list to --help" $
    withDefaultArgs [] `shouldBe` ["--help"]

  it "passes a non-empty argument list through unchanged" $
    withDefaultArgs ["tui"] `shouldBe` ["tui"]

  it "leaves an explicit --help unchanged" $
    withDefaultArgs ["--help"] `shouldBe` ["--help"]
