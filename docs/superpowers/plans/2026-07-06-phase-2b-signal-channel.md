# Phase 2b — Signal Channel: Plan

> **For agentic workers:** Implement task-by-task, top to bottom. Each task is
> TDD (red → green → commit). Steps use checkbox (`- [ ]`) syntax. Do not start
> a task until the previous task's gate is green (`cabal build all` `-Werror`
> clean, `cabal test` green, `hlint src/ test/` clean, all in the Nix dev shell).
> One commit per task.

**Goal:** A clean-room reimplementation of the reference's Signal channel
(`Channels/Signal.hs` ~220 LOC + `Signal/Transport.hs` ~115 LOC), in this
repo's security-first style. The `seal signal` subcommand spawns signal-cli
as a child process, communicates over JSON-RPC on stdio, allow-lists senders,
chunks replies to the configured limit, derives a server-side
`ConversationId` from the peer, and routes every inbound message through
`Seal.Ingest` — proving the cross-channel foundation (Phase 2a) works for a
second, non-CLI channel. No source is copied; behavior closely matches the
reference.

**Parent roadmap:**
`docs/superpowers/plans/2026-06-28-seal-harness-roadmap.md` § Phase 2 (2b).

**Why this phase:** Signal is the smallest end-to-end channel proof in the
reference (~335 LOC total) and forces the cross-channel foundation to be
exercised by a real second channel — `MessageSource`/`ConversationId` must
thread into the transcript's `erMeta` `channel` field, the ingress gate
must run on a non-CLI channel, and the `ChannelHandle` must back a real
`Channel` instance (not just `FakeChannel`). Phase 6 (Tabs) and Phase 7
(Web) then consume the now-proven foundation.

## Tech Stack

Haskell (GHC2021), Cabal, Nix dev shell. New deps: **`process`** (the
`System.Process` family — `createProcess`/`pipeHandle`/`hGetLine`/`hPutStrLn`/`waitForProcess`).
**Do NOT use `typed-process`** in the new Signal transport code — use
`process` (System.Process) directly. (Existing modules — `Vault.Age`,
`Git.Repo`, `Provider`, `Backend` — still use `typed-process`; they are
untouched in 2b. A repo-wide migration off `typed-process` is out of scope.)

Existing deps used: `aeson`, `text`, `bytestring`, `stm` (the inbox
`TQueue`), `containers`. Build/test via `nix develop --command cabal build
all`, `… cabal test`, `… hlint src/ test/`.

## Global Constraints

Inherited from the roadmap verbatim where the spec is exact:

- **Module namespace:** all library code under `Seal.*`. New modules:
  `Seal.Channels.Signal.Transport`, `Seal.Channels.Signal`,
  `Seal.Signal.Config` (the `[signal]` config section). (Note:
  `Seal.Channels.Class` already exists from 2a; the Signal channel is a
  `Channel` instance over a `SignalChannel` record.)
- **Coding style:** GHC2021; conservative always-on `default-extensions`;
  per-file `OverloadedStrings` / `ImportQualifiedPost`. Whole-module imports;
  post-positive qualified imports.
- **Errors:** `Either Text` / `ExceptT Text` default. No bespoke error ADT
  expected — the transport returns `Either Text` for parse failures, the
  channel logs and drops on a non-fatal failure.
- **GHC flags:** `-Wall -Werror` plus the strict set.
- **TDD:** red → green → commit. The pure functions (`chunkMessage`,
  `parseSignalEnvelope`, `conversationIdForSignal`, `mkSignalConfig`) get
  unit + QuickCheck coverage. The IO-bound transport + channel are tested
  via a mock transport (no real signal-cli binary needed for the suite).
- **hlint clean** before each commit.
- **No secret ever serialized.** The signal-cli account's pairing secrets
  come from the vault via `withApiKey`-style CPS accessors; they NEVER
  enter the transcript, the `erMeta`, or the audited git log. The
  `SignalChannel` record carries only the *account label* (a phone number
  or UUID — that's transport metadata, not a secret) and the
  `AllowList UserId` (also transport metadata).
- **No shell-wrapping.** The signal-cli subprocess is invoked via a
  **fixed argv** (`signal-cli --output=json --trust-new-identities=always
  -u <account> jsonRpc`) — no shell interpreter, no constructed command
  string. The `<account>` is a smart-constructed `SignalAccount` newtype
  (charset predicate, no leading dash — option-injection defense). This is
  a fixed-argv invocation of a specific trusted binary, permitted as
  infrastructure per the roadmap's "No shell-wrapping" rule.
- **Type-guaranteed subprocess arguments.** `SignalAccount` is a
  smart-constructed newtype; the exec wrapper accepts only it, never raw
  `Text`. Rejects leading-dash values (option injection).
- **`MessageSource` is server-derived.** `conversationIdForSignal` derives
  the `ConversationId` from the peer's authenticated transport metadata
  (phone number + UUID, both present in signal-cli's envelope), **never
  from the message body**. This is the Phase-2a invariant, enforced
  structurally here: the envelope parser extracts the peer fields and the
  conversation id is minted from them; a body field named `conversationId`
  is ignored.
- **Cabal registration:** new library modules in `exposed-modules`, new test
  specs in `other-modules`, both alphabetical; new specs wired into
  `test/Main.hs`.
- **Commits:** one per task.
- **Build/verify:** `nix develop --command cabal build all`,
  `nix develop --command cabal test`,
  `nix develop --command cabal test --test-options='--match "<needle>"'`,
  `nix develop --command hlint src/ test/`.
- **Clean-room:** no prior/reference runtime named in code, comments, docs,
  or commit messages.

## Non-goals (explicitly out of scope for 2b)

- **No Telegram.** Phase 8.
- **No web gateway / WS.** Phase 7.
- **No tab routing / terse `/N` grammar.** Phase 6. (Signal does gain
  `/help` and any registered slash commands, but not `/tab` — the tab
  family lands in Phase 6 and is registered into the shared registry then.)
- **No CLI TUI unification.** `Seal.Channel.Cli` keeps its direct path.
- **No new providers.** Signal uses whatever provider the active session is
  bound to (resolved exactly as the CLI TUI resolves it).
- **No signal-cli auto-install.** If `signal-cli` is not on `$PATH`, `seal
  signal` fails fast with a clear diagnostic. The Nix dev shell may
  optionally provide it; the test suite uses a mock transport so it never
  needs the binary.
- **No end-to-end live signal-cli integration test in CI.** The capstone
  uses a mock transport. A manual smoke test against a real signal-cli +
  registered number is documented but not automated (signal-cli requires a
  registered phone number + SMS verification, which cannot run in CI).

---

## Task map

| Task | Title | Gate |
|---|---|---|
| **T0** | `Seal.Channels.Signal.Transport` — the testability seam + `chunkMessage` | `cabal test` green; `chunkMessage` + mock transport unit + QuickCheck |
| **T1** | `parseSignalEnvelope` + `conversationIdForSignal` (pure) | `cabal test` green; envelope parsing + conv-id derivation unit + QuickCheck |
| **T2** | `Seal.Signal.Config` — `[signal]` config section + `SignalAccount` | `cabal test` green; config round-trip; `SignalAccount` smart-constructor |
| **T3** | `Seal.Channels.Signal` — `SignalChannel` + `Channel` instance + `withSignalChannel` | `cabal test` green; mock-transport round-trip; allow-list drop; chunked send |
| **T4** | Wiring: `CommandSignal` + `seal signal` startup + config plumbing | `cabal build all` green; `seal signal --help` works; startup resolves vault account via CPS |
| **T5** | `Seal.Phase2bSpec` capstone — mock transport through `Seal.Ingest` to the agent loop | `cabal test` green; `MessageSource` threads into transcript `erMeta` `channel`; slash command dispatches; plain message routes to `runTurn`; non-allow-listed sender dropped |

---

## T0 — `Seal.Channels.Signal.Transport` — the testability seam + `chunkMessage`

**Why:** the transport is the IO boundary over signal-cli — the one place
that talks to the child process. Isolating it behind a record of IO actions
(`_stReceive`, `_stSend`, `_stClose`) means the channel logic (T3) and the
capstone (T5) are fully testable with a mock, no binary needed. The pure
`chunkMessage` lives here too because it's the send-side chunking policy.

**Module:** `src/Seal/Channels/Signal/Transport.hs`

### Design

```haskell
-- | The testability seam over signal-cli. Real impl spawns signal-cli as a
-- child process and talks JSON-RPC over stdio; mock impl backs the tests.
data SignalTransport = SignalTransport
  { stReceive :: IO (Either Text Value)       -- ^ next inbound JSON value (one line)
  , stSend    :: Text -> Text -> IO ()        -- ^ send a message: recipient, body
  , stClose   :: IO ()
  }

-- | Spawn @signal-cli --output=json --trust-new-identities=always -u <account> jsonRpc@
-- as a child process via System.Process, line-buffered JSON-RPC over
-- stdin/stdout. 'stReceive' reads one line from stdout and decodes it;
-- 'stSend' writes a JSON-RPC @send@ frame to stdin. 'stClose' terminates
-- the child.
mkRealSignalTransport :: SignalAccount -> IO (Either Text SignalTransport)

-- | A mock transport backed by a 'TQueue' of inbound 'Value's and an 'IORef'
-- of captured sends. 'stReceive' pops the next inbound (or returns
-- 'Left "inbox empty"'); 'stSend' appends (recipient, body) to the capture.
mkMockSignalTransport :: [Value] -> IO (SignalTransport, IO [(Text, Text)])

-- | Split a message into chunks of at most 'limit' characters, preferring
-- paragraph boundaries (@\\n\\n@), then line boundaries (@\\n@), hard-cut
-- as a last resort. Mirrors the reference's chunking. Pure.
chunkMessage :: Int -> Text -> [Text]
```

### `mkRealSignalTransport` — `process` usage

Uses `System.Process` (`createProcess` with `std_in`/`std_out`/`std_err` =
`CreatePipe`, no shell, fixed argv). The argv is built from the
smart-constructed `SignalAccount` (T2) so option injection fails to
compile. Line-buffered: `stReceive` is `hGetLine` on the child's stdout +
`decode` (aeson); `stSend` is `hPutStrLn` on the child's stdin (a JSON-RPC
`send` frame). `stClose` is `hClose` on both handles + `terminateProcess` +
`waitForProcess` (with a timeout — use `System.Timeout.timeout`). A
preflight `signal-cli --version` probe (mirroring `Vault.Age`'s `age
--version` preflight) fails fast if the binary is absent.

### `chunkMessage` invariants (QuickCheck)

- Every chunk is non-empty.
- Every chunk is `<= limit` characters.
- `concatChunks (chunkMessage limit t) == t` (the chunks reassemble to the
  original — hard-cut preserves bytes, boundary splits drop the separator
  and re-add it on reassembly; see the reassembly note below).
- `chunkMessage limit "" == []`.
- `chunkMessage 5 "abc" == ["abc"]` (under-limit passes through).
- For `limit >= 1`, `chunkMessage limit t` covers every character of `t`.

**Reassembly note:** paragraph/line splits drop the separator (`\n\n` /
`\n`); the chunks are the text *between* separators. Reassembly rejoins
with the appropriate separator. To keep `concatChunks == t` true, the
splitter must remember which separator was consumed and the reassembly must
re-insert it. **Simpler design:** chunkMessage emits the chunks *including*
their trailing separator (except the last), so `concat` is identity. This
matches "the chunks are the literal bytes to send, in order" and avoids a
reassembly mismatch. Adopt this: chunks carry their trailing separator;
the last chunk has none; `concat == id`.

### TDD steps

- [ ] **Red.** Write `test/Seal/Channels/Signal/TransportSpec.hs`:
  - `chunkMessage`: the explicit cases above.
  - QuickCheck: for all `limit >= 1`, `t`, the invariants hold (use a
    small `limit` range like `1..40` and a generator that includes
    `\n\n` and `\n`).
  - Mock transport: `stReceive` pops scripted values in order, then
    `Left "inbox empty"`; `stSend` captures `(recipient, body)` pairs in
    order; `stClose` is idempotent.
- [ ] **Red-verify.** Fails (module missing).
- [ ] **Green.** Implement `src/Seal/Channels/Signal/Transport.hs`.
  Register `Seal.Channels.Signal.Transport` in `exposed-modules` (under
  `Seal.Channels.Class`). Add `process` to the library + test `build-depends`.
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(signal): transport seam + chunkMessage`

---

## T1 — `parseSignalEnvelope` + `conversationIdForSignal` (pure)

**Why:** the two pure functions that turn a raw signal-cli JSON value into
the `MessageSource`-bearing `SignalEnvelope` and derive the server-side
`ConversationId`. Pure ⇒ heavy QuickCheck. The security-critical property:
the `ConversationId` is derived from the peer's authenticated transport
metadata, never from the message body.

**Module:** `src/Seal/Channels/Signal/Transport.hs` (same module — they're
the envelope-parsing pair). Export `SignalEnvelope`, `parseSignalEnvelope`,
`conversationIdForSignal`.

### Design

```haskell
-- | A parsed inbound signal-cli envelope: the peer-derived conversation id,
-- the sender's user id, and the message body.
data SignalEnvelope = SignalEnvelope
  { seConversationId :: ConversationId
  , seSender         :: UserId
  , seBody           :: Text
  }

-- | Parse a raw signal-cli JSON value into a 'SignalEnvelope'. Handles both
-- raw envelopes and JSON-RPC-wrapped @params.envelope@ messages. Returns
-- 'Left' on a malformed value or a missing peer field. The body is taken
-- from the envelope; the conversation id is NOT — it's derived via
-- 'conversationIdForSignal'.
parseSignalEnvelope :: Value -> Either Text SignalEnvelope

-- | Derive the server-side 'ConversationId' from the peer's authenticated
-- transport metadata. signal-cli envelopes carry both a phone number
-- (@source@) and a UUID (@sourceUuid@); the conversation id is
-- @sig:<source>:<sourceUuid>@ (or @sig:<source>@ when the UUID is absent).
-- Never reads the message body.
conversationIdForSignal :: Maybe Text -> Maybe Text -> Either Text ConversationId
```

### Invariants (QuickCheck + unit)

- `conversationIdForSignal (Just "+1") (Just "uuid")` =>
  `ConversationId "sig:+1:uuid"`.
- `conversationIdForSignal (Just "+1") Nothing` =>
  `ConversationId "sig:+1"`.
- `conversationIdForSignal Nothing _` => `Left` (a peer phone number is
  required).
- `parseSignalEnvelope` of a well-formed raw envelope yields the right
  `seConversationId`/`seSender`/`seBody`.
- `parseSignalEnvelope` of a JSON-RPC-wrapped `{"jsonrpc":"2.0",
  "method":"receive", "params":{"envelope":{...}}}` unwraps to the inner
  envelope.
- `parseSignalEnvelope` of a value missing the `source` field => `Left`.
- **Security property (QuickCheck):** for any envelope, the derived
  `ConversationId` depends only on the peer fields (`source`/`sourceUuid`),
  never on the body. (Construct two envelopes with the same peer but
  different bodies; assert equal conversation ids.)
- A body field named `conversationId` is IGNORED (the conversation id is
  always server-derived).

### TDD steps

- [ ] **Red.** Write `test/Seal/Channels/Signal/EnvelopeSpec.hs` with the
  invariants above.
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement the parsing + derivation in
  `src/Seal/Channels/Signal/Transport.hs`. (`parseSignalEnvelope` uses
  aeson's `withObject`; handles both shapes via a `method`/`params.envelope`
  unwrap attempt.)
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(signal): parseSignalEnvelope + server-derived conversationId`

---

## T2 — `Seal.Signal.Config` — `[signal]` config section + `SignalAccount`

**Why:** the `[signal]` config section (`account`, `text_chunk_limit`,
`allow_from`) + the smart-constructed `SignalAccount` newtype (the
option-injection defense for the signal-cli argv). Lives in its own module
so `Seal.Config.File` can add the section without a cycle.

**Module:** `src/Seal/Signal/Config.hs`

### Design

```haskell
-- | The signal-cli account label (a phone number or UUID). Smart-constructed:
-- non-empty, no leading dash (option-injection defense), charset
-- [A-Za-z0-9+:-]. The validated type that reaches the subprocess argv.
newtype SignalAccount = SignalAccount Text
  deriving stock (Eq, Show)

mkSignalAccount :: Text -> Either Text SignalAccount
signalAccountText :: SignalAccount -> Text

-- | The [signal] config section. All fields optional at the file level;
-- 'seal signal' fails fast if 'account' is unset.
data SignalConfig = SignalConfig
  { scAccount        :: Maybe Text       -- ^ phone number or UUID
  , scTextChunkLimit :: Maybe Int        -- ^ default 1998 (Signal's limit)
  , scAllowFrom      :: AllowList Text   -- ^ sender allow-list (phone or UUID)
  }

defaultSignalConfig :: SignalConfig
defaultSignalConfig = SignalConfig Nothing (Just defaultSignalChunkLimit) AllowAll

defaultSignalChunkLimit :: Int
defaultSignalChunkLimit = 1998

-- | Resolve a loaded FileConfig's [signal] section + the vault-supplied
-- account label into a validated 'SignalAccount' + chunk limit + allow-list.
-- The account label may come from config OR the vault (vault wins); either
-- way it's smart-constructed here.
resolveSignalConfig :: FileConfig -> Maybe Text -> Either Text (SignalAccount, Int, AllowList UserId)
```

### `AllowList UserId` mapping

The config's `allow_from` is an `AllowList Text` (phone numbers / UUIDs as
strings). `resolveSignalConfig` maps each through `mkUserId` to an
`AllowList UserId` for the channel's sender check. `AllowAll` passes
through; `AllowOnly` maps each element (a malformed entry fails the whole
resolution with a clear error).

### `FileConfig` extension

Add `fcSignal :: Maybe SignalConfig` to `Seal.Config.File.FileConfig` +
extend the TOML codec with a `[signal]` table (`account`,
`text_chunk_limit`, `allow_from` — the last as a TOML array of strings,
`AllowAll` when absent). `defaultFileConfig` gets `fcSignal = Nothing`.

### TDD steps

- [ ] **Red.** Write `test/Seal/Signal/ConfigSpec.hs`:
  - `mkSignalAccount` rejects empty / leading-dash / invalid chars;
    accepts `+15551234567`, `uuid:abcd-1234`.
  - `resolveSignalConfig`: config-only account succeeds; vault-supplied
    account overrides config; missing account => `Left`; malformed
    `allow_from` entry => `Left`; `AllowAll` passes through.
  - TOML round-trip: a `[signal]` section with all three fields round-trips
    through `loadFileConfig`/`saveFileConfig`; absent section => `Nothing`.
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement `src/Seal/Signal/Config.hs`; extend
  `Seal.Config.File` (`FileConfig` field + codec + `defaultFileConfig`).
  Register `Seal.Signal.Config` in `exposed-modules`.
- [ ] **Green-verify.** Build + the **full** suite green (the
  `FileConfig` shape change must not break `Config.FileSpec`,
  `Vault.CommandsSpec`, etc.). hlint clean.
- [ ] **Commit.** `feat(signal): [signal] config section + SignalAccount smart constructor`

---

## T3 — `Seal.Channels.Signal` — `SignalChannel` + `Channel` instance + `withSignalChannel`

**Why:** the `SignalChannel` record (config + inbox `TQueue SignalEnvelope` +
transport + `IORef` last-sender) and its `Channel` instance — the first
real `Channel` instance (FakeChannel was the test instance in 2a). The
reader thread parses signal-cli output, allow-lists the sender, and pushes
envelopes to the inbox. Send chunks via the transport.

**Module:** `src/Seal/Channels/Signal.hs`

### Design

```haskell
data SignalChannel = SignalChannel
  { scConfig   :: SignalConfig      -- ^ chunk limit + allow-list (resolved)
  , scAccount  :: SignalAccount
  , scInbox    :: TQueue SignalEnvelope
  , scTransport :: SignalTransport
  , scLastSender :: IORef (Maybe UserId)
  }

instance Channel SignalChannel where
  toHandle ch = ChannelHandle
    { chSend        = sendChunked ch
    , chSendError   = \t -> stSend (scTransport ch) (recipientForLast ch) ("error: " <> t)
    , chSendChunk   = sendChunked ch   -- chunks are pre-split by the caller
    , chPrompt      = \_ -> pure (Left Deferred)   -- Signal can't answer inline
    , chPromptSecret = \_ -> pure (Left Deferred)
    , chStreaming   = True
    , chReadSecret  = pure Nothing    -- vault is reached via the vault handle
    , chReceive     = receiveFromInbox ch
    }

-- | Run the reader thread with cleanup. Spawns a background thread that
-- loops 'stReceive' + 'parseSignalEnvelope', allow-lists the sender, and
-- pushes to 'scInbox'. On transport close or exception, the thread exits.
withSignalChannel :: SignalConfig -> SignalAccount -> SignalTransport
                 -> (SignalChannel -> IO a) -> IO a

-- | Derive the recipient for an outbound send: the last-sender's user id
-- (so a reply goes back to the peer who just messaged). 'Nothing' when no
-- peer has been seen yet — the send is dropped with a log.
recipientForLast :: SignalChannel -> Text
```

### Reader thread

`withSignalChannel` brackets the reader thread:
1. Allocate `TQueue` + `IORef` + the `SignalChannel`.
2. `forkIO` a reader loop: `stReceive` → on `Right val`, `parseSignalEnvelope val` → on `Right env`, allow-list check (`isAllowed (seSender env) (scAllowList config)`) → on pass, `atomically (writeTQueue inbox env)` + update last-sender; on fail, log + drop; on `Left err`, log + continue (a malformed line is not fatal).
3. Run the action.
4. Cleanup: `stClose` the transport + `killThread` the reader.

### `sendChunked`

`chSend t` splits `t` via `chunkMessage (chunkLimit config) t` and sends
each chunk via `stSend transport recipient chunk`, where `recipient` is
`recipientForLast`. If no last sender, log + drop. `chSendChunk t` sends
`t` as-is (the caller pre-split).

### `receiveFromInbox`

`chReceive` blocks on `atomically (readTQueue inbox)` and returns
`(Just (mkMessageSourceFromEnvelope env), seBody env)`. The
`MessageSource` is built from the envelope's `seConversationId` +
`ChannelKind = Signal` + `Just (seSender env)` + an empty open map. This
is where the Phase-2a `MessageSource` threads into a real channel.

### `mkMessageSourceFromEnvelope`

Pure helper: `SignalEnvelope -> MessageSource` via `mkMessageSource`. If
`mkMessageSource` ever fails (it shouldn't, given the smart-constructed
ids), the reader thread logs + drops the envelope instead of crashing.

### TDD steps

- [ ] **Red.** Write `test/Seal/Channels/SignalSpec.hs` using a mock
  transport:
  - Script two inbound values (a raw envelope + a JSON-RPC-wrapped one);
    `withSignalChannel` + `chReceive` yields both in order with the right
    `MessageSource` (`ChannelKind = Signal`, `ConversationId =
    "sig:+1:uuid"`).
  - A non-allow-listed sender: `chReceive` never yields it (the reader
    drops it); the next allow-listed message comes through.
  - `chSend "a long message..."` with `text_chunk_limit = 10` sends
    multiple chunks via the transport; assert the capture has the chunks.
  - `chSend` with no last sender: the send is dropped (capture empty).
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement `src/Seal/Channels/Signal.hs`. Register in
  `exposed-modules` (after `Seal.Channels.Class`, before
  `Seal.Channels.Signal.Transport`).
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(signal): SignalChannel + Channel instance + reader thread`

---

## T4 — Wiring: `CommandSignal` + `seal signal` startup + config plumbing

**Why:** the `seal signal` subcommand spawns the Signal channel + runs the
agent loop against it, parallel to `seal tui`. Resolves the signal-cli
account's pairing secrets from the vault via CPS (no secret in the
transcript). Reuses the existing `Backends`/`ISA.Registry`/session
machinery from `Seal.Channel.Cli` so the agent loop is identical.

**Modules:** `src/Seal/Types/Command.hs` (add `CommandSignal`),
`src/Seal/Channels/Signal.Run.hs` (the startup), `src/Seal/AppMain.hs`
(dispatch arm).

### Design

```haskell
-- Seal.Types.Command
data Command = CommandNoOp | CommandTui | CommandSignal
  deriving (Eq, Show)
-- pCommand adds: command "signal" (info (pure CommandSignal) (progDesc "Run the agent over the Signal channel"))

-- Seal.Channels.Signal.Run
runSignal :: SealPaths -> VaultRuntime -> ProviderRuntime -> SessionRuntime
          -> Registry -> PreprocessChain -> Backends
          -> SignalConfig -> IO ()
-- 1. Resolve the SignalAccount (from config or vault; vault wins).
-- 2. mkRealSignalTransport account  -- spawns signal-cli
--    on Left err: putStrLn diagnostic + exit
-- 3. withSignalChannel config account transport $ \ch ->
--      let h = toHandle ch
--      in runSignalLoop paths rt pr sr registry chain backends h
```

### `runSignalLoop`

The loop mirrors `runCliTui`'s structure but is inbox-driven (not
Haskeline-driven):
1. `chReceive` blocks for the next `(MessageSource, Text)`.
2. `ingest registry chain (RawInbound text)` → `interpretDisposition`.
3. For `PlainMessage t`: resolve the active session's provider+model
   (exactly as `runCliTui` does), build `mkSessionAgentEnv` **but with a
   `ChannelCaps` adapter over the `ChannelHandle`** (the same adapter the
   capstone used — `ccSend`/`ccPrompt`/`ccPromptSecret` forwarded), then
   `handlePlain`. **The `MessageSource` is threaded into the transcript's
   `erMeta` `channel` field** — see the loop-diff note below.
4. For `DispatchAction`/`ShowText`/`Rejected`: as the CLI TUI.
5. Loop.

### Loop-diff: `MessageSource` → transcript `erMeta`

The current `runTurn` writes `erMeta = Map.empty`. To thread the channel,
`runSignalLoop` builds the `AgentEnv` with an `aeMeta` field? **No — keep
2b minimal.** The cleanest path: add a `Maybe MessageSource` to `AgentEnv`
(`aeMessageSource :: Maybe MessageSource`), default `Nothing` for the CLI
TUI (which doesn't have one yet), `Just ms` for Signal. `runTurn` folds
`msChannelKind <$> aeMessageSource` into the request `EntryRecord`'s
`erMeta` under the `"channel"` key (and the `ConversationId` under
`"conversationId"`). This is the 2a plan's "threading into the agent loop"
step, landing here in 2b.

**This is the one `AgentEnv`/`runTurn` change in 2b.** It is backward-
compatible: `aeMessageSource = Nothing` means `erMeta` is unchanged for the
CLI TUI (the existing `WiringSpec`/`CliSpec`/`Phase5Spec` stay green).

### Vault account via CPS

The signal-cli account label is a phone number / UUID — **that's transport
metadata, not a secret**, so it can live in config. If the user prefers to
keep it in the vault, `runSignal` reads it via the vault handle's CPS
accessor (`withApiKey`-style) — the label surfaces to `SignalAccount`
construction but the vault entry's *value* is the account label, and a
label is not a secret. (No secret crosses the transcript boundary either
way.)

### TDD steps

- [ ] **Red.** Add `CommandSignal` to `Seal.Types.Command` (the
  `AppMainSpec` may need a tweak — check it). Write
  `test/Seal/Channels/Signal/RunSpec.hs`:
  - `seal signal --help` renders (a `Command` parse test, no spawn).
  - `runSignalLoop` with a mock `ChannelHandle` + a scripted `/ping` then
    `hello`: the `/ping` dispatches (reply captured via `chSend`), `hello`
    routes to `handlePlain` with a scripted provider (reuse
    `ScriptProvider` from `WiringSpec`), the reply is sent via `chSend`,
    and the transcript's request `EntryRecord` carries
    `erMeta ! "channel" == "signal"` and
    `erMeta ! "conversationId" == "sig:+1:uuid"`.
  - The `aeMessageSource = Nothing` path (CLI TUI) leaves `erMeta` without
    a `channel` key (assert on a fake transcript — the existing
    `WiringSpec` pattern).
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement. Add `aeMessageSource` to `AgentEnv`; thread
  into `runTurn`'s request `EntryRecord` `erMeta`. Add `runSignal` +
  `runSignalLoop` to `Seal.Channels.Signal.Run`. Add the `CommandSignal`
  dispatch arm to `AppMain`. Register
  `Seal.Channels.Signal.Run` in `exposed-modules`.
- [ ] **Green-verify.** Build + **full** suite green (the `AgentEnv` +
  `runTurn` change must not break `WiringSpec`/`CliSpec`/`Phase5Spec`/
  `Agent.LoopSpec`). hlint clean.
- [ ] **Commit.** `feat(signal): seal signal subcommand + MessageSource threaded into transcript erMeta`

---

## T5 — `Seal.Phase2bSpec` capstone — mock transport through `Seal.Ingest` to the agent loop

**Why:** the proof that the Signal channel works end-to-end through the
ingress gate to the agent loop, with `MessageSource` threaded into the
transcript. The 2b milestone gate.

**Module:** `test/Seal/Phase2bSpec.hs`

### Design

The capstone exercises the *real* `SignalChannel` (T3) over a *mock*
`SignalTransport` (T0), driven through `runSignalLoop` (T4) with a
`ScriptProvider` (T4 spec already does this — the capstone is the
end-to-end version):

1. Build a mock transport with two scripted inbound values:
   - A raw envelope from `+15551234567` / uuid `abc` with body `/ping`.
   - A raw envelope from the same peer with body `hello`.
   - A third from a non-allow-listed sender (`+19999999999`) with body
     `ignored`.
2. `withSignalChannel` (allow-list = `AllowOnly {+15551234567}`) +
   `runSignalLoop` with a `ScriptProvider` that replies "hi from model" to
   any plain text.
3. Assert:
   - The allow-listed `/ping` dispatches → `pong` is sent via the
     transport (capture contains `("+15551234567", "pong")`).
   - The allow-listed `hello` routes to `runTurn` → the provider's "hi
     from model" reply is sent via the transport (capture contains
     `("+15551234567", "hi from model")`).
   - The non-allow-listed `ignored` is dropped (no send, no transcript
     entry for it).
   - The transcript's request `EntryRecord` for `hello` carries
     `erMeta ! "channel" == "signal"` and
     `erMeta ! "conversationId" == "sig:+15551234567:abc"`.
4. `stClose` is called on shutdown (the bracket cleans up).

### TDD steps

- [ ] **Red.** Write `test/Seal/Phase2bSpec.hs` with the scenario above.
- [ ] **Red-verify.** Fails (or partially passes if T4's RunSpec already
  covers pieces — the capstone is the full end-to-end).
- [ ] **Green.** Make it pass. No library change expected (T0–T4 did the
  work); if a helper is missing, add it to the test or the library as
  appropriate.
- [ ] **Green-verify.** `cabal test --match "Phase 2b capstone"` green;
  full suite green; hlint clean.
- [ ] **Commit.** `test(phase2b): capstone — Signal over mock transport end-to-end through Ingest`

---

## Milestone (2b)

**Definition of Done (whole sub-phase):**

- [ ] `cabal build all` is `-Werror` clean (Nix dev shell).
- [ ] `cabal test` green including the new QuickCheck properties and the
      `Seal.Phase2bSpec` capstone.
- [ ] `hlint src/ test/` clean.
- [ ] `seal signal` (Nix dev shell, with a real or mock signal-cli)
      receives a message from an allow-listed sender, routes it through
      `Seal.Ingest` to the agent loop, dispatches any `/`-command via the
      registry, threads the `ChannelKind`/`ConversationId` into the
      transcript's `erMeta`, and sends the agent's reply back via
      signal-cli (chunked to the configured limit).
- [ ] A message from a non-allow-listed sender is logged and dropped.
- [ ] The existing `seal tui` CLI channel is unaffected (the
      `aeMessageSource = Nothing` path leaves `erMeta` unchanged).
- [ ] All five tasks committed (one commit per task).

**Manual smoke test (documented, not automated):**
```
nix develop --command cabal run seal -- signal
# with signal-cli registered + [signal] config set
# send a text from an allow-listed number → agent replies, chunked
# send /help → the help index is chunked back
```

**Next:** Phase 6 — Harness + Tabs (text-based tab UI).