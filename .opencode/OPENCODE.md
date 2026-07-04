# Project Instructions

This project uses [metaswarm](https://github.com/dsifry/metaswarm), a multi-agent orchestration framework for OpenCode. It provides specialized agents, commands, and quality gates that enforce TDD, coverage thresholds, and spec-driven development.

## How to Work in This Project

### Starting work

Start by priming context with relevant knowledge, then begin tracked work:

```text
/prime
/start-task <task-description>
```

This primes the agent with relevant knowledge, guides you through scoping, and picks the right level of process for the task.

### Design review (limited in this POC)

After writing a design document, you can request a review:

```text
/review-design
```

> **POC limitation:** the full parallel review gate uses 5 specialist reviewers
> (PM, Architect, Designer, Security, CTO). All 5 reviewer agents are now registered,
> but the `/review-design` command still routes to a single `@architect-agent` review
> until the parallel gate is wired up. You can invoke the other reviewers manually
> via `@product-manager-agent`, `@designer-agent`, `@security-design-agent`, `@cto-agent`.

### Available Commands

| Command | Purpose |
|---|---|
| `/prime` | Load relevant knowledge from the BEADS knowledge base |
| `/start-task` | Begin tracked work on a task with complexity assessment |
| `/review-design` | Architecture-focused design review (single `@architect-agent` in this POC, not the full 5-agent gate) |

### Available Agents

| Agent | Purpose |
|---|---|
| `@issue-orchestrator` | Main coordinator per issue — spawns sub-agents, runs 4-phase execution loop |
| `@swarm-coordinator-agent` | Meta-orchestrator managing multiple issues/epics in parallel across worktrees |
| `@architect-agent` | Reviews technical architecture and creates implementation plans |
| `@coder-agent` | TDD implementation of features and fixes |
| `@test-automator-agent` | Test writing and coverage analysis |
| `@researcher-agent` | Codebase exploration and prior art research |
| `@code-review-agent` | Internal code review before PR creation |
| `@cto-agent` | Plan review and architectural guidance |
| `@designer-agent` | UX, API design, and developer experience review |
| `@product-manager-agent` | Use case validation and user benefit review |
| `@security-auditor-agent` | Security vulnerability detection and OWASP compliance |
| `@security-design-agent` | Security review of designs before implementation |
| `@customer-service-agent` | User issue investigation and support (read-only) |
| `@sre-agent` | Production system monitoring and incident response (read-only) |
| `@metrics-agent` | Collect, aggregate, and report on agent swarm performance |
| `@knowledge-curator-agent` | Knowledge extraction and curation |
| `@pr-shepherd-agent` | PR lifecycle management through to merge |
| `@release-engineer-agent` | Safe delivery of approved code from merge through production verification |
| `@slack-coordinator-agent` | Human-agent communication bridge via Slack |

## POC Scope

Full agent roster is registered (19/19). Commands are partially wired: 6 of 13 commands registered. Remaining commands will be added incrementally in follow-up PRs.

## Current Limitations

- BEADS integration via `.opencode/plugins` is not yet implemented
- Session hooks (compacting, session events) are not configured
- Skills discovery is not wired
- Commands: 7 of 13 not yet registered (`/self-reflect`, `/handoff`, `/status`, `/migrate`, `/handling-pr-comments`, `/visual-review`, `/external-tools`)
- Design review gate runs only `@architect-agent`; the other 4 reviewers (PM, Designer, Security Design, CTO) are now registered and can be invoked, but the `/review-design` command itself still routes to a single reviewer until the parallel gate is wired up
