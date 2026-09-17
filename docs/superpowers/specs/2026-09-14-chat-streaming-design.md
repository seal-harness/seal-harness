# Chat Channel Streaming & Tool-Call Progress

## Problem

When a user sends a message via Telegram or Signal, the agent may run for
tens of seconds (or minutes) with no visible feedback. The current
architecture sets `chStreaming = False` for both chat channels, so the
agent loop skips per-delta `ccSend` calls and only delivers the final
response via `replyFanout` after the entire turn completes. If something
fails mid-turn, the user sees nothing — just silence.

## Goal

Stream intermediate progress to chat channels so the user can see the agent
is working and what it is doing, similar to how Hermes' Telegram integration
progressively edits a message with streamed tokens and tool-call
notifications. Implement for **both Telegram and Signal**.

## Prior Art: Hermes

Hermes (`gateway/stream_consumer.py` + `gateway/run.py`) uses a
`GatewayStreamConsumer` with two parallel mechanisms:

### 1. Text streaming (edit-based)

- On first text delta, sends a new message to the platform.
- On subsequent deltas, **edits the same message** via
  `adapter.edit_message(chat_id, message_id, content)`.
- Rate-limited: `edit_interval` (seconds between edits) +
  `buffer_threshold` (codepoints before forcing an edit).
- Appends a cursor character (`▉`) to intermediate edits; removes it on
  the final edit.
- Handles overflow: when text exceeds `MAX_MESSAGE_LENGTH`, splits into
  multiple messages (edit the first, send continuations).
- Flood-control backoff: on Telegram 429 "Retry After", waits and retries;
  after 3 consecutive flood failures, permanently disables progressive
  edits and falls back to a single final send.
- Segment breaks: when a tool call fires, the current text message is
  finalized (cursor removed) and subsequent text appears as a new message
  below the tool-progress bubble.

### 2. Tool-progress bubbles (separate editable message)

- A `progress_callback` fires on `tool.started` events from the agent.
- Each tool start appends a line (e.g. `🔍 SHELL_EXEC`) to a
  tool-progress bubble — a separate message that is also edit-based.
- Multiple consecutive tool calls edit the same bubble (appending lines),
  so the user sees a growing list of tools being used.
- Rate-limited with its own edit interval (1.5s).

### Hermes' Signal limitation — and why it's outdated

Hermes' `SignalAdapter` sets `SUPPORTS_MESSAGE_EDITING = False` with the
comment "Signal has no real edit API for already-sent messages." This is
**outdated**: Signal added message editing in October 2023 (protocol
v6.34), and signal-cli has supported `--edit-timestamp` since v0.13.x.
Hermes simply never updated this.

Hermes' Signal `send()` returns `message_id=None`, keeping the stream
consumer on the non-edit fallback path. Tool progress is gated on
`type(adapter).edit_message is not BasePlatformAdapter.edit_message` —
Signal's `edit_message` is the base no-op, so the progress queue is drained
silently and no progress bubbles are sent.

## Signal editing IS available

**signal-cli 0.14.7** (verified installed) supports:

1. **`--edit-timestamp`** on `send` — sends an edited version of a
   previously-sent message. The timestamp of the original message is its
   identity. Signal clients display the result as an edited message (with
   the "edited" indicator users see in the desktop/mobile apps).

2. **`remoteDelete`** command — sends a "delete for everyone" by timestamp.

The JSON-RPC interface (which Seal uses) exposes these as:
- `editTimestamp` parameter on the `send` method (camelCase per JSON-RPC
  convention)
- `remoteDelete` method

The key difference from Telegram is that **Signal uses timestamps as
message identifiers**, not message-id strings. The `send` response is:
```json
{"jsonrpc":"2.0","result":{"timestamp":1693064367769},"id":4}
```
To edit, call `send` again with `editTimestamp` set to that timestamp.

**This means both Telegram and Signal can use the same edit-based streaming
algorithm.** The message identifier is an opaque `Text` to the caller —
it's a Telegram `message_id` string or a Signal timestamp string.

### Signal transport demux requirement

The current Signal transport sends JSON-RPC **notifications** (no `id`
field) so signal-cli doesn't send responses — `stReceive` reads all stdout
lines as receive notifications. To get the timestamp back (needed for
editing), we need to send **requests** (with `id`), which means signal-cli
will send responses on the same stdout stream, interleaved with receive
notifications.

The transport must **demux** stdout lines:
- JSON-RPC responses (have `result` or `error` + `id`) → route to the
  waiting sender via a response queue/MVar keyed by `id`.
- JSON-RPC notifications (have `method` + `params`, no `id`) → route to
  the inbox TQueue (as before).

This is the main structural change to the Signal transport. See
"Signal transport changes" below.

## Seal Harness Current State

### Architecture

```
User message → runChannelLoop → plainTurn → runSessionTurn → runTurn (Agent.Loop)
                                                            ↓
                                              providerStreamWithRetry
                                                  ↓ ccSend (per-delta, only if ccStreaming=True)
                                                  ↓ tool dispatch (dispatchOne)
                                                  ↓ repeat until no tool calls
                                                  ↓ notifyStop (replyFanout → all subscribed channels)
```

- `ChannelCaps.ccStreaming` is `True` for CLI/Web, `False` for Telegram/Signal.
- When `False`, per-delta `ccSend` is skipped; the full text is sent once via
  `notifyStop` (reply fan-out) at the end.
- Tool calls are dispatched silently — no notification to the channel during
  execution.
- `ChannelHandle` has `chSend` (one-shot send) but no edit capability or
  send-that-returns-an-id.

### Transports

- **Telegram** (`Seal.Channels.Telegram.Transport`): `tgSend` calls
  `sendMessage` but discards the response (doesn't capture `message_id`).
  No `editMessageText` method exists.
- **Signal** (`Seal.Channels.Signal.Transport`): `stSend` writes a
  JSON-RPC `send` notification (no `id`) to stdin. No response reading.
  No edit capability.

### Config

- `[signal]` and `[telegram]` sections exist with `account`/`token`,
  `text_chunk_limit`, `allow_from`.
- No streaming-related config fields.

## Design

### Overview

Add a **streaming progress** layer to chat channels that provides:
1. **Tool-call progress** — an editable message showing which tools the
   agent is calling, updated as each tool starts.
2. **Text streaming** — progressive edits of the assistant's text response
   as tokens arrive, so the user sees text appearing in real time.

Both Telegram and Signal support message editing (via different mechanisms),
so both get the full feature. The whole feature is gated behind a config
flag so operators can switch between the existing (silent) behavior and the
new (streaming) behavior.

### Platform capabilities

| Platform | Edit mechanism | Message identifier | Text streaming | Tool progress |
|----------|---------------|-------------------|---------------|--------------|
| Telegram | `editMessageText` API | `message_id` (int string) | Yes | Yes (edit-based bubble) |
| Signal | `send` with `editTimestamp` | `timestamp` (epoch ms string) | Yes | Yes (edit-based bubble) |

### Config

A new `[chat_streaming]` section in `config.toml`:

```toml
[chat_streaming]
enabled = false              # master switch (default: false = current behavior)
tool_progress = true         # send tool-call notifications (default: true when enabled)
text_streaming = true        # progressive text edits (default: true when enabled)
edit_interval_ms = 1500      # min ms between edits
buffer_threshold = 80        # codepoints before forcing an edit
cursor = "▉"                 # cursor appended to intermediate edits
```

When `enabled = false` (the default), the existing behavior is preserved
exactly: no streaming, no tool progress, final text sent via `replyFanout`.

### Channel capability changes

#### `ChannelHandle` — add edit support

```haskell
data ChannelHandle = ChannelHandle
  { -- ... existing fields ...
  , chSendWithId   :: Text -> IO (Maybe Text)
    -- ^ Send a message and return the platform message identifier (for
    -- later editing). 'Nothing' if the send failed. The identifier is
    -- opaque: a Telegram message_id string or a Signal timestamp string.
  , chEditMessage  :: Maybe (Text -> Text -> IO Bool)
    -- ^ Edit a previously sent message: message identifier, new content.
    -- Returns 'True' on success, 'False' on failure. 'Nothing' if the
    -- platform has no edit API. Best-effort: never throws.
  , chDeleteMessage :: Maybe (Text -> IO Bool)
    -- ^ Delete a previously sent message by identifier. 'Nothing' if
    -- unsupported. Used for cursor cleanup on fallback. Best-effort.
  }
```

Default values (for channels that don't support editing, and for existing
test fakes): `chSendWithId = \_ -> pure Nothing`, `chEditMessage = Nothing`,
`chDeleteMessage = Nothing`.

### Telegram transport changes

Add to `TelegramTransport`:

```haskell
data TelegramTransport = TelegramTransport
  { -- ... existing fields ...
  , tgSendWithId   :: Text -> Text -> IO (Maybe Text)
    -- ^ Send a message, return the message_id from the API response.
  , tgEditMessage  :: Text -> Text -> Text -> IO Bool
    -- ^ Edit a message: chat id, message id, new content. Returns success.
  , tgDeleteMessage :: Text -> Text -> IO Bool
    -- ^ Delete a message: chat id, message id. Returns success.
  }
```

These call the Bot API `sendMessage` (capturing `result.message_id`),
`editMessageText`, and `deleteMessage` respectively. The real transport
implements them via HTTP; the mock transport captures to IORefs.

The `tgSendWithId` implementation parses the `sendMessage` response JSON
for `result.message_id` and returns it as `Just (T.pack (show msgId))`.

`tgEditMessage` calls `editMessageText` with `chat_id`, `message_id`, and
`text` (plain text, no `parse_mode` — matching the existing security gate
from `tgSend`). Returns `True` on HTTP 200 + `"ok":true`, `False` otherwise.
Handles "message is not modified" (identical content) as success.

### Signal transport changes

This is the more involved change. The current transport is
fire-and-forget: `stSend` writes a JSON-RPC notification (no `id`) and
never reads a response. To support editing, we need the timestamp from the
response, which requires sending requests with `id` and demuxing stdout.

#### New transport shape

```haskell
data SignalTransport = SignalTransport
  { stReceive    :: IO (Either Text Value)
  , stSend       :: Text -> Text -> IO ()
    -- ^ Existing fire-and-forget send (unchanged, for backward compat).
  , stSendWithId :: Text -> Text -> IO (Maybe Text)
    -- ^ Send a message, return the timestamp from the response.
    -- Blocks until the matching JSON-RPC response arrives.
  , stEditMessage :: Text -> Text -> Text -> IO Bool
    -- ^ Edit a message: recipient, timestamp, new content.
    -- Sends a `send` with editTimestamp set. Returns success.
  , stDeleteMessage :: Text -> Text -> IO Bool
    -- ^ Delete a message: recipient, timestamp.
    -- Calls the `remoteDelete` JSON-RPC method. Returns success.
  , stClose      :: IO ()
  }
```

#### Demux architecture

The real transport spawns a **single reader thread** that reads all lines
from signal-cli's stdout and classifies each:

- Has `result` or `error` + `id` → JSON-RPC response: look up the
  waiting `stSendWithId` caller by `id` and deliver the result via an
  `MVar` (or `TVar` map keyed by id).
- Has `method` + `params` + no `id` → JSON-RPC notification: push to the
  inbox `TQueue` (as before, picked up by `stReceive`).

A counter (`IORef Int`) generates unique `id` values for each
`stSendWithId` call. Each call:
1. Allocates an id, creates an `MVar (Maybe Value)`, inserts it into an
   `IOMap Int (MVar (Maybe Value))`.
2. Writes the JSON-RPC frame with `id` to stdin.
3. Blocks on `takeMVar` (with a timeout — 10s — so a missing response
   doesn't hang the turn).
4. On response, extracts `result.timestamp` and returns it.
5. On timeout or error, returns `Nothing`.

The mock transport captures sends + edits + deletes to IORefs (no real
demux needed).

#### `stEditMessage` implementation

Sends a `send` JSON-RPC request with:
```json
{
  "jsonrpc": "2.0",
  "method": "send",
  "id": <next-id>,
  "params": {
    "recipient": ["<recipient>"],
    "message": "<new content>",
    "editTimestamp": <timestamp-int>
  }
}
```
The `editTimestamp` is parsed from the opaque `Text` identifier (which is
the timestamp string from the original `stSendWithId`). Returns `True` if
the response has a `result`, `False` on error or timeout.

#### `stDeleteMessage` implementation

Sends a `remoteDelete` JSON-RPC request:
```json
{
  "jsonrpc": "2.0",
  "method": "remoteDelete",
  "id": <next-id>,
  "params": {
    "recipient": ["<recipient>"],
    "targetTimestamp": <timestamp-int>
  }
}
```

### Streaming progress manager

A new module `Seal.Channels.StreamProgress` implements the streaming logic,
mirroring Hermes' `GatewayStreamConsumer` but adapted to Seal's
`ReaderT AppEnv IO` + handle pattern.

```haskell
-- | Configuration for the stream progress manager.
data StreamProgressConfig = StreamProgressConfig
  { spcEnabled         :: Bool
  , spcToolProgress    :: Bool
  , spcTextStreaming   :: Bool
  , spcEditIntervalMs  :: Int
  , spcBufferThreshold :: Int
  , spcCursor          :: Text
  }

-- | The streaming state for one turn.
data StreamProgress = StreamProgress
  { spHandle      :: ChannelHandle
  , spConfig      :: StreamProgressConfig
  , spRecipient   :: Maybe Text       -- Telegram: chat id; Signal: recipient
  , spTextMsgId   :: Maybe Text       -- message id of the text bubble
  , spToolMsgId   :: Maybe Text       -- message id of the tool bubble
  , spAccumulated :: Text             -- accumulated text deltas
  , spToolLines   :: [Text]           -- accumulated tool lines
  , spLastEdit    :: Maybe UTCTime
  , spEditSupported :: Bool           -- False if edits fail repeatedly
  }
```

#### Tool-call progress

When the agent dispatches a tool call, the loop calls a new hook:

```haskell
-- In AgentEnv:
aeOnToolCall :: Maybe (OpName -> Value -> IO ())
-- ^ Called before each tool dispatch with the opcode name + input.
-- Chat channels wire this to the stream progress manager.
```

The stream progress manager:

1. On first tool call, send a new message:
   `🔍 SHELL_EXEC {...}` → capture message id as `spToolMsgId`.
2. On subsequent tool calls, edit `spToolMsgId` to append the new line:
   ```
   🔍 SHELL_EXEC {...}
   🔍 FILE_READ {"path":"..."}
   ```
3. Rate-limited by `spcEditIntervalMs`. If edit fails (flood control,
   message too old, etc.), set `spEditSupported = False` and send
   remaining tools as new messages.
4. On segment break (text resumes after tools): finalize the tool bubble
   (no further edits) and reset `spToolMsgId = Nothing` so the next tool
   call starts a fresh bubble below any new text.

#### Text streaming

When `spcTextStreaming` is True and the channel supports editing:

1. On first text delta, send a new message with the text + cursor.
   → capture message id as `spTextMsgId`.
2. On subsequent deltas (rate-limited by `editIntervalMs` or
   `bufferThreshold`), edit `spTextMsgId` with accumulated text + cursor.
3. On tool-call boundary: finalize the text message (edit without cursor),
   set `spTextMsgId = Nothing` so the next text delta starts a new message
   below the tool bubble.
4. On turn end: final edit without cursor. If the final edit fails, send
   the full text as a new message.
5. Overflow: if accumulated text exceeds the platform's chunk limit, split
   into multiple messages (edit the first, send continuations).

When `spcTextStreaming` is False or edits are not supported: text is sent
once at the end via the existing `replyFanout` path.

#### Fallback behavior

If `spEditSupported` becomes `False` (edits keep failing):
- **Text**: stop editing; send the remaining accumulated text as a new
  message at turn end (via the existing `replyFanout` path — the manager
  just doesn't claim to have delivered it).
- **Tool progress**: stop editing the bubble; send each subsequent tool
  call as a new message (or suppress, depending on config).

### Agent loop changes

The agent loop (`Seal.Agent.Loop.go`) needs two integration points:

1. **Tool-call notification**: Before `dispatchOne`, call `aeOnToolCall`
   (if wired) with the opcode name + input. This is the hook the stream
   progress manager uses to send tool-progress messages.

2. **Text streaming**: The existing per-delta `ccSend` path is already
   there (guarded by `ccStreaming`). We add a parallel path: when the
   stream progress manager is active, route deltas to it instead of
   raw `ccSend`. The manager handles the edit-based send/edit logic.

   At the end of the turn (stop branches), the manager finalizes:
   - Text message: final edit (cursor removed) or fallback send.
   - Tool bubble: left as-is (already finalized at the last edit).

   The existing `notifyStop` / `replyFanout` is adjusted: if the stream
   progress manager already delivered the final text (via edit), skip the
   `ccSend` to the arrival channel (but still fan out to OTHER subscribed
   channels). This mirrors the existing `alreadySentText` guard.

### Wiring

The `ChannelDeps` record gains a `StreamProgressConfig` (loaded from
config per turn). The `mkHandleCaps` / `mkTelegramHandleCaps` functions
wire `aeOnToolCall` to the stream progress manager when enabled.

The `TurnEnv` gains a `teOnToolCall :: Maybe (OpName -> Value -> IO ())`
field, threaded into `AgentEnv` via `mkSessionAgentEnv`.

### Security considerations

- Tool-call progress messages contain the opcode name + a *summary* of the
  input. We must NOT send full inputs that may contain secrets (e.g.
  `SECRET_GET` input has a key name). The progress formatter will show the
  opcode name and a redacted/truncated input (first N chars, secrets
  masked). This matches the transcript's `orRecorded` (secret-free) vs
  `orParts` (secret-bearing) split — we use the same `secretOpcodes` list
  from `Registry.hs` to suppress input display for secret-bearing opcodes.
- No new shell-wrapping or subprocess invocation (Trusted/Audited path
  invariant preserved).
- Telegram API calls are direct HTTP (existing pattern), no shell.
- Signal `editTimestamp` and `targetTimestamp` are integer-validated
  before reaching the JSON-RPC frame (they come from our own `stSendWithId`
  responses, not user input, but we validate defensively).

### Migration / compatibility

- `enabled = false` by default → existing behavior is the default.
- New `ChannelHandle` fields have sensible defaults (`chSendWithId =
  \_ -> pure Nothing`, `chEditMessage = Nothing`, etc.) so existing
  code that constructs handles without the new fields compiles.
- The `[chat_streaming]` section is optional; absent = disabled.
- The existing `stSend` (fire-and-forget) is kept for backward compat;
  `stSendWithId` is the new method that captures the timestamp.

### TDD plan

1. **`Seal.Channels.StreamProgressSpec`** — pure unit tests:
   - `StreamProgressConfig` resolution from `RuntimeConfig`.
   - Buffer/threshold logic (when to trigger an edit).
   - Cursor insertion/removal.
   - Segment-break state reset.
   - Tool-line formatting + secret redaction.

2. **`Seal.Channels.Telegram.TransportSpec`** — transport tests:
   - `tgSendWithId` returns the message_id from the API response.
   - `tgEditMessage` calls `editMessageText` with the right payload.
   - `tgDeleteMessage` calls `deleteMessage`.
   - Mock transport captures edit/delete calls for assertions.

3. **`Seal.Channels.Signal.TransportSpec`** — transport tests:
   - `stSendWithId` sends a request with `id` and returns the timestamp
     from the response.
   - `stEditMessage` sends with `editTimestamp`.
   - `stDeleteMessage` calls `remoteDelete`.
   - Demux: responses routed to the right caller; notifications to inbox.
   - Timeout: `stSendWithId` returns `Nothing` on a missing response.
   - Mock transport captures for assertions.

4. **Integration tests** (using mock transports):
   - Telegram: tool call triggers a progress message; second tool call
     edits the same message.
   - Signal: tool call triggers a progress message; second tool call
     edits the same message (via `editTimestamp`).
   - Config `enabled = false`: no progress messages sent (existing
     behavior preserved).
   - Text streaming on both platforms: deltas produce edits; final edit
     removes cursor.
   - Flood-control fallback: edit failure → fallback to new message.
   - Segment break: text → tool → text produces three separate messages.

5. **Property tests** (QuickCheck):
   - `T.concat (chunkMessage limit t) == t` (already exists; verify the
     new `tgSendWithId` / `stSendWithId` chunking path).
   - Buffer threshold: edits are triggered at most once per
     `editIntervalMs` window.

### Files to create/modify

**New:**
- `src/Seal/Channels/StreamProgress.hs` — the streaming manager.
- `test/Seal/Channels/StreamProgressSpec.hs` — tests.

**Modified:**
- `src/Seal/Handles/Channel.hs` — add `chSendWithId`, `chEditMessage`,
  `chDeleteMessage`.
- `src/Seal/Channels/Telegram/Transport.hs` — add `tgSendWithId`,
  `tgEditMessage`, `tgDeleteMessage` (+ API functions + mock capture).
- `src/Seal/Channels/Telegram.hs` — wire new handle fields.
- `src/Seal/Channels/Signal/Transport.hs` — add `stSendWithId`,
  `stEditMessage`, `stDeleteMessage` + demux reader + mock capture.
- `src/Seal/Channels/Signal.hs` — wire new handle fields.
- `src/Seal/Agent/Env.hs` — add `aeOnToolCall` to `AgentEnv` + `TurnEnv`.
- `src/Seal/Agent/Loop.hs` — call `aeOnToolCall` before dispatch;
  integrate text streaming manager.
- `src/Seal/Core/TurnEngine.hs` — thread `teOnToolCall` through
  `mkSessionAgentEnv`.
- `src/Seal/Channels/Loop.hs` — build `StreamProgressConfig` from config,
  wire into caps + adapter.
- `src/Seal/Config/File.hs` — add `[chat_streaming]` section +
  `ChatStreamingConfig` type + codec.
- `src/Seal/Channels/Telegram/Run.hs` — wire stream progress.
- `src/Seal/Channels/Signal/Run.hs` — wire stream progress.
- `seal-harness.cabal` — new exposed-module + test-module.
- `test/Main.hs` — wire new test module.

### Implementation order

The changes are layered to keep `make check` green at each step:

1. **Config** — `ChatStreamingConfig` type + codec (no consumers yet).
2. **ChannelHandle** — add new fields with defaults (no callers yet).
3. **Telegram transport** — `tgSendWithId`, `tgEditMessage`,
   `tgDeleteMessage` + mock + tests.
4. **Signal transport** — demux reader + `stSendWithId`, `stEditMessage`,
   `stDeleteMessage` + mock + tests.
5. **Channel wiring** — Telegram.hs + Signal.hs wire new handle fields.
6. **StreamProgress module** — the manager + pure tests.
7. **Agent loop** — `aeOnToolCall` hook + text streaming integration.
8. **TurnEngine + Loop.hs** — wire config → caps → adapter → env.
9. **Run.hs** — wire in both entry points.
10. **Integration tests** — end-to-end with mock transports.

### Future extensions

- **Signal typing indicators**: Signal supports `sendTyping` — we could
  send typing indicators during long tool calls to show activity. This
  would require adding `sendTyping` to the signal-cli transport.
- **Telegram draft streaming**: Hermes has a `send_draft` transport that
  uses Telegram's native draft animation (DM-only, bot API 9.4+). This
  is a future enhancement; the edit-based path is the MVP.
- **Config per channel**: Allow `[chat_streaming]` overrides per channel
  (e.g. `[chat_streaming.telegram] tool_progress = false`).
- **Fresh-final**: Hermes' "fresh final" feature sends the completed reply
  as a new message (instead of editing the preview) when the preview has
  been visible for a long time, so the platform's timestamp reflects
  completion time. Could add as a future config option.