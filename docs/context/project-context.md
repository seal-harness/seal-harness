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
| (none yet) | | | |

## Established Patterns
- STM-backed registries: `newtype Registry = Registry (TVar (Map Key Value))`
- Sidecar completion: forked child threads append to JSONL, turn engine reads at turn start
- Agent runtime: `AgentRuntime (TVar (Map SubagentId AgentInstance))`
- Delegation: `runDelegate` (sync) / `runDelegateAsync` (async with forked threads)