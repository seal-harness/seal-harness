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
.PHONY: help build test lint check run tui ghci clean shell frontend-install frontend-test dist package static

help: ## List the available targets
	@echo "seal-harness — make targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

build: frontend-build ## Build the library and executable (-Werror)
	$(NIX) cabal build all
 
frontend-build: frontend-install ## Build the web UI + stamp sentinel manifest
	@cd frontend && npm run build
	@# sha256sum (not shasum) to match the nix-side frontend build in flake.nix,
	@# so the sentinel has one format regardless of who built it. shasum is
	@# SHA-1 and silently produces a different digest to the same file.
	@# (macOS has no sha256sum coreutils binary; use `shasum -a 256`.)
	@cd frontend/dist && (find . -type f ! -name '.seal-manifest' \
	    | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256) > .seal-manifest

test: ## Run the test suite
	$(NIX) cabal test

lint: ## Run hlint over src/ and test/ (must report: No hints)
	$(NIX) hlint src/ test/

check: build test lint frontend-test ## Build, test, lint, and run the frontend suite — the full local gate

run: ## Run the seal executable; pass flags via ARGS="..." (e.g. make run ARGS="--help")
	$(NIX) cabal run -v0 seal -- $(ARGS)

frontend-test: ## Run the frontend unit tests (vitest)
	@cd frontend && npm test

frontend-install: ## Install frontend npm dependencies if missing
	@cd frontend && [ -d node_modules ] || npm install

serve: frontend-build ## Rebuild the frontend, then launch the seal gateway and web server (pass flags via ARGS, e.g. make serve ARGS="--yolo")
	$(NIX) cabal run -v0 seal -- serve --static-dir frontend/dist $(ARGS)

tui: ## Launch the interactive terminal UI (equivalent to `seal tui`)
	$(NIX) cabal run -v0 seal -- tui

ghci: ## Open a GHCi session on the library
	$(NIX) cabal repl

clean: ## Remove build artifacts (dist-newstyle)
	$(NIX) cabal clean

shell: ## Enter an interactive Nix dev shell
	nix develop

dist: ## Build the portable release artifact (bin/seal + any bundled libs)
	nix build --print-build-logs --max-jobs auto --accept-flake-config .#dist
	@./scripts/check-portability.sh result

package: dist ## Build and package the release tarball (VERSION=... to version it)
	@VERSION="$(VERSION)"; \
	./scripts/package-release.sh "$$(nix eval --impure --raw --expr 'builtins.currentSystem')" "$$VERSION" "seal$${VERSION:+-$$VERSION}-$$(nix eval --impure --raw --expr 'builtins.currentSystem')"

static: ## Build and verify the fully static x86_64-linux binary at ./result-static/bin/seal
	@if [ "$$(uname -s)-$$(uname -m)" != "Linux-x86_64" ]; then \
		echo "error: static builds are supported on Linux x86_64 only" >&2; \
		exit 1; \
	fi
	nix build -o result-static --print-build-logs --max-jobs auto --accept-flake-config .#static
	@file result-static/bin/seal | grep -q 'statically linked' || { \
		echo "error: result-static/bin/seal is not statically linked" >&2; \
		file result-static/bin/seal >&2; \
		exit 1; \
	}
	@echo "ok: $$(file -b result-static/bin/seal)"
codegraph-sigs: ## Print all the type signatures in the project
	codegraph query "" --kind function --limit 10000 --json | node -e "const d=JSON.parse(require('fs').readFileSync(0,'utf8'));d.filter(x=>x.node.language==='haskell'&&x.node.signature).forEach(x=>console.log(x.node.qualifiedName+' :: '+x.node.signature))"
