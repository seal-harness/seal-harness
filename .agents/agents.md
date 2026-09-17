---
kind: agents
---

# Seal Harness — Agent Guide

> Security-first Haskell runtime for AI agents, built on the **SealOp ISA**:
> every agent action is a typed opcode with a schema, trust classification,
> and authorization gate. The transcript (append-only, hash-chained) is the
> audit log; all derived state is rebuilt from transcript replay. Mission:
> guarantees where guarantees are needed — the insecure path is harder to
> write than the secure path.

## The Rules (Non-Negotiable)

1. **Clean-room.** Never copy or reference another proprietary codebase — in
   code, identifiers, comments, commits, PRs, or docs. Port the idea, write
   it fresh, in this repo's own style and `Seal.*` namespace.
2. **Human authorship.** Issues, design docs, and human-facing prose are
   written by humans. AI writes code; humans write the rules the code must
   follow.
3. **Security-first.** Never commit or log secrets, keys, tokens, or vault
   contents. Secret and proof types stay opaque with unexported constructors
   (`SafePath`, `AuthorizedCommand`). Found a vulnerability? Disclose
   privately — never a public issue.
4. **TDD.** Failing test first, then minimal implementation, then commit.
   Security-critical pure functions get QuickCheck properties.
5. **No git force pushes. Ever.**
6. **New feature ⇒ new branch** off `main` (e.g. `git checkout -b <name>`).

## Development

Everything runs through the **Nix flake dev shell** — never install GHC,
cabal, or hlint yourself. Use the Makefile wrappers (all run inside
`nix develop`; `direnv` users: `echo "use flake" > .envrc && direnv allow`):

```bash
make build    # cabal build all (-Werror clean)
make test     # cabal test
make lint     # hlint src/ test/ — must report: No hints
make check    # build + test + lint — the full local gate; what CI runs
make serve    # rebuild frontend + launch gateway
make tui      # interactive TUI
```

**SIGPIPE pitfall:** never pipe Haskell binaries (`cabal`, `hlint`, `ghcid`)
through `head`/`tail`. The RTS sets `SIGPIPE` to `SIG_IGN`, so the writer
hangs in its exception handler instead of dying and the command appears to
hang forever. Redirect to a file, then page through the file:

```bash
nix develop --command cabal test >test.log 2>&1; head -80 test.log
```

(`make`, `rg`, `git` are unaffected — they use the default SIGPIPE handler.)

**Frontend:** React 18 + TS + Vite + Tailwind, embedded into the binary via
`file-embed`, so `frontend/dist` must exist when `cabal build` runs (the
Makefile gates this).

## Architecture

`ReaderT AppEnv IO` + Handle pattern throughout. Explicit decisions: no
effect systems, no `StateT`/`ExceptT` in the stack; static typeclass
dispatch with existentials only at the CLI wiring boundary.

- **Capability-based security.** Each function declares the capabilities it
  needs. `UntrustedIO` (the unified handle for all untrusted side effects)
  is only in scope for `UntrustedOpcode`, so a Trusted opcode that shells
  out **fails to compile**. Opcode modules never import `System.Process`,
  `System.Directory`, or `System.Posix` — they call capability methods.
- **Transcript as source of truth.** All derived stores (memory, skills,
  agent defs) are materialized views rebuilt from transcript replay. The
  transcript is `conversation.jsonl` + `entries.jsonl`.
- **Two-plane split.** In `mode=remote`, untrusted execution (shell, files,
  web, browser) runs on a separate machine over SSH with mandatory host-key
  pinning; the control plane runs only Trusted/Audited opcodes. A Cabal flag
  (`-f remote-only-untrusted`) omits the local executor at compile time.

### The ISA

Every opcode is one of:

- **Untrusted** — interacts with the outside world (shell, files, web,
  browser); runs in an isolated env. ACK-before-execute: the dispatcher
  durably records the invocation (synchronous fsync) *before* executing, so
  the action never runs until its audit entry is on disk.
- **Trusted** — harness-internal (sessions, scheduling, human interaction);
  in-process, logged in the session transcript.
- **Audited** — Trusted + writes to the global cross-session append-only log
  (memory, skills, agent defs, config).

Opcodes are a GADT in `src/Seal/ISA/Opcode.hs`: pure
`Value -> Either Text ()` authorization, JSON in/out schemas, and a run
function typed by trust level (`UntrustedIO` for Untrusted,
`BackendExec` for Trusted/Audited). The name-indexed registry lives in
`src/Seal/ISA/Registry.hs`.

### Two Global Invariants

1. **No shell-wrapping in Trusted/Audited opcodes.** No `sh -c`, no
   constructed command strings, never an arbitrary or agent-supplied
   command. Direct mechanisms only (native libs, direct handles, SQLite,
   STM). Permitted exception: fixed-argv invocation of a specific trusted
   binary (`age` for vault crypto, `ssh` for transport, `tmux` for harness
   control).
2. **Type-guaranteed argument sanitization.** Every value from user/LLM
   input that reaches a subprocess argv must be a validated
   smart-constructed newtype — never raw `Text`/`String`. Smart constructors
   defend against option injection (reject leading-dash values and/or always
   pass `--` before user-derived arguments).

## Coding Conventions

- GHC2021 on GHC 9.12. Warnings are errors: `-Wall -Werror` plus the strict
  flag set in `seal-harness.cabal` (see existing files for the exact list).
- Always-on `default-extensions` live in the .cabal (`DeriveGeneric`,
  `DerivingStrategies`, `LambdaCase`, `ScopedTypeVariables`); per-file
  pragmas for everything else (`OverloadedStrings`, `RankNTypes`,
  `BangPatterns`, ...).
- Whole-module imports (no explicit symbol lists); `import qualified
  Data.Text as T`; bare `Text` for the pervasive type; external packages
  before internal modules. Fixed-width import padding is fine.
- `Text` not `String`; `ByteString` for binary; `Vector` for indexed access;
  `foldl'` not `foldl`; `modify'` not `modify`; strict fields (`!`) by
  default; explicit `deriving stock` / `deriving newtype`.
- No partial functions (`head`, `tail`, `fromJust`, `read`, `!!`), no orphan
  instances (wrap in a newtype), `Show` is for debugging not serialization,
  no `error`/`undefined` in production code.
- Records: named-field construction; field names `_<type>_<field>` (e.g.
  `_user_email`); `Default` instances for widely-constructed records. No
  content-dependent vertical alignment — never pad `=`, `::`, or comments to
  a variable-length identifier's width.
- Errors: default to `Either Text`. Introduce a bespoke error ADT only when
  the program pattern-matches on it to drive control flow.
- Naming: user-facing terms are descriptive words, not metaphors — a user
  should know what an opcode does from its name alone.

## Recipes

### Adding a new opcode

1. Failing test first: `test/Seal/ISA/Ops/YourOpSpec.hs`. Wire in three
   places: library `exposed-modules:` and test-suite `other-modules:` in
   `seal-harness.cabal`, plus `test/Main.hs`.
2. Implement `src/Seal/ISA/Ops/YourOp.hs`: pick trust level, write pure
   `authorize`, `run` (capability methods only for Untrusted), and JSON
   schemas. `OpResult.orRecorded` is what the transcript stores — must be
   secret-free; secret values go in `orParts` only, and the name goes in
   `secretOpcodes` in `Registry.hs`.
3. Register in the opcode list passed to `mkRegistry` — order controls the
   tool order the model sees.
4. Untrusted: never import `System.Process`/`System.Directory`/
   `System.Posix`; call `UntrustedIO` methods.
5. `make check`.

### Adding a new module

`src/Seal/Area/Module.hs` → library `exposed-modules:`; matching
`test/Seal/Area/ModuleSpec.hs` → test-suite `other-modules:`; wire into
`test/Main.hs`; `make check`.

The .cabal file and `test/Main.hs` are merge hotspots across parallel work —
keep edits there minimal and rebase before opening a PR.

## Testing

hspec + QuickCheck. Tests assert real behavior — vacuously-true properties
are sent back. Bound all generators; keep the suite sub-second; no unbounded
filesystem trees or blocking I/O. Tests needing a real binary or hardware
token are guarded with `pendingWith`.

## PR Workflow

1. Claim the issue: `gh issue edit <NN> --add-assignee @me`.
2. Branch from `main`: `git switch main && git pull && git switch -c
   <area>/<desc>-<NN>`.
3. Open a **draft PR immediately** (`gh pr create --draft --fill --body
   "Closes #<NN>"`), push as you go.
4. Keep `make check` green; rebase on `main`, then `gh pr ready`.

PR requirements: one logical change, `Closes #NN` in the body, tests for new
behavior, `hlint` clean, never skip CI gates or use `--no-verify`. CI runs
the same gate on Linux + macOS (`.github/workflows/ci.yml`) — a PR cannot
merge red.

## Pointers

- `README.md` — the spec; the source of truth when behavior is in question.
- `CONTRIBUTING.md` — full workflow, rules, testing, PR process.
- `docs/superpowers/specs/` (approved designs) and `plans/` (TDD plans).
  Read the referenced design-doc section before picking up an issue. The
  roadmap lives at `docs/superpowers/plans/2026-06-28-seal-harness-roadmap.md`.
- Core source: `src/Seal/ISA/Opcode.hs` (the GADT), `src/Seal/ISA/Dispatch.hs`
  (ACK-before-execute), `src/Seal/ISA/Registry.hs`, `src/Seal/Security/Path.hs`
  (SafePath — opaque, unexported constructor, use `mkSafePath`/`mkSafePathForWrite`),
  `src/Seal/Security/Policy.hs` (pure command authorization),
  `src/Seal/Tools/Exec/UntrustedIO.hs`, `src/Seal/Agent/Loop.hs`,
  `src/Seal/Core/Types.hs`.
- Full Haskell conventions: `.agents/skills/haskell-coder/SKILL.md`;
  review checklist: `.agents/skills/haskell-reviewer/SKILL.md`.