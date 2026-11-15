# Release pipeline: silent UI-less binaries (2026-11-15)

## Symptoms → root cause

Investigating why the `beta-0` tag produced no release turned up a larger
defect: **every binary ever published was UI-less.**

- `release.yml` matched only `tags: ["v*"]`, so `beta-0` triggered nothing and
  the workflow had never run at all.
- `Seal.Gateway.Embedded` splices `frontend/dist` with `file-embed` behind a
  compile-time `doesDirectoryExist` guard. `frontend/dist` is gitignored, and
  a flake's source is the git tree, so in CI the directory never existed and
  the splice took its empty branch.
- Nothing executed the packaged binary, so `404 "No UI embedded in this build"`
  shipped unnoticed across the whole `latest` history.

The three other `file-embed` sites (`config/templates/*`, `config/skills/*`,
`github-known-hosts`) point at **tracked** files and worked fine. That
asymmetry is the diagnostic: strings from those payloads were present in the
binary; strings from the built frontend were not.

## Durable lessons

1. **A `file-embed` splice over a gitignored path is a build-configuration
   dependency, not a code dependency.** The Haskell was correct and always had
   been. The fix belonged in `flake.nix` (build the frontend with
   `buildNpmPackage` and splice it into the project source), not in the module.
   Before changing code, check whether the guard's *input* can ever exist.

2. **`file-embed` gives you a differential test.** Embed a known-tracked file
   and a known-generated one; if the tracked payload is in the binary and the
   generated one is not, the splice works and the input is missing. This
   separates "the embedding is broken" from "the input was never there" in one
   command.

3. **Never publish an artifact you have not executed.** A five-line smoke test
   (boot it, `GET /`, assert the UI) would have caught this on day one. It is
   now a required step in both the gate and the release build, and publishing
   is downstream of it.

4. **The gate must be shared, not copied.** `release.yml` had its own build
   path with no tests, no hlint, no frontend suite. Extracting one reusable
   `workflow_call` workflow that both `ci.yml` and `release.yml` invoke makes
   "the tag ran the same checks as main" structural rather than aspirational.

5. **A reusable-workflow call in a `workflow_dispatch` run checks out the
   default branch.** So releasing an older tag would have gated `main`'s code
   and published the tag's. Any ref the callee must honor has to be an explicit
   input and passed through.

6. **Two producers of one hash must agree on the algorithm.** `make` stamped the
   embed sentinel with `shasum` (SHA-1) while the flake used `sha256sum`. Same
   dist, different digest, depending on who built it. Cross-check the two paths
   and assert the format in a test.

7. **Reproducible archives need `gzip -n`.** Pinning tar mtimes is not enough:
   gzip writes its own timestamp into header bytes 4–7, so byte-identical tar
   payloads still hash differently per run. bsdtar (macOS) also has no
   `--mtime`/`--owner`, so pin the file's mtime first.

8. **Touching a `file-embed` module does not reliably recompile it.** A
   mutation test appeared to pass because the stale splice was still embedded.
   Verify a mutation actually applied *and* that the module rebuilt (delete
   `dist-newstyle`, or confirm a `Compiling …` line) before trusting a green
   result. This is the same trap recorded in
   `2026-11-07-config-templates-and-host-default-learnings.md` §1.

9. **A test that skips on clean checkouts is not covering the release.** The
   `EmbeddedSpec` "count > 0" cases silently skipped wherever `frontend/dist`
   was absent — i.e. in every clean CI build. `make check` was therefore weaker
   in CI than on a developer machine. Building the UI inside nix makes those
   tests run for real.
