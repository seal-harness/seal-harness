# Design — OpenAI and Ollama Cloud provider types

**Status:** revision 6 — approved scope, narrowed by operator re-ratification.
Round 4 returned 5/5 APPROVED; revision 6 is a strict *removal* (§3.1).

Gate history:

| Round | Result |
|---|---|
| 1 | 4/5 NEEDS_REVISION (Security APPROVED) |
| 2 | 3/5 NEEDS_REVISION, 2 APPROVED |
| 3 | 2 APPROVED, 3 NEEDS_REVISION (all blockers fixed) |
| 4 | **5/5 APPROVED** — gate passed (`0ba0bc5` + the §7 invariant-list fix) |

**APPROVED — implementation may proceed.** All blockers from rounds 1-3 are
addressed and each is pinned by a numbered test. Round 4 returned 5/5 APPROVED
on this text.
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

**Re-ratified, with the scope consequence made explicit (operator, 2026-11-18):**

> "Let's re-ratify the rename. We don't have any users yet and don't have to
> worry about backwards compatibility."

This is not merely a waiver of the backward-compatibility objection. The rename's
only unresolved cost was the fail-closed guard for a *pre-existing*
`[providers.openai]` section (§3.1 in revisions 1-5) — the item the Plan Review
Gate's scope reviewer blocking on as "unrequested work". With no users, no such
section exists on any install, so the guard is unreachable and is **removed**,
together with the three write paths that existed only to keep it from
dead-ending its own happy path. See §3.1.

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

**No orphaned secret.** The rename does not strand a stored
`OPENAI_API_KEY`: there are no users, so no such key exists (§3.1). The
injectivity invariant is what makes this a non-question — every type owns its own
vault key, so `handleProviderDelete` can only ever delete the key of the type
being deleted. Pinned through DELETE by item 45.

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
const isHiddenBaseUrl = row === undefined
  || row.name === 'openai' || row.name === 'ollama-cloud'   // unresolved => fail closed
```

For the **submitted payload** an unresolved `row` must mean "hidden" (send
nothing): otherwise a providers list that has not loaded yet lets a stale
`baseUrl` be re-sent into `[providers.openai]`. Render logic keeps its current
default. 

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

### 3.1 No migration: there are no users

Revisions 1-5 carried a fail-closed guard for one specific state:

> `[providers.openai]` exists with a key but **no** `base_url` — the shape
> `handleProviderCreate` produces by calling `upsertProvider` to seed
> `default_model` (`Config/File.hs:828-830`). Before the rename that state failed
> closed and transmitted nothing. After it, `openai` has a built-in endpoint, so
> that stored key would be sent to `api.openai.com`.

With no users (D1, re-ratified), **that state cannot exist on any install.**
The guard, the three cases it distinguished, its `Map.member`-vs-`providerBaseUrl`
subtlety, the `usable` empty-string test, and the three write paths that existed
only because the guard would otherwise dead-end its own happy path are all
unnecessary. They are **removed from this design**, not deferred.

What that deletes:

| Removed | Why it existed |
|---|---|
| The §3.1 case-3 guard in `resolveProvider OpenAIProvider` | Protect a pre-existing section — none can exist |
| Create-path `base_url` injection in `handleProviderCreate` | Stop the guard dead-ending a UI-created provider |
| `PUT` repair matrix in `handleProviderUpdate` | Repair a case-3 section from the Providers page |
| `addCmd`'s `base_url` write + its absence-scoping | Make the guard's named remedy (`/provider add openai`) not a no-op |
| The two-parameter `resolveOpenAICompatible` (`hasBuiltInEndpoint`) | Drop the "the setup wizard asks for it" parenthetical for built-ins |

**`handleProviderCreate`, `handleProviderUpdate`, `addCmd` and
`resolveOpenAICompatible` are therefore UNCHANGED.** `upsertProvider` still
writes a section *without* `base_url` — and that is now the **normal, correct**
state for a built-in provider, exactly as it already is for Anthropic:
`providerBaseUrlFor` supplies the built-in default at resolution time.

**Reachability audit — what used to need the guard, and why nothing does now.**

- A scripted `POST {"name":"openai","api_key":…}` with no `base_url` now resolves
  to `api.openai.com`. That is the **happy path**: the caller asked for OpenAI
  and supplied an OpenAI key. The UI offers no way to point OpenAI elsewhere
  (D7 hides the field).
- An operator with a self-hosted endpoint selects **OpenAI-compatible**, which
  still *requires* an explicit `base_url` (item 42). "A key meant for a
  self-hosted server" therefore cannot reach `openai` by the product's own
  affordances.
- No stored secret is orphaned by the `OPENAI_API_KEY` reassignment (D3), because
  none exists.

**One place the old behaviour was still wrong: a developer artifact, not a user
config.** `scripts/setup-walkthrough.sh` POSTs
`{"name":"openai","api_key":"sk-local"}` with no `base_url` and then calls the
test endpoint (§3.3). That is re-keyed to a custom name — corrected, not guarded.

**What the rename still costs:** one CHANGELOG line recording that `openai` is
now real OpenAI and the generic type is `openai-compatible`.

### 3.2 The setup step's P4 copy

`classifyProvider`'s P4 detail currently reads "Add an LLM provider: anthropic,
openrouter, ollama, or an OpenAI-compatible endpoint." Updated to name the new
options without becoming an unreadable inventory — the operator sees the radio
list directly beneath it, so the sentence stays short.

### 3.3 `scripts/setup-walkthrough.sh` must be re-keyed

Steps 8b–8f POST `{"name":"openai", …}` to exercise the generic type's
fail-closed behaviour:

```sh
8b. POST /api/providers {name:openai, api_key} with NO base_url
8c. POST /api/providers/openai/test (fails closed: the endpoint is required)
```

After the rename, `name: "openai"` **is real OpenAI** and has a built-in
endpoint, so 8b succeeds instead of failing closed and 8c performs a **real
request to `https://api.openai.com/v1`** carrying `sk-local`. No user config is
involved — this is a script developers run locally — so it is fixed by
correcting the script, not by keeping a guard.

The whole block is re-keyed to a custom name (`local-vllm` with
`type: "openai-compatible"`), which preserves the original intent — a generic
endpoint still requires an explicit base URL and still fails closed without one
— and removes the egress.

## 4. Files touched

### Backend

| File | Change |
|---|---|
| `src/Seal/Providers/Registry.hs` | +2 constructors; every total function updated: `providerLabel`, `vaultKeyName`, `defaultModelFor`, `providerBaseUrlFor`, `resolveProvider`, `configuredProviders`, `validateProviderName`. `resolveProvider OpenAICompatibleProvider`'s hardcoded `"openai"` argument → `providerLabel OpenAICompatibleProvider` (that string names the config section in its fail-closed error). Both new constructors delegate to `resolveOpenAICompatible` with their built-in default as the base URL, so its `T.null baseUrl` branch is unreachable **through any product affordance** (D7 hides the field). It remains reachable only if an operator hand-writes `[providers.openai] base_url = ""`, where failing closed is the correct outcome (`providerBaseUrlFor` returns `""` for an explicitly empty value — `fromMaybe builtIn (Just "")` is `""`). Item 21b pins it. Its signature is unchanged; one word of the message is neutralised (`"the OpenAI-compatible provider"` → `"provider"`), which reads correctly for all four callers including real OpenAI. **No case-3 guard** (§3.1). `providerTypeForName` needs **no** change (already `fromMaybe OpenAICompatibleProvider`). `knownProviders` order (D2). |
| `src/Seal/Setup/State.hs` | `providerDisplayName` +2; `providerCards` raises no flags for the new types (already constructor-keyed); P4 copy. |
| `src/Seal/Gateway/API.hs` | `providerAuthStatus` +2 and `staticModelsFor` +2 (**these two are WU1 work** — wildcard-free exhaustive cases, so the library will not compile without them; see §5.6); `providerDetailJsonFor` gains `requiresBaseUrl`/`requiresName`; `customProviderDetailJson` type id → `openai-compatible`; **`:715`** the `customInfos` `"type"` literal → `openai-compatible`; **`:3246`** the readiness guard `typeId /= "openai"` → `typeId /= "openai-compatible"` (otherwise it becomes a tautology and custom instances inherit Ollama readiness); `resolveCreateTarget` / `resolveExistingTarget` type ids and the required-type check; `handleProvidersAll` unchanged (mapM over `knownProviders` picks up the new rows). |
| `src/Seal/Gateway/Setup.hs` | `handleProviderTest`'s "known providers" hint text. Card JSON already emits both booleans — no change. |
| `src/Seal/Command/Provider.hs` | **No change.** `addCmd`'s generic path already prompts for a key for any non-`ollama` type, and `seedProviderDefaults` seeds `rcDefaultProvider`/`pcDefaultModel`. It does not write `base_url` — correct now that a section without one is the normal state for a built-in provider (§3.1). `providerReadinessSegment` already returns `""` for non-`ollama`. The help text listing known ids is generated from `knownProviders`. **Not fixed here:** `authLabel` (`:255-266`) probes `anthropicOAuthKey` in its `otherwise` branch, so it reports `auth: oauth` for any non-Ollama provider when Anthropic OAuth exists — pre-existing, already wrong for OpenRouter. Separate PR (§6). |
| `CHANGELOG.md` | One `0.1.0.0` bullet: `openai` is now **real OpenAI** (`https://api.openai.com/v1`); the generic type is `openai-compatible`; `ollama-cloud` is added for Ollama's hosted OpenAI-compatible endpoint. No migration instructions — there are no users (D1, §3.1). |
| `scripts/setup-walkthrough.sh` | Steps 8b–8f re-keyed from `name: "openai"` to a custom name with `type: "openai-compatible"`. See §3.3 — leaving it as-is turns a developer script into a live request to `api.openai.com`. |
| `config/templates/config.toml` | Comment block gains the new ids; the generic example is re-keyed to `openai-compatible`. No migration note (§3.1). |

**Not touched:** `src/Seal/Providers/OpenRouter.hs` (reused as-is),
`Seal.Providers.Ollama`, `Seal.Providers.OllamaReadiness*` (no readiness for
the new types), `Seal.Providers.ContextWindow` (D10), the ISA, any opcode.

### Frontend

| File | Change |
|---|---|
| `frontend/src/types.ts` | `ProviderDetail` +`requiresBaseUrl` / `requiresName`; comment updates on `type`. |
| `frontend/src/lib/providerLabels.ts` | labels for `openai` / `ollama-cloud` / `openai-compatible`. The generic row renders **"OpenAI-compatible (custom / self-hosted)"** in dropdowns, since the id no longer disambiguates it from real OpenAI. |
| `frontend/src/components/ProvidersView.tsx` | label map; drive Base URL visibility from `isHiddenBaseUrl` and Unique name from `requiresName` (when creating, both from the dropdown's own `ProviderDetail` row — D7), **not** from a generic 'flags' notion that could be misread as `requiresBaseUrl` instead of `formName === 'openai'`; **pass `showBaseUrl` explicitly at the `ProviderFormFields` call site** (and `showModels`/`showDefaultModel` as `true` — no flag drives them and no behavioural change is intended) (it currently omits `showBaseUrl`, which defaults to `true`, so edit renders Base URL for every provider); **gate the submitted payload on `!isHiddenBaseUrl` (not `requiresBaseUrl`), and clear `baseUrl`/`uniqueName` when `formName` changes** (RG-2); custom-instance `type: 'openai-compatible'`; reserved-name set. |
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
    contains `"openai"` and **not** `"OpenAI-compatible"` (the neutralised noun;
    real OpenAI is not described as a generic compatible endpoint).
19. **RED** `resolveProvider OllamaCloudProvider` with no key ⇒ `Left` whose text
    contains `"ollama-cloud"` and **not** `"OpenAI-compatible"`.
20. **RED** `resolveProvider OpenAICompatibleProvider` with no vault ⇒ `Left`
    naming the config section **`openai-compatible`**, asserted as
    `"[providers.openai-compatible]" isInfixOf e` **and**
    `"[providers.openai]" notInfixOf e`. A bare `openai` substring check passes
    when it should fail, because `"openai-compatible"` contains `"openai"`.
20b/20c. **REMOVED (re-ratified).** Both items pinned branches of the §3.1
     case-3 guard and the display-noun parameterisation of
     `resolveOpenAICompatible`. With the guard deleted (§3.1) there is no branch
     to pin, and with the helper's noun neutralised there is no second display
     string to confuse. Item 20 still pins the section key for the generic type,
     which is the reachable case.

21b. **RED** An explicitly **empty** `base_url` fails closed, and does so for both
    new types: `resolveProvider OpenAIProvider` with `[providers.openai] base_url = ""`
    returns `Left` (it does **not** silently fall back to the built-in), and
    likewise for `ollama-cloud`. This is the one state in which the built-in
    default is *not* used, so it is worth pinning separately from item 11 —
    `providerBaseUrlFor` yields `""` for an explicit empty string, and the
    correct reading of an explicit `""` is "the operator configured something
    unusable", not "use the default".

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
28. **RED** `POST {"name":"openai","api_key":"sk-…"}` ⇒ 201, and **no**
    `base_url` is stored for it (`providerBaseUrl cfg "openai" == Nothing`).
    A section without `base_url` is the normal state for a built-in provider
    (§3.1) — the built-in default is applied at resolution time, exactly as for
    Anthropic. Item 35b pins that resolution still succeeds.
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
     `resolveProviderByName "openai"` returns `Right` **and** the persisted
     config has `pcBaseUrl == Nothing` — the provider resolves off the built-in
     default, not a stored copy. This is the round-trip that item 28 cannot
     cover: a stored `base_url` and a resolved provider are different facts.
35c. **RED** Same for `ollama-cloud`.
35d. **RED** Submit-gating: with OpenAI-compatible selected and a base URL typed,
     then switching to OpenAI, the submitted payload carries **no** `base_url`
     and **no** `type` (RG-2) — **and** `name: "openai"` is present, since `name`
     is mandatory. An absence-only assertion would pass on a payload that 400s.
35e-35k. **REMOVED (re-ratified).** These pinned the §3.1 guard's three
     branches and the three write paths that served it: create-path injection
     (35f), PUT repair matrix (35j), `/provider add` clearing the guard (35h),
     case-2/case-1 branch coverage (35g, 35i). With no users the guarded state is
     unreachable (§3.1), and `handleProviderCreate` / `handleProviderUpdate` /
     `addCmd` are unchanged. Items 35b and 35c remain the round-trip proof that a
     created provider actually resolves.

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
45b. **REMOVED (re-ratified).** It pinned the survival of a *legacy*
    `OPENAI_API_KEY` across deleting `openai-compatible`. No legacy key can exist
    (§3.1). D3's injectivity invariant is still pinned through DELETE by item 45,
    which needs no legacy state.

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
  (items 1-21, less the removed 20b/20c, plus the four `RegistrySpec` updates)
  **plus every wildcard-free match over `KnownProvider` outside `Registry.hs`**.

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
  | 5 | `resolveProvider` (5 equations: `Nothing`+4 constructors) | `Registry.hs:188-247` |
  | 6 | `isConfigured` (local case in `configuredProviders`) | `Registry.hs:360` |
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
  `"type"` literal (`:715`) / the readiness guard (`:3246`) + `types.ts` +
  `ProvidersView.tsx` + `ProviderStep.tsx` + `ProviderFormFields.tsx` + label
  maps + `ActiveTabs.tsx` + items 25-39 and their test updates.
  (`providerAuthStatus` and `staticModelsFor` are WU1 - see above.)
  **`handleProviderCreate`, `handleProviderUpdate` and `Command/Provider.hs` are
  NOT in this unit** — they are unchanged (§3.1).

  WU3 **cannot** be split: the frontend is embedded via `file-embed`, so client
  and server ship together, and `type: "openai"` for a custom name must start and
  stop being valid in the same commit.

**Unowned files, assigned.** §4 lists four files that no work unit above names:
`Gateway/Setup.hs` (the "known providers" hint text), `CHANGELOG.md`,
`config/templates/config.toml`, and `scripts/setup-walkthrough.sh`. All four go to
**WU3**, which is already the "touch everything that must ship atomically" unit.
`src/Seal/Command/Provider.hs` is not among them: it is now unchanged (§5.6, §3.1).

Completion gate: `make check` (build + test + lint) plus the frontend test
suite, per the Makefile, and `.coverage-thresholds.json`'s enforcement command.

## 6. Non-goals

- Renaming the existing custom-instance concept, or changing
  `vaultKeyNameForName` / `customProviderNames`.
- Consolidating the four duplicated `PROVIDER_LABELS` maps into one (an
  existing, documented follow-up). This change adds entries to each; it does not
  merge them.
- Adding readiness probing for Ollama Cloud.
- Config migration of any kind. There are no users to migrate (§3.1).
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
  `[providers.ollama] base_url = "https://ollama.com"`. There are no users, so
  there is nobody to prompt (§3.1).
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
| A missed site in a **total function over `KnownProvider`** | `-Werror` + `-Wincomplete-patterns`: the compiler names every such site. This holds **only while those functions have no `_ ->` fallback** — adding one silently opts every future constructor out of the compiler's help. All **nine** sites enumerated in §5.6 must stay wildcard-free — `providerLabel`, `vaultKeyName`, `defaultModelFor`, `builtInBaseUrl`, `resolveProvider`, `isConfigured`, `providerAuthStatus`, `staticModelsFor`, `providerDisplayName`. The two lists must not drift: §5.6 is the authority, and a tenth site added later belongs in both. |
| A missed **label string comparison** — the compiler is blind to these | Enumerated exhaustively and each given a test: `Registry.hs:242` (the fail-closed section name, item 20), `API.hs:715` (custom `type`), `API.hs:3246` (readiness guard), `Registry.hs:118` (reserved names, item 13), `ProvidersView.tsx:247` (custom-ness, item 36). The `"ollama"` comparisons at `State.hs:294`, `Provider.hs:175/256/279`, `API.hs:3182` are **correct as-is** (Ollama-only semantics) and are pinned by guard items. |
| Frontend and backend disagree on which types hide the fields | Server-driven flags (D7) plus item 36 pinning the creating-state helper. |
| Secret egress to a third party after the `openai` rename | **Unreachable, not guarded**: the only affected state is a *pre-existing* `[providers.openai]` section, and there are no users (§3.1). Selecting OpenAI and pasting an OpenAI key resolving to `api.openai.com` is the happy path; a self-hosted endpoint must use `openai-compatible`, which still requires an explicit `base_url` (item 42). §3.3 removes the one place a developer would reproduce the stale shape. |
| A write path clobbering an operator's configured endpoint | No write path fills `base_url` any more — the create path, `PUT` and `addCmd` are unchanged and never write it unless the request supplies one (§3.1). There is nothing to clobber. |
| A provider created through the UI failing to resolve because no `base_url` was stored | That is the intended shape (§3.1): `providerBaseUrlFor` supplies the built-in at resolution time, exactly as for Anthropic. Item 35b round-trips create → `resolveProviderByName` and fails if it does not resolve. |
| A hidden field still being *shown* in edit mode (`showBaseUrl` defaults to `true`; only the wizard passes it) | Both call sites pass `showBaseUrl`/`showModels`/`showDefaultModel` from the flags; item 34a asserts the edit path specifically. |
| A hidden field still leaking a value into the payload (stale `base_url`) | The payload is gated on `!isHiddenBaseUrl` (visibility) and `requiresName`, and `formName` changes clear the fields (D7, RG-2). Items 35d and 41b pin it. |
| A stale tab POSTs the old `type: "openai"` | 400 with a clear message; reload fixes it (D8). |
| Six rows make the wizard list long | Acceptable at this count; vendor-adjacent grouping (D2) keeps it readable. |
| A 0 context window looking like a bug | It renders as *no percentage* (`BottomBar.tsx:37`), which is honest (D10). |
