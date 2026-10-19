{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.RegistrySpec (spec) where

import Control.Monad (when)
import Data.Either (isLeft)
import Data.Maybe (isJust)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Network.HTTP.Client (Manager, defaultManagerSettings, newManager)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec

import Seal.Config.File
  ( ProviderConfig (..), RuntimeConfig (..), defaultRuntimeConfig )
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
  , ProviderCredentials (..)
  , ProviderInstance (..)
  , configuredInstances
  , findInstance
  , genericOpenAICompat
  , instanceAuthStatus
  , instanceCredentials
  , instanceLabelList
  , resolveDefaultModelFor
  , resolveInstance
  , providerBaseUrlForInstance
  , catalogProblems
  , knownProviders
  , legacyTypeIds
  , providerInstances
  , providerTypeForId
  , providerTypes
  , typeId
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
import Seal.Security.Vault (VaultHandle (..))

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
      [(label, ProviderConfig { pcDefaultModel = Nothing, pcBaseUrl = Just u
                              , pcType = Nothing })] }

ollamaCfg :: Maybe T.Text -> RuntimeConfig
ollamaCfg = maybe defaultRuntimeConfig (cfgWithUrl "ollama")

genericCfg :: Maybe T.Text -> RuntimeConfig
genericCfg = maybe defaultRuntimeConfig (cfgWithUrl "openai-compat")

specMain :: Spec
specMain = describe "Seal.Providers.Registry" $ do

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
      defaultModelFor AnthropicProvider `shouldBe` Just (ModelId "claude-opus-4-8")
      defaultModelFor OllamaProvider    `shouldBe` Just (ModelId "llama3.2")
      defaultModelFor presetProvider    `shouldBe` Just (ModelId "acme-large")

    it "has no default model for the generic row" $
      defaultModelFor genericProvider `shouldBe` Nothing

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
      resolveDefaultModel (Just "glm-5.2:cloud") "ollama" `shouldBe` Just (ModelId "glm-5.2:cloud")
    it "treats an empty configured model as unset" $
      resolveDefaultModel (Just "") "ollama" `shouldBe` Just (ModelId "llama3.2")
    it "falls back to the provider's default" $ do
      resolveDefaultModel Nothing "ollama"    `shouldBe` Just (ModelId "llama3.2")
      resolveDefaultModel Nothing "anthropic" `shouldBe` Just (ModelId "claude-opus-4-8")
    it "falls back to anthropic for an unknown label" $
      resolveDefaultModel Nothing "who" `shouldBe` Just (ModelId "claude-opus-4-8")
    it "has no default for the generic row" $
      resolveDefaultModel Nothing "openai-compat" `shouldBe` Nothing

-- ---------------------------------------------------------------------------
-- Provider instances (#273 WU-1)
-- ---------------------------------------------------------------------------

-- | A section in the config map.
sec :: Maybe T.Text -> Maybe T.Text -> Maybe T.Text -> ProviderConfig
sec ty url model = ProviderConfig { pcType = ty, pcBaseUrl = url, pcDefaultModel = model }

cfgWith :: [(T.Text, ProviderConfig)] -> RuntimeConfig
cfgWith xs = defaultRuntimeConfig { rcProviders = Map.fromList xs }

instanceSpec :: Spec
instanceSpec = describe "providerInstances (#273)" $ do

  it "synthesizes one row per type for an empty config" $ do
    let rows = providerInstances defaultRuntimeConfig
    map piName rows `shouldBe` ["anthropic", "ollama", "openai-compat"]
    map piHasSection rows `shouldBe` [False, False, False]
    map piProblem rows `shouldBe` [Nothing, Nothing, Nothing]
    map (fmap typeId . piType) rows
      `shouldBe` [Just "anthropic", Just "ollama", Just "openai-compat"]
    map piTypeId rows `shouldBe` [Nothing, Nothing, Nothing]
    map (isJust . piNameValid) rows `shouldBe` [True, True, True]

  it "keeps catalog order when a section claims a type name" $ do
    let rows = providerInstances (cfgWith [("anthropic", sec Nothing Nothing Nothing)])
    map piName rows `shouldBe` ["anthropic", "ollama", "openai-compat"]
    map piHasSection (take 1 rows) `shouldBe` [True]

  it "appends explicit extra instances after the type rows, by name" $ do
    let cfg = cfgWith
          [ ("groq", sec (Just "openai-compat") (Just "https://groq.example/v1") (Just "m1"))
          , ("aaa", sec (Just "openai-compat") (Just "http://localhost:8000/v1") Nothing)
          ]
        rows = providerInstances cfg
    map piName rows `shouldBe` ["anthropic", "ollama", "openai-compat", "aaa", "groq"]
    map (fmap typeId . piType) (drop 3 rows) `shouldBe` [Just "openai-compat", Just "openai-compat"]
    -- each instance keeps its OWN section
    map (pcBaseUrl . piConfig) (drop 3 rows)
      `shouldBe` [Just "http://localhost:8000/v1", Just "https://groq.example/v1"]

  it "resolves a typed section, case-insensitively, keeping the raw text for display" $ do
    let rows = providerInstances (cfgWith [("work", sec (Just "OpenAI-Compat") Nothing Nothing)])
        work = [ r | r <- rows, piName r == "work" ]
    map (fmap typeId . piType) work `shouldBe` [Just "openai-compat"]
    map piTypeId work `shouldBe` [Just "OpenAI-Compat"]
    map piProblem work `shouldBe` [Nothing]

  it "treats an empty type as absent (back-compat fallback)" $ do
    let rows = providerInstances (cfgWith [("ollama", sec (Just "") (Just "https://ollama.com") Nothing)])
        o = [ r | r <- rows, piName r == "ollama" ]
    map (fmap typeId . piType) o `shouldBe` [Just "ollama"]
    map piProblem o `shouldBe` [Nothing]

  it "reports a present-but-unknown type instead of falling back" $ do
    let rows = providerInstances (cfgWith [("anthropic", sec (Just "anthorpic") Nothing Nothing)])
        a = [ r | r <- rows, piName r == "anthropic" ]
    map piType a `shouldBe` [Nothing]
    map piProblem a `shouldSatisfy` all (maybe False ("unknown provider type: anthorpic" `T.isInfixOf`))

  it "reports a type-less section whose name is not a legacy type id" $ do
    let rows = providerInstances (cfgWith [("groq", sec Nothing Nothing Nothing)])
        g = [ r | r <- rows, piName r == "groq" ]
    map piType g `shouldBe` [Nothing]
    map piProblem g
      `shouldSatisfy` all (maybe False ("has no type" `T.isInfixOf`))

  it "resolves a type-less legacy section (no rewrite needed)" $ do
    let rows = providerInstances (cfgWith [("openai-compat", sec Nothing Nothing Nothing)])
        g = [ r | r <- rows, piName r == "openai-compat" ]
    map (fmap typeId . piType) g `shouldBe` [Just "openai-compat"]
    map piProblem g `shouldBe` [Nothing]

  it "reports an invalid or reserved section name and never resolves it" $ do
    let rows = providerInstances (cfgWith
          [ ("we ird", sec (Just "anthropic") Nothing Nothing)
          , ("default", sec (Just "anthropic") Nothing Nothing)
          ])
        weird = [ r | r <- rows, piName r == "we ird" ]
        def = [ r | r <- rows, piName r == "default" ]
    map piNameValid weird `shouldBe` [Nothing]
    map piNameValid def `shouldBe` [Nothing]
    map piProblem weird `shouldSatisfy` all (maybe False ("not a valid instance name" `T.isInfixOf`))
    map piProblem def `shouldSatisfy` all (maybe False ("is reserved" `T.isInfixOf`))

  it "reports a section naming a type id with a different type (one row per name)" $ do
    let rows = providerInstances (cfgWith [("anthropic", sec (Just "ollama") Nothing Nothing)])
        named = [ r | r <- rows, piName r == "anthropic" ]
    length named `shouldBe` 1
    map (fmap typeId . piType) named `shouldBe` [Just "ollama"]
    map piProblem named
      `shouldSatisfy` all (maybe False ("is not a ollama instance" `T.isInfixOf`))

  it "exposes the type catalog and lookups" $ do
    map typeId providerTypes `shouldBe` ["anthropic", "ollama", "openai-compat"]
    map (fmap typeId . providerTypeForId) ["anthropic", " Ollama ", "OPENAI-COMPAT"]
      `shouldBe` [Just "anthropic", Just "ollama", Just "openai-compat"]
    providerTypeForId "nope" `shouldBe` Nothing
    legacyTypeIds `shouldBe` ["anthropic", "ollama", "openai-compat"]

  it "keeps every instance's config distinct (two openai-compat rows)" $ do
    let cfg = cfgWith
          [ ("local", sec (Just "openai-compat") (Just "http://localhost:8000/v1") (Just "qwen"))
          , ("groq", sec (Just "openai-compat") (Just "https://groq.example/v1") (Just "llama"))
          ]
        rows = [ r | r <- providerInstances cfg, piName r `elem` ["local", "groq"] ]
    -- extras are ordered by name
    map piName rows `shouldBe` ["groq", "local"]
    map (pcBaseUrl . piConfig) rows
      `shouldBe` [Just "https://groq.example/v1", Just "http://localhost:8000/v1"]
    map (pcDefaultModel . piConfig) rows `shouldBe` [Just "llama", Just "qwen"]

-- | The module's single exported spec.
spec :: Spec
spec = specMain >> instanceSpec >> instanceBehaviourSpec

-- ---------------------------------------------------------------------------
-- Instances: credentials, resolution, status (#273 WU-2)
-- ---------------------------------------------------------------------------

-- | Wrap a vault so every credential access is recorded (the "no vault access"
-- assertions need call counts, not just outcomes).
recordingVault :: VaultHandle -> IORef [T.Text] -> VaultHandle
recordingVault vh log' = vh
  { vhGet    = \k -> modifyIORef' log' (("get:" <> k) :) >> vhGet vh k
  , vhPut    = \k v -> modifyIORef' log' (("put:" <> k) :) >> vhPut vh k v
  , vhDelete = \k -> modifyIORef' log' (("del:" <> k) :) >> vhDelete vh k
  }

-- | The instance row for a name in a config (fails the test when absent).
instOf :: RuntimeConfig -> T.Text -> ProviderInstance
instOf cfg n = case findInstance cfg n of
  Just i  -> i
  Nothing -> error ("no instance " <> T.unpack n)

instanceBehaviourSpec :: Spec
instanceBehaviourSpec = describe "provider instances (#273 WU-2)" $ do

  describe "instanceCredentials" $ do
    it "keeps the legacy keys for a type-named instance" $ do
      let i = instOf defaultRuntimeConfig "anthropic"
      fmap pcApiKeyName (instanceCredentials i) `shouldBe` Just "ANTHROPIC_API_KEY"
      fmap pcOauthKeyName (instanceCredentials i) `shouldBe` Just (Just "ANTHROPIC_OAUTH_TOKENS")
      let g = instOf defaultRuntimeConfig "openai-compat"
      fmap pcApiKeyName (instanceCredentials g) `shouldBe` Just "OPENAI_COMPAT_API_KEY"
    it "derives prefixed keys for a named instance" $ do
      let cfg = cfgWith [("work", sec (Just "anthropic") Nothing Nothing)]
      fmap pcApiKeyName (instanceCredentials (instOf cfg "work"))
        `shouldBe` Just "PROVIDER_APIKEY_WORK"
      fmap pcOauthKeyName (instanceCredentials (instOf cfg "work"))
        `shouldBe` Just (Just "PROVIDER_OAUTH_WORK")
    it "gives a non-anthropic instance no OAuth key" $ do
      let cfg = cfgWith [("local", sec (Just "openai-compat") (Just "http://127.0.0.1:9/v1") Nothing)]
      fmap pcOauthKeyName (instanceCredentials (instOf cfg "local")) `shouldBe` Just Nothing
    it "refuses credentials for problem rows (invalid name, unknown type, mismatch)" $ do
      let cfg = cfgWith
            [ ("we ird", sec (Just "anthropic") Nothing Nothing)
            , ("typo", sec (Just "anthorpic") Nothing Nothing)
            , ("anthropic", sec (Just "ollama") Nothing Nothing)
            ]
      map (instanceCredentials . instOf cfg) ["we ird", "typo", "anthropic"]
        `shouldBe` [Nothing, Nothing, Nothing]

  describe "per-instance base URL" $ do
    it "keeps two instances of one type on their own URLs" $ do
      let cfg = cfgWith
            [ ("local", sec (Just "openai-compat") (Just "http://127.0.0.1:8000/v1") Nothing)
            , ("groq", sec (Just "openai-compat") (Just "https://groq.example/v1") Nothing)
            ]
      providerBaseUrlForInstance cfg (instOf cfg "local")
        `shouldBe` Right "http://127.0.0.1:8000/v1"
      providerBaseUrlForInstance cfg (instOf cfg "groq")
        `shouldBe` Right "https://groq.example/v1"
    it "requires a base URL for the generic row and names the instance" $ do
      let cfg = cfgWith [("local", sec (Just "openai-compat") Nothing Nothing)]
      case providerBaseUrlForInstance cfg (instOf cfg "local") of
        Left e -> do
          e `shouldSatisfy` ("local needs a base URL" `T.isInfixOf`)
          e `shouldSatisfy` ("/provider add openai-compat local" `T.isInfixOf`)
        Right u -> expectationFailure ("expected Left, got " <> T.unpack u)
    it "reports a misconfigured row" $ do
      let cfg = cfgWith [("typo", sec (Just "anthorpic") Nothing Nothing)]
      case providerBaseUrlForInstance cfg (instOf cfg "typo") of
        Left e -> e `shouldSatisfy` ("is misconfigured" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

  describe "instanceAuthStatus / configuredInstances" $ do
    it "walks none -> keyless -> api-key for one instance while another stays none" $ do
      let cfg = cfgWith
            [ ("local", sec (Just "openai-compat") (Just "http://127.0.0.1:9/v1") Nothing)
            , ("groq", sec (Just "openai-compat") (Just "https://groq.example/v1") Nothing)
            ]
      vh <- makeFakeVault [("PROVIDER_APIKEY_LOCAL", "sk-local")]
      local <- instanceAuthStatus (Just vh) cfg (instOf cfg "local")
      groq <- instanceAuthStatus (Just vh) cfg (instOf cfg "groq")
      local `shouldBe` "api-key"
      groq `shouldBe` "keyless"
      configured <- configuredInstances (Just vh) cfg
      map piName configured `shouldSatisfy` elem "local"
    it "distinguishes a local from a cloud Ollama instance" $ do
      let cfg = cfgWith
            [ ("desk", sec (Just "ollama") (Just "http://localhost:11434") Nothing)
            , ("cloud", sec (Just "ollama") (Just "https://ollama.com") Nothing)
            ]
      vh <- makeFakeVault []
      desk <- instanceAuthStatus (Just vh) cfg (instOf cfg "desk")
      cloud <- instanceAuthStatus (Just vh) cfg (instOf cfg "cloud")
      desk `shouldBe` "keyless"
      cloud `shouldBe` "none"
      configured <- configuredInstances (Just vh) cfg
      map piName configured `shouldSatisfy` elem "desk"
      map piName configured `shouldNotSatisfy` elem "cloud"
    it "reports a problem row as none" $ do
      let cfg = cfgWith [("typo", sec (Just "anthorpic") Nothing Nothing)]
      vh <- makeFakeVault []
      s <- instanceAuthStatus (Just vh) cfg (instOf cfg "typo")
      s `shouldBe` "none"

  describe "zero vault access for problem rows" $ do
    it "touches the vault for none of an invalid-name, unknown-type or mismatch row" $ do
      let cfg = cfgWith
            [ ("we ird", sec (Just "anthropic") Nothing Nothing)
            , ("typo", sec (Just "anthorpic") Nothing Nothing)
            , ("anthropic", sec (Just "ollama") Nothing Nothing)
            ]
      entries <- newIORef []
      vh <- makeFakeVault []
      let spy = recordingVault vh entries
      mapM_ (\n -> do
        _ <- instanceAuthStatus (Just spy) cfg (instOf cfg n)
        _ <- configuredInstances (Just spy) cfg
        _ <- resolveInstance (Just spy) mgrRef cfg (instOf cfg n) (ModelId "m") counter
        pure ()) ["we ird", "typo", "anthropic"]
      readIORef entries `shouldReturn` []

  describe "resolveInstance" $ do
    it "resolves a keyless generic instance with no vault at all" $ do
      let cfg = cfgWith [("local", sec (Just "openai-compat") (Just "http://127.0.0.1:9/v1") Nothing)]
      shouldResolve =<< resolveInstance Nothing mgrRef cfg (instOf cfg "local") (ModelId "m") counter
    it "refuses a problem row with its problem text" $ do
      let cfg = cfgWith [("typo", sec (Just "anthorpic") Nothing Nothing)]
      r <- resolveInstance Nothing mgrRef cfg (instOf cfg "typo") (ModelId "m") counter
      case r of
        Left e  -> e `shouldSatisfy` ("is misconfigured" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"
    it "reads each instance's own key (keyed generic row)" $ do
      let cfg = cfgWith
            [ ("a", sec (Just "openai-compat") (Just "http://127.0.0.1:9/v1") Nothing)
            , ("b", sec (Just "openai-compat") (Just "http://127.0.0.1:9/v1") Nothing)
            ]
      entries <- newIORef []
      vh <- makeFakeVault [("PROVIDER_APIKEY_A", "sk-a")]
      let spy = recordingVault vh entries
      _ <- resolveInstance (Just spy) mgrRef cfg (instOf cfg "a") (ModelId "m") counter
      _ <- resolveInstance (Just spy) mgrRef cfg (instOf cfg "b") (ModelId "m") counter
      gets <- readIORef entries
      gets `shouldSatisfy` elem "get:PROVIDER_APIKEY_A"

  describe "OAuth keys per instance" $ do
    it "reads and writes the instance's own OAuth key, never the legacy literal" $ do
      let cfg = cfgWith [("work", sec (Just "anthropic") Nothing Nothing)]
          work = instOf cfg "work"
      entries <- newIORef []
      vh <- makeFakeVault [("PROVIDER_OAUTH_WORK", "{}")]
      let spy = recordingVault vh entries
      _ <- resolveInstance (Just spy) mgrRef cfg work (ModelId "m") counter
      gets <- readIORef entries
      gets `shouldSatisfy` elem "get:PROVIDER_OAUTH_WORK"
      gets `shouldNotSatisfy` elem "get:ANTHROPIC_OAUTH_TOKENS"

  describe "resolveDefaultModelFor" $ do
    it "resolves section -> type -> built-in per instance" $ do
      let cfg = cfgWith
            [ ("work", sec (Just "anthropic") Nothing (Just "claude-haiku-4-5"))
            , ("local", sec (Just "openai-compat") (Just "http://127.0.0.1:9/v1") Nothing)
            ]
      resolveDefaultModelFor cfg "work"  `shouldBe` Just (ModelId "claude-haiku-4-5")
      resolveDefaultModelFor cfg "local" `shouldBe` Nothing
      resolveDefaultModelFor defaultRuntimeConfig "ollama"
        `shouldBe` Just (ModelId "llama3.2")
      resolveDefaultModelFor defaultRuntimeConfig "nope" `shouldBe` Nothing

  describe "instanceLabelList" $
    it "lists instance names (both of a type)" $ do
      let cfg = cfgWith
            [ ("work", sec (Just "anthropic") Nothing Nothing)
            , ("local", sec (Just "openai-compat") (Just "http://127.0.0.1:9/v1") Nothing)
            ]
      instanceLabelList cfg
        `shouldBe` "anthropic, ollama, openai-compat, local, work"

  describe "catalogProblems (#273 additions)" $ do
    it "rejects a catalog id that is not a valid instance name or is a built-in id" $ do
      catalogProblems [presetSpec { ocsId = "Acme" }]
        `shouldSatisfy` any ("not a valid instance name" `T.isInfixOf`)
      catalogProblems [presetSpec { ocsId = "ollama" }]
        `shouldSatisfy` any ("collides with a built-in provider type" `T.isInfixOf`)
    it "rejects a vault key using the PROVIDER_ prefix or a legacy key" $ do
      catalogProblems [presetSpec { ocsVaultKey = "PROVIDER_APIKEY_X" }]
        `shouldSatisfy` any ("must not use the PROVIDER_ prefix" `T.isInfixOf`)
      catalogProblems [presetSpec { ocsVaultKey = "ANTHROPIC_API_KEY" }]
        `shouldSatisfy` any ("collides with a legacy provider key" `T.isInfixOf`)

-- | A manager for the resolution tests that never touches the network.
mgrRef :: Manager
mgrRef = unsafePerformIO (newManager defaultManagerSettings)
{-# NOINLINE mgrRef #-}
