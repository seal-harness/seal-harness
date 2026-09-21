# Chat Channel Mid-Turn Focus Streaming & Gateway API Client Restructuring

> No backward compatibility needed — no users yet. We go straight to
> the end state.

## Problem

When a user runs `/6` in Signal to focus tab 6, the channel responds
with "focused tab 6" but none of the in-progress thinking appears.
The user expects that focusing a tab mid-turn should stream ALL
updates for that tab/session to the channel from that point forward —
and if the in-progress thinking bubble hasn't been created yet, one
should be created so intermediate output is visible.

Three gaps cause this:

1. **`/N` terse focus doesn't subscribe to replies.** The `/N` path
   in `runChannelLoop` updates the cursor and sends "focused tab N"
   but does NOT call `replySubscribe`. Compare with `handleTabFocus`
   (the `/tab focus <N>` path) which does subscribe.

2. **In-flight streaming is bound to a single channel handle.**
   `StreamProgress` is created lazily in `toolCallHook`, bound to the
   originating channel handle. When a new channel focuses mid-turn,
   there's no mechanism to wire it into the in-flight turn's streaming
   output.

3. **`taOnTextDelta` is `Nothing` for chat channels.** Text streaming
   via `StreamProgress.onTextDelta` is never wired. Only tool-progress
   bubbles work (via `taOnToolCall`).

But fixing these three gaps in isolation would be adding more layers
to the wrong architecture. The root cause is that chat channels have
deep in-process access to the harness internals (`ChannelDeps` with
`StreamBroker`, `ReplyRegistry`, `CursorStore`, `TurnEngine`, etc.)
instead of going through the gateway API like the web frontend does.

## Goal

Restructure chat channels to be pure gateway API clients (HTTP + WS),
implemented as separate Haskell packages in one Cabal file. This makes
the streaming feature a natural consequence — WS clients get streaming
for free via the existing WS protocol.

## Package Structure

One Cabal file, multiple `library` stanzas. Cabal enforces the
dependency boundaries at build time.

```
seal-gateway-types:   (depends on none of our packages)
seal-web-frontend:        seal-gateway-types
seal-chat-channels:       seal-gateway-types
seal-server:              seal-gateway-types seal-web-frontend seal-chat-channels
```

### `seal-gateway-types`

The shared protocol types that define the gateway API contract —
request/response shapes, WS event types, error codes. Both the server
and channel clients import these. No harness logic, no IO, no
implementation. Just types + codecs. Depends only on external
packages (aeson, text, etc.).

Examples: `SessionId`, `TabIndex`, `TabRef`, `FocusOp`, `ServerEvent`
(the WS event union), `SendRequest`, `SendResult`, `ListsSnapshot`,
`TranscriptEntry`. Many already exist scattered across
`Seal.Core.Types`, `Seal.Handles.*`, `Seal.Tabs.Types`,
`Seal.Gateway.StreamBroker`, and `frontend/src/types/stream.ts`.

### `seal-web-frontend`

The React/TS frontend, embedded into the binary via `file-embed`.
Already a pure gateway API client (HTTP + WS). No restructuring
needed — it is the model for how chat channels should work.

### `seal-chat-channels`

Signal + Telegram channel adapters. Each channel is a thin loop:

1. Receives messages from the platform (Signal/Telegram transport).
2. Translates them into gateway API calls (HTTP POST
   `/api/sessions/:id/send`, WS `FocusOp`).
3. Receives gateway API responses (WS events, HTTP responses) and
   translates them into platform messages (create/edit/send).

Dependencies: `seal-gateway-types` + external packages only. No
access to `Seal.Core.*`, `Seal.Session.*`, `Seal.ISA.*`,
`Seal.Gateway.*` (server internals).

### `seal-server`

The gateway server. Implements the HTTP API, the WS server, the turn
engine, the ISA registry, the agent loop, the session store, the tab
store. All harness logic lives here. Depends on all three other
packages.

### Cabal file sketch

```cabal
library seal-gateway-types
  exposed-modules:
    Seal.Gateway.Api.Types
    Seal.Gateway.Api.Types.Stream
    Seal.Gateway.Api.Types.Session
  build-depends:
    aeson, text, bytestring, ...

library seal-chat-channels
  exposed-modules:
    Seal.Channels.Signal
    Seal.Channels.Signal.Transport
    Seal.Channels.Telegram
    Seal.Channels.Telegram.Transport
    Seal.Channels.WsClient
    Seal.Channels.HttpClient
  build-depends:
    seal-gateway-types
    , websockets, http-client, text, ...

library seal-server
  exposed-modules:
    Seal.Gateway.API
    Seal.Gateway.Stream
    Seal.Gateway.Send
    Seal.Core.TurnEngine
    Seal.Agent.Loop
    Seal.ISA.Registry
    ...
  build-depends:
    seal-gateway-types
    , seal-web-frontend
    , seal-chat-channels
    , ...

executable seal
  main-is: Main.hs
  build-depends: seal-server, ...
```

### What stays the same

- **The CLI** (`Seal.Channel.Cli`) stays in `seal-server` (or a
  `seal-cli` stanza depending on `seal-server`). It is an interactive
  TUI with direct access to harness internals — not a gateway API
  client.
- **The transports** (`Seal.Channels.Signal.Transport`,
  `Seal.Channels.Telegram.Transport`) move to `seal-chat-channels`.
- **The gateway server** stays in `seal-server`.

## Architecture

### Current (chat channels have deep in-process access)

```
                     ┌─── web frontend ──→ WS broker ──→ entry-update events
Agent Loop ──────────┤
                     └─── chat channels ──→ ChannelDeps ──→ StreamProgress
                            (in-process       (StreamBroker,   (tool bubbles,
                             access to        ReplyRegistry,    no text streaming)
                             everything)      CursorStore,
                                             TurnEngine, ...)
```

### Target (chat channels are gateway API clients)

```
                     ┌─── web frontend ──→ WS connection ──→ entry-update events
                     │      (FocusOp over WS)                     │
Agent Loop ──────────┤                                          │
                     │                                          │
                     └─── chat channels ──→ WS + HTTP ──→ entry-update events
                            (FocusOp over WS)   (creates/edits
                            (POST /send)         messages)
```

Chat channels connect to the gateway's WS server (same protocol as
the web frontend), send `FocusOp` messages to focus sessions, receive
`entry-update` / `entry` / `activity` events, and translate them into
platform messages. Channel turns are sent via HTTP POST
`/api/sessions/:id/send`.

This eliminates `ChannelDeps`, `StreamProgress` (for chat channels),
the in-process `ReplyRegistry`/`CursorStore` for channels, and the
parallel streaming path. The gateway API is the single implementation
of all harness logic (DRY).

## Design

### Chat channel loop (end state)

The channel loop becomes:

1. Receive a message from the platform (Signal/Telegram transport).
2. Route it (`/N` → focus, `/tab focus N` → focus, plain text → send).
3. For a **focus**: send a `FocusOp` over the WS connection. The
   gateway updates the subscriber's focused session and replays
   entries. The channel sends "focused tab N" to the platform.
4. For a **plain message**: HTTP POST `/api/sessions/:id/send` with
   the text. The gateway runs the turn.
5. The WS background reader receives `entry-update` events (streaming
   text) and `entry` events (complete transcript entries). The
   channel creates/edits platform messages from these events.
6. When the turn completes, the final reply is delivered either via
   the WS `entry` event (which the channel can render as a new
   message) or via the WS `activity` event with `reply-delivered`.

### WS client module

New module `Seal.Channels.WsClient` (in `seal-chat-channels`):

```haskell
data WsClient = WsClient
  { wcFocus :: SessionId -> IO ()
    -- ^ Send a FocusOp for the given session.
  , wcClose :: IO ()
    -- ^ Close the WS connection.
  }

-- | Connect to the gateway's WS server. Spawns a background thread
-- that reads events and calls the callback for each.
startWsClient
  :: Text    -- ^ Host
  -> Int     -- ^ Port
  -> (ServerEvent -> IO ())
  -> IO WsClient
```

The event callback translates `entry-update` events into platform
messages:

- **First `entry-update` for a session**: send a new message via
  `chSendWithId`, store the message id. This is the "create the
  thinking bubble" the user asked for. The `entry-update` payload
  carries the FULL accumulated text (the web frontend's `webAskCaps`
  maintains an accumulator and broadcasts it on each delta), so the
  user sees the complete in-progress text, not just the tail.
- **Subsequent `entry-update`**: edit the existing message via
  `chEditMessage` with the new text + cursor. Rate-limited by
  `spcEditIntervalMs` / `spcBufferThreshold` (reusing the pure
  functions `shouldEdit`, `addCursor`, `stripCursor` — these move to
  `seal-gateway-types` or a shared utility module).
- **`entry` (complete transcript entry)**: finalize the streaming
  bubble (edit without cursor). This is the definitive text.
- **`activity` with `harness-status: idle`**: finalize any in-progress
  bubble. Handles turn errors/crashes.

### HTTP client module

New module `Seal.Channels.HttpClient` (in `seal-chat-channels`):

```haskell
-- | Send a message to a session via the gateway API.
httpSend :: Manager -> Text -> SessionId -> Text -> IO (Either Text SendResult)

-- | Get the session transcript (for last-reply delivery on focus).
httpGetTranscript :: Manager -> Text -> SessionId -> IO (Either Text [TranscriptEntry])

-- | Create a new session.
httpNewSession :: Manager -> Text -> NewSessionReq -> IO (Either Text SessionInfo)
```

### Session resolution

Currently, chat channels resolve sessions via the `CursorStore`
(per-conversation cursor → tab → SessionId). In the restructured
architecture, the channel needs to track which session each
conversation is focused on. This can be:

- **Client-side tracking**: The channel maintains a map from
  conversation id to session id (replacing `CursorStore`). On focus
  (`/N`), the channel resolves the tab's session id (via HTTP GET
  `/api/tabs` → tab list → tab N's session id) and sends a `FocusOp`.
- **Server-side tracking**: The gateway tracks per-conversation
  cursors. The channel sends a message with the conversation id, and
  the gateway resolves the session.

Client-side tracking is simpler and matches the web frontend's model
(the frontend tracks the focused tab client-side). The channel calls
`GET /api/tabs` to get the tab list, maps `/N` to the tab's session
id, and sends a `FocusOp` with that session id.

### Slash commands

Currently, chat channels dispatch slash commands via the in-process
registry. In the restructured architecture, the channel sends the
slash command text via `POST /api/sessions/:id/send` — the gateway
server already routes slash commands for the web frontend. The
channel receives the response (slash command output) via the WS
`entry` event or the HTTP response body.

For `/N` (tab focus) and `/tab focus N`, the channel intercepts these
locally (they're routing commands, not session messages) and sends a
`FocusOp` over WS instead of an HTTP POST. Other slash commands
(`/tab list`, `/tab new`, `/tab close`, `/new`, `/model`, `/skill`,
etc.) go through the HTTP API.

### ASK_HUMAN

Currently, chat channels use `AskReplyStore` for blocking prompts. In
the restructured architecture, ASK_HUMAN goes through the WS `ask`
event + HTTP `POST /api/sessions/:id/questions/:qid/answer` — same as
the web frontend. The channel receives the `ask` event, renders the
question on the platform, and sends the user's reply via the HTTP
endpoint.

### What gets removed

- `ChannelDeps` — replaced by WS + HTTP client calls.
- `StreamProgress` (for chat channels) — replaced by the WS client's
  event handler.
- `ReplyRegistry` (for chat channels) — the channel receives replies
  via WS events, not via in-process fan-out.
- `CursorStore` (for chat channels) — replaced by client-side session
  tracking.
- `runChannelLoop` — replaced by a simpler loop: receive from platform
  → HTTP/WS call → receive response → send to platform.
- `mkChannelTurnAdapter` — no longer needed (the turn engine is in the
  server, not the channel).
- `toolCallHook` — replaced by WS events (if tool-progress events are
  added to the broker; see below).
- `buildChannelRegistry` — slash commands go through the HTTP API.

### What gets kept (in `seal-server`)

- `StreamProgress` may still be used by the server for the web
  frontend's streaming (via `webAskCaps`'s `ccSend` → `BeEntryUpdate`).
  But the chat channel no longer has its own `StreamProgress`.
- `ReplyRegistry` stays for the web frontend's reply delivery (the
  web frontend doesn't use WS for final reply — it reads the
  transcript). Actually, with the WS approach, the web frontend also
  receives replies via WS `entry` events. The `ReplyRegistry` may be
  removable entirely, but that's a separate cleanup.

## Streaming Details

### Mid-turn focus (the key scenario)

When the user runs `/6` while tab 6's session is mid-turn:

1. The channel resolves tab 6's session id (via `GET /api/tabs`).
2. The channel sends a `FocusOp` over WS: `{"op":"focus","sessionId":"<sid>"}`.
3. The gateway's `streamApp` processes the `FocusOp`: calls
   `updateSubscriberSession`. Optionally replays entries if `since`
   is provided.
4. The next `entry-update` (the next text delta from the in-flight
   stream) arrives at the WS client's background reader.
5. The event handler creates a new message on the chat platform (via
   `chSendWithId`) — the "thinking bubble". The payload carries the
   full accumulated text, so the user sees all the in-progress text.
6. Subsequent `entry-update` events edit the message with new text.
7. When the turn completes, the `entry` event fires with the complete
   entry. The handler finalizes the bubble (edit without cursor).

The user sees: "focused tab 6" → streaming thinking text → finalized
reply. One message, progressively edited. No duplicate final message
(the `entry` event IS the final delivery; the handler edits the
streaming bubble to the final text).

### Rate limiting

The WS client receives `entry-update` events per text delta. The
event handler applies rate limiting before calling `chEditMessage`:
`spcEditIntervalMs` (1500ms default) and `spcBufferThreshold` (80
codepoints). The pure functions `shouldEdit`, `addCursor`,
`stripCursor` are shared (in `seal-gateway-types` or a utility
module).

### Tool-progress bubbles

The broker currently does NOT emit events for individual tool calls.
Tool-progress bubbles were sent via `StreamProgress.onToolCall` on the
originating channel. In the restructured architecture, the chat
channel doesn't have `StreamProgress` — so tool-progress bubbles are
NOT shown on chat channels unless we add tool-call events to the
broker.

**Decision**: Add `BeActivity` events for tool calls. The turn engine
already calls `aeOnToolCall` before each tool dispatch. Wire
`aeOnToolCall` in the server's turn adapter to broadcast a
`BeActivity` event with the tool name + redacted input. The WS client
receives these and renders tool-progress bubbles.

This unifies tool-progress through the broker — both the web frontend
and chat channels receive tool-progress via WS events.

### Edge cases

1. **Tab doesn't exist**: The channel resolves `/N` via `GET /api/tabs`.
   If tab N doesn't exist, send "focus failed: tab index out of range"
   to the platform. No `FocusOp` sent.

2. **Tab is idle**: The `FocusOp` is sent. No `entry-update` events
   arrive (no streaming in progress). When the next turn starts,
   events arrive and the handler creates the streaming bubble. The
   channel can optionally fetch and display the last assistant reply
   via `GET /api/sessions/:id/transcript` on focus (matching current
   `sendLastAssistantReply` behavior).

3. **Turn errors/crashes**: The turn engine's bracket cleanup
   broadcasts `harness-status: idle` on every exit path. The WS client
   receives this as an `activity` event and finalizes any in-progress
   bubble. Partial text is preserved (finalized, no cursor).

4. **WS connection drop**: The WS client reconnects with the current
   focus state. The `FocusOp` includes the `since` field (last entry
   id received) for entry replay, matching the web frontend's
   reconnect behavior. The streaming bubble is recreated from the
   replayed entries.

5. **Multiple conversations focusing the same tab**: Each chat channel
   loop has its own WS connection. The gateway broadcasts events to
   all WS connections focused on the session. Each channel creates/
   edits its own platform message.

6. **Rapid re-subscription**: Sending another `FocusOp` for the same
   session is a no-op on the server side (the subscriber's session
   doesn't change). The next `entry-update` carries the full
   accumulated text, so the existing streaming bubble is edited with
   the complete text.

7. **Long tool execution**: If `BeActivity` tool-call events are
   implemented, the user sees tool-progress bubbles during tool
   execution. Without them, no messages during tools — but the
   streaming text resumes when the LLM generates the next response.

### Standalone mode

In standalone mode (`seal signal` / `seal telegram` without `seal
serve`), there's no WS server. The channel needs the gateway API to
function. Options:

- **Require `seal serve`**: Chat channels only run under `seal serve`.
  Standalone `seal signal` / `seal telegram` are removed (no users
  yet). This is the simplest approach and the one we take.
- **Start a minimal HTTP+WS server internally**: The standalone
  command starts the gateway server on a random port, then connects
  the channel to it. More complex but preserves standalone mode.

Since we have no users, we require `seal serve` for chat channels.

## Implementation Plan

Three steps. Each produces a compilable, testable state. The
dependency hierarchy enforces the system organization.

### Step 1: Extract `seal-gateway-types`

Pull out all the plain Haskell types and trasa types for the gateway
API into a new `library` stanza called `seal-gateway-types`.

This includes:
- Protocol types: `SessionId`, `TabIndex`, `TabRef`, `FocusOp`,
  `ServerEvent` (the WS event union), `SendRequest`, `SendResult`,
  `ListsSnapshot`, `TranscriptEntry`, etc.
- Trasa route types: `SealRoute`, `Resp`, `Req`, the capture
  codecs (`SessionIdOrErr`, `TabIndexOrErr`, etc.).
- WS event types: `BrokerEvent`, `HelloEvent`, `EntryEvent`,
  `EntryUpdateEvent`, `ActivityEvent`, `ReplayEndEvent`, etc.
- Error types: `StreamErrorCode`, `DispatchError` (the wire shape).

These types already exist scattered across `Seal.Core.Types`,
`Seal.Handles.*`, `Seal.Tabs.Types`, `Seal.Gateway.StreamBroker`,
`Seal.Gateway.Route`, and `frontend/src/types/stream.ts`.
Consolidate them into `Seal.Gateway.Types.*` modules under the new
stanza.

`seal-gateway-types` depends only on external packages (aeson, text,
bytestring, trasa, etc.) — none of our other packages.

Pure refactor — no behavior change. `make check` stays green.

### Step 2: Create `seal-chat-channels` and move channel implementations

Create a new `library` stanza called `seal-chat-channels` that
depends only on `seal-gateway-types` (plus external packages like
`websockets`, `http-client`, `text`, etc.).

Move the Signal and Telegram channel implementations into this
package:
- `Seal.Channels.Signal` + `Seal.Channels.Signal.Transport`
- `Seal.Channels.Telegram` + `Seal.Channels.Telegram.Transport`

Add the WS client and HTTP client modules:
- `Seal.Channels.WsClient` — WS client for streaming events.
- `Seal.Channels.HttpClient` — HTTP client for gateway API calls.

Write a **generic chat-channel main loop** that is injected with
Telegram or Signal behavior. This is a nice place to use a **type
class** (to compare with the record-of-functions approach we have been
using elsewhere):

```haskell
class ChatChannel c where
  -- | Receive one inbound message from the platform.
  ccReceive :: c -> IO (Maybe MessageSource)
  -- | Send a message to the platform (plain text).
  ccSend :: c -> Text -> IO ()
  -- | Send a message and return its platform id (for editing).
  ccSendWithId :: c -> Text -> IO (Maybe Text)
  -- | Edit a previously sent message.
  ccEditMessage :: c -> Text -> Text -> IO Bool
  -- | The channel's label ("signal", "telegram").
  ccLabel :: c -> Text
```

The generic loop handles routing (`/N` focus, slash commands, plain
text), WS focus + streaming, HTTP send, and ASK_HUMAN — all through the
gateway API. The `ChatChannel` instance provides the platform-specific
I/O.

Since `seal-chat-channels` depends only on `seal-gateway-types`,
Cabal rejects any import of `Seal.Core.*`, `Seal.Session.*`,
`Seal.ISA.*`, `Seal.Gateway.*` (server internals). The channel's
only interface to the harness is the gateway API (HTTP + WS).

This step removes `ChannelDeps`, `StreamProgress` (for chat
channels), `ReplyRegistry` (for chat channels), `CursorStore` (for
chat channels), `mkChannelTurnAdapter`, `toolCallHook`, and
`buildChannelRegistry`. The channel loop becomes: receive from
platform → HTTP/WS call to gateway → receive response → send to
platform.

### Step 3: `seal-server` (the existing core gateway server)

The existing core gateway server and underlying code becomes a package
called `seal-server`. It depends on `seal-gateway-types`,
`seal-web-frontend`, and `seal-chat-channels`.

This is mostly the remaining code after Steps 1 and 2 pull types and
channels out: the HTTP API (`Seal.Gateway.API`), the WS server
(`Seal.Gateway.Stream`), the turn engine
(`Seal.Core.TurnEngine`), the ISA registry, the agent loop, the
session store, the tab store, the vault, the security layer, etc.

Wire `aeOnToolCall` in the server's turn adapter to broadcast
`BeActivity` events with tool name + redacted input, so chat
channels receive tool-progress via WS.

## Open Questions

1. **Tool-call events**: Should we add a new `BeActivity` sub-type for
   tool calls, or reuse the existing `BeActivity` with a new
   `ActivityEvent` variant? The existing `ActivityEvent` has
   `harness-status`, `entry-at`, `session-created`, `reply-delivered`.
   Adding `tool-call` is a new variant.

2. **Session tracking**: The channel needs to map conversation ids to
   session ids. Does it call `GET /api/tabs` on every focus, or cache
   the tab list (updated via WS `lists` events)? Caching is more
   efficient but adds complexity. MVP: call `GET /api/tabs` on focus.

3. **`/N` tab index resolution**: Tab indices can change (tabs are
   compacted on close). The channel resolves `/N` to a session id via
   the tab list. If the tab list changed between the user's last
   interaction and the `/N` focus, the index may point to a different
   session. This is the same behavior as the web frontend (tab indices
   are positional, not stable). Acceptable.

4. **WS connection per channel or per conversation?**: One WS
   connection per channel loop (Signal, Telegram). The connection's
   focused session changes on `/N`. Multiple conversations on the same
   channel share one WS connection — but a WS connection can only be
   focused on one session at a time. This is a problem: if conversation
   A focuses tab 3 and conversation B focuses tab 7, the single WS
   connection can't receive events for both sessions simultaneously.

   **Solution**: One WS connection per conversation (not per channel).
   Each conversation has its own focus state. The channel loop
   maintains a map from conversation id to WS connection. This is more
   connections but matches the web frontend's model (each browser tab
   has its own WS connection).

   Alternatively: one WS connection that receives ALL session events
   (no focus filter), and the channel filters client-side. This avoids
   the per-conversation connection but receives more events. The
   broker's `shouldSend` filter currently sends only events for the
   subscriber's focused session — changing this to "all events" would
   increase traffic. Not recommended.

5. **Standalone mode**: We require `seal serve` for chat channels. Is
   this acceptable, or do we need a minimal internal server for
   standalone mode? Since we have no users, requiring `seal serve` is
   fine.