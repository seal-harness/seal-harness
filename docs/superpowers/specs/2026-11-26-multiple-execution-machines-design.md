# Multiple Execution Machines — Design

> **Status:** Draft, for the Design Review Gate.
> **Requirements:** `docs/superpowers/requirements/2026-11-26-multiple-execution-machines-requirements.md`
> (approved 2026-11-26, frozen). That document is the baseline for scope; a
> finding that contradicts it is a constraint correction or a scope change
> request, not a blocker.

## 1. Problem & approach

Today exactly one SSH target exists, resolved at boot from
`security.toml`'s `[untrusted_execution.remote]` table. `mkSessionExec` turns
that one resolution into one `SessionExec` — a `UIOEnv` (one `UntrustedIO`), one
`WorkdirFs`, one `WorkspaceRoot` — and `Seal.Session.ExecCache` memoizes it per
session. Untrusted opcodes never see a backend: they call `uio*`
(`Seal.Tools.Exec.UIO`) which reads the single `UntrustedIO` out of the
`ReaderT` environment.

This change introduces N named machines and makes the target a **per-call**
input. The architectural consequence is stated plainly because it is the whole
design:

> **The untrusted execution target stops being a wiring-time constant and
> becomes an explicit argument on the `uio*` surface.**

The operator chose (over dispatcher-side resolution) to carry a **machine
registry in `UIOEnv`** and pass the target through the `uio*` functions. This is
the stronger option, for a reason worth recording: it makes "which machine does
this call run on" visible at every call site in an opcode, so an opcode cannot
accidentally inherit a default it did not ask for. The cost is that all eight
untrusted opcode modules and the `uio*` signatures change; that cost is accepted.

### 1.1 What does *not* change

These are the load-bearing invariants this design must leave untouched, and each
has a named test obligation in §9:

- **ACK-before-execute.** The dispatcher durably records the invocation before
  any machine runs it. Machine selection happens strictly after the record.
- **Fail-closed.** No fallback to another machine, and none to `local`.
- **`allow_localhost = false` means no local untrusted execution.** Enforced in
  the selector, and by absence of the executor in hardened builds.
- **Type-guaranteed argv sanitization.** A machine name from the model is a
  smart-constructed newtype, never raw `Text` into `ssh` argv.
- **`~/.seal` is agent-immutable.** `machines.toml`, `security.toml` and
  `exec-known-hosts` are reachable only from boot and human-driven admin paths.

## 2. Configuration

### 2.1 `machines.toml`

New file, sibling of `security.toml` (`spHome </> "machines.toml"`), mode
`0600`, boot-only, no opcode surface. Shipped by `Seal.Config.Templates` under
its existing never-overwrite invariant.

```toml
default = "linux-builder"

[machines.linux-builder]
host      = "builder.example.com"
user      = "seal"
port      = 22
identity  = "/home/you/.ssh/id_ed25519"
workspace = "/srv/seal/workspace"
```

Types (`Seal.Config.Machines`):

```haskell
data MachinesConfig = MachinesConfig
  { mcDefault   :: Maybe Text
  , mcMachines  :: Map MachineName MachineFileConfig
  }

data MachineFileConfig = MachineFileConfig
  { mfcHost      :: Maybe Text
  , mfcUser      :: Maybe Text
  , mfcPort      :: Maybe Int
  , mfcIdentity  :: Maybe FilePath
  , mfcWorkspace :: Maybe Text
  }
```

`mcMachines` is a `Map MachineName …`, not a list: duplicate detection is a
decode concern, and the map gives the resolution path O(log n) by construction.
A duplicate key in the TOML is a load error naming the key (TOML itself permits
repeated tables to merge; Seal rejects rather than guesses).

### 2.2 Validation, and the "unusable" concept

Loading produces a **`MachineRegistry`** of *resolved* machines plus a list of
*rejected* ones with reasons — because "configured but broken" must be
reportable (Done-when 1, and the unusable-machine error text in the
requirements) rather than either silently ignored or fatal at boot.

```haskell
data MachineRegistry = MachineRegistry
  { mrMachines :: Map MachineName MachineTarget   -- resolved, selectable
  , mrRejected :: Map MachineName Text            -- configured, unusable + why
  , mrDefault  :: Maybe MachineName
  }

data MachineTarget
  = MtLocal
  | MtSsh MachineName SshConfig
```

Resolution rules, all pure so they are testable without boot:

1. Each `[machines.<name>]` is validated: `mkMachineName`, then
   `mkSshHost`/`mkSshUser`/`mkRemotePath` on the fields, `port` in `1..65535`.
   Missing `host`/`user`/`workspace` → `mrRejected` with the field named.
2. **Loopback guard.** `mkSshHost` currently accepts `localhost`/`127.0.0.1`/`::1`
   — it only rejects control chars, space and colon. A separate
   `isLoopbackHost` check (covering `localhost`, `127.0.0.0/8`, `::1`, `[::1]`,
   and the `0.0.0.0`/`::` wildcards) rejects such a machine into `mrRejected`
   with the "is this machine" message. This is a *new* check; `mkSshHost` keeps
   its current contract because it is shared with non-machine uses.
3. `local` is injected as `MtLocal` **iff** `allow_localhost = true`. It is
   never read from the file; a `[machines.local]` table is a load error (it
   would be ambiguous, and it would let a file name the harness box).
4. `mrDefault` is `mcDefault` when it names a *resolved* machine. A `default`
   naming a missing or rejected machine is a load **error** (not a silent
   fall-through to nothing — a broken default is an operator mistake that must
   be visible). Absent `default` with ≥1 machine → `Nothing`, and the session
   prompt treats "no default" as "no pre-selection".

`allow_localhost` arrives as a parameter to this pure resolver rather than being
read inside it, so the two config files stay independently testable and neither
module learns about the other's codec.

### 2.3 `allow_localhost` replaces `mode`

In `security.toml`, `scUntrustedExec` shrinks to carry only the flag:

```haskell
-- Before
data UntrustedExecFileConfig = UntrustedExecFileConfig
  { uefcMode   :: Text                       -- "local" | "remote"
  , uefcRemote :: Maybe UntrustedExecRemoteFileConfig
  }

-- After
data UntrustedExecFileConfig = UntrustedExecFileConfig
  { uefcAllowLocalhost :: Bool               -- default True
  }
```

`UntrustedExecRemoteFileConfig` is **deleted** from `Security.hs`; its role moves
to `Seal.Config.Machines`. `uefcAllowLocalhost` decodes with `Toml.bool
"allow_localhost" .= …` and defaults to `True` when absent.

Defaulting to `True` is deliberate and is the requirements' decision (upgrading
changes nothing). It is also the one place a security-flavoured default argues
for laxity, so it is stated explicitly here: the pre-change behaviour for an
absent section was local execution, and silently flipping every existing install
to remote-only would break them.

`UntrustedExecMode` (`UemLocal`/`UemRemote`) **survives** in
`Seal.Tools.Exec.Untrusted` — it is the *selector's* input, not the file's, and
`enforceRemoteOnly` keeps needing it. It is now derived:

```haskell
untrustedExecConfigFromSecurity :: SecurityConfig -> UntrustedExecConfig
-- UemLocal  when allow_localhost, UemRemote otherwise
```

Note the return type loses its `Maybe`: with `mode` gone, there is no "section
absent" state to encode. `uecRemote :: Maybe SshConfig` also goes away — the
remote target lives in the registry now. `UntrustedExecConfig` becomes:

```haskell
data UntrustedExecConfig = UntrustedExecConfig
  { uecMode :: UntrustedExecMode }
```

`selectExecBackend`/`selectUntrustedBackend` then take `(UntrustedExecConfig,
MachineTarget)` instead of looking up `uecRemote`.

## 3. Host keys

`scKnownHosts` is removed from `SshConfig`. Every machine pins against one
harness-derived path:

```haskell
execKnownHostsPath :: SealPaths -> FilePath
execKnownHostsPath paths = spHome paths </> "exec-known-hosts"
```

`SshConfig` stays as it is otherwise, but is now always built with that path, so
`Seal.Tools.Exec.Remote`'s `-o UserKnownHostsFile=` wiring and
`Seal.Session.AgentMetaCache`'s copy of it both keep working unchanged — they
consume a field that is now filled from one place instead of per machine.

`Seal.Tools.Exec.HostKeyAdoption` needs no change to its logic: it already
probes, prompts, and appends to `scKnownHosts`. Two additions:

- **Non-interactive refusal.** Today `mkSessionExec` fail-closes when
  `mAdoption = Nothing`. That already produces the required "refused when no
  human is present" behaviour, so the requirement is met by *not* plumbing an
  adoption handle where no human exists — no new code path, but it becomes an
  explicit test (§9).
- **Self-key guard.** After a successful probe, compare the probed host key
  against the harness machine's own SSH host key. If equal, refuse. The harness
  key is read from `~/.ssh/ssh_host_*_key.pub` when present; **if it cannot be
  read, the check is skipped** rather than failing the connection — it is a
  best-effort second line behind the loopback guard, and a harness with no local
  sshd should not be prevented from reaching a real remote.

The `known_hosts` field in an existing `security.toml` is dropped by the
migration and not carried across (§4), so a stale path never silently becomes
the pin file.

## 4. Migration

`Seal.Config.Migrate` gains a `migrateExecutionMachines` step, following its
existing three rules (strip only after a successful write; new file wins except
where it has no answer; never strip what was not moved) and its fail-open
posture.

| On disk | Action |
|---|---|
| no `security.toml` section, no `machines.toml` | write `machines.toml` from template, `allow_localhost = true`. Nothing else. |
| `mode = "remote"` + `[untrusted_execution.remote]` complete | write `[machines.default]` with `host`/`user`/`port`/`identity`/`workspace`; **drop `known_hosts`**; set `default = "default"`; set `allow_localhost = false`; strip the old table from `security.toml`. |
| `mode = "remote"` + remote block incomplete | `allow_localhost = false`; **no** machine written (it would be unusable and would make `default` an error); log loudly, pointing at `machines.toml`. The session then fails closed with the "no execution machine configured" message. |
| `mode = "local"` or section absent | `allow_localhost = true`; strip `mode` if present. |
| `machines.toml` already exists | it wins; only the `security.toml` strip happens. |

The incomplete-remote row is the one that deserves attention: the alternative
(writing a half-populated machine) would trip the `default`-must-resolve error
and turn a currently-working `mode=remote`-but-broken install into a boot
failure. Failing closed at call time, as today, is strictly better.

Migration is idempotent: after it runs, `machines.toml` exists, so the third rule
makes every later boot a no-op.

## 5. Session machine selection

`SessionMeta` gains one tolerant field:

```haskell
  , smMachine :: Maybe MachineName
    -- ^ Execution machine this session runs on. 'Nothing' on sessions
    -- created before this feature: resolved via 'machineForSession'.
```

Decoded with `.!= Nothing`-style tolerance like `smChannel`/`smAgent`, so old
`session.json` files load unchanged.

Resolution for a session, one pure function used by every surface:

```haskell
machineForSession :: MachineRegistry -> SessionMeta -> Either MachineError MachineTarget
```

- `smMachine = Just n` → that machine, or `Left (MachineGone n)` when it is not
  in `mrMachines`. **Deleted or rejected → error, never the default**
  (requirements, Done-when 10).
- `smMachine = Nothing` → `mrDefault`, else `Left NoMachineSelected`.

`MachineError` is a bespoke ADT because the call sites pattern-match on it to
render different messages (the requirements specify four distinct texts) — which
is exactly the criterion for introducing one under this repo's conventions:

```haskell
data MachineError
  = MachineUnknown Text [MachineName]   -- unknown name + the valid choices
  | MachineUnusable MachineName Text    -- configured but broken + why
  | MachineGone MachineName             -- session's machine no longer configured
  | MachineNotPermitted MachineName     -- `local` with allow_localhost = false
  | NoMachineSelected                   -- allow_localhost = false, no machines
```

### 5.1 How the choice reaches the session

- **TUI** — `runCliTui` prompts once before the first session, using the existing
  `ccPrompt`/`AskPrompt` machinery (the same seam host-key adoption uses), when
  `mrMachines` has ≥2 entries. Empty reply → `mrDefault`.
- **Web** — `NewArgs`/`CreateTabBody` gain an optional `machine`, rendered as a
  picker in `NewTabComposer` only when ≥2 are selectable. The choices are
  published by the existing session-create options payload.
- **Chat channels** — no prompt; `mrDefault`.
- **`/new -x`/`--machine`** — parsed in `Seal.Gateway.Types.NewArgs` alongside
  `-p`/`-m`/`-r`/`-b` (so the chat loop and CLI share one parser, per that
  module's existing contract) and in `Seal.Command.New`'s optparse parser.

## 6. The per-call seam

This is the substantive change.

### 6.1 `UIOEnv` carries the registry

```haskell
data UIOEnv = UIOEnv
  { uieUntrustedIO :: !UntrustedIO
  , uieCloneDeps   :: !CloneDeps
  , uieMachines    :: !MachineRouting     -- new
  }

data MachineRouting = MachineRouting
  { mrTargets  :: Map MachineName UntrustedIO   -- one handle per machine
  , mrSession  :: MachineName                   -- the session's machine
  }
```

`uieUntrustedIO` is retained and **means the session machine's handle**, so
`Seal.Tools.Exec.WorkdirFs` (which reads it for its own snapshot/path work) keeps
working unmodified. `mrSession` is the fallback every opcode resolves to when it
is handed no explicit machine.

`mrTargets` holds a *fully built* `UntrustedIO` per machine, not an `SshConfig`,
for two reasons: the workdir bootstrap is per machine per session (§7), so the
handle is the thing that exists; and building it eagerly at session exec time
keeps `ssh` connection setup out of the per-call path.

### 6.2 The `uio*` surface takes the target

Every `uio*` function gains a leading machine selector. The type is a newtype
whose constructor is unexported, so it can only come from the resolver:

```haskell
-- | Which machine a call runs on. Constructed only by 'forMachine'
-- (an explicit, validated name) or 'sessionMachine' (the session default).
-- The constructor is not exported: an opcode cannot invent a target.
newtype ExecTarget = ExecTarget MachineName

forMachine :: MachineRouting -> MachineName -> Either MachineError ExecTarget
sessionMachine :: MachineRouting -> ExecTarget
```

```haskell
uioShellExec :: ExecTarget -> ShellCommand -> Maybe RemotePath
             -> UIO (Either UntrustedErr Text)
```

and likewise for `uioRead`, `uioWrite`, `uioPatch`, `uioBinExec`,
`uioProcessList`, `uioProcessKill`, `uioSearchFiles`, `uioShellExecEnv`,
`uioShellExecGitEnv`, `uioBinExecEnv`, `uioBinExecGitEnv`.

Implementation is uniform — one helper, so every op goes through the same
resolution:

```haskell
withTarget :: ExecTarget -> (UntrustedIO -> IO (Either UntrustedErr a))
           -> UIO (Either UntrustedErr a)
withTarget (ExecTarget n) act = UIO $ do
  env <- ask
  case Map.lookup n (mrTargets (uieMachines env)) of
    Just uio -> liftIO' (act uio)
    Nothing  -> pure (Left (UeExec (ExecNotImplementedReason …)))   -- unreachable
```

The `Nothing` branch is unreachable by construction — `ExecTarget` can only be
built for a name in `mrTargets`. It exists because the repo forbids `error` in
production code; it returns a structured error instead.

**Why the newtype rather than a bare `MachineName`:** it makes the target
mandatory at the type level. If a future `uio*` function is added and its author
forgets the selector, the code does not compile — the same
capability-scoping-by-types argument the `UIO` monad already rests on.

`uioLiftIO` and `uioUntrustedIO` keep their current shapes. The latter returns
the *session* handle, and its one remaining caller (`Seal.ISA.Ops.Repo`'s
`cloneRepoIO`) is migrated to `withTarget` so no opcode reads a raw handle.

### 6.3 Opcode input parsing

The eight untrusted opcodes gain an optional `machine` property in their
schemas, parsed by one shared helper in `Seal.ISA.Ops.Common`:

```haskell
machineField :: Value -> Maybe Text          -- Nothing when absent
resolveTarget :: MachineRouting -> Maybe Text -> Either MachineError ExecTarget
```

`resolveTarget` maps `Nothing` → `sessionMachine`, and `Just t` → a validated
`MachineName` looked up in the routing table. **This is where an unknown name
becomes a tool error naming the valid choices** (Done-when 13) — before any
`uio*` call, so nothing runs anywhere.

Because the opcodes read the routing table, `uoRun`'s `UIO` environment is the
only input; the registry is not threaded through `Opcode`. That keeps
`Seal.ISA.Opcode`'s GADT unchanged, which matters because it is the most
sensitive type in the repo.

**Schema visibility.** The model must see the selectable names (requirements,
"the model sees the selectable machine names in its tool catalog"). The schema
is currently a constant (`shellExecSchema`), so it becomes a function of the
registry: `shellExecOp` already receives `wsRoot`/`policy` at registry-build
time, and `buildSessionRegistry` will pass the machine list, which
`machineSchemaProp :: MachineRouting -> Value` renders as an `enum`. One
consequence: the per-turn registry rebuild already happens
(`buildSessionRegistry` per turn), so no caching change is needed.

**Excluded opcodes.** `WEB_FETCH`/`WEB_SEARCH`/`BROWSER_MANAGE` do not gain
`machine`. `BROWSER_MANAGE` goes through `uioBinExec` and *could*, but its
`agent-browser` session state is not per-machine, so exposing the choice would
promise isolation this change does not deliver. `WEB_*` run in-process
(pre-existing, recorded in the requirements' design notes). Both are stated in
the design so the omission is a decision, not an oversight.

### 6.4 Transcript record

`orRecorded` for each untrusted opcode gains the resolved machine name — the
*requested* one, and nothing else about the machine (no host, no user), per the
requirements' constraint that the record carries the name only. Done-when 14.

## 7. Workdirs, discovery and caching

### 7.1 Per-machine workdirs

`mkSessionExec` becomes per-machine. For the session's machine it must
bootstrap before the first turn — that is today's behaviour and stays. For the
*other* machines, bootstrapping every machine at session start would cost N SSH
round trips for machines the session may never touch, so they are built
**lazily on first use**, memoized per `(SessionId, MachineName)`:

```haskell
data SessionExec = SessionExec
  { seUIOEnv        :: UIOEnv
  , seWorkdirFs     :: WorkdirFs
  , seWorkspaceRoot :: WorkspaceRoot
  , seMachines      :: MachineRouting   -- exposed for opcode resolution
  }
```

`seUIOEnv`/`seWorkdirFs`/`seWorkspaceRoot` remain the **session machine's**, so
every existing caller keeps its meaning. `mrTargets` starts with the session
machine and gains an entry the first time a call names another machine.

Lazy bootstrap is the one place this design adds state to a path that was
formerly pure-once. Guarded by the existing `SessionExecCache` pattern
(`IORef (Map …)` + `modifyIORef'`), and it reuses `ensureRemoteSessionWorkdir`'s
`mkdir -p`, which is idempotent, so a concurrent first use is safe (worst case:
two idempotent mkdirs).

`ExecCache`'s fingerprint changes from `show (untrustedExecConfigFromSecurity …)`
to `show (machineRegistryFingerprint, sessionMachine)`, so a `machines.toml` edit
or a session-machine change rebuilds, and a change confined to one machine does
not (the fingerprint is the registry's resolved set, not the session's lazily
added handles).

### 7.2 Discovery

`cachedWorkdirScan` stays keyed on the **session machine's** workdir. Agent
defs and skills are repo-local content, and the requirements put per-machine
agent/skill state out of scope; scanning N workdirs would surface N divergent
catalogs. A model working on another machine sees that machine's *files* via
`FILE_*`/`SEARCH_FILES`, not a second skills catalog. Recorded so the choice is
explicit.

## 8. Where `local` and the flag are enforced

Three layers, unchanged in structure, updated in content:

1. **Config resolution** (§2.2) — `local` is absent from `mrMachines` when
   `allow_localhost = false`, so no name for it exists to resolve.
2. **Selector** — `selectExecBackend` returns `EbLocal` only for `MtLocal` when
   `uecMode = UemLocal`; `Left ExecLocalNotPermittedForUntrusted` otherwise.
3. **Build** — `-f remote-only-untrusted` omits `Seal.Tools.Exec.Local`, and
   `enforceRemoteOnly` rejects a config that permits local, now expressed as
   `allow_localhost = true` being rejected at startup.

The model cannot reach layer 2 or 3 by naming anything: the only name that maps
to `MtLocal` is `local`, and it is not in the registry under
`allow_localhost = false`.

## 9. Test obligations

Per work unit, TDD-first. The invariants from §1.1 each get a test:

| # | Obligation |
|---|---|
| 1 | Machine resolution is pure: loopback hosts rejected; missing fields rejected with the field named; `[machines.local]` in the file is an error; `default` naming a missing/rejected machine is an error. QuickCheck: any resolved `MachineTarget` has a non-loopback host, and `local` present iff the flag. |
| 2 | **ACK-before-execute survives**: an untrusted call naming a machine still records before `uoRun`; asserted with a recording transcript handle, as the existing dispatch specs do. |
| 3 | **No fallback**: a call against an unknown/unusable/gone machine runs `uio*` zero times, asserted with a counter-instrumented `UntrustedIO` per machine. Property: for any input, at most one machine's counter increments. |
| 4 | **`allow_localhost = false`**: `local` is not in the registry; `selectExecBackend _ MtLocal` is `Left`; and the `-f remote-only-untrusted` build is compiled and checked in CI. |
| 5 | **Type-guaranteed sanitization**: `ExecTarget`'s constructor is unexported (compile-fail fixture, following the existing `CapabilityScopingFail` precedent); a model-supplied `machine` never reaches `ssh` argv — a machine named `-oProxyCommand=…` is a `MachineUnknown` error, not argv. |
| 6 | **Session machine persistence**: `SessionMeta` round-trips `smMachine`; an old `session.json` without the field decodes to `Nothing`; `machineForSession` with a deleted machine is `MachineGone`, never the default. |
| 7 | **Not sticky**: two calls in sequence, the first naming machine B and the second omitting it, both resolve to the session machine on the second — asserted on the resolved target, not just the outcome. |
| 8 | **Non-interactive host-key refusal**: `mkSessionExec` with `mAdoption = Nothing` and an unknown key fail-closes; changed key never adopts. |
| 9 | **Migration**: all five rows of §4's table, including idempotency and the incomplete-remote row. |
| 10 | **Workdir isolation**: two machines get distinct `workdirs/<sid>` paths; a read on machine B of a file written on machine A returns not-found (this is the cross-machine behaviour the requirements call out, asserted so it cannot regress silently). |

## 10. Module inventory

**New**

- `src/Seal/Config/Machines.hs` — codec, `MachineName`, resolution to
  `MachineRegistry`, `isLoopbackHost`.
- `src/Seal/ISA/Ops/Common.hs` — `machineField`, `resolveTarget`,
  `machineSchemaProp`.
- `config/templates/machines.toml` — embedded template.

**Changed**

- `Seal.Config.Security` — `allow_localhost`; delete
  `UntrustedExecRemoteFileConfig`.
- `Seal.Config.Paths` — `machinesFilePath`, `execKnownHostsPath`.
- `Seal.Config.Templates` — seed `machines.toml`.
- `Seal.Config.Migrate` — `migrateExecutionMachines`.
- `Seal.Tools.Exec.Types` — `SshConfig` loses `scKnownHosts`;
  `MachineName`/`ExecTarget`/`MachineError` (or a new
  `Seal.Tools.Exec.Machine`).
- `Seal.Tools.Exec.Untrusted` — `UntrustedExecConfig` shrinks; selectors take
  `MachineTarget`.
- `Seal.Tools.Exec.UIO{,.Internal}` — `MachineRouting`, `withTarget`, target
  argument on all twelve functions.
- `Seal.Session.Workdir` — per-machine `SessionExec`, lazy bootstrap.
- `Seal.Session.ExecCache` — re-key; per-`(sid, machine)` exec map.
- `Seal.Session.Meta` — `smMachine`.
- The eight untrusted opcode modules — `machine` input, resolved target.
- `Seal.Gateway.Types.NewArgs`, `Seal.Command.New`, `Seal.Channel.Cli`,
  `Seal.Gateway/{API,Send}`, `Seal.Core/TurnEngine` — plumbing the registry and
  the session choice.
- `frontend/src/components/NewTabComposer.tsx` + `types.ts` + `useNewTabSpec.ts`
  — the machine picker.

## 11. Risks and their mitigations

- **Breadth.** Twelve `uio*` signatures × eight opcodes × four surfaces. Mitigated
  by doing the signature change as one mechanical work unit with a compile-driven
  checklist, before any behaviour work.
- **Lazy bootstrap adds state.** Mitigated as §7.1: memoized, idempotent, and
  a test asserting a second call does not re-bootstrap.
- **Schema growth.** A machine `enum` on eight tools costs tokens every turn.
  Accepted: the requirements make model-side choice load-bearing, and the enum is
  a handful of names. If it proves costly, `registryToolDefs'`'s existing stub mode
  is the lever, not a design change.
- **`scKnownHosts` removal touches many test fixtures** (≈15 sites). Mechanical,
  but it is why this is not a small change.

## 12. Open questions for the gate

1. `MachineName` should be validated to a conservative charset (alphanumerics,
   `-`, `_`, `.`). Does any surface need names with spaces or Unicode?
2. Lazy bootstrap (§7.1) versus eager-for-all-machines: lazy is chosen for
   latency; is a machine that is only ever touched by one call worth the state?
3. `mrTargets` holds built `UntrustedIO`s; should an idle machine's handle be
   evicted after a period (memory vs. reconnect cost)?
