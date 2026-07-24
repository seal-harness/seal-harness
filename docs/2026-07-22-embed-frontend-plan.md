# Plan: Embed the frontend into the seal binary

## Problem

`make serve` builds the frontend to `frontend/dist/`, but `seal serve` doesn't
know where to find it. The gateway's `gcStaticDir` defaults to `Nothing`
(`src/Seal/Gateway/Config.hs:34`), so `gatewayApp` returns
`{"error":"not found"}` for every non-API path (`src/Seal/Gateway/Server.hs:30`).

Today the only way to serve the frontend is to set `[gateway] static_dir` in
`~/.seal/config/config.toml`. That's acceptable for development but not for
real users — the deployed artifact should be a single binary with the UI
baked in.

## Goal

`seal serve` serves the frontend with no on-disk static directory and no config
file. A single binary is the complete deliverable.

## How Hermes does it (Python reference)

Codebase: `/Users/doug/code/public/hermes-agent`

- `web/vite.config.ts` builds to `outDir: "../hermes_cli/web_dist"` — a
  directory *inside* the installed package.
- `MANIFEST.in` has `graft hermes_cli/web_dist` so the wheel/sdist ships the
  built files.
- `hermes_cli/web_server.py:130` serves `Path(__file__).parent / "web_dist"`
  via FastAPI's `StaticFiles`.

Deployed artifact = Python package with the frontend sitting next to the
server code. Not a single file, but "binary + bundled frontend files in the
package."

## The Haskell equivalent: `file-embed`

Package: https://hackage.haskell.org/package/file-embed

Template Haskell splices file bytes into the binary at compile time:

```haskell
import Data.FileEmbed (embedDir)
import qualified Data.ByteString as BS

frontendAssets :: [(FilePath, BS.ByteString)]
frontendAssets = $(embedDir "frontend/dist")
```

At runtime the server serves from the in-memory `ByteString`s — no filesystem
path needed. One binary, zero external files.

### Availability confirmed

`file-embed-0.0.16.0` resolves cleanly through the haskell.nix flake.
Verified by adding it to `build-depends` and running
`nix develop --command cabal build --dry-run all` — it appears in the
plan-to-nix derivations. No flake.nix changes needed.

## Implementation

### 1. New module `Seal.Gateway.Embedded`

`$(embedDir "frontend/dist")` exposed as a `Map FilePath ByteString` lookup
keyed by relative path (e.g. `"index.html"`, `"assets/index-*.js"`).

### 2. `Seal.Gateway.Server` changes

- `serveStatic` — when `mStaticDir` is `Nothing`, fall back to the embedded
  map. When set, serve from disk (preserves the dev-iteration path: edit +
  `npm run build` without recompiling).
- `gatewayApp` — passes `mStaticDir` through; the embedded fallback is
  consulted inside `serveStatic` so no API change.

### 3. `seal-harness.cabal`

- Add `file-embed` to `build-depends`.
- Add `frontend/dist` to `extra-source-files` so `cabal sdist` includes it
  and the TH splice finds the dir in a source dist.

### 4. Makefile

- `build`/`check` targets build the frontend first (so `cabal build` has
  `frontend/dist` to embed).
- `serve` already builds it (plus the `frontend-install` target added in
  this session).

## The build-ordering gotcha

`embedDir` runs at *compile* time, so `frontend/dist` must exist when
`cabal build` runs. Options:

- **Makefile gate (simplest):** `build: frontend-build` so `make build`
  always builds the frontend first. CI's `make check` already goes through
  the Makefile.
- **Empty-embed fallback:** wrap `embedDir` in a guard that embeds an empty
  list if the dir is missing (keeps `cabal build` working without the
  frontend, but then `seal serve` has no UI until you build it — same as
  today, just with a cleaner story).
- **Nix build hook:** a pre-build phase in the flake that runs
  `npm run build`. Cleanest for `nix build` but more Nix plumbing.

### Recommendation

Makefile gate for `make build`/`check`, plus an empty-embed guard so
`cabal build` alone never hard-fails. The binary ships with the UI baked in;
devs who want hot-reload use `make serve` (which builds the frontend then
runs the disk-path override) or `npm run dev` against a running `seal serve`.

## Effort estimate

~1-2 hours: one new module, ~20 lines of Server.hs changes, cabal/Makefile
edits, and a test that the embedded map contains `index.html`.

## Key files

- `src/Seal/Gateway/Server.hs` — `gatewayApp` (line 25), `serveStatic` (line 35)
- `src/Seal/Gateway/Config.hs` — `defaultGatewayConfig` (line 29),
  `gcStaticDir` (line 24)
- `src/Seal/Command/Serve.hs` — `runServeMain` wiring (line 70)
- `seal-harness.cabal` — library `build-depends` (line 182)
- `Makefile` — `serve` target (line 35), `build` target (line 21)
- `frontend/tsconfig.json` — the frontend build config
- `flake.nix` — haskell.nix cabalProject' (no changes needed)

## Reference: current Makefile serve target

```make
frontend-install: ## Install frontend npm dependencies if missing
	@cd frontend && [ -d node_modules ] || npm install

serve: frontend-install ## Rebuild the frontend, then launch the seal gateway and web server (pass flags via ARGS, e.g. make serve ARGS="--yolo")
	@cd frontend && npm run build
	$(NIX) cabal run -v0 seal -- serve $(ARGS)
```

The `frontend-install` target was added in this session (2026-07-22) to
auto-install `node_modules` when missing. The `serve` target still relies on
the on-disk `frontend/dist` being served via a configured `static_dir`; the
embed work above removes that requirement.