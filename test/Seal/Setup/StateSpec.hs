{-# LANGUAGE OverloadedStrings #-}
-- | WU2 tests (plan rev 3, tests 1–18): the setup state model.
--
-- The rows under test are design §5.1 (V0–V6) and §5.2 (P1–P4). Two
-- properties matter more than any individual row:
--
-- * @vsLocked@ is never a readiness signal on its own — a @per_access@ vault
--   reports locked forever and must still be Ready (test 6);
-- * a YubiKey vault never probes the vault for provider credentials, because
--   that would mean a physical touch just to render the wizard (test 14).
module Seal.Setup.StateSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, elements, forAll, ioProperty, oneof)

import Seal.Config.File
  ( ProviderConfig (..), RuntimeConfig (..), defaultRuntimeConfig )
import Seal.Config.Paths (SealPaths (..))
import Seal.Config.Security (SecurityConfig (..), defaultSecurityConfig)
import Seal.Providers.Registry (KnownProvider (..))
import Seal.Security.Vault (VaultHandle)
import Seal.Setup.State
  ( ProviderCard (..), SetupInputs (..), SetupState (..), SetupStep (..)
  , StepStatus (..), deriveSetupState, emptySetupInputs )
import Seal.TestHelpers.FakeVault (makeFakeVault, makeLockedVault)

spec :: Spec
spec = describe "Seal.Setup.State" $ do

  describe "vault step" $ do

    it "an empty install reports both steps pending" $ do
      state <- deriveSetupState (emptySetupInputs fakePaths)
      ssRequiredComplete state `shouldBe` False
      stepStatuses state `shouldBe` [StepPending, StepPending]
      actionsOf "vault" state `shouldBe` ["create"]

    it "a working vault is ready" $ do
      handle <- makeFakeVault []
      state <- deriveSetupState (workingVault handle)
      stStatus (vaultStep state) `shouldBe` StepReady
      -- V6's detail names the key type, not a secret count.
      stDetail (vaultStep state) `shouldBe` Just "Key type: `x25519`."
      ssRequiredComplete state `shouldBe` False  -- the provider step is not done

    it "an orphan vault file blocks" $ do
      let inputs = (emptySetupInputs fakePaths) { siVaultFileExists = True }
      state <- deriveSetupState inputs
      stStatus (vaultStep state) `shouldBe` StepBlocked
      stActions (vaultStep state) `shouldBe` ["recheck"]
      let detail = fromMaybe "" (stDetail (vaultStep state))
      detail `shouldSatisfy` T.isInfixOf "~/.seal/config/vault/vault.age"
      -- Path-free: the absolute home never appears in a detail.
      detail `shouldSatisfy` (not . T.isInfixOf "/home/alice")
      -- ...and it must not tell the operator to delete anything.
      detail `shouldSatisfy` (not . T.isInfixOf "rm ")

    it "an unreadable identity blocks even when a handle exists" $ do
      handle <- makeFakeVault []
      let inputs = (workingVault handle) { siIdentityReadable = Just False }
      state <- deriveSetupState inputs
      stStatus (vaultStep state) `shouldBe` StepBlocked
      stActions (vaultStep state) `shouldBe` ["recheck"]
      fromMaybe "" (stDetail (vaultStep state))
        `shouldSatisfy` T.isInfixOf "default.identity"

    it "startup-mode locked is blocked" $ do
      handle <- makeLockedVault
      state <- deriveSetupState (withUnlock "startup" (workingVault handle))
      stStatus (vaultStep state) `shouldBe` StepBlocked
      stActions (vaultStep state) `shouldBe` ["reopen", "recheck"]

    it "on_demand and per_access are ready" $ do
      unlocked <- makeFakeVault []
      lockedLooking <- makeLockedVault
      onDemand <- deriveSetupState (withUnlock "on_demand" (workingVault unlocked))
      stStatus (vaultStep onDemand) `shouldBe` StepReady
      -- per_access never populates the cache, so vsLocked is True forever.
      -- Readiness must come from the mode, not from that flag.
      perAccess <- deriveSetupState (withUnlock "per_access" (workingVault lockedLooking))
      stStatus (vaultStep perAccess) `shouldBe` StepReady

    it "configured-but-not-open offers reopen" $ do
      let inputs = configuredOnDisk { siHandle = Nothing }
      state <- deriveSetupState inputs
      stStatus (vaultStep state) `shouldBe` StepBlocked
      stActions (vaultStep state) `shouldBe` ["reopen"]

    it "a recorded key with no vault file offers resume" $ do
      let inputs = configuredOnDisk
            { siHandle = Nothing, siVaultFileExists = False }
      state <- deriveSetupState inputs
      stStatus (vaultStep state) `shouldBe` StepPending
      stActions (vaultStep state) `shouldBe` ["resume"]

    it "an undecodable security.toml degrades instead of throwing" $ do
      state <- deriveSetupState (emptySetupInputs fakePaths)
        { siSecurityProblem = Just "line 3: expected a value" }
      stStatus (vaultStep state) `shouldBe` StepBlocked
      stActions (vaultStep state) `shouldBe` ["recheck"]
      let detail = fromMaybe "" (stDetail (vaultStep state))
      detail `shouldSatisfy` T.isInfixOf "could not be parsed"
      detail `shouldSatisfy` T.isInfixOf "line 3: expected a value"
      detail `shouldSatisfy` (not . T.isInfixOf "/home/alice")

    it "missing config files degrade" $ do
      -- The caller passes defaults for absent files; nothing may throw and the
      -- provider cards must still be emitted.
      state <- deriveSetupState (emptySetupInputs fakePaths)
      map pcId (ssProviders state)
        `shouldBe` ["anthropic", "ollama", "openrouter", "openai"]
      map pcConfigured (ssProviders state) `shouldBe` [False, False, False, False]
      -- Branding is a display name, not a mechanical capitalise.
      map pcLabel (ssProviders state)
        `shouldBe` ["Anthropic", "Ollama", "OpenRouter", "OpenAI-compatible"]
      -- Only the generic endpoint needs a URL from the operator.
      map pcRequiresBaseUrl (ssProviders state)
        `shouldBe` [False, False, False, True]

  describe "provider step" $ do

    it "provider: default + credential is ready" $ do
      state <- deriveSetupState
        (emptySetupInputs fakePaths)
          { siRuntime = defaultRuntimeConfig { rcDefaultProvider = Just "anthropic" }
          , siConfiguredProviders = pure [AnthropicProvider] }
      stStatus (providerStep state) `shouldBe` StepReady
      stDetail (providerStep state) `shouldBe` Just "anthropic · claude-opus-4-8"

    it "provider: keyless ollama is ready" $ do
      state <- deriveSetupState
        (emptySetupInputs fakePaths)
          { siRuntime = defaultRuntimeConfig { rcDefaultProvider = Just "ollama" }
          , siConfiguredProviders = pure [OllamaProvider] }
      stStatus (providerStep state) `shouldBe` StepReady
      fromMaybe "" (stDetail (providerStep state)) `shouldSatisfy` T.isInfixOf "llama3.2"

    it "provider: default without credential is pending, naming the provider" $ do
      state <- deriveSetupState
        (emptySetupInputs fakePaths)
          { siRuntime = defaultRuntimeConfig { rcDefaultProvider = Just "anthropic" }
          , siConfiguredProviders = pure [] }
      stStatus (providerStep state) `shouldBe` StepPending
      fromMaybe "" (stDetail (providerStep state))
        `shouldSatisfy` T.isInfixOf "anthropic"

    it "provider: a configured provider with no default is pending" $ do
      state <- deriveSetupState
        (emptySetupInputs fakePaths)
          { siConfiguredProviders = pure [OpenRouterProvider] }
      stStatus (providerStep state) `shouldBe` StepPending
      fromMaybe "" (stDetail (providerStep state))
        `shouldSatisfy` T.isInfixOf "Choose which provider"

    it "provider: nothing configured is pending" $ do
      state <- deriveSetupState (emptySetupInputs fakePaths)
      stStatus (providerStep state) `shouldBe` StepPending
      fromMaybe "" (stDetail (providerStep state))
        `shouldSatisfy` T.isInfixOf "Add an LLM provider"

    it "a yubikey vault never probes the vault for providers" $ do
      let yubiSecurity = defaultSecurityConfig
            { scVaultRecipient = Just testRecipient
            , scVaultIdentity  = Just "/home/alice/.seal/keys/default.yubikey.txt"
            , scVaultKeyType   = Just "yubikey"
            }
          inputs = (emptySetupInputs fakePaths)
            { siSecurity = yubiSecurity
            , siVaultFileExists = True
            , siIdentityReadable = Just True
            , siRuntime = defaultRuntimeConfig
                { rcDefaultProvider = Just "anthropic"
                , rcProviders = Map.fromList [("anthropic", ProviderConfig Nothing Nothing)]
                }
            -- Reaching this would decrypt, i.e. ask for a touch.
            , siConfiguredProviders =
                error "provider probe must not run for a yubikey vault"
            }
      state <- deriveSetupState inputs
      stStatus (providerStep state) `shouldBe` StepReady
      -- The card list is derived from config.toml alone.
      [ pcId c | c <- ssProviders state, pcConfigured c ] `shouldBe` ["anthropic"]

    it "the emitted state has exactly two required steps" $ do
      state <- deriveSetupState (emptySetupInputs fakePaths)
      map stRequired (ssSteps state) `shouldBe` [True, True]
      map stId (ssSteps state) `shouldBe` ["vault", "provider"]

    prop "required_complete == all-required-ready" $
      forAll genScenario $ \scenario -> ioProperty $ do
        inputs <- inputsFor scenario
        state <- deriveSetupState inputs
        pure (ssRequiredComplete state
                == all (\s -> not (stRequired s) || stStatus s == StepReady)
                       (ssSteps state))

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

testRecipient :: Text
testRecipient = "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqysq0"

fakePaths :: SealPaths
fakePaths = SealPaths
  { spHome   = "/home/alice/.seal"
  , spConfig = "/home/alice/.seal/config"
  , spState  = "/home/alice/.seal/state"
  , spKeys   = "/home/alice/.seal/keys"
  , spCache  = "/home/alice/.seal/cache"
  }

-- | A vault configured on disk: key recorded, file present, identity readable.
configuredOnDisk :: SetupInputs
configuredOnDisk = (emptySetupInputs fakePaths)
  { siSecurity = defaultSecurityConfig
      { scVaultRecipient = Just testRecipient
      , scVaultIdentity  = Just "/home/alice/.seal/keys/default.identity"
      , scVaultKeyType   = Just "x25519"
      }
  , siVaultFileExists = True
  , siIdentityReadable = Just True
  }

workingVault :: VaultHandle -> SetupInputs
workingVault handle = configuredOnDisk { siHandle = Just handle }

withUnlock :: Text -> SetupInputs -> SetupInputs
withUnlock mode inputs =
  inputs { siSecurity = (siSecurity inputs) { scVaultUnlock = Just mode } }

vaultStep :: SetupState -> SetupStep
vaultStep = stepById "vault"

providerStep :: SetupState -> SetupStep
providerStep = stepById "provider"

stepById :: Text -> SetupState -> SetupStep
stepById stepId state = case filter ((== stepId) . stId) (ssSteps state) of
  (s:_) -> s
  [] -> error ("no step " <> T.unpack stepId)

stepStatuses :: SetupState -> [StepStatus]
stepStatuses = map stStatus . ssSteps

actionsOf :: Text -> SetupState -> [Text]
actionsOf stepId state =
  concat [stActions s | s <- ssSteps state, stId s == stepId]

-- ---------------------------------------------------------------------------
-- Property fixtures
-- ---------------------------------------------------------------------------

data Scenario = Scenario
  { scRecipient   :: Bool
  , scVaultFile   :: Bool
  , scHandle      :: Maybe Bool   -- ^ 'Nothing' = no handle; @Just locked?@
  , scIdentity    :: Maybe Bool
  , scDefaultProv :: Maybe Bool   -- ^ @Just True@ = default set and configured
  } deriving stock (Show)

genScenario :: Gen Scenario
genScenario = Scenario
  <$> elements [True, False]
  <*> elements [True, False]
  <*> oneof [pure Nothing, Just <$> elements [True, False]]
  <*> elements [Nothing, Just True, Just False]
  <*> elements [Nothing, Just True, Just False]

inputsFor :: Scenario -> IO SetupInputs
inputsFor scenario = do
  mhandle <- case scHandle scenario of
    Nothing   -> pure Nothing
    Just True -> Just <$> makeLockedVault
    Just False -> Just <$> makeFakeVault []
  let security = defaultSecurityConfig
        { scVaultRecipient =
            if scRecipient scenario then Just testRecipient else Nothing
        , scVaultIdentity = if scRecipient scenario
            then Just "/home/alice/.seal/keys/default.identity"
            else Nothing
        , scVaultKeyType =
            if scRecipient scenario then Just "x25519" else Nothing
        }
      runtime = defaultRuntimeConfig
        { rcDefaultProvider = case scDefaultProv scenario of
            Just True  -> Just "anthropic"
            Just False -> Just "openrouter"
            Nothing    -> Nothing
        }
      configured = case scDefaultProv scenario of
        Just True  -> pure [AnthropicProvider]
        Just False -> pure []
        Nothing    -> pure [OllamaProvider]
  pure SetupInputs
    { siPaths = fakePaths
    , siRuntime = runtime
    , siSecurity = security
    , siSecurityProblem = Nothing
    , siHandle = mhandle
    , siVaultFileExists = scVaultFile scenario
    , siIdentityReadable = scIdentity scenario
    , siConfiguredProviders = configured
    , siHome = "/home/alice"
    }
