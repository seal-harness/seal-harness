# Learnings — gateway host default + first-run config templates

<!-- date: 2026-11-07 -->
<!-- branch: gateway/passkey-access-control -->

## 1. `file-embed` + cabal: an embedded non-source file does not trigger a rebuild

`Seal.Config.Templates` embeds `config/templates/*.toml`. Editing a template and
running `cabal build` **did not** recompile the module: cabal-install decides
the package is up to date without invoking GHC, so the `.hi`-recorded TH
dependency never gets a chance to fire. Symptom: the test suite compared the
file on disk against a *stale* embedded copy (an em dash had become `\DC4`), and
an ASCII fix appeared not to work until the module was `touch`ed.

Fix, verified: list the files in the package's `extra-source-files`. After that,
editing a template changes the object file with no `touch`. `Seal.Gateway.Embedded`
solves the same class of problem for the frontend with a sentinel manifest
(`.seal-manifest`) because its inputs are generated; for static inputs,
`extra-source-files` is enough — and it is required for a buildable sdist anyway.

Belt and braces: a test that reads the file from disk and compares it to the
embedded value turns a stale embed into a red test. It needs the package root
captured at compile time (`$(litE . stringL) =<< runIO getCurrentDirectory`),
because at least one spec moves the process's working directory.

## 2. `Data.Text.IO` writes in the *locale* encoding

`writeSecretFile`/`TIO.writeFile` encode through the process's locale, which in
a `nix develop` shell can be `C`/ASCII. Every non-ASCII character in a template
was then truncated to its low byte (U+2014 → `\DC4`, U+2026 → `&`). Generated
config files should be ASCII-only, and a test should pin that
(`all (< '\x80')`). This is pre-existing for any *hand-written* non-ASCII
comment in `security.toml` too: a rewrite will mangle it.

## 3. `sed -i ''` under `/bin/sh` is not reliable here — use python for edits

Two "mutation tests" that I ran with `sed -i ''` silently changed nothing, and I
briefly concluded the new tests had no teeth. They did. Every scripted edit in
this environment should go through `python3 - <<'PY' … io.write`, and a mutation
must be *verified applied* (`grep`) before its result means anything.

The same class of false conclusion came from a mutation that changed the code
but broke the build (unused import) rather than the assertion.

## 4. What the plan-review gate actually caught

Six iterations; feasibility/completeness/scope. Roughly two thirds of the
findings were line-number drift — real but low value, and each round cost a full
re-read. The substantive catches, all of which would have shipped bugs:

1. **The migration trap.** Creating `security.toml` before `migrateSecurityConfig`
   flips that migration from "move the values in" to "security.toml wins" and
   silently drops an operator's vault settings.
2. **The legacy-marker scan is a substring match.** Any mention of a `vault_*`
   key or `[untrusted_execution]` in `config.toml`'s *own prose* would make every
   boot after the first strip the template's comments. The template is now
   marker-free, with a test.
3. **An unaccounted writer.** `seal access-control disable|reset` writes
   `security.toml`, so a fresh install could get a comment-free file and never
   see the template. `runAccessControl` now scaffolds too.
4. **"Resolves identically" is not the same as "safe to write".** Two keys had to
   be commented out: `[untrusted_execution]` (an absent table and
   `mode = "local"` differ under `-f remote-only-untrusted`) and
   `max_fetch_bytes` (its default is *derived* from `[retrieval] max_scan_bytes`,
   so writing it freezes the coupling).

Lesson for future plans: keep line citations to the ones a reviewer must check,
and state the *invariant* ("writing it must resolve like an absent key") rather
than an exhaustive key list that invites drift.

## 5. A flaky gate is a bug report, not an obstacle

`Seal.Agent.Runtime.Registry`'s crash test failed in ~half of full-suite runs
and passed in isolation. The cause was a real lost-update race in `startAgent`:
it forked the worker before inserting the instance, and the worker's crash
handler is a `Map.adjust` keyed by subagent id — an agent that throws on its
first line updated a map that did not hold it yet, and the insert then left the
instance `Running` for the life of the process. Register first, release the fork
after the insert (`MVar` gate). Three consecutive green full runs afterwards.

## 6. Local process notes

- Don't run `cabal build` concurrently with `cabal test` while judging
  timing-sensitive specs; it inflated the flake rate and cost a diagnostic round.
- `make check` includes `frontend-build` + `frontend-test`; `npm install`
  completes here (906 vitest tests pass). `cabal build` alone does not build the
  frontend, and `frontend/dist` being absent is handled by `Seal.Gateway.Embedded`.
