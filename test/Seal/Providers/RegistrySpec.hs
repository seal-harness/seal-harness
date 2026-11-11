{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.RegistrySpec (spec) where

import Data.IORef (IORef, newIORef)
import Data.Either (isLeft)
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
  , configuredCustomProviderNames
  , customProviderNames
  , defaultModelFor
  , knownProviders
  , listSome
  , parseProvider
  , providerBaseUrlFor
  , providerId
  , providerLabel
  , resolveDefaultModel
  , resolveDefaultModelForName
  , resolveProvider
  , resolveProviderByName
  , validateProviderName
  , vaultKeyName
  , vaultKeyNameForName
  )
import Seal.Providers.Ollama (defaultOllamaBaseUrl)
import Seal.Providers.OpenRouter (defaultOpenRouterBaseUrl)
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

-- | A runtime config whose @[providers.ollama] base_url@ is set (or the
-- built-in local default when 'Nothing'). Lets the tests drive the Ollama
-- base URL through the config instead of a bare string.
ollamaCfg :: Maybe T.Text -> RuntimeConfig
ollamaCfg mUrl = defaultRuntimeConfig
  { rcProviders =
      maybe Map.empty
        (\u -> Map.fromList
          [("ollama", ProviderConfig { pcDefaultModel = Nothing, pcBaseUrl = Just u })])
        mUrl
  }

-- | A runtime config whose @[providers.openrouter] base_url@ is set.
openRouterCfg :: Maybe T.Text -> RuntimeConfig
openRouterCfg mUrl = defaultRuntimeConfig
  { rcProviders =
      maybe Map.empty
        (\u -> Map.fromList
          [("openrouter", ProviderConfig { pcDefaultModel = Nothing, pcBaseUrl = Just u })])
        mUrl
  }

-- | A runtime config whose @[providers.openai] base_url@ is set (or absent).
openAICfg :: Maybe T.Text -> RuntimeConfig
openAICfg mUrl = defaultRuntimeConfig
  { rcProviders =
      maybe Map.empty
        (\u -> Map.fromList
          [("openai", ProviderConfig { pcDefaultModel = Nothing, pcBaseUrl = Just u })])
        mUrl
  }

-- | A runtime config with one custom OpenAI-compatible instance.
customCfg :: T.Text -> Maybe T.Text -> RuntimeConfig
customCfg name mUrl = defaultRuntimeConfig
  { rcProviders =
      Map.fromList
        [(name, ProviderConfig { pcDefaultModel = Just "my-model", pcBaseUrl = mUrl })]
  }

spec :: Spec
spec = describe "Seal.Providers.Registry vocabulary" $ do
  it "lists the known providers" $
    knownProviders
      `shouldBe` [ AnthropicProvider, OllamaProvider, OpenRouterProvider
                 , OpenAICompatibleProvider ]

  it "labels Anthropic" $
    providerLabel AnthropicProvider `shouldBe` "anthropic"

  it "labels Ollama" $
    providerLabel OllamaProvider `shouldBe` "ollama"

  it "labels OpenRouter" $
    providerLabel OpenRouterProvider `shouldBe` "openrouter"

  it "labels the generic OpenAI-compatible provider" $ do
    providerLabel OpenAICompatibleProvider `shouldBe` "openai"
    vaultKeyName OpenAICompatibleProvider `shouldBe` "OPENAI_API_KEY"
    parseProvider "openai" `shouldBe` Just OpenAICompatibleProvider

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
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig AnthropicProvider (ModelId "claude-opus-4-8") counter
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure $ "expected Right, got Left: " <> show e

    it "reports a missing credential with an actionable hint" $ do
      vh  <- makeFakeVault []
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig AnthropicProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("provider add" `T.isInfixOf`)
        Right _ -> expectationFailure "expected a Left for a missing credential"

    it "reports a locked vault" $ do
      vh  <- makeLockedVault
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig AnthropicProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("locked" `T.isInfixOf`)
        Right _ -> expectationFailure "expected a Left for a locked vault"

    it "resolves via OAuth tokens when only they are present (no HTTP for a fresh token)" $ do
      let toks = OAuthTokens (mkBearerToken "acc") (mkRefreshToken "ref")
                             (posixSecondsToUTCTime 4102444800) -- 2100: fresh
      vh  <- makeFakeVault [("ANTHROPIC_OAUTH_TOKENS", serializeTokens toks)]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig AnthropicProvider (ModelId "claude-opus-4-8") counter
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right (OAuth), got Left: " <> show e)

    it "prefers OAuth over an API key: a corrupt OAuth blob fails rather than falling back" $ do
      vh  <- makeFakeVault
               [ ("ANTHROPIC_OAUTH_TOKENS", "not-json")
               , ("ANTHROPIC_API_KEY",      "sk-fallback")
               ]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig AnthropicProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("OAuth" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left: corrupt OAuth blob must not fall back to the API key"

    it "reports vault not configured for Anthropic with no vault handle" $ do
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider Nothing mgr defaultRuntimeConfig AnthropicProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("vault not configured" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left for no vault handle"

  describe "resolveProvider (ollama)" $ do
    it "resolves local Ollama with no stored key" $ do
      vh  <- makeFakeVault []
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig OllamaProvider (ModelId "llama3.2") counter
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right (local), got Left: " <> show e)

    it "resolves cloud Ollama when a key is present" $ do
      vh  <- makeFakeVault [("OLLAMA_API_KEY", "k-cloud")]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr (ollamaCfg (Just "https://ollama.com")) OllamaProvider (ModelId "m") counter
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right (cloud), got Left: " <> show e)

    it "resolves local Ollama with no vault handle at all (keyless, vault untouched)" $ do
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider Nothing mgr defaultRuntimeConfig OllamaProvider (ModelId "m") counter
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right (local, no vault), got Left: " <> show e)

    it "resolves local Ollama even with a locked vault (vault untouched)" $ do
      vh  <- makeLockedVault
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig OllamaProvider (ModelId "m") counter
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right (local, locked vault untouched), got Left: " <> show e)

    it "reports a missing key for the cloud host with no vault handle" $ do
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider Nothing mgr (ollamaCfg (Just "https://ollama.com")) OllamaProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` (\t -> "key" `T.isInfixOf` t || "provider add" `T.isInfixOf` t)
        Right _ -> expectationFailure "expected Left for cloud host with no vault"

    it "surfaces a locked vault for the cloud host" $ do
      vh  <- makeLockedVault
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr (ollamaCfg (Just "https://ollama.com")) OllamaProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("locked" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left for a locked vault on the cloud host"

  describe "resolveProvider (openrouter)" $ do
    it "resolves when a key is stored" $ do
      vh  <- makeFakeVault [("OPENROUTER_API_KEY", "sk-or")]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig OpenRouterProvider (ModelId "m") counter
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right, got Left: " <> show e)

    it "reports a missing key with an actionable hint" $ do
      vh  <- makeFakeVault []
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig OpenRouterProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("provider add" `T.isInfixOf`)
        Right _ -> expectationFailure "expected a Left for a missing credential"

    it "reports no vault handle" $ do
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider Nothing mgr defaultRuntimeConfig OpenRouterProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("API key" `T.isInfixOf`)
        Right _ -> expectationFailure "expected a Left for no vault handle"

  describe "resolveProvider (openai-compatible)" $ do
    it "refuses to resolve without a base URL (never guesses api.openai.com)" $ do
      vh  <- makeFakeVault [("OPENAI_API_KEY", "sk-local")]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig
               OpenAICompatibleProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("base URL" `T.isInfixOf`)
        Right _ -> expectationFailure "expected a Left when no endpoint is configured"

    it "resolves against the configured endpoint with a stored key" $ do
      vh  <- makeFakeVault [("OPENAI_API_KEY", "sk-local")]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr (openAICfg (Just "http://localhost:8000/v1"))
               OpenAICompatibleProvider (ModelId "m") counter
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right, got Left: " <> show e)

    it "reports a missing key with an actionable hint" $ do
      vh  <- makeFakeVault []
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr (openAICfg (Just "http://localhost:8000/v1"))
               OpenAICompatibleProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("provider add" `T.isInfixOf`)
        Right _ -> expectationFailure "expected a Left for a missing credential"

  describe "configuredProviders (openai-compatible)" $ do
    it "needs BOTH the endpoint and the key" $ do
      vh  <- makeFakeVault [("OPENAI_API_KEY", "sk-local")]
      keyed <- configuredProviders (Just vh) (openAICfg (Just "http://localhost:8000/v1"))
      keyed `shouldSatisfy` elem OpenAICompatibleProvider
      endpointOnly <- configuredProviders (Just vh) defaultRuntimeConfig
      endpointOnly `shouldSatisfy` notElem OpenAICompatibleProvider

  describe "providerBaseUrlFor" $ do
    it "uses each provider's OWN default base URL" $ do
      providerBaseUrlFor defaultRuntimeConfig OllamaProvider
        `shouldBe` defaultOllamaBaseUrl
      providerBaseUrlFor defaultRuntimeConfig OpenRouterProvider
        `shouldBe` defaultOpenRouterBaseUrl

    it "OpenRouter does NOT inherit Ollama's configured base URL (regression)" $ do
      -- The bug: an OpenRouter session POSTed to the Ollama base URL (the
      -- local daemon), yielding \"404 page not found\". Each provider must
      -- read its OWN [providers.<label>] section.
      providerBaseUrlFor (ollamaCfg (Just "http://localhost:9999")) OpenRouterProvider
        `shouldBe` defaultOpenRouterBaseUrl

    it "reads [providers.<label>] base_url per provider" $ do
      let cfg = openRouterCfg (Just "https://proxy.example/v1")
      providerBaseUrlFor cfg OpenRouterProvider `shouldBe` "https://proxy.example/v1"
      providerBaseUrlFor cfg OllamaProvider    `shouldBe` defaultOllamaBaseUrl

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

  describe "custom provider instances" $ do
    it "validates names against the allow-list grammar" $ do
      validateProviderName "local-vllm" `shouldBe` Right ()
      validateProviderName "openai" `shouldBe` Right ()
      validateProviderName "a" `shouldBe` Right ()
      validateProviderName "" `shouldSatisfy` isLeft
      validateProviderName "Local" `shouldSatisfy` isLeft
      validateProviderName "-x" `shouldSatisfy` isLeft
      validateProviderName "x-" `shouldSatisfy` isLeft
      validateProviderName "a--b" `shouldSatisfy` isLeft
      validateProviderName "all" `shouldSatisfy` isLeft
      validateProviderName "anthropic" `shouldSatisfy` isLeft

    it "derives a distinct vault key for a custom name" $ do
      vaultKeyNameForName "local-vllm" `shouldBe` "PROVIDER_APIKEY_LOCAL_VLLM"
      vaultKeyNameForName "openai" `shouldBe` "OPENAI_API_KEY"

    it "lists only non-built-in config sections as custom instances" $ do
      let cfg = customCfg "local-vllm" (Just "http://localhost:8000/v1")
      customProviderNames cfg `shouldBe` ["local-vllm"]

    it "resolves a custom instance against its own endpoint and vault key" $ do
      vh <- makeFakeVault [("PROVIDER_APIKEY_LOCAL_VLLM", "sk-local")]
      mgr <- newManager defaultManagerSettings
      r <- resolveProviderByName (Just vh) mgr
             (customCfg "local-vllm" (Just "http://localhost:8000/v1"))
             "local-vllm" (ModelId "m") counter
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right, got Left: " <> show e)

    it "refuses a custom instance with no endpoint" $ do
      vh <- makeFakeVault [("PROVIDER_APIKEY_LOCAL_VLLM", "sk-local")]
      mgr <- newManager defaultManagerSettings
      r <- resolveProviderByName (Just vh) mgr
             (customCfg "local-vllm" Nothing)
             "local-vllm" (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("base URL" `T.isInfixOf`)
        Right _ -> expectationFailure "expected a Left when no endpoint is configured"

    it "counts a custom instance as configured only with URL and key" $ do
      vh <- makeFakeVault [("PROVIDER_APIKEY_LOCAL_VLLM", "sk-local")]
      withKey <- configuredCustomProviderNames (Just vh)
        (customCfg "local-vllm" (Just "http://localhost:8000/v1"))
      withKey `shouldBe` ["local-vllm"]
      noUrl <- configuredCustomProviderNames (Just vh)
        (customCfg "local-vllm" Nothing)
      noUrl `shouldBe` []

    it "uses the OpenAI-compatible default model for a custom name" $ do
      resolveDefaultModelForName (customCfg "local-vllm" Nothing) "local-vllm"
        `shouldBe` ModelId "my-model"
      resolveDefaultModelForName defaultRuntimeConfig "local-vllm"
        `shouldBe` defaultModelFor OpenAICompatibleProvider
