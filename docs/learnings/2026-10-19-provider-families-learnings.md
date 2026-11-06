# Learnings: provider families (generic OpenAI API + OpenRouter)

Date: 2026-10-19
Branch: `provider/openai-compat-271` (PR #272)
Design/plan: `docs/superpowers/specs|plans/2026-10-19-provider-families-*.md`

## What shipped

A first-class `ProviderFamily` (`AnthropicFamily | OllamaFamily | OpenAIFamily`)
with `familyKey`/`familyLabel`/`openAICompatSpecFor`; the catalog is
`[genericOpenAI (id openai, base URL required), openRouter (fixed
https://openrouter.ai/api/v1, key required)]`; `resolveInstance` dispatches
through the family; the #271 `openrouter → openai-compat` migration was deleted
and `legacyProviderHint` re-pointed to `openai-compat → openai`;
`upsertProviderForType` stamps `pcType` on every section-creating write; the
gateway exposes `family`/`familyDisplayName`/`apiKeyName`/`oauthKeyName`.

## Lessons

1. **Verify claimed invariants against the code.** The design asserted
   `catalogProblems` already checked vault-key distinctness; it did not (only
   duplicate ids). Add the check *and* a test that fails without it.
2. **Check release status before designing a migration.** The "openrouter was
   released" premise was false (version 0.1.0.0, no tags, all CHANGELOG entries
   unreleased). Re-introducing `openrouter` as a real provider made the #271
   rename migration actively harmful; deleting it was the right move.
3. **Centralize section creation.** Two writers (`handleProviderUpdate`,
   `/model default`) created a type-less `[providers.openai]` section, which
   reloaded as a problem row and orphaned the key. `upsertProviderForType`
   fixes the class, not the instances. A type id excluded from `legacyTypeIds`
   makes this failure mode immediate.
4. **The UI must not guess credential names.** The client `apiKeyNameFor` map
   would have named `PROVIDER_APIKEY_OPENROUTER` while the server deleted
   `OPENROUTER_API_KEY`. Expose `apiKeyName`/`oauthKeyName` from the server.
5. **The design gate earns its cost.** Five reviewers caught both bugs above
   (plus the `providerDefaultModel` name collision, the payload-`Eq` family
   issue, and the missing problem-row/table conversions) before any code was
   written. Revision 6's scope cuts (no policy move, no default-model
   unification, no header hardening) kept the diff proportional.
6. **`insertWith` upsert semantics.** `upsertProvider` applies the update only
   to an existing section (`insertWith (\_ old -> f old)`); the helper must
   stamp `pcType` on the *result*, not rely on the create branch.
7. **Flaky test to watch:** `Seal.Agent.Runtime.Registry.agentStatus records
   Crashed when the worker throws` polls a ≤2 s async transition and fails
   intermittently under `make check` load; it passes in isolation and on rerun.

## Follow-ups (tracked in TODO.md)

- Provider base-URL repoint guard (rotate key / explicit confirmation before a
  keyed instance's `PUT {base_url}`).
- Derive `catalogProblems`' built-in id list and `legacyReservedKeys` from
  `providerTypes`.
