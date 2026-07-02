# Phase 3, M3: Ollama provider (local + cloud)

Date: 2026-07-02
Status: APPROVED (design)
Parent: `docs/superpowers/specs/2026-06-30-phase-3-multi-provider-sessions-design.md` (M3)

## Motivation

Phase 3 M1/M2 made providers and sessions first-class: a `KnownProvider` registry
resolves credentials from the vault, `/provider` and `/model` commands manage them, and
plain chat runs against the active session's selected provider+model. Only **Anthropic**
is implemented. This milestone adds **Ollama** as a second provider so a session can run
against a local Ollama host (`localhost:11434`, no key) or Ollama Cloud (`ollama.com`,
API key), exercising the multi-provider machinery end-to-end.

The parent design sketched M3 as "a `Provider` instance with a configurable `base_url`
and an optional API key." Two facts discovered during M1/M2 implementation refine that
sketch and are the substance of this spec:

1. **Config went flat.** M1/M2 shipped flat `default_provider` / `default_model` keys,
   not the `[providers.<id>]` tables the parent design imagined. Ollama's `base_url`
   follows suit as a single flat key.
2. **The registry and `/provider` flows assume a required credential.** `vaultKeyName`,
   `resolveProvider`, and `/provider add|list|test` all treat a missing key as an error.
   Local Ollama needs no key, so those paths must treat the Ollama credential as
   **optional**.

## Goals

1. `Seal.Providers.Ollama` — a `Provider` instance (`complete` + `listModels`) for the
   Ollama HTTP API, with a configurable base URL and an optional API key.
2. **Full spine parity via tools.** The provider maps the agent loop's tool definitions,
   tool-use blocks, and tool-result blocks to and from Ollama's `/api/chat` shape, so the
   ISA opcodes (FILE_READ, SECRET_GET, …) work with tool-capable Ollama models.
3. **One provider, two deployments.** A single `ollama` `KnownProvider`; local vs cloud is
   determined by the configured `base_url` and whether an `OLLAMA_API_KEY` is present.
4. `/provider add|list|test ollama` and `/model use ollama <name>` work end-to-end,
   handling the optional-credential case gracefully.

## Non-goals

- Streaming responses (the spine is non-streaming; unchanged).
- Embeddings, model pull/management, or any Ollama endpoint beyond `/api/chat` and
  `/api/tags`.
- Per-provider config tables (`[providers.*]`) — config stays flat.
- Two separate provider entries for local vs cloud — explicitly rejected in favor of one
  `ollama` provider with a configurable base URL.
- OAuth for Ollama (cloud uses a bearer API key only).

## Guiding principle

Mirror the existing Anthropic module exactly where possible: a **pure request/response
codec** (`encodeRequest` / `decodeResponse`) separated from the **HTTP round-trip**, with
credentials supplied through the opaque `ApiKey`/CPS accessors so key bytes never surface
in a return value, a log line, or the transcript.

## Component: `Seal.Providers.Ollama`

A new module structured after `Seal.Providers.Anthropic`.

### Data type & constructors

```haskell
data Ollama = Ollama
  { olModel   :: ModelId
  , olManager :: Manager
  , olBaseUrl :: Text          -- e.g. "http://localhost:11434" or "https://ollama.com"
  , olApiKey  :: Maybe ApiKey  -- Nothing = local (no auth); Just = cloud (Bearer)
  }

mkOllama :: Manager -> Text -> Maybe ApiKey -> ModelId -> Ollama
```

### HTTP endpoints

- `complete`   → `POST {base_url}/api/chat`
- `listModels` → `GET  {base_url}/api/tags` → `.models[].name` (best-effort; surfaces the
  transport error key-safely on failure).

The base URL is joined without a trailing-slash assumption (strip one trailing `/` from
`olBaseUrl` before appending the path).

### Auth headers

- Local (`olApiKey == Nothing`): `content-type: application/json` only.
- Cloud (`olApiKey == Just k`): additionally `Authorization: Bearer <key>`, supplied via
  the CPS `withApiKey`/`withBearerToken` accessor so the key bytes live only inside the
  continuation.

### Pure request encoding (`encodeRequest :: CompletionRequest -> Value`)

Body: `{ "model": crModel, "stream": false, "messages": [...], "tools"?: [...] }`.

Message flattening (the loop sends a growing history including tool-use and tool-result
blocks):

| Source block | Ollama message |
| --- | --- |
| `crSystem = Just s` | prepend `{ "role": "system", "content": s }` |
| `CbText t` in a `User` message | `{ "role": "user", "content": t }` |
| `CbText t` in an `Assistant` message | `{ "role": "assistant", "content": t }` |
| `CbToolUse _ name input` in an `Assistant` message | `{ "role": "assistant", "content": "", "tool_calls": [{ "function": { "name": name, "arguments": input } }] }` |
| `CbToolResult _ parts _` in a `User` message | one `{ "role": "tool", "content": <joined text of parts> }` **per result block** |

Notes:

- A single `User` message from the loop may carry multiple `CbToolResult` blocks; each
  becomes its own `tool` message, in order. Ollama matches tool results to the preceding
  tool calls **by order**, so the synthesized `ToolCallId` is not emitted here.
- A `CbToolResult`'s `cbParts` (`[TrpText Text]`) are joined with newlines into the one
  `content` string. Ollama's `tool` role has no error channel, so `cbIsError` is folded
  into content (the error text is delivered as the tool output); it is not signaled
  separately.
- Consecutive `CbText` blocks in one message are joined with newlines into one `content`
  string (Ollama content is a single string, not a block array).
- `crToolChoice` has no Ollama analogue and is ignored (Ollama auto-decides); `crMaxTokens`
  maps to `options.num_predict`.

Tools: `crTools` → `[{ "type": "function", "function": { "name": tdName, "description":
tdDescription, "parameters": tdInputSchema } }]`. Omitted entirely when `crTools` is empty.

### Pure response decoding (`decodeResponse :: Value -> Either Text CompletionResponse`)

From the top-level object:

- `.message.content` (string) → a `CbText` block **iff** non-empty.
- `.message.tool_calls` (array, optional) → for each element at index `i`,
  `CbToolUse (ToolCallId ("call_" <> show i)) (OpName name) arguments`, where `arguments`
  is the already-decoded JSON object (Ollama returns an object, not a string).
- Stop reason: if any tool_calls are present → `StopToolUse`; else if
  `.done_reason == "length"` → `StopMaxTokens`; else `StopEnd`. An unrecognized
  `done_reason` → `StopOther <that text>`.
- Usage: `.prompt_eval_count` → `uInput`, `.eval_count` → `uOutput` (each defaulting to 0
  when absent).

The resulting `rsContent` is the text block (if any) followed by the tool-use blocks, so
the agent loop's `[b | b@CbToolUse{} <- rsContent]` filter sees them unchanged.

### Error handling (`Either Text`, key-safe)

Mirror Anthropic's `httpErrorText`. Specifics:

- Transport exception (connection refused — the common "Ollama not running" case) →
  `"could not reach Ollama at <base_url> — is it running? (try: ollama serve)"`. The
  base URL is not secret.
- Non-2xx → `"Ollama API returned HTTP <code>: <body>"` (body is diagnostic and
  key-safe).
- HTTP 401 (cloud) → `"Ollama rejected the credential (HTTP 401) — check the key with
  /provider add ollama"`.

## Changed module: `Seal.Config.File`

Add one optional field:

```haskell
fcOllamaBaseUrl :: Maybe Text   -- TOML key: ollama_base_url
```

Encoded/decoded with `Toml.dioptional (Toml.text "ollama_base_url")`, following the
existing flat fields. A helper (or inline default at the call sites) resolves
`Nothing` → `"http://localhost:11434"`.

## Changed module: `Seal.Providers.Registry`

- `KnownProvider` gains the `OllamaProvider` constructor. Because the totality functions
  are pattern-complete, adding the constructor forces every case to be handled.
- `providerLabel OllamaProvider = "ollama"`.
- `vaultKeyName OllamaProvider = "OLLAMA_API_KEY"`.
- `defaultModelFor OllamaProvider = ModelId "llama3.2"` — a documented placeholder so a
  new session has *a* model; the user is expected to `/model use ollama <installed-name>`.
- `resolveProvider` gains a `base_url :: Text` parameter (the resolved, non-`Maybe` URL).
  Anthropic ignores it. For Ollama:
  - Read `OLLAMA_API_KEY` from the vault. `VaultKeyNotFound` → `Nothing` (local, no error).
    Any other `VaultError` (e.g. `VaultLocked`) → surface it via `vaultErrText`.
  - Build `mkOllama mgr base_url mKey model` and wrap in `SomeProvider`.

Signature becomes:

```haskell
resolveProvider
  :: VaultHandle -> Manager -> Text {- base_url -} -> KnownProvider -> ModelId
  -> IO (Either Text SomeProvider)
```

## Changed module: `Seal.Command.Provider`

- **`addCmd`** special-cases Ollama: first `ccPrompt` for the base URL (blank keeps the
  current/default), persisted to `fcOllamaBaseUrl` via `updateFileConfig`; then
  `ccPromptSecret` for the API key (blank ⇒ skip, leaving Ollama keyless/local). Anthropic
  keeps its single hidden-key prompt. Both still seed `default_provider`/`default_model`
  when unset.
- **`listCmd` / `reportOne`** reports Ollama's status as `auth: none (local)` when no key
  is stored, instead of the generic `auth: none`. (Anthropic's OAuth/api-key reporting is
  unchanged; the special-case keys off the provider label.)
- **`testCmd`** loads `ollama_base_url` from `prConfigPath` and passes it to
  `resolveProvider`; for local Ollama it resolves and pings **without** a stored key.

## Changed module: `Seal.Channel.Cli`

`resolveSessionProvider` loads `ollama_base_url` from `prConfigPath` (default applied) and
passes it to `resolveProvider`. Anthropic sessions are unaffected (the arg is ignored for
Anthropic). No change to `mkSessionAgentEnv` or the turn loop.

## Data flow (unchanged shape; Ollama slotted in)

1. Startup builds the registry vocabulary; `ollama` is now a known provider.
2. `/provider add ollama` → prompt base URL (config) + optional key (vault).
3. `/model use ollama <name>` → session selection persisted to `session.json`.
4. Plain chat → `resolveSessionProvider` reads the base URL, resolves an `Ollama`
   `SomeProvider`, runs the turn loop identically to Anthropic (tools included).
5. `/provider test ollama` → resolve + one `pingRequest` round-trip, reported key-safely.

## Testing

**Pure (no network):**

- Request encode: system message prepend; `CbText` user/assistant; a `CbToolUse` in
  assistant history → `tool_calls`; a `User` message with two `CbToolResult` blocks →
  two ordered `tool` messages; `tools` present vs omitted; `max_tokens` → `num_predict`.
- Response decode: text-only; tool_calls → `CbToolUse` with `call_0`/`call_1` ids and
  object arguments; usage extraction with and without the count fields; stop-reason
  mapping (tool_calls ⇒ `StopToolUse`, `length` ⇒ `StopMaxTokens`, `stop` ⇒ `StopEnd`,
  other ⇒ `StopOther`).
- Base-URL join strips exactly one trailing slash.
- Config parse of `ollama_base_url` (present, absent → default).

**IO with mocks / temp dirs:**

- `resolveProvider` for Ollama against the existing mock vault: no key ⇒ `Right`
  (local); key present ⇒ `Right` (cloud); `VaultLocked` ⇒ `Left` (surfaced).
- `/provider test ollama` driven by an in-process scripted `Provider` (no network) —
  asserts the ok and error reports (reuse the M1 pattern).

**Gated (pending, needs a running service):**

- Live local round-trip against `ollama serve` (chat + `/api/tags`), marked `pending`
  like the existing live-Anthropic and YubiKey smoke tests.

## Key decisions

- **One `ollama` provider, optional key.** Local vs cloud is base_url + key presence, not
  two registry entries. Keeps the totality functions single-auth-story-free and matches
  the parent design's stated shape.
- **Tools included in M3.** Ollama `/api/chat` tool_calls carry no id, so ids are
  **synthesized** (`call_<i>`) on decode and **dropped** on encode (Ollama matches tool
  results by order). This gives full spine parity with Anthropic.
- **`base_url` is a flat config key**, consistent with the M1/M2 flat config, not a
  `[providers.ollama]` table.
- **Credential is optional throughout** — `resolveProvider`, `/provider add|list|test`
  treat a missing Ollama key as "local," never an error.
