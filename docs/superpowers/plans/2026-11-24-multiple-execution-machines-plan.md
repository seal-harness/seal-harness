# Multiple execution machines — plan index (superseded as a single document)

<!-- design: docs/superpowers/specs/2026-11-23-multiple-execution-machines-design.md (rev 3c) -->
<!-- handoff: docs/handoffs/2026-11-23-multiple-execution-machines-handoff.md -->
<!-- status: SPLIT — this document is an index; the executable plans are A and B -->

## This plan was split into two milestones

One 1620-line plan could not be reviewed: the Plan Review Gate was attempted three times
and returned **zero verdicts** (600 s wall-clock limit twice; provider idle-stream timeout
once; 15 reviewer spawns). That is recorded in detail in §A.1 below. The failure was a
size problem, and the fix is a split, not a retry.

| | Document | Units | Lines |
|---|---|---|---|
| **A** | [`…-A-inventory-and-pin.md`](2026-11-24-multiple-execution-machines-A-inventory-and-pin.md) | WU-1a, 1b, 1c, 2, 3, 4 | ~754 |
| **B** | [`…-B-destructive-cutover.md`](2026-11-24-multiple-execution-machines-B-destructive-cutover.md) | WU-2b, 5, 6, 7, 8, 2c, 9 | ~811 |

**A is additive and B is destructive**, and the seam is the design's own decision point:

- A defines the machine inventory, parses `allow_local`, and lets a session pin a machine.
  It deletes nothing; `untrusted_execution.mode` keeps working; a user who never passes
  `--machine` sees no behaviour change.
- A ends at **Checkpoint A** — the design's two-week falsification test, where the pinned
  machine becomes visible in the composed ssh argv.
- **B is gated on A's answer.** If nobody pins a non-default machine, B drops the picker
  (WU-8) or does not happen — and nothing needs undoing, because A was additive.

This is not an arbitrary halfway mark. The design already required every destructive
change to come after WU-4 (so WU-4 could be demoable); the split simply exposes the seam
that was already there, and puts the reversible work on the side that ships first.

## §A.1 Gate status — inherited by both milestones, not erased by splitting

Three attempts, 15 reviewer spawns, **zero PASS/FAIL verdicts**:

| Attempt | Configuration | Outcome |
|---|---|---|
| 1 | 3 reviewers, whole plan, no time-box | all 3 killed at the **600 s subagent wall clock** (95 / 69 / 53 messages of real verification, no verdict) |
| 2 | 3 reviewers, chunked to WU-1a/1b/1c/2 (~580 lines), 6-min time-box, build commands forbidden | 2 killed by a **provider stream timeout** (`no data for 5 minutes`) |
| 3 | same chunk, same time-box | 1 killed by the same provider timeout |

The two limits are adversarial: deep verification needs long uninterrupted reading, and
long reading stretches trip the provider's idle-stream timeout, while the wall clock caps
total duration. Shrinking briefs further would produce reviewers that skim and pass
everything — **worse than no review, because it manufactures assurance.** Retries were
stopped deliberately at that point.

### Findings the attempts did produce

**One genuine blocking defect, found by independent review (not self-review)** — fixed in
Milestone A's WU-4:

- **WU-4 changed `newSession`/`newSessionMeta`'s signature while naming only 3 of the 11
  files that call them.** Measured: **101 call sites across 11 files**. All 11 are now in
  scope, with a DoD item that counts hits before/after and leans on the compiler.

**Two load-bearing structural claims were independently corroborated** (re-verified by
hand after the reviewers died):

| Claim | Result |
|---|---|
| §C6 — may `Seal.Execution.Types` import `Seal.Security.Path` without a cycle? | **PASS.** `Path.hs` has **zero** `Seal.*` imports (only `base`/`directory`/`filepath`/`text`/`unix`). No cycle constructible. |
| §0.3 — is the `localhost` rejection test non-vacuous? | **PASS.** `localAddressNamesWith` emits only `show (ipv4 iface)` / `show (ipv6 iface)`; it can never yield `localhost`. The loopback literals in `selfIdentityFrom` are load-bearing. |

### Corrections from the one completed independent review (Milestone A, feasibility)

A feasibility review of Milestone A completed and returned **FAIL** with five blocking
findings, four of which were correct and are fixed in both milestones. Recorded here
because they change the file lists a reader would otherwise trust:

1. **The 101-site sweep's file list was wrong.** The *count* (101) is right, but the plan
   listed a different eleven files — it omitted `test/Seal/Session/StoreSpec.hs` (5 sites)
   and `test/Seal/Command/SessionSpec.hs` (1), while naming files with no call site at
   all. Under `-Werror` with a non-optional parameter, the omitted files do not compile.
   Both milestones now carry the measured per-file table.
2. **`TurnDeps` gains a required field and there is no `Default TurnDeps` instance**, so
   `mkWebTurnDeps` (`Gateway/Send.hs:276`) must change in the same commit. It was absent
   from WU-4's file scope; now listed (4 literals total: `Send.hs:276`, `Cli.hs:218/276/309`).
3. **`CreateTabBody` is TypeScript-only** (`frontend/src/hooks/useApi.ts:1021`). There is
   no Haskell type of that name — `handleTabNew` takes a raw `A.Value`. WU-4's change site
   was corrected; the interface extension belongs to WU-8.
4. **The WU-4 sweep grep was a BRE where `\(` is a group operator**, so it silently meant
   "`newSession ` or `newSessionMeta `" — and its "101" baseline contradicted WU-3's
   separate 77-site `SessionMeta` population. Replaced with an `-E` form and an explicit
   note that the two populations differ.
5. A self-defeating `either (const undefined) id` assertion (tests neither branch) was
   rewritten to build a real temp-dir path.

One reviewer finding was **rejected on verification**: it claimed
`test/Seal/Session/SearchSpec.hs` has no `newSession` call sites. It has **15**
(`grep -cE '\bnewSession(Meta)?[[:space:](]'`). The reviewer conflated `newSession`
*callers* with `SessionMeta` *construction sites* — the exact conflation item 4 warns
about. It stays in scope.

### What is NOT reviewed

- **WU-5, WU-6, WU-7, WU-8, WU-9 have never been independently reviewed** — all in B.
- Neither A nor B has passed a Plan Review Gate. Both are **re-cuts of unapproved
  material**. The split makes each gateable (~750–810 lines, one reviewer can finish);
  it does not make them approved.

Both milestones therefore require their own gate run before their first unit executes.
That is stated as a precondition in each document, not as an optional step.

---

## Historical content

The full single-document plan is superseded. Its unit text lives on, verbatim, in A and B.
The sections below are retained only where they are not reproduced elsewhere, or where a
milestone cross-references them.

### Cross-cutting design notes (referenced by both milestones)

#### §0.2 Four conflicts inside the design's work-unit table, and how the plan resolves them

These are **not** re-litigations of design decisions. They are places where the design's
work-unit table contradicts a design decision, a build fact, or itself. Each is resolved
in favour of the decision.

**C1 — WU-1 could not be pure-and-IO-free while also owning `SelfIdentity`.** D4 splits
`resolveTarget`/`validateTarget` (pure) from `getSelfIdentity`/`resolveTargetIO` (IO), but
the design's work-unit table puts all of it in WU-1. **Resolution:** split into **WU-1a**
(pure `Seal.Execution.Types`) and **WU-1b** (IO `Seal.Execution.Resolve`), which the design
already names as separate modules.

**C2 — the `-F /dev/null` hardening had no owner.** D6's last paragraph requires
`-F /dev/null -o ProxyCommand=none -o ProxyJump=none` in `sshExecArgv`/
`sshExecArgvForwarding`. No work unit listed it. **Resolution:** **WU-1c**, a two-file unit
with no dependencies.

**C3 — cabal wiring was assigned to both WU-1 and WU-9.** **Resolution:** each unit wires
the module it creates (WU-1a, WU-1b, WU-2), in the same commit. WU-9 keeps only
`config/templates/execution.toml` in `extra-source-files` plus a *negative* check.

**C4 — `TargetConfigUnreadable` had no producer.** D4 makes `resolveTarget` take an
already-parsed config, so nothing could return the constructor D13 writes copy for.
**Resolution:** WU-1b owns `loadAndResolveTargetIO`, which turns a
`loadExecutionConfig` failure into `TargetConfigUnreadable`.

**C5 — WU-4's falsification demo was not observable at WU-4.** The executor still derived
from `SecurityConfig` until WU-2b, so WU-4 would persist a field and demonstrate nothing —
the PM round-2 defect one layer down. **Resolution (three attempts; the first two were
rejected — see Milestone A §3.1):** the pin is read **inside** `cachedSessionExec` via
`readSessionMeta` (whose arguments are already in scope), so `cachedSessionExec`'s type is
unchanged and no call site moves. `mkSessionExec` gains one `Maybe ResolvedTarget`
parameter (3 call sites, all in scope), with today's body moved verbatim behind its
`Nothing` branch. `TurnDeps` and `Send.hs` are untouched.

*Rejected:* (1) a `securityConfigForTarget` helper rewriting `scUntrustedExec` — it
silently moved untrusted execution from the remote box to the harness box on existing
`mode=remote` installs; (2) threading a `Maybe MachineName` through
`cachedSessionExec`/`mkSessionExec` — 16 + 3 call sites, two inside the modules being
changed.

**C6 — `Seal.Execution.Types` cannot both be a leaf importing only
`Seal.Tools.Exec.Types` and reuse D7's `blockedNames`.** **Resolution:** it also imports
`Seal.Security.Path`, which imports **no** project module (verified), so it stays a leaf.
D17's two rules concern `Seal.Config.Security` and `Seal.Config.Migrate`; a DoD grep
enforces the two bans that matter.

**C7 — `TemplatesSpec` was claimed by both WU-2b and WU-9.** **Resolution:** WU-2b does
the **minimum** to keep the suite green and adds no new assertions; WU-9 authors the
template and every new assertion.

**C8 — the design's integration case had no owner.** **Resolution:** it is a DoD item of
WU-7 (in B), where `ApiTestHarness`'s recording fake can observe the argv.

#### §0.3 One implementation refinement that makes D6's most important test non-vacuous

The handoff's headline lesson: *a test asserted `localhost` is rejected, against a
`SelfIdentity` construction that could never produce the string `localhost`.*

The design fixes the **production** construction (D6 step 2). It does not specify how
**tests** construct one — so if tests hand-build `SelfIdentity ["arrakis.local"]`, the
`localhost` assertion is vacuous again, the same defect relocated into the test suite.

Hence **one constructor, used by both production and tests**:

```haskell
-- Seal.Execution.Types (pure). Appends the canonical loopback literals itself,
-- so no caller can build a SelfIdentity that omits them.
selfIdentityFrom :: Text -> [Text] -> SelfIdentity
```

`getSelfIdentity` (WU-1b) calls `selfIdentityFrom <$> (nodeName <$> getSystemID) <*> localAddressNames`.
Every D6 test calls it too. **Verified:** `localAddressNamesWith` emits only
`show (ipv4 iface)`/`show (ipv6 iface)` — no hostname, no `localhost` — so the literals are
load-bearing and the test exercises real behaviour.

Two consequences that are DoD items, not prose:

- A test asserts `selfIdentityFrom "arrakis.local" []` **contains** `"localhost"`,
  `"127.0.0.1"`, `"::1"`, `"ip6-localhost"`.
- A test asserts every D6 bypass string (`localhost`, `localhost.`, `LOCALHOST`,
  `127.0.0.1`, `127.1`, `2130706433`, `0x7f000001`, `0.0.0.0`) is **rejected** against a
  `SelfIdentity` built by `selfIdentityFrom "arrakis.local" []` — the one production
  builds — not against a hand-written list.

#### §0.4 Two measured facts that bound what any work unit may promise

**M1 — the hardened build does not build, and that is pre-existing (issue #347).**

| Command | Result |
|---|---|
| `cabal build all` (baseline) | exit 0 |
| `cabal build lib:seal-harness -f remote-only-untrusted` | **exit 0** — and `Seal.Tools.Exec.Local` *is* compiled, i.e. #347's defect reproduced |
| `cabal build all -f remote-only-untrusted` | **exit 1** — `ld: symbol(s) not found`, undefined `Seal.Tools.Exec.Local.readBoundedBytes` referenced from `Remote.o` |
| `cabal build test:tests -f remote-only-untrusted` | **exit 1** — `test/Seal/Tools/Exec/LocalSpec.hs:16: Could not find module 'Seal.Tools.Exec.Local'` |

Consequences: no DoD may require building or testing under the flag; the design's own D0
evidence line uses `lib:seal-harness`, not `all`; and because `test:tests` does not compile
under the flag, **the whole suite cannot be run under it**, so no DoD may claim a spec
passes under `-f remote-only-untrusted`.

**M2 — a module with no cabal stanza is genuinely never typechecked.** Confirmed with the
harness this tree already ships: `test/Seal/TestHelpers/CompileFail.hs` invokes
`ghc -fno-code`, and its fixtures run (`--match=compile-fail` → 11 examples, 0 pending).
The compile-fail pattern used in three DoD items (WU-2b #5, WU-5 #1, WU-7 #6) is proven
working in this tree, not assumed.

### Human checkpoints (both milestones)

| # | Where | Why | What the human sees |
|---|---|---|---|
| **A** | End of Milestone A | **The falsification point**; the two-week clock starts | The `--machine builder` demo with the composed ssh argv, the `session.json` diff, and the statement: *if nobody pins a non-default machine within two weeks, B drops the picker (WU-8) or does not happen.* |
| **B** | After B's WU-2b (and WU-5) | Destructive security change | Coercion evidence in the form that exists (normal-build test + `cpp` output + one-use grep), migration comment preservation, deleted-symbol summary |
| **C** | After B's WU-9, before PR | Final cross-unit review | The full WU table and the cross-unit checks |

### Out of scope (both milestones)

Multi-machine file explorer; OS/capability routing; multiple machines per session; adding
machines from the web UI; per-machine vaults; IPv6 SSH targets (`mkSshHost` rejects `:`);
`seal exec-machine` CLI group; DNS-resolved self-host detection. Issues **#347** and
**#348** are separate.

### External dependencies

None that block implementation — no API keys, no services, no network at test time. Every
SSH interaction in the specs goes through the existing fake runners. `ssh-keygen` is
required by the existing `ApiTestHarness` fixture generator, not by anything this feature
adds.
