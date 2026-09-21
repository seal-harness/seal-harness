# Implementation Plan: seal-chat-channels Package (Step 2)

> Issue #198 · Branch `channels/seal-chat-channels-198` · PR #199

## Goal

Create a new `seal-chat-channels` Cabal library stanza that reimplements
Signal and Telegram chat channels as pure gateway API clients (HTTP + WS).
The new package depends only on `seal-gateway-types` + external packages.
The existing channel implementations stay in place for behavioral
comparison.

## Architecture

```
seal-gateway-types  ← shared protocol types (already exists)
        ↑
seal-chat-channels  ← NEW: depends only on seal-gateway-types
  Seal.Channels.Chat.Class       — ChatChannel type class
  Seal.Channels.Chat.Types       — shared types
  Seal.Channels.Chat.Route       — pure routing (/N, /tab, plain, slash)
  Seal.Channels.Chat.RateLimit   — pure shouldEdit/addCursor/stripCursor
  Seal.Channels.Chat.HttpClient  — HTTP calls to gateway API
  Seal.Channels.Chat.WsClient    — WS client for streaming events
  Seal.Channels.Chat.Loop        — generic chat-channel main loop
  Seal.Channels.Chat.Signal      — Signal ChatChannel instance + transport
  Seal.Channels.Chat.Telegram    — Telegram ChatChannel instance + transport
        ↑
seal-harness (server)  ← depends on seal-chat-channels
  Seal.Command.Serve forks the new channel handlers
```

## Work Units

### WU-1: Package skeleton + shared types + pure functions

**Files:**
- `seal-harness.cabal` — add `library seal-chat-channels` stanza
- `src-chat-channels/Seal/Channels/Chat/Types.hs` — shared types
- `src-chat-channels/Seal/Channels/Chat/Route.hs` — pure routing
- `src-chat-channels/Seal/Channels/Chat/RateLimit.hs` — pure rate-limiting
- `test/Seal/Channels/Chat/RouteSpec.hs` — routing tests
- `test/Seal/Channels/Chat/RateLimitSpec.hs` — rate-limit tests

**Types module:**
- `InboundMessage` — (MessageSource, body Text) from the platform
- `ChatMessageId` — newtype Text for platform message ids
- `StreamingState` — mutable state for one streaming bubble (IORef-based)
- `SessionMap` — conversation key → SessionId map (client-side cursor replacement)
- `GatewayConfig` — host, httpPort, wsPort, baseUrl

**Route module (pure, no IO):**
- Reimplements `Seal.Routing.Route.route` using `Seal.Gateway.Types.Tab`
  (TabIndex, tabIndexFromChar). Returns `ChatRoute` ADT:
  `ChatFocus TabIndex | ChatInject TabIndex Text | ChatPlain Text |
   ChatTabCommand TabSlashCommand | ChatCurrentTab | ChatNewSession Text |
   ChatSlash Text`
- Does NOT import `Seal.Routing.Route` or `Seal.Handles.Tab` — uses only
  `Seal.Gateway.Types.Tab` for `TabIndex`/`tabIndexFromChar`.

**RateLimit module (pure, no IO):**
- `StreamProgressConfig` — same fields as existing (enabled, editIntervalMs,
  bufferThreshold, cursor)
- `shouldEdit`, `addCursor`, `stripCursor` — copied from StreamProgress.hs
  (pure functions, no dependencies on internal types)
- `defaultStreamProgressConfig`

**DoD:**
- [ ] `seal-chat-channels` stanza compiles with empty exposed-modules
- [ ] Types module compiles, depends only on seal-gateway-types
- [ ] Route module compiles, route function matches existing behavior
- [ ] RateLimit module compiles, pure functions match existing behavior
- [ ] RouteSpec tests pass (all existing routing test cases)
- [ ] RateLimitSpec tests pass (shouldEdit, addCursor, stripCursor)
- [ ] `make check` green

### WU-2: HTTP client + WS client

**Files:**
- `src-chat-channels/Seal/Channels/Chat/HttpClient.hs`
- `src-chat-channels/Seal/Channels/Chat/WsClient.hs`
- `test/Seal/Channels/Chat/HttpClientSpec.hs`
- `test/Seal/Channels/Chat/WsClientSpec.hs`

**HttpClient module:**
- `httpSend :: Manager -> Text -> SessionId -> Text -> IO (Either Text SendResult)`
  — POST `/api/sessions/:id/send` with `{"message": text}`
- `httpGetTabs :: Manager -> Text -> IO (Either Text [TabJson])`
  — GET `/api/tabs`, parse JSON array of tab objects
- `httpGetTranscript :: Manager -> Text -> SessionId -> IO (Either Text [Value])`
  — GET `/api/sessions/:id/transcript`
- `httpNewSession :: Manager -> Text -> NewSessionReq -> IO (Either Text SessionInfoJson)`
  — POST `/api/sessions/new`
- `httpAnswerQuestion :: Manager -> Text -> SessionId -> Text -> Text -> Text -> IO (Either Text ())`
  — POST `/api/sessions/:id/questions/:qid/answer` with `{"answer": ..., "scope": ...}`
- `httpStopSession :: Manager -> Text -> SessionId -> IO (Either Text ())`
  — POST `/api/sessions/:id/stop`
- Wire types: `SendResult` (kind, response, session_id), `TabJson` (index,
  kind, label, session_id, status), `SessionInfoJson` (id, runtime, model, ...)
- All return `Either Text a` — errors are text, never thrown

**WsClient module:**
- `data WsClient = WsClient { wcFocus :: SessionId -> IO (), wcClose :: IO () }`
- `startWsClient :: Text -> Int -> (ServerEvent -> IO ()) -> IO WsClient`
  — connects to `ws://host:port`, sends hello, spawns background reader
  that decodes JSON frames and calls the callback
- Decodes wire JSON to `ServerEvent` (from `Seal.Gateway.Types.Stream`):
  parse the `type` field, dispatch to SeEntry/SeEntryUpdate/SeActivity/etc.
- `wcFocus sid` sends `{"op":"focus","sessionId":"<sid>"}` (FocusOp JSON)
- Reconnect logic: on connection drop, reconnect with `since` field
- Uses `websockets` client library + `connection` package

**DoD:**
- [ ] HttpClient compiles, all functions return `Either Text a`
- [ ] WsClient compiles, `startWsClient` spawns background reader
- [ ] HttpClientSpec: mock HTTP server tests for send, getTabs, newSession
- [ ] WsClientSpec: mock WS server test for focus + event delivery
- [ ] `make check` green

### WU-3: ChatChannel class + generic loop

**Files:**
- `src-chat-channels/Seal/Channels/Chat/Class.hs`
- `src-chat-channels/Seal/Channels/Chat/Loop.hs`
- `test/Seal/Channels/Chat/LoopSpec.hs`

**ChatChannel class:**
```haskell
class ChatChannel c where
  ccReceive  :: c -> IO (Maybe InboundMessage)
  ccSend     :: c -> Text -> IO ()
  ccSendWithId :: c -> Text -> IO (Maybe Text)
  ccEditMessage :: c -> Text -> Text -> IO Bool
  ccLabel    :: c -> Text
```

**Generic loop:**
- `runChatChannel :: ChatChannel c => GatewayConfig -> Manager -> c -> IO ()`
- Main loop: `ccReceive` → route → dispatch:
  - `ChatFocus idx` → `httpGetTabs` → resolve tab N's session_id →
    `wcFocus sid` → send "focused tab N" to platform
  - `ChatSlash cmd` → `httpSend` to the conversation's session →
    receive slash result via HTTP response
  - `ChatPlain text` → `httpSend` to the conversation's session →
    receive streaming via WS `entry-update` events
  - `ChatNewSession args` → `httpNewSession` → update session map →
    `wcFocus` new session
  - `ChatTabCommand` → `httpSend` with the command text
- Session resolution: `SessionMap` (TVar map from ConversationKey to
  SessionId). First message from a conversation → `httpNewSession` →
  store in map.
- WS event handler (background thread per conversation):
  - `SeEntryUpdate sid val` → extract accumulated text from val →
    create/edit platform message (rate-limited via shouldEdit/addCursor)
  - `SeEntry sid val` → finalize streaming bubble (edit without cursor)
  - `SeActivity sid val` → check for `harness-status: idle` → finalize
  - `SeAsk sid val` → render question on platform, wait for answer,
    `httpAnswerQuestion`
- One WS connection per conversation (per design open question #4)

**DoD:**
- [ ] ChatChannel class compiles with 4 methods
- [ ] Generic loop compiles, routes all ChatRoute variants
- [ ] SessionMap tracks conversation → session mapping
- [ ] WS event handler creates/edits/finalizes streaming bubbles
- [ ] ASK_HUMAN flow: WS ask event → platform question → HTTP answer
- [ ] LoopSpec: mock channel + mock HTTP server tests for all routes
- [ ] `make check` green

### WU-4: Signal + Telegram channel adapters

**Files:**
- `src-chat-channels/Seal/Channels/Chat/Signal.hs`
- `src-chat-channels/Seal/Channels/Chat/Signal/Transport.hs`
- `src-chat-channels/Seal/Channels/Chat/Telegram.hs`
- `src-chat-channels/Seal/Channels/Chat/Telegram/Transport.hs`
- `test/Seal/Channels/Chat/SignalSpec.hs`
- `test/Seal/Channels/Chat/TelegramSpec.hs`

**Signal adapter:**
- `SignalChatChannel` record — wraps the transport + inbox + allow-list
- `ChatChannel SignalChatChannel` instance:
  - `ccReceive` — pull from inbox (MessageSource, body)
  - `ccSend` — chunked send to last sender
  - `ccSendWithId` — send + return timestamp
  - `ccEditMessage` — edit via signal-cli
  - `ccLabel` — "signal"
- `withSignalChatChannel :: ... -> (SignalChatChannel -> IO a) -> IO a`
  — bracket that spawns reader thread

**Telegram adapter:**
- `TelegramChatChannel` record — wraps transport + inbox + allow-list
- `ChatChannel TelegramChatChannel` instance:
  - `ccReceive` — pull from inbox
  - `ccSend` — chunked send to last chat
  - `ccSendWithId` — send + return message_id
  - `ccEditMessage` — edit via Bot API
  - `ccLabel` — "telegram"
- `withTelegramChatChannel :: ... -> (TelegramChatChannel -> IO a) -> IO a`
- Telegram callback handling (inline keyboard for ASK_HUMAN) — but
  ASK_HUMAN now goes through the generic loop's WS ask handler, so
  the adapter just needs ccSend with keyboard support. The adapter
  provides an optional `ccSendWithKeyboard` extension.

**Transport modules:**
- Reimplemented from scratch in the new package's namespace, using only
  `Seal.Gateway.Types.MessageSource` for types. The real transport
  implementations (signal-cli subprocess, Telegram Bot API HTTP) are
  copied/adapted — they only depend on external packages + gateway types.
- Mock transports for testing.

**DoD:**
- [ ] Signal adapter compiles, ChatChannel instance works
- [ ] Telegram adapter compiles, ChatChannel instance works
- [ ] Transport mock implementations work for tests
- [ ] SignalSpec: mock transport + mock gateway tests
- [ ] TelegramSpec: mock transport + mock gateway tests
- [ ] `make check` green

### WU-5: Server wiring

**Files:**
- `src/Seal/Command/Serve.hs` — add new fork functions alongside existing
- `seal-harness.cabal` — add seal-chat-channels to server deps + tests

**Wiring:**
- `forkSignalChatChannel :: GatewayConfig -> Manager -> SignalChatConfig -> IO ()`
  — spawns the new Signal chat channel via `runChatChannel`
- `forkTelegramChatChannel :: GatewayConfig -> Manager -> TelegramChatConfig -> IO ()`
  — spawns the new Telegram chat channel via `runChatChannel`
- These are called ALONGSIDE the existing `forkSignalListener`/
  `forkTelegramListener` so both old and new can run for comparison.
  A config flag or env var can disable the old ones.
- The new channels connect to the gateway's HTTP + WS endpoints
  (localhost, the same ports the server binds).

**DoD:**
- [ ] Server can fork new chat channel handlers
- [ ] New channels connect to gateway HTTP + WS
- [ ] `make check` green
- [ ] No existing tests broken

## Dependencies between work units

```
WU-1 (types + pure) ──→ WU-2 (HTTP + WS clients)
                   ──→ WU-3 (class + loop)
WU-2 + WU-3         ──→ WU-4 (Signal + Telegram adapters)
WU-4               ──→ WU-5 (server wiring)
```

## Key design decisions

1. **New namespace `Seal.Channels.Chat.*`** — doesn't collide with existing
   `Seal.Channels.Signal.*` / `Seal.Channels.Telegram.*`. Both coexist.

2. **Transports reimplemented from scratch** — the transport code (signal-cli
   subprocess, Telegram Bot API) is copied into the new package's namespace
   with only `Seal.Gateway.Types.MessageSource` as the internal dependency.
   The real transport implementations are mostly external-package code.

3. **One WS connection per conversation** — per design open question #4.
   Each conversation has its own focus state and streaming bubble.

4. **Client-side session tracking** — `SessionMap` (TVar) replaces
   `CursorStore`. First message → `httpNewSession` → store in map.
   `/N` → `httpGetTabs` → resolve tab index → `wcFocus`.

5. **Existing code stays untouched** — no removal of `ChannelDeps`,
   `StreamProgress`, etc. The new package is purely additive.

6. **`seal-gateway-types` may need additions** — if `StreamProgressConfig`
   or `shouldEdit`/`addCursor`/`stripCursor` should be shared, they move
   to `seal-gateway-types`. Otherwise they're reimplemented in
   `Seal.Channels.Chat.RateLimit` (duplicated for now).