# CRON_MANAGE — Scheduled/Recurring Job Support

**Date**: 2026-10-03
**Status**: Design — revision 2 (post design-review-gate round 1)
**Research**: See `2026-10-03-cron-manage-research.md` for the prior-art survey

## 1. Problem

Seal Harness has no way to schedule recurring agent tasks. Operators who
want daily code reviews, periodic health checks, nightly memory
consolidation, or any time-based automation must manually trigger each run.
Every other major harness (Claude Code, OpenHands, OpenClaw, Hermes, Goose,
Cline, Devin, Cursor) has scheduled task support — seal-harness is missing a
table-stakes feature.

## 1.0 User Personas

**Operator** — The human who runs `seal serve`, unlocks the vault, and
configures the harness. The operator defines cron jobs, chooses schedules,
reviews outputs, and is the beneficiary of automated recurring work. The
operator is the WHO for all use cases below.

**Agent** — The AI that executes the cron job's prompt in an isolated
session. The agent is the mechanism, not the beneficiary. The agent
inherits the harness's tool set (minus `CRON_MANAGE`) and runs at the
autonomy level the operator configured, with a restricted tool set for
cron-spawned sessions (see §5 Security).

## 1a. Use Cases (WHO / WANTS / SO THAT / WHEN)

1. **Operator schedules a daily code review** — *As* an operator, *I want*
   to define a cron job that reviews the previous day's commits every
   morning at 9am, *so that* I see a summary of changes and potential
   issues without manually asking the agent each morning, *when* I set up
   a new project for automated review.
2. **Operator sets up a periodic CI health check** — *As* an operator, *I
   want* a job that checks CI status every 30 minutes during a deployment,
   *so that* I'm alerted if builds are failing without watching the
   dashboard, *when* a deployment is in progress and I need hands-off
   monitoring.
3. **Operator schedules nightly memory consolidation** — *As* an operator,
   *I want* a job that reviews the day's sessions and writes a daily note
   at 11pm, *so that* the memory store stays organized without manual
   cleanup, *when* the harness runs overnight.
4. **Operator sets a one-shot reminder** — *As* an operator, *I want* to
   schedule a one-time reminder for a deadline in 2 hours, *so that*
   nothing slips through the cracks, *when* a task has a time-sensitive
   follow-up.
5. **Operator reviews a failed cron run** — *As* an operator, *I want* to
   see the run history for a cron job including error messages, *so that*
   I can diagnose why a scheduled task failed and fix it, *when* a cron
   job stops producing expected output.
6. **Operator manages an overlapping job** — *As* an operator, *I want*
   jobs that overlap with themselves to skip rather than spawn duplicate
   sessions, *so that* a slow job doesn't pile up concurrent agent
   sessions, *when* a job's runtime exceeds its interval.

## 1b. Success Metrics (user-focused, measurable)

- **S1**: An operator can create a cron job in a single `CRON_MANAGE`
  call with `action: "create"` and have it fire within 1 tick interval
  (default 60s) of its scheduled time. Verified by an integration test
  that creates a job with a 1-minute interval and asserts a run is
  recorded within 2 minutes.
- **S2**: A failed cron run surfaces an error message in the run history
  that the operator can read via `CRON_MANAGE` with `action: "read"` —
  the error text contains enough information to diagnose the failure
  cause (e.g. "agent session timed out", "agent def not found").
- **S3**: Zero runaway scheduling loops — a cron-spawned session cannot
  invoke `CRON_MANAGE` (verified by an integration test that asserts
  `lookupOp` returns `Nothing` for `CRON_MANAGE` in a cron-spawned
  session's registry).
- **S4**: An operator can list all cron jobs and see their next fire
  times, enabling them to verify schedules at a glance without reading
  individual job details.

## 2. Proposed Approach

A new `CRON_MANAGE` opcode (Audited trust level) with an action-based
interface, backed by a file-based `CronStore` (concrete record of IO
fields, matching `SkillBackend`/`MemoryStore` pattern). A scheduler
thread (started in the `serve` boot path, not in `Backends`) ticks at a
configurable interval, checks for due jobs, and fires agent turns via
`runDelegateAsync` directly (not the `AGENT_START` opcode, since the
scheduler runs outside any turn context).

### Design Principles

- **Consistent with existing patterns**: Follow the `*_MANAGE` opcode
  pattern, concrete-record-of-IO-fields store, `Backends` record for the
  store only — exactly like SKILL_MANAGE, MEMORY_MANAGE, etc.
- **Security-first**: Anti-runaway via `filterBlocklistedWith` (ops-list
  removal, not catalog hiding); restricted tool set for cron-spawned
  sessions; operator-approved prompts; no shell-wrapping; full audit
  trail.
- **Simple v1**: Standard 5-field cron, isolated sessions by default,
  file-based persistence. No natural language scheduling, no RRULE, no
  chat channel delivery in v1.
- **Composable**: Fires via `runDelegateAsync`, so cron jobs get a
  restricted but functional agent tool set.

## 3. Opcode Specification

### CRON_MANAGE (Audited)

**Actions**: `create`, `read`, `list`, `update`, `delete`, `trigger`,
`enable`, `disable`

**Note on `create`/`update` vs `write`**: Existing MANAGE opcodes use a
single `write` action (upsert by user-supplied ID). CRON_MANAGE uses
`create` (auto-generates ID) + `update` (partial patch by ID) because
the ID lifecycle is auto-generated (slug from name), not user-supplied.
This is a deliberate, justified deviation from the `write` pattern.

### Action: create

**Input**:
- `action`: `"create"`
- `name`: string (required, non-empty, max 100 chars) — human-readable job name
- `schedule`: string (required) — 5-field cron expression (e.g. `"0 9 * * 1-5"`)
- `timezone?`: string — IANA timezone (default: host local). Validated at authorize time.
- `prompt`: string (required, non-empty, max 4000 chars) — the prompt to run on each fire
- `agent_def_id?`: string — agent definition to use (default: default agent). Validated at authorize time.
- `enabled?`: boolean — initial state (default: `true`)
- `one_shot?`: boolean — if true, auto-disable after first run (default: `false`)

**ID generation**: The job ID is a slug derived from the `name` field
(lowercase, non-alphanumeric replaced with `-`, truncated to 32 chars,
deduplicated with a numeric suffix if already exists, e.g.
`morning-review`, `morning-review-2`). This makes IDs predictable for the
operator while ensuring uniqueness.

**OpResult**:
- `orParts`: `"created job 'morning-review' (id: morning-review), next fire: 2026-10-04T09:00:00-07:00"`
- `orRecorded`: `{"action": "create", "id": "morning-review", "name": "morning-review", "schedule": "0 9 * * 1-5", "enabled": true, "one_shot": false, "next_fire": "2026-10-04T09:00:00-07:00"}`

**Security**: `create` sets the `prompt` field — see §5 for prompt
injection mitigations (operator pre-approval required before `enabled`
takes effect for jobs created by agent-initiated calls).

### Action: read

**Input**: `action: "read"`, `id`: string (required, validated via `mkCronJobId`)

**OpResult (job found)**:
- `orParts`: Multi-line rendered text with all job fields
- `orRecorded`: `{"action": "read", "id": "morning-review", "found": true, "name": "...", "schedule": "...", "enabled": true, ...}`

**OpResult (job not found)**:
- `orParts`: `"cron job not found: morning-review"`
- `orIsError`: `true`
- `orRecorded`: `{"action": "read", "id": "morning-review", "found": false}`

### Action: list

**Input**: `action: "list"`, `enabled_only?`: boolean (default: `false`)

**OpResult**:
- `orParts`: Rendered text, one line per job: `"<id> [enabled|disabled]: <name> — <schedule> (next: <next_fire>)"`
- `orRecorded`: `{"action": "list", "count": N, "ids": ["morning-review", ...], "enabled_count": M}`

### Action: update

**Input**: `action: "update"`, `id`: string (required), plus any of:
`name?`, `schedule?`, `timezone?`, `prompt?`, `agent_def_id?`, `enabled?`,
`one_shot?`. At least one optional field must be present.

**OpResult (job found)**:
- `orParts`: `"updated job 'morning-review'"`
- `orRecorded`: `{"action": "update", "id": "morning-review", "fields": ["schedule", "enabled"], "next_fire": "..."}`

**OpResult (job not found)**:
- `orParts`: `"cron job not found: morning-review"`
- `orIsError`: `true`
- `orRecorded`: `{"action": "update", "id": "morning-review", "found": false}`

**Note**: `update` fails on non-existent jobs (does NOT upsert — use
`create` for new jobs). The store-level `csSave` is an upsert, but the
opcode handler checks existence first and returns an error if not found.

### Action: delete

**Input**: `action: "delete"`, `id`: string (required)

**OpResult**:
- `orParts`: `"deleted"` or `"deleted (was not present)"` (idempotent)
- `orRecorded`: `{"action": "delete", "id": "morning-review", "existed": true}`

### Action: trigger

**Input**: `action: "trigger"`, `id`: string (required)

Fires the job immediately, out of schedule. Works on both enabled and
disabled jobs (the operator may want to test a disabled job).

**OpResult**:
- `orParts`: `"triggered job 'morning-review', session: <session-id>"`
- `orRecorded`: `{"action": "trigger", "id": "morning-review", "session_id": "..."}`

### Action: enable

**Input**: `action: "enable"`, `id`: string (required)

**OpResult**:
- `orParts`: `"enabled job 'morning-review', next fire: ..."`
- `orRecorded`: `{"action": "enable", "id": "morning-review", "next_fire": "..."}`

Idempotent — enabling an already-enabled job succeeds and returns the
same result.

### Action: disable

**Input**: `action: "disable"`, `id`: string (required)

**OpResult**:
- `orParts`: `"disabled job 'morning-review'"`
- `orRecorded`: `{"action": "disable", "id": "morning-review"}`

Idempotent — disabling an already-disabled job succeeds.

### Authorization Gate

Pure `Value -> Either Text ()`:
- `create`: validates `name` (non-empty, max 100), `schedule` (via
  `mkCronExpr`), `timezone` (valid IANA format via `mkTimeZone`), `prompt`
  (non-empty, max 4000), `agent_def_id` (via `mkAgentDefId` if present)
- `read`, `update`, `delete`, `trigger`, `enable`, `disable`: validates
  `id` via `mkCronJobId` (rejects invalid charset, not just missing)
- `list`: always allowed
- `update`: at least one optional field must be present
- All field validation is pure (no IO) — cron expression parsing, timezone
  format check, and ID charset validation happen at authorize time

### JSON Input Schema

Follows the consolidated MANAGE pattern. The `action` field has an enum
of `["create", "read", "list", "update", "delete", "trigger", "enable",
"disable"]`. Per-action fields are documented in the schema's
`properties` section with `description` fields indicating which actions
require them.

## 4. Backend Design

### CronStore (concrete record of IO fields)

Matches the `SkillBackend`/`AgentDefBackend`/`MemoryStore` pattern — a
concrete record, NOT a typeclass:

```haskell
data CronStore = CronStore
  { csJobsDir :: FilePath    -- ~/.seal/config/cron/jobs/
  , csRunsDir :: FilePath    -- ~/.seal/config/cron/runs/
  , csRepo    :: ConfigRepo  -- for git auto-commit (same as SkillBackend)
  , csCreate  :: CronJob -> IO ()
  , csRead    :: CronJobId -> IO (Maybe CronJob)
  , csList    :: Bool -> IO [CronJob]        -- enabledOnly flag
  , csSave    :: CronJob -> IO ()             -- upsert (used internally)
  , csDelete  :: CronJobId -> IO ()
  , csRecordRun :: CronJobId -> CronRun -> IO ()
  , csListRuns  :: CronJobId -> Int -> IO [CronRun]  -- limit, last N
  }
```

**File layout**: `~/.seal/config/cron/jobs/<job-id>.json` — one JSON file
per job. This is under `config/` (not `~/.seal/cron/`) for git
versioning, consistent with skills (`config/skills/`) and agent defs
(`config/agents/`). Run history is at
`~/.seal/config/cron/runs/<job-id>.jsonl` (append-only, rotated to last
100 runs).

**Atomic writes**: Each job file is written via tmp→chmod 0600→rename
(matching `SkillBackend.writeSkill`). Git auto-commit is performed after
mutations (matching the skills/agent-defs pattern).

**Run log rotation**: When `csRecordRun` is called and the run log
exceeds 100 entries, the oldest entries are truncated. This prevents
unbounded disk growth.

### Types

```haskell
newtype CronJobId = CronJobId Text
-- mkCronJobId: validates [a-z0-9-]+, 1-64 chars, no leading dash
-- Path-traversal-safe: no slashes, no dots, no ..

newtype CronExpr = CronExpr Text
-- mkCronExpr: validates 5-field cron syntax using the `cron` package
-- (http://hackage.haskell.org/package/cron) — parseCronSchedule
-- Rejects invalid expressions at construction time
-- Minimum interval: 1 minute (rejects sub-minute schedules)

newtype TimeZone = TimeZone Text
-- mkTimeZone: validates IANA timezone format (e.g. "America/New_York")
-- Uses the `tzdata` package for timezone-aware next-fire computation

data CronJob = CronJob
  { cjId          :: CronJobId
  , cjName        :: Text            -- max 100 chars, never used as path
  , cjSchedule    :: CronExpr
  , cjTimezone    :: Maybe TimeZone  -- Nothing = host local
  , cjPrompt      :: Text            -- max 4000 chars, never used as path
  , cjAgentDefId  :: Maybe Text      -- validated via mkAgentDefId
  , cjEnabled     :: Bool
  , cjOneShot     :: Bool
  , cjApproved    :: Bool            -- operator pre-approval (see §5)
  , cjCreatedAt   :: UTCTime
  , cjUpdatedAt   :: UTCTime
  , cjLastFire    :: Maybe UTCTime
  , cjRunCount    :: Int
  }

data CronRun = CronRun
  { crJobId     :: CronJobId
  , crSessionId :: SessionId
  , crStartedAt :: UTCTime
  , crEndedAt   :: Maybe UTCTime
  , crStatus    :: CronRunStatus    -- Pending | Running | Completed | Failed
  , crError     :: Maybe Text
  }
```

### Scheduler (started in serve boot path, NOT in Backends)

The scheduler is a background thread started in `Seal.Command.Serve` (the
same place other `forkIO` background threads start). It is NOT a field in
the `Backends` record.

```haskell
data CronScheduler = CronScheduler
  { csStore        :: CronStore
  , csAgentWiring :: AgentStartWiring   -- for runDelegateAsync
  , csTickInterval :: Int               -- seconds, default 60
  , csStopSignal   :: TVar Bool
  , csClock        :: IO UTCTime        -- injectable for testing
  , csMaxConcurrent :: Int              -- default 5
  }

startCronScheduler :: CronScheduler -> IO ()
-- Forks a thread that:
-- 1. Ticks every csTickInterval seconds (using csClock for time)
-- 2. Lists enabled+approved jobs from the store
-- 3. For each job whose next_fire <= now:
--    a. Skip if concurrent running jobs >= csMaxConcurrent
--    b. Skip if previous run for this job is still Pending/Running (overlap protection)
--    c. Record a Pending run
--    d. Call runDelegateAsync directly (NOT the AGENT_START opcode)
--       - Constructs a fresh AgentEnv from the agent def
--       - Uses an isolated session (fresh workdir, fresh session id)
--       - Applies the cron-spawn blocklist (removes CRON_MANAGE + dangerous ops)
--       - Sets autonomy to AckRequired (all untrusted ops need ACK — see §5)
--    e. Async: when agent completes, update CronRun status
--    f. Update cjLastFire and cjRunCount
--    g. If one_shot, disable the job
--    h. Compute next_fire and persist
-- 4. If csStopSignal is True, exit
```

**Concurrency model**: Fire-and-forget (async). The scheduler does NOT
block on agent completion. It spawns the agent via `runDelegateAsync` and
moves on to the next due job. The `CronRun` status is updated
asynchronously when the agent completes (via a completion callback).
Concurrent runs are capped at `csMaxConcurrent` (default 5). Overlap
protection: if a job's previous run is still `Pending` or `Running`, the
new fire is skipped (not queued).

**Stale job recovery**: Missed fires during downtime are NOT caught up.
When the scheduler starts, it computes `next_fire` from `now` (not from
`last_fire`) for all enabled jobs. This matches Claude Code and OpenClaw
behavior — simpler and avoids thundering herds of catch-up runs.

### Backends record addition

Only the store is added to `Backends` (NOT the scheduler):

```haskell
data Backends = Backends
  { ...existing fields...
  , bCronStore :: CronStore
  }
```

The scheduler is constructed in `Serve.hs` after `newBackends` and
`AgentStartWiring` are available, then started via `forkIO`.

## 5. Security Analysis

### Invariant Preservation

1. **No shell-wrapping**: CRON_MANAGE is a `TrustedOpcode` (Audited).
   Its `toRun` has no `UntrustedIO` in scope — it physically cannot
   invoke `System.Process`. The CronStore uses native Haskell file I/O
   (`TIO.writeFile`, `renameFile`, `setFileMode`), same as
   `SkillBackend.writeSkill`. The invariant preserved is no
   `System.Process` (NOT no `System.Directory` — the store legitimately
   uses `System.Directory` for `createDirectoryIfMissing`, same as the
   skill backend).

2. **Type-guaranteed sanitization**: `CronJobId` (`[a-z0-9-]+`, no
   slashes/dots) is path-traversal-safe — cannot escape the jobs
   directory. `CronExpr` is validated at construction. `TimeZone` is
   validated at construction. `agent_def_id` is validated via
   `mkAgentDefId`. The `name` and `prompt` fields are free `Text` but
   are NEVER used as path components (only `cjId` is). The authorization
   gate validates all IDs via their smart constructors, not just presence.

3. **Transcript as source of truth**: Cron job definitions are stored as
   files under `config/cron/jobs/`. The `orRecorded` field carries the
   job definition for transcript replay. The CronStore is a materialized
   view rebuilt from transcript replay (same as skills, agent defs).
   **Scheduler firing decisions** are recorded into the cron-spawned
   session's transcript as a harness entry before the agent's first turn,
   ensuring the firing decision is part of the audit trail.

### Anti-Runaway Protection (BLOCKER FIX)

The scheduler removes `CRON_MANAGE` from the cron-spawned session's
opcode list **entirely** (not just hidden from the catalog). This is
achieved via `filterBlocklistedWith` — the same mechanism used for child
agent registries at `TurnEngine.hs` ~line 1237.

`CRON_MANAGE` is added to a cron-specific blocklist:
```haskell
cronSpawnBlocklist :: Set OpName
cronSpawnBlocklist = Set.fromList [OpName "CRON_MANAGE"]
```

This blocklist is applied when building the cron-spawned session's
registry: `filterBlocklistedWith baseOps cronSpawnBlocklist`. After
filtering, `lookupOp` returns `Nothing` for `CRON_MANAGE` → `OpNotFound`.
The opcode is not just hidden from the model's tool catalog — it is
**undispatchable**.

**Defense-in-depth**: The existing `Path.hs` `blockedNames` list includes
`".seal"`, so `mkSafePath`/`mkSafePathForWrite` reject paths touching
`.seal`. A cron-spawned agent cannot write directly to
`config/cron/jobs/` via `FILE_WRITE` or `FILE_PATCH`.

### Prompt Injection Mitigation (BLOCKER FIX)

The `prompt` field is arbitrary text that becomes the spawned agent's
goal. To prevent stored prompt injection with autonomous execution:

1. **Operator pre-approval**: Jobs created by agent-initiated
   `CRON_MANAGE` calls have `cjApproved = false`. The scheduler only
   fires jobs where `cjApproved = true`. The operator approves a job by
   calling `CRON_MANAGE` with `action: "update"` and `approved: true`
   — but this field is only accepted from operator-initiated calls (not
   from agent sessions). In practice, the operator reviews the job via
   the web UI or `read` action, then approves it.

   **Simplified v1 approach**: In v1, all jobs created via `CRON_MANAGE`
   require the operator to call `enable` (or `update` with
   `enabled: true`) from a separate operator session. The `create`
   action sets `enabled: false` by default. The operator must explicitly
   enable the job after reviewing the prompt. This is simpler than a
   separate `approved` field and achieves the same safety: the agent
   creates the job definition, the operator reviews and enables it.

2. **Restricted tool set for cron-spawned sessions**: In addition to
   `CRON_MANAGE`, the cron-spawn blocklist also removes high-risk
   opcodes: `SECRET_MANAGE`, `AGENT_MANAGE` (which can spawn agents),
   `AGENT_DEF_MANAGE`. This limits the blast radius of a prompt-injected
   cron job — it can read/write files, run shell commands, and search
   the web, but cannot access vault secrets or spawn further agents.

   ```haskell
   cronSpawnBlocklist :: Set OpName
   cronSpawnBlocklist = Set.fromList
     [ OpName "CRON_MANAGE"
     , OpName "SECRET_MANAGE"
     , OpName "AGENT_MANAGE"
     , OpName "AGENT_DEF_MANAGE"
     ]
   ```

3. **Low autonomy level**: Cron-spawned sessions use `AckRequired`
   autonomy (all untrusted ops require ACK). Since no human is present
   to ACK, untrusted ops (SHELL_EXEC, FILE_WRITE, etc.) will NOT
   execute in cron-spawned sessions by default. The operator can
   configure a higher autonomy level per job (via `agent_def_id`
   pointing to an agent def with higher autonomy), but the default is
   restrictive.

   **Note**: This means v1 cron jobs can only run Trusted/Audited
   opcodes (MEMORY_MANAGE, SKILL_MANAGE, WEB_SEARCH, SESSION_MANAGE,
   etc.) without operator intervention. To run SHELL_EXEC or
   FILE_WRITE, the operator must create an agent def with higher
   autonomy and reference it via `agent_def_id`. This is a deliberate
   safety trade-off.

4. **Prompt length cap**: `prompt` is capped at 4000 chars to limit
   prompt-stuffing surface.

### Resource Limits

- **Maximum job count**: 100 jobs enforced at `create` time. Creating
  beyond 100 returns an error.
- **Minimum cron interval**: 1 minute. Schedules that fire more
  frequently are rejected at `mkCronExpr` time.
- **Maximum concurrent runs**: 5 (configurable). The scheduler skips
  fires when this limit is reached.
- **Run log rotation**: Last 100 runs per job. Older entries are
  truncated when new runs are recorded.
- **Overlap protection**: If a job's previous run is still `Pending` or
  `Running`, the new fire is skipped (not queued).

### Error Handling

**Retry policy for failed cron runs**:
- On failure (agent session crashes, times out, or returns an error):
  Apply exponential backoff before the next scheduled run:
  `30s → 1m → 5m → 15m → 60m` (matching OpenClaw's pattern).
- After 5 consecutive failures, auto-disable the job and record
  `"auto-disabled after 5 consecutive failures"` in the run history.
- The operator is notified via `SHOW_HUMAN` when a job is auto-disabled.

**Timeout**: Cron-spawned sessions have a configurable timeout (default
300s / 5 minutes). If the agent doesn't complete within the timeout, the
run is marked `Failed` with `"agent session timed out"`.

## 6. Testing Strategy

### Unit Tests (`test/Seal/ISA/Ops/CronSpec.hs`)

- `mkCronJobId` validation: valid, empty, leading dash, too long, invalid chars, uppercase rejected
- `mkCronExpr` validation: valid expressions, invalid fields, wrong field count, sub-minute rejected
- `mkTimeZone` validation: valid IANA, invalid format, empty
- Authorization gate: each action with valid/missing/invalid inputs
- `create`: stores job, returns slugified id + next_fire, enforces max 100 jobs
- `read`: existing job (returns all fields), non-existent (returns error)
- `list`: with/without `enabled_only`, empty store
- `update`: partial updates, non-existent job (returns error, not upsert)
- `delete`: existing and non-existent (idempotent, `existed` flag in orRecorded)
- `trigger`: fires immediately, works on disabled jobs
- `enable`/`disable`: toggles enabled, idempotent, updates next_fire
- OpResult format: verify `orParts` is rendered text, `orRecorded` is JSON per action
- Error states: read non-existent, update non-existent, trigger on disabled, enable/disable idempotent

### QuickCheck Properties

- `prop_cronJobIdRoundTrip`: `mkCronJobId (cronJobIdText id) == Right id` for all valid ids
- `prop_cronExprRoundTrip`: `mkCronExpr (cronExprText expr) == Right expr` for all valid expressions
- `prop_nextFireMonotonic`: next_fire is always strictly after last_fire for recurring jobs
- `prop_cronJobIdPathSafe`: `not (any (\c -> c == '/' || c == '.' || c == '..') (T.unpack (cronJobIdText id)))` — no path traversal
- `prop_slugDeterministic`: same name produces same slug (before dedup suffix)
- `prop_hiddenStillDispatchable`: `hideOpcodes` does NOT prevent dispatch (verifies the anti-runaway fix is necessary)

### Integration Tests

- **Scheduler fires a job**: Create a job with a 1-minute interval using
  an injectable clock (`csClock`). Advance the clock past `next_fire`.
  Assert a `CronRun` is recorded with status `Completed` or `Failed`.
- **One-shot auto-disable**: Create a one-shot job. Trigger it. Assert
  `cjEnabled` is `false` after the run.
- **Anti-runaway (dispatch check)**: Spawn a cron session. Assert
  `lookupOp registry (OpName "CRON_MANAGE")` returns `Nothing` (not just
  hidden from tool catalog — undispatchable).
- **Overlap protection**: Create a job with 1-minute interval. Mock a
  long-running agent (doesn't complete). Advance clock past next fire.
  Assert the second fire is skipped.
- **Stale job recovery**: Create a job. Stop the scheduler. Advance
  clock past several fire times. Start the scheduler. Assert no catch-up
  runs — only the next scheduled fire occurs.
- **Error handling**: Create a job with a non-existent `agent_def_id`.
  Assert the run is marked `Failed` with an error message. Assert
  backoff is applied before the next fire.

## 7. File Impact

### New Files

| File | Purpose |
|---|---|
| `src/Seal/Cron/Store.hs` | CronStore concrete record + file-based operations |
| `src/Seal/Cron/Types.hs` | CronJob, CronRun, CronJobId, CronExpr, TimeZone types |
| `src/Seal/Cron/Scheduler.hs` | Scheduler thread (started from Serve.hs) |
| `src/Seal/ISA/Ops/Cron.hs` | CRON_MANAGE opcode |
| `test/Seal/ISA/Ops/CronSpec.hs` | Opcode + type tests |
| `test/Seal/Cron/StoreSpec.hs` | Store tests |
| `test/Seal/Cron/TypesSpec.hs` | Type validation tests |

### Modified Files

| File | Change |
|---|---|
| `seal-harness.cabal` | Add new modules + `cron` and `tzdata` dependencies |
| `test/Main.hs` | Import + register new test specs |
| `src/Seal/Core/Backends.hs` | Add `bCronStore :: CronStore` field + init in `newBackends` |
| `src/Seal/Core/TurnEngine.hs` | Add `cronManageOp` to `baseOps` list |
| `src/Seal/Command/Serve.hs` | Construct + start `CronScheduler` in boot path |
| `src/Seal/Agent/Runtime/Delegation/Worker.hs` | Add `CRON_MANAGE` to `knownOpNames` if needed |

## 8. Cabal Wiring

### New dependencies

```
cron >= 0.7 && < 0.8       -- cron expression parsing + next-fire computation
tzdata >= 0.2 && < 0.3     -- IANA timezone database
```

### Library `exposed-modules:`

```
Seal.Cron.Store
Seal.Cron.Types
Seal.Cron.Scheduler
Seal.ISA.Ops.Cron
```

### Test-suite `other-modules:`

```
Seal.ISA.Ops.CronSpec
Seal.Cron.StoreSpec
Seal.Cron.TypesSpec
```

## 9. Definition of Done

### Technical Outputs

- [ ] `CRON_MANAGE` opcode with all 8 actions, each with explicit
      `orParts`/`orRecorded` specification
- [ ] `CronStore` concrete record of IO fields with atomic writes
      (tmp→chmod 0600→rename) + git auto-commit
- [ ] `CronJobId`, `CronExpr`, `TimeZone` smart-constructed newtypes
- [ ] Scheduler thread started from `Serve.hs` (NOT in `Backends`)
- [ ] Scheduler fires via `runDelegateAsync` (NOT `AGENT_START` opcode)
- [ ] Anti-runaway via `filterBlocklistedWith` (ops-list removal, not
      `hideOpcodes`) — `lookupOp` returns `Nothing` for `CRON_MANAGE`
- [ ] Restricted tool set for cron-spawned sessions (no SECRET_MANAGE,
      AGENT_MANAGE, AGENT_DEF_MANAGE)
- [ ] Low autonomy default for cron-spawned sessions (AckRequired)
- [ ] One-shot jobs auto-disable after first run
- [ ] Run history persisted to `config/cron/runs/<job-id>.jsonl` with
      100-run rotation
- [ ] Error handling: exponential backoff (30s→1m→5m→15m→60m),
      auto-disable after 5 consecutive failures, 300s timeout
- [ ] Resource limits: max 100 jobs, min 1-minute interval, max 5
      concurrent runs, overlap protection
- [ ] Stale job recovery: no catch-up, next_fire computed from `now`
- [ ] Injectable clock for deterministic testing

### Quality Gates

- [ ] All unit tests passing (each action, error states, OpResult format)
- [ ] QuickCheck properties for CronJobId, CronExpr, path safety
- [ ] Integration test: scheduler fires a job with injectable clock
- [ ] Integration test: anti-runaway (lookupOp returns Nothing)
- [ ] Integration test: overlap protection
- [ ] Integration test: stale job recovery (no catch-up)
- [ ] `make check` green (build + test + lint)
- [ ] `.cabal` and `test/Main.hs` wired correctly
- [ ] `hlint` clean on all new files

### User-Focused Outcomes (from §1b)

- [ ] S1: Operator can create a job in one call, fires within 1 tick
- [ ] S2: Failed runs surface diagnosable error messages in run history
- [ ] S3: Zero runaway scheduling loops (lookupOp returns Nothing)
- [ ] S4: List action shows next fire times for at-a-glance verification