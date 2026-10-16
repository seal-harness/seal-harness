# Implementation Plan: OpenRouter Provider

## Dependency & Cabal Changes
- Add `openai >=2.5.4` to `build-depends:` in `seal-harness.cabal`.
- Add `exposed-modules:` entry for `Seal.Providers.OpenRouter` and test-module `Seal.Providers.OpenRouterSpec`.

## Work Unit 1: Provider File & Cabal
- Create `src/Seal/Providers/OpenRouter.hs` (new file) implementing `Provider` class (`complete`/`listModels`) using `openai` package (v2.5.4, non-servant interface).
- Base URL: `https://openrouter.ai/api/v1`.

## Work Unit 2: Registry & Wiring
- Add `OpenRouterProvider` to `KnownProvider` in `Seal.Providers.Registry`; update `providerLabel`, `providerId`, `defaultModelFor`, `resolveProvider`, `configuredProviders`, `seedProviderDefaults`.
- Cross-file integration: `Seal.Providers.Registry` imports new module; `Seal.Command.Provider` uses `resolveProvider` for new provider label; frontend already references `"openrouter"` in `PROVIDER_LABELS`.
- Create `test/Seal/Providers/OpenRouterSpec.hs` (new file) with QuickCheck properties for authorization and JSON schema round-trip.
- Wire `.cabal`: add module names, library/test-suite entries.
- Wire `test/Main.hs`: add `OpenRouterSpec` to import/test list.
- Backward compatibility: existing Anthropic/Ollama providers untouched; new provider opt-in only.
- Verification: `make build` clean; `cabal list --installed` shows `openai`; `make test` includes new spec.

## Work Unit 3: Security & Tests (TDD)
- TDD: `test/Seal/Providers/OpenRouterSpec.hs` — failing test first asserts `complete` returns `Left` when vault missing; minimal implementation passes.
- Edge cases verified: vault locked → `VaultLocked` handled; API key corrupt/missing → `Left` with user-facing message; network failure → retry policy (`RetryPolicyM`) applied (reuses `providerStreamWithRetry` / `streamRetryPolicy`).
- Security: `orRecorded` never includes `OPENROUTER_API_KEY`; `recorded` stores only `{provider: "openrouter", model: ...}`; no file writes to `~/.seal/` (only vault `vhPut`/`vhGet` for key storage). Confirmed by code inspection (`grep -r '~/.seal' src/` returns only admin command paths, not provider code).
- Rollback: removing provider deletes vault key via `/provider remove openrouter`; no persistent state outside vault/config.

## Verification
- `make build` passes (`-Werror` clean).
- `make test` passes.
- `make lint` clean (`hlint` reports no hints).
- `make check` passes.
