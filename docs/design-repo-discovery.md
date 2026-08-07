# Design: `.agents` + `.skills` Discovery from Cloned Repos

## Goal

When a session clones a repo via `SETUP_REPO`, Seal should automatically
discover and load:

1. **Agent definitions** from the repo's `.agents/` directory
2. **Skills** from the repo's `.skills/` directory, following the
   [agentskills.io](https://agentskills.io) specification

## Current State

### Skills

`workdirSkillBackend` already scans cloned repos for skills, but:
- It looks in `.seal/skills`, `.claude/skills`, `agents/skills` — **not** `.skills`
- It expects Seal's own flat format (`<id>.md` files with `id:`/`description:`
  frontmatter), **not** the agentskills.io directory-based format
  (`<name>/SKILL.md` with `name:`/`description:` YAML frontmatter)

### Agent Defs

There is **no** workdir-scanning backend for agent defs. The
`markdownAgentDefBackend` reads only from `~/.seal/config/agents/`. There is
no equivalent of `workdirSkillBackend` for agent defs.

## Design

### 1. Skills: Support `.skills/` with agentskills.io format

**agentskills.io format:**
```
.skills/
├── my-skill/
│   └── SKILL.md      # YAML frontmatter: name, description + body
├── another-skill/
│   └── SKILL.md
```

**Seal's current format (flat `.md` files):**
```
.seal/skills/
├── my-skill.md       # frontmatter: id, description + body
├── another-skill.md
```

**Changes to `Seal.Skills.Backend`:**

- Add `.skills` to `workdirSkillConventions`
- Add a new `listAgentSkillsDir` function that scans a directory for
  subdirectories containing `SKILL.md` files (agentskills.io format)
- Parse `SKILL.md` using YAML frontmatter: `name` → `skId`, `description`
  → `skDescription`, body → `skBody`. The `name` field must pass
  `isValidSkillId` (agentskills.io allows only lowercase + hyphens, which
  is a subset of Seal's `[A-Za-z0-9_-]+`).
- Merge agentskills.io skills with the existing flat/grouped skills from
  the same convention directory (agentskills.io dirs don't conflict with
  flat `.md` files — they're subdirectories, not `.md` files)

### 2. Agent Defs: New `workdirAgentDefBackend`

**Format:** `.agents/` directory in a cloned repo, using the same DirScheme
format Seal already supports: subdirectories with bootstrap files
(`SOUL.md`, `AGENTS.md`, etc.) and/or flat `.md` files.

This reuses the existing `Seal.Agent.Def.Backend` DirScheme machinery
(`loadDirAgentDef`, `composeDirSystemPrompt`, `listAgentDefs`) — just
pointed at the workdir instead of `~/.seal/config/agents/`.

**New `workdirAgentDefBackend`:**
- A read-only `AgentDefBackend` (like `workdirSkillBackend` is read-only)
- Scans each top-level directory in the workdir (cloned repos) for `.agents/`
- Uses `listAgentDefs` (the existing hybrid flat + dir discovery) on each
  `.agents/` directory
- Alphabetically-first repo wins on id collisions (same as skills)
- Writes are no-ops (repo-local agent defs are immutable from the model's
  perspective)

### 3. Union layer for agent defs

Add a `unionAgentDefBackend` (analogous to `tripleUnionSkillBackend`):

- Workdir agent defs shadow user agent defs (workdir-wins, same as skills)
- `adbRead`: check workdir first, then user backend
- `adbList`: merge workdir + user (workdir wins on collision)
- Writes go to the user backend only

### 4. Wiring

**Channel loop (`Channels/Loop.hs`):**
- Build `workdirAgentDefs` alongside `workdirSkills` from the session workdir
- Construct `sessionAgentDefs = unionAgentDefBackend workdirAgentDefs (bAgentDefs backends)`
- Use `sessionAgentDefs` for `agentDefReadOp`, `agentDefListOp`, etc. in the
  ISA registry
- Use `sessionAgentDefs` for `resolveDefaultAgent` and system prompt resolution

**Same pattern in:**
- `Gateway/Send.hs` (web path)
- `Channel/Cli.hs` (CLI path)
- The child agent registry builder (for AGENT_START)

## Implementation Plan

1. `Seal.Skills.Backend`: Add `.skills` convention + agentskills.io `SKILL.md` parsing
2. `Seal.Agent.Def.Backend`: Add `workdirAgentDefBackend` + `unionAgentDefBackend`
3. Wire into `Channels/Loop.hs`, `Gateway/Send.hs`, `Channel/Cli.hs`
4. Tests