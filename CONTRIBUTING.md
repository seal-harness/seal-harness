# Contributing to Seal Harness

Thanks for your interest in Seal Harness — a security-first Haskell runtime for
AI agents, built around the SealOp ISA. This guide is what you need to make a
change that lands cleanly. It is deliberately concrete; please read it before
your first PR.

> **The README is the spec.** When behavior is in question, the README and the
> design docs under `docs/superpowers/` are the source of truth.

---

## Ground rules

### 1. Clean-room implementation (non-negotiable)

Seal Harness is a **clean-room** project. Do **not** copy source from, or
reference, any other proprietary or related codebase — not in code, identifiers,
comments, commit messages, PR descriptions, or docs. Implement from the design
docs and public specifications (e.g. the [`age`](https://age-encryption.org)
format) in this repository's own style and `Seal.*` namespace. If you're porting
an idea, port the *idea* and write it fresh.

PRs that reference or paste external proprietary code will be asked to redo the
work clean.

### 2. Security-first

This is security infrastructure. That raises the bar:

- **Never** commit or log secrets, keys, tokens, or vault contents. Secret types
  are opaque by construction (redacted `Show`, no serialization, CPS-only
  access) — keep them that way.
- A proof type's constructor stays **unexported** so it can only be produced
  through its validating smart constructor (`SafePath`, `AuthorizedCommand`, …).
- Found a vulnerability? **Do not open a public issue.** Disclose privately —
  see `SECURITY.md` (in progress); until it lands, email the maintainers.

### 3. Style: follow the `haskell-coder` conventions

The settled house style (enforced by `-Wall -Werror` + a strict warning set and
`hlint`):

- **GHC2021**; situational extensions (`OverloadedStrings`,
  `GeneralizedNewtypeDeriving`, …) go in **per-file** `{-# LANGUAGE #-}` pragmas,
  not `default-extensions`.
- **Whole-module imports** (`import Data.Foo`), with a **qualified alias** for
  collections/text (`import qualified Data.Text as T`) and the bare type name
  where idiomatic (`import Data.Text (Text)`).
- `deriving stock` / `deriving newtype` explicitly; capability-handle records of
  `IO` functions over type classes; **no effect systems**.
- **Errors:** default to `Either Text`. Introduce a bespoke error ADT **only**
  when the program pattern-matches the error to drive control flow — and even
  then, fold report-only failures into one `Text`-carrying catch-all constructor.
- Match the surrounding code's idiom, comment density, and naming.

---

## Claiming and working an issue (the workflow)

This is the canonical process for working any issue — **you can point a human or
an AI agent at this section and it has everything needed to start.** The model is
*claim-by-assignment + draft-PR-first + work-in-the-open*: progress is visible and
reviewable from the first commit, so anyone can comment on your implementation as
it develops.

1. **Claim it — assign the issue to yourself.**
   ```bash
   gh issue edit <NN> --add-assignee @me
   ```
   If someone is already assigned and active, pick a different issue or coordinate
   in a comment first. Leaving a quick "starting on this" comment is courteous.

2. **Branch from an up-to-date `main`.**
   ```bash
   git switch main && git pull
   git switch -c <area>/<short-desc>-<NN>      # e.g. config/seal-paths-12
   ```

3. **Open a *draft* PR immediately — before writing the implementation.**
   Make a scaffold commit (e.g. the failing first test, or an empty stub +
   `WIP`), push the branch, and open the PR **as a draft**:
   ```bash
   git commit --allow-empty -m "WIP: <summary> (#<NN>)"
   git push -u origin HEAD
   gh pr create --draft --fill --body "Closes #<NN>"
   ```
   The draft PR is your workspace in the open. `Closes #<NN>` links it to the
   issue (and closes the issue on merge).

4. **Push as you go.** Commit and push frequently; the draft PR updates live.
   This is the point — reviewers watch and comment on the evolving implementation
   instead of waiting for a big final drop. Respond to comments in subsequent
   pushes.

5. **Follow TDD and keep the gates green** (see *Testing* and *Pull requests*
   below): `cabal build all` (`-Werror`), `cabal test`, `hlint src/ test/`.

6. **Mark the PR "Ready for review"** once the gates pass and the issue's
   Definition of Done is met. Rebase on `main` first so CI runs against current
   `main`.
   ```bash
   gh pr ready
   ```

7. **Iterate to merge.** Address review feedback with more pushes; keep the PR and
   issue conversation as the single coordination point.

If you stop working an issue, **unassign yourself** (`gh issue edit <NN>
--remove-assignee @me`) and say so in a comment, so it's free for someone else.

---

## Development environment

Everything runs through the **Nix flake dev shell** — you do not install GHC,
cabal, or `hlint` yourself.

The `Makefile` wraps the common tasks so you don't have to type the
`nix develop --command …` prefix; run `make` to list targets:

```bash
make            # list available targets
make build      # build the library + executable (-Werror clean)
make test       # run the test suite
make lint       # hlint src/ test/ (must report: No hints)
make check      # build + test + lint (the full local gate)
make tui        # launch the interactive TUI (seal tui)
make run ARGS="--help"   # run the seal executable with arbitrary flags
make shell      # drop into an interactive dev shell
```

Each target is just a thin wrapper; the equivalent raw commands are:

```bash
nix develop                                   # enter the dev shell
nix develop --command cabal build all         # build (-Werror clean)
nix develop --command cabal test              # run the test suite
nix develop --command hlint src/ test/        # lint (must report: No hints)
```

Some features shell out to the [`age`](https://age-encryption.org) binary;
`age` and `age-keygen` are provided by the dev shell. Tests that need a real
binary or hardware token are guarded (`pendingWith`) so the suite stays green
without them.

---

## Testing

We practice **test-driven development**. Write the failing test first, watch it
fail, then make it pass.

- `hspec` + `QuickCheck`. Tests must assert **real behavior** — a property that
  is vacuously true (always passes regardless of the implementation) will be
  sent back. Prefer exact assertions and meaningful generators.
- Keep the suite **fast** (sub-second). Bound QuickCheck generators; never let a
  test create unbounded/deep filesystem trees or block on I/O.
- A new module gets a matching `*Spec` and is wired in three places:
  1. `seal-harness.cabal` → library `exposed-modules:`
  2. `seal-harness.cabal` → test-suite `other-modules:`
  3. `test/Main.hs` → import + run the spec in the aggregate.

  (The cabal file and `test/Main.hs` are the common merge points across parallel
  work — keep edits there minimal and rebase before opening your PR.)

---

## Pull requests

1. **Branch from `main`.** One logical change per PR; keep it reviewable.
2. **Green before review.** All of these must pass locally and in CI:
   - `cabal build all` (`-Werror` clean)
   - `cabal test` (all green, output pristine — no stray warnings)
   - `hlint src/ test/` → `No hints`
3. **Include tests** for new behavior, and reference the issue you're closing
   (`Closes #NN`).
4. **Never** use `git commit --no-verify` or skip CI gates.
5. Write a clear commit message describing the *why*. If a change was AI-assisted,
   you may add a `Co-Authored-By:` trailer.

CI builds and tests on Linux and macOS via Nix; a PR cannot merge red.

---

## Planning & design

Larger work starts as a design doc and an implementation plan under
`docs/superpowers/`:

- `docs/superpowers/specs/` — approved designs (the "what" and "why").
- `docs/superpowers/plans/` — detailed, task-by-task TDD implementation plans.

If you're picking up a code issue, read the referenced design-doc section first —
it defines the module's interface contract so parallel work composes without
conflict.

---

## Where to start

- Issues labeled **`good first issue`** are scoped and self-contained.
- The **`area:*`** labels (`area:commands`, `area:config`, `area:security`,
  `area:ci`) group work by subsystem; **`phase-2`** marks the current milestone.
- The current milestone design lives at
  `docs/superpowers/specs/2026-06-28-phase-2-vault-cli-mvp-design.md`.

Questions are welcome — open a `question` issue or comment on the one you're
working on. Thanks for helping build Seal.
