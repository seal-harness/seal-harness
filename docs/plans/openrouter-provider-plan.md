> **Superseded** by `docs/superpowers/specs/2026-10-19-provider-families-design.md`
> and `docs/superpowers/plans/2026-10-19-provider-families-plan.md` — the generic
> provider is now `openai` and `openrouter` is a fixed-URL provider. Kept for history.

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
and `Seal.Providers.Ollama` exactly. **Do not** use `OpenAI.V1.makeMethods`
(the servant-client convenience wrapper) — it would unwrap `ApiKey` to `Text`
and surface `servant-client` runtime exceptions.

## Pre-requisite
`servant-client` is currently in `seal-harness.cabal` `build-depends` (added
by `2c3d533` alongside `openai`). No source code imports it. `openai` itself
declares `servant-client` + `servant-client-core` in its own `build-depends`,
so it stays available transitively. **Drop it from our `build-depends`** so no
future module can import `Servant.Client` without an explicit opt-in.

## Work Units

### WU-A: Drop `servant-client` from `build-depends`
**Files:** `seal-harness.cabal` (remove `, servant-client` from the library
`build-depends` list — the one line also carrying `openai >=2.5.4`).
**Verify:** `make build` clean (whole project — lib + test suite — still
compiles; `openai` resolves `servant-client` transitively); `rg "Servant\.Client" src` returns nothing.
**Dependencies:** none (leaf).
**TDD:** N/A (dependency change). Gate: `make build` clean.

### WU-B: Implement `OpenRouter.complete` + `listModels` (openai types + own HTTP)
**Files:**
- `src/Seal/Providers/OpenRouter.hs` — rewrite the skeleton:
  - Add `orManager :: !Manager` field to `OpenRouter`; update `mkOpenRouter`
    to `Manager -> Maybe ApiKey -> Text -> ModelId -> OpenRouter` (matching
    `mkOllama`/`mkAnthropic` — Manager first).
  - Drop the skeleton `-Wno-unused-imports` / `-Wno-unused-matches` pragmas.
  - **Module export list** becomes: `OpenRouter(..)`, `mkOpenRouter`,
    `defaultOpenRouterBaseUrl`, `openRouterBaseUrl`, `encodeRequest`,
    `decodeResponse`, `mapFinishReason`, `bearerHeaders`, `sendChatCompletion`,
    `httpErrorText`. (Pure helpers + header builder + HTTP fn are exported so
    WU-C can test them directly without a network round-trip.)
  - Imports: `OpenAI.V1.Chat.Completions` (`CreateChatCompletion`,
    `ChatCompletionObject`, `Choice`, `Message`, `Content`, `FinishReason`),
    `OpenAI.V1.Tool` (`Tool(..)`, `Function(..)`, `ToolChoice`),
    `OpenAI.V1.ToolCall` (`ToolCall(..)`), `OpenAI.V1.Models` (`Model(..)`),
    `OpenAI.V1.Usage` (`Usage(..)`); `Network.HTTP.Client`; `Network.HTTP.Types`
    (`statusCode`); `Network.HTTP.Types.Header` (`RequestHeaders`);
    `Data.Aeson` (encode/decode); `Data.Text.Encoding` (decodeUtf8);
    `Seal.Security.Secrets` (`ApiKey`, `withApiKey`).
    **Forbidden imports:** `System.Process`, `System.Directory`,
    `System.Posix`, `Servant.*`.
  - Pure: `encodeRequest :: CompletionRequest -> CreateChatCompletion`
    (map `crModel`→`model` (`Model . ModelId`'s text), `crSystem`+`crMessages`→
    `messages` (system as a leading `System` message; `User`/`Assistant` roles
    mapped; `CbThinking` blocks dropped — no openai equivalent; `CbToolUse`→
    assistant `tool_calls` via `ToolCall`; `CbToolResult`→`Tool` role message
    with the matching `tool_call_id`), `crMaxTokens`→`max_completion_tokens`
    (`Just . fromIntegral`), `crTools`→`tools` (each `ToolDefinition`→
    `Tool_Function` with `Function`), `crToolChoice`→`tool_choice`
    (`ToolAuto`→`ToolChoice "auto"`, `ToolNone`→`ToolChoice "none"`).
  - Pure: `mapFinishReason :: Text -> StopReason` — `"stop"`→`StopEnd`,
    `"tool_calls"`/`"tool_use"`→`StopToolUse`, `"length"`→`StopMaxTokens`,
    `"content_filter"`→`StopOther "content_filter"`, anything else →
    `StopOther <text>`. (Read `Choice.finish_reason :: Text` raw — do NOT use
    the closed `FinishReason` enum, so unrecognized values map to `StopOther`
    instead of hard-failing.)
  - Pure: `decodeResponse :: ChatCompletionObject -> Either Text CompletionResponse`
    — **empty `choices` → `Left "OpenRouter returned no choices"`** (graceful,
    no crash); non-empty → take the first `Choice`, read `message` (`Assistant`
    text → `CbText`, `tool_calls` → `CbToolUse` with `ToolCall.id` — keep the
    id OpenRouter returns; fall back to `call_<i>` if blank), `mapFinishReason`
    on `finish_reason`, `usage` (`prompt_tokens`→`uInput`,
    `completion_tokens`→`uOutput`, both via `fromIntegral :: Natural -> Int`).
  - `bearerHeaders :: ByteString -> RequestHeaders` —
    `[("content-type","application/json"),("authorization","Bearer " <> bytes),
    ("HTTP-Referer","https://github.com/seal-harness"),("X-Title","seal-harness")]`
    (OpenRouter recommends `HTTP-Referer`/`X-Title` for app attribution; the
    key bytes live only in this header built inside `withApiKey`.)
  - HTTP: `sendChatCompletion :: Manager -> RequestHeaders ->
    CreateChatCompletion -> IO (Either Text CompletionResponse)` —
    `parseRequest ("POST " <> T.unpack baseUrl <> "/chat/completions")`, set
    body (`RequestBodyLBS . encode`) + headers, `httpLbs`; non-2xx →
    `httpErrorText status body`; 2xx → `eitherDecode` + `decodeResponse`.
    Catch `HttpException` → `Left "OpenRouter HTTP request failed (connection
    or transport error)"` (mirrors Anthropic's `sendMessages`).
  - `httpErrorText :: Int -> Text -> Text` — special-case **429** (rate limit —
    "OpenRouter rate limit (HTTP 429) — wait and retry, or switch models with
    /model use.") and **401** (auth — "OpenRouter rejected the API key
    (HTTP 401) — run /provider remove openrouter then /provider add openrouter
    to re-enter the key."); other codes → `"OpenRouter API returned HTTP " <>
    T.pack (show code) <> ": " <> body` (body carries no secret).
  - `complete prov cr = case orApiKey prov of` `Nothing -> pure (Left
    "OpenRouter needs an API key — run /vault setup then /provider add
    openrouter")`; `Just key -> withApiKey key $ \bytes -> sendChatCompletion
    (orManager prov) (bearerHeaders bytes) (encodeRequest cr)`.
  - `listModels prov = pure (Right [orDefaultModel prov])` — keep the static
    default (the gateway's live `/v1/models` proxy is a separate, larger
    work item; the static list in `API.hs` already feeds the dropdown).
- `src/Seal/Providers/Registry.hs` — update the `resolveProvider`
  OpenRouter branch: un-shadow `_mgr` → `mgr` and call
  `mkOpenRouter mgr (Just (mkApiKey kb)) baseUrl model` (signature gained a
  `Manager`). No other callsite of `mkOpenRouter` exists in `src`.
- `test/Seal/Providers/OpenRouterSpec.hs` — **update the two existing
  `mkOpenRouter` callsites** (lines ~22, ~29) to the new 4-arg signature
  (`mkOpenRouter <manager> Nothing defaultOpenRouterBaseUrl (ModelId …)`),
  building a `Manager` via `Network.HTTP.Client.TLS.newTlsManager` (cheap,
  no network). The two existing skeleton assertions still hold after WU-B
  (`complete` with `Nothing` key → `Left "needs an API key"`;
  `listModels` → `Right [default]`). The full spec *rewrite* (new
  encode/decode/empty-choices/mapFinishReason tests) is WU-C — WU-B only
  keeps the suite compiling and green.
**Verify:** `make build` clean (`-Werror`); `cabal test
--test-options='--match=OpenRouter'` (existing skeleton assertions green);
`rg "Servant\.|System\.Process|System\.Directory|System\.Posix" src/Seal/Providers/OpenRouter.hs` empty.
**Dependencies:** WU-A (cabal must build without `servant-client` first).
**TDD:** the no-key branch + `listModels` are exercised by the kept skeleton
tests; the pure functions get real tests in WU-C. Gate: `make build` +
`cabal test --test-options='--match=OpenRouter'` green.

### WU-C: TDD spec — real tests for OpenRouter
**Files:** `test/Seal/Providers/OpenRouterSpec.hs` — rewrite (replacing the
WU-003 skeleton) to add:
- `encodeRequest`: a minimal `CompletionRequest` (user text, no tools) →
  `CreateChatCompletion` whose `messages` has the expected `User` message and
  whose `model` matches; a request with `crSystem` → a leading `System`
  message; a request with a `CbToolResult` → a `Tool`-role message with the
  right `tool_call_id`; `crToolChoice` `ToolAuto`/`ToolNone` → the right
  `tool_choice`.
- `mapFinishReason`: `"stop"`→`StopEnd`, `"tool_calls"`→`StopToolUse`,
  `"length"`→`StopMaxTokens`, `"content_filter"`→`StopOther`, unknown →
  `StopOther <text>`.
- `decodeResponse`: a hand-built `ChatCompletionObject` (one `Choice`,
  `Assistant` text, `finish_reason = "stop"`, `Usage` with
  `prompt_tokens`/`completion_tokens`) → `Right` with `CbText` + `StopEnd` +
  the right `Usage`; a choice with `tool_calls` → `CbToolUse` with the id;
  **empty `choices` → `Left "OpenRouter returned no choices"`**.
- `complete`: no key (`mkOpenRouter mgr Nothing …`) → `Left` with the
  "needs an API key" message.
- `listModels`: → `Right [default]`.
- `bearerHeaders`: the `authorization` header is `Bearer <bytes>` (assert the
  key bytes are present, not redacted) and `content-type` is JSON.
- No real network. Tests stay sub-second. (A live round-trip would need a
  real key + endpoint — guard with `pendingWith` if added later.)
**Wire:** already in `test/Main.hs` + `seal-harness.cabal` (WU-002 added it).
**Verify:** `make test` — new tests pass; `make lint` — clean.
**Dependencies:** WU-B.

### WU-D: Security review + final integration
- `rg "~/.seal|System\.Process|System\.Directory|System\.Posix|Servant\."
  src/Seal/Providers/OpenRouter.hs` — empty.
- Key only on the request header inside `withApiKey` (code inspection); no
  `Show`/`ToJSON` on `ApiKey`; no key bytes in any logged/recorded path
  (`httpErrorText` body is the upstream response, not the key; `bearerHeaders`
  is built inside `withApiKey`).
- `make check` green (build + test + lint).
- Frontend already green (prior commit on this branch).
- Update `docs/context/execution-state.md` → COMPLETE.
**Dependencies:** WU-C.

## Execution Order
```
WU-A (cabal) ──→ WU-B (impl) ──→ WU-C (tests) ──→ WU-D (security + check)
```
Linear; each unit's gate is the next's entry condition. No parallelism
(single module, shared cabal file — merge hotspots).

## Backward Compatibility
- Anthropic/Ollama untouched.
- `OpenRouter` constructor gains a `Manager` field — `mkOpenRouter` signature
  changes; the only callsite is `resolveProvider` (updated in WU-B). No
  external consumers.
- `/api/providers` shape unchanged by this plan (the "show all + configured
  flag" change is already on this branch).
- `listModels` still returns `Right [default]` (no behavior change for the
  gateway's static list).

## Rollback
Revert WU-B + WU-A; the skeleton `Left "not yet fully implemented"` returns.
No persistent state outside the vault (vault key `OPENROUTER_API_KEY` is
unaffected by code revert).
