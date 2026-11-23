# Multiple execution machines

Status: **revision 3c — gate round 2 complete (5/5 reported).** Round 1 returned
5/5 NEEDS_REVISION (~60 blockers). Round 2 returned 20 more, all now closed:
Designer 7, Security 3, PM 5, CTO 5, and Architect's 11 round-1 items are
incorporated in D17/D4a/D11a/§Testing. **Four of the round-2 blockers were
defects in round-1 *fixes*** — recorded honestly below rather than smoothed
over. Core type model verified to compile (see rev-3c item 1).
Date: 2026-11-23

**Revision log.** Round 1 produced ~60 blockers across five reviewers. Every
code claim was independently re-verified against the source before acceptance;
three reviewer claims were rejected or corrected (see §Corrections). The two
findings that changed the shape of this design:

1. **Local execution is not one construction site — it is four, and the
   compile-time backstop is dead.** A prerequisite (WU-0) is now required.
2. **The file explorer cannot be made multi-machine at the cost this feature
   can bear** (96 `adFileExplorer` references, a second cabal library, a second
   hand-maintained route table, and a 7-URL frontend sweep). It moves to
   Non-goals, which also deletes the route rename, the breaking API change, and
   the markdown-exfiltration regression from the whole feature.

**Revision 2a (module layering).** A re-delivered architect note surfaced one
constraint revision 2 missed: the import graph. `Seal.Config.Security` already
imports `Seal.Tools.Exec.Untrusted` (`Security.hs:106`), and
`Seal.Config.Migrate` already imports `Seal.Config.Security` (`Migrate.hs:48`).
See D17 — without it the new `Execution.Types` module closes a cycle that does
not exist today.

**Revision 3 (round-2 Designer blockers, all 7 fixed).** Each was a genuine gap
rather than a style note:

1. **Zero-machine inventory had no precedence row** and `TargetNoDefault` was
   unreachable — yet D13 wrote a runtime message for it. Added row 2.5, and
   resolved the D5-vs-D11 contradiction in D4a (boot *warning* + per-read
   refusal, not a boot exit).
2. **No `TargetSelfHost` copy** — 5 constructors, 4 messages. Now one message
   per constructor (D13) with `teOperatorAction` set deliberately.
3. **Three gateway contracts were unspecified** — all three now defined in D11a
   (`GET /api/machines` shape with server-side `selectable`, `PUT /machine`
   status codes, and `execRefusal` on `SessionInfo` so the list can flag a
   refused session without re-implementing resolution).
4. **WU-7 could not have compiled** — `openApiMeta` is an exhaustive `\case`
   (`OpenApi.hs:79`) and `ApiRouteSpec.expectedRouteCount = 81`
   (`ApiRouteSpec.hs:19`). Route-table work is now in WU-7 explicitly.
5. **`--machine` was promised in copy but built by no WU**, and must land in
   *two* parsers (CLI + chat `/new`, which ignores unknown flags). WU-8,
   long-only.
6. **Explorer notice promised with no WU and no copy**, and `workdir`'s new
   `machine` field had no consumer. Both assigned (D11a, WU-8).
7. **Two message defects**: a remedy aimed at the wrong audience, and a
   human-action suffix both inlined *and* injected (read twice).

**Revision 3a (round-2 Security, 3 blockers).** The reviewer re-verified every
claim independently and found a genuine defect in my D6 fix:

1. **D6 could not reject plain `localhost`.** `SelfIdentity` was to be built
   from `getHostName` + `TlsCert.localAddressNames`, but neither yields the
   string `localhost` — `getHostName` returns the machine name (e.g.
   `arrakis.local`) and `localAddressNamesWith` filters to *assigned interface
   addresses*, explicitly dropping `0.0.0.0`/`::` (`TlsCert.hs:198`). The
   function that does hardcode it is `sanHostsFor` (`TlsCert.hs:154`), which I
   didn't use. So the most important bypass in the whole feature was open while
   my own test list asserted it. `SelfIdentity` now includes the loopback
   literals explicitly.
2. **Step 4 was undefined prose, and it was the only rule catching three of my
   own listed bypasses.** `UrlSafety.isIpv4Private` requires exactly four
   dotted parts; verified `127.1`, `2130706433`, `0x7f000001` all return
   `False`. Replaced with a specified pure `parseIpv4Loose`
   (inet_aton-equivalent: 1-4 parts, decimal/octal/hex).
3. **WU-5 was enumerative, so the bypass *shape* survived.** `mkSessionExec`
   and `cachedSessionExec` take a `SecurityConfig` and re-derive
   local-vs-remote internally — the very shape that caused the original bypass.
   Deleting their callers leaves it intact. WU-5 now requires the signature
   change to `ResolvedTarget`/`Where`.

Also accepted: the deferred explorer is a **confidentiality** exposure, not
merely confusing (Non-goals now fail-closes it under `allow_local = false`,
because `serveAttachment` skips `checkBlockedPath`).

**Revision 3b (round-2 PM, 5 blockers).** Three were self-contradictions in my
own revision:

1. **No success criteria** — added a §Success criteria with five falsifiable
   signals. Free to measure: `exec_machine` is already persisted per session,
   so it is a grep, not new analytics.
2. **My own falsification plan was unbuildable.** I said "ship WU-1..4 and see
   whether anyone pins a machine" — but no opcode may set `smExecMachine`,
   `PUT` is 409 for non-refused sessions, and the picker was in WU-8. WU-1..4
   would have persisted a field *nothing could write*. `--machine` moves into
   WU-4, making it the first demoable increment (verified: `Seal.Command.New`
   and `NewArgs.parseNewArgs` are creation paths).
3. **`/session machine` was promised in D13's message and built by no work
   unit** — `Seal.Command.Session` has exactly `list`/`info`
   (`Session.hs:44-46`, verified). This is the *identical* defect I had just
   "fixed" for `--machine`, left standing for its sibling. Now in WU-7.

Two further corrections:

4. **D8's `KeyFilePath` would have broken every existing remote deployment.**
   Requiring `~/.seal/` paths rejects the shipped template's
   `identity = "/home/you/.ssh/id_ed25519"` (`security.toml:57-58`, verified) —
   the only working remote path today. Relaxed to absolute + no `..` +
   canonicalized, allowlisting `~/.ssh/` and `~/.seal/`.
5. **The template's line 3 still says "Boot-only"** (`security.toml:3`,
   verified) — false once `allow_local` is re-read per turn. Added to WU-9.

The PM also **withdrew** its round-1 `?machine=` recommendation, agreeing that
deferring the explorer makes the point moot.

**Revision 3c (round-2 CTO, 5 blockers).** Two were hard build breaks, both
reproduced with GHC before acceptance:

1. **`MachineName` had no `deriving` clause**, but `TargetError`, `SessionMeta`
   (which derives `Eq, Show` at `Meta.hs:92`) and `CachedExec` all derive over
   it. Reproduced:
   `error: [GHC-39999] No instance for 'Eq MachineName' arising from the first
   field of 'TargetSelfHost'`. Fixed — `deriving stock (Eq, Ord, Show)`.
2. **WU-1's "no wiring" was impossible.** A module in **no** cabal stanza is
   never typechecked (`cabal build all` exits 0 on a deliberate type error), and
   a module in `other-modules` only is unimportable from the test suite
   (`hidden module in the package`). So D16's properties could not be written
   *and* blocker 1's defect would have sailed through eight work units. Cabal
   wiring moves into WU-1.
3. **WU-2b was under-scoped** — it omitted `SecuritySpec`, `ExecCacheSpec:95,180,184`,
   `WorkdirSpec:329`, `TemplatesSpec:375`, and eight `src` call sites with no
   owner. Its ordering also conflicted with WU-5 over `mkSessionExec`. Fixed by
   **moving the signature cutover into WU-2b** (which must touch those sites
   anyway) rather than reordering, which would have produced an incoherent
   intermediate state.
4. **WU-7 omitted the route-table work** — `routeMeta` (`Route.hs:191`) and
   `openApiMeta` (`OpenApi.hs:79`) are both exhaustive `\case` with no
   wildcard, and `-Wincomplete-patterns` is in `-Wall -Werror` (verified). Also
   `Serve.hs:677`, the explorer site destroyed by WU-2b's deletions.
5. **D13 declared `teOperatorAction :: Bool` as a field** on a nullary sum,
   which does not typecheck. Made a function (D4). And `TargetNoDefault` was
   unreachable under D5-as-load-error — resolved by D4a, now cited as the single
   source of truth.

## Problem

Seal runs untrusted code on a remote machine, but only one, welded to
`security.toml`:

```toml
# ~/.seal/security.toml  (agent-immutable)
[untrusted_execution]
mode = "local"                      # local | remote
[untrusted_execution.remote]
host / user / port / identity / known_hosts / workspace
```

`resolveRemoteSsh` (`src/Seal/Config/Security.hs:774`) yields a single
`SshConfig`; six consumers read that one value.

**What is actually impossible today** (corrected — the first draft overstated
this by claiming a restart is needed for the exec path; `loadSecurityConfig` is
re-read every turn at `TurnEngine.hs:684`, and `TurnDeps` deliberately holds no
cached config, per its own docstring at `TurnEngine.hs:373-375`):

1. **Two machines concurrently.** One global setting, so every session shares it.
2. **Adding a machine without moving every existing session.** There is one
   global target; changing it moves all sessions at once.
3. **Telling the file explorer about a change without a restart.** It is built
   once at boot (`Serve.hs:677`) — this is why (3) is separate from (1) and (2).

The honest framing is **concurrency and per-session choice**, not "remote
execution is missing." One remote machine works today.

**Evidence:** this is an operator request, not a measured user pain. Treat UC-1
as an assumption. **The falsification is WU-4, and it is demoable because
`--machine` moves into it** — round-2 PM blocker 2: with `--machine` left in
WU-8, WU-1..4 would persist a field that *nothing could write* (no opcode may
set it, `PUT` is 409 for non-refused sessions, and the picker is WU-8). At WU-4
a user can run `/new --machine builder` and observe the machine change in the
composed ssh argv. That is the first moment the premise is testable.

## Reframing the security boundary

`security.toml` exists to hold choices **an agent must not change**. Two very
different things were in it:

1. **Where untrusted code runs** — host, user, port, key path, workspace. This
   is *provisioning data*.
2. **Whether the harness machine itself may execute untrusted code.** This is a
   *security decision*.

Only (2) stays. `mode` becomes `allow_local`.

```
security.toml   ->  allow_local   (the security decision)
execution.toml  ->  machine inventory  (provisioning data)
```

**This reframing opens exactly one hole, and closing it is most of the work.**
A machine whose `host` denotes the harness box *is* local execution in
disguise; if machine definitions are agent-writable, that defeats
`allow_local = false`.

> **Threat-model honesty (revised).** `execution.toml` grants an agent *nothing
> it does not already have*. An untrusted `SHELL_EXEC` runs `/bin/sh -c` as the
> same user (`UntrustedIO.hs:327`), and `AGENT_DEF_MANAGE`/`SKILL_MANAGE`
> already write into `~/.seal/config` (`Backends.hs:87-96`). What `allow_local`
> protects is not "the agent cannot write files" — it is "untrusted code does
> not execute on this kernel." D6 exists solely to keep that sentence true.
>
> The first draft justified this with "the vault is only reachable from Trusted
> opcodes." **That reasoning was wrong**: `SECRET_MANAGE` is `Trusted` *and*
> agent-callable (`Secret.hs:228`, registered at `TurnEngine.hs:285`), so an
> agent can read secrets today. The correct statement is narrower: *adding a
> machine does not grant vault access, because `SECRET_MANAGE` already had it.*

## Use cases

- **WHO** a developer with a laptop and a Linux build box · **WANTS** a heavy
  compile session on the build box and a scratch session on the laptop
  concurrently · **SO THAT** builds finish without editing config and moving
  every session · **WHEN** starting a new session.
- **WHO** an operator keeping untrusted code off the harness machine · **WANTS**
  `allow_local = false` enforced regardless of which machine a session picks ·
  **SO THAT** a prompt-injected agent cannot reach the control plane · **WHEN**
  any untrusted opcode is dispatched. *(This is a **constraint**, not a new use
  case — it is the existing invariant.)*
- **WHO** a developer working across architectures · **WANTS** to see which
  machine a session runs on · **SO THAT** an arch-specific `cargo build` failure
  is diagnosable · **WHEN** reading the chat header or session list.
- **WHO** an operator who renamed or removed a machine · **WANTS** existing
  sessions to keep working or be re-pointed · **SO THAT** a config edit is
  recoverable without hand-editing session state · **WHEN** the next turn runs.

## Success criteria

Round 1 raised the absence of user-focused success criteria as a blocker; this
is the minimum falsifiable set. It costs nothing to measure because
`exec_machine` is already persisted per session (`session.json`) — **the
measurement is a grep, not new analytics.**

| Signal | Target | How observed | Verdict if missed |
|---|---|---|---|
| Sessions pinned to a non-`default` machine | ≥1 within 2 weeks of WU-4 shipping | `grep exec_machine ~/.seal/sessions/*/session.json` | **Nobody pins ⇒ the premise is unvalidated. Keep single-machine, drop the picker (WU-8), keep the inventory+pin plumbing only if it earned its keep via WU-0.** |
| Sessions moved by adding a machine | 0 — existing sessions' `exec_machine` and `workdir` unchanged | integration test + the same grep before/after | A migration that re-points sessions is a regression, not a feature |
| Machine visible without a click (UC-3) | shown in header + list when it carries information | frontend test | UC-3 unimplemented |
| Rename recoverable (UC-4) | a refused session can be re-pinned, no hand-edited `session.json` | integration test on `PUT` + `/session machine` | UC-4 unimplemented |
| Hardened build | `-f remote-only-untrusted` **builds and passes tests in CI** | new CI job (WU-0) | WU-0 incomplete — the whole D6 argument is unsupported |

The last row is the one that matters most: before this feature, the hardened
build was never exercised, so its guarantee was assumed. After WU-0 it is
measured.

## Goals

1. Define N execution machines in `execution.toml`, one of which may be `local`.
2. Let each session choose its machine **at creation**; persist the choice.
3. Keep `allow_local` as the agent-immutable decision, enforced at resolve time
   against every machine.
4. Repair the hardened build so it actually delivers its documented guarantee.
5. Leave a shaped seam for future routing; build no routing.

## Non-goals

- **Multi-machine file explorer.** *Moved here in revision 2.* The explorer is
  a boot-time handle (`Serve.hs:677`) on `ApiDeps.adFileExplorer`
  (`API.hs:236`) with **96 references** across `src`/`test`. Making it
  per-machine means replacing that field everywhere, adding a registry, a
  second cabal library (`src-gateway-types` cannot import the main library —
  `NewArgs.hs:3-4`), a second hand-maintained route table (`OpenApi.hs:146`),
  a route-count update (`ApiRouteSpec.hs`), and a 7-URL frontend sweep
  (`useApi.ts`). It also *causes* the markdown-exfiltration regression by
  renaming `/api/files*`. All of that is deferred. **v1: the explorer shows
  machine `default` and says so in the UI when the focused session is on a
  different machine.**
  **Round-2 addition — a confidentiality consequence that must be handled, not
  just labelled.** Today the explorer is derived from the exec config
  (`Serve.hs:678-683`), so it *always equals* the exec machine. "Shows
  `default`" inverts that: a session on `builder` gets an explorer pointed at
  the harness box. The sharp edge is that `serveAttachment` deliberately skips
  `checkBlockedPath` (`API.hs:2813` calls `feReadFileBytes` directly; the check
  exists only in `serveInline` at `:2839`, documented as an intentional
  omission). So a UI notice is **insufficient — it does not gate bytes.**
  **Rule: when `allow_local = false`, the explorer is fail-closed
  (`mkFailClosedFileExplorer`) unless every machine in the inventory is
  non-local.** This is not an execution-boundary breach (nothing runs; the
  explorer is passkey-gated and human-driven, and no opcode selects its
  machine), but it is control-plane file bytes served to a remote session's
  viewer, which is precisely what `allow_local = false` is meant to prevent.
- Routing by OS/load/capability (the seam exists; the data is recorded).
- Multiple machines within one session.
- Adding machines from the web UI (config file only).
- Per-machine vaults or policy.
- IPv6 SSH targets (`mkSshHost` rejects `:`, `Types.hs:129` — pre-existing).

## Design decisions

### D0 — Prerequisite: repair the hardened build (WU-0)

`-f remote-only-untrusted` is documented (AGENTS.md, spec §3 Layer B) as the
compile-time guarantee that untrusted execution cannot run on the control
plane. **It does not hold.**

| Evidence | Finding |
|---|---|
| `seal-harness.cabal:340-343` | `Local.hs` only in `exposed-modules`; never `other-modules` under the flag |
| `UntrustedIO.hs:79` | unconditional `import Seal.Tools.Exec.Local` — **0 CPP guards in the file** |
| `Remote.hs:67` | unconditional import (`readBounded`, `withManagedProcess`) |
| `AgentMetaCache.hs:82` | unconditional import (`readBounded`, `withManagedProcess`) |
| `ghc-options: -Wno-missing-home-modules` (`cabal:345`) | the authors' own acknowledgement the module still compiles in |
| `.github/workflows`, `Makefile`, `nix/` | the flag is **never built** |

What actually blocks local execution today is `localModeResult` coercing `mode`
to `UemRemote` under `-DREMOTE_ONLY_UNTRUSTED` (`Security.hs:795-798`).
**D2 deletes `mode`**, so this feature would *unplug* the only working
backstop. `enforceRemoteOnly` — cited in the first draft as Layer B — has **no
production call site** (definition + 2 tests only).

WU-0 must:
1. Gate all **three** imports behind real CPP.
2. Add an `allow_local := False` coercion under the flag (replacing
   `localModeResult`'s role), with a test.
3. Delete `untrustedIOFromSecurity` (`Cli.hs:472-486`) — dead code, zero
   callers; its only effect was the `#if` arm at `Cli.hs:485`.
4. Add `-f remote-only-untrusted` to CI so it cannot rot again.

### D1 — `execution.toml`

```toml
# ~/.seal/config/execution.toml
default = "builder"            # required when >= 2 machines exist (D5)

[machines.local]               # reserved name = the local executor, no keys
```

```toml
[machines.builder]
host        = "builder.example.com"
user        = "seal"
port        = 22
identity    = "/home/you/.ssh/id_ed25519"
known_hosts = "/home/you/.ssh/known_hosts"
workspace   = "/srv/seal/workspace"
os          = "linux"          # optional, informational (never routed on)
```

**Top-level keys, not `[execution]`** — `config.toml` and `security.toml` have
no wrapper table named after the file; theirs are top-level concepts
(`[retrieval]`, `[gateway]`). `[execution] execution.default` restated the
filename. Field prefix is `ex`/`exMachines`.

**`local` is a reserved name, not a flag.** A machine named exactly `local` *is*
the local executor and rejects all other keys. This makes
`[machines.laptop] local = true` unrepresentable rather than merely
discouraged, and reuses vocabulary the codebase already has (`allow_local`,
`UemLocal`).

### D2 — `security.toml` keeps only the decision

```toml
[untrusted_execution]
allow_local = false            # default: true
```

Read **per turn** (matching `loadSecurityConfig` at `TurnEngine.hs:684`), not
cached at boot. Delete `mode`, `UntrustedExecRemoteFileConfig`,
`UntrustedExecMode`, `resolveByMode`, `resolveRemoteSsh`, and
`untrustedExecConfigCodec`'s remote arm.

`allow_local` is **not** described as "boot-only" anywhere — that was
self-contradictory in revision 1. It is operator-owned and re-read per turn.

### D3 — Typed machine model (corrected — must compile)

Revision 1's `MachineSpec` **does not compile**: record syntax in both
constructors makes `msHost`/`msPort`/`msIdentity`/`msKnownHosts`/`msWorkspace`
partial selectors, and `-Werror` rejects them. Reproduced:

```
Pf2.hs:7:9: error: [GHC-82712] [-Wpartial-fields, Werror=partial-fields]
    Definition of partial record field: 'msHost'
```

Corrected — nest the SSH record:

```haskell
newtype MachineName = MachineName Text
  deriving stock (Eq, Ord, Show)   -- REQUIRED: TargetError and SessionMeta both
                                   -- derive Eq/Show over it; without this clause
                                   -- the tree does not compile (CTO round-2 #1)
  -- charset ^[a-z0-9][a-z0-9_-]*$  (lowercase-only: it is a URL segment *and*
  -- a TOML key *and* must not collide case-insensitively; rejects ".", "..", "%")

data SshMachineSpec = SshMachineSpec
  { smsHost       :: SshHost        -- existing validated newtype
  , smsUser       :: SshUser
  , smsPort       :: Int            -- validated 1..65535 (new; see D12)
  , smsIdentity   :: IdentitySource -- see D8
  , smsKnownHosts :: KeyFilePath    -- see D8
  , smsWorkspace  :: WorkspaceRoot' -- see D7 (rejects "..", blocked-name clean)
  , smsOs         :: Maybe Text
  }

data MachineSpec
  = MachineLocal
  | MachineSsh SshMachineSpec
```

No `Default` for `MachineSpec` — there is no sensible `def` for "where does code
run". `ExecutionConfig` may have one (`ExecutionConfig mempty Nothing`).

### D4 — Resolution: one pure core, one IO entry point

Revision 1's signature was self-contradictory: D6 needs `getHostName`, which is
IO, but the function was specified pure. Split it:

```haskell
-- Seal.Execution.Types (pure, IO-free; imports only Seal.Tools.Exec.Types)
data Where = WhereLocal | WhereSsh SshConfig
data ResolvedTarget = ResolvedTarget
  { rtName  :: MachineName     -- carried: the whole point is naming the machine
  , rtWhere :: Where
  }

data TargetError
  = TargetUnknownMachine MachineName [MachineName]
  | TargetNoDefault      [MachineName]
  | TargetLocalForbidden MachineName
  | TargetSelfHost       MachineName
  | TargetConfigUnreadable Text
  deriving stock (Eq, Show)

-- D13 needs a per-constructor human-action flag. It is a FUNCTION, not a
-- field: the constructors stay nullary so Eq/Show/pattern-matching stay
-- simple. (Round-2 CTO blocker 5: D13 said the type "carries
-- teOperatorAction :: Bool", which does not typecheck against a sum.)
teOperatorAction :: TargetError -> Bool
teOperatorAction = \case
  TargetUnknownMachine _ _ -> False   -- a human can re-pin it in-session
  TargetNoDefault _        -> True
  TargetLocalForbidden _   -> True
  TargetSelfHost _         -> True
  TargetConfigUnreadable _ -> True

renderTargetError :: TargetError -> Text   -- the D13 message table

newtype SelfIdentity = SelfIdentity [Text]   -- lowercase hostnames + FQDNs + IPs

resolveTarget
  :: ExecutionConfig -> Bool -> Maybe MachineName
  -> Either TargetError ResolvedTarget

validateTarget
  :: SelfIdentity -> Bool -> ResolvedTarget
  -> Either TargetError ResolvedTarget
```

```haskell
-- Seal.Execution.Resolve (IO)
getSelfIdentity :: IO SelfIdentity
resolveTargetIO :: ExecutionConfig -> Bool -> Maybe MachineName
                -> IO (Either TargetError ResolvedTarget)
```

Tests inject a literal `SelfIdentity` and never touch `getHostName` or DNS;
production goes through `resolveTargetIO`. **A closed `TargetError` ADT, not
`Either Text`** — the API maps variants to 404/403/500, which is control flow
(`AGENTS.md`: introduce a bespoke ADT when the program pattern-matches on it).

**Precedence table** (one ordered list — revision 1's table contradicted D6 and
itself):

Rows are evaluated top to bottom; the first match wins. **Row 2.5 closes the
gap revision 2 left**: a file that *parses* but declares zero machines matched
no row at all, and `TargetNoDefault` had no producing row.

| # | Condition | Result |
|---|---|---|
| 1 | `ExecutionConfig` empty (no file) | `TargetLocal` if `allowLocal`, else `TargetLocalForbidden local` |
| 2 | pin names a machine not in inventory | `TargetUnknownMachine pin known` |
| 2.5 | file present but inventory is empty (0 machines) | `TargetNoDefault []` — "no machines are defined" |
| 3 | no pin, `default` set | `default` |
| 4 | no pin, no `default`, exactly 1 machine | that machine |
| 5 | no pin, no `default`, ≥2 machines | `TargetNoDefault known` — reachable after a mid-run edit (D4a) |
| 6 | resolved `MachineLocal`, `allowLocal = False` | `TargetLocalForbidden` |
| 7 | resolved SSH, host denotes the harness box, `allowLocal = False` | `TargetSelfHost` |
| 8 | resolved SSH, `allowLocal = True` | allowed (self-host permitted — it *is* local) |

Row 7 is **conditioned on `allowLocal = False`**, matching D6. Revision 1's
table row omitted that qualifier, contradicting both D6 and its own test plan.

### D4a — ≥2 machines with no `default`: refused at read, reported at boot

Revision 2 said D5 rejects it "at load time" **and** D11 requires the config to
be loaded per call, never boot-snapshotted. Those are compatible only if stated
precisely:

- `seal serve` / `seal tui` **print a prominent boot warning** and refuse to
  start a *session* until it is fixed. This is where the operator can act.
- The *read* still succeeds: `loadExecutionConfig` returns the parsed config,
  and `resolveTarget` returns `TargetNoDefault` (row 5). This keeps
  `TargetNoDefault` reachable, keeps the refusal message meaningful, and means
  a mid-run edit is observed without a restart (D11).
- It is **not** a hard process exit: the gateway must still boot so the operator
  can reach the UI to read the message, and so Trusted opcodes keep working.

So: **boot warning + per-read refusal**, not a boot exit. D13 message #2's
"You have N machines" is therefore written for a genuinely reachable state.

### D5 — Missing `default` with ≥2 machines: required, reported at boot

Revision 1 had legacy sessions resolving through `default`, so **adding a second
machine silently refused untrusted execution in every pre-existing session**,
surfacing as a turn error far from the config edit that caused it.

**When the inventory holds ≥2 machines, `default` is mandatory.** Its absence is
reported prominently at boot (where the operator can act) and refused at read
time (so a mid-run edit is still observed). See D4a for the precise semantics —
revision 2 wrongly called this a "load error", which contradicted D11's
per-call reload and made `TargetNoDefault` unreachable.

### D6 — Self-host detection (rewritten; the lexical list was the wrong primitive)

Revision 1 listed `localhost`, `127.0.0.0/8`, `::1`, own hostname. Defeated by
`localhost.`, `LOCALHOST`, `127.1`, `2130706433`, `0x7f000001`, `0.0.0.0`,
`::ffff:127.0.0.1`, `ip6-localhost`, `foo.local`. And `::1` is **unrepresentable**
(`mkSshHost` rejects `:`), so that test case was unwritable.

Replaced with **normalize-then-test against `SelfIdentity`**:

**These steps run only when `allowLocal = False`** (matching D4 rows 7-8). With
`allow_local = true` an SSH machine pointing at this box is legitimate — it is
just local execution reached the long way round.

1. Normalize the host: lowercase, strip a trailing dot, unbracket.
2. **Reject if it equals an entry in `SelfIdentity`.** `SelfIdentity` is built
   from `getHostName` **plus** `TlsCert.localAddressNames` **plus the loopback
   literals**. Round 2 caught a real bug here: neither `getHostName`
   (returns e.g. `arrakis.local`) nor `localAddressNamesWith` — which filters to
   *assigned interface addresses* and explicitly drops `0.0.0.0`/`::`
   (`TlsCert.hs:198`) — ever yields the string `localhost`. The function that
   hardcodes it is `sanHostsFor` (`TlsCert.hs:154`:
   `<> ["localhost", "127.0.0.1", "::1"]`), which revision 2 did not use. So
   D6 as written **could not reject plain `localhost`** — the single most
   important case, and the one its own test list asserted. `SelfIdentity` must
   therefore include `localhost`, `localhost.localdomain`, `ip6-localhost`,
   `ip6-loopback`, `127.0.0.1`, `::1` explicitly.
3. **Reject if it parses as an inet_aton-equivalent IPv4 literal.** This is
   *specified code*, not prose. `UrlSafety.isIpv4Private` requires exactly four
   dotted parts, so it returns `False` for `127.1`, `2130706433`, and
   `0x7f000001` (verified) — step 3 as previously written caught none of them.
   New pure function `parseIpv4Loose :: Text -> Maybe Word32` accepting 1-4
   parts, each decimal / octal (leading `0`) / hex (`0x`), left-to-right
   filling, rejecting values over 32 bits; then test the resulting `Word32`
   against the loopback and private ranges. Covers every form `getaddrinfo`
   accepts without delegating to it.
4. **Reject if it parses as an IPv6 literal that is loopback, unspecified,
   link-local, or IPv4-mapped onto a rejected IPv4** (`::ffff:127.0.0.1`).
   `::1` and `::ffff:...` are unrepresentable via `mkSshHost` (which rejects
   `:`), so that specific test is unwritable today; the rule guards a future
   relaxation.

Steps 1-4 are all pure and belong in `validateTarget`. Nothing here resolves
DNS — see residual risk.

**Plus `-F /dev/null` in `sshExecArgv`/`sshExecArgvForwarding`** (`Remote.hs:93`),
with `-o ProxyCommand=none -o ProxyJump=none`. Without it, a `~/.ssh/config`
`Host builder` / `HostName 127.0.0.1` alias defeats everything above without
touching `execution.toml` — D6 would validate a string ssh does not honour.

**Residual risk (unchanged, and now stated operator-facing):** a DNS or
Tailscale/MagicDNS alias resolving to the harness box is not caught without DNS
resolution. This limitation must appear **next to the setting** in
`config/templates/security.toml` and README, not only in this doc — Tailscale is
a documented, recommended deployment (`docs/web-access-control.md`).

### D7 — `workspace` is a trusted anchor and must be validated as one

A hazard revision 1 missed entirely. `mkSafePathRemote` (`Path.hs:193`) checks
`blockedNames` against the **requested** segments and treats the **root** as
trusted. `mkRemotePath` rejects empty/leading-dash/control but **not `..`**
(`Types.hs:161`). So `workspace = "~/.seal"` + relative README-style path
`config/vault/vault.age` passes containment with segments `config`, `vault`,
`vault.age` — none blocked.

`WorkspaceRoot'` is a validated newtype that:
- rejects `..` anywhere,
- rejects empty / relative,
- runs `blockedSegment` on the **root itself** at load time,
- is normalized before use.

Property to test: *the workspace root's own segments are blocked-name clean.*

### D8 — Key material paths are validated opaque types

`scKnownHosts`/`scIdentity` are bare `FilePath` emitted verbatim into argv
(`Remote.hs:98,110`), and TOFU adoption appends to whatever `known_hosts`
names (`HostKeyAdoption.hs:200`). Once agent-writable, they become
attacker-selectable: point at a pin file in your own workspace, pre-seed a key
for a host you control, and `ExecHostKeyMismatch` never fires.

- `KeyFilePath` — opaque; validation specified in the correction below.
- `IdentitySource = AgentOnly | PinnedFile KeyFilePath`.

**Correction (round-2 PM blocker 4): the round-2 draft over-constrained this.**
Requiring `identity`/`known_hosts` to live under `~/.seal/` would reject
*every existing remote deployment* — the current template ships
`identity = "/home/you/.ssh/id_ed25519"` and
`known_hosts = "/home/you/.ssh/known_hosts"`
(`config/templates/security.toml:57-58`), and that is the only working remote
path today. Revised rule:

- `KeyFilePath` must be **absolute**, contain no `..`, and canonicalize
  (symlinks resolved, then re-checked — else `~/.seal/key -> /tmp/x` passes) to
  a path outside `blockedNames` **other than** the two accepted locations:
  `~/.ssh/` and `~/.seal/`. `~/.ssh` is the conventional home for these and is
  already in `blockedNames`, so it is explicitly allowlisted here rather than
  silently violating that list.
- The `~/.seal/` location remains **recommended** in docs (key material next to
  the harness), not required.

This also corrects D3's revision-1 claim that Invariant 2 (no raw `Text` reaches
argv) was preserved: for these two fields it was not.

"Host-key mismatch is never bypassed" remains true **per definition** — and a
new machine definition starts at TOFU, so it is *resettable* by adding a
machine. Stated, not hidden.

### D9 — Per-session pin

`smExecMachine :: Maybe MachineName` on `SessionMeta` (not `Maybe Text` — the
harness validates this identifier; `smAgent` is `Maybe AgentDefId` for the same
reason). On-disk key `exec_machine`; **wire** `execMachine` in
`sessionInfoJson` (`SessionJson.hs:81`) — revision 1 specified disk only, which
made UC-3 unimplementable.

Tolerant decode: an invalid name is **dropped**, matching the existing
"inherited branch that no longer validates is dropped" policy.

**Resolved at creation, persisted as the name.** Changing `default` does not
move new sessions. *Legacy* sessions with no pin do resolve via `default` and
can move — stated in the risk table, since revision 1's mitigation overclaimed.

**Inheritance (was missing):** child and handoff sessions inherit the parent's
resolved machine. `writeChildMeta` (`Worker.hs:404`), `writeHandoffMeta`
(`:518`), `fallbackMeta` (`TurnEngine.hs:1340`), and `branchSession`
(`Branch.hs:93`) all mint `SessionMeta` today with no machine, so a `builder`
session would spawn children on `default`. Anchored children already reuse the
parent's exec (`TurnEngine.hs:1282`) — the two paths disagreed.

**No opcode may set `smExecMachine`.** `SESSION_MANAGE action=new` and cron
fires always take `default`. That asymmetry is deliberate: *an agent must not
choose a machine* is what makes D6 meaningful.

### D10 — Re-pinning a refused session

Renaming a machine would otherwise permanently brick every session pinned to it,
with no in-product remedy (hand-editing `session.json` is unreachable —
`~/.seal` is in `blockedNames`).

`PUT /api/sessions/:id/machine` and `/session machine <name>`, **gated to
sessions whose current resolution is a `TargetError`**. Re-pinning is already
cache-safe once D11 lands. Refusal is visibly flagged in the session list.

### D11 — Exec cache: the pin is not an input (security bug)

`execFingerprint :: SecurityConfig -> Text` (`ExecCache.hs:98`) and
`cachedSessionExec`'s signature (`:105`) take **no pin and no
`ExecutionConfig`**. Consequences:

- A session re-pinned `local` → `builder` keeps serving the **cached local**
  exec until process restart — including under `allow_local = false`.
- Editing `[machines.builder] host` changes nothing, because the fingerprint
  derives from `SecurityConfig`, which no longer holds the coordinates at all.

Fix: compute the fingerprint **inside** the cache from the session's own
resolved target, and add `ceSessionPin :: Maybe MachineName` as a second guard
(the resolved `SshConfig` can be byte-identical for two names). Ripples to 6
call sites (`TurnEngine.hs:689,1060,1097,1294,1368`, `API.hs:1652`).

`ExecutionConfig` is loaded **per call**, never boot-snapshotted (contrast
`adSecurityConfig` at `Serve.hs:199`, which already causes this class of bug).

**Structural requirement (round-2 Security blocker 3).** Deleting the three
bypass *sites* is not enough — `mkSessionExec` (`Workdir.hs:177-181`) and
`cachedSessionExec` (`ExecCache.hs:105-113`) both take a **`SecurityConfig`**
and re-derive local-vs-remote *internally*. That re-derivation is the shape that
produced the original bypass, and it survives deletion of its callers. Once
WU-2b removes `mode` there is nothing left to derive from, so:

> `mkSessionExec` and `cachedSessionExec` must take a
> `ResolvedTarget`/`Where`, **not** a `SecurityConfig`. A local arm then cannot
> be constructed without a `WhereLocal` value in hand.

D11 is the proof that this shape already bites: the cache re-derives from
`SecurityConfig` and its fingerprint has exactly this bug. WU-5's DoD must
assert the signature change, not just the deletions.

### D11a — Gateway contracts (specified, not implied)

Revision 2 promised three HTTP surfaces without shapes. All three are specified
here because an implementer would otherwise invent them.

**`GET /api/machines`** — the picker's data source. Response:

```json
{ "default": "builder",
  "machines": [
    { "name": "builder", "kind": "ssh", "os": "linux",
      "default": true,  "selectable": true,  "detail": null },
    { "name": "local",   "kind": "local", "os": null,
      "default": false, "selectable": false,
      "detail": "allow_local = false in ~/.seal/security.toml" } ] }
```

`selectable` is resolved server-side per machine, so the picker never
re-implements `allow_local`/self-host logic in TypeScript. `detail` is the
human-readable reason when `selectable` is false.

**`PUT /api/sessions/:id/machine`** — body `{"machine": "builder"}` (body, not
path: the session id is already the path, and a machine name as a path segment
was only needed for the deferred explorer). Returns `200 {"ok":true,"machine":…}`
on success, `400` with the `TargetError` message for an unknown or unselectable
machine, `404` for an unknown session, `409` when the session is *not* currently
refused (D10 gates re-pin to refused sessions so it cannot become a
silent-migration footgun).

**`SessionInfo` gains two fields** so the list can flag a refused session
without the frontend resolving anything:

```json
{ "execMachine": "builder",
  "execRefusal": null }
```

`execRefusal` carries the same human message as D13 when resolution fails, and
`null` otherwise. This is what makes D10's "visibly flagged in the session
list" implementable — revision 2 specified the promise but no field.

**`GET /api/sessions/:id/workdir`** returns `{path, machine}` (WU-6). The
chat-header `OpenWorkdirLink` (`ChatArea.tsx:355-430`, typed `{path: string}`)
**must consume `machine`**: when the session's machine is not the explorer's,
it renders the D13/D11a notice instead of a link to a path that does not exist
on the machine being browsed. Revision 2 added the field and no consumer.

### D12 — Port validation (pre-existing bug)

`resolveRemoteSsh` does `fromMaybe 22 (uerfcPort r)` with no range check
(`Security.hs:780`). WU-2 adds 1..65535 validation with a test for `0`/`65536`.
Noted as a latent pre-existing bug, not a new invariant.

### D13 — Refusal messages are read by the model

`TargetError` strings flow into the turn, so **the agent reads them**. Revision
1's messages said "set `allow_local = true` in `~/.seal/security.toml`" — an
instruction the model will try to follow with `FILE_WRITE`, which `blockedNames`
blocks. Result: a wasted turn and a confused user.

Rule: **refusal text is written for a human and states explicitly that the agent
cannot fix it.** `teOperatorAction :: TargetError -> Bool` (D4) tells
`TurnEngine`
injects an "A human must change this; you cannot." framing **once**, after the
message. The suffix is **never** embedded inline in a message body — revision 2
did both for message #3, so the model would read it twice.

One message per `TargetError` constructor — **five**, not four. Revision 2
omitted `TargetSelfHost` entirely, leaving an implementer to invent the text,
which is the exact defect this section exists to prevent.

| Constructor | Message | `teOperatorAction` |
|---|---|---|
| `TargetUnknownMachine` | `Unknown execution machine 'builer'. Known machines: builder, local. Two ways to fix: re-point this session with /session machine <name>, or correct the name in ~/.seal/config/execution.toml.` | false |
| `TargetNoDefault` | `This session has no execution machine, and ~/.seal/config/execution.toml sets no default. You have N machines (a, b). Add default = "<name>" at the top of that file, or start the session with --machine <name>.` | true |
| `TargetLocalForbidden` | `Machine 'local' is this machine, and ~/.seal/security.toml sets allow_local = false, so untrusted code cannot run here. Start the session on an SSH machine (--machine <name>), or have the operator set allow_local.` | true |
| `TargetSelfHost` | `Machine 'NAME' points at host 'HOST', which is this machine. ~/.seal/security.toml sets allow_local = false, so untrusted code cannot run here. Give that machine a genuinely remote host in ~/.seal/config/execution.toml, or have the operator set allow_local.` | true |
| `TargetConfigUnreadable` | `Could not read ~/.seal/config/execution.toml: <parse error>. Untrusted execution is refused until it parses; chat and trusted tools still work.` | true |

Two round-1 message defects fixed here: #1's second remedy no longer says "choose
a machine when starting the session" (an *existing* pinned session can only be
fixed by re-pin, D10 — now named); #3 no longer embeds the human-action suffix
inline as well as having it injected.

**`TargetNoDefault` reachability (round-2 CTO blocker 5b).** Revision 2 said D5
made "≥2 machines, no `default`" a *load* error, which would make this variant
and its message unreachable — untestable, and dead in TDD. That is why D4a
exists: the config **loads** (D11 requires per-call reload and the gateway must
boot so the UI is reachable), the operator gets a prominent **boot warning**,
and `resolveTarget` row 5 returns `TargetNoDefault`. The variant is therefore
reachable and testable, and D4a is the single source of truth for this
behaviour.

**Explorer notice (a sixth string, not a `TargetError`).** The explorer is
single-machine in v1, so the Files view must say so rather than silently showing
the wrong box: `Showing machine 'default'. This session runs on 'builder' — its
files are not visible here.` The same string drives the chat-header workdir link
(D11a). This was promised in Non-goals with no work unit and no copy; WU-8 now
owns it.

### D14 — All four `*IsRemote` flags, and `cdIsRemote` is a security decision

`tdIsRemote` is removed outright (compile error at every site — the strongest DX
decision in revision 1, preserved). But three siblings remain and **56
construction sites** exist (15 `src`, 41 `test`):

| Flag | Site | Note |
|---|---|---|
| `tdIsRemote` | `TurnEngine.hs:404` | removed |
| `CloneDeps.cdIsRemote` | `Clone.hs:247` | **security-relevant**: gates remote deploy-key `ssh -A` vs local clone auth (`Clone.hs:436`). A stale `False` silently downgrades a remote session to local clone auth. |
| `ChannelDeps.cdIsRemote` | `Loop.hs:94` | positional `Bool` in `newChannelDeps` (`:129`); removing it changes arity → `Serve.hs:541` + 10 call sites |
| `SendDeps.sdIsRemote` | `Send.hs:203` | boot-time global |

`mkCloneDepsTurn :: TurnDeps -> IO CloneDeps` (`TurnEngine.hs:909`) reads
`tdIsRemote` at `:918` with **no `SessionId` in scope** — it must gain one,
across 6 call sites.

Also: `cloneDepsForApiDeps` (`API.hs:1629`) and `mkRepoTestSeam`
(`Serve.hs:818`) hardcode `cdIsRemote = False`, so every API-side repo clone uses
the local credential path regardless of the session's machine.

### D15 — `SessionMeta` needs a `defaultSessionMeta` first

**75 construction sites across 31 files**, no `Default`. Adding `smExecMachine`
sweeps all of them. Introduce `defaultSessionMeta` as a **separate prerequisite
step** so WU-3 is not a 75-site diff tangled with behavioural change.

### D16 — TDD properties that are actually worth having
Revision 1's property was the **weak half**:

> `allow_local = false ⇒ never TargetLocal`

True by construction of its own table, so it passes on an implementation
containing the exact hole this design closes (`allow_local = false` returning
`TargetSsh localhost`). The invariant worth testing:

> `allowLocal = False` ⇒ the result is never `TargetLocal` **and never an SSH
> target whose host denotes the harness box** (per `SelfIdentity`).

Mechanics: `Arbitrary` instances for the newtypes must go **through** the smart
constructors, so generators are `Gen (Maybe …)`-shaped (`suchThatMaybe`). Avoid
orphan instances — use a wrapper newtype as `RepoSpec.hs:477` does.

### D17 — Module layering (import-cycle constraint)

The new types live in a leaf module so the dependency graph stays a DAG. This
is not cosmetic: `Seal.Config.Security` **already** imports
`Seal.Tools.Exec.Untrusted` (`Security.hs:106`), and
`Seal.Config.Migrate` already imports `Seal.Config.Security`
(`Migrate.hs:48`). Two rules follow, and violating either closes a cycle that
does not exist today:

1. **`Seal.Config.Security` must NOT import `Seal.Execution.Types`.**
   `resolveTarget` takes a bare `Bool` for `allow_local`, so Security needs
   nothing from Execution. If it did import it, then
   `Seal.Config.Execution` (which must import `Security` for the atomic-write
   and `loadSecurityConfig` helpers) yields
   `Security → Execution → … → Security`.
2. **The D7 migration lives in `Seal.Config.Migrate`, not
   `Seal.Config.Security`.** It writes both files; Migrate already imports
   Security and already owns the `config.toml`→`security.toml` precedent.

Layering, outermost to leaf:

```
Seal.Execution.Resolve   (IO: getSelfIdentity, resolveTargetIO)
        |
Seal.Execution.Types     (pure; imports only Seal.Tools.Exec.Types)
        |
Seal.Tools.Exec.Types    (existing cycle-breaker leaf; imports only Tools.Args)
```

`Seal.Tools.Exec.Untrusted` must **not** import `Seal.Execution.Types` either:
`UntrustedExecMode`/`enforceRemoteOnly` are deleted by D2/WU-2b, so the import
is unnecessary, and adding it invites
`Execution.Types → Exec.Untrusted → Execution.Types`.

Conversely `Seal.Session.Workdir` importing `Seal.Execution.Types` is a *win*:
`mkSessionExec` takes a `ResolvedTarget`, so Workdir can drop its
`Seal.Config.Security` import (`Workdir.hs:29`).

## Failure modes

| Condition | What the person sees |
|---|---|
| `execution.toml` unparseable | boot log + per-session refusal naming the parse error; chat and trusted tools work |
| ≥2 machines, no `default` | **boot warning** + per-session refusal (D4a — not a boot exit, so the UI stays reachable) |
| pinned machine unknown | per-session refusal naming the machine and the known set; session flagged in the list; re-pin available (D10) |
| `allow_local = false` + local pin | refusal naming both remedies, marked human-action-required (D6/D13) |
| `allow_local = false` + self-host SSH | `TargetSelfHost`, with the D13 message naming the host (D6) |
| parent's machine unknown | child refuses with the parent's reason (D9) |
| machine unreachable / host-key mismatch | unchanged structured `ExecError`; session stays usable |
| hardened build + `allow_local = true` | coerced to `false` at load (D0) |

## Testing strategy

Pure: table D4 rows as properties (D16); `SelfIdentity` self-host detection
including `localhost.`, `LOCALHOST`, `127.1`, `2130706433`, `0.0.0.0`; the
`WorkspaceRoot'` blocked-name/basis property (D7); `MachineName` charset;
`execution.toml` parse (minimal/full/malformed/duplicate/`local` with extra
keys); the D4a boot-warning + per-read refusal; migration rows.

### Picker display rules (previously undefined)

WU-8 adds a machine picker; round 1 flagged that its empty states were
unspecified. **Every install in existence today has exactly one machine**, so an
unconditional picker would be noise on 100% of current users.

| Inventory state | Render |
|---|---|
| 0 machines | no picker; a one-line hint pointing at `execution.toml` |
| exactly 1 machine | **no picker** — a static label naming it (mirrors the agent dropdown, which hides at `agents.length === 0`) |
| ≥2 machines, some selectable | picker, default preselected |
| ≥2 machines, **none** selectable (only `local` defined, `allow_local = false`) | picker disabled, showing D13's `TargetLocalForbidden` text and a pointer to `security.toml` |

Same rule for the chat header and session list: **show the machine only when it
carries information** — the inventory has ≥2 machines, or the session's machine
is not the default. A permanent `local` chip on a single-machine install is
noise.

Integration (existing `ApiTestHarness`, recording fake — no live SSH): two
machines, two sessions, assert each composed ssh argv carries its own host and
`-F /dev/null`; `allow_local = false` + local pin refused while a Trusted opcode
still works; `workdir` returns the session's own path; D11's re-pin rebuild.

Frontend: `sanitizeHref` — separate issue, see §Corrections.

Gate: `make check` = **build + test + lint + frontend-test** (revision 1
misdescribed it as three).

## Work units

| WU | Scope | Depends |
|---|---|---|
| **0** | Repair hardened build: 3 CPP guards, `allow_local := False` coercion, delete `untrustedIOFromSecurity`, add flag to CI | — |
| **1** | `Seal.Execution.Types` + `Seal.Execution.Resolve`: `MachineName`, `SshMachineSpec`, `ExecutionConfig`, `TargetError`, `ResolvedTarget`, `SelfIdentity`, pure `resolveTarget`/`validateTarget`/`parseIpv4Loose`, IO `getSelfIdentity`/`resolveTargetIO`. Fully unit-tested incl. D16. **Cabal wiring is part of this WU, not WU-9** — a module with no stanza is never typechecked (`cabal build` exits 0 on a deliberate type error), so deferring the wiring would let compile errors through WU-1..8 undetected. Per D17: Security must not import it; `Exec.Untrusted` must not import it | 0 |
| **2** | `Seal.Config.Execution` load/save/template + `allow_local` in security config + `WorkspaceRoot'`/`KeyFilePath` validators + port range. **Additive only** — `mode` still works | 1 |
| **2b** | **Destructive**: delete `mode`/`UntrustedExecMode`/`resolveRemoteSsh`; migration in `Seal.Config.Migrate`; rewrite **all** affected specs — `Phase4Spec`, `UntrustedSpec`, `TemplatesSpec`, `ApiTestHarness`, **plus `SecuritySpec` (5+3 record literals), `ExecCacheSpec:95,180,184`, `WorkdirSpec:329`, `TemplatesSpec:375`**; and the `src` call sites with no other owner: `Workdir.hs:182`, `ExecCache.hs:99`, `Serve.hs:538,677`, `API.hs:1212,1710`, `TurnEngine.hs:653,669`, `Cli.hs:158,474`. **Also the signature cutover**: `mkSessionExec` + `cachedSessionExec` take `ResolvedTarget`/`Where` instead of `SecurityConfig` (they re-derive local-vs-remote internally today — the bypass shape, D11) | 2 |
| **3** | `defaultSessionMeta` (75 sites, mechanical, no behaviour change) | — |
| **4** | `smExecMachine` + creation plumbing (`CreateTabBody`, `newSession`) + validation at creation (400 in the form) + child/handoff/branch inheritance + `execMachine` on the wire **+ `--machine` (long-only) in `Seal.Command.New` and `src-gateway-types/…/NewArgs.parseNewArgs`** — moved here from WU-8 so WU-4 is the first *demoable* increment (PM round-2 blocker 2) | 1,3 |
| **5** | Delete the now-orphaned local constructors: `mkLocalUIO` (`UIO/Internal.hs:117`), `mkSessionUntrustedIO` (`Workdir.hs:308`), and `mkSessionExec`'s `Nothing` arm (gone in 2b); rewrite `UIOSpec`/`WorkdirSpec`. DoD: a local arm is unconstructible without a `WhereLocal` value — asserted structurally, not just by deletions | 1,4,2b |
| **6** | All four `*IsRemote` flags; `mkCloneDepsTurn` gains `SessionId`; exec-cache fingerprint (D11); `workdir` returns `{path, machine}`; fix the 2 hardcoded `cdIsRemote = False` | 4,5 |
| **7** | Gateway per D11a: `GET /api/machines` (`{default, machines[]}` with `selectable`/`detail`), `PUT /api/sessions/:id/machine` (body, 400/404/409), `execMachine` + `execRefusal` on `SessionInfo`. **Includes the route-table work**: a `SealRoute` constructor, an `routeMeta` arm, an `openApiMeta` arm (`OpenApi.hs:79` is an exhaustive `\case`), and `ApiRouteSpec.expectedRouteCount` 81→83 — **both `routeMeta` (`Route.hs:191`) and `openApiMeta` (`OpenApi.hs:79`) are exhaustive `\case` with no wildcard, and `-Wincomplete-patterns` is in `-Wall -Werror`, so omitting either is a hard build break** (CTO round-2 #4). Also `Serve.hs:677` — the file-explorer construction site, destroyed by WU-2b's deletions and owned by no other WU. **Also `/session machine <name>`** — a third subcommand in `Seal.Command.Session`, which has only `list`/`info` today (`Session.hs:44-46`); D13 message #1 tells the model to use it, so it must exist (PM round-2 blocker 3) | 6 |
| **8** | Frontend: machine picker in `NewTabComposer` **with defined 0-/1-machine and all-unselectable states**; chat-header + session-list display **gated on being informative**; refused-session flag; re-pin UI; `execMachine`/`execRefusal` in `frontend/src/types.ts::SessionInfo`; explorer notice + workdir link from D11a | 7 |
| **9** | Docs, README, `security.toml` template — **including fixing line 3's "Boot-only and agent-immutable"** (`config/templates/security.toml:3`), which becomes false once `allow_local` is re-read per turn (PM round-2 blocker 5) — plus the residual-risk note; `execution.toml` template; **`.cabal` wiring** (`exposed-modules`, `other-modules`, `test/Main.hs`, `extra-source-files`); CHANGELOG | all |

**Ordering note (CTO round-2 #3) — resolved by re-cutting, not reordering.** Deleting `mode` breaks `mkSessionExec` (`Workdir.hs:182`), and the original split assigned that symbol to WU-5, which ran *after* WU-2b — leaving the tree red in between. Rather than reorder (which creates an incoherent intermediate state: `mkSessionExec` taking a `ResolvedTarget` while `mode` still exists), **the signature cutover moves into WU-2b**, since 2b must touch those call sites anyway. WU-5 then owns only the now-orphaned local constructor deletions. Effective order: WU-0, 1, 2, 3, 4, 2b, 5, 6, 7, 8, 9.

**WU-2 is split** (2 / 2b) because as one unit it could not go green: deleting
`mode` breaks `Phase4Spec`, `UntrustedSpec`, `ApiTestHarness`, and
`TemplatesSpec` simultaneously.

**Wiring is explicit** (WU-9): `Seal.Execution.Types`, `Seal.Execution.Resolve`,
`Seal.Config.Execution` all need `exposed-modules`, test `other-modules`,
`test/Main.hs`, and `config/templates/execution.toml` in `extra-source-files` —
or the sdist stops building and `file-embed` ships a stale copy
(`TemplatesSpec:90`).

## Risks

| Risk | Mitigation |
|---|---|
| Agent adds a self-host machine to escape `allow_local` | D6 (`SelfIdentity` + `-F /dev/null`); D16 property; compile-time coercion in WU-0 |
| Hardened build silently regresses again | WU-0 adds it to CI |
| Re-pinning serves a stale exec | D11 fingerprint inside the cache + `ceSessionPin` guard |
| Migration strips `security.toml` comments | surgical key removal, not re-encode; migration log says so if a re-encode is unavoidable |
| `WorkspaceRoot'` validation misses a form | D7 property test |
| Legacy sessions move when `default` changes | documented, not overclaimed |
| Scope creep into the explorer | Non-goals; explorer stays on `default` with an explicit UI notice |

## Corrections to the review record

Three reviewer claims were **rejected or corrected** on re-verification:

1. **PM/Security "use `?machine=` instead of a path segment."** Rejected —
   Designer showed every scoped route in `Route.hs` is path-nested, and the
   security motive dissolves because the explorer is out of scope (Non-goals).
2. **Security: "`SECRET_MANAGE` is Audited."** Wrong — it is `Trusted`
   (`Secret.hs:228`); the reviewer read a stale module comment. The substantive
   point (agent-callable vault read) holds.
3. **Security: "D6 is defeated by `::1`."** That case is *unrepresentable* —
   `mkSshHost` rejects `:` (`Types.hs:129`), so the test was unwritable. The
   other bypass classes were real and are fixed in D6.

## Out-of-scope finding — file separately

`sanitizeHref` (`frontend/src/lib/markdown.ts:72`) blocks `startsWith('/api/files/download')`.
**This is bypassable today**, independent of this feature:

```
/api/files/../files/download?path=/etc/passwd
  .startsWith('/api/files/download')  -> false      (block does not fire)
  new URL(...,'http://x').pathname     -> /api/files/download   (blocked route, reached anyway)
```

Round-2 Security independently confirmed this and found **two further vectors**
that belong in the issue's repro: `/api/files/./files/download?…` and
`/api/files/%2e%2e/files/download?…`. `validateFilePath` (`API.hs:2690-2695`)
applies `lexicalCollapse` *after* routing, so the request lands on
`serveAttachment` — the arm with **no** `checkBlockedPath` (`API.hs:2813` vs
`:2839`). That makes the unblocked route the one that also skips the
blocked-path check.

Its own comment also falsely claims "the download UI uses `fetch()`, never an
`<a href>`" — `FilesView.tsx:416,468` and `MediaView.tsx:46` all render
`href="/api/files/download?..."`. Fix: structural segment match, not a prefix;
assert traversal is dead. **Separate issue, not part of this feature.**

## Future work

- Multi-machine file explorer (the deferred Non-goal).
- `seal exec-machine` CLI group; `GET /api/machines` is the v1 read path.
- OS/capability routing (`machines.<name>.os` already recorded).
- Moving a live session between machines.
- DNS-resolved self-host detection.
