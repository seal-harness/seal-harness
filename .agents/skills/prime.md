---
description: Load relevant knowledge from the docs/ directory into context before starting work
---

# Context Prime

**CRITICAL**: Do this at the START of any investigation, planning, or
implementation work to load relevant knowledge into your context.

## When to Use

- Starting work on a GitHub Issue
- Beginning investigation/research
- Before writing a plan
- Before implementing changes
- When switching to a new area of the codebase

## How It Works

Read the knowledge base files in `docs/knowledge/` to load facts relevant
to your current context, ensuring you:

1. Follow established patterns and rules
2. Avoid known gotchas and pitfalls
3. Make decisions aligned with architectural choices
4. Don't repeat mistakes that have been learned from

## Usage

### Quick Prime (Most Common)

Read the knowledge base files for general context:

```bash
cat docs/knowledge/*.jsonl | jq -r '.fact'
```

### Prime for a Specific Topic

Search for facts matching specific keywords:

```bash
cat docs/knowledge/*.jsonl | jq -r 'select(.fact | test("authentication"; "i")) | .fact'
```

### Prime for Specific Files

When working on specific files, search for facts that reference those
file patterns:

```bash
cat docs/knowledge/*.jsonl | jq -r 'select(.fact | test("src/lib/services"; "i")) | .fact'
```

## What Gets Loaded

### 1. MUST FOLLOW (Critical Rules)

Non-negotiable rules containing NEVER/ALWAYS/MUST:

- "NEVER use `as any` type casting"
- "ALWAYS use centralized AI config"
- Security-critical patterns

### 2. GOTCHAS (Common Pitfalls)

Known issues to avoid:

- "Truthy check fails for explicit zero values - use !== undefined"
- API behavior quirks

### 3. PATTERNS (Best Practices)

Established patterns in this codebase:

- "Use mock factories from test utilities"
- "Services should follow TDD (Red-Green-Refactor)"

### 4. DECISIONS (Architectural Choices)

Team/architectural decisions:

- "State management uses Zustand + TanStack Query"
- "AI providers implement Strategy Pattern"

### 5. API BEHAVIORS

External API quirks:

- "Prisma findMany returns [] not null"

## Integration Points

### In Planning Phase

Before writing a plan, read relevant knowledge:

```bash
cat docs/knowledge/*.jsonl | jq -r 'select(.fact | test("<task-keywords>"; "i")) | .fact'
```

### In Implementation Phase

Before writing code, check for patterns and gotchas related to the files
you'll touch:

```bash
cat docs/knowledge/gotchas.jsonl | jq -r '.fact'
cat docs/knowledge/patterns.jsonl | jq -r '.fact'
```

### In Review Phase

Before reviewing code, check for established patterns:

```bash
cat docs/knowledge/patterns.jsonl | jq -r '.fact'
cat docs/knowledge/anti-patterns.jsonl | jq -r '.fact'
```

## Context Recovery

When resuming after context compaction or in a new session, check for
active execution state:

### What Gets Loaded

1. **Active Plan** — reads `docs/plans/active-plan.md` if it exists with
   `status: in-progress`
2. **Project Context** — reads `docs/context/project-context.md`
   (completed work units, established patterns, tooling)
3. **Execution State** — reads `docs/context/execution-state.md`
   (current work unit, phase, retry count)
4. **Knowledge Base** — all the usual MUST FOLLOW, GOTCHAS, PATTERNS,
   DECISIONS facts

### Recovery Flow

```bash
# 1. Check for active execution
if [ -f docs/plans/active-plan.md ]; then
  grep -q 'status: in-progress' docs/plans/active-plan.md && echo "ACTIVE PLAN FOUND"
fi

# 2. Load all context files
cat docs/plans/active-plan.md           # The approved plan
cat docs/context/project-context.md     # Completed work, patterns
cat docs/context/execution-state.md     # Where we left off

# 3. Load relevant knowledge base facts
cat docs/knowledge/*.jsonl | jq -r '.fact'
```

### When Recovery Triggers Automatically

- Orchestrated execution starts and finds `docs/plans/active-plan.md`
  with `status: in-progress` but has no plan in its current context
- A new session begins and active execution state is detected
- After context compaction, when the agent recognizes it has lost
  plan/execution context

## Verification

After priming, you should be able to answer:

1. What are the critical rules I must follow?
2. What gotchas should I watch out for?
3. What patterns should I apply?
4. What architectural decisions constrain my options?
5. (If recovery mode) Where did execution stop and what comes next?