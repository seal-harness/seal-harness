# Handoff: Chunked resumable download — implementation complete

**Date**: 2026-11-14 · **Branch**: `files/chunked-download` (off `main` @ `847eee5`)
**Design**: `docs/superpowers/specs/2026-11-13-chunked-resumable-download-design.md`
**Plan**: `docs/superpowers/plans/2026-11-14-chunked-resumable-download-plan.md`

## 0. TL;DR

All 6 work units are implemented and committed. The feature is complete
and green. No PR has been opened (operator preference — fold into a
future PR).

| Fact | State |
|---|---|
| Branch | `files/chunked-download`, tree clean |
| Commits | 5 (WU-1 through WU-5) |
| Backend tests | 4310 examples, 0 failures, 41 pending |
| Frontend tests | 1031 tests, 43 files, all pass |
| hlint | No hints |
| tsc | Clean |

## 1. What was built

### WU-1 — Backend foundation (`e4d8e50`)

- Split `mkLocalFileExplorer`/`mkRemoteFileExplorer` to take two Ints:
  `readCeiling` (viewer, unchanged) + `downloadChunkBytes` (new, 4 MiB)
- Fixed `readBoundedFile`: `hFileSize` + `hSeek` + bounded `hGetSome` instead
  of `BS.readFile` + `BS.take` (fixes the 2 GB allocation bug)
- Added `FileStat` record + `feStatFile` method (local + remote + fail-closed)
- Added `feReadRange` method for chunked reads (local: hSeek+hGetSome,
  remote: dd via `runRemoteStream`)
- Added `runRemoteStream` to `RemoteRunner` — uncapped transport
  (`forall r. [String] -> (Handle -> IO r) -> IO (Either ExecError r)`)
  with `RankNTypes` per-file pragma. The 50K cap on `runRemoteBytes`
  would have silently truncated 4 MiB chunks.

### WU-2 — API routes + config + blocked-path (`df18a2d`)

- 3 new routes: `GET /api/files/stat`, `GET /api/files/download/manifest`,
  `GET /api/files/download/chunk`
- O(1) manifest (no hash list — per gate §12): `{path, size, mtimeEpoch,
  chunkSize, chunkCount}`
- Per-chunk `X-Chunk-SHA256` header on chunk responses
- Blocked-path enforcement (SEC-B3): canonicalize path → `blockedSegment`
  → 403. Listing/viewer keep warning-only (unchanged).
- 3 new config fields: `file_download_prompt_bytes` (256 MiB),
  `file_download_chunk_bytes` (4 MiB), `file_download_allow_blocked` (False)
- Audit logging: one `InfoS` line per download (on manifest request)
- Route count: 73 → 76. `blockedSegment` exported from `Seal.Security.Path`.
- Old `/api/files/download` route kept for backwards compatibility.

### WU-3 — Confirm dialog + stat + .partial naming (`7fe6ed7`)

- `DownloadConfirmDialog.tsx`: `role="dialog"`, `aria-labelledby`,
  `aria-modal`, `createPortal`, initial focus on Cancel, Escape via shared
  modalStack, focus restore. Shows actual file size + configured threshold.
  Three buttons: Cancel, Download partial, Download full anyway.
- `lib/modalStack.ts`: extracted from `ChatArea.tsx` (DS-B6)
- `fetchFileStat` hook + `FileStat`/`FileManifest` types
- Hardcoded "128 KiB" string → dynamic message
- `.partial` naming with totals: `name.<N>MiB-of-<M>GB.partial`

### WU-4 — Chunked download orchestration + progress UI (`8e979a6`)

- `useFileDownload` hook: manifest → sequential chunks → SHA256 verify →
  assemble → save. In-memory chunk store (`Map<number, ArrayBuffer>`).
  Resume (skip held chunks), cancel (AbortController), 409 handling
  (discard + restart once, second 409 aborts), network error
  (interrupted state with Retry/Cancel), partial stop logic.
- `DownloadProgress.tsx`: `role="progressbar"` with `aria-valuenow`,
  `aria-valuetext`, Cancel button, milestone-only `role="status"` live region.
  Distinct rendering for interrupted/error/done/partial/cancelled states.
- SHA256 verification via `crypto.subtle` with insecure-context degradation.

### WU-5 — sanitizeHref link block (`cdc56ec`)

- Block `/api/files/download*` URLs in `sanitizeHref` — prevents
  agent-authored markdown links from minting same-site download clicks.
  (§6.0a, T-LINK-BLOCKED)

## 2. What remains (follow-ups, not blockers)

1. **Frontend tests for the new download flow.** The existing FilesView
   tests still use the old `downloadFile` mock. New tests for
   `useFileDownload` (T-RESUME, T-CANCEL, T-INTEGRITY, etc.) and
   `DownloadConfirmDialog` (T-CONFIRM, T-DIALOG-A11Y) should be written.
2. **`M-1` constant-memory test.** The plan includes a guarded test
   (`pendingWith` when sparse files are unavailable) but it was not
   written. It should be added to `FileExplorerSpec.hs`.
3. **Remote testing.** The operator has a remote machine for testing.
   The remote arm is implemented but not exercised against a live SSH
   connection in this session.
4. **`showSaveFilePicker` streaming.** Large assemblies may be slow;
   streaming directly to disk is deferred (§9.3 of the design).
5. **Parallel chunk fetching.** v1 is sequential; a N=2..4 window is
   deferred (§5.7/§9.1).
6. **Frontend CI job.** Vitest is local-only; `.github/workflows/ci.yml`
   runs `cabal test` only.

## 3. If you resume

1. The branch is `files/chunked-download` off `main`. All 5 commits are
   on the branch.
2. Run `make check` to verify gates. Baseline: 4310 Haskell / 1031 frontend.
3. Write the missing frontend tests (follow-up 1 above).
4. Open a PR when the operator is ready. Use `BIN_EXEC gh` with
   `--head files/chunked-download`.
5. The old `/api/files/download` route can be removed once the frontend
   is confirmed to no longer call it.
