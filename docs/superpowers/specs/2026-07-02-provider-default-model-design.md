# Phase 3, M3 follow-up: per-provider config sections (`[providers.<label>]`)

Date: 2026-07-02
Status: APPROVED (design)
Parent: `docs/superpowers/specs/2026-07-02-ollama-provider-design.md`

## Motivation

`/model list` shows each provider's default model, but that value is the hardcoded
`defaultModelFor` (`llama3.2` for Ollama, `claude-opus-4-8` for Anthropic) — a compile-time
placeholder the user cannot change. Config only has a single **global** `default_model`, and
Ollama's `base_url` sits as a flat top-level key. The user wants per-provider config —
starting with a settable default model — stored **inside a provider section**, matching the
original Phase 3 `[providers.<id>]` vision that M1/M2 flattened away.

## Scope

Introduce `[providers.<label>]` sections holding per-provider config: `default_model` and
`base_url`. This **consolidates** Ollama's `base_url` out of the flat top-level key into
`[providers.ollama].base_url`, and adds a command to set a provider's default model, used by
`/model list`, model-less `/model use`, and new-session selection.

Pre-alpha: no external configs to migrate. The flat `ollama_base_url` key is **removed**
(replaced by `[providers.ollama].base_url`). The global `default_provider` key stays; the
global `default_model` key stays as a backward-compat override but is no longer *seeded*.

## Config schema

```haskell
data ProviderConfig = ProviderConfig
  { pcDefaultModel :: Maybe Text
  , pcBaseUrl      :: Maybe Text   -- only meaningful for Ollama today
  } deriving stock (Eq, Show)

-- FileConfig: REMOVE fcOllamaBaseUrl; ADD:
fcProviders :: Map Text ProviderConfig   -- keyed by provider label ("ollama", "anthropic")
```

On disk:

```toml
default_provider = "ollama"      # unchanged (which provider new sessions use)

[providers.ollama]
base_url      = "http://localhost:11434"
default_model = "glm-5.2:cloud"

[providers.anthropic]
default_model = "claude-opus-4-8"
```

Codec (tomland 1.3.3.3, confirmed available):

```haskell
providerConfigCodec :: TomlCodec ProviderConfig
providerConfigCodec = ProviderConfig
  <$> Toml.dioptional (Toml.text "default_model") .= pcDefaultModel
  <*> Toml.dioptional (Toml.text "base_url")      .= pcBaseUrl

-- in fileConfigCodec (replaces the ollama_base_url line):
<*> Toml.tableMap Toml._KeyText (const providerConfigCodec) "providers" .= fcProviders
```

`Toml.tableMap` returns an empty `Map` when `[providers.*]` is absent, so `defaultFileConfig`
gets `fcProviders = Map.empty`. `fcDefaultProvider` and `fcDefaultModel` keys are kept.

## Resolution helpers

Split to avoid coupling `Registry` to `Config.File`:

```haskell
-- Seal.Config.File
providerDefaultModel :: FileConfig -> Text -> Maybe Text
providerDefaultModel cfg lbl = pcDefaultModel =<< Map.lookup lbl (fcProviders cfg)

providerBaseUrl :: FileConfig -> Text -> Maybe Text
providerBaseUrl cfg lbl = pcBaseUrl =<< Map.lookup lbl (fcProviders cfg)

-- Seal.Providers.Registry
resolveDefaultModel :: Maybe Text -> Text -> ModelId
resolveDefaultModel (Just m) _   = ModelId m
resolveDefaultModel Nothing  lbl =
  maybe (defaultModelFor AnthropicProvider) defaultModelFor (parseProvider lbl)
```

Effective default model for a provider = `resolveDefaultModel (providerDefaultModel cfg lbl) lbl`.
Effective Ollama base URL = `fromMaybe defaultOllamaBaseUrl (providerBaseUrl cfg "ollama")`.

## base_url readers (migrated)

The three sites that currently read `fcOllamaBaseUrl` switch to
`fromMaybe defaultOllamaBaseUrl (providerBaseUrl cfg "ollama")`:

- `Seal.Channel.Cli.resolveSessionProvider`
- `Seal.Command.Provider.testCmd`
- `Seal.Command.Model` (the `/model list <provider>` live branch)

Behavior is identical; only the config source changes (section instead of flat key).

## Command surface (`Seal.Command.Model`)

- **`/model default <provider> <model>`** — validates the provider (`parseProvider`; unknown →
  existing message, no write), then `updateFileConfig` sets
  `fcProviders[label].pcDefaultModel = Just model` (preserving that section's `pcBaseUrl`);
  confirms `"<provider> default model set to <model>"`.
- **`/model use <provider> [model]`** — the model argument becomes **optional**. Omitted ⇒ load
  config and use `resolveDefaultModel (providerDefaultModel cfg lbl) lbl`. Unknown provider still
  rejected with no session mutation.
- **`/model list`** — each provider line shows its effective default (configured section value
  or fallback). `/model list <provider>` (live models) unchanged.

## New-session selection (`Seal.Session.Store.defaultSessionSelection`)

```haskell
defaultSessionSelection cfg =
  ( provLabel
  , fromMaybe fallbackModel (fcDefaultModel cfg) )   -- global override still wins if present
  where
    provLabel = fromMaybe "anthropic" (fcDefaultProvider cfg)
    ModelId fallbackModel = resolveDefaultModel (providerDefaultModel cfg provLabel) provLabel
```

Precedence: global `default_model` (legacy/override) → `[providers.<provider>].default_model` →
hardcoded. Fresh configs (no global `default_model`) use the per-provider section.

## `/provider add` seeding (`Seal.Command.Provider`)

`/provider add <p>` seeds the provider **section** instead of flat keys:
- `fcProviders[p].pcDefaultModel = defaultModelFor p` when that section value is unset.
- For Ollama, the base-URL prompt writes `fcProviders["ollama"].pcBaseUrl` (when the user
  supplies a non-blank URL), replacing the old `fcOllamaBaseUrl` write.
- Still seeds `fcDefaultProvider` when unset. Stops seeding the global `fcDefaultModel`.

A single helper to upsert one field of a provider section keeps this and `/model default`
DRY, e.g.:

```haskell
upsertProvider :: Text -> (ProviderConfig -> ProviderConfig) -> FileConfig -> FileConfig
upsertProvider lbl f cfg =
  cfg { fcProviders = Map.insertWith (\_ old -> f old) lbl (f emptyProviderConfig) (fcProviders cfg) }
  where emptyProviderConfig = ProviderConfig Nothing Nothing
```

(`Map.insertWith` applies `f` to the existing section if present, else to an empty one.)

## Error handling

`Either Text`; unknown-provider reuses `unknownProviderMsg`. Config load/parse errors on a
write surface the tomland message (as `updateFileConfig` already does).

## Testing

**Pure:**
- `[providers.<label>]` TOML round-trip: parse a config with two provider sections (one with
  `base_url` + `default_model`, one with only `default_model`); encode `fcProviders` back;
  absent `[providers]` → empty map. `defaultFileConfig` has `fcProviders = Map.empty` and no
  `fcOllamaBaseUrl` field.
- `providerDefaultModel` / `providerBaseUrl`: hit / miss.
- `resolveDefaultModel`: configured value used; `Nothing` → per-provider hardcoded
  (`ollama`→`llama3.2`, `anthropic`→`claude-opus-4-8`); unknown label → Anthropic fallback.
- `defaultSessionSelection`: section default used when no global `default_model`; global
  `default_model` still wins when present.
- `upsertProvider`: inserts into an empty map; updates one field of an existing section without
  clobbering the other.

**IO with temp config:**
- `/model default ollama glm-5.2:cloud` writes `[providers.ollama].default_model`, preserving any
  existing `base_url`, and confirms.
- `/model use ollama` (no model) sets the session model to the configured default.
- `/model list` shows the configured default where set, fallback otherwise.
- `/provider add ollama` (base URL + key) writes `[providers.ollama].base_url` and seeds
  `[providers.ollama].default_model`; does not write flat `ollama_base_url` or global
  `default_model`.
- A base_url reader (e.g. `/provider test ollama`) uses `[providers.ollama].base_url`.

## Migration / compatibility

Pre-alpha; no external configs. The flat `ollama_base_url` key is removed. Existing global
`default_model` keeps working as an override. No data migration required.
