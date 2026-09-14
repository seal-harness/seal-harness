# Task Management Guide

This guide covers best practices for tracking progress using task
documents — markdown files in `docs/tasks/`. Task documents are the
single source of truth for task tracking in your project.

**Do NOT use TodoWrite, TodoRead, or TaskCreate tools.** Use task
documents exclusively.

## Task Management with Task Documents

**CRITICAL**: Always maintain accurate issue status to ensure task
completion and proper tracking.

## When to Use Task Documents

Use task documents for:

- Complex multi-step tasks (3+ distinct steps)
- Non-trivial and complex tasks requiring careful planning
- Features, bugs, and epics
- Multiple tasks provided by user (numbered or comma-separated)
- Tasks requiring systematic tracking
- When you need to maintain state across a long conversation

### Skip task documents for:

- Single, straightforward tasks
- Trivial tasks where tracking provides no benefit
- Tasks completable in less than 3 trivial steps
- Purely conversational or informational requests

## Checking Available Work

Check current task list frequently, especially:

- At the beginning of conversations: `ls docs/tasks/*.md`
- Before starting new tasks: `grep -l "status: open" docs/tasks/*.md`
- After completing tasks: `grep -l "status: open" docs/tasks/*.md`
- When uncertain about next steps: `grep -l "status: in_progress" docs/tasks/*.md`
- **Before any context switch or branch change**

## Updating Task Status

Update task status in real-time by editing the markdown file's front
matter:

- Mark tasks as `in_progress` BEFORE starting work
- Only have ONE task `in_progress` at a time
- Mark as `completed` IMMEDIATELY after finishing — update the status
  field and add a completion note
- Use for tasks with 3+ steps or requiring systematic tracking
- **NEVER leave tasks as `in_progress` when switching context**

## Task Management Rules

### 1. No Abandoned Tasks

If you can't complete a task, update its document with notes:

```markdown
---
status: blocked
notes: "Blocked on X. Remaining: Y and Z."
---
```

### 2. Context Switches

Before changing branches or starting new work:

- Check all `in_progress` tasks: `grep -l "status: in_progress" docs/tasks/*.md`
- Either close them or update with notes
- Inform user of any incomplete work

### 3. Task Handoff

When a task needs user action:

- Update the task document with clear next steps in a "Notes" section
- Notify user explicitly

### 4. Dependencies

When tasks depend on each other, list them in the task document's front
matter:

```yaml
---
depends_on:
  - docs/tasks/001-setup-auth.md
  - docs/tasks/002-auth-middleware.md
---
```

## Task States

- **open**: Task not yet started
- **in_progress**: Currently working on (limit to ONE at a time)
- **blocked**: Waiting on a dependency or human decision
- **completed**: Task finished successfully

## Task Document Format

```markdown
---
title: "Implement feature X"
status: open
type: task
priority: 2
labels:
  - waiting:human
depends_on: []
created: 2026-01-15
completed: null
---

# Implement feature X

## Description

Brief description of the task.

## Definition of Done

- [ ] Tests written and passing
- [ ] Implementation complete
- [ ] Code review passed

## Notes

Add progress notes here as work progresses.
```

## Task Document Workflow Example

```bash
# 1. Check available work
ls docs/tasks/*.md
grep -l "status: open" docs/tasks/*.md

# 2. Review task details
cat docs/tasks/001-implement-feature-x.md

# 3. Claim it — edit the status field to in_progress
# (edit the markdown file's front matter)

# 4. Complete the work

# 5. Mark task complete — update status to completed and add completion note
# (edit the markdown file's front matter)

# 6. Find next task
grep -l "status: open" docs/tasks/*.md

# 7. Commit changes (task documents are plain markdown, synced via git)
git add docs/tasks/
git commit -m "docs: update task status"
```

## Creating New Tasks

Create a new markdown file in `docs/tasks/` with the task document format
shown above.

## Integration with Other Workflows

- Before creating PRs: Ensure all related tasks are marked completed
- Before context switches: Review and update all in_progress items
- During long tasks: Periodically update progress notes in the task document
- After completing features: Close all related task documents
- At session end: Commit any task document changes to git