# Restore `/bg` on gateway-API chat channels (rev 4)

<!-- status: awaiting user approval -->
<!-- date: 2026-10-25 -->
<!-- rev: 4 — applies every blocking finding from plan-review-gate iterations 1-3 -->

## Problem (regression chain — verified against git history + current code)

`/bg` ran a prompt in a fresh, untabbed session from a chat channel and
delivered the reply back to the originating conversation. It was an
**in-process** feature that was never ported when chat channels moved to the
gateway HTTP/WS API:

| Commit | Effect on `/bg` |
| --- | --- |
| `18092f7` | `/bg` added for chat channels: `BgRunner` + `backgroundCommandSpec` registered inline in `src/Seal/Channels/Loop.hs:236` (`git grep backgroundCommandSpec 18092f7 -- src`). Later refactored into `Seal.Channels.Loop.buildChannelRegistry`. |
| `ff2826c` | Tab-leak fix: `TurnEngine.shouldAutoTab` (`smChannel == "bg"` → no auto-tab) + `createConversationSessionHeadless`. |
| `b2896ce` (#199) | New `src-chat-channels` package speaks only the gateway API; `/bg` not ported (zero `bg` references in the package). |
| `99ddc53` | Old in-process channels deleted (incl. `mkBgRunner`, `isBgSlash`, `createConversationSessionHeadless`); `useNewChatChannels` removed. `/bg` now unreachable from every chat channel. |

Current path: `/bg foo` → `Chat.Route.route` → `ChatSlash "bg foo"` →
`sendSlash` (= `sendPlain`) → `POST /api/sessions/<focused>/send` →
`Seal.Gateway.Send.handleSend` → `Route.SlashCommand` → `runSlash` →
`Seal.Ingest.ingest` → `parseSlash` →
`ParseFailure "unknown command: bg"` (`src/Seal/Command/Parse.hs:127`) → posted
back to the chat. The gateway's slash registry
(`src/Seal/Command/Serve.hs:260`) has no `bg` spec; `backgroundCommandSpec`
exists only in the CLI (`src/Seal/Channel/Cli.hs:262`).

Routing note: `route "/bg"` yields `ChatSlash "bg"` — the single-char tab
branch requires end-of-string or a space after the char
(`src-chat-channels/Seal/Channels/Chat/Route.hs:62-72`), and `('b',"g")` fails
it; `/b` alone is a tab focus. The new `bg` case only needs to precede the
generic `otherwise -> ChatSlash` fallback.

Four further defects sit on the path this feature needs:

1. `handleSend` calls `ensureTabForSession` unconditionally
   (`src/Seal/Gateway/Send.hs:546`, `:564`, `:572`), bypassing
   `TurnEngine.shouldAutoTab` — a `channel="bg"` session driven over HTTP would
   be tabbed (re-regresses `ff2826c`).
2. `httpAnswerQuestion` always sends **both** `answer` and `scope`
   (`HttpClient.hs:126-135`), which `parseAnswerBody` rejects with 400
   (`Send.hs:964-984`, pinned by `test/Seal/Gateway/SendSpec.hs:692`) — the
   chat channel's button-tap answer path therefore never delivers an answer,
   and the error is discarded (`Loop.hs:982`).
3. `handleAsk` registers a pending ask only when `options` is non-empty
   (`Loop.hs:845-861`), so an option-less ask (open-ended `ASK_HUMAN`, or the
   confirmation gate, which uses `AskPrompt prompt []` —
   `src/Seal/Agent/Loop.hs:623`) can never be answered from a chat channel.
   Conversely, registered asks are only ever removed on a button tap
   (`Loop.hs:992`): text answers never dequeue, and `SeAskResolved` is ignored
   (`Loop.hs:437`).
4. With `/watch` on, **every** non-focused activity event goes to
   `handleWatchActivity` (`Loop.hs:425-436`), which would emit a bogus
   "Tab ? … finished thinking" plus a duplicate reply for each bg turn — bg
   sids must be excluded from the watch path.

## Approach

Keep `/bg` a chat-channel-only affordance (the web frontend does not need it;
`POST /send` must keep answering `unknown command: bg`).

- **Gateway seam A** — `POST /api/sessions/new` accepts optional
  `"headless": true` → session label `"bg"`.
- **Gateway seam B** — `handleSend` gates its three `ensureTabForSession` calls
  on `shouldAutoTab meta`.
- **Chat client bug fix** — `httpAnswerQuestion` sends exactly one field
  (`{answer}`), matching `parseAnswerBody`'s contract.
- **Chat channel** — intercept `/bg` locally (like `/watch`), mint a headless
  session, open **one WS connection focused on the bg session** (its
  `entry`/`ask` events are focus-matched, so the existing per-session handlers
  apply), `POST /send` the prompt, and close the connection when the turn
  reports `harness-status idle`. The conversation's own connection, session
  map, and tab tracking are untouched.

Deliberately **not** added (pre-regression parity): token-level streaming
bubbles for bg turns (`entry_update` is ignored on the bg connection; the reply
arrives on the recorded `entry`, as `mkBgRunner`'s `chSend` did). Tool-progress
lines are kept — the old `/bg` showed them via `StreamProgress`.

## Definition of Done

1. `/bg <prompt>` runs the prompt in a freshly minted, persisted session and
   posts the assistant reply back to that conversation (on the recorded
   response entry; `ccSend` on non-streaming channels).
2. The conversation's focused session is untouched: no `FocusOp` is sent on its
   connection, no `sessionInsert`, and a plain message sent afterwards still
   reaches it. `/bg` works even when the conversation has no session yet.
3. The bg session never appears in Active Tabs (`GET /api/tabs` unchanged after
   `/bg`); it does appear in Recent Sessions.
4. Blank prompt replies `usage: /bg <prompt>` and creates nothing; `/bg -h` /
   `/bg --help` prints the command help and creates nothing.
5. An `ASK_HUMAN` from a bg turn is rendered on the conversation and is
   answerable: inline buttons where supported, otherwise the next **plain-text**
   message (never a `/command`) answers it (numeric body → indexed option label,
   else raw text) and is not routed to the focused session. After answering, the
   ask is removed, so the following message routes normally again. An ask is
   answerable only from a conversation that owns its session (its focused
   session, or one of its own bg sessions).
6. Two concurrent `/bg` invocations are both tracked and both deliver; a text
   answer goes to the oldest pending bg ask.
7. Web behavior unchanged: `/bg` over `POST /api/sessions/:id/send` still
   returns `unknown command: bg` (pinned by a test); web turns still auto-tab;
   no gateway command is registered for `bg`.
8. `/watch` mode is unaffected: a bg turn never produces a watch notification.
9. `make check` (build + test + lint) green.

## Signature changes (enumerated, with test-site counts)

`BgSessions` (new loop-owned `TVar (Map ConversationKey [BgSession])`) is
threaded as one extra parameter through: `handleInbound` (1 src site
`Loop.hs:238`; 3 test sites `LoopSpec.hs:476,490,507`), `handleFocus`,
`handleCallback` (1 src site `Loop.hs:235`), `ensureWsConn`, `resolveSession`,
`handleNewSession`, `sendPlain`, `sendSlash`, `handleServerEvent` (22 test
sites). `BgSessions`/`BgSession`/`newBgSessions` are added to the module export
list so tests can construct the store.

`handleEntryUpdate` / `handleEntry` / `handleHarnessStatus` /
`handleToolCallActivity` change to take a `StreamingState` instead of
`(ConversationKey, wsConns)`; none is exported and there are no test call
sites, so this is internal only.

## Work units

### WU-1 — gateway: headless session creation
Files: `src/Seal/Gateway/API.hs` (`handleSessionNew`).
Change: parse optional `headless :: Bool`; channel label `"bg"` when true,
`"web"` otherwise. Still creates no tab, still broadcasts.
Tests (`test/Seal/Gateway/ApiSpec.hs`): `{"headless": true}` → created
session's `smChannel == "bg"` (read back from disk); absent flag and empty body
→ `"web"`.

### WU-2 — gateway: auto-tab respects `shouldAutoTab`; web `/bg` unchanged
Files: `src/Seal/Gateway/Send.hs`.
Change: `when (shouldAutoTab meta)` around the three `ensureTabForSession`
calls (`Send.hs:65` already imports `Seal.Core.TurnEngine`, so no cycle).
Tests (`test/Seal/Gateway/SendSpec.hs`):
- `channel="bg"` session + Plain turn → **no** tab **and** the scripted reply is
  recorded in `conversation.jsonl` (positive proof the turn ran, so the "no tab"
  assertion is not vacuous).
- regression guard: an existing `channel="web"` session still auto-tabs.
- **DoD 7 pin**: `handleSend` on a `"web"` session with the text `/bg hi`
  returns `SendSlash "unknown command: bg" Nothing` — the slash route's existing
  auto-tab behaviour for web sessions is unchanged and is not asserted.
- new fixture helper for a non-`web` channel session (`seedSession` at
  `SendSpec.hs:291` hard-codes `"web"`).

### WU-3 — chat channel: `/bg` route
Files: `src-chat-channels/Seal/Channels/Chat/Route.hs`.
Change: add `ChatBackground Text`, checked (case-insensitive, first word
`== "bg"`) before the generic `otherwise -> ChatSlash` fallback. Arg = text
after the first space, raw (may be empty, may quote).
Tests (`test/Seal/Channels/Chat/RouteSpec.hs`): `/bg` → `ChatBackground ""`;
`/bg hi there` → `ChatBackground "hi there"`; `/bg "quoted thing"` →
`ChatBackground "\"quoted thing\""`; `/BG x` → `ChatBackground "x"`; `/bgx` →
`ChatSlash "bgx"`; `/b` still `ChatFocus 'b'`; `/bg  extra` keeps inner
spacing. (`Loop.hs:270-298` gains the `ChatBackground` case — without it the
`case route body of` is non-exhaustive and `-Werror` fails the build.)

### WU-4 — chat channel: bg session lifecycle + delivery
Files: `src-chat-channels/Seal/Channels/Chat/Loop.hs`.
Change:
- `data BgSession = BgSession { bgSid :: !SessionId, bgWs :: WsClient,
  bgStream :: StreamingState, bgDelivered :: IORef Bool }`;
  `newtype BgSessions = BgSessions (TVar (Map ConversationKey [BgSession]))` in
  creation order, plus `newBgSessions`, exported.
- Streaming handlers take `StreamingState` (see signature list).
- Test seams on `ChatChannelConfig` (defaults = real `httpNewSession`,
  `httpSend`, `startWsClient`): `cccNewSession`, `cccSendMessage`,
  `cccStartWs`. Only `defaultChatChannelConfig` constructs the record.
- `handleBackground` (new; dispatched from `handleInbound`'s `ChatBackground`
  case): blank → `usage: /bg <prompt>`; `-h`/`--help` → `bgHelp`; else, in this
  order — mint a headless session → connect the WS client and `wcFocus` the bg
  sid → **register in `BgSessions`** → `POST /send` the prompt → confirm
  `bg session <short-id> started`. Registration precedes the send so
  `thinking`/`idle`/`entry` events for a fast turn are never handled before the
  sid is tracked (which would leak the connection and skip the watch exclusion).
- `handleBgServerEvent` (bg callback): acts only on events whose sid is the bg
  sid. `SeEntry` with `direction == "response"` → post the text, mark delivered.
  `SeAsk` → `handleAsk`. `SeActivity` `tool-call` → progress line;
  `harness-status idle` → finalize, close, untrack, **drop that sid's pending
  asks**; if nothing was delivered, post
  `bg session <short-id> produced no reply`. `SeEntryUpdate`, `SeLists`, other
  sids → ignored. `SeAskResolved` → drop the matching ask (shared with the main
  path, see WU-5).
- **Close trigger is `harness-status idle` only** — not `reply-delivered`,
  which fires at every turn end even when sub-agent children keep the session
  thinking (`TurnEngine.hs:588-591`).
- Failure paths (mint / connect / send) close what they opened, untrack, drop
  that sid's asks, and report on the channel.
- Cap: at most 4 live bg sessions per conversation; a fifth closes and
  untracks the oldest (bounds the leak when no `idle` ever arrives: the
  provider-resolution early return never enters the turn bracket
  (`TurnEngine.hs:536-547`), and a subscription refused by the broker's
  1024-subscriber cap delivers nothing).
- `handleServerEvent`: a non-focused `SeActivity` whose sid belongs to this
  conversation's `BgSessions` is ignored (never routed to
  `handleWatchActivity`) — DoD 8. Non-bg sids keep today's watch behaviour.
Tests (`LoopSpec.hs`; `MockChan` gains `ccSendWithOptions` and a `wcFocus`
recording stub):
blank prompt creates nothing; `-h` prints help and creates nothing; `/bg hi`
mints with `headless:true`, sends the prompt to the **new** sid (never the
conversation's), leaves the session map unchanged, and sends **no `FocusOp`**
on the conversation's client (DoD 2); `/bg` with no prior session still works
(DoD 2); a response entry on the bg connection is posted and marks delivered;
`entry_update`/`lists`/other-session events on that connection are ignored;
`idle` closes, untracks and drops that sid's asks; idle with no delivery posts
`produced no reply`; mint failure, connect failure, and send failure each
report, clean up, and leave nothing tracked; two `/bg` invocations are both
tracked and both deliver (DoD 6); a fifth evicts the oldest; a non-focused
`SeActivity` for a bg sid produces no watch notification while `/watch` is on
(DoD 8).

### WU-5 — chat channel: answer bg asks
Files: `src-chat-channels/Seal/Channels/Chat/Loop.hs`,
`src-chat-channels/Seal/Channels/Chat/HttpClient.hs`.
Change:
- `httpAnswerQuestion` sends `{"answer": ...}` only; add pure
  `answerBodyJson :: Text -> Value` used by the request so the wire shape is
  unit-tested. Applies to approvals too: `parseScopeReply`
  (`src/Seal/Agent/Loop.hs:635-644`) reads the text as `yes`→`once`, else
  `rejected` — the y/N semantics chat channels offer.
- `handleAsk` registers pending asks even when `options` is empty.
- `SeAskResolved` (both connections) removes the matching ask id (by 8-char
  prefix) from `pendingAsks`, so web-side answers, cancels, and timeouts stop
  being answerable (and stop accumulating).
- Answerable-session rule (DoD 5): the conversation's focused session plus its
  own bg sessions. `handleCallback` resolves the ask-id prefix among those sids
  only (today it uses `sessionLookup sessions key` alone —
  `Loop.hs:962-970`).
- Text answers: handled **in the `ChatPlain` branch of `handleInbound`**, i.e.
  after the `/watch` intercept and after `route` classifies the input, so a
  slash command is never consumed as an answer. If one of the conversation's bg
  sessions has a pending ask: answer it (numeric body → indexed option label,
  else raw text), post `✓ <label>`, **remove the ask**, and consume the
  message (do not route it to the focused session). Oldest-first: `handleAsk`
  prepends (`Map.insertWith (++)`, `Loop.hs:858`), so the oldest ask for a sid
  is the **last** element; bg sessions are scanned in creation order.
- Foreground (non-bg) asks remain button/web-only: the text-answer interception
  is bg-scoped, unchanged for the focused session.
Tests (`LoopSpec.hs`, `HttpClientSpec.hs`): `answerBodyJson` shape; bg ask
registers with and without options; inline-keyboard rendering via
`ccSendWithOptions`; numeric text maps to the indexed label and posts `✓`;
non-numeric text delivered raw (covers the confirmation gate's `y`/`yes`); the
message is not routed to the focused session; **after answering, the next plain
message routes to the focused session again** (ask dequeued); `SeAskResolved`
removes a pending ask; a callback tap resolves a bg ask; an ask belonging to
another conversation's session is neither rendered nor answerable; with two bg
sessions holding asks, the older one is answered; `/1` and `/watch` are never
consumed as answers.

## Known limitations (documented in the PR)

- A bg turn whose session never emits `harness-status idle` (provider
  resolution failure before the turn bracket; or a subscription refused by the
  broker's 1024-subscriber cap) keeps its WS connection until evicted by the
  per-conversation cap of 4, and delivers no reply.
- Foreground (non-bg) asks on channels without inline buttons still cannot be
  answered by a plain text message (pre-existing gap); their pending entries are
  now also cleared by `SeAskResolved`.
- WS events arriving between subscribe and the `focus` frame are dropped — the
  same benign race the main connection has; the bg path focuses before
  `POST /send`, so no turn events are affected.
- A lost WS connection mid-bg-turn (server restart) ends the reader loop
  silently (`WsClient.hs:83-90`); the bg session is reclaimed only by the cap.
- OpenAPI needs no change: `/sessions/new` documents a free-form body
  (`OpenApi.hs:103`).

## Backward compatibility / rollback

Additive: one route variant, one optional JSON field, three config fields with
production defaults, one extra loop-state parameter, and a bug fix in one
request body. Reverting restores today's behavior exactly (chat `/bg` →
`unknown command: bg`; CLI `/bg` unaffected).

## Verification

- `make check` (baseline on this checkout: 3169 examples, 0 failures, 41
  pending).
- Manual: `seal serve` + a chat channel → `/bg say hi` posts a confirmation and
  the reply; `GET /api/tabs` unchanged; `GET /api/sessions` shows the new
  session; a follow-up plain message still reaches the focused session; a bg
  turn that asks a question renders it and accepts `y` or a numeric option, and
  the message after the answer routes normally; `/watch` produces no
  notification for the bg turn.
