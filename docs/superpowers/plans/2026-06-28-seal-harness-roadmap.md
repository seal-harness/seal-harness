# Seal Harness — Implementation Roadmap

> **For agentic workers:** This is the master roadmap. Each phase links to (or
> will spawn) its own detailed, TDD, bite-sized plan under
> `docs/superpowers/plans/`. Implement phase-by-phase, top to bottom. Do not
> start a phase until the previous phase's milestone is green (build + tests +
> hlint clean in the Nix dev shell).

**Goal:** Build Seal Harness — a security-first AI agent runtime around the
SealOp Instruction Set Architecture (ISA) — as a clean-room reimplementation
of the functionality currently embodied by an existing internal agent runtime,
rebuilt on a stronger security spine.

**Architecture:** `ReaderT AppEnv IO` plus the capability-handle pattern
throughout (no effect systems). Every agent action is a typed ISA *opcode*
classified by trust level (Untrusted / Trusted / Audited). All execution is
recorded in an append-only, cryptographically hash-chained transcript that
serves as the audit log; the four evolutionary stores (memory, skills, agent
definitions, config) additionally write to a unified cross-session Audited log.

**Tech Stack:** GHC 9.12 (GHC2021), Cabal, Nix/haskell.nix, `aeson`, `text`,
`bytestring`, `containers`, `stm`, `async`, `typed-process`, `katip`,
`configuration-tools`, `optparse-applicative`, `crypton`, `sqlite-simple`,
`http-client`/`wai`/`warp`, `hspec` + `QuickCheck`. Vault encryption shells out
to the `age` binary (with `age-plugin-yubikey` for hardware tokens).

---

## Global Constraints

Every task in every phase implicitly inherits these. Copied verbatim where the
spec is exact.

- **Clean-room rule (CRITICAL).** This repository must be self-contained and
  must not reference, name, or mention any other repository or product it
  derives from — not in code, identifiers, comments, commit messages, or docs.
  Do **not** copy source verbatim. Reimplement functionality from a behavioral
  understanding, in this repo's own improved style. The only permitted source
  of truth in-repo is the README and these plans.
- **Module namespace:** all library code under `Seal.*`, matching the README
  architecture (`Seal.Core`, `Seal.Security`, `Seal.Handles`, `Seal.ISA`,
  `Seal.Tools`, `Seal.Agent`, `Seal.Providers`, `Seal.Channels`, `Seal.Memory`,
  `Seal.Gateway`, `Seal.Scheduler`, `Seal.CLI`, `Seal.Transcript`).
- **Coding style:** follow the repo's `haskell-coder` skill. Settled project
  conventions (established in Phase 1, Task 0): `default-language: GHC2021`;
  default extensions `OverloadedStrings, LambdaCase, DerivingStrategies,
  DeriveGeneric, GeneralizedNewtypeDeriving, ImportQualifiedPost,
  ScopedTypeVariables, TupleSections`; post-positive qualified imports
  (`import Data.ByteString qualified as BS`).
- **GHC flags:** `-Wall -Werror` with the strict set:
  `-Wincomplete-patterns -Wincomplete-uni-patterns -Wname-shadowing
  -Wunused-imports -Wredundant-constraints`. Warnings are errors; the build
  must stay green.
- **TDD:** red → green. Write the failing test first, watch it fail, implement
  the minimum, watch it pass, commit. Security-critical pure functions
  (policy, path validation, hash chaining) get QuickCheck properties.
- **hlint clean** required before each commit: `hlint src/ test/`.
- **No secret ever serialized.** Secret newtypes have redacted `Show`, no
  `ToJSON`/`FromJSON`, and are accessed only through CPS continuations. No code
  path may write a secret value to a transcript, log, audited log, or API
  response. This is enforced structurally, not by review.
- **Build/verify command:** everything runs under the Nix dev shell, e.g.
  `nix develop --command cabal build all`,
  `nix develop --command cabal test`,
  `nix develop --command hlint src/ test/`.
- **Commit cadence:** one commit per completed task (all steps green). End every
  commit message with the project's `Co-Authored-By` trailer.

---

## What is genuinely new vs. a remake

Understanding this split keeps the plan honest. The source runtime we are
remaking provides the *functionality*; the README upgrades the *security spine*.

**Remake (functionality exists in the reference, reimplement cleanly):**
the LLM provider abstraction, the channel abstraction (CLI/Telegram/Signal),
memory backends (SQLite/Markdown/None), the tool/opcode set (shell, files, web,
exec, edit, patch, memory, cron, etc.), the agent turn loop, sessions, the
gateway server, the scheduler, and the security primitives `SafePath`,
`AuthorizedCommand`, `SecurityPolicy`, pairing, and the crypto-backed vault.

**New design (does not exist in the reference — design carefully):**
1. **Trust-level taxonomy.** A first-class `TrustLevel = Untrusted | Trusted |
   Audited` attached to every opcode. The reference has only an autonomy
   level; it has no per-opcode trust classification.
2. **Cryptographic hash-chaining.** The reference links request/response by a
   shared UUID only. The README requires a real tamper-evident chain: each
   transcript entry stores the hash of the previous entry. New.
3. **ACK-before-execute.** Untrusted opcodes must block until the transcript
   daemon confirms the audit entry is durably written. New.
4. **Unified cross-session Audited log.** A single global, append-only,
   hash-chained log capturing every mutation to the four evolutionary stores
   (memory, skills, agent defs, config) across all concurrent sessions. New.
5. **Formal ISA.** Every opcode carries a typed input/output schema, a trust
   classification, an atomicity guarantee, a transcript-entry format, and an
   authorization gate — as data, not ad-hoc handler functions. New structure.
6. **Skills and Agent-definition stores** as first-class Audited opcode groups.

---

## Phase map and prioritization

The ordering follows the user's directive: **vault first** (security
foundation), then **the shortest path to a usable system**, then **build out
the ISA starting with the core Trusted opcodes**.

```
Phase 0  Scaffolding ........................... DONE (committed)
Phase 1  Security foundation + Secret Vault .... security from day one
Phase 2  Minimal usable agent (MVP) ............ usable end-to-end, fast
Phase 3  ISA build-out: core Trusted opcodes ... the highest-value feature
Phase 4  Untrusted opcode breadth + isolation .. shell/files/web at scale
Phase 5  Audited stores: Memory/Skills/Agents/Config
Phase 6  Channels, Gateway, Scheduler, MCP ..... reach + automation
```

Dependency rationale: Phase 1 establishes the secret types, crypto seam, and
project conventions everything else imports. Phase 2 stands up the transcript
spine (hash-chain + ACK), the ISA dispatcher skeleton, one provider, the CLI
channel, the agent loop, the Secrets opcodes (proving the vault end-to-end),
and exactly one Untrusted opcode (proving the ACK-before-execute path). Phase 3
then widens the ISA along the Trusted groups, which is where the architecture's
value compounds.

---

## Phase 0 — Scaffolding — DONE

Completed and committed (`Scaffold seal-harness from Haskell template`):

- Renamed package → `seal-harness`, executable → `seal`, namespace → `Seal.*`.
- `ReaderT Env (KatipContextT IO)` app monad, `configuration-tools` config,
  optparse subcommands, katip logging, IORef state — all from the template.
- FSL-1.1-MIT `LICENSE`, GitHub Actions CI (Nix build + HPC coverage),
  `flake.nix`/`cabal`/`CHANGELOG` updated.
- Placeholder `greet`/`tick` commands retained **only** as working scaffolding
  that keeps CI green. They are deleted in Phase 2 when the real CLI lands.
- Verified green: `cabal build all`, `cabal test`, `seal --help`.

---

## Phase 1 — Security foundation + Secret Vault

**Detailed plan:** `docs/superpowers/plans/2026-06-28-phase-1-secret-vault.md`

**Why first:** the README's thesis is "the insecure path is harder to write
than the secure path." That property has to exist before any feature can use
it. Phase 1 delivers the secret types, the crypto seam, and the vault so that
every later subsystem imports secrets and encryption that are already correct.

**Deliverables:**
- Task 0 — Project conventions: GHC2021, strict warnings, extension set,
  `Seal.Core.Errors` skeleton. (Folds setup into the first real module.)
- `Seal.Security.Secrets` — opaque `ApiKey`, `BearerToken`, `PairingCode`,
  `SecretKey`; redacted `Show`; no JSON; smart constructors; CPS accessors
  (`withApiKey`, …). Property test: `show` never reveals bytes.
- `Seal.Security.Crypto` — `getRandomBytes`, `sha256Hash`, `constantTimeEq`,
  `generateToken`, and symmetric `encrypt`/`decrypt` (`crypton`,
  AES-256-CTR, random IV prepended). Round-trip + tamper QuickCheck props.
- `Seal.Security.Vault.Age` — `VaultError`, the `AgeEncryptor` /
  `VaultEncryptor` handles that shell out to `age` (`typed-process`), a
  preflight `age --version` check, and mock encryptors for tests (no binary
  needed). `age-plugin-yubikey` works transparently via recipient/identity
  strings.
- `Seal.Security.Vault` — `VaultHandle` capability record with
  init/get/put/delete/list/lock/unlock/status/rekey; three `UnlockMode`s
  (startup, on-demand, per-access); atomic writes (tmp → chmod 0600 → rename);
  base64-in-JSON storage; verify-before-replace rekey. Concurrency-safe via
  `MVar` write lock + `TVar` cache.
- `Seal.Security.Path` — `SafePath` opaque type + `mkSafePath` (canonicalize,
  reject `..`, absolute escapes, blocked dotfiles, out-of-workspace symlinks).
  Pulled into Phase 1 because it is pure, security-critical, and Phase 2's
  Untrusted opcode needs it. QuickCheck: no input yields a path outside root.
- `Seal.Security.Command` + `Seal.Security.Policy` — pure `SecurityPolicy`,
  `AuthorizedCommand` proof type, `authorize`/`authorizeShell`. Pure ⇒ heavy
  QuickCheck coverage.

**Milestone:** a vault you can `init`/`unlock`/`put`/`get`/`list`/`rekey`
against a real `age` key in a throwaway integration test; secret types that
cannot be serialized or shown; pure policy/path validated by properties. No
agent yet — just a rock-solid security floor. hlint clean, `-Werror` green.

---

## Phase 2 — Minimal usable agent (MVP)

**Detailed plan:** to be written at the start of Phase 2
(`2026-07-xx-phase-2-mvp.md`).

**MVP bar (decided):** CLI chat against Anthropic, the working vault (Secrets
opcodes), `ASK_HUMAN`/`SHOW_HUMAN` so the loop is interactive, a hash-chained
transcript underneath, **plus one Untrusted opcode** (`FILE_READ`) exercising
the full ACK-before-execute path. Smallest thing that proves the whole
architecture end-to-end.

**Deliverables (task groups):**
1. **`Seal.Core.Types`** — `ProviderId`, `ModelId`, `ToolCallId`, `SessionId`
   (+ `isValidSessionId`), `MessageSource`/`ChannelKind`, `WorkspaceRoot`,
   `TrustLevel(Untrusted|Trusted|Audited)`, `AllowList`.
2. **Transcript spine** — `Seal.Transcript.Types` (entry with `prevHash`/
   `entryHash`), `Seal.Handles.Transcript` (append-only JSONL via raw POSIX
   FDs + fsync), and the **hash-chain**: `entryHash = sha256(prevHash ‖
   canonical(entry))`, with a `verifyChain` function. QuickCheck: any mutation
   to any entry breaks verification.
3. **Transcript daemon + ACK** — a writer thread; `recordAndAck` returns only
   after fsync. The dispatcher must call this before executing an Untrusted
   opcode.
4. **ISA skeleton** — `Seal.ISA.Opcode` (the `Opcode` record: name, trust
   level, input/output schema, authorization gate), `Seal.ISA.Registry`,
   `Seal.ISA.Dispatch` (`dispatch :: Registry -> OpName -> Value -> App
   Result`, enforcing ACK-before-execute for Untrusted).
5. **Provider abstraction + Anthropic** — `Seal.Providers.Class` (`Provider`
   class, `SomeProvider`, `CompletionRequest`/`Response`, `ContentBlock` with
   tool-use/tool-result), `Seal.Providers.Anthropic` (Messages API, reads key
   via `withApiKey` from the vault).
6. **CLI channel** — `Seal.Handles.Channel` + `Seal.Channels.CLI`
   (haskeline; `prompt`/`promptSecret`/streaming chunks).
7. **Agent loop** — `Seal.Agent.Env`, `Seal.Agent.Loop` (turn-based: message →
   completion → opcode dispatch → transcript → channel, until no tool calls).
8. **First opcodes** — `SHOW_HUMAN`, `ASK_HUMAN` (Trusted); the five Secrets
   opcodes (`SECRET_SAVE/GET/LIST/DELETE`, `VAULT_STATUS`, all Audited but
   values never logged); `FILE_READ` (Untrusted, via `SafePath` +
   ACK-before-execute).
9. **Real CLI** — replace `greet`/`tick` with `seal` chat + `vault`
   admin subcommands (`init`/`lock`/`unlock`/`rekey`), wired through
   `configuration-tools`.

**Milestone:** `export ANTHROPIC_API_KEY=…; seal` → chat with a model that can
save/read secrets, ask the human a question, and read a workspace file, with
every step landing in a verifiable hash-chained transcript and Untrusted reads
blocked until their audit entry is durably written.

---

## Phase 3 — ISA build-out: core Trusted opcodes (highest-value feature)

**Detailed plan:** to be written at the start of Phase 3.

**Why this is the highest-value feature:** the formal, classified instruction
set *is* the product. With the spine in place, the value compounds fastest by
widening the ISA along the Trusted groups — the harness-internal operations the
agent uses to manage itself and its work — each with a defined schema, trust
class, atomicity guarantee, transcript format, and authorization gate.

**Deliverables (task groups), Trusted unless noted:**
1. **Tools (Meta) group** — `TOOL_SEARCH`, `TOOL_DESCRIBE`, `TOOL_CALL`,
   `TOOL_LIST`. Self-describing ISA over the registry; the agent discovers and
   invokes opcodes dynamically. Establishes the *dynamic retrieval* pattern.
2. **Dynamic Retrieval pattern** — the shared "stat first, then adapt"
   page-sizing (`page_size = clamp(floor, round(A·total^0.5), ceiling)`),
   configurable at config/session/call layers. Retrofit `FILE_READ`; reuse
   everywhere a retrieval opcode returns bounded content.
3. **Sessions group** — `SESSION_NEW`, `SESSION_COMPACT`, `SESSION_SEARCH`.
4. **Human Interaction** — already seeded in Phase 2; finalize schemas.
5. **Scheduling group** — `CRON`, `HEARTBEAT_WAKEUP` (pure cron predicate +
   STM scheduler).
6. **Harnesses group** — `HARNESS_LIST/START/STOP`, `PLAN_MODE`.
7. **MCP group** — `MCP_LIST/CONNECT/DISCONNECT`.

**Milestone:** the agent can introspect and call the full Trusted instruction
set, manage sessions and schedules, and every Trusted execution is in the
session transcript with its declared schema.

---

## Phase 4 — Untrusted opcode breadth + isolation

**Deliverables:** `SHELL_EXEC`, `PROCESS_MANAGE`, `CODE_EXEC` (Execution);
`FILE_WRITE`, `SEARCH_FILES`, `FILE_PATCH` (Files); `WEB_SEARCH`,
`WEB_EXTRACT`, `BROWSER_*` (Web & Browser); `IMAGE_*`, `TEXT_TO_SPEECH`
(Media). All Untrusted: isolated/disposable execution environment, `SafePath`
confinement, `AuthorizedCommand` gating, ACK-before-execute. Network opcodes
redact auth headers via CPS and check allow-lists.

**Milestone:** the README's core pitch — agents with real shell, file, and web
access, every action sealed in the audit log.

---

## Phase 5 — Audited evolutionary stores

**Deliverables:** the unified cross-session Audited log (`Seal.Audited`),
hash-chained and mirrored off-box like the transcript; then the four Audited
opcode groups built on it — **Memory** (`MEMORY_STORE/RECALL/UPDATE/DELETE`,
SQLite/Markdown/None backends), **Skills** (`SKILL_LIST/READ/CREATE/UPDATE`),
**Agents** (`AGENT_DEF_*`, `AGENT_LIST/START/STATUS/STOP`), **Config**
(`CONFIG_VIEW/UPDATE`, `TARGET_SET`, `PROVIDER_LIST`). Secret values never
enter the Audited log — only key names and operation metadata.

**Milestone:** an agent that evolves (memory, skills, its own definition,
config) with every mutation in a global append-only log, so a self-destructing
agent is fully reconstructible by replay.

---

## Phase 6 — Channels, Gateway, Scheduler, breadth

**Deliverables:** Telegram and Signal channels (allow-lists, pairing via
`Seal.Security.Pairing`); the gateway HTTP server (`Seal.Gateway`) serving a
web channel + transcript streaming + pairing; remaining providers (OpenAI,
OpenRouter, Ollama); off-box transcript mirroring hardening.

**Milestone:** reach the agent from anywhere, multiple providers, durable
off-box audit — the full README feature set.

---

## Per-phase definition of done

A phase is done when, in the Nix dev shell: `cabal build all` is `-Werror`
clean, `cabal test` is green (including the new QuickCheck properties),
`hlint src/ test/` is clean, the phase milestone is demonstrable, and the work
is committed. Then write the next phase's detailed plan before starting it.
