---
kind: agents
---

# Seal Harness — AGENTS.md

> **Purpose:** A compact guide for any contributor (human or AI agent) starting
> development on Seal Harness. Read this first. It distills the README,
> CONTRIBUTING.md, the design docs, the haskell-coder/haskell-reviewer skills,
> and the source tree into everything you need to start writing code that
> lands cleanly.

---

## What Is Seal Harness?

A **security-first Haskell runtime for AI agents**, built around the **SealOp
ISA** — a formal Instruction Set Architecture where every agent action is a
typed opcode with a defined schema, trust classification, atomicity guarantee,
transcript entry format, and authorization gate. The transcript (append-only,
hash-chained) IS the audit log. All derived state is rebuilt from transcript
replay.

**Mission:** Provide guarantees where guarantees are needed. The insecure path
is harder to write than the secure path.

**License:** FSL-1.1-MIT (source-available, converts to MIT two years per version).

**Status:** Pre-alpha. Active design and development.

---

## The Rules (Non-Negotiable)

### 1. Clean-room implementation

Do **not** copy source from, or reference, any other proprietary or related
codebase — not in code, identifiers, comments, commit messages, PR
descriptions, or docs. Implement from design docs and public specifications in
this repo's own style and `Seal.*` namespace. Port the *idea*, write it fresh.

### 2. Human-authorship rule

**Things that have to be read by humans must be written by humans.** GitHub
issues, design docs, and human-facing prose are human-authored and
human-vouched. AI writes code. Humans write the rules the code must follow.

### 3. Security-first

- Never commit or log secrets, keys, tokens, or vault contents.
- Secret types are opaque by construction — keep them that way.
- Proof type constructors stay **unexported** (`SafePath`, `AuthorizedCommand`).
- Found a vulnerability? **Do not open a public issue.** Disclose privately.

### 4. TDD

Red-green methodology. Write the failing test first, watch it fail, commit the
failure, implement the minimum, watch it pass, commit. Security-critical pure
functions get QuickCheck properties.

### 5. No git force pushes. Ever.

### 6. When starting work on a new feature, check out a new branch first
(e.g. `git checkout -b <name>`).

---

## Development Environment

Everything runs through the **Nix flake dev shell**. You do not install GHC,
cabal, or hlint yourself.

```bash
# Enter the dev shell
nix develop

# Or use the Makefile wrappers (all run inside nix develop):
make build      # cabal build all (-Werror clean)
make test       # cabal test
make lint       # hlint src/ test/ (must report: No hints)
make check      # build + test + lint (the full local gate — what CI runs)
make tui        # launch the interactive TUI (seal tui)
make run ARGS="--help"
make serve      # rebuild frontend + launch gateway
make ghci       # GHCi session on the library
make shell      # drop into interactive dev shell

make serve ARGS="--yolo" # Run the server with --yolo (safe if you have configured an external execution server)
```

Raw equivalents:
```bash
nix develop --command cabal build all
nix develop --command cabal test
nix develop --command hlint src/ test/
```

**direnv:** `echo "use flake" > .envrc && direnv allow`

**Frontend** (Phase 7): React 18 + TypeScript + Vite + Tailwind. The dev shell
includes `nodejs_22`. `make serve` builds the frontend then runs the gateway.
The frontend is embedded into the binary at compile time via `file-embed`
(`embedDir "frontend/dist"`), so `frontend/dist` must exist when `cabal build`
runs (the Makefile gates this).

### Shell Command Pitfalls

**Never pipe `cabal` (or other Haskell binary) output through `head`/`tail`.**
The Haskell RTS sets `SIGPIPE` to `SIG_IGN` on startup. When a consumer like
`head -80` closes the pipe early, the next write from `cabal` throws an
`IOError` (`ResourceVanished` / `EPIPE`) inside cabal's process. Instead of
dying cleanly, cabal hangs in its exception handler — the shell pipe never
returns and the command appears to hang forever.

**Use file redirection instead:**
```bash
nix develop --command cabal build all >build.log 2>&1; head -80 build.log
nix develop --command cabal test >test.log 2>&1; head -80 test.log
```

Then read the log file with `FILE_READ` or `head` on the file (not on the
pipe). This applies to any Haskell binary (`cabal`, `hlint`, `ghcid`,
`nix`-spawned Haskell tools, etc.). Non-Haskell programs (`make`, `rg`,
`git`) are not affected because they use the default `SIGPIPE` handler.

When in doubt: redirect to a file, then page through the file.

---

## Architecture

```
seal-harness/
├── src/Seal/
│   ├── Core/            Types, Config, Errors (TrustLevel, OpName, SessionId, Paging)
│   ├── Security/        Path (SafePath), Command (AuthorizedCommand), Policy, Secrets, Crypto, Vault, Adoption
│   ├── Handles/         Capability records: Channel, AskReply, Harness, Tab, Transcript
│   ├── ISA/             Opcode definitions, dispatcher, registry
│   │   ├── Opcode.hs    The Opcode GADT (TrustedOpcode | UntrustedOpcode)
│   │   ├── Dispatch.hs   ACK-before-execute dispatcher
│   │   ├── Registry.hs   Name-indexed opcode set → tool definitions
│   │   └── Ops/          Opcode implementations (File, Shell, Bin, Search, Process, Secret, Memory, Skills, Agent, Harness, Human, Repo, Registry)
│   ├── Tools/Exec/       UntrustedIO (unified capability handle), Local/Remote executors, Args
│   ├── Agent/            Loop (turn loop), Env, Def (agent definitions), Runtime (delegation/registry)
│   ├── Providers/        Anthropic (+OAuth), Ollama, Class, Registry, ContextWindow
│   ├── Channels/         Class, Loop, Cursor, Signal (+Transport/Run), Telegram (+Commands/Run/Transport)
│   ├── Channel/          Caps, Cli (haskeline REPL — secondary dev surface)
│   ├── Memory/           Types, Backend (SQLite, Markdown, None)
│   ├── Skills/           Types, Codec, Backend, Autoload, Prompt, Builtins
│   ├── Gateway/          Server (Warp/WAI), API, Stream (WS), StreamBroker, Send, Broadcast, Transcript, Config, ListsSnapshot, SessionJson
│   ├── Harness/          Id, Registry, Tmux, Reconcile, Observer, Discovery
│   ├── Tabs/             Types, Persist, Partition, Relay, Wizard, Runtimes
│   ├── Transcript/       Types, Entries, Conv, Reconstruct
│   ├── Session/          Kind, Store, Meta, Workdir, Log, Lock
│   ├── Config/           File, Migrate, Paths, Security
│   ├── Command/          Parse, Model, Help, Provider, Session, Serve, Skill, Agent, Background, Call, New, Spec, Tab, Channel
│   ├── Routing/          Route (terse /N grammar front-end)
│   ├── Web/              Search, Fetch, Browser, UrlSafety, SearXngSetup, UiState
│   ├── Media/            Image, Tts
│   ├── Vault/            Backend, Commands
│   ├── Store/            Markdown
│   ├── Logging/          Logger, ChannelContext, Exceptions, Global
│   ├── Text/             LineFile
│   ├── Ingest.hs         The single ingress chokepoint (preprocessing before any LLM call)
│   ├── AppMain.hs        Top-level wiring
│   └── Tui.hs            Terminal UI
├── exe/Main.hs           Thin entry point → delegates to library
├── test/                 hspec + QuickCheck test suite
├── frontend/             React 18 + TypeScript + Vite + Tailwind SPA
├── config/skills/core/   Built-in skills (seal-usage.md)
├── docs/                 Design docs, plans, handoffs
│   └── superpowers/
│       ├── specs/        Approved designs (the "what" and "why")
│       └── plans/        Detailed TDD implementation plans
├── .agents/             .agents Protocol config (agents, skills, agents.md)
└── .opencode/            OpenCode config (symlinks to .agents/, commands, opencode.json)
```

### Key Design Decisions

- **No effect systems** — `ReaderT AppEnv IO` + Handle pattern throughout.
  Explicit decision. No `StateT`, no `ExceptT` in the stack.
- **Pure policy evaluation** — `SecurityPolicy` has no IO. Fully testable with QuickCheck.
- **Capability-based handles** — Each function declares exactly which
  capabilities it needs. The `Shell` handle is wired only into Untrusted
  implementations, so a Trusted opcode that shells out **fails to compile**.
- **Static dispatch** — Typeclass resolution at compile time. Existentials
  only at the CLI wiring boundary.
- **Transcript as source of truth** — All derived stores (memory, skills,
  agent defs) are materialized views rebuilt from transcript replay. The
  transcript is a two-file format: `conversation.jsonl` (messages) +
  `entries.jsonl` (audit entries).

### The Two-Plane Split

```
Control plane (harness machine)          Untrusted plane (remote, via SSH)
┌──────────────────────────────┐        ┌──────────────────────────────┐
│ agent loop, ISA dispatch       │  SSH   │ SHELL_EXEC, BIN_EXEC,          │
│ transcript (append-only audit)  │ ────▶ │ PROCESS_MANAGE                │
│ secret vault (age)             │        │ FILE_READ/WRITE/SEARCH/PATCH   │
│ Trusted + Audited opcodes      │        │ WEB_*, BROWSER_*, media         │
│ NO untrusted execution         │        │ (workspace lives here)         │
└──────────────────────────────┘        └──────────────────────────────┘
```

In `mode=remote`, untrusted execution runs on a separate machine over SSH
with mandatory host-key pinning. The control plane never runs agent-driven
commands. A Cabal flag (`-f remote-only-untrusted`) can compile-time omit the
local executor entirely.

---

## The ISA (Instruction Set Architecture)

The ISA defines opcodes in groups. Every opcode is classified by **trust
level**:

| Trust Level | What it means | Where it runs |
|---|---|---|
| **Untrusted** | Interacts with outside world (shell, files, web, browser) | Isolated/disposable env, ACK-before-execute |
| **Trusted** | Harness-internal (sessions, scheduling, human interaction, tools) | In-process, logged in session transcript |
| **Audited** | Trusted + writes to unified cross-session log (memory, skills, agent defs, config) | In-process + global append-only log |

### The Opcode GADT

```haskell
data Opcode
  = TrustedOpcode
      { toName       :: OpName
      , toTrust      :: TrustLevel       -- Trusted or Audited
      , toDesc       :: Text
      , toInSchema   :: Value
      , toOutSchema  :: Value
      , toAuthorize  :: Value -> Either Text ()
      , toRun        :: BackendExec -> Value -> App OpResult
      }
  | UntrustedOpcode
      { uoName       :: OpName
      , uoDesc       :: Text
      , uoInSchema   :: Value
      , uoOutSchema  :: Value
      , uoAuthorize  :: Value -> Either Text ()
      , uoRun        :: UntrustedIO -> Value -> App OpResult
      }
```

**Capability scoping is type-level:** `UntrustedIO` is only in scope for
`UntrustedOpcode`. A Trusted opcode that shells out literally cannot be
constructed — it has no `UntrustedIO` in scope. A compile-fail fixture
(`Seal.Tools.Exec.CapabilityScopingFail`) asserts this.

### ACK-Before-Execute

For Untrusted opcodes, the dispatcher durably records the invocation
(`tfwRecordAndAck` — synchronous fsync) **BEFORE** executing. The untrusted
action never runs until its audit entry is on disk. Trusted opcodes record
concurrently.

### The UntrustedIO Capability Handle

Every side-effecting IO an untrusted opcode can perform is a method on
`UntrustedIO`. Opcode modules **never** import `System.Process`,
`System.Directory`, or `System.Posix` — they call capability methods. The
constructor is not exported; only two smart constructors exist:

- `mkLocalUntrustedIO :: WorkspaceRoot -> UntrustedIO` (absent under
  `-f remote-only-untrusted`)
- `mkRemoteUntrustedIO :: SshConfig -> RemoteRunner -> UntrustedIO`

### ISA Groups

| Group | Key Opcodes | Trust |
|---|---|---|
| Memory | `MEMORY_WRITE`, `MEMORY_RECALL`, `MEMORY_DELETE` | Audited |
| Skills | `SKILL_WRITE`, `SKILL_LOAD`, `SKILL_LIST`, `SKILL_DELETE` | Audited |
| Agents | `AGENT_DEF_WRITE/READ/LIST/DELETE`, `AGENT_INSTANCES`, `AGENT_START`, `AGENT_STATUS`, `AGENT_STOP` | Audited |
| Config | `CONFIG_VIEW`, `CONFIG_UPDATE`, `TARGET_SET`, `PROVIDER_LIST` | Audited |
| Secrets | `SECRET_SAVE`, `SECRET_GET`, `SECRET_LIST`, `SECRET_DELETE`, `VAULT_STATUS` | Audited |
| Sessions | `SESSION_NEW`, `SESSION_COMPACT`, `SESSION_SEARCH` | Trusted |
| Scheduling | `CRON`, `HEARTBEAT_WAKEUP` | Trusted |
| Human Interaction | `ASK_HUMAN`, `SHOW_HUMAN` | Trusted |
| Tools (Meta) | `TOOL_SEARCH`, `TOOL_DESCRIBE`, `TOOL_LIST` | Trusted |
| MCP | `MCP_LIST`, `MCP_CONNECT`, `MCP_DISCONNECT` | Trusted |
| Harnesses | `HARNESS_LIST`, `HARNESS_START`, `HARNESS_STOP`, `PLAN_MODE` | Trusted |
| Execution | `SHELL_EXEC`, `PROCESS_MANAGE`, `BIN_EXEC` | Untrusted |
| Files | `FILE_READ`, `FILE_WRITE`, `SEARCH_FILES`, `FILE_PATCH` | Untrusted |
| Web & Browser | `WEB_SEARCH`, `WEB_EXTRACT`, `BROWSER_*` | Untrusted |
| Media | `IMAGE_ANALYZE`, `IMAGE_GENERATE`, `TEXT_TO_SPEECH` | Untrusted |

### Dynamic Retrieval Pattern

Data retrieval opcodes share a "stat first, then adapt" pattern: inspect the
data source's dimensions, then return content using the square root law:
`page_size = min(total, max(floor, round(A · total^0.5)), ceiling)`. Coefficients
are configurable at three layers: `config.yaml`, `CONFIG_UPDATE`, inline
`strategy` field.

---

## Security Architecture

### SafePath

`SafePath` is an opaque type with an unexported constructor. Obtained via
`mkSafePath` (for reads — path must exist) or `mkSafePathForWrite` (for writes
— parent must exist, final component may not). Validation steps:

1. Reject blocked names (`.env`, `.ssh`, `.gnupg`, `.netrc`, `.seal`)
2. Lexically collapse `.`/`..` and check containment (pure, no FS access)
3. Canonicalize (follows symlinks)
4. Re-run containment check on canonical path
5. Confirm existence

For remote paths: `mkSafePathRemote` (pure, lexical-only — no
`canonicalizePath` since the file is on a remote machine).

### AuthorizedCommand

A proof type — unexported constructor. Shell commands must be authorized via
the `SecurityPolicy` before execution. The policy is pure (no IO), heavily
QuickCheck'd.

### Secrets

Opaque newtypes (`ApiKey`, `BearerToken`, `PairingCode`, `SecretKey`) with:
- Redacted `Show` instances (never reveal bytes)
- No `ToJSON`/`FromJSON` instances
- CPS-only access (`withApiKey`, `withBearerToken`) — scope limited to a single
  function, can't leak into a persistent binding

### Vault

- Encrypted at rest using [age](https://age-encryption.org) — public-key
  encryption with hardware token support (YubiKey, NitroKey)
- Three unlock modes: startup, on-demand, per-access
- Atomic writes (tmp → chmod 0600 → rename)
- Rekey support with verify-before-replace
- Secret values **never** written to transcript or audited log — only key
  names and operation metadata

### Two Global Invariants

1. **No shell-wrapping in Trusted/Audited opcodes.** They never run an
   arbitrary or agent-supplied command. No `sh -c`, no constructed command
   strings. Direct mechanisms only (native libs, direct handles, SQLite,
   STM). *Permitted:* fixed-argv invocation of a specific trusted binary (`age`
   for vault crypto, `ssh` for untrusted transport, `tmux` for harness
   control).

2. **Type-guaranteed argument sanitization.** Every value from user/LLM input
   that reaches a subprocess argv must be a validated, smart-constructed
   newtype — never raw `Text`/`String`. The exec wrappers accept only these
   types, so unsanitized input fails to compile. Smart constructors defend
   against option injection (reject leading-dash values and/or always pass
   `--` before user-derived arguments).

---

## Coding Conventions

### Language & Flags

- **GHC2021** (GHC 9.12)
- **Always-on `default-extensions`** (in `.cabal`): `DeriveGeneric`,
  `DerivingStrategies`, `LambdaCase`, `ScopedTypeVariables`
- **Per-file pragmas** for everything else: `OverloadedStrings`,
  `GeneralizedNewtypeDeriving`, `RankNTypes`, `BangPatterns`, etc.
- **GHC flags:** `-Wall -Werror -Wcompat -Widentities -Wincomplete-uni-patterns
  -Wincomplete-record-updates -Wname-shadowing -Wpartial-fields
  -Wredundant-constraints`
- Warnings are errors. The build must stay green.

### Imports

- **Whole-module imports** (`import Data.Foo`), not explicit symbol lists
- **Qualified alias** for collections/text: `import qualified Data.Text as T`
- **Bare type name** for pervasive types: `import Data.Text (Text)`
- Organize: external packages → internal modules, qualified where appropriate
- Fixed-width padding for `import` lines is fine (constant 10 spaces after
  `import` to align module names after `qualified`)

### Records

- Field names: `_<type>_<field>` (e.g. `_user_email`) — leading `_` for
  future `makeLens` compatibility, type prefix for uniqueness, second `_` as
  deterministic separator
- Named-field construction syntax, not positional
- `Default` instances for records constructed in many places with shared
  values
- **No content-dependent vertical alignment** — don't pad `=`, `::`, or
  comments to the width of a variable-length identifier. Constant-width
  padding (indentation, import alignment) is fine.

### Errors

- Default to `Either Text` / `ExceptT Text`
- Introduce a bespoke error ADT **only** when the program pattern-matches the
  error to drive control flow
- Fold report-only failures into one `Text`-carrying catch-all constructor
- `error`/`undefined` never in production code (ok for stubbing during dev)

### Other

- `Text` not `String`. `ByteString` for binary. `Vector` for indexed access.
- `foldl'` not `foldl`. `modify'` not `modify`.
- Strict fields (`!`) by default in data types.
- `deriving stock` / `deriving newtype` explicitly.
- No orphan instances — use newtypes to wrap.
- `Show` is for debugging, not serialization.
- No partial functions (`head`, `tail`, `fromJust`, `read`, `!!`).

### Naming Philosophy

User-facing terminology uses **descriptive words**, not metaphors. A user
should understand what an opcode does from its name alone. Internal
implementation details may use specialized terminology.

---

## Adding a New Opcode

1. **Write the failing test first** (in `test/Seal/ISA/Ops/YourOpSpec.hs`).
   Wire it in three places:
   - `seal-harness.cabal` → library `exposed-modules:` (add the source module)
   - `seal-harness.cabal` → test-suite `other-modules:` (add the spec)
   - `test/Main.hs` → import + run the spec

2. **Implement the opcode** in `src/Seal/ISA/Ops/YourOp.hs`:
   - Choose trust level (Untrusted → `UntrustedOpcode`, Trusted/Audited →
     `TrustedOpcode`)
   - Define `uoAuthorize` / `toAuthorize` (pure `Value -> Either Text ()`)
   - Define `uoRun` / `toRun` (the execution — calls capability methods, never
     raw IO for Untrusted opcodes)
   - Define `uoInSchema` / `toInSchema` (JSON schema for the LLM)
   - The `OpResult` has `orParts` (what the model sees), `orIsError`, and
     `orRecorded` (what the transcript records — must be secret-free)

3. **Register it** — add to the opcode list passed to `mkRegistry` in the
   wiring layer. Registration order matters (controls which tools the model
   sees first).

4. **If Untrusted:** never import `System.Process`/`System.Directory`/
   `System.Posix`. Call `UntrustedIO` methods. The capability handle is
   backend-selected at wiring time.

5. **If it involves secrets:** secret values go in `orParts` only, never in
   `orRecorded`. Add the opcode name to `secretOpcodes` in `Registry.hs` if
   it returns secret values.

6. **Gate check:** `make check` (build + test + lint). All must pass.

---

## Adding a New Module

1. Create `src/Seal/Area/Module.hs`
2. Add to `seal-harness.cabal` → library `exposed-modules:`
3. Create matching `test/Seal/Area/ModuleSpec.hs`
4. Add spec to `seal-harness.cabal` → test-suite `other-modules:`
5. Wire in `test/Main.hs`
6. `make check`

The cabal file and `test/Main.hs` are the common merge points across parallel
work — keep edits there minimal and rebase before opening your PR.

---

## Testing

- **hspec + QuickCheck.** Tests assert real behavior — vacuously-true
  properties are sent back. Prefer exact assertions and meaningful generators.
- Keep the suite **fast** (sub-second). Bound QuickCheck generators. Never let
  a test create unbounded filesystem trees or block on I/O.
- Security-critical pure functions (policy, path validation) get QuickCheck
  properties.
- Tests that need a real binary or hardware token are guarded (`pendingWith`)
  so the suite stays green without them.
- The test suite has **600+ examples** across 130+ spec files. Run with
  `make test`.

---

## CI

GitHub Actions (`.github/workflows/ci.yml`):
- Matrix: `x86_64-linux` (ubuntu-latest) + `aarch64-darwin` (macos-latest)
- Nix builds with cache restoration
- `nix build` + `nix develop --command cabal test --enable-coverage`
- HPC coverage report posted to job summary
- S3 Nix binary cache push (on main + same-repo PRs; secrets-gated)
- A PR cannot merge red

---

## PR Workflow

1. **Claim the issue** — `gh issue edit <NN> --add-assignee @me`
2. **Branch from `main`:** `git switch main && git pull && git switch -c <area>/<desc>-<NN>`
3. **Open a draft PR immediately** — scaffold commit, push, `gh pr create --draft --fill --body "Closes #<NN>"`
4. **Push as you go** — reviewers watch and comment on the evolving implementation
5. **Keep gates green:** `make check` (build + test + lint)
6. **Mark "Ready for review"** — `gh pr ready` (rebase on main first)
7. **Iterate to merge**

PR requirements:
- `cabal build all` (`-Werror` clean)
- `cabal test` (all green, no stray warnings)
- `hlint src/ test/` → `No hints`
- Tests for new behavior
- `Closes #NN` in the PR body
- Never `--no-verify` or skip CI gates
- One logical change per PR

---

## Design Docs

Larger work starts as a design doc under `docs/superpowers/`:
- `specs/` — approved designs (the "what" and "why")
- `plans/` — detailed, task-by-task TDD implementation plans

If you're picking up a code issue, read the referenced design-doc section
first — it defines the module's interface contract so parallel work composes
without conflict.

The **roadmap** lives at `docs/superpowers/plans/2026-06-28-seal-harness-roadmap.md`
and defines the phase sequence (Phase 0–8). The README is the spec — when
behavior is in question, the README and design docs are the source of truth.

---

## Phase Status

| Phase | What | Status |
|---|---|---|
| 0 | Scaffolding | DONE |
| 1 | Security foundation + Secret Vault | DONE |
| 2a | Cross-channel types (ChannelKind, MessageSource, AllowList) | DONE |
| 2b | Signal channel | DONE |
| 3 | ISA build-out: core Trusted opcodes | DONE (M1–M4) |
| 4 | Untrusted opcode breadth + isolation (remote exec) | DONE |
| 5 | Audited evolutionary stores (git-backed Markdown) | DONE |
| 6a | Harness backend (tmux, registry, reconcile) | DONE |
| 6b | Tabs-as-view (tab UI, terse /N grammar, relay) | DONE |
| 7a | Gateway + WS broker + minimal chat shell | DONE |
| 7b | Full frontend close-duplication | DONE |
| 8 | More channels (Telegram), Scheduler, MCP, remaining providers | Pending |

---

## Key Files to Read First

| File | What it gives you |
|---|---|
| `README.md` | The spec — full product vision, ISA overview, architecture |
| `CONTRIBUTING.md` | Workflow, rules, testing, PR process |
| `src/Seal/ISA/Opcode.hs` | The Opcode GADT — the heart of the ISA |
| `src/Seal/ISA/Dispatch.hs` | The dispatcher — ACK-before-execute |
| `src/Seal/ISA/Registry.hs` | How opcodes are registered and offered to the LLM |
| `src/Seal/Security/Path.hs` | SafePath — filesystem confinement |
| `src/Seal/Security/Policy.hs` | SecurityPolicy — pure command authorization |
| `src/Seal/Tools/Exec/UntrustedIO.hs` | The unified capability handle for untrusted IO |
| `src/Seal/Agent/Loop.hs` | The turn loop — the agent's main execution cycle |
| `src/Seal/Core/Types.hs` | Core vocabulary (TrustLevel, OpName, SessionId) |
| `docs/superpowers/plans/2026-06-28-seal-harness-roadmap.md` | The master roadmap |
| `.agents/skills/haskell-coder/SKILL.md` | Full Haskell coding conventions |
| `.agents/skills/haskell-reviewer/SKILL.md` | Code review checklist |
