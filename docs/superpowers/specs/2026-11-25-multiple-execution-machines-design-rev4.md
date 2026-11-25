# Multiple execution machines — revision 4

Status: **draft, awaiting design review gate.**
Supersedes `2026-11-23-multiple-execution-machines-design.md` (rev 3c).
Date: 2026-11-25. Branch: `exec/multiple-machines`. Issue: #348.

## Why this revision exists

Rev 3c is approved but its plan has never passed a review gate: three attempts, fifteen
reviewer spawns, **zero verdicts** (see `…-plan.md` §A.1). The plan was split into two
milestones and still did not pass. The failure was diagnosed as *plan size*, and the fix
was a split. **That diagnosis was wrong.**

The real cause is design scope. Rev 3c spends most of its length on a single consequence
of one decision: moving `mode` out of `security.toml` and replacing it with `allow_local`.
That decision creates one hole (a machine definition whose `host` denotes the harness box),
and closing that hole is D6, D7, D8, D11a, and §3.1 of both plans — self-host detection,
a bypass-string table, two new opaque path types, an explorer fail-closed rule, four
rejected security designs, and a destructive migration. The design says so itself:

> *"This reframing opens exactly one hole, and closing it is most of the work."*

Revision 4 does not close the hole. **It declines to open it.** `mode` stays. The machine
inventory holds SSH targets only, so nothing in `execution.toml` can express local
execution and the hole cannot be dug.

Everything below follows from that. The deliverable is mostly a deletion list.

### What this revision deletes, by decision

| Design decision | Status in rev 4 | Why it existed |
|---|---|---|
| D2 — `security.toml` keeps only `allow_local` | **Deleted.** `mode` unchanged. | Root decision |
| D4a / D5 — `TargetNoDefault`, refusal rows | **Deleted.** One config-load error when ambiguous | Followed from D2 |
| D6 — self-host detection, `SelfIdentity`, §0.3 | **Deleted entirely** | Closing the D2 hole |
| D7 — `WorkspaceRoot'` opaque type | **Deleted.** Reuse existing validators | Closing the D2 hole |
| D8 — `KeyFilePath` opaque type | **Deleted.** Reuse existing validators | Closing the D2 hole |
| D10 — re-pin gated to refused sessions (409) | **Simplified** to a human-only `/machine` | Followed from D2 |
| D11a — `PUT .../machine`, `execRefusal`, `GET .../workdir?machine` | **Deleted** | Followed from D2 |
| D13 — refusal-message copy set | **Reduced** to two messages | Followed from D2 |
| D14 — four `*IsRemote` audits | **Deleted** as a unit; folded into WU-5 | Followed from D2 |
| §0.2 C5 — three rejected `mkSessionExec` designs | **Deleted.** No bridge needed | Followed from D2 |
| §0.3 — non-vacuous `selfIdentityFrom` refinement | **Deleted** with D6 | Closing the D2 hole |
| §3.1 — the four-route security regression | **Deleted.** Unconstructible | Followed from D2 |
| C9 — documented deviation from D9 | **Deleted.** No deviation needed | Followed from D2 |
| `-F /dev/null -o ProxyCommand=none` (old WU-1c) | **Deleted** with D6 | Closing the D2 hole |
| Milestone B — 7 units, 822 lines, destructive cutover | **Deleted entirely** | Followed from D2 |
| `security.toml` → `execution.toml` migration | **Deleted.** No migration at all | Followed from D2 |
| D12 — port range check | **Kept** (pre-existing latent bug, 3 lines) | Independent |

Consequences worth stating plainly:

- **No migration.** An existing install with `[untrusted_execution] mode = "remote"` and no
  `execution.toml` behaves **byte-identically**. No file is created on upgrade.
- **Issue #347 stops being load-bearing.** `mode`'s `localModeResult` coercion
  (`Security.hs:796-802`) is the working runtime backstop, and this feature does not
  remove it. #347 remains a real artifact-property bug, out of scope, and this design
  neither depends on nor worsens it.
- **The file explorer's posture is unchanged.** Under `mode = "local"` the explorer browses
  the harness box — exactly what it does today. The rev-3c "confidentiality consequence"
  and its fail-closed-explorer rule evaporate.
- **One milestone.** Eight additive units. Nothing is deleted from the product.

### A correction to rev 3c's own reasoning

Rev 3c's D11 asserts a *structural* security requirement:

> `mkSessionExec` and `cachedSessionExec` must take a `ResolvedTarget`/`Where`, **not** a
> `SecurityConfig`. A local arm then cannot be constructed without a `WhereLocal` in hand.

**The first half is right and rev 4 adopts it. The justification is overstated, and the
second sentence is false.**

Measured. `WorkspaceRoot` confinement is *not* performed by the opcodes — it is performed
inside `UntrustedIO`, which captures its own root at construction:

- `mkLocalUntrustedIO :: WorkspaceRoot -> UntrustedIO` (`UntrustedIO.hs:254`) —
  `mkSafePathAllowAbs wsRoot rel` per call (`:330`, `:350`)
- `mkRemoteUntrustedIOFromRunner :: SshConfig -> RemoteRunner -> UntrustedIO` (`:609`) —
  `mkSafePathRemoteAllowAbs (wsRootFromCfg sshCfg) rel` per call (`:623`, `:637`)

Of the six untrusted opcodes that take a `WorkspaceRoot`, **five ignore it**:

```haskell
fileReadOp    _root   operatorCeiling = UntrustedOpcode    -- File.hs:142
fileWriteOp   _root   operatorWriteCeiling = ...           -- File.hs:236
filePatchOp   _root   = ...                                -- File.hs:323
shellExecOp   _wsRoot policy = ...                         -- Shell.hs:48
searchFilesOp _wsRoot policy maxResults = ...              -- Search.hs:33
processManageOp _wsRoot policy = ...                       -- Process.hs:25
```

Only `binExecOp` uses it, and only to validate `cwd` relative to the root
(`Bin.hs:404,424`).

So a mismatch between the registry's root and the `UntrustedIO`'s root produces a
**refusal asymmetry** (an absolute `cwd` accepted by the opcode but re-confined-and-refused
by the executor), **not an escape**. Passing a `SecurityConfig` into `mkSessionExec` is bad
because it *re-derives* the boundary in two places — a correctness and duplication problem
— not because it lets local execution be constructed without a `WhereLocal` in hand.

Rev 4 adopts the signature change on the real grounds (one derivation instead of eight) and
drops the false claim. This matters for the plan: the `WorkspaceRoot` thread does **not**
need to become per-target in v1, and nothing in v1 must touch it.

## Problem

Seal runs untrusted code on a remote machine, but exactly one, welded into `security.toml`:

```toml
# ~/.seal/security.toml
[untrusted_execution]
mode = "local"                       # local | remote
[untrusted_execution.remote]
host / user / port / identity / known_hosts / workspace
```

`resolveRemoteSsh` (`Security.hs:774`) yields a single `SshConfig`. That one value is
re-derived independently by **eight live call sites**:

| Site | Derives |
|---|---|
| `Channel/Cli.hs:158` | `isRemote` for `TurnDeps` |
| `Command/Serve.hs:538` | `isRemoteExec` for `SendDeps` |
| `Command/Serve.hs:677` | the boot-time file explorer |
| `Core/TurnEngine.hs:653` | `MetaCacheEnv` |
| `Core/TurnEngine.hs:669` | the debug-log reason string |
| `Session/ExecCache.hs:99` | `execFingerprint` |
| `Gateway/API.hs:1212` | `metaCacheEnvForApi` |
| `Gateway/API.hs:1710` | `GET /api/sessions/:id/workdir` |

(`Channel/Cli.hs:474` is a ninth, dead — `untrustedIOFromSecurity`, zero callers.)

**This scattering is the actual defect.** It is why `execFingerprint` fingerprints
`SecurityConfig` rather than the thing that decides where code runs — the bug D11
documents. A second machine is not a new concept to add; it is the input that exposes how
badly the current one is threaded.

### What is impossible today

1. **Two machines concurrently** — one global setting, shared by every session.
2. **Adding a machine without moving every existing session** — changing the one target
   moves all sessions at once.
3. **Telling the file explorer about a change without a restart** — built once at boot
   (`Serve.hs:677`). Note this is *not* fixed here; it is a non-goal (§Non-goals).

Honest framing: **one remote machine works today.** The gap is concurrency and per-session
choice, not remote execution.

## Goals

1. Define N execution machines in `execution.toml`; each session picks one at creation.
2. Persist the choice on the session; inheritance copies it.
3. Keep `mode` as the sole agent-immutable decision about local execution.
4. Collapse the eight re-derivations into **one** pure resolver.
5. Make the exec cache keyed by the resolved target, deleting `execFingerprint`.
6. Leave a shaped seam for per-tool-call machine selection. Build no routing.

## Non-goals

- **Local execution as a machine name.** A machine entry is an SSH target. `local` is not a
  name, and no inventory entry can resolve to `WhereLocal`. This single rule is why D6/D7/
  D8 do not exist in this revision.
- **Per-tool-call machine selection in v1.** Designed for (§7), not built.
- **Multiple machines within one turn in v1.**
- **Multi-machine file explorer.** The explorer is a boot-time handle on
  `ApiDeps.adFileExplorer` with ~96 references. v1 keeps it on the resolved target at boot.
  **This is a real limitation, stated as one**: a session pinned to `builder` gets an
  explorer showing whatever `mode` resolves to at boot, and the UI must say so when they
  differ. (Cheap, because `GET /api/sessions/:id/workdir` already computes both.)
- **Adding machines from the web UI.** Config file only.
- Per-machine vaults, policy, or OS-based routing.
- IPv6 SSH targets (`mkSshHost` rejects `:`, pre-existing).
- Fixing #347, #348, or the boot-time explorer.
- Cross-machine workdir anchoring (see §7 — it needs a transfer, a separate design).

## Design

### 1. `security.toml` is unchanged

```toml
[untrusted_execution]
mode = "local"                       # unchanged: local | remote
[untrusted_execution.remote]         # unchanged, and still authoritative for legacy installs
host = "..."
```

`UntrustedExecFileConfig`, `UntrustedExecMode`, `untrustedExecConfigFromSecurity`,
`resolveRemoteSsh`, `localModeResult` — **all unchanged.** The only edit in this file is
D12's port range check (§6).

### 2. `execution.toml` holds SSH machines and nothing else

```toml
# ~/.seal/config/execution.toml
default = "builder"                  # required when >= 2 machines; implied when exactly 1

[machines.builder]
host        = "builder.example.com"
user        = "seal"
port        = 22
identity    = "/home/you/.ssh/id_ed25519"
known_hosts = "/home/you/.ssh/known_hosts"
workspace   = "/srv/seal/workspace"
```

Top-level keys, matching `config.toml` and `security.toml` (neither wraps its contents in
a table named after the file).

**Every field is required except `port` and `identity`.** A partial machine is a config
error at load, not a fail-closed at call time — there is no reason to accept a machine
definition that can never be used.

**Why `config/` and not `~/.seal/`?** `~/.seal/` is agent-immutable and no opcode may read
or write it (AGENTS.md rule 3). `config/` is the version-controlled, operator- and
agent-writable tree. Putting provisioning data there is correct *because* a machine entry
confers no authority: it can only name an SSH target, and only `mode` can permit local
execution. Nothing an agent writes into `execution.toml` can move untrusted code onto the
harness kernel.

### 3. `ResolvedTarget` — the value that replaces re-derivation

```haskell
-- Seal.Execution.Types (pure; imports only Seal.Security.Path + Seal.Tools.Exec.Types)
newtype MachineName = MachineName Text
  deriving stock (Eq, Ord, Show)

mkMachineName :: Text -> Either Text MachineName
-- charset [A-Za-z0-9_-], non-empty, no leading '.', max 64 —
-- identical to isValidAgentDefId (Agent/Def/Types.hs:41-47), reused for consistency.

data ResolvedTarget
  = WhereLocal
  | WhereSsh MachineName SshConfig
  deriving stock (Eq, Show)
```

`MachineName` is a smart-constructed newtype for the Invariant-2 reason: this value reaches
a session file, an API body, and (in §7) a tool-call argument, and a raw `Text` must not.

### 4. Three invariants, each with a test

**I1 — `mode` is the only producer of `WhereLocal`.** No inventory entry can yield it,
because `SshMachineSpec` carries only validated SSH fields. Therefore *adding, removing, or
editing a machine can never move untrusted execution onto the harness kernel.* This is what
replaces D6, D7, D8 and the entire §3.1 regression analysis, and it is a property of the
type, not of a check.

**I2 — a pin never widens authority.** Rows 1–2 below only ever *add* an SSH target. They
never cause `mode` to be consulted differently, because `mode` has no say over any
`WhereSsh`. This is the rule §3.1 of the old plan generalised, and here it is trivially
true rather than guarded in four places.

**I3 — a pin is a request, not a resolution.** v1 persists the machine name the user asked
for, never the resolved `SshConfig`. Storing a resolution would freeze a fingerprint of
config that can change, which is D11's bug in a different position.

### 5. Resolution — one pure function, five rows

```haskell
resolveTarget
  :: ExecutionConfig       -- execution.toml
  -> SecurityConfig        -- security.toml, unchanged
  -> Maybe MachineName     -- the session pin
  -> Either TargetError ResolvedTarget
```

| # | Condition | Result |
|---|---|---|
| 1 | pin names a machine in the inventory | `WhereSsh name (sshConfigFromMachine spec)` |
| 2 | no pin, an effective `default` exists | `WhereSsh default …` |
| 3 | no pin, `mode = "remote"`, legacy `[untrusted_execution.remote]` complete | `WhereSsh "default" legacySsh` |
| 4 | no pin, not row 3 | `WhereLocal` |
| 5 | pin names an unknown machine; **or** row 3's legacy block is incomplete | `Left TargetError` |

Row 4 covers `mode = "local"` and the absent-section default ⇒ today's behaviour exactly.

**Row 3 invents the name `"default"` for the legacy block.** It exists only so a legacy
remote install has something to show in a UI and in a session file. It is *not* an
inventory entry. `mkMachineName` accepts it (it is charset-valid), so the reservation must
be explicit: **`default` is a reserved machine name, and declaring `[machines.default]` is
a config-load error.** That keeps row 3 unambiguous, and a test asserts the reservation.

**Effective `default`.** `execution.toml`'s `default` when present; when absent and the
inventory has exactly one machine, that machine; when absent and the inventory has ≥ 2
machines, a **config-load error** naming the machines. No `TargetNoDefault` constructor, no
refusal-at-call-time row — an ambiguous inventory is not a per-session condition.

**`resolveTarget` is pure and total.** Every branch is exercised by a table-driven spec.

### 6. Port validation (D12, kept)

`resolveRemoteSsh` does `fromMaybe 22 (uerfcPort r)` with no range check
(`Security.hs:780`). A latent pre-existing bug. `sshConfigFromMachine` validates `1..65535`
and so does `resolveRemoteSsh` after this change; tests cover `0` and `65536`.

### 7. The seam for per-tool-call selection (designed, not built)

Recorded so a reviewer can check v1 does not foreclose it. **Nothing here ships.**

The dispatch signature already carries the capability handle per call:

```haskell
dispatch :: Registry -> IndexedTranscriptHandle -> BackendExec -> UIOEnv
         -> ToolTimeoutConfig -> AbortFlag -> OpName -> Value
         -> App (Either DispatchError OpResult)
```

`UIOEnv` arrives as an argument, so "this one call goes elsewhere" is structurally within
reach. What per-tool-call additionally needs:

1. `machine` in every untrusted opcode's input schema — a shared schema-augmenting wrapper
   at registry-build time, one place.
2. A per-session **allowlist**, not just a default. The settled shape is
   `ExecSelection { esDefault, esAllowed }` with `esDefault ∈ esAllowed` by construction.
   The tool argument must be a member of `esAllowed`; a refusal names the available set.
   `mode` still means "no member of any allowlist may be `local`", because no member can be.
3. A per-target exec bundle cache keyed `(SessionId, ResolvedTarget)` — the same key v1
   introduces.
4. **A per-target session workdir.** `sessionWorkdir paths sid` and
   `remoteSessionWorkdirPath sshCfg sid` both key on the sid alone, so two machines mean two
   disjoint filesystems. `SETUP_REPO` is per-machine, and `dwdParentWorkdir`
   (`TurnEngine.hs:1295`) must mean "the parent's workdir *on the child's machine*" — which
   for a cross-machine child requires a transfer and is therefore a separate design.
5. The system prompt must state the current machine and that the filesystem is per-machine,
   or the model will confidently read a path it wrote elsewhere.
6. Approval prompts must display the target, since the operator approves a specific command
   on a specific box.

The security rationale for reversing D9's *"an agent must not choose a machine"* survives
for exactly one reason: **the inventory cannot express local execution**, so an
agent-chosen machine is always an agent-chosen *remote* machine — a place the operator has
already declared untrusted code may run. Under rev 3c's `allow_local` reframing this would
not be true. That is the strongest argument for §1.

`erMeta.machine` (WU-8) is what makes the falsification metric a `grep` over
`entries.jsonl` — actual use — rather than `session.json` — mere configuration.

### 8. SSH cost: already per-machine

`sshExecArgv` sets `ControlPath=~/.seal/ssh-mux/m-%C` where `%C` is ssh's hash of
`|local host|local port|remote host|remote port` (`Remote.hs:158-163`). Each target already
gets its own master connection. **Adding machines costs no multiplexing work.**
`-F /dev/null` (rev 3c's WU-1c) is deleted with D6.

### 9. Layering

`Seal.Execution.Types` imports only `Seal.Security.Path` and `Seal.Tools.Exec.Types`.
Verified: `Seal.Security.Path` imports **zero** `Seal.*` modules (only
`base`/`directory`/`filepath`/`text`/`unix`), so no cycle is constructible.
`Seal.Execution.Resolve` adds `Seal.Config.Execution`. Neither imports
`Seal.Config.Security` — the `SecurityConfig` argument to `resolveTarget` is passed in, and
`UntrustedExecConfig`/`SshConfig` come from `Seal.Tools.Exec.Untrusted`/`Types`.

## Work units

Eight units. Additive throughout. Order chosen so the demo lands at WU-6.

### WU-1 — `Seal.Execution.Types` (pure, no IO)

`MachineName` + `mkMachineName`; `SshMachineSpec` with validated newtypes
(`SmsHost :: SshHost`, `SmsUser :: SshUser`, `SmsPort :: Int`,
`SmsIdentity :: Maybe FilePath`, `SmsKnownHosts :: FilePath`,
`SmsWorkspace :: RemotePath`); `ResolvedTarget`; `TargetError`; and the one pure projection

```haskell
sshConfigFromMachine :: SshMachineSpec -> SshConfig   -- total; both sides validated
```

`identity`/`known_hosts` validation: absolute, no `..`, no `blockedNames` segment except
`.ssh` and `.seal` (which must be *allowed* here — they are where keys live). Reuses
`Seal.Security.Path.blockedNames`/`blockedSegment`; **no new opaque type.**

Cabal wiring in the same commit (a module in no stanza is never typechecked — measured in
the old plan's M2).

### WU-2 — `Seal.Execution.Resolve`

`ExecutionConfig` (inventory map + effective default); `resolveTarget` (§5, five rows);
`loadExecutionConfig :: SealPaths -> IO (Either Text ExecutionConfig)`;
`loadAndResolveTargetIO` (turns a load failure into `TargetError`).

### WU-3 — `execution.toml` codec + template

`Seal.Config.Execution` codec (`default` + `[machines.<name>]` via `Toml.tableMap`), with
`default` a reserved name (config-load error if declared), required fields, port range
(D12), and `MachineName` validation at decode. Plus `config/templates/execution.toml`
comment-only (nothing enabled by default — an empty inventory must stay the pre-existing
behaviour) and the `extra-source-files` entry.

### WU-4 — the per-session pin (the biggest diff)

`SessionMeta` gains `smExecMachine :: Maybe MachineName`. On-disk key `exec_machine`; wire
key `execMachine` in `sessionInfoJson`. **Tolerant decode**: invalid name dropped, matching
the existing "an inherited value that no longer validates is dropped" policy.

Measured cost: **77 `SessionMeta` construction sites across 25 files**
(`scripts/count-sessionmeta-sites.py`; baseline recorded in the plan). All in scope, and
the compiler finds them — which is why this unit is mechanical rather than risky.

`newSession`/`newSessionMeta` gain one argument. Measured: **101 call sites across 11
files** (`grep -rnE '\bnewSession(Meta)?[[:space:](]' --include=*.hs src test`). The 11
files are enumerated in the plan; the old plan shipped a *wrong* file list for this sweep
once and the omission did not compile.

**Inheritance**: `writeChildMeta` (`Worker.hs:404`), `writeHandoffMeta`
(`:518`), `fallbackMeta` (`TurnEngine.hs:1340`), `branchSession` (`Branch.hs:93`), and
`initSessionMeta` copy the parent's `smExecMachine` **value**.

**No opcode may set `smExecMachine`.** `SESSION_MANAGE action=new` and cron fires take the
effective default. D9's asymmetry is retained and is what makes I2 meaningful.

### WU-5 — collapse the eight derivations; delete `execFingerprint`

`mkSessionExec` and `cachedSessionExec` take `ResolvedTarget` instead of `SecurityConfig`.
`cachedSessionExec`'s memo key becomes `(SessionId, ResolvedTarget)`; **`execFingerprint` is
deleted**, not fixed. `mkSessionExec` has 3 call sites (`ExecCache.hs:113`,
`Workdir.hs:312`, `API.hs:1656`); `cachedSessionExec` has 16 (10 in `ExecCacheSpec`).

The eight sites in §Problem each call `loadAndResolveTargetIO` + `resolveTarget` with the
session's pin. `tdIsRemote`/`sdIsRemote`/`cdIsRemote` are derived from the resolved target
rather than from `mode`, so a pinned session gets the correct deploy-key clone path.

This unit is where the codebase gets *smaller*.

### WU-6 — `--machine` in both parsers ← **demo checkpoint**

`NewArgs` gains `machine :: Maybe MachineName`; `/new --machine builder` writes it.
`CreateTabBody` gains `machine?: string` (`frontend/src/hooks/useApi.ts:1021` — TypeScript
only; `handleTabNew` takes a raw `A.Value`). `handleTabNew`'s provider arm passes it to
`newSessionMeta`.

Validation at creation: an unknown machine is a `400` with the available set, because a
human is present to read it. This is the only place a refusal is user-facing in v1.

### WU-7 — `GET /api/machines` + the dropdown

Response: `{ "default": "builder", "machines": [{ "name", "default" }] }`. **No
`selectable`/`detail`** — with an SSH-only inventory every machine is selectable whenever
`mode` is anything, so those fields would be dead.

Route work is real and must be listed: a `SealRoute` constructor, `routeMeta`, `openApiMeta`
(both exhaustive `\case`, `-Wincomplete-patterns` under `-Werror`), and
`ApiRouteSpec.expectedRouteCount` 81 → 82.

`NewTabComposer.tsx` gets one `<select>`, rendered **only when the inventory has ≥ 2
machines**. A one-entry picker is noise, and this also covers the legacy `mode = "remote"`
install with no `execution.toml` (row 3's synthetic name never appears in a dropdown).

### WU-8 — `erMeta.machine`

`mkInvocationEntry` (`Dispatch.hs:146`) gains the target's name in `erMeta`. Two lines.
Makes the success criterion measurable from the transcript.

## Testing

TDD throughout. The properties worth QuickCheck:

| Property | Unit |
|---|---|
| `resolveTarget` row 4 ≡ today's `untrustedExecConfigFromSecurity` for every `SecurityConfig` | WU-2 |
| no `ExecutionConfig` value can produce `WhereLocal` unless `mode = "local"` (I1) | WU-2 |
| a pin at rows 1–2 never changes `WhereLocal`↔`WhereSsh` vs. the unpinned case (I2) | WU-2 |
| `exec_machine` round-trips; an invalid name decodes to `Nothing` | WU-4 |
| child/handoff/branch metas inherit the parent's pin exactly | WU-4 |
| `cachedSessionExec` rebuilds when the target changes, reuses when unchanged | WU-5 |
| a legacy `mode=remote` install with no `execution.toml` produces the same argv as before | WU-5 |

**The additivity tests, written first and passing on the unmodified tree.**
`mode = "remote"` + no `execution.toml` must yield a composed ssh argv byte-identical to
today's; and `mode = "local"` + no `execution.toml` must yield no ssh argv at all. If those
two do not pass before any change, the unit that breaks them is wrong.

## Success criteria

| Signal | Target | Observed by | Verdict if missed |
|---|---|---|---|
| Sessions pinned to a non-default machine | ≥ 1 within 2 weeks | `grep exec_machine ~/.seal/sessions/*/session.json` | Premise unvalidated — keep inventory + pin, drop the picker (WU-7) |
| Sessions moved by adding a machine | 0 | integration test + same grep before/after | A regression, not a feature |
| Machine visible without a click | shown in the chat header when it differs from `mode`'s | frontend test | UC-3 unimplemented |
| No legacy behaviour change | byte-identical config resolution and ssh argv | the two additivity tests | Additivity claim false |

## Risks

| Risk | Mitigation |
|---|---|
| An agent-written `execution.toml` redirects untrusted code to an attacker host | It already can: `SHELL_EXEC` runs `/bin/sh -c` as the same user. A machine entry adds no authority — `mode` still decides whether *this* kernel executes. Stated, not hidden. |
| A machine entry naming the harness box *is* local execution in disguise | **The one guarantee rev 4 gives up.** Under `mode = "local"` it is harmless (local execution is already permitted). Under `mode = "remote"` an entry whose `host` names this machine resolves to an SSH connection to itself, so untrusted code executes on the control-plane kernel — precisely the hole D6 existed to close. Accepted and documented, not hidden. Cheap to close if required: one pure check in `resolveTarget` comparing the resolved `SshHost` against the harness's own names (~40 lines + tests, inside WU-2, no new opaque types). It is stated plainly because a reader who assumes rev 4 removed D6 for free deserves to be contradicted. |
| A pinned machine is removed or renamed | Resolution returns `TargetError`; the session fails closed with a message naming the machine. Remedy is the human-only `/machine <name>` command. No 409 gating, no auto-repair. |
| The explorer shows the wrong machine | Named as a non-goal; the UI says so when `GET /api/sessions/:id/workdir`'s machine differs from the session's |

The second risk is the decision this revision asks of its reviewers, not one it can make
itself: **rev 3c spent most of its length closing that hole; rev 4 documents it instead.**
The asymmetry is deliberate — the hole requires the operator to have written an entry
naming their own machine into a file they control, while `SHELL_EXEC` already runs as that
same user. §7 notes that per-tool-call selection makes closing it *more* important, because
the model, not only the operator, would then be choosing among entries.

## Out of scope

Multi-machine explorer; per-tool-call routing (§7); multiple machines per turn; OS/load
routing; adding machines from the web UI; per-machine vaults; IPv6 targets; cross-machine
workdir anchoring; `seal exec-machine` CLI group; fixing #347/#348; the boot-time explorer.
