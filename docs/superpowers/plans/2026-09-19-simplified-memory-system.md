# Simplified Memory System — TDD Implementation Plan

> **Status:** draft — awaiting human review
> **Design source:** `docs/2026-09-19-memory-system-vision.md`
> **Branch:** `simplified-memory-system`

**Goal:** Replace the existing id-based upsert/delete memory system with a
path-based, append-only, archive-instead-of-delete memory system with
semantic search. The new system lives under `~/.seal/memory/` with
`active/` and `archived/` directory hierarchies, plain-text files (no
frontmatter), and a pluggable embedding backend (null + engram).

This is a **breaking redesign** — the old `MemoryId`, `MemoryEntry`,
`MemoryBackend`, and three opcodes (`MEMORY_WRITE`, `MEMORY_RECALL`,
`MEMORY_DELETE`) are replaced entirely. All consumers (TurnEngine wiring,
Backends, tests, Arbitrary instances) are updated.

## What Changes

| Aspect | Old | New |
|--------|-----|-----|
| Key type | `MemoryId` (flat `[A-Za-z0-9_-]+`) | `MemoryPath` (directory hierarchy, `/`-separated) |
| Storage location | `config/memory/<id>.md` | `~/.seal/memory/active/<path>.md` + `archived/` |
| File format | Frontmatter + body | Plain text (body only) |
| Mutation | Upsert (create or update) | Write-once (fails if exists) |
| Removal | Hard delete | Archive (move to `archived/` with timestamp prefix) |
| Opcodes | 3: WRITE, RECALL, DELETE | 5: WRITE, READ, LIST, SEARCH, ARCHIVE |
| Search | Substring + paging | Semantic via EmbeddingBackend (null + engram) |

## Design Decisions (from the vision doc)

1. **Plain text, no frontmatter.** Memory content is just the file body.
   Metadata (created date, tags, provenance) can be added later via
   frontmatter without breaking plain-text reads. Start simple.
2. **Write-once.** `MEMORY_WRITE` fails if the file already exists in
   `active/`. The agent must archive first, then write the new version.
3. **Archive, never delete.** `MEMORY_ARCHIVE` moves `active/<path>` to
   `archived/<path>/<timestamp>-<filename>`. The directory hierarchy is
   preserved. A timestamp prefix prevents collisions.
4. **MEMORY_READ falls back to archived/.** If the file isn't in `active/`,
   check `archived/` and return it with an `archived: true` flag.
5. **EmbeddingBackend typeclass.** Ships with `nullBackend` (no search,
   returns empty) and `engramBackend` (subprocess to engram CLI). The
   typeclass is a top-level concern, not memory-specific.
6. **No git auto-commit.** The new memory system lives under
   `~/.seal/memory/`, not under `config/`. It is NOT part of the config
   git repo. Memory is its own store with its own immutability guarantees
   enforced by the harness, not by git.
7. **`include_archived` flag.** `MEMORY_LIST` and `MEMORY_SEARCH` default
   to active-only; `MEMORY_READ` always falls back to archived.

## Scope — What's In

- `Seal.Memory.Path` — new `MemoryPath` smart-constructed newtype
- `Seal.Memory.Store` — new file-based store (active/archived, write-once, archive)
- `Seal.Memory.Embedding` — `EmbeddingBackend` typeclass + null + engram backends
- `Seal.ISA.Ops.Memory` — rewritten with 5 opcodes
- `Seal.Core.Backends` — updated to construct the new memory store
- `Seal.Core.TurnEngine` — updated wiring (2 sites: session + child)
- All tests updated

## Scope — What's Out (Deferred)

- engram subprocess integration (the typeclass + null backend ship; engram
  backend is a stub that returns empty results — real engram wiring is a
  follow-up once engram's incremental add/remove API is verified)
- Reconciliation cron job
- Read-only mount in untrusted environment
- Configuration (`embedding:` section in config.toml)
- Cross-session queries, session search integration

---

## Milestone Map

| M | Title | Gate |
|---|------|------|
| **M1** | MemoryPath type | `cabal test` green; `mkMemoryPath` validates paths; QuickCheck properties pass |
| **M2** | File-based store | `cabal test` green; write-once, read, list, archive all work against temp dirs |
| **M3** | EmbeddingBackend typeclass | `cabal test` green; null backend returns empty; typeclass interface verified |
| **M4** | Five memory opcodes | `cabal test` green; all 5 opcodes dispatch through `Seal.ISA.Dispatch` |
| **M5** | Wiring + integration | `cabal test` green; `make check` green; TurnEngine wires new opcodes; Phase5 + Integration specs updated |

---

## M1 — MemoryPath Type

**Goal:** Replace `MemoryId` with `MemoryPath` — a smart-constructed
newtype that validates directory-hierarchy paths for memory files.

**Validation rules:**
- Non-empty
- No leading dot on any segment (`.hidden` rejected)
- No `..` or `.` segments
- Segments use `[A-Za-z0-9_-]+` (same charset as `MemoryId`, plus `/` separator)
- Must end with `.md` (or we append it — decision: the agent provides the
  path without extension; the store appends `.md`)
- No leading/trailing `/`

**Files:**

- Create: `src/Seal/Memory/Path.hs` — `MemoryPath` newtype, `mkMemoryPath`,
  `memoryPathText`, `memoryPathSegments`, QuickCheck-friendly.
- Delete: `src/Seal/Memory/Types.hs` — replaced by `Path.hs`
- Create: `test/Seal/Memory/PathSpec.hs` — unit tests + QuickCheck
- Delete: `test/Seal/Memory/TypesSpec.hs` — replaced by `PathSpec.hs`

**Tasks:**

- [ ] 1.1 Write failing test: `mkMemoryPath "projects/pureclaw/architecture"`
      succeeds; `memoryPathText` round-trips.
- [ ] 1.2 Write failing test: `mkMemoryPath ""` fails; `mkMemoryPath "../etc"`
      fails; `mkMemoryPath ".hidden"` fails; `mkMemoryPath "/abs"` fails.
- [ ] 1.3 Write failing QuickCheck: valid paths round-trip through
      `mkMemoryPath`; invalid paths are rejected.
- [ ] 1.4 Implement `MemoryPath` in `src/Seal/Memory/Path.hs`.
- [ ] 1.5 Update cabal: replace `Seal.Memory.Types` with `Seal.Memory.Path`
      in `exposed-modules` and `other-modules`.
- [ ] 1.6 Update `test/Main.hs`: replace `Seal.Memory.TypesSpec` with
      `Seal.Memory.PathSpec`.
- [ ] 1.7 `make check` green (expect failures in M2+ modules that still
      reference `MemoryId` — those are fixed in M2).

**Commit:** `feat: MemoryPath smart-constructed newtype for path-based memory`

---

## M2 — File-Based Store

**Goal:** Replace `MemoryBackend` with a new `MemoryStore` that implements
the append-only / archive model against `~/.seal/memory/active/` and
`~/.seal/memory/archived/`.

**Store interface:**

```haskell
data MemoryStore = MemoryStore
  { msWrite    :: MemoryPath -> Text -> IO (Either Text ())
    -- ^ Write a new memory file. Fails if the path already exists in active/.
  , msRead     :: MemoryPath -> IO (Either Text (Text, Bool))
    -- ^ Read a memory by path. Returns (content, isArchived).
    --   Falls back to archived/ if not in active/.
  , msList     :: Text -> Bool -> IO [MemoryPath]
    -- ^ List memory paths matching a prefix. includeArchived flag.
  , msArchive  :: MemoryPath -> IO (Either Text MemoryPath)
    -- ^ Move active/<path> to archived/<path>/<timestamp>-<filename>.
    --   Returns the archived path.
  }
```

**Implementation details:**

- `msWrite`: atomic write (temp + rename). Creates parent directories as
  needed. Fails if the target file already exists (write-once).
- `msRead`: check `active/` first; if not found, search `archived/` (walk
  the archived directory tree for a file matching the path — the timestamp
  prefix means we match by suffix). Returns `(content, True)` if archived.
- `msList`: walk the directory tree under `active/` (and `archived/` if
  `includeArchived`), filter by prefix, return sorted paths.
- `msArchive`: move `active/<path>` to
  `archived/<dir>/<timestamp>-<filename>`. The timestamp is
  `YYYYMMDDThhmmssZ` (UTC). Creates `archived/<dir>/` if needed.
- No git auto-commit. The store manages its own immutability.
- No frontmatter. Files are plain text.

**Files:**

- Create: `src/Seal/Memory/Store.hs` — `MemoryStore` + `fileMemoryStore`
  (disk-backed) + `noneMemoryStore` (in-memory for tests).
- Delete: `src/Seal/Memory/Backend.hs` — replaced by `Store.hs`
- Create: `test/Seal/Memory/StoreSpec.hs` — unit tests for all 4 operations.
- Delete: `test/Seal/Memory/BackendSpec.hs` — replaced by `StoreSpec.hs`

**Tasks:**

- [ ] 2.1 Write failing test: `msWrite` creates a file under `active/`;
      content round-trips through `msRead`.
- [ ] 2.2 Write failing test: `msWrite` fails when the path already exists
      (write-once / immutability).
- [ ] 2.3 Write failing test: `msWrite` creates parent directories for
      nested paths (e.g. `projects/pureclaw/architecture`).
- [ ] 2.4 Write failing test: `msRead` falls back to `archived/` and
      returns `(content, True)`.
- [ ] 2.5 Write failing test: `msRead` on a non-existent path returns
      `Left "not found"`.
- [ ] 2.6 Write failing test: `msList` with prefix `projects/` returns
      only paths under that directory.
- [ ] 2.7 Write failing test: `msList` with `includeArchived=True` includes
      archived paths.
- [ ] 2.8 Write failing test: `msArchive` moves the file from `active/` to
      `archived/` with a timestamp prefix; the file is no longer in
      `active/`.
- [ ] 2.9 Write failing test: `msArchive` on a non-existent path returns
      `Left "not found"`.
- [ ] 2.10 Write failing test: `msArchive` then `msWrite` the same path
       succeeds (archive-then-write-new is the update pattern).
- [ ] 2.11 Implement `MemoryStore` + `fileMemoryStore` + `noneMemoryStore`.
- [ ] 2.12 Update cabal: replace `Seal.Memory.Backend` with
       `Seal.Memory.Store` in `exposed-modules` and `other-modules`.
- [ ] 2.13 Update `test/Main.hs`: replace `Seal.Memory.BackendSpec` with
       `Seal.Memory.StoreSpec`.
- [ ] 2.14 `make check` (expect opcode/wiring failures — fixed in M4/M5).

**Commit:** `feat: file-based memory store with active/archived directories`

---

## M3 — EmbeddingBackend Typeclass

**Goal:** Define the `EmbeddingBackend` typeclass and ship the null
backend. The engram backend is a stub for now (returns empty results) —
real engram integration is a follow-up.

**Interface (from the vision doc):**

```haskell
class EmbeddingBackend m where
  index        :: FilePath -> Text -> m ()
  unindex      :: FilePath -> m ()
  search       :: Text -> Int -> m [SearchResult]
  backendName  :: m Text

data SearchResult = SearchResult
  { srPath    :: Text
  , srContent :: Text
  , srScore   :: Double
  }
```

**Decision:** Use a record-of-functions approach (consistent with the
project's `MemoryBackend` / `SkillBackend` pattern) rather than a
typeclass, to stay consistent with the codebase convention "capability-handle
records of `IO` functions over type classes" (CONTRIBUTING.md). The vision
doc sketches a typeclass, but the codebase pattern is records.

```haskell
data EmbeddingBackend = EmbeddingBackend
  { ebIndex       :: FilePath -> Text -> IO ()
  , ebUnindex     :: FilePath -> IO ()
  , ebSearch      :: Text -> Int -> IO [SearchResult]
  , ebBackendName :: Text
  }

nullEmbeddingBackend :: EmbeddingBackend
```

**Files:**

- Create: `src/Seal/Memory/Embedding.hs` — `EmbeddingBackend` record,
  `SearchResult` type, `nullEmbeddingBackend`.
- Create: `test/Seal/Memory/EmbeddingSpec.hs` — tests for null backend.

**Tasks:**

- [ ] 3.1 Write failing test: `nullEmbeddingBackend` search returns `[]`.
- [ ] 3.2 Write failing test: `nullEmbeddingBackend` index/unindex are
      no-ops (don't throw).
- [ ] 3.3 Implement `EmbeddingBackend` record + `nullEmbeddingBackend`.
- [ ] 3.4 Update cabal: add `Seal.Memory.Embedding` to `exposed-modules`
       and `Seal.Memory.EmbeddingSpec` to `other-modules`.
- [ ] 3.5 Update `test/Main.hs`: add `Seal.Memory.EmbeddingSpec`.
- [ ] 3.6 `make check`.

**Commit:** `feat: EmbeddingBackend record + null backend for semantic search`

---

## M4 — Five Memory Opcodes

**Goal:** Rewrite `Seal.ISA.Ops.Memory` with five opcodes, backed by the
new `MemoryStore` + `EmbeddingBackend`.

**Opcodes:**

1. `MEMORY_WRITE` — `{ path, content }` → `{ path, indexed }`. Write-once.
   Fails if file exists. Indexes after write.
2. `MEMORY_READ` — `{ path }` → `{ path, content, exists, archived }`.
   Falls back to archived/.
3. `MEMORY_LIST` — `{ prefix, include_archived? }` → `{ entries, count }`.
   Lists paths matching prefix.
4. `MEMORY_SEARCH` — `{ query, limit?, include_archived? }` →
   `{ results, total_matches }`. Semantic search via EmbeddingBackend.
5. `MEMORY_ARCHIVE` — `{ path }` → `{ path, archived_path }`. Moves to
   archived/ with timestamp.

All five are `Trusted` (not `Audited` — the new memory system is not part
of the config git repo, and the transcript records the invocation). The
old `MEMORY_DELETE` is removed entirely.

**Files:**

- Modify: `src/Seal/ISA/Ops/Memory.hs` — complete rewrite.
- Modify: `test/Seal/ISA/Ops/MemorySpec.hs` — complete rewrite.

**Tasks:**

- [ ] 4.1 Write failing test: `MEMORY_WRITE` creates a memory; `MEMORY_READ`
      returns its content.
- [ ] 4.2 Write failing test: `MEMORY_WRITE` fails on an existing path
      (write-once).
- [ ] 4.3 Write failing test: `MEMORY_WRITE` rejects an invalid path.
- [ ] 4.4 Write failing test: `MEMORY_READ` on a non-existent path returns
      `exists: false`.
- [ ] 4.5 Write failing test: `MEMORY_READ` falls back to archived and
      returns `archived: true`.
- [ ] 4.6 Write failing test: `MEMORY_LIST` with prefix returns matching
      paths.
- [ ] 4.7 Write failing test: `MEMORY_LIST` with `include_archived` includes
      archived paths.
- [ ] 4.8 Write failing test: `MEMORY_SEARCH` with null backend returns
      empty results (not an error).
- [ ] 4.9 Write failing test: `MEMORY_ARCHIVE` moves the file; subsequent
      `MEMORY_READ` returns `archived: true`.
- [ ] 4.10 Write failing test: `MEMORY_ARCHIVE` on non-existent path returns
       an error.
- [ ] 4.11 Write failing test: secret discipline — `orRecorded` never
       carries a vault secret (memory content is agent-visible, recorded
       in full).
- [ ] 4.12 Implement all 5 opcodes in `src/Seal/ISA/Ops/Memory.hs`.
- [ ] 4.13 Rewrite `test/Seal/ISA/Ops/MemorySpec.hs` with all tests above.
- [ ] 4.14 `make check` (expect wiring failures — fixed in M5).

**Commit:** `feat: five memory opcodes (WRITE, READ, LIST, SEARCH, ARCHIVE)`

---

## M5 — Wiring + Integration

**Goal:** Wire the new memory system into `Backends`, `TurnEngine`, and
update all integration tests.

**Files:**

- Modify: `src/Seal/Core/Backends.hs` — replace `bMemory :: Mem.MemoryBackend`
  with `bMemory :: Mem.MemoryStore`, construct from `~/.seal/memory/` path.
  Add `bEmbedding :: Mem.EmbeddingBackend`.
- Modify: `src/Seal/Core/TurnEngine.hs` — update both `baseOps` sites
  (session + child) to wire the 5 new opcodes instead of the 3 old ones.
- Modify: `test/Seal/ISA/IntegrationSpec.hs` — update memory integration
  tests for the new opcodes.
- Modify: `test/Seal/Phase5Spec.hs` — update the capstone scenario to use
  the new opcodes.
- Modify: `test/Seal/TestHelpers/Arbitrary.hs` — replace `MemoryId` /
  `MemoryEntry` instances with `MemoryPath` instances.
- Modify: `seal-harness.cabal` — update module registrations.
- Modify: `test/Main.hs` — update spec registrations.

**Tasks:**

- [ ] 5.1 Update `Backends`: replace `MemoryBackend` with `MemoryStore` +
      `EmbeddingBackend`. Construct `fileMemoryStore` from
      `<sealHome>/memory/` (NOT `<configRoot>/memory/`). Construct
      `nullEmbeddingBackend` (engram wiring is deferred).
- [ ] 5.2 Update `TurnEngine` session `baseOps`: replace 3 old opcodes with
      5 new ones.
- [ ] 5.3 Update `TurnEngine` child `baseOps`: same replacement.
- [ ] 5.4 Update `IntegrationSpec` memory tests: rewrite for new opcodes.
- [ ] 5.5 Update `Phase5Spec` capstone: update the `MEMORY_WRITE` +
      `MEMORY_RECALL` tool calls to `MEMORY_WRITE` + `MEMORY_READ`.
- [ ] 5.6 Update `Arbitrary`: remove `MemoryId` / `MemoryEntry` instances;
      add `MemoryPath` instance.
- [ ] 5.7 Remove old `Seal.Memory.Types` / `Seal.Memory.Backend` modules
      and their test specs from cabal + `test/Main.hs`.
- [ ] 5.8 `make check` — full gate green: build (-Werror), test, hlint.

**Commit:** `feat: wire new memory system into Backends + TurnEngine`

---

## Post-Implementation Notes

### Migration

There is no automatic migration from the old `config/memory/*.md` files to
the new `~/.seal/memory/active/` layout. Old memories remain in the config
directory as git-tracked Markdown; the agent can manually re-write them
using the new `MEMORY_WRITE` opcode. This is acceptable for a
pre-production system.

### Follow-Up Work (Out of Scope)

1. **engram subprocess integration** — wire `engramBackend` to call the
   engram CLI. Blocked on verifying engram's incremental add/remove API.
2. **Reconciliation cron** — daily scan of `active/` + `archived/` to
   reconcile the engram index.
3. **Configuration** — `embedding:` section in `config.toml`.
4. **Read-only mount** — mount `active/` read-only in the untrusted
   execution environment.
5. **MEMORY_SEARCH with engram** — once engram is wired, test semantic
   search end-to-end.