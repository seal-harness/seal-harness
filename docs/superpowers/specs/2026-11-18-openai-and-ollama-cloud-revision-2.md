# Design revision 2 — decisions taken

Resolutions for every open question the CTO review raised. Each is a decision,
not further analysis, so the plan phase can proceed once the gate closes.

## R1 — `Registry.hs:242` literal (CTO Q1) → pass the label

Change

```haskell
resolveProvider mvh mgr cfg OpenAICompatibleProvider model _ =
  resolveOpenAICompatible mvh mgr "openai"
    (providerBaseUrlFor cfg OpenAICompatibleProvider)
    (vaultKeyName OpenAICompatibleProvider) model
```

to pass `providerLabel OpenAICompatibleProvider`. The helper uses that string to
name the config section in its fail-closed message ("set
`[providers.<name>] base_url`"). It must therefore be the **label**, which is
also the config key — not a literal that will drift.

New §5 item: assert the error text contains `openai-compatible` **and** does not
contain `[providers.openai]` (word-boundary), because a naive `isInfixOf`
cannot tell the two apart (`"openai-compatible"` contains `"openai"`).

## R2 — `gpt-4o` / `gemma4:31b` context windows (CTO Q2) → shrink the list, accept 0

**Verified:** `modelContextWindow :: Text -> Int` (`ContextWindow.hs:17`), unknown
⇒ `0`. `"gpt-4o-"` has a trailing dash (`:22`), so bare `gpt-4o` ⇒ 0. No
`gemma` clause ⇒ `gemma4:31b` ⇒ 0.

**Verified:** a 0 is *not* rendered as a misleading "0". `BottomBar.tsx:37`
guards the whole usage block with `contextWindow > 0` and renders only the raw
token count otherwise. `ChatArea.tsx:2940` does the same. So a 0 context window
degrades to "no percentage shown", which is honest — it does not claim 0.

**Decision:**
- OpenAI's `staticModelsFor` = `["gpt-4o-mini", "gpt-4-turbo"]` — both already
  have clauses. Drop `gpt-4o` so the list publishes nothing the table cannot
  size. No new context numbers invented; `ContextWindow.hs` is **not** touched.
- Ollama Cloud's `staticModelsFor` stays `[]`.
- `gemma4:31b` stays as `defaultModelFor OllamaCloudProvider`. A default model
  need **not** appear in the static model *list* (the list is only the
  new-tab suggestion set), and its 0 context window renders no percentage — the
  same state as any custom endpoint's models today.

Consequence: §5 item 32 is restated as "every id in `staticModelsFor
OpenAIProvider` has a **non-zero** `modelContextWindow`" — expressible against
the real `Int` signature — and `ContextWindow.hs` is removed from §4.

## R3 — `ProviderStep.tsx` POST body (CTO B1) → real bug, fixed

`ProviderStep.tsx:147` sends `type: 'openai'` for a custom instance. Post-rename
`resolveCreateTarget` (`API.hs:3367`) requires `"openai-compatible"` ⇒ 400.

Fix: send `type: 'openai-compatible'`. §4's row for this file changes from
"reserved-name array" to "reserved-name array **and** the `saveKey` POST body's
`type`". New §5 item: a wizard test that posts a custom instance and asserts the
request body carries `type: 'openai-compatible'`.

This was the most serious miss: the wizard's custom-endpoint flow would have
broken with the suite fully green.

## R4 — `scripts/setup-walkthrough.sh` (CTO B6) → re-key, and it is a risk instance

Steps 8b–8f POST `{"name":"openai", …}` expecting the generic type's
fail-closed behaviour. Post-rename `name: "openai"` is **real OpenAI**, so:

- 8b (`api_key` only, no `base_url`) now **succeeds** instead of failing closed;
- 8c's `POST /api/providers/openai/test` then performs a **real request to
  `https://api.openai.com/v1`** carrying `sk-local`.

That is precisely the D3.1 case-3 egress, reproduced in a script that developers
run. Re-key the whole block to a custom name (e.g. `local-vllm` with
`type: "openai-compatible"`), which preserves the original intent (fail closed
without an endpoint) and removes the egress.

## R5 — §5 split into RED and GUARD

Every item labelled. Items that pass before any implementation are GUARD, not
RED — including 12, 20, 31, 35, 36, 37, 38. Items 2 and 3 are rewritten
property-shaped exactly like 19 (over `map providerLabel knownProviders` /
`map vaultKeyName knownProviders`, which auto-extend because
`knownProviders = [minBound .. maxBound]`), so a future constructor is covered
without editing the test.

## R6 — Existing tests to UPDATE get their own section

`RegistrySpec` (4-element vector; `providerLabel`/`vaultKeyName`/`parseProvider`
for the generic type; `validateProviderName "openai"` → `isLeft`;
`vaultKeyNameForName "openai"` now the built-in key; the `openAICfg` fixture
re-keyed to `openai-compatible`, which un-breaks the four
`resolveProvider`/`configuredProviders` tests), `StateSpec` (4-card → 6-card
vectors), `ApiSpec` (4-entry `byName`; custom-instance POST bodies and `type`
echoes), `SetupApiSpec` (`hasBoolField` is a whole-body substring helper at
`:626-628`, so its paired `True`/`False` assertions both stay green while
per-provider semantics invert — replace with per-provider assertions),
`ProvidersView.test.tsx`, `providerStep.test.tsx`, `setup-walkthrough.sh`.

## R7 — Work units (CTO suggestion, adopted)

- **WU1** `Registry.hs` + `RegistrySpec`. Independently green; pure.
- **WU2** `Setup/State.hs` + `StateSpec` + `SetupApiSpec`. Independently green
  (new cards render as raw ids until WU3 lands the labels — degraded, not
  broken).
- **WU3** Irreducible atomic unit: `resolveCreateTarget` / `resolveExistingTarget`
  / `customProviderDetailJson` / `providerAuthStatus` / `staticModelsFor` +
  `types.ts` + `ProvidersView.tsx` + `ProviderStep.tsx` + their tests. It cannot
  be split because `file-embed` ships client and server together: `type:
  "openai"` for a custom name must start and stop being valid in one commit.

## R8 — §4 corrections

Remove `providerTypeForName` (already `fromMaybe OpenAICompatibleProvider`,
correct post-rename) and `handleProvidersAll` (already correct). Add
`API.hs:3246` (readiness guard), `API.hs:715` (custom `type`), `CHANGELOG.md`,
`scripts/setup-walkthrough.sh`. `ContextWindow.hs` stays out (R2).

## R9 — §7 risk row rewritten

Replace "the compiler names every site" with the truth: totality catches
constructor scrutiny only; label **string** comparisons are compiler-blind, and
the enumerated list of them (`Registry.hs:242`, `API.hs:715`, `API.hs:3246`,
`ProvidersView.tsx:247`, `Registry.hs:118`, plus the already-correct `"ollama"`
comparisons in `State.hs:294` / `Provider.hs:175,256,279` / `API.hs:3182`) is the
mitigation.

## R10 — CHANGELOG covers both migrations

Not just `[providers.openai]`, but also `[providers.ollama] base_url =
"https://ollama.com"` → `ollama-cloud` gains the OpenAI-compatible path (the
headline motivation in §1).

## R11 — Minor

- D2 states that `knownProviders` order **is** constructor declaration order
  (derived `Enum`/`Bounded`), so the order is expressed structurally.
- §5 items 17/18 drop the unobservable "never a network call" clause.
- `inferProviderId` (`Kind.hs:79`) has no callers and now means real OpenAI;
  leave it, note it. Not deleted here (unrelated change).
- New code writes `=` unpadded (AGENTS.md), unlike the existing padded
  `Registry.hs`. Do not add a third precedent.
- `ProvidersView.tsx:247` custom-ness: once `requiresBaseUrl`/`requiresName`
  exist on `ProviderDetail`, prefer them over `PROVIDER_LABELS` membership.
