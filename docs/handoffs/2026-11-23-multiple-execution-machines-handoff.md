# Handoff — multiple execution machines

Date: 2026-11-23
Branch: `exec/multiple-machines` (pushed)
Commit: `18c84e4`
Status: **design approved through 2 gate rounds; implementation not started**

## Read this first

The design document is the artifact:

```
docs/superpowers/specs/2026-11-23-multiple-execution-machines-design.md
```

1045 lines. Read it in full before touching code. It contains the problem
statement, 19 design decisions (D0-D17, plus D4a/D11a), failure modes, testing
strategy, a 10-work-unit plan with dependencies, and a revision log recording
every review round and what changed.

## What this feature is

Seal can run untrusted code on **one** remote machine, pinned in
`~/.seal/security.toml`. This feature lets an operator define **N** machines and
lets each **session** pick one at creation.

The operator reframing (adopted) splits two things that were bundled in
`security.toml`:

| | |
|---|---|
| `security.toml` → `allow_local = true\|false` | the **security decision**: may this kernel execute untrusted code |
| `~/.seal/config/execution.toml` | the **machine inventory**: provisioning data (host/user/port/identity/known_hosts/workspace) |

It replaces `mode = "local"\|"remote"`. `local` becomes a reserved machine name,
not a flag.

## The gate result (do not re-litigate settled points)

Two rounds, five reviewers, ~80 blockers. All closed.

- **Round 1:** 5/5 NEEDS_REVISION (~60 blockers)
- **Round 2:** 20 more, of which **4 were defects in round-1 fixes**

The single most important lesson is in the revision log: I wrote a test
asserting `localhost` is rejected, against a `SelfIdentity` construction
(`getHostName` + `TlsCert.localAddressNames`) that could never produce the
string `localhost`. Read D6 carefully.

**Settled and corrected in the doc — do not "fix" these back:**

- File explorer is a **Non-goal**. Deferring it removed a breaking API change,
  a second cabal library, and a live security regression.
- `resolvedTarget` carries `rtName :: MachineName` (not just an `SshConfig`) —
  the machine *name* is the user-facing value.
- `?machine=` query param: **rejected**. Path segments match every other scoped
  route; moot once the explorer is deferred.
- `tdIsRemote :: Bool` is **deleted outright**, not shadowed (compile error at
  every site). Same for `cdIsRemote`/`sdIsRemote`.
- Field naming follows **existing practice** (`scHost`, `msOs`), not the stale
  `_<type>_<field>` rule in AGENTS.md.
- `enforceRemoteOnly` cited as "Layer B" is **dead code** — definition + 2 tests,
  no production call site.

## Two things already done, outside this branch's scope

1. **Issue #347** — `-f remote-only-untrusted` does not deliver its documented
   guarantee. Measured: the build **succeeds** (exit 0), but
   `[79 of 218] Compiling Seal.Tools.Exec.Local` appears in the hardened build
   log and `mkLocalUntrustedIO` is in the artifact. Operator decided: fix the
   flag to match the docs, **as a separate issue**. Not this feature's problem.

2. **Unfiled finding — file this before starting.** `sanitizeHref`
   (`frontend/src/lib/markdown.ts:72`) blocks `startsWith('/api/files/download')`,
   which is bypassable by path traversal:
   ```
   /api/files/../files/download?path=/etc/passwd      → block does not fire
   /api/files/./files/download?…                     → block does not fire
   /api/files/%2e%2e/files/download?…                → block does not fire
   ```
   Both resolve to `/api/files/download`, and `validateFilePath`
   (`API.hs:2690-2695`) collapses *after* routing, so the request lands on
   `serveAttachment` — the arm that **skips** `checkBlockedPath`
   (`API.hs:2813` vs `:2839`). The comment claiming "the download UI uses
   `fetch()`, never an `<a href>`" is also false (`FilesView.tsx:416,468`,
   `MediaView.tsx:46`). Fix: structural segment match, not a prefix.

## Next step: the Plan Review Gate

The design is done. The next step is an **implementation plan** decomposed into
work units with DoD items, then the **Plan Review Gate** (3 adversarial
reviewers — Feasibility, Completeness, Scope — all must PASS) before any code.

Load `plan-review-gate`.

## Work-unit plan (from the design — refine into the plan)

Effective order: **1, 2, 3, 4, 2b, 5, 6, 7, 8, 9**

| WU | Scope |
|---|---|
| 1 | `Seal.Execution.Types` + `.Resolve`: types, pure `resolveTarget`/`validateTarget`/`parseIpv4Loose`, IO `getSelfIdentity`/`resolveTargetIO`, `SelfIdentity`. **Owns its own cabal wiring** (unwired modules are never typechecked). Per D17: `Config.Security` and `Exec.Untrusted` must NOT import it |
| 2 | `Seal.Config.Execution` load/save/template; `allow_local`; `WorkspaceRoot'`/`KeyFilePath` validators; port range. **Additive** — `mode` still works |
| 3 | `defaultSessionMeta` (~56-75 sites, mechanical, no behaviour change) |
| 4 | `smExecMachine` + creation plumbing (`CreateTabBody`) + 400 at creation + child/handoff/branch inheritance + wire fields + **`--machine` long-only in both parsers**. **First demoable increment** |
| 2b | **Destructive**: delete `mode`/`UntrustedExecMode`/`resolveRemoteSsh`; migration in `Seal.Config.Migrate`; **re-point the `REMOTE_ONLY_UNTRUSTED` coercion at `allow_local`**; `mkSessionExec`/`cachedSessionExec` take `ResolvedTarget`; rewrite all affected specs |
| 5 | Delete now-orphaned `mkLocalUIO`, `mkSessionUntrustedIO`; rewrite `UIOSpec`/`WorkdirSpec` |
| 6 | All four `*IsRemote` flags; `mkCloneDepsTurn` gains `SessionId`; exec-cache fingerprint (D11); `workdir` returns `{path, machine}` |
| 7 | Gateway: `GET /api/machines`, `PUT /api/sessions/:id/machine`, `/session machine`; **exhaustive `routeMeta`/`openApiMeta` arms + `ApiRouteSpec` 81→83** |
| 8 | Frontend: picker (with 0/1/all-unselectable states), header/list display gated on informativeness, refused-session flag, re-pin UI |
| 9 | Docs, both templates, **fix template's "Boot-only" line 3**, CHANGELOG |

## Traps that will bite you

Each of these was found the hard way; all are verified:

- **`MachineSpec` must nest the SSH record.** Record syntax in both constructors
  makes `msHost`/`msPort`/… partial selectors and `-Werror` rejects them.
  Verified:
  `error: [GHC-82712] [-Wpartial-fields, Werror=partial-fields]`
- **`MachineName` needs `deriving stock (Eq, Ord, Show)`.** Without it
  `TargetError`, `SessionMeta` and `CachedExec` all fail:
  `error: [GHC-39999] No instance for 'Eq MachineName'`
- **A module with no cabal stanza is never typechecked** — `cabal build all`
  exits 0 on a deliberate type error. Wire it in the same WU that creates it.
- **`routeMeta` (`Route.hs:191`) and `openApiMeta` (`OpenApi.hs:79`) are
  exhaustive `\case` with no wildcard**, and `-Wincomplete-patterns` is on.
  Adding a route is a hard build break until both have an arm.
- **`make check` is `build test lint frontend-test`** (`Makefile:39`).
- **Config templates are `file-embed`ed** and `TemplatesSpec` asserts the
  embedded copy matches disk — touch `Templates.hs` after editing a `.toml` or
  you ship a stale copy.
- **`TemplatesSpec` pins `"# [untrusted_execution.remote]"`** and its six keys;
  deleting that table breaks it.
- **`SIGPIPE` pitfall** (AGENTS.md): never pipe Haskell binaries through
  `head`/`tail`. Redirect to a file and page through it.
- **`sshExecArgv` (`Remote.hs:93`) has no `-F`**, so `~/.ssh/config` is honoured.
  D6 requires `-F /dev/null` + `ProxyCommand=none` + `ProxyJump=none`.

## The property that actually matters

Not the easy one:

> ~~`allow_local = false ⇒ never TargetLocal`~~ — true by construction, passes on
> an implementation containing the hole.

Test this instead:

> `allowLocal = False` ⇒ never `TargetLocal`, **and never an SSH target whose
> host denotes the harness box** (per `SelfIdentity`).

`Arbitrary` instances must go *through* the smart constructors, so generators are
`Gen (Maybe …)`-shaped. Avoid orphan instances — use a wrapper newtype as
`RepoSpec.hs:477` does.

## Human checkpoints

The design assumes the operator wants this. It is **unvalidated** — no issue, no
user report. The falsification is WU-4: at that point a user can run
`/new --machine builder` and see the machine change in the composed ssh argv.

If nobody pins a non-default machine within two weeks of WU-4, the design says
**drop the picker** (WU-8) and keep only the plumbing that earned its keep.

## Open decisions (operator has not been asked)

1. `seal exec-machine` CLI group (`list`/`add`/`remove`/`test`) — deferred from
   v1. `GET /api/machines` is the read path that ships.
2. OS/capability routing — `machines.<name>.os` is recorded and displayed but
   never acted on. The `MachineRequirements` seam exists.
3. Residual risk accepted: a DNS or Tailscale/MagicDNS alias resolving to the
   harness box is not caught without DNS resolution. **This must be stated next
   to the setting** in `config/templates/security.toml` and README (WU-9), not
   only in the design doc.
