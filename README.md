<p align="center">
  <img src="assets/SealLogo.png" alt="Seal Harness logo — baby seal" width="200">
</p>

<p align="center">
  <strong>Seal Harness</strong><br>
  <em>safer AND more productive</em>
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

Most agent harnesses can't guarantee their own integrity. Actions happen off the record. You can't trust what you can't verify.

Agent frameworks are racing to hide what they do. Background steps you can't inspect. Tool calls summarized away. State changes with no record you can replay. Seal Harness goes the other way, fixing this at the architectural level. Not with policies to remember, but with structural guarantees enforced by the design of the system.

- Agents can't delete or tamper with their own logs, transcripts, or configs. This is the exact failure seen in the OpenAI/Hugging Face incident.
- Secrets are encrypted at rest, preventing the most common prompt injection attacks.
- Untrusted agent operations run in isolation.
- Start a conversation from your desktop, continue it from your phone. Same agent, same context, no handoff.
- Manage multiple agents simultaneously from any device. No tabbing through tmux panes.

---

## What Makes Seal Different

### Trust Every Agent Action

Security isn't a layer bolted on top. It's the foundation.

**Encrypted secrets vault.** API keys, bearer tokens, and encryption keys
don't live in plaintext config files or environment variables. They live in
an [age](https://age-encryption.org)-encrypted vault with public-key
cryptography and hardware token support (YubiKey, NitroKey). Three unlock
modes: explicit unlock at startup, automatic unlock on first access, or
decrypt-from-disk on every operation. Atomic writes — no partial states.
Rekey support re-encrypts the entire vault with a new key, verified
byte-for-byte before the old vault is replaced.

**Two trust levels, enforced by the system.** Every opcode is classified:

- **Untrusted** — interacts with the outside world (shell, files, web,
  browser). Runs in an isolated, disposable environment with no path to
  modify agent identity, memory, skills, or the audit trail.
- **Trusted** — harness-internal (sessions, scheduling, human
  interaction, state management). In-process, logged in the session
  transcript.

Seal Harness allows you to guarantee complete machine separation between
the untrusted and trusted environments. Untrusted operations can run on a
separate machine, so even full compromise of the execution environment
can't reach the control plane.

### Command Multiple Agents Effortlessly From Anywhere

Running multiple agents at once is the hard part — not the coding, the
*awareness*. A tmux TUI tells you *which* agent is idle, but each is still an
isolated conversation you tab into and out of. Check from your phone? Let a
teammate glance at the state? Watch two agents at once? You're back to
tabbing.

Seal Harness treats every agent session as a first-class, persistent object
— a **tab** — that multiple channels subscribe to simultaneously.

- **The web frontend is the source of truth.** It renders the transcript
  directly with full fidelity — every message, tool call, skill load, and
  permission prompt, with channel attribution, timestamps, raw JSON
  inspection, and branching from any point. This is where you do deep work.
- **Append-only channels (Telegram, Signal) subscribe to the tab.** Each
  channel is a live view: it sees new messages and replies as they happen.
  One handle per channel kind, deduped so re-subscribing replaces the old
  handle, not the other channels.
- **Every user message is mirrored across channels.** A message from
  Telegram appears in Signal as `[telegram] what is your name?`; a
  message from the web appears in Telegram as `[web] fix the failing
  test`.

Start a conversation on Telegram from your phone, continue it from the
web UI at your desk, watch it unfold on Signal — all three stay in sync
because they're views into the same transcript. The state of every agent
(idle, thinking, waiting on a permission prompt) is visible from any
subscribed channel. No conversation is lost when a tmux session dies —
the transcript is on disk.

### See Everything Your Agents Do

When an agent acts, you see everything. No hidden layers, no off-the-record
decisions.

**Every tool call is user-visible.** The web frontend renders the transcript
directly — every message, tool call, skill load, and permission prompt with
full fidelity: channel attribution, timestamps, raw JSON inspection,
collapsible structured views. Nothing is summarized behind the scenes. Branch
from any point and you branch from the real record.

**Cross-channel mirroring.** Every user message is mirrored across all
subscribed channels with a `[channel]` prefix. Assistant replies fan out to
every channel. You always know who said what, from where.

## The SealOp ISA

Every other agent framework has ad-hoc tool calls: `shell`, `read_file`,
`web_search`, whatever the developer thought of that week. No unifying
design. No privilege model. No atomicity guarantees.

Seal Harness defines a formal Instruction Set Architecture — a closed set
of opcodes where every instruction has:

- **Defined input/output JSON schema** — not "whatever JSON the LLM generates"
- **Trust classification** — Untrusted or Trusted
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
| **Memory** | `MEMORY_MANAGE` | Trusted |
| **Skills** | `SKILL_MANAGE` | Trusted |
| **Agent Defs** | `AGENT_DEF_MANAGE` | Trusted |
| **Agent Runtime** | `AGENT_MANAGE` | Trusted |
| **Sessions** | `SESSION_MANAGE`, `SESSION_NEW` | Trusted |
| **Secrets** | `SECRET_MANAGE` | Trusted |
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

## License

**FSL-1.1-MIT** (Functional Source License) — source-available with a
"Competing Use" restriction. Each version converts to MIT license two
years after its release date. See [LICENSE](LICENSE) for details.
