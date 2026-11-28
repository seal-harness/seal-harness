# Handoff — Multiple Execution Machines

**Status**: 18 of 18 work units complete. Branch `wu-1-machine-config`, PR #354 (draft).
**Last commit**: `582caa9` — `feat(machines): WU-13 complete — post-SETUP_REPO hooks respect the machine`
**`make check`**: green. 5099 examples, 0 failures, 41 pending, hlint "No hints";
frontend `tsc --noEmit` 0 errors and 1193 vitest tests pass.
**`-f remote-only-untrusted`**: green. Builds, links, 5087 examples, 0 failures, 74 pending.

> **Read this first.** This feature has been through 4 design revisions, 7 plan
> revisions, and 3 rounds of both review gates. The documents below are the
> authority; this handoff only tells you where execution stands and what bit me.

## The documents (read in this order)

1. `docs/superpowers/requirements/2026-11-26-multiple-execution-machines-requirements.md`
   — **frozen**, approved by the operator, with **2 operator-approved amendments**
   recorded in its header. Do not reopen it; a change is a scope change request.
2. `docs/superpowers/specs/2026-11-26-multiple-execution-machines-design.md`
   — **revision 5**. The authority on *how*. §6.2 (dispatcher resolution) and
   §6.2.2 (`CloneDeps` follows the call) are the two sections that matter most.
3. `docs/superpowers/plans/2026-11-26-multiple-execution-machines-plan.md`
   — **revision 7**. 18 work units. §0 is a table of all 26 findings from the
   plan gates and how each was fixed — **read it before touching a unit**.

## What is done

| WU | Content | Commit |
|---|---|---|
| WU-1 | `MachineName`, `MachinesConfig` codec, `MachineRegistry`, pure `resolveMachines`, `isLoopbackHost`. | `6cdca38` |
| WU-2 | `MachineRouting`/`MachineSlot`/`MachineError`, `mkStaticRouting`, `seedRouting`, `mkTestUIOEnvWith`. | `ba710f8` |
| WU-3 | Dispatcher-side resolution; per-call env swap of both `uieUntrustedIO` and `uieCloneDeps`. | `f59097f` |
| WU-4 | **Schema integration.** `machine` now advertised by all 8 machine-selectable opcodes as an enum of the selectable names. Schemas take `[Selectable]`, threaded from the session's routing. | `cd1e9ba` |
| WU-5 | **Real routing in a session.** `mkSessionExecFor` builds the full routing table (was a singleton); lazy per-machine bootstrap with its own workdir and `CloneDeps`. | `04582fd` |
| WU-6 | `allow_localhost` replaces `mode`; selector truth table; `enforceRemoteOnly` call sites. | `d7feb62` |
| WU-6b | FileExplorer/`AgentMetaCache`/`handleSessionWorkdir` follow the session machine. (§6.7's `fileExplorerFollowsSessionMachine` is still not implementable — see below.) | `d7feb62` |
| WU-7 | `loadMachinesConfig`/`saveMachinesConfig`, `resolveMachinesForBoot`, template seeding. | `7083e84` |
| WU-8 | Migration of `[untrusted_execution.remote]` → machine `default`. | in `a279f9d` (base) |
| WU-9 | `SessionMeta.smMachine`, `machineForSession`, `renderMachineConfigError`. | in `a279f9d` (base) |
| WU-12 | **ACK record assertions.** 6 new cases incl. the P10 ordering proof (a FAILING machine still leaves an entry). | `4735b51` |
| WU-13 | **`SETUP_REPO` reads `CloneDeps` from the env**, and the post-clone hooks respect the machine (`dispatchOn`). The per-call swap was inert for it; a cross-machine clone ran over the session machine's transport AND re-scanned the wrong workdir. | `0cffc9d`, `582caa9` |
| WU-14 | **`/machine list`** + the `~/.seal` immutability guard extended to the new files. | `185a528` |
| WU-10 | **Session selection plumbing.** `/new -x` (validated before minting), `naMachine` in `parseNewArgs`, `GET /api/machines` (all 5 route edits), and the web picker. | `d61f85d`, `c29960f`, `4b018be` |
| WU-11 | **Five display surfaces.** `buildMachinePrompt` (T-STR-8), tab line, banner (T-STR-9), `sessionInfoJson` (T-STR-12), sidebar `TabLineField` on by default. | `d9212bc` + prior |
| WU-15 | **Self-key guard + frozen adoption prompt (T-STR-7) + `execErrorToMachineError`** (closes a host/path leak to the model). | `5c1623f` |
| WU-16 | **The hardened build links.** Shared subprocess primitives extracted to `Seal.Tools.Exec.Proc`; `make hardened` + CI gate step; `HardenedBuildSpec`. | `8bfa32b` |
| WU-17 | `CHANGELOG.md` entry incl. the downgrade hazard. | `159d976` |

## What remains

Nothing. All 18 units are implemented and verified.

`fileExplorerFollowsSessionMachine` (§6.7) is still **not implementable as
written** — see the section below — and is recorded rather than claimed.

## Estimate corrections (do not repeat these)

Two figures in the plan were wrong and I repeated one of them without checking:

- **"~289 `uio*` call sites"** — the WU-3 rewrite that would have needed them
  was replaced by the per-call env swap (§0 P20), so the churn never happened.
- **"`dispatch`'s signature has 12+ call sites"** — I asserted this to justify
  deferring WU-13's hook items. There are **3**. Verified with
  `grep -rn '\bdispatch\b' src/`. The deferral was not warranted, and the work
  took one commit once actually measured.

If a plan states a fan-out count, count it before quoting it.

## Traps that cost me time — read before editing

1. **`FILE_PATCH` rejects multiple `@@` hunks in one patch**, and a stray
   `*** End Patch` line makes it fail with a confusing error. Split them, or
   write the whole file.
2. **Patches land where the context matches, not where you meant.** After any
   patch to a file's head, re-read it — I twice duplicated a block that way.
3. **`MachineName`'s constructor is deliberately unexported.** Use `mkMachineName`
   behind a local helper; `localMachineName` for the reserved `local` (which
   `mkMachineName` *refuses* by design).
4. **`mkTestUIOEnv` keeps its arity deliberately** (~90 call sites). It builds a
   *static* routing around the handle you pass. Seeding it with a stub silently
   bypasses the caller's test handler.
5. **`make check` is four targets** (`build test lint frontend-test`) plus a
   frontend build. `hlint` must say "No hints".
6. **Never pipe `cabal`/`hlint` through `head`/`tail`** — SIGPIPE hangs the writer.
7. **`-Werror` catches positional record construction and unused imports.** A
   CPP-split import list also trips hlint's "Use fewer imports" — the fix that
   worked was a whole-module import (which is the repo convention anyway).
8. **`decodeMachinesConfig` silently decoded every `machines.toml` to an empty
   machine list.** `Toml.tableMap` needs the `machines` node to carry an explicit
   value; the idiomatic hand-written shape leaves it implicit. Fixed with
   `normalizeMachinesTable`. **Any new `Toml.tableMap`-decoded section needs the
   same treatment.**
9. **`Toml.dioptional (Toml.table …)` reports a table whose contents fail to
   decode as `Nothing`** — indistinguishable from absent. Section presence must
   be checked at the AST level.
10. **`migrateSecurityConfig` picks its branch by asking whether
    `security.toml` exists.** Any migration that *creates* that file must run
    **after** it.
11. **Test fixtures must not use a shared `/tmp` path** — one test's
    `machines.toml` leaks into the next.
12. **`mkSafePath` blocks `.seal` by segment name**, so the new files were
    already covered. Asserted rather than assumed (`CapabilityScopingWorkdirFsFailSpec`).
13. **`renderMachineList` must not be given a bottom `MachineTarget`.** My first
    fixture used `error "coordinates not read"` and the renderer forced it. Use a
    real `SshConfig` and prove non-rendering with negative assertions.

## The gate's catches that are now implemented (do not regress)

- **`SETUP_REPO` closes over its `CloneDeps`** — fixed in WU-13 by reading
  `uioCdCloneDeps`. The regression test is a *poisoned* `CloneDeps`: every field
  is an `error` thunk naming the bug, so a revert dies with
  `WU-13: constructor CloneDeps used (cdRepoReg)`.
- **`-f remote-only-untrusted` can still run local code** — the boot gate is in
  both paths, `mkLocalExec` is CPP-gated, and the artifact boundary is asserted
  by `HardenedBuildSpec` (nothing outside the local arm may import
  `Seal.Tools.Exec.Local`).
- **The ACK ordering (P10)** — proved by driving a FAILING machine and requiring
  the entry to exist anyway. A success-path assertion cannot see a reordering.

## Not implementable as written

`fileExplorerFollowsSessionMachine` (§6.7). The file-explorer routes take a
`path` query parameter, not a session id, so there is no session in scope and
"the session's machine" is undefined. Honouring it needs either session-scoped
routes (a user-facing change §6.7 itself declines) or an `adFileExplorer` that is
a resolver rather than a value (breaks ~50 `ApiDeps` literals under `-Werror`,
and still has no session). Recorded rather than claimed done.

## Process notes

- **TDD**: RED assertion first in every unit. If a RED assertion passes before the
  code exists, it is wrong. Mutation-test the important ones — I caught two
  vacuous assertions this way (a probe stub returning `True`, and an ACK
  assertion on a success path).
- **Do not use `--no-verify`, do not force-push.**
- **PR #354 is a draft**; `gh pr ready` only when `make check` is green AND the
  hardened build is green.
- **`.cabal` and `test/Main.hs` are merge hotspots** — keep edits minimal.
- **Report honestly.** Several units looked done and weren't. WU-5's routing was
  dead code; WU-12's ordering assertion was vacuous; WU-4's helper had zero call
  sites. All three passed review-looking checks and did nothing.

## Suggested next action

**WU-15**, because it is the last unit with a security property in it (host-key
pinning, self-key guard) and because `seal machine pin` — deferred from WU-14 —
depends on its seams. It needs, minimally:

- `scKnownHosts` filled from `execKnownHostsPath` at the single construction site;
- `HostKeyPaths { hkpSystemKeys :: [FilePath] }` injected so the self-key check
  can be pointed at a fixture instead of `/etc/ssh/`;
- `hkaAdopt :: MachineName -> SshConfig -> IO (Either Text ())` and
  `HostKeyInfo` gaining `hkiMachine`;
- `execErrorToMachineError :: MachineName -> ExecError -> MachineError`,
  including an `ExecNotImplementedReason` arm so the `Workdir.hs` host+path leak
  stops reaching the model.

Then **WU-17** (CHANGELOG + template) is small and unblocks the PR description,
and **WU-10**/**WU-11** are the user-facing remainder.
