---
created_at: 2026-11-26T21:26:45Z
description: Write the operator's review surface (user-facing behaviour only) before any design work, so scope has a frozen baseline and reviewer findings can be triaged instead of all becoming requirements. Use when starting any feature that will go through a design or plan review gate.
group: metaswarm
id: requirements-capture
session: 20261126-205738-067
updated_at: 2026-11-26T21:26:45Z
---

# Requirements Capture

Write the **operator's review surface** before any design work: the complete
user-facing behaviour of a feature, and nothing else.

---

## Why this phase exists

A design document reviewed by agents grows. Every reviewer finding becomes a
"requirement" because the design is the only statement of intent, so nothing
can be ruled out of scope. Observed failure mode: a chat command reached 11
design revisions, ~50 findings, and a 1200-line spec for a ~200-line change.

The fix is a separate artifact written **before** design, containing only what
a user of the system would notice. Then "is this finding in scope?" has a
mechanical answer.

**The filter is one question:**

> Would the operator notice, or care, if this were wrong?

If no — it is design detail or someone else's bug. It does not go here.

---

## Two rules

### 1. Completely user-facing

A requirement states observable behaviour. Not architecture, not data flow, not
error types, not which module owns what.

| Belongs in requirements | Belongs in design |
|---|---|
| "`/last b` shows tab b's last message." | "Tail-seek `conversation.jsonl` via `conversation.idx`." |
| "Errors say `last failed: no such tab z`." | "`selectLastMessages` returns `Either Text`." |
| "`/last` never changes the focused tab." | "Route through `handleInject`-shaped read-only path." |
| "No secrets are ever sent to the chat platform." | "`cbInput` is stripped; only `cbName` crosses." |

If you cannot phrase it as something a user does or sees, it is not a
requirement.

### 2. Freezable

Requirements are frozen before design begins. After that, a change requires
explicit human approval — a **scope change request**, not a review fix.

Fixing *within* declared requirements is free. Expanding *them* is a decision
for the human, because it changes what they were promised.

---

## Workflow

```
operator's request
      ↓
[1] CAPTURE — write docs/superpowers/requirements/<date>-<slug>-requirements.md
      ↓
[2] HUMAN APPROVAL — the ONLY document the human must read (~2 min)
      ↓  (optional in a highly automated setting — see "Automated mode")
[3] FREEZE — record approval in the doc header
      ↓
design phase (agents only) → plan phase (agents only) → execution
```

### Step 1: Capture

Write the document. Keep it short — a page or two. Sections:

```markdown
# <Feature> — Requirements

**Status**: awaiting human approval.
**Branch**: <branch>
**Scope**: <one line>

> **What this document is.** The operator's review surface: complete
> user-facing behaviour, nothing else. ~2 minutes to review.

## Behaviour
<the commands / interactions, with argument grammar>

## What the user sees
<concrete rendered examples — literal text, not descriptions>

## Constraints
<the "never does X" invariants a user would notice being violated>

## Out of scope
<pre-existing gaps and non-goals, explicitly, so they are not re-litigated>

## Done when
<numbered, independently observable acceptance criteria>

## Notes for the design phase
<facts the design should not have to rediscover — explicitly NOT requirements>
```

### Step 2: Human approval

This is the point of the whole exercise: **one short document the human reads,
instead of a design document they would skip.**

Present it with a **flagged-issues block** (see below), not a wall of text.

### Step 3: Freeze

Set `**Status**: approved (<date>, <who>)`. From here the design is measured
against it.

---

## Reporting flagged issues to the human

> **Rule**: when requirements capture surfaces an ambiguity, a conflict, or a
> question the agent cannot settle alone, communicate it **concisely and
> prominently**. Not buried in prose.

Format — one line per issue, the decision, and a default:

```markdown
## Needs your call (3)

1. **`/last 3` — tab 3, or three messages?** Default: tab 3 (matches `/N`
   grammar); replies name the tab so a mistake is visible.
2. **Rate limiting in scope?** Default: no — pre-existing gap, every command
   lacks it, not specific to `/last`.
3. **Show tool call arguments?** Default: no — they are not the assistant's
   text, and they can carry secrets.

Reply with corrections, or "defaults" to accept all three.
```

Rules for this block:

- **Cap it at ~5 items.** If there are more, the request is underspecified —
  ask the one question that unblocks the rest instead.
- **Every item gets a default.** The human must be able to say "defaults" and
  move on. Never present an issue with no recommended answer.
- **State the consequence** of the default in the same line, so the human is
  choosing with information, not on trust.
- **Prominent**: put it above the document summary, not after it.
- Never re-raise a decided question. If it comes back, it is a scope change
  request, not a flag.

---

## Automated mode

Human approval may be skipped when the operator has said so, or in a highly
automated setting (unattended pipelines, batch work):

- Record `**Status**: auto-approved (<reason>)` instead.
- Every default taken from the flagged-issues block must be **listed in the PR
  description**, so the human sees the decisions after the fact even though
  they were not asked before.
- The freeze still applies: defaults become requirements, and changing one
  later still needs human sign-off.

Unattended is not unattended-and-unrecorded. The decisions are still surfaced;
only the timing moves.

---

## Downstream: how requirements gate later phases

The requirements document is not filed and forgotten. It is the baseline for
both review gates.

### Design Review Gate

Reviewers receive the requirements as **fixed premises**, with:

> "Do not reopen these. A finding that contradicts a stated constraint or an
> out-of-scope item is a **CONSTRAINT CORRECTION** — report it as such, not as
> a blocker."

Every finding is then triaged into exactly one bucket:

| Bucket | Meaning | Action |
|---|---|---|
| **IN SCOPE — design defect** | Violates a requirement, or fails to meet one | Fix the design |
| **CONSTRAINT CORRECTION** | Reviewer lacked a premise | Fix the reviewer prompt; the design is unchanged |
| **PRE-EXISTING** | A real bug, not this feature's | File an issue; one line in the design pointing at it |
| **NEW REQUIREMENT** | Would change user-facing behaviour | **Human approval required — default is decline** |

A reviewer finding may never add scope on its own authority.

### Plan Review Gate

The Scope & Alignment reviewer gets the requirements document as its baseline,
so "no scope creep" becomes measurable against something instead of being a
judgement call.

---

## Anti-patterns

| # | Anti-pattern | Why it is wrong |
|---|---|---|
| 1 | Requirements that describe implementation | Then it is a design doc, and design review has nothing to check against |
| 2 | A requirements doc that grows as findings arrive | That is the failure this phase exists to prevent |
| 3 | Skipping human approval *silently* | If you auto-approve, record why and list the defaults taken |
| 4 | Presenting 20 flagged issues | Signals an underspecified request; ask the one unblocking question |
| 5 | Flagging issues with no default | Forces the human to do design work; you were supposed to do that |
| 6 | Treating "out of scope" as "not a real problem" | It usually IS a real problem — it is just not *this* problem. File it |
| 7 | Re-opening a decided requirement during design review | Scope change request, needs human sign-off |

---

## Relationship to other skills

- **`brainstorming`** — explores *whether* and *roughly what*. Requirements
  capture follows it and turns that into the reviewable baseline.
- **`design-review-gate`** — validates the design *against* requirements.
  Needs the requirements document as input.
- **`plan-review-gate`** — validates the plan's scope *against* requirements.
- **`orchestrated-execution`** — implements the plan. Requirements feed the
  DoD items.

Order: brainstorm → **requirements capture** → human approval → design →
design gate → plan → plan gate → execution.
