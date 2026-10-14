# Active Plan
<!-- approved: pending -->
<!-- gate-iterations: 0 -->
<!-- user-approved: false -->
<!-- status: pending -->

# Implementation Plan: Embedded Static Asset Distribution & Serving

## Design: docs/2026-10-14-embedded-static-assets-design.md
## Milestones: M1 (core embed + serving) + M2 (pipeline + CLI flag)

## Work Units

### WU-1: Seal.Gateway.Embedded module + config placeholder + cabal wiring
**Title:** Create the embedded assets module with file-embed TH splices
**Spec:** Design §4.2 (module definition), §4.10 M1 steps 1-4
**Dependencies:** None (leaf unit)
**Human Checkpoint:** No

**Files:**
- `config/frontend-dist-absent.txt` — NEW: placeholder content "absent" (fallback for embedOneStringFileOf)
- `src/Seal/Gateway/Embedded.hs` — NEW: embeddedAssets, distManifest, embeddedAssetCount, embedDistOrEmpty
- `seal-harness.cabal` — ADD `Seal.Gateway.Embedded` to library exposed-modules; ADD `Seal.Gateway.EmbeddedSpec` to test-suite other-modules
- `test/Seal/Gateway/EmbeddedSpec.hs` — NEW: unit tests for embedded assets
- `test/Main.hs` — ADD `import qualified Seal.Gateway.EmbeddedSpec` + `Seal.Gateway.EmbeddedSpec.spec`

**TDD:**
- RED: Test `embeddedAssetCount >= 0` (always true, establishes the module compiles and exports)
- RED: When `embeddedAssetCount > 0`, assert `"index.html"` is a key in `embeddedAssets`
- RED: When `embeddedAssetCount > 0`, assert all keys are relative (no leading `/`), use forward slashes, and contain no `..` segments
- RED: Tolerate `count == 0` (fresh checkout / nix) — assert `distManifest` is a non-empty string instead
- GREEN: Implement the module with embedDistOrEmpty, embedOneStringFileOf, export distManifest
- REFACTOR: N/A (minimal module)

**DoD Items:**
1. `config/frontend-dist-absent.txt` exists with content "absent"
2. `Seal.Gateway.Embedded` module compiles under `-Wall -Werror` with `distManifest` exported (no unused-binding warning)
3. `embeddedAssets :: Map FilePath ByteString` is exported and populated when `frontend/dist` exists
4. `embedDistOrEmpty` degrades to empty list when `frontend/dist` is absent (clean checkout builds succeed)
5. `distManifest :: String` is exported and non-empty (falls back to `config/frontend-dist-absent.txt`)
6. `embeddedAssetCount` equals `Map.size embeddedAssets`
7. `EmbeddedSpec` tests pass: index.html is a key when count > 0; keys are relative/forward-slash/no `..`; count == 0 tolerated with manifest assertion
8. `seal-harness.cabal` has `Seal.Gateway.Embedded` in exposed-modules and `Seal.Gateway.EmbeddedSpec` in other-modules
9. `test/Main.hs` wires in `EmbeddedSpec`

**Verification:** `make build && make test` — new tests pass; `make lint` — clean

---

### WU-2: Server changes — serveEmbedded + response helpers + traversal fix + tests
**Title:** Implement embedded serving, disk path hardening, and WAI tests
**Spec:** Design §4.3 (Server changes), §4.4 (cache policy), §4.8 (security), §4.9 (testing), §4.10 M1 steps 5-8
**Dependencies:** WU-1 (Server imports Seal.Gateway.Embedded)
**Human Checkpoint:** Yes — security-sensitive traversal fix + first new serving path

**Files:**
- `src/Seal/Gateway/Server.hs` — MODIFY: add serveEmbedded, response helpers (embeddedResponse, indexResponse, notFoundResponse, emptyEmbedResponse), auxiliary helpers (contentTypeHeader, cacheHeadersFor, nosniffHeader), isAssetPath, assetExtensions, expanded contentTypeFor, route serveStatic through mkSafePath, update gatewayApp fallback
- `test/Seal/Gateway/ServerSpec.hs` — MODIFY: add embedded serving tests + disk traversal tests + cache header tests + nosniff tests
- `src/Seal/Skills/Builtins.hs` — MODIFY: fix stale qAddDependentFile comment (drive-by)

**TDD:**
- RED: `GET /` with no static_dir → 200 `text/html` + `no-cache` + `nosniff` (when assets embedded)
- RED: `GET /assets/<known key>` → 200, bytes match embeddedAssets, `immutable` cache header, `nosniff`
- RED: `GET /some/spa/route` → 200 `text/html` (SPA fallback to index.html)
- RED: `GET /assets/nonexistent.js` → 404 (asset-extension miss, not HTML)
- RED: `GET /user.profile` → 200 (SPA fallback, `.profile` not in assetExtensions)
- RED: Traversal probe `GET /../` → no 200 (not index.html, not any file)
- RED: Traversal probe `GET /..%2fetc%2fpasswd` → no 200
- RED: `X-Content-Type-Options: nosniff` present on all static responses
- RED: Disk-path traversal test with temp static dir: `GET /../` → no 200; `GET /.seal-manifest` → blocked (if blockedNames covers it, else document)
- RED: Disk-path cache headers match embedded-path policy
- RED: Disk-path root `GET /` with static_dir → 200 `text/html` (index.html, not directory listing)
- GREEN: Implement serveEmbedded, helpers, isAssetPath, contentTypeFor expansion, serveStatic via mkSafePath
- REFACTOR: Extract shared helpers (contentTypeHeader, cacheHeadersFor, nosniffHeader) used by both paths

**DoD Items:**
1. `serveEmbedded` serves from `embeddedAssets` Map via case-sensitive `T.intercalate "/"` key lookup (no T.toLower)
2. `embeddedResponse`, `indexResponse`, `notFoundResponse`, `emptyEmbedResponse` all have correct signatures and attach MIME + cache + nosniff headers
3. `contentTypeHeader :: String -> ResponseHeaders` and `cacheHeadersFor :: FilePath -> ResponseHeaders` are defined
4. `isAssetPath` uses the pinned 20-extension list (excludes `.html`), case-insensitive via `T.toLower` on extension only
5. `contentTypeFor` expanded to cover all 21 extensions (case-insensitive, shared by both paths)
6. `nosniffHeader` present on ALL static responses (both embedded and disk paths)
7. `serveStatic` routes through `Seal.Security.Path.mkSafePath` with `WorkspaceRoot`; `PathDoesNotExist` → SPA fallback for non-asset paths, `PathEscapesWorkspace`/`PathIsBlocked` → 404
8a. `serveStatic` special-cases root path (`pathInfo = []` → serve `index.html` directly, bypassing `mkSafePath` which would return the directory itself)
8. `gatewayApp` falls back to `serveEmbedded` when `mStaticDir` is `Nothing`
9. `emptyEmbedResponse` returns helpful HTML when `embeddedAssets` is empty
10. `isAssetPath→404` applied to BOTH embedded and disk paths
11. Stale `qAddDependentFile` comment in `Seal.Skills.Builtins` fixed
12. All ServerSpec tests pass (embedded hit, SPA fallback, asset 404, non-asset dot extension, traversal probes, nosniff, disk-path parity)
13. `make check` is green (build + test + lint)

**Verification:** `make check` — full gate green; `git diff --name-only` — only declared files modified

---

### WU-3: Makefile gates + --static-dir CLI flag (M2)
**Title:** Gate build on frontend-build, add --static-dir CLI flag, wire make serve
**Spec:** Design §4.5 (build ordering), §4.7 (dev workflow), §4.10 M2
**Dependencies:** WU-2 (serveEmbedded must exist for --static-dir to be meaningful)
**Human Checkpoint:** No

**Files:**
- `Makefile` — MODIFY: add `frontend-build` target with .seal-manifest stamping; gate `build` on `frontend-build`; update `serve` to pass `--static-dir frontend/dist`
- `src/Seal/Types/Command.hs` — MODIFY: `CommandServe AutonomyLevel (Maybe FilePath)` + parser with `optional (strOption (long "static-dir" <> metavar "DIR"))`
- `src/Seal/AppMain.hs` — MODIFY: thread `Maybe FilePath` from `CommandServe` to `runServeMain`
- `src/Seal/Command/Serve.hs` — MODIFY: `runServeMain :: AutonomyLevel -> Maybe FilePath -> SealLogger -> IO ()`; override `gcStaticDir` from CLI when present
- `test/Seal/Command/ServeSpec.hs` — MODIFY: update existing `CommandServe Supervised` → `CommandServe Supervised Nothing` and `CommandServe Full` → `CommandServe Full Nothing` (arity change); add new `--static-dir` parser tests

**TDD:**
- RED: `CommandServe` parser accepts `serve --static-dir /path/to/dist` and produces `CommandServe Supervised (Just "/path/to/dist")`
- RED: `CommandServe` parser without `--static-dir` produces `CommandServe Supervised Nothing`
- RED: `runServeMain` with `Just "frontend/dist"` overrides `gcStaticDir` from TOML config
- GREEN: Implement parser change, threading, and config override
- REFACTOR: N/A

**DoD Items:**
1. `frontend-build` Makefile target builds frontend + stamps `.seal-manifest` sentinel
2. `build` target depends on `frontend-build` (cabal build runs after frontend build)
3. `--static-dir` CLI flag added to `seal serve` via optparse-applicative (`optional (strOption (long "static-dir" <> metavar "DIR"))`)
4. `CommandServe` carries `Maybe FilePath` for static dir
5. `runServeMain` accepts `Maybe FilePath` and overrides `gcStaticDir` from TOML when present
6. `make serve` passes `--static-dir frontend/dist`
7. Parser tests pass (with and without --static-dir)
8. Existing `CommandServe Supervised` / `CommandServe Full` assertions in `ServeSpec.hs` updated to `CommandServe Supervised Nothing` / `CommandServe Full Nothing`
9. `make check` is green

**Verification:** `make check` — full gate green; `make build` — frontend built before cabal; `git diff --name-only` — only declared files modified

---

## Dependency Graph

```
WU-1 (Embedded module) ──→ WU-2 (Server changes) ──→ WU-3 (Makefile + CLI)
```

Sequential execution — each WU depends on the previous.

## Security Considerations

- **Trust boundary:** All static assets are compile-time-trusted (embedded via TH). No user-generated content is served.
- **Disk path (dev-only):** `serveStatic` routed through `mkSafePath` (lexical collapse + canonicalize + symlink containment + blockedNames). Handles encoded-path bypasses.
- **Path traversal:** Embedded path is structurally impossible (Map lookup, no FS). Disk path hardened via `mkSafePath`.
- **Content-type confusion:** `isAssetPath→404` on both paths prevents returning HTML for asset-extension misses.
- **MIME sniffing:** `X-Content-Type-Options: nosniff` on all static responses in M1.
- **Dotfiles:** `embedDir` skips dot-prefixed entries (embedded path). `mkSafePath.blockedNames` blocks `.env`/`.seal`/`.ssh`/`.gnupg`/`.netrc` (disk path). `.seal-manifest` not in blockedNames — documented as known limitation for disk path (low impact: hash, not secrets).

## Human Checkpoints

1. **After WU-2:** Security-sensitive traversal fix + first new serving path. Present test results and diff for review before proceeding to WU-3.

## Risks (from design §4.12)

1. Binary size grows by ~1–3 MB — negligible
2. TH compile cost — one-module blast radius; mild
3. Recompile staleness — mitigated by .seal-manifest sentinel (WU-3)
4. `make check` npm coupling (R8) — idempotent frontend-install; decouple if burdensome
5. `isAssetPath` false positives (R9) — pinned extension list excludes non-asset dot extensions
