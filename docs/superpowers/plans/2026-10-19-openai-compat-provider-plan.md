> **Superseded** by `docs/superpowers/specs/2026-10-19-provider-families-design.md`
> and `docs/superpowers/plans/2026-10-19-provider-families-plan.md` — the generic
> provider is now `openai` and `openrouter` is a fixed-URL provider. Kept for history.
# Plan: Generic OpenAI-compatible provider (`openrouter` → `openai-compat`)

Issue: #271 · Design (approved, rev 6): `docs/superpowers/specs/2026-10-19-openai-compat-provider-design.md`
Branch: `provider/openai-compat-271` (off `main`)

**Gates.** `make check` after every unit. It is `build → frontend-build → cabal
test → hlint`, and `frontend-build` is `npm run build` = `tsc && vite build`, so
the frontend typecheck *is* in the gate. `make frontend-test` (vitest) for WU-7.
The repo's `.coverage-thresholds.json` sets `enforcement.command = "make test"`,
a subset of `make check`.

## Scope

Tasks 1 and 2 of the issue. Task 3 (`openai`/`openrouter` presets) is out of
scope and stays a one-row change (design §11, verified by WU-2's dry-run tests).
Design §14 records what is deferred: REST mutation guard, gateway listener
binding, key-byte redaction, the metadata/SSRF denylist, the editor-side
insecure-URL warning, and three pre-existing frontend API gaps
(`displayName`/`defaultModel`/`isDefault` on `/api/providers`,
`useNewTabSpec` preselection).

**Product decision to flag in the PR body:** the generic row is keyless-capable
(`ocsKeyRequired = False`, design §4.1). The issue does not ask for this, but a
local vLLM/llama.cpp/LM Studio endpoint is the archetype of "another service
with the same API", and the alternative is storing a fake secret in the vault.
A key, when present, is still stored and sent, and the row reports `api-key`
(design §4.6 as amended).

## Execution model

Sequential units, TDD per unit (RED → GREEN), `make check` before each commit.
A unit is one commit unless it says otherwise: **WU-1** is two commits (rename,
then transport behaviour) and **WU-7** is two (the `frontend-test` target, then
the UI). Human checkpoints after **WU-1**, after **WU-2b** (the contract every
later unit consumes), and after **WU-6**. No `--no-verify`, no force-push.

---

## WU-1 — Rename + transport

**Files:** `src/Seal/Providers/OpenRouter.hs` → `src/Seal/Providers/OpenAICompat.hs`
(module, spec type **and the `genericOpenAICompat` catalog row** — `chatHeaders`
takes a spec, so the row must exist in this unit);
`src/Seal/Providers/Registry.hs` (import + `mkOpenAICompat` call site);
`src/Seal/Agent/Loop.hs` (export `isTransientError`);
`seal-harness.cabal`; `test/Seal/Providers/OpenRouterSpec.hs` →
`OpenAICompatSpec.hs`; `test/Seal/Providers/RegistrySpec.hs` (identifiers);
`test/Main.hs`

**Step 1 — own commit, no behaviour change.** `git mv` the module and spec;
rename `OpenRouter` → `OpenAICompat`, `mkOpenRouter` → `mkOpenAICompat`,
`orApiKey/orBaseUrl/orManager` → `oacApiKey/oacBaseUrl/oacManager`,
`orDefaultModel` → `oacModel`; drop the unused `openRouterBaseUrl` export; keep
`defaultOpenRouterBaseUrl` until WU-2. Update `Registry.hs`, cabal,
`test/Main.hs`, and the two specs' identifiers.

*RED protocol (compile-breaking commit):* the new files do not exist until the
move; the build fails until cabal/`test/Main.hs`/`Registry.hs` are wired, then
the ported assertions pass **unchanged** (identifiers only). No behaviour is
claimed in this commit.

**Step 2 — RED first.**
1. `chatHeaders Nothing spec` has no `authorization` key (assert absence).
2. `chatHeaders (Just key) spec`: the bytes appear only as the
   `Bearer `-prefixed `authorization` value; no header value equals the bare key.
3. `ocsExtraHeaders` are appended; names in
   `{authorization, host, content-length, content-type}` are dropped (injected
   spec).
4. `validateBaseUrl` accepts `https://h/v1`, `http://localhost:8000/v1`,
   `http://192.168.1.10:11434`, `http://[::1]:8000/v1`; `HTTPS://Host/v1` ⇒
   `Right "https://Host/v1"`; `"  https://h/v1//  "` ⇒ `Right "https://h/v1"`.
5. Rejects with the exact reason: `""`/`"   "`/`"\t"` (`empty`); `h/v1`,
   `//h/v1`, `http:/h`, `ftp://h/v1`, `file:///v1`, `ws://h`; `https://`,
   `http://:8000/v1`; `https://user:pw@h/v1`, `https://user@h/v1`;
   `"https://h/v1\r\nHost: evil"`, `"https://h/v1 x"`; `https://h:99999/v1`;
   `https://h/v1?x=1`, `https://h/v1#f`. (No metadata denylist — deferred, §14.)
6. QuickCheck (bounded: small alphabet, length ≤ 60): every `Right` has no
   whitespace/control char and no `@` before the first `/`; idempotent;
   `chatUrl` never yields `//chat/completions` and always ends in exactly one
   `/chat/completions`.
7. `httpErrorText spec code body`: 401 keyed vs keyless (two §6 messages), 403
   reuses those rows, 404 names `/v1` **and** the model id, 429 keeps the
   literal `HTTP 429`, a 5 000-char body is truncated to 2 000 and single-lined.
8. `decodeResponse` empty `choices` ⇒ `<N> returned no choices`; malformed ⇒
   "unreadable response".
9. `sendChatCompletion` with an unparseable base URL (`"http://"`) ⇒ `Left`, no
   escaping exception.
10. `complete` with `crModel = ModelId ""` ⇒ the §6 no-model message, no
    network call.
11. Warp mock (`testWithApplication`, template `ModelSpec.bracketMockOllama`):
    base URL `http://127.0.0.1:PORT/openai/v1/`; keyless `complete` ⇒ canned
    completion, mock saw `POST /openai/v1/chat/completions` with **no**
    `authorization` header.
12. Warp mock with a **key**: `complete` sends `authorization: Bearer …`
    (proves the key path end-to-end for the family row).
13. Warp mock returning `302` ⇒ the redirect message, `isTransientError` (now
    exported) does **not** match it, and the redirect target is never requested.
14. Warp mock returning `401` for a keyless spec ⇒ the keyless 401 message.

**GREEN**
`OpenAICompatSpec` type + `oacSpec`; `chatHeaders`; `validateBaseUrl`;
`chatUrl`; spec-parameterised `httpErrorText` with single-lining + 2 000-char
truncation; `parseRequest` inside the `try`; `redirectCount = 0` +
`shouldStripHeaderOnRedirect = const True` with `TooManyRedirects`/3xx mapped to
the non-transient message; `complete` sends without `authorization` when no key
and errors on an empty `crModel`. Delete the old no-key `complete` test and the
old `listModels` test.

**DoD**
1. Every RED test exists and is green.
2. No test performs I/O to a non-loopback host: every `mkOpenAICompat` /
   `complete` / `sendChatCompletion` value in the spec is built with a
   `127.0.0.1:<port>` base URL (the `https://…` literals are validator inputs
   only).
3. `rg -n 'System\.Process|System\.Directory|System\.Posix' src/Seal/Providers/OpenAICompat.hs`
   empty; no provider-id literal or label comparison in that module.
4. `make check` green.

**Checkpoint (human).**

---

## WU-2 — Catalog, base URL, resolution, status

**Files:** `src/Seal/Providers/OpenAICompat.hs` (catalog row),
`src/Seal/Providers/Registry.hs`, `src/Seal/Gateway/API.hs` (delete the local
`providerAuthStatus`; import the shared one; update `OpenRouterProvider`
matches), `src/Seal/Config/File.hs` (docs), `test/Seal/Providers/RegistrySpec.hs`,
`test/Seal/Config/FileSpec.hs`, `test/Seal/Gateway/ApiSpec.hs` (the provider
label change makes the `byName` fixture at `ApiSpec.hs:3691` fail here, not in
WU-6)

**RED**

*Catalog / vocabulary*
1. `knownProviders == [AnthropicProvider, OllamaProvider,
   OpenAICompatProvider genericOpenAICompat]`; `catalogProblems
   openAICompatSpecs == []`; `catalogProblems` reports a duplicate id and a
   blank id on synthetic lists; `map providerLabel` has no duplicates.
2. `parseProviderIn syntheticCatalog "acme"` finds a row appended to a synthetic
   two-element catalog; `parseProvider "openai-compat"` / `"OpenAI-Compat"`
   resolve.
3. `vaultKeyName` ⇒ `"OPENAI_COMPAT_API_KEY"`; `providerDisplayName` ⇒
   `"OpenAI-compatible"`.

*Base URL*
4. `providerBaseUrlFor`: family with no config ⇒ `Left` whose text is the §6
   missing-URL message (contains `needs a base URL` and `Providers view`);
   `"https://h/v1/"` ⇒ `Right "https://h/v1"`; `"ftp://h"` ⇒ `Left` with the
   `scheme` reason; **injected preset** (`ocsBuiltinBaseUrl = Just u`) ⇒
   `Right u` with **empty config** and with a conflicting configured URL;
   `chatUrl` of the preset result targets `u` single-slashed; ollama with
   `base_url = "localhost:11434"` (no scheme) ⇒ `Right` unchanged.
5. `resolveProvider` ollama still works after the `Either` change (local keyless,
   cloud with key) — the `ollamaNeedsKey` guard is restructured against the
   `Right` value.

*Resolution / status*
6. `resolveProvider` family: keyless + no vault handle ⇒ `Right`; keyless +
   `makeLockedVault` ⇒ `Right`; keyless + a readable key ⇒
   `Right` and the provider carries the key (asserted via the WU-1 keyed mock or
   an accessor); `ocsKeyRequired` (injected spec) + no key ⇒ `Left` naming
   `/provider add`; + locked vault ⇒ `Left` naming `/vault unlock`; + no vault
   handle ⇒ `Left` naming `/vault setup`; base-URL error precedes the key error.
7. `configuredProvidersFor` with an injected key-required spec: excluded without
   a key, included with one. Shipped catalog: family excluded when the base URL
   is missing, included when it resolves.
8. `providerAuthStatus` (now in the library): `none` (no base URL) → `keyless`
   (base URL, no key) → `api-key` (base URL + key) for the shipped row; the
   key-required injected spec: `none` / `vault-locked` / `api-key`; ollama
   local ⇒ `keyless`, `ollama.com` with key ⇒ `api-key`. Invariants (§4.6) for
   all providers with an unlocked **and** a locked vault.
9. `Config/FileSpec`: `[providers.openai-compat]` (hyphenated key) round-trips
   `upsertProvider` → `saveRuntimeConfig` → `loadRuntimeConfig` with `base_url`
   + `default_model`.

**GREEN**
Catalog + `KnownProvider` payload (drop `Enum`/`Bounded`) +
`providerDisplayName` + `catalogProblems` + `parseProviderIn` +
`configuredProvidersFor` + **`providerAuthStatus` moved into the Registry**
(shared by CLI and gateway) + `providerBaseUrlFor :: … -> Either Text Text` +
family/ollama `resolveProvider` + `Config/File.hs` doc note. Remove
`defaultOpenRouterBaseUrl`.

**DoD**
1. All RED green; `RegistrySpec`'s three `providerBaseUrlFor` assertions
   rewritten for `Either` (not deleted), plus the five existing assertions the
   rename/keyless rule flips: `providerLabel OpenRouterProvider`
   (`RegistrySpec.hs:90`), and the four family/ollama key assertions at
   `RegistrySpec.hs:231-251` which change from `Left` to `Right`.
2. `rg -n 'providerAuthStatus' src/` shows one definition (Registry) and one
   import (API).
3. `make check` green.

---

## WU-2b — Legacy recovery copy + `new -p`

**Files:** `src/Seal/Providers/Registry.hs` (hint helper),
`src/Seal/Command/Provider.hs` (`resolveSessionProvider`,
`resolveDefProvider`), `src/Seal/Command/New.hs`,
`test/Seal/Command/{ProviderSpec,NewSpec}.hs`

**RED**
1. `resolveSessionProvider` with `smProvider = "openrouter"` ⇒ `Left` containing
   `renamed to openai-compat`, `/provider add openai-compat` **and** `/model use
   openai-compat`.
2. `resolveDefProvider "openrouter"` ⇒ `Left` containing `renamed to
   openai-compat` and `provider line`.
3. `new -p openrouter` ⇒ the §6 message and **no session directory created**;
   `new -p openai-compat` still works.

**GREEN** `legacyProviderHint :: Text -> Maybe Text` (one place, three
surfaces); `New` validates `-p` with `parseProvider` before minting.

**DoD** All RED green; `make check` green. **Checkpoint (human):** the
catalog/base-URL/status/legacy contract every later unit consumes.

---

## WU-3 — Model plumbing (`Maybe` default model)

**Files:** `src/Seal/Providers/{Registry,OpenAICompat}.hs`,
`src/Seal/Session/Store.hs`, `src/Seal/Command/{Model,New,Provider}.hs`,
`src/Seal/Gateway/API.hs`,
`test/Seal/Providers/RegistrySpec.hs`, `test/Seal/Session/StoreSpec.hs`,
`test/Seal/Command/{ModelSpec,NewSpec,ProviderSpec}.hs`

**RED**
1. `defaultModelFor (OpenAICompatProvider genericOpenAICompat) == Nothing`;
   `resolveDefaultModel (Just "") _ == Nothing`; unknown label ⇒
   `Just (ModelId "claude-opus-4-8")` (existing test preserved).
2. `defaultSessionSelection` with `default_provider = "openai-compat"` and no
   model ⇒ `("openai-compat", "")`.
3. `listModels` for the family = the exact deduped `ocsModels ∪ {oacModel}`
   (injected spec with models); never `[ModelId ""]`.
4. `/model use openai-compat` (no model arg) ⇒ error, `smModel` unchanged.
5. `/model list openai-compat` ⇒ `… has no models — set one with /model use …`;
   quiet `/model list` fallback branch prints `(default model: none — …)`.
6. `New` with an inherited empty model ⇒ `resolveDefaultModel` for the target
   provider (`new -p anthropic` from a model-less family session ⇒
   `claude-opus-4-8`).
7. `/provider default openai-compat` ⇒ the §6 confirmation, both variants
   (`(model: …)` and `(no default model — …)`).

**GREEN** `defaultModelFor`/`resolveDefaultModel` → `Maybe`; every call site per
design §4.4 (**including** `Command/Provider.hs` seeding/`defaultCmd`/`testCmd`
and `Gateway/API.hs` seeding/`parseProviderModel`); `listModels`; `/model use`
guard; `New` repair; `parseProviderModel` stops substituting `"llama3.2"` and
`handleTabNew` fills from `defaultSessionSelection`.

**DoD**
1. All RED green; `rg -n '"llama3.2"' src/Seal/Gateway/API.hs` matches only the
   Ollama static-model list (the `parseProviderModel` fallbacks are gone); no
   new `ModelId ""` literal is introduced outside `defaultSessionSelection`
   (pre-existing `ModelId ""` sites in `TurnEngine`/`Reconstruct`/`Transcript`
   are untouched).
2. `make check` green.

---

## WU-4 — Boot-time config migration

**Files:** `src/Seal/Config/Migrate.hs`, `src/Seal/Command/Serve.hs`,
`src/Seal/Tui.hs`, `test/Seal/Config/MigrateSpec.hs`

**RED**
1. `default_provider = "openrouter"` ⇒ `"openai-compat"`.
2. `[providers.openrouter]` with `base_url` + `default_model` ⇒ copied; old
   section removed.
3. Section without `base_url` ⇒ `https://openrouter.ai/api/v1` filled in.
4. Section **without** `default_model` ⇒ the old implicit default
   written from a single shared constant (`legacyOpenRouterModel`, defined next
   to the catalog so step 3's preset row reuses it — never duplicated as a
   literal in `Migrate.hs`); preserves today's behaviour.
5. Only `default_provider` set ⇒ section synthesized with URL **and** model.
6. Existing `[providers.openai-compat]` + `[providers.openrouter]` ⇒ existing
   wins; old removed.
7. Idempotent; malformed TOML untouched; unwritable config ⇒ fail-open (no
   exception) **and** the §6 could-not-update stderr line; the **success** path
   emits the §6 migrated stderr line (asserted).
8. **Ordering:** `[untrusted_execution] mode = "remote"` + `[providers.openrouter]`,
   run `migrateSecurityConfig` **then** `providerRenameMigration` ⇒
   `security.toml` has the remote settings **and** the provider section is
   migrated.

**GREEN** `providerRenameMigration` via `updateRuntimeConfig` (serialized,
atomic); one stderr line per path; fail-open; called **after**
`migrateSecurityConfig` in both call sites.

**DoD** All RED green; `rg -n
'migrateSecurityConfig|providerRenameMigration' src/Seal/{Command/Serve,Tui}.hs`
shows the order; `make check` green.

---

## WU-5 — CLI (`add|list|test|remove|default`)

**Files:** `src/Seal/Command/Provider.hs`, `test/Seal/Command/ProviderSpec.hs`

**RED**
1. `addPlanFor`: anthropic (`NoBaseUrl`, `RequiredKey`, built-in model), ollama
   (`OptionalBaseUrl default`, `OptionalKey`, built-in model), generic
   (`RequiredBaseUrl`, `OptionalKey`, prompt), **preset** (injected spec ⇒
   `NoBaseUrl`, key policy from `ocsKeyRequired`).
2. `add openai-compat` blank base URL ⇒ re-prompts, then aborts with
   `nothing was saved`; nothing written.
3. `add openai-compat` `ftp://h` ⇒ the reason message, nothing written.
4. Valid URL + **blank** key + model `m` ⇒ `base_url` + `default_model` in
   config, no vault key, the §6 success line verbatim.
5. Valid URL + **non-blank** key ⇒ `OPENAI_COMPAT_API_KEY` written to the vault
   (and the WU-1 keyed mock/resolveProvider assertion proves it is sent).
6. Keyless add with **no vault configured** succeeds.
7. `"rejected"` at any prompt ⇒ abort, nothing written.
8. `add ollama` with blank URL + blank key still keeps the default URL and
   stores no key (**existing** test, must stay green); `add anthropic`
   regression.
9. `http://` on a non-loopback host with a key ⇒ the §6 unencrypted warning.
10. `list` with no vault lists **all** known providers with the shared status
    labels, base URL, and `(default)` marker (asserted verbatim).
11. `test openai-compat` with a configured model against
    `http://127.0.0.1:1/v1` ⇒ the verbatim transport message; with **no** model
    ⇒ the §6 no-model message and no network.
12. `remove openai-compat` keyless, no vault ⇒ succeeds; clears
    `[providers.openai-compat] base_url`; clears `default_provider`/
    `default_model` when it was the default; `ANTHROPIC_OAUTH_TOKENS` intact.
13. `remove anthropic` still deletes `ANTHROPIC_OAUTH_TOKENS`.
14. Prompt texts asserted verbatim (required base URL, defaulted base URL,
    model, required key, optional key).

**GREEN** `AddPlan`/`BaseUrlPrompt`/`KeyPrompt`; `addCmd` with blank-vs-cancel
per design §4.7 (amended), in-place re-prompt (max 3), vault-then-config write
order, http warning; vault-optional `list`/`test`/`remove`; remove/deconfigure;
corrected `progDesc`.

**DoD**
1. All RED green; the **six** existing tests whose expectations change are
   rewritten in place (auth label, "Stored API key" success copy, "filters out
   anthropic", "no providers configured", local-Ollama label, vault-less
   message) and the Ollama blank-key test stays green.
2. `rg -n '"ollama"' src/Seal/Command/Provider.hs` returns **nothing** (the
   `addPlanFor` row is constructor-based).
3. `make check` green.

---

## WU-6 — Gateway API

**Files:** `src/Seal/Gateway/API.hs`, `test/Seal/Gateway/ApiSpec.hs`

**RED**
1. `ProviderDetail` for `openai-compat`: `displayName`,
   `baseUrlRequired: true`, `keyOptional: true`, `defaultModelRequired: true`,
   `baseUrlEditable: true`, `defaultBaseUrl: null`, `baseUrl: null`; anthropic:
   `baseUrl = "https://api.anthropic.com"`, `baseUrlEditable: false`;
   **injected preset** (via the exported pure detail builder): `baseUrl =
   ocsBuiltinBaseUrl`, `baseUrlRequired: false`, `baseUrlEditable: false`,
   `defaultBaseUrl = ocsBuiltinBaseUrl`.
2. `keyOptional` for Ollama follows its URL (local ⇒ true, `ollama.com` ⇒ false).
3. `staticModelsFor` (exported) with an injected spec whose `ocsModels` is
   non-empty returns those ids; the shipped row returns `[]`; `GET
   /api/providers/openai-compat/models` ⇒ `[]`.
4. authStatus over HTTP for the shipped row: no base URL ⇒ `none`; base URL ⇒
   `keyless`; key stored ⇒ `api-key` (one fixture wired to
   `configuredProviders`, asserting the §4.6 invariant for that row).
5. Table-driven invalid POSTs (missing `base_url`, `""`, `ftp://h`, CRLF,
   missing `default_model`) ⇒ 400 `{error, field}` **and** the vault key was
   **not** written.
6. The REST 400 body carries no `/provider add` tail (design §4.2 rule 3).
7. Valid POST ⇒ 201; `PUT {api_key}` only ⇒ 200; `PUT {base_url: ""}` ⇒ 400;
   `PUT {base_url: "ftp://h"}` ⇒ 400, no vault write.
8. `DELETE /api/providers/openai-compat` with no vault ⇒ 204.
9. `DELETE /api/providers/openai-compat` leaves `ANTHROPIC_OAUTH_TOKENS` intact
   and clears `[providers.openai-compat] base_url`; `DELETE
   /api/providers/anthropic` still removes the OAuth blob.
10. `POST /api/tabs/new` with the family and no model ⇒ `smModel == ""`; with
    no provider/model at all ⇒ the configured `defaultSessionSelection`, not
    `ollama`/`llama3.2`.
11. `PUT {default_model: ""}` on a `defaultModelRequired` row ⇒ 400; POST with a
    non-string (`{"base_url": 5}`) ⇒ 400.
12. The `byName` fixture edit lands in WU-2; this unit asserts the same endpoint
    still returns one row per known provider with the new label.

**GREEN** the seven detail fields (`providerAuthStatus` imported from the
Registry; a pure `providerDetailValue` builder so the preset columns are
testable); `staticModelsFor` (exported); strict decode + effective-value
validation + validate-before-write; `DELETE` parity with the CLI (vault-optional
204, `ANTHROPIC_OAUTH_TOKENS` only for Anthropic, `base_url` cleared for family
rows); `parseProviderModel` no longer substitutes `llama3.2` and
`handleTabNew` fills an absent provider/model from `defaultSessionSelection`.

**DoD**
1. All RED green; the whole `ApiSpec` corpus green (only the `byName` fixture
   and the one wired fixture change).
2. `rg -n '"anthropic"|"ollama"|"openai-compat"' src/Seal/Gateway/API.hs` shows
   no provider-id comparison (constructor matches only).
3. `make check` green.

**Checkpoint (human):** backend complete — `make check` + manual smoke
(`/provider add openai-compat` against a local OpenAI-compatible server,
`/provider list`, `/provider test`, one real completion).

---

## WU-7 — Frontend

**Files:** `frontend/src/types.ts`,
`frontend/src/components/{ProvidersView,NewSessionComposer,NewTabComposer,AgentsView,ActiveTabs}.tsx`,
`frontend/src/hooks/useApi.ts` (`ProviderMutationResult` must carry the server's
`field` so the editor can render it inline),
`frontend/src/components/__tests__/{ProvidersView,NewTabComposer,NewSessionComposer,Sidebar,AgentsView}.test.tsx`,
`Makefile`

**Step 0 (own commit):** add `frontend-test` (`cd frontend && npx vitest run`,
depends on `frontend-install`) plus its `.PHONY` entry, and confirm green
**before** any RED.

**RED** (`make frontend-test`)
1. Save disabled with an empty required base URL **and** re-enabled once typed;
   `baseUrlRequired: false` ⇒ Save enabled with an empty URL.
2. `defaultModelRequired: true` ⇒ Save disabled with an empty model; enabled
   once typed.
3. Read-only base URL when `!baseUrlEditable`; Ollama placeholder
   `http://localhost:11434` in the **create** flow; family placeholder
   `https://host/v1`.
4. `keyOptional` drives the API-key hint; `defaultModelRequired` drives the
   model hint.
5. Editor title from `displayName`, map fallback.
6. `NewTabComposer` **and** `NewSessionComposer` render `OpenAI-compatible`; the
   five `openrouter` literals in `NewTabComposer.test.tsx` are replaced.
7. `Sidebar`/`ActiveTabs` render the `openai-compat` badge; a legacy
   `openrouter` tab keeps its icon.
8. `AgentsView` provider option renders `OpenAI-compatible`.
9. Server `400 {field}` renders inline next to the field (the mutation result
   type carries `field`).

**GREEN** `ProviderDetail` + the seven fields (required); update **all three**
`makeProvider` factories (`ProvidersView` = `ProviderDetail`; `NewTabComposer`
and `NewSessionComposer` = `ProviderInfo`, unchanged but type-checked); one
`openai-compat` entry in the four label maps **and** the `ActiveTabs` badge map;
flag-driven `ProvidersView` (create mode resolves flags from the
`/api/providers/all` row matching `form.name`); `Makefile` target.
**No** `ProviderInfo`/`useNewTabSpec` changes (deferred, §14).

**DoD**
1. `make frontend-test` green; `make check` green.
2. `rg -n "isOllama|isKeyless" frontend/src` empty.
3. `rg -n "openrouter" frontend/src` shows only the legacy badge/label entry and
   its test.

---

## WU-8 — Docs, cleanup, release notes

**Files:** `CHANGELOG.md`, `docs/plans/openrouter-provider-{design,plan}.md`,
`cabal.project`, `TODO.md`,
`docs/superpowers/plans/2026-06-28-seal-harness-roadmap.md`,
`docs/plans/active-plan.md`, `docs/context/execution-state.md`

1. CHANGELOG: breaking rename; automatic config migration (incl. the implicit
   model, and that it re-encodes `config.toml` so comments/unknown keys are
   lost); the one manual step (re-enter the key); `OPENROUTER_API_KEY` left in
   place (revoke at the vendor if step 3 will not ship); the keyless decision;
   `/provider remove` no longer deletes the Anthropic OAuth blob; upstream 3xx
   responses now refused with an actionable message; error bodies truncated to
   2 000 chars; the dropped attribution headers.
2. Mark the two `docs/plans/openrouter-*` files superseded; note the design's
   §14 deferrals there.
3. Refresh the `cabal.project` OpenRouter comment.
4. Update the `openrouter` mentions in `TODO.md` and the roadmap.
5. Record the private security disclosure as delivered (design §14).
6. Write `docs/plans/active-plan.md` + `docs/context/execution-state.md`.

**DoD (design §11)**
1. No provider-id comparison remains. Two checks, both run from the repo root:
   `rg -n '== *"openai-compat"' src/` and
   `rg -n '== *"(ollama|anthropic|openrouter)"' src/`. Each returns only the
   Anthropic OAuth capability checks (constructor-based after WU-5) and the
   migration/legacy-hint literals.
2. `rg -n 'base_url|dfcBaseUrl' src/Seal/ISA/` returns **no matches** (exit 1).
   (`dfcBaseUrl` is the parsed-but-unused delegation field; no opcode may wire
   it or `providers.*.base_url`.)
3. `git diff --stat main -- src/` for a hypothetical preset would be one file —
   asserted in prose only (WU-2's injected-spec dry run is the executable proof).
4. `rg -i openrouter README.md TODO.md cabal.project docs/superpowers/plans/2026-06-28-seal-harness-roadmap.md`
   shows only intentional historical/superseded references.
5. `make check` + `make frontend-test` green.

---

## Dependencies

```
WU-1 ──► WU-2 ──► WU-2b ──┬──► WU-3 ──► WU-5 ──► WU-6 ──► WU-7 ──► WU-8
                          └──► WU-4
```

- WU-2b's legacy copy needs WU-2's `providerDisplayName`; WU-3's `Maybe` model
  comes after the catalog so its call sites are stable.
- WU-4 needs only WU-2's label; it may be developed in parallel but merges after
  WU-2b.
- WU-5 needs WU-2 (status/catalog), WU-2b (legacy messages), WU-3 (`Maybe`).
- WU-6 needs WU-3 (`Maybe` call sites, `parseProviderModel`) and WU-2 (the
  shared `providerAuthStatus` it imports).
- WU-7 needs WU-6 (the API fields it consumes). WU-8 last (it needs WU-7's
  `frontend-test`).

## Rollback

Revert in reverse order (WU-8 → WU-1). WU-7 introduces the `frontend-test`
target that WU-8 needs; WU-3…WU-6 consume the new constructors and the `Maybe`
model, so a partial revert must start from the top. The migration is
forward-only: after reverting WU-4's code, a migrated `config.toml` leaves an
inert `[providers.openai-compat]` section and a `default_provider` the old
binary rejects — recorded in the PR body.

## Risks

| Risk | Mitigation |
|---|---|
| The rename commit silently changes behaviour | WU-1 step 1 is identifier-only with the ported spec unchanged; behaviour lands in step 2 |
| `Maybe` model breaks a command | WU-3 lists every call site and its documented fallback |
| Existing `ApiSpec` corpus breaks | Only the `byName` fixture and one `adProviders` fixture change (WU-6 RED 10/4) |
| Migration ordering regression | WU-4 RED 8 asserts the two migrations in sequence |
| WU-2 is the contract everything else consumes | A human checkpoint after WU-2b |
| Frontend tests ungated by CI | `frontend-test` from WU-7 step 0; wiring into CI is a follow-up |
| Scope creep | Design §14 fixes the boundary; anything outside WU-1…WU-8 stays out |
