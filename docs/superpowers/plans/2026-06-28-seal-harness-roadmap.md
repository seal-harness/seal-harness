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
recorded in an append-only transcript that serves as the audit log; integrity
is guaranteed by never executing untrusted actions on the machine that holds
the log, so the harness's own codebase is the trust boundary. The four
evolutionary stores (memory, skills, agent definitions, config) additionally
write to a unified cross-session Audited log.

**Tech Stack:** GHC 9.12 (GHC2021), Cabal, Nix/haskell.nix, `aeson`, `text`,
`bytestring`, `containers`, `stm`, `async`, `process`, `katip`,
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
  `Seal.Gateway`, `Seal.Scheduler`, `Seal.CLI`, `Seal.Transcript`,
  `Seal.Session`, `Seal.Harness`, `Seal.Tabs`, `Seal.Command`, `Seal.Routing`,
  `Seal.Ingest`).
- **Coding style:** follow the repo's `haskell-coder` skill. Settled project
  conventions (established in Phase 1, Task 0): `default-language: GHC2021`;
  a conservative always-on `default-extensions` set (`DeriveGeneric,
  DerivingStrategies, LambdaCase, ScopedTypeVariables`) with situational
  extensions (`OverloadedStrings`, `GeneralizedNewtypeDeriving`,
  `ImportQualifiedPost`, …) enabled per-file via `{-# LANGUAGE #-}` pragmas;
  whole-module imports rather than explicit symbol lists.
- **Errors:** default to `Either Text`/`ExceptT Text`. Introduce a bespoke
  error ADT only when the program pattern-matches the error to drive control
  flow (per the `haskell-coder` skill) — a typed error that is only shown to a
  user is over-engineering. Keep the matched-on constructors distinct and fold
  report-only failures into a single `Text`-carrying constructor.
- **GHC flags:** `-Wall -Werror` with the `haskell-coder` strict set:
  `-Wcompat -Widentities -Wincomplete-uni-patterns -Wincomplete-record-updates
  -Wname-shadowing -Wpartial-fields -Wredundant-constraints`. Warnings are
  errors; the build must stay green.
- **TDD:** red → green. Write the failing test first, watch it fail, implement
  the minimum, watch it pass, commit. Security-critical pure functions
  (policy, path validation) get QuickCheck properties.
- **hlint clean** required before each commit: `hlint src/ test/`.
- **No secret ever serialized.** Secret newtypes have redacted `Show`, no
  `ToJSON`/`FromJSON`, and are accessed only through CPS continuations. No code
  path may write a secret value to a transcript, log, audited log, or API
  response. This is enforced structurally, not by review.
- **No shell-wrapping in Trusted/Audited opcodes.** Trusted and Audited opcodes
  are **never** implemented by wrapping a shell and **never** run an arbitrary or
  agent-supplied command — no shell interpreter (`sh -c`), no constructed command
  strings. They use direct mechanisms only (native libraries, direct
  file/network handles, in-process data structures, SQLite via a binding, an STM
  scheduler, …). The capability to run a command lives **exclusively** in the
  Untrusted opcode path. Enforced by capability scoping: the `Shell` handle is
  wired only into Untrusted implementations, so a Trusted opcode that shells out
  fails to type-check. *Permitted as infrastructure (not opcode shell-wrapping):*
  fixed-argv invocation of a specific trusted binary with no shell interpreter
  and no agent-supplied command — `age` (vault crypto), `ssh` (untrusted
  transport), `tmux` (harness control).
- **Type-guaranteed subprocess arguments.** Every value derived from user/LLM
  input that reaches a subprocess argv must be carried by a validated,
  smart-constructed newtype — never raw `Text`/`String`. The exec/subprocess
  wrappers accept only these types in their signatures, so unsanitized input
  fails to compile. Extends the `SafePath`/`AuthorizedCommand`/`ContainerTarget`
  pattern (e.g. a `VaultKey` for the `age` seam) and the smart constructor must
  also defend against **option injection** (reject leading-dash values and/or
  always pass a leading `--` separator before user-derived arguments).
- **Build/verify command:** everything runs under the Nix dev shell, e.g.
  `nix develop --command cabal build all`,
  `nix develop --command cabal test`,
  `nix develop --command hlint src/ test/`.
- **Commit cadence:** one commit per completed task (all steps green).

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
2. **ACK-before-execute.** Untrusted opcodes must block until the transcript
   daemon confirms the audit entry is durably written. New.
3. **Unified cross-session Audited log.** A single global, append-only log
   capturing every mutation to the four evolutionary stores (memory, skills,
   agent defs, config) across all concurrent sessions. New.
4. **Formal ISA.** Every opcode carries a typed input/output schema, a trust
   classification, an atomicity guarantee, a transcript-entry format, and an
   authorization gate — as data, not ad-hoc handler functions. New structure.
5. **Skills and Agent-definition stores** as first-class Audited opcode groups.
6. **Channel-ingress preprocessing gate.** A single `ingest` chokepoint with an
   ordered preprocessing chain guaranteed (by construction of the one ingress
   pipeline) to run before any LLM call on every channel — the future home for
   prompt-injection / policy scanning that sees 100% of inbound traffic. The
   reference does slash-before-LLM by control-flow convention; this makes it a
   structural seam. See the slash-command infrastructure design.
7. **Discoverable `/`-command infrastructure.** Each command is channel-agnostic
   data with an optparse-applicative parser, so help/usage is auto-derived and a
   property test enforces that *every* command and option is discoverable via
   `/help`. The reference's `/`-command help is partly hand-written and ad-hoc.
   (The terse tab grammar is preserved exactly as a bespoke Layer-1 front-end.)

---

## Phase map and prioritization

> **2026-07-06 overhaul.** The original plan prioritized the web frontend as
> the MVP channel and deferred Signal to Phase 6. After landing Phases 1, 3
> (M1–M4 + the Tools-Meta re-slice), and 5 (audited stores, pivoted to git-backed
> Markdown) on the **CLI TUI channel**, the four remaining large features from
> the reference runtime are now sequenced as **Signal → Harness+Tabs → Web**.
> Rationale: Signal is the smallest end-to-end channel proof in the reference
> (~335 LOC) and forces the cross-channel foundation (`ChannelKind` /
> `MessageSource` / `ConversationId` / ingress-aware tab routing) to land
> *before* tabs or the web frontend need it. Harness+tabs then layer on top —
> tabs bind to harnesses *and* sessions, the terse `/N` grammar drives both,
> and both CLI and Signal benefit immediately. The web frontend is built last
> over the now-mature gateway+broker+tabs surface, rendering everything that
> already works textually. The CLI TUI channel (`Seal.Channel.Cli`) is kept as
> a secondary dev/debug surface — it is NOT unified into `ChannelKind` routing
> in this overhaul (it stays a direct haskeline REPL), but it does gain
> read-only access to the tab/harness registry for `/tabs` and `/tab`.

The ordering follows the user's directive: **vault first** (security
foundation, DONE), then **the shortest path to a usable system**, then **build
out the ISA starting with the core Trusted opcodes** (DONE for the Trusted
groups), then **the four large reference-runtime features** in the order
**Signal → Harness+Tabs → Web**.

```
Phase 0  Scaffolding ........................... DONE (committed)
Phase 1  Security foundation + Secret Vault .... DONE
Phase 2  Cross-channel foundation + Signal ..... the ingress gate, ChannelKind/
         2a  Core cross-channel types (MessageSource, ConversationId, ChannelKind)
         2b  Signal channel (signal-cli JSON-RPC transport, allow-list, chunking)
Phase 3  ISA build-out: core Trusted opcodes ... DONE (M1–M4 + Tools-Meta re-slice)
Phase 4  Untrusted opcode breadth + isolation .. shell/files/web at scale
Phase 5  Audited evolutionary stores ............ DONE (Memory/Skills/Agents, git-backed)
Phase 6  Harness + Tabs (text UI) ............... tmux-backed harness registry + tabs-as-view
         6a  Harness backend (tmux seam, durable UUID registry, reconcile loop)
         6b  Tabs-as-view (I1/I2/I3 invariants, /tab family, /N terse grammar, relay)
Phase 7  Web frontend (close duplication) ....... Warp/WAI gateway + WS broker + React/TS SPA
         7a  Gateway + WS broker + minimal chat shell
         7b  Full frontend close-duplication (sidebar, tabs, harness controls, branch)
Phase 8  More channels (Telegram → CLI unify), Scheduler, MCP, remaining providers
```

Dependency rationale: Phase 1 establishes the secret types, crypto seam, and
project conventions everything else imports (DONE). Phase 2 now stands up the
**cross-channel type foundation** the reference's channels share
(`ChannelKind`, `ConversationId`, `MessageSource`) and the **Signal channel**
as the first non-CLI ingress — proving the `Seal.Ingest` chokepoint works for
a second channel and forcing `MessageSource`/`ConversationId` to exist before
tabs or the web frontend need them. Phase 3 widened the ISA along the Trusted
groups (DONE). Phase 6 lands harnesses (tmux-backed, UUID-keyed, with a
reconcile loop) and the tabs-as-view layer (the pure `TabList` with I1/I2/I3
invariants, the `/tab` family, the terse `/N` routing grammar, and the
per-conversation relay) — both CLI and Signal gain `/tabs` and `/tab` driving.
Phase 7 builds the web frontend over the now-mature gateway+broker+tabs
surface, close-duplicating the reference's React/TS/Vite/Tailwind SPA. Phase 8
adds Telegram, unifies the CLI channel into `ChannelKind` routing if desired,
and the remaining breadth features.

**Channel priority (user-directed, 2026-07-06):** **Signal** first (forces the
cross-channel foundation), then **Harness+Tabs** (the text-based tab UI over
both CLI and Signal), then **Web** (the close-duplication frontend). The CLI
TUI channel stays as a secondary surface throughout.

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

## Phase 1 — Security foundation + Secret Vault — DONE

**Detailed plan:** `docs/superpowers/plans/2026-06-28-phase-1-secret-vault.md`

**Why first:** the README's thesis is "the insecure path is harder to write
than the secure path." That property has to exist before any feature can use
it. Phase 1 delivers the secret types, the crypto seam, and the vault so that
every later subsystem imports secrets and encryption that are already correct.

**Deliverables:**
- Task 0 — Project conventions: GHC2021, strict warnings, the conservative
  always-on extension set, and this phase's dependencies. No error module:
  errors default to `Either Text`; a bespoke error ADT appears only where
  control flow demands it (just `VaultError`).
- `Seal.Security.Secrets` — opaque `ApiKey`, `BearerToken`, `PairingCode`,
  `SecretKey`; redacted `Show`; no JSON; smart constructors; CPS accessors
  (`withApiKey`, …). Property test: `show` never reveals bytes.
- `Seal.Security.Crypto` — `getRandomBytes`, `sha256Hash`, `constantTimeEq`,
  `generateToken`, and symmetric `encrypt`/`decrypt` (`crypton`,
  AES-256-CTR, random IV prepended). Round-trip + tamper QuickCheck props.
- `Seal.Security.Vault.Age` — `VaultError`, the `AgeEncryptor` /
  `VaultEncryptor` handles that shell out to `age` (`process`), a
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

## Phase 2 — Cross-channel foundation + Signal channel

**Detailed plan:** to be written at the start of Phase 2
(`2026-07-xx-phase-2-cross-channel-signal.md`), split into **2a** (the core
cross-channel types) and **2b** (the Signal channel end-to-end). Two existing
designs feed it:
- `docs/superpowers/specs/2026-06-28-slash-command-infrastructure-design.md` —
  the `/`-command registry, optparse-derived discoverable help, the Layer-1
  terse tab-routing front-end, and the single channel-ingress preprocessing
  gate (preprocessing guaranteed before any LLM call, on every channel).
- a Signal-channel behavioral spec written at the start of the 2b work,
  derived from the reference's `Channels/Signal.hs` + `Signal/Transport.hs`
  (~335 LOC total: signal-cli JSON-RPC over stdio, allow-listed senders,
  chunked sends, conversation id derived from the peer).

**Why re-sequenced (2026-07-06):** the original Phase 2 was a large monolith
that landed the web frontend first and deferred Signal to Phase 6. After
shipping Phases 1/3/5 on the CLI TUI channel, the four remaining large
features are now sequenced **Signal → Harness+Tabs → Web**. Signal goes first
because it is the smallest end-to-end channel proof in the reference and it
forces the **cross-channel type foundation** (`ChannelKind`,
`ConversationId`, `MessageSource`) to land *before* tabs (Phase 6) or the web
frontend (Phase 7) need them. The CLI TUI channel (`Seal.Channel.Cli`) stays
as a secondary dev/debug surface — it is NOT unified into `ChannelKind`
routing in this phase, but the new types are designed so the CLI can adopt
them later (Phase 8) without churn.

**2a — Core cross-channel types (the foundation Tabs and Web both need).**
These are leaf-ish modules (depend only on `Seal.Core` / `Seal.Security`),
carry QuickCheck coverage for invariants and JSON round-trips, and settle the
shared vocabulary every later channel imports. They are the subset of the
original Phase-2 "core type foundations" groups 1, 5, and 6 — the *cross-channel*
parts — leaving sessions/transcripts/providers (which already landed ad-hoc
during Phases 3/5) to be backfilled only where the new types demand.

1. **`Seal.Core.ChannelKind`** — the channel enumeration:
   `Cli` | `Web` | `Signal` | `Telegram` | `Background` | `Other`. The
   `ConversationKey` (Phase 6) keys on `ChannelKind × ConversationId`. Pure
   `channelKindToText` for the transcript's `_te_metadata` channel field.
2. **`Seal.Core.MessageSource`** — `MessageSource` (the required
   `ConversationId`, the `ChannelKind`, an optional `UserId`, an open field
   map) constructed only via `mkMessageSource`, which strips control
   characters and bounds the length of every attacker-controlled string leaf.
   The `ConversationId` is a server-derived, transport-scoped conversation key,
   **always minted from authenticated transport metadata, never read from a
   message body**, so a sender cannot forge it to hijack another
   conversation's tab cursor. QuickCheck: `mkMessageSource` rejects over-long /
   control-char-laden inputs; round-trips.
3. **`Seal.Core.AllowList`** — the `AllowList` family
   (`AllowAll` | `AllowList (Set a)`) with `isAllowed` and `allowListWarning`,
   used here for sender allow-listing and later for opcode exposure gating.
   QuickCheck: the `AllowList` never admits an absent element.
4. **`Seal.Handles.Channel`** — the `ChannelCaps` capability record, widened
   from the current `Seal.Channel.Caps` to the reference's shape: `send` /
   `sendError` / `sendChunk` (streaming chunks) / `prompt` / `promptSecret` /
   `streaming` flag / `readSecret` / `receive`. Interactive ops on
   request/response channels (Signal, the future CLI channel) return a
   structured deferral; the web channel is async-only. The existing CLI
   `ChannelCaps` is kept as-is for Phase 2; the widened handle is the target
   the Signal channel (2b) and the web gateway (Phase 7) implement.
5. **`Seal.Channels.Class`** — the `Channel` type class (`toHandle ::
   Channel h => h -> ChannelHandle`) so a channel is wired by handing its
   handle to `Seal.Ingest`, mirroring the reference. The CLI TUI is *not*
   made an instance in this phase (it keeps its direct `interpretDisposition`
   path); Signal (2b) is the first instance.

**Milestone (2a):** the cross-channel types compile `-Werror` clean with their
invariant/round-trip QuickCheck properties green; `Seal.Handles.Channel` and
`Seal.Channels.Class` compile and are exercised by a no-op `FakeChannel`
instance in tests. No runtime behavior change yet — the CLI TUI still works
exactly as before.

**2b — The Signal channel end-to-end.** A clean-room reimplementation of the
reference's `Channels/Signal.hs` (220 LOC) + `Signal/Transport.hs` (115 LOC),
in this repo's security-first style. Behavior closely matches the reference;
no source is copied.

6. **`Seal.Channels.Signal.Transport`** — the testability seam over
   signal-cli: a `SignalTransport` record (`_st_receive :: IO Value`,
   `_st_send :: Text -> Text -> IO ()`, `_st_close :: IO ()`). The real
   implementation spawns `signal-cli --output=json --trust-new-identities=always
   -u <account> jsonRpc` as a child process via `typed-process` and communicates
   over JSON-RPC on stdio (line-buffered). A mock implementation
   (`mkMockSignalTransport`) backs the unit tests. Includes
   `chunkMessage :: Int -> Text -> [Text]` — split on paragraph (`\n\n`) then
   line boundaries, hard-cut as a last resort, mirroring the reference.
7. **`Seal.Channels.Signal`** — the `SignalChannel` (config + inbox
   `TQueue SignalEnvelope` + transport + `IORef` last-sender) and its
   `Channel` instance. The reader thread parses signal-cli output, allow-lists
   the sender (checking both phone number and UUID against the `AllowList
   UserId`), and pushes envelopes to the inbox. Send chunks via the transport.
   `parseSignalEnvelope` handles both raw envelopes and JSON-RPC-wrapped
   `params.envelope` messages. `conversationIdForSignal` derives the
   `ConversationId` from the peer source (server-derived, never from message
   body). `withSignalChannel` runs the reader thread with cleanup.
8. **Wiring + config** — `[signal]` config section (`account`,
   `text_chunk_limit`, `allow_from`), `seal signal` startup subcommand (spawns
   the Signal channel + runs the agent loop against it, parallel to the
   existing `seal tui`). The vault supplies the signal-cli account's pairing
   secrets via `withApiKey`-style CPS accessors (no secret in the transcript).
9. **First cross-channel ingress test** — a `Seal.Phase2Spec` capstone: drive
   a `FakeChannel` and a mock `SignalTransport` through `Seal.Ingest.ingest`,
   assert the `MessageSource` carries the right `ChannelKind`/`ConversationId`,
   a slash command dispatches, and a plain message routes to the agent loop
   with the `ConversationId` threaded into the transcript's `_te_metadata`.
   This is the proof that the ingress gate works for a second channel and that
   `MessageSource` is correctly threaded end-to-end.

**Milestone (2b):** `seal signal` (Nix dev shell, with a real or mock
signal-cli) receives a message from an allow-listed sender, routes it through
`Seal.Ingest` to the agent loop, dispatches any `/`-command via the registry,
threads the `ChannelKind`/`ConversationId` into the transcript, and sends the
agent's reply back via signal-cli (chunked to the configured limit). A
message from a non-allow-listed sender is logged and dropped. The existing
`seal tui` CLI channel is unaffected. hlint clean, `-Werror` green, the
capstone spec passes.

---

## Phase 3 — ISA build-out: core Trusted opcodes — DONE

**Detailed plan:** written per-milestone at the start of each. The
multi-provider-sessions work (M1–M3, merged) was inserted ahead of this original
Trusted-ISA build-out; the ISA build-out resumes here, sliced into user-testable
milestones.

> **Re-slice + `TOOL_CALL` drop (2026-07-03).** Deliverables 1 and 2 below are
> split and re-sequenced. **M-a** ships the Dynamic Retrieval pattern
> (deliverable 2) *first* — a generic page sizer, a reusable line-oriented
> text-file abstraction (for later agent-def/skills/file CRUD), and a paged
> `FILE_READ` — because the Meta ops depend on the pager and have no live consumer
> until tool-exposure gating exists. **M-b** then ships the Tools (Meta) group
> (deliverable 1) as discovery-only ops (`TOOL_LIST`/`TOOL_SEARCH`/`TOOL_DESCRIBE`)
> plus the configurable exposure gating. **`TOOL_CALL` is dropped:** its only role
> was invoking a tool absent from the native list; gating instead gates
> *discovery* and injects a discovered opcode's real `ToolDefinition` into the
> native tool list, so the model always calls tools directly. Design:
> `docs/superpowers/specs/2026-07-03-dynamic-retrieval-linefile-design.md`.

**Why this is the highest-value feature:** the formal, classified instruction
set *is* the product. With the spine in place, the value compounds fastest by
widening the ISA along the Trusted groups — the harness-internal operations the
agent uses to manage itself and its work — each with a defined schema, trust
class, atomicity guarantee, transcript format, and authorization gate.

**Deliverables (task groups), Trusted unless noted:**
1. **Tools (Meta) group** — `TOOL_SEARCH`, `TOOL_DESCRIBE`, `TOOL_LIST`
   (`TOOL_CALL` dropped — see the 2026-07-03 note above). Self-describing ISA
   over the registry; the agent discovers opcodes and, under exposure gating,
   activates them into the native tool list to call directly. Ships as M-b atop
   the M-a *dynamic retrieval* pattern.
2. **Dynamic Retrieval pattern** — the shared "stat first, then adapt"
   page-sizing (`page_size = clamp(floor, round(A·total^0.5), ceiling)`),
   configurable at config/session/call layers. Retrofit `FILE_READ`; reuse
   everywhere a retrieval opcode returns bounded content.
3. **Sessions group** — `SESSION_NEW`, `SESSION_COMPACT`, `SESSION_SEARCH`
   (session *types* seeded in Phase 2; this group adds the opcodes and the
   on-disk session store).
4. **Human Interaction** — already seeded in Phase 2; finalize schemas.
5. **Scheduling group** — `CRON`, `HEARTBEAT_WAKEUP` (pure cron predicate +
   STM scheduler).
6. **Harnesses group** — `HARNESS_LIST/START/STOP`, `PLAN_MODE`, and the tab
   view layer (harness/tab *types* and pure ops seeded in Phase 2; this group
   adds the live lifecycle — process spawn, the reconcile loop, and output
   routing through tabs/cursors).
7. **MCP group** — `MCP_LIST/CONNECT/DISCONNECT`.

**Status (2026-07-06):** M1–M4 merged (provider commands, sessions model,
Ollama provider, default-model binding, spine commands). The Tools-Meta
re-slice (M-a/M-b) and the Sessions Phase-3 group are **deferred** — see the
Phase 5 handoff (`docs/handoffs/handoff-2026-07-05-1900.md` §10). Do not pick
up without asking. The Harnesses group and the tab view layer move to
**Phase 6** of this overhaul (the harness+tabs feature).

**Milestone (reached for the merged M1–M4):** the agent can introspect and
call the merged Trusted instruction set, and every Trusted execution is in
the session transcript with its declared schema. The remaining Trusted
groups (Harnesses group, full Sessions group, Scheduling, MCP) land in
later phases per the new sequencing.

---

## Phase 4 — Untrusted opcode breadth + isolation

**Deliverables:** the `TerminalBackend` family — the typed selector for *where*
a tool call runs (`Local`/`Tmux`/`Ssh`/`Container`, with `TmuxConfig`/
`SshConfig`/`ContainerSpec`+validated `ContainerTarget`) — which is the
tool-call-execution counterpart to the tmux-only harness backend fixed in
Phase 6; then the opcodes themselves: `SHELL_EXEC`, `PROCESS_MANAGE`,
`CODE_EXEC` (Execution); `FILE_WRITE`, `SEARCH_FILES`, `FILE_PATCH` (Files);
`WEB_SEARCH`, `WEB_EXTRACT`, `BROWSER_*` (Web & Browser); `IMAGE_*`,
`TEXT_TO_SPEECH` (Media). All Untrusted: isolated/disposable execution
environment, `SafePath` confinement, `AuthorizedCommand` gating,
ACK-before-execute. Network opcodes redact auth headers via CPS and check
allow-lists.

**Remote-only untrusted execution (control plane / untrusted plane split).**
**Full design:**
`docs/superpowers/specs/2026-06-28-remote-only-untrusted-execution-design.md`.
A configurable, optionally compile-time-enforced guarantee that **no untrusted
opcode ever executes on the harness machine** — all untrusted execution runs on
a separate machine over SSH, leaving the control plane holding only the agent
loop, transcript, vault, and Trusted/Audited opcodes. Deliverables:
- **Executor split** — `Seal.Tools.Exec.Local` (untrusted local executor) vs
  `Seal.Tools.Exec.Remote` (SSH executor), behind the Phase-2 backend dispatch
  seam.
- **`UntrustedExecBackend`** — smart-constructed so it can be built *only* from
  an `Ssh` backend (a local container/VM shares the harness kernel and does
  **not** count as remote). Pure `selectUntrustedBackend`; QuickCheck: untrusted
  ⇒ `Ssh`-or-failure, never `Local`.
- **Runtime layer** — `untrusted_execution = local | remote` config, fail-closed
  when `remote` (no local fallback ever); boot succeeds even with no/unreachable
  remote, untrusted ops fail closed at call time.
- **Compile-time layer** — Cabal flag `remote-only-untrusted` that omits
  `Seal.Tools.Exec.Local` from the build entirely (the local untrusted-exec
  capability is absent from the binary; `mode=local` rejected at startup). CI
  builds and asserts the local executor is absent under the flag.
- **SSH transport** — shells out to `ssh` via fixed argv with **mandatory
  host-key pinning** (`StrictHostKeyChecking`, pinned `known_hosts`); a host-key
  mismatch is a hard failure. Remote workspace root anchors `SafePath`.

**Milestone:** the README's core pitch — agents with real shell, file, and web
access, every action sealed in the audit log; plus a deployment mode (runtime or
hardened-build) in which untrusted execution is provably confined to a remote
machine and the control plane runs no agent-driven commands.

---

## Phase 5 — Audited evolutionary stores — DONE

**Detailed plan:** `docs/superpowers/plans/2026-07-05-phase-5-audited-stores.md`
(partially superseded by the pivot — see the handoff).

**Deliverables:** the four evolutionary stores — **Memory** (`MEMORY_STORE/
RECALL/UPDATE/DELETE`), **Skills** (`SKILL_LIST/READ/CREATE/UPDATE`), **Agents**
(`AGENT_DEF_*`, `AGENT_LIST/START/STATUS/STOP`), **Config** — built as ISA
opcode groups over disk-backed Markdown files. Secret values never enter the
transcript or the git history — only key names and operation metadata.

**Status (2026-07-06):** DONE and verified. The original Audited-log design
was **pivoted** mid-phase to a git-backed Markdown design: `~/.seal/config/`
is a git repo; skills/agents/memory are Markdown files (frontmatter + body);
disk is canonical and git is the versioning + audit layer; model-authored
writes auto-commit. The `Audited` `TrustLevel` constructor is kept (treated as
`Trusted` in the dispatcher) to avoid a cascading test/roadmap change. See
`docs/handoffs/handoff-2026-07-05-1900.md` for the full state, the pivot
rationale, and the capstone `Seal.Phase5Spec`.

**Milestone (reached):** an agent that evolves (memory, skills, its own
definition) with every mutation landing as a Markdown file under `config/`
and auto-committed to git, so a self-destructing agent is fully reconstructible
by reading the disk + replaying the git history. hlint clean, `-Werror`
green, 596 examples / 0 failures / 6 pending.

---

## Phase 6 — Harness + Tabs (text-based tab UI)

**Detailed plan:** to be written at the start of Phase 6
(`2026-07-xx-phase-6-harness-tabs.md`), split into **6a** (harness backend +
tmux registry) and **6b** (tabs-as-view + the `/tab` family + the terse `/N`
grammar + per-conversation relay). A behavioral spec for the tab text UI is
written at the start of 6b, derived from the reference's `Tabs/Types.hs`
(396 LOC), `Tabs/Wiring.hs` (755), `Tabs/Relay.hs` (233), `Tabs/Wizard.hs`
(230), `Harness/Tmux.hs` (849), and `Harness/Registry.hs` (258).

**Why this phase:** the reference's central interaction model is "tabs as a
view over ground truth" — a tab binds to a live session *or* a harness, the
terse `/N` grammar switches focus, and per-conversation relay routes output.
This is the text-based tab UI the user wants, and it works over **both** the
CLI TUI and the Signal channel (Phase 2). The web frontend (Phase 7) then
renders the same tab model graphically. Harnesses are external CLI tools
(Claude Code, Codex, …) that can only be driven reliably inside a tmux
session, so the harness backend is tmux-only by construction.

**6a — Harness backend (tmux seam + durable registry + reconcile loop).**
A clean-room reimplementation of the reference's `Harness/Tmux.hs` +
`Harness/Registry.hs` + `Harness/Reconcile.hs` + `Harness/Observer.hs` +
`Harness/Discovery.hs` + `Harness/ClaudeCode.hs`, in this repo's
security-first style. Behavior closely matches the reference; no source is
copied.

1. **`Seal.Harness.Id`** — `HarnessId`, a UUID-backed durable identity (the
   registry key), keyed on identity rather than a mutable terminal label.
   `newHarnessId`, `parseHarnessId`, `harnessIdToText`.
2. **`Seal.Handles.Harness`** — `HarnessHandle`, the capability record of
   `IO` actions (send/receive/snapshot/status/stop); `HarnessStatus`,
   `HarnessError`, a no-op handle for tests, and the output prefix/sanitize
   helpers (strip ANSI/control/decorative bytes).
3. **`Seal.Harness.Registry`** — `HarnessEntry` (identity + reconciled
   coordinate/health cache), `HarnessOrigin` (`Spawned`/`Discovered`/
   `Adopted`), `Liveness` (`Idle`/`Thinking`/`AwaitingInput`/`Exited`/
   `Orphaned`), the `STM`-backed `HarnessRegistry` with race-safe CRUD
   (`insert`/`lookupById`/`lookupByLabel`/`modify`/`delete`/`snapshot`), and
   `mergeReconcile` (`ObservedHarness` → entries, merged **by key inside one
   transaction** so concurrent inserts are never clobbered — the lost-update-
   safe path). QuickCheck on the merge invariants.
4. **`Seal.Harness.Tmux`** — the sole chokepoint for tmux subprocesses. Every
   tmux invocation builds its `typed-process` `ProcessConfig` from an
   `AuthorizedCommand` obtained via `authorizeTmuxCommand` (the manager-owned
   tmux seam, §8 B1 — `Seal.Security.Command` already exists). Pure argv
   builders (unit-testable): `sendKeysNamedArgs` (with `-l --` for literal
   text + a separate `sendEnterNamedArgs` to prevent key-token injection),
   `pasteBufferNamedArgs`, `captureNamedArgs`, `killWindowNamedArgs`,
   `renameWindowNamedArgs`, `newWindowNamedArgs`, `setWindowMarkerArgs`,
   `clearWindowMarkerArgs`, `setRemainOnExitArgs`. IO wrappers:
   `startTmuxSessionStatus`, `addHarnessWindowNamed`, `sendToWindowNamed`,
   `captureWindowNamed`, `stopHarnessWindowNamed`, `renameWindowNamed`,
   `readMarkers`, `setWindowMarker`, `clearWindowMarker`, `setRemainOnExit`.
   `validateTmuxIdent` (defense-in-depth: reject leading-dash, empty, control
   chars, `:`). `stealthShellCommand` (macOS/Linux `script(1)` wrap for a
   fresh PTY). `checkTmuxCapabilities` (probe `@seal_id` + `pane_dead`).
   `stripAnsi` (pure). `selectHarnessPid`/`parsePsRows`/`harnessPidOf` (PID
   provenance via `ps`, BFS over the process tree, cycle-safe).
5. **`Seal.Session.Kind`** — `SessionKind` (`SkProvider ProviderSpec` |
   `SkHarness HarnessSpec`); `HarnessSpec` carries its `TmuxConfig`
   coordinates directly (flavour, tmux session, cwd, args, optional durable
   ids) rather than a general backend; `HarnessFlavour` (known tools + a
   smart-constructed `HCustom` that rejects path separators);
   `inferProviderId` (model-prefix → provider).
   - **Harness backend vs. tool-call backend — keep these separate.** A
     *harness* backend has exactly one viable form — tmux — so `HarnessSpec`
     hard-codes `TmuxConfig`. A *tool-call execution* backend — where
     Untrusted opcodes and raw-shell tabs run — is genuinely plural and is
     modelled by the `TerminalBackend` family in **Phase 4**, not here.
6. **`Seal.Harness.Reconcile` + `Seal.Harness.Observer`** — the background
   reconcile loop: a server sweep (`readMarkers`) per session, classified
   by a per-flavour observer (Claude Code screen-capture heuristic) into
   `Liveness`, merged into the registry via `mergeReconcile`. The
   `defaultOrphanGraceTicks` wall-clock-free grace policy auto-evicts an
   entry after N consecutive Orphaned ticks (never touches `session.json`).
   `livenessToActivity` for the activity-stream the frontend consumes.
7. **`Seal.Harness.Discovery`** — `DiscoverableWindow` + `scanDiscoverableIO`
   (on-demand scan for unmanaged tmux windows that could be adopted).
   `Seal.Security.Adoption` — `AdoptedHarness`, `ConsentChannel`,
   `authorizeAdoption`, `AdoptError` (an adopted window requires
   consent_confirmed; a headless run cannot confirm, so adoption fail-closes).

**Milestone (6a):** `seal harness start claude-code` (Nix dev shell, with
tmux installed) spawns Claude Code in a tmux window, stamps a `@seal_id`
marker, registers a `HarnessEntry` (OriginSpawned), the reconcile loop
classifies its liveness (Idle/Thinking/AwaitingInput), and `seal harness list`
shows it. Stopping it marks the entry Exited; killing the tmux window
orphanages it and the grace policy evicts it. A discovered external window
can be adopted (with consent). hlint clean, `-Werror` green, the registry
QuickCheck properties pass.

**6b — Tabs-as-view (the text-based tab UI).** A clean-room reimplementation
of the reference's `Tabs/Types.hs` + `Tabs/Wiring.hs` + `Tabs/Relay.hs` +
`Tabs/Wizard.hs` + `Tabs/Exec.hs` + `Tabs/Persist.hs` + `Tabs/Runtimes.hs`,
in this repo's style. Behavior closely matches the reference; no source is
copied.

8. **`Seal.Handles.Tab`** — the validated `TabIndex` (`0..35`, `mkTabIndex`),
   the single index type reused everywhere. `TabKind` (`KindAi` |
   `KindProvider` | `KindHarness` | `KindShell` | `KindSsh` | `KindTmux`).
9. **`Seal.Tabs.Types`** — `TabRef` (`BoundSession SessionId` |
   `BoundHarness HarnessId`), `TabStatus` (`Live` | `Dead`), `Tab`, and the
   `TabList` enforcing **I1** (contiguous slots `0..n-1`; removal compacts,
   tmux-window style) and **I2** (no two tabs share a `TabRef`) by
   construction, with a hard 36-slot cap; plus per-conversation routing —
   `ConversationKey` (`ChannelKind` × `ConversationId`), `RelayMode`
   (`FocusedOnly` | `ActivityDigest` | `Firehose`), and `CursorState` whose
   cursors key by `TabRef` not slot (**I3**: a cursor survives slot
   compaction because it names ground truth, resolved to a current slot at
   read time). The parsed `/tab` command ADTs: `TabKindArg`, `ForceMode`,
   `TabSlashCommand` (`TabNewCmd` | `TabListCmd` | `TabCloseCmd` |
   `TabFocusCmd` | `TabResumeCmd` | `TabRenameCmd`). Heavy QuickCheck on the
   I1/I2/I3 invariants.
10. **`Seal.Routing.Route`** — the Layer-1 terse-grammar routing front-end:
    `route :: Text -> Either ParseError RoutingDecision` where
    `RoutingDecision` is `Focus TabIndex` | `Inject TabIndex Text` |
    `Plain Text` | `TabCommand TabSlashCommand` | `SlashCommand …`. `/N`
    switches focus to tab N, `/N payload` injects into tab N, a bare `/tab …`
    parses to the `TabSlashCommand` family, anything else is plain text to
    the focused tab. The grammar is a first-class synopsis entry in the
    `/help` registry so it is discoverable through the same `/help`.
11. **`Seal.Tabs` (the registry) + `Seal.Tabs.Relay` + `Seal.Tabs.Wizard`**
    — the thin `IORef`/`TVar` handle that mutates a `TabList`; the
    streaming-aware per-conversation output relay (`relayEvent`: focused
    conversations receive every `StreamStart`/`ChunkOf`/`StreamEnd`
    verbatim, background `ActivityDigest` conversations get at most one
    breadcrumb ping per burst, `Firehose` forwards everything); and the
    `/tab` attach-wizard state machine (snapshot the running harnesses +
    recent sessions, number them `[1-9a-z]`, `0` cancels, a `/`-prefixed
    reply cancels and runs that command instead).
12. **`Seal.Tabs.Persist` + `Seal.Tabs.Runtimes`** — tab list persistence
    (the `TabList` survives a restart; tabs are re-resolved to their
    `TabRef`s at boot) and the per-tab runtime wiring (a session tab runs
    the agent loop, a harness tab drives the harness handle).
13. **First registered commands** — the tab family registered into the
    existing `/`-command registry: `/tabs` (alias `/tab list`), `/tab new
    [<kind>]`, `/tab close <N> [--force]`, `/tab focus <N>`, `/tab resume
    <session-id>`, `/tab rename <N> <name>`, plus the terse `/N` routing
    (a synopsis entry, so `/help` shows it). Proving the registry
    end-to-end with the real tab entries. Both the CLI TUI and the Signal
    channel gain `/tabs` and `/tab` driving.
14. **`Seal.Phase6Spec` capstone** — drive a `FakeChannel` (CLI or Signal)
    through `Seal.Ingest`: `/tab new` creates a tab at the lowest free slot,
    `/1` switches focus, `/1 hello` injects into tab 1, `/tab close 0`
    compacts the list (I1), `/tab new` reuses slot 0, a second `/tab new`
    binding the same session is rejected (I2), a cursor survives a
    `removeSlot` compaction (I3). A harness tab's output relays to the
    focused conversation verbatim and to a background conversation as one
    breadcrumb per burst.

**Milestone (6b):** over **both** the CLI TUI and the Signal channel, the
user can `/tab new`, `/N` switch, `/N payload` inject, `/tab close`, `/tab
resume`, `/tab rename`, and `/tabs` list — with the I1/I2/I3 invariants
preserved by construction, a cursor surviving slot compaction, and a
harness tab's output relaying to the focused conversation verbatim and to
background conversations per the configured `RelayMode`. The tab terse
grammar is discoverable via `/help`. hlint clean, `-Werror` green, the
capstone passes.

---

## Phase 7 — Web frontend (close duplication)

**Detailed plan:** to be written at the start of Phase 7
(`2026-07-xx-phase-7-web-frontend.md`), split into **7a** (gateway + WS
broker + minimal chat shell) and **7b** (full frontend close-duplication).
A behavioral spec for the frontend is written at the start of 7a, derived
from the reference's `Frontend/Server.hs` (279 LOC), `Frontend/API.hs`
(2459), `Frontend/Stream.hs` (767), `Frontend/StreamBroker.hs` (327),
`Frontend/TabsView.hs` (193), and the 10-component React 18 + TypeScript +
Vite + Tailwind SPA under `frontend/src/`.

**Why this phase:** the web frontend is the close duplication of the
reference's UI. It is built **last** so it renders an architecture that
already works textually over CLI and Signal — the gateway + WS broker expose
the existing tab/harness/session surface, and the React SPA is a graphical
view over the same ground truth. Behavior and appearance closely match the
reference; no source is copied.

**7a — Gateway + WS broker + minimal chat shell.**

1. **`Seal.Gateway.Server`** — a Warp/WAI HTTP server bound to loopback by
   default (`127.0.0.1:8080`), with a non-loopback bind warning (the full
   slash-command surface — including local code execution — is reachable
   by anything that can reach the address). `FrontendConfig` (port, bind
   host, static dir, allowed origins). CORS middleware (echo an allowed
   `Origin` header, handle OPTIONS preflight). Static file serving with SPA
   fallback. An accept-side connection counter caps concurrent HTTP
   connections at 1024; `setTimeout 30` on non-WS routes.
2. **`Seal.Gateway.Stream`** — the WS endpoint at `/api/stream`. Every WS
   upgrade is gated by an exact-match Origin allowlist, a per-origin
   subscriber cap (`StreamGuard`), and the broker's global cap. Inbound
   frames are bounded at 4 KB; malformed JSON returns an in-band error
   without closing the connection. `withPingThread` keepalive (Warp's idle
   timeout does NOT apply to hijacked sockets). Wire protocol: on upgrade,
   a one-shot `hello`; then a reader/writer race forwards `BrokerEvent`s
   from the broker to the WS peer while accepting `focus` ops from the
   client. A `focus` op carrying `since` enters replay mode
   (file slice + UUID-deduped buffered set; falls back to `replay-failed`
   so the client can refetch via HTTP).
3. **`Seal.Gateway.StreamBroker`** — the in-process broker that fans
   `EntryRecorded` / `SaHarnessStatus` / `ListsSnapshot` events to every
   subscribed WS connection, filtering by each connection's focused session.
   `SessionActivity` (the per-session thinking/idle state the frontend
   consumes). `broadcastLists` pushes a refreshed tab/session snapshot to
   every connection.
4. **`Seal.Gateway.API`** — the REST surface the SPA calls:
   - `GET  /api/sessions/:id/transcript` — the on-disk transcript slice.
   - `POST /api/sessions/:id/send` — send a message; returns
     `{ kind: "assistant" | "slash", response? }`.
   - `GET  /api/sessions` / `GET  /api/sessions/archived` — recent + archived.
   - `PUT  /api/sessions/:id/description` / `PUT /api/sessions/:id/archived` /
     `PUT /api/sessions/:id/prompt`.
   - `GET  /api/tabs` — the `TabSnapshot` (liveness → tab status, origin →
     pill, attach command).
   - `POST /api/tabs/new` — create a tab (provider/harness/branch/attach).
   - `POST /api/tabs/:index/close` / `dismiss` / `acknowledge` / `release` /
     `destroy`.
   - `GET  /api/agents` / `GET /api/providers` — agent defs + providers.
   - `GET  /api/harnesses/discover` — discoverable tmux windows.
5. **Minimal chat shell (frontend)** — a deliberately minimal React 18 +
   TypeScript + Vite + Tailwind client: chat/transcript view, live WS
   streaming (seed HTTP GET + WS tail, deduped by entry id, sorted by
   timestamp), `/help`, and tab driving via the terse grammar. Enough to
   close the end-to-end loop over the web channel. The full UI lands in 7b.

**Milestone (7a):** `seal serve` (Nix dev shell, with `frontend/dist` built)
opens the web UI on `http://localhost:8080`; the user can chat with a model,
see the transcript stream live over WS, run `/help`, and drive tabs via the
terse grammar — every inbound message passing the ingress preprocessing
chain, every step landing in the append-only transcript. hlint clean,
`-Werror` green, the gateway + broker specs pass.

**7b — Full frontend close-duplication.** The bulk of the SPA, a
clean-room reimplementation of the reference's 10 components + 5 hooks +
types + lib. Behavior and appearance close-match the reference; no source is
copied.

6. **`Sidebar`** — active tabs (`ActiveTabs`), running harnesses
   (`RunningHarnesses`), recent sessions, archived sessions; per-session
   activity dots, unread counts, age pills; archive/unarchive buttons.
7. **`ChatArea`** — transcript → messages (`transcriptToMessages`), with
   `MessageContent` blocks (text, code, list, collapsed system prompt,
   thinking, raw JSON, tool calls + matched results), per-message raw JSON
   modal, branch-from-here, per-session model dropdown, in-place description
   edit, optimistic pending-thinking, remote-thinking, slash-command output
   bubbles, session stats (tokens used / context window), model context
   window lookup.
8. **`HarnessControls`** — the right-pane view for a selected harness tab:
   status, the harness's backing session, release (adopted only, never
   kills), destroy (gated confirmation for adopted harnesses).
9. **`NewTabComposer`** — the inline new-tab form: provider/model/agent
   selection, branch-from-here (lazy backend session create on first send),
   existing-harness attach (adoptWindow with consent_confirmed).
10. **`TopBar` + `BottomBar` + `StatusDot` + `JsonTree`** — the chrome.
11. **Hooks** — `useApi` (transcript, send, agents, session CRUD, tab CRUD,
    harness adopt/release/destroy), `useListsStream` (live `ListsSnapshot`
    over WS), `useTranscriptStream` (seed + WS tail, `reconcileEntries`),
    `useSessionActivityStream` (per-session thinking/idle), `useNewTabSpec`
    (the composer state machine).
12. **`streamClient`** — the singleton WS client: focus ops, entry
    subscription, status + lastError tracking, origin normalization.
13. **Types** — `SessionInfo`, `TabInfo` (with `TabStatus`, `TabOrigin`,
    `extModified`, `stale`, `attachCommand`), `TranscriptEntry` (with the
    verbatim `raw` field — everything visible), `Message`/`MessageContent`,
    `ToolCallInfo`, `AgentInfo`, `ProviderInfo`, `DiscoverableWindow`.
14. **`Seal.Phase7Spec` capstone** — a browser-driven (or headless
    Playwright) end-to-end: open the web UI, start a new tab, chat, see the
    transcript stream, branch from a row, start a harness tab, see it in
    the sidebar, destroy it, archive a session, unarchive it.

**Milestone (7b):** the web UI close-duplicates the reference's behavior and
appearance — sidebar with tabs + recent/archived sessions, chat area with
branch-from-here + per-session model + raw JSON modals, harness controls,
new-tab composer (provider/branch/attach), live WS streaming, slash-command
output bubbles. hlint clean, `-Werror` green, the capstone passes.

---

## Phase 8 — More channels, Scheduler, MCP, remaining providers

The web channel + gateway already shipped in Phase 7; Signal shipped in
Phase 2. This phase adds the remaining channels and the breadth features.
All new channels register their commands into the existing `/`-command
registry and enter the core only via `Seal.Ingest`, so the preserved tab UX,
discoverable `/help`, and the preprocessing gate come for free.

**Deliverables (in priority order):**
- **Telegram channel** — `Seal.Channels.Telegram` (BotFather command
  registration generated from the registry), allow-lists, pairing.
- **CLI channel unification (optional)** — fold the existing `Seal.Channel.Cli`
  haskeline REPL into the `ChannelKind`/`Seal.Ingest` routing the Signal and
  web channels use (it currently bypasses `MessageSource`/`ConversationId`).
  More work but a uniform architecture; deferred unless the user asks.
- **Remaining Trusted ISA groups** — the Scheduling group (`CRON`,
  `HEARTBEAT_WAKEUP`, pure cron predicate + STM scheduler) and the MCP group
  (`MCP_LIST/CONNECT/DISCONNECT`), deferred from Phase 3.
- **Remaining providers** — OpenAI, OpenRouter (Ollama already merged).
- **Off-box transcript mirroring hardening** — the original Audited-log
  design had a mirror hook; the git-based design has no equivalent yet. A
  `git remote` + `git push` on auto-commit (or a cron `git push`) would be
  the analogue. Not started; not requested.
- **Gateway pairing/multi-device hardening** — pairing via
  `Seal.Security.Pairing` for the web channel.

**Milestone:** reach the agent from anywhere (web, Signal, Telegram, CLI),
multiple providers, durable off-box audit — the full README feature set.

---

## Per-phase definition of done

A phase is done when, in the Nix dev shell: `cabal build all` is `-Werror`
clean, `cabal test` is green (including the new QuickCheck properties),
`hlint src/ test/` is clean, the phase milestone is demonstrable, and the work
is committed. Then write the next phase's detailed plan before starting it.
