# Handoff — Multiple Execution Machines

**Status**: 9 of 18 work units complete. Branch `wu-1-machine-config`, PR #354 (draft).
**Last commit**: `b9c6001` — `feat(machines): WU-6b session workdir follows the recorded machine`
**`make check`**: green (build + test + lint "No hints" + frontend). 5016 examples, 0 failures.

> **The hardened build (`-f remote-only-untrusted`) does not link, and never did.**
> Verified against the pre-WU-6 branch: `Remote.hs` and `AgentMetaCache.hs` import
> `Seal.Tools.Exec.Local` unconditionally while the flag removes it from
> `exposed-modules`. WU-16 owns the fix. WU-6 removed the *compile* errors (the
> CPP'd-out local arm no longer leaves unused imports), so WU-16 is now the
> import fix plus the Makefile/CI step — no longer "very likely fails to
> compile", just "fails to link".

> **Read this first.** This feature has been through 4 design revisions, 7 plan
> revisions, and 3 rounds of both review gates. The documents below are the
> authority; this handoff only tells you where execution stands and what bit me.

## The documents (read in this order)

1. `docs/superpowers/requirements/2026-11-26-multiple-execution-machines-requirements.md`
   — **frozen**, approved by the operator, with **2 operator-approved amendments**
   recorded in its header. Do not reopen it; a change is a scope change request.
2. `docs/superpowers/specs/2026-11-26-multiple-execution-machines-design.md`
   — **revision 5**. The authority on *how*. §6.2 (dispatcher resolution) and
   §6.2.2 (`CloneDeps` is a closure) are the two sections that matter most.
3. `docs/superpowers/plans/2026-11-26-multiple-execution-machines-plan.md`
   — **revision 7**. 18 work units. §0 is a table of all 26 findings from the
   plan gates and how each was fixed — **read it before touching a unit**, because
   several units' *first* draft was wrong in ways the table records.

## What is done

| WU | Content | Commit |
|---|---|---|
| WU-1 | `MachineName`, `MachinesConfig` codec, `MachineRegistry`, pure `resolveMachines`, `isLoopbackHost`. Paths: `machinesFilePath`, `execKnownHostsPath`. | `6cdca38` |
| WU-2 | `MachineRouting`/`MachineSlot`/`MachineError`, `mkStaticRouting`, `seedRouting`, `mkTestUIOEnvWith`. `UIOEnv` gained `uieMachines`. | `ba710f8` |
| WU-3 | Dispatcher-side resolution: `resolveMachineForCall`, per-call env swap (both `uieUntrustedIO` **and** `uieCloneDeps`), ACK entry records the resolved machine. | `f59097f` |
| WU-4 | `Seal.ISA.Ops.Machine`: `machineField`, `renderMachineError`, `machinePropertySchema`, `renderUnusableReason`. | `f59097f` |
| WU-7 | `loadMachinesConfig`/`saveMachinesConfig`, `resolveMachinesForBoot`, `config/templates/machines.toml`, template seeding. | `7083e84` |
| WU-6 | `allow_localhost` replaces `mode`; `UntrustedExecRemoteFileConfig` deleted; `UntrustedExecMode` retired (operator decision — the `Bool` carries the same fact); corrected selector truth table; `enforceRemoteOnly` call sites in both boot paths; `mkSessionExec` resolves from the registry; `ExecCache` fingerprint covers the registry. | `d7feb62` |

## What remains

| WU | Content | Notes |
|---|---|---|
| WU-5 | Per-machine workdirs, lazy bootstrap, cache re-key. | WU-7 done. `ExecCache` already re-keys on the registry AND the recorded machine (done in WU-9), so part of this unit is already satisfied — read its RED block against current behaviour first. |
| WU-12 | ACK record names the machine. | **Largely done in WU-3** — verify against its RED block; may only need tests. |
| WU-13 | `SETUP_REPO` on a non-session machine. | Must read `uioCdCloneDeps` from the env — the closure is a default, not the source. Design §6.2.2. |
| WU-10 | TUI prompt, `/new -x`, `/api/machines`, persistence into `smMachine`. | `/api/machines` needs **5** registration edits (see below). |
| WU-11 | Five display surfaces. | `'machine'` must join `DEFAULT_TAB_LINE_FIELDS` or the sidebar won't show it. |
| WU-12 | ACK record — **already largely done in WU-3**. | Verify against its RED block; may only need tests. |
| WU-13 | `SETUP_REPO` on a non-session machine. | Must read `uioCdCloneDeps` from the env — the closure is a default, not the source. See design §6.2.2. |
| WU-14 | `/machine list`, `seal machine pin`, `~/.seal` guard. | `GroupGeneral` only — a new `CommandGroup` ctor renumbers `Enum` and breaks `HelpSpec`. Non-interactive pin only. |
| WU-15 | Host-key pinning, self-key guard, adoption copy. | Needs injected seams (resolver + key paths) or its tests can't fail for the right reason. |
| WU-16 | `-f remote-only-untrusted` actually refuses local execution. | **Pre-existing hole**: `Workdir.hs:188` calls `mkLocalUntrustedIO` unguarded, and `enforceRemoteOnly` has zero call sites + a `Maybe`-collapsed input it cannot see through. |
| WU-17 | `CHANGELOG.md` + `security.toml` template copy. | |

## Traps that cost me time — read before editing

1. **`FILE_PATCH` rejects multiple `@@` hunks in one patch.** Split them, or rewrite
   the file wholesale. I wasted many iterations patching fragments; for new code,
   write the complete file.
2. **Patches land where the context matches, not where you meant.** I twice
   inserted blocks *inside* an export list and *above* the module pragma. After any
   patch to a file's head, re-read it.
3. **`MachineName`'s constructor is deliberately unexported.** Tests cannot write
   `"myname" :: MachineName`. Use `mkMachineName` behind a local helper, and
   `localMachineName` for the reserved `local` (which `mkMachineName` *refuses* by
   design — two of my tests failed on exactly that).
4. **`mkTestUIOEnv` keeps its arity deliberately** (~90 call sites). It now builds
   a *static* routing around the handle you pass. If you seed it with a stub
   instead, you silently bypass the caller's test handler — I broke 16 specs that
   way and only the full suite caught it.
5. **`make check` is four targets** (`build test lint frontend-test`) plus a
   frontend build. `hlint` must say "No hints".
6. **Never pipe `cabal`/`hlint` through `head`/`tail`** — SIGPIPE hangs the writer.
   Redirect to a file and read that.
7. **`-Werror` catches positional record construction.** Adding a field to
   `SessionMeta`/`UIOEnv` breaks every `X { … }` literal and every point-free
   `f = Ctor`. Grep the count *before* starting.

## The gate's two most valuable catches (do not regress these)

- **`SETUP_REPO` closes over its `CloneDeps`** (`Repo.hs:107`). Swapping
  `uieCloneDeps` is *inert* for it. Design §6.2.2: `runSetupRepo` must read
  `uioCdCloneDeps` from the environment.
- **`-f remote-only-untrusted` can still run local code** when
  `[untrusted_execution]` is absent, because `allow_localhost` defaults true, and
  `enforceRemoteOnly` takes a `Maybe`-collapsed config that is `Nothing` in that
  exact state. WU-16 fixes both.

## Process notes

- **TDD**: RED assertion first in every unit. The plan's RED blocks are written to
  fail first; if a RED assertion passes before the code exists, it is wrong.
- **Do not use `--no-verify`, do not force-push.**
- **PR #354 is a draft**; run `gh pr ready` only when `make check` is green and
  the full suite passes.
- **`.cabal` and `test/Main.hs` are merge hotspots** — keep edits minimal, rebase
  `main` before opening for review.
- **Report honestly.** Several units looked done and weren't (WU-12's mechanism was
  a no-op; WU-3's first `mkTestUIOEnv` broke 16 specs). Run the full suite, not
  just the new spec.

## Suggested next action

Start **WU-6**. It is the pivot: every later unit assumes `UntrustedExecFileConfig`
carries `uefcAllowLocalhost :: !Bool` instead of `uefcMode`, and that
`untrustedExecConfigFromSecurity` returns `UntrustedExecConfig` (no `Maybe`).
Its RED block is in plan §WU-6, and its 10 call sites are enumerated there.

## Traps this round added

8. **`decodeMachinesConfig` silently decoded every `machines.toml` to an empty
   machine list.** `Toml.tableMap` needs the `machines` node to carry an
   explicit value in tomland's AST, but the idiomatic hand-written shape
   (`[machines.<n>]` sub-tables, no bare header) leaves it implicit. A file full
   of correct machines read as "none configured" — which, with
   `allow_localhost = false`, is the state that refuses to run anything.
   `Seal.Config.File` already normalizes `providers` and `channels` for exactly
   this reason. Fixed with `normalizeMachinesTable`. **Any new
   `Toml.tableMap`-decoded section in this repo needs the same treatment.**

9. **`Toml.dioptional (Toml.table …)` reports a table whose contents fail to
   decode as `Nothing`** — indistinguishable from the table being absent. That
   is precisely the silent-downgrade shape design §2.3 exists to prevent, so
   section presence has to be checked at the AST level
   (`decodeSecurityConfig`'s `sectionPresent`), covering both the dotted-key
   spelling and a bare header with no keys.

10. **`migrateSecurityConfig` picks its branch by asking whether
    `security.toml` exists.** Any migration that *creates* that file must run
    **after** it, or an upgraded install takes the "security.toml wins" path and
    strands the vault fields in `config.toml`.

11. **Positional `SessionMeta` construction is a trap for mechanical rewrites.**
    A regex that added the new field also matched `resolveExitReason Nothing
    True Nothing Nothing` (an unrelated three-argument function) and silently
    made it four arguments. Count: **75** construction sites, not the "~30" the
    plan estimated. Convert to named construction when you touch them.

12. **Test fixtures must not use a shared `/tmp` path.** `ExecCacheSpec` and
    `WorkdirSpec` both had fixed paths, so one test's `machines.toml` leaked into
    the next and "no machine configured" tests passed or failed by order.

## Not implementable as written

`fileExplorerFollowsSessionMachine` (§6.7). The file-explorer routes take a
`path` query parameter, not a session id, so there is no session in scope and
"the session's machine" is undefined. Honouring it needs either session-scoped
routes (a user-facing change §6.7 itself declines) or an `adFileExplorer` that is
a resolver rather than a value (breaks ~50 `ApiDeps` literals under `-Werror`,
and still has no session). Recorded rather than claimed done.
