# Implementation Plan — Issue #154 (Metaswarm Sub-Agent Orchestration)

<!-- issue: 154 -->
<!-- design: docs/superpowers/specs/2026-09-10-metaswarm-orchestration-design.md (v6, gate-approved 5/5) -->
<!-- branch: feat/metaswarm-orchestration-154 -->
<!-- status: draft rev 4 — gate: Completeness PASS, Scope PASS (iter 2); Feasibility census fixed across iters 2-4 (7 src + 15 test sites, grep verified); ready for user -->
<!-- approved: pending -->

## Plan review gate — iteration 3 (narrow census re-check) → rev 4 changelog

Feasibility round-3 re-check: all 21 listed sites verified at exact
lines, BUT (a) one more src site found — `Types.hs:110` (the `FromJSON`
instance builds positionally, must gain two `.:?` lines); (b) the DoD
grep pattern as written matched NONE of the `pure AgentDef` /
`Just AgentDef` / `( AgentDef` / `-> AgentDef <$>` forms (disproven by
direct execution). Rev 4: census now **7 src + 15 test sites**, DoD grep
pattern broadened and verified:
`rg "AgentDef[ {(<]|-> AgentDef|= AgentDef\b|pure AgentDef|Just AgentDef"`
(final census: 4 src construction-bearing files + 5 test files; all
other hits are type references, signatures, or record-UPDATE sites
which preserve unknown fields automatically and need no edit).

## Plan review gate — iteration 2 → 3 changelog

Iteration 2 verdicts: Completeness **PASS**, Scope & Alignment **PASS**,
Feasibility **FAIL** (one finding: the W1 constructor census). Rev 3
fixes:

- **Constructor census verified by grep across iterations 2-4** (the
  gate's hardest finding): final census **7 src construction sites
  (4 files) + 15 test sites (5 files)** — including 10 positional (hard
  arity error) `ApiSpec.hs` sites, the `Types.hs:110` `FromJSON`
  positional site (two `.:?` lines), `Command/AgentSpec.hs:31` (record),
  and the phantom `ISA/Ops/AgentSpec.hs:31` removed (it was an import
  line). The original DoD grep matched none of the `pure AgentDef` /
  `Just AgentDef` / `-> AgentDef <$>` forms (disproven by execution) —
  replaced with the broadened pattern. `RepoDiscoverySpec` and
  `ExecCacheSpec` verified construction-free (ExecCacheSpec has one
  signature reference only).
- **Fence-freedom property given one canonical home** (Completeness
  minor 10): test 1 stops at the sanitizer level; test 6 owns the
  end-to-end validate→encode property.
- **12a boundary clarified** (Scope round-2 minor): `max_spawn_depth = 1`
  rejects the depth-2 attempt (the orchestrator child's own spawn); a
  depth-1 spawn succeeds (`parentDepth >= maxDepth`).
- **Field-name unification**: `dwdResolveProviderOverride` everywhere
  (rev 2 had `dwdResolveProvider` drift).
- **R7/R8 added**: design-test-number cross-reference warning + the two
  design-doc errata lines ([agent] table + depth-conditional stub
  wording) riding in W3's commit.

## Plan review gate — iteration 1 → 2 changelog

All 3 reviewers FAILED iteration 1 (Feasibility, Completeness, Scope &
Alignment). Fixes applied in rev 2:

- **Child-turn provider seam (Feasibility B1, the big one):** child turns
  resolve providers via `buildWorker`'s `resolveChild` → `resolveDefProvider`
  (`Command/Provider.hs:352`) → real HTTP manager against
  `defaultOllamaBaseUrl` — the harness's `ScriptProvider` seam
  (`sdResolve`/`tdResolve`, `ApiTestHarness.hs:414-415`) only feeds
  top-level turns. Rev 2 adds a **`dwdResolveProviderOverride` test seam**:
  `ApiTestOptions.atoChildProvider :: Maybe (AgentDef -> IO (Either Text
  (SomeProvider, ModelId)))` threaded `tdMkWorker`-style (production
  `Nothing` = real `resolveChild`), so children run REAL scripted turns
  sharing the harness's one `ScriptProvider` script. No HTTP mock needed.
- **Stub-composition contradiction resolved (Feasibility B2):**
  `tdMkWorker` replaces the worker at the FIRST spawn (orchestrator child
  would never run a turn). Rev 2 defines the seam policy: **the
  orchestrator child runs a real scripted turn; the stub applies to
  leaf-most workers only** — `ApiTestOptions.atoChildWorker` becomes
  `Maybe (AgentDef -> Bool)` (stub predicate) or, simpler,
  **depth-conditional**: stub when `childDepth >= atoStubAtDepth`
  (default: top-level spawn + 1). The "at every level" wording is gone.
- **W1 constructor-site completeness (Feasibility B3):** all `AgentDef`
  record-construction + fixture sites enumerated in W1 scope (6 src + 7
  test sites, with locations).
- **Validator chokepoint widened (Completeness B1, Scope B1):** `group`,
  `provider`, `model` included; test 1 property extended; per-field cap
  matrix stated (256 for role/description/group; 1KB name).
- **Config kill switch section fixed (Completeness B2):** the key lives in
  the existing `[agent]` table (`AgentConfig`/`agentConfigCodec`,
  `Config/File.hs:316/494`) as `available_agents` — mirroring
  `parallel_tool_guidance`'s resolver pattern (`:638`), NOT a nonexistent
  `[runtime]` table (design §3.4's `[runtime]` wording corrected by this
  plan; the design doc gets a one-line errata note in W3's commit).
- **Remote-mode constraint given a home (Completeness B3):** W2 scope +
  DoD item (comment + assertion): the union backend reuses the parent's
  `cachedWorkdirScan` result; no new control-plane FS reads; the
  remote-mode arm of child tests runs via the same fake-runner path the
  harness already provides.
- **Depth-boundary test restored (Completeness B4, Scope B2):** test 12 is
  the design's 3-level chain under `max_spawn_depth = 2` (cap-boundary
  spawn at depth 2 succeeds-and-records, third level rejected); the
  `max_spawn_depth = 1` case becomes test 12a (boundary-clarified, cheap).
- **12b prompt-plane gating test added (Completeness B5, Scope B3):**
  `orchestrator_enabled = false` ⇒ orchestrator child's prompt carries NO
  catalog (test 23, with the registry-plane error still test 15).
- **Parent-prompt catalog test added (Completeness B6):** test 21 splits
  into parent-prompt (catalog present, AFTER `<available_skills>`) and
  child-prompt assertions; the e2e asserts the leaf-note too.
- **De-duplicated tests 5/17** (Scope B4): W1 test 5 = output-text only;
  W2 test 17 = recorded-JSON roles from workdir-decoded defs.
- **Test 7 asserts membership, not cardinality** (Scope B5).
- **Stale role-schema text edit dropped from W2** (Scope B6) — W1 owns it;
  quote corrected to the actual text ("\"leaf\" (default) or
  \"orchestrator\". Orchestrators may spawn…").
- **`encodeAgentDef` fence-freedom property folded into test 6**
  (Completeness minor 7).
- **`resolveTask` depth-tuple churn dropped** (Feasibility minor 7):
  `registerChild`'s call site already has `wiring` — depth comes from
  `aswParentDepth wiring + 1` there; no resolver-signature change.
- **W4 workdir seeding assumption fixed** (Feasibility minor 8): a
  `seedWorkdir` helper IS required (harness seeds no workdirs today;
  `ApiSpec.hs:3455-3511` hand-builds them); remote-arm wording is now
  "local-only" for child/e2e tests.
- **WorkerSpec cabal/Main wiring added to W2 scope** (Feasibility minor 9).
- **`max_spawn_depth ≥ 2` requirement stated in test 11's setup**
  (Feasibility minor 4).
- **PR-workflow details mirrored into the execution protocol** (Scope
  B7): draft PR immediately, hotspot minimality + rebase, branch suffix
  `-154`, no force pushes, `--no-verify` never.

## Tooling (project context)

- Build/test/lint: `make build` / `make test` / `make lint` / `make check`
  (all under `nix develop`; `-Wall -Werror`, hlint must report "No hints").
- **SIGPIPE**: never pipe cabal/hlint output — redirect to a file, then
  page. (`nix develop --command cabal test > /tmp/t.log 2>&1; tail /tmp/t.log`)
- Test wiring merge-hotspots: `seal-harness.cabal` (library
  `exposed-modules:` + test-suite `other-modules:`), `test/Main.hs` —
  minimal edits, rebase on `main` before `gh pr ready`.
- Targeted run:
  `nix develop --command cabal test --test-options="--match=/Seal.Gateway.AgentIntegration/" > /tmp/t.log 2>&1`.
- Pre-existing failure (NOT ours, fails on clean main):
  `Seal.Channels.Loop` "SKILL_LOAD writes the skill body…" — full-suite
  local runs only; `make check`/CI is the gate.
- Existing seams (verified): `runApiTestOpts`/`atoChildWorker` +
  `stubChildWorker` (`ApiTestHarness.hs:834`); `ScriptProvider` +
  `setScript` (`:714`, `sdResolve` stub at `:414` feeding top-level turns
  ONLY); `adMkSessionExec` (`Gateway/API.hs:139`) — test seam for
  `handleSessionAgents` workdir injection; `mkInMemWorkdirFs`
  (`WorkdirFs.hs:560`); mock-HTTP precedent `bracketMockOllama` +
  `mkPRWithOllama` (`test/Seal/Command/ModelSpec.hs:76-97`, writes
  `base_url` into config.toml).
- Delegation config: `[delegation]` TOML table (`DelegationFileConfig`,
  `Config/File.hs:170-190`) → `aswConfig` re-reads per call
  (`TurnEngine.hs:899-902`) → `fromFileConfig`. Tests override via
  `updateRuntimeConfig` (the `mkPRWithOllama` pattern) or a new
  `ApiTestOptions` field.

---

# W1 — Role + description (+ group/provider/model sanitization) on AgentDef

## File scope

- `src/Seal/Agent/Def/Types.hs` — `adRole :: Maybe Text`,
  `adDescription :: Maybe Text` on `AgentDef`; `FromJSON` two `.:?` lines;
  pure validators (new module-local or here):
  - `sanitizeAgentTextField :: Int -> Text -> Text` (single line:
    newlines/CR → space; C0 stripped; fence tokens
    `</available_agents>`, `</available_skills>`, `---` → `_`;
    cap param — 256 for role/description/group, 1024 for name).
  - `sanitizeAgentDefFields :: AgentDef -> AgentDef` — applies the cap
    matrix to role/description/group, plus `provider`/`model`
    (256 cap each — they render into `AGENT_DEF_LIST` output; Security
    item 10).
- `src/Seal/Agent/Def/Workdir.hs` — `decodeAgentDef` (:273) reads
  `role`/`description` + runs `sanitizeAgentDefFields` on the whole
  decoded def (single chokepoint for all fields incl. name from
  frontmatter); `decodeProtocolAgentMd` (:490) +
  `decodeProjectAgentsMd` (:462) same; `encodeAgentDef` (:254) round-trips
  both new fields.
- ALL `AgentDef` record-construction sites (must compile under -Werror;
  each gains the two new fields; **census verified by grep round 2** —
  positional `AgentDef x1 … x10` sites are hard arity errors, record
  `AgentDef {…}` sites are missing-field errors; the DoD grep pattern
  covers BOTH):
  - **src (7 construction sites in 4 files)**:
    - `src/Seal/Agent/Def/Types.hs` :110 — the `FromJSON` instance builds
      positionally (`AgentDef <$> o .: "id" <*> …`): add two `.:?` lines
      (`role`, `description`) — back-compat defaults `Nothing`.
    - `src/Seal/ISA/Ops/Agent.hs` `agentDefWriteOp` run (~:195-206) —
      + accepts optional `role`/`description` fields (authorize REJECTS
        role ∉ {orchestrator, leaf, absent}:
        `Left "AGENT_DEF_WRITE: role must be \"orchestrator\" or \"leaf\""`);
        description/name validated via the shared validators; unknown
        `tools:` names recorded in `orRecorded` (`"unknown_tools"` array);
        the in-schema `role` description text corrected (actual text at
        :391-393 implies per-task override — change to narrow-only
        wording).
    - `src/Seal/Gateway/API.hs` `stampAgentDef` (:1180-1191) — set/preserve
      the two fields (web CRUD path).
    - `src/Seal/Agent/Def/Workdir.hs` decoders: `decodeAgentDef` (:272-278,
      reads role/description + runs `sanitizeAgentDefFields` as the
      single chokepoint), `decodeProjectAgentsMd` (:452), 
      `decodeProtocolAgentMd` (:480), `loadDirAgentDef` (:390-412 —
      `adRole = Nothing`, `adDescription = Nothing`; DirScheme-decodes-
      as-leaf pinned by test).
  - **test (16 sites across 6 files)**:
    - `test/Seal/Gateway/ApiSpec.hs` — 10 positional sites (:1594, :1595,
      :1670, :1807, :1901, :1959, :2016, :2054, :3482, :3613) — HARD
      arity errors if missed;
    - `test/Seal/Agent/Def/BackendSpec.hs` — 2 record sites (:33 `mkDef`,
      :299 `flat`);
    - `test/Seal/Agent/Def/TypesSpec.hs` — 1 (:26 `sampleDef`);
    - `test/Seal/TestHelpers/Arbitrary.hs` — 1 (:180, 10→12 args; ALL
      AgentDef QuickCheck properties keep compiling);
    - `test/Seal/Command/AgentSpec.hs` — 1 (:31 `mkDef` record);
    - `test/Seal/RepoDiscoverySpec.hs` + `test/Seal/Session/ExecCacheSpec.hs`
      — verified import/reference-only (no constructions; zero edits).
  - DoD grep (verified round 3 — the earlier pattern matched none of the
    `pure AgentDef` / `Just AgentDef` / `( AgentDef` / `-> AgentDef <$>`
    forms):
    `rg "AgentDef[ {(<]|-> AgentDef|= AgentDef\b|pure AgentDef|Just AgentDef" src/ test/ | grep -vE "AgentDefBackend|AgentDefId|newtype|data AgentDef"`
    (file-granularity; multi-line record constructions show only the
    `AgentDef {` line). Record-UPDATE sites (`d { adGroup = … }`,
    `prefixWorkdirDef`) need no edit — they preserve unknown fields
    automatically..
- `src/Seal/Agent/Runtime/Delegation.hs` — `ctRole` haddock (:253-255)
  corrected to narrow-only semantics (behavior change is W2).
- Test fixtures (compile fixes + new-field plumbing):
  - `test/Seal/TestHelpers/Arbitrary.hs` (:180 region — AgentDef
    Arbitrary gains 2 args; ALL AgentDef QuickCheck properties keep
    compiling),
  - the construction sites enumerated above (ApiSpec ×9 positional,
    BackendSpec ×2, TypesSpec ×1, Command/AgentSpec ×1).
- `seal-harness.cabal` + `test/Main.hs` — no new modules in W1 (extends
  existing specs); no wiring needed.

## Tests (RED first — extend existing specs)

1. **Sanitizer property** (`Agent/Def/TypesSpec.hs`): for any string,
   `sanitizeAgentTextField` output has no newline, no C0 control char,
   no fence token; cap truncation applies. (The end-to-end
   validate→encode fence-freedom property has its canonical home in
   test 6 — this test stops at the sanitizer level.)
2. **Flat-scheme decode** of `role`/`description` frontmatter + round-trip
   via `encodeAgentDef`; DirScheme def decodes as leaf/`Nothing`
   (regression pin, `WorkdirSpec`).
3. **Protocol decode** sets both fields (`decodeProtocolAgentMd`).
4. **`AGENT_DEF_WRITE`**: accepts {orchestrator, leaf, absent}; rejects
   `"admin"` (authorize error text names the valid values); unknown
   `tools:` name appears in `orRecorded.unknown_tools`; description
   sanitized on write (multi-line input → single-line stored).
5. **`AGENT_DEF_LIST`** output text shows `[orchestrator]` for a
   role-carrying def (recorded-JSON roles asserted in W2's test 17 —
   de-duped).
6. **Round-trip property**: `encodeAgentDef` → `decodeAgentDef` preserves
   role + description AND the encoded frontmatter is fence-token-free
   (the W1 validator chokepoint proof).

## DoD

- [ ] Tests 1-6 green; `make check` green.
- [ ] Every `AgentDef` construction site compiles:
      `rg "AgentDef[ {(<]|-> AgentDef|= AgentDef\b|pure AgentDef|Just AgentDef" src/ test/ | grep -vE "AgentDefBackend|AgentDefId|newtype|data AgentDef"`
      — construction-bearing files: 4 src (Types.hs :110 FromJSON,
      Agent.hs :195, API.hs :1180, Workdir.hs :278/:401/:452/:480) +
      5 test (ApiSpec ×10, BackendSpec ×2, TypesSpec ×1, Arbitrary ×1,
      Command/AgentSpec ×1); all other grep hits are type references,
      signatures, or record-UPDATE sites (no edit needed).
- [ ] Existing suites unchanged-green (new fields `Maybe`, back-compat).

---

# W2 — Role-conditioned nested AGENT_START + depth + allow-lists + union backend

**The core WU.** (Split W2a mechanics / W2b errors if review demands; W2a
exit criterion is still test 11.)

## File scope

- `src/Seal/Agent/Runtime/Delegation/Worker.hs`:
  - `childBlocklist :: Maybe Text{-effective role-} -> Bool{-orch enabled-}
    -> Set OpName` (pure): leaf/`Nothing` OR switch-off ⇒ full
    `delegationBlocklist`; orchestrator+enabled ⇒ minus `AGENT_START`.
  - `filterBlocklisted` generalized to take the blocklist as an argument
    (today's callers pass the static set); `narrowAllowList` same. NOTE
    (Feasibility minor 6): `narrowAllowList` has ZERO call sites today —
    `adTools` is never applied; W2 wires the intersection NET-NEW at
    `buildChildRegistryAdapter` (not a modification of an existing
    enforcement path — scope it as new wiring).
  - `DelegationWorkerDeps` gains:
    - `dwdUnionDefBackend :: AgentDefBackend` (per-turn workdir⊕user union),
    - `dwdResolveProviderOverride :: Maybe (AgentDef -> IO (Either Text
      (SomeProvider, ModelId)))` — the **child-provider test seam**
      (Feasibility B1; `Nothing` in production = real `resolveChild`;
      tests inject a resolver returning the SAME `ScriptProvider` ref the
      harness's `sdResolve` already wraps, so child turns consume the
      next scripted response — the script is one shared queue; the field
      name throughout is `dwdResolveProviderOverride`).
  - `mkDelegateWorker` consumes `dwdParentDepth` (dead today) + effective
    role; passes (depth, role, union backend) into `dwdChildRegistry`.
- `src/Seal/Core/TurnEngine.hs`:
  - `buildChildRegistry` gains the role/switch/depth/backend/mint/config/
    runtime/pause/parentActivity/worker params and, for orchestrator
    children, constructs the NESTED `agentStartOp` with child-side
    `AgentStartWiring`:
    `aswDefBackend = union`, `aswParentDepth = dwdParentDepth + 1`
    (threaded depth + 1 = the child's own depth),
    `aswMintSession = mintSession childSid`,
    `aswWorker` = re-anchored `buildWorker td childSid … (dwdParentDepth
    + 1)` composed WITH `tdMkWorker` per the depth-conditional stub
    policy (below), `aswConfig` = same per-call loader,
    `aswRuntime`/`aswPauseFlag`/`aswParentActivity` = process-global
    handles. The op is ALWAYS present; leaf/switch-off ⇒ its run returns
    the dedicated error (W2b messages).
  - `buildChildRegistryAdapter` stops discarding `_def`: computes
    effective role (via W2's `effectiveRole` helper), intersects
    `adTools` with baseOps, applies `childBlocklist` at both chokepoints.
  - `buildWorker` takes the real parent depth (top-level turn = 0) and
    the union backend (from `buildStartWiring`'s `sessionBackends`).
  - `buildStartWiring` (:894-906): threads `sessionBackends` (already in
    scope) into worker deps; the top-level `aswParentDepth = 0` stays.
- **Depth-conditional stub policy (Feasibility B2)**: `tdMkWorker`
  (production `Nothing`) means "stub leaf-most workers". In W2 the stub
  becomes a predicate: `Maybe (Int{-childDepth-} -> Bool)` — a spawned
  worker is the stub when its own depth ≥ the threshold. The existing
  `atoChildWorker` harness option maps to threshold ∞-ish (stub at
  depth ≥ 1) preserving current tests' behavior; the nested tests pass a
  threshold of 2 (orchestrator children run REAL scripted turns;
  grandchildren get the stub). Documented in `ApiTestOptions` haddock.
- `src/Seal/ISA/Ops/Agent.hs`:
  - `registerChild` records `depth = aswParentDepth wiring + 1` (call
    site :439 has `wiring`; NO resolver-signature change — Feasibility
    minor 7).
  - `resolveTask` consumes `_parentDepth`: the dispatch-time gate —
    kill-switch-off or leaf-effective spawn ⇒ the dedicated error from
    the resolver's `Either` (TOCTOU gate; the def is in hand here).
- `src/Seal/Agent/Runtime/Delegation.hs`:
  - `effectiveRole :: Maybe Text -> Maybe Text -> Maybe Text` (pure,
    def-authoritative, ctRole-narrows-only).
  - `runDelegate`: `_orchEnabled` becomes a resolver input — the
    Either path rejects orchestrator-effective spawns while disabled
    (retry-hint message).
- `seal-harness.cabal` + `test/Main.hs` — **new test module wiring for
  `test/Seal/Agent/Runtime/Delegation/WorkerSpec.hs`** (Feasibility
  minor 9).

## Distinguishable error messages (W2b if split)

- Depth (existing): `"Delegation depth limit reached (depth=<n>, max_spawn_depth=<m>)…"`.
- Leaf: `"AGENT_START is not available to this agent: its definition is a leaf (role: leaf). Ask the operator to grant the orchestrator role if delegation is required."`
- Kill switch: `"Delegation spawning is disabled: delegation.orchestrator_enabled = false. Re-trying will not succeed until the operator re-enables it."`
- Spawn-pause: existing message unchanged.
All four surface to the parent via `ChildResult`'s error rendering
(`encodeResultsJson`).

## Remote-mode constraint (Completeness B3 — explicit)

The nested wiring's `aswDefBackend` and the child prompt's def list MUST
reuse the parent session's `cachedWorkdirScan` result (threaded through
`buildStartWiring` → `DelegationWorkerDeps.dwdUnionDefBackend`) — no new
control-plane FS reads in mode=remote. DoD: grep-comment at the thread
site + test 11's remote arm passes without new runner calls (the existing
fake-runner capture ref can assert no new `cat`/`find` probes beyond the
parent scan's).

## Tests (RED first)

`test/Seal/Agent/Runtime/Delegation/WorkerSpec.hs` (new, pure):

7. `childBlocklist` membership table: leaf/`Nothing`/switch-off ⇒
   `AGENT_START ∈ blocklist`; orchestrator+enabled ⇒ ∉. (Membership, not
   cardinality — Scope B5.)
8. Role-aware `narrowAllowList`: `AllowOnly` orchestrator def listing
   `AGENT_START` keeps it; leaf def listing it loses it.
9. `effectiveRole`: def-authoritative; `ctRole` narrows only (table +
   QuickCheck: leaf def never widens).
10. Tool intersection property: for any `AllowList` + role, child
    registry ops ⊆ baseOps and ∩ blocklist = ∅.

`test/Seal/TestHelpers/ApiTestHarness.hs` (seam work, unblocked by test 7):

- `atoChildProvider :: Maybe (AgentDef -> IO (Either Text (SomeProvider,
  ModelId)))` — child-resolver seam (wraps the SAME `providerRef` the
  top-level `sdResolve` uses, so `setScript` drives both parent and
  child turns from one queue).
- `atoStubWorkerFromDepth :: Maybe Int` — the depth-conditional stub
  threshold (default: stub at depth ≥ 1 = today's behavior).
- `atoDelegationOverride :: Maybe DelegationFileConfig` — writes
  `[delegation]` into the harness's config.toml before boot
  (max_spawn_depth / orchestrator_enabled overrides for tests 12/15/23).

`test/Seal/Gateway/AgentIntegrationSpec.hs` (integration):

11. **Grandchild spawn (W2 EXIT CRITERION)**: defs for orchestrator +
    leaf; script: parent turn 1 = `AGENT_START orchestrator`;
    orchestrator child turn = `AGENT_START leaf`; leaf worker = stub
    (threshold 2). Assert grandchild JSON in orchestrator summary,
    `AGENT_INSTANCES` = 2, recorded depths {1, 2}. **Requires
    `max_spawn_depth ≥ 2`** — the harness override sets it to 2 (test 12
    exercises the same override; default depth 1 would reject any
    grandchild).
12. **Depth boundary (design test 10)**: `max_spawn_depth = 2`; 3-level
    chain — orchestrator spawns child-orchestrator (succeeds at depth 2,
    grandchild recorded depth 2), child-orchestrator's spawn of the
    third level REJECTED with the depth message naming depth vs max.
    (12a, cheap variant: `max_spawn_depth = 1` ⇒ the depth-2 attempt —
    the orchestrator child's own spawn — is rejected; a depth-1 spawn
    still succeeds since the check is `parentDepth >= maxDepth`,
    Delegation.hs:463.)
13. **Batch orchestrator**: `tasks: [coder, reviewer]` — both register;
    orchestrator child still spawns; comment documents the single-token
    `bracketSem` bound (parallelism = 1 today).
14. **Leaf cannot spawn**: leaf child's AGENT_START errors with the
    dedicated leaf message (assert text + `orIsError`, NOT OpNotFound).
15. **Kill switch (registry plane)**: `orchestrator_enabled = false` ⇒
    orchestrator child's AGENT_START errors with the dedicated
    kill-switch message (resolver gate).
16. **Tool allow-list**: def with `tools = ["AGENT_DEF_LIST"]` ⇒ child's
    `FILE_WRITE` errors unknown-tool; `AGENT_DEF_LIST` succeeds.
17. **`AGENT_DEF_LIST` roles in recorded JSON** (workdir-decoded defs;
    output text covered by W1 test 5 — de-duped).

## DoD

- [ ] Tests 7-17 green (11 = exit criterion); `make check` green.
- [ ] No child registry contains blocklisted ops (property 10).
- [ ] `dwdParentDepth` fully consumed (no dead site); remote-mode
      no-new-FS-reads comment + assertion in place.

---

# W3 — `<available_agents>` catalog injection

## File scope

- `src/Seal/Agent/PromptParts.hs` — `availableAgentsBlock` +
  `injectAvailableAgents :: [AgentDef] -> Maybe Text -> Maybe Text`
  (mirror `Seal.Skills.Prompt`): bullets
  `- <full-id> [<role>]: <description|name-fallback>` (full
  merged-backend ids always — Designer S1), grouped by `adGroup`
  (`## <group>`), 4096 budget via `truncateBlock`, nudge
  `"Delegate with AGENT_START using an id before relying on an agent."`
- `src/Seal/Core/TurnEngine.hs`:
  - `resolveSystemPrompt` (:200): append `injectAvailableAgents` AFTER
    the skills catalog; def list from the per-turn union backend's
    `adbList` (the caller passes `[AgentDef]` — injection stays pure).
  - `childSystemPrompt` (:988): gains the child's spawn-capability flag
    (registry retains a USABLE AGENT_START = effective orchestrator +
    switch on) + def list; orchestrator children get the catalog; leaf
    children get `"You are a leaf agent; delegation is not available."`.
- `src/Seal/Config/File.hs` — the kill switch lives in the EXISTING
  `[agent]` table (`AgentConfig`, `:316`; codec `:494`): new field
  `acAvailableAgents :: Maybe Bool` + resolver
  `resolvedAvailableAgents :: RuntimeConfig -> Bool` (default True,
  mirror `:638`). **NOT a `[runtime]` table — that section does not
  exist** (Completeness B2; design doc gets a one-line correction in
  W3's commit).
- `seal-harness.cabal` + `test/Main.hs` — no new module needed (W3
  extends `PromptPartsSpec` + gateway spec).

## Tests (RED first)

`test/Seal/Agent/PromptPartsSpec.hs` (pure):

18. Empty def list ⇒ no block. N defs ⇒ N bullets, full ids,
    `[<role>]` suffix, description→name fallback, group headers, nudge.
19. >4096 chars ⇒ truncated with elided-count marker.
20. Fence-freedom property: no def's (sanitized) fields can emit
    `</available_agents>` or a newline into the block (feeds W1's
    validators).

`test/Seal/Gateway/AgentIntegrationSpec.hs`:

21. **Parent prompt**: system-prompt preamble entry contains the catalog
    (prefixed id + role) AND it appears AFTER the
    `</available_skills>` close (ordering assert).
22. **Orchestrator child prompt**: preamble contains
    `demo-project--orchestrator [orchestrator]`-style bullets.
23. **Gating (design 12b + PM S2 combined)**: leaf child ⇒ leaf note, no
    catalog; `orchestrator_enabled = false` ⇒ orchestrator child gets NO
    catalog (prompt plane gated with the registry plane — test 15);
    `[agent] available_agents = false` ⇒ no catalog anywhere.

## DoD

- [ ] Tests 18-23 green; `make check` green.
- [ ] No empty-tags emission (mirrors skills); `[agent] available_agents`
      resolver defaults True.

---

# W4 — Mini-metaswarm e2e fixture + docs

## File scope

- `test/Seal/Gateway/MetaswarmE2ESpec.hs` (new; wired in cabal +
  `test/Main.hs`):
  - **`seedWorkdir` helper** (REQUIRED — the harness seeds no workdirs
    today, Feasibility minor 8): materialize the demo-project tree into
    `spCache paths </> "workdirs" </> sidText` (the local-mode workdir
    root the harness's `mkSessionExec` computes) before the first turn;
    used by the e2e AND available to other specs.
  - Fixture: `demo-project/` with `.agents/agents.md`,
    `.agents/agents/{orchestrator,coder,reviewer}/agent.md`
    (role + distinct `tools:` frontmatter), `src/index.js`.
  - Scripted conversation (one shared `ScriptProvider` queue — parent
    turn 1, orchestrator child turn, coder/reviewer leaf stubs at
    threshold 2): parent → orchestrator (catalog visible) → batch
    spawn coder+reviewer → narrowed registries (coder's
    out-of-allow-list call errors; in-list calls succeed) → results →
    `AGENT_INSTANCES` depths {1,2,2}; leaf-child leaf-note asserted.
  - LOCAL-ONLY (`runApiTestLocal`-style) — remote-arm workdir seeding
    over SSH is out of scope for the e2e (Feasibility minor 8; W2's
    remote assertions stay in AgentIntegrationSpec's existing
    local/remote runner).
- `README.md` — Agents row note (role semantics, depth cap, catalog);
  delegation table.
- Changelog note (README changelog section or CHANGELOG.md) —
  allow-list behavior-change warning for pre-existing defs with
  `tools:` frontmatter (PM S2).
- Follow-up issues (filed via `gh` when auth works, else listed in PR
  body): frontend role badges/delegation-tree view; DirScheme role
  support; `AGENT_DEF_WRITE` Trusted→Audited; Claude-Code-style
  diff-based catalog announcements (future optimization).

## Tests

24. The §4.1 e2e conversation (local mode; remote pends per suite
    convention).
25. Real-provider smoke: `pendingWith`-guarded (needs a live model);
    the scripted fixture doubles as the manual checklist.

## DoD

- [ ] E2E green (local); `make check` green; `make lint` "No hints".
- [ ] README + changelog notes merged; follow-up issues referenced.

---

# Execution protocol (per work unit)

1. `git switch main && git pull && git switch -c
   feat/metaswarm-orchestration-154` (Scope B7 suffix). One PR for the
   whole feature: **open a DRAFT PR immediately** (`gh pr create --draft
   --fill --body "Closes #154"` — needs `gh auth login` to work first;
   if gh stays 401, the user opens the PR), push as you go.
2. Per WU: failing test(s) first (RED) → minimal implementation (GREEN)
   → `make check` → adversarial review (fresh reviewer, file:line
   evidence per DoD item) → commit (`feat: W<n> ...`).
3. Max 3 retries per WU on red; then escalate with failure history.
4. Human checkpoint after W2 (nested wiring + depth semantics review).
5. Rebase on `main` before `gh pr ready`; never `--no-verify`, never
   force-push. PR body: `Closes #154`, design + plan links, changelog
   note, follow-up issues.

## Risk register

- **R1 — nested wiring recursion**: `buildWorker` is a pure closure
  constructor; the grandchild wiring is built per-spawn inside
  `dwdChildRegistry` (verified no circularity). Fallback: extract a
  `NestedSpawnDeps` record built once per child run.
- **R2 — W2 size**: split W2a (mechanics) / W2b (errors); W2a's exit
  criterion is still test 11.
- **R3 — full-suite pre-existing failure** (`Channels.Loop` SKILL_LOAD):
  full-suite local runs only; `make check`/CI is the gate.
- **R4 — remote-mode pends**: SSH tests pend in CI without sshd; child
  remote arms follow the existing pattern; the W4 e2e is local-only.
- **R5 — child-provider seam**: the `dwdResolveProviderOverride` seam
  (rev 2) is
  the make-or-break for tests 11-15, 21-23, 24; if the shared-script
  queue interleaving (parent + child pops from one `ScriptProvider` ref)
  proves fragile, fallback: per-agentId script queues keyed by the
  def id the resolver sees (`resolveChild` receives the def — the
  resolver can pick the queue; deterministic because each child's first
  turn is its own turn).
- **R6 — delegation-config override plumbing** (Scope B8): if
  `atoDelegationOverride` proves awkward (config write timing vs
  `aswConfig`'s per-call re-read), fallback: override `bDelegationConfig`
  on the harness's backends record (it's an `IO DelegationConfig`
  field — tests wrap it; production unchanged).
- **R7 — label conventions**: the design's "12a" (kill-switch registry
  plane) = this plan's test 15; the design's test 10 = this plan's test
  12. When implementing, cite the design section, not the design's test
  number, to avoid cross-doc drift.
- **R8 — design-doc errata** (Scope round-2 item 5): two one-line
  corrections ride along in W3's commit — §3.4's `[runtime]
  available_agents` → `[agent] available_agents`, and §3.2's
  "stub at EVERY level" wording → the depth-conditional stub policy
  (test-only; production `tdMkWorker = Nothing` unchanged).