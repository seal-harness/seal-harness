# Multiple Execution Machines — Design

> **Status:** Revision 3, for Design Review Gate round 3.
> **Requirements:** `docs/superpowers/requirements/2026-11-26-multiple-execution-machines-requirements.md`
> (approved 2026-11-26, frozen, **with two operator-approved amendments recorded
> in §0.2**).

## 0. Review history

**Round 1** — 5/5 NEEDS_REVISION. 16 in-scope, 3 pre-existing, 3 declined.
Structural fixes: the per-call seam could not compile (W6 guard); the ACK record
could not name the machine; §8 claimed an artifact property the hardened build
does not have.

**Round 2** — Designer and PM returned NEEDS_REVISION; Architect, Security and
CTO timed out and did not report. Both reporting reviewers agreed on one
diagnosis: *the design describes the right thing and then does not reach the
user-visible surface.* Both independently demanded the same structural fix —
replace prose ("six error texts") with an enumerated string table.

Round-2 fixes in this revision:

| # | Round-2 finding | Fix |
|---|---|---|
| R2-1 | `renderMachineError` emits `<OP>: failed:`; frozen text is `<OP> failed:` | §5.5, one line: `op <> " failed: " <> msg` |
| R2-2 | Changed-host-key string has **no producer** (it is `ExecError`, rendered by `renderExecError`) | §5.4 typed `ExecError → MachineError` mapping + §5.5 table row |
| R2-3 | `machines.toml:`-prefixed config-load text has no producer; `renderMachineError` is `OpName`-typed and structurally cannot emit it | §5.4 second renderer `renderMachineConfigError` |
| R2-4 | `NoMachineSelected` has no producer; its frozen text is unreachable because `MachineDefaultUnset` swallows the state | §5.1 case 5 splits on `(flag, machine count)` |
| R2-5 | `renderSessionLine` cannot reach the frozen 4-column render | §5.6 **corrects the misreading**: the example is `renderTab`, not `renderSessionLine` |
| R2-6 | `/machine list` + `seal machine pin` specified but unwired | §5.7 wiring (Command ctor, AppMain, `coreCommandSpecs`, `CommandGroup`), with output pinned |
| R2-7 | Web picker has no data source | §5.8 `GET /api/machines` |
| R2-8 | `seal machine pin` probes instead of accepting a supplied key | §3.3 `--key-file`/`--fingerprint`, verified against the probe |
| R2-9 | `buildMachinePrompt` cannot produce `(linux, default)`/`(macos)` — no `os` field exists | §0.2 amendment: platform labels dropped |
| R2-10 | `buildAdoptionPrompt` cannot receive a machine name (`hkaAdopt :: SshConfig -> …`) | §3.4 named signature change |
| R2-11 | `machine_user` credential collision never noted | §5.9 |
| R2-12 | `TabLineField` union + `toHaveLength(5)` test not in inventory | §12 |
| R2-13 | §10's string obligations were prose, not rows | §5.5 + §10.2 |
| R2-14 | `MachineUnreachable` carries free `Text` — drift hazard | §5.4 typed payload |
| R2-15 | DW-10: when does a deleted machine fail — resume or first call? | §5.1 states it |

**Round 3** (Designer; Security and CTO did not report before this revision):

| # | Finding | Fix |
|---|---|---|
| R3-1 | Row 4's `RrLoopbackHost` was nullary, so the renderer could only hardcode `localhost` — wrong for `127.0.0.1`/`::1` | §2.2: `RrLoopbackHost !Text` carries the configured host |
| R3-2 | `2 ai seal-harness mac-mini` has no producer: `renderTab` emits `KindAi` (stock `Show`), and has 3 slots not 4 | §0.2 amendment 2: kind token dropped from the requirement; §5.6 rewritten |
| R3-3 | `buildMachinePrompt` took `[MachineName]`, but `local` is not a constructible `MachineName` and must be suppressible | §5.6: `Selectable = SelLocal | SelMachine !MachineName` |
| R3-4 | `opNameText` does not exist (`OpName` is a newtype) | §5.5 uses the field directly |

### 0.1 Declined (round 1, NEW REQUIREMENT)

`default` naming a missing machine boot-fatal; `[machines.local]` as a load
error; file-view machine badge. None implemented.

### 0.2 Operator-approved amendments to the frozen requirements

1. **The TUI prompt drops platform labels.** The requirements' example renders
   `2. linux-builder  (linux, default)` / `3. mac-mini  (macos)`, but
   `machines.toml` has no `os` field and the requirements' own TOML example does
   not define one — so those labels have no data source. Operator decision: omit
   them rather than add a field. The rendered prompt becomes:

   ```text
   execution machine [default: linux-builder]:
     1. local          (this machine)
     2. linux-builder  (default)
     3. mac-mini
   > 3
   ```

   The `(default)` marker is retained; `(this machine)` is retained for `local`.
2. **`seal machine pin` accepts supplied key material.** §3.3.

## 1. Problem & approach

Today exactly one SSH target is resolved at boot into one `SessionExec`
(`UIOEnv` + `WorkdirFs` + `WorkspaceRoot`), memoized per session. Untrusted
opcodes never see a backend: they call `uio*` functions that read one
`UntrustedIO` from the `ReaderT` environment.

This change introduces N named machines and makes the target a **per-call**
input:

> **The untrusted execution target stops being a wiring-time constant and becomes
> an explicit argument on the `uio*` surface.**

### 1.1 Invariants that must not change

Each has a test in §10.

- **ACK-before-execute**, and the record names the machine (§6.5).
- **Fail-closed** — no fallback to another machine, none to `local`.
- **`allow_localhost = false` ⇒ no local untrusted execution**, enforced in the
  selector; in hardened builds also by the CPP gate on the local wiring path —
  **not** by absence of the executor (§13.3).
- **Type-guaranteed argv sanitization** — a model-supplied machine name is a
  smart-constructed newtype, never raw `Text` into `ssh` argv.
- **`~/.seal` is agent-immutable.**
- **Capability scoping** — `MachineRouting` never readable from opcode land.

## 2. Configuration

### 2.1 `machines.toml`

`spHome </> "machines.toml"`, mode `0600`, boot-only, no opcode surface. Seeded by
`Seal.Config.Templates` under its never-overwrite invariant.

**The shipped template has every machine table commented out and no live
`default`**, mirroring `config/templates/security.toml:46-58`. A live example
machine plus `default` would give a fresh install two selectable machines, a
mandatory prompt, and a default pointing at `builder.example.com` — the opposite
of Done-when 3.

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
`UntrustedExecRemoteFileConfig` codec record; all other records use strict fields.

### 2.2 Validation

```haskell
data MachineRegistry = MachineRegistry
  { regMachines :: !(Map MachineName MachineTarget)
  , regRejected :: !(Map MachineName RejectReason)
  , regDefault  :: !(Maybe MachineName)
  }

data MachineTarget = MtLocal | MtSsh !SshConfig   -- name lives in the map key
```

Pure, so testable without boot:

1. Validate each table: `mkMachineName`, then field checks. Missing
   `host`/`user`/`workspace` → `RrMissingField Host|User|Workspace`; `port`
   outside `1..65535` → `RrInvalidPort`.
2. **Loopback guard ordered before host validation**, so a loopback host yields
   `RrLoopbackHost host` (it carries the configured host, so the rendered text
   names what the operator actually wrote — `127.0.0.1` renders as `127.0.0.1`,
   not a hardcoded `localhost`) and the "is this machine" text rather than `mkSshHost`'s
   generic "invalid characters". (`mkSshHost` already rejects `:`
   at `Types.hs:133`, so `::1` never reached the old check — the ordering is what
   makes the message right.)
3. `local` is injected as `MtLocal` iff `allow_localhost`. A `[machines.local]`
   table is **ignored with a boot warning** (declined as an error, §0.1), but
   `mkMachineName` rejects the reserved name so it cannot be shadowed.
4. `regDefault` is `mcDefault` when it names a resolved machine; otherwise a
   **logged warning with no pre-selection**.

`mkMachineName`: ASCII alphanumerics plus `-`/`_`/`.`; reject leading `-`,
leading `.`, bare `.`/`..`, length > 64, and the reserved `local`.

### 2.3 `allow_localhost` replaces `mode`

```haskell
data UntrustedExecFileConfig = UntrustedExecFileConfig
  { uefcAllowLocalhost :: !Bool }
```

`UntrustedExecRemoteFileConfig` is deleted; its role moves here.

**Two absences must be distinguished:** a *whole section* absent ⇒ `True` (today's
behaviour, the frozen default); a section **present without `allow_localhost`** ⇒
`Left`. Otherwise a failed migration silently downgrades a remote-only install to
local.

`UntrustedExecMode` survives (the selector's input; `enforceRemoteOnly` needs it),
derived not read:

```haskell
untrustedExecConfigFromSecurity :: SecurityConfig -> UntrustedExecConfig
data UntrustedExecConfig = UntrustedExecConfig { uecMode :: !UntrustedExecMode }
```

A Bool also closes a silent-coercion hole: `resolveByMode` (`Security.hs:767`)
currently maps anything not literally `"remote"` to `UemLocal`, so a typo quietly
permits local execution.

## 3. Host keys

`scKnownHosts :: FilePath` **stays in `SshConfig`**; revision 1 said it was
removed *and* "always built with that path", which left three pure argv builders
(`Remote.hs:98`, `:135`, `AgentMetaCache.hs:191`) with no `SealPaths` in scope.

The requirement is **config-file level** — no operator-supplied path in any
config file — satisfied by filling the field at one construction site:

```haskell
execKnownHostsPath :: SealPaths -> FilePath
execKnownHostsPath paths = spHome paths </> "exec-known-hosts"
```

A **strengthening**: today's operator path reaches unquoted shell interpolation
(`… >> <path>` at `FileExplorer.hs:215`, `Workdir.hs:216`). Quoting stays anyway.

### 3.1 One pin file is not trust conflation

`ssh -o UserKnownHostsFile=<one file> -o StrictHostKeyChecking=yes` keys entries
by hostname (or `[host]:port`); strict checking consults only the matching entry.
Per-host isolation is ssh's, not the file split's. `ssh-keyscan` keying for
non-22 ports is a **test obligation** (T-HK-PORT), not a risk note — a mismatch
strands adoption entries fail-closed.

### 3.2 Self-key guard, corrected

Revision 1 put this inside `HostKeyAdoption`, which runs only on the
`ExecHostKeyUnknown` branch (`Workdir.hs:194-215`), so an already-pinned machine
never probed; and it read `~/.ssh/ssh_host_*_key.pub`, when sshd keys live in
`/etc/ssh/`. Three layers:

1. **Resolution-based loopback refusal at connect (primary, not skippable).**
   Resolve the host with `getaddrinfo` before first connection; refuse if **any**
   resolved address is loopback, unspecified, or a local interface address.
   Catches `mybox.lan`, `/etc/hosts` aliases, `127.1`, hex forms.
2. **String check at config load** (§2.2 rule 2) — fast, good message.
3. **Self-key comparison at connect (best-effort).** Compare the presented key
   against the harness's own sshd keys, read from `/etc/ssh/ssh_host_*_key.pub`
   (configurable). Unreadable ⇒ skipped, degrading from two defences to one.

### 3.3 `seal machine pin` — accepts supplied key material

Requirements: "may be pre-pinned non-interactively by supplying its key, for
scripted installs." A probe-plus-`--yes` flow is scripted TOFU, which auto-approves
whatever answers — strictly weaker, in exactly the unattended case the requirement
carves out. Corrected:

```text
seal machine pin <name> --key-file <path>      # known_hosts line(s) supplied
seal machine pin <name> --fingerprint SHA256:… # expected fingerprint
seal machine pin <name>                        # interactive probe + confirm
```

With `--key-file`/`--fingerprint` the host is probed and the result **verified
against the supplied material**; a mismatch is a hard failure. `--yes` alone never
appends an unverified key. The command:
- validates `<name>` with `mkMachineName`;
- errors if `<name>` is absent from `machines.toml`;
- is idempotent when the key is already pinned;
- never bypasses the loopback refusal of §3.2 layer 1;
- is a human-driven admin path (like `seal access-control`), never an opcode.

### 3.4 `buildAdoptionPrompt` gains the machine name

Revision 2 said it "gains the machine name" without a signature, and the only
caller is `hkaAdopt :: SshConfig -> IO (Either Text ())`
(`HostKeyAdoption.hs:72-77`) — no name in scope, and §2.2 keeps `MtSsh`
name-free. Named change:

```haskell
-- before
buildAdoptionPrompt :: HostKeyInfo -> Text
hkaAdopt            :: SshConfig -> IO (Either Text ())

-- after
data HostKeyInfo = HostKeyInfo { hkiMachine :: Maybe MachineName, … }
buildAdoptionPrompt :: HostKeyInfo -> Text
hkaAdopt :: MachineName -> SshConfig -> IO (Either Text ())
```

Callers updated: `Seal.Session.Workdir.hs:194-215`, `mkSessionExec`,
`rtResolve`. The prompt's exact copy (with the two-space indent and the `key:  `
padding that aligns values) is pinned by T-STR-7.

## 4. Migration

`Seal.Config.Migrate` gains `migrateExecutionMachines`, following its existing
rules (strip only after a successful write; new file wins except where it has no
answer; never strip what was not moved).

| On disk | Action |
|---|---|
| no `[untrusted_execution]`, no `machines.toml` | write commented template; `allow_localhost` stays absent ⇒ `True` |
| `mode="remote"` + complete remote block | write `[machines.default]`; **drop `known_hosts`**; `default = "default"`; `allow_localhost = false`; strip old table |
| `mode="remote"` + incomplete block | `allow_localhost = false`; **no** machine written; log loudly — a half-populated machine would trip `default` resolution |
| `mode="local"` or absent | `allow_localhost = true`; strip `mode` if present |
| `machines.toml` exists | it wins; only the strip happens |

### 4.1 A failed migration must not downgrade a remote-only install

`Migrate` is fail-open (`Migrate.hs:65`). The dangerous post-failure state:
`security.toml` still holds `mode="remote"` + its remote block (ignored by the new
codec) and `allow_localhost` is absent ⇒ `True`. A remote-only install silently
becomes local-execution.

Fixed by §2.3's decode rule: a *present* section without `allow_localhost` is a
decode error, so the failed-migration state is a visible boot error naming the
file. T-MIG-5 asserts this.

## 5. Session machine selection

```haskell
  , smMachine     :: Maybe MachineName    -- Nothing on pre-existing sessions
  , smRepoMachine :: Maybe MachineName    -- provenance for §6.6 (§12 inventory)
```

`session.json` compatibility verified: `FromJSON` already uses `.:?`/`.!=`
(`Meta.hs:113-128`) and unknown keys are ignored both directions.

### 5.1 `machineForSession` — ordered checks

Revision 1 consulted only `regMachines`, making `MachineUnusable` unreachable and
reporting a *misconfigured* machine with the *deleted*-machine text. Revision 2
then collapsed `Nothing`+no-default into `MachineDefaultUnset`, which consumed the
only state that could produce the requirements' `allow_localhost is false and no
execution machine is configured` text — leaving `NoMachineSelected` orphaned.
Corrected, ordered:

| # | State | Result |
|---|---|---|
| 1 | `Just n`, `n ∈ regMachines` | that target |
| 2 | `Just n`, `n ∈ regRejected` | `MachineUnusable n reason` |
| 3 | `Just "local"`, `allow_localhost = false` | `MachineNotPermitted "local"` |
| 4 | `Just n`, otherwise | `MachineGone n` |
| 5a | `Nothing`, `regDefault = Just d` | `d` |
| 5b | `Nothing`, no default, `allow_localhost = false`, `regMachines` empty | `NoMachineSelected` |
| 5c | `Nothing`, no default, otherwise | `MachineDefaultUnset` |

**When the failure surfaces:** `machineForSession` runs at the start of every
turn and every dispatch. A session whose machine is gone therefore **resumes
successfully and surfaces the error on its first untrusted call** — the session is
still readable, `Trusted` opcodes still work, and the `SHELL_EXEC failed:` render
is where the operator meets it. Stated here because the requirements do not
specify timing.

### 5.2 `MachineError`

```haskell
data MachineError
  = MachineUnknown !Text ![MachineName]      -- requested + valid choices
  | MachineUnusable !MachineName !RejectReason
  | MachineGone !MachineName
  | MachineNotPermitted !MachineName
  | MachineDefaultUnset
  | NoMachineSelected
  | MachineUnreachable !MachineName !UnreachableReason
  | MachineHostKeyChanged !MachineName       -- §5.4 mapping

data RejectReason
  = RrMissingField !MissingField | RrLoopbackHost !Text
  | RrInvalidHost !Text | RrInvalidWorkspace !Text | RrInvalidPort

data UnreachableReason = UrConnectFailed | UrBootstrapFailed | UrHostKeyUnknown
```

`MachineUnreachable` and `MachineHostKeyChanged` carry **typed** payloads, not
free `Text` — free text is exactly where the host-key and unreachable strings
would drift, the argument §2.2 makes for typing `RejectReason`.

Justification for a bespoke ADT (AGENTS.md: only when pattern-matched to drive
control flow): call sites dispatch on it, and `MachineUnknown` must carry the
valid-choices payload. *Not* the weaker "renders different messages" argument
revision 1 used.

### 5.3 How the choice reaches the session

- **TUI** — prompt when `regMachines` has ≥2 entries; none at 1. Rendered by
  `buildMachinePrompt` (§5.6), not `formatQuestionWithOptions`.
- **Web** — `NewTabComposer` picker at ≥2, defaulted, fed by `GET /api/machines`
  (§5.8).
- **Chat channels** — no prompt; `regDefault`; if unset, `ASK_HUMAN` with the list.
- **`/new -x`/`--machine`** — §5.9.
- Resuming uses `smMachine`; a legacy session displays its **resolved** machine.

### 5.4 Rendering: two seams, typed, no free text

Revision 1 claimed "one seam only" and then could not produce two of the
requirements' strings, because they are not opcode errors at all. Corrected: two
typed seams, each with a fixed input type.

```haskell
-- Opcode/execution-side (has the OpName)
renderMachineError :: OpName -> MachineError -> Text

-- Config/boot-side (no OpName; emits the "machines.toml: " prefix)
renderMachineConfigError :: MachineName -> RejectReason -> Text
```

The host-key-changed string is produced by a **typed mapping**, not by free text:

```haskell
execErrorToMachineError :: MachineName -> ExecError -> MachineError
  -- ExecHostKeyMismatch  -> MachineHostKeyChanged name
  -- ExecHostKeyUnknown   -> MachineUnreachable name UrHostKeyUnknown
  -- ExecRemoteUnreachable-> MachineUnreachable name UrConnectFailed
```

Applied at the resolve/bootstrap boundary (`rtResolve`, §6.1), so the
changed-key case reaches `renderMachineError` and can name the machine.

### 5.5 The requirement strings: enumerated, with producers

Round 2 demanded this replace prose. Nine rows; each is a `T-STR-*` obligation
asserting **exact equality** in §10.2.

| # | Frozen text | Producer | Producer's type |
|---|---|---|---|
| 1 | `SHELL_EXEC failed: unknown execution machine "macbook". Selectable machines: local, linux-builder, mac-mini.` | `renderMachineError` ← `MachineUnknown` | `OpName -> MachineError -> Text` |
| 2 | `SHELL_EXEC failed: execution machine "mac-mini" is unusable: workspace not configured. Fix it in ~/.seal/machines.toml.` | `renderMachineError` ← `MachineUnusable` | ditto |
| 3 | `SHELL_EXEC failed: host key for "mac-mini" does not match the key recorded in ~/.seal/exec-known-hosts. This can mean the machine was rebuilt, or that something is intercepting the connection. Seal will not connect. If the machine was rebuilt, remove its entry from that file and confirm the new key.` | `renderMachineError` ← `MachineHostKeyChanged` ← `execErrorToMachineError` | ditto |
| 4 | `machines.toml: machine "builder" is unusable: host "localhost" is this machine. A remote execution machine must be a separate machine.` | `renderMachineConfigError` ← `RrLoopbackHost` | `MachineName -> RejectReason -> Text` |
| 5 | `SHELL_EXEC failed: this session runs on execution machine "mac-mini", which is no longer configured. Resuming it on another machine would run its work somewhere it never ran. Add "mac-mini" back to ~/.seal/machines.toml, or start a new session.` | `renderMachineError` ← `MachineGone` | `OpName -> MachineError -> Text` |
| 6 | `SHELL_EXEC failed: allow_localhost is false and no execution machine is configured. Add one under [machines.<name>] in ~/.seal/machines.toml.` | `renderMachineError` ← `NoMachineSelected` | ditto |
| 7 | `machine "mac-mini" is not yet known.` / `  host: mac-mini.lan` / `  key:  ssh-ed25519 SHA256:9xQ…7fA` / `Trust this key? [y/N]` | `buildAdoptionPrompt` ← `HostKeyInfo` (§3.4) | `HostKeyInfo -> Text` |
| 8 | `execution machine [default: linux-builder]:` + 3 numbered lines + `> 3` (**amended** — no platform labels, §0.2) | `buildMachinePrompt` | `[Selectable] -> Maybe MachineName -> Text` (§5.6) |
| 9 | `session: anthropic / claude-opus-4-8  machine: mac-mini` | `Seal.Channel/Cli.hs:188` banner | `SessionMeta -> Text` |
| 10 | `2  seal-harness  mac-mini` (**amended** — kind token dropped, §0.2 amendment 2) | `renderTab` (`Cli.hs:461`) | `Tab -> Text` |
| 11 | `selectable: local, linux-builder, mac-mini` / `default:    linux-builder` / `unusable:   builder (workspace not configured)` | `/machine list` (§5.7) | `MachineRegistry -> Text` |

Two further literals in the requirements are **not** producer output and are
recorded here so their absence is a decision, not an omission: the model's own
call echo `SHELL_EXEC  {"command": …, "machine": …}` (the transcript renders the
model's argument; no harness message is produced) and the `y` the user types in
the key prompt (user input, not rendered).

**Line wrapping.** Several frozen strings are hard-wrapped across lines in the
requirements for width. The wrap is prose formatting, not part of the string; the
`T-STR-*` assertions compare the joined single-line form.

**The separator is ` failed: `** — revision 2 wrote `"<OP>: failed: "`, which
emits `SHELL_EXEC: failed:`. Frozen text is `SHELL_EXEC failed:`.

```haskell
renderMachineError op err = opNameText op <> " failed: " <> body err
-- NB: OpName is `newtype OpName Text` (no opNameText helper exists); use the
-- field accessor the repo already uses, or `\(OpName n) -> n`.
```

The repo's `<OPNAME>: <msg>` convention is the reason a new renderer is
justified, not licence to alter a frozen string.

**Model-facing vs operator-facing.** A model-facing message may name the machine
and nothing else about it. `MachineUnusable` therefore renders as
`workspace not configured` (for `RrMissingField Workspace`) — never
`host "localhost"`, which would leak coordinates the requirements forbid. The
operator-only `renderMachineConfigError` may render `RejectReason` fully; that is
why it is typed.

### 5.6 Display: four surfaces

**Correction to rounds 1–3.** Rounds 1 and 2 assumed the requirements'
`2  ai  seal-harness  mac-mini` was `renderSessionLine` and argued about dropping
`provider/model`. Revision 3 correctly re-attributed it to `renderTab`
(`Cli.hs:461-463`) but then wrongly concluded "nothing needs dropping" — because
`renderTab` is `<index>  <kind>  <label>` (three slots) and renders `kind` via
`T.pack (show (tKind t))` over a stock-derived `Show` (`TabTypes` at
`src-gateway-types/Seal/Gateway/Types/Tab.hs:62-64`), so it emits `KindAi`, never
`ai`. Four tokens, and no producer of a bare `ai` token exists anywhere.

Resolved by **amending the requirements** (§0.2 amendment 2): the kind token is
dropped, so the entry is `2  seal-harness  mac-mini` — index, label, machine
(label already carries the repo name). The TUI tab line renders
`<index>  KindAi  <label>  <machine>`; the `KindAi` token is pre-existing output
and out of scope to relabel.

| Surface | File | Change |
|---|---|---|
| TUI tab line | `Seal/Channel/Cli.hs:461` (`renderTab`) | label carries the machine |
| TUI `/session list` | `Seal/Command/Session.hs:71` (`renderSessionLine`) | add a machine column |
| TUI startup banner | `Seal/Channel/Cli.hs:188` | append `  machine: <name>` |
| Web sidebar row | `frontend/src/types.ts` (`SessionInfo`), `Sidebar.tsx:66-140`, `lib/tabLineConfig.ts` | `machine` field + `TabLineField` member + `tabLineConfig.ts` arrays |
| Web session JSON | `Seal/Gateway/SessionJson.hs:81` (`sessionInfoJson`) | `"machine"` field, resolved name (never `null` on upgrade) |

`buildMachinePrompt` cannot take `[MachineName]`: `local` is not a constructible
`MachineName` (`mkMachineName` rejects the reserved name, §2.2), and the renderer
must suppress the `local` row entirely when `allow_localhost = false`. Taking a
`[MachineName]` would force it either to hardcode a row it cannot suppress, or to
offer a machine `MachineNotPermitted` then rejects. So the selectable set is its
own type:

```haskell
data Selectable = SelLocal | SelMachine !MachineName

buildMachinePrompt :: [Selectable] -> Maybe MachineName -> Text
```

`SelLocal` renders `1. local          (this machine)`; a `SelMachine` equal to the
default renders `(default)`. Platform labels are dropped per §0.2. `Selectable` is
also what `GET /api/machines` (§5.8) and the web picker consume, so the two
surfaces cannot disagree about whether `local` is offered.

### 5.7 New command surfaces, and their wiring

Round 2: both were prose with no wiring. Registered explicitly.

`/machine list` (`Seal.Command.Machine`, `GroupGeneral`):
- `CommandSpec` added to `coreCommandSpecs` (`Command/Registry.hs:112`);
- `CommandGroup` reuses `GroupGeneral` — **no new group**, so `HelpSpec`'s
  group-ordering invariants are untouched (a new constructor would renumber
  `deriving Enum` and break them);
- output pinned by T-STR-10:

  ```text
  selectable: local, linux-builder, mac-mini
  default:    linux-builder
  unusable:   builder (workspace not configured)
  ```

  `unusable:` is omitted when nothing is rejected; `default:` is omitted when
  unset. This is also the DW-1 listing surface.

`seal machine pin` (§3.3):
- `CommandMachine MachineAction` constructor in `Seal/Types/Command.hs`
  (`pCommand` currently has exactly `tui|serve|access-control|gen-openapi`);
- dispatch branch in `AppMain.hs:45-54`;
- **entry in `reorderGlobalArgs`' subcommand list (`AppMain.hs:99-105`)**, or
  `--log-level` hoisting silently breaks for the new subcommand.

All three files, plus `HelpSpec`, are added to §9's Changed list and to W16.

### 5.8 Web picker data source

`GET /api/machines` returns the selectable list plus the default — **names and
rejection reasons only**, never host/user/path:

```json
{ "selectable": ["local", "linux-builder", "mac-mini"],
  "default": "linux-builder",
  "unusable": [{ "name": "builder", "reason": "workspace not configured" }] }
```

`NewTabComposer` fetches it the way it already fetches `/api/providers`. A new
endpoint rather than widening an existing one: machine state is boot-only and
security-relevant, and `/api/providers` is already large.

### 5.9 `/new -x`, and the `machine_user` collision

`NewArgs.naMachine :: Maybe Text` — `Text`, not `MachineName`: `src-gateway-types`
is a separate cabal library with no dependency on the main library. Validated at
the main-library boundary.

Both parsers must agree — the shared `parseNewArgs` **and** a fifth optparse flag
in `Seal.Command.New` — or `/new -x` silently does nothing on the CLI. T-STR-11
asserts they produce equal `NewArgs`. `-x` is free (`-p`/`-m`/`-r`/`-b` taken).
An unknown or unusable machine **fails at `/new` time** with the valid choices,
before a session is minted.

**Vocabulary note.** `machine_user` is an existing, unrelated **repo credential
kind** (a bot account: `SourceControl/Repo.hs:156-173`,
`Command/Repo.hs:148-167`). It is not an execution machine. Flag help text for
`-x`/`--machine` and the `machines.toml` template wording must not read as
related to `--cred machine_user`. `local` is the harness machine, so "machine" in
`MachineTarget` sometimes denotes the harness itself — the two-plane split
requires the prose keep those distinguishable.

## 6. The per-call seam

### 6.1 Routing is a resolver in `UIOEnv`

Revision 1 put a mutable `Map MachineName UntrustedIO` in `UIOEnv`; that is
unrepresentable (immutable records; `SessionExecCache` is keyed by `SessionId` and
unreachable from a `UIO` action). The mutable cell lives in `SessionExec`:

```haskell
-- Seal.Tools.Exec.Machine — constructor and fields NOT exported
data MachineRouting = MachineRouting
  { rtResolve    :: MachineName -> IO (Either MachineError UntrustedIO)
  , rtSession    :: MachineName
  , rtSelectable :: [MachineName]
  }

data MachineSlot = SlotReady !UntrustedIO | SlotFailed !MachineError
-- SessionExec owns: IORef (Map MachineName MachineSlot)
```

`rtResolve`: `SlotReady` → return; `SlotFailed` → return the memoized error (a
dead machine costs **one** SSH attempt per session, not one per call); absent →
bootstrap, insert with `modifyIORef'`, return. In-flight bootstraps are deduped
per machine.

Lazy is required, not merely preferred: the requirements put "machine health
checking / pre-flight probing" out of scope and say reachability is discovered on
first use.

`uieUntrustedIO` is **deleted** — once `withTarget` exists it is an escape hatch
that lets a future opcode bypass machine selection. Its last reader
(`cloneRepoIO`, `Repo.hs:90-91`) migrates to `withTarget`.

### 6.2 `ExecTarget` and `withTarget`

```haskell
newtype ExecTarget = ExecTarget MachineName   -- constructor NOT exported

withTarget :: ExecTarget -> (UntrustedIO -> IO a) -> UIO (Either MachineError a)
```

Generalized to `IO a` so it fits `cloneRepoIO`'s `IO CloneResult`.

Honest guarantee: **"some target was named"**, not "the caller chose it" —
`sessionMachine` wraps `rtSession` unvalidated, correct per the requirements but
weaker than revision 1 claimed.

Failure branches return a `MachineError` naming the machine, never
`ExecNotImplementedReason` (revision 1's `Nothing` branch made a lookup miss
indistinguishable from a stubbed backend).

### 6.3 Resolution lives in the `UIO` surface

The round-1 compile error: opcode bodies are `UIO` (no `MonadReader`/`MonadIO`),
and `CapabilityScopingWorkdirFsFailSpec.hs:53` fails the build if any
`src/Seal/ISA/Ops/` module imports `UIO.Internal`.

```haskell
-- Seal.Tools.Exec.UIO (opcodes import this legally)
uioResolveTarget :: Maybe Text -> UIO (Either MachineError ExecTarget)
sessionTarget    :: UIO ExecTarget

-- Seal.ISA.Ops.Machine (pure only)
machineField :: Value -> Maybe Text
machineSchemaProp :: [MachineName] -> Value
renderMachineError :: OpName -> MachineError -> Text
```

`MachineRouting`'s constructor/fields are unexported; only `mkMachineRouting`
(for `mkSessionExec`) and the `UIO` functions above. T-CAP is a grep/compile-fail
obligation.

One source of truth per lifetime: the **schema enum** from `regMachines` (static,
names only); **resolution** from the `UIO` env (dynamic, handles). The registry
builder receives `[MachineName]`, never live handles. `buildSessionRegistry`
already runs per turn (`TurnEngine.hs:279`, `:747`, `:1136`), so no caching change.

### 6.4 Opcode input

The eight untrusted opcodes gain an optional `machine` property, parsed by
`machineField`, resolved by `uioResolveTarget`. `Nothing` → session machine;
`Just t` → validated/looked up; unknown becomes a tool error naming valid choices
**before any `uio*` call**. `Seal.ISA.Opcode`'s GADT is unchanged.

`machineField` in a shared module is a mild break from the per-field local-helper
convention (`commandField`, `pathField`), justified by 8 consumers.

**Excluded opcodes**, with reasons stated so the omission reads as a decision:
- `BROWSER_MANAGE` — `agent-browser` session state is not per-machine. Its
  `uoDesc` gains "always runs on the session machine".
- `WEB_FETCH`/`WEB_SEARCH` — in-process today (§13.1). Their `uoDesc` gains the
  same note, because a model that has just used `machine` on `SHELL_EXEC` will
  otherwise infer that `machine` controls egress.

### 6.5 The ACK record names the machine

`mkInvocationEntry` (`Dispatch.hs:146-161`) writes `erMeta = {op, input}`
**before** `uoRun`, and untrusted opcodes' `orRecorded` is never persisted (only
`SKILL_LOAD`/`SETUP_REPO` get a `result` entry). So revision 1's plan changed
nothing observable.

Corrected: resolution happens **in `dispatch`, before `itwRecordAndAck`**, and the
resolved name is stamped into the invocation entry:

```haskell
resolved <- resolveMachineForCall uioEnv name input   -- no execution, no SSH
entry    <- liftIO (mkInvocationEntryWithMachine name input resolved)
liftIO (itwRecordAndAck h …)                          -- ACK, now naming the machine
```

Strengthens ACK-before-execute: the record still precedes execution and now
records the machine that will actually be used. The recorded name is the resolved
target, so it cannot diverge from what executes. `erMeta` gains `"machine"` only
for untrusted opcodes; requirement's "name and nothing else" holds.

`resolveMachineForCall` needs only the registry sets and the session machine — no
built handle — so no SSH pre-ACK.

### 6.6 `SETUP_REPO` on a non-session machine — supported, scoped

Operator decision. When `machine ≠ session machine`:
- the clone runs on the named machine;
- **no** agent auto-bind, **no** session workdir re-scan, **no** cache
  invalidation (all three read the session machine's `wfs`/`wsRoot`, so they
  would re-scan A after cloning to B and bind from the wrong tree);
- `smRepoMachine` records provenance; the invocation entry names B (§6.5);
- the result text states that relative paths on follow-up `FILE_*` resolve on the
  **session** machine, not the clone machine — otherwise a successful clone
  followed by a not-found read reads as a harness bug;
- relative `FILE_*` on B works; on A it returns not-found (the requirements'
  stated out-of-scope behaviour).

### 6.7 File explorer

`mkRemoteFileExplorer` is built once at boot from a single `SshConfig`
(`Serve.hs:677`). Decision: **session-machine-only**, following the session's
resolved machine. Per-request machine selection would change user-facing behaviour
(the declined badge, §0.1). Same for `handleSessionWorkdir` (`API.hs:1710`).

## 7. Workdirs, discovery, caching

### 7.1 Per-machine workdirs

`SessionExec` keeps `seUIOEnv`/`seWorkdirFs`/`seWorkspaceRoot` as the **session
machine's** (existing callers keep their meaning) and gains the resolver and slot
`IORef`. The session machine bootstraps before the first turn; others lazily via
`rtResolve`, memoized including failures.

`ExecCache`'s fingerprint is `(resolved registry, session machine)`: any
`machines.toml` edit rebuilds (the fingerprint *is* the resolved set — revision 1
contradicted itself by also claiming a one-machine change would not), as does a
session-machine change. Lazily added handles are excluded: runtime state, not
config.

`mkTestUIOEnv` keeps its arity by defaulting to a singleton routing whose only
machine is the session machine wrapping the supplied handle — preserving behaviour
for 109 call sites across 24 files and keeping W2 green.

### 7.2 Discovery

`cachedWorkdirScan` stays keyed on the **session machine's** workdir. Defs and
skills are repo-local; per-machine agent/skill state is out of scope; scanning N
workdirs would surface N divergent catalogs. A model on another machine sees that
machine's files via `FILE_*`/`SEARCH_FILES`.

### 7.3 WorkdirFs

Affected: `WorkdirFs.hs:418` calls `runUIOWithEnv uioEnv (uioShellExec cmd Nothing)`,
so a leading `ExecTarget` breaks it. One line: `sessionTarget`. Revision 1 claimed
it "keeps working unmodified" — semantics, not signature.

## 8. Where `local` and the flag are enforced

1. **Resolution** — `local` absent from `regMachines` when `allow_localhost =
   false`.
2. **Selector** (corrected — revision 1's table refused *every* remote machine
   under the default, because `uecMode` is `UemLocal` exactly when
   `allow_localhost = true`):

   | target | `UemLocal` | `UemRemote` |
   |---|---|---|
   | `MtLocal` | `EbLocal` | `Left ExecLocalNotPermittedForUntrusted` |
   | `MtSsh c` | `EbRemote c` | `EbRemote c` |

   Property: `MtLocal` + flag false is never `EbLocal`; `MtSsh` is never `EbLocal`.
3. **Build** — `-f remote-only-untrusted` rejects `allow_localhost = true` at
   startup via `enforceRemoteOnly`, which **now has a call site**. This is a
   wiring-level CPP gate plus a config check, **not** an artifact property,
   because `mkLocalUntrustedIO` is compiled unconditionally (§13.3).

## 9. Module inventory

**New:** `Seal/Config/Machines.hs`; `Seal/Tools/Exec/Machine.hs`;
`Seal/Session/Machine.hs` (not `Config.Machines` — `Config` must not depend on
`Session.Meta`, a leaf); `Seal/ISA/Ops/Machine.hs`; `Seal/Command/Machine.hs`;
`config/templates/machines.toml`.

**Changed:** `Seal.Config.Security`; `Seal.Config.Paths`; `Seal.Config.Templates`;
`Seal.Config.Migrate`; `Seal.Tools.Exec.Untrusted`; `Seal.Tools.Exec.UIO{,.Internal}`;
`Seal.Tools.Exec.WorkdirFs`; `Seal.Tools.Exec.FileExplorer`;
`Seal.Tools.Exec.HostKeyAdoption` (signature, §3.4);
`Seal.Session.{Workdir,ExecCache,Meta,AgentMetaCache}`;
`Seal.Command.{Serve,New,Session,Machine,Registry}`;
`Seal.Channel.Cli`; `Seal.Gateway.{API,Send,SessionJson}`;
`Seal.Core.TurnEngine`; `Seal.Types.Command`; `Seal.AppMain`;
the 6 untrusted opcode modules / 8 opcodes / ~25 call sites;
`src-gateway-types/.../NewArgs.hs`; `frontend/src/{types.ts,
components/{NewTabComposer,Sidebar}.tsx, lib/tabLineConfig.ts,
hooks/useNewTabSpec.ts}`; `config/templates/security.toml`; `CHANGELOG.md`;
`Makefile` + `.github/workflows/{ci,gate}.yml`.

## 10. Test obligations

### 10.1 Done-when matrix

| DW | Design | Test | RED assertion |
|---|---|---|---|
| 1 | §2.2, §5.7 | `MachinesSpec` | registry lists machines; `/machine list` exact output (T-STR-10) |
| 2 | §4 | `MigrateSpec` | T-MIG-1: remote table → `[machines.default]`, flag false, block gone |
| 3 | §2.1, §4 | `TemplatesSpec` | T-TPL-1: template install ⇒ exactly 1 selectable, no prompt |
| 4 | §2.2, §8 | `MachinesSpec`, `UntrustedSpec` | T-LOCAL: flag false ⇒ `local` absent; `MtLocal` never `EbLocal` |
| 5 | §2.2, §3.2 | `MachinesSpec`, `MachineConnectSpec` | T-LOOP: loopback rejected; resolved-loopback refused; self-key refused |
| 6 | §3.1, §3.3 | `HostKeyAdoptionSpec` | T-HK: prompt once / refuse without human / never adopt changed; T-HK-PORT; T-PIN-* |
| 7 | §5.3, §5.6 | `MachinePromptSpec` | T-STR-8; ≥2 prompts, empty → default, 1 does not |
| 8 | §5.8 | `NewTabComposer.test.tsx` | picker hidden at 1, defaulted at ≥2, fed by `/api/machines` |
| 9 | §5.1 | `MachineSpec`, `ExecCacheSpec` | T-RESUME: session on A resumes on A after `default`→B |
| 10 | §5.1 | `MachineSpec` | T-GONE: deleted ⇒ `MachineGone`, no fallback; surfaces at first untrusted call |
| 11 | §6.1–6.4 | `MachinesSpec`, `UIOSpec` | T-TWO: call on A then B, each machine's **own** counter |
| 12 | §6.4 | `MachinesSpec` | T-NOSTICKY: omitted ⇒ session machine every time |
| 13 | §5.5 | `MachineSpec` | T-STR-1; **zero** counters increment |
| 14 | §6.5 | `DispatchSpec` | T-ACK: `erMeta.machine` = resolved name, written **before** execution |
| 15 | §9, W14 | `Makefile`/CI | gate step builds + tests with `-f remote-only-untrusted` |

### 10.2 String obligations — one per row of §5.5

`T-STR-1` … `T-STR-9` assert **exact equality** against the frozen literals in
§5.5, including the separator. `T-STR-10` pins `/machine list` output and
`T-STR-11` pins `/new -x` parser agreement. Per round 2, the ill-posed "TUI and web
renderers agree" test is dropped: the tab line is TUI-only. Replaced by
`T-STR-12`, which asserts `sessionInfoJson`'s `machine` equals the name embedded in
`renderTab`'s label for the same session (a shared projection, both of which
actually emit).

### 10.3 Non-vacuity

- `T-NOFALLBACK`: for a resolvable target, **exactly one** counter increments and
  it is the resolved one; for each error case **every** counter stays at zero and
  the error names the valid choices. (Revision 1's "at most one" was satisfied by
  zero — the very regression under test.)
- `T-RESOLVE`: `checkCoverage` with `cover 20%` for `MtLocal` and `MtSsh` samples.

## 11. Work units

| WU | Content | Green boundary |
|---|---|---|
| W1 | `Config.Machines` + `MachineName` + resolution + `RejectReason` | new specs; nothing existing touched |
| W2 | `ExecTarget`/`MachineRouting`/`MachineSlot`/`MachineError`; `mkTestUIOEnv` singleton default | compiles; suite green |
| W3 | 12 `uio*` signatures + `withTarget` + `WorkdirFs` + `uioUntrustedIO` removal + `Repo` | mechanical, ~289 sites |
| W4 | 8 opcodes: `machine` input, `uioResolveTarget`, schema enum, `renderMachineError`, descs | opcode specs |
| W5 | `SessionExec` resolver + slot `IORef` + lazy bootstrap + `ExecCache` re-key | workdir/cache specs |
| W6 | `allow_localhost` + delete remote config + selectors + `enforceRemoteOnly` call site | config/selector specs |
| W7 | `machines.toml` codec + commented template + `Paths` | `MachinesSpec`, `TemplatesSpec` |
| W8 | Migration (5 rows + failure row) | `MigrateSpec` |
| W9 | `smMachine`/`smRepoMachine` + `machineForSession` + `renderMachineConfigError` | `MachineSpec` |
| W10 | Session selection: TUI prompt, `/new -x`, `NewArgs`, web picker + `/api/machines` | `MachinePromptSpec`, vitest |
| W11 | Display: 5 surfaces (§5.6) incl. `tabLineConfig` union | T-STR-8/9/12 |
| W12 | §6.5 ACK stamping | `DispatchSpec` |
| W13 | §6.6 `SETUP_REPO` scoped semantics | `RepoSpec` |
| W14 | `-f remote-only-untrusted`: fix unconditional `Local` import, Makefile, CI | CI green with flag |
| W15 | `renderExecError` → `execErrorToMachineError` mapping (§5.4) | T-STR-3 |
| W16 | `/machine list` + `seal machine pin` wiring (§5.7) | `CommandMachineSpec`, `HelpSpec` |
| W17 | `CHANGELOG`, `templates/security.toml` copy | — |

W3 is the only unit that cannot be split further: `ExecTarget` is unconstructible
until `UIOEnv` carries the routing, so the signature change is atomic. Sized from
call sites (§12), not opcode count.

## 12. Counted breaking-change inventory

| Change | src | test |
|---|---|---|
| `scKnownHosts` (kept — no change) | 0 | 0 |
| `mkTestUIOEnv` arity (preserved by W2) | 0 | 0 |
| `uio*` call sites | 132 | 157 |
| `untrustedExecConfigFromSecurity` loses `Maybe` | 10 | 8 |
| `uefcRemote`/`UntrustedExecRemoteFileConfig` deleted | 7 | 14 |
| 8 opcode constructor sites | — | ~115 across 13 files |
| `SshConfig` record construction | — | 14 |
| `hkaAdopt`/`buildAdoptionPrompt` signature (§3.4) | 3 | 4 |
| `TabLineField` union + `toHaveLength(5)` assert | — | 1 file, 2 asserts |

Also omitted from earlier inventories and now included:
`Seal.Tools.Exec.FileExplorer`, `Command/Serve.hs:677`, `AgentMetaCache`'s
`MetaCacheEnv` (`TurnEngine.hs:655` pattern-matches the old config and needs the
registry as its `SshConfig` source), `Types/Command.hs`, `AppMain.hs`,
`Command/Registry.hs`, `HelpSpec`, `config/templates/security.toml:44-59`.

`session.json` compatibility: additive and tolerant, verified (§5).

## 13. Pre-existing defects this design stops relying on

Filed separately; one line each because the design touches them.

1. **`WEB_FETCH`/`WEB_SEARCH` are labelled Untrusted but run in-process** via
   `uioLiftIO`. They never traverse SSH, so "egress originates on the untrusted
   plane" is not true today. Not machine-selectable here.
2. **`enforceRemoteOnly` has zero call sites** in `src/` (definition
   `Untrusted.hs:50`, export `:19`; callers only in two test files). Its docstring
   calls it "the startup check"; it does not run. W6 wires it.
3. **`-f remote-only-untrusted` does not omit the local executor.**
   `UntrustedIO.hs:79` imports `Seal.Tools.Exec.Local` unconditionally while the
   flag removes it from `exposed-modules`, so the hardened build very likely fails
   to compile today. And the flag omits only `mkLocalExecHandle` (called by nothing
   but a placeholder, `Untrusted.hs:113`); the real executor
   `mkLocalUntrustedIO` is compiled regardless. W14 fixes the import; a true
   artifact property is a separate project.
4. **`renderExecError` produces generic copy** where the requirements pin exact
   text (§5.4) — pre-existing, changed here because the requirements demand it.

## 14. Risks

- **Breadth** — 17 work units, ~289 `uio*` call sites, 6 opcode modules / 8
  opcodes.
- **Lazy bootstrap adds state** — explicit resolver, memoized failures, per-machine
  dedupe; a second call must not re-bootstrap.
- **Schema growth** — a machine `enum` on 8 tools per turn. Accepted;
  `registryToolDefs'`'s stub mode is the lever.
- **Two config files can disagree** — `allow_localhost` in `security.toml`,
  machines in `machines.toml`. The resolver takes the flag as a parameter; §2.3's
  decode rule prevents a silent downgrade.

## 15. Open questions — resolved

1. **Name charset** — ASCII alphanumerics plus `-`/`_`/`.`; cap 64; reject leading
   `-`, leading `.`, bare `.`/`..`, reserved `local` (§2.2).
2. **Lazy vs eager** — lazy, because pre-flight probing is out of scope (§6.1).
3. **Eviction** — none: `UntrustedIO` holds no socket (the connection is the ssh
   ControlMaster's, `ControlPersist=600`); eviction frees bytes and costs a
   `mkdir -p` round trip.
4. **Deleted-machine timing** — surfaces at the first untrusted call, not at
   resume (§5.1).
5. **`/machine list` as the boot listing** — yes; it is the DW-1 surface (§5.7).
