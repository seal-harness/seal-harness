# Channel CRUD — Implementation Plan

> **Design spec:** `docs/superpowers/specs/2026-11-08-channel-crud-design.md` (approved, round 3)

**Goal:** Add a top-level "Channels" menu in the web UI for chat channel CRUD (Signal/Telegram), supporting multiple channels of the same type.

**Architecture:** A new `Seal.Channels.Config` module provides `ChannelId` (validated newtype), `ChannelConfig`, `ResolvedChannel`, a restricted-kind TOML codec, and a pure `resolveChannelConfig`. `RuntimeConfig` gains `rcChannels :: Map ChannelId ChannelConfig` (mirroring the providers `tableMap` pattern). Legacy `[signal]`/`[telegram]` sections are migrated per-id at load time. Four new gateway routes (GET/POST/PUT/DELETE `/api/channels`) with trasa constructors + manual dispatch arms. `seal serve` iterates the channel map. Frontend gets a `ChannelsView` + "Channels" top-level section.

**Tech Stack:** Haskell (GHC2021, tomland, trasa, aeson, hspec), React 18 + TS + Vite + Tailwind, vitest + RTL.

## Global Constraints

- **Warnings are errors.** `-Wall -Werror` + strict flag set. No unused binds, no partial functions, no orphan instances.
- **Default extensions** (do not re-declare): `DeriveGeneric DerivingStrategies LambdaCase ScopedTypeVariables`. Add `{-# LANGUAGE OverloadedStrings #-}` per-module.
- **TDD:** Failing test first, then minimal implementation, then commit. Security-critical pure functions get QuickCheck properties.
- **Secrets:** Telegram tokens stay vault-only; `ccToken` is a migration affordance only. Never log/return tokens.
- **`~/.seal/` untouched:** No handler or opcode reads/writes under `~/.seal/`.
- **Build/test commands** (inside nix dev shell):
  - Build: `cabal build all` (redirect to file — SIGPIPE pitfall)
  - Test: `cabal test >test.log 2>&1; head -80 test.log`
  - Focused: `cabal test --test-options='--match "<needle>"'`
  - Lint: `hlint src/ test/`
  - Full gate: `make check`
  - Frontend: `cd frontend && npm test -- --run` / `npm run build`
- **Commit style:** frequent, one per task. Never `--no-verify`. Never force-push.

## Work Unit Dependency Graph

```
W1 (Seal.Channels.Config) ──► W2 (RuntimeConfig wiring) ──► W3 (routes/handlers) ──► W6 (integration)
                                     ╲                              ╲
                                      ╲► W4 (serve)                  ╲► W5 (frontend) ──► W6
W4 needs W1+W2 only (not W3); W5 is independent of W1–W4 (can mock API); W6 needs W3+W5.
```

- W1 → W2: `rcChannels` needs `ChannelConfig` + `ChannelId`
- W2 → W3: handlers need `rcChannels` + helpers
- W1+W2 → W4: `forkChatChannels` needs `resolveChannelConfig` + the map (W4 does NOT depend on W3)
- W3 → W6: integration tests need the API handlers
- W5 → W6: integration needs the frontend (optional; W6 can test API-only)
- W5 is independent of W1–W4 (can mock the API)

---

## W1: `Seal.Channels.Config` — data model + codec + resolution

**Files:**
- New: `src/Seal/Channels/Config.hs`
- New: `test/Seal/Channels/ConfigSpec.hs`
- Modify: `src/Seal/Core/AllowList.hs` (export `allowListCodec`)
- Modify: `src/Seal/Signal/Config.hs` (import `allowListCodec` from `Seal.Core.AllowList`, remove local copy)
- Modify: `src/Seal/Telegram/Config.hs` (import `allowListCodec` from `Seal.Core.AllowList`, remove local copy)
- Modify: `seal-harness.cabal` (add `Seal.Channels.Config` to exposed-modules)
- Modify: `test/Main.hs` (wire `Seal.Channels.ConfigSpec`)

**Interfaces (produces):**
- `ChannelId` newtype — constructor exported via `(..)`; `mkChannelId :: Text -> Either Text ChannelId`, `channelIdText :: ChannelId -> Text`
- `ChannelConfig` record — `ccKind`, `ccLabel`, `ccAccount`, `ccToken`, `ccTextChunkLimit`, `ccAllowFrom`
- `ResolvedChannel` sum — `ResolvedSignal SignalAccount Int (AllowList UserId)` | `ResolvedTelegram TelegramToken Int (AllowList UserId)`
- `channelConfigCodec :: Toml.TomlCodec ChannelConfig` (restricted kind: signal/telegram only)
- `keyChannelIdBiMap :: TomlBiMap Toml.Key ChannelId` (fails closed on bad keys, mirrors `keyRepoBiMap`)
- `telegramVaultKeyFor :: ChannelId -> Text` (legacy "telegram" → `TELEGRAM_BOT_TOKEN`, others → suffixed)
- `resolveChannelConfig :: ChannelId -> ChannelConfig -> Maybe Text -> Either Text ResolvedChannel` (pure; `Maybe Text` = pre-fetched vault token)
- `fromSignalConfig :: SignalConfig -> ChannelConfig`, `fromTelegramConfig :: TelegramConfig -> ChannelConfig` (migration helpers)

**Test infrastructure:** Pure unit tests (no vault I/O — `resolveChannelConfig` takes `Maybe Text`).

### Step 1: Write failing tests (`test/Seal/Channels/ConfigSpec.hs`)

```haskell
describe "mkChannelId" $ do
  it "accepts valid ids" $ mkChannelId "work-signal" `shouldBe` Right (ChannelId "work-signal")
  it "rejects empty" $ mkChannelId "" `shouldSatisfy` isLeft
  it "rejects leading dash" $ mkChannelId "-bad" `shouldSatisfy` isLeft
  it "rejects spaces" $ mkChannelId "bad id" `shouldSatisfy` isLeft
  it "rejects special chars" $ mkChannelId "bad/id" `shouldSatisfy` isLeft
  it "accepts underscores, hyphens, alphanumerics" $ mkChannelId "prod_bot-1" `shouldBe` Right (ChannelId "prod_bot-1")

describe "telegramVaultKeyFor" $ do
  it "legacy id maps to unsuffixed key" $ telegramVaultKeyFor (ChannelId "telegram") `shouldBe` "TELEGRAM_BOT_TOKEN"
  it "other ids use suffixed key" $ telegramVaultKeyFor (ChannelId "dev-bot") `shouldBe` "TELEGRAM_BOT_TOKEN_dev-bot"

describe "channelConfigCodec" $ do
  it "round-trips a Signal channel" $ -- encode → decode → shouldBe
  it "round-trips a Telegram channel with token" $ -- encode → decode → shouldBe
  it "round-trips with AllowOnly allow_from" $ -- encode → decode → shouldBe
  it "rejects kind=cli" $ -- decode "kind = \"cli\"" → shouldFail
  it "rejects kind=web" $ -- decode "kind = \"web\"" → shouldFail
  it "accepts absent label (Nothing)" $ -- decode without label → ccLabel shouldBe Nothing
  it "accepts absent token (Nothing)" $ -- decode without token → ccToken shouldBe Nothing

describe "resolveChannelConfig" $ do
  it "Signal: resolves with account + defaults" $ -- resolveChannelConfig cid sigCfg Nothing → Right (ResolvedSignal ...)
  it "Signal: fails without account" $ -- resolveChannelConfig cid sigCfgNoAccount Nothing → Left
  it "Telegram: vault token takes precedence over ccToken" $ -- resolveChannelConfig cid tgCfg (Just "vault-tok") → token is "vault-tok"
  it "Telegram: falls back to ccToken when vault absent" $ -- resolveChannelConfig cid tgCfgWithToken Nothing → token is ccToken
  it "Telegram: fails when neither vault nor ccToken" $ -- resolveChannelConfig cid tgCfgNoToken Nothing → Left
```

Also add a QuickCheck property: `mkChannelId (channelIdText cid) === Right cid` for all `cid` generated from the valid charset.

### Step 2: Verify tests fail
`cabal test --test-options='--match "Seal.Channels.Config"'` → FAIL (module doesn't exist).

### Step 3: Implement `src/Seal/Channels/Config.hs`

- `ChannelId` newtype + `mkChannelId` (charset `[A-Za-z0-9_-]`, no leading dash, non-empty). Export `ChannelId (..)`.
- `ChannelConfig` record.
- `channelConfigCodec`: use `Toml.textBy` (or manual codec) for `kind` with `restrictKind` mapping only signal/telegram. Use `allowListCodec` (imported from `Seal.Core.AllowList`).
- `keyChannelIdBiMap`: mirror `keyRepoBiMap` — decode TOML key via `mkChannelId`, fail closed on invalid.
- `telegramVaultKeyFor`: special-case "telegram" → legacy key.
- `resolveChannelConfig`: pure; delegates to `resolveSignalConfig`/`resolveTelegramConfig` with appropriate args. For Telegram, `mVaultToken` (pre-fetched) takes precedence, then `ccToken`.
- `fromSignalConfig`/`fromTelegramConfig`: map legacy config sections to `ChannelConfig`.

### Step 4: Consolidate `allowListCodec`
- Export `allowListCodec` from `Seal.Core.AllowList`.
- Remove local copies from `Seal.Signal.Config` and `Seal.Telegram.Config`; import from `Seal.Core.AllowList`.

### Step 5: Wire into cabal + test/Main.hs
- Add `Seal.Channels.Config` to `exposed-modules` in `seal-harness.cabal`.
- Add `Seal.Channels.ConfigSpec` to test-suite `other-modules`.
- Wire into `test/Main.hs`.

### Step 6: Verify + commit
`cabal test --test-options='--match "Seal.Channels.Config"'` → PASS. `hlint src/Seal/Channels/Config.hs`. Commit.

---

## W2: Wire `rcChannels` into `RuntimeConfig` + migration

**Files:**
- Modify: `src/Seal/Config/File.hs`
- Modify: `test/Seal/Config/FileSpec.hs`

**Interfaces (produces):**
- `rcChannels :: RuntimeConfig -> Map ChannelId ChannelConfig` (new field)
- `migrateLegacyChannels :: RuntimeConfig -> RuntimeConfig` (in File.hs, per-id synthesis)
- `normalizeChannelsTable` (mirrors `normalizeProvidersTable`)
- `upsertChannel :: ChannelId -> (ChannelConfig -> ChannelConfig) -> RuntimeConfig -> RuntimeConfig`
- `deleteChannel :: ChannelId -> RuntimeConfig -> RuntimeConfig`

**Depends on:** W1 (`ChannelId`, `ChannelConfig`, `channelConfigCodec`, `keyChannelIdBiMap`, `fromSignalConfig`, `fromTelegramConfig`)

### Step 1: Write failing tests (`test/Seal/Config/FileSpec.hs`)

```haskell
describe "rcChannels" $ do
  it "defaultRuntimeConfig has empty rcChannels" $ rcChannels defaultRuntimeConfig `shouldBe` Map.empty
  -- Update the existing "has all Nothing fields" test to include rcChannels = Map.empty

describe "migrateLegacyChannels" $ do
  it "migrates legacy [signal] to channel id 'signal'" $ -- cfg with rcSignal=Just sig, rcChannels=empty → migrate → rcChannels has "signal"
  it "migrates legacy [telegram] to channel id 'telegram'" $ -- same for telegram
  it "migrates both signal + telegram" $ -- both present → both in map
  it "preserves tcToken in ccToken on migration" $ -- rcTelegram with tcToken=Just "tok" → ccToken = Just "tok"
  it "does NOT overwrite when channel id already exists" $ -- rcChannels has "signal" + rcSignal=Just sig → "signal" stays unchanged
  it "migrates legacy even when rcChannels is non-empty" $ -- rcChannels has "prod-telegram" + rcSignal=Just sig → both "prod-telegram" and "signal" in map

describe "channel config TOML round-trip" $ do
  it "parses [channels.work-signal] with kind=signal" $ -- loadRuntimeConfig → rcChannels has the entry
  it "parses [channels.dev-telegram] with kind=telegram" $ -- same
  it "round-trips save → load" $ -- saveRuntimeConfig → loadRuntimeConfig → shouldBe
  it "normalizes hand-written [channels.<id>] without bare [channels] header" $ -- same as providers normalization test

-- CRITICAL: There are THREE full RuntimeConfig { … } literals in FileSpec.hs that must be updated:
-- 1. The "has all Nothing fields" test (~line 31) → add rcChannels = Map.empty
-- 2. The "round-trips a fully-populated RuntimeConfig" test (~line 89) → add rcChannels = Map.fromList […]
--    with at least one channel entry (e.g. rcChannels = Map.fromList [(ChannelId "test-signal", ChannelConfig { … })])
-- 3. Any other RuntimeConfig literal in the file (grep for "RuntimeConfig {" to find all call sites)
-- All three must be updated in Step 1, or compilation fails under -Werror (Missing field rcChannels).
```

### Step 2: Verify tests fail
`cabal test --test-options='--match "Seal.Config.File"'` → FAIL (field doesn't exist).

### Step 3: Implement in `src/Seal/Config/File.hs`

> **Pre-flight:** `grep -rn "RuntimeConfig {" src/ test/` to find ALL full-record literals that need `rcChannels` added. There are at least 3 (two in FileSpec.hs, one in File.hs `defaultRuntimeConfig`).

- Add `rcChannels :: Map ChannelId ChannelConfig` to `RuntimeConfig`.
- Add to `defaultRuntimeConfig`: `rcChannels = Map.empty`.
- Add codec line: `Toml.tableMap keyChannelIdBiMap (Toml.table channelConfigCodec) "channels" .= rcChannels`.
- Add `normalizeChannelsTable` (mirror `normalizeProvidersTable`).
- Apply in `loadRuntimeConfig`: `normalizeChannelsTable` + `migrateLegacyChannels` after decode.
- Add `upsertChannel` / `deleteChannel` helpers (mirror `upsertProvider`).
- Update `defaultRuntimeConfig` literal (all fields explicit).

### Step 4: Verify + commit
`cabal test --test-options='--match "Seal.Config.File"'` → PASS. `hlint`. Commit.

---

## W3: Gateway routes + OpenAPI + handlers

**Files:**
- Modify: `src-gateway-types/Seal/Gateway/Types/Route.hs` (4 route constructors + `routeMeta` + `allRoutes`)
- Modify: `src/Seal/Gateway/OpenApi.hs` (4 OpenAPI arms)
- Modify: `src/Seal/Gateway/API.hs` (4 manual dispatch arms + 4 handlers + `channelDetailJson` helper)
- Modify: `test/Seal/Gateway/ApiRouteSpec.hs` (route count 62→66 + round-trip cases)
- Modify: `test/Seal/Gateway/ApiSpec.hs` (channel CRUD handler tests)

**Interfaces (produces):**
- `RouteChannelsList`, `RouteChannelCreate`, `RouteChannelUpdate`, `RouteChannelDelete` (SealRoute constructors)
- `handleChannelsList`, `handleChannelCreate`, `handleChannelUpdate`, `handleChannelDelete` (handlers)
- `channelDetailJson` (helper — builds camelCase JSON response)

**Depends on:** W2 (`rcChannels`, `upsertChannel`, `deleteChannel`)

**Test infrastructure:** `Seal.TestHelpers.ApiTestHarness` + `Seal.TestHelpers.FakeVault` (`makeFakeVaultRuntime`, `makeLockedVaultRuntime`).

### Step 1: Write failing tests

**`test/Seal/Gateway/ApiRouteSpec.hs`:**
```haskell
-- Update expectedRouteCount from 62 to 66
expectedRouteCount = 66
-- Add round-trip cases for the 4 new routes
```

**`test/Seal/Gateway/ApiSpec.hs`** (channel CRUD tests, modeled on provider tests ~line 4154+):
```haskell
describe "channel CRUD" $ do
  it "GET /api/channels returns 200 with empty array when no channels" $
  it "GET /api/channels returns camelCase JSON (textChunkLimit, allowFrom, authStatus)" $
  it "POST /api/channels creates a Signal channel" $ -- POST {id,kind:signal,account:"..."} → 201; GET → present
  it "POST /api/channels creates a Telegram channel + stores token in vault" $ -- POST {id,kind:telegram,token:"..."} → 201; vault has key
  it "POST /api/channels rejects duplicate id (409)" $
  it "POST /api/channels rejects invalid id (400)" $ -- id with spaces → 400
  it "POST /api/channels rejects invalid kind (400)" $ -- kind=slack → 400
  it "PUT /api/channels/:id updates label + chunk limit" $ -- PUT → 200; GET → updated values
  it "PUT /api/channels/:id rotates telegram token in vault" $ -- PUT with token → vault key updated
  it "PUT /api/channels/:id returns 404 for unknown id" $
  it "DELETE /api/channels/:id removes channel" $ -- DELETE → 204; GET → absent
  it "DELETE /api/channels/:id deletes vault key for telegram" $
  it "DELETE /api/channels/:id nullifies legacy field for 'telegram' id" $ -- DELETE "telegram" → rcTelegram becomes Nothing
  it "DELETE /api/channels/:id is idempotent (204 for missing id)" $
  it "GET /api/channels authStatus: 'missing-credential' for signal without account" $
  it "GET /api/channels authStatus: 'vault-locked' for telegram when vault locked" $
```

### Step 2: Verify tests fail
`cabal test --test-options='--match "channel CRUD"'` + `cabal test --test-options='--match "ApiRoute"'` → FAIL.

### Step 3: Implement routes + handlers

**`Route.hs`:** Add 4 constructors, 4 `routeMeta` arms, 4 `allRoutes` entries (after providers, before UI).

**`OpenApi.hs`:** Add 4 arms mirroring the provider arms.

**`API.hs`:**
- Add 4 manual dispatch arms in the `(method, pathInfo)` pattern match block.
- `handleChannelsList`: load config, migrate, `mapM (channelDetailJson cfg mh) (Map.toList (rcChannels cfg))`, return JSON array.
- `handleChannelCreate`: validate id via `mkChannelId`, validate kind, check duplicate (409), store token in vault (Telegram), `upsertChannel`, `updateRuntimeConfig`, return 201 + detail.
- `handleChannelUpdate`: 404 if not found, update fields, rotate vault key if token present, `updateRuntimeConfig`, return 200 + detail.
- `handleChannelDelete`: `deleteChannel`, delete vault key (Telegram), nullify legacy field if "signal"/"telegram", `updateRuntimeConfig`, return 204.
- `channelDetailJson`: camelCase JSON — `{ id, kind, label, account, textChunkLimit, allowFrom, authStatus }`. Probe vault for Telegram authStatus.

### Step 4: Verify + commit
`cabal test --test-options='--match "channel"'` + `cabal test --test-options='--match "ApiRoute"'` → PASS. `hlint`. Commit.

---

## W4: `seal serve` — `forkChatChannels` iteration

**Files:**
- Modify: `src/Seal/Command/Serve.hs`
- Modify: `test/Seal/Command/ServeSpec.hs` (if it references `forkNewSignalChatChannel` / `forkNewTelegramChatChannel`)

**Depends on:** W1 (`resolveChannelConfig`, `ResolvedChannel`), W2 (`rcChannels`)

### Step 1: Write failing tests

Check if `test/Seal/Command/ServeSpec.hs` exists and tests the fork functions. If so, update tests to expect the new `forkChatChannels` iteration. If not, write integration-level tests verifying:
- `forkChatChannels` iterates all entries in `rcChannels`
- Channels that fail resolution log a warning (not crash)
- Each resolved channel forks the appropriate `withSignalChatChannel`/`withTelegramChatChannel`

If no ServeSpec exists, verify via `make build` (compile check) + manual smoke test.

### Step 2: Implement in `src/Seal/Command/Serve.hs`

- Extract the post-resolution body from `forkNewSignalChatChannel` / `forkNewTelegramChatChannel` into `forkResolvedChannel`.
- `forkResolvedChannel` pattern-matches on `ResolvedChannel`:
  - `ResolvedSignal account chunkLimit allow` → build transport via `mkRealSignalChatTransport`, fork `withSignalChatChannel`.
  - `ResolvedTelegram token chunkLimit allow` → build transport via `mkRealTelegramChatTransport`, fork `withTelegramChatChannel`.
- `forkChatChannels`: iterate `Map.traverseWithKey forkOne (rcChannels cfg)`. Each `forkOne` does `vhGet` (IO) for Telegram, then calls pure `resolveChannelConfig`, then forks.
- Replace the calls to `forkNewSignalChatChannel` / `forkNewTelegramChatChannel` in `runServeMain` with `forkChatChannels`.

### Step 3: Verify + commit
`cabal build all` → clean. `make check` → PASS. `hlint`. Commit.

---

## W5: Frontend — `ChannelsView` + TopBar + App routing + types + hooks

**Files:**
- New: `frontend/src/components/ChannelsView.tsx`
- New: `frontend/src/components/__tests__/ChannelsView.test.tsx`
- Modify: `frontend/src/components/TopBar.tsx` (add `'channels'` to `TopSection` + `SECTION_LABELS`)
- Modify: `frontend/src/App.tsx` (add `/channels` routing + render `<ChannelsView />`)
- Modify: `frontend/src/types.ts` (add `ChannelDetail`, `ChannelAuthStatus`, `ChannelInput`, `ChannelUpdateInput`, `ChannelMutationResult`)
- Modify: `frontend/src/hooks/useApi.ts` (add `useChannels`, `createChannel`, `updateChannel`, `deleteChannel`)

**Depends on:** None (can mock the API; independent of W1–W4).

### Step 1: Write failing tests (`frontend/src/components/__tests__/ChannelsView.test.tsx`)

```tsx
describe('ChannelsView', () => {
  it('renders loading state', () => { /* !loaded → "Loading…" */ })
  it('renders empty state', () => { /* loaded, no channels → "No channels configured." */ })
  it('renders channel list with kind badges', () => { /* 2 channels → 2 rows with Signal/Telegram labels */ })
  it('renders error state', () => { /* error → "Failed to load" */ })
  it('clicking + opens new-channel form', () => { /* click + → form with kind select + id input */ })
  it('creating a signal channel POSTs correct snake_case body', () => { /* fill form → submit → POST body has text_chunk_limit, allow_from */ })
  it('editing a channel seeds form from camelCase response', () => { /* click row → form seeded with textChunkLimit, allowFrom from detail */ })
  it('deleting a channel shows confirm then DELETEs', () => { /* click delete → confirm → DELETE → list updates */ })
  it('shows restart-needed notice after mutation', () => { /* after create/update/delete → banner visible */ })
  it('hides account field for Telegram kind', () => { /* kind=telegram → no account input */ })
  it('hides token field for Signal kind', () => { /* kind=signal → no token input */ })
  it('disables Save when id has invalid chars', () => { /* id="bad id" → Save disabled */ })
})
```

### Step 2: Verify tests fail
`cd frontend && npm test -- --run -- ChannelsView` → FAIL (component doesn't exist).

### Step 3: Implement types + hooks

**`types.ts`:**
```typescript
export type ChannelAuthStatus = 'configured' | 'missing-credential' | 'vault-locked'
export interface ChannelDetail { id: string; kind: string; label: string | null; account: string | null; textChunkLimit: number | null; allowFrom: string[] | null; authStatus: ChannelAuthStatus }
export interface ChannelInput { id: string; kind: string; label?: string; account?: string; token?: string; text_chunk_limit?: number; allow_from?: string[] }
export interface ChannelUpdateInput { label?: string; account?: string; token?: string; text_chunk_limit?: number; allow_from?: string[] }
export type ChannelMutationResult = { ok: true; channel: ChannelDetail } | { ok: false; error: string }
```

**`useApi.ts`:** `useChannels()` (mount + refresh, NOT polling — mirrors `useAllProviders`), `createChannel`, `updateChannel`, `deleteChannel`.

### Step 4: Implement `ChannelsView.tsx`

Model on `ProvidersView.tsx`:
- List pane (left): channels with kind badge + label. "+" button.
- Editor pane (right): form with kind/id/label/account/token/text_chunk_limit/allow_from fields.
- `allow_from` edit-seed: join array with `", "`. Submit: `value.split(',').map(s => s.trim()).filter(Boolean)`.
- Restart-needed notice: persists until user navigates away or starts a new mutation.
- Empty/loading/error states (matching ProvidersView).
- Delete with `confirmingDelete` pattern.

### Step 5: Update TopBar + App

**`TopBar.tsx`:** Add `'channels'` to `TopSection` union + `SECTION_LABELS` (`channels: 'Channels'`).

**`App.tsx`:** Add `/channels` to `sectionFromPath` + `pathFromSection`. Render `<ChannelsView />` when `section === 'channels'`.

### Step 6: Verify + commit
`cd frontend && npm test -- --run` → PASS. `npm run build` → clean. Commit.

---

## W6: Integration smoke test — end-to-end channel CRUD via API

**Files:**
- Modify: `test/Seal/Gateway/ApiSpec.hs` (or `ApiIntegrationSpec.hs`)

**Depends on:** W3 (handlers), W5 (frontend — optional; can test API-only)

### Step 1: Write failing test

```haskell
describe "channel CRUD integration" $ do
  it "full lifecycle: create → list → update → delete" $ do
    -- POST /api/channels {id:"work-signal", kind:"signal", account:"+1555"} → 201
    -- GET /api/channels → array contains work-signal
    -- PUT /api/channels/work-signal {label:"Work"} → 200, label updated
    -- DELETE /api/channels/work-signal → 204
    -- GET /api/channels → array empty
  it "legacy migration: [telegram] with vault token → channel appears in GET /api/channels" $ do
    -- seed config with rcTelegram=Just TelegramConfig{tcToken=Nothing}, vault has TELEGRAM_BOT_TOKEN
    -- loadRuntimeConfig migrates → GET /api/channels returns "telegram" channel
    -- authStatus = "configured" (vault has token)
  it "legacy migration: [telegram] with tcToken in config → authStatus reflects config token" $ do
    -- seed config with rcTelegram=Just TelegramConfig{tcToken=Just "tok"}, no vault key
    -- GET /api/channels → "telegram" channel with authStatus="configured"
  it "multiple channels of same type: 2 signal channels coexist" $ do
    -- POST {id:"sig1",kind:"signal",account:"+1"} → 201
    -- POST {id:"sig2",kind:"signal",account:"+2"} → 201
    -- GET → both present
```

### Step 2: Verify + commit
`cabal test --test-options='--match "channel CRUD integration"'` → PASS. Final `make check`. Commit.

---

## Post-Implementation

- [ ] `make check` green (build + test + lint)
- [ ] `cd frontend && npm test -- --run && npm run build` green
- [ ] Run `self-reflect` to capture learnings
- [ ] Commit knowledge base updates
- [ ] Create branch `feat/channel-crud` off `main`
- [ ] Open draft PR with `Closes` reference
