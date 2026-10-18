{-# LANGUAGE OverloadedStrings #-}
module Seal.Gateway.EmbeddedSpec (spec) where

import Control.Monad (when)
import Data.List (isInfixOf, isPrefixOf)
import Data.Map.Strict qualified as Map
import Test.Hspec

import Seal.Gateway.Embedded

spec :: Spec
spec = do
  describe "embeddedAssets" $ do
    it "has a non-negative asset count" $
      embeddedAssetCount `shouldSatisfy` (>= 0)

    context "when assets are embedded (count > 0)" $ do
      -- These tests only run when frontend/dist exists at compile time.
      -- In a fresh checkout or pure nix build, count == 0 and we skip.
      it "contains index.html as a key" $
        when (embeddedAssetCount > 0) $
          Map.member "index.html" embeddedAssets `shouldBe` True

      it "keys are relative (no leading slash)" $
        when (embeddedAssetCount > 0) $
          not (any ("/" `isPrefixOf`) (Map.keys embeddedAssets)) `shouldBe` True

      it "keys use forward slashes (no backslashes)" $
        when (embeddedAssetCount > 0) $
          not (any ("\\" `isInfixOf`) (Map.keys embeddedAssets)) `shouldBe` True

      it "keys contain no .. traversal segments" $
        when (embeddedAssetCount > 0) $
          not (any (".." `isInfixOf`) (Map.keys embeddedAssets)) `shouldBe` True

    context "when no assets are embedded (count == 0)" $ do
      it "distManifest is non-empty (fallback file exists)" $
        when (embeddedAssetCount == 0) $
          null distManifest `shouldBe` False

  describe "distManifest" $ do
    it "is always non-empty" $
      null distManifest `shouldBe` False

  describe "embeddedAssetCount" $ do
    it "equals Map.size embeddedAssets" $
      embeddedAssetCount `shouldBe` Map.size embeddedAssets
