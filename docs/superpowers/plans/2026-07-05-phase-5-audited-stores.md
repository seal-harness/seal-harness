# Phase 5 — Audited Evolutionary Stores: Plan for Memory, Skills, Agents

> **For agentic workers:** Implement milestone-by-milestone, top to bottom. Each
> milestone is TDD (red → green → commit per task). Steps use checkbox (`- [ ]`)
> syntax. Do not start a milestone until the previous one's gate is green
> (`cabal build all` `-Werror` clean, `cabal test` green, `hlint src/ test/` clean,
> all in the Nix dev shell).

**Goal:** Stand up the Audited tier — the unified cross-session append-only log
that captures every mutation to the agent's four evolutionary stores, then ship
three of those stores (Memory, Skills, Agent definitions + lifecycle) as ISA
opcode groups on top of it. Plus a foundational session-transcript format change
that the whole phase depends on.

## Source-of-truth resolution (decided)

Two append-only logs, with distinct roles:

1. **Session transcript** — per-session record of the conversation *and* every
   opcode invocation in that session (Audited opcodes included). The new
   efficient format (`conversation.jsonl` + `entries.jsonl`) lands in M0,
   ported from the PureClaw transcript-storage design
   (`/Users/zoe/code/pureclaw/docs/superpowers/specs/2026-07-01-transcript-storage-format-design.md`).
   **The user may prune old session transcripts** to reclaim disk space — that
   is a supported operation, not a hazard.

2. **Audited log** — a single global, cross-session, append-only record of
   every mutation to the four evolutionary stores (memory, skills, agent
   definitions, config). **Canonical** for those four stores: stores
   materialize by replaying it. **Cannot be pruned** — it is the audit trail.
   Off-box mirror hook (same durability primitive as the transcript daemon).
   **Not hash-chained.** Integrity rests on the same foundation as the
   session transcript — the append-only single-writer + fsync, keeping
   untrusted operations off the box that holds the log, and the harness
   codebase itself being the trust boundary (mirroring
   `Seal.Transcript.Types`: "Integrity comes from the append-only handle
   plus keeping untrusted actions off the box that holds the log — not from a
   hash chain"). A hash chain without proof-of-work mining adds no real
   integrity guarantee here; it is omitted deliberately.

An Audited opcode therefore writes to **both** logs:

- the **session transcript** (per-session audit; records *that* this session
  invoked this opcode, with secret-free metadata);
- the **Audited log** (cross-session canonical; records the mutation itself).

Deleting a session transcript loses that session's conversation but loses
**nothing** about the agent's evolutionary state — that survives in the Audited
log. Reconstructing a deleted session's per-session audit is out of scope (the
Audited log carries the cross-session-relevant facts only); the session
transcript is the per-session audit and is disposable.

> Note on README:289 ("Transcript as source of truth — All derived stores are
> materialized views rebuilt from transcript replay"): this plan reads that line
> as loose wording for the *per-session* view, and the **Audited log** as the
> cross-session canonical source for the four evolutionary stores. The roadmap
> Phase 5 text is consistent with that reading. If the project later wants the
> per-session transcript to remain the *only* canonical source for memory in
> single-session use, the M2 design can keep an in-session memory cache fed from
> the session transcript and flushed to the Audited log on each mutation — that
> is an implementation detail of the backend, not a contract change.

## Tech Stack

Haskell (GHC2021), Cabal, Nix dev shell. New deps: `sqlite-simple` (Memory
SQLite backend). Build/test via `nix develop --command cabal build all`,
`… cabal test`, `… hlint src/ test/`.

## Global Constraints

Inherited from the roadmap verbatim where the spec is exact:

- **Module namespace:** all library code under `Seal.*`. New modules:
  `Seal.Audited.*`, `Seal.Memory.*`, `Seal.Skills.*`, `Seal.Agent.Def.*`,
  `Seal.Agent.Runtime.*`, `Seal.Handles.Audited`, `Seal.Transcript.Conv` /
  `Seal.Transcript.Entries`.
- **Coding style:** GHC2021; conservative always-on `default-extensions`
  (`DeriveGeneric, DeriveStrategies, LambdaCase, ScopedTypeVariables`);
  per-file `OverloadedStrings` / `ImportQualifiedPost` etc. Whole-module
  imports; post-positive qualified imports (`import Data.Text qualified as T`).
- **Errors:** `Either Text` / `ExceptT Text` default. A bespoke error ADT only
  where control flow pattern-matches it — expected here: `AuditedError`
  (chain-verification failure, write failure, mirror failure).
- **GHC flags:** `-Wall -Werror` plus the strict set. Warnings are errors; the
  build must stay green.
- **TDD:** red → green → commit. Security-critical pure functions (replay,
  memory key validation, `verifyOrder` sanity checks) get QuickCheck properties.
- **hlint clean** before each commit: `hlint src/ test/`.
- **No secret ever serialized.** Audited-log entries that reference secrets
  (none in Memory/Skills/Agents, but the rule stands) carry key names only.
  `MEMORY_STORE` content is *agent-visible memory*, not a vault secret — it is
  recorded in full in both the transcript and the Audited log (memory is the
  agent's own data, not user credentials).
- **No shell-wrapping.** The Audited writer, memory backends, and skill store
  use direct IO (file handles, SQLite binding), never shell. SQLite via
  `sqlite-simple` binding, not via the `sqlite3` CLI.
- **Type-guaranteed identifiers.** `MemoryId`, `SkillId`, `AgentDefId` are
  smart-constructed newtypes with a charset predicate (`[A-Za-z0-9_-]`,
  non-empty, no leading dot) — the same predicate shape as `SessionId`. They
  appear in any future path-join or SQL-parameter position only via the
  validated type.
- **Cabal registration:** new library modules in `exposed-modules`, new test
  specs in `other-modules`, both alphabetical; new specs wired into
  `test/Main.hs`.
- **Commits:** one per task; trailer
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Build/verify:** `nix develop --command cabal build all`,
  `nix develop --command cabal test`,
  `nix develop --command cabal test --test-options='--match "<needle>"'`,
  `nix develop --command hlint src/ test/`.
- **Clean-room:** no prior/reference runtime named in code, comments, docs, or
  commit messages. The PureClaw transcript-format design is a *spec* we port,
  not a runtime we name — port the format, not the identifier.

---

## Milestone map

| M | Title | Gate |
|---|---|---|
| **M0** | Efficient session transcript format | `cabal test` green; legacy read path still works; new sessions write `conversation.jsonl` + `entries.jsonl`; `reconstruct` round-trips byte-identically to old format (modulo intentional uncapping) |
| **M1** | Audited log foundation | `cabal test` green; log appends atomically with fsync; mirror hook fires on each append; replay materializes the four stores' *event stream* (no store impl yet); `verifyOrder` rejects a duplicated entry id |
| **M2** | Memory group | `cabal test` green; the four `MEMORY_*` opcodes dispatch through `Seal.ISA.Dispatch` (Audited branch writes both logs); SQLite/Markdown/None backends materialize by Audited-log replay; `MEMORY_RECALL` uses the dynamic-retrieval pager |
| **M3** | Skills group | `cabal test` green; `SKILL_LIST/READ/CREATE/UPDATE` dispatch as Audited; skill store is a materialized view over the Audited log |
| **M4** | Agent definitions + lifecycle | `cabal test` green; `AGENT_DEF_READ/UPDATE` Audited-backed; `AGENT_LIST/START/STATUS/STOP` manage in-process agent instances via an STM registry, each running a forked `runTurn` loop over its own `AgentEnv` |

---

## M0 — Efficient session transcript format

**Goal:** Replace the O(N²) full-`CompletionRequest`-per-line transcript with the
PureClaw change-log sidecar design: `conversation.jsonl` (one `Message` per line,
the pure content list) + `entries.jsonl` (one event per line, payload-free,
envelope-delta omitted-if-unchanged). Legacy `transcript.jsonl` stays read-only.

**Why first:** every later milestone's "Audited opcodes also write to the session
transcript" depends on a session-transcript format that doesn't bloat O(N²).
Branch-resume and session search (a deferred Phase 3 op) also want it.

**Files:**

- Create: `src/Seal/Transcript/Conv.hs` — the `conversation.jsonl` model: line =
  raw `Message`; `appendMessages` (diff incoming `crMessages` against the
  already-written lines, return the new lines); pure read = `mapMaybe decode`.
- Create: `src/Seal/Transcript/Entries.hs` — the `entries.jsonl` model: `EntryRecord`
  (the columns of `TranscriptEntry` minus `tePayload`, plus `convLen` and
  envelope-delta fields `erModel?/erSystem?/erTools?/erParams?` for `Request`
  events, recorded only when changed); event-kind discriminator
  (`request|response|harness|compaction`); JSON instances; `effectiveEnvelope`
  (left-fold over deltas → envelope in effect at entry *i*).
- Create: `src/Seal/Transcript/Reconstruct.hs` — pure
  `reconstruct :: [ConvLine] -> [EntryRecord] -> [TranscriptEntry]`, byte-identical
  to the old format modulo the intentional uncapping improvement; applies the
  existing `redactHeaders` pass (none yet — placeholder pass-through; wiring
  deferred to Phase 4 network opcodes).
- Modify: `src/Seal/Handles/Transcript.hs` — `withTranscript` learns the new
  two-file layout. Detection: if `conversation.jsonl` exists → new path; else if
  `transcript.jsonl` exists → legacy read path. The writer:
  1. diffs incoming `crMessages` against already-written conversation lines;
     appends only the new `Message` lines to `conversation.jsonl`, fsync;
  2. appends the entry line (envelope-delta + `convLen` + response meta) to
     `entries.jsonl`, fsync.
  Crash semantics: messages first, then entry line; a torn tail leaves at most
  orphan message lines / a malformed last line, both already tolerated by the
  skip-malformed decode path.
- Modify: `src/Seal/Transcript/Types.hs` — keep `TranscriptEntry` (the
  reconstruction target); add a tag for the new format on the read side. The
  `mkInvocationEntry` path in `Seal.ISA.Dispatch` stays — it produces a
  `TranscriptEntry`, which the new writer converts to an `EntryRecord` +
  conversation delta.
- Modify: `src/Seal/Agent/Loop.hs` — `runTurn` now passes the structured
  `CompletionRequest` (for envelope-delta extraction) plus the full message list
  to the transcript handle, instead of pre-serializing the whole request as a
  payload. The handle diffs and appends. The response path records response meta
  (usage / durationMs / stopReason / provider id) in `entries.jsonl` and the
  assistant content blocks in `conversation.jsonl`.
- Modify: `src/Seal/Config/Paths.hs` — add `sessionConversationPath`,
  `sessionEntriesPath` alongside the existing `sessionTranscriptPath`.
- Modify: `src/Seal/Session/Store.hs` — `newSession` no longer creates an empty
  `transcript.jsonl`; the writer creates `conversation.jsonl` + `entries.jsonl`
  on first append.
- Tests: `test/Seal/Transcript/ConvSpec.hs`, `test/Seal/Transcript/EntriesSpec.hs`,
  `test/Seal/Transcript/ReconstructSpec.hs`, `test/Seal/Handles/TranscriptSpec.hs`
  (extend), `test/Seal/Agent/LoopSpec.hs` (extend).

**Tasks (sketch — full TDD steps written at M0 start):**

1. `Seal.Transcript.Conv` — `Message`-line model + `appendMessages` diff.
   Properties: write turns → read-back `[Message]` == original messages; diff
   is the minimal append.
2. `Seal.Transcript.Entries` — `EntryRecord` + envelope left-fold. Properties:
   omit-if-unchanged round-trips; `effectiveEnvelope` at *i* matches the
   envelope that was actually in effect.
3. `Seal.Transcript.Reconstruct` — pure `reconstruct`. Property:
   `reconstruct conv entries ==` the byte-identical old-format
   `TranscriptEntry` list (modulo uncapping).
4. Wire the new writer into `Seal.Handles.Transcript`; legacy read-only path
   for old sessions. Integration test: a multi-turn session grows
   `conversation.jsonl` by deltas and `entries.jsonl` stays payload-free.
5. Switch `Seal.Agent.Loop.runTurn` to feed the structured request; update the
   response-recording path. Existing LoopSpec examples stay green (they assert
   on the channel, not the transcript format) — add new assertions on
   `conversation.jsonl` line counts.
6. Full-suite verification + hlint.

**Milestone gate:** `cabal test` green; legacy `transcript.jsonl` fixtures still
decode via the legacy read path; new sessions write the two-file layout;
`reconstruct` round-trips byte-identically.

---

## M1 — Audited log foundation

**Goal:** The unified cross-session append-only log. Atomic fsync
appends. Off-box mirror hook. Pure replay materializes an event stream (no store
implementation yet — M2/M3/M4 consume the replay).

**Files:**

- Create: `src/Seal/Audited/Types.hs` — `AuditedEntry`
  (`aeId :: Text` (UUID), `aeTimestamp :: UTCTime`, `aeSession :: SessionId`
  (provenance — which session caused this), `aeOpcode :: OpName`, `aeKind ::
  AuditedKind` (`Memory|Skill|AgentDef|Config` — discriminator for which store),
  `aePayload :: Value` (the secret-free mutation record, store-specific
  shape)). `AuditedLog` (the open log handle). JSON instances; canonical
  encoding (`encodeAuditedEntryRaw`) guarantees byte-identical re-encoding
  (stable for any future on-disk comparison; not for hashing — there is no
  hash chain).
- Create: `src/Seal/Audited/Chain.hs` — pure log-integrity helpers. **No hash
  chain.** Provides `verifyOrder :: [AuditedEntry] -> Either AuditedError ()`
  (checks that timestamps are non-decreasing and entry ids are unique — a
  basic sanity check, not a tamper-evidence proof) and `sortEntries ::
  [AuditedEntry] -> [AuditedEntry]` (ordered by timestamp). Tamper-evidence is
  *not* claimed and *not* tested for; integrity rests on the single-writer +
  fsync + off-box execution model, not on a cryptographic chain. QuickCheck:
  generated logs pass `verifyOrder`; a duplicated id is rejected.
- Create: `src/Seal/Handles/Audited.hs` — `AuditedHandle` capability record:
  `auditedAck :: AuditedEntry -> IO ()` (block until fsync'd + mirror
  attempted), `auditedAsync :: AuditedEntry -> IO ()`, `closeAudited :: IO ()`,
  plus a mirror hook field (`ahMirror :: AuditedEntry -> IO ()`, no-op by
  default). `withAuditedLog :: FilePath -> (AuditedHandle -> IO a) -> IO a` —
  same single-writer-daemon + `fsync` pattern as `Seal.Handles.Transcript`.
  Mirror hook fires after the local fsync, before the ack TMVar is filled (so a
  slow mirror *does* back-pressure the writer — fail-closed for durability; a
  later flag can make the mirror async-only).
- Create: `src/Seal/Audited/Replay.hs` — pure `replay :: [AuditedEntry] ->
  [AuditedEvent]` where `AuditedEvent` is the store-agnostic mutation
  (opcode + payload + provenance). M2/M3/M4 fold this into their store
  materializers.
- Modify: `src/Seal/Config/Paths.hs` — `auditedLogPath :: SealPaths -> FilePath`
  (`<state>/audited.log`). Off-box mirror target path is config-driven (M1
  hard-codes the local path; the mirror is a no-op hook by default).
- Modify: `src/Seal/ISA/Dispatch.hs` — the `Audited` branch currently calls
  `recordAsync` on the *session* transcript only. Extend it to *also* call
  `auditedAck` on the Audited log with a freshly minted `AuditedEntry`. The
  opcode's `opRun` runs concurrently with both writes (Audited is Trusted +
  also-logged; the ACK-before-execute gate is Untrusted-only). Wiring: the
  dispatcher needs an `AuditedHandle` field added to its signature — threaded
  through from `Seal.Channel.Cli`'s `withTranscript`/`withAuditedLog` bracket.
  `Seal.Agent.Env.AgentEnv` gains an `aeAudited :: AuditedHandle` field.
- Modify: `src/Seal/Agent/Env.hs`, `src/Seal/Agent/Loop.hs`, `src/Seal/Channel/Cli.hs`
  — thread the `AuditedHandle` through to the dispatcher.
- Tests: `test/Seal/Audited/TypesSpec.hs`, `test/Seal/Audited/ChainSpec.hs`,
  `test/Seal/Handles/AuditedSpec.hs`, `test/Seal/Audited/ReplaySpec.hs`,
  `test/Seal/ISA/DispatchSpec.hs` (extend — assert Audited opcodes write both
  logs).

**Tasks (sketch):**

1. `Seal.Audited.Types` + canonical encoding; `Seal.Audited.Chain` pure
   `verifyOrder` (no hash chain). QuickCheck: generated logs pass
   `verifyOrder`; a duplicated id is rejected.
2. `Seal.Handles.Audited` — single-writer daemon, `fsync`, mirror hook,
   `auditedAck`/`auditedAsync`/`closeAudited`. Property: an `auditedAck` returns
   only after the bytes are durable on the local log (use a fake fsync + a real
   temp dir).
3. `Seal.Audited.Replay` — pure fold over entries → events. Property: replaying
   a generated log yields the events in order. (No chain verification step —
   integrity is not cryptographic; replay trusts the log bytes, which are
   protected by the single-writer + off-box-execution model.)
4. Wire `AuditedHandle` through `AgentEnv` + `Dispatch`; the Audited branch writes
   both logs. Integration test: a fake Audited opcode (test-only) dispatched
   through `dispatch` lands in *both* the fake transcript and the fake Audited
   log; the Audited entry's `aeSession` and `aeOpcode` match the invocation.
5. Full-suite verification + hlint.

**Milestone gate:** `cabal test` green; an Audited opcode dispatched through
`dispatch` writes to both the session transcript (new M0 format) and the
Audited log; the Audited log is durable across a simulated crash (fsync
ordering test); `verifyOrder` rejects a duplicated entry id.

---

## M2 — Memory group

**Goal:** The four Memory opcodes (`MEMORY_STORE`, `MEMORY_RECALL`,
`MEMORY_UPDATE`, `MEMORY_DELETE`) as Audited opcodes, backed by
SQLite/Markdown/None materialized views over the Audited log. `MEMORY_RECALL`
uses the dynamic-retrieval pager (M-a, merged).

**Files:**

- Create: `src/Seal/Memory/Types.hs` — `MemoryId` (smart-constructed newtype,
  `[A-Za-z0-9_-]+`, no leading dot), `MemoryEntry` (`meId :: MemoryId`,
  `meContent :: Text`, `meTags :: [Text]`, `meCreatedAt/meUpdatedAt :: UTCTime`,
  `meSession :: SessionId` (originating session)). The `AuditedEntry` payload
  for `aeKind = Memory` is one of `Store MemPayload | Update MemPayload | Delete
  MemId` — store-specific payload shape, JSON-encoded, secret-free (memory
  content is agent-visible, not a credential).
- Create: `src/Seal/Memory/Backend.hs` — `MemoryBackend` capability record:
  `mbStore :: MemoryEntry -> IO ()`, `mbRecall :: MemoryId -> IO (Maybe
  MemoryEntry)`, `mbRecallPaged :: PageParams -> Int -> IO [MemoryEntry]` (paged
  recall for the dynamic-retrieval window), `mbUpdate :: MemoryEntry -> IO ()`,
  `mbDelete :: MemoryId -> IO ()`, `mbList :: IO [MemoryEntry]`. Three impls:
  `sqliteBackend :: FilePath -> IO MemoryBackend`, `markdownBackend ::
  FilePath -> IO MemoryBackend`, `noneBackend :: MemoryBackend` (in-memory
  map, for tests / opt-out). All three materialize by Audited-log replay on
  startup (the replay populates the backend; subsequent opcodes write through
  to both the Audited log and the backend).
- Create: `src/Seal/ISA/Ops/Memory.hs` — four `Opcode`s, all `Audited`. Input
  schemas: `MEMORY_STORE {id, content, tags?}`, `MEMORY_RECALL {query?, limit?,
  offset?}` (uses the dynamic-retrieval page-sizing: `page_size = clamp(floor,
  round(A·total^0.5), ceiling)`, total = number of matching memories),
  `MEMORY_UPDATE {id, content?, tags?}`, `MEMORY_DELETE {id}`. `opAuthorize`
  validates the `MemoryId` via `mkMemoryId`. `opRun` writes through the
  `MemoryBackend` and the Audited log; `orRecorded` carries the `MemoryId` +
  op name (secret-free). The dispatcher's Audited branch handles the dual write
  to transcript + Audited log; the opcode itself handles the backend mutation
  (the backend is the materialized view; the Audited log is canonical).
- Modify: `src/Seal/ISA/Registry.hs` — register the four opcodes (wiring in
  `Seal.Channel.Cli`).
- Modify: `src/Seal/Channel/Cli.hs` — build a `MemoryBackend` (config-driven:
  `sqlite` default, `markdown`, `none`), thread it into the opcodes, register
  the opcodes in the ISA registry. Build the `AuditedHandle` via
  `withAuditedLog` alongside `withTranscript`.
- Modify: `src/Seal/Types/Config.hs` — add `fcMemoryBackend :: Text` (`sqlite` /
  `markdown` / `none`).
- Tests: `test/Seal/Memory/TypesSpec.hs`, `test/Seal/Memory/BackendSpec.hs`
  (all three backends), `test/Seal/ISA/Ops/MemorySpec.hs`,
  `test/Seal/ISA/DispatchSpec.hs` (extend — Audited memory opcode writes both
  logs and mutates the backend).

**Tasks (sketch):**

1. `Seal.Memory.Types` + `mkMemoryId` predicate + JSON. QuickCheck: smart
   constructor rejects bad ids; `MemoryEntry` round-trips.
2. `Seal.Memory.Backend` — `noneBackend` (in-memory) first; TDD the four ops.
   Properties: store→recall round-trip; delete→recall absent.
3. `sqliteBackend` — `sqlite-simple` binding; schema created on open; same
   op-shape. Integration test against a temp .sqlite file.
4. `markdownBackend` — one Markdown file per memory under `<state>/memory/`,
   atomic write (tmp → chmod 0600 → rename), list = enumerate dir. Same op-shape.
5. Materialization-from-replay: `materializeMemory :: [AuditedEvent] ->
   MemoryBackend -> IO ()` folds the Audited log into the backend at startup.
   Property: replaying a generated event stream yields the same backend state
   as applying the opcodes directly.
6. `Seal.ISA.Ops.Memory` — four opcodes; `MEMORY_RECALL` uses the pager. Specs
   assert: dispatch writes both logs + mutates the backend; `orRecorded`
   carries the `MemoryId` only.
7. Wire into the registry + `Seal.Channel.Cli` + config field. End-to-end: a
   chat turn that calls `MEMORY_STORE` then `MEMORY_RECALL` round-trips content.
8. Full-suite verification + hlint.

**Milestone gate:** `cabal test` green; the four memory opcodes dispatch as
Audited (both logs written); all three backends pass the same op-shape tests;
`MEMORY_RECALL` paging follows the square-root law; replay materializes the
backend identically to direct application.

---

## M3 — Skills group

**Goal:** `SKILL_LIST`, `SKILL_READ`, `SKILL_CREATE`, `SKILL_UPDATE` — Audited
opcodes over a skill store materialized from the Audited log. A *skill* is a
named Markdown bundle (name + description + body) the agent can read into a
prompt or update.

**Files:**

- Create: `src/Seal/Skills/Types.hs` — `SkillId` (smart-constructed, same
  predicate as `MemoryId`), `Skill` (`skId :: SkillId`, `skDescription :: Text`,
  `skBody :: Text`, `skCreatedAt/skUpdatedAt :: UTCTime`, `skSession ::
  SessionId`). Audited payload: `Create SkillPayload | Update SkillPayload |
  Read SkillId` (read is Audited too — the agent reading its own skills is an
  evolutionary event worth logging, with secret-free metadata).
- Create: `src/Seal/Skills/Backend.hs` — `SkillBackend` capability record:
  `sbCreate`, `sbRead`, `sbUpdate`, `sbList`. One impl for M3:
  `markdownSkillBackend :: FilePath -> IO SkillBackend` (one file per skill
  under `<state>/skills/`, atomic write). Materializes from Audited-log replay.
  (A SQLite backend can be added later by reusing the M2 pattern; M3 ships
  Markdown only to keep the milestone tight.)
- Create: `src/Seal/ISA/Ops/Skills.hs` — four Audited opcodes. Input schemas:
  `SKILL_CREATE {id, description, body}`, `SKILL_READ {id}`, `SKILL_UPDATE {id,
  description?, body?}`, `SKILL_LIST {}`. `opAuthorize` validates `SkillId`.
- Modify: `src/Seal/ISA/Registry.hs`, `src/Seal/Channel/Cli.hs` — register +
  wire.
- Tests: `test/Seal/Skills/TypesSpec.hs`, `test/Seal/Skills/BackendSpec.hs`,
  `test/Seal/ISA/Ops/SkillsSpec.hs`.

**Tasks (sketch):**

1. `Seal.Skills.Types` + `mkSkillId` + JSON round-trip.
2. `Seal.Skills.Backend` — `markdownSkillBackend`; TDD the four ops;
   materialize-from-replay.
3. `Seal.ISA.Ops.Skills` — four Audited opcodes; dispatch writes both logs;
   `orRecorded` carries `SkillId` only.
4. Wire into registry + `Seal.Channel.Cli`. End-to-end: create → read → update
   → list round-trips.
5. Full-suite verification + hlint.

**Milestone gate:** `cabal test` green; the four skill opcodes dispatch as
Audited; skill store materializes from Audited-log replay; markdown backend
passes the op-shape tests.

---

## M4 — Agent definitions + lifecycle

**Goal:** `AGENT_DEF_READ` / `AGENT_DEF_UPDATE` (Audited-backed definition
store) + `AGENT_LIST` / `AGENT_START` / `AGENT_STATUS` / `AGENT_STOP`
(running-agent lifecycle). **Scope:** in-process agent instances only — no
tmux/harness integration (that is the separate Phase 3 Harnesses group, which
models external-CLI-tool harnesses, a different concern). An "agent" here is a
named configuration (provider + model + system prompt + tool exposure) plus a
running instance bound to a session.

**Files:**

- Create: `src/Seal/Agent/Def/Types.hs` — `AgentDefId` (smart-constructed),
  `AgentDef` (`adId :: AgentDefId`, `adName :: Text`, `adProvider :: Text`
  (label), `adModel :: ModelId`, `adSystem :: Maybe Text`, `adTools ::
  AllowList OpName` (which opcodes this agent may call), `adCreatedAt ::
  UTCTime`, `adSession :: SessionId`). Audited payload: `DefUpdate AgentDef |
  DefRead AgentDefId`.
- Create: `src/Seal/Agent/Def/Backend.hs` — `AgentDefBackend` capability record
  (`adbRead`, `adbUpdate`, `adbList`); `markdownAgentDefBackend :: FilePath ->
  IO AgentDefBackend` (one file per def under `<state>/agents/`); materializes
  from Audited-log replay.
- Create: `src/Seal/Agent/Runtime/Registry.hs` — `AgentInstance` (`aiId ::
  AgentDefId`, `aiSession :: SessionId`, `aiStatus :: AgentStatus`
  (`Starting|Running|Idle|Stopped|Crashed Text`), `aiThreadId :: ThreadId`,
  `aiEnv :: AgentEnv`); `AgentRuntime` — an STM-backed registry of running
  instances (`arInstances :: TVar (Map AgentDefId AgentInstance)`), with
  `startAgent`, `stopAgent`, `listAgents`, `agentStatus`. Race-safe CRUD mirroring
  the Phase-2 `HarnessRegistry` pattern.
- Create: `src/Seal/ISA/Ops/Agent.hs` — six Audited opcodes. The two `AGENT_DEF_*`
  mutate the Audited-backed definition store. The four `AGENT_*` lifecycle ops
  drive the in-process runtime: `AGENT_START {id}` forks a `runTurn` loop in a
  fresh session bound to the def's provider/model/system/tools, returning the
  new `SessionId`; `AGENT_LIST {}` snapshots the STM registry; `AGENT_STATUS
  {id}` reads one; `AGENT_STOP {id}` kills the thread + marks `Stopped`.
- Modify: `src/Seal/ISA/Registry.hs`, `src/Seal/Channel/Cli.hs` — register +
  wire. The `AgentRuntime` is built in `runCliTui` alongside the
  `SessionRuntime` and threaded into the opcodes.
- Tests: `test/Seal/Agent/Def/TypesSpec.hs`,
  `test/Seal/Agent/Def/BackendSpec.hs`,
  `test/Seal/Agent/Runtime/RegistrySpec.hs`, `test/Seal/ISA/Ops/AgentSpec.hs`.

**Tasks (sketch):**

1. `Seal.Agent.Def.Types` + `mkAgentDefId` + JSON round-trip + QuickCheck on
   the smart constructor.
2. `Seal.Agent.Def.Backend` — markdown backend; TDD read/update/list;
   materialize-from-replay.
3. `Seal.Agent.Runtime.Registry` — STM registry; race-safe CRUD; QuickCheck on
   the invariants (no two instances share a def id while running; stop always
   marks Stopped).
4. `Seal.ISA.Ops.Agent` — six opcodes. `AGENT_START` forks `runTurn` via
   `async` over a fresh `AgentEnv` built from the def; the loop reads from the
   def's session. Specs use a fake provider + fake caps; assert the thread
   starts, sends a greeting, and `AGENT_STATUS` reads `Running`.
5. Wire into registry + `Seal.Channel.Cli`. End-to-end: define an agent → start
   it → it runs a turn → status `Running` → stop → status `Stopped`.
6. Full-suite verification + hlint.

**Milestone gate:** `cabal test` green; the six agent opcodes dispatch as
Audited (the two def ops) or Trusted (the four lifecycle ops — running an
instance is harness-internal, not an evolutionary mutation, so lifecycle ops
are Trusted not Audited; only the *definition* mutations are Audited). Def
store materializes from Audited-log replay; the STM registry is race-safe.

---

## Cross-milestone invariants (asserted at every gate)

- **No secret ever serialized.** Memory content, skill bodies, agent defs are
  agent-visible data, not vault secrets — recorded in full. Vault secrets are
  never written to either log (enforced by the existing CPS secret types).
- **Audited opcodes write both logs.** The dispatcher's Audited branch calls
  `recordAsync` (session transcript) *and* `auditedAck` (Audited log). The
  Untrusted ACK-before-execute gate is unchanged (Untrusted opcodes are not in
  this phase).
- **Audited log is not hash-chained.** Integrity rests on the single-writer +
  fsync + keeping untrusted operations off the box that holds the log, same
  foundation as the session transcript. `verifyOrder` is a basic sanity check
  (unique ids, non-decreasing timestamps), not a tamper-evidence proof.
- **Stores materialize from Audited-log replay.** A cold start reads the
  Audited log, folds it into the backend, and the backend is the
  materialized view. The Audited log is canonical; the backend is a cache.
- **Session transcripts are disposable.** Deleting a session's
  `conversation.jsonl` + `entries.jsonl` loses the conversation but not the
  agent's evolutionary state (the Audited log is intact).

## Definition of done (whole phase)

In the Nix dev shell: `cabal build all` is `-Werror` clean, `cabal test` is
green (including new QuickCheck properties for replay materialization,
`verifyOrder`, and the smart-constructor predicates), `hlint src/ test/` is
clean, and the phase milestone is demonstrable: a chat session that creates a
memory, recalls it paged, defines a skill, defines an agent, starts the agent
in a forked session, and stops it — with every mutation landing in the Audited
log and every session transcript in the new two-file format.
