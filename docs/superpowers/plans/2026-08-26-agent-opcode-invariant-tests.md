# Active Plan
<!-- approved: 2026-08-26 -->
<!-- gate-iterations: 3 -->
<!-- user-approved: true -->
<!-- status: in-progress -->
<!-- issue: 135 -->
<!-- branch: test/agent-opcode-invariants -->

## Resume instruction
Read `.beads/plans/active-plan.md` and continue the orchestrated execution of issue #135 (AGENT_ opcode invariant integration tests). The plan-review gate approved this plan (3 iterations, all 3 reviewers PASS on Rev 3). Work units WU-1 → WU-1.5 → WU-2 → WU-3 → WU-4 → WU-5 are sequential. Current progress is tracked in the "Execution state" section below — pick up at the next pending WU. The branch `test/agent-opcode-invariants` is already checked out. Follow the 4-phase loop per WU: IMPLEMENT → VALIDATE (`make check` or cabal test --match) → ADVERSARIAL REVIEW → COMMIT. The human checkpoint is WU-5: present the 4 failing tests to the user, who decides fix / pendingWith / defer.

## Execution state
- [x] WU-1 — Scaffold the spec + wire it (RED)
- [x] WU-1.5 — Add the stub-child-worker test seam (GREEN for the seam)
- [x] WU-2 — Definitions-group invariants #1-#7 (GREEN)
- [x] WU-3 — Lifecycle-group invariants #8-#15 (GREEN after registerChild fix)
- [x] WU-4 — Cross-group sequencing invariants #16-#17 (GREEN after registerChild fix)
- [x] WU-5 — Human checkpoint + PR (DONE — user chose option (a) fix registerChild)
- [x] WU-6 — Fix registerChild + adjust tests to the synchronous model (GREEN)

## Context for a fresh agent
- **Issue:** https://github.com/seal-harness/seal-harness/issues/135
- **Follow-up issue:** https://github.com/seal-harness/seal-harness/issues/136 (reframed at WU-5)
- **Branch:** `test/agent-opcode-invariants` (checked out from main on 2026-08-26)
- **Scope decision (user-confirmed):** "Add the test-harness seam, write 4 failing tests." The user wants the synchronous-delegation no-ops surfaced as FAILING tests (not pendingWith), then will decide at WU-5's human checkpoint whether to fix or pending.
- **Key no-ops surfaced:** `registerChild` (src/Seal/ISA/Ops/Agent.hs:489-490, `pure ()`) and `_hooks` discard (src/Seal/Agent/Runtime/Delegation/Worker.hs:155, `_hooks` parameter unused).
- **Test seam pattern to mirror:** `tdRemoteRunner :: Maybe RemoteRunner` at src/Seal/Core/TurnEngine.hs:388-395 (Nothing in production, Just in tests). The new `tdMkWorker :: Maybe AgentWorkerBuilder` mirrors this exactly.
- **Gate approval:** Feasibility PASS, Completeness PASS (after 1-line count fix), Scope & Alignment PASS — all on iteration 3 of 3.

---

# Implementation Plan — Issue #135 (Revision 3, gate-approved)

## Title
test: AGENT_ opcode invariant integration tests via the gateway API (surface synchronous-delegation no-ops as failing tests)

## User request
"Implement high level test conversations that exercise the core multi-agent opcode infrastructure. Search for invariants that we can test for in how combinations of AGENT_ opcodes will interact... the agent list called twice in a row yields the same answer. Starting an agent makes the agent list increase in size by one. Stopping an agent makes the list decrease in size by one. Etc."

Scope decision (confirmed by user): **Invariant tests only — exercise what's there, surface the no-ops as failures.** "No production code changes unless a test forces them." The user explicitly clarified at the gate escalation that exercising AGENT_START through the gateway requires a **test-harness seam** (in `test/Seal/TestHelpers/`, NOT production code), and the user chose: **"Add the test-harness seam, write 4 failing tests."**

## Revision 3 changelog (from Rev 2)
- **R-1 resolved properly (BLOCKING from Scope & Alignment review iteration 2):** Rev 2 made #9/#10/#11/#16b pure `pendingWith` (skipped, green suite). The reviewer correctly noted this violates the user's "surface the no-ops as **failures**" instruction — `pendingWith` is skipped, not failing. Rev 3 adds a new **WU-1.5** that injects a stub child-worker seam into the test harness (test infra, not production code — permitted by the user's carve-out), so AGENT_START can run through the gateway with a stub worker. #9/#10/#11/#16b become **REAL tests asserting the correct behavior** (instances=1 after start). They **FAIL** because `registerChild` is a no-op (Agent.hs:489-490) — surfacing the no-op as a failing test, exactly as the user asked.
- **Human checkpoint added at WU-5:** the 4 failing tests are the surfaced no-ops. The user reviews them at PR time and decides whether to (a) fix `registerChild` + wire `_hooks` in this PR, (b) mark them `pendingWith` and merge, or (c) defer to a follow-up. This matches the user's "then decide whether to fix the worker or mark them pending" instruction.
- **`ApiTestHarness.hs` is now EDITABLE** (test infra, not production code). Removed the Rev 2 READ ONLY restriction.
- **#136 reframed:** instead of "the harness can't exercise AGENT_START" (no longer true after WU-1.5), #136 becomes "fix `registerChild` + wire `_hooks` so the lifecycle ops actually work" — the production no-op fix the user may choose to do in this PR or defer. Update #136's body at WU-5 to reflect this.
- **#17 stays reframed** to use AGENT_INSTANCES (not AGENT_START) — it tests "lifecycle ops don't mutate the audited def store" which is meaningful even with the stub worker, and exercising it via AGENT_INSTANCES keeps it independent of the stub-worker's behavior.

## Issue DoD (revised for Rev 3)
- [x] New spec file `test/Seal/Gateway/AgentIntegrationSpec.hs` with 17 invariants.
- [x] Each invariant runs through the gateway API (`runApiTest` + `ScriptProvider`), not direct `opRun` calls.
- [x] Test-harness seam added (`test/Seal/TestHelpers/ApiTestHarness.hs` + `src/Seal/Gateway/Send.hs` + `src/Seal/Core/TurnEngine.hs`) so AGENT_START can run through the gateway with a stub child worker. **This is a production-adjacent change to SendDeps/TurnDeps (new `Maybe` fields), but it's a test-seam pattern identical to the existing `sdRemoteRunner`/`tdRemoteRunner` — `Nothing` in production, `Just` in tests. No production behavior changes.**
- [x] Invariants #9, #10, #11, #16b are REAL tests asserting the correct behavior, and they **FAIL** (surfacing the `registerChild` no-op + `_hooks` discard). The PR presents these 4 failures at the human checkpoint.
- [x] All other invariants pass (14 pass: #1-#8, #12-#15, #17, #16a; 4 fail: #9, #10, #11, #16b).
- [x] Spec wired in `test/Main.hs` and `seal-harness.cabal`.
- [x] `make check` — the 14 passing tests + scaffold green; the 4 failing tests are the delivered surfaced no-ops. **The PR is NOT merged green** — it's opened with the 4 failing tests as the surfaced no-ops, and the user decides at the human checkpoint whether to fix (→ green) or pendingWith (→ green) before merge.
- [x] PR body links `Closes #135` and explicitly calls out the 4 failing tests as surfaced no-ops, with the human-checkpoint decision options.

## File scope
- `test/Seal/Gateway/AgentIntegrationSpec.hs` (NEW) — the 17-invariant suite.
- `test/Seal/TestHelpers/ApiTestHarness.hs` (EDIT) — add `atoChildWorker :: Maybe AgentWorkerBuilder` to `ApiTestOptions`; thread it into `sdMkWorker` in `buildTestEnv`. Default `Nothing` (preserves existing tests' behavior). NOTE: `ApiTestOptions` is currently a `newtype` with one Bool field; adding a second field requires converting to `data` (mechanical, record-update syntax still works).
- `src/Seal/Gateway/Send.hs` (EDIT) — add `sdMkWorker :: Maybe AgentWorkerBuilder` to `SendDeps`; thread it into `tdMkWorker` in `mkWebTurnDeps`. Documented as a test seam mirroring `sdRemoteRunner`. `Nothing` in production.
- `src/Seal/Core/TurnEngine.hs` (EDIT) — add `tdMkWorker :: Maybe AgentWorkerBuilder` to `TurnDeps`; in `buildStartWiring` (line 886), use `fromMaybe (buildWorker td ...) (tdMkWorker td)`. Documented as a test seam mirroring `tdRemoteRunner`. `Nothing` in production.
- `src/Seal/Channels/Loop.hs` (EDIT) — add `cdMkWorker :: Maybe AgentWorkerBuilder` to `ChannelDeps`; thread into `tdMkWorker` in `mkChannelTurnDeps`. (Mirrors the Send.hs pattern for the channel surface. If the channel surface isn't exercised by the gateway tests, this can be deferred — but the field is needed for the record's completeness so construction sites don't break. Check in WU-1.5 whether ChannelDeps can omit it.)
- `src/Seal/Channel/Cli.hs` (EDIT) — the three `TurnDeps` construction sites (lines 201, 249, 274) need the new `tdMkWorker = Nothing` field. Mechanical.
- `test/Main.hs` (EDIT) — import + wire the new spec (2 lines).
- `seal-harness.cabal` (EDIT) — add `Seal.Gateway.AgentIntegrationSpec` to test-suite `other-modules` (1 line).

## Work units

### WU-1 — Scaffold the spec + wire it (RED)
**Spec:** Create the new module + cabal/Main.hs wiring so an empty spec compiles and runs 0 examples. TDD red step.
**DoD:**
- `test/Seal/Gateway/AgentIntegrationSpec.hs` exists with `module Seal.Gateway.AgentIntegrationSpec (spec) where` and `spec = describe "Seal.Gateway.AgentIntegration" $ pure ()`.
- `seal-harness.cabal` test-suite `other-modules` includes `Seal.Gateway.AgentIntegrationSpec`.
- `test/Main.hs` imports `qualified Seal.Gateway.AgentIntegrationSpec` (import block) and calls `Seal.Gateway.AgentIntegrationSpec.spec` (spec list).
- `nix develop --command cabal test --test-option=--match --test-option="Seal.Gateway.AgentIntegration"` runs and reports 0 examples, 0 failures.
**File scope:** 3 files (new spec, Main.hs, cabal).
**Verification:** cabal test with --match filter.

### WU-1.5 — Add the stub-child-worker test seam (GREEN for the seam)
**Spec:** Add a `Maybe AgentWorkerBuilder` test seam through `TurnDeps` → `SendDeps` → `ApiTestHarness`, mirroring the existing `tdRemoteRunner`/`sdRemoteRunner` pattern. When `Just`, `buildStartWiring` uses the stub worker instead of the production `buildWorker` → `mkDelegateWorker` path. The test harness sets it to a stub that returns `ChildWorkerOutcome (Just "child done") CerCompleted 0 0 (Just childSid)` immediately, so AGENT_START through the gateway completes without a real provider call.
**DoD:**
- `TurnDeps` has a new `tdMkWorker :: Maybe AgentWorkerBuilder` field (documented as test seam, mirroring `tdRemoteRunner` at TurnEngine.hs:388-395).
- `buildStartWiring` (TurnEngine.hs:886) uses `fromMaybe (buildWorker td parentSid appEnv eCfg operatorCeiling channel) (tdMkWorker td)` for `aswWorker`.
- `SendDeps` has a new `sdMkWorker :: Maybe AgentWorkerBuilder` field (mirroring `sdRemoteRunner` at Send.hs:172-178).
- `mkWebTurnDeps` (Send.hs:200) threads `sdMkWorker deps` → `tdMkWorker`.
- `ChannelDeps` (Channels/Loop.hs) gets `cdMkWorker` if needed for record completeness; `mkChannelTurnDeps` threads it. If `ChannelDeps` can omit it without breaking construction, omit and note why.
- All three `TurnDeps` construction sites in `src/Seal/Channel/Cli.hs` (lines 201, 249, 274) set `tdMkWorker = Nothing`.
- `ApiTestOptions` (ApiTestHarness.hs) gets `atoChildWorker :: Maybe AgentWorkerBuilder` (convert `newtype` to `data`); `defaultApiTestOptions` sets it `Nothing`. `buildTestEnv` threads it into `sdMkWorker`.
- All existing tests stay green (the seam is `Nothing` by default — no behavior change).
- A new helper `stubChildWorker :: AgentWorkerBuilder` is exported from `ApiTestHarness.hs` (or defined inline in the new spec) that returns `ChildWorkerOutcome (Just "child done") CerCompleted 0 0 (Just sid)` — uses the `SessionId` (second arg), not an out-of-scope `childSid`.
- `make check` green (the seam compiles, existing tests unaffected).
**File scope:** TurnEngine.hs, Send.hs, Channels/Loop.hs, Channel/Cli.hs, ApiTestHarness.hs (5 files — all mechanical additions of a `Maybe` field + threading, mirroring an established pattern).
**Verification:** `make check` green; no behavior change in existing tests.

### WU-2 — Definitions-group invariants #1-#7 (GREEN)
**Spec:** Implement the 7 AGENT_DEF_* invariants as gateway API integration tests. Each scripts the mock LLM to emit one or more AGENT_DEF_* tool calls, sends a user message, then asserts against the transcript.
**DoD:**
- #1 Def list idempotency — `AGENT_DEF_LIST` twice yields same count + ids (parse transcript JSON, compare).
- #2 Def write increases list by one — list N → write → list N+1.
- #3 Def delete decreases list by one — write → list N → delete → list N-1.
- #4 Def write is upsert — write `a1` → write `a1` (new name) → count unchanged → read returns new name.
- #5 Def read round-trips — write {id,name,provider,model} → read returns those fields (parse from transcript text).
- #6 Def delete idempotent — delete missing id → no error → list unchanged.
- #7 Def read of missing id errors — transcript shows "agent def not found".
- All 7 pass.
**File scope:** `AgentIntegrationSpec.hs` only.
**Verification:** cabal test --match "Seal.Gateway.AgentIntegration" → 7 examples, 0 failures.

### WU-3 — Lifecycle-group invariants #8-#15 (5 pass, 3 FAILING)
**Spec:** Implement the 8 AGENT_INSTANCES/START/STATUS/STOP/INTERRUPT invariants. The test harness is configured with `atoChildWorker = Just stubChildWorker` so AGENT_START runs. #9/#10/#11 assert the **correct** behavior (instances=1 after start) and **FAIL** because `registerChild` is a no-op. #14/#15 pass (failure paths that don't reach the worker).
**DoD:**
- #8 Instances empty initially — pass. Script `AGENT_INSTANCES` → transcript shows "(no agents running)".
- #9 Start increases instances by one — **REAL test, FAILS**. Script `AGENT_START {id, goal}` (with a def pre-written via AGENT_DEF_WRITE) → `AGENT_INSTANCES` → assert count = 1. Fails because `registerChild` (Agent.hs:489-490) is a no-op, so instances stays 0. The test uses `atoChildWorker = Just stubChildWorker` so AGENT_START completes without a real provider.
- #10 Stop decreases instances by one — **REAL test, FAILS** (depends on #9). Start → instances 1 (would-be) → `AGENT_STOP` → instances 0. Fails because #9 never registers, so stop is a no-op on an empty registry. Test body asserts the correct behavior.
- #11 Status of started agent is "running" — **REAL test, FAILS** (depends on #9). Start → `AGENT_STATUS` → assert "running". Fails because the registry is empty.
- #12 Stop idempotent — pass. Script `AGENT_STOP` with a non-running subagent_id → transcript shows "stopped".
- #13 Interrupt on non-running returns "subagent not running" — pass.
- #14 Start missing def returns "agent def not found" in transcript — pass. `resolveTask` (Agent.hs:480) returns Left before the worker runs.
- #15 Start missing goal is rejected (orIsError) — pass. `toAuthorize` (Agent.hs:397-403) rejects before any IO.
- 5 pass (#8, #12, #13, #14, #15), 3 FAIL (#9, #10, #11) — the 3 failures are the surfaced no-ops.
**File scope:** `AgentIntegrationSpec.hs` only.
**Verification:** cabal test → 5 pass, 3 fail. The 3 failures are the deliverable (surfaced no-ops).

### WU-4 — Cross-group sequencing invariants #16-#17 (2 pass, 1 FAILING)
**Spec:** Implement the 2 cross-group sequencing invariants. #16b is a REAL failing test (surfaced no-op); #16a and #17 pass.
**DoD:**
- #16 Full lifecycle round-trip (write → start → status → stop → delete): split into two tests:
  - (a) Def write/delete round-trip passes: write `a1` → list shows `a1` → delete `a1` → list no longer shows `a1`.
  - (b) Start/status/stop round-trip — **REAL test, FAILS** (depends on #9). The start registers (would-be), status shows "running" (would-be), stop decreases instances. Fails because `registerChild` is a no-op.
- #17 Def list unchanged by AGENT_INSTANCES — pass. Script `AGENT_DEF_LIST` (count N) → `AGENT_INSTANCES` → `AGENT_DEF_LIST` (count N, unchanged). Tests that the Trusted lifecycle op doesn't mutate the Audited def store.
- 2 pass (#16a, #17), 1 FAIL (#16b).
**File scope:** `AgentIntegrationSpec.hs` only.
**Verification:** cabal test → 2 pass, 1 fail.

### WU-5 — Human checkpoint + PR (DONE)
**Spec:** Present the 4 failing tests to the user at the human checkpoint. The user decides: (a) fix `registerChild` + wire `_hooks` in this PR → all green; (b) mark the 4 `pendingWith` and merge green; (c) defer the fix to #136 and merge with the 4 `pendingWith`. Open the PR with the 4 failures documented, update #136's body to reflect the reframe, push.
**DoD:**
- `make check` — 14 passing tests + scaffold green; 4 failing tests (#9, #10, #11, #16b) documented as surfaced no-ops.
- `hlint src/ test/` → No hints.
- Update #136's body: reframe from "the harness can't exercise AGENT_START" (no longer true after WU-1.5) to "fix `registerChild` (Agent.hs:489-490) + wire `_hooks` in Worker.hs:155 so the lifecycle ops actually work against delegated children." The stub-worker seam from WU-1.5 is NOT the fix — it lets the test RUN, but the no-op `registerChild` means the registry stays empty even when the stub worker completes.
- Push branch `test/agent-opcode-invariants`.
- `gh pr create --draft --fill --body "Closes #135"` with PR body:
  - Lists the 14 passing invariants.
  - Lists the 4 failing invariants (#9, #10, #11, #16b) as surfaced no-ops, citing `registerChild` (Agent.hs:489-490) and `_hooks` discard (Worker.hs:155).
  - States the human-checkpoint decision: (a) fix in this PR, (b) pendingWith + merge, (c) defer to #136.
- Mark PR ready for review ONLY after the user's human-checkpoint decision is applied (fix or pendingWith).
**File scope:** none (workflow) — unless the user chooses option (a) fix, which would add a WU-6 (fix `registerChild` + wire `_hooks`).
**Verification:** `make check` shows 14 pass + 4 fail (pre-checkpoint); `gh pr view` shows the PR; `gh issue view 136` shows the reframed follow-up.

## Dependency graph
```
WU-1 (scaffold) ──> WU-1.5 (test seam) ──> WU-2 (defs #1-#7) ──> WU-3 (lifecycle #8-#15) ──> WU-4 (cross-group #16-#17) ──> WU-5 (checkpoint + PR)
```
Sequential. WU-1.5 must precede WU-3/WU-4 because #9/#10/#11/#16b need the stub-worker seam. WU-2 can run before or after WU-1.5 (it doesn't use AGENT_START) but is sequenced after for simplicity.

## Technical approach
- Reuse `runApiTest Nothing` for the def-group tests (#1-#7) — no AGENT_START, no stub worker needed.
- Use `runApiTestOpts Nothing defaultApiTestOptions { atoChildWorker = Just stubChildWorker }` for the lifecycle tests that exercise AGENT_START (#9, #10, #11, #16b).
- `stubChildWorker :: AgentWorkerBuilder` returns `ChildWorkerOutcome (Just "child done") CerCompleted 0 0 (Just sid)` immediately (using the SessionId arg) — no provider call, no real turn. The child "completes" synchronously.
- Script AGENT_ tool calls via `setScript env [CompletionResponse [CbToolUse (ToolCallId "t1") (OpName "AGENT_DEF_LIST") (object [])] StopToolUse (Usage 0 0), ...]` (pattern from ApiIntegrationSpec.hs:107-109).
- Parse transcript via `getTranscript env sid` → Aeson `Value` array. WU-2 starts with a smoke test that dumps the transcript to learn the exact shape of AGENT_ opcode results before asserting.
- For list-count assertions, parse the `orParts` text of the AGENT_DEF_LIST result (newline-separated list or "(no agent definitions)").
- For the 4 failing tests: write the test body asserting the **correct** behavior (e.g. `count shouldBe 1`), let it fail. The failure message is the surfaced no-op. Do NOT catch the failure or `pendingWith` — the user wants to see the failure.

## Edge cases considered
- AGENT_DEF_LIST on a fresh session returns "(no agent definitions)" — #1 handles count 0 twice.
- AGENT_DEF_WRITE upsert preserves provenance — we assert the observable list-count-unchanged behavior, not provenance.
- AGENT_START failure paths (#14 missing def, #15 missing goal) don't reach the worker/provider — `resolveTask` (Agent.hs:480) and `toAuthorize` (Agent.hs:397-403) short-circuit. These pass without the stub worker.
- AGENT_START success path (#9, #10, #11, #16b) needs the stub worker (WU-1.5) to complete without a real provider. The stub returns immediately, so `runDelegate`'s `runOne` (Delegation.hs:510) completes, but `registerChild` (Agent.hs:489-490) is still a no-op, so `AGENT_INSTANCES` after the start still shows 0 — the test asserts 1 and fails. This is the surfaced no-op.
- The stub worker ignores `_hooks` (matching the production `mkDelegateWorker` which also ignores them at Worker.hs:155). The 4 failing tests surface BOTH no-ops: `registerChild` (instances stays empty) and `_hooks` (tool trace / files read / files written stay empty). The instances-count assertion is the primary surfacing; the trace assertions (if added) would be secondary.
- Multiple AGENT_ calls in one turn: the script is a flat list of `CompletionResponse`s; multi-turn scripts require multiple entries with tool-use + result interleaving.

## Risks (revised for Rev 3)
- **R-1 (RESOLVED):** AGENT_START through the gateway is now exercisable via the WU-1.5 stub-worker seam. No real provider call.
- **R-2: Transcript JSON parsing.** `getTranscript` returns `[A.Value]`; the exact shape of AGENT_ opcode results may differ from `orParts`. Mitigation: WU-2 smoke test dumps the transcript first.
- **R-3 (RESOLVED):** #14 boundary — verified that `resolveTask` (Agent.hs:480) returns Left before the worker runs; #14 passes without the stub worker.
- **R-4: The stub worker's `ChildWorkerOutcome` carries `childSid`, but `registerChild` ignores it.** The 4 failing tests assert `AGENT_INSTANCES` count = 1 after start. Because `registerChild` (Agent.hs:489-490) is `pure ()`, the registry stays empty regardless of the stub's outcome. The test fails at the count assertion. This is the intended surfacing. If `registerChild` were ever fixed, the same test would pass without modification — the test asserts the correct behavior, not the broken behavior.
- **R-5 (RESOLVED): The stub worker uses the `SessionId` argument** (`\_ sid _ _ -> pure (ChildWorkerOutcome (Just "child done") CerCompleted 0 0 (Just sid))`), not an out-of-scope `childSid`. Verified type-checks against `AgentWorkerBuilder = AgentDef -> SessionId -> ChildTask -> ChildRunHooks -> IO ChildWorkerOutcome`.
- **R-6 (RESOLVED): `runDelegate` does not register the child in `AgentRuntime` independently of `registerChild`.** `runOne` (Delegation.hs:510-576) does NOT call `registerChild`; that's the caller's job at Agent.hs:428 (the no-op). So the registry is empty by construction. The 4 failing tests surface this correctly.

## Gate approval record
- **Iteration 1:** Feasibility FAIL (R-1 false wiring assumption — resolveStub doesn't cover child providers), Completeness PASS, Scope & Alignment PASS.
- **Iteration 2:** Feasibility PASS, Completeness PASS, Scope & Alignment FAIL (pendingWith violates "surface as failures"; user's headline examples untested; in-scope test-harness change declined).
- **Iteration 3 (APPROVED):** Feasibility PASS, Completeness PASS (after 1-line count fix: "12 pass" → "14 pass"), Scope & Alignment PASS. User confirmed at gate escalation: "Add the test-harness seam, write 4 failing tests."