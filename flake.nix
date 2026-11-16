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

        # ─────────────────────────────────────────────────────────────────
        # Portability: a release binary must run on a machine with no Nix.
        #
        # On macOS a fully static Haskell executable is not attainable (Apple
        # ships no static libSystem, and the RTS needs system frameworks), so
        # instead the non-system dylibs are bundled beside the binary and their
        # install names rewritten to @executable_path. The executable then links
        # only against /usr/lib and /System/Library.
        #
        # On Linux the release artifact is a fully static musl ELF, built as a
        # cross build from glibc (build platform) to musl (host platform).
        # `pkgsCross.musl64` supplies static gmp, ncurses, libffi, etc., and
        # haskell.nix adds `-optl=-static` to every executable when the host
        # platform is musl. The result has no dynamic loader, so it runs on any
        # recent x86_64 Linux machine without Nix.
        # ─────────────────────────────────────────────────────────────────
        pkgsMusl = pkgs.pkgsCross.musl64;

        staticProject = pkgsMusl.haskell-nix.cabalProject' {
          src = projectSrc;
          compiler-nix-name = "ghc912";
        };

        staticExe = staticProject.hsPkgs.seal-harness.components.exes.seal;

        sealDist =
          if pkgs.stdenv.isDarwin
            then darwinBundle
            else if system == "x86_64-linux"
              then staticExe
              # Other Linux architectures still ship the dynamic build until a
              # matching musl target is added; CI releases only x86_64-linux.
              else flake.packages."seal-harness:exe:seal";

        darwinBundle = pkgs.runCommand "seal-dist-darwin"
          {
            # install_name_tool/otool come from cctools; codesign is NOT a
            # separate package on macOS — it lives in the SDK, so reference it
            # by absolute path rather than through PATH.
            nativeBuildInputs = [ pkgs.darwin.cctools ];
            CODESIGN = "/usr/bin/codesign";
          }
          ''
            mkdir -p $out/bin/dylibs
            cp ${flake.packages."seal-harness:exe:seal"}/bin/seal $out/bin/seal
            chmod u+w $out/bin/seal

            # Rewrite every non-system dependency to a sibling lookup and copy
            # the library in. `otool -L` supplies the exact set, so this cannot
            # drift as the closure changes.
            deps=$(otool -L $out/bin/seal \
                   | tail -n +2 \
                   | sed 's/^[[:space:]]*//; s/ (compatibility.*//' \
                   | grep -v '^/usr/lib/' \
                   | grep -v '^/System/' \
                   | grep -v '^@executable_path/' || true)

            for dep in $deps; do
              base=$(basename "$dep")
              cp "$dep" "$out/bin/dylibs/$base"
              chmod u+w "$out/bin/dylibs/$base"
              install_name_tool -id "@executable_path/dylibs/$base" "$out/bin/dylibs/$base"
              install_name_tool -change "$dep" "@executable_path/dylibs/$base" "$out/bin/seal"
            done

            # Bundled libraries can depend on each other (libiconv ->
            # libcharset), so resolve their store references the same way.
            for lib in $out/bin/dylibs/*.dylib; do
              [ -e "$lib" ] || continue
              subdeps=$(otool -L "$lib" \
                        | tail -n +2 \
                        | sed 's/^[[:space:]]*//; s/ (compatibility.*//' \
                        | grep -v '^/usr/lib/' \
                        | grep -v '^/System/' \
                        | grep -v '^@executable_path/' || true)
              for dep in $subdeps; do
                base=$(basename "$dep")
                if [ ! -e "$out/bin/dylibs/$base" ]; then
                  cp "$dep" "$out/bin/dylibs/$base"
                  chmod u+w "$out/bin/dylibs/$base"
                  install_name_tool -id "@executable_path/dylibs/$base" "$out/bin/dylibs/$base"
                fi
                install_name_tool -change "$dep" "@executable_path/dylibs/$base" "$lib"
              done
            done

            # Re-sign after rewriting: install_name_tool invalidates the
            # signature, and arm64 refuses to run an invalidly signed binary.
            $CODESIGN --force --sign - $out/bin/dylibs/*.dylib
            $CODESIGN --force --sign - $out/bin/seal
          '';

        lib = pkgs.lib;

        flake = pkgs.sealHarnessProject.flake { };

      in flake // {
        packages = {
          # `nix build` produces the seal executable.
          default = flake.packages."seal-harness:exe:seal";

          # `nix build .#dist` produces the portable release artifact: a bin/
          # tree holding `seal` plus any libraries it needs beside it. This is
          # what gets packaged as a tarball.
          dist = sealDist;

          # `nix build .#frontend` produces the compiled UI on its own.
          frontend = frontendDist;

          # Exposed so `npmDepsHash` above can be regenerated after a lockfile
          # change: `nix run .#prefetch-npm-deps frontend/package-lock.json`.
          prefetch-npm-deps =
            pkgs.runCommand "prefetch-npm-deps-wrapper" { } ''
              mkdir -p $out/bin
              cat > $out/bin/prefetch-npm-deps <<'EOF'
              #!${pkgs.runtimeShell}
              exec ${pkgs.prefetch-npm-deps}/bin/prefetch-npm-deps "$@"
              EOF
              chmod +x $out/bin/prefetch-npm-deps
            '';
        } // lib.optionalAttrs (system == "x86_64-linux") {
          # On x86_64-linux `.#dist` is already this static ELF; expose it
          # under its own name for direct verification (`make static`).
          static = staticExe;
        };

        # `nix build .#checks` runs the test suite.
        checks = flake.checks;

        devShells.default = flake.devShells.default;
      });
}
