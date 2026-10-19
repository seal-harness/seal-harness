{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.RegistrySpec (spec) where

import Control.Monad (when)
import Data.Either (isLeft)
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
import Seal.Providers.Ollama (defaultOllamaBaseUrl)
import Seal.Providers.OpenAICompat (OpenAICompatSpec (..))
import Seal.Providers.Registry
  ( KnownProvider (..)
  , catalogProblems
  , completeSome
  , configuredProviders
  , configuredProvidersFor
  , defaultModelFor
  , genericOpenAICompat
  , knownProviders
  , listSome
  , openAICompatSpecs
  , parseProvider
  , parseProviderIn
  , providerAuthStatus
  , providerBaseUrlFor
  , providerDisplayName
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

newtype CannedModels = CannedModels [ModelId]
instance Provider CannedModels where
  complete _ _ = pure (Left "CannedModels.complete not exercised")
  listModels (CannedModels ms) = pure (Right ms)

-- | 'SomeProvider' has no 'Show', so assert resolution explicitly.
shouldResolve :: Either T.Text SomeProvider -> Expectation
shouldResolve (Right _) = pure ()
shouldResolve (Left e)  = expectationFailure ("expected Right, got Left: " <> T.unpack e)

counter :: IORef Int
counter = unsafePerformIO (newIORef 0)
{-# NOINLINE counter #-}

-- | A synthetic preset row: built-in URL, key required. Lets the catalog seam
-- be exercised without shipping a preset (step 3).
presetSpec :: OpenAICompatSpec
presetSpec = OpenAICompatSpec
  { ocsId             = "acme"
  , ocsDisplayName    = "Acme"
  , ocsVaultKey       = "ACME_API_KEY"
  , ocsBuiltinBaseUrl = Just "https://acme.example/v1"
  , ocsDefaultModel   = Just (ModelId "acme-large")
  , ocsKeyRequired    = True
  , ocsModels         = [ModelId "acme-large", ModelId "acme-small"]
  , ocsExtraHeaders   = []
  }

presetProvider :: KnownProvider
presetProvider = OpenAICompatProvider presetSpec

genericProvider :: KnownProvider
genericProvider = OpenAICompatProvider genericOpenAICompat

-- | A runtime config whose @[providers.<label>] base_url@ is set.
cfgWithUrl :: T.Text -> T.Text -> RuntimeConfig
cfgWithUrl label u = defaultRuntimeConfig
  { rcProviders = Map.fromList
      [(label, ProviderConfig { pcDefaultModel = Nothing, pcBaseUrl = Just u })] }

ollamaCfg :: Maybe T.Text -> RuntimeConfig
ollamaCfg = maybe defaultRuntimeConfig (cfgWithUrl "ollama")

genericCfg :: Maybe T.Text -> RuntimeConfig
genericCfg = maybe defaultRuntimeConfig (cfgWithUrl "openai-compat")

spec :: Spec
spec = describe "Seal.Providers.Registry" $ do

  describe "catalog" $ do
    it "lists the shipped providers in order" $
      knownProviders `shouldBe` [AnthropicProvider, OllamaProvider, genericProvider]

    it "has no catalog problems" $
      catalogProblems openAICompatSpecs `shouldBe` []

    it "reports duplicate and blank ids (a preset cannot shadow another)" $ do
      let blank = presetSpec { ocsId = "  " }
      catalogProblems [presetSpec, presetSpec]
        `shouldSatisfy` any ("duplicate id" `T.isInfixOf`)
      catalogProblems [blank] `shouldSatisfy` any ("blank id" `T.isInfixOf`)

    it "reports an unusable built-in base URL" $
      catalogProblems [presetSpec { ocsBuiltinBaseUrl = Just "ftp://h/v1" }]
        `shouldSatisfy` any ("built-in base URL is not usable" `T.isInfixOf`)

    it "makes an appended row reachable by label" $
      parseProviderIn (knownProviders <> [presetProvider]) "ACME" `shouldBe` Just presetProvider

    it "rejects unknown providers" $
      parseProvider "definitely-not-a-provider" `shouldBe` Nothing

  describe "vocabulary" $ do
    it "labels each provider" $ do
      providerLabel AnthropicProvider `shouldBe` "anthropic"
      providerLabel OllamaProvider    `shouldBe` "ollama"
      providerLabel genericProvider   `shouldBe` "openai-compat"

    it "maps to a ProviderId" $
      providerId AnthropicProvider `shouldBe` ProviderId "anthropic"

    it "parses labels case-insensitively" $ do
      parseProvider "Anthropic"     `shouldBe` Just AnthropicProvider
      parseProvider "Ollama"        `shouldBe` Just OllamaProvider
      parseProvider "OpenAI-Compat" `shouldBe` Just genericProvider

    it "names the vault credential key" $ do
      vaultKeyName AnthropicProvider `shouldBe` "ANTHROPIC_API_KEY"
      vaultKeyName OllamaProvider    `shouldBe` "OLLAMA_API_KEY"
      vaultKeyName genericProvider   `shouldBe` "OPENAI_COMPAT_API_KEY"
      vaultKeyName presetProvider    `shouldBe` "ACME_API_KEY"

    it "has a display name for prompts and errors" $ do
      providerDisplayName AnthropicProvider `shouldBe` "Anthropic"
      providerDisplayName OllamaProvider    `shouldBe` "Ollama"
      providerDisplayName genericProvider   `shouldBe` "OpenAI-compatible"
      providerDisplayName presetProvider    `shouldBe` "Acme"

    it "has default models where the provider knows one" $ do
      defaultModelFor AnthropicProvider `shouldBe` ModelId "claude-opus-4-8"
      defaultModelFor OllamaProvider    `shouldBe` ModelId "llama3.2"
      defaultModelFor presetProvider    `shouldBe` ModelId "acme-large"

  describe "completeSome / listSome" $ do
    it "passes the request through to the wrapped provider" $ do
      let resp = CompletionResponse [] StopEnd (Usage 1 2)
      r <- completeSome (SomeProvider (Canned (Right resp))) (error "request not forced")
      r `shouldBe` Right resp

    it "passes listModels through the wrapped provider" $ do
      r <- listSome (SomeProvider (CannedModels [ModelId "m1", ModelId "m2"]))
      r `shouldBe` Right [ModelId "m1", ModelId "m2"]

  describe "providerBaseUrlFor" $ do
    it "gives each built-in provider its own endpoint" $ do
      providerBaseUrlFor defaultRuntimeConfig AnthropicProvider
        `shouldBe` Right "https://api.anthropic.com"
      providerBaseUrlFor defaultRuntimeConfig OllamaProvider
        `shouldBe` Right defaultOllamaBaseUrl

    it "does not let a provider inherit another's configured URL" $ do
      providerBaseUrlFor (ollamaCfg (Just "http://localhost:9999")) genericProvider
        `shouldSatisfy` isLeft

    it "requires a base URL for the generic row" $ do
      case providerBaseUrlFor defaultRuntimeConfig genericProvider of
        Left e -> do
          e `shouldSatisfy` ("needs a base URL" `T.isInfixOf`)
          e `shouldSatisfy` ("Providers view" `T.isInfixOf`)
          e `shouldSatisfy` ("/provider add openai-compat" `T.isInfixOf`)
        Right u -> expectationFailure ("expected Left, got " <> T.unpack u)

    it "canonicalises the configured generic URL" $
      providerBaseUrlFor (genericCfg (Just "http://h/v1/")) genericProvider
        `shouldBe` Right "http://h/v1"

    it "rejects an unusable configured generic URL with the reason" $
      case providerBaseUrlFor (genericCfg (Just "ftp://h/v1")) genericProvider of
        Left e -> do
          e `shouldSatisfy` ("not usable" `T.isInfixOf`)
          e `shouldSatisfy` ("scheme must be http or https" `T.isInfixOf`)
        Right u -> expectationFailure ("expected Left, got " <> T.unpack u)

    it "keeps Ollama's hand-written no-scheme URL working (unchanged)" $
      providerBaseUrlFor (ollamaCfg (Just "localhost:11434")) OllamaProvider
        `shouldBe` Right "localhost:11434"

    it "treats a preset's built-in URL as authoritative" $
      providerBaseUrlFor (cfgWithUrl "acme" "https://evil.example/v1") presetProvider
        `shouldBe` Right "https://acme.example/v1"

  describe "resolveProvider (anthropic)" $ do
    it "resolves when the credential is present" $ do
      vh  <- makeFakeVault [("ANTHROPIC_API_KEY", "sk-test")]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig AnthropicProvider (ModelId "claude-opus-4-8") counter
      shouldResolve r

    it "reports a missing credential with an actionable hint" $ do
      vh  <- makeFakeVault []
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig AnthropicProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("provider add" `T.isInfixOf`)
        Right _ -> expectationFailure "expected a Left"

    it "reports a locked vault" $ do
      vh  <- makeLockedVault
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig AnthropicProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("locked" `T.isInfixOf`)
        Right _ -> expectationFailure "expected a Left"

    it "resolves via OAuth tokens when only they are present" $ do
      let toks = OAuthTokens (mkBearerToken "acc") (mkRefreshToken "ref")
                             (posixSecondsToUTCTime 4102444800)
      vh  <- makeFakeVault [("ANTHROPIC_OAUTH_TOKENS", serializeTokens toks)]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig AnthropicProvider (ModelId "claude-opus-4-8") counter
      shouldResolve r

    it "a corrupt OAuth blob fails rather than falling back to the API key" $ do
      vh  <- makeFakeVault
               [ ("ANTHROPIC_OAUTH_TOKENS", "not-json")
               , ("ANTHROPIC_API_KEY",      "sk-fallback")
               ]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig AnthropicProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("OAuth" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

    it "reports vault not configured with no vault handle" $ do
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider Nothing mgr defaultRuntimeConfig AnthropicProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("vault not configured" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

  describe "resolveProvider (ollama)" $ do
    it "resolves local Ollama with no stored key" $ do
      vh  <- makeFakeVault []
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig OllamaProvider (ModelId "llama3.2") counter
      shouldResolve r

    it "resolves cloud Ollama when a key is present" $ do
      vh  <- makeFakeVault [("OLLAMA_API_KEY", "k-cloud")]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr (ollamaCfg (Just "https://ollama.com")) OllamaProvider (ModelId "m") counter
      shouldResolve r

    it "resolves local Ollama with no vault handle at all" $ do
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider Nothing mgr defaultRuntimeConfig OllamaProvider (ModelId "m") counter
      shouldResolve r

    it "reports a locked vault for the cloud host with the unlock hint" $ do
      vh  <- makeLockedVault
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr (ollamaCfg (Just "https://ollama.com")) OllamaProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("/vault unlock" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

  describe "resolveProvider (openai-compat)" $ do
    it "reports the missing base URL before anything else" $ do
      vh  <- makeFakeVault []
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig genericProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("needs a base URL" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

    it "resolves keyless with no vault handle at all" $ do
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider Nothing mgr (genericCfg (Just "http://127.0.0.1:9/v1")) genericProvider (ModelId "m") counter
      shouldResolve r

    it "resolves keyless even with a locked vault (vault untouched)" $ do
      vh  <- makeLockedVault
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr (genericCfg (Just "http://127.0.0.1:9/v1")) genericProvider (ModelId "m") counter
      shouldResolve r

    it "resolves keyless with a readable key (the key is used when present)" $ do
      vh  <- makeFakeVault [("OPENAI_COMPAT_API_KEY", "sk-oc")]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr (genericCfg (Just "http://127.0.0.1:9/v1")) genericProvider (ModelId "m") counter
      shouldResolve r

    it "requires a key for a key-required row, with the add hint" $ do
      vh  <- makeFakeVault []
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig presetProvider (ModelId "m") counter
      case r of
        Left e -> do
          e `shouldSatisfy` ("needs an API key" `T.isInfixOf`)
          e `shouldSatisfy` ("/provider add acme" `T.isInfixOf`)
          e `shouldSatisfy` ("no need to remove it first" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

    it "distinguishes a locked vault from a missing key" $ do
      vh  <- makeLockedVault
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig presetProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("/vault unlock" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

    it "distinguishes no vault from a missing key" $ do
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider Nothing mgr defaultRuntimeConfig presetProvider (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("/vault setup" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

    it "resolves a key-required row when the key is stored" $ do
      vh  <- makeFakeVault [("ACME_API_KEY", "sk-acme")]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider (Just vh) mgr defaultRuntimeConfig presetProvider (ModelId "m") counter
      shouldResolve r

  describe "providerAuthStatus" $ do
    it "walks none -> keyless -> api-key for the generic row" $ do
      mgr <- newManager defaultManagerSettings
      _ <- pure mgr
      nothing <- providerAuthStatus Nothing defaultRuntimeConfig genericProvider
      nothing `shouldBe` "none"
      noKey <- makeFakeVault []
      s1 <- providerAuthStatus (Just noKey) (genericCfg (Just "http://127.0.0.1:9/v1")) genericProvider
      s1 `shouldBe` "keyless"
      withKey <- makeFakeVault [("OPENAI_COMPAT_API_KEY", "sk-oc")]
      s2 <- providerAuthStatus (Just withKey) (genericCfg (Just "http://127.0.0.1:9/v1")) genericProvider
      s2 `shouldBe` "api-key"

    it "reports none when the base URL is missing" $ do
      vh <- makeFakeVault []
      s <- providerAuthStatus (Just vh) defaultRuntimeConfig genericProvider
      s `shouldBe` "none"

    it "reports vault-locked for a key-required row with a locked vault" $ do
      vh <- makeLockedVault
      s <- providerAuthStatus (Just vh) defaultRuntimeConfig presetProvider
      s `shouldBe` "vault-locked"

    it "reports keyless for a keyless row even with a locked vault" $ do
      vh <- makeLockedVault
      s <- providerAuthStatus (Just vh) (genericCfg (Just "http://127.0.0.1:9/v1")) genericProvider
      s `shouldBe` "keyless"

    it "follows Ollama's URL for the keyless/keyed distinction" $ do
      vh <- makeFakeVault [("OLLAMA_API_KEY", "k")]
      local <- providerAuthStatus (Just vh) defaultRuntimeConfig OllamaProvider
      local `shouldBe` "keyless"
      cloud <- providerAuthStatus (Just vh) (ollamaCfg (Just "https://ollama.com")) OllamaProvider
      cloud `shouldBe` "api-key"

  describe "configuredProviders" $ do
    it "includes local ollama with no vault and no credentials" $ do
      ps <- configuredProviders Nothing defaultRuntimeConfig
      ps `shouldBe` [OllamaProvider]

    it "includes anthropic when an API key is stored" $ do
      vh <- makeFakeVault [("ANTHROPIC_API_KEY", "sk-x")]
      ps <- configuredProviders (Just vh) defaultRuntimeConfig
      ps `shouldSatisfy` elem AnthropicProvider

    it "excludes ollama when the base URL is cloud and no key is stored" $ do
      vh <- makeFakeVault []
      ps <- configuredProviders (Just vh) (ollamaCfg (Just "https://ollama.com"))
      ps `shouldNotSatisfy` elem OllamaProvider

    it "excludes a family row whose base URL does not resolve" $ do
      ps <- configuredProviders Nothing defaultRuntimeConfig
      ps `shouldNotSatisfy` elem genericProvider

    it "includes a keyless family row once its base URL resolves" $ do
      ps <- configuredProviders Nothing (genericCfg (Just "http://127.0.0.1:9/v1"))
      ps `shouldSatisfy` elem genericProvider

    it "excludes a key-required row without a key and includes it with one" $ do
      noKey <- makeFakeVault []
      ps1 <- configuredProvidersFor [presetProvider] (Just noKey) defaultRuntimeConfig
      ps1 `shouldBe` []
      withKey <- makeFakeVault [("ACME_API_KEY", "sk-acme")]
      ps2 <- configuredProvidersFor [presetProvider] (Just withKey) defaultRuntimeConfig
      ps2 `shouldBe` [presetProvider]

    it "keeps the authStatus/configured invariant" $ do
      -- authStatus == "none" => not configured (the UI's dropdown depends on
      -- this direction); a key-required row in a locked vault is deliberately
      -- visible-but-not-configured.
      let cfgs = [defaultRuntimeConfig, genericCfg (Just "http://127.0.0.1:9/v1")]
          checkOn mvh cfg = mapM_ (\kp -> do
            status <- providerAuthStatus mvh cfg kp
            configured <- configuredProvidersFor knownProviders mvh cfg
            when (status == "none")
              (configured `shouldNotSatisfy` elem kp)) knownProviders
      vhs <- sequence [makeFakeVault [], makeFakeVault [("OPENAI_COMPAT_API_KEY", "k")]
                      , makeLockedVault]
      mapM_ (\vh -> mapM_ (checkOn (Just vh)) cfgs) vhs
      mapM_ (checkOn Nothing) cfgs

  describe "resolveDefaultModel" $ do
    it "uses the configured value when present" $
      resolveDefaultModel (Just "glm-5.2:cloud") "ollama" `shouldBe` ModelId "glm-5.2:cloud"
    it "falls back to the provider's default" $ do
      resolveDefaultModel Nothing "ollama"    `shouldBe` ModelId "llama3.2"
      resolveDefaultModel Nothing "anthropic" `shouldBe` ModelId "claude-opus-4-8"
    it "falls back to anthropic for an unknown label" $
      resolveDefaultModel Nothing "who" `shouldBe` ModelId "claude-opus-4-8"
