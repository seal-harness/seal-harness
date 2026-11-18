# Implementation Plan — OpenAI and Ollama Cloud provider types

<!-- design: docs/superpowers/specs/2026-11-18-openai-and-ollama-cloud-provider-design.md (approved 5/5, round 4) -->
<!-- branch: providers/openai-and-ollama-cloud -->
<!-- drafted: 2026-11-18 -->
<!-- gate: pending (this plan has not yet passed the Plan Review Gate) -->

## Verified baseline (measured on this branch, not assumed)

Every row was produced by running a command in this worktree while drafting.

| Fact | How verified | Result |
|---|---|---|
| `make check` runs build + test + lint + **frontend-test** | `grep -nE '^(check\|test\|lint\|build)' Makefile` | `check: build test lint frontend-test` (`Makefile:39`) |
| Frontend unit tests are vitest | `frontend/package.json` scripts | `"test": "vitest run"` |
| Coverage thresholds are **not measured** | `.coverage-thresholds.json` `$comment-project` | HPC not wired in; `enforcement.command` is `make test` and the 95% figures are explicitly "aspirational (not measured)" |
| Registry test module is `Seal.Setup.**StateSpec**` | `seal-harness.cabal:686` + `ls test/Seal/Setup/` | `StateSpec.hs`. There is **no** `SetupStateSpec` |
| `RegistrySpec` / `SetupApiSpec` names | `seal-harness.cabal:683,687` | present |
| Frontend specs that exist | `ls frontend/src/components/__tests__/` | `ProvidersView.test.tsx`, `providerStep.test.tsx`, `ProviderBadge.test.tsx` |
| `providerLabel OpenAICompatibleProvider` | `Registry.hs:88` | `= "openai"` |
| `providerLabel` for the other three | `Registry.hs:85,86,87` | `anthropic`, `ollama`, `openrouter` |
| `vaultKeyName OpenAICompatibleProvider` | `Registry.hs:143` | `= "OPENAI_API_KEY"` |
| `defaultModelFor OpenAICompatibleProvider` | `Registry.hs:163` | `= ModelId "gpt-4o-mini"` |
| `providerBaseUrlFor`/`resolveProvider` call sites for the generic type | `Registry.hs:244,373` | `resolveProvider` passes literal `"openai"`; `configuredProviders` uses `vaultKeyName` |

## Gate status — read this first

This plan has **not** passed the Plan Review Gate. It is submitted to it in the
next step. Nothing below is claimed as reviewed.

## What this plan implements

Two new provider types that reuse the existing OpenAI-compatible client, with
built-in endpoints and their Base URL / Unique name fields **hidden entirely**:

| Type | id | base URL | vault key |
|---|---|---|---|
| `OpenAIProvider` | `openai` | `https://api.openai.com/v1` | `OPENAI_API_KEY` |
| `OllamaCloudProvider` | `ollama-cloud` | `https://ollama.com/v1` | `OLLAMA_CLOUD_API_KEY` |

The generic type is renamed `openai` → **`openai-compatible`**
(`OPENAI_COMPATIBLE_API_KEY`), per the operator's explicit decision.

## Work units (from the approved design §5.6, unchanged)

Three units. **WU1 and WU3 are separate commits; WU2 is downstream of WU1 and
must land after it.** WU3 is irreducible because `file-embed` ships client and
server together, so `type: "openai"` must start and stop being valid for a custom
name in one commit.

### WU1 — the `KnownProvider` vocabulary sweep (backend, pure)

**Why one commit:** `-Wall` implies `-Wincomplete-patterns` and `-Werror` is on
for the whole library, so adding two constructors breaks the build at **nine**
wildcard-free sites simultaneously. There is no smaller green commit.

Files:
- `src/Seal/Providers/Registry.hs` — constructors + all total functions;
  `resolveProvider OpenAICompatibleProvider`'s literal `"openai"` → `providerLabel
  OpenAICompatibleProvider`; `resolveOpenAICompatible` gains separate
  (id, displayNoun, hasBuiltInEndpoint) parameters; the §3.1 case-3 guard.
- `src/Seal/Gateway/API.hs` — **only** `providerAuthStatus` (`:3259`) and
  `staticModelsFor` (`:3824`), two additive equations each.
- `src/Seal/Setup/State.hs` — **only** `providerDisplayName` (`:352`), two
  additive equations.
- `test/Seal/Providers/RegistrySpec.hs` — new items + the four updates.

TDD order (RED then GREEN, per item):
1. Write the failing assertions for design items **1-21, 20b, 20c** and the
   `RegistrySpec` updates (`:88-93`, `:118-124`, `:297`, `:410`, `:422`).
2. Add the constructors and make each site total until the suite is green.
3. `make build && make test && make lint`.

**DoD:** `make build` clean under `-Werror`; `make test` green; `make lint`
reports "No hints"; design items 1-21, 20b and 20c all pass.

**Explicitly NOT in WU1:** `resolveCreateTarget`, `resolveExistingTarget`,
`customProviderDetailJson`, the `:715` literal, the `:3246` readiness guard, the
create-path `base_url` injection (all WU3); `providerCards`/P4 copy (WU2).

### WU2 — card flags, copy, and the setup wire (backend, after WU1)

Files:
- `src/Seal/Setup/State.hs` — the remainder: P4 copy, and confirm
  `providerCards`' existing `_ ->` wildcards already yield `requiresBaseUrl =
  False` / `pcReadiness = Nothing` for the new types (no change expected; this
  is a verification, not an edit).
- `test/Seal/Setup/StateSpec.hs` — 4-card vectors → 6-card.
- `test/Seal/Gateway/SetupApiSpec.hs` — per-card assertions replacing the
  whole-body `hasBoolField` pair (`:127-138`).

TDD order: write design items **22-24** failing (six cards, flag vectors,
per-card `GET /api/setup`), then update.

**DoD:** items 22-24 pass; `make test` green.
**Depends on:** WU1 (cannot compile before it).

### WU3 — the wire rename + both forms, atomically

Files:
- `src/Seal/Gateway/API.hs` — `resolveCreateTarget` / `resolveExistingTarget`
  type ids and the required-type check; `customProviderDetailJson` type id;
  the `:715` `customInfos` literal; the `:3246` readiness guard; the create-path
  `base_url` injection (`supplied >>= nonEmpty <|> providerBaseUrlFor`);
  `providerDetailJsonFor` gains `requiresBaseUrl`/`requiresName`.
- `src/Seal/Gateway/Setup.hs` — the "known providers" hint text.
- `src/Seal/Command/Provider.hs` — `addCmd` writes the built-in `base_url`,
  constructor-scoped **and** absence-scoped.
- `frontend/src/types.ts`, `lib/providerLabels.ts`, `ProvidersView.tsx`,
  `ProviderFormFields.tsx`, `setup/ProviderStep.tsx`, `ProviderModelFields.tsx`,
  `AgentsView.tsx`, `ActiveTabs.tsx`, `lib/setupSteps.ts` - **comment only,
  verified**: that file contains no provider-id literals
  (`grep -nE 'openai|anthropic|ollama|openrouter'` returns nothing), so the
  `requires_*` parsing needs no change.
- `test/Seal/Gateway/ApiSpec.hs`, `test/Seal/Setup/StateSpec.hs` (card flags).
- `test/Seal/Command/ProviderSpec.hs` - **verified necessary, not optional**:
  `addCmd` is covered at `:82` ("add stores the key and seeds defaults when
  unset", fixture `anthropic`). It needs a sibling for `openai` asserting the
  built-in `base_url` is written, plus the case-1 case (design item 35k) that
  an existing URL is kept. The existing `anthropic` test must stay green:
  `anthropic` also has a built-in endpoint, so the scoped write applies to it,
  and that fixture asserts nothing about `base_url` today.
- `frontend/src/components/__tests__/ProvidersView.test.tsx`,
  `providerStep.test.tsx`.
- `CHANGELOG.md`, `config/templates/config.toml`, `scripts/setup-walkthrough.sh`.

TDD order: write design items **25-39, 34a-34d, 35b-35k, 41b, 41c, 45, 45b**
failing, then implement.

**DoD:** all of those pass; `make check` green end to end (build + test + lint +
frontend-test).

## Requirement → item mapping

| Operator requirement (verbatim) | Plan item(s) |
|---|---|
| "add two more provider types … Ollama Cloud, and OpenAI" | WU1 constructors; items 1-9 |
| "shown in the setup wizard's `Choose an LLM provider` form" | WU2 items 22-24; WU3 wizard items 43, 44 |
| "and in the new provider form on the providers page" | WU3 items 34, 35, 34a-34d |
| "both use the OpenAI-compatible API infrastructure" | WU1: both delegate to `resolveOpenAICompatible`; item 18/19 name the right provider |
| "hard code the Base URL … fields" | WU1 items 10-12; WU3 create-path injection; guard 35f/35g/35i |
| "… and Unique name fields" | WU1 `requiresName = False` for both (item 23); WU3 hides the input (34, 34a) |
| "appropriately for those providers" | D2/D3 tables; `ollama-cloud` needs a key, keyless mode forbidden (items 14-16) |
| (operator follow-up) "Hidden entirely" | D7 visibility table; guards 41b (Ollama still shown) / 41c (custom still shown) |

## Cross-file integration points (verified)

- `seal-harness.cabal` — no new module, so **no** `exposed-modules` or
  `other-modules` edit is needed. (Confirmed: all edited modules already listed.)
- `test/Main.hs` — no new spec module, so no edit. (Confirmed: same.)
- The four duplicate `PROVIDER_LABELS` maps are each edited in place; **merging**
  them is an explicit non-goal (design §6).
- `scripts/setup-walkthrough.sh` steps 8b-8f must be re-keyed in the same commit
  as WU3, or the script performs the case-3 egress it is meant to illustrate.

## Verification

Per-unit as above; whole change: `make check` (the CI-equivalent local gate) must
be green, and CI runs the same gate on Linux + macOS.

Coverage: `.coverage-thresholds.json`'s enforcement command is `make test`, and
its own metadata states the 95% thresholds are **not measured** (HPC not wired
in). So "coverage gate" here means "the suite passes", which this plan states
plainly rather than claiming a number it cannot produce.

## Risks and rollback

| Risk | Mitigation |
|---|---|
| A missed wildcard-free site breaks the build | WU1 is one commit precisely so the compiler reports them together; the nine are enumerated in design §5.6. |
| The rename breaks a runtime string comparison the compiler cannot see | The five such sites are enumerated in design §7 and each has a test. |
| A hidden field leaks a stale value into the payload | Payload gated on `!isHiddenBaseUrl`; items 35d, 41b. |
| **Rollback** | The change is additive plus one rename. Reverting the WU3 commit restores the old `openai` meaning; WU1/WU2 can be reverted independently *only* as a set (the constructors are what break the build if reverted alone). |
| Backward compatibility | The one behaviour change is documented in `CHANGELOG.md` as four facts; no automatic config migration (design §3.1). |

## Out of scope

Everything in the approved design's §6 non-goals. Notably: no readiness probing
for Ollama Cloud, no config migration, no label-map consolidation, no
`ContextWindow` change, no `authLabel` fix, no `handleProviderDelete`
`anthropicOAuthKey` fix, no `inferProviderId` change, no streaming work.
