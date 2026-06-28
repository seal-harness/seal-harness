{
  description = "seal-harness — a harness for secure AI agent execution around the SealOp ISA";

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
