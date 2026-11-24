# Project Context (Maintained by Orchestrator)

## Tooling
- Build: `make build` (nix dev shell; SIGPIPE pitfall — redirect to a log
  file, never pipe cabal/hlint through head/tail)
- Test: `make test`; focused: `cabal test --test-options='--match "<needle>"'`
- Lint: `make lint` (hlint src/ test/ — must report: No hints)
- Full gate: `make check` (build + test + lint + frontend tests)
- Frontend: `cd frontend && npm run build` — `frontend/dist` must exist for
  file-embed when the library builds

## Session-proven operational facts
- Background processes: use `tmux new-session -d` — `nohup ... &` from a
  SHELL_EXEC dies with the opcode's process-group teardown (proven twice).
- A full-suite `nix develop --command cabal test` from a warm build runs in
  ~120s (4873 examples).
- Sub-agent budget: 600s hard wall (delegation.child_timeout_seconds). A coder
  that must rebuild an import closure + run tests fits IF it stays targeted;
  the WU-1 coder finished its work but lost its report to the deadline
  (reproduction #7). Keep briefs tight; pre-read target regions.

## Completed Work Units
| WU | Title | Commit | Key changes |
|----|-------|--------|-------------|
| WU-1 | catchChildSync + runChildWithTimeout seam + 3 catch sites | d72af9e | Delegation.hs:129-136 catchChildSync (rethrow SomeAsyncException); :141-142 runChildWithTimeout = timeout; runOne :623-624 + runWorker :804-806 converted; Worker.hs:376-378 converted (summaryRef write kept for sync, moves in WU-2); ConcurrentSpec #12-14 (ThreadKilled propagates; sync/async pair; budget seam Nothing/Just) |

## Established Patterns (verified by the 2026-11-24 plan-review gate + WU-1)
- ChildExitReason ADT: Delegation.hs CerCompleted/CerError/CerMaxIterations/CerTimeout;
  childStatusFor maps reason → CsCompleted/CsError/CsMaxIter/CsTimeout
- Worker.hs:376-381 (post-WU-1): catchChildSync now rethrows async; handler
  still writes "child runTurn raised: ..." into summaryRef for SYNC errors —
  and :380-382 still maps any `Just` summary to CerCompleted. WU-2 must
  (a) move the catch write out of summaryRef into terminalReasonRef,
  (b) gate CerCompleted on aeStopFanoutDone, (c) classify the five
  non-completion returns via Loop's childStopKind.
- aeStopFanoutDone :: IORef Bool (Env.hs:164) — set True ONLY in deliverFinal
  (Loop.hs:224, sole src/ write); per-child ref allocated Worker.hs:~303,
  wired ~:366
- Five notifyStop outcome sites: Loop.hs:256 (max turns) / :366 (provider
  error) / :414 (retry exhausted) / :498 (truncation) / :548 (abort)
- Handoff callback defects: Agent.hs:952-957 (register+log only) with
  self-parent registration :959; correct background form :884 passes
  parentSid; sidecar append :869, parent wake :881; hasRunningChildren
  filters aiParentSession (Registry.hs:101-105)
- dwdOnEntry :: IO (): Worker.hs:235 (field), :363 (use), TurnEngine.hs:1311
  (`= pure ()`), WorkerSpec.hs:471 (test); broadcastNewEntries takes
  sid/model/createdAt (existing pattern TurnEngine.hs:1185)
- Registry: registerCompletedAgentResult Registry.hs:204-222 (log line
  hardcodes "Crashed"/"Stopped" :220-221; stores aiResult :216);
  handleStatus already renders exit_reason (Agent.hs:1050-1057);
  handleInstances renders only aiStatus (Agent.hs:775-783)

## Disclosed landmines from WU-1 review (not owned by any current WU)
1. Heartbeat orphan: a propagated ThreadKilled (AGENT_STOP) now skips
   `void (tryPutMVar hbStop ()); killThread hbThreadId` cleanup at
   Delegation.hs:624-629/:806-810 — heartbeatLoop never exits, keeps
   touching the parent-activity cell every 30s, defeating the parent's
   inactivity timeout. One leak per stopped child. Fix: bracket the
   heartbeat around runChildWithTimeout.
2. Batch pool: forkIO'd runOne with a semaphore has no async-safe putMVar;
   an async kill escaping runOne in a DiBatch hangs the parent's readMVar
   (unreachable in production today — only registered tids are killed).
3. Loop.hs:779/797/811 debug-append catches swallow a mid-append Timeout
   when aeDebugRequestsPath is set (narrow, debug-only).

## Active Services
See SERVICE-INVENTORY.md (not yet created)
