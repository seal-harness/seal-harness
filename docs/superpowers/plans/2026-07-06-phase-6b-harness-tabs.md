# Phase 6b — Tabs-as-view (the text-based tab UI): Plan

> **For agentic workers:** Implement task-by-task, top to bottom. Each task is
> TDD (red → green → commit). Steps use checkbox (`- [ ]`) syntax. Do not start
> a task until the previous task's gate is green (`cabal build all` `-Werror`
> clean, `cabal test` green, `hlint src/ test/` clean, all in the Nix dev shell).
> One commit per task.

**Goal:** The tabs-as-view layer — a pure `TabList` enforcing the I1/I2/I3
invariants by construction, the Layer-1 terse `/N` routing grammar, the
`/tab` command family, per-conversation output relay, and the `/help`-
discoverable synopsis — registered into the existing `/`-command registry
so **both** the CLI TUI and the Signal channel gain `/tabs` and `/tab`
driving. The harness backend (Phase 6a) is the ground truth a tab's
`BoundHarness HarnessId` resolves through. No source is copied; behavior
closely matches the reference.

**Parent roadmap:**
`docs/superpowers/plans/2026-06-28-seal-harness-roadmap.md` § Phase 6 (6b).

**Why this sub-phase:** the reference's central interaction model is "tabs
as a view over ground truth" — a tab binds to a live session *or* a harness,
the terse `/N` grammar switches focus, and per-conversation relay routes
output. This is the text-based tab UI the user wants, over both the CLI TUI
and Signal. The web frontend (Phase 7) then renders the same tab model
graphically.

## Tech Stack

Haskell (GHC2021), Cabal, Nix dev shell. No new deps — uses the existing
`stm`, `aeson`, `text`, `containers`, `QuickCheck`. Build/test via
`nix develop --command cabal build all`, `… cabal test`, `… hlint src/ test/`.

## Global Constraints

Inherited from the roadmap verbatim where the spec is exact:

- **Module namespace:** all library code under `Seal.*`. New modules:
  `Seal.Handles.Tab`, `Seal.Tabs.Types`, `Seal.Routing.Route`,
  `Seal.Tabs` (the registry handle), `Seal.Tabs.Relay`, `Seal.Tabs.Wizard`,
  `Seal.Tabs.Persist`, `Seal.Tabs.Runtimes`, `Seal.Command.Tab` (the
  `/tab` + `/tabs` command specs).
- **Coding style:** GHC2021; conservative always-on `default-extensions`;
  per-file `OverloadedStrings` / `ImportQualifiedPost`. Whole-module imports;
  post-positive qualified imports.
- **Errors:** `Either Text` / `ExceptT Text` default. No bespoke error ADT
  expected in 6b — the pure constructors return `Either Text`.
- **GHC flags:** `-Wall -Werror` plus the strict set.
- **TDD:** red → green → commit. The pure `TabList` + the routing grammar get
  **heavy QuickCheck** on the I1/I2/I3 invariants + the grammar round-trips.
  The IO-bound registry/relay/wizard are tested via a no-op handle.
- **hlint clean** before each commit.
- **Type-guaranteed identifiers.** `TabIndex` is a smart-constructed newtype
  (`0..35`, `mkTabIndex`) — the single index type reused everywhere. A
  `TabRef` (`BoundSession SessionId` | `BoundHarness HarnessId`) names ground
  truth, not a slot, so a cursor (I3) survives compaction.
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

## Non-goals (explicitly out of scope for 6b)

- **No web frontend / WS broker.** Phase 7. The tab model 6b builds is what
  Phase 7 renders graphically.
- **No Telegram channel.** Phase 8.
- **No `PLAN_MODE` opcode.** The roadmap lists it under the Harnesses group;
  it's a tab-UX concern that's deferred to a follow-up (it's not on the 6b
  critical path — the `/tab` family + relay + wiring is).
- **No tab persistence across restart.** `Seal.Tabs.Persist` is a stub in 6b
  (the `TabList` is in-memory; persistence + re-resolve-at-boot is a follow-up
  that needs the session store). The module ships so the wiring compiles,
  but the body is `pure ()`-shaped.
- **No per-tab runtime execution.** `Seal.Tabs.Runtimes` is a stub in 6b
  (the per-tab runtime — a session tab runs the agent loop, a harness tab
  drives the harness handle — is the 7a gateway's job; 6b delivers the *view*
  + the *commands*, not the live per-tab execution). The module ships so the
  wiring compiles.
- **No `seal harness` subcommand.** The harness lifecycle is driven via the
  ISA opcodes (Phase 6a) + the `/tab new harness` command (6b). A dedicated
  `seal harness` CLI subcommand is a follow-up (it's a thin wrapper over the
  opcodes + the registry, not on the 6b critical path).
- **No CLI TUI unification.** `Seal.Channel.Cli` keeps its direct
  `interpretDisposition` path; 6b adds a read-only `TabsHandle` accessor to
  it so `/tabs` and `/tab` work, but the CLI is not unified into
  `ChannelKind` routing (that's Phase 8).

---

## Task map

| Task | Title | Gate |
|---|---|---|
| **T0** | `Seal.Handles.Tab` — `TabIndex` + `TabKind` | `cabal test` green; `mkTabIndex` + QuickCheck (0..35, rejects 36+) |
| **T1** | `Seal.Tabs.Types` — `TabRef`/`Tab`/`TabList` (I1/I2/I3) + `ConversationKey`/`RelayMode`/`CursorState` + `/tab` ADTs | `cabal test` green; heavy QuickCheck on I1/I2/I3 |
| **T2** | `Seal.Routing.Route` — the terse `/N` grammar | `cabal test` green; grammar round-trip + QuickCheck (no `/N` ever routes to plain; `/N payload` injects) |
| **T3** | `Seal.Tabs` (the registry handle) + `Seal.Tabs.Relay` | `cabal test` green; registry mutates TabList; relay focused/background/breadcrumb |
| **T4** | `Seal.Tabs.Wizard` (the `/tab` attach-wizard state machine) | `cabal test` green; wizard snapshots harnesses+sessions, numbers them, 0 cancels, `/`-prefixed reply cancels+runs |
| **T5** | `Seal.Command.Tab` — the `/tab` + `/tabs` command specs + registration into `/help` | `cabal test` green; `/help` shows the tab family + the terse grammar synopsis |
| **T6** | `Seal.Tabs.Persist` + `Seal.Tabs.Runtimes` stubs + CLI/Signal wiring (the read-only `TabsHandle` accessor) | `cabal build all` green; `seal tui` + `seal signal` compile with the tab handle; `/tabs` works in both |
| **T7** | `Seal.Phase6bSpec` capstone | `cabal test` green; the full I1/I2/I3 + relay scenario over a FakeChannel |

---

## T0 — `Seal.Handles.Tab` — `TabIndex` + `TabKind`

**Why:** `TabIndex` is the single validated index type (`0..35`) reused
everywhere — in `TabList` slots, in `/N` routing, in `/tab close <N>`, in
`/tab focus <N>`. Smart-constructed so an out-of-range index fails to
compile into any path. `TabKind` is the closed enumeration (the kinds a tab
can be).

**Module:** `src/Seal/Handles/Tab.hs`

### Design

```haskell
-- | A validated tab index: 0..35 (the terse grammar maps 0-9a-z to 0..35).
-- Smart-constructed; the predicate rejects <0 and >35.
newtype TabIndex = TabIndex Int
  deriving stock (Eq, Ord, Show)

mkTabIndex :: Int -> Either Text TabIndex
tabIndexToInt :: TabIndex -> Int
tabIndexToChar :: TabIndex -> Char   -- 0->'0', 9->'9', 10->'a', 35->'z'
tabIndexFromChar :: Char -> Either Text TabIndex  -- inverse, case-insensitive

maxTabIndex :: Int
maxTabIndex = 35

data TabKind = KindAi | KindProvider | KindHarness | KindShell | KindSsh | KindTmux
  deriving stock (Eq, Show, Enum, Bounded, Generic)
  deriving anyclass (ToJSON, FromJSON)
```

### TDD steps

- [ ] **Red.** Write `test/Seal/Handles/TabSpec.hs`:
  - `mkTabIndex 0` → Right; `mkTabIndex 35` → Right; `mkTabIndex 36` → Left;
    `mkTabIndex (-1)` → Left.
  - `tabIndexToChar (mk 0)` == '0'; `tabIndexToChar (mk 9)` == '9';
    `tabIndexToChar (mk 10)` == 'a'; `tabIndexToChar (mk 35)` == 'z'.
  - `tabIndexFromChar '0'` == Right (mk 0); `tabIndexFromChar 'Z'` == Right (mk 35) (case-insensitive); `tabIndexFromChar '!'` → Left.
  - QuickCheck: for `n in 0..35`, `tabIndexFromChar (tabIndexToChar (mk n)) == Right (mk n)`.
- [ ] **Red-verify.** Fails (module missing).
- [ ] **Green.** Implement `src/Seal/Handles/Tab.hs`. Register in
  `exposed-modules` (alphabetical: `Seal.Handles.Channel` before
  `Seal.Handles.Harness` before `Seal.Handles.Tab` before
  `Seal.Handles.Transcript`).
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(tabs): TabIndex + TabKind`

---

## T1 — `Seal.Tabs.Types` — `TabRef`/`Tab`/`TabList` (I1/I2/I3) + routing + `/tab` ADTs

**Why:** the pure `TabList` is the crown jewel — I1 (contiguous slots,
removal compacts tmux-window style), I2 (no two tabs share a `TabRef`), and
I3 (a cursor keys by `TabRef` not slot, so it survives compaction) are all
enforced **by construction** (the smart constructors reject violations).
Heavy QuickCheck proves the invariants hold for any sequence of inserts/
removes. Plus the per-conversation routing types and the parsed `/tab`
command ADTs.

**Module:** `src/Seal/Tabs/Types.hs`

### Design

```haskell
-- | A tab's reference to ground truth: a live session OR a harness.
data TabRef = BoundSession SessionId | BoundHarness HarnessId
  deriving stock (Eq, Show)

data TabStatus = Live | Dead
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Tab = Tab
  { tIndex  :: TabIndex
  , tRef    :: TabRef
  , tKind   :: TabKind
  , tLabel  :: Maybe Text     -- ^ optional user-set label
  , tStatus :: TabStatus
  } deriving stock (Eq, Show)

-- | The per-conversation routing key: ChannelKind × ConversationId.
data ConversationKey = ConversationKey ChannelKind ConversationId
  deriving stock (Eq, Ord, Show)

-- | How a conversation receives a tab's output.
data RelayMode = FocusedOnly | ActivityDigest | Firehose
  deriving stock (Eq, Show)

-- | A conversation's cursor + relay mode. The cursor keys by TabRef (I3):
-- it names ground truth, resolved to a current slot at read time.
data CursorState = CursorState
  { csFocused   :: TabRef           -- ^ which tab this conversation is focused on
  , csRelayMode :: RelayMode
  } deriving stock (Eq, Show)

-- | The tab list. I1 (contiguous 0..n-1, removal compacts) + I2 (no two tabs
-- share a TabRef) are enforced by the smart constructors. Hard 36-slot cap.
newtype TabList = TabList { tlTabs :: [Tab] }
  deriving stock (Eq, Show)

-- | Construct an empty TabList.
emptyTabList :: TabList

-- | The number of tabs (also the next free slot under I1).
tabCount :: TabList -> Int

-- | Insert a tab at the lowest free slot (I1). 'Left' if the TabRef is
-- already present (I2) or the list is full (36).
insertTab :: TabRef -> TabKind -> Maybe Text -> TabList -> Either Text TabList

-- | Look up a tab by index. 'Nothing' if the index is out of range.
lookupTab :: TabList -> TabIndex -> Maybe Tab

-- | Look up a tab by its TabRef. 'Nothing' if absent.
lookupByRef :: TabList -> TabRef -> Maybe Tab

-- | Remove a tab by index. Compacts the list (I1: slots renumber to 0..n-1).
-- 'Left' if the index is out of range.
removeTab :: TabList -> TabIndex -> Either Text TabList

-- | Rename a tab (set its label). 'Left' if the index is out of range.
renameTab :: TabList -> TabIndex -> Text -> Either Text TabList

-- | The current slot of a TabRef (I3: resolved at read time). 'Nothing' if
-- the ref is no longer in the list (the cursor is stale).
slotOf :: TabList -> TabRef -> Maybe TabIndex

-- | The parsed /tab command ADTs.
data TabKindArg = TkaAi | TkaProvider | TkaHarness | TkaShell | TkaSsh | TkaTmux
  deriving stock (Eq, Show)

data ForceMode = Force | NoForce
  deriving stock (Eq, Show)

data TabSlashCommand
  = TabNewCmd (Maybe TabKindArg)
  | TabListCmd
  | TabCloseCmd TabIndex ForceMode
  | TabFocusCmd TabIndex
  | TabResumeCmd SessionId
  | TabRenameCmd TabIndex Text
  deriving stock (Eq, Show)
```

### Invariants (QuickCheck — heavy)

- **I1 (contiguity):** for any `TabList` built via `insertTab`/`removeTab`,
  the indices are exactly `0..n-1` (no gaps). `tabCount tl == length (tlTabs tl)`.
- **I1 (compaction):** `removeTab tl i` (valid i) yields a list whose indices
  are `0..n-2`.
- **I2 (no duplicate refs):** `insertTab ref k l tl` is `Left` iff `ref` is
  already in `tlTabs tl`. The list never contains two tabs with the same
  `TabRef`.
- **I2 (preserved by remove):** `removeTab` never introduces a duplicate.
- **I3 (cursor survives compaction):** if `slotOf tl ref == Just i`, and
  `removeTab tl j` succeeds with `j < i`, then
  `slotOf (removeTab tl j) ref == Just (i-1)`. The cursor names ground truth
  (the `TabRef`), not a slot.
- **36-slot cap:** `insertTab` fails after 36 tabs.
- **Round-trip:** `lookupTab tl (tIndex t) == Just t` for every tab `t` in `tl`.

### TDD steps

- [ ] **Red.** Write `test/Seal/Tabs/TypesSpec.hs` with the explicit cases +
  the QuickCheck invariants above. Use generators for `TabRef` (a small set
  of `SessionId`/`HarnessId` values) + a sequence-of-operations generator
  (`insertTab`/`removeTab`/`renameTab`).
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement `src/Seal/Tabs/Types.hs`. Register in
  `exposed-modules` (after `Seal.Tui`? no — `Seal.Tabs.*` sorts before
  `Seal.Text.*`; place under `Seal.Tabs.Types`).
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(tabs): TabList with I1/I2/I3 invariants + routing types`

---

## T2 — `Seal.Routing.Route` — the terse `/N` grammar

**Why:** the Layer-1 terse-grammar routing front-end. `/N` switches focus
to tab N, `/N payload` injects into tab N, a bare `/tab …` parses to the
`TabSlashCommand` family, anything else is plain text to the focused tab.
This is the user-facing UX crown jewel — one-thumb `/N` switching. The
grammar is a first-class synopsis entry in `/help` so it's discoverable.

**Module:** `src/Seal/Routing/Route.hs`

### Design

```haskell
data ParseError = ParseError Text
  deriving stock (Eq, Show)

data RoutingDecision
  = Focus TabIndex                 -- ^ /N
  | Inject TabIndex Text           -- ^ /N payload
  | Plain Text                     -- ^ plain text to the focused tab
  | TabCommand TabSlashCommand     -- ^ /tab …
  | SlashCommand Text              -- ^ other /commands (deferred to the registry)
  deriving stock (Eq, Show)

-- | Route one inbound line. The Layer-1 terse grammar:
--
-- * @\/N@          -> 'Focus' N
-- * @\/N payload@  -> 'Inject' N payload
-- * @\/tab …@      -> 'TabCommand' (parsed via the /tab command ADT)
-- * @\/<other>…@   -> 'SlashCommand' (deferred to the registry)
-- * anything else  -> 'Plain'
--
-- A @\/@ followed by an out-of-range index (e.g. @\/36@) is a 'ParseError'
-- (not a SlashCommand) so the user gets a clear "no tab 36" message.
route :: Text -> Either ParseError RoutingDecision

-- | The terse-grammar synopsis (for /help). One line, e.g.
-- @\/N [payload]  Switch to tab N (0-9a-z), or inject payload into it@
terseSynopsis :: Text
```

### Grammar rules (exact)

- `/0` → `Focus (mkTabIndex 0)`. `/z` → `Focus (mkTabIndex 35)`.
- `/1 hello` → `Inject (mkTabIndex 1) "hello"`.
- `/tab` → `TabCommand TabListCmd`. `/tab new` → `TabCommand (TabNewCmd Nothing)`.
  `/tab new harness` → `TabCommand (TabNewCmd (Just TkaHarness))`.
  `/tab close 2` → `TabCommand (TabCloseCmd (mkTabIndex 2) NoForce)`.
  `/tab close 2 --force` → `TabCommand (TabCloseCmd (mkTabIndex 2) Force)`.
  `/tab focus 3` → `TabCommand (TabFocusCmd (mkTabIndex 3))`.
  `/tab resume 2026-07-01-120000-001` → `TabCommand (TabResumeCmd ...)`.
  `/tab rename 1 work` → `TabCommand (TabRenameCmd (mkTabIndex 1) "work")`.
- `/help` → `SlashCommand "help"` (deferred).
- `/ping` → `SlashCommand "ping"` (deferred).
- `/36` → `ParseError` (out of range).
- `hello` → `Plain "hello"`.
- `` (empty) → `Plain ""`.

### TDD steps

- [ ] **Red.** Write `test/Seal/Routing/RouteSpec.hs` with the explicit cases
  above + QuickCheck:
  - For `c in 0-9a-z`, `route ("/" <> singleton c) == Right (Focus (mk c))`.
  - For `c in 0-9a-z` + non-empty payload, `route ("/" <> c <> " " <> payload) == Right (Inject (mk c) payload)`.
  - `route` of plain text (no leading `/`) is always `Right (Plain t)`.
  - `/N` never routes to `Plain` or `SlashCommand`.
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement `src/Seal/Routing/Route.hs`. Register in
  `exposed-modules` (`Seal.Routing.Route`).
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(routing): terse /N grammar + /tab command parsing`

---

## T3 — `Seal.Tabs` (the registry handle) + `Seal.Tabs.Relay`

**Why:** the thin `TVar`/`IORef` handle that mutates a `TabList` (the live
state a tab command reads/writes), and the streaming-aware per-conversation
output relay. The relay: focused conversations receive every
`StreamStart`/`ChunkOf`/`StreamEnd` verbatim; background `ActivityDigest`
conversations get at most one breadcrumb ping per burst; `Firehose` forwards
everything.

**Modules:** `src/Seal/Tabs.hs` (the handle), `src/Seal/Tabs/Relay.hs`

### Design

```haskell
-- Seal.Tabs
newtype TabsHandle = TabsHandle (TVar TabList)

newTabsHandle :: IO TabsHandle
snapshotTabs :: TabsHandle -> IO TabList
-- | Insert a tab at the lowest free slot. 'Left' (I2/I2/full).
insertTabH :: TabsHandle -> TabRef -> TabKind -> Maybe Text -> IO (Either Text TabIndex)
-- | Remove a tab (compacts; I1). 'Left' if out of range.
removeTabH :: TabsHandle -> TabIndex -> IO (Either Text ())
-- | Rename a tab.
renameTabH :: TabsHandle -> TabIndex -> Text -> IO (Either Text ())
-- | Focus a tab (validates the index is in range).
focusTabH :: TabsHandle -> TabIndex -> IO (Either Text ())

-- Seal.Tabs.Relay
-- | One streaming event to relay.
data RelayEvent
  = StreamStart Text     -- ^ a stream began (carries a header/breadcrumb)
  | ChunkOf Text          -- ^ one chunk
  | StreamEnd             -- ^ the stream ended
  deriving stock (Eq, Show)

-- | Relay one event to one conversation. Returns the lines to send to that
-- conversation (0, 1, or many). Pure.
relayEvent :: RelayMode -> RelayEvent -> [Text]

-- | A breadcrumb ping (for ActivityDigest background conversations): one
-- short line per burst. The caller tracks "has this conversation already
-- been pinged for this burst?" via 'StreamStart'/'StreamEnd' boundaries.
breadcrumb :: RelayEvent -> Maybe Text
```

### Relay semantics (exact)

- `FocusedOnly`: `StreamStart` → `[]` (no header); `ChunkOf t` → `[t]`;
  `StreamEnd` → `[]`. (The focused conversation sees the chunks verbatim,
  no framing.)
- `ActivityDigest`: `StreamStart` → `[]`; `ChunkOf t` → `[]` (suppress);
  `StreamEnd` → `[breadcrumb]` where the breadcrumb is a short ping like
  `"[tab] activity"`. So the background conversation gets at most one ping
  per burst.
- `Firehose`: every event → `[show event]` (forwards everything, including
  framing — the firehose consumer wants the structure).

### TDD steps

- [ ] **Red.** Write `test/Seal/TabsSpec.hs` + `test/Seal/Tabs/RelaySpec.hs`:
  - `insertTabH` then `snapshotTabs` reflects the insert; the returned index
    is the lowest free slot.
  - `removeTabH` compacts (I1): after remove, the snapshot's indices are
    `0..n-1`.
  - `insertTabH` with a duplicate `TabRef` is `Left` (I2).
  - `relayEvent FocusedOnly (ChunkOf "hi")` == `["hi"]`;
    `relayEvent FocusedOnly StreamEnd` == `[]`.
  - `relayEvent ActivityDigest (ChunkOf "hi")` == `[]`;
    `relayEvent ActivityDigest StreamEnd` `shouldSatisfy` (not . null).
  - `relayEvent Firehose (ChunkOf "hi")` == `["ChunkOf hi"]` (or similar show).
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement `src/Seal/Tabs.hs` + `src/Seal/Tabs/Relay.hs`.
  Register in `exposed-modules`.
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(tabs): TabsHandle registry + per-conversation relay`

---

## T4 — `Seal.Tabs.Wizard` — the `/tab` attach-wizard state machine

**Why:** the `/tab new harness` (or `/tab resume`) attach-wizard: snapshot
the running harnesses + recent sessions, number them `[1-9a-z]`, `0` cancels,
a `/`-prefixed reply cancels and runs that command instead. This is the
interactive attach UX — the user types `/tab new harness`, sees a numbered
list of running harnesses, picks one by number, and the wizard binds a tab
to it.

**Module:** `src/Seal/Tabs/Wizard.hs`

### Design

```haskell
-- | One attachable target (a running harness or a recent session).
data AttachTarget = AttachTarget
  { atLabel :: Text
  , atRef   :: TabRef
  } deriving stock (Eq, Show)

-- | The wizard state: a numbered list of targets + the pending tab kind.
data WizardState = WizardState
  { wsTargets :: [(TabIndex, AttachTarget)]  -- ^ numbered 1..n
  , wsKind    :: TabKind
  } deriving stock (Eq, Show)

-- | Build the wizard state from the running harnesses + recent sessions.
-- Numbers the targets 1..n (slot 0 is reserved for "cancel").
buildWizard :: TabKind -> [AttachTarget] -> WizardState

-- | Handle one reply. 'Right TabRef' = attach to this ref; 'Left Text' =
-- a status message (e.g. "cancelled"); a `/`-prefixed reply is parsed as a
-- slash command and returned via 'WizardSlash Text'.
data WizardReply
  = WizardAttach TabRef
  | WizardCancel
  | WizardSlash Text   -- ^ a /-prefixed reply: cancel + run this command
  deriving stock (Eq, Show)

handleReply :: WizardState -> Text -> Either Text WizardReply
```

### TDD steps

- [ ] **Red.** Write `test/Seal/Tabs/WizardSpec.hs`:
  - `buildWizard` numbers targets 1..n (skipping 0).
  - `handleReply ws "0"` → `Right WizardCancel`.
  - `handleReply ws "1"` (with target at slot 1) → `Right (WizardAttach ref)`.
  - `handleReply ws "/ping"` → `Right (WizardSlash "ping")`.
  - `handleReply ws "99"` (out of range) → `Left "no such target"`.
  - `handleReply ws ""` → `Left "empty reply"`.
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement `src/Seal/Tabs/Wizard.hs`. Register.
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(tabs): /tab attach-wizard state machine`

---

## T5 — `Seal.Command.Tab` — the `/tab` + `/tabs` command specs + `/help` registration

**Why:** the tab family registered into the existing `/`-command registry:
`/tabs` (alias `/tab list`), `/tab new [<kind>]`, `/tab close <N> [--force]`,
`/tab focus <N>`, `/tab resume <session-id>`, `/tab rename <N> <name>`, plus
the terse `/N` routing as a synopsis entry. Proving the registry end-to-end
with the real tab entries — both the CLI TUI and Signal gain `/tabs` + `/tab`.

**Module:** `src/Seal/Command/Tab.hs`

### Design

```haskell
-- | The /tab command spec (one hsubparser with the subcommands).
tabCommandSpec :: TabsHandle -> CommandSpec

-- | The /tabs alias spec (an alias for /tab list).
tabsCommandSpec :: TabsHandle -> CommandSpec

-- | The terse-grammar synopsis entry for /help. Registered as a synthetic
-- spec so /help shows the /N grammar alongside the /tab family.
terseGrammarSpec :: CommandSpec
```

The `/tab` parser uses `optparse-applicative`'s `hsubparser` with the six
subcommands (`new`, `list`, `close`, `focus`, `resume`, `rename`), each
parsing to a `CommandAction` that mutates the `TabsHandle` and replies via
the channel's `ccSend`. The `/tabs` spec is a thin alias that runs the
`list` subcommand. The terse grammar is a synopsis-only entry (no parser —
it's handled by `Seal.Routing.Route` before the registry; the synopsis is
registered so `/help` shows it).

### TDD steps

- [ ] **Red.** Write `test/Seal/Command/TabSpec.hs`:
  - `/tab list` against a handle with 2 tabs → replies with the formatted list.
  - `/tab new` → inserts a tab at slot 0, replies with the new index.
  - `/tab close 0` → removes it, compacts.
  - `/tab focus 1` → focuses.
  - `/tab rename 0 work` → renames.
  - `/help` includes the terse grammar synopsis + the `/tab` entry.
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement `src/Seal/Command/Tab.hs`. Register in
  `exposed-modules`. (Wiring into the live registry is T6.)
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(tabs): /tab + /tabs command specs + /help synopsis`

---

## T6 — `Seal.Tabs.Persist` + `Seal.Tabs.Runtimes` stubs + CLI/Signal wiring

**Why:** the persistence + per-tab-runtime modules ship as stubs (out of
scope for 6b per the non-goals) so the wiring compiles. The CLI TUI + Signal
channels gain a read-only `TabsHandle` accessor + the tab commands
registered into their `/`-command registries. After T6, `seal tui` and
`seal signal` both support `/tabs` and `/tab`.

**Modules:** `src/Seal/Tabs/Persist.hs`, `src/Seal/Tabs/Runtimes.hs`,
wiring edits in `src/Seal/Channel/Cli.hs`, `src/Seal/Channels/Signal/Run.hs`,
`src/Seal/Tui.hs`.

### Design

```haskell
-- Seal.Tabs.Persist (stub — persistence is a follow-up)
saveTabList :: TabsHandle -> IO ()
loadTabList :: IO (Maybe TabList)
-- both are no-ops in 6b; ship so the wiring compiles.

-- Seal.Tabs.Runtimes (stub — per-tab runtime is the 7a gateway's job)
data TabRuntime = TabRuntime  -- stub
runSessionTab :: ... -> IO ()
runHarnessTab :: ... -> IO ()
-- both are no-ops in 6b.
```

### Wiring

- `Seal.Tui.runTui`: build a `TabsHandle` (via `newTabsHandle`), pass it to
  the `tabCommandSpec`/`tabsCommandSpec` + the `terseGrammarSpec`, add them
  to the `mkRegistry` list. Pass the `TabsHandle` to `runCliTui`.
- `Seal.Channel.Cli.runCliTui`: accept a `TabsHandle` arg; the `plainHandler`
  checks `Seal.Routing.Route.route` first — if `Focus`/`Inject`/`TabCommand`,
  mutate the handle + reply; if `SlashCommand`, defer to `ingest`; if `Plain`,
  run the agent loop (as before).
- `Seal.Channels.Signal.Run.runSignalMain`: same — build a `TabsHandle`,
  register the tab commands, pass the handle to `runSignalLoop`.

### TDD steps

- [ ] **Red.** Write `test/Seal/Channel/CliTabsSpec.hs`:
  - A `FakeChannel` + `TabsHandle` + a scripted `/tabs` then `/tab new`
    then `/1 hello` (inject) → the handle reflects the tab + the inject
    routes (the agent loop runs against the tab's session).
  - `/tab close 0` compacts; `/tab new` reuses slot 0 (I1).
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement the stubs + the wiring. Register the stub
  modules in `exposed-modules`.
- [ ] **Green-verify.** Build + the **full** suite green (the CLI/Signal
  wiring change must not break `WiringSpec`/`CliSpec`/`Phase5Spec`/
  `Phase2bSpec`). hlint clean.
- [ ] **Commit.** `feat(tabs): wire /tab + /tabs into CLI TUI + Signal; Persist/Runtimes stubs`

---

## T7 — `Seal.Phase6bSpec` capstone

**Why:** the 6b milestone gate. Drive a `FakeChannel` (CLI or Signal-flavored)
through `Seal.Ingest` + the tab routing: `/tab new` creates a tab at the
lowest free slot, `/1` switches focus, `/1 hello` injects into tab 1,
`/tab close 0` compacts the list (I1), `/tab new` reuses slot 0, a second
`/tab new` binding the same session is rejected (I2), a cursor survives a
`removeTab` compaction (I3). A harness tab's output relays to the focused
conversation verbatim and to a background conversation as one breadcrumb
per burst.

**Module:** `test/Seal/Phase6bSpec.hs`

### TDD steps

- [ ] **Red.** Write `test/Seal/Phase6bSpec.hs` with the full scenario above.
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Make it pass. No library change expected (T0–T6 did the
  work); if a helper is missing, add it.
- [ ] **Green-verify.** `cabal test --match "Phase 6b capstone"` green;
  full suite green; hlint clean.
- [ ] **Commit.** `test(phase6b): capstone — tabs over FakeChannel, I1/I2/I3 + relay`

---

## Milestone (6b)

**Definition of Done (whole sub-phase):**

- [ ] `cabal build all` is `-Werror` clean (Nix dev shell).
- [ ] `cabal test` green including the new QuickCheck properties and the
      `Seal.Phase6bSpec` capstone.
- [ ] `hlint src/ test/` clean.
- [ ] Over **both** the CLI TUI and the Signal channel, the user can
      `/tab new`, `/N` switch, `/N payload` inject, `/tab close`, `/tab
      resume`, `/tab rename`, and `/tabs` list — with the I1/I2/I3
      invariants preserved by construction, a cursor surviving slot
      compaction, and a harness tab's output relaying to the focused
      conversation verbatim and to background conversations per the
      configured `RelayMode`.
- [ ] The tab terse grammar is discoverable via `/help`.
- [ ] All seven tasks committed (one commit per task).
- [ ] **No runtime behavior regression** — the existing `seal tui` +
      `seal signal` channels still work (the tab commands are additive; the
      plain-text agent-loop path is unchanged when no `/N`/`/tab` is present).

**Next:** Phase 7 — Web frontend (close duplication). The gateway + WS
broker expose the existing tab/harness/session surface (now including the
6a/6b tab model), and the React SPA is a graphical view over the same
ground truth.