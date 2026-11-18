# Design — OpenAI and Ollama Cloud provider types

**Status:** draft - revision 5, round 4 in progress.

Gate history:

| Round | Result |
|---|---|
| 1 | 4/5 NEEDS_REVISION (Security APPROVED) |
| 2 | 3/5 NEEDS_REVISION, 2 APPROVED |
| 3 | 2 APPROVED, 3 NEEDS_REVISION (all blockers fixed) |
| 4 | Designer **APPROVED**, Product Manager **APPROVED**; Architect, CTO and Security outstanding |

All blockers from rounds 1-3 are addressed and each is pinned by a numbered
test. Round 4 re-review is running against this text; the design is not approved
until 5/5 return APPROVED.
**Date:** 2026-11-18
**Branch:** `providers/openai-and-ollama-cloud`

## 1. Problem

The setup wizard's *Choose an LLM provider* step and the Providers page's
*New provider* form both offer four choices: Anthropic, Ollama, OpenRouter,
and OpenAI-compatible. Two obvious destinations are missing:

- **OpenAI** (`https://api.openai.com/v1`) — the single most requested
  provider (original issue #14). Today an operator must select the generic
  "OpenAI-compatible" row, then type `https://api.openai.com/v1` into a Base
  URL field and `openai` into a Unique name field — two pieces of information
  the product already knows.
- **Ollama Cloud** (`https://ollama.com/v1`) — Ollama's hosted inference,
  reachable directly over an OpenAI-compatible API with no local install
  (`docs.ollama.com/api/openai-compatibility`: `base_url="https://ollama.com/v1"`,
  key from `https://ollama.com/settings/keys`). Today this is reachable only by
  selecting *Ollama* and typing `https://ollama.com` as the base URL, which
  routes through the **native Ollama protocol**, not the OpenAI-compatible one.

**Measurable benefit.** Setting up OpenAI drops from *two typed fields plus one
recalled URL* (select the generic row, paste `https://api.openai.com/v1`, invent
a unique name) to *one paste of an API key*, with zero base-URL typos and no
invented id. Ollama Cloud stops requiring the operator to know that
`https://ollama.com` is an OpenAI-compatible endpoint reachable through a
different protocol than the local daemon.

Both new types reuse the existing OpenAI-compatible infrastructure
(`Seal.Providers.OpenRouter.mkOpenAICompatible`). No new HTTP client, no new
request/response mapping, no new protocol.

## 2. Decisions

### D1 — Operator decisions (recorded verbatim from the request)

> "Let's add two more provider types to our list of available providers (shown
> in the setup wizard's `Choose an LLM provider` form and in the new provider
> form on the providers page): Ollama Cloud, and OpenAI. These two models will
> both use the OpenAI-compatible API infrastructure and hard code the Base URL
> and Unique name fields appropriately for those providers."

Asked how "hard code the Base URL and Unique name fields" should render, the
operator chose: **"Hidden entirely."**

Asked how to resolve the `openai` id collision (see D2), the operator chose:
**"Rename generic to openai-compatible."**

### D2 — The `openai` id collision, and its resolution

`openai` is **already taken**. It is the id of `OpenAICompatibleProvider` — the
*generic* OpenAI-compatible type, the only one with `pcRequiresBaseUrl = True`
and `pcRequiresName = True`, and the only one with **no** built-in base URL
(`providerBaseUrlFor` returns `""` for it deliberately; `resolveProvider`
fails closed rather than reaching out to `api.openai.com` on the operator's
behalf, "which would send a key meant for a self-hosted server to a third
party").

Real OpenAI needs that id — a provider type named `openai` that is *not*
OpenAI would be a permanent trap. Resolution:

| Type | id (= config key = vault-name stem) | display name |
|---|---|---|
| `AnthropicProvider` | `anthropic` | Anthropic |
| `OllamaProvider` | `ollama` | Ollama |
| **`OllamaCloudProvider`** (new) | **`ollama-cloud`** | **Ollama Cloud** |
| `OpenRouterProvider` | `openrouter` | OpenRouter |
| **`OpenAIProvider`** (new) | **`openai`** | **OpenAI** |
| `OpenAICompatibleProvider` (renamed) | `openai-compatible` | OpenAI-compatible |

`knownProviders` order (from `[minBound .. maxBound]`) becomes the wizard's and
the dropdown's order: anthropic, ollama, ollama-cloud, openrouter, openai,
openai-compatible. Grouping each vendor's types adjacently reads better in a
six-item list than appending the new rows at the end.

Appending instead would yield `anthropic, ollama, openrouter, openai,
ollama-cloud, openai-compatible` - separating Ollama from Ollama Cloud and OpenAI
from OpenAI-compatible, so two pairs of near-identical rows land non-adjacent in
a dropdown. Vendor grouping is better for a six-item list; the cost is one test
vector, already budgeted in §5.5.

Because `Enum`/`Bounded` are derived, that order **is** the constructors'
declaration order in the `data` block — the intended order is expressed
structurally, not by a comment. `KnownProvider` is never serialized and
`[minBound .. maxBound]` is its only ordinal use, so inserting constructors in
the middle is safe; nothing persists an ordinal.

### D3 — Distinct vault keys per type

| Type | vault key |
|---|---|
| `AnthropicProvider` | `ANTHROPIC_API_KEY` |
| `OllamaProvider` | `OLLAMA_API_KEY` |
| `OllamaCloudProvider` | `OLLAMA_CLOUD_API_KEY` |
| `OpenRouterProvider` | `OPENROUTER_API_KEY` |
| `OpenAIProvider` | `OPENAI_API_KEY` |
| `OpenAICompatibleProvider` | `OPENAI_COMPATIBLE_API_KEY` |

`vaultKeyName :: KnownProvider -> Text` stays total and **injective**.

The alternative — sharing `OLLAMA_API_KEY` between `ollama` and `ollama-cloud`,
since both are the same ollama.com account credential — was rejected. Concrete
reason, not taste: `handleProviderDelete` calls
`vhDelete vh (vaultKeyName <provider>)`. With a shared key, deleting the *Ollama*
provider would silently deprovision *Ollama Cloud*, and `providerAuthStatus`
for one type would depend on another type's provisioning. Injectivity is worth
one extra paste, and only for an operator who uses both.

`OPENAI_API_KEY` moves from the generic type to real OpenAI, which is what the
name always meant. The generic type takes `OPENAI_COMPATIBLE_API_KEY`.

**Consequence of the rename, decided explicitly:** `handleProviderDelete` for
`openai-compatible` now deletes `OPENAI_COMPATIBLE_API_KEY`, so a legacy
`OPENAI_API_KEY` **survives** that delete. This is deliberate - deleting it would
break a working OpenAI setup - and it is recorded in the CHANGELOG and pinned by
a test (item 45b). §3.1 case 3's guard is what keeps that survivor from being
transmitted without confirmation.

### D4 — Base URLs are built-in defaults, still overridable in config

`providerBaseUrlFor` gains two `builtInBaseUrl` cases:

```haskell
builtInBaseUrl OllamaCloudProvider = "https://ollama.com/v1"
builtInBaseUrl OpenAIProvider = "https://api.openai.com/v1"
```

Precedence is unchanged: `fromMaybe builtIn (providerBaseUrl cfg label)`. A
`[providers.openai] base_url = …` in config.toml still wins.

Keeping the override is deliberate — it is the established behaviour for every
other built-in provider, and it is what lets an operator route through a
corporate proxy or a local caching mirror. "Hard code" in the request is about
the **form**: the operator is not asked for a value the product already knows.
It is not a claim that the value must be unchangeable on disk.

### D5 — Both new types reuse `mkOpenAICompatible`

`resolveProvider` delegates both new constructors to the existing
`resolveOpenAICompatible` helper (the same one `OpenRouterProvider` and custom
instances use), which already: requires a base URL fail-closed, requires a
vault key fail-closed, and builds `mkOpenAICompatible`. Both types need a key —
neither has a keyless mode, unlike local Ollama.

No change to `Seal.Providers.OpenRouter` at all.

### D6 — Neither new type carries readiness

`pcReadiness` / the `readiness` wire field stay **Ollama-only**. Ollama Cloud is
a remote HTTPS endpoint like OpenRouter; `readinessFields` already gates on
`n == "ollama"`, so `ollama-cloud` emits neither key. This is the existing
design-D1 rule ("the remote HTTPS providers' config plus credential genuinely
is their whole story") and no local probe exists to run.

### D7 — The forms hide Base URL and Unique name; the server says so

"Hidden entirely" is implemented by **not rendering the fields**, driven by the
same server booleans the wizard already consumes — not by a second hardcoded
provider list in TypeScript.

- `ProviderCard` already carries `pcRequiresBaseUrl` / `pcRequiresName`, emitted
  as `requires_base_url` / `requires_name` on `GET /api/setup`. Both are
  `False` for `openai` and `ollama-cloud` (unchanged code path — `providerCards`
  already keys these off the constructor).
- `ProviderDetail` (`GET /api/providers/all`) **gains** `requiresBaseUrl` and
  `requiresName` (camelCase, 1:1 like `authStatus`/`isDefault`). The Providers
  page is driven by that endpoint, so it currently has no such signal and would
  otherwise need its own hardcoded `type` map — a second source of truth that
  can drift from the registry. For custom instances both are `True`.

Consequence: the wizard needs **no** change to its field-visibility logic
(`needsBaseUrl` / `needsName` already gate `showBaseUrl` and the Unique name
input). The Providers page replaces its hardcoded `formName === 'openai'`
special-cases with these two flags.

**`requiresBaseUrl` means REQUIRED, not VISIBLE — they are different questions.**
`pcRequiresBaseUrl` is true only for `OpenAICompatibleProvider` (`State.hs:337-342`);
it is `False` for **Ollama**, whose base URL is *optional* but *essential*: it is
the only GUI affordance for pointing at a remote Ollama daemon
(`ProviderFormFields.tsx:162-168` gives it the `http://localhost:11434`
placeholder and the "Leave blank for default" hint), and `resolveProvider` reads
it to decide keyless-vs-keyed (`Registry.hs:213-216`). Driving visibility off
`requiresBaseUrl` would **delete remote-Ollama configuration from the GUI** and
break the existing test at `ProvidersView.test.tsx:142-164`, which finds that
field by its placeholder.

So visibility needs its **own** predicate, and the two must never be conflated:

| Type | `requiresBaseUrl` (validation) | visible (UI) |
|---|---|---|
| `openai`, `ollama-cloud` | `false` | **`false`** — hidden entirely |
| `openai-compatible` | `true` | `true` — required, so shown |
| `ollama` | `false` | **`true`** — optional, still shown |
| `anthropic`, `openrouter` | `false` | `true` (today's behaviour) |

Concretely `showBaseUrl = not isHiddenBaseUrl`, where `isHiddenBaseUrl` is true
for exactly `openai` and `ollama-cloud`. `requiresBaseUrl` keeps its existing job
— deciding whether a non-empty URL is **required** before Save is enabled (the
item 42 guard) — and is never used to decide whether the field renders.

**Both surfaces, both modes.** "Hidden entirely" applies to the Providers page
in **create and edit** alike. Verified gap: `ProvidersView.tsx:544` invokes
`ProviderFormFields` **without** `showBaseUrl`, which defaults to `true`
(`ProviderFormFields.tsx:144`) — only the wizard passes it
(`ProviderStep.tsx:257`). So today the edit path renders Base URL for every
provider. Left alone, editing an OpenAI provider would *display*
`https://api.openai.com/v1` (pre-filled by `providerFormValuesFrom` from the
`base_url` the create path now writes), and offer to let the operator change a
value the request says is fixed. Both `showBaseUrl` **and** `showModels`/
`showDefaultModel` must therefore be passed explicitly at **both** call sites,
derived from the flags for the selected provider.

**Hiding a field is not enough — the payload must be gated too.** Verified
hazard: `ProvidersView.tsx:496` sets `formName` without resetting `form`, and
`:269` sends `base_url` whenever it is non-empty *regardless of visibility*. So
select OpenAI-compatible, type `http://localhost:8000/v1`, switch to OpenAI, and
Save writes that stale URL into `[providers.openai]` — contradicting D4 and
item 28. The same applies to `uniqueName`.

Therefore: send `base_url` when **`!isHiddenBaseUrl`** — i.e. `openai` and
`ollama-cloud` send nothing; `ollama`, `openai-compatible`, `anthropic`,
`openrouter` and custom instances send their non-empty value. Keying the gate on
`requiresBaseUrl` instead would be the same required-vs-visible conflation this
section exists to prevent: `ollama` has `requiresBaseUrl = false` but a visible,
essential field, so an operator could type a remote daemon URL and have it
**silently dropped on submit**, breaking the only GUI path to a remote Ollama.
`uniqueName` and `type` stay gated on `requiresName`. Clear `baseUrl`/`uniqueName`
when `formName` changes.

**`name` is always sent — only its *source* is conditional.** `name` is a
required field (`API.hs:3306` answers 400 `name must not be empty`), so the rule
is the existing ternary, not an omission:

```ts
name: requiresName ? uniqueName.trim() : formName
...(requiresName ? { type: 'openai-compatible' } : {})
```

i.e. `type` is present **only** for a custom instance; `name` is always present,
sourced from the Unique Name input when there is one and from the selected
built-in id otherwise.

One implementation detail the design must not gloss. While `creating ===
true`, `selected` is `null` (`ProvidersView.tsx:220-223`), so the per-provider
values cannot come from `selected`. The correct source is the dropdown's own
`ProviderDetail` row: both option lists already iterate the provider list from
`GET /api/providers/all`, so

```ts
const row = providers.find(p => p.name === formName)
const isHiddenBaseUrl = row?.name === 'openai' || row?.name === 'ollama-cloud'
```

is available for every selectable type. D7 reads `requiresBaseUrl` (validation)
and `requiresName` from that row, and derives `isHiddenBaseUrl` from the row's
**identity**, never from `requiresBaseUrl` — per the table above.

`ProvidersView.tsx:247` currently derives "is custom" from
`PROVIDER_LABELS[p.name] === undefined`, which is secretly a
registry-membership test; where the detail object is available, the flags are
preferred.

### D8 — Wire `type` values

`type` means "which implementation", consistently:

| `type` | meaning |
|---|---|
| `anthropic` | Anthropic |
| `ollama` | native Ollama protocol |
| `ollama-cloud` | Ollama Cloud over OpenAI-compatible |
| `openrouter` | OpenRouter |
| `openai` | real OpenAI |
| `openai-compatible` | generic / custom instance |

`customProviderDetailJson` emits `type: "openai-compatible"`, and
`resolveCreateTarget` requires `type: "openai-compatible"` for a custom name.

**No legacy aliasing.** The frontend is embedded in the binary via `file-embed`,
so client and server are always the same build. A stale browser tab that POSTs
`type: "openai"` with a non-`openai` name gets the existing 400
(`unknown provider: …`) and a reload fixes it. Silently reinterpreting the
string would be worse: after the rename, `type: "openai"` legitimately means
real OpenAI, and aliasing it back to the generic type would recreate exactly
the ambiguity D2 removes.

### D9 — Reserved instance names

`validateProviderName` currently reserves `["anthropic", "ollama",
"openrouter"]` — deliberately **not** `openai`, because `openai` was the generic
built-in's own section and must stay nameable.

The rejection message also gains a concrete alternative -
"choose another name (for example \"my-openai-endpoint\")" - because a blocked
operator currently gets no guidance.

After the rename every built-in label is reserved:
`anthropic`, `ollama`, `ollama-cloud`, `openrouter`, `openai`,
`openai-compatible`. A custom instance can no longer be named `openai`; it must
be e.g. `local-vllm`.

Frontend mirrors are updated to match: `RESERVED_PROVIDER_NAMES` in
`ProvidersView.tsx` and the literal array inside `ProviderStep.tsx`. The two
lists are duplicated in the frontend today; a follow-up should share them, but
that is out of scope here.

### D10 — Default models and static model lists

| Type | `defaultModelFor` | `staticModelsFor` |
|---|---|---|
| `OpenAIProvider` | `gpt-4o-mini` | `gpt-4o-mini`, `gpt-4-turbo` |
| `OllamaCloudProvider` | `gemma4:31b` | `[]` |
| `OpenAICompatibleProvider` | `gpt-4o-mini` (unchanged) | `[]` (unchanged) |

`gpt-4o-mini` was the generic type's default; it becomes real OpenAI's, which
is what it always described. The generic type keeps it as "a starting point
only: a generic endpoint's real model ids are its own".

OpenAI's two ids are stable public ids already sized by
`Seal.Providers.ContextWindow` (`gpt-4o-` and `gpt-4-turbo` prefixes).
`gpt-4o` is deliberately **excluded**: the table's clause is `"gpt-4o-"`
(trailing dash), so the bare id scores 0. `modelContextWindow` returns `Int`,
not `Maybe`, and a 0 is rendered as *no percentage* (`BottomBar.tsx:37` guards
the block with `contextWindow > 0`), so a 0 degrades honestly — but there is no
reason to publish a model the table cannot size. `ContextWindow.hs` is
therefore not touched.

`gemma4:31b` is the identifier form Ollama documents for **direct** cloud
requests ("Direct cloud requests use the identifiers from
`https://ollama.com/api/tags`", e.g. `gemma4:31b`; the `:cloud` suffix is the
*signed-in-local-server* form). Ollama Cloud's static list is empty for the same
reason the generic type's is: its live catalogue is the operator's own, and
inventing ids here would be a guess the UI presents as fact. `listModels`
already calls the real `/v1/models`.

`gemma4:31b` has no `ContextWindow` clause and so scores 0. That is the same
state as any custom endpoint's models today and renders no percentage; a default
model need not appear in the static *list*, which is only the new-tab
suggestion set.

## 3. Consequences

### 3.1 The `openai` id changes meaning — one documented migration wart

Before this change, `[providers.openai]` meant a *generic* endpoint. After,
`openai` means real OpenAI. Three cases:

1. **`[providers.openai] base_url = "http://localhost:8000/v1"` + key.**
   Works unchanged: the configured `base_url` still overrides the new built-in
   default, so calls still go to the operator's server. Only the *label* in the
   UI now reads "OpenAI". Acceptable and self-correcting once the operator
   renames the section to a custom instance.
2. **No `[providers.openai]` section at all.** No behaviour change; `openai`
   simply gains a working default endpoint.
3. **`[providers.openai]` with a key but no `base_url`.** This is the one real
   change, and it is **guarded, not merely documented**.

   Before: `resolveOpenAICompatible` failed closed with "needs a base URL - set
   [providers.openai] base_url". Nothing was ever transmitted.

   After: **fail closed again**, with an actionable message. The rule needs BOTH
   an existence test and a value test, because they are different questions:

   ```haskell
   let sectionExists = Map.member (providerLabel OpenAIProvider) (rcProviders cfg)
       usable u = not (T.null (T.strip u))   -- empty means ABSENT, not "use nothing"
   in case providerBaseUrl cfg (providerLabel OpenAIProvider) of
        Just u | usable u -> use u               -- case 1 (and every product create)
        _ | sectionExists -> fail closed         -- case 3: a legacy section, unconfirmed
          | otherwise     -> use (builtInBaseUrl OpenAIProvider)  -- case 2
   ```

   The `usable` guard is required by item 20c: without it `Just ""` takes the
   case-1 branch and only fails closed *downstream* in
   `resolveOpenAICompatible`'s null check. That yields the right outcome by the
   wrong path, and a future refactor of either site would split them. The value
   test must treat empty as absent **here**.

   | State | Behaviour |
   |---|---|
   | No `[providers.openai]` section | **Use the built-in default.** Fresh install; nothing pre-existing to leak. |
   | Section **with** `base_url` | Use it. Case 1 - unchanged. |
   | Section **without** `base_url` | **Fail closed**: "this key predates the OpenAI provider type - run `/provider add openai`, or add `base_url` to `[providers.openai]` in config.toml, to confirm it belongs to OpenAI." |

   Once the create path writes the built-in URL (§4), the `POST` / `PUT`
   response's `baseUrl` is non-null for these types. That is intended and
   harmless: it is a compiled-in **public** endpoint, already exposed for every
   configured provider, and carries no credential.

   **One durable consequence, stated so D4 is not misread:** writing the value
   into `config.toml` means `rcProviders` now *pins* it. If
   `builtInBaseUrl OpenAIProvider` ever changes, providers created before that
   change keep the old URL; only a provider with no section (case 2) follows the
   new one. That is the correct trade — it is what keeps the guard from
   dead-ending — but "built-in default" must not be read as "always current".
   The CHANGELOG says so alongside the other three migration facts.

   **`Map.member` is load-bearing, not stylistic.** `providerBaseUrl`
   (`Config/File.hs:742`) is `pcBaseUrl =<< Map.lookup lbl (rcProviders cfg)`,
   so it returns `Nothing` for *both* "no section" and "section without the
   field". Keying the guard off `providerBaseUrl` alone would therefore fail
   closed on a **fresh install** - breaking case 2 and the feature's own happy
   path. Item 35g pins case 2 specifically.

   **Every write path must leave a section WITH a base_url**, so the guard only
   ever trips on a genuinely pre-existing config:
   - Providers page / wizard → `handleProviderCreate` injects the built-in
     `base_url` **server-side** (§4), never from client input (the field is
     hidden, so the client sends nothing). Precedence is explicitly
     `base_url = (supplied >>= nonEmpty) <|> providerBaseUrlFor cfg kp`, so a
     scripted POST that *does* supply a URL (e.g. an Ollama Cloud proxy) still
     wins over the built-in default, and only an omitted **or empty** value falls
     back to it. Plain `<|>` is wrong: `Just ""` would beat the built-in and
     contradict item 20c. This mirrors the existing shape at `API.hs:3330-3331`,
     which already gates on `not (T.null u)`.
   - `/provider add openai` → `addCmd`'s non-Ollama branch now writes the
     built-in `base_url` too. Without it the fail-closed message's named remedy
     is a **no-op**: `seedProviderDefaults` (`Command/Provider.hs:163-169`) sets
     only `rcDefaultProvider` and `pcDefaultModel`, never `pcBaseUrl`, so the
     operator would be told to run a command that cannot clear the guard.
   - `PUT /api/providers/openai` (Providers-page edit) → must **repair** a case-3
     section, since the UI cannot send the URL (D7 hides it). Today
     `handleProviderUpdate` writes `pcBaseUrl` only when the request supplies one
     (`API.hs:3429-3431`), so editing from the UI leaves the guard set while
     `POST` and `/provider add` both clear it. The repair is **conditional**:

     ```haskell
     -- an existing value always wins; only an ABSENT one is repaired
     cfg1 = case mBaseUrl >>= nonEmpty of
              Just u  -> setBaseUrl u                    -- explicit update
              Nothing | isNothing (providerBaseUrl cfg lbl) && hasBuiltInEndpoint lbl
                      -> setBaseUrl (builtInBaseUrl lbl)  -- repair case 3
                      | otherwise -> cfg                  -- preserve case 1
     ```

     An **unconditional** "PUT injects the built-in" would be a credential
     misdirection bug: an operator on case 1 (`base_url = localhost`) who edits
     any other field would have their stored key silently redirected to
     `api.openai.com` — precisely the failure this design exists to prevent.

     **The repair also requires the request to carry a new `api_key`.** A Save
     that only changes the default model is not a statement that "this key
     belongs to OpenAI"; clearing the guard on it would authorise the very
     transmission the guard exists to require confirmation for, and would make
     the UI path weaker than `/provider add openai` (which prompts for the key).

     | `PUT` carries | section state | result |
     |---|---|---|
     | non-empty `api_key` | no `base_url` | repair: write the built-in, resolve |
     | non-empty `api_key` | has `base_url` | keep the operator's URL |
     | no `api_key` | no `base_url` | stay fail-closed, surface the `/provider add openai` hint |
     | no `api_key` | has `base_url` | keep everything (pure field edit) |

     Item 35j pins all four.

   `OllamaCloudProvider` needs no guard: it is a brand-new id, so no legacy
   section can exist. It still gets the same explicit `base_url` write, for
   consistency.

   **Why a guard at all, and not just documenting it:** review converged on the
   point that a 401 does not make the transmission harmless - it is *evidence*
   that bytes already reached a third party. Neither the CHANGELOG nor a
   config-template comment reaches an operator whose config predates the change.
   A decidable guard is the only mitigation that does. The earlier `key_namespace`
   marker suggestion reaches the same guarantee; `Map.member` reuses existing
   config machinery at lower cost.


**The inverse case, also documented.** An operator whose *old generic* provider
is configured (`OPENAI_API_KEY` + `base_url`) keeps working (case 1) — but the
`openai-compatible` row now reads `OPENAI_COMPATIBLE_API_KEY`, finds nothing, and
silently shows as unconfigured. No error explains it. Closing that is one
CHANGELOG line (re-enter the key under the new type, or move the section to a
named instance); no code change.

No automatic config migration. Rewriting a user's config.toml section key on
load is more surprising than the wart it fixes, and it would have to guess
whether a `base_url` that *is* `api.openai.com` was meant as OpenAI or as a
generic instance. `Seal.Config.Migrate` has no provider-section machinery today,
so adding one would be new, untested surface for a one-time wart.

### 3.2 The setup step's P4 copy

`classifyProvider`'s P4 detail currently reads "Add an LLM provider: anthropic,
openrouter, ollama, or an OpenAI-compatible endpoint." Updated to name the new
options without becoming an unreadable inventory — the operator sees the radio
list directly beneath it, so the sentence stays short.

### 3.3 `scripts/setup-walkthrough.sh` reproduces the case-3 egress

Steps 8b–8f POST `{"name":"openai", …}` to exercise the generic type's
fail-closed behaviour:

```sh
8b. POST /api/providers {name:openai, api_key} with NO base_url
8c. POST /api/providers/openai/test (fails closed: the endpoint is required)
```

After the rename, `name: "openai"` **is real OpenAI** and has a built-in
endpoint, so 8b succeeds instead of failing closed and 8c performs a **real
request to `https://api.openai.com/v1`** carrying `sk-local`. That is exactly the
§3.1 case-3 transmission, reproduced by a script developers run locally.

The whole block is re-keyed to a custom name (`local-vllm` with
`type: "openai-compatible"`), which preserves the original intent — a generic
endpoint still requires an explicit base URL and still fails closed without one
— and removes the egress.

## 4. Files touched

### Backend

| File | Change |
|---|---|
| `src/Seal/Providers/Registry.hs` | +2 constructors; every total function updated: `providerLabel`, `vaultKeyName`, `defaultModelFor`, `providerBaseUrlFor`, `resolveProvider`, `configuredProviders`, `validateProviderName`. Also `resolveProvider OpenAICompatibleProvider`'s hardcoded `"openai"` argument → `providerLabel OpenAICompatibleProvider` (that string names the config section in its fail-closed error). And the **§3.1 case-3 guard** in `resolveProvider OpenAIProvider`: fail closed when a `[providers.openai]` section exists without `base_url`. The guard uses `Map.member` on `rcProviders`, **not** `providerBaseUrl` alone (which returns `Nothing` for both an absent section and a section without the field). And `resolveOpenAICompatible`'s fixed error nouns ("the OpenAI-compatible provider … the setup wizard asks for it", `:269-270`) need parameterising — but **by two separate strings, not one**. The existing single `name` parameter serves *two* roles: the quoted subject **and** the config-section key in `set [providers.<name>] base_url` (`:270`). `providerLabel` is `openai` while `providerDisplayName` is `OpenAI` (and `ollama-cloud` vs `Ollama Cloud`), so passing the display name for both roles would emit the unusable `[providers.Ollama Cloud]`. Add an `id`/label parameter (section key, `/provider add` target) and keep a distinct display noun, plus a `hasBuiltInEndpoint` flag so the "the setup wizard asks for it" parenthetical appears only when it is true. `providerTypeForName` needs **no** change (already `fromMaybe OpenAICompatibleProvider`). `knownProviders` order (D2). |
| `src/Seal/Setup/State.hs` | `providerDisplayName` +2; `providerCards` raises no flags for the new types (already constructor-keyed); P4 copy. |
| `src/Seal/Gateway/API.hs` | `providerAuthStatus` +2 and `staticModelsFor` +2 (**these two are WU1 work** — wildcard-free exhaustive cases, so the library will not compile without them; see §5.6); `providerDetailJsonFor` gains `requiresBaseUrl`/`requiresName`; `customProviderDetailJson` type id → `openai-compatible`; **`:715`** the `customInfos` `"type"` literal → `openai-compatible`; **`:3246`** the readiness guard `typeId /= "openai"` → `typeId /= "openai-compatible"` (otherwise it becomes a tautology and custom instances inherit Ollama readiness); `resolveCreateTarget` / `resolveExistingTarget` type ids and the required-type check; `handleProvidersAll` unchanged (mapM over `knownProviders` picks up the new rows). |
| `src/Seal/Gateway/Setup.hs` | `handleProviderTest`'s "known providers" hint text. Card JSON already emits both booleans — no change. |
| `src/Seal/Gateway/API.hs` (create path) | `handleProviderCreate` injects `providerBaseUrlFor cfg OpenAIProvider` as `base_url` **server-side** when creating an OpenAI or Ollama Cloud provider, so `upsertProvider` (`Config/File.hs:828-830`) never materialises a section without one. Without this the §3.1 guard would immediately dead-end a provider created through the UI. Pinned by item 35f. |
| `src/Seal/Command/Provider.hs` | `addCmd`'s generic path already prompts for a key for any non-`ollama` type, so both new types work — **but it must also write the built-in `base_url`** for `openai`/`ollama-cloud` — **scoped by `KnownProvider` constructor match, not unconditionally** — or the §3.1 guard's named remedy is a no-op (`seedProviderDefaults` sets only `rcDefaultProvider`/`pcDefaultModel`). Pinned by item 35h. `providerReadinessSegment` already returns "" for non-`ollama`. The help text listing known ids is generated from `knownProviders`, so it needs no edit. **Not fixed here:** `authLabel` (`:255-266`) probes `anthropicOAuthKey` in its `otherwise` branch, so it reports `auth: oauth` for any non-Ollama provider when Anthropic OAuth exists — pre-existing, already wrong for OpenRouter, and made more visible by two more rows. Separate PR (§6). |
| `CHANGELOG.md` | One `0.1.0.0` bullet stating **all three facts**: (a) `OPENAI_API_KEY` / `[providers.openai]` now name **real OpenAI** — move a self-hosted section to a named `openai-compatible` instance and re-enter the key there; (b) `[providers.ollama] base_url = "https://ollama.com"` gains the OpenAI-compatible path as `ollama-cloud`; (c) **deleting `openai-compatible` does not remove a legacy `OPENAI_API_KEY`** — that secret is retained deliberately; (d) a provider created through the UI **pins** the built-in `base_url` in `config.toml`, so a future change to that default does not reach it. |
| `scripts/setup-walkthrough.sh` | Steps 8b–8f re-keyed from `name: "openai"` to a custom name with `type: "openai-compatible"`. See §3.3 — leaving it as-is turns the script into the case-3 egress. |
| `config/templates/config.toml` | Comment block gains the new ids; the generic example is re-keyed to `openai-compatible` with the D2 migration note. |

**Not touched:** `src/Seal/Providers/OpenRouter.hs` (reused as-is),
`Seal.Providers.Ollama`, `Seal.Providers.OllamaReadiness*` (no readiness for
the new types), `Seal.Providers.ContextWindow` (D10), the ISA, any opcode.

### Frontend

| File | Change |
|---|---|
| `frontend/src/types.ts` | `ProviderDetail` +`requiresBaseUrl` / `requiresName`; comment updates on `type`. |
| `frontend/src/lib/providerLabels.ts` | labels for `openai` / `ollama-cloud` / `openai-compatible`. The generic row renders **"OpenAI-compatible (custom / self-hosted)"** in dropdowns, since the id no longer disambiguates it from real OpenAI. |
| `frontend/src/components/ProvidersView.tsx` | label map; drive Base URL + Unique name visibility from the detail flags (when creating: the dropdown's own `ProviderDetail` row — D7) instead of `formName === 'openai'`; **pass `showBaseUrl` explicitly at the `ProviderFormFields` call site** (and `showModels`/`showDefaultModel` as `true` — no flag drives them and no behavioural change is intended) (it currently omits `showBaseUrl`, which defaults to `true`, so edit renders Base URL for every provider); **gate the submitted payload on `!isHiddenBaseUrl` (not `requiresBaseUrl`), and clear `baseUrl`/`uniqueName` when `formName` changes** (RG-2); custom-instance `type: 'openai-compatible'`; reserved-name set. |
| `frontend/src/components/ProviderFormFields.tsx` | `isOpenAIType` → `isOpenAICompatible` (the generic type's placeholder/hint); no visibility logic change — `showBaseUrl` already exists. |
| `frontend/src/components/setup/ProviderStep.tsx` | reserved-name array **and the `saveKey` POST body (~`:147`)**, which sends `type: 'openai'` for a custom instance and becomes a 400 after D8. Field visibility already correct via `requires_base_url` / `requires_name`. |
| `frontend/src/components/ProviderModelFields.tsx`, `frontend/src/components/AgentsView.tsx` | label maps. |
| `frontend/src/components/ActiveTabs.tsx` | badge specs for `openai` and `ollama-cloud`. `ollama-cloud` reuses the bundled Ollama mark (same brand). `openai` needs a bundled mark; if none is available, a lettered chip (`char: 'O'`) is the established pattern (Anthropic uses `char: 'A'`). This is **load-bearing, not cosmetic**: `handleProviderIconWith` reads the config-only `providerBaseUrl`, so a provider with only a built-in default 404s on icon fetch (pre-existing — Anthropic behaves this way today). |
| `frontend/src/lib/setupSteps.ts` | comment only (`requires_*` parsing unchanged). |

### Tests

- `test/Seal/Providers/RegistrySpec.hs` — `knownProviders` membership + order;
  labels, vault keys, default models, base URLs for the two new types; the
  generic type's renamed label/key; `validateProviderName` reserving all six;
  `configuredProviders` for each new type (key present ⇒ configured; key absent
  ⇒ not); `providerBaseUrlFor` override still wins.
- `test/Seal/Setup/StateSpec.hs` — card list, labels, and both `requires*`
  flag vectors for six cards.
- `test/Seal/Gateway/SetupApiSpec.hs` — `requires_base_url` /
  `requires_name` are `False` for `openai` and `ollama-cloud`; the `openai`
  card is present.
- `test/Seal/Gateway/ApiSpec.hs` — `/api/providers` includes six built-ins with
  the new names; `/api/providers/all` carries `requiresBaseUrl` /
  `requiresName`; a custom instance reports `type: "openai-compatible"`; POST
  with `type: "openai-compatible"` creates a custom instance; POST
  `name: "openai"` with no base URL succeeds and does **not** 400 (it has a
  built-in endpoint now).
- `frontend/src/components/__tests__/ProvidersView.test.tsx` — selecting
  OpenAI renders **no** Base URL and **no** Unique name input; selecting
  OpenAI-compatible renders both and still requires them.
- `frontend/src/components/__tests__/providerStep.test.tsx` — an `openai` card
  renders no base-URL field; an `openai-compatible` card does; and the custom
  instance's POST body carries `type: "openai-compatible"`.
- User-outcome tests (§5.3b) assert that an operator can actually finish: Save
  enabled with only a key, the provider resolves, and no stale `base_url` is
  submitted.

## 5. Test plan

Every item is labelled:

- **RED** — fails before the implementation that satisfies it, by construction.
- **GUARD** — passes today and must **stay** green. These are real regression
  guards, not RED tests; labelling them RED would misrepresent the TDD cycle.

Security-critical pure functions get QuickCheck properties over
`knownProviders` (`= [minBound .. maxBound]`), so a **future** constructor is
covered without editing the test. Enumerating six values is not a property.

### 5.1 RED — registry and pure vocabulary

1. **RED** `knownProviders` equals
   `[Anthropic, Ollama, OllamaCloud, OpenRouter, OpenAI, OpenAICompatible]`.
2. **RED** *Property:* `providerLabel` is injective over `knownProviders` —
   pairwise-distinct over the list, written over the list, not six literals.
3. **RED** *Property:* `vaultKeyName` is injective over `knownProviders` — same
   shape. This is the invariant D3 rests on.
4. **RED** *Property:* every label round-trips —
   `∀ p ∈ knownProviders, parseProvider (providerLabel p) == Just p`.
5. **RED** `providerLabel OpenAIProvider == "openai"`; `parseProvider "openai" == Just OpenAIProvider`.
6. **RED** `providerLabel OpenAICompatibleProvider == "openai-compatible"`; `parseProvider "openai-compatible" == Just OpenAICompatibleProvider`.
7. **RED** `providerLabel OllamaCloudProvider == "ollama-cloud"`; `parseProvider "ollama-cloud" == Just OllamaCloudProvider`.
8. **RED** `vaultKeyName` values per D3, exactly (six cases).
9. **RED** `defaultModelFor` per D10, exactly.
10. **RED** `providerBaseUrlFor defaultRuntimeConfig OpenAIProvider == "https://api.openai.com/v1"`.
11. **RED** `providerBaseUrlFor defaultRuntimeConfig OllamaCloudProvider == "https://ollama.com/v1"`.
12. **RED** A configured `base_url` overrides each new built-in default. (The
    override *mechanism* already works today - `fromMaybe builtIn (providerBaseUrl
    cfg …)`; this fails only because the built-in does not exist yet. It becomes
    a true guard once the built-ins land.)
13. **RED** `validateProviderName` rejects every built-in label — *property* over
    `map providerLabel knownProviders` (D9). This item auto-covers a future
    constructor.
14. **RED** `configuredProviders` with `OPENAI_API_KEY` stored ⇒ includes `OpenAIProvider`.
15. **RED** `configuredProviders` with `OLLAMA_CLOUD_API_KEY` stored ⇒ includes `OllamaCloudProvider`.
16. **RED** `configuredProviders` with no keys ⇒ neither new type (no keyless mode).
17. **RED** `configuredProviders` with `OLLAMA_API_KEY` only ⇒ includes
    `OllamaProvider` **and not** `OllamaCloudProvider` (D3 injectivity, observable
    through the public filter).
18. **RED** `resolveProvider OpenAIProvider` with no key ⇒ `Left` whose text
    names **OpenAI** (not "OpenAI-compatible").
19. **RED** `resolveProvider OllamaCloudProvider` with no key ⇒ `Left` naming
    **Ollama Cloud**.
20. **RED** `resolveProvider OpenAICompatibleProvider` with no vault ⇒ `Left`
    naming the config section **`openai-compatible`**, asserted as
    `"[providers.openai-compatible]" isInfixOf e` **and**
    `"[providers.openai]" notInfixOf e`. A bare `openai` substring check passes
    when it should fail, because `"openai-compatible"` contains `"openai"`.
20c. **RED** An **empty-string** `base_url` also fails closed:
     `resolveProvider OpenAIProvider` with `providerBaseUrl = Just ""` returns
     `Left`, **with a `[providers.openai]` section present**. That premise is
     what makes the item sound: `Just ""` only arises when a section exists, so
     without it the case-2 branch would legitimately return `Right` and a future
     editor could "fix" the guard to fail closed on fresh installs. This must
     fail **at the guard's own value test**, not downstream:
     `providerBaseUrl` yields `Just ""`, so a naive `Just u -> use u` routes it
     to case 1 and only `resolveOpenAICompatible`'s null check rejects it. Same
     outcome, wrong path — and a refactor of either site would split them. The
     `usable u = not (T.null (T.strip u))` test in §3.1 is what this pins.
     Because *both* paths return `Left`, item 20c must assert on the **message**
     (the guard's "predates the OpenAI provider type" wording), not merely that
     a `Left` came back — otherwise it, like the naive pseudo-code, cannot tell
     which branch fired.
20b. **RED** Section-key vs display-noun separation: `resolveProvider
     OllamaCloudProvider` with `providerBaseUrl = Just ""` returns a `Left`
     whose text contains **`[providers.ollama-cloud]`** and **not**
     `[providers.Ollama Cloud]`. Item 20 cannot catch this — it uses
     `openai-compatible`, where the id and the display noun coincide.
21. **RED** `staticModelsFor OpenAIProvider` is non-empty and every id satisfies
    `modelContextWindow id > 0` (`Int`, so "non-zero" — the function returns
    `Int`, not `Maybe`). `staticModelsFor OllamaCloudProvider == []`.

### 5.2 RED — setup state and HTTP surfaces

22. **RED** Setup state emits six cards in D2 order with the D2 display names.
23. **RED** `pcRequiresBaseUrl` / `pcRequiresName` are `False`/`False` for
    `openai` and `ollama-cloud`, `True`/`True` for `openai-compatible`, and
    `False`/`False` for the other three.
24. **RED** `GET /api/setup`: the `openai` card has `requires_base_url: false`
    and `requires_name: false`; the `openai-compatible` card has `true`/`true`
    — asserted **per card by id**, not by whole-body substring. (The existing
    `hasBoolField` helper is a `contains` on the whole body, so a paired
    `True`/`False` pair both passes while the per-provider semantics invert.)
25. **RED** `GET /api/providers` lists six built-ins with the D2 names **and**
    the correct per-name `configured` flags.
26. **RED** `GET /api/providers/all`: `requiresBaseUrl`/`requiresName` are
    `false`/`false` for `openai` and `ollama-cloud`; `true`/`true` for
    `openai-compatible`.
27. **RED** `GET /api/providers/all` for a custom instance reports
    `type: "openai-compatible"`, `requiresBaseUrl: true`, `requiresName: true`.
28. **RED** `POST {"name":"openai","api_key":"sk-…"}` ⇒ 201, and a `base_url` **is**
    stored for it, equal to `providerBaseUrlFor cfg OpenAIProvider`. (The client
    sends none - the field is hidden - so the server injects it. Item 28 and the
    §3.1 guard must agree: a create must never leave a section without a
    base_url, or 35b fails.)
29. **RED** `POST {"name":"ollama-cloud","api_key":"…"}` ⇒ 201, likewise with the injected `base_url` (`https://ollama.com/v1`).
30. **RED** `POST {"name":"local-vllm","type":"openai-compatible","base_url":…}`
    ⇒ 201 with `type: "openai-compatible"` echoed.
31. **RED** `POST {"name":"local-vllm","type":"openai"}` ⇒ 400 (no legacy
    aliasing, D8).
32. **RED** `POST {"name":"openai","type":"openai-compatible"}` ⇒ 400
    (type/name mismatch).
33. **RED** `GET /api/providers/all` for a custom instance emits **no**
    readiness keys (the `:3246` guard fix).

### 5.3 RED — frontend

34. **RED** Providers page: selecting **OpenAI** renders neither
    `provider-base-url-input` nor `provider-instance-name-input`; Save is
    enabled with only an API key.
35. **RED** Providers page: selecting **Ollama Cloud** likewise renders neither.
36. **RED** Providers page: the id→flags helper classifies exactly
    `openai-compatible` as custom-capable (`requiresBaseUrl`/`requiresName`
    true) and every other built-in as not — the anti-drift guard for D7's
    creating-state helper.
37. **RED** Providers page: submitting a custom instance POSTs
    `type: "openai-compatible"`.
38. **RED** Wizard: saving a custom instance POSTs `type: "openai-compatible"`
    (the `ProviderStep.tsx:147` fix — the bug that would otherwise ship green).
39. **RED** Label maps render the short forms "OpenAI", "Ollama Cloud",
     "OpenAI-compatible" (`providerLabel`). The dropdown **option text** is a
     separate surface and uses the disambiguating form "OpenAI-compatible
     (custom / self-hosted)" — asserted separately, so the two strings cannot be
     confused for one another.

### 5.3b RED — user outcomes (the design's actual promise)

The items above mostly assert that fields are *absent*. An operator must also be
able to **finish**. These are the acceptance criteria for §1's benefit claim.

34a. **RED** Providers page, **edit** mode: selecting an existing **OpenAI**
     provider renders **no** `provider-base-url-input` and **no**
     `provider-instance-name-input`, even though the stored detail carries a
     `baseUrl` (pre-filled by `providerFormValuesFrom`). This is the case the
     first draft missed — `showBaseUrl` defaults to `true` and the Providers
     page never passed it. Repeat for **Ollama Cloud** (the edit×Ollama Cloud
     combination is otherwise unasserted).
34b. **RED** Providers page: for **OpenAI**, entering only an API key leaves
     Save **enabled**, and submitting succeeds.
34c. **RED** Providers page: for **Ollama Cloud**, likewise.
34d. **RED** Wizard: for **OpenAI**, entering only an API key enables the primary
     action.
35b. **RED** After `POST {"name":"openai","api_key":…}`,
     `resolveProviderByName "openai"` returns `Right` - the provider actually
     resolves, not merely that a key was stored.
35c. **RED** Same for `ollama-cloud`.
35d. **RED** Submit-gating: with OpenAI-compatible selected and a base URL typed,
     then switching to OpenAI, the submitted payload carries **no** `base_url`
     and **no** `type` (RG-2) — **and** `name: "openai"` is present, since `name`
     is mandatory. An absence-only assertion would pass on a payload that 400s.
35e. **RED** `resolveProvider OpenAIProvider` when a `[providers.openai]` section
     exists **without** `base_url` returns `Left` naming `/provider add openai`
     (§3.1 case 3), and makes no network call.
35f. **RED** Round-trip consistency, **stored form**: after
     `POST {"name":"openai","api_key":…}`, the persisted config has
     `pcBaseUrl = Just "https://api.openai.com/v1"`. This is the half 35b does
     not cover and the one that fails if a create path forgets to inject the
     URL — `upsertProvider` writes the section regardless (§3.1), so 35b alone
     can pass while the guard is silently re-armed.
35g. **RED** **Case 2 (fresh install)**: with *no* `[providers.openai]` section,
     `resolveProvider OpenAIProvider` (key present) returns `Right` and uses
     `https://api.openai.com/v1`. Pins that the guard keys off `Map.member`, not
     `providerBaseUrl` — a `providerBaseUrl`-only check fails this item because
     it returns `Nothing` for both the absent-section and section-without-field
     states (`Config/File.hs:742`).
35j. **RED** `PUT /api/providers/openai` repair matrix (all four rows):
     (i) non-empty `api_key` + no `base_url` ⇒ the built-in is written and
     `resolveProviderByName "openai"` returns `Right`;
     (ii) non-empty `api_key` + an existing `base_url` ⇒ that value is **kept**
     (never redirected to `api.openai.com`);
     (iii) **no** `api_key` + no `base_url` ⇒ still fail-closed (a model-only
     Save must not authorise transmission);
     (iv) no `api_key` + existing `base_url` ⇒ unchanged.
35i. **RED** **Case 1 through the guard**: with a `[providers.openai]` section
     that HAS a `base_url` (e.g. `http://localhost:8000/v1`), `resolveProvider
     OpenAIProvider` returns `Right` and uses **that** URL, not the built-in.
     Item 12 pins the accessor (`providerBaseUrlFor`); this pins the guard's
     `Just u` branch, which is the one that must never fail closed. Together
     35e/35g/35i cover all three branches.
35h. **RED** `/provider add openai` **clears** the case-3 guard: after the
     fail-closed state, the command writes `base_url` and
     `resolveProviderByName "openai"` returns `Right`. Fails today, because
     `seedProviderDefaults` never touches `pcBaseUrl`.

### 5.4 GUARD — passing today, must stay green

40. **GUARD** `providerBaseUrlFor defaultRuntimeConfig OpenAICompatibleProvider == ""`
    (the generic type still has no default — the whole point of D2).
41. **GUARD** `validateProviderName "local-vllm" == Right ()`.
41b. **GUARD** **Ollama keeps an editable Base URL** on the Providers page, in
     **both** create and edit modes: `provider-base-url-input` renders with the
     `http://localhost:11434` placeholder, **and the submitted payload carries
     the typed remote URL**. Asserting rendering alone is not enough: keying the
     payload on `requiresBaseUrl` (false for Ollama) would render the field and
     then silently drop the value — the regression would pass the whole suite.
     This is the guard for `requiresBaseUrl` meaning *required*, not *visible*,
     and it also protects the existing test at `ProvidersView.test.tsx:142-164`.
41c. **GUARD** A custom `openai-compatible` instance still renders an editable
     Base URL in **edit** mode, pre-filled with its stored URL, and the
     submitted payload carries it. Absence-only coverage (item 34a) would pass an
     implementation that hides the field unconditionally in edit mode — making a
     custom instance's endpoint uneditable *and*, with the payload gated on
     `requiresBaseUrl`, unsendable.
42. **GUARD** Providers page: selecting **OpenAI-compatible** still renders both
    fields and Save stays disabled until both are valid.
43. **GUARD** Wizard: an `openai-compatible` card still renders both fields.
44. **GUARD** Wizard: an `openai` / `ollama-cloud` card renders no base-URL and
    no unique-name field (D7 says this already holds because the wizard gates on
    the server flags — a guard, not new behaviour).

### 5.4b RED — vault retention and injectivity (security)

45. **RED** Delete `ollama` ⇒ `providerAuthStatus ollama-cloud` is still
    `api-key` (D3 injectivity, through DELETE).
45b. **RED** Delete `openai-compatible` ⇒ `OPENAI_API_KEY` still present, so
    `providerAuthStatus openai` is unchanged. Pins the deliberate retention of
    D3 rather than leaving it accidental.

### 5.5 Existing tests to UPDATE (not merely add to)

These assert the old names and **will go red**. The plan phase must budget them
as work, not discover them mid-implementation.

| File | Assertion |
|---|---|
| `RegistrySpec.hs:118-124` | 4-element `knownProviders` vector; `providerLabel OpenAICompatibleProvider == "openai"`; `vaultKeyName … == "OPENAI_API_KEY"`; `parseProvider "openai"`. |
| `RegistrySpec.hs:88-93` | `openAICfg` keys `[providers.openai]`; must key `openai-compatible` or the four `resolveProvider`/`configuredProviders` tests (`:288-320`) go red. |
| `RegistrySpec.hs:410` | `validateProviderName "openai" == Right ()` → `isLeft` (D9). |
| `RegistrySpec.hs:422` | `vaultKeyNameForName "openai" == "OPENAI_API_KEY"` — `openai` is now a built-in, so the name-derived path no longer applies; assert with a custom name. |
| `RegistrySpec.hs:297` | `"base URL" isInfixOf` → also assert the section name (item 20). |
| `StateSpec.hs:118-129` | 4-card vector, names, `requires*` vectors → 6 cards. |
| `ApiSpec.hs:4465` | 4-entry `byName` Map incl. `("openai", False)` → 6 entries. |
| `ApiSpec.hs:4838-4847, 4886, 4900` | Custom-instance POST bodies and the `type` echo → `openai-compatible`. |
| `SetupApiSpec.hs:127-138` | `hasBoolField` is a whole-body `contains` helper (`:626-628`); replace with per-card assertions (item 24). |
| `ProvidersView.test.tsx:379-420` | Selects `value: 'openai'` expecting the generic flow → `openai-compatible`. |
| `providerStep.test.tsx:280-305` | Card `id: 'openai'` with `requires_base_url: true` → `openai-compatible`. |
| `scripts/setup-walkthrough.sh:79-92` | Re-key steps 8b–8f (§3.3). |

`ProviderBadge.test.tsx` is unaffected (it uses `ollama`).

### 5.6 Work units

The rename is not a forced big-bang, but WU3 is irreducible.

- **WU1** the entire `KnownProvider` vocabulary: `Registry.hs` + `RegistrySpec`
  (items 1-21 plus the four `RegistrySpec` updates) **plus every wildcard-free
  match over `KnownProvider` outside `Registry.hs`**.

  This must be an *exhaustive sweep*, not a spot fix. `-Wall` (in the shared
  `settings` stanza, `seal-harness.cabal:31-32`) implies
  `-Wincomplete-patterns`, and `-Werror` is on for the whole `library`, so `+2`
  constructors fails the build at **every** site that matches without a `_ ->`.
  There are **nine**:

  | # | Site | File |
  |---|---|---|
  | 1 | `providerLabel` | `Registry.hs:85` |
  | 2 | `vaultKeyName` | `Registry.hs:140` |
  | 3 | `defaultModelFor` | `Registry.hs:157` |
  | 4 | `builtInBaseUrl` (local to `providerBaseUrlFor`) | `Registry.hs:295` |
  | 5 | `resolveProvider` (4 equations) | `Registry.hs:193+` |
  | 6 | `isConfigured` (local case in `configuredProviders`) | `Registry.hs:357+` |
  | 7 | `providerAuthStatus` | `API.hs:3259` |
  | 8 | `staticModelsFor` | `API.hs:3824` |
  | 9 | `providerDisplayName` | `State.hs:352` |

  Sites 1-6 are inside WU1's own file. Sites 7-8 are two extra equations in
  `API.hs`. **Site 9 lives in `Setup/State.hs`, which is WU2's file** — so WU2's
  "green alone" cannot hold unless WU1 carries it too. `providerDisplayName` is
  pure and additive (two `Text` literals), so it belongs in WU1 for exactly the
  reason sites 7-8 do.

  WU1's independence is therefore: **green modulo three pure, additive
  exhaustive matches outside `Registry.hs`** (`providerAuthStatus`,
  `staticModelsFor`, `providerDisplayName`) — none of which touches a route, a
  JSON shape, or an HTTP path.

  **`State.hs` appears in both WU1 and WU2, by design and by line.** WU1 owns
  exactly one function in it — `providerDisplayName` (`:352`), the two new
  `Text` equations. WU2 owns everything else in that file (P4 copy, the card
  flags, `StateSpec`). No other file is split: `Registry.hs` is wholly WU1,
  `ProvidersView.tsx`/`ProviderStep.tsx` wholly WU3, and `API.hs` is split by
  **function** (WU1: `providerAuthStatus`, `staticModelsFor`; WU3: the rest),
  which is stated above.

  Sites that are **not** in this set because they use a `_ ->` wildcard and so
  compile fine: `providerCards` (`State.hs:337-346` — its wildcards already
  yield the correct defaults for the new types, `requiresBaseUrl = False`,
  `pcReadiness = Nothing`), `providerReadinessSegment`, and the `"ollama"`
  label comparisons. Those are behavioural, not compile-time, and are covered by
  tests instead (§7).
- **WU2** the remainder of `Setup/State.hs` + `StateSpec` + `SetupApiSpec`
  (items 22-24, the P4 copy, and the card-flag assertions). Green **once WU1
  has landed** `providerDisplayName`'s two cases — WU2 is downstream of WU1 by
  construction, not parallel to it. After that it stands alone: the new cards
  render as raw ids until WU3 lands the frontend labels, which is degraded, not
  broken.
- **WU3** The atomic unit: `resolveCreateTarget` / `resolveExistingTarget` /
  `customProviderDetailJson` / `providerDetailJsonFor` / the `customInfos`
  `"type"` literal (`:715`) / the readiness guard (`:3246`) / the create-path
  `base_url` injection (`API.hs`) + `types.ts` + `ProvidersView.tsx` +
  `ProviderStep.tsx` + `ProviderFormFields.tsx` + label maps + `ActiveTabs.tsx`
  + items 25-39 and their test updates. (`providerAuthStatus` and
  `staticModelsFor` are WU1 - see above.)

  WU3 **cannot** be split: the frontend is embedded via `file-embed`, so client
  and server ship together, and `type: "openai"` for a custom name must start
  and stop being valid in the same commit.

**Unowned files, assigned.** §4 lists five files that no work unit above names:
`Gateway/Setup.hs` (the "known providers" hint text), `Command/Provider.hs`
(**load-bearing** — item 35h fails without `addCmd`'s `base_url` write),
`CHANGELOG.md`, `config/templates/config.toml`, and
`scripts/setup-walkthrough.sh`. All five go to **WU3**, which is already the
"touch everything that must ship atomically" unit. In particular item 35h is
WU3 work, not WU1, despite being a backend test.

Completion gate: `make check` (build + test + lint) plus the frontend test
suite, per the Makefile, and `.coverage-thresholds.json`'s enforcement command.

## 6. Non-goals

- Renaming the existing custom-instance concept, or changing
  `vaultKeyNameForName` / `customProviderNames`.
- Consolidating the four duplicated `PROVIDER_LABELS` maps into one (an
  existing, documented follow-up). This change adds entries to each; it does not
  merge them.
- Adding readiness probing for Ollama Cloud.
- Automatic config migration for `[providers.openai]` (§3.1).
- Touching `Seal.Providers.ContextWindow` (D10).
- Changing `Seal.Providers.OpenRouter`, the ISA, or any opcode.
- Streaming: both new types inherit the existing non-streaming
  `sendChatCompletion`, exactly like OpenRouter and custom instances today.
- Replacing `knownProviders = [minBound .. maxBound]` with an explicit list.
  Suggested in review, declined deliberately: the derived enumeration is what
  makes the injectivity and reserved-name *properties* (§5 items 2-4, 13)
  auto-cover a future constructor. An explicit list would reintroduce the drift
  D2 removes.
- Extending `inferProviderId` (`Seal.Session.Kind`) with an `ollama-cloud` rule.
  `gemma` does **not** disambiguate — `gemma3:4b` is a perfectly good *local*
  Ollama model. Its existing `gpt` → `openai` rule becomes consistent with real
  OpenAI as a side effect of D2; it has no callers today, so it is noted, not
  changed.
- In-product migration prompt for operators already on
  `[providers.ollama] base_url = "https://ollama.com"`. They already get a
  discoverable signal: that config yields readiness `RdCloud` and
  `ProvidersView` renders a **"Cloud"** badge for it. A backend hint would be new
  logic in `providerDetailJsonFor` for a one-line nudge — scope creep against the
  one-logical-change rule. The CHANGELOG names the migration explicitly instead.
- Fixing `handleProviderDelete`'s unconditional deletion of `anthropicOAuthKey`
  (`API.hs:3463-3470`), which wipes Anthropic OAuth tokens when *any* provider is
  deleted. Pre-existing and separate; D3's injectivity prevents *new* instances
  of that bug class, but the rename does make it more reachable (six deletable
  built-ins instead of four). Its own PR.
- Fixing `authLabel`'s `otherwise` branch reporting `auth: oauth` for every
  non-Ollama provider when Anthropic OAuth exists
  (`Command/Provider.hs:255-266`). Pre-existing, already wrong for OpenRouter.

## 7. Risks

| Risk | Mitigation |
|---|---|
| A missed site in a **total function over `KnownProvider`** | `-Werror` + `-Wincomplete-patterns`: the compiler names every such site. This holds **only while those functions have no `_ ->` fallback** — adding one silently opts every future constructor out of the compiler's help. `vaultKeyName`, `providerLabel`, `defaultModelFor`, `providerBaseUrlFor`, `providerAuthStatus`, `staticModelsFor` must stay wildcard-free. |
| Conflating a provider's id with its display name when parameterising the fail-closed error (emitting `[providers.Ollama Cloud]`) | The helper takes the section key and the display noun as separate parameters; item 20b pins it on `ollama-cloud`, where the two differ. |
| A missed **label string comparison** — the compiler is blind to these | Enumerated exhaustively and each given a test: `Registry.hs:242` (the fail-closed section name, item 20), `API.hs:715` (custom `type`), `API.hs:3246` (readiness guard), `Registry.hs:118` (reserved names, item 13), `ProvidersView.tsx:247` (custom-ness, item 36). The `"ollama"` comparisons at `State.hs:294`, `Provider.hs:175/256/279`, `API.hs:3182` are **correct as-is** (Ollama-only semantics) and are pinned by guard items. |
| Frontend and backend disagree on which types hide the fields | Server-driven flags (D7) plus item 36 pinning the creating-state helper. |
| The §3.1 case-3 key transmission (secret egress to a third party) | **Guarded, not just documented**: a pre-existing `[providers.openai]` section without `base_url` fails closed (§3.1). The create path always writes `base_url`, so product-configured providers never hit it. §3.3 removes the one place a developer would reproduce it. Items 35e and 34b-35d pin it. |
| The §3.1 guard dead-ending a provider created through the UI (because `upsertProvider` always writes a section) | Both write paths (create + `/provider add`) inject the built-in `base_url` server-side; items 35f/35h round-trip and fail if they do not. |
| The §3.1 guard failing closed on a **fresh install** (the case-2 regression) | The guard tests `Map.member (rcProviders cfg)`, not `providerBaseUrl`, which cannot distinguish the two states. Item 35g pins case 2. |
| A hidden field still being *shown* in edit mode (`showBaseUrl` defaults to `true`; only the wizard passes it) | Both call sites pass `showBaseUrl`/`showModels`/`showDefaultModel` from the flags; item 34a asserts the edit path specifically. |
| A hidden field still leaking a value into the payload (stale `base_url`) | The payload is gated on `!isHiddenBaseUrl` (visibility) and `requiresName`, and `formName` changes clear the fields (D7, RG-2). Items 35d and 41b pin it. |
| A legacy `OPENAI_API_KEY` outliving deletion of `openai-compatible` | Deliberate retention, documented in the CHANGELOG and pinned by item 45b; §3.1's guard is what stops it being transmitted unconfirmed. |
| A stale tab POSTs the old `type: "openai"` | 400 with a clear message; reload fixes it (D8). |
| Six rows make the wizard list long | Acceptable at this count; vendor-adjacent grouping (D2) keeps it readable. |
| A 0 context window looking like a bug | It renders as *no percentage* (`BottomBar.tsx:37`), which is honest (D10). |
