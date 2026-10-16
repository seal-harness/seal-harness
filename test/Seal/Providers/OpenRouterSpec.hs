{-# LANGUAGE OverloadedStrings #-}
-- | WU-003 Security & Tests — TDD spec skeleton (RED → GREEN).
-- Failing test first: asserts `complete` returns `Left` when vault missing;
-- asserts `listModels` returns `Right` with default model.
-- Minimal skeleton (`OpenRouter` instance) passes — GREEN step.
module Seal.Providers.OpenRouterSpec (spec) where

import Data.Either (isLeft)
import Test.Hspec

import Seal.Core.Types (ModelId (..))
import Seal.Providers.Class (CompletionRequest (..), Provider (..), textMsg, Role (..), ToolChoice (..))
import Seal.Providers.OpenRouter (OpenRouter (..), mkOpenRouter, defaultOpenRouterBaseUrl)

spec :: Spec
spec = describe "Seal.Providers.OpenRouter — WU-003 TDD skeleton" $ do
  -- RED phase: no provider skeleton → these fail.
  -- GREEN phase: minimal `OpenRouter` instance in src/ passes.

  describe "complete (vault missing)" $ do
    it "returns Left when vault missing (Nothing ApiKey)" $ do
      let prov = mkOpenRouter Nothing defaultOpenRouterBaseUrl (ModelId "openrouter/default")
          req  = CompletionRequest (ModelId "openrouter/default") Nothing [textMsg User "test"] [] ToolAuto 256
      r <- complete prov req
      r `shouldSatisfy` isLeft

  describe "listModels" $ do
    it "returns Right with default model" $ do
      let prov = mkOpenRouter Nothing defaultOpenRouterBaseUrl (ModelId "openrouter/default")
      r <- listModels prov
      r `shouldBe` Right [ModelId "openrouter/default"]
