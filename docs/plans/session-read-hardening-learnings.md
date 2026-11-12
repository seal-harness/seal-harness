# Session Read Hardening — Execution Learnings

Post-execution knowledge capture for the read-hardening branch
(fix/session-self-read-guard, 2026-10-22/23). Source: the five-work-unit
orchestrated execution (docs/plans/session-read-hardening-plan.md) and its
review-gate + adversarial-review findings.

## The incident class (why this branch exists)

A model debugging sub-agents read its own session transcript via
`SESSION_MANAGE get` four times; each read result was appended to the same
transcript, so each successive read included the outputs of every previous
read. Four calls produced ~3.4MB of echo in ~11 minutes (320KB → 585KB →
698KB → 1.84MB) until the provider rejected the turn with
"context window exceeds limit". Message-count pagination never fired —
`limit=10` still returned 1.84MB because limits capped COUNT, not BYTES.

## Durable lessons

1. **Byte budgets must cover ALL rendered bytes, including metadata.** The
   first WU1 adversarial review caught that the rendered session-meta
   header embeds the unbounded agent-controlled `description` — a 1MB
   description produced a >1MB page with `truncated:false`. Budget the
   whole page: header cap (2048) + body + footer reserve, with a per-message
   cap for per-message degradation.
2. **Guard by construction, not by lookup.** The lineage guard threads the
   ancestor chain through the spawn path and bakes it into the ops at
   registry-build time. Persisted-meta lookup was infeasible for children
   (`saveSessionMeta` writes top-level only; finding a child's meta needs
   the directory scan the guard exists to avoid). Baked chains are also
   robust to future id rotation (compaction) by construction.
3. **Security-relevant refactor extractions must be diffed, not trusted.**
   `writeMetaFileAtomic` was extracted from `saveSessionMeta`'s body; the
   reviewer hand-diffed old vs new to prove the temp-file uniqueness, 0600
   chmod, and atomic rename survived. That concurrency-collision protection
   is invisible to tests and easy to drop silently.
4. **Dead mirror fields with false provenance comments are a distinct
   hazard class.** `aswParentLineage` was assigned everywhere and read
   nowhere, while comments claimed it was the lineage source — on the
   security-critical path. `-Werror`/hlint cannot catch unread record
   fields. Only the FINAL cross-unit review found it; every per-unit
   review passed it because each unit's own scope was correct. Rule: every
   added record field needs a named reader, and comment claims about data
   flow must be checked against actual read sites.
5. **The plan review gate paid for itself.** Three adversarial iterations
   caught two design errors that would have stranded mid-implementation:
   (a) child-meta lookup could not work as specified (the walk needs the
   excluded scan), (b) the repeat registry's origination layer
   (`newChannelDeps`/TUI/CLI, never inside per-request `mkWebTurnDeps`)
   was misattributed — a per-request registry compiles green and passes
   unit tests while silently resetting the cross-turn window.
6. **Process notes.** `-Werror` turns record-field additions into
   build-verified literal sweeps (let the compiler find sites, don't trust
   hand lists). TDD red in Haskell under `-Werror`: a `_`-prefixed unused
   binding observes runtime red before the implementation exists. The
   `RegistrySpec agentStatus records Crashed` test is a documented
   load-sensitive flake: policy = verify in isolation, re-run the gate.

## Reviewer-recorded residual risks (accepted, follow-up material)

- `readConvLines` drops malformed lines, so on a CORRUPT transcript the
  idx-path margin/window split and rendered global indices can shift
  (guards unaffected; corruption-only path). Comment understates this.
- No direct loop-level test that repeated REFUSED reads escalate through
  the repeat window to a block (structural placement, verified by review).
- `repeatScope` covers SESSION_MANAGE as a whole, so repeated identical
  `new`/`list`/`search` calls also warn/block (read the thresholds as
  applying to the opcode, not strictly to reads).
- Message-id anchoring (`around_message_id`) deferred: `Message` carries
  no id; needs a transcript format change — revisit with any compaction
  feature, which would also motivate it.