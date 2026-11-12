# Feature Research: CRON_MANAGE — Scheduled/Recurring Jobs

**Date**: 2026-10-03
**Feature**: CRON_MANAGE opcode for defining, managing, and executing recurring jobs
**Status**: Research complete

## Summary

Seal Harness has no way to schedule recurring agent tasks. Users who want daily
code reviews, periodic health checks, or nightly memory consolidation must
manually trigger each run. A `CRON_MANAGE` opcode would let users define
cron-scheduled jobs that fire agent turns automatically, persisted across
sessions and restarts. This research surveys how 15+ LLM agent harnesses
implement scheduled tasks and synthesizes the findings into design decisions
for seal-harness.

## Prior Art Survey

### Claude Code (Anthropic)

- **Approach**: Three tiers — `/loop` (session-scoped, in-memory), Routines
  (cloud, durable), Desktop scheduled tasks (local, persistent)
- **Storage**: In-memory for `/loop`; cloud for Routines; local config for
  Desktop tasks
- **Execution**: In-process scheduler checks every second for due tasks;
  fires between turns (not mid-response)
- **Security**: Session-scoped tasks die on exit; Routines run autonomously
  without permission prompts
- **Key detail**: Recurring tasks auto-expire after 7 days; no catch-up for
  missed fires; 8-char task IDs; CronCreate/CronList/CronDelete tools
- **Verdict**: Worth copying — the 3-tier model (session/local/cloud) maps
  to seal-harness's session/trusted/remote planes. The auto-expiry and
  no-catch-up behaviors are sensible defaults.

### OpenHands (All-Hands-AI)

- **Approach**: Automations service — separate microservice for scheduling
  and dispatching automation runs
- **Storage**: PostgreSQL (production) or SQLite (single-process)
- **Execution**: Background scheduler polls DB every N seconds; uses
  `FOR UPDATE SKIP LOCKED` for multi-worker safety; creates PENDING runs
  that a dispatcher picks up
- **Security**: Per-user API keys; runs in isolated cloud sandboxes
- **Key detail**: Supports cron + webhook (GitHub event) triggers; full run
  history with status tracking; git sync for automation definitions
- **Verdict**: Adapt — the DB-backed polling + run-tracking model is robust,
  but seal-harness uses file-based stores (transcript as source of truth),
  not a database. The run history pattern is worth copying.

### OpenClaw

- **Approach**: Built-in cron in the Gateway process — the most
  architecturally similar to seal-harness
- **Storage**: `~/.openclaw/cron/` (files on disk, persist across restarts)
- **Execution**: Cron runs inside the Gateway process (not the model);
  three schedule kinds: `at` (one-shot), `every` (interval), `cron`
  (expression); optional stagger
- **Session targeting**: `main` (enqueue system event), `isolated`
  (dedicated fresh session), `current` (bound to creating session),
  `session:<custom-id>` (persistent custom session)
- **Error handling**: One-shot: retry 3x with exponential backoff
  (30s→1m→5m), then disable. Recurring: exponential backoff
  (30s→1m→5m→15m→60m) before next scheduled run
- **Delivery**: Can announce results to chat channels (Slack, Telegram,
  WhatsApp) with `--announce --channel --to` flags
- **Security**: `deleteAfterRun` for one-shots; cron-run sessions guard
  against stale ack replies; best-effort cleanup of browser tabs/processes
- **Verdict**: Worth copying — this is the closest analog to seal-harness's
  architecture. The session targeting model, error handling, and file-based
  persistence all map directly.

### Hermes Agent (Nous Research)

- **Approach**: Single `cronjob` tool with action-style operations
  (schedule/list/remove/pause/resume/edit/trigger)
- **Storage**: File-based
- **Execution**: Gateway process; runs in fresh agent sessions
- **Key detail**: Can attach zero, one, or multiple skills to a cron job;
  natural language or cron expression scheduling; multi-stage pipelines via
  `context_from` (job N receives job N-1's output as context)
- **Security**: Cron-run sessions cannot recursively create cron jobs
  (prevents runaway scheduling loops)
- **Verdict**: Worth copying — the action-based tool design matches
  seal-harness's `*_MANAGE` opcode pattern. The skill attachment and
  anti-runaway features are excellent.

### Goose (Block/AAIF)

- **Approach**: Cron module (Go-based) + scheduler system + Automations
  (cloud)
- **Storage**: SQLite for cron module; recipe files for scheduler
- **Execution**: In-process tick loop at configurable interval;
  `EnableStaleJobRecovery` for catch-up after downtime
- **Key detail**: `CronHandler` struct with group:name pair, cron pattern,
  handler function, priority, retry limit, retry delay, timeout,
  exponential backoff; typed handlers with JSON config payload
- **Verdict**: Adapt — the typed handler + retry config pattern is
  well-designed, but seal-harness's jobs are prompts (natural language),
  not code handlers. The stale job recovery concept is worth considering.

### Cline

- **Approach**: Hub-spoke architecture — hub runs as background process,
  persists schedules across restarts
- **Storage**: Hub-managed persistence (independent of terminal sessions)
- **Execution**: `cline schedule` CLI; creates new session per fire;
  results can be routed to connectors (Telegram, Slack, Discord)
- **Key detail**: Interactive schedule wizard; execution history with
  status, duration, tokens, and cost; statistics (success rate, avg
  duration); cron expression reference
- **Verdict**: Adapt — the execution history and statistics are nice but
  may be over-engineering for seal-harness's first iteration. The
  connector routing is already handled by seal-harness's chat channels.

### Devin (Cognition)

- **Approach**: Scheduled Sessions + Automations — cloud-based, natural
  language scheduling
- **Storage**: Cloud
- **Execution**: Cloud VMs; iCalendar RRULE format for schedules
- **Key detail**: "Schedule this for every Monday at 9am" — conversational
  scheduling; playbook attachment; agent type selection (devin,
  data_analyst); managed Devins for parallel execution
- **Verdict**: Adapt — RRULE is more expressive than cron but adds
  complexity. Stick with standard 5-field cron for the first iteration.

### AutoGPT

- **Approach**: Web UI scheduling + webhook triggers
- **Storage**: Platform database
- **Execution**: Cloud
- **Key detail**: Schedule (recurring with fixed inputs) vs Trigger
  (webhook-driven with dynamic inputs); visual schedule builder
- **Verdict**: Reference only — cloud platform model doesn't apply to
  seal-harness's local-first architecture.

### Cursor

- **Approach**: Cloud Automations with scheduled + event triggers
- **Storage**: Cloud
- **Execution**: Cloud sandbox agents
- **Key detail**: `/automate` skill for natural language automation
  creation; multi-repo environments; memory tool persists across runs
- **Verdict**: Reference only — cloud model.

### Continue

- **Approach**: Mission Control workflows with cron/webhook triggers
- **Storage**: Cloud
- **Execution**: Cloud agents
- **Verdict**: Reference only — cloud model.

### Others

- **ChatGPT**: Scheduled tasks (cloud), event-triggered tasks, monitoring
  tasks. Cloud-only, not applicable.
- **AnythingLLM**: Scheduled Jobs (cron), per-job tool selection, full run
  traces. Self-hosted but different architecture.
- **Fixie/aiXplain**: SDK triggers with schedules. Cloud SDK model.
- **BabyAGI**: Task loop/queue, not time-based scheduling. Not applicable.
- **Aider**: No built-in scheduling. Third-party tools exist (aaider,
  aider-desk task-scheduler).
- **SWE-agent**: No scheduling features.
- **Kotaemon**: RAG UI, no scheduling.
- **Sweep**: Event-driven via GitHub only, no scheduling.

## Cross-Cutting Patterns

1. **Cron expressions are universal** — Every harness with scheduling uses
   standard 5-field cron (minute hour day-of-month month day-of-week).
   Some add 6-field (seconds) but 5-field is the baseline.

2. **Session targeting is the key design decision** — OpenClaw's
   `main`/`isolated`/`current`/`session:<id>` model is the most
   sophisticated. Most harnesses default to "isolated" (fresh session per
   run) with optional persistent session support.

3. **Persistence varies by architecture** — In-memory (Claude Code /loop),
   files (OpenClaw, Hermes), SQLite (Goose, Cline), PostgreSQL (OpenHands).
   File-based is the right choice for seal-harness (consistent with skills,
   agents, memory stores; transcript as source of truth).

4. **Error handling: exponential backoff is standard** — OpenClaw's
   30s→1m→5m→15m→60m backoff for recurring jobs is the most detailed.
   One-shot jobs typically retry 3x then disable.

5. **Anti-runaway is critical** — Kopi/Hermes disable cron management tools
   inside cron-run sessions to prevent runaway scheduling loops. This is
   essential for seal-harness.

6. **Delivery to chat channels** — OpenClaw and Hermes can deliver results
   to Slack/Telegram/etc. Seal-harness already has chat channels, so this
   is a natural fit.

7. **One-shot vs recurring** — Most harnesses support both. One-shots
   auto-delete or auto-disable after running.

8. **Skill/context attachment** — Hermes allows attaching skills to cron
   jobs. This maps to seal-harness's skill system.

9. **Run history** — OpenHands, Cline, and others track run history with
   status, duration, and results. Important for auditability.

10. **Natural language scheduling** — Several harnesses (Devin, Claude
    Code, Hermes) accept natural language like "every weekday at 9am" and
    convert to cron. Nice-to-have but not essential for v1.

## Key Design Decisions for Seal-Harness

### 1. Trust Level: Audited

Cron job definitions are persistent, cross-session state — they survive
restarts and are shared across all sessions. This matches the pattern of
skills, agent defs, and memory (all Audited). The cron store will be a
new backend in the `Backends` record, persisted under `~/.seal/cron/`.

### 2. Opcode: CRON_MANAGE (consolidated, action-based)

Following the `*_MANAGE` pattern (SKILL_MANAGE, MEMORY_MANAGE,
SECRET_MANAGE, AGENT_MANAGE), `CRON_MANAGE` will use an `action` field:

- `create` — define a new cron job
- `read` — get a specific job by id
- `list` — list all jobs
- `update` — modify an existing job (schedule, prompt, enabled, etc.)
- `delete` — remove a job
- `trigger` — fire a job immediately (out of schedule)
- `enable` — enable a disabled job
- `disable` — pause a job without deleting it

### 3. Storage: File-based under `~/.seal/cron/`

Consistent with the seal-harness pattern:
- `~/.seal/cron/jobs/` — one JSON file per job definition
- `~/.seal/cron/runs/` — run history (one JSONL file per job)
- Git is the versioning + audit layer (same as skills, agent defs)

### 4. Execution: In-process scheduler thread

A scheduler thread (started at harness boot) ticks at a configurable
interval (default 60s), checks for due jobs, and fires agent turns via
the existing `AGENT_START` mechanism. Each fire creates an isolated
session (fresh context) by default, with optional persistent session
binding.

### 5. Schedule Format: Standard 5-field cron + optional timezone

```json
{
  "schedule": "0 9 * * 1-5",
  "timezone": "America/New_York"
}
```

Timezone defaults to the host's local timezone (matching Claude Code and
OpenClaw). Supports both recurring and one-shot (`schedule.kind: "once"`
with `at: "2026-10-05T09:00:00Z"`).

### 6. Session Model: Isolated by default

Following OpenClaw's model:
- `isolated` (default) — fresh session per run, no context carry-over
- `session:<id>` — persistent session, context accumulates across runs

### 7. Security: Anti-runaway + transcript audit

- Cron-run sessions have the `CRON_MANAGE` opcode hidden from their tool
  list (prevent runaway scheduling loops, like Kopi/Hermes)
- All cron operations are Audited (written to the global cross-session log)
- Run history is persisted for auditability
- No shell-wrapping (Trusted/Audited opcode invariant preserved)

## Seal-Harness Architecture Fit

- **Trust level**: Audited — persistent, cross-session state
- **Opcodes needed**: `CRON_MANAGE` (new, Audited)
- **Backend/handle**: `CronStore` in the `Backends` record (new)
- **Security invariants**: No shell-wrapping; transcript as source of
  truth; anti-runaway (hide CRON_MANAGE from cron-run sessions)
- **Interaction with existing opcodes**: Fires via `AGENT_START` mechanism;
  uses session store for isolated sessions; optionally delivers results
  via chat channels

## Open Questions

1. **Concurrency limits** — Should there be a max number of concurrent cron
  runs? OpenClaw limits to 2 concurrent jobs. Cline has configurable
  concurrency.
2. **Stale job recovery** — Should missed fires during downtime be
  caught up? Goose has `EnableStaleJobRecovery`. Most harnesses skip
  missed fires (Claude Code, OpenClaw).
3. **Chat channel delivery** — Should cron runs be able to deliver results
  to Telegram/Slack/etc? Seal-harness has chat channels — this is a
  natural extension but adds complexity.
4. **Skill attachment** — Should cron jobs be able to load specific skills
  before running? Hermes supports this. Adds power but also complexity.
5. **Natural language scheduling** — Should the opcode accept "every
  weekday at 9am" and convert to cron? Nice UX but requires LLM parsing
  or a natural-language cron library.