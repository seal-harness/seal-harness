# Project Context (Maintained by Orchestrator)

## Tooling
- Build/test/lint: `make check` (build + test + lint) — MUST be green before any commit
- Everything runs via Nix: `nix develop --command cabal ...`; never pipe cabal/hlint through head/tail (SIGPIPE hangs) — redirect to a file, then read it
- Run a subset of tests: `nix develop --command cabal run test:tests -- -m "<match>" > /tmp/t.log 2>&1` then read /tmp/t.log
- Test framework: hspec + QuickCheck; suite must stay sub-second; bound all generators
- GHC 9.12, GHC2021, `-Wall -Werror` + strict flag set; no partial functions (head/tail/fromJust/read/!!); strict fields by default; Text not String; whole-module imports; named-field construction; Haddock comments on top-level defs are the norm (follow existing file style); no content-dependent alignment

## Completed Work Units
| WU | Title | Key Files | Notes |
|----|-------|-----------|-------|
| pre-plan | Self-read refusal + search self-exclusion (commit 13b8501) | src/Seal/ISA/Ops/Session.hs, src/Seal/Core/TurnEngine.hs | sessionManageOp/sessionGetOp/sessionSearchOp take the current `session :: SessionId` baked at registry-build time; handleGet refuses `sid == session` before both top-level and child branches; handleSearch filters self from matched/childMatched |

## Established Patterns
- Current-session identity: baked into ops at registry-build time (`sessionManageOp paths searchBackend session`), mirrors `skillManageOp backend session`
- Op guard placement: in `handleGet`'s case, as a guard clause before both the meta branch and child-resolution branch (Session.hs ~:215-225)
- Tests: `runTestApp` harness + `mkPaths` temp-dir SealPaths + `seedConversation`/`seedChildConversation` + `fixedSessionId`/`callerSessionId` helpers in test/Seal/ISA/Ops/SessionSpec.hs
- TDD: write failing test first (observe runtime red with an intentionally-unused binding if needed), minimal implementation, re-run green
- No .cabal/test-Main.hs changes needed unless new modules are added (WU4 only)
