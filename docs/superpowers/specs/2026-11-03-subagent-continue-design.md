# Subagent `continue` — resume a canceled child and talk to it

<!-- status: approved rev 5 (operator decision) · implemented on agent/subagent-continue -->
<!-- date: 2026-11-03 -->
<!-- branch: agent/subagent-continue -->
<!-- user-approved: true — operator decision after the gate cap: single PR,
     proceed now, all four prerequisites non-negotiable. -->
<!-- gate iterations: design gate 3 rounds (5/5 NEEDS_REVISION each), plan gate
     3 rounds (FAIL/FAIL/PASS, FAIL/FAIL/PASS, FAIL/FAIL/FAIL — cap reached).
     Every finding is applied; the rev 5/6 amendments below supersede the
     conflicting text in the body (struck inline where it appears). -->
<!-- non-negotiable prerequisites (must ship in this PR): ownership gate, one
     child-run lifecycle, conversation repair, child-transcript secret
     redaction. -->
<!-- rev 1-3: 5/5 NEEDS_REVISION each round. rev 4 resolves every finding; the
     gate's 3-iteration cap is reached, so rev 4 went to the operator for a
     proceed/revise/simplify decision (see "Gate status"). -->

## Rev 5 amendments (plan-review round 2 + operator decision)

The operator chose **single PR, proceed now**. The four prerequisites
(ownership gate, run lifecycle, conversation repair, secret redaction) are
**non-negotiable** for this PR. Corrections below supersede the text that
follows where they conflict.

1. **`SpawnCallback` keeps the worker's `ThreadId` ownership.** The inverted
   signature drops the `ThreadId` parameter, so `runNewChild` must record
   `aiWorkerThread := Just myThreadId` itself (inside the forked thread, before
   running the body) — otherwise `stopAgent` has nothing to kill for every
   spawned background child, and a `continue` can hand the transcript to a
   second writer.
2. **Registration stays outside the child-side semaphore.** The cap wraps only
   the run body:
   `spawnCallback sid def csid task (\() -> bracketSem sem (runChildTask …))`.
   Wrapping the callback instead would make a queued child invisible to
   `AGENT_INSTANCES`, `AGENT_STOP`, and `hasRunningChildren`.
3. **`shouldDeferDelivery` is preserved** in the new completion callback
   (descendant settle before sidecar + wake). It is orthogonal to `continue`
   and must not be dropped in the rewrite.
4. **Foreground-`start` registration uses resolver capture**, not a
   `runDelegate` signature change: `handleStartForeground`'s resolver already
   receives `task` and returns `(def, worker, childSid)`, so it appends to an
   `IORef` and results are zipped by `crTaskIndex` afterwards. No
   `Delegation.hs` / `ConcurrentSpec` churn.
5. **`repairDanglingToolUse` returns its findings:**
   `[Message] -> ([Text], [Message])` (unrepairable ids, repaired
   conversation). `runTurn` logs the ids; a pure function cannot log.
6. **`handleStatus` uses the owner-scoped lookup.** The real model-facing read
   path is `handleStatus` → `agentInstanceBySubagentId` (global); it switches
   to `agentStatusFor`, and the global lookup stops being exported.
7. **Dropped (scope-review simplifications):** `SubagentId`'s constructor stays
   exported and `subagent_id` is validated as text in the pure gate instead (no
   `RunRecord` decoder churn); strict `mode` applies to **`continue` only**
   (`start` keeps its documented lenient fallback, so no existing test is
   replaced and no shipped behaviour changes).
8. **Legacy shims are re-wired, not deleted** (they exist for transcript
   replay); deletion is a recorded follow-up.
9. Factual corrections: `startAgent` has **9** call sites (8 in `RegistrySpec`,
   1 in `AgentSpec`); `AgentAction` gains a sixth constructor; `loadRunRecord`
   returns `Nothing` on a decode failure (moot once amendment 7 lands).

## Gate status

Round 1: 5/5 NEEDS_REVISION (design flaws: no tail repair, thread-id aliasing,
no ownership). Round 2: 5/5 (run lifecycle: callback on the worker thread,
claim/fork races, delivery semantics). Round 3: 5/5, each reviewer closing with
"these specific fixes and this is approvable", and each finding is a one- or
two-sentence specification change plus a test row — all of them are in rev 4
below. The findings are listed in "Review resolution log" with where each was
addressed, so a reader can audit the loop without the round-3 transcripts.

## Problem

`AGENT_MANAGE` can start, list, status, stop, and interrupt subagents. Once a
child is stopped or interrupted there is no way back to it:

- `stopAgent` **deletes** the registry entry (`Registry.hs:220-236`).
- The child's def and task (`context`/`role`/`isolate_workdir`) are **not
  stored**, and `SubagentRunRecord` holds neither a def id nor a goal.
- `start` always mints a **fresh** `SubagentId` and a **fresh** child
  `SessionId`, so a re-`start` is a different child with no history.
- `handleStartForeground` never registers anything (`Ops/Agent.hs:768-798`), so
  a child spawned with `mode: "foreground"` is invisible to the registry — the
  `subagent_id` it returns in-band is already useless.

Consequence: a child killed by its timeout, by an `interrupt`, or by a crash is
unrecoverable, and a parent cannot talk to a child at all — every interaction is
one-shot (`start` in, completion push out).

*Assumption, stated honestly:* the cost of a re-spawn (messages/tokens/latency)
is unmeasured. The claim is that it is materially larger than one appended user
message; S2 verifies that structurally (the goal is not replayed), not
financially.

Second, a correctness problem this design must absorb: a child killed **mid
turn** leaves a dangling `tool_use`. The assistant message carrying the
`CbToolUse` blocks is fsync'd (`Loop.hs:415`) *before* tools run
(`Loop.hs:486`), so a kill in between leaves `conversation.jsonl` ending with
`assistant(tool_use)` and no `tool_result`. Providers encode verbatim
(`Providers/Anthropic.hs:112-135`), so the next request is rejected (400:
`tool_use` without `tool_result`). Resuming a killed child is the primary use
case, so `continue` must repair the tail.

A torn *line* is not the problem: `readConversation` skips undecodable lines
(`Transcript/Conv.hs:35-37`), and the mid-turn kill path fsyncs whole
newline-terminated lines.

## Scope of availability

`AGENT_MANAGE` exists **only in the top-level (operator-authorized) session
registry**: `buildChildRegistryAdapter`'s `baseOps` wires the legacy,
role-gated `nestedAgentStartOp` and never `agentManageOp` (`TurnEngine.hs:1356-1387`;
`agentManageOp` is wired only at `TurnEngine.hs:307`).

Product consequence, stated plainly: **this does not help nested orchestrator
children** (e.g. metaswarm issue-orchestrators). If the operator's pain lives
there, v1 does not reach it; nested `continue` is deliberate future work and
would follow the repo's "always present, self-gating, dedicated refusal
message" precedent (`TurnEngine.hs:1386`).

The runtime is **process-global** (`Backends.hs:97`, one `bRuntime` per
process), shared by every top-level session — which is why ownership scoping is
a prerequisite (see "Authorization").

## Use cases

`continue` is model-facing; the operator acts *through* the session agent (there
is no operator control surface for it — see "Non-goals").

| # | WHO | WANTS | SO THAT | WHEN |
|---|---|---|---|---|
| U1 | session agent | to resume a child that hit its timeout | work continues from its last persisted message | a background child reports `timeout` |
| U2 | session agent | to resume a child the operator stopped or interrupted | an accidental kill does not throw away context | after a stop/interrupt |
| U3 | session agent | to send a follow-up and get the reply in-band | a multi-turn conversation with a specialist child (review → fix → re-review) | a reply needs refinement |
| U4 | session agent | to resume a **crashed** child | a transient provider failure does not force a re-spawn | `AGENT_STATUS` reports `crashed` |
| U5 | session agent, on the operator's behalf | one child of a `tasks: [...]` batch to be resumable | a 3-of-5 batch failure is repaired without re-running the whole batch | one task in a batch timed out |
| U6 | operator (via the session agent) | a killed child's context to survive an accidental `/stop` | the work is not paid for twice | an operator stop was a mistake |

### The U3 loop, written out (it is what the tests must model)

1. `start` (background) → child runs, replies; a completion message arrives.
2. Parent reads the reply, decides on a refinement, calls
   `continue {subagent_id, prompt: "…"}`.
3. Either foreground (reply in this tool result) or background (reply arrives
   as a separate message headed `[subagent <sid> replied (continue #n)]`).
4. Repeat 2-3. Each run is a separate `aiRuns` increment on **one**
   `subagent_id` and **one** child session.

## Non-goals

- **Mid-run steering.** A message cannot be injected into a *running* child;
  `continue` requires a terminal child (the refusal says so).
- **Operator-facing control surface** (TUI/gateway listing of continuable
  children). U6 is delivered through the session agent's `AGENT_STATUS`
  `resumable:` hint; a human surface is separate work.
- **Persistence across harness restarts.** The registry is in-process.
- **Fresh-session re-runs** (`fresh: true`).
- **Nested-orchestrator `continue`.**
- **Autonomous child loops.** The parent drives each turn.
- **A file-level writer lock** on the child session (see "Accepted risks").
- **Scrubbing existing transcripts.** Secret redaction (below) is prospective.

## Decision

```
AGENT_MANAGE {
  action: "continue",
  subagent_id: <string>,                       -- required
  prompt?: <string>,                           -- optional, non-empty, ≤32 KiB
  mode?: "foreground" | "background"           -- default "background"
}
```

- `prompt` **present** → the child's next user message is `prompt`.
- `prompt` **absent** → `continueNudge`:
  *"[System: the harness is resuming you. Continue your previous task from
  where you left off. Pick up whatever is unfinished; do not start over.]"* —
  framed like the existing injected prompt (`continuationPrompt`, `Loop.hs:86`)
  so the child distinguishes a harness nudge from a parent instruction.
- **Empty-history fallback:** if the child's session directory exists but its
  `conversation.jsonl` is empty (killed before the first request was written),
  the stored `ctGoal` is used instead — otherwise the child is asked to continue
  a task it has no record of.
- **Missing directory:** if the child's session directory is *gone*, `continue`
  **refuses** rather than silently becoming a fresh start wearing a
  `continued #n` label. (`withIndexedTranscript` would happily recreate it.)
- `mode` defaults to `background`, matching `start`.
- **Start-only fields are rejected, not ignored:** `continue` with `id`,
  `goal`, `context`, `role`, or `tasks` present returns
  `continue: "goal" is a start-only field; pass the instruction as "prompt".`
  Silent ignoring would spend a whole child turn on the wrong message.

### Why one action, not two

`restart` and `continue` differ only in which user message is sent; two actions
would duplicate validation, error text, and ~10 test cases.

### Why reuse the child session and the `SubagentId`

Same session → context preserved. Same id → the parent's handle stays valid
across turns, the registry keeps one entry per child, and completion delivery
keeps working.

## The run lifecycle

Every child run — the original spawn and every `continue` — goes through one
lifecycle. It replaces an implicit one with three defects:

1. `registerCompletedAgentResult` overwrites `aiThreadId` with the completing
   thread (`Registry.hs:199-201`), so thread-liveness checks are wrong and
   `AGENT_STOP` could kill the *parent's* thread.
2. The completion callback runs **inside the child worker thread**
   (`Delegation.hs:730-742` → `:791`/`:796`), and `aswOnIdleCompletion` then
   runs the parent's synthetic turn **synchronously on that same thread**
   (`Gateway/Send.hs:376-441`). While the parent reads a reply and decides to
   `continue` again, the child's "worker thread" *is* the parent's thread — a
   liveness-based settle check would refuse the flagship flow.
3. A `killThread`ed worker has not finished when `killThread` returns; its
   bracket cleanup (closing the transcript handle) is still running. A second
   writer in that window corrupts `conversation.jsonl` (DESYNC silently **drops**
   messages, `Transcript.hs:420-467`).

### Shape

`SpawnCallback` is inverted so the registry-backed layer owns the run:

```haskell
type SpawnCallback =
  SubagentId -> AgentDef -> SessionId -> ChildTask -> (IO ChildResult) -> IO ChildResult
```

> **Supersedes the rev-4 `… -> IO ()` sketch.** The callback *returns* the
> result: `runDelegateAsync` still calls the completion callback afterwards,
> so there is one delivery path, not two. `spawnOne` wraps only the run body
> in the cap, and `callback` stays owned by `runDelegateAsync`.


Two callers, one shared body — this is the fix for "`spawnCb` re-registers and
destroys the claim":

| path | function | first step |
|---|---|---|
| spawn | `runNewChild` | `registerRunningAgent` (constructs the instance: task, def, origin, task index, generation 1) then `runAndReport` |
| continue | `runClaimedChild` | `runAndReport` **only** — the instance already exists and `resumeAgent` has claimed it (`aiRuns+1`, `aiGeneration+1`) |

`runAndReport`:

```haskell
runAndReport sid gen runBody = do
  outcome <- try runBody                 -- ThreadKilled is caught here
  endRun sid gen                         -- ownership-guarded: clear aiWorkerThread
  case outcome of
    Right r -> completionCallback r      -- generation-guarded status/result write
    Left  e -> registerRunCrash sid gen e
```

`endRun` clears `aiWorkerThread` **before** any reporting (that is what lets the
parent's wake turn continue immediately), and it is **ownership-guarded, not
generation-guarded**: it clears the field only when `aiWorkerThread == Just
myThreadId`. Generation-guarding it would be a permanent no-op on the stop path
(the stop bump happens before the kill), leaving the field set forever and
making the child un-continuable — the exact bug the guard was meant to prevent.

### Settle semantics

- `aiWorkerThread :: Maybe ThreadId` is the **only** control handle.
- `workerSettled inst` = `aiWorkerThread == Nothing`, with `threadStatus ∈
  {ThreadFinished, ThreadDied}` as a secondary guard. Verified empirically
  (probe, GHC 9.12.4): `ThreadFinished` implies bracket cleanup completed; a
  killed thread reports `ThreadRunning` immediately after `killThread`, so the
  secondary guard is what closes the kill window.
- `continue` performs a **bounded settle wait** (~250 ms, 10 ms fast-exit
  ticks) before refusing, so the ordinary kill→cleanup window is not surfaced
  as a refusal.
- The idle wake is dispatched **off** the worker thread (`void (forkIO …)`).
  A child worker must never run a parent turn.
- `timeout`'s join means `runBody` returning implies the transcript handle is
  closed — so `endRun` after `runBody` is a legal "cleanup done" point.

### Generation guard

`aiGeneration :: Int` is bumped by every successful claim. Status/result writes
(`registerCompletedAgentResult`, `registerRunCrash`, `stopAgent`,
`interruptAgent`) carry the generation they observed and are a **no-op plus a
diagnostic log** if it has moved on — the in-repo pattern from
`RunRecord.GenerationToken` (`RunRecord.hs:165-170`). This stops a late
completion from run *N* clobbering run *N+1*.

Note the deliberate split: **the handle is owned by thread identity; status and
result are owned by generation.** Two fields, two guards.

### Claim / fork / release

```haskell
resumeAgent
  :: AgentRuntime -> SessionId -> SubagentId -> SpawnOrigin
  -> IO ()                                   -- the run body
  -> IO (Either Text (AgentInstance, TMVar (Either SomeException ChildResult)))
```

The returned `TMVar` is the **result sink**: `runAndReport` always fills it
(`tryPutTMVar` in a `finally`), so a foreground caller can never block forever
— including when the run is killed or throws outside the worker's own catch.
(Without a sink, `resumeAgent` returning at fork time gives the foreground path
nothing to wait on.)

Sequence inside `mask $ \restore`:

1. `atomically`: look up; guard owner, terminal status, generation, snapshots,
   run budget; set `aiStatus := Starting`, `aiResult := Nothing`,
   `aiGeneration := gen+1`, `aiOrigin := origin`, `aiRuns := aiRuns + 1`,
   `aiLastActivity := now`. Return the claim.
2. `forkIO` a worker that **inherits the mask** (so it cannot be killed before
   it registers) and whose *body* runs under `restore` (so it is interruptible
   exactly like a normally-spawned child).
3. **In the parent, still inside `mask`**: `atomically` write
   `aiWorkerThread := Just tid`, `aiStatus := Running` — the handle is recorded
   before the body can do anything (this also satisfies the "recorded before the
   worker body runs" test without any gate dance).
4. On any failure between 1 and 3: `killThread tid`, then a generation-guarded
   release to `Stopped` (nothing was claimed), and the sink gets `Left`.

A concurrent `stopAgent` during 1-3 is closed by the generation guard (its
write invalidates the claim; step 3's CAS loses; the thread is killed).

`claimAgent` is **not exported**; `resumeAgent` owns the transaction.

Note: `Starting` becomes a durable, observable state (it counts as live in
`hasRunningChildren`, `Registry.hs:113-116` — desirable during the claim
window). Haddocks implying it is unreachable are corrected.

## Semantics

### Preconditions, in this exact order

| # | Check | Where | Failure message |
|---|---|---|---|
| 1 | instance exists | lookup | `continue: unknown subagent id "<id>". It was not spawned by this session, or was lost to a restart or to retention pruning. Start a new child.` |
| 2 | owner is the calling session | claim | `continue: that subagent belongs to a different session; a session may only continue the children it spawned.` (never echoes the owner id) |
| 3 | spawning not paused | pre-check | `spawnPausedMsg` (shared constant) |
| 4 | status is terminal (`Stopped`/`Interrupted`/`Crashed`) | claim | `continue: subagent <id> is still running. Stop or interrupt it before continuing.` |
| 5 | previous run settled | pre-check + bounded wait | `continue: subagent <id> is still finishing its previous turn. If this persists, stop it.` |
| 6 | child's own children not running | pre-check | `continue: subagent <id> still has running subagents of its own; wait for them or stop them.` |
| 7 | per-parent budget (background only, advisory) | pre-check | `continue: delegation.max_concurrent_children reached (<n>); wait for a child to finish.` |
| 8 | task + def snapshot present | claim | `continue: subagent <id> was registered without a task snapshot and cannot be continued; start a new child.` |
| 9 | run budget (`aiRuns ≤ 50`, both modes) | claim | `continue: subagent <id> has been continued 50 times; start a fresh child for new work.` |
| 10 | no start-only fields | pure gate | `continue: "<field>" is a start-only field; pass the instruction as "prompt".` |

1-3, 5-7, 10 are pure/IO pre-checks; 2, 4, 8, 9 are re-evaluated **inside the
claim transaction**. A refused `continue` does not consume a run from the
budget (the increment happens in the same transaction as the success).

Check 7 is **advisory and non-atomic** (N concurrent continues may overshoot by
N-1) and background-only (a foreground parent is blocked, so the cap is
meaningless). `start` has no cross-call budget check; the asymmetry is
deliberate and documented.

`Idle` is unreachable; `Starting` is transient-but-observable; the terminal
allow-list is exhaustive.

### Foreground mode (the conversational path)

Forks the run exactly like background mode, then blocks the calling thread on
the result sink (`TMVar`) and returns the child's final text in-band. It
suppresses **both** the sidecar append and the idle wake (the reply is already
in the parent's context; a wake with no new message would be a spurious turn).

The wait is bounded by the worker's own `child_timeout_seconds`, and the sink
always fills (`forkFinally` + `tryPutTMVar`). `AGENT_MANAGE` is
`toBlocking = True`, so a foreground continue can block the parent's turn for up
to `child_timeout_seconds` (default 600 s) and `/stop` cannot interrupt it —
identical to `start` with `mode: "foreground"` (see
`docs/superpowers/plans/2026-10-05-design-subagent-completion-notification.md`,
which documents `spawn_mode`). Accepted, bounded, and stated in `toDesc`.

If the *parent's* thread dies while blocked, the child completes and its reply
survives in `aiResult` (`AGENT_STATUS`); the sidecar is untouched.

### Background mode (the default)

Forks the run, returns immediately with a continuation acknowledgement, and
delivers the reply through the existing completion path (sidecar + idle wake,
dispatched off the worker thread) using a continuation-specific message.

### What is reused from the original spawn

`context`, `role`, `isolate_workdir`, `aiTaskIndex`, the child session, and the
**def snapshot** come from the registry. Only the user message changes.

The worker builder is the **continuing turn's** `aswWorker` (no builder is
retained; `resolveTask` always uses the calling wiring, `Ops/Agent.hs:649-656`).
That is safe *because of the ownership gate*: both sides are top-level wirings
(`aswParentDepth = 0`, `buildWorker … 0`, `TurnEngine.hs:1196-1206`), and
`aiParentSession == aswParentSession` gives the same `dwdParentSid`, hence the
same `agentSessionDir parentSid childSid` child directory (`Worker.hs:262`) and
the same session-stable workdir anchor (`dwdParentWorkdir`, `TurnEngine.hs:1279`).
The gate is therefore both authorization *and* the property that keeps the
child's directory and anchor stable. (A stubbed wiring — `tdMkWorker`,
`TurnEngine.hs:1202-1204` — runs the stub, exactly as at spawn.)

Depth follows from the same argument: `childDepth = dwdParentDepth + 1`
(`Worker.hs:263`) flows into the child registry whose own `nestedAgentStartOp`
uses `childDepth + 1` (`TurnEngine.hs:1436-1440`), so `max_spawn_depth` is
unaffected.

`aiDepth`'s haddock says "the parent's delegation depth" while its only
production call site passes `aswParentDepth + 1` (the *child's* depth,
`Ops/Agent.hs:848`). This design fixes the haddock and leaves the value.

`aiTaskIndex` (from `SpawnInfo.siTaskIndex`) is reused so a continued batch
child reports the same `crTaskIndex` in its completion/timeout text
(`mkTimeoutResult` uses it).

## Authority is frozen at spawn

`AgentInstance` stores `aiDef :: AgentDef` — the def the child was built from —
and `continue` uses it **verbatim**. It does not re-resolve.

Why: the def backend is a **union in which the workdir def shadows the user def
on id collision** (`Def/Backend.hs:364-386`). A repo cloned after the child
started (untrusted content) could otherwise shadow the operator's def, and a
resumed child would wake with repo-authored `tools`/`role`/`allow_spawn`/
`system`. Re-resolution is replace, not narrow-only; pinning is narrow-only by
construction. It also removes two failure modes (def deleted mid-flight, def
edited mid-conversation).

Corollary, stated in `toDesc`: narrowing or deleting a def affects **new**
children only.

Config asymmetry worth knowing (operators): the def is pinned, but
`buildChildRegistryAdapter` re-reads `security.toml` on every rebuild
(`TurnEngine.hs:1347`, fail-closed to `failClosedSessionExec` on error) — that
is the right behaviour (enforcement config re-applies; the def grant does not).

## Data-model changes (`src/Seal/Agent/Runtime/Registry.hs`)

`AgentInstance` (constructed with **named fields**; positional construction with
12 fields is a silent-swap hazard the conventions forbid):

| Field | Type | Purpose |
|---|---|---|
| `aiTask` | `Maybe ChildTask` | spawn snapshot: `context`/`role`/`isolate_workdir`, plus `ctGoal` for the empty-history fallback |
| `aiDef` | `Maybe AgentDef` | pinned def |
| `aiTaskIndex` | `Int` | batch index, reused for `crTaskIndex` |
| `aiWorkerThread` | `Maybe ThreadId` | the only control handle; cleared by `endRun` (ownership-guarded) |
| `aiGeneration` | `Int` | bumped per claim; guards status/result writes |
| `aiOrigin` | `SpawnOrigin` (`SoStartForeground \| SoStartBackground \| SoContinueForeground \| SoContinueBackground`) | drives wording (mode is part of the origin, because delivery differs) and is surfaced by `AGENT_STATUS` |
| `aiRuns` | `Int` | run number; the `#n` ordinal and the continue budget |
| `aiLastActivity` | `!UTCTime` | bumped on claim and on terminal write; the `pruneRetained` key |

`SpawnOrigin` is defined **in `Registry.hs`** (it is an instance field and a
`resumeAgent` parameter; placing it in `Ops.Agent` would create a
`Registry → Ops.Agent` back-edge). It is a different axis from the existing
`SpawnMode`/`RunRecord.SpawnMode`.

`aiThreadId` is **deleted**: its only users are the three places this design
rewrites, no test or consumer reads it, and a field whose only documented
property is "never used for control" is the bug.

`startAgent` (the fourth registration path, with 7 test call sites) is
**extended** with task/def/origin/index/generation so it produces a complete
instance; its tests keep working with a real def fixture.

`registerCompletedAgent` (dead code) is replaced by `registerFinishedAgent`
(Stopped, `aiWorkerThread = Nothing`) used by **foreground `start`**. The
orphaned haddock fragment at `Ops/Agent.hs:676-678` is removed.

`Eq` stays derived. `Show` becomes **custom**: it elides `aiTask`, `aiDef`,
**and `aiResult`** bodies (a `crSummary` routinely restates the goal) and keeps
`aiId`/`aiSubagentId`/`aiSession`/`aiParentSession`/`aiOrigin`/status/`aiRuns`
visible for triage. There is **no existing `Show` test** for `AgentInstance`
(none exists today); DoD 7 adds one.

New fields are **strict** (`!`) per convention. Test wirings must therefore
supply a real `AgentDef` fixture instead of `undefined` (the current
`runDelegateAsync` lambdas pass `undefined`); add `mkTestAgentDef` to
`test/Seal/TestHelpers/`.

### Registry API

```haskell
resumeAgent   :: AgentRuntime -> SessionId -> SubagentId -> SpawnOrigin -> IO () -> IO (Either Text (AgentInstance, TMVar (Either SomeException ChildResult)))
stopAgent     :: AgentRuntime -> SessionId -> SubagentId -> IO (Either Text StopOutcome)   -- Ok | StillShuttingDown
interruptAgent:: AgentRuntime -> SessionId -> SubagentId -> IO (Either Text Bool)
agentStatusFor:: AgentRuntime -> SessionId -> SubagentId -> IO (Either Text AgentInstance)
listAgentsFor :: AgentRuntime -> SessionId -> IO [AgentInstance]        -- model-facing
listAgents    :: AgentRuntime -> IO [AgentInstance]                     -- human/Command layer only (Shutdown.hs:74)
ownsChild     :: SessionId -> AgentInstance -> Bool
workerSettled :: AgentInstance -> IO Bool
countRunningChildren / countFinishedChildren :: AgentRuntime -> SessionId -> IO Int
registerRunningAgent  -- + task, def, index, origin
registerFinishedAgent -- post-hoc (foreground start)
registerCompletedAgentResult / registerRunCrash -- generation-guarded
endRun                -- ownership-guarded handle clear
pruneRetained         -- keeps ≤32 terminal entries per parent, oldest aiLastActivity first
```

- `stopAgent` kills `aiWorkerThread` **under a bounded race**: `killThread` is
  `throwTo`, which blocks until the target accepts the exception, so the kill
  itself runs in its own thread and is raced against the settle poll (≤500 ms).
  It then performs one generation-guarded write: `Stopped`,
  `aiWorkerThread := Nothing`, `aiLastActivity := now`, **keeping any `ChildResult`
  already recorded** (so a stop that races a successful completion does not
  discard the answer) and suppressing only the sidecar/wake. On expiry it
  returns `StillShuttingDown` and writes nothing;
  `handleStop` surfaces that instead of discarding the `Either`
  (`Ops/Agent.hs:907` discards it today).
- `registerCompletedAgentResult` sets `Stopped`/`Crashed` + `aiResult`,
  generation-guarded, and never touches `aiWorkerThread` (already cleared).
- `pruneRetained` bounds retained entries per parent (constant 32; configurable
  later), keyed on `aiLastActivity`.
- ~~`SubagentId`'s constructor is **unexported**, replaced by a validating
  `mkSubagentIdFromText`~~ — **superseded by rev-5 amendment 7**: the
  constructor stays exported and `subagent_id` is validated as *text* in the
  pure `continue` gate instead (`Ops/Agent.hs`, `authorizeContinue`), which
  leaves `RunRecord`'s decoder untouched.

## One child-run core (`src/Seal/Agent/Runtime/Delegation.hs`)

```haskell
runChildTask
  :: Maybe ParentActivity -> Double -> UTCTime -> Int
  -> SubagentId -> SessionId -> AgentDef -> AgentWorkerBuilder -> ChildTask
  -> IO ChildResult
```

(heartbeat, timeout secs, **start timestamp**, **task index**, child identity,
def, worker, task). `runDelegateAsync.runWorker` and `runDelegate.runOne` both
become calls to it — extracting only from the async path would take the tree
from two copies of this logic to three. The start timestamp is a parameter
because today `start <- getCurrentTime` precedes def resolution
(`Delegation.hs:702`/`:712`), and dropping it would silently change
`crDurationSeconds`.

The accumulator `IORef`s (`trace`/`read`/`written`) are created and read
internally; production ignores the hooks (`Worker.hs:257`), and test workers
that write them keep working.

**Child-side concurrency cap must be preserved**: today the semaphore wraps the
run as well as the spawn (`Delegation.hs:738-741`). After inversion:

```haskell
Just sem -> bracketSem sem (spawnCallback sid def childSid task (runChildTask …))
```

Omit it and a batch of N runs all N at once — and precondition 7's budget check
becomes a lie.

This extraction is also what keeps the parent-activity heartbeat alive during a
foreground continue (without it the gateway inactivity reaper can kill the
parent mid-continue).

## Conversation repair (`src/Seal/Agent/ConvRepair.hs`, new)

```haskell
repairDanglingToolUse :: [Message] -> ([Text], [Message])
-- (unrepairable tool-call ids, repaired conversation)
```

> **Supersedes the rev-4 `[Message] -> [Message]` signature** (rev-5
> amendment 5): a pure function cannot log, so `runTurn` logs the ids.

Rule: find the **final** assistant message that carries `CbToolUse` ids with no
matching `CbToolResult` after it; append one `Message User` containing a
`CbToolResult` per unmatched id, `isError = True`, text *"interrupted before
this tool returned; it may have partially or fully completed — verify with a
read or a status check before retrying."* (Not "did not run": non-idempotent
`FILE_WRITE`/`BIN_EXEC`/`SHELL_EXEC` may have completed.)

Scoped to the **final** such turn on purpose: results are appended at the end,
so a repair for a mid-history dangling id would land in the wrong place and the
request would still be invalid. A mid-history dangling id is instead logged as
`[conv-repair] mid-history dangling tool_use <id>: not repairable` — a real
corruption signal rather than a silent cosmetic fix. (Reachable shapes are
tail-shaped anyway: `Loop.hs:415` then one results write.)

Applied in `runTurn` immediately after `itwReadConversation` (`Loop.hs:121`),
before the new user message. Because the repair only **appends**, the
indexed-transcript writer's prefix-extension invariant holds
(`Transcript.hs:420-467`; verified: `itsWritten` is re-seeded from disk on
reopen, `Transcript.hs:500-529`), the repair is persisted as ordinary
conversation lines, and a top-level session resumed after a mid-turn kill is
fixed too.

The repaired `User [CbToolResult …]` is followed by another `User` (prompt or
nudge): consecutive user messages are already produced in production by the
sidecar completion injection (`TurnEngine.hs:778-816`), and providers encode
roles verbatim (`Providers/Anthropic.hs:112-119`) — so this is an observed,
accepted shape, asserted by a test rather than assumed. (Merging them into one
message is possible future hardening; not required for validity.)

## Model-facing text (exact strings)

One canonical constant per shared phrase:

```
continueHint = "Send another message with AGENT_MANAGE continue and the same subagent_id to continue the conversation."
noReplyClause = "If you already sent your answer for this request, reply with NO_REPLY."
```

`noReplyClause` is used by **both** the spawn completion and the continue
completion, replacing the two existing variants (`Agent.hs:1180`, `:1252`) — the
old "already sent your final answer" wording is scoped to the whole
conversation, which in a multi-turn exchange is usually true and licenses
discarding a fresh reply. Scoping it to *this request* fixes that.

`toDesc`:

> Manage agent runtime. Use action to select: instances (list the children this
> session spawned that are running now), start (spawn child agents), continue
> (resume a child this session spawned and keep its conversation — only after it
> has finished, been stopped, been interrupted, or crashed; with `prompt` it
> receives that as its next user message, without `prompt` it receives
> "[System: the harness is resuming you. Continue your previous task from where
> you left off…]"; its agent def and tool grant are the ones it was spawned
> with), status (debugging/observability only — NOT for completion checking),
> stop (kill the agent — no completion message arrives — and it stays
> continuable), interrupt (cooperative stop; its reply still arrives). `start`
> and `continue` deliver the reply automatically in background mode — do NOT
> call AGENT_MANAGE status, sleep, or any polling tool. `mode: "foreground"`
> blocks until the reply and returns it in this tool result (it can block for up
> to `delegation.child_timeout_seconds` and cannot be interrupted);
> `mode: "background"` (default) returns immediately and the reply arrives later
> as a separate message. Replies are headed `[subagent <sid> replied
> (continue #n)]`, where `#n` is the child's run number (1 = the original
> spawn). A continued child stays resumable: pass the same `subagent_id` to
> continue again. Ids do not survive a harness restart and finished children may
> be pruned.

Properties:
- `subagent_id`: `"Subagent id, as returned by start/continue and echoed in completion messages (status/stop/interrupt/continue)."`
- `prompt`: `"Next user message for the child (continue). A non-empty string of at most 32 KiB; it is re-sent on every later turn of this child, so keep it short. Omit to send the default continuation nudge. Not the system prompt — that is fixed by the agent def. Start-only fields (id/goal/context/role/tasks) are rejected, not ignored."`
- `mode`: `"Run mode (start/continue). \"foreground\" blocks until the child finishes and returns the reply in this tool result; \"background\" (default) returns immediately and the reply arrives as a separate message. Foreground can block for child_timeout_seconds and cannot be interrupted. Must be one of these two values."`

### Outcome vocabulary (one renderer, all constructors)

`status=` and `exit=` are pinned to a table (today they leak Haskell constructor
names, e.g. `status=CsTimeout exit=CerTimeout`):

| `ChildStatus` | `status=` |
|---|---|
| `CsCompleted` | `completed` |
| `CsFailed` | `failed` |
| `CsTimeout` | `timeout` |
| `CsInterrupted` | `interrupted` |
| `CsError` | `error` |

| `ChildExitReason` | `exit=` |
|---|---|
| `CerCompleted` | `completed` |
| `CerMaxIterations` | `max_iterations` |
| `CerTimeout` | `timeout` |
| `CerInterrupted` | `interrupted` |
| `CerError` | `error` |

Both `AGENT_STATUS` and every continue render use this table (one dialect, not
two). `Crashed m` renders as `crashed: <m>`.

### Delivery texts

Background acknowledgement (continue):
> `<subagent_id> | <child_session> | running (continued #<n>)`
> `The child is working in the background. Its reply will arrive as a separate message headed [subagent <sid> replied (continue #<n>)] — do NOT call AGENT_MANAGE status, sleep, or any polling tool.`

Foreground result header (continue):
> `[subagent <sid> replied (continue #<n>)] status=<…> exit=<…> child_session=<cs>`
> `<summary | crError | "(no final text from the child)">`
> `<continueHint>`

Background completion message (continue):
> `[subagent <sid> replied (continue #<n>)] status=<…> exit=<…> child_session=<cs>`
> `This is the reply you requested. <summary | crError | "(no final text from the child)">`
> `<continueHint>`
> `<noReplyClause>`

The **summary → `crError` → placeholder** fallback matters: every failure path
sets `crSummary = Nothing` and puts the explanation in `crError` alone
(`mkTimeoutResult` = "Subagent timed out after 600s."), so a summary-only
render would silently drop the diagnosis. For `status=timeout`, an extra clause
follows: *"the child was cut off at its time limit; continuing resumes it rather
than restarting it."*

Foreground `start` children (DoD 8, now continuable) also get `continueHint`
appended, since that is the moment the parent holds a resumable handle.

`child_session` is stable across continues and is **not** a correlation key —
only `#n` is. Said once, in the ack.

## Stop and interrupt semantics

Today a `killThread`ed worker is caught by `runChildTask`'s inner catch and
converted to `CerError`, whose completion message
(`status=Failed … child runTurn raised: ThreadKilled`) is appended to the
parent's sidecar and wakes the parent. Under this design a stopped child is
retained and continuable, so a fabricated failure report would tell the model
"that work failed, move on" and then hand it a second reply later.

Rule: **both `stop` and `interrupt` are intentional terminations and suppress
delivery** (no sidecar append, no idle wake). The model learns the outcome from
its own tool result:
- `AGENT_STOP` → `stopped (resumable with AGENT_MANAGE continue)`, or the
  `StillShuttingDown` error text (never a false "stopped").
- `AGENT_INTERRUPT` → `interrupt requested (the child stays continuable)`.

A completion that races an intentional stop keeps its `aiResult` (so the answer
is not lost) but is not delivered.

## Observability

- `AGENT_INSTANCES` is **owner-scoped** (model-facing) and renders only
  `Starting`/`Running`, plus one bounded line:
  `(<n> finished child(ren) from this session, all resumable with AGENT_MANAGE continue)`.
  Without this, retention makes `"(no agents running)"` unreachable and grows
  tool output without bound.
- `AGENT_STATUS` distinguishes `running` / `stopped` (retained, with outcome
  from the vocabulary table, `runs=<n>`, and
  `resumable: AGENT_MANAGE continue with this subagent_id`) / `unknown`
  (`status: "unknown"`).
- Debug log lines carry `subagent_id`, `origin`, `runs`, `prompt_chars`, status
  transitions **and the refusal reason** (`[continue] refused reason=not-settled
  sid=…`). Never the prompt body, never `show inst`.
- Post-ship headline metric (log-derived, no new infrastructure): the fraction
  of continued children that reach a terminal state with a summary instead of
  being re-spawned, continues per session, and refusal count by reason.

## Security

- `AGENT_MANAGE` stays **Trusted**: no shell, no subprocess, no new capability.
- **Authorization covers every model-reachable path.** The runtime is
  process-global, so `instances`/`status`/`stop`/`interrupt`/`continue` all
  require `ownsChild (aswParentSession wiring) inst` — **including the four
  legacy shim opcodes** (`agentInstancesOp`/`agentStatusOp`/`agentStopOp`/
  `agentInterruptOp`, wired at `TurnEngine.hs:302-306` with no session
  identity). `hideOpcodes` only hides them from the catalog —
  `Dispatch.hs:63` still resolves them by name, and `SESSION_MANAGE`'s refusal
  text names `AGENT_STATUS` to the model (`ISA/Ops/Session.hs:445`, `:461`).
  So each shim is re-wired with the parent session and routed through the
  scoped functions; `listAgents` (global) stays for the human `Command` layer
  (`Shutdown.hs:74`). What is *newly* dangerous is the write/kill axis: today a
  session can read a sibling's child summary; after this change it could write a
  user message into that child (`continue`) and kill it (`stop`).
  Refusals never echo the owning session id.
- **No authority widening**: pinned def; task role narrow-only
  (`effectiveRole (adRole def) (ctRole task)`); `isolate_workdir` and the
  session-stable anchor; depth from the continuing turn's wiring.
- **Input validation**: `subagent_id` validated as text (non-empty, ≤256
  characters, no control characters — rev-5 amendment 7; the constructor stays
  exported); `prompt` non-empty, ≤32 KiB,
  no NUL/control characters — it is fsync'd into the child transcript and
  re-sent on every later turn, so it is bounded. Both validated in
  `authorizeAgentManage` (pure gate, mirroring `authorizeStart`'s `shapeGate`).
- **Secret redaction reaches child transcripts — and the `put` half.**
  Children hold `SECRET_MANAGE` (`TurnEngine.hs:1359`) but `itwSetSecretOps` is
  called only on the top-level path (`TurnEngine.hs:743`, `:1110`), and
  `redactMessages` rewrites only `CbToolResult` parts (keyed on the tool name),
  so a `SECRET_MANAGE put` **value in the `CbToolUse` input** is persisted in
  the clear in both parent and child, and `continue` re-transmits it every turn.
  Fixes: (a) `itwSetSecretOps childTHandle (secretOpNames childReg)` in
  `mkDelegateWorker`'s bracket, computed from the pinned def's registry; (b)
  extend `redactMessages` to redact `CbToolUse` **inputs** whose op name is in
  the secret set; (c) state that both are **prospective** — transcripts written
  earlier keep plaintext secrets and `continue` will re-send them, so a scrub
  decision is a follow-up release task, not part of this PR.
- **Fail-closed approvals stay fail-closed**: child caps' `ccPrompt` returns
  `""`, which both the secret gate (`ISA/Ops/Secret.hs:196-198`) and the
  approval parser (`Loop.hs:653-664`) treat as denial. `continue` re-drives
  exactly those children, so a regression test pins it.
- **Transcript single-writer**: guaranteed in-process by the atomic claim, the
  ownership-guarded `endRun` before reporting, the generation guard on status
  writes, the settle gate + bounded wait, the bounded kill race, and foreground
  continue forking rather than running inline.
- `orRecorded` carries `subagent_id`, `child_session`, `mode`, `prompt_present`,
  `prompt_chars`, `runs`, `status` — never the prompt body, never secrets. (The
  dispatcher already persists the raw input in the invocation entry,
  `Dispatch.hs:147-160`, so this costs no debuggability.)
- `prompt` is **bounded but not redacted**: a model induced to paste a secret
  into it writes that secret to the child transcript and the parent's `erMeta`.
  Stated, not mitigated.
- `continue` adds no filesystem path of its own: it reuses the child session
  directory and the completion sidecar paths that spawning already uses, and
  reads (never writes) `security.toml`. No agent-immutable security state
  (`security.toml`, `exec-known-hosts`, `keys/`, `config/vault/`, `ssh-mux/`) is
  read or written by any new path. (Changing the AGENTS.md wording of rule 3 is
  a human-authored decision, not something this design does.)

## Accepted risks

- **Token spend.** Every turn re-sends the child's growing conversation, and
  `aiRuns ≤ 50` is a blunt guard. A long conversation can cost more than the
  re-spawn it replaced. Mitigation today: the budget, `prompt_chars` logging,
  and `runTurn`'s own context limits; a conversation-size guard is future work.
- **Foreground unresponsiveness.** Up to `child_timeout_seconds` (600 s) of a
  blocked parent turn with no operator abort, per foreground continue. Stated in
  `toDesc`; background is the default for this reason.
- **Cross-process double writer.** The registry is in-process, so a second
  process has no entry and cannot name a continuable child — unreachable through
  `continue`. (`withSessionLock` is in-process only, `Session/Lock.hs:51-70`.) A
  `conversation.lock` (O_EXCL) remains the follow-up for the general case.
- **Retained stale authority.** A retained child keeps its pinned def for the
  process lifetime; the spawn-pause flag gates `continue`, so the operator has a
  working kill switch even without per-def revocation.
- **Run records uninvolved.** `createRun`/`completeRun` have no producer in
  `src/`; `continue` does not create one. When spawning starts producing them,
  `continue` must too (fresh generation token — `SubagentRunRecord` is
  terminal-shaped and `completeRun` rejects stale tokens).
- **Pre-existing: a child's idle wake targets `sessionDir childSid`**
  (`TurnEngine.hs:1434`, `:544`/`:1081` → `Paths.hs:160-161`), not
  `agentSessionDir parent child`. A grandchild completion injected by that wake
  lands in a phantom top-level session the child never reads. Not caused by this
  design and not a two-writer (different paths), but `continue` makes child
  sessions long-lived, so it is recorded here.
- **Pre-existing: no cross-process session lock for child dirs** (see above).

## Success criteria (user-focused)

| # | Criterion | How it is checked |
|---|---|---|
| S1 | A resumed child sees its whole prior conversation: turn 2's captured request has turn 1's messages as a **content prefix** | integration test with a request-capturing provider (new shared helper) |
| S2 | Context preserved *and* the goal not replayed | same test: the appended message is the nudge/prompt and the stored goal appears exactly once in turn 2's request |
| S3 | 3-turn **background** conversation under one `subagent_id`, one child session — and a `continue` issued from inside the wake is accepted | scripted integration test (default mode) |
| S4 | 3 consecutive **foreground** continues work | opcode test |
| S5 | A child killed mid-turn resumes cleanly | unit properties + deterministic kill seam |
| S6 | Every refusal names the failed precondition and is visible in logs | per-precondition tests + log assertion |
| S7 | Retention does not bloat the model's context | `AGENT_INSTANCES` live-only + one summary line |
| S8 | (manual, once) A real model holds a 3-turn review→fix→re-review conversation with one child, driven only by `toDesc` | operator-run scripted session, noted in the PR |

Field failure symptom: a resumed child that answers as if it had never seen the
task (repair or session reuse broken), or `[transcript-diag] DESYNC` in
`seal.log`.

## Definition of Done

1. `continue` accepts `subagent_id`, optional `prompt`, optional `mode`; schema,
   `toDesc`, and property descriptions exactly as specified.
2. Preconditions 1-11 (eleven refusal texts) in order with the specified texts; 2/4/8/9 re-checked in
   the claim; a refusal does not consume run budget.
3. `continue` reuses the child session, the pinned def, the stored task, the
   task index, and the continuing turn's `aswWorker`; empty history → `ctGoal`;
   missing directory → refusal.
4. Foreground returns the reply in-band and always fills its sink; **suppresses
   both sidecar and wake**. Background delivers the continuation message.
5. One run lifecycle: `runNewChild`/`runClaimedChild` share `runAndReport`;
   `endRun` is **ownership-guarded** and runs before reporting; the wake is
   forked off the worker thread; `stopAgent` kills under a bounded race, then
   writes `Stopped` + clears the handle generation-guarded, or returns
   `StillShuttingDown`.
6. `resumeAgent` is the only claim entry point, is `mask`ed, registers the
   handle in the parent, runs the body under `restore`, and releases the claim
   on every failure path; two concurrent continues → exactly one winner.
7. `aiGeneration` guards status/result writes; `aiThreadId` deleted;
   `AgentInstance` uses named fields, strict new fields, a custom `Show`
   eliding `aiTask`/`aiDef`/`aiResult`; the `SubagentId` constructor stays
   exported (rev-5 amendment 7).
8. Foreground `start` registers its children; their results carry
   `continueHint`.
9. `repairDanglingToolUse` is applied in `runTurn`, targets the final
   tool_use turn, logs mid-history corruption, and is property-tested.
10. `AGENT_INSTANCES` owner-scoped + live-only + summary line; `AGENT_STATUS`
    outcome vocabulary + resumability hint; `AGENT_STOP`/`AGENT_INTERRUPT`
    surface their outcome and suppress delivery.
11. All six `AGENT_MANAGE` actions (instances/start/continue/status/stop/
    interrupt) **and the four legacy shims** enforce
    ownership; refusals never echo the owning session id; `listAgents` retained
    for the human Command layer.
12. Child transcript secret redaction wired (`CbToolResult` **and**
    `CbToolUse` inputs), with the prospective-only note.
13. Retention pruned on `aiLastActivity`; `aiRuns ≤ 50`; `prompt`/`subagent_id`
    validation; strict `mode` for **`continue` only** (rev-5 amendment 7 —
    `start` keeps its documented lenient fallback, so no shipped behaviour
    changes and no existing test is replaced).
14. Module wiring: `Seal.Agent.ConvRepair` in `exposed-modules`,
    `ConvRepairSpec` in the test suite's `other-modules`, both `test/Main.hs`
    edits; `turnEngine`'s four shim wirings updated with the parent session.
15. **Request-capturing provider promoted** to `test/Seal/TestHelpers/`
    (`captureMessages`) and wired through `ApiTestHarness`, so S1/S2/S3/S5 are
    assertable (today `ScriptProvider.complete` discards the request,
    `TestHelpers/ScriptProvider.hs:27`).
16. The 7 `runDelegateAsync` test lambdas rewritten to invoke the run body
    (`void body`) with a real `mkTestAgentDef` fixture — suite not hanging, no
    `undefined` def forced by strict fields.
17. `make check` green; haddocks corrected (`stopAgent` no longer deletes,
    `aiDepth` = child's depth, `Starting` observable); no `--no-verify`.

## Testing plan (TDD — failing test first)

Legend: R = `RegistrySpec`, A = `AgentSpec`, C = `ConvRepairSpec` (new),
I = `IntegrationSpec`.

| DoD / S | Test | Determinism |
|---|---|---|
| 5 | R: `stopAgent` retains the entry as `Stopped` (replaces the "removes the instance" case) | — |
| 5 | R: `stopAgent` returns only after the killed worker's cleanup ran (`takeMVar gate \`finally\` writeIORef cleaned True`) | MVar |
| 5 | R: **stop a mid-run worker → `Right`, status `Stopped`, `workerSettled` True, and a following `continue` succeeds** (the regression that catches a generation-guarded `endRun`) | MVar |
| 5 | R: bounded-kill expiry (`mask_` busy loop) → `StillShuttingDown`, status unchanged | poll, ≤500 ms |
| 5 | R: `stopAgent` never kills a thread that is not `aiWorkerThread` | — |
| 5 | R: a stop that races a completed run keeps `aiResult` and suppresses delivery | IORef counter |
| 5 | R: `endRun` clears the handle **before** the completion callback observes it (callback reads the instance) | — |
| 5 | I: the idle wake runs off the child worker thread (callback records `myThreadId`; the wake's thread differs) | — |
| 6 | R: claim on `Stopped` → Running; on `Running`/unknown/non-owner → `Left` | — |
| 6 | R: failed claim leaves status/`aiResult`/generation/`aiRuns` untouched | — |
| 6 | R: two concurrent `resumeAgent`s → exactly one `Right` | MVar |
| 6 | R: a run body that throws leaves `Stopped`/`Crashed`, never `Starting`; `hasRunningChildren` False | — |
| 6 | R: the handle is recorded before the body runs | — |
| 7 | R: stale-generation `registerCompletedAgentResult` is a no-op | — |
| 7 | R: `show` omits goal, system prompt, summary; keeps ids/status | — |
| 7/13 | A: `subagent_id` text is rejected when empty / 257 chars / contains a control character | — |
| 8 | A: foreground `start` → `continue` on the returned id runs the worker twice; result carries `continueHint` | IORef |
| 9 | C: one repair per unmatched id; `repair . repair == repair`; input is a prefix of output; complete tails unchanged | QuickCheck |
| 9 | C: partial tail (2 `CbToolUse`, 1 answered) → exactly one repair | QuickCheck |
| 9 | C: mid-history dangling id → unchanged + `not repairable` log | — |
| 9/S5 | I: kill between assistant fsync and tool dispatch → continue → turn-2 request has no dangling `tool_use` | test op signals an `MVar` from inside dispatch then blocks |
| 1 | A: `parseAgentAction` accepts `"continue"` | — |
| 2 | A: all eleven refusal texts, in order (owner refusal does not contain the owner id) | — |
| 2 | A: `goal`/`id`/`context`/`role`/`tasks` with `continue` → start-only-field error | — |
| 13 | A: `prompt: ""`, `prompt: 123`, 40 KiB, control chars → errors; absent ok; `mode: "Foreground"` → error for **both** start and continue | — |
| 3 | A: continue passes the **same child session** (IORef-minted; today's constant `"fresh"` is vacuous) and the pinned def | IORef |
| 3 | A: no `prompt` → `continueNudge`; empty history → `ctGoal`; missing dir → refusal | — |
| 3 | A: def edited after spawn does not change the continued child's tools/role | — |
| 3 | A: a continued batch child keeps its `aiTaskIndex` in the result | — |
| 4 | A: foreground continue returns the summary in-band, `Stopped`, `aiResult` set, **no** sidecar entry, **no** wake | IORef |
| 4 | A: foreground continue on a killed run still returns (sink always fills) | MVar |
| 4 | A: outcome vocabulary — every `ChildStatus`/`ChildExitReason` renders the pinned token; summary→`crError`→placeholder fallback | — |
| 4 | A: background ack `running (continued #n)`; completion has `(continue #`, `continueHint`, `noReplyClause` | poll, fast exit |
| 5 | A: the **second** run of a continued child has `aiRuns == 2` and acks `continued #2` (catches `spawnCb` clobbering the claim) | — |
| 10 | A: `AGENT_INSTANCES` live-only + summary line; another session's child not listed | — |
| 10 | A: `AGENT_STATUS` unknown → `status: "unknown"`; stopped → outcome + `resumable:` | — |
| 10 | A: `AGENT_STOP`/`AGENT_INTERRUPT` suppress delivery and say the child stays continuable | — |
| 11 | A: the four legacy shims refuse another session's child | — |
| 12 | A: child transcript redacts a secret `get` result **and** a secret `put` value | — |
| 12 | A: child approvals stay fail-closed (`ccPrompt` `""` → denied) | — |
| 13 | R: `pruneRetained` keeps 32 per parent, oldest `aiLastActivity` first | — |
| 13 | A: `continue` refuses at `aiRuns = 50`; a refused continue does not consume budget | — |
| 15/S1,S2 | I: 3-run background conversation with the capturing provider — turn-2 request has turn-1 messages as a content prefix; the stored goal appears exactly once | scripted provider |
| 15/S3 | I: `continue` issued from inside the wake callback is accepted | MVar |
| 14 | build: cabal + `test/Main.hs` wiring compiles, spec runs | — |
| 16 | A: the 7 rewritten `runDelegateAsync` tests complete under a bounded poll (no `takeMVar` hang) | poll |

Runtime budget: no new test exceeds ~150 ms except the bounded-wait/kill cases
(cap 500 ms each) and the two scripted-conversation tests. All waits are
`MVar`-driven or bounded fast-exit polls (never a bare `threadDelay`); record
`make test` wall time before/after in the PR.

## Small extractions

1. `spawnPausedMsg` shared by `runDelegate`, `runDelegateAsync`, `continue`
   (duplicated verbatim today, `Delegation.hs:498`/`:659`).
2. `pollUntil` helper (pattern exists as `pollUntilCrashed`,
   `RegistrySpec.hs:63-71`), 10 ms ticks, caller bound.
3. `writeChildMeta` preserves the original `smCreatedAt` on a resumed child
   (resets to `now` today, `Worker.hs:372`); DoD item + test.
4. `mkTestAgentDef` fixture in `TestHelpers` (strict fields force a real def).

## Rollout / compatibility

Additive for the model-facing surface; internal seams change: `SpawnCallback`
inverted (1 production site, 7 test lambdas), `stopAgent`/`interruptAgent`/
`agentStatus`-family gain a `SessionId`, the four legacy shims re-wired,
`registerRunningAgent` extended, `AgentInstance` re-shaped (named fields, +6
fields, −`aiThreadId`), `stopAgent`/`interruptAgent` retain entries and suppress
delivery, `AGENT_STATUS` gains the outcome vocabulary + `unknown` token,
`AGENT_INSTANCES` becomes owner-scoped and live-only, `mode` validation is
strict for `continue` only (rev-5 amendment 7 — `start` is unchanged).
`README.md:144` names the opcode but not its actions, so it needs no change; the
opcode description carries the behaviour.

## Review resolution log

| Round-3 finding | Resolution |
|---|---|
| `endRun` generation-guard contradicts the stop path | `endRun` is **ownership**-guarded (thread identity); status writes stay generation-guarded. Regressions: "stop mid-run → settled → continue succeeds" |
| `spawnCb` re-registers and destroys the claim | split into `runNewChild` (registers) and `runClaimedChild` (claimed already); test "second run keeps `aiRuns == 2`" |
| Legacy shims bypass ownership | all four re-wired with the parent session; `listAgents` kept for the human layer; test row |
| `killThread` can block forever | kill runs in its own thread, raced against the settle poll; `mask_` busy-loop test |
| Fork inside `mask` cannot be killed / handle not recorded before body | handle recorded in the **parent** inside `mask`; body runs under `restore` |
| Child-side `bracketSem` silently dropped | explicit `bracketSem sem (spawnCallback …)` in the inverted shape |
| `SpawnOrigin` has no mode; `resumeAgent` has no result sink | 4 constructors; `resumeAgent` returns the sink `TMVar` |
| Success criteria not in DoD/tests; no request-capturing provider | DoD 15 + S1/S2/S3/S5 rows; provider promoted to `TestHelpers` |
| No test for continue-from-wake / wake off the worker thread | two I/A rows |
| Model-facing gaps (crashed legality, outcome vocabulary, `crError` fallback, stop-suppresses-delivery, `#n`, `NO_REPLY` scoping, start-only fields, pruned-id message) | `toDesc` rewritten; vocabulary table; `crError` fallback; `stop`/`interrupt` text; `#n` defined; `noReplyClause` unified and request-scoped; start-only fields rejected; unknown-id text mentions pruning |
| `pruneRetained` has no ordering key | `aiLastActivity` added |
| Redaction misses `CbToolUse put` values; prospective-only | both fixes + prospective note + scrub follow-up |
| Repair rule could emit an unusable repair | scoped to the final tool_use turn; mid-history logged as corruption |
| `runChildTask` duration/index; third copy of the logic | start timestamp + task index parameters; `runDelegate.runOne` deduped too |
| `startAgent` is a fourth registration path | explicitly extended, 7 test call sites updated, real def fixture |
| 7 test lambdas would hang; `undefined` def forced by strict fields | DoD 16 + `mkTestAgentDef` |
| "existing `Show` test" | there is none; DoD 7 adds one |
| `poll ≤100 ms` vs. documented flake lesson | bounded fast-exit polls, no bare sleeps |
| Strict `mode` for `start` | adopted for both, one test replaced, enumerated error |
| Interrupt delivery model | unified with stop: both intentional, both suppressed |
| Foreground suppresses wake? | yes, stated |
| Empty-history fallback masks a lost transcript | missing directory → refusal |
| Stop racing a completed run loses the result | `aiResult` kept, delivery suppressed |
| `SubagentId` raw construction | constructor unexported, validating smart constructor |
| `prompt` bounded but not redacted | stated explicitly |
| `~/.seal/` wording | no reinterpretation; only "adds no filesystem path" |
| Citation drift | corrected throughout |
