# Multiple Execution Machines — Implementation Plan

> **Design:** `docs/superpowers/specs/2026-11-26-multiple-execution-machines-design.md` (revision 4, accepted)
> **Requirements:** `docs/superpowers/requirements/2026-11-26-multiple-execution-machines-requirements.md` (frozen, 2 operator-approved amendments)
> **Branch:** `feature/multiple-execution-machines`
> **PR:** #354

## How to read this plan

17 work units. Each has: DoD items, file scope, dependencies, and the RED test
that fails before the unit starts. Every unit ends with `make check` green.

**Rules for every unit** (from AGENTS.md, restated because they are easy to skip
under time pressure):
- Failing test first. The RED assertion in each unit is written before the code.
- Never `--no-verify`, never force-push.
- Stay inside the declared file scope. If a unit needs a file outside its scope,
  stop and amend the plan.
- New module ⇒ wired in three places: library `exposed-modules:`, test
  `other-modules:`, `test/Main.hs`.
- `make check` = build + test + lint (`hlint` must report "No hints").

**SIGPIPE reminder:** never pipe `cabal`/`hlint` through `head`/`tail`. Redirect
to a file and read it (`cabal test >test.log 2>&1; head -80 test.log`).

**Merge hotspots:** `seal-harness.cabal` and `test/Main.hs`. Keep edits minimal,
rebase before the PR.

---

## Phase 1 — Pure foundations (no wiring; nothing existing breaks)

### WU-1: Machine names and config resolution

**DoD**
- [ ] `MachineName` newtype with smart constructor: ASCII alphanumerics plus
      `-`/`_`/`.`; rejects empty, leading `-`, leading `.`, bare `.`/`..`,
      length > 64, and the reserved name `local`.
- [ ] `MachinesConfig` + `MachineFileConfig` tomland codec for `machines.toml`
      (`default`, `[machines.<name>]` with `host`/`user`/`port`/`identity`/
      `workspace`).
- [ ] `MachineTarget = MtLocal | MtSsh !SshConfig` (name lives in the map key, not
      the constructor).
- [ ] `RejectReason = RrMissingField !MissingField | RrLoopbackHost !Text |
      RrInvalidHost !Text | RrInvalidWorkspace !Text | RrInvalidPort`.
- [ ] `MachineRegistry { regMachines, regRejected, regDefault }`.
- [ ] `resolveMachines :: Bool -> SealPaths -> MachinesConfig -> MachineRegistry`
      — pure; takes `allow_localhost` and the paths (for
      `exec-known-hosts`/workspace validation) as parameters so it does not read
      either config file itself.
- [ ] Resolution rules, in order: field validation → loopback guard **before**
      host validation (so `RrLoopbackHost` yields the right message) → `local`
      injected iff the flag → `regDefault` resolved or dropped with a warning.
- [ ] `isLoopbackHost :: Text -> Bool` covering `localhost`, `127.0.0.0/8`,
      `::1`, `[::1]`, `0.0.0.0`, `::`.

**Files (create)**
- `src/Seal/Config/Machines.hs`
- `test/Seal/Config/MachinesSpec.hs`

**Files (edit)**
- `seal-harness.cabal` (exposed-modules, other-modules)
- `test/Main.hs`

**RED**
```
machineNameRejectsReservedLocal        -- "local" → Left
machineNameRejectsLeadingDash          -- "-x" → Left
machineNameAcceptsValid                -- "linux-builder" → Right
loopbackBeforeHostValidation           -- host "localhost" → RrLoopbackHost "localhost"
loopbackCarriesConfiguredHost          -- host "127.0.0.1" → RrLoopbackHost "127.0.0.1"
missingWorkspaceRejected               -- RrMissingField Workspace
localInjectedIffFlag                   -- property, checkCoverage both arms
localTableIgnoredWithWarning           -- [machines.local] present → MtLocal still implicit
defaultNamingMissingMachineIsDropped   -- regDefault = Nothing, warning logged
mtSshCannotCarryMismatchedName         -- type-level: name only in the map key
```

**Depends on:** nothing.

---

### WU-2: `ExecTarget`, routing, slots, errors

**DoD**
- [ ] `MachineError` ADT exactly as design §5.2, with **typed** payloads:
      `MachineUnreachable !MachineName !UnreachableReason`,
      `MachineHostKeyChanged !MachineName`. No free `Text` payload anywhere.
- [ ] `UnreachableReason = UrConnectFailed | UrBootstrapFailed | UrHostKeyUnknown`.
- [ ] `newtype ExecTarget = ExecTarget MachineName` — constructor **not exported**.
- [ ] `MachineRouting` with `rtResolve :: MachineName -> IO (Either MachineError UntrustedIO)`,
      `rtSession :: MachineName`, `rtSelectable :: [Selectable]`. Constructor and
      fields **not exported**; only `mkMachineRouting`.
- [ ] `MachineSlot = SlotReady !UntrustedIO | SlotFailed !MachineError`.
- [ ] `data Selectable = SelLocal | SelMachine !MachineName`.
- [ ] `mkTestUIOEnv` keeps its current arity: it defaults to a singleton routing
      (session machine only, wrapping the supplied handle).
- [ ] `mkTestMachineRouting :: [(MachineName, UntrustedIO)] -> MachineName -> MachineRouting`
      exported **with a `Test`-prefixed or `mkTest` name** (the repo's convention
      for test seams) so multi-machine tests can be written.

**Files (create)**
- `src/Seal/Tools/Exec/Machine.hs`
- `test/Seal/Tools/Exec/MachineSpec.hs`

**Files (edit)**
- `src/Seal/Tools/Exec/UIO/Internal.hs` (`UIOEnv` gains `uieMachines`)
- `seal-harness.cabal`, `test/Main.hs`

**RED**
```
execTargetConstructorNotExported       -- compile-fail fixture
machineRoutingConstructorNotExported   -- compile-fail fixture
mkTestUIOEnvSingletonRouting           -- existing fixtures still compile + behave
mkTestMachineRoutingTwoMachines        -- two machines, both resolvable
slotMemoizesFailure                    -- second resolve of a Failed slot does not retry
```

**Depends on:** WU-1 (`MachineName`, `Selectable`).

---

## Phase 2 — The per-call seam

### WU-3: `uio*` signatures take the target

**DoD**
- [ ] All twelve `uio*` functions gain a leading `ExecTarget`.
- [ ] `withTarget :: ExecTarget -> (UntrustedIO -> IO a) -> UIO (Either MachineError a)`.
- [ ] `uioResolveTarget :: Maybe Text -> UIO (Either MachineError ExecTarget)`.
- [ ] `sessionTarget :: UIO ExecTarget`.
- [ ] `uioUntrustedIO` **deleted**; `Seal.ISA.Ops.Repo`'s `cloneRepoIO` migrated
      to `withTarget`.
- [ ] `Seal.Tools.Exec.WorkdirFs.hs:418` passes `sessionTarget`.
- [ ] `MachineRouting` stays opaque — no opcode module can destructure it.

**Files (edit)**
- `src/Seal/Tools/Exec/UIO/Internal.hs`, `src/Seal/Tools/Exec/UIO.hs`
- `src/Seal/Tools/Exec/WorkdirFs.hs`
- `src/Seal/ISA/Ops/{File,Shell,Bin,Search,Process,Repo}.hs`
- ~289 call sites (132 src, 157 test)

**RED**
```
uioShellExecTakesTarget                -- signature-level: does not compile without it
withTargetUnknownMachineIsMachineError -- not ExecNotImplemented
workdirFsUsesSessionTarget             -- snapshot still works
repoCloneGoesThroughWithTarget         -- cloneRepoIO no longer takes a raw handle
noOpcodeDestructuresMachineRouting     -- grep/compile-fail (T-CAP)
```

**Depends on:** WU-2.

**Note:** this is the only unit that cannot be split further — `ExecTarget` is
unconstructible until `UIOEnv` carries the routing, so the signature change is
atomic. Expect a large diff; do not attempt to keep the build green mid-unit.

---

### WU-4: The eight opcodes accept `machine`

**DoD**
- [ ] `machineField :: Value -> Maybe Text` and
      `machineSchemaProp :: [Selectable] -> Value` in `Seal.ISA.Ops.Machine`.
- [ ] `renderMachineError :: OpName -> MachineError -> Text` —
      `\(OpName n) -> n <> " failed: " <> body err` (**space, no colon**).
- [ ] The 8 untrusted opcodes (`SHELL_EXEC`, `BIN_EXEC`, `FILE_READ`,
      `FILE_WRITE`, `FILE_PATCH`, `SEARCH_FILES`, `PROCESS_MANAGE`,
      `SETUP_REPO`) accept optional `machine`, resolve via `uioResolveTarget`,
      and fail before any execution on an unknown name.
- [ ] `BROWSER_MANAGE`, `WEB_FETCH`, `WEB_SEARCH` `uoDesc` gains
      "always runs on the session machine".
- [ ] Schemas become functions of `[Selectable]`; `buildSessionRegistry` passes it.

**Files (create)**
- `src/Seal/ISA/Ops/Machine.hs`
- `test/Seal/ISA/Ops/MachineSpec.hs`

**Files (edit)**
- the 6 opcode modules, `src/Seal/Core/TurnEngine.hs` (`buildSessionRegistry`)
- `seal-harness.cabal`, `test/Main.hs`

**RED**
```
machineFieldAbsentIsNothing
machineFieldPresentIsJust
schemaEnumListsSelectableNames         -- incl. "local" when allowed
renderMachineErrorSeparator            -- "SHELL_EXEC failed: " exactly (T-STR-1)
unknownMachineRunsNothing              -- zero counters increment (T-NOFALLBACK)
omittedMachineUsesSessionMachine       -- and stays that way on the next call (T-NOSTICKY)
twoMachinesInOneSession                -- each machine's OWN counter (T-TWO)
```

**Depends on:** WU-3.

---

## Phase 3 — Session exec and caching

### WU-5: Per-machine workdirs, lazy bootstrap, cache re-key

**DoD**
- [ ] `SessionExec` gains the resolver and the `IORef (Map MachineName MachineSlot)`.
- [ ] Session machine bootstraps before the first turn (today's behaviour).
- [ ] Other machines bootstrap lazily via `rtResolve`; in-flight bootstraps deduped
      per machine; failures memoized.
- [ ] `ExecCache` fingerprint = `(resolved registry, session machine)`.
- [ ] A failed bootstrap returns a typed `MachineError`, never a stub reason.

**Files (edit)**
- `src/Seal/Session/Workdir.hs`, `src/Seal/Session/ExecCache.hs`

**RED**
```
twoMachinesDistinctWorkdirs            -- workdirs/<sid> per machine
secondCallDoesNotRebootstrap           -- counter on the bootstrap
failedBootstrapMemoized                -- one attempt per session, not per call
cacheRebuildsOnMachinesTomlChange      -- fingerprint changes
cacheRebuildsOnSessionMachineChange
cacheDoesNotRebuildOnLazyHandleAdd     -- runtime state, not config
readOnBWrittenOnAIsNotFound            -- cross-machine isolation (DW test)
```

**Depends on:** WU-2.

---

### WU-6: `allow_localhost`, selector, enforcement

**DoD**
- [ ] `UntrustedExecFileConfig` = `{ uefcAllowLocalhost :: !Bool }`;
      `UntrustedExecRemoteFileConfig` deleted.
- [ ] Decode: whole section absent ⇒ `True`; section present without
      `allow_localhost` ⇒ `Left` (prevents the failed-migration downgrade).
- [ ] `untrustedExecConfigFromSecurity` returns `UntrustedExecConfig` (no `Maybe`).
- [ ] `selectExecBackend` truth table: `allow_localhost` gates `MtLocal` **only**;
      `MtSsh` is always selectable.
- [ ] `enforceRemoteOnly` gains its call site (startup), rejecting
      `allow_localhost = true` in the hardened build.

**Files (edit)**
- `src/Seal/Config/Security.hs`, `src/Seal/Tools/Exec/Untrusted.hs`
- 10 `src` call sites that branch on the old `Maybe`
  (`Workdir.hs:182`, `ExecCache.hs:99`, `Gateway/API.hs:1212,1710`,
  `Command/Serve.hs:538,677`, `Channel/Cli.hs:158,474`,
  `TurnEngine.hs:654,670`)

**RED**
```
absentSectionIsTrue
presentSectionWithoutKeyIsLeft          -- the failed-migration guard
mtLocalFalseIsNeverEbLocal
mtSshIsNeverEbLocal                     -- property over (Bool, MachineTarget)
mtSshSelectableUnderDefault             -- the inverted-table regression
enforceRemoteOnlyHasCallSite            -- hardened build refuses allow_localhost
```

**Depends on:** WU-1, WU-2.

---

## Phase 4 — Config files and migration

### WU-7: `machines.toml` codec, template, paths

**DoD**
- [ ] `machinesFilePath :: SealPaths -> FilePath` → `spHome </> "machines.toml"`.
- [ ] `execKnownHostsPath :: SealPaths -> FilePath` → `spHome </> "exec-known-hosts"`.
- [ ] `loadMachinesConfig` / `saveMachinesConfig` (mode `0600`, `O_NOFOLLOW`,
      `writeSecretFile`).
- [ ] `config/templates/machines.toml` — **every table commented out, no live
      `default`**, mirroring `security.toml:46-58`.
- [ ] `Seal.Config.Templates` seeds it under the never-overwrite invariant.

**Files (create)**
- `config/templates/machines.toml`

**Files (edit)**
- `src/Seal/Config/Paths.hs`, `src/Seal/Config/Machines.hs`,
  `src/Seal/Config/Templates.hs`
- `test/Seal/Config/{PathsSpec,TemplatesSpec}.hs`

**RED**
```
machinesFilePathIsSiblingOfSecurity     -- not under config/
execKnownHostsPathIsHarnessOwned
templateHasNoLiveMachine                -- T-TPL-1: 1 selectable (local), no prompt
templateNeverOverwrites
```

**Depends on:** WU-1.

---

### WU-8: Migration

**DoD**
- [ ] `migrateExecutionMachines` covering all five rows of design §4 plus the
      failure row (§4.1).
- [ ] Idempotent; fail-open but never downgrades (WU-6's decode rule is the
      guard).
- [ ] Drops `known_hosts`; does not carry a stale path across.

**Files (edit)**
- `src/Seal/Config/Migrate.hs`, `test/Seal/Config/MigrateSpec.hs`

**RED**
```
migratesRemoteTableToDefaultMachine     -- T-MIG-1
migratesModeRemoteToFlagFalse
incompleteRemoteWritesNoMachine         -- fail closed at call time, not boot
modeLocalBecomesFlagTrue
existingMachinesTomlWins
idempotentSecondRunIsNoOp
failedWriteDoesNotDowngrade             -- T-MIG-5
```

**Depends on:** WU-6, WU-7.

---

## Phase 5 — Session selection and display

### WU-9: `SessionMeta`, `machineForSession`, config-error renderer

**DoD**
- [ ] `smMachine :: Maybe MachineName`, `smRepoMachine :: Maybe MachineName`,
      tolerant decode (`.:?`), no change to old files.
- [ ] `machineForSession` with the ordered 7-case table (design §5.1), including
      case 5b producing `NoMachineSelected` and 5c `MachineDefaultUnset`.
- [ ] `renderMachineConfigError :: MachineName -> RejectReason -> Text` emitting
      the `machines.toml: ` prefix.

**Files (create)**
- `src/Seal/Session/Machine.hs`
- `test/Seal/Session/MachineSpec.hs`

**Files (edit)**
- `src/Seal/Session/Meta.hs`, `seal-harness.cabal`, `test/Main.hs`

**RED**
```
oldSessionJsonDecodesToNothing          -- back-compat
machineForSessionResolvesPresent
deletedMachineIsMachineGone             -- never the default
rejectedMachineIsMachineUnusable        -- not MachineGone (the round-1 bug)
localUnderFlagIsMachineNotPermitted
noDefaultWithFlagFalseAndEmptyIsNoMachineSelected
noDefaultOtherwiseIsMachineDefaultUnset
renderMachineConfigErrorNamesConfiguredHost  -- 127.0.0.1 renders as written (T-STR-4)
```

**Depends on:** WU-1, WU-6.

---

### WU-10: Session selection plumbing

**DoD**
- [ ] `buildMachinePrompt :: [Selectable] -> Maybe MachineName -> Text` — its own
      pure function; `formatQuestionWithOptions` untouched.
- [ ] TUI prompts when ≥2 selectable; none at 1; empty reply ⇒ default.
- [ ] `NewArgs.naMachine :: Maybe Text`; `parseNewArgs` gains `-x`;
      `Seal.Command.New` gains the fifth optparse flag.
- [ ] `/new -x <unknown>` fails at `/new` time with the valid choices.
- [ ] `GET /api/machines` returning `{selectable, default, unusable}` — names and
      reasons only, never host/user/path.
- [ ] `NewTabComposer` picker at ≥2, defaulted, fed by that endpoint.

**Files (create)**
- `test/Seal/Command/MachinePromptSpec.hs`

**Files (edit)**
- `src/Seal/Channel/Cli.hs` (prompt call), `src/Seal/Command/New.hs`,
  `src-gateway-types/Seal/Gateway/Types/NewArgs.hs`,
  `src/Seal/Gateway/API.hs` (`/api/machines`),
  `frontend/src/components/NewTabComposer.tsx`,
  `frontend/src/hooks/useNewTabSpec.ts`
- `seal-harness.cabal` (both library stanzas — the `.cabal` is a merge hotspot)

**RED**
```
promptAtTwoMachines / noneAtOne / emptyTakesDefault   -- T-STR-8
promptIncludesLocalRow / omitsItWhenFlagFalse
parseNewArgsAgreesWithOptparse                        -- T-STR-11
newWithUnknownMachineFailsBeforeMinting
apiMachinesOmitsCoordinates                           -- no host/user/path in JSON
pickerHiddenAtOne / shownAtTwo                        -- vitest
```

**Depends on:** WU-2, WU-9.

---

### WU-11: Display surfaces

**DoD**
- [ ] TUI tab line (`Cli.hs:461` `renderTab`) gains the machine.
- [ ] TUI `/session list` (`Session.hs:71`) gains a machine column.
- [ ] TUI banner (`Cli.hs:188`) appends `  machine: <name>`, **after** any
      `  agent: <id>` suffix.
- [ ] Web `SessionInfo` gains `machine`; `sessionInfoJson` emits it (resolved
      name for legacy sessions, never `null`).
- [ ] `TabLineField` union gains `'machine'`; `ALL_TAB_LINE_FIELDS` and
      `DEFAULT_TAB_LINE_FIELDS` updated; `tabLineConfig.test.ts`'s
      `toHaveLength(5)` updated to 6.
- [ ] Sidebar renders it.

**Files (edit)**
- `src/Seal/Channel/Cli.hs`, `src/Seal/Command/Session.hs`,
  `src/Seal/Gateway/SessionJson.hs`
- `frontend/src/types.ts`, `components/{Sidebar,ActiveTabs}.tsx`,
  `lib/tabLineConfig.ts`, `lib/__tests__/tabLineConfig.test.ts`

**RED**
```
renderTabIncludesMachine                -- T-STR-10 exact
renderSessionLineIncludesMachineColumn
bannerAppendsMachineAfterAgent          -- T-STR-9, agent-free session
sessionInfoJsonMachineNeverNull         -- legacy session shows resolved
tabLineFieldsIncludesMachine            -- toHaveLength(6)
sessionInfoJsonAgreesWithRenderTab      -- T-STR-12 shared projection
```

**Depends on:** WU-9.

---

## Phase 6 — Transcript, SETUP_REPO, commands

### WU-12: ACK record names the machine

**DoD**
- [ ] `resolveMachineForCall` — pure-ish, no SSH, no handle build.
- [ ] `dispatch` resolves **before** `itwRecordAndAck` and stamps the resolved
      name into the invocation entry.
- [ ] `mkInvocationEntryWithMachine`; `erMeta` gains `"machine"` only for
      untrusted opcodes.
- [ ] `opAuthorize` still runs **first** — a denied call must not resolve a
      machine and must not record one.

**Files (edit)**
- `src/Seal/ISA/Dispatch.hs`, `test/Seal/ISA/DispatchSpec.hs`

**RED**
```
recordNamesResolvedMachine              -- T-ACK: erMeta.machine == resolved
recordWrittenBeforeExecution            -- ordering preserved
omittedMachineRecordsSessionMachine     -- not absent
deniedCallRecordsNoMachine              -- authorize precedes resolution
recordedNameCannotDivergeFromExecuted   -- resolved == executed
```

**Depends on:** WU-4.

---

### WU-13: `SETUP_REPO` on a non-session machine

**DoD**
- [ ] Clone runs on the named machine.
- [ ] When `machine ≠ session machine`: **no** auto-bind, **no** re-scan, **no**
      cache invalidation.
- [ ] `smRepoMachine` recorded.
- [ ] Result text states that relative follow-up paths resolve on the **session**
      machine.

**Files (edit)**
- `src/Seal/Core/TurnEngine.hs` (~1147-1197), `src/Seal/ISA/Ops/Repo.hs`,
  `test/Seal/ISA/Ops/RepoSpec.hs`

**RED**
```
setupRepoOnOtherMachineSkipsAutoBind
setupRepoOnOtherMachineRecordsRepoMachine
setupRepoResultTextNamesSessionMachine
setupRepoOnSessionMachineUnchanged      -- regression guard
```

**Depends on:** WU-5, WU-9.

---

### WU-14: `/machine list` and `seal machine pin`

**DoD**
- [ ] `Seal.Command.Machine` with `/machine list` registered in
      `coreCommandSpecs` under **`GroupGeneral`** (no new `CommandGroup`
      constructor — it would renumber the `Enum` and break `HelpSpec` ordering).
- [ ] Output exactly: `selectable:` / `default:` / `unusable:` lines; the latter
      two omitted when empty/unset.
- [ ] `CommandMachine MachineAction` in `Seal.Types.Command`, dispatch in
      `AppMain.hs`, **entry in `reorderGlobalArgs`' subcommand list**.
- [ ] `seal machine pin <name> [--key-file PATH | --fingerprint SHA256:…]`:
      verifies a probe against supplied material; `--yes` alone never appends an
      unverified key; idempotent; errors if the name is absent from
      `machines.toml`; never bypasses the loopback refusal.

**Files (create)**
- `src/Seal/Command/Machine.hs`
- `test/Seal/Command/MachineSpec.hs`

**Files (edit)**
- `src/Seal/Command/Registry.hs`, `src/Seal/Types/Command.hs`,
  `src/Seal/AppMain.hs`, `seal-harness.cabal`, `test/Main.hs`

**RED**
```
machineListExactOutput                  -- T-STR-11
machineListOmitsEmptySections
machineListRegisteredUnderGroupGeneral  -- HelpSpec ordering intact
reorderGlobalArgsKnowsMachine           -- --log-level hoisting still works
pinVerifiesAgainstFingerprint / MismatchFails
pinKeyFileRequiresMatch
pinWithoutMaterialRequiresConfirmation
pinIdempotent
pinUnknownNameErrors
pinRefusesLoopback
```

**Depends on:** WU-1, WU-9.

---

## Phase 7 — Host keys and the hardened build

### WU-15: Host-key guard and adoption copy

**DoD**
- [ ] `scKnownHosts` filled from `execKnownHostsPath` at the single construction
      site (the machine resolver).
- [ ] Resolution-based loopback refusal at connect (`getaddrinfo`); refuse if any
      address is loopback/unspecified/local-interface.
- [ ] Self-key comparison at connect against `/etc/ssh/ssh_host_*_key.pub`
      (configurable); unreadable ⇒ skip.
- [ ] `hkaAdopt :: MachineName -> SshConfig -> IO (Either Text ())`;
      `HostKeyInfo` gains `hkiMachine`; `buildAdoptionPrompt` renders the
      requirement's four lines.
- [ ] `execErrorToMachineError :: MachineName -> ExecError -> MachineError`.
- [ ] Callers updated: `Workdir.hs:194-215`, `mkSessionExec`, `rtResolve`.

**Files (edit)**
- `src/Seal/Tools/Exec/{HostKeyAdoption,UntrustedIO,Remote}.hs`,
  `src/Seal/Session/Workdir.hs`, `src/Seal/Config/Machines.hs`
- ~18 test fixture sites (`scKnownHosts = …`)

**RED**
```
connectRefusesResolvedLoopback          -- mybox.lan → 127.0.0.1
connectRefusesSelfHostKey
selfKeyCheckSkippedWhenUnreadable       -- degrades, does not fail
adoptionPromptExactCopy                 -- T-STR-7
hostKeyChangedRendersFrozenText         -- T-STR-3 via the mapping
unknownKeyRefusedWithoutHuman
changedKeyNeverOfferedForAdoption
sshKeyscanPortKeying                    -- T-HK-PORT
```

**Depends on:** WU-9.

---

### WU-16: `-f remote-only-untrusted` actually builds

**DoD**
- [ ] Fix the unconditional `import Seal.Tools.Exec.Local` in
      `UntrustedIO.hs:79` (CPP-gate or move the two functions) so the flag
      compiles — it likely does not today (design §13.3).
- [ ] `Makefile` target and a `.github/workflows/` step building + testing with
      the flag.
- [ ] `enforceRemoteOnly` call site verified under the flag (WU-6).

**Files (edit)**
- `src/Seal/Tools/Exec/UntrustedIO.hs`, `seal-harness.cabal`,
  `Makefile`, `.github/workflows/{ci,gate}.yml`

**RED**
```
cabal build all -f remote-only-untrusted   -- succeeds
cabal test  -f remote-only-untrusted       -- succeeds
```

**Depends on:** WU-6.

**Note:** this fixes a **pre-existing** break, not one this feature introduces.
Done-when 15 depends on it, so it is in scope here.

---

### WU-17: Docs and copy

**DoD**
- [ ] `config/templates/security.toml` — replace the `mode`/`known_hosts` section
      with `allow_localhost`, pointing at `machines.toml`.
- [ ] `CHANGELOG.md` entry: operator-visible config schema change
      (`mode` → `allow_localhost`, `[untrusted_execution.remote]` →
      `machines.toml`), with the migration note.

**Files (edit)**
- `config/templates/security.toml`, `CHANGELOG.md`

**RED**
```
TemplatesSpec: security template has no "mode" key
CHANGELOG grep: allow_localhost mentioned
```

**Depends on:** WU-7.

---

## Full suite gate

After WU-17:

```bash
make check                                   # build + test + lint
nix develop --command cabal build all -f remote-only-untrusted
nix develop --command cabal test        -f remote-only-untrusted
nix develop --command cabal test >test.log 2>&1; tail -40 test.log
```

All green before `gh pr ready`.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| WU-3 is a large atomic diff (~289 sites) | Compile-driven checklist; do not try to keep green mid-unit; it is the only unsplittable unit |
| `.cabal` + `test/Main.hs` edited by 8 units | Minimal edits per unit; rebase `main` before `gh pr ready` |
| Two config files can disagree | Resolver takes `allow_localhost` as a parameter (WU-1); decode rule in WU-6 prevents silent downgrade |
| Frontend tests break on `TabLineField` | WU-11 updates `toHaveLength(5)` → 6 in the same commit |
| Migration is fail-open | WU-6's decode rule turns the dangerous state into a visible boot error; WU-8 asserts it |
