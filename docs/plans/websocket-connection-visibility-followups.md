# Follow-on: Surfacing WebSocket Connection Issues in the Web UI

**Status**: Proposed (ready to implement)
**Created**: 2026-10-21
**Follows**: [#276 — serve the WebSocket stream on the HTTP port](https://github.com/seal-harness/seal-harness/pull/276) (merged as `061b6fe`)
**Tracking issue**: [#275](https://github.com/seal-harness/seal-harness/issues/275)

## Why this document exists

PR #276 fixed the *cause* of the reported bug — a WS port conflict that
silently killed the stream while HTTP kept serving — by serving the
WebSocket stream from the same Warp listener as the HTTP API. One port,
one bind, no second listener to collide with. It also made the backend
honest: a bind failure is now logged at `Error` and published in
`/api/health` as `wsStatus` / `wsMessage`.

**What it did not do is make the failure visible to the person using the
web UI.** The `/api/health` fields are correct but nothing consumes them.
The user-facing symptom is still "the transcript silently stops updating
and a hard refresh fixes it" — the same confusing experience that prompted
the original investigation.

This document describes the remaining work, in the order it should be
closed.

## The core problem

**The transcript's only data path is the WebSocket.** The sidebar already
knows how to degrade — it polls `/api/lists` over HTTP every 3s when the
WS `lists` frame never arrives — but the transcript has no such path.

That asymmetry is what made the original bug read as *intermittent*: the
tab list stayed live while the transcript was frozen, so it looked like a
transient glitch rather than a dead connection.

### Evidence: the reconnect never happens

Against a port that is not a WebSocket server, the browser fires `onerror`
but never `onclose`, and `readyState` stays `CONNECTING` forever.
`frontend/src/lib/streamClient.ts:233` currently reads:

```ts
sock.onerror = () => {
  // onerror always precedes onclose; we let close handle the bookkeeping.
}
```

That assumption is only valid when `onclose` is guaranteed. When it is
not, `handleClose` never runs, so `scheduleReconnect()` never runs and
**no reconnect is ever attempted** — the client sits in `connecting`
forever. Measured against a non-WS port: `onerror` at t≈7.8s, then
nothing, with `reconnectAttempt = 0` after 25s.

### Evidence: the health data is published but never read

`/api/health` now returns the real state:

```json
{ "status": "ok", "wsPort": 9090, "wsStatus": "up",
  "wsMessage": "WebSocket stream server listening on port 9090" }
```

`wsStatus` is one of `up` | `failed` | `down` | `starting`. No frontend
code reads it — the WS client only discovers the *port*, via
`discoverStreamUrl()` in `frontend/src/lib/streamClient.ts`.

---

## Decision: no HTTP polling fallback for the transcript (yet)

**HTTP polling for the transcript is explicitly deferred.** It is a
reasonable future hardening — see [Deferred work](#deferred-work) — but it
is not needed to make the transcript correct, because **the `since`-based
replay already recovers everything missed while disconnected.**

Verified against a live gateway: with the socket closed, a message sent
while disconnected, then reconnected with `since=<last entry id>`, the
server replayed **every** entry produced during the outage:

```
--- closing WS, then sending msg2 while disconnected ---
on-disk ids now: ["0","1","3","4","6","7","9","10","12","13","14"]

--- reconnecting with since=0 ---
  <- entry id=1 … id=14
  <- replay-end last="14"

ids missed while disconnected: ["1","3","4","6","7","9","10","12","13","14"]
of those, RECOVERED by reconnect: ["1","3","4","6","7","9","10","12","13","14"]
```

**100% recovered.** So the correct fix is to make the reconnect actually
happen (Task 1) — after which the transcript is correct again, with no
polling and no lost content. Polling would only paper over a reconnect
that never fires.

This also means the transcript is **stale but not wrong** during an
outage: entries that arrive while disconnected are missing from the view
until the reconnect, at which point they are replayed in full. The UI must
therefore say *"these updates are not arriving yet"* rather than implying
the transcript is up to date.

---

## Task 1 — Make the frontend reconnect when the socket dies

**Priority**: P1 — this is the gap that leaves the UI permanently stuck.
**Size**: Small (one file, plus tests).

### Problem

`onerror` is a no-op that assumes `onclose` follows. When it does not, the
client never retries.

### Change

Treat a terminal `onerror` as a failure. Two complementary pieces:

1. **`onerror` should schedule a reconnect** if the socket has not
   already closed. Guard against double-scheduling: `handleClose` also
   calls `scheduleReconnect()`, and a naive implementation would double the
   backoff. `scheduleReconnect` (line ~404) currently does **not** clear a
   pending timer, so two calls in quick succession would leave two timers
   live and reconnect twice. Make it idempotent (clear any pending timer
   first) and have both paths funnel through it.

2. **Add a connect deadline.** A socket that has not reached `OPEN`
   within a bounded window (the same 90s the heartbeat watchdog already
   uses) is dead. Without this, the `onerror`-without-`onclose` case can
   still wedge if the browser never fires `onerror` either. There is
   currently no `readyState === CONNECTING` handling anywhere in the
   client (the only `readyState` checks are for `OPEN`).

Note that `handleClose` already does the right bookkeeping
(`this.ws = null`, `setStatus('reconnecting')`, `scheduleReconnect()`);
the fix is to make sure it always *runs*.

### Test cases

- `onerror` without a subsequent `onclose` results in a reconnect
  attempt (assert `reconnectAttempt` advances and a timer is scheduled).
- `onerror` followed by `onclose` does not schedule two reconnects.
- A socket that stays `CONNECTING` past the deadline is closed and
  retried.
- Backoff still grows as expected (no thundering herd on a dead server).
- **Recovery**: after a reconnect, entries produced during the outage are
  delivered via the `since` replay (this is the property verified above;
  it deserves a regression test).

---

## Task 2 — Surface the connection state in the UI

**Priority**: P1 — this is what turns "silently broken" into "visibly
broken".
**Size**: Small–medium (one component + the WS client).

### Problem

Even with a working reconnect, a user whose WS is down sees a transcript
that quietly stops updating. Nothing in the UI says so. `useTranscriptStream`
exposes `status` and `lastError`, but **no component subscribes to
`onStatusChange`** — the state is computed and then dropped on the floor.

### Change

Add a visible connection indicator to the chat area:

- When `status` is not `live`, show a compact, non-blocking banner:
  "Live updates disconnected — reconnecting" (and, once the reconnect
  ladder gives up, "Live updates unavailable. Reload to reconnect.").
- Surface `lastError` when present. It already carries useful detail
  (`connection closed (code 1006)`, `heartbeat timeout — connection
  appears dead`).
- Keep it non-modal: the transcript must remain readable (the HTTP seed
  still works), because the user may be reading history while the live
  tail is down.

Task 3 escalates this to a modal once retries are exhausted.

### Test cases

- The banner appears when the stream status leaves `live`.
- The banner is absent while `live`.
- The banner shows `lastError` text when one is set.
- The banner does not block transcript interaction (it is not a modal).

---

## Task 3 — Modal alert when the WebSocket cannot reconnect

**Priority**: P1 — the terminal state of the same failure, and the one
that must not be silent.
**Size**: Small–medium (one component + the WS client).
**Depends on**: Task 1 (there must be retries to exhaust).

### Problem

Task 2's banner is deliberately non-modal, because most disconnects are
brief and self-healing. But a *persistent* failure — the gateway is down,
or the port is wrong — leaves the transcript permanently frozen with only a
small dismissible banner. A user who does not notice the banner may
believe the agent has stopped working, and may sit waiting for a reply
that is already on disk.

The reconnect ladder backs off to a 5s cap and never gives up
(`RECONNECT_MAX_MS = 5000`, no attempt cap). So "the connection is not
coming back" is a real, reachable state that currently has no
representation in the UI at all.

### Change

Escalate to a **modal** once the client has failed to reconnect a set
number of times.

- **Trigger**: after N consecutive failed connection attempts. The
  existing `reconnectAttempt` counter already tracks this and is reset to
  0 on any successful message (line ~291) — reuse it rather than adding
  a second counter. Suggested N: **10** attempts. With the current
  backoff (250ms → 5s), 10 attempts is roughly 30–40s of trying: long
  enough to ride out a brief restart, short enough that a user waiting on
  a reply is not left staring at a spinner for minutes.
- **Content**: state plainly that live updates are unavailable and that
  the transcript shown may be stale. Include `lastError` when set.
  Something like: *"Live updates unavailable. The transcript may be out
  of date. Check that the gateway is running, then reconnect."*
- **Actions**:
  - **Reconnect now** — force an immediate reconnection attempt rather
    than waiting out the current backoff.
  - **Dismiss** — close the modal but keep the background retry ladder
    running. The transcript stays visible and stale; if a reconnect later
    succeeds, the missed entries are replayed and the transcript catches
    up automatically.
- **Behaviour**: the modal must not block the transcript from being read
  or the composer from being used. The agent keeps running server-side
  regardless of the WS state, and a user can still send messages.
- **Recovery**: when a reconnect succeeds, the modal closes automatically
  and the banner returns to its non-modal state. Because the reconnect
  sends `since`, the entries missed during the outage are replayed — the
  user sees the transcript catch up rather than silently jumping.

### Test cases

- The modal does not appear before N failed attempts.
- The modal appears at attempt N, showing `lastError` when set.
- "Reconnect now" triggers an immediate connection attempt.
- "Dismiss" closes the modal and the background retry ladder continues.
- The modal closes automatically when a reconnect succeeds.
- The transcript remains readable and the composer usable while the modal
  is open.
- **Recovery**: after a successful reconnect, entries produced during the
  outage appear in the transcript (via the `since` replay).

---

## Task 4 — Fix the POST /send re-seed that races the turn

**Priority**: P2 — a correctness wart, not a freeze.
**Size**: Small.

### Problem

`POST /api/sessions/:id/send` returns **immediately** with
`{"kind":"assistant"}`; the turn itself runs asynchronously. The frontend's
`useSendMessage` calls `onComplete()` in its `finally` block, which
triggers `refresh()` → an HTTP re-seed.

That re-seed fires ~3ms after the POST returns, but the turn's first
entry does not land on disk until ~1000ms later. Measured against a live
gateway:

```
POST /send returned after 3ms
>> RE-SEED AT POST-RETURN (t+4ms): 0 entries    <- the re-seed sees nothing
>> t+1033ms: 1 entries                            <- the turn's entry finally lands
```

The re-seed therefore **always** races the turn and sees an empty
transcript. It is a wasted request that contributes nothing.

### Change

Re-seed **after** the turn completes, not when the POST returns. Options:

- **Preferred**: have the backend include a `turn_id`/completion signal.
  The WS `activity` frame already carries a `harness-status` transition to
  `idle` — the frontend could re-seed on that transition.
- **Simpler**: drop the re-seed entirely. The WS tail is the source of
  truth for new entries; the re-seed exists only as a safety net for the
  race, and the race is precisely what it loses.

Do not simply delay the re-seed by a fixed interval — that trades a
deterministic bug for a timing-dependent one.

Note this is *not* the same as the deferred HTTP polling fallback: this
is a one-shot re-seed triggered by turn completion, not a recurring poll.

### Test cases

- A send that produces entries does not trigger an immediate empty
  re-seed.
- The transcript still shows the sent message and the reply.
- With the WS down, the transcript still converges once the connection is
  restored (via the `since` replay).

---

## Suggested sequencing

| # | Task | Priority | Depends on | Size |
|---|------|----------|------------|------|
| 1 | Reconnect on socket death | P1 | — | Small |
| 2 | Connection state in the UI | P1 | — | Small–medium |
| 3 | Modal alert when reconnects are exhausted | P1 | 1 | Small–medium |
| 4 | Fix the POST /send re-seed race | P2 | — | Small |

Tasks 1 and 2 are independent and can be done in either order. Task 3
needs Task 1 (there must be retries to exhaust) and benefits from Task 2
(the banner is the transient state, the modal the terminal one). Task 4
is independent of all three.

**Task 1 is the load-bearing one.** It is what makes the transcript
correct again after an outage; tasks 2 and 3 are what make the outage
visible while it happens.

## Deferred work

- **HTTP polling fallback for the transcript.** Explicitly not doing this
  now. The `since` replay recovers 100% of the entries missed during an
  outage (verified above), so polling would be redundant once reconnects
  work. Worth revisiting if a future change breaks the replay path, or if
  the UX requirement becomes "the transcript must be current even while
  the WS is down" — in which case the sidebar's `useListsPoll` pattern
  (3s interval) is the precedent to mirror.
- **Server-side WS metrics or a live-connection count.** The backend
  already reports its own liveness accurately via `/api/health`; a richer
  endpoint is not needed for these fixes.
- **Changing the WS wire protocol.** The current protocol works; the
  gaps are all in the client's handling of a dead socket and in the
  absence of user-visible state.

## References

- `frontend/src/lib/streamClient.ts` — the WS client; `sock.onerror`
  (line ~233), `handleClose` (~383), `scheduleReconnect` (~404),
  `discoverStreamUrl` (~467), the backoff constants (~36)
- `frontend/src/hooks/useTranscriptStream.ts` — the transcript hook;
  `reconcileEntries` merge (~161), the HTTP seed effect
- `frontend/src/hooks/useApi.ts` — `useSendMessage`'s `onComplete` (~371),
  `useListsPoll` (~231), `POLL_INTERVAL` (~26)
- `src/Seal/Gateway/API.hs` — the `/api/health` handler (~176) that
  publishes `wsStatus` / `wsMessage`
- `src/Seal/Gateway/Stream.hs` — the WS middleware, `StreamHealth`, and
  the `since` replay that makes recovery complete
- `docs/plans/single-port-websocket-plan.md` — the merged single-port work
