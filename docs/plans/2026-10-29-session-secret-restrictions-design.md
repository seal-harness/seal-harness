# Per-Session Secret Vault Access Restrictions

**Issue**: #287
**Status**: Design (revision 2 — addressing design review gate feedback)
**Date**: 2026-10-29

## Summary

Implement per-session restrictions on which vault secrets the LLM can
directly access via the `SECRET_MANAGE` opcode during a session. The user
selects an exact set of secrets in the "Start a new tab" form; the session's
`SECRET_MANAGE` opcode is constrained to only those keys. This is the first
piece of a broader per-session access-control system that may later restrict
Skills, Agents, and memory.

## Problem

Currently, `VaultRuntime` is a single global, process-wide handle. Every
session has unrestricted access to all vault secrets via `SECRET_MANAGE`.
There is no mechanism for a user to limit a session's direct secret access —
a session created for a risky task can read any secret in the vault.

### Use Cases

1. **Untrusted agent execution**: A developer running a community agent
   definition WANTS TO restrict that session's vault access to only the
   credentials the task requires, SO THAT a prompt injection or agent bug
   can't exfiltrate unrelated secrets, WHEN starting a new tab for an
   untrusted task.

2. **Sensitive automated workflows**: A team operator WANTS TO grant a
   session only the deployment credentials it needs, SO THAT the blast
   radius of a compromised session is minimized, WHEN creating a session
   for a sensitive automated workflow.

3. **Principle of least privilege**: Any user WANTS TO follow least-
   privilege by default, SO THAT sessions don't have access to secrets
   they don't need, WHEN creating any new session.

### Scope

- **IN SCOPE**:
  - New `smAllowedSecrets :: Maybe (Set Text)` field on `SessionMeta`
    (`Nothing` = all secrets, backward-compat; `Just Set.empty` = no
    secrets)
  - `SECRET_MANAGE` opcode enforcement: `get`/`put`/`delete`/`list` filter
    against the allow-list. The check happens in `toAuthorize` (before any
    I/O, including before the delete human-confirmation prompt).
  - Thread the allow-list from `SessionMeta` through `buildSessionRegistry`
    (parent sessions) and `buildChildRegistryAdapter` (delegation worker —
    inline registry, NOT via `buildSessionRegistry`).
  - Child sessions inherit the parent's `smAllowedSecrets`, persisted in
    `writeChildMeta` and enforced in the child's inline registry.
  - Gateway API: parse `allowed_secrets` from the 3 session-creation
    endpoints (`POST /api/tabs/new`, `POST /api/sessions/new`,
    `POST /api/sessions/:id/new`)
  - Frontend: secret-selection UI in the New Tab form, fetch secrets list
    from `/api/secrets`
  - Secret-name validation: a new `isValidSecretName :: Text -> Bool` pure
    function, reused by both the API and the existing vault-put handler.
  - Tests: QuickCheck properties for pure helpers, hspec unit tests for
    opcode filtering, SessionMeta serialization, API endpoints, frontend
    component tests.

- **OUT OF SCOPE**:
  - Restrictions on Skills, Agents, memory (future work — this issue
    establishes the pattern via `SessionMeta`)
  - Per-secret granular permissions (e.g. read-only secrets)
  - CLI/TUI secret selection (web frontend only for now; CLI/TUI/`SESSION_MANAGE
    {action:"new"}` default to `Nothing` = all secrets)
  - Wildcard/glob patterns in secret names (exact set only)
  - Restricting indirect vault access via credential injection paths
    (`CloneDeps.cdVault` for `SETUP_REPO`/`BIN_EXEC git/gh`) and
    `WEB_SEARCH` (`wscVault`). These bypass `SECRET_MANAGE` and are
    documented as known limitations (see Security Considerations).
  - Harness-kind session UI for secret selection. The opcode enforcement
    applies to all session types (including harness), but only the
    provider-kind New Tab form has a UI to set the allow-list. Harness
    sessions default to `Nothing` (all secrets) since there is no UI to
    restrict them. This asymmetry is a known v1 limitation.

## Architecture Decision

**Decision**: Store the allowed-secrets set in `SessionMeta`
(`smAllowedSecrets :: Maybe (Set Text)`) and pass it as a parameter to
`secretManageOp`, which filters all vault operations. The check lives in
`toAuthorize` (the pure authorization gate) for `get`/`put`/`delete`, and as
a post-filter in `handleList` for `list`.

**Rationale**:
- `SessionMeta` is the natural home — it's the per-session config record,
  persisted to `session.json`, and already carries `smRepoUrl`, `smAgent`,
  etc.
- `Nothing` means "all secrets allowed" — fully backward compatible. Old
  `session.json` files load without change.
- `Just Set.empty` means "no secrets" — a user who deselects all checkboxes
  gets a session with zero vault access (not full access).
- The opcode is constructed per-turn in `buildSessionRegistry` (parent) and
  inline in `buildChildRegistryAdapter` (child), so threading the allow-list
  from the in-scope `SessionMeta` is a minimal change at both sites.
- Putting the check in `toAuthorize` means the disallowed-key rejection
  happens *before* any I/O — before the vault is touched and before the
  delete human-confirmation prompt fires. This is both faster and safer
  (no prompting the user about a secret the session isn't allowed to touch).
- Child sessions inherit the parent's allow-list — persisted in
  `writeChildMeta` (the single source of truth) and enforced in
  `buildChildRegistryAdapter` via the parent's meta captured in the
  `mkDelegateWorker` closure.
- `SESSION_MANAGE {action:"new"}` (LLM-created top-level sessions) defaults
  to `Nothing` (all secrets). These are top-level sessions, not children;
  the LLM creating a new session doesn't inherit restrictions.

**Why NOT alternatives**:
- *Per-session filtered VaultHandle*: Would require wrapping the global
  handle and threading a new type through many call sites. The opcode-level
  filter is simpler and equally secure for the `SECRET_MANAGE` path.
- *Store in a separate file*: Adds a second file to manage/load;
  `session.json` is already the metadata record.

## Technical Specification

### SessionMeta changes (`src/Seal/Session/Meta.hs`)

```haskell
-- New field (strict):
smAllowedSecrets :: !(Maybe (Set Text))
-- Nothing = all secrets allowed (backward compat)
-- Just set = only keys in the set are accessible
-- Just Set.empty = no secrets accessible
```

`ToJSON`: add `"allowed_secrets" .= smAllowedSecrets m`
  - `Nothing` serializes as `null` (backward-compatible: `.:?` reads `null`
    as `Nothing`).
  - `Just set` serializes as a JSON array.

`FromJSON`: `o .:? "allowed_secrets"` (defaults to `Nothing` when absent
or `null`)

**Import**: `Data.Set (Set)` must be added to `Meta.hs` imports.

**All record-literal construction sites** that must add `smAllowedSecrets =
Nothing` (or the appropriate value):

*Production:*
- `src/Seal/Session/Store.hs:92` — `newSessionMeta` (will set the passed
  value)
- `src/Seal/Core/TurnEngine.hs:1323` — `fallbackMeta` in `buildWorker`
  (set to `Nothing`)
- `src/Seal/Agent/Runtime/Delegation/Worker.hs:361` — `writeChildMeta`
  (set to `smAllowedSecrets <$> mParent` to inherit parent's restriction)

*Tests (~20 files):*
- `test/Seal/Session/StoreSpec.hs` — lines 71, 94, 116
- `test/Seal/Session/MetaSpec.hs` — line 20
- `test/Seal/Agent/Runtime/Delegation/WorkerSpec.hs` — line 175
- `test/Seal/RepoDiscoverySpec.hs` — lines 719, 764
- `test/Seal/Command/TabSpec.hs` — lines 37, 386
- `test/Seal/Logging/LoggerSpec.hs` — lines 133, 160, 192, 218
- `test/Seal/Tabs/PartitionSpec.hs` — line 29
- `test/Seal/Core/SystemPromptSpec.hs` — line 43
- `test/Seal/ISA/Ops/SessionSpec.hs` — line 119 (and updates at 704/727/
  760/781/786/1719)
- `test/Seal/Command/NewSpec.hs` — line 64
- `test/Seal/Gateway/SendSpec.hs` — line 90
- `test/Seal/Gateway/ApiSpec.hs` — lines 4523, 4639, 4839, 4975, 5110-11,
  5236-37 (`fakeMeta` + overrides)

### Secret-name validation (`src/Seal/ISA/Ops/Secret.hs` or a new utility)

A new pure function, since no such validator currently exists in the
codebase:

```haskell
isValidSecretName :: Text -> Bool
isValidSecretName t =
  not (T.null t) && T.all (\c -> isAlphaNum c || c == '_' || c == '-') t
```

This matches the pattern in `SecretsView.tsx` (`/^[A-Za-z0-9_\-]+$/`). It
will be reused by the gateway API parsing and can be adopted by the
existing `handleSecretPut` endpoint for consistency (but that adoption is
optional/non-blocking).

### SECRET_MANAGE opcode (`src/Seal/ISA/Ops/Secret.hs`)

`secretManageOp` gains a `Maybe (Set Text)` parameter:

```haskell
secretManageOp :: VaultRuntime -> Maybe (Set Text) -> ChannelCaps -> Opcode
```

**Authorization gate** (`toAuthorize`): For `get`/`put`/`delete` actions,
after the existing field-presence validation, check `isSecretAllowed
allowed key`. If not allowed, return `Left "secret not available in this
session"`. This happens *before* `toRun` and *before* the delete
human-confirmation prompt.

**`list` handler**: After fetching keys from the vault, apply
`filterSecretList allowed keys` before rendering. The `count` in
`orRecorded` is the *filtered* count, not the total.

Pure helper functions (QuickCheck-tested):

```haskell
-- | Filter a list of secret keys to only those in the allow-list.
-- Nothing = no filtering (all keys). Just set = only keys in the set.
filterSecretList :: Maybe (Set Text) -> [Text] -> [Text]

-- | Check whether a secret key is accessible under the allow-list.
-- Nothing = always allowed. Just set = must be a member.
isSecretAllowed :: Maybe (Set Text) -> Text -> Bool
```

Error messages: `"secret not available in this session"` — deliberately does
not confirm or deny whether the key exists in the vault (no existence
oracle for the LLM).

### buildSessionRegistry (`src/Seal/Core/TurnEngine.hs`, ~line 261)

Add `Maybe (Set Text)` parameter (the allowed secrets from the session
meta). Pass to `secretManageOp`. This makes 15 positional parameters —
acceptable given the codebase's existing style, and the natural home for
future restriction fields is a `SessionPolicy` record (deferred to when
Skills/Agents/memory restrictions are added).

The call site at ~line 740 passes `smAllowedSecrets meta'`.

### Delegation worker (`src/Seal/Core/TurnEngine.hs`, ~line 1359)

The child session's registry is built **inline** in `buildChildRegistryAdapter`
(NOT via `buildSessionRegistry`). It calls `secretManageOp (tdVault td)
childCaps` directly. This must change to `secretManageOp (tdVault td)
allowedSecrets childCaps` where `allowedSecrets` is threaded from the
parent's `SessionMeta`.

**Threading path**: `mkDelegateWorker` (in `Delegation/Worker.hs`) has
access to the parent's session id via `dwdParentSid`. It already loads the
parent's meta for `parentSealFrontMatter`. The parent's `smAllowedSecrets`
is captured in the `dwdChildRegistry` closure and passed to
`buildChildRegistryAdapter`.

**Persistence**: `writeChildMeta` (`Delegation/Worker.hs:361`) constructs
the child's `SessionMeta` and must set `smAllowedSecrets = smAllowedSecrets
<$> mParent` so the child's `session.json` records the inherited
restriction. This is the durable record — if the child is later resumed,
the restriction is loaded from its own meta.

### Session.Store (`src/Seal/Session/Store.hs`)

`newSessionMeta` and `newSession` gain a `Maybe (Set Text)` parameter as
the **last** positional argument:

```haskell
newSessionMeta :: SealPaths -> Text -> Text -> Text -> Maybe AgentDefId
               -> Maybe (Set Text) -> IO SessionMeta
newSession :: SealPaths -> Text -> Text -> Text -> Maybe AgentDefId
           -> Maybe (Set Text) -> IO SessionMeta
```

**All callers** that must be updated:

| Caller | File:Line | Value to pass |
|--------|-----------|---------------|
| `handleTabNew` | `Gateway/API.hs:839` | parsed `allowed_secrets` |
| `handleSessionNew` | `Gateway/API.hs:940` | parsed `allowed_secrets` |
| `handleSessionRebindNew` | `Gateway/API.hs:997` | parsed `allowed_secrets` |
| `handleNew` (SESSION_MANAGE) | `ISA/Ops/Session.hs:342` | `Nothing` (top-level session) |
| CLI `/new` | `Channel/Cli.hs:207` | `Nothing` (CLI defaults to all) |
| `Command/New.hs` | lines 186, 201 | `Nothing` (CLI defaults to all) |
| `initSession` | `Store.hs:284` | thread through (wraps `newSession`) |
| `initSessionMeta` | `Store.hs:297` | thread through (wraps `newSessionMeta`) |

`initSession`/`initSessionMeta` callers: `Tui.hs:138`,
`Command/Registry.hs:138`, `Command/Serve.hs:221` — all pass `Nothing`.

### Gateway API (`src/Seal/Gateway/API.hs`)

Three endpoints parse `allowed_secrets` from the request body:

| Method | Path | Body field |
|--------|------|------------|
| POST | `/api/tabs/new` | `allowed_secrets: string[]` |
| POST | `/api/sessions/new` | `allowed_secrets: string[]` |
| POST | `/api/sessions/:id/new` | `allowed_secrets: string[]` |

**Parsing semantics** (security-critical):
- Field **absent** → `Nothing` (all secrets, backward-compat)
- Field **present and `[]`** → `Just Set.empty` (no secrets — user
  deliberately deselected all)
- Field **present and non-empty** → `Just (Set.fromList list)` (only these
  secrets)

**Validation**: Each entry validated with `isValidSecretName`. If any entry
is invalid, return `400` with an error message (consistent with existing
`errJson status400` pattern). Do not silently filter.

**`kind: "resume"` in `handleTabNew`**: The `allowed_secrets` field is
**ignored** for resume — the existing session's `smAllowedSecrets` stands.
Document this in the API response (no error, just silently ignored, since
the session already has its own restriction).

### Frontend

- `useNewTabSpec.ts`: Add `allowedSecrets: Set<string>` state (default: all
  selected), `setAllowedSecrets` handler, and `availableSecrets: string[]`
  (fetched from `GET /api/secrets` via the existing `useSecrets` hook).
  Default state: when secrets are loaded, all are selected (preserves
  current behavior — `buildBody` omits the field when all are selected).
- `NewTabComposer.tsx`: Add a "Secrets" section with checkboxes for each
  available secret. Only shown for `provider` kind. Includes:
  - "Select all" / "Deselect all" toggles
  - A scroll container (`max-height`) for vaults with many secrets
  - Helper text: "The session can only read, write, and delete the
    selected secrets. It cannot create new ones."
  - Hidden entirely when `availableSecrets.length === 0 && loaded &&
    !error` (nothing to restrict)
  - Error state: when secrets fetch fails (vault locked/unconfigured),
    show a warning: "Secret selection unavailable — the vault may be
    locked. The session will have access to all secrets." and omit
    `allowed_secrets` from the request body (sends `Nothing` = all).
- `CreateTabBody` (`useApi.ts`): Add optional `allowed_secrets?: string[]`.
- `buildBody()`: Omit `allowed_secrets` when all secrets are selected
  (field absent = all). Include the array (even `[]`) when not all are
  selected.
- `createBareSession`: Include `allowed_secrets` in the body.

## TDD Implementation Plan

### Cycle 0: Update existing tests (compile-fix)

Add `smAllowedSecrets = Nothing` to all existing `SessionMeta` record
literals across ~20 test files and 3 production sites. Add the new
parameter (`Nothing`) to all existing `newSession`/`newSessionMeta`/
`secretManageOp`/`buildSessionRegistry` call sites. Verify `make build`
compiles with no new behavior.

### Cycle 1: Pure filtering functions + QuickCheck (Secret.hs)

```haskell
-- Equational tests:
-- filterSecretList Nothing keys == keys
-- filterSecretList (Just allowed) keys == filter (`Set.member` allowed) keys
-- isSecretAllowed Nothing _ == True
-- isSecretAllowed (Just allowed) k == Set.member k allowed

-- QuickCheck properties:
-- prop_filterSecretList_preserves_allowed:
--   forall allowed keys. filterSecretList (Just allowed) keys
--     == filter (isSecretAllowed (Just allowed)) keys
-- prop_filterSecretList_idempotent:
--   forall m keys. filterSecretList m (filterSecretList m keys)
--     == filterSecretList m keys
-- prop_isSecretAllowed_nothing_always:
--   forall k. isSecretAllowed Nothing k == True
```

### Cycle 2: Secret-name validator + QuickCheck

```haskell
-- isValidSecretName "foo" == True
-- isValidSecretName "foo-bar_baz" == True
-- isValidSecretName "" == False
-- isValidSecretName "foo bar" == False
-- isValidSecretName "foo/bar" == False
-- isValidSecretName "foo.bar" == False

-- QuickCheck:
-- prop_valid_name_alphanumeric_underscore_dash:
--   forall s. all (\c -> isAlphaNum c || c == '_' || c == '-') s
--     ==> isValidSecretName (T.pack s) == not (null s)
```

### Cycle 3: SessionMeta serialization

```haskell
-- toJSON includes "allowed_secrets" as null when Nothing
-- toJSON includes "allowed_secrets" as array when Just
-- fromJSON parses allowed_secrets correctly
-- fromJSON defaults to Nothing when field absent (backward compat)
-- fromJSON defaults to Nothing when field is null
-- fromJSON parses Just Set.empty from []
-- Round-trip: encode . decode == id
```

### Cycle 4: SECRET_MANAGE opcode with allow-list

```haskell
-- get with allowed key returns the secret
-- get with disallowed key returns error (not the secret) — checked in toAuthorize
-- list with allow-list returns only allowed keys; count is filtered count
-- list with Nothing returns all keys; count is total
-- put with disallowed key returns error — checked in toAuthorize
-- delete with disallowed key returns error — checked in toAuthorize,
--   BEFORE the human-confirmation prompt fires
-- Nothing allow-list: all operations behave as before (backward compat)
```

### Cycle 5: Gateway API endpoints

```haskell
-- POST /api/tabs/new with allowed_secrets ["a","b"] creates session with
--   smAllowedSecrets = Just (fromList ["a","b"])
-- POST /api/tabs/new without allowed_secrets creates smAllowedSecrets = Nothing
-- POST /api/tabs/new with allowed_secrets [] creates smAllowedSecrets = Just Set.empty
-- POST /api/tabs/new with invalid secret name returns 400
-- POST /api/tabs/new with kind:"resume" ignores allowed_secrets
-- POST /api/sessions/new with allowed_secrets
-- POST /api/sessions/:id/new with allowed_secrets
-- SessionMeta persisted to disk contains the allowed_secrets field
```

### Cycle 6: Frontend component tests

```tsx
// NewTabComposer renders secrets section for provider kind
// Secrets section is hidden for harness/attach kind
// Secrets section is hidden when no secrets available
// Toggling a secret updates the selection
// "Select all" / "Deselect all" work correctly
// buildBody includes allowed_secrets when not all selected
// buildBody includes [] when none selected
// buildBody omits allowed_secrets when all selected
// Vault-locked state shows warning and omits allowed_secrets
```

## Implementation Phases

### Phase 1: Backend core (SessionMeta + opcode filtering)
- [ ] Cycle 0: Update all SessionMeta literals and caller signatures
- [ ] Cycle 1: Add pure filtering functions + QuickCheck properties
- [ ] Cycle 2: Add secret-name validator + QuickCheck properties
- [ ] Cycle 3: SessionMeta serialization tests
- [ ] Cycle 4: Modify `secretManageOp` with allow-list + tests
- [ ] Thread allow-list through `buildSessionRegistry`
- [ ] Thread allow-list through delegation worker (`buildChildRegistryAdapter`
      + `writeChildMeta`)

### Phase 2: Gateway API
- [ ] Cycle 5: Parse `allowed_secrets` in `handleTabNew`, `handleSessionNew`,
      `handleSessionRebindNew`
- [ ] Input validation with `isValidSecretName`
- [ ] API tests for all three endpoints

### Phase 3: Frontend
- [ ] Cycle 6: Add secret-list fetching to `useNewTabSpec`
- [ ] Add secrets selection UI to `NewTabComposer`
- [ ] Include `allowed_secrets` in API calls
- [ ] Frontend component tests

## Files to Create/Modify

*Production:*
- `src/Seal/Session/Meta.hs` — add `smAllowedSecrets` field + serialization
- `src/Seal/Session/Store.hs` — update `newSessionMeta`/`newSession`/
  `initSession`/`initSessionMeta` signatures
- `src/Seal/ISA/Ops/Secret.hs` — add allow-list filtering, pure helpers,
  `isValidSecretName`
- `src/Seal/Core/TurnEngine.hs` — thread allow-list through
  `buildSessionRegistry` (line ~261) + `buildChildRegistryAdapter`
  (line ~1359) + `fallbackMeta` (line ~1323)
- `src/Seal/Agent/Runtime/Delegation/Worker.hs` — `writeChildMeta` inherits
  parent's `smAllowedSecrets`; thread through `dwdChildRegistry`/
  `mkDelegateWorker`
- `src/Seal/Gateway/API.hs` — parse `allowed_secrets` in 3 session-creation
  handlers
- `src/Seal/ISA/Ops/Session.hs` — `handleNew` passes `Nothing`
- `src/Seal/Channel/Cli.hs` — `/new` passes `Nothing`
- `src/Seal/Command/New.hs` — two call sites pass `Nothing`
- `src/Seal/Tui.hs` — `initSession` passes `Nothing`
- `src/Seal/Command/Registry.hs` — `initSession` passes `Nothing`
- `src/Seal/Command/Serve.hs` — `initSession` passes `Nothing`

*Frontend:*
- `frontend/src/hooks/useNewTabSpec.ts` — add secret selection state
- `frontend/src/components/NewTabComposer.tsx` — add secrets selection UI
- `frontend/src/hooks/useApi.ts` — add `allowed_secrets` to `CreateTabBody`

*Tests:*
- `test/Seal/ISA/Ops/SecretSpec.hs` — opcode filtering + QuickCheck
- `test/Seal/Session/StoreSpec.hs` — serialization + new-session with allow-list
- `test/Seal/Session/MetaSpec.hs` — serialization round-trip
- `test/Seal/Gateway/ApiSpec.hs` — API endpoint tests
- `test/Seal/Agent/Runtime/Delegation/WorkerSpec.hs` — child inheritance
- ~20 test files — add `smAllowedSecrets = Nothing` to record literals
- `frontend/src/components/__tests__/NewTabComposer.test.tsx` — component tests

*Build/merge hotspots:*
- `seal-harness.cabal` — new test modules if needed
- `test/Main.hs` — wire new test modules

## Acceptance Criteria

### Technical
- [ ] `make check` passes (build + test + lint, `-Werror` clean)
- [ ] `SECRET_MANAGE` with `Just allowed` refuses `get`/`put`/`delete` for
      keys outside the set — rejection happens in `toAuthorize` (before I/O)
- [ ] `SECRET_MANAGE delete` with disallowed key is rejected *before* the
      human-confirmation prompt fires
- [ ] `SECRET_MANAGE list` with `Just allowed` returns only allowed keys;
      `count` in `orRecorded` is the filtered count
- [ ] `SECRET_MANAGE` with `Nothing` behaves exactly as before (backward compat)
- [ ] `SECRET_MANAGE` with `Just Set.empty` allows no `get`/`put`/`delete`;
      `list` returns empty
- [ ] `SessionMeta` with `smAllowedSecrets` serializes/deserializes correctly
- [ ] Old `session.json` without `allowed_secrets` loads as `Nothing` (all)
- [ ] Old `session.json` with `"allowed_secrets": null` loads as `Nothing`
- [ ] POST `/api/tabs/new` with `allowed_secrets: ["a","b"]` creates a
      restricted session
- [ ] POST `/api/tabs/new` with `allowed_secrets: []` creates a session with
      `Just Set.empty` (no secrets)
- [ ] POST `/api/tabs/new` without `allowed_secrets` creates `Nothing` (all)
- [ ] POST `/api/tabs/new` with invalid secret name returns 400
- [ ] POST `/api/tabs/new` with `kind: "resume"` ignores `allowed_secrets`
- [ ] Child sessions inherit the parent's `smAllowedSecrets` (persisted +
      enforced)
- [ ] `SESSION_MANAGE {action:"new"}` creates sessions with `Nothing`
- [ ] QuickCheck properties pass for `filterSecretList`, `isSecretAllowed`,
      `isValidSecretName`
- [ ] No secrets, tokens, or vault values appear in transcripts or logs
- [ ] `hlint` reports no hints
- [ ] PR created with `Closes #287` in the body

### User-Facing
- [ ] A user can select specific secrets and start a restricted session in
      the same number of clicks as an unrestricted session (when leaving
      defaults — all selected)
- [ ] The secrets section is discoverable in the New Tab form (visible label,
      not hidden behind a settings menu)
- [ ] The UI communicates the `put` restriction: "The session can only
      read, write, and delete the selected secrets. It cannot create new
      ones."
- [ ] When the vault is locked/unconfigured, the UI warns the user that
      secret selection is unavailable and the session will have access to
      all secrets
- [ ] "Select all" / "Deselect all" affordances are present for usability
      with large vaults

## Security Considerations

### What This Restriction Covers

The allow-list restricts **direct LLM secret access via the `SECRET_MANAGE`
opcode only**. The LLM cannot `get`, `put`, `delete`, or `list` secrets
outside the allow-list through `SECRET_MANAGE`. The check happens in
`toAuthorize` before any vault I/O.

### Known Limitations (Indirect Vault Access Paths)

The vault is accessed through paths **other than `SECRET_MANAGE`** that are
NOT restricted by this design:

1. **Credential injection for `SETUP_REPO` / `BIN_EXEC git/gh`**: The
   `CloneDeps.cdVault` handle accesses vault secrets directly (via
   `resolveCloneTarget` → `vhGet`) to fetch PAT tokens and deploy-key
   passphrases for registered repos. This bypasses `SECRET_MANAGE`
   entirely. The LLM triggers these paths by calling `SETUP_REPO` or
   `BIN_EXEC git/gh` from inside a registered repo's workdir. Secret
   *values* are not returned to the LLM through this path, but the LLM
   can *use* the secrets' capabilities (clone, push, PR creation).

2. **`git config --get http.extraHeader` PAT exfiltration (pre-existing
   vulnerability)**: For PAT-registered repos, credential injection sets
   `GIT_CONFIG_PARAMETERS` containing `http.extraHeader=Authorization:
   Basic <base64(user:token)>` in the git process environment. The LLM
   can run `BIN_EXEC git config --get http.extraHeader` from inside a
   registered repo's workdir, and git returns the header from
   `GIT_CONFIG_PARAMETERS`. The base64 is trivially decodable to the raw
   PAT. Deploy-key repos are NOT affected (ssh-agent doesn't expose the
   key in git config). This is a pre-existing vulnerability, but the
   `SECRET_MANAGE` restriction does NOT prevent it. Should be tracked as
   a separate issue.

3. **`WEB_SEARCH` vault resolution**: `wscVault = Just rt` means
   `WEB_SEARCH` resolves API keys from the vault via `vaultGetByName`.
   The key name comes from config (`wcSearchAuthKey`), not LLM input, and
   the key value is never returned to the LLM. But the LLM can trigger
   searches that use a vault secret it wasn't explicitly allowed to
   access. Lower risk because the key is not LLM-selectable.

These indirect paths are **out of scope** for this issue. A future design
could wrap `VaultRuntime` with the allow-list for `CloneDeps.cdVault` and
`wscVault` to close these gaps.

### What Is Protected

- The allow-list is stored in `session.json` (metadata, not secret values).
  It contains only key names, which are already non-sensitive (the vault's
  `list` action returns them).
- `put` is restricted — a session cannot write a new secret under a key
  outside its allow-list. This prevents a session from creating a secret
  it then claims to need.
- Child sessions inherit the parent's restrictions — delegation cannot
  escalate access.
- `SESSION_MANAGE` (the session metadata opcode) does NOT expose
  `smAllowedSecrets` for modification — the LLM cannot remove its own
  restriction mid-session. The `sessionManageOp` only handles
  archive/list/search/get actions, not meta-field updates.
- `session.json` lives in the state directory (outside `wsRoot`), so
  `FILE_WRITE`/`SHELL_EXEC`/`SEARCH_FILES` cannot reach it — the LLM
  cannot tamper with its own `smAllowedSecrets`.
- Error messages deliberately do not confirm whether a disallowed key
  exists in the vault (no existence oracle).