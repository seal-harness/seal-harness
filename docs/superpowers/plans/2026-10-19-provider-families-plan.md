# Plan: Provider families — generic OpenAI API + OpenRouter preset

Issue: #271, step 3 · Design (rev 6 + §13): `docs/superpowers/specs/2026-10-19-provider-families-design.md`
Branch: `provider/openai-compat-271` (extends PR #272)
Gates: `make check` per Haskell unit; `make check` + `make frontend-test` for WU-4.

## Scope

Add a first-class **provider family** (wire protocol, no URL) and four
**providers**: `anthropic`, `ollama`, `openai` (generic OpenAI API, base URL
required), `openrouter` (OpenAI API, base URL fixed). Delete the #271 rename
migration; re-point `legacyProviderHint` to `openai-compat → openai`. No
back-compat guarantee (nothing released).

**Out (rev 6):** `BaseUrlPolicy` move, `providerTypeDefaultModel` unification,
reserved-header deny-list extension, mismatch-copy grammar fix, UI "API family"
row, `family`/`familyDisplayName` in TS types.

## WU-1 — Model + catalog + migration/hint + upsert helper (atomic; `make check` green)

**Files:** `src/Seal/Providers/Registry.hs`, `src/Seal/Config/File.hs`
(`upsertProviderForType`), `src/Seal/Config/Migrate.hs`, `src/Seal/Command/Serve.hs`,
`src/Seal/Tui.hs`, and the tests below.

**RED**
1. `providerFamily` of `openai`/`openrouter` is `OpenAIFamily`; `familyKey` =
   `"openai"`; `familyLabel` = `"OpenAI API"`.
2. `providerTypes == [anthropic, ollama, openai, openrouter]`.
3. `openrouter` resolves to `https://openrouter.ai/api/v1` with a stored
   `base_url`; key required; default model = `openRouterDefaultModel`.
4. `openai` has no built-in URL (`Left` without one) and no default model; a
   **configured** `openai` instance with no key reports `keyless`; the bare
   implicit row reports `none`.
5. `legacyTypeIds == ["anthropic","ollama","openrouter"]`.
6. `catalogProblems openAICompatSpecs == []`, **and** an injected spec with a
   duplicate `ocsVaultKey` is rejected (so the new pairwise check has teeth).
7. `[providers.openai-compat]` and type-less `[providers.openai]` are problem
   rows with the corrected copy (`has no type — add type = "<id>" …`);
   `[providers.openai] type="openrouter"` / `[providers.openrouter]
   type="openai"` are mismatch rows with no credentials.
8. `addPlanFor (OpenAICompatType openRouter)` = `NoBaseUrl`, `RequiredKey`,
   `Just openRouterDefaultModel`; `genericOpenAI` = `RequiredBaseUrl`,
   `OptionalKey`, `Nothing`.
9. `legacyProviderHint "openai-compat"` = the rename repair;
   `legacyProviderHint "openrouter"` = `Nothing`.
10. `providerRenameMigration` is gone; `resolveSessionProvider` on a persisted
    `openai-compat` is `Left` naming the known ids (fail closed).
11. `upsertProviderForType` sets `pcType` on create and overwrites a different
    existing `type`.

**GREEN**
- `ProviderFamily = AnthropicFamily | OllamaFamily | OpenAIFamily`
  (`Eq, Show`); `providerFamily`, `familyKey`, `familyLabel`,
  `openAICompatSpecFor`.
- `openAICompatSpecs = [genericOpenAI, openRouter]`; `providerTypes` derived;
  `genericOpenAICompat` → `genericOpenAI`; `legacyOpenRouter*` →
  `openRouterBaseUrl`/`openRouterDefaultModel` (exported).
- `resolveInstance` dispatches `providerFamily` then `openAICompatSpecFor`.
- `catalogProblems` pairwise vault-key check (`T.toLower . T.strip`).
- `upsertProviderForType :: Text -> Text -> (ProviderConfig -> ProviderConfig)
  -> RuntimeConfig -> RuntimeConfig` in `Config.File`.
- Correct the type-less problem copy (`has no type — add type = "<id>" or
  delete the section`).
- Delete `providerRenameMigration`/`RenamePlan`/`renamePlan`/`applyRename`/
  `migratedMsg`/`couldNotUpdateMsg`, the `Serve`/`Tui` calls, and
  `MigrateSpec.providerRenameSpec` + its `spec` operand. Drop the now-dead
  imports (`Migrate.hs`: `<|>`, `fromMaybe`, `isJust`, `updateRuntimeConfig`,
  `Map`, `ProviderConfig (..)`, Registry import — **keep** `RuntimeConfig (..)`,
  `System.IO`, `try`, `SomeException`; `Serve/Tui`: `System.IO (hPutStrLn,
  stderr)`; `MigrateSpec`: `Data.Map.Strict`, `ProviderConfig (..)`,
  `providerBaseUrl`, `providerDefaultModel` — **keep** `RuntimeConfig (..)`;
  `spec_main` uses `rcDefaultProvider` at `:55`).
- Re-point `legacyProviderHint` to `openai-compat → openai` (5 call sites stay).

**Registry exports:** `ProviderFamily (..)`, `familyKey`, `familyLabel`,
`openAICompatSpecFor`, `genericOpenAI`, `openRouter`, `openRouterBaseUrl`,
`openRouterDefaultModel`.

**Conversion table (gate-blocking)**
- `openai-compat` generic target → `openai`; fixed-URL/preset target →
  `openrouter`.
- `ProviderSpec.hs:605/606/689` `"(OpenAI-compatible)"` → `"(OpenAI API)"`.
- Type-less-section fixtures set `pcType = Just "openai"`:
  `ModelSpec.hs:351`, `ProviderSpec.hs:503/517/531`.
- Vault-key literals `OPENAI_COMPAT_API_KEY` → `OPENAI_API_KEY`:
  `ProviderSpec.hs:426/450/462`, `RegistrySpec.hs:234`, `ApiSpec.hs:5132`.
- `RegistrySpec.hs` four-id lists `106/110/116/125/184/185/379`; parallel
  boolean/Maybe lists `107/108/111/112`; `:188` `legacyTypeIds`;
  `:158-160` legacy fixture → `openrouter`.
- `ApiSpec.hs:3635` four ids, `:3644-3650`, `:3860/3864` POST type,
  `:5085-5167`, `:5315` DELETE row, `:5318-5327`.
- `ProviderSpec.legacySpec`: hint tests use `openai-compat` + new text;
  `known:` tails four ids. `legacyMeta` splits: one `openai-compat` hint case
  and one `openrouter` case that uses `makeFakeVault [("OPENROUTER_API_KEY",
  …)]`; assert `providerBaseUrlForInstance` = the fixed URL (the opaque
  `SomeProvider` cannot be inspected).
- `NewSpec.hs:216-224` `/new -p openai-compat` rejected with the new hint;
  `/new -p openrouter` accepted (real deps fixture); `:246` `openai` stays
  empty.
- `StoreSpec.hs:103` → `openai` (no extra unknown-id test; §12.5 keeps that
  out of scope).
- `FileSpec` keeps a hyphenated *instance* name; the `type` literals at
  `:329/333/361/376` become `openai`.
- `NameSpec`/`OpenAICompatSpec` literals → `openai`.

**DoD:** `make check` green; no `openai-compat` **type id** in `src/` or
gate-blocking tests (the re-pointed hint string and WU-5 comments are exempt).

## WU-2 — CLI + Model

**Files:** `src/Seal/Command/Provider.hs`, `src/Seal/Command/Model.hs`,
`test/Seal/Command/{ProviderSpec,ModelSpec}.hs`.

**RED**
1. `typeArg` help lists all four ids.
2. `RequiredBaseUrl` prompt names `https://api.openai.com/v1` as the example.
3. `/model default openai <model>` leaves `type = "openai"` (uses
   `upsertProviderForType` from WU-1).

**DoD:** `make check` green.

## WU-3 — Gateway

**Files:** `src/Seal/Gateway/API.hs`, `test/Seal/Gateway/ApiSpec.hs`.

**RED**
1. `/api/providers/all` rows carry `family = "openai"` and
   `familyDisplayName = "OpenAI API"` for both new rows; null on problem rows.
2. `apiKeyName` = `OPENAI_API_KEY`/`OPENROUTER_API_KEY` for the built-in rows;
   null exactly when `problem` is non-null; `oauthKeyName` non-null only for a
   problem-free anthropic row.
3. `PUT {base_url, default_model}` on the implicit `openai` row persists
   `type = "openai"` (uses `upsertProviderForType`).
4. `PUT {base_url}` on `openrouter` returns 200 and leaves the section
   unchanged.
5. A repoint of a keyed `openai` instance reaches the stored key;
   `DELETE /api/providers/openai` removes `OPENAI_API_KEY` (accepted-risk pins).
6. `/api/providers` has four rows including "OpenAI API" and "OpenRouter";
   `/all` has `baseUrlRequired: false` for `openrouter`, `true` for `openai`.

**DoD:** `make check` green.

## WU-4 — Frontend

**Files:** `frontend/src/types.ts`, `components/{ProvidersView,NewSessionComposer,
NewTabComposer,AgentsView,ActiveTabs}.tsx`, the matching tests.

**RED**
1. Delete the client `apiKeyNameFor`; delete copy names the server-supplied
   `apiKeyName` and both keys when `oauthKeyName` is present; generic fallback
   when absent (never `undefined`).
2. Vendor-conventional key names get the "may be shared with other tooling"
   clause.
3. Create flow: `openrouter` shows a read-only fixed URL + required key;
   `openai` shows required URL + optional key + prompted model.
4. Label maps: `openai` → "OpenAI API" in place in the three composers, added
   in `ProvidersView`; `openrouter` added; `openai-compat` removed.
5. Badge map: `openai` → title "OpenAI API"; `openrouter` icon retained; `?`
   only when neither `providerType` nor the name matches.
6. All fixtures updated (`openai-compat` gone).

**DoD:** `make check` + `make frontend-test` green.

## WU-5 — Docs

Rewrite the CHANGELOG (remove the false `openrouter → openai-compat` and "Next:
presets" bullets; document the `openai-compat` removal, the orphaned key, and
the `openai` repoint/destruction warning). Update `TODO.md` (repoint guard,
derived keys/ids), the `Command/Provider` header, `Config/File` `pcType` doc,
`Gateway/API.hs:2249`, `Name.hs` comment, `Registry.hs` legacy comments,
`frontend/src/types.ts:45`, `docs/plans/active-plan.md`,
`docs/context/execution-state.md`, and "Superseded by" headers on the two
OpenAI-compat docs and the two `openrouter-provider-*` docs.

**DoD:** `make check` green.

## Verification

- `make check` after WU-1..WU-3/WU-5; `make frontend-test` after WU-4.
- `rg -n 'openai-compat' src/ test/ frontend/src` returns only the re-pointed
  hint, docs/comments, and historical notes.
- `rg -n 'providerRenameMigration|RenamePlan|renamePlan|applyRename' src/ test/` empty.
