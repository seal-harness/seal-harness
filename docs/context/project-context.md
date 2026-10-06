# Project Context (Maintained by Orchestrator)

## Tooling
- Build: `nix develop --command cabal build all` (or `make build`)
- Test: `nix develop --command cabal test` (or `make test`)
- Lint: `nix develop --command hlint src/ test/` (or `make lint`)
- Full gate: `make check` (build + test + lint)
- GHC 9.12.4, GHC2021, -Wall -Werror
- Test framework: hspec + QuickCheck
- Frontend: React 18 + TS + Vite + Tailwind (frontend/dist must exist for build)

## Coding Conventions
- `Text` not `String`; `ByteString` for binary; `Vector` for indexed access
- `foldl'` not `foldl`; `modify'` not `modify`; strict fields (`!`) by default
- Whole-module imports; `import qualified Data.Text as T`
- No partial functions; no orphan instances; no `error`/`undefined`
- Records: named-field construction; field names `_<type>_<field>`
- Errors: default to `Either Text`
- `ReaderT AppEnv IO` + Handle pattern; no effect systems

## Completed Work Units
| WU | Title | Key Files | Services Created |
|----|-------|-----------|-----------------|
| WU-1 | SubagentRunRecord — durable tracking foundation | src/Seal/Agent/Runtime/RunRecord.hs | RunRecordRegistry (STM-backed) |
| WU-2 | Foreground (blocking) mode for AGENT_MANAGE start | src/Seal/ISA/Ops/Agent.hs | SpawnMode, handleStartForeground |
| WU-3 | Anti-polling instructions + Phase 2/3 migration + adAllowSpawn | src/Seal/ISA/Ops/Agent.hs, src/Seal/Agent/PromptParts.hs, src/Seal/Core/TurnEngine.hs, src/Seal/Agent/Def/Types.hs, src/Seal/Agent/Def/Workdir.hs | childAutoAnnounceNote, gAllowSpawn gate, allowSpawnBlockedMsg |

## Established Patterns
- STM-backed registries: `newtype Registry = Registry (TVar (Map Key Value))`
- Sidecar completion: forked child threads append to JSONL, turn engine reads at turn start
- Agent runtime: `AgentRuntime (TVar (Map SubagentId AgentInstance))`
- Delegation: `runDelegate` (sync) / `runDelegateAsync` (async with forked threads)
- Spawn gate: `AgentStartGate { gEffectiveRole, gOrchEnabled, gAllowSpawn }` — `gAllowSpawn` (per-def `adAllowSpawn`) overrides role-based default; `authorizeStart` consults it
- Anti-polling: spawn response + completion message carry NO_REPLY instructions; child prompt gets `childAutoAnnounceNote` when it can spawn