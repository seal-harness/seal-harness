# Implementation Plan: VaultAccess Type-Level Allow-List Gating

**Issue**: #287 (rework)
**Design**: docs/plans/2026-10-29-vault-access-design.md (approved by 5-agent gate, 3 iterations)
**Status**: Pending plan review gate

## User Request

Make all Vault functionality require a list of allowed secrets and
gate things through that list. Fail-closed default: if nothing is
supplied, disallow access. Use regular Haskell 2010 types (no dependent
types). Enforce via the type system so no code path can bypass the
allow-list.

## Work Units

### WU-1: Create VaultAccess module + type + operations (TDD)

**Scope**: New module `Seal.Vault.Access` with the `VaultAccess` opaque
type, `vaGet`/`vaPut`/`vaDelete`/`vaList`/`vaAllowedSet`, smart
constructors, `unrestrictedVaultAccess`, and `VaultAccessDenied` error
variant.

**Files**:
- NEW: `src/Seal/Vault/Access.hs`
- `src/Seal/Security/Vault/Age.hs` — add `VaultAccessDenied` to `VaultError`
- `seal-harness.cabal` — add `Seal.Vault.Access` to exposed-modules
- NEW: `test/Seal/Vault/AccessSpec.hs`
- `test/Main.hs` — wire new test module
- `seal-harness.cabal` — add test module to other-modules

**Tests**: Unit tests + QuickCheck for vaGet/vaPut/vaDelete/vaList with
empty and non-empty allow-lists. vaList short-circuit. vaAllowedSet.
unrestrictedVaultAccess reads all keys.

**Dependencies**: None.

**Verification**: `make build && make test`

### WU-2: SessionMeta smAllowedSecrets :: Set Text + compile-fix

**Scope**: Change `smAllowedSecrets` from `Maybe (Set Text)` to `Set
Text`. Update FromJSON (`.!? .!= mempty`). Fix ALL construction sites.

**Files**:
- `src/Seal/Session/Meta.hs` — type change + serialization
- `src/Seal/Session/Store.hs` — newSessionMeta/newSession/initSession/initSessionMeta signatures (Set Text)
- `src/Seal/Core/TurnEngine.hs` — fallbackMeta (mempty), buildChildRegistryAdapter (maybe mempty smAllowedSecrets mChildMeta)
- `src/Seal/Agent/Runtime/Delegation/Worker.hs` — writeChildMeta (maybe mempty smAllowedSecrets mParent)
- `src/Seal/ISA/Ops/Secret.hs` — isSecretAllowed/filterSecretList drop Maybe
- ~20 test files — all SessionMeta construction sites
- `test/Seal/Session/MetaSpec.hs` — serialization tests

**Dependencies**: WU-1 (VaultAccess exists for later WUs, but this WU is pure SessionMeta).

**Verification**: `make build && make test`

### WU-3: secretManageOp with VaultAccess

**Scope**: Change `secretManageOp` to take `VaultAccess` instead of
`VaultRuntime` + `Maybe (Set Text)`. Update `vaultGetByName` etc. to
take `VaultAccess`. Update all call sites.

**Files**:
- `src/Seal/ISA/Ops/Secret.hs` — signature change, use vaAllowedSet
- `src/Seal/Core/TurnEngine.hs` — buildSessionRegistry and buildChildRegistryAdapter call sites
- `test/Seal/ISA/Ops/SecretSpec.hs` — update all call sites + tests
- `test/Seal/ISA/IntegrationSpec.hs` — update call site

**Dependencies**: WU-1, WU-2.

**Verification**: `make build && make test`

### WU-4: CloneDeps.cdVault :: VaultAccess

**Scope**: Change `CloneDeps.cdVault` from `VaultRuntime` to
`VaultAccess`. Replace `resolveVaultHandle` with `vaGet` calls. Add
`VaultAccessDenied` case to `renderCloneError`. Update `stubCloneDeps`.

**Files**:
- `src/Seal/SourceControl/Clone.hs` — cdVault type, resolveCloneTarget, renderCloneError, stubCloneDeps
- `src/Seal/Core/TurnEngine.hs` — mkCloneDepsTurn signature + all call sites
- `src/Seal/Command/Serve.hs` — mkRepoTestSeam (unrestrictedVaultAccess)
- `src/Seal/Gateway/API.hs` — cloneDepsForApiDeps (unrestrictedVaultAccess)
- `src/Seal/Tools/Exec/UIO/Internal.hs` — if CloneDeps construction is referenced
- `test/` — all CloneDeps test call sites

**Dependencies**: WU-1, WU-3.

**Verification**: `make build && make test`

### WU-5: WebSearchConfig.wscVault :: Maybe VaultAccess

**Scope**: Change `wscVault` from `Maybe VaultRuntime` to `Maybe
VaultAccess`. Update `resolveApiKey` to use `vaultGetByName` with
`VaultAccess`.

**Files**:
- `src/Seal/Web/Search.hs` — wscVault type, resolveApiKey
- `src/Seal/Core/TurnEngine.hs` — webSearchCfg and childWebSearchCfg construction
- `test/` — any WebSearchConfig test sites

**Dependencies**: WU-1, WU-4.

**Verification**: `make build && make test`

### WU-6: TurnDeps per-turn VaultAccess + all callers

**Scope**: Construct `VaultAccess` per-turn inside `runTurnBody` and
`callDispatcher`. Thread through `buildSessionRegistry` and
`mkCloneDepsTurn`. Update `sessionSkillBackend` call site. Update CLI
and web TurnDeps construction sites.

**Files**:
- `src/Seal/Core/TurnEngine.hs` — runTurnBody (va from meta), callDispatcher (va from mMeta), buildSessionRegistry signature, mkCloneDepsTurn signature, sessionSkillBackend, buildChildRegistryAdapter, buildWorker (dwdMkUIOEnv)
- `src/Seal/Gateway/Send.hs` — tdVault stays VaultRuntime
- `src/Seal/Channel/Cli.hs` — tdVault stays VaultRuntime (3 sites)
- `src/Seal/Vault/Commands.hs` — vaultErrMsg (VaultAccessDenied case)
- `src/Seal/Providers/Registry.hs` — vaultErrText (VaultAccessDenied case, exhaustive pattern match — build will break without this)
- `src/Seal/Command/Repo.hs` — renderRepoTestError (add specific VaultAccessDenied case before catch-all for better UX)
- `test/` — all affected test sites

**Dependencies**: WU-3, WU-4, WU-5.

**Verification**: `make build && make test`

### WU-7: Gateway API + frontend

**Scope**: `parseAllowedSecrets` returns `Either Text (Set Text)`. Update
3 API handlers. Frontend: always send `allowed_secrets` (default `[]`),
update warning texts, zero-selection warning, remove conditional-omit in
buildBody.

**Files**:
- `src/Seal/Gateway/API.hs` — parseAllowedSecrets, handleTabNew, handleSessionNew, handleSessionRebindNew
- `src/Seal/ISA/Ops/Session.hs` — handleNew (passes mempty)
- `src/Seal/Channel/Cli.hs` — /new (passes mempty)
- `src/Seal/Command/New.hs` — two sites (pass mempty)
- `src/Seal/Gateway/Server.hs` — startup warning for sessions with no allowed_secrets
- `frontend/src/hooks/useNewTabSpec.ts` — always send, default empty Set, no persist
- `frontend/src/components/NewTabComposer.tsx` — warning texts, zero-selection
- `frontend/src/components/NewSessionComposer.tsx` — same
- `frontend/src/hooks/useApi.ts` — CreateTabBody (always include)
- `frontend/src/components/__tests__/NewTabComposer.test.tsx` — update tests
- `frontend/src/components/__tests__/NewSessionComposer.test.tsx` — update tests
- `test/Seal/Gateway/ApiSpec.hs` — API tests

**Dependencies**: WU-2, WU-6.

**Verification**: `make build && make test` + frontend tests

### WU-8: Final integration + PR update

**Scope**: Full `make check`, update PR #288.

**Files**: None new.

**Dependencies**: WU-1 through WU-7.

**Verification**: `make check` green. PR #288 updated.

## Execution Order

```
WU-1 → WU-2 → WU-3 → WU-4 → WU-5 → WU-6 → WU-7 → WU-8
```

WU-1 and WU-2 can be done in parallel (no dependencies between them).
WU-3 depends on both. WU-4 and WU-5 depend on WU-3. WU-6 ties everything
together. WU-7 is the API + frontend. WU-8 is the final gate.

## Backward Compatibility

**Breaking change**: `smAllowedSecrets` goes from `Maybe (Set Text)` to
`Set Text`. Old `session.json` files load as `Set.empty` (no access).
CLI sessions default to no vault access. Gateway logs a warning on
startup for sessions with no `allowed_secrets`.
