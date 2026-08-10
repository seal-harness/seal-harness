# Implementation Plan: ASK_HUMAN Stock Answers (Slice 3 — Telegram)

**Issue**: https://github.com/seal-harness/seal-harness/issues/91
**Design**: `docs/superpowers/specs/2026-08-10-ask-human-stock-answers-design.md` (rev 2, §4.7)
**Branch**: `feat/ask-human-stock-answers` (continue on Slice 1+2's branch; rebase onto `main` after PR #92 merges).
**Tooling**: cabal + Nix (`make`); tests = hspec + QuickCheck; lint = hlint; gate = `cabal build all` + `cabal test` + `hlint src/ test/`.
**User directive**: proceed without stopping at user gates.

This plan covers **Slice 3 (Telegram inline keyboard)** only. Slices 1+2 are done.

## Plan-gate iteration history

- **Iteration 1**: Feasibility FAIL, Completeness FAIL, Scope FAIL. All 3 blockers:
  1. **Missed `runChannelLoop` call sites** — the plan added 2 params to `runChannelLoop` but the file scope omitted 3 production call sites: `Signal/Run.hs:88` (`runSignal`, the production path — NOT `runSignalLoop`), `Serve.hs:386` (Signal listener), `Serve.hs:422` (Telegram listener). The plan also falsely claimed `LoopSpec` has `runChannelLoop` call sites (it doesn't — it tests `channelCallDispatcher` + `newChannelDeps`). **Fix (rev 2)**: add all 3 to W2/W3 file scope with `Nothing`/`Nothing`; drop the LoopSpec claim.
  2. **`answerCallbackQuery` internal contradiction** — W1 builds `answerCallbackQuery` + `tuCallbackId` but W3 doesn't call them (the `callback_query_id` is lost in the `ChannelHandle.chReceive` → `(MessageSource, Text)` yield — the inbox only carries the body). AC8's "answerCallbackQuery acknowledges the spinner" clause is unmet. **Fix (rev 2)**: defer `answerCallbackQuery` to a follow-up (the spinner timeout is cosmetic — the answer is delivered correctly). W1 keeps `answerCallbackQuery` + `tuCallbackId` (the real transport parses them; the function is built for the follow-up). AC8 amended: the `answerCallbackQuery` clause is deferred with a documented TODO. The design's AC8 will be updated in the gate-check step (W4).
  3. **`getUpdates` `allowed_updates` claim** — the plan said "the Bot API by default doesn't deliver callback_query" — wrong. The default delivers all types except `chat_member` etc. `callback_query` IS delivered. **Fix (rev 2)**: corrected — no `allowed_updates` parameter needed.

## Work units

### W1 — Telegram transport: `TelegramButton`, `tgSendWithKeyboard`, `answerCallbackQuery`, `TelegramUpdate` callback fields

**DoD:**
- `TelegramButton` record in `Seal.Channels.Telegram.Transport`: `{ tbText :: !Text, tbCallbackData :: !Text }` with `ToJSON` (encodes as `{"text":..., "callback_data":...}`). Exported.
- `tgSendWithKeyboard :: Manager -> Text -> Text -> Text -> [[TelegramButton]] -> IO ()` — like `sendViaApi` but the JSON payload includes `"reply_markup": {"inline_keyboard": [[...]]}`. **MUST NOT set `parse_mode`** (gate: Security #3 — plain text, no markdown/HTML). Haddock documents this.
- `answerCallbackQuery :: Manager -> Text -> Text -> Text -> IO ()` — calls the Bot API `answerCallbackQuery` with `callback_query_id` + an optional `text` (display a toast) + `show_alert: false`. Best-effort (logs on failure, doesn't throw). Acknowledges the callback, stops the button's loading spinner.
- `TelegramUpdate` gains `tuCallbackData :: Maybe Text` + `tuCallbackId :: Maybe Text` (the callback_query's id, needed for `answerCallbackQuery`). When the update is a regular message, both are `Nothing`. When it's a `callback_query`, `tuCallbackData = Just data` + `tuCallbackId = Just id` + the chat id/sender come from `callback_query.message.chat`/`callback_query.from`.
- `parseTelegramUpdate` (Transport.hs:219) restructured to handle the `callback_query` object: when the update has `callback_query` (not `message`), parse `callback_query.data` + `callback_query.id` + `callback_query.message.chat.id` + `callback_query.from.id` into a `TelegramUpdate` with `tuCallbackData = Just data` + `tuCallbackId = Just id` + `tuBody = data` (the callback data; the loop uses it to route). The `message` path is unchanged (both fields = `Nothing`).
- `parseGetUpdatesResponse` (line 190): the `parseOneUpdate` already calls `parseTelegramUpdate` — the `callback_query` handling happens inside `parseTelegramUpdate`. The Bot API by default delivers `callback_query` updates (the default `allowed_updates` delivers all types except `chat_member` etc.); no `allowed_updates` parameter is needed in the `getUpdates` URL.
- Tests (`TransportSpec`): `tgSendWithKeyboard` builds the right JSON (no `parse_mode`); `parseTelegramUpdate` handles `callback_query` (yields `tuCallbackData`/`tuCallbackId`); `answerCallbackQuery` builds the right payload (guarded `pendingWith` if no real bot — or test the JSON construction only).

**File scope:**
- `src/Seal/Channels/Telegram/Transport.hs` — `TelegramButton`; `tgSendWithKeyboard`; `answerCallbackQuery`; `TelegramUpdate` fields; `parseTelegramUpdate` restructure; export new names.
- `test/Seal/Channels/Telegram/TransportSpec.hs` — `TelegramButton` JSON; `parseTelegramUpdate` callback_query; `tgSendWithKeyboard` no `parse_mode`.

**Test first (red):** write the TransportSpec tests before implementing. Watch them fail. Implement. Watch pass. Commit.

---

### W2 — `runChannelLoop` accepts an optional `ccPrompt` override; `mkTelegramHandleCaps`

**DoD:**
- `Seal.Channels.Loop.runChannelLoop` gains an optional parameter `mkCaps :: Maybe (ChannelHandle -> AskReplyStore -> SessionId -> ChannelCaps)`. When `Nothing`, uses `mkHandleCaps` (today's behavior — Signal + the generic numbered list). When `Just factory`, uses `factory h askReply sid` instead. This lets Telegram inject its own `ccPrompt` (inline keyboard) without changing the shared loop for Signal.
  - Alternative considered: threading a full `ChannelCaps` — but the loop builds per-sid caps (sid changes each turn), so a factory function is cleaner.
- The loop's `mkHandleCaps h askReply sid` call (line 384) becomes: `let handleCaps = case mkCaps of Nothing -> mkHandleCaps h askReply sid; Just f -> f h askReply sid`.
- `Seal.Channels.Telegram.Run.mkTelegramHandleCaps :: ChannelHandle -> AskReplyStore -> SessionId -> ChannelCaps` — like `mkHandleCaps` but:
  - `ccPrompt` calls `askHumanWithOptions store sid q opts` (registers `paOptions`).
  - In `notify`, sends the question text via `tgSend` (or `chSend h`), then sends a second message with the inline keyboard via `tgSendWithKeyboard` (the keyboard's rows: one row if ≤4 options, two rows otherwise; each button's `text` = `qoLabel`, `callback_data` = `take 8 (askIdText qid) <> ":" <> qoLabel`).
  - The Telegram `ChannelHandle` needs access to the transport's `tgSendWithKeyboard` — but `ChannelHandle` doesn't carry the transport. The cleanest approach: `mkTelegramHandleCaps` closes over the `TelegramTransport` (or the `Manager` + `token`) so it can call `tgSendWithKeyboard`.
  - Actually, the Telegram `ChannelHandle`'s `chSend` goes through `Transport.tgSend`. But `tgSendWithKeyboard` is a new transport function. The `ChannelHandle` doesn't expose it. **Decision:** `mkTelegramHandleCaps` takes the `TelegramTransport` as an extra arg, and the `ccPrompt` closure calls `tgSend transport` (for the question text) + a new `tgSendWithKeyboard` method on the transport (add `tgSendWithKeyboard :: Text -> Text -> [[TelegramButton]] -> IO ()` to the `TelegramTransport` record, wired in `mkRealTelegramTransport` + `mkMockTelegramTransport`).
  - This means `TelegramTransport` gains a `tgSendWithKeyboard` field + the mock transport captures it for tests.
- `runTelegram` (Telegram.Run:70) passes `Just (mkTelegramHandleCaps transport)` to `runChannelLoop`.
- Tests: the loop's existing tests stay green (Signal passes `Nothing` — uses `mkHandleCaps`).

**File scope:**
- `src/Seal/Channels/Telegram/Transport.hs` — `TelegramTransport` gains `tgSendWithKeyboard :: Text -> Text -> [[TelegramButton]] -> IO ()`; `mkRealTelegramTransport` wires it to the real `tgSendWithKeyboard`; `mkMockTelegramTransport` captures the keyboard sends.
- `src/Seal/Channels/Loop.hs` — `runChannelLoop` gains the optional `mkCaps` parameter (+ `onCallback` in W3; both added together to avoid 2 signature changes).
- `src/Seal/Channels/Telegram/Run.hs` — `mkTelegramHandleCaps`; pass `Just` to `runChannelLoop`.
- `src/Seal/Channels/Signal/Run.hs` — line 88 (`runSignal`, the production path): pass `Nothing`/`Nothing` to `runChannelLoop`. (NOT `runSignalLoop` — that's the legacy loop, unchanged.)
- `src/Seal/Command/Serve.hs` — lines 386 + 422 (the Signal + Telegram listeners): pass `Nothing`/`Nothing` to `runChannelLoop`.
- (LoopSpec does NOT call `runChannelLoop` directly — it tests `channelCallDispatcher` + `newChannelDeps`. No edit needed there.)
- `test/Seal/Channels/Telegram/RunSpec.hs` or `TransportSpec.hs` — assert the mock transport captured the keyboard sends.

**Test first (red):** write the test asserting the Telegram `ccPrompt` with options sends a keyboard (captured by the mock). Watch it fail. Implement. Watch pass. Commit.

---

### W3 — Telegram inbound path: callback_query → by-id delivery; typed message → `deliverNextAnswerResolved`

**DoD:**
- The Telegram loop's inbound path (inside `runChannelLoop`, after `chReceive h`) branches on `tuCallbackData`:
  - **`Just callbackData` (button tap):** parse the `callbackData` (`"<8hex>:<label>"`) → find the pending ask by the 8-hex prefix (linear scan over `pendingForSession` or the store — there are typically ≤2) → `deliverAnswer store qid (AskReply ScopeOnce label)` (by-id, NOT FIFO). (The `answerCallbackQuery` call is deferred — see the deferral section below.) The `delivered` bool is `True` if the ask was pending; the loop continues (no routing).
  - **`Nothing` (typed message):** the existing `deliverNextAnswerResolved askReply sid body` path (from Slice 2 W3) handles it (FIFO + numeric resolution). This is already in place.
- The branching happens in the `runChannelLoop`'s loop, but the callback-specific logic (parse + by-id deliver + answerCallbackQuery) is Telegram-specific. **Decision:** the `mkCaps` factory approach (W2) doesn't cover the inbound path — the inbound path is in the shared `runChannelLoop` loop, not in `ccPrompt`. So the loop needs to know whether the inbound update is a callback or a message. **Refined approach:** the `ChannelHandle`'s `chReceive` yields `(MessageSource, Text)` — the `Text` is the body. For a callback_query, the body is the `callback_data` (the `<8hex>:<label>` string). But the loop can't tell it's a callback vs a typed message that happens to look like one.
  - **Better approach:** extend the `ChannelHandle` or the loop to carry a "callback marker" — OR, simpler: the `mkTelegramHandleCaps` approach is only for `ccPrompt` (the outbound). The inbound path needs a separate hook. Let me reconsider.
  - **Simplest approach:** the `callback_data` (`<8hex>:<label>`) is a distinctive format (8 hex chars + `:` + label). The loop can detect it: if the body matches `^[0-9a-f]{8}:` AND a pending ask with that prefix exists, treat it as a callback → by-id delivery. Otherwise, it's a typed message → `deliverNextAnswerResolved`. This is a heuristic (a human could type a string that looks like `abcdefgh:label`) but the probability is negligible + the worst case is a misdelivery (the human's typed "Other" is delivered as if it were a button tap — the label is still a valid answer). This avoids extending the loop signature.
  - **Even simpler:** the `TelegramTransport` mock can test the callback path directly. The real loop's `deliverNextAnswerResolved` already handles the `callback_data` as a typed body (it's not a number, so it's delivered as-is). But that delivers the `callback_data` string (`<8hex>:<label>`) to the agent, not the label. The agent would receive `"abcd1234:main"` — not `"main"`. That's wrong.
  - **Decision: add an inbound callback hook to `runChannelLoop`.** The `mkCaps` factory (W2) gains an optional `onCallback :: Maybe (Text -> IO Bool)` — when the loop receives a body, it first checks `onCallback`; if `onCallback` is present and returns `True` (the body was a callback + delivered), the loop continues; otherwise falls through to `deliverNextAnswerResolved`. Telegram's `onCallback` parses the `callback_data` + delivers by-id + acknowledges. Signal passes `Nothing` (no callback support). This is cleaner than the heuristic.

  Actually, the cleanest is to extend the `mkCaps` factory to return a full "channel strategy" record, not just `ChannelCaps`. But that's over-engineering for one hook. Let me use the `onCallback` approach: `runChannelLoop` accepts `Maybe (Text -> IO Bool)` as a separate parameter (the callback handler). When the body arrives, the loop calls `onCallback body` first; if `True`, continue; if `False`, fall through to `deliverNextAnswerResolved`.

  **Final decision:** `runChannelLoop` gains TWO optional parameters: `mkCaps :: Maybe (ChannelHandle -> AskReplyStore -> SessionId -> ChannelCaps)` (W2) + `onCallback :: Maybe (Text -> IO Bool)` (W3). Both `Nothing` for Signal; `Just mkTelegramHandleCaps` + `Just onTelegramCallback` for Telegram.

- `onTelegramCallback :: AskReplyStore -> TelegramTransport -> Text -> IO Bool`:
  - Parse the body as `"<8hex>:<label>"` — if it doesn't match, return `False` (not a callback).
  - Find the pending ask by the 8-hex prefix (linear scan over the store's pending asks — `pendingForSession` won't work (no sid in a callback); use a new `findByAskIdPrefix :: AskReplyStore -> Text -> IO (Maybe (AskId, Text))` helper, or scan all pending asks). **Simpler:** the `callback_data` carries the full label, so the handler can just deliver the label as the answer text to the oldest pending ask for the session. But the session isn't known from the callback... The `callback_query` carries `message.chat.id` → the conversation id → the session id (via the cursor). But the `runChannelLoop` loop resolves the session AFTER the `deliverNextAnswer` call, not before.
  - **Simplest correct approach:** the `onTelegramCallback` receives the sid (resolved by the loop before calling the callback) — so `runChannelLoop` calls `onCallback sid body` (not just `body`). `onTelegramCallback` looks up the pending ask by the 8-hex prefix (scan the session's pending asks), delivers by-id, acknowledges. The `sid` is already resolved by the loop at the point of the call (line 374).
  - `onTelegramCallback :: AskReplyStore -> TelegramTransport -> Text -> SessionId -> Text -> IO Bool` — takes the store + transport + chatId (for `answerCallbackQuery` — the chatId is the callback's `message.chat.id`, but the loop has the `MessageSource` which carries the conversation id, not the raw `tuChatId`. Hmm.
  - **Even simpler:** the callback_data is `<8hex>:<label>`. The handler scans ALL pending asks (not session-specific) for a matching 8-hex prefix. If found, delivers by-id + the label. If not found, returns `False` (the body is a typed message — fall through). The `answerCallbackQuery` needs the `callback_query_id` — but the loop's `chReceive` yields `(MessageSource, Text)` and the `Text` is the `callback_data`. The `callback_query_id` is lost. The `answerCallbackQuery` call is best-effort (the spinner just times out — not critical). **Decision: skip `answerCallbackQuery` in v1** (the spinner timeout is cosmetic; the answer is delivered correctly). Add a TODO for v2.

  **Final final decision:** keep it simple. The `onCallback` hook is `Maybe (SessionId -> Text -> IO Bool)`. Telegram's `onTelegramCallback sid body`:
  1. Parse `body` as `"<8hex>:<label>"`. If no match, return `False`.
  2. Scan the session's pending asks (via a new `pendingForSession` + prefix match) for one whose `askIdText` starts with the 8-hex prefix. If none, return `False`.
  3. `deliverAnswer store qid (AskReply ScopeOnce label)` (by-id).
  4. Return `True`.
  No `answerCallbackQuery` in v1 (TODO). The `callback_query_id` is lost in the loop's `chReceive` (which only yields the body). This is acceptable — the answer is delivered; the spinner just times out.

- Tests: `TransportSpec` or a new test asserts the callback_data format (`<8hex>:<label>`) is parsed + delivered by-id.

**File scope:**
- `src/Seal/Channels/Loop.hs` — `runChannelLoop` gains `onCallback :: Maybe (SessionId -> Text -> IO Bool)` (same signature change as W2's `mkCaps` — both added together); the loop calls it before `deliverNextAnswerResolved`.
- `src/Seal/Channels/Telegram/Run.hs` — `onTelegramCallback`; pass `Just` to `runChannelLoop`.
- `src/Seal/Channels/Signal/Run.hs` — line 88: pass `Nothing` for `onCallback`.
- `src/Seal/Command/Serve.hs` — lines 386 + 422: pass `Nothing` for `onCallback`.
- `src/Seal/Handles/AskReply.hs` — `findByAskIdPrefix :: AskReplyStore -> SessionId -> Text -> IO (Maybe AskId)` (scans the session's pending asks for one whose `askIdText` starts with the 8-hex prefix; returns the `AskId`).

**`answerCallbackQuery` deferral (gate-plan correction):** The design's AC8 mentions `answerCallbackQuery` (gate: Architect #5b). However, the `callback_query_id` is lost in the `ChannelHandle.chReceive` → `(MessageSource, Text)` yield — the inbox only carries the body, not the callback_query_id. Calling `answerCallbackQuery` would require threading the `callback_query_id` through the `TelegramChannel` reader loop + the inbox + the `ChannelHandle.chReceive` yield — a significant invasive change for a purely cosmetic benefit (the button's loading spinner times out after ~10s; the answer is delivered immediately). **Decision: defer `answerCallbackQuery` to a follow-up.** W1 keeps the `answerCallbackQuery` function + `tuCallbackId` field (the real transport parses them; the function is ready for the follow-up). The design's AC8 is amended: the `answerCallbackQuery` clause is deferred with a documented TODO. W4 updates the design doc.

**Test first (red):** write a test asserting a callback_data (`<8hex>:<label>`) is delivered by-id (the waiting `askHumanWithOptions` thread unblocks with the label). Watch it fail. Implement. Watch pass. Commit.

---

### W4 — Gate check + AC8 amendment

**DoD:**
- `cabal build all` green (`-Werror` clean).
- `cabal test` green (including new Telegram transport + callback tests).
- `hlint src/ test/` → No hints (my files).
- `cd frontend && npm test` green (no frontend changes in Slice 3).
- **AC8 amendment:** update the design doc's AC8 to defer the `answerCallbackQuery` clause: "a button tap routes via `deliverAnswer` (by-id, NOT FIFO); a typed reply routes via `deliverNextAnswerResolved`. `tgSendWithKeyboard` does NOT set `parse_mode`. The `answerCallbackQuery` acknowledgment is deferred to a follow-up (the `callback_query_id` is not threaded through the `ChannelHandle.chReceive` yield; the spinner timeout is cosmetic — the answer is delivered immediately)."
- Self-review: re-read the amended AC8 + verify each clause is met.

**File scope:**
- `docs/superpowers/specs/2026-08-10-ask-human-stock-answers-design.md` — AC8 amendment (defer `answerCallbackQuery`).

---

## Dependencies (graph)

```
W1 (Transport: TelegramButton, tgSendWithKeyboard, TelegramUpdate callback fields) ─┬─> W2 (mkTelegramHandleCaps + runChannelLoop mkCaps param)
                                                                                       └─> W3 (onTelegramCallback + runChannelLoop onCallback param + findByAskIdPrefix)

W2 ─> W3 (the callback handler needs the transport from W2's mkTelegramHandleCaps? No — onCallback is separate from mkCaps. But both are passed to runChannelLoop, so they're co-dependent on the runChannelLoop signature change.)
all ─> W4 (gate check)
```

**Critical path:** W1 → W2 → W3 → W4. W2 and W3 both modify `runChannelLoop`'s signature — they should be done together (or W2 first, then W3 adds the second parameter).

## Risks

- **`runChannelLoop` signature change** — adding two optional parameters (`mkCaps` + `onCallback`) changes all call sites. The existing tests call `runChannelLoop` — they pass `Nothing` for both. `cabal build all` green is the gate.
- **`callback_data` prefix collision** — the 8-hex prefix is 4 bytes = 4 billion possibilities; the probability of two pending asks sharing a prefix is negligible (≤2 pending asks per session). The linear scan is O(pending asks) — fine.
- **No `answerCallbackQuery` in v1** — the button's loading spinner times out after ~10s (Telegram's default). The answer is delivered immediately; the spinner is cosmetic. A TODO for v2.
- **`tgSendWithKeyboard` no `parse_mode`** — enforced by the implementation (the JSON payload doesn't include `parse_mode`). The test pins this.
- **`getUpdates` `allowed_updates`** — the Bot API by default delivers `message` + `callback_query` (unless `allowed_updates` is explicitly set to exclude it). The existing `getUpdates` URL doesn't set `allowed_updates`, so `callback_query` updates ARE delivered. Verify (or add `&allowed_updates=message,callback_query` to be safe).