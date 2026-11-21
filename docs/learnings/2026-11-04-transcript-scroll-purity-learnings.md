# Transcript scroll-to-top: purity refactor and root cause (2026-11-04)

## Symptoms → root cause

The "Scroll to top" button silently stopped working after scrolling up a long
transcript; switching sessions did not help; a hard refresh did.

Root cause was a **server-side truncation bug amplified by client-side
state**:

- `handleRequestEntries` read only `ReadLastN (limit * 3)` for a `before`
  cursor, then searched that window for the cursor. Past ~2 pages the cursor
  was missing (`([], False)`) or `hasMore` was computed inside the truncated
  window (false while older entries existed).
- The client copied that boolean into `hasMore` and into a module-level
  cache. With no other source of truth, the flag stayed wrong for the page's
  lifetime; only the HTTP seed (hard refresh) recomputed it.
- The button's non-`hasMore` branch was a bare `scrollTo({top: 0})` — the top
  of the loaded slice, not the transcript.

## Durable lessons

1. **Never store a derived availability flag that the server also sends.**
   Track the window extent (`atStart`, `atEnd`) in the same pure reducer as
   the entries and derive `hasOlder`/`isViewingLatest`. A boolean that is
   written from two places (chunk response, cache hit) drifts and can only be
   repaired by a reload.
2. **A cursor must be searchable in the data you read.** Any
   `before=<id>` pagination that truncates the read before searching will
   eventually return "not found" mid-transcript. Read the whole list for
   cursor requests; keep bounded reads only for "first N"/"last N".
3. **`ttEntryCount` is not the frontend entry count** on the indexed path
   (`length evs + trailingCount` can exceed the reconstructed list after
   `zipWithMaybe` drops). Do not use it for index arithmetic; at most as a
   conservative hint.
4. **Programmatic scroll classification belongs in a pure function.** A
   sticky boolean guard (`syntheticScrollRef`) deadens scrolling when the
   browser coalesces the expected event. Use an expected-value comparison, and
   clear it only on a *non-matching* event so two listeners on the same event
   cannot disarm each other.
5. **Two programmatic-scroll guards with different jobs:** the virtual
   window's measurement adjustment must suppress both the range update and
   intent cancellation; the button's own scroll must suppress only intent
   cancellation (the range still needs recomputing).
6. **Plan review is worth the iteration.** Round 3 caught a contradiction in
   the plan's own DoD (a `hasMore:false` chunk could not both mean "keep
   hasOlder" and "mark atStart"). Reading the old test fixtures against each
   new rule before submitting would have caught it one round earlier.

## Test-writing lessons

- jsdom's `scrollTo` is a stub and `scrollHeight` is 0, so "was scrollTo
  called?" can pass for the wrong reason (a stray sticky-bottom scroll).
  Assert the specific target (`{ top: 0 }`) and that the expected fetch was
  called.
- Module-level caches leak across tests in the same file. A test that seeds a
  session and does not reset the cache will make the next test's first render
  a cache hit. Existing suites may already depend on the leak; when changing
  a cache writer, do not add writes the old code did not do (the re-seed merge
  branch was the one that broke).
