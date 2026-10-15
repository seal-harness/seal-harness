# Project Context (Maintained by Orchestrator)

## Tooling
- Build: `make build` (cabal build all, inside nix develop)
- Test: `make test` (cabal test)
- Lint: `make lint` (hlint src/ test/)
- Full gate: `make check` (build + test + lint)
- Frontend: React 18 + TS + Vite + Tailwind, tests via vitest
- Frontend build: `cd frontend && npm run build` (must exist before cabal build)

## Completed Work Units
| WU | Title | Key Files | Status |
|----|-------|-----------|--------|

## Established Patterns
- CRUD views: left list pane (280px) + right editor pane, AgentsView/SecretsView/ReposView pattern
- API handlers: `case (requestMethod, pathInfo req) of ...` manual dispatch in `apiApp`
- Vault access: `readIORef (vrHandleRef (adVault deps))` → `Maybe VaultHandle`
- Config access: `srConfigPath (adSessionRuntime deps)` + `updateRuntimeConfig`
- SealRoute GADT in src-gateway-types/Seal/Gateway/Types/Route.hs + openApiMeta in OpenApi.hs
- Route count assertion in test/Seal/Gateway/ApiRouteSpec.hs