# Session Partition Invariants — Design

**Date:** 2026-07-25
**Branch:** `feat/session-partition-invariants`
**Status:** Draft (iteration 2 — addresses Design Review Gate round 1 feedback)

## Problem

The web frontend sidebar renders three sections — **Active Tabs**, **Recent Sessions**, and **Archived** — but the running session associated with an active tab currently appears in BOTH "Active Tabs" (via `tabs[].session_id`) AND "Recent Sessions" (via `/api/sessions`, which returns every non-archived on-disk session). This redundancy wastes screen real estate and obscures the categorization.

### User personas

- **Zoe (web user).** Lives in the web SPA. Creates sessions via the "Recent Sessions +" button or `/api/tabs/new` composer. Sends via the chat input. Today, a session she's actively chatting in shows up twice — once in "Active Tabs" (the tab she opened) and once in "Recent Sessions" (the same session from `/api/sessions`). She scans the sidebar to re-find a conversation; the duplicate makes her pause to figure out which row is the "real" one.
- **Maya (cross-channel user).** Uses Signal for async replies and the web SPA for heavy lifting. She creates a session in the web UI, then steps away and replies from Signal. Today the Signal send goes to the same session but no web tab reflects the activity — the tab list and the session list are disconnected surfaces.
- **Sam (operator).** Runs `seal serve` on a long-lived box. Restarts the server for an upgrade. Today, every open tab vanishes on restart — Sam has to remember which sessions were active and re-open each one. With many harness tabs, the harness registry starts fresh and orphans the windows.

### Use cases (WHO/WANTS/SO THAT/WHEN)

1. **WHO** Zoe **WANTS** to locate an active conversation in the sidebar without scanning duplicates **SO THAT** she can jump back to it in one click **WHEN** she has several sessions open across tabs.
2. **WHO** Maya **WANTS** a message she sends from Signal to surface as a tab in the web sidebar **SO THAT** she can pick up the conversation in the web UI later **WHEN** she sends to a session that has no web tab.
3. **WHO** Sam **WANTS** his open tabs to survive a `seal serve` restart **SO THAT** he doesn't have to re-open every session **WHEN** he upgrades the server.
4. **WHO** Zoe **WANTS** archived sessions to stay archived (out of Recent Sessions) **SO THAT** the Recent list stays short **WHEN** she has many old sessions.
5. **WHO** Any user **WANTS** the three sidebar sections to never overlap **SO THAT** a session is in exactly one place **WHEN** they scan the sidebar.

### User benefits (measurable)

- **0 sessions appear in more than one sidebar section** (verifiable via the `partitionSessions` property test + an E2E assertion).
- **Sidebar scan time to locate a known active session reduced** — today Zoe must disambiguate a duplicate; after the partition the active session is in "Active Tabs" only. Qualitative; a user-satisfaction signal (GitHub issue follow-up) is the evaluation mechanism since the project has no telemetry.
- **Tabs survive restart** — verifiable: boot with `tabs.json` containing N tabs → after boot, `snapshotTabs` returns N tabs (with harness-orphan reconcile applied). Failure/rollback criterion: if users report they can no longer find sessions that "disappeared" from Recent Sessions (the partition is wrong for their workflow), we roll back the dedup and revisit the categorization.

### Scope

- **MVP (this PR):** partition invariant (W1, W6, W7), auto-tab on send across all paths (W2, W3), unified shared `TabsHandle` in `seal serve` (W4), tab persistence + boot reconcile (W5).
- **Deferred (follow-up epic, designed-for not built):** the "any channel can interact with any tab" UX polish — e.g. a Signal user runs `/tab focus 2` to operate on a web-created tab. The shared handle makes this possible; the UX work is separate.

## Invariants

1. **Partition.** The three sections — "Active Tabs", "Recent Sessions", "Archived" — partition the space of sessions. Every session is categorized into exactly one.
2. **Auto-tab on send.** Any message sent to a session that has no active tab creates a new tab (unless the session is an AGENT_START sub-session).
3. **Unified, persistent tab list (supporting).** A single tab list shared across all channels (web, Signal, Telegram, CLI) under `seal serve`, preserved across `seal serve` restarts. Implemented now; the "any channel can interact with any tab" UX is the follow-up.

## Current State (findings from exploration)

- **Sidebar sections.** `frontend/src/components/Sidebar.tsx` renders `ActiveTabs`, `RunningHarnesses` (a split-out subset of tabs where `kind === 'harness'`), a `RecentSessionsHeader` + session rows, and an `ArchivedSection`. The redundancy: `recentSessions = sessions` (line 269) where `sessions` comes from `/api/sessions` and includes tab-backed sessions.
- **Intentional harness dual-listing (preserved).** `Sidebar.tsx:266-268` documents that a running harness's backing session is INTENTIONALLY also listed under "Recent Sessions" so the user can jump straight to the conversation. The partition rule preserves this: `handleTabNew`'s harness branch (`API.hs:458`) inserts a `BoundHarness hid` tab WITHOUT calling `newSession`, so harness tabs carry `session_id: null`. A `BoundHarness` tab therefore pulls NO session into `psTabSessions`, and the harness's backing session (if any exists on disk) stays in `psRecentSessions`. The dual-listing is preserved by construction. (Confirmed: harness tabs acquire no `session_id`; the comment is accurate, not dead.)
- **`findSession` aspirational lie.** `frontend/src/types.ts:136` claims tab-backed sessions are "deduped OUT of recents/archived by the backend," but `Seal.Session.Store.listSessions` returns ALL non-archived on-disk sessions — no dedup. This design makes the comment true; W7 updates the comment to past-tense ("are deduped OUT by the backend") so it's not misread as aspirational.
- **Dormant WS path.** `Seal.Gateway.StreamBroker.broadcastLists` is wired (the `BeListsSnapshot` event + the `broadcastLists` helper exist and the WS `Stream.hs` forwards them) but **never invoked from production code**. The frontend's `useListsStream` hook subscribes to a `lists` frame that never arrives; `App.tsx` falls back to REST polling (`useTabs` + `useRecentSessions` + `useArchivedSessions`, each on a 2s interval). `tabSessions` is always `[]` in practice.
- **Per-channel tab handles.** `Seal.Command.Serve` creates one `tabsH <- newTabsHandle` for the web (line 105) and each channel listener forks its own (Signal line 276, Telegram line 312). The standalone `seal signal` / `seal telegram` entry points also create their own. Tabs created in a channel listener are invisible to the web sidebar.
- **Tab persistence stub.** `Seal.Tabs.Persist` exists but is a no-op stub (`saveTabList _h = pure ()`, `loadTabList = pure Nothing`). Tabs are in-memory only; a `seal serve` restart loses the tab list.
- **Sub-sessions already excluded.** AGENT_START children live under `<parent>/agents/<child>/` (`Seal.Config.Paths.agentSessionDir`). `listSessions` reads only direct children of `sessionsRoot`, so sub-sessions never appear in the sessions list. `loadSessionMeta paths sid` reads `sessionsRoot/<sid>/session.json` — a sub-session id never resolves there. Invariant 1 is already satisfied for sub-sessions; the partition work doesn't special-case them.
- **No auto-tab on send.** `handleSend` (`Seal.Gateway.Send.hs:216`) runs `plainTurn` and returns; it never inserts a tab. The channel `createConversationSession` (`Seal.Channels.Loop.hs:395`) DOES insert a tab on first message from a conversation, but a session created via the web "Recent Sessions +" button (`/api/sessions/new`) then messaged via Signal would not get a tab on the Signal side.
- **TabKind constructors.** `Seal.Handles.Tab.hs:59` defines `KindAi | KindProvider | KindHarness | KindShell | KindSsh | KindTmux`. Wire mapping (`API.hs:1063-1065`): `KindHarness → "harness"`, `KindProvider → "session:provider"`, `KindAi → "session:ai"`. The web `handleTabNew` provider branch uses `KindProvider` (`API.hs:453`); channels and the CLI use `KindAi` (`Loop.hs:405`, `Cli.hs:682`, `Tab.hs:95`). Both render in "Active Tabs" (only `KindHarness` is split out to "Running Harnesses"), so the partition is unaffected by the choice — but for consistency, the auto-tab `TabKind` matches the calling surface.

## Approach

**Chosen: Approach A — Backend dedup at the source.** The backend owns the partition. A pure function computes the three mutually-exclusive lists from the tab list + the on-disk session lists; this partition is emitted via the (finally-activated) WS `lists` frame and a new `/api/lists` REST endpoint. The frontend renders what it's given; the `findSession` fallback chain stays as a defensive lookup. The CLI `tabs`/`session list` commands and any future surface get the partition for free.

Rejected alternatives:
- **B (frontend-only dedup)** — leaves the invariant in one renderer; channel sends and the CLI keep showing duplicates.
- **C (backend tags a `section` field)** — cleanest wire shape but breaks the existing `ListsSnapshot` TS contract and forces a frontend refactor of every consumer; more churn than A for the same guarantee.

## Design

### Section 1 — The partition step (Approach A)

A pure function:

```haskell
data PartitionedSessions = PartitionedSessions
  { psTabSessions     :: [SessionMeta]   -- wire key: "tabSessions"
  , psRecentSessions  :: [SessionMeta]   -- wire key: "recentSessions"
  , psArchivedSessions :: [SessionMeta]  -- wire key: "archivedSessions"
  }

partitionSessions :: TabList -> [SessionMeta] -> [SessionMeta] -> PartitionedSessions
```

- **Inputs:** the current `TabList` (from the shared `TabsHandle`), `listSessions paths` (non-archived), `listArchivedSessions paths`.
- **Rule:** a session `s` goes into `psTabSessions` iff some tab's `tRef == BoundSession (smId s)`; else into `psRecentSessions` iff not archived; else into `psArchivedSessions`. Haddock notes map the `ps`-prefixed Haskell fields to the un-prefixed wire keys to prevent a `tabSessions`/`psTabSessions` mismatch bug.
- **Mutual exclusion** is by construction (a session appears in exactly one of the three). **Completeness** — every non-archived on-disk session is in either `psTabSessions` or `psRecentSessions`; every archived is in `psArchivedSessions`.
- **Archived + tab-bound edge case.** A session that is BOTH archived AND tab-bound is categorized into `psTabSessions` (the tab wins). This is intentional: the user has an open tab on it, so hiding it from "Active Tabs" would be confusing. The archive flag stays on disk; if the user closes the tab, the session returns to `psArchivedSessions`. (Acceptance criterion: an archived+tab-bound session renders in "Active Tabs" only, never in both "Active Tabs" and "Archived".)
- **Harness tabs** (`BoundHarness hid`) carry no `session_id`, so they don't pull any session into `psTabSessions`. The intentional harness dual-listing is preserved: a harness's backing session (if it exists on disk) stays in `psRecentSessions`. They render in "Active Tabs" / "Running Harnesses" via the tab list alone, unchanged.
- **Sub-sessions** never appear (not in either `list*` output, and `loadSessionMeta` doesn't resolve them) — no special-casing needed.

`listSessions` and `listArchivedSessions` stay as-is (raw on-disk truth); the partition layers on top.

### Section 2 — Unified, persistent tab list

**Single shared handle.** Replace the three `tabsH <- newTabsHandle` sites in `seal serve` (web `Serve.hs:105`, Signal `:276`, Telegram `:312`) with one handle created once and threaded into `ChannelDeps` as a new `cdTabs :: TabsHandle` field. `runChannelLoop` already takes `tabsH` as a parameter — keep the signature, pass the shared one. The standalone `seal signal` / `seal telegram` commands (no web) keep their own `newTabsHandle` since there's no web surface to unify with. **Behavior change (deliberate, not a wire change):** channel-created tabs were previously invisible to the web sidebar; under the shared handle they appear there. This is the intended cross-channel visibility (use case 2).

**Persistence (wrapper approach — committed to).** Implement `Seal.Tabs.Persist` for real. TVars cannot be watched without polling, so the wrapper approach is the only implementable option: each mutation (`insertTabH`/`removeTabH`/`rebindTabH`/`renameTabH`) persists after the STM transaction commits via a thin `persisting` wrapper around the `TabsHandle` API (or a `saveTabList` call at each mutation site, mirroring how `persistUiState` is invoked explicitly at each mutation in `UiState`). The wrapper holds an `MVar ()` to **serialize writes** so concurrent tab mutations cannot interleave file writes (per the security reviewer's required mitigation):
- `saveTabList :: TabsHandle -> IO ()` writes `TabList` as JSON to `<state>/tabs.json` atomically (mirror `Seal.Web.UiState.persistUiState`: write `.tmp`, `renameFile`), **with file mode `0600`** (matches the `session.json` precedent in `saveSessionMeta`; `tabs.json` reveals which sessions are active + harness ids — operator metadata worth protecting on multi-user hosts).
- `loadTabList :: IO (Maybe TabList)` reads it at boot. Missing file → `Nothing` (fresh empty list). Corrupt JSON → `Nothing` + stderr warning (ids + error type only, no session content — self-heals on next write).
- **`loadTabList` validates every `TabRef` id** via `mkSessionId`/`mkHarnessId` on decode and **skips** (not errors) any tab carrying an unparseable id — defense-in-depth against a tampered `tabs.json` (per the security reviewer's required mitigation).

**Boot-time reconcile-to-orphaned.** On startup: `loadTabList` → seed the `TVar` → reconcile pass:
- For each `BoundHarness hid` tab, run one `reconcileTick` over the persisted hid(s) **before** the periodic sweep starts, so surviving windows are marked `running` and missing ones `orphaned` at boot. The harness registry is fresh (empty) at boot; `reconcileTick` reads tmux markers via the runner and populates the registry. (Sequencing: boot reconcile runs the existing `Seal.Harness.Reconcile` machinery once over the persisted harness ids, then the periodic sweep takes over.)
- For each `BoundSession sid` tab, validate `session.json` exists on disk; missing → drop the tab (stale) and log to stderr (ids only).
- `broadcastLists` is NOT fired at boot (no client connected yet); the first WS subscriber gets a fresh snapshot on its first broadcast trigger.

The `TabsHandle` is the single source of truth for "which sessions have an active tab," feeding the partition step. Any channel that creates a session tab inserts into the shared handle, so the web sidebar reflects it immediately (via `broadcastLists`).

### Section 3 — Auto-tab on send

**The rule.** Any message **sent to the session** against a session whose id is NOT already bound to a tab in the shared `TabsHandle` auto-creates a `BoundSession sid` tab at the lowest free index. "Sent to the session" is gated by **route**, not by send outcome — only `Plain`, `SlashCommand`, and `NewSession` routes qualify. The `TabCommand`/`Focus`/`Inject` routes return `SendSlash` with a parenthetical note (`Send.hs:234-236`) but **no message was sent** — they are explicitly excluded. **Note on `SlashCommand`:** this route funnels through `runSlash`, which serves some commands that deliver to the session (`/agent`, `/clear`) and some that don't (`/help` returns help text, no turn). We accept the over-tab on the non-delivering subset as harmless — the tab is a UI affordance, not a correctness requirement (see Failure Mode below), and a `/help`-induced tab is benign. The alternative (gating auto-tab inside `runSlash` on the specific sub-commands that deliver) adds complexity for no user benefit. Sub-sessions are excluded by the fact that `loadSessionMeta paths sid` returns `Nothing` for sub-session ids (their `session.json` is not at `sessionsRoot/<sid>/`) — `handleSend` returns `SendError 404` before reaching the auto-tab path. No fragile substring/path-segment check is needed; the existing typed `SessionId` + on-disk resolution is the guard.

**Helper:**
```haskell
ensureTabForSession :: TabsHandle -> TabKind -> SessionId -> IO ()
```
Idempotent: `snapshotTabs` → if `sid` already bound, no-op; else `insertTabH (BoundSession sid) kind Nothing`. **Parameterized by `TabKind`** (per the architect's suggestion): web callers pass `KindProvider` (matches `handleTabNew`'s provider branch, wire `"session:provider"`); channel/CLI callers pass `KindAi` (matches `createConversationSession`, wire `"session:ai"`). Both render in "Active Tabs" (only `KindHarness` splits out); the parameterization is for consistency, not partition. The `SessionId` is sourced only from server-validated contexts (the `SessionMeta` loaded by `loadSessionMeta` / minted by `newSession`) — never from raw client strings (per the security reviewer's required mitigation).

**Call sites:**
- `handleSend` (web) in `Seal.Gateway.Send.hs:216` — after the `Plain`/`SlashCommand`/`NewSession` branch returns a non-`SendError` outcome. `TabCommand`/`Focus`/`Inject` branches skip the auto-tab. The auto-tab fires after the turn completes (so a failed turn doesn't create a spurious tab). Concurrency note: multiple channels calling `ensureTabForSession` concurrently on the same `sid` — STM serializes; first wins, others get `Left "duplicate"` → logged + skipped (the documented failure mode).
- `plainTurn` in `Seal.Channels.Loop.hs:462` — after the turn completes. The channel loop's `createConversationSession` already inserts a `KindAi` tab on first message from a conversation, so this is a safety net for the case where a session exists on disk but no tab was created (e.g. web `/api/sessions/new` then messaged via Signal). Channel `ensureTabForSession` passes `KindAi`.
- The CLI `plainHandler` in `Seal.Channel.Cli.hs` — same pattern, `KindAi`.

**Failure mode.** If `insertTabH` returns `Left "full"` (tab list at capacity) or `Left "duplicate"` (race), the auto-tab is skipped and a warning is logged to stderr (ids only, no session content); the send itself still succeeds. The tab is a UI affordance, not a correctness requirement.

**Broadcast.** After a successful auto-tab insert, fire `broadcastLists` (debounced — see Section 4) so the web sidebar updates immediately — the partition step runs in the broadcast, so the new tab appears in "Active Tabs" and the session drops out of "Recent Sessions" in one frame. To avoid a double broadcast in the same request (the send may have already triggered one via a session-create path), the auto-tab path uses the same debounced `broadcastLists` helper — coalescing absorbs the second fire.

### Section 4 — WS lists snapshot wiring + REST boundary

**Structured wire record.** A new `data ListsSnapshotWire = ListsSnapshotWire { lswTabs :: [Value], lswRecentSessions :: [Value], lswArchivedSessions :: [Value], lswTabSessions :: [Value] } deriving (Generic, ToJSON)` (the `ps`-prefixed Haskell fields map to un-prefixed wire keys via a custom `ToJSON` or `fieldLabelModifier` — the Haddock notes call this out). Compile-time field-name safety (per the designer's suggestion). No `type` field on the REST body.

**Snapshot builder.** `buildListsSnapshot :: ApiDeps -> IO ListsSnapshotWire` assembles the record using `partitionSessions` + the existing `tabToJson` + `sessionInfoJsonWithSnippet`. The WS envelope wraps it with `{"type": "lists", ...}` (matching `frontend/src/types/stream.ts:83 ListsEvent`); the REST `GET /api/lists` returns the bare `ListsSnapshotWire` (no `type` field — distinct from the WS envelope, per the designer's clarification). The endpoint is named `/api/lists` to mirror the WS `lists` frame name (the rationale: one logical "sidebar lists" surface, two transport shapes).

**`adBroker` plumbing.** `adBroker :: Maybe StreamBroker` is added to `ApiDeps` (currently only the WS layer holds the broker). `SendDeps.sdBroker` and `ChannelDeps.cdBroker` already carry it.

**Broadcast triggers + debounce.** Call `broadcastLists` after every state change affecting the partition:
- tab insert / remove / rebind / rename / acknowledge / release (in `Seal.Gateway.API.hs` handlers + `ensureTabForSession`);
- archive / unarchive (`handleSessionArchived`);
- session create (`handleSessionNew`, `handleSessionRebindNew`, `createConversationSession`);
- the periodic harness reconcile sweep — **only re-broadcast when a tab's orphaned/running status actually changed** (per the security reviewer's suggestion), so a tight reconcile loop cannot spam `broadcastLists`.

**Debounce/coalesce:** `broadcastLists` calls go through a `debouncedBroadcast :: ApiDeps -> IO ()` helper that coalesces calls within a 50ms window (the last call wins; a fresh `buildListsSnapshot` runs at the window edge). This absorbs the double-broadcast case (send + auto-tab in the same request) AND bounds the broadcast rate when many triggers fire in quick succession. Performance: `buildListsSnapshot` calls `listSessions` + `listArchivedSessions` (each O(n) disk read decoding every `session.json`) on every broadcast — at the expected scale (tens to low-hundreds of sessions) this is fine; the debounce bounds it under burst. A cache with TTL is deferred (YAGNI until telemetry shows a problem).

**REST boundary.** Add `GET /api/lists` returning `ListsSnapshotWire` (for the initial poll before the first WS frame lands). The existing `/api/tabs`, `/api/sessions`, `/api/sessions/archived` endpoints stay for back-compat (the CLI `seal tabs` / `seal session list` commands keep hitting them; they're not migrated — out of scope for this PR). No sunset plan for the legacy endpoints; the frontend keeps them as a third-tier fallback indefinitely.

**Frontend changes (minimal, specified):**

- **`useListsPoll()` hook** (new, in `useApi.ts`): returns `{ tabs: TabInfo[], recentSessions: SessionInfo[], archivedSessions: SessionInfo[], tabSessions: SessionInfo[], error: boolean, refresh: () => void }` — interchangeable with `useListsStream`'s return shape so `App.tsx` can treat WS and REST sources uniformly. Polls `GET /api/lists` every `POLL_INTERVAL` (reuses the existing constant), maps `TabInfoWire[]` → `TabInfo[]` via the existing `mapTabInfo`. Exposes `refresh` like `useTabs` does.
- **`App.tsx` 3-tier precedence (specified):**
  1. WS `lists` frame is primary. "WS live" means a `lists` frame has arrived within the last connection (tracked by a `wsListsReceived` flag set true on first frame, reset on WS reconnect). Per-field `length > 0` checks are dropped — a single `lists` frame carries all four fields.
  2. If WS is not live, poll `/api/lists` via `useListsPoll()` continuously (every `POLL_INTERVAL`).
  3. The legacy three-poll hooks (`useTabs`/`useRecentSessions`/`useArchivedSessions`) stay as a final fallback, used only if `/api/lists` returns an error (e.g. an older server without the endpoint) — `App.tsx` checks `useListsPoll().error` and falls through.
  4. While a WS frame is in flight (WS live but no frame yet), `App.tsx` renders the `useListsPoll()` data (the initial poll fires on mount), so there's no empty-state flash.
- **`Sidebar.tsx` defensive filter (defense-in-depth, per the designer's contradiction fix):** `recentSessions` is filtered: `sessions.filter((s) => !tabs.some((t) => t.session_id === s.id))`. The backend guarantees no overlap by construction, but the filter is defense-in-depth against a buggy WS frame (the `App.test.tsx` legacy-shape assertion now passes). A Haddock/comment notes the filter is defense-in-depth, not the source of truth.
- **`findSession` fallback chain stays** (defensive lookup; the lists are exclusive by construction but the chain doesn't hurt and keeps the type signature stable).

## Testing Strategy

**Haskell backend (TDD, RED-GREEN per work unit).** Each work unit's first RED test is named below.

**W1 — `partitionSessions` + `GET /api/lists`:**
- `Seal.Tabs.PartitionSpec` (new): mutual exclusion (no `SessionId` in two lists), completeness (every non-archived non-tab session in recents; every archived in archived; every tab-bound in tabSessions), sub-session exclusion (fixtures under `agents/` never appear), harness tabs don't pull a session, archived+tab-bound → `psTabSessions` (not both). RED test: `partitionSessions emptyTabList [s1] []` should yield `psRecentSessions == [s1]`, `psTabSessions == []`, `psArchivedSessions == []`.
- `Seal.Gateway.ApiSpec`: `GET /api/lists` returns the partitioned shape; archiving moves a session `recentSessions` → `archivedSessions` (and out of `tabSessions` if it had a tab); creating a tab for a session moves it `recentSessions` → `tabSessions`.

**W2 — `ensureTabForSession` + web `handleSend`:**
- `Seal.Gateway.SendSpec`: `ensureTabForSession` is idempotent; skips when a tab already binds the sid; `handleSend` on a `Plain` route auto-tabs after a successful turn (assert the tab appears in a follow-up `snapshotTabs`); a failed send (`SendError`) does NOT auto-tab; a `TabCommand`/`Focus`/`Inject` route does NOT auto-tab. RED test: `handleSend` on a tab-less session → follow-up `snapshotTabs` returns a tab binding the sid.
- Concurrency test: two threads call `ensureTabForSession` on the same sid → exactly one tab exists afterward.

**W3 — channel `plainTurn` + CLI `plainHandler`:**
- `Seal.Channels.LoopSpec` extension: a session on disk with no tab, messaged via the channel loop → a `KindAi` tab appears. RED test: pre-seed `sessionsRoot/<sid>/session.json`, run a turn through the loop, assert `snapshotTabs` has a `BoundSession sid` `KindAi` tab.

**W4 — unified `TabsHandle`:**
- `Seal.Command.ServeSpec` (or integration): under `seal serve`, a tab inserted by the Signal listener is visible via `GET /api/tabs` (the web surface). RED test: fork a fake Signal message through the shared handle, `GET /api/tabs` returns it.

**W5 — persistence + boot reconcile:**
- `Seal.Tabs.PersistSpec`: round-trip `saveTabList`/`loadTabList`; missing file → `Nothing`; corrupt JSON → `Nothing` + stderr warning (ids + error type only); unparseable `TabRef` id → tab skipped (not error). **Auto-save-on-mutation test:** `insertTabH` then `loadTabList` returns the new tab (verifies the wrapper). RED test: `insertTabH h (BoundSession sid) KindAi Nothing >> loadTabList` returns `Just` a `TabList` containing the tab.
- Boot reconcile test (with the harness-reconcile seam): `Seal.Harness.Reconcile` is abstracted behind a `ReconcileRunner` seam (a typeclass or record of `IO` actions) so the test injects a fake that reports a fixed liveness without a live tmux. RED test: persist a `tabs.json` with a `BoundHarness hid` the fake reports as missing + a `BoundSession sid` with no `session.json` → boot reconcile drops the session tab and marks the harness tab `orphaned`; `snapshotTabs` reflects both.

**W6 — `broadcastLists` triggers + `adBroker`:**
- `Seal.Gateway.StreamBrokerSpec` extension: use a fake broker capturing calls. **Every trigger site gets a test** (per the CTO's requirement): tab insert, tab remove, tab rebind, tab rename, tab acknowledge, tab release, archive, unarchive, session new, session rebind-new, conversation-session create, auto-tab insert. Each asserts the fake received a `BeListsSnapshot`. The debounce is tested by firing two triggers within 50ms → exactly one broadcast. The reconcile-sweep broadcast is tested: status-change → broadcast; no-change → no broadcast.

**W7 — frontend:**
- `useListsStream` test: assert the partition (no overlap between `recentSessions` and `tabSessions`) when the WS frame is well-formed.
- `App.test.tsx`: renders with a WS `lists` frame carrying a session in BOTH `tabs[].session_id` AND `recentSessions` (legacy/buggy shape) → asserts the sidebar shows it under "Active Tabs" only (the `Sidebar.tsx` defensive filter drops it from Recent Sessions).
- `useListsPoll` test: polls `/api/lists`, returns the four arrays, maps `TabInfoWire` → `TabInfo`, sets `error: false`; on a 404 sets `error: true`.

**E2E (Playwright):** extend `frontend/e2e/capstone.spec.ts` — send a message to a tab-less session → assert a new tab appears in "Active Tabs" and the session vanishes from "Recent Sessions" within one poll interval.

## Acceptance Criteria

1. **Partition (invariant 1):** for any `TabList` + on-disk sessions, no `SessionId` appears in more than one of `psTabSessions`/`psRecentSessions`/`psArchivedSessions`. Verified by the `Seal.Tabs.PartitionSpec` property test + the E2E assertion.
2. **Auto-tab on send (invariant 2):** for any successful `Plain`/`SlashCommand`/`NewSession` send to a tab-less session, a `BoundSession sid` tab exists afterward. Verified by `Seal.Gateway.SendSpec` + `Seal.Channels.LoopSpec`.
3. **Unified tabs (invariant 3):** under `seal serve`, a tab inserted by any channel is visible via `GET /api/tabs` (the web surface). Verified by `Seal.Command.ServeSpec`.
4. **Persistence:** boot with `tabs.json` containing N tabs → after boot, `snapshotTabs` returns N tabs (with harness-orphan reconcile applied). Verified by `Seal.Tabs.PersistSpec`.
5. **No regression:** the existing `Seal.Gateway.ApiSpec` archived tests, `Seal.TabsSpec`, and `Sidebar.test.tsx` continue to pass.
6. **Wire contract:** `GET /api/lists` returns `ListsSnapshotWire` (no `type` field); the WS `lists` frame carries `type: "lists"`. Verified by `Seal.Gateway.ApiSpec` + `Seal.Gateway.StreamSpec`.

## Work-Unit Decomposition (for the plan phase)

- **W1:** `partitionSessions` + `ListsSnapshotWire` + `GET /api/lists` + tests (pure, no I/O) — foundation. RED: `Seal.Tabs.PartitionSpec`.
- **W2:** `ensureTabForSession` (parameterized by `TabKind`) + wire into `handleSend` (gated by route) + tests — auto-tab on web send. RED: `Seal.Gateway.SendSpec`.
- **W3:** Wire auto-tab into channel `plainTurn` (`KindAi`) + CLI `plainHandler` (`KindAi`) + tests. RED: `Seal.Channels.LoopSpec`. *(W3 depends on W4's `cdTabs` for the channel path — see ordering note.)*
- **W4:** Unified `TabsHandle` (thread `cdTabs` through `ChannelDeps`, replace the three `seal serve` sites; leave the two standalone entry points as-is) + tests. RED: `Seal.Command.ServeSpec`. *(W4 must precede W3 so the channel path has the shared handle — W3 and W4 are reordered: **W4 before W3**.)*
- **W5:** Implement `Seal.Tabs.Persist` (wrapper, MVar-serialized, 0600, id-validation on load) + boot-time reconcile-to-orphaned (with the `ReconcileRunner` seam) + tests. RED: `Seal.Tabs.PersistSpec` auto-save test.
- **W6:** `broadcastLists` triggers (all sites) + `debouncedBroadcast` + `adBroker` in `ApiDeps` + WS frame emission + tests. RED: `Seal.Gateway.StreamBrokerSpec` fake-broker capture.
- **W7:** Frontend `useListsPoll` + `App.tsx` 3-tier precedence + `Sidebar.tsx` defensive filter + `types.ts` comment fix + frontend tests. RED: `App.test.tsx` legacy-shape assertion.

**Dependency order:** W1 → (W2, W4 in parallel) → W3 (needs W4) → (W5, W6 in parallel) → W7.

## Out of Scope

- Full "any channel can interact with any tab" UX (e.g. Signal user runs `/tab focus 2` to operate on a web-created tab). The shared handle makes this possible; the UX polish is a follow-up.
- Migrating the CLI `seal tabs` / `seal session list` commands to `/api/lists` — they keep hitting the legacy endpoints.
- HPC coverage instrumentation (per `.coverage-thresholds.json` POC limitation).
- BEADS/Dolt tracking (dolt not installed in this environment — GitHub issue used instead).
- Telemetry/analytics for post-release evaluation of the partition's user impact (the project has no telemetry; evaluation is via GitHub-issue user feedback).