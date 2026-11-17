# Telegram notification policy — Design (Rev 7)

> **Operator requirement**: apply the same notification reduction to Telegram
> that landed for Signal on `channels/signal-notification-policy` (PR #328).
> Tool calls should mostly *not* produce notifications — the turn's progress is
> one message edited in place. The last message before idle, and any
> `ASK_HUMAN`, must produce a notification.

**Branch**: `channels/telegram-notification-policy`, stacked on
`channels/signal-notification-policy` (PR #328, still open).
**Status**: design — Rev 8. Approved by the 5-agent design gate through round 5;
then the **plan** gate found Rev 5-6 were over-engineered, and this revision
acts on that.

Rev 8 adds operator decisions 3 and 4, plus one implementability fix the plan
gate caught: `updateBubble` is `IO ()`, so "advance the gate only on success"
was not expressible. It now returns `IO Bool` - which its own stale Haddock at
`Loop.hs:1278` already claims it does.

## Operator decisions (recorded)

1. **Gate both edit sources at 1500 ms** for every `PsSingleBubble` channel
   (rather than a per-channel interval). Accepted consequence: Signal's live
   preview drops from every-gateway-frame to ≤1 edit/1500 ms.
2. **Create the progress bubble silently** (`disable_notification: true`). A
   tool turn therefore notifies **exactly once** — the answer — and tool calls
   notify **zero** times. Deliberately diverges from PR #328.
3. **Every turn ends with exactly one notification.** A tools-only turn (no
   answer text) would otherwise notify zero times — its last message before idle
   is the silent bubble, violating "the last message before idle must notify".
   So at idle, when a turn produced a progress bubble but no answer text, send
   one short notifying close notice. Invariant: **a turn notifies exactly once**
   - the answer when there is one, otherwise the close notice.
4. **Fix the over-limit freeze for Signal too** (section 2.6).

## Rev 7 changelog — the most important change

**The `EditOutcome` enum is withdrawn.** Rev 5-6 proposed replacing
`ccEditMessage`'s `Bool` with a three-valued outcome across 11 sites in both
transports. The plan gate showed that was solving the wrong problem, and the
code agrees:

- `updateBubble` is reached **only** from `PsSingleBubble` call sites
  (`Loop.hs:1234` frame, `:1358` finalize close, `:1509` tool).
- The bubble "holds tool progress only" (`Loop.hs:1346-1347`); the **answer is
  never in it** — `finalizeSingleBubble` sends the answer separately via `ccSend`
  (`:1361-1365`).
- Therefore, on an edit failure, **sending a fresh message loses nothing.** The
  live-edit state (`ssSplices`, `ssAccumulated`) is intact, so the next frame,
  tool call or `idle` re-renders the whole body. Only a *preview* can be stale.

So the amplifier (answering a transient 429 with a new notifying message) is
removed by **not sending**, not by classifying. One branch, no type migration,
no new transport fields, no `EditFailure`, no per-turn cap.

**What that costs, stated honestly:** a permanently uneditable message now shows
a stale preview for the rest of the turn instead of a duplicate notification.
That is the correct trade for this task, and the answer still arrives.

The three real bugs Rev 5-6 were reaching for remain fixed:
- the duplicate/re-post loop → gone (no send on failure);
- content loss → none (answer is a separate `ccSend`; preview re-renders);
- diagnosis → one `dbg` line with the status code (WU-4), no enum needed.

---

## 1. Problem

### 1.1 Today: one notification per text segment and per tool call

`TelegramChatChannel` never overrides `ccProgressStyle` (`Class.hs:82` default
`PsSeparateMessages`), so every streamed text segment creates its own message,
`handleToolCallActivity` posts every tool line via `ccSend chan line`
(`Loop.hs:1522`), and `handleHarnessStatus`/`handleEntry` flush accumulated text
as further messages. A five-tool turn yields roughly six Telegram pushes.

### 1.2 The Signal fix is already channel-generic

The Signal work added `ccProgressStyle` / `PsSingleBubble` and `ccChunkLimit` to
the class (`Class.hs:35-36,81-92`), a pure renderer
`Seal.Channels.Chat.Bubble.bubbleText`, and a single-bubble branch in the loop
(`updateBubble`, `spliceContent`, `finalizeSingleBubble`, `mergeAnswer`). Only
`Signal.hs:456` opts in. So this task is largely *opting Telegram in* plus the
hazards below.

### 1.3 Hazards

**H1 — `ccChunkLimit` is unset.** `TelegramChatChannel` inherits the `Nothing`
default (`Class.hs:91`), so `shouldFallBackToChunks` (`Loop.hs:1368-1370`) always
returns `False` and an over-long bubble is never bounded. Telegram must set
`Just (tccChunkLimit ch)` (config default 3900).

**H1b — the over-limit branch freezes the bubble.** `finalizeSingleBubble`
(`Loop.hs:1352-1357`) logs "leaving it as-is" and clears `ssMsgId`, abandoning the
bubble with a cursor. Not reachable for Telegram today; H1 makes it reachable.

**H2 — a failed edit is answered with a brand-new notifying message.**
`updateBubble` (`Loop.hs:1294-1300`):

```haskell
ok <- ccEditMessage chan id' content
unless ok $ void (ccSendWithId chan content)    -- discards the new id
```

Telegram returns non-200 for 429 flood control (transient), 5xx, and genuine
uneditability alike, and `tgEditMessageViaApi` (`Telegram.hs:565-591`) collapses
them to `False`. Because the new id is discarded, `ssMsgId` keeps naming the dead
message, so **every later tool call re-sends the whole body** — an unbounded
notifying loop. This is the bug to kill.

**H3 — the whole `PsSingleBubble` edit path is unthrottled.** Neither the frame
branch (`:1231-1236`) nor the tool branch (`:1496-1511`) consults any gate, so a
fast model yields ~100+ edits/min, above Telegram's ~20/min group budget.

**H4 — the bubble create itself notifies.** Even with H1-H3 fixed, a tool turn
would push twice (bubble + answer). Operator decision 2 removes the bubble push.

### 1.4 What already works and must not regress

- **`ASK_HUMAN` sends as a new message.** `handleAsk` (`:1545-1560`) uses
  `ccSendWithOptions` / `ccSend`, never `ssMsgId`; Telegram's is a real
  `sendMessage` with a keyboard (`Telegram.hs:220`).
- **The final answer is sent as a new message** at idle (`:1361-1365`).
- **Edits do not notify on Telegram** — the same premise as Signal.
- **Watch mode** (`:982-1160`) notifies through `ccSend`; no change needed.

---

## 2. Design

### 2.1 Telegram opts in

```haskell
instance ChatChannel TelegramChatChannel where
  ccProgressStyle _ = PsSingleBubble
  ccChunkLimit ch   = Just (tccChunkLimit ch)
  ccSendWithIdSilently = -- §2.4
```

| Turn shape | Messages | Notifications (attempted) |
|---|---|---|
| plain Q&A | 1 — the answer | 1 |
| tool turn | 2 — progress bubble, then answer | **1** (the answer) |
| ask | question (+ inline keyboard) as new message | 1 |

The tool row is 1 because the bubble is created silently (§2.4). Signal's
contract is the same except its create is a normal `sendMessage`, so a Signal
tool turn notifies twice — the recorded divergence.

### 2.2 Don't send on a failed edit (fixes H2)

`updateBubble`'s failed-edit branch becomes:

```haskell
Just id' -> do
  ok <- ccEditMessage chan id' content
  unless ok $
    -- Do NOT send a fresh message. The answer is delivered separately
    -- ('finalizeSingleBubble'), and this body is re-rendered from
    -- 'ssSplices'/'ssAccumulated' by the next frame, tool call or idle. A
    -- fresh send would notify, duplicate the body, and (because the new id
    -- was discarded) repeat on every later tool call - the exact symptom
    -- this change removes.
    dbg "[bubble] edit failed; leaving the bubble for the next event"
```

The create branch is unchanged: it is the only way a bubble comes into being,
and a failed create simply means no bubble (the next tool call retries).

**Why nothing is lost** (the argument the tests must encode):
- the answer is a separate `ccSend`, untouched by any edit outcome;
- `ssSplices` and `ssAccumulated` are only written by the tool-call and entry
  handlers, never by an edit, so a failed edit cannot drop state;
- the *next* successful edit renders the full accumulated body, not a delta.

**Accepted cost**: a permanently uneditable message (user deleted it, bot lost
rights) shows a stale preview for the rest of the turn. Correct trade: stale
progress beats a duplicate notification.

### 2.3 Bound the edit path (fixes H3) — with honest arithmetic

```haskell
ccEditIntervalMs :: c -> Int
ccEditIntervalMs _ = spcEditIntervalMs defaultStreamProgressConfig   -- 1500
```

The default **is** the existing limiter constant, so the two cannot drift
(`RateLimit.hs:38`). `shouldEdit` is not reused because its `||` codepoint branch
is what makes it unbounded.

Both `PsSingleBubble` sources share **one** per-conversation timestamp,
`ssLastBubbleEdit` — one bucket, not one per source, or the gates would compose
to 80/min:

- **Frame edits** (`:1231-1236`): edit only if
  `now - ssLastBubbleEdit >= interval`, then set it.
- **Tool edits** (`:1496-1511`): the *same* field and interval.
- The first edit of a turn is immediate because `resetStreamingState` clears the
  field at turn start.
- `EditDeferred`/failure does **not** advance it, so a suppressed edit retries on
  the next event.

Ceiling:

| Source | Before | After |
|---|---|---|
| Frame path | ungated (~100+/min) | ≤40/min |
| Tool path | ungated | ≤40/min |
| **Combined** | — | **≤40/min** (one shared 1500 ms bucket) |
| Telegram group budget | — | 20/min — **not guaranteed** |

**The gate is a burst limiter, not a guarantee.** In a group chat 20/min is the
whole allowance and leaves nothing for the answer. The safety net is §2.2: an
over-budget edit is *skipped*, never converted into a send, so exceeding the
budget degrades to a stale bubble, never a duplicate.

Gate placement: **at the two call sites**, never inside `updateBubble` —
`finalizeSingleBubble` routes its closing edit through `updateBubble`
(`:1358`), so a gate there would suppress the idle close.

**Signature change this requires.** `updateBubble` is `IO ()`
(`Loop.hs:1281-1284`), so a call site cannot tell whether an edit landed and
"advance only on success" is inexpressible. It becomes `IO Bool` — which its
own stale Haddock (`:1278`, "Returns 'True' when the content is on the
platform") already describes. The three call sites ignore the result except the
two gated branches, which advance `ssLastBubbleEdit` on `True`.

### 2.4 Silent progress-bubble create (H4, operator decision 2)

```haskell
-- | Send a message that must not raise a platform notification, returning its
-- id for later editing. Used for progress bubbles. 'Nothing' when the platform
-- cannot send silently or the send failed; the loop then falls back to
-- 'ccSendWithId' (notifying) so progress is never lost.
ccSendWithIdSilently :: c -> Text -> IO (Maybe ChatMessageId)
ccSendWithIdSilently c t = ccSendWithId c t      -- default: cannot be silent
```

- `TelegramChatChannel` implements it via `disable_notification: true`.
- Signal inherits the default ⇒ PR #328's Signal behaviour is untouched here.
- `updateBubble`'s create branch uses it, falling back to `ccSendWithId` on
  `Nothing`.
- **`handleAsk` must not use it** (§2.5).

### 2.5 What "must notify" guarantees

- **`ASK_HUMAN` notifies.** `handleAsk` (`:1545-1560`) never writes `ssMsgId`;
  both its paths are new `sendMessage` calls. The §2.2 policy and §2.3 gate
  cannot touch them. The §2.4 seam must not capture asks — a regression there
  would silently break the operator's explicit requirement, so it gets an
  automated test (WU-4).
- **The answer notifies.** `finalizeSingleBubble` step 2 (`:1361-1365`) is a new
  `ccSend`.
- **Delivery is best-effort, and currently unreported.** `ccSend ::
  c -> Text -> IO ()`, `sendViaApi` (`Telegram.hs:487-500`) and
  `tgSendWithIdViaApi` (`:544-563`) swallow every exception and ignore the status
  code. A 429 at that moment drops the answer silently; the human sees a bubble
  close with a cursor and then nothing.

This PR makes that **visible** (a `dbg` status line — never the body, URL, or
`show ex`; the token is in the request URL, and `getUpdates` at `:318` already
leaks `show ex` — do not copy it) and files the real fix as a follow-up: a
`ChatSendOutcome` symmetric with the edit path on **both** `ccSend` and
`ccSendWithId` (the create path matters most — a 429 there yields no bubble).
Named `ChatSendOutcome`, not `SendOutcome`, which is taken (`Send.hs:510-522`).
Deferred because it touches ~30 call sites and would break "one logical change".

### 2.6 Close an over-limit bubble instead of abandoning it (H1b)

At finalize, when the body exceeds `ccChunkLimit`, make **one** edit to a short
under-limit literal (`"turn finished — answer below"`) instead of logging and
clearing the id (`:1352-1357`). The bubble ends deliberately, with no dangling
cursor; the full text still arrives via chunked `ccSend`.

**Not gated on `ccProgressStyle`.** Rev 3 proposed that guard "so Signal is
untouched" — it was **incoherent**, because `Signal.hs:456` already sets
`PsSingleBubble`, so it admits Signal and the accompanying "Signal unchanged"
test could never pass. The honest position: this improvement applies to Signal
too, since the frozen-bubble bug is real there. A deliberate change to PR #328's
code, listed in §5.

### 2.7 Test seam


`cccNow :: IO UTCTime` on `ChatChannelConfig`, defaulting to `getCurrentTime`.
Every existing config is built from `defaultChatChannelConfig` (record updates),
so the field is additive. WU-3 also routes `Loop.hs:1238`'s direct
`getCurrentTime` through it, so the seam is not tool-gate-only.

`ssLastBubbleEdit :: IORef (Maybe UTCTime)` on `StreamingState` (already
per-conversation; Telegram's budget is per-chat), cleared by
`resetStreamingState`.

### 2.8 Every turn notifies exactly once (operator decision 3)

The silent bubble (section 2.4) means a **tools-only** turn would notify zero
times: the bubble is silent, edits are silent, and `finalizeSingleBubble` only
`ccSend`s when the answer is non-empty (`:1365`). Today such a turn notifies via
its tool-line posts, so this is a real regression against "the last message
before idle must notify".

Rule: at idle, **if a progress bubble existed this turn and the answer text is
empty, send one short notifying close notice** (e.g. `"turn finished"`) through
the normal `ccSend`.

```haskell
-- finalizeSingleBubble, after the answer step
unless (T.null (T.strip answer)) $ ccSend chan answer
when (T.null (T.strip answer) && hadBubble) $ ccSend chan closeNotice
```

`hadBubble` is whether `ssMsgId` was set when the turn ended (read before the
close clears it). Consequences:

- **Invariant: a turn notifies exactly once** - the answer when there is one,
  otherwise the close notice. Never zero, never twice.
- A plain Q&A turn has no bubble and a non-empty answer gives 1 notification,
  unchanged.
- An **empty** turn with no bubble still notifies zero times: no progress to
  report, no bubble to close. Correct, and distinct from tools-only.
- `ASK_HUMAN` is unaffected: the ask is its own notifying send (section 2.5).

---

## 3. Alternatives considered

- **`EditOutcome` enum + per-site policy matrix (Rev 5-6).** Withdrawn: the
  answer is never in the bubble, so classifying failures buys nothing that "don't
  send" does not, and it cost 11 sites across both transports plus a per-turn cap.
- **Keep the fresh-send fallback but adopt the id.** Rejected: still answers a
  transient 429 with a notifying duplicate. "Don't send" is simpler *and*
  strictly better.
- **Treat every failure as deferred (retry later).** That is what §2.2 does, by
  simply leaving the state alone.
- **Sleep for `retry_after` inside the adapter.** Rejected: the loop is a
  single-threaded event handler shared by every conversation on the channel.
- **Re-gate the separate-messages frame path.** Rejected: that path already calls
  `shouldEdit` at `:1250`. (The gateway's own gate is a different process path
  whose codepoint branch fires regardless of elapsed time, so its frames *do*
  arrive inside the interval.) Rev 7's gate is interval-only, so applying it to
  the `PsSingleBubble` frame path is deliberately behaviour-changing.

---

## 4. Work units

Each leaves the tree green (`make check`: build `-Werror`, test, hlint).

### WU-1 — Stop sending on a failed edit (H2)

**Files**: `Loop.hs`, `test/.../LoopSpec.hs`.

Replace the fallback send with a `dbg` line (§2.2).

**DoD**
- A tool call whose edit fails creates **no** new message; a second tool call
  still creates none (the loop does not amplify).
- After a failed edit, the next successful edit renders the **whole**
  accumulated body (no delta loss).
- After a failed edit at `idle`, the answer is still delivered exactly once as a
  `ccSend`.
- Existing suites green (the current "edit failure falls back to a fresh send"
  expectation, if any, is rewritten with a comment saying why).

**Commit**: `fix(chat): do not re-send the bubble body when an edit fails`

### WU-2 — Telegram opts in, silently + over-limit close

**Files**: `Telegram.hs`, `Class.hs`, `Loop.hs`,
`test/.../TelegramAdapterSpec.hs`, `test/.../LoopSpec.hs`.

**Churn to enumerate** (the plan gate caught this being implicit):
`TelegramChatTransport` gains a field, which breaks the hand-built literals at
`TelegramAdapterSpec.hs:104-115` and `:134-145`; `mkMockTelegramChatTransport`
(`Telegram.hs:99`) gains an edits recorder, changing its return shape and thus
its **five** call sites (`TelegramAdapterSpec.hs:55,60,68,77,84`).

**DoD**
- `ccProgressStyle == PsSingleBubble`; `ccChunkLimit == Just limit`.
- Silent create: a tool turn's bubble create records `silent=True`; every later
  update is an edit; **zero** notifying sends before the answer.
- Silent-create fallback: when the silent send yields `Nothing`, the notifying
  `ccSendWithId` is used (progress is not lost).
- Two-tool turn: exactly one create, ≥1 edit on that id, exactly one `ccSend`
  with the answer. (The one-create assertion assumes succeeding edits; a failed
  edit legitimately means no bubble — not a product invariant.)
- Tools-only turn: 1 create, ≥1 cursor-free edit, 0 `ccSend`.
- Over-limit turn: tool call **first** (the only creator under `PsSingleBubble`),
  then a body over `ccChunkLimit`, then `idle`. The closing edit equals the §2.6
  literal **exactly**, has no cursor, and the full text is delivered once.
- Signal over-limit path **also** gets the closing edit (guard dropped).

**Commit**: `feat(telegram): silent progress bubble, one notification per turn`

### WU-3 — Interval-gate both edit sources

**Files**: `Loop.hs`, `Types.hs`, `Class.hs`, `test/.../LoopSpec.hs`.

**DoD**
- Create a bubble with a tool call, then 10 frames inside one interval ⇒ **one**
  edit, carrying the final text. (Frames alone cannot edit: the frame branch is
  `hasBubble`-guarded (`:1232`), so a tool call must come first. This correction
  is from the plan gate.)
- 10 tool calls inside one interval ⇒ one edit carrying all 10 lines.
- Frames and tools interleaved ⇒ total ≤1 edit (the **shared** bucket).
- After the interval, the next event edits.
- A fresh turn edits immediately (`resetStreamingState` cleared the field).
- `idle` always edits with the clock un-advanced (gate at call sites).
- A failed edit does not advance the bucket.
- Advancing `cccNow` also moves the `PsSeparateMessages` path (routed seam).
- **`StopMaxTokens` continuation** through the gate: both segments delivered once
  (existing `LoopSpec.hs:668-699`, now under a bucket).
- **`/bg` with no frames** through the gate: one bubble, one delivery (existing
  `:648-666`, now gated).
- **Watch mode** unaffected: `/watch` is a `ccSend`, so one notification still
  arrives with the gate active.
- `PsSeparateMessages` cadence tests untouched.

**Commit**: `perf(chat): rate-limit single-bubble edits to one per interval`

### WU-4 — Ask regression guard, observability, docs, issues

**Files**: `Loop.hs`, `Class.hs`, `Telegram.hs`, `src/Seal/Telegram/Config.hs`,
`test/.../LoopSpec.hs`.

**DoD**
- **Ask must notify** — needs a mock that is both `PsSingleBubble` and has a
  failing keyboard send (`BubbleChan.ccSendWithOptions` returns `Just` today,
  `LoopSpec.hs:90`; `NoKeyboardChan` is `PsSeparateMessages`, `:102-109`), plus a
  `mcSilentSends` recorder on the class-level mock so "no ask used the silent
  path" is a real assertion rather than vacuous. Assert: options ask →
  `ccSendWithOptions`; failing keyboard → notifying `ccSend`; no ask recorded as
  silent.
- Log send failures with an allow-listed status only — never body, URL, `show ex`.
- Haddocks: `ProgressStyle`, `ccSupportsStreaming` (unreachable under
  `PsSingleBubble`), `ccSendWithIdSilently` (asks must not use it),
  `updateBubble`'s no-send policy, `Seal.Telegram.Config` chunk note.
- File issue A (`ChatSendOutcome`) and issue B (missing inbound allow-list).

**Commit**: `docs(chat): guard asks against silent sends; log send failures`

---

## 5. Risks and accepted degradations

- **A deferred/failed *answer* send is a lost notification** (§2.5) —
  pre-existing; this PR reduces exposure and makes it visible. Follow-up filed.
  The largest residual gap.
- **The gate is a burst limiter, not a guarantee** (§2.3). Group chats can exceed
  20/min → stale bubble, never a duplicate.
- **A permanently uneditable bubble shows a stale preview** for the rest of the
  turn (§2.2). Accepted: stale progress beats duplicate notifications.
- **Signal's preview cadence drops** to ≤1 edit/1500 ms, and its over-limit path
  now closes the bubble — both operator-approved changes to PR #328's code.
- **Over-limit chunk units.** `shouldFallBackToChunks` compares codepoints;
  Telegram's 4096 is UTF-16 units and `opEmoji` is nearly all non-BMP (2 each), so
  an emoji-dense body can pass 3900 and still be rejected. Mitigated by §2.6 (a
  rejected closing edit is harmless — the text still arrives via chunking).
- **No inbound allow-list (pre-existing, out of scope).** `tccAllowList` is
  declared and assigned but **never read** (`Telegram.hs:182,279`), and
  `readerLoop` retargets `tccLastChat` for **any** sender (`:312-316`), which
  every send/edit subsequently reads (`:205,:213,:241`). Any party who can message
  the bot redirects sends and edits. Nothing here assumes a gate exists. Issue
  filed (WU-4); if fixed later, the check must run **before** the `writeIORef`
  at `:315`.
- **Rebase onto PR #328.** Files: `Loop.hs`, `Class.hs`, `Types.hs`, `Signal.hs`
  (Haddock only), `Telegram.hs`, three specs. Conflict region:
  `LoopSpec.hs:567-815`.

## 6. Verification beyond unit tests

One manual run: `seal serve`, a Telegram channel, a multi-tool turn. Confirm
(a) **no** notification from the bubble or any tool call, (b) the bubble appears
and updates in place, (c) the answer is the turn's **only** notification, (d) an
`ASK_HUMAN` turn notifies with a usable keyboard, (e) the bubble lags ≤ ~3 s.

**Rollback is three pieces:** (i) revert WU-2's instance methods (style, chunk
limit, silent create); (ii) revert WU-3's gates (a `Loop.hs` change that also
affects Signal); (iii) revert §2.6's close. WU-1 and WU-4 stand alone.

## 7. Open questions

1. **Lost answer on a 429'd send.** §2.5's follow-up is the real fix for the
   operator's stated must-not-happen. Separate issue, or a blocker here?
2. **The edit interval value.** 1500 ms (40/min — fine for private chats, over
   the group budget) or 3000 ms (20/min — exactly the budget)? The decision fixed
   *that* we gate, not the number.
3. **The missing inbound allow-list.** Pre-existing, out of scope, but a real
   redirection vector. Prioritise over this work?
