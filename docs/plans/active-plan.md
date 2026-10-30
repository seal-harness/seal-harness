# Active Plan
<!-- approved: 2026-10-27T00:00:00Z -->
<!-- gate-iterations: 2 -->
<!-- user-approved: true -->
<!-- status: complete -->

# OpenAI-compat content wire format: reactive auto-detect + config override

Supersedes (after completion): #271 step 3 provider families —
`docs/superpowers/plans/2026-10-19-provider-families-plan.md` (done).

**Goal:** Replace the blanket always-string content encoding (the fix for
strict local servers like Magnitude rejecting content-part arrays) with a
reactive auto-detect: send the library-normal content-part array form by
default; when a server proves it only accepts plain-string content (the
distinctive serde 400), transparently retry once with strings and remember
the downgrade per provider endpoint for the process lifetime; never send the
string form to a server that accepts the normal form. A per-instance
`content_style` config field (`auto` | `parts` | `string`, default `auto`)
overrides detection.

**Architecture:** The `openai` package's `CreateChatCompletion` type forces
`content` into content-part arrays. `OpenAICompat` gains a two-level format
model: a configured **policy** (`ContentStyle`, from the provider instance's
config) and the per-call **wire format** (`WireFormat`). Policy `auto` starts
at `WireParts` and consults a process-lifetime memo (an `IORef (M.Map Text
WireFormat)` keyed by canonical base URL — one entry per *endpoint*, so two
instances pointing at the same server share a decision; that is correct, it
is the same server) threaded the same way Ollama's `callCounter` is. Because
`resolveInstance` rebuilds provider values every turn (TurnEngine.hs:545 →
`resolveSessionProvider` → fresh value), the memo must live above
resolution, in `ProviderRuntime`. On an HTTP 400 whose body matches the
strict-server signature (`invalid type: sequence, expected a string`
mentioning `messages`), an `auto` provider retries the identical request
once with `WireString` and memoizes; `parts` never downgrades; `string`
always sends strings. Explicit styles never consult the memo.

**Tech Stack:** Haskell (GHC2021), `aeson`, `http-client`, `tomland`,
`hspec` + `QuickCheck`, loopback `warp` mocks for wire tests.

## Global Constraints

- `-Wall -Werror` clean; strict fields; `Text` not `String`; `atomicModifyIORef'`
  for the memo; no partial functions; no comments beyond house-style Haddock.
- Secrets never surface (unchanged by this plan; the downgrade path reuses
  `chatHeaders` verbatim — key bytes never leave the `withApiKey` continuation).
- Wire tests use the loopback warp mock only — no DNS, no egress, no real keys.
- **Every task ends green** (`cabal build all` + full test suite pass). A
  shared-signature change and all of its callers update in the SAME task —
  no task may leave the library or test suite uncompilable. Task 4 is the
  single signature-change wave; Tasks 1–3 are purely additive.
- Focused test run (note: the wire spec's top-level describe is
  `"wire behaviour (loopback warp mock)"`, so `--match=OpenAICompat` misses
  it; run the full suite for final verification):
  `nix develop --command cabal test test:tests --test-options="--match=OpenAICompat"`
  for pure tests, then `make check`.

---

### Task 1: OpenAICompat — pure format model (no signature changes)

Purely additive: new types and functions, zero edits to existing signatures,
so the tree stays green with no caller updates.

**Files:**
- Modify: `src/Seal/Providers/OpenAICompat.hs`
- Modify: `test/Seal/Providers/OpenAICompatSpec.hs`

**Interfaces (all exported; the existing `encodeRequestBody` is kept
untouched — Task 4 subsumes it into `wireBody`):**
- `data ContentStyle = StyleAuto | StyleParts | StyleString` — the configured
  policy. `deriving stock (Eq, Show)`.
- `data WireFormat = WireParts | WireString` — what goes on the wire this call.
- `parseContentStyle :: Text -> Maybe ContentStyle` — case-sensitive on
  exactly `auto` / `parts` / `string`; `Nothing` otherwise.
- `wantsStringContent :: Text -> Bool` — the strict-server 400 signature:
  body contains `invalid type: sequence, expected a string` **and** mentions
  `messages` (guards against tools-shape errors). Narrow by design: the
  config override covers unlisted phrasings; the phrase list may grow later.
- `effectiveWireFormat :: ContentStyle -> IORef (M.Map Text WireFormat) -> Text -> IO WireFormat`
  — `Parts`→`WireParts`, `String`→`WireString`, `Auto`→memo lookup at the
  base URL, defaulting to `WireParts`.
- `wireBody :: WireFormat -> Chat.CreateChatCompletion -> BL.ByteString` —
  `WireParts` → `encode` (the openai package default); `WireString` → the
  existing compaction (`encode . compactMessages . toJSON`, i.e. today's
  `encodeRequestBody`).

**TDD steps:**

- [ ] Failing tests first, in `OpenAICompatSpec.hs` (pure only in this task):
  - `parseContentStyle`: the three keywords round-trip; `AUTO`, `auto ` and
    garbage yield `Nothing`.
  - `wantsStringContent`: Magnitude's verbatim 400 body → `True`; a 400 body
    about `tools` → `False`; a body missing `messages` → `False`.
  - `effectiveWireFormat`: fixed styles bypass the memo; `Auto` defaults to
    `WireParts`; `Auto` with a memo hit returns `WireString`.
  - `wireBody`: `WireParts` emits part arrays; `WireString` emits strings
    (mirror the existing `encodeRequestBody` assertions).
- [ ] Run focused suite — expect "not in scope" compile failure, then red
  tests, then implement until green. Full suite green at task end.

### Task 2: Config — the `content_style` field

**Files:**
- Modify: `src/Seal/Config/File.hs`
- Modify: `test/Seal/Config/FileSpec.hs`
- Modify (record-literal totality only): every file whose `ProviderConfig`
  literal the compiler flags — at minimum `test/Seal/Providers/RegistrySpec.hs`
  (the `sec ty url model = ProviderConfig { ... }` helper, ~line 107) and any
  other literal found by grepping `ProviderConfig {`.

**Interfaces:**
- `pcContentStyle :: Maybe Text` on `ProviderConfig` (TOML key
  `content_style`, per-instance: `[providers.<name>] content_style = "..."`).
  Read by the OpenAI-compatible family; ignored by other families (same
  contract as `base_url` on built-in-URL rows).

**TDD steps:**

- [ ] Failing tests: `ProviderConfig` parse + save/load round-trip for
  `content_style`; absent key decodes as `Nothing`.
- [ ] Add the field + codec line; update every `ProviderConfig` record
  literal the `-Wmissing-fields` errors enumerate (grep first: `rg -n
  'ProviderConfig \{' src/ test/`). Full suite green at task end.

### Task 3: Registry — row-level validation (no resolution changes yet)

Validates and surfaces the style on the instance row; resolution does not
consume it yet, so no signature changes and the tree stays green.

**Files:**
- Modify: `src/Seal/Providers/Registry.hs`
- Modify: `test/Seal/Providers/RegistrySpec.hs`

**Interfaces:**
- `ProviderInstance` gains `piContentStyle :: !(Either Text ContentStyle)` —
  `Right` parsed from `pcContentStyle` (`Nothing` ⇒ `Right StyleAuto`);
  `Left` carries the problem text for an invalid value. Surfaced through
  `piProblem` (row unusable, shown in list) — mirroring unknown-type
  handling (`rowFromSection`'s problem composition, and
  `instanceCredentials`/`resolveInstance`'s existing refusal of problem
  rows). Task 4 adds the explicit resolve-time refusal.

**TDD steps:**

- [ ] Failing tests: a section with `content_style = "string"` produces a
  problem-free row; `content_style = "sometimes"` produces a `piProblem`
  naming the valid values; absent style yields `Right StyleAuto`.
- [ ] Implement: parse in `rowFromSection`, fold the style problem into
  `piProblem`. Update the `ProviderInstance` record literals in the spec
  (compile-enumerated). Full suite green at task end.

### Task 4: The signature wave — memo threading + reactive downgrade

One atomic task: every shared-signature change and every caller, src and
test, updates together.

**Files:**
- Modify: `src/Seal/Providers/OpenAICompat.hs` —
  - `OpenAICompat` gains `oacContentStyle :: !ContentStyle` and
    `oacContentMemo :: !(IORef (M.Map Text WireFormat))`.
  - `mkOpenAICompat :: Manager -> Maybe ApiKey -> Text -> ModelId -> OpenAICompatSpec -> ContentStyle -> IORef (M.Map Text WireFormat) -> OpenAICompat`.
  - `sendChatCompletion :: Manager -> OpenAICompatSpec -> Text -> Maybe ApiKey -> ContentStyle -> IORef (M.Map Text WireFormat) -> Chat.CreateChatCompletion -> IO (Either Text CompletionResponse)`
    — resolves the format via `effectiveWireFormat`, POSTs `wireBody fmt req`,
    and on (400 ∧ `wantsStringContent` body ∧ `WireParts` ∧ `StyleAuto`)
    memoizes `baseUrl → WireString` via `atomicModifyIORef'` and re-POSTs
    once with strings; returns the retry's result (if the retry also fails,
    its error is what surfaces). `complete` passes the instance's style and
    memo through.
  - `encodeRequestBody` is subsumed by `wireBody` and removed.
- Modify: `src/Seal/Providers/Registry.hs` — `resolveInstance` and
  `resolveOpenAIInstance` gain the memo param; `resolveOpenAIInstance`
  reads `piContentStyle`, refuses on `Left` before dispatch, and passes
  style + memo to `mkOpenAICompat`.
- Modify: `src/Seal/Command/Provider.hs` — `ProviderRuntime` gains
  `prContentMemo :: IORef (M.Map Text WireFormat)`; pass it at all three
  `resolveInstance` call sites (`resolveSessionProvider`,
  `resolveDefProvider`, `testCmd`).
- Modify: `src/Seal/Command/Model.hs` — 2 `resolveInstance` call sites.
- Modify: `src/Seal/Command/Serve.hs`, `src/Seal/Tui.hs` — construct the
  memo once at boot beside `prCallCounter`.
- Modify (compile-forced, one-line field additions / arg additions):
  `test/Seal/Providers/OpenAICompatSpec.hs` (9 call sites: 1
  `sendChatCompletion` at ~line 419; 8 `mkOpenAICompat` at ~lines 425, 436,
  442, 488, 501, 519, 532, 549 — the existing wire assertions pass
  `StyleString`, preserving the prior fix's behavior),
  `test/Seal/Providers/RegistrySpec.hs` (6 `resolveInstance` calls at
  ~lines 338, 346, 349, 361, 362, 373),
  `test/Seal/TestHelpers/ApiTestHarness.hs` (×1), `test/Seal/Channel/CliSpec.hs`
  (×2), `test/Seal/Command/SessionSpec.hs` (×1), `test/Seal/Command/ModelSpec.hs`
  (×2), `test/Seal/Command/ProviderSpec.hs` (×1), `test/Seal/Gateway/ApiSpec.hs`
  (×4), `test/Seal/Gateway/SendSpec.hs` (×1).

**TDD steps:**

- [ ] Write the failing wire-level tests FIRST (they reference the new
  signatures, so red = compile failure):
  - Strict mock: first POST (parts) → 400 serde body; the retry (string) →
    200 canned; `complete` returns `Right`; the mock saw two POSTs, the
    second with string content. A second `complete` sends exactly one POST
    (string) — the memo held. A fresh `resolveInstance`-built provider
    (simulating the next turn) also sends exactly one POST — the memo
    survives across provider values.
  - `StyleParts` against the strict mock surfaces the 400 text, no retry
    (one POST). `StyleString` sends one string POST, no downgrade needed.
  - Concurrent duplicate probe is benign: two threads racing before the
    memo is set may each pay one 400+retry; both set the same value
    (assert the memo converges; no crash, no lost update).
- [ ] Implement the whole wave; update every call site the compiler
  enumerates; full suite green at task end.

### Task 5: End-to-end verification

- [ ] Full `make check` (build `-Werror`, all examples, `hlint` No hints).
- [ ] Wire-level warp tests (Task 4) are the authoritative machine-checked
  verification of the reactive behavior — they assert exactly: parts by
  default, one 400 + one retry on a strict server, memoized strings
  thereafter, parts never downgraded, strings never downgraded-from.
- [ ] Manual smoke (user, local Magnitude), observed on the **server side**
  (Magnitude's own request log visibly printed the original 400; Seal's
  `requests.jsonl` debug file logs the pre-encoding `CompletionRequest`
  only — it shows one request per turn in both modes and is NOT a channel
  for wire-format observation): fresh process, send a message — Magnitude's
  log shows one 400 then 200s; subsequent turns show no further 400s; the
  stock `openrouter` row continues to receive part arrays (visible in a
  proxy or the server's log if desired).
- [ ] Known limitation, stated honestly: the downgrade itself emits no log
  line — the provider layer has no logger handle (OpenAICompat deliberately
  imports nothing logger-shaped; its security-posture header lists its
  imports). Adding an observability channel for format downgrades is a
  separate, explicit decision if the manual smoke proves insufficient.

## Out of scope (explicit)

- Persisting the detected format to config (restarts re-probe once per
  process — acceptable; can be added later as a write-back).
- Provider-editor UI flags for `content_style` (hand-editable TOML for now).
- Broadening the trigger beyond the serde phrase (config override covers
  unlisted servers).
- A provider-layer log channel for the downgrade event (see Task 5's known
  limitation).