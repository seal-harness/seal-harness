# Execution State
<!-- updated: 2026-10-19 -->

Plan: `docs/superpowers/plans/2026-10-19-openai-compat-provider-plan.md`
Issue: #271 · PR: #272 (draft)

## Current Position
- Active work unit: #273 WU-6 (remove the legacy `KnownProvider` API + docs)
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
| WU-3 (CLI) | COMPLETE | COMMITTED | 944e520 |
| WU-4a (gateway reads) | COMPLETE | COMMITTED | 32eb1fd |
| WU-4b (gateway mutations) | COMPLETE | COMMITTED | 605a1e2 |
| WU-5 (frontend) | COMPLETE | COMMITTED | 0aff4b4 + b8f1bd0 |
| WU-6 (remove legacy API + docs) | TODO | — | — |

Gate status for #273: design rounds 1–3 (5 agents each, rev 5 = §11
authoritative), plan round 1 (Scope PASS; Feasibility/Completeness blockers
fixed by adopting the scope review's simplifications: no
`/api/provider-types`, no instance cap, three delete behaviours,
`adProviders` deleted). WU-0/1/2/3, WU-4a and WU-4b are in and green (3279
examples, 0 failures, hlint clean): the CLI creates/lists/tests/logs in to and
removes named instances, and `/model`/`/new` resolve them; the gateway read
API and session `providerType` speak instances; and POST/PUT/DELETE plus the
default endpoints mutate instances (validation table, immutable type, §11.1
delete, session/tab provider checks), and the frontend now speaks instances
throughout (labels, badges by `providerType`, type→name create flow, problem
rows, per-class delete copy). Only WU-6 remains: delete the legacy
`KnownProvider` API and update the CHANGELOG/docs.
Note: `Seal.Agent.Runtime.Registry > agentStatus > records Crashed` is a
pre-existing flake under full-suite load; re-run before believing a red gate.

Notes for the next unit:
- The gateway now speaks instances on both read and write: rows come from
  `providerInstances`; POST/PUT are validated by `validateInstanceWrite`
  (`BaseUrlPolicy`), DELETE follows §11.1, and sessions/tabs are checked by
  `sessionProviderError`. `/api/providers` and `/all` rows carry `type`,
  `typeDisplayName`, `configured`, `reconfiguring`, `problem`, `defaultModel`;
  session JSON carries `providerType`.
- WU-5 is in and green (tsc + `make frontend-test`: 635 tests, 24 files):
  instance labels in both composers + AgentsView (problem rows disabled),
  problem rows excluded from the default fallback, the ActiveTabs badge keyed
  by `providerType`, and the `ProvidersView` type→name create flow (inline
  validation, Configure/Reconfigure, problem rows delete-only, read-only
  identity in edit, per-class delete copy).
- **WU-6 (remaining):** delete the legacy `KnownProvider` API per the gate
  grep in plan WU-6 (keep `legacyProviderHint`), and update `CHANGELOG.md` +
  the design/plan/execution-state docs (upgrade note, model change, security
  delta).
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
