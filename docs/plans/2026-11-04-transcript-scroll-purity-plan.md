# Transcript scroll purity + scroll-to-top fix (rev 5)

<!-- status: awaiting operator go/no-go — gate ran 4 rounds (1 extra at operator request) -->
<!-- date: 2026-11-04 -->
<!-- branch: frontend/transcript-scroll-purity -->
<!-- rev 5: addresses plan-review-gate iteration 4 findings -->

## Symptom

Sometimes the web frontend cannot scroll to the top of a transcript. The
"Scroll to top" button does nothing, repeatedly. Clicking away to another
session and back does not help. A hard refresh does.

## Root cause (verified by reading code)

1. `ChatArea` scrolls near the top → `loadOlder()` → WS `request-entries`
   with `before=<oldest loaded entry id>`.
2. `handleRequestEntries` (`src/Seal/Gateway/Stream.hs`, the `case mBefore of`
   block) reads only `ReadLastN (limit * 3)` (150 entries) for a `before`
   cursor, then searches that truncated window with `entriesBeforeId`. Once
   the cursor is older than the window it is not found → `([], False)`. Even
   before that, `hasMoreBefore` is computed *inside* the truncated window, so
   after a couple of backward pages it reports `False` although older entries
   exist.
3. The frontend stores that answer in the `hasMore` boolean and in the
   module-level `TranscriptDataCache`. There is no other source of truth, so
   the flag is wrong for the lifetime of the page.
4. The "Scroll to top" handler then takes its non-`hasMore` branch — a bare
   `scrollTo({ top: 0 })` — i.e. the top of the *loaded slice*, not the
   transcript.
5. Session switch is a cache hit on the same `{entries, hasMore:false}`; only
   a reload re-runs the HTTP seed and restores `hasMore:true`.

Secondary stateful defects on the same path:

- `pendingScrollToTop` / `pendingScrollToBottom` are independent refs that can
  both be set and are only consumed inside effects that early-return when a
  URL fragment is present.
- `triggeredLoadLatest` is a third ref that must be reset manually.
- `useVirtualWindow` has its own `wasAtBottom` ref **and** a boolean
  `syntheticScrollRef`; the latter is cleared only by the next scroll event,
  so a coalesced/clamped adjustment can swallow the next real event, and the
  former is a second sticky-bottom state machine.

## Decisions

| # | Decision |
|---|---|
| D1 | Older/newer availability is **derived** from a window extent (`atStart`, `atEnd`, `olderBlocked`) held in the same reducer state as the entries. `hasOlder = !atStart`, `isViewingLatest = atEnd`. No free-standing `hasMore` boolean. |
| D2 | `totalCount` is **not** load-bearing for scroll state (`ttEntryCount` is a record/line count on the indexed path and can exceed the frontend entry count). It stays a passthrough. |
| D3 | Backend `before`-cursor pagination reads the whole entry list, so the cursor is always found and `hasMore` means "entries exist before this chunk". The handler core takes the reader/sink as arguments so the production decision path is testable without a socket. |
| D4 | Scroll intent is one `'top' | 'bottom' | null` driven by a pure reducer. Two programmatic-scroll guards with **distinct jobs**: the hook's measurement adjustments suppress both range updates and intent cancellation; the button's own scrolls suppress intent cancellation only (so the range still recomputes). Neither can swallow a later real event (guards clear on mismatch only). |
| D5 | Virtual-window range/spacer/height math moves into pure functions; the hook keeps no scroll-decision refs of its own (`atBottomRef` and `scrollGuard` are passed in; both default to the current behaviour). |
| D6 | An explicit user scroll request wins over URL-fragment auto-scroll suppression. Automatic behaviour (session-switch follow, sticky-bottom) is still suppressed when a fragment is present. |
| D7 | Wire protocol unchanged. `hasMore`/`isViewingLatest` prop names stay (now derived). Backend + frontend ship in one PR; rollback reverts both. |
| D8 | Existing deliberate behaviours are preserved: entries are **not** wiped when `sessionId` goes null (anti-flicker), and a live append does **not** change the window extent (`isViewingLatest` stays false for a beginning-only window). |

## Work units

### WU-1 — Backend cursor pagination is correct + testable handler core

Files:
- `src/Seal/Gateway/Stream.hs`
- `test/Seal/Gateway/StreamSpec.hs`

Changes:
- Two plain pure functions:
  ```haskell
  readLimitFor :: Maybe Text -> Int -> ReadLimit
  -- Nothing -> ReadLastN n; Just "__beginning__" -> ReadFirstN n; Just _ -> ReadAll

  shapeChunk :: Maybe Text -> Int -> Int -> [Value] -> ([Value], Bool)
  -- mBefore -> limit -> totalCount -> readWindow -> (chunk, hasMore)
  ```
  `shapeChunk (Just before)` computes `hasMore` from
  `length beforeEntries > limit` over the **full** list (no `totalCount`);
  `Nothing`/`__beginning__` use `totalCount > limit`.
- Testable core (the production decision path, not just the helpers):
  ```haskell
  handleRequestEntriesCore
    :: (ReadLimit -> IO ([Value], Int))                  -- reader: limit -> (window, totalCount)
    -> ([Value] -> Bool -> Int -> Maybe Text -> IO ())   -- sink: chunk/hasMore/totalCount/before
    -> Maybe Text -> Int -> IO ()
  ```
  `handleRequestEntries conn paths op` binds the real reader/sink and keeps
  the existing `catch`. Export all three.
- Document that `totalCount` is a conservative upper bound, not an index.

DoD:
- [ ] `readLimitFor (Just "e5") 50 == ReadAll`. **(This is the bug: today the
      handler uses `ReadLastN 150`.)**
- [ ] `handleRequestEntriesCore` with a fake reader over 1000 synthetic
      entries records **`ReadAll`** for `Just "e100"`; the fake sink receives
      entries 50..99 with `hasMore == True`.
- [ ] Fake reader over 40 entries for `Just "__beginning__"`: sink receives
      0..39, `hasMore == False`.
- [ ] `shapeChunk (Just "e10") 50 1000 entries0to999` → 0..9,
      `hasMore == False`.
- [ ] `Nothing` on entries 950..999 with `totalCount 1000` → 950..999,
      `hasMore == True`.
- [ ] Missing cursor on a full list → `([], False)`.
- [ ] No inline `ReadLastN (limit * 3)` / inline slicing remains.

Rollback: revert the helpers + read mode (together with the frontend; see
Backward compatibility).

### WU-2 — Pure transcript reducer (entries + window extent together)

Files:
- `frontend/src/lib/transcriptState.ts` (new)
- `frontend/src/lib/__tests__/transcriptState.test.ts` (new)

Why a reducer: `added` (net new entries after dedup) is only knowable inside
the `setEntries` updater today, and deriving the extent in a second state
update is not atomic.

API:
```ts
interface WindowExtent { atStart: boolean; atEnd: boolean; olderBlocked: boolean }
interface TranscriptState { entries: TranscriptEntry[]; extent: WindowExtent }

type TranscriptEvent =
  | {type:'reset'}
  | {type:'hydrate'; entries: TranscriptEntry[]; extent: WindowExtent}   // cache hit
  | {type:'seed'; entries: TranscriptEntry[]; chunkHasMore: boolean}     // HTTP seed
  | {type:'chunk-latest'; entries: TranscriptEntry[]; chunkHasMore: boolean}
  | {type:'chunk-beginning'; entries: TranscriptEntry[]; chunkHasMore: boolean}
  | {type:'chunk-older'; entries: TranscriptEntry[]; chunkHasMore: boolean}
  | {type:'entry'; entry: TranscriptEntry}                               // live tail
  | {type:'merge-tail'; entries: TranscriptEntry[]}                      // re-seed merge
  | {type:'chunk-error'}                                                 // no hasMore field

reduceTranscript(state: TranscriptState, e: TranscriptEvent): TranscriptState
hasOlder(extent): boolean            // !atStart
isViewingLatest(extent): boolean     // atEnd
canAutoLoadOlder(extent): boolean    // !atStart && !olderBlocked
```
Rules:
- `reset` → `{entries: [], extent: WHOLE}`.
- `hydrate` → exactly the given entries + extent (cache round-trip; no
  re-derivation, so a `{atStart:true, atEnd:false}` beginning window is
  restorable).
- `seed` / `chunk-latest` → entries replaced;
  `{atStart: !chunkHasMore, atEnd: true, olderBlocked: false}`.
- `chunk-beginning` → entries replaced;
  `{atStart: true, atEnd: !chunkHasMore, olderBlocked: false}`. (No
  `count < limit` shortcut: it contradicts the existing
  `isViewingLatest === false` test for a 1-entry beginning chunk.)
- `chunk-older` → prepend+dedup. Let `added = next.length - prev.length`.
  - `added > 0` → `{atStart: !chunkHasMore, atEnd: prev.atEnd,
    olderBlocked: false}`.
  - `added === 0` → extent unchanged except `olderBlocked: true` (a request
    that added nothing must not mark the start and must not be re-fired).
- `entry` → `reconcileEntries`; extent **unchanged** (D8: a beginning window
  stays `isViewingLatest:false` after a live append, so ChatArea's
  "bottom but not latest → loadLatest" trigger still works).
- `merge-tail` → `reconcileEntries` for each; extent unchanged.
- `chunk-error` → state unchanged.
- `reconcileEntries` and `prependChunkEntries` move here; the hook re-exports
  them so existing test imports keep working.

DoD:
- [ ] Seed 1000 entries as the tail 50 with `chunkHasMore:true` → `hasOlder`
      true, `isViewingLatest` true.
- [ ] `chunk-older` 50 new entries, `chunkHasMore:true` → `hasOlder` true;
      the final page (50 new, `chunkHasMore:false`) → `hasOlder` false.
- [ ] The existing semantics are preserved: a 1-entry prepend with
      `hasMore:false` → `hasMore:false` (the `useStreams` assertion stays
      unchanged).
- [ ] `chunk-older` with 0 new entries → extent unchanged except
      `olderBlocked:true`; `canAutoLoadOlder` false; a later non-empty
      chunk clears it.
- [ ] `chunk-beginning` with `chunkHasMore:true` → `atEnd:false`;
      with `false` → `atEnd:true` (existing `isViewingLatest` tests pass).
- [ ] `chunk-error` leaves entries and extent untouched.
- [ ] `entry` appends without changing the extent; streaming replacement
      keeps length and extent.
- [ ] `merge-tail` adds entries without moving the extent.
- [ ] `hydrate` restores a `{atStart:true, atEnd:false}` window exactly.
- [ ] `reset` returns `WHOLE` with no entries.
- [ ] No `totalCount` parameter anywhere in this module.

Rollback: new module; the hook switches back to its current inline state.

### WU-3 — Pure scroll math + virtual window adoption

Files:
- `frontend/src/lib/transcriptScroll.ts` (new)
- `frontend/src/lib/__tests__/transcriptScroll.test.ts` (new)
- `frontend/src/hooks/useVirtualWindow.ts`
- `frontend/src/hooks/__tests__/useVirtualWindow.test.ts`
- `frontend/src/hooks/__tests__/transcriptRendererParity.test.ts` (must pass
  **unchanged**; it exists — `git ls-files` lists it — and its inline oracle
  stays independent)

API:
```ts
AT_BOTTOM_PX = 80; AT_TOP_PX = 60
interface ScrollMetrics { scrollTop: number; scrollHeight: number; clientHeight: number }
isAtBottom(m, threshold?): boolean
isNearTop(m, threshold?): boolean
computeVisibleRange({scrollTop, viewportHeight, avgRowHeight, messageCount,
                     overscan, minRendered}): {startIndex, endIndex}
computeSpacers(range, messageCount, avgRowHeight): {top, bottom}
blendRowHeight(prev, measuredHeight, renderedCount): number
spacerScrollAdjustment(startIndex, prevAvg, nextAvg): number
isSyntheticScroll(currentScrollTop: expected: number | null): boolean
```
Guards: non-finite/≤0 `avgRowHeight` falls back to the estimate; ranges
clamped to `[0, messageCount]` with `startIndex ≤ endIndex`; spacers never
negative.

`useVirtualWindow` changes:
- Options: `{ atBottomRef?: Ref<boolean>, scrollGuard?: Ref<number | null> }`.
  Defaults when omitted: `atBottomRef = {current: true}` and a private guard
  ref — so existing 3-arg tests and the parity test keep their behaviour.
- `atBottomRef` is the single at-bottom input (owned by ChatArea); delete the
  hook's own `wasAtBottom`.
- Delete `syntheticScrollRef`; the hook sets `scrollGuard.current =
  newScrollTop` immediately before its measurement adjustment.
- Replace inline range/spacer/blend/adjust math with the pure functions.
- Guard semantics: an event is synthetic iff
  `isSyntheticScroll(el.scrollTop, scrollGuard.current)`. A matching event is
  ignored (no range update) and does **not** clear the guard; a
  non-matching event clears it and is processed. Two listeners on the same
  event therefore cannot clear it for each other, and a coalesced adjustment
  cannot swallow a later real scroll.

DoD:
- [ ] `computeVisibleRange` at `scrollTop 0` → `startIndex 0`; at the bottom
      → `endIndex == messageCount`; never `startIndex > endIndex` or outside
      `[0, messageCount]`.
- [ ] `computeSpacers` 0 for a full range; never negative when
      `endIndex > messageCount` or `startIndex > messageCount`.
- [ ] `blendRowHeight` finite/positive for 0 height, 0 rendered, NaN,
      negative.
- [ ] `isSyntheticScroll` exact/±1 boundaries.
- [ ] Hook test (replaces the old `syntheticScrollRef` test, which asserted
      an internal): after a measurement adjustment, the next real scroll
      event updates the range.
- [ ] Hook test: injected `atBottomRef = false` → new messages do not snap
      the range to the bottom; `true` does; omitted → defaults true.
- [ ] `useVirtualWindow` declares no scroll-decision ref of its own
      (`wasAtBottom` / `syntheticScrollRef` absent).
- [ ] `transcriptRendererParity.test.ts` passes unchanged.

Rollback: restore the internal refs + inline math.

### WU-4 — Hook wiring: one reducer, derived flags

Files:
- `frontend/src/hooks/useTranscriptStream.ts`
- `frontend/src/types/stream.ts`
- `frontend/src/hooks/__tests__/useStreams.test.ts`

Changes:
- `useReducer(reduceTranscript, initial)` replaces the `entries` state; every
  write goes through an event (`seed`, `chunk-latest`, `chunk-beginning`,
  `chunk-older`, `entry`, `merge-tail`, `chunk-error`, `hydrate`).
- `hasMore = hasOlder(state.extent)`, `isViewingLatest =
  isViewingLatest(state.extent)`; `totalCount` is a passthrough number never
  used by a scroll decision.
- `TranscriptDataCache` stores `TranscriptState` + `totalCount`;
  `update(sid, state)` takes the reducer state from the caller (deletes the
  `+1` heuristic and the cached `hasMore`). Cache hit dispatches `hydrate`.
- **`sessionId === null` does not wipe entries** (D8): only `loadingMore`
  and pending questions are cleared, exactly as today.
- `loadingMore` reset on every session load (cache hit included) and on a
  chunk for a non-focused session; keep the disconnect reset.
- `types/stream.ts`: `EntriesChunkPayload.hasMore` and
  `EntriesChunkEvent.hasMore` become optional — the backend error frame
  omits the field, and the client uses `hasMore === undefined` to dispatch
  `chunk-error` instead of a chunk event.
- `loadFromBeginning`/`loadLatest` return
  `LoadResult = 'requested' | 'applied' | 'unchanged' | 'unavailable'`.
  `'unchanged'` means the pinned entries array is reference-equal to the
  current entries: **no dispatch happens** (a dispatch would re-render even
  with equal contents), so the caller must scroll directly. `undefined`
  returned from a caller-supplied mock is treated as `'requested'`.
- `loadLatest` prefers the pinned tail only when it is `atEnd`; otherwise it
  requests the latest chunk.

DoD:
- [ ] Reported bug at hook level: seed 50 of a 1000-entry transcript
      (`hasMore:true`); deliver the backward page the **fixed** backend
      returns (50 entries, `hasMore:true`) → `hasMore` stays true; the final
      page (`hasMore:false`) → `hasMore` false.
- [ ] `loadOlder` is a no-op once `hasMore` is false; guarded by
      `loadingMore`.
- [ ] Cache round-trip: live append → switch to B → switch back → entries and
      `hasMore`/`isViewingLatest` are restored exactly (including a
      beginning-only window `{atStart:true, atEnd:false}`), and
      `loadingMore === false`.
- [ ] `sessionId === null` keeps the entries (existing anti-flicker test
      passes unchanged).
- [ ] Error frame (`hasMore` undefined) → `chunk-error`: entries and extent
      unchanged, `loadingMore` cleared.
- [ ] Re-seed merge leaves the extent unchanged.
- [ ] Disconnect while `loadingMore` clears it; reconnect re-request fires.
- [ ] `loadLatest` returns `'unchanged'` without dispatching for the same
      reference, `'applied'` for a different pinned reference, `'requested'`
      when no pinned tail exists.
- [ ] Existing `useStreams` tests pass unchanged (no semantics inversion).

Rollback: restore `entries` + `hasMore` state, the old cache shape, and the
required (non-optional) `hasMore` field.

### WU-5 — Single scroll intent in `ChatArea`

Files:
- `frontend/src/lib/scrollIntent.ts` (new)
- `frontend/src/lib/__tests__/scrollIntent.test.ts` (new)
- `frontend/src/components/ChatArea.tsx`
- `frontend/src/components/__tests__/ChatArea.test.tsx`
- `frontend/src/App.tsx` (only if a prop type needs widening)
- mock updates: `ChatArea.test.tsx` (the `loadFromBeginning`/`loadLatest`
  mocks in the same-reference no-op tests must return `'unchanged'`) and
  `frontend/src/__tests__/App.test.tsx`

API:
```ts
type ScrollIntent = 'top' | 'bottom' | null
type ScrollEvent =
  | {type:'select-session'; preserveAnchor: boolean}
  | {type:'scroll-to-top'; atStart: boolean}
  | {type:'scroll-to-bottom'; atEnd: boolean}
  | {type:'content-arrived'; loading: boolean; empty: boolean; atBottom: boolean}
  | {type:'scrolled'; atTop: boolean; atBottom: boolean;
     hasNewer: boolean; canAutoLoadOlder: boolean}
  | {type:'user-scrolled'}
interface ScrollStep { intent: ScrollIntent;
                       fetch: 'beginning'|'latest'|'older'|null;
                       scrollTo: 'top'|'bottom'|null }
nextScrollIntent(current: ScrollIntent, event: ScrollEvent): ScrollStep
```
Rules:
- `select-session {preserveAnchor:true}` → `{intent:null}`; `false` →
  `{intent:'bottom'}`.
- `scroll-to-top {atStart:false}` → `{intent:'top', fetch:'beginning'}`;
  `{atStart:true}` → `{intent:null, scrollTo:'top'}`.
- `scroll-to-bottom {atEnd:false}` → `{intent:'bottom', fetch:'latest'}`;
  `{atEnd:true}` → `{intent:null, scrollTo:'bottom'}`.
- `content-arrived` while `loading` → unchanged, no scroll; `empty` clears
  the intent; intent `'top'`/`'bottom'` consumed with the matching
  `scrollTo`; no intent + `atBottom` → `scrollTo:'bottom'` (sticky follow).
  ChatArea passes `atBottom: false` while `hasFragment` is set (D6).
- `scrolled {atTop:true, canAutoLoadOlder:true}` → `fetch:'older'`;
  else `{atBottom:true, hasNewer:true}` → `{intent:'bottom',
  fetch:'latest'}`; else unchanged.
- `user-scrolled` → `{intent:null}`.
- Repeated `scroll-to-top` is idempotent.

`ChatArea` changes:
- Delete `pendingScrollToTop`, `pendingScrollToBottom`, `triggeredLoadLatest`
  and `wasAtBottom` as a decision variable. One `scrollIntent` ref, one
  `atBottomRef` (input), two programmatic-scroll guards:
  - `scrollGuard` (passed to `useVirtualWindow`): the hook's measurement
    adjustments. A matching scroll skips both the intent cancellation and
    (in the hook) the range update.
  - `intentScrollGuard` (ChatArea-local): the button's own `scrollTo`. A
    matching scroll skips **only** the intent cancellation, so the range
    still recomputes from the new position.
  Both guards are cleared by a non-matching scroll only.
- The scroll listener is not gated by `hasFragment` for measurement: it
  computes `isNearTop`/`isAtBottom`, updates `atBottomRef`, skips
  `user-scrolled` on guarded events, and dispatches `scrolled`.
- Every fetch is gated by `!loadingMore` (dedup; replaces
  `triggeredLoadLatest`).
- The consumption effect is not gated by `hasFragment`; `hasFragment` only
  makes `preserveAnchor` true and masks sticky follow.
- Remove the `[chat] SCROLL-*` logs (they print deleted refs).

DoD:
- [ ] Reducer tests: idempotent top; `content-arrived {loading:true}` keeps;
      `{empty:true}` clears; `{atBottom:true}` with no intent yields sticky
      bottom; `{atTop:true, canAutoLoadOlder:true}` yields `fetch:'older'`;
      `{atBottom:true, hasNewer:true}` yields `fetch:'latest'`;
      `user-scrolled` clears; `select-session {preserveAnchor:true}` does not
      scroll; `{preserveAnchor:false}` follows.
- [ ] **Reported-repro test**: partial window (`hasMore:true`) → top click →
      `loadFromBeginning` returns `'requested'` and is called → rerender with
      the beginning chunk (`hasMore:false`) → `scrollTo({top:0})` applied.
      Also pin the failure mode: a partial window that wrongly reports
      `hasMore:false` (what the truncated backend produces) does **not**
      fetch on click — this is why WU-1 ships with WU-2..5.
- [ ] **Cache-hit test**: partial window → switch away → switch back (extent
      restored as partial) → top click → fetches the beginning again.
- [ ] **Virtualized-path test**: > 500 messages, at the bottom, top click
      with no fetch → `scrollTo({top:0})` applied **and** the rendered range
      moves to `startIndex 0` (the button's scroll is not treated as
      synthetic for the range).
- [ ] **Virtualized intent test**: a measurement adjustment matching
      `scrollGuard` does not cancel a pending intent.
- [ ] **Deep-link test**: `window.location.hash = '#x'`; session switch does
      not auto-scroll; clicking "Scroll to top" does.
- [ ] Two rapid top clicks while `loadingMore` → one request, one scroll.
- [ ] Repeated `scrolled` events while a fetch is in flight do not re-request.
- [ ] Session switch with a pending top intent scrolls to the new session's
      bottom, never a stale top.
- [ ] Sticky-bottom streaming follow still passes existing tests without a
      `wasAtBottom` decision ref.
- [ ] The two existing same-reference no-op tests pass with mocks returning
      `'unchanged'`.

Rollback: restore the three refs and their effects.

### WU-6 — Gate, docs, self-reflect, PR

- [ ] `cd frontend && npx vitest run` green.
- [ ] `cd frontend && npm run build` (tsc + vite) green.
- [ ] `make test` green; `make lint` clean.
- [ ] Update the status header of
      `docs/plans/2026-10-07-three-layer-transcript-design.md` (git-tracked)
      to record that scroll purity landed incrementally here.
- [ ] Manual smoke (documented in the PR): `make serve`, >200-entry session,
      scroll up twice, click "Scroll to top" repeatedly, switch tabs and
      back, click again — reaches entry 0.
- [ ] `self-reflect`, commit learnings, open PR (no `Closes #NN`: issues are
      human-authored here).

## Dependencies

WU-2 → WU-4. WU-3 → WU-5. WU-4 → WU-5 (`LoadResult`, derived props).
WU-1 independent in code but ships in the same PR/commit series as
WU-2..WU-5 (the frontend's `atStart` is derived from per-chunk `hasMore`).

## Backward compatibility / rollout

- Backend + frontend land together: new frontend + old backend can still
  receive a truncated `hasMore:false` and mark the window at the start. The
  PR merges both and the rollback reverts both.
- Old frontend + new backend is fine (it ignores the extra correctness and
  uses `hasMore`, which is now more often true — strictly better).
- `totalCount` remains emitted and consumed as a passthrough.

## Out of scope

- The three-layer cache rewrite in
  `docs/plans/2026-10-07-three-layer-transcript-design.md`.
- Indexed backend pagination for arbitrary cursors.
- Fixing `ttEntryCount`'s indexed-path semantics (the plan stops depending on
  it instead).
- Changing the WS wire protocol or the HTTP endpoint.

## Risks

- **Full read per backward page** — bounded by transcript size, scroll-up
  only, documented in the handler.
- **Inflated `totalCount`** — only feeds the tail/beginning `hasMore` hint,
  where over-reporting gives one extra request that succeeds.
- **Stale cursor (transcript rebuilt while open)** — an empty older chunk
  sets `olderBlocked`, so the automatic near-top load stops re-requesting;
  the explicit "Scroll to top" click still requests `__beginning__`, which
  resolves. This is the bounded no-progress rule.
- **Test churn** — existing semantics are preserved; the only updated mocks
  are the two same-reference no-op ChatArea tests (`'unchanged'`).

## Plan review gate — iteration 4 findings and dispositions

| # | Reviewer | Finding | Disposition |
|---|---|---|---|
| 1 | F | `chunk-beginning`'s `count < limit` shortcut contradicts the existing 1-entry beginning-chunk test (`isViewingLatest:false`) | **Fixed** — rule is now `atEnd = !chunkHasMore` only; DoD updated |
| 2 | F/S | `sessionId === null` → `reset` wipes entries, contradicting the documented anti-flicker invariant and its test | **Fixed** — D8: null only clears `loadingMore`/questions; `reset` is not wired to null; DoD pins the existing test |
| 3 | F/C | Reported-repro DoD claimed a cache hit restores `hasMore:true` after a beginning chunk | **Fixed** — repro now pins the partial-window case; a separate cache-hit DoD restores the *partial* extent and fetches the beginning |
| 4 | F/C | `'requested'` mocks conflict with the two existing same-reference no-op tests (`vi.fn()` → `undefined`) | **Fixed** — `'unchanged'` means no dispatch; `undefined` is treated as `'requested'`; the two tests are named and return `'unchanged'` |
| 5 | F/C | `hasMore` is non-optional in the chunk types while `chunk-error` depends on `undefined` | **Fixed** — WU-4 makes both fields optional and dispatches `chunk-error` |
| 6 | F | `isSyntheticScroll` named but absent from the WU-3 API | **Fixed** — added to the API and DoD |
| 7 | F | Missing `atBottomRef` default would break existing hook/parity tests | **Fixed** — defaults documented (`{current: true}` + private guard) |
| 8 | F | Old `syntheticScrollRef` test asserts an internal that is deleted | **Fixed** — WU-3 DoD replaces it with an observable-behaviour test |
| 9 | F/C/S | No range recompute after a guarded programmatic scroll (top click, no fetch, >500 msgs) | **Fixed** — two guards with distinct jobs: the button's scroll cancels no intent but still updates the range; DoD added |
| 10 | F | `content-arrived` cannot express fragment suppression | **Fixed** — ChatArea passes `atBottom:false` while `hasFragment` is set (D6), stated in the rule |
| 11 | C | No cache-hydration event in the reducer union | **Fixed** — `hydrate` event + DoD |
| 12 | C | Empty/missing-cursor older chunk + new auto-fetch = unbounded re-request | **Fixed** — `olderBlocked` in the extent; auto-load stops after a no-progress chunk; the explicit button still works; DoD + risk updated |
| 13 | S | `entry → atEnd:true` silently changes `isViewingLatest` for a beginning window | **Fixed** — live append leaves the extent unchanged (D8); DoD pins it |
| 14 | S | `chunk-beginning`/`hydrate` identity: `'unchanged'` premise | **Fixed** — `'unchanged'` is defined as "no dispatch"; hydration creates the state explicitly |
| 15 | C | "`transcriptRendererParity.test.ts` does not exist" | **Rebutted** — it exists and is git-tracked: `git ls-files frontend/src/hooks/__tests__/` lists `transcriptRendererParity.test.ts`; its inline `expectedVisibleRange` is at lines 1044-1057 |
| 16 | S | `handleRequestEntriesCore` is over-abstraction | **Rebutted** — round 3 blocked the plan precisely because the handler path had no exercising test; the core is ~10 lines and the real wrapper stays tiny |
