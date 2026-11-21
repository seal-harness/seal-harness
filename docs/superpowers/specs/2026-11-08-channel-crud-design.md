# Channel CRUD — Multi-Instance Chat Channel Management

**Date**: 2026-11-08 · **Status**: revised (round 2, post-review-gate) · **Branch**: `feat/channel-crud`

## Design review gate (round 1 → round 2)

Round 1 ran 5 reviewers (PM, Architect, Designer, Security, CTO) in parallel.
All 5 returned NEEDS_REVISION. Resolutions:

- **Circular dependency** (Architect B1) — `migrateLegacyChannels` was
  typed `RuntimeConfig -> RuntimeConfig` in `Seal.Channels.Config`, creating
  a mutual cycle with `File.hs` (which imports `Channels.Config` for the
  `rcChannels` field + codec). Resolution: `migrateLegacyChannels` moves
  into `File.hs` (it operates on `RuntimeConfig` and is only called there).
  `Seal.Channels.Config` exports only the leaf types + codec + resolution.
  Fixed §3.1, §3.3, §5.
- **Missing `normalizeChannelsTable`** (Architect B2) — tomland's
  `Toml.tableMap` silently returns an empty map when a config has only
  `[channels.<id>]` sub-tables and no bare `[channels]` header (the
  idiomatic hand-written style). This is the same bug `File.hs` already
  works around with `normalizeProvidersTable`. Resolution: add a parallel
  `normalizeChannelsTable` and apply it in `loadRuntimeConfig`. Fixed §3.2.
- **Migration condition drops legacy channels** (Architect B3) + **legacy
  deletion respawn** (Designer B2) — the original "synthesize only when
  `rcChannels` is empty" guard silently drops a legacy `[signal]` when the
  operator also has `[channels.prod-telegram]` (non-empty map, no
  `"signal"` key). And deleting the sole migrated legacy channel respawns
  it on the next load (legacy field still set → re-synthesized). Resolution:
  (a) migration synthesizes **per-id** (`Map.notMember "signal" rcChannels`
  / `Map.notMember "telegram" rcChannels`), not whole-map-empty; (b)
  `handleChannelDelete` nullifies the corresponding legacy field
  (`rcSignal = Nothing` / `rcTelegram = Nothing`) in the same
  `updateRuntimeConfig` transaction when the deleted id is a legacy default.
  Fixed §3.3, §3.7.
- **`enumBounded` codec** (Architect H1, CTO B1) — `Toml.enumBounded` over
  `ChannelKind` produces Int (not Text), and `channelKindFromText` accepts
  all 6 constructors (Cli/Web/Background/Other are invalid channel types —
  `ResolvedChannel` has only Signal/Telegram arms). Resolution: a custom
  `TomlBiMap ChannelKind Text` restricted to `"signal"`→Signal and
  `"telegram"`→Telegram, returning a decode error for any other kind. Fixed
  §3.2.
- **Legacy token-in-config Telegram dropped** (CTO B2) — `TelegramConfig`
  has `tcToken :: Maybe Text`; operators can store the bot token in
  `[telegram] token = "…"` (cleartext config) rather than the vault.
  `migrateLegacyChannels` synthesized a `ChannelConfig` (which has no token
  field), so the token was lost → Telegram silently stops listening. This
  breaks the zero-migration promise. Resolution: `migrateLegacyChannels`
  runs at load time and is pure (no vault I/O); to preserve the token, the
  migrated `ChannelConfig` gains a `ccToken :: Maybe Text` field (config-
  level, mirrors `tcToken`). `resolveChannelConfig` uses it as a fallback
  when the vault key is absent (vault takes precedence). The legacy
  `telegramVaultKey` fallback is removed — the config token IS the fallback.
  Fixed §3.1, §3.4, §3.5.
- **ChannelId is raw Text** (Security B1, CTO S1) — the design used raw
  `Text` for channel ids at every boundary (`Map Text`, vault key, TOML key,
  URL capture), violating the type-guaranteed sanitization standard
  (`RepoId`/`SignalAccount`/`TelegramToken` all use unexported-constructor
  newtypes). Resolution: introduce `ChannelId` newtype with unexported
  constructor + `mkChannelId` smart constructor (non-empty, no leading dash,
  `[A-Za-z0-9_-]` charset). `rcChannels :: Map ChannelId ChannelConfig`.
  `telegramVaultKeyFor :: ChannelId -> Text`. A `TomlBiMap Key ChannelId`
  fails closed on bad TOML keys (mirrors `keyRepoBiMap`). The URL capture
  and POST body run `mkChannelId` fail-closed. Fixed §3.1, §3.4, §3.7, §4.
- **Wire-key naming inconsistency** (Designer B1) — §3.7 used snake_case
  response keys but §3.9 used camelCase TS types, and neither followed the
  established split (provider DETAIL responses emit camelCase JSON matching
  `ProviderDetail` 1:1; provider INPUT bodies use snake_case matching
  `ProviderInput` 1:1). Resolution: channel detail response emits camelCase
  (`textChunkLimit`, `allowFrom`, `authStatus`) matching `ChannelDetail` TS
  type 1:1 (no mapping function). Channel input bodies use snake_case
  (`text_chunk_limit`, `allow_from`, `token`) matching `ChannelInput` TS
  type 1:1. Fixed §3.7, §3.9.
- **Test landmines** (CTO B3) — `test/Seal/Gateway/ApiRouteSpec.hs` asserts
  `length allRoutes shouldBe 62` (becomes 66); `test/Seal/Config/FileSpec.hs`
  has a literal `defaultRuntimeConfig shouldBe RuntimeConfig{ … }` and an
  "all Nothing fields" test (must add `rcChannels = Map.empty`). Neither was
  in the File Scope. Resolution: both added to §5 File Scope.
- **Restart expectations** (PM B1) — success metric #2 claimed "no restart
  for config changes — though new channels require a restart," but
  edit/delete of an active channel ALSO requires a restart to affect the
  running listener. An operator would believe they deleted a channel that's
  still receiving messages. Resolution: metric #2 rewritten — the web UI
  manages channel *configuration*; a serve restart is required for any
  change (add/edit/delete) to take effect on running listeners. The UI
  shows a "restart needed" notice after any mutation. Fixed §1.1, §3.8.

### Round 2 → round 3 revisions

4 of 5 reviewers returned NEEDS_REVISION in round 2 (CTO APPROVED).
Resolutions:

- **Vault-key mismatch for legacy Telegram** (PM, Architect B3, Security) —
  the CLI wizard (the primary setup path) stores the bot token under the
  unsuffixed vault key `TELEGRAM_BOT_TOKEN` with `tcToken = Nothing`. The
  round-2 design migrated the channel to id `"telegram"` whose
  parameterized key is `TELEGRAM_BOT_TOKEN_telegram` — a different key.
  The token is not found → Telegram silently stops, breaking success
  metric #3. Resolution: `telegramVaultKeyFor` maps the legacy id
  `"telegram"` to the legacy key `TELEGRAM_BOT_TOKEN` (not the suffixed
  form); all other ids use `TELEGRAM_BOT_TOKEN_<id>`. The migrated
  "telegram" channel reads the same key the CLI wizard wrote — zero
  migration. Fixed §3.4.
- **ChannelId constructor export** (Architect B1, Security) — the design
  said "unexported constructor" but the precedents (`RepoId`,
  `SignalAccount`, `TelegramToken`) all export via `(..)`. And
  `migrateLegacyChannels` in `File.hs` uses `ChannelId "signal"` literals
  which require the constructor. Resolution: export `ChannelId (..)`, use
  `mkChannelId` at trust boundaries (POST handler, URL capture, TOML key
  decode) — exactly like `RepoId`. Fixed §3.1.
- **resolveChannelConfig purity vs IO** (Architect B2) — the round-2
  signature `... -> Maybe VaultHandle -> Either Text ResolvedChannel` is
  pure but must call `vhGet` (IO) to read the vault — won't typecheck.
  Resolution: change the signature to take `Maybe Text` (a pre-fetched
  token), do the `vhGet` in `forkOne`. This matches the existing pure
  `resolveTelegramConfig`/`resolveSignalConfig` pattern and makes
  `resolveChannelConfig` unit-testable without a vault. Fixed §3.5.
- **§3.9 inline ChannelInput type literal** (Designer) — the inline type
  literal still showed camelCase `textChunkLimit?`/`allowFrom?`,
  contradicting the surrounding prose and §3.7's input spec. Resolution:
  corrected to snake_case `text_chunk_limit?`/`allow_from?`. Fixed §3.9.

### Non-blocking suggestions incorporated

- **`ChannelDetail` not `ChannelInfo`** (Designer S1) — the TS response
  type is named `ChannelDetail` (parity with `ProviderDetail`).
- **`ChannelAuthStatus` union type** (Designer S2) —
  `'configured' | 'missing-credential' | 'vault-locked'` mirroring
  `ProviderAuthStatus`.
- **`ChannelMutationResult` type** (Designer S3) —
  `{ ok: true; channel: ChannelDetail } | { ok: false; error: string }`.
- **Empty/loading/error UI states** (Designer S4) — enumerated in §3.8.
- **`useChannels` = mount + refresh, not polling** (Designer S5) — channel
  config changes only via this UI; matches `useAllProviders`.
- **`allow_from` parsing rules** (Designer S7) —
  `value.split(',').map(s => s.trim()).filter(Boolean)`.
- **`allowListCodec` consolidation** (CTO S4) — export from
  `Seal.Core.AllowList` and import in all three modules (Signal, Telegram,
  Channels) rather than triplicating.
- **Work-unit dependency graph** (CTO S5) — added to §6.
- **Manual router dispatch** (CTO S6) — §3.6 now notes the four manual
  `(method, pathInfo)` arms in `API.hs` alongside the trasa constructors.
- **`forkResolvedChannel` extraction** (Architect H2) — §3.5 notes the
  existing monolithic fork functions need extraction into a post-resolution
  body.
- **WHEN triggers on user stories** (PM) — added to §1.0.
- **Legacy-field tech debt** (PM) — noted in §3.3 for future cleanup.

## 1. Problem

### 1.0 User stories

1. **Operator with multiple Signal numbers** (WHO) — when they want to
   connect a personal Signal number and a work Signal number to the same
   Seal instance (WHEN) — wants both channels active simultaneously
   (WANTS-TO) — so that messages from each conversation reach their
   respective sessions (SO-THAT). Today this is impossible: `RuntimeConfig`
   has a single `rcSignal :: Maybe SignalConfig`.
2. **Operator managing several Telegram bots** (WHO) — when they want to
   run a dev bot and a prod bot at the same time (WHEN) — wants both
   listening simultaneously (WANTS-TO) — so they can test commands on the
   dev bot before sending them on prod (SO-THAT). Today impossible: single
   `rcTelegram` and a single vault key `TELEGRAM_BOT_TOKEN`.
3. **Operator on the web UI** (WHO) — when they need to add, edit, or
   remove a chat channel (WHEN) — wants to do it from a top-level
   "Channels" menu without SSHing in to edit `config.toml` (WANTS-TO) — so
   channel lifecycle is self-service (SO-THAT). Today channels are only
   configurable via the `/channel` CLI wizard, which writes a single
   `[signal]` or `[telegram]` section.

### 1.1 Success metrics

- An operator can configure 2+ Signal channels and 2+ Telegram channels
  simultaneously; messages on each reach distinct sessions.
- Channel add/edit/delete is achievable entirely from the web UI (no
  `config.toml` editing). **A `seal serve` restart is required for any
  configuration change (add/edit/delete) to take effect on running
  listeners** — the web UI manages channel *configuration*; it does not
  hot-reload running channel processes. The UI displays a "restart needed"
  notice after every mutation so the operator knows the running listener
  is stale until restart.
- An existing `config.toml` with legacy `[signal]` / `[telegram]` sections
  (including token-in-config) continues to work after upgrade (zero
  migration steps).

### 1.2 Non-goals

- Hot-reloading channels without a `seal serve` restart. (Future work; out
  of scope — the serve command forks channels at boot.)
- Adding new channel *types* (Slack, IRC, Matrix). The design is
  type-extensible, but only Signal and Telegram are wired in this iteration.
- Migrating the `/channel` CLI wizard to the new config format. The CLI
  continues to write legacy `[signal]`/`[telegram]` sections; the web UI
  writes `[channels.<id>]` sections. Both coexist (§3.3). The legacy
  `rcSignal`/`rcTelegram` fields are tech debt for future cleanup once the
  CLI wizard is migrated.

## 2. Current Architecture (summary)

- **Config**: `RuntimeConfig` (`src/Seal/Config/File.hs`) has
  `rcSignal :: Maybe SignalConfig` and `rcTelegram :: Maybe TelegramConfig`
  — singular, one per type. TOML codec uses `Toml.table` for each.
- **Resolution**: `resolveSignalConfig` / `resolveTelegramConfig` take the
  `Maybe <Type>Config` section + an optional vault value, smart-construct
  the credential, and return `(credential, chunkLimit, allowList)`.
- **Startup**: `forkNewSignalChatChannel` / `forkNewTelegramChatChannel` in
  `Serve.hs` resolve the single section and fork one channel each. These
  functions are monolithic (resolve → transport → register → fork); §3.5
  notes they need extraction into a post-resolution body.
- **Gateway API**: trasa `SealRoute` GADT (`Route.hs`) → handlers (`API.hs`).
  The runtime dispatch in `API.hs` is a **manual `(method, pathInfo)`
  pattern match** (~line 480+), NOT the trasa `sealRouter` — both the trasa
  constructors AND the manual dispatch arms must be added. Providers have
  full CRUD backed by `Map Text ProviderConfig` via `Toml.tableMap` — the
  template for channels.
- **Frontend**: `TopBar` top-level sections; `ProvidersView` is the CRUD UI
  template (list pane + editor pane); `useApi.ts` has all hooks.

## 3. Design

### 3.1 Data model — `ChannelConfig` + `ChannelId`

A new module `src/Seal/Channels/Config.hs` exports the leaf types + codec +
resolution (no `RuntimeConfig` import — keeps the module acyclic; migration
lives in `File.hs`, §3.3):

```haskell
-- | Validated channel id (the [channels.<id>] key + URL capture + vault-key
-- component). Smart-constructed: non-empty, no leading dash (option-
-- injection defense), charset [A-Za-z0-9_-]. Constructor exported (like
-- RepoId); mkChannelId is used at trust boundaries (POST body, URL capture,
-- TOML key decode via keyChannelIdBiMap) to validate untrusted input.
newtype ChannelId = ChannelId Text
  deriving stock (Eq, Ord, Show)

mkChannelId :: Text -> Either Text ChannelId
channelIdText :: ChannelId -> Text

data ChannelConfig = ChannelConfig
  { ccKind           :: ChannelKind   -- Signal | Telegram only (codec rejects others)
  , ccLabel          :: Maybe Text    -- human-readable name (optional)
  , ccAccount        :: Maybe Text    -- Signal: phone/UUID
  , ccToken          :: Maybe Text    -- Telegram: config-level token fallback (mirrors tcToken)
  , ccTextChunkLimit :: Maybe Int
  , ccAllowFrom      :: AllowList Text
  }
```

- `ccKind` discriminates the channel type. We reuse `ChannelKind` from
  `Seal.Gateway.Types.ChannelKind` (re-exported as `Seal.Core.ChannelKind`
  in the server), but the codec (§3.2) restricts it to Signal/Telegram.
- `ccAccount` is Signal-specific. `ccToken` is the Telegram config-level
  token fallback (mirrors `tcToken` in the legacy `TelegramConfig`); the
  vault token takes precedence at resolution time (§3.5).
- `ccLabel` is optional; the UI defaults it to `channelIdText` if absent.

`RuntimeConfig` gains:

```haskell
, rcChannels :: Map ChannelId ChannelConfig
```

The existing `rcSignal` / `rcTelegram` fields are **retained** for back-compat
migration (§3.3) but are no longer the primary source at serve time. They
are tech debt for future cleanup.

### 3.2 TOML format + codec

Mirrors the `[providers.<label>]` pattern (`Toml.tableMap`):

```toml
[channels.work-signal]
kind = "signal"
label = "Work Signal"
account = "+15555550123"
text_chunk_limit = 1998
allow_from = ["+15555550123"]

[channels.dev-telegram]
kind = "telegram"
label = "Dev Bot"
text_chunk_limit = 3900
allow_from = ["123456789"]
```

Codec in `Seal.Channels.Config`:

```haskell
channelConfigCodec :: Toml.TomlCodec ChannelConfig
channelConfigCodec = ChannelConfig
  <$> Toml.textBy "kind" channelKindToText restrictKind  .= ccKind
  <*> Toml.dioptional (Toml.text "label")                .= ccLabel
  <*> Toml.dioptional (Toml.text "account")              .= ccAccount
  <*> Toml.dioptional (Toml.text "token")                .= ccToken
  <*> Toml.dioptional (Toml.int "text_chunk_limit")      .= ccTextChunkLimit
  <*> allowListCodec                                    .= ccAllowFrom
```

where `restrictKind` maps only `"signal"`→`Signal` and `"telegram"`→`Telegram`,
returning `Left "invalid channel kind"` for any other value (including
`cli`/`web`/`background`/`other`). This is a **custom restricted codec**, NOT
`Toml.enumBounded` (which produces Int and accepts all 6 constructors).

Wired into `runtimeConfigCodec` as:

```haskell
<*> Toml.tableMap keyChannelIdBiMap (Toml.table channelConfigCodec) "channels" .= rcChannels
```

where `keyChannelIdBiMap :: TomlBiMap Key ChannelId` fails closed on bad
keys (mirrors `keyRepoBiMap`). **`allowListCodec`** is consolidated —
exported from `Seal.Core.AllowList` and imported in `Seal.Signal.Config`,
`Seal.Telegram.Config`, and `Seal.Channels.Config` (eliminating the current
triplication).

**`normalizeChannelsTable`**: tomland's `Toml.tableMap` silently returns an
empty map when a config has only `[channels.<id>]` sub-tables and no bare
`[channels]` header (the idiomatic hand-written style). `File.hs` already
works around this for providers with `normalizeProvidersTable`. A parallel
`normalizeChannelsTable` is applied in `loadRuntimeConfig` alongside the
providers normalization.

### 3.3 Back-compat migration (legacy `[signal]` / `[telegram]`)

`migrateLegacyChannels` lives in `File.hs` (it operates on `RuntimeConfig`
and is only called there — avoids a cycle with `Seal.Channels.Config`).
Called inside `loadRuntimeConfig` after decode + normalization, so every
reader sees the unified map.

**Per-id synthesis** (not whole-map-empty):

```haskell
migrateLegacyChannels :: RuntimeConfig -> RuntimeConfig
migrateLegacyChannels cfg =
  let chans0 = rcChannels cfg
      chans1 = case (Map.notMember (ChannelId "signal") chans0, rcSignal cfg) of
        (True, Just sig) -> Map.insert (ChannelId "signal") (fromSignalConfig sig) chans0
        _                -> chans0
      chans2 = case (Map.notMember (ChannelId "telegram") chans1, rcTelegram cfg) of
        (True, Just tg) -> Map.insert (ChannelId "telegram") (fromTelegramConfig tg) chans1
        _               -> chans1
  in cfg { rcChannels = chans2 }
```

- `fromSignalConfig` maps `scAccount`/`scTextChunkLimit`/`scAllowFrom` →
  `ChannelConfig { kind=Signal, ccToken=Nothing, … }`.
- `fromTelegramConfig` maps `tcToken`/`tcTextChunkLimit`/`tcAllowFrom` →
  `ChannelConfig { kind=Telegram, ccToken=tcToken, … }` — **preserving the
  config-level token** so token-in-config setups survive migration.

This is **read-only migration** — the legacy sections are NOT removed from
the file. The web UI reads/writes `[channels.<id>]`; the CLI wizard
continues to write `[signal]`/`[telegram]`. If both exist with the same
default id, the channel map entry wins (the legacy section is ignored for
that id).

**Coexistence rule**: legacy sections that DON'T collide with an existing
channel id are migrated even when `rcChannels` is non-empty. Once an id
exists in `rcChannels`, the corresponding legacy section is ignored. This
handles the upgrade transition (operator has `[channels.prod-telegram]` +
legacy `[signal]` → both appear).

**Deletion respawn prevention**: `handleChannelDelete` (§3.7) nullifies the
corresponding legacy field (`rcSignal = Nothing` / `rcTelegram = Nothing`)
in the same `updateRuntimeConfig` transaction when the deleted id is a
legacy default (`"signal"` / `"telegram"`), so the legacy section no longer
triggers re-synthesis on the next load.

### 3.4 Vault keys for multi-channel Telegram

Each Telegram channel needs its own bot token. The vault key is
parameterized by channel id:

```haskell
-- | The vault key for a Telegram channel's bot token. The legacy id
-- "telegram" maps to the unsuffixed key TELEGRAM_BOT_TOKEN (the key the
-- CLI wizard writes), preserving zero-migration. All other ids use the
-- suffixed form.
telegramVaultKeyFor :: ChannelId -> Text
telegramVaultKeyFor cid =
  if channelIdText cid == "telegram"
    then "TELEGRAM_BOT_TOKEN"
    else "TELEGRAM_BOT_TOKEN_" <> channelIdText cid
```

For the **legacy** single Telegram channel (id `"telegram"`),
`telegramVaultKeyFor` returns the unsuffixed `TELEGRAM_BOT_TOKEN` — the
same key the CLI wizard writes. The migrated "telegram" channel reads it
directly, preserving zero-migration. The `ccToken` field remains as a
fallback for operators who stored the token in config (not vault).

New channels created via the web UI use the parameterized (suffixed) key.

Signal accounts are stored in `ccAccount` (config, not vault) — same as
today.

### 3.5 Channel resolution + serve startup

`resolveChannelConfig` in `Seal.Channels.Config`:

```haskell
data ResolvedChannel
  = ResolvedSignal SignalAccount Int (AllowList UserId)
  | ResolvedTelegram TelegramToken Int (AllowList UserId)

resolveChannelConfig
  :: ChannelId
  -> ChannelConfig
  -> Maybe Text             -- pre-fetched vault token (Telegram only)
  -> Either Text ResolvedChannel
```

Pure: takes a pre-fetched vault token (if any) rather than a `VaultHandle`,
so it is unit-testable without vault I/O. The caller (`forkOne`) does the
`vhGet` and passes the result here. This matches the existing pure
`resolveTelegramConfig`/`resolveSignalConfig` pattern.

- **Signal**: delegates to `resolveSignalConfig (Just (signalConfigFromChannel cc)) Nothing`
  — no vault (account is in `ccAccount`). Fails if `ccAccount` is unset.
- **Telegram**: `mVaultToken` (pre-fetched by the caller via
  `vhGet (telegramVaultKeyFor cid)`) takes precedence; if absent, falls
  back to `ccToken` (the config-level token, preserved from legacy
  `tcToken`); if both absent, fails. Then delegates to
  `resolveTelegramConfig (Just (telegramConfigFromChannel cc)) mVaultToken`.

`seal serve` replaces the two single-fork functions with one iteration:

```haskell
forkChatChannels :: ... -> RuntimeConfig -> Maybe VaultHandle -> WatchState -> IO ()
forkChatChannels logger gwCfg mgr cfg mHandle watchState =
  Map.traverseWithKey forkOne (rcChannels cfg) >> pure ()
  where
    forkOne chanId chanCfg = do
      -- Pre-fetch the vault token for Telegram channels (IO), then call
      -- the pure resolver. Signal channels pass Nothing.
      mVaultToken <- case (ccKind chanCfg, mHandle) of
        (Telegram, Just vh) -> do
          r <- vhGet vh (telegramVaultKeyFor chanId)
          pure (case r of Right bs -> Just (TE.decodeUtf8 bs); _ -> Nothing)
        _ -> pure Nothing
      case resolveChannelConfig chanId chanCfg mVaultToken of
        Left err -> logIO logger WarningS ("channel " <> ls (channelIdText chanId) <> ": " <> ls err)
        Right resolved -> void (forkIO (forkResolvedChannel logger gwCfg mgr chanId resolved watchState))
```

**`forkResolvedChannel`** requires extracting the post-resolution body from
the existing monolithic `forkNewSignalChatChannel` / `forkNewTelegramChatChannel`
(which currently resolve internally). The resolution is moved to
`resolveChannelConfig`; the fork functions keep only the transport +
register + `withSignalChatChannel`/`withTelegramChatChannel` body, accepting
a `ResolvedChannel`. The existing `withSignalChatChannel` /
`withTelegramChatChannel` library functions are reused unchanged.

### 3.6 Gateway API — new routes

Four new `SealRoute` constructors in `Route.hs`:

```haskell
RouteChannelsList   :: SealRoute '[] '[] Bodyless Resp
RouteChannelCreate  :: SealRoute '[] '[] (Body Req) Resp
RouteChannelUpdate  :: SealRoute '[Text] '[] (Body Req) Resp
RouteChannelDelete  :: SealRoute '[Text] '[] Bodyless Resp
```

`routeMeta` arms + `allRoutes` entries (4 added, count 62→66). OpenAPI arms
in `OpenApi.hs` mirror these.

**Manual router dispatch** (`API.hs`): four manual
`(method, pathInfo)` arms must be added alongside the trasa constructors,
mirroring the providers block:
- `("GET", ["api","channels"])` → `handleChannelsList`
- `("POST", ["api","channels"])` → `handleChannelCreate`
- `("PUT", ["api","channels", cid])` → `handleChannelUpdate`
- `("DELETE", ["api","channels", cid])` → `handleChannelDelete`

### 3.7 Gateway API — handlers (`API.hs`)

**`GET /api/channels`** → `handleChannelsList`:
- Load config, migrate, return JSON array of channel detail objects.
- **Response wire keys are camelCase** (matching `ProviderDetail` 1:1):
  `{ id, kind, label, account, textChunkLimit, allowFrom, authStatus }`
  where `authStatus` is `"configured"` / `"missing-credential"` /
  `"vault-locked"` (probes vault for Telegram tokens; Signal is
  `"configured"` if `ccAccount` is set, else `"missing-credential"`).

**`POST /api/channels`** → `handleChannelCreate`:
- **Input wire keys are snake_case** (matching `ProviderInput` 1:1):
  `{ id, kind, label?, account?, token?, text_chunk_limit?, allow_from? }`
- Validates `id` via `mkChannelId` (non-empty, no leading dash,
  `[A-Za-z0-9_-]`). Rejects if id already exists (409).
- Validates `kind` is `"signal"` or `"telegram"` (400 otherwise).
- For Telegram: stores `token` in vault under `telegramVaultKeyFor id`.
- Inserts into `rcChannels` via `updateRuntimeConfig`. Returns 201 + detail.

**`PUT /api/channels/:id`** → `handleChannelUpdate`:
- **Input wire keys are snake_case**:
  `{ label?, account?, token?, text_chunk_limit?, allow_from? }`
  (all optional — only provided fields are updated; `kind` is immutable).
- For Telegram: if `token` present, rotates the vault key.
- Updates the map entry. Returns 200 + detail. 404 if id not found.

**`DELETE /api/channels/:id`** → `handleChannelDelete`:
- Removes from `rcChannels`. Deletes the vault key (Telegram). Returns 204
  (idempotent — missing id is not an error, matching provider delete).
- **If the deleted id is a legacy default** (`"signal"` / `"telegram"`),
  nullifies the corresponding legacy field (`rcSignal = Nothing` /
  `rcTelegram = Nothing`) in the same transaction (§3.3 respawn prevention).

All handlers use `updateRuntimeConfig` (the existing lock-serialized
load-modify-save) for writes — no new concurrency concerns.

### 3.8 Frontend — `ChannelsView.tsx`

New component modeled on `ProvidersView.tsx`:

- **List pane** (left): all channels with a kind badge (text label "Signal"
  / "Telegram") + label. "+" button to add. Click to edit.
- **Editor pane** (right): form fields —
  - `kind` (select: Signal / Telegram) — only settable on create.
  - `id` (text) — only settable on create (the URL key). Client-side
    pre-validation: disable Save when id contains chars outside
    `[A-Za-z0-9_-]` or has a leading dash.
  - `label` (text, optional).
  - `account` (text) — Signal only; shown/hidden by kind.
  - `token` (password, write-only) — Telegram only; never pre-filled.
  - `text_chunk_limit` (number, optional).
  - `allow_from` (comma-separated text → array on submit:
    `value.split(',').map(s => s.trim()).filter(Boolean)`).
- Save / Cancel / Delete buttons (delete with confirm, matching
  ProvidersView's `confirmingDelete` pattern).
- **Restart-needed notice**: after any successful mutation (create/update/
  delete), display a banner: "Channel configuration saved. Restart
  `seal serve` for the change to take effect on running listeners."

**Empty/loading/error states** (matching ProvidersView):
- `"Loading…"` while `!loaded`.
- `"Failed to load — the backend may be unreachable."` on error.
- `"No channels configured."` on empty list.
- `"Select a channel to edit, or click + to add one."` as the empty-editor
  placeholder.

### 3.9 Frontend — navigation + types + hooks

- `TopBar.tsx`: add `'channels'` to `TopSection` + `SECTION_LABELS`
  (`channels: 'Channels'`).
- `App.tsx`: add `/channels` to `sectionFromPath` / `pathFromSection`;
  render `<ChannelsView />` when `section === 'channels'`.
- `types.ts`:
  - `ChannelDetail` (`{ id, kind, label, account, textChunkLimit, allowFrom,
    authStatus }`) — camelCase, matches the response wire 1:1 (no mapping
    function needed, like `ProviderDetail`).
  - `ChannelAuthStatus = 'configured' | 'missing-credential' | 'vault-locked'`.
  - `ChannelInput` — used for create. **Wire keys are snake_case** for the
    request body, matching `ProviderInput` 1:1:
    `{ id, kind, label?, account?, token?, text_chunk_limit?, allow_from? }`.
  - `ChannelUpdateInput` (same without `id`/`kind`):
    `{ label?, account?, token?, text_chunk_limit?, allow_from? }`.
  - `ChannelMutationResult = { ok: true; channel: ChannelDetail } | { ok:
    false; error: string }`.
- `useApi.ts`:
  - `useChannels()` — fetches `GET /api/channels` on mount + `refresh()`
    after mutations (NOT polling — matches `useAllProviders`; channel
    config changes only via this UI).
  - `createChannel(input)`, `updateChannel(id, input)`, `deleteChannel(id)`
    — return `ChannelMutationResult` / `boolean`.

## 4. Security Considerations

- **Telegram tokens** stay in the vault (for web-UI-created channels),
  never in `config.toml`, never returned by `GET /api/channels`. The
  `token` field in `POST`/`PUT` is write-only (frontend `type="password"`,
  never pre-filled) — same pattern as provider API keys. The legacy
  config-level token (`ccToken`, from `tcToken`) is a migration affordance
  only; new channels use the vault exclusively.
- **ChannelId validated newtype**: `mkChannelId` (non-empty, no leading
  dash, `[A-Za-z0-9_-]` charset) used at trust boundaries (POST body, URL
  capture, TOML key decode via `keyChannelIdBiMap`) — constructor exported
  for trusted internal literals, mirroring `RepoId`/`SignalAccount`/
  `TelegramToken`. The same validated `ChannelId` guards the vault-key
  string (`TELEGRAM_BOT_TOKEN_<id>`), the TOML map key
  (via `keyChannelIdBiMap`), the URL capture, and the POST body. No raw
  `Text` id reaches a vault key or argv.
- **Kind restriction**: the codec rejects `cli`/`web`/`background`/`other`
  at decode time — invalid channel kinds never reach `ResolvedChannel`.
- **No new shell-wrapping**: handlers use `updateRuntimeConfig` (native
  file I/O) and `vhPut`/`vhDelete` (vault) — no subprocess construction.
- **`~/.seal/` untouched**: no handler reads/writes under `~/.seal/`.
  Config is at the operator-chosen `config.toml` path.
- **Allow-list** unchanged: each channel's `ccAllowFrom` resolves through
  the existing `mapAllowUserId` → `mkUserId` validation.
- **Inherited posture (not a regression)**: CORS `*` wildcard, no gateway
  auth, no rate limiting — acceptable for the documented loopback
  single-operator model; becomes high-risk if the gateway is ever exposed.

## 5. File Scope

### Backend (Haskell)
| File | Change |
|---|---|
| `src/Seal/Channels/Config.hs` | **NEW** — `ChannelId` newtype + `mkChannelId`, `ChannelConfig`, `ResolvedChannel`, restricted kind codec, `keyChannelIdBiMap`, `resolveChannelConfig`, `fromSignalConfig`/`fromTelegramConfig` helpers |
| `src/Seal/Core/AllowList.hs` | Export `allowListCodec` (consolidate from Signal/Telegram/Channels) |
| `src/Seal/Signal/Config.hs` | Import `allowListCodec` from `Seal.Core.AllowList` (remove local copy) |
| `src/Seal/Telegram/Config.hs` | Import `allowListCodec` from `Seal.Core.AllowList` (remove local copy) |
| `src/Seal/Config/File.hs` | Add `rcChannels` field + codec line + `normalizeChannelsTable` + `migrateLegacyChannels`; add `upsertChannel`/`deleteChannel` helpers; update `defaultRuntimeConfig` |
| `src/Seal/Command/Serve.hs` | Replace `forkNewSignalChatChannel` + `forkNewTelegramChatChannel` with `forkChatChannels` iteration; extract `forkResolvedChannel` |
| `src-gateway-types/Seal/Gateway/Types/Route.hs` | Add 4 route constructors + `routeMeta` arms + `allRoutes` entries (count 62→66) |
| `src/Seal/Gateway/OpenApi.hs` | Add 4 OpenAPI arms |
| `src/Seal/Gateway/API.hs` | Add 4 manual dispatch arms + 4 handlers + `channelDetailJson` helper |
| `seal-harness.cabal` | Add `Seal.Channels.Config` to exposed-modules |

### Frontend (TS/React)
| File | Change |
|---|---|
| `frontend/src/components/ChannelsView.tsx` | **NEW** — CRUD view |
| `frontend/src/components/TopBar.tsx` | Add `'channels'` section |
| `frontend/src/App.tsx` | Add routing for `/channels` |
| `frontend/src/types.ts` | Add `ChannelDetail`, `ChannelAuthStatus`, `ChannelInput`, `ChannelUpdateInput`, `ChannelMutationResult` |
| `frontend/src/hooks/useApi.ts` | Add `useChannels`, `createChannel`, `updateChannel`, `deleteChannel` |

### Tests
| File | Change |
|---|---|
| `test/Seal/Channels/ConfigSpec.hs` | **NEW** — `ChannelId` smart-constructor (charset, leading-dash, empty), codec round-trip (valid + invalid-kind rejection), `resolveChannelConfig` (Signal missing-account, Telegram vault-vs-config precedence), migration helpers |
| `test/Seal/Gateway/ApiRouteSpec.hs` | Update expected route count 62→66 + add channel route round-trip cases |
| `test/Seal/Config/FileSpec.hs` | Add `rcChannels = Map.empty` to `defaultRuntimeConfig` literal + "all Nothing" test; add `migrateLegacyChannels` test (per-id synthesis, coexistence, token preservation) |
| `test/Main.hs` | Wire new spec |
| `seal-harness.cabal` | Add test module to other-modules |
| `frontend/src/components/__tests__/ChannelsView.test.tsx` | **NEW** — render + CRUD interactions + restart-needed notice |

## 6. Work Units (for the plan)

Dependency graph: W1 → W2 → W3 → W4 (backend chain); W5 independent of W1–W4
(can mock the API); W6 depends on W3 + W5.

- **W1**: `Seal.Channels.Config` — `ChannelId` newtype + `ChannelConfig` +
  restricted kind codec + `keyChannelIdBiMap` + `resolveChannelConfig` +
  `allowListCodec` consolidation (backend, TDD)
- **W2**: Wire `rcChannels` into `RuntimeConfig` + `normalizeChannelsTable`
  + `migrateLegacyChannels` in `File.hs` + `upsertChannel`/`deleteChannel`
  helpers (backend, TDD)
- **W3**: Gateway routes + OpenAPI + manual dispatch + handlers (backend, TDD)
- **W4**: `seal serve` — `forkChatChannels` iteration + `forkResolvedChannel`
  extraction (backend)
- **W5**: Frontend — `ChannelsView` + TopBar + App routing + types + hooks (TDD)
- **W6**: Integration smoke test — end-to-end channel CRUD via API
