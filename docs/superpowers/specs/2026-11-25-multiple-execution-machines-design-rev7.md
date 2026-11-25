# Multiple execution machines — revision 7

Status: **draft.** Round-3 gate returned 2/2 NEEDS_REVISION (security, CTO); all ten
blockers were text-level corrections and are applied below. Round 3 was the last
permitted iteration — rev 7 is presented to the human rather than re-gated.
Supersedes rev 6, rev 5, rev 4 and rev 3c. Date: 2026-11-25. Branch:
`exec/multiple-machines`.
## Revision log — what changed from rev 6

Round-3 gate returned NEEDS_REVISION from both reviewers. **Three of the ten
blockers were my own errors, verified against source:**

| Change | Why |
|---|---|
| **WU-4: the 75-site sweep is unavoidable, not eliminated** | I claimed "no arity change ⇒ ~100 edits avoided". False: `-Wmissing-fields` is part of `-Wall` (`seal-harness.cabal:33`, `-Werror`), so **every named-field `SessionMeta` literal breaks** the moment the field is added — all 75 (73 test / 4 src). Mitigation named: a `defaultSessionMeta`-based constructor so each site adds one line rather than re-listing 14 fields |
| **§6.4/§6.3: the ControlPath change is NOT invisible to the suite** | Rev 6 said "insertion is invisible to the assertions". True for *flag insertion*, false for the *ControlPath value*: `RemoteSpec.hs:236,241,242,247` compare it exactly (`checkAdjacentPair argv "ControlPath" (home </> ".seal/ssh-mux/m-%C")`) and `:252` asserts the `-m-%C` suffix. Those 5 assertions are part of the unit |
| **§6.1: fail-closed decode has no error channel** | `readSessionMeta :: IO (Maybe SessionMeta)` and `decodeFileStrict` collapse every parse failure to `Nothing` — and **30 call sites** depend on that type. Rev 6's own test ("invalid ⇒ `TargetUnknownMachine`, not `Nothing`") could not pass. Resolved by scoping: a *renamed* machine is already caught by §5 row 0, so only *malformed* text is in question, and for that, `Nothing` + a load-time warning is correct — making the whole `session.json` undecodable would render the session unreadable, which is worse than the silent move it prevents |
| **§5: inheritance fails closed instead of falling back** | Rev 6's "fall back to the default and warn" can land `WhereLocal`: `allow_localhost = true`, one ssh machine, no explicit `default`, session pinned to it, machine renamed ⇒ child falls to row 3 ⇒ **untrusted subagent code on the harness kernel** with only a warning. A dead pin is now a `TargetError`, full stop |
| **§1.4: the `-f remote-only-untrusted` coercion applies to the default, not just a present section** | Otherwise a hardened build with **no** `security.toml` keeps `allow_localhost = true` and yields `WhereLocal`. `mkLocalUntrustedIO` has no CPP guard, so this value is the only thing between the hardened build and local execution |
| **§3.1: the writability claim is corrected; `group` sanitisation added to WU-2** | `FILE_WRITE` is contained under `WorkspaceRoot`, so `~/.seal` is out of *its* reach — but `SKILL_WRITE`/`AGENT_DEF` write locally via `defPath`/`skillPath` with an unsanitised `group` (`Skills.hs:92-97`, `T.strip` only). `group = "../../.."` escapes. It cannot forge `execution.toml` **only because `.md` is unconditionally appended** — accidental, not designed. Sanitisation is now a WU-2 deliverable |
| **`selectExecBackend`/`selectUntrustedBackend` get an owner (WU-5)** | They branch on `UemLocal`/`UemRemote` (`Untrusted.hs:88-118`) and will not compile once `UntrustedExecMode` is deleted. Zero production callers (tests only), so no live hole — but they are a second, parallel authority-decider |
| **`ApiTestHarness` re-typing is costed in WU-5** | **32** test references to `UntrustedExecMode`/`UemLocal`/`UemRemote`, and `buildTestEnv :: FilePath -> UntrustedExecMode -> …` is the harness's spine (`:413`, `:496`, `:498`, `:542`). Until it is re-typed to `ResolvedTarget` + `execution.toml` fixtures, `mode` cannot be deleted at all |
| **`MachineName` derives `Ord`**; WU-2 owns the `Seal.Config.Security` edits | Both compile-level omissions. `mode` is `Toml.text` (required, `Security.hs:453`), so making it optional *is* a `Security.hs` edit |
| **`erMeta.machine` dropped; 8 units** | The doc itself says it is not the deciding metric. It is the largest churn item (92 sites, a third `UIOEnv` field) for no user-visible capability. Kept as a follow-up gated on criterion 1 being ambiguous. `erMeta.machine` remains the right *diagnostic*, just not v1 |
| **`renderTargetError` gets a §8 test row** | Rev 6's log claimed "all six strings pinned" while §8 had no cycle for the renderer |


## Revision log — what changed from rev 5

Round-2 gate: architect, designer and PM returned NEEDS_REVISION; security and CTO
timed out at the 600 s subagent wall. Twelve blockers, all text-level corrections
except two which are my own errors:

| Change | Why |
|---|---|
| **§6.4 rewritten: `%C` already includes the user; `identity`/`known_hosts` are the unhashed inputs** | I claimed the opposite. Reproduced: `ssh -G -o ControlPath=/tmp/cp-%C alice@…` and `… bob@…` give **different** hashes; `-i k1` and `-i k2` give the **same** hash. `%C = hash(%l%h%p%r%j)`. `Remote.hs:154-156`'s comment is stale and I inherited the error from it — fixed here too |
| **`Ord` added to `SshHost`, `SshUser`, `SshConfig`** (WU-1, named explicitly) | `ResolvedTarget`'s `deriving Ord` does not compile without them — all three derive `(Eq, Show)` only. Named because these edits land in `Seal.Tools.Exec.Types`, outside WU-1's file list |
| **§1.5 legacy activation gated on `mode`** | Presence-activation alone cannot distinguish `mode="local"` + a complete remote block (today: `WhereLocal`) from `mode="remote"` + the same block (today: `WhereSsh`). Ungated, it moves untrusted code onto the remote box for anyone who switched remote→local by editing only `mode` |
| **§5: a pin is validated, then fails closed** — new row before the default row | Rev 5's table let a *valid* pin naming a since-removed machine fall through to the **default**: the silent authority change §6.1 was written to prevent |
| **§5: single-machine `default` inference applies only when `allow_localhost = false`** | Otherwise writing the *first* `[machines.builder]` silently moved every pre-existing unpinned session off local — violating §9 criterion 3 with no mechanism to detect it |
| **WU-6: the web and chat mint paths must carry `machine`** | `mintBody`/`rebindBody` (`HttpClient.hs:223-238`) have no machine field, and `handleSessionNew`/`handleSessionRebindNew` do not accept one, so `/new --machine` from Telegram/Signal parsed the flag and **discarded it** |
| **WU-7: `machines` always includes `local` when `allow_localhost`; new `resolvable` flag** | Rev 5's `{default: null, machines: []}` contradicted §8's own test. And with `allow_localhost = false` + no inventory the New Tab form minted a session whose every turn fails closed |
| **The Files link goes inert on mismatch**, not merely badged (now WU-8) | `OpenWorkdirLink` builds `/files?path=…` and the explorer is boot-time global, so a `builder` session's link opened a nonexistent local path |
| **`TargetError` splits `TargetConfigLoadError` from `TargetNoMachine`; `renderTargetError` added; all six strings pinned** | One free-text field cannot distinguish "fix your TOML syntax" from "no machine is configured at all" — and row 4's message is the only outcome a hardened install ever sees |
| **Inheritance warns and falls back when a pin no longer resolves** | Copying a dead pin by value made branch/handoff reproduce the dead end, so §10's "start a new session" remedy lost the transcript for exactly the long session UC-1 exists to protect |
| **§9 criterion 1: denominator restricted to installs where the picker rendered** | Including single-machine installs (structurally 0%) drags the rate below the threshold and deletes the feature on a measurement artefact |
| **§9 verdict keeps the inventory and resolver; drops only the surfaces** | Rev 5 would have deleted the substrate the requester's stated next want (per-tool-call routing) is built on |
| **§6.3 extended to `sshExecArgvForwarding`, rsync, `GIT_SSH_COMMAND`** | `-F /dev/null` in `sshExecArgv` alone leaves git and rsync traffic re-pointable by a `Host *` stanza |
| **`erMeta.machine`'s true cost is 92 sites**, not ~60 | Rev 5 said "~60 call sites"; it is 92 applications. The cost is nevertheless ~zero because `mkTestUIOEnv u c = UIOEnv u c Nothing` keeps the arity |
| **§4 rewritten: the localhost denylist is deleted** | The operator decided to trust the authenticated user. The real control is that **no agent-reachable path can add a machine** — passkey-gated `POST /api/machines`, mirroring `POST /api/repos`, with no opcode writing `executionFilePath`. ~40 lines of address/host-key detection removed (the `localAddressNames` rationale row it replaced is gone with it) |

## Revision log — what changed from rev 4

Rev 4 kept `mode` and made the inventory SSH-only, to avoid opening rev 3c's
self-host hole. The gate found that reasoning unsound, and the fix is better than
either: **delete `mode` and replace it with `allow_localhost`.**

| Change | Why |
|---|---|
| **`mode` deleted.** `allow_localhost :: Bool` (default `true`) replaces it | One concept instead of two that could disagree. See §1 |
| **`allow_localhost` gates the fallback**, with no address classifier | An earlier revision tried to refuse known-local targets. Deleted in favour of the operator-only write model (§4): a denylist cannot bind the principal who owns the file |
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

`allow_localhost = false` gates the **fallback**: when it is `false` and no machine
applies, resolution returns `TargetNoMachine` (§5 row 4) and nothing runs. It is not
an address classifier — the denylist is deleted (§4.1), because the inventory is
operator-authored and an address denylist cannot bind the principal who owns the file.

The guarantee that replaces it is upstream and stronger: **no agent-reachable path can
add, remove, or edit a machine** (§4.3–4.4). Given that, the only way a
localhost-denoting machine gets into the inventory is that the operator put it there —
and if they want untrusted code on this kernel, `allow_localhost = true` says so
directly.

### 1.3 Default `true`

Today's behaviour is local execution. `true` is the honest default; `false` is
opt-in hardening. Shipping `false` would silently break every existing install,
which is worse than a default-open posture that is already default-open.

### 1.4 `-f remote-only-untrusted` re-couples here

This corrects rev 4. With `mode` gone, the compile-time coercion that currently
lives in `localModeResult` (`Security.hs:796-802`) has nowhere to go, so the
feature **owes** it: under `-DREMOTE_ONLY_UNTRUSTED`, `allow_localhost` is forced
`false`.

**It must be applied to the field's *default*, not only to a present
`[untrusted_execution]` section.** Forcing it inside `untrustedExecConfigCodec`
covers an install that has the section; a hardened build with **no**
`security.toml` would keep the field absent, `allow_localhost` absent ⇒ `true` ⇒
row 3 ⇒ `WhereLocal`. So the coercion belongs in the *accessor* that resolves the
field to a `Bool` (`allowLocalhostFrom :: UntrustedExecFileConfig -> Bool`), which is
total over the absent case. `mkLocalUntrustedIO` has **no** CPP guard
(`UntrustedIO.hs:79` imports `Local` unconditionally), so this value is the only thing
standing between the hardened build and local execution.

Test: "remote-only build + absent `security.toml` ⇒ `allow_localhost = false`". Note
this needs a second build variant (`seal-harness.cabal:343` already sets
`cpp-options: -DREMOTE_ONLY_UNTRUSTED` for one configuration), which is a real cost
and is owned by the CPP unit (WU-9).

`enforceRemoteOnly` — definition plus two tests, zero production call sites — is
expressible as `allow_localhost = false`, so **delete it** in WU-5 along with its
tests. Leaving it dead is worse than either keeping it wired or removing it.

### 1.5 Legacy compatibility: gated on `mode`, not merely on presence

**Presence alone is not enough.** Today `mode` distinguishes two installs that have
byte-identical remote blocks:

| `mode` | complete `[untrusted_execution.remote]` | today | rev 5 (wrong) | rev 6 |
|---|---|---|---|---|
| absent / `"local"` | present | `WhereLocal` (`localModeResult _ = Nothing`) | `WhereSsh "default"` — **moves untrusted code to the remote box** | `WhereLocal` |
| `"remote"` | present | `WhereSsh` legacy | `WhereSsh "default"` | `WhereSsh "default"` |
| `"remote"` | absent / incomplete | fail-closed | fail-closed | fail-closed |

So an operator who switched remote→local by editing only `mode` (leaving the block,
because nothing needs it removed) would silently have had untrusted execution moved
back onto the remote box. The rule:

- **The legacy block becomes the implicit machine `default` only when the derived
  `allow_localhost = false`.** Equivalently: `mode ∈ {absent, "remote"}`.
  `mode = "local"` ⇒ `WhereLocal`, block ignored.
- `allow_localhost` is **derived** from `mode` when present (`"remote"` ⇒ `false`,
  `"local"` ⇒ `true`); an explicit `allow_localhost` wins. A `mode` key without an
  explicit `allow_localhost` therefore cannot change posture.
- An **incomplete** block yields **no machine** (not a half-built one), so row 4
  applies and nothing runs. Stated explicitly because rev 5 left it to inference.
- `default` is reserved (`[machines.default]` in `execution.toml` is a load error).
- **No file is ever rewritten. No migration.** `mode` is deprecated-with-read-compat
  and can be removed in a later release. WU-2 seeds one **comment-only, worked
  example** `config/templates/execution.toml`; nothing in it is enabled.

Note the widening this requires: `mode` is **required** today (`Toml.text "mode"`,
`Security.hs:453`), so `[untrusted_execution.remote]` without `mode` is currently a
load error. Under deprecation it must decode. Benign, and pinned by a test (WU-2).

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

**Need existence is evidenced; need frequency is not.** The requester is the operator
and the user population for a single-operator self-hosted harness, and they have a
concrete two-machine workflow *plus* a stated future want (per-tool-call selection
across machines). That establishes the need **class** exists. It does **not** establish
how often the *pinned-session* form of it is used — which is what §9's two-week metric
falsifies. Rev 4 dropped this caveat entirely; the gate correctly called that the most
important line deleted, so it is stated here in both halves.

## 3. `execution.toml` — SSH machines, in `config/`

```toml
# ~/.seal/config/execution.toml
# Hand-editable, but the supported path is POST /api/machines (passkey-gated, WU-7).
# No opcode can read or write this file (§4.3).
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
| machine inventory | `config/execution.toml` | **yes, by design** | **no** — passkey-gated route only (§4.3) |
| `allow_localhost` | `security.toml` | no | no |

**The write path is the control, not the file's contents** (§4.3–4.4). What matters
is not whether the inventory is agent-writable in the filesystem sense — it is that
**no agent-reachable path can add, remove, or edit a machine.** That holds because
`POST /api/machines` is passkey-gated (`accessControlMiddleware` is default-deny) and
no opcode writes `executionFilePath`. Under `allow_localhost = false` the one local
write primitive that does not go through `FILE_WRITE` — `group` in
`SKILL_WRITE`/`AGENT_DEF` — is closed by WU-2's sanitisation.

The residual — a cloned dotfiles repo carrying a localhost entry — arrives as an
operator action in a file they version-control. §4.5 records that as the accepted
trade.

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

## 4. Trust model: the operator adds machines, and nobody else

### 4.1 Decision

**No address- or host-key-based localhost detection.** Earlier revisions spent three subsections
on enumerating loopback spellings, interface addresses, numeric re-encodings and (in a
deferred layer) host-key fingerprints, all to stop an `execution.toml` entry that
denotes the harness box. **All of it is deleted.**

Not because the concern is unreal, but because **it defends against the wrong actor.**
The inventory is a human-authored file in the operator's own config tree. A machine
entry naming `localhost` is an operator decision — and if the operator wants untrusted
code to run on this kernel, `allow_localhost = true` already says so in one word. An
address denylist cannot meaningfully bind a principal who owns the file, can edit the
setting, and has shell access as the same user.

So the guarantee is: **`execution.toml` is human-authored, and no agent-reachable path
can add, remove, or edit a machine.** Everything in §4 is about holding that line.
Given it, `allow_localhost` needs no classifier — it gates the *fallback* (§5 row 3),
not the inventory.

### 4.2 The control: passkey-gated writes, on the `/api/repos` pattern

The codebase already has exactly this shape, and it is the one to copy:

| | `POST /api/repos` (existing) | `POST /api/machines` (new, WU-7) |
|---|---|---|
| Route gated by `accessControlMiddleware` | yes — default-deny, `AccessControl.hs:341-352` | yes, same middleware, no new auth |
| Writes a file in `config/` | `repos.toml` via `updateRepoRegistry` | `execution.toml` via `updateExecutionConfig` |
| Serialised by a process lock | `repoRegistryWriteLock` (`Registry.hs:77`) | `executionWriteLock` (same pattern) |
| Written atomically, 0600 | `saveRepoRegistry` | `writeSecretFile` + `openUniqueTemp` (`Security.hs:538,578`) |
| Reachable by an opcode | **no** | **no** |

`accessControlMiddleware` is default-deny: everything except `/api/auth` requires a
valid passkey session. So "only an authenticated operator adds machines" is **not a new
control** — it is the existing control, pointed at a new route. No new auth mechanism,
no new session concept, no new exemption to get wrong.

### 4.3 The opcode ban (the load-bearing part)

This is the property to test, and it is cheap to test:

1. **No opcode writes `execution.toml`.** A grep test asserting zero occurrences of
   `executionFilePath` under `src/Seal/ISA/`. Same posture as `security.toml`
   (`AGENTS.md` rule 3).
2. **No opcode adds, removes, or edits a machine.** No `MACHINE_*` opcode exists in
   `Seal.ISA.Registry`; a test asserts the registry contains none.
3. **The write function is not exported to any opcode-reachable module.** Same
   structural argument `Seal.Config.Security` already makes for itself: the narrow
   writer's callback sees only machine fields, so an opcode cannot express a change
   even if one were wired up by mistake.

And the reason this suffices, stated plainly: **an agent that could write
`execution.toml` under `allow_localhost = false` would be an escalation** — it could
add a machine pointing anywhere. §4.4 closes that. Under `allow_localhost = true` it
would gain nothing, since local execution is already permitted.

### 4.4 Why the ban holds — including the one path that does not go through `FILE_WRITE`

Under `allow_localhost = false`:

- `FILE_WRITE` cannot reach `~/.seal/` — contained under `WorkspaceRoot`, and
  `blockedNames` includes `.seal` (`Path.hs:53`). Doubly out of reach.
- `SHELL_EXEC` runs on the **remote** box, so it cannot touch the harness filesystem.
- **`SKILL_WRITE` / `AGENT_DEF` write locally without either of those.** `defPath`
  (`Agent/Def/Backend.hs:139-144`) and `skillPath` (`Skills/Backend.hs:418-423`) build
  `root </> T.strip group </> <id>.md` with `createDirectoryIfMissing True`, and
  `group` comes raw from `groupField` (`Skills.hs:92-97`, `T.strip` only).
  `group = "../../.."` escapes the config tree **today**, independent of this feature.
  It cannot forge `execution.toml` only because `.md` is unconditionally appended —
  an accident, not a boundary.

  **WU-2 adds charset sanitisation to `group`** (`[A-Za-z0-9_-]`, rejecting `.`/`..`/
  separators) with a test that `group = "../../.."` is refused. This is the one place
  where trusting the operator is not enough, because the hole is an *agent* write
  primitive that happens to be aimed at the operator's config tree.

Under `allow_localhost = true` the agent can write the inventory and it does not
matter — local execution is already permitted, so no entry gains authority.

### 4.5 What this gives up, stated rather than buried

- **An operator can add `localhost` as a machine.** That is the point. It is their
  harness, the file is theirs, and `allow_localhost` is right there.
- **A cloned or dotfiles-synced `execution.toml` can carry a localhost entry.** It
  arrives as an operator action, in a file they version-control. If that is not
  acceptable for a given deployment, the answer is a deny-list — which rev 7 spent 70
  lines on and this revision deletes. Recorded here so the trade is visible, not so it
  can be re-added silently.
- **An agent can still run `ssh -L`/`socat` inside `SHELL_EXEC`.** Never defended
  against by any revision of this design; needs egress policy, a different feature.

The guarantee this buys instead is narrower and *true*: **no agent-reachable path can
change which machines exist.** That is the sentence the tests assert.

## 5. Resolution

```haskell
-- Seal.Execution.Types (pure; imports Seal.Security.Path + Seal.Tools.Exec.Types only)
newtype MachineName = MachineName Text          -- smart constructor, unexported

data ResolvedTarget = WhereLocal | WhereSsh MachineName SshConfig
  deriving stock (Eq, Ord, Show)
```

`Ord` does not compile today and WU-1 must add it: `SshConfig` (`Types.hs:83-91`),
`SshHost` (`:124`) and `SshUser` (`:139`) all derive `(Eq, Show)` only. `RemotePath`
already has `Ord`. Named explicitly because those three edits land in
`Seal.Tools.Exec.Types`, outside WU-1's stated file list.

```haskell
data TargetError
  = TargetUnknownMachine   MachineName [MachineName]  -- requested, available
  | TargetLocalNotAllowed  MachineName                -- allow_localhost = false
  | TargetConfigLoadError  Text                       -- bad TOML / validation
  | TargetNoMachine        Text                       -- nothing may run at all
  deriving stock (Eq, Show)

renderTargetError :: TargetError -> Text
```

Six pinned strings. `TargetConfigLoadError` and `TargetNoMachine` are **separate
constructors** because their remedies are unrelated (fix your TOML syntax vs. write
an inventory) and one free-text field cannot say which. The last message is the
only outcome a hardened install ever sees, so it must name **both** remedies.

```haskell
resolveTarget
  :: ExecutionConfig                  -- pre-filtered at load; localhost offenders already rejected
  -> Maybe UntrustedExecFileConfig    -- §9 layering: NOT SecurityConfig
  -> Maybe MachineName                -- the session pin
  -> Either TargetError ResolvedTarget
```

| # | Condition | Result |
|---|---|---|
| 0 | **pin present and unresolvable** — not in the inventory, or `local` while `allow_localhost = false` | `Left TargetUnknownMachine` / `Left TargetLocalNotAllowed` |
| 1 | pin names a machine (incl. reserved `local` when `allow_localhost`) | `WhereSsh` / `WhereLocal` |
| 2 | else an effective `default` exists | same |
| 3 | else `allow_localhost = true` | `WhereLocal` |
| 4 | else | `Left TargetNoMachine` — nothing may run |

**Row 0 is why the pin is validated before the default is consulted.** Without it a
*valid* pin naming a since-removed machine decodes fine, fails row 1, and falls to
row 2 — the default — which is precisely the silent authority change §6.1 exists to
prevent. A session pinned to `local` whose `allow_localhost` is later set `false`
reaches row 0 and fail-closes with `TargetLocalNotAllowed` naming the setting.

**`local` is a reserved, pinnable name**, present iff `allow_localhost = true`.
Without it a user with an inventory could never pin a session to the laptop, which
is half of UC-1. `[machines.local]` declared in the file is a load error.

**Effective `default`** — and the rule that makes §9 criterion 3 achievable:

- `execution.toml`'s explicit `default` always wins.
- When `default` is **absent** and the inventory has exactly one machine, that
  machine becomes the effective default **only when `allow_localhost = false`**.
- When `default` is absent, the inventory has exactly one machine, and
  `allow_localhost = true`: **`local` stays the default.** Writing the *first*
  machine must not silently move every pre-existing unpinned session onto it.
- When `default` is absent with ≥ 2 ssh machines: a config-load error naming them.

**`local` does not count** toward the "≥ 2 machines ⇒ `default` required" rule: it
is the fallback, not a peer. It **does** appear in `GET /api/machines` and **does**
count toward the picker's `≥ 2` render rule (§7).

**The pin is a request, not a resolution.** v1 persists the name the user asked for,
never an `SshConfig`. Storing a resolution freezes a fingerprint of mutable config,
which is D11's bug in a different position.

**On inheritance: a dead pin fails closed, it does not fall back.**

Rev 6 said the child falls back to the effective default and warns. That can land
`WhereLocal`: with `allow_localhost = true`, exactly one ssh machine, no explicit
`default`, a session pinned to that machine, and then the machine renamed — the child
inherits the dead pin, fails rows 0/1, and lands on row 3. **Untrusted subagent code
executes on the harness kernel, with only a warning to show for it.** That is
precisely the silent authority change §6.1 exists to forbid, and transcript
preservation does not buy an authority downgrade.

So: a child **copies** the parent's value; if that value no longer resolves, the child
fails closed with `TargetUnknownMachine`, exactly as the parent does, and names the
machine. Both parent and child are repaired the same way (§10). Consistent, and one
rule instead of two.

## 6. Fixes the gate verified against source

These are not new features; each is a defect in the current tree that this feature
would otherwise build on.

### 6.1 Fail-closed `exec_machine` decode

Rev 4 said "invalid name is dropped, matching the existing tolerant-decode policy".
**Wrong for this field.** If a pinned machine is renamed, the pin becomes `Nothing`,
resolution falls to row 2, and the session **silently moves** — a silent authority
change with no error, log, or prompt. Tolerant decode is right for cosmetic fields.

**Two distinct cases, and only one needs a decode error:**

| Case | Mechanism | Behaviour |
|---|---|---|
| a machine was **renamed/removed**, pin text still valid | `smExecMachine = Just name`, not in inventory | §5 **row 0** ⇒ `Left TargetUnknownMachine` |
| `exec_machine` text is **malformed** (hand-edited, corrupt) | `mkMachineName` fails at decode | `Nothing` + a load-time warning |

**Why malformed text is `Nothing` and not an error.** `readSessionMeta ::
SealPaths -> SessionId -> IO (Maybe SessionMeta)` has no error channel, and
`decodeFileStrict` collapses every parse failure to `Nothing`; **30 call sites**
depend on that type. Giving it one would be a 30-site change for a case that is
already caught — and worse, propagating a decode failure would make a *hand-edited*
session unreadable entirely, which is a harsher outcome than the silent move it
prevents. So: `Nothing` + a warning, and row 0 carries the fail-closed guarantee.

A **renamed machine** (the case that actually happens) is therefore fully fail-closed
via row 0, and rev 6's test row becomes: "a valid pin naming an absent machine ⇒
`TargetUnknownMachine`", not "malformed text ⇒ `TargetUnknownMachine`".

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

### 6.3 Restore `-F /dev/null` — in **every** ssh argv builder

Reproduced: a `Host *` stanza in `~/.ssh/config` sets `Hostname` and
`ProxyCommand`, so a machine entry does **not** fully determine its endpoint.
`-F /dev/null -o ProxyCommand=none -o ProxyJump=none` closes it. Rev 4 deleted
this with D6, which was a mistake — it is endpoint integrity, not self-host
detection.

**Not just `sshExecArgv`.** `sshExecArgvForwarding` (`Remote.hs:130`), the rsync rsh
string (`AgentMetaCache.hs:186-196`) and `GIT_SSH_COMMAND` (`Clone.hs:481`) also
honour `~/.ssh/config`, so a `Host *` stanza re-points git and rsync traffic too. One
line each. Verified non-breaking: every existing argv assertion is membership- or
adjacency-based (`checkAdjacentPair`, `elem`, `isSuffixOf "-m-%C"`), and
`grep 'argv !!'` finds zero positional assertions, so inserting after `"ssh"` is
invisible to the suite.

### 6.4 Mux key: `%C` already includes the user; `identity` is the gap

**Rev 5 stated this backwards and was verified wrong.** `%C` is a hash of
`%l%h%p%r%j` — the user **is** included. Reproduced:

```
ssh -G -o ControlPath=/tmp/cp-%C alice@exec.invalid → cp-b58648dc…
ssh -G -o ControlPath=/tmp/cp-%C bob@exec.invalid   → cp-8adb5a85…   different
ssh -G -o ControlPath=/tmp/cp-%C -i /tmp/k1 a@h.invalid → cp-8914aa8c…
ssh -G -o ControlPath=/tmp/cp-%C -i /tmp/k2 a@h.invalid → cp-8914aa8c…  SAME
```

So different `user` already gets a different master, and rev 5's proposed `%r` fix
would have been a no-op. The real unhashed inputs are **`identity` and
`known_hosts`**: two entries with the same host/port/user but different keys share one
master, and whichever connected first serves both — riding the wrong key and the
wrong pinned host key. Unreachable today (one global `SshConfig`); reachable the
moment the inventory exists.

Fix (both, they are cheap): fold a truncated hash of `identity`+`known_hosts` into the
ControlPath, **and** reject duplicate `host:port:user` across machines at load so two
entries cannot silently alias. `Remote.hs:154-156`'s comment is stale — correct it in
the same commit, since a design that cites a wrong comment is how this survived to
rev 5.

**This is not free: it breaks five existing assertions.** Rev 6 claimed the change was
"invisible to the suite" — true of inserting a *flag*, false of changing the
`ControlPath` *value*. `RemoteSpec.hs:236,241,242,247` compare it exactly
(`checkAdjacentPair argv "ControlPath" (home </> ".seal/ssh-mux/m-%C")`), and `:252`
asserts the `-m-%C` suffix. Those five are part of WU-1's commit.

Similarly §6.3's `-F /dev/null` insertion **is** invisible — every ssh-argv assertion
elsewhere is membership- or adjacency-based, and `grep 'argv !!'` finds zero positional
assertions — but only because it inserts rather than replaces. Worth stating which is
which, so the next reader does not assume both are free.

### 6.5 Layering

`resolveTarget` takes `Maybe UntrustedExecFileConfig`, not `SecurityConfig` — naming
a type in a signature *is* importing it, so rev 4's "neither imports
`Seal.Config.Security`" was false. `Seal.Security.Path` imports zero `Seal.*`
modules (verified), so `Seal.Execution.Types` stays a leaf.

## 7. Work units

**Nine units** (ten if §6.3/6.4 split out as WU-1b). Additive. Demo at WU-6.
Rev 6 had nine too, but differently: `erMeta.machine` is dropped (§9) and the CPP
coercion is promoted from prose to WU-9.

### WU-1 — `Seal.Execution.Types` (pure)
`MachineName` (+ reserved `local`/`default`), `SshMachineSpec` (validated newtypes),
`ResolvedTarget` (**needs `Ord` on itself and on `MachineName`**), the
four-constructor `TargetError`, `renderTargetError`,
`sshConfigFromMachine :: SshMachineSpec -> SshConfig` (total),
`targetLabel :: ResolvedTarget -> Text`, and
`targetSshConfig :: ResolvedTarget -> Maybe SshConfig`.

**Also in this commit, in `Seal.Tools.Exec.Types`:** `deriving Ord` on `SshHost`
(`:124`), `SshUser` (`:139`) and `SshConfig` (`:83-91`), plus the leading-`-` guard in
`mkSshHost`/`mkSshUser` (§6.2). `ResolvedTarget`'s `Ord` does not compile without
them, and `RemotePath` already has it. Cabal wiring in the same commit (a module in no
stanza is never typechecked). Prefixes `smsHost`/`smsUser`/… to match `scHost`/
`naProvider` style.

**And §6.3 + §6.4 in this commit, in `Seal.Tools.Exec.Remote` /
`Seal.Session.AgentMetaCache` / `Seal.SourceControl.Clone`:** `-F /dev/null
-o ProxyCommand=none -o ProxyJump=none` in all four ssh-argv/rsh builders, the
`identity`+`known_hosts` hash folded into `ControlPath`, and the stale comment at
`Remote.hs:154-156` corrected. **Five assertions update with it**
(`RemoteSpec.hs:236,241,242,247,252`) — this unit is not "pure" any more, and pretending
otherwise is how rev 6 mis-scoped it. Alternative, if that is too much for one unit:
split §6.3+§6.4 into **WU-1b** (same pattern as rev 3c's C2), which keeps WU-1 pure.
Recommended — WU-1 is already the foundation for eight others.

### WU-2 — `execution.toml` codec + `loadExecutionConfig`
`Seal.Config.Execution`: the codec (§3.2 validation, reserved names, duplicate
`host:port:user` rejection, unknown-key warning), `executionFilePath :: SealPaths ->
FilePath` added to `Seal.Config.Paths`, `loadExecutionConfig`, and a
comment-only template + `extra-source-files`. *(Moved ahead of the resolver — rev 4
had WU-2 depending on a codec that did not yet exist, so `make check` could not
pass.)*

**Also in this commit, two items rev 6 left out:**

- **`Seal.Config.Security`**: `uefcMode` becomes optional (`Toml.text "mode"` →
  `dioptional`, `Security.hs:453` — required today, so §1.5's
  "`[untrusted_execution.remote]` without `mode` decodes" test needs it) and gains
  `uefcAllowLocalhost`, with `allowLocalhostFrom` deriving from `mode` when absent.
- **`group` sanitisation** for `SKILL_WRITE`/`AGENT_DEF` (§3.1): charset
  `[A-Za-z0-9_-]`, rejecting `.`/`..`/separators. Test: `group = "../../.."` is
  refused. This closes a local-write escape that exists today, independent of this
  feature, and which §3.1's inventory-integrity argument currently leans on.

### WU-3 — `Seal.Execution.Resolve`
`resolveTarget` (**five rows** 0-4, pure), `loadAndResolveTargetIO` (turns a load
failure into `TargetConfigLoadError`). **No address classifier** — the localhost
denylist this unit carried in earlier revisions is deleted (§4.1), making it ~40
lines smaller.

### WU-4 — the per-session pin
`SessionMeta` gains `smExecMachine :: Maybe MachineName`; key `exec_machine`, wire
`execMachine`. `FromJSON` is **explicit**, not derived (§6.1).

**The 75-site sweep is unavoidable — rev 6 was wrong about this.** Haskell has no
record-field defaults, and `-Wmissing-fields` is part of `-Wall`
(`seal-harness.cabal:33`, with `-Werror`), so **every** named-field `SessionMeta`
literal becomes a compile error the moment the field is added: **75 sites across 25
files**, 73 test / 4 src (`scripts/count-sessionmeta-sites.py` reports 77 including two
in `Meta.hs` itself). There is no arity change to `newSession`/`newSessionMeta`, but
that saves nothing — the literals are the cost, not the function signatures.

Mitigation, named so this unit is writable: add
`defaultSessionMeta :: SessionId -> UTCTime -> SessionMeta` in `Seal.Session.Meta`, so
each of the 75 sites becomes one record-update line
(`defaultSessionMeta sid now { smProvider = … }`) instead of re-listing 14 fields. That
is the same helper rev 3c's D15 asked for, and it makes the sweep mechanical rather
than error-prone. A `setExecMachine :: MachineName -> SessionMeta -> SessionMeta`
helper keeps the field out of opcode-reachable construction.

Inheritance copies the parent's **value**, and a dead value fails closed (§5):
`writeChildMeta` (`Worker.hs:404`), `writeHandoffMeta` (`:518`), `fallbackMeta`
(`TurnEngine.hs:1340`), `initSessionMeta`, and the branch handler
(`API.hs:1317-1327` — *not* `branchSession`, whose own haddock says it writes no
`session.json`).

**No opcode may set `smExecMachine`.** Tested two ways: a grep asserting zero
occurrences under `src/Seal/ISA/Ops/`, and `SESSION_MANAGE action=new` with an extra
`machine` key resolving to the effective default.

### WU-5 — collapse the eight derivations; delete `execFingerprint`
`mkSessionExec`/`cachedSessionExec` take `ResolvedTarget`; the memo key becomes
`(SessionId, ResolvedTarget)`; `execFingerprint` **deleted**; the `sceExecs` IORef's
type and `CachedExec`'s shape change; `invalidateExec` drops **all** targets for the
sid. `mkSessionUntrustedIO` **deleted** (zero production callers, and it is a
`SecurityConfig`-shaped bypass of the resolver being introduced) — and its
equivalence test deleted in the same commit (`WorkdirSpec.hs:267-276`).

Boot sites (`Cli.hs:158`, `Serve.hs:538`, `Serve.hs:677`) have **no session** and
resolve **unpinned** (rows 3-4). **Each `Left` must have a defined behaviour** —
rev 5 left this undefined and the unit cannot be written without it:

- `Cli.hs:158` / `Serve.hs:538` (`isRemote` Bool): log the rendered `TargetError` at
  warn, set the Bool `False` (row 4 means nothing executes anyway, so nothing is
  reachable to be remote).
- `Serve.hs:677` (file explorer): `Left` ⇒ `mkFailClosedFileExplorer`, matching the
  existing "remote mode without SSH ⇒ fail-closed" posture.

The per-session remote-ness boolean moves *into the turn* (`TurnEngine.hs:918`,
`metaCacheEnvFor`) keyed off the session's pin — otherwise a session pinned to
`builder` under `allow_localhost = true` gets `cdIsRemote = False` and the wrong
clone path.

**Three more items this unit owns, which rev 6 left unowned:**

1. **`ApiTestHarness` re-typing.** **32** test references to
   `UntrustedExecMode`/`UemLocal`/`UemRemote`, and the harness's spine is
   `buildTestEnv :: FilePath -> UntrustedExecMode -> …` (`ApiTestHarness.hs:413`),
   used at `:365`/`:378` and read at `:496`/`:498`/`:511`/`:542`. Until it is re-typed
   to `ResolvedTarget` + `execution.toml` fixtures, `mode` **cannot** be deleted and
   `make check` cannot be green. This is the largest hidden cost in the feature, and
   it is why rev 5's "delete `mode`" looked cheap.
2. **`selectExecBackend` / `selectUntrustedBackend`** (`Untrusted.hs:88-118`) branch
   on `UemLocal`/`UemRemote` and will not compile once the type is gone. Zero
   production callers (tests only) — delete them, or re-type to `ResolvedTarget`.
   Named because they are a second, parallel authority-decider, and leaving them
   half-migrated is how two decision paths appear.
3. **`enforceRemoteOnly`** deleted with its two tests (§1.4).

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

**The web and chat mint paths need four more edits, not one.** Rev 5 claimed the
chat path "picks it up with no separate parser" — true of the *parser*, false of the
*body*. `Loop.hs:1744` sends `mintBody (naProvider na) (naModel na) …`, and
`HttpClient.hs:223-238`'s `mintBody`/`rebindBody` carry no machine field; they POST to
`handleSessionNew` (`API.hs:1443`) and `handleSessionRebindNew` (`API.hs:1494`),
neither of which accepts one. So `/new --machine builder` **from Telegram or Signal
parsed the flag and discarded it**, landing the session on the default — the exact
silent-authority-change class §6.1 was added to eliminate. Required:

1. `HttpClient.mintBody`/`rebindBody` gain `Maybe Text`;
2. `handleSessionNew`/`handleSessionRebindNew` accept it and validate pre-mint;
3. each returns a `400` carrying the available set, relayed to the user via `ccSend`
   (mirroring the `/new -r` failure path at `Loop.hs:1765`);
4. `createBareSession` (`useApi.ts`) hits `handleSessionNew` too — the "Recent
   Sessions +" button is a fifth mint site, and is deliberately machine-less. State
   that, so it is a decision rather than an omission.

`CreateTabBody` gains `machine?: string` (`useApi.ts:1021`) — flat, matching
`branch_from`/`harness_id`. `createTab` currently **discards the response body** on
`!res.ok` (`:1046`), so a 400 is invisible; it must return `NewTabResult | null`
(`{ok:false, error}`) like `setupRepo` (`:1279`). **Careful:** the composer's
`if (res)` at `NewTabComposer.tsx:81` treats `{ok:false}` as success and would still
call `onSubmit` + `persistOnSubmit`; it becomes `if (!res || !res.ok)`. `buildBody`
**omits** `machine` whenever the picker is not rendered **and** whenever `branch_from`
is set (the backend copies the parent's pin, so sending it would express a value the
server ignores) — one rule, not two.

`renderNewSessionConfirmation` gains the machine name.

### WU-7 — the machine API: `GET /api/machines`, `POST /api/machines`, and the dropdown

**The write route is the security control (§4.2–4.3), so it is the load-bearing part of
this unit, not the read.** `POST /api/machines` follows `POST /api/repos` exactly:

- passes through `accessControlMiddleware` unchanged — passkey-gated, default-deny,
  **no new auth mechanism**;
- body `{name, host, user, port?, identity?, known_hosts, workspace}`, validated by
  WU-2's codec, returning the same field-specific `Left` messages;
- serialised by `executionWriteLock` (same pattern as `repoRegistryWriteLock`,
  `Registry.hs:77`) and written via `writeSecretFile` + `openUniqueTemp`
  (`Security.hs:538,578`);
- `DELETE /api/machines/:name` alongside it, refusing to remove a machine that is
  `default` (or reassigning `default` explicitly);
- **`MachinesWrite` exported only to `Seal.Gateway.API`** — no opcode module may import
  it. A grep test asserts zero `executionFilePath` references under `src/Seal/ISA/`.

`GET /api/machines` — `200 {default: string|null, machines: [{name, kind, default}],
resolvable: boolean, error: string|null}`. Degraded shapes are **200, never 500**; a
malformed file must not break the New Tab form.

**`local` is always in the list when `allow_localhost = true`** — so with no
`execution.toml` the honest shape is
`{default: "local", machines: [{name:"local", kind:"local", default:true}], …}`, not
rev 5's `{default: null, machines: []}` (which contradicted §8's own test). The picker
stays hidden by the `≥ 2` rule, so nothing changes visually and the data stops lying.
`machines: []` occurs only under `allow_localhost = false`, where `resolvable = false`.

**`resolvable` exists because rev 5 minted doomed sessions.** With
`allow_localhost = false` and no inventory — the state `-f remote-only-untrusted`
forces, and the state a cautious operator creates by setting the flag before writing
an inventory — the form succeeded, `buildBody` omitted `machine`, the session was
created, and then *every turn* failed closed on row 4. WU-7 requires
`NewTabComposer` to **disable Start** and render the `error` (naming both fixes) when
`resolvable === false`.

`kind: "local" | "ssh"` means the client never hardcodes the reserved literal. Label
the row **"Run on"** and the local option **"This machine (where Seal runs)"** — the
browser may be on a different box than the gateway, so bare "Local" is ambiguous
about whose local.

Route work: a `SealRoute` constructor, `routeMeta`, `openApiMeta` (both exhaustive
`\case` under `-Werror`), `ApiRouteSpec.expectedRouteCount` **81 → 82**.

`NewTabComposer.tsx`: one `<select>`, rendered only when `machines.length ≥ 2` and
`kind === 'provider'`; read-only in branch mode (the backend copies the parent's
pin). **Do not persist it in `LastOptions`** (`UiState.hs:57`) — `repoBranch` is
deliberately not persisted for the same class of reason.

### WU-8 — session-viewer surface
`GET /api/sessions/:id/workdir` returns `{path, machine, files_machine}`
(`handleSessionWorkdir` returns `{path}` today and derives it from `mode`, so it must
resolve the pin; `files_machine` is `null` when the explorer is `FeDisabled`).

**The badge alone is not the fix.** `OpenWorkdirLink` (`ChatArea.tsx:358`) builds
`/files?path=<path>`, and the file explorer is a **single boot-time global**
(`Serve.hs:677`) with no session input. Today remote mode and the explorer always
agree; with per-session pins a `builder` session gets
`path = /srv/seal/workspace/workdirs/<sid>` while the explorer is local, so the link
opens a nonexistent local path and the user sees "not found" for a directory that
exists. WU-8 must render the link **inert** (the existing `aria-disabled`/no-`href`
path supports it) whenever `machine ≠ files_machine`, with a title naming both; the
badge is supplementary.

This is the accepted v1 cost of a global explorer, and it is sharpest for UC-1's
compile session: *"I can't see my build artifacts in Files."* Stated as a cost, not
just a badge.

### WU-9 — the `-f remote-only-untrusted` coercion
Promoted from a §1.4 paragraph to a unit, because it was prose-only across three
revisions and is the last thing standing between a hardened build and local execution.

Under `-DREMOTE_ONLY_UNTRUSTED`, `allowLocalhostFrom` returns `False`
**unconditionally** — including when `security.toml` is absent, which is the case rev 6
missed. `mkLocalUntrustedIO` has no CPP guard (`UntrustedIO.hs:79` imports `Local`
unconditionally), so this value *is* the guarantee.

Cost note: the test needs a second build variant. `seal-harness.cabal:343` already sets
`cpp-options: -DREMOTE_ONLY_UNTRUSTED` for one configuration, so the pattern exists.
Wiring a second `test-suite` stanza is the work. If that proves expensive, the fallback
is a CPP-guarded `#if` inside the existing spec plus a pure unit test of
`allowLocalhostFrom` — cheaper, and it tests the function rather than the artifact.
Issue #347 owns the artifact property (the module still compiles in), which stays out
of scope.

## 8. Testing

TDD throughout. Properties worth QuickCheck, per unit:

| Unit | Tests |
|---|---|
| WU-1 | `mkMachineName` accepts iff charset-valid **and** not reserved; empty / leading `.` / leading `-` / 64 vs 65 / control chars; `sshConfigFromMachine` total and field-preserving; `mkSshHost`/`mkSshUser` reject leading `-`; **`renderTargetError` total, all six strings exact** (`TargetUnknownMachine` names the available set *and* the remedy; `TargetNoMachine` names **both** fixes) |
| WU-1b (§6.3/6.4) | `-F /dev/null`, `ProxyCommand=none`, `ProxyJump=none` present in all four builders; two `SshConfig`s differing only in `identity` get **different** ControlPaths; duplicate `host:port:user` ⇒ `Left`; the five updated `RemoteSpec` assertions |
| WU-2 | codec round-trip; each required field missing ⇒ `Left` naming it; `[machines.local]`/`[machines.default]` ⇒ `Left`; invalid name as key ⇒ `Left`; port `0`/`65536`; duplicate `host:port` ⇒ `Left`; unknown key ⇒ warning not error |
| WU-3 | five rows 0-4; row 3 ≡ today's behaviour for every `SecurityConfig`; **no inventory or pin can produce `WhereLocal` unless `allow_localhost`**; row 4 returns `TargetNoMachine` when `allow_localhost = false` and nothing applies. — the rev-7 loopback suite is deleted with §4.1 |
| WU-4 | `exec_machine` round-trips; absent ⇒ `Nothing`; malformed text ⇒ `Nothing` + a warning; **a valid pin naming an absent machine ⇒ `TargetUnknownMachine`**; all five inheritance sites copy the value; **a dead pin fails closed in the child, never falls back to `WhereLocal`**; `SESSION_MANAGE action=new` + `machine` key ⇒ default |
| WU-5 | **two sessions on two machines in one cache get distinct execs** (the headline feature); a target change rebuilds; an unchanged target reuses; `invalidateExec` clears all targets for the sid; a legacy `mode=remote` install with no `execution.toml` produces byte-identical argv |
| WU-6 | `--machine` parses; value-less `--machine` ⇒ error not silent; unknown machine ⇒ 400 whose body carries the available set; **no `session.json` minted on refusal**; web path sends an identical body when the picker is hidden |
| WU-7 | golden JSON as before; absent file + `allow_localhost = true` ⇒ `{default:"local", machines:[{name:"local",kind:"local"}]}`; absent file + `false` ⇒ `machines:[], resolvable:false`; route count **83** (read + add + remove); `≥2` render rule; Start disabled on `resolvable:false` |
| WU-7 (opcode ban) | **grep: zero `executionFilePath` under `src/Seal/ISA/`**; registry contains no `MACHINE_*` opcode; `POST /api/machines` returns 401 without a passkey session (the middleware test, not a new one); `DELETE` of the `default` machine is refused |
| WU-8 | workdir response carries both machines; they differ ⇒ badge shown **and** the Files link is inert |
| WU-9 (CPP) | the `-DREMOTE_ONLY_UNTRUSTED` variant builds and asserts `allow_localhost = false` **with `security.toml` absent**; an explicit `allow_localhost = true` in the file is overridden |

**The additivity tests, written first, passing on the unmodified tree:** a legacy
`mode=remote` install with no `execution.toml` yields byte-identical ssh argv; and
a local install with no `execution.toml` yields no ssh argv at all.
(Note the one deliberate legacy change: a `security.toml` host beginning with `-`
previously loaded and now fails closed — §6.2. That is the only behaviour change to
an existing install, and it is a hardening.)

**Plus the transition tests, which rev 5 lacked:**
`mode=local` + a **complete** `[untrusted_execution.remote]` block ⇒ `WhereLocal`
(the §1.5 row-1 bug); and `allow_localhost=true` + writing the **first**
`[machines.builder]` with no `default` ⇒ pre-existing unpinned sessions **stay**
`WhereLocal` (the §5 effective-default bug).

**Post-WU-5 harness equivalence:** `ApiTestHarness`'s remote fixture still yields
`sdIsRemote = True` and byte-identical argv after re-typing — this *is* the additivity
fixture, and WU-5 changes it.

## 9. Success criteria

| Signal | Target | Observed by | Verdict if missed |
|---|---|---|---|
| Sessions pinned to a non-default machine | ≥ 20% of sessions created **on installs where the picker rendered** (`machines.length ≥ 2`), with ≥ 10 such sessions (else "insufficient data", not "pass"); owner: the operator; evaluated **2 weeks after first WU-7 deploy** | `grep exec_machine ~/.seal/state/sessions/*/session.json` (honour `SEAL_HOME`; `sessionsRoot = spState </> "sessions"`, `Paths.hs:233`) | **Keep the inventory and resolver**; drop only the surfaces (WU-6/7/9). See below |
| Two sessions on two machines, both executing | 1 observed | manual, at the demo | UC-1 unvalidated |
| Sessions moved by adding a machine | 0 | integration test + the same grep before/after | A regression, not a feature |
| Machine visible without a click | shown when it differs from the explorer's | WU-8 test | UC-3 unimplemented |
| No legacy behaviour change | byte-identical resolution + argv | the two additivity tests | Additivity claim false |

**The denominator matters.** Rev 5's "sessions created since ship" included installs
where the picker never rendered (`machines.length < 2`), where the rate is
structurally 0% — so a single-machine install would drag the rate under the threshold
and *delete the feature on a measurement artefact*.

**The verdict no longer deletes the substrate.** Rev 5's "drop the inventory, pin,
and picker" would remove `execution.toml` and the resolver — exactly what the
requester's stated next want (per-tool-call selection) is built on. A missed metric
should drop the **surfaces** (the picker, the badge, WU-6/7/9) and keep the inventory
plus WU-3/WU-5, which fix a real today-biting bug (`execFingerprint`) and pay for
themselves regardless.

Criterion 1 measures **configuration**. `erMeta.machine` would measure **use**, which
is the better instrument — but it costs a third `UIOEnv` field across 92 sites for no
user-visible capability, so it is **deferred** and gated on criterion 1 proving
ambiguous. Recorded here so the option is not lost.

## 10. Risks

| Risk | Mitigation |
|---|---|
| An operator adds `localhost` as a machine | **Accepted by design** (§4.5). They own the file; `allow_localhost` is the setting that decides whether it matters. The guarantee is that no *agent* can add one |
| A machine becomes unreachable mid-session | Every subsequent turn fail-closes with a message naming the machine; re-pinning is §11 |
| A removed/renamed machine strands a pinned session | `TargetUnknownMachine` naming the machine. **Remedy: a fresh session — *not* a branch or handoff**, since inheritance copies the pin and a dead pin fails closed rather than falling back (§5). No `/machine` command in v1 (§11) |
| Two entries share a mux master despite different keys | §6.4: fold `identity`+`known_hosts` into the ControlPath, and reject duplicate `host:port:user` at load |
| Two sessions on two machines share one exec cache | The key change is the mitigation; it has its own test |
| The explorer is a boot-time global, so a `builder` session's Files link is wrong | WU-8 renders the link inert on mismatch + a badge. **Accepted v1 cost**, sharpest for UC-1's compile session |

## 11. Out of scope

Host-key identity checks (§4.5 — unnecessary once only the operator can add machines);
per-tool-call routing; multiple machines per turn; cross-machine workdir anchoring (v1
already gives two machines two disjoint filesystems because the remote path roots at
`scWorkspace` — only *anchoring a child across machines* needs a transfer); OS/load
routing; per-machine vaults; IPv6 targets; a `/machine` re-pin command (remedy is a new
session); `seal exec-machine` CLI group; fixing #347's artifact property or #348.

**Adding machines from the web UI has moved *into* scope** (WU-7). It was a non-goal
when the inventory was hand-edited only; under §4 it is the control.
