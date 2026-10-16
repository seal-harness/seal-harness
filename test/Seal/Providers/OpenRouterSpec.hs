{-# LANGUAGE OverloadedStrings #-}
-- | Skeleton spec for OpenRouter provider wiring (WU-002).
-- TDD: failing test asserts registry recognizes 'openrouter';
-- minimal registry wiring passes.
module Seal.Providers.OpenRouterSpec (spec) where

import Test.Hspec
import Data.Text qualified as T

import Seal.Core.Types (ModelId (..), ProviderId (..))
import Seal.Providers.Registry
  ( KnownProvider (..)
  , providerLabel
  , providerId
  , parseProvider
  , defaultModelFor
  , vaultKeyName
  )

spec :: Spec
spec = describe "Seal.Providers.OpenRouter wiring" $ do
  it "lists openrouter in known providers" $ do
    parseProvider "openrouter" `shouldBe` Just OpenRouterProvider

  it "labels openrouter" $ do
    providerLabel OpenRouterProvider `shouldBe` "openrouter"

  it "maps openrouter to ProviderId" $ do
    providerId OpenRouterProvider `shouldBe` ProviderId "openrouter"

  it "names the vault key for openrouter" $ do
    vaultKeyName OpenRouterProvider `shouldBe` "OPENROUTER_API_KEY"

  it "has a default model for openrouter" $ do
    -- Default model value to be defined by registry wiring
    defaultModelFor OpenRouterProvider `shouldSatisfy` (\(ModelId m) -> not (T.null m))
