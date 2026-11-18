# Design revision 3 — round-1 review consolidation

Round 1 verdicts: CTO NEEDS_REVISION, Product NEEDS_REVISION, Designer
NEEDS_REVISION, Security **APPROVED** (with two required mitigations).
Architect still running.

Every claim below was re-verified against the code by the orchestrator.

## RG-1 — Case 3 needs a decidable guard, not prose (PM blocker + Security MEDIUM)

Two reviewers converged here from different angles:
- **Product:** a 401 *proves* transmission; it is not evidence of harmlessness.
  Neither CHANGELOG nor a config template reaches an operator with a stale
  `[providers.openai]` section.
- **Security:** rated **MEDIUM** — bytes that never left the machine now leave
  it, unprompted, to a third party.

**Reachability confirmed:** `handleProviderCreate` stores the key *before* it
ever needs a base URL (`storeProviderKey` runs before `seedCfg`), so
`{"name":"openai","api_key":"…"}` with no `base_url` succeeds today and creates
exactly the hazardous config. The project's own
`scripts/setup-walkthrough.sh:80` (**step 8b**) does precisely this. So this is
not a hypothetical legacy state — the repo manufactures it.

### The fix: decidable, no new config field

`resolveProvider OpenAIProvider` fails closed **iff** a `[providers.openai]`
section exists but carries no `base_url`:

| State | Behaviour |
|---|---|
| No `[providers.openai]` section | Use the built-in `https://api.openai.com/v1`. (Fresh install — nothing pre-existing to leak.) |
| Section **with** `base_url` | Use it. (Case 1 — works, unchanged.) |
| Section **without** `base_url` | **Fail closed.** "This key predates the OpenAI provider type — run `/provider add openai` to confirm it belongs to OpenAI." |

The create path (UI and `/provider add`) now writes `base_url` **explicitly**
when it creates an OpenAI provider. So a provider configured through the product
always has a section *with* a base_url and resolves normally; only a
pre-existing, never-confirmed section fails closed, once, with an actionable
message. `OllamaCloudProvider` needs no guard — it is brand new, so no legacy
section can exist.

Why this over the security agent's `key_namespace` marker: it reuses existing
config machinery (`providerBaseUrl cfg name` already returns `Maybe`, so
"section exists but field absent" is already observable), adds no new field, and
is decidable. The marker would work too but is more surface for the same
guarantee.

Rejected alternative: requiring re-entry of the key always. That breaks case 1
(base_url pointed at localhost — a *working* config) for no benefit.

## RG-2 — Stale form state leaks a hidden `base_url` (Designer blocker)

Verified. `ProvidersView.tsx:496` sets `formName` without resetting `form`, and
`:269` sends `base_url` whenever non-empty **regardless of visibility**. So:

1. select **OpenAI-compatible** → type `http://localhost:8000/v1`;
2. switch to **OpenAI** → the field is hidden but `form.baseUrl` survives;
3. Save → writes `[providers.openai] base_url = "http://localhost:8000/v1"`.

That contradicts D4 (operator must not supply it) and item 28. Same hazard for
`uniqueName` (`:259`, `:265`).

**Fix:** gate on the flag, don't infer from presence — send `base_url` only when
`requiresBaseUrl` is true, and `type`/`name` only when `requiresName` is true.
Also clear `baseUrl`/`uniqueName` when `formName` changes. This is the exact
class of defect D7 exists to prevent, so it belongs in the design, not in
implementation discovery.

**Designer's open question answered:** `providerDetailJsonFor` emits
`providerBaseUrl cfg name` — the **config-only** accessor
(`Config/File.hs:742`), which returns `Nothing` absent a section. So it does
**not** emit the built-in default; a never-configured `openai` reports
`baseUrl: null`. The edit path therefore cannot pin the default by itself *today*
— but once RG-1's create path writes `base_url` explicitly, it legitimately
becomes non-null, and the flag-gated resubmit keeps that idempotent.

## RG-3 — `ProviderStep.tsx:147` (CTO + Designer, both blockers)

Independently found by both. `saveKey` sends `...(needsName ? { type: 'openai' }
: {})`. After D2 only `openai-compatible` has `requiresName: true`, so every
wizard custom instance sends `type: 'openai'` → 400. §4 must name the POST body,
not just the reserved-name array. (Already added in revision 2; retained.)

## RG-4 — D7 must name the creating-state source (Designer)

While `creating === true`, `selected` is `null` (`ProvidersView.tsx:220-223`), so
the flags cannot come from `selected`. The correct source is the dropdown's own
`ProviderDetail` row — both option lists already iterate `providers` from
`GET /api/providers/all`, so
`providers.find(p => p.name === formName)?.requiresBaseUrl` is available for
every selectable type. D7 now says so explicitly.

## RG-5 — §5 needs a user-outcome test (PM blocker)

Every frontend item asserted field *absence*. None asserted an operator can
**finish**. Add:

- **RED** Providers page: with only an API key entered for `openai` (no base
  URL, no unique name), Save is **enabled** and submits successfully.
- **RED** Wizard: with only an API key, the primary action is **enabled**.
- **RED** `POST /api/providers {"name":"openai","api_key":…}` then
  `resolveProviderByName "openai"` yields `Right` — i.e. the provider actually
  answers, not merely that it stored.
- **RED** Same for `ollama-cloud`.

And §1 states the measurable benefit: OpenAI setup drops from two typed fields
plus one recalled URL to a single paste, with zero base-URL typos.

## RG-6 — DELETE / vault-retention semantics (Security)

- `handleProviderDelete` for `openai-compatible` deletes
  `OPENAI_COMPATIBLE_API_KEY`, so a legacy `OPENAI_API_KEY` **survives**.
  Must be a documented decision, not an accident. Adopt: **retain**, and say so,
  because deleting it would break a working OpenAI setup. Add a test pinning it.
- Add the symmetric injectivity probes: delete `ollama` ⇒
  `providerAuthStatus ollama-cloud` still `api-key`; delete `openai-compatible`
  ⇒ `providerAuthStatus openai` unchanged.
- Do not start emitting `baseUrl` for hidden-field types in the *create
  response* as a side effect of the `requiresBaseUrl` refactor.

## RG-7 — D9's rejection message should name the alternative (PM)

`"… is a built-in provider type; choose another name"` → append a concrete
example, e.g. `… choose another name (for example "my-openai-endpoint")`. Small,
and it is the only guidance a blocked operator gets.

## RG-8 — The `ollama` + `ollama.com` population already has a signal (PM Q5)

PM asked whether operators already on `[providers.ollama] base_url =
"https://ollama.com"` are told the first-class type exists. Partly **yes**,
already: that config gets readiness `RdCloud`, and `ProvidersView` renders a
**"Cloud"** badge (the `readiness === 'cloud'` branch). So the operator can see
they are on the cloud path.

Decision: **no** in-product migration prompt in this change (new backend logic
in `providerDetailJsonFor` for a one-line hint is scope creep against the
one-logical-change rule). Instead the CHANGELOG names the migration explicitly.
Recorded as an explicit non-goal with the existing badge cited as the discovery
hook.

## RG-9 — D2's reordering is justified, not cosmetic (PM)

PM called the reordering churn. It is deliberate: appending would yield
`anthropic, ollama, openrouter, openai, ollama-cloud, openai-compatible`
— separating Ollama from Ollama Cloud and OpenAI from OpenAI-compatible, so two
pairs of near-identical rows land non-adjacent. Vendor grouping is better for a
six-item list. Cost is one test vector (already budgeted). Retained, now with the
rationale stated.

## RG-10 — Label disambiguation (Designer)

Generic row renders **"OpenAI-compatible (custom / self-hosted)"** in the
dropdown, since the id no longer disambiguates it from real OpenAI.
