{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.RegistrySpec (spec) where

import Data.Either (isLeft)
import Data.Maybe (isJust)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Network.HTTP.Client (Manager, defaultManagerSettings, newManager)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec

import Seal.Config.File
  ( ProviderConfig (..), RuntimeConfig (..), defaultRuntimeConfig )
import Seal.Core.Types (ModelId (..))
import Seal.Providers.Class
  ( CompletionResponse (..), Provider (..), SomeProvider (..)
  , StopReason (..), Usage (..) )
import Seal.Providers.OpenAICompat (ContentStyle (..), OpenAICompatSpec (..), WireFormat (..))
import Seal.Providers.Registry
  ( catalogProblems
  , completeSome
  , ProviderCredentials (..)
  , ProviderType (..)
  , ProviderFamily (..)
  , providerFamily
  , familyKey
  , familyLabel
  , openAICompatSpecFor
  , genericOpenAI
  , openRouter
  , openRouterBaseUrl
  , openRouterDefaultModel
  , openAICompatSpecs
  , ProviderInstance (..)
  , configuredInstances
  , findInstance
  , instanceAuthStatus
  , instanceCredentials
  , instanceLabelList
  , resolveDefaultModelFor
  , resolveInstance
  , providerBaseUrlForInstance
  , legacyTypeIds
  , providerInstances
  , providerTypeForId
  , providerTypes
  , typeId
  , listSome
  )
import Seal.TestHelpers.FakeVault (makeFakeVault)
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

contentMemo :: IORef (Map.Map T.Text WireFormat)
contentMemo = unsafePerformIO (newIORef Map.empty)
{-# NOINLINE contentMemo #-}

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


specMain :: Spec
specMain = describe "Seal.Providers.Registry" $ do

  describe "completeSome / listSome" $ do
    it "passes the request through to the wrapped provider" $ do
      let resp = CompletionResponse [] StopEnd (Usage 1 2)
      r <- completeSome (SomeProvider (Canned (Right resp))) (error "request not forced")
      r `shouldBe` Right resp

    it "passes listModels through the wrapped provider" $ do
      r <- listSome (SomeProvider (CannedModels [ModelId "m1", ModelId "m2"]))
      r `shouldBe` Right [ModelId "m1", ModelId "m2"]


-- ---------------------------------------------------------------------------
-- Provider instances (#273 WU-1)
-- ---------------------------------------------------------------------------

-- | A section in the config map.
sec :: Maybe T.Text -> Maybe T.Text -> Maybe T.Text -> ProviderConfig
sec ty url model = ProviderConfig { pcType = ty, pcBaseUrl = url, pcDefaultModel = model, pcContentStyle = Nothing }

cfgWith :: [(T.Text, ProviderConfig)] -> RuntimeConfig
cfgWith xs = defaultRuntimeConfig { rcProviders = Map.fromList xs }

instanceSpec :: Spec
instanceSpec = describe "providerInstances (#273)" $ do

  it "synthesizes one row per type for an empty config" $ do
    let rows = providerInstances defaultRuntimeConfig
    map piName rows `shouldBe` ["anthropic", "ollama", "openai", "openrouter"]
    map piHasSection rows `shouldBe` [False, False, False, False]
    map piProblem rows `shouldBe` [Nothing, Nothing, Nothing, Nothing]
    map (fmap typeId . piType) rows
      `shouldBe` [Just "anthropic", Just "ollama", Just "openai", Just "openrouter"]
    map piTypeId rows `shouldBe` [Nothing, Nothing, Nothing, Nothing]
    map (isJust . piNameValid) rows `shouldBe` [True, True, True, True]

  it "keeps catalog order when a section claims a type name" $ do
    let rows = providerInstances (cfgWith [("anthropic", sec Nothing Nothing Nothing)])
    map piName rows `shouldBe` ["anthropic", "ollama", "openai", "openrouter"]
    map piHasSection (take 1 rows) `shouldBe` [True]

  it "appends explicit extra instances after the type rows, by name" $ do
    let cfg = cfgWith
          [ ("groq", sec (Just "openai") (Just "https://groq.example/v1") (Just "m1"))
          , ("aaa", sec (Just "openai") (Just "http://localhost:8000/v1") Nothing)
          ]
        rows = providerInstances cfg
    map piName rows `shouldBe` ["anthropic", "ollama", "openai", "openrouter", "aaa", "groq"]
    map (fmap typeId . piType) (drop 4 rows) `shouldBe` [Just "openai", Just "openai"]
    -- each instance keeps its OWN section
    map (pcBaseUrl . piConfig) (drop 4 rows)
      `shouldBe` [Just "http://localhost:8000/v1", Just "https://groq.example/v1"]

  it "resolves a typed section, case-insensitively, keeping the raw text for display" $ do
    let rows = providerInstances (cfgWith [("work", sec (Just "OpenAI") Nothing Nothing)])
        work = [ r | r <- rows, piName r == "work" ]
    map (fmap typeId . piType) work `shouldBe` [Just "openai"]
    map piProblem work `shouldBe` [Nothing]

  it "treats an empty type as absent (back-compat fallback)" $ do
    let rows = providerInstances (cfgWith [("ollama", sec (Just "") (Just "https://ollama.com") Nothing)])
        o = [ r | r <- rows, piName r == "ollama" ]
    map (fmap typeId . piType) o `shouldBe` [Just "ollama"]
    map piProblem o `shouldBe` [Nothing]

  it "parses content_style into the row, defaulting an absent value to auto" $ do
    let cfg = cfgWith
          [ ("magnitude", ProviderConfig { pcType = Just "openai"
                                         , pcBaseUrl = Nothing
                                         , pcDefaultModel = Nothing
                                         , pcContentStyle = Just "string" })
          , ("work", sec (Just "openai") Nothing Nothing)
          ]
        rows = providerInstances cfg
        m = [ r | r <- rows, piName r == "magnitude" ]
        w = [ r | r <- rows, piName r == "work" ]
    map piContentStyle m `shouldBe` [Right StyleString]
    map piProblem m `shouldBe` [Nothing]
    map piContentStyle w `shouldBe` [Right StyleAuto]

  it "reports an invalid content_style as a problem row" $ do
    let rows = providerInstances (cfgWith
          [ ("groq", ProviderConfig { pcType = Just "openai"
                                    , pcBaseUrl = Nothing
                                    , pcDefaultModel = Nothing
                                    , pcContentStyle = Just "sometimes" }) ])
        g = [ r | r <- rows, piName r == "groq" ]
    map piContentStyle g `shouldSatisfy` all isLeft
    map piProblem g
      `shouldSatisfy` all (maybe False ("content_style must be one of" `T.isInfixOf`))

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
    let rows = providerInstances (cfgWith [("openrouter", sec Nothing Nothing Nothing)])
        g = [ r | r <- rows, piName r == "openrouter" ]
    map (fmap typeId . piType) g `shouldBe` [Just "openrouter"]
    map piProblem g `shouldBe` [Nothing]

  it "reports a type-less openai section (not a legacy id) as a problem row" $ do
    let rows = providerInstances (cfgWith [("openai", sec Nothing Nothing Nothing)])
        g = [ r | r <- rows, piName r == "openai" ]
    map piType g `shouldBe` [Nothing]
    map piProblem g
      `shouldSatisfy` all (maybe False ("has no type" `T.isInfixOf`))

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
    map typeId providerTypes `shouldBe` ["anthropic", "ollama", "openai", "openrouter"]
    map (fmap typeId . providerTypeForId) ["anthropic", " Ollama ", "OPENAI"]
      `shouldBe` [Just "anthropic", Just "ollama", Just "openai"]
    providerTypeForId "nope" `shouldBe` Nothing
    legacyTypeIds `shouldBe` ["anthropic", "ollama", "openrouter"]

  it "keeps every instance's config distinct (two openai rows)" $ do
    let cfg = cfgWith
          [ ("local", sec (Just "openai") (Just "http://localhost:8000/v1") (Just "qwen"))
          , ("groq", sec (Just "openai") (Just "https://groq.example/v1") (Just "llama"))
          ]
        rows = [ r | r <- providerInstances cfg, piName r `elem` ["local", "groq"] ]
    -- extras are ordered by name
    map piName rows `shouldBe` ["groq", "local"]
    map (pcBaseUrl . piConfig) rows
      `shouldBe` [Just "https://groq.example/v1", Just "http://localhost:8000/v1"]
    map (pcDefaultModel . piConfig) rows `shouldBe` [Just "llama", Just "qwen"]

-- | The module's single exported spec.
spec :: Spec
spec = specMain >> instanceSpec >> instanceBehaviourSpec >> familySpec

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
      let g = instOf defaultRuntimeConfig "openai"
      fmap pcApiKeyName (instanceCredentials g) `shouldBe` Just "OPENAI_API_KEY"
    it "derives prefixed keys for a named instance" $ do
      let cfg = cfgWith [("work", sec (Just "anthropic") Nothing Nothing)]
      fmap pcApiKeyName (instanceCredentials (instOf cfg "work"))
        `shouldBe` Just "PROVIDER_APIKEY_WORK"
      fmap pcOauthKeyName (instanceCredentials (instOf cfg "work"))
        `shouldBe` Just (Just "PROVIDER_OAUTH_WORK")
    it "gives a non-anthropic instance no OAuth key" $ do
      let cfg = cfgWith [("local", sec (Just "openai") (Just "http://127.0.0.1:9/v1") Nothing)]
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
            [ ("local", sec (Just "openai") (Just "http://127.0.0.1:8000/v1") Nothing)
            , ("groq", sec (Just "openai") (Just "https://groq.example/v1") Nothing)
            ]
      providerBaseUrlForInstance cfg (instOf cfg "local")
        `shouldBe` Right "http://127.0.0.1:8000/v1"
      providerBaseUrlForInstance cfg (instOf cfg "groq")
        `shouldBe` Right "https://groq.example/v1"
    it "requires a base URL for the generic row and names the instance" $ do
      let cfg = cfgWith [("local", sec (Just "openai") Nothing Nothing)]
      case providerBaseUrlForInstance cfg (instOf cfg "local") of
        Left e -> do
          e `shouldSatisfy` ("local needs a base URL" `T.isInfixOf`)
          e `shouldSatisfy` ("/provider add openai local" `T.isInfixOf`)
        Right u -> expectationFailure ("expected Left, got " <> T.unpack u)
    it "reports a misconfigured row" $ do
      let cfg = cfgWith [("typo", sec (Just "anthorpic") Nothing Nothing)]
      case providerBaseUrlForInstance cfg (instOf cfg "typo") of
        Left e -> e `shouldSatisfy` ("is misconfigured" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

  describe "instanceAuthStatus / configuredInstances" $ do
    it "walks none -> keyless -> api-key for one instance while another stays none" $ do
      let cfg = cfgWith
            [ ("local", sec (Just "openai") (Just "http://127.0.0.1:9/v1") Nothing)
            , ("groq", sec (Just "openai") (Just "https://groq.example/v1") Nothing)
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
        _ <- resolveInstance (Just spy) mgrRef cfg (instOf cfg n) (ModelId "m") counter contentMemo
        pure ()) ["we ird", "typo", "anthropic"]
      gets <- readIORef entries
      gets `shouldSatisfy` all (T.isInfixOf "OPENROUTER_API_KEY")

  describe "resolveInstance" $ do
    it "resolves a keyless generic instance with no vault at all" $ do
      let cfg = cfgWith [("local", sec (Just "openai") (Just "http://127.0.0.1:9/v1") Nothing)]
      shouldResolve =<< resolveInstance Nothing mgrRef cfg (instOf cfg "local") (ModelId "m") counter contentMemo
    it "refuses a problem row with its problem text" $ do
      let cfg = cfgWith [("typo", sec (Just "anthorpic") Nothing Nothing)]
      r <- resolveInstance Nothing mgrRef cfg (instOf cfg "typo") (ModelId "m") counter contentMemo
      case r of
        Left e  -> e `shouldSatisfy` ("is misconfigured" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"
    it "refuses an invalid content_style row with its problem text" $ do
      let cfg = cfgWith
            [ ("groq", ProviderConfig { pcType = Just "openai"
                                      , pcBaseUrl = Nothing
                                      , pcDefaultModel = Nothing
                                      , pcContentStyle = Just "sometimes" }) ]
      r <- resolveInstance Nothing mgrRef cfg (instOf cfg "groq") (ModelId "m") counter contentMemo
      case r of
        Left e  -> e `shouldSatisfy` ("content_style must be one of" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"
    it "reads each instance's own key (keyed generic row)" $ do
      let cfg = cfgWith
            [ ("a", sec (Just "openai") (Just "http://127.0.0.1:9/v1") Nothing)
            , ("b", sec (Just "openai") (Just "http://127.0.0.1:9/v1") Nothing)
            ]
      entries <- newIORef []
      vh <- makeFakeVault [("PROVIDER_APIKEY_A", "sk-a")]
      let spy = recordingVault vh entries
      _ <- resolveInstance (Just spy) mgrRef cfg (instOf cfg "a") (ModelId "m") counter contentMemo
      _ <- resolveInstance (Just spy) mgrRef cfg (instOf cfg "b") (ModelId "m") counter contentMemo
      gets <- readIORef entries
      gets `shouldSatisfy` elem "get:PROVIDER_APIKEY_A"

  describe "OAuth keys per instance" $ do
    it "reads and writes the instance's own OAuth key, never the legacy literal" $ do
      let cfg = cfgWith [("work", sec (Just "anthropic") Nothing Nothing)]
          work = instOf cfg "work"
      entries <- newIORef []
      vh <- makeFakeVault [("PROVIDER_OAUTH_WORK", "{}")]
      let spy = recordingVault vh entries
      _ <- resolveInstance (Just spy) mgrRef cfg work (ModelId "m") counter contentMemo
      gets <- readIORef entries
      gets `shouldSatisfy` elem "get:PROVIDER_OAUTH_WORK"
      gets `shouldNotSatisfy` elem "get:ANTHROPIC_OAUTH_TOKENS"

  describe "resolveDefaultModelFor" $ do
    it "resolves section -> type -> built-in per instance" $ do
      let cfg = cfgWith
            [ ("work", sec (Just "anthropic") Nothing (Just "claude-haiku-4-5"))
            , ("local", sec (Just "openai") (Just "http://127.0.0.1:9/v1") Nothing)
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
            , ("local", sec (Just "openai") (Just "http://127.0.0.1:9/v1") Nothing)
            ]
      instanceLabelList cfg
        `shouldBe` "anthropic, ollama, openai, openrouter, local, work"

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

-- | Provider families, the two shipped rows, and the OpenRouter URL policy.
familySpec :: Spec
familySpec = describe "provider families and catalog" $ do
  it "maps every provider to its family and exposes the wire slug/label" $ do
    let ts = [ AnthropicType, OllamaType
             , OpenAICompatType genericOpenAI, OpenAICompatType openRouter ]
    map providerFamily ts
      `shouldBe` [AnthropicFamily, OllamaFamily, OpenAIFamily, OpenAIFamily]
    map (familyKey . providerFamily) ts
      `shouldBe` ["anthropic", "ollama", "openai", "openai"]
    map (familyLabel . providerFamily) ts
      `shouldBe` ["Anthropic API", "Ollama API", "OpenAI API", "OpenAI API"]
    openAICompatSpecFor (OpenAICompatType openRouter) `shouldBe` Just openRouter
    openAICompatSpecFor AnthropicType `shouldBe` Nothing

  it "ships the generic OpenAI API and OpenRouter rows" $ do
    map ocsId openAICompatSpecs `shouldBe` ["openai", "openrouter"]
    ocsDisplayName genericOpenAI `shouldBe` "OpenAI API"
    ocsDisplayName openRouter `shouldBe` "OpenRouter"
    ocsVaultKey genericOpenAI `shouldBe` "OPENAI_API_KEY"
    ocsVaultKey openRouter `shouldBe` "OPENROUTER_API_KEY"
    ocsBuiltinBaseUrl genericOpenAI `shouldBe` Nothing
    ocsBuiltinBaseUrl openRouter `shouldBe` Just openRouterBaseUrl
    ocsDefaultModel openRouter `shouldBe` Just (ModelId openRouterDefaultModel)
    ocsKeyRequired openRouter `shouldBe` True
    catalogProblems openAICompatSpecs `shouldBe` []

  it "rejects a duplicate vault key across catalog rows" $
    catalogProblems [genericOpenAI, openRouter { ocsVaultKey = "OPENAI_API_KEY" }]
      `shouldSatisfy` any ("duplicate vault key" `T.isInfixOf`)

  it "resolves OpenRouter to its fixed URL even with a stored base_url" $ do
    let cfg = cfgWith
          [("openrouter", sec (Just "openrouter") (Just "https://proxy.example/v1") (Just "m"))]
    providerBaseUrlForInstance cfg (instOf cfg "openrouter")
      `shouldBe` Right openRouterBaseUrl
