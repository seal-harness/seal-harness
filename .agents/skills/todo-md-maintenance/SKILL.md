---
name: todo-md-maintenance
description: Lightweight, injectable skill for targeted TODO.md edits from any conversation context. Add items, update status, check current state. For full-sync maintenance, use the todo-manager agent instead.
---

# TODO.md Maintenance (Injectable)

## Overview

A **lightweight skill** that any agent can load mid-conversation to make targeted edits to a project's TODO.md. Add a to-do item from current context, update an item's status, or read the current state. No full GitHub sync, no issue reconciliation — just the operation you need, right now.

For full maintenance (sync all issues, reconcile phases, restructure sections), start the **todo-manager agent** instead.

## When to Use

- You're deep in a conversation and something comes up that needs tracking → `todo-add`
- You just finished a task and want to mark it done → `todo-update`
- You need to check what's on the list before starting work → `todo-check`
- You're in any agent session with context about a specific item that belongs on the list

## When NOT to Use

- You need to sync TODO.md with all GitHub issues → start the todo-manager agent
- You need to restructure sections or reconcile phase status → start the todo-manager agent
- You need a standup report → start the todo-manager agent

## TODO.md Format Reference

```markdown
# [Project Name] — TODO

## Status: [current phase or milestone]

## Roadmap
- [x] **Phase N** — [name]
- [~] **Phase N** — [name] ([link to plan])
- [ ] **Phase N** — [name]

## Active Work
- [~] [Item being implemented] — [link to plan/issue]
- [ ] [Item ready to implement]

## Known Issues
### Critical
- #[NN] [Title] ([labels])
### High
- #[NN] [Title] ([labels])
### Help Wanted
- #[NN] [Title] ([labels])

## Backlog
- [ ] #[NN] [Title]

## Done
- [x] [Phase/feature name] — [brief note, PR ref]

<!-- Last updated: YYYY-MM-DD by [agent name] -->
```

**Checkbox semantics:** `- [ ]` not started · `- [~]` in progress · `- [x]` done

## Operations

### todo-check: Read current state

Read the project's TODO.md to understand what's on the list. No changes, just context.

```bash
cat TODO.md
```

If no TODO.md exists, report that to the user and offer to create one (or suggest starting the todo-manager agent).

### todo-add: Add a single item

Add one item to the appropriate section of TODO.md. The item should come from current conversation context — a decision was made, a problem was found, a feature was discussed.

**Steps:**
1. Read the current TODO.md
2. Determine which section the item belongs in:
   - **Active Work** — something being implemented now or ready to start (has a plan or is about to get one)
   - **Known Issues** — a GitHub issue exists (`#NN` reference). Use priority subsections.
   - **Backlog** — no issue yet, no plan yet, just "we should do this someday"
3. Write the item in the existing format style
4. Update the timestamp comment
5. Commit if in a git repo: `git add TODO.md && git commit -m "docs: add [short description] to TODO.md"`

**Item format:**
- With GitHub issue: `- [ ] #NN [Title] ([labels])`
- With plan link: `- [ ] [Title] — [link to plan]`
- No issue or plan: `- [ ] [Title]`

**Rules:**
- Add to the END of the target section (preserve existing order)
- Match the existing formatting style exactly
- One item per invocation — don't batch-add
- If the item already exists (same issue number or very similar title), don't duplicate. Tell the user.

### todo-update: Update an item's status

Change the status of a single item in TODO.md.

**Steps:**
1. Read the current TODO.md
2. Find the item (by issue number, or by searching for matching text)
3. Update the checkbox:
   - Not started → In progress: `[ ]` → `[~]`
   - In progress → Done: `[~]` → `[x]` (and move to Done section)
   - Not started → Done: `[ ]` → `[x]` (and move to Done section)
4. If moving to Done: add brief note with PR ref or date if available
5. Update the timestamp comment
6. Commit: `git add TODO.md && git commit -m "docs: update [item] status in TODO.md"`

**Moving to Done:** When marking an item done, move it from its current section (Active Work, Known Issues, Backlog) to the Done section. Add it at the top of Done (most recent first). Include a brief note if a PR or issue closure is associated.

## Pitfalls

### Don't restructure
This skill makes targeted edits. Don't reorganize sections, change the format, or rewrite the file. If the structure needs changing, start the todo-manager agent.

### Don't duplicate
Before adding, scan the existing TODO.md for the same issue number or a very similar title. If found, tell the user it's already there.

### Timestamp discipline
Always update the `<!-- Last updated -->` comment. This is how the todo-manager agent knows when the last targeted edit happened vs when a full sync is needed.

### Don't touch items you don't understand
If you can't find the item by issue number or clear text match, ask the user rather than guessing. Better to ask than to edit the wrong line.

## Related

- **todo-manager agent** (`.agents/agents/todo-manager/agent.md`) — Full TODO.md maintenance: sync with GitHub, reconcile all issues, restructure sections, generate standup reports. Start as a fresh session when you need the heavy lifting.
- **ceo-agent-github-loop** — Autonomous development loop that uses GitHub Issues as the work queue. TODO.md can coexist as the navigation layer.