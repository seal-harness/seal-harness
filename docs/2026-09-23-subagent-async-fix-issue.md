# fix: async subagent delegation — spawn timeout kills/retries live agents; child transcripts invisible; empty child workdirs

> Draft issue for seal-harness, prepared for human review per the
> human-authorship rule. Observed in session `20260923-065201-354`
> (plan-review gate on the dorne repo): every `AGENT_MANAGE start`
> attempt "failed", yet 13 child agents ran — several to completion with
> 300–580 KB transcripts. Nothing was retrievable from the parent side.

## Problem

### 1. Synchronous spawn under a 120s timeout/retry race (root cause)

`AGENT_START` / `AGENT_MANAGE start` run children **synchronously** —
the parent blocks until all children finish — but the opcode declares
`toBlocking = False` (`src/Seal/ISA/Ops/Agent.hs`), so the dispatcher
wraps it in the generic per-call timeout/retry race
(`Seal.Tools.Exec.Timeout`, default 120 s, 3 retries).

Any batch that takes longer than 120 s is killed at 120 s, the **entire
spawn is retried** (spawning a whole new batch of agents), killed again,
retried again, and finally reported as
`AGENT_MANAGE failed after 3 retries (last error: timed out after 120s)`.

Meanwhile every "failed" attempt left orphaned child agents still running:
`registerChild` only runs after `handleStart` returns, which it never
does — so the orphans are unregistered, invisible to `AGENT_INSTANCES`,
and unstoppable via `AGENT_STOP`/`AGENT_INTERRUPT`. They keep burning
provider tokens until their own `child_timeout_seconds` (default 600 s)
expires.

The delegation module's own `child_timeout_seconds` (600 s default,
per-child, the correct bound) is preempted by the outer 120 s race and
never gets a chance to govern.

### 2. Retry loop has no side-effect awareness

`shouldRetry (ToolTimeout _) = True` re-executes the opcode on timeout.
For an idempotent shell command that's fine; for "spawn N agents" it is
a fan-out amplifier: 4 attempts × 3 children = 12 orphaned agents in the
observed session.

### 3. Child transcripts invisible to SESSION_GET / SESSION_SEARCH / SESSION_LIST

Child transcripts live at
`sessions/<parent-session>/agents/<child-session>/conversation.jsonl`
(`agentSessionDir` in `Seal/Config/Paths.hs`). The session opcodes only
scan top-level `sessions/*/conversation.jsonl`, so the parent's
"no retrievable transcripts" conclusion was literally true despite
megabytes of review work on disk. The `ChildResult.child_session` id
needed to read them was never returned to the parent.

### 4. Every child gets a fresh EMPTY workdir

`dwdMkUIOEnv` builds the child's `UIOEnv` from the child's fresh session
id → fresh empty workdir. The reviewer goals referenced files in the
parent's workdir (`docs/plans/provisioner-wiring-plan.md`, the dorne
clone), which the children cannot see. Children re-cloned the repo
themselves (one from a typo'd org `equipek/dorne` vs the real
`equitek/dorne`) or gave up with "cannot review: required input missing".

### 5. AGENT_STATUS reports "stopped" with no result

Post-hoc registration (`registerCompletedAgent`) records status
`Stopped` but no summary, no `child_session`, no exit reason — so a
completed child is indistinguishable from a failed one.

## Scope of fix (async-first, no backward compatibility with the synchronous contract)

1. **`AGENT_MANAGE start` becomes asynchronous.** Fork one worker per
   task (respecting `max_concurrent_children`), register each child in
   the `AgentRuntime` at spawn time (status `Starting` → `Running`),
   and return immediately with per-child `subagent_id` + `child_session`.
   Batches run in parallel — that is the point of the `tasks` array.
2. **Child completion notifies the parent durably.** When a child
   finishes, its `ChildResult` (summary, status, `child_session`,
   exit reason) is appended to the **parent's** `conversation.jsonl` as
   a user-role harness message (via the parent transcript's single-writer
   daemon, which is thread-safe by design), so the parent's next turn
   sees "subagent X completed: …" without polling.
3. **`AGENT_INSTANCES`/`AGENT_STATUS` become live and informative.**
   Live status while running; after completion, status carries the
   summary + `child_session` + exit reason + file trace, readable from
   the registry.
4. **Spawn ops exit the timeout/retry race:** `toBlocking = True` for
   `AGENT_MANAGE`/`AGENT_START` (spawning itself is fast; the long part
   now happens in forked threads). Resolution errors (def not found,
   invalid role, paused) return immediately — never retried, never
   re-spawning.
5. **Session opcodes see child transcripts:** `SESSION_GET` resolves
   `sessions/<parent>/agents/<child>/` when the id is a child session;
   `SESSION_SEARCH`/`SESSION_LIST` surface child sessions with a
   parent-attribution marker.
6. **Child workdir anchored to the parent's workdir by default** (repo
   clones and plan files visible), with the fresh-empty isolation mode
   kept as an explicit opt-in (`context` or a config knob).
7. **Docs:** `AGENT_MANAGE` op description + schema document the async
   contract (start returns ids; results arrive as transcript messages;
   `AGENT_STATUS` for retrieval).

## Definition of Done

1. `AGENT_MANAGE start` (single + batch) returns immediately with a
   per-child result: `subagent_id`, `child_session`, `status=running`.
   Children run in parallel up to `max_concurrent_children`.
2. While children run, `AGENT_INSTANCES` lists them; `AGENT_STOP`/
   `AGENT_INTERRUPT` control them; after completion, `AGENT_STATUS`
   returns summary + `child_session` + exit reason.
3. A completed child's result is durably appended to the parent's
   `conversation.jsonl` and is visible to the parent's next turn
   (integration test).
4. No orphan re-spawning: a timed-out/killed AGENT_MANAGE call never
   re-spawns children; per-child timeout is governed solely by
   `delegation.child_timeout_seconds`.
5. `SESSION_GET`/`SESSION_SEARCH` find child transcripts by session id
   (child path), and `SESSION_LIST` shows child sessions attributed to
   their parent.
6. A spawned child can read files in the parent's workdir (repo + plan
   files) without re-cloning; fresh-empty isolation remains available as
   an explicit opt-in.
7. `make check` green; hspec coverage for each DoD item above
   (TDD: failing test first per work unit).

## Suggested work units

- WU-1: `runDelegate` async core — fork-per-task, spawn-time registry
  registration, parent-notification callback seam.
- WU-2: opcode layer — `handleStart` async path, `toBlocking = True`,
  result JSON, `AGENT_STATUS` enrichment from registry+transcript.
- WU-3: session visibility — `SESSION_GET`/`SEARCH`/`LIST` child-path
  resolution.
- WU-4: child workdir anchoring — `dwdMkUIOEnv` parent-workdir
  inheritance + opt-in isolation flag.
- WU-5: tests + docs (per-DoD specs; update `AGENT_MANAGE` descriptions
  and any gateway/OpenAPI schemas touched by the new result shape).

## Non-goals

- Backward compatibility with the synchronous AGENT_START contract
  (explicitly dropped per operator decision 2026-09-23).
- Cross-process child tracking (registry remains in-process).
- Changing `shouldRetry` semantics for non-agent opcodes.