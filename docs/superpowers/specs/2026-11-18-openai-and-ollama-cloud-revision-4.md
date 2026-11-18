# Design revision 4 — round-1 close-out

All five verdicts in: **CTO, Product, Designer, Architect = NEEDS_REVISION;
Security = APPROVED.** Round 1 therefore fails the gate (needs 5/5). Two of the
Architect's items were already fixed in revisions 2-3; the rest are new.

Verified against code by the orchestrator.

## Status of the Architect's two blockers — both already fixed

- **Blocker A1** (`ProviderStep.tsx:147` POSTs `type: 'openai'`): fixed in
  revision 2, extended in revision 3 (`§4` frontend row + item 38 + item 35d).
  Independently reported by the CTO and the Designer; all three agree.
- **Blocker A2** (`API.hs:715` second hardcoded `"type"` literal): fixed in
  revision 2 (`§4` names `:715` explicitly) — verified present in the current
  document.

The Architect's Q1-Q4 answers are all favourable and confirm revisions 2-3:
delegation to `resolveOpenAICompatible` is sound; key-only `configuredProviders`
is correct for the two new types; `vaultKeyName` is genuinely injective and
compiler-guarded; no ordinal is persisted.

## RA-1 — §4's `authLabel` claim was FALSE (correct the doc)

§4 says `authLabel` "falls into the `otherwise` branch correctly". Verified
false: `Provider.hs:255-266`'s `otherwise` branch probes `anthropicOAuthKey`, so
it reports `"auth: oauth"` for **any** non-Ollama provider whenever Anthropic
OAuth tokens exist:

```
(_, Right _)          -> "auth: api-key"
(Right _, _)          -> "auth: oauth"      -- <- fires for openai/openrouter
```

So an operator with Anthropic OAuth sees `openai — auth: oauth` in
`/provider list`. This is **pre-existing** (it already mislabels OpenRouter);
two more rows make it more visible.

Decision: **do not fix here** (separate logical change), but **delete the false
claim** from §4 and replace it with an accurate out-of-scope note. Shipping a
design that asserts a known-broken path is "correct" is worse than shipping one
that names it.

## RA-2 — The fail-closed error's fixed nouns mislead for the new types

`Registry.hs:269-270` hardcodes:

> the OpenAI-compatible provider "ollama-cloud" needs a base URL — set
> [providers.ollama-cloud] base_url (**the setup wizard asks for it**)

Both the noun and the parenthetical are false for the new types under D7 (the
wizard asks for neither). It fires only if an operator explicitly sets
`base_url = ""`.

Decision: parameterise the helper with a display name and drop the
"the setup wizard asks for it" clause when the type has a built-in endpoint.
Minimal form: `resolveOpenAICompatible` takes the provider's display label and a
`Bool` for "has a built-in endpoint"; the parenthetical appears only when false.
This also fixes the same wording for custom instances (where the wizard *does*
ask), so no caller regresses.

## RA-3 — §3.1 misses the inverse vault-key migration (add it)

The Architect spotted the mirror image of case 3, which the doc omits: an
operator whose **old generic** provider is configured (`OPENAI_API_KEY` +
`base_url`) keeps working (case 1) — but the **`openai-compatible` row** now
reads `OPENAI_COMPATIBLE_API_KEY`, finds nothing, and silently shows as
unconfigured. No error, no explanation.

Fix: one CHANGELOG line telling that operator to re-enter the key under the new
type, or to move their section to a named instance. No code change — this is a
documentation gap, and it is cheap to close.

## RA-4 — §7 must warn against wildcard clauses (the one way `-Werror` fails)

`vaultKeyName` and the other total functions are protected by
`-Wincomplete-patterns` only while they have **no** `_ ->` fallback. Adding one
silently opts a future constructor out of the compiler's help. §7 states this
explicitly so a later contributor does not "simplify" a total function into a
partial one.

## RA-5 — Decouple the display order from declaration order (optional, declined)

The Architect suggests an explicit `knownProviders` list rather than
`[minBound .. maxBound]`. **Declined**: `[minBound .. maxBound]` is what makes
the injectivity/reserved-name properties auto-cover a *future* constructor
(§5 items 2-4, 13). An explicit list would break that property and reintroduce
the drift D2 is fixing. Recorded as a deliberate trade-off.

## RA-6 — `handleProviderDelete` wipes Anthropic OAuth (note, out of scope)

`API.hs:3463-3470` deletes `anthropicOAuthKey` for **every** provider delete, so
deleting `openai` wipes Anthropic OAuth. Pre-existing and already in §6's
non-goals; the note now says the rename makes it more reachable (six deletable
built-ins) rather than implying it is new.
