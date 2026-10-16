---
name: copy-harness-feature
description: >
  Research how other top-tier LLM agent harnesses implement a feature, then
  adapt it for seal-harness. Spawns the harness-researcher agent to study
  existing implementations, consolidates findings into a seal-harness design
  doc, and routes through the design review gate. Use this skill whenever the
  task is to add a feature to seal-harness that likely exists in other
  harnesses — cron jobs, background tasks, MCP support, diff review,
  subagent orchestration, git integration, web browsing, file watching,
  persistent memory, skill systems, or anything where studying prior art
  would inform the design. Even if the user doesn't say "copy" or "research
  other harnesses," use this skill when the feature is well-known in the
  harness ecosystem and seal-harness doesn't have it yet.
---

# Copy Harness Feature

Research a feature as implemented across top-tier LLM agent harnesses, then
adapt the best ideas into a seal-harness design doc and implementation plan.

This is the starting point for any feature that exists in the broader harness
ecosystem but isn't yet in seal-harness. The skill handles the full arc:
research → synthesis → design doc → review gate → plan. It does NOT handle
implementation — once the plan is approved, hand off to `start-task` or
`orchestrated-execution`.

## Usage

```
/copy-harness-feature <feature description>
```

## When to use

- User says "add cron jobs" / "add scheduled tasks" / "add recurring jobs"
- User says "implement <X> like <other harness> has"
- User describes a feature that's common in the harness world (background
  tasks, MCP, diff review, file watching, persistent memory, etc.)
- User wants to study how others do something before building it here
- Any feature where prior art in other harnesses would meaningfully inform
  the design — which is most features

## When NOT to use

- Bug fixes or modifications to existing seal-harness features (use `start-task`)
- Pure research with no intent to build (just spawn the researcher directly)
- Features unique to seal-harness's security model with no analog elsewhere
- Refactoring or cleanup tasks

## The Workflow

### Phase 1: Frame the Feature

Before spawning research, make sure the feature is well-scoped. A vague
"add background tasks" produces vague research. Clarify with the user:

1. **What exactly does the feature do?** One sentence, user-facing.
2. **What's the seal-harness analog?** Which ISA layer does it touch?
   - A new opcode? (most common — see the opcode recipe below)
   - A new backend/handle in the `Backends` record?
   - A new channel or provider?
   - A CLI subcommand?
   - Frontend UI?
3. **What are the key design questions?** List 3-5 questions the research
   should answer. Examples:
   - "How do other harnesses persist scheduled job definitions?"
   - "What execution model do they use — in-process threads, external
     processes, or a job queue?"
   - "How do they handle failures, retries, and concurrency limits?"

If the user's description is already specific enough, skip the clarification
and proceed. Don't over-interview for a clear request.

### Phase 2: Research (Spawn the Harness Researcher)

Spawn the `harness-researcher` agent to investigate how other harnesses
implement the feature. This is a sub-agent that explores multiple harness
repos using CodeGraph and web search.

**Spawn it with:**

- A clear goal describing the feature to research
- Context about seal-harness's architecture so the research is relevant
- The key design questions from Phase 1
- A request for a structured markdown report

The researcher will explore harnesses like: Claude Code, Cursor, Aider,
Cline/OpenHands, Devin, SWE-agent, AutoGPT, BabyAGI, AgentGPT, Goose,
Continue, Kotaemon, Sweep, and others it discovers. For each harness that
has the feature, the report should cover:

1. **What the feature does** — user-facing description
2. **How users define/configure it** — API, syntax, config format
3. **How it's stored/persisted** — file format, database, in-memory
4. **How it's triggered/executed** — scheduler, event loop, external cron
5. **Error handling** — retries, backoff, dead-letter, notifications
6. **Security model** — sandboxing, permission gates, audit logging
7. **What works well** — strengths worth copying
8. **What doesn't work** — weaknesses to avoid

The report should also note which harnesses do NOT have the feature.

**While the researcher runs**, study the relevant parts of the seal-harness
codebase so you're ready to synthesize:

- Read the opcode pattern (see the recipe below)
- Identify which trust level the new feature needs (Trusted / Untrusted /
  Audited)
- Identify which backend/handle it would use or need
- Check for related existing opcodes it would interact with
- Note any security invariants that constrain the design

### Phase 3: Synthesize

When the research report arrives, synthesize it into a **feature analysis**
adapted for seal-harness. This is NOT the design doc yet — it's the bridge
between "what others do" and "what seal-harness should do."

Write the analysis to `docs/superpowers/specs/<date>-<feature>-research.md`:

```markdown
# Feature Research: <Feature Name>

## Summary
One-paragraph summary of what the feature is and why seal-harness needs it.

## Prior Art Survey

### <Harness 1>
- **Approach**: ...
- **Storage**: ...
- **Execution**: ...
- **Security**: ...
- **Verdict**: Worth copying / Adapt / Avoid

### <Harness 2>
...

## Cross-Cutting Patterns
What approaches appear across multiple harnesses? What's the consensus?

## Key Design Decisions for Seal-Harness
For each design question from Phase 1, state the answer informed by research:

1. **<Question>**: <Answer + rationale, citing which harnesses informed it>
2. ...

## Seal-Harness Architecture Fit
- **Trust level**: Trusted / Untrusted / Audited — and why
- **Opcodes needed**: New opcode name(s) and action structure
- **Backend/handle**: What goes in the `Backends` record (if anything)
- **Security invariants**: What constraints apply (no shell in Trusted,
  type-guaranteed sanitization, transcript as source of truth, etc.)
- **Interaction with existing opcodes**: Which opcodes it calls or affects

## Open Questions
Things the research didn't fully resolve — for the design review gate.
```

Present this analysis to the user for review before proceeding to the
design doc. The user may want to redirect based on the findings.

### Phase 4: Design Doc

After the user approves the research synthesis, write a full design doc
to `docs/superpowers/specs/<date>-<feature>-design.md`. Follow the existing
design doc format in that directory — read 1-2 existing specs first to
match the style.

The design doc should cover:

1. **Problem statement** — what user need this addresses
2. **Proposed approach** — the seal-harness-specific design, informed by
   the research synthesis
3. **Opcode specification** — the full `*_MANAGE` opcode with its action
   enum, input/output JSON schemas, authorization gate, and trust level
4. **Backend design** — new types, stores, or handles needed
5. **Security analysis** — how the design preserves seal-harness's
   security invariants
6. **Testing strategy** — unit tests, integration tests, QuickCheck
   properties for security-critical pure functions
7. **File impact** — list of files to create/modify
8. **Cabal wiring** — new modules in `exposed-modules:` and
   `other-modules:`

### Phase 5: Design Review Gate (MANDATORY)

After the design doc is written, **STOP**. Do not proceed to planning or
implementation. Run the Design Review Gate:

- Load the `design-review-gate` skill
- Spawn the 5 parallel reviewers (PM, Architect, Designer, Security, CTO)
- Wait for ALL 5 to approve
- Only after approval, proceed to Phase 6

This is non-negotiable — the design review gate catches architectural
issues before expensive planning begins.

### Phase 6: Implementation Plan

After design approval, create an implementation plan:

1. Write the plan to `docs/superpowers/plans/<date>-<feature>.md`
2. Run the **Plan Review Gate** (`plan-review-gate` skill) — 3 adversarial
   reviewers (Feasibility, Completeness, Scope & Alignment) must all PASS
3. Present the approved plan to the user
4. Ask the user which execution approach they want:
   - Orchestrated execution (4-phase loop per work unit)
   - Subagent-driven (parallel sub-agents)
   - Single-session implementation
5. Hand off to the chosen execution path

---

## Seal-Harness Opcode Recipe (Quick Reference)

When the feature requires a new opcode, here's the pattern to follow. This
is a quick reference — read the full recipe in the project guide and study
existing opcodes (e.g. `src/Seal/ISA/Ops/Skills.hs`, `src/Seal/ISA/Ops/Memory.hs`)
for complete examples.

### Trust Level Selection

| Trust Level | When to use |
|---|---|
| **Trusted** | Harness-internal operations (sessions, scheduling, human interaction). In-process, logged in session transcript. |
| **Audited** | Trusted + writes to the global cross-session append-only log (memory, skills, agent defs, config). Use for any persistent state that should survive across sessions. |
| **Untrusted** | Interacts with the outside world (shell, files, web, browser). Runs in isolated env. ACK-before-execute. Never import `System.Process`/`System.Directory`/`System.Posix` — call `UntrustedIO` methods. |

### Consolidated MANAGE Pattern

Most opcode groups use a single `*_MANAGE` opcode with an `action` field:

```haskell
data FeatureAction = ActCreate | ActRead | ActList | ActDelete

parseFeatureAction :: Value -> Either Text FeatureAction
parseFeatureAction v = case parseMaybe (withObject "in" (.: "action")) v of
  Just t -> case t :: Text of
    "create" -> Right ActCreate
    "read"   -> Right ActRead
    "list"   -> Right ActList
    "delete" -> Right ActDelete
    other    -> Left ("unknown action: " <> other)
  Nothing   -> Left "missing action field"

featureManageOp :: SomeBackend -> Opcode
featureManageOp backend = TrustedOpcode  -- or Audited via toTrust = Audited
  { toName       = OpName "FEATURE_MANAGE"
  , toTrust      = Trusted
  , toDesc       = "Manage features. Use action to select: create, read, list, delete."
  , toInSchema   = object [ ... action enum + per-action fields ... ]
  , toOutSchema  = object []
  , toAuthorize  = authorizeFeatureManage
  , toBlocking   = False
  , toRun        = \_ v -> case parseFeatureAction v of
      Left e -> pure (OpResult [TrpText e] True (object []))
      Right action -> case action of
        ActCreate -> handleCreate backend v
        ActRead   -> handleRead   backend v
        ActList   -> handleList   backend
        ActDelete -> handleDelete backend v
  }
```

### Wiring Points (4 places)

1. **`seal-harness.cabal`**: Add `src/Seal/ISA/Ops/Feature.hs` to library
   `exposed-modules:` and `test/Seal/ISA/Ops/FeatureSpec.hs` to test-suite
   `other-modules:`.
2. **`test/Main.hs`**: Import and register the test spec.
3. **`src/Seal/Core/TurnEngine.hs`**: Add the opcode to the `baseOps` list
   (constructed with its backend dependency from `backends`).
4. **`src/Seal/Core/Backends.hs`**: If the feature needs a new persistent
   store, add it to the `Backends` record and initialize it in
   `newBackends`.

### OpResult Contract

```haskell
OpResult
  { orParts    :: [ToolResultPart]  -- what the model sees (may include secrets)
  , orIsError  :: Bool              -- is this an error?
  , orRecorded :: Value             -- what the transcript stores (MUST be secret-free)
  }
```

Secret values go in `orParts` only. `orRecorded` is persisted to disk and
must never contain secrets. If the opcode returns secrets, add its name to
`secretOpcodes` in `Registry.hs`.

### Security Invariants (Non-Negotiable)

1. **No shell-wrapping in Trusted/Audited opcodes.** No `sh -c`, no
   constructed command strings. Direct mechanisms only.
2. **Type-guaranteed argument sanitization.** Every value from user/LLM
   input that reaches a subprocess argv must be a validated smart-constructed
   newtype — never raw `Text`/`String`.
3. **Transcript as source of truth.** All derived stores are materialized
   views rebuilt from transcript replay.
4. **ACK-before-execute for Untrusted opcodes.** The dispatcher durably
   records the invocation (synchronous fsync) before executing.

---

## Common Pitfalls

- **Don't copy identifiers or code from other harnesses.** Port the idea,
  write it fresh in the `Seal.*` namespace. The clean-room rule is
  non-negotiable.
- **Don't skip the design review gate.** It catches architectural issues
  that are expensive to fix after implementation starts.
- **Don't design in a vacuum.** The research phase exists because other
  harnesses have solved these problems — learn from their mistakes.
- **Don't forget the `.cabal` and `test/Main.hs` wiring.** These are merge
  hotspots — keep edits minimal and rebase before opening a PR.
- **Don't over-engineer.** If the research shows most harnesses do
  something simply, don't add complexity seal-harness doesn't need. The
  security model is already the complexity budget.