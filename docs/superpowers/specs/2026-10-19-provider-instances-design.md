# Design: Named provider instances

Status: draft — revision 2 (design gate round 1: 5/5 NEEDS_REVISION)
Issue: #273
Builds on: `2026-10-19-openai-compat-provider-design.md` (#272, in review)

## 1. Problem

Today a provider **is** its type: one `[providers.<type>]` section per kind, one
vault key per kind, and `KnownProvider` is a closed sum. A user can therefore
have exactly one `openai-compat` endpoint — which makes no sense for a *generic*
provider — one Anthropic key, one Ollama server.

People routinely have several of each: `local-vllm` + `groq` + a work proxy (all
OpenAI-compatible), `anthropic-work` + `anthropic-personal`, `ollama-laptop` +
`ollama-desktop`.

Fix: a provider becomes a **named instance of a type**. The user names it;
sessions, agent defs, the CLI and the UI address it by name.

## 2. Use cases

| # | WHO | WANTS | SO THAT | WHEN |
|---|-----|-------|---------|------|
| U1 | Operator with a local model server and a hosted compatible gateway | two `openai-compat` instances with distinct URLs/keys/models | both are selectable per session | `/provider add openai-compat local` |
| U2 | Operator with work and personal Anthropic keys | `anthropic-work` / `anthropic-personal` | I can switch without re-entering keys | `/provider add anthropic work` |
| U3 | Operator with a laptop and a desktop Ollama daemon | one instance per host | I don't rewrite the URL each time | `/provider add ollama desktop` |
| U4 | Existing user | their current setup keeps working, unchanged | nothing to re-enter, no config rewrite | on upgrade |
| U5 | Web user | the provider dropdown lists **my** instances by name | I pick the one I mean | in the composer |
| U6 | Web user adding a second instance of a type | a type picker + a name field | I can do it without the CLI | Providers view |
| U7 | Operator who deleted an instance a session/agent def used | an actionable error naming the instance, the existing ones, and a reachable repair | I don't hunt through config | next turn |
| U8 | Operator removing one of two same-type instances | only that instance's credential removed | the sibling keeps working | `/provider remove work` |

**Non-goals:** renaming in place (remove + re-add); per-instance model catalogues
beyond `default_model`; new provider *types* (step 3's `openai`/`openrouter`
presets stay catalog rows); changing the #271 rename.

## 3. Model

### 3.1 Types are static, instances are the union of "implicit defaults" and config sections

```haskell
data ProviderType = AnthropicType | OllamaType | OpenAICompatType !OpenAICompatSpec

providerTypes :: [ProviderType]
providerTypes = [AnthropicType, OllamaType] <> map OpenAICompatType openAICompatSpecs

typeId :: ProviderType -> Text   -- "anthropic" | "ollama" | ocsId spec
```

```haskell
data ProviderInstance = ProviderInstance
  { piName    :: !ProviderName          -- user-chosen id (config table key)
  , piTypeId  :: !Text                  -- what the config says (or the implicit name)
  , piType    :: !(Maybe ProviderType)  -- Nothing ⇒ unresolvable; see piProblem
  , piConfig  :: !ProviderConfig        -- base_url / default_model
  , piProblem :: !(Maybe Text)          -- rendered in the list, never fatal
  }

-- | Implicit type-named instances (catalog order), then explicit sections by
-- name. Never empty: a fresh install gets anthropic / ollama / openai-compat,
-- exactly like today's static list.
providerInstances :: RuntimeConfig -> [ProviderInstance]
```

**Implicit instances are load-bearing.** With no `[providers.*]` sections the
list is still `[anthropic, ollama, openai-compat]` (unconfigured), which keeps:
`GET /api/providers` non-empty, the composer usable, `/provider list` useful,
and the hardcoded defaults resolvable — `defaultSessionSelection` returns
`"anthropic"` (`Session/Store.hs`), `SESSION_*` defaults to `anthropic`
(`ISA/Ops/Session.hs`), a delegated child with an empty `adProvider` defaults to
`ollama` (`Agent/Runtime/Delegation/Worker.hs`). None of those change; they now
resolve to the implicit instance.

Precedence: a config section named `<x>` **is** the instance `<x>`; an implicit
instance is only synthesized for a type id no section claims. A section whose
name equals a type id but declares a *different* type is reported as a problem
(see 3.2) rather than shadowing that type's default.

**Type resolution:** `pcType` (trimmed; `""` = absent) if it names a known
type; else, for **back-compat**, the frozen legacy set
`{anthropic, ollama, openai-compat}` when the section name is in it. A freshly
added catalog type never silently adopts hand-written `type`-less sections.

`config.toml`:

```toml
[providers.groq]
type = "openai-compat"
base_url = "https://api.groq.com/openai/v1"
default_model = "llama-3.3-70b"

[providers.anthropic-work]
type = "anthropic"
default_model = "claude-opus-4-8"
```

No boot-time rewrite: legacy sections resolve through the fallback, so no
comment is lost and no secret moves. (New instances always write `type`.)

### 3.2 Instance names

`Seal.Providers.Name` (new leaf module — no Registry dependency, no
File↔Registry cycle):

```haskell
newtype ProviderName = ProviderName Text        -- constructor NOT exported
mkProviderName :: Text -> Either Text ProviderName
providerNameText :: ProviderName -> Text
```

Rules, applied to the **raw** text with **no normalisation** (casefold-then-derive
would create collisions):

* 1–32 chars, ASCII `[a-z0-9-]` only;
* no leading/trailing `-`, no `--`;
* not a **reserved** word: `all`, `default` (gateway literal routes) and
  `openrouter` (the legacy id the #271 migration still recognises, and step 3's
  future preset id).

A name equal to a type id is legal **only for that type** (`anthropic` may name
the anthropic instance). `mkProviderName` cannot check that (it has no type), so
the check lives in one helper used by every entry point:

```haskell
checkNameForType :: ProviderName -> ProviderType -> Either Text ()
-- "ollama is a provider type id — choose another name, e.g. ollama-cloud"
-- (allowed when providerNameText n == typeId t)
```

Consequences, all tested: the derived vault key is injective, TOML bare keys are
always valid, and a hand-edited foreign key (`[providers."we ird"]`) round-trips
verbatim without being renamed.

### 3.3 Credentials: one key per instance, disjunct namespaces

```haskell
providerApiKeyName  :: ProviderInstance -> Text
providerOauthKeyName :: ProviderInstance -> Maybe Text   -- anthropic-typed only
```

| instance | API-key vault name |
|---|---|
| `name == typeId (its own type)` — the legacy/default case | **unchanged**: `ANTHROPIC_API_KEY` / `OLLAMA_API_KEY` / `ocsVaultKey` |
| any other name | `PROVIDER_APIKEY_<SHOUTY_SNAKE_NAME>` |

| anthropic OAuth | vault name |
|---|---|
| instance named `anthropic` | `ANTHROPIC_OAUTH_TOKENS` (unchanged) |
| any other anthropic-typed instance | `PROVIDER_OAUTH_<SHOUTY_SNAKE_NAME>` |

`SHOUTY_SNAKE` = upper-case, `-` → `_`; injective over the grammar.

**Why two prefixes:** with a *suffix* scheme (`PROVIDER_<NAME>_OAUTH_TOKENS`),
an instance named `x-oauth-tokens` would collide with instance `x`'s OAuth blob
— and reading that key as an API key would put a serialized OAuth blob on the
`Authorization` header. Distinct prefixes make the namespaces provably disjoint:
`PROVIDER_APIKEY_*` ∩ `PROVIDER_OAUTH_*` = ∅, and both are disjoint from the
legacy set as long as no catalog row's `ocsVaultKey` starts with `PROVIDER_`
(enforced by `catalogProblems`, below).

`catalogProblems` grows four checks: each `ocsId` is a valid `ProviderName`; each
`ocsId` is not `anthropic`/`ollama`; `ocsVaultKey`s are pairwise distinct; no
`ocsVaultKey` starts with `PROVIDER_` or collides with the legacy keys
(`ANTHROPIC_API_KEY`, `OLLAMA_API_KEY`, `ANTHROPIC_OAUTH_TOKENS`).

**Instance cap:** 64 (CLI and gateway), with an actionable error. Instance count
is otherwise operator-unbounded on a surface whose mutation guard is deferred;
`/api/providers/all` also does one vault read per instance.

### 3.4 Resolution, status, and per-instance lookups

`resolveInstance :: … -> ProviderInstance -> …` dispatches on `piType`, but —
unlike today — **every** per-instance lookup is keyed by `piName`:

| lookup | today | after |
|---|---|---|
| base URL | `providerBaseUrl cfg (providerLabel kp)` / `cfg "ollama"` / `cfg (ocsId spec)` | `providerBaseUrl cfg (piName inst)` |
| default model | same | `providerBaseUrl`-style: `cfg (piName inst)` |
| API key | `vaultKeyName kp` | `providerApiKeyName inst` |
| OAuth read **and write-back** | literal `"ANTHROPIC_OAUTH_TOKENS"` in `resolveProvider`'s `osPersist` | `providerOauthKeyName inst` |

The `osPersist` write-back matters: leaving the literal would make a refresh for
`anthropic-work` overwrite `anthropic`'s tokens.

The #271 §4.6 status rules carry over **applied per instance**, with one
addition: an instance with `piProblem` (or `piType = Nothing`) reports
`authStatus: "none"` **and** the problem string; the UI shows it as a broken row
(editable only to delete / fix the TOML). The invariant stays one-directional
(`none ⇒ not configured`), and `configured`/`authStatus` are computed from the
same `ProviderInstance`, so they cannot disagree.

`resolveDefaultModel` is fixed to resolve **name → section → its type →
the type's built-in default**, `Nothing` when the instance or its type is
unresolvable. Today an unrecognised label falls back to Anthropic's model; after
this change every non-type-named instance would hit that fallback and send
`claude-opus-4-8` to e.g. a local vLLM endpoint.

### 3.5 Sessions, agent defs, defaults

Unchanged schema: `smProvider`, agent-def `provider`, `rcDefaultProvider` hold
an **instance name**. Existing values (type ids) resolve via the implicit
instances. An unknown instance ⇒ the message in §6 (surface-aware), never a
derived vault key.

`POST /api/tabs/new` and `POST /api/sessions` validate the provider against
`providerInstances` (today neither does).

### 3.6 CLI

```
/provider add <type> [name]     # name prompted, default = the type id
/provider list                  # every instance, incl. implicit/broken
/provider test <name>
/provider default <name>
/provider remove <name>
/provider login <name>          # anthropic-typed instances only
/model list [<name>]
/model use <name> <model>
/model default <name> <model>
```

* `add`'s first argument is a **type** (`metavar "TYPE [NAME]"`; the type's help
  lists the catalog). Every other command takes an **instance** name
  (`metavar "NAME"`, "instance name — see /provider list").
* After the type is known, `add` prompts `Instance name [<type-id>]:` (blank =
  the type id), so the feature is discoverable on the default path instead of
  being a hidden upsert.
* The target name is validated **before any vault write**: grammar, reserved,
  `checkNameForType`, cap. Existing same-type instance ⇒
  `Reconfiguring <name> (<type>)` then the normal prompts (matches today's
  upsert); existing different-type instance ⇒ error, nothing written.
* `/provider add groq` (a user instance name where a type is expected) ⇒
  `groq is an instance (openai-compat), not a provider type — run /provider add
  openai-compat groq to reconfigure it, or /provider test groq to test it.`

### 3.7 Gateway API

| endpoint | shape |
|---|---|
| **new** `GET /api/provider-types` | static catalog: `{id, typeDisplayName, baseUrlRequired, baseUrlEditable, defaultBaseUrl, defaultModelRequired, keyPolicy, namePattern, nameExample, builtinModels}` where `keyPolicy ∈ never\|optional\|required\|url-dependent` (Ollama is url-dependent, so the create-mode hint must not claim "keyless" before a URL is typed) |
| `GET /api/providers` | **all instances** (implicit included): `{name, displayName(=name), type: string\|null, typeDisplayName, configured, problem: string\|null}` |
| `GET /api/providers/all` | instance rows + the type flags (`baseUrlRequired`, …) + `problem`; flags are `null` when the type is unresolvable |
| `POST /api/providers` | `{type, name, base_url?, default_model?, api_key?}`; new name = create, existing name **of the same type** = reconfigure (matches today's upsert), different type / reserved / malformed ⇒ `400 {error, field:"name"}` — all **before** the vault write |
| `PUT /api/providers/:name` | partial update; `type` immutable (`400 field:"type"` if sent); 404 for an unknown instance (never synthesise a section) |
| `DELETE /api/providers/:name` | that instance's key + (anthropic) OAuth + deconfigure; 204; 404 when unknown |
| `GET /api/providers/default` / `PUT …/default` | existing routes, now validated against **instances** (today they call `parseProvider` and would 400 on `anthropic-work`) |
| `GET /api/providers/:name/models`, `…/context` | instance-addressed; `/context` is unchanged behaviourally |
| session JSON (`/api/sessions`, `/api/lists`) | **adds** `providerType` (derived from the instance at serialization time; `null` when unresolvable). Not persisted: no `session.json` schema change |

Route plumbing: a new `RouteProviderTypes` in
`src-gateway-types/.../Route.hs` (+ `routeMeta`, `allRoutes`, `OpenApi.hs`,
`ApiRouteSpec`/`OpenApiSpec`). `default`/`all` remain literal routes, which is
why they are reserved names.

`adProviders` stays as an injection seam but becomes
`IO [ProviderInstance]` **and is wired to re-load the config** per call (today
it closes over the boot-time `cfg`, so a newly created instance would not appear
in `/api/providers` until restart).

### 3.8 Frontend

* **List pane**: every instance (implicit and explicit). `authStatus: 'none'`
  and `problem` rows stay visible (a just-created or broken instance must remain
  editable/deletable). Row title = instance name; a subtle type hint when
  `name ≠ typeId` (`work — OpenAI-compatible`), suppressed for type-named
  instances.
* **Create**: pick a **type** from `/api/provider-types`, then a **name**
  (prefilled with the type id, inline validation from the shared `namePattern`,
  `aria-invalid` + `aria-describedby`), then the flag-driven fields. On an
  existing same-type name the button reads "Reconfigure" and a warning names the
  instance; a different type ⇒ inline name error.
* **Edit**: name and type are read-only fields (not a title), with the hint that
  a rename is delete + re-create.
* **Delete**: confirms with instance + type and what it removes
  (`PROVIDER_APIKEY_WORK`, default pointer) and warns that sessions/agent defs
  referring to it will fail.
* **Composers / Agents view**: options are instances (`work — OpenAI-compatible`
  / `Anthropic`), unconfigured ones marked `(not configured)` as today.
* **ActiveTabs**: badge keys off `providerType` (`O` for every openai-compat
  instance, `A` for every anthropic one), `?` + `Unknown provider (<name>)` when
  null.
* **`PROVIDER_LABELS` maps** stop being identity: instance name is the label;
  maps hold *type* display names only.
* Zero-instance state cannot occur (implicit instances), but an all-unconfigured
  list shows guidance: `No provider is configured yet — pick a type above.`

## 4. Copy (new and changed strings)

`<n>` = instance name, `<T>` = type display name, `<id>` = type id,
`<instances>` = comma-separated instance names.

| situation | text | surface |
|---|---|---|
| name prompt | `Instance name [<id>]: ` | CLI |
| name invalid | `instance names are 1–32 characters of a–z, 0–9 and “-” (no leading/trailing “-”); e.g. local-vllm` | CLI, editor |
| name reserved | `“<n>” is reserved — choose another name (e.g. <n>-2)` | CLI, editor |
| name is another type's id | `“<n>” is a provider type id — choose another name, e.g. <n>-personal` | CLI, editor |
| name/type conflict | `“<n>” already exists as a <T2> instance — remove it first, or choose another name` | CLI, REST |
| add confirmation | `Configured <n> (<T>, <url>, model <model>). Run /provider test <n> to verify.` / `Updated <n> (<T>, <url>, model <model>).` | CLI |
| list line | `<n> (<T>) (default) — auth: <status>, base URL: <url>` | CLI |
| list line, broken | `<n> — problem: <problem> (fix or remove this section in config.toml)` | CLI, UI |
| unknown instance (session) | `session uses provider “<n>”, which no longer exists (known: <instances>). Re-create it in the Providers view with the same name, or start a new session with another provider.` | transcript, UI |
| unknown instance (agent def) | `agent def uses provider “<n>”, which no longer exists (known: <instances>). Edit the def's provider line, or re-create “<n>”.` | transcript |
| unknown instance (CLI) | `unknown provider: <n> (known: <instances>)` + the CLI repair `/provider add <type> <n>` | CLI |
| type expected | `<n> is an instance (<T>), not a provider type — run /provider add <id> <n> to reconfigure it, or /provider test <n> to test it.` | CLI |
| login on a non-anthropic instance | `OAuth login is only supported for anthropic instances (got: <n>, <T>)` | CLI |
| delete confirm | `Delete <n> (<T>)? This removes <vault-key> from the vault, clears it as default, and sessions or agent defs using “<n>” will fail until you re-create it or point them elsewhere.` | UI |
| create-mode key hint | `keyPolicy` from `/api/provider-types`; for `url-dependent`: `Optional for a local server; required for a cloud host.` | UI |
| type hint in a dropdown | `<n> — <T>` (suppressed when `<n> == <id>`) | UI |
| no types (impossible) / all unconfigured | `No provider is configured yet — pick a type above.` | UI |

#271's §4.2 rules still apply: browser-reachable text names the Providers view
first and the slash command second.

## 5. File scope

**Haskell**
- **new** `src/Seal/Providers/Name.hs` (`ProviderName`, `mkProviderName`,
  `providerNameText`, `checkNameForType`, `shoutySnake`)
- `src/Seal/Providers/Registry.hs` (instances, per-instance resolution/status,
  key names, ordering, `catalogProblems` additions)
- `src/Seal/Config/File.hs` (`pcType`, codec, helpers; **no** import of Registry)
- `src/Seal/Config/Migrate.hs` (gate the #271 rename on `pcType == Nothing`)
- `src/Seal/Command/{Provider,Model,New,Serve}.hs`
- `src/Seal/ISA/Ops/Session.hs` (default provider; tool copy)
- `src/Seal/Agent/Runtime/Delegation/Worker.hs` (empty `adProvider` default)
- `src/Seal/Session/Store.hs` (`defaultSessionSelection` via instances)
- `src/Seal/Gateway/{API,SessionJson,ListsSnapshot}.hs`
- `src-gateway-types/Seal/Gateway/Types/Route.hs`, `src/Seal/Gateway/OpenApi.hs`
- `seal-harness.cabal` (new module + spec; test-suite `other-modules`)

**Tests**
- **new** `test/Seal/Providers/NameSpec.hs` (+ `test/Main.hs`)
- `test/Seal/Providers/RegistrySpec.hs`, `test/Seal/Config/{FileSpec,MigrateSpec}.hs`
- `test/Seal/Command/{ProviderSpec,ModelSpec,NewSpec}.hs`
- `test/Seal/Gateway/{ApiSpec,ApiRouteSpec,OpenApiSpec,ServerSpec,PatIngestionSpec}.hs`,
  `test/Seal/Phase7aSpec.hs`, `test/Seal/TestHelpers/ApiTestHarness.hs`
- `test/Seal/Session/{StoreSpec,MetaSpec}.hs`

**Frontend** — `types.ts`, `useApi.ts`, `hooks/useNewTabSpec.ts`,
`components/{ProvidersView,NewSessionComposer,NewTabComposer,AgentsView,ActiveTabs,Sidebar,ChatArea}.tsx`,
and every typed fixture (`__tests__/{ProvidersView,NewSessionComposer,NewTabComposer,AgentsView,Sidebar}.test.tsx`,
`__tests__/App.test.tsx`, `hooks/__tests__/{useApi,useNewTabSpec}.test.ts`).

**Docs** — CHANGELOG, this design + plan, `docs/plans/active-plan.md`.

## 6. Testing strategy (RED first) and work units

Strangler rule: the old `KnownProvider`-shaped API stays exported and green
until the unit that migrates its last call site.

**WU-0 — `Seal.Providers.Name` (additive).**
`mkProviderName` accepts `groq`, `work-proxy`, `a1`, `anthropic`; rejects `""`,
`Work`, `work_proxy`, `work.proxy`, `-x`, `x-`, `a--b`, 33 chars, `all`,
`default`, `openrouter`, non-ASCII. QuickCheck (bounded): for accepted names,
`shoutySnake` is injective and the derived keys are pairwise disjoint across
`{apiKey, oauthKey}` **and** from the legacy set. `checkNameForType` allows
`anthropic`/`AnthropicType` and rejects `ollama`/`OpenAICompatType`.
Gate: `make check`.

**WU-1 — config + instances (additive).**
`pcType` round-trips (`FileSpec`); `""` = absent; a `type`-less section named a
legacy id resolves; a bogus `type` yields `piProblem` (not fatal); a
`[providers."we ird"]` foreign key round-trips verbatim; an unresolvable section
**survives an unrelated write**; implicit instances exist for a config with no
sections (and for a config that claims only `anthropic`); ordering is implicit
(catalog order) then explicit (name); the cap. Gate: `make check`.

**WU-2 — registry instances.**
Per-instance base URL/default model/API key/OAuth read+write; two
`openai-compat` instances resolve to different URLs and read different keys;
two anthropic instances with distinct OAuth blobs don't share a slot (refresh of
one leaves the other byte-identical); `checkNameForType` enforced on load;
`resolveDefaultModel` resolves instance → type (never Anthropic's model for an
unknown instance); the §3.4 status invariants per instance, including the
`problem` row; `catalogProblems` additions. Gate: `make check`.

**WU-3 — CLI.**
`add <type> [name]` (prompted; blank = type id), name/type/reserved/cap
validation **before** any vault write, same-type reconfigure, different-type
rejection, `add groq` (instance-where-type-expected) message; `list` shows
instances incl. implicit and broken; `test`/`remove`/`default`/`login` by
instance; `remove` touches only that instance's credentials; `/model *` by
instance; `new -p` / agent-def / `ISA/Ops/Session` default resolution; the copy
table asserted verbatim. Gate: `make check`.

**WU-4 — gateway + routes.**
`RouteProviderTypes` (+ meta/allRoutes/OpenApi/route specs); `/api/provider-types`
flags and `keyPolicy`; `/api/providers` lists implicit + explicit instances and
is **fresh** after a POST; `/all` rows incl. `problem`; POST validation table
(malformed, reserved, another type's id, type mismatch, cap, missing required
field) each **without** a vault write; PUT immutability of `type`, 404 unknown;
DELETE scope (sibling untouched); default endpoints accept instance names;
`tabs/new` + `POST /api/sessions` reject unknown instances; session JSON carries
`providerType` derived from the instance. Gate: `make check`.

**WU-5 — frontend.**
Type picker + name field (prefill/inline validation/`aria-describedby`),
reconfigure warning, read-only name/type, delete confirm copy, list shows
unconfigured + problem rows, two instances of one type render distinctly in the
list **and** both composers, badges by `providerType` with the `?` fallback,
empty/all-unconfigured guidance. Gates: `make check` (tsc) + `make frontend-test`.

**WU-6 — docs/CHANGELOG.** Including the upgrade note (nothing to do) and the
model change. Gate: `make check`.

**Metrics (falsifiable)**
- **M1** A pre-change `config.toml` (three legacy sections) + legacy vault keys
  produce the same usable set: same names, URLs, models, `authStatus`, and the
  file is **not rewritten** (`FileSpec`/`RegistrySpec` fixture).
- **M2** Derived vault names are pairwise disjoint over `{apiKey, oauthKey}` ∪
  legacy set ∪ catalog keys (QuickCheck, WU-0).
- **M3** Creating a second instance of **any** catalog type requires zero
  Haskell changes (the type catalog is data; asserted by the injected-catalog
  tests and a diffstat at step 3).

## 7. Security

1. **Instance names are operator-created, never model-created.** A
   model-supplied `provider` string (agent def, `SESSION_*`) is a **lookup key**;
   a miss is an error and never falls back to deriving a vault key.
2. **Name grammar is an allow-list applied to raw text** (no normalisation), used
   for both the TOML key and the vault key; reserved words cover the literal
   routes and the legacy migration id.
3. **Credential namespaces are disjoint by construction** (`PROVIDER_APIKEY_*` /
   `PROVIDER_OAUTH_*` / legacy `<TYPE>_API_KEY`), enforced by a QuickCheck and by
   `catalogProblems`.
4. **No cross-instance reads or writes**: base URL, key, OAuth read *and*
   write-back all come from the same `ProviderInstance`.
5. **No opcode** reads or writes `~/.seal/`; this design adds no new write path
   (`config.toml` writes stay in the CLI/gateway through `updateRuntimeConfig`).
6. Instance count is capped (64) — the deferred mutation guard leaves instance
   creation operator-gated today, but the cap also bounds the per-instance vault
   read in `/api/providers/all`.
7. #271's deferrals (REST mutation guard, listener binding, redaction, metadata
   floor) are unchanged; the security PR inherits one delta: instance names now
   appear in `runtime`/`/api/secrets`.

## 8. Risks

| Risk | Mitigation |
|---|---|
| Legacy config/keys break | implicit instances + frozen legacy type set + unchanged vault names; M1 |
| Name→vault-key collision | two distinct prefixes + allow-list grammar + QuickCheck; `catalogProblems` prefix rule |
| Name collides with a route or the legacy migration | reserved words (`all`, `default`, `openrouter`); migration gated on `pcType == Nothing` |
| Two instances share a config section | every per-instance lookup keyed by `piName`; §3.4 table is the checklist, WU-2 tests it |
| `adProviders` serving a boot-time snapshot | wire it to reload per call; WU-4 freshness test |
| Bigger diff on an already-large PR | WU-0/1 are additive; the strangler rule keeps each commit green |
| Session on a deleted instance | surface-aware error naming the instance, the known ones, and a reachable repair |

## 9. Revision 3 — corrections (authoritative; supersedes the noted parts above)

Design-gate round 2 found five blockers, two of which would have shipped real
bugs. These rules win over any conflicting sentence above.

### 9.1 Module layout (fixes the `Name ↔ Registry` cycle)

`Seal.Providers.Name` is a **leaf** and owns the *text-level* rules:

```haskell
newtype ProviderName = ProviderName Text   -- ctor unexported
mkProviderName   :: Text -> Either Text ProviderName
providerNameText :: ProviderName -> Text
shoutySnake      :: ProviderName -> Text
-- Legacy carve-out is decided by the caller, which knows the type:
apiKeyNameFor    :: ProviderName -> Text -> Text      -- name → own type id
oauthKeyNameFor  :: ProviderName -> Text -> Text
checkNameForType :: ProviderName -> Text -> Either Text ()  -- type id as Text
```

`ProviderType` / `providerTypes` / `typeId` stay in `Registry`; `Name` never
imports it. Registry wraps the text helpers for instance-shaped convenience
(`providerApiKeyName :: ProviderInstance -> Text` = `apiKeyNameFor`). WU-0's
property tests exercise the **real** derivation, not a copy.

### 9.2 Instances are `Text`-named, with validity separate (fixes hand-edited names)

```haskell
data ProviderInstance = ProviderInstance
  { piName      :: !Text                  -- raw section key / implicit type id
  , piNameValid :: !(Maybe ProviderName)  -- Nothing ⇒ invalid or reserved (§9.6)
  , piType      :: !(Maybe ProviderType)  -- Nothing ⇒ unresolvable
  , piConfig    :: !ProviderConfig
  , piProblem   :: !(Maybe Text)          -- human-readable; surfaced, never fatal
  }
```

Hand-edited sections (`[providers."we ird"]`, `[providers.default]`) therefore
**appear** as problem rows (with `piNameValid = Nothing`) and are deletable by
their raw name; reserved words and the grammar are enforced only at **creation**
entry points, never at load.

### 9.3 Type resolution: absent ≠ unknown (fixes the silent downgrade)

* `pcType` absent or `""` ⇒ back-compat fallback: the section name is in the
  frozen legacy set `{anthropic, ollama, openai-compat}` ⇒ that type;
  otherwise `piType = Nothing` + `piProblem = "has no type and its name is not a
  provider type"`.
* `pcType` **present but unknown** ⇒ `piType = Nothing` +
  `piProblem = "unknown provider type: <value>"`. Never falls back, never is
  ignored.
* `pcType` matching is **case-folded on the trimmed value** (so `"Anthropic"` is
  the anthropic type, not a problem row), but the **credential derivation uses
  the canonical `typeId`** — never the raw text (§9.5).

### 9.4 Precedence and the hardcoded defaults (fixes the shadowing contradiction)

One row per name. A section claiming a name **is** that instance; an implicit
instance is synthesized only for a type id no section claims. If the section's
type differs from the type whose id it claims (`[providers.anthropic] type =
"ollama"`), it keeps `piType = Just OllamaType` **and** `piProblem = "section
named \"anthropic\" is not an anthropic instance"`; `resolveInstance` returns
`Left problem` for any instance with `piProblem`.

Consequence, stated: `defaultSessionSelection`'s `"anthropic"` (and
`SESSION_*`'s, and delegation's `"ollama"`) then resolve to that **broken** row
and fail with the problem text — never silently to another endpoint. The
sentence above (§3.1) promising "rather than shadowing that type's default" is
withdrawn.

### 9.5 Credentials: canonical type, total derivation

* Legacy key iff `piType == Just t && piName == typeId t`; otherwise the
  prefixed form. Compared against the **canonical** `typeId`, never `piTypeId`.
* `piType = Nothing` ⇒ **no vault access at all**: no key read, no key delete,
  no OAuth; `resolveInstance` is `Left piProblem`; `/models` returns `[]`.
* `DELETE` semantics per row class (stated, and asserted in WU-4):

| row class | section | credentials | row after |
|---|---|---|---|
| explicit, name ≠ its type id | removed | its API key + (anthropic) OAuth | gone |
| type-named (explicit section) | removed | its API key + (anthropic) OAuth | stays, as the implicit *not configured* row |
| type-named (no section) | — | its API key + (anthropic) OAuth | stays, not configured |
| broken (no/invalid type) | removed | **none** (the type is unknown, so we cannot know which key name applies; `/vault delete` is the manual path) | gone |

Default pointers are cleared when the deleted instance was the default.

### 9.6 Reserved names

Reserved: **`all`, `default`** only (the literal gateway routes). `openrouter`
is **not** reserved: it is step 3's preset id, and reserving it would make that
catalog row fail `catalogProblems`. Migration safety comes from the gate in
§9.7, not from the reservation. A name equal to a type id is legal only for
*that* type (creation-time check).

`catalogProblems` keeps: `ocsId` is a valid `ProviderName`; `ocsId ∉
{anthropic, ollama}`; `ocsVaultKey`s pairwise distinct; no `ocsVaultKey` starts
with `PROVIDER_` or collides with the legacy keys.

### 9.7 Migration (the #271 rename)

`providerRenameMigration` must (a) merge into the destination instead of
replacing it — `Map.adjust` preserving `pcType` and every future key; synthesize
only when the destination is absent; (b) **skip the section move** when *either*
the `openrouter` section or the `openai-compat` destination carries an explicit
`type`; (c) still rewrite `default_provider = "openrouter"` (that id must not
survive as a session default). A hand-written, `type`-less
`[providers.openrouter]` is still treated as legacy and renamed — documented in
the CHANGELOG.

### 9.8 Configure vs reconfigure (the predicate, stated once)

`isConfiguredInstance inst` = the instance has a section **or** a stored
credential. `reconfiguring` = `isConfiguredInstance` — *not* mere existence
(implicit instances always exist). The CLI prints `Configured <n> …` on the
first path and `Updated <n> …` on the reconfigure path; `POST /api/providers`
returns `201` for create and `200` with `reconfigured: true` for reconfigure;
the editor's button reads **Configure** or **Reconfigure** accordingly.

### 9.9 Corrected security section (§7 supersedes §7 above)

1. Instance names are operator-**validated**, not operator-authored: a
   model-supplied `provider` string (`AGENT_DEF_WRITE`, `SESSION_*`) is a lookup
   key; a miss is an error and never derives a vault key. **`SECRET_MANAGE` is a
   pre-existing Trusted opcode that can read/write any vault key by name, and
   `SHELL_EXEC` can write `config.toml`** — this design neither fixes nor widens
   that; it is on the deferred security list.
2. The grammar is an allow-list on raw text; used for the TOML key and the
   derived credential name.
3. Credential namespaces are disjoint **by construction** (`PROVIDER_APIKEY_*` /
   `PROVIDER_OAUTH_*` / legacy `<TYPE>_API_KEY`), asserted in the test suite
   (`catalogProblems` is test-time, not boot-time). Disjointness is a property
   of *our derivation*, not an authorization boundary.
4. No cross-instance reads or writes: base URL, key, OAuth read **and**
   write-back all come from the same `ProviderInstance` (site list in §9.10).
5. No **opcode** reads or writes the agent-immutable `~/.seal/` subset named in
   AGENTS.md rule 3 (`security.toml`, `exec-known-hosts`, `keys/`,
   `config/vault/`, `ssh-mux/`); `SECRET_MANAGE` (vault) and session/memory state
   are the pre-existing exceptions. This design adds **no new write path**.
6. Cap: **64 `[providers.*]` sections** (implicit rows don't count), enforced at
   the CLI and gateway creation paths; loading more loses none.
7. Security-PR delta (recorded, not fixed here): on the unauthenticated,
   `ACAO: *` REST surface the set of **repointable** credentials grows from 2 to
   N (`POST/PUT {base_url}` on an existing instance keeps its key), `DELETE` can
   destroy any instance's credential, and `/api/secrets` reveals the derivable
   `PROVIDER_APIKEY_<SHOUTY>` names. #271's "neither introduces nor worsens" no
   longer holds and must not be quoted.

### 9.10 The per-instance lookup checklist (exhaustive; the grep result)

Every read/write below takes the `ProviderInstance` (never a type id, never a
`KnownProvider`): `providerBaseUrl cfg (piName inst)`,
`providerDefaultModel cfg (piName inst)`, `providerApiKeyName inst`,
`providerOauthKeyName inst`. Sites:

* `Registry`: `providerBaseUrlFor`, `providerAuthStatus`, `configuredProvidersFor`
  (including the two reads that today use `ocsVaultKey spec` directly), the
  anthropic OAuth read **and** the `osPersist` write-back, `resolveProvider`,
  `resolveDefaultModel`.
* `Command.Provider`: add/remove/login (OAuth write + delete)/test/default/list.
* `Gateway.API`: `providerDetailValue`, `keyOptionalFor`, `validateProviderWrite`,
  `handleProviderDelete`, `staticModelsFor`, `providerModelsJson`,
  `handleTabNew`, `handleSessionNew`, both default endpoints.
* `Session.Store.defaultSessionSelection`, `Command.New`, `Command.Model`,
  `ISA.Ops.Session`, `Agent.Runtime.Delegation.Worker`.

`anthropicOAuthKey` gets **one** definition site (Registry re-export); the
duplicate in `Command/Provider.hs` is deleted. WU-2's gate includes:
`rg -n 'vaultKeyName|anthropicOAuthKey|ocsVaultKey|_API_KEY' src/` returns no
provider-credential site reachable without a `ProviderInstance`.

### 9.11 Property tests, corrected (the rev-2 M2 was unsatisfiable)

Three separate properties, using the real functions:

1. distinct accepted names ⇒ distinct `apiKeyNameFor` results, and distinct
   `oauthKeyNameFor` results (bounded QuickCheck over the grammar);
2. for `name ≠ typeId`, both derived names ∉ legacy set ∪ every
   `ocsVaultKey` in `openAICompatSpecs` (run in `RegistrySpec`, which can see the
   catalog);
3. for `name == typeId`, the derived API-key name **equals** that type's legacy
   key (asserted, not excluded).

Plus a hand-written regression pair `x` / `x-oauth-tokens`, and the structural
note that the grammar excludes `_` so the two prefixes cannot alias.

### 9.12 Work-unit order, corrected

* **WU-0** `Seal.Providers.Name` (additive): grammar, reserved, text-level key
  derivation, `checkNameForType`, properties §9.11 1–3.
* **WU-1** config (`pcType`) **+ `Config/Migrate.hs` and `MigrateSpec` in the
  same unit** (the schema change makes `applyRename`'s record construction and
  `FileSpec`'s positional fixtures fail otherwise) + `providerInstances`
  (implicit/explicit/problem rows, ordering by catalog position then name,
  >64 sections lose none) + the §9.7 gate.
* **WU-2** registry: `ProviderType` **alongside** `KnownProvider` with
  `toProviderType` (strangler), `resolveInstance`, per-instance key names and
  lookups (§9.10), `configuredInstances`, `resolveDefaultModel`,
  `catalogProblems` additions, the OAuth write-back seam
  (`buildOAuthSession :: ProviderInstance -> … -> IO OAuthSession`) so the
  two-anthropic-instances test needs no network.
* **WU-3** CLI (instance names, configure/reconfigure predicate, per-class delete
  copy, cap, help/`progDesc`s).
* **WU-4** gateway + routes (`RouteProviderTypes`, `/api/provider-types`,
  `/api/providers` incl. `isDefault`, `/all` incl. `problem`, POST/PUT/DELETE,
  default endpoints, `/models` per instance, `tabs/new` + sessions validation,
  session `providerType` derived once per snapshot, `adProviders` reload with
  `configured`).
* **WU-5** frontend (types incl. `providerType?: string | null`,
  Providers view, composers, Agents view, ActiveTabs title = `<n> — <T>`,
  the four extra `SessionInfo` fixtures).
* **WU-6** remove the `KnownProvider`-shaped API + docs/CHANGELOG.

## 10. Revision 4 corrections (authoritative; supersedes §3.2, §3.3, §3.7, §9.1,
## §9.5, §9.8, §9.9, §9.10, §9.11, §9.12 where they conflict)

Design-gate round 3. All five reviewers confirmed the round-2 semantics are
sound; these are the remaining mechanical and type-level fixes. Where a rule
below contradicts an earlier sentence, this section wins.

### 10.1 Credentials are resolved, not derived from raw text

`Seal.Providers.Name` stays a leaf and owns *only* the text rules. The legacy
carve-out needs catalog data, so it is an **explicit input**:

```haskell
-- Name.hs (leaf)
apiKeyNameFor   :: Maybe Text -> ProviderName -> Text -> Text
--                legacyKey?      name          canonical type id
oauthKeyNameFor :: Maybe Text -> ProviderName -> Text -> Text
```

`Registry` supplies `legacyKeyFor :: ProviderType -> Maybe Text` (anthropic →
`ANTHROPIC_API_KEY`, ollama → `OLLAMA_API_KEY`, catalog row → its
`ocsVaultKey`). Text-level derivation is a total function of its inputs; the
**instance level is partial** so "no vault access" is a type fact, not a
convention:

```haskell
data ProviderCredentials = ProviderCredentials
  { pcApiKeyName   :: !Text
  , pcOauthKeyName :: !(Maybe Text)   -- Just only for anthropic-typed rows
  }

-- 'Nothing' ⇒ the row must not touch the vault at all.
instanceCredentials :: ProviderInstance -> Maybe ProviderCredentials
```

`instanceCredentials` returns `Nothing` when `piNameValid = Nothing` **or**
`piType = Nothing` **or** `piProblem ≠ Nothing`. Every vault read/write
(`resolveInstance`, status probes, `/provider login`, create/update/delete,
`resolveSessionProvider`/`resolveDefProvider`) goes through it. A spy vault that
records calls must show **zero** calls for such rows (a `Left` result alone does
not prove it).

`catalogProblems` gains the forward check
`legacyKeyFor (OpenAICompatType s) == Just (ocsVaultKey s)` and
`ocsVaultKey == SHOUTY(ocsId) <> "_API_KEY"` for the catalog rows, so the
coincidence that makes type-named instances work is guarded for step 3.

### 10.2 Instance record: keep the raw type text

```haskell
data ProviderInstance = ProviderInstance
  { piName      :: !Text
  , piNameValid :: !(Maybe ProviderName)
  , piTypeId    :: !(Maybe Text)          -- raw `type` value, for display
  , piType      :: !(Maybe ProviderType)
  , piConfig    :: !ProviderConfig
  , piProblem   :: !(Maybe Text)
  }
```

`piNameValid = Just n ⇒ providerNameText n == piName` (no normalisation, §3.2).
`type = "Anthropic"` displays as `Anthropic` but resolves/key-derives on the
canonical `anthropic`.

### 10.3 Row taxonomy is total (six classes)

| class | name | type | section | credentials | delete effect | row after |
|---|---|---|---|---|---|---|
| A | valid, `== typeId t` | `Just t` | yes | legacy key + (anthropic) OAuth | remove section, delete credentials, clear default\* | stays (implicit, not configured) |
| B | valid, `== typeId t` | `Just t` | no (implicit) | legacy key + (anthropic) OAuth | delete credentials, clear default\* | stays (not configured) |
| C | valid, `≠ typeId` | `Just t` | yes | `PROVIDER_APIKEY_*` (+ `PROVIDER_OAUTH_*`) | remove section, delete credentials, clear default\* | gone |
| D | valid, `≠ typeId` | `Nothing` | yes | **none** | remove section | gone |
| E | invalid/reserved | `Just t` **or** `Nothing` | yes | **none** (`instanceCredentials = Nothing`) | remove section | gone |
| F | valid, `== typeId x` but declares `t ≠ x` (§9.4 mismatch) | `Just t` | yes | **none** (`piProblem` ⇒ no vault access) | remove section | gone |

\* only when it was `default_provider`; `rcDefaultModel` is cleared with it
(today's behaviour).

Class F deliberately does **no** credential work: deleting
`PROVIDER_APIKEY_ANTHROPIC` would leave the real `ANTHROPIC_API_KEY` behind and
tell the operator it was removed. The error/confirm copy names the section
removal and, for D/E/F, points at `/vault delete` for any credential the
operator may have stored.

`PUT /api/providers/:name` on D/E/F is rejected with
`{error: "this instance's configuration is invalid — fix or delete the section
in config.toml", field: "type"}`; DELETE is allowed per the table.

### 10.4 Configure vs reconfigure, and the API carrier

`isConfiguredInstance inst` = (class A or C: a section exists) **or** (a
credential exists) — and **always `False`** for classes D/E/F (§3.4's
`none ⇒ not configured` invariant is unchanged).

The API carries it: both `/api/providers` and `/api/providers/all` rows include
`reconfiguring: boolean` (= `isConfiguredInstance`). The editor's button label,
the CLI's `Configured`/`Updated` copy and the POST `200 {reconfigured:true}`
all read the same predicate.

### 10.5 Migration: source-only gate, three states, merge wins destination

`providerRenameMigration` classifies, in order:

1. no `[providers.openrouter]` and no `default_provider = "openrouter"` ⇒
   `Nothing` (no-op);
2. `[providers.openrouter]` present **and** it carries a `type` ⇒ it is an
   ordinary instance; **leave the section and the pointer alone** (a type id is
   never both a legacy section and an instance, and the pointer must not be
   repointed behind the operator's back) ⇒ `Nothing`;
3. otherwise ⇒ `Just` one of `MoveAndDefault` (section present, type-less) or
   `DefaultOnly` (pointer only), with distinct messages.

The move **merges** into the destination with `Map.adjust` (destination wins per
field, `pcType` and every future key preserved; synthesize only when the
destination is absent) and logs a one-line warning when the destination's
`base_url`/`default_model` differed. `default_provider = "openrouter"` is
rewritten to `openai-compat` only in states 3 (`DefaultOnly` included).

### 10.6 Copy additions (extends §4; WU-3/WU-5 assert these)

| situation | text |
|---|---|
| cap | `at most 64 provider instances — remove one first (/provider remove <n>)` (CLI) / `400 {error, field:"name"}` (REST) |
| delete confirm, class A/B | `Delete <n> (<T>)? This removes <keys> from the vault<default-clause>. The <T> instance stays in the list, not configured.` |
| delete confirm, class C | `Delete <n> (<T>)? This removes <keys> from the vault<default-clause>, and sessions or agent defs using “<n>” will fail until you re-create it or point them elsewhere.` |
| delete confirm, classes D/E/F | `Delete <n>? This removes the config.toml section. Its provider type is unknown, so any credential stored for it must be deleted manually (/vault delete <name>).` |
| `<default-clause>` | `, clears it as default` **only when** the instance is the default |
| `<keys>` | the API key name; `A and B` for an anthropic instance with OAuth |
| problem-row turn error | `provider “<n>” is misconfigured: <problem> — fix or delete the section in config.toml` |
| unknown instance (CLI) | `unknown provider: <n> (known: <instances>)` — **no** `<type>` placeholder; the repair is `/provider list` |
| agent def repair | `agent def uses provider “<n>”, which no longer exists (known: <instances>). Set the Provider field in the Agents view, or re-create “<n>”.` |
| list line | `<n> (<T>) (default) — auth: <status>, base URL: <url \| not set>` |
| `add` progDesc | `Create or update a provider instance (type, name, credentials)` |
| `list` progDesc | `List provider instances and their credential status` |
| `remove` progDesc | `Remove a provider instance's credentials` |
| type field (read-only) | `A provider's type can't change — delete and re-create to change it` |
| broken list line (UI) | `… — fix or delete it here, or edit config.toml` |
| reconfigure warning | `You're updating “<n>” (<T>). To add another <T> instance instead, change the name.` |
| no-provider banner | `No provider is configured yet — add one from the type picker.` (banner above the list; list stays) |

### 10.7 §9.9 (security) — replace the rule-3 wording

AGENTS.md rule 3 says no opcode may ever read or write files under `~/.seal/`.
That is **already violated by two pre-existing paths** and this design records
them rather than narrowing the rule:

* `SECRET_MANAGE` (Trusted) reads/writes `~/.seal/config/vault/`;
* `SHELL_EXEC`/`BIN_EXEC` can write `~/.seal/config/config.toml`;
* the REST `/api/secrets` mutations (unauthenticated, `ACAO: *`) write and delete
  **any** vault key by name.

This design adds **no new write path** under `~/.seal/` and does not change
those three. The security-PR delta is: instance names are **operator-authored,
creation-validated, not load-validated**; credential *target names* become
enumerable (`namePattern` is public, instances are listed) on a surface that can
already write them; the set of credentials repointable via
`PUT {base_url}` (which keeps a stored key) grows 2→N — i.e. operator-key
exfiltration to an attacker-chosen host, not merely "repointing";
`GET /api/providers/all` does one vault read per instance (≤64);
broken rows' credentials can no longer be deleted from the UI/CLI (they orphan).

### 10.8 Site checklist (supersedes §9.10) and its gate

Credential **and** config reads/writes that must take a `ProviderInstance`:
`Registry.{resolveInstance, providerBaseUrlFor*, providerDefaultModel*,
providerAuthStatus*, configuredProviders*, resolveDefaultModel*}`,
`Command.Provider.{add, remove, login, test, default, list,
resolveSessionProvider, resolveDefProvider}`, `Command.Model.{list, use,
default}`, `Session.Store.defaultSessionSelection`, `Command.New`,
`Gateway.API.{providerInfoJson, providerDetailValue, handleProvidersAll,
keyOptionalFor, validateProviderWrite, handleProviderCreate,
handleProviderUpdate, handleProviderDelete, providerModelsJson, handleTabNew,
handleSessionNew, both default endpoints}`, `Command.Serve.adProviders`,
`Gateway.SessionJson` / `ListsSnapshot`.

`Channel.Cli`, `ISA.Ops.Session` and `Delegation.Worker` are **label producers
only** — no change (they emit `"anthropic"`/`"ollama"` names that resolve as
implicit instances).

Gate (replaces §9.10's): `rg -n 'vhGet|vhPut|vhDelete|hasVaultKey|readKeyIfAny|
probeVault' src/` — every hit must be inside a function that takes
`ProviderCredentials` (not a name, not a `KnownProvider`), plus
`rg -n 'vaultKeyName|ocsVaultKey|anthropicOAuthKey' src/` empty outside the
catalog definitions. Cycle guard: a source-grep test asserting
`Seal.Providers.Name` imports no `Seal.Providers.*` module (precedent:
`test/Seal/CapabilityScopingWorkdirFsFailSpec.hs`).

### 10.9 Properties (supersedes §9.11)

1. `∀ n m. apiKeyNameFor a n t ≠ oauthKeyNameFor b m u` (cross-role, sampled over
   the grammar) — this is the rev-2 bug class and was previously argued, not
   asserted.
2. distinct names ⇒ distinct derived api-key names, and distinct oauth names;
3. `name ≠ typeId` ⇒ both derived names ∉ every legacy key ∪ every catalog
   `ocsVaultKey`;
4. `name == typeId t` ⇒ the derived api-key name **equals** `legacyKeyFor t`
   (asserted for anthropic, ollama **and** the catalog row);
5. `legacyKeyFor (OpenAICompatType s) == Just (ocsVaultKey s)` for every catalog
   row.

### 10.10 Plan corrections (WU order)

* **WU-2 also owns `src/Seal/Session/Store.hs` + `StoreSpec`** (`resolveDefaultModel`
  consumer). Keep `resolveDefaultModel`'s old signature as a thin adapter that
  resolves the instance and delegates; add `resolveDefaultModelFor :: RuntimeConfig
  -> Text -> Maybe ModelId`. The adapter dies in WU-6.
* **Session `providerType`: `buildListsSnapshot` loads the config itself** (one
  load per snapshot, no `SendDeps`/`StreamGuard` signature change, no
  `Broadcast`/`Send`/`Stream` ripple). State "one load per snapshot" in WU-4.
* **WU-0**: property 3/4/5 move to WU-1/WU-2 (where `RegistrySpec` lives); WU-0
  keeps 1–2 and its DoD becomes "no module under `src/` imports `Seal.Providers.Name`".
* **WU-1** adds the type-less non-legacy row (`[providers.groq]` ⇒ problem row,
  §9.3), the class E/F fixtures, and the migration's three states + message
  assertions.
* **WU-2** adds `openrouter` is accepted by `mkProviderName` and appears in the
  catalog checks; `instanceCredentials` returns `Nothing` for D/E/F with a
  recording vault asserting **zero** calls; two-anthropic refresh asserts the
  recorded call **sequence**, not just the other blob.
* **WU-4**: `/models` for an unknown/problem instance ⇒ `[]`; name the rewritten
  suites (`ApiSpec`, `ServerSpec`, `PatIngestionSpec`, `Phase7aSpec`); add
  `defaultModel` to both provider payloads (the composers read it) or delete the
  read in WU-5; add the reserved-name route test (`DELETE /api/providers/default`
  removes the section, POST/PUT return `400 field:"name"`).
* **WU-5**: post-delete row states asserted (A/B stays not-configured, C/D/E/F
  removed); problem rows excluded from pickers (disabled, not selectable) and
  from the composer's default fallback; an upgrade fixture (three legacy
  sections → same names/badges, no problem rows); `chatArea` is fixture-only.
* **WU-6** gate widens to every legacy symbol (`parseProvider`, `parseProviderIn`,
  `toProviderType`, `vaultKeyName`, `knownLabelList`, `configuredProviders(+For)`,
  `providerAuthStatus`, `defaultModelFor`, `providerDisplayName`, `providerLabel`,
  `missingBaseUrlMsgFor`, `legacyProviderHint`, `resolveProvider`,
  `resolveDefaultModel`) in `src/` **and** `test/`.

## 11. Revision 5 — simplifications adopted after the plan gate

The scope review passed and argued three items down; adopting all of them, plus
the mechanical fixes the other two reviewers found. **This section supersedes
§10 where it conflicts** (in particular §10.3's six-class taxonomy, §10.6's cap
row, §3.7's `/api/provider-types`, and §10.8's gate wording).

### 11.1 Delete semantics: two axes, not six classes

```haskell
data ProviderInstance = ProviderInstance
  { piName      :: !Text
  , piNameValid :: !(Maybe ProviderName)
  , piTypeId    :: !(Maybe Text)
  , piType      :: !(Maybe ProviderType)
  , piConfig    :: !ProviderConfig
  , piProblem   :: !(Maybe Text)
  , piHasSection :: !Bool          -- explicit in config.toml?
  }
```

`instanceCredentials :: ProviderInstance -> Maybe ProviderCredentials` is
`Just` only when `piNameValid`, `piType` are `Just` **and** `piProblem` is
`Nothing` — i.e. classes A, B and C. Everything else (D/E/F: unknown type,
invalid/reserved name, name/type mismatch) has **no credentials and no vault
access**, and there is nothing to distinguish between them for delete purposes.

DELETE therefore has exactly three behaviours:

| instance | effect |
|---|---|
| credentials `Just`, has section | remove the section, delete those credentials, clear default pointers if it was the default |
| credentials `Just`, no section (implicit) | delete those credentials, clear default pointers if default; the row stays as *not configured* |
| credentials `Nothing`, has section | remove the section only; copy points at `/vault delete` for anything the operator stored manually |
| credentials `Nothing`, no section | cannot happen (an implicit row always has both) |

No class F special case is needed: a mismatch row has `piProblem ≠ Nothing`, so
`instanceCredentials = Nothing` and its delete removes only the section — the
real `ANTHROPIC_API_KEY` is never touched (and the copy says so).

### 11.2 No `/api/provider-types`, no cap

* Every type already has an **implicit instance**, so "pick a type" is picking
  the row named after the type id (`/api/providers/all` already carries
  `baseUrlRequired`, `baseUrlEditable`, `defaultBaseUrl`, `keyOptional`,
  `defaultModelRequired`). The create flow lists the **implicit, unconfigured**
  rows as its type choices; no new endpoint, no new route, no second source of
  truth for the flags.
* The name grammar is **one** constant mirrored in one TS constant, with a shared
  accept/reject table test.
* For an Ollama-typed instance the API-key hint is neutral in create mode
  (`required for a cloud host; blank is fine for a local server`); in edit mode
  the row's `keyOptional` (computed from that instance's URL) is authoritative.
* **The 64-instance cap is dropped.** It was unenforceable (load must not drop
  sections) and therefore not a bound. `/api/providers/all` does one vault read
  per instance; that cost is inherent to listing instances and is noted in the
  security delta instead.

### 11.3 `checkNameForType` takes the type-id set

`Seal.Providers.Name` is a leaf and cannot know other types, so:

```haskell
checkNameForType :: [Text] -> ProviderName -> Text -> Either Text ()
--                  known type ids  name        its own type id
```

`Registry` passes `map typeId providerTypes`. A name equal to *another* type's
id is rejected; equal to *its own* is allowed.

### 11.4 `adProviders` is deleted, not re-typed

`ApiDeps.adProviders` is read only by `GET /api/providers`, which can load the
config and compute `configuredInstances` itself (as `handleProvidersAll` already
does). Deleting the field removes the boot-time staleness *and* avoids re-typing
~30 test literals (they lose the field binding instead).

### 11.5 `legacyProviderHint` survives WU-6

The #271 migration rewrites `config.toml` but not `session.json`; the hint is the
only repair path for a pre-#271 session. It stays (folded into the
unknown-instance message) — WU-6 must **not** delete it.

### 11.6 Problem rows are refused at session creation

`POST /api/sessions` and `POST /api/tabs/new` reject an instance with
`piProblem ≠ Nothing` (not just an unknown name), so a session cannot be created
on a row that is guaranteed to fail every turn.

### 11.7 Non-goal added

**Repointing an existing session's provider from the web UI** is out of scope
(the CLI already has `/model use <instance> <model>`; there is no REST endpoint
for it today, for any provider). Recorded here and in the CHANGELOG.

### 11.8 Corrected gate greps (WU-2 / WU-6)

* WU-2 (scoped, satisfiable): every provider-credential site in `Registry`,
  `Command.Provider`, `Command.Model`, `Gateway.API` reads its key names from
  `ProviderCredentials` — asserted by the recording-vault tests, not by a
  repo-wide grep (unrelated `vhGet` hits exist in `Security/Vault`,
  `SourceControl/Clone`, `ISA/Ops/Secret`, `Vault/Commands`).
* WU-0 cycle guard: `Seal.Providers.Name` imports no `Seal.Providers.*` and no
  `Seal.Config.*` module (source-grep spec). The opposite direction (nobody may
  import `Name`) is **wrong** — `Registry` must import it from WU-1 onward.
* `Config/File.hs` must not import `Seal.Providers.Registry` (guard test in
  WU-1).
* WU-6 greps are word-anchored and avoid substring pairs:
  `rg -w 'KnownProvider|knownProviders|parseProviderIn|toProviderType|vaultKeyName|knownLabelList|configuredProvidersFor|providerAuthStatus|defaultModelFor|missingBaseUrlMsgFor|resolveProvider'`
  in `src/` and `test/`. (`resolveDefaultModel` is excluded: the retained
  `resolveDefaultModelFor` contains it.)
