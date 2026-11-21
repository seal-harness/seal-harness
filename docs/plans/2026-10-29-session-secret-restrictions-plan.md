# Implementation Plan: Per-Session Secret Vault Access Restrictions

**Issue**: #287
**Design**: docs/plans/2026-10-29-session-secret-restrictions-design.md
**Status**: Pending plan review gate (iteration 2)

## User Request

Implement per-session restrictions on which secrets in the vault are
accessible by the LLM during a session. The user selects an exact set of
secrets via a new form field in the web frontend's "Start a new tab" form.
This restricts `SECRET_MANAGE` opcode access. Eventually this system may
expand to restrict Skills, Agents, and memory, but for now: secrets only.

## Work Units

### WU-1: SessionMeta field + serialization (TDD)

**Scope**: Add `smAllowedSecrets :: !(Maybe (Set Text))` to `SessionMeta`
at the **end** of the record (after `smLastActive`) to minimize disruption
to positional constructors.

**Files**:
- `src/Seal/Session/Meta.hs` — add field at end of record, update ToJSON/FromJSON
- `test/Seal/Session/MetaSpec.hs` — serialization tests

**Tests**:
- `toJSON` includes `"allowed_secrets"` as `null` when `Nothing`
- `toJSON` includes `"allowed_secrets"` as array when `Just`
- `fromJSON` parses `Just (fromList ["a","b"])` from `["a","b"]`
- `fromJSON` defaults to `Nothing` when field absent
- `fromJSON` defaults to `Nothing` when field is `null`
- `fromJSON` parses `Just Set.empty` from `[]`
- Round-trip: `encode . decode == id`

**Dependencies**: None (first work unit).

**Verification**: `make test` — new MetaSpec tests pass; existing tests will
break on compilation until WU-2 updates the record literals.

**Note**: This WU adds the field to the data declaration. It will break
compilation of ALL `SessionMeta` record literals and positional
constructors. WU-2 must follow immediately to fix them. These two WUs are
effectively one atomic compile-fix cycle, split for clarity.

### WU-2: Compile-fix — update all SessionMeta construction sites

**Scope**: Add `smAllowedSecrets = Nothing` to every `SessionMeta` record
literal and `Nothing` to every positional constructor across the codebase.
Since the field is added at the end, positional sites append one `Nothing`
after the second timestamp argument. Line numbers are approximate — the
compiler will identify every site.

**Files (production — 3 sites)**:
- `src/Seal/Session/Store.hs` — `newSessionMeta` (set to `Nothing` for now;
  WU-4 changes the signature to accept the parameter)
- `src/Seal/Core/TurnEngine.hs` — `fallbackMeta` in `buildWorker` (~line 1322)
- `src/Seal/Agent/Runtime/Delegation/Worker.hs` — `writeChildMeta`
  (~line 360; set to `Nothing` for now; WU-5 changes it to inherit)

**Files (tests — ~20 files, ~45+ sites)**:
- `test/Seal/Session/StoreSpec.hs` — ~line 70 (record literal), ~101, ~123
- `test/Seal/Session/MetaSpec.hs` — import only (tests serialization, may
  not construct positionally — verify via compiler)
- `test/Seal/Agent/Runtime/Delegation/WorkerSpec.hs` — ~line 175
- `test/Seal/RepoDiscoverySpec.hs` — ~lines 719, 764
- `test/Seal/Command/TabSpec.hs` — ~lines 37, 386
- `test/Seal/Logging/LoggerSpec.hs` — ~lines 133, 160, 192, 218
- `test/Seal/Tabs/PartitionSpec.hs` — ~line 29
- `test/Seal/Core/SystemPromptSpec.hs` — ~line 43
- `test/Seal/ISA/Ops/SessionSpec.hs` — ~line 119 (and updates at
  ~704/727/760/781/786/1719)
- `test/Seal/Command/NewSpec.hs` — ~line 64
- `test/Seal/Gateway/SendSpec.hs` — ~lines 90, 319, 864, 952, 991, 1630, 1719
- `test/Seal/Gateway/ApiSpec.hs` — `fakeMeta` definition (~line 157,
  positional) + ~28 positional constructors at lines ~974-2192 +
  record-update sites at ~4523, 4639, 4839, 4975, 5110-11, 5236-37
- `test/Seal/Gateway/PatIngestionSpec.hs` — ~line 235
- `test/Seal/Gateway/ServerSpec.hs` — ~line 62
- `test/Seal/Channel/CliSpec.hs` — ~line 63
- `test/Seal/Phase7aSpec.hs` — ~line 65
- `test/Seal/Command/SessionSpec.hs` — ~line 34
- `test/Seal/Command/ModelSpec.hs` — ~lines 44, 271, 272, 289, 303
- `test/Seal/Session/SearchSpec.hs` — uses `newSession` (updated in WU-4,
  not WU-2; uses `saveSessionMeta` with record-update syntax which doesn't
  break)
- `test/Seal/TestHelpers/ApiTestHarness.hs` — ~line 432 (if it constructs
  `SessionMeta` positionally — verify via compiler)

**Tests**: No new tests. Existing tests must still pass.

**Dependencies**: WU-1 (field must exist before updating literals).

**Verification**: `make build` compiles clean. `make test` — all existing
tests pass (behavior unchanged — all sites set `Nothing`).

### WU-3: Pure helpers + secret-name validator + opcode filtering (TDD)

**Scope**: Add `filterSecretList`, `isSecretAllowed`, `isValidSecretName`
pure functions. Modify `secretManageOp` to accept `Maybe (Set Text)` and
enforce the allow-list in `toAuthorize`.

**Files**:
- `src/Seal/ISA/Ops/Secret.hs` — add pure helpers, `isValidSecretName`,
  modify `secretManageOp` signature and authorization/handlers
- `test/Seal/ISA/Ops/SecretSpec.hs` — new tests for helpers, QuickCheck
  properties, opcode filtering behavior

**Tests**:
- `filterSecretList Nothing keys == keys`
- `filterSecretList (Just allowed) keys == filter (isSecretAllowed (Just allowed)) keys`
- `isSecretAllowed Nothing _ == True`
- `isSecretAllowed (Just allowed) k == Set.member k allowed`
- `isValidSecretName "foo" == True`, `"foo-bar_baz" == True`, `"" == False`, `"foo bar" == False`
- QuickCheck: `prop_filterSecretList_preserves_allowed`, `prop_filterSecretList_idempotent`, `prop_isSecretAllowed_nothing_always`, `prop_valid_name_alphanumeric_underscore_dash`
- Opcode: `get` with allowed key returns secret; disallowed key returns error in `toAuthorize`
- Opcode: `list` with allow-list returns only allowed keys; `count` is filtered count
- Opcode: `put` with disallowed key returns error in `toAuthorize`
- Opcode: `delete` with disallowed key returns error in `toAuthorize` (before prompt)
- Opcode: `Nothing` allow-list → all operations behave as before

**Dependencies**: WU-2 (must compile before modifying).

**Verification**: `make test` — all SecretSpec tests pass. `make lint` —
hlint clean.

**Note**: This WU also updates ALL `secretManageOp` call sites to pass
`Nothing` temporarily (the actual threading happens in WU-4/WU-5):

*Production call sites (2):*
- `src/Seal/Core/TurnEngine.hs` — line ~285 in `buildSessionRegistry`
- `src/Seal/Core/TurnEngine.hs` — line ~1359 in `buildChildRegistryAdapter`

*Test call sites (17 total):*
- `test/Seal/ISA/Ops/SecretSpec.hs` — 16 call sites (~lines 82, 96, 114,
  130, 143, 162, 175, 188, 195, 215, 236, 245, 254, 266, 275)
- `test/Seal/ISA/IntegrationSpec.hs` — 1 call site (~line 862)

### WU-4: Thread allow-list through buildSessionRegistry + callers

**Scope**: Thread `smAllowedSecrets` from `SessionMeta` into
`buildSessionRegistry` at both call sites. Update `newSessionMeta`/
`newSession`/`initSession`/`initSessionMeta` signatures.

**Files**:
- `src/Seal/Core/TurnEngine.hs` — add `Maybe (Set Text)` param to
  `buildSessionRegistry`; pass `smAllowedSecrets meta'` at call site ~740;
  pass `smAllowedSecrets <$> mMeta` at call site ~1107 (`callDispatcher`)
- `src/Seal/Session/Store.hs` — add `Maybe (Set Text)` as last param to
  `newSessionMeta`, `newSession`, `initSession`, `initSessionMeta`
- `src/Seal/Gateway/API.hs` — update `handleTabNew`, `handleSessionNew`,
  `handleSessionRebindNew` to parse and pass `allowed_secrets` (parsing
  logic: absent/null → `Nothing`, `[]` → `Just Set.empty`, non-empty →
  `Just (Set.fromList validated)`)
- `src/Seal/ISA/Ops/Session.hs` — `handleNew` passes `Nothing`
- `src/Seal/Channel/Cli.hs` — `/new` passes `Nothing`
- `src/Seal/Command/New.hs` — two call sites pass `Nothing`
- `src/Seal/Tui.hs` — `initSession` passes `Nothing`
- `src/Seal/Command/Registry.hs` — `initSession` passes `Nothing`
- `src/Seal/Command/Serve.hs` — `initSession` passes `Nothing`
- `test/` — update all `newSession`/`newSessionMeta`/`initSession` test
  call sites (~22 sites across the test files listed in WU-2) to add
  `Nothing` parameter
- `test/Seal/Session/SearchSpec.hs` — uses `newSession` (add `Nothing`)
- `test/Seal/Gateway/ApiSpec.hs` — API endpoint tests for `allowed_secrets`
  parsing (absent, `[]`, non-empty, invalid name, resume-ignores)

**Tests**:
- POST `/api/tabs/new` with `allowed_secrets: ["a","b"]` → session meta has `Just (fromList ["a","b"])`
- POST `/api/tabs/new` without `allowed_secrets` → `Nothing`
- POST `/api/tabs/new` with `allowed_secrets: []` → `Just Set.empty`
- POST `/api/tabs/new` with invalid name → 400
- POST `/api/tabs/new` with `kind: "resume"` → ignores `allowed_secrets`
- Same for `/api/sessions/new` and `/api/sessions/:id/new`
- `session.json` persisted to disk contains the `allowed_secrets` field

**Dependencies**: WU-3 (opcode accepts the parameter).

**Verification**: `make test` — all tests pass including new API tests.

### WU-5: Child session inheritance (delegation worker)

**Scope**: Persist parent's `smAllowedSecrets` in child's `session.json`
via `writeChildMeta`. Thread it into `buildChildRegistryAdapter`'s inline
`secretManageOp` call.

**Files**:
- `src/Seal/Agent/Runtime/Delegation/Worker.hs` — `writeChildMeta` sets
  `smAllowedSecrets = maybe Nothing smAllowedSecrets mParent`; thread the
  parent's `smAllowedSecrets` through `mkDelegateWorker` into
  `dwdChildRegistry` (add as a parameter or capture in the closure —
  `parentSid` and `tdPaths` are in scope in `buildWorker` where
  `dwdChildRegistry` is constructed)
- `src/Seal/Core/TurnEngine.hs` — `buildChildRegistryAdapter` (~line 1359)
  passes the allow-list to `secretManageOp`; `buildWorker` (~line 1287)
  loads parent meta (via a new `loadSessionMeta` call or reuse existing
  parent-meta loading) and threads `smAllowedSecrets` into `dwdChildRegistry`
- `test/Seal/Agent/Runtime/Delegation/WorkerSpec.hs` — test that child
  session inherits parent's `smAllowedSecrets`

**Tests**:
- Child session spawned from a restricted parent has `smAllowedSecrets`
  persisted in its `session.json`
- Child session's `SECRET_MANAGE get` for a disallowed key returns error
- Child session's `SECRET_MANAGE get` for an allowed key works

**Dependencies**: WU-4 (parent threading complete).

**Verification**: `make test` — delegation worker tests pass.

### WU-6: Frontend — secret selection UI

**Scope**: Add secret-list fetching, selection state, and UI to the New Tab
form. Include `allowed_secrets` in API calls.

**Files**:
- `frontend/src/hooks/useNewTabSpec.ts` — add `allowedSecrets: Set<string>`,
  `setAllowedSecrets`, `availableSecrets: string[]`, fetch from `/api/secrets`
  (via the existing `useSecrets` hook)
- `frontend/src/components/NewTabComposer.tsx` — add "Secrets" section
  (checkboxes, select all/deselect all, scroll container, helper text,
  hidden-when-empty, vault-locked warning); only shown for `provider` kind
- `frontend/src/hooks/useApi.ts` — add `allowed_secrets?: string[]` to
  `CreateTabBody`; update `createBareSession` to include it
- `frontend/src/components/__tests__/NewTabComposer.test.tsx` — component
  tests

**Tests**:
- Renders secrets section for `provider` kind
- Hidden for `harness`/`attach` kind
- Hidden when no secrets available and loaded and no error
- Toggling a secret updates selection
- "Select all" / "Deselect all" work
- `buildBody` includes `allowed_secrets` when not all selected
- `buildBody` includes `[]` when none selected
- `buildBody` omits `allowed_secrets` when all selected
- Vault-locked state shows warning and omits `allowed_secrets`

**Dependencies**: WU-4 (API endpoints must accept the field).

**Verification**: Frontend tests pass. `make build` — frontend builds and
embeds into the binary.

### WU-7: Final integration + draft PR

**Scope**: Full `make check` pass, create draft PR.

**Files**: None new — verify all existing changes.

**Tests**: `make check` (build + test + lint).

**Dependencies**: WU-1 through WU-6.

**Verification**: `make check` green. Draft PR created with `Closes #287`.

## Execution Order

```
WU-1 → WU-2 → WU-3 → WU-4 → WU-5 → WU-6 → WU-7
```

WU-1 and WU-2 are effectively one compile-fix cycle (the field is added,
then all construction sites are updated). They are split for clarity but
must be committed together or the build is broken between them.

## Backward Compatibility

- `Nothing` (field absent or `null` in `session.json`) = all secrets
  allowed. Old sessions load without change.
- All non-web entry points (CLI, TUI, `SESSION_MANAGE {action:"new"}`)
  default to `Nothing`.
- The API field is optional — old frontend versions that don't send it
  get `Nothing` (all secrets).

## Known Limitations (from security review)

- Indirect vault access via `CloneDeps.cdVault` (credential injection) is
  NOT restricted — documented in Security Considerations.
- `git config --get http.extraHeader` PAT exfiltration is a pre-existing
  vulnerability, out of scope, should be filed as a separate issue.
- `WEB_SEARCH` vault key resolution is NOT restricted — key name is
  config-level, not LLM-selectable.
- Harness-kind sessions have no UI for secret selection (opcode enforcement
  applies but defaults to `Nothing`).