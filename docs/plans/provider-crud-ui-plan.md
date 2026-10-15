# Provider CRUD UI — Implementation Plan (Rev 4)

## Overview

Add a top-level "Providers" menu in the web frontend (between "Sessions" and
"Agents") that lets the user manage model providers from the GUI — add
credentials, set default models, configure base URLs, set the default
provider, and remove providers. API keys are stored transparently in Seal's
secrets vault (never on-disk in cleartext), mirroring the existing
`/provider add|remove|default` CLI commands and the SecretsView/ReposView
vault patterns.

### Out of Scope

- **OAuth login** (`/provider login`) remains CLI-only for this milestone.
  The OAuth flow requires a browser redirect + code-paste interaction that
  doesn't fit the CRUD form pattern. The UI supports API-key-based provider
  configuration only. The `authStatus: "oauth"` value is **read-only
  display** for providers already OAuth-configured via CLI — the UI shows
  the status but provides no OAuth login button.

### Key Design Decisions

1. **Separate endpoints**: The existing `GET /api/providers` endpoint
   returns **configured providers only** — it is consumed by
   `useConfiguredProviders()` which feeds the NewTabComposer and AgentsView
   dropdowns. **This endpoint's semantics are NOT changed.** A new
   `GET /api/providers/all` endpoint returns ALL known providers with full
   status details for the ProvidersView CRUD page.

2. **No new `ApiDeps` field**: The config path is already available via
   `srConfigPath (adSessionRuntime deps)` — proven by the existing
   `handleAgentSetDefault` handler at `API.hs:1151` which calls
   `updateRuntimeConfig (srConfigPath (adSessionRuntime deps)) ...`. No
   new field is needed; the new handlers use the same access path. This
   avoids updating ~25 `ApiDeps` literals in `ApiSpec.hs`.

3. **Reimplement config logic inline**: The CLI's `seedProviderDefaults`
   and `clearDefault` functions are not exported from
   `Seal.Command.Provider` (which has heavy CLI dependencies inappropriate
   for the gateway layer). The new handlers reimplement the equivalent
   logic using the already-exported `upsertProvider`, `rcDefaultProvider`,
   `rcDefaultModel`, and `providerDefaultModel` functions from
   `Seal.Config.File`, plus the `ModelId` newtype from `Seal.Core.Types`.
   This is a few lines of straightforward record updates — no new
   abstractions needed.

4. **Five-value `authStatus`**: The status vocabulary is `"api-key"` |
   `"oauth"` | `"keyless"` | `"none"` | `"vault-locked"`. The `"keyless"`
   value covers local Ollama with a keyless base URL — which
   `configuredProviders` (`Registry.hs:177-181`) correctly treats as
   configured. Without this value, a working local Ollama would display as
   `"none"` (unconfigured), contradicting the existing semantics.

5. **Declarative route spec**: Every new endpoint must be registered in the
   `SealRoute` GADT (`src-gateway-types/Seal/Gateway/Types/Route.hs`), the
   `openApiMeta` table (`src/Seal/Gateway/OpenApi.hs`), and the
   `allRoutes` list — matching the pattern every other CRUD resource
   (agents, skills, repos, secrets) follows. The route-count assertion in
   `test/Seal/Gateway/ApiRouteSpec.hs` must be updated accordingly.

## Architecture Summary

**Backend**: New REST endpoints in `Seal.Gateway.API`. The `KnownProvider`
type stays a fixed sum (anthropic | ollama). Handlers access config via
`srConfigPath (adSessionRuntime deps)` (the existing pattern) and the vault
via `adVault`. Config-writing logic (seed defaults, clear default) is
reimplemented inline using exported `Seal.Config.File` functions. The
`anthropicOAuthKey` constant is exported from `Seal.Providers.Registry` so
the DELETE handler can remove OAuth tokens too. New `SealRoute` constructors
and `openApiMeta` arms are added for all 6 new endpoints.

**Frontend**: A new `ProvidersView.tsx` following the established CRUD
pattern. New types in `types.ts`, new hooks in `useApi.ts` (a
`useAllProviders()` hook separate from the existing
`useConfiguredProviders()`), new section in `TopBar.tsx`, wired in
`App.tsx`.

## Work Units

### WU-1: Backend — Export `anthropicOAuthKey` + new `GET /api/providers/all` endpoint + SealRoute

**File scope:**
- `src/Seal/Providers/Registry.hs` — export `anthropicOAuthKey`
- `src/Seal/Gateway/API.hs` — new `GET /api/providers/all` handler + `providerDetailJson`, extend imports
- `src-gateway-types/Seal/Gateway/Types/Route.hs` — add `RouteProvidersAll` constructor + `routeMeta` arm + `Constructed` entry
- `src/Seal/Gateway/OpenApi.hs` — add `openApiMeta` arm for `RouteProvidersAll`
- `test/Seal/Gateway/ApiSpec.hs` — add test for new endpoint

**DoD:**
1. `anthropicOAuthKey` is exported from `Seal.Providers.Registry`
2. `GET /api/providers` is **unchanged** — still returns only configured providers with just `{"name": ...}` (backward compatible)
3. `GET /api/providers/all` — NEW endpoint returns ALL `knownProviders`, each as:
   `{name, isDefault (bool), defaultModel (string|null), baseUrl (string|null), authStatus}`
   where `authStatus` is `"api-key"` | `"oauth"` | `"keyless"` | `"none"` | `"vault-locked"`
4. `providerDetailJson` reads config via `loadRuntimeConfig (srConfigPath (adSessionRuntime deps))` + vault via `adVault` (the `readIORef (vrHandleRef ...)` pattern from `handleSecretList`). The `authStatus` logic:
   - If vault handle is `Nothing`: `"none"` for all providers
   - If vault handle is `Just vh`:
     - For Ollama: check `providerBaseUrl cfg "ollama"`. If the URL needs no key (`not (ollamaNeedsKey baseUrl)`): `"keyless"`. Else probe `vhGet vh (vaultKeyName OllamaProvider)`: `Right _` → `"api-key"`, `Left VaultLocked` → `"vault-locked"`, `Left VaultKeyNotFound` → `"none"`.
     - For Anthropic: probe `vhGet vh anthropicOAuthKey` first: `Right _` → `"oauth"`. Else probe `vhGet vh (vaultKeyName AnthropicProvider)`: `Right _` → `"api-key"`, `Left VaultLocked` → `"vault-locked"`, `Left VaultKeyNotFound` → `"none"`.
5. Unconfigured providers (no key, no keyless URL) appear with `authStatus: "none"`
6. `isDefault` is `True` when `rcDefaultProvider cfg == Just (providerLabel kp)`
7. `defaultModel` comes from `providerDefaultModel cfg (providerLabel kp)`
8. `baseUrl` comes from `providerBaseUrl cfg (providerLabel kp)`
9. API.hs imports extended: `knownProviders`, `vaultKeyName`, `anthropicOAuthKey`, `defaultModelFor` added to the `Seal.Providers.Registry` import; `loadRuntimeConfig`, `providerBaseUrl`, `providerDefaultModel`, `upsertProvider` added to the `Seal.Config.File` import; `vhGet` added to the `Seal.Security.Vault` import (`VaultHandle (..)` already imported); `VaultLocked` added to the `Seal.Security.Vault.Age (VaultError (..))` import; `ollamaNeedsKey` imported from `Seal.Providers.Ollama`
10. `RouteProvidersAll` constructor added to the `SealRoute` GADT with `routeMeta` arm `match "providers" ./ match "all" ./ end` (GET, bodyless, `Resp`), `Constructed RouteProvidersAll` added to `allRoutes`, and corresponding `openApiMeta` arm added
11. New test: `GET /api/providers/all` returns 200 with all known providers + correct `authStatus` fields
12. `make check` passes

### WU-2: Backend — Provider CRUD endpoints (POST, PUT, DELETE) + SealRoute

**File scope:**
- `src/Seal/Gateway/API.hs` — new route patterns + handler functions
- `src-gateway-types/Seal/Gateway/Types/Route.hs` — add `RouteProviderCreate`, `RouteProviderUpdate`, `RouteProviderDelete` constructors + `routeMeta` arms + `Constructed` entries
- `src/Seal/Gateway/OpenApi.hs` — add `openApiMeta` arms for the 3 new routes
- `test/Seal/Gateway/ApiSpec.hs` — new test cases (using temp config files, mirroring the agent-default PUT test pattern at `ApiSpec.hs:1827`)

**Endpoints:**
- `POST /api/providers` — body: `{name, api_key?, base_url?, default_model?}`.
  - Validates `name` against `parseProvider` → 400 on unknown.
  - If `api_key` is present and non-empty: `vhPut vh (vaultKeyName kp) (encodeUtf8 api_key)`.
  - Updates config via `updateRuntimeConfig (srConfigPath (adSessionRuntime deps))`:
    - Seeds `default_provider` if unset: `rcDefaultProvider = rcDefaultProvider cfg <|> Just (providerLabel kp)`
    - Seeds per-provider `default_model` if unset: `upsertProvider (providerLabel kp) (\p -> if isJust (pcDefaultModel p) then p else p { pcDefaultModel = Just (let ModelId t = defaultModelFor kp in t) })` — uses inline `ModelId` unwrap (`ModelId` is exported from `Seal.Core.Types`), NOT `modelText` (which is a non-exported local)
    - If `base_url` is present: `upsertProvider (providerLabel kp) (\p -> p { pcBaseUrl = base_url })`
    - If `default_model` is present in the request body: `upsertProvider (providerLabel kp) (\p -> p { pcDefaultModel = default_model })`
  - **Upsert semantics**: if the provider is already configured, the key is rotated and config is updated (no 409).
  - **Keyless POST without vault**: a POST with no `api_key` (e.g. keyless Ollama with just `base_url`) never calls `vhPut` and succeeds even when the vault is not configured — it only writes config. The 500-on-vault-not-configured applies only when `api_key` is present and non-empty.
  - **Partial failure**: `vhPut` is called before `updateRuntimeConfig`. If `updateRuntimeConfig` fails after a successful `vhPut`, the vault holds an orphaned key. This matches the CLI `addCmd` behavior (which also does vault-then-config with no rollback) and is acceptable for a single-user GUI. The error is surfaced to the user.
  - 201 on success, 400 on unknown provider name, 500 on vault error/locked.
- `PUT /api/providers/:name` — body: `{api_key?, base_url?, default_model?}`.
  - Validates `name` against `parseProvider` → 400 on unknown.
  - If `api_key` is present and non-empty: rotates the vault key (`vhPut`).
  - If `base_url` is present: `upsertProvider` to set `pcBaseUrl`.
  - If `default_model` is present: `upsertProvider` to set `pcDefaultModel`.
  - 200 on success. Does NOT change `default_provider`.
- `DELETE /api/providers/:name` — removes ALL vault credentials:
  - `vhDelete vh (vaultKeyName kp)` (e.g. `ANTHROPIC_API_KEY`)
  - `vhDelete vh anthropicOAuthKey` (e.g. `ANTHROPIC_OAUTH_TOKENS`) — mirroring CLI `removeCmd`. This is called for ALL providers including Ollama; it is an intentional idempotent no-op for non-Anthropic providers (the key simply doesn't exist; `vhDelete` returns `Left (VaultKeyNotFound _)` which is treated as success).
  - Clears `default_provider` + `default_model` if they were set to this provider: `updateRuntimeConfig` with `rcDefaultProvider = Nothing, rcDefaultModel = Nothing` when `rcDefaultProvider cfg == Just (providerLabel kp)`.
  - 204 when vault is configured (idempotent — missing key is not an error).
  - 500 when vault is not configured (consistent with `handleSecretDelete`).
  - 500 when vault is locked.

**Route ordering**: `PUT /api/providers/default` (WU-3) MUST be matched
BEFORE `PUT /api/providers/:name` in the `case` expression, since both are
3-segment PUT routes and `"default"` would otherwise be captured as a
provider name. Same for `GET /api/providers/default` vs any `GET
/api/providers/:name`. The `default` literal arms appear before the
variable `:name` arms. The existing `GET /api/providers/all` is also a
literal arm that must precede any `:name` catch-all.

**DoD:**
1. All three endpoints are wired in the `apiApp` pattern match, with `all` and `default` literal routes ordered before `:name` variable routes
2. `POST /api/providers` with `name=anthropic, api_key=sk-xxx` stores `ANTHROPIC_API_KEY` in the vault + seeds config defaults (default_provider if unset, default_model if unset)
3. `POST /api/providers` with `name=ollama, base_url=http://localhost:11434` (no api_key) configures keyless local Ollama (succeeds even without vault)
4. `POST /api/providers` on an already-configured provider rotates the key + updates config (upsert, no 409)
5. `POST /api/providers` with `default_model` in the body overrides the seeded default
6. `PUT /api/providers/anthropic` with `api_key=new-key` rotates the vault key
7. `PUT /api/providers/anthropic` with `default_model=claude-sonnet-4` writes `[providers.anthropic] default_model`
8. `DELETE /api/providers/anthropic` removes BOTH `ANTHROPIC_API_KEY` and `ANTHROPIC_OAUTH_TOKENS` from the vault + clears default if set
9. Unknown provider name → 400 on POST and PUT
10. Vault not configured → 500 on POST (when api_key present), PUT (when api_key present), and DELETE (consistent with `handleSecretDelete`)
11. Vault locked → 500 on POST, PUT, and DELETE
12. API key is NEVER echoed back in any response
13. Tests use temp config files (mirroring `ApiSpec.hs:1827` where `srConfigPath = cfgRoot </> "config.toml"`) so `updateRuntimeConfig` writes to a real path
14. `RouteProviderCreate`, `RouteProviderUpdate`, `RouteProviderDelete` constructors added to `SealRoute` GADT with `routeMeta` arms, `Constructed` entries in `allRoutes`, and `openApiMeta` arms
15. `make check` passes

### WU-3: Backend — Default provider endpoints + SealRoute + route count update

**File scope:**
- `src/Seal/Gateway/API.hs` — new route patterns + handler functions
- `src-gateway-types/Seal/Gateway/Types/Route.hs` — add `RouteProviderDefaultGet`, `RouteProviderDefaultPut` constructors + `routeMeta` arms + `Constructed` entries
- `src/Seal/Gateway/OpenApi.hs` — add `openApiMeta` arms for the 2 new routes
- `test/Seal/Gateway/ApiSpec.hs` — new test cases
- `test/Seal/Gateway/ApiRouteSpec.hs` — update `expectedRouteCount` from 54 to 60 (54 + 6 new routes: `RouteProvidersAll`, `RouteProviderCreate`, `RouteProviderUpdate`, `RouteProviderDelete`, `RouteProviderDefaultGet`, `RouteProviderDefaultPut`)

**Endpoints:**
- `GET /api/providers/default` — reads `loadRuntimeConfig (srConfigPath (adSessionRuntime deps))` and returns `{"provider": "anthropic"}` or `{"provider": null}`
- `PUT /api/providers/default` — body: `{"provider": "anthropic"}`. Sets
  `default_provider` in config.toml via `updateRuntimeConfig`. 400 on
  unknown provider. Passing `null` or empty string clears the default.

**Route ordering**: These routes are matched BEFORE the `:name` routes (see
WU-2 route ordering note).

**DoD:**
1. Both endpoints are wired, ordered before `:name` routes
2. `GET` returns the configured `default_provider` from config.toml
3. `PUT` with a valid provider writes `default_provider` to config.toml
4. `PUT` with `null` / empty clears `default_provider`
5. `PUT` with an unknown provider → 400
6. `RouteProviderDefaultGet`, `RouteProviderDefaultPut` constructors added to `SealRoute` GADT with `routeMeta` arms, `Constructed` entries in `allRoutes`, and `openApiMeta` arms
7. `expectedRouteCount` in `ApiRouteSpec.hs` updated from 54 to 60
8. `make check` passes

### WU-4: Frontend — Types + API hooks

**File scope:**
- `frontend/src/types.ts` — new `ProviderDetail` + `ProviderInput` types
- `frontend/src/hooks/useApi.ts` — new provider CRUD functions + `useAllProviders` hook

**DoD:**
1. `ProviderDetail` type: `{name: string, isDefault: boolean, defaultModel: string | null, baseUrl: string | null, authStatus: "api-key" | "oauth" | "keyless" | "none" | "vault-locked"}`
2. `ProviderInput` type: `{name?: string, api_key?: string, base_url?: string, default_model?: string}`
3. `fetchAllProviders()` → `GET /api/providers/all` → `ProviderDetail[]`
4. `createProvider(input)` → `POST /api/providers` → `{ok: true, provider: ProviderDetail} | {ok: false, error: string}`
5. `updateProvider(name, input)` → `PUT /api/providers/:name` → `{ok: true, provider: ProviderDetail} | {ok: false, error: string}`
6. `deleteProvider(name)` → `DELETE /api/providers/:name` → `boolean`
7. `fetchDefaultProvider()` → `GET /api/providers/default` → `string | null`
8. `setDefaultProvider(name | null)` → `PUT /api/providers/default` → `boolean`
9. `useAllProviders()` hook with `{providers: ProviderDetail[], loaded, error, refresh}` — separate from the existing `useConfiguredProviders()` which is NOT modified
10. `make check` (frontend tests) passes

### WU-5: Frontend — `ProvidersView` component

**File scope:**
- `frontend/src/components/ProvidersView.tsx` — the full CRUD view
- `frontend/src/components/__tests__/ProvidersView.test.tsx` — component tests

**DoD:**
1. Left pane: lists ALL known providers (from `useAllProviders()`) with their auth status badge + default badge. Auth status badges: "API Key", "OAuth", "Keyless", "Not Configured", "Vault Locked". OAuth shown as a read-only badge (no OAuth login button — CLI-only).
2. Right pane: editor form with fields for API key (write-only password input), base URL (labeled with Ollama hint when provider is ollama), default model
3. "+" button opens a "New provider" form that lets the user select from known but unconfigured providers (dropdown of providers with `authStatus: "none"`)
4. Save button calls `createProvider` (new) or `updateProvider` (existing)
5. Delete button with confirmation calls `deleteProvider`
6. "Set as default" / "Clear default" button calls `setDefaultProvider`
7. API key field is `type="password"`, write-only, never pre-filled. Hint text on edit: "Paste a new key to rotate (the stored key is never shown)."
8. Error messages from the backend are surfaced in the form
9. List refreshes after every mutation
10. Empty state: when no providers are configured, shows "No providers configured. Click + to add one."
11. Vault-locked state: when `authStatus` is `"vault-locked"`, shows a warning badge and disables the API key field
12. Keyless state: when `authStatus` is `"keyless"`, the API key field shows a hint "This provider is keyless (local). No API key required." and the field is optional
13. Tests cover: render, create, edit, delete, set-default, error display, vault-locked state, keyless state
14. `make check` (frontend tests) passes

### WU-6: Frontend — Wire into TopBar + App

**File scope:**
- `frontend/src/components/TopBar.tsx` — add `'providers'` to `TopSection` union + `SECTION_LABELS` record, inserted between `'sessions'` and `'agents'`
- `frontend/src/App.tsx` — import `ProvidersView`, add section routing (`sectionFromPath` + `pathFromSection`), render switch
- `frontend/src/__tests__/App.test.tsx` — update fetch mocks to include `/api/providers/all` response

**DoD:**
1. "Providers" button appears between "Sessions" and "Agents" in the nav bar (insertion order in `SECTION_LABELS` record controls this)
2. Clicking it renders `ProvidersView`
3. URL `/providers` navigates to the Providers section (`sectionFromPath` + `pathFromSection` updated)
4. Browser back/forward works with the new section (popstate handler already handles this generically)
5. `data-testid="section-providers"` is on the nav button (generated automatically by the existing `SectionButton` template)
6. `App.test.tsx` fetch mocks include a mock for `GET /api/providers/all` so existing tests don't break when `ProvidersView` is rendered
7. **Integration verification**: after adding a provider via the ProvidersView (POST → vault key stored), the provider appears in the New-Tab composer's provider dropdown (which reads from `GET /api/providers` → `configuredProviders`). This works because `configuredProviders` checks the vault on each request — no changes to `useConfiguredProviders()` are needed. A manual or automated verification step confirms this round-trip.
8. `make check` passes

## Dependencies

- WU-1 → WU-2, WU-3 (handlers need the exported `anthropicOAuthKey` + `providerDetailJson` pattern + `RouteProvidersAll` precedent)
- WU-2, WU-3 → WU-4 (frontend hooks need the API endpoints)
- WU-4 → WU-5 (component uses the hooks)
- WU-5 → WU-6 (App wires the component)
- All WUs are sequential

## Security Considerations

- API keys are **write-only**: stored in the vault, never returned by any
  endpoint, never persisted in config.toml
- The `api_key` field in responses is always absent (same pattern as
  SecretsView's value field and ReposView's token field)
- Config writes use the existing `updateRuntimeConfig` (which can only
  modify `RuntimeConfig` — not security-critical `security.toml` fields)
- No new opcodes are created — all changes are in the gateway API layer
  (Trusted/Audited tier)
- DELETE removes both API key and OAuth token credentials from the vault
  (mirroring CLI `removeCmd`)

## Backward Compatibility

- `GET /api/providers` endpoint semantics are **unchanged** — still returns
  only configured providers with just `{"name": ...}`
- `useConfiguredProviders()` hook is **not modified** — NewTabComposer and
  AgentsView dropdowns continue to work exactly as before
- The new `GET /api/providers/all` endpoint is additive — no existing
  consumer is affected
- No new `ApiDeps` fields — all existing `ApiDeps` literals in tests compile
  unchanged
- `anthropicOAuthKey` export from `Seal.Providers.Registry` is additive —
  the duplicate in `Seal.Command.Provider` remains (no breaking change to
  the CLI module)
- New `SealRoute` constructors are additive — the route-count assertion is
  updated to match