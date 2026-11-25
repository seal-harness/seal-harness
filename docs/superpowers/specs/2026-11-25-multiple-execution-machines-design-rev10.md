# Multiple execution machines — revision 10

Status: **draft, round 6.** Round 5 returned 5/5 NEEDS_REVISION again — all five
completed. Applied below. Two were real design holes I introduced (a `POST` upsert that
re-points pinned sessions, and no cache invalidation after adding a machine); the rest
were count slips and stale signatures. **The doc has not reached 5/5 approval.** See the
closing note.
Supersedes rev 9, 8, 7, 6, 5, 4 and 3c. Date: 2026-11-25. Branch:
`exec/multiple-machines`.
## Revision log — what changed from rev 9

**Two real design holes, both mine:**

1. **`POST` as an upsert re-pointed pinned sessions — the exact thing §4.6 forbids by
   name.** §4.6 said "there is no `PUT` because an in-place host change would silently
   re-point every session pinned to that name", then defined `POST` as an upsert
   returning `200` on replace. `POST {name:"builder", host:"evil"}` *is* that in-place
   host change, and it bypassed both DELETE guards: no pin count, no `?force`, no audit
   line. On the one route a passkey holder reaches. Now guarded identically.
2. **No invalidation after adding a machine.** `NewTabComposer`'s picker reads
   `useMachines` at mount; nothing refetched after a write. So the operator adds their
   first machine at `/machines`, opens a New Tab, and the picker is *still* hidden until
   a page reload — the feature looking broken in its first thirty seconds. The
   precedent is one line: `BeReposChanged` → `repos-changed` → `useRepos`.

**Two of my errors that five revisions of review had not caught:**

3. **`Session/Workdir.hs:182` is a ninth derivation site** (`mkSessionExec` calls
   `untrustedExecConfigFromSecurity` directly, and it is what actually builds the
   `UntrustedIO`/`WorkdirFs` pair). §2 listed eight, and `Session/Workdir.hs` appeared
   nowhere in the doc — the same class as rev 8's "helpers that do not exist".
4. **`AccessControlHandle` is not in `ApiDeps`.** Round 4's fix ("WU-7a refuses unless
   `acsMode == AccessPasskey`") is unimplementable as scoped: `gatewayApp` takes the
   handle *outside* `ApiDeps` (`Server.hs:63`), so adding it breaks all 38 construction
   sites. Moved into `AccessControl.decide` as a passkey-required path predicate —
   ~6 lines, where the auth gate already lives.

**Also applied:** a dangling `default` naming an absent machine had no row and fell to
`WhereLocal` (new row 1b + codec rule); `POST`'s body carries `default` and the writer
validates the *resulting* document (otherwise the screen cannot create the
≥ 2-machines-with-no-default state the route then cannot repair); route count is
81 → 83 in WU-7a and 83 → 84 in WU-7b (rev 9 had WU-7a shipping 2 of 3 routes while
bumping to 84 — a red `make check`); `MachineInfo`'s `local` row now says the ssh fields
are omitted; `renderTargetError` takes the real paths rather than hardcoding `~/.seal/`
(all other code honours `SEAL_HOME`); the picker gains a sentinel option so a present
`exec_machine` really does mean a deliberate choice (§9's instrument claim); `POST`
warns — does not refuse — on a loopback host, since the denylist is gone and the
consequence is now a *diagnostic* one; `group` sanitisation moved out of WU-2 into its
own unit (it is an independent pre-existing escape, not load-bearing for §4.3).

**Count slips, fixed and now checked mechanically rather than by eye** (four renderings,
not five; seven resolution rows, not five; fourteen units, not ten — WU-1b/6b/7a/7b/7c/10
are all headings; duplicate `host:port:user`, not `host:port`). A script asserts the unit
headings and the §8 test rows are 1:1. Counting by eye has been wrong in four
consecutive revisions, which is why the check is now a script.

---

## Revision log — what changed from rev 8

Round 4 was the first round where all five reviewers returned. Four of the five
converged on the same three defects, which is why they are worth trusting.

**Verified errors of mine:**

1. **"Passkey-gated" was false.** `decide` short-circuits `AccessOpen -> AuthAllow`
   for *every* path (`AccessControl.hs:305`), and `access_mode = "none"` is a
   documented supported choice. So under `allow_localhost = false` + `AccessOpen` +
   a non-loopback bind, a remote agent's `SHELL_EXEC` could `curl -XPOST
   /api/machines` and add one — exactly the escalation §4.3 claims is impossible. The
   §8 test ("401 without a passkey session") could not pass on an `AccessOpen`
   fixture, so the doc asserted something the code does not guarantee. Fixed by
   requiring **`AccessPasskey` specifically** (§4.2), which also makes the test
   honest.
2. **§4.2's write-mechanism row described both columns wrongly.** `writeSecretFile`
   opens with `trunc = True` and writes **in place** — not atomic; a partial write
   leaves a truncated inventory, i.e. `TargetConfigLoadError` and every turn failing
   closed. The atomic helper is `writeAtomicText` (unexported). `saveRepoRegistry` is
   atomic (`.tmp` + rename) but default-mode, not 0600. The right answer is
   `saveRepoRegistry`'s shape, not `writeSecretFile`'s.
3. **Route arithmetic was wrong twice and self-contradictory.** 81 (verified at
   `ApiRouteSpec.hs:19`) + GET + POST + DELETE = **84**. The doc said 82 in one place
   and 83 in another.

**Design gaps the reviewers found that I had not:**

4. **`default = "local"` with `allow_localhost = false` had no row.** Row 0 guards
   *pins*, not the *default*, so that config resolved `WhereLocal` — falsifying §1.1,
   the sentence the whole design rests on. New row 1a.
5. **`resolveTarget` took `Maybe UntrustedExecFileConfig`**, delegating "what does
   `Nothing` mean" to the implementer — and a `maybe True` there silently reintroduces
   the exact hardened-build bug rev 6 shipped. Takes a resolved `Bool` now.
6. **`allowLocalhostFrom`'s type was not total over absence.** `scUntrustedExec ::
   Maybe …` (`Security.hs:124`) is where absence lives, so the accessor takes
   `Maybe`.
7. **`updateExecutionConfig` / `executionWriteLock` / `saveExecutionConfig` do not
   exist** — rev 8 cited them as if they did. WU-2 now ships them; WU-7a only calls.
8. **Deleting the *implied* default silently moves unpinned sessions onto `local`**
   — the mirror of §9 criterion 3, one DELETE away, and unmeasured.
9. **No UI for the now-in-scope write route**, and the picker renders only at
   `≥ 2` machines — i.e. hidden in exactly the zero-and-one state where a machine must
   be added. This is a real fork, not a text fix: see WU-7a/7c.
10. **Criterion 1 was not direction-symmetric** — it counted pinned-to-non-default
    only, so an operator who defaults to `builder` and uses it daily would score 0%
    and lose the feature. Measures the split both ways now.

Dead material removed: `ExecutionConfig`'s undefined shape, the stale "pre-filtered"
parameter comment, §11's stale §4.5 pointer, WU-3's test row that was a commit
instruction, and the "nine (ten if…)" ambiguity (now fourteen units).

---

## Revision log — what changed from rev 7

Two things, one of them a design decision rather than a correction.

**1. The localhost denylist is deleted (§4).** Rev 7 tried to refuse "known-local"
targets: loopback literals, numeric re-encodings, `127.0.0.0/8`, interface addresses
from `localAddressNames`, `nodeName`/FQDN, plus a deferred host-key layer to defeat
port forwarding. The human's call: **trust the authenticated operator.** A machine
entry naming `localhost` is the file owner's decision, and an address denylist cannot
bind the principal who owns the file, can edit `allow_localhost`, and has shell access
as the same user. It defended against the wrong actor.

Replaced by a control that already exists: `accessControlMiddleware` is default-deny
(`AccessControl.hs:341-352`), so `POST /api/machines` is passkey-gated for free,
following `POST /api/repos` exactly. The guarantee becomes *no agent-reachable path can
add, remove, or edit a machine* — three tests, §4.3. `allow_localhost` now gates the
**fallback** only. Net: ~40 lines out of WU-3, one write route into WU-7a, and the
"adding machines from the web UI" non-goal moves in scope because it *is* the control.

**2. All ten round-3 blockers are applied.** Three were my own verified errors: WU-4's
"no arity change ⇒ no sweep" (false — `-Wmissing-fields` is in `-Wall`, so all 75
literals break); "the ControlPath change is invisible to the suite" (false — five
assertions compare it exactly); and "invalid ⇒ `TargetUnknownMachine`" (impossible —
`readSessionMeta :: IO (Maybe …)` has no error channel, so it is rescoped to row 0).
The rest: legacy activation gated on `mode`; §5 row 0 so a removed machine's pin fails
closed; inheritance fails closed rather than falling back to `WhereLocal`; the `-f`
coercion applies to the field default and gets its own unit (WU-9); `group` sanitisation
into WU-2; `ApiTestHarness` re-typing (32 refs) and the terminal-backend selectors into
WU-5; `MachineName` derives `Ord`; WU-2 owns the `Seal.Config.Security` edits;
`renderTargetError` gets a test row; `erMeta.machine` dropped to a follow-up. WU-7 became WU-7a/7b/7c.

---

## Revision log — what changed from rev 6

Round-3 gate returned NEEDS_REVISION from both reviewers. **Three of the ten
blockers were my own errors, verified against source:**

| Change | Why |
|---|---|
| **WU-4: the 77-site sweep is unavoidable, not eliminated** | I claimed "no arity change ⇒ ~100 edits avoided". False: `-Wmissing-fields` is part of `-Wall` (`seal-harness.cabal:33`, `-Werror`), so **every named-field `SessionMeta` literal breaks** the moment the field is added — all 77 (73 test / 4 src). Mitigation named: a `defaultSessionMeta`-based constructor so each site adds one line rather than re-listing 14 fields |
| **§6.4/§6.3: the ControlPath change is NOT invisible to the suite** | Rev 6 said "insertion is invisible to the assertions". True for *flag insertion*, false for the *ControlPath value*: five assertions in `RemoteSpec.hs` compare it, and they are enumerated once in §6.4. Those five are part of WU-1b. |
| **§6.1: fail-closed decode has no error channel** | `readSessionMeta :: IO (Maybe SessionMeta)` and `decodeFileStrict` collapse every parse failure to `Nothing` — and **30 call sites** depend on that type. Rev 6's own test ("invalid ⇒ `TargetUnknownMachine`, not `Nothing`") could not pass. Resolved by scoping: a *renamed* machine is already caught by §5 row 0, so only *malformed* text is in question, and for that, `Nothing` + a load-time warning is correct — making the whole `session.json` undecodable would render the session unreadable, which is worse than the silent move it prevents |
| **§5: inheritance fails closed instead of falling back** | Rev 6's "fall back to the default and warn" can land `WhereLocal`: `allow_localhost = true`, one ssh machine, no explicit `default`, session pinned to it, machine renamed ⇒ child falls to row 3 ⇒ **untrusted subagent code on the harness kernel** with only a warning. A dead pin is now a `TargetError`, full stop |
| **§1.4: the `-f remote-only-untrusted` coercion applies to the default, not just a present section** | Otherwise a hardened build with **no** `security.toml` keeps `allow_localhost = true` and yields `WhereLocal`. `mkLocalUntrustedIO` has no CPP guard, so this value is the only thing between the hardened build and local execution |
| **§3.1: the writability claim is corrected; `group` sanitisation added to WU-2** | `FILE_WRITE` is contained under `WorkspaceRoot`, so `~/.seal` is out of *its* reach — but `SKILL_WRITE`/`AGENT_DEF` write locally via `defPath`/`skillPath` with an unsanitised `group` (`Skills.hs:92-97`, `T.strip` only). `group = "../../.."` escapes. It cannot forge `execution.toml` **only because `.md` is unconditionally appended** — accidental, not designed. Sanitisation is now a WU-2 deliverable |
| **`selectExecBackend`/`selectUntrustedBackend` get an owner (WU-5)** | They branch on `UemLocal`/`UemRemote` (`Untrusted.hs:88-118`) and will not compile once `UntrustedExecMode` is deleted. Zero production callers (tests only), so no live hole — but they are a second, parallel authority-decider |
| **`ApiTestHarness` re-typing is costed in WU-5** | **32** test references to `UntrustedExecMode`/`UemLocal`/`UemRemote`, and `buildTestEnv :: FilePath -> UntrustedExecMode -> …` is the harness's spine (`:413`, `:496`, `:498`, `:542`). Until it is re-typed to `ResolvedTarget` + `execution.toml` fixtures, `mode` cannot be deleted at all |
| **`MachineName` derives `Ord`**; WU-2 owns the `Seal.Config.Security` edits | Both compile-level omissions. `mode` is `Toml.text` (required, `Security.hs:453`), so making it optional *is* a `Security.hs` edit |
| **`erMeta.machine` dropped** | The doc itself says it is not the deciding metric. It is the largest churn item (92 sites, a third `UIOEnv` field) for no user-visible capability. Kept as a follow-up gated on criterion 1 being ambiguous. `erMeta.machine` remains the right *diagnostic*, just not v1 |
| **`renderTargetError` gets a §8 test row** | Rev 6's log claimed its strings were pinned while §8 had no cycle for the renderer |


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
| **WU-6: the web and chat mint paths must carry `machine`** | `mintBody`/`rebindBody` (`Chat/HttpClient.hs:223-238`) have no machine field, and `handleSessionNew`/`handleSessionRebindNew` do not accept one, so `/new --machine` from Telegram/Signal parsed the flag and **discarded it** |
| **`machines` always includes `local` when `allow_localhost`; new `resolvable` flag** (now WU-7b) | Rev 5's `{default: null, machines: []}` contradicted §8's own test. And with `allow_localhost = false` + no inventory the New Tab form minted a session whose every turn fails closed |
| **The Files link goes inert on mismatch**, not merely badged (now WU-8) | `OpenWorkdirLink` builds `/files?path=…` and the explorer is boot-time global, so a `builder` session's link opened a nonexistent local path |
| **`TargetError` splits `TargetConfigLoadError` from `TargetNoMachine`; `renderTargetError` added; every rendering pinned** | One free-text field cannot distinguish "fix your TOML syntax" from "no machine is configured at all" — and row 4's message is the only outcome a hardened install ever sees |
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

### 1.2 `false` means: no tool call may *fall back* to this machine

`allow_localhost = false` gates the **fallback**: when it is `false` and no machine
applies, resolution returns `TargetNoMachine` (§5 row 4) and nothing runs. It does not
gate an inventory entry that resolves to this host — §4.5 records that consequence. It is not
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
field to a `Bool` (`allowLocalhostFrom :: Maybe UntrustedExecFileConfig -> Bool`),
which is total over the absent case because absence lives at `scUntrustedExec ::
Maybe UntrustedExecFileConfig` (`Security.hs:124`). `mkLocalUntrustedIO` has **no** CPP guard
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
`SshConfig`, and that one value is **re-derived independently at nine live
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
| **`Session/Workdir.hs:182`** | **`mkSessionExec` — builds the `UntrustedIO`/`WorkdirFs` pair. Missing from every revision before rev 10** |

(`Channel/Cli.hs:474` is a tenth, dead — `untrustedIOFromSecurity`, zero callers.)

**The ninth site was missing from rev 9 and every revision before it.** The file
`Session/Workdir.hs` appeared nowhere in the design; a unit scoped against an incomplete
map is the same class of error as rev 8 citing helpers that did not exist.

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
  `cargo build` failure is diagnosable · WHEN opening the session (the surface is
  WU-8's chat-header badge; the session *list* is not touched in v1, stated here so the
  use case does not promise a surface no unit delivers).

- **UC-5 — knowing the feature exists.** WHO an operator with zero or one machine ·
  WANTS to learn that more machines can be added, and that a second one gives
  per-session choice · SO THAT they can reach the write route without reading a design
  doc · WHEN they open the Machines screen or the New Tab form.

  Named for **discoverability**, which is what WU-7c delivers (an empty state that says
  why it is empty, and a hint at exactly one ssh machine). The other half of the
  journey — an operator with zero machines adds one through the screen and a turn runs
  on it — has **one** §8 assertion (WU-7c's ramp row: default install → add a machine → the
  picker renders two options → a session mints there), not a use case. Claiming it under
  UC-5's title without that row would have been the fourth revision to promise an
  activation journey no unit accepts.

UC-5 exists because the previous four rounds kept finding the same defect: five
revisions specified the *picker* and never the *ramp* that populates it. The picker
renders at `≥ 2` machines, so a user with zero or one has no in-product signal that the
feature exists — WU-7c's empty-state copy and its `==1` hint are that signal, and they
are the whole of UC-5's delivery.

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
# Hand-editable, but the supported path is the Machines screen (WU-7c), which posts to
# /api/machines (WU-7a). No opcode can read or write this file (§4.3).
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
`SKILL_WRITE`/`AGENT_DEF` — is closed by **WU-10's** sanitisation.

The residual — a cloned dotfiles repo carrying a localhost entry — arrives as an
operator action in a file they version-control. §4.5 records that as the accepted
trade.

### 3.2 Field validation

| Field | Req? | Rule |
|---|---|---|
| machine name | **yes** | `MachineName`: `[A-Za-z0-9_-]`, non-empty, no leading `.`, ≤ 64. Rejects leading `-`. `local` and `default` are reserved |
| `host` | **yes** | `mkSshHost` **plus a leading-`-` rejection** (§6.2) |
| `user` | **yes** | `mkSshUser` **plus a leading-`-` rejection** |
| `port` | no (22) | `1..65535` (D12: `fromMaybe 22` has no range check today, `Security.hs:780`) |
| `identity` | no (ssh-agent) | absolute, no `..`, no `blockedNames` segment **except** `.ssh`/`.seal`; **no whitespace, no `=`** (§6.2) |
| `known_hosts` | **yes** | same rule as `identity`. Required because it is half of the mux-key hash (§6.4) — an optional value would make the key unstable |
| `workspace` | **yes** | `mkRemotePath` (rejects empty, leading `-`, control chars) |
| `default` (top-level key) | no | must name `local` (only when `allow_localhost`) or a machine in the inventory — otherwise `Left TargetConfigLoadError`. Row 1b in §5 relies on this |
| unknown keys | — | **decided**: a warning at load, not an error — a typo'd `identiy` silently defaulting to ssh-agent is the failure this catches |

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

| | `POST /api/repos` (existing) | `POST /api/machines` (new, WU-7a) |
|---|---|---|
| Gated by `accessControlMiddleware` | `AccessPasskey` only — see below | **`AccessPasskey` only**, enforced explicitly |
| Writes a file in `config/` | `repos.toml` via `updateRepoRegistry` | `execution.toml` via `updateExecutionConfig` (WU-2) |
| Serialised by a process lock | `repoRegistryWriteLock` (`SourceControl/Registry.hs:77`) | `executionWriteLock` (WU-2) |
| Written atomically | yes — `.tmp` + rename (`Registry.hs:57-62`) | same shape; **not** `writeSecretFile` |
| File mode | default (umask) | default — it holds paths and hostnames, not secrets |
| Reachable by an opcode | **no** | **no** |

**"Authenticated-session-gated" is the accurate term** — `hasServiceToken`
(`AccessControl.hs:313`) admits an in-process bearer token on any non-auth path in
`AccessPasskey` mode. That token is minted in memory, never logged and never in the
environment, and a same-uid shell already dominates it (§4.5), so it is not a new class;
but "passkey-gated" overstates the predicate.

**And it is not automatic: rev 8 was wrong to say it was.** `decide`
short-circuits `AccessOpen -> AuthAllow` for *every* path (`AccessControl.hs:305`),
and `access_mode = "none"` is a documented supported choice meaning "anyone who can
reach the gateway has full control". Under `allow_localhost = false` + `AccessOpen` +
a non-loopback bind, a remote agent's `SHELL_EXEC` could `curl -XPOST
/api/machines` and add an execution machine — the escalation this section claims is
impossible. So WU-7a must **refuse machine mutation unless `acsMode == AccessPasskey`**
(`403`, same shape as `AuthSetupRequired`). This is the one surface where "the
operator waived authentication" must not be read as "the operator waived *granting
execution authority*".

**The write mechanism is `saveRepoRegistry`'s, not `writeSecretFile`'s.**
`writeSecretFile` opens with `trunc = True` and writes **in place** (`Security.hs:578`)
— a partial write leaves a truncated inventory, so every subsequent turn fails closed
with `TargetConfigLoadError`. `saveRepoRegistry` writes `path.tmp` then `rename`s
(`Registry.hs:57-62`), which is the property that matters. Mode is the default, like
`config.toml` and `repos.toml`: `0600` on a file whose whole purpose is to be
git-committed is a needless deviation, and git only records 100644/100755 anyway.

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

  **WU-10 adds charset sanitisation to `group`** (`[A-Za-z0-9_-]`, rejecting `.`/`..`/
  separators) with a test that `group = "../../.."` is refused. This is the one place
  where trusting the operator is not enough, because the hole is an *agent* write
  primitive that happens to be aimed at the operator's config tree.

Under `allow_localhost = true` the agent can write the inventory and it does not
matter — local execution is already permitted, so no entry gains authority.

**Scope note — this is not an audit of every write primitive in the harness.** Only
primitives whose path could reach `config/execution.toml` are in scope. `MEMORY_WRITE`
writes under `~/.seal/memory/`, and the memory system is unrelated to execution
machines; it is mentioned solely so a reader does not mistake this section for a
complete enumeration.

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
- **A localhost-named entry under `allow_localhost = false` is not refused.** The
  session resolves `WhereSsh` while executing on this kernel, so remote-assuming
  surfaces behave as remote locally — `cdIsRemote` picks the deploy-key clone path and
  the explorer's fail-closed posture is chosen for a target that is not remote. The
  operator asked for it, but the *mislabelling* is a consequence worth recording.
- **The guarantee is point-in-time, not durable.** §4.4's "under `allow_localhost =
  true` it gains nothing" holds at that moment. But `true` is the **default**, so every
  install starts in the state where an agent with a local shell can pre-plant a
  `[machines.x]` entry that becomes meaningful the day the operator sets
  `allow_localhost = false`. Not fixable here — a same-uid shell can already write
  `security.toml` today, so this adds no new class — but the recommendation is: set
  `allow_localhost = false` **before** the first agent session *and review
  `execution.toml` and `security.toml` for entries you did not write at the moment you
  flip it.*

The guarantee this buys instead is narrower and *true*, and it must be stated with its
qualifier: under `allow_localhost = false`, **no opcode-reachable path can change which
machines exist.** That is additionally conditional on the inventory containing no entry
that resolves to this host: `allow_localhost = false` forbids the *fallback*, not such an
entry, and with one present `SHELL_EXEC` runs a shell as the gateway's uid here — the
same-uid class recorded in the last bullet below, reached under `false` rather than
`true`. The two conditions together are the honest statement. §4.4 concedes that under `allow_localhost = true` — the default — an
agent with a local shell *can* write the inventory; what it cannot do is gain anything,
since local execution is already permitted. Rev 9 stated the sentence unconditionally,
which made the very tests that assert it capable of certifying a false property.

### 4.6 `DELETE` semantics: the **explicit** default is the dangerous one

Two distinct deletions, and only one of them is obvious:

- **A machine named by the explicit `default` key** — refusing is easy and already
  stated.
- **The *explicit* default.** This is the silent-move population. Deleting the machine
  named by an explicit `default` leaves that key **dangling**, which §5 row 1b catches —
  but a `?force` delete that also removes the key leaves unpinned sessions resolving
  through rows 2/3, i.e. onto `local` under `allow_localhost = true`. One `DELETE` away.
- **The *implied* default is NOT a silent move, and rev 10's earlier text got this
  backwards.** When `default` is absent, the inventory has one ssh machine and
  `allow_localhost = true`, §5 keeps **`local`** as the default (§5's rule exists
  precisely so that writing the first machine does not move anyone). So deleting that
  machine moves nothing, and under `allow_localhost = false` it leaves zero machines ⇒
  row 4 `TargetNoMachine` — loud, not silent. The guard is still worth applying for the
  explicit case; the "implied" branch of the original text resolved to `local`, whose
  deletion is already a `400`.

So `DELETE` must:

1. compute the **effective** default (explicit *or* implied, §5), and refuse to remove
   it unless `?force=true`;
2. if the machine is pinned by sessions, refuse unless `?force=true` **and report the
   pin count** in the refusal body. The count is a bounded `session.json` walk — cheap,
   not free — and §9 already specifies the grep (honour `SEAL_HOME`);
3. log the removal at audit level with the count.

`POST` is an **upsert**: `201` on create, `200` on replace — **and a replace is guarded
exactly like the `DELETE` it would otherwise be**. Rev 9 said "there is no `PUT` because
an in-place host change would silently re-point every pinned session", then allowed
`POST {name:"builder", host:"evil"}` to do precisely that, bypassing both DELETE guards.
So: on a `POST` whose name already exists and whose `host`/`port`/`user`/`identity`/
`known_hosts`/**`workspace`** differs, apply guard (2) verbatim — refuse without `?force`, report the pin
count, audit the change.

`POST`'s body carries an optional `default`, and the writer validates the **resulting**
document (including the ≥ 2-machines-need-a-default rule) before the rename. Without
this the screen cannot create the very state the route then refuses to repair, because
`updateExecutionConfig` loads the file first.

**Removal does not touch live exec caches.** `invalidateExec` (WU-5) is keyed by
session, and the cache's memo key includes the target (`(SessionId, ResolvedTarget)`),
so a deleted machine's next turn rebuilds, hits row 0/1b, and fail-closes. No cascade
eviction is needed, and the design should say so rather than leaving the reader to
wonder whether a stale in-memory `SessionExec` can outlive the entry. It cannot: the
resolved-target key changes the moment the machine is gone.

`DELETE` answers `204` with no body on success; `400` on `DELETE /api/machines/local`,
since `local` has no `[machines.local]` row to remove and exists only when
`allow_localhost = true` (it is a reserved name, not an entry). `409` with a **typed** body `{error: string, pinned: Int, unpinned: Int, fallback: string|null}`
on refusal without `?force` (`fallback` is the machine unpinned sessions land on; `null`
means `TargetNoMachine`). Guard (2) reports **unpinned** sessions too —
they are the population that silently moves when the effective default is removed, and
guard (2) as written in rev 9 counted only the pinned ones.

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
  | TargetNoMachine                                   -- nothing may run at all
  deriving stock (Eq, Show)

renderTargetError :: TargetPaths -> TargetError -> Text
```

**Four constructors, four renderings**, pinned here so the implementer does not invent
the only errors a hardened install ever sees:

| Constructor | Rendering |
|---|---|
| `TargetUnknownMachine n avail` | `No execution machine named "<n>"; available: <avail>. Start a new session pinned to one of them, or add one on the Machines screen.` |
| `TargetLocalNotAllowed n` | `machine "<n>" runs on this host, but allow_localhost = false in <security.toml>. Set allow_localhost = true, or start a new session pinned elsewhere.` |
| `TargetConfigLoadError why` | `<execution.toml>: <why>` (the codec's field-specific `Left` becomes the payload) |
| `TargetNoMachine` | `No execution machine is configured. Add one on the Machines screen, or add a [machines.<name>] block to <execution.toml>, or set allow_localhost = true in <security.toml>.` (The third clause is inert under `-f remote-only-untrusted`, which forces the flag false — WU-9. Kept because the string is shared and only one clause is wrong in that build.) |

The paths are **parameters, not literals**: `renderTargetError :: TargetPaths ->
TargetError -> Text` where `tpExecution`/`tpSecurity` are derived from `SealPaths`.
Everything else in this codebase honours `SEAL_HOME`; hardcoding `~/.seal/` would print
the wrong path on any non-default install, and `TargetNoMachine` is the only message a
hardened install ever sees. `TargetNoMachine` is **nullary** — rev 9's `Text` payload
was read by nothing.

The copy names the **Machines screen** as the first remedy, not just the file: §4 calls
WU-7a the control, and a message that points only at hand-editing sends the blocked
operator away from it.

`TargetConfigLoadError` and `TargetNoMachine` are **separate** because their remedies
are unrelated (fix your TOML syntax vs. write an inventory) and one free-text field
cannot say which. `TargetNoMachine`'s is the only outcome a hardened install ever sees,
so it names **both** remedies.

```haskell
data ExecutionConfig = ExecutionConfig
  { ecDefault  :: Maybe MachineName                  -- ^ the `default` key, if present
  , ecMachines :: Map MachineName SshMachineSpec     -- ^ the decoded [machines.*] tables
  }

resolveTarget
  :: ExecutionConfig        -- ^ decoded and validated; no address policy applies
  -> Bool                   -- ^ allow_localhost, from `allowLocalhostFrom` ONLY
  -> Maybe MachineName      -- ^ the session pin
  -> Either TargetError ResolvedTarget
```

The second parameter is a resolved `Bool`, **not** `Maybe UntrustedExecFileConfig`.
Rev 8 passed the `Maybe` and left "what does `Nothing` mean" to the implementer — and
`maybe True uefcAllowLocalhost` compiles, passes every non-CPP test, and silently
reintroduces the exact hardened-build bug rev 6 shipped. The value must be able to come
from one place only:

```haskell
allowLocalhostFrom :: Maybe UntrustedExecFileConfig -> Bool
```

`Maybe`, because absence lives at `scUntrustedExec :: Maybe UntrustedExecFileConfig`
(`Security.hs:124`) — rev 8's `UntrustedExecFileConfig -> Bool` could not express the
case §1.4 depends on. Under `-DREMOTE_ONLY_UNTRUSTED` it returns `False`
unconditionally, which is WU-9.

| # | Condition | Result |
|---|---|---|
| 0 | **pin present and unresolvable** — not in the inventory, or `local` while `allow_localhost = false` | `Left TargetUnknownMachine` / `Left TargetLocalNotAllowed` |
| 1 | pin names a machine (incl. reserved `local` when `allow_localhost`) | `WhereSsh` / `WhereLocal` |
| 1a | **effective `default` names `local` while `allow_localhost = false`** | `Left TargetLocalNotAllowed` |
| 1b | **effective `default` names a machine that is not in the inventory** | `Left TargetConfigLoadError` (dangling default; WU-2 also makes it a load error) |
| 2 | else an effective `default` names an ssh machine | `WhereSsh` |
| 3 | else `allow_localhost = true` | `WhereLocal` |
| 4 | else | `Left TargetNoMachine` — nothing may run |

Rows are **first-match-wins**, and rows 1a/1b/2 concern only the *effective default* —
they are reached only when no pin resolved (rows 0/1). Row 1b exists because a
**dangling** `default` — `default = "builder"` after `[machines.builder]` is renamed or
`DELETE`d with `?force` — would otherwise skip row 2 and fall to row 3, moving every
unpinned session to `WhereLocal`. That is §6.1's defect one level up. The codec makes it
a load error as well, and `DELETE` removes or refuses the key it names (§4.6).

**Row 1a is the row that makes §1.1 true.** Row 0 guards *pins*; it does not guard the
*default*. `execution.toml` with `default = "local"` and
`allow_localhost = false` would otherwise reach row 2 and resolve `WhereLocal`, which
falsifies the one sentence this design rests on. The codec (WU-2) additionally makes
`default = "local"` a **load error** when `allow_localhost = false`, and legal when
`true` — belt and braces, because the resolver must be correct independently of the
codec.

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
string (`Session/AgentMetaCache.hs:186-196`) and `GIT_SSH_COMMAND` (`SourceControl/Clone.hs:481`) also
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
`ControlPath` *value*. `RemoteSpec.hs:236,241,242,247,252` compare it exactly
(`checkAdjacentPair argv "ControlPath" (home </> ".seal/ssh-mux/m-%C")`), and `:252`
asserts the `-m-%C` suffix. Those five are part of **WU-1b's** commit — WU-1 is pure and produces no argv.

Similarly §6.3's `-F /dev/null` insertion **is** invisible — every ssh-argv assertion
elsewhere is membership- or adjacency-based, and `grep 'argv !!'` finds zero positional
assertions — but only because it inserts rather than replaces. Worth stating which is
which, so the next reader does not assume both are free.

### 6.5 Layering

`resolveTarget` takes `ExecutionConfig` and a resolved `Bool`, not `SecurityConfig` —
naming a type in a signature *is* importing it, so rev 4's "neither imports
`Seal.Config.Security`" was false, and rev 9's `Maybe UntrustedExecFileConfig` had the
same problem plus a non-total default. `Seal.Security.Path` imports zero `Seal.*`
modules (verified), so `Seal.Execution.Types` stays a leaf.

## 7. Work units

**Fourteen units.** Additive. Demo at WU-6. WU-1b/7a/7b/7c are first-class units, WU-6
splits into 6/6b (the chat half does not gate the demo), and `group` sanitisation is
**WU-10** — extracted out of WU-2 because it is an independent pre-existing escape, not
load-bearing for §4.3, and bundling a live security fix behind this feature's critical
path is exactly what to avoid. `erMeta.machine` is dropped (§9).

### WU-1 — `Seal.Execution.Types` (pure)
`MachineName` (+ reserved `local`/`default`), `SshMachineSpec` (validated newtypes),
`ResolvedTarget` (**needs `Ord` on itself and on `MachineName`**), the
four-constructor `TargetError`, `renderTargetError`,
`sshConfigFromMachine :: SshMachineSpec -> SshConfig` (total),
`targetLabel :: ResolvedTarget -> Text`,
`targetSshConfig :: ResolvedTarget -> Maybe SshConfig`, and

```haskell
data TargetPaths = TargetPaths
  { tpExecution :: Text   -- ^ from SealPaths (executionFilePath), never a literal
  , tpSecurity  :: Text   -- ^ from SealPaths (securityFilePath)
  }
```

`TargetPaths` is built by WU-3's call sites from `SealPaths`; it exists so
`renderTargetError` never hardcodes `~/.seal/` (§5). It was referenced by two
signatures in rev 10 and declared by none — the same "cites something that does not
exist" defect as rev 8's helpers.

**Also in this commit, in `Seal.Tools.Exec.Types`:** `deriving Ord` on `SshHost`
(`:124`), `SshUser` (`:139`) and `SshConfig` (`:83-91`), plus the leading-`-` guard in
`mkSshHost`/`mkSshUser` (§6.2). `ResolvedTarget`'s `Ord` does not compile without
them, and `RemotePath` already has it. Cabal wiring in the same commit (a module in no
stanza is never typechecked). Prefixes `smsHost`/`smsUser`/… to match `scHost`/
`naProvider` style.

### WU-1b — §6.3 + §6.4 across the ssh argv builders

`-F /dev/null -o ProxyCommand=none -o ProxyJump=none` in all four builders
(`sshExecArgv`, `sshExecArgvForwarding`, the rsync rsh string in
`Session/AgentMetaCache.hs:186-196`, `GIT_SSH_COMMAND` in `SourceControl/Clone.hs:481`); the
`identity`+`known_hosts` hash folded into `ControlPath`; the stale comment at
`Remote.hs:154-156` corrected. **Five assertions update with it**
(`RemoteSpec.hs:236,241,242,247,252`).

A separate unit rather than folded into WU-1, for two reasons: WU-1 is subtitled
"pure" and this is not (rev 6's "invisible to the suite" error was exactly this
mis-scoping), and WU-1 is the foundation for eight other units — folding ssh argv
details into it puts the whole feature's critical path behind them. §6.5's layering
claim survives the split either way: it is a claim about *imports*, and nothing new is
imported (the edits land in modules already below `Seal.Execution.Types`).

### WU-2 — `execution.toml` codec + `loadExecutionConfig`
`Seal.Config.Execution`: the codec (§3.2 validation, reserved names, duplicate
`host:port:user` rejection, unknown-key warning), `executionFilePath :: SealPaths ->
FilePath` added to `Seal.Config.Paths`, `loadExecutionConfig`, and a
comment-only template + `extra-source-files`. *(Moved ahead of the resolver — rev 4
had WU-2 depending on a codec that did not yet exist, so `make check` could not
pass.)*

**This unit also owns the write side**, because rev 8 cited helpers that do not exist
(`rg 'saveExecutionConfig|updateExecutionConfig|executionWriteLock'` → zero hits):

- `saveExecutionConfig` — `path.tmp` + `rename`, mirroring `saveRepoRegistry`
  (`SourceControl/Registry.hs:57-62`). **Not** `writeSecretFile`: it opens `trunc = True` and writes
  in place, so a partial write leaves a truncated inventory and every turn then fails
  closed.
- `updateExecutionConfig` — read-modify-write under the lock, with the round-trip
  verification `updateAccessControlSection` uses (`Security.hs:642-650`).
- `executionWriteLock` — dedicated, not shared with `securityWriteLock`
  (mirroring `repoRegistryWriteLock`'s "DEDICATED, not shared" comment).
- **The legacy-block synthesis** (§1.5): the implicit machine `default` from a
  complete `[untrusted_execution.remote]` is built *here*, because WU-2 is the only
  place that sees both configs. Without this clause the unit is unwritable as scoped.

**If WU-2 proves too large in practice, the seam is between the read side and the
writer**: the codec + `executionFilePath` + template + legacy synthesis + the
`Seal.Config.Security` deprecation edits form one coherent commit (the synthesis needs
both codecs), and the writer trio (`saveExecutionConfig`/`updateExecutionConfig`/
`executionWriteLock`) could move to WU-7a, its only caller. Named so the split is a
mechanical decision during implementation rather than a redesign. **If the seam is
taken, the writer's §8 row moves with the trio** — otherwise the split silently
re-creates the double-ownership this revision just fixed.

**The writer's three tests ship with the writer**, not with its caller (AGENTS.md rule
4 — a unit ships with its test): a rejected write leaves the file byte-identical; a
concurrency test mirroring `RegistrySpec.hs:126-143`; a write→load→resolve round-trip
(the codec test alone does not exercise the encoder the writer uses). Rev 9 filed all
three under WU-7a, whose code ships later.

**`Seal.Config.Security` edits, also here:**

- `uefcMode :: Text → Maybe Text` (`Security.hs:150`) with `Toml.text "mode"` →
  `dioptional` (`:453`). Required today, so §1.5's "`[untrusted_execution.remote]`
  without `mode` decodes" test needs it. This ripples to `Security.hs:767`
  (`if uefcMode uec == "remote"`) and `untrustedExecConfigFromSecurity`, which both
  assume `Text`. Precedent for the shape: `acfcMode :: Maybe Text` (`:206`).
- `uefcAllowLocalhost :: Maybe Bool`, with `allowLocalhostFrom` deriving from `mode`
  when absent.

**`uefcMode`'s ripples are costed**, not just named — 7 sites the type change breaks:
**one** `shouldBe "local"` assertion (`MigrateSpec.hs:137`) and **six** `uefcMode`
literals — one `"local"` (`SecuritySpec.hs:139`) and five `"remote"`
(`SecuritySpec.hs:158,178,187`, `WorkdirSpec.hs:329`, `ApiTestHarness.hs:766`).

**`group` sanitisation is NOT here** — it moved to WU-10. It returns `Either` from
`skillPath`/`defPath`, rippling `writeSkill`/`writeAgentDef` and both backend records,
and it is not load-bearing for §4.3 (`.md` is unconditionally appended, so the escape
cannot forge `execution.toml` — §4.4 says so itself).

### WU-3 — `Seal.Execution.Resolve`
`resolveTarget` (**seven rows** 0/1/1a/1b/2/3/4, pure), `loadAndResolveTargetIO` (turns a load
failure into `TargetConfigLoadError`). **No address classifier** — the localhost
denylist this unit carried in earlier revisions is deleted (§4.1), making it ~40
lines smaller.

### WU-4 — the per-session pin
`SessionMeta` gains `smExecMachine :: Maybe MachineName`; key `exec_machine`, wire
`execMachine`. `FromJSON` is **explicit**, not derived (§6.1). **`ToJSON` must *omit* the key when
`smExecMachine` is `Nothing`, not emit `null`** — and that is asserted. The surrounding
style in `Session/Meta.hs` is `"repo_url" .= smRepoUrl m`, i.e. `Maybe → null`, so
copying it here would make every post-deploy session carry a *present* key, and §9's "a
present key means a deliberate choice" would be false on exactly the population the
metric uses. This is the same encoder-vs-test agreement WU-7b pins for `MachineInfo`.

**The sweep is unavoidable — rev 6 was wrong about this.** Haskell has no
record-field defaults, and `-Wmissing-fields` is part of `-Wall`
(`seal-harness.cabal:33`, with `-Werror`), so **every** named-field `SessionMeta`
literal becomes a compile error the moment the field is added. Measured by
`scripts/count-sessionmeta-sites.py`: **77 sites across 25 files — 73 test / 4 src**.
(The four src sites: `Delegation/Worker.hs` ×2, `Core/TurnEngine.hs` ×1,
`Session/Store.hs` ×1.) The script excludes `src/Seal/Session/Meta.hs`, which holds the
`ToJSON`/`FromJSON` pair and is hand-written in this unit. Earlier revisions said "75
sites" — wrong, because 73 + 4 = 77; the total and the split disagreed and nobody added
them up. There is no arity change to `newSession`/`newSessionMeta`, but that saves
nothing — the literals are the cost, not the function signatures.

Mitigation, named so this unit is writable: add
`defaultSessionMeta :: SessionId -> UTCTime -> SessionMeta` in `Seal.Session.Meta`, so
each of the 77 sites becomes one record-update line
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

### WU-5 — collapse the nine derivations; delete `execFingerprint`
`mkSessionExec`/`cachedSessionExec` take `ResolvedTarget`; the memo key becomes
`(SessionId, ResolvedTarget)`; `execFingerprint` **deleted**; the `sceExecs` IORef's
type and `CachedExec`'s shape change; `invalidateExec` drops **all** targets for the
sid. `mkSessionUntrustedIO` **deleted** (zero production callers, and it is a
`SecurityConfig`-shaped bypass of the resolver being introduced) — and its
equivalence test deleted in the same commit (`WorkdirSpec.hs:267-276`).

**This unit's file list must name `Session/Workdir.hs`** — `mkSessionExec` (`:182`) is
the ninth derivation site and the one that actually builds the `UntrustedIO`/`WorkdirFs`
pair; it has appeared in no revision before this one. The back-compat wrapper at `:305-312`
(`mkSessionUntrustedIO`) is deleted with it. It uses `targetSshConfig` (WU-1) to recover
the `SshConfig`, which is that accessor's only consumer — the reason it is exported.

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

**The chat and Telegram mint paths are WU-6b's scope, not this unit's** — they are the
half of `/new --machine` that does not gate the demo checkpoint.

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

### WU-6b — the chat and Telegram mint paths

`/new --machine builder` sent from Telegram or Signal parses the flag and then
**discards it**: `src-chat-channels/Seal/Channels/Chat/Loop.hs:1744` sends `mintBody`, and `Chat/HttpClient.hs:223-238` has no
machine field; it POSTs to `handleSessionNew`, which does not accept one. The session
lands on the default — the silent-authority-change class §6.1 exists to eliminate, and a
live bug today. Rev 9 called this "four more edits"; the real count is **7–9 plus two
fixtures**: `mintBody`/`rebindBody` signatures, two handlers with pre-mint validation,
two `400`→`ccSend` relays, the `createBareSession` decision, `createTab`'s swallowed
`!res.ok`, and the composer's `if (res)` inversion (both WU-6's, above). Roughly a day.

Split from WU-6 so the demo checkpoint (CLI + web) does not wait on it.

**Two UI fixes are WU-6's, not this unit's, and are not counted in its budget:** the
`createTab` error-body return and the composer's `if (res)` → `if (!res || !res.ok)`
inversion (both specified in WU-6). Rev 10 listed them in both units; WU-6b only *relays*
a chat 400 through `ccSend` and touches neither.

**Scope decision, stated so it is reviewable either way:** WU-6b ships in the same PR.
The alternative — defer it to v1.1 and have the chat parser **reject** `--machine` with
"not supported in chat" (2 lines) rather than silently dropping it — is defensible, and
cheaper by ~a day, precisely because `--machine` does not exist today: the silent
misroute only becomes reachable when WU-6 adds the flag. If the demo slips, that is the
cut to make first, and rejecting is strictly better than the current silent drop.

### WU-7a — the machine write API (the security control)

Split from 7b so the control lands, and is tested, before any UI depends on it.

`POST /api/machines` (upsert: `201` create / `200` replace) and
`DELETE /api/machines/:name`, with the §4.6 guards. Six constraints, each of which an
earlier revision got wrong or omitted:

1. **Refuse unless `acsMode == AccessPasskey`** (`403`) — enforced in
   `AccessControl.decide` (§4.2), **not** via `ApiDeps`. `accessControlMiddleware`
   alone is not enough: `AccessOpen` short-circuits to allow for every path
   (`AccessControl.hs:305`), so a gateway in `access_mode = "none"` with a
   non-loopback bind would let a remote agent `curl -XPOST` a machine into existence.
2. **Write via WU-2's `updateExecutionConfig`** — `.tmp` + rename under
   `executionWriteLock`. Not `writeSecretFile` (in-place, non-atomic). Default file
   mode, like `repos.toml`.
3. **Body** `{name, host, user, port?, identity?, known_hosts, workspace}` validated by
   WU-2's codec, returning the codec's field-specific `Left` payload, **and a rejected
   write leaves the file byte-identical** (§8).
4. **Warn — do not refuse — on a loopback host.** With the denylist gone (§4.1) the
   consequence of a `localhost` entry is a *diagnostic* one, not an authorization one:
   the session resolves `WhereSsh` while executing here, so `cdIsRemote` picks the
   deploy-key clone path and the Files link goes inert. `POST` returns a `warning` field
   (same posture as unknown-keys: warn, never block) whose text names the
   **consequence**, not merely "this is localhost": *"this entry denotes this host;
   sessions pinned to it will be treated as remote but execute here, so the Files link
   and the deploy-key clone path will both be wrong."*
5. **`stat` the two key paths at write time** and return a field-specific `Left` if
   either does not exist. §3.2 already validates them as absolute, `..`-free and
   `blockedNames`-free; existence is the same class of check, runs on the filesystem the
   writer already owns, and catches the most likely mistake — a typo'd key path — before
   it becomes a mystery turn failure. This is the cheap substitute for the deferred
   test-connection endpoint.
6. **No opcode may reach the writer.** Two assertions: zero `executionFilePath` under
   `src/Seal/ISA/`, and `Seal.ISA.Registry`'s import closure does not contain
   `updateExecutionConfig` — the second catches a re-export that a path-grep misses.

Route work for both routes: `SealRoute` constructor, `allRoutes` entry (a plain list —
`-Werror` will **not** catch an omission), `routeMeta`, `openApiMeta` (both exhaustive
`\case`), and `ApiRouteSpec.expectedRouteCount` **81 → 83** in this unit (GET is WU-7b). The DELETE capture is
`Text` in `seal-gateway-types` and validated in the handler — the same layer constraint
already identified for `naMachine` (`NewArgs.hs` cannot depend on the main library).

### WU-7b — `GET /api/machines` + the dropdown

`GET /api/machines` — `200 {default: string|null, machines: [MachineInfo],
resolvable: boolean, error: string|null}`. Degraded shapes are **200, never 500**; a
malformed file must not break the New Tab form.

**`MachineInfo` carries the full spec**, not `{name, kind, default}` as rev 8 had it:
`{name, kind, default, host, user, port, identity, known_hosts, workspace}`. None of
those are secrets — they are paths and hostnames — and without them the management
screen cannot pre-fill an existing machine, so an operator cannot verify an entry they
added a month ago. **The six ssh-only fields are omitted when `kind == "local"`** (they
are required for `ssh` rows and meaningless for the reserved one); both goldens are
pinned, so the encoder and the test cannot disagree about whether they are `null` or
absent.

**`local` is always in the list when `allow_localhost = true`** — so with no
`execution.toml` the honest shape is
`{default: "local", machines: [{name:"local", kind:"local", default:true}], …}`. The
picker stays hidden by the `≥ 2` rule, so nothing changes visually and the data stops
lying. `machines: []` occurs only under `allow_localhost = false`.

**`resolvable` exists because rev 5 minted doomed sessions.** With
`allow_localhost = false` and no inventory — the state `-f remote-only-untrusted`
forces — the form succeeded, `buildBody` omitted `machine`, the session was created,
and then *every turn* failed closed on row 4. `NewTabComposer` **disables Start** and
renders `error` when `resolvable === false`.

The composer at **exactly one** ssh machine should hint that a second unlocks the
picker (one string, and it is the only cheap lever on criterion 1's population — nothing
else in the product tells an operator that adding a second machine gives them per-session
choice).

**Two states `resolvable` must define**, which rev 8 left open:

- **malformed `execution.toml` + `allow_localhost = true`** ⇒ `resolvable: true`
  (row 3 yields `local`) **but `error` is non-null and persistent**. The composer's
  transient message is not enough — a broken inventory must be visible somewhere that
  does not disappear on submit, and WU-7c is that somewhere.
- **`machines: []`** only under `allow_localhost = false`.

`kind: "local" | "ssh"` means the client never hardcodes the reserved literal. Label
the row **"Run on"** and the local option **"This machine (where Seal runs)"** — the
browser may be on a different box than the gateway, so bare "Local" is ambiguous about
whose local. `targetLabel` (WU-1) and WU-8's badge reuse that exact string.

`ApiRouteSpec.expectedRouteCount` **83 → 84** (the GET route lands here).

`NewTabComposer.tsx`: one `<select>`, rendered only when `machines.length ≥ 2` and
`kind === 'provider'`; read-only in branch mode (the backend copies the parent's pin).
**Do not persist it in `LastOptions`** (`UiState.hs:57`) — `repoBranch` is deliberately
not persisted for the same class of reason. **The select carries a leading sentinel option** — `Default (<name>)` — whose value is
omitted from the body. Without it, at `≥ 2` machines the `<select>` renders with the
default preselected and `buildBody` sends it, so *every* web session would record a pin
and §9's "a present key means a deliberate choice" would be false on exactly the
population criterion 1 measures. `buildBody` still omits `machine` whenever the picker is
not rendered.

**Adding a machine must invalidate the picker without a reload.** `useMachines` reads at
mount; nothing refetched after a write, so the headline flow — add the first machine,
open a New Tab — showed a stale picker until F5. One line of precedent:
`BeReposChanged` → `repos-changed` → `useRepos` (`StreamBroker.hs:310`,
`streamClient.ts`). This unit adds `BeMachinesChanged`/`broadcastMachinesChanged`, the
`machines-changed` client frame, and `useMachines` refetching on it. **The two emitter
call sites are WU-7a's** — `broadcastMachinesChanged` after a successful `POST` and
after a successful `DELETE`. Rev 10 said "this unit adds the frame" without saying who
calls it, so a test could inject the frame and pass while the real route never
broadcast.

### WU-7c — the Machines screen

**This is the gap round 4 found: the write API is the security control and it had no
UI.** Without it the operator has no way to use the control, and the only machine
affordance in the product (`NewTabComposer`'s picker) renders at `≥ 2` machines — i.e.
hidden in exactly the zero-and-one state where a machine must first be added.

- A `Machines` member in `TopBar`'s `TopSection` union (`SECTION_LABELS` is a
  `Record<TopSection, string>`, so TS forces that entry), `sectionFromPath`, and **the
  render branch in `App.tsx`** (`App.tsx:1077`'s ternary, whose `else` is the Sessions
  view — a missing case renders Sessions silently with no compile error).
  `pathFromSection` is generic and needs no edit. Without the union member the route is
  unreachable; without the render branch it renders the wrong screen.
- `MachinesView.tsx` cloning `ReposView`: list rows showing name/host/user/default,
  an inline add-or-edit form with one `data-testid` per field, a
  `data-testid="machines-form-error"` for the codec's payload.
- **The `?force` flow is one flow, used by both destructive paths.** Neither delete nor
  an edit that changes `host`/`port`/`user`/`identity`/`known_hosts` can read the pin
  count up front (`GET /api/machines` does not carry it and there is no separate
  endpoint). So: *attempt → `409 {error, pinned, unpinned, fallback}` → surface those
  counts with a "Do it anyway" control that retries with `?force`*. One flow, two
  entry points, and two §8 rows.
- **The form carries a "set as default" control** (`data-testid="machines-set-default"`). Without it
  the screen cannot add the *second* machine: §4.6 makes the writer validate the
  resulting document, and ≥ 2 ssh machines with no `default` is a load error — so the
  add would be refused and the state unrepairable from the UI.
- **`kind === "local"` rows render no edit, no delete and no default control, and
  display the same string as the select option — "This machine (where Seal runs)" — not
  the bare reserved name.** It is
  the fallback, not a peer; a form pre-filled with four empty required fields, and a
  Delete that `400`s, are both bugs waiting to be written.
- **Reachable in every state**, including `resolvable: false` — the operator in exactly
  that state must be able to fix it from the web UI, which is the one place the control
  is needed most.
- **Empty-state copy says *why* it is empty**, not just that it is: with
  `resolvable: false` the screen reads "`allow_localhost = false` and no SSH machines
  are configured — add one to run anything", rather than a bare "No machines".
- **At `machines.length == 1` the screen hints that a second machine unlocks the
  per-session picker.** This is the only cheap lever on §9 criterion 1's population:
  without it, an operator with one machine never learns the picker exists, and the
  metric's denominator stays empty for reasons unrelated to the feature's value.
- The composer's `resolvable: false` error links to `/machines`.
- **WU-7c owns four copy surfaces that other units promise *to* it**, each with a
  `data-testid` and a §8 assertion: the persistent `error` banner (a malformed
  `execution.toml` — §7b says "WU-7c is that somewhere"), the empty-state *why*, the
  `machines.length == 1` hint, and `POST`'s loopback `warning` (§7a constraint 4).
  Without them those four promises have no deliverer, and two of them *are* the whole of
  UC-5's delivery.
- Shows the derived `allow_localhost` posture read-only with a "set in `security.toml`" note (**no directory** — §5 forbids hardcoding `~/.seal/` on `SEAL_HOME` installs), so a list missing `local` does not read as broken.
- **Required fields marked**: `name`, `host`, `user`, `known_hosts`, `workspace` are
  required; `port` defaults to 22 and `identity` defaults to ssh-agent. §3.2 gains this
  axis — rev 8 had no required/optional column, so the form was unbuildable.
- **No test-connection affordance in v1**, stated as a known limitation: a
  syntactically valid machine with a wrong key path returns `201`, appears in the
  picker, and is discovered only when a turn fails closed. `POST
  /api/machines/:name/test` is a follow-up (it would make the count 85).

### WU-8 — session-viewer surface
`GET /api/sessions/:id/workdir` returns `{path, machine, files_machine}`
(`handleSessionWorkdir` returns `{path}` today and derives it from `mode`, so it must
resolve the pin). **Value domain for both**: `"local" | <machine name> | null`, where
`null` occurs **only** when the explorer is `FeDisabled` — pinned here, because rev 9
defined `null` but left the live case implicit, so the badge condition had no total
meaning.

**`files_machine == null` means the explorer is `FeDisabled` — which is the *normal*
state on a non-loopback bind — and the link must be inert in that case too.** Rev 10
defined `null` but then applied only the `machine ≠ files_machine` rule, under which
`null == null` leaves the link **active** against a disabled explorer, returning
`403 file explorer disabled`. So: **the link is inert when `files_machine` is `null` or
differs from `machine`.**

**The badge alone is not the fix.** `OpenWorkdirLink` (`ChatArea.tsx:358`) builds
`/files?path=<path>`, and the file explorer is a **single boot-time global** (built in `WU-5`'s boot wiring) with no session input. Today remote mode and the explorer always
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
**unconditionally** — and it must **override the function**, not re-derive the default in
a second place, or the codebase gains a second authority-decider (the exact shape WU-5
is deleting) — including when `security.toml` is absent, which is the case rev 6
missed. `mkLocalUntrustedIO` has no CPP guard (`UntrustedIO.hs:79` imports `Local`
unconditionally), so this value *is* the guarantee.

Cost note: the test needs a second build variant. `seal-harness.cabal:343` already sets
`cpp-options: -DREMOTE_ONLY_UNTRUSTED` for one configuration, so the pattern exists.
Wiring a second `test-suite` stanza is the work. If that proves expensive, the fallback
is a CPP-guarded `#if` inside the existing spec plus a pure unit test of
`allowLocalhostFrom` — cheaper, and it tests the function rather than the artifact.
Issue #347 owns the artifact property (the module still compiles in), which stays out
of scope.

### WU-10 — `group` sanitisation (independent pre-existing escape)

`defPath` (`Agent/Def/Backend.hs:139-144`) and `skillPath`
(`Skills/Backend.hs:418-423`) build `root </> T.strip group </> <id>.md` with
`createDirectoryIfMissing True`, and `group` comes raw from `groupField`
(`Skills.hs:92-97`, `T.strip` only). `group = "../../.."` escapes the config tree
**today**, independent of execution machines.

Charset `[A-Za-z0-9_-]`, rejecting `.`/`..`/separators, **enforced in the backend**
(`skillPath`/`defPath` returning `Either`) rather than only in `groupField`: sanitising at
the op level leaves `POST /api/skills` / `POST /api/agents` and the legacy shims
unguarded. The op-level check stays as the friendly error. Tests at both layers.

Separate unit because it is not load-bearing for §4.3 (`.md` is unconditionally
appended, so it cannot forge `execution.toml`) and because bundling a live security fix
behind this feature's critical path is what to avoid. **It may deserve its own issue
regardless of whether this feature ships** — that is the human's call.

## 8. Testing

TDD throughout. Properties worth QuickCheck, per unit:

| Unit | Tests |
|---|---|
| WU-1 | `mkMachineName` accepts iff charset-valid **and** not reserved; empty / leading `.` / leading `-` / 64 vs 65 / control chars; `sshConfigFromMachine` total and field-preserving; `mkSshHost`/`mkSshUser` reject leading `-`; **`renderTargetError` total, all four renderings exact**, with paths supplied (not `~/.seal/` literals). `TargetUnknownMachine`'s rendering names the available set **and** the Machines screen; `TargetNoMachine` names all three remedies |
| WU-1b (§6.3/6.4) | `-F /dev/null`, `ProxyCommand=none`, `ProxyJump=none` present in all four builders; two `SshConfig`s differing only in `identity` get **different** ControlPaths; the five updated `RemoteSpec` assertions (**the five line numbers are stated once, in §6.4** — do not restate them here) |
| WU-3 | **seven rows** 0/1/1a/1b/2/3/4; row 3 ≡ today's behaviour for every `SecurityConfig`; **no inventory or pin can produce `WhereLocal` unless `allow_localhost`**; **row 1a: `default = "local"` + `allow_localhost = false` ⇒ `TargetLocalNotAllowed`**; row 4 returns `TargetNoMachine` when `allow_localhost = false` and nothing applies |
| WU-2 | codec round-trip; each required field missing ⇒ `Left` naming it; `[machines.local]`/`[machines.default]` ⇒ `Left`; invalid name as key ⇒ `Left`; **`default` naming an absent machine ⇒ `Left`, and `default = "local"` + `allow_localhost = false` ⇒ `Left`**; port `0`/`65536`; duplicate **`host:port:user`** ⇒ `Left`; unknown key ⇒ warning not error; **`[untrusted_execution.remote]` without `mode` decodes**; `uefcMode = Nothing` ⇒ `allow_localhost` derived correctly; **writer: rejected write leaves the file byte-identical; concurrent writes serialise; write→load→resolve round-trip** |
| WU-4 | `exec_machine` round-trips; absent ⇒ `Nothing`; malformed text ⇒ `Nothing` + a warning; **a valid pin naming an absent machine ⇒ `TargetUnknownMachine`**; all five inheritance sites copy the value; **a dead pin fails closed in the child, never falls back to `WhereLocal`**; `SESSION_MANAGE action=new` + `machine` key ⇒ default |
| WU-5 | **two sessions on two machines in one cache get distinct execs** (the headline feature); a target change rebuilds; an unchanged target reuses; `invalidateExec` clears all targets for the sid; a legacy `mode=remote` install with no `execution.toml` produces byte-identical argv |
| WU-6 | `--machine` parses; value-less `--machine` ⇒ error not silent; unknown machine ⇒ 400 whose body carries the available set; **no `session.json` minted on refusal**; web path sends an identical body when the picker is hidden; **`createTab` returns `{ok:false,error}` on a 400 and `NewTabComposer` does not call `onSubmit`/`persistOnSubmit`** |
| WU-7a | **`403` when `acsMode /= AccessPasskey`** (the `AccessOpen` fixture is the regression test — rev 8's "401 without a passkey session" could not pass there); `DELETE` of the effective default refused; `DELETE` of a pinned machine returns the pin count and requires `?force`; **`POST` replacing an existing machine's `host` refuses without `?force` and reports the pin count** (the rev-10 fix, previously untested); `POST` validates the **resulting** document (adding the second machine with no `default` is refused); the loopback `warning` field is present; a non-existent `identity`/`known_hosts` ⇒ field-specific `Left`. *The writer's three unit-level tests (byte-identical rejection, concurrency, round-trip) live in WU-2's row — they ship with the writer, not with this caller.* |
| WU-7a (opcode ban) | **grep: zero `executionFilePath` under `src/Seal/ISA/`**; **`Seal.ISA.Registry`'s import closure excludes `updateExecutionConfig`**; no `MACHINE_*` opcode in the registry |
| WU-7b | golden JSON incl. the full `MachineInfo` spec **with both `local` (ssh fields omitted) and `ssh` (fields present) rows**; sentinel option ⇒ an untouched picker omits `machine` from the body; **`machines-changed` triggers a refetch, so adding a machine updates the composer without a reload**; absent file + `allow_localhost = true` ⇒ `{default:"local", machines:[{name:"local",kind:"local",default:true}], resolvable:true, error:null}`; absent file + `false` ⇒ `machines:[], resolvable:false`; **malformed file + `true` ⇒ `resolvable:true` with non-null `error`**; route count **84**; `≥2` render rule; untouched picker omits `machine` from the body; Start disabled on `resolvable:false` |
| WU-7c | **the end-to-end ramp on a default install**: no `execution.toml` → add one machine → the picker renders two options → a session mints on it; the section renders at `/machines` (and the `App.tsx` render branch is present, not the Sessions fallback); **add ⇒ the row appears; edit ⇒ the form pre-fills from the stored spec**; **the `?force` flow: the 409 force-confirm (`data-testid="machines-force-confirm"`) shows `pinned`/`unpinned`/`fallback` and "Do it anyway" retries with `?force`, for both delete and host-changing edit**; the "set as default" control lets the second machine be added; a `kind === "local"` row has no edit/delete/default controls; **the composer's `resolvable:false` error links to `/machines`**; reachable when `resolvable:false`; each field has a `data-testid`; a codec error renders in `machines-form-error`; delete confirm shows the pin count |
| WU-8 | workdir response carries both machines; they differ ⇒ badge shown **and** the Files link is inert |
| WU-6b | `--machine` from a chat channel reaches `handleSessionNew` and lands on the chosen machine; an unknown machine relays the available set via `ccSend`; a value-less `--machine` errors rather than defaulting |
| WU-10 | `group = "../../.."` refused at both `skillPath`/`defPath` and the op level; `POST /api/skills` with a traversal group is refused |
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
| **Both machines are used**, and neither dominates | on installs where the picker rendered (`machines.length ≥ 2`), counting **only `channel == "web"` sessions with `smCreatedAt` after the WU-7c deploy** (pre-feature `session.json` files have no `exec_machine` key and would otherwise all count on the default side, diluting the rate to ~0 — the rev-5 denominator bug moved from the machine axis to the time axis): **both** names appear in the window, **and** the minority side is ≥ 20% of sessions, with ≥ 10 sessions total (else "insufficient data", not "pass"); owner: the operator; evaluated **2 weeks after first WU-7c deploy**, once extended to 4 weeks if data is insufficient | `grep exec_machine ~/.seal/state/sessions/*/session.json` (honour `SEAL_HOME`; `sessionsRoot = spState </> "sessions"`, `Paths.hs:233`), with `ecDefault` recorded at evaluation time. A session with **no** `exec_machine` key took the default: the picker carries a sentinel option whose value is omitted (§7b), so a *present* key means the user changed the select. Without that sentinel the select would render preselected and every web session would record a pin, biasing the rate toward whichever option was preselected and making the metric false on its own population | **Keep the inventory and resolver**; drop only the surfaces (WU-6/7b/7c/8). See below |
| Two sessions on two machines, both executing | 1 observed | manual, at the demo | UC-1 unvalidated |
| Sessions moved by adding a machine | 0 | integration test + the same grep before/after | A regression, not a feature |
| Machine visible without a click | shown when it differs from the explorer's | WU-8 test | UC-3 unimplemented |
| No legacy behaviour change | byte-identical resolution + argv | the two additivity tests | Additivity claim false |

**The denominator matters.** Rev 5's "sessions created since ship" included installs
where the picker never rendered (`machines.length < 2`), where the rate is
structurally 0% — so a single-machine install would drag the rate under the threshold
and *delete the feature on a measurement artefact*.

**The channel axis is the third denominator bug, and the pattern is now stated once:**
only `NewTabComposer` renders a picker, so only `web` sessions can carry a
sentinel-absent key. `cli`/`tg`/`bg` sessions *cannot* express a pick and would score on
the default side, deflating the rate below the threshold and deleting the surfaces on an
artefact — the same class as rev 5's machine axis and rev 6's time axis. CLI `--machine`
pins are deliberate and countable separately if wanted. Note also that
`sessions/*/session.json` does **not** match `sessions/<parent>/agents/<child>/session.json`,
so the stated command and the stated inheritance bias describe different populations;
the glob is the metric's population and child sessions are excluded by design.

**One residual bias, stated:** branched and child sessions *inherit* the parent's pin, so
a branch-heavy install can inflate the minority side with inheritance rather than
deliberate choice. One sentence in the evaluation note is enough; the metric is a usage
floor, not a value claim.

**And so does the direction.** Rev 8 counted "pinned to a non-default machine", which
punishes the successful operator: someone who sets `default = "builder"` and compiles
on it daily would have nearly every session on the default, score ~0%, and lose the
picker they used every day. The criterion therefore measures the **split in either
direction** — both machines used, neither dominating. `ecDefault` is recorded at
evaluation time because it can change between ship and measurement, and it decides
which side is "minority".

**The verdict no longer deletes the substrate.** Rev 5's "drop the inventory, pin,
and picker" would remove `execution.toml` and the resolver — exactly what the
requester's stated next want (per-tool-call selection) is built on. A missed metric
drops the **surfaces** — WU-6's flag, WU-7b's picker, WU-7c's screen, WU-8's badge —
and keeps the inventory, the writer, WU-3 and WU-5, which fix a real today-biting bug
(`execFingerprint`) and pay for themselves regardless.

One consequence to state, because it is a security posture change: dropping **WU-7a**
(the write route) reverts §4 to hand-edited-file-only — the rev-7 posture. That is a
legitimate outcome, but a reader must be able to tell whether the *control* survives a
missed metric, and by default it does.

**"Insufficient data" expires.** A discovery failure would otherwise park the feature
forever: extend once to 4 weeks, then decide on whatever the split shows.

Criterion 1 measures **whether both machines get used**, and nothing more. It does not
measure *value over hand-editing `execution.toml`* — nothing in this document does —
and it is not a test that the picker beat the file. With `local` counting toward
`≥ 2` (§5), a `local`-plus-one-ssh install satisfies the denominator, and "minority
≥ 20%" then reads as "did you ever run one session the other way": a usage floor, not a
value claim. Stated so a 100% score is not mistaken for validation.

`erMeta.machine` would additionally measure **use per call**, which is a better
instrument — but it costs a third `UIOEnv` field across 92 sites for no
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

Host-key identity checks (unnecessary once only the operator can add machines — §4.1);
per-tool-call routing; multiple machines per turn; cross-machine workdir anchoring (v1
already gives two machines two disjoint filesystems because the remote path roots at
`scWorkspace` — only *anchoring a child across machines* needs a transfer); OS/load
routing; per-machine vaults; IPv6 targets; a `/machine` re-pin command (remedy is a new
session); `seal exec-machine` CLI group; fixing #347's artifact property or #348.

**Adding machines from the web UI has moved *into* scope** (WU-7a/7c). It was a non-goal
when the inventory was hand-edited only; under §4 it is the control.
