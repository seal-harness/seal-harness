# Sub-agent completion delivery — implementation plan

<!-- status: draft — awaiting plan-review gate -->
<!-- date: 2026-10-22 -->
<!-- diagnosis: docs/plans/2026-10-22-subagent-completion-delivery-diagnosis.md -->
<!-- branch: fix/subagent-completion-delivery-diagnostics (PR #279, draft) -->

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

## 2. What we measured (this is why WU-1's test is deterministic)

A throwaway probe (200+ runs) measured how often the reader loses the
race, as a function of the write's position in the writer's queue:

| shape | reader missed the injection |
|---|---|
| injection is the **first** write on a fresh handle | **50 / 50 (100%)** |
| injection follows an earlier write (warm daemon) | 0 / 50 (0%) |

The transcript handle is opened **per turn** (`withIndexedTranscript` in
`runSessionTurn`), so in production the completion injection is *always*
the first write on a fresh handle — the daemon has only just been forked
and has not reached its queue read when the model's context is built.

⇒ The bug is not a rare interleaving. It is the normal path, and it is
reproducible in a unit test with no timing luck involved.

## 3. Design decisions

### D1 — the handoff must be durable before the model's context is built

The writer exposes one durable primitive (`itwRecordAndAck`) and one
fire-and-forget primitive (`itwRecordAsync`). The completion injection
uses the fire-and-forget one, and the read that builds the model's
context is a direct file read that does not go through the writer's queue.

**Decision: make the completion handoff durable at the point it is
requested.** The `EntryRecord` already carries `erHarness = Just
"subagent-completion"`, so the writer can recognise a handoff without any
new plumbing. `itwRecordAsync` waits for the handoff to be fsync'd before
returning; every other write stays fire-and-forget.

*Why here rather than at the call site in `TurnEngine`:* the regression
test in WU-1 must exercise the *same* call the production path makes, or
it does not stay a regression test. Making the behaviour a property of
the handoff (rather than of one call site) keeps the production path and
the test on one code path.

*Rejected alternative:* change `TurnEngine` to call `itwRecordAndAck` and
have the regression test call `itwRecordAndAck` too. Rejected because the
test would then assert the behaviour of the *fixed* call rather than of
the code that was broken — it would not have failed before the fix.

*Consequence:* the name `itwRecordAsync` becomes a slight misnomer for
handoffs. The doc comment will say so explicitly. (Alternative considered:
rename the method — rejected as churn across call sites for no
behavioural gain.)

*Durability semantics:* after the handoff is durable, the file contains
the completions, so the next read — the one that builds the model's
context — necessarily contains them. The writer's recorded conversation
and the caller's list are then the same length, so the positional diff
stays aligned and no messages are dropped.

*Error handling:* `itwRecordAndAck` raises `TranscriptError` if the
writer daemon is dead or stuck. A handoff that cannot be recorded must
not kill the turn: the error is caught, logged at Error level, and the
turn continues without the injection (the completion is lost, but the
session survives and the failure is visible).

### D2 — a completion that arrives during a turn is delivered when the turn ends

When `wakeIdleSession` skips the wake-up because a turn is in flight,
nothing is scheduled to pick the completion up.

**Decision: the turn engine announces the end of every turn, and the
gateway checks for pending completions then.**

- `TurnDeps` gains `tdOnTurnEnd :: Maybe (SessionId -> IO ())` (the CLI
  paths pass `Nothing`; the gateway wires it).
- `TurnEngine.runSessionTurn` calls it *after* the turn's bracket — i.e.
  after the session lock is released and the idle broadcast has fired —
  so a wake started from it is not blocked by the turn that is ending.
- `Gateway/Send.hs` implements it: if `pendingCompletionCount` is
  non-zero, call `wakeIdleSession`.

*Re-entrancy:* when the ending turn is itself a wake-up turn, the
per-session wake mutex is still held, so the nested `wakeIdleSession`
skips — which is correct, because the outer `wakeIdleSession` re-checks
for pending completions after its turn finishes and starts another
synthetic turn if any arrived meanwhile. The chain terminates when the
sidecar is empty.

*Ordering wart:* the idle broadcast fires before the new turn's thinking
broadcast, so the frontend sees idle → thinking. Accepted (the current
code has the same wart in the opposite direction).

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
- `test/Seal/Handles/TranscriptSpec.hs` — R4 (the mechanism)

**Test infrastructure needed (test only).** `SendSpec` already defines a
local `ScriptProvider`; it pops canned responses but *discards* the
`CompletionRequest`, so a test cannot assert what the model was given.
Add a local `CapturingProvider` to `SendSpec` that records every
`CompletionRequest` it receives (an `IORef [CompletionRequest]`) and
returns a scripted response. That is the whole of the new test
infrastructure — no new module, so no `.cabal` / `test/Main.hs` edits.

**R1 — the parent model is given the sub-agent's verdict.** *(the
user-visible symptom)* Seed the session's sidecar with a completed
sub-agent's message (`appendCompletionToSidecar`), run one turn through
`handleSend`, and assert the `CompletionRequest` the provider received
contains the verdict.

Today: the turn engine's injection is the first write on the turn's
fresh transcript handle, so the read that builds the model's context
beats the writer (measured: 50/50 misses — §2). The request does not
contain the verdict -> **fails**.

**R2 — the transcript keeps both the verdict and the parent's own
message.** After R1's turn, read `conversation.jsonl` and assert it
contains the verdict *and* the parent's reply, in that order, with
nothing lost.

Today: the writer is ahead of the caller's list by the number of
injected messages, so the parent's own reply is dropped from the file
and replaced by the verdict -> **fails**.

**R3 — a verdict that arrives while the parent is mid-turn is delivered
when the turn ends.** Run a turn whose provider blocks (so a turn is in
flight), deliver a verdict to the sidecar while it runs, let the turn
end, and assert the verdict is delivered — the sidecar is drained and a
subsequent provider request contains it.

Today: the wake-up is skipped ("turn in flight") and nothing re-checks
when the turn ends -> the verdict stays in the sidecar -> **fails**.

**R4 — the mechanism, in isolation.** *(the transcript handle, in the
same shape the turn engine uses)* With a fresh handle, enqueue a
completion handoff and then read the conversation the way the turn
engine does:

```haskell
withIndexedTranscript dir $ \h -> do
  itwRecordAsync h (IndexedTranscriptWrite (prior <> completion) handoffEntry)
  modelContext <- itwReadConversation h
  completion `shouldSatisfy` (`elem` modelContext)
```

Today: the handoff is the first write on a fresh handle, so the reader
beats the writer -> **fails** (measured 50/50, §2).

**DoD:**
- [ ] R1, R2, R3, R4 exist and **fail** on the current code.
- [ ] The failures are **deterministic**: each fails on 20 consecutive
      runs (the measured miss rate is 100% for this shape — see §2).
- [ ] Each failure message names the defect and points at the diagnosis
      doc.
- [ ] No production file is touched by this work unit.
- [ ] `make test` reports exactly these four as failing (and nothing
      else newly failing).

**Verification:** `make test` — four named failures with the expected
messages.

### WU-2 — Make the completion handoff durable

**Files:**
- `src/Seal/Handles/Transcript.hs`
- `test/Seal/Gateway/SendSpec.hs` (R1, R2 go green)
- `test/Seal/Handles/TranscriptSpec.hs` (R4 goes green; new cases for the
  dead-daemon path)

**Work:**
- `itwRecordAsync` waits for durability when the entry is a completion
  handoff (`erHarness == Just completionHarnessTag`); every other write
  stays fire-and-forget.
- The dead/stuck-daemon path is caught and logged, not thrown into the
  turn.
- The doc comments on `itwRecordAsync` and on `completionHarnessTag` state
  the durability rule.

**DoD:**
- [ ] R1, R2 and R4 pass.
- [ ] R1/R2/R4 pass on 20 consecutive runs (no flakiness introduced).
- [ ] The full suite is green; `hlint src/ test/` reports "No hints".
- [ ] A new test covers the dead-daemon path: the turn's caller sees the
      error logged, not an exception.
- [ ] `itwRecordAsync` for a non-handoff write is still fire-and-forget
      (asserted by a test that does not block).

**Verification:** `make check`.

### WU-3 — Deliver completions that arrive during a turn

**Files:**
- `src/Seal/Core/TurnEngine.hs` (`TurnDeps`, `runSessionTurn`)
- `src/Seal/Gateway/Send.hs` (the end-of-turn hook, the wake chain)
- `src/Seal/Channel/Cli.hs` (`tdOnTurnEnd = Nothing`)
- `test/Seal/Gateway/SendSpec.hs` (R3 goes green; a new test for the
  chain: a completion arriving *during* the wake turn is delivered by a
  second wake turn)

**DoD:**
- [ ] R3 passes.
- [ ] A completion that arrives during a wake-up turn is delivered by a
      follow-up wake-up turn (new test).
- [ ] The chain terminates: with an empty sidecar, no further turn
      starts (asserted by a turn counter in the test).
- [ ] The end-of-turn hook fires after the session lock is released (a
      test asserts the wake is not skipped as "turn in flight").
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

### WU-5 — Final review, knowledge capture, PR

- [ ] The full diff is reviewed against the diagnosis doc §9 (the live
      evidence): every number quoted there is re-checked against the
      fixed behaviour.
- [ ] `self-reflect` is run and the learnings committed to the knowledge
      base.
- [ ] The PR describes both defects, the live evidence, and the fix.
- [ ] `make check` green on the final commit; the PR is marked ready.

## 5. Out of scope

- **The `agent def not found` errors.** Five of the eighteen completions
  in the live session were `status=CsError error: agent def not found:
  dr3-pm`. That is a separate defect (the parent spawned agent defs that
  do not exist) and it is tracked separately.
- **The torn-read hazard.** `readConversation` is `mapMaybe decode`, so a
  partially written trailing line is silently dropped from a reader's
  snapshot. Not reachable once handoffs are durable (the write is
  fsync'd before the read), but it is a latent hazard worth its own
  issue.
- **The `/model` and `/stop` notices never reaching
  `conversation.jsonl`.** `Command/Model.hs` and `Command/Stop.hs` append
  a one-message list to a session whose conversation they never read, so
  the writer's positional diff drops it. A pre-existing bug, unrelated to
  completion delivery, but it was found by the new alignment detector and
  deserves its own issue.

## 6. Risks

| risk | mitigation |
|---|---|
| `itwRecordAndAck` blocks up to 30 s if the writer daemon is stuck | the handoff path catches `TranscriptError` and logs; the turn continues |
| making one `itwRecordAsync` call durable surprises a caller that expects fire-and-forget | the behaviour is keyed on the entry's harness tag and documented on the method; the turn engine's only handoff call is the completion injection |
| the end-of-turn hook adds a turn where there was none | it fires only when the sidecar is non-empty; a test asserts no turn starts with an empty sidecar |
| the wake chain loops | the chain re-checks the sidecar after each synthetic turn and stops when it is empty; a test asserts termination |

## 7. Definition of done for the whole change

- [ ] WU-1's three tests exist and are green.
- [ ] A live gateway run with the fix shows no
      `COMPLETION NOT VISIBLE TO READER` and no `DESYNC` line for a
      completion delivery (the instrumentation from PR #279 stays in
      place as the regression net).
- [ ] A live gateway run shows a completion that arrives during a turn
      being delivered when the turn ends.
- [ ] `make check` green; hlint clean.
- [ ] The diagnosis doc updated with the post-fix measurements.
