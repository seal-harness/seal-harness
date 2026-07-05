# Phase 3 — M1: Provider config + vault credentials + `/provider` commands

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `/provider add|list|test|remove` command group (Anthropic only) that stores provider API keys in the encrypted vault and can prove a live round-trip from the REPL.

**Architecture:** A small code-level provider registry (`Seal.Providers.Registry`) maps a `KnownProvider` to its vault credential name and builds a `SomeProvider` by reading the key from the vault on demand. A new command module (`Seal.Command.Provider`) exposes the four subcommands over `ChannelCaps`, following the existing `/vault` pattern. Two scalar config keys (`default_provider`, `default_model`) record the user's default.

**Tech Stack:** Haskell (GHC2021), hspec + QuickCheck tests, `optparse-applicative` command parsers, `tomland` config, `http-client`/`http-client-tls` for the provider HTTP layer.

**Scope note / deviation from the design spec:** The design (`docs/superpowers/specs/2026-06-30-phase-3-multi-provider-sessions-design.md`) describes a `[providers.<id>]` TOML table. For M1 (Anthropic only) that table is unnecessary — the only per-provider setting Anthropic needs is the default model, which the top-level `default_model` covers. M1 therefore ships **only the two scalar keys plus a code-level known-provider list**, and defers the `[providers.<id>]` table to **M3** (when Ollama needs a per-provider `base_url`). This is a faithful subset and keeps M1 the shortest path to a user-testable provider test.

## Global Constraints

- Language/build: **GHC2021**, `-Wall -Werror`, **hlint-clean**. Build and test inside the Nix dev shell (`nix develop`).
- Style: `deriving stock`; **post-positive qualified imports** (`import Data.Text qualified as T`); capability-handle pattern; no effect systems.
- Errors: **`Either Text`** by default; a typed error ADT only where control flow needs it (none new here).
- Secrets: API keys use the opaque `ApiKey` from `Seal.Security.Secrets` — **never** serialized, logged, or `Show`n in the clear. Key bytes only ever cross into `mkApiKey`.
- Clean-room: **no reference to any prior/reference runtime by name** in code, identifiers, comments, docs, or commit messages.
- TDD: write the failing test first, watch it fail, implement minimally, watch it pass, commit. Every task ends green (`cabal build` and `cabal test` both clean).
- Test run commands: full suite `cabal test`; focused `cabal test --test-options='-m "<pattern>"'`.

---

### Task 1: Config defaults (`default_provider`, `default_model`)

**Files:**
- Modify: `src/Seal/Config/File.hs`
- Test: `test/Seal/Config/FileSpec.hs`

**Interfaces:**
- Consumes: existing `FileConfig`, `fileConfigCodec`, `loadFileConfig`, `saveFileConfig`.
- Produces: `FileConfig` gains `fcDefaultProvider :: Maybe Text` and `fcDefaultModel :: Maybe Text`; both round-trip through the TOML keys `default_provider` / `default_model`; both default to `Nothing`.

- [ ] **Step 1: Write the failing test**

Add to `test/Seal/Config/FileSpec.hs` inside the top-level `spec` (a new `describe`):

```haskell
  describe "provider defaults" $ do
    it "round-trips default_provider and default_model through TOML" $
      withSystemTempDirectory "seal-cfg" $ \dir -> do
        let path = dir </> "config.toml"
            cfg  = defaultFileConfig
              { fcDefaultProvider = Just "anthropic"
              , fcDefaultModel    = Just "claude-opus-4-8"
              }
        saveFileConfig path cfg
        Right loaded <- loadFileConfig path
        fcDefaultProvider loaded `shouldBe` Just "anthropic"
        fcDefaultModel    loaded `shouldBe` Just "claude-opus-4-8"

    it "defaults to Nothing when the keys are absent" $ do
      fcDefaultProvider defaultFileConfig `shouldBe` Nothing
      fcDefaultModel    defaultFileConfig `shouldBe` Nothing
```

Ensure these imports exist at the top of the file (add any that are missing):

```haskell
import System.IO.Temp (withSystemTempDirectory)
import System.FilePath ((</>))
import Seal.Config.File
  ( FileConfig (..), defaultFileConfig, loadFileConfig, saveFileConfig )
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cabal test --test-options='-m "provider defaults"'`
Expected: FAIL — `fcDefaultProvider`/`fcDefaultModel` are not fields of `FileConfig` (compile error / not in scope).

- [ ] **Step 3: Add the two fields + codec lines**

In `src/Seal/Config/File.hs`, add the two fields to the `FileConfig` record (after `fcVaultKeyType`):

```haskell
  , fcVaultKeyType :: Maybe Text
    -- ^ Display label: @\"x25519\"@ | @\"yubikey\"@ | @\"user\"@.
  , fcDefaultProvider :: Maybe Text
    -- ^ Provider id used for new sessions (e.g. @\"anthropic\"@).
  , fcDefaultModel :: Maybe Text
    -- ^ Model id used for new sessions (e.g. @\"claude-opus-4-8\"@).
  } deriving stock (Eq, Show)
```

Add their defaults in `defaultFileConfig` (after `fcVaultKeyType = Nothing`):

```haskell
  , fcVaultKeyType   = Nothing
  , fcDefaultProvider = Nothing
  , fcDefaultModel    = Nothing
  }
```

Add their codec lines at the end of `fileConfigCodec` (after the `vault_key_type` line):

```haskell
  <*> Toml.dioptional (Toml.text "vault_key_type")  .= fcVaultKeyType
  <*> Toml.dioptional (Toml.text "default_provider") .= fcDefaultProvider
  <*> Toml.dioptional (Toml.text "default_model")    .= fcDefaultModel
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cabal test --test-options='-m "provider defaults"'`
Expected: PASS (2 examples).

- [ ] **Step 5: Build the whole project (no warnings)**

Run: `cabal build`
Expected: builds clean with `-Werror`.

- [ ] **Step 6: Commit**

```bash
git add src/Seal/Config/File.hs test/Seal/Config/FileSpec.hs
git commit -m "Add default_provider/default_model config keys"
```

---

### Task 2: Provider registry vocabulary

**Files:**
- Create: `src/Seal/Providers/Registry.hs`
- Create: `test/Seal/Providers/RegistrySpec.hs`
- Modify: `seal-harness.cabal` (expose the module + register the spec)
- Modify: `test/Main.hs` (register the spec)

**Interfaces:**
- Consumes: `ProviderId`, `ModelId (..)` from `Seal.Core.Types`.
- Produces:
  - `data KnownProvider = AnthropicProvider` deriving `(Eq, Show, Enum, Bounded)`
  - `knownProviders :: [KnownProvider]`
  - `providerLabel :: KnownProvider -> Text` (`AnthropicProvider -> "anthropic"`)
  - `providerId :: KnownProvider -> ProviderId`
  - `parseProvider :: Text -> Maybe KnownProvider` (case-insensitive on the label)
  - `vaultKeyName :: KnownProvider -> Text` (`AnthropicProvider -> "ANTHROPIC_API_KEY"`)
  - `defaultModelFor :: KnownProvider -> ModelId` (`AnthropicProvider -> ModelId "claude-opus-4-8"`)

- [ ] **Step 1: Write the failing test**

Create `test/Seal/Providers/RegistrySpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.RegistrySpec (spec) where

import Test.Hspec

import Seal.Core.Types (ModelId (..), ProviderId (..))
import Seal.Providers.Registry
  ( KnownProvider (..)
  , defaultModelFor
  , knownProviders
  , parseProvider
  , providerId
  , providerLabel
  , vaultKeyName
  )

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
```

Register it: in `test/Main.hs` add the import line with the other `Seal.Providers.*` imports:

```haskell
import qualified Seal.Providers.RegistrySpec
```

and add to the `hspec $ do` block (near the other `Seal.Providers` lines):

```haskell
  Seal.Providers.RegistrySpec.spec
```

In `seal-harness.cabal`, add `Seal.Providers.RegistrySpec` to the test-suite `other-modules` (alongside `Seal.Providers.ClassSpec`).

- [ ] **Step 2: Run test to verify it fails**

Run: `cabal test --test-options='-m "Registry vocabulary"'`
Expected: FAIL — module `Seal.Providers.Registry` not found.

- [ ] **Step 3: Create the module**

Create `src/Seal/Providers/Registry.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | The code-level provider registry: the set of providers Seal knows how to
-- build, and the mapping from each to its display label, vault credential key,
-- and default model. Credential resolution (reading the key from the vault and
-- constructing a live 'SomeProvider') is added on top of this vocabulary.
module Seal.Providers.Registry
  ( KnownProvider (..)
  , knownProviders
  , providerLabel
  , providerId
  , parseProvider
  , vaultKeyName
  , defaultModelFor
  ) where

import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (ModelId (..), ProviderId (..))

-- | Every provider Seal can build. M1 ships Anthropic only; later milestones
-- extend this sum (the totality of the functions below forces each addition to
-- be handled everywhere).
data KnownProvider = AnthropicProvider
  deriving stock (Eq, Show, Enum, Bounded)

knownProviders :: [KnownProvider]
knownProviders = [minBound .. maxBound]

-- | The user-facing id typed at the @/provider@ prompt.
providerLabel :: KnownProvider -> Text
providerLabel AnthropicProvider = "anthropic"

providerId :: KnownProvider -> ProviderId
providerId = ProviderId . providerLabel

-- | Parse a label (case-insensitive) back to a 'KnownProvider'.
parseProvider :: Text -> Maybe KnownProvider
parseProvider t =
  let needle = T.toCaseFold (T.strip t)
  in lookup needle [(T.toCaseFold (providerLabel p), p) | p <- knownProviders]

-- | The vault secret name under which this provider's API key is stored.
vaultKeyName :: KnownProvider -> Text
vaultKeyName AnthropicProvider = "ANTHROPIC_API_KEY"

-- | The model used when the user has not chosen one.
defaultModelFor :: KnownProvider -> ModelId
defaultModelFor AnthropicProvider = ModelId "claude-opus-4-8"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cabal test --test-options='-m "Registry vocabulary"'`
Expected: PASS (7 examples).

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Providers/Registry.hs test/Seal/Providers/RegistrySpec.hs \
        test/Main.hs seal-harness.cabal
git commit -m "Add Seal.Providers.Registry provider vocabulary"
```

---

### Task 3: Credential resolution (`resolveProvider`, `completeSome`) + fake-vault helper

**Files:**
- Modify: `src/Seal/Providers/Registry.hs`
- Create: `test/Seal/TestHelpers/FakeVault.hs`
- Modify: `test/Seal/Providers/RegistrySpec.hs`
- Modify: `seal-harness.cabal` (register the new test helper module; add `http-client` to the test-suite deps)

**Interfaces:**
- Consumes: `VaultHandle (..)` from `Seal.Security.Vault`; `VaultError (..)` from `Seal.Security.Vault.Age`; `mkApiKey` from `Seal.Security.Secrets`; `mkAnthropic` from `Seal.Providers.Anthropic`; `SomeProvider (..)`, `Provider (..)`, `CompletionRequest`, `CompletionResponse` from `Seal.Providers.Class`; `Manager` from `Network.HTTP.Client`.
- Produces:
  - `resolveProvider :: VaultHandle -> Manager -> KnownProvider -> ModelId -> IO (Either Text SomeProvider)`
  - `completeSome :: SomeProvider -> CompletionRequest -> IO (Either Text CompletionResponse)`
  - `vaultErrText :: VaultError -> Text`
  - Test helper `makeFakeVault :: [(Text, ByteString)] -> IO VaultHandle` and `makeLockedVault :: IO VaultHandle` in `Seal.TestHelpers.FakeVault`.

- [ ] **Step 1: Create the fake-vault test helper**

Create `test/Seal/TestHelpers/FakeVault.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | In-memory VaultHandle for tests, backed by an IORef Map. Mirrors the real
-- handle's Either-VaultError contract without any crypto or disk.
module Seal.TestHelpers.FakeVault
  ( makeFakeVault
  , makeLockedVault
  ) where

import Data.ByteString (ByteString)
import Data.IORef (newIORef, readIORef, writeIORef, modifyIORef')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

import Seal.Security.Vault (VaultHandle (..), VaultStatus (..))
import Seal.Security.Vault.Age (VaultError (..))

-- | An unlocked vault seeded with the given name→value pairs.
makeFakeVault :: [(Text, ByteString)] -> IO VaultHandle
makeFakeVault initial = do
  ref <- newIORef (Map.fromList initial :: Map Text ByteString)
  pure VaultHandle
    { vhInit   = pure (Right ())
    , vhUnlock = pure (Right ())
    , vhLock   = pure ()
    , vhGet    = \k -> maybe (Left (VaultKeyNotFound k)) Right . Map.lookup k <$> readIORef ref
    , vhPut    = \k v -> modifyIORef' ref (Map.insert k v) >> pure (Right ())
    , vhDelete = \k -> do
        m <- readIORef ref
        if Map.member k m
          then writeIORef ref (Map.delete k m) >> pure (Right ())
          else pure (Left (VaultKeyNotFound k))
    , vhList   = Right . Map.keys <$> readIORef ref
    , vhStatus = do
        m <- readIORef ref
        pure (VaultStatus False (Map.size m) "test")
    , vhRekey  = \_ _ _ -> pure (Right ())
    }

-- | A locked vault: every accessor returns 'VaultLocked'.
makeLockedVault :: IO VaultHandle
makeLockedVault = pure VaultHandle
  { vhInit   = pure (Right ())
  , vhUnlock = pure (Right ())
  , vhLock   = pure ()
  , vhGet    = \_   -> pure (Left VaultLocked)
  , vhPut    = \_ _ -> pure (Left VaultLocked)
  , vhDelete = \_   -> pure (Left VaultLocked)
  , vhList   = pure (Left VaultLocked)
  , vhStatus = pure (VaultStatus True 0 "test")
  , vhRekey  = \_ _ _ -> pure (Left VaultLocked)
  }
```

Register `Seal.TestHelpers.FakeVault` in the test-suite `other-modules` in `seal-harness.cabal` (next to `Seal.TestHelpers.FakeCaps`). Add `http-client` to the test-suite `build-depends`.

- [ ] **Step 2: Write the failing tests**

Append to `test/Seal/Providers/RegistrySpec.hs`. Add imports:

```haskell
import Data.Either (isRight)
import Data.Text qualified as T
import Network.HTTP.Client (defaultManagerSettings, newManager)

import Seal.Providers.Class
  ( CompletionResponse (..), Provider (..), SomeProvider (..)
  , StopReason (..), Usage (..) )
import Seal.Providers.Registry (completeSome, resolveProvider)
import Seal.TestHelpers.FakeVault (makeFakeVault, makeLockedVault)
```

Add a canned provider just above `spec`:

```haskell
newtype Canned = Canned (Either T.Text CompletionResponse)
instance Provider Canned where
  complete (Canned r) _ = pure r
  listModels _ = pure (Right [])
```

Add these `describe`s to `spec`:

```haskell
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
      r `shouldSatisfy` isRight

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
```

Note: `completeSome` returns the canned `Right resp` without forcing the request, so `error "request not forced"` is never evaluated — this proves `completeSome` does not inspect the request itself.

- [ ] **Step 3: Run tests to verify they fail**

Run: `cabal test --test-options='-m "Seal.Providers.Registry"'`
Expected: FAIL — `resolveProvider`, `completeSome` not in scope.

- [ ] **Step 4: Implement resolution in the module**

In `src/Seal/Providers/Registry.hs`, extend the export list:

```haskell
  , vaultKeyName
  , defaultModelFor
  , resolveProvider
  , completeSome
  , vaultErrText
  ) where
```

Add imports:

```haskell
import Network.HTTP.Client (Manager)

import Seal.Providers.Anthropic (mkAnthropic)
import Seal.Providers.Class
  ( CompletionRequest, CompletionResponse, Provider (..), SomeProvider (..) )
import Seal.Security.Secrets (mkApiKey)
import Seal.Security.Vault (VaultHandle (..))
import Seal.Security.Vault.Age (VaultError (..))
```

Append the implementation:

```haskell
-- | Build a live provider by reading its API key from the vault. The key
-- bytes flow straight into 'mkApiKey' (opaque) — never returned or logged.
resolveProvider
  :: VaultHandle -> Manager -> KnownProvider -> ModelId
  -> IO (Either Text SomeProvider)
resolveProvider vh mgr kp model = do
  eKey <- vhGet vh (vaultKeyName kp)
  pure $ case eKey of
    Left e         -> Left (credErr kp e)
    Right keyBytes -> Right (build kp mgr (mkApiKey keyBytes) model)
  where
    build AnthropicProvider m k md = SomeProvider (mkAnthropic m k md)

-- | Run a completion through an existentially-wrapped provider.
completeSome :: SomeProvider -> CompletionRequest -> IO (Either Text CompletionResponse)
completeSome (SomeProvider p) = complete p

-- | Provider-aware credential error: a missing key points the user at the
-- exact @/provider add@ they need.
credErr :: KnownProvider -> VaultError -> Text
credErr kp = \case
  VaultKeyNotFound _ ->
    "no credential for " <> providerLabel kp
      <> " — run /provider add " <> providerLabel kp
  e -> vaultErrText e

-- | Human-readable rendering of a vault error.
vaultErrText :: VaultError -> Text
vaultErrText = \case
  VaultLocked         -> "vault is locked — run /vault unlock"
  VaultNotFound       -> "vault not found — run /vault setup"
  VaultAlreadyExists  -> "vault already exists"
  VaultKeyNotFound k  -> "no such secret: " <> k
  VaultBackendError t -> "backend error: " <> t
```

Add `LambdaCase` to the module's pragmas (top of file):

```haskell
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cabal test --test-options='-m "Seal.Providers.Registry"'`
Expected: PASS (all vocabulary + resolution examples).

- [ ] **Step 6: Build clean**

Run: `cabal build`
Expected: clean with `-Werror`.

- [ ] **Step 7: Commit**

```bash
git add src/Seal/Providers/Registry.hs test/Seal/TestHelpers/FakeVault.hs \
        test/Seal/Providers/RegistrySpec.hs seal-harness.cabal
git commit -m "Add provider credential resolution + in-memory fake vault"
```

---

### Task 4: Provider command pure helpers (`pingRequest`, `formatTestResult`)

**Files:**
- Create: `src/Seal/Command/Provider.hs`
- Create: `test/Seal/Command/ProviderSpec.hs`
- Modify: `seal-harness.cabal` (expose the module + register the spec)
- Modify: `test/Main.hs` (register the spec)

**Interfaces:**
- Consumes: `ModelId`, `CompletionRequest (..)`, `CompletionResponse (..)`, `Usage (..)`, `ToolChoice (..)`, `Role (..)`, `textMsg` from `Seal.Providers.Class`.
- Produces:
  - `pingRequest :: ModelId -> CompletionRequest` (a 1-message, 16-token, no-tools request)
  - `formatTestResult :: Text -> Either Text CompletionResponse -> Text`

- [ ] **Step 1: Write the failing test**

Create `test/Seal/Command/ProviderSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.ProviderSpec (spec) where

import Data.Text qualified as T
import Test.Hspec

import Seal.Command.Provider (formatTestResult, pingRequest)
import Seal.Core.Types (ModelId (..))
import Seal.Providers.Class
  ( CompletionRequest (..), CompletionResponse (..)
  , StopReason (..), ToolChoice (..), Usage (..) )

spec :: Spec
spec = describe "Seal.Command.Provider helpers" $ do
  describe "pingRequest" $ do
    it "uses the given model, one message, no tools, a small token cap" $ do
      let req = pingRequest (ModelId "claude-opus-4-8")
      crModel req      `shouldBe` ModelId "claude-opus-4-8"
      length (crMessages req) `shouldBe` 1
      crTools req      `shouldBe` []
      crToolChoice req `shouldBe` ToolNone
      crMaxTokens req  `shouldSatisfy` (> 0)

  describe "formatTestResult" $ do
    it "reports success with the output-token count" $ do
      let r = formatTestResult "anthropic"
                (Right (CompletionResponse [] StopEnd (Usage 3 7)))
      r `shouldSatisfy` ("anthropic" `T.isInfixOf`)
      r `shouldSatisfy` ("OK" `T.isInfixOf`)
      r `shouldSatisfy` ("7" `T.isInfixOf`)

    it "reports failure with the error text" $ do
      let r = formatTestResult "anthropic" (Left "boom")
      r `shouldSatisfy` ("FAILED" `T.isInfixOf`)
      r `shouldSatisfy` ("boom" `T.isInfixOf`)
```

Register in `test/Main.hs`:

```haskell
import qualified Seal.Command.ProviderSpec
```
and in the `hspec $ do` block (near the other `Seal.Command.*` lines):
```haskell
  Seal.Command.ProviderSpec.spec
```

In `seal-harness.cabal`: add `Seal.Command.Provider` to the **library** `exposed-modules`, and add `Seal.Command.ProviderSpec` to the test-suite `other-modules`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cabal test --test-options='-m "Seal.Command.Provider helpers"'`
Expected: FAIL — module `Seal.Command.Provider` not found.

- [ ] **Step 3: Create the module with just the helpers**

Create `src/Seal/Command/Provider.hs`:

```haskell
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The @/provider@ command group: configure, list, test, and remove model
-- providers. Credentials live in the vault; this module never holds key bytes
-- beyond handing them to the vault or to 'mkApiKey'.
module Seal.Command.Provider
  ( pingRequest
  , formatTestResult
  ) where

import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (ModelId)
import Seal.Providers.Class
  ( CompletionRequest (..), CompletionResponse (..), Role (..)
  , ToolChoice (..), Usage (..), textMsg )

-- | A minimal completion used to prove a provider responds.
pingRequest :: ModelId -> CompletionRequest
pingRequest m = CompletionRequest
  { crModel      = m
  , crSystem     = Nothing
  , crMessages   = [textMsg User "ping"]
  , crTools      = []
  , crToolChoice = ToolNone
  , crMaxTokens  = 16
  }

-- | Render the outcome of @/provider test@ for a provider labelled @label@.
formatTestResult :: Text -> Either Text CompletionResponse -> Text
formatTestResult label = \case
  Left e  -> label <> " test FAILED: " <> e
  Right r ->
    label <> " OK — model responded ("
      <> T.pack (show (uOutput (rsUsage r))) <> " output tokens, stop="
      <> T.pack (show (rsStop r)) <> ")"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cabal test --test-options='-m "Seal.Command.Provider helpers"'`
Expected: PASS (5 examples).

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Command/Provider.hs test/Seal/Command/ProviderSpec.hs \
        test/Main.hs seal-harness.cabal
git commit -m "Add /provider command pure helpers (pingRequest, formatTestResult)"
```

---

### Task 5: `/provider` command surface (add / list / test / remove)

**Files:**
- Modify: `src/Seal/Command/Spec.hs` (add `GroupProvider`)
- Modify: `src/Seal/Command/Help.hs` (header for `GroupProvider`)
- Modify: `src/Seal/Command/Provider.hs` (runtime + parser + handlers + spec)
- Modify: `test/Seal/Command/ProviderSpec.hs` (parser + handler tests)

**Interfaces:**
- Consumes: `ChannelCaps (..)`; `CommandAction (..)`, `CommandGroup (..)`, `CommandName (..)`, `CommandSpec (..)`, `Availability (..)` from `Seal.Command.Spec`; `VaultRuntime (..)` from `Seal.Vault.Commands`; `VaultHandle (..)` from `Seal.Security.Vault`; `loadFileConfig`, `updateFileConfig`, `FileConfig (..)` from `Seal.Config.File`; everything produced by Tasks 2–4.
- Produces:
  - `data ProviderRuntime = ProviderRuntime { prConfigPath :: FilePath, prVault :: VaultRuntime, prManager :: Manager }`
  - `providerCommandSpec :: ProviderRuntime -> CommandSpec`
  - new `CommandGroup` constructor `GroupProvider`.

- [ ] **Step 1: Add the `GroupProvider` group (with its Help header)**

In `src/Seal/Command/Spec.hs`, add the constructor between `GroupGeneral` and `GroupVault` (insertion order sets the Ord used for help ordering):

```haskell
data CommandGroup
  = GroupGeneral
  | GroupProvider
  | GroupVault
  deriving stock (Eq, Ord, Show, Enum, Bounded)
```

In `src/Seal/Command/Help.hs`, add the matching header case (keeps `groupHeader` total under `-Werror`):

```haskell
    groupHeader GroupGeneral  = "General"
    groupHeader GroupProvider = "Providers"
    groupHeader GroupVault    = "Vault"
```

- [ ] **Step 2: Write the failing tests (parser + handlers)**

Append to `test/Seal/Command/ProviderSpec.hs`. Add imports:

```haskell
import Data.ByteString (ByteString)
import Data.IORef (newIORef)
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

import Seal.Channel.Caps (ChannelCaps)
import Seal.Command.Provider (ProviderRuntime (..), providerCommandSpec)
import Seal.Command.Spec (CommandSpec (..), runCommandAction)
import Seal.Config.File (FileConfig (..), loadFileConfig)
import Seal.Config.Paths (SealPaths (..))
import Seal.Security.Vault (VaultHandle, vhGet)
import Seal.TestHelpers.FakeCaps (getSent, makeFakeCaps)
import Seal.TestHelpers.FakeVault (makeFakeVault)
import Seal.Vault.Commands (VaultRuntime (..))
```

Add helpers + the `describe` to `spec`:

```haskell
mkPR :: FilePath -> Maybe VaultHandle -> IO ProviderRuntime
mkPR cfgPath mvh = do
  ref <- newIORef mvh
  mgr <- newManager defaultManagerSettings
  let sp  = SealPaths cfgPath cfgPath cfgPath cfgPath   -- unused by /provider
      vrt = VaultRuntime { vrPaths = sp, vrConfigPath = cfgPath, vrHandleRef = ref }
  pure ProviderRuntime { prConfigPath = cfgPath, prVault = vrt, prManager = mgr }

runProv :: ProviderRuntime -> [String] -> ChannelCaps -> IO ()
runProv pr argv caps =
  case execParserPure defaultPrefs (csParserInfo (providerCommandSpec pr)) argv of
    Success act         -> runCommandAction act caps
    Failure _           -> expectationFailure ("parse failed: " <> show argv)
    CompletionInvoked _ -> expectationFailure "unexpected completion"
```

```haskell
  describe "/provider commands" $ do
    it "add stores the key and seeds defaults when unset" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfgPath (Just vh)
        (fc, caps) <- makeFakeCaps ["sk-secret"]
        runProv pr ["add", "anthropic"] caps
        vhGet vh "ANTHROPIC_API_KEY" >>= (`shouldBe` Right ("sk-secret" :: ByteString))
        Right cfg <- loadFileConfig cfgPath
        fcDefaultProvider cfg `shouldBe` Just "anthropic"
        fcDefaultModel    cfg `shouldBe` Just "claude-opus-4-8"
        sent <- getSent fc
        sent `shouldSatisfy` any ("Stored API key" `T.isInfixOf`)

    it "list marks the default and shows credential presence" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        vh <- makeFakeVault [("ANTHROPIC_API_KEY", "sk")]
        pr <- mkPR cfgPath (Just vh)
        (_, addCaps)  <- makeFakeCaps ["sk2"]      -- not used; ensures defaults
        runProv pr ["add", "anthropic"] addCaps     -- sets default_provider
        (fc, caps) <- makeFakeCaps []
        runProv pr ["list"] caps
        sent <- getSent fc
        T.unlines sent `shouldSatisfy` ("anthropic" `T.isInfixOf`)
        T.unlines sent `shouldSatisfy` ("default" `T.isInfixOf`)
        T.unlines sent `shouldSatisfy` ("present" `T.isInfixOf`)

    it "remove deletes the credential and clears a matching default" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        vh <- makeFakeVault [("ANTHROPIC_API_KEY", "sk")]
        pr <- mkPR cfgPath (Just vh)
        (_, addCaps) <- makeFakeCaps ["sk"]
        runProv pr ["add", "anthropic"] addCaps      -- sets default
        (fc, caps) <- makeFakeCaps []
        runProv pr ["remove", "anthropic"] caps
        vhGet vh "ANTHROPIC_API_KEY" >>= (`shouldSatisfy` either (const True) (const False))
        Right cfg <- loadFileConfig cfgPath
        fcDefaultProvider cfg `shouldBe` Nothing
        sent <- getSent fc
        sent `shouldSatisfy` any ("Removed" `T.isInfixOf`)

    it "rejects an unknown provider" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfgPath (Just vh)
        (fc, caps) <- makeFakeCaps []
        runProv pr ["test", "bogus"] caps
        sent <- getSent fc
        sent `shouldSatisfy` any ("unknown provider" `T.isInfixOf`)

    it "reports when the vault is not configured" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        pr <- mkPR cfgPath Nothing      -- no vault handle
        (fc, caps) <- makeFakeCaps []
        runProv pr ["list"] caps
        sent <- getSent fc
        sent `shouldSatisfy` any ("vault not configured" `T.isInfixOf`)

    it "the spec is in the Providers group" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        pr <- mkPR (dir </> "config.toml") Nothing
        csSynopsis (providerCommandSpec pr) `shouldSatisfy` (not . T.null)

    it "live: /provider test anthropic round-trips against the real API" $
      pending  -- requires ANTHROPIC_API_KEY + network; run manually
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cabal test --test-options='-m "/provider commands"'`
Expected: FAIL — `ProviderRuntime`, `providerCommandSpec` not in scope.

- [ ] **Step 4: Implement the runtime, parser, and handlers**

In `src/Seal/Command/Provider.hs`, extend the export list:

```haskell
module Seal.Command.Provider
  ( pingRequest
  , formatTestResult
  , ProviderRuntime (..)
  , providerCommandSpec
  ) where
```

Add imports:

```haskell
import Control.Applicative ((<|>))
import Data.IORef (readIORef)
import Data.Text.Encoding qualified as TE
import Network.HTTP.Client (Manager)
import Options.Applicative

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Config.File
  ( FileConfig (..), loadFileConfig, updateFileConfig )
import Seal.Core.Types (ModelId (..))
import Seal.Providers.Class (CompletionResponse)
import Seal.Providers.Registry
  ( KnownProvider, completeSome, defaultModelFor, knownProviders
  , parseProvider, providerLabel, resolveProvider, vaultErrText, vaultKeyName )
import Seal.Security.Vault (VaultHandle, vhDelete, vhGet, vhPut)
import Seal.Security.Vault.Age (VaultError (..))
import Seal.Vault.Commands (VaultRuntime (..))
```

Append the runtime + spec + parser + handlers:

```haskell
-- | Everything the @/provider@ handlers need: where config lives, the vault
-- (for credentials), and an HTTP manager (for the live @test@ round-trip).
data ProviderRuntime = ProviderRuntime
  { prConfigPath :: FilePath
  , prVault      :: VaultRuntime
  , prManager    :: Manager
  }

providerCommandSpec :: ProviderRuntime -> CommandSpec
providerCommandSpec pr = CommandSpec
  { csName         = CommandName "provider"
  , csAliases      = []
  , csGroup        = GroupProvider
  , csSynopsis     = "Configure and test model providers"
  , csParserInfo   = providerParserInfo pr
  , csAvailability = InteractiveOnly
  }

providerParserInfo :: ProviderRuntime -> ParserInfo CommandAction
providerParserInfo pr =
  info (providerParser pr <**> helper)
    (  progDesc "Manage model providers (API keys stored in the vault)"
    <> header   "provider — configure and test model providers"
    )

providerParser :: ProviderRuntime -> Parser CommandAction
providerParser pr = hsubparser
  (  command "add"
       (info (addCmd pr <$> provArg)
             (progDesc "Store a provider API key (hidden prompt) in the vault"))
  <> command "list"
       (info (pure (listCmd pr))
             (progDesc "List known providers and their credential status"))
  <> command "test"
       (info (testCmd pr <$> provArg)
             (progDesc "Run a live round-trip to verify a provider works"))
  <> command "remove"
       (info (removeCmd pr <$> provArg)
             (progDesc "Remove a provider's stored credential"))
  <> metavar "COMMAND"
  )

provArg :: Parser Text
provArg = T.pack <$> strArgument (metavar "PROVIDER" <> help "Provider id (e.g. anthropic)")

-- Shared guards -------------------------------------------------------------

withVaultHandle :: ProviderRuntime -> ChannelCaps -> (VaultHandle -> IO ()) -> IO ()
withVaultHandle pr caps k = do
  mh <- readIORef (vrHandleRef (prVault pr))
  maybe (ccSend caps "vault not configured — run /vault setup") k mh

withProvider :: ChannelCaps -> Text -> (KnownProvider -> IO ()) -> IO ()
withProvider caps lbl k =
  maybe (ccSend caps (unknownProviderMsg lbl)) k (parseProvider lbl)

unknownProviderMsg :: Text -> Text
unknownProviderMsg lbl =
  "unknown provider: " <> lbl <> " (known: "
    <> T.intercalate ", " (map providerLabel knownProviders) <> ")"

-- Subcommand handlers -------------------------------------------------------

addCmd :: ProviderRuntime -> Text -> CommandAction
addCmd pr lbl = CommandAction $ \caps ->
  withProvider caps lbl $ \kp ->
    withVaultHandle pr caps $ \vh -> do
      val <- ccPromptSecret caps ("API key for " <> providerLabel kp <> ": ")
      res <- vhPut vh (vaultKeyName kp) (TE.encodeUtf8 val)
      case res of
        Left e   -> ccSend caps (vaultErrText e)
        Right () -> do
          _ <- updateFileConfig (prConfigPath pr) (seedDefaults kp)
          ccSend caps ("Stored API key for " <> providerLabel kp <> ".")
  where
    seedDefaults kp fc = fc
      { fcDefaultProvider = fcDefaultProvider fc <|> Just (providerLabel kp)
      , fcDefaultModel    = fcDefaultModel fc    <|> Just (modelText (defaultModelFor kp))
      }

listCmd :: ProviderRuntime -> CommandAction
listCmd pr = CommandAction $ \caps ->
  withVaultHandle pr caps $ \vh -> do
    eCfg <- loadFileConfig (prConfigPath pr)
    let def = either (const Nothing) fcDefaultProvider eCfg
    mapM_ (reportOne caps vh def) knownProviders
  where
    reportOne caps vh def kp = do
      eGet <- vhGet vh (vaultKeyName kp)
      let cred = case eGet of
            Right _                   -> "credential: present"
            Left (VaultKeyNotFound _) -> "credential: absent"
            Left VaultLocked          -> "credential: (vault locked)"
            Left e                    -> "credential: " <> vaultErrText e
          mark = if Just (providerLabel kp) == def then " (default)" else ""
      ccSend caps (providerLabel kp <> mark <> " — " <> cred)

testCmd :: ProviderRuntime -> Text -> CommandAction
testCmd pr lbl = CommandAction $ \caps ->
  withProvider caps lbl $ \kp ->
    withVaultHandle pr caps $ \vh -> do
      eCfg <- loadFileConfig (prConfigPath pr)
      let model = case eCfg of
            Right c | Just m <- fcDefaultModel c -> ModelId m
            _                                    -> defaultModelFor kp
      eProv <- resolveProvider vh (prManager pr) kp model
      case eProv of
        Left e   -> ccSend caps (formatTestResult (providerLabel kp) (Left e))
        Right sp -> do
          r <- completeSome sp (pingRequest model) :: IO (Either Text CompletionResponse)
          ccSend caps (formatTestResult (providerLabel kp) r)

removeCmd :: ProviderRuntime -> Text -> CommandAction
removeCmd pr lbl = CommandAction $ \caps ->
  withProvider caps lbl $ \kp ->
    withVaultHandle pr caps $ \vh -> do
      res <- vhDelete vh (vaultKeyName kp)
      case res of
        Left e   -> ccSend caps (vaultErrText e)
        Right () -> do
          _ <- updateFileConfig (prConfigPath pr) (clearDefault kp)
          ccSend caps ("Removed credential for " <> providerLabel kp <> ".")
  where
    clearDefault kp fc
      | fcDefaultProvider fc == Just (providerLabel kp) =
          fc { fcDefaultProvider = Nothing, fcDefaultModel = Nothing }
      | otherwise = fc

modelText :: ModelId -> Text
modelText (ModelId t) = t
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cabal test --test-options='-m "Seal.Command.Provider"'`
Expected: PASS (helpers + `/provider commands`, with the `live:` example reported as pending).

- [ ] **Step 6: Build clean**

Run: `cabal build`
Expected: clean with `-Werror`.

- [ ] **Step 7: Commit**

```bash
git add src/Seal/Command/Spec.hs src/Seal/Command/Help.hs \
        src/Seal/Command/Provider.hs test/Seal/Command/ProviderSpec.hs
git commit -m "Add /provider add|list|test|remove command surface"
```

---

### Task 6: Wire `/provider` into the CLI registry

**Files:**
- Modify: `src/Seal/Tui.hs`
- Modify: `test/Seal/Command/ProviderSpec.hs` (help-index integration test)

**Interfaces:**
- Consumes: `providerCommandSpec`, `ProviderRuntime (..)` (Task 5); `renderHelpIndex` from `Seal.Command.Help`; `newTlsManager` from `Network.HTTP.Client.TLS`.
- Produces: the assembled `Registry` now contains the `/provider` spec; `renderHelpIndex` shows a "Providers" group with a `/provider` line.

- [ ] **Step 1: Write the failing integration test**

Append to the `/provider commands` describe in `test/Seal/Command/ProviderSpec.hs`. Add import:

```haskell
import Seal.Command.Help (renderHelpIndex)
import Seal.Command.Spec (mkRegistry)
```

Add the test:

```haskell
    it "appears under the Providers group in the help index" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        pr <- mkPR (dir </> "config.toml") Nothing
        let idx = renderHelpIndex (mkRegistry [providerCommandSpec pr])
        idx `shouldSatisfy` ("Providers" `T.isInfixOf`)
        idx `shouldSatisfy` ("/provider" `T.isInfixOf`)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cabal test --test-options='-m "appears under the Providers group"'`
Expected: FAIL — `renderHelpIndex`/`mkRegistry` not yet imported in the spec (compile error), proving the test is wired before the source change.

(If the import additions alone make it pass because `providerCommandSpec` already sets `GroupProvider`, that is fine — it confirms Task 5's group wiring. Proceed to Step 3 to wire the real CLI.)

- [ ] **Step 3: Wire the provider command into `Seal.Tui`**

In `src/Seal/Tui.hs`, add imports:

```haskell
import Network.HTTP.Client.TLS (newTlsManager)

import Seal.Command.Provider (ProviderRuntime (..), providerCommandSpec)
```

In `runTui`, after the `VaultRuntime` (`rt`) is built and before `runCliTui`, build the `ProviderRuntime` and add its spec to the registry. Replace the `let rt = ... ; registry = ...` block with:

```haskell
  let rt = VaultRuntime
            { vrPaths      = paths
            , vrConfigPath = cfgPath
            , vrHandleRef  = ref
            }
  -- A dedicated manager for the /provider test round-trip. (M2 consolidates
  -- this with the chat provider's manager when the startup hardcode is removed.)
  mgr <- newTlsManager
  let pr = ProviderRuntime
            { prConfigPath = cfgPath
            , prVault      = rt
            , prManager    = mgr
            }
      registry = mkRegistry [vaultCommandSpec rt, providerCommandSpec pr]
  runCliTui paths rt registry emptyChain
```

- [ ] **Step 4: Run the targeted test + full suite**

Run: `cabal test --test-options='-m "appears under the Providers group"'`
Expected: PASS.

Run: `cabal test`
Expected: all examples pass; pending count includes the new `live:` provider test plus the pre-existing pending tests.

- [ ] **Step 5: Build clean + hlint**

Run: `cabal build`
Expected: clean with `-Werror`.

Run: `hlint src/Seal/Providers/Registry.hs src/Seal/Command/Provider.hs src/Seal/Tui.hs src/Seal/Config/File.hs`
Expected: "No hints".

- [ ] **Step 6: Manual smoke (user-testable checkpoint)**

In a shell with the Nix dev environment and a real key exported as `ANTHROPIC_API_KEY` available to type:

```
cabal run seal -- repl
> /vault setup        # if not already configured
> /provider add anthropic     # paste the key at the hidden prompt
> /provider list              # anthropic (default) — credential: present
> /provider test anthropic    # expect: anthropic OK — model responded (… tokens, stop=StopEnd)
> /provider remove anthropic  # Removed credential for anthropic.
```

Expected: `test` prints an `OK` line on a working key, and a `FAILED: …` line (no key bytes) on a bad key.

- [ ] **Step 7: Commit**

```bash
git add src/Seal/Tui.hs test/Seal/Command/ProviderSpec.hs
git commit -m "Wire /provider into the CLI command registry"
```

---

## Self-Review

**Spec coverage (against the design's M1 bullets):**
- `config.toml` defaults → Task 1 (`default_provider`/`default_model`; the `[providers.<id>]` table is explicitly deferred to M3, noted in the header).
- `/provider add` (hidden prompt → vault) → Task 5 `addCmd` (uses `ccPromptSecret`).
- `/provider list` (configured + credential present) → Task 5 `listCmd`.
- `/provider test` (live round-trip, key-safe) → Tasks 3+4+5 (`resolveProvider` + `pingRequest`/`completeSome` + `formatTestResult`; errors carry no key bytes).
- `/provider remove` → Task 5 `removeCmd`.
- Vault-stored credentials, opaque `ApiKey`, lazy resolution → Task 3 (`resolveProvider` reads from the vault on demand; never returns key bytes).
- Channel-agnostic (no Haskeline types in registry/commands) → registry and command modules import only `ChannelCaps`; verified by tests driving them through `FakeCaps`.
- CLI wiring + discoverability via `/help` → Task 6.

**Placeholder scan:** No TBD/TODO; every code step shows complete code; the one `pending` is an intentional gated live test (matches the suite's existing pending convention).

**Type consistency:** `KnownProvider`/`AnthropicProvider`, `providerLabel`, `vaultKeyName`, `defaultModelFor`, `resolveProvider`, `completeSome`, `vaultErrText`, `pingRequest`, `formatTestResult`, `ProviderRuntime`/`providerCommandSpec`, and `GroupProvider` are used with identical names/signatures across the tasks that define and consume them. `VaultHandle` field names (`vhGet`/`vhPut`/`vhDelete`/`vhList`/`vhStatus`/`vhInit`/`vhUnlock`/`vhLock`/`vhRekey`) match `Seal.Security.Vault`. `VaultError` constructors match `Seal.Security.Vault.Age`. `FileConfig` field additions are referenced consistently.
