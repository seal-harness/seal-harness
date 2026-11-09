module Seal.AppMainSpec (spec) where

import Test.Hspec

import Seal.AppMain (reorderGlobalArgs, withDefaultArgs)

spec :: Spec
spec = describe "Seal.AppMain" $ do
  describe "withDefaultArgs" $ do
    it "rewrites an empty argument list to --help" $
      withDefaultArgs [] `shouldBe` ["--help"]

    it "passes a non-empty argument list through unchanged" $
      withDefaultArgs ["tui"] `shouldBe` ["tui"]

    it "leaves an explicit --help unchanged" $
      withDefaultArgs ["--help"] `shouldBe` ["--help"]

  describe "reorderGlobalArgs" $ do
    it "hoists --log-level before the subcommand keyword" $
      reorderGlobalArgs ["serve", "--yolo", "--log-level", "debug", "--no-enrollment-token"]
        `shouldBe` ["--log-level", "debug", "serve", "--yolo", "--no-enrollment-token"]

    it "leaves args unchanged when no subcommand is present" $
      reorderGlobalArgs ["--log-level", "debug"] `shouldBe` ["--log-level", "debug"]

    it "leaves args unchanged when globals are already before the subcommand" $
      reorderGlobalArgs ["--log-level", "debug", "serve", "--yolo"]
        `shouldBe` ["--log-level", "debug", "serve", "--yolo"]

    it "hoists multiple global options" $
      reorderGlobalArgs ["serve", "--yolo", "--log-level", "debug", "--server-host", "0.0.0.0", "--no-enrollment-token"]
        `shouldBe` ["--log-level", "debug", "--server-host", "0.0.0.0", "serve", "--yolo", "--no-enrollment-token"]
