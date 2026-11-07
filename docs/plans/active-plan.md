# Active Plan
<!-- approved: 2026-11-04T00:00:00Z -->
<!-- gate-iterations: 4 -->
<!-- user-approved: true -->
<!-- status: in-progress -->
<!-- branch: frontend/transcript-scroll-purity -->

## Transcript scroll purity + scroll-to-top fix

Full plan: `docs/plans/2026-11-04-transcript-scroll-purity-plan.md` (rev 5).

Root cause: the WS `before`-cursor read was truncated to the last
`limit * 3` entries, so `hasMore` lied after a couple of backward pages; the
client copied that boolean into `hasMore` + a module cache, and the
"Scroll to top" button fell back to scrolling the loaded slice.

Approach:

1. Backend: `readLimitFor` / `shapeChunk` / `handleRequestEntriesCore` — a
   `before` cursor reads the whole list; the handler core is testable with an
   injected reader/sink.
2. Frontend: one pure reducer owns `{entries, windowExtent}`; `hasMore` and
   `isViewingLatest` are derived.
3. Frontend: one pure scroll-intent reducer replaces
   `pendingScrollToTop` / `pendingScrollToBottom` / `triggeredLoadLatest` /
   `wasAtBottom`.
4. Virtual window math extracted to pure functions; one shared scroll guard
   with two jobs (measurement vs. button scroll).

Work-unit status:

- [x] WU-1 backend pagination + handler core (+ StreamSpec)
- [x] WU-2 pure transcript reducer (+ tests)
- [x] WU-3 pure scroll math + virtual-window adoption (+ tests)
- [x] WU-4 hook wiring, derived flags, cache extent (+ tests)
- [x] WU-5 single scroll intent in ChatArea (+ tests)
- [x] WU-6 self-reflect, commit, PR (adversarial review round fixed the
      bottom-scroll guard, the per-effect-run initial flag, the
      duplicate-chunk retry loop, and restored the render profiler)

Gates run: frontend `vitest` 775 passed, `tsc && vite build` green;
Haskell `cabal test` 3416 examples / 0 failures / 41 pending; `hlint`
No hints.
