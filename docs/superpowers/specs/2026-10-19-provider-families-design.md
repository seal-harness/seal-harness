# Design: Provider families — generic OpenAI API + OpenRouter preset

Status: draft — revision 4 (design gate round 4; PM + security approved rev 3)
Issue: #271, step 3 (follow-up)
Branch: `provider/openai-compat-271`
Builds on: `2026-10-19-openai-compat-provider-design.md`,
`2026-10-19-provider-instances-design.md`

## 0. Release status

The repository is **unreleased**: no version tags, `seal-harness.cabal` is
`version: 0.1.0.0`, and every CHANGELOG section is unreleased. No provider
feature has shipped. The user has confirmed **no backwards-compatibility
requirements**. `legacyTypeIds` survives only as a development-config courtesy;
the #271 rename migration is deleted; a dev config on `openai-compat` becomes a
visible problem row (manual fix + orphaned-key note in the CHANGELOG).

## 1. Terminology (glossary)

| term | Haskell | config / wire | meaning |
|---|---|---|---|
| **provider family / API** | `ProviderFamily` | `family` (wire slug, **derived, not config**) | the wire protocol; never fixes a URL |
| **provider** | `ProviderType` | `type` (id) | a built-in: family + base-URL policy + presentation |
| **instance** | `ProviderInstance` | `[providers.<name>]`, `name` | the operator's named configuration |
| **row** | `ProviderInstance` | one list item | an instance rendered by the CLI/API/UI |

`ProviderType` keeps its name to avoid colliding with the `Provider` typeclass
in `Seal.Providers.Class`. "Provider API" = "provider family". The family is
**not** a config key: `type` names the provider and the family is derived.

## 2. Problem

`ProviderType` conflates the **wire protocol** and a **concrete endpoint**. The
user asked for two levels: a **Provider Family / Provider API** that never fixes
a base URL (so adding one requires the URL), and **Providers** that combine a
family with a base-URL policy — a generic **OpenAI API** provider on the
existing OpenAI-compatible code (URL required), and an **OpenRouter** provider
that uses the OpenAI API with the OpenRouter URL fixed.

## 3. Use cases and success metrics

| # | WHO | WANTS | SO THAT | WHEN |
|---|-----|-------|---------|------|
| U1 | local OpenAI-compatible server operator | the OpenAI wire API with no fixed endpoint | I set my URL and run keyless **unless I store a key** | `/provider add openai` |
| U2 | OpenRouter user | endpoint + default model pre-filled | I never look up the URL | `/provider add openrouter` |
| U3 | maintainer adding an OpenAI-family vendor | one catalog row | transport/CLI/gateway need no change | a new row |
| U4 | web user | "OpenAI API" and "OpenRouter" distinct | I pick the right endpoint | Providers view |
| U5 | operator behind a proxy | a generic `openai` instance with an overridable URL | my proxy works | CLI / Providers view |
| U6 | operator deleting an instance | the dialog names the exact vault key(s) | I know what is destroyed | Providers view |

**Metrics (falsifiable, asserted)**

- **M1** `openrouter` resolves to `https://openrouter.ai/api/v1` and
  `OPENROUTER_API_KEY`; a stored `base_url` is ignored.
- **M2** `openai` requires a base URL; a key is **optional** — a stored
  `OPENAI_API_KEY` is sent as `Bearer` when present, and the row resolves
  keyless otherwise.
- **M3** `familyKey (providerFamily row) == "openai"` for both `openai` and
  `openrouter`; an `openrouter` instance resolves to an OpenAI-compatible
  transport whose URL is the fixed one (behavioural pair: `openai` refuses to
  resolve without a URL, `openrouter` resolves with a stale `base_url` present).
- **M4** a future OpenAI-family vendor is one catalog row: no change to
  `OpenAICompat.hs`, the CLI or the gateway; frontend **labels** need no change
  (they come from `typeDisplayName` on the wire) — a badge icon is optional.
- **M5** `/api/providers` returns four distinct built-in rows whose
  `typeDisplayName` includes "OpenAI API" and "OpenRouter";
  `/api/providers/all` reports `baseUrlRequired: true` for `openai`,
  `false` for `openrouter`, and `familyDisplayName: "OpenAI API"` on both.
- **M6** the delete-confirmation payload carries the real vault key name(s):
  built-in `openai` → `OPENAI_API_KEY`, built-in `openrouter` →
  `OPENROUTER_API_KEY`; a named instance (`work`, `openrouter work`) →
  `PROVIDER_APIKEY_*`.

## 4. Model

### 4.1 Provider family (the API)

```haskell
data ProviderFamily
  = AnthropicFamily | OllamaFamily | OpenAIFamily
  deriving stock (Eq, Show)

providerFamily :: ProviderType -> ProviderFamily
familyKey   :: ProviderFamily -> Text   -- "anthropic" | "ollama" | "openai"
familyLabel :: ProviderFamily -> Text   -- "Anthropic API" | "Ollama API" | "OpenAI API"

-- Total helper for the OpenAI transport spec (Nothing ⇒ not an OpenAI row).
openAICompatSpecFor :: ProviderType -> Maybe OpenAICompatSpec
openAICompatSpecFor (OpenAICompatType s) = Just s
openAICompatSpecFor _                    = Nothing
```

The family is payload-free, so `providerFamily` of the `openai` and `openrouter`
rows is the **same value** (`OpenAIFamily`). The OpenAI branch of dispatch
obtains its transport spec through `openAICompatSpecFor`; the `Nothing` arm is
defensive (unreachable for the built-in catalog) and returns the misconfigured
message. `familyLabel OpenAIFamily == "OpenAI API"` equals the generic row's
`ocsDisplayName`; the UI hides the family row when
`familyDisplayName == typeDisplayName` (so `openai` shows one string, not two).

`providerFamily` is the **transport dispatch key**. Anthropic OAuth, Ollama's
url-dependent key policy and vault-key derivation stay constructor-based by
design — capabilities of the concrete row, not of the protocol.

### 4.2 Base-URL policy

Moved wholesale into `Seal.Providers.Registry` **in WU-1** (the gateway's
`baseUrlPolicyFor` / `UrlFixed|UrlDefault|UrlRequired` ADT is deleted in the
same unit, so two same-named types never coexist):

```haskell
data BaseUrlPolicy
  = BaseUrlFixed !Text | BaseUrlDefaulted !Text | BaseUrlRequired

providerBaseUrlPolicy :: ProviderType -> BaseUrlPolicy
```

| policy | required | editable | default | stored `base_url` |
|---|---|---|---|---|
| `BaseUrlFixed u` | `false` | `false` | `Just u` | ignored |
| `BaseUrlDefaulted d` | `false` | `true` | `Just d` | validated at **write**; used **verbatim** at resolve (today's Ollama) |
| `BaseUrlRequired` | `true` | `true` | `Nothing` | validated at write and resolve |

`providerBaseUrlForInstance` derives from the policy. The gateway's
`typeUrlRequired`/`typeUrlEditable`/`typeDefaultBaseUrl` become one-line
projections of `providerBaseUrlPolicy`, and `validateInstanceWrite` switches on
the policy (all in WU-1). `baseUrlRequired`/`baseUrlEditable`/`defaultBaseUrl`
keep `<$> piType` null propagation for problem rows.

`shownBaseUrlOf` (editor display) derives from the policy **without changing
today's output**:

```haskell
Just t  -> case providerBaseUrlPolicy t of
  BaseUrlFixed u     -> Just u
  BaseUrlDefaulted _ -> providerBaseUrl cfg (piName inst)  -- stored only; may be Nothing
  BaseUrlRequired    -> providerBaseUrl cfg (piName inst)  -- raw, unvalidated
Nothing -> providerBaseUrl cfg (piName inst)               -- problem row (today's fallback)
```

The `BaseUrlDefaulted` asymmetry (display shows stored-only while resolution
returns the default) is load-bearing: do not "simplify" it to
`providerBaseUrlForInstance` or Ollama's field pre-fills with localhost.

Anthropic's `defaultBaseUrl` changes `null` → `Just "https://api.anthropic.com"`
(a new ApiSpec assertion pins it; no existing test does).

### 4.3 Catalog

The catalog stays **one list**, derived into `providerTypes`:

```haskell
openAICompatSpecs = [genericOpenAI, openRouter]        -- renamed from [genericOpenAICompat]
providerTypes = [AnthropicType, OllamaType] <> map OpenAICompatType openAICompatSpecs
```

| id | display | family | base URL | key | default model |
|---|---|---|---|---|---|
| `anthropic` | Anthropic | Anthropic | fixed `https://api.anthropic.com` | required (key or OAuth) | `claude-opus-4-8` |
| `ollama` | Ollama | Ollama | defaulted `http://localhost:11434` | url-dependent | `llama3.2` |
| `openai` | **OpenAI API** | OpenAI | **required** | optional | none |
| `openrouter` | **OpenRouter** | OpenAI | **fixed** `https://openrouter.ai/api/v1` | required | `deepseek/deepseek-v4.1-flash-1017` |

```haskell
genericOpenAI = OpenAICompatSpec
  { ocsId = "openai", ocsDisplayName = "OpenAI API"
  , ocsVaultKey = "OPENAI_API_KEY", ocsBuiltinBaseUrl = Nothing
  , ocsDefaultModel = Nothing, ocsKeyRequired = False
  , ocsModels = [], ocsExtraHeaders = [] }

openRouter = OpenAICompatSpec
  { ocsId = "openrouter", ocsDisplayName = "OpenRouter"
  , ocsVaultKey = "OPENROUTER_API_KEY"
  , ocsBuiltinBaseUrl = Just openRouterBaseUrl
  , ocsDefaultModel = Just (ModelId openRouterDefaultModel)
  , ocsKeyRequired = True
  , ocsModels = []
  , ocsExtraHeaders = [("HTTP-Referer", "https://github.com/seal-harness/seal-harness")
                      , ("X-Title", "Seal")] }
```

`openRouterBaseUrl`/`openRouterDefaultModel` replace the `legacyOpenRouter*`
constants (same values). A second fixed instance (`openrouter work`) is allowed
and is a distinct credential slot for the same endpoint — intended.

**Default model:** new `providerTypeDefaultModel :: ProviderType -> Maybe ModelId`
(avoids the imported `Seal.Config.File.providerDefaultModel`). Replacement
ownership: WU-1 replaces the inline case in `Registry.resolveDefaultModelFor`
(the File accessor stays for the instance's own override); WU-2 replaces
`Command.Model.defaultModelForType`; WU-3 replaces `Gateway.API.typeDefaultModel`.
`Command.Provider.addPlanFor` already reads `ocsDefaultModel` from the spec and
is unchanged. `staticModelsForType` keeps its lists (non-goal).

### 4.4 Dispatch

```haskell
case providerFamily t of
  AnthropicFamily -> resolveAnthropicInstance ...
  OllamaFamily    -> resolveOllamaInstance ...
  OpenAIFamily    -> case openAICompatSpecFor t of
    Just spec -> resolveOpenAIInstance ... spec
    Nothing   -> pure (Left (misconfiguredMsg inst))   -- defensive, unreachable
```

## 5. Config, legacy ids, migration

- `type` holds a provider id. `legacyTypeIds = ["anthropic","ollama","openrouter"]`.
  `openai` stays **out** so a dormant hand-written `[providers.openai]
  base_url=…` cannot silently activate as a repointable instance.
- **`handleProviderUpdate` must persist `pcType`** when it creates a section for
  a built-in row (today only the create path sets it). Without this, editing the
  implicit `openai` row would write a type-less `[providers.openai]` that
  reloads as a problem row and orphans the key just written. `type` is already
  immutable on update, so writing the canonical id is safe. Same for any future
  type. Add a test: `PUT {base_url, default_model}` on the implicit `openai` row
  leaves a resolvable row with `type = "openai"`.
- **Type-less message:** change "has no type and its name is not a provider
  type" to "has no type — add `type = \"<id>\"` or delete the section" so it is
  not false for `[providers.openai]`.
- **Delete** the #271 rename machinery: `providerRenameMigration`, `RenamePlan`,
  `renamePlan`, `applyRename`, `migratedMsg`, `couldNotUpdateMsg`, the calls in
  `Command.Serve` and `Tui`, and `MigrateSpec`'s `providerRenameSpec` **and**
  `spec = spec_main >> providerRenameSpec`. Dead imports to drop in
  `Migrate.hs`: `<|>`, `fromMaybe`, `isJust`, `updateRuntimeConfig`,
  `Data.Map.Strict`, the Registry import, and the now-unused `ProviderConfig`
  selectors. Dead imports to drop in `Serve.hs`/`Tui.hs`: `System.IO
  (hPutStrLn, stderr)` (only the deleted message print used them).
- **Delete `legacyProviderHint`** + export + 5 call sites (`Command.Provider`
  ×3, `Command.Model`, `Command.New`) + imports. Tests invert (see §10).
- Rename `genericOpenAICompat` → `genericOpenAI` (compile-forced in
  `ProviderSpec`).
- Problem rows, asserted: `[providers.openai-compat]` (no type, non-legacy);
  type-less `[providers.openai]`; `[providers.openai] type = "openrouter"` and
  `[providers.openrouter] type = "openai"` (mismatch; neither touches the other
  row's key). A persisted `provider = "openai-compat"` in `session.json` /
  UI-state `last_options` fails closed as an unknown instance (test), never
  silently falls back to `rcDefaultProvider`.
- Fix the pre-existing mismatch copy ("not a <type> instance" → "not an instance
  of <type>").

## 6. CLI

`addPlanFor` is already generic over `OpenAICompatType spec`, so §6's table
needs **no new production code**:

| id | base URL prompt | key prompt | model |
|---|---|---|---|
| `anthropic` | none | required | built in |
| `ollama` | optional (default) | optional | built in |
| `openai` | **required** | optional | prompted |
| `openrouter` | none (fixed) | required | built in |

The **only** new RED in the CLI area is
`addPlanFor (OpenAICompatType openRouter) == AddPlan NoBaseUrl RequiredKey
(Just (ModelId openRouterDefaultModel))` (the existing four tests already cover
anthropic/ollama/generic/`presetSpec`). `typeArg`'s help already derives from
`providerTypes`; add an assertion. The `RequiredBaseUrl` prompt should mention
`https://api.openai.com/v1` as the canonical example (still not a default).

## 7. Gateway API

- `/api/providers` (summary) gains `family` + `familyDisplayName` only.
- `/api/providers/all` (detail) gains `family`, `familyDisplayName`,
  `apiKeyName`, `oauthKeyName`.
- Null contracts: `family`/`familyDisplayName` are `null` when `piType` is
  `Nothing`; `apiKeyName` is `null` **exactly when `problem` is non-null**;
  `oauthKeyName` is non-null **only for a problem-free anthropic-typed row**.
  Key names are values-free (`ProviderCredentials` holds `Text` names).
- Flags derive from `providerBaseUrlPolicy`; `shownBaseUrlOf` per §4.2.
- `keyOptional`/`typeKeyOptional` stay constructor-based (it already reads
  `ocsKeyRequired` for OpenAI rows — `openai` optional, `openrouter` required).
- Mutation: `base_url` on `BaseUrlFixed` is accepted-and-ignored (`PUT` leaves
  the section unchanged); `BaseUrlRequired` validates/presents-required;
  `BaseUrlDefaulted` accepts. `handleProviderUpdate` writes `pcType` per §5.
- Problem-row deletes keep the existing "fix or delete the section; `/vault
  delete` anything stored manually" copy.

## 8. Frontend

- Label maps: relabel `openai` **in place** in `NewSessionComposer`,
  `NewTabComposer`, `AgentsView` (they already have an `openai` key) and add it
  in `ProvidersView`; remove `openai-compat`; add `openrouter`. Labels are
  fallbacks — `typeDisplayName` is authoritative.
- `ActiveTabs`: replace `openai-compat` with `openai`, keep the OpenRouter icon.
  Rule: `?` iff neither `providerType` nor the instance name matches the badge
  map.
- `ProvidersView`: **delete the client-side `apiKeyNameFor`** (the hardcoded
  legacy map) and use the server's `apiKeyName`/`oauthKeyName`; name both keys
  when `oauthKeyName` is non-null; fall back to generic copy when a field is
  absent (older payload/mocks), never `undefined`. Detail pane shows "API
  family", hidden when `familyDisplayName == typeDisplayName`.
- TS types: `family?: string | null`, `familyDisplayName?: string | null`,
  `apiKeyName?: string | null`, `oauthKeyName?: string | null` on
  `ProviderDetail`; `family`/`familyDisplayName` on `ProviderInfo`.
- Fixtures: `ProvidersView.test.tsx` `makeProvider` (+ the `PROVIDER_APIKEY_WORK`
  delete assertion and the create-flow selector), `Sidebar.test.tsx` badge,
  the three composer labels, `NewTabComposer.test.tsx`'s `openrouter` fixture,
  and the Haskell-side literals listed in §10.

## 9. Security

- No new credential namespace, opcode, or `~/.seal/` write path. Deleting the
  rename migration removes a boot-time config rewrite.
- **OpenRouter is fixed:** a stored `base_url` is ignored, so a stored
  `OPENROUTER_API_KEY` cannot be repointed (asserted); the config-layer mirror
  `[providers.openrouter] type = "openai"` is a problem row and touches no key.
- **Generic `openai` is repointable:** `BaseUrlRequired` + `PUT {base_url}` keeps
  `OPENAI_API_KEY` on the unauthenticated, `ACAO: *` loopback surface
  (pre-existing #273 delta). **Accepted risk, recorded**: a test pins that a
  repoint reaches the stored key and that `DELETE /api/providers/openai` removes
  `OPENAI_API_KEY`; the deferred guard (rotate key / explicit confirmation) is
  TODO-tracked; the CHANGELOG warns about both repoint **and** destruction
  (the name may be shared with other tooling).
- **`catalogProblems` gains a pairwise vault-key check** across catalog rows,
  comparing `T.toLower . T.strip` and rejecting keys with surrounding
  whitespace (vault lookups are exact). Gate:
  `catalogProblems openAICompatSpecs == []` (no such assertion exists today).
  The built-in id list `["anthropic","ollama"]` and `legacyReservedKeys` remain
  hardcoded; deriving both from `providerTypes` is a TODO follow-up.
- **Reserved headers:** `chatHeaders` drops (after trimming)
  `authorization`, `proxy-authorization`, `host`, `content-length`,
  `content-type`, `cookie`, `x-api-key`, `transfer-encoding`, `connection`,
  `te`, `trailer`, `upgrade`, `proxy-authenticate`, `content-encoding`; unit
  test. Assert no `ocsExtraHeaders` value contains CR/LF or a `Bearer ` prefix.
  The deny list is a single exported constant used by both `chatHeaders` and
  its test.
- **Plaintext-HTTP asymmetry** (CLI warns for a keyed non-private URL; the
  gateway does not) is pre-existing and out of scope.
- Orphaned secret: CHANGELOG tells the operator to
  `/vault delete OPENAI_COMPAT_API_KEY` and re-point `default_provider`.
- No new secret logging: `family`, `apiKeyName`, `oauthKeyName` are names.

## 10. Work units (TDD, RED first; each gate green)

**WU-1 — atomic model swap (largest; keeps `make check` green).**
`ProviderFamily`/`familyKey`/`familyLabel`/`openAICompatSpecFor`; `BaseUrlPolicy`
+ `providerBaseUrlPolicy` + deletion of the gateway ADT and repointing of
`validateInstanceWrite`/flag projections; `providerTypeDefaultModel` (Registry
copy); catalog rows + `genericOpenAI` rename; family dispatch; `legacyTypeIds`;
`handleProviderUpdate` writes `pcType`; type-less message; delete the rename
migration + `legacyProviderHint`; rename constants; `catalogProblems` pairwise
check; reserved-header constant; `addPlanFor openRouter` RED. Then the
**conversion table** for gate-blocking tests:
- `openai-compat` used as the generic target (`RegistrySpec`, `ProviderSpec`
  add/test/remove, `ModelSpec`, `ApiSpec` generic row, `NewSpec` model
  resolution) → `openai`;
- `openai-compat` used where a fixed URL/preset is meant → `openrouter`;
- `ApiSpec` row-count/`Map.keys` assertions → four ids; generic row
  `typeDisplayName` → "OpenAI API";
- `ProviderSpec.legacySpec`: the two hint tests rewrite to a genuinely unknown
  id (`openai-compat`) + four-id `known:` tail; `/provider default
  openai-compat` → `openai` (still "no default model"); `smProvider =
  "openrouter"` expects the openrouter row's built-in model;
- `NewSpec` `/new -p openrouter` → accepted (needs a working deps fixture, not
  the `ndPaths = error` stub); `resolveNewModel … 'openai' ''` stays empty;
- `MigrateSpec`: delete `providerRenameSpec` + its `spec` operand.
`FileSpec`/`NameSpec`/`OpenAICompatSpec`/`StoreSpec` literals that merely name
the id are cosmetic but updated for consistency; `StoreSpec`'s
`defaultSessionSelection "openai-compat"` becomes a genuinely unknown id.

**WU-2 — CLI + Model.** `Command.Model.defaultModelForType` → 
`providerTypeDefaultModel`; `typeArg` help assertion; `ProviderSpec`/`ModelSpec`
characterisation tests (the four-id `addPlanFor` tests already exist and pass).

**WU-3 — gateway.** `/api/providers` family fields; `/all` family + key-name
fields; mutation tests (fixed-URL ignore, required-URL validation, PUT-on-
implicit-`openai` persists `type`); Anthropic `defaultBaseUrl` pin; M5.

**WU-4 — frontend.** Labels, badges, TS types, detail family, delete copy from
`apiKeyName`/`oauthKeyName` (remove `apiKeyNameFor`), all fixtures. Gate:
`make check` (tsc) + `make frontend-test` (local; CI runs `cabal test` and
`nix build`, not vitest).

**WU-5 — docs.** Rewrite (not append) the CHANGELOG: remove the false
"openrouter → openai-compat" and "Next: presets" bullets; document the
`openai-compat` removal, the orphaned key, the repoint/destruction warning.
Update `TODO.md` (repoint guard, derived reserved keys/ids), the
`Command/Provider` header, `Config/File` `pcType` doc, `Name.hs` comment,
`frontend/src/types.ts:45` comment, `docs/plans/active-plan.md`,
`docs/context/execution-state.md`, and add "Superseded by" headers to the two
OpenAI-compat docs **and** the two `docs/plans/openrouter-provider-*` docs.

## 11. Non-goals

- A fixed `api.openai.com` preset (the generic `openai` row covers OpenAI with a
  typed URL; the user asked for the generic provider). The CLI prompt hints the
  canonical URL.
- Model discovery / a non-empty `ocsModels` for OpenRouter (a configured
  instance's `listModels` still includes its default model); the Providers
  create form may prefill the row's default model as a convenience.
- Renaming the `Provider` typeclass or the `pcType` config field.
- A repoint guard for `PUT {base_url}` (deferred, TODO-tracked).
- Deriving `legacyReservedKeys`/built-in ids, `staticModelsForType`
  unification, and any migration/continuity guarantee for the unreleased ids.

## 12. Revision 5 corrections (authoritative; supersedes §5, §7, §10 where they conflict)

Design-gate round 4: PM/security/architect approved; designer and CTO found one
more real writer bug and exact test-conversion gaps. All are adopted.

### 12.1 One section-creating upsert stamps `pcType`

Two writers currently create a section without `type`:
`Gateway.API.handleProviderUpdate` and `Command.Model.defaultCmd`
(`/model default <provider> <model>`). Either would turn the implicit `openai`
row into a type-less problem row and orphan `OPENAI_API_KEY`.

Fix the **class**, not the instances: add to `Seal.Config.File`
(no Registry import needed):

```haskell
upsertProviderForType :: Text -> Text -> (ProviderConfig -> ProviderConfig)
                      -> RuntimeConfig -> RuntimeConfig
--            canonical id   name     field update
```

It sets `pcType = Just canonicalId` on create **and** normalises a
mixed-case existing `type` on write. Every section-creating path uses it:
gateway `handleProviderCreate` / `handleProviderUpdate`, CLI `completeAdd`,
`Command.Model.defaultCmd` (and any other `upsertProvider` call that can create
a section). Add RED: `/model default openai <model>` and a gateway `PUT` on the
implicit `openai` row both leave a resolvable row with `type = "openai"`.

### 12.2 Exact WU-1 conversion table (additions)

- **Type-less-section fixtures must set `pcType`** (a bare id rename makes them
  problem rows): `ModelSpec.hs:351`, `ProviderSpec.hs:503/517/531`.
- **Vault-key literals** `OPENAI_COMPAT_API_KEY` → `OPENAI_API_KEY`:
  `ProviderSpec.hs:426/450/462`, `RegistrySpec.hs:234`,
  `ApiSpec.hs:5132` (the last stays green but is vacuous otherwise).
- **RegistrySpec structural assertions**: four-id lists at
  `106/110/116/125/184/186/379`; `legacyTypeIds` at `188` becomes
  `["anthropic","ollama","openrouter"]`; the type-less legacy fixture at
  `158-160` moves to `openrouter` (and keeps its positive assertion); the
  mismatch-copy assertion at `181` follows §5's "not an instance of <type>".
- **`openai-compat` as generic target** → `openai` elsewhere; **`openai-compat`
  where a fixed URL/preset is meant** → `openrouter`.
- **`ProviderSpec` `smProvider = "openrouter"`** asserts the session resolves
  through the OpenRouter row and the fixed URL is used (not a vacuous built-in
  model claim; `resolveSessionProvider` echoes `smModel`).
- **`StoreSpec.hs:103`** becomes `openai` (preserves "no default model"); add a
  separate genuinely-unknown-id test.
- **`FileSpec`** keeps a hyphenated *instance* name so the hyphen round-trip
  stays tested.
- **`ApiSpec:5132`** targets `OPENAI_API_KEY` so "a rejected request wrote no
  credential" keeps its teeth.

### 12.3 Dead imports (complete)

`Migrate.hs` also drops `RuntimeConfig (..)` (only the deleted block used it)
and the whole `ProviderConfig (..)` import. `MigrateSpec.hs` drops
`Data.Map.Strict`, `ProviderConfig (..)`, `providerBaseUrl`,
`providerDefaultModel` after `providerRenameSpec` goes. `Serve.hs`/`Tui.hs`
drop `System.IO (hPutStrLn, stderr)`.

### 12.4 Gateway surface (narrowed)

`/api/providers` (summary) does **not** gain family/key-name fields — it keeps
its current shape (four rows, `typeDisplayName`). Only `/api/providers/all`
gains `family`, `familyDisplayName`, `apiKeyName`, `oauthKeyName`. `family` is
`familyKey` (e.g. `"openai"`), asserted in M5. Key-name null contracts as §7.

### 12.5 Small corrections

- Example instance name `openrouter work` → **`openrouter-work`** (the grammar
  forbids spaces).
- **M4** reworded: adding a vendor row needs no `OpenAICompat.hs`, CLI or
  gateway change. The reserved-header constant (§9) is a one-time change in
  this design, not a per-vendor cost.
- Type-less problem message interpolates a known id:
  `has no type — add type = "openai" or delete the section`.
- Delete dialog adds one clause when the key name is vendor-conventional
  (`OPENAI_API_KEY`/`OPENROUTER_API_KEY`): the name may be shared with other
  tooling and this deletes it.
- `Registry` export additions: `ProviderFamily (..)`, `familyKey`,
  `familyLabel`, `openAICompatSpecFor`, `BaseUrlPolicy (..)`,
  `providerBaseUrlPolicy`, `providerTypeDefaultModel`, `genericOpenAI`,
  `openRouter`.
- WU-1 carries the `catalogProblems openAICompatSpecs == []` gate explicitly.
- WU-2's `typeArg` help assertion covers all four ids.
- WU-4 adds tests for: the "API family" row (hidden for `openai`, shown for
  `openrouter`), Anthropic's `defaultBaseUrl`, and the ActiveTabs badge title
  "OpenAI API".
- `defaultSessionSelection`'s unknown-id echo is out of scope; the fail-closed
  assertion lives on `resolveSessionProvider`.

## 13. Revision 6 — scope reductions (authoritative; supersedes §4.2, §4.3, §7, §8, §9, §10, §12 where they conflict)

The plan gate found the plan over-scoped relative to the four user clauses and
under-specified on test conversions. Adopted:

### 13.1 Cut (deferred, not required by any user clause)
- **No `BaseUrlPolicy` move.** The gateway's existing
  `baseUrlPolicyFor`/`UrlFixed|UrlDefault|UrlRequired` already derives fixed /
  required / defaulted from `ocsBuiltinBaseUrl`, so the two new rows work with
  no change. `providerBaseUrlPolicy` and the Anthropic `defaultBaseUrl`
  (`null → Just`) change are **dropped**.
- **No `providerTypeDefaultModel` unification.** `resolveDefaultModelFor`,
  `Command.Model.defaultModelForType` and `Gateway.API.typeDefaultModel`
  already read `ocsDefaultModel` for OpenAI-family rows; they stay.
- **No reserved-header deny-list extension.** Deferred (no new
  attacker-controlled header path; `ocsExtraHeaders` is compile-time catalog
  data). The existing four-name list is unchanged.
- **No mismatch-copy grammar fix.** Deferred.
- **No "API family" UI row / hide rule.** The family is exposed as
  `family`/`familyDisplayName` on `/api/providers/all` only; the UI does not
  render it.

### 13.2 Keep but change
- **`legacyProviderHint` is re-pointed, not deleted.** It becomes
  `openai-compat → openai` (a repair path for dev configs the unreleased branch
  produced). The five call sites remain; the two tests that asserted the old
  `openrouter → openai-compat` text are rewritten. `openrouter` now resolves, so
  its hint branch is gone.
- **`catalogProblems` pairwise vault-key check** is kept (it protects the two
  near-identical `*_API_KEY` rows) and labeled as such.

### 13.3 Still in scope
Family model + dispatch (`ProviderFamily`, `familyKey`, `familyLabel`,
`openAICompatSpecFor`); two catalog rows; `legacyTypeIds`; delete the #271
rename migration; re-point the hint; `upsertProviderForType` (all section
creators stamp `pcType`); server-side `apiKeyName`/`oauthKeyName` on `/all`
(+ delete the client `apiKeyNameFor`); `family`/`familyDisplayName` on `/all`;
frontend labels/badges/TS/delete copy; `RequiredBaseUrl` prompt example;
fail-closed `resolveSessionProvider` test; docs/CHANGELOG/TODO.

### 13.4 Additional conversions the plan must carry
- `ProviderSpec.hs:605/606/689` assert `"(OpenAI-compatible)"` → `"OpenAI API"`.
- `RegistrySpec.hs:107/108/111/112` parallel boolean/Maybe lists grow to four
  rows.
- `ApiSpec.hs:3860/3864` POST `type = "openai-compat"` → `openai`.
- `MigrateSpec.hs` also drops the `RuntimeConfig (..)` import (dead once
  `providerRenameSpec` goes).
- Export `openRouterBaseUrl`/`openRouterDefaultModel` (tests import them).
- RED "`instanceAuthStatus` is keyless" is scoped to a configured `openai`
  instance (with a base URL); the bare implicit row is `none`.
- WU-1's DoD is "no `openai-compat` **code/id** in `src/` or gate-blocking
  tests"; comment sweeps live in WU-5 (including `Gateway/API.hs:2249`).
