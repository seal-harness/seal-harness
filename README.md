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
  <br>
  <a href="https://seal-harness.github.io/seal-harness/api/index.html">API Docs</a>
  &nbsp;&bull;&nbsp;
  <a href="https://seal-harness.github.io/seal-harness/coverage/main/hpc_index.html">Code Coverage</a>
</p>

---

> **Status:** Pre-alpha. Active design and development.
> This is a harness designed from the ground up for security and reliability
> around the SealOp Instruction Set Architecture (ISA).
> **Seal's mission is to provide guarantees where guarantees are needed.**

**Seals get the job done!**

**Every agent action bears the Seal.**

AI agents are powerful. They're also dangerous. Every company racing to deploy
autonomous agents hits the same wall: agents need shell access to be useful,
modify state across systems with no audit trail, fail silently, and leave
corrupt state behind. Everyone wants autonomous agents. Nobody has the
infrastructure to trust them.

Seal Harness is the open-source agent runtime that solves this at the
architectural level — not with policies to remember, but with structural
guarantees enforced by the system.

## Why Seal Harness

Most agent frameworks are moving in one direction: hiding more of what they
do. Background steps you can't inspect. Tool calls summarized away. State
changes that happened somewhere, somehow, with no record you can replay.
Seal Harness goes the other way.

### Visibility and Transparency

When an agent acts, you see everything. There is no hidden layer where
decisions happen off the record.

**The transcript is the audit log.** Every operation the agent performs —
memory changes, skill edits, shell commands, file writes, web requests —
is a transcript entry. The transcript is append-only, hash-chained, and
mirrored off-box. There is no separate audit log to reconcile against the
"real" state; the transcript *is* the source of truth, and all derived
state (memory, skills, agent definitions) is rebuilt by replaying it.

**ACK-before-execute.** The harness refuses to run any untrusted opcode
(shell, file I/O, web) until the transcript daemon confirms the audit
entry is durably written (synchronous fsync). If the audit log can't
record it, the operation doesn't happen. You can never end up in a state
where an action ran but no record of it exists.

**Every tool call is user-visible.** The web frontend renders the
transcript directly — every message, every tool call, every skill load,
every permission prompt — with full fidelity: channel attribution,
timestamps, raw JSON inspection, collapsible structured views. Nothing
is summarized behind the scenes. When you branch from a point in the
conversation, you branch from the real record, not a reconstruction.

**Cross-channel mirroring.** Every user message is mirrored across all
subscribed channels (Telegram, Signal, web) with a `[channel]` prefix so
the origin is visible at a glance. Assistant replies fan out to every
channel. You always know who said what, from where, and when.

### Safety from the Ground Up

Security isn't a layer bolted on top. It's the foundation the rest is
built on, enforced at compile time by Haskell's type system and at
runtime by the ISA's trust model.

**Encrypted secrets vault.** API keys, bearer tokens, and encryption keys
don't live in plaintext config files or environment variables any shell
command can read. They live in an [age](https://age-encryption.org)-encrypted
vault with public-key cryptography and hardware token support (YubiKey,
NitroKey via `age-plugin-yubikey`). Three unlock modes: explicit unlock
at startup, automatic unlock on first access, or decrypt-from-disk on
every operation. Atomic writes (write to temp, chmod 0600, rename) — no
partial states. Rekey support re-encrypts the entire vault with a new key,
verified byte-for-byte before the old vault is replaced.

**Secret values are never logged.** Secret types are opaque — they have
no serialization path, so there is no code route that accidentally writes
a secret to the transcript, logs, or API response. Access is scoped to a
single function call, so a secret can't leak into a binding that persists
beyond the call. The audit log proves *that* a secret was accessed, never
*what* it was.

**Three trust levels, enforced by the type system.** Every opcode is
classified:

- **Untrusted** — interacts with the outside world (shell, files, web,
  browser). Runs in an isolated, disposable environment with no path to
  modify agent identity, memory, skills, or the audit trail.
- **Trusted** — harness-internal (sessions, scheduling, human
  interaction). In-process, logged in the session transcript.
- **Audited** — Trusted + writes to a unified cross-session append-only
  log. This log captures every mutation to the agent's persistent
  evolutionary state — memory, skills, agent definitions, configuration.
  It is append-only (the agent cannot delete or rewrite entries, only
  supersede them), hash-chained, and mirrored off-box. If an agent
  self-destructs, you replay the audited log forward to reconstruct state
  at any point in its lifetime.

**Compile-time security guarantees.**

| Security Property | How It's Enforced | What Fails at Compile Time |
|---|---|---|
| Command authorization | Authorization proof type required to execute a shell command | Executing a shell command without policy approval |
| Filesystem confinement | Validated path type (opaque, unexported constructor) | Accessing files outside the workspace |
| Secret protection | Opaque secret types, no serialization path, encrypted vault | Logging or serializing API keys, tokens, pairing codes |
| Policy evaluation | Pure functions, no IO | Security checks that depend on external state |
| Capability scoping | Capability handles — untrusted capabilities only available to untrusted opcodes | A Trusted opcode that shells out |
| Option injection | Validated argument types, `--` before user-derived args | Raw user input reaching a subprocess argv |

The insecure path is harder to write than the secure path. That's the point.

### Built for Concurrent Orchestration

Running multiple agents at once is the hard part — not the coding, the
*awareness*. A tmux TUI with a list of panes tells you *which* agent is
idle, but each agent is still an isolated conversation you tab into and
out of. Check from your phone? Let a teammate glance at the state? Watch
two agents at once? You're back to tabbing.

Seal Harness treats every agent session as a first-class, persistent
object — a **tab** — that multiple channels subscribe to simultaneously.
You don't tab *into* an agent; you *view* it with a channel.

- **The web frontend is the source of truth.** It renders the transcript
  directly with full fidelity — every message, tool call, skill load,
  and permission prompt, with channel attribution, timestamps, raw JSON
  inspection, and branching from any point. This is where you do deep
  work.
- **Append-only channels (Telegram, Signal) subscribe to the tab.** Each
  channel is a live view: it sees new messages and replies as they
  happen, without the full history the web frontend renders. One handle
  per channel kind, deduped so re-subscribing replaces the old handle,
  not the other channels.
- **Every user message is mirrored across channels.** A message from
  Telegram appears in Signal as `[telegram] what is your name?`; a
  message from the web appears in Telegram as `[web] fix the failing
  test`. The sender never receives its own message back.
- **Assistant replies go to all subscribers** — no tabbing required.

Start a conversation on Telegram from your phone, continue it from the
web UI at your desk, watch it unfold on Signal — all three stay in sync
because they're views into the same transcript. The state of every agent
(idle, thinking, waiting on a permission prompt) is visible from any
subscribed channel. No conversation is lost when a tmux session dies —
the transcript is on disk.

## The SealOp ISA

Every other agent framework has ad-hoc tool calls: `shell`, `read_file`,
`web_search`, whatever the developer thought of that week. No unifying
design. No privilege model. No atomicity guarantees.

Seal Harness defines a formal Instruction Set Architecture — a closed set
of opcodes where every instruction has:

- **Defined input/output JSON schema** — not "whatever JSON the LLM generates"
- **Trust classification** — Untrusted, Trusted, or Audited
- **Atomicity guarantee** — what state is left if the opcode fails mid-execution
- **Transcript entry format** — how the execution is recorded in the audit log
- **Authorization gate** — a pure `Value -> Either Text ()` check that must
  pass before execution

### The Wired Opcode Catalog

The registry currently exposes these opcodes to the model. Legacy
single-action opcodes (e.g. `MEMORY_WRITE`, `SKILL_LOAD`) still exist for
backward-compatibility transcript replay but are hidden from the model's
tool catalog, superseded by the consolidated `*_MANAGE` opcodes.

| Group | Visible Opcodes | Trust |
|---|---|---|
| **Memory** | `MEMORY_MANAGE` | Audited |
| **Skills** | `SKILL_MANAGE` | Audited |
| **Agent Defs** | `AGENT_DEF_MANAGE` | Audited |
| **Agent Runtime** | `AGENT_MANAGE` | Trusted |
| **Sessions** | `SESSION_MANAGE`, `SESSION_NEW` | Trusted |
| **Secrets** | `SECRET_MANAGE` | Audited |
| **Human Interaction** | `ASK_HUMAN`, `SHOW_HUMAN` | Trusted |
| **Harnesses** | `HARNESS_LIST`, `HARNESS_START`, `HARNESS_STOP` | Trusted |
| **Execution** | `SHELL_EXEC`, `BIN_EXEC`, `PROCESS_MANAGE`, `SETUP_REPO` | Untrusted |
| **Files** | `FILE_READ`, `FILE_WRITE`, `FILE_PATCH`, `SEARCH_FILES` | Untrusted |
| **Web** | `WEB_FETCH`, `WEB_SEARCH` | Untrusted |
| **Introspection** | `OPCODE_DESCRIBE`, `OPCODE_LIST` | Trusted |

Vault management (lock, unlock, rekey) is handled by the `seal vault` CLI —
admin operations that can require a physical hardware token, not something
the agent does autonomously. `SECRET_MANAGE` covers vault CRUD (get, put,
delete, list) with values never logged — only key names and operation
metadata are recorded. If the vault is locked when the agent calls
`SECRET_MANAGE`, it gets a "vault locked" error and can ask the human to
unlock it via `ASK_HUMAN`.

See the [ISA specification](docs/isa.md) for the complete opcode reference
with input/output schemas, atomicity guarantees, transcript entry
formats, and authorization gates.

### Dynamic Retrieval Pattern

Data retrieval opcodes (`FILE_READ`, `WEB_FETCH`, `SEARCH_FILES`,
`MEMORY_SEARCH`, `SESSION_SEARCH`) share a common design pattern:
**stat first, then adapt.** The opcode inspects the data source's
dimensions before returning content, then adapts how much to return using
a principled mathematical function — not hardcoded thresholds or the
model's guess.

Page size follows the **square root law**:
`page_size = min(total, max(floor, round(A · total^0.5)), ceiling)`.
Sublinear growth: a 10× larger file returns √10 ≈ 3.16× more content.
Coefficients are configurable at three layers: `config.yaml` (persistent),
per-session, and per-call.

## Quick Start

### Prerequisites

- **Nix** (recommended) — [install Nix](https://nixos.org/download) for
  fully reproducible builds
- **Or** GHC 9.12+ and Cabal — via [GHCup](https://www.haskell.org/ghcup/)
- An API key from your AI provider of choice (Anthropic or a local Ollama
  instance)

### Install and Run

You can either download a pre-built binary or build from source:

#### Download a pre-built binary (no Nix required)

Pre-built binaries are available on the
[Releases page](https://github.com/seal-harness/seal-harness/releases).

**Stable releases** (versioned, e.g. `v0.1.0`):

```bash
# Linux (x86_64)
curl -L https://github.com/seal-harness/seal-harness/releases/download/v0.1.0/seal-v0.1.0-seal-x86_64-linux.tar.gz | tar xz
chmod +x seal
./seal --help
```

**Bleeding edge** (rolling `latest` tag, rebuilt on every push to main):

```bash
# Linux (x86_64)
curl -L https://github.com/seal-harness/seal-harness/releases/download/latest/seal-x86_64-linux.tar.gz | tar xz
chmod +x seal
./seal --help
```

Verify download integrity with the SHA256 checksums provided alongside
each release asset.

#### Build from source

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

### Pick a Frontend

Seal Harness has four launch modes — pick the one that fits how you work:

```bash
seal tui       # interactive terminal UI (single channel, local)
seal serve     # web gateway + API: multi-tab, multi-channel, browser frontend
seal signal    # Signal channel (subscribe to tabs from your phone)
seal telegram  # Telegram channel
```

`seal serve` is the full setup: it launches the web gateway (React 18 + TS
+ Vite + Tailwind, embedded into the binary) with
multi-tab support, cross-channel mirroring, and the HTTP API. The
append-only channels (`seal signal`, `seal telegram`) subscribe to tabs
managed by a running `seal serve` instance.

### Start a Chat

From a running frontend, start a session with the `/new` command:

```
/new                              # fresh session in the current tab
/new -p anthropic -m claude       # Anthropic, explicit model
/new -p ollama -m llama3          # local Ollama, no API key needed
```

Provider credentials are read from the vault (set them with
`seal vault save`). Resume old sessions with `/session` and `/tab`.

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

**SIGPIPE pitfall:** never pipe Haskell binaries (`cabal`, `hlint`,
`ghcid`) through `head`/`tail`. The RTS sets `SIGPIPE` to `SIG_IGN`, so
the writer hangs in its exception handler instead of dying and the
command appears to hang forever. Redirect to a file, then page through
the file:

```bash
nix develop --command cabal test >test.log 2>&1; head -80 test.log
```

(`make`, `rg`, `git` are unaffected — they use the default SIGPIPE handler.)

**Frontend:** React 18 + TS + Vite + Tailwind, embedded into the binary,
so `frontend/dist` must exist when `cabal build` runs
(the Makefile gates this).

### Project Standards

- **GHC flags:** `-Wall -Werror` with strict warnings (incomplete
  patterns, name shadowing, unused imports)
- **TDD:** Red-green methodology — failing tests first, implementation
  second. Security-critical pure functions get property-based tests.
- **Linting:** hlint clean required before merge
- **CI:** GitHub Actions with Nix builds (Linux + macOS)

## Naming Philosophy

User-facing terminology uses **descriptive words**, not metaphors that
may be unfamiliar. A user should understand what an opcode does from its
name alone, without learning a domain-specific vocabulary first. Internal
implementation details and developer-facing API names may use specialized
terminology, but anything an end user or contributor encounters in
documentation, CLI output, or configuration should be plain and
self-explanatory.

## TODO Management

The project uses a [TODO.md](TODO.md) at the repo root as a navigation
layer — one file showing roadmap progress, active work, and known issues
by priority.

- [**todo-manager agent**](.agents/agents/todo-manager/agent.md) — Full
  sync: reconcile with GitHub Issues, update roadmap phases, generate
  standup reports.
- [**todo-md-maintenance skill**](.agents/skills/todo-md-maintenance/SKILL.md)
  — Lightweight edits: add an item, update a status, or check the list
  from any conversation context.

## License

**FSL-1.1-MIT** (Functional Source License) — source-available with a
"Competing Use" restriction. Each version converts to MIT license two
years after its release date. See [LICENSE](LICENSE) for details.