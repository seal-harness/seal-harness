# Incremental Transcript Rendering Design

> **Status:** Draft
> **Date:** 2026-09-21
> **Goal:** Sub-100ms transcript view on session switch for transcripts of
> any size. Snappy scroll-to-top and scroll-to-bottom. Multi-session
> cache for instant re-switch.

## Problem

When the user clicks a different session tab, the frontend:

1. Fetches the full transcript via HTTP GET (`/api/sessions/:id/transcript`).
2. Runs `useTranscriptMessages(entries)` — incremental per-entry caching
   helps on re-renders, but the first render of a new session still
   processes every entry.
3. Renders **all** `ChatMessage` components into the DOM in a single
   commit.
4. Auto-scrolls to the bottom.

For a 150-turn session (~300 messages, 280 KB payload), steps 2–3 take
500–900 ms on a fast machine. The user sees a blank "Loading
transcript…" state for that duration. This feels sluggish.

## Design Principle

> **Sub-100ms response time is a primary frontend design criterion.** The
> transcript view should feel instant on session switch regardless of
> transcript size. This is achieved by rendering only what the user will
> see immediately, then filling in the rest in the background.

The transcript is **append-only** and **immutable** (past entries never
change except streaming placeholders, which are already handled by
`reconcileEntries`). This immutability is the key enabler: once a slice
of the transcript is rendered, it never needs to be re-rendered unless
the user switches sessions and comes back.

## Approach: Windowed Rendering with Background Fill

### Core idea

Instead of rendering all N messages at once, render only a **window** —
the last `WINDOW_SIZE` messages (default 30, ~1–2 screen pages). The
user lands at the bottom, sees the latest messages immediately, and the
rest of the transcript is rendered in the background via
`requestIdleCallback` chunks.

```
Full transcript: [msg 0] [msg 1] ... [msg 270] [msg 271] ... [msg 299]
                                                   ↑ window (30 msgs)
                                                   user lands here
```

### Three-phase rendering

```
Phase 1: INSTANT (0–100ms)
  - Render the last WINDOW_SIZE messages.
  - Auto-scroll to bottom.
  - User sees the latest messages immediately.

Phase 2: BACKGROUND FILL (idle callbacks, 100ms–2s)
  - Render remaining messages in chunks of CHUNK_SIZE (default 20)
    via requestIdleCallback, filling from the window outward.
  - Each chunk is one React commit — small enough to not jank.
  - Scroll position is preserved (user stays at bottom).
  - If the user scrolls during fill, the fill adapts to prioritize
    the region around the viewport.

Phase 3: COMPLETE
  - All messages rendered. Normal scrolling behavior.
```

### Scroll-to-top and scroll-to-bottom

Both are handled the same way: **jump-to-window**.

- **Scroll to top:** The top `WINDOW_SIZE` messages are immediately
  rendered (if not already), the scroll position is set to the top, and
  background fill continues from there. If the full transcript is
  already rendered, this is just a `scrollTo({ top: 0 })` — no
  re-rendering.
- **Scroll to bottom:** Same, but for the bottom window. If the user is
  already at the bottom (the common case on session switch), this is a
  no-op.

The key insight: scroll-to-top does **not** force an immediate full
render. It only forces the top window to be rendered (if not already),
then jumps there. Background fill handles the rest.

### Multi-session renderer cache

The `TranscriptRenderer` class (from `useTranscriptMessages`) already
caches per-entry message results. We extend this to a **multi-session
cache**: a `Map<sessionId, TranscriptRenderer>` that persists across
session switches.

When the user switches from session A to session B:
1. Session A's renderer is kept in the cache (its per-entry cache and
   tool-result index are preserved).
2. Session B's renderer is retrieved from the cache (if it was visited
   before) or created fresh.
3. If session B was visited before, its cached messages are available
   immediately — only new entries (arrived via WS since the last visit)
   need processing.

The cache has a **max size** (default 8 sessions). When the cache is
full, the least-recently-used session is evicted. This bounds memory
usage while keeping the most-active sessions instant.

### Windowed rendering component

The rendering window is managed by a new `useWindowedMessages` hook
that wraps `useTranscriptMessages`:

```typescript
interface WindowState {
  /** Index of the first rendered message in the full array. */
  startIdx: number
  /** Index of the last rendered message (exclusive). */
  endIdx: number
  /** Whether background fill is in progress. */
  filling: boolean
}

function useWindowedMessages(
  allMessages: Message[],
  sessionId: string | null,
): {
  visibleMessages: Message[]
  /** Placeholder height for unrendered top section (px). */
  topPlaceholderHeight: number
  /** Placeholder height for unrendered bottom section (px). */
  bottomPlaceholderHeight: number
  /** Force the window to include the top — called on scroll-to-top. */
  jumpToTop: () => void
  /** Force the window to include the bottom — called on scroll-to-bottom. */
  jumpToBottom: () => void
  /** True when all messages are rendered. */
  isComplete: boolean
}
```

The hook:
1. On session change, sets `startIdx = max(0, N - WINDOW_SIZE)`,
   `endIdx = N`.
2. Renders `allMessages[startIdx..endIdx)`.
3. Kicks off background fill via `requestIdleCallback`:
   - Each callback expands the window by `CHUNK_SIZE` in the direction
     closest to the viewport (or both directions if the user is in the
     middle).
4. `jumpToTop` sets `startIdx = 0`, `endIdx = max(endIdx, WINDOW_SIZE)`,
   and scrolls to top.
5. `jumpToBottom` sets `endIdx = N`, `startIdx = min(startIdx, N -
   WINDOW_SIZE)`, and scrolls to bottom.

### Placeholder heights

Unrendered messages occupy space via placeholder `<div>` elements with
estimated heights. This preserves the scrollbar thumb size and prevents
layout jumps as messages are filled in.

The estimated height per message is based on a running average of
rendered message heights, measured after each chunk commit. Initially,
a default of 120 px per message is used.

### Interaction with existing features

**Sticky-bottom auto-scroll:** The existing `wasAtBottom` logic works
unchanged — it checks if the user is near the bottom and auto-scrolls on
new messages. During background fill, if the user is at the bottom, the
fill expands upward (so the bottom stays stable).

**Streaming updates:** When a new entry arrives via WS, it's appended
to the full message array. The window expands by one (if the user is at
the bottom) or stays the same (if the user is scrolled up). The new
message is rendered immediately since it's at the end.

**Fragment deep-links:** When a URL fragment targets a specific message
(`#msg-<id>`), the window is positioned to include that message before
rendering. The existing `useFragmentAnchor` handles scrolling into view.

**Slash-command bubbles:** These are spliced into the message array by
App.tsx and are part of the rendered list. They're included in the
window like any other message.

**Branch prefix messages:** In compose mode, `prefixMessages` are
rendered above the composer panel. These are typically short (a few
messages) and don't need windowing.

### Performance targets

| Scenario | Target | Mechanism |
|---|---|---|
| Session switch (150 turns) | < 100 ms to paint | Window: last 30 msgs |
| Session re-switch (cached) | < 50 ms to paint | Multi-session cache |
| Scroll-to-top | < 100 ms to paint | Jump-to-window + scroll |
| Scroll-to-bottom | < 50 ms | Already rendered |
| New WS entry (append) | < 16 ms (one frame) | Incremental hook |
| Background fill chunk | < 16 ms (no jank) | requestIdleCallback, 20 msgs |

### Constants

- `WINDOW_SIZE = 30` — initial visible window (~1–2 screen pages)
- `CHUNK_SIZE = 20` — messages per idle callback
- `MAX_CACHED_SESSIONS = 8` — multi-session renderer cache limit
- `DEFAULT_MSG_HEIGHT = 120` — px, initial height estimate
- `IDLE_TIMEOUT = 2000` — ms, max time to wait for an idle callback
  before using setTimeout fallback

### Files to create/modify

**New:**
- `frontend/src/hooks/useWindowedMessages.ts` — windowed rendering hook
- `frontend/src/hooks/__tests__/useWindowedMessages.test.ts` — tests

**Modified:**
- `frontend/src/hooks/useTranscriptMessages.ts` — extract renderer into
  multi-session cache
- `frontend/src/components/ChatArea.tsx` — use windowed messages,
  placeholder divs, scroll-to-top/bottom integration
- `frontend/src/hooks/__tests__/useTranscriptMessages.test.ts` — update
  for multi-session cache

### Testing strategy

1. **Unit tests (`useWindowedMessages.test.ts`):**
   - Initial window is the last N messages.
   - Background fill expands the window.
   - `jumpToTop` repositions the window.
   - `jumpToBottom` repositions the window.
   - Session change resets the window.
   - Small transcripts (< WINDOW_SIZE) render everything immediately.

2. **Integration tests (existing `ChatArea.test.tsx`):**
   - All existing tests pass unchanged (they use small transcripts).
   - New test: large transcript renders only the window initially.
   - New test: scroll-to-top renders the top window.

3. **Performance test (manual / perf overlay):**
   - Measure render→paint time on a 300-message transcript.
   - Verify < 100 ms for the initial window.
   - Verify background fill completes without jank.

### Out of scope

- Virtual scrolling (only rendering what's in the viewport) — this is a
  future optimization if background fill proves insufficient for very
  large transcripts (1000+ turns). The windowed approach should handle
  up to ~500 turns well.
- Server-side pre-rendering — the backend could pre-render the
  transcript to HTML and ship diffs, but this is a bigger architectural
  change and not needed yet.
- Transcript search/jump-to-message — this would benefit from the
  windowed architecture (jump to the message's position), but is a
  separate feature.