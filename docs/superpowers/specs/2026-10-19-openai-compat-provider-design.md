# Design: Generic OpenAI-compatible provider (rename `openrouter` → `openai-compat`)

Status: approved — revision 5 (rounds 1–3: 5/5 NEEDS_REVISION; dispositions in
§12–§13. The plan-review gate split the gateway hardening out of this PR: the
items marked **[deferred]** below are recorded in **§14** and ship separately.)
Issue: #271
Supersedes: `docs/plans/openrouter-provider-design.md`, `docs/plans/openrouter-provider-plan.md`

## 1. Problem

Seal's `openrouter` provider is not OpenRouter-specific: it speaks OpenAI's
`/chat/completions` wire format and takes a base URL from config. The name
undersells the capability (any OpenAI-compatible endpoint), hides a real
constraint (the base URL is optional only because a hardcoded OpenRouter default
fills the gap), and hard-fails without a key so keyless local servers (vLLM,
llama.cpp, LM Studio) cannot be used at all.

Tasks, in the issue's order:

1. Rename to `openai-compat`; the base URL becomes **required**.
2. Make adding further OpenAI-compatible providers (that supply a built-in base
   URL) a **catalog row** — same implementation, same code path, no frontend
   edit.
3. *(Later, out of scope)* Add `openai` and `openrouter` presets.

**Compatibility boundary:** *Bearer*-auth `/chat/completions` endpoints only.
Azure OpenAI (`api-key` header + `api-version` query) is not expressible in the
spec and is out of scope.

## 2. Use cases and metrics

| # | WHO | WANTS | SO THAT | WHEN |
|---|-----|-------|---------|------|
| U1 | Operator running local vLLM / llama.cpp / LM Studio / an Ollama OpenAI shim | to point Seal at `http://localhost:8000/v1` with no key and no vault | I can use models on my machine | `/provider add openai-compat` |
| U2 | Operator with a hosted OpenAI-compatible gateway | to enter URL + key once | Seal works with no code changes | same |
| U3 | Operator whose request fails | an error naming the provider and the repair, **on the surface they are looking at** | I don't read source | on any failure |
| U4 | Maintainer adding a vendor preset | one catalog row | I never touch transport, CLI, gateway, or frontend | when requested |
| U5 | Operator upgrading from `openrouter` | config migrated automatically, one manual step named | I'm not stranded | first boot |
| U6 | Operator editing a provider in the Providers view | required fields visibly required, Save blocked while empty, server reason inline | I can't save a config that cannot work | while editing |

**Metrics** (falsifiable by test or diffstat; no telemetry)

- **M1** A second preset is a diff touching exactly one file **under `src/`**
  and zero frontend files (`git diff --stat` at step 3); §11's dry-run test
  proves the code path.
- **M2** Each of the four legacy break paths emits its own message: WU-2b owns
  the session, agent-def and `new -p` assertions; WU-4 owns the config-migration
  one.
- **M3** A keyless local endpoint is fully usable with zero `/vault`
  interaction: add, list, test, **remove** (WU-5).
- **M4** The 404 message names the missing-API-path fix (WU-1b).

**Non-goals:** step 3 presets; Azure; streaming changes; `/v1/models`
discovery; validating Ollama's base URL; enabling `/provider add` from the web
chat (`ccPromptSecret` is fail-closed there).

## 3. Current state

- `src/Seal/Providers/OpenRouter.hs`: value (manager, `Maybe ApiKey`, base URL,
  model), pure `encodeRequest`/`decodeResponse`/`mapFinishReason`,
  `bearerHeaders`, `sendChatCompletion` (`parseRequest` **outside** `try`),
  `httpErrorText`, `instance Provider` (`listModels` → `[model]`; no model check;
  key required).
- `src/Seal/Providers/Registry.hs`: `KnownProvider = Anthropic | Ollama |
  OpenRouter` (`Enum`/`Bounded`), total mappings, `providerBaseUrlFor`,
  `resolveProvider`, `configuredProviders`, `credErr`/`vaultErrText` (which
  already distinguish `vault locked` from `not configured`).
- `src/Seal/Command/Provider.hs`: three label-keyed branches in `addCmd`, an
  OAuth guard in `loginCmd`, an `ollama` branch in `listCmd`, `removeCmd`
  deletes `ANTHROPIC_OAUTH_TOKENS` for **every** provider, `list`/`test`
  require a vault, `remove` requires a vault.
- `src/Seal/Gateway/API.hs`: `providerInfoJson` (name+configured only),
  `providerDetailJson`, `providerAuthStatus`, create/update (**vault written
  before validation**), `staticModelsFor`, `parseProviderModel` (substitutes
  `"llama3.2"` for any provider), CORS `*`, no REST auth.
- `src/Seal/Gateway/Server.hs`: documents loopback-only but calls
  `Warp.run` with `defaultSettings` (`settingsHost = *4` ⇒ **all interfaces**);
  `gcHost` only reaches a warning.
- `src/Seal/Config/Migrate.hs`: one boot-time idempotent fail-open migration
  (`migrateSecurityConfig`), called from `Serve.hs:112` and `Tui.hs:85`. It
  triggers on a **text scan** of `config.toml`; it is the only path that writes
  `security.toml` from legacy fields, and a `RuntimeConfig` re-encode drops
  keys the codec does not model.
- Frontend: `ProvidersView` (`isOllama`/`isKeyless` id branches), label maps in
  four components, `ActiveTabs` badges (`?`/"Unknown provider" fallback fed only
  a provider id), `useNewTabSpec` (model list → custom affordance; reads
  `defaultModel`/`isDefault` that the API never emits).

## 4. Design

### 4.1 One implementation, a data-driven catalog

- `src/Seal/Providers/OpenRouter.hs` → `src/Seal/Providers/OpenAICompat.hs`
- `OpenRouter` → `OpenAICompat`, `mkOpenRouter` → `mkOpenAICompat`
- fields: `oacSpec`, `oacApiKey`, `oacBaseUrl`, `oacModel` (the model this
  instance **advertises from `listModels`**; the request model is `crModel`),
  `oacManager`
- drop `defaultOpenRouterBaseUrl`, `bearerHeaders`; add `chatHeaders`,
  `validateBaseUrl`, `chatUrl`
- the module owns the spec *type* and the transport; no provider-specific
  `case` anywhere in it

```haskell
data OpenAICompatSpec = OpenAICompatSpec
  { ocsId             :: !Text       -- ^ provider id, e.g. "openai-compat"
  , ocsDisplayName    :: !Text       -- ^ human label, e.g. "OpenAI-compatible"
  , ocsVaultKey       :: !Text       -- ^ vault key holding the API key
  , ocsBuiltinBaseUrl :: !(Maybe Text)      -- ^ Nothing ⇒ the user supplies one
  , ocsDefaultModel   :: !(Maybe ModelId)   -- ^ Nothing ⇒ the user supplies one
  , ocsKeyRequired    :: !Bool              -- ^ False ⇒ keyless endpoints OK
  , ocsModels         :: ![ModelId]         -- ^ advertised catalogue ([] = none)
  , ocsExtraHeaders   :: ![(ByteString, ByteString)] -- ^ static vendor headers
  } deriving stock (Eq, Show)

openAICompatSpecs :: [OpenAICompatSpec]
openAICompatSpecs = [genericOpenAICompat]

genericOpenAICompat :: OpenAICompatSpec
genericOpenAICompat = OpenAICompatSpec
  { ocsId = "openai-compat", ocsDisplayName = "OpenAI-compatible"
  , ocsVaultKey = "OPENAI_COMPAT_API_KEY"
  , ocsBuiltinBaseUrl = Nothing, ocsDefaultModel = Nothing
  , ocsKeyRequired = False, ocsModels = [], ocsExtraHeaders = [] }

data KnownProvider = AnthropicProvider | OllamaProvider
                   | OpenAICompatProvider !OpenAICompatSpec
  deriving stock (Eq, Show)

knownProviders = [AnthropicProvider, OllamaProvider]
              <> map OpenAICompatProvider openAICompatSpecs
```

`Enum`/`Bounded` are dropped (verified: `knownProviders = [minBound .. maxBound]`
is their only use; `Eq`/`Show` are kept). `parseProvider` already looks labels up
over `knownProviders`. `openAICompatSpecs` and `genericOpenAICompat` are exported
for tests.

### 4.2 Copy rules (surface awareness)

1. Every message is templated on `<N>` = `providerDisplayName` and `<id>` =
   `providerLabel` (`providerDisplayName :: KnownProvider -> Text`).
2. **No string that can reach a browser may name a slash command as its only
   repair.** `/provider`, `/model`, `/vault` are `InteractiveOnly` and the web
   client has no command entry; `ccPromptSecret` is fail-closed in web sessions,
   so `/provider add` cannot be completed from the chat. Browser-reachable
   strings (REST bodies, transport/model/key errors written to the transcript)
   name the **Providers view** first and the slash command second.
3. **Layering of base-URL errors:** `validateBaseUrl` returns a short reason
   only (`"missing scheme"`, `"host required"`, …). `providerBaseUrlFor` builds
   `"<N> base URL is not usable (<reason>) — it must be an http(s) URL like
   https://host/v1"`. The CLI appends `"; run /provider add <id>"`; the REST 400
   body carries the same sentence plus `{"field": "base_url"}` and **no command
   tail** (the editor renders it inline and offers the field).
4. `vault locked` is **not** `vault not configured`: `credErr`/`vaultErrText`
   already say `/vault unlock` vs `/vault setup`, and the new code reuses them
   rather than flattening both into "run /vault setup" (which would walk a
   locked-vault user into a rekey).

### 4.3 Base URL: required, authoritative, validated

```haskell
providerBaseUrlFor :: RuntimeConfig -> KnownProvider -> Either Text Text
```

| provider | result |
|---|---|
| anthropic | `Right "https://api.anthropic.com"` (informational; endpoint hardcoded, field read-only) |
| ollama | configured `base_url`, else `defaultOllamaBaseUrl` — **unvalidated, unchanged** (§8.11) |
| family, `ocsBuiltinBaseUrl = Just u` | `Right u`; a config `base_url` is **ignored** (the preset URL is authoritative) |
| family, `Nothing` | configured `base_url`, validated; `Left` when missing/invalid |

```haskell
validateBaseUrl :: Text -> Either Text Text  -- Left = short reason (§4.2)
chatUrl         :: Text -> Text              -- canonical base → base <> "/chat/completions"
```

| input | result |
|---|---|
| `https://h/v1`, `http://localhost:8000/v1`, `http://192.168.1.10:11434` | `Right` |
| `HTTPS://Host/v1` | `Right "https://Host/v1"` — **only the scheme is lowercased** (http-client's parser is case-sensitive) |
| `http://[::1]:8000/v1` | `Right` (IPv6 literals allowed) |
| `  https://h/v1//  ` | `Right "https://h/v1"` (whitespace stripped, **all** trailing `/` collapsed) |
| `""`, `"   "`, `"\t"` | `Left "empty"` |
| `h/v1`, `//h/v1`, `http:/h`, `ftp://h/v1`, `file:///v1`, `ws://h` | `Left "scheme must be http or https"` |
| `https://`, `http://:8000/v1` | `Left "host required"` |
| `https://user:pw@h/v1`, `https://user@h/v1` | `Left "userinfo is not allowed"` |
| `https://h/v1\r\nHost: evil`, embedded space/tab | `Left "whitespace or control characters"` |
| `https://h:99999/v1` | `Left "port out of range"` |
| `https://h/v1?x=1`, `https://h/v1#f` | `Left "query or fragment is not allowed"` |

The metadata/SSRF denylist is **deferred** (§14) to the security PR that owns
`Seal.Web.UrlSafety`; a textual denylist is not a control, and shipping half of
one here would imply a guarantee this PR does not make. `isSafeUrl` (DNS-based)
is not used either, because U1 requires loopback/private hosts.

Properties (bounded generators: alphabet `{a,z,0,9,':','/','@','.','-','[',']','\r','\n',' ','?','%'}`, length ≤ 60):
every `Right u` has no whitespace/control char and no `@` before the first `/`;
`validateBaseUrl` is idempotent on its own output; `chatUrl` never yields
`//chat/completions` and always ends in exactly one `/chat/completions`.

`/v1` is **not** auto-appended (endpoints vary). The prompt, the UI hint, and
the 404 message say what to enter.

### 4.4 Model

```haskell
defaultModelFor     :: KnownProvider -> Maybe ModelId
resolveDefaultModel :: Maybe Text -> Text -> Maybe ModelId
```

- `resolveDefaultModel (Just "") _ = Nothing`; unknown label keeps
  `Just (ModelId "claude-opus-4-8")` (existing test preserved).
- Seeding never writes an empty model (implicit seed skipped when
  `defaultModelFor == Nothing`); a model the user **supplies** (CLI prompt,
  `default_model` in the request) is written.
- **A model is required to complete, enforced once, in `complete`, on
  `crModel`** (the value that reaches the wire). `/provider test` on a
  model-less provider therefore reports the message and makes **no** network
  call (a `GET <base>/models` probe is a follow-up).
- `listModels` for the family = `nub (ocsModels spec <> [oacModel | non-empty])`.
  `/model list` passes the **resolved** default model so a configured id is what
  `listModels` reports.
- **Empty inherited models are repaired:** `Seal.Command.New` falls back to
  `resolveDefaultModel` for the target provider when the inherited/selected
  model is empty (today it copies `smModel` verbatim, so a model-less family
  session followed by `new -p anthropic` would send `model: ""` to Anthropic,
  which has no empty-model guard).

| site | behaviour when `Nothing` / empty |
|---|---|
| `Session.Store.defaultSessionSelection` | `smModel = ""` (unless the global `default_model` is set — unchanged precedence) |
| `Command.New` (inherit/`-p`) | empty ⇒ `resolveDefaultModel` for the target provider, else `""` |
| `Command.Provider.seedProviderDefaults` | skip seeding |
| `Command.Provider.defaultCmd` | `default provider set to <id> (no default model — set one with /model use <id> <model-id>)` |
| `Command.Provider.testCmd` | §6 no-model message, no network |
| `Command.Model.useCmd` (no model arg) | §6 no-model message; **session unchanged** |
| `Command.Model.reportProviderQuiet` | prints `<id> (default model: none — set one with /model use <id> <model-id>)` **only** on the existing fallback branch (empty/failed listing) |
| `Command.Model.reportProviderLoud` | `[]` ⇒ `<id> has no models — set one with /model use <id> <model-id>` |
| `Gateway.API.staticModelsFor` | `[]` |
| `Gateway.API.parseProviderModel` | `""` (no more `"llama3.2"` substitution for every provider) |
| `Gateway.API` create/update | `400 {field: "default_model"}` when `defaultModelRequired` and the effective value is empty |

The `""`-as-unset convention follows the existing `T.null`-check precedent in
`TurnEngine` (`adModel`). `Seal.ISA.Ops.Session.handleNew`'s
`anthropic`/`claude-sonnet-4-20250514` default is unchanged (documented).

### 4.5 API key

```haskell
chatHeaders :: Maybe ApiKey -> OpenAICompatSpec -> RequestHeaders
```
The key (when present) is unwrapped by `withApiKey` **inside** this function. No
key ⇒ **no** `authorization` header (never an empty `Bearer `). Names that could
weaken key handling (`authorization`, `host`, `content-length`, `content-type`)
are dropped from `ocsExtraHeaders`. `ocsKeyRequired` is enforced at resolution
(§4.6), so the transport stays policy-free.

```haskell
-- (deferred, §14: key-byte redaction of upstream bodies)
httpErrorText :: OpenAICompatSpec -> Int -> Text -> Text
```
`httpErrorText` single-lines and truncates every body-bearing branch (§6). Key
redaction is deferred (§14) — the key is header-only in this design.
rendered body and to the decode-failure message (§6), before the text can reach
the transcript, the model context, or `seal.log`.

### 4.6 Status, configuration, and the UI invariant

| provider | configured when | authStatus |
|---|---|---|
| anthropic | key **or** OAuth readable | `oauth` / `api-key` / `none` / `vault-locked` |
| ollama | keyless local URL, or key readable for a cloud URL | `keyless` / `api-key` / `none` / `vault-locked` |
| family, base URL missing/invalid | never | `none` |
| family, base URL ok, key readable (whatever `ocsKeyRequired` says) | yes | `api-key` |
| family, base URL ok, `not ocsKeyRequired`, no key | yes | `keyless` (vault not probed only when no key is stored — see step 3) |
| family, base URL ok, `ocsKeyRequired`, no key | never | `none` |
| family, base URL ok, `ocsKeyRequired`, vault locked | never | `vault-locked` |

**Invariants:** (1) `authStatus == "none"` ⇒ not configured (the direction the
UI depends on: the New-provider dropdown is the unconfigured set);
(2) `vault-locked` ⇒ *visible but not configured*, deliberate (matches today's
`ProvidersView`); (3) for family rows, configured ⟺
`authStatus ∈ {api-key, keyless}`. Asserted in **WU-2** (library) and **WU-6**
(API), including a real locked handle (`makeLockedVault`). WU-6's harness wires
`adProviders` to `configuredProviders mh cfg` (today every fixture injects
`pure knownProviders`, which would make the API-level invariant vacuous).

`resolveProvider` for the family: (1) `providerBaseUrlFor` (`Left` propagates);
(2) `ocsKeyRequired` ⇒ read the key — no vault handle ⇒ §6 `/vault setup`
message, `Left VaultLocked` ⇒ §6 `/vault unlock` message, missing key ⇒ §6 key
message; (3) `not ocsKeyRequired` ⇒ optional lookup, locked/absent vault is
fine; (4) build the value. Base-URL errors precede key errors (asserted).

`listCmd` uses the same status function as the gateway (no second derivation),
so CLI and UI cannot disagree.

### 4.7 CLI: one data-driven add plan

```haskell
data BaseUrlPrompt = NoBaseUrl | OptionalBaseUrl Text | RequiredBaseUrl
data KeyPrompt     = NoKey | OptionalKey | RequiredKey
data AddPlan = AddPlan { apBaseUrl :: BaseUrlPrompt
                       , apKey     :: KeyPrompt
                       , apModel   :: Maybe ModelId }

addPlanFor :: KnownProvider -> AddPlan
addPlanFor AnthropicProvider = AddPlan NoBaseUrl RequiredKey (defaultModelFor AnthropicProvider)
addPlanFor OllamaProvider    = AddPlan (OptionalBaseUrl defaultOllamaBaseUrl) OptionalKey (defaultModelFor OllamaProvider)
addPlanFor (OpenAICompatProvider s) =
  AddPlan (maybe RequiredBaseUrl OptionalBaseUrl (ocsBuiltinBaseUrl s))
          (if ocsKeyRequired s then RequiredKey else OptionalKey)
          (ocsDefaultModel s)
```

Presets use `NoBaseUrl` (never a dead `pcBaseUrl` the resolver ignores).

`addCmd` flow and abort rules:

1. base URL prompt (echoed, labelled `<N> base URL …`); validate **immediately**;
   an invalid value is re-prompted in place up to 3 times, then abort;
2. model prompt when `apModel == Nothing` (echoed, required non-empty);
3. key prompt (`ccPromptSecret`; `RequiredKey` ⇒ non-empty required);
4. write **vault first, then config** (a locked vault aborts before the config
   lands half-written); nothing is persisted before step 4.

**Blank vs cancel:** blank is a legitimate *value* wherever the plan says it is
(`OptionalBaseUrl` ⇒ keep the configured/default URL, `OptionalKey` ⇒ store
nothing, which is how `/provider add ollama` already behaves — that test stays
green). At a **required** prompt (`RequiredBaseUrl`, `RequiredKey`, the model),
a blank answer re-prompts (max 3) and then aborts with `nothing was saved`. The
web-cancel sentinel `"rejected"` aborts at **any** prompt and is never stored.
The vault is required only when a non-empty key is stored, so U1 works with no
`/vault setup`.

Success: `Configured <id> (<base-url>, model <model>). Run /provider test <id>
to verify.`

`listCmd` / `testCmd` take `Maybe VaultHandle` (no vault needed) and list **all
known providers** with their status, so "why doesn't my provider appear?" is
answerable: `<id>[ (default)] — auth: <api-key|keyless|none|vault locked|oauth>,
base URL: <url | not set>`.

`/provider add`'s `progDesc` is corrected.

**`/provider remove`** (fixes three bugs): delete the provider's vault key if
present; delete `ANTHROPIC_OAUTH_TOKENS` **only** for `AnthropicProvider`; clear
`[providers.<id>] base_url` for family rows (so a keyless provider can actually
be deconfigured); clear `default_provider`/`default_model` if it was the
default; work with **no vault handle**. The gateway `DELETE` behaves the same
and returns `204` (idempotent), never `500 "vault not configured"`.

### 4.8 Gateway API

`ProviderDetail` additions — **seven** fields, each with a consumer:

| field | anthropic | ollama | family generic | family preset | UI effect |
|---|---|---|---|---|---|
| `displayName` | `providerDisplayName` | ✓ | `ocsDisplayName` | ✓ | row/editor title, falls back to the map |
| `baseUrl` | `"https://api.anthropic.com"` (**now the real endpoint; field read-only**) | raw configured | raw configured | the builtin URL | field value |
| `baseUrlRequired` | `false` | `false` | `true` | `false` | `*`, `aria-required`, blocks Save when empty |
| `baseUrlEditable` | `false` | `true` | `true` | `false` | read-only field |
| `defaultBaseUrl` | `null` | `defaultOllamaBaseUrl` | `null` | `ocsBuiltinBaseUrl` | placeholder (create mode: Ollama keeps `http://localhost:11434`) |
| `keyOptional` | `false` | `not (ollamaNeedsKey url)` | `not ocsKeyRequired` | same | "leave blank…" hint |
| `defaultModelRequired` | `false` | `false` | `defaultModelFor == Nothing` | same | `*` + hint + blocks Save |

`keyRequired` is **not** shipped: it is exactly `not keyOptional` in every row
(verified), so it would be a redundant DTO field. The write-path rule uses
`keyOptional`; nothing else needed it.

`providerInfoJson` (`/api/providers`) gains `displayName`, `defaultModel`, and
`isDefault` (the last two fix pre-existing bugs: `useNewTabSpec` reads both and
the API never emitted them, so the model/default-provider preselection could
never fire).

`staticModelsFor (OpenAICompatProvider s) = map modelText (ocsModels s)`.

Create/update:

1. **Strict decode**: present-but-non-string or `""` ⇒ `400 {error, field}`.
2. **Validate the effective value after merge** (PUT is a partial update):
   `PUT {api_key}` on a provider with a stored base URL succeeds; `PUT
   {base_url: ""}` ⇒ 400.
3. Family preset: a `base_url` in the body (or in config) is **ignored**, never
   stored, never 400 (§4.3). Applies to the step-3 dry run only (no preset ships
   here).
4. `default_model` required when `defaultModelRequired` and the effective value
   is empty.
5. A missing key is **not** an error (`201`/`200`; status becomes `none`).
6. **Only then** write the vault key and the config (today's order is inverted).
   Asserted table-driven on **every** 400 branch.

**Mutation guard — [deferred]** (§14). The REST surface's missing
authentication, `ACAO: *`, and the Origin/Host mutation guard are a *separate*
pre-existing exposure: a hostile page can already set `providers.*.base_url`
today, so this PR neither introduces nor worsens it. The guard ships in the
security PR together with the listener binding it depends on.

**Private disclosure (not fixed here, reported to the operator):** no REST auth;
`ACAO: *` gives cross-origin reads (`GET /api/sessions/:id/transcript`,
`/api/secrets` names, `/api/repos/:id/deploy-key`) and writes (`POST /send`,
`/api/agents`, `/api/skills`, `/api/sessions/:id/prompt`, `/api/repos`,
`/api/tabs/new`) and, worst, `POST /api/sessions/:id/questions/:qid/answer`,
which grants `ASK_HUMAN` approval (`scope: always`) — an approval-gate bypass;
`SECRET_MANAGE get` returns vault values to the model, so `/send` +
cross-origin read is a vault-exfiltration path; warp's binding
(§4.10) made all of this network-reachable before this PR; an allow-listed
`SHELL_EXEC` can edit `config.toml`, `security.toml`, and `config/vault/*`
(command authorization is by program name); `Seal.Web.UrlSafety.extractHost`
truncates at `:` so `isAlwaysBlockedUrl` never matches IPv6 (latent:
`isAlwaysBlockedUrl` is currently unused by `WEB_FETCH`, which uses `isSafeUrl`).
The full detail is delivered to the operator privately, per AGENTS.md.

### 4.9 Frontend

- `types.ts`: `ProviderDetail` + the seven §4.8 fields (required);
  `ProviderInfo` + `displayName?: string`, `defaultModel?: string | null`,
  `isDefault?: boolean` (**optional**, so existing factories type-check).
- Label maps: all four components prefer `displayName`, map as fallback. Only
  edit: add `'openai-compat': 'OpenAI-compatible'` to `ProvidersView`; replace
  `openrouter` with `openai-compat` in the other three.
- `ProvidersView`: id branches replaced by the flags. **Create mode** resolves
  the flags from the `/api/providers/all` row matching `form.name` (none before
  a provider is picked). Base URL row: `*` + `aria-required` when required,
  read-only when `!baseUrlEditable`, placeholder `defaultBaseUrl` (Ollama's
  `http://localhost:11434` survives in create mode), else `https://host/v1`.
  Save disabled while a required field (base URL, default model) is empty;
  whitespace counts as empty. **No client-side URL parsing** — the server's
  `400 {error, field}` renders inline next to the field (`aria-invalid`,
  `aria-describedby`). API-key hint by `keyOptional`; the model hint by
  `defaultModelRequired`. Delete failure is surfaced (today the trash button is
  a silent no-op on error).
- `ActiveTabs`: the badge map keeps brand icons (anthropic/ollama/openrouter)
  and the fallback becomes **id-derived** (title = id, glyph = first char,
  deterministic colour hash) instead of `?`/"Unknown provider" — no
  `displayName` plumbing, so `openai-compat` and every future preset need **no**
  frontend edit (M1).
- `useNewTabSpec`: empty model list ⇒ seed from `ProviderInfo.defaultModel` when
  present, and enable the custom-model field.
- `NewSessionComposer`: align with `NewTabComposer` — mark and disable
  unconfigured providers, and treat "no configured provider" (not "no
  provider") as empty (a third provider makes this reachable).
- `useNewTabSpec`'s persisted `last_options.provider = "openrouter"` self-heals
  via the existing name-membership re-selection (documented, not changed).

### 4.10 Gateway listener — **[deferred]**

The listener-binding fix (`runSettings` with `gcHost` instead of `Warp.run`,
which binds `*4`) and the CHANGELOG note ship in the security PR (§14). This PR
does not change how the gateway binds.

## 5. File scope

**Haskell**
- `src/Seal/Providers/OpenRouter.hs` → **rename** `src/Seal/Providers/OpenAICompat.hs`
- `src/Seal/Providers/Registry.hs`
- `src/Seal/Session/Store.hs`
- `src/Seal/Command/{Provider,Model,New}.hs`
- `src/Seal/Gateway/API.hs`
- `src/Seal/Config/File.hs` (doc: `pcBaseUrl` is a credential destination; a
  preset's section is ignored)
- `src/Seal/Config/Migrate.hs` (+ call sites in `src/Seal/Command/Serve.hs`,
  `src/Seal/Tui.hs`)
- `seal-harness.cabal` (library `exposed-modules` rename, test-suite
  `other-modules` rename, no other entries)

**Tests**
- `test/Seal/Providers/OpenRouterSpec.hs` → `OpenAICompatSpec.hs` (rewritten)
- `test/Seal/Providers/RegistrySpec.hs`
- `test/Seal/Command/{ProviderSpec,ModelSpec,NewSpec}.hs`
- `test/Seal/Session/StoreSpec.hs`
- `test/Seal/Gateway/ApiSpec.hs`
- `test/Seal/Config/{MigrateSpec,FileSpec}.hs`
- `test/Main.hs` (import + spec list)
- `test/Seal/Channel/CliSpec.hs` — untouched (its `unknown provider` assertion
  still matches)
- The warp-mock template already exists (`test/Seal/Command/ModelSpec.hs`,
  `testWithApplication`); no new dependency.

**Frontend**
- `frontend/src/types.ts`
- `frontend/src/components/{ProvidersView,NewSessionComposer,NewTabComposer,AgentsView,ActiveTabs}.tsx`
- `frontend/src/hooks/useNewTabSpec.ts`
- `frontend/src/components/__tests__/{ProvidersView,NewTabComposer,NewSessionComposer}.test.tsx`
- `frontend/src/hooks/__tests__/useNewTabSpec.test.ts`
- `frontend/vite.config.ts` (comment: `changeOrigin` must stay false)
- `Makefile` (`frontend-test` target, created in **WU-7**, depending on
  `frontend-install`)

**Docs**
- `CHANGELOG.md`; `docs/plans/openrouter-provider-{design,plan}.md` (superseded
  notes); `cabal.project` comment; `TODO.md` + the roadmap's `openrouter` lines

## 6. Exact user-facing strings

Legend: `<N>` = display name, `<id>` = provider id, `<url>` = resolved base URL,
`<model>` = model id. "Surface" — **T** = transcript/model-visible (chat, logs),
**C** = CLI prompt, **R** = REST body, **E** = editor.

| situation | text | surface |
|---|---|---|
| base URL missing | `<N> needs a base URL — set it in the Providers view, or run /provider add <id>` | T, C |
| base URL missing (editor) | `Base URL is required — for example https://host/v1` | E |
| base URL invalid | `<N> base URL is not usable (<reason>) — it must be an http(s) URL like https://host/v1` | T, C, R |
| unencrypted base URL (CLI warning) | `<N> base URL is http, not https — the API key will be sent unencrypted (continuing)` | C |
| base URL prompt (required) | `<N> base URL (full URL including the API path, e.g. https://host/v1): ` | C |
| base URL prompt (defaulted: Ollama, presets) | `<N> base URL [<default>] (blank = keep): ` | C |
| model prompt | `<N> model id (e.g. qwen2.5-7b-instruct; for keyed endpoints see your provider's docs): ` | C |
| API-key prompt | required: `<N> API key: ` · optional: `<N> API key (blank for a keyless endpoint): ` | C |
| required input blank / cancelled | `nothing was saved — run /provider add <id> again` | C |
| no model selected | `<N> has no model selected — set a model in the Providers view, or run /model use <id> <model-id>` | T, C |
| key required, no vault | `<N> needs an API key — run /vault setup, then /provider add <id>` | T, C |
| key required, vault locked | `<N> needs an API key and the vault is locked — run /vault unlock` | T, C |
| key required, no key stored | `<N> needs an API key — run /provider add <id> (add to an existing entry; no need to remove it first)` | T, C |
| transport failure | `<N> HTTP request failed (connection or transport error)` (verbatim — `isTransientError` matches it) | T, C |
| redirect refused | `<N> endpoint answered with a redirect (HTTP <code>), refused for security — enter the final URL` (+ `; run /provider add <id>` for the generic row; presets: `— this is a Seal bug, please report it`) | T |
| 401/403, keyed row | `<N> rejected the API key (HTTP <code>) — run /provider add <id> to re-enter it` | T, C |
| 401/403, keyless row | `<N> rejected the request (HTTP <code>) — this endpoint requires an API key; set one in the Providers view or run /provider add <id>` | T, C |
| 404 | `<N> API returned HTTP 404 — check the base URL path (it may be missing /v1) or the model id: <body>` | T |
| 429 | `<N> rate limit (HTTP 429) — wait a moment and retry, or switch models with /model use` (verbatim `HTTP 429`) | T |
| other non-2xx | `<N> API returned HTTP <code>: <body>` | T |
| empty choices | `<N> returned no choices` | T |
| decode failure | `<N> returned an unreadable response: <message>` | T |
| legacy, config (emitted once to stderr by the migration) | `openrouter was renamed to openai-compat; your config was updated (base URL https://openrouter.ai/api/v1, model <model>). Run /provider add openai-compat to store the API key.` — when the write failed: `… Seal could not update your config. Run /provider add openai-compat (base URL https://openrouter.ai/api/v1, model <model>).` | C |
| legacy, session | `unknown provider in session: openrouter — openrouter was renamed to openai-compat; first run /provider add openai-compat, then /model use openai-compat <model-id>` | T |
| legacy, agent def | `unknown provider in agent def: openrouter — openrouter was renamed to openai-compat; edit the def's provider line to openai-compat` | T |
| legacy, `new -p` | `unknown provider: openrouter — openrouter was renamed to openai-compat (known: anthropic, ollama, openai-compat)` | C |
| `/provider add` success | `Configured <id> (<url>, model <model>). Run /provider test <id> to verify.` | C |
| `/provider list` line | `<id>[ (default)] — auth: <api-key\|keyless\|none\|vault locked\|oauth>, base URL: <url \| not set>` | C |
| `/provider default` | `default provider set to <id> (model: <model>)` / `(no default model — set one with /model use <id> <model-id>)` | C |
| `/model list` (quiet, fallback branch) | `<id> (default model: none — set one with /model use <id> <model-id>)` | C |
| `/model list <id>` (empty) | `<id> has no models — set one with /model use <id> <model-id>` | C |

`httpErrorText` applies single-lining + **2000-char truncation** to every
body-bearing branch and to the decode message, and every rendered body passes
(key redaction deferred, §14).

## 7. Testing strategy (TDD, RED-first, no egress)

**Hard rules.** No test constructs a provider whose base URL is not loopback
(`127.0.0.1`). The old `"complete (no key) ⇒ Left"` test
(`OpenRouterSpec.hs:196-212`) is **deleted** — with the key guard gone it would
perform real HTTPS to `openrouter.ai` and still pass. Connections to
`127.0.0.1:1` are only for negative paths. QuickCheck generators are bounded
(§4.3).

**Work units** (gates: `make check` for WU-1…WU-6, WU-8; `make frontend-test`
for WU-7 — created in WU-7):

- **WU-1a — mechanical rename.** Module/type/field names, cabal, `test/Main.hs`,
  ported spec with identifier changes only. RED protocol for this
  compile-breaking unit: add the new module + spec with bodies moved verbatim;
  the build fails until both are wired, then the ported assertions pass. No
  behaviour is claimed.
- **WU-1b — transport** (`OpenAICompatSpec`): `chatHeaders` (no key ⇒ no
  `authorization`; key ⇒ `Bearer` and the bytes appear only as that header's
  suffix; reserved names dropped); `validateBaseUrl` (full §4.3 table + 4
  properties); `chatUrl`; `httpErrorText` (401 keyed/keyless,
  403, 404 `/v1` hint, 429, other) incl. a >2000-char body truncated,
  single-lined, and key-redacted; `sendChatCompletion` with an unparseable base
  URL ⇒ `Left` (no escaping exception); empty-`crModel` ⇒ §6; 302 ⇒ the
  redirect message (`isTransientError` does **not** match it) with the target
  never hit; wire-level keyless `complete` against a warp mock at
  `http://127.0.0.1:PORT/openai/v1/` asserting `POST
  /openai/v1/chat/completions`, **no** `authorization` header, canned
  completion — and a second mock returning 401 asserting the keyless-row
  message.
- **WU-2 — catalog + resolution** (`RegistrySpec`): `knownProviders` order;
  catalog ids unique; `parseProvider`; `vaultKeyName`; `defaultModelFor`;
  `providerDisplayName`; `providerBaseUrlFor` (missing ⇒ `Left` mentioning
  `base_url` + Providers view; invalid ⇒ reason; injected preset ⇒
  `Right builtin` with a conflicting config URL; generic ⇒ configured **and
  canonical** — `Right "http://h/v1"` for `"http://h/v1/"`); `resolveProvider`
  (keyless with no vault handle ⇒ `Right`; keyless with a locked vault ⇒
  `Right`, vault untouched; key-required missing key ⇒ `/provider add`; locked
  ⇒ `/vault unlock`; base-URL error precedes key error); `configuredProviders`
  + the §4.6 invariants with `makeLockedVault`.
- **WU-2b — legacy recovery copy** (`ProviderSpec`): `resolveSessionProvider`
  and `resolveDefProvider` produce the §6 session/agent-def messages;
  `Seal.Command.New` rejects `-p openrouter` with the `new -p` message and
  creates no session; a second case proves `-p <known>` still works.
- **WU-3 — model plumbing** (`RegistrySpec`, `StoreSpec`, `ModelSpec`):
  `resolveDefaultModel (Just "")` ⇒ `Nothing`; unknown label ⇒ Anthropic
  default; `defaultSessionSelection` ⇒ `""`; `/model use` without a model ⇒
  error, session unchanged; `reportProviderQuiet` fallback line;
  `reportProviderLoud` empty-catalogue line; `listModels` =
  `ocsModels ∪ {configured model}` (and `[]`); `New` repairs an inherited empty
  model via `resolveDefaultModel`.
- **WU-4 — migration** (`MigrateSpec`): `default_provider` rewritten;
  `[providers.openrouter]` copied incl. `default_model`, `base_url` defaulted
  when absent; **only `default_provider` set ⇒ the section is synthesized with
  the OpenRouter default**; an existing `[providers.openai-compat]` wins over
  the copied section; the old section is removed; idempotent; malformed TOML
  untouched; unwritable file ⇒ fail-open (no exception) and the §6
  could-not-update message; **ordering test: a config with
  `[untrusted_execution] mode = "remote"` + `[providers.openrouter]` ⇒ after
  both migrations, `security.toml` exists with the remote settings and the
  provider section is migrated** (proves the rename runs *after*
  `migrateSecurityConfig`).
- **WU-5 — CLI** (`ProviderSpec`): `add` blank/invalid base URL ⇒ message and
  nothing written; `ftp://h` ⇒ reason, nothing written; valid URL + blank key +
  model `m` ⇒ `base_url` + `default_model` in config, no vault key; keyless add
  with **no vault configured** works; `add anthropic` / `add ollama`
  regressions (base URL optional with default, key optional for Ollama);
  cancellations (`""`, `"rejected"`) abort and persist nothing; `list` with no
  vault lists all providers with the shared status labels; `test openai-compat`
  against `http://127.0.0.1:1/v1` asserts the verbatim transport message (so a
  2xx could never pass); `remove openai-compat` (keyless, **no vault handle**)
  clears the base URL and succeeds; `remove openai-compat` leaves
  `ANTHROPIC_OAUTH_TOKENS` intact while `remove anthropic` deletes it; the three
  existing label tests that change (`list reports auth: none …`) are rewritten.
- **WU-6 — gateway** (`ApiSpec`, `ServerSpec`): `allowMutation` unit table (no
  headers ⇒ allow; `Host: evil.example` ⇒ 403; matching Origin+Host on
  localhost ⇒ allow; `Origin: null` ⇒ 403; `Origin` without `Host` ⇒ 403;
  `Origin: http://localhost:8080.evil.com` ⇒ 403; port mismatch ⇒ 403;
  bracketed IPv6 ⇒ allow) and HTTP-level: a foreign-Origin POST ⇒ 403 with the
  §6 body; `/api/providers/all` fields for `openai-compat`; authStatus
  transitions + the three invariants with unlocked **and** locked vaults (with
  `adProviders` wired to `configuredProviders`); POST/PUT validation matrix
  (missing, `""`, `ftp://h`, CRLF, metadata host, missing model) **each
  asserting the vault was not written**; valid POST ⇒ 201; `PUT {api_key}` only
  ⇒ 200; `PUT {base_url: ""}` ⇒ 400; `GET /api/providers/openai-compat/models`
  ⇒ `[]`; `POST /api/tabs/new` with the family and no model ⇒ `smModel == ""`;
  `DELETE` without a vault ⇒ 204; `providerInfoJson` includes
  `displayName`/`defaultModel`/`isDefault`; `ServerSpec` asserts
  `settingsHost (serverSettings cfg) == gcHost`.
- **WU-7 — frontend** (`make frontend-test`): Save disabled/enabled around each
  required field (both directions); `baseUrlRequired: false` ⇒ Save enabled
  with an empty URL; read-only base URL when `!baseUrlEditable`; Ollama
  placeholder in **create** mode; family placeholder; `keyOptional` hint;
  `defaultModelRequired` hint/Save; `baseUrlIgnored` warning; row title from
  `displayName` with the map as fallback; `NewTabComposer` option text
  `OpenAI-compatible`; `NewSessionComposer` marks/disables unconfigured
  providers; `ActiveTabs` renders an **id-derived** badge for an id absent from
  the map (proves no map edit is needed) and keeps the legacy `openrouter`
  icon; empty model list + `defaultModel` ⇒ pre-seeded custom model; server
  `400 {field}` and 403 render inline; delete failure surfaces.
- **WU-8 — docs/cleanup**: CHANGELOG, superseded notes, `cabal.project`,
  `TODO.md`/roadmap, and confirmation that `make frontend-test` exists.

A live round-trip stays `pendingWith`. No new network dependency.

## 8. Security

1. **`base_url` is a bearer-token destination.** Who can set it: the operator
   (config, `/provider add`, the guarded gateway); **any process with an
   allow-listed shell command** (`SHELL_EXEC` authorizes by program name, so
   `config.toml`, `security.toml`, and `config/vault/*` are writable; in
   `remote` mode exec is off-box). No config-writing opcode and no file opcode
   can reach it. The shell path is part of the private disclosure, not fixed
   here.
2. **Validation** (§4.3) is applied on write (CLI + gateway) and at resolution.
   The metadata floor is a **textual denylist** (shared tables, locally parsed
   host, brackets/trailing-dot/`%` handled) and is described as defence in
   depth, not an SSRF control.
3. **Redirects:** `redirectCount = 0` + `shouldStripHeaderOnRedirect = const
   True`; a 3xx raises `TooManyRedirects`, which is mapped to the dedicated
   **non-transient** message (it never matches `isTransientError`, so the loop
   does not retry it). Mechanism recorded so nobody "fixes" the message by
   raising `redirectCount`.
4. **Presets are authoritative** (§4.3): a preset's URL cannot be overridden,
   so the displayed URL is always the destination.
5. **Key isolation:** `chatHeaders` takes `Maybe ApiKey` and unwraps it inside
   `withApiKey`; the bare key never appears outside an `authorization` header
   value, that value is never logged, and every rendered body/message is run
   (key redaction deferred, §14).
6. **Error text:** single-lined, truncated to 2000 chars, key-redacted — it
   lands in the transcript, the model context, and `seal.log`.
7. **[deferred]** The REST mutation guard and the listener binding (§14). They
   address a pre-existing exposure this PR neither introduces nor worsens.
9. **No new opcodes; no writes to `~/.seal/`.** Config writes go through
   `updateRuntimeConfig`/`saveRuntimeConfig` only.
10. **Orphaned credential:** `OPENROUTER_API_KEY` stays in the vault after
    migration, unused but visible (`/vault list`, `SECRET_MANAGE list`,
    `GET /api/secrets`) and readable by agents; purge with `/vault delete
    OPENROUTER_API_KEY`; step 3 adopts it. Because the upstream key stays live,
    the CHANGELOG tells the operator to revoke it if step 3 will not ship.
11. **Plaintext HTTP:** allowed (U1 needs loopback). `/provider add` warns for a
    non-loopback `http://` URL (a warning, not a block). The editor-side warning
    is deferred with the other gateway/UI hardening (§14).
12. **Ollama's base URL stays unvalidated** this PR (back-compat); when it is
    fixed, it must reuse `validateBaseUrl`. The mutation guard, not validation,
    protects that credential today.
13. **Deferred, privately reported:** the list in §4.8 (REST auth, `ACAO: *`
    reads/writes, the `ASK_HUMAN` answer route, `SECRET_MANAGE` exfiltration,
    `UrlSafety.extractHost`, shell-writable config/security/vault files).

## 9. Risks / trade-offs

| Risk | Mitigation |
|---|---|
| Rename breaks config / sessions / agent defs / `new -p` | WU-4 migrates config (ordered **after** `migrateSecurityConfig`); WU-2b owns three surface messages; `new` validates `-p`; M2 |
| Migration re-encodes `config.toml`, dropping comments/unknown keys | Documented; uses `updateRuntimeConfig` (serialized, atomic load→save); the ordering rule prevents the security-field loss |
| Stale global `default_model` gives a family session a foreign model | Unchanged precedence; documented; the endpoint 404/§6 message follows |
| `smModel = ""` | Pre-existing unset convention (`TurnEngine` precedent); every read site tabulated in §4.4, including `New`'s repair |
| "keyless" badge unverifiable for a remote URL | `keyOptional` + the keyless 401/403 message |
| Frontend unit tests ungated by `make check` | `frontend-test` target (WU-7), explicit commands, follow-up to wire into CI |
| Spec table invites vendor drift | 8 spec fields; §11 grep check |

## 10. Backward compatibility

**Automatically migrated at boot** (`providerRenameMigration`, run **after**
`migrateSecurityConfig` in `Serve.hs` and `Tui.hs`):

- `default_provider = "openrouter"` → `"openai-compat"`.
- `[providers.openrouter]` → `[providers.openai-compat]` (keeps `default_model`
  and `base_url`; fills the OpenRouter default URL when absent; synthesizes the
  section when only `default_provider` existed; an existing
  `[providers.openai-compat]` wins; the old section is removed).
- One stderr line (§6), idempotent, fail-open on write errors (with the
  could-not-update variant), written through `updateRuntimeConfig`.

**Manual (exact command in the error):** session `provider: "openrouter"` (→
`/provider add` then `/model use`); agent defs (→ edit the `provider` line); the
vault entry (re-enter once with `/provider add openai-compat`; it stays for
step 3); `new -p openrouter` (now rejected with the §6 message).

**Also changed for everyone:** upstream 3xx responses are refused
(`redirectCount = 0`) with an actionable message rather than followed — a base
URL that redirects (e.g. `http://` → `https://`) must be entered in its final
form; `parseProviderModel` no longer substitutes
`llama3.2`; `/provider remove <non-anthropic>` no longer deletes the Anthropic
OAuth blob; keyless family providers become removable/deconfigurable; the
migrated OpenRouter users lose the
`HTTP-Referer`/`X-Title` attribution headers (now step 3's preset row).

## 11. Step-3 readiness checklist

- [ ] A preset is one appended `OpenAICompatSpec` row; `git diff --stat` shows
      one file under `src/` and no frontend file (M1).
- [ ] Dry-run tests with an **injected** spec: `ocsBuiltinBaseUrl = Just u` ⇒
      `Right u` with empty config and with a conflicting config URL; `chatUrl`
      targets `u` single-slashed; `ocsModels` drives `staticModelsFor` and
      `listModels`; `ocsKeyRequired` without a key ⇒ `none`/not configured;
      with a key ⇒ `api-key`; all §4.6 invariants hold.
- [ ] No provider-id **comparison** remains. Run from the repo root:
      `rg -n '== *"openai-compat"' src/` and
      `rg -n '== *"(ollama|anthropic|openrouter)"' src/`. Each returns only the
      sanctioned capability checks — the Anthropic OAuth guard (`loginCmd`) and
      the Anthropic-only OAuth-blob delete, both of which key off
      `AnthropicProvider` (a constructor, not a string) once WU-5 lands. The
      catalog row, the migration and the legacy-hint helper legitimately
      contain the literal `"openai-compat"`.
- [ ] No config-writing opcode exists for `providers.*.base_url` /
      `delegation.base_url` (`dfcBaseUrl` is the latent path).

## 12. Round-2 disposition

See revision-3 history; all items closed or superseded by §13.

## 13. Round-3 disposition

| Round-3 finding | Resolution |
|---|---|
| "run /vault setup" flattens a locked vault into a rekey trap (PM-1) | §4.2 rule 4 + three distinct key messages (§6) |
| Browser-reachable strings name slash commands only (Designer-1) | §4.2 rule 2 + Providers-view-first copy; REST bodies carry no command tail (§4.2 rule 3) |
| 401 repair recommends the destructive `/provider remove` (Designer-2) | §6 now says "run /provider add <id> (add to an existing entry…)" |
| Eight fields, two without a UI effect; create-mode source unstated (Designer-3, CTO-2) | §4.8 table with a UI effect per field, `keyRequired` dropped, create mode resolves flags from `/api/providers/all` |
| `baseUrlIgnored` contradicted for anthropic (Arch-3) | anthropic now `baseUrl = real endpoint`, `baseUrlEditable: false`, `defaultBaseUrl` set |
| ActiveTabs `displayName` plumbing absent (Arch-4, Designer-S3, PM-S7) | §4.9: id-derived badge, no new plumbing, no map edit needed |
| migration ordering could destroy security fields (Arch-1) | §10 mandates running **after** `migrateSecurityConfig`; WU-4 ordering test |
| migration trigger/precedence under-specified (Arch-2) | §10: triggers on default **or** section, synthesizes, existing section wins |
| WU→assertion mapping false (Arch-2, CTO-1..7, PM-S4) | WU-2b added for all four legacy messages incl. `new -p` validation; WU-6 wires `adProviders`; `staticModelsFor`/`parseProviderModel` asserted via HTTP; presets-ignore-body moved to §11; `chatUrl`/`httpErrorText`/`redactKey` signatures declared; `test` uses `127.0.0.1:1`; three existing ProviderSpec tests rewritten; `frontend-test` created in WU-7 |
| `smModel = ""` leaks into `new -p anthopic` (Arch-5) | §4.4 `New` repair row + WU-3 |
| `addCmd` abort/blank paths undefined, garbage persisted (Designer-5) | §4.7 sentinels, in-place re-prompt, `RequiredKey` non-empty, validate-before-next-prompt |
| keyless provider cannot be removed (Designer-6) | §4.7 remove/deconfigure + vault-optional + 204; UI surfaces delete failure |
| gateway network-reachable, guard premise false (Sec H1) | §4.10 binds `gcHost`; §4.8 documents the dependency; CHANGELOG |
| guard is a 5-route denylist (Sec H2) | §4.8: deny-by-default for all mutating routes |
| disclosure incomplete (Sec B3) | §4.8/§8.13 list the categories; full detail delivered privately |
| metadata floor textual / IPv6 / trailing dot / `%` (Sec M1, M5) | §4.3 shared tables + local host parsing, `%` rejected, scheme lowercased |
| authority match underspecified (Sec M2) | §4.8 exact parsed-authority equality incl. port + tests |
| 302 exception mechanism (Sec M3) | §8.3 states `TooManyRedirects` and the non-transient mapping |
| no 403 copy (Sec M4) | §6 403 row + editor rendering |
| decode message not redacted (Sec M6) | §4.5/§6 redaction covers the decode message |
| §4.3/§8 cross-reference broken (Sec M7) | §8.13 |
| `parseProviderModel`/`staticModelsFor` not testable from WU-3 (CTO-2) | moved to WU-6 (HTTP) |
| `providerInfoJson` also misses `isDefault` (CTO-S4) | §4.4/§4.8 add it |
| misc: `ProviderInfo`/`ApiTestHarness`/`TODO.md`/`vite.config` (CTO-S5..S8) | §5 and WU-8 updated; `ApiTestHarness` dropped from scope |

## 14. Scope reduction after the plan-review gate (authoritative for this PR)

The plan-review gate (Feasibility / Completeness / Scope & Alignment) found the
plan right-sized for nothing: it had absorbed a gateway-hardening project into a
provider rename. The split:

**Ships in this PR (issue #271)**

- The rename, the catalog row, the required base URL, `validateBaseUrl`,
  `chatUrl`, the model/key/status rules, the CLI `AddPlan`, the gateway DTO +
  validate-before-write, the API/model plumbing, the boot-time config migration,
  the frontend flag-driven editor, and the CHANGELOG.
- `redirectCount = 0` + `shouldStripHeaderOnRedirect` (two lines; the URL is now
  a *required*, user-supplied destination for a bearer token).
- Provider-parameterised, single-lined, 2 000-char-truncated error text
  (`httpErrorText` is being rewritten anyway; `redactKey` is **deferred**, since
  the key is header-only and upstream bodies do not contain it).
- *(removed: the metadata/SSRF denylist is deferred — see the table below.)*
- The `/provider remove` OAuth-blob fix and vault-optional
  `list`/`test`/`remove` (needed by the keyless flow this PR introduces, and by
  the new "re-add, don't remove" 401 copy).
- `new -p` validation and the three legacy recovery messages (direct
  consequences of renaming a persisted provider id).
- A pure catalog seam (`parseProviderIn`/`catalogProblems`, §4.1) so the
  "one row" claim is testable with an injected catalog.

**Deferred to a separate security PR (already reported to the operator
privately; no public issue)**

| Deferred deliverable | Design reference |
|---|---|
| REST mutation guard (`allowMutation`, Origin/Host matching, rebinding-resistant `Host` rule, deny-by-default on mutating routes) | §4.8 (marked deferred) |
| Gateway listener binding (`runSettings` + `gcHost` instead of `Warp.run`/`*4`) | §4.10 (marked deferred) |
| Key-byte redaction of upstream bodies (`redactKey`) | §4.5/§8.5 (drop the claim) |
| `Seal.Web.UrlSafety` table export and its IPv6 `extractHost` fix | §8.2/§8.13 |
| REST authentication / `ACAO: *` narrowing | §8.13 |
| `isDefault` on `/api/providers` and the `NewSessionComposer` unconfigured-provider bug | §4.9 (both pre-existing, unrelated) |

**Superseded in §7:** the work-unit list in §7 is the *design's* sketch. The
authoritative unit list, file scope, RED steps and DoDs for this PR are in
`docs/superpowers/plans/2026-10-19-openai-compat-provider-plan.md`. WU-6's
guard/listener items and WU-7's `baseUrlIgnored`/403 items are removed from it.

**Unchanged:** every user-facing string in §6 except the deleted 403 row; the
§4.6 status table and invariants; the §10 migration; the §11 step-3 checklist
(step 3 remains one catalog row under `src/`, and the frontend needs at most an
optional badge/icon entry).

### 14.1 Amendments after the second plan-gate round

- **Keyless status (§4.6 amended).** A readable key wins: a family row with a
  key in the vault reports `api-key` whether or not the key is *required*. The
  vault is probed only when a key exists or a key is required, so a keyless row
  with no key never touches it. This closes the incoherence where U2 (hosted
  gateway + key) was labelled `keyless` forever.
- **Blank vs cancel (§4.7 amended).** Blank is a value at optional prompts
  (keep default URL / store no key — the existing Ollama onboarding test must
  stay green); at required prompts blank re-prompts (max 3) then aborts;
  `"rejected"` aborts anywhere.
- **`ocsExtraHeaders` stays** (rebuttal to "task-3-only"): it is the seam that
  keeps step 3 to one `src/` file. Dropping it would force step 3 to edit the
  transport to restore OpenRouter's `HTTP-Referer`/`X-Title`. The
  reserved-name filter stays with it (3 lines, prevents a future row from
  shadowing `authorization`/`host`).
- **Also deferred (added to the table in §14):** the metadata/SSRF denylist and
  the `Seal.Web.UrlSafety` export; the editor-side insecure-`http://` warning;
  `displayName`/`defaultModel` on `GET /api/providers` and the
  `useNewTabSpec`/`isDefault` preselection (pre-existing bugs); key-code
  redaction.
- **ActiveTabs:** this PR adds a plain `openai-compat` badge entry to the
  existing map (simplest change that removes the `?`/“Unknown provider” wart).
  The id-derived fallback described in §4.9 is *not* implemented; step 3
  therefore adds at most one optional badge entry.
- **Redirect refusal and error-body truncation are user-visible hardening** and
  are recorded in the CHANGELOG (§10).
