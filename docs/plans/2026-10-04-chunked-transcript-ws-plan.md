# Implementation Plan: Chunked Transcript Loading via WebSocket
## Issue: #243
## Design: docs/plans/2026-10-04-chunked-transcript-ws-design.md

## Work Units

### WU-1: Backend pure helpers + op/event types (Haskell)
**Files:**
- `src-gateway-types/Seal/Gateway/Types/Stream.hs` — `RequestEntriesOp`, `ClientMessage`, `SeEntriesChunk`, `parseServerEvent` case
- `src/Seal/Gateway/Stream.hs` — `entriesBeforeId`, `clampLimit`, `sendErrorFrame`, export list update
- `seal-harness.cabal` — no new modules (additions to existing)
- `test/Seal/Gateway/StreamSpec.hs` — tests for pure helpers
- `test/Main.hs` — wire new test if needed

**TDD:**
- RED: Test `entriesBeforeId` (found cursor, not-found → Nothing, empty list, cursor at head/tail), `clampLimit` (default/min/max/out-of-range), `ClientMessage` FromJSON dispatch (op="focus" → CmFocus, op="request-entries" → CmRequestEntries, op absent → CmFocus fallback), `RequestEntriesOp` FromJSON (with/without before/limit)
- GREEN: Implement types and pure helpers
- REFACTOR: Extract shared `breakOnId` pattern if beneficial

**Dependencies:** None (leaf unit)
**Verification:** `make test` — new tests pass; `make lint` — clean

### WU-2: Backend `handleRequestEntries` handler (Haskell)
**Files:**
- `src/Seal/Gateway/Stream.hs` — `handleRequestEntries`, `ClientMessage` dispatch in `readerLoop`
- `test/Seal/Gateway/StreamSpec.hs` — handler tests

**TDD:**
- RED: Test `handleRequestEntries` with fake connection: latest N (before=null), before-cursor (returns newest-of-older entries, NOT oldest), missing cursor (empty + hasMore=false), empty transcript, limit clamping, exception handler sends empty chunk
- GREEN: Implement handler + wire into readerLoop
- REFACTOR: N/A

**Dependencies:** WU-1 (needs `entriesBeforeId`, `clampLimit`, `RequestEntriesOp`, `ClientMessage`)
**Verification:** `make test` — handler tests pass; `make lint` — clean

### WU-3: Frontend types + streamClient (TypeScript)
**Files:**
- `frontend/src/types/stream.ts` — `ClientOp` variant, `ServerEvent` variant, `EntriesChunkPayload` type, `UseTranscriptStream` interface update
- `frontend/src/lib/streamClient.ts` — `requestEntries` method, `onEntriesChunk` listener, `handleMessage` case
- `frontend/src/lib/__tests__/streamClient.test.ts` — tests

**TDD:**
- RED: Test `requestEntries` sends correct WS message; `onEntriesChunk` fires on `entries-chunk` event; `handleMessage` dispatches correctly
- GREEN: Implement types + streamClient methods
- REFACTOR: N/A

**Dependencies:** None (frontend leaf unit, can proceed in parallel with WU-1/WU-2)
**Verification:** `cd frontend && npx vitest run` — new tests pass

### WU-4: Frontend `useTranscriptStream` hook (TypeScript)
**Files:**
- `frontend/src/hooks/useTranscriptStream.ts` — replace HTTP seed with WS chunk requests, `hasMore`/`totalCount`/`loadingMore`/`loadOlder` state, `CachedTranscript` type, `prependChunkEntries` function, WS status reset, response matching by sessionId + requestBefore, empty-chunk guard, initial-chunk reconnect, `refresh()` merge semantics
- `frontend/src/hooks/__tests__/useStreams.test.ts` — tests (note: actual test file is `useStreams.test.ts`, not `useTranscriptStream.test.ts`)

**TDD:**
- RED: Test initial load (latest chunk via WS), load older (prepend via `prependChunkEntries`), session switch (old response ignored), cache hit (shows cached + metadata), live entry during partial load, `loadingMore` reset on WS disconnect, empty-chunk guard, initial-chunk reconnect, `prependChunkEntries` dedup (older entry already in array → dropped), `prependChunkEntries` preserves ascending order, `refresh()` merges latest chunk with existing older entries
- GREEN: Implement hook changes + `prependChunkEntries`
- REFACTOR: Extract `prependChunkEntries` as exported pure function for testability

**Dependencies:** WU-3 (needs `StreamClient.requestEntries`, `onEntriesChunk`, new types)
**Verification:** `cd frontend && npx vitest run` — hook tests pass

### WU-5: Frontend ChatArea + App wiring (TypeScript)
**Files:**
- `frontend/src/components/ChatArea.tsx` — new props (hasMore, loadingMore, onLoadOlder, totalCount), scroll-to-top trigger, "Load older" button (keyboard accessible), loading indicator, "Showing N of M", scroll preservation, wasAtBottom interaction
- `frontend/src/App.tsx` — wire new state from useTranscriptStream to ChatArea
- `frontend/src/components/__tests__/ChatArea.test.tsx` — tests
- `frontend/src/__tests__/App.test.tsx` — tests

**TDD:**
- RED: Test "Load older" button + scroll trigger (scrollTop < 60), loading indicator visible when loadingMore, "Showing N of M" when !loading && totalCount > 0, keyboard activation (Enter/Space), scroll preservation on prepend, wasAtBottom.current = false on load-older
- GREEN: Implement ChatArea changes + App wiring
- REFACTOR: N/A

**Dependencies:** WU-4 (needs `hasMore`/`totalCount`/`loadingMore`/`loadOlder` from hook)
**Verification:** `cd frontend && npx vitest run` — ChatArea + App tests pass

### WU-6: Full integration + `make check`
**Files:** None (verification only)

**Tasks:**
- Run `make check` (build + test + lint)
- Run `cd frontend && npx vitest run && npx tsc --noEmit` (frontend tests + type check)
- Run `cd frontend && npm run build` (production build)
- Verify no full-transcript HTTP fetch on tab switch (test assertion or manual check)

**Dependencies:** WU-1, WU-2, WU-3, WU-4, WU-5 (all must be complete)
**Verification:** `make check` green, frontend build green

## Execution Order

```
WU-1 (backend types/helpers) ──→ WU-2 (backend handler) ──→ WU-6 (integration)
WU-3 (frontend types/client) ──→ WU-4 (frontend hook) ──→ WU-5 (frontend UI) ──→ WU-6
```

WU-1 and WU-3 can proceed in parallel (backend and frontend are independent).
WU-2 depends on WU-1. WU-4 depends on WU-3. WU-5 depends on WU-4.
WU-6 depends on all.

## Backward Compatibility

- HTTP `GET /api/sessions/:id/transcript` remains unchanged
- Existing `FocusOp` parsing preserved (ClientMessage falls back to CmFocus when op absent)
- Chat-channel WS client ignores `entries-chunk` events (forward-compat)
- `reconcileEntries` unchanged (still used for live-tail and refresh-merge)
- `replayEntriesSince` unchanged (still used for WS since-replay)

## Rollback

If issues arise, the feature can be rolled back by:
1. Reverting the frontend `useTranscriptStream.ts` to use HTTP seed fetch
2. The backend handler is additive (new op handling in readerLoop) — removing it has no impact on existing functionality
3. The new WS types are additive — existing clients ignore unknown event types