# Learnings: Source-Control Repo Registry + Credential-Backed Cloning

**Captured**: 2026-08-02 (post-implementation, pre-PR self-reflect)
**Feature**: issue #78 — `feat/source-control-repos` branch
**Design**: `docs/superpowers/specs/2026-08-02-source-control-repo-registry-design.md`

These learnings are extracted from the implementation of the source-control
repo registry + credential-injection clone seam. They are durable facts about
the codebase + security gotchas that future agents/contributors should not have
to rediscover.

---

## 1. Security: `GIT_ASKPASS` is a TWO-call protocol (Username then Password)

**The gotcha.** git invokes `$GIT_ASKPASS <prompt>` **twice** for an HTTPS
credential challenge: once with `Username for 'https://github.com': ` (argv[1]
starts with "Username") and once with `Password for 'https://github.com': `
(argv[1] starts with "Password"). A single-value "echo the token" helper
**FAILS** — it leaves the username prompt unanswered; with
`GIT_TERMINAL_PROMPT=0` git cannot fall back, so the clone fails opaquely.

**The fix.** The ASKPASS helper script MUST be prompt-aware — inspect `argv[1]`
(`$1` in the shell script) and branch:
- **PAT**: `Username` prompt → `x-access-token`; `Password` prompt → the token
  (GitHub's documented PAT-over-HTTPS convention: username `x-access-token`,
  password = the token).
- **Machine user**: `Username` prompt → `cUsername`; `Password` prompt → the
  token.

**Location**: `src/Seal/SourceControl/Clone.hs` `renderAskpassHelper` (~line 320).

---

## 2. Security: shell single-quote escaping is the POSIX `'\''` idiom (3 chars), NOT `\'` (2 chars)

**The bug (caught by adversarial review on W3, round 1).** A first draft of
`escapeSingle` emitted `\'` (backslash + quote, 2 chars) for each `'`. Inside a
single-quoted shell literal, `\'` is a literal backslash followed by the
string-terminating quote — so a token/username containing `'; <cmd> ;'` breaks
out of the literal and **executes `<cmd>`** in the 0700 ASKPASS helper script.
This is a command-injection vulnerability.

**The fix.** The correct POSIX idiom is `'\''` (3 chars: close-quote,
backslash-escaped-quote, reopen-quote). `escapeSingle` at
`src/Seal/SourceControl/Clone.hs:347` now emits `'\''`:
```haskell
go ('\'' : xs) = '\'' : '\\' : '\'' : go xs
```

**The lesson.** When generating shell scripts with embedded secret values,
single-quote escaping MUST use the 3-char `'\''` idiom. A regression test
(`test/Seal/SourceControl/CloneSpec.hs:350-391`) plants a single-quote token
and asserts `T.count "'\\'" s == 2` + that the Password arm line still ends `;;`
(a broken escape would terminate the string early).

---

## 3. Security: never put a git credential in argv/URL/env — use `GIT_ASKPASS` (token out of argv)

**The threat.** `git clone https://<token>@host/...` puts the token in argv,
visible to any co-resident process via `ps` / `/proc/<pid>/cmdline`. Seal
Harness's `UntrustedIO` sandbox shares the PID namespace (it uses `ps`
itself — no `unshare`/`chroot`/`pidns`), so any untrusted `SHELL_EXEC` child
can read the harness's argv and exfiltrate the token.

**The pattern (the seam in `Seal.SourceControl.Clone`).** Pass git a
**token-free URL** + a `GIT_ASKPASS=<helper-script-path>` env var (the env
value is a non-secret path; the helper script is 0700 in a 0700 private dir,
bracket-deleted after the clone). The token bytes live only (a) in the helper
script's bytes on disk (0700, short-lived) and (b) on the pipe between the
harness and git — never in argv, never in the URL, never in the environment.

**For SSH deploy keys**: the keyfile path is in `GIT_SSH_COMMAND`'s env (a
path, not the key bytes); the key bytes are in a 0600 keyfile under a 0700
private state dir, `bracket`-cleaned. `IdentitiesOnly=yes` +
`StrictHostKeyChecking=accept-new` + a private `UserKnownHostsFile`.

**Reuse this pattern** for any future credential-injection feature
(`hg`, `jj`, API tokens for other tools that accept an askpass/helper).

---

## 4. tomland: `Toml.tableMap` SILENTLY decodes an empty map for idiomatic `[<section>.<key>]`-only files

**The gotcha.** `Toml.tableMap Toml._KeyText (Toml.table codec) "<section>"`
silently returns an empty map when a hand-written TOML file uses only
`[<section>.<key>]` sub-tables (no bare `[<section>]` header) — the idiomatic
style. A hand-edited `config.toml` / `repos.toml` decodes as empty (silent
data loss).

**The fix.** Run a `normalizeXTable :: TOML -> TOML` AST walk before
`runTomlCodec` that makes the implicit `<section>` node explicit. The pattern
is established in `Seal.Config.File.normalizeProvidersTable` (line ~442) and
mirrored in `Seal.SourceControl.Repo.normalizeReposTable`.

**The lesson.** Any new keyed-by-id TOML section via `Toml.tableMap` MUST ship
a matching `normalizeXTable` (and a unit test: idiomatic `[<section>.<key>]`-
only file decodes to the non-empty map, not empty). Without it, hand-edited
config files silently lose their contents.

---

## 5. Adversarial review catches real bugs — never skip it, never reuse a reviewer

**Two real bugs** were caught by the adversarial-review phase of the
orchestrated-execution loop in this feature, both missed by the implementing
coder AND by the orchestrator's own validation (build/test/lint all green):

1. **W3 `escapeSingle` command injection** — the security-auditor reviewer
   found it (the W3 coder + `make test` + `make lint` all passed; the tests
   used only `[A-Za-z0-9_]` tokens so the single-quote bug was uncaught). The
   fix + a regression test made the invariant executable.
2. **W5 missing `CloneError` variant tests** — the code-reviewer found 2 of 5
   `CloneError` variants had no `/repo test` error-message test.

**The lesson.** Per the orchestrated-execution protocol:
- **VALIDATE independently** — the orchestrator runs `make build`/`test`/`lint`
  directly; never trust the coder's self-report.
- **ADVERSARIAL REVIEW with a FRESH instance** — never reuse the reviewer that
  found the bug (anchoring bias); spawn a new instance with no memory of the
  prior review to confirm the fix.
- **The security-auditor agent** is the right reviewer for security-sensitive
  WUs (the clone seam); the code-reviewer is right for spec-compliance WUs.

---

## 6. `-Wincomplete-record-updates` + `-Werror` mechanically enforces record-literal updates

When a record type (e.g. `ApiDeps`) gains a field, EVERY record literal across
the codebase must be updated or the build fails under
`-Wincomplete-record-updates` + `-Werror`. This makes large-scale record-field
additions safe: the compiler lists every site. In W4, `ApiDeps` gained 2
fields and ~22 literals across 4 files (production `Serve.hs` + 3 test files)
were all mechanically found by the compiler.

**The lesson.** Don't try to count construction sites by hand — let the
compiler enforce completeness. Run `make build` early and let the warnings
guide you to every literal.

---

## 7. The `RepoTestSeam` pattern: inject the IO seam for testability

The `/repo test` command depends on the live vault + `git ls-remote`. To keep
the command testable without running real git or a real vault, the dependency
was injected as a `RepoTestSeam { rtsLsRemote :: SourceRepo -> IO (Either
CloneError Text), rtsVaultList :: IO (Either VaultError [Text]) }` record of
IO actions. Production wires the real `lsRemoteRepo` + `vhList`; tests pass a
stub.

**The lesson.** When a slash command (or any `ChannelCaps -> IO ()` action)
needs an IO side effect that's hard to test, inject it as a record-of-IO-
actions (mirrors `VaultHandle` itself). This avoids both global mocks AND
testing through real external services.

---

## 8. `RepoRegistryHandle.rrhList :: IO (Either Text [SourceRepo])` — the `Either` surfaces corrupt files as HTTP 500

A registry/file-backed handle's `list` operation should return
`IO (Either Text [...])`, NOT `IO [...]`. A corrupt `repos.toml` (tomland
parse error) must surface as HTTP 500, NOT a silent empty 200 — a silent
empty list would mask a corrupt registry and let a re-POST silently overwrite
entries.

**The lesson.** File-backed service handles should propagate parse/load
errors through the `list` API so the REST layer can distinguish "empty" from
"corrupt" and return the right status code.