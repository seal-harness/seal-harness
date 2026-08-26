---
name: self-reflect
description: >
  Post-session self-reflection and improvement analysis for Seal Harness.
  Analyzes completed sessions for inefficiencies, missing context, and
  improvement opportunities. Classifies findings as local (user-actionable)
  or upstream (harness-dev-actionable). Accumulates upstream findings for
  periodic compilation into sanitized improvement reports.
category: software-development
---

# Seal Harness Session Review

## Purpose

Every session contains learning. Most sessions contain waste — redundant tool
calls, missing context, wrong-tool selection, manual work that a tool should
automate. This skill captures that learning by running a structured review
pass after each session and accumulating findings over time.

Two categories of improvement:

1. **LOCAL** — User-actionable. Changes to the user's own stack: system prompt,
   skills, agent configuration, workflow patterns. Presented to the user for
   approval before any changes are applied.

2. **UPSTREAM** — Harness-dev-actionable. Changes to Seal Harness itself: tool
   design, system prompt templates, guardrail thresholds, missing capabilities,
   UX issues. Accumulated silently to a JSONL file and periodically compiled
   into a sanitized report the user can choose to send upstream.

## Triggers

Three trigger mechanisms, each serving a different depth:

### 1. Always-On Rule (mid-session, lightweight)
A persistent instruction in the agent's system prompt that steers it to
notice obvious inefficiencies as they happen. This is NOT a full review —
it's a real-time signal catcher. The agent flags issues in its response
footer when it notices them, writing to the session's inline findings log.

Format: a `⚠️ Session note:` line appended to the response when the agent
self-detects an inefficiency during the session. These notes are collected
by the post-session reviewer.

### 2. Tab Close (post-session, primary trigger)
When the user closes a conversation tab, Seal Harness fires the full review
before tearing down the session. This is the main trigger. The forked
reviewer agent runs against the complete transcript.

### 3. On-Demand (`/review-session`)
User-triggered deep dive. Runs the full review with the main model (not an
aux model) against the full transcript. Produces a detailed report including
cross-session pattern analysis from the accumulated findings store. Useful
when the user wants to review a particularly complex session or prepare an
upstream report.

## Data Flow

```
Trigger fires (tab close / /review-session / always-on flag accumulation)
        │
        ▼
Collect: full transcript + tool call log + guardrail events + inline findings
        │
        ▼
Fork reviewer agent:
  - Restricted toolset: skill_manage, memory, file read/write (upstream JSONL only)
  - Different prompt: the Review Rubric (below)
  - No persistence to user's session DB
  - Inherits parent's provider/model for warm cache (or aux model for tab-close)
        │
        ▼
Reviewer analyzes transcript against the rubric:
  - Scans for all signal types
  - Classifies each finding: LOCAL or UPSTREAM
  - Attaches evidence span + repair target + repair hint
  - Self-verifies: can I articulate why this matters and what would improve?
        │
        ▼
LOCAL findings → Present to user for approval
  - Grouped by priority (high/medium/low)
  - Each with: title, evidence, proposed action, repair target
  - User approves → apply (patch skill, update config, etc.)
  - User rejects → discard
  - User defers → save to pending queue
        │
        ▼
UPSTREAM findings → Append to ~/.seal-harness/upstream-learnings.jsonl
  - Sanitized: no user data, no paths, no credentials, no project names
  - Structured: category, severity, title, description, suggested_fix, evidence_span
  - Marked sanitized: true before writing
        │
        ▼
Periodically (configurable, default: 50 findings or 30 days):
  Compile upstream-learnings.jsonl into a sanitized improvement document
  Present to user → user decides whether to send upstream to Seal Harness devs
```

## The Review Rubric

This is the prompt that directs the forked reviewer LLM. It is the core of
this skill — detection quality comes entirely from how well it focuses
attention.

---

### RUBRIC START

Review the conversation above and identify improvements. Be ACTIVE — most
sessions produce at least one finding, even if small. A pass that reports
nothing is a missed learning opportunity, not a neutral outcome.

Every finding must be classified as exactly one of:

- **LOCAL** — The user can fix this themselves. It's about their
  configuration, their skills, their system prompt, their workflow.
- **UPSTREAM** — This is a Seal Harness issue. The harness itself should be
  improved so that no user ever hits this problem again.

When a finding could be either, prefer UPSTREAM if the root cause is a
harness gap (missing auto-injected context, ambiguous tool, missing
capability). Prefer LOCAL if the root cause is user-specific configuration.

### Signals to Look For

Any one of these warrants investigation. Look for ALL of them — do not
stop at the first finding.

#### Efficiency Signals
- Same tool called 2+ times with similar arguments when one call would have
  sufficed. The agent re-read a file it already read, re-searched a query it
  already ran, or re-checked state it already knew.
- Sequential tool calls that could have been parallelized. The agent did A,
  waited for the result, then did B, when A and B were independent.
- Manual multi-step work that a single tool or script could have automated.
  The agent called `read_file` 5 times on related files when a directory
  scan would have been better. The agent hand-typed repetitive content when
  a template or script would have been faster.
- Excessive context switching. The user had to redirect the agent mid-task
  because it went down a wrong path. Each redirection is a finding.
- The agent spent many turns on a subtask that should have been quick.
  Look for high tool-call counts relative to the task complexity.

#### Correctness Signals
- Wrong tool called due to missing context. The agent didn't know the OS,
  didn't know the project structure, didn't know a credential location, and
  called a tool with wrong parameters as a result. This is almost always
  UPSTREAM if the harness should have auto-injected the context, or LOCAL
  if the user's system prompt was missing it.
- Tool call failed because of ambiguous tool name or parameters. Two tools
  with similar names caused confusion. A tool's parameter description was
  unclear. This is UPSTREAM.
- Agent guessed at a tool's behavior instead of checking documentation or
  a loaded skill. The agent should have loaded a skill or read docs first.
- User corrected the agent's workflow or approach. "Don't do X, do Y
  instead." This is LOCAL — encode the correction as a skill patch or
  system prompt addition.
- User corrected the agent's output format, tone, or verbosity. "This is
  too verbose", "just give me the answer", "stop formatting like this."
  This is LOCAL — the user's preference should be encoded.

#### Infrastructure Signals
- System prompt missing context the agent needed. The agent had to ask the
  user for information that should have been in the system prompt or could
  have been auto-detected. If the harness should auto-inject it: UPSTREAM.
  If the user should have it in their config: LOCAL.
- Skill loaded but turned out wrong, missing steps, or outdated. The skill
  guided the agent to do X, but X was incorrect or outdated. This is LOCAL
  — patch the skill.
- Agent configuration missing something. Wrong toolsets enabled, missing
  credential context, no working directory set. This is LOCAL.
- A guardrail fired (warn/block/halt) during the session. Was the threshold
  too loose (should have caught it earlier)? Too tight (false positive)?
  If the threshold needs tuning: UPSTREAM. If the agent's behavior that
  triggered it needs fixing: LOCAL.

#### System Signals (UPSTREAM candidates)
- Tool error message was unhelpful or misleading. The agent couldn't
  recover from an error because the message didn't explain what went wrong
  or how to fix it.
- Tool name was ambiguous, causing wrong-tool selection. Two tools with
  overlapping names or unclear purpose distinctions.
- No tool exists for a task the agent had to do manually. The agent spent
  multiple calls simulating something a single tool should handle.
- System prompt template should have auto-injected context but didn't. The
  harness knows the OS, the working directory, the platform — but didn't
  include it in the system prompt.
- Output format confused the user or obscured important information. The
  agent's response was technically correct but the user couldn't parse it.

### Finding Format

Every finding MUST include ALL of these fields. Findings missing any field
are invalid and must not be filed.

- **category**: LOCAL or UPSTREAM
- **severity**: high (caused failure or significant waste), medium (caused
  friction or minor waste), low (minor improvement opportunity)
- **title**: One-line summary, class-level not session-specific
- **evidence_span**: The specific tool call(s) or message exchange(s) that
  justify this finding. Reference by tool call index or message position.
  If you cannot point to the trace, do not file the finding.
- **repair_target**: What to fix — one of: system_prompt, skill, config,
  tool, guardrail, harness_template, workflow, missing_capability
- **repair_hint**: Concrete suggestion for how to fix it. Not vague —
  pin-pointed. "Add OS detection to prompt_builder and inject as
  SYSTEM_CONTEXT block" not "improve the system prompt."
- **proposed_action**: For LOCAL findings, the specific action to take
  (patch skill X, add Y to config, etc.). For UPSTREAM findings, the
  suggested harness change.

### Preference Order for LOCAL Findings

When a LOCAL finding warrants a skill change, prefer the earliest action
that fits:

1. **PATCH A LOADED SKILL** — If a skill was loaded or consulted this
   session and covers the territory, patch it. Add a pitfall, a step, or
   broaden a trigger.
2. **PATCH AN EXISTING SKILL** — If no loaded skill fits but an existing
   skill does, patch it. Search the skill library first.
3. **ADD A SUPPORT FILE** under an existing skill — references/,
   templates/, or scripts/ as appropriate.
4. **CREATE A NEW SKILL** — Only when no existing skill covers the class.
   Name must be class-level, not a session-specific artifact.

### Sanitization Rules for UPSTREAM Findings

Before writing an UPSTREAM finding to the accumulation file, sanitize it:

- Strip all user-specific data: file paths, credential names, project names,
  personal information, API keys, URLs to private resources.
- Keep only the technical pattern: tool name, error type, missing context
  category, the structural issue.
- Include the suggested fix but not the user's specific implementation
  details.
- If the finding cannot be sanitized without losing its value, convert it to
  a LOCAL finding instead (the user can act on it with full context).

### Do NOT Capture

These become persistent self-imposed constraints that bite later. Skip them.

- **Environment-dependent failures**: missing binaries, fresh-install errors,
  path mismatches, "command not found." The user can fix these. They are not
  durable rules.
- **Negative claims about tools**: "browser tools don't work", "X is broken."
  These harden into refusals the agent cites against itself for months after
  the actual problem was fixed. Instead, capture the FIX (install command,
  config step) under a troubleshooting skill.
- **Transient errors that resolved**: if retrying worked, the lesson is the
  retry pattern, not the original failure. Only file if the retry pattern
  itself is non-obvious and worth encoding.
- **One-off task narratives**: "summarize today's market" or "analyze this
  PR" is not a class of work that warrants a finding.
- **Findings without evidence spans**: if you cannot point to the specific
  trace segment, do not file it.
- **Findings where the agent was already correct**: if the user changed
  their mind or the user's request was ambiguous, that's not a finding.
- **User-specific preferences that don't reveal a harness gap**: "I prefer
  tabs over spaces" is a memory item, not a session review finding. Only
  file if the preference reveals a harness gap (e.g., the agent should
  have auto-detected the user's indentation preference).

### Quality Gates

Before filing any finding, self-verify:

1. **Can I articulate why this matters?** If the finding wouldn't change
   future behavior if fixed, it's not worth filing.
2. **Is my feedback pin-pointed?** "Error messages could be better" is
   useless. "The `read_file` error for binary files doesn't suggest using
   `vision_analyze` instead" is useful.
3. **Is this the right category?** Double-check LOCAL vs UPSTREAM. A
   missing system prompt entry is LOCAL. A missing auto-injection of that
   entry by the harness is UPSTREAM. Both can be filed from the same
   incident.
4. **Would I file this if this were the only finding in the session?** If
   not, it's probably noise.

### Closing

"Nothing to report." is a real option but should NOT be the default. If the
session ran smoothly with no inefficiencies, no corrections, no missing
context, and no guardrail events, say "Nothing to report." and stop.
Otherwise, act. File every valid finding — do not self-censor to keep the
report short. The compilation step handles deduplication and prioritization.

### RUBRIC END

## Storage Layout

```
~/.seal-harness/
  upstream-learnings.jsonl       # accumulated upstream findings, one per line
  pending-local-findings.json    # local findings the user deferred
  session-reviews/               # past review outputs for reference
    2026-07-27-session-abc.json  # full review output per session
  upstream-reports/              # compiled reports ready to send
    2026-07-27-upstream-report.md
  config.yaml                    # review settings (see below)
```

## Upstream Learning JSONL Schema

Each line in `upstream-learnings.jsonl`:

```json
{
  "id": "uuid-v4",
  "timestamp": "ISO-8601",
  "session_id": "session identifier",
  "category": "upstream",
  "subcategory": "system_prompt_gap | tool_design | guardrail_threshold | missing_capability | ux_issue | tool_error_message | ambiguous_tool_name",
  "severity": "high | medium | low",
  "title": "class-level one-line summary",
  "description": "sanitized description of the issue, no user data",
  "suggested_fix": "concrete suggestion for harness improvement",
  "evidence_span": "sanitized reference to the trace pattern (no user data)",
  "repair_target": "tool | harness_template | guardrail | missing_capability",
  "tools_involved": ["tool_name_1", "tool_name_2"],
  "sanitized": true,
  "occurrence_count": 1,
  "first_seen": "ISO-8601",
  "last_seen": "ISO-8601"
}
```

When a new finding duplicates an existing one (same subcategory + similar
title), increment `occurrence_count` and update `last_seen` instead of
adding a new line. This handles cross-session pattern accumulation.

## Local Findings Presentation Format

When presenting LOCAL findings to the user:

```
📋 Session Review: N local findings

HIGH PRIORITY:
1. [skill] System prompt missing OS context
   Evidence: Tool call #12 — agent called system_info with Linux args, OS is macOS
   Proposed: Add "OS: macOS 14.5" to your agent's system prompt
   Action: I can update your config now — approve?

MEDIUM PRIORITY:
2. [skill] Skill 'haskell-build' missing nix flake step
   Evidence: Tool calls #34-38 — agent tried cabal build, should use nix build
   Proposed: Patch haskell skill to add nix flake build as first step
   Action: I can patch the skill now — approve?

LOW PRIORITY:
3. [workflow] Repeated file reads on same file
   Evidence: Tool calls #5, #11, #17 — read_file on config.yaml 3 times
   Proposed: No action needed — noted for pattern tracking

Reply with: approve all / approve N / defer N / reject all
```

## Configuration

`~/.seal-harness/config.yaml`:

```yaml
session_review:
  # Triggers
  always_on: true              # mid-session inline notes
  on_tab_close: true           # post-session automatic review
  on_demand: true              # /review-session command

  # Reviewer
  reviewer_model: aux          # "aux" (cheaper) for tab close, "main" for /review-session
  max_review_iterations: 3     # reviewer max tool calls

  # Local findings
  auto_apply_local: false      # always ask user first
  pending_ttl_days: 30         # deferred findings expire after 30 days

  # Upstream findings
  upstream_compile_threshold: 50  # compile report after N findings
  upstream_compile_interval_days: 30  # or after N days, whichever first
  auto_compile: false            # ask user before compiling

  # Quality
  min_severity: low            # file findings at this severity or above
  require_evidence_span: true   # reject findings without evidence
```

## Upstream Report Compilation

When the accumulation threshold is reached (50 findings or 30 days), or when
the user runs `/compile-upstream`, the system:

1. Reads all entries from `upstream-learnings.jsonl`
2. Groups by `subcategory` and merges duplicates (incrementing occurrence_count)
3. Sorts by severity (high → medium → low) then by occurrence_count (descending)
4. Generates a sanitized Markdown report:
   - Executive summary (N findings across M categories)
   - Per-category sections with findings grouped
   - Each finding: title, description, suggested fix, occurrence count
   - No user data, no session IDs, no paths — fully sanitized
5. Saves to `~/.seal-harness/upstream-reports/<date>-upstream-report.md`
6. Presents to user with option to send upstream or save for later

## Cross-Session Pattern Analysis

On-demand reviews (`/review-session`) include cross-session analysis:

1. Read recent entries from `upstream-learnings.jsonl`
2. Identify patterns: same subcategory appearing 3+ times across sessions
3. Flag recurring LOCAL findings: same skill being patched repeatedly
4. Surface guardrail threshold issues: same guardrail firing across sessions
5. Include a "Trends" section in the review output

This addresses the overfitting concern: single-session findings may be noise,
but the same finding appearing across multiple sessions signals a real issue.
