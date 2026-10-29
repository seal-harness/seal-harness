# Project Context (Maintained by Orchestrator)

## Tooling
- Language: Haskell (GHC2021, GHC 9.12, -Wall -Werror)
- Build: cabal (via `make build`)
- Test: hspec + QuickCheck (via `make test`)
- Lint: hlint (via `make lint`)
- Full gate: `make check` (build + test + lint)
- Frontend: React 18 + TS + Vite + Tailwind, embedded via file-embed
- Nix flake dev shell (never install GHC/cabal/hlint directly)

## SIGPIPE Pitfall
Never pipe Haskell binaries through head/tail. Redirect to file, then read.

## Completed Work Units
| WU | Title | Key Files | Status |
|----|-------|-----------|--------|

## Established Patterns
- SessionMeta: record with tolerant FromJSON (.:? + .!= defaults)
- Opcode: TrustedOpcode with toAuthorize (pure Value -> Either Text ()) and toRun
- buildSessionRegistry: per-turn registry construction in TurnEngine
- buildChildRegistryAdapter: inline registry in delegation worker (NOT via buildSessionRegistry)
- secretManageOp: VaultRuntime -> ChannelCaps -> Opcode (Trusted)
- VaultRuntime: global handle, vrHandleRef :: IORef (Maybe VaultHandle)

## Key Files
- src/Seal/Session/Meta.hs — SessionMeta record + ToJSON/FromJSON
- src/Seal/ISA/Ops/Secret.hs — SECRET_MANAGE opcode
- src/Seal/Core/TurnEngine.hs — buildSessionRegistry (~261), buildChildRegistryAdapter (~1341)
- src/Seal/Session/Store.hs — newSessionMeta/newSession/initSession/initSessionMeta
- src/Seal/Gateway/API.hs — handleTabNew/handleSessionNew/handleSessionRebindNew
- src/Seal/Agent/Runtime/Delegation/Worker.hs — writeChildMeta, mkDelegateWorker

## Merge Hotspots
- seal-harness.cabal — exposed-modules + other-modules
- test/Main.hs — wire test modules