# Session Partition Invariants Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish three sidebar invariants — (1) Active Tabs / Recent Sessions / Archived partition the session space, (2) auto-tab on send, (3) unified persistent tab list — and wire the dormant `broadcastLists` path so the frontend gets push updates.

**Architecture:** Backend owns the partition via a pure `partitionSessions` function; a unified in-memory + disk-persisted `TabsHandle` is the single source of truth for "which sessions have a tab"; `ensureTabForSession` auto-tabs on send across web + channels + CLI; `broadcastLists` (debounced) pushes partitioned snapshots to the WS clients; `GET /api/lists` is the REST fallback.

**Tech Stack:** Haskell (GHC, cabal, hspec), TypeScript (Vite, vitest, Playwright). Build gate: `make check` (= `make build test lint`). Frontend gate: `cd frontend && npm run test && npm run build`.

**Design:** `docs/superpowers/specs/2026-07-25-session-partition-invariants-design.md` (Design Review Gate APPROVED 5/5).
**Issue:** https://github.com/seal-harness/seal-harness/issues/55

## Global Constraints

- TDD: every work unit writes the failing test FIRST, runs it to confirm FAIL, then implements.
- No `--no-verify` on commits; no skipping `make check` or frontend tests.
- `tabs.json` written with file mode `0600`, atomic write (`.tmp` + rename), writes serialized via an MVar.
- `loadTabList` validates every `TabRef` id via `mkSessionId`/`mkHarnessId` and skips unparseable tabs.
- `ensureTabForSession` sources `SessionId` only from server-validated `SessionMeta` (never raw client strings).
- Auto-tab gated by route (Plain/SlashCommand/NewSession only); `TabCommand`/`Focus`/`Inject` excluded.
- `TabKind` parameterized: web = `KindProvider`, channel/CLI = `KindAi`.
- `broadcastLists` debounced (50ms coalesce); reconcile sweep re-broadcasts only on status change.
- Sub-session exclusion relies on `loadSessionMeta` returning `Nothing` for sub-session ids (no substring/path check).
- The standalone `seal signal` / `seal telegram` entry points keep their own `TabsHandle` (no web surface to unify with).
- `GET /api/lists` returns `ListsSnapshotWire` (no `type` field); WS `lists` frame wraps it with `{"type": "lists", ...}`.
- Commit style: `feat:`, `fix:`, `docs:`, `test:`, `refactor:` prefixes, lowercase, imperative mood (matches existing log).

---

## File Structure (locked decomposition)

**New backend files:**
- `src/Seal/Tabs/Partition.hs` — `partitionSessions` + `PartitionedSessions` record.
- `src/Seal/Harness/Reconcile/Seam.hs` — `ReconcileRunner` record (test seam over `reconcileTick`).
- `src/Seal/Gateway/SessionJson.hs` — `tabToJson` + `sessionInfoJsonWithSnippet` (moved OUT of `API.hs` so `ListsSnapshot.hs` can import them without creating a cycle with `API.hs`).
- `src/Seal/Gateway/ListsSnapshot.hs` — `ListsSnapshotWire` record + `buildListsSnapshot` (takes `TabsHandle` + `SealPaths` directly — NOT `ApiDeps`, to avoid importing `API.hs`).
- `test/Seal/Tabs/PartitionSpec.hs` — partition property tests.
- `test/Seal/Tabs/PersistSpec.hs` — already exists; extended (if it doesn't, create).
- `test/Seal/Gateway/ListsSnapshotSpec.hs` — snapshot builder tests.
- `test/Seal/Gateway/SendSpec.hs` — new (W2 auto-tab tests).
- `test/Seal/Command/ServeSpec.hs` — new (W4 unified handle + W5 boot reconcile).

**Modified backend files:**
- `src/Seal/Config/Paths.hs` — add `tabListPath :: SealPaths -> FilePath` (the `tabs.json` path; new).
- `src/Seal/Tabs.hs` — wrap mutations to persist (the wrapper holds an MVar + calls `saveTabList`); export the persisting constructor.
- `src/Seal/Tabs/Persist.hs` — implement for real (atomic write, 0600, id-validation); signatures take a `FilePath`.
- `src/Seal/Gateway/API.hs` — **move `tabToJson` + `sessionInfoJsonWithSnippet` to `Seal.Gateway.SessionJson`** (keep a re-export from `API.hs` for back-compat if desired, or update internal call sites to import from `SessionJson`); `GET /api/lists` (calls `buildListsSnapshot (adTabsHandle deps) (srPaths (adSessionRuntime deps))`); `adBroker` in `ApiDeps`; broadcast triggers in handlers.
- `src/Seal/Gateway/Send.hs` — `ensureTabForSession` + call in `handleSend` (gated by route); add `sdTabsHandle :: TabsHandle` to `SendDeps`.
- `src/Seal/Gateway/StreamBroker.hs` — `debouncedBroadcast` helper (or co-locate in API.hs).
- `src/Seal/Channels/Loop.hs` — `cdTabs :: TabsHandle` in `ChannelDeps`; auto-tab in `plainTurn`; `newChannelDeps` takes `tabsH`.
- `src/Seal/Channel/Cli.hs` — auto-tab in `plainHandler` (uses the shared `tabsH` passed in).
- `src/Seal/Command/Serve.hs` — single `tabsH` created once, threaded into `newChannelDeps` + `runChannelLoop` calls; boot `loadTabList` + reconcile pass; `adBroker` wired into `ApiDeps`.

**Cabal file:** `seal-harness.cabal` — add every new test module to the test suite's `other-modules` list (lines 268+). **Required:** new `Spec.hs` files are NOT auto-discovered by cabal's exitcode-stdio suite; without this, `make test` silently skips them.

**Modified frontend files:**
- `frontend/src/hooks/useApi.ts` — add `useListsPoll()` hook + return type.
- `frontend/src/App.tsx` — 3-tier precedence (WS live → `/api/lists` poll → legacy three-poll).
- `frontend/src/components/Sidebar.tsx` — defensive `recentSessions` filter (defense-in-depth).
- `frontend/src/types.ts` — update the `findSession` comment to past-tense (now accurate).

**Test files (extend):**
- `test/Seal/Gateway/ApiSpec.hs` (extend with `/api/lists` cases).
- `test/Seal/Channels/LoopSpec.hs` (extend — channel auto-tab).
- `test/Seal/Gateway/StreamBrokerSpec.hs` (extend — all broadcast triggers + debounce).
- `test/Seal/Command/ServeSpec.hs` — created in W4, extended in W5.
- `frontend/src/hooks/__tests__/useApi.test.ts` (extend) — `useListsPoll`.
- `frontend/src/__tests__/App.test.tsx` (extend) — legacy-shape assertion.
- `frontend/src/components/__tests__/Sidebar.test.tsx` (extend) — defensive filter.
- `frontend/e2e/capstone.spec.ts` (extend) — E2E auto-tab.

**Construction-site update checklist (CRITICAL — adding fields breaks these):**
- `ApiDeps` construction sites (add `adBroker` in W1): `test/Seal/Gateway/ApiSpec.hs` (every `ApiDeps` literal), `test/Seal/Gateway/ServerSpec.hs:53` (`mkDeps`), `test/Seal/Phase7aSpec.hs`, `src/Seal/Command/Serve.hs`.
- `SendDeps` construction sites (add `sdTabsHandle` in W2): `test/Seal/Gateway/ApiSpec.hs` at **three** sites (lines ~2000, ~2083, ~2198 — grep `SendDeps`), `src/Seal/Command/Serve.hs` (the `sendDeps` literal).
- `ChannelDeps`/`newChannelDeps` callers (W4): `src/Seal/Channels/Signal/Run.hs:291`, `src/Seal/Channels/Telegram/Run.hs:138`, `src/Seal/Channels/Loop.hs:85` (test), `src/Seal/Command/Serve.hs:125`.

---

## Work-Unit Dependency Order

```
W1 (partition + /api/lists) ──┬── W2 (web auto-tab)
                              ├── W6 (broadcast triggers; depends on W1's buildListsSnapshot)
                              │
                              └── W4 (unified TabsHandle)
                                    │
                                    └── W3 (channel + CLI auto-tab; needs W4's cdTabs)
                                    │
W5 (persistence + boot reconcile) ── independent of W3; can parallel with W6 after W4
                                    │
                                    └── W7 (frontend; depends on W6 for WS, W1 for /api/lists)
```

Execution order: W1 → (W2, W4 in parallel) → W3 → (W5, W6 in parallel) → W7.

**Human checkpoints** (pause for review):
- After W1 (partition foundation).
- After W4 + W3 (unified handle + cross-channel auto-tab — deliberate behavior change: channel tabs now visible in web sidebar).
- After W5 (persistence + boot reconcile — restart-time behavior worth manual verification).

---

## Task W1: partitionSessions + GET /api/lists

**Files:**
- Create: `src/Seal/Tabs/Partition.hs`
- Create: `src/Seal/Gateway/ListsSnapshot.hs`
- Modify: `src/Seal/Gateway/API.hs` (add `GET /api/lists` handler; add `adBroker :: Maybe StreamBroker` to `ApiDeps` — read-only field for now, used in W6)
- Test: `test/Seal/Tabs/PartitionSpec.hs`
- Test: `test/Seal/Gateway/ListsSnapshotSpec.hs`
- Test: `test/Seal/Gateway/ApiSpec.hs` (extend with `/api/lists` cases)

**Interfaces:**
- Produces: `partitionSessions :: TabList -> [SessionMeta] -> [SessionMeta] -> PartitionedSessions`, `buildListsSnapshot :: ApiDeps -> IO ListsSnapshotWire`, `ListsSnapshotWire` record + `ToJSON`.

### Step 1: Write the failing partition test

- [ ] Create `test/Seal/Tabs/PartitionSpec.hs`:

```haskell
module Seal.Tabs.PartitionSpec (spec) where

import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Seal.Tabs.Partition (PartitionedSessions (..), partitionSessions)
import Seal.Tabs.Types (TabList (..), Tab (..), TabRef (..), emptyTabList, insertTab)
import Seal.Handles.Tab (TabKind (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Core.Types (mkSessionId)
import Data.Either (fromRight)

mkSid :: String -> SessionId
mkSid s = fromRight (error "bad sid") (mkSessionId s)

mkMeta :: String -> SessionMeta
mkMeta s = SessionMeta
  { smId = mkSid s, smProvider = "ollama", smModel = "llama3.2"
  , smChannel = "cli", smAgent = Nothing, smSystemOverride = Nothing
  , smAgentName = Nothing
  , smCreatedAt = read "2026-01-01 00:00:00 UTC"
  , smLastActive = read "2026-01-01 00:00:00 UTC"
  }

spec :: Spec
spec = describe "partitionSessions" $ do
  it "empty tab list, one non-archived session → recents" $ do
    let ps = partitionSessions emptyTabList [mkMeta "s1"] []
    psTabSessions ps `shouldBe` []
    psRecentSessions ps `shouldBe` [mkMeta "s1"]
    psArchivedSessions ps `shouldBe` []

  it "session bound to a tab → tabSessions, not recents" $ do
    let sid = mkSid "s1"
        tl = fromRight emptyTabList (insertTab (BoundSession sid) KindAi Nothing emptyTabList)
        ps = partitionSessions tl [mkMeta "s1"] []
    psTabSessions ps `shouldBe` [mkMeta "s1"]
    psRecentSessions ps `shouldBe` []

  it "archived session with no tab → archivedSessions" $ do
    let ps = partitionSessions emptyTabList [] [mkMeta "s1"]
    psArchivedSessions ps `shouldBe` [mkMeta "s1"]
    psRecentSessions ps `shouldBe` []

  it "archived + tab-bound → tabSessions (tab wins)" $ do
    let sid = mkSid "s1"
        tl = fromRight emptyTabList (insertTab (BoundSession sid) KindAi Nothing emptyTabList)
        ps = partitionSessions tl [] [mkMeta "s1"]
    psTabSessions ps `shouldBe` [mkMeta "s1"]
    psArchivedSessions ps `shouldBe` []

  it "harness tab does not pull a session into tabSessions" $ do
    let tl = fromRight emptyTabList (insertTab (BoundHarness (mkSid "h1")) KindHarness Nothing emptyTabList)
        ps = partitionSessions tl [mkMeta "s1"] []
    psTabSessions ps `shouldBe` []
    psRecentSessions ps `shouldBe` [mkMeta "s1"]

  it "mutual exclusion: no session id in two lists" $ do
    let sid = mkSid "s1"
        tl = fromRight emptyTabList (insertTab (BoundSession sid) KindAi Nothing emptyTabList)
        ps = partitionSessions tl [mkMeta "s1", mkMeta "s2"] [mkMeta "s3"]
    let allIds = map smId (psTabSessions ps <> psRecentSessions ps <> psArchivedSessions ps)
    allIds `shouldSatisfy` (\xs -> length xs == length (nub xs))
  where nub = Data.List.nub
```

(Adjust imports to match the real `Seal.Session.Meta` constructor shape — verify by reading `Seal.Session.Meta` before finalizing. The `BoundHarness` constructor needs a `HarnessId` — read `Seal.Core.Types` / `Seal.Harness.Id` for the constructor.)

- [ ] Run: `make test` (or `cabal test --test-options='-m "/partitionSessions/"'`)
- Expected: FAIL — module `Seal.Tabs.Partition` not found.

### Step 2: Implement `partitionSessions`

- [ ] Create `src/Seal/Tabs/Partition.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | The pure partition step: given the current tab list and the on-disk
-- session lists (non-archived + archived), produce three mutually-exclusive
-- lists. The backend's source of truth for the sidebar's three sections.
-- Haddock note: Haskell record fields use the @ps@ prefix; the wire keys
-- (in 'Seal.Gateway.ListsSnapshot') drop the prefix
-- (@tabSessions@/@recentSessions@/@archivedSessions@).
module Seal.Tabs.Partition
  ( PartitionedSessions (..)
  , partitionSessions
  ) where

import Data.Set (Set)
import Data.Set qualified as Set

import Seal.Core.Types (SessionId)
import Seal.Handles.Tab (TabRef (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Tabs.Types (Tab (..), TabList (..))

data PartitionedSessions = PartitionedSessions
  { psTabSessions      :: [SessionMeta]  -- ^ wire key: @tabSessions@
  , psRecentSessions   :: [SessionMeta]  -- ^ wire key: @recentSessions@
  , psArchivedSessions :: [SessionMeta]  -- ^ wire key: @archivedSessions@
  } deriving stock (Eq, Show)

-- | Partition the session space into three mutually-exclusive lists.
-- A session @s@ goes into 'psTabSessions' iff some tab's 'tRef' is
-- @BoundSession (smId s)@; else into 'psRecentSessions' iff not archived;
-- else into 'psArchivedSessions'. Harness tabs (@BoundHarness@) carry no
-- session and pull nothing into 'psTabSessions'. An archived + tab-bound
-- session goes into 'psTabSessions' (the tab wins; the archive flag stays
-- on disk and resurfaces when the tab closes).
partitionSessions :: TabList -> [SessionMeta] -> [SessionMeta] -> PartitionedSessions
partitionSessions tl recent archived =
  let tabSids = Set.fromList [ sid | t <- tlTabs tl, BoundSession sid <- [tRef t] ]
      (tabbed, recent') = partition (`belongsInTabs` tabSids) recent
  in PartitionedSessions
       { psTabSessions = tabbed
       , psRecentSessions = recent'
       , psArchivedSessions = archived
       }
  where
    belongsInTabs s tabSids = smId s `Set.member` tabSids
```

(Use `Data.List.partition`. Fix the list-comprehension pattern for `BoundSession` — verify `tRef`'s type. If `TabRef` is a sum type, the pattern `[BoundSession sid <- [tRef t]]` works; otherwise use a `case`.)

- [ ] Run: `make test -- -m "/partitionSessions/"`
- Expected: PASS.

### Step 3: Write the `ListsSnapshotWire` + `buildListsSnapshot` failing test

- [ ] Create `test/Seal/Gateway/ListsSnapshotSpec.hs` — assert `buildListsSnapshot` returns the partitioned shape. (Use the existing `ApiSpec` test helpers — read `test/Seal/Gateway/ApiSpec.hs` for the app-construction pattern.)

```haskell
-- Sketched: build a minimal ApiDeps with a known tabsH + a tmp sessions root,
-- call buildListsSnapshot, assert the four fields are partitioned correctly.
```

- [ ] Run: `make test -- -m "/ListsSnapshot/"`
- Expected: FAIL — module not found.

### Step 4: Implement `ListsSnapshotWire` + `buildListsSnapshot`

- [ ] Create `src/Seal/Gateway/SessionJson.hs` — **move `tabToJson` and `sessionInfoJsonWithSnippet` here** from `src/Seal/Gateway/API.hs` (cut the definitions from `API.hs:1047,1112`, paste into `SessionJson.hs`, export both). Update `API.hs`'s internal call sites (lines 91, 100, 106) to `import Seal.Gateway.SessionJson (tabToJson, sessionInfoJsonWithSnippet)`. This breaks the would-be cycle: `ListsSnapshot.hs` imports `SessionJson` (lower-level), not `API.hs`.

- [ ] Create `src/Seal/Gateway/ListsSnapshot.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
-- | The wire snapshot for the WS @lists@ frame and the REST @GET /api/lists@
-- endpoint. Carries the partitioned session lists (mutually exclusive by
-- construction via 'partitionSessions'). The WS frame wraps this with
-- @{"type": "lists", ...}@; the REST body is the bare record (no @type@).
--
-- Takes 'TabsHandle' + 'SealPaths' directly (NOT 'ApiDeps') so this module
-- does NOT import 'Seal.Gateway.API' — avoids a source-level import cycle
-- (API.hs imports this module for the /api/lists route).
module Seal.Gateway.ListsSnapshot
  ( ListsSnapshotWire (..)
  , buildListsSnapshot
  ) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Aeson qualified as A
import GHC.Generics (Generic)

import Seal.Config.Paths (SealPaths)
import Seal.Gateway.SessionJson (sessionInfoJsonWithSnippet, tabToJson)
import Seal.Session.Store (listArchivedSessions, listSessions)
import Seal.Tabs (snapshotTabs, TabsHandle)
import Seal.Tabs.Partition (PartitionedSessions (..), partitionSessions)
import Seal.Tabs.Types (tlTabs)

data ListsSnapshotWire = ListsSnapshotWire
  { lswTabs             :: [A.Value]
  , lswRecentSessions   :: [A.Value]
  , lswArchivedSessions :: [A.Value]
  , lswTabSessions      :: [A.Value]
  } deriving stock (Eq, Show, Generic)

instance ToJSON ListsSnapshotWire where
  toJSON s = A.object
    [ "tabs"             .= lswTabs s
    , "recentSessions"   .= lswRecentSessions s
    , "archivedSessions" .= lswArchivedSessions s
    , "tabSessions"      .= lswTabSessions s
    ]

-- | Build the partitioned snapshot. Takes the components directly (not
-- 'ApiDeps') so this module stays free of a cycle with 'Seal.Gateway.API'.
buildListsSnapshot :: TabsHandle -> SealPaths -> IO ListsSnapshotWire
buildListsSnapshot tabsH paths = do
  tl <- snapshotTabs tabsH
  let tabsJson = map tabToJson (tlTabs tl)
  recent   <- listSessions paths
  archived <- listArchivedSessions paths
  let PartitionedSessions{..} = partitionSessions tl recent archived
  recentJson   <- mapM (sessionInfoJsonWithSnippet paths) psRecentSessions
  archivedJson <- mapM (sessionInfoJsonWithSnippet paths) psArchivedSessions
  tabbedJson   <- mapM (sessionInfoJsonWithSnippet paths) psTabSessions
  pure ListsSnapshotWire
    { lswTabs = tabsJson
    , lswRecentSessions = recentJson
    , lswArchivedSessions = archivedJson
    , lswTabSessions = tabbedJson
    }
```

- [ ] Run: `make test -- -m "/ListsSnapshot/"`
- Expected: PASS.

### Step 5: Add `GET /api/lists` route + `adBroker` field to `ApiDeps`

- [ ] Modify `src/Seal/Gateway/API.hs`:
  - **Move `tabToJson` and `sessionInfoJsonWithSnippet` to `Seal.Gateway.SessionJson`** (per Step 4) — update `API.hs` to import them from `SessionJson` for its own internal use (lines 91, 100, 106). Do NOT re-export from `API.hs` (keep the public API surface minimal; only `apiApp` + `ApiDeps` exported).
  - Add `adBroker :: Maybe StreamBroker` to the `ApiDeps` record (read-only in W1; used in W6).
  - Add a route case: `(m', ["api", "lists"]) | m' == methodGet -> do snap <- buildListsSnapshot (adTabsHandle deps) (srPaths (adSessionRuntime deps)); respond (jsonLBS status200 (A.encode snap))`.
  - Import `Seal.Gateway.ListsSnapshot` (for `buildListsSnapshot`) + `Seal.Gateway.StreamBroker` (the `StreamBroker` type for the field). **No cycle:** `ListsSnapshot.hs` imports `SessionJson.hs` (lower-level), not `API.hs`.

- [ ] Extend `test/Seal/Gateway/ApiSpec.hs`:
  - `GET /api/lists` returns 200 with the four fields.
  - A tab-bound session appears in `tabSessions`, not `recentSessions`.
  - An archived session appears in `archivedSessions`.
  - An archived+tab-bound session appears in `tabSessions`.

```haskell
-- Sketched test pattern (mirror the existing archived tests around line 455):
it "GET /api/lists partitions: tab-bound session in tabSessions only" $ do
  -- create session s1, insert a tab binding s1, GET /api/lists, assert
```

- [ ] **Update ALL `ApiDeps` construction sites** to set `adBroker` (per the Construction-site update checklist in File Structure): `test/Seal/Gateway/ApiSpec.hs` (every `ApiDeps` literal — grep for `ApiDeps`), `test/Seal/Gateway/ServerSpec.hs:53` (`mkDeps`), `test/Seal/Phase7aSpec.hs`, and `src/Seal/Command/Serve.hs`. For tests, pass `Nothing` for now (or a fake broker). For `Serve.hs`, pass `Just broker` (the existing `broker` from `newStreamBroker`).

- [ ] **Add new test modules to `seal-harness.cabal` `other-modules`** (lines 268+): `Seal.Tabs.PartitionSpec`, `Seal.Gateway.ListsSnapshotSpec`, `Seal.Gateway.SendSpec`, `Seal.Tabs.PersistSpec` (if creating), `Seal.Command.ServeSpec` (added in W4). Without this, `make test` silently skips them (cabal's exitcode-stdio suite only runs listed modules). **Also add `Seal.Gateway.SessionJson` and `Seal.Gateway.ListsSnapshot` to the LIBRARY's exposed-modules** (or `other-modules` if the test imports them — read the cabal library stanza to confirm the right list). Without this, the library won't compile the new modules.

- [ ] Run: `make test`
- Expected: PASS (including the new `/api/lists` cases).

### Step 6: Commit

- [ ] Run `make check` (build + test + lint — the full gate).
- [ ] Commit:

```bash
git add src/Seal/Tabs/Partition.hs src/Seal/Gateway/ListsSnapshot.hs \
        src/Seal/Gateway/SessionJson.hs src/Seal/Gateway/API.hs \
        test/Seal/Tabs/PartitionSpec.hs test/Seal/Gateway/ListsSnapshotSpec.hs \
        test/Seal/Gateway/ApiSpec.hs \
        src/Seal/Command/Serve.hs test/Seal/Phase7aSpec.hs test/Seal/Gateway/ServerSpec.hs \
        src/Seal/Config/Paths.hs seal-harness.cabal
git commit -m "feat(gateway): partition sessions + GET /api/lists (W1)"
```

---

## Task W2: ensureTabForSession + web handleSend auto-tab

**Files:**
- Modify: `src/Seal/Gateway/Send.hs` (add `ensureTabForSession`; call it in `handleSend` on the Plain/SlashCommand/NewSession branches).
- Test: `test/Seal/Gateway/SendSpec.hs` (create if absent; extend if present).

**Interfaces:**
- Produces: `ensureTabForSession :: TabsHandle -> TabKind -> SessionId -> IO ()`.
- Consumes: `TabsHandle`, `TabKind` (from `Seal.Handles.Tab`), `SessionId` (from `Seal.Core.Types`).

### Step 1: Write the failing test

- [ ] Create or extend `test/Seal/Gateway/SendSpec.hs`:

```haskell
-- Sketched: build a SendDeps with a real tabsH + a tmp sessions root,
-- pre-seed a session.json for sid, call handleSend with a Plain message,
-- assert a follow-up snapshotTabs has a BoundSession sid KindProvider tab.

describe "ensureTabForSession" $ do
  it "is idempotent — no-op when a tab already binds the sid" $ do
    -- insert a tab, call ensureTabForSession, assert exactly one tab
  it "skips on Left 'full' / Left 'duplicate' (logs, does not throw)" $ do
    -- fill the tab list to capacity, call ensureTabForSession, assert no throw + no new tab

describe "handleSend auto-tab" $ do
  it "Plain route → auto-tabs after a successful turn" $ do
    -- pre-seed session.json, call handleSend with "hello", assert snapshotTabs has the tab
  it "SendError (404 missing session) → no auto-tab" $ do
    -- call handleSend with a non-existent sid, assert no tab
  it "TabCommand/Focus/Inject routes → no auto-tab" $ do
    -- call handleSend with "/tab list", "/focus 0", "/inject 0 hello", assert no tab
```

(Use the existing `SendDeps` construction pattern — read `test/Seal/Gateway/ApiSpec.hs:2187` for the `handleSend` test setup with a real `session.json`. The `plainTurn` path needs a provider runtime — use a stub provider that returns a fixed completion so the turn "succeeds" without a real LLM call. Read `Seal.Gateway.Send` test helpers if they exist.)

- [ ] Run: `make test -- -m "/handleSend auto-tab/"`
- Expected: FAIL — `ensureTabForSession` not found.

### Step 2: Implement `ensureTabForSession` + wire into `handleSend`

- [ ] Modify `src/Seal/Gateway/Send.hs`:

```haskell
-- | Idempotent: if no tab binds @sid@, insert a @BoundSession sid@ tab of the
-- given kind at the lowest free index. Sources the SessionId only from
-- server-validated contexts (the caller passes the SessionMeta's smId, never
-- a raw client string). Failure (full/duplicate) is logged to stderr (ids
-- only) and does not propagate — the tab is a UI affordance.
ensureTabForSession :: TabsHandle -> TabKind -> SessionId -> IO ()
ensureTabForSession tabsH kind sid = do
  tl <- snapshotTabs tabsH
  let alreadyBound = any (\t -> tRef t == BoundSession sid) (tlTabs tl)
  if alreadyBound
    then pure ()
    else do
      r <- insertTabH tabsH (BoundSession sid) kind Nothing
      case r of
        Left e -> hPutStrLn stderr ("[auto-tab] could not insert tab for " <> T.unpack (sessionIdText sid) <> ": " <> T.unpack e)
        Right _ -> pure ()
```

- [ ] Wire into `handleSend`: after the `Plain t` branch's successful `plainTurn` (Right () → SendAssistant), call `ensureTabForSession (sdTabsHandle deps) KindProvider (smId meta)`. Add `sdTabsHandle :: TabsHandle` to `SendDeps` (if not already present — read `SendDeps` record). Do the same for the `SlashCommand`/`NewSession` branches (after `runSlash` returns a non-`SendError` outcome). **Do NOT auto-tab** on the `TabCommand`/`Focus`/`Inject` branches.

(Verify `SendDeps` has a tabs handle; if not, add `sdTabsHandle :: TabsHandle`. Update construction sites per the Construction-site update checklist: `src/Seal/Command/Serve.hs` (the `sendDeps` literal) AND `test/Seal/Gateway/ApiSpec.hs` at **three** sites — lines ~2000, ~2083, ~2198 (grep `SendDeps` to confirm). Pass the `tabsH` in scope at each site.)

- [ ] Run: `make test -- -m "/handleSend auto-tab/"`
- Expected: PASS.

### Step 3: Concurrency test

- [ ] Add to `SendSpec.hs`:

```haskell
it "ensureTabForSession is race-safe: two threads, exactly one tab" $ do
  -- pre-seed session, fork two threads calling ensureTabForSession, assert one tab
```

- [ ] Run `make test -- -m "/race-safe/"`
- Expected: PASS.

### Step 4: Commit

- [ ] `make check`
- [ ] Commit: `git commit -m "feat(gateway): auto-tab on send — web path (W2)"`

---

## Task W4: Unified TabsHandle (before W3)

**Files:**
- Modify: `src/Seal/Channels/Loop.hs` — add `cdTabs :: TabsHandle` to `ChannelDeps`; `newChannelDeps` takes `tabsH`.
- Modify: `src/Seal/Command/Serve.hs` — single `tabsH` created once; pass to `newChannelDeps` + the three channel listener forks.
- Test: `test/Seal/Command/ServeSpec.hs` (create if absent).

**Interfaces:**
- Produces: `cdTabs :: TabsHandle` field on `ChannelDeps`.
- Consumes: `TabsHandle` (from `Seal.Tabs`).

### Step 1: Write the failing test

- [ ] Create `test/Seal/Command/ServeSpec.hs`:

```haskell
-- Sketched: construct the full Serve deps with a single tabsH, fork a fake
-- channel message through the shared handle, GET /api/tabs, assert the
-- channel-created tab is visible.
it "under seal serve, a tab inserted by a channel listener is visible via GET /api/tabs" $ do
  -- ... build the app with a shared tabsH, simulate a Signal send through
  -- the channel loop (use a FakeChannel + the shared handle), assert
  -- GET /api/tabs returns the channel-created tab.
```

(Read `test/Seal/Channels/LoopSpec.hs` for the FakeChannel + runChannelLoop test pattern. The test doesn't need a real Signal transport — it drives `runChannelLoop` with a fake channel that pushes one message, and asserts the tab appears via the ApiDeps.)

- [ ] Run: `make test -- -m "/ServeSpec/"`
- Expected: FAIL — `cdTabs` field doesn't exist.

### Step 2: Add `cdTabs` to `ChannelDeps` + thread through

- [ ] Modify `src/Seal/Channels/Loop.hs`:
  - Add `cdTabs :: TabsHandle` to the `ChannelDeps` record.
  - `newChannelDeps` takes a new `tabsH :: TabsHandle` arg and sets `cdTabs = tabsH`.

- [ ] Modify `src/Seal/Command/Serve.hs`:
  - The single `tabsH <- newTabsHandle` (line 105) is the shared one.
  - Pass `tabsH` to `newChannelDeps`.
  - The three channel listener forks (`forkSignalListener`, `forkTelegramListener`) no longer call `newTabsHandle` — they receive the shared `tabsH` via `ChannelDeps.cdTabs` (update their signatures to take `cdTabs` instead of forking their own). `runChannelLoop`'s `tabsH` arg becomes `cdTabs deps`.
  - **Leave the standalone `seal signal` / `seal telegram` entry points as-is** (they keep `newTabsHandle`).

- [ ] Update `Seal.Channels.Signal.Run` / `Seal.Channels.Telegram.Run` if they fork `newTabsHandle` internally — they should take the handle from `ChannelDeps` when invoked under `seal serve`, but the standalone entry points still create their own.

- [ ] Run `make build` — fix any construction-site breakage.
- [ ] Run `make test -- -m "/ServeSpec/"`
- Expected: PASS.

### Step 3: Update all `newChannelDeps` callers

- [ ] Grep for `newChannelDeps` callers — update each to pass `tabsH`. (Standalone entry points pass their own `newTabsHandle`; `seal serve` passes the shared one.)

- [ ] Run `make check`
- Expected: PASS.

### Step 4: Commit + human checkpoint

- [ ] Commit: `git commit -m "feat(channels): unified TabsHandle across channels under seal serve (W4)"`
- [ ] **PAUSE FOR HUMAN REVIEW** — this is a deliberate behavior change (channel tabs now visible in web sidebar).

---

## Task W3: Auto-tab in channel plainTurn + CLI plainHandler

**Files:**
- Modify: `src/Seal/Channels/Loop.hs` — call `ensureTabForSession (cdTabs deps) KindAi sid` after a successful `plainTurn` in the channel loop.
- Modify: `src/Seal/Channel/Cli.hs` — call `ensureTabForSession tabsH KindAi sid` after `plainHandler`'s turn.
- Test: `test/Seal/Channels/LoopSpec.hs` (extend).

**Interfaces:**
- Consumes: `ensureTabForSession` (from W2), `cdTabs` (from W4).

### Step 1: Write the failing tests (channel loop + CLI)

- [ ] Extend `test/Seal/Channels/LoopSpec.hs`:

```haskell
it "a tab-less session messaged via the channel loop gets a KindAi tab" $ do
  -- pre-seed sessionsRoot/<sid>/session.json (no tab), drive runChannelLoop
  -- with a FakeChannel pushing one Plain message for sid, assert
  -- snapshotTabs (cdTabs deps) has a BoundSession sid KindAi tab.
```

- [ ] Add a CLI `plainHandler` auto-tab test. The CLI path runs `plainHandler` via `Seal.Channel.Cli.runCliTui`/`loop`; read `test/Seal/Channel/CliSpec.hs` (or `test/Seal/Phase2bSpec.hs` which drives a FakeChannel through the CLI) for the test pattern. If no CLI harness exists, add a focused unit test in `test/Seal/Channel/CliSpec.hs`:

```haskell
it "a tab-less session messaged via the CLI plainHandler gets a KindAi tab" $ do
  -- pre-seed sessionsRoot/<sid>/session.json (no tab), drive the CLI loop
  -- with a FakeChannel pushing one Plain message for sid, assert
  -- snapshotTabs tabsH has a BoundSession sid KindAi tab.
```

(If driving the full CLI loop in a test is impractical, test `ensureTabForSession` directly against a `TabsHandle` — it's the same function the channel loop calls; the CLI test then asserts the CLI's `tabsH` is the one the auto-tab targets. Read the existing `CliSpec`/`Phase2bSpec` to pick the lightest seam.)

- [ ] Run: `make test -- -m "/channel loop/"`
- Expected: FAIL (no auto-tab in the loop yet).

### Step 2: Wire auto-tab into the channel loop

- [ ] Modify `src/Seal/Channels/Loop.hs`:
  - In `runChannelLoop`'s `Plain t` branch (around line 311), after `plainHandler h meta (Just ms) t` completes, call `ensureTabForSession (cdTabs deps) KindAi (smId meta)`.
  - The `createConversationSession` path already inserts a tab — `ensureTabForSession` is idempotent, so the double-call is a no-op.

- [ ] Modify `src/Seal/Channel/Cli.hs`:
  - After `plainHandler`'s turn completes, call `ensureTabForSession tabsH KindAi sid` (the CLI's `tabsH` is the shared one under `seal serve`; the standalone `seal cli` keeps its own — verify the wiring).

- [ ] Run `make test -- -m "/channel loop/"`
- Expected: PASS.

### Step 3: Commit

- [ ] `make check`
- [ ] Commit: `git commit -m "feat(channels): auto-tab on send — channel + CLI paths (W3)"`

---

## Task W5: Seal.Tabs.Persist + boot reconcile

**Files:**
- Modify: `src/Seal/Tabs/Persist.hs` — implement for real (atomic, 0600, MVar-serialized, id-validation).
- Modify: `src/Seal/Tabs.hs` — wrap mutations to persist (the persisting wrapper).
- Create: `src/Seal/Harness/Reconcile/Seam.hs` — `ReconcileRunner` record.
- Modify: `src/Seal/Command/Serve.hs` — boot `loadTabList` + reconcile pass.
- Test: `test/Seal/Tabs/PersistSpec.hs` (extend or create).
- Test: `test/Seal/Command/ServeSpec.hs` (extend with boot reconcile cases).

**Interfaces:**
- Produces: `saveTabList :: TabsHandle -> IO ()` (real), `loadTabList :: IO (Maybe TabList)` (real), `ReconcileRunner` record.

### Step 1: Write the failing persistence test

- [ ] Extend `test/Seal/Tabs/PersistSpec.hs` (create if absent):

```haskell
describe "saveTabList/loadTabList round-trip" $ do
  it "save then load returns the tab list" $ do
    h <- newTabsHandle
    _ <- insertTabH h (BoundSession (mkSid "s1")) KindAi Nothing
    saveTabList h
    loaded <- loadTabList
    loaded `shouldSatisfy` isJust
    let Just tl = loaded
    map tRef (tlTabs tl) `shouldBe` [BoundSession (mkSid "s1")]

  it "missing file → Nothing" $ do
    -- point loadTabList at a tmp path with no tabs.json
    loaded <- loadTabList
    loaded `shouldBe` Nothing

  it "corrupt JSON → Nothing + stderr warning (ids only)" $ do
    -- write garbage to tabs.json, loadTabList, assert Nothing

  it "unparseable TabRef id → tab skipped, not error" $ do
    -- write a tabs.json with a tab carrying an invalid sid, loadTabList,
    -- assert the tab is dropped

describe "auto-save-on-mutation" $ do
  it "insertTabH triggers a save (loadTabList returns the new tab)" $ do
    h <- newTabsHandle
    _ <- insertTabH h (BoundSession (mkSid "s1")) KindAi Nothing
    loaded <- loadTabList
    loaded `shouldSatisfy` isJust
```

(These tests need `loadTabList`/`saveTabList` to know the path — the signatures now take a `FilePath` (from `tabListPath paths`). Tests pass a tmp path. The persisting wrapper (Step 3) holds the path so call sites don't have to.)

- [ ] Run: `make test -- -m "/Persist/"`
- Expected: FAIL.

### Step 2: Implement `Seal.Tabs.Persist` for real

- [ ] **Add `tabListPath :: SealPaths -> FilePath` to `src/Seal/Config/Paths.hs`** (mirrors `sessionArchivedMarkerPath` — e.g. `spState paths </> "tabs.json"`). Export it.

- [ ] Modify `src/Seal/Tabs/Persist.hs` — **signatures take a `FilePath`** (the path comes from `tabListPath paths`, threaded in by the caller):

```haskell
module Seal.Tabs.Persist
  ( saveTabList
  , loadTabList
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar)
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.List (filter)
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)
import System.Posix.Files (setFileMode, unionFileModes, ownerReadMode, ownerWriteMode)

import Seal.Core.Types (mkSessionId, sessionIdText)
import Seal.Harness.Id (parseHarnessId, harnessIdToText)  -- harnessIdToText, NOT harnessIdText
import Seal.Handles.Tab (TabRef (..))
import Seal.Tabs (TabsHandle, snapshotTabs)
import Seal.Tabs.Types (Tab (..), TabList (..))

-- Module-level MVar serializes writes. Initialized once (unsafePerformIO).
writeLock :: MVar ()
writeLock = unsafePerformIO (newMVar ())
{-# NOINLINE writeLock #-}

-- | Atomic write: .tmp + rename, mode 0600, serialized via writeLock.
saveTabList :: FilePath -> TabsHandle -> IO ()
saveTabList path h = modifyMVar_ writeLock $ \_ -> do
  tl <- snapshotTabs h
  createDirectoryIfMissing True (takeDirectory path)
  let tmp = path <> ".tmp"
  BL.writeFile tmp (A.encode tl)
  setFileMode tmp (unionFileModes ownerReadMode ownerWriteMode)  -- 0600
  renameFile tmp path

-- | Load + validate every TabRef id. Unparseable → tab skipped. Missing file → Nothing.
--   stderr warnings are ids + error type only (no session content).
loadTabList :: FilePath -> IO (Maybe TabList)
loadTabList path = do
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      bs <- BL.readFile path
      case A.decode bs :: Maybe TabList of
        Nothing -> do
          hPutStrLn stderr "Warning: could not parse tabs.json; using empty tab list"
          pure Nothing
        Just tl -> pure (Just (filterValidTabs tl))
  where
    filterValidTabs tl = tl { tlTabs = filter validRef (tlTabs tl) }
    validRef (BoundSession sid) = case mkSessionId (sessionIdText sid) of Right _ -> True; Left _ -> False
    validRef (BoundHarness hid) = case parseHarnessId (harnessIdToText hid) of Right _ -> True; Left _ -> False
```

(Note: `saveTabList`/`loadTabList` now take a `FilePath` — update the existing stub signatures and all callers. The MVar is module-level so concurrent writes serialize across all callers; the `FilePath` arg means the same lock guards all `tabs.json` writes regardless of path.)

- [ ] Run: `make test -- -m "/Persist/"`
- Expected: PASS.

### Step 3: Wrap `TabsHandle` mutations to persist

- [ ] Modify `src/Seal/Tabs.hs`:
  - Add a `PersistingTabsHandle` variant (or a flag on the existing `TabsHandle`) so mutations call `saveTabList` after the STM commit. The simplest: a new constructor `newPersistingTabsHandle :: FilePath -> IO TabsHandle` that wraps the TVar + a `FilePath` + an MVar, and each `insertTabH`/`removeTabH`/`rebindTabH`/`renameTabH` calls `saveTabList path` after `writeTVar`.

  - Alternatively, leave `TabsHandle` as-is and have `Serve.hs` call `saveTabList (tabListPath paths)` after each mutation site — but this is error-prone (the wrapper is safer). Choose the wrapper.

- [ ] Run: `make test -- -m "/auto-save/"`
- Expected: PASS.

### Step 4: ReconcileRunner seam + boot reconcile test

- [ ] Create `src/Seal/Harness/Reconcile/Seam.hs`:

```haskell
module Seal.Harness.Reconcile.Seam
  ( ReconcileRunner (..)
  , realReconcileRunner
  ) where

import Seal.Harness.Reconcile (reconcileTick, defaultOrphanGraceTicks)
import Seal.Harness.Registry (HarnessRegistry, HarnessEntry)
import Seal.Harness.Tmux (TmuxRunner, TmuxIdent)
import Seal.Session.Kind (HarnessFlavour)

-- | A record-of-actions seam over 'reconcileTick' so tests can inject a fake
-- without a live tmux.
data ReconcileRunner = ReconcileRunner
  { rrTick :: HarnessRegistry -> TmuxRunner -> TmuxIdent -> HarnessFlavour -> Int -> IO [HarnessEntry]
  }

realReconcileRunner :: ReconcileRunner
realReconcileRunner = ReconcileRunner { rrTick = reconcileTick }
```

- [ ] Extend `test/Seal/Command/ServeSpec.hs`:

```haskell
it "boot reconcile: persisted BoundHarness missing → orphaned; BoundSession missing session.json → dropped" $ do
  -- write a tabs.json with a BoundHarness hid + a BoundSession sid,
  -- set the ReconcileRunner seam to report hid as missing,
  -- delete sid's session.json, boot, assert snapshotTabs has the harness
  -- tab marked orphaned and no session tab.
```

- [ ] Run: `make test -- -m "/boot reconcile/"`
- Expected: FAIL.

### Step 5: Wire boot reconcile into Serve

- [ ] Modify `src/Seal/Command/Serve.hs`:
  - Before `forkIO (runStreamServer ...)`, after `tabsH <- newTabsHandle` (or the new `newPersistingTabsHandle (tabListPath paths)`), call `loadTabList (tabListPath paths)` and seed the TVar (if `Just tl`, write it; if `Nothing`, the empty default is already set).
  - Run the boot reconcile pass: for each `BoundHarness hid` tab, run `rrTick` (the seam) over the harness id; for each `BoundSession sid`, check `session.json` exists, drop if missing.

- [ ] Run: `make test -- -m "/boot reconcile/"`
- Expected: PASS.

### Step 6: Commit + human checkpoint

- [ ] `make check`
- [ ] Commit: `git commit -m "feat(tabs): persist tab list + boot reconcile-to-orphaned (W5)"`
- [ ] **PAUSE FOR HUMAN REVIEW** — restart-time behavior; manually verify: create a tab, restart `seal serve`, confirm the tab survives.

---

## Task W6: broadcastLists triggers + debouncedBroadcast + adBroker wiring

**Files:**
- Modify: `src/Seal/Gateway/API.hs` — `debouncedBroadcast :: ApiDeps -> IO ()` helper; call after every state change (tab insert/remove/rebind/rename/acknowledge/release, archive/unarchive, session new/rebind-new, conversation-session create, auto-tab insert).
- Modify: `src/Seal/Gateway/Send.hs` — call `debouncedBroadcast` (via `sdBroker`) after auto-tab.
- Modify: `src/Seal/Channels/Loop.hs` — call `debouncedBroadcast` (via `cdBroker`) after channel auto-tab + conversation-session create.
- Test: `test/Seal/Gateway/StreamBrokerSpec.hs` (extend — all trigger sites + debounce).

**Interfaces:**
- Produces: `debouncedBroadcast :: ApiDeps -> IO ()` (or a `debouncedBroadcast :: Maybe StreamBroker -> ApiDeps -> IO ()`).

### Step 1: Write the failing test — every trigger site

- [ ] Extend `test/Seal/Gateway/StreamBrokerSpec.hs`:

```haskell
-- Use a fake broker that captures BeListsSnapshot calls.
describe "broadcastLists triggers" $ do
  it "tab insert → broadcast" $ ...
  it "tab remove → broadcast" $ ...
  it "tab rebind → broadcast" $ ...
  it "tab rename → broadcast" $ ...
  it "tab acknowledge → broadcast" $ ...
  it "tab release → broadcast" $ ...
  it "archive → broadcast" $ ...
  it "unarchive → broadcast" $ ...
  it "session new → broadcast" $ ...
  it "session rebind-new → broadcast" $ ...
  it "conversation-session create → broadcast" $ ...
  it "auto-tab insert → broadcast" $ ...

describe "debouncedBroadcast" $ do
  it "two triggers within 50ms → exactly one broadcast" $ ...
  it "reconcile sweep: no status change → no broadcast" $ ...
  it "reconcile sweep: status change → broadcast" $ ...
```

- [ ] Run: `make test -- -m "/broadcastLists triggers/"`
- Expected: FAIL.

### Step 2: Implement `debouncedBroadcast`

- [ ] In `src/Seal/Gateway/API.hs` (or a new `Seal.Gateway.Broadcast` module):

```haskell
-- | Coalesce broadcastLists calls within a 50ms window. The last call wins
-- (a fresh buildListsSnapshot runs at the window edge). Bounds the broadcast
-- rate when many triggers fire in quick succession (e.g. send + auto-tab).
debouncedBroadcast :: ApiDeps -> IO ()
debouncedBroadcast deps =
  case adBroker deps of
    Nothing -> pure ()
    Just broker -> do
      -- implement with a TVar (Maybe (IO ())) + a forkIO timer; on each call,
      -- replace the pending action; the timer fires buildListsSnapshot + broadcastLists.
```

(Implement the debounce with a `TVar (Maybe UTCTime)` + a single forkIO watcher, or an `MVar (Maybe (IO ()))` + a worker thread. Keep it simple.)

- [ ] Wire `debouncedBroadcast deps` into every state-change handler in `API.hs` (tab insert/remove/rebind/rename/acknowledge/release, archive/unarchive, session new/rebind-new).

- [ ] Wire into `Send.hs` (after auto-tab) and `Channels/Loop.hs` (after auto-tab + conversation-session create) via the broker field.

- [ ] Run: `make test -- -m "/broadcastLists triggers/"`
- Expected: PASS.

### Step 3: Reconcile-sweep broadcast (status change only)

- [ ] Modify the periodic reconcile sweep in `Serve.hs` (or wherever it runs): compare the pre-tick snapshot to the post-tick snapshot; if any tab's orphaned/running status changed, call `debouncedBroadcast`. If no change, skip.

- [ ] Test: extend `StreamBrokerSpec` with the two reconcile cases (status change → broadcast; no change → no broadcast).

- [ ] Run `make test -- -m "/reconcile sweep/"`
- Expected: PASS.

### Step 4: Commit

- [ ] `make check`
- [ ] Commit: `git commit -m "feat(gateway): wire broadcastLists triggers + debounce (W6)"`

---

## Task W7: Frontend — useListsPoll + App.tsx precedence + Sidebar filter

**Files:**
- Modify: `frontend/src/hooks/useApi.ts` — add `useListsPoll()`.
- Modify: `frontend/src/App.tsx` — 3-tier precedence.
- Modify: `frontend/src/components/Sidebar.tsx` — defensive `recentSessions` filter.
- Modify: `frontend/src/types.ts` — update the `findSession` comment to past-tense.
- Test: `frontend/src/hooks/__tests__/useApi.test.ts` (extend).
- Test: `frontend/src/__tests__/App.test.tsx` (extend).
- Test: `frontend/src/components/__tests__/Sidebar.test.tsx` (extend).
- Test: `frontend/e2e/capstone.spec.ts` (extend).

### Step 1: Write the failing `useListsPoll` test

- [ ] Extend `frontend/src/hooks/__tests__/useApi.test.ts`:

```typescript
describe('useListsPoll', () => {
  it('polls /api/lists and returns the four arrays + error flag', async () => {
    // mock fetch returning { tabs: [], recentSessions: [s1], archivedSessions: [], tabSessions: [] }
    // assert the hook returns the shape, error: false
  })
  it('maps TabInfoWire[] to TabInfo[] via mapTabInfo', async () => { ... })
  it('on 404, sets error: true', async () => { ... })
})
```

- [ ] Run: `cd frontend && npm run test -- useListsPoll`
- Expected: FAIL.

### Step 2: Implement `useListsPoll`

- [ ] Modify `frontend/src/hooks/useApi.ts`:

```typescript
export interface ListsPollResult {
  tabs: TabInfo[]
  recentSessions: SessionInfo[]
  archivedSessions: SessionInfo[]
  tabSessions: SessionInfo[]
  error: boolean
  refresh: () => void
}

export function useListsPoll(): ListsPollResult {
  const [snap, setSnap] = useState<ListsPollResult['tabs'] extends never ? never : Omit<ListsPollResult, 'refresh'>>(
    { tabs: [], recentSessions: [], archivedSessions: [], tabSessions: [], error: false }
  )
  const [error, setError] = useState(false)
  const poll = useCallback(async () => {
    const data = await fetchJson<{ tabs: TabInfoWire[]; recentSessions: SessionInfo[]; archivedSessions: SessionInfo[]; tabSessions: SessionInfo[] }>('/api/lists')
    if (data) {
      setSnap({ tabs: data.tabs.map(mapTabInfo), recentSessions: data.recentSessions, archivedSessions: data.archivedSessions, tabSessions: data.tabSessions })
      setError(false)
    } else {
      setError(true)
    }
  }, [])
  useEffect(() => { poll(); const id = setInterval(poll, POLL_INTERVAL); return () => clearInterval(id) }, [poll])
  return { ...snap, error, refresh: poll }
}
```

(Return shape intentionally identical to `useListsStream` so a future refactor could swap them behind a common interface.)

- [ ] Run: `cd frontend && npm run test -- useListsPoll`
- Expected: PASS.

### Step 3: `App.tsx` 3-tier precedence

- [ ] Modify `frontend/src/App.tsx`:
  - Add a `wsListsReceived` flag (local state in `App.tsx` — owner pinned here), set true on first WS `lists` frame, reset on WS reconnect.
  - Replace the per-field `wsLists.tabs.length > 0 ? ...` precedence with:
    1. If `wsListsReceived` → use `wsLists` for all four fields.
    2. Else if `!useListsPoll().error` → use `useListsPoll()` for all four fields.
    3. Else → fall back to the legacy `polledTabs`/`polledRecent`/`polledArchived` (and `tabSessions = []`).
  - `useListsPoll` is always active (polls on mount regardless of WS state); `App.tsx` selects which source to render.

- [ ] Extend `frontend/src/__tests__/App.test.tsx`:

```typescript
it('renders a session in Active Tabs only when a buggy WS frame carries it in both tabs and recentSessions', () => {
  // mock WS lists frame: tabs: [{ session_id: 's1' }], recentSessions: [{ id: 's1' }]
  // assert the sidebar shows s1 under Active Tabs, NOT under Recent Sessions
  // (the Sidebar defensive filter drops it from Recent Sessions)
})
```

- [ ] Run: `cd frontend && npm run test`
- Expected: FAIL (Sidebar doesn't filter yet).

### Step 4: `Sidebar.tsx` defensive filter

- [ ] Modify `frontend/src/components/Sidebar.tsx`:

```typescript
// Defense-in-depth: the backend guarantees no tab-backed session is in
// `sessions`, but a buggy WS frame could violate that — this filter drops
// any session that's also in `tabs[].session_id` so the sidebar never shows
// a duplicate. The backend is the source of truth; this is the safety net.
const recentSessions = sessions.filter(
  (s) => !tabs.some((t) => t.session_id === s.id)
)
```

- [ ] Run: `cd frontend && npm run test`
- Expected: PASS.

### Step 5: `types.ts` comment fix

- [ ] Modify `frontend/src/types.ts:136` — update the comment from aspirational ("are deduped OUT by the backend") to past-tense accurate, OR reword to "the backend partitions sessions into mutually-exclusive lists; `tabSessions` carries the tab-backed ones." The point: the comment is no longer a lie.

### Step 6: E2E test

- [ ] Extend `frontend/e2e/capstone.spec.ts`:

```typescript
it('auto-tabs a tab-less session on send', () => {
  // start the server, create a session via /api/sessions/new, send a message
  // via /api/sessions/:id/send, assert the sidebar shows a new tab in
  // Active Tabs and the session is gone from Recent Sessions within one
  // poll interval.
})
```

- [ ] Run: `cd frontend && npm run test:e2e -- capstone`
- Expected: PASS (requires the running server — the E2E setup handles that).

### Step 7: Commit

- [ ] `cd frontend && npm run build && npm run test`
- [ ] `make check` (backend gate)
- [ ] Commit: `git commit -m "feat(frontend): useListsPoll + 3-tier precedence + defensive filter (W7)"`

---

## Final integration check

- [ ] `make check` (backend: build + test + lint)
- [ ] `cd frontend && npm run build && npm run test && npm run test:e2e`
- [ ] Manual smoke test: start `seal serve`, open the web UI, create a session via "Recent Sessions +", send a message → assert a tab appears in "Active Tabs" and the session leaves "Recent Sessions"; restart `seal serve` → assert the tab survives (marked orphaned if it was a harness tab).
- [ ] Create the PR: `gh pr create --title "feat: session partition invariants + auto-tab + unified persistent tabs" --body "..."` (body summarizes the design + issue link + DoD checklist).

## Self-Review (run before presenting the plan)

**1. Spec coverage:**
- Partition invariant → W1 (partitionSessions), W6 (broadcast), W7 (frontend filter). ✓
- Auto-tab on send → W2 (web), W3 (channel/CLI), W4 (unified handle enables cross-channel). ✓
- Unified persistent tabs → W4 (unified), W5 (persistence + boot reconcile). ✓
- Sub-session exclusion → W1 (already excluded by listSessions; W2/W3 rely on loadSessionMeta returning Nothing). ✓
- Archived + tab-bound edge case → W1 test. ✓
- WS lists frame finally emitted → W6. ✓
- Frontend `findSession` comment fix → W7. ✓
- Security mitigations (MVar serialization, id-validation, 0600, server-validated SessionId) → W5, W2. ✓

**2. Placeholder scan:** No "TBD"/"TODO" in the plan. The "Sketched" test blocks are illustrative — the implementer reads the existing test patterns (`ApiSpec.hs:2187`, `LoopSpec.hs`) for the exact construction. The code blocks show actual Haskell/TS.

**3. Type consistency:**
- `ensureTabForSession :: TabsHandle -> TabKind -> SessionId -> IO ()` — same signature in W2 (definition) and W3 (call sites). ✓
- `cdTabs :: TabsHandle` — W4 (definition) and W3 (consumption). ✓
- `ListsSnapshotWire` — W1 (definition) and W6 (broadcast). ✓
- `partitionSessions` — W1 (definition) and W1 (buildListsSnapshot consumption). ✓
- `ReconcileRunner` — W5 (definition) and W5 (boot consume). ✓

**4. Dependency order:** W1 → (W2, W4) → W3 (needs W4) → (W5, W6) → W7. W6 depends on W1's `buildListsSnapshot` (noted in the dependency graph). ✓