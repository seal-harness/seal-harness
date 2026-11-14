# Handoff: File explorer redesign 3 — chunked download design gate complete, no code written

**Date**: 2026-11-13 · **Branch**: `files/explorer2` (descends from `files/explorer`, PR **#308**, still DRAFT)
**PR**: **none opened** — the operator asked for a push without a PR. Do not open one.

---

## 0. TL;DR

**No code was written.** This session produced a design document, ran it through
the 5-agent Design Review Gate, and applied the revisions. The gate did its job:
it found real defects and, more usefully, **shrank the work**.

| Fact | State |
|---|---|
| Branch | `files/explorer2`, tree was clean and green at session start |
| Code changed this session | **none** |
| Docs added | 3 files under `docs/superpowers/specs/` |
| Gate verdicts | **5 of 5 NEEDS_REVISION** (PM 7, Designer 7, Security 8, CTO 10, Architect 7 blockers) |
| Baseline gates (verified, pre-session) | `cabal test` 4294/0 fail/41 pending · `hlint` no hints · frontend 1030 tests/43 files · both builds clean |

**Next step is a decision, not a task** — see §5. Three operator decisions block
all further work.

---

## 1. What was asked for

The operator reported: downloading a larger file shows
`Last download was truncated — only the first 128 KiB was saved`. They asked for
a default limit of 256 MB, a configurable limit, and a dialog offering
**cancel / download partial / download full anyway**.

Then they escalated: *"we need to build our own robust chunked, resumable,
download functionality"* with five requirements:

1. Constant memory on the server — no Haskell lazy IO
2. Split the file into appropriately sized chunks
3. Chunk SHA256 hashes for integrity checks
4. Resumable without re-downloading already-downloaded chunks
5. Cancelable

Both messages are quoted verbatim in the design doc §3.1a.

---

## 2. The design document

`docs/superpowers/specs/2026-11-13-chunked-resumable-download-design.md`
(~1390 lines). Sections worth reading in this order:

| § | What it is | Why you care |
|---|---|---|
| §1.1 | The four real defects, with `file:line` | The starting point |
| §6.0a | Agent-reachable exfiltration path | **Most serious finding of the session** |
| §11 | Delivery plan — slice the work | **Read this before doing anything else** |
| §12 | Architect finding: delete the manifest hash list | **Shrank the design by ~a third** |
| §0 | Revision log, all 39 blockers and resolutions | Audit trail |

`docs/superpowers/specs/2026-11-13-chunked-download-architect-digest.md` is the
6-question digest used to re-run the architect after its first pass timed out.
Keep it — it is the template for reviewing an oversized design doc.

---

## 3. Findings that survived verification

Everything below was checked against the code, not taken from a review.

### 3.1 The four defects

1. **One ceiling feeds viewer *and* download.** `mkLocalFileExplorer`
   (`FileExplorer.hs:215-219`) passes one `ceilingBytes` to both `feReadFile`
   and `feReadFileBytes`. Raising the download limit also raises the viewer,
   and `localReadFile` builds `length (T.lines content)` (`:356-358`) — at
   256 MiB that is a boxed list of millions of elements inside a JSON response.
2. **`readBoundedFile` reads the whole file to return a prefix.**
   `FileExplorer.hs:226-233` is `BS.readFile path` then `BS.take maxBytes`. A
   2 GB file allocates 2 GB to return 128 KB. Ceiling protects the response,
   not the process.
3. **Remote is tighter and the UI lies.** `runRemoteBytes` caps at a hardcoded
   `50_000` (`Remote.hs:309`); `remoteReadFileBytes` takes the tighter of the
   two, so remote is **48.8 KiB**. The banner hardcodes the string "128 KiB"
   (`FilesView.tsx:276`) and is wrong in remote mode.
4. **A truncated file saves as if complete.** `downloadFile`
   (`useApi.ts:1853-1868`) calls `a.click()` regardless of `truncated`.

**There is a banner** (`FilesView.tsx:274-278`) — an earlier claim in this
session that there was none was wrong and was corrected. The defect is that the
partial file is still written, not that the user is unwarned.

### 3.2 The security finding

`sanitizeHref` (`lib/markdown.ts:63-69`) passes any URL starting with `/` and
`MarkdownView.tsx:41-43` renders it as `<a target="_blank">`. A click from the
app origin to `/api/files/download?path=…` is **same-site**, so the
`SameSite=Strict` cookie is sent and the request is authorized. **An agent can
emit a markdown link and get bytes with one human click** — no opcode, no
`SafePath`, no audit. No opcode has this path; `mkSafePath` blocks
`blockedNames`. The route is agent-reachable *by proxy*.

Pre-existing, not introduced by the design, but chunking makes it bulk and
quiet. Mitigations in §6.0a: hard-block blocked paths (§6.3), block
`/api/files/download*` hrefs (`T-LINK-BLOCKED`), audit line per download.

### 3.3 Authentication is not "passkey-gated"

`AccessControl.hs:295-315` authorizes on **any** of: a valid `seal_session`
cookie; the **per-run service bearer token** (`hasServiceToken`, held by chat
channels at `Serve.hs:743,804`); `AccessUnconfigured` with the same token; or
`AccessOpen`, which is `AuthAllow` **unconditionally — no auth at all**. So
`mode = "none"` + wildcard bind is unauthenticated arbitrary-file read on the
LAN. §6.3e records the real set.

### 3.4 Pre-existing bug found en route (not ours, not fixed)

`setTimeout` takes **seconds** (Warp `Settings.hs:70-71`). `Server.hs:347` is
`setTimeout 120_000` = **~33 hours**, and the comment above it (`:341-343`)
says "a connection silent for two minutes is genuinely dead". Off by 1000×.
The slowloris bound is effectively disabled. **Worth its own issue.**

### 3.5 Manifest hash list deleted (architect, §12)

§5.2 already puts `X-Chunk-SHA256` on every chunk response; §6.1 already
concedes hashes don't authenticate. A whole-file manifest hash list therefore
buys **no property** the per-chunk header lacks, and costs a **second full read**
of the file (~2× transfer on a 900 MB remote file). Deleting it removed
paging + 413, `runRemoteStream`, NDJSON streaming, the LRU, the
semaphore/token bucket, and O-2 — the majority of the backend complexity.

`manifest` is now O(1): `{path, size, mtimeEpoch, chunkSize, chunkCount}`.

**Consequence written down:** cross-chunk consistency is undetectable. Chunk 3
good + chunk 4 good ≠ same file version. `size`+`mtimeEpoch` is a *staleness*
check, and because sub-second mtime is truncated, a same-size same-second
rewrite can mix old and new bytes. Mitigation: re-stat **after** the read.

---

## 4. Where the design landed

| Slice | Content | Notes |
|---|---|---|
| **1** | ceilings split; `readBoundedFile` fix; `.partial` naming; `stat` route; confirm dialog | ~20% of the work, **off `main`**, fixes the operator's literal complaint, and builds the `stat` endpoint Slice 2 needs |
| **2** | chunk route + per-chunk `X-Chunk-SHA256`; resume via `(path, size, mtime, chunkSize, index)`; client chunk store | hardest backend component now removed (§12) |

Three of the four defects in §1.1 need **no chunking at all**.

---

## 5. BLOCKING — three operator decisions

Nothing should be built until these are answered. All three change the file
list and the test surface.

1. **Slice 1 first, or the full downloader?** Recommendation: **Slice 1**.
2. **O-7 — is remote mode actually live?** §5.3, §5.4a, T11–T14 exist only for
   SSH mode. Evidence it *is* live: this branch's own `d93a8d6` ("batch rail
   listings into one remote operation") exists solely because remote was slow.
   If remote is hypothetical, a third of what remains is unjustified.
3. **O-6 — cross-reload resume at all?** Not in the operator's words
   ("resumable" ≠ "survives a reload"). Keeping it costs an IndexedDB chunk
   store plus a 1-hour plaintext cache in the browser profile (§5.5a, §6.3d).
   Dropping it costs UC-3 only and keeps v1 in memory.

Plus **branching** (CTO-B10, §11.4). Verified: PR **#308** `files/explorer` →
`main` is `isDraft: true`; `files/explorer2` has **no PR**; `explorer2`
descends from `explorer`; the divergence touches exactly the files the design
edits. CONTRIBUTING says "branch from an up-to-date `main`" twice.

| Option | Cost |
|---|---|
| **A.** Land #308, then branch off `main` | cleanest, costs a wait |
| **B.** Branch off `main` now, rebase once | cheapest; one conflict not three — **recommended for Slice 1** |
| **C.** Stack, but open a draft PR for `files/explorer2` first | keeps momentum; must state merge order |

---

## 6. Traps that cost real time

**Do not run two `cabal` commands into the same `dist-newstyle` concurrently.**
This session did, and the builds raced on the same `.o` files:
`renameFile: ... does not exist`. One log also showed a spurious
`Seal.Phase7aSpec` WebSocket `ConnectionClosed` failure after 10.6 s. Both were
artifacts of the race. A clean uncontended run: **4294 examples, 0 failures,
41 pending**. If a gate looks red, check for a concurrent build before
believing it.

**Never pipe `cabal`/`hlint` through `head`.** RTS sets SIGPIPE to `SIG_IGN`
and the writer hangs. Redirect to a file, then read the file.

**Shallow clone.** `git log` shows only the handoff commit until you
`git fetch --unshallow`. Verify branch relationships with
`merge-base --is-ancestor`, not by reading `git log`.

**The 5-agent gate needs a size budget.** The architect **timed out** on a
1150-line doc. Fix: write a 6-question digest
(`2026-11-13-chunked-download-architect-digest.md`) and instruct the reviewer to
answer only those, consulting specific sections on demand. That worked.

**Agent output mangling.** `rg` output rendered matched identifiers as `n`
(`export interface n {`). Use `grep` for anything you need to quote.

**jsdom lacks `indexedDB`** (`node -e "typeof indexedDB"` → `undefined`) and
`fake-indexeddb` is not a dependency. `URL.createObjectURL` is stubbed locally
in `FilesView.test.tsx:164-167`, not in `test-setup.ts`. Present and safe:
`crypto.subtle`, `structuredClone`, `Blob.arrayBuffer`.

---

## 7. Verified environment facts

| Fact | Verified by |
|---|---|
| Warp is **3.4.13.1** | `dist-newstyle/cache/plan.json` |
| `setTimeout` is seconds, not ms | Warp haddock + `Settings.hs:70-71` |
| `RankNTypes` is **not** a default extension | `seal-harness.cabal:27-31` |
| Route plumbing lives in `src-gateway-types/` | `Seal/Gateway/Types/Route.hs` (27 KB) |
| `expectedRouteCount = 73` | `ApiRouteSpec.hs:19` — a hardcoded count, red on the first new route |
| `openApiMeta` needs one arm per route | `OpenApi.hs` — `-Wincomplete-patterns` under `-Werror` |
| `ApiFilesSpec.hs:156` asserts `X-Truncated: false` | retired by the design |
| `[gateway]` config lives in `security.toml` | `Security.hs:733` — boot-only, agent-immutable |
| No streaming precedent in the gateway | no `responseStream`/`responseFile` in `src/` |

Adding a route touches **four** files: `Types/Route.hs`, `OpenApi.hs`,
`ApiRouteSpec.hs`, plus the handler. This is the second-most-contended merge
point in the repo after `cabal`/`Main.hs`.

---

## 8. If you resume

1. Read §5 and get the three decisions answered. Do not start coding first.
2. Read §11 (slicing) and §12 (what was deleted) — building the original
   design would be doing work the gate removed.
3. If Slice 1: branch **off `main`**, TDD, `make check` green.
4. If you write a plan, put it in `docs/superpowers/plans/` and run the **Plan
   Review Gate** before implementation (3 reviewers, all must PASS).
5. Push with `BIN_EXEC git`, never `SHELL_EXEC` — only `BIN_EXEC` gets vault
   credential injection. `gh` likewise, and `gh` has no `-C` flag: use the
   `cwd` parameter.
6. No PR unless the operator asks. Current intent is to fold into the
   `files/explorer` PR eventually.
