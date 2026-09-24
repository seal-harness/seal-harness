# Plan: Make HTTP Send Async + Fix Chat Channel WS Connection

> Issue #198 · Branch `channels/seal-chat-channels-198` · PR #199

## Problem

The new chat channels (`seal-chat-channels` package) don't respond to
messages. Two root causes:

1. **HTTP API is synchronous**: `POST /api/sessions/:id/send` blocks until
   the LLM turn completes, then returns `{"kind":"assistant","response":""}`.
   The new chat channel loop expects the reply to arrive via WS streaming
   events, but the HTTP call blocks the loop thread, so WS events fire
   during the blocked call and are missed.

2. **No WS connection established**: `resolveSession` creates a session but
   never calls `ensureWsConn`. So even if the HTTP call returned
   immediately, there's no WS connection to receive streaming events.

3. **`handleNewSession` bug**: creates a local `wsConns` TVar instead of
   using the loop's shared one, so WS connections are lost immediately.

## Solution

### Part 1: Server — make `POST /api/sessions/:id/send` async for plain turns

**File:** `src/Seal/Gateway/Send.hs`

In `handleSend`, for `Right (Plain t)`:
- Fork `plainTurn` + auto-tab + broadcast in a background thread
- Return `SendAssistant` immediately

Slash commands remain synchronous (they return transient output in the
response body). The web frontend already handles `kind:"assistant"`
correctly — it clears the optimistic spinner and receives the reply via
WS events.

**Test:** `SendSpec` — verify `handleSend` for `Plain` returns immediately
(mock the turn to sleep and verify the HTTP response arrives before the
turn completes).

### Part 2: Chat channel — establish WS connection + handle streaming

**File:** `src-chat-channels/Seal/Channels/Chat/Loop.hs`

1. **Thread `wsConns` through `resolveSession` and `sendPlain`**: currently
   `resolveSession` doesn't have access to the `wsConns` TVar. Pass it
   through so a WS connection is established when a new session is created.

2. **`resolveSession`**: after creating a new session via `httpNewSession`,
   call `ensureWsConn` to establish the WS connection and focus it on the
   new session.

3. **`sendPlain`**: after `httpSend` returns `SendAssistant`, the WS event
   handler receives `entry-update`/`entry`/`activity` events and
   creates/edits/finalizes platform messages. No need to fetch the
   transcript — the WS events deliver the reply.

4. **Fix `handleNewSession`**: use the loop's `wsConns` TVar instead of
   creating a new one.

**Test:** `LoopSpec` — mock WS server + mock channel, verify:
- A WS connection is established on first message
- `entry-update` events create/edit platform messages
- `entry` events finalize platform messages
- `activity idle` events finalize any in-progress bubble

### Part 3: Verify no regressions

- `make check` green
- Web frontend still works (async HTTP send is transparent — the response
  is the same `{"kind":"assistant","response":""}`, just faster)
- Old chat channels (when `implementation = "old"`) still work (unchanged)

## Work Units

### WU-1: Make `handleSend` async for plain turns (server)

**Files:**
- `src/Seal/Gateway/Send.hs` — fork `plainTurn` for `Plain` route
- `test/Seal/Gateway/SendSpec.hs` — test async return

**DoD:**
- [ ] `handleSend` for `Plain` returns `SendAssistant` without waiting for the turn
- [ ] The turn runs in a background thread (auto-tab + broadcast after completion)
- [ ] Slash commands remain synchronous
- [ ] `make check` green

### WU-2: Fix chat channel WS connection + reply delivery

**Files:**
- `src-chat-channels/Seal/Channels/Chat/Loop.hs` — thread `wsConns`, fix `resolveSession`, `sendPlain`, `handleNewSession`
- `test/Seal/Channels/Chat/LoopSpec.hs` — WS connection + streaming tests

**DoD:**
- [ ] `resolveSession` establishes a WS connection for new sessions
- [ ] `sendPlain` works with async HTTP (reply arrives via WS events)
- [ ] `handleNewSession` uses the loop's shared `wsConns` TVar
- [ ] WS event handler creates/edits/finalizes platform messages
- [ ] `make check` green

## Dependencies

```
WU-1 (async HTTP) ──→ WU-2 (chat channel WS fix)
```

WU-2 depends on WU-1 because the chat channel's `sendPlain` expects the
HTTP call to return immediately (async). Without WU-1, the HTTP call
blocks and WS events are missed.