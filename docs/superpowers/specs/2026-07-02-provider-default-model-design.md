# Phase 3, M3 follow-up: per-provider default model (`[providers.<label>]`)

Date: 2026-07-02
Status: DESIGN — awaiting user approval
Parent: `docs/superpowers/specs/2026-07-02-ollama-provider-design.md`

## Motivation

`/model list` shows each provider's default model, but that value is the hardcoded
`defaultModelFor` (`llama3.2` for Ollama, `claude-opus-4-8` for Anthropic) — a compile-time
placeholder the user cannot change. Config only has a single **global** `default_model`.
The user wants to set a provider's default model, stored **inside a provider section** of
the config (the natural, extensible home, matching the original Phase 3 `[providers.<id>]`
vision that M1/M2 flattened away).

## Scope

**In scope:** introduce `[providers.<label>]` sections carrying `default_model`; a command
to set it; use it for `/model list`, model-less `/model use`, and new-session selection.

**Out of scope (separate follow-up, offered not assumed):** moving the existing flat
`ollama_base_url` into `[providers.ollama].base_url`. It stays flat for now so this change
does not touch the just-verified Ollama send path. The section codec is designed so
`base_url` can be added to `ProviderConfig` later with no schema churn.

## Config schema

New per-provider record and a map of them, keyed by provider label:

```haskell
newtype ProviderConfig = ProviderConfig
  { pcDefaultModel :: Maybe Text }        -- room to grow (base_url later)
  deriving stock (Eq, Show)

-- added to FileConfig:
fcProviders :: Map Text ProviderConfig    -- keyed by provider label ("ollama", "anthropic")
```

On disk:

```toml
default_provider = "ollama"      # unchanged (which provider new sessions use)

[providers.ollama]
default_model = "glm-5.2:cloud"

[providers.anthropic]
default_model = "claude-opus-4-8"
```

Codec (tomland 1.3.3.3, confirmed available):

```haskell
providerConfigCodec :: TomlCodec ProviderConfig
providerConfigCodec = ProviderConfig
  <$> Toml.dioptional (Toml.text "default_model") .= pcDefaultModel

-- in fileConfigCodec:
<*> Toml.tableMap Toml._KeyText (const providerConfigCodec) "providers" .= fcProviders
```

`Toml.tableMap` returns an empty `Map` when `[providers.*]` is absent, so `defaultFileConfig`
gets `fcProviders = Map.empty`. The existing `fcDefaultProvider` and `fcDefaultModel` keys
are **kept** (backward compatible); `fcDefaultModel` remains a global override (see
selection below) but is no longer *seeded* by `/provider add`.

## Resolution

Two small helpers, split to avoid coupling `Registry` to `Config.File`:

```haskell
-- Seal.Config.File
providerDefaultModel :: FileConfig -> Text -> Maybe Text
providerDefaultModel cfg lbl = pcDefaultModel =<< Map.lookup lbl (fcProviders cfg)

-- Seal.Providers.Registry
resolveDefaultModel :: Maybe Text -> Text -> ModelId
resolveDefaultModel (Just m) _   = ModelId m
resolveDefaultModel Nothing  lbl =
  maybe (defaultModelFor AnthropicProvider) defaultModelFor (parseProvider lbl)
```

A provider's effective default model = `resolveDefaultModel (providerDefaultModel cfg lbl) lbl`
= the configured section value, else the hardcoded fallback.

## Command surface (`Seal.Command.Model`)

- **`/model default <provider> <model>`** — validates the provider (`parseProvider`; unknown →
  the existing message, no write), then `updateFileConfig` to set
  `fcProviders[label].pcDefaultModel = Just model`; confirms `"<provider> default model set to
  <model>"`.
- **`/model use <provider> [model]`** — the model argument becomes **optional**. Omitted ⇒
  load config and use `resolveDefaultModel (providerDefaultModel cfg lbl) lbl`. Unknown provider
  still rejected with no session mutation (unchanged).
- **`/model list`** — each provider line shows its effective default (configured section value
  or fallback) instead of the raw hardcoded value. `/model list <provider>` (live models) is
  unchanged.

## New-session selection (`Seal.Session.Store.defaultSessionSelection`)

```haskell
defaultSessionSelection cfg =
  ( provLabel
  , fromMaybe fallbackModel (fcDefaultModel cfg) )   -- global override still wins if present
  where
    provLabel = fromMaybe "anthropic" (fcDefaultProvider cfg)
    ModelId fallbackModel = resolveDefaultModel (providerDefaultModel cfg provLabel) provLabel
```

Precedence: explicit global `default_model` (legacy/override) → `[providers.<provider>].default_model`
→ hardcoded. For a fresh config (no global `default_model`), the per-provider section governs.

## `/provider add` seeding (`Seal.Command.Provider`)

Change the default-seeding so `/provider add <p>` seeds `fcProviders[p].pcDefaultModel =
defaultModelFor p` (only when that section value is unset) instead of the global
`fcDefaultModel`. It still seeds `fcDefaultProvider` when unset. This keeps the per-provider
section authoritative and prevents a stale global `default_model` from shadowing a later
`/model default`.

## Error handling

`Either Text`; unknown-provider reuses `unknownProviderMsg`. A config load/parse error on
`/model default` surfaces the tomland message (as `updateFileConfig` already does).

## Testing

**Pure:**
- `[providers.<label>]` TOML round-trip: parse a config with two provider sections; encode a
  `fcProviders` map back; absent `[providers]` → empty map.
- `providerDefaultModel`: hit / miss.
- `resolveDefaultModel`: configured value used; `Nothing` → per-provider hardcoded
  (`ollama`→`llama3.2`, `anthropic`→`claude-opus-4-8`); unknown label → Anthropic fallback.
- `defaultSessionSelection`: section default used when no global `default_model`; global
  `default_model` still wins when present.

**IO with temp config:**
- `/model default ollama glm-5.2:cloud` writes `[providers.ollama].default_model` and confirms.
- `/model use ollama` (no model) sets the session model to the configured default.
- `/model list` shows the configured default for a provider that has one, fallback otherwise.
- `/provider add ollama` seeds `[providers.ollama].default_model` (not global `default_model`).

## Migration / compatibility

Pre-alpha; no external configs. Existing configs with a global `default_model` keep working
(it wins in selection). `ollama_base_url` unchanged. No data migration required.
