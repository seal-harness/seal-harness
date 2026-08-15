# Remote-Aware Workdir Filesystem Seam — Design

> **Status:** Draft (round 3, post-review-gate). **Branch**:
> `fix/remote-workdir-fs-seam-106`. **Issue**: #106. Closes the remote-mode
> regression in repo-local agent-def and skill discovery.

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

**`SessionExec` record:**
```haskell
data SessionExec = SessionExec
  { seUntrustedIO   :: UntrustedIO
  , seWorkdirFs     :: WorkdirFs
  , seWorkspaceRoot :: WorkspaceRoot
    -- ^ The shared workspace root used by BOTH handles (local path for
    -- the local arm, remote workspace path string for the remote arm).
    -- The ISA registry sources its 'wsroot' from here, NOT from a
    -- handle accessor. This avoids the type-confusion of extracting a
    -- root from 'WorkdirFs' (which would be a remote path string in
    -- remote mode, unsafe to feed to local 'mkSafePath').
  }
```

**Shared workspace root + shared `RemoteRunner`:** `mkSessionExec` runs
the mode resolution and remote-workdir creation **once**, then builds
both handles against the same `WorkspaceRoot` and the same `SshConfig`,
sharing the **single `RemoteRunner` passed in** between `seUntrustedIO`
and `seWorkdirFs` (one SSH connection, not two — today
`mkSessionUntrustedIO` creates one via `mkRealRemoteRunner`; the fold
preserves that count by taking the runner as a param and reusing it).
The fail-closed stub path does NOT construct/invoke a runner at all
(returns both stubs before reaching the runner).

**Back-compat:** `mkSessionUntrustedIO` is kept as a thin wrapper
(`seUntrustedIO <$> mkSessionExec paths secCfg sid mkRealRemoteRunner`)
so existing opcode-wiring sites that only need the opcode handle are
unchanged (the wrapper threads `mkRealRemoteRunner`, preserving the
current opaque-runner behavior). The wrapper preserves the EXACT current
semantics (same workdir created, same stub on failure);
`SessionWorkdirSpec` asserts `mkSessionUntrustedIO` and
`(seUntrustedIO <$> mkSessionExec ... mkRealRemoteRunner)` yield
equivalent handles (same root, same arm).

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

The remote arm implements each method over SSH on the existing
`RemoteRunner` (the same transport `UntrustedIO`'s remote arm uses):

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
let untrustedIO   = seUntrustedIO   exec
    workdirFs     = seWorkdirFs     exec
    wsroot        = seWorkspaceRoot exec
... workdirAgentDefBackendFs workdirFs ... Skill.workdirSkillBackendFs workdirFs
```

(Production wiring passes `mkRealRemoteRunner`; tests pass
`mkFakeRemoteRunnerRecording`. The single runner is shared between
`seUntrustedIO` and `seWorkdirFs`.)

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
- `mkRemoteWorkdirFs :: SshConfig -> RemoteRunner -> WorkdirFs` (remote
  arm). Every method validates via `mkSafePathRemote` before any SSH
  call.
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

### W3 — `mkSessionExec` construction seam
**DoD:**
- `SessionExec` record (`seUntrustedIO`, `seWorkdirFs`,
  `seWorkspaceRoot`) + `mkSessionExec :: SealPaths -> SecurityConfig ->
  SessionId -> RemoteRunner -> IO SessionExec` in `Seal.Session.Workdir`
  (takes the `RemoteRunner` explicitly so tests can inject
  `mkFakeRemoteRunnerRecording`).
- `mkSessionUntrustedIO` refactored to
  `seUntrustedIO <$> mkSessionExec paths secCfg sid mkRealRemoteRunner`
  (back-compat — existing opcode-wiring sites unchanged; wrapper
  threads `mkRealRemoteRunner`, preserving EXACT current semantics).
- Mode resolution + remote-workdir creation run **once**; both handles
  share the same `WorkspaceRoot` / cloned `SshConfig` / the **single
  `RemoteRunner` passed in** (one SSH connection, not two). Fail-closed
  stub path does NOT invoke the runner (returns both stubs first).
- Fail-closed: on ANY workdir-creation failure, BOTH handles are stubs
  + `seWorkspaceRoot` is a fail-closed root (never mixed).
- New/extended `SessionWorkdirSpec` cases (use
  `mkFakeRemoteRunnerRecording` — no real SSH): (a) local mode → local
  `WorkdirFs` + local `UntrustedIO` + local `seWorkspaceRoot`; (b)
  remote mode + configured → both remote-shaped, share `scWorkspace`,
  the **same** `RemoteRunner` instance is shared (assert the runner's
  recorded-calls `IORef` shows both handles' calls went to one runner);
  (c) remote mode + unreachable/misconfigured → both stubs (runner NOT
  invoked — `IORef` empty); (d) local mode + workdir `mkdir` fails →
  both stubs (fail-closed parity); (e) `mkSessionUntrustedIO` and
  `(seUntrustedIO <$> mkSessionExec ... mkRealRemoteRunner)` yield
  equivalent handles (same root, same arm).
**RED**: `SessionWorkdirSpec` — the five cases (all via the fake
  runner; no real SSH).
**File scope**: `src/Seal/Session/Workdir.hs`,
  `test/Seal/Config/WorkdirSpec.hs` (the existing spec — module
  `Seal.Config.WorkdirSpec`, importing `Seal.Session.Workdir`; extend
  it).

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

### W6 — Rewire wiring sites + `adSecurityConfig` + remove back-compat wrappers (RED: API integration)
**DoD:**
- `Send.hs:461-476`, `API.hs:793-794`, `Channels/Loop.hs` sites,
  `Channel/Cli.hs` sites: replace `mkSessionUntrustedIO` +
  `ensureSessionWorkdir` + `workdirAgentDefBackend wd` +
  `Skill.workdirSkillBackend wd` with
  `mkSessionExec paths secCfg sid mkRealRemoteRunner` +
  `seWorkdirFs`/`seWorkspaceRoot`, calling the `Fs`-suffixed backend
  functions (`workdirAgentDefBackendFs`, `workdirSkillBackendFs`).
- Remove the W4/W5 back-compat `FilePath` wrappers; promote
  `workdirAgentDefBackendFs` → `workdirAgentDefBackend` (and the skill
  equivalent) at the exported name.
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
  fixture) asserting NO `WorkdirFs` field appears in `AppEnv`, the ISA
  registry env record types, or any module under `src/Seal/ISA/Ops/`
  (the opcode implementations). The `SessionExec` record is consumed at
  the turn-entry site; `seWorkdirFs` is passed ONLY to the discovery
  backends. (The handle MAY be captured in backend closures used during
  opcode dispatch — §3.1 — but opcodes only receive the backends' typed
  interfaces, never `WorkdirFs` directly.)
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
  `test/Seal/Gateway/ApiSpec.hs` (extend — ~20 `ApiDeps` literals + the
  RED case), `test/Seal/Gateway/ServerSpec.hs`,
  `test/Seal/Gateway/Phase7aSpec.hs`,
  `test/Seal/CapabilityScopingWorkdirFsFail.hs` (new grep/compile-fail
  fixture), `seal-harness.cabal` (fixture wiring).

### W7 — Gate
`make check` green (build + test + lint, `-Werror` clean, `hlint` → No
hints). Compile-fail fixtures (`NoDirectFsFail`) assert green (they
FAIL to compile when `System.Directory` is imported).

## 7. Human checkpoints

1. **After this design doc (review-gate round 2)** — confirm §3.1
   (capability-scoping invariant), §3.5 (`realpath` re-check),
   §3.3 (`SessionExec` + `seWorkspaceRoot`), §3.6 (full call-chain
   migration) before implementation.
2. **After W2 (remote arm)** — review the SSH command shapes +
   `realpath`-re-check + pre-SSH `mkSafePathRemote` rejection +
   `--` separators before W3.
3. **After W4/W5 (backend rewire)** — review that no direct
   `System.Directory`/`TIO.readFile` remains in the workdir backends
   (compile-fail fixture green), local-arm parity tests pass, and the
   remote-arm symlink-escape test is non-vacuous, before W6.
4. **After W6 (wiring sites)** — review all four entry points +
   `ApiDeps.adSecurityConfig` wiring + the capability-scoping
   review-checklist before the final gate.

## 8. Alternatives considered + known limitations

- **Extend `UntrustedIO` with raw-read + metadata methods, thread it
  into the backends.** Rejected — `UntrustedIO` is the opcode capability
  handle; holding one in Trusted prompt-assembly code blurs the
  capability-scoping invariant (§3.1). A separate, narrower handle
  keeps the boundary sharp.
- **Make `WorkdirFs` a typeclass with local/remote instances.** Rejected
  — the codebase uses the handle pattern (`ReaderT AppEnv IO` + handles),
  not typeclasses, deliberately (AGENTS.md "No effect systems"). A
  record of IO actions is the idiomatic shape here.
- **Keep the backends on `FilePath` and add a "remote FS adapter" that
  materializes the remote workdir locally on demand.** Rejected —
  materializing the whole repo locally on the control plane defeats the
  two-plane split (the control plane would hold a copy of untrusted
  workspace files). The whole point of `mode=remote` is that the
  workspace lives on the untrusted plane only.
- **Have the backends shell out via `uioShellExec` (`cat`/`ls`/`test`).**
  Rejected — the backends would need an `UntrustedIO` (same scoping
  problem), and `cat`-parsing is less robust than a typed `wfsReadFile`.
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