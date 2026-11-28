# Feature Research: macOS Distribution & Installation

## Summary

Our macOS artifact is a tarball of `bin/seal` plus five bundled dylibs, unsigned,
distributed as a GitHub Release `latest` asset. This research surveys how three
leading harnesses actually get onto a macOS box, to decide what we should copy.

**The headline finding: our binary already works today via `curl`, and the
"Gatekeeper blocks it" problem we documented only affects browser downloads.**
`curl` does not set `com.apple.quarantine` (it sets only `com.apple.provenance`),
so a `curl`-based install path is Gatekeeper-clean *right now*, with no Apple
Developer account. That reframes the priority: a one-line install script is a
much better return than the $99/yr notarization question.

> **Note on provenance:** the intended research sub-agents failed with a
> provider credential error (HTTP 401), so this was gathered by reading the
> three local clones directly. Findings are from source, not summaries.

## Prior Art Survey

### Hermes Agent — Python, `pip`/`uv`, no binary at all

- **Channel:** `scripts/install.sh` (2079 lines) bootstraps a Python environment
  and `pip install`s the package. `pyproject.toml` declares console scripts:
  `hermes = "hermes_cli.main:main"`, `hermes-agent`, `hermes-acp`.
- **Signing:** N/A. Nothing to sign — a Python entry-point shim.
- **Dylibs:** N/A. Dependencies are wheels. They use Homebrew only for *build*
  tools on macOS (`install_build_tools_macos`, `brew install cmake`).
- **UX:** `curl | bash`-style script; upgrades = re-run or `pip install -U`.
- **Verdict: Not applicable.** Their language choice means they never face our
  problem. *But* the `install.sh`-as-primary-channel pattern is exactly the
  point — even a 2000-line installer is preferred over telling users to
  hand-manage a tarball.

### OpenCode — Bun-compiled single binary, `curl | bash`, paid Apple account

- **Channel:** `install` script at repo root; documented as
  `curl -fsSL https://opencode.ai/install | bash`. Installs to
  `$HOME/.opencode/bin/opencode`, `chmod 755`.
- **Single binary, no dylibs.** Release asset is a `.zip` per platform
  (`darwin-arm64`, `darwin-x64`, `linux-x64`, `linux-arm64`, `windows-x64`).
  They ship **one self-contained executable** and never manage sidecar
  libraries — sidestepping our entire `@executable_path` problem by not having
  it. Worth noting we cannot copy this: a single-file Haskell macOS binary is
  what we established is unattainable.
- **Signing:** Yes, but **only for the Electron desktop app**, not the CLI. In
  `.github/workflows/publish.yml`:
  ```yaml
  - uses: apple-actions/import-codesign-certs@...   # v2.0.0
    if: runner.os == 'macOS'
    with:
      keychain: build
      p12-file-base64: ${{ secrets.APPLE_CERTIFICATE }}
      p12-password: ${{ secrets.APPLE_CERTIFICATE_PASSWORD }}
  ```
  driven by `npx electron-builder` with `CSC_KEYCHAIN`, `APPLE_API_KEY`,
  `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`. So: **Developer ID + notarization is
  scoped to the GUI app; the CLI ships unsigned and relies on `curl`.**
- **Smart details worth copying:**
  - **Rosetta detection** — if `darwin` + `x64` but
    `sysctl -n sysctl.proc_translated` returns `1`, they switch to `arm64`.
  - **AVX2 baseline detection** on darwin (`hw.optional.avx2_0`) to fall back
    to a non-AVX2 build.
  - **PATH setup** writes to the right rc file per shell (zsh: `.zshrc`,
    `.zshenv`, `$ZDOTDIR`, XDG paths; bash: `.bashrc`/`.bash_profile`/`.profile`;
    fish: `fish_add_path`), and supports `--no-modify-path`.
  - **`$GITHUB_PATH`** integration for CI.
  - **No `xattr`/`quarantine` handling at all** — because `curl` doesn't
    taint the payload.
- **Verdict: Copy heavily.** The install script, Rosetta guard, and per-shell
  PATH logic are directly reusable. Their signing split (GUI signed, CLI not)
  is strong evidence we don't need a Developer account for the CLI.

### OpenClaw — npm package + separately-signed macOS companion app

- **Channel (CLI):** `npm install -g openclaw@latest` (README "Install
  (recommended)", requires Node ≥22). Also a large `scripts/install.sh` that
  bootstraps pnpm and runs `npm install -g`.
  `openclaw onboard --install-daemon` then installs a launchd user service.
- **Channel (GUI):** a real `.app` distributed as DMG/zip with **Sparkle
  auto-updates**, Developer ID–signed and notarized.
  `docs/platforms/mac/release.md` is a full, honest checklist.
- **Signing:** the *app* is signed/notarized; the *npm CLI* is not (npm
  packages aren't signed/quarantined). Notary credentials via App Store Connect
  API key:
  ```bash
  xcrun notarytool store-credentials "openclaw-notary" \
    --key /tmp/openclaw-notary.p8 --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID"
  ```
  Then `NOTARIZE=1 NOTARYTOOL_PROFILE=openclaw-notary SIGN_IDENTITY="Developer
  ID Application: …" scripts/package-mac-dist.sh`.
- **Notable:** they build **universal (`arm64 x86_64`)** by default for release
  (`BUILD_ARCHS`), and document that `APP_BUILD` must be numeric+monotonic for
  Sparkle comparison.
- **Verdict: Copy the release-doc discipline and the universal-binary idea.
  Their signing applies to the app, not the CLI — same split as OpenCode.**

## Cross-Cutting Patterns

1. **Nobody tells users to hand-manage a tarball.** All three ship an installer
   script or a package manager (`npm -g`, `pip`, or `curl | bash`). Our current
   "download this tarball, extract it, keep the tree together, symlink it
   yourself" is the outlier.
2. **`curl | bash` is the default for compiled CLIs** (OpenCode), and it
   inherently avoids the quarantine flag.
3. **Notarization is only deemed necessary for GUI `.app` bundles.** Both
   projects that pay Apple (OpenCode, OpenClaw) spend it on the desktop app.
   Neither signs its CLI. Two independent data points.
4. **Rosetta/arch handling is done in the installer, not the artifact** —
   detect at install time, download the right arch.
5. **Package-manager channels (`npm`, `pip`) need no signing** because those
   tools don't set quarantine.

## Key Design Decisions for Seal-Harness

1. **Distribution channel:** add a `curl | bash` installer as the primary
   documented path, keep the tarball as the underlying artifact. This is the
   single highest-value change and needs no Apple account.
2. **Signing & notarization:** **do not pursue a Developer ID for the CLI yet.**
   Our Gatekeeper problem is a browser-download problem. Once the documented
   path is `curl`, the problem largely evaporates. Reserve notarization for a
   future GUI app (if any), matching OpenCode/OpenClaw.
3. **Sidecar dylibs:** keep the current `bin/seal` + `bin/dylibs/` layout — the
   installer moves the *whole tree* atomically, so the "binary moved away from
   its sidecars" failure mode is prevented by construction rather than by
   documentation.
4. **Installer UX:** install to `~/.local/share/seal/` (or XDG data dir),
   symlink into `~/.local/bin`, per-shell PATH handling, `--no-modify-path`
   escape hatch, and print the one instruction that matters.
5. **Arch:** ship `aarch64-darwin` and `x86_64-darwin` separately and detect at
   install (including the Rosetta trap).
6. **Homebrew:** a tap is nice-to-have, not required. Our tree is already
   relocatable, so a formula could install the tree to `libexec` and symlink —
   verified working locally.

## Seal-Harness Architecture Fit

- **No opcode work.** Distribution is build/release tooling, not ISA surface.
  Nothing enters the `Backends` record; no new trust level.
- **Files touched:** `scripts/install-macos.sh` (new), `scripts/package-release.sh`
  (ship a README in the tarball), `.github/workflows/{ci,release}.yml`
  (publish + test the installer), `README.md`.
- **Security invariants:** none implicated — no secrets, no `~/.seal/` access.
  The installer must not run as root and must not modify `~/.seal/`.
  Verify a SHA256 before install (we already publish `.sha256`).
- **Interaction with existing opcodes:** none.

## Open Questions

1. Should the installer be a hosted one-liner (`curl -fsSL …/install.sh | bash`)
   from the repo, or served from a versioned URL? Affects supply-chain trust.
2. Do we still want `xattr -dr com.apple.quarantine` in the docs at all? It
   becomes dead advice for `curl` users but still applies to browser downloads.
3. `x86_64-darwin` — is it worth shipping? Apple is phasing it out (our own
   build warns that nixpkgs 26.05 is the last to support it), and we currently
   only build aarch64-darwin.
4. Homebrew tap: now, later, or never?
