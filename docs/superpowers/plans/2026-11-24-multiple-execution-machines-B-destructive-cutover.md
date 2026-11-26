# Milestone B — the destructive cutover

<!-- superseded-by: docs/superpowers/plans/2026-11-25-multiple-execution-machines-plan.md -->

> **SUPERSEDED (2026-11-25).** This document describes a two-milestone split (A ends at
> "Checkpoint A"; B is gated on A's answer). **That split has been abolished.** The
> authoritative plan is a single PR: `docs/superpowers/plans/2026-11-25-multiple-execution-machines-plan.md`,
> against design `docs/superpowers/specs/2026-11-25-multiple-execution-machines-design-rev10.md`.
> `mode` is deleted (replaced by `allow_localhost`), the localhost denylist is not
> implemented, and the trust model is a passkey-gated write route. Do not execute this
> document.

<!-- branch: exec/multiple-machines -->
<!-- design: docs/superpowers/specs/2026-11-23-multiple-execution-machines-design.md (rev 3c) -->
<!-- handoff: docs/handoffs/2026-11-23-multiple-execution-machines-handoff.md -->
<!-- milestone: B of 2 — depends on A (docs/superpowers/plans/2026-11-24-multiple-execution-machines-A-inventory-and-pin.md) -->
<!-- status: DRAFT, NOT STARTABLE — gated on Checkpoint A's answer -->

## 0. What this milestone is, and its precondition

Milestone **B** deletes `untrusted_execution.mode`, migrates existing configs, re-points
the hardened-build coercion at `allow_local`, removes the four `*IsRemote` flags, adds the
gateway API and the frontend picker, and rewrites the docs.

**It is the milestone that changes existing deployments' behaviour.** Everything in it is
destructive or user-visible-by-default, which is precisely why it is second.

### 0.1 Precondition (hard, not advisory)

**Do not start B until Checkpoint A has been answered.** B's first unit deletes the only
working runtime backstop (`mode` → `localModeResult`, `Security.hs:795-798`). Two
outcomes gate the scope:

| Checkpoint A outcome | B becomes |
|---|---|
| Someone pins a non-default machine | **full B** as written (all seven units) |
| Nobody pins one within two weeks | **B-minus**: drop WU-8 (the picker) entirely; keep only the inventory + pin plumbing that earned its keep, plus the docs that describe reality. The design says so explicitly: *"drop the picker (WU-8), keep the inventory+pin plumbing only if it earned its keep."* |
| A is abandoned | B is not started. Because A was additive, nothing needs undoing. |

This document describes **full B**. The B-minus variant deletes WU-8 and adjusts WU-9's
scope; no other unit changes.

### 0.2 Gate status — inherited, and honest about it

The full 1620-line plan was gated three times with **zero verdicts** (600 s wall clock
twice, provider idle-stream timeout once). Splitting does not create approval. Two things
are worse here than in A and are stated rather than glossed:

- **WU-5, WU-6, WU-7, WU-8, WU-9 have never been independently reviewed at all** — the
  gate chunks covering them never ran. They are self-reviewed only.
- **WU-2b is the single riskiest unit in the whole feature** (23 files, 27 DoD items, and
  it deletes the runtime backstop). Its size is justified in its own §"Size, and why it
  is not split further", but that justification is the planner's, not a reviewer's.

Therefore: **B must pass its own Plan Review Gate before any of its units execute.** That
is a precondition of this milestone, not an optional step. The split exists partly so that
gate can be run at a size reviewers can finish.

## 1. Dependency graph and order

```text
   [Milestone A complete: WU-1a,1b,1c,2,3,4]
                   │
                   ▼
                 WU-2b  ← destructive cutover (deletes mode, migration, coercion, signature)
                   │
                   ▼
                 WU-5   (delete orphaned local constructors)
                   │
                   ▼
                 WU-6   (four flags, clone session id, cache pin, workdir {path,machine})
                   │
                   ▼
                 WU-7   (gateway: /api/machines, PUT /machine, execRefusal, /session machine)
                   │
                   ▼
                 WU-8   (frontend picker, refusal UI, explorer/workdir notice)
                   │
                   ▼
                 WU-9   (docs, templates, CHANGELOG, wiring audit)
                   │
                   ▼
              final comprehensive review → PR     ← CHECKPOINT C
```

**Strictly serial.** Each unit's DoD is stated against the previous unit's public
signatures; the design's round-2 CTO blocker #3 was an ordering that left the tree red
between two units, so no parallelism is available here.

**WU-2c is a ledger**, not an execution step — it produces no code and runs nothing. It
is included so a reviewer can check the design's §Failure modes table row by row.

## 2. Work units

### WU-2b — Destructive: delete `mode`, migrate, re-point the coercion, cut `mkSessionExec`/`cachedSessionExec` over

**Spec:** D0 (the coercion this feature **owes**), D2 (delete `mode`,
`UntrustedExecRemoteFileConfig`, `UntrustedExecMode`, `resolveByMode`,
`resolveRemoteSsh`; `allow_local` re-read per turn), D9's resolution at turn time,
D11 structural requirement (`ResolvedTarget`, not `SecurityConfig`), CTO round-2
blocker 3 (the signature cutover belongs here, not in WU-5).

**Change:**

1. **Delete** `UntrustedExecMode` and the `mode` arm of `untrustedExecConfigCodec`;
   delete `resolveByMode`, `resolveRemoteSsh`, `localModeResult` (`Security.hs:761-803`);
   delete `UntrustedExecRemoteFileConfig` and `uerfc*`.
2. **Delete** `enforceRemoteOnly` and `UntrustedExecBackend`'s mode-based selectors'
   mode argument (`Untrusted.hs:50-58,94-129`) — `enforceRemoteOnly` is dead code
   (definition + 2 tests, no production call site; verified).
3. **Re-point the hardened-build coercion at `allow_local`** (the piece D0 says this
   feature owes):
   ```haskell
   -- Seal.Config.Security
   -- | 'True' when this binary was built with -f remote-only-untrusted.
   remoteOnlyCoercion :: Bool
   #if defined(REMOTE_ONLY_UNTRUSTED)
   remoteOnlyCoercion = True
   #else
   remoteOnlyCoercion = False
   #endif

   effectiveAllowLocal :: Bool -> Bool
   effectiveAllowLocal raw = if remoteOnlyCoercion then False else raw
   ```
   `securityAllowLocal` (WU-2) returns `effectiveAllowLocal . resolvedAllowLocal`.
4. **Delete** `untrustedIOFromSecurity` (`Cli.hs:472-486`, zero callers — its only
   effect was the `#if` arm at `:485`).
4b. **Delete WU-4's transitional pin resolution** — the `Maybe MachineName` argument
    threaded into `cachedSessionExec`/`mkSessionExec` (Milestone A §3.1). It exists only
    because A must keep `mode` working for unpinned sessions; once this unit deletes
    `mode`, the `ResolvedTarget` argument replaces it and the transitional parameter is
    dead. A DoD item (13) asserts its absence by grep, so the shim cannot survive the
    merge. **The earlier `securityConfigForTarget`/`tdResolvedTarget` design was rejected
    as a security regression** (A §3.1: it silently moved untrusted execution from the
    remote box to the harness box on existing installs); no such helper exists to delete.
5. **Signature cutover (D11):**
   `mkSessionExec :: SealPaths -> ResolvedTarget -> SessionId -> CloneDeps -> RemoteRunner -> Maybe HostKeyAdoption -> IO SessionExec`
   and
   `cachedSessionExec :: SessionExecCache -> SealPaths -> ResolvedTarget -> Maybe MachineName -> SessionId -> …`
   (the extra `Maybe MachineName` is D11's `ceSessionPin` second guard). Neither takes
   `SecurityConfig` any more, so **a local arm cannot be constructed without a
   `WhereLocal` in hand** — the structural property, not a deletion.
6. **`execFingerprint`** moves inside the cache and derives from the `ResolvedTarget`
   (`rtName` + `rtWhere`), replacing `execFingerprint :: SecurityConfig -> Text`;
   `CachedExec` gains `ceSessionPin :: Maybe MachineName` and the lookup guard
   requires **both** fingerprint and pin to match (D11: the same `SshConfig` can be
   byte-identical for two names).
7. **`ExecutionConfig` is loaded per call** at every site that resolves a target
   (`TurnEngine.hs:684` region, `:1059`, `:1294`, `:1368`, `API.hs:1652`, and the
   `mkCloneDepsTurn` callers) — never boot-snapshotted, per D11. `TurnDeps` gains no
   cached `ExecutionConfig`.
8. **`TargetError` reaches the turn** (D13): `TurnEngine` renders
   `renderTargetError` and, when `teOperatorAction e`, appends the
   "A human must change this; you cannot." framing **once**, after the message —
   never inline in a message body.
9. **Rewrite every affected spec** (CTO round-2 blocker 3's list, re-verified):
   `Phase4Spec` (`enforceRemoteOnly` cases deleted, `UntrustedExecConfig`
   constructions updated), `UntrustedSpec` (same), `TemplatesSpec` (the pinned
   `"# [untrusted_execution.remote]"` block and its six keys — **corrected only so the
   suite is green**, per C7: the `sampleSecurityConfig` literal and any pinned string
   that names `mode`. Do **not** author the new template or any new assertion here;
   that is WU-9's, and splitting it this way is what stops the two units from both
   rewriting the file and neither owning it), `ApiTestHarness` (`ateMode :: UntrustedExecMode` becomes
   `ateAllowLocal :: Bool`; `uemLabel` deleted; `buildTestEnv` signature updated),
   `SecuritySpec` (5 `SecurityConfig` literals + 3 `UntrustedExecFileConfig`
   literals), `ExecCacheSpec:95,180,184`, `WorkdirSpec:329`,
   `TemplatesSpec:375`, plus `test/Seal/Config/MigrateSpec.hs`.
10. **`src` call sites with no other owner:** `Workdir.hs:182`, `ExecCache.hs:99`,
    `Serve.hs:538,677`, `API.hs:1212,1710`, `TurnEngine.hs:653,669`, `Cli.hs:158,474`.
    Each becomes a `ResolvedTarget`-based site or is deleted.
11. **Migration in `Seal.Config.Migrate`** (D17 rule 2 — *not* in Security, which
    must not import `Execution.Types`): a one-time, idempotent, fail-open step that
    rewrites a legacy `security.toml`'s `[untrusted_execution]` (`mode` +
    `[untrusted_execution.remote]`) into
    `~/.seal/config/execution.toml` (`[machines.default]` + `default = "default"`)
    and leaves `allow_local` behind, **surgically** — removal of the `mode` key and
    the `remote` table, not a re-encode, because a re-encode drops every comment
    (and the template's comments are load-bearing documentation).
12. **`Serve.hs:677`, the file explorer** (unowned elsewhere, CTO round-2 #4):
    becomes the D11a/Non-goals rule — `mkLocalFileExplorer` only when
    `allow_local` is true **or** every machine in the inventory is non-local;
    otherwise `mkFailClosedFileExplorer`. (`serveAttachment` skips
    `checkBlockedPath` at `API.hs:2813`, so this is a confidentiality rule, not a
    cosmetic one.)

**DoD:**

1. Build clean — `nix develop --command cabal build all` exits 0. **The hardened
   build is NOT a DoD item of this unit, and cannot be** (see §0.3): measured on
   this tree before any change,
   - `cabal build lib:seal-harness -f remote-only-untrusted` → **exit 0** (the
     library links; this is the measurement the design recorded),
   - `cabal build all -f remote-only-untrusted` → **exit 1**, an *undefined-symbol*
     link failure in `exe:seal` (`Seal.Tools.Exec.Local.readBoundedBytes`, pulled in
     by `Remote.o`),
   - `cabal build test:tests -f remote-only-untrusted` → **exit 1**, compile error:
     `test/Seal/Tools/Exec/LocalSpec.hs:16: Could not find module
     'Seal.Tools.Exec.Local'`.

   So the flag cannot be exercised by *any* target this feature runs, and a DoD item
   demanding it would be unsatisfiable no matter how good the implementation is.
   What this unit owes instead is the **source-level** guarantee, checked by grep
   (item 4b) — that is the part of D0 the design assigns here.
2. `grep -rn 'UntrustedExecMode\|UemLocal\|UemRemote\|resolveRemoteSsh\|localModeResult\|enforceRemoteOnly\|untrustedIOFromSecurity' src test`
   returns nothing.
3. `grep -rn 'uefcMode' src test` returns nothing; `grep -rn 'untrusted_execution.remote' src`
   returns nothing (the template copy is WU-9's).
4. `effectiveAllowLocal` property: for all `b :: Bool`,
   `effectiveAllowLocal b == (if remoteOnlyCoercion then False else b)`. Runs in the
   normal build. **The flag-on run is not executable** (item 1: the test suite does
   not compile under the flag, for a reason that predates this feature and is
   issue #347's). Substitute proof, both parts mandatory:
   (a) the pure function is exercised in the normal build, and
   (b) a **compile-out proof by inspection with a recorded command** — after
   `cpp -P -DREMOTE_ONLY_UNTRUSTED <the extracted CPP region of Security.hs>`, the
   pasted output in the commit message shows `remoteOnlyCoercion = True`. That is the
   strongest available evidence while #347 is open; a claim that the test was run
   under the flag would be false.
4b. **Source-level D0 guarantee (the enforceable half):** in
   `src/Seal/Config/Security.hs`, `effectiveAllowLocal` is the only function that may
   consult `remoteOnlyCoercion`, and `securityAllowLocal` must be defined in terms of
   it. Asserted by `grep -n 'remoteOnlyCoercion' src/Seal/Config/Security.hs` returning
   exactly two hits (the CPP definition block and the one use). A `securityAllowLocal`
   that read `resolvedAllowLocal` directly would pass every behavioural test in the
   normal build and silently drop the hardened coercion — that is the regression this
   grep exists to catch.
5. **Structural assertion (WU-5's DoD #1 is the other half):**
   `mkSessionExec`'s type contains `ResolvedTarget` and does **not** contain
   `SecurityConfig`; asserted by a `CompileFail` fixture (the tree already has
   `test/Seal/TestHelpers/CompileFail.hs` and four `*FailSpec` modules) that
   attempts `mkSessionExec paths secCfg sid …` and must fail to typecheck.
6. **D11 cache bug, with a test reproducing the reported failure before the fix:**
   a session resolved to `WhereLocal`, then re-resolved to `builder`, produces a
   **fresh** exec (different argv host) in the same process. Red on the pre-fix
   fingerprint, green after. Also: two machine names sharing a byte-identical
   `SshConfig` produce a rebuild (the `ceSessionPin` guard).
7. Turn-level refusal: a session pinned to an unknown machine yields a turn error
   whose text is `renderTargetError (TargetUnknownMachine …)`, and the injected
   human-action suffix appears **exactly once** (assert `T.count` of the suffix == 1).
8. Migration: legacy `security.toml` with `mode = "remote"` + a full
   `[untrusted_execution.remote]` ⇒ `execution.toml` contains
   `[machines.default]` with the six coordinates and `default = "default"`;
   `security.toml` still contains every **comment** it had (assert a specific
   comment line survives); a second run is a no-op; a malformed `security.toml`
   leaves both files untouched and logs.
9. Migration precedence: `execution.toml` already present ⇒ migration does **not**
   overwrite it (adds nothing), and `security.toml`'s stale `mode` is still removed.
10. File explorer fail-closed: `allow_local = false` + an inventory containing a
    non-local machine ⇒ `mkFailClosedFileExplorer`; `allow_local = true` ⇒
    `mkLocalFileExplorer`; `allow_local = false` + inventory of only non-local
    machines ⇒ **explorer enabled** on `default` (the Non-goals rule, including its
    permissive half — a test that only asserts the fail-closed arm would leave the
    rule half-implemented).
11. `make check` green (build + test + lint + frontend-test). Frontend is untouched
    here, so `frontend-test` must be green **unchanged** — any frontend edit in this
    commit is a scope violation.
12. No `TODO`/`FIXME` introduced: `grep -rn 'TODO\|FIXME' <changed files>` empty.
13. **No transitional pin plumbing survives.** The `Maybe MachineName` argument A added to
    `cachedSessionExec`/`mkSessionExec` is gone, and the only pin input is now the
    `ResolvedTarget` (whose `rtName` is D11's `ceSessionPin`). Assert:
    `grep -n 'Maybe MachineName' src/Seal/Session/ExecCache.hs src/Seal/Session/Workdir.hs`
    shows only the `ResolvedTarget`-derived use, and
    `grep -rn 'securityConfigForTarget\|tdResolvedTarget' src test` returns nothing (the
    rejected design must never appear — see A §3.1).
13b. **The §3.1 regression stays dead:** re-run Milestone A's DoD 14 fixture (an install
    with `mode = "remote"` and no pin) and assert it now resolves to the **migrated**
    machine's remote exec, not the local arm. A's test must still exist and pass after
    `mode` is deleted — if that test is deleted here rather than re-pointed, the property
    it guards is lost.

**File scope:** `src/Seal/Config/Security.hs`, `src/Seal/Config/Migrate.hs`,
`src/Seal/Tools/Exec/Untrusted.hs`, `src/Seal/Session/Workdir.hs`,
`src/Seal/Session/ExecCache.hs`, `src/Seal/Channel/Cli.hs`,
`src/Seal/Command/Serve.hs`, `src/Seal/Gateway/API.hs`,
`src/Seal/Core/TurnEngine.hs`, `src/Seal/Gateway/Send.hs` (only if the turn-deps
threading requires it), `test/Seal/Phase4Spec.hs`,
`test/Seal/Tools/Exec/UntrustedSpec.hs`, `test/Seal/Config/TemplatesSpec.hs`,
`test/Seal/TestHelpers/ApiTestHarness.hs`, `test/Seal/Config/SecuritySpec.hs`,
`test/Seal/Session/ExecCacheSpec.hs`, `test/Seal/Config/WorkdirSpec.hs`,
`test/Seal/Config/MigrateSpec.hs`, `test/Seal/CapabilityScopingWorkdirFsFailSpec.hs`,
`test/Seal/Gateway/ApiSpec.hs`, `test/Seal/Tools/Exec/UIOSpec.hs`,
`test/Seal/Tools/Exec/UIOParitySpec.hs`.

**Depends:** WU-2, WU-4.

**Size, and why it is not split further (explicit exception).** This unit touches
~14 `src` files and ~9 test files, well over the ~5-file guideline in
`orchestrated-execution` §2. It is a deliberate, reviewable exception, and the reason
is the design's own round-2 CTO blocker 3: the tree cannot be green between "`mode`
deleted" and "`mkSessionExec` takes a `ResolvedTarget`", because deleting `mode` breaks
`mkSessionExec`'s only input. Splitting this unit re-creates precisely the
incoherent intermediate state the design rejected (`ResolvedTarget` in one place,
`mode` in another). The unit is therefore **one atomic deletion**, and the mitigation
is that its VALIDATE gate is `make check` on the **whole** tree — there is no partial
credit — plus Checkpoint B before the next unit. Its DoD is 13 items rather than 5
because each deleted symbol needs its own absence proof; a shorter DoD is what let
round-1's WU-5 be enumerative and leave the bypass shape alive (D11).

**Checkpoint B:** **yes.** This is the destructive security change. Report must
include the hardened-build result (DoD 1, 4) and the migration comment-preservation
evidence (DoD 8).

---

---

### WU-5 — Delete the now-orphaned local constructors

**Spec:** D11's structural requirement (the second half), D17 ("`Workdir` importing
`Seal.Execution.Types` is a *win*").

**Change:** delete `mkLocalUIO` (`src/Seal/Tools/Exec/UIO/Internal.hs:117`, re-exported
from `src/Seal/Tools/Exec/UIO.hs:19`), delete `mkSessionUntrustedIO`
(`src/Seal/Session/Workdir.hs:308`), delete `mkSessionExec`'s now-unreachable
`Nothing`/local arm (its `Nothing` came from the deleted `untrustedExecConfigFromSecurity`).
`Seal.Session.Workdir` drops its `Seal.Config.Security` import (D17's win) and takes
`ResolvedTarget`.

**DoD:**

1. **Structural assertion** (the half WU-2b's DoD #5 cannot make): a `CompileFail`
   fixture that constructs a local exec handle **without** a `WhereLocal` value in
   scope must fail to typecheck. Concretely: `mkTestUIOEnv (mkLocalUntrustedIO root) deps`
   still compiles (it is the test seam), but every *production* path to a local
   `UIOEnv` requires `WhereLocal` — asserted by the absence of any exported function
   `WorkspaceRoot -> CloneDeps -> UIO a -> IO a`.
2. `grep -rn 'mkLocalUIO\|mkSessionUntrustedIO' src test` returns nothing.
3. `UIOSpec` and `WorkdirSpec` rewritten to go through the surviving seams
   (`mkTestUIOEnv`, `mkSessionExec` with a `ResolvedTarget`); no test is deleted —
   the record of what `mkLocalUIO` guaranteed is expressed against
   `seUIOEnv`/`seWorkspaceRoot` instead. Count before/after in the commit message.
4. `Seal.Session.Workdir` no longer imports `Seal.Config.Security` (grep).
5. Full suite green; `hlint` clean.

**File scope:** `src/Seal/Tools/Exec/UIO/Internal.hs`, `src/Seal/Tools/Exec/UIO.hs`,
`src/Seal/Session/Workdir.hs`, `test/Seal/Tools/Exec/UIOSpec.hs`,
`test/Seal/Tools/Exec/UIOParitySpec.hs`, `test/Seal/Config/WorkdirSpec.hs`,
`test/Seal/ISA/Ops/UIOConstructionFailSpec.hs`.

**Depends:** WU-1a, WU-4, WU-2b.

---

---

### WU-6 — The four `*IsRemote` flags, `mkCloneDepsTurn`'s `SessionId`, the cache pin, `workdir` returns `{path, machine}`

**Spec:** D14 (all four flags, `cdIsRemote` is security-relevant), D11 (`SessionId`
in scope at `TurnEngine.hs:909`), D11a (`workdir` shape + its consumer).

**Change:**

- `TurnDeps.tdIsRemote` (`TurnEngine.hs:404`) — **deleted outright** (D14: compile
  error at every site).
- `CloneDeps.cdIsRemote` (`Clone.hs:247`) — kept, but its value must be the
  **session's own** target, not the global one: `mkCloneDepsTurn :: TurnDeps -> SessionId -> IO CloneDeps`
  (gains `SessionId`, 6 call sites). `Clone.hs:436` gates remote deploy-key `ssh -A`
  vs local clone auth, so a stale `False` silently downgrades a remote session to
  local clone auth — that is D14's security claim and DoD #3 tests it.
- `ChannelDeps.cdIsRemote` (`Loop.hs:94`) — kept as a boot-time **default** for
  sessions with no resolution (documented as such, not silently); removing it
  changes `newChannelDeps`'s positional arity at `Serve.hs:541` + 10 sites for no
  behavioural gain.
- `SendDeps.sdIsRemote` (`Send.hs:203`) — same treatment as `ChannelDeps`: a default,
  overridden per session where a target is available.
- Fix the two hardcoded `cdIsRemote = False`: `cloneDepsForApiDeps`
  (`API.hs:1629`) and `mkRepoTestSeam` (`Serve.hs:818`) resolve the session's target
  instead. `mkRepoTestSeam` keeps a seam for tests but takes the resolved value.
- `GET /api/sessions/:id/workdir` returns `{"path": …, "machine": …}` where
  `machine` is the resolved `rtName` (or the refused state — see WU-7).
- **Frontend stays green:** `useApi.fetchSessionWorkdir` returns the new object and
  `ChatArea`'s `OpenWorkdirLink` (`ChatArea.tsx:377`) reads `.path`. The *notice* is
  WU-8; this unit only keeps the link working. Without this, `make check`'s
  `frontend-test` stage would be red for a whole unit — a scope-boundary reason, not
  a design change.

**DoD:**

1. Build clean.
2. `grep -rn 'tdIsRemote' src test` returns nothing.
3. `mkCloneDepsTurn` takes `SessionId`; a test with a `builder`-pinned session yields
   `cdIsRemote = True`, and an unpinned-local session yields `False` — **two**
   assertions, because a single `False` case would pass on a hardcoded constant.
4. `cloneDepsForApiDeps` for a remote-pinned session yields `cdIsRemote = True`
   (regression test for `API.hs:1629`'s hardcoded `False`).
5. `workdir` JSON has both keys; `machine` equals the session's `exec_machine`
   (resolved), and the path is the **remote** shape for a remote session
   (`/srv/.../workdirs/<sid>`), not the local cache path.
6. Frontend: `fetchSessionWorkdir` + `OpenWorkdirLink` still work;
   `npm test -- --run` green; one new frontend test asserting the object shape is
   read via `.path`.
7. Full suite green; `hlint` clean.

**File scope:** `src/Seal/Core/TurnEngine.hs`, `src/Seal/SourceControl/Clone.hs`,
`src/Seal/Channels/Loop.hs`, `src/Seal/Gateway/Send.hs`, `src/Seal/Command/Serve.hs`,
`src/Seal/Gateway/API.hs`, `src/Seal/Channel/Cli.hs`,
`frontend/src/hooks/useApi.ts`, `frontend/src/components/ChatArea.tsx`,
`test/Seal/Gateway/ApiSpec.hs`, `test/Seal/Gateway/SendSpec.hs`,
`test/Seal/SourceControl/CloneSpec.hs`, `test/Seal/Channel/CliSpec.hs`,
`test/Seal/TestHelpers/ApiTestHarness.hs`, `frontend/src/components/__tests__/`.

**Depends:** WU-4, WU-5.

---

---

### WU-7 — Gateway surface: `GET /api/machines`, `PUT /api/sessions/:id/machine`, `execRefusal`, `/session machine`

**Spec:** D10 (re-pin gated to refused sessions), D11a (all three contracts, with
shapes), CTO round-2 #4 (the route table), PM round-2 blocker 3 (`/session machine`
must exist because D13's message #1 names it), D4a (the boot-warning *state* is
readable, not just logged).

**Change:**

- `GET /api/machines` ⇒ `{ "default": …|null, "machines": [ {name, kind, os, default, selectable, detail} ] }`.
  `selectable` is computed **server-side** per machine via
  `validateTarget <$> getSelfIdentity <*> allowLocal`, so the TypeScript never
  re-implements `allow_local`/self-host logic. `detail` carries
  `renderTargetError`'s text when `selectable = false`.
- `PUT /api/sessions/:id/machine`, body `{"machine": "builder"}` ⇒ `200`
  `{"ok":true,"machine":…}`; `400` with `TargetError` text for unknown/unselectable;
  `404` unknown session; `409` when the session is **not currently refused** (D10 —
  so re-pin cannot become a silent-migration footgun).
- `SessionInfo` gains `execRefusal :: Maybe Text` — the D13 message when resolution
  fails, `null` otherwise. Computing it requires resolution per row; `ListsSnapshot`
  already builds these concurrently (`ListsSnapshot.hs:53-55`), so this adds one
  resolution per session per snapshot, not per request.
- `SealRoute` gains `RouteMachinesList` and `RouteSessionMachine`, with **both**
  exhaustive tables: a `routeMeta` arm (`src-gateway-types/Seal/Gateway/Types/Route.hs:190-191`,
  exported unchanged through `src/Seal/Gateway/Route.hs:14`) and an `openApiMeta` arm
  (`src/Seal/Gateway/OpenApi.hs:75-79`). `-Wincomplete-patterns` is in `-Werror`, so omitting either is a
  hard build break — DoD #5 asserts each arm individually.
- `ApiRouteSpec.expectedRouteCount` 81 → **83**.
- `Seal.Command.Session` gains a third subcommand, `machine`:
  `/session machine` prints the active session's machine (name + whether it is
  refused, with the refusal text) and `/session machine <name>` re-pins it, applying
  the *same* gate as `PUT` (refused-only). `Session.hs:44-46` currently has only
  `list`/`info`.

**DoD:**

1. Build clean.
2. `GET /api/machines` with two machines, `allow_local = false`, returns
   `local.selectable == false`, `local.detail` non-null and containing
   `allow_local`, and the SSH machine `selectable == true`, `detail == null`.
   With `allow_local = true` **and** an SSH machine whose host is this box,
   `selectable == false` with the `TargetSelfHost` detail — the self-host arm is
   otherwise untested through the gateway.
3. `default` is `null` and every `selectable` is computed independently when the
   inventory has ≥2 machines and no `default` (D4a's state is representable on the
   wire).
4. `PUT /machine` four status codes, one test each: `200` (refused session, valid
   machine), `400` (unknown machine; message lists known names), `404` (unknown
   session), `409` (a healthy session).
5. `PUT /machine` on a refused session makes the **next** turn succeed and the
   session's `exec_machine` change on disk; and the exec cache is rebuilt (assert
   the composed argv changes — the D11/D10 interaction).
6. `routeMeta RouteMachinesList` ⇒ `M.get`; `routeMeta RouteSessionMachine` ⇒
   `M.put`; `openApiMeta` has an arm for each (a `CompileFail` fixture deleting the
   `openApiMeta` arm must fail to build — the exhaustive-`\case` proof).
7. `length allRoutes == 83`.
8. `SessionInfo` carries `execRefusal`: `null` for a healthy session, the D13 text
   for one pinned to an unknown machine. Asserted through `GET /api/sessions`.
9. `/session machine` with no argument prints the machine; with an unknown name
   prints the `TargetUnknownMachine` text **and** the human-action framing; with a
   valid name on a **healthy** session refuses (the D10 gate), on a **refused**
   session succeeds. Four assertions.
10. **The design's integration case, which no work unit owned (C8):** two machines,
    two sessions (one pinned to each), each session's untrusted op observes its **own**
    host in the composed ssh argv, and every captured argv contains
    `("-F", "/dev/null")`. Captured through `ApiTestHarness`'s recording fake
    (`mkFakeRemoteRunnerRecording`) — no live host. This is the only place the
    per-session isolation claim is tested end-to-end, so a `GET /api/machines` test
    standing in for it would leave the actual claim untested.
11. `make check` green.
12. `hlint` clean.

**File scope:** `src-gateway-types/Seal/Gateway/Types/Route.hs`,
`src/Seal/Gateway/API.hs`, `src/Seal/Gateway/OpenApi.hs`,
`src/Seal/Gateway/SessionJson.hs`, `src/Seal/Gateway/ListsSnapshot.hs`,
`src/Seal/Command/Session.hs`, `src/Seal/Command/Serve.hs` (for the gateway's
per-call `ExecutionConfig` loader), `test/Seal/Gateway/ApiRouteSpec.hs`,
`test/Seal/Gateway/ApiSpec.hs`, `test/Seal/Gateway/OpenApiSpec.hs`,
`test/Seal/Command/SessionSpec.hs`, `test/Seal/Gateway/SetupApiSpec.hs`,
`test/Seal/Gateway/PatIngestionSpec.hs` (if `SessionInfo` literal updates are needed),
`test/Seal/Phase7aSpec.hs`, `test/Seal/Gateway/ServerSpec.hs`,
`test/Seal/Gateway/MutationGuardSpec.hs`.

**Depends:** WU-6.

---

---

### WU-8 — Frontend: picker with defined empty states, informative display, refusal flag, re-pin, explorer/workdir notice

**Spec:** §Testing/"Picker display rules" (the four inventory states), D11a
(`OpenWorkdirLink` must consume `machine`), Non-goals (explorer notice), D13's sixth
string.

**Change:**

- `frontend/src/types.ts::SessionInfo` gains `execMachine: string | null` and
  `execRefusal: string | null`.
- `NewTabComposer`: a machine picker fed by a new `useMachines()` (`GET /api/machines`),
  with **all four** states rendered exactly as the design's table:
  0 machines ⇒ no picker + a one-line hint pointing at `execution.toml`; exactly 1 ⇒
  **no picker**, a static label naming it; ≥2 with some selectable ⇒ picker,
  `default` preselected; ≥2 with **none** selectable ⇒ disabled picker showing
  `TargetLocalForbidden`'s text and a pointer to `security.toml`.
  `buildBody` sends `exec_machine` when a machine is chosen.
- Chat header + session list: show the machine **only when it carries information**
  (≥2 machines, or the session's machine ≠ the default). A permanent `local` chip on
  a single-machine install is noise and must not exist — DoD #4 asserts absence.
- Refused session: the list row shows `execRefusal`'s text and a re-pin control;
  re-pin calls `PUT /api/sessions/:id/machine`. The control is **absent** on healthy
  rows (the `409` gate made visible rather than discovered).
- Explorer + workdir notice (D11a/D13's sixth string):
  `Showing machine 'default'. This session runs on 'builder' — its files are not
  visible here.` — rendered in the chat header **instead of** the `OpenWorkdirLink`
  when the session's machine ≠ the explorer's, and in the Files view when the focused
  session is on a different machine.

**DoD:**

1. `npm test -- --run` green; `npm run build` clean (typecheck).
2. Four component tests, one per inventory state (0, 1, ≥2-selectable,
   ≥2-none-selectable), each asserting the *rendered* outcome (present/absent picker,
   preselected value, disabled state + specific text). The 1-machine case asserts the
   static label **and** the absence of a `<select>`.
3. `useNewTabSpec`'s `buildBody()` (`useNewTabSpec.ts:303` — it reads hook state and
   takes no arguments) sends `exec_machine: "builder"` when the picker holds
   `builder`, and **omits** the field when no machine is chosen (so the server
   resolves `default`). Asserted through the hook, the way the existing
   `useNewTabSpec.test.ts:63` case asserts the flat body.
4. Header/list display gated: with a single-machine inventory, the machine is **not**
   rendered anywhere (assert `queryByText('local')` is null); with two machines it is.
5. Refused session: row shows the refusal text and a re-pin control; healthy row does
   not. Re-pin issues `PUT` with the right body and refreshes the list on `200`.
6. `OpenWorkdirLink` renders the D11a notice (not a link) when the session's machine
   differs from the explorer's; renders the link when they match. Two tests.
7. `sanitizeHref` is **not** touched (issue #348 is a separate fix; touching it here is
   scope creep and the design says so).
8. `make check` green end-to-end.

**File scope:** `frontend/src/types.ts`, `frontend/src/hooks/useApi.ts`,
`frontend/src/hooks/useNewTabSpec.ts`, `frontend/src/components/NewTabComposer.tsx`,
`frontend/src/components/ChatArea.tsx`, `frontend/src/components/FilesView.tsx`
(notice only), the session-list component, and their `__tests__/`.

**Depends:** WU-7.

---

---

### WU-2c — Failure-mode rows with no other owner (§Failure modes 6-7)

Not a design work unit. A **coverage ledger**, recorded so a reviewer can check the
design's §Failure modes table row by row rather than trusting prose:

| # | Row | Reachable by |
|---|---|---|
| 1 | `execution.toml` unparseable | WU-1b DoD 3 (`TargetConfigUnreadable` producer) |
| 2 | ≥2 machines, no `default` | WU-2 DoD 7 (boot warning `Just`) + WU-1a DoD 10 (row 5 → `TargetNoDefault`) |
| 3 | pinned machine unknown | WU-1a DoD 10 (row 2) + WU-2b DoD 7 (turn text) + WU-7 DoD 8 (`execRefusal`) + WU-7 DoD 4 (`400`) |
| 4 | `allow_local=false` + local pin | WU-1a DoD 11 (row 6) + WU-4 DoD 7 (`400` at creation) |
| 5 | `allow_local=false` + self-host SSH | WU-1a DoD 7/11 (row 7) + WU-7 DoD 2 (through the gateway) |
| 6 | parent's machine unknown | WU-4 DoD 12b |
| 7 | unreachable / host-key mismatch | WU-4 DoD 12c |
| 8 | hardened build + `allow_local = true` | WU-2b DoD 4 + 4b (see §0.4/M1: the *runtime* coercion, not the artifact) |

There is **no work unit** here; the table exists so the reviewer's completeness check
has a single place to fail. If a row is unreachable, it is a plan defect, not a
missing nicety — the design's round-2 lesson was that an unreachable refusal message is
dead code that ships.

---

---

### WU-9 — Docs, both templates, CHANGELOG, and the wiring audit

**Spec:** D2 ("not boot-only"), D6 residual risk ("stated next to the setting"),
D13's message table, PM round-2 blocker 5 (template line 3 says "Boot-only and
agent-immutable", false once `allow_local` is re-read per turn), Non-goals (explorer
notice), D1's template.

**Change:**

- `config/templates/security.toml`:
  - **line 3** `"Boot-only and agent-immutable: …"` → corrected: `allow_local` is
    re-read every turn; the file is still agent-immutable; the *vault* and
    *access_control* sections remain boot-time.
  - the `[untrusted_execution]` block loses `mode` and
    `[untrusted_execution.remote]`; gains `allow_local = true` (written out, since
    writing it resolves like the absent default) with a comment stating exactly what
    it protects.
  - **the residual-risk note next to the setting** (not only in the design doc): a
    DNS or Tailscale/MagicDNS alias resolving to this box is **not** detected;
    `-F /dev/null` closes the `~/.ssh/config` route, nothing closes DNS.
- `config/templates/config.toml`: nothing (the inventory is a sibling file), but its
  cross-reference comment gets the new filename.
- `README.md`: the "execution machines" section — the two-file split (`security.toml`
  = decision, `execution.toml` = inventory), `default`, the reserved `local` name,
  the `--machine` flag, the residual-risk note verbatim, and the hardening
  statement.
- `docs/web-access-control.md`: same residual-risk note where Tailscale is
  recommended.
- `CHANGELOG.md`: a breaking-change entry — `untrusted_execution.mode` removed,
  migrated automatically; `--machine` added; `exec_machine` added to
  `session.json`; `GET /api/machines`, `PUT /api/sessions/:id/machine`,
  `/session machine` added.
- `seal-harness.cabal`: `config/templates/execution.toml` in `extra-source-files`
  (WU-2 added it to `extra-source-files` too; this unit **verifies** rather than
  duplicates — the audit is the deliverable).
- Wiring audit: a documented grep proving every `src/Seal/Execution/*.hs` and
  `src/Seal/Config/Execution.hs` appears in `exposed-modules`, and every new
  `test/Seal/**` module in `other-modules` **and** `test/Main.hs`.

**DoD:**

1. `TemplatesSpec` green, including: the staleness test for **all three** templates;
   `securityTomlTemplate` no longer contains `mode =` or
   `[untrusted_execution.remote]`; it **does** contain `allow_local`; it **does**
   contain the DNS/Tailscale residual-risk sentence (assert a stable substring, so a
   later edit cannot quietly delete it); its decode still yields
   `defaultSecurityConfig`'s behaviour.
2. `security.toml`'s header no longer claims boot-only for `allow_local`; a test
   asserts the file does **not** contain the string `"Boot-only and agent-immutable"`
   (the PM round-2 blocker, made un-regressible).
3. `decodeExecutionConfig executionTomlTemplate` is `Right`, and the template's
   commented `[machines.builder]` block has all seven keys inside it (mirroring the
   existing security-template test's block-scoping assertion).
4. `README.md` contains the residual-risk sentence and the two-file table; asserted by
   a doc test if one exists for README, otherwise recorded as a manual check in the
   commit message with the exact grep output.
5. `cabal sdist` succeeds and the tarball contains all three templates
   (`tar tzf | grep templates`).
6. Wiring audit: `for m in Seal.Execution.Types Seal.Execution.Resolve Seal.Config.Execution; do grep -c "$m" seal-harness.cabal; done` ≥ 1 each, and the same for the new `*Spec` modules vs `test/Main.hs`. Output pasted in the commit message.
7. `make check` green — the final gate.

**File scope:** `config/templates/security.toml`, `config/templates/config.toml`,
`README.md`, `docs/web-access-control.md`, `CHANGELOG.md`, `seal-harness.cabal`,
`src/Seal/Config/Templates.hs`, `test/Seal/Config/TemplatesSpec.hs`.

**Depends:** all.

---

---

## 3. Checkpoint B — after WU-2b (and WU-5), mid-milestone

The full plan's Checkpoint B, unchanged in intent: this is the destructive security
change and it is reported before the rest of B builds on it.

Present: the coercion evidence in the form that exists (`effectiveAllowLocal`'s
normal-build test; the `cpp -P -DREMOTE_ONLY_UNTRUSTED` output showing
`remoteOnlyCoercion = True`; the two-hit grep proving it has exactly one use) — **not** a
`-f remote-only-untrusted` build, which already fails at link on this tree (§4 below);
the migration's comment-preservation evidence; and a summary of every deleted symbol.

## 4. The hardened build: what B owes, and what it cannot prove

Measured on this branch before any change (§0.4 of the full plan):

| Command | Result |
|---|---|
| `cabal build all` | exit 0 |
| `cabal build lib:seal-harness -f remote-only-untrusted` | exit 0 — and `Seal.Tools.Exec.Local` **is** compiled, i.e. #347's defect reproduced |
| `cabal build all -f remote-only-untrusted` | **exit 1** — undefined `Seal.Tools.Exec.Local.readBoundedBytes` from `Remote.o` |
| `cabal build test:tests -f remote-only-untrusted` | **exit 1** — `LocalSpec.hs:16: Could not find module` |

Consequence for B, stated once and obeyed everywhere: **the runtime coercion cannot be
executed by any test** until #347 lands, because the suite does not compile under the
flag. B therefore owes the *source-level* guarantee (WU-2b DoD 4 and 4b) and must not
claim a test it cannot run.

**Operator decision recommended before B starts:** fix #347 first. B deletes the only
working runtime backstop and replaces it with a property that has never run. The design
treats #347 as separable; the measurement says otherwise.

## 5. Security considerations for B

| Boundary | Change | WU |
|---|---|---|
| `security.toml` → coercion | `effectiveAllowLocal` forces `False` under `-DREMOTE_ONLY_UNTRUSTED`; the piece D0 says this feature owes | 2b |
| exec cache | fingerprint moves *inside* the cache over `ResolvedTarget` + a `ceSessionPin` guard (D11 — a live re-pin bug today) | 2b |
| `mkSessionExec`/`cachedSessionExec` | take `ResolvedTarget`, **not** `SecurityConfig`; a local arm becomes unconstructible without `WhereLocal` | 2b |
| file explorer | fail-closed under `allow_local = false` unless every machine is non-local (Non-goals: `serveAttachment` skips `checkBlockedPath`, `API.hs:2813`) | 2b |
| re-pin (`PUT`, `/session machine`) | gated to *refused* sessions (D10) so it cannot become a silent-migration footgun | 7 |
| config migration | surgical key removal, **not** re-encode — a re-encode drops every comment (and the template's comments are load-bearing documentation) | 2b |

**Residual risks**, stated operator-facing in WU-9 (not merely in the design doc): a DNS
or Tailscale-MagicDNS alias resolving to the harness box is not detected without DNS
resolution; and a new machine definition starts at TOFU, so "host-key mismatch is never
bypassed" is true per definition and *resettable* by adding a machine.

## 6. API contracts

### GET /api/machines

- **Request:** none. No query parameters.
- **200:**
  ```json
  { "default": "builder",
    "machines": [
      { "name": "builder", "kind": "ssh", "os": "linux",
        "default": true, "selectable": true, "detail": null },
      { "name": "local", "kind": "local", "os": null,
        "default": false, "selectable": false,
        "detail": "Machine 'local' is this machine, and ~/.seal/security.toml sets allow_local = false, so untrusted code cannot run here. Start the session on an SSH machine (--machine <name>), or have the operator set allow_local." } ] }
  ```
- **Errors:** `200` always when the gateway is up; an unreadable `execution.toml`
  yields `{"default": null, "machines": []}` plus a synthetic pseudo-machine is
  **not** invented — the empty list plus `null` default is the wire form of
  `TargetConfigUnreadable`'s state, and the frontend's 0-machine state names the file.
  (`GET` is read-only and the gateway must stay reachable — D4a.)

### PUT /api/sessions/:id/machine

- **Request body:** `{"machine": "builder"}` — required, non-empty, `MachineName`
  charset.
- **200:** `{"ok": true, "machine": "builder"}`.
- **400:** `{"error": "<renderTargetError text>"}` — unknown machine, invalid name, or
  a machine that `selectable = false`.
- **404:** `{"error": "session not found"}`.
- **409:** `{"error": "<the reason re-pin is not allowed here>"}` — the session is
  **not** currently refused (D10).
- **500:** resolution failed for a reason that is not a `TargetError` (should be
  unreachable; present so the case is not silently coerced).

### GET /api/sessions/:id/workdir

- **200:** `{"path": "/srv/seal/workspace/workdirs/<sid>", "machine": "builder"}`.
- **404:** session has no `session.json`.
- `machine` is the **resolved** name; for a refused session the request still returns
  `200` with the session's pinned name and its `execRefusal` surfaced through
  `SessionInfo` (the workdir link is what the frontend must suppress, so the endpoint
  must not lie about which machine it is).

### SessionInfo (extended)

```json
{ "execMachine": "builder", "execRefusal": null }
```

### POST /api/tabs/new (extended)

Body gains `"exec_machine": "builder"`. Absent ⇒ server resolves `default`. Invalid
or unselectable ⇒ `400` with the `TargetError` text, and **no** `session.json` is
written (the existing arm already persists only after the tab insert succeeds —
`API.hs:1281+` — so the invariant is preserved, not newly asserted).

---

---

### 6.1 UI / UX flows

Four inventory states (`frontend/src/components/NewTabComposer.tsx`):

```
0 machines       ┌────────────────────────────────────────────┐
                 │ No execution machines configured.          │
                 │ Add one to ~/.seal/config/execution.toml.  │
                 └────────────────────────────────────────────┘
1 machine        Execution machine: local          (static label, no <select>)
≥2, some select. Execution machine: [ builder ▾ ]  (default preselected)
≥2, none select. Execution machine: [ builder ▾ ]  (disabled)
                 Machine 'local' is this machine, and
                 ~/.seal/security.toml sets allow_local = false …
```

Chat header / session list: the machine chip is rendered **only** when the inventory
has ≥2 machines or the session's machine ≠ the default. Single-machine installs show
nothing (noise).

Refused session row:

```
┌──────────────────────────────────────────────────────────────┐
│ 20261124-101500-123   ollama/llama3.2   [builder]  ⚠ refused  │
│ Unknown execution machine 'builer'. Known machines: builder,  │
│ local. Two ways to fix: re-point this session …               │
│ [ re-point ▾ ]                                                │
└──────────────────────────────────────────────────────────────┘
```

Chat-header workdir, machine mismatch:

```
Showing machine 'default'. This session runs on 'builder' — its files are not
visible here.
```

Loading/error states: `useMachines()` failure ⇒ the picker is absent and the hint
names `execution.toml` (never a disabled picker with no explanation); `PUT` failure ⇒
the row's existing refusal text stays and the control re-enables with the server's
message shown inline.

Integration: no component is built in isolation — WU-8's DoD #8 is `make check`
end-to-end, and DoD #5 exercises the real `PUT` from the real control.

---

---

## 7. Success criteria (from the design, made measurable)

| Signal | Target | Observed by | Owning WU |
|---|---|---|---|
| Sessions pinned to a non-`default` machine | ≥1 within 2 weeks of WU-4 | `grep exec_machine ~/.seal/sessions/*/session.json` | **A's WU-4** (already measurable at the A boundary) |
| Sessions moved by adding a machine | 0 | the same grep before/after | A's WU-4 |
| Machine visible without a click | header + list when informative | WU-8 DoD 4 | 8 |
| Rename recoverable | refused session re-pinnable, no hand-edited `session.json` | WU-7 DoD 5 + WU-8 DoD 5 | 7/8 |
| Hardened build | runtime coercion at `allow_local`'s single definition, provable today in the normal build | WU-2b DoD 4 + 4b (the *build* half is #347's — see §4) | 2b |

## 8. Out of scope for B

Everything in the full plan's §9. Issues **#347** (hardened-build artifact property) and
**#348** (`sanitizeHref` prefix bypass — **WU-8 must not touch it**) stay separate.

## 9. Execution method

`orchestrated-execution`'s 4-phase loop per unit, `make check` as the VALIDATE gate,
fresh adversarial reviewer per unit, human checkpoints at B and C. Method choice confirmed
with the operator before starting.
