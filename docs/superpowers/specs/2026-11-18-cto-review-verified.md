# CTO review — independently verified findings

The CTO returned NEEDS_REVISION with six blockers. Every claim below was
re-checked against the code by the orchestrator; the verdict column records the
outcome, not the reviewer's assertion.

| # | CTO claim | Verified? | Evidence |
|---|---|---|---|
| B1 | `ProviderStep.tsx:147` POSTs `type: 'openai'`; §4 lists only the reserved-name array; D8 makes it a 400; no §5 item posts from the wizard | **CONFIRMED** | `ProviderStep.tsx:147`: `...(needsName ? { type: 'openai' } : {})`. `resolveCreateTarget` (`API.hs:3367`) requires `Just "openai-compatible"` post-rename ⇒ 400 `unknown provider: local-vllm`. §5 items 36-38 are render-only. |
| B2 | `modelContextWindow :: Text -> Int`, so "non-`Nothing`" is inexpressible; `"gpt-4o-"` has a trailing dash so bare `gpt-4o` ⇒ 0 | **CONFIRMED** | `ContextWindow.hs:17` signature returns `Int`. `:22` is `"gpt-4o-" isPrefixOf m` ⇒ `modelContextWindow "gpt-4o" == 0`. §5 item 32 as written is unsatisfiable/ill-typed. |
| B3a | `Registry.hs:242` passes literal `"openai"` to `resolveOpenAICompatible`, so the fail-closed error names the wrong config section | **CONFIRMED** | `Registry.hs:241-244`: `resolveOpenAICompatible mvh mgr "openai" (providerBaseUrlFor cfg OpenAICompatibleProvider) …`; helper builds `[providers.<name>]` from that literal (`:269-271`). Post-rename the section is `openai-compatible` ⇒ error tells operator to set the wrong section. `RegistrySpec:297` only asserts `"base URL" isInfixOf` ⇒ stays green. |
| B3b | `API.hs:715` emits `type: "openai"` for custom instances, absent from §4 | **CONFIRMED** | `API.hs:715`: `, "type" .= ("openai" :: Text)`. Post-rename this claims every custom instance is real OpenAI. |
| B3c | `API.hs:3246` `typeId /= "openai"` becomes a tautology | **CONFIRMED** | `API.hs:3246`: `[ r | typeId /= "openai" \|\| name == "ollama", r <- readinessFields … ]`. Custom instances will carry `typeId = "openai-compatible"`, so the guard never excludes them ⇒ custom instances would inherit Ollama readiness. |
| B3d | `ProvidersView.tsx:247` decides custom-ness from `PROVIDER_LABELS[p.name] === undefined`, gating the dropdown at 501/507 | **CONFIRMED** | `existingCustomNames` uses `PROVIDER_LABELS[p.name] === undefined`; and `PROVIDER_LABELS[...] !== undefined` filters the `<option>` lists. So the label map is secretly also a *registry membership* test. |
| B4 | §5 preamble ("each item written failing first") is false for items 12, 20, 31, 35, 38; items 36-38 are vacuous | **CONFIRMED** | Item 12 says "(unchanged)"; 20 says "(unchanged)"; 31 is already 400 today; 35/38 are labelled regression guards. Items 36-38 assert render behaviour D7 itself says already holds. |
| B4b | Items 2 and 3 are not property-shaped; only 19 is | **CONFIRMED** | 2 says "all six labels distinct"; 3 says "injective over knownProviders" but phrased as enumeration. 19 correctly names `map providerLabel knownProviders`, which auto-extends via `[minBound .. maxBound]`. |
| B5 | Existing-test update list incomplete; `openAICfg` fixture keys `[providers.openai]` so four tests go red | **CONFIRMED** | `RegistrySpec.hs:88-93` builds `[("openai", …)]`. `resolveProvider OpenAICompatibleProvider` reads `providerBaseUrlFor cfg OpenAICompatibleProvider` ⇒ `[providers.openai-compatible]` ⇒ `openAICfg` fixtures no longer apply. Tests at `:288-320` and the `configuredProviders` block at `:309-318` go red. |
| B6 | §4 omits `scripts/setup-walkthrough.sh`, `CHANGELOG.md`, `ContextWindow.hs` | **CONFIRMED** | `setup-walkthrough.sh:79-92` step 8c POSTs `{"name":"openai","api_key":"sk-local"}` expecting fail-closed — becomes real egress to api.openai.com, *the exact D3.1 case-3 risk*. §3.1 promises a CHANGELOG note; §4 omits CHANGELOG.md. |
| B2b | Suggestion: `defaultModelFor OllamaCloudProvider = gemma4:31b` also yields context window 0 | **CONFIRMED** | No `gemma` clause in `ContextWindow.hs` ⇒ returns 0. Same class as `gpt-4o`. |

## Additional items the CTO raised that need a decision

**C1 — `Registry.hs:242` literal.** Two options: (a) pass
`providerLabel OpenAICompatibleProvider` so the message names
`[providers.openai-compatible]`, or (b) keep the instance name and re-shape the
message. Recommendation: **(a)** — the whole purpose of the message is naming
the section to edit, and (a) makes it correct by construction. A §5 item must
assert the section name that appears in the error.

**C2 — `gpt-4o` and `gemma4:31b` context windows.** Recommendation: **do not**
publish a static model list that renders a 0 context window in the UI. Two
choices:
- (i) add `"gpt-4o" == m` / `"gemma"` clauses to `ContextWindow.hs` and list the
  file in §4, or
- (ii) shrink OpenAI's static list to ids the table already understands
  (`gpt-4o-mini`, `gpt-4-turbo`) and leave Ollama Cloud's list `[]` as planned.

Recommendation: **(ii)** for OpenAI (smallest diff, no new context numbers to
invent), and keep Ollama Cloud `[]`. `gemma4:31b` stays as the *default model*
— the default model does not have to appear in the static *list*, and an unknown
context window only affects the context-window display, not correctness.

**C3 — RED vs regression-guard split.** Adopt. Label every §5 item
`RED` or `GUARD`.

**C4 — Work-unit decomposition.** Adopt the CTO's WU1/WU2/WU3. WU3 is
irreducible because `file-embed` ships client and server together: `type:
"openai"` for a custom name must start and stop being valid in one commit.

**C5 — `providerTypeForName` needs no change** (already
`fromMaybe OpenAICompatibleProvider`) and `handleProvidersAll` is already
correct; §4 over-lists them. Fix the table.

**C6 — §7 "the compiler names every site" is false.** This is the single most
important correction: the design's headline safety property does not hold for
label string comparisons. Rewrite §7's first risk row.

**C7 — `knownProviders` order is constructor declaration order** (derived
Enum/Bounded). State that in D2 so the order is expressed structurally, not by
a comment.

**C8 — CHANGELOG must also cover the `[providers.ollama] base_url =
"https://ollama.com"` migration** to `ollama-cloud`, which is §1's headline
motivation but currently gets no note.

**C9 — `inferProviderId`** (`Kind.hs:79`) maps `gpt*` → `"openai"`, which after
the rename finally means real OpenAI. It has **no callers**. Note or delete;
do not let it become a third source of truth.

**C10 — Items 17/18's "never a network call"** is unobservable through
`resolveProvider` (the helper fails closed before constructing a client, so the
Manager is simply unused). Drop the clause or inject a Manager that throws.

**C11 — AGENTS.md forbids content-dependent `=` padding**, but the design's D4
snippet pads it (and so does existing `Registry.hs`). Do not add a third
precedent; write new code unpadded.
