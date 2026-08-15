# Remote-Aware Workdir Filesystem Seam — Design

> **Status:** Draft (round 6, post-review-gate + UIO augmentation). **Branch**:
> `fix/remote-workdir-fs-seam-106`. **Issue**: #106. Closes the remote-mode
> regression in repo-local agent-def and skill discovery, and introduces
> the `UIO` monad as the sole execution context for untrusted opcodes.

## Design review gate (round 1 → round 2)

Round 1 ran 5 reviewers (PM, Architect, Designer, Security, CTO) in parallel.
PM: APPROVED. Architect/Designer/Security/CTO: NEEDS_REVISION. Resolutions:

- **CRITICAL: remote symlink escape** (Security B1, Architect B1) —
  `mkSafePathRemote` is lexical-only; a repo-authored symlink under
  `.agents/` pointing outside the workspace passes lexical containment,
  then the remote `head -c` follows the symlink and exfiltrates content
  (e.g. `/etc/shadow`) into the system prompt. §5's round-1 claim that
  symlinks are rejected on the remote arm was FALSE (real arm follows the
  symlink) and VACUOUS (the in-memory stub can't model symlinks).
  Resolution: the remote arm now performs a `realpath -f` / `readlink -f`
  step BEFORE the read, resolves the symlink on the remote OS, re-runs the
  lexical containment check on the **resolved** absolute path, and rejects
  on escape. This makes the remote arm match the local arm's
  `mkSafePath`-canonicalizes-then-re-checks safety. Added §3.5. The stub
  used in tests now models symlinks (`Map RemotePath StubEntry` where
  `StubEntry = FileContent Text | Symlink RemotePath`) so the
  symlink-escape test is non-vacuous. Added §5.
- **CRITICAL: capability-scoping guarantee absent** (Security B2) — the
  design argued a separate `WorkdirFs` preserves the "Trusted opcode has
  no `UntrustedIO`" invariant but never guaranteed `WorkdirFs` itself
  never reaches opcode scope. Resolution: §3.1 now states the invariant
  explicitly: "`WorkdirFs` is passed ONLY to the discovery backends
  (`workdirAgentDefBackend` / `workdirSkillBackend`); it is never added
  to `AppEnv`, the opcode registry, or any env reachable by an `Opcode`
  implementation." Added a review-checklist item to W6.
- **Confinement-anchor regression** (Architect B1) — today
  `loadProjectAgentDef`/`loadProtocolSubAgent` anchor `mkSafePath` at
  the `.agents/` dir (tight); the round-1 design's single-`WorkspaceRoot`
  `WorkdirFs` anchored at the workdir root (wider). Resolution: workdir-root
  confinement is the **correct** security boundary — all cloned-repo
  content lives under the workdir, and the actual security property is
  "no escape from the workdir to host files" (e.g. `/etc/shadow`), not
  "no escape from `.agents/` to elsewhere-in-the-repo" (reading the repo's
  own `README.md` via a symlink is harmless — it's all cloned content the
  operator chose to clone). Workdir-root confinement is **equivalent** to
  `.agents/`-anchored confinement for the escape-to-host case (both
  reject `/etc/shadow`); it is **wider** only for the
  within-workdir-via-symlink case, which is not a security risk. The
  existing `RepoDiscoverySpec` symlink-escape test (line 239) is updated
  to assert escape-from-**workdir** (not escape-from-`.agents/`), which is
  the real invariant. Documented §3.4.
- **`readBoundedFile` guards on both arms** (Architect B2) — the remote
  arm now does `stat -c %s` FIRST, rejects `WfsOversize` BEFORE `head -c`
  (no wasted round-trip, preserves `Nothing`-on-oversize). Added §3.5 + W2
  DoD.
- **`ApiDeps.adSecurityConfig` required** (Architect B3, Designer Q4) —
  confirmed `ApiDeps` (API.hs:99-117) has NO `SecurityConfig` field;
  `handleSessionAgents` cannot call `mkSessionExec` without it.
  Resolution: adding `adSecurityConfig :: SecurityConfig` to `ApiDeps` is
  a concrete W6 DoD item (not a "verify" hedge), with the wiring site
  (the `ApiDeps` construction site) listed in W6 file scope.
- **`composeDirSystemPrompt`/`readSection`/`loadDirAgentConfig`/`dirMTime`
  migration unspecified** (Designer B1) — these take `FilePath` and call
  `System.Directory`/`TIO.readFile` directly; round-1 only specified the
  top-level `workdirAgentDefBackend` signature change. Resolution: ALL
  workdir-reading functions in `Seal.Agent.Def.Backend` now take
  `WorkdirFs` (internal functions: `readSection`, `loadDirAgentConfig`,
  `dirMTime`, `readBoundedFile` removed-into-`wfsReadFile`; exported:
  `composeDirSystemPrompt` signature changes `FilePath -> ...` →
  `WorkdirFs -> ...` and its test call sites update). Full call-chain
  migration specified §3.6.
- **`wfsListDirectory` asymmetric return** (Designer B2) — existence
  checks return `IO Bool`; `wfsListDirectory` returned
  `IO (Either WorkdirFsErr [Text])`. A missing dir on `wfsDoesDirectoryExist`
  yields `False`; on `wfsListDirectory` yields `Left NotFound`.
  Resolution: `wfsListDirectory` returns `Right []` on a missing directory
  (fail-soft-to-empty, matching the backends' existing
  `if not exists then [] else listDirectory` pattern). `Left` is reserved
  for genuine errors (bad path, SSH failure, stub). Added §3.2.
- **`wfsReadFile` byte-ceiling ambiguous** (Designer B3, CTO B6) — two
  bounds: the `Int` parameter AND internal `maxBootstrapFileBytes`.
  Resolution: the `Int` parameter is REMOVED. The ceiling is fixed
  inside the handle (the operator scan-byte ceiling, captured at
  construction via `mkSessionExec`). Signature:
  `wfsReadFile :: RemotePath -> IO (Either WorkdirFsErr Text)`. The
  `maxBootstrapFileBytes` + `truncateSection` guards apply internally on
  both arms. Added §3.2.
- **`wfsRoot` type gap / unsafe** (CTO B3, Architect, Designer S1) — in
  `mode=remote`, `WorkspaceRoot` would wrap a remote path string, but
  local `mkSafePath` canonicalizes on the LOCAL fs (wrong). Resolution:
  `wfsRoot` is DROPPED. `SessionExec` exposes
  `seWorkspaceRoot :: WorkspaceRoot` (the shared root used by BOTH
  handles — local path for the local arm, remote workspace path string
  for the remote arm; the right `mkSafePath*` is called internally per
  arm, so the type is unambiguous). The ISA registry sources `wsroot`
  from `seWorkspaceRoot`, not from a handle accessor. Added §3.3, §3.7.
- **W6 "no new red" violates TDD** (CTO B1) — the suite won't compile
  between W4/W5 (signature change) and W6 (rewire). Resolution: W4/W5
  keep a temporary back-compat `FilePath` wrapper
  (`workdirAgentDefBackend :: FilePath -> IO AgentDefBackend` that
  delegates to `mkLocalWorkdirFs (WorkspaceRoot wd)`) so existing call
  sites still compile and the suite stays green. W6 removes the wrapper
  and rewires to `seWorkdirFs exec`, with a concrete RED: an `ApiSpec`
  case asserting `GET /api/sessions/:id/agents` returns ≥1 repo-local
  def in `mode=remote` with a stub-remote `WorkdirFs`. Each W is now
  independently verifiable (suite green). Added §6.
- **"existing tests pass unmodified" is false** (CTO B2) — ~12
  `RepoDiscoverySpec` + `BackendSpec` call sites must change to wrap
  `mkLocalWorkdirFs (WorkspaceRoot tmp)`. Resolution: W4/W5 DoD wording
  fixed to "pass with a mechanical call-site adapter"; the call-site
  count is listed in the migration scope. Added §6.
- **§5 must forbid real SSH/IO + name stubs + QuickCheck** (CTO B4) —
  Resolution: §5 now explicitly states "no test makes a real SSH call,
  real network IO, or spawns a subprocess; all remote-arm cases use
  `mkFakeRemoteRunnerRecording` (existing in `Seal.Tools.Exec.Remote`)".
  Added a QuickCheck property for `shellQuote` (every
  `mkSafePathRemote`-validated path, when `shellQuote`'d, contains no
  unescaped shell metacharacter). Added §5.
- **PM suggestions (non-blocking, adopted)** — added a fail-closed use
  case (§1.0 #4) + a skills use case (§1.0 #5) + an evaluation timeline
  to the success metrics (§1.1).
- **SSH round-trip batching** (Architect S1, CTO S1, Designer) —
  acknowledged as a known limitation with a cheap future mitigation
  (single batched `find`/`ls -R`); documented §8. Not blocking for
  pre-alpha (mirrors today's per-call pattern).

## Design review gate (round 2 → round 3)

Round 2 ran 5 reviewers in parallel. PM/Architect/Designer: APPROVED.
Security/CTO: NEEDS_REVISION. Resolutions:

- **CRITICAL: `wfsListDirectory` follows directory symlinks** (Security
  B1) — round-2 exempted `wfsListDirectory` (and the metadata methods)
  from the `realpath` re-check, claiming "listing of a symlinked name
  is not an exfiltration vector." This is FALSE for directory symlinks:
  `ls -1 -- <abspath>` follows a directory symlink by default, so a
  repo-authored `.agents/agents -> /etc` passes lexical containment (the
  NAME is inside the workspace) then `ls -1` lists `/etc`'s filenames,
  which surface as agent-def candidate ids in the dropdown — an
  information disclosure. Resolution: the `realpath -f` re-check is
  applied to `wfsListDirectory` too (resolve the symlink, re-check
  containment on the resolved path, reject `WfsPath` on escape BEFORE
  `ls -1` runs). The metadata methods (`wfsFileSize`, `wfsModificationTime`)
  also get the re-check (defense-in-depth: `stat` follows symlinks and
  discloses target size/mtime). `wfsDoesFileExist`/`wfsDoesDirectoryExist`
  return only a bool (1-bit, no target identity) and are exempt (documented
  as accepted residual). Updated §3.5, §4.
- **CRITICAL: capability-scoping invariant stated falsely + not
  machine-enforced** (Security B2) — round-2 §3.1 claimed `WorkdirFs`
  "goes out of scope before the agent loop / opcode dispatch begin." This
  is FALSE: `WorkdirFs` is captured in `AgentDefBackend` closures
  (`adbRead` closes over `wfsReadFile`) that are wired into
  `buildWebRegistry` and used DURING opcode dispatch. The actual security
  property IS preserved — opcodes receive a typed `AgentDefBackend`
  (`adbRead :: AgentDefId -> IO (Maybe AgentDef)`, not
  `wfsReadFile :: RemotePath -> ...`), so no opcode can call
  `wfsReadFile` with an arbitrary path. But the stated invariant and
  scope-lifetime were wrong, and enforcement was prose-only (a review
  checklist). Resolution: §3.1 corrected to state the REAL invariant
  ("`WorkdirFs` methods are not directly exposed to any opcode; the
  handle may be captured in discovery-backend closures that are used
  during opcode dispatch, but opcodes only receive the backends' typed
  interfaces (`adbRead`/`sbRead` with `AgentDefId`/`SkillId`, never
  `wfsReadFile` with `RemotePath`), so no opcode can read an arbitrary
  workspace path") and a CI-enforced grep check is added to W6
  (mirroring the `CapabilityScopingFail` compile-fail discipline for
  `UntrustedIO`): a grep asserting no `WorkdirFs` field appears in
  `AppEnv`, the ISA registry env records, or any `Opcode`-implementing
  module. The closure-capture is accepted (the typed interface is the
  guard, not scope lifetime). Updated §3.1, W6 DoD.
- **`mkSessionExec` has no `RemoteRunner` injection point** (CTO B1) —
  the round-2 signature `mkSessionExec :: SealPaths -> SecurityConfig ->
  SessionId -> IO SessionExec` calls `mkRealRemoteRunner` internally
  (opaque), so the W6 RED (`ApiSpec` remote-mode `handleSessionAgents`)
  and W3 case (b) cannot be tested under §5's no-real-SSH rule — there's
  no way to inject a stub runner. Resolution: `mkSessionExec` gains a
  `RemoteRunner` parameter (mirroring `mkRemoteUntrustedIO :: SshConfig
  -> RemoteRunner -> UntrustedIO` at `UntrustedIO.hs:472`, which already
  takes a runner). Production wiring sites pass `mkRealRemoteRunner`;
  tests pass `mkFakeRemoteRunnerRecording`. The back-compat wrapper
  `mkSessionUntrustedIO` threads `mkRealRemoteRunner` through (preserving
  the current opaque-runner behavior). The single `RemoteRunner` is
  shared between `seUntrustedIO` and `seWorkdirFs` (one SSH connection,
  not two). The fail-closed stub path does NOT construct a runner at all
  (returns both stubs before reaching the runner). Updated §3.3, §3.7,
  W3 DoD, W6 DoD.
- **CTO non-blocking suggestions (adopted)**:
  - Back-compat wrapper naming pinned to the distinct name
    `workdirAgentDefBackendFromPath` (during W4/W5, the EXPORTED name
    keeps the `FilePath` signature; the new `WorkdirFs`-taking function
    is `workdirAgentDefBackendFs`; W6 swaps the names). Updated W4/W5
    DoD.
  - Call-site counts corrected: `RepoDiscoverySpec` has 13 workdir
    call sites (9 `workdirAgentDefBackend` + 4 `workdirSkillBackend`);
    `BackendSpec` has 2 (`composeDirSystemPrompt`); `SkillBackendSpec`
    has 0 (it tests the user store only). Total ≈15, not ≈20. Updated
    §3.6, W4/W5 DoD.
  - `ApiDeps.adSecurityConfig` construction is a WIDE mechanical change:
    ~20 `ApiDeps` literals in `ApiSpec.hs` + `ServerSpec.hs:61` +
    `Phase7aSpec.hs:75/129` + `Serve.hs:243` each add the field. Listed
    explicitly in W6 file scope.
  - Symlink-escape test fixture: the round-2 fixture target was INSIDE
    the workdir (vacuous under workdir-anchored confinement). The fixture
    target now moves OUTSIDE the workdir root (e.g.
    `/tmp/seal-escape-target-<unique>/secret.txt`, not under `tmp`), so
    the updated assertion is non-vacuous. Plus a within-workdir-symlink-
    allowed test (target inside workdir, outside `.agents/`). Updated W4
    DoD.
  - `SessionWorkdirSpec` existing path corrected to
    `test/Seal/Config/WorkdirSpec.hs` (module `Seal.Config.WorkdirSpec`,
    importing `Seal.Session.Workdir`). Updated W3 DoD.
  - W6 secondary gateway/channel integration test hedge ("if feasible
    without a live provider") dropped — the primary `ApiSpec` RED is
    concrete; the secondary is a W7 stretch goal, not a W6 DoD item.
- **Architect non-blocking suggestions (adopted)**: §3.5/§4 now
  explicitly note `wfsListDirectory`/`wfsFileSize`/`wfsModificationTime`
  get the `realpath` re-check (per Security B1 resolution above); the
  accepted-residual for `wfsDoesFileExist`/`wfsDoesDirectoryExist`
  (1-bit bool, no target identity) is documented. The `ApiDeps`
  construction site is pinned (CTO's count confirms it spans multiple
  files — listed in W6).

## Augmentation: the `UIO` monad (round 3 → round 4)

After round-3 approval, the design is augmented with a new restricted
monad `UIO` that becomes the **sole execution context for untrusted
opcodes**, turning the "don't import `System.Directory`/don't shell
out in opcodes" convention into a **compile-time guarantee**. This
categorically eliminates future local/remote parity gaps: there is one
construction path per mode, and the only IO an untrusted opcode can
perform is the `UIO`-lifted `UntrustedIO` (+ `CloneDeps`) surface.

### Why `UIO`

Round-3 relies on a *convention* ("opcode bodies must not call
`liftIO`/import `System.Directory`") + a compile-fail fixture that
asserts the *absence* of an import. A restricted monad makes the
guarantee **structural**:

- `UIO` exposes `Functor`, `Applicative`, `Monad` — but **NOT**
  `MonadIO`, `MonadReader`, `MonadThrow`, `Katip`. An opcode body typed
  `UIO OpResult` literally cannot call `liftIO`, `ask`, `logMsg`, or
  `throwM` — it won't compile.
- `UIO`'s only IO surface is the `UntrustedIO` operations, lifted as
  module-level `UIO`-typed functions (e.g.
  `uioRead :: RemotePath -> Int -> UIO (Either UntrustedErr
  LineWindow)`). No `liftIO (uioReadFile uio ...)` — just
  `uioRead path n`. (`CloneDeps` surface lives in a separate
  `Seal.Tools.Exec.UIOGit` module — §3.11.)
- `UIO` can only be constructed by `mkLocalUIO` or `mkRemoteUIO` (the
  two smart constructors mirroring `mode=local`/`mode=remote`). The
  constructor is unexported. There is no other way to obtain a `UIO`
  execution context.
- This **categorically kills the regression class**: any code that
  reads the workdir or shells out MUST run in `UIO`, and `UIO` is
  backend-selected once at construction — so a feature that works in
  `mode=local` works in `mode=remote` by construction (the
  local/remote selection happens at `mkUIO*`, not scattered across
  opcode bodies).

### Feasibility (grounded in the codebase)

An audit of every untrusted opcode (`File.hs`, `Shell.hs`, `Search.hs`,
`Bin.hs`, `Process.hs`, `Git.hs`) found:

- **Zero uses of `ask`/`asks`/`MonadReader Env`.** `Env` (the `AppEnv`)
  carries only log level, host/port, logger — none read by opcodes.
- **Zero transcript writes.** ACK-before-execute is the dispatcher's job
  (`Dispatch.hs:67`); the opcode returns `OpResult` (a pure value).
- **Zero Katip logging** in opcode bodies.
- **`UntrustedIO` is already an explicit `uoRun` argument** (not an env
  read) — it slots cleanly into a `UIO` that carries it internally.
- `WorkspaceRoot`/`SecurityPolicy`/`operatorCeiling` are **closure
  parameters** captured at opcode construction (`buildWebRegistry`),
  not runtime env reads. They stay closure parameters under `UIO`
  (the `UIO` context need not carry them). `CloneDeps` is the one
  exception — it moves into `UIOEnv` (§3.10/§3.11; Git opcodes use
  `uioCd*` from the `UIO` context), but it stays a Git closure param
  through W-A3 (W6 drops it when the dispatcher threads a real
  `seUIOEnv`).
- The one wrinkle — Git's `CloneDeps` (repo registry, vault helpers via
  `liftIO`) — is a closure-captured capability, not an env read. It
  lifts into `UIO` the same way `UntrustedIO` does (§3.11).

`OpResult` is pure; constructing it needs no `App`/`IO`. The
dispatcher stays in `App` (it does the ACK + transcript + logging) and
invokes the opcode's `UIO` action *after* `tfwRecordAndAck` completes.

### Design review gate (round 4 → round 5)

Round 4 ran 5 reviewers in parallel. PM: APPROVED.
Architect/Designer/Security/CTO: NEEDS_REVISION. The round-4 `UIO`
sections were internally inconsistent. Resolutions:

- **CRITICAL: `CloneDeps` placement contradiction** (Designer B1,
  Security B1, Architect S4) — round-4 put `CloneDeps` in `UIOEnv`
  (§3.10/§3.11) AND as a closure param (augmentation block + W-A3 DoD)
  simultaneously — mutually exclusive. Resolution: `CloneDeps` goes
  **into `UIOEnv`** (per the user's "lift CloneDeps into UIO too"
  decision); Git opcode constructors (`gitFetchOp`/`gitPullOp`/
  `gitPushOp`/`setupRepoOp`) **DROP** their `CloneDeps` parameter and
  use the `uioCd*` module-level functions (§3.11) instead. The
  augmentation block's "stay closure parameters under UIO" sentence is
  removed; W-A3 DoD updated (Git constructors lose `CloneDeps`;
  `buildWebRegistry` drops `cloneDeps` from the closure params).
- **CRITICAL: `CloneDeps` capability-escalation** (Security B1) —
  putting `uioCd*` in a `MonadUIO` class (round 4) made them reachable
  by ALL opcodes (round-3 had them lexically scoped to Git only).
  Resolution (two parts): (a) `MonadUIO` class is **dropped** in favor
  of **module-level `UIO`-typed functions** (Architect S1, Designer —
  single-instance class was a smell; module functions are idiomatic for
  this codebase); the `uio*` functions are in `Seal.Tools.Exec.UIO`
  (in scope for all opcode modules), but the `uioCd*` functions are in
  a **separate `Seal.Tools.Exec.UIOGit` module imported ONLY by
  `Seal.ISA.Ops.Git`** (lexical scoping restored — a non-Git opcode
  that wants `uioCdRepoRegList` must add an import, caught at review).
  (b) A **CI grep guard** (W-A3 DoD) asserts `uioCd*` /
  `Seal.Tools.Exec.UIOGit` is referenced only from
  `src/Seal/ISA/Ops/Git.hs` (+ the definition site) — mirroring the W6
  `WorkdirFs` discipline. The `uioCd*` functions take a `CloneDeps`
  arg explicitly (not from a class), so they're scoped by import +
  argument threading, not class membership.
- **`runUIOWithEnv` seam unspecified** (Architect B1, Designer S1) —
  the dispatcher and `WorkdirFs`'s remote arm need to run a `UIO`
  action with a pre-built `UIOEnv` (not re-construct per call).
  Resolution: `runUIOWithEnv :: UIOEnv -> UIO a -> IO a` is exported
  from `Seal.Tools.Exec.UIO` (to `Seal.ISA.Dispatch`,
  `Seal.Session.Workdir`, `Seal.Tools.Exec.WorkdirFs` — NOT to any
  module under `src/Seal/ISA/Ops/`, enforced by the W6 grep check).
  The smart constructors delegate:
  `mkLocalUIO ws action = runUIOWithEnv (buildLocalUIOEnv ws) action`.
  `UIOEnv` stays non-exported (opaque) — no caller can forge one;
  only `mkSessionExec`/`mkLocalUIO`/`mkRemoteUIO`/`mkUIOStub` build it.
  Pinned in §3.10.
- **Work-unit ordering contradiction** (Architect B2) — W3 (round-3
  `seUntrustedIO`) and W-A4 (round-4 `seUIOEnv`) described the same
  record mutably; W2 and W-A4 both rewrote `mkRemoteWorkdirFs`.
  Resolution: W-A4 is **folded into W2+W3** (W2 owns
  `mkRemoteWorkdirFs`-on-`UIO`; W3 owns `mkSessionExec`-constructs-
  `UIOEnv`). W-A4 is dropped. Ordering: W-A1 (`UIO`), W-A2 (fixtures),
  W-A3 (migrate opcodes), W1 (`WorkdirFs` local/stub), W2
  (`WorkdirFs` remote arm on `UIO`), W3 (`mkSessionExec`→`UIOEnv`),
  W4, W5, W6, W7. §6 + §7 updated.
- **`Maybe GitRepo` undefined/unconsumed** (Designer B2) — `GitRepo`
  doesn't exist; the workdir is 0-or-many repos (multiple `SETUP_REPO`
  clones). Resolution: `Maybe GitRepo` is **dropped** from
  `mkLocalUIO`/`mkRemoteUIO`. Git opcodes resolve the repo at runtime
  via `CloneDeps` (now in `UIOEnv`), not a constructor param. The
  smart constructors take `WorkspaceRoot` (+ `SshConfig`/`RemoteRunner`
  for remote) only.
- **`GitEnv` vs `CloneEnv`** (Designer B3) — typo. Resolution: §3.11
  uses `CloneEnv` (the existing type at `Clone.hs:277`), not `GitEnv`.
- **Naming consistency** (Designer S4) — `mkUIOLocal`/`mkUIORemote`
  (mode after type) vs existing `mkLocalUntrustedIO`/`mkRemoteUntrustedIO`
  (mode before). Resolution: renamed to `mkLocalUIO`/`mkRemoteUIO`/
  `mkUIOStub` (mode before, matching the existing convention).
- **PM suggestions (adopted)**: §1.1 gains a UIO metric ("no untrusted
  opcode module imports `System.Directory`/`System.Process`/
  `Control.Monad.IO.Class` — enforced by `UIOUnrestrictedFail` (W-A2)
  + verified at W7"). §2 Non-Goals adds: "`UIO` is not a general
  effect system; it's scoped to untrusted-opcode execution. Trusted/
  Audited opcodes and control-plane code continue to use `ReaderT
  AppEnv IO`."
- **Architect non-blocking (adopted)**: §3.12's "inherits UIO's SafePath
  confinement by construction" reworded to "inherits UIO's transport
  (one shared `RemoteRunner`); file-path confinement remains
  `WorkdirFs`'s own `mkSafePathRemote` + `realpath` re-check, layered
  on `UIO`'s CWD confinement." `buildWebRegistry` W-A3 DoD tightened
  ("`uoRun` signature changes; `UntrustedIO` no longer a runtime arg;
  closure params `wsRoot`/`policy`/`operatorCeiling` unchanged;
  `cloneDeps` dropped — Git opcodes use `uioCd*`"). `aeUntrustedIO`
  → `aeUIOEnv` field rename pinned in W-A3.

## Design review gate (round 5 → round 6)

Round 5 ran 5 reviewers. PM/Security/Architect: APPROVED.
Designer/CTO: NEEDS_REVISION — both with the same root cause (the
W-A3→W3 dependency contradiction) plus two doc fixes. Resolutions:

- **CRITICAL: W-A3→W3 dependency contradiction (CTO B1, Architect B2)** —
  round-5 W-A3 DoD said `aeUntrustedIO → aeUIOEnv` (field rename + type
  change) AND "keep `uoRunLegacy` so the dispatcher compiles before
  it's rewired" — mutually exclusive (the rename needs a production
  `UIOEnv` source that only W3's `mkSessionExec` provides; ~30 test
  `AgentEnv` sites + 4 production sites would break). Resolution
  (option (b) from the CTO): **defer the `aeUIOEnv` rename + dispatch
  `runUIOWithEnv` change to W6** (not W3). W-A3 migrates opcode
  *bodies* to `UIO` (the `uoRun` field type changes to `Value -> UIO
  OpResult`); the dispatcher keeps the old `UntrustedIO`-based path
  via `uoRunLegacy`; `aeUntrustedIO` stays `UntrustedIO` through
  W-A3/W1/W2/W3. W6 does the rename + dispatch rewire + drops
  `uoRunLegacy`. The suite is green after each W.
- **`uoRunLegacy` CloneDeps gap (CTO S3)** — `uoRunLegacy ::
  UntrustedIO -> Maybe CloneDeps -> Value -> App OpResult` (added the
  `Maybe CloneDeps` arg). For Git, the real `CloneDeps` (still
  closure-captured through W-A3) is passed; for non-Git, `Nothing` and
  a fail-closed stub `CloneDeps` is built internally. Git constructors
  KEEP `CloneDeps` through W-A3 (drop in W6). Pinned in W-A3 DoD.
- **W6 migration scope expanded (CTO B2)** — W6 file scope now
  includes `src/Seal/ISA/Dispatch.hs` (rewire), `src/Seal/Agent/Loop.hs`
  + `src/Seal/Agent/Runtime/Delegation/Worker.hs` (field rename), and
  the ~30 test `AgentEnv` construction sites (`LoopSpec`, `Phase2bSpec`,
  `Phase5Spec`, `Phase7aSpec`, `WiringSpec`, `SignalRunSpec`, `CliSpec`).
- **CloneDeps placement prose (Designer B1)** — the augmentation
  narrative still said "stay closure parameters under UIO" for
  `CloneDeps` (contradicting §3.10/§3.11). Fixed: `CloneDeps` is the
  one exception (moves into `UIOEnv`; stays a Git closure param through
  W-A3, dropped in W6). `WorkspaceRoot`/`SecurityPolicy`/
  `operatorCeiling` stay closure params.
- **`UIOEnv` in W6 grep (Designer S1)** — W6 DoD grep now asserts no
  `WorkdirFs` AND no `UIOEnv` field in `AppEnv`/registry/opcode
  modules.
- **`mkTestUIOEnv` scope (Designer S2)** — pinned to the `Test`-prefix
  naming gate (matching `mkFakeRemoteRunnerRecording`); `#ifdef TESTING`
  dropped (the codebase has zero such guards). Exported to both
  `src/` (`uoRunLegacy` uses it) and tests.
- **Security non-blocking (adopted)**: the W-A3 CI grep uses OR logic
  (module path string `Seal.Tools.Exec.UIOGit` catches qualified/aliased
  imports; `uioCd` prefix catches re-exports).

### Design decisions (UIO, round 5 — coherent)

- **`UIO` lifts `UntrustedIO` + `CloneDeps` operations as module-level
  `UIO`-typed functions** (no `MonadUIO` class; no `liftIO` in opcode
  bodies). `uoRun`'s signature changes from
  `UntrustedIO -> Value -> App OpResult` to `Value -> UIO OpResult`
  (the `UntrustedIO` + `CloneDeps` are carried by the `UIO` context,
  not passed). Git's `CloneDeps`-shaped operations lift to `uioCd*`
  functions in a separate `Seal.Tools.Exec.UIOGit` module (imported
  only by `Seal.ISA.Ops.Git` — lexical scoping restored).
- **All untrusted opcodes (incl. Git) migrate to `UIO`.** `CloneDeps`
  is in `UIOEnv`; Git opcode constructors DROP their `CloneDeps` param
  (they use `uioCd*` from the `UIO` context). (Per round-6: Git keeps
  `CloneDeps` as a closure param through W-A3 — the dispatcher threads
  it via `uoRunLegacy`; W6 drops it when `seUIOEnv` is wired.)
- **`WorkdirFs` stays a separate handle but its remote arm is
  implemented on `UIO`'s `uioShellExec`** (§3.12). One SSH transport
  (`UIO`'s `RemoteRunner`, shared via `runUIOWithEnv`); `WorkdirFs`
  inherits the transport + CWD confinement; file-path confinement
  remains `WorkdirFs`'s own `mkSafePathRemote` + `realpath` re-check.
- **Two smart constructors + stub**: `mkLocalUIO :: WorkspaceRoot ->
  UIO a -> IO a` and `mkRemoteUIO :: SshConfig -> RemoteRunner ->
  WorkspaceRoot -> UIO a -> IO a` (mode before type, matching
  `mkLocalUntrustedIO`/`mkRemoteUntrustedIO`). `mkUIOStub :: UIO a ->
  IO a` for fail-closed. `runUIOWithEnv :: UIOEnv -> UIO a -> IO a`
  exported to dispatcher/`WorkdirFs` (not opcodes). Constructor +
  `runUIO` + `UIOEnv` unexported; only the smart constructors +
  `runUIOWithEnv` are.
- **No `Maybe GitRepo`** — dropped (doesn't connect to how Git
  opcodes work; they resolve the repo via `CloneDeps`).
- **Work units**: W-A1 (`UIO`), W-A2 (fixtures), W-A3 (migrate
  opcodes), W1-W7 (`WorkdirFs`/discovery, with W2/W3 round-5-native
  on `UIOEnv`). W-A4 is folded into W2+W3.

## 1. Problem

### 1.0 User stories

1. **Operator running `mode=remote`** (WHO) — when they create a new tab
   for a repo shipping `.agents/agents.md` (WHEN) — wants the project
   agent definition injected into the system prompt on the first turn
   (WANTS-TO) — so the session behaves as the repo author intended
   without manual import (SO-THAT).
2. **Operator running `mode=remote`** (WHO) — when they open the Agent
   dropdown for a remote-mode session (WHEN) — wants repo-local
   sub-agents listed (WANTS-TO) — so they can pick a persona the repo
   ships (SO-THAT).
3. **Operator running `mode=remote`** (WHO) — when they start a session
   on a repo shipping `.agents/skills/` (WHEN) — wants repo-shipped
   skills available via `SKILL_LOAD` on the first turn (WANTS-TO) — so
   the agent has the tooling the repo author intended without manual
   skill import (SO-THAT).
4. **Operator with an unreachable/misconfigured remote** (WHO) — when
   `mode=remote` is set but the SSH target is down or misconfigured
   (WHEN) — wants the session to boot with a clear distinction between
   "repo has no `.agents/`" and "remote unreachable, discovery failed
   closed" (WANTS-TO) — so they can diagnose the config issue rather
   than silently operating without the repo's intended persona
   (SO-THAT).
5. **Maintainer adding a workspace-derived store** (WHO) — when they
   wire a new backend that reads cloned-repo files (WHEN) — wants a
   single capability to call (WANTS-TO) — so it works in both
   `mode=local` and `mode=remote` by construction, not by remembering to
   (SO-THAT).

### 1.1 Success metrics (user-focused, measurable)

- With `mode=remote` and a repo shipping `.agents/agents.md`, the first
  turn's system prompt includes the project agent def's body. **Evaluated
  at**: W4 remote-arm discovery test (backend level) + W6 `ApiSpec`
  remote-mode case (API level, the user-visible surface).
- With `mode=remote`, `GET /api/sessions/:id/agents` returns ≥1
  repo-local def for a repo shipping `.agents/`. **Evaluated at**: W6
  `ApiSpec` remote-mode case.
- With `mode=remote`, `SKILL_LOAD` of a repo-shipped skill resolves on
  the first turn. **Evaluated at**: W5 remote-arm skill discovery test.
- `mode=local` behavior is byte-for-byte unchanged. **Evaluated at**: W4
  + W5 local-arm parity tests (existing `BackendSpec` /
  `RepoDiscoverySpec` / `SkillBackendSpec` with mechanical adapter) at the
  W7 gate.
- Fail-closed: a misconfigured/unreachable remote yields empty discovery
  (no agents/skills) and the session still boots (chat + Trusted opcodes
  work). **Evaluated at**: W3 `SessionWorkdirSpec` fail-closed case.
- **UIO restriction (round 5)**: no untrusted opcode module under
  `src/Seal/ISA/Ops/` imports `System.Directory`/`System.Process`/
  `Control.Monad.IO.Class`, and none calls `liftIO`/`ask`/`throwM` —
  enforced by the `UIOUnrestrictedFail` compile-fail fixture (W-A2) and
  verified at the W7 gate. **Evaluated at**: W-A2 fixtures + W7 gate.

### 1.2 The regression

In `mode=remote`, `SETUP_REPO` clones the repository onto the **remote
machine** via the `UntrustedIO` capability handle (correct — the
workspace lives on the untrusted plane per the two-plane split). However,
the agent-def and skill backends discover repo-shipped definitions by
reading the workdir through **direct local filesystem access**
(`System.Directory` + `Data.Text.IO.readFile`), not through any
remote-aware abstraction.

The wiring at `src/Seal/Gateway/Send.hs:461-476` computes the workdir
twice, inconsistently:

1. **Line 461** — `mkSessionUntrustedIO paths secCfg sid`:
   **remote-aware**. In `mode=remote` it creates the workdir on the
   remote machine (`ensureRemoteSessionWorkdir` over SSH) and points
   `uioReadFile` at it. `SETUP_REPO` clones there. ✅
2. **Lines 462, 474-476** — `ensureSessionWorkdir paths sid` →
   `workdirAgentDefBackend wd` / `Skill.workdirSkillBackend wd`:
   **local-only**. Always `~/.seal/cache/workdirs/<sid>` on the control
   plane, read via `System.Directory` + `TIO.readFile`. In `mode=remote`
   this local dir is empty (only `mkdir`'d locally by
   `ensureSessionWorkdir`). ❌

The clone lands on the remote machine (step 1); agent-def discovery
scans the local machine (step 2), which is empty. The repo's
`.agents/agents.md` never reaches the system prompt. The same local-FS
pattern is repeated at every turn-entry wiring site:

- `src/Seal/Gateway/API.hs:793-794` (`handleSessionAgents` — populates
  the frontend agent picker).
- `src/Seal/Channels/Loop.hs:793, 806-808, 986-996, 1159, 1206`
  (channel turns).
- `src/Seal/Channel/Cli.hs:432, 562-564, 595-601, 641-649, 680-687`
  (CLI turns).

### 1.3 Root-cause shape

There is **no shared abstraction** between the two workdir computations.
`UntrustedIO` is the existing local/remote-agnostic capability handle,
but:

- Its only file-read method returns a paged `LineWindow`, not raw `Text`:
  ```haskell
  uioReadFile :: RemotePath -> Int -> IO (Either UntrustedErr LineWindow)
  ```
  The agent-def/skill backends want whole-file contents (frontmatter
  parse, bootstrap composition), not line-oriented windows.
- It has no `doesFileExist`/`doesDirectoryExist`/`listDirectory`/
  `fileSize`/`getModificationTime` equivalents — the backends call these
  on the local `System.Directory` API directly.
- It is not threaded into the backends; they take a bare `FilePath`.

## 2. Goals / Non-Goals

**Goals:**
1. A single unified abstraction for retrieving information from files
   (and file metadata) on the untrusted execution machine that works
   whether that machine is local (`mode=local`) or remote over SSH
   (`mode=remote`).
2. Rewire `workdirAgentDefBackend` and `workdirSkillBackend` to use the
   abstraction exclusively — no direct `System.Directory`/`TIO.readFile`
   for workspace-derived content (enforced by a compile-fail fixture +
   grep check).
3. Update all turn-entry wiring sites to source the abstraction from
   the same `mkSessionExec` selection that builds `UntrustedIO`.
4. Preserve SafePath confinement on both arms (local: `mkSafePath`;
   remote: `mkSafePathRemote` + a `realpath`-based symlink-resolution
   re-check so remote symlink escape is rejected).
5. `mode=local` behavior unchanged.

**Non-Goals:**
- The user's own agent-def store (`markdownAgentDefBackend` over
  `~/.seal/agents/`) stays local — it is control-plane data, not
  workspace-derived.
- The remote executor SSH transport itself (already works — `SETUP_REPO`
  clones correctly in remote mode).
- Any change to `UntrustedIO`'s existing paged `uioReadFile` API
  (additive only — a new handle, no signature change to existing
  methods).
- Writing repo-local agent defs/skills (immutable, per the existing
  design).
- The frontend (the dropdown already re-fetches on
  `broadcastAgentDefsChanged`; once the backend returns the right list,
  the frontend is correct).
- SSH round-trip batching (a single batched `find`/`ls -R` to amortize
  discovery into one round-trip) — acknowledged as future work (§8), not
  in scope for this regression fix.
- **`UIO` as a general effect system.** `UIO` is NOT a general-purpose
  effect system; it's scoped exclusively to untrusted-opcode execution.
  Trusted/Audited opcodes and control-plane code (the dispatcher,
  wiring, discovery backends) continue to use `ReaderT AppEnv IO`
  (`App`). Lifting `UIO` beyond untrusted opcodes is out of scope.

## 3. Design decisions

### 3.1 A new `WorkdirFs` capability handle (not an `UntrustedIO` extension)

**Decision**: introduce a new capability handle, `WorkdirFs`, constructed
alongside `UntrustedIO` by `mkSessionExec` (§3.3), exposing the small
filesystem-vocabulary the discovery backends need. Thread it into
`workdirAgentDefBackend` / `workdirSkillBackend` in place of the bare
`FilePath`.

**Why a new handle, not extending `UntrustedIO`:** `UntrustedIO` is the
capability handle for **Untrusted opcodes** — its constructor is
unexported and its methods are scoped so a Trusted opcode that shells
out fails to compile. The agent-def/skill backends are **not opcodes**;
they run on the control plane during prompt assembly, which is Trusted
territory. Folding discovery reads into `UntrustedIO` would blur the
capability-scoping boundary (a Trusted code path would hold an
`UntrustedIO`). A separate, narrower handle keeps the scoping invariant
intact: `UntrustedIO` remains opcode-only; `WorkdirFs` is the
discovery-only seam.

**Capability-scoping invariant (CRITICAL):** `WorkdirFs` methods are
**not directly exposed to any opcode.** The handle is constructed by
`mkSessionExec` and `seWorkdirFs` is passed ONLY to the discovery
backends (`workdirAgentDefBackend` / `workdirSkillBackend`). The handle
**may be captured in discovery-backend closures** (`adbRead` closes over
`wfsReadFile`) that are wired into `buildWebRegistry` and used DURING
opcode dispatch — so the handle does NOT "go out of scope before opcode
dispatch" (an earlier draft claimed this; it was wrong). The actual
security property is: opcodes receive the backends' **typed interfaces**
(`adbRead :: AgentDefId -> IO (Maybe AgentDef)`, `sbRead :: SkillId ->
IO (Maybe Skill)`, never `wfsReadFile :: RemotePath -> ...`), so no
opcode can read an arbitrary workspace path — it can only ask for a
specific agent/skill by its validated id. This preserves the
`FILE_READ` opcode's ACK-before-execute + transcript + ceiling as the
sole path for arbitrary workspace reads.

`WorkdirFs` is **never** added to `AppEnv`, the ISA registry's env
records, or any env reachable by an `Opcode` implementation's
construction. This is **CI-enforced** (not just a human review
checklist): W6 adds a grep check (mirroring the
`Seal.Tools.Exec.CapabilityScopingFail` compile-fail discipline for
`UntrustedIO`) asserting no `WorkdirFs` field appears in `AppEnv`,
the ISA registry env record types, or any module under
`src/Seal/ISA/Ops/` (the opcode implementations). The closure-capture
in discovery backends is accepted — the typed backend interface is the
guard, not scope lifetime.

### 3.2 The `WorkdirFs` interface

```haskell
-- | A local/remote-agnostic, SafePath-confined filesystem vocabulary for
-- workspace-derived discovery (agent defs, skills). Constructed by
-- 'mkSessionExec' alongside 'UntrustedIO'; the constructor is NOT
-- exported. The local arm reads via 'System.Directory'/'Data.Text.IO';
-- the remote arm reads via SSH ('RemoteRunner'). Every method validates
-- the path (local: 'mkSafePath'; remote: 'mkSafePathRemote' + a
-- 'realpath'-based symlink-resolution re-check) before any IO.
data WorkdirFs = WorkdirFs
  { wfsReadFile  :: RemotePath -> IO (Either WorkdirFsErr Text)
    -- ^ Read a workspace-relative file as raw 'Text', bounded by the
    -- operator scan-byte ceiling (captured at construction, NOT a
    -- per-call parameter) and 'maxBootstrapFileBytes' (applied
    -- internally on both arms). Returns the whole file (no paging, no
    -- 'LineWindow'). Path validated + confined + (remote arm)
    -- symlink-resolved internally.

  , wfsDoesFileExist      :: RemotePath -> IO Bool
  , wfsDoesDirectoryExist :: RemotePath -> IO Bool
  , wfsListDirectory      :: RemotePath -> IO (Either WorkdirFsErr [Text])
    -- ^ List the immediate children of a workspace-relative directory
    -- (names only, not paths). A MISSING directory yields 'Right []'
    -- (fail-soft-to-empty — matches the backends' existing
    -- @if not exists then [] else listDirectory@ pattern, eliminating
    -- per-call-site error handling). A genuine error (bad path, SSH
    -- failure, stub) yields 'Left'. Caller-side sorting.

  , wfsFileSize           :: RemotePath -> IO (Either WorkdirFsErr Integer)
  , wfsModificationTime   :: RemotePath -> IO (Either WorkdirFsErr UTCTime)
  }
```

**Rationale for the method set:** these are exactly the
`System.Directory` calls the two backends make today
(`doesFileExist`, `doesDirectoryExist`, `listDirectory`, `getFileSize`,
`getModificationTime`) plus a bounded raw read. No more — the discovery
vocabulary is small and stable. `wfsFileSize` is needed by the internal
`wfsReadFile` oversize guard (stat-first on both arms) AND is NOT dead
surface (the remote arm's `wfsReadFile` calls it internally; backends
don't call it directly after the rewire — it's an internal helper
exposed for the oversize guard and potential future diagnostics).

**`WorkdirFsErr` ADT** (pinned for exhaustive pattern-match under
`-Wall -Werror`):
```haskell
data WorkdirFsErr
  = WfsPath !PathError      -- SafePath confinement failure (escape, blocked name)
  | WfsNotFound             -- file does not exist (for wfsReadFile; existence checks return Bool)
  | WfsOversize             -- file exceeds maxBootstrapFileBytes
  | WfsIo !Text             -- local IO error or remote parse failure
  | WfsExec !Text            -- remote SSH failure (exec error, connection refused)
  | WfsStub                  -- fail-closed stub (misconfigured/unreachable remote)
```

**Backend error-folding (no behavior change in `mode=local`):** the
backends fold ALL `WorkdirFsErr` constructors into the same
`Nothing`/defaults they produce today. Both `WfsOversize` and
`WfsNotFound` → `Nothing` (skip), matching today's `readBoundedFile`
which returns `Nothing` on both. The pattern-match is exhaustive and
exists for future diagnostics, NOT for behavioral branching. Table:

| Constructor | `loadProjectAgentDef` / `readAgentDef` / `readSection` | `listWorkdirAgentDefs` / `listWorkdirSkills` |
|---|---|---|
| `WfsPath` | `Nothing` (skip) | `[]` (skip this entry) |
| `WfsNotFound` | `Nothing` (skip) | n/a (existence checks return `False`) |
| `WfsOversize` | `Nothing` (skip) | n/a |
| `WfsIo` | `Nothing` (skip) | `[]` (skip) |
| `WfsExec` | `Nothing` (skip) | `[]` (skip) |
| `WfsStub` | `Nothing` (skip) | `[]` (skip) |

**Naming convention note:** `WorkdirFs` field names use the `wfs`
short-prefix convention (mirroring `UntrustedIO`'s `uio` prefix and
`AgentDefBackend`'s `adb` prefix), NOT the `_<type>_<field>` record
convention from AGENTS.md. This is the established capability-handle
convention in this codebase (handles of IO actions use short prefixes;
data records use `_<type>_<field>`). Fields are functions (IO actions),
so `!` strictness annotations are no-ops (lifted) — omitted.

### 3.3 Construction — `mkSessionExec` mirrors and folds `mkSessionUntrustedIO`

**Decision**: a new `mkSessionExec :: SealPaths -> SecurityConfig ->
SessionId -> RemoteRunner -> IO SessionExec` in `Seal.Session.Workdir`,
structurally identical to `mkSessionUntrustedIO` (same three cases, same
fail-closed stub) EXCEPT it takes an explicit `RemoteRunner` parameter
(mirroring `mkRemoteUntrustedIO :: SshConfig -> RemoteRunner ->
UntrustedIO` at `UntrustedIO.hs:472`, which already takes a runner).
The two constructors share the same mode-resolution
(`untrustedExecConfigFromSecurity`) and the same remote-workdir creation
(`ensureRemoteSessionWorkdir`). Production wiring sites pass
`mkRealRemoteRunner`; tests pass `mkFakeRemoteRunnerRecording` (so the
W3 case (b) + W6 RED are testable under §5's no-real-SSH rule).

**`SessionExec` record** (round-5 — `seUIOEnv` replaces `seUntrustedIO`;
see §3.12 for the round-4→5 UIO augmentation):
```haskell
data SessionExec = SessionExec
  { seUIOEnv        :: UIOEnv
    -- ^ Carries UntrustedIO + CloneDeps; the dispatcher runs untrusted
    -- opcodes in 'UIO' via 'runUIOWithEnv seUIOEnv'. (Round 5: replaces
    -- round-3's seUntrustedIO.)
  , seWorkdirFs     :: WorkdirFs
    -- ^ For discovery (remote arm built on seUIOEnv via runUIOWithEnv).
  , seWorkspaceRoot :: WorkspaceRoot
    -- ^ The shared workspace root used by UIO + WorkdirFs + the ISA
    -- registry (local path for the local arm, remote workspace path
    -- string for the remote arm). The ISA registry sources its 'wsroot'
    -- from here. This avoids the type-confusion of extracting a root
    -- from 'WorkdirFs' (which would be a remote path string in remote
    -- mode, unsafe to feed to local 'mkSafePath').
  }
```

**Shared workspace root + shared `RemoteRunner`:** `mkSessionExec` runs
the mode resolution and remote-workdir creation **once**, then builds
`UIOEnv` + `WorkdirFs` against the same `WorkspaceRoot` and the same
`SshConfig`, sharing the **single `RemoteRunner` passed in** between
`seUIOEnv` (UIO's `UntrustedIO`) and `seWorkdirFs` (via
`runUIOWithEnv`) — one SSH connection, not two. The fail-closed stub
path does NOT construct/invoke a runner at all (returns both stubs
before reaching the runner).

**Back-compat:** `mkSessionUntrustedIO` is kept as a thin wrapper
(`\exec -> uieUntrustedIO (seUIOEnv exec) <$> mkSessionExec paths secCfg
sid mkRealRemoteRunner`) so existing opcode-wiring sites that only
need the `UntrustedIO` handle are unchanged (the wrapper threads
`mkRealRemoteRunner`, preserving the current opaque-runner behavior).
The wrapper preserves the EXACT current semantics (same workdir
created, same stub on failure); `SessionWorkdirSpec` asserts
`mkSessionUntrustedIO` and
`(uieUntrustedIO . seUIOEnv <$> mkSessionExec ... mkRealRemoteRunner)`
yield equivalent `UntrustedIO` handles.

**Fail-closed contract:** on ANY workdir-creation failure (local mkdir
fail, remote unreachable, remote mkdir fail, bad remote path), `mkSessionExec`
returns `SessionExec` with **both** handles as stubs and `seWorkspaceRoot`
as a fail-closed root — never a mix of real-`UntrustedIO` + stub-`WorkdirFs`
or vice versa. Both stubs or both real.

**Stub:** `mkWorkdirFsStub` returns a `WorkdirFs` whose every read yields
`Left WfsStub` and every existence check yields `False` — so a
misconfigured remote session discovers no agents/skills and fails closed,
mirroring `mkRemoteUntrustedIOStub`.

### 3.4 Local arm — direct `System.Directory` (confined by `mkSafePath`, anchored at the workdir root)

The local arm of `WorkdirFs` reads via the same `System.Directory` /
`Data.Text.IO` the backends use today, but every path is run through
`mkSafePath (WorkspaceRoot wd) rel` first (canonicalizes, follows
symlinks, re-checks containment at the workdir root).

**Confinement anchoring — workdir root, not `.agents/`:** the `WorkdirFs`
is anchored at the **workdir root** (the directory containing the cloned
repos), not at each convention's `.agents/` dir. This is the **correct**
security boundary:
- The actual security property is "no escape from the workdir to host
  files" (e.g. a symlink to `/etc/shadow` is rejected — both
  `.agents/`-anchored and workdir-anchored confinement reject this,
  because `/etc/shadow` is outside both).
- The only behavioral difference is: a symlink in `.agents/` pointing to
  a file INSIDE the workdir but OUTSIDE `.agents/` (e.g.
  `.agents/agents.md -> ../README.md`) is **rejected** under
  `.agents/`-anchored confinement but **allowed** under workdir-anchored
  confinement. This is **not a security risk** — it's all cloned-repo
  content the operator explicitly chose to clone; reading the repo's own
  `README.md` via a symlink is harmless.

Centralizing confinement at the workdir root is a **security
improvement** over today: today `loadProjectAgentDef`/`loadProtocolSubAgent`
call `mkSafePath` (anchored at `.agents/`), but `listAgentDefs` (the
legacy path for `.seal/agents`/`agents`/non-protocol `.agents/`) does NOT
call `mkSafePath` at all — it reads via raw `System.Directory`. After the
rewire, ALL paths go through `WorkdirFs`'s `mkSafePath` (workdir-root
anchored), closing the legacy gap.

The existing `RepoDiscoverySpec` symlink-escape test (line 239) is
updated: it now asserts that a symlinked `agent.md` escaping the
**workdir** (not just `.agents/`) is rejected. The within-workdir-via-symlink
case is allowed (and a new test asserts it is, documenting the
intentional behavior).

### 3.5 Remote arm — SSH via `RemoteRunner` (confined by `mkSafePathRemote` + `realpath` symlink re-check)

The remote arm implements each method via `UIO`'s `uioShellExec`
(§3.12 — one `RemoteRunner`, shared with `UIO`; the commands are the
same shape `UntrustedIO`'s remote arm uses today):

| Method | Remote implementation |
|---|---|
| `wfsReadFile` | (1) `realpath -f -- <abspath>` → resolved path; (2) re-run lexical containment on resolved path against workspace root (reject `WfsPath` on escape); (3) `stat -c %s -- <resolved>` → reject `WfsOversize` if > ceiling; (4) `head -c <ceil> -- <resolved>` → raw `Text`. |
| `wfsDoesFileExist` | `test -f -- <abspath>` → parse stdout (`y`/empty). **Exempt** from `realpath` re-check (returns a 1-bit bool, no target identity — accepted residual). |
| `wfsDoesDirectoryExist` | `test -d -- <abspath>` → parse stdout. **Exempt** from `realpath` re-check (1-bit bool, no target identity — accepted residual). |
| `wfsListDirectory` | (1) `realpath -f -- <abspath>` → resolved (a missing path's `realpath` failure is treated as "missing → `Right []`", NOT `WfsIo`, so the fail-soft-to-empty contract holds); (2) re-check containment on resolved path (reject `WfsPath` on escape); (3) `ls -1 -- <resolved>` → split lines; missing dir → `Right []`. **Guarded** (directory symlinks are resolved + re-checked — `ls -1` would otherwise follow a symlinked dir and leak the target's filenames). |
| `wfsFileSize` | (1) `realpath -f -- <abspath>` → resolved; (2) re-check containment (reject `WfsPath` on escape); (3) `stat -c %s -- <resolved>` → `Integer` (Linux target; `wc -c < <resolved>` portable fallback if target OS is uncertain — pinned at config validation, not per-call). **Guarded** (`stat` follows symlinks and would disclose target size). |
| `wfsModificationTime` | (1) `realpath -f -- <abspath>` → resolved; (2) re-check containment (reject `WfsPath` on escape); (3) `stat -c %Y -- <resolved>` → epoch seconds → `UTCTime` (second precision; acceptable for `dirMTime`'s best-effort timestamp use — already falls back to `epochZero` today). **Guarded** (`stat` follows symlinks and would disclose target mtime). |

**`realpath` symlink-resolution re-check (CRITICAL, resolves the remote
symlink-escape gap):** the remote arm is NOT symlink-safe via
`mkSafePathRemote` alone (lexical-only). Before any read or listing,
the remote arm runs `realpath -f -- <abspath>` on the remote OS, which
resolves ALL symlinks to a canonical absolute path. The resolved path
is then re-checked for lexical containment against the remote workspace
root (same `mkSafePathRemote` containment check, run on the resolved
path). If the resolved path escapes the workspace root → `Left WfsPath`
(reject, before any content is read or any directory is listed). This
mirrors the local arm's `mkSafePath` (which `canonicalizePath`-es then
re-checks containment). `realpath -f` is present on GNU/Linux and macOS
(coreutils/BSD) — the SSH target is Linux by convention; config
validation may pin the target OS if needed.

**Which methods need the re-check (and why):**
- `wfsReadFile` — **guarded** (content exfiltration vector).
- `wfsListDirectory` — **guarded** (directory symlinks: `ls -1` follows
  the link and lists the target's filenames → information disclosure into
  the agent-def candidate list / dropdown; e.g. `.agents/agents -> /etc`
  would leak `/etc`'s filenames as candidate ids).
- `wfsFileSize` / `wfsModificationTime` — **guarded** (defense-in-depth:
  `stat` follows symlinks and would disclose the target's size/mtime —
  a metadata info-leak).
- `wfsDoesFileExist` / `wfsDoesDirectoryExist` — **exempt** (return a
  1-bit bool; no target identity or content is disclosed — `test -f`
  reveals only "the symlink resolves to a file," not which file). This
  is an accepted residual, documented for reviewers. (The backends
  gate `wfsReadFile`/`wfsListDirectory` on these existence checks, so a
  symlinked-external existence-`True` does not by itself exfiltrate
  content — the subsequent guarded read/list is rejected.)

**Shell quoting + `--` separator:** every absolute path is shell-quoted
via the existing `shellQuote` AND preceded by `--` (e.g.
`head -c 1048576 -- '/srv/agent-workspace/<sid>/repo/.agents/agents.md'`)
— defense-in-depth against option injection (a crafted filename
beginning with `-` is treated as a path, not a flag). No agent-derived
content reaches argv — only a SafePath-validated absolute path (from
`getSafePath`/`mkSafePathRemote`, not raw `Text`) and the
operator-controlled integer ceiling (from config, captured at
construction, not from the LLM).

**`readBoundedFile` guards on the remote arm:** `wfsReadFile` does
`stat -c %s` FIRST, rejects `WfsOversize` BEFORE `head -c` (no wasted
round-trip reading an oversize file then discarding it). Preserves the
`Nothing`-on-oversize semantics the backends expect (today's
`readBoundedFile` returns `Nothing` on `size > maxBootstrapFileBytes`).

**Invariant-1 posture (AGENTS.md "no shell-wrapping in
Trusted/Audited opcodes"):** `WorkdirFs` is **not an opcode** — it's a
discovery handle used by Trusted prompt-assembly code. Invariant 1
applies to opcodes, so there is no literal violation. The remote arm
invokes fixed, trusted binaries (`realpath`, `head`, `test`, `ls`,
`stat`) over SSH with NO agent-derived content in argv — this matches
Invariant 1's permitted-infrastructure shape ("fixed-argv invocation of
a specific trusted binary"). If `runRemoteShell` uses a remote
`sh -c` wrapper, the command string is harness-constructed from
validated components (SafePath-validated path + operator `Int`) with no
agent-derived content, and the binaries are fixed (not arbitrary) —
the shell-interpreter use is bounded. Documented for reviewers; not a
violation.

### 3.6 The backends take `WorkdirFs`, not `FilePath` — full call-chain migration

**Decision**: new `workdirAgentDefBackendFs` and `workdirSkillBackendFs`
functions (signature `WorkdirFs -> IO XBackend`) replace the current
`workdirAgentDefBackend`/`workdirSkillBackend` (which keep their
`FilePath` signatures as back-compat wrappers during W4/W5, then are
promoted in W6). **ALL** workdir-reading functions in
`Seal.Agent.Def.Backend` and the `workdir*` functions in
`Seal.Skills.Backend` take `WorkdirFs` (not `FilePath`). The
`System.Directory` / `TIO.readFile` calls are replaced by `WorkdirFs`
method calls; the backend's own `mkSafePath` calls are **removed**
(confinement now happens inside `WorkdirFs` — single chokepoint,
closing the legacy `listAgentDefs` gap, §3.4).

**Full call-chain in `Seal.Agent.Def.Backend`:**
- `readBoundedFile` — REMOVED (its logic moves into `wfsReadFile`,
  §3.2). The backends call `wfsReadFile` and get already-bounded `Text`.
- `readSection :: WorkdirFs -> SectionKind -> Int -> IO (Maybe Text)` —
  signature change (`FilePath` → `WorkdirFs`); calls `wfsReadFile` for
  the section file.
- `composeDirSystemPrompt :: WorkdirFs -> Int -> IO Text` — EXPORTED
  signature change (`FilePath` → `WorkdirFs`); calls `readSection` with
  the `WorkdirFs`. Its test call sites (`BackendSpec.hs:176,187`) update
  to pass `mkLocalWorkdirFs (WorkspaceRoot tmp)`.
- `loadDirAgentDef :: WorkdirFs -> AgentDefId -> IO (Maybe AgentDef)` —
  signature change; calls `loadDirAgentConfig`, `composeDirSystemPrompt`,
  `dirMTime` with the `WorkdirFs`.
- `loadDirAgentConfig :: WorkdirFs -> IO DirAgentConfig` — signature
  change; calls `wfsReadFile` for `AGENTS.md`.
- `dirMTime :: WorkdirFs -> IO UTCTime` — signature change; calls
  `wfsModificationTime` (with `epochZero` fallback on `Left`).
- `loadProjectAgentDef :: WorkdirFs -> IO (Maybe AgentDef)` — signature
  change; calls `wfsReadFile` (the `mkSafePath` call is removed —
  `WorkdirFs` validates internally).
- `loadProtocolSubAgent :: WorkdirFs -> Text -> IO (Maybe AgentDef)` —
  signature change; same.
- `listWorkdirAgentDefs :: WorkdirFs -> IO [AgentDef]` — signature
  change; `listWorkdirSubdirs` → `wfsListDirectory`; per-repo
  `doesDirectoryExist` → `wfsDoesDirectoryExist`; dispatch to
  `listAgentsDotAgents`/`listAgentDefs` (both now `WorkdirFs`-taking).
- `listWorkdirSubdirs` — REMOVED (subsumed by `wfsListDirectory`).
- `listAgentsDotAgents`/`listProtocolAgentDefs`/`isProtocolRoot` —
  signature change; `doesFileExist`/`doesDirectoryExist` → `wfs*`.

**Full call-chain in `Seal.Skills.Backend` (workdir functions only):**
- `workdirSkillBackend :: WorkdirFs -> IO SkillBackend` — signature
  change.
- `listWorkdirSkills :: WorkdirFs -> IO [Skill]` — signature change;
  `doesDirectoryExist` → `wfsDoesDirectoryExist`; `listSubdirs` →
  `wfsListDirectory`.
- `listAgentSkillsDir`, `listTopLevelSkills`, `listGroupedSkills` —
  signature change; `doesFileExist`/`doesDirectoryExist`/`listDirectory`
  → `wfs*`; `TIO.readFile` → `wfsReadFile`.
- The user-store functions (`markdownSkillBackend`, the user's
  `~/.seal/skills/` reads) stay on `FilePath` — they are control-plane
  data, not workspace-derived.

**Existing tests — mechanical adapter:** the existing
`AgentDefBackendSpec` / `RepoDiscoverySpec` call sites change from
`workdirAgentDefBackend tmp` to
`workdirAgentDefBackendFs (mkLocalWorkdirFs (WorkspaceRoot tmp))` — a
mechanical wrap. **Call-site counts** (corrected): `RepoDiscoverySpec`
has 13 workdir call sites (9 `workdirAgentDefBackend` + 4
`workdirSkillBackend`); `BackendSpec` has 2 (`composeDirSystemPrompt`
at lines 176/187); `SkillBackendSpec` has 0 (tests the user store only,
which is NOT changing). Total ≈15. The test logic is unchanged; only
the backend-construction call wraps. During W4/W5 the EXPORTED
`workdirAgentDefBackend`/`workdirSkillBackend` keep their `FilePath`
signatures (back-compat wrappers delegating to `mkLocalWorkdirFs`), so
existing tests compile unmodified until W6 promotes the `Fs`-suffixed
names. This preserves local-arm parity (the §1.1 success metric).

**Compile-fail fixture (enforces no direct FS in workdir backends):**
a new compile-fail fixture `Seal.Agent.Def.Backend.NoDirectFsFail`
(mirroring the existing `Seal.Tools.Exec.CapabilityScopingFail` pattern)
asserts that `Seal.Agent.Def.Backend`'s workdir functions do not import
`System.Directory` / `Data.Text.IO` (the workdir functions are split
into a sub-module or guarded by a CPP boundary so the fixture can assert
the absence). Added to W4 DoD. Same for `Seal.Skills.Backend` (W5 DoD).

### 3.7 Wiring sites source both handles + the shared root from `mkSessionExec`

Each turn-entry site (`Send.hs`, `API.hs`, `Channels/Loop.hs`,
`Channel/Cli.hs`) replaces:

```haskell
untrustedIO <- ... mkSessionUntrustedIO paths secCfg sid
eWd <- ensureSessionWorkdir paths sid
... workdirAgentDefBackend wd ... Skill.workdirSkillBackend wd
```

with:

```haskell
exec <- mkSessionExec paths secCfg sid mkRealRemoteRunner
let uioEnv       = seUIOEnv        exec  -- threaded to 'dispatch' for untrusted opcodes
    workdirFs   = seWorkdirFs      exec  -- for discovery backends
    wsroot      = seWorkspaceRoot exec  -- for the ISA registry
... workdirAgentDefBackendFs workdirFs ... Skill.workdirSkillBackendFs workdirFs
```

(The dispatcher receives `uioEnv` and runs untrusted opcodes via
`runUIOWithEnv uioEnv (uoRun op input)`. Production wiring passes
`mkRealRemoteRunner`; tests pass `mkFakeRemoteRunnerRecording`. The
single runner is shared between `seUIOEnv` (UIO) and `seWorkdirFs`
(via `runUIOWithEnv`).)

The local `ensureSessionWorkdir` call is removed from these sites (it
now happens inside `mkSessionExec`'s local arm). The `wsroot` used by
the ISA registry (`buildWebRegistry ... wsroot ...`) is sourced from
`seWorkspaceRoot` (the shared root), NOT from a `wfsRoot` accessor
(which is dropped — §3.3).

`wfsRoot` is DROPPED. The discovery backends don't need it (they use
`WorkdirFs` methods which have the root internal). The ISA registry gets
the root from `seWorkspaceRoot`. This resolves the type-confusion (a
`WorkspaceRoot` wrapping a remote path string is unsafe to feed to
local `mkSafePath`, but the ISA registry uses it for `UntrustedIO`'s
opcodes which have their own internal root — the `wsroot` param to
`buildWebRegistry` is used for `RemotePath` construction / display, not
for local canonicalization).

### 3.8 `handleSessionAgents` uses `WorkdirFs` (requires `adSecurityConfig` on `ApiDeps`)

`GET /api/sessions/:id/agents` (`API.hs:785-807`) currently computes
`sessionWorkdir paths sid` (local) and builds `workdirAgentDefBackend
wd`. It switches to `mkSessionExec paths secCfg sid` and
`workdirAgentDefBackend (seWorkdirFs exec)`.

**`ApiDeps.adSecurityConfig` (concrete, not "verify"):** `ApiDeps`
(`API.hs:99-117`) has NO `SecurityConfig` field today; the existing
`handleSessionAgents` does not load one. To call `mkSessionExec`
(which takes `SecurityConfig`), `ApiDeps` gains
`adSecurityConfig :: SecurityConfig`, wired at the `ApiDeps`
construction site (wherever `ApiDeps` is built — likely `Serve.hs` or
the gateway bootstrap). This is a concrete W6 DoD item.

### 3.9 No change to the user store or built-in backends

`markdownAgentDefBackend` (the user's `~/.seal/agents/` store) and the
built-in skills map remain local-FS / in-memory. They are control-plane
data, not workspace-derived. Only the `workdir*` backends switch to
`WorkdirFs`. The `unionAgentDefBackend` / `tripleUnionSkillBackend`
compositions are unchanged (they union backends, not FSs).

### 3.10 The `UIO` monad — definition + construction

**Decision**: introduce a new restricted monad `UIO` in
`src/Seal/Tools/Exec/UIO.hs` (alongside `UntrustedIO`). It is the sole
execution context for untrusted opcodes. It exposes `Functor`,
`Applicative`, `Monad` — and deliberately **no `MonadIO`, no
`MonadReader`, no `MonadThrow`, no `Katip`**.

```haskell
-- | The restricted monad for untrusted opcode execution. Carries an
-- 'UntrustedIO' handle (+ the Git 'CloneDeps' surface) internally; the
-- only IO an opcode can perform is the lifted 'UntrustedIO'/'CloneDeps'
-- surface. NO 'MonadIO' — a bare 'liftIO'/'IO' action in an opcode body
-- won't compile. Constructed ONLY by 'mkLocalUIO'/'mkRemoteUIO'/
-- 'mkUIOStub'; the constructor + 'unUIO' + 'UIOEnv' + 'runUIO' are
-- unexported. 'runUIOWithEnv' is exported to the dispatcher +
-- 'WorkdirFs' (NOT to opcode modules — W6 grep check).
newtype UIO a = UIO { unUIO :: ReaderT UIOEnv IO a }
  deriving newtype (Functor, Applicative, Monad)
  -- deliberately NOT: MonadIO, MonadReader, MonadThrow

data UIOEnv = UIOEnv
  { uieUntrustedIO :: !UntrustedIO
  , uieCloneDeps   :: !CloneDeps
  }
```

- `UIOEnv` carries the two handles the opcode body needs (`UntrustedIO`
  + `CloneDeps`). It is NOT exported (opaque — no caller can forge
  one). The `unUIO` field accessor is also NOT exported (defense-in-depth
  — exporting it would let an opcode unwrap to `ReaderT UIOEnv IO`,
  which DOES have `MonadIO`/`MonadReader`/`MonadThrow` instances; the
  opcode can't re-wrap into `UIO` since the constructor is unexported,
  so it can't escape, but hiding `unUIO` removes the temptation). The
  `ReaderT` is an implementation detail; `MonadReader`-ness is **not**
  re-exposed (only `Functor`/`Applicative`/`Monad` are derived).
- Module-level `UIO`-typed functions (§3.11) expose the
  `UntrustedIO`/`CloneDeps` operations as `UIO`-level primitives (no
  `MonadUIO` class — a single-instance class is a smell; module
  functions are idiomatic for this codebase's handle pattern). Opcode
  bodies call `uioRead path n`, `uioShellExec cmd cwd`, etc. — never
  `liftIO (uioReadFile uio ...)`.
- **Running**: `runUIO :: UIO a -> IO a` is NOT exported. Two run seams
  exist: (a) the smart constructors (`mkLocalUIO`/`mkRemoteUIO`/
  `mkUIOStub`) take a `UIO a` action and run it to `IO a`, having
  selected the backend (they build a `UIOEnv` internally and delegate
  to `runUIOWithEnv`); (b) `runUIOWithEnv :: UIOEnv -> UIO a -> IO a`
  is exported (to `Seal.ISA.Dispatch`, `Seal.Session.Workdir`,
  `Seal.Tools.Exec.WorkdirFs` — NOT to any module under
  `src/Seal/ISA/Ops/`, enforced by the W6 grep check) for callers that
  have a pre-built `UIOEnv` (the dispatcher, `WorkdirFs`'s remote arm).
  `mkSessionExec` builds the `UIOEnv` once and threads it via
  `seUIOEnv`; the dispatcher runs the opcode's `UIO` action via
  `runUIOWithEnv` (not re-constructing per call).

**Construction paths (only two + stub):**

```haskell
-- | mode=local: the workdir is a local path; UntrustedIO is local.
mkLocalUIO :: WorkspaceRoot -> UIO a -> IO a

-- | mode=remote: the workdir is a remote workspace path; UntrustedIO
-- is remote (SSH via the RemoteRunner). The runner is shared with
-- WorkdirFs (§3.12, via runUIOWithEnv).
mkRemoteUIO :: SshConfig -> RemoteRunner -> WorkspaceRoot
            -> UIO a -> IO a

-- | Fail-closed: every operation returns Left/Stub. For misconfigured
-- or unreachable remotes; mirrors mkRemoteUntrustedIOStub.
mkUIOStub :: UIO a -> IO a

-- | Run a UIO action with a pre-built UIOEnv (the dispatcher +
-- WorkdirFs's remote arm use this). Exported to Dispatch/Workdir/WorkdirFs
-- only — NOT to opcode modules (W6 grep check).
runUIOWithEnv :: UIOEnv -> UIO a -> IO a
```

The constructor (`UIO`/`UIOEnv`), `unUIO`, and `runUIO` are unexported;
only the smart constructors + `runUIOWithEnv` are exported. There is no
`Maybe GitRepo` parameter — Git opcodes resolve the repo at runtime via
`CloneDeps` (in `UIOEnv`), not a constructor param. `mkSessionExec`
(§3.3) builds the `UIOEnv` once and returns it as `seUIOEnv`; the
wiring runs the opcode's `UIO` action via `runUIOWithEnv` (through the
dispatcher) after ACK-before-execute.

**Back-compat**: the existing `UntrustedIO` handle stays (it's the
record of IO actions `UIO` carries internally). The opcode signature
change (`uoRun :: UntrustedIO -> Value -> App OpResult` → `Value ->
UIO OpResult`) is the breaking change W-A3 makes; the dispatcher is
updated to run the `UIO` action via `runUIOWithEnv` after
ACK-before-execute.

### 3.11 The `UIO` operation surface (lifted `UntrustedIO` + `CloneDeps`)

The `UntrustedIO` methods lift to **module-level `UIO`-typed functions**
(no `MonadUIO` class — a single-instance class is a smell; module
functions are idiomatic for this codebase's handle pattern, and
call-site concision is identical):

```haskell
-- In Seal.Tools.Exec.UIO (in scope for all opcode modules via import):
uioRead        :: RemotePath -> Int -> UIO (Either UntrustedErr LineWindow)
uioWrite       :: RemotePath -> Text -> WriteMode -> Int
                -> UIO (Either UntrustedErr Int)
uioPatch       :: RemotePath -> Text -> UIO (Either UntrustedErr ())
uioShellExec   :: ShellCommand -> Maybe RemotePath
                -> UIO (Either UntrustedErr Text)
uioBinExec     :: BinName -> [BinArg] -> Maybe RemotePath
                -> UIO (Either UntrustedErr Text)
uioProcessList :: UIO (Either UntrustedErr Text)
uioProcessKill :: Int -> UIO (Either UntrustedErr ())
uioSearchFiles :: SearchPattern -> Maybe RemotePath -> Int
                -> UIO (Either UntrustedErr Text)
uioShellExecEnv :: [(String,String)] -> ShellCommand -> Maybe RemotePath
                 -> UIO (Either UntrustedErr Text)
uioShellExecGitEnv :: [(String,String)] -> Maybe BS.ByteString
                    -> ShellCommand -> Maybe RemotePath
                    -> UIO (Either UntrustedErr Text)
uioBinExecEnv  :: [(String,String)] -> BinName -> [BinArg] -> Maybe RemotePath
                -> UIO (Either UntrustedErr Text)
-- each reads the UntrustedIO from UIOEnv via the internal ReaderT and
-- calls the underlying method.
```

```haskell
-- In Seal.Tools.Exec.UIOGit (a SEPARATE module, imported ONLY by
-- Seal.ISA.Ops.Git — lexical scoping restores the round-3 property
-- that non-Git opcodes cannot name these functions; enforced by the
-- W-A3 CI grep guard):
uioCdRepoRegList :: UIO [RepoRegistryEntry]   -- rrhList (cdRepoReg deps)
uioResolveClone  :: RepoRef -> UIO (Maybe CloneTarget) -- resolveCloneTarget deps
uioWithClone     :: CloneTarget -> (CloneEnv -> UIO a) -> UIO a  -- withCloneTarget
-- ... plus any other CloneDeps IO the Git opcodes use
-- each reads the CloneDeps from UIOEnv via the internal ReaderT.
```

- **Naming**: the `uio` prefix is reused (the operations ARE the
  `UntrustedIO` operations, just lifted). `CloneDeps`-specific
  functions get `uioCd*` prefixes and live in `Seal.Tools.Exec.UIOGit`.
- **`CloneDeps` capability scoping (CRITICAL, round-5 fix)**: in
  round 3, `CloneDeps` was a closure param of Git opcodes only —
  non-Git opcodes had no lexical access. Round 4 (class) lost that.
  Round 5 restores it: `uioCd*` live in a separate
  `Seal.Tools.Exec.UIOGit` module imported only by
  `Seal.ISA.Ops.Git`. A non-Git opcode that wants `uioCdRepoRegList`
  must add the import (caught at review); the **W-A3 CI grep guard**
  asserts `Seal.Tools.Exec.UIOGit` is referenced only from
  `src/Seal/ISA/Ops/Git.hs` (+ the definition site), mirroring the W6
  `WorkdirFs` discipline. So the capability surface is scoped by
  import + CI, not class membership.
- The `UntrustedIO` record itself stays exported (it's the underlying
  data; `WorkdirFs`'s remote arm uses it via `UIO`, §3.12). The `UIO`
  wrapper is what's restricted.
- Opcode bodies call these directly: `uioRead path n`, `uioShellExec
  cmd cwd` — no `liftIO`, no handle argument. A bare `liftIO` or `IO`
  action in an opcode body typed `UIO OpResult` won't compile (no
  `MonadIO` instance).
- `CloneEnv` (not `GitEnv`) — the existing type at `Clone.hs:277`;
  `uioWithClone` yields it (the existing `withCloneTarget`'s callback
  arg). `GitEnv` was a round-4 typo.

**Compile-fail fixtures (enforce the restriction):**
- `Seal.ISA.Ops.UIOUnrestrictedFail` — asserts an opcode body typed
  `UIO OpResult` that calls `liftIO`/`ask`/`throwM` fails to compile
  (no `MonadIO`/`MonadReader`/`MonadThrow` instance). Mirrors the
  `CapabilityScopingFailSpec` pattern (build-source-string +
  `assertCompileFail`). Added to W-A2 DoD.
- `Seal.ISA.Ops.UIOConstructionFail` — asserts a module that tries to
  construct `UIO`/`UIOEnv` directly (without the smart constructors)
  fails to compile (constructor + `unUIO` unexported). Added to W-A2
  DoD.

### 3.12 `WorkdirFs` is built on `UIO`'s shell-exec (one transport)

**Decision**: `WorkdirFs` (§3.2) stays a separate handle for the
discovery backends (it's consumed by Trusted prompt-assembly code, not
opcodes — §3.1 capability scoping). But its remote arm is now
**implemented on top of `UIO`'s `uioShellExec`/`uioBinExec` primitives**
rather than calling the `RemoteRunner` directly.

- `mkRemoteWorkdirFs` no longer takes a `RemoteRunner`. It takes the
  `UIOEnv` and issues its `realpath`/`head -c`/`ls -1`/`stat`/`test`
  commands via `uioShellExec` (run in the `UIO` context via
  `runUIOWithEnv uioEnv`, where `uioEnv` is the `seUIOEnv` from
  `mkSessionExec`). `WorkdirFs`'s remote arm holds the `UIOEnv` and
  calls `runUIOWithEnv uioEnv (uioShellExec cmd cwd)` for each
  operation.
- This **unifies the transport**: one `RemoteRunner` (owned by `UIO`),
  shared with `WorkdirFs` via `runUIOWithEnv`. No second SSH connection.
- `WorkdirFs` **inherits `UIO`'s transport (one shared `RemoteRunner`)
  + CWD confinement** (`uioShellExec`'s `Maybe RemotePath` cwd is
  SafePath-confined). **File-path confinement remains `WorkdirFs`'s
  own** `mkSafePathRemote` + `realpath` re-check (§3.5), layered on top
  of `UIO`'s CWD confinement — `uioShellExec` confines the cwd, not
  the command-string argv; the file paths `WorkdirFs` reads are
  validated by `WorkdirFs`'s own `mkSafePathRemote` before the
  `uioShellExec` call.
- The local arm of `WorkdirFs` stays on `System.Directory` (direct,
  confined by `mkSafePath`) — it doesn't go through `UIO` (no need;
  local reads are cheap and `UIO`'s local arm would just wrap
  `System.Directory` anyway). Only the remote arm goes through `UIO`.
  This local/remote asymmetry is intentional and documented.

**`mkSessionExec` revision (round 5):** `mkSessionExec` constructs the
`UIOEnv` (selecting local vs remote via
`untrustedExecConfigFromSecurity`, creating the workdir, building the
`UntrustedIO` + `CloneDeps`), and returns:
```haskell
data SessionExec = SessionExec
  { seUIOEnv        :: UIOEnv        -- for running untrusted opcodes in UIO
  , seWorkdirFs     :: WorkdirFs     -- for discovery (remote arm built on UIOEnv)
  , seWorkspaceRoot :: WorkspaceRoot
  }
```
The dispatcher's `uoRun` invocation changes from
`uoRun op untrustedIO input` (in `App`) to running the opcode's `UIO`
action via `runUIOWithEnv (seUIOEnv exec) (uoRun op input)` (after
ACK-before-execute). The `App` context stays for the dispatcher (ACK +
transcript + logging); the opcode runs in `UIO`. `mkSessionExec` takes
the `RemoteRunner` param (round-3 CTO fix preserved) and shares it
between `UIO` and `WorkdirFs` (via `runUIOWithEnv`).


## 4. Security considerations

| Concern | Mitigation |
|---|---|
| **Path traversal / symlink escape on the remote arm** (CRITICAL) | `mkSafePathRemote` (lexical containment) is NOT symlink-safe. The remote arm runs `realpath -f -- <abspath>` on the remote OS FIRST, resolves all symlinks to a canonical absolute path, re-runs the lexical containment check on the **resolved** path against the remote workspace root, and rejects `WfsPath` on escape BEFORE any content is read or any directory listed. **Applied to:** `wfsReadFile` (content), `wfsListDirectory` (directory symlinks — `ls -1` follows them and would leak target filenames), `wfsFileSize` + `wfsModificationTime` (defense-in-depth — `stat` follows symlinks and would disclose target size/mtime). **Exempt:** `wfsDoesFileExist`/`wfsDoesDirectoryExist` (1-bit bool, no target identity — accepted residual; the backends gate guarded reads/lists on these, so a symlinked-external existence-`True` does not by itself exfiltrate). This mirrors the local arm's `mkSafePath` (canonicalize-then-recheck). |
| Path traversal on the local arm | `mkSafePath` (canonicalizes, follows symlinks, re-checks containment at the workdir root) — the existing proof type. Centralizing moves the legacy `listAgentDefs` path (which today skips `mkSafePath`) behind the same confinement — a security improvement. |
| **Capability scoping** (CRITICAL) | `WorkdirFs` is a distinct handle from `UntrustedIO`. `WorkdirFs` methods are not directly exposed to any opcode — the handle MAY be captured in discovery-backend closures (`adbRead` closes over `wfsReadFile`) that are used DURING opcode dispatch, but opcodes receive only the backends' **typed interfaces** (`adbRead :: AgentDefId -> IO (Maybe AgentDef)`, never `wfsReadFile :: RemotePath -> ...`), so no opcode can read an arbitrary workspace path. `AgentDefId`/`SkillId` are charset-validated (`[A-Za-z0-9_-]+`, no `/`/`.`/`..`) so no path traversal via the id. `WorkdirFs` is NEVER added to `AppEnv`/opcode registry/any env reachable by an `Opcode` — **CI-enforced** via a W6 grep check (asserting no `WorkdirFs` field in `AppEnv`, ISA registry env records, or `src/Seal/ISA/Ops/` modules), mirroring the `CapabilityScopingFail` discipline. |
| Unbounded read / OOM | `wfsReadFile` is bounded by the operator scan-byte ceiling (captured at construction) and applies `maxBootstrapFileBytes` + `truncateSection` internally on BOTH arms. The remote arm `stat -c %s`-first rejects `WfsOversize` before `head -c` (no wasted round-trip). |
| Option injection via SSH argv | Only a SafePath-validated absolute path (from `getSafePath`/`mkSafePathRemote`, not raw `Text`) reaches the SSH argv, shell-quoted via `shellQuote` AND preceded by `--`. No agent-derived content reaches argv (discovery backends read repo files, not agent input). The operator ceiling `Int` comes from config, captured at construction. |
| Secret leakage via discovery | The backends parse file contents into `AgentDef`/`Skill`; only the system-prompt body flows onward to the LLM. With the `realpath` re-check (remote arm) + `mkSafePath` (local arm), a symlinked `.agents/agents.md -> /etc/shadow` is REJECTED before read — no exfiltration. `WorkdirFs` adds no logging. |
| Remote plane compromise | A compromised remote can return arbitrary file contents / fake `stat`/`realpath` output. This is the same trust posture as `uioReadFile` today: the remote is untrusted, so its file contents are untrusted content fed to the LLM — which the operator explicitly chose by cloning the repo and the user explicitly chose by picking the agent (existing trust model). No new trust boundary. The `realpath` re-check defends against a *malicious repo* (symlink in the cloned repo), not against a *compromised remote host* (which is outside the threat model — the operator pinned the host key). |
| Fail-closed | `mkWorkdirFsStub` (misconfigured/unreachable remote) yields `False`/`Left WfsStub` everywhere → no agents/skills discovered → session still boots (chat + Trusted opcodes work), mirroring `mkRemoteUntrustedIOStub`. |
| Local/remote mode asymmetry | RESOLVED (was a round-1 gap). Both arms are now symlink-safe: local via `mkSafePath`'s `canonicalizePath`; remote via the `realpath -f` re-check. An operator whose repo is safe in `mode=local` is now also safe in `mode=remote` (for the symlink-escape-to-host case). Documented for operators. |
| Invariant 1 posture | `WorkdirFs` is not an opcode; the remote arm invokes fixed trusted binaries (`realpath`/`head`/`test`/`ls`/`stat`) over SSH with no agent-derived content in argv — matches the permitted-infrastructure shape. Not a literal violation; documented §3.5. |
| **`UIO` restriction (CRITICAL, round 5)** | `UIO` exposes only `Functor`/`Applicative`/`Monad` — no `MonadIO`/`MonadReader`/`MonadThrow`/`Katip` (and `unUIO` is unexported so the `ReaderT`'s instances can't be reached). An opcode body typed `UIO OpResult` literally cannot call `liftIO`, `ask`, `throwM`, or import `System.Directory`/`System.Process` (compile error). The only IO is the module-level `uio*`/`uioCd*` functions (`Seal.Tools.Exec.UIO` + `Seal.Tools.Exec.UIOGit`). Constructed ONLY by `mkLocalUIO`/`mkRemoteUIO`/`mkUIOStub` (constructor + `UIOEnv` + `runUIO` unexported). `runUIOWithEnv` exported to dispatcher/`WorkdirFs` only (NOT opcodes — W6 grep check). **`CloneDeps` scoping restored (round 4 regressed, round 5 fixes):** `uioCd*` live in `Seal.Tools.Exec.UIOGit`, imported only by `Seal.ISA.Ops.Git` (lexical scoping) + a W-A3 CI grep guard asserts no other opcode module references it. `UIOEnv` is also guarded by the W6 grep check (no `UIOEnv` field in `AppEnv`/registry/opcode modules — only in `SessionExec`, consumed at turn-entry sites). Compile-fail fixtures (`UIOUnrestrictedFail`, `UIOConstructionFail`) assert the restriction. This turns the "no direct FS in opcodes" convention into a **type-level guarantee**, categorically eliminating future local/remote parity gaps (one construction path per mode; backend selected once). |

## 5. Testing

**No real SSH / network IO / subprocess spawn.** Every `WorkdirFsSpec` and
`RepoDiscoverySpec`/`SkillBackendSpec` remote-arm case uses
`mkFakeRemoteRunnerRecording` (existing in `Seal.Tools.Exec.Remote` —
records argv+stdin to an `IORef`, returns canned stdout) — no real SSH,
no network IO, no subprocess. The implementer MUST NOT reach for
`mkRealRemoteRunner` in tests.

- **Pure (QuickCheck, existing):** the `deriveAgentsMdId` suffix-shape
  property and the existing `isValidAgentDefId`/`isValidSkillId`
  properties are unchanged (pure functions unaffected).
- **NEW pure (QuickCheck):** `shellQuote` property — for every path
  that passes `mkSafePathRemote`, `shellQuote path` contains no unescaped
  shell metacharacter (no unquoted space, `"`, `'`, `` ` ``, `$`, `;`,
  `|`, `&`, `<`, `>`, newline). Security-critical pure function (AGENTS.md
  mandates QuickCheck for these). Bounded generator over valid
  `RemotePath`s.
- **Local-arm parity:** the existing `AgentDefBackendSpec` /
  `SkillBackendSpec` / `RepoDiscoverySpec` pass with the mechanical
  `mkLocalWorkdirFs (WorkspaceRoot tmp)` adapter (local parity guard).
- **Stub arm (non-vacuous symlink model):** the in-memory stub
  (`mkInMemWorkdirFs`) models symlinks: `Map RemotePath StubEntry` where
  `StubEntry = FileContent Text | SymlinkTarget RemotePath | Directory
  [Text] | Missing`. The stub's `wfsReadFile` resolves `SymlinkTarget`
  chains (up to a depth bound), re-checks containment on the resolved
  path, and rejects on escape — mirroring the real remote arm's
  `realpath` logic. This makes the symlink-escape test non-vacuous.
  Renamed from `mkStubWorkdirFs` (round-1 name collided with
  `mkWorkdirFsStub`; `mkInMemWorkdirFs` is the seeded-map test stub,
  `mkWorkdirFsStub` is the fail-closed stub).
- **Remote-arm stub:** `mkRemoteWorkdirFsFromStub` mimics the SSH path
  over an in-process stub `RemoteRunner` seeded from the same
  `Map RemotePath StubEntry`. Asserts: `.agents/agents.md` is read;
  sub-agent `agent.md` is read; `listDirectory` returns names; existence
  checks are correct; oversize → `Left WfsOversize`; a `..` path is
  rejected before the runner is invoked (the stub runner's recorded-calls
  `IORef` is `[]`); a symlinked `agent.md` escaping the workspace is
  rejected (the stub models the symlink, the `realpath`-equivalent
  resolves it, containment re-check fails → `Left WfsPath`); a
  within-workdir symlink is allowed.
- **Remote-mode integration:** `RepoDiscoverySpec` (extended) builds the
  discovery backends over the stub-remote `WorkdirFs` seeded with a
  fixture repo's files (including a symlinked `agents.md` escaping the
  workspace, which must be rejected), and asserts the same discovery
  results as the local-arm fixture (the §1.1 success metrics). This is
  the headline test for the fix.
- **Fail-closed:** `mkWorkdirFsStub`-backed discovery yields `[]`/
  `Nothing`/defaults (no agents, no skills), session still boots.
- **SafePath confinement (both arms):** the existing
  `RepoDiscoverySpec` SafePath test, re-run against both arms (local +
  stub-remote), now asserting escape-from-**workdir** (not
  escape-from-`.agents/`); plus a new test asserting a within-workdir
  symlink is allowed (documenting the intentional behavior).
- **Compile-fail fixture:** `Seal.Agent.Def.Backend.NoDirectFsFail` (and
  the skills equivalent) assert the workdir functions don't import
  `System.Directory`/`Data.Text.IO`.

## 6. TDD work units

### W-A1 — The `UIO` monad + smart constructors + operation surface
**DoD:**
- `UIO` newtype + `UIOEnv` in `src/Seal/Tools/Exec/UIO.hs`, constructor
  + `unUIO` + `runUIO` + `UIOEnv` unexported;
  `Functor`/`Applicative`/`Monad` derived; **no**
  `MonadIO`/`MonadReader`/`MonadThrow`/`Katip` instances.
- `mkLocalUIO :: WorkspaceRoot -> UIO a -> IO a`,
  `mkRemoteUIO :: SshConfig -> RemoteRunner -> WorkspaceRoot -> UIO a
  -> IO a`, `mkUIOStub :: UIO a -> IO a` (mode before type, matching
  `mkLocalUntrustedIO`/`mkRemoteUntrustedIO`). No `Maybe GitRepo`.
  `runUIOWithEnv :: UIOEnv -> UIO a -> IO a` exported (to
  dispatcher/`WorkdirFs` — NOT opcodes; W6 grep check). Local arm
  builds a local `UntrustedIO` + `CloneDeps`; remote arm builds a
  remote `UntrustedIO` (SSH via the runner) + `CloneDeps`; stub arms
  are fail-closed.
- Module-level `uio*` functions (§3.11) in `Seal.Tools.Exec.UIO`:
  `uioRead`, `uioWrite`, `uioPatch`, `uioShellExec`, `uioBinExec`,
  `uioProcessList`, `uioProcessKill`, `uioSearchFiles`,
  `uioShellExecEnv`, `uioShellExecGitEnv`, `uioBinExecEnv` — each
  reads `UntrustedIO` from `UIOEnv` via the internal `ReaderT`. No
  `MonadUIO` class (single-instance class is a smell; module functions
  are idiomatic).
- `Seal.Tools.Exec.UIOGit` (separate module): `uioCdRepoRegList`,
  `uioResolveClone`, `uioWithClone` (yields `CloneEnv`, not `GitEnv` —
  the existing type at `Clone.hs:277`). Each reads `CloneDeps` from
  `UIOEnv`. Imported only by `Seal.ISA.Ops.Git` (W-A3 CI grep guard).
- **Test helper** `mkTestUIOEnv :: UntrustedIO -> CloneDeps -> UIOEnv`
  exported from `Seal.Tools.Exec.UIO` with the `Test` prefix as the
  naming gate (matching the codebase's `mkFakeRemoteRunnerRecording`
  pattern in `src/Seal/Tools/Exec/Remote.hs` — the `Fake`/`Test` prefix
  is the convention; no `#ifdef TESTING` — the codebase has zero such
  guards). Exported to both `src/` (the `uoRunLegacy` back-compat
  wrapper in W-A3 uses it to build a `UIOEnv` from the dispatcher's
  `UntrustedIO` + a stub/real `CloneDeps`) and tests (Git specs use a
  stub `CloneDeps` — all 6 fields stubbed: `cdVault`, `cdRepoReg`,
  `cdSshAgent`, `cdAgentRegistry`, `cdPinnedKnownHosts`,
  `cdKeyfilesDir` — seeded into the `UIOEnv` via this helper).
- New `UIOSpec`: local arm runs an action calling each `uio*` function
  against a temp workdir; stub arm asserts every operation returns
  fail-closed; `mkLocalUIO` vs `mkRemoteUIO` (with
  `mkFakeRemoteRunnerRecording` — no real SSH) produce equivalent
  results for the same fixture workdir; `runUIOWithEnv` round-trips a
  pre-built `UIOEnv`.
- Wiring: `seal-harness.cabal` (exposed-modules: `Seal.Tools.Exec.UIO`,
  `Seal.Tools.Exec.UIOGit`), `test/Main.hs`.
**RED**: `UIOSpec` — every `uio*` function round-trips on the local
  arm; stub is fail-closed; remote arm (fake runner) matches local for
  a fixture; `runUIOWithEnv` round-trips.
**File scope**: `src/Seal/Tools/Exec/UIO.hs`,
  `src/Seal/Tools/Exec/UIOGit.hs`,
  `test/Seal/Tools/Exec/UIOSpec.hs`, `seal-harness.cabal`,
  `test/Main.hs`.

### W-A2 — `UIO` compile-fail fixtures (the restriction is enforced)
**DoD:**
- `Seal.ISA.Ops.UIOUnrestrictedFail` (via `assertCompileFail`): an
  opcode body typed `UIO OpResult` that calls `liftIO`/`ask`/`throwM`
  fails to compile (no `MonadIO`/`MonadReader`/`MonadThrow` instance).
  Expected stderr substring: "No instance for" / "Not in scope".
- `Seal.ISA.Ops.UIOConstructionFail`: a module that constructs `UIO`/
  `UIOEnv` directly (without the smart constructors) or accesses
  `unUIO` fails to compile (constructor + `unUIO` + `UIOEnv`
  unexported). Expected: "Not in scope: 'UIO'" / "...'UIOEnv' is not
  exported" / "Not in scope: 'unUIO'".
- Mirrors the existing `CapabilityScopingFailSpec` /
  `SecurityScopingFailSpec` pattern (build-source-string +
  `assertCompileFail` in `test/Seal/TestHelpers/CompileFail.hs`).
- If `ghc` is not on `PATH` (non-Nix env), `pendingWith` (the helper
  should gain this fallback per AGENTS.md "guarded by pendingWith").
**RED**: the two fixtures (they assert compile-FAILURE; if the code
  compiles, the test fails).
**File scope**: `test/Seal/ISA/Ops/UIOUnrestrictedFailSpec.hs`,
  `test/Seal/ISA/Ops/UIOConstructionFailSpec.hs`,
  `test/Seal/TestHelpers/CompileFail.hs` (add `pendingWith` fallback
  if missing), `seal-harness.cabal`, `test/Main.hs`.

### W-A3 — Migrate untrusted opcodes to `UIO`
**DoD:**
- `uoRun` signature changes from
  `UntrustedIO -> Value -> App OpResult` to `Value -> UIO OpResult`
  (in `Seal.ISA.Opcode`).
- Every untrusted opcode body (`File.hs`, `Shell.hs`, `Search.hs`,
  `Bin.hs`, `Process.hs`, `Git.hs`) migrated: `liftIO (uio* uio ...)`
  → the module-level `uio*` functions (`Seal.Tools.Exec.UIO`);
  `import Control.Monad.IO.Class` removed from these modules; no
  `liftIO`/`ask`/`throwM` remains. Git opcodes additionally import
  `Seal.Tools.Exec.UIOGit` for `uioCd*`.
- **Git opcode constructors KEEP their `CloneDeps` param through W-A3**
  (the `CloneDeps` moves into `UIOEnv` in **W6**, not W-A3 — see the
  `uoRunLegacy` CloneDeps gap below). `buildWebRegistry` keeps
  `cloneDeps` as a closure param through W-A3; W6 drops it. Closure
  params `wsRoot`/`policy`/`operatorCeiling`/`cloneDeps` unchanged in
  W-A3. (Git opcode *bodies* migrate to `uioCd*` in W-A3, but the
  `CloneDeps` value is still closure-captured and threaded into the
  `UIOEnv` by `uoRunLegacy` until W6 rewires the dispatcher to source
  it from `seUIOEnv`.)
- **Agent-loop env**: `aeUntrustedIO :: UntrustedIO` (Loop.hs:374)
  **stays `UntrustedIO` through W-A3/W1/W2/W3** — the rename to
  `aeUIOEnv :: UIOEnv` + the dispatch `runUIOWithEnv` change land in
  **W6** (when `mkSessionExec` provides `seUIOEnv` and the wiring
  sites pass it). The dispatch signature stays `UntrustedIO`-based
  through W-A3.
- Dispatcher (`Dispatch.hs`) keeps the **old `UntrustedIO`-based path
  through W-A3** via `uoRunLegacy` (below). W6 rewires it to
  `runUIOWithEnv uioEnv (uoRun op input)` (where `uioEnv` is
  `seUIOEnv`, threaded as a new `dispatch` param), NOT via `App`.
  `runUIOWithEnv` is imported from `Seal.Tools.Exec.UIO`. The `App`
  context stays for the dispatcher (ACK + transcript + logging) + the
  three caller-side recorders (`SKILL_LOAD`/`SETUP_REPO`/`GIT_PUSH`).
- **CI grep guard (CloneDeps scoping, W-A3-specific)**: asserts
  `Seal.Tools.Exec.UIOGit` / `uioCd*` are referenced ONLY from
  `src/Seal/ISA/Ops/Git.hs` (+ the `UIOGit.hs` definition site).
  Mirrors the W6 `WorkdirFs` discipline. Added as a grep test in W-A3.
  (The grep uses OR logic: matches the module path string
  `Seal.Tools.Exec.UIOGit` — catches qualified/aliased imports — OR
  the `uioCd` function prefix — catches re-export scenarios.)
- Existing opcode specs (`FileSpec`, `ShellSpec`, `SearchSpec`,
  `BinSpec`, `ProcessSpec`, `GitSpec`) updated to run opcodes in `UIO`
  (via `mkLocalUIO (WorkspaceRoot tmp)` — no `Maybe GitRepo`) instead
  of passing a raw `UntrustedIO`. Git specs need a stub `CloneDeps`
  (all 6 `CloneDeps` fields stubbed: `cdVault`, `cdRepoReg`,
  `cdSshAgent`, `cdAgentRegistry`, `cdPinnedKnownHosts`,
  `cdKeyfilesDir` — mirroring the existing `GitSpec` fake repo
  registry + vault stub pattern) seeded into the `UIOEnv` via
  `mkTestUIOEnv` (W-A1). Test logic unchanged; construction wraps.
- **Back-compat (`uoRunLegacy`, the CloneDeps gap fix)**: during
  W-A3, keep a temporary `uoRunLegacy :: UntrustedIO -> Maybe
  CloneDeps -> Value -> App OpResult` wrapper. The dispatcher calls
  `uoRunLegacy op (Just cloneDeps) input` for Git opcodes (where
  `cloneDeps` is still closure-captured at the opcode construction
  site — Git constructors keep `CloneDeps` through W-A3) and
  `uoRunLegacy op Nothing input` for non-Git opcodes. `uoRunLegacy`
  internally builds a `UIOEnv` from the `UntrustedIO` + the `CloneDeps`
  (real for Git; a fail-closed stub `CloneDeps` for non-Git, which
  never touches it) via an internal helper, then runs
  `runUIOWithEnv uioEnv (uoRun op input)` via `liftIO`. This keeps
  the suite green (the dispatcher + `AgentEnv` sites + ~30 test
  `aeUntrustedIO` construction sites unchanged) until W6 does the
  rename + dispatch rewire + drops `uoRunLegacy` + drops Git's
  `CloneDeps` closure param. The fail-closed stub `CloneDeps` for
  non-Git is `mempty`-shaped (all fields stub) — non-Git opcodes
  never call `uioCd*`, so the stub is never exercised.
**RED**: a migrated opcode spec asserting the opcode runs under `UIO`
  and produces the correct `OpResult` (behavior RED) + the W-A2
  compile-fail fixture pointed at a real opcode module (a bare `liftIO`
  in the body is a compile error).
**File scope**: `src/Seal/ISA/Opcode.hs` (`uoRun` signature change),
  `src/Seal/ISA/Dispatch.hs` (add `uoRunLegacy` path; keep old
  `UntrustedIO`-based dispatch — the `runUIOWithEnv` rewire is W6),
  `src/Seal/ISA/Ops/{File,Shell,Search,Bin,Process,Git}.hs` (body
  migration to `uio*`/`uioCd*`),
  `src/Seal/Tools/Exec/UIOGit.hs` (new — the `uioCd*` functions),
  `src/Seal/Gateway/Send.hs` (the `buildWebRegistry` call — `cloneDeps`
  stays a closure param through W-A3; dropped in W6),
  `test/Seal/ISA/Ops/*Spec.hs` (extend — run opcodes via `mkLocalUIO`;
  Git specs via `mkTestUIOEnv` with stub `CloneDeps`),
  `test/Seal/ISA/Ops/UIOGitScopingSpec.hs` (new — the W-A3 CI grep
  guard as a test spec), `seal-harness.cabal`, `test/Main.hs`.
  (The `aeUntrustedIO` → `aeUIOEnv` rename + dispatch `runUIOWithEnv`
  rewire + `Channels/Loop.hs`/`Channel/Cli.hs` dispatch-site changes +
  `src/Seal/Agent/Runtime/Delegation/Worker.hs` + the ~30 test
  `AgentEnv` construction sites all land in **W6**, not W-A3 — see W6
  file scope.)

### W1 — The `WorkdirFs` handle + local/in-memory stubs
**DoD:**
- `WorkdirFs` record + `WorkdirFsErr` ADT (§3.2 pinned constructors) in
  a new `src/Seal/Tools/Exec/WorkdirFs.hs`, constructor unexported.
- `mkLocalWorkdirFs :: WorkspaceRoot -> WorkdirFs` (local arm — direct
  `System.Directory`/`TIO.readFile` confined by `mkSafePath`, anchored
  at the workdir root). The operator scan-byte ceiling is captured
  internally (no per-call `Int` param on `wfsReadFile`).
- `mkInMemWorkdirFs :: Map RemotePath StubEntry -> WorkdirFs` where
  `StubEntry = FileContent Text | SymlinkTarget RemotePath | Directory
  [Text] | Missing`. The stub's `wfsReadFile` resolves symlink chains
  (depth-bounded), re-checks containment on the resolved path, rejects
  on escape (non-vacuous symlink model).
- `mkWorkdirFsStub :: WorkdirFs` (fail-closed: every read `Left WfsStub`,
  every existence check `False`, `wfsListDirectory` `Right []`).
- `wfsReadFile` applies `maxBootstrapFileBytes` + `truncateSection`
  internally on both arms; `wfsListDirectory` returns `Right []` on
  missing dir.
- New `WorkdirFsSpec`: local arm against a temp dir (with a real
  symlink fixture); in-memory stub arm against a seeded map (with
  `SymlinkTarget` entries); both assert read/exists/list/size/mtime +
  workdir-escape rejection (local via real symlink, stub via
  `SymlinkTarget` chain) + within-workdir-symlink allowed + oversize +
  fail-closed-stub + `wfsListDirectory`-missing-dir-→-`[]`.
- Wiring: `seal-harness.cabal` (exposed-module), `test/Main.hs`.
**RED**: `WorkdirFsSpec` — read/exists/list/size/mtime + workdir-escape
  rejection (non-vacuous on stub) + within-workdir-symlink allowed +
  oversize + stub-records-non-invocation-on-bad-path + missing-dir-→-`[]`.
**File scope**: `src/Seal/Tools/Exec/WorkdirFs.hs`,
  `test/Seal/Tools/Exec/WorkdirFsSpec.hs`, `seal-harness.cabal`,
  `test/Main.hs`.

### W2 — The remote arm over SSH (with `realpath` re-check)
**DoD:**
- `mkRemoteWorkdirFs :: UIOEnv -> WorkdirFs` (remote arm, built on
  `UIO`'s shell-exec per §3.12 — no direct `RemoteRunner`; the runner
  is owned by `UIO` and shared). Every method validates via
  `mkSafePathRemote` before any shell-exec call.
- `wfsReadFile` remote: (1) `realpath -f -- <abspath>` → resolved; (2)
  re-check containment on resolved path (reject `WfsPath` on escape);
  (3) `stat -c %s -- <resolved>` → reject `WfsOversize` if > ceiling;
  (4) `head -c <ceil> -- <resolved>` → raw `Text`. Preserves
  `Nothing`-on-oversize.
- `wfsDoesFileExist`/`wfsDoesDirectoryExist`/`wfsListDirectory`/`wfsFileSize`/`wfsModificationTime`
  remote per §3.5 table; `--` separator on all; `wfsListDirectory`
  returns `Right []` on missing dir.
- Every path shell-quoted via `shellQuote` + `--`; `mkSafePathRemote`
  rejection happens before the `RemoteRunner` is invoked (the stub
  runner in `WorkdirFsSpec` asserts non-invocation via the recorded-calls
  `IORef`).
- Remote-arm cases added to `WorkdirFsSpec` via a stub `RemoteRunner`
  (`mkFakeRemoteRunnerRecording`, in-process, no live SSH). Symlink
  cases use the stub runner seeded with a `realpath`-resolved fixture
  (the stub records the `realpath` call and returns the resolved path;
  the containment re-check then rejects on escape).
- **QuickCheck property**: `shellQuote` of every `mkSafePathRemote`-valid
  path contains no unescaped shell metacharacter.
**RED**: `WorkdirFsSpec` remote cases — bad path rejected pre-SSH
  (IORef empty); `realpath`-resolved symlink-escape rejected;
  read/exists/list/size/mtime over the stub runner; oversize
  (`stat`-first rejection); missing-dir-→-`[]`.
**File scope**: `src/Seal/Tools/Exec/WorkdirFs.hs`,
  `test/Seal/Tools/Exec/WorkdirFsSpec.hs`.

### W3 — `mkSessionExec` constructs `UIOEnv` (folds old W-A4)
**DoD:**
- `SessionExec` record (`seUIOEnv`, `seWorkdirFs`, `seWorkspaceRoot`)
  + `mkSessionExec :: SealPaths -> SecurityConfig -> SessionId ->
  RemoteRunner -> IO SessionExec` in `Seal.Session.Workdir` (takes the
  `RemoteRunner` explicitly so tests can inject
  `mkFakeRemoteRunnerRecording`). `seUIOEnv` carries the `UntrustedIO`
  + `CloneDeps` (round-5 — replaces round-3's `seUntrustedIO`).
- `mkSessionExec` constructs the `UIOEnv` (selecting local vs remote
  via `untrustedExecConfigFromSecurity`, creating the workdir,
  building `UntrustedIO` + `CloneDeps`), builds `WorkdirFs` (W2's
  remote arm via `runUIOWithEnv uioEnv`, local arm via
  `System.Directory`), and returns the `SessionExec`.
- `mkSessionUntrustedIO` back-compat wrapper refactored to
  `(\exec -> uieUntrustedIO (seUIOEnv exec)) <$> mkSessionExec paths
  secCfg sid mkRealRemoteRunner` (for any lingering caller that wants
  just the handle; threads `mkRealRemoteRunner`, preserving EXACT
  current semantics).
- Mode resolution + remote-workdir creation run **once**; `UIO` and
  `WorkdirFs` share the same `WorkspaceRoot` / cloned `SshConfig` /
  the **single `RemoteRunner` passed in** (one SSH connection, not
  two — `WorkdirFs`'s remote arm reaches it via `runUIOWithEnv`).
  Fail-closed stub path does NOT invoke the runner (returns both
  stubs first).
- Fail-closed: on ANY workdir-creation failure, BOTH `seUIOEnv` (stub)
  + `seWorkdirFs` (stub) + `seWorkspaceRoot` (fail-closed root) —
  never mixed.
- New/extended `SessionWorkdirSpec` cases (use
  `mkFakeRemoteRunnerRecording` — no real SSH): (a) local mode → local
  `WorkdirFs` + local `seUIOEnv` (local `UntrustedIO` + `CloneDeps`) +
  local `seWorkspaceRoot`; (b) remote mode + configured → both
  remote-shaped, share `scWorkspace`, the **same** `RemoteRunner`
  instance is shared (assert the runner's recorded-calls `IORef` shows
  BOTH `UIO`'s AND `WorkdirFs`'s calls went to one runner — proves
  `WorkdirFs`-on-`UIO`); (c) remote mode + unreachable/misconfigured
  → both stubs (runner NOT invoked — `IORef` empty); (d) local mode +
  workdir `mkdir` fails → both stubs (fail-closed parity); (e)
  `mkSessionUntrustedIO` and
  `(uieUntrustedIO . seUIOEnv <$> mkSessionExec ... mkRealRemoteRunner)`
  yield equivalent `UntrustedIO` handles (back-compat).
**RED**: `SessionWorkdirSpec` — the five cases (all via the fake
  runner; no real SSH). Case (b) is the round-5 folded W-A4 assertion
  (one runner shared between `UIO` and `WorkdirFs`).
**File scope**: `src/Seal/Session/Workdir.hs`,
  `src/Seal/Tools/Exec/WorkdirFs.hs` (remote arm via `runUIOWithEnv`,
  per W2), `test/Seal/Config/WorkdirSpec.hs` (the existing spec —
  module `Seal.Config.WorkdirSpec`, importing `Seal.Session.Workdir`;
  extend it), `seal-harness.cabal`.

### W4 — Rewire `workdirAgentDefBackend` to `WorkdirFs` (+ back-compat wrapper)
**DoD:**
- The new `WorkdirFs`-taking function is named
  `workdirAgentDefBackendFs :: WorkdirFs -> IO AgentDefBackend` (distinct
  name — Haskell can't hold two same-named functions with different
  signatures).
- **ALL** workdir-reading functions in `Seal.Agent.Def.Backend` take
  `WorkdirFs` (full call-chain, §3.6): `readSection`,
  `composeDirSystemPrompt` (EXPORTED — test call sites update),
  `loadDirAgentConfig`, `dirMTime`, `loadDirAgentDef`,
  `loadProjectAgentDef`, `loadProtocolSubAgent`, `listWorkdirAgentDefs`,
  `listAgentsDotAgents`, `listProtocolAgentDefs`, `isProtocolRoot`.
- `readBoundedFile` REMOVED (logic in `wfsReadFile`);
  `listWorkdirSubdirs` REMOVED (subsumed by `wfsListDirectory`).
- Every `System.Directory` / `TIO.readFile` call in the workdir functions
  replaced by a `WorkdirFs` method call; backend `mkSafePath` calls
  REMOVED (confinement in the handle).
- **Back-compat wrapper**: the EXPORTED name `workdirAgentDefBackend`
  keeps its current `FilePath -> IO AgentDefBackend` signature during
  W4/W5, delegating to `workdirAgentDefBackendFs . mkLocalWorkdirFs .
  WorkspaceRoot` — so existing call sites (`Send.hs`, `API.hs`,
  `Channels/Loop.hs`, `Channel/Cli.hs`, and the tests) still compile
  and the suite stays green. W6 removes this wrapper and promotes
  `workdirAgentDefBackendFs` to the exported `workdirAgentDefBackend`
  name.
- Existing `AgentDefBackendSpec`/`RepoDiscoverySpec` pass with the
  mechanical `mkLocalWorkdirFs (WorkspaceRoot tmp)` adapter. **Call-site
  counts** (corrected): `RepoDiscoverySpec` has 13 workdir call sites
  (9 `workdirAgentDefBackend` + 4 `workdirSkillBackend`); `BackendSpec`
  has 2 (`composeDirSystemPrompt` at lines 176/187). Total ≈15 in
  agent-def specs (skill-spec counts in W5). Test logic unchanged;
  only the backend-construction call wraps.
- **Symlink-escape test fixture (non-vacuous)**: the existing
  `RepoDiscoverySpec` symlink-escape test (line 239) has its symlink
  target moved OUTSIDE the workdir root (e.g.
  `/tmp/seal-escape-target-<unique>/secret.txt`, NOT under `tmp`) —
  otherwise the updated workdir-anchored assertion would pass vacuously
  (the target is still within the workdir). The assertion asserts
  escape-from-**workdir** (updated from escape-from-`.agents/`). A new
  test asserts a within-workdir symlink (target inside workdir, outside
  `.agents/`) is **allowed** (documenting the intentional behavior).
- New remote-arm case: build the backend over a stub-remote `WorkdirFs`
  (via `mkFakeRemoteRunnerRecording`) seeded with a fixture repo's
  files (including a symlinked `agents.md` escaping the workspace →
  rejected by the `realpath` re-check; a within-workdir symlink →
  allowed); assert the same discovery results as the local fixture
  (the §1.1 success metric — headline test).
- **Compile-fail fixture** `Seal.Agent.Def.Backend.NoDirectFsFail`
  asserting the workdir functions don't import
  `System.Directory`/`Data.Text.IO`.
**RED**: the remote-arm discovery test (fails until the backend is
  rewired + the stub `WorkdirFs` is wired).
**File scope**: `src/Seal/Agent/Def/Backend.hs`,
  `test/Seal/Agent/Def/BackendSpec.hs`, `test/Seal/RepoDiscoverySpec.hs`
  (extend), `test/Seal/Agent/Def/BackendNoDirectFsFail.hs` (new
  compile-fail fixture), `seal-harness.cabal` (fixture wiring).

### W5 — Rewire `workdirSkillBackend` to `WorkdirFs` (+ back-compat wrapper)
**DoD:**
- The new `WorkdirFs`-taking function is named
  `workdirSkillBackendFs :: WorkdirFs -> IO SkillBackend` (distinct name
  — same rationale as W4).
- **ALL** workdir-reading functions in `Seal.Skills.Backend` (the
  `workdir*` functions only — NOT the user store) take `WorkdirFs`:
  `listWorkdirSkills`, `listAgentSkillsDir`, `listTopLevelSkills`,
  `listGroupedSkills`, `listSubdirs` (removed-into-`wfsListDirectory`).
- Every `System.Directory` / `TIO.readFile` in the workdir functions
  replaced by `WorkdirFs` calls.
- **Back-compat wrapper**: the EXPORTED name `workdirSkillBackend`
  keeps its current `FilePath -> IO SkillBackend` signature during
  W4/W5, delegating to
  `workdirSkillBackendFs . mkLocalWorkdirFs . WorkspaceRoot`. W6
  removes it and promotes `workdirSkillBackendFs` to the exported name.
- Existing tests pass with the mechanical adapter. **Call-site counts**
  (corrected): `SkillBackendSpec` has 0 `workdirSkillBackend` calls
  (it tests the user store only, which is NOT changing per §3.9); the
  4 `workdirSkillBackend` call sites are in `RepoDiscoverySpec.hs`
  (lines 71, 95, 108, 121). Total workdir-skill test call sites = 4
  (all in `RepoDiscoverySpec`).
- New remote-arm case: stub-remote `WorkdirFs` (via
  `mkFakeRemoteRunnerRecording`) seeded with `.skills/<id>/SKILL.md`;
  assert the skill is discovered. Plus a symlinked `SKILL.md` escaping
  the workspace → rejected (parity with W4).
- **Compile-fail fixture** `Seal.Skills.Backend.NoDirectFsFail`.
**RED**: the remote-arm skill discovery test.
**File scope**: `src/Seal/Skills/Backend.hs`,
  `test/Seal/RepoDiscoverySpec.hs` (extend — the workdir-skill call
  sites are here, not in `SkillBackendSpec`),
  `test/Seal/Skills/BackendNoDirectFsFail.hs` (new),
  `seal-harness.cabal`.

### W6 — Rewire wiring sites + `adSecurityConfig` + UIO dispatch rewire + remove back-compat wrappers (RED: API integration)
**DoD:**
- `Send.hs:461-476`, `API.hs:793-794`, `Channels/Loop.hs` sites,
  `Channel/Cli.hs` sites: replace `mkSessionUntrustedIO` +
  `ensureSessionWorkdir` + `workdirAgentDefBackend wd` +
  `Skill.workdirSkillBackend wd` with
  `mkSessionExec paths secCfg sid mkRealRemoteRunner` +
  `seWorkdirFs`/`seWorkspaceRoot`/`seUIOEnv`, calling the `Fs`-suffixed
  backend functions (`workdirAgentDefBackendFs`, `workdirSkillBackendFs`).
- Remove the W4/W5 back-compat `FilePath` wrappers; promote
  `workdirAgentDefBackendFs` → `workdirAgentDefBackend` (and the skill
  equivalent) at the exported name.
- **UIO dispatch rewire (deferred from W-A3)**: the `aeUntrustedIO ::
  UntrustedIO` field in `AgentEnv` (`Loop.hs:374` +
  `src/Seal/Agent/Runtime/Delegation/Worker.hs:170` +
  `src/Seal/Channels/Loop.hs` + `src/Seal/Channel/Cli.hs`) renames to
  `aeUIOEnv :: UIOEnv`; the dispatch call sites become
  `dispatch ... aeUIOEnv ...`. The dispatcher (`Dispatch.hs`) rewires
  from `uoRunLegacy` to `runUIOWithEnv uioEnv (uoRun op input)`.
  `uoRunLegacy` is removed. Git opcode constructors DROP their
  `CloneDeps` closure param (they source `CloneDeps` from
  `seUIOEnv`/`uioCd*`); `buildWebRegistry` drops `cloneDeps`.
  - **Wide mechanical change (~30 test `AgentEnv` sites)**: every
    test that constructs an `AgentEnv` with `aeUntrustedIO =
    mkRemoteUntrustedIOStub` (`LoopSpec`: ~25 sites, `Phase2bSpec`,
    `Phase5Spec`, `Phase7aSpec`, `WiringSpec`, `SignalRunSpec`,
    `CliSpec`) updates to `aeUIOEnv = <UIOEnv from mkTestUIOEnv or
    mkUIOStub>`. Plus the 4 production sites (`Send.hs`,
    `Channels/Loop.hs`, `Channel/Cli.hs`, `Worker.hs`).
- `wsroot` sourced from `seWorkspaceRoot exec` (not `wfsRoot` — dropped).
- `ApiDeps` gains `adSecurityConfig :: SecurityConfig`. **Construction
  sites to update (wide mechanical change)**: ~20 `ApiDeps` literals in
  `test/Seal/Gateway/ApiSpec.hs` (lines ~1546, 1619, 1684, 1752, 1843,
  1899, 1954, 1990, 2078, 2132, 2185, 2232, 2288, 2622, 2663, 2900,
  3005, 3098, 3223, 3333), `test/Seal/Gateway/ServerSpec.hs:61`,
  `test/Seal/Gateway/Phase7aSpec.hs:75/129`, and the production
  construction at `src/Seal/Gateway/Serve.hs:243`. Each adds the
  `adSecurityConfig` field. `handleSessionAgents` calls
  `mkSessionExec paths adSecurityConfig sid <runner>` (the runner is
  sourced from `ApiDeps` or constructed at the handler — pin during
  implementation; the handler is a read-only REST endpoint so a fresh
  `mkRealRemoteRunner` per call is acceptable, or share one on
  `ApiDeps`).
- **Capability-scoping CI-enforced grep check** (mirrors the
  `CapabilityScopingFail` compile-fail discipline for `UntrustedIO`):
  a grep in the W6 test (or a new `Seal.CapabilityScopingWorkdirFsFail`
  fixture) asserting NO `WorkdirFs` field AND NO `UIOEnv` field appears
  in `AppEnv`, the ISA registry env record types, or any module under
  `src/Seal/ISA/Ops/` (the opcode implementations). The `SessionExec`
  record is consumed at the turn-entry site; `seWorkdirFs` /
  `seUIOEnv` are passed ONLY to the discovery backends / dispatcher
  respectively. (The handles MAY be captured in backend closures used
  during opcode dispatch — §3.1 — but opcodes only receive the backends'
  typed interfaces, never `WorkdirFs`/`UIOEnv` directly. `UIOEnv` is
  threaded to `dispatch`, which runs the opcode via
  `runUIOWithEnv`; the opcode body in `UIO` has no `UIOEnv` access.)
- **RED (concrete)**: `ApiSpec` case — `GET /api/sessions/:id/agents`
  in `mode=remote` (with `mkSessionExec` injected with
  `mkFakeRemoteRunnerRecording` and a stub-remote `WorkdirFs` seeded
  with a fixture repo's `.agents/agents.md`) returns ≥1 repo-local def
  (the user-visible success metric). This is the headline integration
  test. (A gateway/channel first-turn-system-prompt integration test is
  a W7 stretch goal, not a W6 DoD item — the primary `ApiSpec` RED is
  the gate.)
**RED**: `ApiSpec` remote-mode `handleSessionAgents` case.
**File scope**: `src/Seal/Gateway/Send.hs`, `src/Seal/Gateway/API.hs`,
  `src/Seal/Gateway/Serve.hs` (the production `ApiDeps` construction),
  `src/Seal/Channels/Loop.hs`, `src/Seal/Channel/Cli.hs`,
  `src/Seal/ISA/Dispatch.hs` (the `runUIOWithEnv` rewire + drop
  `uoRunLegacy`), `src/Seal/ISA/Opcode.hs` (drop `uoRunLegacy`),
  `src/Seal/Agent/Loop.hs` (`aeUntrustedIO` → `aeUIOEnv`),
  `src/Seal/Agent/Runtime/Delegation/Worker.hs` (same field rename),
  `src/Seal/ISA/Ops/Git.hs` (drop `CloneDeps` closure param),
  `test/Seal/Gateway/ApiSpec.hs` (extend — ~20 `ApiDeps` literals + the
  RED case), `test/Seal/Gateway/ServerSpec.hs`,
  `test/Seal/Gateway/Phase7aSpec.hs`,
  `test/Seal/Agent/{LoopSpec,Phase2bSpec,Phase5Spec,Phase7aSpec,
  WiringSpec,SignalRunSpec,CliSpec}.hs` (~30 `aeUntrustedIO` →
  `aeUIOEnv` test sites),
  `test/Seal/CapabilityScopingWorkdirFsFail.hs` (new grep/compile-fail
  fixture — asserts no `WorkdirFs`/`UIOEnv` in `AppEnv`/registry/opcode
  modules), `seal-harness.cabal` (fixture wiring).

### W7 — Gate
`make check` green (build + test + lint, `-Werror` clean, `hlint` → No
hints). Compile-fail fixtures (`NoDirectFsFail`) assert green (they
FAIL to compile when `System.Directory` is imported).

## 7. Human checkpoints

1. **After this design doc (review-gate round 6, with `UIO` augmentation)**
   — confirm §3.10 (`UIO` monad: no `MonadIO`, two smart constructors +
   `runUIOWithEnv`), §3.11 (module-level `uio*` + `uioCd*` in separate
   `UIOGit` module), §3.12 (`WorkdirFs`-on-`UIO` via
   `runUIOWithEnv`), plus the round-3 confirmations (§3.1 capability
   scoping, §3.5 `realpath` re-check, §3.6 full call-chain migration).
2. **After W-A1/W-A2 (`UIO` + compile-fail fixtures)** — review the
   `UIO` restriction (no `MonadIO`), the two smart constructors +
   `runUIOWithEnv`, the `uio*`/`uioCd*` surface, and the compile-fail
   fixtures assert the restriction, before W-A3.
3. **After W-A3 (opcode body migration)** — review every untrusted
   opcode body for residual `liftIO`/`ask`/`System.Directory` imports
   (should be none), the `uoRun` signature change (`Value -> UIO
   OpResult`), the `uoRunLegacy` back-compat wrapper (dispatcher keeps
   old `UntrustedIO`-based path; `aeUntrustedIO` stays `UntrustedIO`;
   Git constructors KEEP `CloneDeps`), and the W-A3 CI grep guard
   (`UIOGit` scoped to `Git.hs`), before W1.
4. **After W2/W3 (`WorkdirFs` remote arm on `UIO`; `mkSessionExec`
   constructs `UIOEnv`)** — review the single shared `RemoteRunner`
   (one SSH connection, `WorkdirFs`'s remote arm via `runUIOWithEnv`),
   `WorkdirFs`'s file-path confinement (own `mkSafePathRemote` +
   `realpath`, layered on `UIO`'s CWD confinement), and the W3 case (b)
   assertion (both `UIO`'s and `WorkdirFs`'s calls on one runner),
   before W4.
5. **After W4/W5 (backend rewire)** — review that no direct
   `System.Directory`/`TIO.readFile` remains in the workdir backends
   (compile-fail fixture green), local-arm parity tests pass, and the
   remote-arm symlink-escape test is non-vacuous, before W6.
6. **After W6 (wiring sites + UIO dispatch rewire)** — review all
   four entry points + `ApiDeps.adSecurityConfig` wiring + the
   `aeUntrustedIO → aeUIOEnv` rename + dispatch `runUIOWithEnv` rewire
   (drop `uoRunLegacy`) + Git `CloneDeps` closure drop + the ~30 test
   `AgentEnv` sites + the capability-scoping CI grep (no `WorkdirFs`/
   `UIOEnv` in `AppEnv`/registry/opcode modules) before the final
   gate.

## 8. Alternatives considered + known limitations

- **`UIO` as a restricted monad (round 4 augmentation).** Adopted —
  turns the "no direct FS in opcodes" convention into a type-level
  guarantee (no `MonadIO` instance; compile-fail fixtures). The sole
  execution context for untrusted opcodes; two smart constructors
  mirror the two modes. Categorically eliminates future local/remote
  parity gaps. `WorkdirFs`'s remote arm is built on `UIO`'s
  shell-exec, unifying the transport.
- **Extend `UntrustedIO` with raw-read + metadata methods, thread it
  into the backends.** Rejected — `UntrustedIO` is the opcode capability
  handle; holding one in Trusted prompt-assembly code blurs the
  capability-scoping invariant (§3.1). A separate, narrower handle
  keeps the boundary sharp. (`UIO` wraps `UntrustedIO`; `WorkdirFs`
  stays separate.)
- **Make `WorkdirFs` a typeclass with local/remote instances.** Rejected
  — the codebase uses the handle pattern (`ReaderT AppEnv IO` + handles),
  not typeclasses, deliberately (AGENTS.md "No effect systems"). A
  record of IO actions is the idiomatic shape here. (`UIO` uses
  module-level `UIO`-typed functions for its *operation* surface — not
  a `MonadUIO` class (a single-instance class would be a smell); the
  carrier is a concrete `newtype UIO`, not a typeclass-polymorphic
  stack. The `CloneDeps` surface lives in a separate `UIOGit` module
  for lexical scoping.)
- **Keep the backends on `FilePath` and add a "remote FS adapter" that
  materializes the remote workdir locally on demand.** Rejected —
  materializing the whole repo locally on the control plane defeats the
  two-plane split (the control plane would hold a copy of untrusted
  workspace files). The whole point of `mode=remote` is that the
  workspace lives on the untrusted plane only.
- **Have the backends shell out via `uioShellExec` (`cat`/`ls`/`test`).**
  Rejected as a direct backend call — the backends would need an
  `UntrustedIO`/`UIO` (scoping), and `cat`-parsing is less robust than
  a typed `wfsReadFile`. (`WorkdirFs`'s remote arm DOES use `UIO`'s
  shell-exec internally, but behind a typed `WorkdirFs` interface —
  the best of both.)
- **Do nothing; document that repo-local discovery is local-mode
  only.** Rejected — the issue reports a real regression; `mode=remote`
  is a supported, security-first configuration and the
  repo-agents-dropdown feature is advertised to work in it.
- **KNOWN LIMITATION — SSH round-trip batching:** the remote arm makes
  N SSH round-trips per discovery scan (per `doesFileExist`/
  `listDirectory`/`readFile`/`stat`). For a workdir with many repos,
  this is latency (mirrors today's per-call local pattern, but each call
  is a network round-trip in remote mode). Not blocking for pre-alpha
  (small workdirs). Cheap future mitigation: a single batched
  `ssh ... -- find <root> -maxdepth 3 -type f \\( -name agent.md -o
  -name agents.md -o -name SKILL.md \\)` that returns all discovery
  files in one round-trip, parsed client-side. Tracked as future work;
  the per-call `WorkdirFs` interface is forward-compatible with a
  batched implementation behind the same seam.
- **KNOWN LIMITATION — remote `stat` flavor:** the remote arm uses
  `stat -c %s`/`stat -c %Y` (GNU coreutils). The SSH target is Linux by
  convention. If the target could be macOS, `stat -f %z`/`stat -f %m`
  would be needed; a portable `wc -c` fallback exists for `wfsFileSize`.
  Config validation may pin the target OS if non-Linux targets must be
  supported; for now, Linux-only is the assumption (consistent with the
  existing `uioReadFile` remote arm).