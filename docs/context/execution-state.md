# Execution State
<!-- updated: 2026-11-24 15:15 -->

## Current Position
-- Active work unit: WU-3 (registry truthfulness)
- Current phase: pre-IMPLEMENT (brief prep)
- Retry count: 0

## WU-2 record (complete)
- Orchestrator-implemented (operator decision after coder deadline-deaths
  #7/#8). Adversarial review PASS (wu-adversarial-reviewer-577f48b3):
  all 6 DoD PASS with evidence; 2 cosmetic nits fixed pre-commit
  (duplicate import entry, doubled blank line); re-verified (build/test/
  hlint green) after the cosmetic fixes.
- Commit 02d73d4. Full suite 4896/0/43 pending. RED: wu2-red2.log;
  GREEN: wu2-green4.log (79/0 targeted).
- Two test-side corrections during GREEN (test defects, not impl):
  prefixed summary expectation; crash injection moved inside the guarded
  region (dwdOnEntry throws, not dwdChildSystemPrompt).

## WU-2 implementation record (uncommitted)
- Loop.hs: ChildStopKind ADT + childStopKind exported (after imports);
  infix matching for provider-notice markers (they arrive as
  prefix <> notice via ccSend/notifyStop); exact-match abort.
- Worker.hs: terminalReasonRef (Nothing :: Maybe ChildExitReason)
  allocated beside summaryRef; catchChildSync handler writes ONLY
  terminalReasonRef (Just CerError) — summaryRef untouched (the
  conflation is gone); exit reason = resolveExitReason summary
  fanoutDone terminalReason; resolveExitReason exported (pure).
- Two behavioral test-side corrections during GREEN (both were test
  defects, not implementation defects):
  1. summary is the channel-prefixed text ("ollama/llama3> done") —
     deliverFinal is called with prefix <> text; expectation fixed.
  2. crash injection must be INSIDE the guarded region — dwdOnEntry
     throws (fires inside runTurn), not dwdChildSystemPrompt (fires
     before the guard); fixed.
- RED: wu2-red2.log (not-in-scope compile RED). GREEN: wu2-green4.log
  79/0 targeted. hlint: No hints (wu2-hlint.log).
- Full suite: running (wu2-full-test.log).

## WU-2 design (from plan §2 + code read)
- Loop.hs: new exported ChildStopKind ADT (CskMaxTurns/CskProviderError/
  CskRetryExhausted/CskTruncation/CskAbort) + childStopKind :: Text ->
  Maybe ChildStopKind, matching the five real markers (verified):
  max-turns prefix "(stopped: reached the"; provider error prefix
  "provider error: "; retry exhausted infix "The model returned an
  unusable response"; truncation infix "(stopped: response truncated at
  the"; abort EXACT "(stopped)". Order: exact abort first.
- Worker.hs: terminalReasonRef beside summaryRef; catch handler writes
  ONLY the reason (no summaryRef write); new exported pure
  resolveExitReason :: Maybe Text -> Bool -> Maybe ChildExitReason ->
  ChildExitReason (crash reason wins; fanoutDone gates CerCompleted;
  else classify summary; residual CerMaxIterations).
- Tests: WorkerSpec — resolveExitReason pure battery + behavioral:
  normal completion (Just "done", CerCompleted) and sync crash via
  throwing dwdOnEntry → (Nothing, CerError) [RED today: CerCompleted +
  "child runTurn raised" summary]. ConcurrentSpec — childStopKind
  five-way + negative (final answer → Nothing).
- Child env always wires aeOnStop (Worker.hs:358) so deliverFinal regime
  1 always applies → fanoutDone is a sound completion discriminator.
- Files: Loop.hs, Worker.hs, WorkerSpec.hs, ConcurrentSpec.hs.

## WU-1.5 record (complete)
- Coder coder-agent-d6195031 died at the 600s deadline mid-unit
  (reproduction #8): tests + spy helpers written, implementation not
  started. Orchestrator completed the implementation (withHeartbeat
  bracket) per the approved brief; one self-caught design error fixed
  pre-review (release must killThread the captured tid, not just fill
  the stop MVar).
- Validation: build -Werror exit 0; targeted 20/0; FULL SUITE
  4877/0/43 pending PASS (in tmux — nohup proven unreliable);
  hlint No hints (const action fix).
- Adversarial review: PASS (wu-adversarial-reviewer-33acd1fd) — masking
  audit, falsifiability of all 4 tests, spy soundness, second-async
  resilience; landmines #2 (batch putMVar) and #3 (debug-append) remain
  disclosed-only.
- Commit ab7eabd (amended once to fix a literal-\n message artifact from
  SHELL_EXEC; BIN_EXEC is the reliable multi-line commit path).

## Work Unit Status
| WU | Status | Phase | Retries |
|----|--------|-------|---------|
| WU-1 seam + catchChildSync + 3 catch sites | COMPLETE | COMMITTED d72af9e | 0 |
| WU-1.5 heartbeat bracket (operator-approved) | COMPLETE | COMMITTED ab7eabd | 0 |
| WU-2 structural exit reason | PENDING | — | 0 |
| WU-3 registry truthfulness | PENDING | — | 0 |
| WU-4 handoff callback | PENDING | — | 0 |
| WU-5 live broadcast | PENDING | — | 0 |
| WU-6 make check | PENDING | — | 0 |

## WU-1 record (complete)
- Implementer: coder-agent-26a44881 (killed at 600s deadline after finishing
  the code — reproduction #7; work recovered from the tree and validated)
- Validation (orchestrator-run): build -Werror exit 0; full suite 4873/0/43
  pending (delta = ollama-absent engram pendings, environmental); hlint No
  hints; scope exact (3 files).
- Adversarial review: PASS (wu-adversarial-reviewer-e2d7ec59) — DoD 1-5 all
  PASS; 3 disclosed landmines recorded in project-context.md; #1 (heartbeat
  orphan) promoted to WU-1.5 by operator decision; #2 (batch pool putMVar)
  and #3 (debug-append Timeout) stay disclosed-only for now.
- Commits: d72af9e (WU-1), c16f33d (docs bookkeeping)

## Baseline
- Pre-WU-1 make check GREEN at 3f939c6 (4868/0/41); post-WU-1 suite
  4873/0/43 (engram pendings environmental). Build warm. PR #349 draft open.

## Constraints (this session)
- 600s hard child deadline; SIGPIPE pitfall; never --no-verify; never
  force-push; no ~/.seal/ writes; background processes must use tmux
- Coverage gate enforcement command: make test

## Blocked / Escalated
none
