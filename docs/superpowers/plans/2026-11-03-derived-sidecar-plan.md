# Derived Sidecar — Implementation Plan (PR 0 of the session-dispositions epic)

**Date**: 2026-11-03 · **Code branch**: `perf/derived-sidecar` (base `main`, docs excluded) · **Docs branch**: `docs/session-dispositions-spec` · **Design**: `docs/superpowers/specs/2026-11-03-tab-dispositions-design.md` §5.11, §7 (I16/I17), §4 Metric 4, §8 (W0a–W0d) · **Plan-review**: round 4

## Scope

Ship `<sessionDir>/derived.json` so the sidebar listing stops re-parsing
`entries.jsonl` for every session on every poll. **No wire change, no UI change,
no behaviour change.**

Out of scope: dispositions (PR 1–3), SQLite (§13), the append-time hook
(design §11.9 — deferred with a verified rationale).

## What the four gate rounds changed

Round 1: two scalars with different source files; mtime validity; `writeMetaFileAtomic`
private/monomorphic; invented CLI surface; no bytes instrumentation; `entry_count`
vacuous. Round 2: formatter in `exe/` unimportable from the test-suite; read-then-stat
race; append hook unusable at the append site; `never throws` vs a `failed` counter.
Round 3: contradictory `reindex` arithmetic; vacuous reindex assertion; wrong-function
test citation; missing edge cases; unbounded Metric 4 gate. Round 4 (this one):
**`showIso` import cycle** (fixed by moving the formatter into `Derived`), unreachable
`failed` counter, `entries.jsonl`-absent vs `skipped`, no concurrency test, bench
hard-coding the `derived.json` literal.

## Work units — strictly sequential (all edit `seal-harness.cabal`)

### WU-0 — path helper + `bench-lists` executable

- **Files**: `src/Seal/Config/Paths.hs`, `test/Seal/Config/PathsSpec.hs`,
  `exe/bench-lists/Main.hs` (new), `seal-harness.cabal`, `Makefile`.
- **Why the path helper is here**: the bench must sum `derived.json` sizes, and
  WU-0 has no dependencies — so the path function lands first rather than being
  duplicated as a string literal in `exe/`.
- **cabal stanza** (mirrors `executable seal`, cabal:353-360):
  ```
  executable bench-lists
    import:           settings
    hs-source-dirs:   exe/bench-lists
    main-is:          Main.hs
    build-depends:    base, seal-harness, seal-gateway-types,
                      containers, directory, filepath, time, optparse-applicative
  ```
  (`aeson` not needed — session ids come from `listSessions`, not the snapshot's
  `[Value]`.)
- **DoD**:
  1. `sessionDerivedPath :: SealPaths -> SessionId -> FilePath` returns
     `<sessionDir>/derived.json`; `PathsSpec` covers it (mirrors
     `sessionMetaPath`, `Paths.hs:164`).
  2. `bench-lists [--iterations N]` (default 3) calls the production
     `buildListsSnapshot` (`ListsSnapshot.hs:41`) with `newTabsHandle`
     (`Tabs.hs:43`) and `Set.empty`, after **one unmeasured warm-up** (the run
     heals sidecars, so iteration 1 is cold). Prints: session count, the cold
     iteration's ms **separately**, and the **median** of the measured
     iterations.
  3. Prints `Σ size(entries.jsonl)` and `Σ size(derived.json)` via
     `listSessions <> listArchivedSessions` and `sessionDerivedPath`, labelled
     `modelled bytes (file sizes, not syscall accounting)`; missing files = 0.
  4. Paths via `getSealPaths` (`Paths.hs:73-85`), which honours `SEAL_HOME` — so
     the zero-session case is exercised with `SEAL_HOME=$(mktemp -d)`: prints
     `sessions: 0`, exits 0.
  5. `make bench-lists` = `$(NIX) cabal run -v0 bench-lists -- $(ARGS)` (pattern
     `Makefile:41`; `NIX` at `Makefile:8`). Precondition, same as `run:`:
     `frontend/dist` must exist, so run it after `make build` on a clean tree.
  6. `make lint` extended to `hlint src/ test/ exe/`.
  7. `cabal build all` green.
- **Deps**: none.

### WU-1 — `Seal.Session.Derived` (pure core + writer + the one formatter)

- **Files**: `src/Seal/Session/Derived.hs` (new),
  `test/Seal/Session/DerivedSpec.hs` (new), `seal-harness.cabal` (library
  `exposed-modules:` = `Seal.Session.Derived`; test-suite `other-modules:` =
  `Seal.Session.DerivedSpec`, **the spec not the library module**), `test/Main.hs`.
- **API**:
  ```haskell
  data DerivedMeta = DerivedMeta
    { dmVersion           :: !Int
    , dmLastUserMessageAt :: !(Maybe Text)
    , dmEntriesBytes      :: !Int64
    } deriving stock (Eq, Show)

  renderIso      :: UTCTime -> Text          -- "%Y-%m-%dT%H:%M:%S%3QZ"
  readDerived    :: SealPaths -> SessionId -> IO (Maybe DerivedMeta)
  writeDerived   :: SealPaths -> SessionId -> DerivedMeta -> IO Bool  -- False, never throws
  entriesSize    :: SealPaths -> SessionId -> IO (Maybe Int64)
  derivedIsFresh :: SealPaths -> SessionId -> IO Bool
  computeDerived :: SealPaths -> SessionId -> IO (Maybe DerivedMeta)
  ```
  `computeDerived` is the **single producer**: `stat → read → stat`, `Nothing`
  when the sizes disagree or `entries.jsonl` is absent. Both WU-2 and WU-3 call
  it, so the parse and the race rule exist once.
- **The formatter lives here to avoid an import cycle.** `showIso`
  (`Transcript.hs:902-904`) cannot be imported by `Derived`, because `Transcript`
  imports `Derived`. So `Derived` owns `renderIso` and WU-2 changes
  `showIso = renderIso` (a one-line delegation) — one formatter, one direction of
  dependency. The I16 identity test is what proves the two paths agree.
- **DoD**:
  1. JSON is exactly
     `{"version":1,"last_user_message_at":…,"entries_bytes":…}`, with the
     timestamp carrying **milliseconds** (`renderIso`), version written as `1`.
  2. `readDerived` → `Nothing`, never an exception, for: missing file, malformed
     JSON, non-object value, and `version /= 1` (including a future `version: 2`,
     which a heal then overwrites as `version: 1`).
  3. `writeDerived`: unique temp via `openBinaryTempFile` (a fixed `.tmp` name
     races — `Store.hs:125-139`), explicit `setFileMode tmp 0o600`
     (`openBinaryTempFile` alone is `0600 & ~umask`; `unix` is already a dep),
     `renameFile`. Returns `False` and leaves **no** temp file when the session
     dir is absent, **or when the rename fails** (test: pre-create `derived.json`
     as a *directory*) — the enumerable variant, asserted with `listDirectory`.
     Never creates a directory; never throws.
  4. `entriesSize`: `Nothing` when `entries.jsonl` is absent (never
     `getFileSize`), `Just 0` for a zero-byte file, `Just n` otherwise.
  5. `derivedIsFresh` = sidecar present ∧ version ok ∧ `dmEntriesBytes ==
     entriesSize`; `False` when `entries.jsonl` is absent, on **every** mismatch
     (smaller and larger), and when `dmEntriesBytes` is negative.
  6. `computeDerived` → `Nothing` when `entries.jsonl` is absent or the pre/post
     sizes disagree; otherwise the freshly parsed value with the agreed size.
  7. `renderIso` renders `2026-07-01T12:00:05Z` as
     `"2026-07-01T12:00:05.000Z"` — the exact string `ApiSpec.hs:1089` pins.
  8. `DerivedSpec` covers, explicitly: DoD 2's four cases; DoD 3's absent-dir and
     rename-failure cases plus `0o600` via `getFileMode`; DoD 4's `Nothing` /
     `Just 0`; DoD 5's full matrix (absent, smaller, larger, negative); DoD 6's
     disagreement path; **and DoD 3 under concurrency** — 20 concurrent
     `writeDerived` calls for one session via `async` leave a decodable file and
     no temp files.
  9. QuickCheck (bounded): `decode (encode m) == Right m`; decoding arbitrarily
     mutated bytes never throws.
 10. No partial functions; `-Wall -Werror`; hlint clean.
- **Deps**: WU-0.

### WU-2 — read path

- **Files**: `src/Seal/Gateway/Transcript.hs` (`lastUserMessageAtFast`,
  `lastRequestTs`, `showIso` only), `test/Seal/Gateway/TranscriptSpec.hs`.
  *(No new test module: I16's two levels are assertable from `TranscriptSpec`,
  which can import `Seal.Gateway.ListsSnapshot` — an exposed library module — so
  no extra cabal or `test/Main.hs` wiring.)*
- **DoD**:
  1. `showIso = renderIso` (delegation) — one formatter in the codebase.
  2. Fresh sidecar ⇒ return the cached value **without parsing `entries.jsonl`**,
     proven by overwriting `entries.jsonl` with unparseable bytes of the *same
     length* and still getting the cached value.
  3. Miss / stale ⇒ `computeDerived`, then `writeDerived` when it yields a value;
     return the computed value regardless of the write's success.
  4. **I17**: appending to `entries.jsonl` (changing its size) without touching
     the sidecar ⇒ the new value is returned and the sidecar is rewritten.
  5. **I16** at both levels: with every `derived.json` deleted, (a)
     `sessionInfoJsonWithSnippet` output is byte-identical for every session and
     (b) `buildListsSnapshot` JSON is byte-identical, versus a warm run.
  6. **Corrupt sidecar still lists**: a session whose `derived.json` is garbage
     or `version: 99` appears in the listing with the correct
     `lastUserMessageAt`.
  7. **Absent `entries.jsonl`**: returns `Nothing`, writes no sidecar, creates no
     directory. This needs its **own** direct test — the
     `/nonexistent-seal-test` case at `TranscriptSpec.hs:719` belongs to the
     `firstUserMessageSnippetFast` block, and `lastUserMessageAtFast` has no
     direct test today.
  8. **Zero-byte `entries.jsonl`**: returns `Nothing`, writes
     `{"…":null,"entries_bytes":0}`, and a second call trusts it.
  9. **`entries.jsonl` deleted under a live sidecar**: the sidecar is ignored,
     `Nothing` is returned, the orphan file is **left in place** (the read path
     never deletes), no exception escapes.
 10. `firstUserMessageSnippetFast` is **unchanged**; its existing tests are
     untouched.
 11. `-Wall -Werror`; hlint clean; `make check` green.
- **Deps**: WU-1.

### WU-3 — `/session reindex`

- **Files**: `src/Seal/Command/Session.hs`, `test/Seal/Command/SessionSpec.hs`.
- **DoD**:
  1. Processes `listSessions <> listArchivedSessions` (top-level, non-child —
     `Store.hs:146,168`) via `computeDerived` + `writeDerived`; never
     `lastUserMessageAtFast` (that would double-write).
  2. Prints exactly `written: N  skipped: M  failed: K`:
     **skipped** = already fresh **or** `entries.jsonl` absent;
     **failed** = a value was computed but `writeDerived` returned `False`
     (reachable deterministically by pre-creating `derived.json` as a
     *directory*, which works even as root);
     **written** = the rest.
  3. **Values are correct against an independent oracle**: the slow
     `lastUserMessageAt` (which reconstructs from the transcript and never reads
     the sidecar) equals both the reindex-written value and what
     `lastUserMessageAtFast` returns. A bytes-correct but `null`-timestamp
     sidecar fails this.
  4. **Idempotent**, with an explicit precondition: given N sessions that all
     have a non-empty `entries.jsonl` and no sidecar, run 1 reports
     `written: N skipped: 0 failed: 0`; run 2 reports
     `written: 0 skipped: N failed: 0`. Sessions with no `entries.jsonl` count as
     `skipped` and are excluded from this assertion.
  5. No flag — it always processes everything (the design's `--all` is gone).
  6. Missing sessions root ⇒ `written: 0 skipped: 0 failed: 0`, no exception.
  7. Exercised through `SessionSpec`'s `runSess` hook
     (`test/Seal/Command/SessionSpec.hs:53-58`), asserting the printed line.
  8. `-Wall -Werror`; hlint clean.
- **Deps**: WU-2.

## Dependency graph

```
WU-0 → WU-1 → WU-2 → WU-3
```

## API contract

No HTTP/WS change.

```
exe/bench-lists        # separate executable, NOT a `seal` subcommand
make bench-lists       # $(NIX) cabal run -v0 bench-lists -- $(ARGS)
/session reindex       # slash command, GroupSession, InteractiveOnly
```

## Security considerations

- No trust boundary crossed: no client/model input, no opcode.
- Writes land in `<state>/sessions/<sid>/derived.json` — the same directory as
  `session.json`, never in the agent-immutable `~/.seal/` members AGENTS.md
  enumerates. Writer is the gateway process.
- Mode `0o600` (set explicitly); the file holds a derived timestamp only.
- No surface prints transcript content; `reindex` prints counts, and its DoD-3
  test compares values without printing them.
- Never authoritative: deleting all sidecars yields byte-identical output (I16);
  a tampered sidecar is trusted only when its byte count matches the real file.
- Reverting the code leaves inert `derived.json` files that nothing else reads;
  they persist in session dirs (noted, not cleaned up automatically).

## Risks

| Risk | Mitigation |
|---|---|
| Sidecar disagrees with `entries.jsonl` | size key; any append changes the size (I17) |
| Append lands during the read | `computeDerived`'s `stat → read → stat` |
| Concurrent heals for one session | unique temp + atomic rename (tested with 20× `async`) |
| Corrupt / future-version sidecar | treated as absent; heal rewrites `version: 1` |
| Heal write throws in a read path | `writeDerived` returns `Bool`, never throws, never creates dirs |
| Bench mutates what it measures | one unmeasured warm-up; cold reported separately |
| Metric 4 not achieved | **gate on a named statistic**: median of the warm iterations, post vs the baseline recorded in the PR body. Cold does not gate. If <5×, the PR is not opened and findings are escalated. |

## Files touched (code branch only)

```
exe/bench-lists/Main.hs              (new)
src/Seal/Session/Derived.hs          (new)
src/Seal/Config/Paths.hs
src/Seal/Gateway/Transcript.hs
src/Seal/Command/Session.hs
Makefile
seal-harness.cabal
test/Main.hs
test/Seal/Session/DerivedSpec.hs     (new)
test/Seal/Config/PathsSpec.hs
test/Seal/Gateway/TranscriptSpec.hs
test/Seal/Command/SessionSpec.hs
```

Docs ship on `docs/session-dispositions-spec` first, so this PR is one logical
change.

## Open item (operator action)

AGENTS.md rule 2 makes issues human-authored, so the epic's tracking issue is not
created by the agent; the PR body will carry `Closes #NN` once the operator files
it. Design §12 Q-E records the same prerequisite. Explicit, not silent.

## Human checkpoints

- **After WU-0**: operator pastes `make bench-lists` from the real store
  (`SEAL_HOME=~/.seal`); the sandbox cannot read `~/.seal`, so this is the only
  true baseline. **Pause.**
- **After WU-3**: report before/after against the Metric 4 gate, then request PR
  approval.

## Verification standard

`make check` = `build` (`cabal build all` + `npm run build`), `test`
(`cabal test`), `lint` (`hlint src/ test/ exe/`). No `--no-verify`, no skipped
tests. Per WU: IMPLEMENT → VALIDATE (orchestrator runs the gates) → ADVERSARIAL
REVIEW (fresh reviewer each attempt, max 3) → COMMIT.
