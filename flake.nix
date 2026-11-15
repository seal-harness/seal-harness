{
  description = "seal-harness — a harness for secure AI agent execution around the SealOp ISA";

  # Pull pre-built store paths from our public S3 Nix cache. CI signs and pushes
  # to this bucket on every push to main (see .github/workflows/ci.yml). The
  # bucket allows anonymous reads; the trusted public key is what guarantees
  # integrity. Honored automatically in CI (accept-flake-config = true); locally
  # you must be a trusted user or pass --accept-flake-config the first time.
  nixConfig = {
    # cache.iog.io serves haskell.nix's prebuilt GHCs and Hackage deps — without
    # it, Nix compiles GHC from source (multi-hour). Must stay in sync with the
    # compiler-nix-name below: ghc9122 is prebuilt and cached there.
    extra-substituters = [
      "https://cache.iog.io"
      "https://seal-harness-nix-cache.s3.us-east-1.amazonaws.com"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
      "seal-harness-cache-1:CV7Ptf9uZ7QxK2GuHWdk0EVFqho0kc2Ftjd+gz64uCo="
    ];
  };

  inputs = {
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    haskellNix.url = "github:input-output-hk/haskell.nix";
  };

  outputs = { self, nixpkgs, flake-utils, haskellNix }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [
          haskellNix.overlay
          (final: _prev: {
            sealHarnessProject =
              final.haskell-nix.cabalProject' {
                src = projectSrc;
                # Concrete patch version that haskell.nix prebuilds and pushes to
                # cache.iog.io (see nixConfig above). The bare "ghc912" alias
                # resolved to an uncached GHC, forcing a source build in CI.
                compiler-nix-name = "ghc912";
                # Used by `nix develop .` to open a dev shell for
                # `cabal`, `ghcid` and `hlint`.
                shell.tools = {
                  cabal = { };
                  ghcid = { };
                  hlint = { };
                };
                # Frontend toolchain (Phase 7b T0b): `node`/`npm`/`npx` for
                # the Vite build + Vitest + Playwright driver. The browser
                # binary is NOT provided here — `pkgs.chromium` fails to
                # evaluate on darwin (`driverLink not supported`), so the
                # Playwright capstone (T13) runs `npx playwright install
                # chromium` once on first use (the @playwright/test npm
                # package installs the driver + downloads a matching
                # browser into a user cache). These go through mkShell
                # passthrough (NOT `shell.tools`, which is haskell-nix's
                # attrset for Hackage Haskell tools only).
                shell.buildInputs = with final; [
                  nodejs_22
                ];
              };
          })
        ];

        pkgs = import nixpkgs {
          inherit system overlays;
          inherit (haskellNix) config;
        };

        # ─────────────────────────────────────────────────────────────────
        # Frontend build. `frontend/dist` is gitignored, so it is absent from
        # the flake source; without this the `file-embed` splice in
        # Seal.Gateway.Embedded takes its empty branch and `nix build` ships a
        # binary whose `seal serve` has no UI. Building it here makes the UI a
        # reproducible build input, so `nix build` alone yields the
        # self-contained single binary that is the release deliverable.
        # ─────────────────────────────────────────────────────────────────
        frontendSrc = lib.cleanSourceWith {
          src = ./frontend;
          name = "seal-harness-frontend-src";
          filter = path: _type:
            let base = baseNameOf path;
            in !(builtins.elem base [ "node_modules" "dist" ]);
        };

        frontendDist = pkgs.buildNpmPackage {
          pname = "seal-harness-frontend";
          version = "0.1.0";
          src = frontendSrc;
          # Hashes the `deps` tree from package-lock.json. Regenerate when the
          # lockfile changes: `nix run .#prefetch-npm-deps frontend/package-lock.json`.
          npmDepsHash = "sha256-nfdSmqPYGIqFkUUfUugkdF/0t7zT4rsg9oupF3g1sJ4=";
          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp -r dist/. $out/
            # Sentinel read by Seal.Gateway.Embedded.distManifest: identifies
            # which UI build is baked into a binary. Hashes the asset tree,
            # excluding the sentinel itself, which does not exist until now.
            ( cd $out \
              && find . -type f ! -name '.seal-manifest' -print0 \
                 | LC_ALL=C sort -z \
                 | xargs -0 sha256sum \
                 | sha256sum > .seal-manifest )
            runHook postInstall
          '';
        };

        # The flake source with the built dist spliced in, so that the splice
        # in Seal.Gateway.Embedded finds `frontend/dist` at compile time.
        projectSrc = pkgs.runCommand "seal-harness-src" { } ''
          cp -r ${./.} $out
          chmod -R u+w $out
          rm -rf $out/frontend/dist $out/frontend/node_modules
          cp -r ${frontendDist} $out/frontend/dist
        '';

        lib = pkgs.lib;

        flake = pkgs.sealHarnessProject.flake { };

      in flake // {
        # `nix build` produces the seal executable.
        packages.default = flake.packages."seal-harness:exe:seal";

        # `nix build .#frontend` produces the compiled UI on its own.
        packages.frontend = frontendDist;

        # Exposed so `npmDepsHash` above can be regenerated after a lockfile
        # change: `nix run .#prefetch-npm-deps frontend/package-lock.json`.
        packages.prefetch-npm-deps =
          pkgs.runCommand "prefetch-npm-deps-wrapper" { } ''
            mkdir -p $out/bin
            cat > $out/bin/prefetch-npm-deps <<'EOF'
            #!${pkgs.runtimeShell}
            exec ${pkgs.prefetch-npm-deps}/bin/prefetch-npm-deps "$@"
            EOF
            chmod +x $out/bin/prefetch-npm-deps
          '';

        # `nix build .#checks` runs the test suite.
        checks = flake.checks;

        devShells.default = flake.devShells.default;
      });
}
