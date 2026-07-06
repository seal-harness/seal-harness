# Phase 6a — Harness Backend (tmux seam + durable registry + reconcile loop): Plan

> **For agentic workers:** Implement task-by-task, top to bottom. Each task is
> TDD (red → green → commit). Steps use checkbox (`- [ ]`) syntax. Do not start
> a task until the previous task's gate is green (`cabal build all` `-Werror`
> clean, `cabal test` green, `hlint src/ test/` clean, all in the Nix dev shell).
> One commit per task.

**Goal:** Stand up the harness backend — a tmux-backed execution seam, a
durable UUID-keyed `HarnessRegistry` (STM, race-safe CRUD, lost-update-safe
reconcile merge), the per-flavour observer + reconcile loop with a
wall-clock-free grace eviction policy, and the adoption path for external
tmux windows. This is the foundation Phase 6b's tabs-as-view binds to: a
tab's `BoundHarness HarnessId` resolves through the registry to a live
`HarnessEntry`. No tab UX yet — that's 6b.

**Parent roadmap:**
`docs/superpowers/plans/2026-06-28-seal-harness-roadmap.md` § Phase 6 (6a).

**Why this sub-phase:** harnesses are external CLI tools (Claude Code,
Codex, …) that can only be driven reliably inside a tmux session, so the
harness backend is tmux-only by construction. The registry is the ground
truth a tab's `BoundHarness` references; it must be durable (UUID-keyed,
not a mutable terminal label), race-safe (concurrent reconcile + user
mutations never clobber), and self-healing (the reconcile loop classifies
liveness and evicts orphans). Landing it before 6b means the tab layer is a
pure view over a stable ground truth.

## Tech Stack

Haskell (GHC2021), Cabal, Nix dev shell. Uses **`process`**
(`System.Process` — the established helper pattern from
`Seal.Security.Vault.Age.readProcessBinary` /
`Seal.Vault.Backend.readProcessNoInput` /
`Seal.Git.Repo.readProcessBinaryCwd`). Existing deps: `stm`, `aeson`,
`text`, `bytestring`, `containers`, `time`, `uuid` (NEW — for
`HarnessId`; check it's available, else generate UUIDs via
`crypton`-derived randomness + a hand-rolled v4 encoder — see T0).
Build/test via `nix develop --command cabal build all`, `… cabal test`,
`… hlint src/ test/`.

## Global Constraints

Inherited from the roadmap verbatim where the spec is exact:

- **Module namespace:** all library code under `Seal.*`. New modules:
  `Seal.Harness.Id`, `Seal.Handles.Harness`, `Seal.Harness.Registry`,
  `Seal.Harness.Tmux`, `Seal.Session.Kind`, `Seal.Harness.Reconcile`,
  `Seal.Harness.Observer`, `Seal.Harness.Discovery`,
  `Seal.Security.Adoption`.
- **Coding style:** GHC2021; conservative always-on `default-extensions`;
  per-file `OverloadedStrings` / `ImportQualifiedPost`. Whole-module imports;
  post-positive qualified imports.
- **Errors:** `Either Text` / `ExceptT Text` default. A bespoke error ADT
  only where control flow pattern-matches it — expected here: `HarnessError`
  (the `Seal.Handles.Harness` error sum: spawn failure, capture failure,
  stop failure, not-found, tmux-missing).
- **GHC flags:** `-Wall -Werror` plus the strict set.
- **TDD:** red → green → commit. Security-critical pure functions
  (`validateTmuxIdent`, the registry merge invariants, `authorizeAdoption`)
  get QuickCheck properties. The IO-bound tmux seam is tested via the pure
  argv builders (`sendKeysNamedArgs` etc.) + a no-op `HarnessHandle` for
  the registry/reconcile tests; no real tmux binary is needed for the suite.
- **hlint clean** before each commit.
- **No shell-wrapping.** Every tmux invocation builds its `CreateProcess`
  from a fixed argv (no shell interpreter, no constructed command string).
  The tmux session/window/pane identifiers are smart-constructed
  `TmuxIdent` newtypes (charset predicate, no leading dash — option
  injection defense) so an attacker-supplied label fails to compile into
  the argv. Fixed-argv invocation of `tmux` is permitted as infrastructure
  per the roadmap's "No shell-wrapping" rule.
- **Type-guaranteed subprocess arguments.** `TmuxIdent`, `HarnessId`
  (text form, for `@seal_id` markers), and `HarnessFlavour` (the known-tool
  enum + a smart-constructed `HCustom` that rejects path separators) are
  the validated types that reach any subprocess argv.
- **Cabal registration:** new library modules in `exposed-modules`, new test
  specs in `other-modules`, both alphabetical; new specs wired into
  `test/Main.hs`.
- **Commits:** one per task.
- **Build/verify:** `nix develop --command cabal build all`,
  `nix develop --command cabal test`,
  `nix develop --command cabal test --test-options='--match "<needle>"'`,
  `nix develop --command hlint src/ test/`.
- **Clean-room:** no prior/reference runtime named in code, comments, docs,
  or commit messages.

## Non-goals (explicitly out of scope for 6a)

- **No tab UX.** `TabList`, `TabIndex`, `TabRef`, the `/tab` family, the
  terse `/N` grammar, per-conversation relay — all 6b. 6a delivers the
  *ground truth* a tab binds to, not the tab view.
- **No `/tab` or `/tabs` slash commands.** 6b registers them.
- **No `seal harness` CLI subcommand yet.** The `HARNESS_LIST/START/STOP`
  opcodes (the ISA group) and the `seal harness` subcommand land at the
  6a/6b boundary (the final 6a task wires the opcodes; the subcommand is
  6b's wiring since it drives tabs). 6a delivers the *library* (handles +
  registry + tmux + reconcile + discovery) + the ISA opcode *definitions*;
  the user-facing commands are 6b.
- **No Process-tree PID provenance yet.** `selectHarnessPid`/`parsePsRows`/
  `harnessPidOf` (BFS over the process tree, cycle-safe) is deferred to a
  follow-up — it's an observer refinement, not on the 6a critical path.
  The observer classifies liveness via screen-capture heuristics only.
- **No multi-flavour observers.** Only the Claude Code screen-capture
  heuristic lands in 6a (the reference's primary case). A codex/generic
  observer is a follow-up.
- **No gateway/web.** Phase 7.
- **No remote-only untrusted execution.** Phase 4. The harness backend is
  tmux-local by construction (a harness IS a local tmux window); the
  tool-call execution split (Local/Tmux/Ssh/Container) is a separate
  Phase-4 concern that reuses the tmux seam's argv builders.

---

## Task map

| Task | Title | Gate |
|---|---|---|
| **T0** | `Seal.Harness.Id` — `HarnessId` (UUID-backed durable identity) | `cabal test` green; `newHarnessId`/`parseHarnessId`/`harnessIdToText` + round-trip QuickCheck |
| **T1** | `Seal.Handles.Harness` — `HarnessHandle` capability record + `HarnessStatus`/`HarnessError` + no-op handle + sanitize helpers | `cabal test` green; no-op handle round-trip; `stripAnsi`/sanitize unit + QuickCheck |
| **T2** | `Seal.Harness.Registry` — `HarnessEntry`/`HarnessOrigin`/`Liveness` + STM registry + race-safe CRUD + `mergeReconcile` | `cabal test` green; CRUD + QuickCheck on the merge invariants (concurrent inserts never clobber) |
| **T3** | `Seal.Harness.Tmux` — pure argv builders + `validateTmuxIdent` + `stripAnsi` (pure) | `cabal test` green; argv builders unit-tested; `validateTmuxIdent` QuickCheck (rejects leading-dash/empty/control/`:`) |
| **T4** | `Seal.Harness.Tmux` — IO wrappers (start/add/send/capture/stop/rename/markers) via `process` | `cabal test` green; IO wrappers tested via a fake-process seam (capture the argv, no real tmux) |
| **T5** | `Seal.Session.Kind` + `Seal.Harness.Observer` + `Seal.Harness.Reconcile` — the reconcile loop | `cabal test` green; observer classifies a scripted capture into Liveness; `mergeReconcile` + `defaultOrphanGraceTicks` eviction QuickCheck |
| **T6** | `Seal.Harness.Discovery` + `Seal.Security.Adoption` — discoverable windows + consent-gated adoption | `cabal test` green; `scanDiscoverableIO` over a fake; `authorizeAdoption` fail-closes on headless/missing consent |
| **T7** | ISA harness opcodes (`HARNESS_LIST/START/STOP`) + `Seal.Phase6aSpec` capstone | `cabal test` green; opcodes dispatch; capstone drives a fake harness through start→liveness→stop |

---

## T0 — `Seal.Harness.Id` — `HarnessId` (UUID-backed durable identity)

**Why:** the registry keys on identity, not a mutable terminal label. A
`HarnessId` is a UUID-backed durable identity minted at spawn time and
stamped as a tmux `@seal_id` marker on the harness window, so a window can
be re-identified after a `tmux rename-window` or a reconnect. Pure module
(UUID generation is IO, but the parse/text codec is pure).

**Module:** `src/Seal/Harness/Id.hs`

### Design

```haskell
-- | A UUID-backed durable harness identity (the registry key). Minted at
-- spawn time; stamped as a tmux @seal_id marker on the harness window.
newtype HarnessId = HarnessId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

-- | Mint a fresh random HarnessId (UUID v4). IO because it reads randomness.
newHarnessId :: IO HarnessId

-- | Parse a HarnessId from its text form (a UUID). 'Left' on malformed input.
parseHarnessId :: Text -> Either Text HarnessId

-- | The text form (a UUID string) — the value stamped as the @seal_id marker.
harnessIdToText :: HarnessId -> Text
```

### UUID generation

The repo has `uuid-types` (the `UUID` type + `toString`/`fromWords64`) but
NOT the full `uuid` package (no `Data.UUID.V4.nextRandom`). `random` is
available. **Decision: do NOT add `uuid` as a dep.** Generate a UUID v4
from two random `Word64`s (`System.Random.randomIO`) with the v4
version/variant bits set (version 4 = high nibble of byte 6 = `4`,
variant = high bits of byte 8 = `10`), via `UUID.fromWords64`. This keeps
the dep set unchanged and the generation in-repo. `newHarnessId =
HarnessId . T.pack . U.toString <$> genV4` where `genV4` masks the two
`Word64`s appropriately.

### TDD steps

- [ ] **Red.** Write `test/Seal/Harness/IdSpec.hs`:
  - `parseHarnessId (harnessIdToText h) == Right h` for a minted `h`.
  - `parseHarnessId "not-a-uuid"` `shouldSatisfy` isLeft.
  - `parseHarnessId ""` `shouldSatisfy` isLeft.
  - QuickCheck: for any `Text` that decodes as a valid UUID,
    `parseHarnessId` round-trips. (Generate valid UUID strings via the
    `uuid` library's `Arbitrary` if available, else generate the
    `[0-9a-f-]` charset in the UUID shape.)
  - Two minted `HarnessId`s are distinct (probabilistic — run 1000).
- [ ] **Red-verify.** Fails (module missing / `uuid` dep missing).
- [ ] **Green.** Add `uuid` to `build-depends`. Implement
  `src/Seal/Harness/Id.hs`. Register in `exposed-modules` (alphabetical:
  `Seal.Harness.Id` before `Seal.Handles.Harness`).
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(harness): HarnessId UUID-backed durable identity`

---

## T1 — `Seal.Handles.Harness` — `HarnessHandle` capability record + status/error + no-op handle + sanitize

**Why:** the capability handle is the seam the registry + reconcile loop +
(6b) the tab runtime drive a harness through. A no-op handle backs the
registry/reconcile tests so they need no real tmux. The sanitize helpers
(strip ANSI/control/decorative bytes) are pure and security-relevant (a
captured screen may carry escape sequences that could spoof the observer
or the transcript).

**Module:** `src/Seal/Handles/Harness.hs`

### Design

```haskell
data HarnessStatus
  = HsIdle | HsThinking | HsAwaitingInput | HsExited | HsOrphaned
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data HarnessError
  = HeSpawnFailed Text
  | HeCaptureFailed Text
  | HeStopFailed Text
  | HeNotFound HarnessId
  | HeTmuxMissing
  deriving stock (Eq, Show)

-- | The capability record of IO actions for driving one harness.
data HarnessHandle = HarnessHandle
  { hhSend      :: Text -> IO (Either HarnessError ())
  , hhReceive   :: IO (Either HarnessError [Text])   -- ^ captured output lines (sanitized)
  , hhSnapshot  :: IO (Either HarnessError Text)      -- ^ full screen capture (sanitized)
  , hhStatus    :: IO (Either HarnessError HarnessStatus)
  , hhStop      :: IO (Either HarnessError ())
  }

-- | A no-op handle for tests: sends succeed, receive/snapshot return empty,
-- status is HsIdle, stop succeeds.
noOpHarnessHandle :: HarnessHandle

-- | Strip ANSI escape sequences, control characters, and decorative bytes
-- from a captured line. Pure. Used by the real handle's capture path and
-- by the observer.
stripAnsi :: Text -> Text

-- | Strip ALL control characters (a superset of stripAnsi — also removes
-- NUL/BEL/BS etc., not just CSI sequences). Pure.
stripControl :: Text -> Text
```

### `stripAnsi` invariants (QuickCheck)

- `stripAnsi` never emits an ESC byte (`\x1b`).
- `stripAnsi` is idempotent (`stripAnsi (stripAnsi t) == stripAnsi t`).
- `stripAnsi` of plain ASCII text is identity.
- `stripAnsi` removes a CSI sequence (`\x1b[` … `m`) entirely.
- `stripControl` removes NUL/BEL/BS/DEL and is idempotent.

### TDD steps

- [ ] **Red.** Write `test/Seal/Handles/HarnessSpec.hs`: no-op handle
  round-trip (send succeeds, receive is `Right []`, status is `HsIdle`,
  stop succeeds); `stripAnsi`/`stripControl` unit + QuickCheck.
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement `src/Seal/Handles/Harness.hs`. Register in
  `exposed-modules` (alphabetical: `Seal.Handles.Harness` before
  `Seal.Handles.Transcript`).
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(handles): HarnessHandle capability record + sanitize`

---

## T2 — `Seal.Harness.Registry` — STM registry + race-safe CRUD + `mergeReconcile`

**Why:** the registry is the ground truth. STM-backed, keyed by
`HarnessId`, with race-safe CRUD (insert/lookupById/lookupByLabel/
modify/delete/snapshot) and a `mergeReconcile` that merges observed
harnesses into entries **by key inside one transaction** so concurrent
inserts are never clobbered (the lost-update-safe path). Pure-ish (the
registry is `TVar`-backed; the merge is an `STM` action).

**Module:** `src/Seal/Harness/Registry.hs`

### Design

```haskell
data HarnessOrigin = HoSpawned | HoDiscovered | HoAdopted
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Liveness = LvIdle | LvThinking | LvAwaitingInput | LvExited | LvOrphaned
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | One registry entry: the durable identity + the reconciled
-- coordinate/health cache. The coordinate (tmux session.window) is the
-- live position; the liveness is the observer's last classification.
data HarnessEntry = HarnessEntry
  { heId        :: HarnessId
  , heLabel     :: Text              -- ^ human-facing label (mutable)
  , heOrigin    :: HarnessOrigin
  , heLiveness  :: Liveness
  , heTmuxCoord :: Maybe Text        -- ^ "session:window.pane" when backed by tmux
  , heFlavour   :: Maybe Text        -- ^ the harness flavour (claude-code, codex, …)
  , heOrphanTicks :: Int             -- ^ consecutive Orphaned ticks (for grace eviction)
  }

newtype HarnessRegistry = HarnessRegistry (TVar (Map HarnessId HarnessEntry))

newHarnessRegistry :: IO HarnessRegistry

insert :: HarnessRegistry -> HarnessEntry -> STM ()
lookupById :: HarnessRegistry -> HarnessId -> STM (Maybe HarnessEntry)
lookupByLabel :: HarnessRegistry -> Text -> STM (Maybe HarnessEntry)
modify :: HarnessRegistry -> HarnessId -> (HarnessEntry -> HarnessEntry) -> STM ()
delete :: HarnessRegistry -> HarnessId -> STM ()
snapshot :: HarnessRegistry -> IO [HarnessEntry]   -- ^ all entries, sorted by id

-- | Merge a list of observed harnesses (from the reconcile sweep) into the
-- registry **inside one STM transaction**, so concurrent inserts never
-- clobber. Observed entries are merged by key: an existing entry keeps its
-- origin + orphan-ticks (reset on a non-orphan observation); a new
-- observed entry is inserted as OriginDiscovered. Returns the new entries.
mergeReconcile :: HarnessRegistry -> [ObservedHarness] -> STM [HarnessEntry]

-- | The observed-harness shape the reconcile loop produces (pure data; the
-- observer fills it from a screen capture + the tmux markers).
data ObservedHarness = ObservedHarness
  { ohId        :: HarnessId
  , ohLiveness  :: Liveness
  , ohTmuxCoord :: Maybe Text
  , ohFlavour   :: Maybe Text
  }
```

### `mergeReconcile` invariants (QuickCheck)

- An observed id that already exists: the entry's `heOrigin` is preserved
  (a `HoSpawned` stays `HoSpawned`, not overwritten to `HoDiscovered`),
  `heLiveness` is updated, `heOrphanTicks` is 0 if the new liveness is
  non-Orphaned, else incremented.
- An observed id that doesn't exist: inserted as `HoDiscovered` with
  `heOrphanTicks = 0`.
- An existing entry NOT in the observed list: untouched by `mergeReconcile`
  (orphan-tick increment happens in a separate `tickOrphans` step, not
  here — keeps `mergeReconcile` pure-merge).
- **Lost-update safety:** two `mergeReconcile`s with disjoint observed ids
  composed in one transaction both land (neither clobbers the other).
- `snapshot` after `mergeReconcile` reflects all observed entries.

### TDD steps

- [ ] **Red.** Write `test/Seal/Harness/RegistrySpec.hs`: CRUD + the
  `mergeReconcile` invariants above as QuickCheck properties (use
  `atomically` to run the STM actions).
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement `src/Seal/Harness/Registry.hs`. Register in
  `exposed-modules` (after `Seal.Harness.Id`, before
  `Seal.Harness.Tmux`).
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(harness): STM HarnessRegistry + race-safe mergeReconcile`

---

## T3 — `Seal.Harness.Tmux` — pure argv builders + `validateTmuxIdent` + `stripAnsi` (pure)

**Why:** the tmux seam is the sole chokepoint for tmux subprocesses. The
pure argv builders are unit-testable without a tmux binary and are the
security-critical surface (option-injection defense). `validateTmuxIdent`
is the defense-in-depth predicate. `stripAnsi` lives here too (re-exported
from `Seal.Handles.Harness` to avoid a cycle, OR duplicated — decide: keep
it in `Handles.Harness` and import here; the tmux seam is the only
consumer besides the observer).

**Module:** `src/Seal/Harness/Tmux.hs`

### Design

```haskell
-- | A validated tmux identifier (session name, window name, pane id).
-- Smart-constructed: rejects empty, leading dash, control chars, and `:`
-- (tmux's separator — a `:` in a name would break coordinate parsing).
newtype TmuxIdent = TmuxIdent Text
  deriving stock (Eq, Show)

mkTmuxIdent :: Text -> Either Text TmuxIdent
tmuxIdentText :: TmuxIdent -> Text

validateTmuxIdent :: Text -> Either Text ()   -- ^ the bare predicate (exported for testing)

-- | Pure argv builders — each returns the exact argv list (no shell) that
-- the IO wrapper passes to `tmux`. Unit-testable.
sendKeysNamedArgs       :: TmuxIdent -> Text -> [String]
sendEnterNamedArgs      :: TmuxIdent -> [String]
pasteBufferNamedArgs    :: TmuxIdent -> Text -> [String]
captureNamedArgs        :: TmuxIdent -> [String]
killWindowNamedArgs     :: TmuxIdent -> [String]
renameWindowNamedArgs   :: TmuxIdent -> TmuxIdent -> [String]
newWindowNamedArgs      :: TmuxIdent -> TmuxIdent -> [String]
setWindowMarkerArgs     :: TmuxIdent -> Text -> [String]   -- ^ @seal_id marker
clearWindowMarkerArgs   :: TmuxIdent -> [String]
setRemainOnExitArgs     :: TmuxIdent -> [String]
```

### `validateTmuxIdent` invariants (QuickCheck)

- Rejects: empty, leading `-` (option injection), control chars
  (`\NUL`/`\x1b`/etc.), `:` (tmux separator).
- Accepts: `[A-Za-z0-9_.-]` (the tmux-safe charset), non-empty, no leading
  dash.
- The argv builders always pass `-l --` (literal text + `--` separator)
  before user-derived text in `sendKeysNamedArgs` (so a payload starting
  with `-` is not interpreted as a flag), and `sendEnterNamedArgs` is
  separate from `sendKeysNamedArgs` to prevent key-token injection (a
  payload like `Enter` is never parsed as the Enter key — it's sent as
  literal text via `sendKeys`, and `sendEnter` sends the actual Enter
  keystroke via a separate call).

### TDD steps

- [ ] **Red.** Write `test/Seal/Harness/TmuxSpec.hs`: `validateTmuxIdent`
  QuickCheck + explicit cases; each argv builder's output is the exact
  expected list (e.g. `sendKeysNamedArgs (mkTmuxIdent "win") "hello"` `==`
  `["send-keys", "-t", "win", "-l", "--", "hello"]` — adjust to the real
  tmux syntax; the reference uses `send-keys -t <target> -l -- <text>`).
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement `src/Seal/Harness/Tmux.hs` (pure parts only;
  IO wrappers are T4). Register in `exposed-modules`.
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(harness): tmux pure argv builders + validateTmuxIdent`

---

## T4 — `Seal.Harness.Tmux` — IO wrappers via `process`

**Why:** the IO wrappers turn the pure argv into `createProcess` calls to
the `tmux` binary. Tested via a fake-process seam (capture the argv, return
scripted stdout) so no real tmux is needed.

**Module:** `src/Seal/Harness/Tmux.hs` (same module — add the IO wrappers +
a `TmuxProcess` seam).

### Design

```haskell
-- | The process-execution seam: a function that runs @tmux@ with a given
-- argv and returns its stdout. The real implementation uses
-- System.Process (readProcessNoInput-style); tests supply a fake that
-- captures the argv and returns scripted output.
newtype TmuxRunner = TmuxRunner { runTmux :: [String] -> IO (Either HarnessError Text) }

-- | The real tmux runner via System.Process. Preflight @tmux --version@
-- (fail-closes with HeTmuxMissing if absent).
mkRealTmuxRunner :: IO TmuxRunner

-- | A fake runner for tests: records every argv passed, returns scripted
-- stdout per-call (popped from a queue).
mkFakeTmuxRunner :: [Text] -> IO (TmuxRunner, IO [[String]])

-- IO wrappers (each takes a TmuxRunner + the validated idents)
startTmuxSessionStatus :: TmuxRunner -> TmuxIdent -> IO (Either HarnessError ())
addHarnessWindowNamed  :: TmuxRunner -> TmuxIdent -> TmuxIdent -> HarnessId -> IO (Either HarnessError ())
sendToWindowNamed      :: TmuxRunner -> TmuxIdent -> Text -> IO (Either HarnessError ())
captureWindowNamed     :: TmuxRunner -> TmuxIdent -> IO (Either HarnessError [Text])
stopHarnessWindowNamed :: TmuxRunner -> TmuxIdent -> IO (Either HarnessError ())
renameWindowNamed      :: TmuxRunner -> TmuxIdent -> TmuxIdent -> IO (Either HarnessError ())
readMarkers            :: TmuxRunner -> TmuxIdent -> IO (Either HarnessError (Map Text Text))
setWindowMarker        :: TmuxRunner -> TmuxIdent -> Text -> Text -> IO (Either HarnessError ())
clearWindowMarker      :: TmuxRunner -> TmuxIdent -> Text -> IO (Either HarnessError ())
setRemainOnExit        :: TmuxRunner -> TmuxIdent -> IO (Either HarnessError ())

-- | Probe tmux capabilities: @seal_id marker support + pane_dead. Returns
-- False if tmux is too old.
checkTmuxCapabilities :: TmuxRunner -> IO Bool
```

### TDD steps

- [ ] **Red.** Write `test/Seal/Harness/TmuxIOSpec.hs` using
  `mkFakeTmuxRunner`: each IO wrapper passes the expected argv (assert
  against the captured argv list) and returns the scripted result. E.g.
  `sendToWindowNamed fake (mkTmuxIdent "win") "hello"` captures
  `["send-keys", "-t", "win", "-l", "--", "hello"]` and returns `Right ()`.
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement the IO wrappers in `src/Seal/Harness/Tmux.hs`
  using the `readProcessNoInput`-style helper (tmux takes no stdin; capture
  stdout/stderr). `mkRealTmuxRunner` pref lights `tmux --version`.
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(harness): tmux IO wrappers via process + fake-runner seam`

---

## T5 — `Seal.Session.Kind` + `Seal.Harness.Observer` + `Seal.Harness.Reconcile` — the reconcile loop

**Why:** the background reconcile loop is the self-healing spine. A
server sweep (`readMarkers`) per session is classified by a per-flavour
observer (Claude Code screen-capture heuristic) into `Liveness`, merged
into the registry via `mergeReconcile`, and the
`defaultOrphanGraceTicks` wall-clock-free grace policy auto-evicts an
entry after N consecutive Orphaned ticks (never touches `session.json`).

**Modules:** `src/Seal/Session/Kind.hs`, `src/Seal/Harness/Observer.hs`,
`src/Seal/Harness/Reconcile.hs`

### Design

```haskell
-- Seal.Session.Kind
data HarnessFlavour
  = HfClaudeCode | HfCodex | HfGeneric
  | HCustom Text   -- ^ smart-constructed: rejects path separators (/ to prevent argv injection into a custom-tool launch command)
  deriving stock (Eq, Show)

mkHCustom :: Text -> Either Text HarnessFlavour

data HarnessSpec = HarnessSpec
  { hsFlavour    :: HarnessFlavour
  , hsTmuxSession :: TmuxIdent
  , hsCwd        :: Maybe FilePath
  , hsArgs       :: [Text]
  , hsDurableId  :: Maybe HarnessId   -- ^ adopt an existing id (re-attach)
  }

data SessionKind
  = SkProvider ProviderSpec
  | SkHarness HarnessSpec
  -- | ProviderSpec is the existing provider+model binding shape (from
  -- Seal.Session.Meta or a new leaf — reuse what exists).

-- Seal.Harness.Observer
-- | The per-flavour observer: classify a captured screen + the marker map
-- into a Liveness. Pure (the capture is IO, the classification is pure).
observeClaudeCode :: Text -> Map Text Text -> Liveness

-- Seal.Harness.Reconcile
-- | One reconcile tick: read markers for the session, classify via the
-- observer, merge into the registry, then tick orphans and evict those
-- over the grace limit. Returns the post-tick snapshot.
reconcileTick
  :: HarnessRegistry -> TmuxRunner -> TmuxIdent -> HarnessFlavour
  -> Int  -- ^ grace ticks (defaultOrphanGraceTicks)
  -> IO [HarnessEntry]

defaultOrphanGraceTicks :: Int
defaultOrphanGraceTicks = 3

-- | Increment orphan-ticks for entries not seen in the last sweep, evict
-- those over the limit. STM, pure-ish.
tickOrphans :: HarnessRegistry -> Set HarnessId -> Int -> STM [HarnessEntry]  -- ^ evicted

-- | Map a Liveness to the activity-stream tag the frontend (Phase 7) consumes.
livenessToActivity :: Liveness -> Text
```

### Observer heuristic (Claude Code)

`observeClaudeCode screen markers` classifies by screen-content patterns:
- `LvThinking` when the screen shows a spinner / "Thinking…"/ "Working…".
- `LvAwaitingInput` when the screen shows the Claude Code prompt (`> ` at
  the bottom + no spinner) or a yes/no confirmation.
- `LvIdle` when the harness is at its main prompt but not awaiting input.
- `LvExited` when the marker is gone + the pane is dead (`pane_dead` marker).
- `LvOrphaned` when the pane exists but the `@seal_id` marker is gone
  (someone renamed the window out from under us, or the harness crashed and
  the pane is in a stale state).

### TDD steps

- [ ] **Red.** Write `test/Seal/Harness/ReconcileSpec.hs`:
  - `observeClaudeCode` classifies scripted screens into the expected
    Liveness (3-4 explicit cases per state).
  - `mkHCustom` rejects `/` and `\` (path separators).
  - `reconcileTick` with a fake `TmuxRunner` scripting a capture + markers:
    the registry's entry liveness updates; an orphaned entry's ticks
    increment; after `defaultOrphanGraceTicks + 1` ticks the entry is
    evicted (not in the snapshot).
  - QuickCheck: `tickOrphans` never evicts an entry whose id IS in the
    observed set; evicts an entry whose orphan-ticks exceed the limit.
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement the three modules. Register in
  `exposed-modules` (`Seal.Harness.Observer`, `Seal.Harness.Reconcile`,
  `Seal.Session.Kind`).
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(harness): reconcile loop + Claude Code observer + orphan grace`

---

## T6 — `Seal.Harness.Discovery` + `Seal.Security.Adoption` — discoverable windows + consent-gated adoption

**Why:** a user may have an existing tmux window running a CLI tool they
want the harness to adopt. Discovery scans for unmanaged tmux windows
(those without a `@seal_id` marker); adoption requires
`consent_confirmed` (a headless run cannot confirm, so adoption
fail-closes — the user must confirm via an interactive channel).

**Modules:** `src/Seal/Harness/Discovery.hs`,
`src/Seal/Security/Adoption.hs`

### Design

```haskell
-- Seal.Harness.Discovery
data DiscoverableWindow = DiscoverableWindow
  { dwTmuxCoord :: Text
  , dwTitle     :: Text
  , dwFlavourHint :: Maybe Text   -- ^ guessed from the title (claude-code, codex, …)
  }

-- | On-demand scan for unmanaged tmux windows (no @seal_id marker). IO.
scanDiscoverableIO :: TmuxRunner -> IO (Either HarnessError [DiscoverableWindow])

-- Seal.Security.Adoption
data ConsentChannel = CcCli | CcSignal | CcWeb   -- ^ interactive channels
data AdoptError
  = AeHeadlessNoConsent        -- ^ cannot confirm consent in a headless run
  | AeConsentMissing
  | AeAlreadyManaged HarnessId -- ^ the window already has a seal_id

-- | Authorize an adoption: requires consent_confirmed from an interactive
-- channel. A headless run (no ConsentChannel) fail-closes.
authorizeAdoption :: Maybe ConsentChannel -> Bool -> Either AdoptError ()
-- ^ (mChannel, consentConfirmed) -> ok or error
```

### TDD steps

- [ ] **Red.** Write `test/Seal/Harness/DiscoverySpec.hs` +
  `test/Seal/Security/AdoptionSpec.hs`:
  - `scanDiscoverableIO` with a fake `TmuxRunner` scripting a
    `list-windows`-style output returns the expected `DiscoverableWindow`s
    (filtering out windows that have a `@seal_id` marker).
  - `authorizeAdoption`: `(Just CcCli, True)` => `Right ()`;
    `(Nothing, _)` => `Left AeHeadlessNoConsent`;
    `(Just CcSignal, False)` => `Left AeConsentMissing`.
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement both modules. Register in `exposed-modules`.
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(harness): discoverable windows + consent-gated adoption`

---

## T7 — ISA harness opcodes + `Seal.Phase6aSpec` capstone

**Why:** the ISA harness opcode group (`HARNESS_LIST/START/STOP`) exposes
the registry to the model + the 6b slash commands. The capstone is the 6a
milestone gate: a fake harness driven through start → liveness → stop.

**Modules:** `src/Seal/ISA/Ops/Harness.hs` (the opcodes),
`test/Seal/Phase6aSpec.hs` (the capstone).

### Design

```haskell
-- Seal.ISA.Ops.Harness
harnessListOp  :: HarnessRegistry -> Opcode
harnessStartOp :: HarnessRegistry -> TmuxRunner -> HarnessFlavour -> ... -> Opcode
harnessStopOp  :: HarnessRegistry -> TmuxRunner -> Opcode
-- (PLAN_MODE is deferred to 6b — it's a tab-UX concern, not a harness lifecycle op.)
```

The opcodes are `Trusted` (harness lifecycle is a control-plane action,
not agent-supplied arbitrary execution). `HARNESS_START` spawns the tmux
window via the runner, stamps the `@seal_id` marker, inserts a
`HarnessEntry` (OriginSpawned) into the registry, and returns the
`HarnessId` to the model. `HARNESS_LIST` returns the snapshot.
`HARNESS_STOP` stops the tmux window + marks the entry `LvExited`.

### Capstone (`Seal.Phase6aSpec`)

Drive a fake `TmuxRunner` + a `HarnessRegistry` through:
1. `HARNESS_START claude-code` → a `HarnessId` is returned; the registry
   has one entry (OriginSpawned, LvIdle); the fake runner captured the
   `new-window` + `set-window-marker` argv.
2. A `reconcileTick` with a scripted "Thinking…" capture → the entry's
   liveness becomes LvThinking.
3. `HARNESS_LIST` → the model sees the entry with LvThinking.
4. `HARNESS_STOP` → the entry becomes LvExited; the fake runner captured
   `kill-window`.
5. A second `reconcileTick` where the pane is gone → the entry's ticks
   increment; after `defaultOrphanGraceTicks + 1` ticks the entry is
   evicted.

### TDD steps

- [ ] **Red.** Write `test/Seal/Phase6aSpec.hs` with the scenario above.
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement `src/Seal/ISA/Ops/Harness.hs`. Register in
  `exposed-modules`. Wire the opcodes into the test's `ISA.Registry`.
- [ ] **Green-verify.** `cabal test --match "Phase 6a capstone"` green;
  full suite green; hlint clean.
- [ ] **Commit.** `feat(harness): HARNESS_LIST/START/STOP opcodes + Phase 6a capstone`

---

## Milestone (6a)

**Definition of Done (whole sub-phase):**

- [ ] `cabal build all` is `-Werror` clean (Nix dev shell).
- [ ] `cabal test` green including the new QuickCheck properties and the
      `Seal.Phase6aSpec` capstone.
- [ ] `hlint src/ test/` clean.
- [ ] `Seal.Harness.Id`, `Seal.Handles.Harness`, `Seal.Harness.Registry`,
      `Seal.Harness.Tmux` (pure + IO), `Seal.Session.Kind`,
      `Seal.Harness.Observer`, `Seal.Harness.Reconcile`,
      `Seal.Harness.Discovery`, `Seal.Security.Adoption` compile and their
      invariant/round-trip QuickCheck properties are green.
- [ ] The `HARNESS_LIST/START/STOP` opcodes dispatch against a fake
      `TmuxRunner` + `HarnessRegistry`; the capstone drives a fake harness
      through start → liveness → stop → orphan-eviction.
- [ ] All seven tasks committed (one commit per task).
- [ ] **No runtime behavior change** — the existing `seal tui` and
      `seal signal` channels are unaffected (the harness opcodes are
      registered into the ISA registry only in the 6b wiring; 6a ships the
      library + opcode definitions, not the registration).

**Next:** write `docs/superpowers/plans/2026-07-xx-phase-6b-harness-tabs.md`
before starting 6b (the tabs-as-view layer + the `/tab` family + the terse
`/N` grammar + per-conversation relay).