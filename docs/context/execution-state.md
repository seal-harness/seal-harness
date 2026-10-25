# Execution State
<!-- updated: 2026-10-23 (merge of main into fix/session-self-read-guard) -->

> **Work streams in this repo.** Two streams are recorded here: the session
> read hardening branch (this branch — COMPLETE) and the sub-agent
> completion delivery stream (merged from main; handoff at
> `docs/handoffs/handoff-2026-10-22-subagent-completion-delivery.md`).

## Session read hardening (this branch — COMPLETE, merged with main)

- Plan: `docs/plans/session-read-hardening-plan.md` (gate: 3/3 PASS)
- Branch: `fix/session-self-read-guard`
- Learnings: `docs/plans/session-read-hardening-learnings.md`

| WU | Title | Status |
|----|-------|--------|
| pre-plan | Self-read refusal + search self-exclusion | COMPLETE (13b8501) |
| WU1 | Byte-bounded reads + conversation.idx windowing | COMPLETE (cd005e0) |
| WU2 | Read-path secret redaction | COMPLETE (bba7b90) |
| WU3 | smParent + baked-lineage guard + search caps | COMPLETE (7cd342c) |
| WU4 | Repeat detection (warn ≥2 / block ≥4 / window 16) | COMPLETE (0173564) |
| WU5 | around_index anchor windowing | COMPLETE (226016f) |
| final | Dead aswParentLineage cleanup + learnings | COMPLETE (76f10af, 0704e76) |

Final comprehensive review: PASS (all 10 cross-unit checks).
PR creation intentionally deferred per maintainer.

## Sub-agent completion delivery (from main)

- Plan: `docs/plans/2026-10-22-subagent-completion-delivery-fix-plan.md`
  (gate: 3/3 PASS)
- Handoff: `docs/handoffs/handoff-2026-10-22-subagent-completion-delivery.md`
- Branch: `fix/subagent-completion-delivery-diagnostics` · PR #279

| WU | Title | Status |
|----|-------|--------|
| WU-1 | Reproduce the bug with a failing test | COMPLETE — R1/R2/R3 fail deterministically (20 runs) |
| WU-2 | Record the completion handoff durably | COMPLETE — R1/R2 pass |
| WU-3 | Deliver completions that arrive during a turn | COMPLETE (f05b5e3; adversarial review PASS) |
| WU-4 | Wake-path hygiene (mutex leak, skip warning, pending count) | COMPLETE (532504c; adversarial review PASS) |
| WU-5 | Final review, tracking items, self-reflect, PR | NOT STARTED |

Session note (2026-10-23): `Seal.Agent.Runtime.Registry > agentStatus >
records Crashed when the worker throws` flaked once under full-suite load
(its poll is capped at ~2s and its own comment documents the history).
Unrelated to either work stream — tracking item for a load-tolerant wait.