# Developer task runner for seal-harness.
#
# Every recipe runs inside the Nix dev shell (`nix develop --command ...`), so
# you do NOT need cabal, ghc, hlint, or age installed on your host — only Nix.
# Run `make` (or `make help`) to list the available targets.

# Run a command inside the project's Nix dev shell.
NIX := nix develop --command

# Extra arguments for `make run`, e.g. `make run ARGS="--help"`.
ARGS ?=

.DEFAULT_GOAL := help
.PHONY: help build test lint check run tui ghci clean shell

help: ## List the available targets
	@echo "seal-harness — make targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

build: ## Build the library and executable (-Werror)
	$(NIX) cabal build all

test: ## Run the test suite
	$(NIX) cabal test

lint: ## Run hlint over src/ and test/ (must report: No hints)
	$(NIX) hlint src/ test/

check: build test lint ## Build, test, and lint — the full local gate (what CI runs)

run: ## Run the seal executable; pass flags via ARGS="..." (e.g. make run ARGS="--help")
	$(NIX) cabal run -v0 seal -- $(ARGS)

serve: ## Rebuild the frontend, then launch the seal gateway and web server
	@cd frontend && npm run build
	$(NIX) cabal run -v0 seal -- serve

tui: ## Launch the interactive terminal UI (equivalent to `seal tui`)
	$(NIX) cabal run -v0 seal -- tui

ghci: ## Open a GHCi session on the library
	$(NIX) cabal repl

clean: ## Remove build artifacts (dist-newstyle)
	$(NIX) cabal clean

shell: ## Enter an interactive Nix dev shell
	nix develop
