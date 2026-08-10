# ASK_HUMAN Stock Answers (Channel-Portable Multiple-Choice Questions)

**Issue**: (to be filed)
**Branch**: `feat/ask-human-stock-answers`
**Date**: 2026-08-10
**Status**: Design — awaiting review gate

## 1. Problem

`ASK_HUMAN` (`Seal.ISA.Ops.Human`) currently takes a single `question: string`
and returns the human's typed reply. The frontend (`ChatArea.tsx`) renders
pending ASK_HUMAN questions **only** when they happen to match the Untrusted
confirmation-gate regex `^Allow\s+(\S+)\s+(\{.*\})\?` (`matchesToolCall`,
`ChatArea.tsx:836`) — a pure ASK_HUMAN question (no `Allow …?` prefix) renders
**nothing** inline; the loop just blocks silently until the human types into the
composer or a chat channel's next inbound message is consumed via
`deliverNextAnswer`. There is no way for the agent to offer the human a set of
discrete choices, and no channel-portable shape for carrying those choices.

Both reference repos solve this:

- **opencode** (`packages/schema/src/question.ts`) — `Question.Info` has
  `question`, `header`, `options: [{label, description}]`, `multiple`,
  `custom` (allow own answer). The web dock (`session-question-dock.tsx`)
  renders one button per option with label + description, plus a "Type your own
  answer" textarea.
- **hermes-agent** (`tools/clarify_tool.py`) — `clarify` takes `question` +
  `choices: List[str]` (max 4); the UI always appends a 5th "Other" option.
  Telegram/Discord render real platform-native buttons (RELEASE_v0.14.0.md).

We want the same capability in Seal Harness, with three constraints that shape
the design:

1. **Channel-portable.** The agent specifies the choices once; every channel
   (web, Signal, Telegram, CLI) renders them in the richest way its transport
   supports and returns an equivalent answer. The web renders a form with
   buttons + a free-text "Other"; Telegram renders an inline keyboard;
   Signal/CLI fall back to a numbered list + free text. The agent's code path
   is identical regardless of channel.
2. **Backward-compatible.** Existing `ASK_HUMAN` calls with only `question`
   keep working unchanged. Stock answers are optional.
3. **Does not touch the Untrusted confirmation gate.** That gate's four
   hard-coded scope buttons (`once`/`for_session`/`always`/`rejected`) carry
   access-control semantics (an `ApprovalScope` that caches future
   authorizations); ASK_HUMAN stock answers are free-form clarifying
   questions whose replies are never cached. Conflating them would muddy both.
   The two systems stay separate.

## 1a. Use Cases (WHO / WANTS / SO THAT / WHEN)

The primary personas are the **agent** (calls ASK_HUMAN to ask a clarifying
question) and the **human** (answers it on whatever channel they're on).

1. **Agent offers a multiple-choice clarification** — *As* an agent, *I want*
   to call `ASK_HUMAN` with a question and up to N stock answers, *so that*
   the human can pick one with a single click/tap instead of typing a
   free-form reply, *when* the decision has a small, enumerable option set
   (e.g. "Which branch should I target?" → `[main, develop, release/2.3]`).
2. **Human answers via the web form** — *As* a human on the web frontend,
   *I want* to see the question rendered as a form with one button per stock
   answer (label + description) plus an "Other" textarea, *so that* I can
   click my choice or type a custom reply, *when* an ASK_HUMAN with stock
   answers is pending.
3. **Human answers via Telegram inline buttons** — *As* a human on Telegram,
   *I want* to see the question followed by one inline keyboard button per
   stock answer (and know I can type a custom reply as a normal message),
   *so that* I can tap my choice, *when* an ASK_HUMAN with stock answers is
   pending on a Telegram-bound session.
4. **Human answers via Signal/CLI numbered list** — *As* a human on Signal or
   the CLI TUI, *I want* to see the question followed by a numbered list of
   stock answers and know I can type the number or my own reply, *so that* I
   can answer with minimal typing, *when* an ASK_HUMAN with stock answers is
   pending.
5. **Agent asks an open-ended question (status quo)** — *As* an agent, *I
   want* to call `ASK_HUMAN` with only `question` and have it behave exactly
   as today, *so that* existing prompts and channels are unaffected, *when*
   the question is genuinely open-ended.

## 2. Goals / Non-Goals

**Goals**

- Extend `ASK_HUMAN`'s input schema with an optional `stockAnswers` field.
- Thread the stock answers through the ask/reply store → WS broadcast → REST
  API → frontend, and through the channel-agnostic `ccPrompt` seam so every
  channel can render them.
- Web frontend: render a question form (buttons + "Other" textarea) for
  pending ASK_HUMAN questions that carry stock answers. The existing raw
  opcode block (the `ToolCallBlock`) stays as-is.
- Generic chat channel (Signal, CLI TUI): render a numbered list of stock
  answers alongside the question; the human types the number or a custom
  reply; the inbound-message path resolves the number to the label.
- Telegram channel: render the question text + a Telegram inline keyboard
  with one button per stock answer; a callback_query delivers the chosen
  label directly; a typed message still works as "Other".
- Always offer a free-text "Other" answer on every channel (per user
  decision).
- TDD: red-green for every layer; QuickCheck properties for the
  stock-answer validation (length bounds, label uniqueness).

**Non-Goals**

- No change to the Untrusted confirmation gate (`Allow <NAME> <JSON>?`), its
  four scope buttons, or the `ApprovalCache`/`ApprovalScope` machinery.
- No `multiple` (multi-select) mode in this iteration — single-pick only
  (matches hermes-agent; opencode's multi-select is out of scope for now).
- No persistence of the offered choices in the transcript `meta` beyond what
  the dispatcher already records; the stock answers are part of the opcode
  input, which the dispatcher's existing audit entry already captures.
- No new opcode — `ASK_HUMAN` itself gains an optional field.
- No change to `SHOW_HUMAN`.

## 3. Existing Mechanism (What We Build On)

```
agent calls ASK_HUMAN {question}
  └─ toRun → ccPrompt caps q
       └─ channel's ccPrompt closure calls askHuman store sid q notify
            ├─ mints AskId, registers PendingAsk { paId, paSession, paQuestion, paMeta=Nothing, paSlot }
            ├─ notify qid  (web: broadcast BeAsk; Signal/Telegram: chSend the question)
            └─ blocks on paSlot (STM TMVar)
       └─ returns Right (arText reply) | Left outcome
            └─ ccPrompt maps to Text → ASK_HUMAN returns [TrpText ans]

human's reply arrives:
  web:  POST /api/sessions/:id/questions/:qid/answer  {scope: "..."}
        → handleAnswerDelivery → deliverAnswer store qid (AskReply scope label)
        → broadcasts BeAskResolved
  Signal/Telegram/CLI: next inbound message
        → deliverNextAnswer store sid body
        → delivers (AskReply ScopeOnce body) to the oldest pending ask
```

Key existing pieces:

- `Seal.Handles.AskReply` — `AskReplyStore`, `PendingAsk` (already has
  `paMeta :: Maybe Value`), `askHuman`/`askHumanWithMeta`, `deliverAnswer`,
  `deliverNextAnswer`/`deliverNextAnswerAny`, `pendingForSession`.
- `Seal.Channel.Caps.ChannelCaps` — `ccPrompt :: Text -> IO Text` is the
  seam every channel implements. Today it takes only the question text.
- `Seal.Gateway.Send.webAskCaps` — builds `ccPrompt` for the web channel;
  broadcasts `BeAsk sid {id, question}`.
- `Seal.Gateway.Stream` — encodes `BeAsk` as `{type:"ask", sessionId, ask:
  {id, question}}` over the WS.
- `Seal.Gateway.API.handleListQuestions` — returns `[{id, question,
  createdAt, meta?}]`; `handleAnswerDelivery` takes an `ApprovalScope` and
  builds `AskReply scope (approvalScopeText scope)`.
- `Seal.Channels.Loop.mkHandleCaps` / `Seal.Channels.Signal.Run` /
  `Seal.Channels.Telegram.Run` — each builds `ccPrompt` that calls
  `askHuman` with just the question text and `notify = chSend`.
- `Seal.Channels.Telegram.Transport.sendViaApi` — calls Telegram
  `sendMessage` with `{chat_id, text}` only (no `reply_markup`).
- Frontend `PendingQuestion` type (`useApi.ts:451`) — `{id, question,
  createdAt}`. `ChatArea.tsx` matches pending questions to `ToolCallBlock`s
  via the `Allow …?` regex; a pure ASK_HUMAN question renders nothing inline.

## 4. Design

### 4.1 The `StockAnswer` type + `ASK_HUMAN` schema

A new product type (in `Seal.ISA.Ops.Human` or a tiny new
`Seal.Core.Ask` module — **decision: put it in `Seal.Handles.AskReply`**
since the ask/reply store is the canonical home for ask-related types and
every channel already imports it):

```haskell
-- | One stock answer offered to the human alongside an ASK_HUMAN question.
-- The @saLabel@ is the value returned to the agent when the human picks this
-- choice; the @saDescription@ is a one-line explanation shown alongside the
-- button (may be empty). Labels MUST be non-empty and unique within one
-- question's offer set.
data StockAnswer = StockAnswer
  { saLabel       :: !Text
  , saDescription :: !Text
  } deriving stock (Eq, Show, Generic)
```

Validation (a pure `Either Text [StockAnswer]`):

- Non-empty list only if the field is present (absent ⇒ open-ended).
- 1 ≤ length ≤ 8 (8 is a generous ceiling; hermes uses 4, opencode is
  unbounded — 8 covers realistic branches without overloading a Telegram
  inline keyboard, which caps at 8 buttons per row × 8 rows but practically
  wants ≤ ~6).
- Each `saLabel` non-empty, ≤ 64 chars (Telegram callback_data is 64 bytes;
  we store the label there directly so the constraint is hard).
- Each `saDescription` ≤ 200 chars.
- Labels unique within the list (case-sensitive).

`ASK_HUMAN`'s input schema becomes:

```json
{
  "type": "object",
  "properties": {
    "question":     {"type": "string", "description": "..."},
    "stockAnswers": {
      "type": "array",
      "description": "Optional discrete choices. When present, channels render one button per choice plus an 'Other' free-text option. When absent, the question is open-ended.",
      "items": {
        "type": "object",
        "properties": {
          "label":       {"type": "string", "description": "The value returned to the agent when picked (1-5 words, concise)"},
          "description": {"type": "string", "description": "One-line explanation of the choice"}
        },
        "required": ["label"]
      },
      "maxItems": 8
    }
  },
  "required": ["question"]
}
```

`toAuthorize` validates the `question` (as today) **and** the optional
`stockAnswers` (the pure validator above).

### 4.2 Threading stock answers through the ask/reply store

`PendingAsk` already has `paMeta :: Maybe Value`. We **do not** overload
`paMeta` (it's documented as "opcode name + input for the confirmation
gate"). Instead, add a dedicated field:

```haskell
data PendingAsk = PendingAsk
  { paId          :: !AskId
  , paSession     :: !SessionId
  , paQuestion    :: !Text
  , paCreatedAt   :: !UTCTime
  , paMeta        :: !(Maybe Value)     -- unchanged (confirmation-gate metadata)
  , paStockAnswers :: ![StockAnswer]    -- NEW (empty for open-ended)
  , paSlot        :: !(TMVar (Either AskOutcome AskReply))
  }
```

A new smart constructor variant (mirrors the `askHuman`/`askHumanWithMeta`
pair):

```haskell
askHumanWithChoices
  :: AskReplyStore -> SessionId -> Text -> [StockAnswer]
  -> (AskId -> IO ())
  -> IO (Either AskOutcome Text)
```

`askHuman` and `askHumanWithMeta` delegate to the same core with
`paStockAnswers = []`. The `notify` callback now needs the stock answers
too — but rather than change the callback arity, the channel's `ccPrompt`
closure is the place that has the stock answers in scope (see §4.3), so
`notify` stays `AskId -> IO ()` and the channel's `ccPrompt` closure
broadcasts/sends the stock answers itself (it already does the
medium-specific send).

`pendingForSession` returns the stock answers alongside the existing tuple
(so the REST API can include them). We reshape the return to a record to
avoid an N-tuple:

```haskell
data PendingQuestionInfo = PendingQuestionInfo
  { pqiId          :: !AskId
  , pqiSession     :: !SessionId
  , pqiQuestion    :: !Text
  , pqiCreatedAt   :: !UTCTime
  , pqiMeta        :: !(Maybe Value)
  , pqiStockAnswers :: ![StockAnswer]
  }
pendingForSession :: AskReplyStore -> SessionId -> IO [PendingQuestionInfo]
```

### 4.3 The `ccPrompt` seam: a new `ccAsk` capability

`ChannelCaps.ccPrompt :: Text -> IO Text` is the existing seam. We have two
options:

- **(A)** Change `ccPrompt`'s arity to take a structured prompt (question +
  stock answers). Touches every channel + every test.
- **(B)** Add a new `ccAsk :: AskPrompt -> IO Text` capability, where
  `AskPrompt = AskPrompt { apQuestion :: Text, apStockAnswers ::
  [StockAnswer] }`, and keep `ccPrompt` as a backwards-compatible adapter
  (`ccPrompt q = ccAsk (AskPrompt q [])`). The default `ccAsk` delegates to
  `ccPrompt` so channels that haven't opted in still work.

**Decision: (B)** — additive, no churn to the 5 existing `ccPrompt`
implementations until they're updated to render stock answers. `ASK_HUMAN`'s
`toRun` calls `ccAsk caps (AskPrompt q stocks)` instead of `ccPrompt caps
q`. The confirmation gate's `checkConfirmation` (Loop.hs:390) keeps using
`ccPrompt` (it has no stock answers — its four scope buttons are
client-side, not agent-supplied).

`AskPrompt` lives in `Seal.Channel.Caps`:

```haskell
data AskPrompt = AskPrompt
  { apQuestion     :: !Text
  , apStockAnswers :: ![StockAnswer]
  }
```

### 4.4 The web channel

`webAskCaps` (`Send.hs:982`) gains a `ccAsk` that:

1. Calls `askHumanWithChoices store sid q stocks` (registers the pending
   ask with `paStockAnswers = stocks`).
2. In the `notify` callback, broadcasts `BeAsk sid` with the stock answers:

   ```json
   {"type":"ask","sessionId":"...","ask":{
     "id":"...","question":"...?",
     "stockAnswers":[{"label":"main","description":"the default branch"},
                     {"label":"develop","description":"..."}]
   }}
   ```

   `Seal.Gateway.Stream.sendEvent (BeAsk sid v)` is unchanged — it already
   forwards the whole `v` object.

`handleListQuestions` (`API.hs:1632`) includes `stockAnswers` in each
element (from `pqiStockAnswers`).

`handleAnswerDelivery` (`Send.hs:1082`) **generalizes**: today it takes an
`ApprovalScope` and builds `AskReply scope (approvalScopeText scope)`. For
ASK_HUMAN the reply is the human's chosen text (a stock label or a typed
"Other"), not a scope. We split the route:

- **POST .../questions/:qid/answer** body now accepts **either**
  `{"scope": "once|for_session|always|rejected"}` (confirmation gate —
  unchanged) **or** `{"answer": "<text>"}` (ASK_HUMAN — new). The handler
  detects which field is present and builds the `AskReply` accordingly:
  - `scope` present → `AskReply scope (approvalScopeText scope)` (today's
    behavior).
  - `answer` present → `AskReply ScopeOnce answer` (the reply text is the
    answer; scope is `ScopeOnce` since ASK_HUMAN replies are never cached).
  - both/none → 400.

`AskReply.arText` already carries arbitrary text, so no change to the store.

### 4.5 The frontend

Extend `PendingQuestion` (`useApi.ts:451`):

```ts
export interface StockAnswer {
  label: string
  description?: string
}
export interface PendingQuestion {
  id: string
  question: string
  createdAt: string
  meta?: unknown
  stockAnswers?: StockAnswer[]
}
```

The WS `ask` event handler and `fetchPendingQuestions` already populate
`PendingQuestion` from the JSON — they pick up `stockAnswers` automatically
once the backend sends it.

New component `AskHumanForm` (in `ChatArea.tsx`, alongside
`ToolCallBlock`'s inline-approval panel). Rendered **below** the existing
`ToolCallBlock` for an ASK_HUMAN tool call that has a pending question with
stock answers. (A pending ASK_HUMAN question today only matches a
`ToolCallBlock` when its text matches the `Allow …?` regex — so we also
need to match ASK_HUMAN tool calls by opcode name. `matchesToolCall` is
extended: if the tool call's name is `ASK_HUMAN`, match any pending question
whose id hasn't already been matched; otherwise keep the regex.)

`AskHumanForm` renders:

- The question text (prominent, `--text-primary`).
- One button per stock answer: label (bold) + description (muted, below).
  Clicking calls `answerQuestion(sessionId, qid, {answer: label})` via a new
  `answerQuestionText` API helper (sister to the existing
  `answerQuestion` which posts `{scope}`).
- An "Other" textarea + Submit button. Submitting calls
  `answerQuestionText(sessionId, qid, {answer: typedText})`.
- A Cancel/dismiss button → `onCancelQuestion(qid)` (existing).
- Disabled state while the POST is in flight; on success the
  `BeAskResolved` WS event clears the question from `pendingQuestions`
  (existing path in `useTranscriptStream`).

The existing inline-approval panel (`ToolCallBlock` lines 750-769) is
untouched — it only renders for the confirmation gate (matched via the
`Allow …?` regex), which never carries `stockAnswers`.

### 4.6 Generic chat channel (Signal, CLI TUI)

`Seal.Channels.Loop.mkHandleCaps` (and `Signal.Run`'s inline `handleCaps`)
gain a `ccAsk` that:

1. Calls `askHumanWithChoices store sid q stocks`.
2. In `notify`, sends a numbered list to the peer via `chSend`:

   ```
   <question>

   1) main — the default branch
   2) develop — ...
   3) release/2.3 — ...

   Reply with a number or type your own answer.
   ```

3. The inbound path (`deliverNextAnswer`) is **unchanged for typed text**:
   if the human types `2`, the channel needs to resolve `2` → the 2nd
   stock answer's label. This resolution is added to the inbound path in
   `mkHandleCaps`'s parent loop: before calling `deliverNextAnswer`, if the
   body matches `^\d+$` and there's a pending ask with stock answers for
   this session, substitute the indexed label. This is a small new helper
   in `Seal.Handles.AskReply`:

   ```haskell
   -- | If the body is a 1-based index into the oldest pending ask's stock
   -- answers, return that label; otherwise return the body unchanged.
   resolveStockIndex :: AskReplyStore -> SessionId -> Text -> IO Text
   ```

   The loop calls `resolveStockIndex` then `deliverNextAnswer` with the
   resolved text. (For "Other" typed text, `resolveStockIndex` is a no-op.)

This keeps the generic path transport-agnostic (the loop already owns
`deliverNextAnswer`). CLI TUI gets it for free (it uses `mkHandleCaps`).

### 4.7 Telegram channel (inline keyboard)

Telegram's `sendMessage` accepts a `reply_markup` field with an
`inline_keyboard` (array of rows of buttons; each button has `text` +
`callback_data`). `callback_data` is max 64 bytes — the `saLabel` ≤ 64
chars constraint (§4.1) guarantees fit (we URL-encode only if needed; plain
ASCII labels are the norm).

`Seal.Channels.Telegram.Transport` gains:

- `tgSendWithKeyboard :: Manager -> Text -> Text -> Text -> [[TelegramButton]] -> IO ()`
  — like `sendViaApi` but includes `reply_markup: {inline_keyboard: ...}`.
- `TelegramButton = {text, callback_data}` (a small record).
- The Bot API's `getUpdates` returns `callback_query` updates (in addition
  to `message`); `tgReceive` parses them and yields the `callback_data` as
  the inbound body (with a marker so the loop knows it's a button tap, not
  typed text — but since the callback_data IS the label, the loop's
  `resolveStockIndex` + `deliverNextAnswer` path works unchanged: the label
  is delivered as the answer text).

`Seal.Channels.Telegram.Run`'s `ccAsk`:

1. Calls `askHumanWithChoices store sid q stocks`.
2. In `notify`, sends the question text via `tgSend`, then sends a second
   message (or the same message with `reply_markup`) whose inline keyboard
   has one button per stock answer (single row if ≤ 4, two rows otherwise),
   each button's `callback_data` = the label.
3. The existing `deliverNextAnswer`-on-next-inbound path handles both
   button taps (callback_query → label delivered) and typed "Other" replies
   (text delivered, `resolveStockIndex` is a no-op since typed text isn't a
   number).

### 4.8 Transcript / audit

The dispatcher's existing ACK-before-execute entry for `ASK_HUMAN` already
records the opcode name + input (including `stockAnswers`). No change — the
stock answers are part of the input `Value`, which is already audited. The
human's reply is recorded as the `OpResult.orParts` `[TrpText ans]` (the
return value of `ASK_HUMAN`), also already audited. No new transcript
entry kind.

### 4.9 Security

- Stock answers are agent-supplied display text. They are never executed,
  never interpolated into a shell command, never written to disk. They
  flow: agent input `Value` → `StockAnswer` (validated) → `PendingAsk` →
  WS/API JSON → frontend/Telegram. No `AuthorizedCommand`, no `SafePath`.
- The `saLabel` reaches Telegram's `callback_data` (64-byte limit enforced
  at validation). A malicious label can't escape the inline keyboard (it's
  a display string); the worst it can do is mislead the human.
- The human's chosen reply is `AskReply.arText` → `ASK_HUMAN`'s
  `OpResult` → transcript. Secret-free (no secrets are involved).
- The new `answer` body field on POST .../answer is free text from the
  human; it's delivered to the waiting `askHuman` thread and returned to the
  agent. It's not executed. Same trust posture as today's typed-reply path.

## 5. Phasing (Three Implementable Slices)

Per the user's directive: **web first, then generic chat, then Telegram.**
Each slice is independently shippable.

### Slice 1 — Web (the minimum viable stock-answers UI)

- `StockAnswer` type + validation (`Seal.Handles.AskReply`).
- `AskPrompt` + `ccAsk` capability (`Seal.Channel.Caps`); `ccPrompt`
  delegates to `ccAsk` with empty stock answers (default).
- `askHumanWithChoices`; `PendingAsk.paStockAnswers`; `PendingQuestionInfo`;
  `pendingForSession` returns the record.
- `ASK_HUMAN.toRun` calls `ccAsk`; `toAuthorize` validates `stockAnswers`.
- `webAskCaps.ccAsk` broadcasts `BeAsk` with `stockAnswers`.
- `handleListQuestions` includes `stockAnswers`.
- POST .../answer accepts `{answer}` (in addition to `{scope}`).
- Frontend `StockAnswer` type; `AskHumanForm` component; `matchesToolCall`
  extended for ASK_HUMAN; `answerQuestionText` helper.
- Tests: opcode validation (QuickCheck), ask/reply store round-trip with
  stock answers, API JSON shape, frontend render + click + "Other".

### Slice 2 — Generic chat channel (Signal, CLI TUI)

- `mkHandleCaps`/`Signal.Run` `ccAsk` renders numbered list.
- `resolveStockIndex` helper; inbound path resolves before
  `deliverNextAnswer`.
- Tests: numbered-list render, index resolution, "Other" pass-through,
  end-to-end ask→notify→deliver with stock answers.

### Slice 3 — Telegram inline keyboard

- `tgSendWithKeyboard`; `TelegramButton`; `tgReceive` parses
  `callback_query`.
- `Telegram.Run` `ccAsk` sends question + inline keyboard.
- Tests: keyboard JSON shape, callback_query parsing, label delivery
  (guarded `pendingWith` if no real bot token).

## 6. Testing Strategy

- **Pure / QuickCheck** (`Seal.Handles.AskReplySpec`):
  - `StockAnswer` validation: length bounds, label non-empty + ≤64, label
    uniqueness, description ≤200. Generator: `genStockAnswers` bounded to
    1-8 elements, labels from a small alphabet.
- **ISA** (`Seal.ISA.Ops.HumanSpec`):
  - `ASK_HUMAN` with `stockAnswers` authorizes + runs; absent
    `stockAnswers` still works; invalid `stockAnswers` → `Left`.
- **API** (`Seal.Gateway.ApiSpec`):
  - `GET .../questions` includes `stockAnswers` when present.
  - `POST .../answer` with `{answer}` delivers the text;
    `{scope}` still works; both/none → 400.
- **Frontend** (`ChatArea` tests, Vitest):
  - `AskHumanForm` renders one button per stock answer + "Other" textarea.
  - Clicking a stock button POSTs `{answer: label}`.
  - Typing + submitting POSTs `{answer: typed}`.
  - `BeAskResolved` clears the form.
- **Channel loops** (`Seal.Channels.LoopSpec`, `Signal.RunSpec`):
  - `ccAsk` sends a numbered list; inbound `2` resolves to the 2nd label.
- **Telegram** (`Telegram.RunSpec` / `TransportSpec`):
  - `tgSendWithKeyboard` includes `reply_markup.inline_keyboard`.
  - `callback_query` parse → label delivered. (Real-bot test guarded with
    `pendingWith "requires Telegram bot token"`.)

## 7. Open Questions (for the review gate)

1. **`maxItems` for `stockAnswers`** — 8 is a guess. Telegram inline
   keyboards cap at 8×8; hermes uses 4; opencode is unbounded. 8 is a
   reasonable middle ground. Reviewers: is 8 right, or should we go 6?
2. **`AskPrompt` location** — `Seal.Channel.Caps` (co-located with
   `ChannelCaps`) vs a new `Seal.Core.Ask`. Leaning `Channel.Caps` since
   `AskPrompt` is only used at the channel seam.
3. **`paStockAnswers` field name** — `paStockAnswers` is verbose but clear;
   `paChoices`/`paOptions` are shorter. House style favors descriptiveness;
   leaning `paStockAnswers` to match the user's "stock answers" vocabulary.
4. **`matchesToolCall` extension** — matching ASK_HUMAN tool calls by
   opcode name (not the `Allow …?` regex) is a behavior change: today, a
   pending ASK_HUMAN question that *doesn't* match the regex renders
   nothing inline. After Slice 1, it renders the `AskHumanForm` (if it has
   stock answers) or still nothing (if open-ended). Is that the desired
   behavior, or should open-ended ASK_HUMAN also render an inline "type your
   answer" affordance? (Out of scope for this design — but worth flagging.)

## 8. Acceptance Criteria

1. **AC1** — `ASK_HUMAN` accepts an optional `stockAnswers` array of
   `{label, description}` objects; absent ⇒ open-ended (today's behavior).
2. **AC2** — Invalid `stockAnswers` (empty list, >8, empty label, label
   >64 chars, duplicate labels) → `toAuthorize` returns `Left`, the opcode
   does not run, the dispatcher records the rejection.
3. **AC3** — A pending ASK_HUMAN with `stockAnswers` is surfaced over the
   WS `ask` event and the `GET .../questions` REST route with the
   `stockAnswers` field.
4. **AC4** — The web frontend renders an `AskHumanForm` with one button
   per stock answer (label + description) and an "Other" textarea;
   clicking a button or submitting "Other" POSTs `{answer: <text>}` and
   unblocks the agent loop with the chosen text.
5. **AC5** — The existing Untrusted confirmation gate (four scope buttons)
   is unchanged; its `Allow <NAME> <JSON>?` questions still render the
   inline-approval panel and POST `{scope}`.
6. **AC6** — POST .../answer accepts `{scope}` (unchanged) and `{answer}`
   (new); both/none → 400.
7. **AC7** — The generic chat channel (Signal, CLI TUI) renders a numbered
   list of stock answers; a numeric inbound reply resolves to the indexed
   label; a non-numeric reply is delivered as-is ("Other").
8. **AC8** — The Telegram channel renders an inline keyboard with one
   button per stock answer; a button tap delivers the label; a typed reply
   is delivered as-is ("Other").
9. **AC9** — `cabal build all` is `-Werror` clean; `cabal test` green
   (including new QuickCheck properties + Vitest); `hlint src/ test/` clean.
10. **AC10** — No change to `ApprovalScope`/`ApprovalCache`/`checkConfirmation`/
    `recordApproval` (the confirmation gate is untouched).

## 9. File Scope (Slice 1 — Web)

**Haskell (src):**
- `Seal.Handles.AskReply` — `StockAnswer`, `AskReply`/`PendingAsk` field,
  `askHumanWithChoices`, `PendingQuestionInfo`, `pendingForSession` reshape,
  `resolveStockIndex` (Slice 2).
- `Seal.Channel.Caps` — `AskPrompt`, `ccAsk` field, default delegation.
- `Seal.ISA.Ops.Human` — `stockAnswers` schema + `toAuthorize` +
  `toRun` uses `ccAsk`.
- `Seal.Gateway.Send` — `webAskCaps.ccAsk` broadcasts stock answers;
  `handleAnswerDelivery` generalizes to `{answer}`.
- `Seal.Gateway.API` — `handleListQuestions` includes `stockAnswers`;
  answer-route body parsing accepts `{answer}`.

**Haskell (test):**
- `Seal.Handles.AskReplySpec` — validation + round-trip (new or extend).
- `Seal.ISA.Ops.HumanSpec` — stock-answers authorize/run (extend).
- `Seal.Gateway.ApiSpec` — questions JSON + answer route (extend).

**Frontend (src):**
- `hooks/useApi.ts` — `StockAnswer` type, `PendingQuestion.stockAnswers`,
  `answerQuestionText` helper.
- `components/ChatArea.tsx` — `AskHumanForm` component; `matchesToolCall`
  ASK_HUMAN branch; wire into `MessageBlock`/`ChatMessage`.

**Frontend (test):**
- `components/__tests__/ChatArea.test.tsx` (or new `AskHumanForm.test.tsx`)
  — render, click, "Other", dismiss.

**Cabal:** add new modules to `exposed-modules` / `other-modules` as needed.

## 10. Risks

- **`ccPrompt` arity drift** — avoided by adding `ccAsk` (option B) rather
  than changing `ccPrompt`. Channels that don't implement `ccAsk` fall back
  to `ccPrompt` (open-ended behavior) — a safe degradation.
- **Telegram `callback_data` 64-byte limit** — enforced at validation
  (`saLabel` ≤ 64 chars). A future label with non-ASCII could exceed 64
  *bytes* even under 64 *chars*; the validator counts chars (Haskell
  `Text.length` is in `Data.Text` length = code points, not bytes). We
  validate bytes explicitly: `BS.length (TE.encodeUtf8 label) <= 64`.
- **`matchesToolCall` behavior change** — today a non-matching pending
  ASK_HUMAN renders nothing inline; after Slice 1, an ASK_HUMAN *with
  stock answers* renders the form. This is the desired behavior (the whole
  point). An ASK_HUMAN *without* stock answers still renders nothing
  inline (the human types into the composer as today).
- **Answer-route ambiguity** — `{scope}` vs `{answer}`. We detect by field
  presence; a body with both is a 400. This is unambiguous and
  backward-compatible (the confirmation gate only ever sends `{scope}`).

## 11. References

- opencode question schema: `packages/schema/src/question.ts`
- opencode web question dock:
  `packages/app/src/pages/session/composer/session-question-dock.tsx`
- opencode TUI question prompt:
  `packages/tui/src/routes/session/question.tsx`
- hermes-agent clarify tool: `tools/clarify_tool.py`
- hermes-agent clarify release notes: `RELEASE_v0.14.0.md` (native buttons
  on Telegram/Discord)
- Seal current ASK_HUMAN: `src/Seal/ISA/Ops/Human.hs`
- Seal ask/reply store: `src/Seal/Handles/AskReply.hs`
- Seal web ask caps: `src/Seal/Gateway/Send.hs:982`
- Seal frontend pending questions: `frontend/src/hooks/useApi.ts:451`,
  `frontend/src/components/ChatArea.tsx:750` (approval panel),
  `:836` (`matchesToolCall`)