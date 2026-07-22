{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.RegistrySpec (spec) where

import Data.IORef (IORef, newIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Network.HTTP.Client (defaultManagerSettings, newManager)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec

import Seal.Config.File (RuntimeConfig (..), ProviderConfig (..), defaultRuntimeConfig)
import Seal.Core.Types (ModelId (..), ProviderId (..))
import Seal.Providers.Anthropic.OAuth (OAuthTokens (..), serializeTokens)
import Seal.Providers.Class
  ( CompletionResponse (..), Provider (..), SomeProvider (..)
  , StopReason (..), Usage (..) )
import Seal.Providers.Registry
  ( KnownProvider (..)
  , completeSome
  , configuredProviders
  , defaultModelFor
  , knownProviders
  , listSome
  , parseProvider
  , providerId
  , providerLabel
  , resolveDefaultModel
  , resolveProvider
  , vaultKeyName
  )
import Seal.Security.Secrets (mkBearerToken, mkRefreshToken)
import Seal.TestHelpers.FakeVault (makeFakeVault, makeLockedVault)

newtype Canned = Canned (Either T.Text CompletionResponse)
instance Provider Canned where
  complete (Canned r) _ = pure r
  listModels _ = pure (Right [])

-- | A tiny provider whose 'listModels' returns a fixed, non-empty list — used
-- to assert 'listSome' really passes the result through (not a tautology).
newtype CannedModels = CannedModels [ModelId]
instance Provider CannedModels where
  complete _ _ = pure (Left "CannedModels.complete not exercised")
  listModels (CannedModels ms) = pure (Right ms)

-- | A shared counter for resolveProvider calls in these tests. The synthesized
-- Ollama tool-call ids aren't inspected here, so a single process-wide counter
-- is fine; we just need to thread the new argument through.
counter :: IORef Int
counter = unsafePerformIO (newIORef 0)
{-# NOINLINE counter #-}

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

  describe "listSome" $
    it "passes listModels through the wrapped provider" $ do
      r <- listSome (SomeProvider (CannedModels [ModelId "m1", ModelId "m2"]))
      r `shouldBe` Right [ModelId "m1", ModelId "m2"]

  describe "resolveProvider" $ do
    it "resolves Anthropic when the credential is present" $ do
      vh  <- makeFakeVault [("ANTHROPIC_API_KEY", "sk-test")]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr "http://localhost:11434" AnthropicProvider (ModelId "claude-opus-4-8") counter
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure $ "expected Right, got Left: " <> show e

    it "reports a missing credential with an actionable hint" $ do
      vh  <- makeFakeVault []
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr "http://localhost:11434" AnthropicProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("provider add" `T.isInfixOf`)
        Right _ -> expectationFailure "expected a Left for a missing credential"

    it "reports a locked vault" $ do
      vh  <- makeLockedVault
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr "http://localhost:11434" AnthropicProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("locked" `T.isInfixOf`)
        Right _ -> expectationFailure "expected a Left for a locked vault"

    it "resolves via OAuth tokens when only they are present (no HTTP for a fresh token)" $ do
      let toks = OAuthTokens (mkBearerToken "acc") (mkRefreshToken "ref")
                             (posixSecondsToUTCTime 4102444800) -- 2100: fresh
      vh  <- makeFakeVault [("ANTHROPIC_OAUTH_TOKENS", serializeTokens toks)]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr "http://localhost:11434" AnthropicProvider (ModelId "claude-opus-4-8") counter
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right (OAuth), got Left: " <> show e)

    it "prefers OAuth over an API key: a corrupt OAuth blob fails rather than falling back" $ do
      vh  <- makeFakeVault
               [ ("ANTHROPIC_OAUTH_TOKENS", "not-json")
               , ("ANTHROPIC_API_KEY",      "sk-fallback")
               ]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr "http://localhost:11434" AnthropicProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("OAuth" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left: corrupt OAuth blob must not fall back to the API key"

    it "reports vault not configured for Anthropic with no vault handle" $ do
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider Nothing mgr "http://localhost:11434" AnthropicProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("vault not configured" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left for no vault handle"

  describe "resolveProvider (ollama)" $ do
    it "resolves local Ollama with no stored key" $ do
      vh  <- makeFakeVault []
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr "http://localhost:11434" OllamaProvider (ModelId "llama3.2") counter
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right (local), got Left: " <> show e)

    it "resolves cloud Ollama when a key is present" $ do
      vh  <- makeFakeVault [("OLLAMA_API_KEY", "k-cloud")]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr "https://ollama.com" OllamaProvider (ModelId "m") counter
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right (cloud), got Left: " <> show e)

    it "resolves local Ollama with no vault handle at all (keyless, vault untouched)" $ do
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider Nothing mgr "http://localhost:11434" OllamaProvider (ModelId "m") counter
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right (local, no vault), got Left: " <> show e)

    it "resolves local Ollama even with a locked vault (vault untouched)" $ do
      vh  <- makeLockedVault
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr "http://localhost:11434" OllamaProvider (ModelId "m") counter
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right (local, locked vault untouched), got Left: " <> show e)

    it "reports a missing key for the cloud host with no vault handle" $ do
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider Nothing mgr "https://ollama.com" OllamaProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` (\t -> "key" `T.isInfixOf` t || "provider add" `T.isInfixOf` t)
        Right _ -> expectationFailure "expected Left for cloud host with no vault"

    it "surfaces a locked vault for the cloud host" $ do
      vh  <- makeLockedVault
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr "https://ollama.com" OllamaProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("locked" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left for a locked vault on the cloud host"

  describe "resolveDefaultModel" $ do
    it "uses the configured value when present" $
      resolveDefaultModel (Just "glm-5.2:cloud") "ollama" `shouldBe` ModelId "glm-5.2:cloud"
    it "falls back to the provider's hardcoded default" $ do
      resolveDefaultModel Nothing "ollama"    `shouldBe` ModelId "llama3.2"
      resolveDefaultModel Nothing "anthropic" `shouldBe` ModelId "claude-opus-4-8"
    it "falls back to anthropic for an unknown label" $
      resolveDefaultModel Nothing "who" `shouldBe` ModelId "claude-opus-4-8"

  describe "configuredProviders" $ do
    it "includes ollama (local) even with no vault and no credentials" $ do
      ps <- configuredProviders Nothing defaultRuntimeConfig
      ps `shouldBe` [OllamaProvider]

    it "includes ollama (local) with an empty vault" $ do
      vh <- makeFakeVault []
      ps <- configuredProviders (Just vh) defaultRuntimeConfig
      ps `shouldBe` [OllamaProvider]

    it "includes anthropic when an API key is stored" $ do
      vh <- makeFakeVault [("ANTHROPIC_API_KEY", "sk-x")]
      ps <- configuredProviders (Just vh) defaultRuntimeConfig
      ps `shouldSatisfy` elem AnthropicProvider

    it "includes anthropic when an OAuth blob is stored" $ do
      let toks = OAuthTokens (mkBearerToken "acc") (mkRefreshToken "ref")
                             (posixSecondsToUTCTime 4102444800)
      vh <- makeFakeVault [("ANTHROPIC_OAUTH_TOKENS", serializeTokens toks)]
      ps <- configuredProviders (Just vh) defaultRuntimeConfig
      ps `shouldSatisfy` elem AnthropicProvider

    it "excludes anthropic when no credential is stored" $ do
      vh <- makeFakeVault []
      ps <- configuredProviders (Just vh) defaultRuntimeConfig
      ps `shouldNotSatisfy` elem AnthropicProvider

    it "excludes ollama when the base URL is cloud and no key is stored" $ do
      vh <- makeFakeVault []
      let cfg = defaultRuntimeConfig
            { rcProviders = Map.fromList
                [ ("ollama", ProviderConfig { pcDefaultModel = Nothing
                                            , pcBaseUrl = Just "https://ollama.com" }) ]
            }
      ps <- configuredProviders (Just vh) cfg
      ps `shouldNotSatisfy` elem OllamaProvider

    it "includes ollama when the base URL is cloud and a key is stored" $ do
      vh <- makeFakeVault [("OLLAMA_API_KEY", "k-cloud")]
      let cfg = defaultRuntimeConfig
            { rcProviders = Map.fromList
                [ ("ollama", ProviderConfig { pcDefaultModel = Nothing
                                            , pcBaseUrl = Just "https://ollama.com" }) ]
            }
      ps <- configuredProviders (Just vh) cfg
      ps `shouldSatisfy` elem OllamaProvider

    it "excludes both when the vault is locked" $ do
      vh <- makeLockedVault
      ps <- configuredProviders (Just vh) defaultRuntimeConfig
      -- local ollama is keyless so it survives even a locked vault (it never
      -- touches the vault); anthropic is excluded.
      ps `shouldBe` [OllamaProvider]
