# Ollama Provider (Phase 3, M3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Ollama as a second model provider — one `ollama` provider that talks to a local host (`localhost:11434`, no key) or Ollama Cloud (`ollama.com`, API key), with full agent-spine tool support.

**Architecture:** A new `Seal.Providers.Ollama` module mirrors `Seal.Providers.Anthropic`: a pure request/response codec (`encodeRequest`/`decodeResponse`) split from the HTTP round-trip (`sendChat`/`listTags`), plus a `Provider` instance. The provider carries a configurable base URL and an **optional** `ApiKey` (absent ⇒ local, no auth header; present ⇒ cloud, `Authorization: Bearer`). The registry gains an `OllamaProvider` constructor and `resolveProvider` gains a `base_url` parameter that Anthropic ignores. Config gains a flat `ollama_base_url` key.

**Tech Stack:** Haskell (GHC2021), `aeson`, `http-client`, `http-types`, `tomland`, `hspec`. Build via `cabal`; the design spec is `docs/superpowers/specs/2026-07-02-ollama-provider-design.md`.

## Global Constraints

- **Warnings are errors.** The `common settings` stanza sets `-Wall -Werror -Wcompat -Widentities -Wincomplete-uni-patterns -Wincomplete-record-updates -Wname-shadowing -Wpartial-fields -Wredundant-constraints`. Every task must build clean: no unused binds (prefix intentionally-unused args with `_`), no partial-field accessors (destructure in list comprehensions / pattern matches, never as bare functions), no incomplete patterns.
- **Default extensions** (already on, do not re-declare): `DeriveGeneric DerivingStrategies LambdaCase ScopedTypeVariables`. Add `{-# LANGUAGE OverloadedStrings #-}` per-module as the existing provider modules do.
- **Secrets never surface.** Key bytes only ever live inside the `withApiKey` continuation. No `Show`, no JSON, no transcript, no log for key material. The base URL is *not* secret and may appear in error messages.
- **Error convention:** `Either Text` (project convention); typed ADT only where control flow needs it.
- **Build/test commands** (run inside the nix dev shell if not already in one — prefix with `nix develop --command` when needed):
  - Build: `cabal build all`
  - Full test: `cabal test`
  - Focused test: `cabal test --test-options='--match "<needle>"'`
- **Commit style:** frequent, one per task. End commit messages with the repo's `Co-Authored-By` trailer only if the user's git config expects it; otherwise a plain conventional-commit subject is fine.

---

### Task 1: Config — `ollama_base_url` field

Add one optional flat field to `FileConfig` so the Ollama base URL is persisted in `config.toml`. Default resolution (`Nothing → http://localhost:11434`) lives in the Ollama module (Task 2), so this task only adds the field + codec.

**Files:**
- Modify: `src/Seal/Config/File.hs`
- Test: `test/Seal/Config/FileSpec.hs`

**Interfaces:**
- Produces: `fcOllamaBaseUrl :: FileConfig -> Maybe Text` (TOML key `ollama_base_url`); it is part of the `FileConfig` record literal (all fields explicit).

- [ ] **Step 1: Write the failing tests**

In `test/Seal/Config/FileSpec.hs`, update the `defaultFileConfig` "has all Nothing fields" expectation to include the new field, and add a parse test. First, add the field to the existing full-record literal in the `defaultFileConfig` test (around line 20):

```haskell
    it "has all Nothing fields" $
      defaultFileConfig `shouldBe` FileConfig
        { fcVaultPath      = Nothing
        , fcVaultRecipient = Nothing
        , fcVaultIdentity  = Nothing
        , fcVaultUnlock    = Nothing
        , fcVaultKeyType   = Nothing
        , fcDefaultProvider = Nothing
        , fcDefaultModel    = Nothing
        , fcOllamaBaseUrl   = Nothing
        }
```

Then add a new parse test inside the `describe "loadFileConfig"` block:

```haskell
    it "parses ollama_base_url" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "ollama_base_url = \"https://ollama.com\"\n"
        result <- loadFileConfig path
        case result of
          Left err  -> expectationFailure ("parse failed: " <> T.unpack err)
          Right cfg -> fcOllamaBaseUrl cfg `shouldBe` Just "https://ollama.com"
```

Also update the fully-populated round-trip literal in the `describe "saveFileConfig / loadFileConfig round-trip"` block (the `let cfg = FileConfig { ... }` around line 70) to set `fcOllamaBaseUrl = Just "http://localhost:11434"` so the record stays total.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cabal test --test-options='--match "Seal.Config.File"'`
Expected: FAIL — `fcOllamaBaseUrl` not in scope / record construction incomplete.

- [ ] **Step 3: Add the field, default, and codec line**

In `src/Seal/Config/File.hs`:

Add the record field (after `fcDefaultModel`):

```haskell
  , fcDefaultModel :: Maybe Text
    -- ^ Model id used for new sessions (e.g. @\"claude-opus-4-8\"@).
  , fcOllamaBaseUrl :: Maybe Text
    -- ^ Ollama host base URL (default @http:\/\/localhost:11434@ applied by the
    -- Ollama provider). @https:\/\/ollama.com@ for Ollama Cloud.
  } deriving stock (Eq, Show)
```

Add to `defaultFileConfig`:

```haskell
  , fcDefaultModel    = Nothing
  , fcOllamaBaseUrl   = Nothing
  }
```

Add the codec line (last field in the applicative chain):

```haskell
  <*> Toml.dioptional (Toml.text "default_model")    .= fcDefaultModel
  <*> Toml.dioptional (Toml.text "ollama_base_url")  .= fcOllamaBaseUrl
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cabal test --test-options='--match "Seal.Config.File"'`
Expected: PASS (all `Seal.Config.File` examples green).

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Config/File.hs test/Seal/Config/FileSpec.hs
git commit -m "feat(config): add ollama_base_url field"
```

---

### Task 2: Ollama module — request encoding + helpers

Create `Seal.Providers.Ollama` with the data type, constructors, URL/header helpers, the default base URL, and the pure `encodeRequest`. No `Provider` instance yet (added in Task 4) — the module compiles without it. Register the module in cabal and create its spec.

**Files:**
- Create: `src/Seal/Providers/Ollama.hs`
- Create: `test/Seal/Providers/OllamaSpec.hs`
- Modify: `seal-harness.cabal` (library `exposed-modules`; test `other-modules`)
- Modify: `test/Main.hs` (import + call the new spec)

**Interfaces:**
- Produces:
  - `data Ollama = Ollama { olModel :: ModelId, olManager :: Manager, olBaseUrl :: Text, olApiKey :: Maybe ApiKey }`
  - `mkOllama :: Manager -> Text -> Maybe ApiKey -> ModelId -> Ollama`
  - `defaultOllamaBaseUrl :: Text`
  - `chatUrl :: Text -> Text`, `tagsUrl :: Text -> Text` (base-URL join, strips one trailing slash)
  - `ollamaHeaders :: Maybe ByteString -> RequestHeaders`
  - `encodeRequest :: CompletionRequest -> Value`

- [ ] **Step 1: Create the module with type + helpers + encodeRequest**

Create `src/Seal/Providers/Ollama.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | Ollama provider (local host or Ollama Cloud). One provider; local vs cloud
-- is the configured base URL plus whether an API key is present. JSON mapping is
-- pure ('encodeRequest' / 'decodeResponse'); 'complete' adds the HTTP round-trip
-- and supplies the optional bearer key via the CPS 'withApiKey' accessor so the
-- key bytes only ever live on the request header inside the continuation.
-- Non-streaming. Ollama tool-calls carry no id, so ids are synthesized on decode
-- ("call_<i>") and dropped on encode (Ollama matches tool results by order).
module Seal.Providers.Ollama
  ( Ollama (..)
  , mkOllama
  , defaultOllamaBaseUrl
  , chatUrl
  , tagsUrl
  , ollamaHeaders
  , ollamaErrorText
  , unreachableMsg
  , encodeRequest
  , decodeResponse
  ) where

import Control.Exception (try)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Network.HTTP.Client
import Network.HTTP.Types (statusCode)
import Network.HTTP.Types.Header (RequestHeaders)

import Seal.Core.Types (ModelId (..), OpName (..), ToolCallId (..))
import Seal.Providers.Class
import Seal.Security.Secrets (ApiKey, withApiKey)

-- Data type ----------------------------------------------------------------

data Ollama = Ollama
  { olModel   :: ModelId
  , olManager :: Manager
  , olBaseUrl :: Text          -- e.g. "http://localhost:11434" | "https://ollama.com"
  , olApiKey  :: Maybe ApiKey  -- Nothing = local (no auth); Just = cloud (Bearer)
  }

mkOllama :: Manager -> Text -> Maybe ApiKey -> ModelId -> Ollama
mkOllama mgr base mKey model = Ollama model mgr base mKey

-- URL + headers ------------------------------------------------------------

defaultOllamaBaseUrl :: Text
defaultOllamaBaseUrl = "http://localhost:11434"

stripTrailingSlash :: Text -> Text
stripTrailingSlash t = fromMaybe t (T.stripSuffix "/" t)

chatUrl :: Text -> Text
chatUrl base = stripTrailingSlash base <> "/api/chat"

tagsUrl :: Text -> Text
tagsUrl base = stripTrailingSlash base <> "/api/tags"

-- | Local: content-type only. Cloud: add a bearer authorization header.
ollamaHeaders :: Maybe ByteString -> RequestHeaders
ollamaHeaders mKey =
  ("content-type", "application/json")
    : [ ("authorization", "Bearer " <> kb) | Just kb <- [mKey] ]

-- Pure request mapping -----------------------------------------------------

encodeRequest :: CompletionRequest -> Value
encodeRequest cr = object $
  [ "model"    .= crModel cr
  , "stream"   .= False
  , "messages" .= (systemMsgs <> concatMap encMsg (crMessages cr))
  , "options"  .= object ["num_predict" .= crMaxTokens cr]
  ]
  <> ["tools" .= map encTool (crTools cr) | not (null (crTools cr))]
  where
    systemMsgs =
      maybe []
        (\s -> [object ["role" .= ("system" :: Text), "content" .= s]])
        (crSystem cr)

-- | Flatten one provider-agnostic message into zero or more Ollama messages.
-- A User message becomes a "user" message (its text, if any) followed by one
-- "tool" message per tool-result block. An Assistant message becomes one
-- "assistant" message carrying its text and any tool_calls.
encMsg :: Message -> [Value]
encMsg (Message User blocks) =
  let texts = [t | CbText t <- blocks]
      userMsg =
        [ object ["role" .= ("user" :: Text), "content" .= T.intercalate "\n" texts]
        | not (null texts) ]
      toolMsgs =
        [ object ["role" .= ("tool" :: Text), "content" .= joinParts parts]
        | CbToolResult _ parts _ <- blocks ]
  in userMsg <> toolMsgs
encMsg (Message Assistant blocks) =
  let content = T.intercalate "\n" [t | CbText t <- blocks]
      toolCalls =
        [ object ["function" .= object ["name" .= n, "arguments" .= inp]]
        | CbToolUse _ (OpName n) inp <- blocks ]
      tc = ["tool_calls" .= toolCalls | not (null toolCalls)]
  in [object (["role" .= ("assistant" :: Text), "content" .= content] <> tc)]

-- | Ollama's tool role has no error channel, so cbIsError is folded into the
-- content text; parts are newline-joined.
joinParts :: [ToolResultPart] -> Text
joinParts parts = T.intercalate "\n" [t | TrpText t <- parts]

encTool :: ToolDefinition -> Value
encTool (ToolDefinition (OpName n) d sch) =
  object
    [ "type" .= ("function" :: Text)
    , "function" .= object ["name" .= n, "description" .= d, "parameters" .= sch]
    ]
```

Note: `decodeResponse`, `ollamaErrorText`, and `unreachableMsg` are exported here but **defined in Task 3**; add stubbed definitions now so the module compiles, or (preferred) do Task 2 and Task 3 as one build cycle. To keep Task 2 self-compiling, temporarily add at the bottom:

```haskell
-- Defined in Task 3.
decodeResponse :: Value -> Either Text CompletionResponse
decodeResponse _ = Left "decodeResponse: not yet implemented"

ollamaErrorText :: Int -> Text -> Text
ollamaErrorText code body = "HTTP " <> T.pack (show code) <> ": " <> body

unreachableMsg :: Text -> Text
unreachableMsg base = "could not reach Ollama at " <> base
```

(These stubs are replaced wholesale in Task 3; the export list already lists them. The unused imports `try`, `BL`, `TE`, `TEE`, `statusCode`, `ModelId`, `ToolCallId`, `Parser`, `parseEither` are consumed in Tasks 3–4 — to avoid `-Werror` unused-import failures **in this task only**, either land Task 2+3 together before building, or trim the import list to what Step-1 code uses and re-add in Task 3. Simplest: implement Task 2 and Task 3 back-to-back and build once at the end of Task 3.)

- [ ] **Step 2: Register the module in cabal and the test aggregator**

In `seal-harness.cabal`, add to the library `exposed-modules` (alphabetically near the other providers, after `Seal.Providers.Class`):

```
        Seal.Providers.Ollama
```

Add to the test-suite `other-modules`:

```
        Seal.Providers.OllamaSpec
```

In `test/Main.hs`, add the import (near the other provider spec imports):

```haskell
import qualified Seal.Providers.OllamaSpec
```

and the call (near `Seal.Providers.RegistrySpec.spec`):

```haskell
  Seal.Providers.OllamaSpec.spec
```

- [ ] **Step 3: Write the encodeRequest tests**

Create `test/Seal/Providers/OllamaSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.OllamaSpec (spec) where

import Data.Aeson
import Test.Hspec

import Seal.Core.Types
import Seal.Providers.Class
import Seal.Providers.Ollama

spec :: Spec
spec = describe "Seal.Providers.Ollama" $ do

  describe "chatUrl / tagsUrl" $ do
    it "appends the path, stripping one trailing slash" $ do
      chatUrl "http://localhost:11434"  `shouldBe` "http://localhost:11434/api/chat"
      chatUrl "http://localhost:11434/" `shouldBe` "http://localhost:11434/api/chat"
      tagsUrl "https://ollama.com"      `shouldBe` "https://ollama.com/api/tags"

  describe "ollamaHeaders" $ do
    it "local: content-type only, no authorization" $ do
      let hs = ollamaHeaders Nothing
      lookup "content-type"  hs `shouldBe` Just "application/json"
      lookup "authorization" hs `shouldBe` Nothing
    it "cloud: adds a bearer authorization header" $ do
      let hs = ollamaHeaders (Just "k-123")
      lookup "authorization" hs `shouldBe` Just "Bearer k-123"

  describe "encodeRequest" $ do
    it "emits model, stream=false, num_predict, and a user message" $ do
      let req = CompletionRequest (ModelId "llama3.2") Nothing
                  [textMsg User "hi"] [] ToolAuto 4096
      encodeRequest req `shouldBe` object
        [ "model"    .= ("llama3.2" :: String)
        , "stream"   .= False
        , "messages" .= [object [ "role" .= ("user" :: String), "content" .= ("hi" :: String)]]
        , "options"  .= object ["num_predict" .= (4096 :: Int)]
        ]

    it "prepends a system message when crSystem is set" $ do
      let req = CompletionRequest (ModelId "m") (Just "be brief")
                  [textMsg User "hi"] [] ToolAuto 16
          Object o = encodeRequest req
      case parseMaybe (.: "messages") (Object o) :: Maybe [Value] of
        Just (m0 : _) -> m0 `shouldBe`
          object ["role" .= ("system" :: String), "content" .= ("be brief" :: String)]
        _ -> expectationFailure "expected a system message first"

    it "encodes a CbToolUse in an assistant message as tool_calls" $ do
      let asst = Message Assistant
                   [CbToolUse (ToolCallId "call_0") (OpName "FILE_READ")
                              (object ["path" .= ("a.txt" :: String)])]
          req = CompletionRequest (ModelId "m") Nothing [asst] [] ToolAuto 16
      case parseMaybe (.: "messages") (encodeRequest req) :: Maybe [Value] of
        Just [m] -> m `shouldBe` object
          [ "role" .= ("assistant" :: String)
          , "content" .= ("" :: String)
          , "tool_calls" .=
              [object ["function" .= object
                 [ "name" .= ("FILE_READ" :: String)
                 , "arguments" .= object ["path" .= ("a.txt" :: String)]]]]
          ]
        _ -> expectationFailure "expected one assistant message"

    it "expands a User message of tool results into ordered tool messages" $ do
      let user = Message User
                   [ CbToolResult (ToolCallId "call_0") [TrpText "one"] False
                   , CbToolResult (ToolCallId "call_1") [TrpText "two"] True ]
          req = CompletionRequest (ModelId "m") Nothing [user] [] ToolAuto 16
      parseMaybe (.: "messages") (encodeRequest req) `shouldBe`
        Just [ object ["role" .= ("tool" :: String), "content" .= ("one" :: String)]
             , object ["role" .= ("tool" :: String), "content" .= ("two" :: String)] ]

    it "includes a tools array only when tools are present" $ do
      let tool = ToolDefinition (OpName "FILE_READ") "read a file"
                   (object ["type" .= ("object" :: String)])
          req  = CompletionRequest (ModelId "m") Nothing [textMsg User "hi"]
                   [tool] ToolAuto 16
      case parseMaybe (.: "tools") (encodeRequest req) :: Maybe [Value] of
        Just [t] -> t `shouldBe` object
          [ "type" .= ("function" :: String)
          , "function" .= object
              [ "name" .= ("FILE_READ" :: String)
              , "description" .= ("read a file" :: String)
              , "parameters" .= object ["type" .= ("object" :: String)] ]
          ]
        _ -> expectationFailure "expected one tool"
```

- [ ] **Step 4: Build and run the tests**

Run: `cabal build all && cabal test --test-options='--match "Seal.Providers.Ollama"'`
Expected: the `chatUrl`, `ollamaHeaders`, and all five `encodeRequest` examples PASS. (The `decodeResponse` stub is not exercised yet.)

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Providers/Ollama.hs test/Seal/Providers/OllamaSpec.hs seal-harness.cabal test/Main.hs
git commit -m "feat(ollama): add module scaffold + request encoding"
```

---

### Task 3: Ollama response decoding + error text

Replace the Task 2 stubs with the real `decodeResponse`, `ollamaErrorText`, and `unreachableMsg`.

**Files:**
- Modify: `src/Seal/Providers/Ollama.hs`
- Test: `test/Seal/Providers/OllamaSpec.hs`

**Interfaces:**
- Produces:
  - `decodeResponse :: Value -> Either Text CompletionResponse`
  - `ollamaErrorText :: Int -> Text -> Text`
  - `unreachableMsg :: Text -> Text`

- [ ] **Step 1: Write the failing tests**

Append to `test/Seal/Providers/OllamaSpec.hs` inside the top-level `describe`:

```haskell
  describe "decodeResponse" $ do
    it "parses a text-only message with usage and stop=end" $ do
      let body = object
            [ "message" .= object ["role" .= ("assistant" :: String), "content" .= ("yo" :: String)]
            , "done_reason" .= ("stop" :: String)
            , "prompt_eval_count" .= (3 :: Int)
            , "eval_count" .= (1 :: Int)
            ]
      decodeResponse body `shouldBe`
        Right (CompletionResponse [CbText "yo"] StopEnd (Usage 3 1))

    it "parses tool_calls into CbToolUse with synthesized ids and object args" $ do
      let body = object
            [ "message" .= object
                [ "role" .= ("assistant" :: String)
                , "content" .= ("" :: String)
                , "tool_calls" .=
                    [ object ["function" .= object
                        ["name" .= ("FILE_READ" :: String)
                        , "arguments" .= object ["path" .= ("a.txt" :: String)]]]
                    , object ["function" .= object
                        ["name" .= ("SECRET_GET" :: String)
                        , "arguments" .= object ["name" .= ("K" :: String)]]]
                    ]
                ]
            , "done_reason" .= ("stop" :: String)
            ]
      decodeResponse body `shouldBe`
        Right (CompletionResponse
                [ CbToolUse (ToolCallId "call_0") (OpName "FILE_READ")
                    (object ["path" .= ("a.txt" :: String)])
                , CbToolUse (ToolCallId "call_1") (OpName "SECRET_GET")
                    (object ["name" .= ("K" :: String)]) ]
                StopToolUse
                (Usage 0 0))

    it "maps done_reason=length to StopMaxTokens" $ do
      let body = object
            [ "message" .= object ["role" .= ("assistant" :: String), "content" .= ("x" :: String)]
            , "done_reason" .= ("length" :: String)
            ]
      decodeResponse body `shouldBe`
        Right (CompletionResponse [CbText "x"] StopMaxTokens (Usage 0 0))

    it "defaults usage counts to zero when absent" $ do
      let body = object
            [ "message" .= object ["role" .= ("assistant" :: String), "content" .= ("x" :: String)] ]
      decodeResponse body `shouldBe`
        Right (CompletionResponse [CbText "x"] StopEnd (Usage 0 0))

  describe "ollamaErrorText / unreachableMsg" $ do
    it "401 points the user at /provider add ollama" $ do
      let m = ollamaErrorText 401 "unauthorized"
      m `shouldSatisfy` (T.isInfixOf "401")
      m `shouldSatisfy` (T.isInfixOf "/provider add ollama")
    it "other statuses include the code and body" $ do
      let m = ollamaErrorText 400 "bad model"
      m `shouldSatisfy` (T.isInfixOf "400")
      m `shouldSatisfy` (T.isInfixOf "bad model")
    it "unreachable mentions the base url and how to start ollama" $ do
      let m = unreachableMsg "http://localhost:11434"
      m `shouldSatisfy` (T.isInfixOf "http://localhost:11434")
      m `shouldSatisfy` (T.isInfixOf "ollama serve")
```

Add `import qualified Data.Text as T` to the spec's imports.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cabal test --test-options='--match "decodeResponse"'`
Expected: FAIL — the stub returns `Left "decodeResponse: not yet implemented"`.

- [ ] **Step 3: Replace the stubs with real implementations**

In `src/Seal/Providers/Ollama.hs`, delete the three Task-2 stub definitions and add:

```haskell
-- Pure response mapping ----------------------------------------------------

decodeResponse :: Value -> Either Text CompletionResponse
decodeResponse = mapLeft T.pack . parseEither parseResp
  where mapLeft f = either (Left . f) Right

parseResp :: Value -> Parser CompletionResponse
parseResp = withObject "ollama response" $ \o -> do
  msg        <- o .: "message"
  content    <- msg .:? "content" .!= ""
  rawCalls   <- msg .:? "tool_calls" .!= ([] :: [Value])
  toolBlocks <- traverse parseToolCall (zip [0 :: Int ..] rawCalls)
  doneReason <- o .:? "done_reason"
  promptTok  <- o .:? "prompt_eval_count" .!= 0
  evalTok    <- o .:? "eval_count" .!= 0
  let textBlocks = [CbText content | not (T.null content)]
      blocks     = textBlocks <> toolBlocks
      stop       = if not (null toolBlocks) then StopToolUse else stopFromDone doneReason
  pure (CompletionResponse blocks stop (Usage promptTok evalTok))

-- | Ollama tool calls carry no id; synthesize a stable "call_<i>" per index.
parseToolCall :: (Int, Value) -> Parser ContentBlock
parseToolCall (i, v) = flip (withObject "tool_call") v $ \o -> do
  fn   <- o .: "function"
  name <- fn .: "name"
  args <- fn .:? "arguments" .!= object []
  pure (CbToolUse (ToolCallId ("call_" <> T.pack (show i))) (OpName name) args)

stopFromDone :: Maybe Text -> StopReason
stopFromDone (Just "length") = StopMaxTokens
stopFromDone (Just "stop")   = StopEnd
stopFromDone Nothing         = StopEnd
stopFromDone (Just other)    = StopOther other

-- Error rendering ----------------------------------------------------------

-- | Render a non-2xx Ollama response, key-safely (the body carries no secret).
ollamaErrorText :: Int -> Text -> Text
ollamaErrorText 401 _ =
  "Ollama rejected the credential (HTTP 401) — check the key with /provider add ollama"
ollamaErrorText code body =
  "Ollama API returned HTTP " <> T.pack (show code) <> ": " <> body

-- | Transport failure (connection refused is the common "not running" case).
-- The base URL is not secret.
unreachableMsg :: Text -> Text
unreachableMsg base =
  "could not reach Ollama at " <> base
    <> " — is it running and the URL correct? (try: ollama serve)"
```

- [ ] **Step 4: Build and run the tests**

Run: `cabal build all && cabal test --test-options='--match "Seal.Providers.Ollama"'`
Expected: PASS — all encode + decode + error-text examples green, build `-Werror` clean.

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Providers/Ollama.hs test/Seal/Providers/OllamaSpec.hs
git commit -m "feat(ollama): add response decoding + key-safe error text"
```

---

### Task 4: Ollama HTTP round-trip + Provider instance

Add the HTTP calls (`sendChat`, `listTags`) and the `Provider Ollama` instance wiring text + tools through Ollama's endpoints. No unit test drives the network; the deliverable is a clean build plus a `pending` live test.

**Files:**
- Modify: `src/Seal/Providers/Ollama.hs`
- Test: `test/Seal/Providers/OllamaSpec.hs`

**Interfaces:**
- Consumes: `encodeRequest`, `decodeResponse`, `ollamaHeaders`, `chatUrl`, `tagsUrl`, `ollamaErrorText`, `unreachableMsg` (this module); `withApiKey` (Secrets); `Provider (..)` (Class).
- Produces: `instance Provider Ollama` with `complete` and `listModels`.

- [ ] **Step 1: Add the HTTP round-trip and Provider instance**

In `src/Seal/Providers/Ollama.hs`, add (the imports `try`, `BL`, `TE`, `TEE`, `statusCode`, `ModelId`, `withApiKey`, `HttpException` are now all consumed):

```haskell
-- HTTP round-trip ----------------------------------------------------------

-- | POST {base}/api/chat with the given headers; decode, or return a key-safe
-- transport / HTTP-status error.
sendChat
  :: Manager -> Text -> RequestHeaders -> CompletionRequest
  -> IO (Either Text CompletionResponse)
sendChat mgr base hdrs cr = do
  result <- try $ do
    initReq <- parseRequest (T.unpack ("POST " <> chatUrl base))
    let req = initReq
          { requestBody     = RequestBodyLBS (encode (encodeRequest cr))
          , requestHeaders  = hdrs
          }
    httpLbs req mgr
  case result of
    Left (_ :: HttpException) -> pure (Left (unreachableMsg base))
    Right resp -> do
      let code = statusCode (responseStatus resp)
      if code >= 200 && code <= 299
        then pure $ case eitherDecode (responseBody resp) of
          Left e  -> Left (T.pack e)
          Right v -> decodeResponse v
        else pure $ Left $ ollamaErrorText code
          (TE.decodeUtf8With TEE.lenientDecode (BL.toStrict (responseBody resp)))

-- | GET {base}/api/tags → the installed model names.
listTags :: Manager -> Text -> RequestHeaders -> IO (Either Text [ModelId])
listTags mgr base hdrs = do
  result <- try $ do
    initReq <- parseRequest (T.unpack ("GET " <> tagsUrl base))
    httpLbs initReq { requestHeaders = hdrs } mgr
  case result of
    Left (_ :: HttpException) -> pure (Left (unreachableMsg base))
    Right resp -> do
      let code = statusCode (responseStatus resp)
      if code >= 200 && code <= 299
        then pure $ case eitherDecode (responseBody resp) of
          Left e  -> Left (T.pack e)
          Right v -> parseTags v
        else pure $ Left $ ollamaErrorText code
          (TE.decodeUtf8With TEE.lenientDecode (BL.toStrict (responseBody resp)))

parseTags :: Value -> Either Text [ModelId]
parseTags = mapLeft T.pack . parseEither p
  where
    mapLeft f = either (Left . f) Right
    p = withObject "tags" $ \o -> do
      models <- o .:? "models" .!= ([] :: [Value])
      traverse (withObject "model" (\m -> ModelId <$> m .: "name")) models

-- Provider instance --------------------------------------------------------

instance Provider Ollama where
  listModels o = withHeaders o (listTags (olManager o) (olBaseUrl o))
  complete o cr =
    withHeaders o (\hdrs -> sendChat (olManager o) (olBaseUrl o) hdrs cr)

-- | Run @k@ with request headers built from the optional key; the key bytes
-- live only inside the 'withApiKey' continuation.
withHeaders :: Ollama -> (RequestHeaders -> IO r) -> IO r
withHeaders o k = case olApiKey o of
  Nothing  -> k (ollamaHeaders Nothing)
  Just key -> withApiKey key (\kb -> k (ollamaHeaders (Just kb)))
```

Add the `HttpException` import if not already covered by `import Network.HTTP.Client` (it re-exports `HttpException`). Confirm `parseTags`'s `mapLeft`/`p` do not shadow the `decodeResponse` local `mapLeft` (they are in separate `where` clauses — no shadow warning).

- [ ] **Step 2: Add a pending live test**

Append to `test/Seal/Providers/OllamaSpec.hs`:

```haskell
  describe "Provider Ollama (live)" $
    it "chat + tags round-trip against a running ollama" $
      pendingWith "needs a local `ollama serve` at http://localhost:11434"
```

- [ ] **Step 3: Build and run the full provider spec**

Run: `cabal build all && cabal test --test-options='--match "Seal.Providers.Ollama"'`
Expected: PASS (pure examples green, live example reported `pending`). Build is `-Werror` clean.

- [ ] **Step 4: Commit**

```bash
git add src/Seal/Providers/Ollama.hs test/Seal/Providers/OllamaSpec.hs
git commit -m "feat(ollama): add HTTP round-trip + Provider instance"
```

---

### Task 5: Registry — add `OllamaProvider` and thread `base_url` through `resolveProvider`

Add the `OllamaProvider` constructor, extend every totality function, and change `resolveProvider`'s signature to take a `base_url :: Text` (Anthropic ignores it; Ollama uses it and reads the key **optionally**). This ripples to both non-test call sites (`Seal.Channel.Cli`, `Seal.Command.Provider`), which must be updated in this same task to keep the build green. `/model use ollama <name>` and `/model list` start working automatically because they iterate `knownProviders` / call `parseProvider`.

**Files:**
- Modify: `src/Seal/Providers/Registry.hs`
- Modify: `src/Seal/Channel/Cli.hs` (`resolveSessionProvider`)
- Modify: `src/Seal/Command/Provider.hs` (`testCmd` only — the base_url arg)
- Test: `test/Seal/Providers/RegistrySpec.hs`

**Interfaces:**
- Consumes: `mkOllama`, `defaultOllamaBaseUrl` (Ollama module); `loadFileConfig`, `fcOllamaBaseUrl` (Config.File).
- Produces:
  - `KnownProvider` gains `OllamaProvider`.
  - `resolveProvider :: VaultHandle -> Manager -> Text -> KnownProvider -> ModelId -> IO (Either Text SomeProvider)` (new 3rd param = base URL).
  - `providerLabel OllamaProvider = "ollama"`, `vaultKeyName OllamaProvider = "OLLAMA_API_KEY"`, `defaultModelFor OllamaProvider = ModelId "llama3.2"`.

- [ ] **Step 1: Update the RegistrySpec expectations and add Ollama resolution tests**

In `test/Seal/Providers/RegistrySpec.hs`:

Update the vocabulary expectations:

```haskell
  it "lists the known providers" $
    knownProviders `shouldBe` [AnthropicProvider, OllamaProvider]
```

Add, alongside the Anthropic label/key/model examples:

```haskell
  it "labels Ollama" $
    providerLabel OllamaProvider `shouldBe` "ollama"

  it "parses ollama case-insensitively" $ do
    parseProvider "ollama" `shouldBe` Just OllamaProvider
    parseProvider "Ollama" `shouldBe` Just OllamaProvider

  it "names the Ollama vault credential key" $
    vaultKeyName OllamaProvider `shouldBe` "OLLAMA_API_KEY"

  it "has an Ollama default model" $
    defaultModelFor OllamaProvider `shouldBe` ModelId "llama3.2"
```

Update the **four** existing `resolveProvider` calls to pass a base-URL argument in the new 3rd position (any string works for Anthropic; use `"http://localhost:11434"`). For example the first one becomes:

```haskell
      r   <- resolveProvider vh mgr "http://localhost:11434" AnthropicProvider (ModelId "claude-opus-4-8")
```

Apply the same edit to the other three Anthropic `resolveProvider` calls in that file.

Add a new `describe` block for Ollama resolution:

```haskell
  describe "resolveProvider (ollama)" $ do
    it "resolves local Ollama with no stored key" $ do
      vh  <- makeFakeVault []
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider vh mgr "http://localhost:11434" OllamaProvider (ModelId "llama3.2")
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right (local), got Left: " <> show e)

    it "resolves cloud Ollama when a key is present" $ do
      vh  <- makeFakeVault [("OLLAMA_API_KEY", "k-cloud")]
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider vh mgr "https://ollama.com" OllamaProvider (ModelId "m")
      case r of
        Right _ -> pure ()
        Left e  -> expectationFailure ("expected Right (cloud), got Left: " <> show e)

    it "surfaces a locked vault rather than treating it as local" $ do
      vh  <- makeLockedVault
      mgr <- newManager defaultManagerSettings
      r   <- resolveProvider vh mgr "http://localhost:11434" OllamaProvider (ModelId "m")
      case r of
        Left e  -> e `shouldSatisfy` ("locked" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left for a locked vault"
```

- [ ] **Step 2: Run tests to verify they fail (compile error)**

Run: `cabal test --test-options='--match "Seal.Providers.Registry"'`
Expected: FAIL to compile — `OllamaProvider` not in scope and `resolveProvider` arity mismatch.

- [ ] **Step 3: Extend the registry**

In `src/Seal/Providers/Registry.hs`:

Add imports:

```haskell
import Seal.Providers.Ollama (mkOllama)
```

(`defaultOllamaBaseUrl` is applied at the call sites, not here.) Extend the sum:

```haskell
data KnownProvider = AnthropicProvider | OllamaProvider
  deriving stock (Eq, Show, Enum, Bounded)
```

Extend the totality functions (each already pattern-complete; add the Ollama case):

```haskell
providerLabel :: KnownProvider -> Text
providerLabel AnthropicProvider = "anthropic"
providerLabel OllamaProvider    = "ollama"

vaultKeyName :: KnownProvider -> Text
vaultKeyName AnthropicProvider = "ANTHROPIC_API_KEY"
vaultKeyName OllamaProvider    = "OLLAMA_API_KEY"

defaultModelFor :: KnownProvider -> ModelId
defaultModelFor AnthropicProvider = ModelId "claude-opus-4-8"
defaultModelFor OllamaProvider    = ModelId "llama3.2"
```

Change `resolveProvider`'s signature and add the Ollama clause. The existing Anthropic clause gains an ignored base-URL param:

```haskell
resolveProvider
  :: VaultHandle -> Manager -> Text -> KnownProvider -> ModelId
  -> IO (Either Text SomeProvider)
resolveProvider vh mgr _baseUrl AnthropicProvider model = do
  -- ... body unchanged ...
```

(Keep the entire existing Anthropic body; only the head line adds `_baseUrl`.) Add:

```haskell
resolveProvider vh mgr baseUrl OllamaProvider model = do
  eKey <- vhGet vh (vaultKeyName OllamaProvider)
  pure $ case eKey of
    Right keyBytes            -> Right (SomeProvider (mkOllama mgr baseUrl (Just (mkApiKey keyBytes)) model))
    Left (VaultKeyNotFound _) -> Right (SomeProvider (mkOllama mgr baseUrl Nothing model))   -- local, no key
    Left e                    -> Left (vaultErrText e)
```

`VaultKeyNotFound` and `vaultErrText` are already in scope (imports of `VaultError (..)` and the local helper). `mkApiKey` is already imported.

- [ ] **Step 4: Update the two non-test call sites**

In `src/Seal/Channel/Cli.hs`, `resolveSessionProvider` must load the base URL from config and pass it. Add imports:

```haskell
import Data.Maybe (fromMaybe)
import Seal.Config.File (fcOllamaBaseUrl, loadFileConfig)
import Seal.Providers.Ollama (defaultOllamaBaseUrl)
```

Change the resolve to look up the base URL (config path is `prConfigPath pr`):

```haskell
        Just vh -> do
          let model = ModelId (smModel meta)
          eCfg <- loadFileConfig (prConfigPath pr)
          let baseUrl = fromMaybe defaultOllamaBaseUrl
                          (either (const Nothing) fcOllamaBaseUrl eCfg)
          fmap (fmap (, model)) (resolveProvider vh (prManager pr) baseUrl kp model)
```

(`prConfigPath` and `prManager` are fields of the `ProviderRuntime` already bound as `pr` in this function; confirm `ProviderRuntime (..)` / the needed accessors are imported — `Seal.Command.Provider` is already imported here for `ProviderRuntime`.)

In `src/Seal/Command/Provider.hs`, `testCmd` already loads the config (`eCfg`) for the model; reuse it for the base URL and pass it to `resolveProvider`. Add imports:

```haskell
import Data.Maybe (fromMaybe)
import Seal.Providers.Ollama (defaultOllamaBaseUrl)
```

and update the resolve line and add the base-URL binding:

```haskell
      let model = case eCfg of
            Right c | Just m <- fcDefaultModel c -> ModelId m
            _                                    -> defaultModelFor kp
          baseUrl = fromMaybe defaultOllamaBaseUrl
                      (either (const Nothing) fcOllamaBaseUrl eCfg)
      eProv <- resolveProvider vh (prManager pr) baseUrl kp model
```

Add `fcOllamaBaseUrl` to the existing `Seal.Config.File (FileConfig (..), ...)` import list (it is exported by `FileConfig (..)`; ensure the import brings the accessor — `FileConfig (..)` already does).

- [ ] **Step 5: Build and run the affected tests**

Run: `cabal build all && cabal test --test-options='--match "Seal.Providers.Registry"'`
Expected: build clean; all registry examples PASS (Anthropic + the three Ollama resolution cases).

Also run the command specs to confirm nothing regressed:

Run: `cabal test --test-options='--match "Seal.Command"'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/Seal/Providers/Registry.hs src/Seal/Channel/Cli.hs src/Seal/Command/Provider.hs test/Seal/Providers/RegistrySpec.hs
git commit -m "feat(registry): register ollama + thread base_url through resolveProvider"
```

---

### Task 6: `/provider add ollama` two-step prompt + `/provider list` local status

Make `/provider add ollama` prompt for the base URL (saved to config) then an optional API key (blank ⇒ local), and make `/provider list` report `auth: none (local)` for Ollama when no key is stored. Anthropic's flows stay exactly as they are. Also fix `reportOne` so it only consults the Anthropic OAuth key for Anthropic (today it checks it for every provider).

**Files:**
- Modify: `src/Seal/Command/Provider.hs`
- Test: `test/Seal/Command/ProviderSpec.hs`

**Interfaces:**
- Consumes: `providerLabel`, `vaultKeyName`, `updateFileConfig`, `ccPrompt`, `ccPromptSecret`, `fcOllamaBaseUrl`.
- Produces: no new exports; behavioral change to `addCmd` and `listCmd` for the `ollama` label.

- [ ] **Step 1: Write the failing tests**

In `test/Seal/Command/ProviderSpec.hs`, add inside `describe "/provider commands"`:

```haskell
    it "add ollama saves the base url to config and stores a key when given" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfgPath (Just vh)
        -- scripted answers: base url (ccPrompt) then key (ccPromptSecret)
        (_, caps) <- makeFakeCaps ["https://ollama.com", "k-cloud"]
        runProv pr ["add", "ollama"] caps
        vhGet vh "OLLAMA_API_KEY" >>= (`shouldBe` Right ("k-cloud" :: ByteString))
        Right cfg <- loadFileConfig cfgPath
        fcOllamaBaseUrl cfg `shouldBe` Just "https://ollama.com"

    it "add ollama with a blank key configures local (no key stored)" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfgPath (Just vh)
        -- blank base url keeps the default; blank key => local
        (_, caps) <- makeFakeCaps ["", ""]
        runProv pr ["add", "ollama"] caps
        vhGet vh "OLLAMA_API_KEY" >>= (`shouldSatisfy` either (const True) (const False))

    it "list reports ollama as none (local) when no key is stored" $
      withSystemTempDirectory "seal-prov" $ \dir -> do
        let cfgPath = dir </> "config.toml"
        vh <- makeFakeVault []
        pr <- mkPR cfgPath (Just vh)
        (fc, caps) <- makeFakeCaps []
        runProv pr ["list"] caps
        out <- getSent fc
        T.unlines out `shouldSatisfy` ("ollama" `T.isInfixOf`)
        T.unlines out `shouldSatisfy` ("local" `T.isInfixOf`)
```

Add `fcOllamaBaseUrl` to the `Seal.Config.File (FileConfig (..), loadFileConfig)` import in the spec (already imports `FileConfig (..)`, which exports the accessor).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cabal test --test-options='--match "ollama"'`
Expected: FAIL — `add ollama` currently prompts only for a secret (queue exhausted or wrong key name), and `list` prints generic `none`.

- [ ] **Step 3: Special-case Ollama in `addCmd` and `listCmd`**

In `src/Seal/Command/Provider.hs`, replace `addCmd` with a version that branches on the label. Keep the existing Anthropic path intact:

```haskell
addCmd :: ProviderRuntime -> Text -> CommandAction
addCmd pr lbl = CommandAction $ \caps ->
  withProvider caps lbl $ \kp ->
    withVaultHandle pr caps $ \vh ->
      if providerLabel kp == "ollama"
        then addOllama pr caps vh kp
        else do
          val <- ccPromptSecret caps ("API key for " <> providerLabel kp <> ": ")
          res <- vhPut vh (vaultKeyName kp) (TE.encodeUtf8 val)
          case res of
            Left e   -> ccSend caps (vaultErrText e)
            Right () -> do
              _ <- updateFileConfig (prConfigPath pr) (seedDefaults kp)
              ccSend caps ("Stored API key for " <> providerLabel kp <> ".")
  where
    seedDefaults kp fc = fc
      { fcDefaultProvider = fcDefaultProvider fc <|> Just (providerLabel kp)
      , fcDefaultModel    = fcDefaultModel fc    <|> Just (modelText (defaultModelFor kp))
      }

-- | Ollama onboarding: prompt for the base URL (blank keeps the default),
-- persist it to config, then prompt for an optional API key (blank => local,
-- nothing stored). Seeds provider/model defaults like the generic path.
addOllama :: ProviderRuntime -> ChannelCaps -> VaultHandle -> KnownProvider -> IO ()
addOllama pr caps vh kp = do
  urlIn <- ccPrompt caps
             ("Ollama base URL [" <> defaultOllamaBaseUrl <> "] (blank = default): ")
  let mUrl = if T.null (T.strip urlIn) then Nothing else Just (T.strip urlIn)
  keyIn <- ccPromptSecret caps "Ollama API key (blank for local): "
  keyRes <-
    if T.null keyIn
      then pure (Right ())
      else vhPut vh (vaultKeyName kp) (TE.encodeUtf8 keyIn)
  case keyRes of
    Left e   -> ccSend caps (vaultErrText e)
    Right () -> do
      _ <- updateFileConfig (prConfigPath pr) (seedAll mUrl)
      ccSend caps
        ("Configured ollama"
          <> maybe " (local)" (const "") mUrl'
          <> ".")
  where
    mUrl' = Nothing :: Maybe ()  -- placeholder to keep the message simple; see note
    seedAll mUrl fc = fc
      { fcDefaultProvider = fcDefaultProvider fc <|> Just (providerLabel kp)
      , fcDefaultModel    = fcDefaultModel fc    <|> Just (modelText (defaultModelFor kp))
      , fcOllamaBaseUrl   = mUrl <|> fcOllamaBaseUrl fc
      }
```

Simplify the confirmation message (drop the `mUrl'` placeholder) to just:

```haskell
    Right () -> do
      _ <- updateFileConfig (prConfigPath pr) (seedAll mUrl)
      ccSend caps "Configured ollama."
```

and remove the `mUrl'` line from the `where`. (The two-line message variant above is illustrative; ship the single clear line.)

Add the needed imports at the top of the module:

```haskell
import Seal.Config.File (FileConfig (..), loadFileConfig, updateFileConfig)   -- add fcOllamaBaseUrl via FileConfig (..)
import Seal.Providers.Ollama (defaultOllamaBaseUrl)
import Seal.Channel.Caps (ChannelCaps (..))   -- already imported
import Seal.Security.Vault (VaultHandle, ...)  -- already imported; ensure VaultHandle is in scope
```

(`FileConfig (..)` already imported for `fcDefaultProvider`/`fcDefaultModel`; it also exports `fcOllamaBaseUrl`. Add only `Seal.Providers.Ollama (defaultOllamaBaseUrl)`.)

Now update `reportOne` inside `listCmd` so Ollama reports local status and the Anthropic OAuth key is only consulted for Anthropic:

```haskell
    reportOne caps vh def kp = do
      eKey <- vhGet vh (vaultKeyName kp)
      auth <- authLabel caps vh kp eKey
      let mark = if Just (providerLabel kp) == def then " (default)" else ""
      ccSend caps (providerLabel kp <> mark <> " — " <> auth)

    authLabel _ vh kp eKey
      | providerLabel kp == "ollama" =
          pure $ case eKey of
            Right _               -> "auth: api-key"
            Left VaultLocked      -> "auth: (vault locked)"
            _                     -> "auth: none (local)"
      | otherwise = do
          eOAuth <- vhGet vh anthropicOAuthKey
          pure $ case (eOAuth, eKey) of
            (Right _, _)          -> "auth: oauth"
            (_, Right _)          -> "auth: api-key"
            (Left VaultLocked, _) -> "auth: (vault locked)"
            _                     -> "auth: none"
```

(`VaultLocked` is already imported via `Seal.Security.Vault.Age (VaultError (..))`. The `caps` param of `authLabel` is unused — drop it and call `authLabel vh kp eKey`, or prefix `_caps`; simplest is to not pass it.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cabal build all && cabal test --test-options='--match "ollama"'`
Expected: PASS — the three new Ollama command examples green.

Confirm no Anthropic regression:

Run: `cabal test --test-options='--match "/provider commands"'`
Expected: PASS (Anthropic add/list/remove unchanged).

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Command/Provider.hs test/Seal/Command/ProviderSpec.hs
git commit -m "feat(provider): ollama add flow (base url + optional key) and local list status"
```

---

### Task 7: Provider-aware session default model

Fix a latent bug flagged by the M2 whole-branch review (M3-earmarked): `defaultSessionSelection` in `Seal.Session.Store` hardcodes the model fallback to `defaultModelFor AnthropicProvider` regardless of the configured provider, so a config with `default_provider = "ollama"` and no `default_model` starts a session as `("ollama", "claude-opus-4-8")`. Fall back to `defaultModelFor` of the **parsed** provider instead.

**Files:**
- Modify: `src/Seal/Session/Store.hs`
- Test: `test/Seal/Session/StoreSpec.hs`

**Interfaces:**
- Consumes: `parseProvider`, `defaultModelFor` (Registry — the latter already imported; add `parseProvider`).
- Produces: `defaultSessionSelection :: FileConfig -> (Text, Text)` (signature unchanged; behavior now provider-aware).

- [ ] **Step 1: Write the failing test**

In `test/Seal/Session/StoreSpec.hs`, add to the `defaultSessionSelection` describe block (create it if absent, importing `defaultSessionSelection` and `Seal.Config.File (defaultFileConfig, FileConfig (..))`):

```haskell
  describe "defaultSessionSelection" $ do
    it "uses the parsed provider's default model when no model is configured" $ do
      let cfg = defaultFileConfig { fcDefaultProvider = Just "ollama" }
      defaultSessionSelection cfg `shouldBe` ("ollama", "llama3.2")

    it "keeps an explicitly configured model" $ do
      let cfg = defaultFileConfig
                  { fcDefaultProvider = Just "ollama"
                  , fcDefaultModel    = Just "qwen3" }
      defaultSessionSelection cfg `shouldBe` ("ollama", "qwen3")

    it "falls back to anthropic + its model when nothing is configured" $
      defaultSessionSelection defaultFileConfig `shouldBe` ("anthropic", "claude-opus-4-8")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cabal test --test-options='--match "defaultSessionSelection"'`
Expected: FAIL — the first example gets `("ollama", "claude-opus-4-8")`.

- [ ] **Step 3: Make the fallback provider-aware**

In `src/Seal/Session/Store.hs`, add `parseProvider` to the Registry import, and rewrite `defaultSessionSelection`:

```haskell
-- | The provider label + model a new session should start with: the configured
-- defaults, falling back to the configured provider's own default model (or
-- Anthropic when no provider is configured).
defaultSessionSelection :: FileConfig -> (Text, Text)
defaultSessionSelection cfg =
  ( provLabel
  , fromMaybe fallbackModel (fcDefaultModel cfg) )
  where
    provLabel = fromMaybe "anthropic" (fcDefaultProvider cfg)
    ModelId fallbackModel =
      maybe (defaultModelFor AnthropicProvider) defaultModelFor (parseProvider provLabel)
```

Confirm `AnthropicProvider` and `KnownProvider (..)` are already imported (they are — `import Seal.Providers.Registry (KnownProvider (..), defaultModelFor)`); add `parseProvider` to that import list.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cabal test --test-options='--match "defaultSessionSelection"'`
Expected: PASS (all three examples).

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Session/Store.hs test/Seal/Session/StoreSpec.hs
git commit -m "fix(session): default model follows the configured provider"
```

---

### Task 8: Full-suite verification + docs

Confirm the whole suite is green and the build is `-Werror` clean end-to-end, and record the milestone.

**Files:**
- Modify: `README.md` (or the Phase 3 status note, if one exists) — optional one-line status update.

- [ ] **Step 1: Run the entire suite and a clean build**

Run: `cabal build all && cabal test`
Expected: all examples pass; Ollama live example reported `pending`; zero warnings (`-Werror`). If `hlint` is part of the repo's gate (see CONTRIBUTING), also run: `hlint src/ test/` and fix any hints in the new module.

- [ ] **Step 2: Manual smoke (optional, needs a local Ollama)**

If `ollama serve` is available locally with a model pulled (e.g. `ollama pull llama3.2`):

```
cabal run seal
# in the REPL:
/vault unlock
/model use ollama llama3.2
hello, who are you?
/provider test ollama
```

Expected: the chat turn returns text from the local model; `/provider test ollama` reports OK. (This is manual verification, not a gate.)

- [ ] **Step 3: Update the status note (optional)**

If `README.md` or a phase-status doc tracks milestone completion, add a line noting M3 (Ollama provider) is implemented.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore(ollama): finalize M3 — full suite green"
```

---

## Self-Review

**Spec coverage** (design → task):
- `Seal.Providers.Ollama` module (type, `complete`, `listModels`, pure codec split) → Tasks 2–4. ✅
- Full tool support (encode tool defs, decode tool_calls with synthesized ids, tool-result flattening) → Task 2 (encode) + Task 3 (decode). ✅
- One `ollama` provider, optional key, local vs cloud by base URL + key presence → Task 5 (`resolveProvider` Ollama clause) + Task 6 (add flow). ✅
- `/provider add|list|test ollama` graceful optional-credential handling → Task 5 (`test` base_url + optional key resolution) + Task 6 (`add` two-step, `list` local status). ✅
- `/model use ollama <name>` end-to-end → Task 5 (auto via `parseProvider`/`knownProviders`; no extra code). ✅
- Config `ollama_base_url` flat field → Task 1. ✅
- Registry totality extensions (`providerLabel`/`vaultKeyName`/`defaultModelFor`) → Task 5. ✅
- Endpoints `/api/chat` + `/api/tags`, base-URL join → Tasks 2 (URLs) + 4 (round-trip). ✅
- Key-safe errors (connection hint, 401, generic) → Task 3 + used in Task 4. ✅
- `max_tokens → options.num_predict` → Task 2 `encodeRequest`. ✅
- Provider-aware session default model (M2-review M3 note) → Task 7. ✅
- Zero-vault local Ollama → documented non-goal (spec); not implemented in M3. ✅ (out of scope)
- Testing: pure codec round-trips, registry resolution (local/cloud/locked), config parse, `/provider` command tests, pending live test → Tasks 1–6. ✅
- Non-goals (streaming, embeddings, `[providers.*]` tables, two entries, OAuth) → not introduced. ✅

**Placeholder scan:** The only intentional interim stubs are the three Task-2 `decodeResponse`/`ollamaErrorText`/`unreachableMsg` definitions, explicitly replaced wholesale in Task 3. The `addOllama` message includes an illustrative `mUrl'` placeholder that Step 3 explicitly instructs to delete in favor of the single-line `"Configured ollama."`. No other TBD/TODO/"handle edge cases".

**Type consistency:** `resolveProvider` has the same 5-arg signature (`VaultHandle -> Manager -> Text -> KnownProvider -> ModelId -> IO (Either Text SomeProvider)`) in Task 5's definition, all four updated Anthropic test calls, both non-test call sites, and the three new Ollama tests. `mkOllama :: Manager -> Text -> Maybe ApiKey -> ModelId -> Ollama` is defined in Task 2 and called identically in Task 5. `fcOllamaBaseUrl :: Maybe Text` defined Task 1, read in Tasks 5/6. Field/accessor names (`olBaseUrl`, `olApiKey`, `olManager`, `olModel`) are consistent across Tasks 2 and 4. Synthesized tool-call ids use `"call_<i>"` in both the encode example expectations and the decode implementation.
