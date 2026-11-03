# Derived Sidecar — Implementation Plan (PR 0 of the session-dispositions epic)

**Date**: 2026-11-03 · **Code branch**: `perf/derived-sidecar` (base: `main`, **docs excluded**) · **Docs branch**: `docs/session-dispositions-spec` · **Design**: `docs/superpowers/specs/2026-11-03-tab-dispositions-design.md` §5.11, §7 (I16/I17), §4 Metric 4 · **Plan-review**: round 3 (rounds 1–2 = 3× FAIL each)

## Scope

Ship `<sessionDir>/derived.json` so the sidebar listing stops re-parsing
`entries.jsonl` for every session on every poll. **No wire change, no UI change,
no behaviour change.**

Out of scope: dispositions (PR 1–3), SQLite (§13), and the append-time hook (§11.9
of the design — deferred with a verified rationale, see §Revision history).

## Revision history — what the gates changed

**Round 1 → 2** (3× FAIL): caching two scalars with different source files;
mtime validity (racy); `writeMetaFileAtomic` private + `SessionMeta`-monomorphic;
the `seal session …` CLI surface doesn't exist; no bytes instrumentation; I16
covered only half the routes; `entry_count` vacuous.

**Round 2 → 3** (3× FAIL): (a) a formatter in `exe/` is unimportable from the
test-suite (cabal test-suite sees `hs-source-dirs: test` only) → **the formatter
is not unit-tested**; (b) read-then-stat can record a newer size with an older
value → **stat-before-read, stat-after-read, write only if unchanged**;
(c) the append hook has no usable interface at the append site and cannot know
the last request timestamp → **dropped from PR 0** and moved to design §11.9;
(d) `writeDerived` "never throws" vs `reindex`'s `failed` counter →
`writeDerived :: … -> IO Bool`; (e) absent vs zero-byte `entries.jsonl` →
explicit rule; (f) reindex output terms defined; (g) bench mutates the store it
measures → warm-up + separate cold iteration; (h) concurrent writes → unique
temp via `openBinaryTempFile`; (i) WU-0/WU-1 both edit `seal-harness.cabal` and
`test/Main.hs` → **WU-1 depends on WU-0**; (j) docs bundled with code → **docs
ship on their own branch first**; (k) design doc still said mtime / `--all` /
`§5.12` → amended.

Work units are strictly **sequential** — every one of them edits
`seal-harness.cabal` (a documented merge hotspot, AGENTS.md).

## Work units

Work units are strictly **sequential** — every one of them edits
`seal-harness.cabal` (a documented merge hotspot, AGENTS.md).

### WU-0 — `bench-lists` executable (the baseline instrument)

- **Files**: `exe/bench-lists/Main.hs` (new), `seal-harness.cabal`, `Makefile`.
- **cabal stanza** (explicit, mirroring `executable seal` at cabal:353-360):
  ```
  executable bench-lists
    import:           settings
    hs-source-dirs:   exe/bench-lists
    main-is:          Main.hs
    build-depends:    base, seal-harness, seal-gateway-types,
                      containers, directory, filepath, time, optparse-applicative
  ```
  (`aeson` is **not** needed: session ids for the byte sums come from
  `listSessions`/`listArchivedSessions`, not from the snapshot's `[Value]`.)
- **DoD**:
  1. `bench-lists [--iterations N]` (default 3) calls the production
     `buildListsSnapshot` (`ListsSnapshot.hs:41`) with `newTabsHandle`
     (`Tabs.hs:43`) and `Set.empty`, after **one unmeasured warm-up** iteration
     (the run heals sidecars, so iteration 1 is cold). Prints: session count,
     the cold iteration's ms **separately**, and the **median** of the measured
     iterations.
  2. Prints modelled bytes: `Σ size(entries.jsonl)` and `Σ size(derived.json)`
     sourced from `listSessions <> listArchivedSessions`, labelled
     `modelled bytes (file sizes, not syscall accounting)`; missing files count
     as 0.
  3. Resolves paths via `getSealPaths` (`Paths.hs:73-85`), which honours
     `SEAL_HOME` — so the zero-session case is exercised by running with
     `SEAL_HOME=$(mktemp -d)`: prints `sessions: 0`, exits 0. (This is how the
     sandbox and CI can run it without touching `~/.seal`.)
  4. `make bench-lists` = `$(NIX) cabal run -v0 bench-lists -- $(ARGS)`
     (`Makefile:8`). Documented precondition, same as the existing `run:`
     target: `frontend/dist` must exist, so `make bench-lists` is run **after**
     `make build` on a clean tree.
  5. `make lint` extended to `hlint src/ test/ exe/` so new `exe/` code is inside
     the gate.
  6. `cabal build all` green.
- **Deps**: none.

### WU-1 — `Seal.Session.Derived` (pure core + writer)

- **Files**: `src/Seal/Session/Derived.hs` (new), `src/Seal/Config/Paths.hs`,
  `test/Seal/Session/DerivedSpec.hs` (new), `test/Seal/Config/PathsSpec.hs`,
  `seal-harness.cabal` (library `exposed-modules:` for `Seal.Session.Derived`;
  test-suite `other-modules:` for **`Seal.Session.DerivedSpec`** — the spec, not
  the library module, which would be a duplicate-module error), `test/Main.hs`.
  *(Six files, one concern; declared deviation from the "~5" ceiling because
  `sessionDerivedPath` belongs beside `sessionMetaPath` by repo convention.)*
- **API**:
  ```haskell
  data DerivedMeta = DerivedMeta
    { dmVersion           :: !Int
    , dmLastUserMessageAt :: !(Maybe Text)   -- already rendered by showIso
    , dmEntriesBytes      :: !Int64
    } deriving stock (Eq, Show)

  sessionDerivedPath :: SealPaths -> SessionId -> FilePath
  readDerived        :: SealPaths -> SessionId -> IO (Maybe DerivedMeta)
  writeDerived       :: SealPaths -> SessionId -> DerivedMeta -> IO Bool  -- False, never throws
  entriesSize        :: SealPaths -> SessionId -> IO (Maybe Int64)
  derivedIsFresh     :: SealPaths -> SessionId -> IO Bool
  computeDerived     :: SealPaths -> SessionId -> IO (Maybe DerivedMeta)
    -- ^ THE single producer: stat -> read -> stat; Nothing when the two sizes
    --   disagree or entries.jsonl is absent. Used by both WU-2 and WU-3 so the
    --   parse logic is written once and the race rule is applied once.
  ```
- **DoD**:
  1. `sessionDerivedPath` returns `<sessionDir>/derived.json`; `PathsSpec` covers
     it (mirrors `sessionMetaPath`, `Paths.hs:164`).
  2. JSON is exactly
     `{"version":1,"last_user_message_at":…,"entries_bytes":…}`; version is
     written as `1`; the timestamp string is opaque here (produced by `showIso`).
  3. `readDerived` → `Nothing`, never an exception, for: missing file, malformed
     JSON, `version /= 1` (including a future `version: 2`, which the heal then
     **overwrites** as `version: 1`), and a non-object value.
  4. `writeDerived`: unique temp via `openBinaryTempFile` (not a fixed `.tmp`
     name — `Store.hs:125-139` documents that race), explicit `setFileMode tmp
     0o600` (the `unix` dep is already present; `openBinaryTempFile` alone is
     `0600 & ~umask`), `renameFile`; returns `False` and leaves **no** temp file
     when the session dir is absent or the write fails; never creates a
     directory; never throws.
  5. `entriesSize`: `Nothing` when `entries.jsonl` is absent (never
     `getFileSize`, which throws), `Just 0` for a zero-byte file, `Just n`
     otherwise.
  6. `derivedIsFresh` = sidecar present ∧ version ok ∧ `dmEntriesBytes ==
     entriesSize`; **`False`** when `entries.jsonl` is absent, on every
     mismatch (smaller *and* larger), and when `dmEntriesBytes` is negative.
  7. `computeDerived` returns `Nothing` when `entries.jsonl` is absent or when
     the pre/post stat sizes disagree; otherwise the freshly parsed value with
     the agreed byte count.
  8. `DerivedSpec` covers, explicitly: DoD 3's four cases; DoD 4's
     `False`-and-no-temp case (`entriesSize`-style bogus session dir) and the
     `0o600` mode (`getFileMode`); DoD 5's `Nothing` / `Just 0`; DoD 6's matrix
     (absent, smaller, larger, negative); DoD 7's disagreement path.
  9. QuickCheck (bounded): `decode (encode m) == Right m`; decoding arbitrary
     mutated bytes never throws.
 10. No partial functions; `-Wall -Werror`; hlint clean.
- **Deps**: WU-0.

### WU-2 — read path

- **Files**: `src/Seal/Gateway/Transcript.hs` (`lastUserMessageAtFast` only),
  `test/Seal/Gateway/TranscriptSpec.hs`.
  *(No new test module: I16's two levels are both assertable from
  `TranscriptSpec`, which can import `Seal.Gateway.ListsSnapshot` — an exposed
  library module — so no extra cabal/`test/Main.hs` wiring is needed.)*
- **DoD**:
  1. Fresh sidecar ⇒ return the cached value **without parsing `entries.jsonl`**
     — proven by overwriting `entries.jsonl` with unparseable bytes of the
     *same length* and still getting the cached value.
  2. Miss / stale ⇒ `computeDerived`, then `writeDerived` when it yields a value;
     return the computed value regardless of whether the write succeeded.
  3. **I17**: appending to `entries.jsonl` (changing its size) without touching
     the sidecar ⇒ the new value is returned and the sidecar is rewritten.
  4. **I16** at both levels: with every `derived.json` deleted,
     (a) `sessionInfoJsonWithSnippet` output is byte-identical for every session
     and (b) `buildListsSnapshot` JSON is byte-identical, versus a warm run.
  5. **Corrupt sidecar still lists**: a session whose `derived.json` is garbage
     or `version: 99` appears in the listing with the correct
     `lastUserMessageAt`.
  6. **Absent `entries.jsonl`**: `lastUserMessageAtFast` returns `Nothing`,
     writes **no** sidecar and creates **no** directory. This needs its **own**
     direct test — the existing `/nonexistent-seal-test` case at
     `TranscriptSpec.hs:717-721` belongs to the
     `firstUserMessageSnippetFast` block and does not execute the changed
     function (which today has no direct test at all).
  7. **Zero-byte `entries.jsonl`**: returns `Nothing`, and
     `{"…":null,"entries_bytes":0}` is a legitimate fresh sidecar (a second call
     returns `Nothing` without re-reading).
  8. **`entries.jsonl` deleted while a sidecar exists**: the sidecar is ignored
     (`derivedIsFresh` is `False`), `Nothing` is returned, the orphan file is
     **left in place** (no delete — the read path never removes files), and no
     exception escapes.
  9. `firstUserMessageSnippetFast` is **unchanged** — no new code path; its
     existing tests are untouched.
 10. `-Wall -Werror`; hlint clean; `make check` green.
- **Deps**: WU-1.

### WU-3 — `/session reindex`

- **Files**: `src/Seal/Command/Session.hs`,
  `test/Seal/Command/SessionSpec.hs`.
- **DoD**:
  1. `/session reindex` processes `listSessions <> listArchivedSessions`
     (top-level, non-child — `Store.hs:146,168`), using `computeDerived` +
     `writeDerived` (never `lastUserMessageAtFast`, which would double-write).
  2. Prints exactly `written: N  skipped: M  failed: K`:
     **skipped** = `derivedIsFresh` was already `True` **or** `entries.jsonl` is
     absent (nothing to compute); **failed** = `computeDerived` yielded a value
     but `writeDerived` returned `False` (reachable by pointing the command at a
     session directory that exists but is not writable — asserted in the test via
     a bogus `SessionId` whose dir is absent); **written** = the rest.
  3. **Values are correct, not just counted**: for each session, the value the
     reindex wrote makes `lastUserMessageAtFast` return the same thing as it does
     with all sidecars deleted. Asserted directly — a bytes-correct but
     `null`-timestamp sidecar must fail this.
  4. **Idempotent**, stated precisely: run 1 on N sessions (all stale) reports
     `written: N  skipped: 0`; run 2 reports `written: 0  skipped: N` (the
     `skipped` count is the *total*, not run 1's count).
  5. No flag — it always processes everything (the design's `--all` is gone;
     there is no other mode).
  6. Missing sessions root ⇒ `written: 0  skipped: 0  failed: 0`, no exception.
  7. Exercised through `SessionSpec`'s existing `runSess` hook
     (`test/Seal/Command/SessionSpec.hs:53-58`), asserting the printed line.
  8. `-Wall -Werror`; hlint clean.
- **Deps**: WU-2.

## Dependency graph (strictly sequential)

```
WU-0 (bench) → WU-1 (Derived) → WU-2 (read path) → WU-3 (/session reindex)
```

Every WU edits `seal-harness.cabal`; parallelising them would create the exact
merge conflict AGENTS.md warns about. WU-0 goes first so the baseline exists
before any behaviour changes.

## API contract

No HTTP/WS change.

```
exe/bench-lists        # separate executable, NOT part of the shipped `seal` binary
make bench-lists       # $(NIX) cabal run -v0 bench-lists -- $(ARGS)
/session reindex       # slash command, GroupSession, InteractiveOnly
```

## Security considerations

- **Trust boundary**: none crossed — no client/model input, no opcode.
- **Writes land** in `<state>/sessions/<sid>/derived.json`, the same directory as
  `session.json`, and never in the agent-immutable `~/.seal/` members AGENTS.md
  enumerates. Writer is the gateway process, not an opcode.
- **Mode `0o600`**; the file holds a derived timestamp only (no content).
- **Never logged**: no surface prints transcript content; `reindex` prints counts.
- **Never authoritative**: deleting all sidecars yields byte-identical output
  (I16), and a tampered sidecar cannot invent history — it is trusted only when
  its recorded byte count matches the real file size.

## Risks

| Risk | Mitigation |
|---|---|
| Sidecar disagrees with `entries.jsonl` | size key; any append changes the size (I17) |
| Race: append lands during the read | `stat → read → stat`; write only if sizes agree |
| Concurrent heals for one session | unique temp file + atomic rename |
| Corrupt / unknown-version sidecar | treated as absent; session still lists |
| Heal write throws in a read path | `writeDerived` returns `Bool`, never throws, never creates dirs |
| Bench mutates what it measures | one unmeasured warm-up; cold iteration reported separately |
| Metric 4 not achieved | **gate on a named statistic**: the **median of the measured (warm) iterations**, post-change vs the baseline recorded in the PR description. Cold iteration is reported but does not gate (post-change cold includes the one-time heal). If the median is not ≥5× better, the PR is not opened and the findings are escalated. |

## Files touched (declared scope, code branch only)

```
exe/bench-lists/Main.hs                 (new)
src/Seal/Session/Derived.hs             (new)
src/Seal/Config/Paths.hs
src/Seal/Gateway/Transcript.hs
src/Seal/Command/Session.hs
Makefile
seal-harness.cabal
test/Main.hs
test/Seal/Session/DerivedSpec.hs        (new)
test/Seal/Config/PathsSpec.hs
test/Seal/Gateway/TranscriptSpec.hs
test/Seal/Command/SessionSpec.hs
```

Docs (`docs/superpowers/specs/…`, `docs/superpowers/plans/…`) ship on
`docs/session-dispositions-spec` **before** this branch is opened, so PR 0 is one
logical change.

## Open item (operator action, not a work unit)

AGENTS.md rule 2 makes issues human-authored, so the tracking issue for this epic
is **not** created by the agent. The PR body will carry `Closes #NN` once the
operator files it; design §12 Q-E records the same prerequisite. This is an
explicit open item rather than a silent omission.

## Human checkpoints

- **After WU-0**: operator pastes `make bench-lists` output from the real store
  (the sandbox cannot read `~/.seal`). This is the only source of a true
  baseline. **Pause.**
- **After WU-3**: report before/after against Metric 4's gate, then request PR
  creation approval.

## Verification standard

`make check` — `build` (= `cabal build all` **plus** `npm run build`), `test`
(`cabal test`), `lint` (`hlint src/ test/ exe/`). No `--no-verify`, no skipped
tests. Per WU: IMPLEMENT → VALIDATE (the orchestrator runs the gates itself) →
ADVERSARIAL REVIEW (fresh reviewer per attempt, max 3) → COMMIT.
