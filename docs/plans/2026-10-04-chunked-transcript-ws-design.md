# Chunked Transcript Loading via WebSocket

## Status: Approved (Design Review Gate — Round 3, all 5 reviewers approved)
## Issue: #243

## Problem

The web frontend downloads the **entire** session transcript via HTTP
`GET /api/sessions/:id/transcript` on every tab click. For long sessions
(hundreds of entries with large `web_fetch`/`SHELL_EXEC` tool results),
this is a multi-hundred-KB fetch that blocks the UI. The frontend already
supports partial transcript rendering in the DOM (the `TranscriptRenderer`
in `useTranscriptMessages.ts` does incremental per-entry processing), but
the data layer (`useTranscriptStream.ts`) always fetches the full
transcript.

### Quantified Impact

A representative long session (200+ entries with `WEB_FETCH` tool results)
produces a ~250-300 KB transcript JSON response. The `A.encode` phase
alone (serializing the full `Value` tree) takes 30-80 ms on the server,
and the HTTP transfer + `JSON.parse` on the client adds another 50-100 ms.
Total time-to-first-entry: **150-200 ms** for the full fetch, during which
the UI shows a loading spinner.

With chunked loading (50 entries per chunk), the initial payload drops to
**~30-60 KB** and time-to-first-entry drops to **<50 ms** — a 5-10x
improvement for the common case (user wants to see the latest activity,
not the full history).

## User Stories

1. **Operator monitoring a long-running session**: An operator watching a
   long agent session WANTS TO switch to its tab and see the latest
   activity immediately SO THAT they can judge progress without waiting
   for a full transcript download.

2. **Reviewer returning to a completed session**: A reviewer returning to
   a finished session WANTS TO scroll up to see what happened earlier
   SO THAT they can understand the agent's reasoning chain. They accept
   a brief loading delay when scrolling past the loaded boundary.

### Accepted Tradeoff

Chunked loading improves the common case (see latest) but makes
random-access to old entries slower than the old full-fetch — the user
must scroll-load multiple chunks to reach a specific old entry. This is
accepted for v1; search/jump-to is a deliberate v2 feature. The HTTP
endpoint remains as a fallback for full-fetch use cases (API consumers,
chat-channel clients).

### Accessibility

The "load older" trigger fires on scroll-to-top (`scrollTop < 60`). For
keyboard-only users, a "Load older messages" button is also rendered at
the top of the transcript area when `hasMore` is true. This button is
focusable and activates on Enter/Space.

## Solution

Replace the HTTP seed fetch with **WebSocket-based chunk requests**. The
existing WS connection (already open for live entry streaming) carries
both the live tail AND on-demand chunk requests. The user sees the latest
chunk first; scrolling to the top loads older chunks.

### Why WebSocket instead of HTTP pagination?

- **No new connection overhead** — the WS is already open and authenticated
- **No HTTP request/response framing cost** — a single WS frame each way
- **Unified transport** — one connection handles seed, live-tail, and
  replay, simplifying the frontend's state machine
- **Lower latency** — no TCP handshake, no HTTP header parsing per chunk

## Design

### 1. WS Protocol Changes

#### 1.1 New client→server op: `request-entries`

```json
{
  "op": "request-entries",
  "sessionId": "<session-id>",
  "before": "<entry-id>" | null,
  "limit": 50
}
```

- `before`: The entry id cursor. When `null`, the server returns the
  **latest** N entries. When set, the server returns entries **before**
  this id (exclusive) — used for "load older" / infinite scroll upward.
- `limit`: Maximum entries to return. The server clamps to a cap
  (default 50, max 200) to prevent abuse. The client sends a reasonable
  default; this field is mostly for future tuning.

The existing `focus` op is unchanged. The `request-entries` op is
independent of focus — the client can request chunks for any session
without changing its focused session.

#### 1.2 New server→client event: `entries-chunk`

```json
{
  "type": "entries-chunk",
  "sessionId": "<session-id>",
  "entries": [<TranscriptEntry>, ...],
  "hasMore": true,
  "totalCount": 347,
  "requestBefore": "<entry-id>" | null
}
```

- `entries`: The chunk of `TranscriptEntry` JSON objects (same shape as
  the existing `entry` events and the HTTP transcript response).
- `hasMore`: `true` when there are older entries not yet loaded.
- `totalCount`: The total number of entries in the session's transcript.
- `requestBefore`: Echoes the `before` cursor from the request, so the
  client can match responses to requests.

The entries in the chunk are in **ascending order** (oldest-first within
the chunk), matching the existing transcript display order.

#### 1.3 Backward compatibility

The HTTP `GET /api/sessions/:id/transcript` endpoint remains unchanged.
The frontend simply stops using it as its primary loading path.

### 2. Backend Implementation

#### 2.1 New op type: `RequestEntriesOp`

In `src-gateway-types/Seal/Gateway/Types/Stream.hs`:

```haskell
data RequestEntriesOp = RequestEntriesOp
  { reoSessionId :: Text
  , reoBefore    :: Maybe Text
  , reoLimit     :: Maybe Int
  } deriving stock (Eq, Show)
```

`FromJSON` parses `{op: "request-entries", sessionId, before?, limit?}`.

#### 2.2 New event type: `SeEntriesChunk`

In `src-gateway-types/Seal/Gateway/Types/Stream.hs`:

```haskell
| SeEntriesChunk SessionId Value
```

Added to `parseServerEvent` for `"entries-chunk"` type dispatch.

#### 2.3 `ClientMessage` sum type

```haskell
data ClientMessage = CmFocus FocusOp | CmRequestEntries RequestEntriesOp
```

`FromJSON` dispatches on the `op` field: `"focus"` → `CmFocus`,
`"request-entries"` → `CmRequestEntries`. The `readerLoop` pattern-matches
on `ClientMessage`.

**Backward compatibility**: The existing `FocusOp` `FromJSON` accepts
`{"session":"..."}` (no `op` field) for legacy channel-client compat.
`ClientMessage`'s `FromJSON` falls back to `CmFocus` when `op` is absent,
preserving the existing tolerance.

#### 2.4 Handler in `Stream.hs`

`handleRequestEntries` reads the full transcript via
`readTranscriptEntries`, slices it to the requested chunk, and sends an
`entries-chunk` event. **Includes a `catch` handler** (matching
`replayEntriesSince`) so a corrupt/missing transcript file sends an
error frame instead of propagating to the `readerLoop`'s top-level catch
and disconnecting the entire WS connection:

```haskell
handleRequestEntries :: Connection -> SealPaths -> RequestEntriesOp -> IO ()
handleRequestEntries conn paths (RequestEntriesOp sidTxt mBefore mLimit) =
  case mkSessionId sidTxt of
    Left _ -> sendErrorFrame conn "invalid session id"
    Right sid -> do
      let go = do
            mMeta <- loadSessionMeta paths sid
            let model = maybe "" smModel mMeta
                fallbackTs = maybe "" (showIso . smCreatedAt) mMeta
            allEntries <- readTranscriptEntries paths model fallbackTs sid
            let limit = clampLimit mLimit
                totalCount = length allEntries
                (chunk, hasMore) = case mBefore of
                  Nothing ->
                    let dropped = max 0 (totalCount - limit)
                    in (drop dropped allEntries, totalCount > limit)
                  Just before ->
                    case entriesBeforeId before allEntries of
                      Just beforeEntries ->
                        -- Take from the END of beforeEntries (newest of
                        -- the older entries, adjacent to the loaded
                        -- boundary) — NOT from the start. This matches
                        -- the latest-chunk case's direction and ensures
                        -- upward infinite scroll loads entries adjacent
                        -- to the currently-loaded boundary.
                        let taken = drop (max 0 (length beforeEntries - limit)) beforeEntries
                            hasMoreBefore = length beforeEntries > limit
                        in (taken, hasMoreBefore)
                      Nothing -> ([], False)  -- cursor not found → empty, no more
            sendTextData conn (A.encode (object
              [ "type" .= ("entries-chunk" :: Text)
              , "sessionId" .= sidTxt
              , "entries" .= chunk
              , "hasMore" .= hasMore
              , "totalCount" .= totalCount
              , "requestBefore" .= mBefore
              ]))
      go `catch` \(e :: SomeException) -> do
        globalLogIO InfoS ("[ws] request-entries error: " <> ls (T.pack (show e)))
        sendTextData conn (A.encode (object
          [ "type" .= ("entries-chunk" :: Text)
          , "sessionId" .= sidTxt
         , "entries" .= ([] :: [Value])
         -- Omit totalCount + hasMore in error path; client preserves
         -- its known values so the user can retry by scrolling again.
          , "requestBefore" .= mBefore
          ]))
```

**Key decision — `entriesBeforeId` missing-cursor behavior**: When the
`before` cursor id is not found in the transcript, `entriesBeforeId`
returns `Nothing`. The handler returns `entries: []`, `hasMore: false`.
This prevents accidentally dumping the full transcript (which the existing
`filterAfterId` fallback does) and prevents infinite loops. The client
treats this as "no more entries to load" and hides the "load older"
affordance.

#### 2.5 Pure helpers in `Stream.hs`

```haskell
-- | Return entries before the entry with id `before` (exclusive).
-- Returns Nothing when the id is not found (distinct from the existing
-- filterAfterId which falls back to all entries on a miss).
entriesBeforeId :: Text -> [Value] -> Maybe [Value]
entriesBeforeId beforeId = go
  where
    go [] = Nothing
    go (v : vs) =
      if extractId v == beforeId
        then Just []  -- found; entries before it are in the accumulator
        else case go vs of
          Just rest -> Just (v : rest)
          Nothing   -> Nothing

clampLimit :: Maybe Int -> Int
clampLimit = min 200 . max 1 . fromMaybe 50
```

**`sendErrorFrame` helper**: Extracted from the existing inline error
pattern in `readerLoop` (line 158):
```haskell
sendErrorFrame :: Connection -> Text -> IO ()
sendErrorFrame conn msg = sendTextData conn (A.encode (object
  [ "type" .= ("error" :: Text), "message" .= msg ]))
```
The `readerLoop`'s error message changes from "expected a focus op" to
"unknown op".

**`SeEntriesChunk` in `ServerEvent`**: Added for type-completeness. The
`Value` carries the entire JSON object (like `SeLists`). The chat-channel
WS client does not use chunked loading (it uses HTTP), so it ignores
this variant — safe per the existing forward-compat pattern.
`parseServerEvent` gets a new case:
```haskell
"entries-chunk" -> SeEntriesChunk
  <$> (asSessionId =<< KeyMap.lookup (Key.fromText "sessionId") o)
  <*> pure (A.Object o)  -- whole object, matching SeLists pattern
```

### 3. Frontend Implementation

#### 3.1 Types (`frontend/src/types/stream.ts`)

New `ClientOp` variant:
```typescript
| { op: 'request-entries'; sessionId: string; before: string | null; limit: number }
```

New `ServerEvent` variant:
```typescript
| { type: 'entries-chunk'; sessionId: string; entries: TranscriptEntry[];
    hasMore: boolean; totalCount: number; requestBefore: string | null }
```

New payload type (factored like `AskPayload`):
```typescript
export interface EntriesChunkPayload {
  entries: TranscriptEntry[]
  hasMore: boolean
  totalCount?: number  // optional — omitted in error path; client preserves known value
  requestBefore: string | null
}
```

Updated `UseTranscriptStream` interface:
```typescript
export interface UseTranscriptStream {
  entries: TranscriptEntry[]
  status: StreamStatus
  lastError: string | null
  pendingQuestions: PendingQuestion[]
  loading: boolean
  refresh: () => void
  hasMore: boolean          // older entries exist on disk; initialized false
  totalCount: number        // total entries; initialized 0
  loadingMore: boolean      // fetching older entries; initialized false
  loadOlder: () => void     // trigger to load the next chunk
}
```

#### 3.2 StreamClient (`frontend/src/lib/streamClient.ts`)

New method: `requestEntries(sessionId, before, limit)` — sends the WS op.
New listener: `onEntriesChunk(cb)` — fires on `entries-chunk` events.
New `handleMessage` case for `entries-chunk`.

#### 3.3 `useTranscriptStream` hook

**Initial state**: `hasMore = false`, `totalCount = 0`, `loadingMore = false`.
The "load older" affordance is hidden until the first chunk confirms
`hasMore: true`.

**On session switch (cache miss):**
1. Clear entries, set `loading = true`, reset `hasMore = false`,
   `totalCount = 0`, `loadingMore = false`
2. Send `focus(sessionId)` (unchanged)
3. Send `requestEntries(sessionId, null, CHUNK_SIZE)` — latest chunk
4. On `entries-chunk` with `requestBefore === null` **and** `sessionId`
   matching the current session: set entries, set `hasMore`, `totalCount`,
   `loading = false`

**Initial-chunk reconnect**: If the WS drops before the first
`entries-chunk` arrives (loading=true, entries empty), the
`onStatusChange` listener detects the transition to `reconnecting`.
On reconnect (status → `live` or `replaying`), if `loading === true` or
`entries.length === 0` for the focused session, the hook re-sends
`requestEntries(sessionId, null, CHUNK_SIZE)`.

**On session switch (cache hit):**
- Show cached entries + metadata immediately
- Send `focus(sessionId, lastId)` for replay (unchanged)

**Load older (user scrolls to top):**
1. Guard: if `loadingMore` or `!hasMore`, return
2. Set `loadingMore = true`
3. Send `requestEntries(sessionId, firstEntryId, CHUNK_SIZE)` where
   `firstEntryId` is the id of the oldest currently-loaded entry
4. On `entries-chunk` with `requestBefore !== null` **and** `sessionId`
   matching: **prepend** new entries via `prependChunkEntries` (see
   below), update `hasMore`, `loadingMore = false`

**`prependChunkEntries` function**: The existing `reconcileEntries` is
append-only — new ids are pushed to the END. It cannot prepend older
entries. A new pure function is required:
```typescript
/** Prepend older chunk entries to the existing array, dedup by id.
 *  Older entries that already exist (e.g. delivered via live tail
 *  during the chunk request) are NOT re-added — the existing entry
 *  wins. Ascending order preserved: chunk is ascending, goes before
 *  existing. */
export function prependChunkEntries(
  existing: TranscriptEntry[],
  older: TranscriptEntry[],
): TranscriptEntry[] {
  const existingIds = new Set(existing.map(e => e.id))
  const deduped = older.filter(e => !existingIds.has(e.id))
  return [...deduped, ...existing]
}
```
Chunk entries are always finalized (no streaming placeholders in
historical chunks), so no streaming-placeholder eviction is needed.

**Response matching**: The hook checks **both** `sessionId` and
`requestBefore` to match responses:
- `sessionId` must match the currently-focused session (protects against
  session-switch races — an old session's chunk response is ignored)
- `requestBefore === null` → initial load → replace entries
- `requestBefore !== null` → load older → prepend entries

**`loadingMore` reset on WS status change**: The hook subscribes to
`onStatusChange`. When status becomes `reconnecting` or `closed`,
`loadingMore` is reset to `false` (the in-flight chunk request is lost;
on reconnect, the hook sends a fresh `focus` + `requestEntries` if
needed).

**Empty-chunk guard**: If a load-older response returns `entries: []`
but `hasMore: true` (shouldn't happen with the backend's missing-cursor
behavior, but defensive), the hook sets `hasMore = false` to prevent an
infinite loop.

**Data cache**: `CachedTranscript = { entries, hasMore, totalCount }`.
The `update` method signature changes to accept the metadata. The WS
entry handler that calls `getGlobalDataCache().update(sid, next)` only
increments `totalCount` when `next.length > prev.length` (a genuinely
new entry was appended, not an in-place update like
streaming→finalized). `totalCount` is advisory (for the "Showing N of
M" indicator) and may drift if WS entries are missed; it's corrected on
refresh or cache-miss.

**`refresh()` semantics**: `refresh()` re-requests the latest chunk via
`requestEntries(sessionId, null, CHUNK_SIZE)`. On response, the latest
chunk is **merged** with existing entries via `reconcileEntries` (not
replacing the array) — this preserves already-loaded older entries
while refreshing the latest ones. `hasMore`/`totalCount` are NOT reset
by `refresh()`.

**Chunk size**: `const CHUNK_SIZE = 50`
#### 3.4 ChatArea (`frontend/src/components/ChatArea.tsx`)

New props: `hasMore`, `loadingMore`, `onLoadOlder`, `totalCount`

**Scroll-to-top trigger**: When `scrollTop < 60` and `hasMore` and
`!loadingMore`, call `onLoadOlder()`. Also sets `wasAtBottom.current =
false` to prevent the sticky-bottom effect from yanking the user down
after prepend.

**"Load older" button**: A focusable button at the top of the transcript
area, visible when `hasMore && !loadingMore`. Activates on Enter/Space,
calls `onLoadOlder()`. This provides keyboard accessibility.

**Loading indicator**: "Loading older messages..." spinner at top when
`loadingMore`.

**"Showing N of M" indicator**: Rendered in the transcript header area
when `!loading && totalCount > 0`: "Showing {entries.length} of
{totalCount}".

**Scroll preservation**: `useLayoutEffect` captures `scrollHeight` before
prepend, restores relative position after DOM update. Does NOT interfere
with `wasAtBottom` tracking or session-switch scroll (the load-older
trigger explicitly sets `wasAtBottom.current = false`).

#### 3.5 App.tsx wiring

Pass `hasMore`, `totalCount`, `loadingMore`, `loadOlder` from
`useTranscriptStream` to `ChatArea`.

### 4. Interaction with Existing Features

- **WS live-tail**: Unchanged. `onEntry` still receives new entries.
  `reconcileEntries` appends them. `totalCount` increments only when a
  genuinely new entry is added (not on in-place updates).
- **WS `since` replay**: Unchanged. `focus(sessionId, lastId)` replays
  missed entries.
- **LRU data cache**: Now stores `CachedTranscript` (entries + metadata).
  Cache hit shows entries + `hasMore`/`totalCount` immediately.
- **Refresh after send**: `refresh()` sends `requestEntries(sessionId,
  null, CHUNK_SIZE)` instead of HTTP fetch. The latest chunk is **merged**
  with existing entries via `reconcileEntries` — older entries already
  loaded are preserved, not lost. `refresh()` does NOT reset
  `hasMore`/`totalCount`.
- **HTTP endpoint**: Remains unchanged. No breaking change.

### 5. Edge Cases

1. **Empty transcript**: `entries: []`, `hasMore: false`, `totalCount: 0`
2. **Fewer entries than chunk size**: All entries returned, `hasMore: false`
3. **Rapid session switching**: Old session's chunk response ignored
   (sessionId mismatch in response matching)
4. **WS disconnect during chunk request**: `loadingMore` reset to `false`
   by `onStatusChange` listener; on reconnect, fresh `requestEntries` +
   `since` replay
5. **Multiple in-flight chunk requests**: `loadingMore` gating prevents
   this; only one load-older request at a time
6. **Scroll position on prepend**: `useLayoutEffect` preserves position;
   `wasAtBottom.current = false` prevents sticky-bottom yank
7. **Entry id stability**: Positional lookup (same as `breakOnId`) avoids
   lexicographic ordering issues
8. **Invalid `before` cursor** (stale id after session rebuild):
   `entriesBeforeId` returns `Nothing` → `entries: []`, `hasMore: false`
   → client hides "load older" (safe degradation)
9. **Empty chunk with `hasMore: true`** (shouldn't happen but defensive):
   Client sets `hasMore = false` to prevent infinite loop
10. **Prepend reconcile race** (live entry arrives during load-older
    request): `prependChunkEntries` dedup by id handles this — the
    live entry is already in the existing array; the chunk response's
    older entries that collide with existing ids are dropped (the
    existing/live entry wins). No duplication, no reordering.
11. **Initial-chunk WS disconnect**: If the WS drops before the first
    `entries-chunk` arrives, `loading` stays true but the
    `onStatusChange` listener detects reconnect and re-sends
    `requestEntries(sessionId, null, CHUNK_SIZE)`.

### 6. Testing Strategy

#### 6.1 TDD Cycle Sequencing

The feature spans 7 files across 2 languages. The RED→GREEN→REFACTOR
cycles are sequenced backend-first (protocol types → handler → pure
helpers), then frontend (types → streamClient → hook → ChatArea → App).

**Cycle 1 — Backend pure helpers (Haskell)**
- RED: `test/Seal/Gateway/StreamSpec.hs` — test `entriesBeforeId` with
  found cursor, not-found cursor (returns `Nothing`), empty list, cursor
  at head, cursor at tail. Test `clampLimit` with default, min, max,
  out-of-range values. QuickCheck: `entriesBeforeId` returns `Just` iff
  the id exists in the list.
- GREEN: Implement `entriesBeforeId` and `clampLimit` in `Stream.hs`.
- REFACTOR: Extract shared `breakOnId` pattern if beneficial.

**Cycle 2 — Backend `RequestEntriesOp` + `ClientMessage` (Haskell)**
- RED: Test `FromJSON` parsing of `RequestEntriesOp` with/without
  `before`/`limit`. Test `ClientMessage` dispatch on `op` field.
- GREEN: Implement types in `Stream.hs` + `Types/Stream.hs`.

**Cycle 3 — Backend `handleRequestEntries` (Haskell)**
- RED: Test `handleRequestEntries` with a fake connection: latest N,
  before-cursor, missing cursor (empty + hasMore false), empty
  transcript, limit clamping. Test error handler sends empty chunk on
  exception.
- GREEN: Implement `handleRequestEntries` in `Stream.hs`.

**Cycle 4 — Frontend types + streamClient (TypeScript)**
- RED: `streamClient.test.ts` — `requestEntries` sends correct WS
  message; `onEntriesChunk` fires on `entries-chunk` event.
- GREEN: Implement in `streamClient.ts` + `types/stream.ts`.

**Cycle 5 — Frontend `useTranscriptStream` hook (TypeScript)**
- RED: `useTranscriptStream.test.ts` — initial load (latest chunk),
  load older (prepend via `prependChunkEntries`), session switch (old
  response ignored), cache hit (shows cached + metadata), live entry
  during partial load, `loadingMore` reset on WS disconnect,
  empty-chunk guard, initial-chunk reconnect, `prependChunkEntries`
  dedup (older entry already in array via live tail → dropped),
  `prependChunkEntries` preserves ascending order, `refresh()` merges
  latest chunk with existing older entries.
- GREEN: Implement in `useTranscriptStream.ts`.

**Cycle 6 — Frontend ChatArea (TypeScript)**
- RED: `ChatArea.test.tsx` — "Load older" button + scroll trigger,
  loading indicator, "Showing N of M", keyboard activation.
- GREEN: Implement in `ChatArea.tsx`.

**Cycle 7 — App.tsx wiring (TypeScript)**
- RED: `App.test.tsx` — new props passed to ChatArea.
- GREEN: Wire up in `App.tsx`.

#### 6.2 Acceptance Criteria (measurable)

| Criterion | Target | Verification |
|-----------|--------|-------------|
| Initial tab-switch payload | < 60 KB (down from 250+ KB) | Instrument `entries-chunk` byte size in perf |
| Time-to-first-entry on tab switch | < 50 ms (down from 150-200 ms) | Instrument `transcript.seed` perf timer |
| "Load older" chunk round-trip | < 100 ms | Instrument `transcript.loadOlder` perf timer |
| `make check` passes | Build + test + lint green | CI gate |
| No full-transcript HTTP fetch on tab switch | Frontend never calls `/transcript` | Network tab / test assertion |

### 7. File Scope

**Backend (Haskell):**
- `src-gateway-types/Seal/Gateway/Types/Stream.hs` — `RequestEntriesOp`,
  `ClientMessage`, `SeEntriesChunk`, `parseServerEvent` update
- `src/Seal/Gateway/Stream.hs` — `handleRequestEntries`,
  `ClientMessage` dispatch in readerLoop, `entriesBeforeId`, `clampLimit`,
  `sendErrorFrame` helper

**Frontend (TypeScript):**
- `frontend/src/types/stream.ts` — `ClientOp` variant, `ServerEvent`
  variant, `UseTranscriptStream` interface, `EntriesChunkPayload` type
- `frontend/src/lib/streamClient.ts` — `requestEntries` method,
  `onEntriesChunk` listener, `handleMessage` case
- `frontend/src/hooks/useTranscriptStream.ts` — replace HTTP seed with
  WS chunk requests, `hasMore`/`totalCount`/`loadingMore`/`loadOlder`
  state, `CachedTranscript` type, WS status reset for `loadingMore`,
  response matching by `sessionId` + `requestBefore`, empty-chunk guard,
  initial-chunk reconnect, `prependChunkEntries` function,
  `refresh()` merge semantics
- `frontend/src/components/ChatArea.tsx` — new props, scroll-to-top
  trigger, "Load older" button (keyboard accessible), loading indicator,
  "Showing N of M", scroll preservation, `wasAtBottom` interaction
- `frontend/src/App.tsx` — wire new state to ChatArea

**Tests:**
- `test/Seal/Gateway/StreamSpec.hs` (or new spec) — backend tests
- `frontend/src/hooks/__tests__/useTranscriptStream.test.ts` — updated
- `frontend/src/lib/__tests__/streamClient.test.ts` — updated
- `frontend/src/components/__tests__/ChatArea.test.tsx` — updated

### 8. Risks and Mitigations

1. **Full transcript read per chunk request** — Acceptable for JSONL
   <1MB. Future: reverse-read optimization. The `handleRequestEntries`
   has a `catch` handler so file errors don't crash the WS connection.
2. **WS message ordering** — `requestBefore` + `sessionId` disambiguates;
   `reconcileEntries` dedup by id handles interleaved live entries.
3. **Scroll position jank** — `useLayoutEffect` preserves position;
   `wasAtBottom.current = false` prevents sticky-bottom yank.
4. **`.cabal` / `test/Main.hs` merge conflicts** — No new modules needed;
   all additions to existing modules.
5. **No per-connection rate limiting** (Security note): Each
   `request-entries` call reads the full transcript from disk. Equivalent
   cost to the existing `replayEntriesSince` path. Mitigated by the
   local-first single-operator trust model. Documented as a known
   tradeoff; a per-connection rate limit could be added in a future
   hardening pass.
