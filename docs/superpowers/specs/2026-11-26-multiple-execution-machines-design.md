# Multiple Execution Machines — Design

> **Status:** Revision 2, for Design Review Gate round 2.
> **Requirements:** `docs/superpowers/requirements/2026-11-26-multiple-execution-machines-requirements.md`
> (approved 2026-11-26, frozen). That document is the baseline for scope.

## 0. Round-1 gate findings, and what this revision changes

Round 1 returned NEEDS_REVISION from all five reviewers. Triage:

- **16 IN SCOPE** — all fixed here.
- **3 PRE-EXISTING** — recorded in §13 with one line each; filed, not fixed.
- **3 NEW REQUIREMENT** — declined (§0.1).

The three structural corrections, in order of consequence:

1. **The per-call seam as drafted could not compile** (§6). `resolveTarget ::
   MachineRouting -> …` in an opcode module violates the W6 guard
   (`CapabilityScopingWorkdirFsFailSpec.hs:53`), because `MachineRouting` must
   live in `UIO.Internal` and opcode bodies have no `MonadReader`. Resolution
   moves into the `UIO` surface.
2. **The ACK record could not name the machine** (§6.5). `mkInvocationEntry`
   (`Dispatch.hs:146`) writes `erMeta = {op, input}` and untrusted opcodes'
   `orRecorded` is never persisted, so §6.4 of revision 1 satisfied nothing.
   The resolved machine is stamped into the invocation entry before `itwRecordAndAck`.
3. **The hardened build does not deliver the artifact property revision 1
   claimed** (§13.3). `-f remote-only-untrusted` omits only
   `Seal.Tools.Exec.Local`, whose `mkLocalExecHandle` is called by nothing but a
   placeholder; the real local executor `mkLocalUntrustedIO` lives in the
   unconditionally-compiled `UntrustedIO.hs`. Revision 1 asserted a guarantee
   the binary does not have. Corrected below.

### 0.1 Declined (NEW REQUIREMENT, not implemented)

| Finding | Why declined |
|---|---|
| `default` naming a missing machine → boot-fatal | Requirements specify no such failure mode, and all their broken-config texts are call-time. Instead: logged warning + no pre-selection (§2.2 rule 4). |
| `[machines.local]` table → load error | Requirements only say `local` "is not declared in the file". A `[machines.local]` table is ignored with a warning; the reserved *name* is still rejected by `mkMachineName` (§2.2 rule 3). |
| File-view machine badge | Would change user-facing behaviour. The divergence is correct per requirements; only the UI affordance is unrequested. §6.7 records the gap. |

## 1. Problem & approach

Today exactly one SSH target is resolved at boot and turned into one
`SessionExec` (`UIOEnv` + `WorkdirFs` + `WorkspaceRoot`), memoized per session.
Untrusted opcodes never see a backend: they call `uio*` functions that read one
`UntrustedIO` from the `ReaderT` environment.

This change introduces N named machines and makes the target a **per-call**
input. The architectural consequence:

> **The untrusted execution target stops being a wiring-time constant and
> becomes an explicit argument on the `uio*` surface.**

The operator chose (over dispatcher-side resolution) to carry the registry in
`UIOEnv` and pass the target through `uio*`. The cost is that all twelve `uio*`
signatures and ~25 opcode call sites change.

### 1.1 Invariants that must not change

Each has a test in §10.

- **ACK-before-execute** — the invocation is durably recorded before any machine
  runs it, and the record names the machine (§6.5).
- **Fail-closed** — no fallback to another machine, none to `local`.
- **`allow_localhost = false` ⇒ no local untrusted execution.** Enforced in the
  selector; in hardened builds also by the CPP gate on the local wiring path —
  **not** by absence of the executor (§13.3).
- **Type-guaranteed argv sanitization** — a model-supplied machine name is a
  smart-constructed newtype, never raw `Text` into `ssh` argv.
- **`~/.seal` is agent-immutable** — `machines.toml`, `security.toml`,
  `exec-known-hosts` reachable only from boot and human-driven admin paths.
- **Capability scoping** — opcodes can perform no IO outside the `UIO` surface;
  `MachineRouting` never becomes readable from opcode land (§6.3).

## 2. Configuration

### 2.1 `machines.toml`

New file at `spHome </> "machines.toml"`, mode `0600`, boot-only, no opcode
surface. Seeded by `Seal.Config.Templates` under its never-overwrite invariant.

**The shipped template contains every machine table commented out and no live
`default` key**, mirroring `config/templates/security.toml:46-58` (which comments
out `[untrusted_execution]` for exactly this reason). A template with a live
`[machines.linux-builder]` plus `default` would give a fresh install two
selectable machines, a mandatory prompt, and a default pointing at
`builder.example.com` — the opposite of Done-when 3. Test obligation T-3a
asserts a template-seeded fresh install yields exactly one selectable machine
(`local`) and no prompt.

```toml
# default = "linux-builder"

# [machines.linux-builder]
# host      = "builder.example.com"
# user      = "seal"
# port      = 22
# identity  = "/home/you/.ssh/id_ed25519"
# workspace = "/srv/seal/workspace"
```

```haskell
data MachinesConfig = MachinesConfig
  { mcDefault  :: !(Maybe Text)
  , mcMachines :: !(Map MachineName MachineFileConfig)
  }

data MachineFileConfig = MachineFileConfig
  { mfcHost      :: Maybe Text
  , mfcUser      :: Maybe Text
  , mfcPort      :: Maybe Int
  , mfcIdentity  :: Maybe FilePath
  , mfcWorkspace :: Maybe Text
  }
```

`MachineFileConfig`'s fields stay lazy `Maybe`s to match the existing
`UntrustedExecRemoteFileConfig` codec record; every other record in this design
uses strict fields per AGENTS.md.

### 2.2 Validation and the "unusable" concept

```haskell
data MachineRegistry = MachineRegistry
  { regMachines :: !(Map MachineName MachineTarget)  -- resolved, selectable
  , regRejected :: !(Map MachineName RejectReason)   -- configured, unusable
  , regDefault  :: !(Maybe MachineName)
  }

data MachineTarget
  = MtLocal
  | MtSsh !SshConfig            -- name lives in the map key, not here

data RejectReason
  = RrMissingField !MissingField
  | RrLoopbackHost
  | RrInvalidHost !Text
  | RrInvalidWorkspace !Text
  | RrInvalidPort
```

`MtSsh` does not carry the machine name: `regMachines :: Map MachineName …`
already does, and carrying it twice permits key `"a"` → `MtSsh …` for a
different name. Reviewers flagged the duplication; dropping it makes it
unrepresentable.

`RejectReason` is typed rather than `Text` so the operator-facing and
model-facing renderings are two mechanical projections of one value (§5.2)
rather than two hand-written strings that can drift.

Resolution rules — all pure, so testable without boot:

1. Validate each `[machines.<name>]`: `mkMachineName`, then the field checks.
   Missing `host`/`user`/`workspace` → `RrMissingField`. `port` outside `1..65535`
   → `RrInvalidPort`.
2. **Loopback guard, ordered before host validation.** `isLoopbackHost` runs on
   the raw `host` text *before* `mkSshHost`, so a loopback host yields
   `RrLoopbackHost` and the requirement's "is this machine" text rather than
   `mkSshHost`'s generic "invalid characters".
   **Correction to revision 1:** `mkSshHost` already rejects `:`
   (`Types.hs:133`), so `::1`/`[::1]` never reached `isLoopbackHost` there; the
   ordering change is what makes the message right. It is also a resolution-based
   check, not a string one — see §3.2.
3. `local` is injected as `MtLocal` iff `allow_localhost`. A `[machines.local]`
   table is **ignored with a boot warning** (declined as an error, §0.1), but
   `mkMachineName` rejects the reserved name `local` so the implicit machine
   cannot be shadowed.
4. `regDefault` is `mcDefault` when it names a resolved machine. A `default`
   naming a missing or rejected machine is a **logged warning with no
   pre-selection** (declined as boot-fatal, §0.1) — a broken default must not
   stop the harness booting, matching §4's incomplete-remote reasoning.

`mkMachineName` charset: ASCII alphanumerics plus `-`, `_`, `.`; reject leading
`-`, reject `.`/`..` exactly, reject leading `.`, cap at 64, reject `local`.
No surface needs more, and ASCII-only removes any NFC-normalisation mismatch
between the file and a model-supplied string while keeping the schema enum
unambiguous.

### 2.3 `allow_localhost` replaces `mode`

```haskell
data UntrustedExecFileConfig = UntrustedExecFileConfig
  { uefcAllowLocalhost :: Bool }   -- default True when the section is absent
```

`UntrustedExecRemoteFileConfig` is **deleted**; its role moves to
`Seal.Config.Machines`.

**The decoder must distinguish two absences** (round-1 finding): a *whole
section* absent means `True` (today's behaviour, and the frozen default), but a
section **present without `allow_localhost`** is `Left` — otherwise a failed
migration (§4.1) silently downgrades a remote-only install to local. Implemented
as `Toml.dioptional (Toml.table …)` for the section plus a required `Toml.bool`
inside it.

`UntrustedExecMode` survives in `Seal.Tools.Exec.Untrusted` — it is the
selector's input, not the file's, and `enforceRemoteOnly` still needs it. Derived,
not read:

```haskell
untrustedExecConfigFromSecurity :: SecurityConfig -> UntrustedExecConfig
-- UemLocal when allow_localhost, UemRemote otherwise
data UntrustedExecConfig = UntrustedExecConfig { uecMode :: !UntrustedExecMode }
```

The return type loses its `Maybe` (no "section absent" state remains) and
`uecRemote` goes away (targets live in the registry). Ten call sites branch on
that `Maybe` today; §12 lists them.

Replacing `mode` with a Bool also closes a silent-coercion hole worth recording:
`resolveByMode` (`Security.hs:767`) currently maps any value that is not
literally `"remote"` to `UemLocal`, so a typo quietly permits local execution. A
TOML bool fails closed on a typo.

## 3. Host keys

`scKnownHosts :: FilePath` **stays in `SshConfig`**. Revision 1 said it was
removed *and* "always built with that path" — incoherent, and it left three pure
argv builders (`sshExecArgv` `Remote.hs:98`, `sshExecArgvForwarding` `:135`,
`rsyncRshString` `AgentMetaCache.hs:191`) with no `SealPaths` in scope.

The requirement "there is no `known_hosts` field" is **config-file level**: no
operator-supplied path in any config file. That is satisfied by filling the field
from one place:

```haskell
execKnownHostsPath :: SealPaths -> FilePath
execKnownHostsPath paths = spHome paths </> "exec-known-hosts"
```

`SshConfig` is constructed only by the machine resolver (§2.2), which sets
`scKnownHosts = execKnownHostsPath paths`. Every consumer is unchanged.

This is a **strengthening**, not just a move: today's operator-supplied path
reaches unquoted shell interpolation (`… >> <path>` at `FileExplorer.hs:215` and
`Workdir.hs:216`) and could point at a workspace-relative location. A
harness-derived fixed path removes that surface. The quoting stays anyway.

### 3.1 Why one pin file is not trust conflation

`ssh -o UserKnownHostsFile=<one file> -o StrictHostKeyChecking=yes` keys
`known_hosts` entries by hostname (or `[host]:port`), and strict checking
consults only the matching entry. Per-host isolation is enforced by ssh, not by
splitting files. Recorded so this is not re-litigated. `ssh-keyscan`'s host keying
for non-22 ports must be verified end to end — a mismatch strands adoption
entries (fail-closed, but confusing).

### 3.2 The self-key guard: moved to the connection path, and not the primary defence

Revision 1 put the self-key comparison inside `HostKeyAdoption`, which runs only
on the `ExecHostKeyUnknown` branch (`Workdir.hs:194-215`) — so an already-pinned
machine never probed and the guard never fired. It also read
`~/.ssh/ssh_host_*_key.pub`, when sshd host keys live in `/etc/ssh/`.

Corrected design, three layers:

1. **Resolution-based loopback refusal at connect (primary, not skippable).**
   Before the first connection to a machine, resolve its host with `getaddrinfo`
   and refuse if **any** resolved address is loopback, unspecified, or a local
   interface address. This implements the requirement's "A remote execution
   machine must be a separate machine" and needs no harness key. It catches
   `mybox.lan`, `/etc/hosts` aliases, `127.1`, and hex forms that the string check
   misses.
2. **String check at config load** (§2.2 rule 2) for the fast, obvious case and a
   good message.
3. **Self-key comparison at connect (third line, best-effort).** Compare the
   presented key against the harness's own sshd host keys, read from
   `/etc/ssh/ssh_host_*_key.pub` on Linux (configurable), not `~/.ssh/`. If the
   harness key is unreadable the check is **skipped**, which now degrades from
   two defences to one rather than to zero.

The requirements' literal text says the guard runs "when connecting… if the
machine presents a host key identical to the harness machine's own". Layer 3
implements it; layers 1–2 are the reason its absence is survivable.

### 3.3 Pre-pinning

Requirements: "A machine may be pre-pinned non-interactively by supplying its
key, for scripted installs." Revision 1 had no counterpart. Specify: a
`seal machine pin <name>` subcommand (human-driven admin path, like
`seal access-control`) that probes the host, prints the fingerprint, and appends
to `exec-known-hosts` under `--yes`. It never bypasses the loopback refusal.
Documented in the template as the scripted path.

### 3.4 HostKeyAdoption copy

`buildAdoptionPrompt` (`HostKeyAdoption.hs:216-222`) currently renders text that
does not match the requirement, and cannot name the machine (`HostKeyInfo` has no
machine field). It gains the machine name and the requirement's exact lines
(`machine "X" is not yet known.` / `host:` / `key:` / `Trust this key? [y/N]`).
The logic is unchanged; the copy is a work unit with an exact-string test (T-11a).

## 4. Migration

`Seal.Config.Migrate` gains `migrateExecutionMachines`, following its existing
rules (strip only after a successful write; new file wins except where it has no
answer; never strip what was not moved).

| On disk | Action |
|---|---|
| no `[untrusted_execution]`, no `machines.toml` | write template (all commented); `allow_localhost` stays absent ⇒ `True`. Nothing else. |
| `mode = "remote"` + complete `[untrusted_execution.remote]` | write `[machines.default]` from `host`/`user`/`port`/`identity`/`workspace`; **drop `known_hosts`**; `default = "default"`; `allow_localhost = false`; strip the old table. |
| `mode = "remote"` + incomplete remote block | `allow_localhost = false`; **no** machine written; log loudly. Session then fails closed with the "no machine configured" text. Writing a half-populated machine would trip `default`-resolution and turn a working-but-broken install into a confusing one. |
| `mode = "local"` or section absent | `allow_localhost = true`; strip `mode` if present. |
| `machines.toml` already exists | it wins; only the `security.toml` strip happens. |

Idempotent: after the first run `machines.toml` exists, so later boots are no-ops.

### 4.1 Migration failure must not downgrade a remote-only install

`Migrate` is fail-open by design (`Migrate.hs:65`: "Write fails → log a loud
error and proceed"). Revision 1 adopted that posture uncritically. The dangerous
post-failure state: `security.toml` still holds `mode="remote"` +
`[untrusted_execution.remote]` (which the new codec ignores), `allow_localhost`
is absent ⇒ `True`, and the remote coordinates were never moved. A remote-only
install silently becomes a local-execution install.

Fix (§2.3): a *present* `[untrusted_execution]` section without `allow_localhost`
is a decode error, so the failed-migration state is a visible boot error naming
the file, not a silent downgrade. T-M4 asserts this row.

## 5. Session machine selection

```haskell
  , smMachine :: Maybe MachineName   -- Nothing on pre-existing sessions
```

Decoded with `.:?` + default, so old files load; `session.json` compatibility
verified — `FromJSON` already uses `.:?`/`.!=` for optional fields
(`Meta.hs:113-128`) and unknown keys are ignored in both directions.

```haskell
machineForSession :: MachineRegistry -> SessionMeta -> Either MachineError MachineTarget
```

Checked **in this order** (round-1 fix — revision 1 checked only `regMachines`,
making `MachineUnusable` unreachable and reporting a misconfigured machine with
the deleted-machine text):

1. `smMachine = Just n`, `n ∈ regMachines` → that target.
2. `smMachine = Just n`, `n ∈ regRejected` → `MachineUnusable n reason`.
3. `smMachine = Just n = "local"`, `allow_localhost = false` → `MachineNotPermitted n`.
4. `smMachine = Just n`, otherwise → `MachineGone n` (deleted).
5. `smMachine = Nothing` → `regDefault`, else `MachineDefaultUnset`.

`MachineDefaultUnset` is new: revision 1 routed this to `NoMachineSelected`,
whose text ("allow_localhost is false and no execution machine is configured") is
false on both counts when the flag is true and machines exist.

```haskell
data MachineError
  = MachineUnknown Text [MachineName]    -- unknown name + valid choices
  | MachineUnusable MachineName RejectReason
  | MachineGone MachineName
  | MachineNotPermitted MachineName
  | MachineDefaultUnset
  | NoMachineSelected
  | MachineUnreachable MachineName Text
```

A bespoke ADT is justified here for the reason AGENTS.md gives: call sites
pattern-match on it to drive control flow *and* the `MachineUnknown` case must
carry the valid-choices payload to render. (Revision 1 justified it as "renders
different messages", which is display, not control flow — reviewers correctly
called that weak.)

### 5.1 How the choice reaches the session

- **TUI** — prompt before the first session when `regMachines` has ≥2 entries;
  no prompt at 1. Rendered by its own pure function (§5.3), not by
  `formatQuestionWithOptions`.
- **Web** — `NewTabComposer` picker, shown only at ≥2, defaulted.
- **Chat channels** — no prompt; `regDefault`. If unset, `ASK_HUMAN` with the
  machine list rather than a dead end.
- **`/new -x`/`--machine`** — see §5.4.
- Resuming uses `smMachine`; a legacy session displays its **resolved** machine,
  not a blank (§5.2).

### 5.2 Display — the four surfaces

The requirements say the machine is "shown on the session (sidebar / session
list)" and give exact renders. Revision 1 covered persistence and the picker but
none of the display, so a user could not see which machine a session runs on.
All four:

| Surface | File | Change |
|---|---|---|
| Web sidebar row | `frontend/src/types.ts` (`SessionInfo`), `components/Sidebar.tsx:66-140` | add `machine`, render in the row |
| Web session JSON | `Seal/Gateway/SessionJson.hs:81` (`sessionInfoJson`) | add `"machine"` field |
| TUI `/session list` | `Seal/Command/Session.hs:71` (`renderSessionLine`) | add a machine slot |
| TUI startup banner | `Seal/Channel/Cli.hs:188` | append `  machine: <name>` |

Two of these need copy changes beyond an added field, both pinned by tests:
`renderSessionLine` currently emits `<sid>  <provider>/<model>` and the
requirement shows `2  ai  seal-harness  mac-mini` (provider/model *absent*);
`Cli.hs:188` emits `provider / model` with spaces where the requirement shows
`anthropic / claude-opus-4-8` — those stay, and `machine:` is appended.

For a legacy session (`smMachine = Nothing`) all four show the resolved machine,
so the column is never blank on upgrade.

**Operator vs model text is split** (round-1 finding — a model-facing error
naming `host "localhost"` leaks coordinates the requirements forbid): the
operator boot report renders `RejectReason` fully (`host "localhost" is this
machine`); the model-facing `MachineUnusable` renders the field name only
(`workspace not configured`) plus the config path. This is why `RejectReason` is
typed (§2.2).

**Error rendering** (round-1 finding — the requirements' `SHELL_EXEC failed: `
prefix exists nowhere in the repo; the repo's convention is `<OPNAME>: <msg>`).
Because the frozen requirements specify `failed:`, the design adds it: a single
renderer in `Seal.ISA.Ops.Machine`:

```haskell
renderMachineError :: OpName -> MachineError -> Text   -- "<OP>: failed: <msg>"
```

**One seam only.** Machine errors are resolved in `uioResolveTarget` (§6.3) and
rendered by the opcode's `uoRun` through this one function, so the same error
class cannot render with two prefixes. `withTarget`'s internal fallback does not
render at all — it returns a `MachineError` (§6.2).

### 5.3 The TUI prompt

`formatQuestionWithOptions` (`AskReply.hs:244-254`) renders `1) label — desc`
plus a `Reply with a number…` trailer. It is shared with `ASK_HUMAN` and the
confirmation gate, where those details are load-bearing. The requirement's
`1. local          (this machine)` alignment is not reachable through it,
so the machine prompt is its own pure function beside `buildAdoptionPrompt`
(which is exactly this pattern and already exported for testing):

```haskell
buildMachinePrompt :: [MachineName] -> Maybe MachineName -> Text
```

Tested as an exact string (T-11b).

### 5.4 `/new -x`

`NewArgs.naMachine :: Maybe Text` — **`Text`, not `MachineName`**:
`src-gateway-types` is a separate cabal library with no dependency on the main
library, so a `MachineName` field would be an illegal edge. Validation happens at
the main-library boundary.

Both parsers must agree, and the design must close the specific failure where the
shared module gains the field but the CLI's optparse parser does not, causing
`/new -x` to silently do nothing on the CLI. So:
`Seal.Command.New` gains a fifth optparse flag, and T-5a asserts
`parseNewArgs "-x mac-mini"` equals what the optparse parser produces, in the
`renderNewSessionConfirmation` mould.

`-x` is free (only `-p`/`-m`/`-r`/`-b` are taken). **An unknown or unusable
machine fails at `/new` time** with the valid-choices list, before a session is
minted — not deferred to a stranded session that can never run.

## 6. The per-call seam

### 6.1 Routing lives in `UIOEnv` as a resolver, not a mutable map

Revision 1 put `mrTargets :: Map MachineName UntrustedIO` in `UIOEnv` and said it
"gains an entry the first time a call names another machine". That is
unrepresentable: `UIOEnv`/`SessionExec` are immutable records, `withTarget` reads
them via `ask`, and `SessionExecCache` is keyed by `SessionId` so it is
unreachable from inside a `UIO` action.

Corrected: the environment carries a **resolver**, and the mutable cell lives in
`SessionExec`, where it can be owned.

```haskell
-- Seal.Tools.Exec.Machine (new; opaque from opcode land)
data MachineRouting = MachineRouting          -- constructor NOT exported
  { rtResolve :: MachineName -> IO (Either MachineError UntrustedIO)
  , rtSession :: MachineName
  , rtSelectable :: [MachineName]             -- for the schema enum
  }
```

`MachineSlot` memoizes outcomes, including failures:

```haskell
data MachineSlot = SlotReady !UntrustedIO | SlotFailed !MachineError
-- SessionExec owns: IORef (Map MachineName MachineSlot)
```

`rtResolve` is built in `mkSessionExec` over that `IORef`. Behaviour: `Ready` →
return; `Failed e` → return `Left e` (a dead machine costs **one** SSH attempt
per session, not one per call); absent → bootstrap, insert with `modifyIORef'`,
return. In-flight bootstraps are deduped per machine so N concurrent first-uses
do one `mkdir -p`, not N. `mkdir -p` is idempotent, so even without deduping the
worst case is harmless.

Lazy is not merely a latency preference — the requirements put "machine health
checking / pre-flight probing" out of scope and say "reachability is discovered on
first use", so eager bootstrapping of all machines at session start would add
behaviour the frozen scope excludes.

`uieUntrustedIO` is **deleted** (round-1 finding: once `withTarget` exists it is
an escape hatch that lets a future opcode silently bypass machine selection, the
exact failure `ExecTarget` exists to prevent). Its one remaining reader
(`cloneRepoIO`, `Repo.hs:90-91`) is migrated to `withTarget`.

### 6.2 `ExecTarget` and `withTarget`

```haskell
newtype ExecTarget = ExecTarget MachineName   -- constructor NOT exported

withTarget :: ExecTarget -> (UntrustedIO -> IO a) -> UIO (Either MachineError a)
```

`withTarget` is generalized to `IO a` (not `IO (Either UntrustedErr a)`) so it
fits `cloneRepoIO`'s `IO CloneResult`.

Honest statement of what the type guarantees: **"some target was named"**, not
"the caller chose it" — `sessionMachine` wraps `rtSession` unvalidated, which is
correct per the requirements (omitting `machine` uses the session machine) but is
not the stronger claim revision 1 made.

`withTarget`'s failure branches return a `MachineError` with the machine named
(`MachineUnreachable`/`MachineUnusable`), never the generic
`ExecNotImplementedReason` — revision 1's `Nothing` branch would have made a
lookup miss indistinguishable from a genuinely stubbed backend.

### 6.3 Resolution lives in the `UIO` surface

The compile error of revision 1: opcode bodies are `UIO`, which exports no
`MonadReader`/`MonadIO`, and `CapabilityScopingWorkdirFsFailSpec.hs:53` fails the
build if any `src/Seal/ISA/Ops/` module imports `UIO.Internal`. So
`resolveTarget :: MachineRouting -> …` in opcode land is unimplementable, and the
obvious fix (exporting `MachineRouting`) would void the capability guarantee.

Corrected split:

```haskell
-- Seal.Tools.Exec.UIO (opcodes already import this legally)
uioResolveTarget :: Maybe Text -> UIO (Either MachineError ExecTarget)
sessionTarget    :: UIO ExecTarget          -- the session machine

-- Seal.ISA.Ops.Machine (pure only — no env access)
machineField     :: Value -> Maybe Text
machineSchemaProp :: [MachineName] -> Value
renderMachineError :: OpName -> MachineError -> Text
```

`MachineRouting`'s constructor and fields are **not exported**; only
`mkMachineRouting` (used by `mkSessionExec`) and the `UIO` functions above. No
opcode module may destructure it — added as a grep obligation (§10 T-CAP).

One source of truth per lifetime, so the two cannot disagree once a machine is
lazily added: the **schema enum** comes from `regMachines` (static, config-derived,
names only); **resolution** comes from the `UIO` env (dynamic, handles). The
registry builder receives `[MachineName]`, never live `UntrustedIO` handles.

`buildSessionRegistry` already runs per turn (`TurnEngine.hs:279`, rebuilt at
`:747`, `:1136`), so making the eight schemas functions of the machine list needs
no caching change — verified.

### 6.4 Opcode input

The eight untrusted opcodes gain an optional `machine` property, parsed by the
shared `machineField` and resolved by `uioResolveTarget`. `Nothing` → session
machine; `Just t` → validated, looked up, and an unknown name becomes a tool
error naming the valid choices **before any `uio*` call**, so nothing runs
anywhere.

`Seal.ISA.Opcode`'s GADT is unchanged.

`machineField` moving to a shared module is a mild break from the repo's
per-field local-helper convention (`commandField`, `cwdField`, `pathField`), which
is justified by 8 consumers and stated here so it is not re-litigated.

**Excluded opcodes**, with the reason stated so the omission reads as a decision:

- `BROWSER_MANAGE` — `agent-browser` session state is not per-machine; exposing
  the choice would promise isolation this change does not deliver. Its `uoDesc`
  gains "always runs on the session machine" so a model that has just used
  `machine` on `SHELL_EXEC` is not silently mis-modelling the execution plane.
- `WEB_FETCH`/`WEB_SEARCH` — in-process today (§13.1).

The trust label now means "runs under the untrusted policy", not "runs on the
untrusted machine"; §13.1 is why.

### 6.5 The ACK record names the machine

The load-bearing correction. `mkInvocationEntry` (`Dispatch.hs:146-161`) writes
`erMeta = {op, input}` **before** `uoRun`, and untrusted opcodes' `orRecorded` is
never persisted (only `SKILL_LOAD`/`SETUP_REPO` get a `result` entry, via
`recordSkillLoadResult`/`recordSetupRepoResult`). So revision 1's plan — put the
machine in `orRecorded` — changed nothing observable, and Done-when 14 was
unsatisfiable.

Corrected: machine resolution happens **in `dispatch`, before
`itwRecordAndAck`**, and the resolved name is stamped into the invocation entry:

```haskell
-- dispatch, UntrustedOpcode branch
resolved <- resolveMachineForCall uioEnv name input   -- pure-ish, no execution
entry    <- liftIO (mkInvocationEntryWithMachine name input resolved)
liftIO (itwRecordAndAck h …)                          -- ACK, now naming the machine
…
```

This *strengthens* ACK-before-execute rather than violating it: the record still
precedes execution, and it now records the machine that will actually be used
rather than only what the model typed. It also removes the divergence risk — the
recorded name is the resolved target, not a post-hoc report.

`erMeta` gains `"machine"` only when the opcode is untrusted and a target
resolved. The requirement's "carries the machine name and nothing else about it"
holds: a name, no host/user/path.

`resolveMachineForCall` needs only the registry's resolved/rejected sets and the
session machine — **not** a built handle — so no SSH happens pre-ACK.

### 6.6 `SETUP_REPO` on a non-session machine — supported, scoped

Operator decision (round 1): **support it, scoped.** The requirements list
`SETUP_REPO` as machine-selectable, and the post-clone hooks were hard-wired to
the session machine (`TurnEngine.hs:1147-1197`: `recordSetupRepoResult`,
`updateSessionRepo`, `invalidateWorkdirScan`, `cachedWorkdirScan`,
`autoBindRepoAgentWith`).

Semantics when `machine ≠ session machine`:

- The clone runs on the named machine.
- **No** agent auto-bind, **no** session workdir re-scan, **no** cached-scan
  invalidation — all three read the session machine's `wfs`/`wsRoot`, and
  running them would re-scan A after cloning to B, find nothing, and bind from
  the wrong tree.
- `session.json` gains `smRepoMachine :: Maybe MachineName` so provenance is not
  a lie, and the transcript's invocation entry names B (§6.5).
- The result text says the clone landed on B and that discovery did not refresh.
- Relative `FILE_*` on B works (B's workdir exists); relative `FILE_*` on A
  returns not-found, which is the requirements' stated out-of-scope behaviour.

This keeps §7.2's "one skills catalog" decision intact while making the
divergence visible.

### 6.7 The file explorer

`mkRemoteFileExplorer` is built **once at boot** from a single `SshConfig`
(`Serve.hs:677`), so with N machines it has no defined target. Decision:
**session-machine-only**, following the session's resolved machine, with the
divergence from a model working on another machine recorded in §12's follow-ups.
Per-request machine selection in the file view would change user-facing behaviour
(the declined badge, §0.1). Same decision for `handleSessionWorkdir`
(`Gateway/API.hs:1710`).

## 7. Workdirs, discovery, caching

### 7.1 Per-machine workdirs

`SessionExec` keeps `seUIOEnv`/`seWorkdirFs`/`seWorkspaceRoot` as the **session
machine's**, so existing callers keep their meaning, and gains the routing
resolver (§6.1) and the slot `IORef`.

The session machine bootstraps before the first turn (today's behaviour). Other
machines bootstrap lazily via `rtResolve` (§6.1), memoized per
`(SessionId, MachineName)`, with failures memoized too.

`ExecCache`'s fingerprint becomes `(resolved registry, session machine)`: any
`machines.toml` edit rebuilds (the fingerprint *is* the resolved set — revision 1
contradicted itself by also claiming a one-machine change would not rebuild), as
does a session-machine change. Lazily added handles are deliberately excluded:
they are runtime state, not config.

`mkTestUIOEnv` keeps its existing arity by defaulting to a singleton routing whose
only machine is the session machine wrapping the supplied handle. This preserves
behaviour for 109 test call sites across 24 files and keeps the mechanical work
unit green (§11).

### 7.2 Discovery

`cachedWorkdirScan` stays keyed on the **session machine's** workdir. Agent defs
and skills are repo-local content; the requirements put per-machine agent/skill
state out of scope, and scanning N workdirs would surface N divergent catalogs.
A model on another machine sees that machine's files via `FILE_*`/`SEARCH_FILES`,
not a second skills catalog.

### 7.3 WorkdirFs

`WorkdirFs` **is** affected: `WorkdirFs.hs:418` calls
`runUIOWithEnv uioEnv (uioShellExec cmd Nothing)`, so a leading `ExecTarget`
breaks it. One line: `sessionTarget`. Revision 1 claimed it "keeps working
unmodified" — that preserved semantics, not the signature. It belongs in the work
unit checklist so it is not discovered mid-refactor.

## 8. Where `local` and the flag are enforced

1. **Resolution** — `local` is absent from `regMachines` when `allow_localhost =
   false`; no name for it exists to resolve.
2. **Selector** — corrected truth table (round-1 finding: revision 1's table
   refused every remote machine under the default, because `uecMode` is
   `UemLocal` exactly when `allow_localhost = true`):

   | target | `UemLocal` | `UemRemote` |
   |---|---|---|
   | `MtLocal` | `EbLocal` | `Left ExecLocalNotPermittedForUntrusted` |
   | `MtSsh c` | `EbRemote c` | `EbRemote c` |

   `allow_localhost` gates `MtLocal` **only**; `MtSsh` is always selectable.
   QuickCheck property: `MtLocal` + `allow_localhost=false` is never `EbLocal`;
   `MtSsh` is never `EbLocal`.
3. **Build** — `-f remote-only-untrusted` rejects `allow_localhost = true` at
   startup via `enforceRemoteOnly`, which **now has a call site** (§13.2).
   Corrected claim: this is a wiring-level CPP gate plus a config check, **not**
   an artifact property, because the local untrusted executor
   (`mkLocalUntrustedIO`) is compiled unconditionally (§13.3).

## 9. Module inventory

**New**

- `src/Seal/Config/Machines.hs` — codec, `MachineName`, `RejectReason`,
  resolution to `MachineRegistry`, `isLoopbackHost`.
- `src/Seal/Tools/Exec/Machine.hs` — `MachineTarget`, `ExecTarget`,
  `MachineRouting` (opaque), `MachineSlot`, `MachineError`, `mkMachineRouting`.
- `src/Seal/Session/Machine.hs` — `machineForSession`. Placed in the session
  layer, not `Config.Machines`, because `Config` must not depend on
  `Session.Meta` (which is a leaf).
- `src/Seal/ISA/Ops/Machine.hs` — pure: `machineField`, `machineSchemaProp`,
  `renderMachineError`. (Named for what it holds; `Ops.Common` reads as a dumping
  ground.)
- `src/Seal/Command/Machine.hs` — `/machine list`, `seal machine pin`.
- `config/templates/machines.toml`.

**Changed**

- `Seal.Config.Security` — `allow_localhost`; delete
  `UntrustedExecRemoteFileConfig`.
- `Seal.Config.Paths` — `machinesFilePath`, `execKnownHostsPath`.
- `Seal.Config.Templates` — seed `machines.toml`.
- `Seal.Config.Migrate` — `migrateExecutionMachines`.
- `Seal.Tools.Exec.Types` — `SshConfig` unchanged (keeps `scKnownHosts`).
- `Seal.Tools.Exec.Untrusted` — `UntrustedExecConfig` shrinks; selectors take
  `MachineTarget`; `enforceRemoteOnly` gains its call site.
- `Seal.Tools.Exec.UIO{,.Internal}` — `uioResolveTarget`, `sessionTarget`,
  `withTarget`; `ExecTarget` on all twelve functions; `uieUntrustedIO` removed.
- `Seal.Tools.Exec.WorkdirFs` — one-line `sessionTarget` (§7.3).
- `Seal.Tools.Exec.FileExplorer` — session-machine-only (§6.7).
- `Seal.Session.Workdir` — resolver, slot `IORef`, `SessionExec`.
- `Seal.Session.ExecCache` — re-key.
- `Seal.Session.Meta` — `smMachine`, `smRepoMachine`.
- `Seal.Session.AgentMetaCache`, `Seal.Command.Serve`, `Seal.Channel.Cli`,
  `Seal.Gateway/{API,Send,SessionJson}`, `Seal.Core.TurnEngine`,
  `Seal.Command/{New,Session}`.
- The 6 untrusted opcode modules / 8 opcodes / ~25 call sites.
- `src-gateway-types/.../NewArgs.hs` (separate library — sequence cabal edits
  together; `.cabal` is a merge hotspot).
- `frontend/src/{types.ts,components/{NewTabComposer,Sidebar}.tsx,hooks/useNewTabSpec.ts}`.
- `config/templates/security.toml` (documents `mode`/`known_hosts` today).
- `CHANGELOG.md` — operator-visible config schema change.
- `Makefile` + `.github/workflows/{ci,gate}.yml` — `-f remote-only-untrusted`
  build step (Done-when 15).

## 10. Test obligations — Done-when indexed

Revision 1's §9 covered 10 of 15 Done-when items, omitted 7/8/11/14, and
contained two vacuous properties. Replaced by a matrix: every Done-when item names
its design section, spec file, and the RED assertion that fails first.

| DW | Design | Test | RED assertion |
|---|---|---|---|
| 1 | §2.2 | `MachinesSpec` | registry lists machines; `/machine list` shows rejected + reasons |
| 2 | §4 | `MigrateSpec` | remote table → `[machines.default]`, `allow_localhost=false`, old block gone |
| 3 | §2.1, §4 | `TemplatesSpec` | template-seeded install ⇒ exactly 1 selectable (`local`), no prompt |
| 4 | §2.2, §8 | `UntrustedSpec`, `MachinesSpec` | flag false ⇒ `local` absent; `MtLocal` never `EbLocal` |
| 5 | §2.2, §3 | `MachinesSpec`, `MachineConnectSpec` | loopback host rejected with "is this machine"; resolved-loopback refused; self-key refused |
| 6 | §3 | `HostKeyAdoptionSpec` | unknown key prompts once interactively; refused with no human; changed key never adopts |
| 7 | §5.1, §5.3 | `MachinePromptSpec` | ≥2 prompts, empty → default, 1 does not prompt; exact string |
| 8 | §5.1 | `NewTabComposer.test.tsx` | picker hidden at 1, defaulted at ≥2 |
| 9 | §5 | `MachineSpec`, `ExecCacheSpec` | session on A resumes on A after `default`→B |
| 10 | §5 | `MachineSpec` | deleted machine ⇒ `MachineGone`, no fallback |
| 11 | §6.1–6.4 | `MachinesSpec`, `UIO*Spec` | call on A then B in one session, asserted on each machine's **own** counter |
| 12 | §6.4 | `MachinesSpec` | omitted `machine` ⇒ session machine, **every time** (no stickiness) |
| 13 | §5.2 | `MachineSpec` | unknown ⇒ error listing selectable names; **zero** counters increment |
| 14 | §6.5 | `DispatchSpec` | `entries.jsonl` `erMeta.machine` = resolved name, written **before** execution |
| 15 | §9 | `Makefile`/CI | gate step builds + tests with `-f remote-only-untrusted` |

**Non-vacuity** (revision 1's property 3 said "at most one machine's counter
increments", which zero satisfies — exactly the no-fallback regression under
test):

- T-NOFALLBACK: for a resolvable target, **exactly one** counter increments and it
  is the resolved one; for each of `MachineUnknown`/`MachineUnusable`/`MachineGone`/
  `MachineNotPermitted`, **every** counter stays at zero and the error names the
  valid choices.
- T-RESOLVE: generate `(flag, machine list)` with non-empty resolvable sets;
  `checkCoverage` with `cover 20%` clauses for `MtLocal` and `MtSsh` samples, so
  vacuity fails the suite.

**String obligations** (revision 1 had none, though the requirements' review
surface is almost entirely exact strings): one row per user-visible string —
six error texts, the prompt, the session-list line — asserting exact equality,
plus one asserting the TUI and web renderers agree. T-CAP: grep/compile-fail
fixture asserting no `src/Seal/ISA/Ops/` module imports
`Seal.Config.{Machines,Security}` or destructures `MachineRouting`, extending the
existing `CapabilityScopingWorkdirFsFailSpec` precedent.

## 11. Work units (each ends `make check` green)

Revision 1 claimed the signature change could be "one mechanical work unit before
any behaviour work" — not achievable, because `ExecTarget` is unconstructible
until `UIOEnv` carries the routing, and that alone touches 109 test sites. Ordered:

| WU | Content | Green boundary |
|---|---|---|
| W1 | `Config.Machines` + `MachineName` + resolution + `RejectReason`; pure, no wiring | new specs pass; no existing file touched |
| W2 | `ExecTarget`/`MachineRouting`/`MachineSlot`/`MachineError`; `mkTestUIOEnv` keeps arity via singleton default | compiles; existing suite green |
| W3 | 12 `uio*` signatures + `withTarget` + `WorkdirFs` one-liner + `uioUntrustedIO` removal + `Repo` migration | mechanical; ~289 call sites |
| W4 | 8 opcodes: `machine` input, `uioResolveTarget`, schema enum, `renderMachineError`, `BROWSER_MANAGE` desc | opcode specs |
| W5 | `SessionExec` resolver + slot `IORef` + lazy bootstrap + `ExecCache` re-key | workdir/cache specs |
| W6 | `security.toml` `allow_localhost` + delete remote config + selectors + `enforceRemoteOnly` call site | config + selector specs |
| W7 | `machines.toml` codec + template + `Paths` | `MachinesSpec`, `TemplatesSpec` |
| W8 | Migration (all 5 rows + failure row) | `MigrateSpec` |
| W9 | `smMachine`/`smRepoMachine` + `machineForSession` + `/machine list` | `MachineSpec` |
| W10 | Session selection plumbing: TUI prompt, `/new -x`, `NewArgs`, web picker | `MachinePromptSpec`, `NewArgsSpec`, vitest |
| W11 | Display: `sessionInfoJson`, `renderSessionLine`, `Cli.hs:188`, `Sidebar`, `types.ts` | string tests |
| W12 | §6.5 ACK stamping | `DispatchSpec` |
| W13 | §6.6 `SETUP_REPO` scoped semantics | `RepoSpec` |
| W14 | `-f remote-only-untrusted`: fix unconditional `Local` import, Makefile target, CI step | CI green with the flag |
| W15 | `CHANGELOG`, `templates/security.toml` copy | — |

## 12. Counted breaking-change inventory

Revision 1 estimated "≈15 test fixtures"; the real figure is larger and the
estimate sized the work wrong.

| Change | src | test |
|---|---|---|
| `scKnownHosts` (kept — no change) | 0 | 0 |
| `mkTestUIOEnv` arity (preserved by W2 default) | 0 | 0 |
| `uio*` call sites | 132 | 157 |
| `untrustedExecConfigFromSecurity` loses `Maybe` | 10 (branching on the `Maybe`) | 8 |
| `uefcRemote`/`UntrustedExecRemoteFileConfig` deleted | 7 | 14 (incl. `TemplatesSpec.hs:376`, `ApiTestHarness.hs:767`) |
| 8 opcode constructor sites | — | ~115 across 13 files |
| `SshConfig` record construction | — | 14 `scHost=` sites |

Also changed and omitted from revision 1's inventory: `Seal.Tools.Exec.FileExplorer`,
`Seal.Command.Serve:677`, `AgentMetaCache`'s `MetaCacheEnv` (which
pattern-matches `UntrustedExecConfig UemRemote (Just sshCfg)` at `TurnEngine.hs:655`
and needs a new source of `SshConfig` — the registry), and
`config/templates/security.toml:44-59`.

`session.json` compatibility: additive and tolerant, verified (§5).

## 13. Pre-existing defects this design must stop relying on

Filed separately; each needs one line here because the design touches it.

1. **`WEB_FETCH`/`WEB_SEARCH` are labelled Untrusted but run in-process** on the
   control plane via `uioLiftIO` and an `http-client` `Manager`. They never
   traverse SSH, in either mode, so "egress originates on the untrusted plane" is
   not true today. Not machine-selectable here. Issue required.
2. **`enforceRemoteOnly` has zero call sites** in `src/` (definition
   `Untrusted.hs:50`, export `:19`; callers only in two test files). Its docstring
   calls it "the startup check"; that check does not run. W6 wires it, because
   Done-when 15 depends on it.
3. **`-f remote-only-untrusted` does not omit the local executor.**
   `UntrustedIO.hs:79` imports `Seal.Tools.Exec.Local` unconditionally while the
   flag removes that module from `exposed-modules`, so the hardened build very
   likely fails to compile today. And the flag omits only
   `mkLocalExecHandle` (called by nothing but a placeholder in
   `Untrusted.hs:113`); the real executor `mkLocalUntrustedIO`
   (`/bin/sh -c` at `UntrustedIO.hs:327`/`:356`) is compiled regardless. W14 fixes
   the import and the build; a true artifact property is a separate project.
4. **`renderSessionLine` and the TUI banner diverge from the requirements' exact
   renders** (§5.2) — pre-existing copy, changed here because the requirements pin
   it.

## 14. Risks

- **Breadth** — 15 work units, ~289 `uio*` call sites, 6 opcode modules / 8
  opcodes. Sized from call sites (§12), not opcode count.
- **Lazy bootstrap adds state** — mitigated by an explicit resolver with memoized
  failures and per-machine dedupe; a test asserts a second call does not
  re-bootstrap.
- **Schema growth** — a machine `enum` on 8 tools per turn. Accepted; the
  requirements make model-side choice load-bearing. `registryToolDefs'`'s stub
  mode is the lever if it proves costly.
- **Two config files can disagree** — `allow_localhost` lives in `security.toml`,
  machines in `machines.toml`. The resolver takes the flag as a parameter so both
  stay independently testable; §2.3's decode rule is what prevents a silent
  downgrade.

## 15. Open questions — resolved

1. **Name charset** — ASCII alphanumerics plus `-`/`_`/`.`; cap 64; reject
   leading `-`, leading `.`, bare `.`/`..`, and the reserved `local` (§2.2).
2. **Lazy vs eager** — lazy, because the requirements put pre-flight probing out
   of scope (§6.1), not merely for latency.
3. **Eviction** — none in v1: `UntrustedIO` holds no socket (the connection is the
   ssh ControlMaster's, `ControlPersist=600`), so eviction frees a few hundred
   bytes and costs a full `mkdir -p` round trip. The bound is the operator's
   machine count, not time.
