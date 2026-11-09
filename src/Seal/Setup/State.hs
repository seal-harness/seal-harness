{-# LANGUAGE OverloadedStrings #-}
-- | The first-run setup state: what the wizard must show, computed from files
-- on disk plus the live vault handle.
--
-- == Two rules this module exists to enforce
--
-- 1. /Never/ treat @vsLocked@ as a readiness signal on its own. A
--    @per_access@ vault never populates the in-memory cache (every read goes
--    to disk), so a perfectly working vault reports @vsLocked = True@
--    forever. Only @startup@ mode can be genuinely locked in-process, and
--    @reopen@ (which calls @vhUnlock@) is the in-product fix.
-- 2. /Never/ decrypt while merely rendering the wizard. For a YubiKey vault,
--    probing credentials means a physical touch, so the provider step is
--    config-only there (§5.2); the explicit Test button is where a touch is
--    allowed to happen.
--
-- Every 'SetupStep' detail is path-free: tilde form at most, no absolute path,
-- no secret, no credential value. This module imports no vault read function
-- beyond 'VaultStatus' — it cannot leak vault contents because it cannot read
-- them.
module Seal.Setup.State
  ( StepStatus (..)
  , SetupStep (..)
  , ProviderCard (..)
  , SetupState (..)
  , SetupInputs (..)
  , emptySetupInputs
  , deriveSetupState
  ) where

import Data.List (stripPrefix)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath (takeDirectory, takeFileName)

import Seal.Config.File
  ( RuntimeConfig (..), defaultRuntimeConfig, providerDefaultModel )
import Seal.Config.Paths (SealPaths (..), vaultFilePath)
import Seal.Config.Security (SecurityConfig (..), defaultSecurityConfig)
import Seal.Core.Types (ModelId (..))
import Seal.Providers.Registry
  ( KnownProvider (..), defaultModelFor, knownProviders, parseProvider
  , providerLabel )
import Seal.Security.Vault (VaultHandle (vhStatus), VaultStatus (..))

-- | The three states a wizard row can be in. There is deliberately no
-- @StepSkipped@: the gate is blocking (operator decision), so "done" and
-- "not done" are the only outcomes a required step can have.
data StepStatus = StepReady | StepPending | StepBlocked
  deriving stock (Eq, Show)

data SetupStep = SetupStep
  { stId       :: Text
  , stRequired :: Bool
  , stStatus   :: StepStatus
  , stDetail   :: Maybe Text
    -- ^ Path-free: tilde form at most. Never a secret or a credential value.
  , stActions  :: [Text]
    -- ^ @create@ | @resume@ | @reopen@ | @recheck@ | @configure@.
    -- @configure@ renders no action-bar button (the provider step has its own
    -- inline form); the rest map to buttons.
  } deriving stock (Eq, Show)

-- | One row of the provider step's list. Carried on 'SetupState' so the
-- provider step renders without a second call to @GET \/api\/providers\/all@
-- (which decrypts once per provider name).
data ProviderCard = ProviderCard
  { pcId           :: Text
  , pcLabel        :: Text
  , pcConfigured   :: Bool
  , pcIsDefault    :: Bool
  , pcDefaultModel :: Maybe Text
  , pcRequiresBaseUrl :: Bool
    -- ^ True for providers with no built-in endpoint (the generic
    -- OpenAI-compatible option): the wizard must collect the URL, and the
    -- backend refuses to use the provider without one. Server-driven so the
    -- wizard never has to know which provider is which.
  } deriving stock (Eq, Show)

data SetupState = SetupState
  { ssRequiredComplete :: Bool
  , ssSteps            :: [SetupStep]
  , ssProviders        :: [ProviderCard]
  } deriving stock (Eq, Show)

-- | Everything 'deriveSetupState' needs, as values.
--
-- The two @stat@ results ('siVaultFileExists', 'siIdentityReadable') are
-- inputs rather than seams, so classification is testable without a
-- filesystem; the caller does the two @stat@ calls against 'siPaths'.
data SetupInputs = SetupInputs
  { siPaths              :: SealPaths
  , siRuntime            :: RuntimeConfig
  , siSecurity           :: SecurityConfig
  , siSecurityProblem    :: Maybe Text
    -- ^ 'Just' a summary when @security.toml@ exists but does not parse.
    -- 'Nothing' when it parsed (or was absent, in which case 'siSecurity' is
    -- 'defaultSecurityConfig').
  , siHandle             :: Maybe VaultHandle
  , siVaultFileExists    :: Bool
  , siIdentityReadable   :: Maybe Bool
    -- ^ 'Nothing' = no identity recorded; @Just False@ = recorded but not a
    -- readable regular file.
  , siHome               :: FilePath
    -- ^ The user's home directory, the base for the tilde form a detail may
    -- show. 'emptySetupInputs' guesses it as the seal home's parent, which is
    -- exactly right for the default @~/.seal@ layout; the handler can override
    -- it with the real home directory.
  , siConfiguredProviders :: IO [KnownProvider]
    -- ^ The @adProviders@ seam. Never invoked for a YubiKey vault.
  }

-- | An "empty install": no config files on disk, no handle, no vault, no
-- provider probing. The base a handler overrides field by field.
emptySetupInputs :: SealPaths -> SetupInputs
emptySetupInputs paths = SetupInputs
  { siPaths = paths
  , siRuntime = defaultRuntimeConfig
  , siSecurity = defaultSecurityConfig
  , siSecurityProblem = Nothing
  , siHandle = Nothing
  , siVaultFileExists = False
  , siIdentityReadable = Nothing
  , siConfiguredProviders = pure []
  , siHome = takeDirectory (spHome paths)
  }

-- | The whole state. 'ssSteps' order is the wizard's order: vault first.
deriveSetupState :: SetupInputs -> IO SetupState
deriveSetupState inputs = do
  vault <- classifyVault inputs
  configured <- configuredProviderIds inputs
  let provider = classifyProvider inputs configured
      steps = [vault, provider]
  pure SetupState
    { ssRequiredComplete = all isSatisfied steps
    , ssSteps = steps
    , ssProviders = providerCards inputs configured
    }
  where
    -- A future non-required step (chat channels) must not be able to block the
    -- gate by accident: only required steps constrain completion.
    isSatisfied step = not (stRequired step) || stStatus step == StepReady

-- ---------------------------------------------------------------------------
-- Vault step (design §5.1, ordered by terminality)
-- ---------------------------------------------------------------------------

classifyVault :: SetupInputs -> IO SetupStep
classifyVault inputs
  -- V0: the file exists but does not decode. Never attempt a write; the
  -- runtime case is "boot refused, then a later edit broke it".
  | Just summary <- siSecurityProblem inputs =
      pure (blockedVault
        ("security.toml could not be parsed (" <> summary
          <> "). Fix or restore it, then Re-check.")
        ["recheck"])
  -- V1: an orphan vault file. Precedes the identity check on purpose: when
  -- both are wrong the operator must attach a key first, and the reverse order
  -- would give advice that cannot fix the blocker.
  | siVaultFileExists inputs, isNothing recipient =
      pure (blockedVault (orphanDetail inputs) ["recheck"])
  -- V2: the recorded identity cannot be read.
  | isJust recipient, Just False <- siIdentityReadable inputs =
      pure (blockedVault (identityDetail inputs) ["recheck"])
  | otherwise = do
      locked <- handleLocked (siHandle inputs)
      pure (classifyWith locked)
  where
    security = siSecurity inputs
    recipient = scVaultRecipient security
    startupMode = scVaultUnlock security == Just "startup"
    hasHandle = isJust (siHandle inputs)
    vaultExists = siVaultFileExists inputs

    classifyWith locked
      -- V3: startup mode, handle present, genuinely locked.
      | hasHandle, startupMode, locked =
          blockedVault
            "The vault is locked (mode: `startup`). Reopen it here, or run \
            \`/vault unlock` in `seal tui`."
            ["reopen", "recheck"]
      -- V4: configured on disk but no handle in this process.
      | isJust recipient, vaultExists, not hasHandle =
          blockedVault "The vault is configured but not open in this process." ["reopen"]
      -- V5: key recorded, no vault file — one click from done.
      | isJust recipient, not vaultExists =
          pendingVault "Finish creating the vault (a key is already recorded)." ["resume"]
      -- V6: open, on disk, identity readable, and not genuinely locked.
      | hasHandle, vaultExists, not (startupMode && locked) =
          readyVault ("Key type: `" <> fromMaybe "unknown" (scVaultKeyType security) <> "`.")
      -- Nothing recorded, no vault file: the clean first run.
      | otherwise =
          pendingVault "Create an encrypted vault for API keys and tokens." ["create"]

handleLocked :: Maybe VaultHandle -> IO Bool
handleLocked Nothing = pure False
handleLocked (Just handle) = vsLocked <$> vhStatus handle

orphanDetail :: SetupInputs -> Text
orphanDetail inputs =
  "A vault file exists at " <> displayPath inputs (configuredVaultPath inputs)
    <> " but no key is recorded. Run `seal tui`, then `/vault setup` to attach \
       \a key, then Re-check."

identityDetail :: SetupInputs -> Text
identityDetail inputs =
  "security.toml names `" <> identityBasename inputs <> "`, which cannot be \
  \read. Fix ~/.seal/security.toml or re-run `/vault setup` in `seal tui`, \
  \then Re-check."

identityBasename :: SetupInputs -> Text
identityBasename inputs = case scVaultIdentity (siSecurity inputs) of
  Nothing -> "the identity file"
  Just raw -> T.pack (takeFileName (T.unpack raw))

configuredVaultPath :: SetupInputs -> FilePath
configuredVaultPath inputs =
  maybe (vaultFilePath (siPaths inputs)) T.unpack (scVaultPath (siSecurity inputs))

-- | Render a path for a detail. Tilde form when it is under the user's home
-- (@~/.seal/config/vault/vault.age@); otherwise the file name alone. A detail
-- must never carry an absolute path (design §5.1), so an unusual @SEAL_HOME@
-- loses the location rather than disclosing it.
displayPath :: SetupInputs -> FilePath -> Text
displayPath inputs path = case stripPrefix (siHome inputs <> "/") path of
  Just rest -> "~/" <> T.pack rest
  Nothing   -> T.pack (takeFileName path)

-- ---------------------------------------------------------------------------
-- Provider step (design §5.2)
-- ---------------------------------------------------------------------------

-- | Which provider ids count as configured. For a YubiKey vault this is
-- config-only (@[providers.*]@ sections), because asking the vault would
-- decrypt — and a decrypt on a YubiKey identity means a physical touch.
configuredProviderIds :: SetupInputs -> IO (Set Text)
configuredProviderIds inputs
  | isYubiKeyVault inputs =
      pure (Set.fromList (Map.keys (rcProviders (siRuntime inputs))))
  | otherwise =
      Set.fromList . map providerLabel <$> siConfiguredProviders inputs

classifyProvider :: SetupInputs -> Set Text -> SetupStep
classifyProvider inputs configured =
  case rcDefaultProvider (siRuntime inputs) of
    Just label
      -- P1
      | isYubiKeyVault inputs || Set.member label configured ->
          readyProvider (label <> " · " <> modelFor inputs label)
      -- P2
      | otherwise ->
          pendingProvider ("Add credentials for " <> label <> ".") ["configure"]
    Nothing
      -- P3
      | not (Set.null configured) ->
          pendingProvider "Choose which provider new sessions should use." ["configure"]
      -- P4
      | otherwise ->
          pendingProvider
            "Add an LLM provider: anthropic, openrouter, ollama, or an \
            \OpenAI-compatible endpoint."
            ["configure"]

-- | The model a session would actually use: the global default, else the
-- provider's configured default, else the provider's hardcoded default.
modelFor :: SetupInputs -> Text -> Text
modelFor inputs label =
  fromMaybe (defaultModelText label) $
    rcDefaultModel (siRuntime inputs)
      <> providerDefaultModel (siRuntime inputs) label

defaultModelText :: Text -> Text
defaultModelText label = case parseProvider label of
  Just known -> modelText (defaultModelFor known)
  Nothing -> "unknown model"

modelText :: ModelId -> Text
modelText (ModelId m) = m

providerCards :: SetupInputs -> Set Text -> [ProviderCard]
providerCards inputs configured =
  [ ProviderCard
      { pcId = providerLabel known
      , pcLabel = providerDisplayName known
      , pcConfigured = Set.member (providerLabel known) configured
      , pcIsDefault = rcDefaultProvider (siRuntime inputs) == Just (providerLabel known)
      , pcDefaultModel = providerDefaultModel (siRuntime inputs) (providerLabel known)
      , pcRequiresBaseUrl = case known of
          OpenAICompatibleProvider -> True
          _ -> False
      }
  | known <- knownProviders
  ]

-- | The card's display name. Branding is explicit rather than derived: a
-- mechanical capitalise turns @openrouter@ into "Openrouter".
providerDisplayName :: KnownProvider -> Text
providerDisplayName known = case known of
  AnthropicProvider  -> "Anthropic"
  OllamaProvider     -> "Ollama"
  OpenRouterProvider -> "OpenRouter"
  OpenAICompatibleProvider -> "OpenAI-compatible"

isYubiKeyVault :: SetupInputs -> Bool
isYubiKeyVault inputs = scVaultKeyType (siSecurity inputs) == Just "yubikey"

-- ---------------------------------------------------------------------------
-- Constructors
-- ---------------------------------------------------------------------------

vaultStepId, providerStepId :: Text
vaultStepId = "vault"
providerStepId = "provider"

readyVault :: Text -> SetupStep
readyVault detail = SetupStep vaultStepId True StepReady (Just detail) []

pendingVault :: Text -> [Text] -> SetupStep
pendingVault detail = SetupStep vaultStepId True StepPending (Just detail)

blockedVault :: Text -> [Text] -> SetupStep
blockedVault detail = SetupStep vaultStepId True StepBlocked (Just detail)

readyProvider :: Text -> SetupStep
readyProvider detail = SetupStep providerStepId True StepReady (Just detail) []

pendingProvider :: Text -> [Text] -> SetupStep
pendingProvider detail = SetupStep providerStepId True StepPending (Just detail)
