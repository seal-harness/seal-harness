# `/skill load` — load a skill into the current session via `SKILL_LOAD`

**Date**: 2026-07-21 · **Status**: revised (round 2, post-review-gate) · **Branch**: `feat/skill-load`

## Design review gate (round 1 → round 2)

Round 1 ran 5 reviewers (PM, Architect, Designer, Security, CTO) in parallel.
All 5 returned NEEDS_REVISION. Resolutions (with the user):

- **Channel scope** — round 1 incorrectly claimed Signal.Run and Telegram.Run
  already build a `CallDispatcher` for `/call`. They don't. The user wants
  all 4 channels in v1, structured around a **unified code path** so the
  question doesn't arise again. Round 2 introduces a per-turn
  `channelCallDispatcher` inside `Seal.Channels.Loop` (analogous to
  `webCallDispatcher`) and routes both `/call` and `/skill load` through
  it. Signal.Run and Telegram.Run now register both commands.
- **Duplicate-load gate** — round 1 shipped a confirmation gate that
  prompted on re-loads with token-distance + context-window-percentage.
  PM flagged it as highest-friction/lowest-benefit; Security flagged a
  re-prompt DoS vector and an O(n) scan over the **uncompacted**
  `entries.jsonl` (only `conversation.jsonl` is compacted). User
  decision: **drop the gate from v1**. Ship rename + `/skill load` only.
  Defer the gate to v2 with the declined-cache + scan-cap fixes.
- **Web frontend filter** — round 1 incorrectly claimed the web frontend
  can render `EKHarness` entries distinctly via `erMeta.op.name`. In fact
  `reconEntryToFrontend` (`Seal.Gateway.Transcript.hs:283-285`) **drops
  every `EKHarness` entry that has no `"approval"` key**, and
  `harnessPayload` (`Seal.Transcript.Reconstruct.hs:151`) only copies
  `op` into the payload when an approval key exists. Round 2 explicitly
  whitelists `op.name == "SKILL_LOAD"` in both functions so a
  `SKILL_LOAD` invocation surfaces in the frontend as a distinct
  harness entry carrying its `op` metadata.
- **Two-constructor child exemption** — moot in round 2 (gate is
  dropped). The single `skillLoadOp :: SkillBackend -> Opcode`
  constructor is used unchanged for parent and child registries.
- **Use cases** — round 1 §1 was a problem narrative. Round 2 rewrites
  it as WHO/WANTS/SO THAT/WHEN use cases with explicit personas.
- **TDD readiness** — round 1's test plan was underspecified. Round 2
  enumerates opcode-level tests, names the transcript fixture (temp-dir
  `TwoFileHandle`), and adds a phasing table.
- **DoD grep scope** — round 1's "grep -r SKILL_READ returns zero
  hits" was wrong (historical `docs/handoffs/...` legitimately retain
  the name). Round 2 scopes it to `src/`, `test/`, `README.md`, and
  live docs under `docs/superpowers/`.

## 1. Use cases

**Persona A — CLI operator.** Wants to load a skill into the current
session to drive the next turn, and wants the transcript to record
that load as a distinct event (not as the user having pasted the
body).

> **As** a CLI operator, **I want** to type `/skill load <id>` and
> have the skill body injected into the current session, **so that**
> the agent sees the skill as context for the next turn and the
> transcript records a discrete `SKILL_LOAD` event, **when** I decide
> a defined skill is relevant mid-conversation.

**Persona B — Web frontend user.** Same intent as A, plus: wants the
frontend to render the skill load as a distinct harness entry (not a
plain user bubble), so the conversation history visually distinguishes
"human typed this" from "skill was loaded."

> **As** a web user, **I want** to send `/skill load <id>` from the
> chat composer and see the skill load appear in the transcript as a
> harness event labeled with the skill id, **so that** I can later
> skim the transcript and tell which turns were shaped by which
> loaded skills, **when** I'm reviewing a long conversation.

**Persona C — The agent itself.** Already has `SKILL_READ` (renamed
to `SKILL_LOAD` by this design). The rename is a pure relabel; the
agent's capability is unchanged. The shared name is the point: both
the user's `/skill load` and the agent's tool call hit the same
opcode, so the audit trail attributes both uniformly.

> **As** the agent, **I want** my tool call to load a skill to be
> named `SKILL_LOAD` (not `SKILL_READ`), **so that** the transcript
> records my load and the human's `/skill load` with the same
> `erMeta.op.name`, **when** I decide a skill is relevant to my task.

## 2. Why an opcode, not an IORef-and-prepend?

Earlier discussion considered having `/skill load` silently stash the
body in a per-session `IORef (Maybe Text)` and have `plainHandler` /
`Seal.Gateway.Send` prepend it to the next turn. **We reject that
approach** for three reasons:

1. **Audit-trail integrity.** If `/skill load` just mutates an `IORef`
   and prepends text in `plainHandler`, the skill body shows up in the
   transcript as part of a user message — indistinguishable from the
   user having pasted the body themselves. Every other skill operation
   (`SKILL_WRITE`, `SKILL_READ`, `SKILL_DELETE`, `SKILL_LIST`) is an
   audited opcode with proper provenance. Loading a skill via a
   side-channel would break that invariant.
2. **Symmetry with the agent path.** The agent's skill-load path is
   already an opcode (`SKILL_READ`, renamed to `SKILL_LOAD` by this
   design). The user's skill-load path should use the same opcode, so
   the transcript records both load paths with the same `EKHarness`
   entry shape — the audit trail can answer "when was skill X loaded
   into session Y, and by whom?" uniformly.
3. **Web-channel identification.** The user wants skill loads to be
   "properly identified as a skill load operation" in the web
   frontend, not just rendered as skill text inside a user bubble. An
   opcode invocation has a discrete `EKHarness` entry with
   `erMeta.op.name = "SKILL_LOAD"` and the skill id as input. **This
   requires a frontend filter change** (see §3.4) — the current
   filter drops every non-approval `EKHarness` entry before it
   reaches the SPA, so the rename alone is not enough.

## 3. Design

### 3.1 Rename `SKILL_READ` → `SKILL_LOAD`

Rename the existing `SKILL_READ` opcode to `SKILL_LOAD`. This is a
**pure rename**: the opcode's behavior, trust level (`Trusted`),
schema, `toRun` body, and `orRecorded` shape are unchanged. The
agent's tool-call name changes from `SKILL_READ` to `SKILL_LOAD`; the
agent's system-prompt tool description updates accordingly (driven by
`toDesc`, which changes from "Read one agent skill by id into the
prompt." to "Load one agent skill by id into the current session.").

Rationale: "LOAD" describes what the opcode does — load a skill into
the session context. "READ" is ambiguous (read it for what? into
what?). The new `/skill load` user command and the agent tool now
share a name, which is the whole point of using one opcode for both
paths.

### 3.2 `/skill load` invokes the opcode

`/skill load <skill-name>` is a new subcommand of the existing
`/skill` group. It dispatches the `SKILL_LOAD` opcode against the
active session's ISA registry, exactly as
`/call SKILL_LOAD {"id":"..."}` would — but with a friendlier surface
syntax.

The dispatch path:

1. `skillArg` parses the skill id (`[A-Za-z0-9_-]+`, non-empty, no
   leading dot — same predicate as `mkSkillId`, already used by
   `/skill info`).
2. The command builds the JSON input `{"id": "<skill-name>"}` and
   invokes a `CallDispatcher` (`Seal.Command.Call`) supplied by the
   channel wiring. The dispatcher is the same one `/call` uses: it
   threads the active session's `TwoFileHandle` + ISA registry + env.
3. The dispatcher runs `dispatch`, which:
   - records an `EKHarness` entry to `entries.jsonl` with
     `erMeta.op.name = "SKILL_LOAD"` and `erMeta.input = {"id": ...}`
     (the audit trail we want), then
   - runs `skillLoadOp`, which returns
     `OpResult [TrpText rendered] False recorded` where `rendered`
     is `"# <id>\n\n<description>\n\n---\n\n<body>"` and `recorded`
     carries the id + description + body + updated_at + session.
4. `renderOpResult` (`Seal.Command.Call`) prints the rendered body to
   the channel via `ccSend`. The command also echoes a header line
   first so the "Command output" bubble is self-contained. The echo
   line format is `$ /skill load <id>` (mirrors `/call`'s
   `echoLine` at `Seal.Command.Call.hs:95`).

### 3.3 Transcript attribution

The user's `/skill load <id>` shows up in the transcript in two
places, mirroring how `/call` already records:

- The slash command itself is echoed as the first line of the command
  output (so the "Command output" bubble is self-contained — same
  pattern as `Seal.Command.Call.echoLine`).
- The dispatcher records the `EKHarness` entry with
  `erMeta.op.name = "SKILL_LOAD"` and `erMeta.input = {"id": ...}`.
  This is the "coming from the human" attribution the user wants: the
  entry is recorded under the active session's transcript, and the
  only way an `EKHarness` entry with `op.name = "SKILL_LOAD"` lands
  in the transcript is if someone (human via `/skill load` or agent
  via tool call) invoked the opcode.

When the **agent** issues the tool call, the same `EKHarness` entry
is recorded by the same dispatcher — so the audit trail is uniform.
The distinction between "human invoked" and "agent invoked" is
already encoded in the surrounding transcript entries: a
`/skill load` invocation is preceded by a `EKRequest` entry with the
user's slash command in the conversation; an agent tool call is
preceded by an `EKResponse` entry with a `CbToolUse` block.

### 3.4 Web frontend filter fix

The current frontend transcript renderer drops every `EKHarness`
entry that has no `"approval"` key in its payload
(`Seal.Gateway.Transcript.reconEntryToFrontend:283-285`), and
`harnessPayload` (`Seal.Transcript.Reconstruct.hs:151`) only copies
`op` into the payload when an approval key exists. Without these two
changes, a `SKILL_LOAD` invocation (which has no approval metadata)
is invisible to the SPA — the user's requested "properly identified
as a skill load operation" does not ship.

Two coordinated edits:

1. `harnessPayload` (`Seal.Transcript.Reconstruct.hs:145-158`):
   always include `"op" .= (Map.lookup "op" (erMeta e))` in the base
   payload (currently only added in the approval branch). The base
   payload becomes `{messages, harness, op}`; the approval branch
   stays `{messages, harness, op, approval}`.
2. `reconEntryToFrontend` (`Seal.Gateway.Transcript.hs:283-285`):
   relax the drop-filter so a `harness` entry is kept when EITHER it
   has an `approval` key OR its `op.name` is in a whitelist of
   user-surfacing opcodes. v1 whitelist: `{"SKILL_LOAD"}`. (Future
   opcodes that should surface to the user get added here.) The
   filter becomes:

   ``` haskell
   A.Object o
     | KeyMap.member (Key.fromText "harness") o,
       not (KeyMap.member (Key.fromText "approval") o),
       not (isUserSurfacingOp o) -> Nothing
   ```

   where `isUserSurfacingOp o = case KeyMap.lookup "op" o of
   Just (Object opObj) -> case KeyMap.lookup "name" opObj of
   Just (String n) -> n `Set.member` userSurfacingOps; _ -> False; _ ->
   False`, and `userSurfacingOps :: Set.Set Text` is a module-level
   constant `Set.fromList ["SKILL_LOAD"]` (a `Set` rather than a list
   to make the shared-state surface discoverable — see §8 risk 2).

The frontend's payload renderer (`rewritePayload` at
`Seal.Gateway.Transcript.hs:304`) is not touched in v1 — the SPA
already renders a `harness` entry's raw payload, so the new
`SKILL_LOAD` entries will appear with their `op.name` and `input.id`
visible. A dedicated frontend rendering component (a "skill loaded"
badge) is a follow-up.

### 3.5 Unified channel wiring via `channelCallDispatcher`

The user wants a unified code path across all 4 channels so the
"which channels ship /skill load?" question doesn't arise. Today
only CLI (inside `runCliTui`) and web (`Seal.Command.Serve`) build a
`CallDispatcher` for `/call`; Signal.Run and Telegram.Run do not
register `/call` at all.

The fix: introduce `channelCallDispatcher :: ChannelDeps ->
ChannelHandle -> AskReplyStore -> IORef SessionId -> CallDispatcher`
in `Seal.Channels.Loop`, mirroring `webCallDispatcher`
(`Seal.Gateway.Send.hs:516`). It reads `sid` from the IORef fresh on
each invocation, opens the session's transcript via
`withTwoFileTranscript`, builds the session's `ChannelCaps` via the
same `mkHandleCaps` pattern (`Loop.hs:306`) — which requires
`AskReplyStore` (hence the extra parameter), builds the session's
ISA registry via `buildIsaRegistry`, and dispatches the opcode
under `Full` autonomy semantics (the operator is the approver by
typing the command).

**Wiring strategy (in-loop construction, chosen over startup
construction):** the dispatcher closure is built **inside
`runChannelLoop`** at `Loop.hs:243` alongside the existing
`registryWithBg` extension. The `bgConvSid :: IORef SessionId`
(created at `Loop.hs:241` inside the loop body, written per-turn at
`Loop.hs:266`) is the `sidRef` the dispatcher closes over. The
`askReply :: AskReplyStore` (parameter to `runChannelLoop` at
`Loop.hs:228`) is in scope at `Loop.hs:243`. The
`registryWithBg` extension list grows from
`[backgroundCommandSpec bgRunner]` to
`[backgroundCommandSpec bgRunner, callCommandSpec dispatcher,
skillCommandSpec (bSkills (cdBackends deps)) dispatcher]`. No
signature change to `runChannelLoop` — the existing `Registry`
parameter at `Loop.hs:226` stays; the dispatcher is constructed in
the `let`-block at `Loop.hs:242-243` where `deps`, `h`, `askReply`,
and `bgConvSid` are all in scope.

This mirrors how `webCallDispatcher` reads `srActive` inside its
body (`Send.hs:518`) and how `bgConvSid` is already written each
turn at `Loop.hs:266`. The per-turn `sid` write at `Loop.hs:266`
flows into the dispatcher's next invocation automatically.

The 4 wiring sites:

- **CLI** (`Seal.Channel.Cli.runCliTui`): already builds
  `callDispatcher` at `Seal.Channel.Cli.hs:556` inside `runCliTui`
  (analogous to in-loop construction — `runCliTui` is the CLI's
  loop-equivalent). Register `skillCommandSpec (bSkills backends)
  callDispatcher` in `registryWithBg` at `Cli.hs:548`. Remove the
  existing `skillCommandSpec` entry from `Tui.hs:161` to avoid
  double-registration. No new dispatcher construction.
- **Web** (`Seal.Command.Serve`): already builds
  `webCallDispatcher sendDeps` at `Seal.Command.Serve.hs:159`. Pass
  the same closure into `skillCommandSpec` at `Serve.hs:154`. No
  new dispatcher construction.
- **Signal** (`Seal.Channels.Signal.Run`): the `registry` built at
  `Signal.Run:287` is passed into `runChannelLoop` as before;
  `runChannelLoop` internally extends it with `/call` + `/skill load`
  via the in-loop `registryWithBg` construction at `Loop.hs:243`.
  No changes to `Signal.Run`'s registry list (the existing
  `skillCommandSpec (bSkills backends)` entry at `Signal.Run:290`
  is **removed** — it's now added inside `runChannelLoop` instead).
- **Telegram** (`Seal.Channels.Telegram.Run`): same as Signal —
  remove the `skillCommandSpec` entry at `Telegram.Run:133-142`; it
  moves into `runChannelLoop`'s `registryWithBg`.

The unified code path: all 4 channels build a `CallDispatcher` and
register both `/call` and `/skill load` against it. The command
implementation (`loadCmd` in `Seal.Command.Skill`) is shared across
all 4. The dispatcher *construction site* varies (CLI builds inside
`runCliTui`; web builds at startup in `Serve`; Signal/Telegram build
inside `runChannelLoop` via the shared `channelCallDispatcher`
helper in `Seal.Channels.Loop`). The `sid` source varies per
channel (`srActive` for CLI/web, cursor-resolved `bgConvSid` IORef
for Signal/Telegram) — unavoidable, but the dispatcher type and the
command spec are uniform.

### 3.6 `/skill` command signature change

`skillCommandSpec` changes from taking `SkillBackend` to taking
`SkillBackend` + `CallDispatcher`:

``` haskell
skillCommandSpec :: SkillBackend -> CallDispatcher -> CommandSpec
skillCommandSpec backend dispatcher = ...
  where
    skillParser = hsubparser
      (  command "list"  ...  -- reads backend directly (no dispatch)
      <> command "info"  ...  -- reads backend directly (no dispatch)
      <> command "load"  (info (loadCmd dispatcher <$> skillArg) ...)
      )
```

`list` and `info` continue to read the `SkillBackend` directly (no
audit-trail entry — they're read-only inspections, not loads). Only
`load` dispatches the opcode. The 4 wiring sites each pass their
`CallDispatcher` into `skillCommandSpec` alongside the
`SkillBackend` they already thread.

### 3.7 Files

| File | Change |
|---|---|
| `src/Seal/ISA/Ops/Skills.hs` | Rename `skillReadOp` → `skillLoadOp`, `SKILL_READ` → `SKILL_LOAD`. Update `toDesc` to "Load one agent skill by id into the current session." Signature unchanged: `SkillBackend -> Opcode`. No new deps (the duplicate-load gate is dropped from v1). |
| `src/Seal/Command/Skill.hs` | Add `load` subcommand. `skillCommandSpec :: SkillBackend -> CallDispatcher -> CommandSpec`. The `load` command builds `{"id":"<name>"}`, invokes the dispatcher, and renders the result via `renderOpResult` (reuse from `Seal.Command.Call`). Echo a header line first (mirror `Seal.Command.Call.echoLine:95`). |
| `src/Seal/Channels/Loop.hs` | Add `channelCallDispatcher :: ChannelDeps -> ChannelHandle -> AskReplyStore -> IORef SessionId -> CallDispatcher` (mirrors `webCallDispatcher` at `Send.hs:516-541`). Construct it inside `runChannelLoop` at `Loop.hs:243` in the `let`-block where `bgConvSid` (created at `Loop.hs:241`) and `askReply` (param at `Loop.hs:228`) are in scope. Extend `registryWithBg` at `Loop.hs:243` from `[backgroundCommandSpec bgRunner]` to `[backgroundCommandSpec bgRunner, callCommandSpec dispatcher, skillCommandSpec (bSkills (cdBackends deps)) dispatcher]`. No signature change to `runChannelLoop`. |
| `src/Seal/Channels/Signal/Run.hs` | **Remove** the `skillCommandSpec (bSkills backends)` entry at `Signal.Run:290` (it's now added inside `runChannelLoop` via `channelCallDispatcher`). The `registry` at `Signal.Run:287` no longer registers `/skill load` or `/call` itself — `runChannelLoop` extends it. |
| `src/Seal/Channels/Telegram/Run.hs` | **Remove** the `skillCommandSpec (bSkills backends)` entry at `Telegram.Run:133-142` (same rationale as Signal). |
| `src/Seal/Channel/Cli.hs` | Update `skillReadOp` → `skillLoadOp` at `Cli.hs:389,462`. Register `skillCommandSpec (bSkills backends) callDispatcher` inside `runCliTui`'s `registryWithBg` at `Cli.hs:548` (alongside the existing `callCommandSpec callDispatcher`). Both `backends` and `callDispatcher` are in scope. |
| `src/Seal/Gateway/Send.hs` | Update `skillReadOp` → `skillLoadOp` at `Send.hs:342,625`. Pass `webCallDispatcher` (already built at `Send.hs:516`) into `skillCommandSpec` in `Seal.Command.Serve`. |
| `src/Seal/Command/Serve.hs` | Pass `webCallDispatcher sendDeps` into `skillCommandSpec` (alongside the existing `bSkills backends`). |
| `src/Seal/Tui.hs` | **Remove** the existing `skillCommandSpec (bSkills backends)` entry at `Tui.hs:161` (it moves into `runCliTui` at `Cli.hs:548` alongside `callCommandSpec`, per Q3 option a — avoids double-registration). |
| `src/Seal/Transcript/Reconstruct.hs` | `harnessPayload:145-158`: always include `"op"` in the base payload (not just the approval branch). |
| `src/Seal/Gateway/Transcript.hs` | `reconEntryToFrontend:283-285`: relax the drop-filter to keep `harness` entries whose `op.name` is in a whitelist (`["SKILL_LOAD"]` for v1). Add `isUserSurfacingOp :: A.Object -> Bool` helper. |
| `src/Seal/ISA/Ops/Registry.hs` | Comment update at `Registry.hs:10`: `OPCODE_DESCRIBE` mirrors the `SKILL_LOAD` pattern (was `SKILL_READ`). |
| `README.md` | Rename `SKILL_READ` → `SKILL_LOAD` in the opcode table at `README.md:233` (verify line with grep at implementation time). |
| `docs/superpowers/plans/2026-07-05-phase-5-audited-stores.md` | Rename `SKILL_READ` → `SKILL_LOAD` at lines 372 and 392 (historical plan doc but lives under `plans/`, in scope per DoD #1). |
| `test/Seal/ISA/Ops/SkillsSpec.hs` | Rename `describe "SKILL_READ"` → `describe "SKILL_LOAD"`. Update opcode construction (`skillReadOp` → `skillLoadOp`). Existing test cases (valid id, missing id, invalid id) unchanged in shape. |
| `test/Seal/ISA/IntegrationSpec.hs` | Rename `SKILL_READ` references at `IntegrationSpec.hs:519-529`. |
| `test/Seal/Phase5Spec.hs` | Update opcode construction at `Phase5Spec.hs:130` (`skillReadOp` → `skillLoadOp`). |
| `test/Seal/Command/SkillSpec.hs` | Add tests for `/skill load`: (a) valid id renders body, (b) missing id reports "skill not found", (c) invalid id reports "invalid skill id", (d) dispatcher returns `Left OpNotFound` (impossible in production but the command should render it gracefully). Use a `CallDispatcher` constructed against a temp-dir `TwoFileHandle` (via `fakeTwoFileTranscript` at `Seal.Handles.Transcript.hs:323` or `withTwoFileTranscript tmpdir`). |
| `test/Seal/Gateway/TranscriptSpec.hs` (or new) | Add tests for the relaxed filter: a `SKILL_LOAD` `EKHarness` entry passes through `reconEntryToFrontend`; a non-whitelisted `EKHarness` entry (e.g. `SHELL_EXEC`) is still dropped; an approval-bearing entry still passes. |
| `test/Seal/Transcript/ReconstructSpec.hs` (or new) | Add a test that `harnessPayload` includes `op` in the base payload (no approval key). |

### 3.8 The `CallDispatcher` reuse

`/call` already takes a `CallDispatcher` (`Seal.Command.Call:44`):

``` haskell
type CallDispatcher = OpName -> Value -> IO (Either DispatchError OpResult)
```

`/skill load` reuses the same dispatcher type — same session, same
transcript, same ISA registry, same audit-trail path. The 4 wiring
sites each build one `CallDispatcher` (CLI and web already do;
Signal and Telegram get `channelCallDispatcher`); both `/call` and
`/skill load` close over it. No new closure per command.

The `CallDispatcher` closes over `srActive` (CLI/web) or the
cursor-resolved `sid` (Signal/Telegram) read fresh per invocation, so
a `/new` swap of `srActive` flows the new `sid` into the next
`/skill load` automatically. (Verified by the architect reviewer:
CLI at `Cli.hs:557`, web at `Send.hs:518` both read `srActive` inside
the dispatcher body.)

## 4. Open questions for the review gate (round 2)

| # | Question | Resolution |
|---|---|---|
| Q1 | Does the rename break any external contract? | `grep -r SKILL_READ` across `src/`, `test/`, `README.md`, and `docs/superpowers/plans/*.md` returns the references enumerated in §3.7 (plus the phase-5 plan at `docs/superpowers/plans/2026-07-05-phase-5-audited-stores.md:372,392` — a historical plan doc, but it lives under `plans/` not `handoffs/`, so it IS in scope for the mechanical rename). This design spec (`docs/superpowers/specs/2026-07-21-skill-load-design.md`) and everything under `docs/handoffs/...` are excluded by design — the spec describes the rename and must reference the old name; the handoffs are immutable snapshots. |
| Q2 | Should the `channelCallDispatcher` close over a `Registry`-builder closure (per-turn rebuild) or over a fixed `Registry` (built once at startup)? | **Neither — in-loop construction with IORef-mirror.** The dispatcher closure is built once per channel-loop invocation, inside `runChannelLoop` at `Loop.hs:243` (in the `let`-block where `bgConvSid` and `askReply` are in scope). Each turn, the loop writes the cursor-resolved `sid` to `bgConvSid` at `Loop.hs:266`. The dispatcher reads the IORef fresh on each invocation and builds a per-session transcript + ISA registry at dispatch time (mirrors `webCallDispatcher` at `Send.hs:518-541`). No signature change to `runChannelLoop`; no per-turn registry rebuild at the loop level. |
| Q3 | Where does the CLI's `callDispatcher` get threaded into `skillCommandSpec`? | **Option (a): move `skillCommandSpec` registration into `runCliTui`** alongside `callCommandSpec` at `Cli.hs:548`. The existing `skillCommandSpec (bSkills backends)` entry in `Tui.runTui`'s registry list at `Tui.hs:161` is **removed** to avoid double-registration. Both `backends` and `callDispatcher` are in scope at `Cli.hs:548`. This mirrors how `/call` is already registered inside `runCliTui`, not in `Tui.runTui`'s list. |
| Q4 | Is the frontend whitelist `["SKILL_LOAD"]` the right v1 scope? | Yes. Future opcodes that should surface to the user (e.g. a future `SESSION_NEW` if it becomes an opcode) get added to the whitelist. The whitelist is intentionally narrow to avoid accidentally surfacing internal opcodes (e.g. `SHELL_EXEC` invocations shouldn't appear as standalone bubbles in the chat history). |
| Q5 | Should the `op` field in `harnessPayload` be `Maybe Value` (current approval branch) or always-present? | Always-present, as `Maybe Value`: `"op" .= (Map.lookup "op" (erMeta e) :: Maybe Value)`. Entries without an `op` meta key (none currently, but defensive) serialize `"op": null`. The frontend treats `null` as "no op metadata" and renders accordingly. |
| Q6 | What's the v2 plan for the duplicate-load gate? | Deferred. v2 will add: (a) a `Maybe ChannelCaps` parameter to `skillLoadOp` (`Nothing` for child registries — exempts delegated agents); (b) a "recently declined" cache mirroring `Seal.Handles.AskReply`'s approval cache so the agent can't re-prompt every turn; (c) a scan cap or index over `entries.jsonl` (which is uncompacted — only `conversation.jsonl` is compacted) so the O(n) scan doesn't grow with session length; (d) the token-distance + context-window-percentage prompt text. |

## 5. DoD (Definition of Done)

1. `SKILL_READ` is renamed to `SKILL_LOAD` everywhere in `src/`,
   `test/`, `README.md`, and live docs under `docs/superpowers/`;
   `grep -r SKILL_READ src/ test/ README.md docs/superpowers/plans/`
   returns zero hits (historical `docs/handoffs/...` and this design
   spec `docs/superpowers/specs/2026-07-21-skill-load-design.md`
   retain the old name — the spec as a design record describes the
   rename and must reference the old name; the handoffs are
   immutable historical snapshots).
2. `/skill load <id>` with a valid id renders the skill body to the
   channel via `ccSend` (with an echo header line first) and records
   an `EKHarness` entry with `erMeta.op.name = "SKILL_LOAD"`,
   `erMeta.input.id = <id>`.
3. `/skill load <id>` with a missing id reports "skill not found:
   <id>" (existing `SKILL_LOAD` behavior, unchanged by rename).
4. `/skill load <id>` with an invalid id reports "invalid skill id:
   ..." (existing behavior).
5. `/skill load` works on all 4 channels (CLI, web, Signal,
   Telegram). On inbox channels (Signal, Telegram), the dispatcher
   resolves `sid` per turn from the conversation cursor and
   dispatches against the session's transcript + ISA registry.
6. The agent-invoked `SKILL_LOAD` tool call works unchanged (pure
   rename); the agent's tool description updates to "Load one agent
   skill by id into the current session."
7. The web frontend renders a `SKILL_LOAD` `EKHarness` entry as a
   distinct harness entry (not dropped by the filter), carrying its
   `op.name` and `input.id` in the payload. Non-whitelisted
   `EKHarness` entries (e.g. `SHELL_EXEC`) are still dropped by the
   filter. Approval-bearing entries still pass through unchanged.
8. `make check` (`cabal build` + `cabal test` + `hlint` with
   `-Werror`) passes.
9. All new and renamed tests pass:
   - `test/Seal/ISA/Ops/SkillsSpec.hs` covers `SKILL_LOAD` valid id,
     missing id, invalid id.
   - `test/Seal/Command/SkillSpec.hs` covers `/skill load` valid id
     (renders body + echo header), missing id, invalid id,
     dispatcher-Left graceful render.
   - `test/Seal/Gateway/TranscriptSpec.hs` (or new) covers the
     relaxed filter: `SKILL_LOAD` passes, `SHELL_EXEC` drops,
     approval-bearing passes.
   - `test/Seal/Transcript/ReconstructSpec.hs` (or new) covers
     `harnessPayload` including `op` in the base payload.

## 6. Human checkpoints

- **After round 2 design review gate** — pause for user to read the
  5 reviewers' notes and adjust before planning.
- **After plan review gate** — pause for user to read the 3
  reviewers' PASS/FAIL before implementation begins.
- **After implementation passes `make check`** — pause for user
  review before opening a PR.

## 7. Implementation phasing (RED-GREEN)

| Phase | RED (write failing test first) | GREEN (implement) |
|---|---|---|
| 1. Mechanical rename | Rename `describe "SKILL_READ"` → `describe "SKILL_LOAD"` in `SkillsSpec.hs`, `IntegrationSpec.hs`; update `Phase5Spec.hs` opcode construction. Tests fail to compile. | Rename `skillReadOp` → `skillLoadOp`, `SKILL_READ` → `SKILL_LOAD` in `src/Seal/ISA/Ops/Skills.hs`. Update all call sites (`Channels/Loop.hs:566,696`, `Gateway/Send.hs:342,625`, `Channel/Cli.hs:389,462`). Update `Registry.hs:10` comment. Update `README.md:233` opcode table. Update `docs/superpowers/plans/2026-07-05-phase-5-audited-stores.md:372,392`. Tests compile and pass. |
| 2. `skillCommandSpec` signature change | Add a failing test in `SkillSpec.hs` that calls `skillCommandSpec backend dispatcher` with a mock dispatcher (returns `Right (OpResult [TrpText "body"] False ...)`). Test fails to compile (arity mismatch). | Change `skillCommandSpec :: SkillBackend -> CommandSpec` to `SkillBackend -> CallDispatcher -> CommandSpec`. Add `loadCmd dispatcher <$> skillArg` subparser. For CLI: move `skillCommandSpec` registration into `runCliTui`'s `registryWithBg` at `Cli.hs:548` alongside `callCommandSpec`, and **remove** the `skillCommandSpec` entry from `Tui.hs:161`. For web: pass `webCallDispatcher sendDeps` into `skillCommandSpec` in `Serve.hs:154`. For Signal/Telegram: **remove** the `skillCommandSpec` entry from `Signal.Run:290` and `Telegram.Run:133-142` (they'll be re-added inside `runChannelLoop` in phase 3). Phase 2 leaves Signal/Telegram without `/skill load` until phase 3 wires `channelCallDispatcher`. Tests pass (CLI + web only at this phase). |
| 3. `channelCallDispatcher` for inbox channels | Add a failing integration test (in a new `test/Seal/Channels/LoopSpec.hs` or extend an existing one) that constructs a `ChannelDeps` with a fake channel handle + a `sid :: IORef SessionId` primed with a known `SessionId` + a fake `AskReplyStore`, calls `channelCallDispatcher deps h askReply sidRef opName val`, and asserts the dispatcher records an `EKHarness` entry to the session's transcript + returns the opcode's `OpResult`. Test fails to compile (function doesn't exist). | Implement `channelCallDispatcher :: ChannelDeps -> ChannelHandle -> AskReplyStore -> IORef SessionId -> CallDispatcher` in `Seal.Channels.Loop`. Mirror `webCallDispatcher` (`Send.hs:516-541`): read `sid` from the IORef fresh, build `ChannelCaps` via `mkHandleCaps h askReply sid` (the same helper used at `Loop.hs:306-313` for slash-command caps), open the session's transcript via `withTwoFileTranscript`, build the ISA registry via `buildIsaRegistry`, dispatch under `Full` autonomy. Construct the dispatcher inside `runChannelLoop` at `Loop.hs:243` in the `let`-block (alongside `bgRunner` and `registryWithBg`), closing over `deps`, `h`, `askReply`, and `bgConvSid`. Extend `registryWithBg` to include `callCommandSpec dispatcher` + `skillCommandSpec (bSkills (cdBackends deps)) dispatcher`. The per-turn `writeIORef bgConvSid sid` at `Loop.hs:266` flows the cursor-resolved sid into the dispatcher's next invocation. Tests pass on all 4 channels. |
| 4. Web frontend filter | Add a failing test in `test/Seal/Gateway/TranscriptSpec.hs` (or new): construct an `EKHarness` `EntryRecord` with `erMeta.op.name = "SKILL_LOAD"`, no `approval` key; reconstruct; assert `reconEntryToFrontend` returns `Just ...` (not `Nothing`). Test fails (filter drops the entry). Also add a test that `SHELL_EXEC` entries are still dropped. Add `harnessPayload` test in `test/Seal/Transcript/ReconstructSpec.hs` (or new): assert `op` is in the base payload (no approval key). | Relax the filter at `Transcript.hs:283-285` with the `isUserSurfacingOp` predicate against a module-level `userSurfacingOps :: Set.Set Text` (v1: `Set.fromList ["SKILL_LOAD"]`). Update `harnessPayload` at `Reconstruct.hs:145-158` to always include `"op" .= (Map.lookup "op" (erMeta e) :: Maybe Value)` in the base payload. Tests pass. |
| 5. `/skill load` command tests | Add failing tests in `SkillSpec.hs` that build a real `CallDispatcher` against a temp-dir `TwoFileHandle` (via `fakeTwoFileTranscript` at `Seal.Handles.Transcript.hs:323` or `withTwoFileTranscript tmpdir`): (a) `/skill load greet` with a preloaded `greet` skill renders the body + the echo header line `$ /skill load greet`; (b) `/skill load nope` reports "skill not found: nope"; (c) `/skill load bad/id` reports "invalid skill id: ..."; (d) dispatcher returns `Left (OpNotFound ...)` renders gracefully via `renderDispatchError`. Tests fail (no `load` subcommand yet). | Implement `loadCmd :: CallDispatcher -> Text -> CommandAction` in `Seal.Command.Skill.hs`. Echo header line first (`"$ /skill load <id>"`), then `renderOpResult` (reused from `Seal.Command.Call`) on `Right` and `renderDispatchError` on `Left`. Tests pass. |
| 6. `make check` gate | n/a | `make check` (build + test + lint with `-Werror`) passes. |

## 8. Risks

- **`channelCallDispatcher` dispatch-time cost.** The dispatcher
  opens the session's transcript and builds the ISA registry on each
  invocation (mirrors `webCallDispatcher` at `Send.hs:516-541`).
  This only runs when `/call` or `/skill load` is invoked, not on
  every plain turn, so the cost is amortized. Acceptable.
- **Frontend filter whitelist maintenance.** The whitelist
  `["SKILL_LOAD"]` is a new piece of shared state between the ISA
  opcodes and the frontend renderer. Adding a new user-surfacing
  opcode requires updating both the opcode and the whitelist. The
  whitelist is intentionally narrow; a follow-up could derive it
  from an opcode-level `toUserSurfacing :: Bool` flag.
- **Rename is a breaking change for any external consumer of the
  `SKILL_READ` opcode name.** Seal is currently single-repo with no
  external opcode consumers (the ISA is internal); the rename is
  mechanical across `src/` and `test/`. Flagged in Q1.
- **Audit-trail shape change.** `harnessPayload` now always includes
  `op` in the base payload (was: only in the approval branch). This
  is a new key in the base payload. Existing readers of
  `entries.jsonl` that don't know about `op` will ignore it (aeson's
  `parseJSON` ignores unknown keys by default). No migration needed;
  old transcripts remain readable.
- **v2 duplicate-load gate is deferred.** The user explicitly
  accepted that v1 has no duplicate detection. An agent (or user)
  can invoke `SKILL_LOAD` for the same skill repeatedly with no
  prompt, AND can invoke `SKILL_LOAD` for many *different* skills in
  one turn (flooding the conversation with multiple skill bodies).
  Both behaviors are pre-existing `SKILL_READ` behaviors (no gate
  today), so v1 is no worse than the status quo. The audit trail
  records each invocation; the conversation accumulates each body.
  v2 adds the gate with the mitigations in Q6.

## 9. v2 deferred scope (out of v1)

- Duplicate-load confirmation gate (per-session, per-skill-id).
- Token-distance + context-window-percentage prompt text.
- "Recently declined" cache (mirror `AskReply` approval cache) so
  the agent can't re-prompt every turn.
- Scan cap or index over `entries.jsonl` (uncompacted) so the O(n)
  scan doesn't grow with session length.
- `Maybe ChannelCaps` parameter to `skillLoadOp` for child-agent
  exemption (`Nothing` for child registries).
- Dedicated frontend "skill loaded" badge component (v1 surfaces the
  raw `op.name` + `input.id`; v2 renders a styled badge).
- Frontend `isUserSurfacingOp` whitelist growth: v2 should derive
  the whitelist from an opcode-level `toUserSurfacing :: Bool` flag
  (or equivalent) rather than maintaining a hardcoded `Set` in the
  transcript renderer, so adding a user-surfacing opcode doesn't
  require touching two modules.