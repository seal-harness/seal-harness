{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.RegistrySpec (spec) where

import Data.Text qualified as T
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Test.Hspec

import Seal.Core.Types (ModelId (..), ProviderId (..))
import Seal.Providers.Class
  ( CompletionResponse (..), Provider (..), SomeProvider (..)
  , StopReason (..), Usage (..) )
import Seal.Providers.Registry
  ( KnownProvider (..)
  , completeSome
  , defaultModelFor
  , knownProviders
  , parseProvider
  , providerId
  , providerLabel
  , resolveProvider
  , vaultKeyName
  )
import Seal.TestHelpers.FakeVault (makeFakeVault, makeLockedVault)

newtype Canned = Canned (Either T.Text CompletionResponse)
instance Provider Canned where
  complete (Canned r) _ = pure r
  listModels _ = pure (Right [])

spec :: Spec
spec = describe "Seal.Providers.Registry vocabulary" $ do
  it "lists the known providers" $
    knownProviders `shouldBe` [AnthropicProvider]

  it "labels Anthropic" $
    providerLabel AnthropicProvider `shouldBe` "anthropic"

  it "maps Anthropic to its ProviderId" $
    providerId AnthropicProvider `shouldBe` ProviderId "anthropic"

  it "parses the label case-insensitively" $ do
    parseProvider "anthropic" `shouldBe` Just AnthropicProvider
    parseProvider "Anthropic" `shouldBe` Just AnthropicProvider

  it "rejects unknown providers" $
    parseProvider "definitely-not-a-provider" `shouldBe` Nothing

  it "names the vault credential key" $
    vaultKeyName AnthropicProvider `shouldBe` "ANTHROPIC_API_KEY"

  it "has a default model" $
    defaultModelFor AnthropicProvider `shouldBe` ModelId "claude-opus-4-8"

  describe "completeSome" $
    it "passes the request through to the wrapped provider" $ do
      let resp = CompletionResponse [] StopEnd (Usage 1 2)
      r <- completeSome (SomeProvider (Canned (Right resp)))
                        (error "request not forced")
      r `shouldBe` Right resp

  describe "resolveProvider" $ do
    it "resolves Anthropic when the credential is present" $ do
      vh  <- makeFakeVault [("ANTHROPIC_API_KEY", "sk-test")]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider vh mgr AnthropicProvider (ModelId "claude-opus-4-8")
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure $ "expected Right, got Left: " <> show e

    it "reports a missing credential with an actionable hint" $ do
      vh  <- makeFakeVault []
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider vh mgr AnthropicProvider (ModelId "m")
      case r of
        Left e  -> e `shouldSatisfy` ("provider add" `T.isInfixOf`)
        Right _ -> expectationFailure "expected a Left for a missing credential"

    it "reports a locked vault" $ do
      vh  <- makeLockedVault
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider vh mgr AnthropicProvider (ModelId "m")
      case r of
        Left e  -> e `shouldSatisfy` ("locked" `T.isInfixOf`)
        Right _ -> expectationFailure "expected a Left for a locked vault"
