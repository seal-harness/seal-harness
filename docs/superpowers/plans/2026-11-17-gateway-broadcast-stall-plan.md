# Gateway broadcast stall — proven fix + targeted diagnostics, then decide

Status: v6 — plan review gate **APPROVED**
Gate result: Feasibility PASS · Completeness PASS · Scope & Alignment PASS
(6 revisions; 18 findings raised, all verified against the code and
resolved. Four were errors in my own earlier analysis.)
**Not yet implemented — awaiting operator approval of §11.**
Supersedes v3 (rejected on feasibility: 1 BLOCKING, 4 WARNING — see §10)
and v2 (rejected on scope), v1 (rejected on scope + completeness)

v5/v6 corrections applied after review:
- **Unit 2a redesigned (was BLOCKING).** `HttpClient.hs` lives in the
  `seal-chat-channels` stanza (`seal-harness.cabal:78-113`), whose
  `build-depends` (`:93-113`) contain **no katip**, and which **cannot**
  import `Seal.Logging.Global` — that module is in the upper library
  (`:329`), which depends on `seal-chat-channels` (`:399`): a circular
  import. So "log the exception via katip" is not implementable as
  scoped, and `hPutStrLn stderr` would never reach `seal.log` (§1.2's
  evidence base). 2a is now **deferred** with the reason recorded (§8.3)
  rather than specified as impossible work.
- **Unit 1's race tests rewritten — they were vacuous.** An earlier
  revision had every send succeed, but the write-back at `:177` runs only
  inside `when (length live < length subs)` (`:174`), i.e. only when a
  send **failed**. With all sends succeeding the guard is false, no write
  happens, and the resurrection test passes on buggy code. The tests now
  include a subscriber whose send **throws** to arm the guard (verified
  by tracing `live`/`subs` both ways).
- `Stream.hs:68-69` import list added to Unit 1's file scope
  (`unsubscribe` must be bound there, not only exported).
- **The `finally` must start at `:237` (`subscribe`), not at `:251`.**
  Between them sit the connect log and `broadcastListsSnapshot` (`:243`),
  which can throw — scoping `finally` to `:251` would still leak.
- `StreamSpec` integration assertion given a bounded poll (unsubscribe
  fires server-side, asynchronously to the client's close).
- Line numbers re-anchored: snapshot read `:168`, `filterM` `:169`,
  guard `:174`, `subscribe` `:131-137`, per-send `timeout` `:192`.
- Recorded that an unsubscribed subscriber may still receive **one**
  in-flight event (the `:168` snapshot predates the unsubscribe).

Origin: operator report — Signal `/new -r` returned
`new session failed: HTTP request failed`; a web "Start a new tab"
submitted, hung, and silently returned to the form; a `seal serve`
restart made both work again.

Operator's instruction: **"instrument first, get a repro, then fix."**
This plan departs from the letter of that instruction in one specific,
justified way — Unit 1 is a defect proven by code inspection alone, so it
does not need a reproduction — and stays faithful to it everywhere else:
Unit 3 (the stall fix proper) is contingent on observed evidence (§6).
The departure is flagged for operator approval in §11.

## 1. Established facts

### 1.1 The user-visible symptom is a discarded exception

`new session failed: HTTP request failed` has exactly one producer:
`src-chat-channels/Seal/Channels/Chat/HttpClient.hs:399`

```haskell
eResp <- try (httpLbs req2 mgr)
case eResp of
  Left _ -> pure (Left "HTTP request failed")
```

The `HttpException` is thrown away; `Loop.hs:1353` only prefixes the
string. So the user saw a transport failure with the cause erased — and
we lost the single cheapest datum (timeout vs. reset). Fixing this is
**deferred** (§8.3) — it is blocked by a library-stanza boundary, not by
difficulty — so this plan diagnoses the stall from the gateway side instead.

### 1.2 A blocked handler is unobservable at the default log level

`requestTimingMiddlewareWith` (`Server.hs:101-113`) logs only inside the
`respond` continuation, so a handler that never produces a `Response`
logs nothing. There is no request-start log anywhere in `src/Seal/Gateway/`
(grep `requestStart|in-flight|inflight` finds only unrelated in-flight-turn
comments).

Concretely: `~/.seal/state/sessions/20261117-125326-018/session.json`
exists with `created_at: 2026-11-17T12:53:26.01844Z`, `channel: "web"`,
yet `seal.log` contains no `HTTP POST /api/sessions/new` line for it, while
the same process answered `GET /api/tabs` and `GET /api/auth/status` at
0 ms seconds later. One handler blocked; the log recorded nothing.

**The default log level is `Info`** (`Config.hs:36`), and both the stderr
and file scribes filter on it (`Logger.hs:74-76`, `:88-90`,
`permitItem sev`). Any diagnostic specified at Debug is therefore inert
unless the operator restarts with `--log-level debug`
(`AppMain.hs:91-111` — supported for `serve`, hoisted by
`reorderGlobalArgs`). v2 missed this and specified its decisive instrument
at Debug. Unit 2 therefore puts the load-bearing diagnostics at
**Info/Warning**, so they work in the default configuration.

### 1.3 Defect A: nothing ever unsubscribes (proven, no repro needed)

`Stream.hs` `acceptConn` calls `subscribe` (`:237`); on peer loss the reader
loop is `catch`-wrapped (`:271`) and `concurrently_` finishes. Nothing
removes the subscriber. `StreamBroker`'s export list (`:12-33`) contains
`subscribe` and `updateSubscriberSession` but **no `unsubscribe`**
(verified: zero occurrences).

Dead subscribers are reaped only opportunistically by a later broadcast
that tries to send: ~ms if the send *raises* (clean FIN), the full 2 s if
it *blocks* (half-open socket, backgrounded tab under backpressure).

Measured on the process that died (PID 55925, ~22 h uptime):
**15 `[ws] connected`, 0 disconnect lines** (no disconnect is logged at all).

This defect is established by reading the code. It does not depend on
reproducing the stall.

### 1.4 Defect B: the subscriber list write-back races (proven, no repro needed)

`broadcast` reads a snapshot and later writes the **whole list** back:

```haskell
subs <- readTVarIO (sbSubs broker)              -- StreamBroker.hs:169
...
atomically $ writeTVar (sbSubs broker) live     -- :177
```

Any `subscribe` (`:131-137`, `writeTVar ... subs <> [...]`) or
`unsubscribe` completing between `:168` and `:177` is clobbered: a live
subscriber silently dropped, or a removed one resurrected.

**This makes the obvious fix unsafe.** Adding `unsubscribe` on top of the
whole-list write-back would resurrect a subscriber whose connection is
gone — permanently, because it can never unsubscribe again. Defect B must
be fixed *with* Defect A, not after it. Unit 1 does both.

### 1.5 The stall: a hypothesis, not an established fact

The stall mechanism is plausible but **not observed** (§1.2 — the path logs
nothing). `broadcast` fans out serially with a 2 s per-subscriber timeout:

```haskell
live <- filterM (deliverTo event) subs      -- sequential, :176
sent <- timeout sendTimeoutMicros (...)     -- 2_000_000 µs, :204-207
```

Between `newSession` and `jsonOk` (`API.hs:1368-1372`) sits
`triggerBroadcast` (`:1149-1153`) → `broadcastListsSnapshot`
(`Broadcast.hs:56-65`) → `broadcast`. That is one candidate stage; others
(`loadRuntimeConfig`, `resolveDefaultAgent`, `newSession`) log nothing
either, so the evidence cannot distinguish them.

Timeout facts, verified from upstream docs and this repo:

| Boundary | Value | Source |
|---|---|---|
| frontend `createTab` abort | 20 s | `useApi.ts:1014` |
| Signal client (http-client default) | 30 s | `responseTimeoutDefault` = 30 s; `Serve.hs:882` sets no `managerResponseTimeout` |
| per-subscriber send timeout | 2 s | `StreamBroker.hs:204-207` |
| Warp `setTimeout` | **not an application timeout** | Warp docs: "not applied to application code, only network progress" |

15 stuck subscribers × 2 s = 30 s; 10 × 2 s = 20 s — one mechanism, both
observed client timeouts. **Caveat:** a cleanly-closed socket raises
immediately (~ms), so the stuck count is bounded by 15, not equal to it.
Whether enough were genuinely half-open is unknown.

## 2. Limitations

1. The stall was never directly observed (§1.2).
2. Which stage blocked is unknown (§1.5).
3. Whether stuck subscribers were half-open (2 s) or cleanly closed (~ms)
   is unknown, so the arithmetic in §1.5 bounds the effect without
   proving it.
4. Deploying diagnostics requires restarting `seal serve`, and
   `newStreamBroker` starts with an empty subscriber list
   (`StreamBroker.hs:82-85`, created at `Serve.hs:507`) — so **any restart
   resets the accumulated leak** that is the suspected trigger. Passive
   "wait for it to recur" is therefore not a viable repro strategy; §6
   specifies forcing instead. (v2 got this wrong.)
5. One `seal.log` was available; the failing process is gone, so no
   post-hoc profiling is possible.
6. `20261117-125326-018` may be a stranded session. Not investigated (§7).

## 3. Structure

Three units. Unit 1 and Unit 2 ship together in one small PR; Unit 3 is
contingent on observed evidence.

| Unit | Content | Gate |
|---|---|---|
| 1 | Race-safe removal + `unsubscribe` (Defects A and B) | Own tests (proven by inspection; no repro needed) |
| 2 | Broadcast instrumentation at Warning (2b; 2a deferred — §8.3) | Own tests |
| 3 | Concurrent fan-out (the stall fix proper) | **Blocked on §6.2 evidence** |

## 4. Unit 1 — race-safe removal

**Test first.** All tests use an `MVar` to sequence the race
deterministically — no polling, no timing luck.

1. `unsubscribe` removes the subscriber: count 1 → unsubscribe → count 0,
   and a later `broadcast` invokes that send zero times.

2. **Lost-update / resurrection** (the Defect-B test).

   This test needs **three** subscribers, and the reason is the whole
   point. The write-back at `:177` runs only inside
   `when (length live < length subs)` (`:174`) — i.e. only when some
   send **failed**. So a resurrection test in which every send succeeds
   can never exercise the bug at all: the guard is false, no write
   happens, and the subscriber stays correctly gone. It would pass
   vacuously on buggy code.

   Therefore the fan-out must contain a **failing subscriber** (its send
   throws ⇒ `deliverTo` catches at `:197` and returns `False` ⇒ excluded
   from `live` ⇒ guard true ⇒ write-back runs). B must be in `live`
   (its send succeeds) and be unsubscribed *during* the fan-out, so the
   stale snapshot still contains it and the write-back puts it back.

   Sequence (order matters — fan-out is sequential over the `:168`
   snapshot):
   - subscribe **B** (send succeeds; later unsubscribed mid-flight)
   - subscribe **F** (send throws — this is what arms the write-back)
   - subscribe **A** (send blocks on an `MVar`, giving the main thread a
     deterministic window)
   - fork `broadcast`
   - wait until A's send has entered (an `MVar`/`TMVar` signal — never a
     sleep)
   - `unsubscribe` B from the main thread
   - release A; join the fork
   - assert B is **absent** afterwards, and that a subsequent `broadcast`
     invokes B's send zero further times

   Against the current code: `live = [B, A]` (F threw), `subs = [B, F, A]`
   ⇒ guard true ⇒ `writeTVar live` writes **B back**. Test fails, as the
   DoD requires. Against the fixed removal-by-identity code: only F is
   removed, so B stays gone.

3. `subscribe` during a blocked fan-out is preserved. **Same
   requirement:** a failing subscriber must be present, or the `:174`
   guard skips the write-back and the test proves nothing on current
   code. Sequence: F throws + A blocks on an `MVar`; while blocked,
   `subscribe` C; release A; assert C survived (the buggy whole-list
   write-back would drop it, since C is absent from the stale `subs`
   snapshot and therefore absent from `live`).

4. `unsubscribe` is idempotent.

Changes:

1. Add `unsubscribe :: StreamBroker -> TVar SessionId -> IO ()`, removing
   by **identity** (`subSessionRef`), idempotent, one STM transaction.
2. Change `broadcast`'s write-back (`:177`) from `writeTVar ... live` to
   removing exactly the identities that failed (`modifyTVar'` +
   `filter`), so it composes commutatively with concurrent
   `subscribe`/`unsubscribe` and cannot resurrect anyone.

   **Accepted artifact (must be asserted, not left implicit):** a
   subscriber that unsubscribes while a fan-out is in flight may still
   receive that **one** event, because `subs` was snapshotted at `:168`
   before the unsubscribe. Acceptable — the connection is leaving and one
   stray event is harmless — but the bound must be pinned: Unit 1 test 2
   asserts the unsubscribed subscriber is gone once the fan-out completes
   and that no *subsequent* `broadcast` reaches it.

3. In `Stream.hs` `acceptConn`, wrap in `finally` calling `unsubscribe`.
   **The `finally` must start at the `subscribe` call (`:237`), not at the
   `withPingThread` block (`:251-272`).** `subscribe` is at `:237`, and
   between it and `:251` sit the connect log (`:238`) and
   `broadcastListsSnapshot` (`:243` — which walks every subscriber and can
   throw). A `finally` scoped to `:251-272` would leak the subscriber if
   any of that throws. Correct shape:

   ```haskell
   subSessionRef <- subscribe broker defaultSid sendEvent closeConn
   (do globalLogIO InfoS "..."
       broadcastListsSnapshot ...
       withPingThread ... concurrently_ ...)
     `finally` unsubscribe broker subSessionRef
   ```

   `finally` is not currently imported (`:42` has only
   `SomeException, catch`) and must be added there too.

**File scope (complete):**

- `src/Seal/Gateway/StreamBroker.hs` — add `unsubscribe`; change the
  write-back; extend the export list (`:12-33`).
- `src/Seal/Gateway/Stream.hs` — `finally` import (`:42`) **and** bind
  `unsubscribe` in the explicit import list at `:68-69`, which currently
  reads `( BrokerEvent (..), StreamBroker, subscribe, updateSubscriberSession )`
  and will not compile without it.
- `test/Seal/Gateway/StreamBrokerSpec.hs` — tests 1-4.
- `test/Seal/Gateway/StreamSpec.hs` — the integration test.

No `.cabal` change: `Seal.Gateway.StreamBroker` is already an exposed
module, and `async`/`modifyTVar'` are already available to it.

DoD:

- [ ] Tests 1-4 above land first and fail without the implementation
      (test 2 must fail against the current write-back specifically).
- [ ] **`finally` placement is discriminatingly tested.** A test where
      `subSend` throws is NOT sufficient: that path is already handled by
      `broadcast`'s prune and is already green today
      (`StreamBrokerSpec.hs:131-146` asserts `count shouldBe 1` after a
      throwing subscriber), so it passes even if `finally` were wrongly
      scoped at `:251`. The test must instead make something **between
      `:237` and `:251` throw** — specifically the connect-side work
      (`broadcastListsSnapshot` at `:243`, which the plan identifies as
      throw-capable) — and assert the subscriber count returns to 0.
      With `finally` at the rejected `:251` placement that test fails;
      with the correct `:237` placement it passes. This is the only DoD
      that pins the headline v5 correction, so it must not be softened.
- [ ] Integration: in `StreamSpec`, connect a real client against a real
      broker, assert `subscriberCount` is 1, close the client cleanly from
      the test body, then **poll** `subscriberCount` until 0 with a
      bounded budget (e.g. every 10 ms up to 2 s) and fail on timeout.
      The poll is required, not optional: `unsubscribe` runs server-side
      when `acceptConn`'s body exits (`Stream.hs:251-272`), which is
      asynchronous to the client's `close` — an immediate assertion races.
      *Hazard to respect:* `withStreamServer` (`StreamSpec.hs:53-65`)
      wraps `runClient` and turns `IOException`/`ConnectionException` into
      `pendingWith`, so a disconnect test built naively can report pending
      (green suite) rather than fail. Either assert on broker state from
      outside that wrapper, or do not route the assertion through it.
- [ ] No use of `pendingWith` for any assertion this unit depends on.
- [ ] `make check` green.

## 5. Unit 2 — targeted diagnostics (default-visible)

One item. At **Warning**, so it appears without `--log-level debug`.
`StreamBroker.hs` already imports `globalLogIO` (`:49`) and
`Severity (..)` (`:44`), so no new dependency is needed.

**2b — broadcast instrumentation** (`StreamBroker.hs`). At `broadcast`:
- log a per-send timeout at **Warning**, with the subscriber's session id
  and elapsed ms (today: silent);
- log each prune at **Warning**, with pruned count and remaining count;
- log total fan-out duration at **Warning** when it exceeds 100 ms, with
  subscriber count. Below threshold, silent (a healthy server stays quiet).

**2a — stop discarding the transport error — DEFERRED, not doable as
scoped.** `HttpClient.hs:399` is in the `seal-chat-channels` stanza
(`seal-harness.cabal:78-113`), whose `build-depends` (`:93-113`) have no
`katip`, and it cannot import `Seal.Logging.Global`: that module is in the
upper library (`:329`), which depends on `seal-chat-channels` (`:399`) — a
circular import. The stanza's only logging idiom is `hPutStrLn stderr`
(`Loop.hs:381-382`), which never reaches `seal.log` — the exact
"inert diagnostic" failure mode that got v2 rejected. Doing 2a properly
needs a `katip` dependency on `seal-chat-channels` plus a decision about
how the global logger is wired across stanzas. That is a cross-cutting
change with its own risk, so it is written up as its own issue (§8.3)
rather than smuggled into a diagnostics unit. The information is not
lost: the Signal side is diagnosed from the gateway's own 2b evidence.

2b is content-free (ids, counts, durations — no session text, no event
payloads).

**Deliberately not included** (v2 had these; both were correctly rejected):

- **No request-start logging** (v2's A-2) and no rate limiter. The
  limiter's `N` was undefined, and rate-limiting start lines while
  leaving the completion line unlimited produces unmatched log pairs and
  can suppress the very blocked-handler line it exists to capture.
- **No per-stage timing in `handleSessionNew`** (v2's A-5). It was
  specified at Debug (inert by default, §1.2) and is only needed if Unit 3
  is reached. If §6's evidence points at a non-broadcast stage, A-5 is
  reinstated *then*, against a specific target.
- **No WebSocket disconnect log.** Unit 1 makes disconnect observable by
  *removing* the subscriber; the count is already assertable via
  `subscriberCount`. A log line adds no decision-relevant information.
- **No frontend work.** v2's B-3 (silent `null` in `createTab`, form
  reset with no message) is a real and user-facing defect, but §1.1 of v2
  correctly noted it has no diagnostic value for this bug. It moves to its
  own issue (§8).

DoD (2b only — 2a is deferred, §8.3):

- [ ] 2b: `StreamBrokerSpec` log-capture test (`setGlobalLogger`, per
      `LogRedactionSpec.hs:52-61`) asserts a Warning line on a hung
      subscriber **and** no warning line on a fast one (threshold
      behaviour).
- [ ] 2b: captured log text contains no event payload.
- [ ] 2b: the timeout/prune lines are emitted at a severity that survives
      the default `Info` filter. **Note the trap:** the standard test
      helper `mkCaptureScribe` (`LogRedactionSpec.hs:38-51`) uses
      `permitItem DebugS`, so it captures everything and cannot
      distinguish severity; and `newSealLoggerWithScribe` ignores its
      `Severity` parameter entirely (`Logger.hs:116-119`, parameter named
      `_sev`). The assertion must therefore build a capture scribe with
      `permitItem InfoS` (mirroring the default filter) and assert the
      Warning line still arrives — while a Debug-severity line, if one
      were emitted, would not.
- [ ] `make check` green.

**Cross-file impact (must be in this unit's file scope):** adding any log
line to `requestTimingMiddleware` would break
`test/Seal/Gateway/ServerSpec.hs:264` (`length logs shouldBe 1`) and
`:285-289`. Unit 2 does **not** modify that middleware, so those tests are
untouched — but if 2b's scope later grows to include request-start
logging, those two assertions must be updated in the same change.

**Test-cost note:** the hung-subscriber assertions in 2b are real 2 s
`timeout`s (the production `sendTimeoutMicros`), so `make check`
wall-clock grows by roughly 2 s per such test. Keep the number of
hung-subscriber tests to the minimum that covers the behaviour.

## 6. Reproduction and decision (Unit 3 gate)

### 6.1 Forcing, not waiting

Passive "wait for it to recur" is not viable: restarting `seal serve` to
deploy Units 1-2 resets `sbSubs` to empty (`StreamBroker.hs:82-85`), so the
accumulated state the suspect mechanism needs is gone (§2.4).

Force it instead, with a half-open socket — a WS client that connects and
then stops reading, with the TCP window filled by a large payload.
`SIGSTOP`-ing a browser does **not** work: a small `lists` frame fits in
socket buffers and is accepted.

Note that Unit 1 changes the population dynamics: with `unsubscribe`
working, dead subscribers no longer accumulate. So after Units 1-2 the
stall may simply stop occurring — which is a useful signal, not a
non-result (§6.2).

### 6.2 Decision rule (blocking for Unit 3)

The table must be exhaustive: every outcome routes somewhere, including
"the stall is somewhere else entirely."

| Evidence after Units 1-2 | Action |
|---|---|
| 2b shows fan-out ≥ the client timeout, with send timeouts logged | Implement Unit 3 |
| **Stall recurs and 2b is silent** (no timeouts, no prunes, fan-out < 100 ms) | Broadcast is **exonerated**. Reinstate per-stage timing (§5, A-5) targeted at the stages §1.5 names — `loadRuntimeConfig`, `resolveDefaultAgent`, `newSession` — deploy, and re-run this rule. Do **not** implement Unit 3. |
| Subscriber count inflated, sends *raising* (not blocking), fan-out fast — **and the stall does not recur** | Unit 3 **not** needed; Unit 1 removed the trigger. Close the issue. |
| Stall disappears entirely once `unsubscribe` works | Unit 3 **not** needed. Close the issue; Unit 1 was the fix. |
| Unit 3 shipped and the stall **still** recurs | The hypothesis was wrong. Stop. Re-open the investigation with the A-5 evidence; do not iterate on `broadcast` further. |
| No stall and no diagnosis possible within 2 weeks of normal use | Re-assess with the operator; do **not** fix on hypothesis. |

Two notes on reading the table: "does not recur" and "the evidence pattern"
are **different** outcomes — an inflated count with fast fan-out plus a
recurring stall is the *exoneration* row, not the close-the-issue row. And
§5's A-5 reinstatement is armed by the exoneration row above, so a
silent 2b never leaves an implementer without an instruction.

The "2 weeks" bound is a trigger for a human conversation, not an
automatic action. The operator decides.

## 7. Unit 3 — concurrent fan-out (contingent)

**Test first.** `StreamBrokerSpec`: N = 5 subscribers each
`threadDelay maxBound`; `broadcast` completes in well under N × 2 s
(assert ≤ ~3 s). The existing single-subscriber test (`:177-196`) is the
N = 1 case.

Change: replace sequential `filterM (deliverTo event) subs` with
`mapConcurrently (deliverTo event) subs`. With the existing per-send 2 s
timeout, total wall-clock becomes ~2 s **regardless of subscriber count** —
no budget arithmetic, no skip semantics, no fork. `async` is already a
dependency; `mapConcurrently` is already used at `ListsSnapshot.hs:53-55`.

Deliberately **not** doing:

- **No forking of `triggerBroadcast`.** Unnecessary once fan-out is
  bounded, and it would make `buildListsSnapshot` (one thread per session,
  `ListsSnapshot.hs:53-55` — a known FD-pressure path, hence
  `AppMain.raiseFdLimit`) run unbounded per mutation. With WS live the
  frontend disables REST polling (`App.tsx:205-217`), so a missed `lists`
  frame is unrecoverable until the next mutation.
- **No total-budget / skip mechanism.** It would drop events for healthy
  subscribers, and `replayEntriesSince` (`Stream.hs:305-345`) replays
  transcript entries only — it would not repair a missed `lists` frame.

Tradeoffs: one lightweight thread per subscriber per event, bounded by
`sbCap` (1024, checked in one STM transaction at `:136`) and in practice
in the tens. Two concurrent `broadcast` calls could interleave sends to the
same subscriber; that hazard pre-exists (today's sequential fan-out is not
serialised across concurrent `broadcast` calls either) and is not worsened.

DoD:

- [ ] N-hung-subscribers test lands first and fails on current code.
- [ ] Healthy subscribers still receive the event while a hung one is
      pruned (existing N=1 test generalised).
- [ ] A realistic-count test (e.g. 50 subscribers) asserts bounded
      wall-clock.
- [ ] `make check` green.

## 8. Deferred to their own issues

1. **Frontend failure surfacing.** `createTab` returns silent `null`
   (`useApi.ts:1014-1031`), `createBareSession` has no timeout (`:1042+`),
   `NewTabComposer.tsx:85-88` resets with no message. Real, user-facing,
   unrelated to this bug's diagnosis. Note `NewTabComposer.test.tsx`
   exists, and the only callers are the two composers plus mocks, so the
   fix is narrow.
2. **Stranded sessions.** `handleSessionNew` (`API.hs:1342-1372`) persists
   `session.json` before building the response, unlike `handleTabNew`
   (insert first, then persist). A failure after `newSession` strands a
   tab-less session — possibly `20261117-125326-018`. Whether to keep or
   garbage-collect is a policy decision.
3. **The Signal-side transport error is discarded**
   (`HttpClient.hs:399`). `doRequest` catches `HttpException` and
   collapses it to a fixed string, so a timeout cannot be told from a
   reset — the cheapest reproduction datum, and the literal producer of
   the reported message. Blocked by a stanza boundary, not difficulty:
   `seal-chat-channels` (`seal-harness.cabal:78-113`) has no `katip` in
   `build-depends` (`:93-113`) and cannot import `Seal.Logging.Global`
   (`:329`) without a cycle (`:399` depends on `seal-chat-channels`).
   Preferred fix is the cheap one: return an `Either` that preserves the
   exception and let the **caller** in `Loop.hs` log it via its existing
   `dbg` (which is already `hPutStrLn stderr`, `:381-382`). Own issue.
4. **`buildListsSnapshot` cost** — out of scope unless §6.2 shows it
   matters.

## 9. Rollback and backward compatibility

**Revert unit for Unit 1 is the pair, not the parts.** `unsubscribe` and
the write-back change (§4 steps 1-2) must land and revert **together**:
adding `unsubscribe` on top of the current whole-list write-back would
resurrect subscribers (§1.4), so a partial revert reintroduces precisely
the bug Unit 1 exists to fix. The `finally` in `Stream.hs` (step 3) is
independently revertable — without it the subscriber simply leaks as it
does today.

**Units 2 and 3 are independently revertable.**

- Unit 2 is additive `Warning` log lines in `broadcast`; deleting them
  changes no control flow. Its tests are the only removal cost.
- Unit 3 is a one-line change (`filterM` → `mapConcurrently`) with the
  per-send timeout untouched; reverting restores today's sequential
  behaviour exactly.

**Backward compatibility.** No wire format, JSON shape, or public API
changes. `broadcast`'s semantics stay synchronous (Unit 3 still joins
before returning), so no caller — including `reconcileStaleThinking` and
the chat-channel consumer — observes a behavioural difference beyond
latency.

## 10. What changed across revisions

| Finding (reviewer, verified) | Resolution |
|---|---|
| BLOCKING: A-5 specified at Debug, inert at default `Info` (`Config.hs:36`, `Logger.hs:74-76/88-90`) | A-5 dropped; Unit 2's diagnostics are Info/Warning and a DoD asserts survival of the default filter |
| BLOCKING: proven defects gated behind an unrelated repro; decision rule would *cancel* them | Unit 1 ships now on code-inspection evidence; only Unit 3 is gated |
| WARNING: A-2's undefined-`N` rate limiter, unmatched log pairs | A-2 dropped entirely |
| WARNING: B-3 has no trigger in the decision rule, dies with a cancelled Phase B | Moved to its own issue (§8.1) |
| WARNING: proportionality — five diagnostic items, eight DoD items | Reduced to ONE diagnostic item (2b), Unit 1, and a contingent Unit 3 |
| (own finding) restart resets `sbSubs`, so passive waiting cannot work | §2.4 and §6.1: forcing required |
| (own finding) `ServerSpec.hs:264` breaks if the middleware gains a line | Recorded as a cross-file constraint in Unit 2 |
| BLOCKING (feasibility): 2a unimplementable — stanza has no katip and cannot import `Seal.Logging.Global` (cycle) | §8.3, with the cheap alternative (`Either` + `Loop.hs`'s `dbg`) recorded |
| BLOCKING (completeness): `finally` DoD not discriminating — throwing-send path is already green today (`StreamBrokerSpec.hs:131-146`) | DoD now requires an exception *between* `:237` and `:251` (`broadcastListsSnapshot`), which fails under the rejected `:251` placement |
| BLOCKING (completeness): no rollback section, though §10 previously claimed one existed | §9 added (revert unit = Unit 1's pair; 2 and 3 independent) |
| (own finding) `finally` scoped to `:251` would still leak (`:238`/`:243` can throw) | §4 step 3: `finally` starts at `:237` |
| (own finding) race tests were vacuous (all sends succeeding never fires the `:174` guard) | §4 tests 2-3: a throwing subscriber arms the guard |

Also carried forward from v1's rejections: no fork of `triggerBroadcast`,
no budget/skip mechanism, `unsubscribe` fixed together with the write-back
race, and the `pendingWith` hazard called out.

## 11. Approval needed

Unit 1 is a deliberate departure from "instrument first, get a repro,
then fix": it fixes a defect proven by code inspection without waiting for
a reproduction.

Rationale: the leak (§1.3) and the lost-update race (§1.4) are established
by reading the code, are independent of *which* stage blocked
`POST /api/sessions/new`, and the race must be fixed together with the leak
or the leak fix itself is unsafe. Withholding a proven correctness fix
behind an unrelated reproduction would be the wrong call.

If the operator prefers strict ordering, the alternative is: Unit 2 only,
observe, then Units 1 and 3 together.

**The cost of waiting is worse than "unbounded growth."** `sbCap` bounds
the list at 1024 (`StreamBroker.hs:136`), so the leak does not grow
forever — but past the cap, `subscribe` silently does nothing (`when
(length subs < sbCap broker)`), meaning a **new browser connection is
never added at all**: it receives no `lists` frames, the frontend never
flips `wsLive` (`App.tsx:205-217`), and the tab appears connected while
being inert. A silent cap-exhaustion is a worse failure than a slow
fan-out, and it is the argument for shipping Unit 1 now.

## 12. Verification summary

| Requirement | Verified by |
|---|---|
| Transport error preserved | Deferred (§8.3) — not in this plan |
| Stall measurable at default log level | 2b tests + `permitItem InfoS` DoD |
| Subscribers cannot leak | Unit 1 tests 1, 3, 4 + StreamSpec integration |
| Race cannot resurrect or drop a subscriber | Unit 1 test 2 (MVar-sequenced) |
| **Repro/decision before the stall fix** | §6.2 blocking rule |
| Fan-out bounded if needed | Unit 3 N-hung test |
| No secrets/content in logs | 2b assertions |

Gate: `make check`.
