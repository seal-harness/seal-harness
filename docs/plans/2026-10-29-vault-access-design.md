# VaultAccess: Type-Level Allow-List Gating for All Vault Paths

**Issue**: #287 (rework)
**Supersedes**: The `SECRET_MANAGE`-only approach in PR #288
**Status**: Design revision 3 (addressing iteration 2 feedback)
**Date**: 2026-10-30

## Summary

Replace the raw `VaultRuntime` in all session-level vault access paths with a
new `VaultAccess` type that bakes the allow-list into the type. All vault
operations (`get`, `put`, `delete`, `list`) go through `VaultAccess`, which
checks the allow-list before touching the underlying `VaultHandle`. The type
system enforces this — session-level modules cannot access the raw
`VaultHandle` at all.

## Use Cases

1. **Untrusted agent execution**: An operator running an LLM agent on a
   risky task WANTS TO grant the agent access to only the specific secrets
   it needs (e.g. a single deploy key), SO THAT the agent cannot
   exfiltrate unrelated secrets via credential injection, web-search key
   resolution, or any path other than `SECRET_MANAGE`, WHEN creating a
   new tab/session in the web frontend.

2. **Principle of least privilege**: An operator WANTS TO run sessions
   with fail-closed secret access by default, SO THAT sessions don't
   have access to secrets they don't need, WHEN creating any new session.

## Problem

PR #288 added an allow-list to `SECRET_MANAGE`'s `toAuthorize` gate. But
there are **5** distinct vault access paths, and only one was gated:

1. **`SECRET_MANAGE`** — gated ✅ (but only at the opcode's `toAuthorize`)
2. **`SETUP_REPO` credential injection** — `CloneDeps.cdVault` →
   `resolveVaultHandle` → `vhGet`. **Bypasses the allow-list entirely.**
3. **`BIN_EXEC git/gh` credential injection** — same `CloneDeps` path.
   **Bypasses the allow-list entirely.**
4. **`WEB_SEARCH` API key resolution** — `wscVault` → `vaultGetByName` →
   `vhGet`. **Bypasses the allow-list entirely.**
5. **Provider API key resolution** — `ProviderRuntime.prVault` →
   `resolveProvider` → `vhGet`. **Not gated by design** — the key is
   harness-internal (used to call the LLM API, never exposed to the model
   via any opcode). This path stays raw `VaultRuntime` and is explicitly
   documented as an intentional non-gate.

Root cause: `VaultRuntime` is passed raw to `CloneDeps.cdVault` and
`WebSearchConfig.wscVault`, giving unrestricted `VaultHandle` access. The
allow-list is a filter at one call site, not a property of the vault
access itself.

### Scope

- **IN SCOPE**:
  - New `VaultAccess` type in a new module `Seal.Vault.Access` (imports
    `VaultRuntime` from `Seal.Vault.Commands` privately — does NOT
    re-export it, enabling true type-level enforcement)
  - `unrestrictedVaultAccess :: VaultRuntime -> IO VaultAccess` — an
    admin-only constructor that reads all current vault keys and creates
    a `VaultAccess` with the full set. Used by admin `CloneDeps`
    construction sites (`mkRepoTestSeam`, `cloneDepsForApiDeps`).
  - `buildSessionRegistry` takes `VaultAccess` instead of `VaultRuntime`
  - `CloneDeps.cdVault` changes from `VaultRuntime` to `VaultAccess`
  - `WebSearchConfig.wscVault` changes from `Maybe VaultRuntime` to
    `Maybe VaultAccess`
  - `secretManageOp` takes `VaultAccess` instead of `VaultRuntime` +
    `Maybe (Set Text)` (allow-list baked into the type)
  - `SessionMeta.smAllowedSecrets` changes from `Maybe (Set Text)` to
    `Set Text` (empty = no access, fail-closed)
  - `vaultGetByName`/`vaultPutByName`/`vaultDeleteByName`/`vaultListNames`
    take `VaultAccess` instead of `VaultRuntime`
  - `resolveVaultHandle` (in Clone.hs) replaced by `vaGet` calls
  - `TurnDeps.tdVault` stays `VaultRuntime` (constructed once at startup);
    `VaultAccess` is constructed per-turn inside `runTurnBody` and
    `callDispatcher` where `meta` is in scope
  - `mkCloneDepsTurn` takes `VaultAccess` as an additional parameter
  - Gateway API `parseAllowedSecrets` returns `Set Text` (not `Maybe`)
  - Frontend sends `allowed_secrets: string[]` always (default: `[]` = no
    access); vault-locked warning text updated; zero-selection warning added
  - `renderCloneError` gains a `VaultAccessDenied` case
  - All existing tests updated (~20 test files for SessionMeta, all
    `secretManageOp`/`newSession`/`buildSessionRegistry` call sites)

- **OUT OF SCOPE**:
  - Admin vault operations (CLI `/vault` commands, gateway `/api/secrets`
    endpoints, vault setup/unlock at startup) — these keep using
    `VaultRuntime` directly
  - Provider API key resolution (`ProviderRuntime.prVault`) — stays raw
    `VaultRuntime` (harness-internal, not LLM-facing)
  - Per-secret granular permissions (read-only, etc.)
  - CLI/TUI secret selection (web frontend only; CLI sessions default to
    `Set.empty` = no access)
  - Wildcard/glob patterns

## Architecture Decision

**Decision**: Create `VaultAccess` — an opaque type wrapping
`VaultRuntime` + `Set Text` allow-list. Only `vaGet`/`vaPut`/`vaDelete`/
`vaList`/`vaAllowedSet` are exported. The underlying `VaultRuntime` and
`VaultHandle` are NOT exported from the module.
`VaultRuntime` remains exported from `Seal.Vault.Commands` for admin
use. The `VaultAccess` constructor and `vaVault` field are NOT exported
from `Seal.Vault.Access`. Session-level modules import only
`Seal.Vault.Access` and cannot obtain the `VaultRuntime` value through
that import.

**Module placement**: `VaultAccess` lives in a new module
`Seal.Vault.Access`. This module imports `VaultRuntime` from
`Seal.Vault.Commands` privately (not re-exported). It imports
`VaultHandle`/`VaultError` from `Seal.Security.Vault`. Session-level
modules import `Seal.Vault.Access (VaultAccess, vaGet, ...)` and
physically cannot obtain `VaultRuntime` through this import. They could
separately `import Seal.Vault.Commands (VaultRuntime(..))`, but this is a
convention violation caught by code review (same as the existing rule
that opcode modules must not import `System.Process`).

**TurnDeps construction timing**: `TurnDeps` is constructed once at
startup (not per-session), but the allow-list is per-session. Therefore:
- `tdVault :: VaultRuntime` stays in `TurnDeps` (the raw runtime,
  available at startup)
- `VaultAccess` is constructed **per-turn** inside `runTurnBody` (where
  `meta` is in scope — the function parameter, available at entry) and
  `callDispatcher` (where `mMeta` is loaded):
  `let va = vaultAccess (tdVault td) (smAllowedSecrets meta)`
  Note: use `meta` (the function parameter), NOT `meta'` — `cloneDeps` is
  constructed at line 687, before `meta'` is derived at line ~743.
  `smAllowedSecrets meta == smAllowedSecrets meta'` because
  `autoBindRepoAgent` only modifies `smAgent`, not `smAllowedSecrets`.
- `buildSessionRegistry` takes `VaultAccess` (not `VaultRuntime`)
- `mkCloneDepsTurn` takes `VaultAccess` as an additional parameter:
  `mkCloneDepsTurn :: TurnDeps -> VaultAccess -> IO CloneDeps`

This means `VaultRuntime` is in `TurnDeps` but only used to construct
`VaultAccess`. The downstream types (`CloneDeps.cdVault`, 
`WebSearchConfig.wscVault`, `secretManageOp`, `buildSessionRegistry`) all
require `VaultAccess` — `VaultRuntime` cannot be passed where
`VaultAccess` is expected.

**Rationale**:
- `Set Text` (not `Maybe (Set Text)`) — empty set = no access (fail-closed
  default). No `Nothing` escape hatch.
- `VaultRuntime` stays for admin operations (vault setup, lock, unlock,
  status, rekey, CLI commands, gateway management endpoints, provider API
  key resolution) — these are human/operator/harness-internal operations,
  not LLM-facing.

## Acceptance Criteria

### Technical
- [ ] `make check` passes (build + test + lint, `-Werror` clean)
- [ ] `VaultAccess`'s constructor and `vaVault` field are NOT exported
      from `Seal.Vault.Access` — a `VaultAccess` value cannot be
      unwrapped back to its `VaultRuntime`
- [ ] `vaGet` with empty allow-list returns `Left VaultAccessDenied` for
      any key (without touching the vault)
- [ ] `vaList` with empty allow-list returns `Right []`
- [ ] A session with `smAllowedSecrets = Set.empty` cannot complete
      `SETUP_REPO` for a private repo (credential injection fails with
      `VaultAccessDenied`)
- [ ] A session with `smAllowedSecrets = Set.empty` cannot resolve a
      web-search API key
- [ ] `SECRET_MANAGE` with empty allow-list refuses all get/put/delete
- [ ] `SECRET_MANAGE list` with allow-list returns only allowed keys
- [ ] `SessionMeta.smAllowedSecrets :: Set Text` serializes/deserializes
- [ ] Old `session.json` without `allowed_secrets` loads as `Set.empty`
- [ ] Child sessions inherit parent's `smAllowedSecrets`
- [ ] `renderCloneError` has a `VaultAccessDenied` case
- [ ] QuickCheck properties for `VaultAccess` operations
- [ ] No secrets, tokens, or vault values in transcripts or logs
- [ ] `hlint` clean

### User-Facing
- [ ] The secrets section shows a clear warning when zero secrets are
      selected: "No secrets selected — the session will have no vault
      access."
- [ ] The vault-locked warning says: "Secret selection unavailable —
      the vault may be locked. The session will have no vault access." (not
      "all secrets" as in PR #288)
- [ ] "Select all" button is present for convenience (operator can
      explicitly opt in to all secrets)
- [ ] The `allowed_secrets` field is always sent (default `[]`)

### Migration
- [ ] Existing sessions with absent/null `allowed_secrets` load as
      `Set.empty` (no access) — documented as a breaking change
- [ ] The gateway logs a warning on startup when loading sessions with
      no `allowed_secrets` field: "Session <id> has no allowed_secrets —
      vault access disabled. Re-create the session or update
      session.json to grant access."
- [ ] CLI sessions default to `Set.empty` (no vault access) with no
      CLI-side secret selection UI. This is a breaking change for CLI
      workflows that rely on credential injection. Workaround: edit
      `session.json` manually to add `"allowed_secrets": ["KEY1", ...]`,
      or create the session via the web frontend which has the
      secret-selection UI.

## Technical Specification

### `VaultAccess` type (`src/Seal/Vault/Access.hs` — new module)

```haskell
-- | A gated view of the vault. The allow-list is baked into the type.
-- All session-level vault access goes through this type. The underlying
-- VaultRuntime and VaultHandle are NOT exported.
data VaultAccess = VaultAccess
  { vaVault  :: VaultRuntime       -- not exported
  , vaAllowed :: !(Set Text)       -- empty = no access (fail-closed)
  }

-- Export list: VaultAccess(..) is NOT exported. Only:
--   VaultAccess (type, not constructors), noVaultAccess, vaultAccess,
--   vaGet, vaPut, vaDelete, vaList, vaAllowedSet

-- | Fail-closed default: no secrets accessible.
noVaultAccess :: VaultRuntime -> VaultAccess
noVaultAccess rt = VaultAccess rt Set.empty

-- | Construct a VaultAccess with the given allow-list.
vaultAccess :: VaultRuntime -> Set Text -> VaultAccess
vaultAccess = VaultAccess

-- | Extract the allow-list (for toAuthorize gate in secretManageOp).
vaAllowedSet :: VaultAccess -> Set Text
vaAllowedSet (VaultAccess _ allowed) = allowed

-- | Gated get: checks allow-list before touching the vault.
-- Returns Either VaultError ByteString (callers adapt to Text).
vaGet :: VaultAccess -> Text -> IO (Either VaultError ByteString)
vaGet (VaultAccess rt allowed) key
  | not (key `Set.member` allowed) = pure (Left (VaultAccessDenied key))
  | otherwise = do
      mh <- readIORef (vrHandleRef rt)
      case mh of
        Nothing -> pure (Left VaultLocked)
        Just h  -> vhGet h key

-- | Gated put: checks allow-list before touching the vault.
vaPut :: VaultAccess -> Text -> ByteString -> IO (Either VaultError ())
vaPut (VaultAccess rt allowed) key val
  | not (key `Set.member` allowed) = pure (Left (VaultAccessDenied key))
  | otherwise = -- delegate to vhPut

-- | Gated delete: checks allow-list before touching the vault.
vaDelete :: VaultAccess -> Text -> IO (Either VaultError ())
vaDelete (VaultAccess rt allowed) key
  | not (key `Set.member` allowed) = pure (Left (VaultAccessDenied key))
  | otherwise = -- delegate to vhDelete

-- | Gated list: returns only keys in the allow-list.
vaList :: VaultAccess -> IO (Either VaultError [Text])
vaList (VaultAccess rt allowed) = do
  if Set.null allowed then pure (Right [])  -- short-circuit (no vault touch)
  else do
  -- fetch all keys from vault, filter to allowed
```

New `VaultError` variant in `Seal.Security.Vault.Age`:
```haskell
data VaultError = ... | VaultAccessDenied Text
```

`unrestrictedVaultAccess :: VaultRuntime -> IO VaultAccess` — reads all
current vault keys via `vhList` and creates a `VaultAccess` with the
full set. Admin-only; used by `mkRepoTestSeam` and
`cloneDepsForApiDeps`. Not exported to session-level modules (convention:
only imported by admin wiring in `Serve.hs`, `API.hs`).

`Show`/`Eq` instances: `VaultAccessDenied k` shows redacted (key name is
non-sensitive, but consistent with `CloneTarget`'s pattern).

### Return type adaptation

`vaGet` returns `Either VaultError ByteString`. Existing callers use
`vaultGetByName :: VaultRuntime -> Text -> IO (Either Text Text)`. The
`vaultGetByName`/`vaultPutByName`/`vaultDeleteByName`/`vaultListNames`
helpers are rewritten to take `VaultAccess` and adapt:
```haskell
vaultGetByName :: VaultAccess -> Text -> IO (Either Text Text)
vaultGetByName va key = do
  r <- vaGet va key
  pure $ case r of
    Left e  -> Left (T.pack (show e))
    Right bs -> Right (TE.decodeUtf8Lenient bs)
```

### SessionMeta changes (`src/Seal/Session/Meta.hs`)

```haskell
-- Before (PR #288): smAllowedSecrets :: !(Maybe (Set Text))
-- After:         smAllowedSecrets :: !(Set Text)
```

`ToJSON`: `"allowed_secrets" .= smAllowedSecrets m` (serializes as array)
`FromJSON`: `o .:? "allowed_secrets" .!= mempty` (absent/null → empty set)

### secretManageOp (`src/Seal/ISA/Ops/Secret.hs`)

```haskell
-- Before: secretManageOp :: VaultRuntime -> Maybe (Set Text) -> ChannelCaps -> Opcode
-- After:  secretManageOp :: VaultAccess -> ChannelCaps -> Opcode
```

The `toAuthorize` gate extracts the allow-list via `vaAllowedSet va` and
checks `isSecretAllowed`. `isSecretAllowed` and `filterSecretList` drop
the `Maybe` wrapper:
```haskell
isSecretAllowed :: Set Text -> Text -> Bool
isSecretAllowed = Set.member
filterSecretList :: Set Text -> [Text] -> [Text]
filterSecretList = filter . Set.member
```

`stubCloneDeps` (Clone.hs:262) needs `cdVault = noVaultAccess (error
"stubCloneDeps: cdVault ...")` — the type changes from `VaultRuntime`
to `VaultAccess`. Use `noVaultAccess` with an error bottom (same pattern
as the other stub fields).

### CloneDeps (`src/Seal/SourceControl/Clone.hs`)

```haskell
-- Before: cdVault :: VaultRuntime
-- After:  cdVault :: VaultAccess
```

`resolveVaultHandle` is removed. `resolveCloneTarget` calls `vaGet (cdVault
deps) vaultKey` instead. The two call sites (lines ~371, ~398) change from
`vhGet vault vaultKey` to `vaGet (cdVault deps) vaultKey`.

`renderCloneError` gains:
```haskell
CloneVaultError (VaultAccessDenied k) ->
  "secret " <> k <> " not available in this session"
```
This case MUST be placed **before** the existing `CloneVaultError v ->
"vault error: " <> ...` catch-all (Clone.hs:133), else it is unreachable.

`vaultErrMsg` (`Vault/Commands.hs:128`) and `vaultErrText`
(`Providers/Registry.hs:186`) also need a `VaultAccessDenied` case —
both have exhaustive pattern matches with no catch-all, so they will break
the build with `-Werror`.

`vaList` with empty allow-list short-circuits to `Right []` without
touching the vault (avoids leaking vault-locked state).

### WebSearchConfig (`src/Seal/Web/Search.hs`)

```haskell
-- Before: wscVault :: Maybe VaultRuntime
-- After:  wscVault :: Maybe VaultAccess
```

`resolveApiKey` calls `vaGet` via `vaultGetByName` (which now takes
`VaultAccess`).

### TurnDeps and per-turn VaultAccess construction

`tdVault :: VaultRuntime` stays in `TurnDeps`. `VaultAccess` is
constructed per-turn:

**`runTurnBody` (~line 740)**:
```haskell
let va = vaultAccess (tdVault td) (smAllowedSecrets meta')
    isaReg = buildSessionRegistry va paths cloneDeps ...
    cloneDeps <- mkCloneDepsTurn td va
```

**`callDispatcher` (~line 1107)**:
```haskell
let va = vaultAccess (tdVault td) (maybe mempty smAllowedSecrets mMeta)
    isaReg = buildSessionRegistry va ...
    cloneDeps <- mkCloneDepsTurn td va
```

**`buildSessionRegistry` signature**: first parameter changes from
`VaultRuntime` to `VaultAccess`.

**`mkCloneDepsTurn` signature**: gains `VaultAccess` parameter:
```haskell
mkCloneDepsTurn :: TurnDeps -> VaultAccess -> IO CloneDeps
```

### `buildChildRegistryAdapter` (~line 1341)

The child uses the parent's `VaultAccess` (which has the parent's
allow-list). `writeChildMeta` copies the parent's `smAllowedSecrets` to
the child's `session.json`, so the child's allow-list matches the
parent's `VaultAccess`. The child constructs its own `VaultAccess` from
`tdVault td` + the child's `smAllowedSecrets` (loaded from the child's
session.json):

```haskell
mChildMeta <- loadSessionMeta (tdPaths td) childSid
let va = vaultAccess (tdVault td) (maybe mempty smAllowedSecrets mChildMeta)
childCloneDeps <- mkCloneDepsTurn td va
-- ...
, secretManageOp va childCaps
-- ...
, wscVault = Just va
```

This replaces the current `mAllowedSecrets = mChildMeta >>= smAllowedSecrets`
(which is ill-typed after the `Maybe (Set Text)` to `Set Text` change).

`fallbackMeta` (~line 1333): `smAllowedSecrets = mempty` (was `Nothing`).
This must be in the same edit set as the `SessionMeta` type change to
avoid a transient build break.

**New module**: `src/Seal/Vault/Access.hs` — add to `seal-harness.cabal`
`exposed-modules`. Import `VaultRuntime` from `Seal.Vault.Commands`
privately. Import `VaultHandle`/`VaultError` from `Seal.Security.Vault`.

### All TurnDeps construction sites

| Site | File:Line | Current | After |
|------|-----------|---------|-------|
| Web | `Send.hs:266` | `tdVault = sdVault deps` | stays `VaultRuntime` |
| CLI 1 (bgRunner) | `Cli.hs:220` | `tdVault = rt` | stays `VaultRuntime` |
| CLI 2 (callDispatcher) | `Cli.hs:278` | `tdVault = rt` | stays `VaultRuntime` |
| CLI 3 (plainHandler) | `Cli.hs:311` | `tdVault = rt` | stays `VaultRuntime` |

All stay `VaultRuntime` — `VaultAccess` is constructed per-turn.

### CloneDeps construction sites

| Site | File:Line | Current | After |
|------|-----------|---------|-------|
| `mkCloneDepsTurn` | `TurnEngine.hs:906` | `cdVault = tdVault td` | `cdVault = va` (parameter) |
| `dwdMkUIOEnv` (inside `buildWorker`) | `TurnEngine.hs:1271` | calls `mkCloneDepsTurn td` | `mkCloneDepsTurn td va` (va constructed from child meta) |
| `sessionSkillBackend` | `TurnEngine.hs:1055` | calls `mkCloneDepsTurn td` | `mkCloneDepsTurn td (noVaultAccess (tdVault td))` (skill scan only, no vault access needed) |
| `cloneDepsForApiDeps` | `API.hs:1138` | `cdVault = adVault deps` | `cdVault = unrestrictedVaultAccess (adVault deps)` (admin path — needs all keys for session exec bootstrap) |
| `mkRepoTestSeam` | `Serve.hs:435` | `cdVault = rt` | `cdVault = unrestrictedVaultAccess rt` (admin path — `/repo test` needs credential access) |

For `cloneDepsForApiDeps` (API.hs): This constructs `CloneDeps` for
`handleSessionAgents` / `cachedSessionExec` — the session-exec bootstrap
(workdir setup). This is an admin/operator path that needs unrestricted
vault access for repo credential resolution. Use
`unrestrictedVaultAccess (adVault deps)` (reads all vault keys at
construction time).

For `mkRepoTestSeam` (Serve.hs): This is production code for the `/repo
test` CLI command. It needs unrestricted vault access for credential
resolution. Use `unrestrictedVaultAccess rt`.

`Channels/Loop.hs:cdVault` is a vestigial `ChannelDeps` field (not
`CloneDeps`) that is never read. It is removed from this table.


### Gateway API (`src/Seal/Gateway/API.hs`)

`parseAllowedSecrets` returns `Either Text (Set Text)`:
- Absent/null → `Right mempty` (no access)
- `[]` → `Right mempty`
- `["a","b"]` → `Right (Set.fromList ["a","b"])`
- Invalid name → `Left err` → 400

`handleTabNew`/`handleSessionNew`/`handleSessionRebindNew` pass `Set
Text` to `newSessionMeta`/`newSession`.

`adVault :: VaultRuntime` stays (for `/api/secrets` admin endpoints and
for constructing `VaultAccess`).

### Frontend

- Default: NO secrets pre-selected (changed from PR #288's all-selected)
- `allowed_secrets: string[]` always sent (default `[]`)
- Vault-locked warning: "Secret selection unavailable — the vault may
  be locked. The session will have no vault access." (not "all secrets")
- Zero-selection warning: "No secrets selected — the session will have
  no vault access."
- "Select all" button present for convenience
- Both `NewTabComposer` and `NewSessionComposer` updated
- `buildBody` always includes `allowed_secrets` (no conditional omit)
- `persistOnSubmit` does NOT persist `allowedSecrets` (forces conscious
  opt-in each time — intentional for fail-closed)
- Harness-kind tabs: no secrets UI (harness sessions get `Set.empty` =
  no vault access — documented as known limitation)
- Stale comments in `useNewTabSpec.ts` (lines ~281-287, ~81) updated

### Session.Store

`newSessionMeta`/`newSession`/`initSession`/`initSessionMeta` take
`Set Text` instead of `Maybe (Set Text)`.

### Worker.hs

`writeChildMeta` (~line 374): `smAllowedSecrets = maybe mempty
smAllowedSecrets mParent` (was `smAllowedSecrets =<< mParent`).

## TDD Implementation Plan

### Cycle 1: VaultAccess type + operations + QuickCheck

```haskell
-- vaGet (VaultAccess rt Set.empty) "ANY" == Left (VaultAccessDenied "ANY")
-- vaGet (vaultAccess rt (Set.fromList ["A"])) "A" == Right "value-A"
-- vaGet (vaultAccess rt (Set.fromList ["A"])) "B" == Left (VaultAccessDenied "B")
-- vaList (VaultAccess rt Set.empty) == Right []
-- vaList (vaultAccess rt (Set.fromList ["A","B"])) == Right ["A","B"] (filtered)
-- vaPut with disallowed key == Left VaultAccessDenied
-- vaDelete with disallowed key == Left VaultAccessDenied
-- vaAllowedSet (vaultAccess rt allowed) == allowed
-- noVaultAccess rt == VaultAccess rt Set.empty

-- QuickCheck:
-- prop_vaGet_allowed: forall allowed key. key `Set.member` allowed ==>
--   vaGet (vaultAccess rt allowed) key /= Left VaultAccessDenied
-- prop_vaGet_disallowed: forall allowed key. not (key `Set.member` allowed) ==>
--   vaGet (vaultAccess rt allowed) key == Left (VaultAccessDenied key)
-- prop_vaList_filters: forall allowed keys.
--   vaList (vaultAccess rt allowed) == Right (filter (Set.member allowed) keys)
```

### Cycle 2: SessionMeta smAllowedSecrets :: Set Text

```haskell
-- toJSON serializes allowed_secrets as array
-- fromJSON: absent → mempty, null → mempty, ["a","b"] → fromList ["a","b"], [] → empty
-- Round-trip preserves
```

### Cycle 3: secretManageOp with VaultAccess

```haskell
-- secretManageOp :: VaultAccess -> ChannelCaps -> Opcode
-- get/put/delete gated by vaAllowedSet
-- list gated by vaAllowedSet
-- Empty allow-list: all ops denied
```

### Cycle 4: CloneDeps.cdVault :: VaultAccess

```haskell
-- resolveCloneTarget calls vaGet instead of vhGet
-- Clone with empty allow-list fails with VaultAccessDenied
-- renderCloneError handles VaultAccessDenied
```

### Cycle 5: WebSearchConfig.wscVault :: Maybe VaultAccess

```haskell
-- resolveApiKey calls vaGet via vaultGetByName
-- Empty allow-list: no API key resolved
```

### Cycle 6: TurnDeps per-turn VaultAccess + all callers

```haskell
-- runTurnBody constructs VaultAccess from tdVault + smAllowedSecrets meta'
-- callDispatcher constructs VaultAccess from tdVault + smAllowedSecrets <$> mMeta
-- buildSessionRegistry takes VaultAccess
-- mkCloneDepsTurn takes VaultAccess
-- CLI TurnDeps sites stay VaultRuntime (VaultAccess constructed per-turn)
```

### Cycle 7: Gateway API + frontend

```haskell
-- parseAllowedSecrets returns Either Text (Set Text)
-- handleTabNew/handleSessionNew/handleSessionRebindNew pass Set Text
-- Frontend: always send allowed_secrets (default [])
-- Vault-locked warning text updated
-- Zero-selection warning added
```

### Cycle 8: Integration + PR update

```haskell
-- make check green
-- Session with empty allow-list cannot SETUP_REPO a private repo
-- Session with empty allow-list cannot resolve web-search key
-- Update PR #288
```

## Security Considerations

### What This Restriction Covers

All 4 LLM-facing vault access paths are gated by `VaultAccess`:
- `SECRET_MANAGE` — gated in `toAuthorize` + `vaGet`
- `SETUP_REPO` credential injection — gated by `vaGet` in
  `resolveCloneTarget`
- `BIN_EXEC git/gh` credential injection — same `CloneDeps` path
- `WEB_SEARCH` API key resolution — gated by `vaGet` in `resolveApiKey`

### Intentional Non-Gate

Provider API key resolution (`ProviderRuntime.prVault` → `resolveProvider`
→ `vhGet`) is NOT gated. The key is harness-internal — used to call the
LLM API, never exposed to the model via any opcode. This path stays raw
`VaultRuntime`.

### Fail-Closed Default

Empty allow-list = no vault access. A session created without selecting
secrets cannot access ANY vault path — not `SECRET_MANAGE`, not credential
injection, not web search keys. This is enforced by the type system:
`VaultAccess` checks `Set.member` before touching the vault.

### Breaking Change for Existing Sessions

Old `session.json` files with absent/null `allowed_secrets` load as
`Set.empty` (no access). This is intentional — the user requested
fail-closed as the default. The gateway logs a warning on startup when
loading such sessions.

### Residual Risk

For **granted** secrets (in the allow-list), PATs still live in
`GIT_CONFIG_PARAMETERS` during git operations. A determined LLM with
`SHELL_EXEC` access could potentially exfiltrate via `env`. Deploy keys
are preferred (key never leaves ssh-agent). `VaultAccess` prevents
*unauthorized* access; it doesn't prevent exfiltration of *granted*
credentials.

### What Is Protected

- `VaultAccess` does not export `VaultRuntime`/`VaultHandle` —
  session-level modules physically cannot bypass the gate.
- `put`/`delete` are also gated — a session cannot write/delete secrets
  outside its allow-list.
- Child sessions inherit the parent's restrictions.
- `SESSION_MANAGE` does not expose `smAllowedSecrets` for modification.
- `session.json` lives outside `wsRoot` — the LLM cannot tamper with
  its own restriction.
- Error messages do not confirm whether a disallowed key exists in the
  vault.
