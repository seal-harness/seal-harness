# Design: Push-Based Sub-Agent Completion Notification

**Status:** Draft
**Goal:** Replace Seal's polling-based sub-agent status checking with a push-based, event-driven completion delivery system.

---

## Problem

Today, when a parent agent spawns sub-agents via `AGENT_MANAGE start`, the parent must repeatedly call `AGENT_MANAGE status` to discover when children finish. This is wasteful:

- **Token cost:** Each status check consumes a full LLM round-trip (prompt + response + tool call). A parent waiting on 3 children that each take 2 minutes may poll 20+ times, burning tokens on no-op "still running" responses.
- **Latency:** The parent only learns of completion on its next poll, adding up to one poll-interval of delay before it can synthesize results.
- **Prompt pollution:** The transcript fills with status-check turns that carry no information, diluting context for the parent's actual reasoning task.
- **Fragility:** If the parent stops polling (e.g., its turn ends, it gets interrupted), completion may go unnoticed.

The root cause: completion is **pulled** by the parent instead of **pushed** to the parent.

---

## Proposed Design: Push-Based Completion Delivery

### Core Principle

**Sub-agent completion is delivered to the parent as an automatic message — the parent never polls for it.**

When a child agent finishes, the harness:
1. Detects completion via an event/await mechanism (not polling)
2. Packages the child's result into a structured completion message
3. Injects that message into the parent agent's session as a synthetic turn
4. The parent's next LLM invocation sees the completion and incorporates the findings

The parent agent is explicitly instructed in its system context that completion will arrive automatically and that it should **not** use sleep, poll, or status-check tools while waiting.

---

## Two Execution Modes

### Mode 1: Foreground (Blocking)

The `AGENT_MANAGE start` call blocks and returns the child's result directly as the tool-call output. The parent's turn does not proceed until the child completes.

- **Best for:** Single-child tasks where the parent has nothing else to do while waiting.
- **Mechanism:** The start operation awaits a completion signal (Deferred / condition variable / future) and returns the result in-band.
- **Timeout support:** A configurable per-child timeout. On timeout, the tool returns a timeout result and the child is interrupted.
- **Interruption support:** If the parent is interrupted while blocked, all pending children are cancelled/interrupted.

### Mode 2: Background (Async with Push Notification)

The `AGENT_MANAGE start` call returns immediately with a job ID. The parent continues its turn. When the child completes, the harness injects a synthetic turn into the parent's session with the result.

- **Best for:** Multi-child parallel tasks where the parent can do useful work (or simply yield) while children run.
- **Mechanism:** The start operation enqueues the child and returns a job ID. A watcher coroutine/fiber awaits the child's completion signal, then injects the result as a synthetic user message into the parent session.
- **The parent does not need to call status** — the completion message arrives as the next turn.

```
Parent calls:  AGENT_MANAGE start (background: true, tasks: [...])
                 → returns immediately: { subagent_ids: [...], mode: "background" }
Parent yields (ends turn or does other work)
                 ...
Child A completes → harness injects synthetic turn into parent session:
                   "[Sub-agent child-a completed]
                    Result: <child's findings>"
Parent's next LLM turn sees the completion and incorporates it
                 ...
Child B completes → harness injects another synthetic turn
Parent's final turn: synthesizes all results → responds to user
```

---

## Completion Detection: Dual-Path for Robustness

Two independent detection paths run concurrently. Whichever fires first wins; the other is aborted. This covers both cross-process and in-process scenarios.

### Path A: RPC Await (Cross-Process)

A blocking await call on the child's run ID. This is a **condition-variable await** — the calling fiber/goroutine suspends until the child's lifecycle emits a terminal state. It is not a busy loop.

- Resolves when the child's agent-job lifecycle emits a terminal snapshot (completed / error / timeout / killed)
- Returns: `{ status, started_at, ended_at, result_text }`

### Path B: In-Process Event Listener (Embedded / Fallback)

A subscription to the in-process agent event stream. When a `phase === "end"` or `phase === "error"` event is emitted for the child, the listener fires.

- This is synchronous fan-out to registered listeners — no polling
- Covers the case where the child runs in the same process and the RPC path adds unnecessary overhead

Both paths converge on the same completion handler, making the system resilient to process boundary issues.

---

## Data Structures

### `SubagentRunRecord` (Durable — Persisted)

The core tracking record for each spawned child. Stored in an in-memory map AND persisted to disk so completion can be recovered after restarts.

```typescript
interface SubagentRunRecord {
  // Identity & linkage
  run_id: string              // unique run identifier
  child_session_key: string   // child's session ID
  parent_session_key: string  // parent's session ID
  controller_session_key: string  // who controls this run

  // Lifecycle
  started_at: number          // unix timestamp
  ended_at: number | null     // set when terminal
  outcome: "ok" | "error" | "timeout" | "killed" | "unknown"
  ended_reason: "complete" | "error" | "timeout" | "killed"

  // Delivery
  expects_completion_message: boolean  // does parent want push notification?
  frozen_result_text: string | null    // captured final output at completion
  announce_retry_count: number         // delivery retry counter
  last_announce_retry_at: number | null

  // Lifecycle policy
  spawn_mode: "foreground" | "background"
  cleanup: "delete" | "keep"           // child session cleanup on completion

  // Nested orchestration
  depth: number                        // spawn depth (guard against runaway recursion)
  wake_on_descendant_settle: boolean   // re-invoke child after its own descendants finish

  // Idempotency guards
  cleanup_handled: boolean
  cleanup_completed_at: number | null
  ended_hook_emitted_at: number | null

  // Suppression
  suppress_announce_reason: string | null  // e.g. "steer_restart", "killed"
}
```

### In-Memory Registry

```typescript
// Module-level, lock/atom-guarded
Map<string, SubagentRunRecord>  // keyed by run_id

// Helper queries
listRunsForParent(parentKey): SubagentRunRecord[]
findLatestRunForChild(childKey): SubagentRunRecord | null
countPendingDescendants(parentKey): number
```

### Completion Signal (Per-Child)

A promise-like single-shot async primitive (Deferred / one-shot channel / resolving future) that is resolved exactly once when the child reaches a terminal state.

```typescript
// One per running child
{
  done: Deferred<CompletionResult>  // resolved by settle()
  scope: Closeable                   // cancelled when parent session scope closes
  token: object                      // generation token — stale forks can't settle a newer job
}
```

The **generation token** is a critical safety mechanism: if a child is re-spawned (same ID, new run), the old watcher's `settle` call is rejected because its token doesn't match the current job's token. This prevents stale completions from corrupting newer runs.

---

## The Completion Delivery Chain

When a child finishes, the following sequence executes automatically:

```
1. DETECT COMPLETION
   └─ Child's agent loop reaches terminal state
   └─ Dual-path detector fires (RPC await OR in-process listener)
   └─ → calls completeRun(run_id)

2. RECORD TERMINAL STATE
   └─ completeRun sets ended_at, outcome, ended_reason
   └─ Freezes result text (reads child's last assistant reply / final output)
   └─ Persists SubagentRunRecord to disk

3. EMIT LIFECYCLE HOOK
   └─ Emit "subagent_ended" hook (idempotent — guarded by ended_hook_emitted_at)
   └─ Plugins/hooks can observe (e.g. logging, metrics, memory recording)

4. DELIVER COMPLETION TO PARENT
   └─ If expects_completion_message is false → skip (foreground mode already returned)
   └─ Build completion message:
      {
        type: "subagent_completion",
        run_id: ...,
        child_session_key: ...,
        status: "ok" | "error" | "timeout",
        result: frozen_result_text,
        duration_seconds: ...,
      }
   └─ Inject as synthetic turn into parent session:
      - For background mode: inject as a user/steer message → triggers parent's next LLM turn
      - For nested subagents (child is itself an orchestrator): inject as internal follow-up

5. CLEAN UP
   └─ If cleanup === "delete": remove child session
   └─ Unregister from in-memory registry
   └─ Cancel the watcher fiber/goroutine
```

### Delivery Retry with Backoff

If the parent session is not currently active (e.g., the parent itself is waiting on other descendants, or its turn has ended and it's between turns), the completion message is **queued** with retry/backoff:

- Up to 3 retry attempts
- Exponential backoff between attempts
- If all retries fail, the completion is stored and delivered when the parent session next becomes active

### Nested Orchestration: Descendant Settle

When a child agent has itself spawned descendants that are still pending, the completion delivery is **deferred** until all descendants have settled:

- `countPendingDescendants(childKey) > 0` → defer delivery, keep child session alive
- When all descendants complete → if `wake_on_descendant_settle` is set, re-invoke the child so it can synthesize a final summary incorporating its descendants' findings
- The child's synthesized summary is then delivered to the grandparent

This prevents partial results from being delivered upward and allows intermediate orchestrators to do synthesis before reporting.

---

## Anti-Polling Instructions

Both the parent agent's system context and the spawn response include explicit instructions:

**In the spawn response (returned to the parent LLM):**
> Sub-agents are running in the background. Completion will be delivered to you automatically as a message — do NOT call `AGENT_MANAGE status`, `sleep`, or any polling tool. Track the expected child IDs and wait for completion events to arrive. Only send your final answer after ALL expected completions have arrived. If a completion event arrives AFTER your final answer, reply with NO_REPLY.

**In the child's system prompt:**
> Your results will be auto-announced to your parent. Do not busy-poll for your own status.

---

## Recursion Safety

- **Max spawn depth:** Configurable limit (default: 3-5 levels). Prevents runaway recursive spawning.
- **Blocked tools for children:** Children cannot spawn their own sub-agents by default unless explicitly permitted (configurable per-agent-definition).
- **Cascade cancellation:** When a parent session's run scope closes (interrupt, timeout, user cancel), all children are automatically cancelled/interrupted by walking the `parent_session_key` linkage.

---

## Edge Cases

### Child Timeout
- Per-child timeout (default: 600s, configurable)
- On timeout: child is interrupted, `outcome = "timeout"`, completion message delivered to parent with timeout status
- The parent sees: `status: "timeout"` in the completion message

### Child Error
- Unhandled errors in the child agent loop → `outcome = "error"`, error text captured in `frozen_result_text`
- Completion message delivered with `status: "error"` and the error message

### Parent Interrupted While Children Running
- All pending children receive interrupt signals
- Completion messages for interrupted children have `status: "killed"`
- If the parent session is terminated (not just paused), completions are suppressed (`suppress_announce_reason = "killed"`)

### Parent Session Restart / Recovery
- `SubagentRunRecord` is persisted to disk
- On restart, the registry loads persisted records
- Children that were still `running` are marked `outcome = "unknown"` and a completion message is delivered to the parent on its next turn
- Children that had `ended_at` set but `cleanup_handled = false` have their completion re-delivered

### Stale Completion (Re-Spawned Child)
- Generation token mismatch → old watcher's `settle` call is rejected
- Only the current generation's completion is delivered

### Completion Arrives After Parent's Final Answer
- The parent is instructed to reply with `NO_REPLY` (a special token that does not produce user-visible output but acknowledges the completion was received)
- This prevents the parent from re-opening a completed task

---

## Migration Path

### Phase 1: Add Background Mode + Push Delivery (No Breaking Change)
- Add `mode: "background"` option to `AGENT_MANAGE start`
- Implement the completion detection + synthetic turn injection for background mode
- Keep existing `status` polling working for foreground mode (backward compatible)
- Update agent system prompts to prefer background mode and not poll

### Phase 2: Make Background the Default
- Default `AGENT_MANAGE start` to background mode
- Foreground mode becomes opt-in (`mode: "foreground"`)
- The `status` action remains available but is documented as "for debugging only, not for completion checking"

### Phase 3: Deprecate Polling
- `AGENT_MANAGE status` is deprecated for completion checking
- Retained for observability/debugging (listing running agents, inspecting state)
- The agent system prompt explicitly forbids polling for completion

---

## Summary of Key Design Decisions

| Decision | Rationale |
|---|---|
| **Push, not pull** | Eliminates token waste, reduces latency, simplifies the parent's reasoning loop |
| **Dual-path detection** | Robustness across process boundaries and embedded scenarios |
| **Synthetic turn injection** | Reuses the existing session/message infrastructure — no new delivery channel needed |
| **Durable records** | Completion survives restarts; no lost results |
| **Generation tokens** | Prevents stale completions from corrupting re-spawned jobs |
| **Nested orchestration support** | Intermediate orchestrators can synthesize before reporting upward |
| **Retry with backoff** | Handles transient delivery failures (parent between turns) |
| **Explicit anti-polling instructions** | Prevents the LLM from falling back to polling habits |
| **Two modes (foreground/background)** | Simple tasks get simple blocking; complex parallel tasks get async push |
| **Cascade cancellation** | Clean teardown when parent is interrupted or terminated |