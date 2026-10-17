# Active Plan
<!-- approved: 2026-10-17 -->
<!-- gate-iterations: 2 -->
<!-- user-approved: true -->
<!-- status: in-progress -->

# Implementation Plan: OpenRouter Provider — Finish `complete`

> Supersedes the WU-001..WU-003 skeleton plan. WU-001 (skeleton) and WU-002
> (registry/cabal/frontend wiring) are committed (`7e50795`, `2c3d533`, `5e37dc3`);
> the frontend `/api/providers` "show all supported providers" fix is landed on
> this branch. What remains is the actual HTTP implementation.

## Goal
Make `Seal.Providers.OpenRouter.complete` actually round-trip a completion
through OpenRouter's OpenAI-compatible `/api/v1/chat/completions`, with real
TDD tests, without introducing a source-level `servant-client` dependency.

## Approach (user-approved)
**openai types + own HTTP** — import the `openai` package's *types* only
(`OpenAI.V1.Chat.Completions`, `OpenAI.V1.Tool`, `OpenAI.V1.ToolCall`,
`OpenAI.V1.Models`, `OpenAI.V1.Usage`) and do the HTTP ourselves with
`Network.HTTP.Client`, passing the API key via the CPS `withApiKey` accessor
as a `Authorization: Bearer` header — mirroring `Seal.Providers.Anthropic`
and `Seal.Providers.Ollama` exactly. **Do not** use `OpenAI.V1.makeMethods`.

## Pre-requisite
Drop `servant-client` from `seal-harness.cabal` `build-depends` (it stays
transitive via `openai`).

## Work Units

### WU-A: Drop `servant-client` from `build-depends`
**Files:** `seal-harness.cabal` (remove `, servant-client` from the library
`build-depends` list).
**Verify:** `make build` clean; `rg "Servant\.Client" src` returns nothing.
**Dependencies:** none (leaf).
**TDD:** N/A (dependency change). Gate: `make build`.

### WU-B: Implement `OpenRouter.complete` + `listModels` (openai types + own HTTP)
**Files:**
- `src/Seal/Providers/OpenRouter.hs` — rewrite the skeleton: add `orManager`;
  drop the `-Wno-unused-*` pragmas; export `encodeRequest`/`decodeResponse`/
  `mapFinishReason`/`bearerHeaders`/`sendChatCompletion`/`httpErrorText`;
  import `OpenAI.V1.*` types + `Network.HTTP.Client` + `withApiKey`
  (forbidden: `System.Process`/`Directory`/`Posix`/`Servant.*`);
  pure `encodeRequest` (crSystem→System message, CbThinking dropped,
  CbToolUse→tool_calls, CbToolResult→Tool role, crMaxTokens→
  max_completion_tokens, crTools→Tool_Function, crToolChoice→ToolChoice);
  pure `mapFinishReason` (stop→StopEnd, tool_calls→StopToolUse, length→
  StopMaxTokens, content_filter + unknown→StopOther);
  pure `decodeResponse` (**empty choices → Left**; else first choice:
  Assistant text→CbText, tool_calls→CbToolUse, mapFinishReason, usage);
  `bearerHeaders`; `sendChatCompletion` (POST baseUrl/chat/completions,
  catch HttpException → Left; non-2xx → httpErrorText);
  `httpErrorText` (429 rate-limit, 401 auth, else status+body);
  `complete` (Nothing key → Left "needs an API key"; Just key → withApiKey
  CPS → sendChatCompletion); `listModels` stays `Right [default]`.
- `src/Seal/Providers/Registry.hs` — un-shadow `_mgr`→`mgr` in the OpenRouter
  branch of `resolveProvider`; call `mkOpenRouter mgr (Just (mkApiKey kb))
  baseUrl model`.
- `test/Seal/Providers/OpenRouterSpec.hs` — update the 2 existing
  `mkOpenRouter` callsites to the new 4-arg signature (Manager via
  `newTlsManager`); the skeleton assertions still pass after WU-B. Full
  spec rewrite is WU-C.
**Verify:** `make build` clean; `cabal test --test-options='--match=OpenRouter'`
(skeleton assertions green); forbidden-import grep empty.
**Dependencies:** WU-A. Gate: `make build` + `cabal test --match=OpenRouter`.

### WU-C: TDD spec — real tests for OpenRouter
**Files:** `test/Seal/Providers/OpenRouterSpec.hs` — rewrite: `encodeRequest`
(minimal, crSystem, CbToolResult, crToolChoice); `mapFinishReason`;
`decodeResponse` (text+stop, tool_calls, **empty choices → Left**);
`complete` (no-key → Left); `listModels`; `bearerHeaders` (Bearer + json).
No network; sub-second.
**Verify:** `make test` green; `make lint` clean.
**Dependencies:** WU-B.

### WU-D: Security review + final integration
- `rg "~/.seal|System\.Process|System\.Directory|System\.Posix|Servant\."
  src/Seal/Providers/OpenRouter.hs` empty (incl. docstring).
- Key only in `withApiKey` (code inspection); no `Show`/`ToJSON` on `ApiKey`;
  no key bytes in logged/recorded paths.
- `make check` green. Frontend already green. Update
  `docs/context/execution-state.md` → COMPLETE.
**Dependencies:** WU-C.

## Execution Order
```
WU-A (cabal) ──→ WU-B (impl) ──→ WU-C (tests) ──→ WU-D (security + check)
```
Linear; each unit's gate is the next's entry condition.

## Rollback
Revert WU-B + WU-A; skeleton `Left "not yet fully implemented"` returns.
No persistent state outside the vault.