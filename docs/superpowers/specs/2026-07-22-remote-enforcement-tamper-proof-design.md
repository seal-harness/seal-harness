# Remote-Only Enforcement — Tamper-Proofing Against Agent Self-Modification

> **Status:** Design exploration, Round 2 (post-review revision). Revised
> after the 5-agent design review gate (Round 1): PM APPROVED, Architect
> APPROVED, Designer APPROVED w/ 2 blockers, Security Design NEEDS_REVISION
> (3 blockers), CTO NEEDS_REVISION (5 blockers). All blockers addressed in
> this revision.
>
> **Upstream spec:** `2026-06-28-remote-only-untrusted-execution-design.md`
> (approved). This document extends that spec to close a residual
> self-modification gap.

## 1. Problem statement

Seal Harness already implements a two-layer remote-only-untrusted design
(Layer A runtime fail-closed; Layer B compile-time hardened build). The
operator wants **high certainty** that untrusted opcodes always execute on a
separate machine, and that an agent cannot defeat this guarantee by
modifying its own configuration.

The existing design assumes the agent cannot rewrite the
`[untrusted_execution]` section of `config.toml`. That assumption is **mostly
true today** but is not structurally guaranteed. The concrete residual gaps
are enumerated in §3. The goal of this design is to convert "mostly true" into
a structural guarantee, at multiple layers, so that defeating the remote-only
requirement requires compromising a mechanism the agent has no capability to
reach.

## 2. What already protects the config (the good news)

Before designing new defenses, catalog the existing ones — several of the
naive attack vectors are already closed:

| Vector | Why it's closed today | Where |
|---|---|---|
| `FILE_WRITE` to `~/.seal/config/config.toml` | `SafePath` blocks the `.seal` path segment (lexical) + post-canonicalization containment check (anti-symlink) | `Security/Path.hs:46,81,100` (`blockedNames` + containment) |
| Any Untrusted opcode touching config (remote-only mode) | All Untrusted opcodes run on the remote machine; the remote workspace ≠ the control-plane config | `Tools/Exec/Untrusted.hs` |
| Agent edits config via shell | `SHELL_EXEC` is Untrusted → runs on remote; remote has no path to `~/.seal` on the control plane | ISA trust classification |
| Trusted/Audited opcode shells out to edit config | Global Invariant 1: Trusted/Audited opcodes never shell-wrap (type-enforced: `TrustedOpcode`'s `toRun` has no `ExecBackend` in scope — compile-fail fixture at `test/Seal/Tools/Exec/CapabilityScopingFailSpec.hs`) | upstream spec §6 Inv. 1 |
| Agent deletes the vault / lobotomizes itself | Config dir is a git repo (`Git/Repo.hs`) — file history is recoverable via `git`. The session transcript is append-only single-writer + fsync (NOT hash-chained; NOT mirrored off-box — see §3 note) | `Git/Repo.hs`, `Handles/Transcript.hs:21-22` |

So the agent's *direct file access* cannot reach the config in remote-only
mode. The residual threats are subtler: code-level vectors that run on the
control plane.

## 3. Residual threat vectors (the gaps)

These are the paths by which a sufficiently capable agent could defeat
remote-only enforcement, ranked by likelihood:

### V1 — Future `CONFIG_UPDATE` opcode (HIGH risk, not yet implemented)

The ISA lists `CONFIG_UPDATE` as an **Audited** opcode (README:235). It is
not yet implemented (grep finds no implementation in `src/`). When it lands, an
Audited opcode runs **on the control plane** (per `ISA/Dispatch.hs:66-71`, the
Audited branch is treated as Trusted and runs in-process) and writes to
`config.toml` via `updateFileConfig` (`Config/File.hs:374`). If its update
function is unrestricted, the agent can set `untrusted_execution.mode =
"local"`.

**The flip does NOT wait for a reboot.** Config is re-read at **every session
start**, not only at process boot: `Channels/Loop.hs:498`
(`loadFileConfig (prConfigPath pr)` inside `runChannelLoop`),
`Channel/Cli.hs:305`, and `Gateway/Send.hs:276` all call `loadFileConfig` per
session. So a corrupted `config.toml` is picked up by the **next session
created in the same long-running process** — no restart needed. This makes V1
*easier* to exploit than a "next boot" model implies.

Layer B (hardened build) catches a `mode=local` value at the next session-start
via `enforceRemoteOnly`, but Layer A (default build) does not. And even Layer B
only catches it *after the config has been corrupted* — the agent has already
tampered with state on disk.

### V2 — `CONFIG_UPDATE` flips mode mid-session (MEDIUM risk)

Because config is re-resolved per session start (see V1), a `CONFIG_UPDATE`
that writes `mode=local` affects any **newly created session** in the same
process immediately. A session already running keeps its resolved
`execBackend` (set at `AgentEnv` construction, `Agent/Env.hs:33`), but a
sub-agent forked via `AGENT_START` would pick up the flipped value. The
"depends on impl" hedge in the Round 1 draft is withdrawn — the per-session
re-read is the mechanism, and it exists today.

### V3 — Future opcode that can write arbitrary config paths (LOW-MEDIUM)

`updateFileConfig` takes an arbitrary `FilePath` (`Config/File.hs:374`) and
does **not** route through `SafePath`. Every existing caller passes a path
derived from `configFilePath` (`Paths.hs:84`), so they target the real config
today — but nothing in the *type* prevents a future caller from passing a
workspace path. A future Trusted/Audited opcode that accepts a path and writes
to it (beyond the existing `skills/agents/memory` stores) could target
`config.toml`. The `updateFileConfig` function itself places no path
constraint. This is a speculative future vector, not a current one — but it
means Approach E (type split) must be paired with a path confinement for the
save function (see §4 B).

### V4 — Environment variable `SEAL_HOME` manipulation (LOW risk)

`resolveSealHome` reads `$SEAL_HOME` (`Config/Paths.hs:45`). If the agent
could set environment variables for the *next* process launch, it could
redirect the config location to a workspace-writable path. Today no opcode
mutates the process environment for the harness itself, and Untrusted
`SHELL_EXEC` runs on the remote machine (different process tree). Approach E
closes this for the running process: `BootstrapConfig` is loaded from a path
resolved **once at boot** and never re-resolved, so a mid-session env change
cannot redirect the already-loaded config. The cross-process variant (agent
sets the env var for a future launch) requires an env-mutating opcode, which
does not exist and would itself be a Trusted opcode on the control plane —
categorized with V5.

### V5 — Supply-chain / binary replacement (OUT OF SCOPE)

If the agent can replace the `seal` binary itself, no config-level defense
matters. This is a platform-security concern (binary on read-only filesystem,
signed updates), not a config-tamper concern. Excluded from this design.

### V6 — HTTP Gateway: unauthenticated `updateFileConfig` caller (HIGH risk, existing)

**This is a live vector the Round 1 draft missed.** The HTTP Gateway calls
`updateFileConfig` with a full `FileConfig -> FileConfig` update function:
`Gateway/API.hs:693,706` (`PUT /api/agents/default`).

- `updateFileConfig` (`Config/File.hs:374`) takes `(FileConfig -> FileConfig)`
  over the **full** `FileConfig`, and `saveFileConfig` re-encodes the whole
  file via `fileConfigCodec`. The current handlers only touch
  `fcDefaultAgent`, but the *capability surface* is the entire config,
  including `fcUntrustedExec`.
- The Gateway binds `127.0.0.1` by default (`Gateway/Config.hs:33`), but a
  non-loopback bind only **warns** to stderr (`Gateway/Server.hs:72-74`) — it
  does **not** refuse. There is **no authentication** anywhere in
  `Seal/Gateway/` (no `Authorization` header check, no token — verified by
  grep).

**Implication:** if an operator binds the gateway non-loopback, any network
client can POST a config write. Even on loopback, a process co-located on the
control plane (e.g., a compromised dependency) can. **Approach E (type split)
does NOT cover this path** — `updateFileConfig` consumes `FileConfig`, not
`MutableConfig`. The Gateway is a Trusted-code caller, not an opcode, so the
type split at the opcode boundary doesn't reach it.

**Mitigation:** (a) Approach E must restrict `updateFileConfig`'s signature to
`MutableConfig` as well (so the Gateway handler physically cannot express a
change to `fcUntrustedExec`), OR (b) the Gateway must validate-reject any
proposed change touching `fcUntrustedExec`. Recommend (a) — it makes the
guarantee structural, not validation-based. Additionally, the Gateway bind
should be **fail-closed** (refuse, not warn) on non-loopback when
`mode=remote`, since a non-loopback gateway is a config-tamper surface.

### V7 — Config-write race / lost-update (MEDIUM risk, existing)

`updateFileConfig` is load-modify-save, non-atomic (`Config/File.hs:375-379`).
Multiple concurrent callers (Gateway PUT + a future `CONFIG_UPDATE`, or two
sessions' `CONFIG_UPDATE`) can silently clobber each other — last-write-wins.
A legitimate provider-setting update could be overwritten by a mode flip, or
vice-versa, with no error. With multiple sessions sharing one `config.toml`
(confirmed: `configFilePath` is process-global, `Paths.hs:84`), this is real
today. Mitigation: serialize all `updateFileConfig` callers behind a
process-wide `MVar` (or file lock). Belongs in the implementation plan.

### V8 — Git-history rollback of config.toml (LOW-MEDIUM risk, speculative)

The config dir is a git repo (`Git/Repo.hs`); `gitCommitAll` stages+commits.
No opcode today wraps `git` (`runGit` uses fixed argv, not exported to
opcodes). However, if a future opcode or the Gateway ever exposed
`git checkout`/`git reset` to agent influence, the agent could restore a
prior `config.toml` with `mode=local` — defeating the config-time defense
without writing a new file. Mitigation: Approach B's `security.toml` must
**not** be versioned in the `~/.seal/config/` git repo (or must have an
independent history), so git cannot resurrect a lower-security version. The
design's `security.toml` should be gitignored or stored outside the repo.

## 4. Design approaches

Five approaches, from cheapest to most structural. They are **layered, not
mutually exclusive** — the recommendation (§6) is a defense-in-depth stack.

---

### Approach A — Immutable config field (runtime, config-level)

**Idea:** Treat `untrusted_execution` as a **read-only-after-boot** section.
Once loaded at startup, the resolved `UntrustedExecConfig` is cached in an
immutable `IORef` (or `MVar` / pure value threaded in `AppEnv`). `CONFIG_UPDATE`
and any other config-mutating opcode is structurally **unable to change the
`untrusted_execution` field** — the field is omitted from the
`updateFileConfig` update function's domain, or rejected if present.

**Mechanism:**
- `CONFIG_UPDATE`'s update function (`FileConfig -> FileConfig`) receives a
  **restricted projection** of `FileConfig` — one that excludes
  `fcUntrustedExec`. Or, the opcode validates its proposed patch and rejects
  any change to `fcUntrustedExec` with a structured error ("untrusted_execution
  is immutable at runtime; edit security.toml directly and restart").
- The resolved `UntrustedExecConfig` is loaded once at boot
  (`untrustedExecConfigFromFile`) and stored in `AppEnv` as a pure value, never
  re-read. **Critically, the caching must apply at the session-start seam**
  (`Channels/Loop.hs:498`, `Channel/Cli.hs:305`, `Gateway/Send.hs:276`) where
  `loadFileConfig` is currently called per-session — not only at `Tui.hs:73`
  (the TUI boot path). Otherwise a config edit is picked up by the next
  session.

**Strengths:**
- Closes V1 and V2 completely on **both** Layer A and Layer B builds.
- Cheap: a validation predicate + a comment. ~1 file, ~20 lines.
- Composable with all other approaches.
- Honest: the field genuinely is not agent-mutable.

**Weaknesses:**
- "Immutable at runtime" is a code convention enforced by a predicate. A
  future developer could add a code path that bypasses it. It is not a
  *type-level* guarantee.
- Does not protect against a config-edit that happens outside the opcode
  system (e.g., a future admin CLI that the agent could somehow invoke). But
  that's V3/V5 territory.
- The agent can still *attempt* the update and learn from the rejection —
  but it cannot succeed.

**Type-level strengthening (optional):** Make the immutability a *type*
guarantee by splitting `FileConfig` into `MutableConfig` (agent-writable
fields) and `BootstrapConfig` (read-at-boot-only, includes
`untrusted_execution`). `CONFIG_UPDATE` consumes `MutableConfig` and
physically cannot mention `fcUntrustedExec`. This is a larger refactor but
makes V1 a **compile-time** impossibility. See Approach E.

---

### Approach B — Separate, agent-unreadable config file (file-level isolation)

**Idea:** Move `untrusted_execution` (and any future security-critical,
boot-only settings) out of `config.toml` into a **separate file** — e.g.
`~/.seal/config/security.toml` — that:
1. Is read at boot and never re-read.
2. Is **not exposed via any opcode** — no `CONFIG_VIEW` / `CONFIG_UPDATE`
   path touches it.
3. Is **not in the workspace** and (optionally) file-permission-locked to the
   harness user (mode 0600), so even a stray file-write opcode can't reach it.

**Mechanism:**
- New `loadSecurityConfig :: IO SecurityConfig` at boot, parallel to
  `loadFileConfig`. `SecurityConfig` carries the `UntrustedExecConfig` (and
  future security knobs).
- `config.toml` no longer contains `[untrusted_execution]` — **"instead of",
  not "in addition to"** (resolving Open Question 2 from Round 1). The field is
  removed from the `FileConfig` codec entirely. There is no in-memory
  representation for an opcode to mutate. A one-time boot-time migration moves
  any existing `[untrusted_execution]` section from `config.toml` to
  `security.toml`, writes `security.toml`, removes the section from
  `config.toml`, and emits a deprecation/warning to stderr. Migration is
  idempotent.
- File permissions: `security.toml` created mode 0600, owned by the harness
  user. Not world-readable.
- **Git versioning:** `security.toml` must **not** live in the git-versioned
  `~/.seal/config/` tree (to prevent V8 — a `git checkout` resurrecting a
  lower-security version). Store it at `~/.seal/security.toml` (sibling of
  `config/`, not inside it) or add it to `.gitignore`. Recommend the former —
  outside the repo entirely.
- **Path confinement:** the `loadSecurityConfig`/save path is hard-wired to
  the `security.toml` location resolved from `SealPaths` and **never** accepts a
  caller-supplied `FilePath` (closes V3's "arbitrary FilePath" for the security
  file).

**Strengths:**
- Removes the field from the opcode-reachable config surface entirely. V1/V2
  cannot even *attempt* to flip it — there's no field to update.
- "Cannot be edited by the agent via opcodes / tool calls" is structurally
  true: no opcode reads or writes `security.toml`.
- Clear separation: "these are operator-only knobs, these are agent-tunable."
- A future `CONFIG_VIEW` for introspection can show a *redacted* view of
  security config (mode only, not the full remote block) if desired.

**Weaknesses:**
- The agent could still edit `security.toml` directly if it had a file-write
  path to `~/.seal/`. `SafePath` blocks `.seal` as a segment, so
  `FILE_WRITE` (Untrusted, workspace-confined) cannot. But a *future* Trusted
  opcode that writes under `~/.seal/` (none exists today) could. Defense:
  `security.toml` is file-mode 0600 and outside the config git repo; no opcode
  writes outside `skills/agents/memory`.
- Slightly more operator complexity (two files). Mitigated by good error
  messages and a `seal config show` CLI that reads **both** files and presents
  a unified view, so the operator mental model stays single-file. This CLI
  subcommand is a listed deliverable alongside B (it does not exist today).
- Migration: existing `config.toml` with `[untrusted_execution]` is migrated
  to `security.toml` at boot (one-time, idempotent, with a stderr warning).
  If migration fails (e.g., write permission denied), boot proceeds with the
  legacy `config.toml` value read directly (fail-open for boot; the guarantee
  applies to *agent mutation*, not to a broken migration), and a loud error
  is logged. Operator must fix permissions and restart.

---

### Approach C — Signed / pinned config (cryptographic)

**Idea:** The operator signs `security.toml` (or the `untrusted_execution`
section) with a private key whose public half is baked into the harness or
stored under `~/.seal/keys/` (the already mode-0700, never-version-controlled
keys dir). At boot, the harness verifies the signature; on mismatch, boot
refuses (or refuses to *lower* the security posture — see §5 variant).

**Mechanism:**
- `security.toml.sig` alongside `security.toml`, produced by
  `seal config sign --key <path>`.
- At boot: verify signature against a pinned public key
  (`~/.seal/keys/security.pub`, mode 0600). If verification fails → boot error.
- Any rewrite of `security.toml` without re-signing is detected at next boot.
- The signing key never lives where an opcode can read it: `keys/` is mode
  0700 and `SafePath` blocks `.seal`.

**Strengths:**
- Tamper-evident across reboots even if *some* code path can write the file.
- The agent has no path to the signing key (keys dir is off-limits to opcodes).
- Defense-in-depth: even a future buggy opcode that can write `security.toml`
  cannot forge a signature.

**Weaknesses:**
- Only catches tampering at **boot**, not mid-session (the running process
  already has the trusted config in memory). This is fine for V1 (the flip
  takes effect on next boot), but it's a "detect and refuse" model, not a
  "prevent the write" model.
- Operator burden: must re-sign after legitimate edits. This is real friction.
  Mitigated by `seal config sign` CLI + a dev mode that skips verification.
- Overkill for the current threat model? The agent already cannot write
  `security.toml` via opcodes (Approach B). This adds a backstop for
  hypothetical future code bugs. Worth it for a "high certainty" requirement,
  but Approach B + A may suffice.
- Key management is its own surface (key rotation, lost key → lockout).

**Variant — "ratchet" (monotonic security):** ~~Record the highest security
posture ever seen in the audited log and refuse to lower it.~~ **Withdrawn in
Round 2.** This variant relied on the audited log being a tamper-proof,
hash-chained, off-box-mirrored append-only log. Verified against source:
the session transcript is append-only single-writer + fsync, **explicitly
NOT a hash chain** (`Handles/Transcript.hs:21-22`, `Transcript/Entries.hs:11-12`),
and **there is no longer an Audited branch** in the dispatcher
(`ISA/Dispatch.hs:10` — Audited is treated as Trusted, recording only to the
per-session transcript). There is no off-box mirror. The README §"Audited"
(lines 99-104) is stale documentation drift from the Phase 5 pivot. A
ratchet would require building a new hash-chain + off-box mirror as a
prerequisite, which is a separate large feature. Without it, a control-plane
process can rewrite/truncate the JSONL, so a ratchet recorded there is not
tamper-proof. The variant is dropped; do not rely on it.

---

### Approach D — Compile-time pin via Cabal flag (extend Layer B)

**Idea:** Extend the existing `remote-only-untrusted` Cabal flag so that, when
on, the `untrusted_execution.mode` field is **hardwired to `remote` at the
type level** — the config file field is *ignored* (or absent from the codec
under the flag). This is a sharpening of the existing Layer B.

**Mechanism:**
- Under `flag(remote-only-untrusted)`, `untrustedExecConfigFromFile` always
  returns `Just (UntrustedExecConfig UemRemote remote)` regardless of the
  TOML — the `mode` field is not parsed. (Today it parses and then
  `enforceRemoteOnly` rejects `local`; this goes further by not parsing it.)
- Equivalently: the `FileConfig` codec under the flag omits the `mode` field.
- There is no value of `mode` an opcode can set that changes behavior, because
  the field is never read.

**CI breakage — resolved (was Round 1 Open Question 3):** The sharpening
changes `enforceRemoteOnly`'s behavior from "reject `mode=local`" to "the
field is absent/ignored." Two existing tests assert the *rejection* behavior
and **will break**:
- `test/Seal/Tools/Exec/UntrustedSpec.hs:106-116` — asserts `mode=local` is
  `Left`-rejected.
- `test/Seal/Phase4Spec.hs:88-92` — asserts the same.

**Resolution:** Approach D is *tertiary* in the recommendation. To avoid
breaking these tests, D is **re-scoped**: keep `enforceRemoteOnly` as-is
(reject `mode=local` — this is a useful defense-in-depth even when the field
is also ignored for resolution), and add a *separate* behavior: under the
flag, `untrustedExecConfigFromFile` *ignores* the parsed `mode` for the
purpose of resolving the backend, while `enforceRemoteOnly` still rejects a
`local` value at startup as a configuration-error signal. Both behaviors
coexist: the field is ignored for resolution (D's guarantee) AND rejected as
a config error (existing tests pass). No test updates required. The
implementation plan adds a *new* test asserting "under the flag, a
`mode=local` config still resolves to remote (the field is ignored for
backend selection) even as `enforceRemoteOnly` rejects it as a config
error."

**Strengths:**
- Strongest single defense: the binary physically ignores the field.
  V1/V2 are impossible — there is nothing to flip.
- Reuses the existing flag infrastructure.
- Zero runtime cost.

**Weaknesses:**
- Only available on the **hardened build**. Default builds (Layer A) get no
  benefit. This is the existing Layer B limitation — it's a deploy-time
  choice, not a universal guarantee.
- An operator who wants "high certainty" must deploy the hardened binary.
  That's a reasonable requirement for a security-critical deployment, but it
  means the guarantee is *opt-in per deployment*, not universal.
- Does not help operators who run the default build for convenience.

---

### Approach E — Type-level split: `MutableConfig` vs `BootstrapConfig`

**Idea:** Split `FileConfig` into two types at the Haskell level:
- `BootstrapConfig` — read once at boot, never re-read, never passed to any
  opcode. Contains `untrusted_execution`, vault settings, and any future
  boot-only security knobs. Stored in `AppEnv` as a pure value.
- `MutableConfig` — the agent-mutable fields (provider settings, default
  agent, retrieval tuning, etc.). `CONFIG_VIEW` / `CONFIG_UPDATE` operate on
  this type only.

**Mechanism:**
- `AppEnv` holds `aeBootstrap :: BootstrapConfig` (pure, set once) and
  `aeMutable :: IORef MutableConfig` (or re-read on demand).
- `CONFIG_UPDATE`'s signature is
  `MutableConfig -> MutableConfig` — it physically cannot mention
  `untrusted_execution` because the field is not in the type.
- A future opcode that wants to change bootstrap config is a **compile
  error**: the field is not in scope.
- **`updateFileConfig` is also narrowed to `MutableConfig`** — not just the
  opcode path. This closes V6 (the HTTP Gateway caller): the Gateway's
  `handleAgentSetDefault` (`API.hs:693,706`) would consume `MutableConfig`
  and physically cannot express a change to `fcUntrustedExec`. A separate,
  non-opcode `saveSecurityConfig` (Approach B) handles the security file, and
  it is never called by an opcode or the Gateway.

**Field assignment** (which `FileConfig` fields move to `BootstrapConfig` vs
stay in `MutableConfig`):

| `FileConfig` field (`Config/File.hs:53-114`) | Goes to | Rationale |
|---|---|---|
| `fcUntrustedExec` | `BootstrapConfig` | The security-critical boot-only knob |
| `fcVaultPath`, `fcVaultRecipient`, `fcVaultIdentity`, `fcVaultUnlock`, `fcVaultKeyType` | `BootstrapConfig` | Vault is boot-only; unlock is a human step |
| `fcProviders` | `MutableConfig` | Mutated by `/provider` command (`Provider.hs:170`) |
| `fcDefaultProvider`, `fcDefaultModel` | `MutableConfig` | Mutated by `/provider default` |
| `fcDefaultAgent` | `MutableConfig` | Mutated by Gateway `PUT /api/agents/default` (`API.hs:706`) |
| `fcRetrieval` | `MutableConfig` | Runtime tuning |
| `fcOnDemandSchemas` | `MutableConfig` | Runtime flag |
| `fcDelegation` | `MutableConfig` | Runtime resolver |
| `fcSignal`, `fcTelegram`, `fcGateway` | `MutableConfig` | Channel config (mutable at runtime) |

**Strengths:**
- Converts V1 from "validation catches it" (Approach A) to "it doesn't
  typecheck." This is the strongest guarantee short of Approach D.
- Works on **both** Layer A and Layer B builds — it's not flag-gated.
- Scales: any future boot-only security knob lands in `BootstrapConfig` and
  is automatically agent-immutable by construction.
- Idiomatic Haskell: the type system does the enforcement, matching the
  project's "security by construction" philosophy (README §"Security by
  Construction").

**Weaknesses:**
- Largest refactor of the five: touches `FileConfig`, the codec, `AppEnv`,
  every config-mutating call site. ~5-10 files, careful migration.
- `CONFIG_UPDATE` is not yet implemented, so the split can be done *before*
  the opcode exists — cheaper now than later. But it touches
  already-working code (`updateFileConfig` consumers: provider, agent,
  vault commands, gateway API).
- The agent could still write `config.toml` directly via a hypothetical
  future file opcode (V3). The type split protects the *opcode* path, not
  the *file* path. Combine with Approach B (separate file) for full coverage.

---

## 5. Combinations & a "ratchet" variant

The approaches layer:

| Layer | What it stops | When | Vectors closed |
|---|---|---|---|
| D (compile-time pin) | Field is ignored entirely for backend resolution | Hardened build only | V1, V2 |
| E (type split, incl. `updateFileConfig` narrowing) | Opcode AND Gateway caller cannot express the change | All builds, compile time | V1, V2, V6 |
| A (runtime immutable) | Opcode rejects the change at session-start seam | All builds, runtime | V1, V2 (if E deferred) |
| B (separate file, outside git repo) | No opcode field to change; git can't resurrect it | All builds, structural | V1, V2, V3, V8 |
| C (signed config) | Tamper detected at boot | All builds, boot time | backstop for hypothetical code bugs |
| File-lock `MVar` around `updateFileConfig` | Prevents lost-update race | All builds, runtime | V7 |
| Gateway fail-closed on non-loopback | Network attacker can't reach the config-write surface | All builds, boot/runtime | V6 (network variant) |

A **ratchet** variant on C: **withdrawn** — see §4 Approach C for the
withdrawal rationale (the audited log is not a tamper-proof hash chain).

## 6. Recommendation

For "high certainty" with pragmatic cost, a **defense-in-depth stack**:

1. **Approach E (type-level split, including narrowing `updateFileConfig` to
   `MutableConfig`) — primary.** This is the structural guarantee.
   `CONFIG_UPDATE` (when implemented) AND the HTTP Gateway caller cannot
   express a change to `untrusted_execution` — it's a compile error on both
   paths (closes V1, V2, V6). It matches the project's "security by
   construction" ethos and works on all builds. Do this *before*
   `CONFIG_UPDATE` is implemented so the split is designed-for, not
   retrofitted.

2. **Approach B (separate `security.toml`, outside the git repo) —
   secondary.** Removes the field from the agent-reachable config file
   entirely (closes V3, V8). Pairs with E: `BootstrapConfig` is loaded from
   `security.toml` (at `~/.seal/security.toml`, not inside the git-versioned
   `config/`), `MutableConfig` from `config.toml`. The `seal config show` CLI
   reads both and presents a unified view.

3. **Approach D (compile-time pin under flag) — tertiary, for hardened
   deployments.** Already partially exists; sharpen it to *ignore* `mode`
   for backend resolution under the flag while keeping `enforceRemoteOnly`'s
   rejection as a config-error signal (no test breakage — see §4 D).

4. **Approach A (runtime immutability predicate) — include as a cheap
   backstop** if E is deferred. If E ships, A is subsumed (the type already
   prevents it) but a runtime check + error message is cheap insurance
   against a future refactor that re-merges the types. **Must apply at the
   session-start seam** (`Loop.hs:498`, `Cli.hs:305`, `Send.hs:276`), not
   only `Tui.hs:73`.

5. **V7 (config-write race): serialize `updateFileConfig`** behind a
   process-wide `MVar` (or file lock). Cheap, independent of the above, and
   fixes a real existing bug regardless of this design.

6. **V6 (Gateway network exposure): make the Gateway fail-closed on
   non-loopback** when `mode=remote` (refuse to boot, not warn). This is a
   separate, orthogonal hardening that the security review surfaced — it
   should be a standalone task regardless of this design.

7. **Approach C (signed config) — defer.** Only worth the operator friction
   if there's a credible threat of a *code* path writing `security.toml`
   outside the opcode+Gateway systems. With E + B in place (type-level +
   separate file + path confinement), that threat is low.

**Why not C now (revised):** ~~The existing audited-log + SafePath +
Untrusted-on-remote combination already means the agent cannot write the
config in remote-only mode.~~ **Corrected:** The existing SafePath `.seal`
block + Untrusted-on-remote combination means the agent's *file opcodes*
cannot reach the config in remote-only mode. The threat is a *future
opcode* (`CONFIG_UPDATE`) and an *existing* Gateway caller, both on the
control plane. E + B close those structurally: E makes the opcode+Gateway
path a compile error, B removes the field from the file the opcode reads. C
would only add value if a code bug *re*-opens the write path — and E
(type-level) makes that bug a compile error, which is strictly better than a
runtime signature check. The session transcript is NOT a tamper-proof
hash-chained log (verified — see §4 C ratchet withdrawal), so do NOT lean on
it for this argument.

## 7. Relationship to the existing two-layer design

| Existing layer | This design's role |
|---|---|
| Layer A (runtime fail-closed, `mode=remote`) | Unchanged in behavior. Approach E ensures the `mode` value cannot be agent-flipped. |
| Layer B (compile-time hardened flag) | Sharpened by Approach D: under the flag, `mode` is *ignored*, not *rejected*. |

This design does not replace Layers A/B; it **closes the self-modification
gap between them** — the gap where an agent on a Layer-A build could flip
`mode` via a future opcode. It is an Amendment to the upstream spec, to be
recorded in §4 of `2026-06-28-remote-only-untrusted-execution-design.md`
alongside the existing Phase 4 amendment.

## 8. Error message contract (operator-facing)

The operator can see these messages. Each has a one-line remediation.

| Scenario | Message | Remediation |
|---|---|---|
| `CONFIG_UPDATE` attempts to change `untrusted_execution` (with Approach A, if E is deferred) | `untrusted_execution is immutable at runtime; edit ~/.seal/security.toml directly and restart` | Edit `security.toml` and restart the harness |
| With Approach E (type split), a future developer tries to add `fcUntrustedExec` to a `MutableConfig` update | **compile error** (not operator-visible) — "Not in scope: fcUntrustedExec" | N/A (structural) |
| Hardened build with `mode=local` in `security.toml` (existing `enforceRemoteOnly`) | `remote-only-untrusted build: untrusted_execution.mode=local is rejected (the local executor is absent from this binary)` | Set `mode=remote` in `security.toml` or use a default build |
| Migration of `[untrusted_execution]` from `config.toml` to `security.toml` (first boot after upgrade) | `[seal] migrating [untrusted_execution] from config.toml to security.toml (one-time). Edit security.toml for future changes.` | None (automatic) |
| Migration fails (write permission denied) | `[seal] WARNING: could not write security.toml — reading untrusted_execution from config.toml for this session. Fix permissions at ~/.seal/ and restart.` | Fix `~/.seal/` permissions and restart |
| Gateway binds non-loopback with `mode=remote` (V6 mitigation) | `refusing to start gateway on non-loopback address <addr> in remote-only mode — bind 127.0.0.1 or disable remote-only` | Bind loopback or set `mode=local` (if you accept the risk) |
| `security.toml` absent and no `[untrusted_execution]` anywhere | (silent — defaults to `mode=local` on default build; fail-closed at call time on hardened build) | Create `security.toml` with `[untrusted_execution] mode = "remote"` + remote block |

## 9. Test specifications (TDD readiness)

### 9.1 Approach E — compile-fail fixture (CRITICAL)

The project already has the infrastructure: `test/Seal/TestHelpers/CompileFail.hs`
(`assertCompileFail`) and `test/Seal/Tools/Exec/CapabilityScopingFailSpec.hs`
(the analogous capability-scoping fixture from upstream spec §8). Add a
parallel fixture:

**Test: `test/Seal/Config/BootstrapScopingFailSpec.hs`**
- Asserts a source string defining a `CONFIG_UPDATE` handler typed
  `MutableConfig -> MutableConfig` that tries to reference `fcUntrustedExec`
  (or `BootstrapConfig`) **fails to compile** with "Not in scope" or
  "Couldn't match type `MutableConfig` with `BootstrapConfig`".
- Uses `assertCompileFail "config_update_cannot_touch_bootstrap" "Not in scope" src`.

This is the single most important test: it verifies the design's headline
claim ("V1 becomes a compile error") is real, not a convention.

**Test: Gateway caller compile-fail**
- Asserts a source string calling `updateFileConfig` (narrowed to
  `MutableConfig`) with a lambda that tries to set `fcUntrustedExec` fails to
  compile. Closes V6 structurally.

### 9.2 Approach B — file isolation tests

**Test: `SecurityConfigSpec.hs`** (new, mirrors `FileSpec.hs` patterns)
- `security.toml` present with `[untrusted_execution] mode = "remote"` →
  `loadSecurityConfig` returns `Just (UntrustedExecConfig UemRemote ...)`.
- `security.toml` absent, `[untrusted_execution]` present in `config.toml` →
  migration runs; `security.toml` written; section removed from `config.toml`;
  `loadSecurityConfig` returns the migrated value.
- Both present → `security.toml` wins (precedence); `config.toml` section is
  ignored (or absent post-migration).
- Malformed `security.toml` → boot proceeds (fail-open for boot per §4 B
  weaknesses), `loadSecurityConfig` returns `Nothing`, untrusted opcodes
  fail-closed at call time. A stderr error is logged.
- **File-mode assertion:** after `loadSecurityConfig` creates `security.toml`,
  assert its file mode is `0o600`.
- `security.toml` is NOT inside `~/.seal/config/` (the git repo) — assert
  its path is `~/.seal/security.toml` (sibling), so git history cannot
  resurrect it (V8).

### 9.3 Migration test

**Test: `ConfigMigrationSpec.hs`** (new)
- Migration from `config.toml` with `[untrusted_execution]` produces an
  equivalent `UntrustedExecConfig` in `security.toml`.
- Migration removes the `[untrusted_execution]` section from `config.toml`.
- Migration is **idempotent** — running it twice does not duplicate or error.
- Migration with a corrupted `[untrusted_execution]` (e.g., `mode=local` but
  no remote block) preserves the value as-is (migration is a move, not a
  validation — validation is `enforceRemoteOnly`'s job).

### 9.4 Breaking changes to existing tests

**`test/Seal/Config/FileSpec.hs:244-323`** — the `"untrusted_execution
section"` describe block has parse + round-trip tests for the field in
`FileConfig`. Approach B removes the field from the `FileConfig` codec. These
tests **will break** and must be:
- Moved to `SecurityConfigSpec.hs` (§9.2), testing `loadSecurityConfig`
  instead of `loadFileConfig`.
- The `FileSpec` round-trip test asserting `[untrusted_execution]` survives
  a `config.toml` save→load cycle is **deleted** (the field is no longer in
  `config.toml`).

This is a named work item in the implementation plan.

### 9.5 Approach D — no test breakage (resolved)

Per §4 D (re-scoped): `enforceRemoteOnly` still rejects `mode=local`
(existing tests `UntrustedSpec.hs:106-116`, `Phase4Spec.hs:88-92` pass
unchanged). A **new** test asserts: under the flag, a `mode=local` config
still *resolves* to remote for backend selection (the field is ignored for
resolution) even as `enforceRemoteOnly` rejects it as a config error.

### 9.6 QuickCheck property (preserved from upstream §8)

The existing property "∀ config/opcode, untrusted ⇒ Ssh-or-failure" (at
`UntrustedSpec.hs:53-58, 83-88`) is **preserved unchanged** under E+B — the
`selectExecBackend` / `selectUntrustedBackend` pure functions are unchanged.
Add a new property: "no value of `MutableConfig` affects
`selectExecBackend`'s remote-only arm" — i.e., the bootstrap field is
provably unreachable from the mutable config.

## 10. Scope & non-goals

**In scope:**
- Prevent agent-driven modification of the `untrusted_execution` config via
  the opcode path (V1, V2) and the Gateway path (V6).
- Prevent config-write races (V7) and git-history rollback (V8).
- Define the type-level and file-level mechanisms.
- Position relative to the existing two-layer design.

**Out of scope (this design):**
- Implementing `CONFIG_UPDATE` itself (separate future task).
- Binary signing / supply-chain (V5).
- OS-level sandboxing / seccomp (separate hardening track).
- Multi-tenant config isolation.
- V4 (`SEAL_HOME`) — mitigated by E (bootstrap loaded from a boot-resolved
  path, never re-resolved). The implementation plan includes a sentence
  confirming `resolveSealHome` is called once at boot and the result cached.

## 11. Resolved open questions (from Round 1 review)

1. **~~E vs A as primary~~ — RESOLVED: E is primary, A is backstop.** E
   recommended because the refactor is cheap *now* (no `updateFileConfig`
   consumer references `fcUntrustedExec` — verified by grep; the field
   moves cleanly) and grows if `CONFIG_UPDATE` lands first. A is included
   as a runtime backstop in case E is deferred.

2. **~~`security.toml` "in addition to" vs "instead of"~~ — RESOLVED:
   "instead of".** The field is removed from `config.toml`'s codec. A
   one-time boot migration moves existing values. Pre-alpha status (README:17)
   means migration cost is acceptable. Resolving here (not deferring to the
   plan) per Designer reviewer B2.

3. **~~Does Approach D break CI?~~ — RESOLVED: no.** D is re-scoped (§4 D):
   keep `enforceRemoteOnly` rejection (existing tests pass), add
   field-ignoring for backend resolution under the flag (new test). No
   existing test updates required.

4. **~~Should `CONFIG_VIEW` read `untrusted_execution.mode`?~~ — RESOLVED:
   redacted view.** `CONFIG_VIEW` (when implemented) operates on
   `MutableConfig` only, so it **physically cannot** print the remote block
   (a secondary win of E). If a separate operator-facing `seal config show`
   is added, it shows `mode` and the remote `host` but NOT `identity` /
   `known_hosts` (SSH key material). Promoted from open question to
   recommendation per Designer reviewer S5.

## 12. Next steps (if design is approved)

1. Write implementation plan, decomposed into work units:
   - **W1: Type split (E)** — split `FileConfig` into `BootstrapConfig` +
     `MutableConfig`; narrow `updateFileConfig` to `MutableConfig`; wire
     `aeBootstrap` in `AppEnv`; update all `updateFileConfig` consumers
     (`Vault/Commands.hs`, `Gateway/API.hs`, `Command/Provider.hs`,
     `Command/Model.hs`, `Command/Agent.hs`) to the narrower type.
   - **W2: Separate file (B)** — `loadSecurityConfig` from
     `~/.seal/security.toml` (outside git repo); remove `[untrusted_execution]`
     from `config.toml` codec; boot-time migration.
   - **W3: Path confinement + file lock** — `saveSecurityConfig` hard-wired
     path (V3); process-wide `MVar` around `updateFileConfig` (V7).
   - **W4: Compile-fail fixture (§9.1)** — `BootstrapScopingFailSpec.hs` +
     Gateway-caller fixture.
   - **W5: File isolation + migration tests (§9.2, §9.3)** —
     `SecurityConfigSpec.hs`, `ConfigMigrationSpec.hs`; move/delete
     `FileSpec.hs:244-323`.
   - **W6: Approach D sharpening (§9.5)** — ignore `mode` for resolution
     under flag; new test; no existing breakage.
   - **W7: Gateway fail-closed on non-loopback (V6)** — standalone task;
     refuse boot on non-loopback when `mode=remote`.
   - **W8: `seal config show` CLI** — reads both files, unified redacted view.
2. Plan review gate (3 adversarial reviewers), then orchestrated execution
   (IMPLEMENT → VALIDATE → ADVERSARIAL REVIEW → COMMIT per work unit).
3. V4 mitigation sentence in W1: confirm `resolveSealHome` called once at
   boot; cache result.