# Workdir-Escape Brainstorm & Direction

> **Status:** Direction selected 2026-07-24. Skill (layer A) is the first
> deliverable; opcode + boundary layers are follow-ups under a future epic.
> GitHub: (issue TBD on creation). Branch: `feat/seal-usage-skill`.

## 1. Incident

Session `20260724-034638-653` (web, agent `zoe`, provider `ollama`/`glm-5.2:cloud`).
User said **"Clone seal-harness"**. The model emitted:

```
SHELL_EXEC { "command": "cd ~ && git clone https://github.com/seal-harness/seal-harness.git" }
SHELL_EXEC { "command": "ls -la ~/seal-harness/ | head -20" }
```

Two problems:
1. `cd ~` escapes the per-session workdir (`~/.seal/cache/workdirs/<sid>`)
   and lands the clone in `~/seal-harness` — outside the session workspace,
   untracked, invisible to `FILE_*`/`SEARCH_FILES` (which use the workdir as
   `WorkspaceRoot`).
2. The workdir for that session is **empty** — the model never wrote there.
   It jumped straight to `~`.

The fresh-workdir design (`docs/2026-07-23-per-session-workdir-design.md`)
already isolates sessions; the **gap** is that the model has no idea the
workdir exists or that it should stay in it. The system prompt
(`SOUL.md`/`USER.md`) and the tool descriptions say nothing about it.
PR #51 established the one-root invariant (SHELL_EXEC defaults cwd to the
workdir when the caller omits it) — but the model **explicitly** wrote `cd ~`,
overriding that default. The fix must make the model *cooperate* (and
eventually *enforce* cooperation).

## 2. Brainstorm (full list, by layer)

### A. Prompt / instruction layer

1. Inject workdir awareness into the system prompt at session start.
2. Enrich `SHELL_EXEC`/`BIN_EXEC` tool descriptions (stay in your workdir; no
   `cd ~` / absolute paths).
3. A workspace-orientation seam (AGENTS.md-style file auto-loaded into the
   prompt).
4. First-turn orientation injection (system note on turn 1).
5. Teach the "clone into `.`" idiom in descriptions/examples.

### B. Tool-call / opcode behavior

6. Reject `cd` to paths outside the workdir (parse the shell command).
7. Strip/rewrite `cd <abs> &&` prefixes (normalize to workdir).
8. Expose `$WORKDIR`/`$PWD` env var in the subprocess + mention in the
   description.
9. Make `~`/`$HOME` *be* the workdir for untrusted subprocesses (set
   `HOME=<workdir>`).
10. Refuse `git clone` that targets an absolute path (special case of 6).

### C. Design-decision layer

11. Implement the deferred `workdir_base` config — point the workdir at the
    repo checkout for single-session CLI users.
12. Default to symlinking the workdir to the checkout.
13. A first-class `CLONE_REPO`/`GIT_CLONE` opcode that clones into the
    workdir and returns the path.
14. A `/clone` operator slash command (sugar over `CLONE_REPO`).
15. Persistent, repo-keyed workdir (same repo URL → same workdir across
    sessions).
16. Auto-seed the workdir from a configured `default_repo` at session start.

### D. Code-level hard boundary (the deferred container/VM track)

17. chroot per session (the design-doc §9-deferred follow-up; needs a real
    rootfs + priv-drop story).
18. Landlock/seccomp on SHELL_EXEC (Linux-only).
19. `bubblewrap` (`bwrap`) — single binary, no privileges, cross-distro, the
    pragmatic middle ground.
20. Set `HOME=<workdir>` + bind-mount workdir as `~` (cheap subset of 17/19).

### E. Hybrid / model-aware

21. Tool-result post-processing: inject a correction if SHELL_EXEC
    writes/cds outside the workdir.
22. Route "Clone X" intent to `CLONE_REPO` (intent detection in the loop).

### F. Evaluation / measurement

23. A workdir-confinement eval/benchmark (sessions must stay in the workdir;
    measure escape rate).
24. A CI gate grepping transcripts for `cd ~`, `cd /`, `git clone .* /` and
    failing the build.
25. A "fresh-workspace contract" property test (no opcode output path escapes
    `workdirsRoot/<sid>`).

## 3. Direction (user-selected)

The user picked a four-part direction. Layers **A** (skill) and **D**
(boundary) ship in that order; layers **B** (opcode ergonomics) and **C**
(`CLONE_REPO`/`/clone`) land as a follow-up under a future epic once we have
data from the skill.

### 3.1 Auto-loaded "Seal Harness usage" skill  *(Layer A — first deliverable)*

- A Seal skill (`SKILL_WRITE` markdown under `~/.seal/config/skills/`) named
  e.g. `seal-usage` describing the fresh-workdir contract: "Your cwd is a
  fresh isolated workspace; stay in it; clone into `.`; do not `cd ~` or to
  absolute paths."
- **Auto-load:** the user wants this present in every session by default,
  injected right after the agent's system prompt. Seal has no auto-load seam
  today (skills are `SKILL_LOAD`-on-demand). **Open question for the
  follow-up epic:** do we add an `autoload_skills` config (a list of skill ids
  the harness injects into the system prompt at session start), or do we
  fold the workdir contract into the resolved system prompt directly (a
  code change to `resolveSystemPrompt`)? For the **first deliverable** we
  ship the skill file alone — the model can `SKILL_LOAD seal-usage` on demand
  and operators can wire it into their agent's `adSystem` today. The
  auto-load mechanism is its own work unit (see §4 open questions).
- This is the *teaching* layer: the model cooperates because it knows the
  contract. Cheap, immediate, reversible. Ships first so we can measure
  whether instruction alone closes the gap before paying for enforcement.

### 3.2 `working-directory` arg on `BIN_EXEC` (and consider `SHELL_EXEC`)  *(Layer B — follow-up)*

- The user wants to avoid multi-command `cd X && cmd` chaining. A
  `working-directory` arg lets the model pass the dir explicitly instead of
  chaining `cd`. Mirrors how `BIN_EXEC` already takes optional `cwd`.
- Fewer opcodes, safer than munging shell commands (no parsing of arbitrary
  shell to detect `cd`). This is the Haskell "make IO actions safe by giving
  them narrower types" approach the user named.
- **Not** in the first deliverable — lands under the follow-up epic.

### 3.3 `CLONE_REPO` opcode + `/clone` slash command  *(Layer C — follow-up)*

- A first-class `CLONE_REPO` opcode: clones a repo URL into the workdir,
  returns the path. Universal enough to justify the opcode slot (the user
  weighed opcode explosion and decided clone is universal).
- `/clone <url>` operator slash command = sugar over `CLONE_REPO`. Covers
  the user case (operator types `/clone`) and the agent case (agent calls
  `CLONE_REPO`) with one mechanism.
- **Not** in the first deliverable — lands under the follow-up epic.

### 3.4 chroot per session  *(Layer D — follow-up, hardest)*

- The hard boundary; closes the `cd /` class of escapes the design doc flags
  at §7. The user explicitly picked D17 (real chroot) over D19 (`bwrap`)
  and over D20 (bind-mount `~`).
- **Carries the design-doc §9 unresolved baggage:** the security reviewer
  found chroot non-functional as previously designed (no rootfs, no
  priv-drop, perm issues). Picking D17 means we must actually solve those —
  a real rootfs, a helper binary with `CAP_SYS_CHROOT` (or a setuid wrapper),
  perm/priv-drop story. This is a meaningful design sub-problem on its own
  and almost certainly its own epic.
- **Open question flagged to the user:** bwrap (D19) gives the same effective
  boundary at far less design risk (single binary, no privileges, cross-distro).
  The user reaffirmed chroot. The chroot design will need to address why the
  security reviewer's v2→v3 concerns are now solvable. This is the riskiest
  item in the direction and the one most likely to revisit bwrap as the
  pragmatic answer.
- **Not** in the first deliverable — lands under the follow-up epic.

## 4. Open questions (for the follow-up epic)

1. **Auto-load mechanism.** Today Seal has no `autoload_skills` config and
   `resolveSystemPrompt` doesn't touch skills. Options: (a) a config list of
   skill ids the harness injects into the resolved system prompt at session
   start; (b) fold the workdir contract directly into `resolveSystemPrompt`
   as a code change (no skill indirection); (c) a per-agent
   `adAutoloadSkills` field. The first deliverable (the skill file) is useful
   regardless of which mechanism wins — operators can wire it manually
   today.
2. **bwrap vs. real chroot.** The user picked chroot; the design doc says
   chroot was non-functional as previously designed. The follow-up epic's
   design must either solve the v2→v3 concerns or revisit bwrap. Do not
   assume this is settled.
3. **Does the skill go in `~/.seal/config/skills/` (user-global) or in the
   repo's `config/skills/` (project-local, versioned)?** The first
   deliverable puts it in the repo so it ships with Seal Harness and is
   versioned; operators can symlink or copy to `~/.seal/config/skills/` to
   make it agent-loadable today. The auto-load mechanism (Q1) decides the
   final home.
4. **Workdir path in the skill body.** The skill can't know the per-session
   workdir path at authoring time (it's `~/.seal/cache/workdirs/<sid>`). The
   body should say "your cwd is already your workdir; stay in it; use `pwd`
   to see it" — not hardcode a path. The model discovers the path at
   runtime via `pwd` (which PR #51 now anchors to the workdir).

## 5. First deliverable scope (this branch)

- [x] Brainstorm + direction (this doc).
- [x] `seal-usage` skill file (markdown, YAML frontmatter, body describing
      the fresh-workdir contract + clone-into-`.` idiom + what NOT to do).
- [x] README/docs note pointing operators at the skill and how to load it
      (`SKILL_LOAD seal-usage` or wire into `adSystem`).
- [x] **Auto-injection at session start** (was the follow-up epic's first
      work unit; promoted into the first deliverable). New `[skills]`
      config section with `autoload` key (default `"seal-usage"`, empty
      string disables). New `Seal.Skills.Autoload` module
      (`injectAutoloadSkill`) appends the skill body to the resolved
      system prompt at all 3 main session wiring sites (CLI
      `resolveSystem`, Channels `plainTurn`, Gateway
      `resolveSystemPrompt`) and all 3 child system-prompt builders (CLI,
      Channels, Gateway — `dwdChildSystemPrompt` changed to `IO`). Tests
      for config round-trip + resolution + injection.
- [x] Commit on `feat/seal-usage-skill` (then cherry-picked onto
      `fix/search-files-pattern-word-split`).

**Out of scope for this branch:** `working-directory` arg, `CLONE_REPO`,
chroot — all follow-up epic.

## 6. Changelog

- 2026-07-24 v1: brainstorm (A–F, 25 ideas) → user direction (skill first;
  chroot as the boundary; `working-directory` arg + `CLONE_REPO` as
  follow-ups). First deliverable scoped to the skill file alone.