# Chunked Resumable Download — Design Document

> **Status**: Rev 1.1 — self-review pass before Design Review Gate Round 1.
> **Date**: 2026-11-13
> **Branch**: `files/chunked-download` (to be branched from `files/explorer2`)
>
> **Rev 1.1 self-review finding (fixed in §5.3a):** the manifest for a file
> larger than **3.00 GiB** exceeds `runRemoteBytes`'s hardcoded 50 000-byte
> cap (`Remote.hs:309`) and would be **silently truncated**, yielding a
> manifest with missing hashes. Arithmetic: 4 MiB chunks → 65 bytes per hex
> line → 769 chunks fit in 50 000 bytes → 3.00 GiB exactly. Found by
> self-review, before the gate. See SR-1.
> **Author**: Human-authored decision, AI-assisted write-up
> **Supersedes**: the ad-hoc "raise the limit to 256 MiB" proposal discussed on
> 2026-11-13, which was rejected as unsound (see §1.2).

## 0. Revision log

Empty until the gate runs. Findings will be appended as
`2026-11-13-chunked-download-gate-round1.md` and resolved here.

### Self-review (pre-gate)

| ID | Blocker | Resolution |
|---|---|---|
| SR-1 | Remote manifest silently truncates above 3.00 GiB (50 000-byte transport cap) | §5.3a — paged manifest + explicit oversize error, never silent |
| SR-2 | §5.4 said remote streaming goes "through the same conduit" without saying how the 50 000-byte `runRealBytes` cap is bypassed | §5.4a — dedicated streaming runner method, no fixed cap |

### Round 1 — Product Manager (NEEDS_REVISION, 7 blockers)

| ID | Blocker | Resolution |
|---|---|---|
| PM-B1 | Cross-reload resume (IndexedDB + 7-day TTL) is unrequested scope, the biggest new client subsystem, and contradicts §6.3 | §5.5a — kept but narrowed to resume-only, `blockedNames` never persisted, TTL 24 h; O-6 asks the operator |
| PM-B2 | "Download partial" has no use case and manufactures the corrupt-artifact defect §1.1.4 exists to kill | §5.8 — consequence named inline; one-line drop if CTO/Designer agree |
| PM-B3 | Operator's report cited, never quoted | §3.1a — verbatim, both messages |
| PM-B4 | §6.3 is unrequested scope, already in §8, while O-1 is open | §6.3 cut to a single dialog line; O-1 decided before implementation |
| PM-B5 | Manifest (O(size)) runs **before** the size dialog → multi-minute wait or 120 s timeout; regresses UC-2 | §5.6 — `stat` first (O(1)), hash only after the choice |
| PM-B6 | "Constant memory" is server-only; client buffers whole file; UC-1's 900 MB unvalidated | §3.2a — stated as server-side guarantee; SC-9 walkthrough at 900 MB |
| PM-B7 | No traceability: G5 has no SC, "cancel" has no UC, no user-outcome criteria | §3.2a — requirement→UC→SC matrix, UC-6, SC-8/SC-9 |

Suggestions applied: S1 (non-goals + UI rule), S2 (renamed to
`file_download_prompt_bytes`), S3/S4 (UC-6, chunk counter), S5 (blockedNames
never persisted).

### Round 1 — Designer (NEEDS_REVISION, 7 blockers)

| ID | Blocker | Resolution |
|---|---|---|
| DS-B1 | No progress/cancel/resume UI for a 40-minute operation; "cancelable" had no button | §5.7a — progressbar with `aria-valuenow`, Cancel, resume affordance, milestone live region; pane-header home; T-PROGRESS |
| DS-B2 | `indexedDB` is `undefined` under vitest+jsdom; `fake-indexeddb` absent → T-RESUME/T-CANCEL unwritable | §7.4 — prerequisite stated; dep added to §8. Verified by probe |
| DS-B3 | 4 of 5 failure modes have no UI; 409 loops unbounded; network loss conflated with cancel; quota + `crypto.subtle` unmentioned | §5.7a + §6.5a — status-switched error contract, bounded 409, `'interrupted'` state, insecure-context degradation |
| DS-B4 | `store.clear()` after partial save made "partial" terminal, contradicting G2/SC-2; copy names a filename not a consequence | §5.6 + §5.8 — only complete saves clear; `.partial` carries totals; consequence named inline |
| DS-B5 | `mtime` encoding unpinned (local sub-second vs remote seconds) → spurious 409s; `size`/`chunkSize`/`chunkCount` precedence unstated | §6.3a — integer epoch seconds both ways, size-only degraded mode, manifest consistency rejected |
| DS-B6 | a11y contract underspecified; `AccessGate` cited as model but lacks name/Escape/restore/portal; `openModalStack` is module-private | §5.8 — `RawJsonModal` named as model, portal mandated (clipping), Cancel focus, restore fallback, trap out of scope; `lib/modalStack.ts` extracted |
| DS-B7 | O-2 unresolved; streamed manifest would change the §5.2 contract | §5.11a — resolved as streamed NDJSON; §5.2 marked not-final |

Suggestions applied: S2/S3 (mode threaded, totals in filename), S6/S7 (error
body + status-only switching), S9 (`errorMessageForStatus` 409/416 arms),
S10 (startup discoverability of unfinished downloads).

### Round 1 — Security (NEEDS_REVISION, 8 blockers)

The central finding, accepted: **every control Rev 1 added was a client-side
UI affordance or a prose commitment, on a surface whose threat model must
assume the client may not cooperate.** Three load-bearing decisions moved
server-side as a result.

| ID | Blocker | Resolution |
|---|---|---|
| SEC-B1/B2 | A security control cannot be an open question; warn-only suits the browse path, not the byte path | §6.3 — O-1 closed: hard block on manifest/chunk/stat, warning unchanged on listing/viewer, override via operator-written config |
| SEC-B3 | Blocked-name matching on the request string is defeated by one symlink | §6.3 — canonicalize then `blockedSegment`; `O_NOFOLLOW`/`fstat` dev-ino closes the TOCTOU |
| SEC-B4 | Chunk route drops `nosniff`/`attachment` the replaced route already had, enabling stored XSS on the app origin | §6.3b — all four headers on every chunk/manifest response |
| SEC-B5 | "Passkey-gated" premise false; service token, `AccessOpen`, wildcard bind also authorize | §6.3e — real set enumerated (verified `AccessControl.hs:295-315`); must not copy the false "not loopback" strings |
| SEC-B6 | Manifest is a work amplifier with no bound (~512 remote spawns; `touch` busts the cache) | §6.3c — semaphore, token bucket, stream wall-clock cap, 409 cap |
| SEC-B7 | IndexedDB plaintext retained on explicit cancel; client duplicates `blockedNames`; no `no-store` | §6.3d — cancel deletes, TTL 1 h, client mirror deleted, `no-store` added |
| SEC-B8 | No audit line on a bulk-read feature | §6.3f — one line per download |
| SEC-M5 | Per-chunk hashing cannot catch a missing final chunk; total length unbound | §6.1a — explicit sum/length assertions, `Integer` offsets |

Also added §6.0a: agent-reachable exfiltration via `sanitizeHref` and a
same-site markdown link (verified in code; mitigated by §6.3 and
T-LINK-BLOCKED). `X-Chunk-SHA256` demoted to diagnostic-only, with
`manifest.hashes` authoritative.

### Round 1 — CTO (NEEDS_REVISION, 10 blockers)

| ID | Blocker | Resolution |
|---|---|---|
| CTO-B1 | No gateway-route test section; `T-PRECONDITION` stubs `fetch` so it proves the client reacts to a 409 it invented, not that the server emits one | **§7.6** added — T-GW-* covering every row of §6.3h plus `X-Chunk-*` |
| CTO-B2 | `stat` endpoint used by §5.6 but absent from §5.2 — the central latency fix has no wire contract | **§5.2a** added |
| CTO-B3 | §8 omits the route-plumbing tax: `Route.hs`, `OpenApi.hs` (one arm per constructor, `-Wincomplete-patterns`), `ApiRouteSpec.hs` (`expectedRouteCount = 73`), `ApiFilesSpec.hs` (`X-Truncated: false`) | §8 rewritten with all four (all verified) |
| CTO-B4 | Audit logging dropped on the new routes | §6.3f already covers; add `Audit.hs` to §8 |
| CTO-B5 | §5.1 signatures cannot express §5.3a paging, §5.11a streaming, or §5.4 windows | **§5.1 rewritten** — paged record + bounded chunk read |
| CTO-B6 | O-2 marked resolved in the log, still open in §10, §5.2 declared "not final" | §5.2 finalized; O-2 removed from §10 |
| CTO-B7 | P1 admits 8,388,608 chunks per case; P4 hashes ~800 MiB/run and is near-vacuous | bounds tightened to `chunkCount ∈ [0,64]`; P4 replaced with a cross-endpoint property in §7.3 |
| CTO-B8 | M-1 cannot set `-M` from inside a test and never touches `responseStream` | re-exec subprocess (the `CompileFail.hs` pattern) + route-level assertion |
| CTO-B9 | T-RESUME passes with a `Set` — an off-by-one re-fetch is invisible | ordered-array equality, applied to all three resume tests |
| CTO-B10 | Branching off `files/explorer2` stacks three unreviewed layers (PR #308 is a **draft**; explorer2 has no PR) and collides on 6 files | **operator decision — see §11** |

**Accepted recommendation (§11): slice the work.** Three of the four defects in
§1.1 need no chunking at all, and one of them is the operator's literal
complaint. See §11 for the proposed Slice 1.

### Round 1 — Architect (NEEDS_REVISION, 7 blockers)

The architect's central finding would **delete a large part of this design**,
and after checking it I agree with it. Recorded in full in §12.

| ID | Blocker | Resolution |
|---|---|---|
| AR-B1 | Two incompatible chunk mechanisms: `feReadRange` returns a strict `ByteString` while §5.4/§5.4a stream conduit windows | **§12** — pick strict per-chunk; §5.4's conduit and §5.4a's runner fall away |
| AR-B2 | `runRemoteStream`'s free `r` needs `forall r.` + `RankNTypes`, which is **not** a default extension | **verified**: `cabal:27-31` lists only four extensions. Deleted by AR-B6 |
| AR-B3 | New routes drop `nosniff`/octet-stream/attachment | already covered by §6.3b; corrects §5.9's call-site ref to `API.hs:2413` |
| AR-B4 | `setTimeout` takes **seconds**, so `setTimeout 120_000` is ~**33 hours**, not 120 s | **verified** — a real pre-existing bug at `Server.hs:347`; raised as §12.3 |
| AR-B5 | `feReadRange` mixes `Integer` offset with `Int` length, contradicting §6.1a.4 | §5.1 corrected to `Integer` throughout |
| AR-B6 | Manifest pre-hashing is unnecessary and doubles transfer | **accepted — see §12** |
| AR-B7 | §8 omits `mkFailClosedFileExplorer`, `Serve.hs:514-517`, `ApiFilesSpec.hs:105` | §8 corrected |

---

## 1. Problem

### 1.1 What happens today

`GET /api/files/download` serves a file with a hard byte ceiling and no
paging, no resume, and no integrity check. Four separate defects compound:

1. **The ceiling is the wrong constant.** `Serve.hs:514,517` passes the
   compiled-in `maxScanBytes` (131072 = 128 KiB, `Text/LineFile.hs:76-77`) into
   `mkLocalFileExplorer` / `mkRemoteFileExplorer`. That constant is the *agent
   context* budget. `[retrieval] max_scan_bytes` is parsed
   (`Config/File.hs:517`) and resolved (`retrievalMaxScanBytes`, `:754`) but
   only reaches the agent read paths (`TurnEngine.hs:683,1091`), so **no
   configuration change affects the download limit today**.
2. **The read reads the whole file to return a prefix.**
   `readBoundedFile` (`FileExplorer.hs:226-233`) is `BS.readFile path` then
   `BS.take maxBytes`. A 2 GB file allocates 2 GB to return 128 KB. The
   ceiling protects the response, not the process.
3. **The remote path is tighter and silently different.** `runRemoteBytes`
   caps at a hardcoded `50_000` (`Remote.hs:309`), and `remoteReadFileBytes`
   (`FileExplorer.hs:512-524`) sets
   `truncated = transportTruncated || BS.length bs >= ceilingBytes`, so in
   remote mode the effective limit is 48.8 KiB. The UI banner
   (`FilesView.tsx:276`) hardcodes the string "128 KiB" and is therefore
   wrong in remote mode.
4. **A truncated file is saved as if complete.** `downloadFile`
   (`useApi.ts:1853-1868`) calls `a.click()` regardless of `truncated`. The
   operator gets a correctly-named prefix. For `.zip`/`.tar.gz`/`.pdf` that
   fails later, elsewhere.

There is no streaming anywhere on this path: `responseLBS`
(`API.hs:2428`) is a strict body, and `res.blob()` (`useApi.ts:1858`)
buffers client-side too.

### 1.2 Why "just raise the limit to 256 MiB" was rejected

Naively raising the ceiling to 256 MiB multiplies problems 1.1.2 and 1.1.4 by
2048:

- **Resident memory.** ~256 MB per concurrent download, transiently ~512 MB
  during `BS.readFile`'s read-then-take. Bounded only by concurrency.
- **It would also raise the *viewer* ceiling.** `mkLocalFileExplorer`
  (`FileExplorer.hs:215-219`) feeds one `ceilingBytes` to **both**
  `feReadFile` (viewer) and `feReadFileBytes` (download). `localReadFile`
  decodes to `Text` and computes `length (T.lines content)`
  (`FileExplorer.hs:356-358`) — at 256 MiB that is a 256 MB `Text` plus a
  multi-million-element boxed list, inside a JSON response. The viewer is
  strictly worse than the download.
- **It does not solve the actual complaint.** A file over the new limit still
  fails, and still fails as a silent prefix.

The two ceilings must be **split**, and the download path must **stream**.

### 1.3 Secondary defect found during investigation

`feReadFileBytes` never calls `checkBlocked`
(`FileExplorer.hs:171-175`). `blockedNames` (`Security/Path.hs:53` —
`.env`, `.ssh`, `.gnupg`, `.netrc`, `.seal`) is used **only** to produce a
warning string in a directory listing (`FileExplorer.hs:241,443,694`); it never
prevents a read. So `~/.ssh/id_rsa` is downloadable today, as is
`~/.seal/security.toml`. Mitigations in place: the gateway is passkey-gated and
binds loopback by default. This is pre-existing, not introduced here — but a
resumable downloader removes the last size brake on pulling a large sensitive
bundle, so §6.3 addresses it explicitly.

---

## 2. Prior art / evidence audit

| Concern | Found in repo? | Where |
|---|---|---|
| SHA256 available | **yes** | `crypton` in `library` build-depends; `Security/Crypto.hs:49` `sha256Hash` |
| Chunked response streaming | **yes**, dep present | `conduit` (`seal-harness.cabal` library stanza), `wai`/`warp` (`:376-377`) |
| Range/seek read on local files | **no** | no `hSeek`/`hFileSize` anywhere in `src/Seal/Tools/Exec/` |
| IndexedDB / client storage | **no** | nothing in `frontend/src/` |
| Web Worker | **no** | nothing in `frontend/src/` |
| AbortController | **yes** | `useApi.ts:689,1010,1248` |
| Cancel/abort of a server-side exec | **yes** | `Seal/Tools/Exec/Abort.hs`, `AbortFlag` |
| Modal / `role="dialog"` primitive | **yes** | `ChatArea.tsx`, `AccessGate.tsx` |
| Existing remote exec pattern | **yes** | `remoteReadCmd` (`FileExplorer.hs:588-596`) — constructed command + `shellQuote` path |

**Conclusion:** server-side building blocks (hashing, streaming, abort) exist.
Client-side chunk storage and the range-read capability are new.

---

## 3. Goals and success criteria

### 3.1 Goals

**G1.** Download a file of any size the operator has configured, without the
server buffering more than a fixed chunk window regardless of file size.
**G2.** Resume an interrupted download without re-fetching completed chunks.
**G3.** Detect corruption per chunk, and detect that the file changed
underneath a resumed download.
**G4.** Cancel a download; a cancel is itself resumable.
**G5.** Files over the configured limit are no longer a dead end (confirm ->
partial or full).

### 3.1a What the operator actually asked for (verbatim, PM-B3)

Quoted from the 2026-11-13 session, because this is the sole justification for
the dialog (§5.8), the threshold decision (§5.10) and the `.partial` naming —
and because the prior Files gate raised "is there recorded evidence, or is it
inference?" and went unanswered:

> I think we need to build our own robust chunked, resumable, download
> functionality. Here are some requirements:
> - It should run in constant memory on the server. In other words, we should
>   not rely on Haskell's lazy IO.
> - Downloader should split the file into appropriately sized chunks
> - Chunk SHA256 hashes should be used for chunk integrity checks.
> - Downloads should be resumable without needing to re-download already
>   downloaded chunks.
> - Downloads should be cancelable.

Preceded by, the same day:

> Now when I try to download a bigger file I get `Last download was truncated
> — only the first 128 KiB was saved`. I think we should default to allow files
> of up to 256 megs and we should make this limit configurable. I think if the
> file exceeds the limit we shouldn't categorically prevent it from
> downloading. We should show a dialog telling the user the file size and that
> it exceeds the limit and asking whether they want to cancel, download
> partial, or download full anyway.

**Note the gap:** "resumable" is stated but **cross-reload resume is not**.
This is what makes PM-B1 a real scope question rather than a nitpick — see
§3.2a on why IndexedDB persistence is being treated as *in scope but
minimal*, and O-6.

### 3.2 Success criteria (measurable)

| ID | Criterion | Verified by |
|---|---|---|
| SC-1 | Peak server memory is independent of file size | §7.3 M-1 |
| SC-2 | A resume fetches **zero** already-held chunks | §7.4 T-RESUME (the DoD the operator called out) |
| SC-3 | A cancelled download resumes from the cancel point | §7.4 T-CANCEL |
| SC-4 | A corrupted chunk is detected and retried once | §7.4 T-INTEGRITY |
| SC-5 | A file mutated between manifest and chunk yields 409, not silent corruption | §7.4 T-PRECONDITION |
| SC-6 | Non-streaming `BS.readFile` is gone from the download path | §7.2 (grep + behaviour test) |
| SC-7 | The viewer ceiling is unaffected by the download ceiling | §7.3 M-2 |

**Explicitly not a success criterion:** throughput. v1 is sequential
(§5.7); parallel chunk fetching is deferred (§9).

### 3.2a Traceability matrix, and non-goals (PM-B7, PM-S1)

Every requirement in §3.1a maps to a goal, a use case and a success criterion.
The gaps PM-B7 identified (G5 with no SC; "cancel" with no UC) are closed here.

| Requirement | Goal | Use case | Success criterion |
|---|---|---|---|
| constant memory on server | G1 | UC-1 | SC-1, M-1 |
| split into chunks | G1 | UC-1 | SC-6, T1/T2/P1-P3 |
| SHA256 per chunk | G3 | UC-4 | SC-4, T-INTEGRITY |
| resumable, no re-download | G2 | UC-1 | **SC-2, T-RESUME** |
| cancelable | G4 | **UC-6 (new)** | **SC-3, T-CANCEL** |
| over-limit is not a dead end | **G5** | UC-2 | **SC-8 (new)** |

**UC-6 (new, for "cancelable").** An operator starts a 40-minute download,
realises it is the wrong file, and stops it. *Wants:* the transfer to stop
now. *So that:* it is not consuming bandwidth and the link for the next 40
minutes — and so that resuming later starts where it stopped.

**New success criteria:**
- **SC-8 (G5).** Clicking Download on an over-threshold file yields a dialog
  with the true size and the true threshold, and all three choices reach a
  terminal state without an error. (Answers the operator's actual complaint;
  verified by T-CONFIRM.)
- **SC-9 (user outcome).** Post-merge operator walkthrough
  (`make serve`, download one large local file and one large remote file,
  interrupt each, resume each). Baseline: today, both fail at 128 KiB /
  48.8 KiB with a saved prefix. Evaluation point: after merge, by hand — the
  project has no telemetry, which the Files redesign spec already stated.

**Non-goals (PM-S1).** Chunk SHA256 **does not authenticate** — a hostile
server can publish hashes for whatever it sends (§6.1). No UI may present
SHA256, or a verified-chunk count, as a security, trust, or authenticity
signal. Doing so would plant an eighth stale security claim
(handoff §4.2 lists seven). Tamper-evidence requires a manifest signed with an
out-of-band pinned key (§9.2), which is out of scope.

**Honest bound on "constant memory" (PM-B6).** Constant memory is a
**server-side** guarantee (SC-1, M-1). The client necessarily holds the
assembled file; §9.3 records that `showSaveFilePicker` streaming is deferred,
so client footprint is O(size). "Constant memory" must not be read
end-to-end. UC-1's 900 MB is the number the walkthrough (SC-9) validates; it is
**not** asserted as safe for arbitrarily large files until §9.3 lands.

---

## 4. Use cases

**UC-1 (primary).** An operator wants to pull a 900 MB model checkpoint out of
a remote workdir through the Files tab, over a flaky link.
*Wants:* the transfer to survive a dropped connection without restarting.
*So that:* a 40-minute download is not lost to a minute-long outage.

**UC-2.** An operator clicks Download on a 2 GB file to learn it "exceeds the
limit".
*Wants:* to be told the size, and to choose.
*So that:* the limit is a decision point, not a wall. (Answers the operator's
own report.)

**UC-3.** An operator downloads a file across a page reload.
*Wants:* progress retained.
*So that:* navigating away is not punitive.

**UC-4.** An operator downloads a large artifact and it arrives corrupt.
*Wants:* to know, before using it.
*So that:* the failure surfaces at download, not at unpack.

**UC-5 (rejected).** *"The operator downloads a file from a hostile server and
Chunk SHA256 proves it is authentic."* — **Not delivered.** See §6.1. Chunk
hashes detect corruption; they do not authenticate, because the manifest and
the chunks come from the same server. Stated so SHA256 in the requirements is
not read as more than it is.

---

## 5. Design

### 5.1 Ceiling split (prerequisite)

`FileExplorerHandle` gains a distinct download ceiling:

```haskell
data FileExplorerHandle = FileExplorerHandle
  { feListDirectory    :: FilePath -> IO (Either FileExplorerErr FileListing)
  , feListDirectories  :: [FilePath] -> IO (Either FileExplorerErr [FileListing])
  , feReadFile         :: FilePath -> IO (Either FileExplorerErr FileContent)  -- viewer ceiling
  , feReadFileBytes    :: FilePath -> IO (Either FileExplorerErr (ByteString, Bool)) -- kept, see §5.9
  , feResolveHome      :: IO (Either FileExplorerErr FilePath)
  -- new:
  , feStatFile         :: FilePath -> IO (Either FileExplorerErr FileStat)
  , feReadRange        :: FilePath -> Integer -> Int -> IO (Either FileExplorerErr BS.ByteString)
  , feChunkManifest    :: FilePath -> Int -> IO (Either FileExplorerErr [Text])
  }
```

`mkLocalFileExplorer`/`mkRemoteFileExplorer` take **two** Ints:
`readCeiling` (unchanged semantics, still `maxScanBytes` or the resolved
`[retrieval] max_scan_bytes`) and `downloadChunkBytes`. Nothing in the viewer
path changes behaviour.

### 5.2 Wire protocol

Stateless conditional requests. **No server-side session state**, which is what
keeps memory constant.

```
GET /api/files/download/manifest?path=<p>&chunk=<n>
 200 { "path": "...", "size": 123456789, "mtime": "2026-11-13T…Z",
       "chunkSize": 4194304, "chunkCount": 30, "algo": "sha256",
       "hashes": ["<hex>", …], "warning": null }
 400 path missing / invalid   · 403 disabled   · 404 not found
 400 path is a directory      · 500 IO/exec

GET /api/files/download/chunk?path=<p>&index=<i>&size=<sz>&mtime=<mt>
 200 raw bytes
     X-Chunk-SHA256: <hex>      X-Chunk-Index: <i>
     X-Chunk-ChunkSize: <n>     Content-Length: <actual>
 409 file changed since manifest (size or mtime mismatch)
 416 index out of range
 404/403/400 as above
```

- **`size`+`mtime` on every chunk request** are the precondition. The server
  re-stats and compares. This binds chunk requests to the manifest **without**
  a signed token, session, or server memory. A mismatch is 409 and the client
  re-runs the manifest (discarding held chunks).
- `index` is parsed as a bounded integer; `0 <= index < chunkCount` else 416.
- Path is re-validated on **every** request via the existing
  `validateFilePath` (`API.hs:2328`). The manifest is never trusted.
- `warning` mirrors the listing-warning convention (§6.3).

**Chunk size** default 4 MiB, reported by the manifest so the client adapts
rather than assuming.

### 5.3 Manifest cost and caching

Hashing a file requires reading it. So a manifest is O(size) work:

- **Local:** one pass, `hSeek`+read per chunk, hash each.
- **Remote:** **one** SSH invocation for the entire manifest — a fixed-argv
  loop emitting one hash per line (`dd bs=$cs skip=$i count=1 | sha256sum`).
  This is the batching decision: a download is **1 manifest call + N chunk
  calls**, never 2N calls.

Manifests are cached in memory keyed by `(path, size, mtime)`, bounded
LRU (64 entries, 10-minute TTL). A 2 GB file costs ~32 KB of hex. Repeat
downloads skip hashing entirely. Cache is advisory only — correctness does not
depend on it.

### 5.3a Manifest size limit (SR-1)

`runRemoteBytes` caps output at a hardcoded 50 000 bytes (`Remote.hs:309`) and
`readBounded` reports truncation by closing the pipe. A manifest carries 65
bytes per chunk (64 hex + newline), so **769 chunks fit in 50 000 bytes** —
that is a **3.00 GiB** file at 4 MiB chunks. Above that, a manifest returned
through `runRemoteBytes` is silently truncated and the download would fail
integrity checks chunk-by-chunk with no actionable cause.

Three-part resolution:

1. **Never go through the capped path.** The manifest uses its own runner
   method (§5.4a) with no fixed byte cap — the manifest is bounded by
   `chunkCount`, not by a transport constant.
2. **Page the manifest explicitly.** `manifest` accepts `from`/`to` chunk
   indices and returns `hashes` for that window plus `nextFrom`. The client
   pages until `nextFrom` is null. Response size is then bounded by a chosen
   page (default 512 chunks ≈ 33 KB) regardless of file size.
3. **Fail loudly on oversize.** If the server cannot page (a client that
   only sent `path` asks for a file whose full manifest exceeds the page
   budget), it returns `413` with `{"error":"manifest too large","chunkCount":N,"pageSize":M}`
   and the client retries with paging. A truncated hash list is never
   returned as if complete.

The DoD for SR-1: a test asserts that a manifest request for a file beyond the
page budget either pages correctly or 413s — and **never** returns a
`hashes` array shorter than `chunkCount` with a 200. (§7.4 T-MANIFEST-BIG.)

### 5.4 Constant-memory chunk serving

Chunk responses use `responseStream` with a `conduit` source reading in
64 KiB windows and stopping after the chunk's byte count:

- **Local:** `openBinaryFile`, `hSeek` to `index * chunkSize`, then read at
  most `min chunkSize (size - offset)`.
- **Remote:** stream the `ssh` child's stdout handle through the same conduit,
  stopping at the byte count, then reap the child (`withManagedProcess`
  cleanup kills the process group — `Remote.hs:231-233` `create_group=True`).

**No lazy IO.** Every read is an explicit bounded `BS.hGetSome`; the conduit
source yields and returns `()`.

### 5.4a Streaming runner (SR-2)

`RemoteRunner` gains one method; nothing existing changes:

```haskell
data RemoteRunner = RemoteRunner
  { runRemote          :: [String] -> IO (Either ExecError Text)
  , runRemoteStdin     :: [String] -> ByteString -> IO (Either ExecError Text)
  , runRemoteEnv       :: [(String, String)] -> [String] -> IO (Either ExecError Text)
  , runRemoteBytes     :: [String] -> IO (Either ExecError (ByteString, Bool))
  -- new:
  , runRemoteStream    :: [String] -> (Handle -> IO r) -> IO (Either ExecError r)
    -- ^ Hands the child's stdout 'Handle' to the callback and reaps the
    -- child after it returns. No byte cap: the callback decides how much to
    -- read. Used by chunk serving (§5.4) and the manifest (§5.3a).
  }
```

This is the same `withManagedProcess` shape as `runRealBytes`
(`Remote.hs:293-320`) minus `readBounded`'s cap, so the process-group cleanup
(`create_group = True`) and the host-key/unreachable error mapping are shared,
not duplicated. `mkFakeRemoteRunner` gains a canned implementation so the
existing fakes stay total (`test/Seal/Tools/Exec/FileExplorerSpec.hs:596-660`,
`TestHelpers/ApiTestHarness.hs:617`, and the five other `RemoteRunner` fakes
listed in §8).

`readBoundedFile` (`FileExplorer.hs:226-233`) is fixed independently of this
work: `hFileSize` + `hSeek`+bounded read instead of `BS.readFile`.

### 5.5 Client: chunk store

`IndexedDB`, one object store `chunks`, key `${manifestKey}:${index}` where

```
manifestKey = sha256hex(`${path}\u0000${size}\u0000${mtime}`)
```

Keying by the triple means a changed file **cannot** collide with held chunks.
Records hold `{ blob: ArrayBuffer, sha256: string }`. Chunks are deleted on
successful assembly, and swept by TTL (7 days) on startup.

Why IndexedDB and not Cache Storage: we need per-chunk arbitrary keys and
per-chunk metadata, and a bounded sweep. `localStorage` is disqualified —
synchronous and ~5 MB.

### 5.5a Scope decision on persistence (PM-B1) — and the §6.3 tension

PM-B1 is right that cross-reload resume is **not** in the operator's words
(§3.1a: "resumable" ≠ "survives a reload"). It is also right about the
contradiction: §6.3 agonizes over *warning* before pulling a `blockedNames`
path while §5.5 would silently persist that file's chunks in browser storage
for a week.

Resolution — IndexedDB **stays in v1** but with a narrowed job:

1. **It is the mechanism for resume, not a durability feature.** In-memory
   retention cannot survive the failure mode that matters in UC-1 (a dropped
   link on a long transfer often coincides with a reload). Without it, "resume"
   degrades to "retry the whole file" whenever the tab was disturbed.
2. **`blockedNames` matches are never persisted** — they are held in memory
   only, and a reload discards them. So the sensitive-path policy in §6.3 is
   now consistent at the storage layer rather than contradicted by it. This
   also shrinks the TTL-sweep surface (PM-S5).
3. **TTL drops from 7 days to 24 hours.** A resumable download is an
   hours-scale activity; a week of retained file content is durability nobody
   asked for.

If the operator prefers, deferring persistence entirely (§9.8) keeps v1
entirely in-memory and costs only UC-3.

### 5.6 Client: download orchestration

```
requestDownload(path):
  stat = GET stat                          # O(1) — NOT O(size). See SR-3/B5.
  if stat.size > promptThreshold: open ConfirmDialog (§5.8)
     cancel                      -> return
     partial                     -> partialLimit = promptThreshold
     full / under threshold      -> partialLimit = Infinity
  manifest = GET manifest                  # O(size) — only now, after the decision
  if manifest.size > pageBudget: page until complete
  for i in 0..chunkCount-1:
     if store has valid chunk i: continue                # SC-2
     if i >= partialLimit: stoppedAt = i; break            # "partial" choice
     bytes = GET chunk(i, size, mtime)
     if sha256(bytes) != manifest.hashes[i]: retry once, else fail
     store.put(i, bytes)
  blob = new Blob(chunks in order)
  save(blob, mode)                         # mode threads .partial naming
  if mode == 'full':  store.clear(manifestKey)   # only a COMPLETE save clears
  else:               keep chunks, mark 'partial-stop'   # resumable, see below
```

**"Partial" is a stopping point, not a dead end (DS-B4).** The first draft
called `store.clear(manifestKey)` unconditionally, which discarded every held
chunk after a partial save and made continuing to full impossible without
re-fetching — contradicting G2/SC-2 outright. Now only a *complete* save
clears. A partial save leaves the store intact, so reopening the same file
offers "continue (87 of 225 held)" and resumes. `mode` is threaded to the
saver so T-PARTIAL's `.partial` naming has an explicit source rather than an
implicit `partialLimit` (DS-S2).

**Partial naming carries the totals (DS-S3).** `name.256MiB-of-1.4GB.partial`
rather than `name.partial`: a bare `.partial` tells a downstream tool nothing
about whether the file is resumable or abandoned, and carries no integrity
signal.

**Why stat precedes manifest (SR-3, PM-B5).** Hashing is O(size). Manifest
first meant a 2 GB remote file produced a multi-minute wait — or the 120 s
Warp timeout (§5.11) — *before* the operator was told the size. That is worse
than today's instant "too big" wall, i.e. it regressed the very complaint this
work answers. `feStatFile` (§5.1) already exists in the design for this; the
size decision is O(1) and happens before any hashing. The manifest is fetched
only after the operator has chosen, so "partial" never pays for a hash of the
bytes it will discard beyond `partialLimit` (§5.3a paging bounds it anyway).

- **Progress**: `i` of `chunkCount` is known, so progress is free to render.
  The full affordance set (progressbar, Cancel, resume hint, live region) is
  specified in §5.7a; §9.9 scopes out only throughput/ETA estimation.

- **Resume** = re-running this loop; it is idempotent by construction.
- **Cancel** = `AbortController.abort()` (`useApi.ts:689` idiom) via the
  explicit Cancel button in §5.7a. Completed chunks stay in the store, so
  cancel *is* resume (SC-3).
- **Changed file** = 409 mid-loop -> discard `manifestKey` chunks, restart
  **once**; a second 409 aborts (§6.5a).
- Assembly uses `new Blob([...])`, which the browser backs off-heap. §9 records
  the honest limit: very large assemblies may still be slow; `showSaveFilePicker`
  streaming to disk is the follow-up, not v1.

### 5.7 Concurrency

v1 fetches chunks **sequentially**. Rationale: the SSH mux carries one channel
per invocation and the remote ceiling is per-invocation; parallel chunks add
ordering, retry, and cancellation complexity for a throughput win we are not
measuring. A `N=2..4` window is a scoped follow-up (§9.1) behind a config knob.

### 5.7a Progress, cancel, and resume affordances (DS-B1)

The first draft specified abort *machinery* and resume *semantics* but **no
UI** — for a 40-minute operation (UC-1) the first several minutes were
indistinguishable from a hang, and "cancelable" (a stated requirement) had no
button.

Progress lives in the **pane header of `FilesView`**, not in `FileRow` and not
in `BottomBar`: the row can re-render out from under a long download, and
`BottomBar` is session-scoped while this is a Files-tab operation.

| Element | Spec |
|---|---|
| Determinate progress | `role="progressbar"`, `aria-valuenow={done}`, `aria-valuemin={0}`, `aria-valuemax={chunkCount}`, `aria-valuetext="87 of 225 chunks, 380 MB of 900 MB"` |
| Bytes counter | `formatSize(bytesDone)` / `formatSize(total)` — reuse `FilesView.tsx:92` |
| Cancel button | bound to the same `AbortController` (§5.6) — the requirement's missing affordance |
| Resume affordance | "87 of 225 held — safe to close this tab" (UC-3 made verifiable *to the user*) |
| Live region | `role="status" aria-live="polite"`, announcing **milestones only** (start, 25/50/75 %, cancel, done) — announcing 225 chunks is an anti-pattern. Precedents: `ChatArea.tsx:57`, `NewTabComposer.tsx:124` |

Zero `role="progressbar"`/`aria-valuenow` exists in `frontend/src` today (verified),
so this is genuinely new; §7.4 gains T-PROGRESS.

**Network loss is not cancel (DS-B3).** A transport failure keeps the progress
UI in a distinct `'interrupted'` state with **Retry** and **Cancel**, rather
than collapsing into the cancel path. Retry resumes from the chunk store.

v1 fetches chunks **sequentially**. Rationale: the SSH mux carries one channel
per invocation and the remote ceiling is per-invocation; parallel chunks add
ordering, retry, and cancellation complexity for a throughput win we are not
measuring. A `N=2..4` window is a scoped follow-up (§9) behind a config knob.

### 5.8 The confirm dialog (answers the operator's report)

`role="dialog"`, following `ChatArea.tsx` / `AccessGate.tsx`, not a bespoke
widget. Copy states the **actual** numbers, never a hardcoded unit:

**a11y contract (DS-B6) — the model is `RawJsonModal` (`ChatArea.tsx:649`),
not `AccessGate.tsx`.** Those two idioms differ materially: `AccessGate.tsx:420`
has `role="dialog" aria-modal="true"` but **no** `aria-labelledby`, **no**
Escape handler, **no** focus restore and **no** portal. Naming only
`role="dialog"` would let this dialog pass its own a11y test while having no
accessible name and no focus management. Pinned requirements:

| Requirement | Spec | Why |
|---|---|---|
| `createPortal` | **mandatory** | `FilesView`'s pane is `overflow-y-auto` (`FilesView.tsx:836`), so an inline overlay is clipped by the scroll container — a concrete reason, not a style preference |
| Accessible name | `aria-labelledby`; assert via `getByRole('dialog', { name: … })` | a test asserting only `role` passes with no name |
| Initial focus | **Cancel** | the decision contains a footgun; focus must not default to it |
| Focus restore | return focus to the row's download button; **fall back to the pane** if the row is unmounted | after a long download the listing may have re-rendered and `previouslyFocused?.focus?.()` silently no-ops (`ChatArea.tsx:645`) |
| Escape | cancels the pre-flight dialog **only** | in-progress state uses the explicit Cancel button (§5.7a) |
| Focus trap | **deliberately out of scope** — stated, not inherited by accident | neither existing modal traps; `aria-modal` without one is a known half-measure |

**`openModalStack` must be extracted (DS-B6).** It is a module-private
`const` at `ChatArea.tsx:572`, so `DownloadConfirmDialog.tsx` cannot reuse it —
and `FilesView` + `ChatArea` coexist under `RowLayout`, so two independent
Escape handlers can double-fire. Extract to `lib/modalStack.ts` and add it to
§8's file list.

> **Download 1.4 GB file?**
> This file exceeds the configured prompt threshold of **256 MiB**.
> - **Cancel** — do nothing
> - **Download partial** — save only the first 256 MiB, as `.partial`.
>   **The saved file will be incomplete and unusable for archives,
>   installers, or media** (`.zip`, `.tar.gz`, `.pdf`, `.mp4`).
> - **Download full anyway** — save all 1.4 GB

The threshold is a **prompt, not a cap** — which is what makes "full anyway"
coherent, and which is why it is named `file_download_prompt_bytes` (§5.10),
not `..._max_bytes`: a `max` that does not cap is precisely the stale-claim
shape this repo keeps re-learning (§1.3, handoff §4.2).

**Why "partial" still exists (PM-B2 response).** No use case wants a prefix of
an archive — and §1.1.4 correctly calls a silently-saved prefix the worst of
the four defects. It is retained for exactly one scenario: pulling the first N
bytes of a *large text or log* file to inspect it, where a prefix is genuinely
useful and the operator knows what they asked for. Because that is a narrow
case, the copy names the consequence inline (above) instead of relying on a
`.partial` suffix, and the suffix remains so the artifact cannot masquerade as
complete. If the CTO/Designer judges the option unjustified, dropping it is a
one-line change and does not affect G1-G5.

The `128 KiB` hardcoded string at `FilesView.tsx:276` is replaced by a
formatter driven by the stat/manifest response.

### 5.9 What is retired

`feReadFileBytes`'s ceiling-truncating behaviour is replaced by the chunk path.
The method is kept (one call site, `API.hs:2418`) during transition but the
download route stops using it, so no unbounded `BS.readFile` remains reachable
(SC-6).

### 5.10 Configuration

`Gateway/Config.hs`, alongside `gcFileExplorerEnabled` (`:52,:76,:160`):

```toml
[gateway]
file_download_prompt_bytes = 268435456  # 256 MiB — dialog threshold, NOT a cap
file_download_chunk_bytes = 4194304    # 4 MiB
```

Renamed from `file_download_max_bytes` per PM-S2. What the threshold actually
protects: interrupting an accidental multi-GB pull on a slow or metered link.
It bounds no bytes (§6.4 states this openly); its only job is to make a large
transfer a deliberate choice.

Both optional with the defaults above. Deliberately **separate** from
`[retrieval] max_scan_bytes`: that is the agent's context budget; raising it to
read a large log must not silently lift the download threshold.

### 5.11 Warp timeout

**The premise of Rev 1's O-2 was false.** Verified against warp-3.4.13.1 (the
resolved version in `dist-newstyle/cache/plan.json`) and the official haddock
for `setTimeout`:

> "Slow-loris" timeout lower-bound value in seconds. Connections where network
> progress is made less frequently than this may be closed. In practice many
> connections may be allowed to go without progress for up to twice this
> amount of time. **Note that this timeout is not applied to application code,
> only network progress.**

So `setTimeout 120_000` (`Server.hs:347`) is **not** a per-request total
deadline. It closes a connection that makes no *network* progress for 120 s.

| Belief in Rev 1 | Actual behaviour |
|---|---|
| A 256 MiB monolithic body dies at 120 s | Only if it stalls >120 s without writing; a steady transfer is fine |
| A long manifest is killed at 120 s | **No** — hashing time is application time, which the timeout does not bound |
| Chunked transfer "sidesteps" the timeout | Not a sidestep; chunking was never needed to avoid it |

**What actually needs bounding is wall-clock application time**, which Warp
does not do for us. That is why §6.3c requires an explicit cap on
`runRemoteStream` and on manifest hashing — a self-imposed deadline, not
Warp's.

### 5.11a O-2 resolved: streaming manifest (DS-B7)

> **Status: downgraded.** The timeout half of this question was based on a
> false premise (§5.11 — Warp's `setTimeout` does not bound application time).
> Streaming the manifest is still worth doing, but for the *right* reason:
> it lets the client start fetching chunks before hashing finishes, which is a
> latency win, not a timeout workaround. It no longer invalidates §5.2's
> contract as an emergency; treat it as a design improvement.

The manifest is O(size) — for UC-1's 900 MB remote file that is a full extra
SSH pass before any payload arrives, and this section concedes it can exceed
the 120 s Warp timeout. Combined with the missing progress UI, the opening
minutes of UC-1 were indistinguishable from a hang.

**Decision: streamed NDJSON progress.** `GET manifest` returns
`Transfer-Encoding: chunked` with one JSON object per line:

```
{"event":"stat","size":943718400,"mtimeEpoch":1763035200,"chunkSize":4194304,"chunkCount":225}
{"event":"chunk","index":64,"sha256":"…"}   # hashes as they complete
{"event":"progress","hashed":64}
…
{"event":"done","hashed":225}
```

Consequences stated because they change §5.2:

1. **This replaces `200 {manifest}`** for large files; §5.2 is therefore
   **not final** until this is folded in. The contract is the stream above.
2. The client accumulates `chunk` events and **may start fetching chunks
   before hashing finishes** for indices already received — first byte arrives
   far earlier.
3. A stream that dies mid-way is resumable: re-request with
   `from=<lastHashed+1>`, reusing §5.3a paging.
4. Small files (≤ `pageBudget`) keep the plain JSON response; the client
   detects by content-type. Both paths specified, neither implicit.

`settings = setTimeout 120_000` (`Server.hs:347`) is per-request. A chunk
response is small and fast, so chunked transfer sidesteps the 2-minute ceiling
that would have killed a monolithic 256 MiB body. The manifest, however, reads
the whole file to hash it and **can** exceed 120 s on a large remote file.
Mitigation: manifest gets its own longer timeout, or reports progress via a
streamed NDJSON response. **Open question O-2.**

---

## 6. Security and threat model

### 6.0 Blockers resolved here (SEC findings)

The security review's central criticism is structural and I accept it: **every
control Rev 1 added was either a client-side UI affordance or a prose
commitment, on a surface whose threat model must assume the client may not
cooperate.** A `warning` field in a JSON body is not a control — `curl`, a
bookmark, an `<a href>`, or a chat link never sees it.

Three decisions move server-side as a result:

1. **Blocked paths are refused on the data path** (§6.3), override only by an
   explicit operator-written config bit.
2. **Chunk responses carry the same hardening as the route they replace**
   (§6.3b) — Rev 1 dropped `nosniff`, `attachment`, and would have added no
   `no-store`.
3. **The manifest gets a work bound, not just a bytes bound** (§6.4) — it is
   the only place one small request becomes gigabytes of I/O.

### 6.0a Agent-reachable exfiltration (SEC-H2) — accepted, and mitigated upstream

### 7.0a Test for the agent-link primitive (SEC-H2)

| ID | Assertion |
|---|---|
| T-LINK-BLOCKED | `sanitizeHref('/api/files/download?path=…')` does **not** yield a clickable anchor in `MarkdownView` — an agent-authored markdown link cannot mint a download click |

This is the client half of §6.0a. The server half is §6.3's hard block. Both
are needed: the block reduces the blast radius, the link test removes the
one-click mint. Note that blocking all `/api/files/download*` hrefs is safe
because the download UI uses `fetch`, never an `<a href>`
(`useApi.ts:1853-1868`).


The reviewer identified a path Rev 1 missed entirely, verified in code:

`sanitizeHref` (`lib/markdown.ts:63-69`) passes through any URL starting with
`/`. `MarkdownView.tsx:41-43` renders it as `<a target="_blank">`. A click from
the app origin to `/api/files/download?path=…` is **same-site**, so the
`SameSite=Strict` session cookie is sent and the request is authorized. An
agent can therefore emit
`[Download docs](/api/files/download/chunk?path=/Users/x/.ssh/id_rsa&…)`
and obtain bytes with one human click — no opcode, no `SafePath`, no audit.

This is **not** introduced by this design (the route exists today; the size cap
was never a control on a small secret), but chunking makes it quiet and bulk.
Mitigations, in order of importance:

- **§6.3 hard block** removes the highest-value targets from the primitive
  entirely — a blocked path 403s regardless of who clicks.
- **§7.0a** adds a test that `sanitizeHref` does not pass `/api/files/download*`
  through as a clickable link, so agent-authored markdown cannot mint the link.
- **§6.3f** adds one audit line per download, so the primitive is at least
  visible in `seal.log`.

Residual (stated, not fixed): any link to a non-blocked path is still
click-to-download. Closing that fully needs download links to be
non-navigable (a token exchange), which is out of scope (§9.10).

### 6.1 What SHA256 chunks do and do not prove

### 6.1a Length is bound separately (SEC-M5) — a real integrity gap in Rev 1

Per-chunk hashing catches corruption **inside** a chunk. It does not catch a
transfer that yields **fewer chunks than `chunkCount`**: Rev 1's loop was
`bytes = GET chunk(i); if sha256(bytes) != hashes[i]: retry`, with nothing
asserting the totals. A dropped final chunk would assemble silently into a
short file.

Required before `save()`:

1. `sum(received lengths) == manifest.size`, as an explicit assertion.
2. `len(bytes[i]) == expectedLen(i)`, where `expectedLen(i)` is `chunkSize`
   for all but the last index and `size - (chunkCount-1) × chunkSize` for it.
3. A final chunk whose length differs from (2) is a **hard error**, never a
   silent short save.
4. `index`, `offset`, and `len` are `Integer` end to end; `index * chunkSize`
   in `Int` can overflow. The server asserts `offset + len <= size` before any
   read.


They detect **corruption in transit or storage** (bit rot, truncated writes,
proxy mangling) — SC-4. They do **not** authenticate: the manifest and the
chunks come from the same server, so a hostile server can publish hashes for
whatever it sends. v1 therefore does not defend against a malicious server.
Making it tamper-evident would require a manifest signed with a key the client
pins out-of-band, which is out of scope (UC-5 rejected).

### 6.2 Trust boundary

Unchanged from today: passkey-gated gateway, loopback by default. This is a
human-driven gateway route, **not** an opcode and **not** an agent-driven path,
so it is not subject to the "no opcode touches `~/.seal/`" rule — but it can
read `~/.seal/` today regardless (§1.3), which §6.3 addresses.

### 6.3 Sensitive paths — decided, not deferred (SEC-B1/B2/B3)

O-1 is **closed**. Rev 1 left "warn or block?" open and called it "decision
needed before implementation". A gate cannot approve a threat model containing
an unanswered "do we mitigate this?", so it is decided here.

**Decision: hard block on the data path; warning on the browse path; override
by explicit config.**

Why the Rev 1 argument ("hard-blocking the operator's own UI breaks legitimate
work") does not survive: it is correct for the **listing and viewer**, where
the operator chose the path and the response is metadata or a text preview. It
is wrong for a route whose entire job is to return bytes, because
(a) the warning is architecturally skippable (§6.0), and (b) the requester is
not always the chooser (§6.0a). An operator backing up `~/.ssh` deliberately
uses `tar` in a terminal — they do not need a browser button for it.

| Surface | Behaviour |
|---|---|
| Listing / viewer (`/api/files`, `/api/files/content`) | warning only — **unchanged** |
| Manifest / chunk / stat | **403 `blocked_path`** |
| Override | `[gateway] file_download_allow_blocked = true`, operator-written, logged at startup |

**Matching runs on the canonical path (SEC-B3), not the request string.** A
blocked-name match on the requested text is defeated by a symlink whose own
name is innocent — the agent can create that link in its own writable workdir,
and `Path.hs` already documents this exact bypass. Use the existing pattern:
canonicalize, then `blockedSegment canon` on the resolved path (as
`mkSafePathAllowAbs` does). On the local arm, `O_NOFOLLOW` or a post-open
`fstat` dev/ino comparison closes the re-stat to `openBinaryFile` TOCTOU.
Without this the policy is a gesture.

**Stated bound (SEC-M6).** `blockedNames` is a five-entry denylist
(`.env .ssh .gnupg .netrc .seal`). It does not cover `.aws`, `.kube`,
`.docker`, `~/.config/gh`, browser cookie stores, or `~/Library/Keychains`.
A denylist cannot make a whole-filesystem browser safe, and this document does
not claim it does.

### 6.3b Response hardening on chunk routes (SEC-B4)

The route being replaced already sets `Content-Type: application/octet-stream`,
`Content-Disposition: attachment`, and `X-Content-Type-Options: nosniff`
(`API.hs:2424-2428`). Rev 1's chunk spec dropped all three. A user file that is
HTML/JS/SVG, requested directly at a chunk URL and rendered in the **app
origin** — the origin holding the passkey session and the IndexedDB store —
is stored XSS against the most privileged origin in the product.

Every chunk and manifest response therefore sets `Content-Type:
application/octet-stream`, `X-Content-Type-Options: nosniff`,
`Cache-Control: no-store`, and `Content-Disposition: attachment`.

`no-store` matters twice: it closes the third copy of file content (the HTTP
disk cache) that the IndexedDB TTL sweep cannot see (§6.3d).

### 6.3c The manifest is a work amplifier — bounded (SEC-B6)

Rev 1 analysed **bytes served** and never **work performed**. The manifest is
O(size): one small authenticated request buys a full-file hash locally, or
~512 `dd | sha256sum` children for a 2 GB remote file. The cache key is
`(path,size,mtime)` — all requester-supplied, so `touch` busts it.

Controls: a **semaphore** capping concurrent manifest computations (2); a
**token bucket** on the manifest route specifically; a **wall-clock cap** on
`runRemoteStream` with process-group kill (§5.4a), otherwise a hung remote
`dd` pins a Warp thread; and the **409 restart cap** of 1 (§6.5a).

Rate limiting is deliberately *not* applied to chunk serving: a session holder
can already copy the file, so throttling bytes is theatre. The manifest is
where the amplification is.

### 6.3d IndexedDB policy (SEC-B7/M1/M2)

1. **Explicit cancel deletes; only interruption retains** (§5.6, T-CANCEL).
   Rev 1's "a cancel is itself resumable" collapsed two signals: a network
   interruption (retain) and a user saying "I do not want this file" (delete).
2. **TTL 1 hour, not 24** (§5.5a).
3. **Server decides; the client does not duplicate.** Because §6.3 refuses
   blocked paths server-side, Rev 1's client-side `blockedNames` mirror — a
   TypeScript reimplementation of a Haskell constant with no shared source of
   truth and no cross-language test — is **deleted**. It was a drift
   guarantee.

**Stated plainly:** IndexedDB is unencrypted browser-profile storage. Moving a
mode-0600 file into it is a **protection downgrade**, not a neutral cache.

### 6.3e Authentication — the real set (SEC-B5)

§6.2's "passkey-gated gateway" premise was incomplete. Verified in
`Seal/Gateway/AccessControl.hs:295-315`, these routes authorize on any of:

| Path in | Mechanism |
|---|---|
| `AccessPasskey` | valid `seal_session` cookie |
| `AccessPasskey` | **per-run service bearer token** (`hasServiceToken`) — held by chat channels (`Serve.hs:743,804`) |
| `AccessUnconfigured` | same service token |
| `AccessOpen` | **unconditional allow** — no auth at all |

So `mode = "none"` plus a wildcard bind is unauthenticated arbitrary-file read
on the LAN — which the Files redesign §6.1 already recorded. §6.4's DoS
reasoning must rest on this real set.

**Also:** the four `"gateway is not loopback"` error strings
(`API.hs:2342,2389,2410,2441`) are false — `Serve.hs:512` is
`fromMaybe True` with no loopback check. This design must **not** copy them
into the two new routes; that is how stale security claim #8 gets planted.

### 6.3f Audit line (SEC-B8)

One line per **download** (not per chunk): path, total bytes, client IP.
`API.hs:72` records audit logging as deferred and two docstrings still claim
it happens; a feature whose own threat model is bulk exfiltration cannot
perform bulk reads with no `seal.log` entry.

### 6.3g mtime encoding — pinned (DS-B5)

The two backends disagree on precision, and the value round-trips through a
query string compared for **exact equality** — a spurious-409 generator.
Verified in code:

| Backend | Source | Precision |
|---|---|---|
| Local | `getModificationTime` (`FileExplorer.hs:318`) | sub-second `UTCTime` |
| Remote | `parseMtime` (`FileExplorer.hs` ~:760) — Unix epoch **seconds** from `ls` | whole seconds |

**Pinned wire encoding:** integer Unix epoch seconds (`mtimeEpoch`), both
directions, both backends. Local truncates sub-second precision when encoding.
Manifest and chunk request therefore carry the same integer and exact
comparison is sound.

**Degraded mode:** if a backend cannot supply a stable mtime (`Nothing` —
symlinks, `stat` failure, `parseMtime` returns `Nothing` for `0`), the manifest
returns `"mtimeEpoch": null` and the precondition compares **size only**. Size
+ per-chunk hashes still catch mutation; a legitimate weaker mode, not a failure.

**Field precedence (DS-B5).** `size` is authoritative; `chunkSize × chunkCount`
must agree with it. A manifest where they disagree is **rejected** — otherwise
`chunkCount: 1` on a 2 GB file silently yields a 4 MiB save.

### 6.3h Error contract (DS-B3, DS-S7)

All non-2xx reuse `errJson`'s `{"error":"…"}` (`API.hs:3280`). The client may
switch on **status alone**:

| Status | Client behaviour |
|---|---|
| 409 | file changed → discard held chunks for `manifestKey`, restart **once**; a second 409 in the same transfer aborts with "file is changing — try again later" (bounds the otherwise-infinite restart loop) |
| 416 | index out of range → abort with a bug-report error; never a silent short save |
| 0 (network) | `'interrupted'` state with Retry/Cancel (§5.7a), **not** treated as a user cancel |
| 413 | manifest too large → retry with paging (§5.3a) |

New fetchers follow the established convention
`{ok:true,…} | {ok:false,status}` with `status: 0` for network error
(`useApi.ts:1760,1777`).

`blockedNames` (`.env`, `.ssh`, `.gnupg`, `.netrc`, `.seal`) currently produce
a warning string only. Recommendation: the manifest and chunk responses carry
`warning` when any path component is blocked, and the confirm dialog (§5.8)
gains a second, stronger line ("This file is in a sensitive location").

**Not** a hard refusal: hard-blocking the operator's own UI breaks legitimate
work (backing up `~/.ssh` deliberately), and the gateway is already
operator-authenticated. This mirrors the previously specified §5.9/§5.10
"warning channel" of the Files redesign, which the handoff calls its most
valuable follow-up. **Decision needed — O-1.**

### 6.4 DoS / resource limits

Total bytes served are unbounded once "full anyway" exists. Mitigations: the
route is loopback+passkey; chunk size bounds per-request memory; manifests are
cached and LRU-bounded. A per-connection concurrency cap is a follow-up.

### 6.5 Injection

`index`/`size`/`mtime` are parsed as bounded integers/ISO timestamps; path
re-validated per request (§5.2). The remote manifest command is constructed
server-side with `shellQuote` on the path, matching the existing
`remoteReadCmd` pattern (`FileExplorer.hs:588`) — no agent-supplied argv.

---

## 7. Testing (TDD matrix, RED first)

### 7.1 Pure functions

| ID | Unit under test | Cases |
|---|---|---|
| T1 | `chunkCount size chunkSize` | size 0 → 1; exact multiple; +1 byte |
| T2 | `chunkRange size chunkSize index` | first; last (short); every mid; `index == count` → `Nothing` |
| T3 | manifest JSON encode/decode | round-trip; unknown field ignored; missing `hashes` rejected |
| T4 | precondition compare | size mismatch → 409; mtime differs → 409; equal → ok |
| T5 | `manifestKey` derivation | distinct for (path,size,mtime) triple; stable across calls |

**QuickCheck properties** (security-critical pure functions, per house rule):
- `P1` chunk lengths sum to `size` for all `size ∈ [0, 8 MiB]`, `chunkSize ∈ [1, 1 MiB]`.
- `P2` ranges are contiguous and non-overlapping (partition property).
- `P3` last chunk length ∈ `(0, chunkSize]` for `size > 0`.
- `P4` `sha256` of concatenated chunks == whole-file `sha256` (ties §5.2 to reality).

### 7.2 Local range read

| ID | Assertion |
|---|---|
| T6 | `feReadRange` returns exactly the requested slice from a known fixture |
| T7 | offset 0, mid-file, and final short chunk |
| T8 | past-EOF index → `Nothing`/error, not a short read |
| T9 | **no `BS.readFile` on the download path** — grep-level assertion in the test plus a behavioural test on a file larger than the read window |
| T10 | permission denied / missing / directory map to the existing `FileExplorerErr` arms |

### 7.3 Remote

| ID | Assertion |
|---|---|
| T11 | manifest is **one** runner invocation (fake runner counts calls) — batching proof |
| T12 | chunk command contains the `shellQuote`d path; no raw injection |
| T13 | streamed chunk stops at the byte count and reaps the child |
| T14 | transport truncation surfaces as an error, never a short chunk |
| T-MANIFEST-BIG (SR-1) | a file beyond the page budget either pages correctly (`nextFrom` non-null, pages concatenate to `chunkCount`) **or** 413s — never a 200 with a short `hashes` array |
| T-STREAM-CAP (SR-2) | `runRemoteStream` delivers a payload larger than 50 000 bytes intact (the cap that truncates `runRemoteBytes` does not apply) |

**M-1 (memory, SC-1).** Guarded: read 20 consecutive 4 MiB chunks of a sparse
512 MiB file under an RTS `-M` limit; pass means the process stayed within
window-sized allocation. `pendingWith` when the platform cannot create sparse
files (per house testing rules).

**M-2 (SC-7).** Viewer ceiling is unchanged when only the download ceiling is
raised — asserts the two parameters are genuinely independent.

### 7.4 Frontend

**Test-environment prerequisite (DS-B2, verified).** `indexedDB` is
`undefined` in the vitest+jsdom setup (`node -e "typeof indexedDB"` →
`undefined`; `fake-indexeddb` and `idb` are both absent from
`frontend/package.json`). SC-2/SC-3 are the operator's called-out DoD and
their tests depend on a chunk store that **does not exist in the test
environment**. The plan must add:

```jsonc
// frontend/package.json devDependencies
"fake-indexeddb": "^6"      // + import 'fake-indexeddb/auto' in test-setup.ts
```

Otherwise T-RESUME and T-CANCEL are unwritable as specified. Also verified
present in Node 22 and safe to rely on: `crypto.subtle`, `structuredClone`,
`Blob.arrayBuffer`. `blob.text()` is likewise available.

`crypto.subtle` is **secure-context only**, so on plain-HTTP LAN access hash
verification throws — the repo already guards this shape via
`isSecureContextOk()` (`auth.ts:122`). Chunk verification must degrade to
"skip verification, say so" rather than throwing (DS-B3).

`global.fetch` stubs, per the established idiom (12 files) — **not** hook-level
`vi.mock`, which intercepts nothing because `useApi` binds its helpers
module-internally. The mock must route the manifest and chunk endpoints
separately.

| ID | Assertion |
|---|---|
| T-RESUME (SC-2) | abort after 2 of 6 chunks; resume issues requests for **only** chunks 2-5 and **zero** duplicate requests |
| T-CANCEL (SC-3) | abort mid-flight; no further requests; held chunks still in the store |
| T-INTEGRITY (SC-4) | chunk whose SHA256 mismatches is retried once, then reported |
| T-PRECONDITION (SC-5) | 409 mid-loop discards held chunks and restarts |
| T-CONFIRM | dialog shows true size + true configured limit (not "128 KiB"); all three choices behave |
| T-PARTIAL | partial save is named `.partial` |
| T-DIALOG-A11Y | `role="dialog"`, Escape cancels, focus restored |
| T-PROGRESS (DS-B1) | `role="progressbar"` with `aria-valuenow` advancing as chunks land; Cancel button aborts; milestone-only `role="status"` announcements |
| T-INTERRUPTED (DS-B3) | network failure shows Retry/Cancel, is **not** treated as a user cancel, and Retry resumes from held chunks |
| T-PARTIAL-RESUME (DS-B4) | after a partial save the store is **not** cleared; a second request resumes instead of re-fetching |
| T-MTIME (DS-B5) | local and remote both emit integer epoch seconds; `null` mtime degrades to size-only comparison without false 409s |
| T-MANIFEST-CONSISTENCY (DS-B5) | a manifest whose `chunkSize × chunkCount ≠ size` is rejected |
| T-409-BOUND (DS-B3) | a second 409 in one transfer aborts instead of looping forever |

`URL.createObjectURL` is **not** implemented in jsdom (`test-setup.ts` stubs
only `scrollIntoView`, `scrollTo`, `WebSocket`); it must be stubbed in
`beforeEach` or the save tests fail misleadingly.

### 7.5 Gates

`make check` (build + `cabal test` + `hlint` + `npm test`). Current baseline,
independently verified on `files/explorer2`: 4294 examples / 0 failures /
41 pending; 1030 frontend tests / 43 files; hlint clean.

---

## 8. Files touched

| File | Change |
|---|---|
| `src/Seal/Tools/Exec/FileExplorer.hs` | `FileStat`, `feStatFile`/`feReadRange`/`feChunkManifest`; split ceilings; fix `readBoundedFile`; remote manifest cmd |
| `src/Seal/Tools/Exec/Remote.hs` | streaming byte source (no 50 KB cap) for range reads |
| `test/Seal/Session/AgentMetaCacheSpec.hs`, `test/Seal/Session/ExecCacheSpec.hs`, `test/Seal/Tools/Exec/WorkdirFsSpec.hs`, `test/Seal/RepoDiscoverySpec.hs`, `test/Seal/TestHelpers/ApiTestHarness.hs` | add `runRemoteStream` to each existing `RemoteRunner` fake (totality under `-Werror`) |
| `src/Seal/Gateway/API.hs` | `manifest` + `chunk` routes; retire the truncating download body |
| `src/Seal/Gateway/Config.hs` | `file_download_max_bytes`, `file_download_chunk_bytes` |
| `src/Seal/Command/Serve.hs` | pass both ceilings |
| `frontend/src/hooks/useApi.ts` | manifest/chunk fetchers; replace `downloadFile` |
| `frontend/src/lib/chunkStore.ts` *(new)* | IndexedDB chunk store |
| `frontend/src/lib/chunkMath.ts` *(new)* | pure manifest-key/range helpers (T5) |
| `frontend/src/lib/modalStack.ts` *(new)* | `openModalStack` extracted from `ChatArea.tsx:572` so two modals cannot double-fire Escape (DS-B6) |
| `frontend/src/components/DownloadProgress.tsx` *(new)* | §5.7a progressbar + Cancel + interrupted state |
| `frontend/package.json` | add `fake-indexeddb` devDependency (T-RESUME/T-CANCEL cannot run without it, DS-B2) |
| `frontend/src/test-setup.ts` | `import 'fake-indexeddb/auto'` |
| `frontend/src/components/DownloadConfirmDialog.tsx` *(new)* | §5.8 dialog |
| `frontend/src/components/FilesView.tsx` | wire dialog + orchestration; drop the hardcoded 128 KiB string |
| `frontend/src/types.ts` | manifest/stat types |
| `seal-harness.cabal`, `test/Main.hs` | new modules/tests in three places |
| `test/Seal/Tools/Exec/FileExplorer*Spec.hs`, `test/Seal/Gateway/*` | §7 |

---

## 9. Out of scope (explicit, with rationale)

1. **Parallel chunk fetching** — §5.7. Throughput not measured; deferred.
2. **Signed manifests / tamper-evidence** — §6.1. Would need out-of-band key pinning.
3. **`showSaveFilePicker` direct-to-disk streaming** — §5.6. Needed if assembled blobs prove slow at multi-GB; a follow-up.
4. **Whole-file hash verification surfaced in UI** — computed for P4, not yet shown.
5. **Hard refusal of `blockedNames` paths** — §6.3 recommends warn, not block (O-1).
6. **Per-connection concurrency cap** — §6.4.
7. **Frontend CI job** — still absent; `.github/workflows/ci.yml:94` runs `cabal test` only, so vitest is local-only. Carried from the handoff's follow-up 3.
8. **Cross-reload resume as a durability feature** — §5.5a keeps IndexedDB but
   narrowed to resume-only, `blockedNames` never persisted, 24 h TTL. Dropping
   it entirely remains a one-line change if the operator says so (O-6).
9. **Rich progress UI** — §5.6 renders a chunk counter (`i` of N), which is
   free. A determinate progress bar with throughput/ETA is not in v1.

---

## 10. Open questions

- ~~**O-1**~~ — **closed** in §6.3: hard block on the data path, warning on the
  browse path, override by operator-written config.
- ~~**O-2**~~ — **closed**: the premise was false (§5.11). Warp's `setTimeout`
  does not bound application time.
- **O-3:** Default chunk size — 4 MiB proposed. Large enough to amortise an SSH
  round trip, small enough to bound memory and retry cost.
- **O-4:** Should the 256 MiB threshold be the default in `security.toml` /
  `config.toml` templates, or config-only?
- **O-5:** Retention for held chunks after an abandoned download — **24 h**
  (§5.5a, reduced from 7 days).
- **O-6 (PM-B1):** Does the operator want cross-reload resume at all? It is
  not in their words (§3.1a). Keeping it costs `chunkStore.ts` +
  `chunkMath.ts`; dropping it costs UC-3 only and makes v1 in-memory.
- **O-7 (from PM-Q1, asked in the prior gate and still unanswered):** is

---

## 11. Delivery plan — slice before building this

Accepted from the CTO review (CTO-B10 and its risk ranking). Four reviewers
have now found real defects; the direction is sound but the document has grown
past the point of easy coherence, and the highest-value fix is **smaller**
than the whole.

### 11.1 Three of the four reported defects need no chunking

§1.1 lists four independent defects. Only one requires a downloader:

| Defect | Needs chunking? | Fix size |
|---|---|---|
| 1.1.1 one ceiling feeds viewer **and** download | no | split two `Int`s |
| 1.1.2 `readBoundedFile` does `BS.readFile` then `take` | no | ~6 lines; fixes the **viewer** too |
| 1.1.3 remote 50 000-byte cap; banner lies "128 KiB" | no | formatter + effective-cap plumbing |
| 1.1.4 **a truncated file saves as if complete** | no | ~10 lines: refuse, or name it `.partial` |

1.1.4 is the operator's literal complaint ("only the first 128 KiB was
saved"). It is not a downloader problem — it is a "do not silently hand the
user a corrupt artifact" problem.

### 11.2 Slice 1 — small, off `main`, no stacked branches

Delivers **G5, SC-7, SC-8**, two of the four defects, and the entire
user-facing dialog — for roughly 20% of the work.

1. Split the ceilings (§5.1's two `Int`s).
2. Fix `readBoundedFile` (`hFileSize` + `hSeek` + bounded `hGetSome`).
3. Stop saving a silent prefix (`.partial` naming, with totals).
4. Add `feStatFile` + the `stat` route (§5.2a) + the §5.8 confirm dialog.

Slice 1 also **builds the `stat` endpoint Slice 2 depends on**, closing CTO-B2
for free.

### 11.3 Slice 2 — the downloader

Manifest + chunk routes + resume + the client chunk store, landing on a `main`
that already has split ceilings and `stat`. §5.2, §5.3a, §5.4a, §5.6 and
§7.1-§7.6 apply here.

### 11.4 Branching (CTO-B10) — verified

- `merge-base --is-ancestor origin/files/explorer files/explorer2` → **yes**
- PR **#308** `files/explorer` → `main`: **`isDraft: true`, OPEN**
- `files/explorer2` has **no PR**
- the divergence touches exactly the files this design edits

CONTRIBUTING says "branch from an up-to-date `main`" twice. Options:

| Option | Cost |
|---|---|
| **A.** Land #308 first, then branch off `main` | cleanest; costs a wait |
| **B.** Branch off `main` now, rebase once | cheapest to start; one conflict, not three |
| **C.** Stack anyway, but open a draft PR for `files/explorer2` | keeps momentum; must state merge order |

**Recommendation: B for Slice 1** (it touches `main`-level files only);
re-decide A vs C for Slice 2 once #308's shape settles.

### 11.5 Two decisions only the operator can make

- **O-6** — cross-reload resume at all? Not in the operator's words
  ("resumable" ≠ "survives a reload"). Keeping it costs an IndexedDB chunk
  store plus a 1-hour plaintext cache in the browser profile; dropping it costs
  UC-3 only and keeps v1 in memory.
- **O-7** — is remote mode actually live? §5.3, §5.4a, T11-T14 and
  T-STREAM-CAP exist **only** for remote. Evidence it is live: this branch's
  `d93a8d6` ("batch rail listings into one remote operation") exists solely
  because remote was slow. If live, the remote surface is justified; if not,
  it is a third of the design.

---

## 12. Architect finding: the manifest hash list should be deleted

The single most valuable finding of the gate, because it **removes** scope
rather than adding it. Verified against the code before accepting.

### 12.1 The argument

§5.2 already puts `X-Chunk-SHA256` on **every chunk response**. §6.1 already
concedes chunk hashes do not authenticate (the same server publishes both the
hashes and the bytes). Therefore a whole-file manifest hash list provides **no
property the per-chunk header does not already provide**, and it costs a
**second full read of the file** — over SSH, on UC-1's 900 MB, ~2× the transfer.

Resumability does not need it either. §5.2/§5.5's resume logic requires only:

```
(path, size, mtimeEpoch, chunkSize, index) + the chunks already held
```

All of which is O(1) to produce.

The entire SR-1 / SR-2 / O-2 stack exists **solely** to ship that hash list:

| Machinery | Exists only to… |
|---|---|
| §5.3a manifest paging + 413 | avoid truncating a hash list |
| §5.4a `runRemoteStream` | escape the 50 000-byte cap on the hash list |
| §5.11a NDJSON streaming | start downloading before hashing finishes |
| §5.3 LRU cache keyed `(path,size,mtime)` | avoid re-hashing |
| §6.3c semaphore + token bucket | bound the O(size) work |
| O-2 | a timeouts question about hashing |

### 12.2 Decision: delete it

**`manifest` becomes O(1) metadata only:**

```json
{ "path": "...", "size": 123456789, "mtimeEpoch": 1763035200,
  "chunkSize": 4194304, "chunkCount": 30 }
```

Per-chunk integrity comes from the `X-Chunk-SHA256` header on the response
that actually carries the bytes — which is *strictly better evidence* than a
manifest hash, because it describes the bytes in flight rather than the bytes
as they were during an earlier pass.

**Deleted:** §5.3's hashing pass, §5.3a paging and 413, §5.4a streaming runner,
§5.11a NDJSON, the manifest LRU, and §6.3c's semaphore/bucket (a stat is O(1);
there is nothing left to bound). `feChunkManifest` disappears from §5.1.

**Kept:** per-chunk SHA256 (the operator asked for it, and it still detects
corruption in transit), the stateless `size`+`mtimeEpoch` precondition, and
§6.1a's length assertions.

### 12.3 Consequence that must be written down

With no manifest hash list, **cross-chunk consistency is no longer detectable**.
Chunk 3 verified good and chunk 4 verified good does not prove they came from
the same file version. The `size`+`mtimeEpoch` precondition is the only
cross-chunk check, and the architect is right that it is a **staleness** check,
not content identity:

- **TOCTOU**: the re-stat happens before the read, so a concurrent write yields
  a torn chunk.
- **Same-size, same-second rewrite is undetectable**, because sub-second mtime
  is deliberately truncated (§6.3g). A secret rotated in place
  (`install -m 600`) can mix old and new bytes while every stat "matches".
- Degrading to `mtimeEpoch: null` makes this **weaker**, not safer.

Mitigation: re-stat **after** the read and compare before serving, which turns
a silent mix into a 409. Residual risk is stated, not eliminated.

### 12.4 Separate pre-existing bug found while verifying AR-B4

`setTimeout` takes **seconds** (Warp `Settings.hs:70-71`). `Server.hs:347` is
`setTimeout 120_000`, which is **~33 hours**, not 120 seconds — and the comment
directly above it (`Server.hs:341-343`) says "a connection silent for two
minutes is genuinely dead". Off by 1000×.

This is **not** introduced by this design and does not block it, but it is a
real defect worth its own issue: the slowloris bound is effectively disabled.
Flagged rather than fixed here (different branch, different scope).

### 12.5 What this does to the size of the work

Deleting the manifest apparatus removes roughly SR-1, SR-2, §5.4a, §5.11a and
§6.3c — the majority of the backend complexity, and the hardest code (a rank-2
streaming runner that would not have compiled). Combined with §11's slicing,
the revised shape is:

| Slice | Content |
|---|---|
| **1** (§11.2) | ceilings split, `readBoundedFile` fix, `.partial` naming, `stat` route, confirm dialog |
| **2** | chunk route with per-chunk `X-Chunk-SHA256`, resume via `(path,size,mtime,chunkSize,index)`, client chunk store |

Estimated effect: Slice 2 loses its hardest backend component and its largest
test surface. I would not have found this without the gate; it contradicts the
reasoning I used to write §5.3.
