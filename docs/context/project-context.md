# Project Context (Maintained by Orchestrator)

## Tooling
- Package manager / build: `nix develop` + `cabal` (via Makefile wrappers)
- Test runner: `cabal test` (hspec + QuickCheck); frontend `vitest`
- Linter: `hlint src/ test/`
- Full gate: `make check` = build + test + lint
- Frontend gate: `cd frontend && npm run build` (tsc + vite) + `npm run test`

## Completed Work Units
| WU | Title | Key Files | Status |
|----|-------|-----------|--------|

## Established Patterns
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