# Metaswarm Sub-Agent Orchestration Support

**Date**: 2026-09-10 · **Status**: draft v6 (gate: 5/5 approved w/ minor revisions, applied; §0 item 3 corrected; §3.4 alternatives note added; §4.1 mini-metaswarm e2e fixture added) · **Branch**: `docs/metaswarm-support-design`

## Design review gate (round 1 → round 2)

Round 1 ran 5 reviewers (PM, Architect, Designer, Security, CTO) in
parallel. The PM run failed to produce output (subagent failure — not a
verdict; re-running). Architect / Designer / Security / CTO:
NEEDS_REVISION. Resolutions:

- **§3.2 mechanism was wrong as stated** (Architect B1, CTO B1, Security Q4):
  `AGENT_START` is not "retained" for orchestrator children — it is
  *absent* from `buildChildRegistry`'s `childBaseOps` entirely
  (`TurnEngine.hs:319-342`). Un-blocklisting alone yields no op. The fix
  is to **add** a role-conditioned `agentStartOp` to the child base ops,
  wired with a complete nested `AgentStartWiring` whose `aswParentDepth`
  is the child's depth. §3.2 rewritten; W2/W3 merged (W2) because the
  blocklist change and the depth plumb are structurally inseparable.
- **Two hardcoded depth zeros, not one** (Architect Q1, Security Q4, CTO B1):
  `buildStartWiring:905` is CORRECT for top-level parents (depth 0);
  the actual gaps are `buildWorker`'s `dwdParentDepth = 0` (`:942`,
  currently a dead field — nothing consumes it) and the missing child-side
  wiring. §3.2 now names the full plumb.
- **`ctRole` widening** (Architect B3, Security B1): per-task role could
  widen a leaf def to orchestrator — a model-controlled escalation path
  that contradicts §5. Decision: **the def is authoritative; per-task
  `ctRole` may only NARROW** (orchestrator→leaf). §3.1 rewritten.
- **`registerChild` hardcodes `depth = 0`** (Architect S1, Security S3,
  CTO B2): contradicted §3.2's "transcript records every level" claim.
  Fix folded into W2 + a recorded-depth test added.
- **Workdir defs invisible to children** (Architect B2, CTO Q1): child
  registry and `childSystemPrompt` use `tdBaseBackends` (user store only),
  so a grandchild spawn of a repo-shipped def fails with "agent def not
  found". §3.6 now threads the workdir ⊕ user union into the child path.
- **`description` is an unsanitized injection surface** (Security B2): the
  "4KB-per-field cap" I cited does not exist (4096 is the whole-catalog
  budget, `Skills/Prompt.hs:33`). §3.1 now mandates per-field validation
  (single line, control chars stripped, catalog-fence tokens rejected) at
  decode AND `AGENT_DEF_WRITE`.
- **Leaf children would see a catalog of agents they cannot spawn**
  (Designer B1): §3.4 now gates the child-side catalog on spawn capability
  and adds a leaf-role line, plus explicit error messages for the three
  spawn-failure causes (Designer B2).
- **Test gaps** (Architect S3, CTO S1–S3, Security Q1): batch-mode
  orchestrator test, 3-level depth-chain test (`max_spawn_depth = 2`),
  unknown-tool-drop unit test, kill-switch at dispatch, child-prompt
  kill-switch coverage, and grandchild-spawn pulled into W2's exit
  criteria. §3.7 updated.
- **`narrowAllowList` must be role-aware too** (Security S1): an
  `AllowOnly` orchestrator def listing `AGENT_START` would otherwise
  silently lose it while an `AllowAll` one keeps it. §3.2 covers both
  chokepoints.
- **Kill switch TOCTOU** (Security S2): `runDelegate` re-checks
  `orchestrator_enabled` per-spawn (it already computes and discards it).
- **Concurrency-cap interplay** (CTO S1): documented in §5 — grandchildren
  run inside the semaphore slot their parent holds, so effective
  parallelism can exceed the cap; documented + bounded by depth.
- **Frontend implications** (Designer S5): noted as follow-up issues, not
  in scope.
- **Pre-existing finding**: `AGENT_DEF_WRITE` is `Trusted`, not `Audited`
  (Agent.hs:135-137) despite the module header's claim (Security Q3) —
  filed as a separate follow-up issue, out of scope here.

Round 2 verdicts: **5/5 APPROVED WITH MINOR REVISIONS** (PM, Architect,
Designer, Security, CTO). Minor revisions applied in v3:

- **Leaf-error mechanism reconciled** (Designer B3, CTO item 5):
  `AGENT_START` is ALWAYS PRESENT in child registries as a
  role/switch-conditioned op whose `authorize` fails with the dedicated
  message for leaf children / kill-switch-off (option (a) — recommended
  by CTO; also closes the TOCTOU window at the op boundary). §3.2
  rewritten; tests 11–12 unchanged.
- **Depth wording fixed** (CTO item 4): `aswParentDepth = threaded
  dwdParentDepth + 1` (= the child's own depth). §3.2 item 3 reworded.
- **Kill-switch dispatch check location named** (Architect item 4,
  Security item 8): the effective-role check lives in/next to
  `resolveTask` (the def is in hand there), not inside `runDelegate`
  proper. §3.2 item 5 rewritten; test 12a (dispatch) assigned to W2,
  12b (prompt gating) to W3 (Architect item 5).
- **§3.3 intersection added to W2's item list** (Architect item 6).
- **Stub-seam threading specified** (CTO item 6): `tdMkWorker`'s
  `AgentWorkerBuilder` seam is honored by the nested wiring too (the
  re-anchored builder composes the override: production =
  `buildWorker …`, tests = the injected stub for EVERY level, incl.
  grandchildren). Test 8 note updated.
- **Concurrency claim corrected** (Security item 9): `bracketSem`
  (`Delegation.hs:501-506`) is a single-token MVar, not a counting
  semaphore — effective parallelism is 1 today; the note now states the
  true current bound. §3.6 step 6 + §5 corrected.
- **Catalog budget note** (PM Q1): with 256-char description caps and
  repo-prefixed ids, ~19 agents can approach 4KB; truncation is
  observable via `AGENT_DEF_LIST` (which stays complete), and the
  renderer's truncation marker names the elided count. PM Q1 wording
  added to §3.4.
- **Defaults stated** (PM Q2): `orchestrator_enabled` defaults TRUE
  (existing resolved default) and `available_agents` defaults TRUE —
  orchestration capability only activates for defs that declare
  `role: orchestrator`, so leaf-only deployments see no behavior change
  except the catalog/`registerChild`-depth improvements. §3.4 + §1.0
  updated.
- **Real-provider smoke added** (PM S1) and **allow-list behavior-change
  changelog note** (PM S2) to W4.
- **Test 6 pins the id form** (Designer S1): catalog bullets always use
  the full (workdir-prefixed) merged-backend id. §3.4 updated.
- **Stale doc comments** (Architect item 7): the `role` in-schema
  description ("Per-task role beats the top-level one",
  `Agent.hs:391-393`) and `ctRole` doc (`Delegation.hs:253-255`) get
  corrected in W1's file scope.
- **Kill-switch message retry hint** (Designer Q1): message appends
  "Re-trying will not succeed until the operator re-enables it."
- **provider/model validators** (Security item 10): optional, folded into
  the §3.1 validator set (cheap, closes the AGENT_DEF_LIST tool-result
  injection vector).

## 0. Problem Statement

Metaswarm-style orchestration (issue → epic → work-unit decomposition →
parallel specialist agents → review gates → PR) does not run correctly on
Seal Harness today. A session that loads the `start-task` skill/command and
tries to orchestrate fails in four specific ways:

1. **Children cannot orchestrate.** `buildChildRegistry`
   (`TurnEngine.hs:310-317`) filters `childBaseOps` through
   `filterBlocklisted` — but `childBaseOps` doesn't contain `AGENT_START`
   at all, and `role` is parsed into `ctRole` (`Delegation.hs:252`) yet
   **never read** — no code dispatches on it. The `issue-orchestrator`
   agent's entire job is spawning sub-agents, so its delegation is
   impossible.
2. **Tool allow-lists are not enforced.** Metaswarm agent profiles declare
   `tools:` frontmatter, but `buildChildRegistryAdapter`
   (`TurnEngine.hs:971`) discards the `AgentDef` (`_def`) and builds every
   child the same full registry. An agent that declares "read-only
   research" can still write files.
3. **Agents are surfaced actively only.** `AGENT_DEF_LIST` and
   `SKILL_LIST` DO make the information accessible — but asymmetrically:
   skills are surfaced *passively* (the `<available_skills>` catalog is
   injected into the system prompt every turn by
   `injectAvailableSkills`), while agent defs are surfaced only *actively*
   (the model must already know to call `AGENT_DEF_LIST` and spend a
   turn probing; nothing in the prompt hints that repo-shipped agents
   exist). Workdir defs also carry repo-prefixed ids
   (`seal-harness--coder-agent`) discoverable only through that call. The
   fix is passive-surfacing parity with skills (§3.4), not new
   information access.
4. **Defs are not role-aware.** `decodeAgentDef`
   (`src/Seal/Agent/Def/Workdir.hs:273`) drops `role` and `description`
   frontmatter entirely — same gap the repo-agents-dropdown design noted
   (§3.3: "`role` is ignored").

### 1.0 User stories

1. **Operator** — a session bound to `issue-orchestrator` delegates to
   `coder-agent`, `test-automator-agent`, `code-review-agent` (batch
   `AGENT_START`), each child running to completion with its declared
   tool set — so a large feature is implemented by a coordinated swarm.
2. **Operator** — an orchestrator child may itself spawn (e.g.
   orchestrator → swarm-coordinator → specialist), bounded by
   `delegation.max_spawn_depth`; every level's transcript nests under its
   parent and the runtime registry records the true depth.
3. **Model (any session)** — sees the available agent defs in its system
   prompt (id + description + role), so it picks the right specialist
   without probing.
4. **Repo author** — a repo ships `.agents/agents/<role>/agent.md`
   profiles; clones get the same orchestration semantics, and repo-shipped
   orchestrators can spawn repo-shipped specialists.

### 1.1 Success metrics

- The 17-invariant gateway suite (`AgentIntegrationSpec`) plus the new
  invariants pass with `make check`.
- A scripted end-to-end conversation: parent orchestrates 2 specialist
  children (batch), one child spawns a grandchild, results return JSON,
  `AGENT_INSTANCES` shows both children with correct depths.
- A 3-level chain is rejected by `max_spawn_depth = 2` with a message
  naming current vs max depth.
- (W4 exit item) A real-provider smoke OR a documented manual checklist:
  bind `issue-orchestrator`, give it a small task, confirm it delegates
  to a specialist and the specialist completes — the scripted seam
  proves wiring; this proves usability of the catalog + spawning flow.

## 2. Non-Goals

- **No new opcodes.** Everything is expressible with `AGENT_DEF_*` +
  `AGENT_START`. The ISA GADT does not change.
- **No async/background delegation.** `AGENT_START` stays synchronous.
- **No BEADS/Dolt integration** (`bd` already works via `BIN_EXEC` when
  the binary exists on the executor).
- **No transcript-format changes** — child transcripts already nest under
  `<parent>/agents/<child-id>`.
- **No frontend work** (role badges, delegation-tree view) — follow-up
  issue.
- **Clean-room**: no metaswarm code is copied; metaswarm is just a
  consumer profile shape (frontmatter `role`/`description`/`tools`).

## 3. Design

### 3.1 Role and description are first-class def fields

`AgentDef` gains `adRole :: Maybe Text` and `adDescription :: Maybe Text`.
`adRole` ∈ {`"orchestrator"`, `"leaf"`, `Nothing` ≡ leaf}.

- `decodeAgentDef` (flat, `Workdir.hs:273`) and `decodeProtocolAgentMd`
  (protocol) set both fields. `AGENT_DEF_WRITE` accepts optional
  `role` + `description` (validate: role ∈ {orchestrator, leaf} if
  present — else authorize error; non-permissive because role gates
  spawning). `AGENT_DEF_LIST` output text includes role; recorded JSON
  gains `roles`.
- DirScheme defs (SOUL.md-style bootstrap) cannot express role or
  description in frontmatter today — documented limitation; they decode as
  leaf with no description. (Extending `DirAgentConfig` is a follow-up.)
- **Per-field validation (injection defense).** `description` and `name`
  (and `group`) are rendered into system prompts by §3.4, so BOTH decode
  paths and `AGENT_DEF_WRITE` enforce:
  - single line: newlines/carriage returns replaced with spaces;
  - control characters (C0) stripped;
  - the literal tokens `</available_agents>`, `</available_skills>`,
    `---`, and `---`-fence prefixes rejected (replaced with `_`) so a
    def cannot close/forge the catalog block or forge frontmatter on
    re-encode (`renderFrontmatter`, `Store/Markdown.hs:104-106`);
  - per-field length cap: 256 chars for `role`/`description`/`group`
    (names may be longer — 1KB), truncating with the existing
    `truncateSection` marker.
  This is enforced in pure validators shared by both codecs and the
  opcode (single chokepoint each).
- `encodeAgentDef` round-trips both fields for the user store.

**Effective role** (the only dispatch input for §3.2):
`adRole` (def-authoritative). Per-task `ctRole` may only **narrow**: an
explicit `role: "leaf"` on a task downgrades an orchestrator def's child
to leaf; any other `ctRole` value on an orchestrator def is IGNORED
(not widened). A leaf def can never be widened by task input. Rationale:
spawning capability must come from the def author (or operator), never
from the model's per-call input. `ctRole` remains in the schema for
back-compat (it already parses); its semantics change from
"override" to "narrow-only".

### 3.2 Orchestrator children get a role-conditioned nested AGENT_START

`buildChildRegistry` currently builds `childBaseOps` WITHOUT
`AGENT_START` and filters via `filterBlocklisted`. The change:

1. **`dwdChildRegistry` signature grows**: `AgentDef` (already passed),
   plus the child's effective role and the child's delegation depth —
   `mkDelegateWorker` must CONSUME `dwdParentDepth` (today a dead field,
   hardcoded 0 at `TurnEngine.hs:942`) and pass it to
   `dwdChildRegistry`.
2. **Role-aware blocklist** (pure, unit-tested):
   `childBlocklist :: Maybe Text -> Bool -> Set OpName` —
   - leaf role OR kill switch off ⇒ full `delegationBlocklist`;
   - orchestrator + enabled ⇒ `delegationBlocklist` minus `AGENT_START`.
   Applied at BOTH chokepoints: `filterBlocklisted` on the ops list AND
   `narrowAllowList` on `AllowOnly` def tools (Security S1 — otherwise an
   `AllowOnly` orchestrator def listing `AGENT_START` silently loses it
   while `AllowAll` keeps it).
3. **Nested role-conditioned `AGENT_START` (always present, role-gated)**:
   the child registry ALWAYS includes `agentStartOp`, wired with a fresh
   child-side `AgentStartWiring`:
   - `aswDefBackend` = the SAME workdir ⊕ user union backend the parent
     session had (§3.6),
   - `aswRuntime`, `aswPauseFlag`, `aswParentActivity` = process-global
     handles (already on `Backends`),
   - `aswConfig` = the same per-call config loader,
   - `aswMintSession` = mint rooted at the CHILD's sid (grandchild
     transcripts nest under `<child>/agents/<grandchild>`),
   - `aswParentDepth` = threaded `dwdParentDepth` **+ 1** (= the child's
     own depth; CTO item 4 wording),
   - `aswWorker` = the re-anchored worker-builder, which COMPOSES the
     `tdMkWorker` override (production = `buildWorker …` re-anchored to
     the child's sid/depth; tests = the injected stub at EVERY level,
     including grandchildren — the seam must thread through the nested
     wiring, not be silently dropped).
   The op's `authorize`/`run` gates on the effective role + kill switch:
   - orchestrator + enabled ⇒ operates normally (depth check per level);
   - leaf OR kill-switch off ⇒ rejects with the DEDICATED message
     (§3.2 item 6) — the op is present but unusable, so the error is
     distinguishable rather than unknown-tool (Designer B3, CTO item 5);
     this also closes the TOCTOU window at the op boundary, with
     `runDelegate`/`resolveTask` as the second gate (item 5).
4. **Depth enforcement**: `runDelegate`'s existing
   `parentDepth >= maxDepth` check (`Delegation.hs:463`) applies at every
   level once depth threads correctly. `buildStartWiring`'s
   `aswParentDepth = 0` is correct for top-level sessions and unchanged;
   the plumb is `buildStartWiring` (top-level: 0) → `buildWorker` →
   `dwdParentDepth` → `dwdChildRegistry` → nested wiring `+1`.
5. **Kill switch + effective role at the resolver (dispatch-time gate)**
   (Security S2, Architect item 4, Security item 8): the per-spawn
   effective-role check lives in/next to `resolveTask` — the def is in
   hand there, which is the only place the effective role is computable
   (the resolver currently ignores `_parentDepth`; its `Either` returns
   the "agent def not found"-class errors, and the kill-switch/leaf
   rejection joins that error path). `runDelegate` already computes
   `orchEnabled` and discards it (`_orchEnabled`) — the resolver
   receives it and rejects an orchestrator-effective spawn while
   `orchestrator_enabled = false`, closing the TOCTOU window for
   long-running orchestrator children (retries are futile until the
   operator re-enables — see message below).

Error messages are explicit and distinguishable (Designer B2):
- **Depth**: `"Delegation depth limit reached (depth=<n>, max_spawn_depth=<m>)…"`
  (existing message, already names both numbers — surfaces to the parent
  via `ChildResult`'s error field).
- **Leaf**: `"AGENT_START is not available to this agent: its definition is a leaf (role: leaf). Ask the operator to grant the orchestrator role if delegation is required."`
- **Kill switch**: `"Delegation spawning is disabled: delegation.orchestrator_enabled = false. Re-trying will not succeed until the operator re-enables it."`
- **Spawn-pause** (existing): unchanged message.
Leaf/kill-switch both produce a dedicated error result rather than
OpNotFound, so the parent transcript distinguishes all four causes.

### 3.3 Def tool allow-lists are enforced as an intersection

`buildChildRegistryAdapter` stops discarding the def and intersects:

- `AllowOnly set` ⇒ child registry = baseOps ∩ set (minus role-aware
  blocklist); `AllowAll` ⇒ full base registry (current behavior).
- Blocklist applied AFTER the allow-list (blocklist wins — §3.2).
- Unknown `tools:` names silently drop (intersection semantics) — and
  `AGENT_DEF_WRITE`'s recorded payload notes unrecognized names so a
  typo is discoverable in the audit trail (Designer S4).
- QuickCheck property: child registry op-name set ⊆ base-op-name set,
  and ∩ blocklist = ∅, for any `AllowList` and any effective role.

### 3.4 `<available_agents>` catalog injection

New `injectAvailableAgents` (mirroring `injectAvailableSkills` in
`Seal.Skills/Prompt.hs`):

- Rendered from `adbList` on the per-turn (workdir ⊕ user) backend: one
  bullet per def — `- <id>: <description>` (skills' exact bullet form;
  description is the primary text, falling back to `adName` when
  description is absent), grouped by `adGroup` with `## <group>` headers,
  role appended in brackets when present:
  `- <id> [<role>]: <description>`. Bullets ALWAYS use the full
  merged-backend id (workdir-prefixed where applicable) — deterministic
  regardless of grouping (Designer S1). Closing nudge line (mirroring the
  skills block): `"Delegate with AGENT_START using an id before relying on an agent."`
- **Budget 4096 chars** (matching the skills catalog — with repo-prefixed
  ids, 19 metaswarm agents sit right at a 2KB cap and would silently
  truncate; 4KB fits them comfortably, though with 256-char description
  caps the rendering can approach 4KB — truncation is observable via the
  renderer's elided-count marker, and `AGENT_DEF_LIST` always stays
  complete so no def is unreachable), truncation via `truncateBlock`.
- **Defaults** (PM Q2): `orchestrator_enabled` defaults TRUE and
  `available_agents` defaults TRUE (mirroring existing resolved
  defaults). Spawning only activates for defs that declare
  `role: orchestrator`, so leaf-only deployments see no behavior change
  beyond the catalog and corrected depth recordings.
- **Considered alternatives** (rejected, with rationale — cross-codebase
  survey of OpenCode, Hermes, and Claude Code):
  - *Tool-description catalog* (OpenCode): the roster is appended to the
    `task` tool's description per request (`tool/registry.ts:260-273`).
    Saves system-prompt tokens but diverges from Seal's existing
    skills convention (system-prompt injection) and puts the roster in
    a place the transcript's System Prompt preamble doesn't show.
  - *Diff-based meta attachments* (Claude Code): the roster arrives as
    `agent_listing_delta` / `skill_listing` user-role messages,
    diff-announced only when the set changes (most token-efficient for
    long sessions). Requires an announcement-tracking mechanism across
    compaction/replay that Seal's per-turn prompt assembly doesn't have
    today; better as a future optimization than a v1 dependency.
  - *Generic delegation, no personas* (Hermes): one `delegate_task` tool
    with toolset scoping, no named agent defs — rejected because
    metaswarm's value is precisely the named-specialist roster
    (orchestrator → coder-agent → …) and Seal already has the def
    store.
- Appended AFTER `<available_skills>` in BOTH prompt paths
  (`resolveSystemPrompt`, `childSystemPrompt`).
- **Child gating** (Designer B1): injected into a CHILD's prompt only when
  that child's registry retains `AGENT_START` (orchestrator + kill switch
  on); a leaf child instead gets a one-line role note
  (`"You are a leaf agent; delegation is not available."`) so the model
  does not waste turns trying. The effective-role predicate is already
  computed at registry-build time (§3.2); `childSystemPrompt` receives it
  (its signature gains the effective role + capability flag — the plumb
  exists since `dwdChildSystemPrompt` already receives the def).
- Config kill switch: `[runtime] available_agents = false` disables
  injection (mirrors `available_skills`).

### 3.6 End-to-end wiring (revised)

1. Parent `AGENT_START {id: issue-orchestrator, goal: ...}` —
   `resolveTask` resolves against the per-turn workdir ⊕ user union
   backend (already wired at depth 0).
2. `mkDelegateWorker` passes `dwdParentDepth` (now consumed) + effective
   role into `dwdChildRegistry`; the adapter builds the child registry
   (§3.2/§3.3) and, for orchestrators, the nested `AgentStartWiring`.
3. **Child backends = workdir ⊕ user union.** The nested wiring's
   `aswDefBackend` and the child prompt's `adbList` source use the same
   union backend the parent session constructed in `callDispatcher` /
   `runTurnBody` (`TurnEngine.hs:821-826`) — currently children get
   `tdBaseBackends` (user store only), which breaks repo-shipped defs for
   grandchildren (Architect B2, CTO Q1). The per-turn union backend is
   threaded through `DelegationWorkerDeps` (new field) so the child sees
   repo-shipped orchestrators AND repo-shipped specialists.
4. Child `runTurn` sees `<available_agents>` (§3.4), calls `AGENT_START`
   with sub-tasks; `runDelegate` runs at childDepth+1; depth cap applies.
5. `registerChild` records `depth = wiring depth + 1` (fixes the
   `depth = 0` hardcode at `Agent.hs:510`), so `AGENT_INSTANCES` and the
   audit trail show true tree positions (CTO B2).
6. Concurrency note (CTO S1, corrected by Security item 9): `bracketSem`
   (`Delegation.hs:501-506`) is a single-token MVar, not a counting
   semaphore — effective parallelism is 1 today, so the cap is not
   exceeded (the claim was wrong in the safe direction). The note
   documents the true bound; if the semaphore is later fixed to a real
   counting semaphore, the nested-spawn-inside-slot behavior must be
   re-examined before raising the cap.

Remote mode: no new local-FS reads. The union backend's workdir half
already flows through `WorkdirFs` + the content-addressed meta cache in
remote mode (the same `cachedWorkdirScan` result the parent uses); the
nested wiring reuses that scan result — no new control-plane executor
reads beyond what def resolution does today.

### 3.7 Test strategy (minimal + integration)

**Unit (pure, fast):**

1. Role/description round-trip (encode/decode, flat + protocol schemes);
   DirScheme still decodes leaf (documented).
2. `AGENT_DEF_WRITE` accepts {orchestrator, leaf, absent}, rejects
   others; recorded payload notes unknown `tools:` names.
3. Per-field validators: newlines/control-chars/fence tokens rejected;
   per-field caps truncate. QuickCheck: no `</available_agents>` or
   newline survives validation into an encoded def.
4. `childBlocklist` pure table: leaf ⇒ full; orchestrator+enabled ⇒
   minus AGENT_START; orchestrator+disabled ⇒ full.
5. Tool intersection property (§3.3).
6. Catalog renderer: empty ⇒ no block; N defs ⇒ N bullets, id-first,
   role suffix; budget truncation at 4096; group headers; nudge line.
7. Effective-role resolver: def-authoritative; `ctRole` narrows only.

**Integration (gateway API harness, stub-worker seam):**

8. **Grandchild spawn (W2 exit criterion)**: orchestrator child spawns a
   grandchild — grandchild result JSON reaches the orchestrator's
   summary; `AGENT_INSTANCES` = 2 with correct depths. Uses the real
   `buildWorker` path with the harness's scripted provider seam, and the
   `tdMkWorker` stub for the leaf-most worker at EVERY level (the seam
   composes through the nested wiring — CTO item 6).
9. **Batch orchestrator**: `tasks: [orch, leaf]` — both register, the
   orchestrator child still spawns (CTO S1a); concurrency interplay
   documented in the assertion comment (§3.6 step 6).
10. **Depth chain**: 3-level chain with `max_spawn_depth = 2` rejects at
    the third level with the depth message naming depth vs max; the
    grandchild's recorded depth via `AGENT_INSTANCES` is 2 (Security Q1,
    CTO B2).
11. **Leaf cannot spawn**: leaf-def child's `AGENT_START` call errors
    with the dedicated leaf message (not OpNotFound).
12. **Kill switch**: `orchestrator_enabled = false` ⇒ orchestrator child
    gets the dedicated kill-switch error (12a: at the resolver/op
    boundary — W2), AND the child-prompt catalog is absent (12b: prompt
    gating — W3). Both assert the registry + prompt planes are gated
    together.
13. **Tool allow-list**: def declares `tools = ["AGENT_DEF_LIST"]` ⇒
    `FILE_WRITE` call errors as unknown-tool.
14. **Catalog in child prompt** (orchestrator child): transcript
    system-prompt preamble contains the workdir-prefixed def id.
15. **`AGENT_DEF_LIST` recorded JSON carries roles.**
16. **Mini-metaswarm e2e** (§4.1): the demo-project fixture drives the
    full loop — catalog in prompts, batch orchestrator spawn, narrowed
    tool registries per def, instances + depths, out-of-allow-list
    rejection. This is the W4 centerpiece and the success-metric
    conversation.

## 4. Work Units (for the TDD plan)

- **W1** — role/description on `AgentDef`: validators (incl.
  provider/model — Security item 10), both decoders, `AGENT_DEF_WRITE`
  fields + unknown-tools note, `AGENT_DEF_LIST` output, user-store
  round-trip, stale doc-comment fixes (`Agent.hs:391-393` role schema
  description, `Delegation.hs:253-255` ctRole doc — Architect item 7).
  Tests 1–2 (+3 pure). Cabal/Main wiring.
- **W2** — role-conditioned nested `AGENT_START` + depth plumb +
  registry-depth fix + workdir-union threading + §3.3 intersection
  (Architect B1/B2, CTO B1/B2, Security Q4, Architect item 6):
  `childBlocklist`, both chokepoints, nested `AgentStartWiring` (child
  depth+1, child-rooted mint, union backend, tdMkWorker-composing
  re-anchored worker), `dwdParentDepth` consumed, `registerChild` depth,
  effective-role + kill-switch gate at the resolver, always-present
  role-gated op with dedicated error messages. Tests 7–11, 12a, 13–15.
  *(W2 is the largest WU; it may split into W2a mechanics / W2b errors —
  reviewers' concern at plan gate, not here.)*
- **W3** — `<available_agents>` injection with child gating + role note
  (both prompt paths) + config kill switch. Tests 6, 12b, 14.
- **W4** — e2e orchestration conversation test (the success-metric
  conversation), real-provider smoke OR manual checklist (PM S1),
  allow-list behavior-change changelog note (PM S2), `make check`,
  README opcode-table note (role semantics + delegation table),
  changelog, follow-up issues (frontend role badges, DirScheme role,
  `AGENT_DEF_WRITE` Audited reclassification).

### 4.1 The mini-metaswarm e2e fixture (W4 centerpiece)

A single self-contained test fixture defines a **small project + a
mini-metaswarm** and drives the full orchestration loop through the
gateway API harness — no external tools, no real LLM:

**Fixture: "demo-project" + 3-agent mini-metaswarm.** A fixture repo
(materialized on a temp workspace via the existing fixture/clone
patterns, e.g. `FixtureRepo`/`RepoDiscoverySpec`'s seeded trees) containing:

```
demo-project/
  .agents/
    agents.md                      # project def (id agents-md)
    agents/
      orchestrator/agent.md        # role: orchestrator, brief system prompt
      coder/agent.md               # role: leaf, tools: [FILE_WRITE, FILE_READ, SHELL_EXEC]
      reviewer/agent.md            # role: leaf, tools: [FILE_READ, SEARCH_FILES]
  src/
    index.js                       # trivial file for coder/reviewer to touch
```

The 3 agent.md profiles are the *minimum* metaswarm shape: one
orchestrator (can spawn), two specialists with distinct tool
allow-lists (so the intersection enforcement is observable), and role
frontmatter (so decode → catalog → spawn all have real data). The
project files give the coder something to "modify" and the reviewer
something to "read" in the scripted conversation.

**The scripted conversation** (scripted provider, real registry/wiring;
only the leaf-most child workers use the `tdMkWorker` stub, per W2's
seam composition):

1. Turn 1: user says "Orchestrate a fix." Model calls `AGENT_START
   {id: orchestrator, goal: fix the bug in src/index.js}` (parent =
   top-level session — the *session's* bound agent need not be the
   orchestrator; the roster comes from the catalog).
2. Orchestrator child's turn: system prompt contains
   `<available_agents>` with `demo-project--orchestrator [orchestrator]`,
   `- demo-project--coder [leaf]`, `- demo-project--reviewer [leaf]`.
   Model calls `AGENT_START {tasks: [{id: coder, goal: edit file},
   {id: reviewer, goal: check the edit}]}` — batch mode.
3. Coder child runs with its narrowed registry (FILE_WRITE present,
   WEB_FETCH absent — the allow-list intersection is real, observable
   in the child transcript); reviewer likewise (read-only).
4. Results flow back: orchestrator summary includes both child results;
   parent's `AGENT_START` result includes the orchestrator's summary;
   `AGENT_INSTANCES` shows 3 entries with depths 1,2,2.

**Assertions**: catalog contents in the right prompts (parent vs
orchestrator child vs leaf child's leaf-note), batch results JSON shape,
instances + depths, and — the security-relevant one — the coder child's
attempted out-of-allow-list call errors as unknown-tool while its
in-list calls succeed.

This fixture doubles as the manual-checklist driver for the real-provider
smoke (PM S1): the same conversation script against a real model with
real `demo-project` files is the manual end-to-end validation.

## 5. Security Review Notes

- Orchestrator spawning is bounded by: depth cap (hard, floored/ceilinged
  config), spawn-pause flag, child timeout, concurrency cap, the
  role-aware blocklist (everything except `AGENT_START` stripped, def
  mutation parent-only), def-authoritative role (model cannot widen),
  per-spawn kill-switch re-check, and prompt-injection-validated
  def metadata. A malicious orchestrator def can only spawn defs that
  already exist in stores it cannot write to.
- Tool allow-lists only NARROW (intersection, blocklist wins); no def can
  widen beyond the harness registry.
- Catalog injection surfaces repo/user-controlled text in system prompts —
  mitigated by the §3.1 per-field validators (single-line, fence-token
  rejection, per-field caps; provider/model included) on top of
  SafePath-confined reads. The catalog is metadata only
  (ids/descriptions/names), never def bodies.
- Leaf children get a present-but-rejecting `AGENT_START` (dedicated
  message) — no unknown-tool ambiguity; the op cannot operate because
  `authorize` fails on the effective role.
- Child summaries remain model-visible untrusted data (existing 200-char
  truncation at `Agent.hs:612`); no change.
- Remote mode: no new control-plane FS reads (§3.6).
- Residual risk (corrected, Security item 9): `bracketSem` is a
  single-token MVar — effective delegation parallelism is 1 today. If a
  real counting semaphore is introduced later, nested-spawn-inside-slot
  semantics (grandchildren consuming parent slots) must be re-examined
  before raising the cap. Bounded today by depth (≤3) + per-child
  timeout.
