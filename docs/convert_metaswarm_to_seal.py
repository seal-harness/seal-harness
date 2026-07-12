#!/usr/bin/env python3
"""Convert metaswarm agents/skills/commands into seal-harness format.

Seal agents  -> ~/.seal/config/agents/<id>.md  (flat scheme: frontmatter + body)
Seal skills  -> ~/.seal/config/skills/<id>.md  (frontmatter + body)

Usage:
    python3 docs/convert_metaswarm_to_seal.py

This script reads the metaswarm content from .opencode/ (agents, skills, commands)
and writes seal-compatible flat-scheme Markdown files into ~/.seal/config/.

The conversion:
1. Agents: Each .opencode/agents/<id>.md becomes ~/.seal/config/agents/<id>.md
   with seal frontmatter (id, name, provider, model, tools, timestamps, session).
   Tool permissions are mapped from the opencode.json permission config.
2. Skills: Each .opencode/skills/<id>/SKILL.md becomes ~/.seal/config/skills/<id>.md
   with seal frontmatter (id, description, timestamps, session).
   Referenced files (rubrics, guides, references) are embedded inline.
3. Commands: Commands without a matching skill are converted to skills.
4. A metaswarm-overview skill is created as an index.
"""

import json
import os
import re
import shutil
from pathlib import Path

METASWARM = Path(__file__).resolve().parent.parent / ".opencode"
SEAL_HOME = Path(os.environ.get("SEAL_HOME", str(Path.home() / ".seal")))
SEAL_CONFIG = SEAL_HOME / "config"
SEAL_AGENTS = SEAL_CONFIG / "agents"
SEAL_SKILLS = SEAL_CONFIG / "skills"

PROVIDER = "ollama"
MODEL = "glm-5.2:cloud"
TIMESTAMP = "2026-07-11T23:30:00Z"
SESSION = "manual"

# Tool permissions mapped from opencode.json
# "all" = AllowAll; list = AllowOnly specific opcodes
READ_ONLY = [
    "FILE_READ", "SEARCH_FILES", "MEMORY_RECALL",
    "SKILL_READ", "SKILL_LIST",
    "AGENT_DEF_READ", "AGENT_LIST", "AGENT_STATUS",
    "SHOW_HUMAN", "ASK_HUMAN",
]
READ_SHELL = READ_ONLY + ["SHELL_EXEC", "CODE_EXEC", "PROCESS_MANAGE"]
READ_EDIT = READ_ONLY + [
    "FILE_WRITE", "FILE_PATCH",
    "MEMORY_STORE", "MEMORY_UPDATE", "MEMORY_DELETE",
    "SKILL_CREATE", "SKILL_UPDATE",
    "AGENT_DEF_CREATE", "AGENT_DEF_UPDATE",
]
ALL_TOOLS = READ_SHELL + READ_EDIT + [
    "AGENT_START", "AGENT_STOP", "SECRET_GET",
]

# Agent-specific tool permissions (from opencode.json)
AGENT_TOOLS = {
    "issue-orchestrator": "all",
    "architect-agent": "all",
    "swarm-coordinator-agent": "all",
    "coder-agent": "all",
    "test-automator-agent": "all",
    "researcher-agent": READ_ONLY + ["SHELL_EXEC", "CODE_EXEC", "PROCESS_MANAGE", "SECRET_GET"],
    "code-review-agent": READ_ONLY,
    "cto-agent": READ_ONLY,
    "designer-agent": READ_ONLY,
    "product-manager-agent": READ_ONLY,
    "security-auditor-agent": READ_ONLY,
    "security-design-agent": READ_ONLY,
    "customer-service-agent": READ_ONLY,
    "sre-agent": READ_ONLY,
    "metrics-agent": READ_SHELL,
    "knowledge-curator-agent": READ_EDIT + ["SHELL_EXEC", "CODE_EXEC", "PROCESS_MANAGE"],
    "pr-shepherd-agent": READ_SHELL,
    "release-engineer-agent": READ_SHELL,
    "slack-coordinator-agent": READ_SHELL,
}

# Agent display names (extracted from the markdown headers)
AGENT_NAMES = {
    "issue-orchestrator": "Issue Orchestrator",
    "architect-agent": "Architect Agent",
    "swarm-coordinator-agent": "Swarm Coordinator Agent",
    "coder-agent": "Coder Agent",
    "test-automator-agent": "Test Automator Agent",
    "researcher-agent": "Researcher Agent",
    "code-review-agent": "Code Review Agent",
    "cto-agent": "CTO Agent",
    "designer-agent": "Designer Agent",
    "product-manager-agent": "Product Manager Agent",
    "security-auditor-agent": "Security Auditor Agent",
    "security-design-agent": "Security Design Agent",
    "customer-service-agent": "Customer Service Agent",
    "sre-agent": "SRE Agent",
    "metrics-agent": "Metrics Agent",
    "knowledge-curator-agent": "Knowledge Curator Agent",
    "pr-shepherd-agent": "PR Shepherd Agent",
    "release-engineer-agent": "Release Engineer Agent",
    "slack-coordinator-agent": "Slack Coordinator Agent",
}


def strip_yaml_frontmatter(text: str) -> tuple[str, dict]:
    """Strip YAML frontmatter from a markdown file, return (body, frontmatter_dict)."""
    if not text.startswith("---\n"):
        return text, {}
    end = text.find("\n---\n", 4)
    if end == -1:
        return text, {}
    fm_text = text[4:end]
    body = text[end + 5:]
    fm = {}
    for line in fm_text.split("\n"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" in line:
            k, v = line.split(":", 1)
            fm[k.strip()] = v.strip()
    return body, fm


def render_seal_frontmatter(fm: dict) -> str:
    """Render a seal frontmatter block from a dict."""
    lines = ["---"]
    for k, v in fm.items():
        lines.append(f"{k}: {v}")
    lines.append("---")
    return "\n".join(lines)


def tools_field_value(tools) -> str:
    """Render the tools frontmatter value: 'all' or a JSON array string."""
    if tools == "all":
        return "all"
    return json.dumps(tools)


def convert_agent(agent_id: str, agent_md: str) -> str:
    """Convert a metaswarm agent markdown into a seal flat-scheme agent .md file."""
    body, _ = strip_yaml_frontmatter(agent_md)

    # Prepend a role header if the body doesn't start with one
    if not body.startswith("# "):
        body = f"# {AGENT_NAMES.get(agent_id, agent_id)}\n\n" + body

    tools = AGENT_TOOLS.get(agent_id, "all")
    fm = {
        "id": agent_id,
        "name": AGENT_NAMES.get(agent_id, agent_id),
        "provider": PROVIDER,
        "model": MODEL,
        "tools": tools_field_value(tools),
        "created_at": TIMESTAMP,
        "updated_at": TIMESTAMP,
        "session": SESSION,
    }
    return render_seal_frontmatter(fm) + "\n\n" + body


def embed_referenced_files(body: str, skill_dir: Path) -> str:
    """Find referenced files in the skill body and embed their content."""
    pattern = r'`?\./((?:rubrics|guides|references|bin|scripts|templates|knowledge)/[^\s`)]+)`?'

    def replacer(m):
        rel_path = m.group(1)
        full_path = skill_dir / rel_path
        if full_path.exists() and full_path.is_file():
            content = full_path.read_text(encoding="utf-8")
            content_body, _ = strip_yaml_frontmatter(content)
            return f"\n\n---\n\n## [Embedded: {rel_path}]\n\n{content_body}\n"
        return m.group(0)

    return re.sub(pattern, replacer, body)


def convert_skill(skill_id: str, skill_md: str, skill_dir: Path) -> str:
    """Convert a metaswarm skill SKILL.md into a seal skill .md file."""
    body, fm = strip_yaml_frontmatter(skill_md)
    description = fm.get("description", "")

    # Embed referenced files from the skill directory
    body = embed_referenced_files(body, skill_dir)

    seal_fm = {
        "id": skill_id,
        "description": description,
        "created_at": TIMESTAMP,
        "updated_at": TIMESTAMP,
        "session": SESSION,
    }
    return render_seal_frontmatter(seal_fm) + "\n\n" + body


def convert_command_to_skill(cmd_id: str, cmd_md: str) -> str:
    """Convert a metaswarm command markdown into a seal skill .md file."""
    body, _ = strip_yaml_frontmatter(cmd_md)

    desc = f"Command: {cmd_id}"
    lines = body.strip().split("\n")
    if lines and lines[0].startswith("# "):
        desc = lines[0][2:].strip()

    seal_fm = {
        "id": cmd_id,
        "description": desc,
        "created_at": TIMESTAMP,
        "updated_at": TIMESTAMP,
        "session": SESSION,
    }
    return render_seal_frontmatter(seal_fm) + "\n\n" + body


def main():
    # Clean and create target directories
    for d in [SEAL_AGENTS, SEAL_SKILLS]:
        if d.exists():
            for f in d.iterdir():
                if f.is_file() and f.suffix == ".md":
                    f.unlink()
        else:
            d.mkdir(parents=True, exist_ok=True)

    # Convert agents
    agents_dir = METASWARM / "agents"
    agent_count = 0
    for agent_file in sorted(agents_dir.glob("*.md")):
        agent_id = agent_file.stem
        content = agent_file.read_text(encoding="utf-8")
        converted = convert_agent(agent_id, content)
        out_path = SEAL_AGENTS / f"{agent_id}.md"
        out_path.write_text(converted, encoding="utf-8")
        print(f"  agent: {agent_id}")
        agent_count += 1

    # Convert skills
    skills_dir = METASWARM / "skills"
    skill_count = 0
    for skill_subdir in sorted(skills_dir.iterdir()):
        if not skill_subdir.is_dir():
            continue
        skill_md_path = skill_subdir / "SKILL.md"
        if not skill_md_path.exists():
            continue
        skill_id = skill_subdir.name
        content = skill_md_path.read_text(encoding="utf-8")
        converted = convert_skill(skill_id, content, skill_subdir)
        out_path = SEAL_SKILLS / f"{skill_id}.md"
        out_path.write_text(converted, encoding="utf-8")
        print(f"  skill: {skill_id}")
        skill_count += 1

    # Convert commands that don't have skill equivalents into skills
    commands_dir = METASWARM / "commands"
    existing_skill_ids = {f.stem for f in SEAL_SKILLS.glob("*.md")}
    cmd_to_skill = {
        "start-task": "start",
        "design-review-gate": "design-review-gate",
        "orchestrated-execution": "orchestrated-execution",
        "setup": "setup",
        "status": "status",
        "handoff": "handoff",
        "handle-pr-comments": "handling-pr-comments",
    }
    cmd_count = 0
    for cmd_file in sorted(commands_dir.glob("*.md")):
        cmd_id = cmd_file.stem
        skill_id = cmd_to_skill.get(cmd_id)
        if skill_id and skill_id in existing_skill_ids:
            continue
        content = cmd_file.read_text(encoding="utf-8")
        final_skill_id = skill_id if skill_id else cmd_id
        converted = convert_command_to_skill(final_skill_id, content)
        out_path = SEAL_SKILLS / f"{final_skill_id}.md"
        out_path.write_text(converted, encoding="utf-8")
        print(f"  cmd->skill: {cmd_id} -> {final_skill_id}")
        cmd_count += 1

    # Create a metaswarm-overview skill
    overview_body = """# Metaswarm Multi-Agent Orchestration

This skill provides an overview of the metaswarm multi-agent orchestration framework adapted for Seal Harness.

## Available Agents

The following specialized agents are available and can be started with `AGENT_START`:

| Agent | Purpose |
|---|---|
| `issue-orchestrator` | Main coordinator per issue — spawns sub-agents, runs 4-phase execution loop |
| `swarm-coordinator-agent` | Meta-orchestrator managing multiple issues/epics in parallel |
| `architect-agent` | Reviews technical architecture and creates implementation plans |
| `coder-agent` | TDD implementation of features and fixes |
| `test-automator-agent` | Test writing and coverage analysis |
| `researcher-agent` | Codebase exploration and prior art research |
| `code-review-agent` | Internal code review before PR creation |
| `cto-agent` | Plan review and architectural guidance |
| `designer-agent` | UX, API design, and developer experience review |
| `product-manager-agent` | Use case validation and user benefit review |
| `security-auditor-agent` | Security vulnerability detection and OWASP compliance |
| `security-design-agent` | Security review of designs before implementation |
| `customer-service-agent` | User issue investigation and support (read-only) |
| `sre-agent` | Production system monitoring and incident response (read-only) |
| `metrics-agent` | Collect, aggregate, and report on agent swarm performance |
| `knowledge-curator-agent` | Knowledge extraction and curation |
| `pr-shepherd-agent` | PR lifecycle management through to merge |
| `release-engineer-agent` | Safe delivery of approved code from merge through production verification |
| `slack-coordinator-agent` | Human-agent communication bridge via Slack |

## Available Skills

Skills are loaded on demand via `SKILL_READ`. Key skills:

| Skill | Purpose |
|---|---|
| `start` | Begin tracked work on a task with complexity assessment |
| `orchestrated-execution` | 4-phase execution loop: IMPLEMENT -> VALIDATE -> ADVERSARIAL REVIEW -> COMMIT |
| `design-review-gate` | Automatic review gate after brainstorming (5 reviewers) |
| `plan-review-gate` | Adversarial review gate with 3 independent reviewers |
| `create-issue` | Create comprehensive GitHub issues with TDD plans |
| `handling-pr-comments` | Address PR review feedback systematically |
| `pr-shepherd` | Monitor a PR through to merge |
| `handoff` | Write a self-contained handoff document |
| `self-reflect` | Extract learnings from recent PR reviews |
| `external-tools` | Delegate to external AI CLI tools (Codex, Gemini) |
| `brainstorming-extension` | Design review gate bridge for brainstorming |
| `setup` | Interactive project setup |
| `status` | Diagnostic status report |
| `migrate` | Migration tool |
| `visual-review` | Visual review with Playwright screenshots |

## Workflow Patterns

### Starting Work

1. Read the `start` skill for task complexity assessment
2. Read the `orchestrated-execution` skill for the 4-phase execution loop
3. Use `AGENT_START` to spawn sub-agents for parallel work

### Design Review

1. Read the `design-review-gate` skill
2. Spawn PM, Architect, Designer, Security, and CTO agents in parallel
3. Iterate until all approve

### Plan Review

1. Read the `plan-review-gate` skill
2. Spawn 3 adversarial reviewers (Feasibility, Completeness, Scope & Alignment)
3. All must PASS before proceeding

### Execution Loop

1. IMPLEMENT: Coder agent writes code following TDD
2. VALIDATE: Run tests, lint, typecheck independently
3. ADVERSARIAL REVIEW: Fresh reviewer checks each DoD item with file:line evidence
4. COMMIT: Only after all gates pass

## Key Principles

- **Trust nothing, verify everything**: Run quality gates independently
- **Adversarial review**: Fresh reviewer checks each DoD item
- **Human checkpoints**: Pause at planned review points
- **Recovery**: Max 3 retries per work unit, then escalate
- **No shortcuts**: Never use --no-verify on commits, never skip coverage gates
"""
    overview_fm = {
        "id": "metaswarm-overview",
        "description": "Overview of the metaswarm multi-agent orchestration framework — lists all agents, skills, and workflow patterns",
        "created_at": TIMESTAMP,
        "updated_at": TIMESTAMP,
        "session": SESSION,
    }
    overview_content = render_seal_frontmatter(overview_fm) + "\n\n" + overview_body
    (SEAL_SKILLS / "metaswarm-overview.md").write_text(overview_content, encoding="utf-8")
    print(f"  skill: metaswarm-overview (created)")
    skill_count += 1

    print(f"\nDone: {agent_count} agents, {skill_count} skills (+{cmd_count} from commands)")
    print(f"  Agents -> {SEAL_AGENTS}")
    print(f"  Skills -> {SEAL_SKILLS}")


if __name__ == "__main__":
    main()