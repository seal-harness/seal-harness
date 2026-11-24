# Execution State
<!-- updated: 2026-11-24 12:30 -->

## Current Position
- Active work unit: WU-2 (structural exit reason)
- Current phase: pre-IMPLEMENT (WU-1 complete + committed; next brief prep)
- Retry count: 0

## Work Unit Status
| WU | Status | Phase | Retries |
|----|--------|-------|---------|
| WU-1 seam + catchChildSync + 3 catch sites | COMPLETE | COMMITTED d72af9e | 0 |
| WU-2 structural exit reason | PENDING | pre-IMPLEMENT | 0 |
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
  PASS with live GHC 9.12.4 evidence; 3 disclosed landmines recorded in
  project-context.md (heartbeat orphan / batch-pool putMVar / debug-append
  Timeout swallow).
- Commit d72af9e on docs/subagent-termination-truthfulness (branch of PR #349).

## Next: WU-2 brief (plan Design §2)
- Files: src/Seal/Agent/Runtime/Delegation/Worker.hs,
  src/Seal/Agent/Loop.hs, test/Seal/Agent/Runtime/Delegation/WorkerSpec.hs,
  test/Seal/Agent/Runtime/Delegation/ConcurrentSpec.hs
- Worker.hs: terminalReasonRef :: IORef (Maybe ChildExitReason) separate from
  summaryRef; catch handler writes reason there (NOT summaryRef); exit
  reason = CerCompleted iff aeStopFanoutDone, else classify summary via
  childStopKind (five kinds), else fallback per plan invariant.
- Loop.hs: export childStopKind :: Text -> Maybe ChildStopKind beside the
  five notifyStop literals (max turns :256 / provider error :366 / retry
  exhausted :414 / truncation :498 / abort :548).
- Tests: WorkerSpec — reason not derived from summary (crash → CerError even
  when summaryRef has text? NO — after WU-2 the catch writes reason ref;
  test that a runTurn sync crash yields CerError by reason, and a normal
  completion yields CerCompleted gated on aeStopFanoutDone);
  ConcurrentSpec — five-way reason taxonomy.
- NOTE for brief: WorkerSpec.hs:471 uses dwdOnEntry — WU-5 changes its type;
  WU-2 must NOT touch the hook type (leave it :: IO ()).

## Baseline (recorded 2026-11-24 11:52)
- make check GREEN at 3f939c6: 4868 examples / 0 failures / 41 pending;
  hlint No hints; 1163 frontend tests
- Build warm; frontend/dist exists; draft PR #349 open
- Post-WU-1 suite: 4873/0/43 pending (ollama-absent engram pendings are
  environmental)

## Constraints (this session)
- 600s hard child deadline; SIGPIPE pitfall; never --no-verify; never
  force-push; no ~/.seal/ writes; background processes must use tmux
- Coverage gate enforcement command: make test

## Blocked / Escalated
none
