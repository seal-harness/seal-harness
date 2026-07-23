# Design: Per-Session Workdir Isolation

> **Status:** Draft v3 (2026-07-23). GitHub Issue: #50.
> Addresses: sessions sharing a single workspace root (the cwd) →
> per-session isolated workdirs.
>
> **Review gate:** round 1 all 5 NEEDS_REVISION; round 2 (Architect +
> Designer APPROVED, PM/Security/CTO NEEDS_REVISION). This v3 addresses
> the remaining blockers (see §9 changelog).
>
> **Decision (user):** chroot is deferred to a container/VM follow-up
> (the security reviewer found it non-functional as designed — no
> rootfs, priv-drop, perm issues). Per-session workdir + SafePath is the
> isolation boundary. No `enabled` opt-out — workdir is always on
> (breaking change for shared-cwd users; they can symlink the workdir to
> their checkout).

## 1. Users & Use Cases

### Personas

1. **Eval developer** — runs parallel benchmark sessions. WANTS each
   session's files isolated so they don't clobber each other. SO THAT
   benchmark results are reproducible. WHEN they start N sessions via
   the web gateway.
2. **Remote-harness operator** — runs Seal in `mode=remote` against an
   SSH sandbox. WANTS each session to get a fresh remote directory. SO
   THAT a compromised model in session A cannot read session B's files
   on the remote machine. WHEN sessions are started in parallel.
3. **Single-session CLI user** — runs Seal in their repo checkout. Today
   the cwd IS the workspace. After this change, the workdir is
   `~/.seal/cache/workdirs/<sid>` — a fresh empty dir, NOT the repo.
   This is a breaking change: the user's existing files are no longer in
   the workspace. **Migration:** symlink `~/.seal/cache/workdirs/<sid>`
   to the repo, or copy files in. (Future: a `workdir_base` config could
   point the workdir at a checkout, but that's out of scope for #50.)

### Use cases (WHO/WANTS/SO THAT/WHEN)

- **UC1 (eval developer):** As an eval developer, I want each session to
  get a fresh isolated workdir, so that parallel sessions don't clobber
  each other's files, when I run 4 sessions concurrently.
- **UC2 (remote operator):** As a remote-harness operator, I want each
  session to create its own remote subdirectory, so that sessions are
  file-isolated on the remote machine, when sessions start in
  `mode=remote`.
- **UC3 (operator inspection):** As an operator, I want the workdir to
  persist after the session ends, so that I can inspect what the model
  did, when a session completes.
- **UC4 (single-session user):** As a single-session user, I want my
  repo files accessible in the workdir, so that the model can read/edit
  my code, when I start a session. (Breaking: requires a symlink or
  copy; no config override in #50.)

### Out of scope
- **Cross-session file sharing** — no path for session B to read
  session A's output. Future "shared workdir" feature.
- **Disk-growth** — workdirs persist; many sessions accumulate disk.
  Future `cache_size_limit` or LRU-eviction. Operator can `rm -rf
  ~/.seal/cache/workdirs/` manually.
- **Chroot/container/VM isolation** — deferred. The per-session workdir
  + SafePath is the isolation boundary. A container/VM-per-session
  follow-up would add a hard boundary (future issue).
- **`workdir_base` config override** — a future config to point the
  workdir at a checkout (for the UC4 user). Out of scope for #50.

### Success metrics
- **UC1:** Session A writes `out.txt` = "A"; session B writes `out.txt`
  = "B"; session A reads `out.txt` → "A" (not "B"). 100% of trials.
- **UC2:** Remote `FILE_WRITE` lands in
  `scWorkspace/workdirs/<sid>`; a second session's writes land in a
  different `<sid2>`. 100% of trials.
- **Session-start latency:** local workdir creation adds < 5ms (one
  `mkdir -p`); remote adds < 500ms (one SSH round-trip). Failure
  criterion: if remote adds > 2s, revisit (high-latency SSH).
- **No regression:** existing test suite passes (updated to use
  per-session workdir fixtures).

## 2. Problem

Today the untrusted opcodes' `WorkspaceRoot` is the harness process's
cwd (`getCurrentDirectory`), resolved once at startup and threaded to
every session. All sessions share it. In `mode=remote`, all sessions
share `SshConfig.scWorkspace`.

### What's wrong
1. **Sessions clobber each other.** `FILE_WRITE {path:"out.txt"}` in
   session A overwrites session B's `out.txt`.
2. **No fresh state per session.** A session inherits the files of
   every prior session run in the same cwd.
3. **No isolation boundary.** A compromised model can read/write any
   file the harness user can reach (the cwd + the full FS for
   SHELL_EXEC). SafePath confines file ops to the workspace root, but
   SHELL_EXEC can `cd /` and read anything. (A container/VM follow-up
   would close this; #50 closes the cross-session clobber.)

## 3. Goals

1. **Per-session workdir (always on).** Each session gets a fresh
   working directory at `~/.seal/cache/workdirs/<session-id>`. The
   untrusted opcodes' `WorkspaceRoot` is this directory, not the cwd.
2. **Remote mkdir.** In `mode=remote`, the workdir is created on the
   remote machine via SSH `mkdir -p`; the remote `UntrustedIO` arm uses
   it as the workspace root.
3. **Workdir persists by default.** `cleanup_on_exit = true` (default
   false) removes the workdir at session end.

## 4. Design

### 4.1 Config: the `[workdir]` section

```toml
[workdir]
# Remove the workdir when the session ends. Default false (persist for
# inspection). When true, the workdir is removed (rm -rf) at session-end.
cleanup_on_exit = false
```

New type in `Seal.Config.File`:

```haskell
data WorkdirConfig = WorkdirConfig
  { wdcCleanupOnExit :: Maybe Bool    -- absent = false (persist)
  }
```

The codec is a standard `dioptional`-wrapped table. Added to
`RuntimeConfig` as `rcWorkdir :: Maybe WorkdirConfig`.

> **No `enabled` field.** Per-session workdirs are always on — isolation
> is the default, not an opt-in. The only knob is `cleanup_on_exit`.

> **Breaking change (acknowledged):** users who rely on sessions sharing
> the cwd (collaborative human+agent editing, in-place CI inspection)
> get a behavior change. Migration: symlink
> `~/.seal/cache/workdirs/<sid>` to the checkout, or copy files in. A
> future `workdir_base` config could restore the old behavior; out of
> scope for #50.

> **Why RuntimeConfig, not SecurityConfig?** The workdir policy is
> operator-tunable runtime state, not a security invariant. The SafePath
> confinement is the load-bearing security check; the workdir location
> is an isolation/UX knob.

### 4.2 Paths: `spCache` + `workdirsRoot` + `sessionWorkdir`

Add `spCache` to `SealPaths`:

```haskell
data SealPaths = SealPaths
  { spHome   :: FilePath   -- ~/.seal
  , spConfig :: FilePath   -- ~/.seal/config
  , spState  :: FilePath   -- ~/.seal/state
  , spKeys   :: FilePath   -- ~/.seal/keys
  , spCache  :: FilePath   -- ~/.seal/cache  (NEW — per-session workdirs)
  }
```

Update `getSealPaths` + `ensureSealDirs` (create `spCache`).

Path builders (pure, no IO):

```haskell
workdirsRoot :: SealPaths -> FilePath
workdirsRoot paths = spCache paths </> "workdirs"

sessionWorkdir :: SealPaths -> SessionId -> FilePath
sessionWorkdir paths sid =
  workdirsRoot paths </> T.unpack (sessionIdText sid)
```

`sessionWorkdir` asserts `isValidSessionId sid` (defense-in-depth — see
§4.6).

### 4.3 The `UntrustedIO` workspace-root change

**The `UntrustedIO` type does NOT change.** It already takes a
`WorkspaceRoot` at construction. The only change is *what root is passed
at construction time* — `sessionWorkdir paths sid` instead of
`getCurrentDirectory`.

**The `untrustedIOFromSecurity` helper does NOT change signature**
(`WorkspaceRoot -> SecurityConfig -> UntrustedIO`). The wiring sites
compute the per-session `WorkspaceRoot` and pass it through. For remote
mode, the wiring site clones the `SshConfig` with `scWorkspace` set to
the remote per-session workdir before calling `mkRemoteUntrustedIO`.
This localizes the remote-workdir override at the call site and keeps
the helper's signature stable.

### 4.4 The workdir lifecycle

**At session start:**

The `SessionId` is bound BEFORE the `withTwoFileTranscript` bracket
opens (it's the session being started).

```
1. Compute workdir = sessionWorkdir paths sid
2. mode=local:
   a. ensureSessionWorkdir paths sid
      (createDirectoryIfMissing True workdir, mode 0700)
   b. ON FAILURE (perms/disk-full): abort session start with a hard
      error ("could not create session workdir: <reason>").
      Do NOT fall back to cwd (would reintroduce the clobber bug).
   c. wsRoot = WorkspaceRoot workdir
3. mode=remote:
   a. remoteWorkdir = scWorkspace/workdirs/<sid>
      (validated via mkSafePathRemote under scWorkspace)
   b. ensureRemoteSessionWorkdir sshCfg runner remoteWorkdir
      (ssh ... -- mkdir -p '<remoteWorkdir>')
      ON FAILURE (SSH error, host-key mismatch, non-zero exit):
        → abort session start with a hard error.
        → do NOT fall back to shared scWorkspace.
   c. sshCfg' = sshCfg { scWorkspace = either error id (mkRemotePath
       remoteWorkdirText) }  (re-validated via mkRemotePath)
   d. wsRoot = WorkspaceRoot remoteWorkdir
4. Construct untrustedIO via untrustedIOFromSecurity wsRoot secCfg
   (local) or mkRemoteUntrustedIO sshCfg' runner (remote).
```

**CLI per-turn concern:** the CLI rebuilds `untrustedIO` per turn inside
the `withTwoFileTranscript` bracket. The workdir creation is idempotent
(`createDirectoryIfMissing` / `mkdir -p` are no-ops if the dir exists),
so per-turn calls are safe but redundant. **Resolution:** hoist the
workdir creation to true session start (before the per-turn bracket),
cache `wsRoot`/`sshCfg'` in the per-session closure (the `SessionRecord`
/ `pr` / `paths` env — the same place `wsRoot` is resolved today), and
reuse across turns. No per-turn `mkdir`.

**At session end** (the bracket's cleanup):

```
If cleanup_on_exit = true:
   mode=local: cleanupSessionWorkdir paths sid
   mode=remote: ssh ... -- rm -rf '<remoteWorkdir>'
Otherwise: leave the workdir in place (persist for inspection)
```

**`/bg` (background) sessions:** `cleanup_on_exit` is a no-op for `/bg`
sessions in #50 (the background session's lifetime is managed by the
`/bg` runner, which may outlive the foreground turn). Known limitation;
full cleanup-on-last-reference is a follow-up. The operator is warned
at session start if `cleanup_on_exit = true` and the session is `/bg`
("cleanup_on_exit has no effect on /bg sessions in this version").

**Sub-agent workdirs:** sub-agents (AGENT_START) get a per-session
`SessionId` (the child's). The child's workdir is created in the
`channelMkWorker`/`webMkWorker` builder (same mkdir logic). Parent and
child don't share a workdir. Child cleanup is the child's own bracket
responsibility (if `cleanup_on_exit = true`, the child's bracket cleans
its own workdir).

### 4.5 Remote workdir: the `SshConfig.scWorkspace` override

The remote-workdir path is `scWorkspace/workdirs/<session-id>`. Validated
via `mkSafePathRemote` (anchored under `scWorkspace`) BEFORE the `mkdir`
SSH call. The `mkdir` uses the validated absolute path.

The `SshConfig` is cloned at the wiring site with `scWorkspace` set to
the remote per-session workdir. The clone re-validates via `mkRemotePath`
(the appended path could theoretically violate `mkRemotePath`'s
invariants; the re-validation catches this and surfaces a hard error).

> **`mkRemotePath` vs `isValidSessionId` responsibilities:** `mkRemotePath`
> (Types.hs:160) rejects empty, leading-dash, control chars — NOT `..` or
> `/`. The `..`-escape protection comes from `isValidSessionId` (rejects
> `.`, `/`, `\` in the sid) + `mkSafePathRemote` lexical re-anchoring.
> The `mkRemotePath` re-validation is defense-in-depth, not the
> load-bearing `..` check.

### 4.6 `SessionId` constructor lock-down (security)

`SessionId(..)` is currently exported, allowing raw `SessionId "../../.."`
construction — a path-injection risk for `sessionWorkdir` → `mkdir` and
`cleanupSessionWorkdir` → `rm -rf`.

**Fix:** stop exporting `SessionId(..)`. Export only the type +
`mkSessionId` + `mkSystemSessionId`. `mkSystemSessionId :: Text ->
SessionId` is a total convenience for known-safe system strings (e.g.
`"web"`) — it calls `isValidSessionId` internally and `error`s on
failure (it does NOT bypass validation). Update all raw-constructor
call sites (`Gateway/API.hs:749` uses `SessionId "web"`, etc.) to use
`mkSystemSessionId`.

**Defense-in-depth:** `sessionWorkdir` / `ensureSessionWorkdir` /
`cleanupSessionWorkdir` ALSO assert `isValidSessionId sid` before
constructing the path, so a future raw-constructor leak is caught at the
boundary.

### 4.7 `shellQuote` hardening

`shellQuote` (UntrustedIO.hs:469) wraps with single quotes but does not
escape embedded single quotes. Harden: `shellQuote s = "'" <> T.replace
"'" "'\\''" s <> "'"`. Applied uniformly to all remote paths (mkdir,
rm, file ops).

### 4.8 `WorkdirError` type

```haskell
data WorkdirError
  = WdMkdirFailed FilePath Text      -- local mkdir failed (path, reason)
  | WdRemoteMkdirFailed Text          -- remote SSH mkdir failed (reason)
  | WdInvalidSessionId Text           -- SessionId failed validation
  | WdNotUnderWorkdirsRoot FilePath    -- cleanup path escaped workdirsRoot
  deriving stock (Eq, Show)
```

`ensureSessionWorkdir` returns `Either WorkdirError FilePath`.
`cleanupSessionWorkdir` returns `IO (Either WorkdirError ())` (does NOT
swallow cleanup failures — logs + returns the error so the operator
knows).

### 4.9 Call-site inventory (all 6 wiring sites)

All 6 `getCurrentDirectory → WorkspaceRoot → untrustedIOFromSecurity`
wiring sites must be updated. Each calls the SAME
`ensureSessionWorkdir` helper:

1. `src/Seal/Channel/Cli.hs:291` — CLI session start (`runCliTui`).
2. `src/Seal/Channels/Loop.hs:496` — channel session start (`plainTurn`).
3. `src/Seal/Channels/Loop.hs:575` — `channelCallDispatcher` (per-turn
   dispatch).
4. `src/Seal/Gateway/Send.hs:274` — web session start
   (`withSessionLock`).
5. `src/Seal/Gateway/Send.hs:485` — `webStartWiring`/dispatch path.
6. `src/Seal/Gateway/Send.hs:528` — `webCallDispatcher` (per-turn
   dispatch).

The per-turn variants (3, 5, 6) reuse the cached `wsRoot` (hoisted to
true session start — no per-turn `mkdir`).

## 5. Phased implementation (TDD — RED first)

### Phase 1 — Config + Paths + SessionId lock-down (green, no behavior change)

**T1.1 (RED)** Tests:
- `WorkdirConfig` round-trips (`[workdir]` section saves + loads).
- `spCache` is `~/.seal/cache`.
- `sessionWorkdir` produces `~/.seal/cache/workdirs/<sid>`.
- `SessionId` constructor is NOT exported (compile-fail: raw
  `SessionId "x"` rejected).
- `isValidSessionId` rejects `..`, `/`, `\`, empty.
- `mkSystemSessionId "web"` succeeds; `mkSystemSessionId "../x"`
  errors.
- Existing `FileSpec.hs` `RuntimeConfig` literals updated to include
  `rcWorkdir = Nothing`.

**T1.2 (GREEN)** Implement:
- Add `spCache` to `SealPaths` + `getSealPaths` + `ensureSealDirs`.
- Add `WorkdirConfig` to `Seal.Config.File` + codec + `rcWorkdir`.
- Add `workdirsRoot`/`sessionWorkdir` to `Seal.Config.Paths` (with
  `isValidSessionId` assert).
- Add `WorkdirError` type.
- Lock down `SessionId(..)` — stop exporting; add `mkSystemSessionId`.
  Update all raw-constructor call sites.

**Gate:** `make check` green. No wiring change.

### Phase 2 — Workdir lifecycle (local mode)

**T2.1 (RED)** Tests:
- `ensureSessionWorkdir` creates `~/.seal/cache/workdirs/<sid>` (mode
  0700).
- `ensureSessionWorkdir` is idempotent (second call is a no-op).
- `ensureSessionWorkdir` failure (perms — use a 0000-mode parent dir)
  surfaces `WdMkdirFailed` — session does NOT proceed with cwd root.
- `cleanupSessionWorkdir` removes the workdir.
- `cleanupSessionWorkdir` asserts the path is under `workdirsRoot`
  (canonicalize + prefix check — defeats symlink swap). Returns
  `WdNotUnderWorkdirsRoot` on escape.
- `cleanupSessionWorkdir` returns `Either WorkdirError ()` (does not
  swallow failures).
- Two sessions get different workdirs; `FILE_WRITE` in A does not
  appear in B.
- Stale workdir (already exists): `ensureSessionWorkdir` reuses it
  (does NOT clear — operator may want to resume).

**T2.2 (GREEN)** Implement:
- `ensureSessionWorkdir :: SealPaths -> SessionId -> IO (Either
  WorkdirError FilePath)`.
- `cleanupSessionWorkdir :: SealPaths -> SessionId -> IO (Either
  WorkdirError ())`.
- Thread the workdir into all 6 wiring sites (§4.9): compute
  `sessionWorkdir` at session start (hoisted out of per-turn bracket for
  CLI), pass as `WorkspaceRoot` to `untrustedIOFromSecurity`. At bracket
  end, call `cleanupSessionWorkdir` if `cleanup_on_exit = true`.
- Integration test: each channel threads the workdir correctly.

**Gate:** `make check` green. Local-mode behavior changed (per-session
workdir always on); existing tests updated to use per-session workdir
fixtures.

### Phase 3 — Remote workdir

**T3.1 (RED)** Tests:
- Fake `RemoteRunner` asserts the `mkdir -p` argv is correct (`ssh ...
  -- mkdir -p '<scWorkspace>/workdirs/<sid>'`).
- Remote `UntrustedIO` arm uses the per-session workdir as
  `WorkspaceRoot`.
- `..` escape rejected against the per-session remote root.
- Remote `mkdir` failure (SSH error, non-zero exit) → `WdRemoteMkdirFailed`
  → session fails fast (no fallback to shared `scWorkspace`).
- `mkRemotePath` re-validation of the appended path fails → hard error
  (distinct from SSH error).
- `shellQuote` escapes embedded single quotes.

**T3.2 (GREEN)** Implement:
- `ensureRemoteSessionWorkdir :: SshConfig -> RemoteRunner -> SessionId
  -> IO (Either WorkdirError RemotePath)`.
- Wire into the 6 wiring sites: when `mode=remote`, clone `SshConfig`
  with `scWorkspace = either error id (mkRemotePath remoteWorkdirText)`,
  then `mkRemoteUntrustedIO sshCfg' runner`.
- `shellQuote` hardened.

**Gate:** `make check` green. Remote-mode creates a per-session workdir
on the remote machine.

## 6. Open questions (resolved)

1. `~/.seal/cache/` vs `~/.seal/state/` → `~/.seal/cache/` (add
   `spCache`).
2. Remote workdir location → `scWorkspace/workdirs/<sid>`.
3. Chroot → deferred (container/VM follow-up).
4. Cleanup timing for `/bg` → no-op in #50 (known limitation).
5. `SessionId` constructor → lock down + `mkSystemSessionId`.
6. Default `enabled` → no `enabled` field; always on.
7. Shared-cwd migration → no opt-out; symlink workaround documented.
8. Chroot priv drop → N/A (chroot deferred).

## 7. What this buys

- **Sessions are isolated.** Session A and B cannot clobber each other's
  files — each gets a fresh workdir at `~/.seal/cache/workdirs/<sid>`.
- **Remote sessions are isolated.** In `mode=remote`, each session gets
  a subdirectory on the remote machine.
- **No silent clobbering.** The #1 user pain point (parallel sessions
  overwriting each other) is eliminated.
- **SafePath is the boundary.** File ops are confined to the workdir.
  (SHELL_EXEC can still `cd /` — a container/VM follow-up closes this.)

## 8. Key files

- `src/Seal/Core/Types.hs` — lock down `SessionId(..)`; add
  `mkSystemSessionId`, `isValidSessionId`.
- `src/Seal/Config/Paths.hs` — `spCache`, `workdirsRoot`,
  `sessionWorkdir` (with `isValidSessionId` assert).
- `src/Seal/Config/File.hs` — `WorkdirConfig` + codec + `rcWorkdir`.
- `src/Seal/Channel/Cli.hs:291` — wiring (1 of 6).
- `src/Seal/Channels/Loop.hs:496,575` — wiring (2 of 6).
- `src/Seal/Gateway/Send.hs:274,485,528` — wiring (3 of 6).
- `src/Seal/Tools/Exec/UntrustedIO.hs` — `shellQuote` hardening.
- `src/Seal/Gateway/API.hs` — `SessionId "web"` → `mkSystemSessionId
  "web"`.
- Tests: workdir lifecycle, session isolation, remote mkdir, config
  round-trip, `SessionId` compile-fail, `WorkdirError` cases.

## 9. Changelog

**v1 → v2:**
- Removed `enabled` field; added personas/use cases; locked down
  `SessionId(..)`; chroot drops privs; fail-fast chroot; signature
  unchanged; CLI per-turn hoist; TDD RED-first; mkdir-failure tests;
  `shellQuote` hardening; self-reference fix.

**v2 → v3:**
- **Dropped chroot entirely** (Phase 4 removed) — security reviewer
  found it non-functional (no rootfs, priv-drop, perm issues). Deferred
  to container/VM follow-up. Per-session workdir + SafePath is the
  isolation boundary.
- **No opt-out confirmed** — workdir always on; shared-cwd users use
  symlink. Breaking change acknowledged in §4.1.
- **Call-site inventory complete** — all 6 wiring sites enumerated
  (§4.9). CTO blocker fix.
- **`WorkdirError` type defined** (§4.8) — designer suggestion.
- **`mkSystemSessionId` validates** (§4.6) — does NOT bypass
  `isValidSessionId`. Security/designer suggestion.
- **`mkRemotePath` vs `isValidSessionId` responsibilities clarified**
  (§4.5) — architect suggestion.
- **`cleanupSessionWorkdir` returns `Either`** (§4.8) — does not
  swallow failures. Architect suggestion.
- **Sub-agent cleanup clarified** (§4.4) — child's own bracket
  responsibility.
- **`/bg` cleanup warning** (§4.4) — operator warned at session start.
- **Success metrics added** (§1) — PM blocker fix.

## 10. Effort estimate

- Phase 1 (config + paths + SessionId lock-down): ~2h
- Phase 2 (local workdir lifecycle + 6 wiring sites): ~2.5h
- Phase 3 (remote workdir + mkdir): ~1.5h

Total: ~6h. The `SessionId` lock-down is the riskiest change (breaking
internal call sites); the rest is path threading + config.