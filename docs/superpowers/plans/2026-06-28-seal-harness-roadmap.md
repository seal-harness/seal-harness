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

The ordering follows the user's directive: **vault first** (security
foundation), then **the shortest path to a usable system**, then **build out
the ISA starting with the core Trusted opcodes**.

**Channel priority (user-directed):** the first usable channel is the **web
frontend** (a close duplication of the reference's React 18 + TypeScript + Vite
+ Tailwind SPA over a Warp/WAI gateway with a WebSocket transcript broker), then
**Signal**, with the **CLI channel deferred to much later**. The MVP is
therefore delivered over the web channel, not a CLI REPL.

```
Phase 0  Scaffolding ........................... DONE (committed)
Phase 1  Security foundation + Secret Vault .... security from day one
Phase 2  Minimal usable agent (MVP) over WEB ... usable end-to-end, web-first
  2a   Command infra + ingress gate + min web loop
  2b   Full web-frontend close-duplication
Phase 3  ISA build-out: core Trusted opcodes ... the highest-value feature
Phase 4  Untrusted opcode breadth + isolation .. shell/files/web at scale
Phase 5  Audited stores: Memory/Skills/Agents/Config
Phase 6  More channels (Signal → …), Scheduler, MCP, remaining providers
```

Dependency rationale: Phase 1 establishes the secret types, crypto seam, and
project conventions everything else imports. Phase 2 stands up the transcript
spine (append-only + ACK), the ISA dispatcher skeleton, one provider, the
agent loop, the Secrets opcodes (proving the vault end-to-end), exactly one
Untrusted opcode (proving the ACK-before-execute path), the **`/`-command
infrastructure + channel-ingress preprocessing gate**
(`docs/superpowers/specs/2026-06-28-slash-command-infrastructure-design.md`),
and the **web channel** (gateway + WebSocket broker + React/TS frontend) as the
MVP's first and only channel. Phase 3 then widens the ISA along the Trusted
groups, which is where the architecture's value compounds. Signal and the
deferred CLI channel land in Phase 6.

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

## Phase 2 — Minimal usable agent (MVP) over the web channel

**Detailed plan:** to be written at the start of Phase 2
(`2026-07-xx-phase-2-mvp.md`), likely split into **2a** (command infrastructure
+ ingress gate + minimal end-to-end web loop) and **2b** (full web-frontend
close-duplication) to keep milestones bite-sized. Two designs feed it:
- `docs/superpowers/specs/2026-06-28-slash-command-infrastructure-design.md` —
  the `/`-command registry, optparse-derived discoverable help, the Layer-1
  terse tab-routing front-end, and the single channel-ingress preprocessing
  gate (preprocessing guaranteed before any LLM call, on every channel).
- a web-frontend behavioral spec written at the start of the 2b work.

**MVP bar (decided):** **web chat** against Anthropic (gateway + WebSocket
transcript broker + React/TS/Vite/Tailwind SPA, close-duplicating the
reference), the working vault (Secrets opcodes), `ASK_HUMAN`/`SHOW_HUMAN` so the
loop is interactive, an append-only transcript underneath, the `/`-command
infrastructure with a working `/help` and the preserved tab UX, **plus one
Untrusted opcode** (`FILE_READ`) exercising the full ACK-before-execute path.
Smallest thing that proves the whole architecture end-to-end — over the
prioritized web channel rather than a CLI REPL (the CLI channel is deferred to
Phase 6).

**Core type foundations land here, in full.** Even though the *runtime* MVP only
exercises a provider-backed web session, Phase 2 settles the complete core type
structure — sessions, transcripts, providers, harnesses, and tabs — up front,
because every later subsystem imports these types and they are expensive to
churn once code depends on them. For harnesses and tabs, Phase 2 ships the
**types plus their pure operations** (registry CRUD, tab-list invariants, cursor
resolution); the live lifecycle (process spawn, reconcile loop, output routing)
is wired in Phase 3 and later on top of these stable types. All foundation
modules are leaf-ish (depend only on `Seal.Core` / `Seal.Security`) and carry
QuickCheck coverage for their invariants and JSON round-trips.

**Deliverables (task groups).** Groups 1–6 are the core type foundations;
groups 7–15 are the runtime MVP built on top of them. Roughly, groups 1–11 and
13–15 are the **2a** milestone (command infra + ingress gate + minimal web loop);
group 12 (the frontend) straddles both — a deliberately minimal web client in
2a (enough to chat, stream the transcript, run `/help`, and drive tabs) and the
full close-duplication of the reference's UI in the **2b** milestone.

1. **`Seal.Core.Types`** — the shared leaf vocabulary, imported everywhere:
   - Identity newtypes: `ProviderId`, `ModelId`, `ToolCallId`, `MemoryId`,
     `UserId`, `CommandName`, `Port`.
   - `SessionId` — opaque label (no parse invariant, so older/newer on-disk
     session dirs stay readable) plus the single strict predicate
     `isValidSessionId` (non-empty, no leading dot, charset `[A-Za-z0-9_-]`)
     used at every path-join and network boundary.
   - `ConversationId` — a server-derived, transport-scoped conversation key,
     **always minted from authenticated transport metadata, never read from a
     message body**, so a sender cannot forge it to hijack another
     conversation's tab cursor.
   - `MessageSource` (`ChannelKind` ∈ {Cli, Web, Signal, Telegram, Background,
     Other}, the required `ConversationId`, optional `UserId`, an open field
     map) constructed only via `mkMessageSource`, which strips control
     characters and bounds the length of every attacker-controlled string leaf.
   - `MessageTarget` (`TargetProvider` | `TargetHarness Name`), `WorkspaceRoot`,
     `AutonomyLevel` (`Full`|`Supervised`|`Deny`, the per-session/agent posture
     — distinct from the per-opcode `TrustLevel`),
     `TrustLevel`(`Untrusted`|`Trusted`|`Audited`), and the `AllowList` family
     (`AllowAll`|`AllowList (Set a)`, `isAllowed`, `allowListWarning`).
2. **`Seal.Session.*`** — the session model:
   - `Seal.Session.Kind` — `SessionKind` (`SkProvider ProviderSpec` |
     `SkHarness HarnessSpec`); `ProviderSpec` (provider, model, optional agent);
     `HarnessSpec` — because a harness is an external CLI tool that can only be
     driven reliably **inside a tmux session**, the spec carries its `TmuxConfig`
     coordinates directly (flavour, tmux, cwd, args, optional durable ids)
     rather than a general backend; `HarnessFlavour` (known tools + a
     smart-constructed `HCustom` that rejects path separators);
     `inferProviderId` (model-prefix → provider).
   - **Harness backend vs. tool-call backend — keep these separate.** They are
     two different concerns and must not share a type. A *harness* backend has
     exactly one viable form — tmux — so `HarnessSpec` hard-codes `TmuxConfig`
     (no choice to model). A *tool-call execution* backend — where Untrusted
     opcodes and raw-shell tabs actually run — is genuinely plural and is
     modelled by the `TerminalBackend` family
     (`Local`/`Tmux`/`Ssh`/`Container`, with `TmuxConfig`/`SshConfig`/
     `ContainerSpec`+validated `ContainerTarget`). That type belongs with the
     isolated execution environments in **Phase 4**, not here; Phase 2 only
     fixes the harness/session shape.
   - `Seal.Session.Types` — `SessionPrefix` (smart-constructed, reserved-word
     denylist), `newSessionId` (timestamp-leading so lexicographic = chronological
     order), and `SessionMeta`, the persistent `session.json` record
     (id, kind, model, channel, created/last-active, archived/description/
     auto-summary display state, and a set-once `MessageSource` provenance field
     flagged **never to feed authz**).
   - Tag-discriminated, back-compat-tolerant JSON throughout (unknown/legacy
     shapes decode rather than crash). QuickCheck: every smart constructor
     rejects malformed input; `SessionMeta`/`SessionKind` round-trip.
3. **`Seal.Transcript.Types`** — the append-only audit-entry model:
   `Direction` (`Request`|`Response`); `TranscriptEntry` (uuid, timestamp,
   optional harness/model, direction, raw payload, optional duration, a
   correlation id linking request↔response, extensible metadata map);
   `TranscriptFilter` (record-of-`Maybe`, all fields AND together) with pure
   `matchesFilter`/`applyFilter`; `encodeEntryRaw` guaranteeing the in-memory
   entry re-encodes byte-identically to its on-disk JSONL line so "view raw"
   hides nothing. QuickCheck: round-trip and ordering preserved.
4. **`Seal.Providers.Class`** — the provider/message model: `Role`
   (`User`|`Assistant`); `ContentBlock` (`Text`|`Image`|`ToolUse`|
   `ToolResult`) and `ToolResultPart` (text/image) so tool-use/tool-result and
   vision interleave in one message list; `Message` + convenience builders;
   `ToolDefinition`/`ToolChoice`; `CompletionRequest`/`CompletionResponse`/
   `Usage`; `StreamEvent` for incremental output; the `Provider` class
   (`complete`, default-delegating `completeStream`, `listModels`) and the
   `SomeProvider` existential for config-driven selection. Full JSON instances
   with QuickCheck round-trips.
5. **`Seal.Harness.*` + `Seal.Handles.Harness`** — the external-tool model
   (types + pure registry ops now; lifecycle in Phase 3):
   - `Seal.Harness.Id` — `HarnessId`, a UUID-backed durable identity (the
     registry key), keyed on identity rather than a mutable terminal label.
   - `Seal.Handles.Harness` — `HarnessHandle`, the capability record of `IO`
     actions (send/receive/snapshot/status/stop); `HarnessStatus`,
     `HarnessError`, a no-op handle for tests, and the output
     prefix/sanitize helpers (strip ANSI/control/decorative bytes).
   - `Seal.Harness.Registry` — `HarnessEntry` (identity + reconciled
     coordinate/health cache), `HarnessOrigin` (`Spawned`/`Discovered`/
     `Adopted`), `Liveness` (`Idle`/`Thinking`/`AwaitingInput`/`Exited`/
     `Orphaned`), the `STM`-backed `HarnessRegistry` with race-safe CRUD
     (`insert`/`lookupById`/`lookupByLabel`/`modify`/`delete`/`snapshot`), and
     `mergeReconcile` (`ObservedHarness` → entries, merged **by key inside one
     transaction** so concurrent inserts are never clobbered).
6. **`Seal.Tabs.Types` + `Seal.Handles.Tab`** — the tab model, a pure view
   layer over ground truth (types + pure ops now; routing wired later):
   - `Seal.Handles.Tab` — the validated `TabIndex` (`0..35`, `mkTabIndex`),
     the single index type reused everywhere.
   - `Seal.Tabs.Types` — `TabRef` (`BoundSession SessionId` |
     `BoundHarness HarnessId`), `TabStatus` (`Live`|`Dead`), `Tab`, and the
     `TabList` enforcing **I1** (contiguous slots `0..n-1`; removal compacts,
     tmux-window style) and **I2** (no two tabs share a `TabRef`) by
     construction, with a hard 36-slot cap; plus per-conversation routing —
     `ConversationKey` (`ChannelKind`×`ConversationId`), `RelayMode`
     (`FocusedOnly`|`ActivityDigest`|`Firehose`), and `CursorState` whose
     cursors key by `TabRef` not slot (**I3**: a cursor survives slot
     compaction because it names ground truth, resolved to a current slot at
     read time). Includes the parsed `/tab` command ADTs. Heavy QuickCheck on
     the I1/I2/I3 invariants. The **Layer-1 terse-grammar routing front-end**
     (`route`: `/N` switch, `/N payload` inject, plain-text default) that drives
     these ADTs lands in group 10 with the rest of the command infrastructure.
7. **Transcript handle + daemon + ACK** — `Seal.Handles.Transcript`
   (append-only JSONL via raw POSIX FDs + fsync) and a writer-thread daemon
   whose `recordAndAck` returns only after fsync. Integrity comes from the
   append-only handle plus keeping untrusted actions off the box that holds the
   log, not from a tamper-evident chain. The dispatcher must call `recordAndAck`
   before executing an Untrusted opcode.
8. **ISA skeleton** — `Seal.ISA.Opcode` (the `Opcode` record: name, trust
   level, input/output schema, authorization gate), `Seal.ISA.Registry`,
   `Seal.ISA.Dispatch` (`dispatch :: Registry -> OpName -> Value -> App
   Result`, enforcing ACK-before-execute for Untrusted). Untrusted opcodes must
   dispatch through a **backend execution seam** (not run inline), so Phase 4 can
   slot the local-vs-remote executors behind it without reworking dispatch — see
   the remote-only untrusted execution design
   (`docs/superpowers/specs/2026-06-28-remote-only-untrusted-execution-design.md`).
9. **Anthropic provider** — `Seal.Providers.Anthropic` (Messages API,
   implements the Phase-2 `Provider` class, reads the key via `withApiKey` from
   the vault).
10. **`/`-command infrastructure + channel-ingress gate** — full design in
    `docs/superpowers/specs/2026-06-28-slash-command-infrastructure-design.md`.
    `Seal.Command.Spec`/`Parse`/`Help` (the `CommandSpec` registry, quote-aware
    tokenizer, `execParserPure` bridge, and optparse-derived `/help` for every
    command and option), `Seal.Routing.Route` (the Layer-1 terse tab grammar),
    and `Seal.Ingest` (the single `ingest` chokepoint + ordered `PreprocessChain`
    that is guaranteed to run before any LLM call). Discoverability is enforced
    by a property test over the registry; the tab terse grammar is a first-class
    synopsis entry so it is discoverable through the same `/help`.
11. **Channel handle + web gateway** — `Seal.Handles.Channel` (the `ChannelCaps`
    capability: `send`/`prompt`/`promptSecret`/streaming chunks, with
    interactive ops returning a structured deferral on request/response
    channels), and `Seal.Gateway` (Warp/WAI HTTP server + WebSocket
    transcript-streaming broker), the close duplication of the reference gateway.
    This is the MVP channel.
12. **Web frontend (close duplication)** — a clean-room reimplementation of the
    reference's React 18 + TypeScript + Vite + Tailwind SPA. **2a** ships a
    deliberately minimal client (chat/transcript view + live WebSocket streaming
    + `/help` + tab driving) to close the end-to-end loop; **2b** is the bulk —
    sidebar with tabs + recent/archived sessions, tab + harness controls, and the
    command palette/autocomplete generated from the `/`-command registry.
    Behavior and appearance close-match the reference; no source is copied. The
    detailed behavioral spec is written at the start of this work.
13. **Agent loop** — `Seal.Agent.Env`, `Seal.Agent.Loop` (turn-based: message →
    completion → opcode dispatch → transcript → channel, until no tool calls),
    fed only via `Seal.Ingest`.
14. **First opcodes + first registered commands** — opcodes: `SHOW_HUMAN`,
    `ASK_HUMAN` (Trusted); the five Secrets opcodes (`SECRET_SAVE/GET/LIST/
    DELETE`, `VAULT_STATUS`, all Audited but values never logged); `FILE_READ`
    (Untrusted, via `SafePath` + ACK-before-execute). Commands registered into
    the Phase-2 registry: `/help`, the tab family (`/tabs`, `/tab …`, plus the
    terse `/N` routing), and the Secrets/`/vault` commands — proving the registry
    end-to-end with real entries.
15. **`seal` startup CLI** — replace `greet`/`tick` with `seal serve` (launch the
    web gateway) plus `vault` admin subcommands (`init`/`lock`/`unlock`/`rekey`),
    wired through `configuration-tools`. This is the process-`argv` parser only;
    it is a **completely separate** optparse tree from the `/`-command registry
    (group 10), even though both use optparse machinery. The interactive **CLI
    *channel*** (a haskeline REPL) is **not** built here — it is deferred to
    Phase 6.

**Milestone:** the core type foundations (groups 1–6) compile `-Werror` clean
with their invariant/round-trip properties green; the `/`-command discoverability
property test passes (every command and option reachable via `/help`); and
`export ANTHROPIC_API_KEY=…; seal serve` → open the **web UI** and chat with a
model that can save/read secrets, ask the human a question, and read a workspace
file, drive tabs via the preserved terse grammar, and discover every command via
`/help` — with every inbound message passing the ingress preprocessing chain
before any LLM call, every step landing in the append-only transcript, and
Untrusted reads blocked until their audit entry is durably written.

---

## Phase 3 — ISA build-out: core Trusted opcodes (highest-value feature)

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

**Milestone:** the agent can introspect and call the full Trusted instruction
set, manage sessions and schedules, and every Trusted execution is in the
session transcript with its declared schema.

---

## Phase 4 — Untrusted opcode breadth + isolation

**Deliverables:** the `TerminalBackend` family — the typed selector for *where*
a tool call runs (`Local`/`Tmux`/`Ssh`/`Container`, with `TmuxConfig`/
`SshConfig`/`ContainerSpec`+validated `ContainerTarget`) — which is the
tool-call-execution counterpart to the tmux-only harness backend fixed in
Phase 2; then the opcodes themselves: `SHELL_EXEC`, `PROCESS_MANAGE`,
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

## Phase 5 — Audited evolutionary stores

**Deliverables:** the unified cross-session Audited log (`Seal.Audited`),
append-only and mirrored off-box like the transcript; then the four Audited
opcode groups built on it — **Memory** (`MEMORY_STORE/RECALL/UPDATE/DELETE`,
SQLite/Markdown/None backends), **Skills** (`SKILL_LIST/READ/CREATE/UPDATE`),
**Agents** (`AGENT_DEF_*`, `AGENT_LIST/START/STATUS/STOP`), **Config**
(`CONFIG_VIEW/UPDATE`, `TARGET_SET`, `PROVIDER_LIST`). Secret values never
enter the Audited log — only key names and operation metadata.

**Milestone:** an agent that evolves (memory, skills, its own definition,
config) with every mutation in a global append-only log, so a self-destructing
agent is fully reconstructible by replay.

---

## Phase 6 — More channels, Scheduler, breadth

The web channel + gateway already shipped in Phase 2. This phase adds the
remaining channels in priority order and the breadth features. All new channels
register their commands into the existing Phase-2 `/`-command registry and enter
the core only via `Seal.Ingest`, so the preserved tab UX, discoverable `/help`,
and the preprocessing gate come for free.

**Deliverables (in priority order):**
- **Signal channel** (channel priority #2) — `Seal.Channels.Signal`, allow-lists,
  pairing via `Seal.Security.Pairing`; the single-threaded chat surface where the
  terse tab UX matters most. Generates its command/autocomplete list from the
  registry.
- **Telegram channel** — `Seal.Channels.Telegram` (BotFather command
  registration generated from the registry), allow-lists, pairing.
- **CLI channel (deferred from Phase 2)** — `Seal.Channels.CLI` (haskeline REPL
  `prompt`/`promptSecret`/streaming), now built as a real interactive channel
  rather than the MVP harness.
- Remaining providers (OpenAI, OpenRouter, Ollama); the scheduler; off-box
  transcript mirroring hardening; gateway pairing/multi-device hardening.

**Milestone:** reach the agent from anywhere (web, Signal, Telegram, CLI),
multiple providers, durable off-box audit — the full README feature set.

---

## Per-phase definition of done

A phase is done when, in the Nix dev shell: `cabal build all` is `-Werror`
clean, `cabal test` is green (including the new QuickCheck properties),
`hlint src/ test/` is clean, the phase milestone is demonstrable, and the work
is committed. Then write the next phase's detailed plan before starting it.
