# Active Plan
<!-- approved: 2026-11-25 -->
<!-- gate-iterations: 3 -->
<!-- user-approved: true -->
<!-- status: not-started -->

Multiple Execution Machines — full implementation plan, **one PR**.

Canonical plan (full text, work units, DoD):
`docs/superpowers/plans/2026-11-25-multiple-execution-machines-plan.md`

Design spec:
`docs/superpowers/specs/2026-11-25-multiple-execution-machines-design-rev10.md`

Branch: `exec/multiple-machines` · Base: `main` · Issue: **#NN — to be created**

Execution: single PR, 14 units in the order below. `make check` green at every commit.

## Pre-flight (do this first)

```bash
python3 scripts/check-spec-counts.py docs/superpowers/specs/2026-11-25-multiple-execution-machines-design-rev10.md
# must print "all checks passed"; if not, the design drifted from the plan
python3 scripts/count-sessionmeta-sites.py     # baseline: 77 sites, 27 record / 50 positional
```

## Operator decisions (settled — do not re-litigate)

| Decision | Value |
|---|---|
| PR shape | **One PR.** Not the two-PR substrate/experiment split a reviewer proposed. |
| `mode` | **Deleted.** `allow_localhost :: Bool` replaces it. |
| `allow_localhost` default | **`true`** (today's behaviour). Confirmed by the operator. |
| WU-9's guarantee | **Deliberately weakened** — function-level test only; the hardened *artifact* property is issue #347's. Confirmed. |
| WU-10 (`group` sanitisation) | **Excluded from this PR.** Pre-existing bug, cannot reach `execution.toml`, own PR. |
| Localhost denylist | **Not implemented.** The control is: only a passkey-authenticated operator can add a machine. |
| `execution.toml` location | `~/.seal/config/` (version-controlled, alongside `repos.toml`). |
| Trust model | Passkey-gated `POST`/`DELETE /api/machines`, mirroring `POST /api/repos`; no opcode may write `executionFilePath`. |

## Work units

| WU | Title | Status |
|---|---|---|
| WU-1 | `Seal.Execution.Types` (pure) + `Ord` on three newtypes + leading-`-` guards | not started |
| WU-1b | `-F /dev/null` in four builders + `identity`/`known_hosts` folded into `ControlPath` | not started |
| WU-2 | `execution.toml` codec, loader, writer, lock, legacy synthesis; `Security.hs` deprecation edits | not started |
| WU-3 | `Seal.Execution.Resolve` — `resolveTarget`, seven rows | not started |
| WU-4 | Per-session pin; 77-site sweep (27 record / 50 positional) | not started |
| WU-5 | Collapse nine derivations; delete `execFingerprint` and `UntrustedExecMode` | not started |
| WU-6 | `--machine` in both parsers ← **demo checkpoint** | not started |
| WU-6b | Chat/Telegram mint paths | not started |
| WU-7a | Machine write API (the security control) | not started |
| WU-7b | `GET /api/machines` + the dropdown | not started |
| WU-7c | The Machines screen | not started |
| WU-8 | Session-viewer surface (workdir + inert Files link) | not started |
| WU-9 | `-f remote-only-untrusted` coercion (macro-free + one CPP line) | not started |
| WU-11 | Docs: both templates, README, CHANGELOG, retire superseded plan set | not started |

## Gate status — read before executing

The **design** passed 8 review rounds (rounds 7–8 found no design holes).

The **plan** went through 3 adversarial gate rounds and **never reached 3/3 PASS**:
round 1 Feasibility FAIL + Scope FAIL; round 2 Completeness FAIL + Scope FAIL;
round 3 Feasibility FAIL + Scope FAIL; Completeness timed out twice at the 600 s wall.
**The operator overrode the gate** rather than iterate a fourth time, on the assessment that
the remaining findings are bookkeeping (missing file-list entries) that `-Werror` and `tsc`
catch at the first build.

All 12 gate blockers were applied. The three most important, so they are not re-introduced:

1. **The sweep's DoD cannot be a count.** `count-sessionmeta-sites.py` matches
   `\bSessionMeta\b`, which does **not** match `defaultSessionMeta` — so replacing the 27
   record literals with `defaultSessionMeta sid now { … }` makes them *disappear from the
   count*. Expected post-sweep output is 50, not 77. The script is a **planning** tool;
   `-Werror` is the gate.
2. **`WU-5` deletes `UntrustedExecMode`, which `src/Seal/Config/Security.hs` imports
   (`:107`) and constructs (`:765-771`, `:796-802`).** That file and
   `test/Seal/Config/SecuritySpec.hs` are in WU-5's list for exactly this reason.
3. **`WU-9` cannot be verified with a `#define` in a test spec** — CPP is per-file, so the
   spec cannot influence how the library was compiled (verified experimentally). Use the
   macro-free `allowLocalhostFromWith :: Bool -> Maybe UntrustedExecFileConfig -> Bool`,
   tested in the normal build, with one CPP line selecting `True`/`False`.
