<p align="center">
  <img src="assets/SealLogo.png" alt="Seal Harness logo — baby seal" width="200">
</p>

<p align="center">
  <strong>Seal Harness</strong><br>
  <em>The OS for secure AI agent execution</em>
</p>

<p align="center">
  <a href="https://github.com/seal-harness/seal-harness/actions/workflows/ci.yml"><img src="https://github.com/seal-harness/seal-harness/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-FSL--1.1--MIT-blue" alt="License"></a>
</p>

---

> **Status:** Pre-alpha. Active design and development.
> This is a harness designed from the ground up for security and reliability
> around the SealOp Instruction Set Architecture (ISA).

**Every agent action bears the Seal.**

AI agents are powerful. They're also dangerous. Every company racing to deploy
autonomous agents hits the same wall: agents need shell access to be useful,
modify state across systems with no audit trail, fail silently, and leave
corrupt state behind. Everyone wants autonomous agents. Nobody has the
infrastructure to trust them.

Seal Harness is the open-source agent runtime that solves this at the
architectural level — not with policies to remember, but with structural
guarantees enforced by the system.

## Naming Philosophy

User-facing terminology should use **descriptive words**, not metaphors
that may be unfamiliar to the audience. We prioritize clarity over cleverness.
A user should understand what an opcode does from its name alone, without
needing to learn a domain-specific vocabulary first. Internal implementation
details and developer-facing API names may use specialized terminology, but
anything an end user or contributor encounters in documentation, CLI output,
or configuration should be plain and self-explanatory.

## What Makes This Different

### Transcript IS the Audit Log

Every operation an agent performs — memory changes, skill edits, shell
commands, file writes — is a transcript entry. The transcript is append-only,
hash-chained, and mirrored off-box. There is no separate audit log to
reconcile. The transcript *is* the source of truth, and all derived state is
rebuilt from transcript replay.

### Instruction Set Architecture, Not "Tool Calls"

Every other agent framework has ad-hoc tool calls: `shell`, `read_file`,
`web_search`, whatever the developer thought of that week. No unifying design.
No privilege model. No atomicity guarantees.

Seal Harness defines a formal ISA — a complete, closed set of 74 opcodes where
every instruction has:

- **Defined input/output schema** — not "whatever JSON the LLM generates"
- **Privilege classification** — Untrusted (isolated execution, interacts with outside world), Trusted (harness-internal, logged in session transcript), or Audited (harness-internal, logged in session transcript AND in a unified cross-session append-only log)
- **Atomicity guarantee** — what state is left if the opcode fails mid-execution
- **Transcript entry format** — how the execution is recorded in the audit log
- **Authorization gate** — what must be satisfied before execution

### Trust Levels: Untrusted, Trusted, Audited

Every opcode is classified into one of three trust levels:

**Untrusted** opcodes interact with the outside world — shell commands, file
I/O, web requests, browser automation, code execution. They execute in an isolated, disposable environment with no path to modify agent identity, memory,
skills, or the audit trail. The harness refuses to act on any untrusted opcode
until the transcript daemon confirms the audit entry is written
(**ACK-before-execute**). If the audit log can't record it, the operation
doesn't happen.

**Trusted** opcodes operate on the agent's own state — sessions, scheduling,
human interaction, tool management. They execute within the harness itself,
and every execution is logged in the current session's transcript.

**Audited** opcodes are Trusted opcodes that *also* write to a **unified
cross-session append-only log**. This log captures every mutation to the
agent's persistent evolutionary state — memory, skills, agent definitions,
and configuration. No matter how many concurrent sessions (tabs) are running,
every change to these four stores lands in one global, append-only,
hash-chained log.

**Why Audited exists:** An agent can modify its own memory, rewrite its own
skills, change its own definition, alter its own configuration. These mutations
transcend any single session — they shape the agent's evolution over its
entire lifetime. If these were only in per-session transcripts, reconstructing
the full history would require correlating across all sessions, which becomes
infeasible with concurrent multi-session use. Worse, an agent that "commits
suicide" (deletes its memories, lobotomizes its skills, rewrites its own
definition) could leave you unable to reconstruct what was lost.

The audited log solves this. It is append-only — the agent cannot delete or
rewrite entries, only supersede them. It spans all sessions. It is
hash-chained and mirrored off-box, same as the transcript. If an agent
self-destructs, you replay the audited log forward to reconstruct state at
any point in the agent's lifetime. **The agent's evolution is permanent and
recoverable.**

### Secret Protection

Secrets get first-class treatment. API keys, bearer tokens, pairing codes, and
encryption keys are not stored in plaintext config files or environment
variables that any shell command can read. They live in an **encrypted vault**
with proper cryptographic guarantees.

**The vault:**

- Encrypted at rest using [age](https://age-encryption.org) — public-key
  encryption with support for hardware tokens (YubiKey, NitroKey) via
  `age-plugin-yubikey`. No software-only keys required.
- Three unlock modes: explicit unlock at startup, automatic unlock on first
  access, or decrypt-from-disk on every operation (keys never held in memory
  longer than needed).
- Atomic writes (write to temp, chmod 0600, rename) — no partial states.
- Rekey support: re-encrypt the entire vault with a new key, verified
  byte-for-byte before the old vault is replaced.

**The secret types:**

All secret values use opaque newtypes with redacted `Show` instances and no
`ToJSON`/`FromJSON` instances. There is no code path that accidentally
serializes a secret to the transcript, logs, or API response. Access is via
CPS-style continuations (`withApiKey`, `withBearerToken`) that limit the
secret's scope to a single function — it can't leak into a binding that
persists beyond the call.

**The opcodes:**

The Secrets group provides five opcodes for vault management. All are
Audited — every vault mutation (save, delete) is recorded in the unified
cross-session log. But **secret values are never written to the audited log
or the session transcript.** Only key names and operation metadata are
recorded. The audited log proves *that* a secret was saved or retrieved,
not *what* it was.

Vault lock, unlock, and rekey are admin operations handled by the CLI, not
agent opcodes. Unlocking can require a physical hardware token (YubiKey,
NitroKey) — that's a human-in-the-loop step, not something the agent does
autonomously. If the vault is locked when the agent calls `SECRET_GET`, it
gets a "vault locked" error and can ask the human to unlock it via `ASK_HUMAN`.

| Opcode | What it does |
|---|---|
| `SECRET_SAVE` | Encrypt and store a secret under a key name |
| `SECRET_GET` | Decrypt and return a secret (value stays in memory, not logged) |
| `SECRET_LIST` | List key names only — never values |
| `SECRET_DELETE` | Remove a secret from the vault |
| `VAULT_STATUS` | Report locked/unlocked state, key type, secret count |

This isn't a config file with `API_KEY=***`. It's a cryptographically sealed
vault with hardware token support, atomic operations, and a full audit trail
of every access — without ever exposing the secrets themselves.

### Security by Construction

Haskell's type system eliminates entire classes of vulnerabilities at compile
time:

| Security Property | How It's Enforced | What Fails at Compile Time |
|---|---|---|
| Command authorization | `AuthorizedCommand` proof type | Executing a shell command without policy approval |
| Filesystem confinement | `SafePath` validated path | Accessing files outside the workspace |
| Secret protection | Opaque newtypes, redacted `Show`, no serialization instances, encrypted vault | Logging or serializing API keys, tokens, pairing codes |
| Policy evaluation | Pure functions, no IO | Security checks that depend on external state |
| Error isolation | `PublicError` channel type | Leaking internal error details to users |
| Capability scoping | Handle pattern | Accessing capabilities not explicitly provided |

The insecure path is harder to write than the secure path. That's the point.

## Quick Start

### Prerequisites

- **Nix** (recommended) — [install Nix](https://nixos.org/download) for fully reproducible builds
- **Or** GHC 9.10+ and Cabal — via [GHCup](https://www.haskell.org/ghcup/)
- An API key from your AI provider of choice

### Install and Run

```bash
# Clone the repository
git clone https://github.com/seal-harness/seal-harness.git
cd seal-harness

# Nix (reproducible, no system deps needed)
nix develop            # enter dev shell with GHC + cabal + hlint
nix build              # build the executable
nix run                # run directly

# Or Cabal (requires GHC toolchain)
cabal build
cabal run seal
```

### Start a Chat

```bash
# Anthropic (default)
export ANTHROPIC_API_KEY="***"
seal

# OpenAI
seal --provider openai --model gpt-4o

# Ollama (local, no API key needed)
seal --provider ollama --model llama3

# With tool access and persistent memory
seal --allow git --allow ls --memory sqlite
```

## The Instruction Set

The ISA defines 77 opcodes organized into 16 groups. Every opcode is classified
as **Untrusted** (prefer isolated execution, interacts with outside world), **Trusted**
(harness-internal, logged in session transcript), or **Audited** (harness-internal,
logged in session transcript AND in a unified cross-session append-only log).

| Group | Key Opcodes | Trust |
|---|---|---|
| **Memory** | `MEMORY_WRITE`, `MEMORY_RECALL`, `MEMORY_DELETE` | Audited |
| **Skills** | `SKILL_WRITE`, `SKILL_READ`, `SKILL_LIST`, `SKILL_DELETE` | Audited |
| **Agents** | `AGENT_DEF_WRITE`, `AGENT_DEF_READ`, `AGENT_DEF_LIST`, `AGENT_DEF_DELETE`, `AGENT_INSTANCES`, `AGENT_START`, `AGENT_STATUS`, `AGENT_STOP` | Audited |
| **Config** | `CONFIG_VIEW`, `CONFIG_UPDATE`, `TARGET_SET`, `PROVIDER_LIST` | Audited |
| **Secrets** | `SECRET_SAVE`, `SECRET_GET`, `SECRET_LIST`, `SECRET_DELETE`, `VAULT_STATUS` | Audited |
| **Sessions** | `SESSION_NEW`, `SESSION_COMPACT`, `SESSION_SEARCH` | Trusted |
| **Scheduling** | `CRON`, `HEARTBEAT_WAKEUP` | Trusted |
| **Human Interaction** | `ASK_HUMAN`, `SHOW_HUMAN` | Trusted |
| **Tools (Meta)** | `TOOL_SEARCH`, `TOOL_DESCRIBE`, `TOOL_CALL`, `TOOL_LIST` | Trusted |
| **MCP** | `MCP_LIST`, `MCP_CONNECT`, `MCP_DISCONNECT` | Trusted |
| **Harnesses** | `HARNESS_LIST`, `HARNESS_START`, `HARNESS_STOP`, `PLAN_MODE` | Trusted |
| **Execution** | `SHELL_EXEC`, `PROCESS_MANAGE`, `BIN_EXEC` | Untrusted |
| **Files** | `FILE_READ`, `FILE_WRITE`, `SEARCH_FILES`, `FILE_PATCH` | Untrusted |
| **Web & Browser** | `WEB_SEARCH`, `WEB_EXTRACT`, `BROWSER_*` | Untrusted |
| **Media** | `IMAGE_ANALYZE`, `IMAGE_GENERATE`, `TEXT_TO_SPEECH` | Untrusted |

See the [ISA specification](docs/isa.md) for the complete opcode reference
with input/output schemas, atomicity guarantees, transcript entry formats, and
authorization gates.

### Dynamic Retrieval Pattern

Data retrieval opcodes (`FILE_READ`, `WEB_EXTRACT`, `BROWSER_SNAPSHOT`,
`SEARCH_FILES`, `MEMORY_RECALL`, `SESSION_SEARCH`) share a common design
pattern: **stat first, then adapt.** The opcode inspects the data source's
dimensions before returning content, then adapts how much to return using a
principled mathematical function — not hardcoded thresholds or the model's
guess.

Page size follows the **square root law**: `page_size = min(total, max(floor, round(A · total^0.5)), ceiling)`. Sublinear growth: a 10× larger file returns √10 ≈ 3.16× more content. Coefficients are configurable at three layers: `config.yaml` (persistent), `CONFIG_UPDATE` (per-session), inline `strategy` field (per-call).

## Architecture

```
seal-harness/
├── src/Seal/
│   ├── Core/            Types, Config, Errors
│   ├── Security/        Path, Command, Policy, Secrets, Crypto, Pairing, Vault
│   ├── Handles/         File, Shell, Network, Memory, Channel, Log
│   ├── ISA/             Opcode definitions, dispatcher, registry
│   ├── Tools/            Opcode implementations
│   ├── Agent/           Loop, Context, Memory, Identity
│   ├── Providers/       Anthropic, OpenAI, OpenRouter, Ollama
│   ├── Channels/        CLI, Telegram, Signal
│   ├── Memory/          SQLite, Markdown, None
│   ├── Gateway/         Server, Routes, Auth
│   ├── Scheduler/       Cron, Heartbeat
│   └── CLI/             Commands
├── test/                Test suite
└── docs/
    ├── ARCHITECTURE.md
    ├── isa.md
    └── SECURITY.md
```

### Key Design Decisions

- **No effect systems** — `ReaderT AppEnv IO` and the Handle pattern throughout--explicit decision.
- **Pure policy evaluation** — `SecurityPolicy` has no IO. Fully testable with QuickCheck.
- **Capability-based handles** — Each function declares exactly which capabilities it needs.
- **Static dispatch** — Typeclass resolution at compile time. Existentials only at the CLI wiring boundary.
- **Transcript as source of truth** — All derived stores (memory, skills, agent defs) are materialized views rebuilt from transcript replay.

## Development

### Running Tests

```bash
# Run the full test suite
nix develop --command cabal test

# Run with HPC coverage report
nix develop --command cabal test --enable-coverage

# Run hlint
nix develop --command hlint src/ test/
```

### Project Standards

- **GHC flags:** `-Wall -Werror` with strict warnings (incomplete patterns, name shadowing, unused imports)
- **TDD:** Red-green methodology...failing tests first, implementation second
- **Linting:** hlint clean required before merge
- **CI:** GitHub Actions with Nix builds

### With direnv

```bash
echo "use flake" > .envrc
direnv allow
```

## License

**FSL-1.1-MIT** (Functional Source License) — source-available with a
"Competing Use" restriction. Each version converts to MIT license two years
after its release date. See [LICENSE](LICENSE) for details.
