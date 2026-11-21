# Chunked Resumable Download — Implementation Plan (Rev 2)

> **Design**: `docs/superpowers/specs/2026-11-13-chunked-resumable-download-design.md` (Rev 1.1, post-gate)
> **Branch**: `files/chunked-download` (off `main`, which now contains PR #318)
> **Operator decisions**: full downloader, both local+remote arms, no cross-reload resume (in-memory only)

## 0. What the gate changed (read before building)

The 5-agent design review gate deleted the manifest hash list (§12). This
removed: the O(size) hashing pass, manifest paging/413, NDJSON streaming, the
LRU cache, and the semaphore/token bucket. The manifest is now **O(1)
metadata**:

```json
{ "path": "...", "size": 123456789, "mtimeEpoch": 1763035200,
  "chunkSize": 4194304, "chunkCount": 30 }
```

Per-chunk integrity comes from `X-Chunk-SHA256` on each chunk response.

### 0a. Correction to §12: `runRemoteStream` is still needed

The design's §12 deleted `runRemoteStream` (§5.4a) claiming it existed "only
to escape the 50,000-byte cap on the hash list." This is **incorrect**: §5.4a
explicitly states it is "Used by chunk serving (§5.4) and the manifest
(§5.3a)." The manifest no longer needs it (it's O(1) now), but **chunk
serving still does** — `runRemoteBytes` has a hardcoded 50,000-byte output
cap (`Remote.hs:309`), and the default chunk size is 4 MiB. Without an
uncapped transport, every remote chunk would be silently truncated to ~48.8
KiB — recreating defect §1.1.3.

**Resolution**: `runRemoteStream` is reinstated in WU-1, scoped to chunk
serving only (not the manifest). It provides a `Handle -> IO r` callback
pattern with no byte cap, sharing the existing `withManagedProcess` cleanup.

Cross-reload resume (IndexedDB) is **dropped** per operator decision. Chunks
are held in a JavaScript `Map<number, ArrayBuffer>` in memory.

## 1. Work units

### WU-1: Backend — ceiling split + readBoundedFile fix + FileStat + feReadRange + runRemoteStream

**Files**:
- `src/Seal/Tools/Exec/FileExplorer.hs`
- `src/Seal/Tools/Exec/Remote.hs` (new `runRemoteStream` method)
- `test/Seal/Tools/Exec/FileExplorerSpec.hs`
- `test/Seal/Tools/Exec/RemoteSpec.hs` (if exists; otherwise in FileExplorerSpec)
- `src/Seal/Command/Serve.hs` (call site update)
- All test files with `RemoteRunner` fakes (add `runRemoteStream` stub for
  totality under `-Werror`, verified by `grep -rn "RemoteRunner {" test/`):
  `ApiTestHarness.hs`, `FileExplorerSpec.hs` (2 fakes), `RepoDiscoverySpec.hs`,
  `AgentMetaCacheSpec.hs` (2 fakes), `ExecCacheSpec.hs`, `WorkdirFsSpec.hs`.
  (Note: `FakeCaps.hs` does NOT contain a `RemoteRunner` literal.)

**Changes**:

1. **Split ceilings.** `mkLocalFileExplorer` and `mkRemoteFileExplorer` take
   two `Int`s: `readCeiling` (unchanged, still `maxScanBytes`) and
   `downloadChunkBytes` (new, default 4 MiB). `feReadFile` (viewer) uses
   `readCeiling`; the download path uses `downloadChunkBytes` for chunk
   sizing.

2. **Fix `readBoundedFile`.** Replace `BS.readFile path` + `BS.take` with
   `hFileSize` + `hSeek` + bounded `BS.hGetSome`. This fixes defect §1.1.2
   (2 GB allocation to return 128 KB) and also protects the viewer path.

3. **Add `FileStat` type:**
   ```haskell
   data FileStat = FileStat
     { fsPath       :: !Text
     , fsSize       :: !Integer
     , fsMtimeEpoch :: !(Maybe Integer)  -- Nothing when mtime unavailable
     } deriving stock (Eq, Show)
   ```

4. **Add `feStatFile` method** to `FileExplorerHandle`:
   - Local: `getFileSize` + `getModificationTime` → truncate to epoch seconds
   - Remote: `stat -c '%s %Y' -- "$p"` via one SSH call (through
     `runRemoteShell`; output is small, well under 50K cap)
   - Fail-closed: returns `Left FeDisabled`

5. **Add `feReadRange` method** for chunked reads:
   ```haskell
   feReadRange :: FilePath -> Integer -> Int -> IO (Either FileExplorerErr ByteString)
   ```
   - Local: `openBinaryFile` + `hSeek AbsoluteSeek offset` + `BS.hGetSome len`
   - Remote: `dd bs=$chunkSize skip=$index count=1 if="$p" 2>/dev/null` via
     **`runRemoteStream`** (uncapped raw transport, no UTF-8 decode). This
     is critical: `runRemoteBytes` caps at 50K which would truncate 4 MiB
     chunks.
   - Fail-closed: `Left FeDisabled`

6. **Add `runRemoteStream` to `RemoteRunner`** (§0a above):
   ```haskell
   , runRemoteStream :: forall r. [String] -> (Handle -> IO r) -> IO (Either ExecError r)
   ```
   - Hands the child's stdout `Handle` to the callback and reaps the child
     after it returns. No byte cap: the callback decides how much to read.
   - Same `withManagedProcess` shape as `runRealBytes` minus `readBounded`'s
     cap. Process-group cleanup (`create_group = True`) is shared.
   - `mkFakeRemoteRunner` and `mkFakeRemoteRunnerRecording` gain a canned
     implementation so existing fakes stay total under `-Werror`.
   - Requires `RankNTypes` (for the `forall r.`) — add as a per-file pragma
     in `Remote.hs` (it is NOT a default extension, verified in
     `seal-harness.cabal:27-31`).

7. **Update `mkFailClosedFileExplorer`** with stubs for `feStatFile` and
   `feReadRange`.

8. **Update `Serve.hs`** call site: pass `maxScanBytes` as `readCeiling` and
   the configured chunk size as `downloadChunkBytes`. (Full config wiring in
   WU-2.)

9. **Update ALL `RemoteRunner` fakes** across the test suite to add a
   `runRemoteStream` stub. Files with `RemoteRunner` literals (from §8 of
   the design, verified by `grep -rn "RemoteRunner {" test/`):
   - `test/Seal/TestHelpers/ApiTestHarness.hs`
   - `test/Seal/Tools/Exec/FileExplorerSpec.hs` (2 fakes)
   - `test/Seal/RepoDiscoverySpec.hs`
   - `test/Seal/Session/AgentMetaCacheSpec.hs` (2 fakes)
   - `test/Seal/Session/ExecCacheSpec.hs`
   - `test/Seal/Tools/Exec/WorkdirFsSpec.hs`
   (Note: `FakeCaps.hs` does NOT contain a `RemoteRunner` literal — it is a
   `ChannelCaps` helper. Do not touch it.)

**DoD**:
- [ ] `mkLocalFileExplorer` takes two Ints (readCeiling, downloadChunkBytes)
- [ ] `mkRemoteFileExplorer` takes two Ints
- [ ] `readBoundedFile` uses hSeek, not BS.readFile (behavioural test: large file)
- [ ] `FileStat` record with strict fields
- [ ] `feStatFile` works on local (returns size + mtime as epoch seconds)
- [ ] `feStatFile` works on remote (one SSH call via runRemoteShell)
- [ ] `feStatFile` returns `Left FeDisabled` on fail-closed
- [ ] `feReadRange` local: correct slice at offset 0, mid-file, final short chunk
- [ ] `feReadRange` local: past-EOF returns error, not short read
- [ ] `feReadRange` remote: correct slice via dd through runRemoteStream
- [ ] `feReadRange` remote: chunk > 50K works (not truncated by runRemoteBytes cap)
- [ ] `feReadRange` fail-closed returns `Left FeDisabled`
- [ ] Viewer ceiling unchanged when only download ceiling is raised (M-2/SC-7)
- [ ] `runRemoteStream` added to RemoteRunner with forall r. (RankNTypes pragma)
- [ ] `runRemoteStream` in mkRealRemoteRunner: uncapped, reaps child
- [ ] ALL RemoteRunner fakes updated with runRemoteStream stub
- [ ] All existing tests pass with updated call sites
- [ ] No `BS.readFile` on the download path (grep assertion)
- [ ] T-STREAM-CAP: runRemoteStream delivers payload > 50K intact

### WU-2: Backend — stat + manifest + chunk routes + config + blocked-path enforcement

**Files**:
- `src-gateway-types/Seal/Gateway/Types/Route.hs` (3 new route constructors)
- `src/Seal/Gateway/OpenApi.hs` (3 new openApiMeta arms)
- `src/Seal/Gateway/API.hs` (3 new handlers + dispatch arms + ApiDeps fields + blocked-path check + error strings)
- `src/Seal/Gateway/Config.hs` (3 new config fields)
- `src/Seal/Command/Serve.hs` (wire new config)
- `test/Seal/Gateway/ApiRouteSpec.hs` (route count 73 → 76)
- `test/Seal/Gateway/ApiFilesSpec.hs` (new endpoint tests)
- All test files with `ApiDeps` literals (add 3 new fields — verified: ApiSpec.hs ~24 literals, Phase7aSpec.hs, SetupApiSpec.hs, ServerSpec.hs, MutationGuardSpec.hs, PatIngestionSpec.hs, ApiFilesSpec.hs, ApiTestHarness.hs)
- All test files with `PartialGatewayConfig` literals (add 3 new fields: SecuritySpec.hs, ConfigSpec.hs, etc.)
- `src/Seal/Command/AccessControl.hs` (`emptyGateway` literal: 3 new fields)
- `test/Seal/Tools/Exec/FileExplorerSpec.hs` (~45 mkLocalFileExplorer/mkRemoteFileExplorer call sites updated for arity, in addition to WU-1 new tests)

**Changes**:

1. **Three new `SealRoute` constructors:**
   - `RouteFilesStat` → `GET /api/files/stat`
   - `RouteFilesManifest` → `GET /api/files/download/manifest`
   - `RouteFilesChunk` → `GET /api/files/download/chunk`

2. **`handleFileStat`**: parse `path` query, call `feStatFile`, return JSON
   `{path, size, mtimeEpoch}`. `mtimeEpoch` is `null` when unavailable.

3. **`handleFileManifest`**: parse `path`, call `feStatFile`, compute
   `chunkCount = ceiling(size / chunkSize)`, return O(1) JSON manifest:
   ```json
   {"path":"...","size":N,"mtimeEpoch":M,"chunkSize":C,"chunkCount":K}
   ```
   Validates `chunkSize * chunkCount >= size` (T-MANIFEST-CONSISTENCY).
   Hard-block `blockedNames` paths → 403 (§6.3).

4. **`handleFileChunk`**: parse `path`, `index`, `size`, `mtime` query params.
   - Re-stat the file. If `size` or `mtimeEpoch` mismatches the request → 409.
     When mtimeEpoch is `null` (degraded mode), compare size only (T-MTIME).
   - If `index < 0` or `index >= chunkCount` → 416.
   - Compute `offset = index * chunkSize`, `len = min chunkSize (size - offset)`.
   - Call `feReadRange path offset len`.
   - Compute SHA256 of the chunk bytes → `X-Chunk-SHA256` header.
   - Response headers: `Content-Type: application/octet-stream`,
     `X-Content-Type-Options: nosniff`, `Content-Disposition: attachment`,
     `Cache-Control: no-store`, `X-Chunk-Index: <i>`,
     `X-Chunk-ChunkSize: <n>`, `Content-Length: <actual>`.
   - Hard-block `blockedNames` paths → 403.
   - Re-stat **after** the read and compare before serving (§12.3 mitigation):
     if the file changed between read and re-stat → 409. This turns a silent
     torn chunk into a visible error.

5. **Config fields** in `GatewayConfig`:
   - `gcFileDownloadPromptBytes :: Maybe Int` (default 256 MiB = 268435456)
   - `gcFileDownloadChunkBytes :: Maybe Int` (default 4 MiB = 4194304)
   - `gcFileDownloadAllowBlocked :: Maybe Bool` (default False; §6.3 override)
   - Codec entries in `gatewayConfigCodec`
   - `withGatewayDefaults` fallbacks

6. **Route count** assertion: 73 → 76.

7. **Audit logging** per download (§6.3f): **one line per download** (not per
   chunk), logged when the client completes the assembly. Since the server
   is stateless and does not know when a download "completes," the audit
   line is logged on the **manifest** request at `InfoS` with path + size +
   client IP. This is the closest server-side signal to "a download started"
   and is one line per download attempt, not N lines per chunk. The design
   says "one line per download" — the manifest request is that line.

8. **`ApiDeps`** gains `adDownloadPromptBytes :: Int`,
   `adDownloadChunkBytes :: Int`, and `adDownloadAllowBlocked :: Bool`.

9. **Blocked path check** (§6.3 SEC-B1/B2/B3): on stat/manifest/chunk routes,
   after `validateFilePath` (which calls `lexicalCollapse`), **canonicalize
   the path** (via `System.Directory.canonicalizePath` on the local arm, or
   `readlink -f -- "$p"` on the remote arm) and then run `blockedSegment`
   (from `Seal.Security.Path`) on the canonical path — not just lexical
   matching on the request string. This defeats the symlink bypass the
   design warns about (SEC-B3). On the local arm, `feReadRange` uses
   `openBinaryFile` followed by an fdStat dev/ino comparison to close the
   TOCTOU between canonicalization and read. If `blockedSegment` returns
   blocked → 403 `blocked_path` unless `adDownloadAllowBlocked` is True.
   The listing and viewer routes keep warning-only behavior (unchanged).

10. **Error strings** (§6.3e SEC-B5): the three new handlers use the error
    string `"file explorer disabled"` (matching the existing
    `gcFileExplorerEnabled` check) — NOT the false `"gateway is not
    loopback"` string that the existing handlers carry. The existing false
    strings are a pre-existing bug not fixed here, but the new routes do not
    propagate them.

11. **Retire old download route** (§5.9 SC-6): `handleFileDownload`
    (`API.hs:2407`) is kept for backwards compatibility but the frontend
    stops using it (WU-3/WU-4). SC-6 is verified by: (a) grep asserting no
    `BS.readFile` in `feReadRange` path, and (b) the old route is not called
    by the new frontend. The old route may be removed in a follow-up.

**DoD**:
- [ ] 3 new SealRoute constructors + routeMeta + allRoutes
- [ ] 3 new openApiMeta arms
- [ ] Route count assertion updated (73 → 76)
- [ ] `handleFileStat` returns `{path, size, mtimeEpoch}`
- [ ] `handleFileManifest` returns O(1) metadata (no hash list)
- [ ] `handleFileManifest` rejects inconsistent manifest (chunkSize*chunkCount < size)
- [ ] `handleFileChunk` returns raw bytes with X-Chunk-SHA256
- [ ] 409 on size/mtime mismatch (precondition); null mtime → size-only comparison
- [ ] Post-read re-stat: 409 if file changed between read and re-stat
- [ ] 416 on index out of range
- [ ] 403 on blockedNames paths (hard block, not warning) unless allow_blocked override
- [ ] Response headers: nosniff, attachment, no-store, octet-stream on all 3 routes
- [ ] `gcFileDownloadPromptBytes` + `gcFileDownloadChunkBytes` + `gcFileDownloadAllowBlocked` in GatewayConfig
- [ ] Serve.hs wires all three config values
- [ ] ApiDeps gains adDownloadPromptBytes + adDownloadChunkBytes + adDownloadAllowBlocked
- [ ] Audit log: one line per download (on manifest request), not per chunk
- [ ] New handlers use "file explorer disabled" string, not false "gateway is not loopback"
- [ ] Old `/api/files/download` route kept but not called by new frontend (SC-6)
- [ ] All ApiDeps test literals updated (3 new fields)
- [ ] All PartialGatewayConfig test literals updated (3 new fields)
- [ ] `gatewayConfigCodec` has entries for all 3 new fields
- [ ] `withGatewayDefaults` has fallbacks for all 3 new fields
- [ ] `emptyGateway` in `src/Seal/Command/AccessControl.hs` updated (3 new fields)
- [ ] `defaultGatewayConfig` in `src/Seal/Gateway/Config.hs` updated (3 new defaults)
- [ ] Blocked-path check uses canonical path + `blockedSegment`, not lexical-only
- [ ] Integration tests pass
- [ ] T-STAT, T-MANIFEST, T-CHUNK, T-409, T-416, T-BLOCKED, T-HEADERS
- [ ] T-MTIME: null mtime degrades to size-only comparison without false 409s
- [ ] T-MANIFEST-CONSISTENCY: inconsistent manifest rejected
- [ ] T12: remote chunk command contains shellQuoted path (injection test)
- [ ] T14: transport truncation surfaces as error, never a short chunk

### WU-3: Frontend — confirm dialog + stat + .partial naming + modalStack extraction

**Files**:
- `frontend/src/lib/modalStack.ts` (new — extracted from ChatArea.tsx)
- `frontend/src/components/DownloadConfirmDialog.tsx` (new)
- `frontend/src/components/ChatArea.tsx` (use extracted modalStack)
- `frontend/src/components/FilesView.tsx` (wire dialog, replace hardcoded string)
- `frontend/src/hooks/useApi.ts` (fetchFileStat hook)
- `frontend/src/types.ts` (FileStat type)
- `frontend/src/components/__tests__/FilesView.test.tsx` (update tests)
- `frontend/src/components/__tests__/DownloadConfirmDialog.test.tsx` (new)

**Changes**:

1. **`FileStat` type** in `types.ts`:
   ```typescript
   export interface FileStat {
     path: string
     size: number
     mtimeEpoch: number | null
   }
   ```

2. **`fetchFileStat`** in `useApi.ts`: `GET /api/files/stat?path=<p>` →
   `{ok: true, stat} | {ok: false, status}`.

3. **Extract `openModalStack` to `lib/modalStack.ts`** (DS-B6): The
   module-private `const` at `ChatArea.tsx:572` is extracted to a shared
   module so `DownloadConfirmDialog` and `ChatArea` share one Escape handler
   and cannot double-fire. `ChatArea.tsx` imports from the new location.

4. **`DownloadConfirmDialog`** component:
   - `role="dialog"`, `aria-labelledby`, `aria-modal="true"`
   - `createPortal` to document.body (avoids scroll-container clipping)
   - Shows actual file size + configured prompt threshold (not "128 KiB")
   - Three buttons: **Cancel**, **Download partial**, **Download full anyway**
   - Initial focus on Cancel (the safe choice)
   - Escape key cancels (via shared `openModalStack`)
   - Focus restore to the download button on close
   - Copy names the consequence for partial: "incomplete and unusable for
     archives, installers, or media"

5. **Replace hardcoded "128 KiB"** string in `FilesView.tsx:276` with a
   formatter driven by the stat response.

6. **`.partial` naming**: when a download is truncated (partial choice or
   transport truncation), the saved file is named
   `name.<N>MiB-of-<M>GB.partial` instead of `name`. A complete download
   keeps the original name.

7. **Wire dialog into FilesView**: on Download click, fetch stat first. If
   `stat.size > promptThreshold`, show dialog. Otherwise proceed directly.

**DoD**:
- [ ] `FileStat` type in types.ts
- [ ] `fetchFileStat` hook in useApi.ts
- [ ] `lib/modalStack.ts` extracted from ChatArea.tsx
- [ ] ChatArea.tsx imports from lib/modalStack.ts (no duplicate Escape handlers)
- [ ] `DownloadConfirmDialog` with role="dialog", aria-labelledby, aria-modal
- [ ] Dialog uses createPortal
- [ ] Dialog shows true file size + true configured threshold (not hardcoded)
- [ ] Three buttons: Cancel, Download partial, Download full anyway
- [ ] Initial focus on Cancel
- [ ] Escape cancels dialog (via shared openModalStack)
- [ ] Focus restored on close
- [ ] Hardcoded "128 KiB" string replaced with formatter
- [ ] `.partial` naming with totals for truncated downloads
- [ ] Dialog wired into FilesView download flow
- [ ] T-CONFIRM: dialog shows true size + threshold, all 3 choices behave
- [ ] T-PARTIAL: partial save named `.partial` with totals
- [ ] T-DIALOG-A11Y: role="dialog", Escape cancels, focus restored

### WU-4: Frontend — chunked download orchestration + progress UI + partial stop logic

**Files**:
- `frontend/src/hooks/useFileDownload.ts` (new)
- `frontend/src/components/DownloadProgress.tsx` (new)
- `frontend/src/components/FilesView.tsx` (wire progress UI)
- `frontend/src/types.ts` (Manifest type)
- `frontend/src/hooks/__tests__/useFileDownload.test.ts` (new)
- `frontend/src/components/__tests__/DownloadProgress.test.tsx` (new)
- `frontend/src/components/__tests__/FilesView.test.tsx` (update)

**Changes**:

1. **`Manifest` type** in `types.ts`:
   ```typescript
   export interface FileManifest {
     path: string
     size: number
     mtimeEpoch: number | null
     chunkSize: number
     chunkCount: number
   }
   ```

2. **`useFileDownload` hook** — the orchestration engine:
   - `fetchManifest(path)` → `GET /api/files/download/manifest?path=<p>`
   - **Partial stop logic** (§5.6): the hook accepts a `partialLimit` option.
     When set (from the "Download partial" dialog choice), the chunk loop
     stops at `partialLimit` chunks and names the output `.partial`.
     `partialLimit = Infinity` for "full anyway" or under-threshold downloads.
   - Sequential chunk fetching: for `i in 0..chunkCount-1`:
     - If `i >= partialLimit`: stop, set `stoppedAt = i`, break
     - Skip if already held in memory (resume)
     - `GET /api/files/download/chunk?path=<p>&index=<i>&size=<s>&mtime=<m>`
     - Verify `X-Chunk-SHA256` via `crypto.subtle.digest('SHA-256', chunk)`
     - On mismatch: retry once, then fail
     - On 409: discard held chunks, restart once; second 409 aborts
     - On network error: enter `'interrupted'` state with Retry/Cancel
     - On cancel (AbortController): keep held chunks, enter `'cancelled'` state
   - Length assertions before save (§6.1a):
     - `sum(received lengths) == manifest.size` (for full downloads)
     - `len(bytes[i]) == expectedLen(i)` for each chunk
   - Assembly: `new Blob(chunks in order)` → save via `createObjectURL` + `<a>`
   - In-memory chunk store: `Map<number, ArrayBuffer>` (session-scoped)
   - **Partial resume affordance**: when reopening a file with held chunks,
     show "N of M held — continue?" and resume from the chunk store.
   - States: `'idle' | 'fetching' | 'verifying' | 'interrupted' | 'cancelled' | 'partial-stop' | 'done' | 'error'`

3. **SHA256 verification** via `crypto.subtle`:
   - Insecure-context degradation: if `crypto.subtle` is unavailable (plain
     HTTP LAN), skip verification and report "verification skipped (insecure
     context)" rather than throwing.

4. **`DownloadProgress` component** (§5.7a):
   - `role="progressbar"` with `aria-valuenow={done}`, `aria-valuemin={0}`,
     `aria-valuemax={chunkCount}`, `aria-valuetext="87 of 225 chunks, 380 MB of 900 MB"`
   - Bytes counter: `formatSize(bytesDone)` / `formatSize(total)`
   - Cancel button bound to `AbortController.abort()`
   - Live region: `role="status" aria-live="polite"` for milestones (start,
     25/50/75%, cancel, done)
   - Interrupted state: shows Retry + Cancel (not collapsed into cancel)
   - Lives in the pane header of FilesView

5. **Wire into FilesView**: replace the existing `downloadFile` call with
   `useFileDownload`. Show `DownloadProgress` when a download is active.

6. **`URL.createObjectURL` stub** in test-setup or beforeEach (jsdom doesn't
   implement it).

**DoD**:
- [ ] `FileManifest` type in types.ts
- [ ] `useFileDownload` hook with manifest → chunks → assembly → save flow
- [ ] Partial stop logic: `partialLimit` breaks the loop, names output `.partial`
- [ ] Sequential chunk fetching with per-chunk SHA256 verification
- [ ] In-memory chunk store (Map<number, ArrayBuffer>)
- [ ] Resume: skip already-held chunks (SC-2)
- [ ] Cancel: AbortController, keep held chunks (SC-3)
- [ ] 409 handling: discard + restart once, second 409 aborts
- [ ] Network error: 'interrupted' state with Retry/Cancel (not treated as cancel)
- [ ] Length assertions before save (sum == size for full, per-chunk length)
- [ ] SHA256 verification with insecure-context degradation
- [ ] Partial resume affordance: "N of M held — continue?"
- [ ] `DownloadProgress` with role="progressbar", aria-valuenow, aria-valuetext
- [ ] Cancel button in progress UI
- [ ] Milestone-only role="status" live region
- [ ] Interrupted state shows Retry + Cancel
- [ ] `createObjectURL` stubbed in tests
- [ ] T-RESUME: abort after 2/6, resume fetches only 3-5 (no duplicates)
- [ ] T-CANCEL: abort mid-flight, no further requests, chunks retained
- [ ] T-INTEGRITY: SHA256 mismatch retried once, then reported
- [ ] T-PRECONDITION: 409 discards chunks and restarts
- [ ] T-PROGRESS: progressbar with aria-valuenow advancing, Cancel aborts
- [ ] T-INTERRUPTED: network error → Retry/Cancel, not treated as cancel
- [ ] T-409-BOUND: second 409 aborts
- [ ] T-PARTIAL-RESUME: after partial save, store not cleared; second request resumes
- [ ] M-1: constant server memory — read 20 chunks of 512 MiB sparse file under RTS -M limit (guarded; pendingWith if no sparse files)

### WU-5: Security hardening — sanitizeHref link block

**Files**:
- `frontend/src/lib/markdown.ts`
- `frontend/src/lib/__tests__/markdown.test.ts`

**Changes**:

1. **Block `/api/files/download*` in `sanitizeHref`** (§6.0a, T-LINK-BLOCKED):
   - Any URL starting with `/api/files/download` is not passed through as a
     clickable anchor. Return `null` (or the href is not rendered as a link).
   - This prevents an agent from emitting a markdown link that, when clicked
     by a human, triggers a same-site download with the session cookie.

2. **Test**: `sanitizeHref('/api/files/download?path=...')` does not yield a
   clickable anchor in `MarkdownView`.

**DoD**:
- [ ] `sanitizeHref` blocks `/api/files/download*` URLs
- [ ] T-LINK-BLOCKED: test asserts blocked URL is not rendered as clickable link
- [ ] Existing markdown link tests still pass

### WU-6: Docs + full gate

**Files**:
- `docs/handoffs/` (handoff document)
- `docs/plans/active-plan.md` (update)
- `docs/context/execution-state.md` (update)

**Changes**:
- Write handoff document
- Run `make check` (build + cabal test + hlint + npm test)
- Verify all gates green
- Self-reflect

**DoD**:
- [ ] `cabal build all` clean
- [ ] `cabal test` — 0 failures
- [ ] `hlint src/ test/ src-chat-channels/` — No hints
- [ ] `npm test` — all frontend tests pass
- [ ] Handoff document written

## 2. Dependencies

```
WU-1 (backend types + ceiling split + runRemoteStream)
  ↓
WU-2 (backend routes — depends on feStatFile + feReadRange + runRemoteStream from WU-1)
  ↓ (parallel with)
WU-3 (frontend dialog — depends on stat route from WU-2)
  ↓
WU-4 (frontend chunked download — depends on manifest+chunk routes from WU-2)
  ↓
WU-5 (security — independent, can run anytime)
  ↓
WU-6 (docs + gate)
```

WU-5 is independent and can run in parallel with WU-3/WU-4.

## 3. Files touched (summary)

| File | WU | Change |
|---|---|---|
| `src/Seal/Tools/Exec/FileExplorer.hs` | 1 | Split ceilings, fix readBoundedFile, FileStat, feStatFile, feReadRange |
| `src/Seal/Tools/Exec/Remote.hs` | 1 | runRemoteStream method (uncapped, forall r) |
| `src/Seal/Command/Serve.hs` | 1,2 | Wire two ceilings + config |
| `src-gateway-types/Seal/Gateway/Types/Route.hs` | 2 | 3 new route constructors |
| `src/Seal/Gateway/OpenApi.hs` | 2 | 3 new openApiMeta arms |
| `src/Seal/Gateway/API.hs` | 2 | 3 new handlers + dispatch + ApiDeps fields + blocked-path |
| `src/Seal/Gateway/Config.hs` | 2 | 3 new config fields |
| `test/Seal/Gateway/ApiRouteSpec.hs` | 2 | Route count 73→76 |
| `src/Seal/Command/AccessControl.hs` | 2 | Update emptyGateway literal (3 new PartialGatewayConfig fields) |
| `test/Seal/Gateway/ApiFilesSpec.hs` | 2 | New endpoint tests |
| `test/Seal/Tools/Exec/FileExplorerSpec.hs` | 1 | New tests for stat, range, ceiling split, runRemoteStream |
| `test/Seal/TestHelpers/ApiTestHarness.hs` | 1 | RemoteRunner fake: add runRemoteStream stub |
| `test/Seal/RepoDiscoverySpec.hs` | 1 | RemoteRunner fake: add runRemoteStream stub |
| `test/Seal/Session/AgentMetaCacheSpec.hs` | 1 | RemoteRunner fake: add runRemoteStream stub (2 fakes) |
| `test/Seal/Session/ExecCacheSpec.hs` | 1 | RemoteRunner fake: add runRemoteStream stub |
| `test/Seal/Tools/Exec/WorkdirFsSpec.hs` | 1 | RemoteRunner fake: add runRemoteStream stub |
| `frontend/src/types.ts` | 3,4 | FileStat + FileManifest types |
| `frontend/src/hooks/useApi.ts` | 3 | fetchFileStat |
| `frontend/src/hooks/useFileDownload.ts` | 4 | New: chunked download orchestration |
| `frontend/src/lib/modalStack.ts` | 3 | New: extracted from ChatArea.tsx |
| `frontend/src/components/ChatArea.tsx` | 3 | Import from lib/modalStack.ts |
| `frontend/src/components/DownloadConfirmDialog.tsx` | 3 | New: confirm dialog |
| `frontend/src/components/DownloadProgress.tsx` | 4 | New: progress UI |
| `frontend/src/components/FilesView.tsx` | 3,4 | Wire dialog + progress, replace hardcoded string |
| `frontend/src/lib/markdown.ts` | 5 | Block /api/files/download* hrefs |
| Various test files | 1-5 | Tests + test literal updates |
| `seal-harness.cabal` | 1 | No new modules |
| `test/Main.hs` | 1 | Wire new test modules if any |

## 4. Test matrix

| ID | Description | WU |
|---|---|---|
| T1 | `chunkCount size chunkSize` — size 0→1, exact multiple, +1 byte | 1 |
| T2 | `chunkRange size chunkSize index` — first, last (short), mid, index==count→Nothing | 1 |
| T6 | `feReadRange` returns exact slice from known fixture | 1 |
| T7 | offset 0, mid-file, final short chunk | 1 |
| T8 | past-EOF index → error, not short read | 1 |
| T9 | no `BS.readFile` on download path (grep + behavioural) | 1 |
| T10 | permission denied / missing / directory → FileExplorerErr | 1 |
| T-STREAM-CAP | runRemoteStream delivers payload > 50K intact | 1 |
| M-1 | constant server memory — 20 chunks of 512 MiB sparse under RTS -M (SC-1) | 1 |
| M-2 | Viewer ceiling unchanged when download ceiling raised (SC-7) | 1 |
| T-STAT | stat route returns {path, size, mtimeEpoch} | 2 |
| T-MANIFEST | manifest route returns O(1) metadata | 2 |
| T-CHUNK | chunk route returns bytes + X-Chunk-SHA256 | 2 |
| T-409 | size/mtime mismatch → 409; null mtime → size-only | 2 |
| T-416 | index out of range → 416 | 2 |
| T-BLOCKED | blockedNames path → 403 on stat/manifest/chunk (unless override) | 2 |
| T-HEADERS | nosniff, attachment, no-store, octet-stream on all routes | 2 |
| T-MTIME | null mtime degrades to size-only without false 409s | 2 |
| T-MANIFEST-CONSISTENCY | inconsistent manifest (chunkSize*chunkCount ≠ size) rejected | 2 |
| T12 | remote chunk command contains shellQuoted path | 2 |
| T14 | transport truncation surfaces as error, never short chunk | 2 |
| T-CONFIRM | dialog shows true size + threshold, all 3 choices work | 3 |
| T-PARTIAL | partial save named `.partial` with totals | 3 |
| T-DIALOG-A11Y | role="dialog", Escape cancels, focus restored | 3 |
| T-RESUME | abort after 2/6, resume fetches only 3-5 (SC-2) | 4 |
| T-CANCEL | abort mid-flight, no further requests, chunks retained (SC-3) | 4 |
| T-INTEGRITY | SHA256 mismatch retried once, then reported (SC-4) | 4 |
| T-PRECONDITION | 409 discards chunks, restarts (SC-5) | 4 |
| T-PROGRESS | progressbar with aria-valuenow advancing, Cancel aborts | 4 |
| T-INTERRUPTED | network error → Retry/Cancel, not treated as cancel | 4 |
| T-409-BOUND | second 409 aborts | 4 |
| T-PARTIAL-RESUME | after partial save, store not cleared; second request resumes | 4 |
| T-LINK-BLOCKED | sanitizeHref blocks /api/files/download* | 5 |

## 5. Baseline

Verified on `main` @ `847eee5`:
- `cabal test`: 4297 examples / 0 failures / 42 pending
- `hlint`: No hints
- Frontend: 1030 tests / 43 files
- Route count: 73
