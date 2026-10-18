# Project Context (Maintained by Orchestrator)

## Tooling
- Package manager / build: `nix develop` + `cabal` (via Makefile wrappers)
- Build: `make build` (cabal build all, inside nix develop)
- Test runner: `make test` (`cabal test`); frontend `vitest`
- Linter: `make lint` (`hlint src/ test/`)
- Full gate: `make check` = build + test + lint
- Frontend: React 18 + TS + Vite + Tailwind
- Frontend gate: `cd frontend && npm run build` (tsc + vite; must exist before
  cabal build) + `npm run test`

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
- Provider module shape (mirror `Seal.Providers.Anthropic`/`Seal.Providers.Ollama`):
  pure `encodeRequest`/`decodeResponse` + `sendX` HTTP + `withApiKey` CPS for
  the bearer header; `Manager` field on the provider record; `mkX :: Manager -> ... `
  constructor; `httpErrorText` special-cases 429/401.
- `withApiKey :: ApiKey -> (ByteString -> r) -> r` (Secrets.hs) — key bytes only
  live inside the continuation.
- Provider modules are FORBIDDEN to import `System.Process`/`System.Directory`/
  `System.Posix`/`Servant.*`.

## Active Services
See `docs/plans/active-plan.md`.
