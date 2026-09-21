# Automated Onboarding Friction Capture System

> **Status:** Design — 2026-09-20
> **Author:** Zoe (Chief of Staff agent), brainstormed with Mighty

## Summary

Automated UX friction capture and contribution system for new Seal Harness
users. When new users leverage AI agents to set up and run Seal (which most
will), those agents should automatically capture UX friction, rough edges,
and small bugs as structured, contribution-ready artifacts — making feedback
contribution the path of least resistance rather than an extra chore.

**Complexity**: complex
**Estimated Effort**: 1-2 weeks (layered; highest-leverage layers first)

---

## Problem

Seal Harness is approaching the point where external users will start trying
it. The first wave will encounter UX friction, confusing errors, missing docs,
wrong defaults, config hell, and small bugs. Normally, the best onboarding
advice is: "take careful notes on your experience and help document issues."
But most new users won't do this manually — they'll be using AI agents to set
up and run Seal, and those agents will work around problems silently rather
than capturing structured feedback.

The opportunity: since AI agents are already in the loop and already
experiencing the friction, we can make feedback capture a default byproduct of
their normal operation — not an extra step the user has to remember.

**Goal**: Make it so that almost anyone starting to use Seal will
automatically (or with very low friction) be contributing UX/polish
improvements to the project by default.

---

## Design: Four-Layer System

### Layer 1: Onboarding Skill (`seal-onboarding`)

A new built-in skill in `config/skills/core/`, embedded into the Seal binary
via `file-embed` (same mechanism as `seal-usage`). Auto-injected at first-run
or when Seal detects it's in a new environment (no existing config, no prior
sessions).

**What it teaches the agent:**

1. **You are a first-class contributor.** When you hit friction, you're not
   just working around it — you're documenting it for the next person. This is
   expected, not optional.
2. **The friction taxonomy.** What counts as a UX issue worth reporting vs. a
   user error vs. a feature gap:
   - `confusing-error` — error message that doesn't tell the user what to do
   - `missing-doc` — agent had to guess because no documentation existed
   - `wrong-default` — a default value caused a problem
   - `workflow-dead-end` — agent hit a wall with no obvious path forward
   - `tool-misnamed` — opcode name doesn't match what it does
   - `missing-capability` — agent needed to do something but no opcode exists
   - `config-hell` — configuration was unclear, contradictory, or required
     trial-and-error
   - `platform-gap` — something works on one platform but not another
3. **The capture protocol.** When you hit friction, create a finding entry in
   `~/.seal/sessions/<sid>/friction-log.jsonl`. Don't break flow — note it,
   work around it, keep going. Findings get compiled at session end.

**Anti-noise guidance**: Only capture friction that would have stopped a new
user cold or required them to ask for help. Minor annoyances go in a
low-priority bucket, not the issue queue. False positives are cheap, missed
findings are expensive — but flooding the system with noise is worse than
missing a few low-severity items.

### Layer 2: Inline Friction Capture (extends `self-reflect`)

The existing `self-reflect` skill already has the "always-on rule" — a
mid-session `⚠️ Session note:` footer for real-time signal catching. Extend
this with structured friction logging:

- During the session, when the agent encounters friction (confusing error,
  retries a command 3+ times, can't figure out a config value, hits a
  dead-end), it appends a structured entry to
  `~/.seal/sessions/<sid>/friction-log.jsonl`.
- **Schema** (extends the existing `upstream-learnings.jsonl` pattern):

```json
{
  "id": "uuid-v4",
  "timestamp": "ISO-8601",
  "session_id": "session identifier",
  "category": "confusing-error | missing-doc | wrong-default | workflow-dead-end | tool-misnamed | missing-capability | config-hell | platform-gap",
  "severity": "high | medium | low",
  "title": "class-level one-line summary",
  "what_happened": "sanitized description of the friction encountered",
  "what_i_tried": "what the agent attempted before finding a workaround",
  "what_worked": "the workaround or resolution, if found",
  "suggested_fix": "concrete suggestion for harness improvement",
  "tools_involved": ["opcode or CLI name"],
  "sanitized": true,
  "occurrence_count": 1,
  "first_seen": "ISO-8601",
  "last_seen": "ISO-8601"
}
```

- Deduplication: when a new finding duplicates an existing one (same category
  + similar title), increment `occurrence_count` and update `last_seen`
  instead of adding a new line.
- This piggybacks on the existing `self-reflect` infrastructure rather than
  creating a parallel system.

### Layer 3: Post-Session Compilation (`onboarding-audit-agent`)

A new agent in `.agents/agents/` that runs when a new user's session ends (tab
close), using the existing `self-reflect` tab-close trigger:

1. Reads `friction-log.jsonl` for the session.
2. Deduplicates, sanitizes, classifies by severity.
3. **High-severity** findings (blocked the user, required human intervention):
   generates a draft GitHub issue using the existing `create-issue` skill's
   template, fully sanitized. Saved to `~/.seal/onboarding-draft-issues/` —
   NOT submitted automatically.
4. **Medium-severity** findings (worked around but caused confusion):
   accumulates to `~/.seal/onboarding-findings.jsonl` (same schema as the
   existing `upstream-learnings.jsonl`).
5. **Low-severity** findings (minor annoyance): notes for FAQ/doc
   consideration, accumulated to the same JSONL.
6. Produces a user-facing summary:

```
📋 Onboarding Review: 3 friction points captured this session

HIGH SEVERITY (draft issues ready for your review):
1. [config-hell] Vault unlock requires YubiKey but no setup guide exists
   → Draft issue: ~/.seal/onboarding-draft-issues/2026-09-20-vault-yubikey-setup.md

MEDIUM SEVERITY (accumulated for pattern analysis):
2. [confusing-error] SHELL_EXEC "cd ~" silently escapes workdir
3. [missing-doc] No examples for --allow flag syntax

Reply with: file all / file N / review N / defer all
```

**The user approves before anything goes public.** AI captures and drafts;
humans review and submit. This respects the human-authorship rule.

### Layer 4: Cross-User Pattern Detection (`knowledge-curator-agent` extension)

Extends the existing `knowledge-curator-agent` in `.agents/agents/`:

- Periodically scans accumulated onboarding findings (if users opt in to
  sharing).
- Clusters by category and identifies systemic patterns (same config issue
  hitting 5 users = it's not a user error, it's a UX problem).
- Generates draft FAQ entries and doc improvements.
- Proposes GitHub issues for systemic problems with aggregated evidence.
- Feeds back into `seal-onboarding` skill updates: "this used to be
  confusing, here's how it works now."

This is the layer where individual friction becomes systemic insight. One
user hitting a confusing error is a data point. Five users hitting it is a
pattern. The curator agent makes that leap.

---

## Architecture Decision

**Decision**: Extend existing infrastructure (`self-reflect`, `create-issue`,
`.agents/` roster) rather than building a parallel system.

**Rationale**: The project already has JSONL accumulation with sanitization
and cross-session pattern detection (`self-reflect`), structured issue
generation (`create-issue`), and a full agent roster (`.agents/agents/`).
Building parallel systems would duplicate effort and create maintenance
burden. The four layers map cleanly onto existing patterns:

| Layer | Existing infrastructure extended |
|-------|----------------------------------|
| 1. Onboarding skill | `seal-usage` auto-injection + `file-embed` builtins |
| 2. Inline capture | `self-reflect` always-on rule + JSONL schema |
| 3. Post-session compilation | `self-reflect` tab-close trigger + `create-issue` template |
| 4. Pattern detection | `knowledge-curator-agent` + `upstream-learnings.jsonl` |

**Rejected alternatives:**

- **Separate "feedback bot" agent** — adds a new agent to the roster that
  monitors other agents. Rejected because it creates an observer/actor split
  that's hard to keep in sync. Better to make the acting agent itself the
  capturer.
- **Pure post-session survey** — only captures friction at session end,
  losing real-time context. Rejected because mid-session capture (while the
  friction is fresh) produces higher-quality findings.
- **Automatic issue submission** — AI files issues without human review.
  Rejected because it violates the human-authorship rule and would flood the
  issue tracker with noise.

---

## Scope

- **IN SCOPE**: Layers 1-3 (onboarding skill, friction capture, post-session
  compilation). These are the minimum viable system.
- **OUT OF SCOPE** (follow-up issues):
  - Layer 4 (cross-user pattern detection) — only matters once multiple users
    are generating findings. Defer to a separate issue.
  - FAQ auto-generation — draft doc improvements from accumulated findings.
    Defer.
  - Opt-in telemetry / sharing mechanism for cross-user data. Defer.
  - Integration with external tools (Slack, Discord) for community Q&A
    capture. Defer.

---

## Implementation Plan

### Phase 1: `seal-onboarding` skill (highest leverage)

- [ ] Write `config/skills/core/seal-onboarding.md` with friction taxonomy,
      capture protocol, and anti-noise guidance
- [ ] Wire into `builtinSources` in `Seal.Skills.Builtins`
- [ ] Auto-injection logic: inject at first-run or when no prior sessions
      exist (detect via absence of `~/.seal/sessions/` or a first-run flag in
      config)
- [ ] Test: verify skill is injected on fresh install, not injected on
      existing install

### Phase 2: Friction log extension to `self-reflect`

- [ ] Extend `self-reflect` always-on rule with structured `friction-log.jsonl`
      output
- [ ] Implement friction log schema (extend `upstream-learnings.jsonl`
      pattern)
- [ ] Add deduplication logic (same category + similar title → increment
      count)
- [ ] Add sanitization pass (strip user data, paths, session IDs)
- [ ] Test: verify friction entries are written during a session with known
      friction points

### Phase 3: `onboarding-audit-agent`

- [ ] Write `.agents/agents/onboarding-audit-agent/agent.md` with post-session
      compilation workflow
- [ ] Implement draft issue generation using `create-issue` template
      (sanitized, saved to `~/.seal/onboarding-draft-issues/`, NOT submitted)
- [ ] Implement accumulation to `~/.seal/onboarding-findings.jsonl` for
      medium/low severity
- [ ] Implement user-facing summary with approval flow (file all / file N /
      review N / defer all)
- [ ] Wire into `self-reflect` tab-close trigger
- [ ] Test: end-to-end test with a session that generates known friction,
      verify draft issues and findings are produced

---

## Files to Create/Modify

- **NEW**: `config/skills/core/seal-onboarding.md` — onboarding skill (Layer 1)
- **NEW**: `.agents/agents/onboarding-audit-agent/agent.md` — post-session
  compiler agent (Layer 3)
- **MODIFY**: `src/Seal/Skills/Builtins.hs` — wire `seal-onboarding` into
  `builtinSources`
- **MODIFY**: `config/skills/core/self-reflect-skill.md` — extend with
  friction log schema and capture protocol (Layer 2)
- **MODIFY**: `src/Seal/Agent/SessionReview.hs` (or equivalent) — friction
  log writing, deduplication, sanitization
- **MODIFY**: `~/.seal-harness/config.yaml` schema — onboarding review
  settings (auto-apply, thresholds, etc.)

---

## Acceptance Criteria

- [ ] `seal-onboarding` skill is auto-injected on first-run and teaches the
      friction taxonomy + capture protocol
- [ ] Agent writes structured entries to `friction-log.jsonl` when it
      encounters friction during a session
- [ ] Post-session review produces a user-facing summary with draft issues
      and accumulated findings
- [ ] Draft issues are saved locally, NOT submitted to GitHub without
      explicit user approval
- [ ] All findings are sanitized (no user data, paths, or session IDs in
      captured artifacts)
- [ ] Deduplication works: repeated friction of the same type increments
      occurrence count, doesn't create duplicate entries
- [ ] Anti-noise guidance is effective: low-severity annoyances don't flood
      the high-priority queue
- [ ] System extends existing `self-reflect` and `create-issue`
      infrastructure — no parallel systems
- [ ] All tests pass (`make check`)
- [ ] Documentation updated: README mentions the onboarding feedback system,
      CONTRIBUTING.md references it

---

## Key Principles

1. **Feedback contribution is the path of least resistance.** It should be
   easier for an agent to capture friction than to work around it silently.
2. **Extend, don't duplicate.** Build on `self-reflect`, `create-issue`, and
   the existing agent roster.
3. **Human stays in control.** AI captures and drafts; humans approve before
   anything goes public.
4. **The feedback loop closes.** Friction → findings → issues → fixes →
   updated onboarding skill → smoother experience for next user.
5. **Noise control is first-class.** Severity classification, accumulation
   thresholds, and anti-noise guidance are not afterthoughts — they're design
   constraints from day one.

---

## Related Issues

- #189 — Overhaul the download/install UX (directly related: install friction
  is a primary source of onboarding findings)
- #5 — Refine CONTRIBUTING.md as Phase 2 lands (this system produces the raw
  material for that refinement)

## References

- `config/skills/core/self-reflect-skill.md` — existing session review
  infrastructure
- `config/skills/core/seal-usage.md` — auto-injection pattern for built-in
  skills
- `.agents/skills/create-issue/SKILL.md` — structured issue template
- `docs/2026-07-24-seal-usage-skill.md` — design pattern for adding built-in
  skills
- `docs/2026-07-24-workdir-escape-brainstorm.md` — example of a friction
  incident that this system would have captured automatically