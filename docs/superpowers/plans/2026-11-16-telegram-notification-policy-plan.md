# Telegram notification policy — Implementation Plan (Rev 4)

**Design**: `docs/superpowers/specs/2026-11-16-telegram-notification-policy-design.md`
(Rev 8).
**Branch**: `channels/telegram-notification-policy`, stacked on
`channels/signal-notification-policy` (PR #328).

**Operator requirement** (verbatim): tool calls should mostly avoid Telegram
notifications by editing the most recent existing message; messages that need
user input (the last message before idle, or `ASK_HUMAN`) must generate a
notification.

**Operator decisions**: (1) gate both edit sources at 1500 ms for every
`PsSingleBubble` channel; (2) create the progress bubble **silently**, so a tool
turn notifies exactly **once** (the answer); (3) **every turn notifies exactly
once** - a tools-only turn sends a short notifying close notice at idle, so it
notifies once rather than zero times; (4) **fix the over-limit freeze for
Signal too**.

## Rev 4 changelog - what plan-gate round 3 changed

1. **WU-3 was internally contradictory** (feasibility + scope). It asserted both
   "a tool call then 10 frames yield ONE edit" and "10 tool calls yield one edit
   carrying all 10 lines" - incompatible, because the create either consumes the
   shared bucket or it does not. Resolved and stated explicitly in WU-3: the
   create does NOT consume the bucket (it is a create, not an edit); the first
   EDIT consumes it.
2. **`updateBubble` returns `IO ()`** (scope), so "advance only on success" was
   unexpressible. It becomes `IO Bool` - its own stale Haddock already claims
   that. Added to WU-3 GREEN with all three call sites.
3. **A tools-only turn would notify ZERO times** (completeness). That violates
   "the last message before idle must notify". Operator decision 3 adds a close
   notice; new **WU-2** DoD.
4. **No rollback section in the plan** (completeness) - rollback lived only in
   the design. Restored below.
5. **Silent-create mock churn under-enumerated** (completeness): `BubbleChan` and
   `NoKeyboardChan` must delegate `ccSendWithIdSilently`, or the WU-2 assertions
   are vacuous exactly as WU-4 warns.
6. **The Signal over-limit change is now an operator decision** (scope), not an
   inferred approval - decision 4.

## Rev 3 changelog — what the plan gate changed

1. **The `EditOutcome` enum is gone** (scope review, decisive). The answer is
   never in the bubble (`Loop.hs:1346-1347`, delivered separately at `:1361-1365`)
   and `ssSplices`/`ssAccumulated` are untouched by edits, so a failed edit loses
   nothing — the next event re-renders the full body. The amplifier is removed by
   **not sending**, which needs no classification. WU-1 is now a one-branch
   change in one file instead of an 11-site type migration across two transports.
2. **"10 frames ⇒ one edit" was unsatisfiable** (feasibility). The frame branch is
   `hasBubble`-guarded (`:1232`), so frames alone never edit — a tool call must
   create the bubble first. WU-3's DoD now says so.
3. **The nonexistent module reference is gone** (`Seal.Handles.Channel.Deferral`
   was cited as a cross-reference target and described as a module; it is a type
   at `src/Seal/Handles/Channel.hs:20`, and with the enum withdrawn nothing needs
   to reference it).
4. **Ask-notifies DoD is now genuinely testable** (completeness). It needs a
   `PsSingleBubble` mock whose keyboard send fails, plus a `mcSilentSends`
   recorder — otherwise "no ask used the silent path" is vacuously true.
5. **WU-2 enumerates its churn** (completeness/feasibility): the new
   `TelegramChatTransport` field breaks two literals, and the mock's return shape
   changes at five call sites.
6. **The §2.6 "Signal unchanged" test is replaced** by its opposite — Signal gets
   the closing edit too, because `Signal.hs:456` already sets `PsSingleBubble`.

---

## Preconditions

- [ ] `make check` green **before** starting, so any RED is attributable:
      `nix develop --command make check >check.log 2>&1; tail -20 check.log`
      (never pipe `cabal`/`hlint` through `head`/`tail` — SIGPIPE hang).
- [ ] Re-grep cited line numbers; they drift on rebase.

---

## WU-1 — Stop sending on a failed edit (H2)

**Files**: `src-chat-channels/Seal/Channels/Chat/Loop.hs`,
`test/Seal/Channels/Chat/LoopSpec.hs`.

### 1.1 RED

In `LoopSpec.hs`, a `BubbleChan` whose `ccEditMessage` returns `False`:

1. **No amplification** — tool call ⇒ edit fails; second tool call ⇒ edit fails.
   `mcSendIds` does **not** grow (Rev 2 asserted "exactly one"; Rev 3 asserts
   **zero**, because sending is what we removed).
2. **No state loss** — after a failed edit, make the next edit succeed and assert
   its body contains the **whole** accumulated text (not a delta).
3. **Answer still delivered** — a failed edit followed by `idle` ⇒ the answer is
   sent exactly once via `ccSend`.

### 1.2 GREEN

Replace the branch at `Loop.hs:1298-1300`:

```haskell
unless ok $
  dbg "[bubble] edit failed; leaving the bubble for the next event"
```

Delete the `void (ccSendWithId chan content)` and its comment; write a new
comment stating *why* no send is needed (the answer is separate; state is
intact; the next event re-renders).

### WU-1 DoD

- [ ] DoD 1–3 green.
- [ ] `make check`: build `-Werror` clean, suite green, hlint `No hints`.
- [ ] If an existing test asserted the old fallback, it is rewritten with a
      comment explaining the new contract.

**Commit**: `fix(chat): do not re-send the bubble body when an edit fails`

---

## WU-2 — Telegram opts in, silently + over-limit close

**Files**: `Telegram.hs`, `Class.hs`, `Loop.hs`,
`test/.../TelegramAdapterSpec.hs`, `test/.../LoopSpec.hs`.

### 2.0 Churn to do first (enumerated, so the tree stays green)

- `TelegramChatTransport` gains
  `tctSendWithIdSilently :: Text -> Text -> IO (Maybe Text)` — breaks the
  hand-built literals at `TelegramAdapterSpec.hs:104-115` and `:134-145`.
- `mkMockTelegramChatTransport` (`Telegram.hs:99`) gains an edits recorder and a
  silent-send recorder, changing its return shape → **five** call sites
  `TelegramAdapterSpec.hs:55,60,68,77,84`.
- `Class.hs`: add `ccSendWithIdSilently`, defaulting to `ccSendWithId`.
- **Mock delegation (plan-gate finding):** `BubbleChan` (`LoopSpec.hs:85-93`) and
  `NoKeyboardChan` (`:102-109`) are `newtype`s over `MockChan` and must
  explicitly delegate `ccSendWithIdSilently`. Without that they inherit the
  class default, which aliases `ccSendWithId` - so the silent-create assertions
  in 2.2 would pass vacuously, exactly the failure WU-4 guards against for asks.

### 2.1 RED — pure facts

- `ccProgressStyle ch == PsSingleBubble`; `ccChunkLimit ch == Just limit`.
- Silent create records `silent=True`.

### 2.2 RED — turn shape

- **Tool turn ⇒ zero notifications before the answer**: the create is the
  *silent* variant, every later update is an edit, and no notifying send occurs
  until the answer.
- **Silent-create fallback**: `tctSendWithIdSilently` yields `Nothing` ⇒ the
  notifying `ccSendWithId` is used (progress not lost).
- **Two-tool turn**: one create, ≥1 edit on that id, exactly one `ccSend` with
  the answer. (Assumes succeeding edits — a failed edit means no bubble, by
  design.)
- **Tools-only turn → exactly ONE notification** (operator decision 3): 1
  create, ≥1 cursor-free edit, and exactly **one** notifying `ccSend` (the close
  notice). Not 0 (silent finish) and not 2.
- **Plain Q&A turn**: no create, exactly one `ccSend` (the answer), no close
  notice.
- **Empty turn** (no bubble, no answer): zero sends.
- **Over-limit turn**: tool call **first**, then a body over `ccChunkLimit`, then
  `idle`. Closing edit equals the §2.6 literal exactly, no cursor, full text
  delivered once.
- **Signal over-limit**: **also** gets the closing edit (guard dropped) -
  operator decision 4.

### 2.3 GREEN

- `Telegram.hs`: style, chunk limit, `ccSendWithIdSilently` via
  `disable_notification: true`.
- `Loop.hs` `updateBubble` create branch → `ccSendWithIdSilently`, falling back to
  `ccSendWithId` on `Nothing`.
- `Loop.hs` `finalizeSingleBubble`: replace the over-limit `dbg` + clear-id with
  one closing edit to the literal; **no** `ccProgressStyle` guard. Also read
  `hadBubble` before the close and, when the answer text is empty and a bubble
  existed, `ccSend` the close notice (Design 2.8).

### WU-2 DoD

- [ ] §2.0 churn compiles; all existing tests green.
- [ ] All §2.1/§2.2 items.
- [ ] `make check` green.

**Commit**: `feat(telegram): silent progress bubble, one notification per turn`

---

## WU-3 — Interval-gate both edit sources

**Files**: `Loop.hs`, `Types.hs`, `Class.hs`, `test/.../LoopSpec.hs`.

`ccEditIntervalMs` defaults to `spcEditIntervalMs defaultStreamProgressConfig`
(1500), so it cannot drift from `RateLimit.hs:38`.

**`updateBubble` gains a success result.** It is `IO ()` today
(`Loop.hs:1281-1284`), so a call site cannot tell whether an edit landed and
"advance only on success" is unexpressible. It becomes `IO Bool` - which its own
stale Haddock (`:1278`) already describes. Three call sites: `:1234` (frame),
`:1358` (finalize close), `:1509` (tool); only the two gated branches read it.

**Bucket semantics, stated once so the DoDs cannot contradict (plan-gate
finding):**

- A **create** does NOT set `ssLastBubbleEdit`. It is a create, not an edit.
- The first **edit** after a create therefore lands immediately.
- Every subsequent edit (frame or tool, same field) waits out the interval.
- A failed edit does NOT set it, so the next event retries.
- `idle`'s closing edit is **not gated** (gate lives at the two call sites, not
  inside `updateBubble`).

### 3.1 RED

`cccNow :: IO UTCTime` on `ChatChannelConfig`, overridden with an advanceable
clock in tests.

1. **Tool burst** - 10 tool calls inside one interval ⇒ the create plus **one**
   edit, whose body contains all 10 lines. (Not "one message": the create is
   separate from the edit.)
2. **Frame burst after a bubble exists** - tool call (creates), then 10 frames
   inside one interval ⇒ **one** edit carrying the final text. Frames alone never
   create (`:1232` is `hasBubble`-guarded), so the tool call is required setup.
3. **Interleaved** - frames and tool calls inside one interval ⇒ one edit total
   (proves the **shared** bucket).
4. **After the interval** - advancing the clock lets the next event edit.
5. **Fresh turn** - edits immediately (create/`resetStreamingState` cleared it).
6. **`idle` always edits** with the clock un-advanced (gate at call sites).
7. **Failed edit does not advance** the bucket ⇒ the next event retries.
8. **Routed seam** - advancing `cccNow` also moves the `PsSeparateMessages` path.
9. **`StopMaxTokens`** continuation under the gate: both segments delivered once.
10. **`/bg` with no frames** under the gate: one bubble, one delivery.
11. **Watch mode** under the gate: `/watch` still notifies once (it is a `ccSend`).
12. `PsSeparateMessages` cadence tests untouched.

### 3.2 GREEN

- `Types.hs`: `ssLastBubbleEdit :: IORef (Maybe UTCTime)`, cleared in
  `resetStreamingState`. **No** separate tool counter.
- `Class.hs`: `ccEditIntervalMs`.
- `Loop.hs`: `updateBubble` → `IO Bool`; route `:1238`'s `getCurrentTime` through
  `cccNow`; gate the frame (`:1231-1236`) and tool (`:1496-1511`) branches on the
  one field, setting it only on a successful edit.

### WU-3 DoD

- [ ] All twelve RED items.
- [ ] The bucket semantics above hold (create does not consume; first edit
      immediate; failures do not advance; idle ungated).
- [ ] `make check` green, hlint `No hints`.

**Commit**: `perf(chat): rate-limit single-bubble edits to one per interval`

---

## WU-4 — Ask regression guard, observability, docs, issues

**Files**: `Loop.hs`, `Class.hs`, `Telegram.hs`, `src/Seal/Telegram/Config.hs`,
`test/.../LoopSpec.hs`.

### 4.1 RED — test infrastructure first (completeness blocker)

- Add `mcSilentSends :: IORef [Text]` to `MockChan`, populated by a
  `ccSendWithIdSilently` override on the **class-level** mock (without it the
  default aliases `ccSendWithId` and the assertion is vacuous).
- Add a mock that is both `PsSingleBubble` **and** has a failing keyboard send
  (`BubbleChan.ccSendWithOptions` returns `Just` today, `:90`; `NoKeyboardChan` is
  `PsSeparateMessages`, `:102-109`).

### 4.2 RED — the ask must notify

- Options ask ⇒ `ccSendWithOptions` used, not the silent create.
- Failing keyboard send ⇒ notifying `ccSend` fallback fires.
- `mcSilentSends` is empty across all ask paths.

### 4.3 GREEN

- Log send failures (`Telegram.hs:487-500`, `:544-563`) with an allow-listed
  status only — never body, URL, or `show ex`.
- Haddocks: `ProgressStyle`; `ccSupportsStreaming` (unreachable under
  `PsSingleBubble`); `ccSendWithIdSilently` (asks must not use it);
  `updateBubble`'s no-send policy; `Seal.Telegram.Config` chunk note.
- File issue A (`ChatSendOutcome` symmetric sends + `retry_after`) and issue B
  (missing inbound allow-list).

### WU-4 DoD

- [ ] Ask-notifies tests green, and non-vacuous (they fail if the ask uses the
      silent path).
- [ ] `make check` green; hlint `No hints`.
- [ ] Both issues filed, URLs in the PR body.
- [ ] New log lines grep clean of token/URL/body.

**Commit**: `docs(chat): guard asks against silent sends; log send failures`

---

## Verification beyond unit tests

Manual run: `seal serve`, a Telegram channel, a multi-tool turn. Confirm
(a) **no** notification from the bubble or any tool call, (b) the bubble appears
and updates in place, (c) the answer is the turn's **only** notification, (d) an
`ASK_HUMAN` turn notifies with a usable keyboard, (e) the bubble lags ≤ ~3 s.

## Rollback (plan-gate finding: this was missing)

Four independent pieces, in increasing blast radius:

1. **WU-1** - restore the two lines at `Loop.hs:1298-1300` (`void (ccSendWithId
   chan content)`). Self-contained; no other file changes.
2. **WU-2 style/silent/chunk** - revert the three `TelegramChatChannel` methods
   to the class defaults; restore the over-limit `dbg` + clear-id and drop the
   close notice.
3. **WU-3 gates** - remove the two gate checks and the `ssLastBubbleEdit` field.
   Note this restores Signal's per-frame preview too, since the gate is shared.
4. **WU-4** - observability and docs only; safe to keep in every case.

If Telegram edit behaviour disappoints on a real device (Design 6), reverting
1+2 restores exactly today's Telegram behaviour while keeping the WU-1 fix,
which is correct for any channel.

## Risks carried from the design

- A failed/deferred **answer** send is a lost notification — pre-existing,
  follow-up filed; the largest residual gap.
- The gate is a burst limiter, not a guarantee; group chats degrade to a stale
  bubble, never a duplicate.
- A permanently uneditable bubble shows a stale preview for the rest of the turn
  (accepted, and the reason WU-1 needs no fallback send).
- Signal's preview cadence drops to ≤1 edit/1500 ms and its over-limit path now
  closes the bubble — both operator-approved changes to PR #328's code.
