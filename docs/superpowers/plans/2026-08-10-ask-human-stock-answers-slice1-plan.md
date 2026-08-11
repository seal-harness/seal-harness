# Implementation Plan: ASK_HUMAN Stock Answers (Slice 1 — Web)

**Issue**: https://github.com/seal-harness/seal-harness/issues/91
**Design**: `docs/superpowers/specs/2026-08-10-ask-human-stock-answers-design.md` (rev 2, gate-approved)
**Branch**: `feat/ask-human-stock-answers` (already created; design doc + roadmap + issue-ref commits on it)
**Tooling**: cabal + Nix (`make`); tests = hspec + QuickCheck; lint = hlint; gate = `make check` + `cd frontend && npm test`; frontend = Vite + Vitest.
**User directive**: proceed without stopping at user gates; the scheduled checkpoint (after W7, before PR) is self-reviewed adversarially.

This plan covers **Slice 1 (Web)** only. Slices 2 (generic chat) and 3 (Telegram) get their own plans after Slice 1 ships.

## Plan-gate iteration history

- **Iteration 1**: Feasibility FAIL, Completeness FAIL (AC9 Vitest), Scope FAIL. All 3 blockers traced to the codebase (verified by grep):
  1. **W3 missed 16 production `ccPrompt` call sites** — the design's rev 2 §4.3 claimed `Seal.Vault.Commands`/`Seal.Command.Provider` only call `ccPromptSecret` (unchanged); grep proved they ALSO call `ccPrompt` at 16 sites (`Vault.Backend:197,218,219`, `Vault.Commands:168,190,195,197`, `Command.Provider:178,266`, `Command.Channel:249,300,324,335,350,356,459`). `cabal build all` would fail. **Fix (rev 2)**: enumerate all 16 in W3 file scope; each `ccPrompt caps "x"` → `ccPrompt caps (AskPrompt "x" [])` (mechanical wrap).
  2. **W3 missed 3 breaking test helpers** — `test/Seal/Agent/LoopSpec.hs:439,479,519,560` (`\q -> modifyIORef' prompts (++ [q])` — `q` becomes `AskPrompt`, capture `apQuestion q`); `test/Seal/Phase2aSpec.hs:64` (`fmap (fromRight "") . chPrompt h` — composition breaks on arity); `test/Seal/TestHelpers/FakeCaps.hs` (iteration-2: `pop` shared lambda — see below). **Fix (rev 2)**: enumerate in W3 file scope.
  3. **W3 spurious entries** — `Seal.Channels.Telegram.Run` has NO `ccPrompt` closure (delegates to `mkHandleCaps` in `Loop.hs` — already listed); `SendSpec`/`ApiSpec` `SendDeps` literals don't override `ccPrompt` (`SendDeps` has no `ChannelCaps` field). **Fix (rev 2)**: removed.
  4. **W3 commit shape misleading** — "migrate one by one, `cabal build` after each" is wrong (build stays red until ALL sites migrate). **Fix (rev 2)**: W3 is one red commit (arity change) + one green commit (all sites).
  5. **W8 "oldest-unmatched" needs `MessageBlock` change** — `matchesToolCall` is a pure `(pq, tc) -> boolean`; `.find()` (ChatArea.tsx:866) picks the first match, so ≥2 ASK_HUMAN tool calls both match the same question. **Fix (rev 2)**: W8 also changes `MessageBlock`'s `.find()` to track already-matched question IDs.
  6. **W9 `make check` doesn't run Vitest** — `Makefile:30` `check: build test lint` = cabal only; frontend tests are `npm test` in `frontend/`. AC9's "Vitest green" is not covered. **Fix (rev 2)**: W9 DoD adds explicit `cd frontend && npm test` step.
  7. **W2 deconstruction count** — plan said 11, design §9 lists 12 line numbers. **Fix (rev 2 → iteration 2)**: recount — the real code-change sites are 2 (line 24-27 `firstPending` helper + line 236 `map`), not 12; the `let (qid, _) = firstPending ps` sites need no change. Updated W2 DoD + file scope + risks.

- **Iteration 2**: Feasibility FAIL (`FakeCaps.pop` shared-lambda blocker), Scope FAIL (W2 count propagation), Completeness PASS.
  1. **`FakeCaps.pop` shared-lambda BLOCKER (Feasibility)** — iteration-1 claimed `pop _prompt` "compiles unchanged because `_` is arity-polymorphic." WRONG: `pop` (FakeCaps.hs:29) is a single monomorphic lambda assigned to BOTH `ccPrompt` (arity → `AskPrompt -> IO Text`) and `ccPromptSecret` (stays `Text -> IO Text`). A single lambda can't satisfy both argument types. **Fix (rev 3)**: W3 file scope adds `FakeCaps.hs` with an explicit edit — split `pop` into two lambdas (`popPrompt (AskPrompt _ _) = …` for `ccPrompt`, `popSecret _prompt = …` for `ccPromptSecret`); bodies identical (both pop the queue). Removed the "no edit expected" claim.
  2. **W3 count "13" → 16 (Feasibility/Scope)** — the enumeration (3+4+2+7=16) was always complete; the "13" label was a stale miscount. **Fix (rev 3)**: W3 DoD + file scope now say "16 production sites."
  3. **W2 count propagation (Scope)** — the DoD was updated to the correct count but the file scope (line 62) + risks (line 305) still said "11." **Fix (rev 3)**: both updated to "2 deconstruction sites" (the accurate count).

## Work units

### W1 — `QuestionOption` type + validation + JSON instances (pure, no IO)

**DoD:**
- `QuestionOption` record in `Seal.Handles.AskReply` with `qoLabel :: !Text`, `qoDescription :: !Text`, strict fields, `deriving stock (Eq, Show, Generic)`.
- `ToJSON`/`FromJSON` instances via `Generic` (field prefix `qo` stripped → JSON keys `label`/`description`).
- `validateOptions :: [QuestionOption] -> Either Text [QuestionOption]` — pure validator: 1 ≤ length ≤ 8; each `qoLabel` non-empty + ≤ 64 bytes (`BS.length . TE.encodeUtf8`); each `qoDescription` ≤ 200 chars; labels unique (case-sensitive).
- QuickCheck generator `genOptions :: Gen [QuestionOption]` bounded 1-8 elements, labels from a small alphabet (e.g. `["main","develop","release","hotfix","next","v1","v2","other"]`), descriptions from a bounded string generator.
- QuickCheck property: `forAll genOptions $ \opts -> validateOptions opts == Right opts` (valid inputs pass).
- QuickCheck property: empty list → `Left`; >8 elements → `Left`; empty label → `Left`; label >64 bytes → `Left`; duplicate labels → `Left`; description >200 chars → `Left`.

**File scope:**
- `src/Seal/Handles/AskReply.hs` — add `QuestionOption`, instances, `validateOptions`; export from module header.
- `test/Seal/Handles/AskReplySpec.hs` — add `describe "QuestionOption validation"` with the QuickCheck properties; import `QuestionOption`, `validateOptions`.

**Test first (red):** write the validation QuickCheck properties in `AskReplySpec.hs` before implementing `QuestionOption`/`validateOptions`. Watch them fail to compile. Commit the failing test. Implement. Watch pass. Commit.

---

### W2 — `PendingAsk.paOptions` + `askHumanWithOptions` + `PendingQuestionInfo` + `pendingForSession` reshape

**DoD:**
- `PendingAsk` gains `paOptions :: ![QuestionOption]` (strict field).
- `askHumanWithOptions :: AskReplyStore -> SessionId -> Text -> [QuestionOption] -> (AskId -> IO ()) -> IO (Either AskOutcome Text)` — the new constructor; sets `paOptions`.
- `askHuman` and `askHumanWithMeta` delegate to the core with `paOptions = []` (their signatures unchanged).
- `PendingQuestionInfo` record (as in design §4.2) with `pqiId`/`pqiSession`/`pqiQuestion`/`pqiCreatedAt`/`pqiMeta`/`pqiOptions`.
- `pendingForSession :: AskReplyStore -> SessionId -> IO [PendingQuestionInfo]` (return type reshaped from the 4-tuple).
- **Migrate the `pendingForSession` deconstruction sites in `test/Seal/Handles/AskReplySpec.hs`** (gate-plan correction: the real code-change sites are 2, not 12 — the iteration-1 count conflated call sites with deconstructions):
  - **Line 24-27: the `firstPending` helper definition** — `firstPending :: [(a, Text, b, c)] -> (a, Text)` + `Just ((qid, q, _, _), _)` pattern. This is the primary migration target: its signature becomes `[PendingQuestionInfo] -> (AskId, Text)` (or it's removed in favor of direct `pqiId`/`pqiQuestion` accessors — implementer's choice). Once `firstPending`'s signature changes, the `let (qid, question) = firstPending ps` / `let (qid, _) = firstPending ps` call sites (lines 50, 83, 111, 125, 252, 266) deconstruct the `(AskId, Text)` return and need **no change** (they don't touch the 4-tuple).
  - **Line 236: `map (\(_, q, _, _) -> q) ps`** — a direct 4-tuple deconstruction NOT via `firstPending`. This MUST change to `map (\info -> pqiQuestion info) ps` (or `map pqiQuestion ps`).
  - The `ps <- pendingForSession store sid` bindings (lines 48, 82, 110, 124, 149, 156, 167, 209, 231, 251, 265) are call sites, not deconstructions — they bind the list and need no change (the return type changes from `[(a,b,c,d)]` to `[PendingQuestionInfo]` but the binding `ps <-` is polymorphic).
  - **Net: 2 code-change sites (lines 24-27 + line 236).** The compiler (`-Werror`) catches any miss.
- `handleListQuestions` in `Seal.Gateway.API` (line 1643) rewritten to deconstruct `PendingQuestionInfo` (not the 4-tuple).
- Existing tests (askHuman/deliverAnswer roundtrip, cancel, timeout, pendingForSession ordering) still pass with the new return shape.
- New test: `askHumanWithOptions` registers a pending ask with `pqiOptions` populated; `pendingForSession` returns them.

**File scope:**
- `src/Seal/Handles/AskReply.hs` — `paOptions` field; `askHumanWithOptions`; `PendingQuestionInfo`; `pendingForSession` reshape; export new names.
- `src/Seal/Gateway/API.hs` — `handleListQuestions` (line 1632) + `questionJson` helper (line 1643) rewritten to `PendingQuestionInfo` accessors.
- `test/Seal/Handles/AskReplySpec.hs` — migrate 2 deconstruction sites (line 24-27 `firstPending` helper signature + line 236 `map (\(_, q, _, _) -> q) ps`); add `askHumanWithOptions` roundtrip test. (The `let (qid, _) = firstPending ps` call sites need no change — they deconstruct the `(AskId, Text)` return, not the 4-tuple.)

**Test first (red):** add the `askHumanWithOptions` roundtrip test (registers a pending ask with options, checks `pendingForSession` returns them) before implementing. It will fail to compile. Implement. Watch pass.

**Note:** the `handleListQuestions` rewrite does NOT yet add `options` to the JSON output (that's W6 — the API JSON shape change). W2 only migrates the deconstruction from the 4-tuple to the record. The JSON output stays `{id, question, createdAt, meta?}` until W6.

---

### W3 — `AskPrompt` type + `ccPrompt` arity change (option A)

**DoD:**
- `AskPrompt` record in `Seal.Channel.Caps` with `apQuestion :: !Text`, `apOptions :: ![QuestionOption]`, strict fields.
- `ChannelCaps.ccPrompt` signature changes from `Text -> IO Text` to `AskPrompt -> IO Text`.
- `Default` instance updated: `ccPrompt = \_ -> pure ""` (ignores the `AskPrompt` arg — same no-op).
- **All 5 channel `ccPrompt` closures migrated** to the new arity:
  - `Seal.Gateway.Send.webAskCaps` (Send.hs:984) — `ccPrompt` closure takes `AskPrompt`; destructures `apQuestion`/`apOptions`; passes `apOptions` to `askHumanWithOptions` (the WS broadcast of options is W6; for W3 the broadcast stays `{id, question}` — options are carried in `paOptions` but not yet in the WS event).
  - `Seal.Channels.Loop.mkHandleCaps` (Loop.hs:431) — `ccPrompt` closure takes `AskPrompt`; destructures; passes `apOptions` to `askHumanWithOptions` (numbered-list rendering is Slice 2; for W3 the notify just sends the question text via `chSend`).
  - `Seal.Channels.Signal.Run` (Signal.Run.hs:116) — same as `mkHandleCaps`.
  - `Seal.Channel.Cli` (Cli.hs:621) — `ccPrompt` closure updated.
  - (No `Seal.Channels.Telegram.Run` edit — it delegates to `mkHandleCaps` via `newChannelDeps`; covered by the `Loop.hs` entry above. Verified by grep: `Telegram/Run.hs` has no `ccPrompt` closure.)
- `Seal.ISA.Ops.Human.askHumanOp` `toRun` calls `ccPrompt caps (AskPrompt q opts)` (was `ccPrompt caps q`); `opts` parsed from the input `Value` (the `options` field — parsing in W4).
- `Seal.Agent.Loop.checkConfirmation` (Loop.hs:390) builds `AskPrompt (buildConfirmationPrompt opName' input') []` (the confirmation gate has no options).
- **16 production `ccPrompt caps "<prompt>"` call sites migrated** (gate-plan correction — these were missed in iteration 1; verified by grep). Each `ccPrompt caps "x"` → `ccPrompt caps (AskPrompt "x" [])` (mechanical arity wrap, no behavior change):
  - `Seal.Vault.Backend` (Vault/Backend.hs:197, 218, 219) — 3 sites.
  - `Seal.Vault.Commands` (Vault/Commands.hs:168, 190, 195, 197) — 4 sites.
  - `Seal.Command.Provider` (Provider.hs:178, 266) — 2 sites.
  - `Seal.Command.Channel` (Channel.hs:249, 300, 324, 335, 350, 356, 459) — 7 sites.
  - (The `ccPromptSecret` sites in these same modules are unchanged.)
- `cabal build all` green (`-Werror` clean) — the arity migration compiles across all 4 channel closures + the 16 production sites + the test helpers.

**File scope:**
- `src/Seal/Channel/Caps.hs` — `AskPrompt` type; `ccPrompt` arity change; `Default` instance.
- `src/Seal/Handles/AskReply.hs` — (no change; `QuestionOption` already imported by `Caps` via the `AskPrompt` field). **Verify:** `Caps` imports `QuestionOption` from `AskReply` — add the import.
- `src/Seal/ISA/Ops/Human.hs` — `toRun` builds `AskPrompt`; parses `options` from input (W4 completes the parsing).
- `src/Seal/Agent/Loop.hs` — `checkConfirmation` builds `AskPrompt`.
- `src/Seal/Gateway/Send.hs` — `webAskCaps.ccPrompt` arity.
- `src/Seal/Channels/Loop.hs` — `mkHandleCaps.ccPrompt` arity (covers Telegram too).
- `src/Seal/Channels/Signal/Run.hs` — `handleCaps.ccPrompt` arity.
- `src/Seal/Channel/Cli.hs` — `ccPrompt` arity.
- `src/Seal/Vault/Backend.hs` — 3 `ccPrompt` call sites (lines 197, 218, 219) wrapped in `AskPrompt … []`.
- `src/Seal/Vault/Commands.hs` — 4 `ccPrompt` call sites (lines 168, 190, 195, 197) wrapped.
- `src/Seal/Command/Provider.hs` — 2 `ccPrompt` call sites (lines 178, 266) wrapped.
- `src/Seal/Command/Channel.hs` — 7 `ccPrompt` call sites (lines 249, 300, 324, 335, 350, 356, 459) wrapped.
- **`test/Seal/TestHelpers/FakeCaps.hs` — BLOCKER (gate-plan iteration-2 fix):** `pop _prompt` (line 29) is a **single lambda shared between `ccPrompt` (arity → `AskPrompt -> IO Text`) and `ccPromptSecret` (stays `Text -> IO Text`)**. A single monomorphic lambda cannot satisfy both argument types — `cabal build` will fail. **Fix:** split `pop` into two lambdas: `popPrompt (AskPrompt _ _) = …` for `ccPrompt` (or `popPrompt _ = …` since the arg is ignored) and `popSecret _prompt = …` for `ccPromptSecret`. The body is identical (both pop the queue); only the argument type differs. (The iteration-1 claim that `pop _prompt` "compiles unchanged because `_` is arity-polymorphic" was wrong — `pop` is monomorphic and shared, so the `_` binds to one concrete type.)
- `test/Seal/ISA/Ops/HumanSpec.hs` — `fakeCaps.ccPrompt` arity (`\_ -> pure (pack reply)` — compiles unchanged, verify).
- `test/Seal/Agent/LoopSpec.hs` — 4 `ccPrompt` overrides (lines 439, 479, 519, 560: `\q -> modifyIORef' prompts (++ [q])` → `\ap -> modifyIORef' prompts (++ [apQuestion ap])`); the `readIORef prompts` assertions at 551/602 still pass (the captured text is the question, unchanged).
- `test/Seal/Phase2aSpec.hs` — line 64: `ccPrompt = fmap (fromRight "") . chPrompt h` — `chPrompt :: Text -> IO (Either Text Text)`; the composition breaks on the arity change. Adapt to `ccPrompt = \(AskPrompt q _) -> fmap (fromRight "") (chPrompt h q)`.
- (The ~10 other test files with `ccPrompt = \_ -> pure ""` compile unchanged — arity-polymorphic `_`. No edit.)

**Test first (red) / commit shape (gate-plan correction):** W3 is **one red commit + one green commit**, NOT per-channel:
1. **Red commit:** change `ccPrompt` arity in `Caps.hs` + add `AskPrompt` type. `cabal build all` breaks (type errors in the 4 channel closures + 16 production sites + 3 test helpers: FakeCaps + LoopSpec×4 + Phase2aSpec). Commit the failing build.
2. **Green commit:** migrate ALL ~18 call sites (4 channel closures + `askHumanOp` + `checkConfirmation` + 13 production prompts + 3 test helpers) in one commit. `cabal build all` green is the gate. (Splitting the green commit per-file would leave the build red between commits — every site must migrate before green.) Commit.

**Dependencies:** W1 (needs `QuestionOption` for `AskPrompt`), W2 (needs `askHumanWithOptions` for the closures).

---

### W4 — `ASK_HUMAN` schema + `toAuthorize` validation

**DoD:**
- `ASK_HUMAN.toInSchema` includes the optional `options` array (max 8, items `{label, description}`) per design §4.1.
- `toAuthorize` validates `question` (as today) **and** the optional `options` via `validateOptions` (W1). Absent `options` ⇒ `Right ()` (open-ended). Present + invalid ⇒ `Left`.
- `toRun` parses `options` from the input `Value` (aeson `parseMaybe` into `[QuestionOption]`); passes to `ccPrompt (AskPrompt q opts)`.
- `HumanSpec` tests:
  - `ASK_HUMAN` with `options` authorizes + runs; the `ccPrompt` closure receives the options (capture via an `IORef` in `fakeCaps`).
  - `ASK_HUMAN` without `options` still works (today's behavior).
  - `ASK_HUMAN` with invalid `options` (empty array, >8, empty label, label >64 bytes, duplicate labels) → `toAuthorize` returns `Left`.
  - `ASK_HUMAN` with valid `options` returns the human's reply (the `ccPrompt` closure returns the reply text).

**File scope:**
- `src/Seal/ISA/Ops/Human.hs` — `toInSchema` (add `options`); `toAuthorize` (validate `options`); `toRun` (parse `options`, build `AskPrompt`).
- `test/Seal/ISA/Ops/HumanSpec.hs` — add the 4 test cases above; update `fakeCaps` to capture the `AskPrompt` (e.g. `ccPrompt = \ap -> modifyIORef' captured (ap:[]) >> pure (pack reply)`).

**Test first (red):** write the 4 `HumanSpec` cases before implementing the schema/authorize changes. Watch them fail (the "with options" test fails because the schema doesn't accept `options`; the "invalid options" test fails because `toAuthorize` accepts everything). Implement. Watch pass.

**Dependencies:** W1 (`validateOptions`), W3 (`AskPrompt` + `ccPrompt` arity).

---

### W5 — Web `ccPrompt` broadcasts `options` in `BeAsk` event

**DoD:**
- `webAskCaps.ccPrompt` (Send.hs:984) closure: after `askHumanWithOptions`, the `notify` callback broadcasts `BeAsk sid` with the `options` field:
  ```haskell
  broadcast broker (BeAsk sid (object
    [ "id" .= askIdText qid
    , "question" .= q
    , "options" .= opts  -- NEW
    ]))
  ```
- `Seal.Gateway.Stream.sendEvent (BeAsk sid v)` unchanged (already forwards the whole `v`).
- Test (`SendSpec` or a new test): `webAskCaps.ccPrompt` with options broadcasts a `BeAsk` carrying `options`. (This may require a fake broker capture — check how `SendSpec` tests `BeAsk` today.)

**File scope:**
- `src/Seal/Gateway/Send.hs` — `webAskCaps.ccPrompt` notify callback (add `"options" .= opts`).
- `test/Seal/Gateway/SendSpec.hs` — add/extend a test asserting the `BeAsk` event carries `options`.

**Test first (red):** write the `SendSpec` test asserting the `BeAsk` event carries `options` before adding the `"options" .=` line. Watch it fail. Implement. Watch pass.

**Dependencies:** W2 (`askHumanWithOptions`), W3 (`ccPrompt` arity).

---

### W6 — `handleListQuestions` includes `options` + answer-route restructure (`parseAnswerBody` + `handleAnswerTextDelivery`)

**DoD:**
- `handleListQuestions` (API.hs:1632) `questionJson` helper includes `"options" .= pqiOptions info` (using the `PendingQuestionInfo` accessors from W2). The JSON output is now `{id, question, createdAt, meta?, options?}`.
- `parseAnswerBody :: BL.ByteString -> Either Text (Either ApprovalScope Text)` (new, in `Seal.Gateway.API` or `Seal.Gateway.Send` — decide based on where `parseScopeBody` lives). Explicit both-reject:
  - `{scope}` only → `Right (Left scope)` (after `parseApprovalScope`).
  - `{answer}` only → `Right (Right answerText)`.
  - both → `Left "ambiguous: send either {scope} or {answer}, not both"`.
  - neither → `Left "missing 'scope' or 'answer' field"`.
- `handleAnswerTextDelivery :: SendDeps -> SessionId -> Text -> AskId -> IO (Either Text Bool)` (new, in `Seal.Gateway.Send`) — builds `AskReply ScopeOnce answerText`; calls `deliverAnswer`; broadcasts `BeAskResolved`.
- The answer route handler (API.hs:269-283) restructured: calls `parseAnswerBody`; branches on `Right (Left scope)` → existing `handleAnswerDelivery`; `Right (Right answerText)` → new `handleAnswerTextDelivery`; `Left parseErr` → 400.
- `ApiSpec` tests:
  - `GET .../questions` includes `options` when present.
  - `POST .../answer` with `{answer: "main"}` delivers the text (`accepted: true`).
  - `POST .../answer` with `{scope: "once"}` still works (unchanged).
  - `POST .../answer` with `{scope: "once", answer: "main"}` → 400.
  - `POST .../answer` with `{}` → 400.

**File scope:**
- `src/Seal/Gateway/API.hs` — `handleListQuestions`/`questionJson` (add `options`); `parseAnswerBody` (new); answer-route handler restructure (line 269-283).
- `src/Seal/Gateway/Send.hs` — `handleAnswerTextDelivery` (new); export it.
- `test/Seal/Gateway/ApiSpec.hs` — the 5 test cases above.

**Test first (red):** write the 5 `ApiSpec` cases before implementing. Watch them fail. Implement. Watch pass.

**Dependencies:** W2 (`PendingQuestionInfo`), W5 (the WS broadcast — not strictly required for the API tests, but same slice).

---

### W7 — Frontend: `QuestionOption` type + `PendingQuestion.options` + WS `ask` handler fix + `AskEvent` type

**DoD:**
- `frontend/src/hooks/useApi.ts` — `QuestionOption` interface (`{label: string, description?: string}`); `PendingQuestion` gains `options?: QuestionOption[]` + `meta?: unknown`; `answerQuestionText(sessionId, qid, answer)` helper (POSTs `{answer}` to `.../questions/:qid/answer`).
- `frontend/src/lib/streamClient.ts` — `AskEvent` type extended with `options?: QuestionOption[]` + `meta?: unknown`.
- `frontend/src/hooks/useTranscriptStream.ts:148` — the WS `ask` handler spreads the full payload:
  ```ts
  return [...prev, {
    id: ask.id,
    question: ask.question,
    createdAt: new Date().toISOString(),
    options: ask.options,
    meta: ask.meta,
  }]
  ```
  (NOT just `{id, question, createdAt}`).
- Vitest: a test asserting the WS `ask` event with `options` populates `pendingQuestions` with `options` (not just on initial fetch).

**File scope:**
- `frontend/src/hooks/useApi.ts` — `QuestionOption`, `PendingQuestion` extension, `answerQuestionText`.
- `frontend/src/lib/streamClient.ts` — `AskEvent` type.
- `frontend/src/hooks/useTranscriptStream.ts` — line 148 fix.
- `frontend/src/hooks/__tests__/useTranscriptStream.test.ts` (or extend an existing test) — the WS `ask` handler test.

**Test first (red):** write the Vitest case (WS `ask` event with `options` → `pendingQuestions` carries `options`) before the fix. Watch it fail. Implement. Watch pass.

**Dependencies:** W5 (the backend WS broadcast must carry `options` for the test to pass end-to-end; the Vitest test can mock the WS event).

---

### W8 — Frontend: `AskHumanForm` component + `matchesToolCall` extension + wire into `ToolCallBlock`

**DoD:**
- `AskHumanForm` component in `ChatArea.tsx`:
  - Renders **inside the expanded `ToolCallBlock`**, in the same slot as the inline-approval panel (after the Input display, before the "Awaiting result" placeholder). Mutually exclusive with the inline-approval panel.
  - **Render condition:** `opcode === "ASK_HUMAN" && pendingQuestion.options?.length > 0` (AC13).
  - Vertical stack of full-width buttons (one per option): label (bold) + description (muted, below). Each button is a native `<button>` (`role="radio"`, `aria-checked`).
  - "Other" textarea (full-width) + Submit button. **Keyboard:** Enter submits (Shift+Enter newline); Escape cancels (`onCancelQuestion`).
  - Cancel/dismiss button → `onCancelQuestion(qid)`.
  - Clicking a stock button calls `answerQuestionText(sessionId, qid, label)`.
  - "Other" submit calls `answerQuestionText(sessionId, qid, typedText)`.
  - **Error states:** `submitting` state; buttons + textarea disabled while POST in flight; POST failure shows inline error ("Answer failed — try again" in `--needs-input`); `accepted:false` dismisses; WS `ask_resolved` mid-POST is benign (the `useTranscriptStream` filter unmounts the form; the POST completes `accepted:false` → treated as success).
  - **XSS-safe:** `saLabel`/`saDescription` rendered as React text children (`{label}`), never `dangerouslySetInnerHTML`.
  - Mobile: buttons full-width; textarea full-width; Submit below textarea; descriptions `text-xs`.
- `matchesToolCall` (ChatArea.tsx:836) extended: if the tool call's name is `ASK_HUMAN`, match a pending question with `options?.length > 0`; otherwise keep the `Allow …?` regex.
- **`MessageBlock` matching loop (ChatArea.tsx:866) changed (gate-plan correction):** today `const pq = pendingQuestions?.find((q) => matchesToolCall(q, block.toolCall!))` picks the first match. For ASK_HUMAN-with-options, this would match the same (oldest) question to every ASK_HUMAN tool call. **Fix:** track already-matched question IDs across the `message.blocks.map` iteration — e.g. a `Set<string>` of matched question IDs, and `matchesToolCall` + the loop skip questions already in the set. This implements the "oldest-unmatched" (creation-order) correlation (AC14) when ≥2 ASK_HUMAN tool calls are pending. (The `message.blocks.map` in `ChatMessage` (line 1041) is the loop site; the matched-set state lives in `ChatMessage` or `MessageBlock`'s parent.)
- `ToolCallBlock` renders `AskHumanForm` in the expanded section (the inline-approval panel + `AskHumanForm` are mutually exclusive — the approval panel renders for `Allow …?` matches; `AskHumanForm` for ASK_HUMAN-with-options matches).
- Vitest (`AskHumanForm.test.tsx` or extend `ChatArea.test.tsx`):
  - Renders one button per option (vertical stack) + "Other" textarea.
  - Clicking a stock button POSTs `{answer: label}`.
  - Typing + Enter submits POSTs `{answer: typed}`; Shift+Enter inserts newline; Escape cancels.
  - POST failure shows inline error; `accepted:false` dismisses; WS `ask_resolved` mid-POST benign.
  - **XSS:** label `<img src=x onerror=alert(1)>` renders as literal text.
  - Does NOT render for the confirmation gate (no `options`).
  - **≥2 ASK_HUMAN tool calls:** the oldest pending question matches the first ASK_HUMAN tool call; the second tool call matches the next-unmatched question (AC14).

**File scope:**
- `frontend/src/components/ChatArea.tsx` — `AskHumanForm` component; `matchesToolCall` extension; **`MessageBlock`/`ChatMessage` matching-loop change (track matched question IDs — AC14)**; `ToolCallBlock` wiring; prop threading (the `pendingQuestions`/`onAnswer`/`onCancel` props already flow through — verify).
- `frontend/src/hooks/useApi.ts` — `answerQuestionText` (from W7; ensure the component imports it).
- `frontend/src/components/__tests__/ChatArea.test.tsx` (or new `AskHumanForm.test.tsx`) — the 7 test cases above.

**Test first (red):** write the Vitest cases before the component. Watch them fail (component doesn't exist). Implement. Watch pass.

**Dependencies:** W7 (`QuestionOption` type, `answerQuestionText`, WS handler), W6 (the API route accepts `{answer}`).

---

### W9 — Gate check + hlint + commit

**DoD:**
- `make check` green (build + test + lint — cabal only).
- **`cd frontend && npm test` green (Vitest)** — gate-plan correction (Completeness #1): `make check` (Makefile:30) runs only `cabal build/test/lint`; it does NOT run the frontend Vitest suite. AC9's "Vitest green" requires this explicit separate step.
- `hlint src/ test/` → No hints (covered by `make check`'s `lint` target, but re-run to confirm).
- All work units W1-W8 committed (red-green-commit per unit: write test → watch fail → commit → implement → watch pass → commit).
- The design doc's §9 File Scope for Slice 1 is fully covered.
- Self-review: re-read the design doc's AC1-AC14 and verify each is met by the implementation (file:line evidence). AC11/AC12 (cancel/timeout) are documented behavior (no new code) — verify the doc's claim matches the code (the existing `AskReplySpec` cancel/timeout tests, which W2 migrated, already pin the sentinel behavior). AC10 (no change to confirmation gate) — verify `checkConfirmation`/`recordApproval`/`ApprovalCache` are untouched except the `ccPrompt` arity (W3). AC2 "dispatcher records the rejection" — verify the dispatcher's existing ACK-before-execute path records the rejected invocation (existing behavior, no new code).

**File scope:** none (verification only).

---

## Dependencies (graph)

```
W1 (QuestionOption + validation) ─┬─> W2 (PendingAsk.paOptions + askHumanWithOptions + pendingForSession reshape)
                                  ├─> W3 (AskPrompt + ccPrompt arity)  [also depends on W2]
                                  └─> W4 (ASK_HUMAN schema + toAuthorize)  [depends on W1, W3]

W2 ─┬─> W5 (web ccPrompt broadcasts options)  [also depends on W3]
    └─> W6 (handleListQuestions options + answer-route restructure)  [also depends on W5]

W3 ─> W4
W5 ─> W6
W6 ─┬─> W7 (frontend types + WS handler)  [W5 needed for end-to-end]
    └─> W8 (AskHumanForm + matchesToolCall)  [depends on W7]

W7 ─> W8
all ─> W9 (gate check)
```

**Critical path:** W1 → W2 → W3 → W4 → W5 → W6 → W7 → W8 → W9.

W1, W2, W3 can be partially parallelized (W1 is pure; W2 depends on W1; W3 depends on W1+W2). W4 depends on W1+W3. W5+W6 depend on W2+W3. W7+W8 are frontend (depend on W5+W6 for the backend contract). W9 is the gate.

## Human checkpoint

- **After W7 (web MVP shippable)** — self-reviewed adversarially (per user directive, no pause). The PR opens after W9.

## Risks (slice 1)

- **`ccPrompt` arity migration (W3)** is the riskiest unit — it touches 4 channel closures + 16 production call sites + 3 breaking test helpers (FakeCaps shared-`pop` split, LoopSpec×4 `apQuestion` capture, Phase2aSpec composition). `cabal build all` green is the gate. If a site is missed, `-Werror` catches it (type mismatch). The `\_ -> pure ""` test sites (~10 files) compile unchanged (arity-polymorphic `_`).
- **`pendingForSession` reshape (W2)** — the 4-tuple → `PendingQuestionInfo` record change requires migrating 2 deconstruction sites in `AskReplySpec.hs` (the `firstPending` helper at line 24-27 + the `map (\(_, q, _, _) -> q) ps` at line 236) + 1 production site (`handleListQuestions` in `API.hs`). The compiler (`-Werror`) catches any miss.
- **WS `ask` handler fix (W7)** — the design's claim that it "picks up automatically" was wrong (Designer #1). The explicit fix is in W7; the Vitest test pins it.
- **`matchesToolCall` extension (W8)** — the oldest-unmatched logic must be stable when ≥2 ASK_HUMAN tool calls are pending. The Vitest test should cover the ≥2 case.