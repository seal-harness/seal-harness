# Execution State
<!-- updated: 2026-10-19 -->

Plan: `docs/superpowers/plans/2026-10-19-openai-compat-provider-plan.md`
Issue: #271 · PR: #272 (draft)

## Current Position
- Active work unit: #273 WU-3 (CLI: add/list/test/remove/default/login by instance)
- Current phase: IMPLEMENT (#273 design rev 5 / plan v3 approved for build)
- Retry count: 0

## Work Unit Status
| WU | Status | Phase | Retries | Commits |
|----|--------|-------|---------|---------|
| WU-1 (rename) | COMPLETE | COMMITTED | 0 | cba6e27 |
| WU-1 (transport) | COMPLETE | COMMITTED | 0 | a402195 |
| WU-2 (catalog/URL/status) | COMPLETE | COMMITTED | 0 | 87cf89a |
| WU-2b (legacy copy, new -p) | COMPLETE | COMMITTED | 0 | 88b3625 |
| WU-3 (model `Maybe`) | COMPLETE | COMMITTED | 0 | 0fc85bc |
| WU-4 (config migration) | COMPLETE | COMMITTED | 0 | e510151 |
| WU-5 (CLI) | COMPLETE | COMMITTED | 0 | 3b5f6d4 |
| WU-6 (gateway) | COMPLETE | COMMITTED | 0 | 5ba5066 |
| WU-6 (gateway) | TODO | — | 0 | — |
| WU-7 (frontend) | COMPLETE | COMMITTED | 0 | 0199d9e |
| WU-8 (#271 docs) | COMPLETE | COMMITTED | 0 | 6881dd6 |

## #273 — named provider instances (same branch/PR)

| WU | Status | Phase | Commits |
|----|--------|-------|---------|
| WU-0 (Name module) | COMPLETE | COMMITTED | 37e9cc8 |
| WU-1 (config + migration + instances) | COMPLETE | COMMITTED | 9118652 |
| WU-2 (registry instances) | COMPLETE | COMMITTED | ee41c6e |
| WU-3 (CLI) | IN-PROGRESS | IMPLEMENT | — |
| WU-4a (gateway reads) | TODO | — | — |
| WU-4b (gateway mutations) | TODO | — | — |
| WU-5 (frontend) | TODO | — | — |
| WU-6 (remove legacy API + docs) | TODO | — | — |

Gate status for #273: design rounds 1–3 (5 agents each, rev 5 = §11
authoritative), plan round 1 (Scope PASS; Feasibility/Completeness blockers
fixed by adopting the scope review's simplifications: no
`/api/provider-types`, no instance cap, three delete behaviours,
`adProviders` deleted). WU-0/1/2 are in and green (3259 examples, hlint clean).

Notes for the next unit:
- `providerInstances` + `instanceCredentials` + `resolveInstance` +
  `configuredInstances` + `instanceAuthStatus` + `resolveDefaultModelFor` +
  `instanceLabelList` are the instance API the CLI/gateway should move to.
- The old `KnownProvider`-shaped API is still exported (strangler); WU-3 ports
  `Command/Provider` + `Model` + `New`, WU-4 ports the gateway, WU-6 deletes.
- Migration: rev-6 correction — pointer-only still synthesizes the section
  (design §11.9).

## Checkpoints
- after WU-1 (transport green) — delivered
- after WU-2b (contract consumed by later units) — delivered (PR #272 reviewable)
- after WU-6 (backend complete) — delivered
- final gate — `make check`: 3207 examples, 0 failures, hlint clean;
  `make frontend-test`: 627 tests, 24 files

## Notes
- Gate status at WU-6: `make check` green — 3207 examples, 0 failures, hlint
  clean.
- `Seal.Agent.Runtime.Registry > agentStatus > records Crashed when the worker
  throws` is flaky under full-suite load (passes in isolation and on re-run);
  pre-existing and unrelated.
- `defaultOpenRouterBaseUrl` no longer exists: the endpoint/model constants live
  in `Seal.Providers.Registry` (`legacyOpenRouterBaseUrl`,
  `legacyOpenRouterModel`) and are shared with the migration.
