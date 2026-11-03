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

### WU-0 — `bench-lists` executable (the baseline instrument)

- **Files**: `exe/bench-lists/Main.hs` (new), `seal-harness.cabal`,
  `Makefile`.
- **cabal stanza** (must be explicit):
  ```
  executable bench-lists
    import:           settings
    hs-source-dirs:   exe/bench-lists
    main-is:          Main.hs
    build-depends:    base, seal-harness, seal-gateway-types,
                      containers, directory, filepath, time, optparse-applicative
  ```
- **DoD**:
  1. `bench-lists [--iterations N]` (default 3) calls the production
     `buildListsSnapshot` (`ListsSnapshot.hs:41`) with `newTabsHandle`
     (`Tabs.hs:43`) and `Set.empty`, after **one unmeasured warm-up** iteration
     (the run heals sidecars, so iteration 1 is cold), then prints: session
     count, the cold iteration's ms separately, and min/median of the measured
     iterations.
  2. Prints modelled bytes: `Σ size(entries.jsonl)` and `Σ size(derived.json)`,
     labelled `modelled bytes (file sizes, not syscall accounting)`. Missing
     files count as 0.
  3. Exits 0 with zero sessions and prints `sessions: 0`.
  4. `make bench-lists` runs it via the existing `NIX` wrapper (`Makefile:8`):
     `$(NIX) cabal run -v0 bench-lists -- $(ARGS)`.
  5. `make lint` is extended to `hlint src/ test/ exe/` so the new directory is
     covered by the gate.
  6. `cabal build all` green.
- **Deps**: none.

### WU-1 — `Seal.Session.Derived` (pure core + writer)

- **Files**: `src/Seal/Session/Derived.hs` (new), `src/Seal/Config/Paths.hs`,
  `test/Seal/Session/DerivedSpec.hs` (new), `test/Seal/Config/PathsSpec.hs`,
  `seal-harness.cabal` (library `exposed-modules:` **and** test-suite
  `other-modules:`), `test/Main.hs`.
  *(Six files, one concern; the ceiling is "~5" — called out as an accepted
  deviation because `sessionDerivedPath` belongs next to `sessionMetaPath` by
  repo convention rather than in `Derived`.)*
- **API**:
  ```haskell
  data DerivedMeta = DerivedMeta
    { dmVersion           :: !Int
    , dmLastUserMessageAt :: !(Maybe Text)   -- rendered by showIso
    , dmEntriesBytes      :: !Int64
    } deriving stock (Eq, Show)

  sessionDerivedPath :: SealPaths -> SessionId -> FilePath
  readDerived        :: SealPaths -> SessionId -> IO (Maybe DerivedMeta)
  writeDerived       :: SealPaths -> SessionId -> DerivedMeta -> IO Bool  -- False, never throws
  derivedIsFresh     :: SealPaths -> SessionId -> IO Bool
  entriesSize        :: SealPaths -> SessionId -> IO (Maybe Int64)
  ```
- **DoD**:
  1. `sessionDerivedPath` returns `<sessionDir>/derived.json`; `PathsSpec`
     covers it (mirrors `sessionMetaPath`, `Paths.hs:164`).
  2. `DerivedMeta` JSON is exactly
     `{"version":1,"last_user_message_at":…,"entries_bytes":…}`; the timestamp
     string is opaque to this module (produced by the caller with `showIso`).
  3. `readDerived` returns `Nothing` — **never throws** — for a missing file,
     malformed JSON, or `version /= 1`.
  4. `writeDerived` writes atomically (unique temp from `openBinaryTempFile`,
     not a fixed `.tmp` name — `Store.hs:130-141` documents that race), mode
     `0o600`, `renameFile`; **returns `False` and leaves nothing behind** on any
     failure; **never creates a directory** (returns `False` when the session dir
     is absent); never throws.
  5. `entriesSize` returns `Nothing` when `entries.jsonl` is absent (it must not
     use `getFileSize`, which throws), and `Just n` otherwise (including `0`).
  6. `derivedIsFresh` = sidecar exists ∧ version ok ∧ `dmEntriesBytes` equals
     `entriesSize`; **`False` when `entries.jsonl` is absent**.
  7. QuickCheck (bounded): `decode (encode m) == Right m`; and decoding arbitrary
     mutated bytes never throws.
  8. No partial functions; `-Wall -Werror`; hlint clean.
- **Deps**: WU-0 (shared `seal-harness.cabal` + `test/Main.hs`).

### WU-2 — read path

- **Files**: `src/Seal/Gateway/Transcript.hs` (`lastUserMessageAtFast` only),
  `test/Seal/Gateway/TranscriptSpec.hs`.
- **DoD**:
  1. Fresh sidecar ⇒ return the cached value **without parsing `entries.jsonl`**
     — proven by overwriting `entries.jsonl` with unparseable bytes of the
     *same length* and still getting the cached value.
  2. Miss / stale ⇒ compute with the existing implementation, then
     `stat → read → stat`; write the sidecar **only if the two stats agree** and
     `entries.jsonl` exists. Return the computed value regardless.
  3. **I17**: appending to `entries.jsonl` (changing size) without touching the
     sidecar ⇒ the new value is returned and the sidecar is rewritten.
  4. **I16**: with every `derived.json` deleted, `sessionInfoJsonWithSnippet`
     output is byte-identical for every session (the shared leaf behind
     `/api/lists`, `/api/sessions`, `/api/sessions/archived`) — and so is
     `buildListsSnapshot`. Tested at both levels.
  5. **Corrupt sidecar still lists**: a session whose `derived.json` is garbage
     or `version: 99` appears in the listing with the correct
     `lastUserMessageAt`.
  6. **Absent `entries.jsonl`**: returns `Nothing`, writes **no** sidecar, and
     creates **no** directory (the existing `/nonexistent-seal-test` test at
     `TranscriptSpec.hs:717-721` stays green). Zero-byte `entries.jsonl`:
     `Nothing` is returned and `{"…":null,"entries_bytes":0}` is a legitimate
     fresh sidecar.
  7. `firstUserMessageSnippetFast` is **unchanged** — no new code path, existing
     tests untouched.
  8. `-Wall -Werror`; hlint clean; `make check` green.
- **Deps**: WU-1.

### WU-3 — `/session reindex`

- **Files**: `src/Seal/Command/Session.hs`,
  `test/Seal/Command/SessionSpec.hs`.
- **DoD**:
  1. `/session reindex` processes `listSessions <> listArchivedSessions`
     (top-level, non-child) — `Store.hs:150,172`.
  2. Prints exactly `written: N  skipped: N  failed: N`, where
     **written** = `writeDerived` returned `True`, **skipped** = `derivedIsFresh`
     was already `True` (or `entries.jsonl` is absent), **failed** = `writeDerived`
     returned `False`.
  3. Idempotent: a second run reports `written: 0` and the same `skipped` count.
  4. No flag: it always processes everything (design's `--all` is gone — there is
     no other mode).
  5. Parse-and-run is tested through `SessionSpec`'s existing `runSess` hook
     (`test/Seal/Command/SessionSpec.hs:54-58`); a missing sessions root yields
     `written: 0 skipped: 0 failed: 0` and does not throw.
  6. `-Wall -Werror`; hlint clean.
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
| Metric 4 not achieved | **gate**: if `make bench-lists` wall time is not ≥5× better than the recorded baseline, the PR is not opened |

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
