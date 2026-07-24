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

The agent loads it on demand:

```
SKILL_LOAD { "id": "seal-usage" }
```

Or the operator can fold the contract into an agent's `adSystem` prompt so
it's present from turn 1 (no auto-load mechanism exists yet — see the
follow-up epic in the brainstorm doc).

## What's NOT here

- **Auto-load at session start** — not yet implemented; this is the
  follow-up epic's first work unit.
- **`working-directory` arg on `BIN_EXEC`/`SHELL_EXEC`** — follow-up.
- **`CLONE_REPO` opcode + `/clone` slash command** — follow-up.
- **chroot per session (hard boundary)** — follow-up, hardest item.