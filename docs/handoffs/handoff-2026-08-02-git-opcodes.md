# Handoff: Git Opcodes + SSH Agent Forwarding (no un-encrypted secret on disk)

**Date**: 2026-08-02 · **Branch**: `feat/git-opcodes-agent-forwarding` (pushed) · **Base**: `feat/source-control-repos` (PR #80, open) · **Issue**: #81

## 1. Objective

Replace PR #80's on-disk `GIT_ASKPASS`/keyfile credential seam with **SSH agent forwarding** for deploy keys (the private key never crosses to the untrusted machine; a compromised binary gets only a per-op, per-repo signing oracle) and `http.extraHeader`-in-argv for PATs (no disk, token-in-untrusted-memory residual). Add typed `GIT_FETCH`/`GIT_PULL`/`GIT_PUSH` opcodes; revise `SETUP_REPO` to registry-lookup + credential-injection + bare-URL fallthrough; auto-generate a fresh per-repo deploy key at repo-create time. **Binding requirement:** no un-encrypted secret on disk, on either machine (encrypted-on-disk is permitted — same category as the age-encrypted vault file).

**The concrete user goal:** a registered private GitHub SSH repo (`git@github.com:seal-harness/seal-harness.git`) clones successfully via `SETUP_REPO` on the first try with no host credentials.

## 2. The credential mechanism (final — encrypted keyfile on the harness disk)

**Deploy keys (preferred):**
- **Generate** (repo-create, on the harness): `ssh-keygen -t ed25519 -f <harness-keyfile-path> -N "<random-vault-passphrase>" -C "seal-deploy-key:<repo-id>"` → writes an **encrypted** (`aes256-ctr`/`bcrypt`) private key to `<harness-keyfile-path>` + a public key to `<harness-keyfile-path>.pub` under a 0700 harness-private dir (`~/.seal/state/repos/keys/`). The random passphrase is stored in the vault under `seal-deploy-key-passphrase:<repo-id>`. The encrypted keyfile stays on the harness disk (ciphertext — satisfies the rule). The public key is stored on `srDeployKeyPublic`.
- **Use** (git-op, on the harness): per-op `ssh-agent` → `printf '<passphrase>\n' | SSH_ASKPASS_REQUIRE=never ssh-add <encrypted-keyfile>` (passphrase from `vhGet`, piped to `ssh-add`'s stdin — **verified non-interactive**) → agent decrypts the keyfile into memory → `ssh -A user@untrusted -- git ...` forwards the socket → after the op, `ssh-add -D` + kill the agent.
- **The untrusted machine never sees the keyfile** (encrypted or otherwise) — only the forwarded agent socket.
- **Repo-remove cleanup**: delete the encrypted keyfile + `.pub` + the passphrase vault entry.

**PATs (fallback):** `git -c http.extraHeader='Authorization: Basic <base64(user:token)>'` in argv (memory, no file). Token-in-untrusted-memory residual (documented; deploy keys preferred).

**This eliminates the pure-Haskell OpenSSH serializer** (the biggest risk from earlier revisions) — `ssh-keygen` produces the format, `ssh-add` consumes it.

## 3. Definition of Done (design §9 — 12 criteria)

1. No un-encrypted secret on disk, either machine (no-disk snapshot test — the encrypted keyfile on the harness disk IS permitted; the untrusted workdir has only the public `known_hosts`).
2. Deploy keys preferred; fresh per-repo key auto-generated at repo-create; public key + host-aware instructions shown; private key never rendered.
3. SSH agent forwarding (per-op): private key never crosses to untrusted; compromised binary / co-resident process gets a per-op, per-repo signing oracle (exactly one identity live — verified by the per-op scoping test).
4. Host-key verification via pre-pinned GitHub keys (`StrictHostKeyChecking=yes`, no `accept-new`/`/dev/null`).
5. `SETUP_REPO` clones registered deploy-key via forwarded agent; registered PAT via `http.extraHeader`; unregistered falls through.
6. `GIT_FETCH`/`PULL`/`PUSH` work first-try for a registered repo (one opcode call → success, no retry).
7. `GIT_PUSH` Audited (audit written via `runLocal` before the untrusted git run); secret-free audit entry carrying `credential_kind`.
8. No `ToJSON` on secret carriers; no secret in any API response/log/transcript; `GET /api/repos/:id/deploy-key` returns public key only.
9. PAT residual (token-in-untrusted-memory + swap edge) documented in `/repo add --cred pat` help + `ReposView` advisory.
10. `-A` opt-in per git-op (non-credentialed remote ops have no `-A` — `RemoteSpec`).
11. `make check` + frontend gate green; `Env` gains `VaultHandle`/`RepoRegistryHandle` (mkEnv); no `SessionRuntime` field.
12. **User goal: registered `git@github.com:seal-harness/seal-harness.git` clones via `SETUP_REPO` first-try.**

## 4. Current Status

**Done & verified:**
- Design doc: `docs/superpowers/specs/2026-08-02-git-opcodes-agent-forwarding-design.md` — **5/5 design-gate APPROVED (round 2)**, **feasibility re-verified (round 3, PASS)**, **rev 3** (encrypted-keyfile approach, user-approved). Latest commit `5037409` on the branch (pushed).
- GitHub issue #81 filed: https://github.com/seal-harness/seal-harness/issues/81
- **Implementation plan**: `.beads/plans/git-opcodes-plan.md` — **fully updated to match design rev 3** (encrypted keyfile; opcodes Untrusted; env `env VAR=val` prefix; `Env` fields; `UntrustedIORemoteSpec` in W2 scope; W1–W6 RED-GREEN-REFACTOR). Ready for the plan review gate + execution.
- Empirical verifications on record: `ssh-keygen -f -` writes to a file named `-` (not stdout); `printf '<pass>\n' | SSH_ASKPASS_REQUIRE=never ssh-add <enc-file>` works non-interactively; GitHub's published host keys are public data; `crypton` has ed25519 primitives (not needed now but confirmed); `ssh-add -D` + `ssh-agent -k` work.

**Not started:**
- W1–W6 implementation (none of the code is written).

### Working tree
- Branch `feat/git-opcodes-agent-forwarding`, **pushed** to origin.
- Uncommitted: `.beads/plans/git-opcodes-plan.md` (the plan; `.beads/` is gitignored — working state, NOT committed). **The plan is on disk at `.beads/plans/git-opcodes-plan.md` — read it first.**
- Recent commits: `5037409` (rev 3 encrypted keyfile), `c5f410a` (rev 2 feasibility fixes), `81ccf58` (rev 1), `802ca71` (initial design).

## 5. Required Reading (read these before acting, in order)

| # | Path | Why | What to look for |
|---|---|---|---|
| 1 | `.beads/plans/git-opcodes-plan.md` | **The implementation plan — START HERE.** | W1–W6 DoD, file scopes, RED-GREEN-REFACTOR per WU, the credential mechanism (§2), the security table. Ready for the plan gate + execution. |
| 2 | `docs/superpowers/specs/2026-08-02-git-opcodes-agent-forwarding-design.md` | The approved design (source of truth) | §4.1.1 (encrypted-keyfile keygen/use), §4.2 (opcodes Untrusted — GIT_PUSH audit via runLocal), §4.4 (env `env VAR=val` prefix), §4.6 (per-op agent), §4.7 (Generate flow + repo-remove cleanup), §5 (security), §7 (W1–W6), §8 (18 resolved decisions), §9 (12 AC) |
| 3 | `docs/superpowers/specs/2026-08-02-source-control-repo-registry-design.md` + PR #80 | The base feature (the registry + the on-disk seam being replaced) | The `SourceRepo`/`RepoCredential`/`RepoRegistry`/`Clone` types this builds on |
| 4 | `src/Seal/ISA/Opcode.hs` | The opcode trust model | `TrustedOpcode.toRun` has NO `UntrustedIO`; `UntrustedOpcode.uoRun` does — that's why the git opcodes MUST be Untrusted |
| 5 | `src/Seal/Tools/Exec/UntrustedIO.hs` | The capability seam W2 extends | `uioShellExec`/`uioBinExec` (no env today); W2 adds `uioShellExecEnv`/`uioBinExecEnv`; remote arm needs `env VAR=val` prefix |
| 6 | `src/Seal/Tools/Exec/Remote.hs` | The SSH executor W2 adds opt-in `-A` to | `sshExecArgv` line 47; `mkFakeRemoteRunnerRecording` line 171 (signature change ripples to ~15 sites in `UntrustedIORemoteSpec.hs`) |
| 7 | `src/Seal/Types/Env.hs` | W3 adds `VaultHandle`+`RepoRegistryHandle` here | `mkEnv` line 25 is the single constructor (small blast radius) |
| 8 | `src/Seal/ISA/Ops/Repo.hs` | `normalizeRepoUrl` (line 157) — W1 moves to `SourceControl.Repo`; `setupRepoOp` — W3 revises + its 5 call sites | `setupRepoOp wsRoot autonomy` gains a CloneDeps param |

## 6. Key Decisions & Rationale (do not undo)

- **Encrypted keyfile on the harness disk** (rev 3, user-approved) — `ssh-keygen -N "<vault-passphrase>"` writes an encrypted keyfile (ciphertext) to the harness private state dir; the passphrase lives in the vault; `ssh-add` decrypts at git-op time using the passphrase piped to its stdin. Satisfies "no *un-encrypted* secret on disk." Eliminates the pure-Haskell OpenSSH serializer (the biggest implementation risk). The untrusted machine only sees the forwarded agent socket.
- **Per-op ssh-agent, NOT session-scoped** — session-scoped accumulates keys across a multi-repo session, breaking the per-repo oracle-scoping claim. Per-op (start → `ssh-add` one key → run → `ssh-add -D` + kill) guarantees exactly one identity live.
- **Pre-pinned GitHub host keys, NOT `accept-new`/`/dev/null`** — `accept-new`+`/dev/null` is zero host-key verification (MITM). Pre-pin GitHub's published keys (public data) with `StrictHostKeyChecking=yes`.
- **Opt-in `-A` per git-op, NOT blanket `sshExecArgv`** — a blanket `-A` forwards the agent for every remote op, widening the oracle surface.
- **Git opcodes are Untrusted, NOT Trusted** — `TrustedOpcode.toRun` has no `UntrustedIO` in scope; an opcode that executes git on the untrusted machine MUST be `UntrustedOpcode`. `GIT_PUSH`'s audit is written via `runLocal` before the untrusted git run (per-opcode audit, not a new constructor).
- **Remote-arm env via `env VAR=val` prefix in the command string** — `ssh -A` only forwards the agent socket; `SendEnv`/`SetEnv` need server `AcceptEnv` (default `none`). The `env` prefix is portable.
- **`Env` gains `VaultHandle`+`RepoRegistryHandle`** (centralized in `mkEnv`); `setupRepoOp` gains a CloneDeps param (5 call sites); **no `SessionRuntime` field** — the agent is a per-op `CloneDeps` value.
- **User directive**: proceed without stopping at user gates; the two scheduled checkpoints (after W2, before PR) are self-reviewed adversarially (fresh security-auditor after W2; fresh code-review before PR).

## 7. Code Map

- `src/Seal/SourceControl/Repo.hs` (W1: `lookupRepoByUrl`, shared `normalizeRepoUrl`, `CredAccountKey` codec fail-closed)
- `src/Seal/SourceControl/Clone.hs` (W2: revised — remove `writePrivateTempFile`/`escapeSingle`/`renderAskpassHelper`; per-op agent via `SshAgentHandle`; `http.extraHeader`; `CloneDeps`)
- `src/Seal/SourceControl/GithubKeys.hs` (W2: NEW — `file-embed` pinned GitHub host keys)
- `src/Seal/Tools/Ssh/Agent.hs` (W2: NEW — `SshAgentHandle` seam: `sahStart`/`sahAddKey`/`sahDeleteAll`/`sahKill`/`sahGetAuthEnv`; real + fake impls)
- `src/Seal/Tools/Exec/Remote.hs` (W2: opt-in `ForwardAgent` on `sshExecArgv`)
- `src/Seal/Tools/Exec/UntrustedIO.hs` (W2: `uioShellExecEnv`/`uioBinExecEnv`; remote arm `env VAR=val` prefix)
- `src/Seal/ISA/Ops/Repo.hs` (W3: `SETUP_REPO` revision — registry lookup + credential injection + bare-URL fallthrough)
- `src/Seal/ISA/Ops/Git.hs` (W4: NEW — `GIT_FETCH`/`GIT_PULL`/`GIT_PUSH`, Untrusted; `GIT_PUSH` audit via `runLocal`)
- `src/Seal/Types/Env.hs` (W3: add `VaultHandle`/`RepoRegistryHandle` to `Env` + `mkEnv`)
- `src/Seal/Config/Paths.hs` (W5: `repoKeysDir`)
- `src/Seal/Gateway/API.hs` (W5: `generate_key`, `GET .../deploy-key`, `POST .../deploy-key/generate`, repo-remove keyfile cleanup)
- `frontend/src/components/ReposView.tsx` (W5: the Generate flow)
- Pattern to imitate: `Seal.Tools.Exec.Remote` (`RemoteRunner` record-of-IO-actions + recording fake), `Seal.Security.Vault` (`VaultHandle`), `Seal.ISA.Ops.Repo` (`setupRepoOp` UntrustedOpcode shape)

## 8. How to Verify

```bash
make check              # build + cabal test + hlint (the gate)
cd frontend && npm run build && npm test && npx tsc --noEmit   # frontend gate
```
- **No-disk test** (`CloneSpec`): snapshot `~/.seal/` + the untrusted workdir before; run clone+fetch+push; snapshot after; assert no UN-ENCRYPTED secret appears (the encrypted keyfile under `~/.seal/state/repos/keys/` IS permitted; the `<workdir>/.seal-known-hosts` is public data).
- **Per-op scoping test** (`CloneSpec`): two sequential ops for different repos; assert the fake `SshAgentHandle` sees exactly one `sahAddKey` + `sahDeleteAll` + `sahKill` per op.
- **`-A` invariant test** (`RemoteSpec`): non-credentialed remote ops' argv has no `-A`; git-credential ops' has `-A`.
- **End-to-end (issue #81 AC12)**: a registered `git@github.com:seal-harness/seal-harness.git` clones via `SETUP_REPO` first-try (a test against a local fixture, or a documented manual verification — the design-gate can decide; the registry host allow-list is `github.com`, so a local-fixture test may need to bypass `planClone`'s allow-list via the mechanism-test pattern from PR #80's CloneSpec).

## 9. Open Questions / Blockers

- **The plan review gate has not been re-run** on the rev-3 plan. The plan is drafted and matches the approved design, but the 3-reviewer plan gate (Feasibility, Completeness, Scope) should be run before execution — the round-1 plan gate found 5 real feasibility blockers (now fixed in the design), so the gate earns its keep.
- HPC coverage measurement is pending project-wide (`.coverage-thresholds.json` `make test` runs the suite but doesn't measure) — not a blocker for this PR.
- No remaining known feasibility landmines — the encrypted-keyfile approach removed the OpenSSH-serializer risk; the rest mirrors PR #80's patterns.

## 10. Next Action

**Run the plan review gate** (3 adversarial reviewers: Feasibility, Completeness, Scope & Alignment) on `.beads/plans/git-opcodes-plan.md`. On PASS, persist the approved plan to `.beads/plans/active-plan.md` (with the `<!-- user-approved: true -->` + `<!-- status: in-progress -->` headers per the orchestrated-execution skill) and **begin W1** (`lookupRepoByUrl` + shared `normalizeRepoUrl` + `CredAccountKey` codec fail-closed — the lowest-risk foundational unit).

Per the user directive: proceed through W1→W6 without stopping at user gates; the two checkpoints are self-reviewed adversarially (fresh security-auditor after W2; fresh code-review before PR). Continue until `make check` + frontend gate green and a registered `git@github.com:seal-harness/seal-harness.git` clones via `SETUP_REPO`. The 4-phase orchestrated-execution loop (IMPLEMENT → VALIDATE → fresh ADVERSARIAL REVIEW → COMMIT) per WU, with independent validation (never trust the coder's self-report).

If the plan gate finds blockers, fix them (in the plan or, if they trace to the design, in the design doc) and re-run before starting W1.

## 11. Remaining Work (after the next action)

1. Run the plan review gate (3 reviewers) on `.beads/plans/git-opcodes-plan.md`; persist the approved plan.
2. W1: URL normalization + `lookupRepoByUrl` + `CredAccountKey` codec fail-closed.
3. W2 (self-reviewed security checkpoint): no-disk clone seam + `SshAgentHandle` + opt-in `-A` + env-override seam + pinned known_hosts + `UntrustedIORemoteSpec` recording-fake ripple.
4. W3: `SETUP_REPO` revision + `Env` fields (`VaultHandle`/`RepoRegistryHandle`) + 5 `setupRepoOp` call sites + caller updates.
5. W4: `GIT_FETCH`/`GIT_PULL`/`GIT_PUSH` opcodes (Untrusted; `GIT_PUSH` audit via `runLocal`).
6. W5: deploy-key generation endpoints (`ssh-keygen -N "<vault-passphrase>"` encrypted keyfile) + frontend Generate flow + repo-remove keyfile cleanup.
7. W6 (self-reviewed before PR): `make check` + frontend gate + final review + self-reflect + PR.
8. Reference PR #80's W1–W6 execution (the `docs/learnings/2026-08-02-source-control-repo-registry-learnings.md` file) for the established patterns (TDD, the 4-phase loop, the `-Werror` construction-site enforcement, the `escapeSingle` lesson — though that machinery is being removed in W2).