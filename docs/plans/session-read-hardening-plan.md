# Session Read Hardening — Implementation Plan

> Status: APPROVED (gate iteration 3; override on remaining site-enumeration
> findings, folded in below; maintainer-approved 2026-10-22)
> Branch: `fix/session-self-read-guard` (continues; self-read guard + search
> self-exclusion already committed as 13b8501)
> Context: post-incident follow-up to the transcript self-echo feedback loop
> (session 20261022-174851-823, 4MB transcript in ~11 minutes). The
> context-compressor work stream is explicitly out of scope per maintainer
> decision (2026-10-22).

## Problem

Three classes of unbounded context growth remain after the committed guards:

1. **Unbounded reads.** `SESSION_MANAGE get` / `SESSION_GET` pagination caps
   *message count* (floor 50 / ceiling 200) but not bytes; `renderBlock`
   embeds tool results verbatim. The incident's `limit=10` call returned
   1.84MB. Any foreign-session read can still explode context.
2. **Secret laundering.** `redactMessages` (Seal.Handles.Transcript:511)
   redacts secret-opcode tool results only in the *owning* session's write
   path, keyed on that session's `secretOpNames`. `SESSION_MANAGE get`
   renders foreign transcripts with zero redaction — a foreign file written
   before its handle had secret ops configured (older builds, unusual
   flows) would leak raw secret-op results to any reader.
3. **No-progress repeats.** Nothing detects a model re-issuing identical
   session-read calls; the incident made four increasingly large reads.

Plus two robustness gaps:

4. **Id-equality is fragile.** The committed guards compare session ids. Seal
   has no persisted parent link (`SessionMeta` has no `smParent`; the
   sub-agent tree is a directory convention, re-derived by scanning in
   `resolveChildSessionPath`). A future compaction feature that rotates
   session ids would silently break the guards; child→parent reads (a
   mutual-echo path: the parent transcript can contain reads of the child)
   are unguarded today.
5. **Unstable pagination + O(file) reads.** `handleGet` reads the whole
   `conversation.jsonl` strictly then slices; `conversation.idx` +
   `readConvLines` (Seal.Transcript.ConvIndex:67) exist but are unused by
   the ops. Positional offsets drift on live foreign sessions between
   turns.

## Non-goals

- Context compressor / tool-result pruning-dedup (maintainer decision).
- Per-turn aggregate tool-result budget (folded into the deferred compressor
  stream).
- Read-path redaction of model-*echoed* secrets in foreign assistant text —
  not identifiable syntactically; needs the compressor stream. Noted as
  residual risk.
- **Message-id anchors (`around_message_id`).** See WU5 Deviations — Seal's
  `Message` type carries no id; the approved list scoped this item to an
  index anchor.
- **"References-not-content" for search.** Already satisfied by the existing
  shape: results carry session id + a short snippet only; full transcript
  content requires a targeted `get` (the two-step read the research
  wanted). WU3 additionally clamps *all* snippets to the 120-char cap so
  the reference stays short. Nothing further to build.

## Work Units (implementation order)

### WU1 — Byte-bounded reads + `conversation.idx` windowed reads

**Scope:** `src/Seal/ISA/Ops/Session.hs`, `test/Seal/ISA/Ops/SessionSpec.hs`.
No signature changes.

- Constants: total render budget ~96KB (`getRenderBudgetBytes`), per-message
  render cap ~8KB (`getRenderMessageBytes`).
- `handleGet`: select the message window as today (`paginateBy`), then read
  **only** that range via `readConvLines` when `conversation.idx` exists
  (both top-level and child dirs); fall back to the whole-file read when
  the index is missing (`readConvLines` returns `Left "conversation.idx
  not found"`). `readConvLines :: FilePath -> FilePath -> Int -> Int -> IO
  (Either Text [Message])` takes a `[start, end)` line range; the window
  slice must be mapped to it.
- Count-source note: when the idx is present, `total` comes from the idx's
  recorded line count; the fallback's `total` is the decoded-message
  count. These are equal for well-formed files (every line a valid
  `Message`); a malformed line can diverge them, which is accepted and
  documented — guard behavior (refusals, windowing) is identical on both
  paths, only `total`/`has_more` text can differ on malformed files.
- Render with budget: render messages in order; a message whose rendered
  size exceeds the per-message cap is truncated with a `[content truncated]`
  marker; accumulation stops at the budget and the footer reports
  `output truncated at N bytes — narrow the window (limit / offset /
  around_index)`. `orRecorded` gains `truncated :: Bool`.
- Existing `renderPageFooter` counts (`has_more`) must stay consistent with
  the *count-based* windowing; byte truncation only ever reduces what is
  rendered, and the footer says why.

**DoD:**
1. Seeded 200KB transcript + `limit=200` → rendered output ≤ budget and the
   truncation marker/footer appear; `orRecorded.truncated == true`.
2. Same range read via idx path and via whole-file path renders identically
   (well-formed file).
3. Session dir without `conversation.idx` still reads correctly (fallback).
4. All existing pagination tests green (small transcripts unaffected).
5. Single huge message (100KB) + small limit → per-message truncation with
   marker; secret content never in `orRecorded`.

### WU2 — Read-path secret redaction

**Scope:** `src/Seal/Handles/Transcript.hs` (export `redactMessages` —
one-line export-list addition), `src/Seal/ISA/Ops/Session.hs`, spec.

- `Session.hs` imports `secretOpcodes` from `Seal.ISA.Registry` (verified:
  no import cycle — Registry imports only Core.Types / Providers.Class /
  Opcode; Transcript imports no ISA modules).
- `handleGet` (both top-level and child branches): before rendering, apply
  `redactMessages secretOpcodes scanSet windowMsgs` where `scanSet` is the
  window plus a small pre-window margin (tool-use typically precedes its
  result within a message or one message earlier) so a tool-use just
  outside the window still causes its result to be redacted.
- Refusal/record paths unchanged; rendered foreign transcripts show the
  existing placeholder format from `redactBlock` (Transcript.hs:536
  `<redacted:secret>`-style) — do not invent a new format.

**DoD:**
1. Foreign session seeded with a `SECRET_MANAGE` tool-use + result
   containing `super-secret-value` → `get` renders the placeholder, value
   absent from parts and `orRecorded`.
2. Non-secret op results pass through verbatim.
3. Tool-use outside the window (result inside) still redacted via the
   pre-window margin.
4. `hlint` clean; no new partial functions.

### WU3 — `smParent` + baked-lineage guard + search caps

**Design decision (lineage is threaded, not looked up):** the guard needs
the current session's ancestor chain at `handleGet` time. Persisted-meta
lookup cannot provide it for child sessions: `saveSessionMeta` writes only
to top-level `sessionMetaPath` (Store.hs:110-119), and locating a child's
meta from its sid requires `resolveChildSessionPath` (Paths.hs:260-285) —
the directory scan this work unit exists to avoid. Instead the chain is
**threaded through the spawn path and baked into the ops at registry-build
time**: the parent's registry knows its own lineage; `AGENT_START`'s wiring
carries it to the delegation worker; the child registry is built with
`childSid : parentLineage`. This needs no per-call meta reads, no scans,
and is robust to future id rotation by construction (the chain is derived
from live wiring at spawn time, not from persisted ids compared by
equality). The persisted `smParent` field remains in the design for audit
and future features, not for guard-time lookup.

**Scope:** `src/Seal/Session/Meta.hs`, `src/Seal/Session/Store.hs`,
`src/Seal/ISA/Ops/Session.hs`, `src/Seal/Core/TurnEngine.hs`
(`buildSessionRegistry` lineage threading + `buildChildRegistryAdapter`),
`src/Seal/ISA/Ops/Agent.hs` (`AgentStartWiring` gains the parent lineage;
spawn site passes it), `src/Seal/Agent/Runtime/Delegation/Worker.hs`
(worker deps gain the parent lineage; child meta write at the
`withIndexedTranscript` site, Worker.hs:248; adapter call passes
`childSid : parentLineage`), `src/Seal/Config/Paths.hs` (only if a helper
for the child meta path is wanted — `agentSessionDir` already exists),
specs. All `SessionMeta` record-construction sites are in scope and must
compile with the new field: src — `Store.hs:89` (`newSessionMeta`),
`TurnEngine.hs:1211` (`fallbackMeta`), `Meta.hs:81` (FromJSON); tests —
StoreSpec.hs:68, MetaSpec.hs:19, TabSpec.hs:256, NewSpec.hs:63,
CliSpec.hs:50, RepoDiscoverySpec.hs:718/763, ApiSpec.hs:139/647,
ApiTestHarness.hs:430, PatIngestionSpec.hs:232, Phase7aSpec.hs:62,
PartitionSpec.hs:28, SystemPromptSpec.hs:42, LoggerSpec.hs:132/158/189/214,
ServerSpec.hs:59, SessionSpec.hs:36, Command/ModelSpec.hs:44/289/303,
Gateway/SendSpec.hs:184/238/704/792/831 — mechanical one-line additions;
`-Werror` makes any residual site a build error.

- `SessionMeta`: add `smParent :: !(Maybe SessionId)`. JSON codec must
  decode files without the field (`Nothing`, using the existing tolerant
  `.:?` pattern at Meta.hs:80-93) — backwards compatible. Set `Nothing`
  in `newSessionMeta` and `fallbackMeta`.
- Child meta persistence: extract `writeMetaFileAtomic :: FilePath ->
  SessionMeta -> IO ()` from `saveSessionMeta`'s existing
  temp-write-chmod-rename body; `saveSessionMeta` calls it with
  `sessionMetaPath`, and a new `saveChildSessionMeta :: SealPaths ->
  SessionId -> SessionId -> SessionMeta -> IO ()` calls it with
  `agentSessionDir paths parentSid childSid </> "session.json"` (parent
  and child ids). The delegation worker writes a minimal child meta
  (parent's provider/model, channel `"agent"`, `smParent = Just
  parentSid`) at the Worker.hs:248 site (`dwdParentSid deps` / `childSid`
  in scope). Top-level `listSessions` (Store.hs:127-142) scans only
  top-level dirs, so child metas do not appear in SESSION_MANAGE
  list/search — no behavioral change there.
- Lineage threading: `AgentStartWiring` gains `aswParentLineage ::
  [SessionId]`; it is populated where the wiring record is *constructed* —
  `buildStartWiring` (TurnEngine.hs:1084) and the nested child wiring
  (TurnEngine.hs:1299) — both passed into `buildSessionRegistry` as the
  existing param, carrying the *parent's own* baked lineage (top-level:
  `[sid]`). The `DelegationWorkerDeps` record literal that gains
  `dwdParentLineage :: [SessionId]` (alongside `dwdParentSid`,
  Worker.hs:143) lives in `buildWorker` (TurnEngine.hs:1158-1194 — the
  `spawnCb` at Agent.hs:840-842 only registers the running agent); the
  worker passes `childSid : dwdParentLineage` to
  `buildChildRegistryAdapter`, which supplies it to the session ops
  (replacing the single-`SessionId` param committed earlier — the ops'
  guard param becomes `lineage :: [SessionId]`, self first, nearest
  ancestor next). Construction-literal sweep: AgentStartWiring test
  literals at AgentSpec.hs:337/375/409/443/468/498/537/566/597/628/927,
  Phase5Spec.hs:137/249, IntegrationSpec.hs:751,
  AgentIntegrationSpec.hs:1043; DelegationWorkerDeps test literal at
  WorkerSpec.hs:207-229 — mechanical one-line additions, `-Werror`
  catches any residual.
- Guards: `handleGet` refuses when the requested sid is a member of
  `lineage` (message distinguishes self — head — from ancestor);
  `handleSearch` excludes lineage ids from `matched` (by `smId`) and from
  `childMatched` (by child id). Existing self-read tests keep their
  semantics (self is the lineage head).
- Search result cap: cap `matched` + `childMatched` at 20; footer gains
  `showing 20 of N matches — refine your query`; `orRecorded` gains
  `match_total`.
- Snippet clamp: backend matches currently render snippets up to ~200
  chars (Session/Search.hs:154-158) while child snippets are capped at
  120. Clamp **all** rendered snippets to the existing 120-char
  `truncateSnippet` cap so search results stay short references.

**DoD:**
1. Spawned child session has `session.json` in its child dir with
   `smParent == parent`; it does not appear in `SESSION_MANAGE list`.
2. Op-level: an op built with lineage `[child, parent, root]` refuses
   `get` on `parent` and `root` (ancestor message), allows an unrelated
   session; wiring-level: the child registry's session ops carry
   `childSid : parentLineage` (verified by dispatching against the
   adapter-built registry in a test).
3. Old `session.json` files (no `smParent`) decode to `Nothing` and are
   accepted; legacy child dirs (no `session.json`) still resolve and read.
4. Search excludes all lineage rows, still finds unrelated matches.
5. Search with 30 matches renders 20 + footer; `orRecorded.match_total ==
   30`.
6. Every rendered snippet (backend and child) is ≤ 120 chars.
7. No directory scans and no per-call `session.json` reads occur on the
   guard path (assert by construction: the ops receive only baked
   values).

### WU4 — Repeat detection for session reads

**Scope:** new `src/Seal/ISA/RepeatDetect.hs` (+cabal exposed-modules,
+`test/Main.hs` — one-line additions each), `src/Seal/Core/TurnEngine.hs`
(`TurnDeps` field at :372 + per-turn lookup + `TurnEnv` threading),
`src/Seal/Agent/Env.hs` (`AgentEnv` field at :26 + construction at :231),
`src/Seal/Agent/Loop.hs` (hook in `dispatchOne` at :561),
`src/Seal/Agent/Runtime/Delegation/Worker.hs` (child `AgentEnv` at :267),
**registry origination (process-lifetime, mirroring `tdAbortReg`'s
journey)**: `src/Seal/Channels/Loop.hs` (`ChannelDeps` field at :46 +
`newChannelDeps` at :123-128), `src/Seal/Gateway/Send.hs` (`SendDeps` field
+ `mkWebTurnDeps` passes it at :268), `src/Seal/Command/Serve.hs`
(assignment at :288), `src/Seal/Tui.hs` (:48/:201) and
`src/Seal/Channel/Cli.hs` (`runCliTui` param at :149 + `TurnDeps`
literals at :216/272/303); test construction sites: LoopSpec.hs (~40
`AgentEnv` literals), WiringSpec.hs:53, Phase5Spec.hs:186,
IntegrationSpec.hs:249, SendSpec.hs:197, ApiSpec.hs:4411/4519/4669/4794/
4922, ApiTestHarness.hs:482 (SendDeps literals) — mechanical one-line
additions; new RepeatDetectSpec.

- **Registry lifetime is process-scoped**: `SessionRepeatRegistry` is
  created once per process at the same sites `newSessionAbortRegistry`
  is created today — in `newChannelDeps` (channels/web path) and in the
  TUI/CLI entry (`Tui.hs` → `runCliTui`) — then threaded
  `ChannelDeps → SendDeps → TurnDeps` and `runCliTui → Cli.hs TurnDeps
  literals`, exactly as `abortReg` flows (Channels/Loop.hs:123 →
  Serve.hs:288 → Send.hs:268). It is NOT created inside
  `mkWebTurnDeps` (pure, called per-request) — a per-request registry
  would silently reset the cross-turn window.
- **Child-track delivery**: `DelegationWorkerDeps` gains
  `dwdRepeatTrack :: RepeatTrack` mirroring `dwdAbortFlag` (set at
  TurnEngine.hs:1192, consumed at Worker.hs:261) so the child `AgentEnv`
  literal (Worker.hs:267) carries the child's own track, looked up from
  the registry keyed by `childSid`; the DelegationWorkerDeps test
  literal at WorkerSpec.hs:207-229 is updated accordingly.
- Wiring mirrors `aeAbortFlag` from there: `lookupOrCreateRepeatTrack
  (tdRepeatReg td) sid` per turn (as at TurnEngine.hs:685) → threaded
  through `TurnEnv`/`mkSessionAgentEnv` → new `aeRepeatReg :: RepeatTrack`
  field in `AgentEnv` → consumed in `dispatchOne`. Child sessions look up
  their own track (Worker.hs:267) keyed by `childSid`.
- `RepeatTrack` semantics: per session a sliding window of the last 16
  session-op inputs; canonical key = `(OpName, aeson-encoded input)`;
  scope = `{SESSION_MANAGE, SESSION_GET}`.
- Verdicts: first occurrence → `Allow`; identical key seen ≥2× within the
  window → `WarnRepeat` (dispatch proceeds, result parts get a prepended
  note `[note: repeated identical session read — no new information
  expected]`); ≥4× within the window → `BlockRepeat` (synthesized error
  result, op not dispatched). Enabled by default — no config knob in v1.
- Bounded memory: window capped; registry entries per session capped.
- Time-local: window is call-order based, not wall-clock.

**DoD:**
1. Pure verdict logic unit tests (bound generators; QuickCheck for key
   stability under JSON encoding).
2. Registry: sliding window eviction, per-session isolation, and
   **process-lifetime persistence** — a test that runs two separate
   turn/env constructions against the same registry observes the window
   surviving across them (a per-request registry fails this test).
3. Loop-level test: identical `SESSION_MANAGE` get input four times → 2nd
   carries the warning note, 4th is blocked with an actionable error;
   distinct inputs never warned.
4. All `AgentEnv`/`TurnDeps`/`TurnEnv`/`SendDeps`/`ChannelDeps`/
   `DelegationWorkerDeps` construction sites compile and are updated
   (build green under `-Werror`; includes the TurnEnv test literal at
   CliSpec.hs:145-166).
5. `.cabal` + `test/Main.hs` wired (merge-hotspot files: minimal diffs).

### WU5 — Anchor-based windowing (`around_index`)

**Scope:** `src/Seal/ISA/Ops/Session.hs`, spec. Depends on WU1.

- Optional `around_index` (integer) on `SESSION_MANAGE get` + `SESSION_GET`
  inputs + schemas. When present it overrides `offset`: window = `limit`
  messages starting at `max(0, around_index - limit/2)` (default limit 20
  in around-mode), clamped to the transcript; rendering keeps true global
  indices (pass the window start as `renderMessage`'s offset — signature
  already supports it, Session.hs:640). Footer reports the global range.
- The default back-to-front `offset=0` behavior is expressed and documented
  as the alias of the *tail anchor* (the window ends at the transcript
  tail): the anchor model is the primary interface, `offset` remains for
  literal absolute paging.
- Absent → existing behavior (back-to-front default) unchanged.

**Deviations (documented deliberately):**
- The research inspiration named Hermes' `around_message_id`. Seal's
  `Message` type carries **no id** (Providers/Class.hs:74 — `Message
  { msgRole, msgContent }`); ids exist only on `entries.jsonl` events
  (`erId`, Entries.hs:168), and the entry→message mapping is ambiguous
  for harness-emitted conversation lines, so a true message-id anchor
  requires a transcript format change. The maintainer-approved list
  scoped this item to "a get parameter that windows around an index" —
  `around_index` implements exactly that. A message-id anchor is noted
  as future work if/when a compaction feature (which would also motivate
  id-based anchoring) lands.
- Drift caveat: within a turn indices are stable; across turns a live
  foreign session's indices can drift (append-only growth). This is
  inherent to index anchoring and accepted per the approved scope.

**DoD:**
1. `around_index` mid-transcript returns the centered window with correct
   global `#N` indices.
2. Clamped at both ends; out-of-range values clamp (never error).
3. Default path (no param) byte-identical behavior to pre-WU5; the
   default is documented as the tail anchor alias.
4. Interacts correctly with WU1's byte budget and WU2's redaction.

## Sequence & branches

All work continues on `fix/session-self-read-guard`, committed per work
unit (TDD: failing test first, minimal implementation, `make check` green
before each commit). WU1 → WU2 → WU3 → WU4 → WU5. WU1 and WU2 share
`handleGet` rendering; WU3 changes the ops' guard param (single `SessionId`
→ `lineage`) and WU5 depends on WU1's windowed reads.

## Risks

- **conversation.idx availability**: child + old sessions may lack it —
  fallback path is mandatory (DoD 3 in WU1).
- **SessionMeta schema change**: additive, optional field; old files must
  decode (DoD 3 in WU3). Construction sites enumerated in WU3 scope;
  `-Werror` makes any missed site a build error, not a runtime bug.
- **Lineage threading breadth (WU3)**: touches the AGENT_START wiring
  record, worker deps, and child registry adapter; all are named in scope.
  Risk: a spawn path that forgets to thread lineage degrades the child's
  guard to self-only (safe failure — refuses less, never allows
  self-reads); the wiring-level DoD test catches it.
- **Registry lifetime (WU4)**: the repeat registry must originate
  process-lifetime; a per-request registry compiles green but silently
  resets the window. Mitigated by enumerating origination sites in scope
  and the lifetime DoD test (WU4 DoD 2).
- **AgentEnv/TurnDeps/TurnEnv/SendDeps/ChannelDeps/DelegationWorkerDeps
  field additions (WU3/WU4)**: every record literal must gain the field
  under `-Werror`; sites enumerated in WU3/WU4 scope; sweep is
  mechanical (one line each) and build-verified.
- **Loop.hs hook**: `dispatchOne` is on the hot path of every turn; the
  detector must be O(1) per call and exception-free.
- **.cabal / test/Main.hs** are merge hotspots: single-line additions only.

## Human checkpoints

- After WU1+WU2 (the unbounded-read + redaction core).
- After WU3 (schema + child-meta persistence + lineage-guard semantics).
- After WU4 (policy: warn/block thresholds — maintainer sign-off on 2/4).