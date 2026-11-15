# Signal notification policy + ASK_HUMAN rendering — Implementation Plan (Rev 8)

> **Operator requirement**: focused session shows all channel activity, concise
> (minimal notifications); `/watch on` sends only the final update, and only on
> one of two conditions — turn finished (thinking → idle) or ASK_HUMAN.
> Operator approved the **offset-splice** design after the gate escalated.

## Status: IMPLEMENTED — PR #328 (closes #327)

All five work units landed on `channels/signal-notification-policy`:

| WU | Delivered |
|---|---|
| 1 | pure bubble core (`Bubble.hs`) |
| 2 | single-edited-bubble style in the loop (inert) |
| 3 | Signal opts in + safe edit-timestamp parse |
| 4 | open-ended ASK_HUMAN reply hint |
| 5 | `/watch` reports ASK_HUMAN, and can answer it |

`make check` green: build clean, 4452 examples / 0 failures, hlint "No hints".

Two bugs were found by this plan's own QuickCheck properties during TDD, both
in the new pure code: `bubbleText` first applied splice offsets against the
*remaining* text rather than the original (collapsing the text between two
tool lines), and `chunkMessage` first dropped the break separator at each
split (silently losing characters, caught by the round-trip property).

**Outstanding before merge**: the §4 manual Signal device check. Everything
else is verified by the suite.

## 0. Why offset-splice

The gateway's streaming accumulator is **turn-scoped**: `webAskCaps` creates
`accRef` once per turn and appends every delta (`Send.hs:895,902`), and every
`entry-update` frame carries the whole accumulator (`:927`, `:967-970`). So a
frame after tool 2 already contains response 1's text again. Any design that
commits per-response text into blocks and *also* renders frames double-counts.

Offset-splice inverts it: the cumulative frame text is the **sole** body, and
each tool line is remembered with the offset (cumulative length) at which it
fired. Rendering splices tool lines into that text at their offsets. Because the
text source is monotone and the offsets are absolute, there is no duplication,
and tool lines appear **where they happened** — not dumped at the end.

Worked example. Frames carry `"T1"`, then `"T1T2"`, then `"T1T2T3"`; tool 1 fires
when the accumulated length was 2, tool 2 when it was 4. Render `"T1T2T3"` with
`[(2,"tool1"),(4,"tool2")]` ⇒ `T1 · tool1 · T2 · tool2 · T3`. Exact ordering, one
bubble.

## 1. Problem

### 1.1 Focused turn spams one notification per tool call

`Signal.hs:442` sets `ccSupportsStreaming _ = False`, so `handleEntryUpdate`
accumulates without editing and each of `handleHarnessStatus` (idle),
`handleEntry`, and `handleToolCallActivity` flushes the accumulated text as a
**new message**; separately `handleToolCallActivity` posts every tool line via
`ccSend chan line` (`Loop.hs:1224`). A 5-tool turn yields ~6 notifications.

### 1.2 Watch mode cannot distinguish "needs input" from "finished"

`handleWatchActivity` (`Loop.hs:952-975`) sends one notification per
thinking→idle, always worded "finished thinking", and `/watch`'s confirmation and
help promise only that (`Loop.hs:908-909`, `:927`). Because
`wrapCapsForAskStatus` emits `idle` before blocking on a prompt
(`Broadcast.hs:178-183`), an ASK_HUMAN on a watched session is announced as a
finished turn with the wrong text.

### 1.3 ASK_HUMAN renders badly on Signal

`chunkMessage` (`Signal.hs:65-73`) claims word-boundary splitting but does raw
`T.take`/`T.drop`; `handleAsk` (`Loop.hs:1243-1249`) sends an open-ended ask as
the bare question; `sctEditMessage` parses a timestamp with a partial
`read (…) :: Int` (`Signal.hs:176`).

## 2. Design

### 2.1 Pure core (no IO, fully testable)

```haskell
-- | A tool line and the length of the streamed text when it fired.
type Splice = (Int, Text)

-- | Splice tool lines into the cumulative turn text at their offsets.
-- Offsets are clamped to the text length (a frame may not have caught up
-- yet). Blocks are separated by a blank line; empty text contributions are
-- dropped. Pure.
spliceBubble :: [Splice] -> Text -> Text -> Text
```

`spliceBubble splices text cursor` walks the splice list in offset order,
emitting `take k rest`, then `"\n\n" <> line <> "\n\n"`, then continuing. The
cursor is appended once at the end.

```haskell
-- | Render an ask with a reply hint. Pure.
formatAsk :: Text -> [QuestionOption] -> Text
formatAsk q []   = q <> "\n\nReply with your answer."
formatAsk q opts = q <> "\n\n" <> numbered <> "\n\n"
                   <> "Reply with a number or type your own answer."
```

```haskell
-- | Word/newline-aware chunking. Splits at the last newline (then space)
-- inside the limit; hard-splits only a token longer than the limit. Pure.
chunkMessage :: Int -> Text -> [Text]
```

### 2.2 Loop behaviour (`PsSingleBubble` only)

State on `StreamingState`:
- `ssSplices :: IORef [Splice]` — tool lines with their stream offsets.
- `ssAccumulated :: IORef Text` — the latest frame's cumulative text.

| Event | `PsSingleBubble` | `PsSeparateMessages` (default) |
|---|---|---|
| `entry-update` | store text; create bubble once, then edit `spliceBubble splices text cursor` | unchanged |
| `tool-call` | append `(T.length text, line)`; edit `spliceBubble splices text ""` | unchanged |
| `entry` | **create-or-edit** to `spliceBubble splices text ""` using the recorded text as `text` (exact, XML-stripped) when it is longer; **do not** set `ssFinalized` | unchanged |
| `idle` | final edit (no cursor), set `ssFinalized`, reset | unchanged |

Properties, each mapped to a failure the gate found:

- **No duplication** — the frame text is turn-cumulative and monotone; offsets
  are absolute, never re-added. (Rev 5-7 flaw.)
- **No truncation** — the recorded entry supplies exact text and the frame
  supplies the tail; neither alone is trusted. (Rev 6 flaw.)
- **One notification per turn** — first frame creates the bubble; all later work
  is edits.
- **`/bg` works** — `handleEntry` creates on demand, so a bg connection that
  never receives `entry-update` (`Loop.hs:719-728`) still gets one bubble; the
  `delivered` flag and the "produced no reply" fallback are untouched.
  (Rev 6-7 flaw.)
- **Continuations work** — `StopMaxTokens` responses append to the same
  cumulative text; nothing overwrites an earlier segment. (Rev 7 flaw.)
- **No mid-turn latch** — `ssFinalized` is set only by `idle`.
- **Cursor** — previews carry it; every commit strips it, so a withheld `idle`
  (`TurnEngine.hs:590-595`) never leaves a stale cursor or lost text.
- **Overflow** — if the rendered body exceeds the channel's limit, stop editing;
  the final delivery goes through the chunked `ccSend` path.

`ccChunkLimit :: Maybe Int` is added to `ChatChannel` (default `Nothing`), so the
polymorphic loop can read the limit — `sccChunkLimit` is Signal-only
(`Signal.hs:402`) and was unreachable from `Loop.hs`.

### 2.3 Watch mode: two conditions, deduped by the existing ask store

No new store, no new state machine. `pendingAsks` is **already in scope** at the
`handleServerEvent` call site (`Loop.hs:811`), so it is passed to
`handleWatchActivity` (one extra argument — not a cascade).

`handleWatchActivity`'s `idle` branch:
1. **Re-check `cccGetQuestions` up to 5× at 100 ms** (≤ ~500 ms), because `idle`
   precedes ask registration (`Broadcast.hs:178-183` vs `AskReply.hs:405-406`).
2. Question found ⇒ **register it into `PendingAsks`** (with `paSeq` and
   `paOptions`), send `"📔 Tab N (title) needs your input"` then `formatAsk`.
3. Otherwise ⇒ `"📔 Tab N (title) finished thinking"` + last assistant reply.

**Dedupe without a new store**: a needs-input notification is sent only when the
ask id is **not already** in `PendingAsks` for that session. That single
condition replaces Rev 5-7's `AwaitingAnswer` state machine, its unreachable
exit (`BeAskResolved` is session-filtered, `StreamBroker.hs:219`), and its
timeout. Clearance is automatic: `SeAskResolved` → `forgetAskByPrefix`
(`Loop.hs:729,851`), `answerAsk` → `forgetAsk` (`Loop.hs:1533`), and the poll
itself stops finding answered questions.

Consequence: after the answer, the resumed turn's `idle` polls an empty list and
sends the "finished thinking" notification — which is correct and desired, and
is why "exactly one notification per ask turn" is false: an ask turn correctly
yields needs-input *then* finished. That is two notifications for two distinct
facts the operator asked to be told.

`/watch`'s confirmation and help are rewritten to name both triggers.

Answering: `answerPendingBgAsk` → `answerPendingAsk`, unioning the conversation's
watched sessions with `bgSessionsFor`; `paSeq` ordering preserved; `bgOwnsSession`
guard preserved (`Loop.hs:840-845`; test `LoopSpec.hs:2009-2050`).

New seam: `cccGetQuestions :: Manager -> Text -> SessionId -> IO (Either Text [Value])`,
default `httpGetQuestions` → `GET /api/sessions/:id/questions`, which returns
`id`, `question`, `createdAt`, `options` (`API.hs:3033-3047`).

**Deliberate override, stated**: `handoff-2026-10-25-1345.md:130` records
foreground asks as button/web-only. A "needs your input" notification that
cannot be answered where it was read fails the requirement, so this lifts it for
*watched* sessions only. Focused asks keep today's behaviour (`Loop.hs:847-848`).

### 2.4 Opt-in per channel, so Telegram is untouched

```haskell
data ProgressStyle = PsSeparateMessages | PsSingleBubble
ccProgressStyle :: c -> ProgressStyle
ccProgressStyle _ = PsSeparateMessages   -- default: today's behaviour

ccChunkLimit :: c -> Maybe Int
ccChunkLimit _ = Nothing                 -- default: no split
```

`SignalChatChannel` returns `PsSingleBubble` and `Just sccChunkLimit`.
`TelegramChatChannel` and `LoopSpec`'s `MockChan` inherit both defaults and keep
today's behaviour byte-for-byte. `ccSupportsStreaming` keeps its meaning ("can
the platform edit?") and stays as-is per channel; its Haddock is corrected since
it no longer selects the message strategy.

## 3. Work units (ordered; each leaves the tree green)

### WU-1: Pure core + types

**Files**: `src-chat-channels/Seal/Channels/Chat/Types.hs`,
`src-chat-channels/Seal/Channels/Chat/Bubble.hs` (new),
`seal-harness.cabal`, `test/Main.hs`,
`test/Seal/Channels/Chat/BubbleSpec.hs` (new)

Wiring is three places, per the repo's convention (cf. `ToolRender` at
`seal-harness.cabal:88`, and `TypesSpec` at `:564` + `test/Main.hs:118,344`):
library `exposed-modules`, test-suite `other-modules`, and both the import and
the `spec` entry in `test/Main.hs`.

- `ProgressStyle`, `Splice`, `spliceBubble`, `formatAsk`, `chunkMessage` (moved
  and fixed; Signal's copy delegates).
- `StreamingState`: add `ssSplices :: IORef [Splice]`; clear in
  `resetStreamingState`.

**DoD**: `spliceBubble [] "abc" "" == "abc"`;
`spliceBubble [(2,"X")] "abcd" "" == "ab\n\nX\n\ncd"`;
`spliceBubble [(2,"X"),(4,"Y")] "T1T2T3" ""` style ordering preserved;
`spliceBubble [(99,"X")] "ab" "▉" == "ab\n\nX\n\n▉"` (clamped);
`formatAsk "Q" [] == "Q\n\nReply with your answer."`;
`chunkMessage 60` on a 3-option list keeps each `N) label` line whole;
`chunkMessage 5 "abcdefghij" == ["abcde","fghij"]`.

### WU-2: Loop support (inert — no channel opts in yet)

**Files**: `src-chat-channels/Seal/Channels/Chat/Class.hs` (both new methods),
`src-chat-channels/Seal/Channels/Chat/Loop.hs`,
`test/Seal/Channels/Chat/LoopSpec.hs`

Branch the three `ccSupportsStreaming` sites (`Loop.hs:1081`, `:1192`, `:1217`) on
`ccProgressStyle`; share one create-or-edit helper across the four table rows;
relax the idle gate (`Loop.hs:1191-1193`); update the superseded comment
(`Loop.hs:1199-1211`). Lands **before** any channel opts in, so the whole
existing suite stays green and Telegram/`MockChan` are untouched.

**DoD**: existing suite unchanged and green; with a `PsSingleBubble` test double,
a 2-tool turn with text either side creates exactly ONE bubble and the final
body shows text/tool/text/final in order, each once, no cursor; a tools-only turn
creates and finalizes one bubble; a `/bg` single-response turn with no
`entry-update` creates one bubble and posts once; a `StopMaxTokens` continuation
keeps both segments; an edit failure falls back to a fresh send.

### WU-3: Signal opts in

**Files**: `src-chat-channels/Seal/Channels/Chat/Signal.hs`,
`test/Seal/Channels/Chat/SignalAdapterSpec.hs`

`ccProgressStyle _ = PsSingleBubble`; `ccChunkLimit _ = Just (sccChunkLimit ch)`;
`sctEditMessage` via `Data.Text.Read.decimal` (non-numeric ⇒ `False`).

**DoD**: `ccProgressStyle` is `PsSingleBubble`; a non-numeric timestamp yields
`False` with no exception; the four pinned `chunkMessage` cases still hold.

### WU-4: ASK_HUMAN rendering

**Files**: `Loop.hs`, `test/Seal/Channels/Chat/LoopSpec.hs`

`handleAsk` uses `formatAsk` for the open-ended path and the no-keyboard
fallback; `formatQuestionWithOptions` delegates to it.

**DoD**: open-ended ask sends the hint form; an options ask sends `N) label —
description` plus the numeric hint; a keyboard-capable channel still gets
`ccSendWithOptions` and no duplicate text.

**Test churn**: `LoopSpec.hs:743` pins `formatQuestionWithOptions "Hello?" [] ==
"Hello?"`; it becomes the hint form. `Seal.Handles.AskReply`'s separate
`formatQuestionWithOptions` (CLI, `Cli.hs:167,214`) does not change.

### WU-5: Watch mode reports ASK_HUMAN

**Files**: `Loop.hs`, `HttpClient.hs` (+ `httpGetQuestions`), `LoopSpec.hs`,
`HttpClientSpec.hs`

Per §2.3, plus `cccGetQuestions` in `ChatChannelConfig`,
`defaultChatChannelConfig`, and `stubCfg`.

**DoD**: watch on + a watched session that asks ⇒ one needs-input notification
containing the question, and the ask registered in `PendingAsks`; the same ask
not re-notified on a later idle; a watched session that only finishes ⇒ finished
notification, no question; a plain-text reply to a watched ask reaches
`cccAnswerQuestion` with that session's id (`paSeq` preserved); an ask answered
from the web (no `BeAskResolved` here) is not re-notified, and the next turn's
idle yields the finished notification; watch off ⇒ neither; `/watch on` and
`/watch -h` name both triggers; a retired bg session's ask does not notify
(`LoopSpec.hs:2009-2050` green).

## 4. Verification beyond unit tests

**Signal edit behaviour must be confirmed on a device before merge**: one manual
run of `seal serve`, a multi-tool turn, checking the phone receives one
notification and the bubble updates in place. `Signal.hs:439-441` says edits are
"flaky in practice" and this plan overrides that. If it fails, WU-3's
`ccProgressStyle` reverts to the default (one value) and WU-4/WU-5 still land;
WU-2 becomes inert. That revert is the rollback path — no data migration.

## 5. Risks

- **Edit support**: bounded by "create once, then edit"; a failing edit falls
  back to a fresh send rather than losing text.
- **Overflow**: a body past the channel limit falls back to chunked sends.
- **Two asks in one turn**: the oldest is announced; the next on a later idle.
- **Focused *and* watched**: skipped when `sid == focusedSid`.
- **Test churn**: the 3 tool-emoji tests (`LoopSpec.hs:639-695`), the 3 streaming
  tests (`:412-525`), the `formatQuestionWithOptions` test (`:737-743`), the
  Signal streaming test (`SignalAdapterSpec.hs:212-245`). Telegram's tests stay
  untouched and must stay green.
