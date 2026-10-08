# Implementation Plan: Push-Based Sub-Agent Completion Notification

**Design:** `docs/superpowers/plans/2026-10-05-design-subagent-completion-notification.md`
**Branch:** `subagent-completion-notification`
**Status:** Revised — pending Plan Review Gate (iteration 2)

---

## Context

The design describes a push-based completion notification system to replace
polling. The basic sidecar mechanism already exists on `main`:
- `appendCompletionToSidecar` writes completion messages to a sidecar JSONL
- `readAndClearCompletions` reads/clears the sidecar at turn start
- `completionMessage` formats child results into user-role messages
- The completion callback in `handleStart` wires it together

**Already implemented in the codebase (confirmed by review):**
- Max spawn depth enforcement: `parentDepth >= maxDepth` check in
  `runDelegateAsync` (Delegation.hs:658). Current default is 1, cap is 3.
  The design asks for default 3-5 — this plan adjusts the default.
- Blocked tools for children: `Worker.childBlocklist mRole orchEnabled`
  in `buildChildRegistryAdapter` (TurnEngine.hs) blocks spawning for leaf
  children. The design asks for per-agent-definition configurability —
  this plan adds that config field.
- Background mode timeout: `runDelegateAsync` already handles timeouts
  via `timeout micros runWithCatch` and `mkTimeoutResult` (Delegation.hs).
- Background mode error: `runDelegateAsync` already handles errors via
  `catch` and `mkErrorResult` (Delegation.hs).
- `interruptAgent` is already exported from `Registry.hs`.

## Work Units

### WU-1: SubagentRunRecord — Durable Tracking Foundation + Lifecycle Hooks + Session Cleanup

**Goal:** Create a durable record type and in-memory registry that tracks
every spawned child's full lifecycle. Implement lifecycle hook emission
and session cleanup on completion.

**Files:**
- `src/Seal/Agent/Runtime/RunRecord.hs` (new) — `SubagentRunRecord` type,
  `RunRecordRegistry` (STM-backed), persistence to disk, helper queries,
  lifecycle hook emission, session cleanup
- `src/Seal/Agent/Runtime/Registry.hs` (modify) — cross-reference
  `RunRecordRegistry` from `AgentInstance` (or add as a sibling field)
- `src/Seal/Core/Backends.hs` (modify) — construct `RunRecordRegistry`
  alongside `AgentRuntime` in the `Backends` record
- `src/Seal/ISA/Ops/Agent.hs` (modify) — create record on spawn, update
  on completion, emit lifecycle hook, perform session cleanup
- `src/Seal/Core/TurnEngine.hs` (modify) — wire the registry into
  `buildStartWiring` and `buildChildRegistryAdapter`
- `src/Seal/Handles/Transcript.hs` (modify) — recovery on restart
  (load persisted records with `ended_at` but `cleanup_handled = false`)
- `test/Seal/Agent/Runtime/RunRecordSpec.hs` (new) — unit tests
- `seal-harness.cabal` (modify) — add new modules
- `test/Main.hs` (modify) — wire new spec

**DoD:**
- [ ] `SubagentRunRecord` has all fields from the design: run_id,
  child_session_key, parent_session_key, controller_session_key,
  started_at, ended_at, outcome, ended_reason, expects_completion_message,
  frozen_result_text, announce_retry_count, last_announce_retry_at,
  spawn_mode, cleanup, depth, wake_on_descendant_settle,
  cleanup_handled, cleanup_completed_at, ended_hook_emitted_at,
  suppress_announce_reason
- [ ] `RunRecordRegistry` provides: `createRun`, `completeRun`,
  `listRunsForParent`, `findLatestRunForChild`, `countPendingDescendants`
- [ ] Records persist to disk as JSON (one file per run under
  `sessionDir/agents/<run_id>/run-record.json`)
- [ ] Generation token: each run has a unique token; `completeRun` rejects
  stale tokens (re-spawned children with same ID)
- [ ] All operations are STM-safe (no races)
- [ ] **Lifecycle hook emission**: on completion, emit a `subagent_ended`
  hook. Idempotent — guarded by `ended_hook_emitted_at` (only emitted
  once per run). The hook is an internal event that plugins/hooks can
  observe (logging, metrics). Implemented as an extensible callback list
  on the `RunRecordRegistry`.
- [ ] **Session cleanup on completion**: when `cleanup === "delete"`,
  remove the child session directory and unregister from the in-memory
  registry. Guarded by `cleanup_handled` / `cleanup_completed_at`
  (idempotent).
- [ ] **Parent restart recovery**: on restart, load persisted records.
  Records with `ended_at` set but `cleanup_handled = false` have their
  completion re-delivered. Still-running children get
  `outcome = "unknown"`.
- [ ] Tests: record creation, completion, persistence, queries, stale
  token rejection, lifecycle hook idempotency, session cleanup, restart
  recovery

### WU-2: Foreground (Blocking) Mode

**Goal:** Add `mode: "foreground"` to `AGENT_MANAGE start` that blocks
and returns the child's result directly as the tool-call output.

**Files:**
- `src/Seal/ISA/Ops/Agent.hs` (modify) — parse `mode` field, dispatch to
  `runDelegate` (sync) for foreground, `runDelegateAsync` for background
- `src/Seal/Agent/Runtime/Delegation.hs` (modify) — ensure `runDelegate`
  is usable from the opcode layer (it currently takes a different resolver
  signature than `runDelegateAsync` — `(AgentDef, AgentWorkerBuilder,
  SessionId)` vs `(AgentDef, AgentWorkerBuilder)` + separate `mintSession`)
- `src/Seal/Agent/Runtime/Delegation/Worker.hs` (modify — if the resolver
  signature change affects the worker builder wiring)
- `test/Seal/ISA/Ops/AgentSpec.hs` (modify) — foreground mode tests

**DoD:**
- [ ] `AGENT_MANAGE start` accepts `mode: "foreground" | "background"`
  (default: `background` — the mode field is added here but the default
  change to background is WU-3b; initially default is `background` since
  the existing behavior IS background/async)
- [ ] Foreground mode: `handleStart` calls `runDelegate` (synchronous),
  returns `ChildResult` summary as the tool result text
- [ ] Foreground mode: parent's turn blocks until child completes
- [ ] Foreground mode: per-child timeout works (returns timeout result)
- [ ] Foreground mode: child errors are returned as error results
- [ ] Foreground mode: no sidecar append (result is in-band)
- [ ] **Background mode timeout**: confirm existing `runDelegateAsync`
  timeout handling works (already implemented via `timeout micros` +
  `mkTimeoutResult`). Add an explicit test verifying timeout status
  appears in the completion message.
- [ ] **Background mode error**: confirm existing `runDelegateAsync`
  error handling works (already implemented via `catch` +
  `mkErrorResult`). Add an explicit test verifying error status appears
  in the completion message.
- [ ] Background mode: unchanged (existing sidecar mechanism)
- [ ] Tests: foreground returns result, foreground timeout, foreground
  error, batch foreground mode, background timeout confirmation,
  background error confirmation

### WU-3: Anti-Polling Instructions + Phase 2/3 Migration

**Depends on:** WU-2 (the `mode` field must exist before Phase 2 can
change the default)

**Goal:** Update spawn responses, tool descriptions, and system prompts
to explicitly instruct agents not to poll. Implement the 3-phase
migration path with explicit sequencing. Make background the default
(Phase 2). Deprecate polling (Phase 3).

**Files:**
- `src/Seal/ISA/Ops/Agent.hs` (modify) — `encodeSpawnInfos` includes
  anti-polling text for background mode; `completionMessage` includes
  NO_REPLY instruction; opcode descriptions updated; default mode
  set to `background`
- `src/Seal/Agent/PromptParts.hs` (modify) — add anti-polling guidance
  to the system prompt for agents with spawning capability (parent-side)
  and to the child's system prompt (child-side)
- `src/Seal/Agent/Runtime/Delegation.hs` (modify) — adjust
  `defaultMaxSpawnDepth` from 1 to 3 (design says "default: 3-5 levels")
- `src/Seal/Agent/Def/Types.hs` (modify) — add `adAllowSpawn :: Maybe Bool`
  field for per-agent-definition spawn permission (design: "configurable
  per-agent-definition")
- `src/Seal/Agent/Def/Workdir.hs` (modify) — encode/decode the new
  `adAllowSpawn` field
- `test/Seal/ISA/Ops/AgentSpec.hs` (modify) — verify anti-polling text
- `test/Seal/Agent/PromptPartsSpec.hs` (modify) — verify prompt guidance
- `src/Seal/Gateway/API.hs` (modify) — update `stampAgentDef` (line ~1217:
  record-literal `AgentDef` construction) to handle the new `adAllowSpawn`
  field (default to `Nothing`); update `agentInfoJson` (line ~1972) to
  expose the field to the frontend
- `test/Seal/Gateway/ApiSpec.hs` (modify) — ~10 `AgentDef` construction
  sites (positional syntax) need the new `adAllowSpawn` field (default
  `Nothing`)
- `test/Seal/RepoDiscoverySpec.hs` (modify) — ~6 record-literal
  `AgentDef` construction sites need the new field
- `test/Seal/TestHelpers/Arbitrary.hs` (modify) — `Arbitrary AgentDef`
  instance needs a new `arbitrary` for `adAllowSpawn`
- `test/Seal/Agent/Def/BackendSpec.hs` (modify) — `mkDef` helper
  constructs `AgentDef` positionally, needs the new field

**DoD:**

**Phase 1 — Anti-polling instructions (no breaking change):**
- [ ] Background spawn response includes: "Sub-agents are running in the
  background. Completion will be delivered to you automatically — do NOT
  call AGENT_MANAGE status, sleep, or any polling tool. Track the
  expected child IDs and wait for completion events to arrive. Only send
  your final answer after ALL expected completions have arrived. If a
  completion event arrives AFTER your final answer, reply with NO_REPLY."
- [ ] Completion message includes NO_REPLY instruction for completions
  arriving after the parent's final answer
- [ ] **Child's system prompt** includes: "Your results will be
  auto-announced to your parent. Do not busy-poll for your own status."
- [ ] `AGENT_MANAGE` and `AGENT_START` descriptions mention push-based
  delivery
- [ ] `AGENT_MANAGE status` description says "for debugging/observability
  only, not for completion checking"
- [ ] System prompt for orchestrator-capable agents includes anti-polling
  guidance (parent-side)

**Phase 2 — Background as default:**
- [ ] Default mode is `background` (already the existing behavior; the
  `mode` field from WU-2 defaults to `background`)
- [ ] Foreground mode is opt-in (`mode: "foreground"`)
- [ ] `defaultMaxSpawnDepth` adjusted from 1 to 3 (design: "default:
  3-5 levels")

**Phase 3 — Deprecate polling:**
- [ ] `AGENT_MANAGE status` description explicitly says polling for
  completion is deprecated
- [ ] System prompt for orchestrator-capable agents explicitly forbids
  polling for completion

**Per-agent-definition spawn permission:**
- [ ] `AgentDef` gains `adAllowSpawn :: Maybe Bool` field (Nothing =
  role-based default, Just False = never allow spawn, Just True = allow
  spawn even if role is leaf)
- [ ] `buildChildRegistryAdapter` checks `adAllowSpawn` when building the
  child's nested AGENT_START gate
- [ ] Tests: anti-polling text in spawn response, completion message,
  parent system prompt, child system prompt, `adAllowSpawn` enforcement,
  adjusted max spawn depth default

### WU-4: Cascade Cancellation

**Depends on:** WU-1 (RunRecordRegistry for parent→child linkage)

**Goal:** When a parent session is terminated (interrupt, timeout, user
cancel — NOT normal turn end), all children are automatically
cancelled/interrupted by walking the parent→child linkage.

**Files:**
- `src/Seal/Agent/Runtime/RunRecord.hs` (modify) — add
  `cancelRunsForParent` that walks the linkage and interrupts all
  pending children. Distinguishes session termination from turn end.
- `src/Seal/Core/TurnEngine.hs` (modify) — add a session-termination
  hook (distinct from the per-turn bracket) that calls
  `cancelRunsForParent`. This fires on session interrupt/abort, NOT on
  normal turn end — background children survive across turns.
- `test/Seal/Agent/Runtime/RunRecordSpec.hs` (modify) — cascade tests

**DoD:**
- [ ] When a parent session is **terminated** (interrupt, abort, user
  cancel), all pending children of that session are interrupted. This
  is NOT the same as normal turn end — background children survive
  across turn boundaries (they complete async and deliver via sidecar).
- [ ] Cascade is recursive: grandchildren are also cancelled
- [ ] Interrupted children get `outcome = "killed"` in their run record
- [ ] Completion messages for killed children have `status: "killed"`
- [ ] If parent session is terminated (not just paused), completions are
  suppressed (`suppress_announce_reason = "killed"`)
- [ ] Normal turn end does NOT trigger cascade — background children
  continue running between turns
- [ ] Tests: cascade fires on session termination, cascade fires on
  abort, recursive cancellation, suppression on termination, normal
  turn end does NOT cancel children

### WU-5: Nested Orchestration — Descendant Settle

**Depends on:** WU-1 (RunRecordRegistry for descendant tracking)

**Goal:** When a child agent has spawned its own descendants that are
still pending, defer the child's completion delivery until all
descendants have settled. If `wake_on_descendant_settle` is set,
re-invoke the child so it can synthesize a final summary.

**Files:**
- `src/Seal/Agent/Runtime/RunRecord.hs` (modify) —
  `countPendingDescendants` query, `deferDelivery` / `deliverIfSettled`
  logic
- `src/Seal/ISA/Ops/Agent.hs` (modify) — completion handler checks
  pending descendants before delivering
- `test/Seal/Agent/Runtime/RunRecordSpec.hs` (modify) — descendant
  settle tests

**DoD:**
- [ ] `countPendingDescendants(parentKey) > 0` → defer delivery, keep
  child session alive
- [ ] When all descendants complete → deliver the child's completion
  upward
- [ ] If `wake_on_descendant_settle` is set, re-invoke the child with a
  synthesis prompt before delivering
- [ ] The child's synthesized summary is delivered to the grandparent
- [ ] Tests: deferred delivery, delivery after settle, wake-on-settle
  re-invocation

### WU-6: Delivery Retry with Backoff

**Depends on:** WU-1 (RunRecordRegistry for retry tracking)

**Goal:** If the parent session is not currently active (between turns),
the completion message is queued with retry/backoff.

**Files:**
- `src/Seal/Agent/Runtime/RunRecord.hs` (modify) — retry counter,
  backoff logic, `announce_retry_count` / `last_announce_retry_at`
- `src/Seal/Handles/Transcript.hs` (modify) — sidecar append with
  retry awareness
- `test/Seal/Agent/Runtime/RunRecordSpec.hs` (modify) — retry tests

**DoD:**
- [ ] Up to 3 retry attempts with exponential backoff
- [ ] If all retries fail, completion is stored and delivered when the
  parent session next becomes active (via the existing sidecar mechanism)
- [ ] `announce_retry_count` and `last_announce_retry_at` are tracked
- [ ] Tests: retry counter increments, backoff delays, final delivery
  on parent reactivation

### WU-7: Dual-Path Completion Detection + Edge Cases

**Depends on:** WU-1 (RunRecordRegistry for completion signals)

**Goal:** Implement dual-path completion detection (condition-variable
await + in-process event listener). Handle edge cases: completion after
final answer (NO_REPLY), stale completion, parent session restart/
recovery.

**Files:**
- `src/Seal/Agent/Runtime/RunRecord.hs` (modify) — STM-based completion
  signal (TMVar per child), event listener registration
- `src/Seal/Agent/Runtime/Delegation.hs` (modify) — emit completion
  events on child terminal state
- `src/Seal/ISA/Ops/Agent.hs` (modify) — NO_REPLY handling in
  completion message
- `test/Seal/Agent/Runtime/RunRecordSpec.hs` (modify) — dual-path and
  edge case tests

**DoD:**
- [ ] Path A: STM condition await — a `TMVar` per child that is filled
  on completion; the watcher thread takes it
- [ ] Path B: in-process event listener — a subscription mechanism that
  fires on child terminal state events (new infrastructure, not
  dependent on existing `BrokerEvent` types)
- [ ] Both paths converge on the same completion handler; first wins
- [ ] Completion after parent's final answer: parent replies with
  NO_REPLY (no user-visible output)
- [ ] Stale completion: generation token mismatch → rejected
- [ ] Tests: both paths fire, first wins, NO_REPLY handling, stale
  rejection

## Dependency Order

```
WU-1 (RunRecord foundation) ──┬── WU-2 (Foreground mode)
                               ├── WU-4 (Cascade cancellation)
                               ├── WU-5 (Descendant settle)
                               ├── WU-6 (Delivery retry)
                               └── WU-7 (Dual-path + edge cases)
                                        └── WU-3 (Anti-polling + Phase 2/3)
```

WU-1 is the foundation. WU-2 depends on WU-1. WU-3 depends on WU-2
(the `mode` field must exist before Phase 2 can change the default).
WU-4 through WU-7 depend on WU-1 and can proceed in parallel after it.

**Note on parallel edits:** WU-2 and WU-3 both modify
`src/Seal/ISA/Ops/Agent.hs`, so they must be sequenced (WU-2 → WU-3)
to avoid edit conflicts. WU-4 through WU-7 each modify different aspects
of `RunRecord.hs` and `Agent.hs`, so they should also be sequenced or
carefully coordinated.

## Execution Approach

Orchestrated execution: 4-phase loop per work unit (IMPLEMENT →
VALIDATE → ADVERSARIAL REVIEW → COMMIT), sequential through the
dependency chain.
