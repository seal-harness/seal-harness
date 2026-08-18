# Layered Harness Architecture: API-First Channel Design

> **Status:** Draft for brainstorming
> **Author:** Zoe (Chief of Staff) + Mighty
> **Date:** 2026-08-18
> **Problem:** Behavioral divergence between harness interaction surfaces (Web, TUI, Telegram, Signal)

---

## 1. The Problem

Seal Harness currently has **three independently-implemented turn paths** that each
reconstruct the same machinery from scratch:

| Path | File | Turn Function | ISA Registry Builder |
|------|------|---------------|---------------------|
| **Web** | `Gateway/Send.hs` | `plainTurn` / `plainTurnWithCaps` | `buildWebRegistry` |
| **Channels** | `Channels/Loop.hs` | `runTurnOnSession` | `buildIsaRegistry` |
| **CLI** | `Channel/Cli.hs` | `withCliTurn` / `handlePlain` | `cliIsaReg` (inline) |

Each path independently:
1. Loads session meta from disk
2. Resolves the provider + model from the vault
3. Opens a `withTwoFileTranscript` bracket
4. Loads config + security config
5. Builds `mkSessionExec` (local or remote)
6. Constructs workdir-aware skill + agent-def backends
7. Resolves the system prompt (with autoload + available-skills injection)
8. Builds the ISA registry (the opcode set)
9. Wires `AgentStartWiring` for AGENT_START delegation
10. Constructs `ChannelCaps` (medium-specific ask/reply)
11. Builds `AgentEnv` via `mkSessionAgentEnv`
12. Calls `runTurn` or `dispatch`
13. Broadcasts new transcript entries
14. Fans out replies to subscribed channels
15. Auto-tabs the session

The code comments explicitly acknowledge the problem: `buildIsaRegistry`
is documented as "Mirrors `Seal.Gateway.Send.buildWebRegistry` so channels
have the SAME tool set as the web and CLI paths." But they are **copy-pasted**,
not shared. Every new opcode, every new config flag, every new security
knob must be threaded through three sites. Miss one → silent behavioral
divergence. The bugs Mighty is hitting are the inevitable result.

### Specific Divergence Vectors

- **CLI `cliIsaReg`** lacks `webFetchOp`, `webSearchOp`, `harnessListOp`,
  `harnessStartOp`, `harnessStopOp`. The CLI agent literally has fewer tools
  than the web agent.
- **CLI child registry** (`cliChildRegistryBuilder`) also lacks web/harness ops.
  Delegated agents on CLI are even more crippled.
- **`buildWebRegistry`** and **`buildIsaRegistry`** are line-for-line
  identical except for the function name — ~115 lines of pure duplication.
- **System prompt resolution** is implemented three times:
  `resolveSystemPrompt` (Send.hs), inline in `runTurnOnSession` (Loop.hs),
  `resolveSystem` (Cli.hs). Each does the same `injectStaticGuidance →
  injectAutoloadSkill → injectAvailableSkills` pipeline but with subtle
  ordering and config-reading differences.
- **`autoBindRepoAgent`** is called in all three paths, but at different
  points in the turn setup, with different error handling.
- **Cross-channel reply fan-out** is wired differently: the web path uses
  `replyFanout` explicitly; the channel path uses `replySubscribe` +
  `replyFanoutMessage`; the CLI path doesn't subscribe at all.

---

## 2. Design Principle

> **The core Seal Harness exposes a REST API. All communication channels
> provide their functionality using ONLY that API.**

This is the "layered harness" architecture. The REST API becomes the single
integration point. Channels become thin adapters that translate their
medium-specific input (Telegram messages, Signal messages, TUI keystrokes)
into API calls and translate API responses back to medium-specific output.

The ISA registry builder, the turn execution, the transcript management,
the system prompt resolution — all of it moves behind the API. There is
exactly one implementation of each.

---

## 3. Proposed Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Interaction Surfaces                       │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐    │
│  │ Web SPA  │  │  TUI     │  │ Telegram │  │ Signal   │    │
│  │(React)   │  │(Haskeline)│  │(Telethon)│  │(signal-cli)│   │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘    │
│       │              │              │              │          │
└───────┼──────────────┼──────────────┼──────────────┼─────────┘
        │              │              │              │
        │  HTTP/WS     │  HTTP        │  HTTP        │  HTTP
        ▼              ▼              ▼              ▼
┌─────────────────────────────────────────────────────────────┐
│                    REST API Layer                             │
│                                                               │
│  POST /api/sessions/:id/send       ← the single turn entry    │
│  POST /api/sessions/:id/stop                                    │
│  POST /api/sessions/:id/setup-repo                              │
│  GET  /api/sessions/:id/transcript                              │
│  GET  /api/sessions/:id/questions                               │
│  POST /api/sessions/:id/questions/:qid/answer                   │
│  GET  /api/tabs / POST /api/tabs / DELETE /api/tabs/:idx        │
│  GET  /api/agents / CRUD                                       │
│  GET  /api/skills / CRUD                                        │
│  GET  /api/repos / CRUD                                        │
│  GET  /api/providers / models                                   │
│  WS   /stream                  ← live transcript + tab updates │
│                                                               │
│  *** ONE implementation of every operation ***                 │
└───────────────────────┬───────────────────────────────────────┘
                        │
                        │  (in-process: direct function calls)
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                    Core Harness                               │
│                                                               │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────────┐     │
│  │ Turn Engine │  │ ISA Registry │  │ Session Manager  │     │
│  │ (runTurn)   │  │ (one builder)│  │ (meta + lock)    │     │
│  └─────────────┘  └──────────────┘  └──────────────────┘     │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────────┐     │
│  │ Transcript  │  │ System Prompt│  │ Provider Resolve│     │
│  │ (two-file)  │  │ (one resolve)│  │ (vault-backed)   │     │
│  └─────────────┘  └──────────────┘  └──────────────────┘     │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────────┐     │
│  │ Skill Backend│ │ Agent Defs   │  │ Memory Backend   │     │
│  │ (workdir-aware)│ │ (workdir-aware)│ │ (markdown)      │     │
│  └─────────────┘  └──────────────┘  └──────────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

### 3.1 The Single Turn Path

Today's three `plainTurn` variants collapse into one. The API handler
`POST /api/sessions/:id/send` is the only entry point for agent turns.
It calls a single `runTurnOnSession` that:

1. Loads session meta (one implementation)
2. Resolves provider + model (one implementation)
3. Opens transcript bracket (one implementation)
4. Builds `mkSessionExec` (one implementation)
5. Constructs workdir-aware backends (one implementation)
6. Resolves system prompt (one implementation)
7. Builds ISA registry (one builder — the union of all current opcodes)
8. Wires AGENT_START (one implementation)
9. Constructs `AgentEnv` (one `mkSessionAgentEnv` call)
10. Runs `runTurn` or `dispatch`

The `ChannelCaps` — the only medium-specific piece — becomes a thin
abstraction over the API's response mechanisms:

```haskell
data ChannelCaps = ChannelCaps
  { ccSend       :: Text -> IO ()        -- write to medium
  , ccPrompt     :: AskPrompt -> IO Text -- ask human via medium
  , ccPromptSecret :: Text -> IO Text    -- secret prompt via medium
  , ccStreaming  :: Bool                 -- does medium support streaming?
  }
```

Each channel adapter constructs its `ChannelCaps` and passes it into
the shared turn engine. The turn engine is caps-agnostic — it doesn't
know or care whether the caps write to stdout, Telegram, or a WS broker.

### 3.2 Channel Adapters

Each surface becomes a thin adapter:

**TUI Adapter** (`Seal.Channel.Cli`):
- Reads from Haskeline → `POST /api/sessions/:id/send` (in-process)
- Renders responses to stdout
- Slash commands → API calls (e.g. `/tab list` → `GET /api/tabs`)
- ASK_HUMAN → stdin prompt
- ~200 lines of glue, down from ~830

**Telegram Adapter** (`Seal.Channels.Telegram`):
- Receives Telegram updates → `POST /api/sessions/:id/send`
- Renders responses via Telegram API
- Tab/focus/new routing via `Route.route` → API calls
- ASK_HUMAN → inline keyboard buttons
- ~150 lines of glue, down from ~400+

**Signal Adapter** (`Seal.Channels.Signal`):
- Same pattern as Telegram

**Web Frontend** (React SPA):
- Already an API consumer. Minimal change — it already calls the REST
  API. The only change is that it no longer has a privileged "web path"
  through `Send.hs`; it uses the same `POST /send` as everyone else.

### 3.3 What Dies

- `buildWebRegistry` (Send.hs) — merged into `buildIsaRegistry` (or
  vice versa; the name doesn't matter, there's only one)
- `buildIsaRegistry` (Loop.hs) — same
- `cliIsaReg` (Cli.hs inline) — same
- `resolveSystemPrompt` (Send.hs) — merged with `resolveSystem` (Cli.hs)
  and the inline resolution in `runTurnOnSession`
- `webCallDispatcher`, `channelCallDispatcher`, `callDispatcher` (Cli.hs) —
  one dispatcher, parameterized by `ChannelCaps`
- `webStartWiring`, `channelStartWiring`, `cliStartWiring` — one
  `AgentStartWiring` builder
- `webAskCaps`, `mkHandleCaps`, CLI's inline `caps` — one `ChannelCaps`
  factory per medium, calling a shared turn engine
- `webMkWorker`, `channelMkWorker` — one worker builder
- The three `mkCloneDepsFrom*` variants — one clone deps builder

### 3.4 What Stays

- `ChannelCaps` — medium-specific I/O, but a uniform interface
- `ChannelHandle` / `Channel` type class — the transport abstraction
- `Route.route` — the terse grammar parser (Layer 1)
- `Ingest.ingest` — the slash-command preprocessor
- The command `Registry` — slash command specs (but they call the API,
  not the core directly)
- `StreamBroker` / WS — the web frontend's live-update channel
- `ReplyRegistry` — cross-channel reply fan-out (still needed for
  multi-medium sessions)

---

## 4. Migration Path

This is a refactor, not a rewrite. The key constraint: **never break the
web frontend**. It's the primary dev surface.

### Phase 1: Unify the ISA Registry (mechanical)

Merge `buildWebRegistry` + `buildIsaRegistry` + `cliIsaReg` into a single
`buildSessionRegistry`. The function signature already matches across
all three. The CLI's version is missing web/harness ops — add them.
This alone fixes the "CLI agent has fewer tools" bug.

**Risk:** Low. Pure consolidation of identical code.
**Verification:** Existing test suite + verify CLI agent can call
WEB_SEARCH, HARNESS_LIST.

### Phase 2: Unify System Prompt Resolution

Merge `resolveSystemPrompt` (Send.hs), `resolveSystem` (Cli.hs), and
the inline resolution in `runTurnOnSession` into one function.

**Risk:** Low. Same pipeline, same injection order.
**Verification:** Test that system prompts are byte-identical across
all three surfaces for the same session + agent + config.

### Phase 3: Unify the Turn Body

Extract the shared turn body (steps 1-12 from §3.1) into a single
function parameterized by `ChannelCaps` + `SessionId` + `Text`. The
three `plainTurn` variants become one-liners that construct caps and
call the shared function.

**Risk:** Medium. The three paths have subtle differences in
broadcast timing, lock acquisition, and reply fan-out wiring.
**Verification:** Integration tests for each surface.

### Phase 4: Unify Call Dispatchers + Start Wiring

Merge the three `*CallDispatcher` functions and the three
`*StartWiring` builders. The dispatcher is parameterized by
`ChannelCaps` + `SessionId`.

**Risk:** Medium. The web dispatcher swaps `srActive` for multi-session
support; the channel dispatcher reads from an `IORef`. These need to
converge on a single session-resolution strategy.
**Verification:** `/call` + `/skill load` from each surface, verify
transcript entry lands on the correct session.

### Phase 5: CLI Becomes API Client (optional, larger)

The CLI currently shares the same process as the gateway under
`seal serve`. In the final state, the CLI could be a pure HTTP client
of the API — even running as a separate process. This eliminates the
last "in-process but not via API" path.

**Risk:** Higher. The CLI uses direct function calls (not HTTP) for
performance. Converting to HTTP adds latency to every turn.
**Mitigation:** Keep in-process calls but route them through the same
handler function the API uses. The "API" is the function, not the
HTTP transport. HTTP is just one transport; in-process is another.

### Phase 6: Channel Adapters Slim Down

With the shared turn engine in place, the channel files
(`Channels/Telegram.hs`, `Channels/Signal.hs`, `Channel/Cli.hs`) shrink
to just transport + caps construction. The `Channels/Loop.hs` module
simplifies to a thin loop that calls the shared turn engine.

**Risk:** Low (once phases 1-4 are done).

---

## 5. Key Design Decisions

### 5.1 In-Process API vs HTTP API

The "REST API" is the **contract**, not the transport. The same handler
function serves both HTTP requests (from the web frontend) and
in-process calls (from the CLI, Telegram adapter). The TUI doesn't
make HTTP calls to itself — it calls the handler function directly.

This means:
- `apiApp` (the WAI application) routes HTTP → handler functions
- The CLI calls the same handler functions directly (no HTTP overhead)
- The Telegram/Signal adapters call the same handler functions
  (in-process under `seal serve`, or via HTTP if standalone)

The handler functions ARE the API. HTTP is one serialization of them.

### 5.2 ChannelCaps as the Only Medium-Specific Seam

The only thing that varies between surfaces is **how the agent
communicates with the human**:
- Web: WS broker pushes to React frontend
- Telegram: Telethon sends messages
- Signal: signal-cli sends messages
- CLI: stdout/stdin

`ChannelCaps` captures this. Everything else — the turn engine, the
ISA registry, the transcript, the system prompt — is shared.

### 5.3 No New Abstractions

This refactor doesn't introduce new type classes, new effect systems,
or new architectural patterns. It consolidates existing code into
shared functions. The `ReaderT AppEnv IO` + Handle pattern stays. The
`Channel` class stays. The `ChannelCaps` stays. We're removing
duplication, not adding layers.

### 5.4 The API Already Exists

The REST API in `Gateway/API.hs` already has:
- `POST /api/sessions/:id/send` — turn entry
- `POST /api/sessions/:id/stop` — abort
- `GET /api/sessions/:id/transcript` — transcript read
- `GET /api/sessions/:id/questions` — pending questions
- `POST /api/sessions/:id/questions/:qid/answer` — answer ASK_HUMAN
- `GET /api/tabs` — tab list
- Full CRUD for agents, skills, repos, providers

The API is the integration point. It just needs to be the **only**
integration point. The channels need to stop building their own turn
machinery and start calling these handlers.

---

## 6. What This Fixes

| Bug Class | Root Cause | Fix |
|----------|-----------|-----|
| CLI agent can't search the web | `cliIsaReg` omits `webFetchOp`/`webSearchOp` | Single registry includes all opcodes |
| Tab close notification missed on CLI | CLI path doesn't wire `mkTabCloseNotifier` | Single turn path wires it once |
| Skill load writes to wrong session (web) | `webCallDispatcher` reads `srActive` not request sid | Single dispatcher takes explicit `SessionId` |
| Reply fan-out inconsistent | Three different fan-out wiring patterns | Single turn path fans out once |
| Agent start wiring diverges | Three `*StartWiring` builders | One builder, parameterized by caps + channel label |
| System prompt ordering differences | Three resolution implementations | One function, one injection order |
| New opcode missing from CLI | Must add to `cliIsaReg` separately | Add to one registry builder |

---

## 7. Open Questions

1. **Session resolution strategy**: The web path swaps `srActive` for
   multi-session support. The channel path uses per-conversation
   cursors. The CLI uses `srActive` directly. These need to converge —
   probably on "explicit `SessionId` parameter, no global mutable
   state" (the web path's swap hack is a symptom of the wrong
   abstraction).

2. **Broadcast timing**: The three paths call `broadcastNewEntries`
   at slightly different points (before vs after the turn, with vs
   without `broadcastHarnessStatus`). The shared path needs one
   canonical broadcast sequence.

3. **Lock scope**: The web path acquires `withSessionLock` inside the
   transcript bracket. The channel path acquires it outside. Need to
   pick one (probably outside — the lock protects the turn, not just
   the transcript write).

4. **Standalone mode**: `seal telegram` and `seal signal` run without
   the web gateway. They still need the turn engine. The shared
   functions must work without a `StreamBroker` (already handled via
   `Maybe StreamBroker`, but needs verification).

5. **Child agent registries**: The three `buildChildRegistry` variants
   (one per surface) also differ. The CLI child registry is missing
   web/harness ops. This needs the same consolidation as the parent
   registry.

---

## 8. Success Metric

> A new opcode added to the ISA registry is available on all four
> surfaces (Web, TUI, Telegram, Signal) with zero additional wiring
> per surface.

Today this requires touching 3+ files. After the refactor, it requires
touching 1.