# Implementation Plan — Ollama provider readiness status

<!-- revision: 6 -->
<!-- design: docs/superpowers/specs/2026-11-17-ollama-readiness-status-design.md (approved, 5/5) -->
<!-- issue: #334 -->
<!-- branch: providers/ollama-readiness-status -->
<!-- drafted: 2026-11-17 -->
<!-- gate: NOT CLEAN-PASSED. 9 adversarial rounds, 23 defects found and fixed. -->
<!-- gate: max-iterations exhausted; presented for operator decision, not certified. -->

## Gate status — read this first

This plan has **not** received a clean 3/3 PASS from the adversarial Plan Review
Gate. It went through **nine** rounds, which found **23 distinct defects** — all
fixed and each re-verified against the tree. The gate's own escalation rule (max
3 iterations) was exceeded several times over, so the plan is presented for an
operator decision rather than certified as reviewed.

**Why it kept failing, honestly:** the defects were almost all of one kind — the
plan asserting things about the codebase that had not been measured. Examples
that would have caused real bugs:

- design test 25 declared as satisfied twice while remaining **unimplementable**
  (`Serve.hs` exports only `runServeMain`; the wiring site is unreachable);
- design **D2.10** and **D2.7** silently dropped — the latter a liveness bug,
  since the global cap-1 single-flight would be held forever by a hung probe;
- `ProviderRuntime` construction sites counted as 15 when there are **14**
  (`Provider.hs:82-87` is a `data` declaration, not a site);
- `OllamaProbeError` counted as 5 constructors when the design declares **6**;
- four DoD items stating behaviour but naming **no test**;
- two frontend/TS claims mis-attributing where a symbol is declared.

Every one of those was checkable in under a minute with `rg`. The lesson is
recorded rather than hidden: **measure before asserting**, and treat a plan's own
revision log as claims to verify, never as facts.

The numbers in this revision were each re-verified against the tree after the
fact (see "Verified baseline"). The **design** is unaffected — it is approved,
and its four load-bearing empirical claims were reproduced by execution.

## What this plan implements

The approved design adds an additive, observed `readiness` axis for Ollama so the
web UI, the setup wizard, and the TUI stop asserting usability from config
inspection alone. `configured` keeps its exact current semantics.

Two work units, exactly as the design's **Work units** section specifies:

- **WU-A** — probe states, the seam, the wire, and all four user-visible
  surfaces. Alone, it closes issue #334.
- **WU-B** — the advisory RAM-fit judgement that refines `ready`'s count and
  makes `RdNoFittingModel` reachable.

## Verified baseline (executed on this branch, not assumed)

Every fact below was produced by running code in the Nix dev shell on this
branch before this plan was written.

| Fact | How verified | Result |
|---|---|---|
| `nix develop --command cabal build all` | executed | exit 0, 214 modules |
| frontend `npm install` + `npm test -- --run` | executed | 1079 tests / 46 files, all pass |
| `extractHost "http://[fd00:ec2::254]/x"` | executed copy of the function | `Just "[fd00"` → floor **not** triggered |
| `extractHost "http://x@169.254.169.254/api/tags"` | executed | `Just "x@169.254.169.254"` → floor **not** triggered |
| `extractHost "http://169.254.169.254:80/"` | executed | `Just "169.254.169.254"` → floor triggered (already correct) |
| real closed-port connect, errno | executed against `127.0.0.1:9` and `:59999` | `errno=Just 61`, type `NoSuchThing`, msg `"does not exist"` |
| real DNS failure, errno | executed against `*.invalid` | `errno=Nothing`, type `NoSuchThing`, msg `"does not exist"` |

The last two rows confirm the design's D3.1 claim: refusal and DNS failure are
**byte-identical** in exception type and message, separated only by errno. A
message-substring discriminator would make `RdNotRunning` unreachable.

Two further claims of the design were reproduced by execution during planning,
because the plan depends on their exact behaviour:

| Fact | How verified | Result |
|---|---|---|
| `redirectCount = 0` with a 302 response | executed: `warp` listener on a local port returning 302, http-client request with `redirectCount = 0` | **returns** `status=302`, does **not** throw; listener saw exactly **1** request |

This confirms the design was right to drop `OpeTooManyRedirects` as unreachable
decoration, and that "redirects are never followed" is correctly pinned by
*counting requests* rather than by expecting an exception.

### Corrections made at plan-review (revision 3)

An adversarial scope review found three real defects in revision 2. Each was
re-verified against the tree and fixed; the numbers below are the corrected
ones.

1. **The `ApiDeps` literal count was wrong, and one file was mis-attributed.**
   Revision 2 claimed "39 literals … API.hs 1". Recounted: **37 real record
   literals** across **9** files, and `src/Seal/Gateway/API.hs` contains **no**
   literal at all (only the `data ApiDeps` declaration at `API.hs:163`). The
   29th `adSessionRuntime` occurrence in `ApiSpec.hs` (line 364) is a
   **copy-update** — `{ adSessionRuntime = (adSessionRuntime baseDeps) { … } }`
   — which needs no new field. The design's own "~34 / 36" figures were
   approximations; the exact number is 37.
2. **The shared stub helper was reinstated.** Revision 2 replaced the design's
   D6.2 shared constant with per-site inlining, on the false premise that no
   suitable helper module exists. `test/Seal/TestHelpers/ApiTestHarness.hs`
   exists and is already imported by `ApiSpec.hs:85`, so `noOllamaReadiness`
   belongs there, exactly as the design directs.
3. **Design test 25 is restored to a wiring-site assertion**, not a source
   grep. Revision 2 had downgraded it and its own risk register admitted the
   downgrade "proves nothing if wired via another name" — a self-refuting
   mitigation.

4. **The WU-A frontend test files are now enumerated.** Revision 2 named only
   `ProvidersView.test.tsx` while its DoD 18–21 required editing four more
   existing test files plus creating one new one; the plan's own file-scope
   gate would have failed the plan's own mandated work.

### Corrections made at plan-review (revision 4)

Gate iteration 2 returned two more FAILs, and two **independent** reviewers
converged on the same blocking issue. All fixed here.

1. **Test 25 still had no testable seam — for the second time.** Revision 3
   claimed to restore a wiring-site assertion, but `Seal.Command.Serve` exports
   only `runServeMain` (`Serve.hs:6`) and the `ApiDeps` literal sits inline in
   `runServeMainInner` (`Serve.hs:655`). No test can reach that site, so the
   assertion would have degenerated into a constructor test — the identical
   self-refutation revision 2 was faulted for. Fixed by declaring the refactor
   the assertion actually needs: an exported
   `mkOllamaProbes :: Manager -> IO OllamaProbes` factory, plus a source
   assertion pinning the single call site that the factory cannot observe.
2. **The `ProviderSelect` half of design test 42 had no test home.**
   `AgentsView.tsx:476-491` hand-rolls its own `<select>` and never renders
   `ProviderSelect`; the shared component is rendered only by
   `NewTabComposer.tsx:167` and `CronView.tsx:478`. Revision 3 assigned test 42
   to `AgentsView.test.tsx` alone, so either half the test would be skipped or
   an unscoped file edited. `CronView.test.tsx:324` already pins the literal
   `'Ollama'`, so the annotation change breaks an existing assertion. Both
   consumer test files are now in scope.
3. **A stale "39" survived in the risk register** after the revision-3 recount
   to 37. Fixed.
4. **A false line citation**: `siConfiguredProviders` is at `State.hs:119`, not
   `:122` (that line is a Haddock comment).
5. **The TUI surface had no verification and no data source.** Design D6.3
   requires `/provider list` to probe *inline* (the TUI is a separate process
   and cannot share the gateway cache), but `ProviderRuntime`
   (`Command/Provider.hs:82-87`) carries no probe handle, and it is built at
   **14** sites. Revision 3 pinned DoD 12 to design test 17 (`readinessText`, a
   pure function) — which never runs `listCmd` — and said nothing about the
   missing seam. Inlining a probe without one would also have made
   `ProviderSpec.hs:227-236` hit the real PATH and network, contradicting
   DoD 14. Fixed: `prOllamaReadiness` is added to `ProviderRuntime`, its 15
   construction sites are declared in scope, and a `ProviderSpec` assertion on
   the `list` readiness segment is the named verification.
6. **`ProviderOption` was mis-attributed to `types.ts`.** It is declared at
   `ProviderModelFields.tsx:35`, which is the file that must widen it.

### Corrections made at plan-review (revision 5)

Two reviewers again converged on test 25, which is now treated honestly rather
than papered over. Five more defects fixed.

1. **Design D2.10 was silently dropped.** The plan had no item requiring the
   probe to re-read `providerBaseUrl` on each refresh, and `OllamaProbes`/
   `mkOllamaProbes` carried no config source — so an edited `base_url` would
   have needed a restart, contradicting the design. Fixed: the factory takes an
   `IO RuntimeConfig` action, and **DoD 8b** pins the behaviour with a
   two-listener test.
2. **Test 25 is now split into two honest halves.** No test can observe which
   manager a *caller* passes; that is a property of the call site. So 25a is a
   behavioural test (a manager stamping a sentinel header → the header arrives),
   which is the real control, and 25b is a narrowly scoped source assertion on
   the **single** `mkOllamaProbes` call site. The plan now says plainly that 25b
   is a source assertion instead of claiming "not a grep" while doing one.
   Critically, 25b must be scoped to that call site: `Serve.hs:1018` legitimately
   calls `gatewayManager` for chat channels, so a whole-file check would be
   false.
3. **`ProviderRuntime` construction sites: 14, not 15.** Recounted with
   `rg -c 'prCallCounter\s*='`. Revision 4 counted `Provider.hs:82-87` — the
   `data` declaration — as a construction site.
4. **`OllamaProbeError` has 6 constructors, not 5** (design D6.1), and DoD 1
   simultaneously claimed "the exact types from D6.1". Naming the six explicitly
   removes the invitation to drop `OpeBlocked`/`OpeOther`, which tests 5 and
   D3.1 require.
5. **A false line citation:** the destructure whitelist is `setupSteps.ts:194`;
   `:192` is the function signature.

### Corrections made at plan-review (revision 6)

The eighth round found two more real gaps, one of them a liveness bug.

1. **Design D2.7 (2 s probe timeout) was dropped entirely** while the plan's own
   spec line claimed "all of D2.1–D2.10". This is not cosmetic: D2.6 caps
   in-flight probes at **1 globally**, so a probe that never returns holds that
   slot forever and every subsequent refresh is starved — permanently. That is a
   worse failure than the bug being fixed. Now **DoD 6b**, with a
   never-responding-listener test that also asserts the single-flight slot is
   released rather than leaked.
2. **DoD 8 required an "injectable clock" that the declared signature did not
   provide** — the fallback was a flaky wall-clock 30 s assertion, and a 0 s TTL
   would leave the cache permanently stale. Fixed properly: `mkOllamaProbes`
   now takes a **`ProbesConfig` record of seams** (manager, config action,
   timeout, TTL, clock, `findExecutable`, RAM reader) with a
   `defaultProbesConfig` for production, instead of a positional argument list.
   This is what makes DoD 6b, DoD 8 and DoD 14 *hermetically* testable — no real
   network, no real PATH, no 30 s sleeps — and it mirrors the existing
   `SetupDeps`/`ProvisionDeps` handle pattern.
3. A stale "15 construction sites" remained in the DoD 12 prose after the
   revision-5 recount to 14. Fixed.
4. **Three DoD behaviours named no test:** the badge **stacking** (DoD 16 —
   jsdom does no layout, so a "both texts present" check cannot tell stacked
   from clipped; now a structural sibling-in-column assertion), the `cloud` →
   BOTH-badges row (DoD 17 — design test 38 covers only `vault-locked`; now
   four table rows with four assertions), and DELETE's bodiless 204 (DoD 10).
5. **The two call-site source assertions had no home in the file scope** — the
   plan's own scope gate would have failed whatever file they were written in.
   Now named: `test/Seal/Command/ServeWiringSpec.hs` (new), following the
   `BackendNoDirectFsFailSpec.hs` precedent. `seal-harness.cabal` and
   `test/Main.hs` therefore wire **three** test modules, not two.

### Corrections made at plan-review (revision 5, continued)

The third reviewer found DoD items that stated behaviour but named **no test** —
the same class of defect as revision 2's under-scoped file list. Fixed:

1. **DoD 8 (30 s TTL / async refresh) had no verification** and no design test
   covers it, so the plan now defines one: the TTL becomes a **parameter** of
   `mkOllamaProbes` (default 30 s) with an injectable clock, so the test drives
   it with 0 s and a large value rather than sleeping 30 s in the suite.
2. **DoD 23 (startup-warm ordering) had no verification.** Now a call-site
   source assertion on `Serve.hs` ordering (the same narrow technique as 25b,
   and for the same reason: `Serve.hs` exports only `runServeMain`).
3. **DoD 24 (no vault handle) had no named test.** Now two: a probe-spec case
   with no `VaultHandle` in scope (a vault dependency would fail to compile), and
   an `ApiSpec` case serving `/api/providers/all` with a **locked** vault and
   asserting readiness still appears.
4. **Test 33b pinned PUT only**; POST is a distinct call site
   (`API.hs:3295` vs `:3394`), so both are now named, and DELETE's bodiless 204
   is asserted unchanged.

Test counts that the plan must not regress: Haskell gate baseline is established
by `make test` on the branch tip; frontend baseline is **1079 passing**.

## Non-goals (from the design — do not drift)

- No readiness for `anthropic` / `openrouter` / `openai`, or for custom
  OpenAI-compatible instances (follow-up #1).
- No change to provider resolution, request encoding, or
  `ollamaResponseTimeoutMicro`.
- No change to `configuredProviders` / `configured` semantics (`Registry.hs`
  needs **no** change — its `OllamaProvider` branch stays byte-identical).
- No DNS-resolving SSRF floor (follow-up #3) — the bracket/userinfo half only.
- `ollamaNeedsKey`'s substring fragility is **not** fixed (follow-up #2); the
  probe simply never calls `withHeaders`.
- No install or lifecycle management of Ollama.

---

## Work unit decomposition

```text
WU-A (no deps) ──→ WU-B (depends on WU-A)
```

WU-B touches the same modules as WU-A, so they run **sequentially**. Only the
tag record and fit logic are WU-B's; everything user-visible is WU-A's.

### WU-A — probe states + all four surfaces

**Spec:** design §D1, §D2 (all of D2.1–D2.10), §D3, §D4 (labels), §D6, §D7,
§D8, Wire format.
**Dependency:** none.
**Human checkpoint:** yes — after WU-A, because it changes a security-relevant
module (`Seal.Web.UrlSafety`) and the blocking-setup-gate copy.

**File scope (WU-A):**

New:
- `src/Seal/Providers/OllamaReadiness.hs` — pure classification
- `src/Seal/Providers/OllamaReadinessProbe.hs` — I/O, cache, single-flight
- `test/Seal/Providers/OllamaReadinessSpec.hs`
- `test/Seal/Providers/OllamaReadinessProbeSpec.hs`
- `test/Seal/Command/ServeWiringSpec.hs` — **new**, the home for the two
  call-site source assertions (25b: the single `mkOllamaProbes` call passes
  `mgr` not `gwMgr`; DoD 23: `mkOllamaProbes` precedes `let deps = ApiDeps`
  precedes `runGateway`). Precedent:
  `test/Seal/Agent/Def/BackendNoDirectFsFailSpec.hs` reads a module's source and
  asserts on import lines. This file is why the plan's scope gate has a named
  destination for those assertions instead of inventing an in-scope file later.
- `frontend/src/lib/readiness.ts`
- `frontend/src/lib/__tests__/readiness.test.ts`

Modified:
- `src/Seal/Web/UrlSafety.hs` — `extractHost` bracket-aware + userinfo-stripped;
  `isAlwaysBlockedUrl` prefix → `elem`
- `test/Seal/Web/UrlSafetySpec.hs` — four host-parsing cases (design test 22,
  plus the `Seal.Web.Fetch`-facing `isSafeUrl "http://x@192.168.1.1/"` assertion)
- `src/Seal/Setup/State.hs` — `siOllamaReadiness`, `providerCards` +3rd arg,
  `classifyProvider` +3rd arg, "not ready yet" detail
- `ProviderRuntime` gains `prOllamaReadiness` (DoD 12 / the TUI surface). This
  is a **14-construction-site churn additional to `ApiDeps`**, recounted with
  `rg -c 'prCallCounter\s*=' src test -g '*.hs'` (the `prCallCounter` field is
  written exactly once per construction): ApiSpec 4, CliSpec 2, ModelSpec 2,
  and 1 each in `Serve.hs`, `Tui.hs`, `SessionSpec.hs`, `SendSpec.hs`,
  `ProviderSpec.hs`, `ApiTestHarness.hs`. Note `Provider.hs:82-87` is the
  `data` declaration, **not** a construction site — revision 4 miscounted it as
  one and therefore claimed 15.
- `src/Seal/Gateway/Setup.hs` — `SetupEnv.seOllamaReadiness`, `cardJson`,
  `SetupInputs` literal in `handleSetupState`
- `src/Seal/Gateway/API.hs` — `ApiDeps.adOllamaReadiness`, `providerInfoJson`,
  `providerDetailJsonFor`, `setupEnv`
- `src/Seal/Command/Provider.hs` — `listCmd` renders readiness
- `src/Seal/Command/Serve.hs` — probe cache, `adOllamaReadiness`, startup warm
- `test/Seal/Setup/StateSpec.hs` — `inputsFor` + the new field, detail assertions
- `test/Seal/Gateway/ApiSpec.hs` — **28** real `ApiDeps` record literals (the
  29th `adSessionRuntime` occurrence, line 364, is a copy-update of an existing
  `ApiDeps` and needs no new field)
- `test/Seal/Phase7aSpec.hs` — 2 literals
- `test/Seal/Gateway/SetupApiSpec.hs` — 1 literal
- `test/Seal/Gateway/ServerSpec.hs` — 1 literal
- `test/Seal/Gateway/MutationGuardSpec.hs` — 1 literal
- `test/Seal/Gateway/ApiFilesSpec.hs` — 1 literal
- `test/Seal/Gateway/PatIngestionSpec.hs` — 1 literal
- `test/Seal/TestHelpers/ApiTestHarness.hs` — 1 literal **plus** the shared
  `noOllamaReadiness :: IO OllamaReadiness` stub (`pure RdPending`) required by
  design D6.2. This module is already imported by `ApiSpec.hs:85`, so the
  constant reaches the largest consumer for free.
- `seal-harness.cabal` — 2 exposed modules, **3** test `other-modules:`
  (the two probe specs + `ServeWiringSpec`)
- `test/Main.hs` — **3** imports + 3 spec entries
- `frontend/src/types.ts` — `ProviderReadiness`, `readiness?` on
  `ProviderInfo` / `ProviderDetail`, and `readinessModels?`
- `frontend/src/lib/setupSteps.ts` — `ProviderCard` + `parseProvider` whitelist
- `frontend/src/components/ProvidersView.tsx` — list row + editor pill, stacked
- `frontend/src/components/ProviderModelFields.tsx` — widen **`ProviderOption`**
  (declared here at `:35`, **not** in `types.ts`) with `readiness?` +
  `readinessModels?`, and render the annotation in `ProviderSelect`.
  Revision 3 mis-attributed this interface to `types.ts`.
- `frontend/src/components/AgentsView.tsx` — option annotation
- `frontend/src/components/setup/ProviderStep.tsx` — pill + hint + CTA copy
- `frontend/src/hooks/useApi.ts` — focus refetch in `useAllProviders`
- `frontend/src/hooks/useSetup.ts` — focus refetch in `useSetupState`
- **Frontend test files (all required by DoD 15–21 and design tests 35–44):**
  - `frontend/src/lib/__tests__/readiness.test.ts` — **new** (tests 39, 40)
  - `frontend/src/components/__tests__/ProvidersView.test.tsx` — rewrite the
    literal `Keyless` assertion at line ~203 in the RED step; add tests 35–38
  - `frontend/src/lib/__tests__/setupSteps.test.ts` — `parseProvider`
    round-trip (test 41)
  - `frontend/src/components/__tests__/providerStep.test.tsx` — pill, hint,
    CTA-copy agreement (test 44)
  - `frontend/src/components/__tests__/AgentsView.test.tsx` — option
    annotation + still selectable (test 42)
  - `frontend/src/components/__tests__/CronView.test.tsx` — the
    **`ProviderSelect` half of test 42**. `ProviderSelect` is rendered by
    `NewTabComposer.tsx:167` and `CronView.tsx:478`, while
    `AgentsView.tsx:476-491` hand-rolls its own `<select>` and never touches
    `ProviderSelect`, so `AgentsView.test.tsx` alone does not cover it. This
    file **already pins the option text** (`CronView.test.tsx:324` asserts
    `'Ollama'`), so the annotation change breaks that assertion and it must be
    updated to `'Ollama (Not Running)'` in the RED step.
  - `frontend/src/components/__tests__/NewTabComposer.test.tsx` — the second
    `ProviderSelect` consumer (`NewTabComposer.tsx:167`); add the same
    annotation assertion so both live renders of the shared component are
    pinned.
  - `frontend/src/hooks/__tests__/useApi.test.ts` — focus refetch for
    `useAllProviders` (test 43)
  - `frontend/src/hooks/__tests__/useSetup.test.ts` — **new** file; no such
    test exists today, and test 43 requires focus-refetch coverage for
    `useSetupState` too
- **delete** `frontend/src/components/NewSessionComposer.tsx` and
  `frontend/src/components/__tests__/NewSessionComposer.test.tsx`

Out of WU-A scope by declaration: `src/Seal/Providers/Registry.hs` (no change),
`src/Seal/Providers/Ollama.hs` (no change — the probe builds its own request).

**Wire shape WU-A must emit** (design "Wire format", each endpoint keeps its own
casing):

```json
GET /api/providers      { "name":"ollama", "configured":true, "models":[],
                          "readiness":"not-running" }
                        { ..., "readiness":"ready", "readiness_models":3 }
GET /api/providers/all  { ..., "readiness":"ready", "readinessModels":3 }
GET /api/setup card     { ..., "readiness":"ready", "readiness_models":3 }
```

`readiness` is **absent** (not `null`) for non-Ollama rows and for custom
OpenAI-compatible instances. Wire values are kebab-case:
`pending | unknown | not-installed | not-running | no-models | no-fitting-model | ready | cloud`.

**DoD items (each independently verifiable):**

1. `Seal.Providers.OllamaReadiness` exists with the exact types from design
   D6.1: `OllamaReadiness` (8 constructors), `OllamaProbeError` (**6** —
   `OpeRefused`, `OpeBlocked`, `OpeTimeout`, `OpeBadResponse`, `OpeHttp !Int`,
   `OpeOther`),
   `OllamaHostKind` (4), `OllamaTag { otName }`, `OllamaProbe`, plus
   `classifyOllamaReadiness`, `readinessText`, `classifyProbeFailure`,
   `probeTargetFor`. **`OllamaTag` declares `otName` only in WU-A** (WU-B owns
   `otSizeBytes`/`otRemoteHost`) and `isCloudModel` is **not** defined in WU-A.
2. `classifyProbeFailure` discriminates on `ioe_errno` exactly as design D3.1's
   compilable snippet, including the `fromException se :: Maybe IOException`
   unwrap and the trailing fail-safe `_ = OpeOther`. Design test 16
   (a) real refusal → `OpeRefused`; (b) real `.invalid` DNS → not
   `OpeRefused`; (c) synthetic `eCONNRESET` via `toException` with **all**
   `IOError` fields (incl. `ioe_handle = Nothing`) → not `OpeRefused`.
3. `probeTargetFor :: Text -> Either OllamaProbeError Request` rejects
   non-http(s), userinfo, `169.254.169.254`, and `http://[fd00:ec2::254]/…`;
   accepts `http://localhost:11434`, `http://127.0.0.1:11434`,
   `http://192.168.1.9:11434` (design test 22). Its output carries no
   `Authorization` header and is built without `withHeaders` (test 23).
4. `Seal.Web.UrlSafety.extractHost` is bracket-aware and userinfo-stripping
   (design D2.2), and `isAlwaysBlockedUrl` uses exact `elem` rather than
   `T.isPrefixOf`. Proven **through the public surface** in
   `UrlSafetySpec` — no export widening: `isAlwaysBlockedUrl
   "http://[fd00:ec2::254]/x"` and `isAlwaysBlockedUrl
   "http://x@169.254.169.254/"` become `True`; `"http://169.254.169.254:80/"`
   stays `True`; `isSafeUrl "http://x@192.168.1.1/"` is
   `Left (UseBlockedIp "192.168.1.1")` (not `Left UseDnsFailed`); and the
   loopback/private-must-still-**pass** cases are re-asserted so the fix does
   not over-block (`isSafeUrl` on `172.32.0.1`, `100.128.0.1`, `93.184.216.34`
   still `Right`).
5. Probe I/O uses the **provider** manager: constructed from `adHttpManager`,
   never `gatewayManager` (design tests 24/25). Test 24 runs a local loopback
   listener and asserts the captured request carries **no** `Authorization`
   — this is the test that actually observes `managerModifyRequest`.
   **Test 25 is a wiring-site assertion, not a source grep** (design D2.9:
   "asserted at the wiring site, so wiring the service-token manager fails
   RED") — and it requires one small refactor, declared here so the file scope
   is honest. `Seal.Command.Serve` exports only `runServeMain` (`Serve.hs:6`),
   and the `ApiDeps` literal is inline inside `runServeMainInner`
   (`Serve.hs:655`), so **no test can reach the wiring site today**: a
   "construct a probe over my own injected manager" test exercises the
   constructor while proving nothing about the wiring — exactly the
   self-refutation revision 2 was faulted for.

   Therefore WU-A extracts a **pure factory**, exported from
   `Seal.Providers.OllamaReadinessProbe`, which takes the manager **and** the
   config source (the config source is required by D2.10 — see DoD 8b):

   ```
   data ProbesConfig = ProbesConfig
     { pcManager      :: Manager      -- the PROVIDER manager, never gatewayManager
     , pcReadConfig   :: IO RuntimeConfig   -- re-read per refresh (design D2.10)
     , pcTimeoutMicro :: Int          -- design D2.7, default 2_000_000
     , pcTtlMicro     :: Int          -- design D2.5 (30 s), injectable for tests
     , pcNow          :: IO UTCTime   -- injectable clock
     , pcIsExecutable :: Text -> IO (Maybe FilePath)  -- findExecutable seam
     , pcTotalRam     :: IO (Maybe Word64)
     }

   mkOllamaProbes :: ProbesConfig -> IO OllamaProbes
   defaultProbesConfig :: Manager -> IO RuntimeConfig -> ProbesConfig
   ```

   A **single record of seams**, not seven positional arguments: production calls
   `mkOllamaProbes (defaultProbesConfig mgr loadCfg)`; tests override only the
   field under test. This is what makes DoD 8's "injectable clock", DoD 6b's
   short timeout, and DoD 14's "no test touches the network or the real PATH"
   (`pcIsExecutable`) all achievable *hermetically* — a wall-clock 30 s sleep or
   a real `findExecutable` in the suite is not an option. It also mirrors the
   repo's existing `SetupDeps`/`ProvisionDeps` nested-handle pattern.

   `Serve.hs` then calls `mkOllamaProbes mgr loadCfg` with the **provider**
   manager (`Serve.hs:316`) and nothing else, mirroring the existing
   `adProviders` seam which already takes `loadCfg` (`Serve.hs:662-672`).

   **What test 25 can and cannot assert — stated honestly.** No test can
   observe which manager a caller passes: that is a property of the call site,
   not of the factory. So test 25 is split into the two halves that are each
   genuinely verifiable:

   - **25a (behavioural, the real control):** construct the factory over a
     manager carrying a `managerModifyRequest` that stamps a sentinel header,
     run one probe, and assert the header **does** arrive — proving the factory
     honours the manager it is given. This is the half that would have caught
     the original bug class.
   - **25b (structural, narrow and precisely stated):** an assertion in
     `test/Seal/Command/ServeWiringSpec.hs` on `Serve.hs`'s **single**
     `mkOllamaProbes` call site that its manager argument is `mgr`, not `gwMgr`. This is a source assertion, and the plan
     says so rather than pretending otherwise. It is safe from the "proves
     nothing" objection *as long as it is scoped to the call site* — note
     `Serve.hs:1018` legitimately calls `gatewayManager` for chat channels, so
     a whole-file "does not mention gatewayManager" check would be false and is
     explicitly **not** what is asserted.

   25a is the primary control; 25b is a regression guard on one line.
   `Seal.Command.Serve`'s export list does **not** change.
6. Body read is an accumulating `brReadSome` loop until `BS.empty` or 256 KiB;
   reaching the cap is `OpeBadResponse`. A two-segment `/api/tags` body decodes
   fully (test 26); >256 KiB → `OpeBadResponse`, never a partial decode
   (test 27); `redirectCount = 0` and a 3xx lands in `OpeHttp 3xx` with the
   listener seeing exactly one request (test 9).
6b. **The probe is bounded at 2 s** (design D2.7), not the provider's
    5-minute `ollamaResponseTimeoutMicro`. This is a liveness requirement, not
    a nicety: D2.6 caps in-flight probes at **1** globally, so a probe that
    never returns holds that cap **forever** and every later refresh is silently
    starved — DoD 8's "kicks an async refresh when older than 30 s" would stop
    firing permanently, which is a worse failure than the bug being fixed.
    Implementation: set `responseTimeout = responseTimeoutMicro 2_000_000` on
    the request (never inherit the provider's value), and treat expiry as
    `OpeTimeout` → `RdUnknown` (design tests 6, 9).
    **Verification:** an `OllamaReadinessProbeSpec` case against a loopback
    listener that accepts the connection and then **never responds**, asserting
    the probe returns `RdUnknown` well under ~5 s, and that a *second* probe
    afterwards is still possible (i.e. the single-flight slot was released, not
    leaked). The timeout is a **parameter** of `mkOllamaProbes` (default 2 s) so
    the test can use a short value instead of waiting.

7. Single-flight is atomic (`atomicModifyIORef'` or `TVar`), global cap 1,
   keyed on the URL normalised with `stripTrailingSlash`. Concurrent calls issue
   exactly one request (test 28); `http://localhost:11434` and
   `http://localhost:11434/` issue exactly one probe between them (test 29).
8. `OllamaProbes { oprReadiness, oprRefresh, oprTotalRam }` exists and is
   injected as `SetupInputs.siOllamaReadiness` and
   `ApiDeps.adOllamaReadiness`. `oprReadiness` returns the cached value
   immediately and kicks an async refresh when older than 30 s; `oprRefresh`
   forks and returns immediately. `SetupInputs`'s default lives in
   `emptySetupInputs` (`State.hs:125-137`) as `siOllamaReadiness = pure
   RdPending` — the field is an IO action, exactly mirroring the existing
   `siConfiguredProviders :: IO [KnownProvider]` seam (`State.hs:119`). The
   cache itself follows the `IconCache` precedent (`ProviderIcon.hs:50-56`: a
   `newtype` over `IORef`, TTL-based, constructed by `newIconCache` and created
   in `Serve.hs`).
   **Verification (no design test covers TTL, so this plan defines it):** a new
   `OllamaReadinessProbeSpec` case driving `pcNow` / `pcTtlMicro` —
   `oprReadiness` on a fresh cache returns `RdPending` and kicks one probe;
   a second `oprReadiness` inside 30 s returns the cached value and issues **no**
   second request; past 30 s it returns the cached value immediately (asserted
   non-blocking by timing) and kicks exactly one refresh. Because a wall-clock
   30 s wait is unacceptable in the suite, the TTL is `pcTtlMicro` in
   `ProbesConfig` (default 30 s), so the test drives it with 0 and a large value
   instead of sleeping. `oprRefresh` is asserted to return before
   its probe completes (a probe against a listener that never answers).
8b. **Every refresh re-reads the config** (design D2.10). `mkOllamaProbes`
    takes an `IO RuntimeConfig` action, not a frozen `Text` base URL, and each
    probe pass calls `providerBaseUrl cfg "ollama"` afresh — mirroring the
    existing `adProviders` seam (`Serve.hs:662-672`), which re-reads
    `config.toml` on every request for exactly the same reason. Consequences
    that must hold: editing `[providers.ollama] base_url` takes effect **without
    a restart**, and the single-flight key is that freshly-read URL normalised
    with `stripTrailingSlash` (`Ollama.hs:99`). Verified by a probe-spec test
    that points the config action at listener A, probes, then re-points it at
    listener B and probes again, asserting listener B receives the second
    request (and that a trailing-slash variant does not produce a second
    in-flight probe). Revision 4 had no item for D2.10 at all — `OllamaProbes`
    carried no config source, so a `base_url` change would have needed a
    restart, silently contradicting the design.

9. `/api/providers` emits `readiness` + `readiness_models` for Ollama only, and
   never for `anthropic`/`openrouter`/`openai`/custom instances (test 31).
10. `/api/providers/all` **and both** the POST and PUT mutation responses carry
    the same `readiness` + `readinessModels` (test 33b) — all via the single
    shared `providerDetailJsonFor` lookup (`API.hs:3181`), so a saved Ollama
    provider cannot flip back to `Keyless`. Both verbs are pinned separately
    (`API.hs:3295` and `:3394` are distinct call sites). DELETE is unchanged —
    204 `noContent` with an empty body — and is pinned by an `ApiSpec`
    assertion that the response body is `""` and the status is 204.
11. `/api/setup` card carries `readiness` + `readiness_models`; `required_complete`
    is unaffected by readiness (test 32), and `configured` is unchanged for every
    readiness value (test 30 — the no-gate-flap invariant).
12. `readinessText` is total over all eight constructors, `RdPending → ""`,
    `RdReady n` → `Ready · n Models` / `Ready · 1 Model`, `RdReady` with no count
    → `Ready` (test 17). `/provider list` omits the segment when the text is
    empty.
    **The TUI surface needs a seam that does not exist today, and this plan
    declares it.** `ProviderRuntime` (`Command/Provider.hs:82-87`) carries
    `prConfigPath`/`prVault`/`prManager`/`prCallCounter` and **no** probe
    handle; it is constructed at **14** sites, and only 2 are already in scope
    (`Serve.hs:318`, `Provider.hs` itself). Inlining a probe in `listCmd`
    without a seam would put `findExecutable` + a network connect on
    `ProviderSpec.hs:227-236` — breaking DoD 14's "no existing test touches the
    network or the real PATH". Therefore WU-A adds
    `prOllamaReadiness :: IO OllamaReadiness` to `ProviderRuntime` and fills it
    at all 14 construction sites, of which these are added to the file scope:
    `src/Seal/Tui.hs`, `test/Seal/Channel/CliSpec.hs`,
    `test/Seal/Command/ModelSpec.hs`, `test/Seal/Command/ProviderSpec.hs`,
    `test/Seal/Command/SessionSpec.hs`, `test/Seal/Gateway/SendSpec.hs`,
    `test/Seal/Gateway/ApiSpec.hs` (4 literals), and
    `test/Seal/TestHelpers/ApiTestHarness.hs` (already in scope). Every test
    literal uses `noOllamaReadiness`, so `ProviderSpec`'s existing `list`
    assertions stay offline and green. `listCmd` probes **inline** (design
    D6.3: the TUI is a separate process and cannot share the gateway cache) and
    its readiness segment is verified by a new `ProviderSpec` assertion — this
    is the named verification design test 17 alone does not provide.
13. `StateSpec`: the provider step's `detail` appends the "Ollama is not ready
    yet; you can continue and start it later." sentence **only** for
    `{not-installed, not-running, no-models}`, and for no other state
    (test 33) — the excluded set is `{pending, unknown, cloud, no-fitting-model, ready}`.
14. Every test stub reports `RdPending`, never `RdUnknown`, so no existing test
    touches the network or the real PATH (test 34). All **37 real `ApiDeps`
    record literals** across **9** files compile with the new field — recount
    with `rg 'adSessionRuntime\s*='` and exclude the copy-update at
    `ApiSpec.hs:364`: ApiSpec **28**, Phase7aSpec 2, and 1 each in SetupApiSpec,
    ServerSpec, MutationGuardSpec, ApiFilesSpec, PatIngestionSpec,
    ApiTestHarness, `Serve.hs`. `src/Seal/Gateway/API.hs` has **no** literal
    (only the `data ApiDeps` decl at line 163) and must not be edited for this.
    **The stub is the one shared constant design D6.2 mandates:**
    `noOllamaReadiness = pure RdPending`, defined once in
    `test/Seal/TestHelpers/ApiTestHarness.hs` (already imported by
    `ApiSpec.hs:85`) and referenced by every literal. Do **not** inline a
    per-site literal that duplicates it.
15. `frontend/src/lib/readiness.ts` exports `readinessLabel`, `readinessHint`,
    `readinessTone`, all **total**: `pending` → `''` / `null` / `faint`
    (tests 39, 40); the eight-state label table matches design §D4 exactly,
    including the `n`-model pluralisation.
16. `ProvidersView` renders `Not Running` in **both** the list row and the
    editor pill instead of `Keyless` (tests 35, 36), the two badges **stack**
    rather than clip (the row is `text-xs truncate`), and absent `readiness`
    falls back to the current auth badge (test 37).
    **Verification:** tests 35–37 in `ProvidersView.test.tsx`, plus a new
    assertion that the two badge elements are **siblings in a column container**
    (so they stack) rather than inline siblings in the `truncate` row — asserted
    structurally on the rendered DOM, since jsdom does no layout and a pure
    "both texts are present" check cannot distinguish stacked from clipped.
17. The D3.2 override table is implemented exactly: `pending` first (readiness
    slot empty, auth badge only); readiness present + `authStatus ∈ {none,
    vault-locked}` → both badges; `cloud` → both; readiness present and specific
    → readiness **replaces** the auth badge; readiness absent → existing
    `AUTH_STATUS_LABELS` badge. Notably `vault-locked` on **anthropic** renders
    **one** badge (test 38).
    **Verification:** test 38 covers `vault-locked`-anthropic (one badge) and
    `vault-locked`-ollama (two). Design test 38 does **not** cover the `cloud`
    row, so this plan adds it: a `readiness: 'cloud'` Ollama renders **two**
    badges (readiness `Cloud` + auth `Keyless`). Also added: `authStatus: 'none'`
    + readiness present → two badges, and readiness present + specific auth
    (`api-key`) → readiness **replaces** it (one badge). Four table rows, four
    assertions.
18. Both live option lists annotate `Ollama (Not Running)` — parenthesised —
    and keep the option **selectable**; `missing` wins over readiness when both
    apply (test 42). `ProviderSelect` (feeding `NewTabComposer` + `CronView`) and
    `AgentsView` are the two live sites.
19. `parseProvider` preserves `readiness` and `readiness_models` (test 41) — the
    destructure whitelist at `setupSteps.ts:194` (the function signature is at `:192`) would otherwise silently drop
    them.
20. A window `focus` event triggers a refetch in **both** `useAllProviders` and
    `useSetupState` (test 43).
21. `ProviderStep`: the pill renders from `readiness` (falling back to current
    text when absent), a hint slot renders below it, the CTA stays
    `Use <provider>` and stays **enabled**, and the "not ready yet" sentence
    agrees with the CTA (test 44).
22. `NewSessionComposer.tsx` and its spec are deleted; nothing else in
    `frontend/src` imports it (verified before deletion by grep).
23. Startup warm: the cache `IORef` is created in `Serve.hs` in the
    `wsHealthRef`/`iconCache` cluster **before** `let deps = ApiDeps` and before
    `runGateway`, and the first probe is kicked non-blocking so the HTTP bind is
    never delayed.
    **Verification:** a source assertion in
    `test/Seal/Command/ServeWiringSpec.hs` (the `mkOllamaProbes` line precedes
    `let deps = ApiDeps`, which precedes `runGateway`) — the same narrow, call-site-scoped structural technique as
    25b, since `Serve.hs` exports only `runServeMain` and cannot be observed
    behaviourally. Non-blockingness is covered by DoD 8's `oprRefresh` test.
24. Readiness requires **no vault handle**: the probe path is readable with the
    vault locked or absent.
    **Verification (two named tests, since revision 5 named none):**
    (a) an `OllamaReadinessProbeSpec` case that builds the probes from
    `mkOllamaProbes` with **no** `VaultHandle` anywhere in scope and completes a
    probe against a loopback listener — the type signature makes a vault
    dependency impossible to add silently, and this test fails to compile if one
    appears; (b) an `ApiSpec` case that serves `GET /api/providers/all` with
    `adVault = fakeLockedVaultRuntime` and asserts the Ollama row still carries
    `readiness` + `readinessModels` (a vault-locked Ollama, complementing test
    38's frontend-only assertion).
25. `make check` green (build + Haskell test + `hlint` clean + frontend test),
    with `hlint src/ test/` reporting **No hints**.

**TDD sequencing inside WU-A.** Write RED first, in this order, because each
layer depends on the one before it:

1. `UrlSafetySpec` cases (DoD 4) — RED, then fix `extractHost` /
   `isAlwaysBlockedUrl` → GREEN. This lands first because the probe's floor
   depends on it.
2. `OllamaReadinessSpec` — pure classification and `classifyProbeFailure`
   (DoD 1–3, tests 1–11, 17). The refusal/DNS pair is produced by **real
   connects** (design test 16), using `Seal.TestHelpers.FreePort` to pick a
   definitely-closed loopback port.
3. `OllamaReadinessProbeSpec` — I/O against a local `warp` loopback listener
   (`warp` is already a test dependency), no external network (DoD 5–8).
4. Wiring: `StateSpec` detail (DoD 13), then `ApiSpec` wire shape (DoD 9–11),
   then the mechanical `ApiDeps` stub fill (DoD 14).
5. Frontend RED: `readiness.test.ts`, then `ProvidersView.test.tsx` (rewriting
   the `Keyless` literal), then the remaining component/hook tests (DoD 15–21).

### WU-B — RAM judgement

**Spec:** design §D5 (all), §D3.5, plus the `n`-is-usable-count clause in §D4
and the `RdNoFittingModel` row of the label table.
**Dependency:** WU-A complete (same modules; extends the tag record).
**Human checkpoint:** no.

**File scope (WU-B):**

- `src/Seal/Providers/OllamaReadiness.hs` — add `otSizeBytes`, `otRemoteHost`,
  `isCloudModel`, `parseMemTotal`, the exact-integer fit predicate, the
  `RdNoFittingModel` / usable-count logic
- `src/Seal/Providers/OllamaReadinessProbe.hs` — `oprTotalRam` (sysctl /
  `/proc/meminfo`, memoise **only** `Just`), populate sizes/remote_host
- `test/Seal/Providers/OllamaReadinessSpec.hs` — tests 12–15, 18–21, 14b, 14c
- `test/Seal/Providers/OllamaReadinessProbeSpec.hs` — RAM reader
- `frontend/src/lib/readiness.ts` — `no-fitting-model` hint (already labelled in
  WU-A) becomes reachable; no table change

**DoD items:**

1. `isCloudModel` is true when the name has a `:cloud` suffix **or**
   `remote_host` is present; `remote_host` is authoritative when they disagree;
   both-directions and neither-set asserted (test 15).
2. Fit predicate is exact integer arithmetic, no floating point:
   `fits model := isCloudModel model || (size known && size * 5 < ram * 4)`
   (design D5.2 — 1.25× headroom, `size * 5 < ram * 4`).
3. Unknown RAM never produces a claim: `forAll` over tag lists,
   `opTotalRam = Nothing` ⇒ never `RdNoFittingModel` (test 18).
4. Symmetric **size** rule: `RdNoFittingModel` requires **at least one known
   size, and none of the known-size models fit**; every size unknown ⇒
   `RdReady` with count = all models (test 14b). Mixed known/unknown ⇒ the
   unknown-size model counts as usable ⇒ `RdReady` (test 14c).
5. Monotonicity over the exported classifier: `classify (p { opTotalRam = Just r })
   == RdReady n` ⇒ `classify (p { opTotalRam = Just r' }) == RdReady m` with
   `m >= n` for `r' >= r` (test 19).
6. `otRemoteHost = Just _` ⇒ usable regardless of size, `forAll` over sizes
   (test 20).
7. `parseMemTotal :: Text -> Maybe Word64` converts kB→bytes
   (`"MemTotal: 16384000 kB"` → `Just 16777216000`); `""`, `"MemTotal: 0 kB"`,
   `"garbage"` → `Nothing`; a non-`kB` unit suffix (`"MemTotal: 16 MB"`) →
   `Nothing` rather than a silent rescale (test 21).
8. `n` in `Ready · n Models` is the **usable** count (cloud ∪ fitting), so
   `Ready · 3 Models` is truthful on a GPU host (design D4).
9. RAM sourcing: macOS `/usr/sbin/sysctl -n hw.memsize` with a plain-PATH
   fallback; Linux `MemTotal` from `/proc/meminfo`; **memoise only `Just`** so a
   transient PATH miss cannot permanently disable the judgement.
10. `RdNoFittingModel` never affects `configured`, never gates the wizard, never
    blocks selection (advisory-only, asserted by `ApiSpec` remaining green with
    the existing `configured`/`required_complete` assertions unchanged).
11. `make check` green; frontend suite green with the WU-A count plus WU-B's.

---

## Quality gates per work unit

The orchestrator runs these **itself**; subagent self-reports are not accepted.

| Gate | Command | Blocking condition |
|---|---|---|
| Haskell build (`-Werror`) | `make build` | any warning or error |
| Haskell tests | `make test` (redirect to a file — SIGPIPE pitfall) | any failure; new pending without justification |
| Lint | `make lint` | anything other than `No hints` |
| Frontend | `make frontend-test` | any failure |
| Full gate | `make check` | non-zero exit |
| Coverage | `.coverage-thresholds.json` enforcement command (`make test`) | fails; note thresholds are aspirational until HPC is wired — do **not** claim coverage numbers |
| File scope | `git diff --name-only` vs the WU's declared scope | any file outside scope |
| No `~/.seal` writes | inspect the diff | any opcode or agent path writing under `~/.seal/` |
| Invariant 1 | inspect the diff | any `sh -c` or agent-supplied command string in Trusted/Audited code |

**SIGPIPE discipline:** never pipe `cabal`/`hlint` output through `head`/`tail`.
Redirect to a log file, then page it with `sed -n`.

## Security considerations (pre-flight)

**Trust boundaries.** `base_url` in `config.toml` is operator-controlled but the
probe dereferences it unattended on a polled endpoint — treat it as untrusted
input. The threat model the design addresses:

| Threat | Control | Pinned by |
|---|---|---|
| Vault key exfiltrated to an attacker-controlled `base_url` | Probe uses `ollamaHeaders Nothing` only; never `withHeaders`/`resolveProvider`/`listSome` | test 23 (structural), test 24 (listener sees no `Authorization`) |
| Gateway **service token** exfiltrated | Probe built on `adHttpManager`, never `gatewayManager` (which stamps `Authorization: Bearer <service token>` via `managerModifyRequest`) | tests 24 + 25 |
| SSRF to cloud metadata | `isAlwaysBlockedUrl` floor + `redirectCount = 0` | test 22 |
| SSRF bypass via bracket-IPv6 / userinfo | the `extractHost` fix in DoD 4 | `UrlSafetySpec` cases |
| Warp worker exhaustion / latency oracle / browser-triggered egress | out-of-band cache; handlers only read an `IORef` | DoD 8; `oprReadiness` never blocks |
| Memory exhaustion from a hostile response | 256 KiB accumulating cap, fail closed | tests 26, 27 |
| Unbounded egress | lazy 30 s refresh + focus refetch, no timer | DoD 8, DoD 20 |

**Recorded residual (accepted in the design, restated so it is not mistaken for
coverage):** `isAlwaysBlockedUrl` performs no DNS resolution, so a hostname
resolving to a metadata IP passes (rebinding). Accepted because no credential is
sent, the body is capped, and only an 8-value enum escapes the process — this is
a blind connect oracle, not a metadata read. Follow-up #3.

**Capabilities:** no opcode gains a capability; no new opcode. `sysctl` /
`/proc/meminfo` / `findExecutable` are gateway/CLI code, justified by precedent
(`TlsCert.hs`, `SearXngSetup.hs`, `EngramBackend.hs`) — invariant 1 is scoped to
Trusted/Audited opcodes, and invariant 2 is not implicated (no user-derived
argv).

## Rollback / backward compatibility

- The wire change is **purely additive**; `readiness` absent → every consumer
  falls back to today's behaviour (tests 37, and the `ProviderStep` absent case
  in DoD 21). An older frontend against a newer backend ignores the new fields;
  a newer frontend against an older backend takes the fallback path. No flag day.
- `configured` semantics are untouched (DoD 11), so reverting readiness cannot
  re-open or close the blocking gate.
- The `extractHost` fix is the one non-additive change: it makes the floor
  **stricter**. Reverting it restores two live SSRF bypasses, so it is not a
  candidate for rollback on its own.
- Deleting `NewSessionComposer` is verifiable as safe before deletion (DoD 22);
  the file is recoverable from git if the grep turns out wrong.

## Human checkpoints

**Checkpoint 1 — after WU-A (mandatory pause).** Present:
- the `UrlSafety` diff and the four new `UrlSafetySpec` cases, since this
  changes the SSRF floor for `Seal.Web.Fetch` as well as the probe;
- the four surfaces rendered (screenshots or test output) — Providers list,
  editor pill, setup card, `/provider list`;
- confirmation that `configured` / `required_complete` assertions are unchanged;
- the `ApiDeps`-churn outcome (**37 real literals across 9 files**, each
  referencing the single shared `noOllamaReadiness` constant) and whether that
  was preferable to a `Default ApiDeps` refactor.

**Checkpoint 2 — after WU-B, before PR.** Final comprehensive review + final
gate, then `self-reflect` and knowledge-base commit **before** PR creation.

## Open questions carried from the design (decide before WU-A starts)

These are the design's own "Open questions" — they do not block WU-A, but the
plan records the default so execution does not silently pick one:

1. **30 s lazy refresh + focus refetch** — plan default: ship as designed.
   Adding a gateway timer would create standing unattended egress, which the
   design's Security review specifically avoided.
2. **Disable affordance for the startup warm** — plan default: **not** in this
   PR. It is a policy question (air-gapped / egress-monitored installs), and the
   design left it as a follow-up. Flag it in the PR description so the operator
   can override.
3. **`ApiDeps` churn (37 real literals across 9 files)** — plan default: the
   single shared `noOllamaReadiness = pure RdPending` constant in
   `test/Seal/TestHelpers/ApiTestHarness.hs`, exactly as design D6.2 directs,
   referenced by every literal. If that proves noisy in review, the alternative
   is a `Default` instance for `ApiDeps` (none exists today), which is a larger
   refactor and is **not** planned here.

## Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| `ApiDeps` 37-literal churn across 9 files causes merge conflicts with parallel work | High (the .cabal and `test/Main.hs` are named merge hotspots) | Land wiring in as few commits as possible; rebase on `main` before opening the PR; keep .cabal edits minimal and adjacent |
| `classifyProbeFailure` regresses to a message match | Medium | Test 16 uses **real** connects, not synthesized exceptions; the design's empirical evidence is in the doc |
| `extractHost` fix over-blocks and breaks `Seal.Web.Fetch` | Medium | DoD 4 re-asserts the loopback/private-must-**pass** cases (`172.32.0.1`, `100.128.0.1`, `93.184.216.34`) |
| Test 25 could be written as a weak textual check that passes even if the token-stamping manager is wired in another way | Medium | Resolved in revision 3: test 25 is a **wiring-site behavioural assertion** over an injected manager, per design D2.9, never a source grep. Test 24 (listener observes no `Authorization`) independently catches it at the wire. |
| Frontend focus-refetch tests are flaky | Medium | Assert on the fetch call count after dispatching a `focus` event; keep existing 1079-test baseline green |
| `sysctl` absent (macOS GUI/launchd PATH) | Medium | Absolute path with plain-PATH fallback; memoise only `Just` (WU-B DoD 9) |
| HPC coverage not wired, thresholds unmeasurable | Known | Do not claim coverage numbers in any report; state the gate as `make test` |

## Definition of Done for the PR

- [ ] All WU-A DoD items 1–25 verified with file:line or command evidence
- [ ] All WU-B DoD items 1–11 verified with file:line or command evidence
- [ ] Issue #334's own DoD list satisfied item by item
- [ ] `make check` green; frontend suite green
- [ ] `git diff --name-only main` ⊆ declared file scopes
- [ ] No `~/.seal/` writes; no `sh -c`; no `--no-verify`; no force-push
- [ ] `self-reflect` run and knowledge-base updates committed **in** this PR
- [ ] PR body carries `Closes #334` and flags the design's follow-ups #1–#4
      (notably: `ollamaNeedsKey` is **not** fixed by this PR)
- [ ] `NewSessionComposer` deleted, with the pre-deletion grep recorded
