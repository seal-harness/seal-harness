# Phase 2a — Core Cross-Channel Types: Plan

> **For agentic workers:** Implement task-by-task, top to bottom. Each task is
> TDD (red → green → commit). Steps use checkbox (`- [ ]`) syntax. Do not start
> a task until the previous task's gate is green (`cabal build all` `-Werror`
> clean, `cabal test` green, `hlint src/ test/` clean, all in the Nix dev shell).
> One commit per task.

**Goal:** Stand up the shared cross-channel vocabulary every later channel
(Phase 2b Signal, Phase 6 Tabs, Phase 7 Web) imports — `ChannelKind`,
`MessageSource` + `ConversationId`, the reusable `AllowList` family, the
widened `ChannelCaps`/`ChannelHandle` capability seam, and the `Channel` type
class — with QuickCheck invariants and JSON round-trips, and a no-op
`FakeChannel` instance that exercises the wiring end-to-end. **No runtime
behavior change:** the existing CLI TUI (`Seal.Channel.Cli`) keeps working
exactly as before. This is the foundation; Phase 2b (Signal) is the first real
consumer.

**Parent roadmap:**
`docs/superpowers/plans/2026-06-28-seal-harness-roadmap.md` § Phase 2 (2a).

**Why these types, why now:** Phase 6 (Tabs) keys tab cursors on
`ChannelKind × ConversationId`; Phase 7 (Web) needs `ChannelKind` for the
transcript's `_te_metadata` channel field and a `MessageSource` to know which
conversation an inbound web frame belongs to; Phase 2b (Signal) needs all of
them plus the widened `ChannelHandle` to be a real `Channel` instance. Landing
them now — leaf-ish, depend only on `Seal.Core`/`Seal.Security`, with
QuickCheck coverage — settles the vocabulary before any of those features
touch it, so the later phases are pure consumers.

## Tech Stack

Haskell (GHC2021), Cabal, Nix dev shell. No new deps — uses the existing
`aeson`, `text`, `containers`, `stm`, `QuickCheck`. Build/test via
`nix develop --command cabal build all`, `… cabal test`,
`… hlint src/ test/`.

## Global Constraints

Inherited from the roadmap verbatim where the spec is exact:

- **Module namespace:** all library code under `Seal.*`. New modules:
  `Seal.Core.ChannelKind`, `Seal.Core.MessageSource`, `Seal.Core.AllowList`,
  `Seal.Handles.Channel`, `Seal.Channels.Class`. (Note: `AllowList` already
  exists as a *constructor family* in `Seal.Security.Policy`; this task
  extracts/promotes it to its own `Seal.Core.AllowList` module so the
  cross-channel layer can use it without depending on the whole security
  policy, and `Seal.Security.Policy` re-exports it for backward compatibility.
  See Task 3 for the migration.)
- **Coding style:** GHC2021; conservative always-on `default-extensions`
  (`DeriveGeneric, DeriveStrategies, LambdaCase, ScopedTypeVariables`);
  per-file `OverloadedStrings` etc. Whole-module
  imports; post-positive qualified imports (`import Data.Text qualified as T`).
- **Errors:** `Either Text` / `ExceptT Text` default. No bespoke error ADT
  expected in 2a — the smart constructors return `Either Text`.
- **GHC flags:** `-Wall -Werror` plus the strict set. Warnings are errors.
- **TDD:** red → green → commit. Security-critical pure functions
  (`mkMessageSource`, `mkConversationId`, the `AllowList` invariants) get
  QuickCheck properties.
- **hlint clean** before each commit.
- **No secret ever serialized.** N/A in 2a (no secrets in these types), but
  the rule stands: `MessageSource`'s open field map carries only
  attacker-controlled *metadata*, never secrets.
- **Type-guaranteed identifiers.** `ConversationId` and `UserId` are
  smart-constructed newtypes with a charset predicate and a length bound —
  the same predicate shape as `SessionId`, tightened with a max length so an
  attacker cannot bloat the transcript or exhaust a cursor map.
- **Cabal registration:** new library modules in `exposed-modules`, new test
  specs in `other-modules`, both alphabetical; new specs wired into
  `test/Main.hs`.
- **Commits:** one per task.
- **Build/verify:** `nix develop --command cabal build all`,
  `nix develop --command cabal test`,
  `nix develop --command cabal test --test-options='--match "<needle>"'`,
  `nix develop --command hlint src/ test/`.
- **Clean-room:** no prior/reference runtime named in code, comments, docs, or
  commit messages.

## Non-goals (explicitly out of scope for 2a)

- **No Signal channel.** That is 2b. 2a only delivers the types + the widened
  handle + the class + a `FakeChannel` test instance.
- **No CLI TUI unification.** `Seal.Channel.Cli` keeps its direct
  `interpretDisposition` path and its existing `ChannelCaps`. The widened
  `Seal.Handles.Channel`/`Seal.Channels.Class` live alongside it; the CLI is
  *not* made a `Channel` instance in 2a (deferred to Phase 8 if ever).
- **No `MessageSource` threading into the agent loop yet.** The agent loop
  (`runTurn`) and the transcript's `_te_metadata` are *not* modified to carry
  `MessageSource` in 2a — that lands in 2b when the first real non-CLI channel
  needs it. 2a only delivers the type and its invariants. The capstone
  exercises the type via the `FakeChannel`/`Seal.Ingest` seam, not the agent
  loop.
- **No tab routing.** The terse `/N` grammar and `TabList` are Phase 6.
- **No gateway / WS / web.** Phase 7.
- **No new providers.** Phase 8.
- **No removal of `Seal.Channel.Caps`.** The old `ChannelCaps` stays for the
  CLI TUI; the widened `ChannelHandle` is the *target* the new channels
  implement. (A later phase may unify them; not now.)

---

## Task map

| Task | Title | Gate |
|---|---|---|
| **T0** | `Seal.Core.ChannelKind` | `cabal test` green; QuickCheck round-trip; `channelKindToText`/parse covered |
| **T1** | `Seal.Core.MessageSource` + `ConversationId` + `UserId` | `cabal test` green; QuickCheck on `mkMessageSource` invariants + JSON round-trip |
| **T2** | `Seal.Core.AllowList` extraction + `Seal.Security.Policy` re-export | `cabal test` green; existing PolicySpec still passes; new AllowListSpec green |
| **T3** | `Seal.Handles.Channel` (widened capability record) | `cabal test` green; FakeHandleSpec exercises the widened shape |
| **T4** | `Seal.Channels.Class` + `FakeChannel` test instance | `cabal test` green; FakeChannel is a `Channel`; `toHandle` round-trips |
| **T5** | `Seal.Phase2aSpec` capstone | drive a `FakeChannel` through `Seal.Ingest`; assert `MessageSource` carries the right `ChannelKind`/`ConversationId`; slash command dispatches; plain message routes as `PlainMessage` |

---

## T0 — `Seal.Core.ChannelKind`

**Why:** the channel enumeration is the leaf every other cross-channel type
keys on. It is pure, security-relevant (the transcript's `_te_metadata`
channel field is derived from it), and has a trivial invariant (the
enumeration is closed; `Other` is the escape hatch for future channels).

**Module:** `src/Seal/Core/ChannelKind.hs`

### Design

```haskell
data ChannelKind
  = Cli | Web | Signal | Telegram | Background | Other
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (ToJSON, FromJSON)

channelKindToText :: ChannelKind -> Text
channelKindFromText :: Text -> Maybe ChannelKind
```

- `channelKindToText` emits the lowercase tag (`"cli"`, `"web"`, `"signal"`,
  `"telegram"`, `"background"`, `"other"`) — the value the transcript's
  `_te_metadata` `channel` field carries.
- `channelKindFromText` is the inverse, case-insensitive on input, returning
  `Nothing` for unknown tags (the caller decides whether to fall back to
  `Other` or reject).
- `Other` is the explicit escape hatch for channels not yet enumerated (e.g.
  a future Discord bridge). It is NOT a synonym for "unknown" — it is a
  first-class channel kind that happens to be generic.

### TDD steps

- [ ] **Red.** Write `test/Seal/Core/ChannelKindSpec.hs`:
  - `channelKindToText Signal == "signal"` (and the other five).
  - `channelKindFromText "signal" == Just Signal`, `"SIGNAL" == Just Signal`,
    `"unknown" == Nothing`.
  - QuickCheck: for all `k :: ChannelKind`,
    `channelKindFromText (channelKindToText k) == Just k`.
  - QuickCheck: `channelKindToText` never emits an empty or control-char
    string (the tag is a safe transcript metadata value).
  - JSON round-trip: `decode (encode k) == k`.
  - `minBound .. maxBound` covers exactly the six constructors (no drift).
- [ ] **Red-verify.** `nix develop --command cabal test --test-options='--match "ChannelKind"'` — fails (module missing).
- [ ] **Green.** Implement `src/Seal/Core/ChannelKind.hs`. Register in
  `exposed-modules` (alphabetical: insert after `Seal.Core.Types` is wrong —
  `ChannelKind` sorts before `Paging`/`Types`, so it goes first among
  `Seal.Core.*`).
- [ ] **Green-verify.** `cabal build all` `-Werror` clean; `cabal test --match "ChannelKind"` green; `hlint src/ test/` clean.
- [ ] **Commit.** `feat(core): ChannelKind enumeration + text codec`

---

## T1 — `Seal.Core.MessageSource` + `ConversationId` + `UserId`

**Why:** `MessageSource` is the authenticated-transport-derived identity of an
inbound message. It is the type Phase 6 tabs key cursors on
(`ChannelKind × ConversationId`) and the type Phase 7 web frames carry. The
critical security property: **the `ConversationId` is server-derived from
transport metadata, never read from a message body**, so a sender cannot forge
it to hijack another conversation's tab cursor. That property is enforced
*structurally*: `mkMessageSource` takes a `ConversationId` (which itself is
smart-constructed) and never reads a conversation id from the open field map.

**Module:** `src/Seal/Core/MessageSource.hs`

### Design

```haskell
-- | A server-derived, transport-scoped conversation key. NEVER read from a
-- message body — always minted from authenticated transport metadata (e.g.
-- the Signal peer's phone number + UUID, the web session's authenticated
-- principal). Smart-constructed; the predicate bounds length and charset so
-- an attacker cannot bloat the transcript or exhaust a cursor map.
newtype ConversationId = ConversationId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

mkConversationId :: Text -> Either Text ConversationId
conversationIdText :: ConversationId -> Text

-- | An authenticated user identity on a channel (e.g. a Signal phone number
-- or UUID, a Telegram user id, a web principal). Optional — some channels
-- (Background) have no user. Smart-constructed with the same predicate shape.
newtype UserId = UserId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

mkUserId :: Text -> Either Text UserId
userIdText :: UserId -> Text

-- | The authenticated-transport-derived identity of an inbound message.
-- Constructed ONLY via 'mkMessageSource', which strips control characters
-- and bounds the length of every attacker-controlled string leaf.
data MessageSource = MessageSource
  { msConversationId :: ConversationId   -- ^ required; server-derived
  , msChannelKind    :: ChannelKind
  , msUserId         :: Maybe UserId     -- ^ optional; absent on Background
  , msOpen           :: Map Text Text    -- ^ bounded, control-char-stripped
  } deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

mkMessageSource :: ConversationId -> ChannelKind -> Maybe UserId
               -> Map Text Text -> Either Text MessageSource
```

### Invariants (QuickCheck)

- `mkConversationId` rejects: empty, over-256-chars, control chars, leading
  dot. Accepts `[A-Za-z0-9_-]` plus `:` (colon — needed for composite keys
  like `phone:uuid`) up to the length bound.
- `mkUserId` same predicate (minus the leading-dot special case — user ids
  are transport-minted, never path-joined, so the leading-dot rule is not
  needed; keep the charset + length bound).
- `mkMessageSource` strips control chars from every value in the open map,
  rejects any key or value over the length bound (256), and rejects the
  whole thing if the open map has more than 32 entries (a bound on
  attacker-controlled metadata size).
- The open map MUST NOT contain a key named `conversationId` — that field is
  structural, not open; `mkMessageSource` rejects it to prevent a future
  caller from smuggling a second conversation id into the open field.
- JSON round-trip: `decode (encode ms) == ms` for any `ms` constructed via
  `mkMessageSource`.
- `Show` does not redact (these are not secrets — they are transport
  metadata). The no-secret rule applies to *values*, not to identities.

### TDD steps

- [ ] **Red.** Write `test/Seal/Core/MessageSourceSpec.hs` with the
  invariants above as QuickCheck properties + explicit rejection cases
  (empty conversation id, over-long, control-char, leading-dot, `conversationId`
  key in open map, >32 open entries).
- [ ] **Red-verify.** Fails (module missing).
- [ ] **Green.** Implement `src/Seal/Core/MessageSource.hs`. Register in
  `exposed-modules` (alphabetical: `Seal.Core.ChannelKind`,
  `Seal.Core.MessageSource`, `Seal.Core.Paging`, `Seal.Core.Types`).
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(core): MessageSource + ConversationId + UserId smart constructors`

---

## T2 — `Seal.Core.AllowList` extraction + `Seal.Security.Policy` re-export

**Why:** `AllowList` is currently a constructor family inside
`Seal.Security.Policy`, but the cross-channel layer (sender allow-listing in
Signal, opcode-exposure gating later) needs it without pulling in the whole
security policy. Extracting it to `Seal.Core.AllowList` lets `Seal.Channels.*`
and `Seal.Core.MessageSource`-adjacent code depend on the leaf, while
`Seal.Security.Policy` re-exports it so existing call sites
(`Seal.Agent.Def.Types`, `Seal.ISA.Ops.Agent`, `Seal.Agent.Def.Backend`) keep
compiling unchanged.

**Module:** `src/Seal/Core/AllowList.hs`

### Design

```haskell
module Seal.Core.AllowList
  ( AllowList(..)
  , isAllowed
  , allowListWarning
  ) where

data AllowList a = AllowAll | AllowOnly (Set a)
  deriving stock (Eq, Show)

isAllowed :: Ord a => a -> AllowList a -> Bool
isAllowed _ AllowAll      = True
isAllowed x (AllowOnly s) = x `Set.member` s

-- | A human-readable warning string for a rejected element, or 'Nothing' if
-- allowed. Used by channel ingress to log a dropped sender without crashing.
allowListWarning :: a -> AllowList a -> Maybe Text  -- see note
```

`allowListWarning` returns `Just "<x> is not on the allow-list"` when the
element is rejected and `Nothing` when allowed. The `a` must be rendered to
`Text`; for non-`Text` `a` the caller pre-renders. To keep the leaf
dependency-free, the signature takes the already-rendered `Text` of the
element:

```haskell
allowListWarning :: Text -> Bool -> Maybe Text
-- ^ Given the rendered element and whether it was allowed, return a warning
-- or Nothing. (Keeps the leaf generic; the caller knows how to render `a`.)
```

Actually — simpler: keep `isAllowed` as the predicate, and let the caller
format the warning. Drop `allowListWarning` from the leaf; it is a one-liner
the caller writes. **Decision: ship `AllowList(..)` + `isAllowed` only.** The
warning string is the caller's concern (Signal will format its own).

### Migration

- Move `data AllowList a = AllowAll | AllowOnly (Set a)` from
  `Seal.Security.Policy` to `Seal.Core.AllowList`.
- `Seal.Security.Policy` adds `import Seal.Core.AllowList (AllowList(..))`
  and **re-exports** it (`module Seal.Security.Policy (..., AllowList(..), ...)`),
  so every existing `import Seal.Security.Policy (AllowList(..))` keeps
  working. (Confirmed call sites: `Seal.Agent.Def.Types`,
  `Seal.ISA.Ops.Agent`, `Seal.Agent.Def.Backend` — all import from
  `Seal.Security.Policy`; none need to change.)
- Add `isAllowed` (the leaf version, `Ord a => a -> AllowList a -> Bool`).
  Note: `Seal.Security.Policy` already has `isCommandAllowed` (specialized to
  `CommandName` over `SecurityPolicy`); leave it — it is a different
  function. The leaf `isAllowed` is the generic one the channel layer uses.

### TDD steps

- [ ] **Red.** Write `test/Seal/Core/AllowListSpec.hs`:
  - `isAllowed x AllowAll == True`.
  - `isAllowed x (AllowOnly (Set.fromList [x])) == True`;
    `isAllowed y (AllowOnly (Set.fromList [x])) == False`.
  - QuickCheck: `AllowOnly s` never admits an element not in `s`;
    `AllowAll` admits everything.
  - QuickCheck: for any finite `Set a`, `isAllowed x (AllowOnly s)` ==
    `Set.member x s`.
- [ ] **Red-verify.** Fails (module missing).
- [ ] **Green.** Create `src/Seal/Core/AllowList.hs`; edit
  `Seal.Security.Policy` to import + re-export. Register
  `Seal.Core.AllowList` in `exposed-modules` (alphabetical: after
  `Seal.Core.ChannelKind`, before `Seal.Core.MessageSource`).
- [ ] **Green-verify.** Build + the **full** test suite green (the
  re-export must not break `Seal.Security.PolicySpec`,
  `Seal.Agent.Def.TypesSpec`, `Seal.ISA.Ops.AgentSpec`,
  `Seal.Agent.Def.BackendSpec`). hlint clean.
- [ ] **Commit.** `refactor(core): extract AllowList to Seal.Core.AllowList; Policy re-exports`

---

## T3 — `Seal.Handles.Channel` (widened capability record)

**Why:** the current `Seal.Channel.Caps.ChannelCaps` is a 3-field record
(send/prompt/promptSecret) shaped for the interactive CLI TUI only. The
reference's channels need more: `sendError`, `sendChunk` (streaming chunks),
a `streaming` flag, `readSecret`, `receive` (pull from an inbox). The widened
handle is the target Phase 2b (Signal) and Phase 7 (Web) implement. The CLI
TUI keeps its existing `ChannelCaps` — the two coexist; a later phase may
unify them.

**Module:** `src/Seal/Handles/Channel.hs`

### Design

```haskell
module Seal.Handles.Channel
  ( ChannelHandle(..)
  , ChannelError(..)
  , Deferral(..)  -- see note
  ) where

-- | A structured deferral for interactive ops on request/response channels
-- (Signal, the future unified CLI). The web channel is async-only and never
-- returns a 'Deferred' — it returns 'AsyncQueued'. Kept simple in 2a: the
-- payload is just a marker the caller can match; 2b fills in the real shape
-- (a continuation id + a timeout).
data Deferral = Deferred | AsyncQueued
  deriving stock (Eq, Show)

-- | The widened channel capability record. Every field is an IO action so the
-- type is uniform between real and fake variants (house style: no type class;
-- callers receive the handle and call fields directly).
data ChannelHandle = ChannelHandle
  { chSend        :: Text -> IO ()
  -- ^ Emit one line to the user.
  , chSendError   :: Text -> IO ()
  -- ^ Emit an error line (may be formatted differently on some channels).
  , chSendChunk   :: Text -> IO ()
  -- ^ Emit one streaming chunk (for tool output / long replies). Channels
  -- that do not stream may batch and call 'chSend' once.
  , chPrompt      :: Text -> IO (Either Deferral Text)
  -- ^ Visible prompt; returns 'Right' the typed line on interactive channels,
  -- 'Left Deferred' on channels that cannot answer inline (the caller must
  -- wait for a follow-on message), 'Left AsyncQueued' on async channels.
  , chPromptSecret :: Text -> IO (Either Deferral Text)
  -- ^ Hidden (no-echo) prompt; same return shape as 'chPrompt'.
  , chStreaming   :: Bool
  -- ^ Whether this channel benefits from streaming (web: yes; Signal: yes,
  -- chunked; CLI TUI: yes, line-by-line).
  , chReadSecret  :: IO (Maybe Text)
  -- ^ Pull a secret the channel itself holds (e.g. a pairing token). 'Nothing'
  -- on channels with no channel-held secret. NOT a vault accessor — the vault
  -- is reached via the vault handle, not the channel.
  , chReceive     :: IO (Maybe MessageSource, Text)
  -- ^ Pull the next inbound message from the channel's inbox, with its
  -- authenticated 'MessageSource'. Blocks until a message is available (or
  -- returns immediately if the channel is driven externally — see 2b).
  }
```

**Note on `chReceive`:** in 2a the shape is settled but no real channel
implements it yet (the `FakeChannel` test instance does). The Signal channel
(2b) will back this with a `TQueue SignalEnvelope`. The web channel (Phase 7)
will back it with a per-WS-connection inbox. The CLI TUI (which currently
blocks on `getInputLine`) is *not* migrated to `chReceive` in 2a — it keeps
its `ccPrompt`-driven loop.

**Note on `MessageSource` in the signature:** `chReceive` returns a
`MessageSource`, so `Seal.Handles.Channel` imports `Seal.Core.MessageSource`.
That is the only dependency outside `Seal.Handles` — keep it that way (the
handle is a leaf above the core types).

### TDD steps

- [ ] **Red.** Write `test/Seal/Handles/ChannelSpec.hs`:
  - Construct a `FakeChannel`-backed `ChannelHandle` (the test helper from
    T4, or a minimal inline one if T4 isn't done yet — but T4 is the class,
    so do them together; see T4).
  - Assert `chSend`/`chSendError`/`chSendChunk` append to a captured list.
  - Assert `chPrompt "x"` returns `Right "y"` when the fake is scripted.
  - Assert `chStreaming` is the configured flag.
  - Assert `chReceive` returns the next scripted `(MessageSource, Text)`.
- [ ] **Red-verify.** Fails (module missing).
- [ ] **Green.** Implement `src/Seal/Handles/Channel.hs`. Register in
  `exposed-modules` (alphabetical: `Seal.Handles.Channel` before
  `Seal.Handles.Transcript`).
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(handles): widened ChannelHandle capability record`

---

## T4 — `Seal.Channels.Class` + `FakeChannel` test instance

**Why:** the `Channel` type class is the seam a channel implements to be
wired into `Seal.Ingest` — `toHandle :: Channel h => h -> ChannelHandle`,
mirroring the reference. The CLI TUI is *not* made an instance in 2a (it
keeps its direct path); `FakeChannel` is the first instance, used by the
capstone and by future test suites.

**Module:** `src/Seal/Channels/Class.hs` (the class) +
`test/Seal/TestHelpers/FakeChannel.hs` (the test instance, in the test tree
so it never ships in the library).

### Design

```haskell
module Seal.Channels.Class
  ( Channel(..)
  ) where

class Channel h where
  toHandle :: h -> ChannelHandle
```

A minimal class — one method. The reference has more (a `channelKind`
method), but in this repo `ChannelKind` is carried by the `MessageSource`
the channel's `chReceive` yields, so the class itself does not need it. Keep
it minimal; widen only when a real consumer demands it.

`FakeChannel` (test helper):

```haskell
-- test/Seal/TestHelpers/FakeChannel.hs
data FakeChannel = FakeChannel
  { fcSent      :: IORef [Text]        -- captured sends, in order
  , fcErrors    :: IORef [Text]
  , fcChunks    :: IORef [Text]
  , fcPromptSrc :: IORef [Text]        -- scripted prompt responses
  , fcInbox     :: IORef [(MessageSource, Text)]  -- scripted inbound
  , fcStreaming :: Bool
  }

instance Channel FakeChannel where
  toHandle fc = ChannelHandle
    { chSend        = \t -> modifyIORef' (fcSent fc) (t :)
    , chSendError   = \t -> modifyIORef' (fcErrors fc) (t :)
    , chSendChunk   = \t -> modifyIORef' (fcChunks fc) (t :)
    , chPrompt      = \_ -> popPrompt fc
    , chPromptSecret = \_ -> popPrompt fc
    , chStreaming   = fcStreaming fc
    , chReadSecret  = pure Nothing
    , chReceive     = popInbox fc
    }
```

(`popPrompt`/`popInbox` return `Right`/`Right` (Just) from the scripted
lists, or `Left AsyncQueued`/`(Nothing, "")` when empty — the capstone
scripts them non-empty.)

### TDD steps

- [ ] **Red.** Write `test/Seal/Channels/ClassSpec.hs`:
  - `toHandle (fakeChannel ...)` produces a `ChannelHandle` whose
    `chStreaming` matches the config.
  - Driving `chSend "hi"` then reading `fcSent` yields `["hi"]`.
  - `chReceive` on a scripted inbox yields the first `(MessageSource, Text)`.
  - `chPrompt` on a scripted prompt list yields `Right` the first response.
- [ ] **Red-verify.** Fails (modules missing).
- [ ] **Green.** Implement `src/Seal/Channels/Class.hs` +
  `test/Seal/TestHelpers/FakeChannel.hs`. Register `Seal.Channels.Class` in
  `exposed-modules`; register `Seal.TestHelpers.FakeChannel` in the test
  suite's `other-modules` (alongside the existing `Seal.TestHelpers.FakeCaps`).
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(channels): Channel class + FakeChannel test instance`

---

## T5 — `Seal.Phase2aSpec` capstone

**Why:** the proof that the new types + the widened handle + the class wire
together end-to-end through `Seal.Ingest`. This is the 2a milestone gate: a
`FakeChannel` driven through `ingest` carries the right `ChannelKind`/
`ConversationId`, a slash command dispatches, and a plain message routes as
`PlainMessage`.

**Module:** `test/Seal/Phase2aSpec.hs`

### Design

The capstone does **not** thread `MessageSource` into the agent loop (that
is 2b). It exercises the *ingress* seam:

1. Build a `FakeChannel` with a scripted inbox:
   `[(ms, "/ping"), (ms, "hello")]` where `ms = mkMessageSource (mkConversationId "sig:+15551234567") Signal (Just (mkUserId "+15551234567")) mempty`.
2. Get its `ChannelHandle` via `toHandle`.
3. Pull two messages via `chReceive`.
4. For each, run `ingest registry emptyChain (RawInbound text)`.
5. Assert:
   - The `/ping` message yields `DispatchAction` (assuming `/ping` is in the
     test registry — register a trivial `/ping` spec for the capstone, or
     use an existing command; the existing `Seal.IngestSpec` pattern shows
     how to build a minimal registry).
   - The `hello` message yields `PlainMessage "hello"`.
   - The `MessageSource` carried `ChannelKind = Signal` and
     `ConversationId = "sig:+15551234567"` (asserted directly on the `ms`
     we scripted, proving the type threads through `chReceive` unchanged).
6. Assert `chSend` captured the expected outputs (the `/ping` action's
   reply + the plain message's would-be agent reply — but since the
   capstone does NOT call the agent loop, the plain message just asserts
   `PlainMessage` and stops; the slash command's `CommandAction` runs
   against the `ChannelHandle`'s `chSend` via an adapter).

### Adapter note

`Seal.Command.Spec.CommandAction` runs against `ChannelCaps`, not
`ChannelHandle`. In 2a we do **not** unify them. The capstone builds a
throwaway `ChannelCaps` from the `ChannelHandle` (send/prompt/promptSecret
forwarded) for the slash-command dispatch only. This is intentional: the
widened handle is the future, but the command registry still speaks
`ChannelCaps` today, and 2a does not change that. (A later phase widens
`CommandAction` to take `ChannelHandle`; not now.)

### TDD steps

- [ ] **Red.** Write `test/Seal/Phase2aSpec.hs` with the scenario above.
  Use the existing `Seal.IngestSpec` as a template for the minimal registry
  + the `/ping` spec.
- [ ] **Red-verify.** Fails (some wiring missing — likely the
  `ChannelCaps`-from-`ChannelHandle` adapter, which is test-local).
- [ ] **Green.** Make it pass. If the adapter needs to live in the test
  helper, put it in `test/Seal/TestHelpers/FakeChannel.hs`. No library
  change expected.
- [ ] **Green-verify.** `cabal test --match "Phase 2a capstone"` green;
  full suite green; hlint clean.
- [ ] **Commit.** `test(phase2a): capstone — FakeChannel through Ingest, MessageSource threads`

---

## Milestone (2a)

**Definition of Done (whole sub-phase):**

- [ ] `cabal build all` is `-Werror` clean (Nix dev shell).
- [ ] `cabal test` green including the new QuickCheck properties and the
      `Seal.Phase2aSpec` capstone.
- [ ] `hlint src/ test/` clean.
- [ ] The cross-channel types (`ChannelKind`, `MessageSource`,
      `ConversationId`, `UserId`, `AllowList`) compile and their
      invariant/round-trip QuickCheck properties are green.
- [ ] `Seal.Handles.Channel` and `Seal.Channels.Class` compile and are
      exercised by a no-op `FakeChannel` instance in tests.
- [ ] **No runtime behavior change** — the CLI TUI (`seal tui`) still works
      exactly as before. The existing `Seal.Channel.Caps.ChannelCaps` is
      unchanged; `Seal.Channel.Cli` is unchanged; the `Seal.Security.Policy`
      re-export of `AllowList` keeps every existing call site compiling.
- [ ] All five tasks committed (one commit per task).

**Next:** write `docs/superpowers/plans/2026-07-xx-phase-2b-signal-channel.md`
before starting 2b.
