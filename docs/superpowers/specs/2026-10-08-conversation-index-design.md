# Conversation Line Index Design

> **Status:** Draft (Revision 3 — incorporates Design Review Gate Round 3 feedback)
> **Date:** 2026-10-08
> **Goal:** Eliminate OOM crashes when reading multi-GB
> `conversation.jsonl` files by adding an append-only binary byte-offset
> index that enables random-access reads of individual conversation lines.

## Problem

`conversation.jsonl` grows unbounded — one raw `Message` per line,
appended on every turn. Sessions in production have reached:

| Session | conversation.jsonl | Lines |
|---|---|---|
| 20261006-004158-400 | 4.6 GB | 3,237,588 |
| 20261005-180629-530 | 3.0 GB | — |
| 20261002-200238-830 | 1.5 GB | — |

Every read path calls `readTranscriptEntries`
(`src/Seal/Gateway/Transcript.hs:131`), which reads the **entire file**
into memory via `readFileTextStrict`, decodes every line into Aeson
`Value`s, reconstructs, then slices. A 4.6 GB file becomes 10+ GB of
live heap (Text + Value trees), exceeding available RAM. The OS sends
SIGKILL (`Killed: 9`).

Three read paths trigger this:

1. **WS focus** (`replayEntriesSince` in `src/Seal/Gateway/Stream.hs:186`)
   — fires when the user clicks a tab in the frontend. This is the
   crash the user observed.
2. **WS request-entries** (`handleRequestEntries` in
   `src/Seal/Gateway/Stream.hs:260`) — paginated entry fetch.
3. **HTTP transcript** (`handleTranscript` in
   `src/Seal/Gateway/API.hs:1919`) — the REST seed / fallback.

Additionally, `broadcastNewEntries`
(`src/Seal/Core/TurnEngine.hs:806`) reads the full transcript after
every turn to find new entries — it already uses a positional cursor
to avoid re-broadcasting, but still reads the entire file to get there.

## Root Cause

The two-file format splits transcript data into:

- `conversation.jsonl` — one `Message` per line (the content; grows
  unbounded with conversation length and tool-result size).
- `entries.jsonl` — one `EntryRecord` per event (metadata-only: kind,
  timestamp, `convLen` pointer, envelope delta). Small even for long
  sessions (~1.3 MB for 1775 entries in the crashing session).

Reconstruction (`src/Seal/Transcript/Reconstruct.hs:63`) needs
`conv[start:end]` for each entry, where `start`/`end` come from
`erConvLen` values. The current implementation loads the **entire**
conversation into a `[Message]` list and uses `take`/`drop` to slice.
There is no way to seek to a specific line without reading everything
before it.

## Design: Append-Only Binary Index

### The index file: `conversation.idx`

A binary file of contiguous little-endian `Word64` values
(`Data.ByteString.Builder.word64LE`), storing the **byte offset of the
start of each line** in `conversation.jsonl`:

```
offset[0] = 0                    ← start of line 0
offset[1] = len(line 0) + 1      ← start of line 1 (+1 for the newline)
offset[2] = offset[1] + len(line 1) + 1
...
offset[N] = total file size      ← one past the last line (= file size)
```

N lines → N+1 offsets → `8 * (N+1)` bytes. For 3.2M lines: ~25.9 MB
(vs 4.6 GB conversation file — a 178× reduction).

### Why no rebuild is needed

The index is **built alongside `conversation.jsonl`** by the
single-writer daemon. Both files are append-only. The index is never
out of date because:

1. The first offset (`0`) is written when the index file is created
   (at the same time `conversation.jsonl` is created).
2. After each line is appended to `conversation.jsonl` and fsync'd,
   the new end-of-file position is appended to `conversation.idx`
   and fsync'd.
3. Both writes happen in the same daemon iteration, under the same
   single-writer guarantee.

If the process crashes between the conversation write and the index
write, the index is shorter than expected — but this is detectable
and recoverable (see [Crash Recovery](#crash-recovery)).

### Index entry semantics

After writing conversation line `i` (0-indexed), the daemon appends
`offset[i+1]` = the new end-of-file position of `conversation.jsonl`.

- Before any lines are written, the index contains just `[0]` (one
  `Word64` = the offset of the start of line 0).
- After line 0 is written (say it's 500 bytes + 1 newline = 501
  bytes), the index contains `[0, 501]`.
- After line 1 is written (say 300 bytes + 1 newline), the index
  contains `[0, 501, 802]`.

So the index always has `lineCount + 1` entries. To read line `i`,
seek to `offset[i]` and read `offset[i+1] - offset[i]` bytes.

### File permissions

The index file is created with `0o600` permissions (same as
`conversation.jsonl`), via `defaultFileFlags { creat = Just (0o600 :: FileMode) }`.
Every `openFd` call for `conversation.idx` (in `buildIndex`,
`ensureIndex`, `withIndexedTranscript` startup, and
`appendConversationMessage`) uses this mode. The index contains only
byte offsets (non-sensitive metadata), but inherits the conversation
file's protection as defense-in-depth.

### Index format validation

At read time, `ensureIndex` validates the index before use:

1. Index file size is a multiple of 8 (else: corrupt → `buildIndex`).
2. `offset[0] == 0` (else: corrupt → `buildIndex`).
3. Offsets are strictly monotonically increasing (else: corrupt → `buildIndex`).
4. `lastOffset <= fileSize` of `conversation.jsonl` (else: corrupt → `Left IndexCorrupt`, rebuild on next startup).

In `readConvLines`, after reading `offset[start]` and `offset[end]`,
validate `offset[start] <= offset[end] && offset[end] <= fileSize`
before seeking. If invalid, return `Left "index offset out of bounds"`
rather than reading garbage.

A bespoke error ADT drives the control flow in `ensureIndex`:

```haskell
data ConvIndexError
  = IndexMissing
  | IndexStale    -- ^ lastOffset < fileSize (crash recovery: scan tail)
  | IndexCorrupt  -- ^ failed validation (non-monotonic, wrong size, etc.)
```

### Random access read

```haskell
-- | Read lines [start, end) from conversation.jsonl using the index.
-- Returns the decoded Messages for those lines.
-- Returns Left on: missing files, corrupt index, out-of-bounds offsets.
readConvLines :: FilePath  -- ^ conversation.jsonl path
              -> FilePath  -- ^ conversation.idx path
              -> Int       -- ^ start line (inclusive)
              -> Int       -- ^ end line (exclusive)
              -> IO (Either Text [Message])

-- | Total number of conversation lines (index entry count - 1).
-- Returns 0 if the index file is missing or empty.
convLineCount :: FilePath -> IO Int

-- | Build conversation.idx from an existing conversation.jsonl.
-- One pass: scan the file, record byte offsets of each newline.
-- Truncates any existing index file before writing.
-- Uses temp-file + atomic rename: writes to conversation.idx.tmp,
-- fsyncs, renames to conversation.idx. Crash-safe.
buildIndex :: FilePath -> FilePath -> IO (Either Text ())

-- | Ensure the index exists and is up to date. Builds from scratch
-- if missing; recovers the tail if stale; returns Left IndexCorrupt
-- if structurally invalid (rebuild deferred to next startup — runtime
-- rebuild would invalidate the daemon's long-lived fd via atomic rename).
-- Idempotent and safe to call concurrently (MVar serializes all index writers).
ensureIndex :: FilePath -> FilePath -> IO (Either ConvIndexError ())
```

Implementation:
1. Read the two `Word64`s at index positions `start` and `end`:
   seek to `start * 8`, read 8 bytes → `offset[start]`;
   seek to `end * 8`, read 8 bytes → `offset[end]`.
   (For sequential reads of a range, read a contiguous slice of the
   index: `start * 8` to `(end + 1) * 8`.)
2. Validate: `offset[start] <= offset[end]` and
   `offset[end] <= conversationFileSize`. Return `Left` if invalid.
3. Seek to `offset[start]` in `conversation.jsonl`, read
   `offset[end] - offset[start]` bytes (via `System.Posix.IO.fdSeek` +
   `fdReadBuf`, or `System.IO.hSeek` + `hGetBuf` — see
   [Random-Read Primitive](#random-read-primitive) below).
4. Split on newlines, decode each line as a `Message`.

This reads only the bytes needed for the requested lines — a 50-line
slice of a 3.2M-line file reads ~50 lines of conversation + 408 bytes
of index, regardless of total file size.

### Random-Read Primitive

No `fdSeek`/`fdReadBuf`/`hSeek`/`hGetBuf` import exists in the
codebase today. The design uses `System.Posix.IO` `fdSeek` +
`fdReadBuf` to match the writer's existing POSIX style
(`System.Posix.IO` is already imported in `Seal.Handles.Transcript`).
The index fd is a `Fd` (matching `tfsConvFd` / `tfsEntriesFd`).

For `readConvLines` (which runs in the gateway read path, not the
writer), the function opens both files read-only, seeks, reads, and
closes — no long-lived fd. This is a per-call open/seek/read/close
pattern, acceptable for the read-side latency budget.

### Path layout

```
<sessionDir>/
  conversation.jsonl    ← existing
  conversation.idx      ← NEW (binary, Word64 array)
  entries.jsonl         ← existing
  session.json          ← existing
```

New helper in `Seal.Config.Paths`:
```haskell
sessionConversationIndexPath :: SealPaths -> SessionId -> FilePath
sessionConversationIndexPath paths sid =
  sessionDir paths sid </> "conversation.idx"
```

## Writer Changes

### `withIndexedTranscript` (`src/Seal/Handles/Transcript.hs`)

The `IndexedTranscriptState` gains two fields:

```haskell
data IndexedTranscriptState = IndexedTranscriptState
  { tfsConvFd :: Fd
  , tfsEntriesFd :: Fd
  , tfsConvIdxFd :: Fd          -- NEW: fd for conversation.idx
  , tfsWritten :: [Message]
  , tfsSecretOpsRef :: IORef (Set OpName)
  , tfsPriorEnv :: Maybe Envelope
  }
```

`tfsConvOffset` is **not** a persistent field in `IndexedTranscriptState`. It is
a local variable in `writeOne`, refreshed via `lseek(tfsConvFd, 0,
SEEK_END)` at the start of each `writeOne` call **after** acquiring
the session's in-process `MVar` lock. This prevents the stale-offset
bug: if `appendConversationMessage` wrote lines while the daemon was
idle between turns, the daemon's in-memory offset would be wrong. By
re-reading the EOF position via `lseek`, the daemon always starts from
the true end-of-file. The `MVar` ensures no other writer can append
between the `lseek` and the conversation writes.

The index fd is opened in `O_APPEND` mode with `0o600` permissions.

**In-process writer lock:** A global `IORef (Map FilePath (MVar ()))`
in `Seal.Handles.Transcript` provides per-session `MVar` locks. Both
`writeOne` and `appendConversationMessage` acquire the session's
`MVar` before writing to `conversation.jsonl` or `conversation.idx`.
The `MVar` outlives the `withIndexedTranscript` bracket (the registry
keeps it alive), so `appendConversationMessage` can still serialize
with the daemon if the bracket is active.

**On startup** (inside `withIndexedTranscript`, after reading
`existingConv`):

```haskell
convExists <- doesFileExist convPath
idxExists <- doesFileExist idxPath
if convExists && not idxExists
  then void (buildIndex convPath idxPath)       -- one-time migration
  else if not convExists && not idxExists
    then writeIdxEntry idxFd 0                    -- initial [0]
    else if not convExists && idxExists
      then removeFile idxPath                     -- stale orphan index
      else pure ()                                -- both exist; OK
```

This is a one-time migration for pre-existing sessions, not an ongoing
rebuild. Once the index exists, it is maintained by the writer and
never needs rebuilding.

**One-time migration for existing sessions:** If
`conversation.jsonl` exists but `conversation.idx` does not, scan the
conversation file once (buffered read, split on newlines, record byte
offsets) and write the index via temp-file + atomic rename. This is
O(N) but happens exactly once per session. For the 4.6 GB session
this takes ~9 seconds (buffered scan at ~500MB/s). During this time,
the read path blocks. This is acceptable: the alternative (reading
the full file into memory) crashes the process. A config-gated
fallback for small files (< 100MB) can use the old full-read path
while the index builds in the background (see
[Rollback Plan](#rollback-plan)).

**`buildIndex` atomicity:** `buildIndex` writes to
`conversation.idx.tmp`, fsyncs, then `renameFile` to `conversation.idx`.
This is crash-safe (a partial write to the temp file is discarded; no
existing index is harmed) and concurrent-safe (two simultaneous builds
produce the same file; atomic rename means readers see either the old
state or the new state, never a partial write).

### `writeOne` changes

After acquiring the session's `MVar` (in-process lock):

```haskell
-- Refresh the conversation EOF position (may have changed due to
-- appendConversationMessage writing between turns).
convOffset <- fromIntegral <$> fdSeek (tfsConvFd st) SeekFromEnd 0
              -- fdSeek SeekFromEnd 0 returns the current EOF position

-- Append new conversation lines + index entries
newOffset <- foldM (\off m -> do
    let bs = encodeConvLine (ConvLine m) <> "\n"
    writeFd (tfsConvFd st) bs
    let off' = off + fromIntegral (BS.length bs)
    writeIdxEntry (tfsConvIdxFd st) off'  -- append Word64 LE
    pure off'
  ) convOffset new
fileSynchronise (tfsConvFd st)
fileSynchronise (tfsConvIdxFd st)
```

The `MVar` is released after both fsyncs complete.

`writeIdxEntry` writes a `Word64` in little-endian via
`Data.ByteString.Builder`:

```haskell
writeIdxEntry :: Fd -> Word64 -> IO ()
writeIdxEntry fd w =
  writeFd fd (BL.toStrict (toLazyByteString (word64LE w)))
```

This function is exported from `Seal.Transcript.ConvIndex` so both the
writer daemon and `appendConversationMessage` share the same encoder.

### `appendConversationMessage` (direct-append path)

`src/Seal/Handles/Transcript.hs:551` — the async subagent completion
callback that appends directly via `O_APPEND` without going through the
daemon. This must also append to the index.

**Solution:** `appendConversationMessage` and the daemon's `writeOne`
are serialized via an **in-process `MVar ()`** keyed by the session
directory path. Since both writers run in the same Haskell process,
an `MVar` is sufficient — no OS-level file locking needed. The
`MVar` registry is a global `IORef (Map FilePath (MVar ()))` in
`Seal.Handles.Transcript`; the first writer for a given session
creates the `MVar`, subsequent writers reuse it. The `MVar` outlives
the `withIndexedTranscript` bracket because `appendConversationMessage`
may fire after the bracket closes — the registry keeps the `MVar` alive
as long as the process runs.

All conversation-file writes are centralized through this locked
protocol. A code comment at the `openFd` site documents this:
"WARNING: do not write to conversation.jsonl without holding the
session's MVar."

**Why not `flock`/`fcntl`:** `System.Posix.IO`'s `setLock`/
`setLockWait` use `fcntl` advisory locks, which are **per-process**
(not per-fd). Since both the daemon and `appendConversationMessage`
run in the same process, `fcntl` locks would not serialize them (the
kernel sees the same process already "holds" the lock). An in-process
`MVar` is the correct primitive for same-process serialization.

**`tfsWritten` consistency:** When `appendConversationMessage` fires
while the daemon's bracket is active (a subagent completes during a
parent turn), the daemon's `tfsWritten` list doesn't include the
directly-appended message. On the next `writeOne`, `diffMessages`
compares against `tfsWritten` — the directly-appended line is not in
`tfsWritten`, so `diffMessages` may re-append it. This is a
pre-existing issue (not introduced by the index). The
`appendConversationMessage` path is designed for subagent completions
that outlive the parent's bracket (daemon already closed), so the
race with an active daemon is rare. If it occurs, the
`readAndClearCompletions` sidecar mechanism (lines 574–625) is the
intended path for injecting subagent messages into the next turn —
not direct conversation appends. The direct append is a best-effort
fallback for when the sidecar isn't available.

**`appendConversationMessage` pseudocode:**

```haskell
appendConversationMessage paths sid msg = do
  mvar <- getSessionMVar paths sid  -- from the global IORef registry
  withMVar mvar $ \_ -> do
    let convPath = sessionConversationPath paths sid
        idxPath  = sessionConversationIndexPath paths sid
        flags = defaultFileFlags { append = True, creat = Just (0o600 :: FileMode) }
    convFd <- openFd convPath ReadWrite flags
    idxFd  <- openFd idxPath ReadWrite flags
    convOffset <- fromIntegral <$> fdSeek convFd SeekFromEnd 0
    let bs = encodeConvLine (ConvLine msg) <> "\n"
    writeFd convFd bs
    writeIdxEntry idxFd (convOffset + fromIntegral (BS.length bs))
    fileSynchronise convFd
    fileSynchronise idxFd
    closeFd convFd
    closeFd idxFd
```

If `conversation.idx` doesn't exist, `openFd` creates it (via `creat`),
and the first index entry is the offset after the appended line. The
missing initial `0` offset means `offset[0] != 0`, which structural
validation catches as `IndexCorrupt` — the index is rebuilt on the
next `withIndexedTranscript` startup. Alternatively,
`appendConversationMessage` can check for the index and call
`ensureIndex` first — but the best-effort nature of this function
favors simplicity.

### Crash Recovery

`ensureIndex` runs on the **read path** (gateway, concurrent with the
writer daemon). It must be safe to call while the daemon is active.
Two constraints:

1. **`ensureIndex` acquires the session's `MVar`** before any write to
   `conversation.idx` (tail-recovery or `buildIndex`). This prevents
   races with the daemon's `writeOne` (which also holds the `MVar`).
2. **`buildIndex` is restricted to startup** (before the daemon is
   forked in `withIndexedTranscript`). At runtime, `ensureIndex`
   returns `Left IndexCorrupt` for structurally invalid indices rather
   than rebuilding — the rebuild happens on the next startup. This
   prevents `buildIndex`'s atomic rename from invalidating the daemon's
   long-lived `tfsConvIdxFd` (the fd would point to the unlinked old
   inode).

`ensureIndex` detection and recovery:

1. Read the last `Word64` from the index → `lastOffset`.
2. `stat` `conversation.jsonl` → `fileSize`.
3. If `lastOffset < fileSize` (`IndexStale`): acquire `MVar`, scan from
   `lastOffset` to end-of-file, append missing offsets, fsync, release
   `MVar`. This scans only the unindexed tail, not the full file.
4. If `lastOffset > fileSize` or structural validation fails
   (`IndexCorrupt`): return `Left IndexCorrupt`. The caller surfaces
   an error (empty transcript). The index is rebuilt on the next
   `withIndexedTranscript` startup.
5. If index is missing (`IndexMissing`): `buildIndex` is safe (no
   daemon is running for this session, since the session hasn't been
   opened for a turn yet). Acquire `MVar`, `buildIndex`, release
   `MVar`.

`ensureIndex` is idempotent and safe to call concurrently (the `MVar`
serializes all index writers; `buildIndex` uses temp-file + atomic
rename).

## Read Path Changes

### New module: `Seal.Transcript.ConvIndex`

```haskell
module Seal.Transcript.ConvIndex
  ( readConvLines       -- random access read (IO (Either Text [Message]))
  , convLineCount       -- get the number of lines (index count - 1)
  , buildIndex          -- one-time migration / full rebuild
  , ensureIndex         -- build if missing, recover if stale, return Left IndexCorrupt if corrupt (rebuild on next startup)
  , writeIdxEntry       -- append a Word64 LE offset (used by the writer)
  , ConvIndexError(..)  -- error ADT for ensureIndex
  ) where
```

`readConvRange` is removed from the export list (it was a near-duplicate
of `readConvLines` with no distinct use case). `writeIdxEntry` is
exported so both the writer daemon and `appendConversationMessage` share
the same encoder. `buildIndex` is exported for a potential CLI migration
command; `ensureIndex` is the primary entry point for read paths.

Core operations (signatures match the detailed section above):

```haskell
-- | Read lines [start, end) from conversation.jsonl using the index.
-- Returns Left on: missing files, corrupt index, out-of-bounds offsets.
readConvLines :: FilePath -> FilePath -> Int -> Int -> IO (Either Text [Message])

-- | Total number of conversation lines (index entry count - 1).
-- Returns 0 if the index file is missing or empty.
convLineCount :: FilePath -> IO Int

-- | Build conversation.idx from an existing conversation.jsonl.
-- Truncates any existing index, uses temp-file + atomic rename.
buildIndex :: FilePath -> FilePath -> IO (Either Text ())

-- | Ensure the index exists and is up to date. Builds from scratch
-- if missing; recovers the tail if stale; returns Left IndexCorrupt
-- if structurally invalid (rebuild deferred to next startup).
ensureIndex :: FilePath -> FilePath -> IO (Either ConvIndexError ())
```

### Refactoring `reconstruct`

Split from a single-pass-over-full-conversation into an incremental
fold. The fold state is `(start, mEnv)` — identical to the current `go`
function, but conversation lines are read on demand:

```haskell
-- | Reconstruct transcript entries one at a time, reading conversation
-- lines on demand via the index. The fold state (start, mEnv) is
-- identical to the pure 'reconstruct', but conversation reads are
-- IO-batched per entry.
reconstructStreaming
  :: FilePath          -- ^ conversation.jsonl
  -> FilePath          -- ^ conversation.idx
  -> [EntryRecord]     -- ^ all entries (small file, read fully)
  -> IO [TranscriptEntry]
```

For each `EntryRecord`, the streaming reconstruction:
1. Computes `[start, end)` from `erConvLen` values (same as the pure
   version).
2. Calls `readConvLines` to fetch only those lines. On `Left` error,
   returns an empty list for that entry (matching the current
   skip-malformed-line behavior).
3. Builds the `TranscriptEntry` payload from those lines (same
   `requestPayload`/`responsePayload`/`harnessPayload` logic).

The pure `reconstruct` function is **kept** in
`Seal.Transcript.Reconstruct` for use in tests and properties.
`reconstructStreaming` lives in the same module (it's an IO wrapper
around the same fold logic). The module gains an `IO`-typed export but
remains primarily a pure module.

### `readTranscriptEntries` rewrite

The existing `readTranscriptEntries` signature is preserved. The
`readTranscriptEntriesTimed` variant is also preserved — it gains two
new timing phases for the `Server-Timing` header:

```haskell
data TranscriptTimings = TranscriptTimings
  { ...existing fields...
  , ttIndexEnsureMs :: Integer  -- NEW: time spent in ensureIndex
  , ttRandomReadMs  :: Integer  -- NEW: time spent in readConvLines calls
  }
```

`renderServerTiming` gains two new tokens: `ix` (index ensure) and
`rr` (random read). The frontend's `Server-Timing` parser already
handles arbitrary tokens, so no frontend change is needed.

The `readTranscriptEntries` rewrite reads `entries.jsonl` via the
existing inline pattern (`readFileTextStrict` + `mapMaybe A.decode`)
— no new `readEntriesFile` helper is introduced:

```haskell
readTranscriptEntries
  :: SealPaths -> Text -> String -> SessionId -> IO [Value]
readTranscriptEntries paths model fallbackTs sid = do
  let convPath    = sessionConversationPath paths sid
      entriesPath = sessionEntriesPath paths sid
      idxPath     = sessionConversationIndexPath paths sid
      legacyPath  = sessionTranscriptPath paths sid
  legacyExists <- doesFileExist legacyPath
  if legacyExists
    then readLegacyTranscript paths model fallbackTs sid  -- unchanged
    else do
      convExists <- doesFileExist convPath
      if not convExists
        then pure []
        else do
          eIdxResult <- ensureIndex convPath idxPath
          case eIdxResult of
            Left _ -> pure []  -- index build failed; return empty
            Right () -> do
              -- Read entries.jsonl fully (small: ~1.3MB for 1775 entries)
              entriesRaw <- readFileTextStrict entriesPath
              let evs = mapMaybe (A.decode . BL.fromStrict . TE.encodeUtf8)
                                 (filter (not . T.null) (T.lines entriesRaw))
                              :: [EntryRecord]
              reconstructed <- reconstructStreaming convPath idxPath evs
              -- Trailing conv entries: read lines [maxConvLen..totalLines)
              -- via readConvLines and map through convLineToFrontend
              ...
              pure (mapMaybe (reconEntryToFrontend ...) reconstructed <> trailing)
```

The conv-only path (TSConvOnly — `conversation.jsonl` exists,
`entries.jsonl` doesn't) uses `readConvLines` to read all lines in
batches, then maps through `convLineToFrontend`. This path is rare
(incomplete sessions) but handled.

### Pagination-native variants

For the WS and HTTP read paths that support pagination, add:

```haskell
-- | Read a page of frontend-shaped transcript entries.
-- Processes only the entries in the requested range.
-- Returns (entries, hasMore, totalCount).
readTranscriptPage
  :: SealPaths -> Text -> String -> SessionId
  -> Maybe Text    -- ^ mAfter: entry id to start after (for replayEntriesSince)
  -> Maybe Text    -- ^ mBefore: entry id to page before (for request-entries)
  -> Int           -- ^ limit
  -> IO ([Value], Bool, Int)  -- ^ (entries, hasMore, totalCount)
```

The `totalCount` is derived from the entries file length (or
`convLineCount`), preserving the `entries-chunk.totalCount` field the
frontend currently receives.

`mAfter` supports `replayEntriesSince`'s "all entries strictly after
this id" semantics. `mBefore` supports `handleRequestEntries`'s
"entries before this id" pagination, including the `__beginning__`
sentinel (kept as `Just "__beginning__"` for wire compatibility).

This replaces the current pattern of reading ALL entries then slicing
in `handleRequestEntries` and `handleTranscript`.

### Caller changes

| Caller | Current | After |
|---|---|---|
| `replayEntriesSince` (Stream.hs) | Read all, filter after id | `readTranscriptPage` with `mAfter=sinceId` |
| `handleRequestEntries` (Stream.hs) | Read all, slice to page | `readTranscriptPage` with `mBefore`/limit |
| `handleTranscript` (API.hs) | Read all, optionally limit | `readTranscriptPage` |
| `broadcastNewEntries` (TurnEngine.hs) | Read all, cursor finds new | Read full entries.jsonl (small), read only new entries' conv lines via index |
| `fanoutLastReply` (TurnEngine.hs:820) | Read full conv, extract last assistant msg | Read only last few lines via `readConvLines` to find last assistant message |
| `firstUserMessageSnippetFast` | Read full conv, take first | `readConvLines 0 10`, scan for first User message |
| `lastUserMessageAtFast` | Read entries.jsonl only | Unchanged (already small) |
| `fullTranscriptSnippet` (Search.hs) | Read full conv | Ripgrep is primary; in-memory fallback streams via `readConvLines` in batches |

## TDD Plan

### `Seal.Transcript.ConvIndex` (new module)

### Cycle 0: Cabal wiring

Before the first RED test, wire the new modules into the build:

- Add `Seal.Transcript.ConvIndex` to `exposed-modules:` in
  `seal-harness.cabal`.
- Add `Seal.Transcript.ConvIndexSpec` to `other-modules:` in the
  test-suite stanza.
- Wire into `test/Main.hs`.
- Keep edits minimal (the .cabal and `test/Main.hs` are merge
  hotspots); rebase before opening a PR.

**RED-GREEN-REFACTOR cycles:**

1. **buildIndex + readConvLines round-trip**
   - RED: Write a test that creates a `conversation.jsonl` with N
     lines, calls `buildIndex`, then `readConvLines path idxPath 2 5`
     and asserts the 3 messages at indices 2,3,4 are returned.
   - GREEN: Implement `buildIndex` (scan file, record offsets) and
     `readConvLines` (seek + read).
   - REFACTOR: Extract the offset-read helper.

2. **Empty conversation file**
   - RED: `conversation.jsonl` exists but is empty. `buildIndex`
     writes `[0]` (one Word64). `convLineCount` returns 0.
     `readConvLines 0 0` returns `Right []`.
   - GREEN: Handle empty file edge case.

3. **Single line**
   - RED: One line in conversation.jsonl. Index has `[0, len+1]`.
     `readConvLines 0 1` returns the one message.
   - GREEN: Already works from cycle 1; verify.

4. **Lines with embedded newlines in JSON strings**
   - RED: A message whose text contains `\n` (escaped in JSON as
     `\\n`, so no actual newline in the file). Verify the index
     counts actual newlines (line separators), not embedded ones.
   - GREEN: The scan splits on `0x0a` bytes only; JSON-escaped
     newlines are `\\n` (two bytes: `0x5c 0x6e`), not `0x0a`. Verify
     this is correct.

5. **readConvLines with start == end (empty range)**
   - RED: `readConvLines 3 3` returns `Right []`.
   - GREEN: Trivial.

6. **readConvLines with out-of-bounds range**
   - RED: `readConvLines 0 999999` on a 5-line file. Should return
     all 5 lines (clamp end to lineCount).
   - GREEN: Clamp end to `convLineCount`.

7. **ensureIndex: missing index**
   - RED: conversation.jsonl exists, no index. `ensureIndex` builds
     it. Subsequent `readConvLines` works.
   - GREEN: `ensureIndex` calls `buildIndex` when index is missing.

8. **ensureIndex: stale index (crash recovery)**
   - RED: conversation.jsonl has 10 lines, index has only 6 entries
     (simulating a crash after line 5). `ensureIndex` scans from
     `offset[5]` to EOF and appends missing offsets.
   - GREEN: Implement tail-recovery.

9. **ensureIndex: up-to-date index**
   - RED: Index is current. `ensureIndex` is a no-op (verify by
     checking modification time doesn't change).
   - GREEN: Early return when `lastOffset == fileSize`.

10. **ensureIndex: index-ahead-of-conversation (corrupt)**
    - RED: Index has more entries than conversation lines
      (`lastOffset > fileSize`). `ensureIndex` returns
      `Left IndexCorrupt` (no runtime rebuild — rebuild deferred to
      next `withIndexedTranscript` startup).
    - GREEN: Return `Left IndexCorrupt`; caller surfaces empty
      transcript. Add a separate startup test verifying
      `withIndexedTranscript` detects the corrupt index and calls
      `buildIndex`.

11. **ensureIndex: corrupt index (non-monotonic offsets)**
    - RED: Index has `offset[i] > offset[i+1]`. `ensureIndex` returns
      `Left IndexCorrupt` (no runtime rebuild).
    - GREEN: Implement structural validation; return
      `Left IndexCorrupt`. Rebuild deferred to startup.

12. **Concurrent builds are safe**
    - RED: Two threads call `ensureIndex` simultaneously. Only one
      builds; the other sees the result. Temp-file + atomic rename
      ensures no partial writes.
    - GREEN: `buildIndex` writes to `conversation.idx.tmp`, renames.

13. **File permissions on conversation.idx**
    - RED: After `buildIndex`, verify the file mode is `0o600`.
    - GREEN: Use `creat = Just (0o600 :: FileMode)` in `openFd`.

### QuickCheck properties

14. **buildIndex + readConvLines round-trip property**
    - RED: For any list of messages (bounded: ≤100 messages, bounded
      content blocks), `buildIndex` then `readConvLines 0 (length msgs)`
      returns exactly the original list.
    ```haskell
    prop_buildIndexReadRoundTrip :: [Message] -> Property
    prop_buildIndexReadRoundTrip msgs =
      not (null msgs) ==>
        ioProperty $ do
          -- write msgs to conversation.jsonl
          -- buildIndex
          -- readConvLines 0 (length msgs)
          -- assert result == Right msgs
    ```
    - GREEN: The property holds for all generated message lists.
    - Bound the generator to keep the suite sub-second.

### `reconstructStreaming`

15. **Streamed reconstruction matches pure reconstruction**
    - RED: Build a conversation.jsonl + entries.jsonl with 5 turns
      (request/response pairs). Run both `reconstruct` (pure, full
      read) and `reconstructStreaming` (index-based). Assert the
      outputs are equal.
    - GREEN: Implement `reconstructStreaming` by adapting the `go`
      fold to read conv lines per entry.

16. **Harness entry with convLen = 0**
    - RED: An `EKHarness` entry with `erConvLen = 0`. Verify the
      streaming version preserves the conversation cursor (same as
      the pure version's `go start mEnv es` branch).
    - GREEN: Already handled by the fold state; verify.

17. **Compaction entry**
    - RED: An `EKCompaction` entry. Verify the streaming version
      advances the cursor to `erConvLen`.
    - GREEN: Already handled; verify.

18. **Trailing conv entries (entries.jsonl doesn't cover all conv lines)**
    - RED: conversation.jsonl has 10 lines, entries.jsonl covers
      only 8. The trailing 2 lines should be synthesized as
      frontend entries (same as the current `trailingConvEntries`).
    - GREEN: Implement trailing synthesis in the streaming path.

### Integration tests

19. **Streaming path handles large conversation without OOM**
    - RED: Create a conversation.jsonl with 5K lines (each ~1KB =
      ~5MB). Call `readTranscriptEntries`. The process should not
      crash and should return all entries within a reasonable time.
      (5K lines is enough to prove the streaming path works without
      full-file read; the OOM-prevention is architectural — reads
      only needed bytes — not something a unit test can prove by
      scale alone. Keeping the file small respects the sub-second
      suite constraint.)
    - GREEN: The streaming path handles this naturally.

20. **WS focus on large session**
    - RED: Integration test: create a session with a large
      conversation, connect a WS client, send a focus op. Verify
      entries are received without the server crashing.
    - GREEN: `replayEntriesSince` uses the streaming path.

## Edge Cases

- **Legacy `transcript.jsonl`**: No index. Keep the existing full-read
  path for legacy files. These are from before the two-file format and
  tend to be smaller (the O(N²) format was replaced precisely because
  it was wasteful, so legacy files are rarely multi-GB). The
  `readTranscriptEntries` function checks for legacy first, as it does
  today.

- **Sub-agent conversations**: Sub-agent sessions under
  `<sessionDir>/agents/<subagentId>/` have their own
  `conversation.jsonl`. Each gets its own `conversation.idx`. The
  writer for sub-agent transcripts is a separate `withIndexedTranscript`
  bracket, so the same index-maintenance logic applies.

- **File rotation / compaction**: If a session is compacted (the
  `EKCompaction` entry type), the conversation file is not
  rewritten — compaction is recorded as an entry, and the conversation
  file continues to grow. The index continues to grow alongside it. No
  special handling needed.

- **Read-only sessions (archived)**: Archived sessions still have
  `conversation.jsonl`. The index is built on first read access if
  missing (one-time cost), then cached on disk for subsequent reads.

- **Test fixtures (`fakeIndexedTranscript`)**: The test fake
  `fakeIndexedTranscript` does not construct a `IndexedTranscriptState` — it
  builds a `IndexedTranscriptHandle` directly with MVars, so it is unaffected by
  the new `tfsConvIdxFd` field. Tests that verify index maintenance use
  the real `withIndexedTranscript` with temp files (see
  `Seal.Handles.TranscriptSpec` for the pattern). No existing test
  pattern-matches on `IndexedTranscriptState` constructors.

- **Security**: `conversation.idx` is only touched by
  `Seal.Handles.Transcript` (writer) and `Seal.Gateway.Transcript` /
  `Seal.Transcript.ConvIndex` (reader). Untrusted opcodes go through
  `UntrustedIO` capability methods, which do not expose arbitrary
  session-directory file paths. The index path is derived from
  `SealPaths` (a trusted config), not from agent/LLM input. No opcode
  module imports `Seal.Transcript.ConvIndex`.

## Rollback Plan

If the index approach has unforeseen correctness issues in production:

1. **Config flag**: Gate the streaming read path behind a config flag
   (`use_conv_index :: Bool`, default `True`). When `False`, the
   reader uses the old full-read path.
2. **File-size guard**: In the old full-read path, add a file-size
   check: if `conversation.jsonl` exceeds N MB (configurable, default
   500MB), return an error (`"transcript too large for in-memory read;
   enable conv_index"`) instead of crashing. This prevents OOM while
   the index is disabled.
3. **Index file is safe to delete**: `conversation.idx` is purely a
   cache — deleting it falls back to `ensureIndex` rebuilding on next
   access. No data loss.
4. **No wire-protocol change**: The frontend-facing API
   (`entries-chunk`, `entry` events) is unchanged. The `Server-Timing`
   header gains new tokens but the frontend parser already handles
   arbitrary tokens.

## Architecture Alignment

- **Handle pattern**: The index fd is managed inside the
  `withIndexedTranscript` bracket, opened and closed alongside the
  conversation and entries fds.
- **Single-writer guarantee**: The index is written by the same daemon
  that writes `conversation.jsonl`, preserving the single-writer
  invariant.
- **Append-only + fsync**: The index is append-only and fsync'd
  alongside the conversation file, so the ACK-before-execute
  durability guarantee extends to the index.
- **No new dependencies**: Uses `System.Posix.IO` (already imported)
  and `Data.ByteString.Builder` (in the dependency tree via aeson).
  Writer serialization uses in-process `MVar` (no OS-level locking
  dependency).
- **`Seal.*` namespace**: New module is `Seal.Transcript.ConvIndex`,
  following the existing `Seal.Transcript.Conv` / `Seal.Transcript.Entries`
  / `Seal.Transcript.Reconstruct` structure.

## Files

**New:**
- `src/Seal/Transcript/ConvIndex.hs` — index build, read, ensure, crash recovery
- `test/Seal/Transcript/ConvIndexSpec.hs` — tests

**Modified:**
- `src/Seal/Config/Paths.hs` — `sessionConversationIndexPath`
- `src/Seal/Handles/Transcript.hs` — writer maintains index; `appendConversationMessage` uses in-process MVar
- `src/Seal/Transcript/Reconstruct.hs` — `reconstructStreaming` (IO-based variant)
- `src/Seal/Gateway/Transcript.hs` — `readTranscriptEntries` uses streaming; new `readTranscriptPage`
- `src/Seal/Gateway/Stream.hs` — `replayEntriesSince` / `handleRequestEntries` use streaming
- `src/Seal/Gateway/API.hs` — `handleTranscript` uses streaming
- `src/Seal/Core/TurnEngine.hs` — `broadcastNewEntries` reads only new entries
- `src/Seal/Session/Search.hs` — `fullTranscriptSnippet` streams or delegates to ripgrep
- `seal-harness.cabal` — add new modules to `exposed-modules` and `other-modules`
- `test/Main.hs` — wire new test module

## Risk Assessment

| Risk | Likelihood | Mitigation |
|---|---|---|
| Index corruption on crash | Low | `ensureIndex` tail-recovery + structural validation at read time |
| `appendConversationMessage` race | Medium | In-process `MVar` per session serializes all writers; `lseek(SEEK_END)` refreshes offset |
| Performance regression on small files | Low | Index read is 2 seeks + small read; negligible overhead |
| Legacy sessions without index | Medium | One-time `buildIndex` migration on first access |
| Endianness across architectures | Low | Explicit `word64LE` (portable little-endian) |
| Corrupt index → silently wrong output | Medium | `ensureIndex` validates monotonicity, bounds, `offset[0]==0`; `readConvLines` validates per-read |
| `ensureIndex` race with daemon | Medium | `ensureIndex` acquires `MVar`; `buildIndex` restricted to startup; runtime corrupt → `Left IndexCorrupt` |
| Unforeseen correctness issues | Low | Config flag `use_conv_index` falls back to old path + file-size guard |

## Out of Scope (Follow-ups)

- **Conversation size capping**: The 4.6 GB file likely has unbounded
  `tool_result` blocks (web_fetch HTML, shell output). A writer-side
  cap on individual content block size would prevent future bloat.
  Tracked separately.
- **Index file compaction**: If conversation.jsonl is ever compacted
  (rewritten smaller), the index must be rebuilt. Not needed today
  since the file is append-only.
- **Memory-mapped index**: For very large indices (25MB for 3.2M
  lines), `mmap` would avoid reading the whole index into memory.
  Current approach reads only the needed 8-byte slices, so this is
  not urgent.