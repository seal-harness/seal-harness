# Session Token Count — implementation plan (rev 3)

**Issue:** web frontend shows a `Tokens` count in the status bar that changes
when the user scrolls the transcript. Scrolling must never change the session's
token count.

**Reporter symptom:** "Fairly often I see incorrect `Tokens` count numbers in
the status bar at the bottom of the transcript view in the web frontend. I know
they're wrong because if I refresh the page the `Tokens` count changes.
Scrolling around in the transcript should never change the session's token
count."

## Root cause (verified)

The count is derived from the *scroll window*, not the session.

1. `frontend/src/App.tsx:1061`

   ```ts
   const tokensUsed = useMemo(() => computeTokensUsed(entries), [entries])
   ```

   `entries` is the **loaded chunk window** (`useTranscriptStream` holds ~50
   entries at a time), not the full session transcript.

2. `frontend/src/lib/transcriptState.ts:159-176` — the reducer **replaces** that
   window wholesale on scroll:
   - `chunk-beginning` (scroll to top) replaces `entries` with only the
     **oldest** 50 (`:172-175`).
   - `chunk-latest` / `seed` (scroll to bottom, refresh) replaces with only the
     **newest** 50 (`:162-167`).
   - `chunk-older` prepends 50 more (`:175-176`), so the count **grows** as you
     scroll up.

   A refresh re-seeds to the newest 50, which is why the number "jumps back".

3. `frontend/src/components/ChatArea.tsx:2331` —
   `return lastInputTokens + totalOutputTokens`. Independent second bug:
   `input_tokens` of the latest turn already includes every prior turn's output,
   so adding the cumulative `output_tokens` sum (`:2316`) overstates the value.

The metric is a property of the **session** being derived from a property of the
**viewport** — so any windowing UI makes it drift.

## Scope decisions

- **No UI change to the status bar (operator clarification).** The operator
  originally reported *"it's currently only showing a count"* and asked only for
  a count. Asked whether to remove the percentage, they clarified: *"Oh, I guess
  it's just not showing the percentage because the context window isn't known."*

  That matches the code exactly: `BottomBar.tsx:37-52` renders
  `178.3k / 200k (89%)` **only when `contextWindow > 0`**, and falls back to the
  bare count otherwise. For models whose window is unknown — the operator's
  case — the status bar already renders `Tokens 178.3k`. **So there is nothing
  to remove.** `BottomBar`, its `contextWindow` prop, the `ProgressBar`, and the
  `fetchModelContext` effect in `ChatArea` all stay untouched.

  Consequence: this fix is **backend + one line of `App.tsx`**, with zero
  user-visible UI change except that the number becomes correct. Where a
  context window *is* known, the percentage keeps working and simply gets a
  correct numerator for free.
- **True value, from the session, not the window.** A frontend-only "sticky
  last value" was rejected as unreliable.
- **No fabricated estimate.** If no response has recorded usage, show the count
  as unknown rather than synthesising one. (Dropped from rev 2 — see
  "Deliberately excluded".)

### The efficient path already exists

The gateway already reads exactly the data needed, for every session, on every
sidebar snapshot:

- `lastUserMessageAtFast` reads `entries.jsonl` — *"avg ~128KB, vs 2.7MB for
  conversation.jsonl"* (`Transcript.hs:1025-1039`) — and is called per session
  by `sessionInfoJsonWithSnippet` (`SessionJson.hs:104`), which
  `buildListsSnapshot` maps concurrently over all sessions
  (`ListsSnapshot.hs:53-55`).
- That snapshot is already streamed to the frontend as the WS `lists` frame and
  consumed by `useListsStream` (`useListsStream.ts:20`).
- A fresh snapshot is broadcast after a **web** turn via `triggerBroadcast`
  (`Send.hs:736-740`); WU-3 adds a client-side refetch on the turn-idle
  signal so other channels refresh too, without touching that call graph.

`entries.jsonl` stores payload-free per-response usage:
`EntryRecord.erUsage :: Maybe Usage` (`Entries.hs:176`), written on every
`EKResponse` (`Agent/Loop.hs:435`).

**One read, two fields.** `lastUserMessageAtFast` currently parses the whole
file just to find one timestamp (`Transcript.hs:1031-1039`). WU-1 widens that
function to return the token count from the *same* parsed entry list, so the
per-session cost does not increase: one `entries.jsonl` read still yields both
`lastUserMessageAt` and `tokensUsed`.

**So the whole fix is: return `tokensUsed` as one more field of the JSON that is
already being built from a file that is already being read.** No new route, no
new hook, no new cache, no index change, no backfill, no polling.

The displayed value is the **reported** `input + output` of the most recent
response with non-zero usage. Note `Usage` (`Providers/Class.hs:230`) carries
only those two fields — Anthropic's `cache_read_input_tokens` /
`cache_creation_input_tokens` are never parsed (`Anthropic.hs:155-161`), so the
number is what the provider reported, not a cache-aware total. Document it as
"tokens reported for the last turn", not as an exact tokenizer count.
`Usage 0 0` is emitted only on abnormal stream-end paths (`Ollama.hs:482`,
`:522`), so zero usage must not count as a measurement; the reader falls back to
the previous non-zero response.

**The wire shape is `{input_tokens, output_tokens}`** — the backend rewrites the
GHC-generic `{input, output}` names before serving
(`Transcript.hs:822-832`), matching what the frontend already reads
(`ChatArea.tsx:2316`).

---

### WU-1 — widen the existing fast reader (Haskell, TDD)

**Files**
- `src/Seal/Gateway/Transcript.hs` — widen `lastUserMessageAtFast` **and add
  `SessionEntryFacts (..)` + `sessionEntryFactsFast` to the explicit export
  list** (`Transcript.hs:12-32`), which `SessionJson.hs:23` imports
- `test/Seal/Gateway/TranscriptSpec.hs` (exists)

**No backend broadcast changes.** An earlier draft planned to add
`broadcastListsSnapshot` to `Seal.Core.TurnEngine`. That was dropped: `:1185`
turns out to be a per-tool-call branch (`SETUP_REPO`), not a turn-end site;
`:750` is the per-entry streaming callback (a full multi-session rebuild per
entry); the surviving `Send.hs:709` broadcast fires *after* the auto-tab is
created while a `TurnEngine`-internal one would fire *before*, changing
ordering; and `Send.hs:663`/`:672` are `/new` and slash-command mutations that
never enter `TurnEngine`, so removing them would stop new sessions appearing in
the sidebar at all. Touching that call graph to refresh one integer is not
worth the risk. Freshness is handled in the UI instead (WU-3) using a signal
that already exists.

**Behaviour**

`lastUserMessageAtFast` already reads and parses all of `entries.jsonl`
(`:1031-1039`). Widen it to return both facts from that one parse instead of
adding a second reader:

```haskell
-- | The two per-session facts derived from entries.jsonl, computed in ONE
-- pass: the last request timestamp (sidebar sort) and the context occupancy
-- (input+output of the most recent response that reported non-zero usage).
data SessionEntryFacts = SessionEntryFacts
  { sefLastUserMessageAt :: Maybe Text
  , sefTokensUsed        :: Maybe Int
  }

sessionEntryFactsFast :: SealPaths -> SessionId -> IO SessionEntryFacts
```

- Parse once with `parseEntryRecordsLazy` (`:1044`).
- `Transcript.hs:51` imports `ContentBlock`/`Message`/`Role` but **not**
  `Usage (..)`, so pattern-matching `Just (Usage uIn uOut)` needs that import
  added.
- `sefLastUserMessageAt` = existing `lastRequestTs` logic (`:1049-1057`).
- `sefTokensUsed` = `uIn + uOut` of the last `EKResponse` with
  `Just (Usage uIn uOut)` where `uIn + uOut > 0`; `Nothing` if none.
- No `entries.jsonl` ⇒ both `Nothing`.
- Keep `lastUserMessageAtFast` in WU-1 (its caller at `SessionJson.hs:105` still
  exists), so WU-1 alone compiles and its `make check` DoD is achievable.
  WU-2 switches that caller to `sessionEntryFactsFast` and **then** deletes
  `lastUserMessageAtFast` + its export (`Transcript.hs:24`) — no caller-less
  wrapper survives, and each unit is independently green.

- **Freshness is out of scope for this unit.** WU-1 is a pure reader; how often
  the value is refetched is WU-3's concern.

**Tests (red first)**
- Three responses (100/20, 150/30, 400/50) ⇒ `Just 450` — last occupancy only,
  not a cumulative sum.
- Last response `usage {input:0, output:0}` ⇒ falls back to the previous
  non-zero response.
- No `entries.jsonl` ⇒ both fields `Nothing`.
- Only zero-usage responses ⇒ `Just timestamp`, `Nothing` tokens.
- Legacy `transcript.jsonl`-only session (no `entries.jsonl`) ⇒ `Nothing`.
- `sefLastUserMessageAt` unchanged vs. the current behaviour (regression).
- **Turn in progress** (an `EKRequest` with no completed `EKResponse` yet) ⇒
  the previous turn's occupancy is returned, unchanged by the new request.
  This is the boundary the old window-derived number got wrong.
- **Scroll-independence at the unit level:** the result depends only on file
  contents, so it cannot vary with any viewport.

**DoD**
- [ ] Failing tests first, observed red.
- [ ] One `entries.jsonl` read per session (no second file read added).
- [ ] `make check` green.

---

### WU-2 — expose `tokensUsed` on `SessionInfo` (Haskell, TDD)

**Files**
- `src/Seal/Gateway/SessionJson.hs`
- `src/Seal/Gateway/Transcript.hs` (remove the now-caller-less
  `lastUserMessageAtFast` + its export)
- `test/Seal/Gateway/ApiSpec.hs`

**Behaviour**

- `sessionInfoJson` gains a `Maybe Int` `tokensUsed` argument, encoded as
  `"tokensUsed" .= (Maybe Int)`.
- `sessionInfoJsonWithSnippet` replaces its single `lastUserMessageAtFast` call
  (`:105`) with one `sessionEntryFactsFast` call, passing both
  `sefLastUserMessageAt` and `sefTokensUsed`. Still exactly one `entries.jsonl`
  read per session.
- Delete `lastUserMessageAtFast` and its export (`Transcript.hs:24`) now that
  its one caller is gone — no caller-less wrapper is left behind.

Because `sessionInfoJsonWithSnippet` is the single builder used by
`GET /api/sessions`, `GET /api/sessions/archived` (`API.hs:348,354`) **and** the
WS `lists` snapshot (`ListsSnapshot.hs:53-55`), the field appears on all three
surfaces with no route or snapshot-plumbing change.

**Tests**
- A session fixture with known usage surfaces `"tokensUsed": 450` in the
  `/api/sessions` payload.
- A session with no recorded usage surfaces `"tokensUsed": null`.
- `GET /api/lists` / the `lists` snapshot carries the same value (proves the
  snapshot path, not just the REST path).

**DoD**
- [ ] Failing tests first.
- [ ] Field present on REST + snapshot; `Nothing` ⇒ JSON `null`.
- [ ] `make check` green.

---

### WU-3 — consume it in the status bar; delete the window-derived helper
(frontend, TDD)

**Files**
- `frontend/src/types.ts` (`SessionInfo.tokensUsed?: number | null`)
- `frontend/src/App.tsx` (replace `:1061`; refetch lists on turn-idle)
- `frontend/src/hooks/useListsStream.ts` — add a `refresh()` that re-fetches
  `GET /api/lists` and applies the snapshot through the same `onLists` state
  setter. (`useListsPoll` cannot serve this: it is disabled whenever the WS is
  live — `App.tsx:213` — which is the normal case.)
- `frontend/src/components/ChatArea.tsx` (delete `computeTokensUsed`)
- Test fixtures that construct `SessionInfo` (see below)
- Tests: `ChatArea.test.tsx`, `App.test.tsx`,
  `frontend/src/hooks/__tests__/useStreams.test.ts` (`useListsStream.refresh`)

**Behaviour**
- Add **optional** `tokensUsed?: number | null` to `SessionInfo`
  (`types.ts:36`), matching the repo's existing old-server-tolerant convention
  for this exact object (`sealFrontMatter?: boolean`, `types.ts:64-71`:
  *"Optional so the SPA still works against an older server that omits the
  field"*). A server that predates this change therefore still works, and
  `undefined` reads as "unknown" → `0`.
- `App.tsx`: replace the `computeTokensUsed(entries)` memo with
  `selectedSession?.tokensUsed ?? 0`.
- **Refetch on turn completion** so the number is current for turns from any
  channel. `streamClient().onActivity` (`types/stream.ts:245`) already delivers
  `harness-status` frames for the focused session; on an `idle` transition call
  the new `wsLists.refresh()`. This is additive client-side wiring — **no
  backend change** — and the value always comes from the server, so it cannot
  drift or be attributed to the wrong session. Debounce so a burst of idle
  frames triggers at most one refetch. (This mirrors what
  `useTranscriptStream` already does on the same signal,
  `useTranscriptStream.ts:206-215`.)
- Delete `computeTokensUsed` (`ChatArea.tsx:2299-2344`). This deletion is the
  structural guarantee that the UI cannot recompute the metric from the window.
  `ChatArea` keeps its `tokensUsed` prop. Remove the now-dead imports at
  `App.tsx:4` and `ChatArea.test.tsx:3` (`noUnusedLocals` fails `tsc`
  otherwise — `tsconfig.json:15`).
- **Also delete `payloadStrLen` (`ChatArea.tsx:1876`).** Its only two call sites
  are `:2308` and `:2339` — both inside `computeTokensUsed`. Leaving it would
  orphan a private function and fail `npm run build` under `noUnusedLocals`
  (`tsconfig.json:15`), which `make check` runs. The DoD below greps for it.

**Existing fixtures are unaffected.** Because the field is optional, the
`SessionInfo` fixtures at `types.test.ts:15`, `tabStatus.test.ts:6`,
`ChatArea.test.tsx:20`, `HarnessControls.test.tsx:8`, `Sidebar.test.tsx:10`,
`App.test.tsx:83`, `useApi.test.ts:110`/`:145`, and `useStreams.test.ts:92`
compile unchanged. Only tests that assert a rendered count need an explicit
`tokensUsed` value added to their fixture.

**Tests**
- `App` renders the count from `selectedSession.tokensUsed`, not from `entries`.
- **Regression test for the reported bug:** render with different
  window/`messages` contents and the same `SessionInfo.tokensUsed` ⇒ identical
  displayed count. This encodes "scrolling never changes the count".
- Switching sessions shows the newly-selected session's count, never the
  previous one's.
- An `idle` activity frame triggers exactly one `/api/lists` refetch
  (debounced), and the refreshed `tokensUsed` is displayed.
- A `SessionInfo` omitting `tokensUsed` renders `0` (old-server tolerance).
- Delete the `computeTokensUsed` describe block (`ChatArea.test.tsx:1360-1395`).
- `App.test.tsx:163` (`getByText('Tokens')`) still passes.

**DoD**
- [ ] Failing tests first.
- [ ] `grep` finds no `computeTokensUsed` **and no `payloadStrLen`**.
- [ ] `npm test` green; `npm run build` (tsc) clean — `tsconfig.json:15-16` has
      `noUnusedLocals`/`noUnusedParameters`, so dead imports fail the build.
- [ ] `make check` green.

---

## Deliberately excluded (and why)

- **A `/api/sessions/:id/stats` route.** Rev 2 added one. Dropped: the value
  fits on `SessionInfo`, which is built by widening an `entries.jsonl` read
  that already happens per session, and is already streamed. A route
  would mean a `Route.hs` constructor + `routeMeta` arm + `allRoutes` entry +
  `OpenApi.hs` arm + `expectedRouteCount` bump (`ApiRouteSpec.hs:19`, currently
  `81`) + a dispatch arm — five touch points for a number the sidebar payload
  already carries.
- **An `ApiDeps` memo.** Dropped: unnecessary once there is no dedicated
  endpoint, and it would have forced edits to ~30 `ApiDeps` literals across 7
  test files.
- **An estimate fallback.** Dropped. The operator asked for the *true* count and
  rejected an unreliable substitute; `computeTokensUsed`'s discarded fallback
  was itself `Math.ceil(len/4)` (`ChatArea.tsx:2308`) and the repo's own
  heuristic is chars/4 (`ContextTruncation.hs:60-67`). A bytes/4 estimate with a
  hand-tuned calibration constant is the same class of guess. Ollama reports
  real usage on the normal path (`Ollama.hs:204-210`); `0 0` is only the
  abnormal stream-end path. Unknown therefore renders as `0` — honest, and it
  is what the frontend already does for a missing value today
  (`ChatArea.tsx:2950`, `resolvedTokensUsed = tokensUsed ?? 0`).
- **A `conversation.idx` change.** Not needed: the last response's `erUsage` is
  the answer, and it is already stored.

## Verification

- `make check` (build + test + lint + frontend) green — the local gate CI runs.
- `cd frontend && npm test` green.
- Manual: open a long session, scroll top/bottom repeatedly — the number must
  not change. Refresh — identical. Complete a web turn — updates. Complete a
  **Telegram** turn with the session open in the browser — the number updates
  on that turn's idle frame. Switch sessions and back — the value is correct
  for each. Where the model's context window is known, the existing
  `178.3k / 200k (89%)` display keeps working with a correct numerator.
- **Known limitation (pre-existing, not introduced here):** an out-of-process
  CLI/TUI turn emits no activity frame (its `tdBroker` is `Nothing`,
  `Cli.hs:317`), so a browser looking at that session refreshes only on its next
  own interaction. The same is already true of the transcript's idle re-seed
  (`useTranscriptStream.ts:206-215`) and of `lastUserMessageAt` — this change
  neither causes nor worsens it.

## Risks / notes

- **Semantics documented** in the module doc so nobody later "fixes"
  `tokensUsed` into a cumulative sum.
- **`null` vs `0`:** `null` distinguishes "no usage recorded" from a genuine
  zero. The UI renders both as `0` (existing behaviour), but the wire keeps the
  distinction so a later UI change can say "unknown" without a backend change.
- **No new endpoint, no index change, no backfill migration, no new cache.**
- **Freshness via an existing client signal.** The status-bar value refetches
  when the focused session's turn goes idle — the `harness-status: idle`
  activity frame (`TurnEngine.hs:563`/`:595`), which `useTranscriptStream`
  already consumes for its consistency re-seed (`useTranscriptStream.ts:206-215`).
  This is the same freshness contract the transcript view already relies on, so
  no backend change is needed and no cached value can shadow a newer one (the
  refetch overwrites state rather than layering over it). Broker-less
  out-of-process CLI/TUI turns are the one case that emits nothing — a
  pre-existing limitation shared with the transcript re-seed.
- **No stale-value cache.** There is no client-held token value beyond the
  last `SessionInfo` payload, so the cross-session-attribution and
  stale-overlay failure modes of an `onEntry` overlay cannot occur.
- **Efficiency is bounded, not increased.** `sessionEntryFactsFast` replaces the
  existing `lastUserMessageAtFast` parse rather than adding to it, so
  `entries.jsonl` is still read once per session per snapshot. If profiling ever
  shows this matters, the contained follow-up is a reverse-tail read; it is
  deliberately not part of this fix.

## Rollback / backward compatibility

- **Additive and independently revertable.** The wire change is one new
  optional field; the app reverts by restoring the `computeTokensUsed` memo in
  `App.tsx` and ignoring the field. No stored data changes, so no migration to
  undo. There is no UI change to revert.
- **Old servers:** `tokensUsed` is optional on `SessionInfo`
  (`types.ts:64-71` convention), so the SPA against a pre-change server reads
  `undefined` → `0` rather than failing or rendering `NaN`.
- **Old sessions:** sessions with no `entries.jsonl` (conv-only / legacy
  `transcript.jsonl`) yield `Nothing` → `null` → `0`. No backfill needed. This
  is a knowing trade: such sessions show `0` instead of a drifting estimate.
  WU-1 adds a test asserting the legacy-only path yields `Nothing`.
- **Legacy live entries carry no rewritten usage.** The legacy wire path
  (`teLineToFrontend`, `Transcript.hs:460-512`) ships `payload` verbatim, unlike
  the reconstructed path which rewrites it (`:822-838`). This does **not**
  affect this fix: the value is computed server-side from `entries.jsonl`, not
  from the wire payload. Noted only so a future live-client feature doesn't
  assume `input_tokens` is present on legacy entries.
