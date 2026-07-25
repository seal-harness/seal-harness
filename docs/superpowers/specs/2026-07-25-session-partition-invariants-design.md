# Session Partition Invariants — Design

**Date:** 2026-07-25
**Branch:** `feat/session-partition-invariants`
**Status:** Draft (pending Design Review Gate)

## Problem

The web frontend sidebar renders three sections — **Active Tabs**, **Recent Sessions**, and **Archived** — but the running session associated with an active tab currently appears in BOTH "Active Tabs" (via `tabs[].session_id`) AND "Recent Sessions" (via `/api/sessions`, which returns every non-archived on-disk session). This redundancy wastes screen real estate and obscures the categorization.

Two invariants must be established and preserved:

1. **Partition.** The three sections — "Active Tabs", "Recent Sessions", "Archived" — partition the space of sessions. Every session is categorized into exactly one.
2. **Auto-tab on send.** Any message sent to a session that has no active tab creates a new tab (unless the session is an AGENT_START sub-session).

A third, supporting invariant is in scope as design-for (implementation of the persistence layer is included; the full "any channel can interact with any tab" UX is a follow-up):

3. **Unified, persistent tab list.** A single tab list shared across all channels (web, Signal, Telegram, CLI), preserved across `seal serve` restarts. Any channel can interact with any tab.

## Current State (findings from exploration)

- **Sidebar sections.** `frontend/src/components/Sidebar.tsx` renders `ActiveTabs`, `RunningHarnesses` (a split-out subset of tabs where `kind === 'harness'`), a `RecentSessionsHeader` + session rows, and an `ArchivedSection`. The redundancy: `recentSessions = sessions` (line 269) where `sessions` comes from `/api/sessions` and includes tab-backed sessions.
- **`findSession` lie.** `frontend/src/types.ts:136` claims tab-backed sessions are "deduped OUT of recents/archived by the backend," but `Seal.Session.Store.listSessions` returns ALL non-archived on-disk sessions — no dedup. The comment is aspirational, not enforced.
- **Dormant WS path.** `Seal.Gateway.StreamBroker.broadcastLists` is wired (the `BeListsSnapshot` event + the `broadcastLists` helper exist and the WS `Stream.hs` forwards them) but **never invoked from production code**. The frontend's `useListsStream` hook subscribes to a `lists` frame that never arrives; `App.tsx` falls back to REST polling (`useTabs` + `useRecentSessions` + `useArchivedSessions`, each on a 2s interval). `tabSessions` is always `[]` in practice.
- **Per-channel tab handles.** `Seal.Command.Serve` creates one `tabsH <- newTabsHandle` for the web (line 105) and each channel listener forks its own (Signal line 276, Telegram line 312). The standalone `seal signal` / `seal telegram` entry points do the same. Tabs created in a channel listener are invisible to the web sidebar.
- **Tab persistence stub.** `Seal.Tabs.Persist` exists but is a no-op stub (`saveTabList _h = pure ()`, `loadTabList = pure Nothing`). Tabs are in-memory only; a `seal serve` restart loses the tab list.
- **Sub-sessions already excluded.** AGENT_START children live under `<parent>/agents/<child>/` (`Seal.Config.Paths.agentSessionDir`). `listSessions` reads only direct children of `sessionsRoot`, so sub-sessions never appear in the sessions list. Invariant 1 is already satisfied for sub-sessions; the partition work doesn't need to special-case them.
- **No auto-tab on send.** `handleSend` (`Seal.Gateway.Send.hs:216`) runs `plainTurn` and returns; it never inserts a tab. The channel `createConversationSession` (`Seal.Channels.Loop.hs:395`) DOES insert a tab on first message from a conversation, but a session created via the web "Recent Sessions +" button (`/api/sessions/new`) then messaged via Signal would not get a tab on the Signal side.

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
  { psTabSessions     :: [SessionMeta]
  , psRecentSessions  :: [SessionMeta]
  , psArchivedSessions :: [SessionMeta]
  }

partitionSessions :: TabList -> [SessionMeta] -> [SessionMeta] -> PartitionedSessions
```

- **Inputs:** the current `TabList` (from the shared `TabsHandle`), `listSessions paths` (non-archived), `listArchivedSessions paths`.
- **Rule:** a session `s` goes into `psTabSessions` iff some tab's `tRef == BoundSession (smId s)`; else into `psRecentSessions` iff not archived; else into `psArchivedSessions`.
- **Mutual exclusion** is by construction (a session appears in exactly one of the three). **Completeness** — every non-archived on-disk session is in either `psTabSessions` or `psRecentSessions`; every archived is in `psArchivedSessions`.
- **Harness tabs** (`BoundHarness hid`) carry no session, so they don't pull any session into `psTabSessions`. They render in "Active Tabs" / "Running Harnesses" via the tab list alone, unchanged.
- **Sub-sessions** never appear (not in either `list*` output) — no special-casing needed.

`listSessions` and `listArchivedSessions` stay as-is (raw on-disk truth); the partition layers on top.

### Section 2 — Unified, persistent tab list

**Single shared handle.** Replace the five `tabsH <- newTabsHandle` sites in `seal serve` (web `Serve.hs:105`, Signal `:276`, Telegram `:312`) with one handle created once and threaded into `ChannelDeps` as a new `cdTabs :: TabsHandle` field. `runChannelLoop` already takes `tabsH` as a parameter — keep the signature, pass the shared one. The standalone `seal signal` / `seal telegram` commands (no web) keep their own `newTabsHandle` since there's no web surface to unify with.

**Persistence.** Implement `Seal.Tabs.Persist` for real:
- `saveTabList :: TabsHandle -> IO ()` writes `TabList` as JSON to `<state>/tabs.json` atomically (mirror `Seal.Web.UiState.persistUiState`: write `.tmp`, `renameFile`).
- `loadTabList :: IO (Maybe TabList)` reads it at boot. Missing file → `Nothing` (fresh empty list). Corrupt JSON → `Nothing` + stderr warning (self-heals on next write).
- Every mutation (`insertTabH`/`removeTabH`/`rebindTabH`/`renameTabH`) persists after the STM transaction commits. Implemented via a thin wrapper or a `TVar`-change listener (forkIO watching the TVar) so call sites don't have to remember to call `saveTabList`.

**Boot-time reconcile-to-orphaned.** On startup: `loadTabList` → seed the `TVar` → reconcile pass:
- For each `BoundHarness hid` tab, check the harness registry's tmux window for `hid`; surviving → `running`, missing → `orphaned`.
- For each `BoundSession sid` tab, validate `session.json` exists on disk; missing → drop the tab (stale) and log to stderr.
- Reuses the existing `Seal.Harness.Reconcile` machinery.

The `TabsHandle` is the single source of truth for "which sessions have an active tab," feeding the partition step. Any channel that creates a session tab inserts into the shared handle, so the web sidebar reflects it immediately (via `broadcastLists`).

### Section 3 — Auto-tab on send

**The rule.** Any successful `plainTurn` (or slash command that lands a reply in the transcript) against a session whose id is NOT already bound to a tab in the shared `TabsHandle` auto-creates a `BoundSession sid` tab at the lowest free index. Sub-sessions are excluded by a defensive guard: the auto-tab helper bails when the session dir is under an `agents/` subdir (they also never go through `handleSend`/`plainTurn` directly — they run inside the delegation worker — so the rule doesn't reach them, but the guard is defense-in-depth).

**Helper:**
```haskell
ensureTabForSession :: TabsHandle -> SealPaths -> SessionId -> IO ()
```
Idempotent: `snapshotTabs` → if `sid` already bound, no-op; else `insertTabH (BoundSession sid) KindProvider Nothing`. `KindProvider` since the only non-harness tab kind is provider/session (matches `handleTabNew`'s provider branch). The new tab appears in "Active Tabs" (not "Running Harnesses", which filters `kind === 'harness'`).

**Call sites:**
- `handleSend` (web) in `Seal.Gateway.Send.hs:216` — after any send outcome that is NOT `SendError` (i.e. `SendAssistant` for a plain turn, or `SendSlash` for a slash command that was accepted — whether it produced a transcript entry or a transient bubble). A `SendError` (404 missing session, 500 internal) does NOT auto-tab. The invariant is "a message was sent to the session"; a slash command like `/model` qualifies even though it adds no transcript entry.
- `plainTurn` in `Seal.Channels.Loop.hs:462` — after the turn completes. The channel loop's `createConversationSession` already inserts a tab on first message from a conversation, so this is a safety net for the case where a session exists on disk but no tab was created (e.g. web `/api/sessions/new` then messaged via Signal).
- The CLI `plainHandler` in `Seal.Channel.Cli.hs`.

**Failure mode.** If `insertTabH` returns `Left "full"` (tab list at capacity) or `Left "duplicate"` (race), the auto-tab is skipped and a warning is logged to stderr; the send itself still succeeds. The tab is a UI affordance, not a correctness requirement.

**Broadcast.** After a successful auto-tab insert, fire `broadcastLists` so the web sidebar updates immediately — the partition step runs in the broadcast, so the new tab appears in "Active Tabs" and the session drops out of "Recent Sessions" in one frame.

### Section 4 — WS lists snapshot wiring + REST boundary

**Snapshot builder.** `buildListsSnapshot :: ApiDeps -> IO Value` assembles:
```json
{ "type": "lists"
, "tabs": <TabInfoWire[]>
, "recentSessions": <SessionInfo[]>
, "archivedSessions": <SessionInfo[]>
, "tabSessions": <SessionInfo[]>
}
```
using `partitionSessions` + the existing `tabToJson` + `sessionInfoJsonWithSnippet`. The shape matches `frontend/src/types/stream.ts:83 ListsEvent` and `:137 ListsSnapshot` exactly — no frontend wire change.

**Broadcast triggers.** Call `broadcastLists broker (buildListsSnapshot deps)` after every state change affecting the partition:
- tab insert / remove / rebind / rename / acknowledge / release (in `Seal.Gateway.API.hs` handlers + `ensureTabForSession`);
- archive / unarchive (`handleSessionArchived`);
- session create (`handleSessionNew`, `handleSessionRebindNew`, `createConversationSession`);
- the periodic harness reconcile sweep (extend it to re-broadcast so orphaned-tab status changes refresh the sidebar).

`adBroker :: Maybe StreamBroker` is added to `ApiDeps` (currently only the WS layer holds the broker). `SendDeps.sdBroker` and `ChannelDeps.cdBroker` already carry it.

**REST boundary.** Add `GET /api/lists` returning the same snapshot JSON (for the initial poll before the first WS frame lands). The existing `/api/tabs`, `/api/sessions`, `/api/sessions/archived` endpoints stay for back-compat (the CLI `seal tabs` / `seal session list` commands and any external consumers still work).

**Frontend changes (minimal):**
- `useApi.ts` gains `useListsPoll()` hitting `/api/lists`.
- `App.tsx` prefers WS `lists` → falls back to the single `/api/lists` poll → (legacy) the three separate polls. The `wsLists.tabs.length > 0 ? wsLists.tabs : polledTabs.tabs` precedence simplifies.
- `Sidebar.tsx`'s `recentSessions = sessions` (line 269) becomes `recentSessions` as-is — the backend now guarantees no tab-backed session is in `sessions`, so no frontend filter is needed.
- `findSession` fallback chain stays (defensive lookup; the lists are exclusive by construction but the chain doesn't hurt and keeps the type signature stable).

## Testing Strategy

**Haskell backend (TDD, RED-GREEN per work unit):**
- `Seal.Tabs.PersistSpec` — round-trip `saveTabList`/`loadTabList`; missing file → `Nothing`; corrupt JSON → `Nothing` + stderr warning.
- `Seal.Tabs.PartitionSpec` (new) — `partitionSessions` properties: mutual exclusion (no session id in two lists), completeness (every non-archived, non-tab session in recents; every archived in archived; every tab-bound in tabSessions), sub-session exclusion (fixtures under `agents/` never appear), harness tabs don't pull a session.
- `Seal.Gateway.ApiSpec` — `GET /api/lists` returns the partitioned shape; archiving moves a session `recentSessions` → `archivedSessions` and removes it from `tabSessions` if it had a tab; creating a tab for a session moves it `recentSessions` → `tabSessions`.
- `Seal.Gateway.SendSpec` — `ensureTabForSession` is idempotent; skips when a tab already binds the sid; skips sub-sessions (fixture session dir under `agents/`); `handleSend` auto-tabs after a successful plain turn (assert the tab appears in a follow-up `snapshotTabs`); a failed send does NOT auto-tab.
- `Seal.Command.ServeSpec` or integration — boot with a persisted `tabs.json` containing a `BoundHarness hid` whose tmux window is gone → the tab loads as `orphaned`; a `BoundSession sid` with a missing `session.json` → the tab is dropped.
- Extend `Seal.Gateway.StreamBrokerSpec` — `broadcastLists` is called after tab insert/remove/archive (use a fake broker capturing calls).

**Frontend (vitest):**
- `useListsStream` — extend to assert the partition (no overlap between `recentSessions` and `tabSessions`).
- `App.test.tsx` — renders with WS `lists` frame carrying a session in both `tabs[].session_id` and `recentSessions` (legacy/buggy shape) → asserts the sidebar shows it under "Active Tabs" only.

**E2E (Playwright):** extend `capstone.spec.ts` — send a message to a tab-less session → assert a new tab appears in "Active Tabs" and the session vanishes from "Recent Sessions" within one poll interval.

## Work-Unit Decomposition (for the plan phase)

- **W1:** `partitionSessions` + `GET /api/lists` + tests (pure, no I/O) — foundation.
- **W2:** `ensureTabForSession` + wire into `handleSend` + tests — auto-tab on web send.
- **W3:** Wire auto-tab into channel `plainTurn` + CLI `plainHandler` + tests.
- **W4:** Unified `TabsHandle` (thread `cdTabs` through `ChannelDeps`, drop per-channel `newTabsHandle` in `seal serve`) + tests.
- **W5:** Implement `Seal.Tabs.Persist` + boot-time reconcile-to-orphaned + tests.
- **W6:** `broadcastLists` triggers + `adBroker` in `ApiDeps` + WS frame emission + tests.
- **W7:** Frontend `useListsPoll` + `App.tsx` simplification + frontend tests.

## Out of Scope

- Full "any channel can interact with any tab" UX (e.g. Signal user runs `/tab focus 2` to operate on a web-created tab). The shared handle makes this possible; the UX polish is a follow-up.
- HPC coverage instrumentation (per `.coverage-thresholds.json` POC limitation).
- BEADS/Dolt tracking (dolt not installed in this environment — GitHub issue used instead).