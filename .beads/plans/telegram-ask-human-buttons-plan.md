# Implementation Plan: Telegram inline-keyboard buttons for ASK_HUMAN options

<!-- gate-iterations: 2 -->
<!-- iteration-1: Completeness FAIL (4 missing named tests), Scope FAIL (1 use of !! partial function), Feasibility PASS-with-note (3 extra test ChannelHandle literals). All 5 blockers fixed in iteration 2. -->

**Issue**: https://github.com/seal-harness/seal-harness/issues/93
**Branch**: `feat/telegram-ask-human-buttons` (base: `main`)
**Tooling**: cabal + Nix (`make`); tests = hspec + QuickCheck; lint = hlint; gate = `make check`.
**Reference**: hermes-agent `gateway/platforms/telegram.py` `send_clarify` (lines 2701-2781) + `_handle_callback_query` `cl:` branch (lines 3300-3389). Clean-room: port the IDEA (inline keyboard per option + Other; index-encoded callback_data; answerCallbackQuery on tap), write it fresh in seal-harness's typed capability-handle style.

## Goal

When the agent calls `ASK_HUMAN` with the optional `options` array on a Telegram channel, render one inline keyboard button per choice (plus an "Other" free-text button) instead of the current numbered-list text. Tapping a button delivers the answer by-id and dismisses the spinner via `answerCallbackQuery`. Open-ended `ASK_HUMAN` (no options) is unchanged. Non-Telegram channels are unchanged.

## Current state (verified by reading the source)

The infrastructure is mostly already in place (explicitly deferred at `src/Seal/Channels/Telegram/Run.hs:196-208`):

- `TelegramTransport.tgSendWithKeyboard :: Text -> Text -> [[TelegramButton]] -> IO ()` + `TelegramButton { tbText, tbCallbackData }` exist (`Transport.hs:58-81`) and work (real impl `tgSendWithKeyboardViaApi` at line 377).
- `parseTelegramUpdate` already parses `callback_query` updates into `tuCallbackData :: Maybe Text` + `tuCallbackId :: Maybe Text` (`Transport.hs:257-322`).
- `runChannelLoop` already has the `mkCaps :: Maybe (ChannelHandle -> AskReplyStore -> SessionId -> ChannelCaps)` + `onCallback :: Maybe (SessionId -> Text -> IO Bool)` hooks wired (`Loop.hs:332-453`), and Telegram already passes `Just (mkTelegramHandleCaps transport)` + `Just (onTelegramCallback askReply)` (`Run.hs:87`).
- `onTelegramCallback` already routes `<8hexPrefix>:<label>` callback_data to by-id delivery via `deliverAnswer` (`Run.hs:215-227`).
- `findByAskIdPrefix` (`AskReply.hs:644-649`) scans `pendingForSession` for a pending ask whose `askIdText` starts with the 8-hex prefix. `PendingQuestionInfo` carries `pqiOptions :: [QuestionOption]` (`AskReply.hs:273-280`), so the index→label resolution can read the options from the pending ask WITHOUT a new AskReply.hs export.
- `mkHandleCaps` (`Loop.hs:456-465`) is the generic numbered-list path: `ccPrompt (AskPrompt q opts) = chSend h (formatQuestionWithOptions q opts) >> askHumanWithOptions askReply sid q opts (const (pure ()))`.

The missing pieces (the work):

1. `mkTelegramHandleCaps` (`Run.hs:207-208`) just delegates to `mkHandleCaps` — it does NOT send an inline keyboard.
2. `ChannelHandle` (`Handles/Channel.hs:25-57`) has no `chLastChatId` field, so `mkTelegramHandleCaps` cannot learn the chat id needed for `tgSendWithKeyboard`.
3. `answerCallbackQuery` is never called — `answerCallbackQueryViaApi` exists (`Transport.hs:404-419`) but nothing invokes it; the button's loading spinner would never dismiss once buttons exist.
4. `callback_data` today is `<8hex>:<label>` (per `Run.hs:217`); labels can exceed Telegram's 64-byte `callback_data` limit (a label can be up to 64 bytes by itself, + 8 hex + 1 colon = 73). Switch to `<8hex>:<idx>` (numeric index 0-7) or `<8hex>:other` and resolve the index to the label in `onTelegramCallback` via `pqiOptions` (mirrors hermes `cl:<id>:<idx>`).

## Work units

### W1 — Add `chLastChatId` to `ChannelHandle` + wire all channels + fakes

**Files:**
- `src/Seal/Handles/Channel.hs` — add field `chLastChatId :: IO (Maybe Text)` to the `ChannelHandle` record (after `chReceive`). Doc: "The last chat id the channel addressed a reply to (for transports that need it, e.g. Telegram's `tgSendWithKeyboard`). `Nothing` for channels that address by user id (Signal) or have no chat-id concept (CLI, web, fakes)."
- `src/Seal/Channels/Telegram.hs` — `toHandle ch` wires `chLastChatId = readIORef (tcgLastChat ch)` (the IORef already tracks `Maybe Text` of `tuChatId`, set at `Telegram.hs:124`).
- `src/Seal/Channels/Signal.hs` — `toHandle ch` wires `chLastChatId = pure Nothing`.
- `test/Seal/TestHelpers/FakeChannel.hs` — `toHandle fc` wires `chLastChatId = pure Nothing`.
- `test/Seal/Session/LockSpec.hs` — `ChannelHandle {}` literal at line ~26: add `chLastChatId = pure Nothing` (gate-audit found this site).
- `test/Seal/Channels/LoopSpec.hs` — `ChannelHandle {}` literal at line ~72: add `chLastChatId = pure Nothing` (gate-audit found this site).
- `test/Seal/Handles/ChannelSpec.hs` — `ChannelHandle {}` literal at line ~37: add `chLastChatId = pure Nothing` (gate-audit found this site).

**DoD:**
- `ChannelHandle` has a `chLastChatId :: IO (Maybe Text)` field.
- Telegram's `chLastChatId` returns the last `tuChatId` written to `tcgLastChat` (verified by a test: send an update, `chLastChatId` returns `Just chatId`).
- Signal's + FakeChannel's `chLastChatId` returns `Nothing`.
- ALL 6 `ChannelHandle {}` construction sites compile under `-Wall -Werror` (`-Wmissing-fields`): the 4 listed in Files + the 3 test literals (LockSpec, LoopSpec, ChannelSpec) found by the plan-gate audit (`grep -rn "ChannelHandle {" src/ test/`). The implementer MUST re-run this grep before committing — if any site is missed, the build breaks.

**TDD:** Red — write `TelegramSpec` test "chLastChatId returns the last chat id after an update is received" (expect `Just "123456789"` after the scripted update). Watch it fail (field doesn't exist). Green — add the field, wire it. Audit all other `ChannelHandle {}` literals for compile breaks.

### W2 — Add `tgAnswerCallback` to `TelegramTransport`; call it in `readerLoop`

**Files:**
- `src/Seal/Channels/Telegram/Transport.hs` — add field `tgAnswerCallback :: Text -> IO ()` to `TelegramTransport` (after `tgSendWithKeyboard`). Real impl (`mkRealTelegramTransport`): `tgAnswerCallback = answerCallbackQueryViaApi mgr token`. Mock (`mkMockTelegramTransport`): capture callbacks to a new `IORef [Text]`; return a third accessor `getCallbacks :: IO [Text]`. Update the `mkMockTelegramTransport` return type to `(TelegramTransport, IO [(Text, Text)], IO [BotCommand], IO [Text])` — this is a breaking change to the test helper, so update ALL callers (audit via `grep -rn "mkMockTelegramTransport" test/`).
- `src/Seal/Channels/Telegram.hs` — in `readerLoop`, after allow-listing + pushing to inbox, when `tuCallbackId` is `Just cbId`, call `tgAnswerCallback (tcgTransport ch) cbId` (best-effort: wrap in `try @SomeException`, log on failure, never throw — mirrors the existing error-tolerance of the reader). This dismisses the button's loading spinner.

**DoD:**
- `TelegramTransport` has `tgAnswerCallback :: Text -> IO ()`.
- Real impl calls `answerCallbackQueryViaApi`; mock captures the `callback_query_id` strings.
- `readerLoop` calls `tgAnswerCallback` for every callback_query update (verified: mock captures one callback per scripted callback update).
- A regular `message` update (no `tuCallbackId`) does NOT trigger `tgAnswerCallback` (verified: mock captures zero callbacks for a message-only scripted update).
- All `mkMockTelegramTransport` callers updated for the new return arity.

**TDD:** Red — write `TelegramSpec` test "readerLoop calls tgAnswerCallback for callback_query updates" (script a callback update, assert `getCallbacks` returns one id; script a message update, assert zero). Watch it fail. Green — add the field + the reader call.

### W3 — Rewrite `mkTelegramHandleCaps` (inline keyboard when opts non-empty)

**Files:**
- `src/Seal/Channels/Telegram/Run.hs` — rewrite `mkTelegramHandleCaps` so `ccPrompt (AskPrompt q opts)`:
  - **Empty `opts`** → current behavior: `chSend h (formatQuestionWithOptions q [])` (which is just `q`) then block on `askHumanWithOptions askReply sid q [] (const (pure ()))`. No keyboard.
  - **Non-empty `opts`** → build the keyboard: one row per option (button label = the option's `qoLabel`, callback_data = `<8hexPrefix>:<T.pack (show idx)>` for `idx` in `[0..length opts - 1]`), plus a final row with one "Other" button (callback_data = `<8hexPrefix>:other`). The 8-hex prefix is `T.take 8 (askIdText qid)`. Send via `tgSendWithKeyboard (tgTransport) chatId q keyboard` where `chatId` comes from `chLastChatId h` (if `Nothing`, fall back to `chSend h (formatQuestionWithOptions q opts)` — the numbered list — so the prompt still works if no chat has been seen). Then block on `askHumanWithOptions askReply sid q opts (const (pure ()))`.
  - The `qid` is not known until `askHumanWithOptions` mints it internally. Two options:
    - (a) Pre-mint the `AskId` with `newAskId` (exported? check), register the pending ask manually, send the keyboard with the prefix, then block. This couples `mkTelegramHandleCaps` to the store internals.
    - (b) Pass a `notify` callback to `askHumanWithOptions` that receives the `AskId` and sends the keyboard. `askHumanWithOptions` already takes `notify :: AskId -> IO ()` (`AskReply.hs:382-383`) and fires it BEFORE blocking (`AskReply.hs:406`). This is the clean seam: `notify qid = sendKeyboard qid`. **Use (b).**
  - So: `ccPrompt (AskPrompt q opts) = do { mChat <- chLastChatId h; case (mChat, opts) of { (Just chatId, _:_) -> askHumanWithOptions askReply sid q opts (sendKeyboard chatId q opts); _ -> chSend h (formatQuestionWithOptions q opts) >> askHumanWithOptions askReply sid q opts (const (pure ())) } }` where `sendKeyboard chatId q opts qid = tgSendWithKeyboard tgTransport chatId q (buildKeyboard (T.take 8 (askIdText qid)) opts)`.
  - `buildKeyboard :: Text -> [QuestionOption] -> [[TelegramButton]]` — pure: `map (\(i, o) -> [TelegramButton (qoLabel o) (prefix <> ":" <> T.pack (show i))]) (zip [0..] opts) <> [[TelegramButton "Other" (prefix <> ":other")]]`.
  - Update the `mkTelegramHandleCaps` signature: it already takes `TelegramTransport` (currently ignored) — now it uses `tgSendWithKeyboard`. Keep the signature `TelegramTransport -> ChannelHandle -> AskReplyStore -> SessionId -> ChannelCaps`.
  - Delete the deferral comment at `Run.hs:196-206`; replace with the actual behavior doc.

**DoD:**
- `mkTelegramHandleCaps`'s `ccPrompt` with non-empty `opts` sends exactly ONE `tgSendWithKeyboard` call (verified: mock captures 1 call) with the question text + a keyboard of `length opts + 1` rows (one button per row).
- Each option button's `tbCallbackData` is `<8hex>:<idx>` (verified: `T.take 8` of the ask id + `:` + the 0-based index); the "Other" button's `tbCallbackData` is `<8hex>:other`.
- `tbText` of each option button is the option's `qoLabel`; the "Other" button's `tbText` is `"Other"`.
- Empty `opts` → no `tgSendWithKeyboard` call (verified: mock captures 0 calls); the question is sent via `chSend` (the existing path).
- `chLastChatId` returning `Nothing` with non-empty `opts` → falls back to `chSend` (numbered list); no `tgSendWithKeyboard` call (verified). This is the graceful-degradation path (should not happen in practice — the first inbound message sets the chat id — but must not crash).
- `ccPrompt` blocks until the answer is delivered (by-id via callback OR by the "Other" fallthrough) — verified by the integration test in W5.

**TDD:** Red — write `TelegramButtonsSpec` tests:
- "ccPrompt with options sends an inline keyboard" (build a mock transport + channel + askReply, call `ccPrompt`, assert `getKeyboardSends` returns 1 call with the right shape).
- "ccPrompt with empty opts sends plain text, no keyboard" (call `ccPrompt` with `AskPrompt q []`, assert `getKeyboardSends` returns 0 and `chSend` was called with `q`).
- "ccPrompt with options but no chat id falls back to chSend" (set up a channel whose `chLastChatId = pure Nothing`, call `ccPrompt` with non-empty opts, assert `getKeyboardSends` returns 0 and `chSend` was called with the numbered list).
Watch them fail (current impl sends a numbered list, no keyboard). Green — rewrite `mkTelegramHandleCaps`.

### W4 — Rewrite `onTelegramCallback` (`<8hex>:<idx>` / `<8hex>:other` + index resolution)

**Files:**
- `src/Seal/Channels/Telegram/Run.hs` — rewrite `onTelegramCallback`:
  - Parse `body` as `<prefix>:<token>` where `prefix` is 8 hex chars and `token` is either a decimal index (`0`-`7`) or `other`.
  - If `token == "other"` → return `False` (the loop falls through to `deliverNextAnswerResolved`, so the next typed message is captured as the free-text answer). Do NOT deliver an answer here.
  - If `token` is a decimal `idx`:
    1. `mQid <- findByAskIdPrefix store sid prefix` — find the pending ask.
    2. If `Nothing` → return `False` (stale callback, fall through).
    3. If `Just qid` → look up the pending ask's options to resolve the index. Use `pendingForSession store sid` + filter by `pqiId == qid` to get `pqiOptions`. (Reuses the existing `pendingForSession` export — no new AskReply.hs function. The scan is O(n) over pending asks for this session, which is ≤ a handful; acceptable. `findByAskIdPrefix` already does the same scan.)
    4. Resolve the index SAFELY (no `!!` — AGENTS.md bans partial functions): convert `pqiOptions` to a `Vector QuestionOption` once (`V.fromList opts`), then `V.!? idx` → `Just o` → `deliverAnswer store qid (AskReply ScopeOnce (qoLabel o))`; return `True`. `Nothing` (out of bounds) → return `False` (stale/malformed; fall through).
  - Keep the `isHexChar` helper.
- Delete the old `<8hex>:<label>` parsing (labels are no longer in `callback_data`).

**DoD:**
- `onTelegramCallback` parses `<8hex>:<0>` and delivers `qoLabel` of the first option (verified: `deliverAnswer` called with the label, returns `True`).
- `onTelegramCallback` parses `<8hex>:<other>` and returns `False` without delivering (verified: no `deliverAnswer` call, returns `False`).
- An out-of-bounds index (`<8hex>:<99>`) returns `False` without delivering.
- A stale prefix (`<deadbeef>:<0>` when no pending ask matches) returns `False`.
- A malformed body (no colon, non-hex prefix) returns `False`.
- The `callback_data` is always ≤ 64 bytes (verified by a QuickCheck property: for any validated `[QuestionOption]` (1-8 options), `T.length (prefix <> ":" <> token) ≤ 14` — well under 64).

**TDD:** Red — write `TelegramButtonsSpec` tests:
- "onTelegramCallback resolves index to label" (register a pending ask with options, call `onTelegramCallback` with `<prefix>:0`, assert `deliverAnswer` called with the first option's label, returns `True`).
- "onTelegramCallback: other falls through" (call with `<prefix>:other`, assert returns `False`, no delivery).
- "out-of-bounds index falls through" (call with `<prefix>:99`, assert returns `False`).
- "stale prefix falls through" (call with `<deadbeef>:0` when no pending ask matches, assert returns `False`).
- "malformed callback body falls through" (call with a body with no colon, and with a non-hex prefix; assert returns `False` for both).
- **"prop_callbackDataWithin64Bytes"** (QuickCheck): for any validated `[QuestionOption]` (1-8 options, labels ≤ 64 bytes per `validateOptions`), and any `idx ∈ [0 .. length opts - 1]` or `other`, `T.length (prefix <> ":" <> token) ≤ 14` (and ≤ 64). The prefix is 8 hex chars; the token is at most 5 chars (`other`); total ≤ 14.
Watch them fail (current impl expects `<8hex>:<label>`, not `<8hex>:<idx>`). Green — rewrite `onTelegramCallback`.

### W5 — Integration test + cabal/Main wiring + update existing TelegramSpec

**Files:**
- `test/Seal/Channels/TelegramButtonsSpec.hs` — NEW. Integration test: script a callback update (with `tuCallbackId` + `tuCallbackData = "<prefix>:<idx>"`) after a pending ask is registered; assert (a) the agent's `askHumanWithOptions` unblocks with the right label, (b) `tgAnswerCallback` was called once, (c) the keyboard was sent with the right shape. Also the "Other" integration: script `<prefix>:other` then a typed message; assert the typed text is delivered.
- `test/Seal/Channels/TelegramSpec.hs` — update for the new `chLastChatId` field (W1 test) + the new `mkMockTelegramTransport` arity (W2).
- `seal-harness.cabal` — add `test/Seal/Channels/TelegramButtonsSpec.hs` to the test-suite `other-modules`.
- `test/Main.hs` — import + run `TelegramButtonsSpec`.

**DoD:**
- `TelegramButtonsSpec` exists and covers: keyboard rendering (W3), callback index resolution (W4), "Other" fallthrough (W4), spinner dismiss (W2), end-to-end unblock (W3+W4).
- `TelegramSpec` compiles + passes with the new field + new mock arity.
- `test/Main.hs` runs the new spec.
- `seal-harness.cabal` lists the new module in `other-modules`.
- `make check` green (build + test + lint).

**TDD:** The spec is the test — write it first (red), implement W1-W4 to make it green.

## Deviations from issue / design decisions

- **`askHumanWithOptions`'s `notify` callback is the seam** for sending the keyboard (W3 decision (b)). The alternative (pre-minting `AskId` + manual registration) would couple `mkTelegramHandleCaps` to `AskReplyStore` internals; the `notify :: AskId -> IO ()` callback is the existing designed seam (`AskReply.hs:382-383`, fired at line 406 before blocking). No `AskReply.hs` change needed.
- **`callback_data` encoding is `<8hex>:<idx>`** (0-based) **or `<8hex>:other`**, NOT `<8hex>:<label>`. Labels can be up to 64 bytes (the `validateOptions` limit), + 8 hex + 1 colon = 73 bytes, exceeding Telegram's 64-byte `callback_data` limit. The index is always 1 char (0-7); `other` is 5 chars. Max total = 14 bytes. This mirrors hermes `cl:<id>:<idx>` / `cl:<id>:other`.
- **Index resolution reuses `pendingForSession`** (no new `AskReply.hs` export). `findByAskIdPrefix` already scans `pendingForSession`; `onTelegramCallback` does the same scan + reads `pqiOptions`. O(n) over pending asks for the session (≤ a handful); acceptable.
- **`answerCallbackQuery` is called in `readerLoop`**, not in `onTelegramCallback`. The reader is the first code that sees `tuCallbackId`; calling it there means the spinner dismisses immediately on receipt, before the loop's callback routing. `onTelegramCallback` runs synchronously in the loop after, so by the time it delivers the answer the spinner is already dismissed. This is simpler than threading `tgAnswerCallback` into `onTelegramCallback` and matches the reader's existing "handle transport-level concerns" role.
- **No message edit after button tap** (hermes edits the message to show the decision). Out of scope per the issue; the spinner-dismiss + answer delivery is the user-facing value. Can be added later.

## Plan-gate self-check

- **Feasibility:** every claimed "exists" verified by reading the cited file:line (Transport.hs:58-81, 257-322, 404-419; Loop.hs:332-453, 456-465; Run.hs:87, 196-227; AskReply.hs:273-280, 382-383, 406, 644-649; Telegram.hs:124; Handles/Channel.hs:25-57; Signal.hs:50-60; FakeChannel.hs:50-60). The `notify` seam is the designed integration point. The `pendingForSession` + `pqiOptions` path is verified. No fabricated scope. **Gate note:** the plan-gate feasibility audit found 3 additional `ChannelHandle {}` literals in test files (LockSpec.hs:26, LoopSpec.hs:72, ChannelSpec.hs:37) beyond the 4 listed in W1's original Files — added to W1 Files. The implementer MUST re-run `grep -rn "ChannelHandle {" src/ test/` before committing.
- **Completeness:** all 8 DoD items from the issue are covered with NAMED tests: DoD 1 → W3 "ccPrompt with options sends an inline keyboard"; DoD 2 → W4 "onTelegramCallback resolves index to label" + W5 integration; DoD 3 → W4 "onTelegramCallback: other falls through" + W5 integration; DoD 4 → W2 "readerLoop calls tgAnswerCallback for callback_query updates" + W5 integration; DoD 5 → W4 "prop_callbackDataWithin64Bytes" (QuickCheck); DoD 6 → W3 "ccPrompt with empty opts sends plain text, no keyboard"; DoD 7 → W5 `make check` (regression — existing SignalSpec/LoopSpec run unmodified); DoD 8 → W5 `make check` + cabal/Main wiring. **Gate fix:** 4 missing named tests added to W3/W4 TDD lists (empty-opts, no-chat-id fallback, malformed-body, QuickCheck property).
- **Scope:** no `ASK_HUMAN` schema/authorization changes; no web frontend changes; no Signal/CLI behavior changes; no message-edit after tap. Matches the issue's in/out-of-scope. **Gate fix:** W4's use of `!!` (a partial function banned by AGENTS.md) replaced with safe `Vector.!?` indexing. Field naming matches existing records (`chLastChatId` mirrors `chSend`/`chReceive`; `tgAnswerCallback` mirrors `tgSend`). Clean-room: uses seal-harness's existing `<8hex>:` convention extended with `:idx`/`:other`, NOT hermes's `cl:` prefix.

## Execution order

W1 → W2 → W3 → W4 → W5 (W3 depends on W1 for `chLastChatId`; W4 is independent of W3 but W5 integrates both; W2 is independent but W5 asserts the spinner). Each W is red-green-commit. After W5: `make check` → open PR.