# Sub-agent completion delivery — root-cause analysis

**Date:** 2026-10-22
**Incident:** session `20261021-204208-162` (repo `equitek/vtag`, agent `vtag--agents-md`).
**Status:** root cause identified; instrumentation lands first, the behavioural fix follows.

---

## 1. Symptom

The parent session spawned five background reviewers (round 3 of a design-review
gate) and then sat idle. All five sub-agents ran to completion and every
completion was delivered into the parent's transcript — but the parent's model
never saw four of them. Its final answer said so verbatim:

> Four reviewers still out on round 3 (architect, designer, security, CTO).
> I'll fold their verdicts as they land, then push and move to the plan.

The four verdicts were already in the transcript, sitting two messages above
the final answer. The session then went quiet — nothing was left to trigger a
new turn, so the session looked dead.

## 2. How the delivery path is supposed to work

```
child thread finishes
  └─ Agent.hs  callback
       ├─ appendCompletionToSidecar  → <sessionDir>/agent-completions.jsonl
       └─ onIdleCompletion hook → Gateway/Send.hs wakeIdleSession
            ├─ if a turn is in flight → SKIP (completion waits in the sidecar)
            └─ else → runSessionTurn → TurnEngine.runTurnBody
                        ├─ readAndClearCompletions   (drain the sidecar)
                        ├─ itwRecordAsync            (inject into conversation.jsonl)
                        └─ runTurn
                             └─ prior <- itwReadConversation   ← builds the model's context
```

The injection is written with `itwRecordAsync` (fire-and-forget) and the
model's context is built by `itwReadConversation`, which reads
`conversation.jsonl` **straight off disk** — it does not go through the
writer daemon's queue.

## 3. Root cause

**The completion injection is enqueued asynchronously and the model's context is
read back from the file immediately afterwards. The writer daemon usually has
not flushed yet, so the model never sees the completions — while the
completions still land in the transcript, moments later.**

Measured on the incident session (`seal.log` + `entries.jsonl`):

| event | timestamp | Δ |
|---|---|---|
| injection entry created + enqueued | `13:50:08.631419` | — |
| model's request entry created (context read already done) | `13:50:08.631664` | **0.25 ms** |
| model's own words at the next turn | *"The user sent "." — a nudge. The round-3 agents are still running."* | — |

The model was told, in the same breath, that the round-3 agents were still
running — because the message announcing the PM's completion (0.25 ms old)
was not in its context yet.

A second, later injection reproduced it with four completions at once
(`13:51:50.821444` → `13:51:50.821712`): the four verdicts were appended to
`conversation.jsonl` at indices 501–504, and the model — reading at
+0.27 ms — carried on folding in the *previous* review, then ended its turn
claiming four reviewers were outstanding.

### 3.1 Why the transcript is also corrupted

The writer daemon diffs positionally: it keeps the conversation it has written
(`itsWritten`) and appends `take newLen (drop writtenLen incoming)`. The
caller passes a list whose length it computes from **its own** in-memory
conversation.

After an injection the daemon is `N` messages ahead of the caller's list, so
the caller's next writes are sliced against the wrong offset. The result is
that messages are silently **dropped** from `conversation.jsonl`:

```
255 …                    (call round)
256 Assistant  USE:call_function_4yzpzsr10elm_1   ← in the model, not on disk
257 User      [subagent security-design … completed]
258 User      [subagent designer … completed]
259 User      RES:call_function_4yzpzsr10elm_1   ← on disk, its tool-use is not
```

Five tool results in the incident session have no matching tool call:
`4yzpzsr10elm_1/2`, `drz3z9u3rkgv_1/2`, `xvwxqmcjqbyj_1`. Every one of them
sits immediately after a completion injection. After the injection the file is
permanently offset from the model's context by `N` messages, so every
subsequent tool result is written *before* the tool call that produced it.

## 4. Other ways this can strand a completion

The race above is the one that hit this session, but the same "the session
goes quiet" symptom has at least three other causes on this path:

1. **Wake skipped while a turn is in flight.** `wakeIdleSession` skips the
   wake-up when `sessionTurnInFlight` is true. The completion then waits in
   the sidecar until the *next* turn starts. If the in-flight turn was the
   last one (the model gave its final answer), nothing wakes the session —
   the completion is stranded until a human types something.
2. **The wake mutex leaks on an exception.** `wakeIdleSession` takes the
   per-session wake mutex and releases it *after* `runSessionTurn`. An
   exception in the turn skips the release, and the mutex stays held forever:
   every later completion logs `skipping (wake mutex held)` and the session
   can never be woken again.
3. **A torn read.** `itwReadConversation` reads the file while the daemon may
   be mid-append. `readConversation` is `mapMaybe decode` — a partially
   written trailing line fails to decode and is **silently dropped**, so a
   reader can lose the last message with no error anywhere.

## 5. What the instrumentation has to make visible

None of the above was visible from the outside. The transcript showed the
completions had been delivered; the model said they had not. The two facts
contradict each other and nothing flagged the contradiction.

The instrumentation therefore has to assert the two invariants that were
violated, not just add more log lines:

- **I1 — visibility.** Every message the writer has recorded for a
  completion injection must be present in the conversation the model is
  given. *Breach:* the model is told the agents are still running.
- **I2 — alignment.** The conversation the caller hands the writer must be a
  prefix-extension of the conversation the writer has recorded. *Breach:*
  messages are silently dropped from `conversation.jsonl` and the file
  diverges from the model's context.

Plus a **stranding** check: a completion still sitting in the sidecar when a
turn ends means no wake-up is pending for it.

## 6. Fix options (follow-up PR)

| option | change | notes |
|---|---|---|
| **A** | inject with `itwRecordAndAck` instead of `itwRecordAsync` | one line; adds an fsync at turn start; still races with a *torn* file read |
| **B** | add a "record and wait" that blocks for the write to be durable, with a short timeout that logs instead of throwing | avoids the 30 s `TranscriptError` hazard of A |
| **C** | pass the completions into `runTurn` and prepend them to the in-memory conversation instead of writing them to the file first | the loop then writes them as part of its normal request entry, so the writer's diff stays aligned by construction and the model sees them — no extra fsync, no second source of truth |

**C is the recommended fix.** It removes the race instead of narrowing it, and
it repairs I1 and I2 together: the caller's list and the writer's list stay
the same length because the completions travel *with* the list rather than
being written behind its back.

Whatever is chosen, the I1/I2 assertions from §5 must land with it — they are
the regression net.

## 7. What this PR adds (instrumentation only)

No behaviour changes. The PR makes both invariant breaches visible, so the
next occurrence is diagnosable from the logs alone instead of requiring a
forensic read of the transcript.

### `Seal.Handles.Transcript`

* `TranscriptDiagnostics` — counters for the two invariant breaches:
  `tdInjectedTailMisses` (I1) and `tdDesyncEvents` /
  `tdDesyncDroppedMessages` (I2). Exposed via `itwDiagnostics`.
* `itwRecordedLength` — the writer's own count of the conversation it has
  recorded, so a reader that is behind the writer can be quantified.
* **I1 check.** When a completion injection is enqueued, the writer remembers
  the injected messages. `itwReadConversation` — the read that builds the
  model's context — asserts that they are in the snapshot. If they are not,
  the writer logs
  `[transcript-diag] COMPLETION NOT VISIBLE TO READER` (global log + the
  session's `seal.log`) with the injected / missing / reader / writer counts.
  The expectation is dropped once the writer has actually written the
  injection, so the check fires on the genuine race and not on a stale read.
* **I2 check.** Every write asserts that the caller's conversation is a
  prefix-extension of the writer's: the caller's length must not be below
  the writer's, and the message at the writer's last position must be the
  same in both. A breach logs `[transcript-diag] DESYNC` with the writer
  length, the caller length and the number of messages that were dropped.
  Both checks are O(1) comparisons plus one list walk — no full prefix scan
  on the hot path.

### `Seal.Core.TurnEngine`

* `[completion-diag] injecting N sub-agent completion(s)` — the count and
  the conversation length before the injection, so the transcript's
  `subagent-completion` entry can be tied to a turn.
* `[completion-diag] N sub-agent completion(s) still pending when the turn
  ended` — a completion left in the sidecar has no delivery scheduled; the
  idle wake-up was skipped because a turn was in flight. Logged on every
  exit path, including a failed turn.

### `Seal.Gateway.Send`

* The same pending check after the idle wake-up's synthetic turn, so a
  completion that arrived *during* the wake-up turn is visible.

### `Seal.ISA.Ops.Agent`

* The sidecar-append log now carries the child session id and the message
  size, so the append can be correlated with the injection.

## 8. What the logs look like when the bug bites

```
[idle-diag] completion appended to sidecar: subagent=vtag--cto-agent-fd7234e3 \
  parentSid=20261021-204208-162 childSession=20261022-134436-273-0764 messageChars=2411
[completion-diag] injecting 4 sub-agent completion(s); conversation length before injection = 501
[transcript-diag] COMPLETION NOT VISIBLE TO READER. injected=4 missingFromReader=4 \
  readerLen=501 writerLen=505
[transcript-diag] DESYNC: caller conversation is not a prefix-extension of the writer's \
  conversation. writerLen=505 callerLen=502 droppedMessages=3
```

The first two lines are the normal path. The third is the bug: the reader
that built the model's context had 501 messages while the writer had been
asked to record 505. The fourth is its consequence — the caller's next write
was sliced against the wrong offset and three messages were dropped from
`conversation.jsonl`.

With the fix (§6, option C) the third and fourth lines do not appear.

