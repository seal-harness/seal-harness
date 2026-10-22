# Follow-on: Surfacing WebSocket Connection Issues in the Web UI

**Status**: Proposed (ready to implement)
**Created**: 2026-10-21
**Follows**: [#276 — serve the WebSocket stream on the HTTP port](https://github.com/seal-harness/seal-harness/pull/276) (merged as `061b6fe`)
**Tracking issue**: [#275](https://github.com/seal-harness/seal-harness/issues/275)

## Why this document exists

PR #276 fixed the *cause* of the reported bug — a WS port conflict that
silently killed the stream while HTTP kept serving — by serving the
WebSocket stream from the same Warp listener as the HTTP API. One port,
one bind, no second listener to collide with.

It also made the backend honest: a bind failure is now logged at `Error`
and published in `/api/health` as `wsStatus` / `wsMessage`.

**What it did not do is make the failure visible to the person using the
web UI.** The `/api/health` fields are correct but nothing consumes them.
The user-facing symptom is still "the transcript silently stops updating
and a hard refresh fixes it" — the same confusing experience that prompted
the original investigation.

This document describes the four remaining gaps, in the order they should
be closed.

## The core problem

Three of the four gaps share one root cause: **the web UI has exactly one
path for transcript data, and it is the WebSocket.** The sidebar already
knows how to degrade (it polls `/api/lists` over HTTP every 3s when the
WS `lists` frame never arrives) but the transcript does not.

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

### Test cases

- The banner appears when the stream status leaves `live`.
- The banner is absent while `live`.
- The banner shows `lastError` text when one is set.
- The banner does not block transcript interaction (it is not a modal).

---

## Task 3 — Give the transcript an HTTP polling fallback

**Priority**: P1 — this is the difference between "degraded" and
"broken".
**Size**: Medium.
**Depends on**: Task 1 (polling is a fallback for a WS that cannot be
re-established, not a substitute for fixing reconnects).

### Problem

The sidebar degrades gracefully; the transcript does not. `useListsPoll`
polls `/api/lists` every 3s when the WS `lists` frame never arrives.
`useTranscriptStream` has **no** polling path at all — `grep -c
'setInterval\|POLL' frontend/src/hooks/useTranscriptStream.ts` returns
`0`.

So when the WS is down, the transcript is frozen at whatever the last
HTTP seed returned.

### Change

Mirror the sidebar's pattern:

- When the stream is not `live`, poll
  `GET /api/sessions/:id/transcript?limit=50` on an interval and merge
  the result with `reconcileEntries` (the merge helper already exists and
  is idempotent by entry id).
- Stop polling as soon as the stream returns to `live` — the WS tail
  takes over.
- Poll only for the focused session, and only when the transcript view is
  actually mounted.

Reuse the existing `reconcileEntries` merge (it is already used for the
HTTP seed) and the existing `TranscriptDataCache`, so the fallback does
not introduce a second source of truth.

### Test cases

- With the WS down, the transcript gains new entries via polling.
- Polling stops when the stream returns to `live`.
- The HTTP-poll and WS-tail paths do not duplicate entries (dedup by id
  is already handled by `reconcileEntries`).
- Polling does not run for a session that is not focused.

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

Today this is masked: the WS tail delivers the entry anyway. It stops
being masked the moment Task 3 introduces HTTP polling — the poll would
be doing the work the re-seed was supposed to do, one second too early.

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

### Test cases

- A send that produces entries does not trigger an immediate empty
  re-seed.
- The transcript still shows the sent message and the reply.
- With the WS down (Task 3's fallback active), the transcript still
  converges.

---

## Suggested sequencing

| # | Task | Priority | Depends on | Size |
|---|------|----------|------------|------|
| 1 | Reconnect on socket death | P1 | — | Small |
| 2 | Connection state in the UI | P1 | — | Small–medium |
| 3 | Transcript HTTP polling fallback | P1 | 1 | Medium |
| 4 | Fix the POST /send re-seed race | P2 | — | Small |

Tasks 1 and 2 are independent of each other and can be done in either
order. Task 3 should follow Task 1 so that the polling fallback is a
safety net for a genuinely dead WS rather than the primary mechanism.
Task 4 should land with or shortly after Task 3, since Task 3 makes the
re-seed's timing bug user-visible.

## Out of scope

- **Server-side WS metrics or a live-connection count.** The backend
  already reports its own liveness accurately via `/api/health`; a
  richer endpoint is not needed for these fixes.
- **Changing the WS wire protocol.** The current protocol works; the
  gaps are all in the client's handling of a dead socket and in the
  absence of a fallback.
- **Retrying the HTTP transcript fetch aggressively.** The fallback poll
  should be gentle (the sidebar's 3s interval is a reasonable precedent).

## References

- `frontend/src/lib/streamClient.ts` — the WS client; `sock.onerror`
  (line ~233), `handleClose`, `scheduleReconnect`, `discoverStreamUrl`
- `frontend/src/hooks/useTranscriptStream.ts` — the transcript hook;
  `reconcileEntries` merge, the HTTP seed effect
- `frontend/src/hooks/useApi.ts` — `useListsPoll` (the sidebar's polling
  fallback, the pattern to mirror), `useSendMessage`'s `onComplete`
- `src/Seal/Gateway/API.hs` — the `/api/health` handler that publishes
  `wsStatus` / `wsMessage`
- `src/Seal/Gateway/Stream.hs` — the WS middleware and `StreamHealth`
- `docs/plans/single-port-websocket-plan.md` — the merged single-port work
