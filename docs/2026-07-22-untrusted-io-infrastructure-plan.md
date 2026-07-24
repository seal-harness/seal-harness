# Plan: Unified Untrusted-IO Infrastructure

> **Status:** Draft plan (2026-07-22). Addresses: (1) the FILE_WRITE local-vs-
> remote bug, (2) the wider "no untrusted opcode actually reaches the remote
> machine" gap, and (3) DRY + bulletproofing per the user's request to "create a
> single set of infrastructure… eliminating the need to think about this issue
> in the future and minimizing the possibility of future code calling raw
> manipulation functions from libraries like `process`."

## 1. Problem

### The reported bug
`FILE_WRITE` in `mode=remote` writes the file **locally** on the harness
machine instead of on the remote sandbox. The model called
`FILE_WRITE {path: "pangram.txt", content: "The quick brown fox…"}`; the file
appeared at `/Users/doug/code/ai/seal-harness/pangram.txt` (the local cwd, the
harness workspace root), not at `/Users/zoe/sandbox/pangram.txt` on the remote
SSH host (`192.168.40.28`).

### Root cause (wider than FILE_WRITE)
The untrusted opcode layer has **two** IO seams that never got reconciled:

1. **`BackendExec`** (`Seal.ISA.Opcode`) — `newtype BackendExec =
   BackendExec { runLocal :: forall a. IO a -> App a }`. At the only wiring
   site (`src/Seal/Channels/Loop.hs:593`, `src/Seal/Gateway/Send.hs:545`,
   `src/Seal/Channel/Cli.hs:564`) it is always `localBackend =
   BackendExec liftIO`. It is a plain `liftIO` wrapper. It is **not**
   backend-aware — it always runs IO on the harness machine.

2. **`ExecBackend`** (`Seal.Tools.Exec.Types`) — `EbLocal LocalExecHandle |
   EbRemote SshConfig`. This is the local-vs-remote selector. It is threaded
   into every `UntrustedOpcode`'s `uoRun` as the second argument.

The 7 untrusted opcodes split into two camps:

| Opcode | Uses `runLocal backend` (local FS) | Uses `execBackend` |
|---|---|---|
| `FILE_READ` | yes (read file) | ignores `_execBackend` |
| `FILE_WRITE` | yes (write file) | ignores `_execBackend` ← **the bug** |
| `FILE_PATCH` | yes (read + write file) | ignores `_execBackend` |
| `SHELL_EXEC` | no | yes, but `EbRemote` → `ExecNotImplemented` |
| `BIN_EXEC` | no | yes, but `EbRemote` → `ExecNotImplemented` |
| `PROCESS_MANAGE` | no | yes, but `EbRemote` → `ExecNotImplemented` |
| `SEARCH_FILES` | no | yes, but `EbRemote` → `ExecNotImplemented` |

**Net: in `mode=remote`, no untrusted opcode reaches the remote machine.**
The file ops run locally via `runLocal`; the command ops fail with
"remote SSH executor not yet wired (Phase 4 4g)". The remote SSH executor
(`Seal.Tools.Exec.Remote`) only knows `runRemoteShell` (a shell-command-string
executor); it has no file-transfer path at all.

### The design intent (from the spec)
The approved design (`docs/superpowers/specs/2026-06-28-remote-only-untrusted-execution-design.md`)
is unambiguous: in remote-only mode, **all** untrusted opcodes —
`SHELL_EXEC`, `CODE_EXEC`/`BIN_EXEC`, `PROCESS_MANAGE`,
`FILE_READ`/`WRITE`/`SEARCH`/`PATCH`, and future `WEB_*`/`BROWSER_*`/media —
run on the untrusted plane over SSH. The workspace (the agent's files) lives
on the remote machine. The two-plane split is the whole security model: a
full compromise of the untrusted plane cannot read the vault or rewrite the
audit log because neither ever leaves the control plane.

## 2. Goals

1. **Fix the bug.** `FILE_WRITE` (and `FILE_READ`, `FILE_PATCH`) in
   `mode=remote` operate on the **remote** workspace, not the local one.
2. **Wire the remote arm for commands too.** `SHELL_EXEC`, `BIN_EXEC`,
   `PROCESS_MANAGE`, `SEARCH_FILES` in `mode=remote` run on the remote
   machine via the existing `RemoteRunner`.
3. **DRY: one unified seam.** A single `UntrustedIO` capability type that
   every untrusted opcode (current and future) uses for **all** its
   side-effecting IO — files, commands, process management, search. No
   opcode calls `runLocal`, `BS.readFile`, `System.Process.proc`, etc.
   directly.
4. **Bulletproof: no raw `process`/directory/bytestring calls in opcode
   modules.** The infrastructure module is the only place that touches
   `System.Process` / `System.Directory` / `System.Posix`. Opcode modules
   call typed capability methods. A future opcode author cannot
   accidentally call `BS.writeFile` — the import isn't there.
5. **Preserve the type-level capability-scoping guarantee** (spec §4/§8 +
   Invariant 1): Trusted opcodes have no `UntrustedIO` in scope — it is a
   compile error to try to run a command or touch a workspace file from a
   Trusted opcode.
6. **Preserve `ACK-before-execute`** (dispatcher invariant): the transcript
   entry is on disk before any untrusted IO runs. This is in the dispatcher,
   not the seam, so it is inherited automatically.
7. **Preserve the `remote-only-untrusted` Cabal flag** path: the hardened
   build has no local executor; `mode=local` is a startup error.

## 3. Design: the `UntrustedIO` capability

### 3.1 The type

A single record-of-functions handle (mirrors the existing `LocalExecHandle`
pattern) that carries **every** side-effecting capability an untrusted opcode
needs. It is the **only** IO surface untrusted opcodes see.

```haskell
-- src/Seal/Tools/Exec/UntrustedIO.hs

-- | The unified capability handle for Untrusted opcodes. Every side-effecting
-- operation an untrusted tool call can perform is a method on this type.
-- Opcode modules never import System.Process, System.Directory, or
-- System.Posix — they call these methods. The constructor is NOT exported;
-- the two smart constructors (local + remote) are the only way to obtain one.
--
-- Security properties preserved by construction:
--   * Capability scoping (spec §4/§8): a Trusted opcode has no UntrustedIO
--     in scope — it cannot call any of these methods (compile error).
--   * SafePath confinement: file methods take a WorkspaceRoot + relative path
--     and internally mkSafePath/mkSafePathForWrite. The caller never sees a
--     raw FilePath.
--   * Bounded: read/write/process-list methods carry operator ceilings.
--   * Validated argv: shell/bin methods take validated newtypes
--     (ShellCommand, BinName, BinArg), never raw Text.
data UntrustedIO = UntrustedIO
  { uioReadFile    :: RemotePath -> Int -> IO (Either UntrustedErr Text)
    -- ^ Read a workspace-relative file, bounded by the operator ceiling
    -- (bytes scanned). Returns the content (model-visible) or a structured
    -- error. The path is validated + confined internally.

  , uioWriteFile   :: RemotePath -> Text -> WriteMode -> IO (Either UntrustedErr Int)
    -- ^ Write or append content to a workspace-relative file. Returns bytes
    -- written. The path is validated + confined internally; the content size
    -- is bounded by the operator ceiling (checked before the call).

  , uioPatchFile   :: RemotePath -> Text -> IO (Either UntrustedErr ())
    -- ^ Apply a unified diff to a workspace-relative file (in-process parse +
    -- apply; atomic temp+rename on the target plane). Returns () or error.

  , uioShellExec   :: ShellCommand -> Maybe RemotePath -> IO (Either UntrustedErr Text)
    -- ^ Run a validated shell command (single arg to /bin/sh -c), with an
    -- optional SafePath-confined cwd. Returns stdout (+ exit annotation) or
    -- a structured error.

  , uioBinExec     :: BinName -> [BinArg] -> IO (Either UntrustedErr Text)
    -- ^ Run a named binary (no shell, fixed argv). Returns stdout or error.

  , uioProcessList :: IO (Either UntrustedErr Text)
    -- ^ List processes on the untrusted plane (bounded output).

  , uioProcessKill :: Int -> IO (Either UntrustedErr ())
    -- ^ Kill a process by PID (validated positive integer) on the untrusted
    -- plane.

  , uioSearchFiles :: SearchPattern -> Maybe RemotePath -> Int -> IO (Either UntrustedErr Text)
    -- ^ Search workspace files for a pattern (rg, SafePath-confined, bounded
    -- result count). Returns matching lines or error.
  }

data WriteMode = WMWrite | WMAppend
data UntrustedErr = UePath PathError | UeBounded Int | UeExec ExecError | UeIo Text
```

### 3.2 The two smart constructors

```haskell
-- | The local untrusted executor. Workspace files live on the local FS;
-- commands run via /bin/sh -c (shell) or proc (bin). Absent under
-- -f remote-only-untrusted.
mkLocalUntrustedIO :: WorkspaceRoot -> UntrustedIO

-- | The remote SSH executor. Workspace files live on the remote machine;
-- commands run via the SSH transport. File IO is implemented over SSH
-- (see §4). The SshConfig is the validated, host-key-pinned config.
mkRemoteUntrustedIO :: SshConfig -> RemoteRunner -> UntrustedIO
```

The constructor `UntrustedIO {…}` is **not exported**. Only these two smart
constructors are exported. This is the same pattern as `LocalExecHandle` —
the record fields are accessible to callers (they call the methods), but
nobody can construct a fake `UntrustedIO` with arbitrary IO actions from
outside the module.

### 3.3 The dispatcher change

The `UntrustedOpcode`'s `uoRun` signature changes from
`BackendExec -> ExecBackend -> Value -> App OpResult` to
`UntrustedIO -> Value -> App OpResult`. This:

- **Merges the two seams into one.** No more `BackendExec` + `ExecBackend`
  split. One capability handle, backend-selected once at wiring time.
- **Makes the capability-scoping guarantee tighter.** `UntrustedIO` is only
  in scope for `UntrustedOpcode`s. `TrustedOpcode`'s `toRun` keeps its
  `BackendExec -> Value -> App OpResult` signature (Trusted opcodes use
  `BackendExec` for their own non-untrusted IO — e.g. memory/skill file
  writes under `config/`; they never get `UntrustedIO`).

> **Open question (see §6):** should `BackendExec` be kept for Trusted
> opcodes, or folded into a separate `TrustedIO`? I lean toward keeping
> `BackendExec` as-is for Trusted opcodes — it is a different (smaller)
> capability surface and the spec's Invariant 1 (no shell in Trusted) is
> already enforced by the type split.

### 3.4 The wiring-site change

Today: `execBackend = execBackendFromSecurity wsRoot secCfg` (returns an
`ExecBackend`), passed to `dispatch` alongside `localBackend`.

After: `untrustedIO = untrustedIOFromSecurity wsRoot secCfg remoteRunner`
(returns an `UntrustedIO`), passed to `dispatch`. The wiring site constructs
the `UntrustedIO` once per session/turn from the `SecurityConfig` (same
resolution logic as today's `execBackendFromSecurity`, just producing the
new handle). The `RemoteRunner` is threaded in (it is already constructed
for the SSH transport; today it is unused in `mode=remote` because the
shell opcodes return `ExecNotImplemented`).

### 3.5 What the opcode modules look like after

`Seal.ISA.Ops.File.fileWriteOp` becomes (schematic):

```haskell
fileWriteOp :: WorkspaceRoot -> Int -> Opcode
fileWriteOp root operatorWriteCeiling = UntrustedOpcode
  { uoName = OpName "FILE_WRITE"
  , …
  , uoRun = \uio v -> do
      let rel     = maybe "" T.unpack (pathField v)
          content = maybe "" T.unpack (contentField v)
          mode    = …
          byteCount = BS.length (TE.encodeUtf8 (T.pack content))
          recorded = object [ "path" .= rel, "mode" .= mode, "bytes" .= byteCount ]
      if byteCount > operatorWriteCeiling
        then pure $ OpResult […] True recorded
        else do
          res <- liftIO (uioWriteFile uio (mkRemotePath' rel) (T.pack content) (toMode mode))
          pure $ case res of
            Left err  -> OpResult [TrpText (renderUntrustedErr err)] True recorded
            Right n   -> OpResult [TrpText ("wrote " <> …)] False recorded
  }
```

No `System.Directory`, no `System.Posix`, no `BS.writeFile`, no `runLocal`.
The opcode is pure decision + capability call. **This is the DRY +
bulletproofing payoff: the import list of an opcode module cannot reach
`process`/`directory`/`posix` because the capability methods are the only
IO surface.**

## 4. Remote file IO over SSH

The `RemoteRunner` today only does `runRemoteShell :: SshConfig ->
ShellCommand -> IO (Either ExecError Text)` (runs a command string via
`ssh … -- <command>`). To implement `uioReadFile`/`uioWriteFile`/`uioPatchFile`
for the remote arm, we have three options:

### Option A — SSH + stdin/heredoc (recommended)
Implement file IO as SSH commands that pipe content over the SSH channel:

- **Write:** `ssh … -- sh -c 'cat > "$1"' _ <relpath>` with the content on
  stdin. Or simpler: `ssh … -- tee <relpath>` with content on stdin
  (`tee` truncates; for append, `tee -a`). This is a single SSH exec with
  stdin piped — `System.Process`'s `std_in = CreatePipe` already supports
  this. The `RemoteRunner` gains a `runRemoteWithStdin :: SshConfig ->
  ShellCommand -> ByteString -> IO (Either ExecError Text)` method.
  - SafePath is validated **locally** before the SSH call (the validated
    `RemotePath` newtype is passed; the remote command receives it as a
    single argv element after `--`, so no shell injection from the path).
  - The content is bytes on stdin, never interpolated into the command
    string — so content with quotes/backticks/`$()` is safe.

- **Read:** `ssh … -- cat <relpath>` — stdout is the file content. Bounded
  by the operator ceiling (read at most N bytes via a bounded read or
  `head -c N`). SafePath validated locally first.

- **Patch:** read remote (cat), apply diff in-process (the existing pure
  `applyUnifiedDiff`), write remote (the write path above). Atomic on the
  remote via `mv .tmp final`.

- **Search:** `ssh … -- rg -n -- <pattern> <path>` — already a command, just
  route through `uioSearchFiles` instead of the shell op.

- **Process list/kill:** `ssh … -- ps -o pid=,cmd=` / `ssh … -- kill <pid>`
  — already commands.

**Pros:** no extra deps, no SFTP subsystem needed on the remote, reuses the
existing `ssh` binary + the existing `RemoteRunner` pattern (just adds a
stdin pipe). Single binary, single transport.
**Cons:** content passes through the SSH channel (fine — it's already the
transport for commands); binary-safe (stdin is bytes, not a shell arg).

### Option B — SFTP (via the `ssh` binary's `sftp` subsystem)
Use `sftp` batch mode. More complex, needs the sftp subsystem enabled on the
remote, and the argv is harder to harden. **Not recommended.**

### Option C — rsync
Overkill for single-file ops, and `rsync` is an extra binary dependency on
both ends. **Not recommended.**

**Recommendation: Option A.** It is the minimal, single-transport approach
that reuses the hardened `ssh` argv pattern and adds only a stdin pipe. The
`SshConfig` already pins `StrictHostKeyChecking=yes` + `UserKnownHostsFile`;
the file operations inherit that.

## 5. Phased implementation (TDD)

### Phase 1 — The `UntrustedIO` type + local constructor (green, no behavior change)

**T1.1** New module `Seal.Tools.Exec.UntrustedIO`:
- The `UntrustedIO` record type + `WriteMode` + `UntrustedErr`.
- `mkLocalUntrustedIO :: WorkspaceRoot -> UntrustedIO` — implemented via the
  existing local FS + `System.Process` code (lifted out of `Local.hs` and the
  opcode modules). No remote arm yet.
- Constructor NOT exported; only the smart constructors are.
- `UntrustedErr` render function.

**T1.2** Tests (`UntrustedIOSpec`):
- Local read/write/patch/shell/bin/search/process against a temp workspace
  (mirrors the existing `FileSpec`/`ShellSpec`/`BinSpec`/`SearchSpec`/`
  ProcessSpec` cases, now through the unified handle).
- SafePath confinement holds (a `..` path → `UePath`).
- Bounded write/read ceilings enforced.

**Gate:** `cabal build all` + `cabal test` green. No opcode changed yet.

### Phase 2 — Wire `UntrustedIO` into the dispatcher + opcodes (the refactor)

**T2.1** Change `UntrustedOpcode.uoRun` signature: `UntrustedIO -> Value ->
App OpResult`. Update `Seal.ISA.Dispatch.dispatch` to thread `UntrustedIO`
instead of `BackendExec + ExecBackend` for the Untrusted arm. (Trusted arm
keeps `BackendExec`.)

**T2.2** Rewrite each untrusted opcode module to call `uio*` methods:
- `File.hs`: `uioReadFile`/`uioWriteFile`/`uioPatchFile`.
- `Shell.hs`: `uioShellExec`.
- `Bin.hs`: `uioBinExec`.
- `Process.hs`: `uioProcessList`/`uioProcessKill`.
- `Search.hs`: `uioSearchFiles`.
- Remove all `runLocal backend` / `lehExec*` / direct `BS.*` / `System.*`
  imports from these modules. **This is the bulletproofing checkpoint:**
  after this phase, `grep -n "System.Process\|System.Directory\|System.Posix\|BS.readFile\|BS.writeFile" src/Seal/ISA/Ops/*.hs` returns nothing.

**T2.3** Update wiring sites (`Channels/Loop.hs`, `Gateway/Send.hs`,
`Channel/Cli.hs`): replace `execBackendFromSecurity` with
`untrustedIOFromSecurity :: WorkspaceRoot -> SecurityConfig -> Maybe
RemoteRunner -> UntrustedIO`. Local mode → `mkLocalUntrustedIO`; remote mode
→ `mkRemoteUntrustedIO sshCfg runner` (remote arm implemented in Phase 3;
for now it can be a stub that returns `UeExec ExecNotImplemented` for every
method — preserving today's fail-closed behavior while we build the real
remote arm).

**Gate:** `cabal test` green — all existing tests pass through the new
handle (local behavior unchanged). `hlint` clean. The
`remote-only-untrusted` flag build still works.

### Phase 3 — The remote SSH arm (the bug fix)

**T3.1** Extend `Seal.Tools.Exec.Remote.RemoteRunner` with
`runRemoteWithStdin :: SshConfig -> ShellCommand -> ByteString -> IO (Either
ExecError Text)` (adds `std_in = CreatePipe`; writes the bytes; reads
stdout/stderr; same exit-code mapping as `runRemoteShell`).

**T3.2** Implement `mkRemoteUntrustedIO :: SshConfig -> RemoteRunner ->
UntrustedIO`:
- `uioReadFile`: `ssh … -- cat <relpath>` (bounded read).
- `uioWriteFile`: `ssh … -- tee [−a] <relpath>` with content on stdin.
- `uioPatchFile`: read (cat) → apply diff in-process → write (tee) → atomic
  rename on the remote (`ssh … -- sh -c 'mv "$1.tmp" "$1"' _ <relpath>`).
- `uioShellExec`: the existing `runRemoteShell`.
- `uioBinExec`: `ssh … -- <bin> <args…>` (fixed argv after `--`).
- `uioProcessList`/`uioProcessKill`: the existing `runRemoteShell` with
  `ps`/`kill`.
- `uioSearchFiles`: `ssh … -- rg -n -- <pattern> <path>`.
- SafePath: validated **locally** against the `WorkspaceRoot` before the SSH
  call (the `RemotePath` newtype is the validated, no-`..`, no-leading-dash
  path; it is passed as a single argv element after `--`, so the remote
  shell never interprets it as a flag).

**T3.3** Tests (`UntrustedIORemoteSpec`):
- A fake `RemoteRunner` that simulates the SSH calls (records the argv +
  stdin; returns canned stdout). Asserts the file ops produce the right
  SSH argv + pipe content (e.g. write sends the content on stdin, not
  interpolated into the command).
- SafePath confinement: a `..` path is rejected **before** any SSH call
  (the fake runner would fail the test if it saw a `..` path).
- Host-key mismatch → `UeExec ExecHostKeyMismatch` (hard fail, never
  bypassed) — inherited from the existing `RemoteRunner` mapping.

**Gate:** `cabal test` green. The fake-runner tests prove the remote arm
generates correct SSH argv + stdin. An integration test (marked `pending`
unless an SSH endpoint is available) does a real round-trip: write a file
via `uioWriteFile`, read it back via `uioReadFile`, assert the content
matches.

### Phase 4 — Startup config summary (the user's first ask)

**T4.1** Add a `printStartupSummary` in `Seal.Command.Serve.runServeMain`,
printed to stderr before `runGateway`. Harness-relevant values only (not
the whole config):

```
seal serve — startup
  config:        /Users/doug/.seal/config/config.toml
  security:      /Users/doug/.seal/security.toml
  workspace:      /Users/doug/code/ai/seal-harness  (local cwd)
  untrusted exec: remote → zoe@192.168.40.28:22 (workspace: /Users/zoe/sandbox)
  provider:      ollama (model: glm-5.2:cloud)
  default agent:  zoe
  gateway:       http://127.0.0.1:8080  (ws: 8081)
  vault:         yubikey (on_demand)
```

The values come from the already-loaded `cfg` (RuntimeConfig) + `secCfg`
(SecurityConfig) + `gwCfg` (GatewayConfig). No new loads. The untrusted-exec
line is the one the user needs for debugging the remote-execution bug — it
shows mode + host/user + workspace. If `mode=local`, it prints
`untrusted exec: local (workspace: <cwd>)`; if `mode=remote` with no remote
configured, `untrusted exec: remote — WARNING: no remote configured
(opcodes will fail-closed)`.

**Gate:** manual smoke — `make serve` prints the summary; the
`untrusted exec:` line is correct for the current `security.toml`.

## 6. Open questions

1. **`BackendExec` for Trusted opcodes.** Keep it as-is (Trusted opcodes
   use `BackendExec` for their own `config/` file writes; they never get
   `UntrustedIO`). This preserves Invariant 1 by the type split. **Lean:
   keep.** The alternative (a `TrustedIO` capability) is a larger refactor
   with no security gain — Trusted opcodes already can't shell out (no
   shell capability in `BackendExec`), and the spec's Invariant 1 is
   satisfied by construction.

2. **`WorkspaceRoot` on remote.** Today `WorkspaceRoot` is the local cwd
   (`getCurrentDirectory`). In `mode=remote` the workspace is the remote
   `SshConfig.scWorkspace`. SafePath confinement must anchor against the
   remote workspace, not the local cwd. The local SafePath check
   (`mkSafePath`/`mkSafePathForWrite`) already works on any `FilePath` —
   we pass the remote workspace as the root. The only subtlety: the local
   `mkSafePath` canonicalizes via `canonicalizePath` (a local FS call). For
   the remote arm, we **cannot** canonicalize on the local FS (the file
   lives on the remote). We need a remote-safe path validator that does
   **lexical** confinement only (steps 1-2 of `mkSafePath`: blocked-name +
   `..`/`.` collapse + containment), skipping the canonicalization
   (steps 3-4). This is already half-written; `mkSafePathForWrite`'s
   lexical phase is the model. A new `mkSafePathRemote :: WorkspaceRoot ->
   FilePath -> Either PathError SafePath` (pure, lexical-only, no
   `canonicalizePath`) is needed. The `RemotePath` newtype is already the
   right carrier.

3. **Should `uioReadFile` return the `renderWindow` text or the raw
   content?** Today `FILE_READ` does the LineFile paging + rendering
   inside the opcode. If we push the paging into the capability, the
   opcode is thinner but the capability knows about paging. **Lean: keep
   paging in the opcode** — `uioReadFile` returns raw bounded content; the
   opcode does the `readLineWindow` + `renderWindow` (or we push
   `readLineWindow` into the local arm only, since the LineFile module is
   local-FS-specific). This needs a small decision: either the LineFile
   paging is local-only (and the remote arm returns raw content that the
   opcode renders), or we generalize the paging to work on text. **Lean:
   the latter** — `uioReadFile` returns `Text` (bounded); the opcode
   splits to lines + windows in-process (pure). The LineFile module's
   `readLineWindow` becomes pure text processing, not FS IO. This is a
   small cleanup.

4. **`FILE_PATCH` atomicity on remote.** The local arm does temp+rename
   (atomic). The remote arm can do `ssh … -- sh -c 'cat > "$1.tmp" && mv
   "$1.tmp" "$1"' _ <relpath>` with the patched content on stdin. This is
   atomic on the remote (a single SSH exec). **Confirm this is the right
   approach in T3.2.**

## 7. What this buys

- **One seam, one import.** Opcode modules import `UntrustedIO` (the
  type) + call methods. They never import `System.Process` /
  `System.Directory` / `System.Posix`. A grep for those imports in
  `src/Seal/ISA/Ops/` is the enforcement.
- **The bug is fixed and cannot regress.** `FILE_WRITE`'s `uoRun` calls
  `uioWriteFile uio …`; the `uio` is backend-selected at wiring time. In
  `mode=remote` it is the remote arm (SSH + stdin); the bytes go over SSH,
  not to the local FS. A future opcode author writing a `FILE_DELETE` op
  would call `uioDeleteFile uio …` and get the right backend for free.
- **The remote arm is wired for commands too.** `SHELL_EXEC` etc. stop
  returning `ExecNotImplemented` in `mode=remote`.
- **Capability scoping is tighter.** `UntrustedIO` is only in `UntrustedOpcode`'s `uoRun`; Trusted opcodes physically cannot call it.
- **The startup summary** makes the harness-mode visible at a glance —
  the user sees `untrusted exec: remote → …` and knows the file write
  should land on the remote host.

## 8. Key files

- `src/Seal/Tools/Exec/UntrustedIO.hs` (new) — the capability type + 2 smart constructors
- `src/Seal/Tools/Exec/Remote.hs` — add `runRemoteWithStdin`
- `src/Seal/Tools/Exec/Local.hs` — local arm implementation (absorbed into `UntrustedIO`)
- `src/Seal/Tools/Exec/Types.hs` — `ExecBackend` stays (the `ExecBackend`→`UntrustedIO` bridge is at the wiring site); `LocalExecHandle` may be retired (its methods become `UntrustedIO` methods)
- `src/Seal/Security/Path.hs` — add `mkSafePathRemote` (lexical-only)
- `src/Seal/ISA/Opcode.hs` — `UntrustedOpcode.uoRun` signature change
- `src/Seal/ISA/Dispatch.hs` — thread `UntrustedIO` for the Untrusted arm
- `src/Seal/ISA/Ops/*.hs` — all 7 untrusted opcode modules: call `uio*`, drop raw IO imports
- `src/Seal/Channels/Loop.hs`, `src/Seal/Gateway/Send.hs`, `src/Seal/Channel/Cli.hs` — wiring: `untrustedIOFromSecurity`
- `src/Seal/Command/Serve.hs` — startup summary (Phase 4)
- `seal-harness.cabal` — new `exposed-modules: Seal.Tools.Exec.UntrustedIO`

## 9. Test matrix (the security-relevant invariants)

| Invariant | Test |
|---|---|
| `mode=remote` + FILE_WRITE → file on remote, not local | fake-runner test: `uioWriteFile` produces SSH argv with `tee <path>` + content on stdin; no local FS write. Integration: real SSH round-trip. |
| `mode=remote` + SHELL_EXEC → command on remote | fake-runner: `uioShellExec` produces the SSH argv (already tested via `runRemoteShell`); now actually wired (no `ExecNotImplemented`). |
| `mode=local` + any op → local behavior unchanged | all existing FileSpec/ShellSpec/etc. pass through `UntrustedIO` local arm. |
| SafePath confinement on remote (no `canonicalizePath`) | `mkSafePathRemote "..foo"` → `Left PathEscapesWorkspace`; the fake runner never sees a `..` path. |
| Bounded write/read | `uioWriteFile` with content > ceiling → `UeBounded`; `uioReadFile` bounded read. |
| Host-key mismatch → hard fail | inherited from `RemoteRunner`'s exit-255 mapping; `uioShellExec` returns `UeExec ExecHostKeyMismatch`. |
| `remote-only-untrusted` + `mode=local` → startup error | existing `enforceRemoteOnly` check (unchanged). |
| No raw `process`/`directory`/`posix` imports in opcode modules | grep assertion (a test or a CI check). |
| Trusted opcode cannot call `UntrustedIO` | compile-fail fixture (mirrors the existing `CapabilityScopingFail`). |

## 10. Effort estimate

- Phase 1 (type + local constructor + tests): ~2-3h
- Phase 2 (dispatcher + 7 opcodes + 3 wiring sites): ~3-4h
- Phase 3 (remote arm + `runRemoteWithStdin` + tests): ~2-3h
- Phase 4 (startup summary): ~30min

Total: ~8-10h of focused work. The refactor is mechanical once the type is
in place; the security-critical new code is the remote file-IO path
(Phase 3).