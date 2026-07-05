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
      "hydra.iohk.io:f/Ya9RnKHEt2yyMf9YYkqxOQfvgrYqaqI1mjGZHkqbk="
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
                src = ./.;
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
              };
          })
        ];

        pkgs = import nixpkgs {
          inherit system overlays;
          inherit (haskellNix) config;
        };

        flake = pkgs.sealHarnessProject.flake { };

      in flake // {
        # `nix build` produces the seal executable.
        packages.default = flake.packages."seal-harness:exe:seal";

        # `nix build .#checks` runs the test suite.
        checks = flake.checks;

        devShells.default = flake.devShells.default;
      });
}
