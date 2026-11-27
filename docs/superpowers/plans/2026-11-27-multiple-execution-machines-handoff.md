# Handoff — Multiple Execution Machines

**Status**: 5 of 18 work units complete. Branch `wu-1-machine-config`, PR #354 (draft).
**Last commit**: `7083e84` — `feat(machines): WU-7 machines.toml IO, template, boot wiring`
**`make check`**: green (build + test + lint "No hints" + frontend). 4979 examples, 0 failures.

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

## What remains

| WU | Content | Notes |
|---|---|---|
| **WU-6** | `allow_localhost` replaces `mode`; delete `UntrustedExecRemoteFileConfig`; corrected selector truth table; `enforceRemoteOnly` call site. | **Do this next.** It touches ~10 `Maybe`-branching call sites and 5 test modules. Everything downstream depends on it. |
| WU-8 | Migration (5 rows + the failure row). Requires WU-6 + WU-7. | Must **remove** `mode` on the migration boot — see P21. Do not "helpfully" retain it for rollback. |
| WU-6b | `FileExplorer` + `AgentMetaCache` machine binding. | `Serve.hs:677` builds the explorer once at boot from one `SshConfig`. |
| WU-5 | Per-machine workdirs, lazy bootstrap, `ExecCache` re-key. Requires WU-7. | |
| WU-9 | `smMachine` on `SessionMeta` + `machineForSession` + `renderMachineConfigError`. | **~30 positional `SessionMeta` construction sites** across ~20 test files will break. Plan §WU-9 lists them; count them again before starting. |
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
