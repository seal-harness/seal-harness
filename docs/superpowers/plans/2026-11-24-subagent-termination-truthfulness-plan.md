# Sub-agent termination is reported as success — TDD plan (rev 6)

**Date:** 2026-11-24
**Scope (operator-approved):** root cause + truthful status + handoff parent
linkage + UI visibility.

## Rev 6 — the design changed, because round 5 proved my approach was unsound

Round 5's finding #2 is decisive and I verified it. At `Worker.hs:376-378` the
child's exception handler writes its text into the **same** `summaryRef` used
for genuine final answers, and `:379-381` then maps any `Just` to
`CerCompleted`:

```haskell
runApp ... (runTurn env (ctGoal task))
  `catch` \e -> writeIORef summaryRef
               (Just ("child runTurn raised: " <> T.pack (show e)))
summary <- readIORef summaryRef
let exitReason = case summary of
      Just _  -> CerCompleted
      Nothing -> CerMaxIterations
```

**No amount of inspecting the summary text can separate "crashed" from
"answered"**, because both land in the same `IORef`. Rev 5's marker taxonomy was
structurally unable to work. It was also incomplete: `Loop.hs` has **five**
`notifyStop` sites (`:256`, `:366`, `:414`, `:498`, `:548`), not the three I
claimed — provider error and retry-exhausted would both still have been
reported as success.

### The discriminator the code already maintains

`aeStopFanoutDone` (`Env.hs:164`) is set `True` **only** in `deliverFinal`
(`Loop.hs:224`) — the genuine final-answer path — and the child already wires a
per-child `IORef` for it (`Worker.hs:367`). It is never set on max-turns,
truncation, abort, provider-error or retry-exhausted.

So the exit reason becomes structural rather than textual:

| Observation | Reason |
|---|---|
| threw `Timeout` | rethrown → `timeout` → `CsTimeout` |
| threw sync (via `catchChildSync`) | `CerError` |
| returned, `aeStopFanoutDone` is `True` | `CerCompleted` |
| returned, hook not fired | needs distinguishing (below) |

For the remaining non-completion returns, `Loop` already funnels them through
`notifyStop` with the *outcome text*. Instead of a taxonomy of string markers,
`Worker` classifies with a single exported predicate pair kept beside the
literals that produce them, and the catch handler no longer writes into
`summaryRef` at all — it records the reason in a separate `IORef`. That removes
the ambiguity at its source.

## Gate history

Five rounds; every failure accepted. Six live reproductions of the defect
occurred during the exercise, including **twice by reviewers auditing it**, and
twice more when I stopped reviewers:

```
status=CsCompleted exit=CerCompleted
child runTurn raised: <<timeout>>       # 600s deadline (x2)
child runTurn raised: thread killed     # killThread / AGENT_STOP (x4)
```

## Problem

`System.Timeout.timeout` raises an **async** exception; three
`catch @SomeException` sites swallow it, so `timeout` never returns `Nothing`.
Measured: the incident child ran **599.606s** against a **600.0s** deadline and
was recorded as success.

Verified with real GHC at the exact production nesting — **both** sites must
rethrow:

| inner `Worker.hs` | outer `Delegation.hs` | result |
|---|---|---|
| current | current | `Just ("child runTurn raised: <<timeout>>","CerCompleted")` |
| fixed | current | `Just ("<<timeout>>","CerError")` |
| current | fixed | `Just ("child runTurn raised: <<timeout>>","CerCompleted")` |
| fixed | fixed | `Nothing` → `CsTimeout` |

### Taxonomy (measured)

`Timeout` **is** a `SomeAsyncException` but **not** an `AsyncException`, so
`Seal.Logging.Exceptions`'s `Maybe AsyncException` pattern cannot be reused.

## Design

### 1. `catchChildSync` — in `Delegation.hs`, no new module

No import cycle (`Worker` imports `Delegation`; not the reverse). Exported from
`Delegation.hs`.

```haskell
catchChildSync :: IO a -> (SomeException -> IO a) -> IO a
catchChildSync act handler =
  act `catch` \e -> case fromException e :: Maybe SomeAsyncException of
    Just _  -> throwIO e     -- Timeout/ThreadKilled: never converted
    Nothing -> handler e
```

Applied at all three sites. The `Worker` handler records into a **separate**
`IORef (Maybe ChildExitReason)`; it must not touch `summaryRef` (finding 2).

### 2. Exit reason — structural, not textual

- `Worker` allocates `stopFanoutDoneRef` (already present) and a new
  `terminalReasonRef`.
- Normal return: `CerCompleted` iff `aeStopFanoutDone` is `True`; otherwise
  classify the returned text with `Loop`'s exported predicates for the five
  non-completion returns.
- `Loop` exports `childStopKind :: Text -> Maybe ChildStopKind` covering max
  turns, truncation, abort, provider error and retry exhausted, so the marker
  text has exactly one definition site.

Rejected with measured churn: `AgentEnv` field (no `Default`; ~48 literal
constructions); `runTurn :: App ()` → `App TurnOutcome` (49 test sites discard
the result and `-Wall` has `-Wunused-do-bind`; verified with GHC).

### 3. Truthful status

`registerCompletedAgentResult` logs the real `crStatus`; `handleInstances`
renders `crExitReason` from `aiResult` (already stored and already used by
`handleStatus`). No `AgentStatus` constructor — that would churn the exhaustive
`\case`s in `Shutdown.hs` and `Agent.hs`.

### 4. Handoff: three defects in one callback

| Defect | Location |
|---|---|
| child registered as its own parent | `Agent.hs:963` |
| completion never appended to the parent's sidecar | `Agent.hs:953-957` vs `:869` |
| parent never woken | `Agent.hs:953-957` vs `:881` |

`smParent` is left alone: `writeHandoffMeta` documents handoffs as top-level
(`Worker.hs:508`, asserted by `WorkerSpec.hs`), and nothing branches on it. The
registry's `aiParentSession` is what `hasRunningChildren` filters.

### 5. Live transcript

`dwdOnEntry :: IO ()` → `SessionId -> IO ()`. Ripple is exactly
`TurnEngine.hs` and `WorkerSpec.hs` (verified by `rg dwdOnEntry`).
`TurnEngine.hs:1311` must read the child's meta for `model`/`createdAt` before
calling `broadcastNewEntries` — that is part of the work unit, not assumed.

### 6. The timeout seam

`runWorker`/`runOne` are `where`-bound inside `runDelegateAsync`/`runDelegate`
(`Delegation.hs:763`, `:571`) and capture `mParentActivity`, `mSem` and the
hooks. DoD #1 requires extracting the timeout-and-catch body into a top-level

```haskell
runChildWithTimeout :: Int -> IO ChildWorkerOutcome -> IO (Maybe ChildWorkerOutcome)
```

and exporting it. The extraction is part of WU-1, not a side effect.

## DoD

1. `runChildWithTimeout` with a microsecond budget returns `Nothing` for a
   worker that outlives it → `CsTimeout`/`CerTimeout`. **Fails today.**
2. A worker whose `runTurn` raises synchronously yields `CerError` — by
   *reason*, not by parsing a summary. **Fails today.**
3. All five non-completion returns yield non-`CerCompleted` reasons.
   **Fails today** for all five.
4. `Timeout` is rethrown at all three catch sites.
5. A timed-out child is not reported as `Stopped` (log line + `handleInstances`).
6. A handoff's `aiParentSession` is the spawning session.
7. A completed handoff's result appears in the parent's transcript.
8. A handoff session's entries are live-broadcast while it runs.
9. A normally-completing worker keeps `CerCompleted`.
10. `make check` green.

## File scope

| File | Change |
|---|---|
| `src/Seal/Agent/Runtime/Delegation.hs` | `catchChildSync`; both catch sites; extract + export `runChildWithTimeout` |
| `src/Seal/Agent/Runtime/Delegation/Worker.hs` | `catchChildSync`; separate reason IORef; structural exit reason; sid-taking hook |
| `src/Seal/Agent/Runtime/Registry.hs` | truthful status + log line |
| `src/Seal/Agent/Loop.hs` | export `childStopKind` alongside the five literals |
| `src/Seal/ISA/Ops/Agent.hs` | handoff parentSid, sidecar append, idle broadcast, wake hook; `handleInstances` reason |
| `src/Seal/Core/TurnEngine.hs` | `dwdOnEntry` wiring |
| `test/.../Delegation/ConcurrentSpec.hs` | seam timeout test; five-way reason taxonomy |
| `test/.../Delegation/WorkerSpec.hs` | hook type; reason not derived from summary |
| `test/.../Runtime/RegistrySpec.hs` | truthful status |
| `test/.../Ops/AgentHandoffSpec.hs` | parentSid, sidecar append, wake hook |

No new modules; no cabal library change; no `RunRecord.hs` edit
(`createRun`/`completeRun` have no `src/` callers).

## Work units

WU-1 seam + `catchChildSync` + three sites · WU-2 structural exit reason ·
WU-3 registry truthfulness · WU-4 handoff callback · WU-5 live broadcast ·
WU-6 `make check`.

## Out of scope (recorded)

- `stopAgent` deletes the registry entry before `killThread`, so a killed child
  produces no outcome.
- `interruptAgent` sets a flag nothing polls; `mkDelegateWorker` discards
  `hooks`. `AGENT_INTERRUPT` cannot interrupt a child.
- `RunRecordRegistry` is never populated; `outcomeForResult`'s success-shaped
  `CsFailed` mapping is dead code.
- `smLastActive` is never bumped after creation.
