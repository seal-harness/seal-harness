# Sub-agent termination truthfulness — learnings (2026-11-24)

Branch `docs/subagent-termination-truthfulness` (PR #349). Fixes the defect
that a terminated sub-agent was reported as success: a child that hit its
600s delegation deadline was recorded `status=CsCompleted
exit=CerCompleted`. Commits: `d72af9e` (WU-1), `ab7eabd` (WU-1.5),
`02d73d4` (WU-2), `b4d4040` (WU-3), `a9e2f3b` (WU-4), `02b6cc0` (WU-5).

The defect killed the work itself, nine times over: three plan-review
rounds lost reviewers to the 600s deadline, two coder agents died
mid-unit, one adversarial reviewer died mid-audit — all recorded as
*success*. The fix's own implementation had to survive the bug it fixes.

## The exception taxonomy that made the fix possible

`System.Timeout.timeout` raises an exception that **is** a
`SomeAsyncException` but is **not** an `AsyncException`. The existing
discriminator in `Seal.Logging.Exceptions` (`fromException e :: Maybe
AsyncException`) therefore classifies `Timeout` as *synchronous* — it
cannot be reused at a child-run seam. The correct discriminator is
`Maybe SomeAsyncException` (rethrow on `Just`, handle on `Nothing`).
Verified live on GHC 9.12.4: `(True, False)` for the two probes.

`Timeout` is not the only async exception that matters: AGENT_STOP
delivers `ThreadKilled` into the child thread. A seam that rethrows
`SomeAsyncException` handles both — and the kill is then reported by its
*absence* (no completion callback fires), not by parsing a summary.

## Structural beats textual — the summaryRef conflation

The original root cause was not the catch site alone: the child's
exception handler wrote into the **same** `IORef` that genuine final
answers use, and any `Just` mapped to `CerCompleted`. No textual
taxonomy can separate a crash from an answer once both land in one cell.
The fix had two parts, in this order:

1. Stop writing the crash text into the summary cell (a separate
   `terminalReasonRef`).
2. Gate `CerCompleted` on a signal only the real final-answer path sets
   (`aeStopFanoutDone`, written by `deliverFinal` alone — one write site
   in `src/`).

The five non-completion outcome texts still classify textually
(`childStopKind`, kept beside the literals that produce it), but that
classifier is now a *residual* — it only runs when the fanout never
fired, and genuine answers are protected by ordering (fanout-checked
first), so an answer that happens to contain `"(stopped)"` cannot be
misclassified. The battery test pins that ordering.

## A fix that propagates async exceptions changes cleanup contracts

WU-1's review disclosed the sharpest finding of the session: once
`ThreadKilled` propagates instead of being swallowed, every manual
`fork → run → cleanup` sequence around the old swallow becomes a leak.
The heartbeat poller (30s tick, exits only via its stop-MVar) was
orphaned per stopped child — silently defeating the parent's inactivity
timeout. The fix is `Control.Exception.bracket` so the release is
mask-guaranteed. Lesson: when you make an exception *escape* a region
that used to swallow it, audit every cleanup that the swallowing
implicitly guaranteed. (`withHeartbeat`'s release is `tryPutMVar stop ()
>> killThread tid` — the MVar fill alone exits the poller only after the
current tick; the kill is what bounds it.)

## The reviewer found a no-op the suite could not see

WU-5 rev 1 passed the full suite (4907/0) while its production helper was
**a guaranteed no-op for the case it existed to fix**: nested children
write meta + transcript under the parent's `agents/<sid>/` dir, but the
helper read top-level `sessions/<sid>/` paths. Every test reached it with
either `tdBroker = Nothing` (no-op branch) or a missing meta (skip
branch). Green ≠ working when nothing exercises the production path.

The fix for the test gap: `newStreamBroker 4` + `readEntryCursor` give a
cheap real-broker observation channel — assert the **cursor advances**
for a top-level (handoff) child and **stays 0** for a nested one. The
negative test pins the limitation honestly instead of hiding it. (Scope
anchor: the plan's DoD 8 names *handoff* sessions — top-level peers whose
top-level lookups do hit. Nested-child broadcast needs a
directory-aware entry reader in `Gateway/Transcript.hs`; recorded as
follow-up work on the export's Haddock.)

A vacuous-test near-miss from the same unit: the first RED run's
sub-agent id was `sa-a1-timeout-0001` — the id itself contained the
string the assertion checked, so the test passed against the broken
code. Choose fixture identifiers that cannot contain the needle.

## Operating inside a harness whose children die at 600s

`delegation.child_timeout_seconds` (default 600, floor 30) is an
operator-side config; a session cannot change it. Everything below
follows from that wall clock:

- **Briefs need anchors and budgets.** The first plan-review round and
  the WU-4 reviewer both died with no output because their briefs said
  "verify everything" against a 1453-line module. Budget-disciplined
  briefs (read the plan once, ~12 tool calls, load-bearing claims first,
  "not verified in budget" is acceptable evidence hygiene) got verdicts
  from the same models that died open-ended.
- **Recover the work, don't respawn.** Both coder agents died after
  finishing nearly all the work. The tree held it. Validate what the
  dead agent left as if it were untrusted (full diff review, fresh
  build, full suite, hlint, fresh adversarial reviewer) — that is the
  loop's discipline anyway.
- **`nohup ... &` from a shell opcode dies with the opcode's process
  group; `tmux new-session -d` survives.** The full suite in tmux
  (~120s warm) is the reliable pattern.
- **Multi-line commit messages: `git commit -F <file>` via BIN_EXEC.**
  SHELL_EXEC mangles `\n` into literal text (cost one amend to learn).
- **hspec `--match` takes plain substrings and multiple flags OR.**
  Slash-path match patterns select nothing.

## Process observations (upstream, for the maintainers)

- An agent dying at its own deadline is reported as a *success* with the
  exception text as its summary — which is precisely the defect this
  branch fixes. Once merged and deployed, these deaths will read as
  `interrupted (timeout)` in AGENT_INSTANCES.
- `stopAgent` deletes the registry entry before `killThread`, so a
  killed child produces *no* outcome record at all (recorded out of
  scope in the plan); `AGENT_INTERRUPT` cannot interrupt a child
  (flag nothing polls); `RunRecordRegistry` is never populated
  (`shouldDeferDelivery`'s deferral branch is dead code in production).
- The batch pool (`forkIO $ bracketSem sem $ runOne ... >>= putMVar`)
  has no async-safe `putMVar`: an async kill escaping `runOne` in a
  `DiBatch` hangs the parent's `readMVar`. Unreachable in production
  today (only registered tids are killed) — disclosed in the WU-1
  review, still open.
