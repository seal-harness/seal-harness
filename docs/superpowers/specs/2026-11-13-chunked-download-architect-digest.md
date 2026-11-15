# Architect Review Digest — Chunked Download (Rev 2)

The full design is `2026-11-13-chunked-resumable-download-design.md` (1150 lines).
This digest exists because the design outstripped a single-pass read. **Answer on
the six technical questions below**; consult the full doc only where needed.

## The six crux questions

**Q1 — Handle shape.** Proposed extension to `FileExplorerHandle`
(`src/Seal/Tools/Exec/FileExplorer.hs:109-125`):

```haskell
, feStatFile      :: FilePath -> IO (Either FileExplorerErr FileStat)
, feReadRange     :: FilePath -> Integer -> Int -> IO (Either FileExplorerErr ByteString)
, feChunkManifest :: FilePath -> Int -> IO (Either FileExplorerErr [Text])
```

Construction splits one Int into two: `readCeiling` (viewer, unchanged
semantics) and `downloadChunkBytes`. Justification: `mkLocalFileExplorer`
(`:215-219`) today feeds ONE `ceilingBytes` to BOTH `feReadFile` and
`feReadFileBytes`. Raising the download ceiling to 256 MiB would otherwise
raise the viewer ceiling too, and `localReadFile` (`:356-358`) builds
`length (T.lines content)` — a boxed list of millions of elements.

*Is this the right abstraction? Is a 3-method addition the right cut, or should
range reads live behind a separate `FileSource` handle?*

**Q2 — Streaming runner.** New method:

```haskell
, runRemoteStream :: [String] -> (Handle -> IO r) -> IO (Either ExecError r)
```

`runRemoteBytes` caps output at a hardcoded 50_000 (`Remote.hs:309`) and
`readBounded` signals truncation by closing the pipe (`Local.hs:292-303`).
`runRemoteStream` reuses the `withManagedProcess` shape from `runRealBytes`
(`Remote.hs:293-320`) minus the cap, handing the caller the child's stdout
`Handle`.

*Does handing a raw `Handle` to a callback fit this codebase's Handle pattern,
or does it leak too much? Six existing `RemoteRunner` fakes must gain the field
for totality under `-Werror` — is that acceptable churn?*

**Q3 — Constant memory.** Chunk serving uses `responseStream` + `conduit`
(both already deps: `seal-harness.cabal` library stanza). Local: `hSeek` then
bounded `BS.hGetSome` in 64 KiB windows. No lazy IO.

*Is `responseStream` correct here, and does anything in the existing gateway
layer prevent a streamed body (e.g. middleware that buffers, or the
`sameOriginVerdict` guard at `API.hs:214-216`)?*

**Q4 — Manifest is O(size).** Hashing the whole file. Resolved to streamed
NDJSON (`§5.11a`) so first byte arrives early, plus a semaphore (2), a token
bucket, and manifest paging (`§5.3a`: 769 chunks fit in 50_000 bytes = 3.00 GiB
before truncation).

*A paged + streamed manifest with in-memory LRU caching keyed on
`(path,size,mtime)` — is this over-engineered, and is there a simpler shape?
Note `Seal/Session/ExecCache.hs` already has a TTL-cache precedent
(`defaultDiscoveryTTL = 60`).*

**Q5 — Stateless precondition.** Every chunk request carries `size` and
`mtimeEpoch` (integer Unix seconds; local truncates sub-second, remote is
already seconds). Server re-stats and compares; mismatch is 409. No session,
no token, no server memory.

*Is stateless precondition sound, or is there a race that makes it unsound in a
way `size`-only degradation (`mtimeEpoch: null`) does not fix?*

**Q6 — Warp timeout.** `settings = setTimeout 120_000` (`Server.hs:347`),
per-request. Chunk responses are small, so chunked transfer sidesteps it. But a
manifest for a big remote file can exceed 120 s.

*Does `setTimeout` actually bound a streaming response body per-read or
per-request-total? If total, does the NDJSON stream die at 120 s regardless of
progress?*

## Constraints from the repo rules

- No lazy IO. No partial functions. `-Wall -Werror`.
- Opcode modules never import `System.Process`/`System.Directory`/`System.Posix`
  — but this is a **gateway route**, not an opcode, so it uses the
  `FileExplorerHandle` capability, not `UntrustedIO`.
- No shell-wrapping in Trusted/Audited opcodes. The remote manifest command is
  constructed server-side with `shellQuote`, matching `remoteReadCmd`
  (`FileExplorer.hs:588-596`).

## Output

Verdict `APPROVED` or `NEEDS_REVISION`, with numbered blockers that each cite
`file:line` and name the specific section to change. Be adversarial and
concise — do not restate the design back.
