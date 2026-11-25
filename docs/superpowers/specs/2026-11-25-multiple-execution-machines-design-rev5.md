# Multiple execution machines — revision 5

Status: **draft, awaiting design review gate.**
Supersedes rev 4 (`…-design-rev4.md`) and rev 3c (`…-design.md`).
Date: 2026-11-25. Branch: `exec/multiple-machines`.

## Revision log — what changed from rev 4

Rev 4 kept `mode` and made the inventory SSH-only, to avoid opening rev 3c's
self-host hole. The gate found that reasoning unsound, and the fix is better than
either: **delete `mode` and replace it with `allow_localhost`.**

| Change | Why |
|---|---|
| **`mode` deleted.** `allow_localhost :: Bool` (default `true`) replaces it | One concept instead of two that could disagree. See §1 |
| **`allow_localhost` is enforced by refusing known-local targets**, not by inspecting intent | The user's framing: "completely prevent any tool call on localhost, 127.0.0.1, or any IP the local machine has" |
| **`local` becomes a pinnable, reserved machine name** | Without `mode`, a user with an inventory must still be able to put one session on the laptop and one on builder — the headline use case |
| `execution.toml` **stays in `~/.seal/config/`** (rev 4 said the same; my §2 argument justifying it was wrong and is corrected in §3) | Version-controlling the inventory is a *feature*: you want `builder` defined on every machine you set up. V8's rule protects *decisions* files, not provisioning data |
| **`-F /dev/null` restored** (rev 4 wrongly deleted it with D6) | It is not a D6 measure: without it a `Host *` stanza in `~/.ssh/config` re-points `Hostname`/`ProxyCommand`. Reproduced |
| **Leading-`-` rejection added to `mkSshHost`/`mkSshUser`** | Invariant-2 violation, reproduced as ssh option injection. Hardens the *existing* `security.toml` path too |
| **`exec_machine` decode is fail-closed**, not tolerant | Rev 4's tolerant decode silently re-targeted a session to the default. For a field deciding *where code executes* that is a silent authority change |
| Cache key gains `Ord`; `NewArgs` holds `Maybe Text`; §9 layering fixed; WU-2/WU-3 reordered; boot sites resolve unpinned | Verified gate findings, each with a reproduction |

**Deleted as no longer needed** (all of rev 4's list still applies, plus):

`UntrustedExecMode`, `resolveByMode`, `localModeResult`, `uefcMode`,
`untrustedExecConfigFromSecurity`'s mode branch, `mkSessionUntrustedIO` (zero
production callers; a standing bypass of the resolver this feature introduces),
rev 4's reserved-`default`-for-legacy row, and rev 4's claim that #347 is
load-bearing — see §1.4, which reverses it.

## 1. `security.toml`: one decision, not two

```toml
# ~/.seal/security.toml   (a SIBLING of config/, never in git — design V8)
[untrusted_execution]
allow_localhost = true            # default: true (today's behaviour)
```

`allow_localhost` answers exactly one question: **may untrusted code execute on
this kernel?** Not "where does it run" plus "may it run here" — one question, one
answer, no way for two settings to disagree.

### 1.1 The rule, stated once

> `WhereLocal` is reachable **only** when `allow_localhost = true`.

That single sentence replaces rev 3c/4's five-row table plus a cross-checked
invariant. A pin cannot reach it, a default cannot reach it, no inventory entry
can reach it. Everything else in this document follows.

### 1.2 `false` means: no tool call may touch this machine

`allow_localhost = false` is enforced by **refusing known-local targets** at
config load (§4). A machine entry that provably denotes this box is a load error
naming the offending machine. This is what makes the sentence in §1.1 true
rather than aspirational.

**Refuse only what we can prove.** A host we cannot classify — any DNS name,
CNAME, tailscale MagicDNS name, `mDNS` `.local` name, or this box's own FQDN —
is **allowed**. Refusing unknowns would break legitimate installs (a machine
whose name happens to resolve oddly) and Layer 1 cannot resolve DNS anyway. The
DNS-based circumvention this leaves open is stated as a known gap in §4.3 and is
pre-existing.

### 1.3 Default `true`

Today's behaviour is local execution. `true` is the honest default; `false` is
opt-in hardening. Shipping `false` would silently break every existing install,
which is worse than a default-open posture that is already default-open.

### 1.4 `-f remote-only-untrusted` re-couples here

This corrects rev 4. With `mode` gone, the compile-time coercion that currently
lives in `localModeResult` (`Security.hs:796-802`) has nowhere to go, so the
feature **owes** it: under `-DREMOTE_ONLY_UNTRUSTED`, `allow_localhost` is forced
`false`. ~5 CPP-guarded lines plus a test. Issue #347's separate
artifact-property gap (the module still compiles in) stays out of scope, but this
feature no longer gets to claim it is unaffected.

`enforceRemoteOnly` — currently definition-plus-two-tests with no production call
site — becomes expressible as `allow_localhost = false`, so it can be deleted or
re-pointed rather than left dead.

### 1.5 Legacy compatibility: presence, not `mode`

- A complete `[untrusted_execution.remote]` block is activated by **presence**,
  becoming an implicit machine named `default` (reserved; `[machines.default]` in
  `execution.toml` is a load error).
- If a `mode` key is present, `allow_localhost` is **derived** from it
  (`"remote"` ⇒ `false`, `"local"` ⇒ `true`) so a hardened install keeps its
  posture. An explicit `allow_localhost` wins over the derived value.
- **No file is ever rewritten. No migration.** `mode` is deprecated-with-read-compat
  and can be removed in a later release. One inert comment-only
  `config/templates/execution.toml` is seeded by `ensureConfigTemplates`; nothing
  in it is enabled, so behaviour is unchanged.

## 2. Problem

Seal runs untrusted code on a remote machine, but exactly one, welded into
`security.toml`. `resolveRemoteSsh` (`Security.hs:774`) yields a single
`SshConfig`, and that one value is **re-derived independently at eight live
sites**:

| Site | Derives |
|---|---|
| `Channel/Cli.hs:158` | `isRemote` for `TurnDeps` |
| `Command/Serve.hs:538` | `isRemoteExec` for `SendDeps` |
| `Command/Serve.hs:677` | the boot-time file explorer |
| `Core/TurnEngine.hs:653` | `MetaCacheEnv` |
| `Core/TurnEngine.hs:669` | a debug-log reason string |
| `Session/ExecCache.hs:99` | `execFingerprint` |
| `Gateway/API.hs:1212` | `metaCacheEnvForApi` |
| `Gateway/API.hs:1710` | `GET /api/sessions/:id/workdir` |

(`Channel/Cli.hs:474` is a ninth, dead — `untrustedIOFromSecurity`, zero callers.)

**This scattering is the actual defect.** It is why `execFingerprint` fingerprints
`SecurityConfig` rather than the value that decides where code runs
(`ExecCache.hs:98-109`) — a real, today-biting bug: editing a machine's host
changes nothing until restart, and a re-pinned session keeps serving its old exec.
A second machine is not a new concept to add; it is the input that exposes how
badly the current one is threaded. **WU-5 fixes that bug whether or not the
feature's premise is validated** — see §9.

### 2.1 Use cases

Two survive the simplification. Rev 3c had four; UC-2 was a constraint (now §1) and
UC-4's re-pin is deferred (§9).

- **UC-1 — concurrent per-session choice.** WHO a developer with a laptop and a
  Linux build box · WANTS a heavy compile session on the build box and a scratch
  session on the laptop concurrently · SO THAT builds finish without editing
  config and moving every session · WHEN starting a new session.
- **UC-3 — which machine is this?** WHO a developer working across architectures ·
  WANTS to see which machine a session runs on · SO THAT an arch-specific
  `cargo build` failure is diagnosable · WHEN reading the session list.

### 2.2 Evidence caveat (do not delete this again)

**This is an operator request, not a measured user pain. Treat UC-1 as an
assumption, and §9's two-week metric as its falsification.** Rev 4 dropped this
sentence; the gate correctly called that the most important line deleted.

## 3. `execution.toml` — SSH machines, in `config/`

```toml
# ~/.seal/config/execution.toml
default = "builder"                  # required when >= 2 machines; implied when exactly 1

[machines.builder]
host        = "builder.example.com"
user        = "seal"
port        = 22
identity    = "/home/you/.ssh/id_ed25519"      # optional (ssh-agent)
known_hosts = "/home/you/.ssh/known_hosts"
workspace   = "/srv/seal/workspace"
```

Single machine ⇒ `default` optional. No machines ⇒ the file is absent or
comment-only and §5 row 3 applies.

### 3.1 Why `config/` and not `~/.seal/` top level

Rev 4's §2 asked this on the premise that `config/` is *not* under `~/.seal/`. It
is (`Config/Paths.hs:88`, `spConfig = home </> "config"`). The right distinction
is not location but **purpose**, and the codebase already draws it:

```
config/repos.toml   provisioning data    git-versioned, in config/
security.toml       a security decision  sibling of config/, never in git
```

`securityFilePath`'s own comment states the rule: *"a SIBLING of `config/` (NOT
inside it) so the git-versioned config repo cannot resurrect a lower-security
version (design V8)."* What V8 defends is **a decisions file must not be
reconstructible from a git remote.** An inventory is not a decision — you *want*
it in your dotfiles so `builder` is defined everywhere. So:

| | Where | Git-versioned | Agent-writable |
|---|---|---|---|
| machine inventory | `config/execution.toml` | **yes, by design** | under `allow_localhost = true` only |
| `allow_localhost` | `security.toml` | no | no |

And that is sufficient, because under `allow_localhost = false` the agent cannot
reach the inventory at all: `FILE_WRITE` rejects any `.seal` segment
(`Path.hs:333`) and `SHELL_EXEC` runs on the remote box. Under `true` it can write
it, but local execution is already permitted, so pointing an entry at this box
gains nothing. The residual — a cloned repo carrying `host = "localhost"` — is
exactly what §4's load-time check refuses.

### 3.2 Field validation

| Field | Rule |
|---|---|
| machine name | `MachineName`: `[A-Za-z0-9_-]`, non-empty, no leading `.`, ≤ 64. Rejects leading `-`. `local` and `default` are reserved |
| `host` | `mkSshHost` **plus a leading-`-` rejection** (§6.2) |
| `user` | `mkSshUser` **plus a leading-`-` rejection** |
| `port` | `1..65535` (D12: `fromMaybe 22` has no range check today, `Security.hs:780`) |
| `identity`, `known_hosts` | absolute, no `..`, no `blockedNames` segment **except** `.ssh`/`.seal`; **no whitespace, no `=`** (§6.2) |
| `workspace` | `mkRemotePath` (rejects empty, leading `-`, control chars) |
| unknown keys | **decided**: a warning at load, not an error — a typo'd `identiy` silently defaulting to ssh-agent is the failure this catches |

## 4. Localhost protection

### 4.1 Layer 1 — address check, at config load (v1)

`localAddressNames` already exists and is exactly the right primitive:

```haskell
-- Security/TlsCert.hs:222-232
localAddressNames :: IO [Text]
localAddressNamesWith :: IO [NetworkInterface] -> IO [Text]
  rendered iface = [T.pack (show (ipv4 iface)), T.pack (show (ipv6 iface))]
```

It emits **only** interface addresses — never `localhost`, never a hostname. So the
loopback literals must be added explicitly (they are load-bearing, not redundant),
and the `localAddressNamesWith` seam means a failed enumeration is a testable case.

Rejected set when `allow_localhost = false`:

- loopback literals: `localhost`, `localhost.`, `LOCALHOST`, `127.0.0.1`, `127.1`,
  `::1`, `[::1]`, `ip6-localhost`, `0.0.0.0`
- numeric re-encodings: `2130706433`, `0x7f000001`, `0177.0.0.1`
- the whole `127.0.0.0/8` block
- every address from `localAddressNames`
- the box's own `nodeName` and FQDN

All folded for case and a trailing dot. **IO at load, not at resolve time**:
`loadExecutionConfig` already returns `IO`, so `resolveTarget` stays pure and
total. A matched machine is a **config-load error** naming it.

**Not covered (stated, not hidden):** any DNS name resolving to this box. See §4.3.

### 4.2 Layer 2 — host-key identity, defeating port forwarding (deferred)

Layer 1 cannot see through a TCP tunnel: an entry with `host = "tunnel.example"`,
`port = 2222` forwarding to `localhost:22` presents a non-local hostname. Comparing
**host keys** catches it, because the box's real key is presented regardless of the
address used to reach it.

Design: probe the box's own addresses once (`ssh-keyscan`, `probeHostKey` and the
SHA256 fingerprint helper already exist at `HostKeyAdoption.hs:156,199`), collect
this machine's keys, then compare the presented key at connect. `HostKeyAdoption`
is the correct precedent — a `TurnDeps`-threaded capability no opcode can reach.

**Deferred to its own unit, because it is not cheap:** it needs boot-time IO, a
host-key capture point in the connect path (today `mkRealRemoteRunner` sees only
stderr and detects `ExecHostKeyMismatch` by string match, `Remote.hs:307-320`), and
a fail-**closed** policy when the probe cannot establish this box's keys (no sshd
running, firewall) — otherwise the protection silently disables itself.

**Boundary, stated so the doc does not overclaim:** this defends against a *machine
entry* tunnelled to this box. It does **not** defend against an agent running
`ssh -L`/`socat` inside `SHELL_EXEC`. That needs egress policy — a different
feature.

### 4.3 The known gap

DNS-based circumvention (an entry whose name resolves to this box) passes Layer 1
and is not caught until Layer 2. **This is pre-existing**:
`[untrusted_execution.remote] host = "<this box's tailscale name>"` under
`mode = "remote"` already ran untrusted code on the harness kernel before this
feature existed. The protection here is that `execution.toml` is human-authored and
git-audited, not a resolver pretending to enumerate a machine's identities.

## 5. Resolution

```haskell
-- Seal.Execution.Types (pure; imports Seal.Security.Path + Seal.Tools.Exec.Types only)
newtype MachineName = MachineName Text          -- smart constructor, unexported
data ResolvedTarget = WhereLocal | WhereSsh MachineName SshConfig
  deriving stock (Eq, Ord, Show)                -- Ord required for the cache key

data TargetError
  = TargetUnknownMachine  MachineName [MachineName]  -- requested, available
  | TargetLocalNotAllowed MachineName                -- allow_localhost = false
  | TargetConfigInvalid   Text                       -- load/validation failure
  deriving stock (Eq, Show)
```

A bespoke ADT because the program **branches** on it: `TargetUnknownMachine` names
the available set (a human reads it at creation), `TargetLocalNotAllowed` names the
setting to change. `TargetConfigInvalid` is the residual.

```haskell
resolveTarget
  :: ExecutionConfig          -- pre-filtered at load; localhost offenders already rejected
  -> Maybe UntrustedExecFileConfig   -- §9 layering: NOT SecurityConfig
  -> Maybe MachineName        -- the session pin
  -> Either TargetError ResolvedTarget
```

| # | Condition | Result |
|---|---|---|
| 1 | pin names a machine (incl. reserved `local` when `allow_localhost`) | `WhereSsh` / `WhereLocal` |
| 2 | else an effective `default` exists | same |
| 3 | else `allow_localhost = true` | `WhereLocal` |
| 4 | else | `Left TargetConfigInvalid` — nothing may run |

**`local` is a reserved, pinnable name**, present iff `allow_localhost = true`.
Without it a user with an inventory could never pin a session to the laptop, which
is half of UC-1. `[machines.local]` declared in the file is a load error (the
reserved name is the only way to express it).

**Effective `default`**: `execution.toml`'s `default`; when absent and the inventory
has exactly one machine, that machine; when absent with ≥ 2 machines, a config-load
error naming them. No `TargetNoDefault` constructor — an ambiguous inventory is not
a per-session condition.

**The pin is a request, not a resolution.** v1 persists the name the user asked for,
never an `SshConfig`. Storing a resolution freezes a fingerprint of mutable config,
which is D11's bug in a different position.

## 6. Fixes the gate verified against source

These are not new features; each is a defect in the current tree that this feature
would otherwise build on.

### 6.1 Fail-closed `exec_machine` decode

Rev 4 said "invalid name is dropped, matching the existing tolerant-decode policy".
**Wrong for this field.** If a pinned machine is renamed, the pin becomes `Nothing`,
resolution falls to row 2, and the session **silently moves** — a silent authority
change with no error, log, or prompt. Tolerant decode is right for cosmetic fields.
Here: a present-but-invalid `exec_machine` yields `Left TargetUnknownMachine`.

An **absent** key is `Nothing` = "no pin" and is normal (every legacy session).

### 6.2 Leading-`-` rejection in `mkSshHost`/`mkSshUser`

`Types.hs:117-141` reject control/space/colon but **not a leading `-`**, unlike
`mkRemotePath:164` and `mkContainerTarget:112`. `sshExecArgv` emits `user@host` as
one bare argv token with `--` only before the *command* (`Remote.hs:80-99`).
Reproduced:

```
$ ssh "-oProxyCommand=/bin/echo PWNED@host.invalid" -G x
proxycommand /bin/echo PWNED@host.invalid
```

AGENTS.md Invariant 2 requires smart constructors to reject leading-dash values.
Latent today because these fields live in agent-immutable `security.toml`; fixed
here because the inventory multiplies them. `identity`/`known_hosts` additionally
reject whitespace and `=` (a POSIX-legal path with a space is otherwise enough to
smuggle a second `-o` directive).

### 6.3 Restore `-F /dev/null`

Reproduced: a `Host *` stanza in `~/.ssh/config` sets `Hostname` and
`ProxyCommand`, so a machine entry does **not** fully determine its endpoint.
`-F /dev/null -o ProxyCommand=none -o ProxyJump=none` closes it. Rev 4 deleted
this with D6, which was a mistake — it is endpoint integrity, not self-host
detection.

### 6.4 Mux key collisions are silent

`ControlPath=…/m-%C`; `%C` hashes `|local host|local port|remote host|remote port|`
— **not** user, identity, or known_hosts (`Remote.hs:154-163`, and the comment says
so). Two entries with the same host/port but different `user` share one master, so
the second rides the first's authenticated connection. Unreachable today (one global
`SshConfig`); reachable the moment the inventory exists. Fix: add `%r` to the
ControlPath (one token) **or** reject duplicate `host:port` across machines at load.
Add a risk row either way.

### 6.5 Layering

`resolveTarget` takes `Maybe UntrustedExecFileConfig`, not `SecurityConfig` — naming
a type in a signature *is* importing it, so rev 4's "neither imports
`Seal.Config.Security`" was false. `Seal.Security.Path` imports zero `Seal.*`
modules (verified), so `Seal.Execution.Types` stays a leaf.

## 7. Work units

Nine units. Additive. Demo at WU-6.

### WU-1 — `Seal.Execution.Types` (pure)
`MachineName` (+ reserved `local`/`default`), `SshMachineSpec` (validated newtypes),
`ResolvedTarget` with `Ord`, `TargetError`, `sshConfigFromMachine :: SshMachineSpec
-> SshConfig` (total), `targetLabel :: ResolvedTarget -> Text`, and
`targetSshConfig :: ResolvedTarget -> Maybe SshConfig`. Cabal wiring in the same
commit (a module in no stanza is never typechecked). Prefixes `smsHost`/`smsUser`/…
to match `scHost`/`naProvider` style.

### WU-2 — `execution.toml` codec + `loadExecutionConfig`
`Seal.Config.Execution`: the codec (§3.2 validation, reserved names, duplicate
`host:port` rejection, unknown-key warning), `executionFilePath :: SealPaths ->
FilePath` added to `Seal.Config.Paths`, `loadExecutionConfig`, and a
comment-only template + `extra-source-files`. *(Moved ahead of the resolver — rev 4
had WU-2 depending on a codec that did not yet exist, so `make check` could not
pass.)*

### WU-3 — `Seal.Execution.Resolve`
`resolveTarget` (four rows, pure), `loadAndResolveTargetIO` (turns a load failure
into `TargetConfigInvalid`), and the §4.1 localhost predicate.

### WU-4 — the per-session pin
`SessionMeta` gains `smExecMachine :: Maybe MachineName`; key `exec_machine`, wire
`execMachine`. Fail-closed decode (§6.1). Tolerant `FromJSON` is **explicit**, not
derived, so absent ⇒ `Nothing` and invalid ⇒ a distinguished error.

Measured: **77 construction sites across 25 files**, split **73 test / 4 src**
(`scripts/count-sessionmeta-sites.py`). **No arity change to
`newSession`/`newSessionMeta`** — the field defaults to `Nothing` (= "take the
effective default"), so rev 4's ~100-edit positional sweep is avoided entirely. A
`setExecMachine :: MachineName -> SessionMeta -> SessionMeta` helper keeps the field
out of opcode-reachable construction.

Inheritance copies the parent's **value**: `writeChildMeta` (`Worker.hs:404`),
`writeHandoffMeta` (`:518`), `fallbackMeta` (`TurnEngine.hs:1340`), `initSessionMeta`,
and the branch handler (`API.hs:1317-1327` — *not* `branchSession`, whose own
haddock says it writes no `session.json`).

**No opcode may set `smExecMachine`.** Tested two ways: a grep asserting zero
occurrences under `src/Seal/ISA/Ops/`, and `SESSION_MANAGE action=new` with an extra
`machine` key resolving to the effective default.

### WU-5 — collapse the eight derivations; delete `execFingerprint`
`mkSessionExec`/`cachedSessionExec` take `ResolvedTarget`; the memo key becomes
`(SessionId, ResolvedTarget)` (needs `Ord`, §5); `execFingerprint` **deleted**;
`invalidateExec` drops all entries for the sid. `mkSessionUntrustedIO` **deleted**
(zero production callers, and it is a `SecurityConfig`-shaped bypass of the resolver
being introduced).

Boot sites (`Cli.hs:158`, `Serve.hs:538`, `Serve.hs:677`) have **no session** and
resolve **unpinned** (rows 2-4). The per-session remote-ness boolean moves *into the
turn* (`TurnEngine.hs:918`, `metaCacheEnvFor`) keyed off the session's pin —
otherwise a session pinned to `builder` under `allow_localhost = true` gets
`cdIsRemote = False` and the wrong clone path.

### WU-6 — `--machine` in both parsers ← **demo checkpoint**
`NewArgs` gains `naMachine :: Maybe Text` (**not** `MachineName`:
`seal-gateway-types` cannot depend on the main library). `/new --machine builder`
writes it; validation happens **before** the session is minted, via a new
`NewDeps` field supplying the inventory.

`parseNewArgs` **silently ignores unknown flags** (`NewArgs.hs:63`) and drops a
value-less `--machine` (`:57`), so a typo or missing value yields the default
machine invisibly. Fix: `--machine` with no value is an error, and its failure is
reported inline via `ccSend` with the available set (matching how `/new -r`
failures are already surfaced).

`CreateTabBody` gains `machine?: string` (`useApi.ts:1021`) — flat, matching
`branch_from`/`harness_id`. `createTab` currently **discards the response body** on
`!res.ok` (`:1046`), so a 400 is invisible; it must return `{ok:false, error}` like
`setupRepo` (`:1279`) and the composer must render it. `buildBody` **omits**
`machine` when no picker is shown, so an install with no `execution.toml` sends a
byte-identical body.

`renderNewSessionConfirmation` gains the machine name.

### WU-7 — `GET /api/machines` + the dropdown
`200 {default: string|null, machines: [{name, default}]}`. Degraded shapes are
**200, never 500**: absent `execution.toml` ⇒ `{default: null, machines: []}`; one
machine ⇒ one element. A malformed file must not break the New Tab form.

Route work: a `SealRoute` constructor, `routeMeta`, `openApiMeta` (both exhaustive
`\case` under `-Werror`), `ApiRouteSpec.expectedRouteCount` **81 → 82**.

`NewTabComposer.tsx`: one `<select>`, rendered only when `machines.length ≥ 2` and
`kind === 'provider'`; read-only in branch mode (the backend copies the parent's
pin). **Do not persist it in `LastOptions`** (`UiState.hs:57`) — `repoBranch` is
deliberately not persisted for the same class of reason.

### WU-8 — `erMeta.machine`
**Not two lines.** `dispatch` has a `UIOEnv`, which carries no machine name, so this
needs a third `UIOEnv` field (~60 `mkTestUIOEnv` call sites in tests) or a parallel
`mkTestUIOEnvWithMachine`. Say which in the plan; do not let it discover this. The
name only, never the resolved `SshConfig` (which would leak `identity`/`known_hosts`
paths into the transcript).

### WU-9 — session-viewer surface
`GET /api/sessions/:id/workdir` returns `{path, machine, explorer_machine}`
(`handleSessionWorkdir` currently returns `{path}` and derives it from `mode`, so it
must resolve the pin). `ChatArea.tsx` shows a badge when the session's machine
differs from the explorer's. This is what makes UC-3 observable — rev 4 promised it
in a success criterion with **no work unit**, which the gate correctly flagged.

## 8. Testing

TDD throughout. Properties worth QuickCheck, per unit:

| Unit | Tests |
|---|---|
| WU-1 | `mkMachineName` accepts iff charset-valid **and** not reserved; empty / leading `.` / leading `-` / 64 vs 65 / control chars; `sshConfigFromMachine` total and field-preserving; `mkSshHost`/`mkSshUser` reject leading `-` |
| WU-2 | codec round-trip; each required field missing ⇒ `Left` naming it; `[machines.local]`/`[machines.default]` ⇒ `Left`; invalid name as key ⇒ `Left`; port `0`/`65536`; duplicate `host:port` ⇒ `Left`; unknown key ⇒ warning not error |
| WU-3 | four-row table; row 3 ≡ today's behaviour for every `SecurityConfig`; **no inventory or pin can produce `WhereLocal` unless `allow_localhost`**; localhost literals + interface addresses rejected when `false`; a DNS name **allowed** (documented gap); enumeration failure ⇒ still rejects literals |
| WU-4 | `exec_machine` round-trips; **absent ⇒ `Nothing`; invalid ⇒ `TargetUnknownMachine`** (not `Nothing`); all five inheritance sites copy the value; `SESSION_MANAGE action=new` + `machine` key ⇒ default |
| WU-5 | **two sessions on two machines in one cache get distinct execs** (the headline feature); a target change rebuilds; an unchanged target reuses; `invalidateExec` clears all targets for the sid; a legacy `mode=remote` install with no `execution.toml` produces byte-identical argv |
| WU-6 | `--machine` parses; value-less `--machine` ⇒ error not silent; unknown machine ⇒ 400 whose body carries the available set; **no `session.json` minted on refusal**; web path sends an identical body when the picker is hidden |
| WU-7 | golden JSON; absent file ⇒ `{default:null, machines:[]}`; `local` appears iff `allow_localhost`; route count 82 as a test edit; `≥2` render rule |
| WU-8 | `erMeta.machine` present for a pinned untrusted call, and never contains an `SshConfig` |
| WU-9 | workdir response carries both machines; they differ ⇒ the badge condition is true |

**The additivity tests, written first, passing on the unmodified tree:** a legacy
`mode=remote` install with no `execution.toml` yields byte-identical ssh argv; and
a local install with no `execution.toml` yields no ssh argv at all.

## 9. Success criteria

| Signal | Target | Observed by | Verdict if missed |
|---|---|---|---|
| Sessions pinned to a non-default machine | rate ≥ 20% of sessions created since ship, with ≥ 10 created (else "insufficient data", not "pass") | `grep exec_machine ~/.seal/state/sessions/*/session.json` (honour `SEAL_HOME`) — path corrected: `sessionsRoot = spState </> "sessions"`, `Paths.hs:233` | **Keep the WU-5 fix** (a real today-biting bug); drop the inventory, pin, and picker |
| Two sessions on two machines, both executing | 1 observed | manual, at the demo | UC-1 unvalidated |
| Sessions moved by adding a machine | 0 | integration test + the same grep before/after | A regression, not a feature |
| Machine visible without a click | shown when it differs from the explorer's | WU-9 test | UC-3 unimplemented |
| No legacy behaviour change | byte-identical resolution + argv | the two additivity tests | Additivity claim false |

Criterion 1 measures **configuration**; `erMeta.machine` (WU-8) would measure
**use**, which is the better signal. Both are recorded; the *decision* rests on
criterion 1 because it is available earlier. This resolves rev 4's contradiction
between §9 and §7 rather than shipping both claims.

## 10. Risks

| Risk | Mitigation |
|---|---|
| An entry names this box under a DNS alias | §4.3 — pre-existing, not widened; Layer 2 closes it; `execution.toml` is human-authored and git-audited |
| A machine becomes unreachable mid-session | Every subsequent turn fail-closes with a message naming the machine; re-pinning is §11 |
| A removed/renamed machine strands a pinned session | Fail-closed decode (§6.1) + `TargetUnknownMachine` naming the machine. **Remedy: start a new session** — no `/machine` command in v1 (§11) |
| Two entries share a mux master | §6.4 fix, or duplicate-`host:port` load error |
| Two sessions on two machines share one exec cache | The key change is the mitigation; it has its own test |
| The explorer shows `default`'s machine | WU-9 surfaces the mismatch in the UI |

## 11. Out of scope

Layer 2 host-key protection (§4.2); per-tool-call routing; multiple machines per
turn; cross-machine workdir anchoring (v1 already gives two machines two disjoint
filesystems because the remote path roots at `scWorkspace` — only *anchoring a
child across machines* needs a transfer); OS/load routing; adding machines from the
web UI; per-machine vaults; IPv6 targets; a `/machine` re-pin command (remedy is a
new session); `seal exec-machine` CLI group; fixing #347's artifact property or
#348.
