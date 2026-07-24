# Seal Usage Skill

A Seal skill that teaches the agent the **fresh-workdir contract**: its cwd
is a per-session isolated workspace, it should stay in it, clone repos into
`.`, and never `cd ~` or to absolute paths.

## Why

Session `20260724-034638-653` produced `SHELL_EXEC "cd ~ && git clone …"`,
escaping the per-session workdir (`~/.seal/cache/workdirs/<sid>`) and landing
the clone in `~/seal-harness` — invisible to every file opcode. The
one-root invariant from PR #51 makes `SHELL_EXEC` default its cwd to the
workdir, but the model **explicitly** overrode it with `cd ~`. The gap is
that the model has no idea the workdir exists. This skill closes that gap by
teaching the contract.

Full brainstorm and direction: `docs/2026-07-24-workdir-escape-brainstorm.md`.

## Where it lives

`config/skills/seal-usage.md` — versioned with the repo so it ships with Seal
Harness. Seal's skill backend reads from `~/.seal/config/skills/`, so to make
it agent-loadable today, symlink or copy it:

```bash
mkdir -p ~/.seal/config/skills
ln -s "$(pwd)/config/skills/seal-usage.md" ~/.seal/config/skills/seal-usage.md
```

## How to use it

The skill is **auto-injected by default**. At session start, the harness
loads the configured skill id (default `seal-usage`) from
`~/.seal/config/skills/` and appends it to the resolved system prompt, so
the model is oriented to its per-session workspace from turn one — no
`SKILL_LOAD` needed. This applies to all channels (CLI, web, Signal,
Telegram) and to sub-agent child sessions.

### Disabling or overriding

In `config.toml`:

```toml
# Disable auto-injection entirely (empty string)
[skills]
autoload = ""

# Override with a different skill id
[skills]
autoload = "my-custom-orientation"
```

Absent `[skills]` section or `autoload` key → the built-in default
`seal-usage` is injected.

### Manual loading (still supported)

The agent can still `SKILL_LOAD seal-usage` on demand; auto-injection is
additive (it appends to whatever the bound agent's `adSystem` already
says).

## What's NOT here

- **`working-directory` arg on `BIN_EXEC`/`SHELL_EXEC`** — follow-up.
- **`CLONE_REPO` opcode + `/clone` slash command** — follow-up.
- **chroot per session (hard boundary)** — follow-up, hardest item.