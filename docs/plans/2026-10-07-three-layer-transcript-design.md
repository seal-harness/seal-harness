# Three-Layer Transcript Rendering Architecture

## Status: Draft — Design Review Gate Round 2
## Issue: TBD (created after design approval)

## Problem

The current transcript rendering system has data fetching, state management,
scroll handling, and DOM rendering tangled together in `useTranscriptStream`
(447 lines) and `ChatArea` (2990 lines). This coupling produces interaction
bugs:

- 500MB transfers (HTTP seed not knowing about chunking)
- Scroll-to-top loops (scroll handler fighting with chunk loading)
- Transcript disappearing (`loading` state shared between operations)
- WS entry floods (focus with `since` after chunk response)
- Scroll-to-top/bottom not reaching the actual top/bottom

Each bug is an **emergent interaction** between concerns that should be
separated.

## Goal

**All user operations complete in < 100ms.** When that's impossible (network
latency for uncached data), aggressively prioritize fast response in the
majority of cases by keeping the right data cached.

The six operations from the transcript view, in cache-priority order:

1. **Scroll up** (highest priority — smallest, most frequent)
2. **Scroll down** (highest priority — smallest, most frequent)
3. **Scroll to top** (high — common user action)
4. **Scroll to bottom** (high — common user action)
5. **Page up** (lower — less frequent)
6. **Page down** (follows naturally from scroll down)

## Architecture

Three layers, each independently testable, with explicit interfaces between
them. A React integration bridge (`useTranscriptView`) connects the plain-TS
layers to React components.

```
┌─────────────────────────────────────────────────────────────┐
│              React Bridge: useTranscriptView                  │
│   Hook that wraps the three layers, provides React state      │
│   Consumed by ChatArea (replaces useTranscriptStream)         │
└──────┬───────────────────────────────────┬───────────────────┘
       │                                   │
┌──────▼──────────────────┐  ┌────────────▼──────────────────┐
│   Layer 3: View Manager  │  │  Layer 2: Message Cache        │
│   Virtual window + scroll │  │  TranscriptEntry → Message[]   │
│   Pure: renderTranscript  │  │  Per-entry processing cache    │
│   Returns ViewResult      │  │  Keyed by (sessionId, entryId) │
└──────┬───────────────────┘  └────────────┬───────────────────┘
       │ "give me messages [a, b)"          │ "give me entries [a, b)"
┌──────▼───────────────────────────────────▼───────────────────┐
│                Layer 1: Transcript Data Cache                 │
│   Raw TranscriptEntry[] — cursor-based sparse cache           │
│   Fetches from backend (HTTP + WS) on cache miss              │
│   Background prefetch with concurrency control                │
│   Error handling: fetch failures, WS disconnects              │
└───────────────────────────────────────────────────────────────┘
```

## Layer 1: Transcript Data Cache

### Responsibility

Store raw `TranscriptEntry[]` in memory. Serve requests for entry ranges
from cache. Fetch from backend on cache miss. Background-prefetch likely-
needed ranges with concurrency control.

### Cursor-Based Cache Model

The WS protocol is cursor-based (`before=entryId`), not positional. The
cache stores fetched chunks keyed by their cursor context, not by numeric
index:

```typescript
interface SessionData {
  totalCount: number               // from X-Total-Count or entries-chunk
  entries: Map<string, TranscriptEntry>  // entryId → entry (dedup store)
  orderedIds: string[]             // entry ids in ascending order
  // Assembled from fetched chunks; gaps are detected by comparing
  // orderedIds.length against totalCount.
}
```

`getRange(startIndex, count)` assembles from `orderedIds` + `entries`.
If `orderedIds` has gaps (not all entries fetched), `getRange` returns
what it can with `status: 'partial'` and triggers a fetch for the gap.

### Interface

```typescript
type RangeStatus = 'complete' | 'partial' | 'loading' | 'error'

interface RangeResult {
  entries: TranscriptEntry[]
  status: RangeStatus
  /** When status='error', a human-readable error message. */
  error?: string
  /** The range that was actually returned (may be smaller than requested). */
  availableRange: { start: number; count: number }
}

interface TranscriptDataCache {
  /** Get entries [startIndex, startIndex + count) for a session.
   *  Returns immediately with available data. Triggers background fetch
   *  for missing entries. Caller is notified via onRangeUpdate. */
  getRange(sessionId: string, startIndex: number, count: number): RangeResult

  /** Subscribe to range updates (fetch completions, live tail, errors). */
  onRangeUpdate(sessionId: string, cb: (update: RangeUpdate) => void): () => void

  /** Total entry count for a session. */
  totalCount(sessionId: string): number

  /** Whether older entries exist that aren't cached. */
  hasMore(sessionId: string): boolean

  /** Prefetch a range in the background. Fire-and-forget but
   *  concurrency-limited (max 3 concurrent per session, max 6 total).
   *  Overlapping requests are coalesced. */
  prefetch(sessionId: string, startIndex: number, count: number): void

  /** Clear cache for a session. */
  evict(sessionId: string): void

  /** Approximate memory usage in bytes. */
  size(): number

  /** Last error for a session (for UI display). */
  lastError(sessionId: string): string | null
}

interface RangeUpdate {
  range: { start: number; count: number }
  source: 'fetch' | 'live-tail' | 'replay' | 'error'
  entries: TranscriptEntry[]
  error?: string
}
```

### Fetch Strategy

- **Initial load** (cache miss): HTTP `GET /api/sessions/:id/transcript?limit=50`
  → latest 50 entries with `X-Total-Count` and `X-Has-More` headers.
- **Backward fetch** (older entries): WS `requestEntries(sessionId, before=entryId, limit)`
  where `entryId` is the id of the oldest currently-cached entry at the gap
  boundary.
- **Jump to beginning**: WS `requestEntries(sessionId, before='__beginning__', limit)`.
- **Forward fetch** (newer entries below current view): The WS protocol
  only supports `before` (older). For forward prefetch, use the HTTP endpoint
  with a future `?offset=` parameter (requires a small backend addition),
  OR simply rely on the live tail + initial load covering the latest entries.
  In practice, scroll-down prefetch is almost always a cache hit because
  the latest entries are always in cache from the initial load + live tail.
  If a forward gap exists, fall back to re-fetching from the latest chunk
  via HTTP.
- **Live tail**: WS `entry` events append to `entries` and `orderedIds`.
- **Replay**: WS `focus(sessionId, lastSeenId)` replays missed entries.

### Concurrent Request Correlation

Each in-flight request is tracked in a per-session table:

```typescript
interface InFlightRequest {
  before: string | null  // the cursor sent to the server
  startIndex: number     // the expected position in the transcript
  count: number          // the requested count
  timestamp: number      // for timeout tracking
}
```

When an `entries-chunk` arrives, it's matched by `(sessionId, requestBefore)`.
The `requestBefore` value uniquely identifies the request (only one request
per cursor at a time — duplicates are coalesced). The matched request's
`startIndex` tells the cache where to insert the entries.

### Background Prefetch with Concurrency Control

```typescript
class PrefetchQueue {
  private maxConcurrent = 6
  private maxPerSession = 3
  private active = new Map<string, Set<string>>()  // sessionId → cursors
  private pending: PrefetchRequest[] = []

  enqueue(req: PrefetchRequest): void {
    // Coalesce: if a pending/active request covers the same range, skip
    // Debounce: if the same range was requested < 50ms ago, skip
    this.pending.push(req)
    this.drain()
  }

  private drain(): void {
    // Start pending requests up to concurrency limits
    // Prioritize: scroll up/down > scroll to top/bottom > page up > other sessions
  }
}
```

### Eviction Policy

When memory budget exceeded (~50MB):

1. Evict other sessions' data first (keep current session intact)
2. Within current session, evict farthest chunks (keep scroll neighbors)
3. LRU across sessions (evict least-recently-viewed first)

### Error Handling

- HTTP fetch failure → `getRange` returns `status: 'error'`, `lastError` set
- WS disconnect → in-flight requests are abandoned, `status: 'error'` for
  pending ranges. On reconnect, re-fetch the initial chunk.
- Timeout → requests expire after 10s, `status: 'error'`
- Error entries in `entries-chunk` (empty entries, no hasMore/totalCount) →
  `status: 'partial'`, preserve last known `totalCount`

## Layer 2: Message Cache

### Responsibility

Cache the processed `Message[]` result of `TranscriptEntry → Message`
conversion (the expensive `processEntry` parse/dedup/tool-result-matching
that `useTranscriptMessages` currently does). **Does NOT cache React
elements** — React element creation is cheap and belongs in Layer 3.

### Interface

```typescript
interface TranscriptMessageCache {
  /** Get processed Message[] for entry ids. Returns from cache or
   *  processes on miss. */
  getMessages(sessionId: string, entryIds: string[]): Message[][]

  /** Invalidate entries (when streaming updates replace content). */
  invalidate(sessionId: string, entryIds: string[]): void

  /** Clear cache for a session. */
  evict(sessionId: string): void

  /** Approximate memory usage in bytes. */
  size(): number
}
```

### Cache Structure

```typescript
// Keyed by (sessionId, entryId) — entry ids are NOT globally unique
// across sessions, so the session id MUST be part of the key.
interface SessionMessageCache {
  messages: Map<string, { result: Message[][]; size: number }>
  totalSize: number
}
```

### What It Caches

The existing `useTranscriptMessages` hook's per-entry processing:
- `processEntry`: TranscriptEntry → Message[] (text blocks, thinking, tool calls)
- Tool-result index: matching tool_use blocks with tool_result content
- Dedup state: `seenSystem`, `seenTools` (incremental, per-session)

This logic is extracted into a pure function `processEntries(entries, existingCache) → Message[][]`
that doesn't depend on React hooks.

### Eviction Policy

LRU by access time. Budget: ~100MB (Message[] is larger than TranscriptEntry).

## Layer 3: View Manager (Virtual Window)

### Responsibility

Manage the visible portion of the transcript. Calculate which messages are
on-screen + overscan. Handle scroll events, button actions, scroll position
preservation. Create React elements from Layer 2's `Message[]`.

### The Pure Function

```typescript
type TranscriptPosition = 'top' | 'middle' | 'bottom'
type ViewStatus = 'ready' | 'loading' | 'error'

interface ViewResult {
  status: ViewStatus
  visibleRange: { start: number; end: number }  // entry indices
  topSpacerHeight: number
  bottomSpacerHeight: number
  scrollTop: number | null  // null = don't change scroll
  /** When status='loading', the caller shows a loading indicator
   *  instead of the transcript content. */
  error?: string
}

function renderTranscript(
  location: number,               // entry index to anchor on (0-based)
  position: TranscriptPosition,   // 'top' | 'middle' | 'bottom'
  viewportHeight: number,         // px — used to compute desiredCount
  avgRowHeight: number,           // px — from measurements
  state: TranscriptState,         // current state
): ViewResult
```

**Key invariants** (testable without a browser):
- `renderTranscript(0, 'top', ...)` → `visibleRange.start === 0`, `scrollTop === 0`
- `renderTranscript(totalCount - 1, 'bottom', ...)` → `visibleRange.end === totalCount`, `scrollTop === maxScroll`
- `renderTranscript` with `state.status === 'loading'` → returns `ViewResult.status === 'loading'`

### TranscriptState

```typescript
interface TranscriptState {
  totalCount: number              // total entries in the session
  /** Entries available in the visible range (from Layer 1).
   *  This is a contiguous slice for the current view, NOT the full
   *  sparse cache. Layer 1 assembles it on demand. */
  visibleEntries: TranscriptEntry[]
  /** Processed messages for the visible entries (from Layer 2). */
  visibleMessages: Message[][]
  /** The global start index of visibleEntries/visibleMessages. */
  visibleStartIndex: number
  /** Current scroll position in px. */
  scrollTop: number
  /** Whether data is being fetched for the current view. */
  status: ViewStatus
  /** Error message if status='error'. */
  error?: string
}
```

### Scroll Handling

The existing `useVirtualWindow` hook is the foundation. Key changes:
- Receives `viewportHeight` and `avgRowHeight` instead of computing internally
- `desiredCount` = `Math.ceil(viewportHeight / avgRowHeight) + OVERSCAN * 2`
- Scroll events coalesced via `requestAnimationFrame`
- Synthetic scroll suppression for programmatic scroll changes

### Scroll Position Preservation

`useLayoutEffect` captures `scrollHeight` before DOM update, restores
relative position after. The `renderTranscript` function returns
`scrollTop: number | null` — when non-null, the effect applies it.

### Button Actions

- **Scroll to top**: `renderTranscript(0, 'top', viewport, avgRow, state)`.
  If Layer 1 doesn't have entry 0, `state.status = 'loading'` and the view
  shows a loading indicator. When the fetch completes, `onRangeUpdate`
  triggers a re-render with the data.

- **Scroll to bottom**: `renderTranscript(totalCount - 1, 'bottom', viewport, avgRow, state)`.
  Latest entries are always cached (initial load + live tail).

- **Page up/down**: Shift `location` by `±desiredCount`.

## React Integration Bridge: useTranscriptView

A hook that wraps the three layers and provides React state for ChatArea:

```typescript
interface TranscriptView {
  // Visible data
  messages: Message[]              // flattened visible messages
  totalCount: number
  loading: boolean
  error: string | null

  // Virtual window
  visibleRange: { start: number; end: number }
  topSpacerHeight: number
  bottomSpacerHeight: number

  // Scroll management
  scrollTop: number
  onScroll: (scrollTop: number) => void

  // Actions
  scrollToTop: () => void
  scrollToBottom: () => void
  pageUp: () => void
  pageDown: () => void

  // Status
  hasMore: boolean                 // older entries exist
  loadingMore: boolean             // fetching older entries

  // Pending questions (migrated from useTranscriptStream)
  pendingQuestions: PendingQuestion[]
  refresh: () => void
}

function useTranscriptView(
  sessionId: string | null,
  dataCache: TranscriptDataCache,
  messageCache: TranscriptMessageCache,
  viewportRef: React.RefObject<HTMLDivElement>,
): TranscriptView
```

This hook is the **sole** consumer interface for ChatArea. It replaces
`useTranscriptStream` + `useTranscriptMessages` + `useVirtualWindow`.

## Background Prefetch Priority

After the current view is displayed (status='ready'), prefetch in order:

1. Scroll up: the page immediately above the current view
2. Scroll down: the page immediately below the current view
3. Scroll to top: the first page (oldest entries, `before='__beginning__'`)
4. Scroll to bottom: the last page (latest entries — almost always cached)
5. Page up: two pages above the current view
6. Other active sessions (top to bottom of tab list), latest page only

Prefetch is fire-and-forget with concurrency limits (max 6 total, max 3
per session). Overlapping requests are coalesced. Requests are debounced
(50ms) to avoid burst-loading on rapid scroll.

## Edge Cases (from existing code)

1. **Streaming placeholder eviction**: When a finalized entry replaces a
   streaming placeholder (same position, different id), the cache must
   invalidate the old entry and insert the new one at the same position.
2. **Session-null no-wipe**: When `sessionId` briefly becomes null during
   a React batch, entries must NOT be cleared (prevents flicker).
3. **HTTP/WS race**: The HTTP seed and WS live tail can deliver the same
   entry. Dedup by entry id (the existing `reconcileEntries` logic moves
   into Layer 1).
4. **Tool-result reprocessing**: When a new `tool_result` arrives, entries
   with matching `tool_use` blocks must be re-processed in Layer 2.
5. **WS disconnect during fetch**: In-flight requests are abandoned.
   `status='error'` for pending ranges. On reconnect, re-fetch initial chunk.
6. **Entry id stability**: Entry ids from the two-file format are synthetic
   line indices. The cache must handle id changes when the transcript is
   rebuilt.
7. **Large transcript (500+ entries)**: Only visible + overscan rendered.
   Spacer divs maintain proportional scrollbar.
8. **Session switch with cache hit**: Show cached data instantly. WS
   `focus(sessionId, lastSeenId)` replays only the delta.
9. **Session switch with cache miss**: HTTP seed with `?limit=50`. Loading
   indicator until response arrives.
10. **Empty transcript**: `getRange` returns `{ entries: [], status: 'complete' }`.
    ChatArea shows empty state.
11. **Prefetch on rapid scroll**: Debounce prevents burst-loading. Only the
    final scroll position triggers prefetch.
12. **Cross-session entry id collision**: Cache keys include sessionId:
    `(sessionId, entryId)`.

## Testing Strategy — TDD Cycles

### Layer 1: Data Cache (Phase 1)

**RED → GREEN → REFACTOR cycles:**

1. RED: `getRange` returns `status='complete'` for cached entries
   GREEN: Implement cache hit path
2. RED: `getRange` returns `status='partial'` + triggers fetch on miss
   GREEN: Implement fetch trigger + partial result
3. RED: `onRangeUpdate` fires when fetch completes with `source='fetch'`
   GREEN: Implement WS response handling
4. RED: `getRange` returns `status='error'` on HTTP failure
   GREEN: Implement error handling
5. RED: `prefetch` coalesces overlapping requests
   GREEN: Implement coalescing logic
6. RED: `prefetch` respects max concurrent limit
   GREEN: Implement concurrency queue
7. RED: `evict` removes session data
   GREEN: Implement eviction
8. RED: Live tail `entry` event appends and increments `totalCount`
   GREEN: Implement live tail handling
9. RED: `before='__beginning__'` fetches oldest entries
   GREEN: Implement jump-to-beginning
10. RED: Streaming placeholder eviction on finalized entry
    GREEN: Implement in-place replacement

### Layer 2: Message Cache (Phase 2)

1. RED: `getMessages` returns cached `Message[][]` on hit
   GREEN: Implement cache hit
2. RED: `getMessages` processes entries on miss
   GREEN: Implement `processEntries` pure function
3. RED: `invalidate` clears specific entries
   GREEN: Implement invalidation
4. RED: Tool-result reprocessing on new tool_result
   GREEN: Implement tool-result matching
5. RED: `evict` removes session cache
   GREEN: Implement eviction
6. RED: Cache stays within memory budget
   GREEN: Implement LRU eviction

### Layer 3: View Manager (Phase 3)

1. RED: `renderTranscript(0, 'top', ...)` → start=0, scrollTop=0
   GREEN: Implement top anchoring
2. RED: `renderTranscript(N-1, 'bottom', ...)` → end=N, scrollTop=max
   GREEN: Implement bottom anchoring
3. RED: `renderTranscript` with `status='loading'` → `ViewResult.status='loading'`
   GREEN: Implement loading state propagation
4. RED: Page up/down shifts visible range by one page
   GREEN: Implement paging
5. RED: Scroll position preserved after prepend
   GREEN: Implement scroll preservation
6. RED: Overscan extends beyond visible range
   GREEN: Implement overscan

### React Bridge (Phase 4)

1. RED: `useTranscriptView` returns loading state on initial mount
   GREEN: Wire up Layer 1 initial fetch
2. RED: `useTranscriptView` returns messages after fetch completes
   GREEN: Wire up onRangeUpdate → re-render
3. RED: `scrollToTop` triggers `renderTranscript(0, 'top', ...)`
   GREEN: Wire up button actions
4. RED: Session switch shows cached data instantly
   GREEN: Wire up cache hit path
5. RED: `pendingQuestions` and `refresh` work as before
   GREEN: Migrate from useTranscriptStream

## Implementation Phases

### Phase 1: Layer 1 — Data Cache
Files:
- `frontend/src/lib/transcriptDataCache.ts` — new
- `frontend/src/lib/__tests__/transcriptDataCache.test.ts` — new

TDD: 10 RED-GREEN-REFACTOR cycles (listed above)

### Phase 2: Layer 2 — Message Cache
Files:
- `frontend/src/lib/transcriptMessageCache.ts` — new (extracts processEntry
  from `useTranscriptMessages.ts`)
- `frontend/src/lib/__tests__/transcriptMessageCache.test.ts` — new

TDD: 6 RED-GREEN-REFACTOR cycles

### Phase 3: Layer 3 — View Manager
Files:
- `frontend/src/lib/transcriptViewManager.ts` — new (refactors
  `useVirtualWindow.ts`)
- `frontend/src/lib/__tests__/transcriptViewManager.test.ts` — new

TDD: 6 RED-GREEN-REFACTOR cycles

### Phase 4: React Bridge
Files:
- `frontend/src/hooks/useTranscriptView.ts` — new (replaces
  `useTranscriptStream.ts` + `useTranscriptMessages.ts` + `useVirtualWindow.ts`)
- `frontend/src/hooks/__tests__/useTranscriptView.test.ts` — new

TDD: 5 RED-GREEN-REFACTOR cycles

### Phase 5: ChatArea Integration
Files:
- `frontend/src/components/ChatArea.tsx` — modified (simplified)
- `frontend/src/App.tsx` — modified (wiring)
- `frontend/src/__tests__/App.test.tsx` — modified (update mocks)

### Phase 6: Background Prefetch
Files:
- `frontend/src/lib/transcriptDataCache.ts` — modified (add prefetch queue)
- `frontend/src/lib/__tests__/transcriptDataCache.test.ts` — modified

### Phase 7: Cleanup + Migration
Files:
- `frontend/src/hooks/useTranscriptStream.ts` — DELETED
- `frontend/src/hooks/useTranscriptMessages.ts` — DELETED
- `frontend/src/hooks/useVirtualWindow.ts` — DELETED
- `frontend/src/hooks/__tests__/useStreams.test.ts` — modified (migrate tests)
- `frontend/src/hooks/__tests__/useTranscriptMessages.test.ts` — DELETED
- `frontend/src/hooks/__tests__/useVirtualWindow.test.ts` — DELETED

## Breaking Changes

| File | Change | Migration |
|------|--------|-----------|
| `useTranscriptStream.ts` | DELETED | Replaced by `useTranscriptView` |
| `useTranscriptMessages.ts` | DELETED | Extracted into `transcriptMessageCache.ts` |
| `useVirtualWindow.ts` | DELETED | Refactored into `transcriptViewManager.ts` |
| `App.tsx` | Modified | Swap `useTranscriptStream` → `useTranscriptView` |
| `ChatArea.tsx` | Modified | Consume `TranscriptView` interface |
| `useStreams.test.ts` | Modified | Migrate `reconcileEntries` tests to Layer 1 |
| `useTranscriptMessages.test.ts` | DELETED | Tests migrated to Layer 2 |
| `useVirtualWindow.test.ts` | DELETED | Tests migrated to Layer 3 |
| `App.test.tsx` | Modified | Update mock to include new interface |
| `streamClient.ts` | UNCHANGED | Layer 1 uses it internally |
| `types/stream.ts` | UNCHANGED | WS protocol types preserved |
| Backend | UNCHANGED | All backend work kept |

## Performance Targets

| Operation | Target | Mechanism |
|-----------|--------|-----------|
| Scroll up/down | < 16ms | Layer 2+3 cache hit (no network) |
| Page up/down | < 16ms | Layer 2+3 cache hit (no network) |
| Scroll to top (cached) | < 50ms | Layer 1+2+3 cache hit |
| Scroll to top (uncached) | < 100ms | Single WS request, no replay flood |
| Scroll to bottom | < 16ms | Latest entries always cached |
| Session switch (cached) | < 16ms | Layer 1 cache hit |
| Session switch (uncached) | < 100ms | HTTP seed with limit=50 |
| Initial load | < 100ms | HTTP seed with limit=50 |

## What Gets Thrown Away

- `useTranscriptStream` (447 lines) — replaced by Layer 1 + React bridge
- `useTranscriptMessages` (591 lines) — extracted into Layer 2
- `useVirtualWindow` (220 lines) — refactored into Layer 3
- `ChatArea` transcript section (~1500 lines) — simplified
- `prependChunkEntries`, `reconcileEntries` — internal to Layer 1
- `fetchTranscriptSeed` — internal to Layer 1
- `CachedTranscript` class — replaced by Layer 1

## What Is Kept

- All backend changes (WS protocol, HTTP headers, GLM parser)
- `streamClient.ts` (WS client — Layer 1 uses it)
- `types/stream.ts` (WS protocol types)
- `types.ts` (TranscriptEntry, Message types)
- `ChatArea` non-transcript sections (composer, header, etc.)
- All existing tests for non-transcript functionality
