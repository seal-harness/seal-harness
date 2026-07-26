# WEB_SEARCH Multi-Provider Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Transform the existing WEB_SEARCH opcode stub into a multi-provider search system supporting Parallel, SearXNG, Exa, and Firecrawl — with zero-config default behavior using Parallel's free MCP endpoint.

**Architecture:** Replace the single-endpoint `doSearch` function with a provider-dispatch model. A `SearchProvider` sum type selects between four backends, each with its own request builder and response parser. All providers normalize to a unified result shape. API keys are resolved from the vault at runtime (never stored in config). SearXNG can be auto-installed via Docker if the user selects it and no instance is detected.

**Tech Stack:** Haskell (GHC2021), `http-client` + `http-client-tls`, `aeson`, `tomland`, `text`. No new dependencies required.

---

## Current State

The WEB_SEARCH opcode exists at `src/Seal/Web/Search.hs` as a thin stub:
- POSTs `{"query": "..."}` to a single configurable endpoint URL
- `wscAuthKey` field exists but is never injected into requests
- `wscAllowList` field exists but is never used for result filtering
- Fail-closed when no endpoint configured or no HTTP manager
- No provider abstraction — just one endpoint URL

The config system (`src/Seal/Config/File.hs`) has a `WebConfig` record with `wcSearchEndpoint :: Maybe Text` and `wcSearchAllowList :: Maybe [Text]` fields, decoded from the `[web]` TOML section.

## Key Files

| Purpose                              | Path                                                                     |
| ------------------------------------ | ------------------------------------------------------------------------ |
| WEB_SEARCH opcode                    | `src/Seal/Web/Search.hs` (132 lines)                                     |
| WEB_FETCH opcode (pattern reference) | `src/Seal/Web/Fetch.hs` (160 lines)                                      |
| Config system                        | `src/Seal/Config/File.hs` (~L182-197 for WebConfig, ~L343-353 for codec) |
| Opcode type definition               | `src/Seal/ISA/Opcode.hs` (133 lines)                                     |
| SSRF protection                      | `src/Seal/Web/UrlSafety.hs` (230 lines)                                  |
| Vault system                         | `src/Seal/Security/Vault.hs`, `src/Seal/Vault/Commands.hs`               |
| Vault key resolution                 | `src/Seal/ISA/Ops/Secret.hs` (`vaultGetByName`)                          |
| Wiring — channels loop               | `src/Seal/Channels/Loop.hs` (~L700-767)                                  |
| Wiring — gateway                     | `src/Seal/Gateway/Send.hs` (~L467-540)                                   |
| Wiring — CLI                         | `src/Seal/Channel/Cli.hs` (~L400, L473)                                  |
| Wiring — subagent children           | `src/Seal/Channels/Loop.hs` (~L898), `src/Seal/Gateway/Send.hs` (~L832)  |
| Existing test spec                   | `test/Seal/Web/SearchSpec.hs` (41 lines)                                 |
| Cabal file                           | `seal-harness.cabal`                                                     |
| AGENTS.md                            | `AGENTS.md` (project conventions)                                        |

## Critical Constraints

1. **`-Wall -Werror` is on.** All new code must be warning-clean. Pattern matches must be total or have catch-alls. No unused imports.
2. **All wiring sites must be updated in lockstep.** There are 4+ wiring sites (Loop.hs, Send.hs, Cli.hs, subagent child wirings). Missing one causes silent feature gaps.
3. **`orRecorded` must be secret-free.** The transcript records `{"query": q, "result_count": N, "provider": "..."}` — never API keys, never full response bodies.
4. **API keys are vault references, not inline secrets.** `wscAuthKey :: Maybe Text` is a key *name* in the vault, resolved via `vaultGetByName` at runtime.
5. **No new cabal dependencies.** Everything must use `http-client`, `aeson`, `text`, and existing deps.
6. **No force pushes.** Create a feature branch first (`git checkout -b feat/web-search-providers`).

---

## Provider API Reference

### Normalized Result Shape

All providers must produce results in this JSON format for `orParts` (what the model sees):

```json
{
  "results": [
    {"title": "...", "url": "...", "description": "...", "position": 1},
    ...
  ]
}
```

And `orRecorded` (transcript metadata) is always:

```json
{"query": "...", "result_count": 5, "provider": "parallel"}
```

### Provider 1: Parallel Search (Zero-Config Default)

**Two modes:**

**Mode A — MCP endpoint (zero-config, no API key):**
- Endpoint: `POST https://search.parallel.ai/mcp`
- Transport: MCP JSON-RPC over HTTP (Streamable HTTP transport)
- Auth: none (anonymous, rate-limited)
- Request body (JSON-RPC):
```json
{
  "jsonrpc": "2.0",
  "method": "tools/call",
  "params": {
    "name": "web_search",
    "arguments": {"query": "search term"}
  },
  "id": 1
}
```
- Response: JSON-RPC response. The `result` field contains `content` array with `type: "text"` entries. The text content is JSON with search results.
- Headers: `Content-Type: application/json`, `Accept: application/json, text/event-stream`
- Note: The MCP server may respond with SSE (Server-Sent Events) format. Each SSE line is `data: <json>`. Parse the last `data` line that contains a JSON-RPC response with `result`. If the response `Content-Type` is `application/json`, it's a plain JSON-RPC response — no SSE parsing needed.

**Mode B — REST API (with API key for higher limits):**
- Endpoint: `POST https://api.parallel.ai/v1/search`
- Auth: `x-api-key: <PARALLEL_API_KEY>` header
- Request body:
```json
{
  "objective": "search term",
  "search_queries": ["search term"],
  "mode": "fast",
  "max_results": 10
}
```
- Response:
```json
{
  "results": [
    {
      "url": "https://...",
      "title": "Page Title",
      "excerpts": ["excerpt text", "more excerpt"]
    }
  ]
}
```
- Field mapping: `url` → `url`, `title` → `title`, `" ".join(excerpts)` → `description`, enumerate → `position`
- `max_results` capped at 20 server-side
- Modes: `agentic` (default, deepest), `fast` (quick), `one-shot`
- Default mode for harness: `fast` (best for interactive agent loops, ~1s latency)

**Selection logic:** If `PARALLEL_API_KEY` vault key is configured, use REST API (Mode B). Otherwise, use MCP endpoint (Mode A). This gives zero-config by default with an upgrade path.

### Provider 2: SearXNG (Self-Hosted, Free)

- Endpoint: `GET {SEARXNG_URL}/search` (also supports POST with form-encoded body)
- Auth: none (self-hosted, open by default)
- Query params: `q=<query>&format=json&pageno=1`
- Headers: `Accept: application/json`
- Response:
```json
{
  "results": [
    {
      "url": "https://...",
      "title": "Result Title",
      "content": "Snippet text",
      "score": 1.5,
      "engine": "google"
    }
  ],
  "number_of_results": 12345
}
```
- Field mapping: `url` → `url`, `title` → `title`, `content` → `description`, sort by `score` descending then enumerate → `position`
- No `max_results` param — sort client-side by score desc, slice to limit
- JSON format must be enabled in instance `settings.yml` (`search.formats: [html, json]`); otherwise returns 403
- Timeout: 15 seconds
- Default SearXNG URL: `http://localhost:8888` (the auto-install port)
- Auto-install: see Task 10

### Provider 3: Exa (API Key Required)

- Endpoint: `POST https://api.exa.ai/search`
- Auth: `x-api-key: <EXA_API_KEY>` header
- Request body:
```json
{
  "query": "search term",
  "numResults": 10,
  "contents": {"highlights": true}
}
```
- Response:
```json
{
  "results": [
    {
      "url": "https://...",
      "title": "Page Title",
      "highlights": ["key excerpt from the page"]
    }
  ]
}
```
- Field mapping: `url` → `url`, `title` → `title`, `" ".join(highlights)` → `description`, enumerate → `position`
- Free tier: 1,000 searches/month
- Key at https://exa.ai

### Provider 4: Firecrawl (API Key Required)

- Endpoint: `POST https://api.firecrawl.dev/v2/search`
- Auth: `Authorization: Bearer <FIRECRAWL_API_KEY>` header
- Request body:
```json
{
  "query": "search term",
  "limit": 10
}
```
- Response (v2 shape):
```json
{
  "success": true,
  "data": {
    "web": [
      {
        "url": "https://...",
        "title": "Page Title",
        "description": "Snippet text",
        "position": 1
      }
    ]
  }
}
```
- Field mapping: `data.web[].url` → `url`, `data.web[].title` → `title`, `data.web[].description` → `description`, `data.web[].position` → `position` (already provided by API)
- Response fallback chain (v1 compatibility): try `data.web` → `data.results` → top-level `web` → top-level `results` → `data` as flat array
- `limit` is per-source-type, not total
- Free tier: 500 credits/month
- Key at https://firecrawl.dev

---

## Implementation Tasks

### Task 1: Create Feature Branch

**Objective:** Start work on a feature branch per AGENTS.md conventions.

**Files:** None (git operation only)

**Step 1:** Create and checkout the branch.

```bash
cd ~/code/seal-harness
git checkout -b feat/web-search-providers
```

**Step 2:** Verify clean working tree.

```bash
git status
```
Expected: clean working tree on `feat/web-search-providers`.

---

### Task 2: Define SearchProvider Sum Type and Extended Config

**Objective:** Add the provider abstraction type and extend `WebSearchConfig` with provider-specific fields.

**Files:**
- Modify: `src/Seal/Web/Search.hs`
- Modify: `src/Seal/Config/File.hs`

**Step 1:** Add the `SearchProvider` type to `src/Seal/Web/Search.hs`.

Add this after the existing imports, before `WebSearchConfig`:

```haskell
-- | Which search backend to use. 'ProviderParallel' is the zero-config
-- default (free MCP endpoint, no API key needed).
data SearchProvider
  = ProviderParallel    -- ^ Parallel Search (free MCP or REST with key)
  | ProviderSearXNG     -- ^ Self-hosted SearXNG instance
  | ProviderExa         -- ^ Exa search API (requires key)
  | ProviderFirecrawl   -- ^ Firecrawl search API (requires key)
  | ProviderCustom      -- ^ User-configured custom endpoint (legacy behavior)
  deriving stock (Eq, Show)
```

**Step 2:** Extend `WebSearchConfig` in `src/Seal/Web/Search.hs`.

Replace the existing `WebSearchConfig` with:

```haskell
-- | The configuration for WEB_SEARCH.
data WebSearchConfig = WebSearchConfig
  { wscManager     :: Maybe Manager     -- ^ HTTP manager (Nothing = fail-closed)
  , wscProvider    :: SearchProvider    -- ^ which backend to use
  , wscEndpoint    :: Text             -- ^ endpoint URL (empty = use provider default)
  , wscAllowList   :: [Text]           -- ^ allowed domains (empty = all allowed)
  , wscAuthKey     :: Maybe Text       -- ^ vault key reference for API key
  , wscMaxResults  :: Int              -- ^ max results to return (0 = provider default)
  , wscVault       :: Maybe VaultRuntime  -- ^ vault for resolving API keys
  , wscSearXngUrl  :: Maybe Text       -- ^ SearXNG instance URL (Nothing = localhost:8888)
  }
```

Add the import for `VaultRuntime`:

```haskell
import Seal.Vault.Commands (VaultRuntime)
```

**Step 3:** Extend `WebConfig` in `src/Seal/Config/File.hs`.

Add new fields to the `WebConfig` record (after existing fields, before `deriving`):

```haskell
  , wcSearchProvider :: Maybe Text      -- ^ "parallel" | "searxng" | "exa" | "firecrawl" | "custom"
  , wcSearchMaxResults :: Maybe Int     -- ^ max results per search (default: 10)
  , wcSearXngUrl     :: Maybe Text      -- ^ SearXNG instance URL (default: http://localhost:8888)
```

**Step 4:** Update `defaultWebConfig` in `src/Seal/Config/File.hs`.

Add the new fields with `Nothing` defaults:

```haskell
  , wcSearchProvider = Nothing   -- Nothing = auto-select (Parallel)
  , wcSearchMaxResults = Nothing
  , wcSearXngUrl = Nothing
```

**Step 5:** Update `webConfigCodec` in `src/Seal/Config/File.hs`.

Add codec lines for the new fields (after existing `Toml.dioptional` lines in `webConfigCodec`):

```haskell
  <*> Toml.dioptional (Toml.text "search_provider" .= wcSearchProvider)
  <*> Toml.dioptional (Toml.int  "search_max_results" .= wcSearchMaxResults)
  <*> Toml.dioptional (Toml.text "searxng_url" .= wcSearXngUrl)
```

**Step 6:** Verify the project compiles (it will have warnings from unused fields — that's OK temporarily).

```bash
cd ~/code/seal-harness
cabal build 2>&1 | head -30
```

Expected: May fail due to `wscAuthKey` being moved or constructor mismatch in wiring sites. Fix the wiring sites in Task 3.

**Step 7:** Commit.

```bash
git add src/Seal/Web/Search.hs src/Seal/Config/File.hs
git commit -m "feat: add SearchProvider type and extend WebSearchConfig for multi-provider"
```

---

### Task 3: Update All Wiring Sites

**Objective:** Update every site that constructs `WebSearchConfig` to use the new fields.

**Files:**
- Modify: `src/Seal/Channels/Loop.hs` (~L754-765)
- Modify: `src/Seal/Gateway/Send.hs` (~L522-533)
- Modify: `src/Seal/Channel/Cli.hs` (~L400, L473)
- Modify: `src/Seal/Channels/Loop.hs` (~L898, subagent child wiring)
- Modify: `src/Seal/Gateway/Send.hs` (~L832, subagent child wiring)

**Step 1:** Find all `WebSearchConfig` construction sites.

```bash
cd ~/code/seal-harness
grep -rn "WebSearchConfig" src/ --include="*.hs"
```

**Step 2:** Update each wiring site. The pattern is the same everywhere — replace the old `WebSearchConfig` construction with the new one. For each site:

```haskell
-- OLD:
webSearchCfg = WebSearchConfig
  { wscManager   = httpManager
  , wscEndpoint  = unwrapOpt wcSearchEndpoint webCfg ""
  , wscAllowList = unwrapOpt wcSearchAllowList webCfg []
  , wscAuthKey   = Nothing
  }

-- NEW:
webSearchCfg = WebSearchConfig
  { wscManager     = httpManager
  , wscProvider    = parseProvider (unwrapOpt wcSearchProvider webCfg "parallel")
  , wscEndpoint    = unwrapOpt wcSearchEndpoint webCfg ""
  , wscAllowList   = unwrapOpt wcSearchAllowList webCfg []
  , wscAuthKey     = Nothing  -- TODO: wire to vault key from config
  , wscMaxResults  = unwrapOpt wcSearchMaxResults webCfg 10
  , wscVault       = Nothing  -- TODO: wire to VaultRuntime from deps
  , wscSearXngUrl  = unwrapOpt wcSearXngUrl webCfg "http://localhost:8888"
  }
```

Where `parseProvider` is a helper added to `Search.hs`:

```haskell
-- | Parse a provider name from config text. Unknown values default to
-- 'ProviderParallel' (the zero-config default).
parseProvider :: Text -> SearchProvider
parseProvider t = case T.toLower t of
  "searxng"   -> ProviderSearXNG
  "exa"       -> ProviderExa
  "firecrawl" -> ProviderFirecrawl
  "custom"    -> ProviderCustom
  _           -> ProviderParallel
```

Also export `parseProvider` from `Seal.Web.Search`.

**Step 3:** For the main wiring sites (Loop.hs, Send.hs), wire `wscVault` to the available `VaultRuntime`. These sites already have access to `VaultRuntime` — look for `cdVault` / `sdVault` or the `vaultRt` parameter. Update:

```haskell
  , wscVault       = Just vaultRt  -- or cdVault / sdVault depending on the site
```

**Step 4:** Verify the project compiles.

```bash
cabal build 2>&1 | head -40
```

Expected: Compiles with no errors. May have unused-import warnings from `VaultRuntime` — fix by ensuring the import is used.

**Step 5:** Commit.

```bash
git add -A
git commit -m "feat: update all wiring sites for extended WebSearchConfig"
```

---

### Task 4: Implement Provider Dispatch and Result Types

**Objective:** Create the unified result type and the dispatch function that routes to provider-specific implementations.

**Files:**
- Modify: `src/Seal/Web/Search.hs`

**Step 1:** Add the unified search result type and JSON encoding.

Add near the top of `Search.hs` (after `SearchProvider`):

```haskell
-- | A single normalized search result.
data SearchResult = SearchResult
  { srTitle       :: Text
  , srUrl         :: Text
  , srDescription :: Text
  , srPosition    :: Int
  } deriving stock (Eq, Show)

-- | Encode search results as JSON for the model.
encodeResults :: [SearchResult] -> Text
encodeResults results = T.decodeUtf8 . BL.toStrict . A.encode $
  A.object ["results" .= map toJSON results]
  where
    toJSON (SearchResult title url desc pos) = A.object
      [ "title"       .= title
      , "url"         .= url
      , "description" .= desc
      , "position"    .= pos
      ]
```

**Step 2:** Rewrite `uoRun` to dispatch on provider.

Replace the existing `uoRun` field in `webSearchOp`:

```haskell
  , uoRun = \_uio v -> do
      let q = fromMaybe "" (queryField v)
      case wscManager cfg of
        Nothing -> pure (OpResult
          [TrpText "WEB_SEARCH: no HTTP manager configured"]
          True (recorded q 0))
        Just mgr -> liftIO (dispatchSearch mgr cfg q)
```

Where `recorded` is a helper:

```haskell
recorded :: Text -> Int -> Value
recorded q n = object
  [ "query"        .= q
  , "result_count" .= n
  , "provider" .= providerName (wscProvider cfg)
  ]

providerName :: SearchProvider -> Text
providerName ProviderParallel  = "parallel"
providerName ProviderSearXNG   = "searxng"
providerName ProviderExa       = "exa"
providerName ProviderFirecrawl = "firecrawl"
providerName ProviderCustom    = "custom"
```

**Step 3:** Add the `dispatchSearch` function.

```haskell
-- | Dispatch to the appropriate provider search function.
dispatchSearch :: Manager -> WebSearchConfig -> Text -> IO OpResult
dispatchSearch mgr cfg q = case wscProvider cfg of
  ProviderParallel  -> searchParallel mgr cfg q
  ProviderSearXNG   -> searchSearXNG mgr cfg q
  ProviderExa       -> searchExa mgr cfg q
  ProviderFirecrawl -> searchFirecrawl mgr cfg q
  ProviderCustom    -> searchCustom mgr cfg q
```

**Step 4:** Add a stub for each provider function (to be implemented in later tasks):

```haskell
searchParallel :: Manager -> WebSearchConfig -> Text -> IO OpResult
searchParallel _ _ q = pure (OpResult
  [TrpText "WEB_SEARCH: Parallel provider not yet implemented"]
  True (recorded' q "parallel"))

searchSearXNG :: Manager -> WebSearchConfig -> Text -> IO OpResult
searchSearXNG _ _ q = pure (OpResult
  [TrpText "WEB_SEARCH: SearXNG provider not yet implemented"]
  True (recorded' q "searxng"))

searchExa :: Manager -> WebSearchConfig -> Text -> IO OpResult
searchExa _ _ q = pure (OpResult
  [TrpText "WEB_SEARCH: Exa provider not yet implemented"]
  True (recorded' q "exa"))

searchFirecrawl :: Manager -> WebSearchConfig -> Text -> IO OpResult
searchFirecrawl _ _ q = pure (OpResult
  [TrpText "WEB_SEARCH: Firecrawl provider not yet implemented"]
  True (recorded' q "firecrawl"))

searchCustom :: Manager -> WebSearchConfig -> Text -> IO OpResult
searchCustom _ _ q = pure (OpResult
  [TrpText "WEB_SEARCH: Custom provider not yet implemented"]
  True (recorded' q "custom"))
```

Where `recorded'` is a standalone version of `recorded` that doesn't close over `cfg`:

```haskell
recorded' :: Text -> Text -> Value
recorded' q provider = object
  [ "query"        .= q
  , "result_count" .= (0 :: Int)
  , "provider"     .= provider
  ]
```

**Step 5:** Verify compilation and run existing tests.

```bash
cabal build && cabal test --test-show-details=direct 2>&1 | grep -E "SearchSpec|PASS|FAIL|Error"
```

Expected: Compiles. Existing SearchSpec tests pass (they test `uoAuthorize`, which is unchanged).

**Step 6:** Commit.

```bash
git add -A
git commit -m "feat: add provider dispatch and unified SearchResult type"
```

---

### Task 5: Implement Parallel Provider (Zero-Config MCP + REST)

**Objective:** Implement the Parallel search provider with two modes: MCP endpoint (no key, zero-config) and REST API (with key for higher limits).

**Files:**
- Modify: `src/Seal/Web/Search.hs`

**Step 1:** Implement `searchParallel` with key resolution and mode selection.

```haskell
searchParallel :: Manager -> WebSearchConfig -> Text -> IO OpResult
searchParallel mgr cfg q = do
  mKey <- resolveApiKey cfg
  case mKey of
    Just key -> searchParallelRest mgr cfg q key
    Nothing  -> searchParallelMcp mgr cfg q
```

Where `resolveApiKey` is a shared helper:

```haskell
-- | Resolve an API key from the vault if configured. Returns Nothing if
-- no vault key is configured or the vault is unavailable.
resolveApiKey :: WebSearchConfig -> IO (Maybe Text)
resolveApiKey cfg = case (wscVault cfg, wscAuthKey cfg) of
  (Just rt, Just keyName) -> do
    eVal <- vaultGetByName rt keyName
    pure (either (const Nothing) Just eVal)
  _ -> pure Nothing
```

Add import:

```haskell
import Seal.ISA.Ops.Secret (vaultGetByName)
```

**Step 2:** Implement `searchParallelMcp` (zero-config, no key).

This calls the MCP endpoint using JSON-RPC over HTTP. The MCP "Streamable HTTP" transport is HTTP POST with a JSON-RPC body. The response may be either `application/json` (plain JSON-RPC) or `text/event-stream` (SSE).

```haskell
searchParallelMcp :: Manager -> WebSearchConfig -> Text -> IO OpResult
searchParallelMcp mgr _cfg q = do
  eReq <- try (parseRequest "https://search.parallel.ai/mcp")
  case eReq of
    Left (_ :: HttpException) ->
      pure (mkError q "parallel" "WEB_SEARCH: failed to parse Parallel MCP URL")
    Right initReq -> do
      let body = A.encode $ A.object
            [ "jsonrpc" .= ("2.0" :: Text)
            , "method"  .= ("tools/call" :: Text)
            , "params"  .= A.object
                [ "name"      .= ("web_search" :: Text)
                , "arguments" .= A.object ["query" .= q]
                ]
            , "id"      .= (1 :: Int)
            ]
          req = initReq
            { requestBody = RequestBodyLBS body
            , requestHeaders =
                [ ("content-type", "application/json")
                , ("accept", "application/json, text/event-stream")
                ]
            }
      eResp <- try (httpLbs req mgr)
      case eResp of
        Left (_ :: HttpException) ->
          pure (mkError q "parallel" "WEB_SEARCH: Parallel MCP request failed")
        Right resp -> do
          let code = statusCode (responseStatus resp)
              respBody = responseBody resp
          if code >= 200 && code <= 299
            then parseParallelMcpResponse q respBody
            else pure (mkError q "parallel" $
              "WEB_SEARCH: Parallel MCP HTTP " <> T.pack (show code) <> ": "
              <> bodyText respBody)
```

**Step 3:** Implement `parseParallelMcpResponse`.

The MCP response is JSON-RPC. The `result.content` array has entries with `type: "text"` whose `text` field contains the actual search results as a JSON string or plain text.

```haskell
parseParallelMcpResponse :: Text -> BL.ByteString -> IO OpResult
parseParallelMcpResponse q respBody =
  case A.decode respBody :: Maybe Value of
    Nothing -> pure (mkError q "parallel" "WEB_SEARCH: Parallel MCP returned non-JSON")
    Just (A.Object o) -> do
      case parseMaybe (withObject "rpc" (.: "result")) (A.Object o) of
        Nothing -> pure (mkError q "parallel" "WEB_SEARCH: Parallel MCP missing result field")
        Just resultVal -> do
          -- result.content is an array of {type: "text", text: "..."}
          let contentText = extractMcpContentText resultVal
              results = parseParallelResults contentText
              recorded = object
                [ "query"        .= q
                , "result_count" .= length results
                , "provider"     .= ("parallel" :: Text)
                ]
          pure (OpResult
            [TrpText (encodeResults results)]
            False recorded)
    Just _ -> pure (mkError q "parallel" "WEB_SEARCH: Parallel MCP unexpected response shape")

-- | Extract text content from MCP result.content array.
extractMcpContentText :: Value -> Text
extractMcpContentText val = fromMaybe "" $
  parseMaybe (withObject "result" (.: "content")) val >>= \content ->
    case content of
      A.Array arr -> Just $ T.intercalate "\n"
        [ fromMaybe "" (parseMaybe (withObject "item" (.: "text")) item)
        | item <- toList arr
        , hasTextType item
        ]
      _ -> Nothing
  where
    hasTextType v = fromMaybe False $
      parseMaybe (withObject "item" (.: "type")) v == Just ("text" :: Text)

-- | Parse the text content from Parallel MCP into SearchResult list.
-- The text may be JSON with a results array, or plain text.
parseParallelResults :: Text -> [SearchResult]
parseParallelResults text =
  case A.decode (BL.fromStrict (TE.encodeUtf8 text)) :: Maybe Value of
    Just (A.Object o) -> do
      case parseMaybe (withObject "r" (.: "results")) (A.Object o) of
        Just (A.Array arr) -> zipWith fromParallelJson [1..] (toList arr)
        _ -> []
    Just (A.Array arr) -> zipWith fromParallelJson [1..] (toList arr)
    _ -> []
  where
    fromParallelJson :: Int -> Value -> SearchResult
    fromParallelJson pos v = fromMaybe (SearchResult "" "" "" pos) $
      parseMaybe (withObject "result" $ \obj -> do
        url   <- obj .: "url"
        title <- obj .: "title"
        excerpts <- obj .:? "excerpts" .!= []
        let desc = T.intercalate " " (map asText excerpts)
        pure (SearchResult title url desc pos)) v

    asText :: Value -> Text
    asText (A.String s) = s
    asText _ = ""
```

**Step 4:** Implement `searchParallelRest` (with API key).

```haskell
searchParallelRest :: Manager -> WebSearchConfig -> Text -> Text -> IO OpResult
searchParallelRest mgr cfg q apiKey = do
  let endpoint = if T.null (wscEndpoint cfg)
                   then "https://api.parallel.ai/v1/search"
                   else wscEndpoint cfg
      maxR = min (wscMaxResults cfg) 20
      body = A.encode $ A.object
        [ "objective"      .= q
        , "search_queries" .= [q]
        , "mode"           .= ("fast" :: Text)
        , "max_results"    .= maxR
        ]
  eReq <- try (parseRequest (T.unpack endpoint))
  case eReq of
    Left (_ :: HttpException) ->
      pure (mkError q "parallel" "WEB_SEARCH: invalid Parallel REST endpoint URL")
    Right initReq -> do
      let req = initReq
            { requestBody = RequestBodyLBS body
            , requestHeaders =
                [ ("content-type", "application/json")
                , ("x-api-key", TE.encodeUtf8 apiKey)
                ]
            }
      eResp <- try (httpLbs req mgr)
      case eResp of
        Left (_ :: HttpException) ->
          pure (mkError q "parallel" "WEB_SEARCH: Parallel REST request failed")
        Right resp -> do
          let code = statusCode (responseStatus resp)
              respBody = responseBody resp
          if code >= 200 && code <= 299
            then parseParallelRestResponse q respBody
            else pure (mkError q "parallel" $
              "WEB_SEARCH: Parallel REST HTTP " <> T.pack (show code) <> ": "
              <> bodyText respBody)

parseParallelRestResponse :: Text -> BL.ByteString -> IO OpResult
parseParallelRestResponse q respBody =
  case A.decode respBody :: Maybe Value of
    Nothing -> pure (mkError q "parallel" "WEB_SEARCH: Parallel REST returned non-JSON")
    Just (A.Object o) -> do
      case parseMaybe (withObject "r" (.: "results")) (A.Object o) of
        Just (A.Array arr) -> do
          let results = zipWith fromParallelJson [1..] (toList arr)
              recorded = object
                [ "query"        .= q
                , "result_count" .= length results
                , "provider"     .= ("parallel" :: Text)
                ]
          pure (OpResult [TrpText (encodeResults results)] False recorded)
        _ -> pure (mkError q "parallel" "WEB_SEARCH: Parallel REST missing results array")
    Just _ -> pure (mkError q "parallel" "WEB_SEARCH: Parallel REST unexpected response shape")
  where
    fromParallelJson pos v = fromMaybe (SearchResult "" "" "" pos) $
      parseMaybe (withObject "result" $ \obj -> do
        url     <- obj .: "url"
        title   <- obj .: "title"
        excerpts <- obj .:? "excerpts" .!= []
        let desc = T.intercalate " " (map asText excerpts)
        pure (SearchResult title url desc pos)) v
    asText (A.String s) = s
    asText _ = ""
```

**Step 5:** Add shared helpers (`mkError`, `bodyText`) if not already present.

```haskell
-- | Construct an error OpResult with recorded metadata.
mkError :: Text -> Text -> Text -> OpResult
mkError q provider msg = OpResult
  [TrpText msg]
  True (object
    [ "query"        .= q
    , "result_count" .= (0 :: Int)
    , "provider"     .= provider
    ])

-- | Decode a response body to Text (lenient).
bodyText :: BL.ByteString -> Text
bodyText = TE.decodeUtf8With TEE.lenientDecode . BL.toStrict
```

**Step 6:** Add required imports.

```haskell
import Data.Array (toList)  -- for converting A.Array to list
-- or use `Data.Vector (toList)` depending on aeson version
```

Actually, check what's available — aeson uses `Data.Vector`. Add:

```haskell
import Data.Vector (toList)
```

**Step 7:** Verify compilation.

```bash
cabal build 2>&1 | head -40
```

**Step 8:** Commit.

```bash
git add -A
git commit -m "feat: implement Parallel search provider (MCP zero-config + REST with key)"
```

---

### Task 6: Implement SearXNG Provider

**Objective:** Implement the SearXNG search provider with GET query params, score-based sorting, and configurable instance URL.

**Files:**
- Modify: `src/Seal/Web/Search.hs`

**Step 1:** Implement `searchSearXNG`.

```haskell
searchSearXNG :: Manager -> WebSearchConfig -> Text -> IO OpResult
searchSearXNG mgr cfg q = do
  let baseUrl = maybe "http://localhost:8888" id (wscSearXngUrl cfg)
      endpoint = baseUrl <> "/search"
      maxR = wscMaxResults cfg
      -- Build query string: q=<query>&format=json&pageno=1
      queryString = T.unpack $
        "q=" <> urlEncode q <> "&format=json&pageno=1"
      fullUrl = endpoint <> "?" <> queryString
  eReq <- try (parseRequest (T.unpack fullUrl))
  case eReq of
    Left (_ :: HttpException) ->
      pure (mkError q "searxng" "WEB_SEARCH: invalid SearXNG URL")
    Right initReq -> do
      let req = initReq
            { requestHeaders = [("accept", "application/json")]
            }
      eResp <- try (httpLbs req mgr)
      case eResp of
        Left (_ :: HttpException) ->
          pure (mkError q "searxng" "WEB_SEARCH: SearXNG request failed (is the instance running?)")
        Right resp -> do
          let code = statusCode (responseStatus resp)
              respBody = responseBody resp
          if code >= 200 && code <= 299
            then parseSearXngResponse q maxR respBody
            else pure (mkError q "searxng" $
              "WEB_SEARCH: SearXNG HTTP " <> T.pack (show code) <> ": "
              <> bodyText respBody)
```

**Step 2:** Implement `parseSearXngResponse`.

```haskell
parseSearXngResponse :: Text -> Int -> BL.ByteString -> IO OpResult
parseSearXngResponse q maxR respBody =
  case A.decode respBody :: Maybe Value of
    Nothing -> pure (mkError q "searxng" "WEB_SEARCH: SearXNG returned non-JSON (is JSON format enabled in settings.yml?)")
    Just (A.Object o) -> do
      case parseMaybe (withObject "r" (.: "results")) (A.Object o) of
        Just (A.Array arr) -> do
          let rawResults = toList arr
              -- Sort by score descending, take maxR
              scored = [(scoreOf r, r) | r <- rawResults]
              sorted = map snd $ sortBy (flip compare `on` fst) scored
              taken = take maxR sorted
              results = zipWith fromSearXngJson [1..] taken
              recorded = object
                [ "query"        .= q
                , "result_count" .= length results
                , "provider"     .= ("searxng" :: Text)
                ]
          pure (OpResult [TrpText (encodeResults results)] False recorded)
        _ -> pure (mkError q "searxng" "WEB_SEARCH: SearXNG missing results array")
    Just _ -> pure (mkError q "searxng" "WEB_SEARCH: SearXNG unexpected response shape")
  where
    scoreOf :: Value -> Double
    scoreOf v = fromMaybe 0 $
      parseMaybe (withObject "r" (.: "score")) v >>= \case
        A.Number n -> Just (realToFrac n)
        _ -> Nothing

    fromSearXngJson :: Int -> Value -> SearchResult
    fromSearXngJson pos v = fromMaybe (SearchResult "" "" "" pos) $
      parseMaybe (withObject "r" $ \obj -> do
        url     <- obj .:  "url"
        title   <- obj .:  "title"
        content <- obj .:? "content" .!= ""
        pure (SearchResult title url content pos)) v
```

**Step 3:** Add imports for `sortBy`, `on`, and URL encoding.

```haskell
import Data.List (sortBy)
import Data.Function (on)
import Network.HTTP.Types (urlEncode)  -- check if this is the right import
```

Actually, `urlEncode` from `Network.HTTP.Types` works on `ByteString`. For Text URL encoding, use:

```haskell
import Data.Text.Encoding (encodeUtf8)
import Network.HTTP.Types (urlEncode)

urlEncodeText :: Text -> Text
urlEncodeText = TE.decodeUtf8 . urlEncode False . TE.encodeUtf8
```

Use `urlEncodeText` in the query string construction instead of `urlEncode`.

**Step 4:** Verify compilation.

```bash
cabal build 2>&1 | head -40
```

**Step 5:** Commit.

```bash
git add -A
git commit -m "feat: implement SearXNG search provider with score-based sorting"
```

---

### Task 7: Implement Exa Provider

**Objective:** Implement the Exa search provider with `x-api-key` auth and highlights extraction.

**Files:**
- Modify: `src/Seal/Web/Search.hs`

**Step 1:** Implement `searchExa`.

```haskell
searchExa :: Manager -> WebSearchConfig -> Text -> IO OpResult
searchExa mgr cfg q = do
  mKey <- resolveApiKey cfg
  case mKey of
    Nothing -> pure (mkError q "exa"
      "WEB_SEARCH: Exa requires an API key. Set vault key 'exa_api_key' and configure [web] search_auth_key.")
    Just apiKey -> do
      let endpoint = if T.null (wscEndpoint cfg)
                       then "https://api.exa.ai/search"
                       else wscEndpoint cfg
          maxR = wscMaxResults cfg
          body = A.encode $ A.object
            [ "query"       .= q
            , "numResults"  .= maxR
            , "contents"    .= A.object ["highlights" .= True]
            ]
      eReq <- try (parseRequest (T.unpack endpoint))
      case eReq of
        Left (_ :: HttpException) ->
          pure (mkError q "exa" "WEB_SEARCH: invalid Exa endpoint URL")
        Right initReq -> do
          let req = initReq
                { requestBody = RequestBodyLBS body
                , requestHeaders =
                    [ ("content-type", "application/json")
                    , ("x-api-key", TE.encodeUtf8 apiKey)
                    ]
                }
          eResp <- try (httpLbs req mgr)
          case eResp of
            Left (_ :: HttpException) ->
              pure (mkError q "exa" "WEB_SEARCH: Exa request failed")
            Right resp -> do
              let code = statusCode (responseStatus resp)
                  respBody = responseBody resp
              if code >= 200 && code <= 299
                then parseExaResponse q respBody
                else pure (mkError q "exa" $
                  "WEB_SEARCH: Exa HTTP " <> T.pack (show code) <> ": "
                  <> bodyText respBody)

parseExaResponse :: Text -> BL.ByteString -> IO OpResult
parseExaResponse q respBody =
  case A.decode respBody :: Maybe Value of
    Nothing -> pure (mkError q "exa" "WEB_SEARCH: Exa returned non-JSON")
    Just (A.Object o) -> do
      case parseMaybe (withObject "r" (.: "results")) (A.Object o) of
        Just (A.Array arr) -> do
          let results = zipWith fromExaJson [1..] (toList arr)
              recorded = object
                [ "query"        .= q
                , "result_count" .= length results
                , "provider"     .= ("exa" :: Text)
                ]
          pure (OpResult [TrpText (encodeResults results)] False recorded)
        _ -> pure (mkError q "exa" "WEB_SEARCH: Exa missing results array")
    Just _ -> pure (mkError q "exa" "WEB_SEARCH: Exa unexpected response shape")
  where
    fromExaJson pos v = fromMaybe (SearchResult "" "" "" pos) $
      parseMaybe (withObject "r" $ \obj -> do
        url       <- obj .:  "url"
        title     <- obj .:  "title"
        highlights <- obj .:? "highlights" .!= []
        let desc = T.intercalate " " (map asText highlights)
        pure (SearchResult title url desc pos)) v
    asText (A.String s) = s
    asText _ = ""
```

**Step 2:** Verify compilation.

```bash
cabal build 2>&1 | head -30
```

**Step 3:** Commit.

```bash
git add -A
git commit -m "feat: implement Exa search provider with highlights extraction"
```

---

### Task 8: Implement Firecrawl Provider

**Objective:** Implement the Firecrawl search provider with Bearer auth and v2 response parsing with v1 fallback.

**Files:**
- Modify: `src/Seal/Web/Search.hs`

**Step 1:** Implement `searchFirecrawl`.

```haskell
searchFirecrawl :: Manager -> WebSearchConfig -> Text -> IO OpResult
searchFirecrawl mgr cfg q = do
  mKey <- resolveApiKey cfg
  case mKey of
    Nothing -> pure (mkError q "firecrawl"
      "WEB_SEARCH: Firecrawl requires an API key. Set vault key 'firecrawl_api_key' and configure [web] search_auth_key.")
    Just apiKey -> do
      let endpoint = if T.null (wscEndpoint cfg)
                       then "https://api.firecrawl.dev/v2/search"
                       else wscEndpoint cfg
          maxR = wscMaxResults cfg
          body = A.encode $ A.object
            [ "query" .= q
            , "limit" .= maxR
            ]
      eReq <- try (parseRequest (T.unpack endpoint))
      case eReq of
        Left (_ :: HttpException) ->
          pure (mkError q "firecrawl" "WEB_SEARCH: invalid Firecrawl endpoint URL")
        Right initReq -> do
          let req = initReq
                { requestBody = RequestBodyLBS body
                , requestHeaders =
                    [ ("content-type", "application/json")
                    , ("authorization", "Bearer " <> TE.encodeUtf8 apiKey)
                    ]
                }
          eResp <- try (httpLbs req mgr)
          case eResp of
            Left (_ :: HttpException) ->
              pure (mkError q "firecrawl" "WEB_SEARCH: Firecrawl request failed")
            Right resp -> do
              let code = statusCode (responseStatus resp)
                  respBody = responseBody resp
              if code >= 200 && code <= 299
                then parseFirecrawlResponse q respBody
                else pure (mkError q "firecrawl" $
                  "WEB_SEARCH: Firecrawl HTTP " <> T.pack (show code) <> ": "
                  <> bodyText respBody)

parseFirecrawlResponse :: Text -> BL.ByteString -> IO OpResult
parseFirecrawlResponse q respBody =
  case A.decode respBody :: Maybe Value of
    Nothing -> pure (mkError q "firecrawl" "WEB_SEARCH: Firecrawl returned non-JSON")
    Just val -> do
      let results = extractFirecrawlResults val
          recorded = object
            [ "query"        .= q
            , "result_count" .= length results
            , "provider"     .= ("firecrawl" :: Text)
            ]
      if null results
        then pure (mkError q "firecrawl" "WEB_SEARCH: Firecrawl returned no results")
        else pure (OpResult [TrpText (encodeResults results)] False recorded)

-- | Extract results from Firecrawl response, trying multiple shapes:
-- v2: data.web[] → data.results[] → web[] → results[] → data (flat list)
extractFirecrawlResults :: Value -> [SearchResult]
extractFirecrawlResults val =
  -- Try data.web (v2 shape)
  tryPath ["data", "web"] val
  -- Try data.results
  <|> tryPath ["data", "results"] val
  -- Try top-level web
  <|> tryPath ["web"] val
  -- Try top-level results
  <|> tryPath ["results"] val
  -- Try data as flat list (v1 shape)
  <|> case parseMaybe (withObject "r" (.: "data")) val of
        Just (A.Array arr) -> zipWith fromFirecrawlJson [1..] (toList arr)
        _ -> []
  where
    tryPath :: [Text] -> Value -> Maybe [SearchResult]
    tryPath keys v = do
      let go []     val' = Just val'
          go (k:ks) val' = parseMaybe (withObject "o" (.: k)) val' >>= go ks
      resultVal <- go keys v
      case resultVal of
        A.Array arr -> Just (zipWith fromFirecrawlJson [1..] (toList arr))
        _ -> Nothing

    fromFirecrawlJson :: Int -> Value -> SearchResult
    fromFirecrawlJson pos v = fromMaybe (SearchResult "" "" "" pos) $
      parseMaybe (withObject "r" $ \obj -> do
        url   <- obj .:  "url"
        title <- obj .:  "title"
        desc  <- obj .:? "description" .!= ""
        -- Use API-provided position if available, otherwise our index
        pos'  <- obj .:? "position" .!= pos
        pure (SearchResult title url desc pos')) v
```

**Step 2:** Verify compilation.

```bash
cabal build 2>&1 | head -30
```

**Step 3:** Commit.

```bash
git add -A
git commit -m "feat: implement Firecrawl search provider with v2/v1 response fallback"
```

---

### Task 9: Implement Custom Provider (Legacy Compatibility)

**Objective:** Preserve the original single-endpoint behavior for users who have a custom search endpoint.

**Files:**
- Modify: `src/Seal/Web/Search.hs`

**Step 1:** Implement `searchCustom` — this is essentially the old `doSearch` behavior.

```haskell
searchCustom :: Manager -> WebSearchConfig -> Text -> IO OpResult
searchCustom mgr cfg q
  | T.null (wscEndpoint cfg) = pure (mkError q "custom"
      "WEB_SEARCH: no search endpoint configured and no provider selected. Set [web] search_provider or search_endpoint.")
  | otherwise = do
      eReq <- try (parseRequest (T.unpack (wscEndpoint cfg)))
      case eReq of
        Left (_ :: HttpException) ->
          pure (mkError q "custom" ("WEB_SEARCH: invalid endpoint URL: " <> wscEndpoint cfg))
        Right initReq -> do
          let body = A.encode (A.object ["query" .= q])
              req = initReq
                { requestBody = RequestBodyLBS body
                , requestHeaders = [("content-type", "application/json")]
                }
          eResp <- try (httpLbs req mgr)
          case eResp of
            Left (_ :: HttpException) ->
              pure (mkError q "custom" "WEB_SEARCH: HTTP request failed (connection or transport error)")
            Right resp -> do
              let code = statusCode (responseStatus resp)
                  respBody = responseBody resp
                  resultCount = countResults respBody
                  recorded = object
                    [ "query"        .= q
                    , "result_count" .= resultCount
                    , "provider"     .= ("custom" :: Text)
                    ]
              if code >= 200 && code <= 299
                then pure (OpResult [TrpText (bodyText respBody)] False recorded)
                else pure (mkError q "custom" $
                  "WEB_SEARCH: HTTP " <> T.pack (show code) <> ": " <> bodyText respBody)
```

**Step 2:** Remove the old `doSearch` function (it's replaced by `searchCustom` and the provider dispatch).

**Step 3:** Verify compilation.

```bash
cabal build 2>&1 | head -30
```

**Step 4:** Commit.

```bash
git add -A
git commit -m "feat: implement custom provider for legacy endpoint compatibility"
```

---

### Task 10: Implement SearXNG Auto-Install

**Objective:** When the user selects SearXNG as provider and no instance is reachable, automatically start a local SearXNG Docker container with JSON format enabled.

**Files:**
- Create: `src/Seal/Web/SearXngSetup.hs`
- Modify: `src/Seal/Web/Search.hs` (call auto-setup before SearXNG search)
- Modify: `seal-harness.cabal` (add new module)

**Step 1:** Create `src/Seal/Web/SearXngSetup.hs`.

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | Auto-setup for SearXNG: checks if a local instance is reachable,
-- and if not, starts one via Docker with JSON format enabled.
module Seal.Web.SearXngSetup
  ( ensureSearXng
  , searXngDefaultUrl
  ) where

import Control.Exception (try)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client
  ( HttpException, Manager, httpLbs, parseRequest
  , responseBody, responseStatus )
import Network.HTTP.Types (statusCode)
import System.Process (readProcessWithExitCode)
import System.Exit (ExitCode (..))

searXngDefaultUrl :: Text
searXngDefaultUrl = "http://localhost:8888"

-- | Check if SearXNG is reachable at the given URL. Returns True if
-- the instance responds with HTTP 200 on the /search endpoint.
isSearXngRunning :: Manager -> Text -> IO Bool
isSearXngRunning mgr url = do
  eReq <- try (parseRequest (T.unpack (url <> "/search?q=test&format=json")))
  case eReq of
    Left (_ :: HttpException) -> pure False
    Right req -> do
      eResp <- try (httpLbs req mgr)
      case eResp of
        Left (_ :: HttpException) -> pure False
        Right resp -> pure (statusCode (responseStatus resp) == 200)

-- | Ensure a SearXNG instance is running. If the configured URL is the
-- default localhost:8888 and no instance is reachable, attempt to start
-- one via Docker. Returns True if an instance is reachable after setup.
-- Returns False if Docker is not available or the container fails to start.
ensureSearXng :: Manager -> Text -> IO Bool
ensureSearXng mgr url = do
  running <- isSearXngRunning mgr url
  if running
    then pure True
    else do
      -- Only auto-install for localhost URLs
      if not (isLocalhost url)
        then pure False
        else tryDockerInstall
  where
    isLocalhost u = "localhost" `T.isInfixOf` u || "127.0.0.1" `T.isInfixOf` u

    tryDockerInstall :: IO Bool
    tryDockerInstall = do
      -- Check if Docker is available
      (exitCode, _, _) <- readProcessWithExitCode "docker" ["--version"] ""
      case exitCode of
        ExitFailure _ -> pure False
        ExitSuccess -> do
          -- Check if container already exists but is stopped
          (ec, out, _) <- readProcessWithExitCode "docker"
            ["ps", "-a", "-q", "--filter", "name=seal-harness-searxng"] ""
          case ec of
            ExitFailure _ -> pure False
            ExitSuccess -> do
              if not (null (dropWhile (=='\n') out))
                then do
                  -- Container exists, start it
                  _ <- readProcessWithExitCode "docker"
                    ["start", "seal-harness-searxng"] ""
                  -- Wait briefly for it to come up
                  threadDelay 3000000  -- 3 seconds
                  isSearXngRunning mgr url
                else do
                  -- Pull and run a new container
                  -- First pull the image
                  _ <- readProcessWithExitCode "docker"
                    ["pull", "searxng/searxng:latest"] ""
                  -- Run the container with JSON format enabled
                  -- We need to create a settings.yml that enables JSON format
                  -- The simplest approach: run with a custom command that
                  -- patches settings.yml after first boot
                  let dockerArgs =
                        [ "run", "-d"
                        , "--name", "seal-harness-searxng"
                        , "-p", "8888:8080"
                        , "-e", "SEARXNG_BASE_URL=http://localhost:8888/"
                        , "searxng/searxng:latest"
                        ]
                  (ec2, _, err2) <- readProcessWithExitCode "docker" dockerArgs ""
                  case ec2 of
                    ExitFailure _ -> pure False
                    ExitSuccess -> do
                      -- Wait for container to start up
                      threadDelay 5000000  -- 5 seconds
                      -- Enable JSON format by patching settings.yml
                      _ <- readProcessWithExitCode "docker"
                        ["exec", "seal-harness-searxng"
                        , "sh", "-c"
                        , "sed -i 's/formats: \\[html\\]/formats: [html, json]/' /etc/searxng/settings.yml || true"
                        ] ""
                      -- Restart to apply settings
                      _ <- readProcessWithExitCode "docker"
                        ["restart", "seal-harness-searxng"] ""
                      threadDelay 3000000  -- 3 seconds
                      isSearXngRunning mgr url
```

Add import for `threadDelay`:

```haskell
import Control.Concurrent (threadDelay)
```

**Step 2:** Add the module to `seal-harness.cabal`.

In the `exposed-modules` section, add:

```
    Seal.Web.SearXngSetup
```

**Step 3:** Call `ensureSearXng` from `searchSearXNG` before making the search request.

In `Search.hs`, modify `searchSearXNG` to call the setup check on first failure:

```haskell
searchSearXNG :: Manager -> WebSearchConfig -> Text -> IO OpResult
searchSearXNG mgr cfg q = do
  let baseUrl = maybe "http://localhost:8888" id (wscSearXngUrl cfg)
  -- First attempt
  result <- searXngSearchOnce mgr cfg q baseUrl
  case result of
    Right opRes -> pure opRes
    Left errMsg -> do
      -- If first attempt failed, try auto-setup
      installed <- ensureSearXng mgr baseUrl
      if installed
        then do
          -- Retry after setup
          result2 <- searXngSearchOnce mgr cfg q baseUrl
          case result2 of
            Right opRes -> pure opRes
            Left errMsg2 -> pure (mkError q "searxng" errMsg2)
        else pure (mkError q "searxng" $
          errMsg <> " Auto-install attempted but failed. Ensure Docker is running or start SearXNG manually.")
```

Add a helper `searXngSearchOnce` that returns `Either Text OpResult`:

```haskell
searXngSearchOnce :: Manager -> WebSearchConfig -> Text -> Text -> IO (Either Text OpResult)
searXngSearchOnce mgr cfg q baseUrl = do
  let endpoint = baseUrl <> "/search"
      maxR = wscMaxResults cfg
      fullUrl = endpoint <> "?" <> "q=" <> urlEncodeText q <> "&format=json&pageno=1"
  eReq <- try (parseRequest (T.unpack fullUrl))
  case eReq of
    Left (_ :: HttpException) ->
      pure (Left "WEB_SEARCH: invalid SearXNG URL")
    Right initReq -> do
      let req = initReq { requestHeaders = [("accept", "application/json")] }
      eResp <- try (httpLbs req mgr)
      case eResp of
        Left (_ :: HttpException) ->
          pure (Left "WEB_SEARCH: SearXNG request failed (is the instance running?)")
        Right resp -> do
          let code = statusCode (responseStatus resp)
              respBody = responseBody resp
          if code >= 200 && code <= 299
            then Right <$> parseSearXngResponse q maxR respBody
            else pure (Left $ "WEB_SEARCH: SearXNG HTTP " <> T.pack (show code) <> ": " <> bodyText respBody)
```

Add import:

```haskell
import Seal.Web.SearXngSetup (ensureSearXng)
```

**Step 4:** Verify compilation.

```bash
cabal build 2>&1 | head -30
```

**Step 5:** Commit.

```bash
git add -A
git commit -m "feat: add SearXNG auto-install via Docker with JSON format enabled"
```

---

### Task 11: Wire Vault Key from Config

**Objective:** Connect the `wscAuthKey` field to the vault key name from config, and thread `VaultRuntime` through all wiring sites.

**Files:**
- Modify: `src/Seal/Config/File.hs` (add `wcSearchAuthKey :: Maybe Text` field)
- Modify: `src/Seal/Channels/Loop.hs` (wire vault + auth key)
- Modify: `src/Seal/Gateway/Send.hs` (wire vault + auth key)
- Modify: `src/Seal/Channel/Cli.hs` (wire vault + auth key)
- Modify: subagent child wirings

**Step 1:** Add `wcSearchAuthKey` to `WebConfig` in `Config/File.hs`.

```haskell
  , wcSearchAuthKey  :: Maybe Text     -- ^ vault key name for the search API key
```

Add to `defaultWebConfig`:

```haskell
  , wcSearchAuthKey  = Nothing
```

Add to `webConfigCodec`:

```haskell
  <*> Toml.dioptional (Toml.text "search_auth_key" .= wcSearchAuthKey)
```

**Step 2:** At each wiring site, wire the vault and auth key.

For sites that have access to `VaultRuntime` (Loop.hs, Send.hs):

```haskell
  , wscAuthKey     = unwrapOpt wcSearchAuthKey webCfg Nothing
  , wscVault       = Just vaultRt  -- use the variable name appropriate to each site
```

For sites without direct vault access (CLI, some subagent wirings), pass `Nothing` and document that API-key providers won't work without the vault:

```haskell
  , wscAuthKey     = unwrapOpt wcSearchAuthKey webCfg Nothing
  , wscVault       = Nothing
```

**Step 3:** Verify compilation.

```bash
cabal build 2>&1 | head -30
```

**Step 4:** Commit.

```bash
git add -A
git commit -m "feat: wire vault key resolution for search API keys through config"
```

---

### Task 12: Update the Opcode Description and Schema

**Objective:** Update the opcode description to reflect multi-provider support and add optional fields to the input schema.

**Files:**
- Modify: `src/Seal/Web/Search.hs`

**Step 1:** Update the opcode description.

```haskell
  , uoDesc = "Search the web using the configured provider (parallel, searxng, exa, firecrawl, or custom). Returns ranked results with title, URL, and description."
```

**Step 2:** Update `webSearchSchema` to include an optional `limit` field.

```haskell
webSearchSchema :: Value
webSearchSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ "query" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("The search query." :: Text)
            ]
        , "limit" .= object
            [ "type" .= ("integer" :: Text)
            , "description" .= ("Maximum number of results to return (default: 10)." :: Text)
            ]
        ]
    , "required" .= (["query"] :: [Text])
    ]
```

**Step 3:** Update `uoAuthorize` to validate the optional `limit` field.

```haskell
  , uoAuthorize = \v ->
      case queryField v of
        Nothing -> Left "WEB_SEARCH requires {query:string}"
        Just q
          | T.null q -> Left "WEB_SEARCH: query is empty"
          | otherwise -> case limitField v of
              Just n | n < 1 -> Left "WEB_SEARCH: limit must be >= 1"
              _ -> Right ()
```

Add `limitField`:

```haskell
limitField :: Value -> Maybe Int
limitField = parseMaybe (withObject "in" (.: "limit"))
```

**Step 4:** Update `uoRun` to use the per-call limit if provided (overrides config default).

In the `uoRun` body, add limit extraction:

```haskell
  , uoRun = \_uio v -> do
      let q = fromMaybe "" (queryField v)
          userLimit = limitField v
          cfg' = cfg { wscMaxResults = maybe (wscMaxResults cfg) id userLimit }
      case wscManager cfg' of
        Nothing -> pure (OpResult
          [TrpText "WEB_SEARCH: no HTTP manager configured"]
          True (recorded cfg' q 0))
        Just mgr -> liftIO (dispatchSearch mgr cfg' q)
```

Note: `recorded` now needs to take `cfg` as a parameter since it uses `wscProvider`:

```haskell
recorded :: WebSearchConfig -> Text -> Int -> Value
recorded cfg q n = object
  [ "query"        .= q
  , "result_count" .= n
  , "provider"     .= providerName (wscProvider cfg)
  ]
```

**Step 5:** Verify compilation and run tests.

```bash
cabal build && cabal test --test-show-details=direct 2>&1 | grep -E "SearchSpec|PASS|FAIL"
```

**Step 6:** Commit.

```bash
git add -A
git commit -m "feat: update opcode description, schema with optional limit, and per-call limit override"
```

---

### Task 13: Update Existing Tests

**Objective:** Fix the existing test spec to compile with the new `WebSearchConfig` fields and add tests for provider selection.

**Files:**
- Modify: `test/Seal/Web/SearchSpec.hs`

**Step 1:** Update the test spec to use the new config record.

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Web.SearchSpec (spec) where

import Data.Aeson (object, (.=))
import Test.Hspec

import Seal.ISA.Opcode (uoAuthorize)
import Seal.Web.Search

spec :: Spec
spec = describe "WEB_SEARCH" $ do

  it "authorize gate accepts a good query" $ do
    let cfg = WebSearchConfig
          { wscManager     = Nothing
          , wscProvider    = ProviderParallel
          , wscEndpoint    = "https://search.example.com/api"
          , wscAllowList   = ["example.com"]
          , wscAuthKey     = Nothing
          , wscMaxResults  = 10
          , wscVault       = Nothing
          , wscSearXngUrl  = Nothing
          }
        op = webSearchOp cfg
    uoAuthorize op (object ["query" .= ("hello" :: String)]) `shouldBe` Right ()

  it "rejects an empty query" $ do
    let cfg = defaultTestCfg
        op = webSearchOp cfg
    uoAuthorize op (object ["query" .= ("" :: String)])
      `shouldBe` Left "WEB_SEARCH: query is empty"

  it "rejects a missing query field" $ do
    let cfg = defaultTestCfg
        op = webSearchOp cfg
    uoAuthorize op (object []) `shouldBe` Left "WEB_SEARCH requires {query:string}"

  it "rejects a negative limit" $ do
    let cfg = defaultTestCfg
        op = webSearchOp cfg
    uoAuthorize op (object ["query" .= ("test" :: String), "limit" .= (-1)])
      `shouldBe` Left "WEB_SEARCH: limit must be >= 1"

  it "accepts a valid limit" $ do
    let cfg = defaultTestCfg
        op = webSearchOp cfg
    uoAuthorize op (object ["query" .= ("test" :: String), "limit" .= (5 :: Int)])
      `shouldBe` Right ()

  it "parseProvider maps known names correctly" $ do
    parseProvider "parallel"  `shouldBe` ProviderParallel
    parseProvider "searxng"   `shouldBe` ProviderSearXNG
    parseProvider "exa"       `shouldBe` ProviderExa
    parseProvider "firecrawl" `shouldBe` ProviderFirecrawl
    parseProvider "custom"    `shouldBe` ProviderCustom
    parseProvider "unknown"   `shouldBe` ProviderParallel

  it "providerName maps providers to strings" $ do
    providerName ProviderParallel  `shouldBe` "parallel"
    providerName ProviderSearXNG   `shouldBe` "searxng"
    providerName ProviderExa       `shouldBe` "exa"
    providerName ProviderFirecrawl `shouldBe` "firecrawl"
    providerName ProviderCustom    `shouldBe` "custom"

  it "encodeResults produces valid JSON with results array" $ do
    let results = [SearchResult "Title" "https://example.com" "Description" 1]
        encoded = encodeResults results
    encoded `shouldSatisfy` ("results" `T.isInfixOf`)
    encoded `shouldSatisfy` ("Title" `T.isInfixOf`)

  where
    defaultTestCfg = WebSearchConfig
      { wscManager     = Nothing
      , wscProvider    = ProviderParallel
      , wscEndpoint    = "https://x"
      , wscAllowList   = []
      , wscAuthKey     = Nothing
      , wscMaxResults  = 10
      , wscVault       = Nothing
      , wscSearXngUrl  = Nothing
      }
```

Add import for `T.isInfixOf`:

```haskell
import Data.Text qualified as T
import Data.Text (Text)
```

**Step 2:** Export the new types and functions needed by tests from `Search.hs`.

Ensure these are exported:

```haskell
module Seal.Web.Search
  ( webSearchOp
  , WebSearchConfig (..)
  , SearchProvider (..)
  , SearchResult (..)
  , parseProvider
  , providerName
  , encodeResults
  ) where
```

**Step 3:** Run tests.

```bash
cabal test --test-show-details=direct 2>&1 | grep -E "SearchSpec|PASS|FAIL|Error"
```

Expected: All SearchSpec tests pass.

**Step 4:** Commit.

```bash
git add -A
git commit -m "test: update SearchSpec for multi-provider config and add provider tests"
```

---

### Task 14: Write Integration Test for Parallel MCP Provider

**Objective:** Add a test that exercises the Parallel MCP endpoint with a real (anonymous) search call. This is a network-dependent test — mark it as such.

**Files:**
- Modify: `test/Seal/Web/SearchSpec.hs`

**Step 1:** Add a network-dependent test.

```haskell
  -- Network-dependent test — may fail if Parallel MCP is down or rate-limited
  it "Parallel MCP returns search results for a simple query" $ do
    mgr <- newTlsManager
    let cfg = WebSearchConfig
          { wscManager     = Just mgr
          , wscProvider    = ProviderParallel
          , wscEndpoint    = ""  -- use default MCP endpoint
          , wscAllowList   = []
          , wscAuthKey     = Nothing
          , wscMaxResults  = 5
          , wscVault       = Nothing
          , wscSearXngUrl  = Nothing
          }
        op = webSearchOp cfg
    -- We can't easily run uoRun in a test without the full App monad,
    -- so we test dispatchSearch directly.
    result <- dispatchSearch mgr cfg "Haskell programming language"
    orIsError result `shouldBe` False
```

Add imports:

```haskell
import Network.HTTP.Client.TLS (newTlsManager)
import Seal.ISA.Opcode (OpResult (..))
```

**Step 2:** This test may need to be guarded or marked as pending if network access is unreliable in CI. Consider using `xit` instead of `it` for CI environments.

**Step 3:** Run tests.

```bash
cabal test --test-show-details=direct 2>&1 | grep -E "SearchSpec|PASS|FAIL"
```

**Step 4:** Commit.

```bash
git add -A
git commit -m "test: add integration test for Parallel MCP provider"
```

---

### Task 15: Write Documentation

**Objective:** Document the WEB_SEARCH provider configuration for users.

**Files:**
- Create: `docs/web-search.md` (or add to existing docs)

**Step 1:** Write the documentation.

```markdown
# WEB_SEARCH Configuration

## Quick Start (Zero Config)

No configuration needed. WEB_SEARCH defaults to **Parallel Search** using
the free MCP endpoint — no API key, no signup, no Docker.

## Provider Selection

Set the `[web] search_provider` field in your config file:

```toml
[web]
search_provider = "parallel"   # default, free, no key needed
# search_provider = "searxng"  # self-hosted, auto-installs via Docker
# search_provider = "exa"      # requires API key
# search_provider = "firecrawl" # requires API key
# search_provider = "custom"   # use your own endpoint
```

## Providers

### Parallel (default)

- **Zero-config:** Works with no API key using the free MCP endpoint
- **With API key:** Set vault key `parallel_api_key` and `search_auth_key = "parallel_api_key"`
  for higher rate limits
- **Config:** `search_max_results` (default: 10, max: 20)

### SearXNG

- **Self-hosted:** Runs a local SearXNG Docker container automatically
- **Prerequisites:** Docker must be installed and running
- **Config:**
  ```toml
  [web]
  search_provider = "searxng"
  searxng_url = "http://localhost:8888"  # default
  ```
- If no instance is running at the configured URL and the URL is localhost,
  seal-harness will attempt to start one via Docker with JSON format enabled.

### Exa

- **Requires API key:** Get one at https://exa.ai
- **Free tier:** 1,000 searches/month
- **Config:**
  ```toml
  [web]
  search_provider = "exa"
  search_auth_key = "exa_api_key"  # vault key name
  ```

### Firecrawl

- **Requires API key:** Get one at https://firecrawl.dev
- **Free tier:** 500 credits/month
- **Config:**
  ```toml
  [web]
  search_provider = "firecrawl"
  search_auth_key = "firecrawl_api_key"  # vault key name
  ```

### Custom

- Use your own search endpoint that accepts `POST {"query": "..."}` and returns
  JSON results.
- **Config:**
  ```toml
  [web]
  search_provider = "custom"
  search_endpoint = "https://your-search-api.com/search"
  ```

## API Key Setup

API keys are stored in the seal-harness vault, never in config files:

```bash
# Store an API key in the vault
/vault set exa_api_key
# (you'll be prompted to enter the key value)

# Reference it in config
# config.toml:
# [web]
# search_provider = "exa"
# search_auth_key = "exa_api_key"
```

## Common Settings

```toml
[web]
search_provider = "parallel"      # provider selection
search_max_results = 10           # max results per search
search_allow_list = ["example.com"]  # restrict results to these domains
```
```

**Step 2:** Commit.

```bash
git add docs/web-search.md
git commit -m "docs: add WEB_SEARCH provider configuration guide"
```

---

### Task 16: Final Build and Full Test Suite

**Objective:** Verify everything compiles cleanly and all tests pass.

**Step 1:** Full build.

```bash
cd ~/code/seal-harness
cabal build 2>&1
```

Expected: No errors, no warnings (`-Wall -Werror`).

**Step 2:** Full test suite.

```bash
cabal test --test-show-details=direct 2>&1
```

Expected: All tests pass (network-dependent Parallel MCP test may need to be `xit` if CI has no network).

**Step 3:** Check for unused imports or dead code.

```bash
cabal build 2>&1 | grep -i "warning\|unused"
```

Expected: No output (all warnings are errors).

**Step 4:** Final commit if any cleanup was needed.

```bash
git add -A
git commit -m "chore: final cleanup for WEB_SEARCH multi-provider implementation"
```

---

## Summary: Config Reference

```toml
# config.toml [web] section — all fields optional

[web]
# Provider selection: "parallel" (default) | "searxng" | "exa" | "firecrawl" | "custom"
search_provider = "parallel"

# Max results per search (default: 10)
search_max_results = 10

# Vault key name for the search provider's API key (for exa, firecrawl, parallel-with-key)
search_auth_key = "exa_api_key"

# Custom endpoint URL (for custom provider, or to override a provider's default endpoint)
search_endpoint = "https://custom-api.example.com/search"

# SearXNG instance URL (default: http://localhost:8888, auto-installed if localhost)
searxng_url = "http://localhost:8888"

# Domain allow-list for search results (empty = all domains allowed)
search_allow_list = ["example.com", "example.org"]

# --- WEB_FETCH settings (unchanged) ---
# fetch_allow_list = []
# max_fetch_bytes = 131072
```

## Provider Decision Matrix

| Provider        | Zero-Config | API Key | Docker | Free Tier                 | Quality                       |
| --------------- | :---------: | :-----: | :----: | ------------------------- | ----------------------------- |
| Parallel (MCP)  |      ✅      |    ❌    |   ❌    | Generous anonymous limits | Top-tier (BrowseComp 53%)     |
| Parallel (REST) |      ❌      |    ✅    |   ❌    | With key: higher limits   | Top-tier                      |
| SearXNG         |     ❌¹      |    ❌    |   ✅²   | Unlimited (self-hosted)   | Good (aggregates 70+ engines) |
| Exa             |      ❌      |    ✅    |   ❌    | 1,000 searches/mo         | Good (neural search)          |
| Firecrawl       |      ❌      |    ✅    |   ❌    | 500 credits/mo            | Good (with scrape options)    |
| Custom          |      ❌      | varies  |   ❌    | varies                    | depends on endpoint           |

¹ SearXNG auto-installs via Docker if localhost URL is configured and Docker is available
² Docker must be installed and running

## Architecture Diagram

```
                    WEB_SEARCH opcode
                          |
                    dispatchSearch
                    /     |     |     |     \
              Parallel SearXNG Exa Firecrawl Custom
              /    \       |      |     |       |
           MCP   REST   GET/JSON POST  POST    POST
         (no key) (key)         (key) (key)
              \    /       |      |     |       |
              \  /    parseSearXng  parseExa parseFirecrawl doSearch
          parseParallel     |         |        |          |
              |             |         |        |          |
              \_______ ______/________/________/ ________/
                      v
                [SearchResult]
                      |
                encodeResults → TrpText (model sees this)
                      |
                orRecorded = {query, result_count, provider} (transcript)
```

## Pitfalls and Gotchas

1. **MCP SSE responses:** The Parallel MCP endpoint may respond with `text/event-stream` (SSE) instead of `application/json`. The response parser must handle both. SSE format is `data: <json>\n\n` — parse the last `data` line. If `Content-Type` is `application/json`, skip SSE parsing.

2. **SearXNG JSON format disabled by default:** A fresh SearXNG Docker container has `formats: [html]` in `settings.yml`. The auto-install patches this to `[html, json]` via `sed` inside the container and restarts. If the `sed` pattern doesn't match (SearXNG version change), the JSON API returns 403.

3. **SearXNG rate limiting by upstream engines:** Google aggressively rate-limits SearXNG instances. This is a known issue. The instance works for light use but may degrade under heavy load. Consider configuring SearXNG to use non-Google engines if this becomes a problem.

4. **Firecrawl response shape varies by version:** v1 returns a flat `data` array. v2 returns `data.web[]` grouped by source type. The parser tries `data.web` → `data.results` → `web` → `results` → `data` (flat). Don't assume a single shape.

5. **`-Werror` is unforgiving:** Every `case` must have a catch-all. Every import must be used. Every function must have a type signature. Test locally before committing.

6. **All wiring sites must be updated:** There are 4+ sites that construct `WebSearchConfig`. Missing one means WEB_SEARCH silently uses old behavior in that context (e.g., gateway path works but CLI path doesn't). Grep for `WebSearchConfig` after all changes to verify.

7. **Vault resolution is IO:** `resolveApiKey` calls `vaultGetByName` which is `IO (Either Text Text)`. This is fine inside `uoRun` (which is `App OpResult` with `liftIO`), but the authorize gate (`uoAuthorize`) is pure and cannot resolve keys. Don't try to validate key availability in the authorize gate — handle it at runtime in the search function.

8. **Parallel MCP JSON-RPC `id` field:** The `id` in the JSON-RPC request must be an integer or string. Use `1` for simplicity. The response will echo this `id`. Don't use `null` — that signals a notification (no response expected).

9. **`threadDelay` in SearXNG auto-install:** The `threadDelay` calls (3-5 seconds) block the calling thread. In the `uoRun` context this is acceptable (it's `liftIO` in `App`), but it means the agent loop stalls during setup. This is a one-time cost on first SearXNG use.

10. **Docker container naming:** The auto-install uses a fixed container name `seal-harness-searxng`. If the user already has a SearXNG container with a different name on port 8888, the port conflict will cause the `docker run` to fail. The `isSearXngRunning` check should catch this case (existing instance on the port → no install needed).
