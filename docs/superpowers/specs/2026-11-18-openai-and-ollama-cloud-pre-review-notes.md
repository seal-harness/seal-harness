# Pre-review verification notes — OpenAI + Ollama Cloud

Independent checks run against the code before the design review gate returned,
so the design can be corrected against facts rather than reviewer guesses.

## V1 — The compiler does NOT catch every site (design §4/§7 was wrong)

`AGENTS.md`-style totality catches every **constructor** site. It does not catch
runtime **string** comparisons. These compare provider labels as text and will
silently change meaning after the `openai` → `openai-compatible` rename:

| Location | Comparison | Impact |
|---|---|---|
| `src/Seal/Setup/State.hs:294` | `label == "ollama"` | Correct as-is (readiness is Ollama-only). |
| `src/Seal/Command/Provider.hs:175` | `providerLabel kp == "ollama"` | Correct as-is. |
| `src/Seal/Command/Provider.hs:256` | `providerLabel kp == "ollama"` | Correct as-is. |
| `src/Seal/Command/Provider.hs:279` | `providerLabel kp /= "ollama"` | Correct as-is. |
| `src/Seal/Command/Provider.hs:291` | `providerLabel kp /= "anthropic"` | Correct as-is. |
| `src/Seal/Gateway/API.hs:3182` | `n == "ollama"` (readinessFields) | Correct as-is; must stay Ollama-only (D6). |
| `src/Seal/Gateway/API.hs:3246` | `typeId /= "openai"` | ⚠️ **BREAKS.** After the rename `typeId` for a custom instance is `"openai-compatible"`, so the guard no longer excludes real OpenAI. Must become `typeId /= "openai-compatible"`, and the `|| name == "ollama"` escape must be re-examined. |
| `src/Seal/Providers/Registry.hs:118` | `name \`elem\` ["anthropic","ollama","openrouter"]` | ⚠️ **MUST CHANGE** (D9). Stale list — also still missing nothing today, but after the change the set is six. |
| `src/Seal/Gateway/API.hs:715` | `"type" .= ("openai" :: Text)` | ⚠️ **MUST CHANGE** — custom instances emit `type: "openai"`, which after the rename means real OpenAI. |

**Design correction:** §7's risk row "Missed case in a total function over
`KnownProvider` … the compiler names every site" is true only for constructor
scrutiny. Add an explicit risk row for label string-comparison, and add
`API.hs:3246` and `API.hs:715` to §4's file table (they were implied by
"`customProviderDetailJson` type id → `openai-compatible`" but the readiness
guard was not).

## V2 — `providerReadinessSegment` / `withReadinessNote` are already safe

Both key on the literal `"ollama"`, and Ollama Cloud's label is `"ollama-cloud"`.
No substring matching is used, so Ollama Cloud correctly gets no readiness
segment. Confirmed by reading `Registry.hs:279` and `State.hs:294`. Worth a
regression test (design test 21/22 covers the card flags; add one asserting
`providerReadinessSegment OllamaCloudProvider == ""`).

## V3 — Error copy says "the OpenAI-compatible provider" for the new types

`resolveOpenAICompatible` (`Registry.hs:266-275`) hardcodes
`"the OpenAI-compatible provider \"" <> name <> "\" needs …"`. Delegating the
two new types to it produces, for real OpenAI with no key:

> the OpenAI-compatible provider "openai" needs an API key — run /vault setup
> then /provider add openai

That is confusing but **not wrong** (OpenAI *is* OpenAI-compatible). The
existing per-provider messages for Ollama/OpenRouter are written out by hand.
Decision needed: either (a) accept the generic wording, (b) parameterise
`resolveOpenAICompatible` with a display name, or (c) write the two new
constructors' error messages explicitly like Ollama/OpenRouter. The design
currently picks none. My preference is (b): one extra `Text` argument, callers
pass `providerLabel kp`, and it fixes the wording for all four users of the
helper at once — including custom instances, which today also say "the
OpenAI-compatible provider \"local-vllm\"" (acceptable) — with the smallest diff.

## V4 — `resolveProvider` for the new types must not reuse "openai" as the helper's name

`Registry.hs:241` calls `resolveOpenAICompatible mvh mgr "openai" …`. With
`OpenAICompatibleProvider`'s label becoming `"openai-compatible"`, that literal
must become `providerLabel OpenAICompatibleProvider` (or
`"openai-compatible"`). Otherwise the generic type's error messages and its
`configuredProviders` reasoning name the wrong provider. This is a **silent**
string literal the compiler will not flag — same class as V1.

## V5 — Icon proxy uses config-only base URL, so new providers 404 on icons

`handleProviderIconWith` (`API.hs:3505`) calls `providerBaseUrl cfg name` — the
**config-only** accessor with no built-in fallback — not `providerBaseUrlFor`.
Consequence: a provider whose endpoint is a built-in default and which has no
`[providers.<id>]` section returns
`404 "no base URL configured for this provider"`.

This is **pre-existing** (Anthropic has a built-in default and behaves this
way today, which is why Anthropic renders a lettered chip rather than a fetched
icon — see `ActiveTabs.tsx`'s `PROVIDER_BADGE`), so it is not a regression.
But it means design §4's "`ActiveTabs.tsx` — badge specs for `openai` and
`ollama-cloud`" is **load-bearing, not cosmetic**: because the icon proxy will
404 for both new providers unless the operator writes a config section, both
must have *bundled* badge specs (like `ollama` and `openrouter` already do),
not rely on the fetched-icon fallback. The design's §4 wording is right; §4
should state *why*, so an implementer does not "simplify" it away.

Note: an `openai-icon.svg` / reuse of the Ollama mark will be needed for
`ollama-cloud`. Reusing the Ollama mark for Ollama Cloud is correct (same brand).
OpenAI needs a bundled mark; if no asset is available, a lettered chip
(`char: 'O'`) is an acceptable, established pattern (Anthropic uses `char: 'A'`).

## V6 — `inferProviderId` is unaffected but incomplete

`src/Seal/Session/Kind.hs:79` maps `gpt` → `ProviderId "openai"`. After the
rename that now correctly means real OpenAI (it previously meant the generic
type — arguably the heuristic was already intended as real OpenAI). No change
required. Adding `gemma` → `ollama-cloud` is *not* appropriate: `gemma3:4b` is a
perfectly good **local** Ollama model, so the prefix does not disambiguate.
Correctly out of scope; worth one sentence in §6 so the omission is deliberate.

## V7 — Config migration does not exist, so D3.1 is a real decision

`src/Seal/Config/Migrate.hs` has no provider-section migration. Confirms D3.1's
"no automatic migration" is a genuine choice rather than an oversight, and that
adding one would be new machinery — correctly out of scope.

## V8 — `handleProviderDelete` deletes the Anthropic OAuth key unconditionally

`API.hs:3468-3469` does `vhDelete vh anthropicOAuthKey` for **every** provider
delete, not only Anthropic. Pre-existing bug, unrelated to this change, and
harmless when the vault has no Anthropic OAuth blob. **Out of scope** — but D3's
injectivity argument is what *prevents a new instance of this bug class* from
being introduced by sharing a vault key between `ollama` and `ollama-cloud`.
Do not "fix" the pre-existing bug in this PR (separate logical change); just
note it so a reviewer does not mistake it for a regression.

## V9 — Existing tests that assert the old names (must be UPDATED, not added)

- `test/Seal/Providers/RegistrySpec.hs:118-124` — `knownProviders` vector (4
  elements) and `providerLabel OpenAICompatibleProvider == "openai"`,
  `vaultKeyName … == "OPENAI_API_KEY"`, `parseProvider "openai" == Just …`.
- `test/Seal/Providers/RegistrySpec.hs:410` — `validateProviderName "openai"
  == Right ()` becomes `isLeft` (D9).
- `test/Seal/Providers/RegistrySpec.hs:422` — `vaultKeyNameForName "openai"
  == "OPENAI_API_KEY"` breaks: after the rename `openai` is a **built-in**, so
  `vaultKeyNameForName "openai"` returns the built-in key. Assertion needs a
  custom name instead (e.g. `local-vllm`). **This is a genuine semantic change
  the design did not call out.**
- `test/Seal/Setup/StateSpec.hs:118-129` — the 4-card vector, names, and
  `requires*` vectors → 6 cards.
- `test/Seal/Gateway/ApiSpec.hs:4465` — `byName` Map with 4 entries and
  `("openai", False)` → 6 entries.
- `test/Seal/Gateway/ApiSpec.hs:4838-4847, 4886, 4900` — custom-instance tests
  POST `type: "openai"` and assert `type: "openai"` echoed → `openai-compatible`.
- `test/Seal/Gateway/SetupApiSpec.hs:127-138` — `requires_base_url` test asserts
  `"openai"` is present with `True`; `openai` is now `False` and
  `openai-compatible` is the `True` one.
- `frontend/src/components/__tests__/ProvidersView.test.tsx:379+` — "requires a
  unique name when creating an OpenAI-compatible provider" selects
  `value: 'openai'` and expects the name input. Must select
  `'openai-compatible'`.
- `frontend/src/components/__tests__/providerStep.test.tsx:280-285` — card
  `id: 'openai'` with `requires_base_url: true` → `id: 'openai-compatible'`.
- `frontend/src/components/__tests__/ProviderBadge.test.tsx` — unaffected
  (uses `ollama`).
- `scripts/setup-walkthrough.sh:80,86` — POSTs `{"name":"openai", …}` expecting
  the generic behaviour. After the change `name: "openai"` is real OpenAI and
  the second call's `base_url` would override it. Must be re-keyed to
  `openai-compatible` (or a custom name) or the walkthrough tests the wrong
  thing.

**Design correction:** §5 lists 40 *new* tests but §4/§5 do not budget for these
*updates*. Add an explicit "existing tests to update" section; the plan phase
must treat them as work, not surprises.
