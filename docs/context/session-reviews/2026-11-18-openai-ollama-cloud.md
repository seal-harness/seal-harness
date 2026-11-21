# Session review — openai-and-ollama-cloud implementation

**Date:** 2026-11-18
**Scope:** two new provider types + `openai` → `openai-compatible` rename; three
work units through the 4-phase loop, plus four correction rounds.

> NOTE: this review could not be written to `~/.seal/learnings/` as the
> `seal-session-review` skill specifies — Seal blocks all opcode access under
> `~/.seal/` (AGENTS.md rule 3). That is the harness correctly enforcing its own
> boundary, and it is itself finding UPSTREAM-1 below. Filed here instead.

## Summary

Six commits landed: 3 feature units + 3 correction commits. `make check` green
(4693 backend examples / 1135 frontend tests). Both gates passed. The work is
correct, but the session spent a disproportionate share of effort on **five
defects of one repeated class**, four caught only by negative control.

## Findings

### LOCAL-1 — "Documented ≠ measured": five instances of one defect class
severity: **high** · repair_target: **skill**

Five documents or comments asserted a fact about the code that a single grep or
test would have refuted:

1. **Design D7** claimed the wizard needed no change to field visibility. It did:
   `showBaseUrl={needsBaseUrl}` hid Ollama's Base URL entirely, deleting the only
   GUI path to a remote daemon. This survived **5 design reviewers and a
   3-reviewer plan gate.**
2. **Design item 21** was specified but never budgeted to a test, because
   `staticModelsFor` is not exported and "not exported" was read as "not testable".
3. **CHANGELOG.md** still documented the generic type as `openai` with
   `OPENAI_API_KEY` and "four providers" after shipping six and a rename —
   instructing users into the exact misconfiguration the rename prevents.
4. **Serve.hs:694** used `[providers.openai] base_url` as its example, which after
   the rename reads as "real OpenAI needs a base_url".
5. **providerLabels.ts** referenced a `DISAMBIGUATED` section that does not exist.

Every one was caught by *measuring* (grep, failing test, negative control),
never by re-reading prose.

**Repair:** When a document states a property of the code — "X is already
correct", "the compiler catches Y", "this needs no change" — replace it with the
command that measured it, or delete the claim. A sentence asserting code
behaviour is unverified by default.

### LOCAL-2 — Negative control found four vacuous tests that review passed
severity: **high** · repair_target: **skill**

Four tests looked complete but could not fail:

| Test | Why it couldn't fail | Found by |
|---|---|---|
| item 21 | did not exist | review |
| item 21b | one fixture where two paths needed testing | review |
| wizard item 41b | asserted the field *renders*, not that it is *submitted* | my own injection |
| edit-path base_url | no test observed the unguarded edit payload | my own injection |
| `ollama-cloud` visibility half | zero assertions | review |

Each proven by injecting the corresponding bug and watching the test stay green,
then rewritten until it went red.

**Repair:** Make "prove the assertion non-vacuous by injecting the bug and
watching the test fail" a required step for any credential-adjacent or
visibility behaviour, with the injection recorded in the commit message.

### LOCAL-3 — Broad reviewer prompts time out; narrow ones work
severity: **medium** · repair_target: **missing_capability** (UPSTREAM)

Every *broad* multi-area review prompt timed out with no verdict (plan gate
feasibility, plan gate completeness, plan gate scope ×2, WU3 combined review).
Every *narrowed* prompt — one question, explicit tool-call budget, "do not read
whole files" — returned a verdict. Two of three reviewers returning nothing is
not a gate; it is a coin flip with extra steps.

**Repair:** Give gate reviewer defs an explicit tool-call budget and a "one
question per reviewer; split rather than broaden" rule. On timeout, auto-split
into per-area halves on retry instead of re-running identically.

### LOCAL-4 — Gate reviewer agent defs were stale
severity: **medium** · repair_target: **config**

`plan-feasibility-reviewer`, `plan-completeness-reviewer` and `plan-scope-reviewer`
hardcoded a repo path from a **different session**
(`.../workdirs/20261104-073246-648/...`), and two carried a checklist for an
unrelated previous task ("fix the scroll-to-top bug; take statefulness out of
rendering code"). Had these not been overridden per-invocation, the gate would
have produced confident verdicts about work nobody asked for.

**Repair:** Agent defs must not embed a workdir path (derive from session) or a
task-specific rubric (pass per invocation).

### LOCAL-5 — Work-unit file lists break on shared test fixtures
severity: **low** · repair_target: **skill**

WU1's declared file list omitted two spec files whose 4-card and 4-provider
fixtures necessarily break when constructors land. Predictable at planning time.

**Repair:** In the plan's work-unit section, add an "existing assertions that
encode the value being changed" sweep — grep the old value across `test/` and
assign every hit to a unit.

### UPSTREAM-1 — The session-review skill writes to a path agents may not touch
severity: **medium** · repair_target: **harness_template**

`seal-session-review` instructs writing findings to `~/.seal/learnings/`. Seal
blocks all opcode access under `~/.seal/`, so the write fails with `PathIsBlocked`.
The skill's storage layout needs to live somewhere an agent can write (repo
`docs/context/`, or a harness-provided API), or the review must be
human-driven admin.

## What worked, worth keeping

- **Negative control (bug injection)** — the single most effective technique;
  found four defects that both self-review and adversarial review had passed.
- **Splitting timed-out reviews** into one-question halves recovered three gate
  rounds that would otherwise have been lost silently.
- **Deriving reserved names from `knownProviders`** rather than a literal list
  made a whole class of drift structurally impossible; the reviewer confirmed it.
- **Recording the gate's own flakiness** (2 timeouts + 3 retries) in the plan
  rather than presenting a clean 3/3.
