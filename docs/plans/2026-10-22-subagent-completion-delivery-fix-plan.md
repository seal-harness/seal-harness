# Sub-agent completion delivery — implementation plan

<!-- status: draft — plan-review gate iteration 2 -->
<!-- gate iteration 1: Completeness FAIL, Scope&Alignment FAIL, Feasibility FAIL.
     All three blocking issues addressed: D1 is now the call-site change
     (iteration-1 D1's writer-side mode is withdrawn); the §2 measurement is
     corrected against a re-run probe; the process-death and deferred-delivery
     cases are scoped out with tracking items; the wake chain, the abort path
     and the provider-resolution early return are specified. -->
<!-- date: 2026-10-22 -->
<!-- diagnosis: docs/plans/2026-10-22-subagent-completion-delivery-diagnosis.md -->
<!-- branch: fix/subagent-completion-delivery-diagnostics (PR #279, draft) -->
<!-- gate: iteration 1 — Completeness FAIL, Scope & Alignment FAIL; both blocking
     issues are addressed in §3 D1 (the call-site change) and §4 WU-1/WU-3 -->

## 1. Problem

A background sub-agent's completion is never delivered to the parent
session's model. The parent is told the sub-agent is still running, or it
dies waiting.

The delivery path:

```
child finishes → Agent.hs callback
  → appendCompletionToSidecar            (sidecar file in the session dir)
  → onIdleCompletion hook → wakeIdleSession
      → (a turn is in flight → SKIP; the completion waits in the sidecar)
      → else → synthetic turn → TurnEngine.runTurnBody
          → readAndClearCompletions      (drain the sidecar)
          → itwRecordAsync                (inject into conversation.jsonl)
          → runTurn
              → prior <- itwReadConversation   (reads the FILE, not the writer)
```

Two independent defects, both confirmed on a live gateway
(diagnosis doc §9):

- **D1 — the race.** The injection is enqueued fire-and-forget and the
  conversation the model is given is read straight off disk, so the read
  routinely beats the writer. The model is handed a conversation that does
  not contain the completions, while they land in the transcript moments
  later. Measured: `missingFromReader == injected` for 21 of 21
  completions across two live sessions.
- **D2 — the stranding.** A completion that arrives while a turn is in
  flight has no delivery scheduled: the wake-up is skipped and nothing
  re-checks when the turn ends. Measured: 19 skipped wake-ups, 6
  completions never delivered, session dead.

D1 additionally corrupts the transcript: the writer's positional diff is
sliced against the wrong offset, so the model's own messages are dropped
from `conversation.jsonl` and the file permanently disagrees with the
model's context.

## 2. What we measured (this is why WU-1's tests are deterministic)

The writer daemon is forked when the transcript handle is opened, and the
handle is opened **per turn** (`withIndexedTranscript` in
`runSessionTurn`, `src/Seal/Core/TurnEngine.hs:578`). The completion
injection is therefore *always* the first write on a fresh handle — the
daemon has only just been forked and has not reached its queue read when
the model's context is built.

A throwaway probe measured how often the reader loses the race. The rate
depends on the size of the conversation, because the daemon's work
(redact the whole list, write, fsync) and the reader's work (read the
file, parse the JSON) both scale with it:

| shape | reader missed the handoff |
|---|---|
| cold daemon, prior = 1 small message | 3 / 30 (10%) |
| cold daemon, prior = 50 messages x 5KB (250KB) | 25 / 30 (83%) |
| cold daemon, prior = 300 messages x 5KB (1.5MB) | **30 / 30 (100%)** |
| busy daemon, a bulk write queued ahead of the handoff | **50 / 50 (100%)** |

The live evidence agrees with the top of the table's tail: the incident
sessions ran 269- and 505-message conversations, and **21 of 21**
completions were missed (`missingFromReader == injected`).

Two consequences for WU-1:

1. **A production-sized conversation makes the reproduction
   deterministic.** The gateway-level test therefore seeds a realistic
   conversation (>= 1.5MB, i.e. the size a real session reaches), which
   is where the miss rate reaches 100%.
2. **A busy writer also makes it deterministic, and cheaply.** A bulk
   write queued ahead of the handoff keeps the daemon working while the
   reader runs (the last row). The handoff must be *positioned* so the
   writer will write it once it gets there — the list handed over is the
   writer's state followed by the handoff — otherwise the writer's
   positional diff slices the handoff away and the test would pass for
   the wrong reason.

=> The bug is not a rare interleaving. It is the normal path for any
session with a real conversation, and it is reproducible in a test with
no timing luck involved.

## 3. Design decisions

### D1 — the handoff must be durable before the model's context is built

The writer exposes two primitives: `itwRecordAndAck` (blocks until the
write is fsync'd) and `itwRecordAsync` (fire-and-forget). The completion
injection uses the fire-and-forget one, and the read that builds the
model's context is a direct file read that does not go through the
writer's queue.

**Decision: record the handoff durably, at the call site.**
`TurnEngine.runTurnBody` records the completion injection with
`itwRecordAndAck` instead of `itwRecordAsync`.

This is the codebase's own convention for "this write must be on disk
before the next step": see the ACK-before-execute invariant in
`src/Seal/ISA/Dispatch.hs:3-7` and its uses (`Dispatch.hs:75`,
`Agent/Loop.hs:228`, `Command/Model.hs:100`, `Command/Stop.hs:92`). The
handoff is the same kind of invariant — the model must be able to see it.

*Why the call site and not a mode inside the writer:* `itwRecordAsync`
is a shared API with four other callers (`src/Seal/ISA/Dispatch.hs:99`
and `:105` — the Trusted/Audited invocation entries; `src/Seal/Agent/
Loop.hs:168` — the turn's request entry; and the test in
`test/Seal/Handles/TranscriptSpec.hs:386,389`). A tag-keyed second
behaviour inside it would affect a shared contract for the sake of one
call site, and would leave a permanent misnomer on the method. The
call-site change touches exactly one line and leaves every other
caller's behaviour — and the PR #279 test that pins it — untouched.

*What the change buys:*

- **Visibility.** The ack returns only after the handoff is fsync'd, so
  the file contains the completions before `Agent/Loop.hs:118` reads it.
  The read that builds the model's context therefore cannot miss them.
- **Transcript alignment.** The writer's recorded conversation
  (`itsWritten`) is then the same list the caller's is built from, so the
  caller's next write is a prefix-extension and the positional diff never
  slices the wrong range. The model's own messages are no longer dropped.

*Durability semantics (verified, not just argued).* A probe of the exact
production sequence — a prior conversation, a durable handoff, the
model-context read, then the model's reply written the way
`Seal.Agent.Loop` writes it — gives: the model's context **contains** the
handoff, and the file ends up as `prior + handoff + reply`, in order,
with nothing lost. Both the visibility fault and the transcript
corruption are repaired by the same one-line change.

*Rejected alternative (from the diagnosis doc §6, option C):* pass the
completions into `runTurn` and prepend them to the in-memory
conversation, so the loop writes them as part of its normal request
entry. It avoids the extra fsync and has no second source of truth, but
it needs the completions plumbed into the agent loop (a new `AgentEnv`
field or a `runTurn` parameter) and the harness entry re-ordered so it
does not write the completions behind the caller's back. Deferred: the
fsync happens once per completion batch, and the simpler change is one
line. Revisit if the fsync shows up in a latency budget.

*Error handling:* `itwRecordAndAck` raises `TranscriptError` if the
writer daemon is dead or stuck. A handoff that cannot be recorded must
not kill the turn: the error is caught, logged at Error level, and the
turn continues without the injection (the completion is lost, but the
session survives and the failure is visible).

*Interaction with the PR #279 instrumentation:* unchanged. The I1
detector (`COMPLETION NOT VISIBLE TO READER`) still fires if a handoff is
ever enqueued without becoming durable, and the existing test
`test/Seal/Handles/TranscriptSpec.hs:368` ("counts a read that misses a
completion injection the writer was asked to record") keeps passing
because it exercises the async path, which this change does not touch.
The I2 detector (`DESYNC`) likewise keeps firing if the caller's
conversation ever diverges from the writer's.

### D2 — a completion that arrives during a turn is delivered when the turn ends

When `wakeIdleSession` skips the wake-up because a turn is in flight,
nothing is scheduled to pick the completion up.

**Decision: the turn engine announces the end of every turn, and the
gateway checks for pending completions then.**

- `TurnDeps` gains `tdOnTurnEnd :: Maybe (SessionId -> IO ())`. The four
  construction sites are `src/Seal/Gateway/Send.hs:254` (the gateway
  wires it) and `src/Seal/Channel/Cli.hs:216,272,303` (they pass
  `Nothing`).
- The gateway's wiring is gated on the existing `sdEnableIdleWake` kill
  switch (`src/Seal/Gateway/Send.hs:229-232`), which already gates the
  completion wake-up hook. Setting it to `False` disables both — see §6.
- `TurnEngine.runSessionTurn` calls it **after** the turn's bracket, so
  the session lock is released and the idle broadcast has already fired.
  A wake started from it is therefore not blocked by the turn that is
  ending, and the frontend sees idle → thinking rather than thinking →
  idle.
- `Gateway/Send.hs` implements it: if `pendingCompletionCount` is
  non-zero, call `wakeIdleSession`.

**The wake chain (new behaviour).** Today the outer `wakeIdleSession`
only logs a warning after its turn finishes
(`src/Seal/Gateway/Send.hs:361-367`); it does not re-check. When the
ending turn is itself a wake-up turn, the per-session wake mutex is still
held (`releaseWake` happens at `src/Seal/Gateway/Send.hs:368`, after
`runSessionTurn` returns), so a nested `wakeIdleSession` would correctly
skip. The outer frame therefore re-checks after its turn finishes:

```haskell
wakeIdleSession deps sid = loop
  where
    loop = do
      inFlight <- sessionTurnInFlight (sdLocks deps) sid
      unless inFlight $ do
        acquired <- tryAcquireWake (sdWakeMutex deps) sid
        when acquired $ do
          mMeta <- loadSessionMeta (sdPaths deps) sid
          case mMeta of
            Nothing -> releaseWake (sdWakeMutex deps) sid
            Just meta -> do
              _ <- runSessionTurn td adapter meta Nothing "."
              releaseWake (sdWakeMutex deps) sid
              -- A completion may have arrived during the turn; the
              -- nested wake could not start (the mutex was held), so
              -- this frame picks it up.
              pending <- pendingCompletionCount (sdPaths deps) sid
              when (pending > 0 && wakeTurns < maxWakeTurns) $ loop
```

The chain terminates because the sidecar is empty when no sub-agent is
outstanding, and because it is **bounded**: it stops after
`maxWakeTurns` consecutive wake turns and logs at Warning level if it
stops with completions still pending. The bound is what makes the
provider-failure case below safe even if the hook were to fire there.

**Which turn exits fire the hook:**

| exit | hook fires? | why |
|---|---|---|
| normal completion | yes | a completion may have arrived during the turn |
| the turn threw | yes | same — and the failure must not strand completions |
| the provider failed to resolve | **no** | `runSessionTurn` returns *before* the bracket (`TurnEngine.hs:520-527`) and never reaches `readAndClearCompletions` (`TurnEngine.hs:736`), so the sidecar is never drained. Firing the hook here would make the chain re-enter `runSessionTurn` for a sidecar that can never be emptied — an infinite loop. The completions stay pending until the provider works again |
| the user aborted (`/stop`) | no | an explicit "not now" — the completions stay pending until the next user message |

**Closed tabs.** A wake for a session whose tab was closed runs the turn
headless, exactly as today's completion wake-up does — `runSessionTurn`
re-inserts a tab via `ensureTabForSession` (`TurnEngine.hs:582-583`).
That is pre-existing behaviour of the wake path, not something this plan
introduces; WU-3 adds a test that the turn still runs and the completion
is still delivered, so the tab side effect cannot silently change it.

### D3 — the wake mutex must not leak

`wakeIdleSession` releases the per-session wake mutex *after*
`runSessionTurn`. An exception in the turn skips the release, and the
mutex stays held for the lifetime of the process: every later completion
logs "skipping (wake mutex held)" and the session can never be woken
again.

**Decision:** release the mutex in a `finally`/`bracket` around the
synthetic turn.

## 4. Work units

### WU-1 — Reproduce the bug with a failing test (FIRST)

*No production change.* The point is to make the failure executable and
deterministic before anything is fixed.

**Files (test only):**
- `test/Seal/Gateway/SendSpec.hs` — R1, R2, R3
- `test/Seal/Handles/TranscriptSpec.hs` — R4

**Test infrastructure needed (test only).** `SendSpec` already defines a
local `ScriptProvider`; it pops canned responses but *discards* the
`CompletionRequest`, so a test cannot assert what the model was given.
It also already defines a `CapturingProvider`
(`test/Seal/Gateway/SendSpec.hs:108-114`) — but that one captures a
`Maybe Text`, not the request, so it cannot answer "what conversation was
the model given?". Add a **new**, distinctly named provider to
`SendSpec`: `RequestRecordingProvider`, holding an
`IORef [CompletionRequest]`, returning a scripted response. That is the
whole of the new test infrastructure — no new module, so no `.cabal` /
`test/Main.hs` edits.

**R1 — the parent model is given the sub-agent's verdict.** *(the
user-visible symptom)* Seed the session with a realistic conversation
(>= 1.5MB — the size a real session reaches, which is what makes the
miss rate 100%, §2) and a sidecar holding one completed sub-agent's
message (`appendCompletionToSidecar`). Run one turn through
`handleSend` and assert the `CompletionRequest` the provider received
contains the verdict.

Today: the turn engine's injection is the first write on the turn's fresh
transcript handle, so the read that builds the model's context beats the
writer. The request does not contain the verdict -> **fails**.

**R2 — the transcript keeps both the verdict and the parent's own
message.** After R1's turn, read `conversation.jsonl` and assert it
contains the verdict *and* the parent's reply, in that order, with
nothing lost.

Today: the writer is ahead of the caller's list by the number of
injected messages, so the parent's own reply is dropped from the file
(the verdict is appended at the position the reply would have taken) ->
**fails**.

**R3 — a verdict that arrives while the parent is mid-turn is delivered
when the turn ends.** Run a turn whose provider blocks (so a turn is in
flight), deliver a verdict to the sidecar while it runs, let the turn
end, and assert the verdict is delivered — the sidecar is drained and a
subsequent provider request contains it.

Today: the wake-up is skipped ("turn in flight") and nothing re-checks
when the turn ends -> the verdict stays in the sidecar -> **fails**.

Two harness details: the existing `BlockingProvider`
(`test/Seal/Gateway/SendSpec.hs:96-101`) blocks on *every* call, so the
post-fix wake-up turn would hang — the test needs a provider that blocks
only the first call. And `mkSendDepsWith` leaves `sdTabsHandle` as
`error ...` (`SendSpec.hs:216`), so the test must set it by record
update, as the existing tests do.

**R4 — the property the fix relies on (passes today; pins the
mechanism).** At the transcript handle, with the writer kept busy by a
bulk write queued ahead of the handoff:

```haskell
withIndexedTranscript dir $ \h -> do
  -- a bulk write, queued first: the daemon is busy with it
  itwRecordAsync h (IndexedTranscriptWrite bulk bulkEntry)
  -- the handoff, positioned so the writer WILL write it once it gets
  -- there (the list is the writer's state followed by the handoff)
  itwRecordAndAck h (IndexedTranscriptWrite (bulk <> handoff) handoffEntry)
  modelContext <- itwReadConversation h
  handoff `shouldSatisfy` (`elem` modelContext)
```

This is the invariant WU-2 makes the production path rely on: a handoff
that has been recorded durably is visible to the next reader, even when
the writer had a backlog. It passes today; WU-1 adds it so that a
future change to the writer cannot break the fix's premise unnoticed.
The handoff must be *positioned* as above — if the list handed over does
not continue the writer's state, the writer's positional diff slices the
handoff away and the test would pass for the wrong reason.

**DoD:**
- [ ] R1, R2, R3 exist and **fail** on the current code.
- [ ] The failures are **deterministic**: each fails on 20 consecutive
      runs. WU-1 records the measured miss rate for the shape it used.
      (If R1's miss rate is below 100% on the machine it runs on, WU-1
      increases the seeded conversation size until the false-pass
      probability is negligible, and records the size it settled on.)
- [ ] R4 passes.
- [ ] Each failure message names the defect and points at the diagnosis
      doc.
- [ ] No production file is touched by this work unit.
- [ ] `make test` reports exactly R1, R2, R3 as failing (and nothing
      else newly failing).

**Verification:** `make test` — three named failures with the expected
messages.

### WU-2 — Record the completion handoff durably

**Files:**
- `src/Seal/Core/TurnEngine.hs` (the injection call)
- `test/Seal/Gateway/SendSpec.hs` (R1, R2 go green)
- `test/Seal/Handles/TranscriptSpec.hs` (R4 stays green; a new case for
  the dead-daemon path)

**Work:**
- `TurnEngine.runTurnBody` records the completion injection with
  `itwRecordAndAck` instead of `itwRecordAsync` (D1).
- The `TranscriptError` from a dead or stuck writer daemon is caught and
  logged at Error level; the turn continues without the injection.
- The doc comment on the injection site states the invariant: the handoff
  must be durable before the model's context is read.

**DoD:**
- [ ] R1, R2 and R4 pass.
- [ ] R1/R2 pass on 20 consecutive runs (no flakiness introduced).
- [ ] The suite is green except R3, which is fixed in WU-3 (it asserts the
      stranding behaviour that WU-3 changes); `hlint src/ test/` reports
      "No hints".
- [ ] The PR #279 instrumentation test
      (`test/Seal/Handles/TranscriptSpec.hs:368`) still passes unchanged.
- [ ] The dead-daemon path is covered by a test that can actually observe
      it: at the transcript level, `itwRecordAndAck` on a dead daemon
      raises `TranscriptError` promptly rather than hanging (replacing the
      existing no-op assertion at `test/Seal/Handles/TranscriptSpec.hs:229-250`).
      The turn engine catches that error and logs it; because the turn
      creates its own transcript handle there is no injection seam to
      drive from a test, so the turn-level consequence is verified by
      inspection in WU-5's review, not by a test. The plan does not claim
      a gateway-level test for it.
- [ ] The other `itwRecordAsync` callers are unchanged
      (`src/Seal/ISA/Dispatch.hs:99,105`, `src/Seal/Agent/Loop.hs:168`).

**Verification:** `make check`.

### WU-3 — Deliver completions that arrive during a turn

**Files:**
- `src/Seal/Core/TurnEngine.hs` (`TurnDeps`, `runSessionTurn`)
- `src/Seal/Gateway/Send.hs` (the end-of-turn hook, the wake chain)
- `src/Seal/Channel/Cli.hs` (`tdOnTurnEnd = Nothing` at the three sites)
- `test/Seal/Gateway/SendSpec.hs` (R3 goes green; the chain tests)

**Work:**
- Add `tdOnTurnEnd :: Maybe (SessionId -> IO ())` to `TurnDeps`; wire it
  in the gateway, `Nothing` in the CLI.
- `runSessionTurn` calls the hook after the turn's bracket — and also
  after the provider-resolution early return, so a provider that fails to
  resolve does not strand completions. The hook does not fire when the
  turn was aborted by the user.
- `wakeIdleSession` becomes the loop in §3 D2, so a completion that
  arrives during a wake-up turn is delivered by a follow-up wake-up turn.

**DoD:**
- [ ] R3 passes.
- [ ] A completion that arrives during a wake-up turn is delivered by a
      follow-up wake-up turn (new test).
- [ ] The chain terminates: with an empty sidecar, no further turn
      starts (asserted by a turn counter in the test).
- [ ] The chain is bounded: a provider that cannot be resolved does not
      produce an unbounded sequence of wake turns (asserted by a turn
      counter), and the completions stay pending.
- [ ] A wake for a session whose tab was closed still delivers the
      completion (the turn runs headless).
- [ ] The end-of-turn hook fires after the session lock is released (a
      test asserts the wake is not skipped as "turn in flight").
- [ ] The hook fires on a turn that threw, and on a provider that failed
      to resolve (new tests).
- [ ] The hook does not fire when the turn was aborted by the user (new
      test).
- [ ] `make check` green.

**Verification:** `make check`.

### WU-4 — Wake-path hygiene

**Files:**
- `src/Seal/Gateway/Send.hs`
- `test/Seal/Gateway/SendSpec.hs`

**Work:**
- Release the wake mutex even when the synthetic turn throws (D3).
- Log a skipped wake-up at Warning level (not Debug) with the number of
  pending completions, so "the completion is stranded" is visible when it
  happens rather than only in hindsight.
- Report the pending count at the moment of the skip — the check that
  currently only runs at turn end (and therefore never fires when the
  process dies mid-turn) also runs at the skip.

**DoD:**
- [ ] A test: a synthetic turn that throws still releases the wake
      mutex — a later completion can wake the session.
- [ ] A test: a skipped wake-up is logged at Warning level.
- [ ] `make check` green.

**Verification:** `make check`.

### WU-5 — Final review, tracking items, knowledge capture, PR

- [ ] The out-of-scope defects in §5 are filed as tracking items (the
      repo's `TODO.md` / issue tracker), not just named here.
- [ ] The full diff is reviewed against the diagnosis doc §9 (the live
      evidence): every number quoted there is re-checked against the
      fixed behaviour.
- [ ] `self-reflect` is run and the learnings committed to the knowledge
      base.
- [ ] The PR describes both defects, the live evidence, and the fix.
- [ ] `make check` green on the final commit; the PR is marked ready.

## 5. Out of scope

Each of these is a real defect found while diagnosing, and each is filed
as a tracking item in WU-5.

- **The gateway restarting mid-turn.** The incident session died this
  way: the gateway restarted at 18:04:12 while a turn was in flight, and
  the six pending completions were never delivered (diagnosis §9.5). D2's
  end-of-turn hook cannot fire for a turn lost with the process, so
  those completions wait for the next human message. Delivering them
  automatically needs a startup sweep over every session's sidecar — a
  different mechanism from the one this plan changes, and it is a
  gateway-lifecycle feature rather than a completion-delivery fix.
- **`agent def not found`.** Five of the eighteen completions in the
  live session were `status=CsError error: agent def not found: dr3-pm`
  (and `dr3-architect`, `dr3-designer`, `dr3-security`, `dr3-cto`). The
  parent spawned agent defs that do not exist.
- **The deferred-delivery path.** `src/Seal/ISA/Ops/Agent.hs:817` skips
  the sidecar append entirely when a child has pending descendants
  (`shouldDeferDelivery`); the settle flag is recorded
  (`src/Seal/Agent/Runtime/RunRecord.hs:240,266,289`) but nothing acts
  on it, so such a completion is never delivered at all.
- **The torn-read hazard.** `readConversation` is `mapMaybe decode`, so a
  partially written trailing line is silently dropped from a reader's
  snapshot. Not reachable once handoffs are durable (the write is
  fsync'd before the read), but it is a latent hazard.
- **The `/model` and `/stop` notices never reaching
  `conversation.jsonl`.** `Command/Model.hs` and `Command/Stop.hs` append
  a one-message list to a session whose conversation they never read, so
  the writer's positional diff drops it. A pre-existing bug, unrelated to
  completion delivery, but it was found by the new alignment detector.

## 6. Rollback and compatibility

- **On-disk format: unchanged.** `conversation.jsonl`, `entries.jsonl` and
  the sidecar encoding are untouched by this plan. The only new artefact
  is the `tdOnTurnEnd` field on an internal record.
- **Rollback:** the change is three behaviour switches in three files, each
  independently revertable. Reverting WU-2 restores the race; reverting
  WU-3 restores the stranding; reverting WU-4 restores the mutex leak.
  No data migration is involved, so a revert is a plain `git revert`.
- **Already-corrupted sessions:** sessions whose transcript already
  diverged (the live incident session) keep their corrupted
  `conversation.jsonl`. The I2 detector will keep reporting the
  divergence for them. The fix prevents new corruption; it does not
  repair old transcripts.
- **Kill switch:** the existing `sdEnableIdleWake`
  (`src/Seal/Gateway/Send.hs:229-232`), which already gates the
  completion wake-up hook. The new end-of-turn trigger is wired behind
  the same switch, so setting it to `False` disables both the
  completion wake-up and the end-of-turn trigger (as the scripted-provider
  tests do: `test/Seal/TestHelpers/ApiTestHarness.hs:513`,
  `test/Seal/Gateway/ApiSpec.hs:4443`). If the handoff's fsync shows up in a latency
  budget, the fix reverts to option C (diagnosis §6) without a flag.

## 7. Risks

| risk | mitigation |
|---|---|
| `itwRecordAndAck` blocks up to 30 s if the writer daemon is stuck | the handoff path catches `TranscriptError` and logs; the turn continues |
| the end-of-turn hook adds a turn where there was none | it fires only when the sidecar is non-empty; a test asserts no turn starts with an empty sidecar |
| the wake chain loops | the chain re-checks the sidecar after each synthetic turn and stops when it is empty; a test asserts termination |
| the hook fires while the session lock is still held | the hook is called after the bracket; a test asserts the wake is not skipped as "turn in flight" |
| the hook fires on a provider-resolution failure | the call site is after the early return as well as after the bracket; a test asserts it |

## 8. Definition of done for the whole change

- [ ] WU-1's three failing tests exist and are green.
- [ ] A live gateway run with the fix shows no
      `COMPLETION NOT VISIBLE TO READER` and no `DESYNC` line for a
      completion delivery (the instrumentation from PR #279 stays in
      place as the regression net — see §3 D1).
- [ ] A live gateway run shows a completion that arrives during a turn
      being delivered when the turn ends.
- [ ] `make check` green; hlint clean.
- [ ] The diagnosis doc updated with the post-fix measurements.
