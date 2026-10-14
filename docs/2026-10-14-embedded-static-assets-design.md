# Seal Harness — Embedded Static Asset Distribution & Serving

**Date:** 2026-10-14
**Status:** Proposal — extends and supersedes the scoping in `docs/2026-07-22-embed-frontend-plan.md` (never implemented)
**Research provenance:** Sub-agent code studies of OpenCode, OpenClaw, and Hermes Agent (2026-10-14; repos at `/Users/zoe/code/{opencode,openclaw,hermes-agent}`). `file-embed` API verified against upstream master (`snoyberg/file-embed`); `wai-app-static` 3.2.1 verified on Hackage. seal-harness tree inspected directly at HEAD.
**Intended repo home after review:** `docs/2026-10-14-embedded-static-assets-design.md`

---

## 1. The question this answers

> Do harnesses bake all the static assets into the harness binary, or serve
> them from a config / system directory?

**Answer: baked into the shipped artifact — universally.** None of the three
reference harnesses use a config/system directory as the primary mechanism.
Config dirs appear only as (a) optional override hatches for special
deployments, and (b) in Hermes, the discovery point for third-party *plugin*
dashboards. In every case the core UI ships inside the same distribution unit
as the server code.

## 2. Research synthesis

### 2.1 OpenCode — embedded in the binary itself (closest analog to file-embed)

- The web UI (`packages/app`, Vite) is built, then the release script
  (`packages/opencode/script/build.ts`) generates a virtual module
  `opencode-web-ui.gen.ts` that imports every dist file with Bun's
  file-embedding loader: `import file_N from "..." with { type: "file" }`.
  `bun build --compile` embeds the whole tree into the single-file
  executable's virtual FS (`/$bunfs/root/`).
- The server serves from that map: `serveUIEffect`
  (`packages/opencode/src/server/shared/ui.ts`) imports the generated map,
  serves exact matches with MIME type + CSP, and SPA-falls-back to
  `index.html`.
- Fallback when the map is absent (dev/source run, or the runtime flag
  `OPENCODE_DISABLE_EMBEDDED_WEB_UI`): **proxy to the hosted UI at
  `https://app.opencode.ai`** — never a local directory. There is no code
  anywhere that reads UI assets from `~/.config/opencode` or XDG dirs.
- The Electron desktop app ships the same assets inside the app bundle
  (`out/renderer` served over a custom `oc://` protocol).

### 2.2 OpenClaw — baked into the npm package, resolved relative to the running code

- Vite builds `ui/` directly into the package's `dist/control-ui/`
  (`ui/vite.config.ts` outDir), shipped in the tarball via `prepack` →
  `npm publish`. A production install has the assets at
  `<node_modules>/openclaw/dist/control-ui/`.
- Runtime resolution (`src/infra/control-ui-assets.ts`): walks candidate
  roots and takes the first containing `index.html` — exec dir, module dir
  (`import.meta.url`), `argv[1]` dir (with symlink realpath handling),
  package-root discovery, cwd. All module/binary-relative.
- `~/.openclaw/openclaw.json` offers only an optional override
  (`gateway.controlUi.root`). Nothing is installed to or served from a
  config dir by default.
- Serving is a hand-rolled `node:http` handler (`src/gateway/control-ui.ts`):
  base-path handling, per-extension content types, SPA fallback to
  `index.html`, 404 for unknown *known-extension* asset paths (so a bad JS
  URL doesn't return HTML), CSP + `X-Frame-Options`, and hardened reads
  (symlink containment, hardlink rejection unless package-proven).

### 2.3 Hermes — baked into the Python wheel as package-data

- Vite outputs `web/` → `hermes_cli/web_dist/` (inside the package); shipped
  via `[tool.setuptools.package-data] hermes_cli = ["web_dist/**/*", ...]`
  (`pyproject.toml`). CI runs `npm run build`, asserts
  `hermes_cli/web_dist/index.html` exists, then `uv build`.
- Runtime (`hermes_cli/web_server.py:78`):

  ```python
  WEB_DIST = Path(os.environ["HERMES_WEB_DIST"]) if "HERMES_WEB_DIST" in os.environ \
             else Path(__file__).parent / "web_dist"
  ```

  Package-relative by default; the env override exists for read-only
  installs — Nix copies the dist to `$out/share/hermes-agent/web_dist`,
  Docker sets `HERMES_WEB_DIST=/opt/hermes/...`.
- Served via FastAPI `StaticFiles` mount + catch-all route with
  `resolve()`-based path-traversal guards and SPA fallback to `index.html`.
- The only genuine config-directory usage across all three harnesses:
  **plugin dashboards** discovered from `~/.hermes/plugins/<name>/dashboard/`
  — extensions, not the core UI.

### 2.4 Consensus

| | OpenCode | OpenClaw | Hermes | seal (proposed) |
|---|---|---|---|---|
| Shipped artifact | single-file binary (Bun compile) | npm tarball | Python wheel | single binary |
| Where assets live | embedded in the executable (virtual FS) | `<pkg>/dist/control-ui` | `hermes_cli/web_dist` (package-data) | in-binary `Map` via file-embed TH |
| Runtime resolution | import embedded map | module/argv/package-root walk | `__file__`-relative + env var | in-memory `Map` lookup (no FS) |
| Dev escape hatch | flag → remote proxy to app.opencode.ai | dev-checkout rebuild script | `HERMES_WEB_DIST` / auto `npm run build` | `[gateway] static_dir` / `npm run dev` |
| Config-dir role | none | optional root override | env override + `~/.hermes/plugins` (extensions) | optional `static_dir` (dev) |

### 2.5 Shared invariants (what to copy)

1. **Assets ship with the code.** Zero install steps, no version skew — the
   UI is always the version the binary/package shipped with. Read-only
   environments are handled by self-locating code or an env/config override,
   never by "install assets into a system dir."
2. **The serving shape is identical everywhere:** exact match → bytes;
   miss + SPA route → `index.html`; miss + asset-like extension → 404;
   per-extension MIME; path-traversal hardening.
3. **Escape hatches are for dev / special deployments only.**

## 3. seal-harness current state (verified 2026-10-14)

- `gatewayApp` (`src/Seal/Gateway/Server.hs:34`): `/api/*` → `apiApp`;
  everything else → `serveStatic` when `mStaticDir` is configured, else a
  bare 404. `gcStaticDir` defaults to `Nothing`, so today `seal serve` ships
  no UI unless the user edits `~/.seal/config/config.toml`.
- `serveStatic` (`Server.hs:71`): disk serving with SPA fallback to
  `index.html`; `contentTypeFor` (`Server.hs:86`) covers 7 extensions.
- **`file-embed` is already a dependency** (`seal-harness.cabal:306`):
  `Seal.SourceControl.GithubKeys` (pinned GitHub known-hosts) and
  `Seal.Skills.Builtins` (built-in skills, each `embedFile` splice paired
  with an explicit `qAddDependentFile`). The Builtins module header states
  the philosophy this plan extends verbatim: *"self-contained: no first-run
  materialization, no install-layout dependency, no staleness across
  upgrades."* TH paths in both modules resolve repo-root-relative, so
  `"frontend/dist"` as a literal splice path matches existing convention.
- `frontend/`: React 18 + TS + Vite 5 + Tailwind; `npm run build` →
  `frontend/dist` with default **content-hashed** asset names
  (`assets/[name]-[hash].js`); the dev server already proxies `/api` →
  `localhost:8080` (`frontend/vite.config.ts`), so hot-reload iteration
  needs zero backend changes.
- `frontend/dist/` is gitignored (`.gitignore:10`); `nodejs_22` is already
  in the nix dev shell (`flake.nix:60`), so `make` recipes have npm inside
  `nix develop`.
- Makefile: `serve` builds the frontend first; **`build`/`check` do not** —
  so CI today would embed whatever stale dist happens to exist (or none).
- The prior plan (`docs/2026-07-22-embed-frontend-plan.md`) scoped this work
  with a Hermes-only reference; it was never implemented — no
  `Seal.Gateway.Embedded` module exists.
- **Latent security gap to fix while we're in here:** `serveStatic` joins
  `pathInfo` segments into a filesystem path without rejecting `..`
  segments (`Server.hs:72–83`) — a traversal request can read files
  outside the configured static dir on the disk path.---

## 4. Design: `file-embed` for seal-harness

### 4.1 Request flow (after)

```
request
  → requestTimingMiddleware
  → /api/*                → apiApp (unchanged)
  → static_dir configured → serveStatic   (disk; dev path — traversal-fixed)
  → otherwise             → serveEmbedded (in-binary Map; release default)
```

Resolution order preserves the dev contract: a configured `[gateway]
static_dir` wins (parity with Hermes' `HERMES_WEB_DIST` and OpenClaw's
`gateway.controlUi.root`); the embedded map is the zero-config default.
No API or config changes.

### 4.2 New module `Seal.Gateway.Embedded`

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
-- | The web frontend's build output (frontend/dist), embedded into the
-- binary at compile time so `seal serve` needs no on-disk static dir and
-- no config. Same philosophy as Seal.Skills.Builtins: the UI is always
-- the version the binary shipped with.
module Seal.Gateway.Embedded
  ( embeddedAssets      -- :: Map FilePath ByteString
  , embeddedAssetCount  -- :: Int
  ) where

import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir, embedOneStringFileOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Language.Haskell.TH (Exp, Q)
import Language.Haskell.TH.Syntax (runIO)
import System.Directory (doesDirectoryExist)

-- | Frontend bytes keyed by forward-slash path relative to the dist root
-- ("index.html", "assets/index-De3F1a.js"). embedDir properties (verified
-- in file-embed source): recursive, sorted, dot-prefixed entries skipped
-- (so the .seal-manifest sentinel never appears in the served map), and
-- every embedded file registered with qAddDependentFile.
embeddedAssets :: Map FilePath ByteString
embeddedAssets = Map.fromList $(embedDistOrEmpty "frontend/dist")

-- | Sentinel written by `make frontend-build` (a hash over the dist tree).
-- Changes on every UI build, forcing this module to recompile so the
-- embedDir splice re-runs. This closes file-embed's documented caveat that
-- *newly added* files don't reliably retrigger recompilation — which is
-- the default case for us, since Vite emits new hash-named files each
-- build. Fallback file (committed) keeps `cabal build` working from a
-- clean checkout with no dist.
distManifest :: String
distManifest = $(embedOneStringFileOf
  [ "frontend/dist/.seal-manifest"
  , "config/frontend-dist-absent.txt" ])

-- | embedDir that degrades to an empty list when the directory is absent
-- (pure nix build of a gitignored tree; fresh checkout). A UI-less binary
-- behaves exactly like today's no-static-dir configuration.
embedDistOrEmpty :: FilePath -> Q Exp
embedDistOrEmpty dir = do
  exists <- runIO (doesDirectoryExist dir)
  if exists then embedDir dir else [| [] |]

embeddedAssetCount :: Int
embeddedAssetCount = Map.size embeddedAssets
```

### 4.3 `Seal.Gateway.Server` changes

```haskell
-- gatewayApp: replace the bare-404 branch
      _ -> case mStaticDir of
        Just staticDir -> serveStatic staticDir req respond
        Nothing        -> serveEmbedded req respond

-- | Serve from the compile-time-embedded asset map. Traversal is
-- structurally impossible (pure Map lookup, no filesystem involved).
-- SPA routes fall back to the embedded index.html; misses on asset-like
-- extensions 404 (OpenClaw pattern) so a bad asset URL never returns HTML.
serveEmbedded :: Application
serveEmbedded req respond =
  let segs = pathInfo req
      key  = T.intercalate "/" segs
  in case Map.lookup key embeddedAssets of
       Just bytes -> respond (embeddedResponse segs bytes)
       Nothing
         | isAssetPath segs -> respond notFoundResponse
         | Just idx <- Map.lookup "index.html" embeddedAssets ->
             respond (indexResponse idx)
         | otherwise -> respond notFoundResponse

-- | Traversal fix for the existing disk path: reject "", ".", ".."
-- segments before joining (closes the gap at Server.hs:72-83).
serveStatic staticDir req respond =
  let segs = pathInfo req
  in if any (`elem` ["", ".", ".."]) segs
       then respond notFoundResponse
       else -- existing disk logic, now with the cache policy below
```

`isAssetPath` = any segment's final component has a known static extension
(`.js .css .map .json .png .svg ...`). `contentTypeFor` gets the missing
extensions: `.mjs .map .wasm .woff .woff2 .ttf .otf .webp .jpg .jpeg .txt
.webmanifest`.

### 4.4 Cache policy (harness-informed)

- `assets/*` hits (Vite emits content-hashed names) →
  `Cache-Control: public, max-age=31536000, immutable`.
- `index.html` and SPA fallbacks → `Cache-Control: no-cache`, so clients
  revalidate and pick up new asset hashes on upgrade. (This is exactly
  OpenClaw's policy; Hermes does the same for injected `index.html`.)
- Both disk and embedded paths use the same policy helper.

### 4.5 Build ordering & the recompile-staleness gotcha

- `embedDir` runs at *compile* time → `frontend/dist` must exist when
  `cabal build` runs. Gate it in the Makefile (everything runs inside the
  nix dev shell, which already provides nodejs_22):

  ```make
  frontend-build: frontend-install ## Build the web UI + stamp sentinel manifest
  	@cd frontend && npm run build
  	@cd frontend/dist && (find . -type f ! -name '.seal-manifest' \
  	    | LC_ALL=C sort | xargs shasum | shasum) > .seal-manifest

  build: frontend-build ## Build the library and executable (-Werror)
  check: build test lint  # inherits the gate — CI runs make check
  ```

- Staleness analysis (the subtle part): current `file-embed` registers
  every embedded file via `qAddDependentFile`, so *edited* files retrigger
  recompilation of the embedding module. But its own docs warn that
  *newly added* files may not — and Vite's `emptyOutDir` (default on)
  wipes and rewrites the whole tree with fresh hash names every build, so
  "all new files" is our normal case. In practice the wipe churns
  dependent-file state enough to force recompiles, and Vite's output churns
  mtimes regardless; the `.seal-manifest` sentinel makes it a guarantee
  instead of an accident: any UI build changes the manifest, which changes
  the module's embedded bytes, which forces the recompile.
- Repo convention note: `Seal.Skills.Builtins` pairs each `embedFile` with
  an explicit `qAddDependentFile`, claiming plain `embedFile` doesn't
  register deps. Upstream master *does* register (verified in source).
  Either the comment is stale or the pinned version predates it — worth
  checking when implementing; the sentinel approach is robust either way.

### 4.6 Cabal / sdist / nix

- No new `build-depends` needed — `file-embed` is already there
  (`seal-harness.cabal:306`).
- **Do not** add `frontend/dist` to `extra-source-files` for now: the dir
  is a gitignored build artifact, and `cabal sdist` from a clean checkout
  would fail on missing files. Release discipline is "build the frontend
  before building the binary" (same as OpenClaw's `prepack` and Hermes'
  CI), not "ship sources of artifacts."
- Nix, three regimes:
  1. `nix develop … cabal build` (dev shell): runs in the repo checkout,
     dist exists on disk → embed works.
  2. Pure `nix build` today: flake source = git-tracked files only →
     gitignored dist absent → `embedDistOrEmpty` yields `[]` → **UI-less
     binary that still builds and serves the API** (exactly today's
     behavior, so nothing regresses).
  3. M3 (below): make pure release builds embed the UI.

### 4.7 Dev workflow

- **Release/default:** `seal serve`, no config → embedded UI.
- **Hot iteration:** `npm run dev` (Vite dev server on :5173 proxying
  `/api` → :8080 — already configured). No recompile involved.
- **Fresh-disk-without-recompile:** set `[gateway] static_dir` to
  `frontend/dist`. Implementation detail to verify: whether `seal serve`
  has a CLI flag for static_dir (check `Seal/Command/Serve.hs` wiring);
  if yes, `make serve` should pass it so the just-built dist wins over a
  possibly-stale embedded copy.

### 4.8 Security

- Embedded serving: traversal structurally impossible (Map lookup, no FS);
  segments still validated defensively.
- Disk path: reject `""`, `.`, `..` segments (fix above).
- Asset-extension misses 404 instead of returning HTML (OpenClaw pattern).
- CSP header on static responses: defer to M4 — the gateway serves the API
  on the same origin, so the policy needs joint review with the API
  surface first.

### 4.9 Testing

- `test/Seal/Gateway/EmbeddedSpec.hs`: when `embeddedAssetCount > 0`,
  assert `"index.html"` is a key; keys are relative, forward-slash, and
  contain no `..` segments. Tolerate `count == 0` (nix/fresh checkout) —
  assert the manifest path instead.
- Extend `test/Seal/Gateway/ServerSpec.hs` with the embedded app (existing
  `ApiTestHarness` pattern): `GET /` → 200 `text/html` + `no-cache`;
  `GET /assets/<known embedded key>` → 200, bytes equal, `immutable`;
  `GET /some/spa/route` → 200 `index.html`; `GET /assets/nonexistent.js`
  → 404; traversal probes (`/../`, `/..%2f`) → no 200. Disk-path traversal
  test with a temp static dir.
- Optional later: Playwright smoke against the built binary (the frontend
  already has a Playwright setup).

### 4.10 Rollout

- **M1 — core embed + serving (~half day):** `Seal.Gateway.Embedded`,
  `serveEmbedded`, `gatewayApp` fallback, MIME/cache policy, traversal
  fix, unit + WAI tests. Done when `make build && cabal run seal -- serve`
  serves the UI with zero config and `make check` is green.
- **M2 — pipeline (~1–2 h):** Makefile gates + `.seal-manifest` stamp,
  `make serve` static_dir wiring, verify CI (runs `make check`, needs npm
  access).
- **M3 — nix purity (deferred, ~2–4 h):** options: (a) accept UI-less
  pure builds, (b) override the flake source filter to include
  `frontend/dist` when present + build dist in release CI before
  `nix build` **(recommended)**, (c) full nix-side npm build with
  `prefetch-npmjs`-style dependency fetching.
- **M4 — optional:** CSP header, embedding the static Swagger UI page
  (`API.hs`), precompressed gzip assets if the bundle grows.

### 4.11 Rejected alternatives

- **`wai-app-static` 3.2.1 embedded backend** (`WaiAppStatic.Storage.Embedded`
  — real, consumes file-embed output, adds mime-types + ETag): rejected —
  a new dependency tree for behavior we hand-roll in ~40 lines with full
  SPA-fallback and cache-control authority.
- **`file-embed` `dummySpace`/`inject` post-compile patching** (yesod
  devel trick): rejected — solves patching bytes into prebuilt exes; Vite
  dev server + `static_dir` cover hot iteration.
- **Committing `frontend/dist` to git:** rejected — build artifact in VCS,
  merge churn, defeats the Makefile gate story.
- **Config/system directory as primary mechanism:** rejected — no
  reference harness does it; version-skew risk; breaks the
  single-binary deliverable.

### 4.12 Risks & open questions

1. Binary size grows by the dist (~1–3 MB React bundle) — negligible.
2. TH compile cost of splicing MBs — one-module blast radius; mild.
3. Recompile staleness — mitigated by the sentinel (see 4.5); verify
   GHC's behavior with wiped/missing dependent files during M1.
4. Pinned `file-embed` version behavior vs. the stale Builtins comment
   (see 4.5) — check the resolved version during M1.
5. `make serve` freshness gotcha (embedded copy can lag the just-built
   dist until recompile) — resolved by M2's static_dir wiring.
6. Pure nix builds ship UI-less until M3 — acceptable (matches today),
   but the release pipeline must use the gated path meanwhile.
7. sdist-based distribution is deliberately out of scope (see 4.6).

## 5. Why this is right for seal

This plan makes seal's distribution model match the strongest reference
(OpenCode — true single-binary embed) rather than the weaker ones
(OpenClaw's package-dir layout, Hermes' wheel), while keeping the dev-loop
escape hatches all three harnesses consider essential. It also completes
an invariance seal already claims in `Seal.Skills.Builtins` — self-contained,
no first-run materialization, no staleness across upgrades — and extends it
from skills to the UI. The core is ~150 lines of Haskell, one Makefile
gate, and a sentinel file; everything else is testing and pipeline
discipline.