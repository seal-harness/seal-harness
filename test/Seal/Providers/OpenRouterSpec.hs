{-# LANGUAGE OverloadedStrings #-}
-- | WU-003 Security & Tests — TDD spec. The minimal assertions here keep the
-- suite compiling + green after WU-B's `mkOpenRouter` signature change
-- (3-arg → 4-arg, adding a 'Manager'). WU-C rewrites this file with the full
-- encode/decode/empty-choices/mapFinishReason/no-key/listModels/bearerHeaders
-- test suite.
module Seal.Providers.OpenRouterSpec (spec) where

import Data.Either (isLeft)
import Network.HTTP.Client.TLS (newTlsManager)
import Test.Hspec

import Seal.Core.Types (ModelId (..))
import Seal.Providers.Class (CompletionRequest (..), Provider (..), Role (..), ToolChoice (..), textMsg)
import Seal.Providers.OpenRouter (defaultOpenRouterBaseUrl, mkOpenRouter)

spec :: Spec
spec = describe "Seal.Providers.OpenRouter — WU-B skeleton contract" $ do

  describe "complete (vault missing)" $ do
    it "returns Left when the API key is absent (Nothing ApiKey)" $ do
      mgr <- newTlsManager
      let prov = mkOpenRouter mgr Nothing defaultOpenRouterBaseUrl (ModelId "openrouter/default")
          req  = CompletionRequest (ModelId "openrouter/default") Nothing [textMsg User "test"] [] ToolAuto 256
      r <- complete prov req
      r `shouldSatisfy` isLeft

  describe "listModels" $ do
    it "returns Right with the default model" $ do
      mgr <- newTlsManager
      let prov = mkOpenRouter mgr Nothing defaultOpenRouterBaseUrl (ModelId "openrouter/default")
      r <- listModels prov
      r `shouldBe` Right [ModelId "openrouter/default"]