# Handoff: sub-agent completion delivery (the parent never learns a sub-agent finished)

> **2026-10-23 update:** WU-3 and WU-4 are COMPLETE (commits 058ab1b, 532504c;
> adversarial review PASS on both), and the live-run DoD is verified — see the
> diagnosis doc section 10. What remains of WU-5 is the PR handoff. The status
> sections below are the 2026-10-22 snapshot.

**Date**: 2026-10-22 · **Branch**: `fix/subagent-completion-delivery-diagnostics` (pushed) · **PR**: #279 (draft) · **Plan**: `docs/plans/2026-10-22-subagent-completion-delivery-fix-plan.md`

## 1. Objective

A background sub-agent's completion must reach the parent session's **model**
— and the parent's own messages must survive in the transcript on the way.

**The bug.** The completion was injected into the transcript asynchronously
(`itwRecordAsync`), and the conversation the model is given is read straight
off disk (`itwReadConversation` bypasses the writer daemon's queue). The read
routinely beat the writer, so the parent was told a finished sub-agent was
still running while its verdict sat in the transcript. Second consequence: the
writer's positional diff was sliced against the wrong offset, so the parent's
own messages were dropped from `conversation.jsonl`.

**Live measurement** (real gateway, session `20261022-161101-300`):
21 of 21 completions missed (`missingFromReader == injected`), 19 skipped
wake-ups, 6 completions never delivered, one session dead. The model itself
diagnosed it — *"no agents running — but the transcripts suggest they were
still working. The harness may have stopped them, or they completed and the
notifications [never arrived]"* — and worked around it with 19 `sleep`-poll
calls against the sidecar file.

Full analysis + evidence: `docs/plans/2026-10-22-subagent-completion-delivery-diagnosis.md`.

## 2. Definition of Done (plan §8)

- WU-1's failing tests exist and are green.
- A live gateway run with the fix shows **no** `COMPLETION NOT VISIBLE TO
  READER` and **no** `DESYNC` line for a completion delivery (PR #279's
  instrumentation stays in place as the regression net).
- A live gateway run shows a completion that arrives during a turn being
  delivered when the turn ends.
- `make check` green; hlint clean.
- The diagnosis doc updated with the post-fix measurements.

## 3. Current Status

**Done and committed** (branch pushed):

- **WU-1 — the reproduction.** Four tests, no production change.
  R1 (the parent model is given the verdict), R2 (the transcript keeps the
  verdicts *and* everything the parent wrote), R3 (a verdict arriving
  mid-turn is delivered when the turn ends), R4 (the property the fix relies
  on). R1–R3 fail on the current code, **deterministically — 20 consecutive
  runs**. R2's failure message names the missing messages
  (`expected: [] but got: ["hello","ok"]`), which is the desync itself.
- **WU-2 — the fix.** The handoff is recorded with `itwRecordAndAck`
  instead of `itwRecordAsync` (one line, one call site, the codebase's
  existing ACK-before-execute convention). A handoff that cannot be recorded
  is caught and logged, not thrown into the turn. `itwCloseTranscript` now
  marks the writer dead instead of being a no-op, so the dead-writer path is
  reachable from a test.
  **R1 and R2 now pass.** The suite is 3158 examples with **1 failure (R3)**
  — the stranding, which WU-3 fixes. hlint clean.

**Not started:** WU-3, WU-4, WU-5.

### Working tree

- Branch `fix/subagent-completion-delivery-diagnostics`, **pushed** to origin.
- Recent commits (oldest first): `04dffed` WU-1 reproduction · `1c55ffb`,
  `6ae74b5` hlint fixes · `41c65df` WU-1 result · `1a11a39` plan fixes
  from the gate · `3900e8f` **WU-2 the fix** · `056d7d8` plan non-blocking
  items.
- The plan is tracked in git (not gitignored) — read it from the repo, not
  from a working tree.

## 4. Required Reading (read these before acting, in order)

| # | Path | Why | What to look for |
|---|---|---|---|
| 1 | `docs/plans/2026-10-22-subagent-completion-delivery-fix-plan.md` | **THE PLAN — start here.** | §3 D1/D2/D3 (the design decisions), §4 (WU-1..WU-5, their DoDs and file scopes), §5 (out of scope + tracking items), §6 (rollback), §7 (risks). |
| 2 | `docs/plans/2026-10-22-subagent-completion-delivery-diagnosis.md` | The analysis and the live evidence | §1–§3 (root cause), §6 (fix options and why A was chosen), §7 (the instrumentation), **§9 (the live reproduction — the numbers to re-check after the fix)**. |
| 3 | `src/Seal/Core/TurnEngine.hs` | WU-3's main site | `runTurnBody` (the injection, now `recordHandoff`), `runSessionTurn` (the bracket, the lock, the release action), `TurnDeps` (where `tdOnTurnEnd` goes). |
| 4 | `src/Seal/Gateway/Send.hs` | WU-3/WU-4's main site | `wakeIdleSession`, `tryAcquireWake`/`releaseWake`, `mkWebTurnDeps` (the `TurnDeps` construction), `sdEnableIdleWake`. |
| 5 | `src/Seal/Handles/Transcript.hs` | The writer | `itwRecordAndAck`/`itwRecordAsync`, `itwCloseTranscript` (now marks the writer dead), the positional diff (`new = take newLen (drop writtenLen redactedMsgs)`), the I1/I2 detectors. |
| 6 | `src/Seal/Session/Lock.hs` | `withSessionLock` (the lock is in the bracket's *body*) and `sessionTurnInFlight` (the wake's in-flight check). |
| 7 | `test/Seal/Gateway/SendSpec.hs` | WU-3's tests live here | `mkSendDepsWith`, `seedSession`, `seedConversation`, `RecordingProvider`, the R1–R3 tests. |
| 8 | `test/Seal/Handles/TranscriptSpec.hs` | R4 and the dead-writer test | the `completion-delivery diagnostics` describe block. |

## 5. Key decisions — do not undo these

- **The handoff is durable** (`itwRecordAndAck` at the injection site), not
  a special mode inside the shared writer API. An earlier draft made
  `itwRecordAsync` behave differently for handoffs; two reviewers rejected
  it as disproportionate for one call site, and it would have invalidated a
  committed PR #279 test. The one-line call-site change is the whole fix.
- **The diagnosis doc's "option C"** (carry the completions in the caller's
  in-memory list) is *not* the chosen fix. It avoids the extra fsync but
  needs the completions plumbed into the agent loop. Revisit only if the
  fsync shows up in a latency budget.
- **The end-of-turn hook does NOT fire on the provider-resolution early
  return.** That path returns before the bracket is entered and never
  drains the sidecar, so firing there would start a wake chain that can
  never end. The completions stay pending until the provider resolves.
- **The hook's call site is the turn bracket's *release action*.** After the
  bracket it would be skipped by an exception propagating out of it — so a
  turn that threw would strand its completions, which is the case the hook
  exists for. The release action runs on both paths, and the session lock
  is in the bracket's body, so it is already released by then.
- **`sdEnableIdleWake` is the kill switch** the new trigger is wired behind.
  It is a *construction-time* flag on `SendDeps` (True in the gateway,
  False in the scripted-provider test harnesses), not an operator setting.
- **The process-death case is out of scope** (plan §5): the gateway
  restarting mid-turn loses the turn, and no turn-end hook can fire for it.
  The completions survive in the sidecar and are delivered on the next user
  message. Fixing it needs a startup sweep over every session's sidecar — a
  gateway-lifecycle feature. It is tracked as an item in WU-5.

## 6. Next steps — WU-3 (the stranding)

R3 is the one failing test. It fails because a completion that arrives
while a turn is in flight has **no delivery scheduled**: `wakeIdleSession`
skips the wake-up ("turn in flight") and nothing re-checks when the turn
ends.

The design is settled in the plan (§3 D2); the parts that will bite:

1. **Add `tdOnTurnEnd :: Maybe (SessionId -> IO ())` to `TurnDeps`.** There
   are exactly **four** construction sites: `src/Seal/Gateway/Send.hs:254`
   (the gateway wires it) and `src/Seal/Channel/Cli.hs:216,272,303` (they
   pass `Nothing`). No test constructs `TurnDeps`.
2. **Call it from the turn bracket's release action**, after the idle
   broadcast. Two things to get right: the release action also runs on the
   **abort** path, so the hook must check the session's abort flag
   (`isAborted` over `tdAbortReg`) and skip the wake when the turn was
   aborted; and it must NOT fire on the provider-resolution early return
   (above).
3. **Gate it on `sdEnableIdleWake`** — the same switch that already gates
   the completion wake-up.
4. **Make the wake chain bounded.** `wakeIdleSession` acquires the per-session
   wake mutex, runs a synthetic turn, releases the mutex, and re-checks the
   sidecar; if completions arrived during the turn it starts another
   synthetic turn. A nested wake from the release action correctly skips
   (the mutex is held), so the **outer** frame is what picks the completion
   up. Bound the number of consecutive wake turns (`maxWakeTurns`) and log at
   Warning level if it stops with completions still pending.
5. **The wake internals are not exported** — `wakeIdleSession`,
   `tryAcquireWake` and `releaseWake` are not in `Seal.Gateway.Send`'s
   export list (only `SessionWakeMutex` and `newSessionWakeMutex` are). The
   tests must drive the wake through the public path (the completion
   callback and the new end-of-turn hook) and observe it through the number
   of provider calls the recording provider receives.

**Test-harness traps in `test/Seal/Gateway/SendSpec.hs`:**

- `mkSendDepsWith` leaves `sdTabsHandle` as `error ...` — set it by record
  update (`newTabsHandle`), as the existing tests do.
- The existing `BlockingProvider` blocks on **every** call, so the post-fix
  wake-up turn would hang. R3 needs a provider that blocks only the first
  call — `RecordingProvider` has a one-shot gate for exactly this.
- `CapturingProvider` already exists in that module (it captures a
  `Maybe Text`); the request-recording one is `RecordingProvider`.
- R1/R2 seed a **production-sized** conversation (300 messages × 5KB).
  That size is what makes the reproduction deterministic — see §7.

## 7. Traps and hard-won facts

- **The miss rate scales with the conversation size, and the absolute
  numbers are machine-dependent.** Measured: 3/30 at one small message,
  25/30 at 250KB, **30/30 at 1.5MB**, 50/50 when the writer is kept busy
  by a bulk write queued ahead of the handoff. A second machine measured
  10/10 even at one message. Use a production-sized fixture and re-measure
  rather than trusting any number here.
- **What the desync drops depends on how many completions were injected.**
  With one, the parent's *user message* is dropped and its reply survives;
  with two or more, the reply is dropped too. R2 therefore seeds **two**.
- **`itwCloseTranscript` must mark the writer dead, not enqueue a second
  `ITShutdown`** — the enclosing `withIndexedTranscript` cleanup waits on
  the daemon's ack, so a second shutdown would hang it.
- **A torn read is silently swallowed**: `readConversation` is
  `mapMaybe decode`, so an undecodable trailing line is dropped without an
  error. Not reachable once handoffs are durable, but worth knowing.
- **hlint is part of the gate** (`make check` = build + test + lint). The
  `for_` used in `RecordingProvider` is `Data.Foldable.for_`, not
  `Control.Monad.for_`; the tuple-section hint needs
  `{-# LANGUAGE TupleSections #-}`.
- The three out-of-scope defects found while diagnosing — the
  `agent def not found` spawn errors, the deferred-delivery path (a
  completion whose child has pending descendants is **never** delivered), and
  the `/model` + `/stop` notices never reaching `conversation.jsonl` — are
  **named in plan §5** and must be filed as tracking items in WU-5.

## 8. The gate (already passed — do not re-run it)

The plan went through **four rounds** of the adversarial plan-review gate
(feasibility / completeness / scope-and-alignment, each a fresh reviewer).
**All three now PASS.** Every blocking finding is addressed in the plan; the
rounds are in the git history (`714e2ca`, `6cdbf51`, `1a11a39`, `056d7d8`).

Two of the three reviewers' findings were *about the plan's own text
contradicting itself* (the provider-resolution row, the hook's call site)
and one caught a **wrong measurement** (§2 of the plan) that had been
mis-constructed. If you extend the plan, keep §3 D2, WU-3's Work/DoD and
§7's risk table in agreement — that inconsistency is what the reviewers
found twice.

## 9. Commands

```bash
make check                                   # build + test + lint (the gate)
nix develop --command cabal run test:tests -- --match "sub-agent completion delivery"
nix develop --command cabal run test:tests -- --match "completion-delivery diagnostics"
```

`git push` / `gh` need `BIN_EXEC` in a Seal session (credential injection);
`gh pr create` needs `--head <branch>` in a shallow clone.

**A live check** (the §8 DoD): run the gateway, spawn a background
sub-agent, and confirm the session's `seal.log` shows no
`COMPLETION NOT VISIBLE TO READER` and no `DESYNC` for the delivery, and
that a verdict arriving mid-turn is delivered when the turn ends.
