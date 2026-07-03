{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.RegistrySpec (spec) where

import Data.Text qualified as T
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Test.Hspec

import Seal.Core.Types (ModelId (..), ProviderId (..))
import Seal.Providers.Anthropic.OAuth (OAuthTokens (..), serializeTokens)
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
import Seal.Security.Secrets (mkBearerToken, mkRefreshToken)
import Seal.TestHelpers.FakeVault (makeFakeVault, makeLockedVault)

newtype Canned = Canned (Either T.Text CompletionResponse)
instance Provider Canned where
  complete (Canned r) _ = pure r
  listModels _ = pure (Right [])

spec :: Spec
spec = describe "Seal.Providers.Registry vocabulary" $ do
  it "lists the known providers" $
    knownProviders `shouldBe` [AnthropicProvider, OllamaProvider]

  it "labels Anthropic" $
    providerLabel AnthropicProvider `shouldBe` "anthropic"

  it "labels Ollama" $
    providerLabel OllamaProvider `shouldBe` "ollama"

  it "maps Anthropic to its ProviderId" $
    providerId AnthropicProvider `shouldBe` ProviderId "anthropic"

  it "parses the label case-insensitively" $ do
    parseProvider "anthropic" `shouldBe` Just AnthropicProvider
    parseProvider "Anthropic" `shouldBe` Just AnthropicProvider

  it "parses ollama case-insensitively" $ do
    parseProvider "ollama" `shouldBe` Just OllamaProvider
    parseProvider "Ollama" `shouldBe` Just OllamaProvider

  it "rejects unknown providers" $
    parseProvider "definitely-not-a-provider" `shouldBe` Nothing

  it "names the vault credential key" $
    vaultKeyName AnthropicProvider `shouldBe` "ANTHROPIC_API_KEY"

  it "names the Ollama vault credential key" $
    vaultKeyName OllamaProvider `shouldBe` "OLLAMA_API_KEY"

  it "has a default model" $
    defaultModelFor AnthropicProvider `shouldBe` ModelId "claude-opus-4-8"

  it "has an Ollama default model" $
    defaultModelFor OllamaProvider `shouldBe` ModelId "llama3.2"

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
      r   <- resolveProvider vh mgr "http://localhost:11434" AnthropicProvider (ModelId "claude-opus-4-8")
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure $ "expected Right, got Left: " <> show e

    it "reports a missing credential with an actionable hint" $ do
      vh  <- makeFakeVault []
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider vh mgr "http://localhost:11434" AnthropicProvider (ModelId "m")
      case r of
        Left e  -> e `shouldSatisfy` ("provider add" `T.isInfixOf`)
        Right _ -> expectationFailure "expected a Left for a missing credential"

    it "reports a locked vault" $ do
      vh  <- makeLockedVault
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider vh mgr "http://localhost:11434" AnthropicProvider (ModelId "m")
      case r of
        Left e  -> e `shouldSatisfy` ("locked" `T.isInfixOf`)
        Right _ -> expectationFailure "expected a Left for a locked vault"

    it "resolves via OAuth tokens when only they are present (no HTTP for a fresh token)" $ do
      let toks = OAuthTokens (mkBearerToken "acc") (mkRefreshToken "ref")
                             (posixSecondsToUTCTime 4102444800) -- 2100: fresh
      vh  <- makeFakeVault [("ANTHROPIC_OAUTH_TOKENS", serializeTokens toks)]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider vh mgr "http://localhost:11434" AnthropicProvider (ModelId "claude-opus-4-8")
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right (OAuth), got Left: " <> show e)

    it "prefers OAuth over an API key: a corrupt OAuth blob fails rather than falling back" $ do
      vh  <- makeFakeVault
               [ ("ANTHROPIC_OAUTH_TOKENS", "not-json")
               , ("ANTHROPIC_API_KEY",      "sk-fallback")
               ]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider vh mgr "http://localhost:11434" AnthropicProvider (ModelId "m")
      case r of
        Left e  -> e `shouldSatisfy` ("OAuth" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left: corrupt OAuth blob must not fall back to the API key"

  describe "resolveProvider (ollama)" $ do
    it "resolves local Ollama with no stored key" $ do
      vh  <- makeFakeVault []
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider vh mgr "http://localhost:11434" OllamaProvider (ModelId "llama3.2")
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right (local), got Left: " <> show e)

    it "resolves cloud Ollama when a key is present" $ do
      vh  <- makeFakeVault [("OLLAMA_API_KEY", "k-cloud")]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider vh mgr "https://ollama.com" OllamaProvider (ModelId "m")
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right (cloud), got Left: " <> show e)

    it "surfaces a locked vault rather than treating it as local" $ do
      vh  <- makeLockedVault
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider vh mgr "http://localhost:11434" OllamaProvider (ModelId "m")
      case r of
        Left e  -> e `shouldSatisfy` ("locked" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left for a locked vault"
