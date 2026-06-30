# Design: Seal Harness — Agent Spine over the CLI channel

> **Status:** approved design, pre-plan. Feeds `writing-plans` → a TDD plan under
> `docs/superpowers/plans/`.
>
> **Position in the roadmap:** this branch (`phase-2.5-agent-spine`) builds the
> unbuilt remainder of roadmap *Phase 2* — the agent spine — but scoped to the
> **CLI channel** (web deferred) and to **only the types the running loop
> touches**. It is the prerequisite for roadmap *Phase 3* (Trusted-opcode
> breadth), which becomes the following branch once this spine lands and runs.

## 1. Goal and milestone

Stand up the smallest runnable agent that proves the architecture end-to-end over
the **existing** CLI channel + `Seal.Ingest`:

`export ANTHROPIC_API_KEY=…` (or resolve from the vault) → start the REPL → type a
plain message → Claude responds and can:

- **Trusted:** `SHOW_HUMAN` (emit a line) and `ASK_HUMAN` (prompt, read a reply).
- **Untrusted:** `FILE_READ` a workspace file via `SafePath`, **blocked until its
  audit entry is durably written** (ACK-before-execute).
- **Audited:** `SECRET_GET` a vault key (carries `TrustLevel = Audited`; records to
  the session transcript — the unified cross-session Audited log stays deferred to
  roadmap Phase 5; secret *values* never enter any transcript/log).

Every request, response, and opcode invocation lands in an **append-only
transcript**. This is the smallest thing that exercises the trust taxonomy, the
ISA dispatcher, and the durability-gated Untrusted path.

**Explicitly out of scope** (deferred): the Warp/WAI gateway + web frontend;
streaming completions; `Seal.Harness.*` / `Seal.Tabs.*` types and lifecycle;
`Seal.Session.*` beyond the minimum the loop needs; the unified Audited log;
Trusted-opcode breadth (Tools/Sessions/Scheduling/Harnesses/MCP groups).

## 2. Scope decisions (locked)

| Decision | Choice |
| --- | --- |
| Channel | CLI only; agent is the handler for `Ingest`'s `PlainMessage`. Web deferred. |
| Type foundation | Only what the running loop touches. No Harness/Tabs/Session-heavy types. |
| Seed opcodes | All three trust levels: `SHOW_HUMAN`, `ASK_HUMAN`, `FILE_READ`, `SECRET_GET`. |
| Provider | Anthropic Messages API, **non-streaming `complete` only**. Streaming deferred. |
| CLI integration | No new subcommand; plain text in the existing REPL → agent loop. |

All work inherits the roadmap's **Global Constraints** verbatim (clean-room rule;
`Seal.*` namespace; `Either Text`/`ExceptT Text` errors with a bespoke ADT only
where control flow matches; `-Wall -Werror` + strict set; TDD red→green; hlint
clean; no secret ever serialized; no shell-wrapping in Trusted/Audited opcodes;
type-guaranteed subprocess args; Nix dev shell build/verify; one commit per task).

## 3. Module plan (new modules only)

Built bottom-up, each a leaf depending only on what precedes it. Names follow the
roadmap's `Seal.*` map.

### 3.1 `Seal.Core.Types`
The shared leaf vocabulary, **subset only**:
- `TrustLevel = Untrusted | Trusted | Audited` (the per-opcode classification).
- Identity newtypes the loop touches: `ProviderId`, `ModelId`, `ToolCallId`,
  `OpName` (opcode name), and `SessionId` with `isValidSessionId` (non-empty, no
  leading dot, charset `[A-Za-z0-9_-]`) used at every path-join/boundary.
- No `MessageSource`/`ConversationId`/`AutonomyLevel`/`AllowList` yet (not on the
  loop's path); add when a channel that needs them lands.

QuickCheck: every smart constructor rejects malformed input; `isValidSessionId`
charset property.

### 3.2 `Seal.Transcript.Types`
The append-only audit-entry model:
- `Direction = Request | Response`.
- `TranscriptEntry` — uuid, timestamp, optional model, direction, raw payload
  (`Value`), optional duration, a correlation id linking request↔response,
  extensible metadata map.
- `encodeEntryRaw` guaranteeing the in-memory entry re-encodes byte-identically
  to its on-disk JSONL line (so "view raw" hides nothing).

QuickCheck: JSON round-trip; `encodeEntryRaw` stability.

### 3.3 `Seal.Handles.Transcript`
The durability primitive the Untrusted gate depends on:
- Append-only JSONL over a raw POSIX file descriptor + `fsync`.
- A writer-thread daemon (`STM` queue + `async`); `recordAndAck :: TranscriptEntry
  -> IO ()` enqueues and **returns only after the entry is fsync'd to disk**.
- A `TranscriptHandle` capability record (`recordAndAck`, `recordAsync`, `close`)
  so callers receive a handle and the daemon is fakeable in tests.

Integrity model (per roadmap): comes from the append-only handle plus keeping
untrusted actions off the box that holds the log — **not** a tamper-evident hash
chain. No chaining here.

### 3.4 `Seal.Providers.Class`
The provider/message model:
- `Role = User | Assistant`.
- `ContentBlock = Text Text | ToolUse {…} | ToolResult {…}` and `ToolResultPart`
  (text only for now; image deferred) so tool-use/tool-result interleave in one
  message list.
- `Message`, plus convenience builders.
- `ToolDefinition` (name, description, JSON input schema), `ToolChoice`.
- `CompletionRequest` (model, messages, tools, system), `CompletionResponse`
  (content blocks, stop reason, `Usage`), `Usage`.
- The `Provider` class: `complete`; `completeStream` **default-delegates** to
  `complete`; `listModels`. `SomeProvider` existential for config-driven choice.

QuickCheck: full JSON round-trips on the request/response/message types.

### 3.5 `Seal.Providers.Anthropic`
The one concrete provider:
- Implements `Provider` against the Messages API via `http-client`/`http-client-tls`.
- Reads the API key through `withApiKey` (CPS) from the vault — never as raw
  `Text`, never logged. Falls back to `ANTHROPIC_API_KEY` env for the MVP.
- Maps `ContentBlock` ↔ Anthropic JSON; surfaces `tool_use` blocks as the loop's
  dispatch trigger and accepts `tool_result` blocks on the way back.
- Non-streaming only.

Tested against recorded/fake HTTP at the JSON-mapping boundary; the live call is a
single opt-in integration test (mirrors Phase 1's real-`age` test), not in the
default suite.

### 3.6 `Seal.ISA.Opcode` / `Seal.ISA.Registry`
The instruction set as **data**:
- `Opcode` record: `opName :: OpName`, `opTrust :: TrustLevel`, JSON input schema,
  JSON output schema, a description, and an **authorization gate** (`opAuthorize ::
  Value -> Either Text ()` — a pure check run before execution), plus the
  effectful `opRun` (see the backend seam below).
- `Registry` — name→`Opcode` map; `lookupOp`, `registryToolDefs` (derive the
  provider `ToolDefinition` list the agent is offered).

### 3.7 `Seal.ISA.Dispatch`
- `dispatch :: Registry -> TranscriptHandle -> OpName -> Value -> App Result`.
- **ACK-before-execute invariant:** for an `Untrusted` opcode, `dispatch` calls
  `recordAndAck` for the invocation entry **before** `opRun` executes. For
  `Trusted`/`Audited`, the record may be concurrent with execution.
- **Backend-execution seam:** Untrusted `opRun` dispatches through an indirection
  (a `BackendExec` handle) rather than running inline, so roadmap Phase 4 can slot
  local-vs-remote executors behind it without reworking dispatch. For this branch
  the only backend is local/in-process.
- Authorization gate runs before either path; a failed gate is a `Result` error,
  never an execution.

### 3.8 `Seal.ISA.Ops.{Human,File,Secret}`
The four seed opcodes, each `Opcode` values registered into the registry:
- `Human`: `SHOW_HUMAN` (→ `ccSend`), `ASK_HUMAN` (→ `ccPrompt`). Trusted.
- `File`: `FILE_READ` — validates the path through `Seal.Security.Path`
  (`mkSafePath`), reads bounded content. Untrusted (drives the ACK path).
- `Secret`: `SECRET_GET` — reads a key from the live vault via `VaultRuntime`'s
  `VaultHandle`; **only the key name + operation metadata** reach the transcript,
  never the value (the value flows to the model as a tool result but is excluded
  from the recorded payload). Audited.

### 3.9 `Seal.Agent.Env` / `Seal.Agent.Loop`
The turn loop:
- `AgentEnv` — a capability-handle record bundling everything the loop needs:
  `SomeProvider`, `Registry`, `TranscriptHandle`, `ChannelCaps`, `VaultRuntime`,
  `WorkspaceRoot`, model id, session id. Pure injection ⇒ fully fakeable.
- `runTurn :: AgentEnv -> Text -> App ()`: ingest is already done by
  the caller; build a `CompletionRequest` carrying `registryToolDefs` → `complete`
  → if the response has `ToolUse` blocks, `dispatch` each, append `ToolResult`
  blocks, and loop; otherwise `ccSend` the final assistant text. Every request and
  response is `recordAndAck`'d. A turn-count cap guards runaway tool loops.

## 4. Data flow

```
REPL line
  └─ Seal.Ingest.ingest (existing preprocess chain + slash classifier)
       ├─ DispatchAction / ShowText / Rejected  → existing handling (unchanged)
       └─ PlainMessage t                         → Seal.Agent.Loop.runTurn
            └─ build CompletionRequest (messages + registryToolDefs)
                 └─ Provider.complete  ── recordAndAck(Request/Response) ──┐
                      ├─ ToolUse blocks → ISA.Dispatch.dispatch            │
                      │      (Untrusted ⇒ recordAndAck BEFORE opRun)       │
                      │      → ToolResult blocks → append → loop ──────────┘
                      └─ no tool calls → ccSend final text → turn ends
```

## 5. Error handling

- Default `Either Text` / `ExceptT Text` throughout.
- One small bespoke ADT **only** in `ISA.Dispatch`, and only if the loop branches
  on it: `DispatchError = OpNotFound OpName | Denied Text | ExecFailed Text`. The
  loop turns a `Denied`/`ExecFailed` into a `tool_result` error block the model can
  see and react to; `OpNotFound` is an internal invariant breach. If the loop ends
  up not pattern-matching these distinctly, collapse to `Either Text`.

## 6. Testing strategy (TDD, red→green)

- **ACK ordering (the keystone test):** a fake `TranscriptHandle` and a fake
  Untrusted opcode that records the order of `recordAndAck` vs. `opRun`; assert the
  ack happens first. A `Trusted` opcode has no such ordering requirement.
- **Multi-turn tool loop:** a fake `Provider` scripted to emit a `tool_use` then a
  final text turn; assert dispatch runs, the `tool_result` is fed back, and the
  loop terminates. Drives the loop with zero network.
- **Secret never serialized:** assert the `SECRET_GET` transcript entry contains
  the key name but not the value (property + targeted test); reuse the Phase-1
  redacted-`Show` guarantees.
- **Opcode authorization gates:** per-opcode gate accepts/rejects table.
- **QuickCheck round-trips:** `Core.Types` smart constructors; `TranscriptEntry`
  JSON + `encodeEntryRaw`; provider request/response/message JSON.
- **Live Anthropic call:** one opt-in integration test, excluded from the default
  `cabal test` run.

## 7. Boundaries / isolation check

`Seal.Agent.Loop` depends only on the `AgentEnv` handles — `Provider`, `Registry`,
`TranscriptHandle`, `ChannelCaps`, `VaultRuntime` — each independently fakeable; no
concrete provider, HTTP manager, or file IO leaks into the loop's type. `dispatch`
depends on `Registry` + `TranscriptHandle` + the backend seam, nothing else. Each
unit answers: what it does, how you call it, what it depends on.

## 8. Wiring / housekeeping

- `Seal.Ingest`'s `PlainMessage` branch (currently the "MVP stub") routes to
  `runTurn`. No change to the slash-command path.
- `AgentEnv` is constructed at REPL start from the resolved config + handles
  (provider selected from config/env, transcript daemon started, vault runtime
  reused from the existing `/vault` wiring).
- New cabal deps as needed: `http-client`, `http-client-tls`, `async` (if not
  already present); confirm against `seal-harness.cabal` during planning.
- The branch is named `phase-2.5-agent-spine` to reflect that it completes the
  Phase-2 spine rather than starting Phase-3 breadth.

## 9. Definition of done

In the Nix dev shell: `cabal build all` is `-Werror` clean, `cabal test` green
(including the new QuickCheck properties and the ACK-ordering test), `hlint
src/ test/` clean, and the §1 milestone is demonstrable end-to-end over the CLI.
Then write the Phase-3 (Trusted-opcode breadth) plan before starting it.
