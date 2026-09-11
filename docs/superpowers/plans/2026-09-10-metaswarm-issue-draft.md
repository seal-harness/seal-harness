# Title

feat: metaswarm sub-agent orchestration — role-gated spawning, def tool allow-lists, <available_agents> catalog

## Summary

Metaswarm-style orchestration (issue → epic → parallel specialist agents →
review gates → PR) does not run correctly on Seal Harness today. This issue
implements full support for collections of agents like metaswarm's
(`issue-orchestrator` → `coder-agent` / `test-automator-agent` / …) as
designed in `docs/superpowers/specs/2026-09-10-metaswarm-orchestration-design.md`
(gate-approved 5/5, revision 6).

Four root causes addressed:

1. **Children cannot orchestrate.** `AGENT_START` is absent from
   `buildChildRegistry`'s base ops entirely (`TurnEngine.hs:319-342`), and
   the `role` field is parsed (`ctRole`, `Delegation.hs:252`) but never
   read. The issue-orchestrator's entire job — spawning sub-agents — is
   impossible.
2. **Tool allow-lists are not enforced.** `buildChildRegistryAdapter`
   (`TurnEngine.hs:971`) discards the `AgentDef` and builds every child
   the same full registry; a def declaring `tools: [FILE_READ]` can still
   write files.
3. **Agents are surfaced actively only.** `AGENT_DEF_LIST` makes the info
   accessible, but unlike skills (injected `<available_skills>` catalog),
   the model must probe first — and workdir defs carry repo-prefixed ids
   (`seal-harness--coder-agent`) it cannot guess without the probe.
4. **Defs are not role-aware.** `decodeAgentDef` (`Workdir.hs:273`) drops
   `role` and `description` frontmatter entirely.

## Scope

In: role/description fields on AgentDef (with injection-safe validators);
role-conditioned nested `AGENT_START` for orchestrator children (always
present, role-gated authorize, depth-capped via threaded parent depth);
per-def tool allow-list enforcement (intersection; blocklist wins);
`<available_agents>` system-prompt catalog with leaf gating + config kill
switch; `registerChild` true-depth recording; workdir⊕user union backend
threaded to children; mini-metaswarm e2e fixture.

Out (non-goals): new opcodes (ISA untouched); async delegation; BEADS/Dolt
integration; frontend work (role badges / delegation-tree view); DirScheme
role support (documented follow-up).

## Definition of Done (independently verifiable)

Design §3.7 (16 tests) + §4 work units:

- [ ] W1 — `adRole`/`adDescription` on `AgentDef`: pure per-field validators
      (single-line, control-char strip, fence-token rejection, 256-char caps;
      provider/model included), both decode paths (flat + protocol),
      `AGENT_DEF_WRITE` accepts/rejects role values + records unknown
      `tools:` names, `AGENT_DEF_LIST` output includes role, stale
      doc-comments fixed (`Agent.hs:391-393`, `Delegation.hs:253-255`).
      Unit tests 1-2 (+3 property).
- [ ] W2 — role-conditioned nested `AGENT_START`: `childBlocklist` pure fn
      at both chokepoints (`filterBlocklisted` + `narrowAllowList`); nested
      child-side `AgentStartWiring` (child depth+1, child-rooted session
      mint, workdir⊕user union backend, `tdMkWorker`-composing re-anchored
      worker); `dwdParentDepth` consumed (dead field today, `TurnEngine.hs:942`);
      `registerChild` records real depth (`Agent.hs:510` hardcodes 0);
      effective-role + kill-switch gate at the resolver; 4 distinguishable
      error messages (depth / leaf / kill-switch / spawn-pause); §3.3
      allow-list intersection. Tests 7-11, 12a, 13-15. W2 exit criterion:
      grandchild-spawn integration test passes.
- [ ] W3 — `<available_agents>` injection (skills-pattern, 4096 budget,
      grouped, role suffix, nudge line) in both prompt paths; leaf children
      get the one-line role note instead; `[runtime] available_agents`
      kill switch. Tests 6, 12b, 14.
- [ ] W4 — mini-metaswarm e2e fixture (design §4.1: demo-project with
      orchestrator/coder/reviewer; scripted conversation drives catalog →
      batch spawn → narrowed registries → results → instances+depths);
      real-provider smoke or manual checklist; allow-list behavior-change
      changelog note; `make check` green; README opcode-table note;
      follow-up issues filed.

Global DoD:

- [ ] The 17-invariant gateway suite (`AgentIntegrationSpec`) still passes
      plus the new invariants.
- [ ] 3-level chain rejected by `max_spawn_depth = 2` with the message
      naming depth vs max; grandchild recorded depth = 2.
- [ ] `make check` (build + test + hlint "No hints") green at each WU merge.

## File scope (expected hotspots)

`src/Seal/Core/TurnEngine.hs`, `src/Seal/Agent/Runtime/Delegation.hs`,
`src/Seal/Agent/Runtime/Delegation/Worker.hs`, `src/Seal/ISA/Ops/Agent.hs`,
`src/Seal/Agent/Def/Types.hs`, `src/Seal/Agent/Def/Workdir.hs`,
`src/Seal/Skills/Prompt.hs` (pattern to mirror — likely a sibling module),
`src/Seal/Config/File.hs`, `seal-harness.cabal`, `test/Main.hs`
(merge hotspots — keep minimal, rebase before PR).

## Human checkpoints

- After W2 (the riskiest unit — nested wiring + depth plumb): review the
  grandchild-spawn test + depth semantics before the catalog work lands.
- PR review before merge (CI gate + `make check`).

## Design + process notes

- Design doc (approved): `docs/superpowers/specs/2026-09-10-metaswarm-orchestration-design.md`
  — design-review gate passed 5/5 (PM, Architect, Designer, Security, CTO),
  2 rounds; round-1 blockers resolved and source-verified in round 2.
- Security posture: def-authoritative role (model can narrow only, never
  widen); per-field validators close the prompt-injection surface; depth
  cap + spawn-pause + timeout + concurrency + per-spawn kill-switch
  re-check bound the spawn tree; def mutation stays parent-only;
  allow-lists only narrow (blocklist wins).
- Test seams: `atoChildWorker`/`tdMkWorker` (stub worker), `ScriptProvider`
  (scripted LLM), `FixtureRepo` (fixture repo) — all existing; the stub
  must compose through nested wiring (W2).
- TDD: failing test first per WU; `make check` gate; branch off main;
  draft PR immediately.