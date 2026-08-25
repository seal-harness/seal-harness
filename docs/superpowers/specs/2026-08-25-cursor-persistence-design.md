# Design: Cursor Persistence (survive gateway restart)

**Status**: Approved (direct-to-implementation, no brainstorm gate per user)
**Date**: 2026-08-25
**Bug**: `/model use` change lost after `seal serve` restart on inbox channels
  (Telegram/Signal)

## 1. Problem

On an inbox-driven channel (Telegram, Signal), each conversation resolves its
session via an in-memory cursor (`CursorStore`: `ConversationKey → TabRef`).
The cursor store is a bare `TVar (Map ...)` with **no disk backing**
(`Seal.Channels.Cursor:31`). On `seal serve` restart:

1. `newChannelDeps` (`Seal.Channels.Loop:263`) calls `newCursorStore` → fresh
   empty `TVar`.
2. The next inbound message from an existing Telegram conversation:
   `cursorLookup` returns `Nothing` (`Loop.hs:399`) →
   `createConversationSession` (`Loop.hs:560`) **mints a brand-new session**
   from config defaults (`ollama/glm-5.2:cloud`), orphaning the prior session
   (whose `session.json` carries the user's `/model use` choice, e.g.
   `qwen3.8`).
3. `/model list` now resolves the **new** session's meta → shows
   `active: ollama/glm-5.2:cloud`. The user's model change appears "lost."

The model is correctly persisted in `session.json` by `useCmd`
(`Seal.Command.Model:275`); the data is not lost. What is lost is the
**conversation → session binding**, so the conversation rebinds to a
default-model session and the old session is orphaned.

### Root cause

`CursorStore` lacks the persistence hook that `TabsHandle` already has
(`thSave :: Maybe (IO ())` at `Seal.Tabs:40`, persisted via
`Seal.Tabs.Persist.saveTabList`). Tabs survive restart; cursors do not.

## 2. Goals

- The conversation → tab binding survives a `seal serve` restart (and a
  standalone `seal telegram` / `seal signal` restart).
- After restart, an existing Telegram conversation resolves to its **prior**
  session (carrying the user's `/model use` choice), not a fresh default session.
- The persistence code is DRY: the cursor reuses the same atomic-write +
  MVar-serialize + load-and-validate pattern as `tabs.json`, via a shared
  helper so the two do not drift.
- Stale cursors (pointing at a session whose `session.json` was archived /
  deleted while the gateway was down) degrade gracefully: the existing
  `resolveTabSession` (`Loop.hs:501`) already returns `Nothing` for a missing
  `session.json`, which triggers `createConversationSession` — so a stale
  cursor self-heals on the next message. No special stale-sweep needed at
  boot (a cursor pointing at a deleted session is harmless: the next message
  mints a fresh session, exactly as if the cursor were absent).

## 3. Non-goals

- No change to what the cursor stores. It still maps
  `ConversationKey → TabRef` (provider/model remain solely in `session.json`).
  The user confirmed this architecture ("Persist cursor as-is"): the cursor
  indirection (cursor → tab → session → model) is preserved; no model data is
  denormalized into the cursor.
- No change to `SessionMeta` persistence (`saveSessionMeta`) — it already
  works and is already atomic.
- No change to the `TabsHandle` on-disk format (`tabs.json`).
- No new user-facing command.

## 4. Design

### 4.1 Shared atomic-JSON persistence helper (DRY)

Extract the duplicated atomic-write-JSON + MVar-serialize pattern (currently
copy-pasted across `Seal.Tabs.Persist.saveTabList` and
`Seal.Session.Store.saveSessionMeta`, and ad-hoc in
`Seal.Security.Vault.atomicWrite`) into one helper:

```
module Seal.Util.AtomicJson
  ( saveJsonAtomic   -- :: FilePath -> BL.ByteString -> IO ()
  , saveJsonAtomicWithLock  -- variant taking an explicit MVar (per-file lock)
  ) where
```

- `saveJsonAtomic path bs`: create parent dir, write `path.tmp`, chmod 0600,
  rename over `path`. Serialized by a **module-level MVar keyed by canonical
  path** so concurrent writes to the *same* file cannot interleave, while
  writes to *different* files proceed in parallel. (A single global lock, as
  `Seal.Tabs.Persist` uses today, is also acceptable for correctness; per-path
  is a minor improvement. The simplest correct version: one global MVar,
  matching `Seal.Tabs.Persist` — prefer to match existing behavior to keep the
  change small.)

`Seal.Tabs.Persist.saveTabList` and `Seal.Channels.Cursor.Persist.saveCursorMap`
both delegate to `saveJsonAtomic`. `Seal.Session.Store.saveSessionMeta` is
left as-is in this change (it has a unique temp-file-per-call wrinkle via
`openBinaryTempFile` to avoid concurrent rename races — see §6); it is a
candidate for a follow-up consolidation but is out of scope here to keep the
diff focused. The DRY win in *this* change is that the new cursor persistence
and the existing tab persistence share one writer, so they cannot drift.

### 4.2 `Seal.Channels.Cursor.Persist`

New module, mirroring `Seal.Tabs.Persist`:

```
saveCursorMap :: FilePath -> Map ConversationKey TabRef -> IO ()
loadCursorMap :: FilePath -> IO (Maybe (Map ConversationKey TabRef))
```

- `saveCursorMap`: encode the map to JSON, call `saveJsonAtomic`. Never
  throws (write failure logs a warning and continues — the in-memory store
  stays authoritative within the process; the next mutation retries by
  writing the full current map, so a missed save self-heals, exactly like
  `Seal.Tabs.Persist`).
- `loadCursorMap`: missing file → `Nothing`; corrupt JSON → `Nothing` + a
  stderr warning (ids + error type only — no conversation content). Re-
  validate every `TabRef` id (`mkSessionId` / `parseHarnessId`) and drop
  entries whose id fails to re-parse (defense-in-depth against a tampered
  file), mirroring `Seal.Tabs.Persist.filterValidTabs`.
- JSON instances: `ConversationKey` is `(Text, Text)` — encode as a 2-element
  array `["telegram","12345"]` (aeson derives this from the tuple).
  `TabRef` already has `ToJSON`/`FromJSON` instances (used by `tabs.json`);
  reuse them. `ConversationKey` gets `ToJSON`/`FromJSON` via
  `DeriveGeneric` + `ToJSON`/`FromJSON` derivation, **or** via the existing
  tuple instances (aeson encodes `(Text,Text)` as a 2-array). Prefer the
  tuple derivation (zero new code). The map encodes as a JSON object keyed
  by the conversation key — but a tuple key is not a valid JSON object key,
  so encode the map as an **array of `{"key": [...], "ref": {...}}` pairs**
  to stay within JSON's string-keyed object constraint. This is the same
  shape `tabs.json` uses (an array of tab objects).

### 4.3 `CursorStore` gets a save hook (mirror `TabsHandle`)

```
data CursorStore = CursorStore
  { csVar  :: TVar (Map ConversationKey TabRef)
  , csSave :: Maybe (IO ())
  }

newCursorStore :: IO CursorStore
newCursorStore = CursorStore <$> newTVarIO Map.empty <*> pure Nothing

newPersistingCursorStore :: FilePath -> IO CursorStore
newPersistingCursorStore path = do
  tv <- newTVarIO Map.empty
  let store = CursorStore { csVar = tv, csSave = Just (saveAction store) }
      saveAction s = snapshotCursor s >>= saveCursorMap path
  pure store

snapshotCursor :: CursorStore -> IO (Map ConversationKey TabRef)
snapshotCursor s = readTVarIO (csVar s)

seedCursorStore :: CursorStore -> Map ConversationKey TabRef -> IO ()
seedCursorStore s m = atomically (writeTVar (csVar s) m)
```

Every mutating function (`cursorSet`, `cursorClear`, `cursorClearAll`,
`cursorMigrateAll`) runs the STM transaction, then invokes `csSave` on
success (mirroring `Seal.Tabs.persistIf`). A save failure is logged and
swallowed (in-memory stays authoritative). The `csSave` field is `Maybe` so
non-persisting callers (tests, standalone modes that opt out) are unaffected
— `newCursorStore` returns `csSave = Nothing` and the mutations are pure
in-memory, exactly as today.

### 4.4 `Seal.Config.Paths.cursorMapPath`

```
cursorMapPath :: SealPaths -> FilePath
cursorMapPath paths = spState paths </> "cursors.json"
```

Mirrors `tabListPath` (`Seal.Config.Paths:195`).

### 4.5 Startup wiring

`newChannelDeps` (`Seal.Channels.Loop:252`) currently creates the cursor
store internally (`newCursorStore` at `:263`). Change it to **accept a
`CursorStore` parameter** (like it already accepts `TabsHandle`), so the
caller chooses persisting vs non-persisting. Update its signature + the
three call sites:

- `Seal.Command.Serve.runServeMain` (`Serve.hs:173`): build a persisting
  cursor store, load `cursors.json`, seed it, pass it in. Mirror the
  `tabsH` boot block (`Serve.hs:144-150`):
  ```
  cursorsH <- newPersistingCursorStore (cursorMapPath paths)
  mCursors <- loadCursorMap (cursorMapPath paths)
  case mCursors of
    Nothing -> pure ()
    Just m  -> seedCursorStore cursorsH m
  ```
  No stale-sweep at boot (§2, §5.3): a cursor pointing at a deleted session
  is harmless — `resolveTabSession` returns `Nothing` and a fresh session is
  minted on the next message.

- `Seal.Channels.Telegram.Run.runTelegramMain` (`Telegram/Run.hs:158`):
  same boot block. (Standalone `seal telegram` also loses cursors on
  restart today; the fix applies identically.)

- `Seal.Channels.Signal.Run.runSignalMain` (`Signal/Run.hs`): same.

Tests (`Seal.Channels.LoopSpec`, `Seal.Channels.Signal.RunSpec`,
`Seal.Channels.Telegram.RunSpec`): pass `newCursorStore` (non-persisting) —
no behavior change. `newChannelDeps`'s internal `newCursorStore` call is
removed; tests pass their own.

### 4.6 No model-data duplication

The cursor stores only `TabRef`. `session.json` stores `smProvider`/
`smModel`. The two are **synchronized by construction**: the cursor points
at a tab, the tab points at a session, the session carries the model.
`/model use` writes `session.json` (`useCmd` → `saveSessionMeta`); the
cursor is untouched (correct — the binding didn't change, only the model
did). After this fix, both files survive restart, so the conversation
re-resolves to the same session and reads the same model. There is exactly
one copy of the model (in `session.json`); DRY is satisfied.

## 5. Edge cases

### 5.1 Concurrent writes

`saveJsonAtomic` is MVar-serialized per process (matching
`Seal.Tabs.Persist`). Concurrent `cursorSet` from multiple Telegram
conversations each commit their STM transaction then serialize on the MVar;
each writes the **full current map** (snapshot taken inside the save
action), so the last writer wins with a consistent view. No partial write.

### 5.2 Boot load vs. first mutation

If `cursors.json` exists but is empty/corrupt, `loadCursorMap` returns
`Nothing`; the store seeds empty; the first `cursorSet` persists the
single-entry map. Self-healing.

### 5.3 Stale cursor (session deleted/archived while down)

A cursor points at `BoundSession sid` whose `session.json` was removed
while the gateway was down. On the next message, `resolveTabSession`
(`Loop.hs:501-509`) checks `doesFileExist (sessionDir </> "session.json")`,
returns `Nothing`, and the loop falls through to
`createConversationSession` (`Loop.hs:407`) — a fresh session is minted and
the cursor is rebound. The stale entry is overwritten in memory and on
disk by the `cursorSet` in `createConversationSession` (`Loop.hs:579`). No
boot-time sweep needed. (A boot-time sweep would be a minor optimization —
drop obviously-stale entries — but is not required for correctness and is
omitted to keep the diff small.)

### 5.4 Tab closed while down

A cursor points at a tab that was removed (the tab list was mutated while
the gateway was down — only possible if another process edited
`tabs.json`, which is not a supported workflow). The cursor still points
at `BoundSession sid`; `resolveTabSession` reads `session.json` directly
(ignoring the tab list), so the session resolves as long as its
`session.json` exists. The tab is a UI affordance, not a correctness
requirement (matching `ensureTabForSession`'s design). No issue.

### 5.5 Standalone vs. serve

Under `seal serve`, `CursorStore` persists to `\<state\>/cursors.json`.
Under standalone `seal telegram` / `seal signal`, the same path is used
(`getSealPaths` resolves the same state dir). Both modes gain
persistence. Tests pass `newCursorStore` (no path, no persistence).

## 6. Why not consolidate `saveSessionMeta` into the shared helper now

`saveSessionMeta` (`Seal.Session.Store:105`) uses
`openBinaryTempFile` (a unique temp name per call) rather than a fixed
`path.tmp`, specifically to avoid a concurrent-rename race when multiple
threads save the *same* session meta concurrently (channel loop + gateway
API + `/model` command can all save the same session). The fixed-`.tmp`
pattern in `Seal.Tabs.Persist` relies on the MVar to serialize, which works
for tabs (one tab list) but `saveSessionMeta` guards per-session files with
uniqueness instead. Consolidating them safely requires per-path locking in
the shared helper, which is a larger change. **Out of scope for this fix.**
The DRY consolidation here is cursor + tabs (both use the fixed-`.tmp` +
MVar pattern); session meta stays as-is with a note for a future cleanup.

## 7. Test plan

New spec `test/Seal/Channels/CursorSpec.hs` (or extend
`test/Seal/Channels/CursorSpec.hs` if a stub exists — search confirms none;
create new):

1. **Round-trip**: `newPersistingCursorStore path`; `cursorSet` two
   entries; read `cursors.json` from disk; `loadCursorMap` returns the same
   map. (Pure persistence.)
2. **Restart recovery**: store with two cursors; save; create a *new*
   `newPersistingCursorStore` at the same path (simulating a restart);
   `loadCursorMap` + `seedCursorStore`; `cursorLookup` returns both
   entries. (The core bug fix.)
3. **Stale cursor self-heals**: seed a cursor pointing at a sid whose
   `session.json` does not exist; `resolveTabSession` (via the loop, or
   directly) returns `Nothing`. (Confirms no boot sweep needed.)
4. **Tampered file**: write garbage to `cursors.json`; `loadCursorMap`
   returns `Nothing` (no crash).
5. **Invalid TabRef id**: hand-write a `cursors.json` with a
   `BoundSession "not-a-valid-sid"`; `loadCursorMap` drops that entry,
   returns the rest.
6. **Non-persisting store unaffected**: `newCursorStore`; `cursorSet`;
   `csSave` is `Nothing`; no file is written; `cursorLookup` returns the
   entry. (Tests still use this.)
7. **Concurrent writes don't corrupt**: two threads `cursorSet` different
   keys 1000 times each on a persisting store; final `loadCursorMap` has
   both keys with their last values. (MVar serialization.)
8. **Model survives restart end-to-end** (the user's reported scenario):
   build a `ChannelDeps` with a persisting cursor store; `createConversationSession`
   for a Telegram conversation; `useCmd` to set `qwen3.8` on that session;
   simulate restart (drop the `ChannelDeps`, build a fresh one pointing at
   the same paths, re-load cursors); the next `cursorLookup` for the
   conversation returns the *same* sid; `loadSessionMeta` on that sid
   returns `smModel == "qwen3.8"`. (Integration guard against regressions
   of the original bug.)

Wiring:
- `seal-harness.cabal`: add `Seal.Channels.Cursor.Persist` to library
  `exposed-modules:`; add `Seal.Util.AtomicJson` to library
  `exposed-modules:`; add `Seal.Channels.CursorSpec` to test-suite
  `other-modules:`.
- `test/Main.hs`: import + run the new spec.
- `test/Seal/Channels/LoopSpec.hs`: update `newChannelDeps` call sites to
  pass `newCursorStore` (the non-persisting constructor).

## 8. File scope

| File | Change |
|---|---|
| `src/Seal/Util/AtomicJson.hs` (new) | shared `saveJsonAtomic` helper |
| `src/Seal/Channels/Cursor.hs` | add `csSave` field, persisting constructor, seed, save-after-mutate |
| `src/Seal/Channels/Cursor/Persist.hs` (new) | `saveCursorMap` / `loadCursorMap` |
| `src/Seal/Config/Paths.hs` | `cursorMapPath` |
| `src/Seal/Tabs/Persist.hs` | delegate `saveTabList` to `saveJsonAtomic` (DRY) |
| `src/Seal/Channels/Loop.hs` | `newChannelDeps` accepts `CursorStore` param |
| `src/Seal/Command/Serve.hs` | build persisting cursor store, load + seed at boot |
| `src/Seal/Channels/Telegram/Run.hs` | same boot block |
| `src/Seal/Channels/Signal/Run.hs` | same boot block |
| `test/Seal/Channels/CursorSpec.hs` (new) | round-trip, restart, stale, tamper, concurrency, end-to-end |
| `test/Seal/Channels/LoopSpec.hs` | pass `newCursorStore` at `newChannelDeps` sites |
| `test/Seal/Channels/Signal/RunSpec.hs` | same |
| `test/Seal/Channels/Telegram/RunSpec.hs` | same |
| `seal-harness.cabal` | new modules wired |
| `test/Main.hs` | new spec wired |

## 9. Rollback

- `cursors.json` is additive; its absence is handled (`loadCursorMap` →
  `Nothing`). Deleting the file rolls back to today's behavior (fresh empty
  cursor store on restart) with no other changes required.
- Reverting the code is safe: non-persisting `newCursorStore` is unchanged
  in behavior; the persisting constructor is the only new path.