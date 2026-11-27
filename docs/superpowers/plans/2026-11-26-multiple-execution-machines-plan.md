# Multiple Execution Machines — Implementation Plan

> **Design:** `docs/superpowers/specs/2026-11-26-multiple-execution-machines-design.md` (revision 4, accepted)
> **Requirements:** `docs/superpowers/requirements/2026-11-26-multiple-execution-machines-requirements.md` (frozen, 2 amendments)
> **Branch:** `feature/multiple-execution-machines` · **PR** #354
> **Revision 2** — after Plan Review Gate round 1 (Feasibility FAIL, Completeness FAIL)
> and two late design findings.

## 0. What revision 1 got wrong

| # | Finding | Reviewer | Fix |
|---|---|---|---|
| P1 | **No boot wiring.** `resolveMachines` + `loadMachinesConfig` are never called from startup; WU-4/5/10 consume a registry nobody builds | Completeness | **WU-7b** (new) |
| P2 | **No writer for `smMachine`.** Field added, selection made, never persisted; `Store.hs:86-100` + `Worker.hs:440-455` out of scope | Completeness | **WU-10** scope + RED |
| P3 | **`GET /api/machines` needs 4 files not in scope.** Typed `SealRoute` GADT: constructor + `routeMeta` arm + `allRoutes` entry (`Route.hs:81-118,190-219,278-308`), `openApiMeta` arm (`OpenApi.hs:79`), `expectedRouteCount` 81→82 (`ApiRouteSpec.hs:19`) | Feasibility | **WU-10** scope |
| P4 | **WU-5 forward-depends on WU-7.** Its fingerprint test needs `loadMachinesConfig`, created two units later | Feasibility | WU-5 → after WU-7 |
| P5 | **WU-3 omits `Browser.hs`** (`:97` calls `uioBinExec`) so it cannot compile | Feasibility | **WU-3** scope |
| P6 | **WU-6 lists no test files.** 5 modules construct the deleted symbols; `-Werror` breaks them | Feasibility | **WU-6** scope |
| P7 | **WU-4's `uoDesc` edits live outside its scope** (`Browser.hs:79`, `Web/Fetch.hs:46`, `Web/Search.hs:115`) | Feasibility | **WU-4** scope |
| P8 | **Host keys had no owning unit** at all (§3.1/3.2/3.4 undelivered) | CTO | **WU-15** (was mis-scoped) |
| P9 | **No multi-machine test seam.** `mkTestUIOEnv` singleton routing cannot express 2 machines; DW-11 unbuildable | CTO | **WU-2** + RED |
| P10 | **DW-14 half-vacuous.** Post-execution stamping passes a success-path assertion | CTO | **WU-12** RED |
| P11 | **Frozen strings 2, 5, 6, 8 unasserted** (RED stopped at the ADT constructor) | Completeness | WU-4/9/10 RED |
| P12 | **`mtSshCannotCarryMismatchedName` unfalsifiable** — true by construction | Completeness | deleted |
| P13 | **WU-3 splittable** after WU-2; my "atomic" claim was wrong | CTO | resolved differently — see P20 |
| P14 | **`machines.toml` malformed unhandled** | Completeness | **WU-7** RED |
| P15 | **`make check` is 4 targets** + frontend build, not 3 | Feasibility | corrected below |
| P16 | **`mkSessionUntrustedIO` + its back-compat test** assert the escape hatch being deleted | Completeness | **WU-3b** |
| P17 | **`FileExplorer`, `AgentMetaCache` in no unit** | Completeness | **WU-6b** (new) |
| P18 | **Rollback direction unsafe**: reverting the binary after migration leaves no `[untrusted_execution]` ⇒ old codec defaults to local | Completeness | **WU-8b** |
| P19 | **`enforceRemoteOnly` call site unnamed**; hardened build can still run locally via unguarded `mkLocalUntrustedIO` at `Workdir.hs:188` | Security | **WU-16** |

**Round 2 of the plan gate** (Feasibility FAIL, Completeness FAIL, Scope FAIL
in round 1; this batch is Scope round 1's findings):

| # | Finding | Reviewer | Fix |
|---|---|---|---|
| P20 | **Materially simpler design available**: resolve `machine` in `dispatch` and swap `uieUntrustedIO` per call, leaving all 12 `uio*` signatures untouched | Scope | **WU-3** rewritten; WU-3a/3b deleted; ~289 sites avoided. Operator approved the switch |
| P21 | **WU-8 retained `mode` for rollback**, contradicting "loses `[untrusted_execution] mode`" and making Done-when 2 unpassable | Scope | Retention removed; hazard documented in CHANGELOG instead |
| P22 | **WU-10 added chat-channel `ASK_HUMAN`**, but the requirements say "no interactive prompt; the configured default is used" | Scope | Removed; unset ⇒ `MachineDefaultUnset` |

## How to read this plan

20 work units in 8 phases. Each has DoD, file scope, dependencies, and a RED
block — the assertions that must fail before the unit starts.

**`make check` is four targets plus an npm build**: `check: build test lint
frontend-test`, and `build` depends on `frontend-build` (`Makefile:39,26`). Use
the individual targets when iterating, the whole thing before a commit.

**Rules for every unit** (AGENTS.md): failing test first; never `--no-verify` or
force-push; stay inside declared scope; a new module is wired in three places
(library `exposed-modules:`, test `other-modules:`, `test/Main.hs`); `hlint` must
report "No hints".

**Route registration**: any new HTTP route needs **five** edits —
`Route.hs` constructor + `routeMeta` arm + `allRoutes` entry, `OpenApi.hs`
`openApiMeta` arm, and `ApiRouteSpec.hs:19`'s `expectedRouteCount`. `-Werror`
with a non-exhaustive `openApiMeta` case is a hard build error.

**SIGPIPE**: never pipe `cabal`/`hlint` through `head`/`tail`. Redirect to a file.

---

## Phase 1 — Pure foundations

### WU-1: Machine names and config resolution

**DoD**
- [ ] `MachineName` newtype + smart constructor: ASCII alphanumeric plus `-`/`_`/`.`;
      rejects empty, leading `-`, leading `.`, bare `.`/`..`, len > 64, reserved `local`.
- [ ] `MachinesConfig`, `MachineFileConfig` tomland codec.
- [ ] `MachineTarget = MtLocal | MtSsh !SshConfig` (name in the map key only).
- [ ] `RejectReason = RrMissingField !MissingField | RrLoopbackHost !Text | RrInvalidHost !Text | RrInvalidWorkspace !Text | RrInvalidPort` — **`RrLoopbackHost` carries the configured host**.
- [ ] `MachineRegistry { regMachines, regRejected, regDefault }`.
- [ ] `resolveMachines :: Bool -> SealPaths -> MachinesConfig -> MachineRegistry`
      — pure; the flag and paths are parameters, so it reads neither config file.
- [ ] Order: field validation → loopback guard **before** host validation → `local`
      injected iff flag → `regDefault` resolved or dropped with a warning.
- [ ] `isLoopbackHost`: `localhost`, `127.0.0.0/8`, `::1`, `[::1]`, `0.0.0.0`, `::`.
- [ ] `loadMachinesConfig` returns `Either Text MachinesConfig` (WU-7 owns the file IO;
      WU-1 owns decode).

**Files (create)** `src/Seal/Config/Machines.hs`, `test/Seal/Config/MachinesSpec.hs`
**Files (edit)** `seal-harness.cabal`, `test/Main.hs`
**Depends on** nothing.

**RED**
```
machineNameRejectsReservedLocal / LeadingDash / Empty / DotDot / TooLong
machineNameAcceptsValid
loopbackBeforeHostValidation            -- "localhost" → RrLoopbackHost "localhost"
loopbackCarriesConfiguredHost           -- "127.0.0.1" → RrLoopbackHost "127.0.0.1"
missingWorkspaceRejected                -- RrMissingField Workspace
localInjectedIffAllowLocalhost          -- property + checkCoverage both arms
localTableIgnoredWithWarning
defaultNamingMissingMachineDropped      -- regDefault = Nothing + warning
malformedTomlIsLeft                     -- decode failure surfaces, not silent-empty
```

### WU-2: Routing in `UIOEnv`, slots, errors, test seams

**DoD**
- [ ] `MachineError` per design §5.2, typed payloads only:
      `MachineUnreachable !MachineName !UnreachableReason`,
      `MachineHostKeyChanged !MachineName`. No free `Text` payload.
- [ ] `UnreachableReason = UrConnectFailed | UrBootstrapFailed | UrHostKeyUnknown`.
- [ ] **`UIOEnv` gains a third field `uieMachines :: !MachineRouting`** — without
      it `dispatch` cannot reach the routing at all.
- [ ] `Seal.Tools.Exec.Machine` exports the **selectors** `rtResolve`,
      `rtSession`, `rtSelectable` but **not** the `MachineRouting` constructor, so
      callers can read the routing and cannot forge one.
- [ ] **`MachineSlot` carries `CloneDeps` too**:
      `SlotReady !UntrustedIO !CloneDeps | SlotFailed !MachineError`. `CloneDeps`
      is transport-bound (`cdIsRemote`, `cdPinnedKnownHosts`,
      `SourceControl/Clone.hs:245,247`), so a call routed to machine B must get
      B's clone deps, not the session machine's — otherwise WU-13's cross-machine
      `SETUP_REPO` clones with a B handle and session transport.
- [ ] Pure resolver over a registry, independent of `SessionMeta` (so WU-3 does not
      forward-depend on WU-9):
      `resolveName :: MachineRouting -> Maybe MachineName -> Either MachineError MachineName`.
- [ ] `MachineRouting { rtResolve, rtSession, rtSelectable }` — constructor and
      fields **not exported**.
- [ ] `MachineSlot = SlotReady !UntrustedIO | SlotFailed !MachineError`.
- [ ] `Selectable = SelLocal | SelMachine !MachineName` (**defined here**, not WU-1).
- [ ] `mkTestUIOEnv` keeps arity, defaulting to singleton routing.
- [ ] **`mkTestUIOEnvWith :: [(MachineName, UntrustedIO)] -> MachineName -> CloneDeps -> UIOEnv`**
      — the multi-machine seam. Without it DW-11/DW-12/T-NOFALLBACK are unbuildable.
- [ ] `mkTestMachineRouting` for the same reason.

**Files (create)** `src/Seal/Tools/Exec/Machine.hs`, `test/Seal/Tools/Exec/MachineSpec.hs`
**Files (edit)** `src/Seal/Tools/Exec/UIO/Internal.hs`, `seal-harness.cabal`, `test/Main.hs`
**Depends on** WU-1.

**RED**
```
machineRoutingCtorNotExported             -- compile-fail: cannot construct
machineRoutingSelectorsExported           -- rtResolve/rtSession readable
uioEnvHasRoutingField                     -- dispatch can reach it
slotCarriesCloneDeps                      -- per-machine clone deps
mkTestUIOEnvEtaReducedStillCompiles       -- 3-field record, point-free ctor
machineRoutingConstructorNotExported     -- compile-fail fixture
mkTestUIOEnvSingletonStillWorks          -- existing 109 sites compile + behave
mkTestUIOEnvWithTwoMachines              -- 2 distinct handles resolvable
slotMemoizesFailure                      -- second resolve of Failed does not retry
rejectReasonPayloadExcludedFromModelView -- negative: no host text in any render
```

---

## Phase 2 — The per-call seam

### WU-3: Dispatcher-side resolution

**Changed by operator decision** — replaces revision 2's WU-3a/WU-3b. No `uio*`
signature changes, so the ~289 call sites and `Browser.hs` are untouched, and
`mkSessionUntrustedIO`/`uioUntrustedIO`/`uieUntrustedIO` all stay.

**DoD**
- [ ] `resolveMachineForCall :: UIOEnv -> Value -> Either MachineError MachineName`
      in `Seal.ISA.Dispatch` — no SSH, no handle build. Uses WU-2's
      `resolveName` (pure, registry + maybe-name), **not** `machineForSession`,
      so this unit does not depend on WU-9.
- [ ] **`Dispatch.hs:46` widens its import to `Seal.Tools.Exec.UIO.Internal (UIOEnv (..))`**
      — the record update below does not compile against a type-only import.
- [ ] `dispatch` resolves after `opAuthorize` and before `itwRecordAndAck`, then
      builds the per-call env **swapping both capability fields**:

      ```haskell
      (handle, cloneDeps) <- rtResolve (uieMachines uioEnv) resolved
      let callEnv = uioEnv { uieUntrustedIO = handle
                           , uieCloneDeps   = cloneDeps }
      ```

      and runs `runUIOWithEnv callEnv` at the existing single binding site.
- [ ] `rtResolve` may bootstrap lazily; a failed bootstrap surfaces as a
      `MachineError` naming the machine, never `ExecNotImplementedReason`.
- [ ] Resolution failure produces a tool error naming the valid choices **before
      any `uio*` call**.
- [ ] `mkTestUIOEnv`'s eta-reduced `UIOEnv` construction and the three positional
      sites (`Internal.hs:120,129,132`) are updated for the third field.

**Files (edit)** `src/Seal/ISA/Dispatch.hs`, `test/Seal/ISA/DispatchSpec.hs`
**Depends on** WU-2. *(Not WU-9 — it uses WU-2's pure `resolveName`, not `machineForSession`.)*

**RED**
```
resolvePicksNamedMachine / resolveDefaultsToSession
callEnvSwapsBothCapabilities              -- handle AND cloneDeps
resolveUnknownNamesChoices                -- error lists selectable
callEnvCarriesTargetHandle                 -- uieUntrustedIO == resolved handle
unknownMachineRunsNothing                  -- zero counters (T-NOFALLBACK)
omittedMachineUsesSessionMachine           -- T-NOSTICKY
twoSshMachinesInOneSession                 -- 2 runners, 2 counters (T-TWO)
uioSignaturesUnchanged                     -- no uio* takes an ExecTarget
dispatchImportsUIOEnvFields                -- record update compiles
```

### WU-4: `machine` in the opcode schemas + error rendering

**DoD**
- [ ] `machineField`, `machineSchemaProp :: [Selectable] -> Value`,
      `renderMachineError :: OpName -> MachineError -> Text` in `Seal.ISA.Ops.Machine`.
- [ ] Separator is **`" failed: "`** — `\(OpName n) -> n <> " failed: " <> body err`.
- [ ] The 8 untrusted opcode **schemas** gain the optional `machine` property.
      `uoRun` bodies are unchanged (WU-3 consumes it).
- [ ] `uoDesc` gains "always runs on the session machine" on
      **`Browser.hs:79`, `src/Seal/Web/Fetch.hs:46`, `src/Seal/Web/Search.hs:115`**.
- [ ] Schemas become functions of `[Selectable]`; `buildSessionRegistry` passes it.
- [ ] **Every `RejectReason` except `RrMissingField Workspace` renders payload-free**
      for the model — `renderMachineError` is total, so an unspecified constructor
      leaks host text.

**Files (create)** `src/Seal/ISA/Ops/Machine.hs`, `test/Seal/ISA/Ops/MachineSpec.hs`
**Files (edit)** every `uoInSchema` site for the 8 machine-selectable opcodes —
`Shell.hs:51`, `Bin.hs:89`, `Process.hs:28`, `Search.hs:36`, `Repo.hs:111`,
`File.hs:145,239,331` (9 sites, 6 modules) — plus the `uoDesc` note on
`Browser.hs:81`, `Web/Fetch.hs:45-46`, `Web/Search.hs:114-115`.
`Media/Image.hs` and `Media/Tts.hs` are **not** machine-selectable (they do not
use `UntrustedIO` for transport) and are unchanged.
Also: `src/Seal/Core/TurnEngine.hs`, `seal-harness.cabal`, `test/Main.hs`.
**Depends on** WU-2.

**RED**
```
machineFieldAbsentIsNothing / PresentIsJust
schemaEnumListsSelectableNames            -- incl. "local" when allowed
renderMachineErrorSeparator               -- "SHELL_EXEC failed: " exact (T-STR-1)
renderUnusableText                        -- T-STR-2 exact
renderGoneText                            -- T-STR-5 exact
renderNoMachineText                       -- T-STR-6 exact
rejectReasonNeverLeaksHost                -- negative: RrInvalidHost payload absent
```

---

## Phase 3 — Config files (WU-7 only; WU-8 moved to Phase 4)

### WU-7: `machines.toml`, template, paths, boot wiring

**DoD**
- [ ] `machinesFilePath`, `execKnownHostsPath` in `Seal.Config.Paths`.
- [ ] `loadMachinesConfig` / `saveMachinesConfig` — mode `0600`, `O_NOFOLLOW`,
      `writeSecretFile`.
- [ ] `config/templates/machines.toml` — **every table commented out, no live
      `default`**.
- [ ] `Seal.Config.Templates` seeds it, never overwriting.
- [ ] **`resolveMachinesForBoot :: SealPaths -> IO (Either Text MachineRegistry)`** —
      loads both configs and resolves. This is the boot entry point the rest of the
      plan consumes (P1).
- [ ] **Malformed `machines.toml` fail-closes at boot** with a message naming the
      file, mirroring `security.toml`'s precedent (`Serve.hs:201-205`).

**Files (create)** `config/templates/machines.toml`
**Files (edit)** `src/Seal/Config/{Paths,Machines,Templates}.hs`,
`test/Seal/Config/{PathsSpec,TemplatesSpec,MachinesSpec}.hs`
**Depends on** WU-1.

**RED**
```
machinesFilePathIsSiblingOfSecurity
execKnownHostsPathIsHarnessOwned
templateHasNoLiveMachine                  -- T-TPL-1: 1 selectable, no prompt
templateNeverOverwrites
malformedTomlFailsClosedAtBoot            -- names the file
resolveMachinesForBootReturnsRegistry
```

### WU-8: Migration + rollback safety

**DoD**
- [ ] `migrateExecutionMachines`, all five rows of design §4 + the failure row.
- [ ] Idempotent; fail-open but never downgrades.
- [ ] Drops `known_hosts`.
- [ ] **`mode` is removed on the migration boot**, as the frozen requirements
      state ("loses `[untrusted_execution] mode`"; "removed from `security.toml`
      once the new copy is written"). Done-when 2 asserts "with the old block gone".
      Retaining `mode` for rollback convenience was rejected: it would make DW-2
      unpassable and is a new requirement, not a review fix. The revert hazard is
      documented in the CHANGELOG instead (WU-17), not engineered around.

**Files (edit)** `src/Seal/Config/Migrate.hs`, `test/Seal/Config/MigrateSpec.hs`
**Depends on** WU-6, WU-7. *Moved to Phase 4 — it needs WU-6's `uefcAllowLocalhost`.*

**RED**
```
migratesRemoteTableToDefaultMachine       -- T-MIG-1 + pinning clause
migratesModeRemoteToFlagFalse
incompleteRemoteWritesNoMachine
modeLocalBecomesFlagTrue
existingMachinesTomlWins
idempotentSecondRunIsNoOp
failedWriteDoesNotDowngrade               -- T-MIG-5
modeRemovedOnMigrationBoot                -- DW-2: old block gone
```

---

## Phase 4 — `allow_localhost`, then migration, then session exec

### WU-6: `allow_localhost`, selector, enforcement

**DoD**
- [ ] `UntrustedExecFileConfig = { uefcAllowLocalhost :: !Bool }`;
      `UntrustedExecRemoteFileConfig` deleted.
- [ ] Decode: whole section absent ⇒ `True`; present without the key ⇒ `Left`.
- [ ] `untrustedExecConfigFromSecurity` returns `UntrustedExecConfig` (no `Maybe`).
- [ ] Selector: `allow_localhost` gates `MtLocal` **only**; `MtSsh` always selectable.
- [ ] `enforceRemoteOnly` gains a call site **in both boot paths**
      (`Command/Serve.hs` and `Channel/Cli.hs`).

**Files (edit)** `src/Seal/Config/Security.hs`, `src/Seal/Tools/Exec/Untrusted.hs`,
`src/Seal/Command/Serve.hs`, `src/Seal/Channel/Cli.hs`,
and the 10 `Maybe`-branching sites (`Workdir.hs:182`, `ExecCache.hs:99`,
`API.hs:1212,1710`, `Serve.hs:538,677`, `Cli.hs:158,474`, `TurnEngine.hs:654,670`).

**Files (edit — tests, P6)** `test/Seal/Session/ExecCacheSpec.hs`,
`test/Seal/Config/SecuritySpec.hs`, `test/Seal/TestHelpers/ApiTestHarness.hs`,
`test/Seal/Config/WorkdirSpec.hs`, `test/Seal/Config/TemplatesSpec.hs`

**Depends on** WU-1, WU-2.

**RED**
```
absentSectionIsTrue
presentSectionWithoutKeyIsLeft
mtLocalFalseIsNeverEbLocal / mtSshIsNeverEbLocal      -- property, cover 20%
mtSshSelectableUnderDefault                            -- inverted-table regression
enforceRemoteOnlyCalledInServeAndCli
```

### WU-6b: FileExplorer and AgentMetaCache machine binding

**DoD (P17)**
- [ ] `mkRemoteFileExplorer` built per **session machine**, not once at boot from
      one `SshConfig`.
- [ ] `AgentMetaCache`'s `mceSshCfg` sourced from the registry.
- [ ] `handleSessionWorkdir` (`API.hs:1710`) follows the session machine.

**Files (edit)** `src/Seal/Tools/Exec/FileExplorer.hs`, `src/Seal/Command/Serve.hs:677`,
`src/Seal/Session/AgentMetaCache.hs`, `src/Seal/Gateway/API.hs:1710`,
`src/Seal/Core/TurnEngine.hs:655`
**Depends on** WU-6.

**RED**
```
fileExplorerFollowsSessionMachine
agentMetaCacheEnvFromRegistry             -- not the deleted UemRemote pattern
handleSessionWorkdirUsesSessionMachine
```

### WU-5: Per-machine workdirs, lazy bootstrap, cache re-key

**DoD**
- [ ] `SessionExec` gains the resolver + `IORef (Map MachineName MachineSlot)`.
- [ ] Session machine bootstraps before the first turn; others lazily; failures memoized.
- [ ] `ExecCache` fingerprint = `(resolved registry, session machine)`.
- [ ] `cachedSessionExec`/`mkSessionExec` signature gains the registry.

**Files (edit)** `src/Seal/Session/{Workdir,ExecCache}.hs`,
**and the callers (P7)**: `src/Seal/Gateway/API.hs:1652,1656`,
`src/Seal/Core/TurnEngine.hs:689,1079,1116,1313,1390`
**Depends on** WU-2, WU-7 (moved after WU-7 per P4).

**RED**
```
twoMachinesDistinctWorkdirs
secondCallDoesNotRebootstrap
failedBootstrapMemoized
cacheRebuildsOnMachinesTomlChange / OnSessionMachineChange
cacheDoesNotRebuildOnLazyHandleAdd
readOnBWrittenOnAIsNotFound
```

---

## Phase 5 — Session selection and display

### WU-9: `SessionMeta`, `machineForSession`, config-error renderer

**DoD**
- [ ] `smMachine`, `smRepoMachine` on `SessionMeta`, tolerant decode.
- [ ] `machineForSession` with the ordered 7-case table; case 5b → `NoMachineSelected`,
      5c → `MachineDefaultUnset`; case 2 → `MachineUnusable`; case 3 →
      `MachineNotPermitted`.
- [ ] `renderMachineConfigError :: MachineName -> RejectReason -> Text` with the
      `machines.toml: ` prefix (T-STR-4).
- [ ] **`SessionMeta` construction sites updated** (`Store.hs:86-100`,
      `Worker.hs:440-455`, `:564-576`) — additive fields still break positional records.

**Files (create)** `src/Seal/Session/Machine.hs`, `test/Seal/Session/MachineSpec.hs`
**Files (edit)** `src/Seal/Session/Meta.hs`, `src/Seal/Session/Store.hs`,
`src/Seal/Agent/Runtime/Delegation/Worker.hs`, `seal-harness.cabal`, `test/Main.hs`
**Depends on** WU-1, WU-6.

**RED**
```
oldSessionJsonDecodesToNothing
machineForSessionResolvesPresent
deletedMachineIsMachineGone
rejectedMachineIsMachineUnusable          -- not MachineGone (round-1 bug)
localUnderFlagIsMachineNotPermitted
noDefaultFlagFalseEmptyIsNoMachineSelected -- T-STR-6 exact, not just the ctor
noDefaultOtherwiseIsMachineDefaultUnset
renderConfigErrorNamesConfiguredHost      -- T-STR-4 exact, 127.0.0.1 as written
storeAndWorkerConstructMetaWithMachine
```

### WU-10: Session selection plumbing, incl. persistence

**DoD**
- [ ] `buildMachinePrompt :: [Selectable] -> Maybe MachineName -> Text`
      (its own pure function; `formatQuestionWithOptions` untouched).
- [ ] TUI prompts at ≥2, none at 1, empty ⇒ default.
- [ ] **Chat channels**: default used silently. **No interactive prompt** — the
      requirements are explicit ("no interactive prompt; the configured default is
      used"). When no default is configured the session fails with
      `MachineDefaultUnset`; there is no `ASK_HUMAN` fallback.
- [ ] `NewArgs.naMachine :: Maybe Text`; `parseNewArgs` gains `-x`;
      `Seal.Command.New` gains the fifth optparse flag.
- [ ] `/new -x <unknown>` fails at `/new` time with the valid choices.
- [ ] **The selection is persisted into `smMachine`** at session creation
      (`newSessionMeta`/`newSession` gain a machine parameter) — P2.
- [ ] `GET /api/machines` — **full route registration (P3)**:
      `SealRoute` constructor + `routeMeta` arm + `allRoutes` entry
      (`src-gateway-types/Seal/Gateway/Types/Route.hs`), `openApiMeta` arm
      (`src/Seal/Gateway/OpenApi.hs:79`), `expectedRouteCount` 81→82
      (`test/Seal/Gateway/ApiRouteSpec.hs:19`).
- [ ] Response carries names + reasons only, never host/user/path.
- [ ] `NewTabComposer` picker at ≥2, defaulted.

**Files (edit)** `src/Seal/Channel/Cli.hs`, `src/Seal/Command/New.hs`,
`src-gateway-types/Seal/Gateway/Types/{NewArgs,Route}.hs`,
`src/Seal/Gateway/{API,OpenApi}.hs`, `src/Seal/Session/Store.hs`,
`src-chat-channels/Seal/Channels/Chat/Loop.hs`,
`test/Seal/Gateway/ApiRouteSpec.hs`,
`frontend/src/{components/NewTabComposer.tsx,hooks/useNewTabSpec.ts}`
**Depends on** WU-2, WU-9.

**RED**
```
promptAtTwo / noneAtOne / emptyTakesDefault     -- T-STR-8 exact layout
promptIncludesLocalRow / omitsItWhenFlagFalse
parseNewArgsAgreesWithOptparse                  -- T-STR-11
newWithUnknownMachineFailsBeforeMinting
selectionPersistedToSmMachine                   -- P2
resumeUsesRecordedNotDefault                    -- T-RESUME (DW-9)
chatChannelUsesDefault / asksWhenUnset
apiMachinesRouteRegistered                      -- route count 82 + OpenAPI arm
apiMachinesOmitsCoordinates                     -- negative
pickerHiddenAtOne / shownAtTwo                  -- vitest
```

### WU-11: Display surfaces

**DoD**
- [ ] TUI tab line (`Cli.hs:461` `renderTab`) gains the machine.
- [ ] TUI `/session list` (`Session.hs:71`) gains a machine column.
- [ ] TUI banner (`Cli.hs:188`) appends `  machine: <name>` **after** any `  agent:`.
- [ ] Web `SessionInfo` gains `machine`; `sessionInfoJson` emits it (resolved
      name for legacy sessions, never `null`).
- [ ] `TabLineField` union gains `'machine'`; `ALL_TAB_LINE_FIELDS` /
      `DEFAULT_TAB_LINE_FIELDS` updated; `toHaveLength(5)` → 6.
- [ ] Sidebar renders it.

**Files (edit)** `src/Seal/Channel/Cli.hs`, `src/Seal/Command/Session.hs`,
`src/Seal/Gateway/SessionJson.hs`, `frontend/src/types.ts`,
`components/{Sidebar,ActiveTabs}.tsx`, `lib/tabLineConfig.ts`,
`lib/__tests__/tabLineConfig.test.ts`
**Depends on** WU-9.

**RED**
```
renderTabIncludesMachine                  -- T-STR-10 exact
renderSessionLineIncludesMachineColumn
bannerAppendsMachineAfterAgent            -- T-STR-9, agent-free session
sessionInfoJsonMachineNeverNull
tabLineFieldsIncludesMachine               -- toHaveLength(6)
sessionInfoJsonAgreesWithRenderTab         -- T-STR-12
```

---

## Phase 6 — Transcript, SETUP_REPO, commands

### WU-12: ACK record names the machine

**DoD**
- [ ] Consumes WU-3's `resolveMachineForCall` (**WU-3 owns that function**; this
      unit does not redefine it) and WU-9's `machineForSession` for the
      session-scoped error cases.
- [ ] Resolution happens in `dispatch` **before** `itwRecordAndAck`; the resolved
      name is stamped into the invocation entry (`mkInvocationEntryWithMachine`).
- [ ] `opAuthorize` still runs first — a denied call resolves and records nothing.
- [ ] Resolution failure still records an entry carrying the **requested** name plus
      an error class, so a model naming a forbidden machine leaves a trace (OWASP A09).
- [ ] The record carries the name and **nothing else** — no host/user/path.

**Files (edit)** `src/Seal/ISA/Dispatch.hs`, `test/Seal/ISA/DispatchSpec.hs`
**Depends on** WU-4, WU-9.

**RED**
```
recordNamesResolvedMachine
recordExistsBeforeExecutionFails         -- P10: drive a FAILING machine, assert the
                                         -- ACK entry already exists and names it
omittedMachineRecordsSessionMachine
deniedCallRecordsNothing
resolutionFailureRecordsRequestedName
recordHasNoHostUserOrPath                -- negative
recordedNameEqualsExecutedMachine
```

### WU-13: `SETUP_REPO` on a non-session machine

**DoD**
- [ ] Clone runs on the named machine.
- [ ] When `machine ≠ session machine`: no auto-bind, no re-scan, no invalidation.
- [ ] `smRepoMachine` recorded; result text states follow-up relative paths resolve
      on the **session** machine.

**Files (edit)** `src/Seal/Core/TurnEngine.hs` (~1147-1197), `src/Seal/ISA/Ops/Repo.hs`,
`test/Seal/ISA/Ops/RepoSpec.hs`
**Depends on** WU-5, WU-9.

**RED**
```
setupRepoOnOtherMachineSkipsAutoBind
setupRepoOnOtherMachineRecordsRepoMachine
setupRepoResultTextNamesSessionMachine
setupRepoOnSessionMachineUnchanged
```

### WU-14: `/machine list` and `seal machine pin`

**DoD**
- [ ] `Seal.Command.Machine` with `/machine list` in `coreCommandSpecs` under
      **`GroupGeneral`** (a new `CommandGroup` ctor renumbers `Enum` and breaks
      `HelpSpec` ordering).
- [ ] Output: `selectable:` / `default:` / `unusable:` lines; last two omitted when
      empty/unset. Consumes `renderMachineConfigError` for the reason text (WU-9),
      does not redeclare it.
- [ ] `CommandMachine MachineAction` in `Seal.Types.Command`, dispatch in
      `AppMain.hs:45-54`, **entry in `reorderGlobalArgs`' subcommand list**
      (`AppMain.hs:104`) or `--log-level` hoisting breaks.
- [ ] `seal machine pin <name> [--key-file PATH | --fingerprint SHA256:…]`:
      verifies a probe against supplied material; `--yes` alone never appends an
      unverified key; idempotent; errors if the name is absent; never bypasses the
      loopback refusal.

**Files (create)** `src/Seal/Command/Machine.hs`, `test/Seal/Command/MachineSpec.hs`
**Files (edit)** `src/Seal/Command/Registry.hs`, `src/Seal/Types/Command.hs`,
`src/Seal/AppMain.hs`, `seal-harness.cabal`, `test/Main.hs`
**Depends on** WU-9.

**RED**
```
machineListExactOutput                    -- T-STR-11
machineListOmitsEmptySections
machineListReusesConfigErrorRenderer
registeredUnderGroupGeneral                -- HelpSpec ordering intact
reorderGlobalArgsKnowsMachine
pinVerifiesAgainstFingerprint / MismatchFails
pinKeyFileRequiresMatch
pinWithoutMaterialRequiresConfirmation
pinIdempotent / UnknownNameErrors / RefusesLoopback
```

---

## Phase 7 — Host keys and the hardened build

### WU-15: Host-key pinning, guards, adoption copy

**DoD (P8 — this section had no owner in revision 1)**
- [ ] `scKnownHosts` filled from `execKnownHostsPath` at the single construction
      site (the machine resolver, WU-1).
- [ ] Resolution-based loopback refusal at connect (`getaddrinfo`): refuse if any
      address is loopback/unspecified/local-interface.
- [ ] Self-key comparison at connect against `/etc/ssh/ssh_host_*_key.pub`
      (configurable); unreadable ⇒ skipped.
- [ ] `hkaAdopt :: MachineName -> SshConfig -> IO (Either Text ())`;
      `HostKeyInfo` gains `hkiMachine`; `buildAdoptionPrompt` renders the frozen
      four lines (T-STR-7).
- [ ] `execErrorToMachineError :: MachineName -> ExecError -> MachineError`,
      including an `ExecNotImplementedReason` arm so the
      `Workdir.hs:211-216` host+path leak stops reaching the model.
- [ ] Callers updated: `Workdir.hs:194-215`, `mkSessionExec`, `rtResolve`.

**Files (edit)** `src/Seal/Tools/Exec/{HostKeyAdoption,UntrustedIO,Remote}.hs`,
`src/Seal/Session/Workdir.hs`, `src/Seal/Config/Machines.hs`,
`test/Seal/Tools/Exec/HostKeyAdoptionSpec.hs`
**Depends on** WU-9.

**RED**
```
connectRefusesResolvedLoopback            -- mybox.lan → 127.0.0.1
connectRefusesSelfHostKey
selfKeyCheckSkippedWhenUnreadable
adoptionPromptExactCopy                   -- T-STR-7
hostKeyChangedRendersFrozenText           -- T-STR-3
unknownKeyRefusedWithoutHuman
changedKeyNeverOfferedForAdoption
sshKeyscanPortKeying                      -- T-HK-PORT
hostPathNotRenderedToModel                -- negative: Workdir.hs:211 leak closed
```

### WU-16: The hardened build actually refuses local execution

**DoD (P19 — the security blocker)**
- [ ] **CPP-guard the unguarded local-executor call sites**:
      `Workdir.hs:188` and `UIO/Internal.hs:119` (`mkLocalUIO`).
- [ ] `enforceRemoteOnly`'s input must **not** be the `Maybe`-collapsed derived
      config: with no `[untrusted_execution]` section it is `Nothing`, so the check
      cannot fire. Take `SecurityConfig` (or the resolved flag) directly.
- [ ] CPP-gate `test/Seal/Tools/Exec/LocalSpec.hs` (imports `Seal.Tools.Exec.Local`,
      not exposed under the flag).
- [ ] `Makefile` target + `.github/workflows/` step building and testing with the flag.

**Files (edit)** `src/Seal/Session/Workdir.hs`, `src/Seal/Tools/Exec/UIO/Internal.hs`,
`src/Seal/Command/{Serve,Cli}.hs`, `src/Seal/Tools/Exec/Untrusted.hs`,
`test/Seal/Tools/Exec/LocalSpec.hs`, `Makefile`, `.github/workflows/{ci,gate}.yml`
**Depends on** WU-6.

**RED**
```
cabal build all -f remote-only-untrusted   -- succeeds
cabal test  -f remote-only-untrusted       -- succeeds
hardenedBuildRefusesAbsentSection          -- allow_localhost default is rejected
hardenedBuildCannotConstructLocalExecutor  -- the Workdir.hs:188 path is CPP'd out
```

### WU-17: Docs and template copy

- [ ] `config/templates/security.toml`: replace `mode`/`known_hosts` with
      `allow_localhost`, pointing at `machines.toml`.
- [ ] `CHANGELOG.md`: operator-visible schema change + migration note **and the
      rollback note** (reverting the binary after migration needs `mode` present,
      which WU-8 guarantees).

**Files (edit)** `config/templates/security.toml`, `CHANGELOG.md`
**Depends on** WU-7, WU-8.

---

## Full suite gate

```bash
make check                                   # build + test + lint + frontend-test
nix develop --command cabal build all -f remote-only-untrusted
nix develop --command cabal test        -f remote-only-untrusted
nix develop --command cabal test >test.log 2>&1; tail -40 test.log
```

All green before `gh pr ready`.

## Known risks

| Risk | Mitigation |
|---|---|
| Dispatcher resolution is one unit | No `uio*` signature changes at all (P20), so no 289-site churn and no split |
| `.cabal` + `test/Main.hs` edited by ~10 units | Minimal edits; rebase `main` before `gh pr ready` |
| Two config files can disagree | Resolver takes the flag as a parameter (WU-1); WU-6's decode rule |
| Adding a field to `SessionMeta` breaks positional construction | WU-9 scopes `Store.hs` + `Worker.hs` explicitly |
| Route table is a closed GADT | WU-10 lists all five registration edits |
| Reverting after migration | WU-8 retains `mode` until `machines.toml` is complete |
