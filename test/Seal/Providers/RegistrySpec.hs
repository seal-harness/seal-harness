{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.RegistrySpec (spec) where

import Data.IORef (IORef, newIORef)
import Data.Either (isLeft)
import Data.List (nub)
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
          [("ollama", ProviderConfig { pcDefaultModel = Nothing, pcBaseUrl = Just u, pcModels = Nothing })])
        mUrl
  }

-- | A runtime config whose @[providers.openrouter] base_url@ is set.
openRouterCfg :: Maybe T.Text -> RuntimeConfig
openRouterCfg mUrl = defaultRuntimeConfig
  { rcProviders =
      maybe Map.empty
        (\u -> Map.fromList
          [("openrouter", ProviderConfig { pcDefaultModel = Nothing, pcBaseUrl = Just u, pcModels = Nothing })])
        mUrl
  }

-- | A runtime config whose @[providers.openai-compatible] base_url@ is set (or
-- absent). The section key follows the type id, which D2 renames.
openAICfg :: Maybe T.Text -> RuntimeConfig
openAICfg mUrl = defaultRuntimeConfig
  { rcProviders =
      maybe Map.empty
        (\u -> Map.fromList
          [("openai-compatible", ProviderConfig { pcDefaultModel = Nothing, pcBaseUrl = Just u, pcModels = Nothing })])
        mUrl
  }

-- | A runtime config with one custom OpenAI-compatible instance.
customCfg :: T.Text -> Maybe T.Text -> RuntimeConfig
customCfg name mUrl = defaultRuntimeConfig
  { rcProviders =
      Map.fromList
        [(name, ProviderConfig { pcDefaultModel = Just "my-model", pcBaseUrl = mUrl, pcModels = Nothing })]
  }

spec :: Spec
spec = describe "Seal.Providers.Registry vocabulary" $ do
  it "lists the known providers in vendor-adjacent order (D2)" $
    knownProviders
      `shouldBe` [ AnthropicProvider, OllamaProvider, OllamaCloudProvider
                 , OpenRouterProvider, OpenAIProvider
                 , OpenAICompatibleProvider ]

  it "labels Anthropic" $
    providerLabel AnthropicProvider `shouldBe` "anthropic"

  it "labels Ollama" $
    providerLabel OllamaProvider `shouldBe` "ollama"

  it "labels OpenRouter" $
    providerLabel OpenRouterProvider `shouldBe` "openrouter"

  it "labels the generic OpenAI-compatible provider" $ do
    providerLabel OpenAICompatibleProvider `shouldBe` "openai-compatible"
    vaultKeyName OpenAICompatibleProvider `shouldBe` "OPENAI_COMPATIBLE_API_KEY"
    parseProvider "openai-compatible" `shouldBe` Just OpenAICompatibleProvider

  it "labels OpenAI" $ do
    providerLabel OpenAIProvider `shouldBe` "openai"
    parseProvider "openai" `shouldBe` Just OpenAIProvider

  it "labels Ollama Cloud" $ do
    providerLabel OllamaCloudProvider `shouldBe` "ollama-cloud"
    parseProvider "ollama-cloud" `shouldBe` Just OllamaCloudProvider

  -- Item 2: providerLabel is injective over knownProviders. Written over the
  -- list, not over six literals, so a future constructor is covered.
  it "gives every known provider a distinct label" $
    let ls = map providerLabel knownProviders
    in length ls `shouldBe` length (nub ls)

  -- Item 3: vaultKeyName is injective. This is the invariant D3 rests on.
  it "gives every known provider a distinct vault key" $
    let ks = map vaultKeyName knownProviders
    in length ks `shouldBe` length (nub ks)

  -- Item 4: every label round-trips.
  it "round-trips every label through parseProvider" $
    and [ parseProvider (providerLabel p) == Just p | p <- knownProviders ]

  -- Item 8: the vault keys, exactly as D3 specifies.
  it "maps each provider to its D3 vault key" $ do
    vaultKeyName AnthropicProvider        `shouldBe` "ANTHROPIC_API_KEY"
    vaultKeyName OllamaProvider           `shouldBe` "OLLAMA_API_KEY"
    vaultKeyName OllamaCloudProvider      `shouldBe` "OLLAMA_CLOUD_API_KEY"
    vaultKeyName OpenRouterProvider       `shouldBe` "OPENROUTER_API_KEY"
    vaultKeyName OpenAIProvider           `shouldBe` "OPENAI_API_KEY"
    vaultKeyName OpenAICompatibleProvider `shouldBe` "OPENAI_COMPATIBLE_API_KEY"

  -- Item 9: default models, exactly as D10 specifies.
  it "maps each provider to its D10 default model" $ do
    defaultModelFor OpenAIProvider           `shouldBe` ModelId "gpt-4o-mini"
    defaultModelFor OllamaCloudProvider      `shouldBe` ModelId "gemma4:31b"
    defaultModelFor OpenAICompatibleProvider `shouldBe` ModelId "gpt-4o-mini"

  -- Item 10/11: the new built-in endpoints.
  it "gives OpenAI and Ollama Cloud built-in base URLs" $ do
    providerBaseUrlFor defaultRuntimeConfig OpenAIProvider
      `shouldBe` "https://api.openai.com/v1"
    providerBaseUrlFor defaultRuntimeConfig OllamaCloudProvider
      `shouldBe` "https://ollama.com/v1"

  -- Item 40 (GUARD): the generic type deliberately keeps NO default.
  it "still gives the generic OpenAI-compatible type no default base URL" $
    providerBaseUrlFor defaultRuntimeConfig OpenAICompatibleProvider `shouldBe` ""

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

  describe "resolveProvider (openai)" $ do
    -- Item 18: the message names openai, not the generic type.
    it "reports a missing key naming openai, not OpenAI-compatible" $ do
      vh  <- makeFakeVault []
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig
               OpenAIProvider (ModelId "m") counter
      case r of
        Left e -> do
          -- The exact subject + separator. "openai" alone is a substring of
          -- "openai-compatible", so a bare substring check would pass if the
          -- implementation named the WRONG provider; " — " pins the boundary.
          e `shouldSatisfy` ("no credential for openai \8212 " `T.isInfixOf`)
          e `shouldSatisfy` (not . ("openai-compatible" `T.isInfixOf`))
        Right _ -> expectationFailure "expected a Left for a missing credential"

    -- Item 35b/35g (case 2): with no [providers.openai] section at all, a
    -- stored key resolves against the built-in default. No guard exists any
    -- more, so this is simply the happy path.
    it "resolves off the built-in endpoint with no config section" $ do
      vh  <- makeFakeVault [("OPENAI_API_KEY", "sk-openai")]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig
               OpenAIProvider (ModelId "m") counter
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right, got Left: " <> show e)

    -- Item 12: a configured base_url still overrides the built-in default.
    it "honours a configured base_url over the built-in default" $ do
      vh  <- makeFakeVault [("OPENAI_API_KEY", "sk-openai")]
      mgr <- newManager defaultManagerSettings
      let cfg = defaultRuntimeConfig
            { rcProviders = Map.fromList
                [("openai", ProviderConfig { pcDefaultModel = Nothing
                                           , pcBaseUrl = Just "http://localhost:8000/v1"
                                           , pcModels = Nothing })] }
      r <- resolveProvider (Just vh) mgr cfg OpenAIProvider (ModelId "m") counter
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right, got Left: " <> show e)

    -- Item 21b: an explicitly EMPTY base_url does not silently fall back to the
    -- built-in. providerBaseUrlFor yields "" for Just "", and the shared helper
    -- fails closed. This is the one state where the default is not used.
    it "fails closed on an explicitly empty base_url" $ do
      vh  <- makeFakeVault [("OPENAI_API_KEY", "sk-openai")]
      mgr <- newManager defaultManagerSettings
      let cfg = defaultRuntimeConfig
            { rcProviders = Map.fromList
                [("openai", ProviderConfig { pcDefaultModel = Nothing
                                           , pcBaseUrl = Just ""
                                           , pcModels = Nothing })] }
      r <- resolveProvider (Just vh) mgr cfg OpenAIProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("base URL" `T.isInfixOf`)
        Right _ -> expectationFailure "expected a Left for an empty base_url"

  describe "resolveProvider (ollama-cloud)" $ do
    -- Item 21b, the ollama-cloud half: an explicitly empty base_url does not
    -- fall back to https://ollama.com/v1. Only an ABSENT section uses the
    -- built-in; an explicit "" is a configured-but-unusable value.
    it "fails closed on an explicitly empty base_url" $ do
      vh  <- makeFakeVault [("OLLAMA_CLOUD_API_KEY", "sk-cloud")]
      mgr <- newManager defaultManagerSettings
      let cfg = defaultRuntimeConfig
            { rcProviders = Map.fromList
                [("ollama-cloud", ProviderConfig { pcDefaultModel = Nothing
                                                 , pcBaseUrl = Just ""
                                                 , pcModels = Nothing })] }
      r <- resolveProvider (Just vh) mgr cfg OllamaCloudProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("base URL" `T.isInfixOf`)
        Right _ -> expectationFailure "expected a Left for an empty base_url"

    -- Item 19: names ollama-cloud, not the generic type; D3 keeps the noun
    -- neutral so no display/id confusion is possible.
    it "reports a missing key naming ollama-cloud" $ do
      vh  <- makeFakeVault []
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig
               OllamaCloudProvider (ModelId "m") counter
      case r of
        Left e -> do
          -- Exact subject + separator: this also pins the id/display-name
          -- separation (never "[providers.Ollama Cloud]" or a bare label).
          e `shouldSatisfy` ("no credential for ollama-cloud \8212 " `T.isInfixOf`)
          e `shouldSatisfy` (not . ("OpenAI-compatible" `T.isInfixOf`))
        Right _ -> expectationFailure "expected a Left for a missing credential"

    it "resolves off the built-in endpoint with a stored key" $ do
      vh  <- makeFakeVault [("OLLAMA_CLOUD_API_KEY", "sk-cloud")]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig
               OllamaCloudProvider (ModelId "m") counter
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right, got Left: " <> show e)

    -- Items 14-17: key required, no keyless mode. And D3 injectivity means an
    -- OLLAMA_API_KEY does not satisfy Ollama Cloud.
    it "does not accept the local Ollama key" $ do
      vh  <- makeFakeVault [("OLLAMA_API_KEY", "sk-local")]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig
               OllamaCloudProvider (ModelId "m") counter
      case r of
        Left _  -> pure ()
        Right _ -> expectationFailure
          "Ollama Cloud must not resolve off the local Ollama key"

  describe "resolveProvider (openai-compatible)" $ do
    it "refuses to resolve without a base URL (never guesses api.openai.com)" $ do
      vh  <- makeFakeVault [("OPENAI_API_KEY", "sk-local")]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig
               OpenAICompatibleProvider (ModelId "m") counter
      case r of
        Left e -> do
          e `shouldSatisfy` ("base URL" `T.isInfixOf`)
          -- Item 20: the error must name the section to edit. A bare "openai"
          -- substring check would pass on "openai-compatible", so assert both
          -- directions.
          e `shouldSatisfy` ("[providers.openai-compatible]" `T.isInfixOf`)
          e `shouldSatisfy` (not . ("[providers.openai]" `T.isInfixOf`))
        Right _ -> expectationFailure "expected a Left when no endpoint is configured"

    it "resolves against the configured endpoint with a stored key" $ do
      -- The generic type now owns OPENAI_COMPATIBLE_API_KEY; OPENAI_API_KEY
      -- belongs to real OpenAI (D3).
      vh  <- makeFakeVault [("OPENAI_COMPATIBLE_API_KEY", "sk-local")]
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

  describe "configuredProviders (the two new types)" $ do
    it "includes OpenAI when OPENAI_API_KEY is stored" $ do
      vh <- makeFakeVault [("OPENAI_API_KEY", "sk-openai")]
      ps <- configuredProviders (Just vh) defaultRuntimeConfig
      ps `shouldSatisfy` elem OpenAIProvider

    it "includes Ollama Cloud only when OLLAMA_CLOUD_API_KEY is stored" $ do
      vh  <- makeFakeVault [("OLLAMA_CLOUD_API_KEY", "sk-cloud")]
      ps  <- configuredProviders (Just vh) defaultRuntimeConfig
      ps `shouldSatisfy` elem OllamaCloudProvider

      -- D3 injectivity through the PUBLIC filter: the local Ollama key must
      -- not make Ollama Cloud appear configured.
      vh2 <- makeFakeVault [("OLLAMA_API_KEY", "sk-local")]
      ps2 <- configuredProviders (Just vh2) defaultRuntimeConfig
      ps2 `shouldSatisfy` notElem OllamaCloudProvider

    -- Item 16: neither new type has a keyless mode.
    it "includes neither new type when no keys are stored" $ do
      vh <- makeFakeVault []
      ps <- configuredProviders (Just vh) defaultRuntimeConfig
      ps `shouldSatisfy` notElem OpenAIProvider
      ps `shouldSatisfy` notElem OllamaCloudProvider

  describe "configuredProviders (openai-compatible)" $ do
    it "needs BOTH the endpoint and the key" $ do
      vh  <- makeFakeVault [("OPENAI_COMPATIBLE_API_KEY", "sk-local")]
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
                                            , pcBaseUrl = Just "https://ollama.com"
                                            , pcModels = Nothing }) ]
            }
      ps <- configuredProviders (Just vh) cfg
      ps `shouldNotSatisfy` elem OllamaProvider

    it "includes ollama when the base URL is cloud and a key is stored" $ do
      vh <- makeFakeVault [("OLLAMA_API_KEY", "k-cloud")]
      let cfg = defaultRuntimeConfig
            { rcProviders = Map.fromList
                [ ("ollama", ProviderConfig { pcDefaultModel = Nothing
                                            , pcBaseUrl = Just "https://ollama.com"
                                            , pcModels = Nothing }) ]
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
      -- D9: "openai" is now a built-in type, so it is reserved.
      validateProviderName "openai" `shouldSatisfy` isLeft
      validateProviderName "a" `shouldBe` Right ()
      validateProviderName "" `shouldSatisfy` isLeft
      validateProviderName "Local" `shouldSatisfy` isLeft
      validateProviderName "-x" `shouldSatisfy` isLeft
      validateProviderName "x-" `shouldSatisfy` isLeft
      validateProviderName "a--b" `shouldSatisfy` isLeft
      validateProviderName "all" `shouldSatisfy` isLeft
      validateProviderName "anthropic" `shouldSatisfy` isLeft

    -- Item 13 (property): every built-in label is reserved. Written over the
    -- list so a future constructor is covered without editing this test.
    it "reserves every built-in label as an instance name" $
      and [ isLeft (validateProviderName (providerLabel p)) | p <- knownProviders ]

    -- D9: a blocked operator must be told a concrete alternative, not just
    -- "no". Without this the guidance could be deleted with the suite green.
    it "names a concrete alternative when rejecting a built-in label" $
      case validateProviderName "openai" of
        Left e  -> e `shouldSatisfy` ("my-openai-endpoint" `T.isInfixOf`)
        Right _ -> expectationFailure "expected openai to be reserved"

    it "derives a distinct vault key for a custom name" $ do
      vaultKeyNameForName "local-vllm" `shouldBe` "PROVIDER_APIKEY_LOCAL_VLLM"
      -- After the rename "openai" is a BUILT-IN, so the name-derived path no
      -- longer applies to it; assert the built-in mapping instead.
      vaultKeyNameForName "openai" `shouldBe` "OPENAI_API_KEY"
      vaultKeyNameForName "openai-compatible" `shouldBe` "OPENAI_COMPATIBLE_API_KEY"

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
