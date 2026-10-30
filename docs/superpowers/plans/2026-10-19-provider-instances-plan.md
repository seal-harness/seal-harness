# Plan: Named provider instances

Issue: #273 · Design (rev 3): `docs/superpowers/specs/2026-10-19-provider-instances-design.md`
Branch: `provider/openai-compat-271` — extends PR #272 (user decision).
Gates: `make check` per unit; `make frontend-test` for WU-5.

> **Design §11 is authoritative** (then §10, then §9) where sections conflict.

## Scope

Providers become **named instances of a type**, so one `openai-compat` endpoint
is no longer the limit. Every type gets instances (multiple Anthropic keys,
multiple Ollama servers). No config rewrite, no secret move, no session-schema
change.

## WU-0 — `Seal.Providers.Name` (additive, no behaviour change)

**Files:** new `src/Seal/Providers/Name.hs`, new `test/Seal/Providers/NameSpec.hs`,
`seal-harness.cabal` (exposed-modules + test `other-modules`), `test/Main.hs`.

Design §10.1/§10.9: `apiKeyNameFor :: Maybe Text -> ProviderName -> Text -> Text`
(legacy key, name, canonical type id). Properties 3–5 of §10.9 run in WU-1/WU-2,
not here.

**RED**
1. `mkProviderName` accepts `groq`, `work-proxy`, `a1`, `anthropic`,
   `openai-compat`; rejects `""`, `Work`, `work_proxy`, `work.proxy`, `\u00e9`,
   `-x`, `x-`, `a--b`, 33 chars, `all`, `default`.
2. `checkNameForType` (§11.3: takes the known type-id set) allows
   (`["anthropic","ollama"]`, `anthropic`, `"anthropic"`), rejects
   (`["anthropic","ollama"]`, `ollama`, `"anthropic"`), and allows a name that is
   not in the set.
3. `shoutySnake` maps `work-proxy` → `WORK_PROXY`.
4. Properties (§10.9): (a) **cross-role** `apiKeyNameFor a n t ≠ oauthKeyNameFor b m u`
   sampled over the grammar; (b) distinct names ⇒ distinct derived api and oauth
   names. Property 5 (`legacyKeyFor (OpenAICompatType s) == Just (ocsVaultKey s)`)
   runs in WU-2 where the catalog is visible.
5. Regression pair: `x` (anthropic) OAuth = `PROVIDER_OAUTH_X`;
   `x-oauth-tokens` API key = `PROVIDER_APIKEY_X_OAUTH_TOKENS` — different.

**DoD:** `make check` green; `Seal.Providers.Name` imports no `Seal.Providers.*`
and no `Seal.Config.*` module (source-grep spec). `Registry` importing `Name`
from WU-1 onward is expected.

## WU-1 — config `pcType` + migration gate + `providerInstances`

**Files:** `src/Seal/Config/File.hs`, `src/Seal/Config/Migrate.hs`,
`src/Seal/Providers/Registry.hs` (instances + `ProviderType`/`providerTypes`/
`typeId`/`toProviderType`), `test/Seal/Config/{FileSpec,MigrateSpec}.hs`,
`test/Seal/Providers/RegistrySpec.hs`.

`ProviderType` lands here (additive), because `ProviderInstance.piType` needs it.

**RED**
1. `[providers.x] type = "openai-compat"` round-trips; `""` decodes as absent;
   a `type`-less section named `anthropic`/`ollama`/`openai-compat` resolves to
   that type; a present-but-unknown type (`"anthorpic"`) yields `piProblem`
   (never a silent fallback); case-folded match (`"Anthropic"`) resolves and the
   derived key still uses the canonical id.
2. `providerInstances` on an empty config = `[anthropic, ollama, openai-compat]`
   (catalog order), all unconfigured, no problem.
3. With `[providers.anthropic]` present the row order is unchanged (catalog
   position, not "explicit last"); explicit extras follow, sorted by name.
4. `[providers."we ird"]` and `[providers.default]` appear as problem rows with
   `piNameValid = Nothing` and are addressable by their raw name.
5. `[providers.anthropic] type = "ollama"` ⇒ row has `OllamaType` **and**
   `piProblem`; resolution returns `Left problem` (§9.4).
6. An unresolvable section **survives an unrelated config write** (the codec is
   re-encoded on every save).
7. >64 sections load with none dropped (the cap is enforced at creation, WU-3/4).
8. Migration (§10.5 + §11.9): typed `[providers.openrouter]` ⇒ **section and
   pointer untouched** (no-op); type-less section ⇒ merge into the destination
   (destination wins per field, `pcType` preserved) and rewrite the pointer;
   pointer-only ⇒ rewrite the pointer AND synthesize the section from the legacy
   constants (as #271 did). Assert the message.
9. A type-less, non-legacy section (`[providers.groq]`) is a **problem row**
   (`has no type and its name is not a provider type`) — the §9.3 silent-downgrade
   case.
10. Fixtures for the no-credential rows: `[providers."we ird"] type="anthropic"`
    and `[providers.anthropic] type="ollama"` ⇒ `piNameValid`/`piProblem` per
    §11.1; the mismatch row keeps `OllamaType` + `piProblem` and
    `instanceCredentials = Nothing`.
11. **M1 upgrade fixture** (§11/§6): a config with the three legacy sections and
    legacy vault keys yields the same names, URLs, models and `authStatus`; the
    file is **not** rewritten (load → assert → assert `providerRenameMigration`
    is a no-op and the bytes are unchanged).
12. `Config/File.hs` does not import `Seal.Providers.Registry` (source-grep spec).

**DoD:** `make check` green; `MigrateSpec` has the gate cases; no `KnownProvider`
change yet.

## WU-2 — registry instances (additive, strangler)

**Files:** `src/Seal/Providers/Registry.hs`, `src/Seal/Session/Store.hs`,
`test/Seal/Providers/RegistrySpec.hs`, `test/Seal/Session/StoreSpec.hs`.

`resolveDefaultModel` keeps its old signature as a thin adapter (dies in WU-6);
add `resolveDefaultModelFor :: RuntimeConfig -> Text -> Maybe ModelId`.

**RED**
1. Two `openai-compat` instances (`local`, `groq`) resolve to their own base
   URL, default model and API key; a key read for one never touches the other.
2. Two anthropic instances with distinct OAuth blobs: refreshing one leaves the
   other byte-identical (via the `buildOAuthSession` seam — no network).
3. Type-named instances keep the legacy keys; others use `PROVIDER_APIKEY_*` /
   `PROVIDER_OAUTH_*` (properties from WU-0 run against the real catalog here).
4. `piProblem` / `piType = Nothing` ⇒ `resolveInstance` is `Left problem`, no
   vault access, `/models` empty.
5. `resolveDefaultModelFor cfg <instance>` resolves section → type → built-in; an unknown
   instance is `Nothing` (never Anthropic's model); `resolveDefaultModel` (old
   signature) delegates and is deleted in WU-6.
6. `configuredInstances` + `providerAuthStatus` invariants hold per instance,
   including the two-Ollama case (local keyless vs `ollama.com` keyed) and the
   problem row.
7. `catalogProblems` additions (type id is a valid name; not `anthropic`/`ollama`;
   distinct keys; no `PROVIDER_` prefix).
8. `instanceCredentials` returns `Nothing` for classes D/E/F; a **recording**
   vault fake asserts **zero** calls for those rows (a `Left` alone doesn't prove
   it).
9. Two-anthropic refresh asserts the recorded call **sequence** (read
   `PROVIDER_OAUTH_*` of one, write the same key), not just the other blob.
10. `mkProviderName "openrouter"` is accepted (not reserved) and appears in the
    catalog checks; `legacyKeyFor (OpenAICompatType s) == Just (ocsVaultKey s)`
    for every row.
11. Every provider-credential read/write in `Registry`, `Command.Provider`,
    `Command.Model` and `Gateway.API` goes through `ProviderCredentials`
    (asserted by the recording-vault tests). No repo-wide grep (unrelated
    `vhGet` sites exist in `Security/Vault`, `SourceControl/Clone`,
    `ISA/Ops/Secret`, `Vault/Commands`).

**DoD:** `make check` green; `KnownProvider` still exported and green.

## WU-3 — CLI

**Files:** `src/Seal/Command/{Provider,Model,New}.hs`,
`test/Seal/Command/{ProviderSpec,ModelSpec,NewSpec}.hs`.

**RED**
1. `add openai-compat local` writes `[providers.local] type = "openai-compat"`;
   `add openai-compat` (blank prompt) writes the type-named section; the name is
   prompted with the type id as default.
2. Name validation before any vault write: invalid grammar, reserved
   (`default`), another type's id, 65th instance → nothing written, vault
   byte-identical.
3. Same-type existing instance ⇒ `Configured` on first configure vs `Updated`
   on reconfigure (the §9.8 predicate); different type ⇒ error.
4. `add groq` (instance where a type is expected) ⇒ the §4 message.
5. `list` shows implicit + explicit + problem rows, with `base URL: not set`
   for the generic row and the `(default)` marker.
6. `test`/`default`/`remove`/`login` address instances; `login` on a non-anthropic
   instance is rejected; `remove` deletes only that instance's credentials and
   implements §11.1 (two axes: has-section × credentials), incl. clearing the
default pointers.
7. `/model list <instance>` / `use` / `default` by instance; `new -p <instance>`
   validates; an unknown instance prints the §4 message **without** an unknown
   `<type>` placeholder.
8. Copy table strings asserted verbatim (§10.6, minus the dropped cap row).
9. A session whose provider is unknown **and** one whose provider is a problem
   row produce the §10.6 messages; an agent def naming an unknown provider
   produces its Agents-view repair message.

**DoD:** `make check` green.

## WU-4a — gateway reads + route plumbing

**Files:** `src/Seal/Gateway/API.hs`, `src/Seal/Gateway/{SessionJson,ListsSnapshot}.hs`,
`src/Seal/Command/Serve.hs`, `test/Seal/Gateway/{ApiSpec,ServerSpec,PatIngestionSpec}.hs`,
`test/Seal/Phase7aSpec.hs`, `test/Seal/TestHelpers/ApiTestHarness.hs`.

`ApiDeps.adProviders` is **deleted** (§11.4): the handler loads the config and
computes `configuredInstances` itself.

**RED**
1. `/api/providers`: implicit + explicit instances, `isDefault`, `configured`,
   `reconfiguring`, `type`, `typeDisplayName`, `problem`, `defaultModel`;
   **fresh after a POST** (no boot-time snapshot); `displayName` = instance name.
2. `/all`: per-row flags + `problem` + `reconfiguring`; a no-credential row has
   `null` type/flags and `problem`; the implicit unconfigured rows serve as the
   create flow's type choices (§11.2).
3. `/models` for a non-type-named instance returns its type's static list;
   unknown/problem instance ⇒ `[]`.
4. Session JSON carries `providerType` (derived once per snapshot by
   `buildListsSnapshot` loading the config itself; `null` when unresolvable).

**Gate:** `make check` green.

## WU-4b — gateway mutations + session validation

**Files:** as WU-4a (API.hs + the gateway suites).

**RED**
1. POST validation table — malformed name, reserved, another type's id, unknown
   type, missing required base URL/model, type mismatch — each `400 {error,
   field}` **and no vault write**; same-type existing ⇒ `200 {reconfigured:true}`,
   new ⇒ `201`.
2. PUT: `type` immutable (`400 field:"type"`); unknown instance `404`; PUT on a
   no-credential row ⇒ `400 {field:"type"}` with the §10.3 copy; effective-value
   validation as today.
3. DELETE: §11.1 behaviours; sibling untouched; default pointers cleared only
   when it was the default.
4. `/api/providers/default` GET/PUT accept instance names (`anthropic-work`).
5. Reserved-name route: `DELETE /api/providers/default` removes the section;
   `POST` rejects the name.
6. `POST /api/tabs/new` and `POST /api/sessions` reject unknown instances **and
   problem rows**; a session can still be created on an implicit unconfigured row
   (today's behaviour).

**DoD:** `make check` green; `ApiSpec` + `ApiTestHarness`-backed suites rewritten.

## WU-5 — frontend

**Files:** `frontend/src/types.ts`, `hooks/useApi.ts`, `hooks/useNewTabSpec.ts`,
`components/{ProvidersView,NewSessionComposer,NewTabComposer,AgentsView,ActiveTabs,Sidebar}.tsx`,
tests: `components/__tests__/{ProvidersView,NewSessionComposer,NewTabComposer,AgentsView,Sidebar,ChatArea,HarnessControls}.test.tsx`,
`__tests__/{App,types}.test.ts(x)`, `lib/__tests__/tabStatus.test.ts`,
`hooks/__tests__/{useApi,useNewTabSpec,useStreams}.test.ts`.

**RED**
1. Create flow: type picker → name (prefilled with the type id, inline
   validation with `aria-invalid` + `aria-describedby`) → flag-driven fields;
   button reads **Configure** for an unconfigured instance and **Reconfigure**
   with a warning (including "change the name to add another <T> instance") when
   a section/credential exists.
2. Name/type read-only in edit mode with the rename hint.
3. List shows implicit (unconfigured) and problem rows; a problem row offers
   Delete only and renders its `problem`.
4. Delete confirm per row class, naming the actual vault key(s) and only
   claiming "clears it as default" when true.
5. Two instances of one type render distinctly in the list **and** both
   composers (`work — OpenAI-compatible`; `Anthropic` when name == type id).
6. Badge by `providerType` with `title`/`aria-label` = `<n> — <T>`, `?` when
   null; a session on a deleted instance shows the error state, not a crash.
7. All typed fixtures updated (including `useApi.test.ts` and
   `useStreams.test.ts` `SessionInfo` literals), `providerType?: string | null`
   optional; `ChatArea` is fixture-only. `PROVIDER_LABELS` holds type display
   names only (asserted in the two composers).
8. Post-delete row states: class A/B stays as *not configured*, C/D/E/F removed;
   the `(default)` marker clears. Problem rows are disabled in pickers and
   excluded from the composer's default fallback.
9. Upgrade fixture: the payload an upgraded install produces (three legacy
   sections + legacy keys) renders identical names and badges and **no** problem
   rows.
10. Server `400 field:"name"` (name taken / invalid) renders inline under the
    name field; the all-unconfigured banner and the `Unknown provider (<n>)`
    badge title render.

**DoD:** `make check` (tsc) + `make frontend-test` green.

## WU-6 — remove the legacy API + docs

**Files:** `src/Seal/Providers/Registry.hs` (delete `KnownProvider`, `knownProviders`,
`parseProviderIn`, `toProviderType`), consumers, `CHANGELOG.md`, design/plan,
`docs/plans/active-plan.md`, `docs/context/execution-state.md`.

**DoD**
1. `rg -w 'KnownProvider|knownProviders|parseProviderIn|toProviderType|vaultKeyName|knownLabelList|configuredProvidersFor|providerAuthStatus|defaultModelFor|missingBaseUrlMsgFor|resolveProvider' src/ test/`
   shows only the new instance API. **`legacyProviderHint` stays** (§11.5: it is
   the only repair path for pre-#271 sessions); `resolveDefaultModel` is excluded
   because the retained `resolveDefaultModelFor` contains it.
2. CHANGELOG: the model change, "nothing to do on upgrade", the hand-written
   `type`-less `openrouter` caveat, the security-PR delta (§10.7: repointable
   credentials 2→N, enumerable credential names, per-instance vault reads,
   orphaned credentials on no-credential rows), and the §11.7 non-goal.
3. `make check` + `make frontend-test` green.
