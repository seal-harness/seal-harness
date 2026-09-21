# Opcode Consolidation Plan — Action-Based Manage Pattern

**Created:** 2026-09-20
**Author:** Zoe (Chief of Staff)
**Status:** Draft — not yet committed to repo

## 1. Executive Summary

Seal Harness currently exposes 21 opcodes across four families that all
follow the same CRUD-over-a-store pattern. Each opcode is a separate entry
in the model's `tools` array, sent on every API call. Consolidating each
family into a single `*_MANAGE` opcode with an `action` discriminator
reduces 21 tool definitions to 4 — roughly **2,500–3,500 tokens saved per
turn**, compounding across every turn in every session.

| Family | Current opcodes (count) | Consolidated | Token savings (est.) |
|---|---|---|---|
| Memory | `MEMORY_WRITE`, `MEMORY_READ`, `MEMORY_LIST`, `MEMORY_SEARCH`, `MEMORY_ARCHIVE` (5) | `MEMORY_MANAGE` | ~600–900 |
| Skills | `SKILL_WRITE`, `SKILL_LOAD`, `SKILL_LIST`, `SKILL_DELETE` (4) | `SKILL_MANAGE` | ~500–700 |
| Agent Defs | `AGENT_DEF_WRITE`, `AGENT_DEF_READ`, `AGENT_DEF_LIST`, `AGENT_DEF_DELETE` (4) | `AGENT_DEF_MANAGE` | ~600–800 |
| Agent Runtime | `AGENT_INSTANCES`, `AGENT_START`, `AGENT_STATUS`, `AGENT_STOP`, `AGENT_INTERRUPT` (5) | `AGENT_MANAGE` | ~700–1000 |
| Sessions | `SESSION_NEW`, `SESSION_LIST`, `SESSION_SEARCH`, `SESSION_GET` (4) | `SESSION_MANAGE` | ~500–700 |
| **Total** | **22 opcodes** | **5 opcodes** | **~2,900–4,100 tokens/turn** |

This mirrors Hermes' design: `memory`, `cronjob`, `project`, `preview`,
`todo`, and `tts` all use a single tool with an `action` enum. The pattern
is: **when N operations all act on the same underlying store/resource,
collapse them into one tool with an `action` discriminator.**

## 2. Design Pattern

Each consolidated opcode is a `TrustedOpcode` with:
- An `action` field (enum) as the discriminator
- A union of all fields from the original opcodes in `properties`
- An `authorize` gate that pattern-matches on `action` to validate
  action-specific required fields
- A `toRun` that dispatches to the appropriate handler

### Schema Structure

```json
{
  "action": "write | read | list | search | archive",
  ...action-specific fields...
}
```

The `required` array always includes `"action"` only. Action-specific
required-field validation happens in the `authorize` gate (not the JSON
schema), because different actions require different fields.

### Authorize Gate Pattern

```haskell
toAuthorize = \input ->
  case parseAction input of
    Left err -> Left err
    Right action -> case action of
      AWrite   -> validateWrite input
      ARead    -> validateRead input
      AList    -> Right ()  -- no required fields
      ASearch  -> validateSearch input
      AArchive -> validateArchive input
```

### Run Dispatch Pattern

```haskell
toRun = \backend input ->
  case parseAction input of
    Left err -> pure (errorResult err)
    Right action -> case action of
      AWrite   -> handleWrite store embedding input
      ARead    -> handleRead store input
      AList    -> handleList store input
      ASearch  -> handleSearch embedding store input
      AArchive -> handleArchive store embedding input
```

## 3. Family-Specific Designs

### 3.1 MEMORY_MANAGE

**Replaces:** `MEMORY_WRITE`, `MEMORY_READ`, `MEMORY_LIST`, `MEMORY_SEARCH`,
`MEMORY_ARCHIVE`

**Actions:**

| Action | Required fields | Optional fields | Handler |
|---|---|---|---|
| `write` | `path`, `content` | — | `msWrite` + `ebIndex` |
| `read` | `path` | — | `msRead` (falls back to archived/) |
| `list` | — | `prefix`, `include_archived` | `msList` |
| `search` | `query` | `limit`, `include_archived` | `ebSearch` + `msSearch` fallback |
| `archive` | `path` | — | `msArchive` + `ebUnindex` |

**Schema:**

```json
{
  "action": {"type": "string", "enum": ["write", "read", "list", "search", "archive"]},
  "path": {"type": "string", "description": "Memory path relative to active/."},
  "content": {"type": "string", "description": "Memory content (write only)."},
  "prefix": {"type": "string", "description": "Directory prefix filter (list only)."},
  "query": {"type": "string", "description": "Search query (search only)."},
  "limit": {"type": "integer", "description": "Max search results (default 10)."},
  "include_archived": {"type": "boolean", "description": "Include archived (list/search)."}
}
```

**Trust level:** Trusted (same as current — all memory opcodes are Trusted)

### 3.2 SKILL_MANAGE

**Replaces:** `SKILL_WRITE`, `SKILL_LOAD`, `SKILL_LIST`, `SKILL_DELETE`

**Actions:**

| Action | Required fields | Optional fields | Handler |
|---|---|---|---|
| `write` | `id`, `description`, `body` | `group` | `sbCreate` (upsert) |
| `load` | `id` | — | `sbRead` |
| `list` | — | — | `sbList` |
| `delete` | `id` | — | `sbDelete` (idempotent) |

**Special case — `SKILL_LOAD` has downstream consumers:**

The `load` action must preserve the `recordSkillLoadResult` behavior in
`Seal.ISA.Dispatch`. The dispatcher currently matches on `op.name ==
"SKILL_LOAD"` to record the skill body into `conversation.jsonl` and
surface it to the frontend. After consolidation, this match must change to
check `op.name == "SKILL_MANAGE" && action == "load"`. See §5.

**Schema:**

```json
{
  "action": {"type": "string", "enum": ["write", "load", "list", "delete"]},
  "id": {"type": "string", "description": "Skill id ([A-Za-z0-9_-]+)."},
  "description": {"type": "string", "description": "Short description (write only)."},
  "body": {"type": "string", "description": "Skill body, Markdown (write only)."},
  "group": {"type": "string", "description": "Optional category (write only)."}
}
```

**Trust level:** Trusted (same as current)

### 3.3 AGENT_DEF_MANAGE

**Replaces:** `AGENT_DEF_WRITE`, `AGENT_DEF_READ`, `AGENT_DEF_LIST`,
`AGENT_DEF_DELETE`

**Actions:**

| Action | Required fields | Optional fields | Handler |
|---|---|---|---|
| `write` | `id`, `name`, `provider`, `model` | `system`, `tools`, `group`, `role`, `description` | `adbUpdate` (upsert) |
| `read` | `id` | — | `adbRead` |
| `list` | — | — | `adbList` |
| `delete` | `id` | — | `adbDelete` (idempotent) |

**Schema:**

```json
{
  "action": {"type": "string", "enum": ["write", "read", "list", "delete"]},
  "id": {"type": "string", "description": "Agent def id ([A-Za-z0-9_-]+)."},
  "name": {"type": "string", "description": "Human-readable agent name (write)."},
  "provider": {"type": "string", "description": "Provider label (write)."},
  "model": {"type": "string", "description": "Model id (write)."},
  "system": {"type": "string", "description": "Optional system prompt (write)."},
  "tools": {"type": "array", "description": "Allowed opcode names, or \"all\" (write)."},
  "group": {"type": "string", "description": "Optional display group (write)."},
  "role": {"type": "string", "description": "\"orchestrator\" or \"leaf\" (write)."},
  "description": {"type": "string", "description": "One-line catalog summary (write)."}
}
```

**Trust level:** Trusted (same as current)

### 3.4 AGENT_MANAGE

**Replaces:** `AGENT_INSTANCES`, `AGENT_START`, `AGENT_STATUS`,
`AGENT_STOP`, `AGENT_INTERRUPT`

**Actions:**

| Action | Required fields | Optional fields | Handler |
|---|---|---|---|
| `instances` | — | — | `listAgents` |
| `start` | `goal` (+ `id` for single, or `tasks` for batch) | `context`, `role` | `runDelegate` |
| `status` | `subagent_id` | — | `agentStatus` |
| `stop` | `subagent_id` | — | `stopAgent` (idempotent) |
| `interrupt` | `subagent_id` | — | `interruptAgent` |

**Special case — `AGENT_START` is the most complex opcode in the system:**

The `start` action carries the `AgentStartWiring` (delegation config, worker
builder, role gate, kill-switch). The authorize gate for `start` must
preserve the role/kill-switch gate logic from the current `agentStartOp`.
The `toRun` for `start` must preserve the synchronous delegation +
post-hoc registration logic.

**Schema:**

```json
{
  "action": {"type": "string", "enum": ["instances", "start", "status", "stop", "interrupt"]},
  "id": {"type": "string", "description": "Agent def id (start, single-task)."},
  "goal": {"type": "string", "description": "Task goal (start, single-task)."},
  "context": {"type": "string", "description": "Background context (start)."},
  "role": {"type": "string", "description": "Role hint: \"leaf\" (start)."},
  "tasks": {"type": "array", "description": "Batch: [{id, goal, context?, role?}] (start)."},
  "subagent_id": {"type": "string", "description": "Subagent id (status/stop/interrupt)."}
}
```

**Trust level:** Trusted (same as current — `AGENT_START` and lifecycle ops
are all Trusted)

### 3.5 SESSION_MANAGE

**Replaces:** `SESSION_NEW`, `SESSION_LIST`, `SESSION_SEARCH`, `SESSION_GET`

**Actions:**

| Action | Required fields | Optional fields | Handler |
|---|---|---|---|
| `new` | — | `provider`, `model`, `channel`, `description` | `newSession` + `saveSessionMeta` |
| `list` | — | `archived` | `listSessions` / `listArchivedSessions` |
| `search` | `query` | `archived` | substring match on descriptions + first-user-message snippets |
| `get` | `session_id` | `offset`, `limit` | read + paginate `conversation.jsonl` |

**Note:** `SESSION_NEW` is currently defined in `Session.hs` but NOT wired
into `baseOps` in `TurnEngine` (only `LIST`, `SEARCH`, `GET` are registered).
The `new` action should be included in `SESSION_MANAGE` regardless — the
opcode exists and is tested, it's just not exposed to the model yet. Wiring
it into the consolidated opcode is a natural place to enable it.

**Schema:**

```json
{
  "action": {"type": "string", "enum": ["new", "list", "search", "get"]},
  "provider": {"type": "string", "description": "Provider label (new). Default: \"anthropic\"."},
  "model": {"type": "string", "description": "Model id (new)."},
  "channel": {"type": "string", "description": "Channel label (new). Default: \"api\"."},
  "description": {"type": "string", "description": "Session title (new)."},
  "archived": {"type": "boolean", "description": "List/search archived sessions (list/search). Default: false."},
  "query": {"type": "string", "description": "Search query (search)."},
  "session_id": {"type": "string", "description": "Session id to read (get)."},
  "offset": {"type": "integer", "description": "Message offset, 0-based (get). Default: 0."},
  "limit": {"type": "integer", "description": "Max messages to return (get). Default: 50, max: 200."}
}
```

**Trust level:** Trusted (same as current — all session opcodes are Trusted)

**Blast radius:** Low. The SESSION_ opcodes are new (just merged) with no
downstream consumers outside the test file (`SessionSpec.hs`) and
`TurnEngine` wiring. No frontend references, no dispatcher special-casing,
no `StreamProgress` emoji entries, no `userSurfacingOps` entries. The
`knownOpNames` set in `Agent.hs` does NOT include the SESSION_ opcodes yet
(they were added without updating it — a pre-existing gap). The consolidation
should add `SESSION_MANAGE` to `knownOpNames` as part of the migration.

## 4. Migration Strategy

### 4.1 Backward Compatibility Layer

During migration, both old and new opcodes coexist in the registry. The old
opcodes are thin shims that delegate to the new `*_MANAGE` opcode's handler
with a pre-set `action`. This allows:

- Existing tests to pass unchanged
- The frontend to continue matching `SKILL_LOAD` by name
- A gradual rollout where the model can use either form

**Shim pattern:**

```haskell
-- Old opcode, now a thin wrapper
memoryWriteOp :: MemoryStore -> EmbeddingBackend -> Opcode
memoryWriteOp store embedding =
  (memoryManageOp store embedding)
    { toName = OpName "MEMORY_WRITE"
    , toDesc = "Write a new memory file. (Legacy — prefer MEMORY_MANAGE with action=\"write\".)"
    , toAuthorize = \input ->
        (oaAuthorize (memoryManageOp store embedding))
          (mergeAction "write" input)
    , toRun = \backend input ->
        (toRun (memoryManageOp store embedding))
          backend (mergeAction "write" input)
    }
```

Where `mergeAction` injects `"action": "write"` into the input JSON so the
manage opcode's handler sees it as a normal action call.

### 4.2 Phase Order

Migrate one family at a time. Each phase is independently mergeable and
revertable. Order by risk: lowest-risk first.

1. **Memory** — no downstream consumers, no frontend references, no
   dispatcher special-casing. Cleanest migration.
2. **Sessions** — new opcodes (just merged), no downstream consumers, no
   frontend special-casing. Low risk. Also add `SESSION_MANAGE` to
   `knownOpNames` (which currently doesn't include the SESSION_ opcodes at
   all — a pre-existing gap from the recent merge).
3. **Agent Defs** — no downstream consumers, no frontend special-casing.
   The `knownOpNames` set in `Agent.hs` needs updating.
4. **Agent Runtime** — `AGENT_START` is complex but self-contained. The
   `StreamProgress` emoji map and `knownOpNames` need updating.
5. **Skills** — highest risk because `SKILL_LOAD` has the most downstream
   consumers (dispatcher, frontend, slash command, transcript
   reconstruction). Migrate last.

## 5. Blast Radius — Every Reference to Update

### 5.1 Per-Family Impact

#### Memory (lowest risk)
- `src/Seal/ISA/Ops/Memory.hs` — rewrite as `MEMORY_MANAGE`
- `src/Seal/Core/TurnEngine.hs` — update `baseOps` list
- `test/Seal/ISA/Ops/MemorySpec.hs` — rewrite tests
- `test/Seal/Phase5Spec.hs` — update `MEMORY_WRITE`/`MEMORY_READ` tool-call names
- `src/Seal/ISA/Ops/Agent.hs` — update `knownOpNames` set

#### Sessions (low risk)
- `src/Seal/ISA/Ops/Session.hs` — rewrite as `SESSION_MANAGE`
- `src/Seal/Core/TurnEngine.hs` — update `baseOps` list (currently wires
  `sessionListOp`, `sessionSearchOp`, `sessionGetOp`; also wire `sessionNewOp`
  as the `new` action)
- `test/Seal/ISA/Ops/SessionSpec.hs` — rewrite tests
- `src/Seal/ISA/Ops/Agent.hs` — add `SESSION_MANAGE` to `knownOpNames` (the
  SESSION_ opcodes are currently missing from this set entirely)

#### Skills (highest risk)
- `src/Seal/ISA/Ops/Skills.hs` — rewrite as `SKILL_MANAGE`
- `src/Seal/Core/TurnEngine.hs` — update `baseOps` list
- `test/Seal/ISA/Ops/SkillsSpec.hs` — rewrite tests
- `test/Seal/Command/SkillSpec.hs` — update `SKILL_LOAD` dispatcher reference
- `test/Seal/Skills/PromptSpec.hs` — update `SKILL_LOAD` string check
- `test/Seal/RepoDiscoverySpec.hs` — update `SKILL_LIST` dispatch calls
- `test/Seal/Phase5Spec.hs` — update `SKILL_WRITE` tool-call name
- `src/Seal/ISA/Dispatch.hs` — `recordSkillLoadResult` matches `nm == "SKILL_LOAD"`;
  must match `SKILL_MANAGE` + `action == "load"` instead (or keep the shim
  and match the legacy name during the transition period)
- `src/Seal/Command/Skill.hs` — slash command dispatches `OpName "SKILL_LOAD"`;
  must dispatch `SKILL_MANAGE` with `action: "load"` instead
- `src/Seal/Gateway/Transcript.hs` — `userSurfacingOps` set includes
  `"SKILL_LOAD"`; must include `"SKILL_MANAGE"` (or match action within)
- `src/Seal/Channels/StreamProgress.hs` — emoji map has `"SKILL_LOAD"` entry;
  add `"SKILL_MANAGE"` entry
- `src/Seal/Transcript/Reconstruct.hs` — comment references `SKILL_LOAD`
  whitelisting
- `frontend/src/components/ChatArea.tsx` — matches `opName === 'SKILL_LOAD'`;
  must match `SKILL_MANAGE` + action
- `frontend/src/components/__tests__/ChatArea.test.tsx` — test fixtures with
  `SKILL_LOAD`
- `frontend/src/types.ts` — comment referencing `SKILL_LOAD`
- `test/Seal/Gateway/ApiSpec.hs` — test fixtures with `SKILL_LOAD`
- `test/Seal/Gateway/TranscriptSpec.hs` — test fixture with `SKILL_LOAD`
- `test/Seal/Transcript/ReconstructSpec.hs` — test fixture with `SKILL_LOAD`

#### Agent Defs
- `src/Seal/ISA/Ops/Agent.hs` — rewrite the `AGENT_DEF_*` ops as `AGENT_DEF_MANAGE`
- `src/Seal/Core/TurnEngine.hs` — update `baseOps` list
- `test/Seal/ISA/Ops/AgentSpec.hs` — rewrite `AGENT_DEF_*` tests
- `test/Seal/Phase5Spec.hs` — update `AGENT_DEF_WRITE` tool-call name
- `src/Seal/ISA/Ops/Agent.hs` — update `knownOpNames` set
- `test/Seal/Agent/Def/BackendSpec.hs` — references `AGENT_DEF_UPDATE` (already
  legacy, but check)

#### Agent Runtime
- `src/Seal/ISA/Ops/Agent.hs` — rewrite `AGENT_INSTANCES`/`START`/`STATUS`/
  `STOP`/`INTERRUPT` as `AGENT_MANAGE`
- `src/Seal/Core/TurnEngine.hs` — update `baseOps` list
- `test/Seal/ISA/Ops/AgentSpec.hs` — rewrite agent lifecycle tests
- `test/Seal/Phase5Spec.hs` — update `AGENT_START` tool-call name
- `test/Seal/Agent/Runtime/Delegation/WorkerSpec.hs` — references `AGENT_START`
- `test/Seal/Channels/StreamProgressSpec.hs` — emoji map test for `AGENT_START`
- `src/Seal/Channels/StreamProgress.hs` — emoji map for `AGENT_START`
- `src/Seal/ISA/Ops/Agent.hs` — update `knownOpNames` set

### 5.2 Cross-Cutting References

These reference all opcode names and need updating in every phase:

- `src/Seal/ISA/Ops/Agent.hs` — `knownOpNames` set (hardcoded list of all
  opcode names used for `unknown_tools` detection in `AGENT_DEF_WRITE`).
  Each phase must replace the old names with the new `*_MANAGE` name.
- `src/Seal/Channels/StreamProgress.hs` — emoji map (`opEmoji`). Each old
  opcode name has an emoji. Add entries for the new `*_MANAGE` names. Old
  entries can stay during the transition period (shims still use them).
- `src/Seal/Gateway/Transcript.hs` — `userSurfacingOps` whitelist. Currently
  `["SKILL_LOAD", "SETUP_REPO", "ASK_HUMAN"]`. Must add `SKILL_MANAGE` (or
  match `SKILL_MANAGE` + action == "load").

### 5.3 The `knownOpNames` Problem

The `knownOpNames` set in `Agent.hs` is a hardcoded list of every opcode name
the harness exposes. It's used to detect typos in agent def `tools` lists.
After consolidation:

**Before:**
```haskell
knownOpNames = Set.fromList
  [ "MEMORY_WRITE", "MEMORY_READ", "MEMORY_LIST", "MEMORY_SEARCH", "MEMORY_ARCHIVE"
  , "SKILL_WRITE", "SKILL_LOAD", "SKILL_LIST", "SKILL_DELETE"
  , "AGENT_DEF_WRITE", "AGENT_DEF_READ", "AGENT_DEF_LIST", "AGENT_DEF_DELETE"
  , "AGENT_INSTANCES", "AGENT_START", "AGENT_STATUS", "AGENT_STOP", "AGENT_INTERRUPT"
  , ...
  ]
```

**After:**
```haskell
knownOpNames = Set.fromList
  [ "MEMORY_MANAGE", "SKILL_MANAGE", "AGENT_DEF_MANAGE", "AGENT_MANAGE"
  , "SESSION_MANAGE"
  , ...
  ]
```

**Transition:** During the backward-compat period, both old and new names
must be in the set. After the shims are removed, drop the old names.

**Long-term fix:** `knownOpNames` should be derived from the `Registry` at
construction time (it already has the full opcode list). This eliminates the
hardcoded set entirely and makes it self-maintaining. This is a follow-up
refactor, not part of the consolidation — but worth noting.

## 6. Implementation Phases

### Phase 1: Memory (lowest risk)
1. Write `Seal.ISA.Ops.Memory` with `memoryManageOp` (the new `MEMORY_MANAGE`)
2. Rewrite the 5 old opcodes as shims that inject `action` and delegate
3. Update `TurnEngine.buildSessionRegistry` — add `MEMORY_MANAGE`, keep shims
4. Update `knownOpNames` — add `MEMORY_MANAGE`, keep old names
5. Update `MemorySpec` — test the new `MEMORY_MANAGE` actions + verify shims
   still pass
6. `make check`
7. (Follow-up PR) Remove shims, drop old names from `knownOpNames`, update
   `Phase5Spec` tool-call names

### Phase 2: Sessions (low risk)
1. Write `Seal.ISA.Ops.Session` with `sessionManageOp` (the new `SESSION_MANAGE`)
2. Rewrite the 4 old opcodes as shims that inject `action` and delegate
3. Update `TurnEngine.buildSessionRegistry` — add `SESSION_MANAGE`, keep
   shims. Also wire the `new` action (currently `sessionNewOp` is defined
   but not registered in `baseOps`)
4. Update `knownOpNames` — add `SESSION_MANAGE` (the SESSION_ opcodes are
   currently missing from this set entirely — fix the gap)
5. Update `SessionSpec` — test the new `SESSION_MANAGE` actions + verify
   shims still pass
6. `make check`
7. (Follow-up PR) Remove shims, drop old names from `knownOpNames`

### Phase 3: Agent Defs
1. Write `agentDefManageOp` (`AGENT_DEF_MANAGE`) in `Agent.hs`
2. Rewrite the 4 old `AGENT_DEF_*` opcodes as shims
3. Update `buildSessionRegistry`, `knownOpNames`
4. Update `AgentSpec` — test `AGENT_DEF_MANAGE` actions + verify shims
5. `make check`
6. (Follow-up PR) Remove shims, drop old names

### Phase 4: Agent Runtime
1. Write `agentManageOp` (`AGENT_MANAGE`) in `Agent.hs` — this is the most
   complex: the `start` action must preserve all `AgentStartWiring` logic,
   the role/kill-switch gate, batch mode, and post-hoc registration
2. Rewrite the 5 old `AGENT_*` lifecycle opcodes as shims
3. Update `buildSessionRegistry`, `knownOpNames`, `StreamProgress` emoji map
4. Update `AgentSpec` — test `AGENT_MANAGE` actions + verify shims
5. Update `WorkerSpec` — `agentStart` name reference
6. `make check`
7. (Follow-up PR) Remove shims, drop old names

### Phase 5: Skills (highest risk)
1. Write `skillManageOp` (`SKILL_MANAGE`) in `Skills.hs`
2. Rewrite the 4 old `SKILL_*` opcodes as shims
3. Update `buildSessionRegistry`, `knownOpNames`, `StreamProgress` emoji map
4. **Update `Dispatch.hs`** — `recordSkillLoadResult` must match
   `SKILL_MANAGE` + `action == "load"` (or keep matching `SKILL_LOAD` via
   the shim during transition)
5. **Update `Command/Skill.hs`** — slash command must dispatch
   `SKILL_MANAGE` with `action: "load"` (or keep dispatching `SKILL_LOAD`
   via the shim during transition)
6. **Update `Gateway/Transcript.hs`** — `userSurfacingOps` must include
   `SKILL_MANAGE` (or keep `SKILL_LOAD` via the shim during transition)
7. Update `SkillsSpec`, `SkillSpec`, `PromptSpec`, `RepoDiscoverySpec`
8. Update frontend `ChatArea.tsx` + tests (or defer to follow-up if shims
   preserve the `SKILL_LOAD` name for the transcript)
9. `make check`
10. (Follow-up PR) Remove shims, drop old names, update all downstream
    consumers to match `SKILL_MANAGE` + action

## 7. Testing Strategy

### 7.1 Per-Action Tests

Each `*_MANAGE` opcode gets a test suite that exercises every action:

```haskell
describe "MEMORY_MANAGE" $ do
  describe "action = write" $ do
    it "writes a new memory file" $ ...
    it "fails if path already exists (write-once)" $ ...
    it "rejects invalid paths" $ ...
  describe "action = read" $ do
    it "reads from active/" $ ...
    it "falls back to archived/" $ ...
    it "returns not-found for missing paths" $ ...
  describe "action = list" $ do
    it "lists active memories" $ ...
    it "includes archived when flag set" $ ...
  describe "action = search" $ do
    it "returns embedding results" $ ...
    it "falls back to substring search" $ ...
  describe "action = archive" $ do
    it "moves active to archived" $ ...
```

### 7.2 Shim Compatibility Tests

During the transition period, verify that old opcode names still work:

```haskell
describe "MEMORY_WRITE (legacy shim)" $ do
  it "produces the same result as MEMORY_MANAGE with action=write" $ ...
```

### 7.3 Authorize Gate Tests

Test that the `authorize` gate correctly validates per-action required
fields:

```haskell
describe "MEMORY_MANAGE authorize" $ do
  it "rejects write without path" $ ...
  it "rejects write without content" $ ...
  it "rejects read without path" $ ...
  it "accepts list with no extra fields" $ ...
  it "rejects search without query" $ ...
  it "rejects archive without path" $ ...
  it "rejects unknown action" $ ...
```

### 7.4 Integration Tests

`Phase5Spec` and `RepoDiscoverySpec` exercise opcodes through the full
dispatch path. These must pass unchanged during the transition (shims
preserve old names) and be updated for the new names in the follow-up PR.

## 8. Token Budget Analysis

### Before (current)

Each opcode's tool definition is roughly 150–300 tokens (name + description
+ input schema with properties + required array). With 22 opcodes across
these 5 families, that's **~3,300–6,600 tokens** in every API call's
`tools` array.

### After (consolidated)

5 `*_MANAGE` opcodes, each ~250–400 tokens (larger schema, but one entry per
family). That's **~1,250–2,000 tokens**.

### Net savings

**~2,050–4,600 tokens per turn**, depending on schema verbosity. With
`on_demand_schemas = true` (stub schemas), the savings are smaller (stubs
are ~30 tokens each), but the `OPCODE_DESCRIBE` calls to fetch full schemas
would also consolidate (5 describe calls instead of 22).

### Compounding effect

A 50-turn session saves **~102,500–230,000 tokens**. Across all sessions in
a day, this is material — it directly extends the $200/mo Anthropic Max
budget.

## 9. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Model confusion from action-based dispatch | The `action` enum + per-action field descriptions are clear. Hermes uses this pattern successfully across 8+ tools. |
| `SKILL_LOAD` downstream consumers break | Phase 4 migrates skills last. Shims preserve the `SKILL_LOAD` name during transition. Downstream consumers updated in the same phase. |
| `AGENT_START` complexity doesn't fit the pattern | The `start` action's schema is the largest, but it's self-contained. The `authorize` gate's role/kill-switch logic is action-conditional, which is exactly what the action discriminator supports. |
| `knownOpNames` set gets stale during transition | Include both old + new names during transition. Long-term: derive from Registry (follow-up refactor). |
| Frontend breaks on `SKILL_LOAD` name match | Defer frontend changes to the follow-up PR. The shim keeps `SKILL_LOAD` as the opcode name, so the transcript still records `op.name = "SKILL_LOAD"`. The frontend change happens when the shim is removed. |
| `OPCODE_DESCRIBE` / `OPCODE_LIST` return old names | During transition, both old + new names are in the registry. After shims are removed, only the new names appear. No special handling needed. |

## 10. What We Don't Consolidate

| Opcode family | Why not |
|---|---|
| `SHOW_HUMAN` / `ASK_HUMAN` | Fundamentally different (display vs prompt). `ASK_HUMAN` is the only blocking opcode — `toBlocking` can't be shared. |
| `SECRET_GET` | Standalone, no family. |
| `SETUP_REPO` | Standalone, no family. |
| `FILE_READ` / `FILE_WRITE` / `FILE_PATCH` / `SEARCH_FILES` | Schema union would be as large as 2-3 separate opcodes. Different backends (read has offset/limit, patch has old/new strings, search has regex/glob). Borderline — revisit if token savings prove worth the schema complexity. |
| `SHELL_EXEC` / `BIN_EXEC` / `PROCESS_MANAGE` | Different security surfaces. Collapsing muddies the trust boundary. |
| `WEB_FETCH` / `WEB_SEARCH` | Different backends, different parameters, different purposes. |
| `HARNESS_LIST` / `HARNESS_START` / `HARNESS_STOP` | Only 3 opcodes. Could consolidate to `HARNESS_MANAGE`, but the savings are marginal (~300-500 tokens). Revisit if other harness ops are added. |

## 11. File Inventory

### New/modified source files (per phase)

**Phase 1 (Memory):**
- `src/Seal/ISA/Ops/Memory.hs` — rewrite
- `src/Seal/Core/TurnEngine.hs` — update `baseOps`
- `src/Seal/ISA/Ops/Agent.hs` — update `knownOpNames`

**Phase 2 (Sessions):**
- `src/Seal/ISA/Ops/Session.hs` — rewrite
- `src/Seal/Core/TurnEngine.hs` — update `baseOps`, wire `new` action
- `src/Seal/ISA/Ops/Agent.hs` — add `SESSION_MANAGE` to `knownOpNames`

**Phase 3 (Agent Defs):**
- `src/Seal/ISA/Ops/Agent.hs` — rewrite `AGENT_DEF_*` section + `knownOpNames`
- `src/Seal/Core/TurnEngine.hs` — update `baseOps`

**Phase 4 (Agent Runtime):**
- `src/Seal/ISA/Ops/Agent.hs` — rewrite `AGENT_*` lifecycle section + `knownOpNames`
- `src/Seal/Core/TurnEngine.hs` — update `baseOps`
- `src/Seal/Channels/StreamProgress.hs` — emoji map

**Phase 5 (Skills):**
- `src/Seal/ISA/Ops/Skills.hs` — rewrite
- `src/Seal/Core/TurnEngine.hs` — update `baseOps`
- `src/Seal/ISA/Ops/Agent.hs` — update `knownOpNames`
- `src/Seal/ISA/Dispatch.hs` — `recordSkillLoadResult` match
- `src/Seal/Command/Skill.hs` — slash command dispatch
- `src/Seal/Gateway/Transcript.hs` — `userSurfacingOps`
- `src/Seal/Channels/StreamProgress.hs` — emoji map
- `frontend/src/components/ChatArea.tsx` — `SKILL_LOAD` match (follow-up PR)
- `frontend/src/types.ts` — comment (follow-up PR)

### Test files (per phase)

**Phase 1:** `test/Seal/ISA/Ops/MemorySpec.hs`, `test/Seal/Phase5Spec.hs`
**Phase 2:** `test/Seal/ISA/Ops/SessionSpec.hs`
**Phase 3:** `test/Seal/ISA/Ops/AgentSpec.hs`, `test/Seal/Phase5Spec.hs`
**Phase 4:** `test/Seal/ISA/Ops/AgentSpec.hs`, `test/Seal/Phase5Spec.hs`,
`test/Seal/Agent/Runtime/Delegation/WorkerSpec.hs`,
`test/Seal/Channels/StreamProgressSpec.hs`
**Phase 5:** `test/Seal/ISA/Ops/SkillsSpec.hs`,
`test/Seal/Command/SkillSpec.hs`, `test/Seal/Skills/PromptSpec.hs`,
`test/Seal/RepoDiscoverySpec.hs`, `test/Seal/Phase5Spec.hs`,
`test/Seal/Gateway/ApiSpec.hs`, `test/Seal/Gateway/TranscriptSpec.hs`,
`test/Seal/Transcript/ReconstructSpec.hs`,
`frontend/src/components/__tests__/ChatArea.test.tsx`

## 12. References

- Seal ISA Opcode GADT: `~/code/seal-harness/src/Seal/ISA/Opcode.hs`
- Seal dispatcher: `~/code/seal-harness/src/Seal/ISA/Dispatch.hs`
- Seal turn engine (registry wiring): `~/code/seal-harness/src/Seal/Core/TurnEngine.hs`
- Memory opcodes: `~/code/seal-harness/src/Seal/ISA/Ops/Memory.hs`
- Skills opcodes: `~/code/seal-harness/src/Seal/ISA/Ops/Skills.hs`
- Agent opcodes: `~/code/seal-harness/src/Seal/ISA/Ops/Agent.hs`
- Session opcodes: `~/code/seal-harness/src/Seal/ISA/Ops/Session.hs`
- Stream progress emoji map: `~/code/seal-harness/src/Seal/Channels/StreamProgress.hs`
- Frontend surfacing whitelist: `~/code/seal-harness/src/Seal/Gateway/Transcript.hs`
- Skill slash command: `~/code/seal-harness/src/Seal/Command/Skill.hs`
- Hermes action-based tools: `~/code/hermes-agent/tools/memory_tool.py`,
  `~/code/hermes-agent/tools/cronjob_tools.py`,
  `~/code/hermes-agent/tools/project_tools.py`,
  `~/code/hermes-agent/tools/preview_tool.py`
- Cron implementation plan (same pattern for `CRON_MANAGE`):
  `business/seal-harness/cron-implementation-plan.md`