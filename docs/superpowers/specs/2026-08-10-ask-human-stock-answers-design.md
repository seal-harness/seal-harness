# ASK_HUMAN Stock Answers (Channel-Portable Multiple-Choice Questions)

**Issue**: https://github.com/seal-harness/seal-harness/issues/91
**Branch**: `feat/ask-human-stock-answers`
**Date**: 2026-08-10 (rev 2 — gate-approved with changes)
**Status**: Design — gate-approved (5× APPROVE-WITH-CHANGES, all blocking concerns folded into rev 2)

**Gate history (rev 1 → rev 2):**
- **PM**: APPROVE-WITH-CHANGES — add cancel/timeout use cases + ACs; address open-ended ASK_HUMAN invisibility; rename `stockAnswers`→`options`. → rev 2 adds cancel/timeout ACs (AC11/AC12), renames to `options` throughout, adds open-ended inline affordance as a planned follow-up (§7.4).
- **Architect**: APPROVE-WITH-CHANGES — 6 compile/runtime issues. → rev 2: enumerates `AskReplySpec.hs` + `handleListQuestions` in file scope; adopts **option A** (`ccPrompt` arity change, per user decision — drops `ccAsk` entirely); folds `resolveStockIndex` into `deliverNextAnswer` (single STM transaction); binds Telegram `callback_data` to `AskId`; specifies `matchesToolCall` as oldest-unmatched.
- **Designer**: APPROVE-WITH-CHANGES — 2 blocking (WS `ask` handler, error states) + 3 to specify. → rev 2: adds explicit `useTranscriptStream.ts:148` code change; adds error/already-resolved/race handling; specifies keyboard interaction (Enter/Escape), vertical button layout, form placement (inside `ToolCallBlock`).
- **Security**: APPROVE-WITH-CHANGES — 2 Medium integrity issues. → rev 2: `callback_data`=`AskId` (not label) fixes cross-ask collision; `resolveStockIndex` folded into `deliverNextAnswer` with explicit numeric edge-case handling; forbids `parse_mode`; explicit both-reject in `parseAnswerBody`; `AskHumanForm` render condition guarded by `stockAnswers.length > 0`.
- **CTO**: APPROVE-WITH-CHANGES — strategic priority challenge. → **User decision**: build the full design now; mark Phase 8 "more chat channels" as done in the roadmap (UX dial-in is the priority). CTO's `ccPrompt`-arity (option A) + simpler-schema recommendations: option A adopted; simpler schema **not** adopted (user chose `{label, description}` max 8).

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
- Each `saLabel` non-empty, ≤ 64 **bytes** (Telegram `callback_data` is 64
  bytes; we validate `BS.length (TE.encodeUtf8 label) <= 64` so non-ASCII
  labels are bounded correctly — `Data.Text.length` counts code points, not
  bytes).
- Each `saDescription` ≤ 200 chars.
- Labels unique within the list (case-sensitive).

**Terminology (gate decision):** the JSON schema field is `options` (not
`stockAnswers`), and the Haskell type is `QuestionOption` (not
`StockAnswer`), aligning with opencode's `Question.Option` and reducing
cognitive load for agent authors. The `PendingAsk` field is `paOptions`.
This rev 2 rename applies throughout the design.

`ASK_HUMAN`'s input schema becomes:

```json
{
  "type": "object",
  "properties": {
    "question": {"type": "string", "description": "The question to present to the human operator."},
    "options": {
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
`options` (the pure validator above). `QuestionOption` gets
`ToJSON`/`FromJSON` instances via `Generic` (deriving
`genericToJSON`/`genericParseJSON` with the `qo` prefix stripped) so the WS
broadcast, REST API, and transcript audit all share one serialization shape
(no hand-rolled JSON drift across 3 sites).

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
  , paOptions     :: ![QuestionOption]  -- NEW (empty for open-ended)
  , paSlot        :: !(TMVar (Either AskOutcome AskReply))
  }
```

A new smart constructor variant (mirrors the `askHuman`/`askHumanWithMeta`
pair):

```haskell
askHumanWithOptions
  :: AskReplyStore -> SessionId -> Text -> [QuestionOption]
  -> (AskId -> IO ())
  -> IO (Either AskOutcome Text)
```

`askHuman` and `askHumanWithMeta` delegate to the same core with
`paOptions = []`. The `notify` callback stays `AskId -> IO ()` — the
channel's `ccPrompt` closure has the options in scope (see §4.3) and does
the medium-specific broadcast/send itself.

`pendingForSession` returns the options alongside the existing fields. We
reshape the return from the 4-tuple to a record to avoid an N-tuple
(**gate note (Architect #1):** this breaks 11 deconstruction sites in
`test/Seal/Handles/AskReplySpec.hs` + the `handleListQuestions`
pattern-match in `API.hs:1643` — both enumerated in §9 File Scope):

```haskell
data PendingQuestionInfo = PendingQuestionInfo
  { pqiId        :: !AskId
  , pqiSession   :: !SessionId
  , pqiQuestion  :: !Text
  , pqiCreatedAt :: !UTCTime
  , pqiMeta      :: !(Maybe Value)
  , pqiOptions   :: ![QuestionOption]
  }
pendingForSession :: AskReplyStore -> SessionId -> IO [PendingQuestionInfo]
```

### 4.3 The `ccPrompt` seam: change arity (option A, gate decision)

`ChannelCaps.ccPrompt :: Text -> IO Text` is the existing seam. **Gate
decision (user + CTO): option A** — change `ccPrompt`'s arity to take a
structured prompt. This is a one-time migration cost (pre-alpha, 5 channel
implementations + tests) in exchange for a single clean seam with no
long-term maintenance tax (option B's `ccAsk`+`ccPrompt` coexistence is
avoided).

New signature:

```haskell
data AskPrompt = AskPrompt
  { apQuestion :: !Text
  , apOptions  :: ![QuestionOption]
  }

data ChannelCaps = ChannelCaps
  { ccSend         :: Text -> IO ()
  , ccPrompt       :: AskPrompt -> IO Text   -- arity changed (was Text -> IO Text)
  , ccPromptSecret :: Text -> IO Text
  , ccStreaming    :: Bool
  }
```

`AskPrompt` lives in `Seal.Channel.Caps` (co-located with `ChannelCaps`;
`Seal.Core.Ask` would over-modularize one type).

**Migration scope (all `ccPrompt` construction + call sites):**
- `Seal.Channel.Caps` — the `Default` instance (`ccPrompt = \_ -> pure ""`
  becomes `ccPrompt = \_ -> pure ""` — the `AskPrompt` arg is ignored, same
  no-op).
- `Seal.ISA.Ops.Human.askHumanOp` — `toRun` calls `ccPrompt caps
  (AskPrompt q opts)` (was `ccPrompt caps q`).
- `Seal.Agent.Loop.checkConfirmation` (Loop.hs:390) — builds
  `AskPrompt (buildConfirmationPrompt opName' input') []` (the confirmation
  gate has no options; its four scope buttons are client-side).
- `Seal.Gateway.Send.webAskCaps` (Send.hs:984) — `ccPrompt` closure updated.
- `Seal.Channels.Loop.mkHandleCaps` (Loop.hs:431) — `ccPrompt` closure
  updated.
- `Seal.Channels.Signal.Run` (Signal.Run.hs:116) — `ccPrompt` closure
  updated.
- `Seal.Channel.Cli` (Cli.hs:621) — `ccPrompt` closure updated.
- `Seal.Channels.Telegram.Run` — `ccPrompt` closure updated (Slice 3).
- `Seal.Vault.Commands` (Vault/Commands.hs:312) + `Seal.Command.Provider`
  (Provider.hs:165, :181) — these call `ccPromptSecret` (unchanged), not
  `ccPrompt`, so no edit. (Verify during implementation.)
- Test sites: `test/Seal/Channels/LoopSpec.hs` (8 `newChannelDeps` calls),
  `test/Seal/Gateway/SendSpec.hs`, `test/Seal/Gateway/ApiSpec.hs`,
  `test/Seal/Handles/AskReplySpec.hs` — any `def { ccPrompt = ... }` or
  `ccPrompt caps q` call site updated.
  }
```

### 4.4 The web channel

`webAskCaps` (`Send.hs:982`) `ccPrompt` closure (now `AskPrompt -> IO Text`):

1. Calls `askHumanWithOptions store sid q opts` (registers the pending
   ask with `paOptions = opts`).
2. In the `notify` callback, broadcasts `BeAsk sid` with the options:

   ```json
   {"type":"ask","sessionId":"...","ask":{
     "id":"...","question":"...?",
     "options":[{"label":"main","description":"the default branch"},
                {"label":"develop","description":"..."}]
   }}
   ```

   `Seal.Gateway.Stream.sendEvent (BeAsk sid v)` is unchanged — it already
   forwards the whole `v` object.

`handleListQuestions` (`API.hs:1632`) includes `options` in each element
(from `pqiOptions`). The `questionJson` helper (API.hs:1643) is rewritten to
deconstruct `PendingQuestionInfo` accessors (`pqiId`/`pqiQuestion`/`pqiCreatedAt`/`pqiMeta`/`pqiOptions`)
instead of the 4-tuple pattern-match.

`handleAnswerDelivery` (`Send.hs:1082`) **generalizes**: today it takes an
`ApprovalScope` and builds `AskReply scope (approvalScopeText scope)`. For
ASK_HUMAN the reply is the human's chosen text (an option label or a typed
"Other"), not a scope. We split the route handler + add a sibling deliverer:

- **POST .../questions/:qid/answer** body now accepts **either**
  `{"scope": "once|for_session|always|rejected"}` (confirmation gate —
  unchanged) **or** `{"answer": "<text>"}` (ASK_HUMAN — new).
- **`parseAnswerBody`** (new, replaces `parseScopeBody` for this route) is
  explicit about the both-reject branch (gate: Security #6):
  ```haskell
  parseAnswerBody :: BL.ByteString -> Either Text (Either ApprovalScope Text)
  parseAnswerBody body =
    -- decode JSON object; check exactly one of {scope}/{answer} present
    -- both present → Left "ambiguous: send either {scope} or {answer}, not both"
    -- neither     → Left "missing 'scope' or 'answer' field"
    -- scope only  → Right (Left scope)   (after parseApprovalScope)
    -- answer only → Right (Right answerText)
  ```
- The route handler (`API.hs:269-283`) branches on `parseAnswerBody`:
  - `Left (scope)` → existing `handleAnswerDelivery deps sId qid scope`
    (unchanged, builds `AskReply scope (approvalScopeText scope)`).
  - `Right (answerText)` → new
    `handleAnswerTextDelivery deps sId qid answerText`
    (builds `AskReply ScopeOnce answerText`; broadcasts `BeAskResolved`).
  - `Left parseErr` → 400.

`AskReply.arText` already carries arbitrary text, so no change to the store.

### 4.5 The frontend

Extend `PendingQuestion` (`useApi.ts:451):

```ts
export interface QuestionOption {
  label: string
  description?: string
}
export interface PendingQuestion {
  id: string
  question: string
  createdAt: string
  meta?: unknown
  options?: QuestionOption[]
}
```

**Gate-critical (Designer #1): the WS `ask` event handler does NOT pick up
`options` automatically.** `useTranscriptStream.ts:148` manually constructs
only 3 fields today:
```ts
return [...prev, { id: ask.id, question: ask.question, createdAt: new Date().toISOString() }]
```
This must be updated to spread the full payload:
```ts
return [...prev, {
  id: ask.id,
  question: ask.question,
  createdAt: new Date().toISOString(),
  options: ask.options,
  meta: ask.meta,
}]
```
The `AskEvent` type in `streamClient.ts` must also be extended with
`options?: QuestionOption[]` + `meta?: unknown`. (`fetchPendingQuestions`
at `useApi.ts:464` does a direct JSON cast and picks up the fields
automatically — only the live WS path needs the explicit change.)

New component `AskHumanForm` (in `ChatArea.tsx`, alongside
`ToolCallBlock`'s inline-approval panel). **Render placement (Designer #6):**
inside the expanded `ToolCallBlock`, in the same slot as the inline-approval
panel (after the Input display, before the "Awaiting result" placeholder) —
NOT as a sibling below the block. It is mutually exclusive with the
inline-approval panel (the approval panel renders for confirmation-gate
questions matched via the `Allow …?` regex; `AskHumanForm` renders for
ASK_HUMAN questions with options).

**Render condition (gate: Security #5):** `AskHumanForm` renders iff
`opcode === "ASK_HUMAN" && pendingQuestion.options?.length > 0` — the
`options.length > 0` guard prevents the confirmation gate (which is also
`ASK_HUMAN` by opcode name but has no `options`) from rendering the form.

`matchesToolCall` extension (gate: Architect #6): match ASK_HUMAN tool calls
by opcode name, **oldest-unmatched** (creation order), not "any unmatched."
If two ASK_HUMAN tool calls are pending, the oldest pending question
matches the oldest pending ASK_HUMAN tool call without a match — stable
correlation by creation order.

`AskHumanForm` renders (gate: Designer #3, #4, #5):
- The question text (prominent, `--text-primary`).
- **Vertical stack** of full-width buttons (one per option): label (bold) +
  description (muted, below). NOT horizontal wrap (descriptions break the
  wrap layout). Each button is a native `<button>` (`role="radio"`,
  `aria-checked`) — focusable by Tab, activatable by Enter/Space.
- An "Other" textarea (full-width) + Submit button. **Keyboard contract:**
  Enter in the textarea submits (Shift+Enter for newline); Escape cancels
  (calls `onCancelQuestion`). The Submit button is the explicit
  affordance; Enter is the accelerator.
- A Cancel/dismiss button → `onCancelQuestion(qid)` (existing).
- Clicking a stock button calls `answerQuestionText(sessionId, qid,
  {answer: label})` via a new `answerQuestionText` API helper (sister to
  the existing `answerQuestion` which posts `{scope}`). Typing + submit
  calls `answerQuestionText(sessionId, qid, {answer: typedText})`.

**Error states (gate: Designer #2):**
- `submitting` state tracked; buttons + textarea disabled while POST in flight.
- **POST failure** (network error, non-2xx): form re-enables, inline error
  message shown ("Answer failed — try again" in `--needs-input`); human can
  retry.
- **`accepted: false`** (question already resolved): treat as success —
  dismiss the form (the question was already answered, no point retrying).
- **WS `ask_resolved` arrives while POST in flight**: the
  `useTranscriptStream` filter removes the question from state, unmounting
  the form mid-POST. The POST completes against an already-resolved
  question → `accepted: false` → treated as success (benign double-dismiss).
  No special handling needed.

**XSS (gate: Security):** `AskHumanForm` renders `saLabel`/`saDescription`
as React text children (`{label}`), never `dangerouslySetInnerHTML`. Add a
Vitest test that a label like `<img src=x onerror=alert(1)>` renders as
literal text.

**Mobile/narrow viewport:** buttons are full-width (`width: 100%`) on all
viewports; the "Other" textarea is full-width with the Submit button below
it; descriptions use `text-xs` to bound height. The `ToolCallBlock` uses
`overflow: hidden` — the form must not overflow.

The existing inline-approval panel (`ToolCallBlock` lines 750-769) is
untouched — it only renders for the confirmation gate (matched via the
`Allow …?` regex), which never carries `options`.

### 4.6 Generic chat channel (Signal, CLI TUI)

`Seal.Channels.Loop.mkHandleCaps` (and `Signal.Run`'s inline `handleCaps`)
`ccPrompt` closure (now `AskPrompt -> IO Text`):

1. Calls `askHumanWithOptions store sid q opts`.
2. In `notify`, sends a numbered list to the peer via `chSend`:

   ```
   <question>

   1) main — the default branch
   2) develop — ...
   3) release/2.3 — ...

   Reply with a number or type your own answer.
   ```

3. **Numeric resolution is folded into `deliverNextAnswer` (gate: Architect
   #4, Security #2)** — a single STM transaction eliminates the TOCTOU race
   and handles edge cases. New variant:
   ```haskell
   -- | Deliver the body as the answer to the oldest pending ask for the
   -- session. If the body (after T.strip) is a 1-based index into that
   -- ask's paOptions, substitute the indexed label. Out-of-range numbers,
   -- non-numeric text, and asks with no options are delivered as-is
   -- ("Other"). Returns (deliveredText, accepted).
   deliverNextAnswerResolved
     :: AskReplyStore -> SessionId -> Text -> IO (Text, Bool)
   ```
   **Numeric edge-case handling (Security #2):** `T.strip` first; parse as
   decimal `Int` (accept `02` → 2); if `n ∈ [1..length options]`, substitute
   the nth label; otherwise (out of range, non-numeric, or no options) deliver
   the body as-is. The human typing `99` (typo) sends `"99"` to the agent as
   a free-text answer — the agent receives `"99"` (not a label), which is
   the same posture as today's open-ended ASK_HUMAN. A QuickCheck property
   pins this: for `n ∈ [1..length stocks]` returns the nth label; for any
   other input returns the input unchanged.

The loop calls `deliverNextAnswerResolved` (replacing `deliverNextAnswer`).
CLI TUI gets it for free (it uses `mkHandleCaps`). The standalone
`resolveStockIndex` helper is NOT added (it was the racy design; the fold
into `deliverNextAnswerResolved` supersedes it).

### 4.7 Telegram channel (inline keyboard)

Telegram's `sendMessage` accepts a `reply_markup` field with an
`inline_keyboard` (array of rows of buttons; each button has `text` +
`callback_data`). `callback_data` is max 64 bytes.

**Gate-critical (Architect #5, Security #1): `callback_data` = the `AskId`,
NOT the label.** This eliminates the cross-ask label-collision ambiguity
(two pending asks with the same label → FIFO misrouts the answer). The
`AskId` is a 36-char UUID, well under 64 bytes. The Telegram inbound path
then routes by `AskId` (calling `deliverAnswer` directly, NOT
`deliverNextAnswer`'s FIFO):

- `callback_data = askIdText qid` (36 chars).
- The button `text` shown to the human = `qoLabel` (the label, not the
  description — keep buttons short; the description goes in the question
  message or a separate line above the keyboard).
- `tgReceive` parses `callback_query` updates (in addition to `message`),
  yielding the `callback_data` as the inbound body **with a marker** that
  it's a callback (so the loop knows to route by `AskId`, not FIFO). The
  loop then:
  - Parses the `callback_data` as an `AskId`.
  - Looks up the pending ask by id; resolves the label by matching the
    callback's `message.message_id` to the keyboard's message... **simpler:**
    the `callback_query` carries `data` (the `AskId`) but NOT the label. We
    need the label too. **Refined scheme:** `callback_data =
    "<shortAskIdPrefix>:<label>"` where `shortAskIdPrefix` is the first 8
    hex chars of the UUID (8 chars + `:` + label, leaving 55 bytes for the
    label — tighten the label bound to 55 bytes when this scheme is used,
    OR use the full 36-char UUID + `:` + label = 37 + label bytes, leaving
    27 for the label — too tight). **Decision: use the 8-char prefix
    scheme** (`callback_data = take 8 (askIdText qid) <> ":" <> qoLabel`),
    tighten `qoLabel` byte-bound to 55. The Telegram loop parses the
    prefix, finds the pending ask by prefix (a full `AskId` scan OR a
    prefix-indexed lookup — a linear scan over the session's pending asks
    is fine, there are typically ≤2), and calls
    `deliverAnswer store qid (AskReply ScopeOnce qoLabel)` (by-id delivery).
    A typed "Other" reply (not a callback) still goes through
    `deliverNextAnswerResolved` (FIFO + numeric resolution).

`Seal.Channels.Telegram.Transport` gains:

- `tgSendWithKeyboard :: Manager -> Text -> Text -> Text -> [[TelegramButton]] -> IO ()`
  — like `sendViaApi` but includes `reply_markup: {inline_keyboard: ...}`.
  **MUST NOT set `parse_mode`** (gate: Security #3) — the question text and
  button labels are plain text (matches existing `sendViaApi`). Documented
  in the Haddock.
- `TelegramButton = {text, callback_data}` (a small record).
- `answerCallbackQuery :: Manager -> Text -> Text -> IO ()` — the Bot API
  `answerCallbackQuery` call (gate: Architect #5b) — acknowledges the
  callback_query, stops the button's loading spinner. Called by the loop
  after delivering the answer.
- `TelegramUpdate` (`Transport.hs:74`) gains `tuCallbackData :: Maybe Text`
  + `tuCallbackId :: Maybe Text` (the callback_query id, needed for
  `answerCallbackQuery`). `parseTelegramUpdate` (`Transport.hs:219-241`) is
  restructured to handle the `callback_query` object with
  `message.chat.id` + `data` + `id` (gate: Architect #5c).

`Seal.Channels.Telegram.Run`'s `ccPrompt`:

1. Calls `askHumanWithOptions store sid q opts`.
2. In `notify`, sends the question text via `tgSend`, then sends a second
   message (or the same message with `reply_markup`) whose inline keyboard
   has one button per option (single row if ≤ 4, two rows otherwise),
   each button's `text` = `qoLabel`, `callback_data` =
   `take 8 (askIdText qid) <> ":" <> qoLabel`.
3. The inbound path branches on `tuCallbackData`:
   - `Just callbackData` (button tap) → parse `callbackData` →
     `deliverAnswer store qid (AskReply ScopeOnce qoLabel)` (by-id) →
     `answerCallbackQuery` (acknowledge the spinner).
   - `Nothing` (typed message) → `deliverNextAnswerResolved` (FIFO + numeric
     resolution, §4.6).

### 4.8 Transcript / audit

The dispatcher's existing ACK-before-execute entry for `ASK_HUMAN` already
records the opcode name + input (including `options`). No change — the
options are part of the input `Value`, which is already audited. The
human's reply is recorded as the `OpResult.orParts` `[TrpText ans]` (the
return value of `ASK_HUMAN`), also already audited. No new transcript
entry kind.

### 4.9 Security

- Options are agent-supplied display text. They are never executed, never
  interpolated into a shell command, never written to disk. They flow:
  agent input `Value` → `QuestionOption` (validated) → `PendingAsk` →
  WS/API JSON → frontend/Telegram. No `AuthorizedCommand`, no `SafePath`.
- The `qoLabel` reaches Telegram's `callback_data` (55-byte limit under the
  prefix scheme, §4.7). A malicious label can't escape the inline keyboard
  (it's a display string); the worst it can do is mislead the human.
- **`parse_mode` MUST NOT be set** on `tgSendWithKeyboard` (gate: Security
  #3) — the question text and button labels are plain text. Telegram's
  plain-text mode does not interpret markdown/HTML. This matches the
  existing `sendViaApi`.
- The human's chosen reply is `AskReply.arText` → `ASK_HUMAN`'s
  `OpResult` → transcript. Secret-free (no secrets are involved). The
  human could type a secret into the "Other" textarea — same posture as
  today's open-ended ASK_HUMAN (the human can already type a secret into
  the composer). No new leak surface.
- The new `answer` body field on POST .../answer is free text from the
  human; it's delivered to the waiting `askHuman` thread and returned to
  the agent. It's not executed. Same trust posture as today's typed-reply
  path.
- **`parseAnswerBody` explicitly rejects `{scope, answer}` (both present)**
  with 400 (gate: Security #6) — no silent delivery of `answer` with
  `scope` semantics. An API test pins this.
- **`AskHumanForm` render condition is `opcode === "ASK_HUMAN" && options.length > 0`**
  (gate: Security #5) — prevents the confirmation gate (also `ASK_HUMAN`
  by opcode name) from rendering the form. The confirmation gate never
  sets `paOptions`, so `pqiOptions = []` and the form doesn't render.
- **`paOptions` is a strict field (`![QuestionOption]`)**, set at
  `PendingAsk` construction and never mutated (verified: no `Map.adjust`
  or field update on stored `PendingAsk`s; only `insert`/`delete`/`tryPutTMVar`
  on `paSlot`). The strict field makes the "never mutated" claim
  structurally enforceable.

### 4.10 Cancel / timeout contracts (gate: PM #1, #2)

**Cancel/dismiss:** today, `cancelAsk` (`AskReply.hs:380-391`) delivers
`Left AoCancelled` to the waiting `askHuman` thread; `ccPrompt`'s closure
(`sendHuman`/`mkHandleCaps`/etc.) maps `Left _ → "rejected"` (web) or
`fromRight ""` (Signal/CLI). So the agent receives `"rejected"` (web) or
`""` (Signal/CLI) on cancel. This is **inconsistent across channels** but
unchanged by this design (ASK_HUMAN with options uses the same
`askHumanWithOptions` → `ccPrompt` path). **Documented behavior (AC11):**
on cancel/dismiss, the agent receives the same sentinel it receives today
(`"rejected"` on web, `""` on Signal/CLI). A follow-up could standardize
this to a distinguishable `OpResult` with `orIsError = True`, but that's
out of scope for this design.

**Timeout:** `askHuman`'s timeout (`arsTimeoutUs`) delivers `Left
AoTimedOut`; `ccPrompt` maps it the same way as `AoCancelled`. A late
button-tap or numeric reply after timeout is a no-op: `deliverAnswer`/
`deliverNextAnswerResolved` returns `False` (the ask is no longer in the
map), and the message routes as a normal turn (the loop's existing
fallthrough). **Documented behavior (AC12):** on timeout, the agent
receives the same sentinel as cancel; a late answer is a no-op + routes as
a normal turn.

## 5. Phasing (Three Implementable Slices)

Per the user's directive: **web first, then generic chat, then Telegram.**
Each slice is independently shippable. (Note: Slice 3 depends on the
Telegram channel, which is a Phase 8 deliverable; per the user's decision,
the "more chat channels" roadmap item is marked done — the Telegram channel
already exists, Slice 3 adds `reply_markup` to its existing `sendMessage`.)

### Slice 1 — Web (the minimum viable options UI)

- `QuestionOption` type + validation + `ToJSON`/`FromJSON`
  (`Seal.Handles.AskReply`).
- `AskPrompt` type; `ccPrompt` arity change `Text -> IO Text` →
  `AskPrompt -> IO Text` (`Seal.Channel.Caps`); migrate all 5 channel
  implementations + test sites (§4.3).
- `askHumanWithOptions`; `PendingAsk.paOptions`; `PendingQuestionInfo`;
  `pendingForSession` returns the record; migrate 11 `AskReplySpec`
  deconstruction sites + `handleListQuestions`.
- `ASK_HUMAN.toRun` calls `ccPrompt (AskPrompt q opts)`; `toAuthorize`
  validates `options`.
- `webAskCaps.ccPrompt` broadcasts `BeAsk` with `options`.
- `handleListQuestions` includes `options`; `parseAnswerBody` +
  `handleAnswerTextDelivery` + answer-route handler restructure.
- Frontend `QuestionOption` type; `AskHumanForm` component (vertical
  buttons, "Other" textarea, keyboard contract, error states); WS `ask`
  handler in `useTranscriptStream.ts:148` updated; `AskEvent` type in
  `streamClient.ts` updated; `matchesToolCall` ASK_HUMAN oldest-unmatched
  branch; `answerQuestionText` helper.
- Tests: opcode validation (QuickCheck), ask/reply store round-trip,
  `parseAnswerBody` both-reject, API JSON shape, `ccPrompt` arity migration
  compiles green, frontend render + click + "Other" + error states + XSS.

### Slice 2 — Generic chat channel (Signal, CLI TUI)

- `mkHandleCaps`/`Signal.Run` `ccPrompt` renders numbered list.
- `deliverNextAnswerResolved` (folds numeric resolution into the STM
  transaction); replaces `deliverNextAnswer` at the call sites.
- Tests: numbered-list render, `deliverNextAnswerResolved` index
  resolution + edge cases (QuickCheck), "Other" pass-through, end-to-end
  ask→notify→deliver with options.

### Slice 3 — Telegram inline keyboard

- `tgSendWithKeyboard` (no `parse_mode`); `TelegramButton`;
  `answerCallbackQuery`; `TelegramUpdate.tuCallbackData`/`tuCallbackId`;
  `parseTelegramUpdate` restructure for `callback_query`.
- `Telegram.Run` `ccPrompt` sends question + inline keyboard
  (`callback_data` = 8-char AskId prefix + `:` + label).
- Inbound path branches on `tuCallbackData` → `deliverAnswer` (by-id) +
  `answerCallbackQuery`; typed message → `deliverNextAnswerResolved`.
- Tests: keyboard JSON shape, `callback_query` parsing, by-id label
  delivery, `answerCallbackQuery` called (guarded `pendingWith` if no real
  bot token).

## 6. Testing Strategy

- **Pure / QuickCheck** (`Seal.Handles.AskReplySpec`):
  - `QuestionOption` validation: length bounds (1-8), label non-empty +
    ≤55 bytes (Telegram scheme) / ≤64 bytes (non-Telegram), label
    uniqueness, description ≤200. Generator: `genOptions` bounded to 1-8
    elements, labels from a small alphabet.
  - `deliverNextAnswerResolved`: for `n ∈ [1..length opts]` returns the nth
    label; for any other input (out of range, non-numeric, no options)
    returns the input unchanged. `T.strip` applied before parse.
- **ISA** (`Seal.ISA.Ops.HumanSpec`):
  - `ASK_HUMAN` with `options` authorizes + runs; absent `options` still
    works; invalid `options` (empty array, >8, empty label, label >64
    bytes, duplicate labels) → `Left`.
- **API** (`Seal.Gateway.ApiSpec`):
  - `GET .../questions` includes `options` when present.
  - `POST .../answer` with `{answer}` delivers the text;
    `{scope}` still works; `{scope, answer}` (both) → 400; `{}` (neither)
    → 400.
- **Frontend** (`ChatArea` tests, Vitest):
  - `AskHumanForm` renders one button per option (vertical stack) + "Other"
    textarea.
  - Clicking a stock button POSTs `{answer: label}`.
  - Typing + Enter submits POSTs `{answer: typed}`; Shift+Enter inserts
    newline; Escape cancels.
  - POST failure shows inline error; `accepted:false` dismisses; WS
    `ask_resolved` mid-POST is benign.
  - **XSS:** label `<img src=x onerror=alert(1)>` renders as literal text.
  - `useTranscriptStream.ts:148` WS handler carries `options` (live event
    picks them up, not just initial fetch).
- **Channel loops** (`Seal.Channels.LoopSpec`, `Signal.RunSpec`):
  - `ccPrompt` sends a numbered list; inbound `2` resolves to the 2nd
    label; `99` delivers `"99"` as-is; ` 2 ` (whitespace) resolves to 2nd
    label.
- **Telegram** (`Telegram.RunSpec` / `TransportSpec`):
  - `tgSendWithKeyboard` includes `reply_markup.inline_keyboard`; no
    `parse_mode` in the payload.
  - `callback_query` parse → `deliverAnswer` by-id (not FIFO); label
    resolved from the callback_data prefix.
  - `answerCallbackQuery` called after delivery.
  - Real-bot test guarded with `pendingWith "requires Telegram bot token"`.
- **ccPrompt arity migration:** `cabal build all` green confirms all 5
  channel implementations + test sites compile with the new `AskPrompt`
  arity.

## 7. Open Questions (resolved in rev 2)

1. **`maxItems`** — **8** (confirmed by all reviewers; Telegram caps at 8×8,
   hermes's 4 is too tight for branch-selection, opencode's unbounded is
   reckless for Telegram).
2. **`AskPrompt` location** — **`Seal.Channel.Caps`** (co-located with
   `ChannelCaps`; `Seal.Core.Ask` would over-modularize one type; keeping
   it out of `Core` avoids polluting security-critical vocabulary).
3. **Field name** — **`options`** (gate: PM #5, Designer) — aligns with
   opencode's `Question.Option`, clearer for agent authors than
   `stockAnswers`. Haskell type `QuestionOption`, field `paOptions`.
4. **`matchesToolCall` for open-ended ASK_HUMAN** — **deferred to a planned
   follow-up** (gate: PM #3). This design renders `AskHumanForm` only when
   `options.length > 0`. An open-ended ASK_HUMAN (no options) still renders
   nothing inline today — the human types into the composer. A follow-up
   issue will add a minimal inline "type your answer" affordance for the
   open-ended case (the `matchesToolCall` ASK_HUMAN-by-opcode-name branch is
   already in place from this design; the follow-up just renders the form
   without buttons). This is documented as a known gap, not a regression.

## 8. Acceptance Criteria

1. **AC1** — `ASK_HUMAN` accepts an optional `options` array of
   `{label, description}` objects; absent ⇒ open-ended (today's behavior).
2. **AC2** — Invalid `options` (empty list, >8, empty label, label >64
   bytes, duplicate labels) → `toAuthorize` returns `Left`, the opcode
   does not run, the dispatcher records the rejection.
3. **AC3** — A pending ASK_HUMAN with `options` is surfaced over the WS
   `ask` event (with `options` field) and the `GET .../questions` REST
   route (with `options` field). The live WS path
   (`useTranscriptStream.ts:148`) carries `options` (not just the initial
   fetch).
4. **AC4** — The web frontend renders an `AskHumanForm` (inside the
   expanded `ToolCallBlock`, vertical stack of full-width buttons) with one
   button per option (label + description) and an "Other" textarea;
   clicking a button or submitting "Other" POSTs `{answer: <text>}` and
   unblocks the agent loop with the chosen text. Keyboard: Enter submits
   the textarea, Escape cancels. POST failure shows an inline error;
   `accepted:false` dismisses; WS `ask_resolved` mid-POST is benign.
5. **AC5** — The existing Untrusted confirmation gate (four scope buttons)
   is unchanged; its `Allow <NAME> <JSON>?` questions still render the
   inline-approval panel and POST `{scope}`. The `AskHumanForm` does NOT
   render for the confirmation gate (guarded by `options.length > 0`).
6. **AC6** — POST .../answer accepts `{scope}` (unchanged) and `{answer}`
   (new); `{scope, answer}` (both) → 400; `{}` (neither) → 400
   (`parseAnswerBody` explicit both-reject).
7. **AC7** — The generic chat channel (Signal, CLI TUI) renders a numbered
   list of options; a numeric inbound reply (after `T.strip`, `n ∈
   [1..length opts]`) resolves to the indexed label via
   `deliverNextAnswerResolved` (single STM transaction, no TOCTOU race); a
   non-numeric or out-of-range reply is delivered as-is ("Other").
8. **AC8** — The Telegram channel renders an inline keyboard with one
   button per option; `callback_data` = 8-char `AskId` prefix + `:` +
   label; a button tap routes via `deliverAnswer` (by-id, NOT FIFO) +
   `answerCallbackQuery` acknowledges the spinner; a typed reply routes
   via `deliverNextAnswerResolved`. `tgSendWithKeyboard` does NOT set
   `parse_mode`.
9. **AC9** — `cabal build all` is `-Werror` clean (the `ccPrompt` arity
   migration compiles across all 5 channels + tests); `cabal test` green
   (including new QuickCheck properties + Vitest); `hlint src/ test/` clean.
10. **AC10** — No change to `ApprovalScope`/`ApprovalCache`/
    `checkApproval`/`recordApproval` (the confirmation gate is untouched).
11. **AC11 (gate: PM #1)** — When the human dismisses an ASK_HUMAN with
    options, the agent receives the same sentinel it receives today
    (`"rejected"` on web, `""` on Signal/CLI) — consistent with today's
    open-ended dismiss behavior. Documented (not a new contract).
12. **AC12 (gate: PM #2)** — When an ASK_HUMAN with options times out, the
    agent receives the same sentinel as cancel; a late button-tap or
    numeric reply is a no-op (`deliverAnswer`/`deliverNextAnswerResolved`
    returns `False`) and routes as a normal turn.
13. **AC13 (gate: Security #5)** — `AskHumanForm` renders iff
    `opcode === "ASK_HUMAN" && pendingQuestion.options?.length > 0` —
    prevents the confirmation gate (also `ASK_HUMAN` by opcode name) from
    rendering the form.
14. **AC14 (gate: Architect #6)** — `matchesToolCall` ASK_HUMAN matching is
    oldest-unmatched (creation order), not "any unmatched" — stable
    correlation when ≥2 ASK_HUMAN tool calls are pending.

## 9. File Scope (Slice 1 — Web)

**Haskell (src):**
- `Seal.Handles.AskReply` — `QuestionOption` type + `ToJSON`/`FromJSON`;
  `PendingAsk.paOptions` field; `askHumanWithOptions`;
  `PendingQuestionInfo` record; `pendingForSession` reshape (returns record
  instead of 4-tuple); `deliverNextAnswerResolved` (Slice 2, folds numeric
  resolution into the STM transaction).
- `Seal.Channel.Caps` — `AskPrompt` type; `ccPrompt` arity change
  (`Text -> IO Text` → `AskPrompt -> IO Text`); `Default` instance update.
- `Seal.ISA.Ops.Human` — `options` schema + `toAuthorize` validation +
  `toRun` calls `ccPrompt (AskPrompt q opts)`.
- `Seal.Agent.Loop` — `checkConfirmation` builds `AskPrompt` with empty
  options (the confirmation gate has no options).
- `Seal.Gateway.Send` — `webAskCaps.ccPrompt` broadcasts `BeAsk` with
  `options`; `handleAnswerTextDelivery` (new, builds `AskReply ScopeOnce
  answer`); `parseAnswerBody` (new, replaces `parseScopeBody` for this
  route, explicit both-reject).
- `Seal.Gateway.API` — `handleListQuestions` rewritten to deconstruct
  `PendingQuestionInfo` accessors (not the 4-tuple); answer-route handler
  restructured to branch on `parseAnswerBody` → `handleAnswerDelivery`
  (scope) or `handleAnswerTextDelivery` (answer).
- `Seal.Channels.Loop` — `mkHandleCaps.ccPrompt` closure updated
  (arity change; Slice 2 adds numbered-list rendering).
- `Seal.Channels.Signal.Run` — `handleCaps.ccPrompt` closure updated
  (arity change; Slice 2 adds numbered-list rendering).
- `Seal.Channel.Cli` — `ccPrompt` closure updated (arity change).

**Haskell (test) — gate: Architect #1:**
- `test/Seal/Handles/AskReplySpec.hs` — **migrate 11 deconstruction sites**
  (lines 24, 48, 82, 110, 124, 149, 156, 167, 209, 231, 251, 265 — the 4-tuple
  pattern-matches become `PendingQuestionInfo` accessors); validation +
  round-trip tests for `QuestionOption`; `deliverNextAnswerResolved`
  QuickCheck properties.
- `test/Seal/ISA/Ops/HumanSpec.hs` — `options` authorize/run (extend).
- `test/Seal/Gateway/ApiSpec.hs` — questions JSON includes `options`;
  answer route `{answer}` / `{scope}` / both → 400 / neither → 400
  (extend). The 4 `SendDeps` literals at lines 2836, 2925, 3046, 3152 may
  need `ccPrompt` arity updates if they construct `ChannelCaps`.
- `test/Seal/Channels/LoopSpec.hs` — the 8 `newChannelDeps` calls (lines
  132, 191, 306, 346, 459, 515, 563, 603) need `ccPrompt` arity updates if
  they override `ccPrompt`.
- `test/Seal/Gateway/SendSpec.hs` — the `SendDeps` literal (~line 91) may
  need a `ccPrompt` arity update.

**Frontend (src):**
- `hooks/useApi.ts` — `QuestionOption` type, `PendingQuestion.options`,
  `answerQuestionText` helper (POSTs `{answer}`).
- `hooks/useTranscriptStream.ts:148` — **gate-critical (Designer #1):**
  update the WS `ask` handler to spread the full payload (`options`,
  `meta`), not just `id`/`question`/`createdAt`.
- `lib/streamClient.ts` — `AskEvent` type extended with
  `options?: QuestionOption[]` + `meta?: unknown`.
- `components/ChatArea.tsx` — `AskHumanForm` component (vertical buttons,
  "Other" textarea, keyboard contract, error states, XSS-safe text
  children); `matchesToolCall` ASK_HUMAN oldest-unmatched branch;
  `AskHumanForm` render condition `opcode === "ASK_HUMAN" && options.length > 0`;
  wire into `ToolCallBlock` (inside the expanded block, same slot as the
  inline-approval panel).

**Frontend (test):**
- `components/__tests__/ChatArea.test.tsx` (or new `AskHumanForm.test.tsx`)
  — render (vertical stack), click stock button POSTs `{answer: label}`,
  "Other" textarea + Enter submits + Shift+Enter newline + Escape cancels,
  POST failure inline error, `accepted:false` dismisses, WS `ask_resolved`
  mid-POST benign, XSS (`<img src=x onerror=alert(1)>` renders as text),
  WS handler carries `options`.

**Cabal:** add new modules to `exposed-modules` / `other-modules` as needed.

## 10. Risks

- **`ccPrompt` arity migration (gate: Architect #2, CTO)** — option A
  (change arity) touches all 5 channel implementations + test sites
  simultaneously. This is a one-time pre-alpha migration cost; `cabal
  build all` green is the gate (AC9). The long-term benefit is one clean
  seam (no `ccAsk`/`ccPrompt` coexistence maintenance tax).
- **`pendingForSession` reshape breaks 11 test deconstruction sites +
  `handleListQuestions`** (gate: Architect #1) — enumerated in §9 File
  Scope. The record is cleaner long-term than a 5-tuple.
- **Telegram `callback_data` 64-byte limit** — under the 8-char-prefix
  scheme (`<8hex>:<label>`), the label bound tightens to 55 bytes. We
  validate bytes explicitly: `BS.length (TE.encodeUtf8 label) <= 55` when
  the Telegram scheme is used (≤64 bytes otherwise). Non-ASCII labels are
  bounded correctly (byte count, not char count).
- **`matchesToolCall` behavior change** — today a non-matching pending
  ASK_HUMAN renders nothing inline; after Slice 1, an ASK_HUMAN *with
  options* renders the form. This is the desired behavior (the whole
  point). An ASK_HUMAN *without options* still renders nothing inline (the
  human types into the composer as today) — documented as a known gap
  (§7.4) with a planned follow-up.
- **Answer-route ambiguity** — `{scope}` vs `{answer}`. `parseAnswerBody`
  detects by field presence and explicitly rejects both-present with 400
  (gate: Security #6). Unambiguous and backward-compatible (the
  confirmation gate only ever sends `{scope}`).
- **Cross-ask label collision (gate: Architect #5, Security #1)** —
  resolved by binding Telegram `callback_data` to the `AskId` prefix (not
  the label) and routing button taps via `deliverAnswer` (by-id, not
  FIFO). Typed "Other" replies still use `deliverNextAnswerResolved`
  (FIFO + numeric resolution).
- **`resolveStockIndex` TOCTOU race (gate: Architect #4, Security #2)** —
  resolved by folding numeric resolution into `deliverNextAnswerResolved`
  (single STM transaction; no double-read).
- **Concurrent pending asks on Telegram** — the `AskId`-prefix scheme
  means each button tap routes to the correct ask (by id), even when ≥2
  asks are pending. FIFO only applies to typed replies (which are
  inherently ambiguous with ≥2 pending asks — documented as a known
  limitation of async chat channels, same as today).
- **Channel asymmetry (gate: CTO)** — Slice 1 (web) ships before Slices
  2/3. The web has the rich button UI; Signal/CLI/Telegram render the
  plain question (no numbered list/keyboard) until their slice ships. This
  is a temporary asymmetry, documented in the phasing. The agent's
  `ASK_HUMAN {question, options}` call works on all channels immediately
  (the options are carried through `paOptions` regardless of whether the
  channel renders them); only the rendering differs.

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