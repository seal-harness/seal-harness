# Unified Channel Logging + Exception Handling

**Date**: 2026-07-28 · **Status**: revised (round 2, post-review-gate) · **Branch**: `fix/skill-load-context`

## Design review gate (round 1 → round 2)

Round 1 ran 5 reviewers (PM, Architect, Designer, Security, CTO) in parallel.
All 5 returned NEEDS_REVISION. Resolutions (with the user):

- **`Env`/`mkEnv` lifetime** (Architect B1, CTO B1, Designer B2) — `Env` is
  rebuilt per-turn via `mkEnv defaultConfig` at 6 sites; the design didn't
  say how `SealLogger` gets into it. **Resolution**: `SealLogger` lives in
  `Env` as a new `envLogger` field. `mkEnv` gains a `SealLogger` first
  argument: `mkEnv :: SealLogger -> Config -> IO Env`. The 6 production
  `mkEnv defaultConfig` sites become `mkEnv logger defaultConfig` (logger
  from `ChannelDeps`/`SendDeps`). Test sites go through per-module
  `runTestApp` helpers (one-line change each). `runApp`'s signature is
  unchanged — it reads `envLogger` from `Env` to set up the katip context.
  This is cleaner than a separate `runApp` arg because `App` already has
  `MonadReader Env`, so `logMsg` inside `App` can access the logger via
  `ask`, and every `runApp` call site (production + tests) is untouched.
- **`ThreadKilled` rethrow** (Architect B2, Security 4) —
  `withExceptionLogging` must rethrow `AsyncException`, not swallow it.
  **Resolution**: `withExceptionLogging` catches synchronous exceptions
  only; `AsyncException` (including `ThreadKilled`) is rethrown after
  logging at `InfoS`. The loop-body wrapper uses a variant that rethrows
  async exceptions so shutdown propagates to the bracket.
- **Channel context should be the default** (Designer B1, PM) — `logIO`
  (no context) was the easy path. **Resolution**: the public API is
  `logIO :: SealLogger -> Severity -> LogStr -> IO ()` (uses the logger's
  baseline context, which is `mempty` at startup) and
  `withChannelContext :: SealLogger -> ChannelContext -> SealLogger`
  (returns a *refined* logger with the context overlaid). Turn code
  threads the refined logger, so every `logIO` call within a turn
  automatically carries `ChannelContext`. The context-less `logIO` is
  only used at startup (before any channel is active) and in tests.
- **PII in logs** (Security B1) — `conversationId` carries phone numbers
  (Signal) and chat ids (Telegram). **Resolution**: `ChannelContext`
  stores a *hashed* conversation id (`ccConversationIdHash :: Maybe Text`)
  — the first 12 chars of a SHA-256 hex digest. The full conversation id
  is never logged to the operator console; it's available only in the
  per-session `seal.log` (which is already scoped to one session
  directory). Session ids are timestamp-derived (not PII) and logged in
  full.
- **Exception text to users** (Security B2) — `show SomeException` leaks
  internals to chat users via `chSend`. **Resolution**:
  `withExceptionLogging` returns a *sanitized* `Text` for the user: a
  generic message (`"internal error (turn failed)"`) with a short
  correlation id (first 8 chars of a random nonce). The full exception
  text is logged to the operator log only. `TranscriptError` text is
  already user-facing and passes through unchanged.
- **Log injection** (Security B3) — exception `show` may contain `\n`.
  **Resolution**: `withExceptionLogging` and `logIO` escape `\n`/`\r` to
  literal `\\n`/`\\r` in the `LogStr` before emitting. The session log
  (`appendSessionLog`) also escapes newlines.
- **Test blast radius** (CTO B2, Designer S4) — ~40 test construction
  sites would break. **Resolution**: `Env` gains `envLogger`, and `mkEnv`
  gains a `SealLogger` first argument. Test sites go through per-module
  `runTestApp` helpers (one-line change each: `mkEnv testSealLogger defaultConfig`).
  `ChannelDeps` and `SendDeps` gain `cdLogger`/`sdLogger` as the last field;
  `newChannelDeps` and `mkSendDeps` (smart constructors) gain a `SealLogger`
  final parameter, so test call sites change in one place each. A
  `testSealLogger :: IO SealLogger` helper builds a logger with a no-op
  scribe for tests. `AgentEnv` does NOT gain an `aeLogger`
  field in this phase (deferred per Designer S3 — the `App` monad's
  `KatipContext` instance now delegates to the shared `LogEnv` via
  `runApp`, so `runTurn` can log via `logMsg` without a separate handle).
- **Stringly-typed `ChannelKind`** (Designer B3) — use the existing
  `ChannelKind` enum. **Resolution**: `ccChannelKind :: Maybe ChannelKind`;
  the `ToJSON` instance uses `channelKindToText` for serialization.
- **Personas and user-focused metrics** (PM) — **Resolution**: added
  §1.1 Personas and user-focused DoD items (§4.10, §4.11).
- **`withSealLogger` bracket** (Architect S1) — **Resolution**: the
  production startup path uses `withSealLogger :: Text -> (SealLogger -> IO a) -> IO a`
  (bracket pattern, closes the scribe on exit). `newSealLogger` is kept
  for tests (with `closeSealLogger`).

## 1.1 Personas

- **Operator** — runs the server (`seal serve` or `seal telegram`),
  reads console logs, diagnoses channel failures. The primary
  beneficiary of this design.
- **Channel developer** — adds a new channel (e.g. Discord, IRC).
  Needs the logging contract to be obvious and channel-agnostic.
- **End-user** — uses a channel (Telegram, Signal, web). Expects the
  channel not to die silently. When a turn fails, receives a
  user-friendly error (not raw exception internals).

## 1. Problem

When `/skill load` is invoked from Telegram, the channel loop dies silently —
the end-user sees only the echo line `$ /skill load start`, then nothing. The
console shows `reader exiting: getUpdates network error: thread killed`,
meaning the reader thread was killed mid-long-poll when the channel loop's
bracket cleaned up after an uncaught exception.

The root cause is architectural: the server has **three disjoint logging
mechanisms** that are never unified:

1. **`hPutStrLn stderr`** (43 sites) — the default for all `IO`-layer code
   (channels, transports, gateway, command entry points). No log levels, no
   metadata, no structure.
2. **katip** (`App` monad) — wired up in `Seal.Types.App` but **never actually
   used to emit a single log line anywhere in `src/Seal/`**. Dead code.
3. **Session log** (`Seal.Session.Log`) — per-session `seal.log` file, used
   only for turn lifecycle events from `Agent.Loop`.

This split means:
- Channel-agnostic code (the loop, the dispatcher) can't log through katip
  because it runs in `IO`, not `App`.
- Every exception handler duplicates the same 6-line `catch` + `logTurnError`
  + `hPutStrLn stderr` pattern (6 sites).
- Forked threads that throw kill silently (5 high-risk gaps identified in the
  audit).
- No log entry identifies which channel produced it — the operator can't tell
  a Telegram error from a Signal error from a web error without reading the
  message text.

## 2. Design principle: channel-agnostic by default

Per the user's guidance: the vast majority of functionality should be
identical across all channels (web, TUI, Telegram, Signal, future channels).
Channel-specific behavior is the exception, not the norm.

The logging infrastructure must reflect this:
- **One logger**, shared across all channels. The logger is threaded through
  the shared dependency records (`ChannelDeps`, `SendDeps`), not through
  channel-specific code.
- **Channel metadata** is attached to the logger via `withChannelContext`,
  which returns a refined logger. Turn code threads the refined logger, so
  every `logIO` call within a turn automatically carries `ChannelContext` —
  context-free logging is never the easy path within a turn.
- **Exception handling** is unified: one `withExceptionLogging` helper, used
  by all channels, the web gateway, and the CLI. The helper logs the
  exception with channel + session metadata, sends a sanitized message to
  the user, and continues the loop (or rethrows `AsyncException` for
  shutdown).

## 3. Design

### 3.1 A shared `SealLogger` for `IO` code

The core problem is that katip requires `KatipContext m` (i.e. `App`), but
the channel/transport/gateway code runs in `IO`. We can't move everything to
`App` (the channel loop's `chReceive` blocks, transports do raw HTTP, etc.).

The solution: a lightweight `SealLogger` handle that wraps a katip `LogEnv`
and provides `IO`-level logging functions. It's built once at startup and
threaded through the dependency records.

```haskell
-- src/Seal/Logging/Logger.hs
data SealLogger = SealLogger
  { slLogEnv    :: LogEnv
  , slContext   :: LogContexts
  , slNamespace :: Namespace
  }

-- | Bracket the logger's lifetime. Creates the stderr scribe, runs the
-- action, closes the scribe on exit. Used at all 4 startup sites.
withSealLogger :: Text -> (SealLogger -> IO a) -> IO a  -- ^ log level

-- | Build a logger without a bracket (for tests). The caller is
-- responsible for closing the scribe via 'closeSealLogger' (or process
-- exit, which closes the stderr handle).
newSealLogger :: Text -> IO SealLogger
closeSealLogger :: SealLogger -> IO ()

-- | A logger with a no-op scribe (for tests that don't assert log output).
testSealLogger :: IO SealLogger

-- | Emit a log line from IO. Uses the logger's baseline context (which
-- may be refined via 'withChannelContext'). Newlines in the LogStr are
-- escaped to \\n / \\r before emission (log-injection defense).
logIO :: SealLogger -> Severity -> LogStr -> IO ()

-- | Refine the logger with additional structured context. Returns a new
-- SealLogger whose slContext is the merge (slContext <> liftPayload item).
-- This is how ChannelContext is attached: the turn code calls
-- withChannelContext logger ctx once, then threads the refined logger
-- through all subsequent logIO calls.
withChannelContext :: LogItem a => SealLogger -> a -> SealLogger
```

The logger uses katip's `runKatipContextT` under the hood, but only for the
duration of a single `logIO` call — no long-lived `App` monad needed. The
`withChannelContext` merge is:

```haskell
withChannelContext logger item =
  logger { slContext = slContext logger <> liftPayload item }
```

This ensures `logIOWith`-style per-call context and the logger's baseline
context are merged (not replaced), addressing the Architect's B3 concern.

**Logger self-failure**: `logIO` wraps the `runKatipContextT` call in a
`catch \(_ :: SomeException) -> pure ()` — if the scribe write throws
(e.g. closed handle, I/O error), the error is silently swallowed. This is
best-effort logging (mirroring `appendSessionLog`'s design in
`Seal.Session.Log`): the logger must never crash the caller, especially
inside `withExceptionLogging` where a logger crash would defeat the
exception handler.

### 3.2 Channel metadata as a `LogItem`

A structured payload attached to the logger via `withChannelContext` at the
start of each turn:

```haskell
-- src/Seal/Logging/ChannelContext.hs
data ChannelContext = ChannelContext
  { ccChannelKind       :: Maybe ChannelKind  -- typed enum, not Text
  , ccConversationIdHash :: Maybe Text         -- SHA-256 hash (first 12 hex chars)
  , ccSessionId         :: Maybe Text          -- timestamp-derived, not PII
  }
  deriving stock (Generic)

instance ToJSON ChannelContext where  -- uses channelKindToText for ccChannelKind
instance LogItem ChannelContext

-- | Build a ChannelContext from a MessageSource + optional SessionMeta.
-- The conversation id is hashed (never logged in full to the operator log).
ctxFromMessageSource :: Maybe MessageSource -> Maybe SessionMeta -> ChannelContext

-- | Build a ChannelContext for the CLI/web paths (no MessageSource).
ctxFromSession :: SessionMeta -> ChannelContext
```

The `ccConversationIdHash` is the first 12 hex chars of
`SHA-256(conversationIdText)`. This lets the operator correlate log lines
across a conversation without exposing the phone number (Signal) or chat id
(Telegram). The full conversation id is available in the per-session
`seal.log` (scoped to that session's directory).

`ccTurnNumber` is dropped from v1 (YAGNI — the session id + timestamp already
order events; surfacing the turn number from `runTurn` adds coupling for no
clear benefit).

### 3.3 Threading the logger through dependencies

Add `cdLogger :: SealLogger` to `ChannelDeps` and `sdLogger :: SealLogger`
to `SendDeps`, as the last field in each record. The smart constructors
(`newChannelDeps`, `mkSendDeps`) gain a `SealLogger` final parameter.

`Env` gains `envLogger :: SealLogger` as a new field. `mkEnv` gains a
`SealLogger` first argument: `mkEnv :: SealLogger -> Config -> IO Env`.
The 6 production `mkEnv defaultConfig` sites become
`mkEnv logger defaultConfig` (logger from `ChannelDeps`/`SendDeps`). Test
sites go through per-module `runTestApp` helpers (one-line change each).
`runApp`'s signature is unchanged — it reads `envLogger` from `Env`.

`AgentEnv` is **NOT** modified in this phase — `runTurn` logs via the `App`
monad's `KatipContext` instance (now backed by the shared `LogEnv` via
`envLogger` in `Env`, §3.8). A `logMsg` call inside `runTurn` reaches the
same scribe as `logIO` in the channel `IO` code. Adding `aeLogger` is
deferred (Designer S3).

The logger is built once at startup via `withSealLogger` (bracket pattern)
in `runServeMain`, `runSignalMain`, `runTelegramMain`, and `runTui`.

### 3.4 Unified exception handling helper

One function replaces the 6 duplicated `catch` patterns:

```haskell
-- src/Seal/Logging/Exceptions.hs

-- | Run an IO action, catching synchronous exceptions. Logs the exception
-- with the logger's context + the given 'where' label, calls the optional
-- session-log fallback, and returns either a sanitized error text (for the
-- caller to send to the user) or the original result.
--
-- AsyncException (including ThreadKilled) is NOT caught — it is rethrown
-- after logging at InfoS, so shutdown propagates to the bracket.
withExceptionLogging
  :: SealLogger
  -> Maybe FilePath          -- ^ session log path (for seal.log fallback)
  -> Text                    -- ^ 'where' label (e.g. "slash command", "turn")
  -> IO a
  -> IO (Either Text a)
```

The returned `Text` (on `Left`) is **sanitized**:
- `TranscriptError te` → `"transcript error: " <> te` (already user-facing).
- Other `SomeException` → `"internal error (<whereLabel>) [ref: <correlationId>]"`.
  The correlation id is the first 8 chars of a random nonce, also included
  in the operator log line so the operator can correlate the user's report
  to the log entry.

The full `show e` is logged to the operator log (via `logIO`) at `ErrorS`,
including the `where` label and the `ChannelContext` (from the logger's
context). Newlines in the exception text are escaped before logging.

The `Maybe FilePath` parameter triggers the per-session `seal.log` write
(via `logTurnError`) alongside the katip emission. The 6 call sites drop
their explicit `logTurnError` call since it's now internal to the helper.

This replaces:
- `Loop.hs:341` (slash command catch) → `withExceptionLogging (withChannelContext logger ctx) Nothing "slash command"`
- `Loop.hs:684` (turn catch) → `withExceptionLogging (withChannelContext logger ctx) (Just logPath) "turn"`
- `Send.hs:240` (plainTurn catch) → `withExceptionLogging (withChannelContext logger ctx) (Just logPath) "plainTurn"`
- `Send.hs:419` (turn catch) → `withExceptionLogging (withChannelContext logger ctx) (Just logPath) "turn"`
- `Send.hs:653` (withCaps catch) → `withExceptionLogging (withChannelContext logger ctx) (Just logPath) "turnWithCaps"`
- `Cli.hs:189` (handlePlain catch) → `withExceptionLogging logger logPath "plain"`

The caller still does the `chSend h msg` + `loop` recursion after
`withExceptionLogging` returns `Left msg` — the helper handles logging +
sanization, the caller handles the channel-specific send + loop continuation.

### 3.5 Protecting forked threads

Every `forkIO` whose action can throw must have a top-level catch. The
unified helper makes this a one-liner:

**High-risk gaps to fix:**

| Site | Current | Fixed |
|---|---|---|
| `Channel/Cli.hs:556` (`/bg` runner) | no catch | `withExceptionLogging logger logPath "bg turn"` |
| `Channels/Loop.hs:779` (`/bg` runner) | no catch | same |
| `Command/Serve.hs:319,355` (`runChannelLoop`) | inner catches only | top-level `withExceptionLogging` around the entire loop body (rethrows `AsyncException`) |
| `Gateway/Send.hs:578` (`act caps` — slash dispatch) | no catch | `withExceptionLogging logger Nothing "slash command"` |
| `Gateway/Send.hs:699` (`webCallDispatcher`) | no catch | `withExceptionLogging logger Nothing "call dispatch"` |
| `Handles/Transcript.hs:154` (legacy daemon) | no catch | `catch` (mirror `safeDaemon:329`; mark dead + drain without acking) |

### 3.6 Fixing the Telegram reader-thread crash

The immediate symptom is `reader exiting: getUpdates network error: thread
killed`. The `ThreadKilled` exception is thrown by `killThread` in
`withTelegramChannel`'s `after` handler (Telegram.hs:85), which runs when the
`withChannel` bracket exits. The bracket exits because `runChannelLoop`
threw an uncaught exception.

The fix has two parts:

1. **Prevent the loop from throwing** (§3.5): wrap the entire loop body in
   `withExceptionLogging` (which rethrows `AsyncException` but catches
   synchronous exceptions). No synchronous exception escapes to the bracket.

2. **Make the reader thread's `ThreadKilled` handling graceful**: when the
   reader catches `ThreadKilled`, it logs at `InfoS` (normal shutdown), not
   `ErrorS` (crash). Other `AsyncException`s are also terminal for the
   reader (logged at `WarningS`) — the design explicitly states all
   `AsyncException`s are terminal and must not be retried.

```haskell
-- Telegram.hs readerLoop, Signal.hs readerLoop
Left e -> do
  case fromException @AsyncException e of
    Just ThreadKilled ->
      logIO logger InfoS "reader thread stopped (channel shutting down)"
    Just _ ->
      logIOWith logger ctx WarningS ("reader thread terminated by async exception: " <> showLs e)
    Nothing ->
      logIOWith logger ctx ErrorS ("reader thread exception: " <> showLs e)
  writeIORef (tcgReaderAlive ch) False
```

The reader threads need access to the `SealLogger`. The `TelegramChannel` and
`SignalChannel` records gain a `tcgLogger`/`scLogger` field, threaded from
`withTelegramChannel`/`withSignalChannel` (which gain a `SealLogger`
parameter).

### 3.7 Migrating `hPutStrLn stderr` → `logIO`

All 43 `hPutStrLn stderr` sites are migrated to `logIO` / `logIOWith` with
appropriate severity levels:

| Category | Severity | Examples |
|---|---|---|
| Startup warnings | `WarningS` | config load failure, vault unavailable |
| Channel skipped | `WarningS` | "seal serve: telegram channel skipped: …" |
| Reader thread: ThreadKilled | `InfoS` | normal shutdown |
| Reader thread: other async | `WarningS` | terminated by async exception |
| Reader thread: sync exception | `ErrorS` | real crash |
| Send/chunk dropped | `WarningS` | "telegram: dropping send — no last chat yet" |
| Transport HTTP error | `ErrorS` | getUpdates network error, sendMessage failure |
| Turn/slash failure | `ErrorS` | "turn failed: …", "slash command failed: …" |
| Non-allow-listed sender | `InfoS` | "dropped non-allow-listed sender: …" |
| Transcript daemon died | `ErrorS` | "writer daemon died: …" |
| Tab persist failure | `WarningS` | "tabs.json save failed: …" |
| WS rejected origin | `InfoS` | "ws: rejected Origin …" |

**Startup banners** in `Gateway/Server.hs` (lines 72-82) and
`Config/Migrate.hs` (lines 65, 97, 103) keep `hPutStrLn stderr` — they run
before the logger exists. This is an explicit exemption from DoD item 2.

**Transport layer**: the `TelegramTransport` and `SignalTransport` records
do NOT gain a logger field (keeping them as pure testability seams). The
existing `hPutStrLn stderr` sites in `Telegram/Transport.hs` (lines 296,
310, 314 — the `setMyCommandsViaApi` function) are refactored to return
`Either Text ()` instead of logging directly; the *caller*
(`forkTelegramListener` in `Serve.hs`, `runTelegram` in `Telegram/Run.hs`)
logs the error via `logIO`. The silent swallow at `Transport.hs:274`
(`sendViaApi`'s `Left _ -> pure ()`) is replaced with a `logIO` call at
`WarningS` — the transport's `tgSend` gains a `SealLogger` parameter (or
the caller wraps `tgSend` with a logging version). This avoids coupling the
transport *record* to katip while still migrating all 3 stderr sites and
the silent swallow.

### 3.8 `App` monad: make katip actually work

The `App` monad's `KatipContext` instances currently build a fresh `LogEnv`
per `runApp` call (via `withKatip`). This means `App`-level logs don't share
the same scribe as `IO`-level logs.

Fix: `Env` gains `envLogger :: SealLogger`, and `runApp` reads it from
`Env` to set up the katip context:

```haskell
data Env = Env
  { envLogLevel :: !Text
  , envServerHost :: !Text
  , envServerPort :: !Int
  , envLogger :: !SealLogger    -- NEW
  }

mkEnv :: SealLogger -> Config -> IO Env
mkEnv logger cfg = pure Env
  { envLogLevel = view config_logLevel cfg
  , envServerHost = view (config_server . serverConfig_host) cfg
  , envServerPort = view (config_server . serverConfig_port) cfg
  , envLogger = logger
  }

runApp :: Env -> App a -> IO a
runApp env (App m) =
  runKatipContextT (slLogEnv (envLogger env)) (slContext (envLogger env))
    (slNamespace (envLogger env)) (runReaderT m env)
```

`runApp`'s signature is unchanged — every `runApp` call site (production +
tests) is untouched. The change is localized to `mkEnv` (gains a
`SealLogger` first argument) and its 6 production callers:

```haskell
-- Before: appEnv <- mkEnv defaultConfig
-- After:  appEnv <- mkEnv logger defaultConfig
```

Test sites go through per-module `runTestApp` helpers (e.g.
`runTestApp act = do env <- mkEnv defaultConfig; runApp env act`), which
change in one line each to `mkEnv testSealLogger defaultConfig`.

`withKatip` is removed (replaced by `withSealLogger` at the 4 startup sites).

Now `logMsg`/`logLocM` inside `App` (e.g. in `Agent.Loop`) reaches the same
scribe as `logIO` in the channel `IO` code. `App` already has
`MonadReader Env`, so `logMsg` inside `App` can access the logger via
`ask` — no separate handle needed.

### 3.9 The `AgentEnv` logging path

`AgentEnv` does **NOT** gain an `aeLogger` field in this phase. `runTurn`
logs via the `App` monad's `KatipContext` instance (now backed by the shared
`LogEnv` via the new `runApp` signature). A `logMsg` call inside `runTurn`
reaches the same scribe as `logIO` in the channel code.

The session log (`logTurnStart`/`logTurnEnd`/`logProviderError`/`logMaxTurns`)
stays as `IO` file writes (the per-session audit trail). They're called
alongside katip logs, not replaced by them. Migrating them to katip is
deferred (§8).

### 3.10 Files

| File | Change |
|---|---|
| `src/Seal/Logging/Logger.hs` | **NEW**. `SealLogger`, `withSealLogger`, `newSealLogger`, `closeSealLogger`, `testSealLogger`, `logIO`, `withChannelContext`. Newline escaping in `logIO`. |
| `src/Seal/Logging/ChannelContext.hs` | **NEW**. `ChannelContext` (LogItem), `ctxFromMessageSource`, `ctxFromSession`. SHA-256 hashing of conversation id. `ccChannelKind :: Maybe ChannelKind` (typed). |
| `src/Seal/Logging/Exceptions.hs` | **NEW**. `withExceptionLogging` (rethrows `AsyncException`, catches sync, sanitizes user-facing text, correlation id, newline escaping). |
| `src/Seal/Types/Env.hs` | Add `envLogger :: SealLogger` to `Env`. `mkEnv :: SealLogger -> Config -> IO Env` (gains `SealLogger` first arg). |
| `src/Seal/Types/App.hs` | `runApp` reads `envLogger` from `Env` to set up katip context. Remove `withKatip`. |
| `src/Seal/Channels/Loop.hs` | Add `cdLogger :: SealLogger` (last field). `newChannelDeps` gains `SealLogger` final param. Replace `catch` at 341/684 with `withExceptionLogging`. Add top-level `withExceptionLogging` around loop body. Pass logger to reader threads via `ChannelHandle` or channel record. |
| `src/Seal/Gateway/Send.hs` | Add `sdLogger :: SealLogger` (last field). `mkSendDeps` gains `SealLogger` final param. Replace `catch` at 240/419/653 with `withExceptionLogging`. Add catch around `act caps` (578) and `webCallDispatcher` (699). `mkEnv` calls gain `logger` first arg. |
| `src/Seal/Channel/Cli.hs` | Replace `catch` at 189 with `withExceptionLogging`. Add catch around bg runner forkIO (556). `mkEnv` calls gain `logger` first arg. Thread `SealLogger` through `runCliTui`. |
| `src/Seal/Channels/Telegram.hs` | `TelegramChannel` gains `tcgLogger :: SealLogger`. `withTelegramChannel` gains `SealLogger` param. Replace `logErr` with `logIO`. Handle `ThreadKilled` gracefully. |
| `src/Seal/Channels/Signal.hs` | `SignalChannel` gains `scLogger :: SealLogger`. `withSignalChannel` gains `SealLogger` param. Same as Telegram. |
| `src/Seal/Channels/Telegram/Transport.hs` | Refactor `setMyCommandsViaApi` (lines 296/310/314) to return `Either Text ()` instead of `hPutStrLn stderr`. Replace silent swallow at `sendViaApi:274` with a logged `WarningS`. The caller (`forkTelegramListener`/`runTelegram`) logs the `Either` error via `logIO`. |
| `src/Seal/Channels/Signal/Transport.hs` | Same pattern — any `hPutStrLn stderr` sites refactored to `Either` returns; caller logs. |
| `src/Seal/Agent/Loop.hs` | Replace silent `catch` at 330 (`appendDebugRequest`) with `logIO` at `WarningS` (debug-write failure). |
| `src/Seal/Channels/Telegram/Run.hs` | `withSealLogger` bracket at startup. Thread into `ChannelDeps` + `withTelegramChannel`. |
| `src/Seal/Channels/Signal/Run.hs` | Same. |
| `src/Seal/Command/Serve.hs` | `withSealLogger` bracket at startup. Thread into `ChannelDeps` + `SendDeps` + channel listeners. |
| `src/Seal/Gateway/Stream.hs` | Replace silent `catch` at 98 with `logIO`. Thread logger. |
| `src/Seal/Gateway/StreamBroker.hs` | Replace silent `catch` at 106 with `logIO`. Thread logger. |
| `src/Seal/Session/Lock.hs` | Replace `hPutStrLn stderr` at 148 with `logIO`. Catch all exceptions (not just `IOException`). Thread logger. |
| `src/Seal/Tabs.hs` | Replace `hPutStrLn stderr` at 142/163 with `logIO`. Thread logger. |
| `src/Seal/Tabs/Persist.hs` | Replace `hPutStrLn stderr` at 61 with `logIO`. Thread logger. |
| `src/Seal/Handles/Transcript.hs` | Replace `hPutStrLn stderr` at 331 with `logIO`. Add catch to legacy daemon (154, mirror `safeDaemon:329`). Thread logger. |
| `src/Seal/Web/UiState.hs` | Replace `hPutStrLn stderr` at 172 with `logIO`. Thread logger. |
| `src/Seal/Session/Log.hs` | Keep as-is (per-session file log). Add newline escaping to `formatLogLine`. |
| `seal-harness.cabal` | Add `Seal.Logging.Logger`, `Seal.Logging.ChannelContext`, `Seal.Logging.Exceptions` to `exposed-modules`. |
| `test/Main.hs` | Add `import qualified Seal.Logging.LoggerSpec`, `Seal.Logging.ExceptionsSpec`. Add `spec` calls. |
| `seal-harness.cabal` (test) | Add `Seal.Logging.LoggerSpec`, `Seal.Logging.ExceptionsSpec` to `other-modules`. |
| **Test files** (update smart-constructor call sites) | |
| `test/Seal/Channels/LoopSpec.hs` | `newChannelDeps` calls (7 sites) gain `testSealLogger`. New test: crashing slash command doesn't kill loop. |
| `test/Seal/Gateway/SendSpec.hs` | `mkSendDeps` calls gain `testSealLogger`. |
| `test/Seal/Gateway/ApiSpec.hs` | `SendDeps` literals (4 sites) gain `sdLogger = testSealLogger`. |
| `test/Seal/Channels/Signal/RunSpec.hs` | `mkEnv` calls gain `testSealLogger` first arg. `withSignalChannel` calls (if any) gain `testSealLogger`. |
| `test/Seal/Channels/SignalSpec.hs` | `withSignalChannel` calls (5 sites) gain `testSealLogger`. |
| `test/Seal/Channels/TelegramSpec.hs` | `withTelegramChannel` calls gain `testSealLogger`. |
| `test/Seal/Phase2bSpec.hs` | `mkEnv` call gains `testSealLogger` first arg. |
| `test/Seal/Phase4Spec.hs` | `runTestApp` helper: `mkEnv` gains `testSealLogger` first arg. |
| `test/Seal/Channel/WiringSpec.hs` | `mkEnv` call gains `testSealLogger` first arg. |
| `test/Seal/Agent/LoopSpec.hs` | `runApp` calls unchanged (reads logger from `Env`). `runTestApp` helper gains `testSealLogger`. |
| **Test files** (update `mkEnv`/`runTestApp` helpers) | |
| `test/Seal/ISA/DispatchSpec.hs` | `runTestApp` helper: `mkEnv` gains `testSealLogger` first arg. |
| `test/Seal/ISA/Ops/SkillsSpec.hs` | Same. |
| `test/Seal/ISA/Ops/HumanSpec.hs` | Same. |
| `test/Seal/ISA/Ops/FileSpec.hs` | Same. |
| `test/Seal/ISA/Ops/ShellSpec.hs` | Same. |
| `test/Seal/ISA/Ops/ProcessSpec.hs` | Same. |
| `test/Seal/ISA/Ops/BinSpec.hs` | Same. |
| `test/Seal/ISA/Ops/SearchSpec.hs` | Same. |
| `test/Seal/ISA/Ops/PatchSpec.hs` | Same. |
| `test/Seal/ISA/Ops/SecretSpec.hs` | Same. |
| `test/Seal/ISA/Ops/AgentSpec.hs` | Same. |
| `test/Seal/ISA/Ops/MemorySpec.hs` | Same. |
| `test/Seal/ISA/IntegrationSpec.hs` | Same. |
| `test/Seal/ISA/RegistrySpec.hs` | Same. |
| `test/Seal/Phase5Spec.hs` | Same. |
| `test/Seal/Phase6aSpec.hs` | Same. |

### 3.11 What stays the same

- The session log (`seal.log`) is kept — it's the per-session audit trail,
  orthogonal to the operator's process-level console log.
- `Seal.Session.Log` functions stay in `IO` (they write to a per-session
  file). They're called alongside katip logs, not replaced by them.
- The `App` monad stays — `runTurn` and `dispatch` still run in `App`. The
  only change is that `runApp` now reads `envLogger` from `Env` to set up
  the katip context (instead of building a fresh `LogEnv` via `withKatip`).
- The channel loop architecture stays — `runChannelLoop` still drives the
  inbox, routing, and turn dispatch. The only addition is the top-level
  `withExceptionLogging` and the logger threading.
- `Env` gains `envLogger` (the logger lives in `Env`, not as a separate
  `runApp` argument). `mkEnv` gains a `SealLogger` first argument.
- `AgentEnv` stays unchanged (no `aeLogger` field in this phase).
- The transport records (`TelegramTransport`, `SignalTransport`) stay
  logger-free — errors are returned via `Either` and the caller logs.

## 4. DoD (Definition of Done)

1. `SealLogger` is built once at startup via `withSealLogger` and threaded
   through `ChannelDeps` and `SendDeps`. All log emission goes through katip
   (via `logIO` in `IO` code, `logMsg` in `App` code).
2. Zero `hPutStrLn stderr` calls remain in `src/Seal/Channels/`,
   `src/Seal/Gateway/`, `src/Seal/Command/Serve.hs`, `src/Seal/Session/Lock.hs`,
   `src/Seal/Tabs.hs`, `src/Seal/Tabs/Persist.hs`, `src/Seal/Handles/Transcript.hs`,
   `src/Seal/Web/UiState.hs`, or `src/Seal/Agent/Loop.hs`. (Startup banners in
   `Server.hs` and `Config/Migrate.hs` are explicitly exempted — they run
   before the logger exists.) Verified by `Seal.Logging.NoStderrSpec` (a
   test that greps the source tree and asserts zero matches).
3. Every `forkIO` whose action can throw has a top-level `catch` or
   `withExceptionLogging` that logs via `logIO`. No forked thread dies
   silently.
4. The Telegram/Signal reader threads handle `ThreadKilled` as `InfoS`
   (normal shutdown), not `ErrorS` (crash). Other `AsyncException`s are
   logged at `WarningS` and are terminal.
5. `withExceptionLogging` replaces all 6 duplicated `catch` patterns in
   `Loop.hs`, `Send.hs`, and `Cli.hs`. The helper rethrows `AsyncException`
   (does not swallow `ThreadKilled`).
6. Every log entry from a channel turn includes `ChannelContext` metadata
   (channel kind, conversation id hash, session id) when available, via
   `withChannelContext` refining the logger at turn start.
7. `Env` gains `envLogger :: SealLogger`; `mkEnv :: SealLogger -> Config -> IO Env`.
   `runApp`'s signature is unchanged — it reads `envLogger` from `Env`. `App`-level
   `logMsg` and `IO`-level `logIO` reach the same scribe.
8. `withExceptionLogging` returns sanitized text for the user (generic
   message + correlation id); full exception text is logged to the operator
   only. `TranscriptError` text passes through unchanged.
9. `ChannelContext.ccConversationIdHash` is a SHA-256 hash (first 12 hex
   chars), never the full conversation id. The full id is available only in
   the per-session `seal.log`.
10. **User-focused**: Reproducing the `/skill load` from Telegram scenario
    from the bug report, the channel loop does NOT die — it logs the error
    at `ErrorS` with `channel=telegram` and continues processing the next
    message. The end-user receives a sanitized error message (not raw
    exception internals).
11. **User-focused**: An operator reading the console log can identify
    which channel generated an error from a single log line (the
    `ChannelContext` JSON includes `ccChannelKind`), without reading source
    code.
12. `make check` (`cabal build` + `cabal test` + `hlint -Werror`) passes.
13. New tests:
    - `Seal.Logging.LoggerSpec` — `logIO` emits to a test scribe;
      `withChannelContext` merges context (not replaces); newline escaping;
      `testSealLogger` produces no output. Cross-monad test: a `logMsg`
      inside `runApp` and a `logIO` from `IO` both land in the same captured
      scribe.
    - `Seal.Logging.ExceptionsSpec` — `withExceptionLogging` catches sync
      exceptions, returns sanitized `Left text` with correlation id;
      `AsyncException` is rethrown; `TranscriptError` text passes through;
      newline in exception `show` produces one log line (no forged `[LEVEL]`).
    - `Seal.Channels.LoopSpec` — a crashing slash command does NOT kill the
      loop; the loop continues processing the next message; the error is
      logged with `ChannelContext`.
    - `Seal.Logging.NoStderrSpec` — greps the source tree and asserts zero
      `hPutStrLn stderr` calls in the DoD-item-2 directories (excluding
      exempted `Server.hs` and `Config/Migrate.hs`). Verifies the 43-site
      migration is complete.
    - `Seal.Logging.LoggerSpec` (logger self-failure) — `logIO` with a
      closed/dead scribe does NOT throw; the error is silently swallowed.

## 5. Human checkpoints

- **After round 2 design review gate** — pause for user to read the 5
  reviewers' notes before planning.
- **After plan review gate** — pause for user to read the 3 reviewers'
  PASS/FAIL before implementation begins.
- **After implementation passes `make check`** — pause for user review
  before opening a PR.

## 6. Implementation phasing (RED-GREEN)

| Phase | RED (failing test first) | GREEN (implement) |
|---|---|---|
| 1. `SealLogger` + `ChannelContext` | `LoggerSpec`: `logIO` emits to a test scribe; `withChannelContext` merges context; newline escaping; cross-monad scribe sharing. Fails (modules don't exist). | Implement `Seal.Logging.Logger` + `Seal.Logging.ChannelContext`. `withSealLogger` bracket. `testSealLogger` with in-memory scribe. Tests pass. |
| 2. `withExceptionLogging` | `ExceptionsSpec`: sync exception → `Left text` with correlation id; `AsyncException` rethrown; `TranscriptError` passes through; newline injection blocked. Fails. | Implement `Seal.Logging.Exceptions`. Tests pass. |
| 3. Thread logger through deps | `LoopSpec` + `SendSpec` + `ApiSpec` fail to compile (`newChannelDeps`/`mkSendDeps`/`SendDeps` literals gain `SealLogger` param; `mkEnv` gains `SealLogger` first arg). | Add `cdLogger`/`sdLogger` (last field). `newChannelDeps`/`mkSendDeps` gain `SealLogger` final param. Add `envLogger` to `Env`; `mkEnv` gains `SealLogger` first arg. Export `testSealLogger` for tests. Update all test call sites (7 `newChannelDeps`, 4 `SendDeps` literals, `mkSendDeps` helper, per-module `runTestApp` helpers). Build logger at 4 startup sites via `withSealLogger`. Tests compile and pass. |
| 4. Migrate `catch` sites | `LoopSpec`: a crashing slash command does NOT kill the loop; next message is processed. Fails. | Replace 6 `catch` sites with `withExceptionLogging`. Add top-level `withExceptionLogging` around loop body (rethrows `AsyncException`). Add catch around `act caps` and `webCallDispatcher` in `Send.hs`. Add catch around Cli.hs bg runner. Tests pass. |
| 5. Reader thread `ThreadKilled` | `TelegramSpec`/`SignalSpec`: simulate `ThreadKilled` in the reader; assert logged at `InfoS`. `withTelegramChannel`/`withSignalChannel` gain `SealLogger` param. Fails. | Handle `ThreadKilled` in Telegram.hs + Signal.hs reader loops. Thread `SealLogger` into `TelegramChannel`/`SignalChannel` records. Tests pass. |
| 6. Migrate `hPutStrLn stderr` | A new test (`Seal.Logging.NoStderrSpec`) asserts zero `hPutStrLn stderr` calls in `src/Seal/Channels/`, `src/Seal/Gateway/`, `src/Seal/Command/Serve.hs`, `src/Seal/Session/Lock.hs`, `src/Seal/Tabs.hs`, `src/Seal/Tabs/Persist.hs`, `src/Seal/Handles/Transcript.hs`, `src/Seal/Web/UiState.hs`, `src/Seal/Agent/Loop.hs` (excluding the exempted `Server.hs` and `Config/Migrate.hs`). The test greps the source tree at compile time (via `file-embed` + regex) or at test runtime (via `directory` + `readFile`). Fails (sites still have stderr). | Replace all remaining `hPutStrLn stderr` sites with `logIO`/`logIOWith`. Thread logger through `Session/Lock.hs`, `Tabs.hs`, `Tabs/Persist.hs`, `Handles/Transcript.hs`, `Web/UiState.hs`, `Gateway/Stream.hs`, `Gateway/StreamBroker.hs`, `Agent/Loop.hs`. Refactor `Telegram/Transport.hs` stderr sites to `Either` returns + caller logging. The `NoStderrSpec` test passes. `make check` passes. |
| 7. `make check` gate | n/a | `make check` passes. |

## 7. Risks

- **Logger threading is invasive.** Adding a field to `ChannelDeps`,
  `SendDeps`, and `Env` touches every construction site. Mitigated by:
  (a) adding the field as the LAST field on `ChannelDeps`/`SendDeps`;
  (b) using smart constructors (`newChannelDeps`, `mkSendDeps`) that gain
  the logger as a final parameter (test call sites change in one place
  each); (c) `mkEnv` gains `SealLogger` as the first argument, and test
  sites go through per-module `runTestApp` helpers (one-line change each);
  (d) `testSealLogger` helper for cheap test construction.
- **Katip `LogEnv` lifetime.** The `SealLogger` holds a `LogEnv` with an
  open scribe. `withSealLogger` is a bracket that closes the scribe on exit.
  The 4 startup sites wrap their entire run in `withSealLogger`.
- **Performance of per-call `runKatipContextT`.** `logIO` calls
  `runKatipContextT` per log line. Logging is not on the hot path (turns,
  not per-token), so this is acceptable. The 1ms inbox poll
  (`receiveFromInbox`) must NOT log (it currently doesn't).
- **`ThreadKilled` vs real exceptions.** `withExceptionLogging` uses
  `fromException @AsyncException` to detect async exceptions and rethrows
  them. The reader threads distinguish `ThreadKilled` (InfoS, normal
  shutdown) from other `AsyncException`s (WarningS, terminal) from
  synchronous exceptions (ErrorS, crash). All `AsyncException`s are
  terminal for the reader — no retry logic.
- **Session log duplication.** `logTurnError` (session file) and `logIO`
  (katip) both fire for the same exception. This is intentional — the
  session log is the per-session audit trail; katip is the operator
  console. They serve different audiences. `withExceptionLogging` calls
  both internally, so the 6 call sites drop their explicit `logTurnError`.
- **Log-flood from loop body catch.** If the loop body throws on every
  inbound message (e.g. corrupt session JSON), the operator sees an
  `ErrorS` per message. A max-consecutive-errors circuit breaker (backoff
  after N errors) is deferred to v2. The current design is no worse than
  the status quo (which kills the loop on the first error, producing zero
  log lines).

## 8. Out of scope (deferred)

- Adding `aeLogger` to `AgentEnv` (the `App` monad's `KatipContext` suffices
  for `runTurn` logging via `logMsg`, which accesses `envLogger` through
  `MonadReader Env`).
- Migrating `logTurnStart`/`logTurnEnd`/`logProviderError`/`logMaxTurns` to
  katip (they stay as session-log file writes).
- Structured log output to a file (JSONL log file alongside stderr).
- Log filtering / search / alerting.
- OpenTelemetry / distributed tracing.
- Max-consecutive-errors circuit breaker for the loop body catch.
- Shared `Deps` base record (extracting common fields from `ChannelDeps`/
  `SendDeps` into a shared record — a separate refactor).
- Migrating `Config/Migrate.hs` and `Gateway/Server.hs` startup messages
  (they run before the logger exists; keeping stderr is fine).
- Extending secret-opcode redaction to the logger (exceptions from
  secret-producing opcodes may leak secret values in their `show` text —
  a future phase can add call-stack-based redaction).