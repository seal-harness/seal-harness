---
name: ci-fix
description: Fix CI failures efficiently — downloads full CI logs to a file, decomposes them into sections (build, test failures, timing, coverage), and surfaces the failures section first to avoid LLM context blowup
---

# ci-fix

Use when asked to fix CI failures, debug a failing CI job, or investigate a red
CI run. This skill prevents the common failure mode of loading enormous CI log
output directly into the LLM context (which can blow up token consumption or
hit output truncation limits).

## The Problem

`gh run view --log-failed` produces the full text of all failed steps. For a
typical Seal Harness CI run, the darwin job log alone can be 100K+ characters —
mostly Nix build output from the "Populate Nix store" step. Loading this
directly into the context window wastes tokens and often hits the 50KB tool
output truncation limit, leaving the agent with an incomplete picture.

## The Solution: Download → Decompose → Surface

### Step 1: Identify the failed run and job

```bash
# List recent runs (via BIN_EXEC for credential injection)
gh run list --limit 5 --json databaseId,status,conclusion,headBranch,displayTitle
```

Find the failed run (conclusion: "failure"). Note the `databaseId`.

### Step 2: Download the full log to a file

**Critical**: Use `SHELL_EXEC` with a redirect to a file, NOT `BIN_EXEC` directly.
`BIN_EXEC` output is bounded and will truncate at ~50KB. `SHELL_EXEC` with a
redirect captures the full log to disk without loading it into the context.

```bash
# Download failed-step logs to a file
gh run view <run-id> --log-failed > /tmp/ci-failed-log.txt 2>&1

# If that produces insufficient output (some runs need --log for full context):
gh run view <run-id> --log > /tmp/ci-full-log.txt 2>&1

# Check the size
wc -l /tmp/ci-failed-log.txt
```

**Note**: `gh` via `SHELL_EXEC` does NOT get credential injection. If you get
an auth error, use `BIN_EXEC` with `binary="gh"` to first verify the run ID is
valid, then use `SHELL_EXEC` for the redirect (the log download endpoint uses
the `GITHUB_TOKEN` from the environment, which may work even without vault
injection depending on the repo's visibility). If `SHELL_EXEC` fails with auth
errors, fall back to the API approach:

```bash
# Alternative: download logs zip via the API (needs BIN_EXEC for auth)
# Then extract and read with FILE_READ
```

### Step 3: Decompose the log into sections

Seal Harness CI logs have a well-defined structure. Parse the downloaded file
into sections using these markers:

| Section | Start marker | End marker | Priority |
|---------|-------------|-----------|----------|
| **Job setup** | `Current runner version:` | `##[group]Run actions/checkout` | Skip |
| **Nix install** | `##[group]Run DeterminateSystems/nix-installer-action` | `##[endgroup]` | Skip |
| **Cache restore** | `##[group]Run nix-community/cache-nix-action` | `Finished restoring the cache` | Skip |
| **Populate Nix store** | `##[group]Run nix develop --command true` | `##[endgroup]` (next) | Low — check for cache miss warnings |
| **Build** | `##[group]Run nix build` | `##[endgroup]` (next) | **High** — build failures here |
| **Test suite build** | `##[group]Run nix develop --command cabal test` | `Test suite tests: RUNNING...` | Low — usually just compilation |
| **Test execution** | `Test suite tests: RUNNING...` | `Failures:` | Low — individual test pass/fail |
| **Test failures** | `Failures:` | `=== Slowest test cases ===` | **Highest** — this is what you need |
| **Slowest tests** | `=== Slowest test cases ===` | `HPC` or `Coverage` | Low — timing info |
| **Coverage** | `=== HPC Coverage Report ===` or `##[group]Run` (next step) | End of step | Skip |

### Step 4: Extract the relevant section(s)

Use `grep`, `sed`, or `awk` to extract only the section you need. Always start
with the **failures** section:

```bash
# Extract test failures section (highest priority)
sed -n '/^Failures:/,/^=== Slowest test cases ===/p' /tmp/ci-failed-log.txt > /tmp/ci-failures.txt
wc -l /tmp/ci-failures.txt

# If no failures section, the failure is likely in the Build step
# Extract build step output
sed -n '/##\[group\]Run nix build/,/##\[endgroup\]/p' /tmp/ci-failed-log.txt > /tmp/ci-build.txt
wc -l /tmp/ci-build.txt

# Check for Nix cache miss warnings (useful for Populate step failures)
grep -c "warning: ignoring substitute" /tmp/ci-failed-log.txt
grep "building.*\.drv" /tmp/ci-failed-log.txt | head -20
```

### Step 5: Read the extracted section with FILE_READ

Only now, with the relevant section extracted to a small file, use `FILE_READ`
to load it into the context:

```
FILE_READ { "path": "/tmp/ci-failures.txt" }
```

If the failures section is empty or the file doesn't exist, the failure is
likely in the Build or Populate step. Read `ci-build.txt` next.

### Step 6: Fix the failure

Once you have the relevant failure output in context:
1. Identify the root cause from the error message
2. Make the fix in the codebase
3. Push and let CI re-run
4. If CI fails again, repeat from Step 2

## CI Log Section Structure (Seal Harness)

The CI workflow (`.github/workflows/ci.yml`) has these steps in order:

1. **Set up job** — runner provisioning (skip)
2. **Checkout** — git clone (skip)
3. **Install Nix** — DeterminateSystems/nix-installer-action (skip)
4. **Restore Nix store cache** — cache-nix-action restore (skip)
5. **Populate Nix store** — `nix develop --command true` (low priority; check for cache misses)
6. **Save Nix store cache** — cache-nix-action save (skip)
7. **Build** — `nix build --print-build-logs` (high priority for build failures)
8. **Package binary** — tarball creation (skip unless packaging fails)
9. **Upload artifact** — upload-artifact (skip)
10. **Run tests with coverage** — `nix develop --command cabal test --enable-coverage` (contains test output)
11. **Post test timing summary** — parses test-timings.txt (skip)
12. **Generate coverage report** — HPC report (skip)
13. **Post coverage to job summary** — (skip)
14. **Generate OpenAPI spec** — (skip unless spec generation fails)
15. **Stage/Fetch/Assemble/Deploy Pages** — (skip for CI fix purposes)
16. **Push to S3 Nix cache** — (skip unless cache push fails)

Within step 10, the test output has this structure:
- **Test suite compilation** — Cabal building the test suite (can be noisy)
- `Test suite tests: RUNNING...` — test execution begins
- Individual test results — `Group > test name` lines with `.`/`F`/`p`
- `Failures:` — detailed failure messages (what you need)
- `=== Slowest test cases ===` — timing summary
- HPC coverage lines — typically not useful for fixing failures

## Which job failed?

The CI matrix has two entries:
- `x86_64-linux` (runner: ubuntu-latest)
- `aarch64-darwin` (runner: macos-latest)

The log prefix tells you which job each line belongs to:
```
Build & Test (aarch64-darwin)\tUNKNOWN STEP\t<timestamp> <log line>
Build & Test (x86_64-linux)\tUNKNOWN STEP\t<timestamp> <log line>
```

Filter for the failed job:
```bash
grep "^Build & Test (aarch64-darwin)" /tmp/ci-failed-log.txt > /tmp/ci-darwin.txt
grep "^Build & Test (x86_64-linux)" /tmp/ci-failed-log.txt > /tmp/ci-linux.txt
```

## Common Failure Patterns

### Build failures (step 7)
- **Haskell compilation error**: GHC error in a specific module. Fix the code.
- **Missing dependency**: A cabal dependency isn't available. Check `seal-harness.cabal`.
- **Nix build failure**: A Nix derivation fails to build. Check `flake.nix` / `flake.lock`.

### Test failures (step 10)
- **Assertion failure**: A test assertion failed. Read the failure message, fix the code or test.
- **Test hang/timeout**: Check `currently-running.txt` output in the log for the hung test.
- **Flaky test**: Test passes locally but fails in CI. Look for timing-dependent or port-dependent tests.

### Cache populate failures (step 5)
- **cache.iog.io key mismatch**: `warning: ignoring substitute ... not signed by any of the keys`
  → Update `extra-trusted-public-keys` in `flake.nix` to match haskell.nix's current key.
- **S3 cache empty**: Many `building '...'` lines instead of `copying path '...'`
  → The S3 cache needs warming; run on main to push paths.

## Decision Tree

```
Did CI fail?
├── Which job? (linux / darwin / both)
├── Which step?
│   ├── Populate Nix store → cache miss? check for "ignoring substitute" warnings
│   ├── Build → compilation error? read the build section
│   └── Run tests with coverage
│       ├── Test suite didn't compile → read compilation errors
│       ├── Test suite ran but had failures → read Failures: section
│       └── Test suite hung → check currently-running.txt + heartbeat output
└── Extract only the relevant section, then fix
```