# Per-provider config sections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move per-provider config into `[providers.<label>]` sections (`default_model` + `base_url`), add `/model default <provider> <model>`, and make `/model use`'s model optional — all reading a settable per-provider default.

**Architecture:** `FileConfig` gains `fcProviders :: Map Text ProviderConfig` (via tomland `tableMap`), replacing the flat `ollama_base_url` key. Small helpers resolve a provider's default model and base URL from the section (with hardcoded fallback). `/model` and `/provider` commands read/write those sections.

**Tech Stack:** Haskell (GHC2021), `tomland` 1.3.3.3 (`Toml.tableMap Toml._KeyText`), `containers` (`Data.Map.Strict`), `optparse-applicative`, `hspec`. Spec: `docs/superpowers/specs/2026-07-02-provider-default-model-design.md`.

## Global Constraints

- GHC2021; builds `-Wall -Werror -Wname-shadowing -Wpartial-fields -Wincomplete-record-updates -Wincomplete-uni-patterns`; **hlint clean** (`nix develop --command hlint src/ test/` → "No hints").
- Errors `Either Text`. No secret bytes in output; base URL is not secret.
- Build/test inside the Nix dev shell: `nix develop --command cabal build all`, `nix develop --command cabal test`, focused `nix develop --command cabal test --test-options='--match "<needle>"'`.
- Follow existing patterns (post-positive qualified imports, `Toml.dioptional` for optional keys, `deriving stock`). Register nothing new in cabal (no new modules).
- Provider labels are `"anthropic"` and `"ollama"` (from `providerLabel`). `defaultModelFor`: `anthropic`→`claude-opus-4-8`, `ollama`→`llama3.2`. `defaultOllamaBaseUrl = "http://localhost:11434"`.
- Commit one per task; frequent. TDD: failing test → fail → implement → pass → commit.

---

### Task 1: Additive config foundation — `ProviderConfig`, `fcProviders`, helpers, `resolveDefaultModel`

Add the new section type, map field, codec, and resolution helpers **without removing** `fcOllamaBaseUrl` yet (kept until Task 2 migrates its readers). Purely additive → trivially green.

**Files:**
- Modify: `src/Seal/Config/File.hs`
- Modify: `src/Seal/Providers/Registry.hs`
- Test: `test/Seal/Config/FileSpec.hs`
- Test: `test/Seal/Providers/RegistrySpec.hs`

**Interfaces:**
- Produces:
  - `data ProviderConfig = ProviderConfig { pcDefaultModel :: Maybe Text, pcBaseUrl :: Maybe Text }` (Eq, Show)
  - `fcProviders :: FileConfig -> Map Text ProviderConfig` (record field; `defaultFileConfig` → `Map.empty`)
  - `providerDefaultModel :: FileConfig -> Text -> Maybe Text`
  - `providerBaseUrl :: FileConfig -> Text -> Maybe Text`
  - `upsertProvider :: Text -> (ProviderConfig -> ProviderConfig) -> FileConfig -> FileConfig`
  - `emptyProviderConfig :: ProviderConfig`
  - `resolveDefaultModel :: Maybe Text -> Text -> ModelId` (Registry)

- [ ] **Step 1: Write the failing tests**

In `test/Seal/Config/FileSpec.hs`, add imports `import Data.Map.Strict qualified as Map` and extend the module import to include the new names: `FileConfig (..), ProviderConfig (..), providerDefaultModel, providerBaseUrl, upsertProvider, emptyProviderConfig, defaultFileConfig, loadFileConfig, saveFileConfig, updateFileConfig`. Add:

```haskell
  describe "provider sections" $ do
    it "parses [providers.<label>] sections" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ T.unlines
          [ "[providers.ollama]"
          , "base_url = \"http://localhost:11434\""
          , "default_model = \"glm-5.2:cloud\""
          , "[providers.anthropic]"
          , "default_model = \"claude-opus-4-8\""
          ]
        Right cfg <- loadFileConfig path
        providerBaseUrl      cfg "ollama"    `shouldBe` Just "http://localhost:11434"
        providerDefaultModel cfg "ollama"    `shouldBe` Just "glm-5.2:cloud"
        providerDefaultModel cfg "anthropic" `shouldBe` Just "claude-opus-4-8"
        providerBaseUrl      cfg "anthropic" `shouldBe` Nothing

    it "has an empty provider map when [providers] is absent" $
      providerDefaultModel defaultFileConfig "ollama" `shouldBe` Nothing

    it "upsertProvider updates one field without clobbering the other" $ do
      let c1 = upsertProvider "ollama" (\p -> p { pcBaseUrl = Just "http://h:1" }) defaultFileConfig
          c2 = upsertProvider "ollama" (\p -> p { pcDefaultModel = Just "m" }) c1
      providerBaseUrl      c2 "ollama" `shouldBe` Just "http://h:1"
      providerDefaultModel c2 "ollama" `shouldBe` Just "m"

    it "round-trips provider sections through save/load" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
            cfg  = upsertProvider "ollama" (const (ProviderConfig (Just "glm-5.2:cloud") (Just "http://localhost:11434"))) defaultFileConfig
        saveFileConfig path cfg
        Right back <- loadFileConfig path
        fcProviders back `shouldBe` fcProviders cfg
```

In `test/Seal/Providers/RegistrySpec.hs`, add `resolveDefaultModel` to the import and:

```haskell
  describe "resolveDefaultModel" $ do
    it "uses the configured value when present" $
      resolveDefaultModel (Just "glm-5.2:cloud") "ollama" `shouldBe` ModelId "glm-5.2:cloud"
    it "falls back to the provider's hardcoded default" $ do
      resolveDefaultModel Nothing "ollama"    `shouldBe` ModelId "llama3.2"
      resolveDefaultModel Nothing "anthropic" `shouldBe` ModelId "claude-opus-4-8"
    it "falls back to anthropic for an unknown label" $
      resolveDefaultModel Nothing "who" `shouldBe` ModelId "claude-opus-4-8"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nix develop --command cabal test --test-options='--match "provider sections"'` and `--match "resolveDefaultModel"`
Expected: FAIL to compile (names not in scope).

- [ ] **Step 3: Implement in `Seal.Config.File`**

Add imports: `import Data.Map.Strict (Map)` and `import Data.Map.Strict qualified as Map`, and `import Toml qualified` already present. Add the type and helpers, extend `FileConfig`, `defaultFileConfig`, and the codec. Add all new names to the module export list (`ProviderConfig (..), providerDefaultModel, providerBaseUrl, upsertProvider, emptyProviderConfig`).

```haskell
data ProviderConfig = ProviderConfig
  { pcDefaultModel :: Maybe Text
  , pcBaseUrl      :: Maybe Text
  } deriving stock (Eq, Show)

emptyProviderConfig :: ProviderConfig
emptyProviderConfig = ProviderConfig Nothing Nothing
```

Add the field to `FileConfig` (after `fcOllamaBaseUrl`, which stays for now):

```haskell
  , fcOllamaBaseUrl :: Maybe Text
  , fcProviders :: Map Text ProviderConfig
    -- ^ Per-provider config sections (@[providers.<label>]@).
  } deriving stock (Eq, Show)
```

Add to `defaultFileConfig`:

```haskell
  , fcOllamaBaseUrl   = Nothing
  , fcProviders       = Map.empty
  }
```

Add the codecs (the `providerConfigCodec` as a top-level, and the `tableMap` line last in `fileConfigCodec`):

```haskell
providerConfigCodec :: Toml.TomlCodec ProviderConfig
providerConfigCodec = ProviderConfig
  <$> Toml.dioptional (Toml.text "default_model") .= pcDefaultModel
  <*> Toml.dioptional (Toml.text "base_url")      .= pcBaseUrl
```

and in `fileConfigCodec`, append:

```haskell
  <*> Toml.dioptional (Toml.text "ollama_base_url")  .= fcOllamaBaseUrl
  <*> Toml.tableMap Toml._KeyText (const providerConfigCodec) "providers" .= fcProviders
```

(`Toml._KeyText` is exported from `Toml`.) Add the helpers:

```haskell
providerDefaultModel :: FileConfig -> Text -> Maybe Text
providerDefaultModel cfg lbl = pcDefaultModel =<< Map.lookup lbl (fcProviders cfg)

providerBaseUrl :: FileConfig -> Text -> Maybe Text
providerBaseUrl cfg lbl = pcBaseUrl =<< Map.lookup lbl (fcProviders cfg)

-- | Insert or update one provider section by applying @f@ to its current
-- config (or to an empty one if absent).
upsertProvider :: Text -> (ProviderConfig -> ProviderConfig) -> FileConfig -> FileConfig
upsertProvider lbl f cfg =
  cfg { fcProviders = Map.insertWith (\_ old -> f old) lbl (f emptyProviderConfig) (fcProviders cfg) }
```

- [ ] **Step 4: Implement `resolveDefaultModel` in `Seal.Providers.Registry`**

Add `resolveDefaultModel` to the export list and define it (imports `ModelId (..)`, `parseProvider`, `defaultModelFor`, `AnthropicProvider` are already in scope):

```haskell
-- | A provider's default model: the configured value if given, else the
-- provider's hardcoded default (Anthropic's for an unrecognized label).
resolveDefaultModel :: Maybe Text -> Text -> ModelId
resolveDefaultModel (Just m) _   = ModelId m
resolveDefaultModel Nothing  lbl =
  maybe (defaultModelFor AnthropicProvider) defaultModelFor (parseProvider lbl)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `nix develop --command cabal build all && nix develop --command cabal test --test-options='--match "provider sections"'` and `--match "resolveDefaultModel"`, then the full suite once.
Expected: PASS; build `-Werror` clean; hlint clean.

- [ ] **Step 6: Commit**

```bash
git add src/Seal/Config/File.hs src/Seal/Providers/Registry.hs test/Seal/Config/FileSpec.hs test/Seal/Providers/RegistrySpec.hs
git commit -m "feat(config): add [providers.<label>] sections + resolveDefaultModel (additive)"
```

---

### Task 2: Migrate base_url to the section; remove the flat `ollama_base_url`

Switch the three base_url readers and the `/provider add` base_url writer to `[providers.ollama].base_url`, then delete `fcOllamaBaseUrl`.

**Files:**
- Modify: `src/Seal/Config/File.hs` (remove `fcOllamaBaseUrl`)
- Modify: `src/Seal/Channel/Cli.hs`, `src/Seal/Command/Model.hs`, `src/Seal/Command/Provider.hs`
- Test: `test/Seal/Config/FileSpec.hs`, `test/Seal/Command/ProviderSpec.hs`

**Interfaces:**
- Consumes: `providerBaseUrl`, `upsertProvider` (Task 1), `defaultOllamaBaseUrl`.
- Produces: `fcOllamaBaseUrl` no longer exists; base URL comes from `providerBaseUrl cfg "ollama"`.

- [ ] **Step 1: Update tests first (RED)**

In `test/Seal/Config/FileSpec.hs`: remove `fcOllamaBaseUrl` from the `defaultFileConfig` record literal (the "has all Nothing fields" test) and add `fcProviders = Map.empty` there; delete the `"parses ollama_base_url"` test; in the round-trip full literal, replace `fcOllamaBaseUrl = Just "http://localhost:11434"` with `fcProviders = Map.empty` (or a populated map).

In `test/Seal/Command/ProviderSpec.hs`: change the `add ollama` test assertion at line ~176 from `fcOllamaBaseUrl cfg \`shouldBe\` Just "https://ollama.com"` to `providerBaseUrl cfg "ollama" \`shouldBe\` Just "https://ollama.com"`, and update the import to drop `fcOllamaBaseUrl` and add `providerBaseUrl`.

- [ ] **Step 2: Run to verify failure**

Run: `nix develop --command cabal test --test-options='--match "Seal.Config.File"'`
Expected: FAIL to compile (`fcOllamaBaseUrl` still referenced in src).

- [ ] **Step 3: Remove `fcOllamaBaseUrl` and migrate readers/writer**

In `src/Seal/Config/File.hs`: delete the `fcOllamaBaseUrl` record field, its `defaultFileConfig` line, and its codec line (`Toml.dioptional (Toml.text "ollama_base_url")`). Remove `fcOllamaBaseUrl` from the export list.

In `src/Seal/Channel/Cli.hs`: change the import `Seal.Config.File (fcOllamaBaseUrl, loadFileConfig)` → `Seal.Config.File (providerBaseUrl, loadFileConfig)`, and the reader:

```haskell
      let baseUrl = maybe defaultOllamaBaseUrl id (either (const Nothing) (\c -> providerBaseUrl c "ollama") eCfg)
```

(equivalently `fromMaybe defaultOllamaBaseUrl (either (const Nothing) (\c -> providerBaseUrl c "ollama") eCfg)` — keep `fromMaybe`, it is already imported.)

In `src/Seal/Command/Model.hs`: same import swap (`fcOllamaBaseUrl` → `providerBaseUrl`) and same reader change in the `/model list <provider>` live branch.

In `src/Seal/Command/Provider.hs`:
- `testCmd` (line ~256): same reader change to `providerBaseUrl c "ollama"`.
- `addOllama`'s `seedAll` (line ~176): replace the `fcOllamaBaseUrl = mUrl <|> fcOllamaBaseUrl fc` field-update with a base_url write into the section using `upsertProvider`. Restructure `seedAll` so that when `mUrl` is `Just u`, it also upserts `pcBaseUrl`:

```haskell
    seedAll mUrl fc =
      let fc' = fc
            { fcDefaultProvider = fcDefaultProvider fc <|> Just (providerLabel kp)
            , fcDefaultModel    = fcDefaultModel fc    <|> Just (modelText (defaultModelFor kp))
            }
      in case mUrl of
           Nothing -> fc'
           Just u  -> upsertProvider (providerLabel kp) (\p -> p { pcBaseUrl = Just u }) fc'
```

Add imports to `Provider.hs`: `Seal.Config.File (..., providerBaseUrl, upsertProvider, ProviderConfig (..))` (extend the existing `Seal.Config.File` import). Keep `fcDefaultModel`/`fcDefaultProvider` seeding as-is (Task 4 moves default_model to the section).

- [ ] **Step 4: Run tests + build**

Run: `nix develop --command cabal build all && nix develop --command cabal test`
Expected: PASS; `-Werror` clean; hlint clean. Confirm no lingering `fcOllamaBaseUrl` references: `grep -rn fcOllamaBaseUrl src test` → empty.

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Config/File.hs src/Seal/Channel/Cli.hs src/Seal/Command/Model.hs src/Seal/Command/Provider.hs test/Seal/Config/FileSpec.hs test/Seal/Command/ProviderSpec.hs
git commit -m "refactor(config): move ollama base_url into [providers.ollama].base_url"
```

---

### Task 3: Provider-aware `defaultSessionSelection`

New sessions on the default provider start from that provider's configured default model.

**Files:**
- Modify: `src/Seal/Session/Store.hs`
- Test: `test/Seal/Session/StoreSpec.hs`

**Interfaces:**
- Consumes: `providerDefaultModel` (Config.File), `resolveDefaultModel` (Registry).
- Produces: `defaultSessionSelection :: FileConfig -> (Text, Text)` (signature unchanged).

- [ ] **Step 1: Write the failing tests**

In `test/Seal/Session/StoreSpec.hs`, in the `defaultSessionSelection` describe block, add (importing `Seal.Config.File (FileConfig (..), defaultFileConfig, upsertProvider, ProviderConfig (..))`):

```haskell
    it "uses the provider's configured section default when set" $ do
      let cfg = upsertProvider "ollama" (\p -> p { pcDefaultModel = Just "glm-5.2:cloud" })
                  (defaultFileConfig { fcDefaultProvider = Just "ollama" })
      defaultSessionSelection cfg `shouldBe` ("ollama", "glm-5.2:cloud")

    it "still lets a global default_model win when present" $ do
      let cfg = (defaultFileConfig { fcDefaultProvider = Just "ollama"
                                   , fcDefaultModel = Just "override" })
      defaultSessionSelection cfg `shouldBe` ("ollama", "override")
```

(Keep the existing Task-7 tests; the "ollama without model" one now resolves via the section → still `llama3.2` when no section entry.)

- [ ] **Step 2: Run to verify failure**

Run: `nix develop --command cabal test --test-options='--match "defaultSessionSelection"'`
Expected: FAIL (first new case gets `claude-opus-4-8` or the old fallback path differs).

- [ ] **Step 3: Implement**

In `src/Seal/Session/Store.hs`, add imports `Seal.Config.File (providerDefaultModel)` (extend existing) and `Seal.Providers.Registry (resolveDefaultModel)` (extend existing), and rewrite the fallback:

```haskell
defaultSessionSelection :: FileConfig -> (Text, Text)
defaultSessionSelection cfg =
  ( provLabel
  , fromMaybe fallbackModel (fcDefaultModel cfg) )
  where
    provLabel = fromMaybe "anthropic" (fcDefaultProvider cfg)
    ModelId fallbackModel = resolveDefaultModel (providerDefaultModel cfg provLabel) provLabel
```

(Drops the old `parseProvider`/`defaultModelFor` inline; `resolveDefaultModel` now encapsulates it. Remove any now-unused imports — e.g. if `parseProvider`/`defaultModelFor`/`AnthropicProvider` are no longer referenced elsewhere in Store.hs, drop them from the import to avoid `-Wunused-imports`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `nix develop --command cabal build all && nix develop --command cabal test --test-options='--match "defaultSessionSelection"'`, then full suite.
Expected: PASS; clean.

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Session/Store.hs test/Seal/Session/StoreSpec.hs
git commit -m "feat(session): new sessions use the provider's section default model"
```

---

### Task 4: `/provider add` seeds the section default model (not the global key)

`/provider add <p>` records the provider's default model in `[providers.<p>].default_model` instead of the global `default_model`, so `/model default` isn't shadowed by a stale global value.

**Files:**
- Modify: `src/Seal/Command/Provider.hs`
- Test: `test/Seal/Command/ProviderSpec.hs`

**Interfaces:**
- Consumes: `upsertProvider`, `providerDefaultModel` (Config.File).

- [ ] **Step 1: Update tests (RED)**

In `test/Seal/Command/ProviderSpec.hs`, the `add stores the key and seeds defaults when unset` test currently asserts `fcDefaultModel cfg \`shouldBe\` Just "claude-opus-4-8"`. Change it to assert the section instead:

```haskell
        fcDefaultProvider cfg `shouldBe` Just "anthropic"
        providerDefaultModel cfg "anthropic" `shouldBe` Just "claude-opus-4-8"
```

(and drop the `fcDefaultModel` assertion). Import `providerDefaultModel`. Leave the `add ollama` base_url test from Task 2 as-is, but also assert its seeded model: `providerDefaultModel cfg "ollama" \`shouldBe\` Just "llama3.2"`.

- [ ] **Step 2: Run to verify failure**

Run: `nix develop --command cabal test --test-options='--match "/provider commands"'`
Expected: FAIL (config has global `default_model`, section unset).

- [ ] **Step 3: Implement — seed the section**

In `src/Seal/Command/Provider.hs`, change both `seedDefaults` (the Anthropic/generic path in `addCmd`) and `seedAll` (in `addOllama`) to seed the section default model instead of the global `fcDefaultModel`. Define one shared helper near them:

```haskell
    seedProviderDefaults kp fc0 =
      let fc1 = fc0 { fcDefaultProvider = fcDefaultProvider fc0 <|> Just (providerLabel kp) }
          lbl = providerLabel kp
      in if isJust (providerDefaultModel fc1 lbl)
           then fc1
           else upsertProvider lbl (\p -> p { pcDefaultModel = Just (modelText (defaultModelFor kp)) }) fc1
```

- In `addCmd`'s generic branch, replace `seedDefaults kp` with `seedProviderDefaults kp`.
- In `addOllama`'s `seedAll`, apply `seedProviderDefaults kp` for provider/default seeding, then the base_url upsert from Task 2:

```haskell
    seedAll mUrl fc =
      let fc' = seedProviderDefaults kp fc
      in case mUrl of
           Nothing -> fc'
           Just u  -> upsertProvider (providerLabel kp) (\p -> p { pcBaseUrl = Just u }) fc'
```

Add `import Data.Maybe (isJust)` (extend existing `Data.Maybe` import) and `providerDefaultModel` to the `Seal.Config.File` import. Remove the now-unused global-`fcDefaultModel`-seeding code and any import that becomes unused.

- [ ] **Step 4: Run tests + build**

Run: `nix develop --command cabal build all && nix develop --command cabal test --test-options='--match "/provider commands"'`, then full suite.
Expected: PASS; clean.

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Command/Provider.hs test/Seal/Command/ProviderSpec.hs
git commit -m "feat(provider): /provider add seeds the section default model"
```

---

### Task 5: `/model default`, optional-model `/model use`, resolved `/model list`

The user-facing commands: set a provider's default, use it, and show it.

**Files:**
- Modify: `src/Seal/Command/Model.hs`
- Test: `test/Seal/Command/ModelSpec.hs`

**Interfaces:**
- Consumes: `providerDefaultModel`, `upsertProvider`, `updateFileConfig`, `resolveDefaultModel`, `defaultModelFor`, `providerLabel`, `parseProvider`.
- Produces: `/model default <provider> <model>`; `/model use <provider> [model]`; `/model list` shows resolved defaults.

- [ ] **Step 1: Write the failing tests**

In `test/Seal/Command/ModelSpec.hs`, add (the `runModel`/`mkPR` helpers from the previous feature already build a `ProviderRuntime` + `SessionRuntime`; the config path is `srConfigPath sr` = `prConfigPath pr`, same file):

```haskell
  it "default sets a provider's section default model" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root; pr <- mkPR (srConfigPath sr) Nothing
      (fc, caps) <- makeFakeCaps []
      runModel pr sr ["default", "ollama", "glm-5.2:cloud"] caps
      Right cfg <- loadFileConfig (srConfigPath sr)
      providerDefaultModel cfg "ollama" `shouldBe` Just "glm-5.2:cloud"
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("glm-5.2:cloud" `T.isInfixOf`)

  it "use without a model uses the provider's default" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root; pr <- mkPR (srConfigPath sr) Nothing
      _ <- updateFileConfig (srConfigPath sr)
             (upsertProvider "ollama" (\p -> p { pcDefaultModel = Just "glm-5.2:cloud" }))
      (_, caps) <- makeFakeCaps []
      runModel pr sr ["use", "ollama"] caps
      active <- readIORef (srActive sr)
      smProvider active `shouldBe` "ollama"
      smModel active    `shouldBe` "glm-5.2:cloud"

  it "use without a model and no config falls back to the hardcoded default" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root; pr <- mkPR (srConfigPath sr) Nothing
      (_, caps) <- makeFakeCaps []
      runModel pr sr ["use", "ollama"] caps
      active <- readIORef (srActive sr)
      smModel active `shouldBe` "llama3.2"

  it "list shows a configured section default" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root; pr <- mkPR (srConfigPath sr) Nothing
      _ <- updateFileConfig (srConfigPath sr)
             (upsertProvider "ollama" (\p -> p { pcDefaultModel = Just "glm-5.2:cloud" }))
      (fc, caps) <- makeFakeCaps []
      runModel pr sr ["list"] caps
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("glm-5.2:cloud" `T.isInfixOf`)
```

Add imports: `Seal.Config.File (loadFileConfig, updateFileConfig, upsertProvider, providerDefaultModel, ProviderConfig (..))`, `Seal.Session.Store (SessionRuntime (..))` (already), `Data.IORef (readIORef)` (already). Update the existing `list` test if it asserted the hardcoded `llama3.2` for ollama — it now shows `resolveDefaultModel` which is still `llama3.2` when unconfigured, so that assertion holds.

- [ ] **Step 2: Run to verify failure**

Run: `nix develop --command cabal test --test-options='--match "Seal.Command.Model"'`
Expected: FAIL (`default` subcommand + optional-model `use` not implemented).

- [ ] **Step 3: Implement**

In `src/Seal/Command/Model.hs`:

- Add the `default` subcommand and make `use`'s model optional in `modelParser`:

```haskell
  <> command "default"
       (info (defaultCmd pr sr <$> provArg <*> modelArg)
             (progDesc "Set a provider's default model"))
  <> command "use"
       (info (useCmd pr sr <$> provArg <*> optional modelArg)
             (progDesc "Set the session's provider and model (model optional)"))
```

(`optional` is available via `Options.Applicative`.)

- `useCmd` gains the `ProviderRuntime` (for the config path) and an optional model:

```haskell
useCmd :: ProviderRuntime -> SessionRuntime -> Text -> Maybe Text -> CommandAction
useCmd pr sr provLbl mModel = CommandAction $ \caps ->
  case parseProvider provLbl of
    Nothing -> ccSend caps (unknownProviderMsg provLbl)
    Just kp -> do
      model <- case mModel of
        Just m  -> pure m
        Nothing -> do
          eCfg <- loadFileConfig (prConfigPath pr)
          let cfg = either (const defaultFileConfig) id eCfg
              ModelId m = resolveDefaultModel (providerDefaultModel cfg (providerLabel kp)) (providerLabel kp)
          pure m
      m0 <- readIORef (srActive sr)
      let m1 = m0 { smProvider = providerLabel kp, smModel = model }
      writeIORef (srActive sr) m1
      saveSessionMeta (srPaths sr) m1
      ccSend caps ("session model set to " <> providerLabel kp <> "/" <> model)
```

- `defaultCmd`:

```haskell
defaultCmd :: ProviderRuntime -> SessionRuntime -> Text -> Text -> CommandAction
defaultCmd pr _ provLbl model = CommandAction $ \caps ->
  case parseProvider provLbl of
    Nothing -> ccSend caps (unknownProviderMsg provLbl)
    Just kp -> do
      res <- updateFileConfig (prConfigPath pr)
               (upsertProvider (providerLabel kp) (\p -> p { pcDefaultModel = Just model }))
      case res of
        Left e   -> ccSend caps e
        Right () -> ccSend caps (providerLabel kp <> " default model set to " <> model)
```

- `listCmd`'s no-arg branch: replace `renderKnown` to show the resolved default. It needs the config, so load it once:

```haskell
listCmd pr sr Nothing = CommandAction $ \caps -> do
  eCfg <- loadFileConfig (prConfigPath pr)
  let cfg = either (const defaultFileConfig) id eCfg
  mapM_ (ccSend caps . renderKnown cfg) knownProviders
  active <- readIORef (srActive sr)
  ccSend caps ("active: " <> smProvider active <> "/" <> smModel active)
  where
    renderKnown cfg kp =
      let lbl = providerLabel kp
          ModelId dm = resolveDefaultModel (providerDefaultModel cfg lbl) lbl
      in lbl <> " (default model: " <> dm <> ")"
```

(The `listCmd` for the `Just provider` live-models branch is unchanged apart from already taking `pr`.) Thread `pr` into `useCmd` at its parser call site; `modelParserInfo`/`modelParser` already receive `pr sr`. Add imports: `Options.Applicative (optional)` if not already in scope; `Seal.Config.File (defaultFileConfig, loadFileConfig, updateFileConfig, upsertProvider, providerDefaultModel, ProviderConfig (..))`; `Seal.Providers.Registry (resolveDefaultModel)` (extend existing).

- [ ] **Step 4: Run tests to verify they pass**

Run: `nix develop --command cabal build all && nix develop --command cabal test --test-options='--match "Seal.Command.Model"'`, then the full suite.
Expected: PASS; `-Werror` clean; hlint clean.

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Command/Model.hs test/Seal/Command/ModelSpec.hs
git commit -m "feat(model): /model default + optional-model /model use + resolved /model list"
```

---

## Self-Review

**Spec coverage:** `[providers.<label>]` sections with default_model + base_url → Task 1 (schema) + Task 2 (base_url migration). `resolveDefaultModel`/`providerDefaultModel`/`providerBaseUrl`/`upsertProvider` → Task 1. Remove flat `ollama_base_url` → Task 2. `defaultSessionSelection` per-provider → Task 3. `/provider add` seeds section → Task 4. `/model default` + optional `/model use` + resolved `/model list` → Task 5. ✅

**Placeholder scan:** none — every step has concrete code and exact commands.

**Type consistency:** `ProviderConfig { pcDefaultModel, pcBaseUrl }`, `fcProviders :: Map Text ProviderConfig`, `upsertProvider :: Text -> (ProviderConfig -> ProviderConfig) -> FileConfig -> FileConfig`, `providerDefaultModel/providerBaseUrl :: FileConfig -> Text -> Maybe Text`, `resolveDefaultModel :: Maybe Text -> Text -> ModelId`, `useCmd`/`defaultCmd`/`listCmd` all take `ProviderRuntime -> SessionRuntime -> …` — consistent across tasks. Green-at-each-step: Task 1 additive; Task 2 removes the field only after readers move in the same commit; Tasks 3–5 additive/behavioral.
