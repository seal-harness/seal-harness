# Implementation Plan — OpenAI and Ollama Cloud provider types

<!-- design: docs/superpowers/specs/2026-11-18-openai-and-ollama-cloud-provider-design.md (revision 6 — approved, re-ratified) -->
<!-- branch: providers/openai-and-ollama-cloud -->
<!-- drafted: 2026-11-18, rewritten for revision 6 -->
<!-- gate: Plan Review Gate PASSED 3/3 on revision 6 (feasibility, completeness, scope) -->

## Gate status

**Plan Review Gate: 3/3 PASS** on this text.

| Reviewer | Verdict | Independently re-verified here, not taken on trust |
|---|---|---|
| Feasibility | PASS | `-Wall -Werror` is in `common settings` (`seal-harness.cabal:33`) and imported by all three library stanzas (`:116`, `:45`, `:79`); no `-Wno-error` override anywhere; no `OPTIONS_GHC` in the three touched files. Proven empirically as well: a 3-constructor/2-equation module compiled under these exact flags fails with `[-Wincomplete-patterns, Werror=...]`. The plan's central "no smaller green commit" premise therefore rests on the build system, not on assertion. |
| Completeness | PASS | `frontend/src/lib/setupSteps.ts` carries no provider-id literal (comments only); `src/Seal/Command/Provider.hs` has no `case kp of` at all — only runtime string comparisons, which `-Wincomplete-patterns` cannot see — so the two new constructors provably cannot break it; `scripts/setup-walkthrough.sh` 8b-8f exist and POST `name:openai` at `:80` and `:86`; the removed items (20b, 20c, 35e-35k, 45b) pinned only deleted work, so no requirement is orphaned. |
| Scope & Alignment | PASS | All three units trace to the request or the nine-site compile prerequisite. `handleProviderCreate`, `handleProviderUpdate`, `Command/Provider.hs` and any case-3 guard appear only in the deletion table, the UNCHANGED assertion, and the out-of-scope list — never in a unit's file list. |

Note on the gate itself, recorded rather than hidden: feasibility and
completeness each timed out on their first, broad prompt and returned PASS on a
narrowed one; scope timed out twice. The verdicts above are from the narrowed
runs. Two of three reviewers producing no verdict is not a gate, so the retries
were narrowed to a single question each instead of re-run identically.

## Verified baseline (measured on this branch, not assumed)

Every row was produced by running a command in this worktree.

| Fact | How verified | Result |
|---|---|---|
| `make check` runs build + test + lint + **frontend-test** | `grep -nE '^(check\|test\|lint\|build)' Makefile` | `check: build test lint frontend-test` (`Makefile:39`) |
| Frontend unit tests are vitest | `frontend/package.json` scripts | `"test": "vitest run"` |
| Coverage thresholds are **not measured** | `.coverage-thresholds.json` `$comment-project` | HPC not wired in; `enforcement.command` is `make test` and the 95% figures are "aspirational (not measured)" |
| Registry test module is `Seal.Setup.**StateSpec**` | `seal-harness.cabal:686` + `ls test/Seal/Setup/` | `StateSpec.hs`. There is **no** `SetupStateSpec` |
| `providerLabel OpenAICompatibleProvider` | `Registry.hs:88` | `= "openai"` |
| `vaultKeyName OpenAICompatibleProvider` | `Registry.hs:143` | `= "OPENAI_API_KEY"` |
| `defaultModelFor OpenAICompatibleProvider` | `Registry.hs:163` | `= ModelId "gpt-4o-mini"` |
| `resolveProvider` passes a literal for the generic type | `Registry.hs:241-244` | `resolveOpenAICompatible mvh mgr "openai" …` — the string that names the config section |
| `handleProviderCreate` calls `upsertProvider` unconditionally | `API.hs:3316-3340` | Seeds `default_model`, so a section is always written — **now the intended shape (§3.1)** |
| `resolveOpenAICompatible` noun | `Registry.hs:268-274` | hardcodes `"the OpenAI-compatible provider"` as the quoted subject |

## Scope change since the previous plan (read this first)

The operator re-ratified the `openai` rename and stated there are **no users**
(design D1). That is not only a waiver of backward compatibility: it makes the
pre-existing-`[providers.openai]` case-3 state **unreachable**, so the
fail-closed guard and the three write paths that existed to keep the guard from
dead-ending its own happy path are **removed** (design §3.1).

Deleted from this plan versus the previous draft:

| Deleted | Was |
|---|---|
| The case-3 guard in `resolveProvider OpenAIProvider` | Design §3.1 |
| Create-path `base_url` injection in `handleProviderCreate` | WU3 |
| `PUT` repair matrix in `handleProviderUpdate` | WU3 |
| `addCmd`'s `base_url` write, constructor- and absence-scoped | WU3 |
| Two-parameter `resolveOpenAICompatible` (`hasBuiltInEndpoint`) | WU1 |
| Design items 20b, 20c, 35e, 35f, 35g, 35h, 35i, 35j, 35k, 45b | §5 |

**`handleProviderCreate`, `handleProviderUpdate`, `Command/Provider.hs` and
`resolveOpenAICompatible`'s signature are now UNCHANGED by this change.**

This is what the Plan Review Gate's scope reviewer was blocking on. Its blocker
("the guard is unrequested work") is resolved by deletion, not by rebuttal.

## What this plan implements

Two new provider types reusing the existing OpenAI-compatible client, with
built-in endpoints, their Base URL / Unique name fields **hidden entirely**:

| Type | id | base URL | vault key |
|---|---|---|---|
| `OpenAIProvider` | `openai` | `https://api.openai.com/v1` | `OPENAI_API_KEY` |
| `OllamaCloudProvider` | `ollama-cloud` | `https://ollama.com/v1` | `OLLAMA_CLOUD_API_KEY` |

The generic type is renamed `openai` → **`openai-compatible`**
(`OPENAI_COMPATIBLE_API_KEY`), per the operator's re-ratified decision.

## Work units (design §5.6)

Two units. **WU1 and WU3 are separate commits; there is no WU2 dependency chain
beyond WU1.** WU3 is irreducible because `file-embed` ships client and server
together, so `type: "openai"` must start and stop being valid for a custom name
in one commit.

> The design's §5.6 still labels the setup-state unit "WU2". It is kept as a
> **label only** here, folded into the WU3 commit's predecessors below, because
> its file is `Setup/State.hs` and WU1 already owns one function in that file.

### WU1 — the `KnownProvider` vocabulary sweep (backend, pure)

**Why one commit:** `-Wall` implies `-Wincomplete-patterns` and `-Werror` is on
for the whole library, so adding two constructors breaks the build at **nine**
wildcard-free sites simultaneously. There is no smaller green commit.

Files:
- `src/Seal/Providers/Registry.hs` — +2 constructors; all total functions;
  `resolveProvider OpenAICompatibleProvider`'s literal `"openai"` →
  `providerLabel OpenAICompatibleProvider`; `resolveOpenAICompatible`'s message
  noun `"the OpenAI-compatible provider"` → `"provider"` (**signature unchanged**;
  both new callers pass a never-empty base URL, so its `T.null baseUrl` branch is
  unreachable for them). **No guard.**
- `src/Seal/Gateway/API.hs` — **only** `providerAuthStatus` (`:3259`) and
  `staticModelsFor` (`:3824`), two additive equations each.
- `src/Seal/Setup/State.hs` — **only** `providerDisplayName` (`:352`), two
  additive equations.
- `test/Seal/Providers/RegistrySpec.hs` — items 1-21 (less removed 20b/20c) plus
  the four `RegistrySpec` updates.
- `test/Seal/Gateway/ApiSpec.hs` and `test/Seal/Setup/StateSpec.hs` — **found
  during execution, not in the original WU1 file list.** The 4-entry `byName`
  provider map (`ApiSpec.hs:4460-4466`) and the 4-card vector
  (`StateSpec.hs:118-131`) assert the OLD provider list, so they go red the
  moment the constructors exist — exactly the `providerDisplayName` argument
  one bullet down. Leaving them for WU2/WU3 would make WU1 an ungreen commit,
  which is the thing WU1 exists to avoid. They are **updates to existing
  assertions**, not new work, and their substantive new assertions (per-card
  flags, `GET /api/setup` shapes) remain WU2's.

TDD order (RED then GREEN, per item):
1. Write the failing assertions for design items **1-13, 13b, 14-21, 21b** and
   GUARD items **40, 41**
   (the generic type keeps `providerBaseUrlFor == ""`), plus the `RegistrySpec`
   updates in design §5.5.
2. Add the constructors and make each site total until the suite is green.
3. `make build && make test && make lint`.

**DoD:** `make build` clean under `-Werror`; `make test` green; `make lint`
reports "No hints"; design items 1-21, 21b, 13b and GUARD items 40, 41 pass.

**Explicitly NOT in WU1:** `resolveCreateTarget`, `resolveExistingTarget`,
`customProviderDetailJson`, the `:715` literal, the `:3246` readiness guard (all
WU3); `providerCards`/P4 copy (WU3, see below).

### WU2 — setup state (backend, after WU1; its own commit, no frontend dependency)

Files:
- `src/Seal/Setup/State.hs` — the remainder: P4 copy; confirm `providerCards`'
  existing `_ ->` wildcards already yield `requiresBaseUrl = False` /
  `pcReadiness = Nothing` for the new types (verification, not an edit).
- `test/Seal/Setup/StateSpec.hs` — 4-card vectors → 6-card.
- `test/Seal/Gateway/SetupApiSpec.hs` — per-card assertions replacing the
  whole-body `hasBoolField` pair (`:127-138`).

TDD order: design items **22-24** failing, then implement.

**DoD:** items 22-24 pass; `make test` green.
**Depends on:** WU1 (`providerDisplayName`). After that it stands alone.

### WU3 — the wire rename + both forms, atomically

Files:
- `src/Seal/Gateway/API.hs` — `resolveCreateTarget` / `resolveExistingTarget`
  type ids and the required-type check; `customProviderDetailJson` type id; the
  `:715` `customInfos` literal; the `:3246` readiness guard;
  `providerDetailJsonFor` gains `requiresBaseUrl`/`requiresName`.
  **Not** `handleProviderCreate` / `handleProviderUpdate` — unchanged (§3.1).
- `src/Seal/Gateway/Setup.hs` — the "known providers" hint text (`:374`).
- **`frontend/src/components/setup/ProviderStep.tsx` — the `showBaseUrl`
  predicate (`:257`).** Found during WU2's adversarial review, confirmed by a
  failing wizard test: the wizard drives Base URL *visibility* off
  `requires_base_url`, which is `false` for Ollama, so **a fresh-install
  operator cannot point at a remote Ollama daemon through the GUI at all**.
  D7 previously asserted the wizard needed no change; that was false and is
  corrected. Carry the parked tests (item 41b-wizard RED, item 44 GUARD) into
  this unit.
- `frontend/src/types.ts`, `lib/providerLabels.ts`, `ProvidersView.tsx`,
  `ProviderFormFields.tsx`, `setup/ProviderStep.tsx`, `ProviderModelFields.tsx`,
  `AgentsView.tsx`, `ActiveTabs.tsx`.
  `lib/setupSteps.ts` is **comment only, verified**: that file contains no
  provider-id literals (`grep -nE 'openai|anthropic|ollama|openrouter'` returns
  nothing), so the `requires_*` parsing needs no change.
- `test/Seal/Gateway/ApiSpec.hs`, `test/Seal/Setup/StateSpec.hs` (card flags).
- `frontend/src/components/__tests__/ProvidersView.test.tsx`,
  `providerStep.test.tsx`.
- `CHANGELOG.md`, `config/templates/config.toml`, `scripts/setup-walkthrough.sh`.

TDD order: write design items **25-27, 27b, 28-39, 34a-34d, 35b-35d, 35-or,
35-or-wizard, 35-keep, 41b, 41c, 45** failing,
then implement. GUARD item **42** (the Providers page still renders both fields
for `openai-compatible`, and Save stays disabled until both are valid) must stay
green throughout — it is the regression guard for D7 in create mode.

**DoD:** all of those pass; `make check` green end to end (build + test + lint +
frontend-test).

## Why the earlier "scope creep" objection no longer applies

The scope reviewer FAILed on "the guard is unrequested work" and warned that a
different id would avoid all of it. Both are now satisfied by removing the work,
not by arguing for it:

- The guard, its three cases, the `Map.member`/`providerBaseUrl` distinction, the
  empty-string `usable` test, and the three write paths that served it are
  **deleted** (design §3.1). The plan now changes no write path at all.
- The rename itself is **re-ratified by the operator** with a reason the plan can
  cite: no users, so no backward-compatibility surface (design D1).

What remains is: two constructors, nine exhaustive matches made total, the wire
rename, and the two forms hiding two fields each. That is the "few simple
changes" shape the request described.

## Requirement → item mapping

| Requirement (verbatim) | Plan item(s) |
|---|---|
| "add two more provider types … Ollama Cloud, and OpenAI" | WU1: constructors + items 1-9 |
| "shown in the setup wizard's `Choose an LLM provider` form" | WU2 items 22-24; WU3 items 43, 44 |
| "and in the new provider form on the providers page" | WU3 items 34, 35, 34a-34d |
| "both use the OpenAI-compatible API infrastructure" | WU1 items 18-19 (both delegate to `resolveOpenAICompatible`); item 21b pins the one branch that can still fail closed |
| "hard code the Base URL … fields" | WU1 items 10-12 (built-in defaults); WU3 hides the input (34, 34a) |
| "… and Unique name fields" | WU1 item 23 (`requiresName = False`); WU3 hides the input (34, 34a) |
| "appropriately for those providers" | D2/D3 tables; `ollama-cloud` needs a key, keyless mode forbidden (items 14-17) |
| "Hidden entirely" | D7 visibility table; guards 41b (Ollama still shown)/41c (custom still shown) |
| (operator re-ratification) "no users … no backwards compatibility" | design §3.1 — guard + three write paths **deleted** |

## Cross-file integration points (verified)

- `seal-harness.cabal` — no new module, so **no** edit. (All edited modules are
  already listed.)
- `test/Main.hs` — no new spec module, so no edit.
- The four duplicate `PROVIDER_LABELS` maps are each edited in place; **merging**
  them is an explicit non-goal (design §6).
- `scripts/setup-walkthrough.sh` steps 8b-8f must be re-keyed in the same commit
  as WU3, or the script performs a live request to `api.openai.com`.
- `src/Seal/Command/Provider.hs` is **not** edited. `addCmd` prompts for a key and
  `seedProviderDefaults` seeds the default provider/model; a section without
  `base_url` is the normal state for a built-in provider (design §3.1).

## Verification

Per-unit as above; whole change: `make check` (the CI-equivalent local gate) must
be green, and CI runs the same gate on Linux + macOS.

Coverage: `.coverage-thresholds.json`'s enforcement command is `make test`, and
its own metadata states the 95% thresholds are **not measured** (HPC not wired
in). "Coverage gate" here means "the suite passes", stated plainly rather than
claiming a number it cannot produce.

## Risks and rollback

| Risk | Mitigation |
|---|---|
| A missed wildcard-free site breaks the build | WU1 is one commit precisely so the compiler reports them together; the nine are enumerated in design §5.6 and §7. |
| The rename breaks a runtime string comparison the compiler cannot see | Twelve such sites, enumerated authoritatively in design §7.1; each has a numbered test (items 6, 13, 20, 25, 27, 27b, 30-33, 34, 36-38). A site absent from that table is a defect. |
| A hidden field leaks a stale value into the payload | Payload gated on `!isHiddenBaseUrl`; `formName` changes clear the fields (D7, RG-2). Items 35d, 41b. |
| Secret egress after the rename | Unreachable, not guarded: the only affected state needed a *pre-existing* `[providers.openai]` section, and there are no users (design §3.1). A self-hosted endpoint must use `openai-compatible`, which still requires an explicit `base_url` (item 42). |
| **Rollback** | Additive plus one rename. Reverting the WU3 commit restores the old `openai` meaning; WU1/WU2 can be reverted independently *only* as a set (the constructors are what break the build if reverted alone). |
| Backward compatibility | **No concern** — there are no users (design D1, §3.1). One CHANGELOG line records the new ids. There is no migration code, and none is needed. |

## Out of scope

Everything in the approved design's §6 non-goals. Notably: no readiness probing
for Ollama Cloud, **no config migration of any kind**, no `handleProviderCreate`
/ `handleProviderUpdate` / `addCmd` changes, no label-map consolidation, no
`ContextWindow` change, no `authLabel` fix, no `handleProviderDelete`
`anthropicOAuthKey` fix, no `inferProviderId` change, no streaming work.
