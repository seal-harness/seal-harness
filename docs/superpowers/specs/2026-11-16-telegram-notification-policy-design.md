# Telegram notification policy — Design (Rev 5)

> **Operator requirement**: apply the same notification reduction to Telegram
> that landed for Signal on `channels/signal-notification-policy` (PR #328).
> Tool calls should mostly *not* produce notifications — the turn's progress is
> one message edited in place. The last message before idle, and any
> `ASK_HUMAN`, must produce a notification.

**Branch**: `channels/telegram-notification-policy`, stacked on
`channels/signal-notification-policy` (PR #328, still open).
**Status**: design APPROVED by the 5-agent review gate (architect on round 5;
designer, security-design and CTO on round 3).

## Operator decisions (recorded)

1. **Gate both edit sources at 1500 ms for every `PsSingleBubble` channel**
   (chosen over a per-channel interval). One shared code path. Consequence,
   accepted deliberately: Signal's live-preview cadence drops from
   every-gateway-frame to at most one edit per 1500 ms. This is a real
   behaviour change to the branch this PR is stacked on; called out in
   section 5 and open question 4.

## Rev 4 changelog

Round 3 approved on design/security/CTO and found **three architectural
blockers**. All three are corrected here; the third is the most important
because it invalidated Rev 3's central rate argument.

1. **The dominant edit source is ungated, and Rev 3 missed it.** The
   `PsSingleBubble` branch of `handleEntryUpdate` (`Loop.hs:1231-1236`) calls
   `updateBubble` on **every** frame with **no gate at all** — no interval, no
   codepoint branch. Rev 3 gated only *tool* edits and then claimed a 40/min
   ceiling. The real driver is frame edits: the gateway emits on "1500 ms **or**
   80 new codepoints" (`Send.hs:938`), and 80 codepoints is ~15-20 tokens, so a
   fast model yields several frames per interval — on the order of 100+ edits
   per minute, none of it bounded by WU-3. §2.3 now gates the **frame path** too
   and restates the ceiling honestly (§2.3).
2. **Rev 3's "why a frame re-gate is a no-op" reason was wrong.** It credited
   the gateway. The actual reason the *separate-messages* path cannot be
   double-gated is that `handleEntryUpdate` already calls `shouldEdit` itself at
   `Loop.hs:1250`. And because Rev 4's gate is **interval-only** (dropping the
   codepoint branch), applying it to the frame path is *deliberately
   behaviour-changing* — it removes edits the current code makes. §3 says so
   instead of claiming a no-op.
3. **`ccEditMessage` has three call sites, not two.** Rev 3 covered
   `updateBubble` (`:1294`) and `finalizeBubble` (`:1390`) and claimed "exactly
   two policies". The third, `:1262` (the `PsSeparateMessages` frame path), must
   migrate to `EditOutcome` to compile and had no stated semantics. §2.2 adds a
   third row.
4. **`ssFinalized` is conditional.** It is set only by
   `when (markFinal && delivered)` (`:1394`), so Rev 3's blanket DoD ("a
   subsequent late entry-update produces no further send or edit") holds only if
   the fallback send succeeded. The DoD now asserts on `ssFinalized` /
   conditionality.
5. **The reason-string is a closed whitelist.** Rev 3 said `EditFailed`'s `Text`
   never carries the API body, but a `<reason-class>` derived from Telegram's
   `description` is a passthrough by another name. The classifier is now an
   enumerated type derived in the pure function.
6. **A failing fallback send must clear `ssMsgId`**, and a *chat-level*
   permanent failure needs a per-turn cap — otherwise the H2b loop reappears
   keyed on send failure (429 create) or on a failure that is not
   message-specific (bot kicked, rights lost).
7. **Changelog wording fixed** — Rev 3's "`EditUnchanged` stays dropped" named a
   constructor the type does not have; the no-op case folds into `EditApplied`.

---

## 1. Problem

### 1.1 Today: one notification per text segment and per tool call

`TelegramChatChannel` never overrides `ccProgressStyle` (`Class.hs:82` default
`PsSeparateMessages`), so every streamed text segment creates its own message,
`handleToolCallActivity` posts every tool line via `ccSend chan line`
(`Loop.hs:1522`), and `handleHarnessStatus`/`handleEntry` flush accumulated text
as further messages. A five-tool turn yields roughly six Telegram pushes.

### 1.2 The Signal fix is already channel-generic

The Signal work did not special-case Signal. It added `ccProgressStyle` /
`PsSingleBubble` and `ccChunkLimit` to the class (`Class.hs:35-36,81-92`), a
pure renderer `Seal.Channels.Chat.Bubble.bubbleText` (offset-splice), and a
single-bubble branch in the loop (`updateBubble`, `spliceContent`,
`finalizeSingleBubble`, `mergeAnswer`). Only `Signal.hs:456` opts in. The rest is
channel-polymorphic, so this task is largely *opting Telegram in* plus fixing the
hazards below.

### 1.3 Hazards

**H1 — `ccChunkLimit` is unset.** `TelegramChatChannel` inherits the `Nothing`
default (`Class.hs:92`), so `shouldFallBackToChunks` (`Loop.hs:1368-1370`)
always returns `False` and an over-long bubble is never bounded. Signal sets
`Just (sccChunkLimit ch)` (`Signal.hs:458`); Telegram must set
`Just (tccChunkLimit ch)` (config default 3900, `Seal.Telegram.Config`).

**H1b — the over-limit branch is a frozen bubble.** With the limit set, the
branch at `Loop.hs:1352-1357` logs "leaving it as-is" and clears `ssMsgId`,
abandoning the bubble mid-turn with a cursor while the answer arrives below. Not
reachable for Telegram today; H1 makes it reachable, so §2.6 fixes it.

**H2 — a failed edit becomes a fresh send, and flood control is not a failure.**
`updateBubble` (`Loop.hs:1294-1300`) and `finalizeBubble` (`:1389-1394`) both do
"edit, and on `False` send a fresh full-text message".
`tgEditMessageViaApi` (`Telegram.hs:565-591`) returns `False` for **every**
non-200 — a 429 flood-control, a 5xx, and a genuinely uneditable message are
indistinguishable. So the loop answers "slow down" by **sending a new full-text
message**: it notifies, duplicates the body, and consumes more of the budget it
just exceeded.

**H2b — and the fallback does not converge.** `void (ccSendWithId ...)`
(`Loop.hs:1300`) throws away the new id, so `ssMsgId` still names the dead
message. Every subsequent tool call re-fails and re-sends the whole body. The
one-off duplicate Rev 2 assumed is actually an unbounded loop.

**H3 — the whole `PsSingleBubble` edit path is unthrottled.** Neither the frame
branch (`:1231-1236`) nor the tool branch (`:1496-1511`) consults any gate. This
is the dominant edit source and the one that can exceed Telegram's ~20/min group
budget.

### 1.4 What already works and must not regress

- **`ASK_HUMAN` is sent as a new message.** `handleAsk` (`:1545-1556`) uses
  `ccSend`/`ccSendWithOptions`, never into `ssMsgId`; Telegram's
  `ccSendWithOptions` (`Telegram.hs:206`) is a real `sendMessage` + keyboard.
- **The final answer is sent as a new message** at idle (`:1361-1365`).
- **Edits do not notify on Telegram** — the same premise as Signal.
- **Watch mode** (`:982-1160`) is channel-generic; no Telegram change.

---

## 2. Design

### 2.1 Telegram opts in (the core change)

```haskell
instance ChatChannel TelegramChatChannel where
  ccProgressStyle _ = PsSingleBubble
  ccChunkLimit ch   = Just (tccChunkLimit ch)
```

| Turn shape | Messages | Notifications (attempted) |
|---|---|---|
| plain Q&A | 1 — the answer | 1 |
| tool turn | 2 — progress bubble, then answer | 2 |
| ask | question (+ inline keyboard) as new message | 1 |

Identical to Signal's contract; the third column is *attempted* — see §2.4. (A
`disable_notification` bubble create would make a tool turn 1 notification and is
the only change that would fully meet "tool calls don't notify"; it breaks parity
with PR #328. §7 question 1.)

### 2.2 Three-way `EditOutcome`, with three policies

```haskell
-- | The outcome of one platform edit attempt.
data EditOutcome
  = EditApplied
    -- ^ The content is on the platform. A no-op edit (Telegram's
    -- @message is not modified@) lands here too: the content is present.
  | EditDeferred
    -- ^ Transient refusal: flood control, 5xx, network. The message still
    --   exists and an identical retry may succeed. Fact only — the caller
    --   supplies the policy.
  | EditFailed EditFailure
    -- ^ Permanent refusal. Carries an enumerated classifier, never
    --   platform text (see 'EditFailure').
  deriving stock (Eq, Show)

-- | Why an edit can never succeed. Enumerated in the pure mapping function so
-- no API response body, URL, or exception text can reach a log or a test.
-- The Telegram bot token is embedded in the request URL, so free text here
-- would be a credential-leak vector.
data EditFailure
  = EditGone       -- ^ message deleted / not found
  | EditTooLong    -- ^ body exceeds the platform limit
  | EditForbidden  -- ^ bot blocked, kicked, or lacks rights
  | EditBadRequest -- ^ malformed request (a programming error)
  deriving stock (Eq, Show)
```

Not to be confused with `Seal.Handles.Channel.Deferral` (`Channel.hs:20`),
which means the *opposite* — blocking the caller for a human answer. The
Haddock cross-references it.

**Deferral is only safe where a later event retries**, so there are exactly three
policies — one per `ccEditMessage` call site:

| Site | `EditDeferred` | `EditFailed reason` |
|---|---|---|
| **`updateBubble`** (`:1294`; callers `:1234` frame, `:1509` tool) | keep `ssMsgId`, skip; next frame/tool call retries | send the body once, **adopt the returned id** |
| **`finalizeBubble`** (`:1390`; terminal for `PsSeparateMessages`) | treat as failed: send the text | send the text |
| **`handleEntryUpdate` separate path** (`:1262`) | skip; advance neither `ssLastEdit` nor `ssLastLen`, so the next frame retries (today's `when ok` behaviour, now explicit) | **unchanged**: drop silently, as today |

Notes, all of which earlier revisions got wrong:

- **Adoption is the H2b fix.** `mId <- ccSendWithId …; for_ mId (writeIORef (ssMsgId ss) . Just)`.
- **If the adopt-send returns `Nothing` (429/exception), `ssMsgId` is cleared.**
  Leaving it on the dead message re-opens the H2b loop behind a failing *send*.
- **A chat-level `EditForbidden` is not message-specific** (bot kicked, rights
  lost): every new message is equally uneditable, so adoption alone still
  yields one notifying send per tool call. Add a **per-turn fallback cap of
  one**: after a fallback send, further `EditFailed` edits in that turn are
  dropped (not re-sent) until the next turn. Tracked as a small field on
  `StreamingState`.
- **The separate-path row keeps today's silent drop** to keep WU-1 mechanical;
  that path is not `PsSingleBubble`, is not used by Telegram, and already
  retries-on-next-frame by not advancing the counters.
- **`finalizeSingleBubble`'s bubble close (`:1358`) has no policy of its own** —
  it routes through `updateBubble`, and `handleHarnessStatus` calls
  `resetStreamingState` immediately after (`:1480`), clearing `ssMsgId`
  (`Types.hs:218-224`). A deferred close simply gives up and the cursor lingers
  until the next turn. Accepted (§5).

### 2.3 Bound the whole edit path (H3) — with honest arithmetic

Add a channel-declared interval and gate **both** `PsSingleBubble` edit sources
on **interval only** (no codepoint branch — the `||` in `shouldEdit`
`RateLimit.hs:52-63` is what makes it unbounded):

```haskell
ccEditIntervalMs :: c -> Int
ccEditIntervalMs _ = 1500            -- default: today's behaviour
```

Both sources share **one** per-conversation timestamp, `ssLastBubbleEdit`
(named in §2.7). One shared field, not one per source — two independent gates
would compose to 80/min and falsify the combined bound below.

- **Frame edits** (`:1231-1236`): edit only if
  `now - ssLastBubbleEdit >= interval`, then set it.
- **Tool edits** (`:1496-1511`): the *same* field and interval. The first edit of
  a turn is immediate because `resetStreamingState` clears the field at turn
  start (§2.7), not because of a separate counter.

Corrected ceiling, replacing Rev 3's false "fits" claim:

| Edit source | Rev 3 (claimed) | Rev 4 (actual) |
|---|---|---|
| Frame path | "already gated" | **ungated today** → ~100+/min on a fast model; gated here to ≤40/min individually, sharing the bucket |
| Tool path | ≤40/min | gated to ≤40/min individually, sharing the bucket |
| Combined | 40/min | **≤40/min** — one 1500 ms bucket per conversation, shared by both sources |
| Telegram group budget | "20/min, exact" | 20/min — **still not guaranteed** |

Because both sources draw on the same bucket, a turn alternating frames and tool
calls cannot exceed 40 edits/min in total. `EditDeferred` does not advance the
field (§2.7), so a suppressed edit retries on the next event rather than being
skipped for a full interval.

**The gate is a burst limiter, not a guarantee.** For group chats 20/min is the
whole allowance, leaving nothing for the answer, asks, or watch notifications.
The real safety net is **deferral** (§2.2): an over-budget edit is *skipped*
rather than converted into a send, so exceeding the budget degrades to a *stale
bubble*, never a duplicate. §5 says so.

Gate placement: **at the two call sites**, never inside `updateBubble` —
`finalizeSingleBubble` routes its closing edit through `updateBubble`
(`:1358`), so a gate there would suppress the cursor-stripping idle edit.

### 2.4 What "must notify" actually guarantees

- **`ASK_HUMAN` is always *attempted* as a new `sendMessage`**
  (`ccSendWithOptions`, falling back to `ccSend` — `:1549-1554`). The keyboard
  send returns `Nothing` on any non-200 **or exception** (`Telegram.hs:621-647`),
  and the fallback is the same fire-and-forget primitive as below.
- **The answer is always *attempted* as a new `sendMessage`** at idle
  (`:1361-1365`).
- **Both attempts are best-effort and currently unreported.**
  `ccSend :: c -> Text -> IO ()` and `sendViaApi` swallow every exception and
  ignore the status code (`Telegram.hs:488-501`); `ccSendWithId` — the
  bubble-create path — does the same (`:547-563`).

**What the human observes on failure:** the bubble closes with a cursor, then
nothing — no answer, no error, no sign the turn ended. The operator cannot
distinguish "still working" from "finished and dropped".

This PR makes the failure **visible**: a `dbg` line carrying an allow-listed
status code and an **enumerated** classifier — never the body, URL, or a raw
exception (`getUpdates` at `:318` already leaks `show ex` on a token-bearing
URL; do not copy it). WU-4 owns this.

**Follow-up filed, not in this PR:** a `ChatSendOutcome` symmetric with
`EditOutcome` (with `retry_after`-aware retry) on **both** `ccSend` and
`ccSendWithId` — the create path matters most, since a 429 there yields no
bubble at all. Deferred because it touches ~30 `ccSend` call sites and would
break "one logical change". Named `ChatSendOutcome`, not `SendOutcome`, which is
taken (`Send.hs:510-522`).

### 2.5 The real seam: the transports, not just the class

```haskell
tctEditMessage :: Text -> Text -> Text -> IO EditOutcome   -- was IO Bool (Telegram.hs:65)
sctEditMessage :: Text -> Text -> Text -> IO EditOutcome   -- was IO Bool (Signal.hs:60)
```

Full surface (**11 code sites**):

- `Telegram.hs`: field `:65`, mock `:122`, wiring `:152`, adapter `:216`,
  `tgEditMessageViaApi` `:565-591`.
- `Signal.hs`: field `:60`, mock `:100`, wiring `:176`, adapter `:443`.
- `Class.hs`: export `EditOutcome(..)` and `EditFailure(..)` (`:15-19`).
- Test transport literals: `TelegramAdapterSpec.hs:110,140`;
  `SignalAdapterSpec.hs:151,178,201`.
- Test **assertion** sites that stop typechecking: `TelegramAdapterSpec.hs:76-81`,
  `SignalAdapterSpec.hs:117-123`, `:152-163`.
- `LoopSpec.hs` mock impl `:69-70`; forwarding instances `:89,:106`.

Telegram mapping — **pure** over (status, body), with the body inspected only
for the `not modified` marker:

| Status / condition | Outcome |
|---|---|
| 200, `ok:true` | `EditApplied` |
| 200, `ok:false` | `EditFailed EditBadRequest` (**preserves today's `parseOk` → resend**; a blanket "200 → Applied" would silently drop content) |
| 400, contains `"not modified"` | `EditApplied` (today's `:588-590`) |
| 400, otherwise | `EditFailed EditGone` / `EditTooLong` / `EditBadRequest` from the **enumerated** classifier |
| 401/403 | `EditFailed EditForbidden` |
| 429, 5xx | `EditDeferred` |
| other 4xx | `EditFailed EditBadRequest` |

The classifier is a **closed set** derived in the pure function (status code
plus, at most, a boolean "was it the not-modified marker"). Telegram's
`description` string is **never** carried into `EditFailure` — that is what
makes the no-leak property structural rather than a test.

IO wrapper (`tgEditMessageViaApi`): `parseRequest` `Left` →
`EditFailed EditBadRequest` (a programming error, **not** transient);
`httpLbs` `Left` (network) → `EditDeferred`, exception **discarded, never
`show`n**.

Signal mapping: success → `EditApplied`; unparseable timestamp →
`EditFailed EditBadRequest` (preserves `SignalAdapterSpec.hs:148-163`).

### 2.6 Close an over-limit bubble instead of abandoning it (H1b)

When the body exceeds `ccChunkLimit` at finalize, make **one** edit to a short
under-limit body (`"turn finished — answer below"`) instead of logging and
clearing the id (`:1352-1357`). The bubble then ends deliberately, with no
dangling cursor, and the full text still arrives via chunked `ccSend`.

**Gated on `ccProgressStyle chan == PsSingleBubble`**: Signal sets
`ccChunkLimit` today (`Signal.hs:458`), so an ungated change would alter
Signal's over-limit behaviour inside PR #328's code before that PR is reviewed.

### 2.7 Test seam for the interval gate

`cccNow :: IO UTCTime` on `ChatChannelConfig`, defaulting to `getCurrentTime` in
`defaultChatChannelConfig`. Every existing config is built from that default
(`Serve.hs`, ~20 `LoopSpec` literals), so the field is additive. WU-3 also
**routes `Loop.hs:1238`'s direct `getCurrentTime` through `cccNow`**, otherwise
the seam would cover the tool gate only and leave the frame path
non-deterministic in tests. WU-3's DoD asserts that advancing `cccNow` moves the
`PsSeparateMessages` path too, so the routed seam itself is covered.

Two new `StreamingState` fields, named here so WU-1 and WU-3 cannot each
invent their own:

| Field | Purpose |
|---|---|
| `ssLastBubbleEdit :: IORef (Maybe UTCTime)` | the single shared bucket for both `PsSingleBubble` edit sources (§2.3) |
| `ssFallbackSent :: IORef Bool` | the per-turn one-shot fallback cap (§2.2) |

The tool path deliberately gets **no** separate counter (§2.3). Both fields live
on `StreamingState`, which is already **per-conversation** (Telegram's budget is
per-chat), and both are cleared by `resetStreamingState`
(`Types.hs:218-224`) so a turn starts with an immediate first edit.
`ssLastBubbleEdit` advances **only on `EditApplied`** — a deferred edit must
retry on the next event, not sleep for another interval.

---

## 3. Alternatives considered

- **Keep `Bool`, gate harder.** Rejected: the amplifier is the dangerous bug.
- **Treat every `False` as deferred.** Rejected: a genuinely uneditable message
  would never deliver its content.
- **Sleep for `retry_after` inside the adapter.** Rejected: the loop is a
  single-threaded event handler shared by every conversation on the channel.
- **Gate only the tool path (Rev 3).** Withdrawn: the frame path is the dominant
  edit source and was left unbounded, making Rev 3's ceiling claim false.
- **Re-gate only the separate-messages frame path.** Rejected for a different
  reason than Rev 3 gave: that path already calls `shouldEdit` at `:1250`, so a
  second *identical* gate there is redundant. (Rev 3 credited the gateway; the
  gateway's gate is a separate process path whose codepoint branch fires
  regardless of elapsed time, so its frames do arrive inside the interval.)
  Rev 4's gate is **interval-only**, so applying it to the `PsSingleBubble` frame
  path is deliberately behaviour-changing — that is the point.
- **Land WU-2 behind WU-1 in a separate PR.** Considered: it would make the
  re-post loop unreachable by default. Rejected because the fix is one line;
  instead **WU-1 lands first as its own commit**, with WU-2's DoDs asserting
  convergence.
- **A Telegram-only progress style.** Rejected: the gap is failure semantics,
  which belongs on the class.

---

## 4. Work units

Each leaves the tree green (`make check`: build `-Werror`, test, hlint).

### WU-1 — `EditOutcome` through class, loop and both transports

**Files**: `Class.hs`, `Loop.hs`, `Types.hs`, `Signal.hs`, `Telegram.hs`,
`test/.../LoopSpec.hs`, `test/.../SignalAdapterSpec.hs`,
`test/.../TelegramAdapterSpec.hs`.

- `EditOutcome` / `EditFailure` in `Class.hs` (exported); `ccEditMessage` result.
- `tctEditMessage` / `sctEditMessage` result (§2.5 surface).
- The three policies in §2.2, **including id adoption, `ssMsgId` clearing on a
  `Nothing` adopt-send, and the per-turn fallback cap**.
- Pure `telegramEditOutcome`; IO mapping in `tgEditMessageViaApi`.
- `MockChan` gains `mcEditOutcomes :: IORef [EditOutcome]`, drained head-first,
  last value sticky — so a deferred→applied *sequence* and a *sticky* permanent
  failure are both expressible.

**DoD** (all hspec):
- **Convergence:** a tool call whose edit returns `EditFailed`, then a second
  tool call ⇒ **exactly one** fallback send in total.
- **Chat-level permanence:** a sticky `EditFailed EditForbidden` across two tool
  calls ⇒ at most one fallback send for the turn (the cap).
- **Failed adopt-send:** edit `EditFailed` and the fallback `ccSendWithId`
  returns `Nothing` ⇒ `ssMsgId` is cleared, so the next tool call takes the
  create path rather than re-sending the dead body.
- `EditDeferred` on a live edit creates no message and keeps the id; a later
  `EditApplied` edits the **same** id (asserted via the recorded edit id).
- `EditDeferred` on a live edit loses no text: the following frame lands the
  skipped content.
- `EditDeferred` at `finalizeBubble` sends the text; **assert `ssFinalized` is
  set when the fallback send succeeded**, and that a late `entry-update` then
  produces no further send or edit. (Conditional by construction — `:1394`
  sets it only on `markFinal && delivered`.)
- **The `:1262` separate-path policy**, the only one of the three with no
  asserted behaviour: `EditDeferred` leaves `ssLastEdit`/`ssLastLen` unadvanced
  (so the next frame retries) and `EditFailed` drops with the message count
  unchanged.
- Mapping table (§2.5) row by row, pure, including `200 + ok:false` → failed and
  `parseRequest` `Left` → failed.
- `EditFailure` values are a closed enum: a property test that no constructor
  can carry arbitrary `Text` (compile-enforced, asserted by construction).

### WU-2 — Telegram opts in + over-limit close

**Files**: `Telegram.hs`, `Loop.hs`, `test/.../TelegramAdapterSpec.hs`,
`test/.../LoopSpec.hs`.

- `ccProgressStyle _ = PsSingleBubble`; `ccChunkLimit ch = Just (tccChunkLimit ch)`.
- §2.6, gated on `PsSingleBubble`.

**DoD**
- `ccProgressStyle` is `PsSingleBubble`; `ccChunkLimit` equals the configured
  limit (pure facts on a real channel value in `TelegramAdapterSpec`).
- Extend `mkMockTelegramChatTransport` to record `(id, content)` edits; drive a
  2-tool turn: **exactly one** create, ≥1 edit on that id, exactly one `ccSend`
  carrying the answer. (Generic coverage exists at `LoopSpec.hs:599-607`; this
  asserts the Telegram wiring.) The "one create" assertion assumes succeeding
  edits — a failed edit legitimately creates a second message (§2.2). Stated so
  it is not later read as a product invariant.
- Tools-only turn: 1 create, ≥1 cursor-free edit, 0 `ccSend`.
- Over-limit turn: tool call **first** (the only creator under `PsSingleBubble`,
  `:1231-1236`), then a body over the limit, then `idle`. Assert the closing
  edit equals the §2.6 literal **exactly** (not merely `T.length <= limit`,
  which any short body satisfies), contains no cursor character, and the full
  text is delivered exactly once.
- **Signal unchanged:** the equivalent Signal-path turn keeps today's
  "leaving it as-is" behaviour — assert `mcSendIds` length 1 with **no** closing
  edit (not merely the absence of a `dbg` line).

### WU-3 — Interval-gate both edit sources

**Files**: `Loop.hs`, `Types.hs`, `test/.../LoopSpec.hs`.

- `cccNow` (§2.7) and route `:1238`'s `getCurrentTime` through it.
- `ccEditIntervalMs` on the class (§2.3).
- Per-conversation gate on the **frame** branch (`:1231-1236`) and the **tool**
  branch (`:1496-1511`).

**DoD**
- 10 frames inside one interval ⇒ **one** edit; 10 tool calls inside one
  interval ⇒ **one** edit; the bubble body contains all the text/lines (no loss).
- With `cccNow` advanced past the interval, the next frame / tool call edits.
- The first edit of a turn is immediate.
- `idle` always performs the final edit (proves the gate is not inside
  `updateBubble`).
- A deferred edit does not advance the gate, so it retries on the next event.
- Advancing `cccNow` also moves the `PsSeparateMessages` path (the routed seam,
  §2.7, is covered and not just the two new gates).
- `PsSeparateMessages` cadence unchanged (existing tests untouched).

### WU-4 — Observability, docs, issue filing

- Log send failures (§2.4) in `Telegram.hs:488-501` and `:547-563`: allow-listed
  status + enumerated classifier, **never** the body, URL, or `show ex`.
- Fix Haddocks: `ccEditMessage` (the `Bool` contract is gone; cross-reference
  `Deferral`), `ProgressStyle` (no longer "verified for Signal only"),
  `Seal.Telegram.Config`'s chunk-limit comment, `ccSupportsStreaming`
  (unreachable for a `PsSingleBubble` channel).
- File two issues: (a) §2.4 `ChatSendOutcome`; (b) the missing inbound
  allow-list (§5).
- `make check`; confirm hlint reports `No hints`.

---

## 5. Risks and accepted degradations

- **A deferred *answer* send is a lost notification** (§2.4) — the operator's
  stated must-not-happen. Pre-existing; this PR reduces exposure (bounded edits
  leave send budget) and makes it visible. Follow-up filed. **The largest
  residual gap, stated rather than hidden.**
- **The edit gate is a burst limiter, not a guarantee** (§2.3). In a group chat,
  exceeding 20/min degrades to a stale bubble, never a duplicate.
- **A gated frame path changes Signal's preview cadence** — Signal opts into
  `PsSingleBubble`, so its live preview becomes no faster than the interval
  instead of updating on every gateway frame. This is a deliberate reduction
  (the ungated path is the dominant edit source and blows Telegram's budget) and
  it lands inside PR #328's code. Flagged for review, not hidden.
- **A deferred final bubble close leaves a cursor** until the next turn resets
  state. Bounded, cosmetic.
- **`EditFailed` on a user-deleted message re-posts the body once**, capped to
  one fallback per turn. Content preservation wins; it converges (H2b).
- **Over-limit chunk units.** `shouldFallBackToChunks` compares `T.length`
  (codepoints); Telegram's 4096 is UTF-16 code units, and `opEmoji` is nearly all
  non-BMP (2 units each), so an emoji-dense answer can pass 3900 and still be
  rejected. Mitigated by §2.6. Measuring UTF-16 is a note for the follow-up.
- **No inbound allow-list (pre-existing, out of scope).** `tccAllowList` is
  declared and assigned but **never read** (`Telegram.hs:182,279`), and
  `readerLoop` retargets `tccLastChat` for **any** sender (`:312-316`), which
  every `ccSend`/`ccEditMessage`/`sendRaw` subsequently reads (`:205,:213,:241`).
  Any party who can message the bot redirects both sends and edits into their own
  chat. This design neither causes nor fixes it and introduces nothing new, but
  **no work here may assume a gate exists**. Issue filed (WU-4); if fixed later,
  the check must run **before** the `writeIORef` at `:315`.
- **Rebase onto PR #328.** 11 code sites (§2.5), eight in test files. Expected
  conflict region: `LoopSpec.hs:567-815`, which #328 owns. **WU-1 lands as its
  own commit** and must precede WU-2.

## 6. Verification beyond unit tests

One manual run against a real bot: `seal serve`, a Telegram channel, a
multi-tool turn, confirming (a) one notification for the progress bubble rather
than one per tool, (b) the bubble updates in place, (c) the answer arrives as a
second notification, (d) an `ASK_HUMAN` turn notifies with a usable keyboard,
(e) the bubble does not visibly lag more than ~3 s behind.

**Rollback is three independent pieces:** (i) revert WU-2's two instance methods
to restore the default style; (ii) revert WU-3's gates — a `Loop.hs` change that
also affects Signal, since Signal is `PsSingleBubble`; (iii) revert §2.6's hunk.
WU-1 and WU-4 stay — the failure semantics and observability are right for any
channel.

## 7. Open questions for the operator

1. **Silent progress bubble.** Telegram supports `disable_notification: true`.
   Creating the bubble silently makes a tool turn **1** notification (just the
   answer) — the only change that fully meets "tool calls don't notify". Breaks
   parity with PR #328; needs a create-with-flags seam. In scope or follow-up?
2. **Lost answer on a 429'd send.** §2.4's follow-up is the real fix for the
   operator's stated must-not-happen. Acceptable as a separate issue, or a
   blocker here?
3. **Telegram's edit interval.** 1500 ms (40/min — fine for private chats, over
   the group budget) or 3000 ms (20/min — exactly the group budget)? A
   per-channel policy call.
4. **Signal's preview cadence.** Gating the `PsSingleBubble` frame path caps
   Signal's live preview rate too (§5). Accept, or apply the interval only for
   Telegram?
5. **The missing inbound allow-list.** Pre-existing, out of scope, but a real
   redirection vector. Prioritise over this work?
