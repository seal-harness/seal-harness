---
id: seal-usage
description: How to work inside a Seal Harness session — your cwd is a fresh isolated workspace; prefer it as your default; clone into `.`; operating outside the workdir is fine when the task calls for it but shouldn't be your default mode. Load this at the start of any session before touching files.
created_at: 2026-07-24T00:00:00Z
updated_at: 2026-09-23T00:00:00Z
session: manual
---


# Seal Harness Usage Skill

You are running inside a **Seal Harness session**. Every session gets its own
**fresh, isolated working directory**. This skill teaches you the contract
that keeps your work visible, safe, and confined to that workspace.

Load this skill at the start of a session, before you run any file or shell
opcode. If you have already been working, load it the moment you realize you
haven't.

---

## The one rule

**Prefer your current working directory as your workspace. Stay in it by default.**

Operating outside your workdir is allowed when the task genuinely requires it
(reading a system config, inspecting another project, writing to a shared
location). It just shouldn't be your default mode of operation — most work
belongs in your workdir where it's isolated, visible, and auditable.

- `SHELL_EXEC` and `BIN_EXEC` already default their cwd to your workdir when
  you omit the `cwd` argument. You do not need to `cd` anywhere. Both accept
  an optional `cwd`: a relative path is confined to your workdir; an
  absolute path is used verbatim.
- `FILE_READ`, `FILE_WRITE`, and `FILE_PATCH` accept both relative paths
  (resolved against your workdir) and absolute paths (used verbatim). This
  lets you read or write files that persist across sessions. `SEARCH_FILES`
  is confined to your workdir; relative paths resolve there.
- `pwd` (with no `cwd` arg) returns your workdir. Run it once to see where
  you are.

## What this means in practice

### Cloning a repo

**Correct** — the clone lands inside your workdir. `git` is a single
binary, so `BIN_EXEC` is the right opcode (no shell needed):

```
BIN_EXEC { "binary": "git", "args": ["clone", "https://github.com/seal-harness/seal-harness.git"] }
```

Then list the workdir to see it, and run `git` subcommands in the clone
via `BIN_EXEC` with the clone as an argument:

```
BIN_EXEC { "binary": "ls" }
BIN_EXEC { "binary": "git", "args": ["-C", "seal-harness", "log", "--oneline", "-5"] }
```

The clone is a subdirectory of your workspace — that's where it belongs.

**Wrong (by default)** — this escapes your workspace and the clone is
invisible to every file opcode:

```
SHELL_EXEC { "command": "cd ~ && git clone https://github.com/seal-harness/seal-harness.git" }
```

`cd ~` lands you in the operator's home directory. The clone goes to
`~/seal-harness`, outside your workdir. `FILE_READ "seal-harness/README.md"`
will then fail — your file opcodes look in your workdir, not in `~`.

There are times when this is the right call — e.g. you were asked to clone
into a specific shared location. When you do operate outside the workdir,
just be deliberate about it: know where you're writing, and tell the operator
what you're doing and why.

**Also avoid by default** — absolute paths have the same problem when used
carelessly:

```
SHELL_EXEC { "command": "cd /tmp && git clone …" }
SHELL_EXEC { "command": "git clone … /Users/alice/some-place" }
```

### Running commands

Prefer `BIN_EXEC` unless `SHELL_EXEC` is absolutely necessary. `BIN_EXEC`
runs a named binary with argv tokens and no shell interpreter — narrower,
safer, and immune to shell-injection. Use it for anything that's a single
binary plus arguments: `git`, `ls`, `pwd`, `cabal`, `make`, `rg`, etc.

```
BIN_EXEC { "binary": "pwd" }
BIN_EXEC { "binary": "ls", "args": ["seal-harness"] }
BIN_EXEC { "binary": "cabal", "args": ["build", "all"] }
```

Use `SHELL_EXEC` only when you genuinely need shell features: pipes,
redirects, `&&` chaining, globbing, or environment expansion. `SHELL_EXEC`
takes an optional `cwd` (workspace-relative, SafePath-confined) — use it to
run a command inside a subdirectory of your workspace instead of chaining
`cd ... && ...`:

```
# After cloning seal-harness into your workdir — build inside the clone:
SHELL_EXEC { "command": "cabal build all", "cwd": "seal-harness" }
```

That's fine: `seal-harness` is relative, inside your workdir. The cwd
resets to your workdir on the next call, so a `cwd` does not leak across
calls. Prefer relative, workdir-contained `cwd` values; use an absolute or
home path only when the task explicitly needs it.

### CLI tool pitfalls

**`gh` does not support `-C`.** The `git -C <path>` pattern for running a
command inside a specific directory is git-specific — `gh` (GitHub CLI) has
no equivalent flag. Passing `-C` to `gh` fails immediately with "unknown
shorthand flag: C". To run `gh` against a repo inside your workdir, use the
`cwd` parameter on `BIN_EXEC` instead:

```
# Wrong — gh has no -C flag:
BIN_EXEC { "binary": "gh", "args": ["-C", "seal-harness", "pr", "create", ...] }

# Right — use cwd to scope the command:
BIN_EXEC { "binary": "gh", "args": ["pr", "create", ...], "cwd": "seal-harness" }
```

As a general rule, `-C` is a git-specific flag, not a universal CLI
convention. When in doubt, use the `cwd` parameter rather than a `-C` flag.

### GitHub CLI (`gh`) and credential injection

**Always use `BIN_EXEC` with `binary="gh"` for GitHub operations that
require authentication** (push, PR creation, issue editing, repo cloning
of private repos, etc.). Seal Harness automatically injects `GH_TOKEN`
from the vault into the process environment when `gh` is run via
`BIN_EXEC` from inside a registered repo's workdir. This is the **only**
way `gh` receives credentials in a Seal session — there is no
`gh auth login` keyring on the untrusted machine.

**`SHELL_EXEC` with `gh` gets NO credential injection.** Running
`gh pr create` through `SHELL_EXEC` will fail with an opaque
authentication error because `GH_TOKEN` is never injected into a
`SHELL_EXEC` subprocess. This is the single most common cause of
push/PR failures in Seal sessions.

```
# Wrong — SHELL_EXEC gets no GH_TOKEN → auth failure:
SHELL_EXEC { "command": "gh pr create --draft --fill" }
# Right — BIN_EXEC injects GH_TOKEN from the vault:
BIN_EXEC { "binary": "gh", "args": ["pr", "create", "--head", "my-branch", "--draft", "--fill"], "cwd": "my-repo" }
```

The same applies to `git` push/pull against PAT-registered repos:
`BIN_EXEC` with `binary="git"` gets credential injection (SSH agent for
deploy keys, `http.extraHeader` for PATs); `SHELL_EXEC` does not.

If `gh` fails with an auth error despite using `BIN_EXEC`, the repo may
not be registered in Seal Harness's repo registry, or the vault may be
locked. Check with the operator — do not attempt `gh auth login`
(it is blocked by the harness because it writes secrets to disk).

**`gh pr create` needs `--head` in shallow clones.** In a shallow clone
(which is what `SETUP_REPO` and most agent environments produce), `git
push -u` may not reliably persist upstream tracking config to `.git/config`.
The `gh pr create` command relies on that tracking config to detect the
remote branch, and fails with "you must first push the current branch"
even when the branch exists on the remote. Always pass `--head
<branch-name>` to bypass tracking detection entirely:

```
BIN_EXEC { "binary": "gh", "args": ["pr", "create", "--head", "my-feature-branch", "--draft", "--fill"], "cwd": "seal-harness" }
```

This is the safe default for PR creation from any cloned repo in a Seal
session, not just shallow clones — there is no downside to passing
`--head` explicitly.

### Checking out a different branch in a shallow clone

`SETUP_REPO` does a **shallow clone** (`--depth 1`) of the default branch
only. Other branches exist on the remote but have no local
remote-tracking refs, so a plain `git checkout <branch>` fails with
`pathspec '<branch>' did not match any file(s) known to git`. Two
commands are needed — first fetch the branch's ref at depth 1 with an
explicit refspec, then check it out:

```
BIN_EXEC { "binary": "git", "args": ["fetch", "origin", "my-feature-branch:refs/remotes/origin/my-feature-branch", "--depth", "1"], "cwd": "seal-harness" }
BIN_EXEC { "binary": "git", "args": ["checkout", "my-feature-branch"], "cwd": "seal-harness" }
```

Both steps are required. A bare `git fetch origin <branch>` only populates
`FETCH_HEAD`, not the `refs/remotes/origin/<branch>` ref that `checkout`
resolves the branch against — the explicit refspec is what creates it.

### Why this matters

- **Isolation.** Your workdir is per-session. Parallel sessions get
  different workdirs and cannot clobber each other. If you `cd ~` and write
  there by default, you break that isolation and your writes land somewhere
  the operator didn't expect. (Operating outside the workdir deliberately is
  fine — doing it by default is what causes problems.)
- **Visibility.** `SEARCH_FILES` looks in your workdir. `FILE_READ`,
  `FILE_WRITE`, and `FILE_PATCH` default to your workdir for relative paths
  but also accept absolute paths. If you need to work outside the workdir,
  use absolute paths explicitly so it's clear where things are going — and
  tell the operator what you're doing and why.
- **Audit.** The transcript records what you did. Escaping the workdir
  *accidentally* produces a confusing audit trail (writes the operator can't
  find in the session's workdir). Deliberate outside-workdir actions are fine
  — just be clear about them.

## Quick checklist before every file/shell opcode

- [ ] Am I using a relative path (or no path — cwd defaults to the workdir)?
- [ ] Is this work something that belongs in the workdir? (Most does.)
- [ ] If I'm operating outside the workdir, is that a deliberate choice — do I
      know why, and does the operator know?
- [ ] Did I avoid *accidental* `cd ~`, `cd $HOME`, `cd /abs/...`?
- [ ] Did I avoid *unintended* chaining `cd <absolute> && …`?
- [ ] Can this be a `BIN_EXEC` instead of `SHELL_EXEC`? (single binary + args → yes)
- [ ] If I need to clone, am I cloning with **no destination path** (so it
      lands in my workdir as a subdirectory)?
- [ ] If I'm using `gh` or `git` for authenticated operations, am I using
      `BIN_EXEC`? (SHELL_EXEC gets no credential injection → auth failures)

If you accidentally escaped the workdir, don't try to "fix" it by copying
files around blindly. Tell the operator what happened, then re-run the work
inside your workdir. (If you *deliberately* escaped it for a good reason, you
don't need to fix anything — just make sure the operator knows.)

## Discovering your workdir

You don't need to know the path ahead of time. Just run:

```
BIN_EXEC { "binary": "pwd" }
```

The returned path is your workdir for this session. Use it for reference
when you need to construct an absolute path, or pass relative paths to file
opcodes to resolve against the workdir.

## What is NOT in your workdir (by default)

- The operator's home, dotfiles, other projects. These are outside your
  session by default. You *can* read or write them when a task requires it —
  just be deliberate and explicit about it.
- Other sessions' workdirs. Each session is isolated by design; leave them
  alone unless the operator directs you there.
- System paths (`/usr`, `/etc`, `/tmp`). Off-limits by default; touch them
  only with a clear reason.

## Operator-facing note

Operators: this skill is **shipped embedded in the Seal binary** and
auto-injected at session start by default — no install step needed. It is
always present in the skill list (`SKILL_LIST` / `/skill list`). To override
it, drop a same-id file at `~/.seal/config/skills/seal-usage.md`; the union
backend prefers your copy. Disable auto-injection for all sessions by
setting `[skills] autoload = ""` in `config.toml`.
