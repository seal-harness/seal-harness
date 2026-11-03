# Implementation plan — subagent `continue`

<!-- date: 2026-11-03 · rev 4 (plan gate r1 FAIL/FAIL/PASS · r2 FAIL/FAIL/PASS · r3 FAIL/FAIL/FAIL — all r3 findings applied; gate cap reached, operator decision pending) -->
<!-- branch: agent/subagent-continue · design: docs/superpowers/specs/2026-11-03-subagent-continue-design.md (rev 4 + rev 5/6 amendments) -->

**Build contract:** every WU compiles and passes `make check` on its own. A
signature change owns all of its call sites in that WU.

**Seam (single authoritative shape — supersedes the design's `IO ()` sketch):**

```haskell
type SpawnCallback =
  SubagentId -> AgentDef -> SessionId -> ChildTask -> (IO ChildResult) -> IO ChildResult
```

- `spawnOne` (forked thread):
  `r <- spawnCallback sid def csid task (bracketSem sem body); callback r`
  where `body = runChildTask …` when a cap applies, else plain `runChildTask`.
  The semaphore wraps **only the run body**, so a queued child is still
  registered and visible; `callback` stays owned by `runDelegateAsync`, so the
  four `takeMVar resultMVar` tests keep working (lambdas become
  `\_ _ _ _ body -> body`).
- The opcode's spawn callback (`runNewChild`): `aiWorkerThread := Just myThreadId`
  → run body → `endRun` → return the result; on exception `registerRunCrash`
  and return the error `ChildResult`.
- `continue` (`runClaimedChild`): `endRun` → deliver, honouring the registry's
  `Delivery` verdict.

## Work units

### WU-1 — `Seal.Agent.ConvRepair` (pure)

**Files:** `src/Seal/Agent/ConvRepair.hs` (new),
`test/Seal/Agent/ConvRepairSpec.hs` (new), `seal-harness.cabal`
(`exposed-modules` + test `other-modules`), `test/Main.hs`.

**DoD**
1. `repairDanglingToolUse :: [Message] -> ([Text], [Message])` —
   `(unrepairableIds, repaired)`. For the **final** assistant message carrying
   `CbToolUse` ids with no matching `CbToolResult` after them, appends one
   `Message User [CbToolResult …]` per id (`isError = True`) with text
   "interrupted before this tool returned; it may have partially or fully
   completed — verify with a read or a status check before retrying."
2. Complete / empty / results-only tails → `([], input)`.
3. Unmatched ids in earlier turns → `unrepairableIds`, messages unchanged.

**Verification (C):** unmatched → 1 repair; partial tail (2 uses, 1 answered) →
1; `repair . repair == repair`; input is a prefix of output; complete tail → no
findings; QuickCheck over bounded block combinations.

**Depends on:** nothing.

### WU-2 — Registry instance shape (+ all call sites)

**Files:** `src/Seal/Agent/Runtime/Registry.hs`,
`src/Seal/ISA/Ops/Agent.hs` (`subagentIdField`, `startAgent`/
`registerRunningAgent` call shapes only), `test/Seal/Agent/Runtime/RegistrySpec.hs`,
`test/Seal/ISA/Ops/AgentSpec.hs`, `test/Seal/Command/ShutdownSpec.hs`,
`test/Seal/TestHelpers/` (new `mkTestAgentDef` if a module is added),
`seal-harness.cabal` + `test/Main.hs` (only if new).

**DoD**
1. `AgentInstance` (8 → 15 fields), named-field construction everywhere:
   `aiTask :: !(Maybe ChildTask)`, `aiDef :: !(Maybe AgentDef)`,
   `aiTaskIndex :: !Int`, `aiWorkerThread :: !(Maybe ThreadId)`,
   `aiGeneration :: !Int`, `aiOrigin :: !SpawnOrigin`, `aiRuns :: !Int`,
   `aiLastActivity :: !UTCTime`; `aiThreadId` deleted.
2. `SpawnOrigin` in `Registry.hs`.
3. Custom `Show` eliding `aiTask`, `aiDef`, `aiResult` bodies.
4. `startAgent` extended; **9** sites adapted (`RegistrySpec.hs:42,59,80,85,98,
   114,132,165`; `AgentSpec.hs:818`).
5. `registerRunningAgent` extended; sites adapted (`Ops/Agent.hs:848`,
   `RegistrySpec.hs:141`, `ShutdownSpec.hs:72`). **At this commit the old
   `SpawnCallback` cannot yet supply the real `ChildTask`, so these sites pass
   `Nothing`/`0` and WU-4 replaces them with real values** — no test asserts the
   placeholder values.
6. `aiRuns` starts at **1** for a spawn (so `#n` and the budget are correct for
   post-hoc `registerFinishedAgent` too).
7. `SubagentId`'s constructor stays exported (rev-5 amendment 7).

**Verification (R):** `show` omits goal/system prompt/summary and keeps
ids/status/origin/runs; `startAgent` forks and reports `Running`; adapted specs
compile and pass; `aiRuns == 1` for a fresh spawn.

**Depends on:** nothing.

### WU-3 — Registry lifecycle, ownership, retention (+ all call sites)

**Files:** `src/Seal/Agent/Runtime/Registry.hs`,
`src/Seal/ISA/Ops/Agent.hs` (four shims, `handleInstances`, `handleStatus`,
`handleStop`, `handleInterrupt`, `spawnCb`, the background completion `callback`),
`src/Seal/Core/TurnEngine.hs` (shim wiring), `src/Seal/Command/Shutdown.hs`,
`test/Seal/Agent/Runtime/RegistrySpec.hs`, `test/Seal/Command/ShutdownSpec.hs`,
`test/Seal/ISA/Ops/AgentSpec.hs`, `test/Seal/ISA/IntegrationSpec.hs`,
`test/Seal/Phase5Spec.hs`, `test/Seal/Gateway/AgentIntegrationSpec.hs`.

**DoD**
1. `ownsChild`, owner-scoped `listAgentsFor`/`agentStatusFor`/`stopAgent`/
   `interruptAgent` (non-owned → `Left`, never echoing the owner). Global
   `listAgents` kept for `Command/Shutdown`; `agentInstanceBySubagentId` stops
   being exported and `handleStatus` switches to `agentStatusFor`.
2. `StopOutcome = StopOk | StillShuttingDown`.
3. `registerFinishedAgent` replaces the dead `registerCompletedAgent`.
4. `endRun` (ownership-guarded on `aiWorkerThread == myThreadId`) sets
   `aiLastActivity`.
5. Terminal writes (`registerCompletedAgentResult`, `registerRunCrash`,
   `registerFinishedAgent`, `stopAgent`) set `aiLastActivity`, never touch
   `aiWorkerThread`, and return `Delivery = DeliverResult | SuppressDelivery`
   under this **two-case rule**:
   - **new-claim stale** (generation moved on because a *new run* claimed) →
     no-op, `SuppressDelivery`, debug log;
   - **intentional-terminal stale** (generation bumped by this run's own
     `stop`/`interrupt`) → **record `aiResult`**, `SuppressDelivery`.
   A stop that lands *after* the completion write cannot un-deliver an
   already-fired sidecar/wake (stated, accepted).
6. `stopAgent` bumps the generation before killing, kills under a bounded race
   (kill in its own thread vs. ≤500 ms settle poll), then one generation-guarded
   write (`Stopped`, `aiWorkerThread := Nothing`); expiry → `StillShuttingDown`
   and no write. Stopping an already-`Stopped` child → `StopOk`, no change.
7. `interruptAgent` owner-scoped, generation bump, guarded write.
8. `resumeAgent` (sole claim entry point, `mask`ed, handle recorded in the
   parent, body under `restore`, release-to-`Stopped` on every failure, sink
   `TMVar` always filled); a claim racing a prune cannot resurrect the id.
9. `workerSettled`, `countRunningChildren`, `countFinishedChildren`,
   `pruneRetained` (≤32/parent by `aiLastActivity`) called at the end of every
   terminal write for that parent.
10. `pollUntil` helper (10 ms ticks).
11. The four shims take `SessionId`, route through the scoped API, **and
    validate `subagent_id` as text** (non-empty, ≤256, no control characters) so
    their `orRecorded`/debug lines cannot be forged; `TurnEngine.hs:302-306`
    passes `sid`. `agentStartOp` is deliberately *not* changed (spawn is
    wiring-scoped).

**Verification (R/A/I):** stop retains `Stopped`; stop waits for cleanup
(`finally` IORef); expiry (`mask_` busy loop) → `StillShuttingDown`, unchanged
status; stop never kills a non-worker thread; **stop racing a completed run
keeps `aiResult` and returns `SuppressDelivery`**; **stop mid-run of a
background *spawn* produces no sidecar line and no wake**; `endRun` clears
before the callback observes it; **a spawned background child is stoppable**
(`aiWorkerThread` set by the spawn path); two concurrent `resumeAgent` → one
`Right`; failed claim leaves status/`aiResult`/generation/`aiRuns` untouched and
releases to `Stopped`; thrown body → `Stopped`/`Crashed`, never `Starting`;
handle recorded before body runs; stale-generation no-op; non-owner refused on
all four functions **and** the four shims; shim `subagent_id` validation
(empty/257 chars/control chars → `Left`); `pruneRetained` through the API (33 →
32, oldest evicted); stop idempotent on a retained `Stopped`; claim racing prune
does not resurrect; `Crashed`/`Interrupted` claimable; `IntegrationSpec.hs:798,
816,826`, `AgentIntegrationSpec.hs:258-271,301-325,328-349,356-390,463-484`
assertions and `Phase5Spec.hs:172-176,276-278` wiring updated.

**Depends on:** WU-2.

### WU-4 — Delegation: `SpawnCallback` returns a result + `runChildTask`

**Files:** `src/Seal/Agent/Runtime/Delegation.hs`,
`src/Seal/ISA/Ops/Agent.hs` (`spawnCb` only),
`test/Seal/ISA/Ops/AgentSpec.hs` (7 lambdas + `runDelegate*` cases),
`test/Seal/TestHelpers/` (`mkTestAgentDef`, if not created in WU-2).

**DoD**
1. `SpawnCallback` per the seam above; `spawnOne` keeps the child-side cap
   around only the run body and still calls `callback` after it.
2. `runChildTask` exported; `runDelegateAsync.runWorker` and
   `runDelegate.runOne` delegate to it.
3. The resolve-error path still calls `callback (mkErrorResult …)`.
4. `spawnPausedMsg` exported; duplicated literals removed.
5. The opcode's `spawnCb` records `aiWorkerThread`, runs, `endRun`s, returns the
   result (or `registerRunCrash` + error result) — the tree is green here.
6. The 7 lambdas become `\_ _ _ _ body -> body`.
7. **Behaviour change, tested:** delegating `runOne` to `runChildTask` changes a
   *foreground* timeout result from `crChildSession = Nothing` to
   `Just childSid`; assert the new rendering in `encodeForegroundResults`.

**Verification (A):** all existing `runDelegateAsync`/`runDelegate` cases pass,
including the four completion `takeMVar` assertions and the resolve-error case;
batch cap (`mc <= 3`) holds; a spawned child is registered **before** it waits
on the cap; foreground timeout result asserts the new `child_session` value.

**Depends on:** WU-2, **WU-3**.

### WU-5 — `AGENT_MANAGE continue`

**Files:** `src/Seal/ISA/Ops/Agent.hs`, `test/Seal/ISA/Ops/AgentSpec.hs`.

**DoD**
1. `AgContinue`; `authorizeAgentManage` validates `subagent_id` (non-empty,
   ≤256, no control characters), `prompt` (non-empty, ≤32 KiB, no
   NUL/control chars), strict `mode` for `continue` only, and rejects start-only
   fields (`id`/`goal`/`context`/`role`/`tasks`) with
   `continue: "<field>" is a start-only field; pass the instruction as "prompt".`
2. **Message selection (the "restart" half of the ask):** `prompt` present →
   `prompt`; absent → `continueNudge` (exact text per design); if the child's
   `conversation.jsonl` is empty → the stored `ctGoal`; if the child's session
   directory is missing → refusal (precondition 11).
3. **Ordering, pinned:** (a) JSON shape parse + pure-gate validation (prompt,
   mode, start-only fields, `subagent_id` text); (b) lookup → unknown-id;
   (c) ownership; (d) paused; (e) settled (bounded wait); (f) child's own
   children; (g) budget (background only); (h) atomic claim re-checks
   ownership/status/snapshot/run-budget/missing-dir. Eleven refusal texts as
   specified; a refused continue consumes no run budget.
4. `handleContinue`: foreground → `resumeAgent` + block on the sink, in-band,
   no sidecar/wake; background → ack + delivery.
5. `runAndReport` shared; honours `Delivery`; **preserves
   `shouldDeferDelivery`** before sidecar + wake.
6. Delivery texts, vocabulary table (5×5), summary→`crError`→placeholder,
   timeout clause, forked wake, `noReplyClause` replacing both spawn variants.
7. `toDesc`, six-action enum, three property descriptions exactly per design.
8. `orRecorded` fields; `toTrust == Trusted`.
9. Refusal logging + success fields; never the prompt body / `show inst`.
10. `AGENT_STATUS` vocabulary + `runs=` + `resumable:` + `aiOrigin`;
    `AGENT_INSTANCES` live-only + summary; `STOP`/`INTERRUPT` outcome text +
    suppression.
11. Foreground `start` registration via **post-hoc results**, keyed by
    `crSubagentId`/`crTaskIndex`/`crChildSession` (the resolver receives no
    index and batch `runOne`s are forked, so a resolver-capture zip is not
    deterministic); the def is captured per task value. Duplicate/ambiguous and
    timeout (`crChildSession = Nothing`) cases are handled explicitly — a
    foreground child that cannot be paired is simply not registered (its
    `continue` then fails precondition 1 or 8, never mis-registers).
    Results carry `continueHint`.
12. The `aswWorker` reuse and the resulting child-directory/anchor stability is
    a DoD item, not an assumption.

**Verification (A):** every A row in the design's table, plus: `toDesc`/
property-text assertions; foreground header format; `runs=<n>`; 32 KiB boundary;
background-only budget asymmetry; timeout clause; `orRecorded` fields;
refusal-reason log; `toTrust`; **`prompt` absent → `continueNudge`; empty
history → `ctGoal`; prompt → prompt**; **`subagent_id` text rejection
(empty/257/control)**; **paused (#3) and child's-own-children (#6) via real
state**, not just texts; **`shouldDeferDelivery` still defers**; foreground
timeout `child_session`; continue on a foreground-start child (single **and**
batch, so S4 cannot mask a mis-registration); continued child's second run has
`aiRuns == 2`; stop → settle → `continue` succeeds; `continue` inside the
kill→cleanup window waits then succeeds; foreground-parent-dies leaves
`aiResult` and no sidecar; role narrow-only (leaf def cannot reach
`AGENT_START`); depth unchanged; no new filesystem path (the child dir is the
same one spawn uses).

**Depends on:** WU-3, WU-4.

### WU-6 — Worker/wiring fixes

**Files:** `src/Seal/Agent/Runtime/Delegation/Worker.hs`,
`src/Seal/Handles/Transcript.hs`, `src/Seal/Agent/Loop.hs`,
`test/Seal/Handles/TranscriptSpec.hs`,
`test/Seal/Agent/Runtime/Delegation/WorkerSpec.hs`,
`test/Seal/Agent/LoopSpec.hs`.

**DoD**
1. `itwSetSecretOps childTHandle (secretOpNames childReg)` in
   `mkDelegateWorker`'s bracket.
2. `redactMessages` also redacts `CbToolUse` inputs for secret ops.
3. `writeChildMeta` preserves an existing `smCreatedAt` (read inline; the
   `loadParentMeta` local-mirror is the precedent — no new reader module).
4. `runTurn` calls `repairDanglingToolUse` after `itwReadConversation` and logs
   each unrepairable id.

**Verification:** child transcript redacts a secret `get` result **and** a
secret `put` value; `smCreatedAt` stable across a resumed run; `LoopSpec`
asserts the repaired conversation reaches the provider and the log line appears
for a mid-history id.

**Depends on:** WU-1, WU-4.

### WU-7 — Capture provider + end-to-end conversation

**Files:** `test/Seal/TestHelpers/CapturingProvider.hs` (new),
`test/Seal/TestHelpers/ApiTestHarness.hs` (**provider injection**: replace the
`atoChildProvider :: Bool` hard-wiring of `ScriptProvider` with an injectable
provider option; keep `atoChildProvider` as a shorthand so existing callers are
unchanged), `seal-harness.cabal` + `test/Main.hs` (register new modules),
`test/Seal/Gateway/AgentIntegrationSpec.hs`,
`test/Seal/ISA/IntegrationSpec.hs`.

**DoD**
1. `CapturingProvider` records each request's `Message` list; installable via
   the harness option (each scenario gets its own instance — the shared child
   script queue race is documented at `AgentIntegrationSpec.hs:568-571`).
2. `AgentIntegrationSpec` via `runOrchestrationTest`: S1 (content prefix), S2
   (goal exactly once), S3 (3-run background conversation), S3b (continue from
   inside the wake), S4 (3 consecutive foreground continues), and the wake runs
   off the child worker thread (compared `ThreadId`s).
3. `IntegrationSpec`: S5 kill seam — a test-local opcode whose `toRun` signals
   an `MVar` then blocks; the test kills `aiWorkerThread`, continues, and
   asserts **via the captured request** (provider installed in that test's
   wiring) that no dangling `tool_use` is sent.

**Depends on:** WU-5, WU-6.

### WU-8 — Docs, PR body, final gate

**Files:** design doc, module haddocks, `README.md` (no change expected).

**DoD**
1. Haddocks corrected; orphaned fragment at `Ops/Agent.hs:676-678` removed.
2. **Design doc reconciled with amendments 1-9** — specifically strike/supersede:
   DoD 7's unexported `SubagentId`; DoD 13's strict `mode` for `start` and the
   replaced `parseSpawnMode` test; the rollout line about `start`; the
   `mkSubagentIdFromText` test row; the `repairDanglingToolUse :: [Message] ->
   [Message]` signature; the `SpawnCallback … -> IO ()` sketch; the "five
   actions" count; the `preconditions 1-10` numbering; and the
   "all five actions enforce ownership" claim (it is six, plus four shims).
3. Design header records the operator decision (`user-approved: true`, gate
   iterations, non-negotiable prerequisites).
4. PR body: the behaviour-change list (unknown token, owner-scoped live-only
   `AGENT_INSTANCES`, stop/interrupt retention + delivery suppression,
   `aiRuns ≤ 50`, strict `mode` for `continue` only, top-level-only availability,
   legacy-shim deletion as follow-up, prospective redaction + scrub follow-up,
   the foreground timeout `child_session` change, S4 tested as integration).
5. S8 manual 3-turn session run once; transcript referenced.
6. `make check` green; `make test`/`make check` wall times recorded.
7. No `--no-verify`.

## Rollback

No persistent migration. `WU-1` is independently revertible; **WU-4 and WU-5
must revert together** (the seam and its only continue consumer). Secret
redaction is irreversible by design (already-redacted transcripts stay
redacted). Repaired lines are ordinary `user`/`tool_result` messages readable by
older code. Retention is in-process and vanishes on restart; the `AGENT_STATUS`/
`AGENT_INSTANCES` behaviour changes are not revert-safe for an in-flight parent,
which is acceptable because they are in-process and the PR lands atomically.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Signature churn | every WU owns its call sites (exhaustive lists above) |
| Callback double-delivery | the spawn callback *returns* the result; `runDelegateAsync` still calls `callback` |
| Registration visibility | registration outside the child-side semaphore |
| Stop/kill timing flakes | bounded fast-exit polls; only bounded-wait tests exceed ~150 ms |
| Retention unbounded | `pruneRetained` from every terminal write, tested through the API |
| `ScriptProvider` churn (78 uses) | separate `CapturingProvider` + an injectable option; `ScriptProvider` untouched |
| Mis-registering batch foreground children | post-hoc keyed by `crSubagentId`; batch + timeout rows; unpaired → not registered |

## Commit sequence

1. `test(conv-repair)` + `feat(conv-repair)` — WU-1
2. `refactor(registry): instance shape` — WU-2
3. `refactor(registry): lifecycle, ownership, retention` — WU-3
4. `refactor(delegation): spawn callback returns result + runChildTask` — WU-4
5. `feat(agent): continue action` — WU-5
6. `fix(worker): redaction, createdAt, repair wiring` — WU-6
7. `test(integration): multi-turn conversation` — WU-7
8. `docs: continue behaviour changes` — WU-8
