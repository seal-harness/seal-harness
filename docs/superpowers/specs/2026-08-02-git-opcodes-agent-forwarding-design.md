# Git Opcodes + SSH Agent Forwarding (No Unencrypted Secret on Disk)

**Issue**: (to be filed — follow-up to #80)
**Branch**: `feat/git-opcodes-agent-forwarding`
**Date**: 2026-08-02
**Status**: Design — awaiting review gate

## 1. Problem

PR #80 shipped a source-control repo registry + a credential-injection clone
seam (`Seal.SourceControl.Clone`). That seam writes a 0700 `GIT_ASKPASS`
helper script and a 0600 deploy-key keyfile to `~/.seal/state/repos/` on the
**trusted** harness machine for the duration of a clone, then bracket-deletes
them. PR #80 also leaves `SETUP_REPO` cloning bare URLs in the Untrusted
sandbox with no credential support, so private repos still fail opaquely.

Two problems, one hard requirement:

1. **The hard requirement (binding):** Un-encrypted secrets MUST NEVER be
   written to disk — on either the untrusted execution machine or the trusted
   harness machine. PR #80's `GIT_ASKPASS`/keyfile-on-disk approach (even
   briefly, even 0700) violates this. The follow-up is not "extend the seam";
   it is "replace the seam's mechanism with one that never touches disk, then
   build the new ops on that same mechanism."

2. **The two-sided problem:** credentials must (a) be used on all the git
   ops that need them, (b) work the first time with no failures in the normal
   course of operation, (c) minimize the LLM tokens spent on credential
   reasoning — **and** (d) the credential must not be exfiltratable by a
   compromised `git`/`ssh` binary on the untrusted machine (the injection
   threat the user raised: an untrusted machine is the most
   injection-susceptible surface, and a replaced `git` binary can steal any
   credential that crosses to it).

The chosen mechanism is **SSH agent forwarding** for deploy keys (the
preferred credential kind), with a per-repo key auto-generated at repo-create
time for a streamlined UX. HTTPS PATs remain supported as a fallback for rare
cases but carry an inherent residual (token crosses to untrusted memory) and
are documented as the lesser path.

## 1a. Use Cases (WHO / WANTS / SO THAT / WHEN)

The primary personas are the **operator** (configures repos + credentials,
unlocks the vault) and the **agent** (calls the git opcodes; never sees
credentials). The `/repo` slash command and `ReposView` are operator tools;
the opcodes (`SETUP_REPO`/`GIT_FETCH`/`GIT_PULL`/`GIT_PUSH`) are the agent's
tools.

1. **Operator registers a private repo with an auto-generated deploy key** —
   *As* an operator, *I want* to register a private GitHub repo and have a
   fresh per-repo SSH key generated automatically, stored in the vault, and
   the public key + "add as a GitHub deploy key" instructions shown to me,
   *so that* I can enable private-repo cloning in one click without
   hand-generating an SSH keypair, *when* I add a repo in `ReposView` or via
   `/repo add --cred deploy_key --generate`.
2. **Agent clones a registered private repo** — *As* an agent, *I want* to
   call `SETUP_REPO` on a registered private repo and have it clone
   successfully on the first try with no credential reasoning,
   *so that* I can stand up a session workdir without retrying or
   hand-authenticating, *when* I'm asked to work on a private repo.
3. **Agent fetches/pulls/pushes a registered private repo** — *As* an agent,
   *I want* to call `GIT_FETCH`/`GIT_PULL`/`GIT_PUSH` and have them succeed
   first-try with the harness handling auth transparently via agent
   forwarding, *so that* I spend zero tokens on credential reasoning and
   never fail on auth in the normal course of operation, *when* I'm working
   in a registered private repo's workdir.
4. **Operator rotates a deploy key** — *As* an operator, *I want* to
   regenerate a repo's deploy key (new key in the vault, new public key to
   paste at GitHub), *so that* I can recover from a suspected compromise or
   a key that's no longer valid, *when* a key is rotated. Recovery path:
   `POST /api/repos/:id/deploy-key/generate` (regenerate) → re-display the
   public key + instructions.
5. **Operator hits a missing/locked vault key at git-op time** — *As* an
   operator, *I want* a clear, actionable error naming the missing vault key
   or "vault locked" when an agent's git op fails, *so that* I can unlock the
   vault or store/rotate the key rather than seeing a generic git-auth
   failure, *when* a git op is attempted before the credential is available.
   (Registry-miss is a separate, agent-facing error — use case 6.)
6. **Agent hits an unregistered repo** — *As* an agent, *I want* a clear
   error ("no credential registered for `<host>` (origin: `<url>`); use
   `SETUP_REPO` or `/repo add`") when I call `GIT_FETCH`/`PULL`/`PUSH` on a
   repo whose origin URL isn't in the registry, *so that* I (or the operator)
   can register it rather than failing opaquely or silently falling back to
   an unauthenticated remote that would leak whether the repo is public,
   *when* I attempt a remote op on an unregistered repo.
7. **Operator on the local untrusted executor** (degraded mode) — *As* an
   operator on the local untrusted executor (not the `remote-only-untrusted`
   hardened path), *I want* to know that the key-never-crosses separation is a
   remote-executor benefit and that the local path shares the harness
   `SSH_AUTH_SOCK` (same user, shared PID namespace), *so that* I can choose
   the hardened path when I need it, *when* I deploy the harness. Surfaced as
   a `ReposView`/`/repo` advisory when the local executor is active.

## 1b. User-Focused Success Criteria (in addition to the technical DoD in §9)

- **S1 (operator, register+clone)**: An operator can register a private
  GitHub repo + auto-generate a deploy key in **one** `ReposView` action, then
  the agent clones it via `SETUP_REPO` in **one** opcode call, first try, with
  **zero** credential-reasoning tokens spent by the model. Verified by an
  end-to-end test.
- **S2 (agent, push first-try)**: For a registered repo, `GIT_PUSH` completes
  in a **single** opcode call with **zero** credential-related follow-up
  turns, vs an unbounded retry loop on raw `SHELL_EXEC git`. Verified by a
  GitSpec test asserting one opcode call → success, no retry.
- **S3 (operator, key rotation)**: Rotating a deploy key (regenerate) and
  re-pasting the public key at GitHub requires **zero** registry edits to the
  repo entry (the vault key name is stable) and **zero** downtime for
  subsequent git ops. Verified by a test that regenerates + runs a fetch.
- **Evaluation timeline**: one month after release, if `GIT_PUSH` is never
  invoked on a registered repo, or if operators never auto-generate deploy
  keys and always supply their own, revisit whether the push opcode / the
  auto-generate flow are earning their scope.

## 2. Goals & Non-Goals

### Goals
1. **No un-encrypted secret on disk, either machine.** The vault remains the
   sole encrypted-at-rest store; in use, secret bytes live only in process
   memory (the harness ssh-agent / git argv). Enforced by a test that asserts
   no temp keyfiles/helper-scripts are written anywhere on either machine for
   any git operation.
2. **Deploy keys are the preferred credential kind**, one fresh key per repo,
   auto-generated at repo-create time in the frontend. The user is shown the
   public key + copy-paste instructions to add it as a GitHub deploy key.
3. **SSH agent forwarding** carries a repo's deploy key from the harness
   ssh-agent to the untrusted machine for git ops — the private key never
   crosses to the untrusted machine (only signing requests/answers tunnel over
   the SSH channel). A compromised `git`/`ssh` binary on the untrusted machine
   gets a per-session signing oracle, scoped to that one repo, not the key.
4. **Typed git opcodes** for the remote ops that need auth: revise
   `SETUP_REPO` and add `GIT_FETCH`, `GIT_PULL`, `GIT_PUSH`. The agent calls
   the opcode; the **harness resolves the credential in the trusted plane and
   executes git via BIN_EXEC** (no shell interpreter, no injection surface,
   no env-leak-through-shell-expansion). Local git ops (`add`/`commit`/`log`/
   `diff`/`branch`) stay on `SHELL_EXEC` — they need no credential.
5. **Works first time.** The model calls `GIT_PUSH`; the harness looks up the
   workdir's origin URL in the `RepoRegistry`, resolves the credential, runs
   `git` with the in-memory credential. No failed-then-retry, no credential
   awareness for the model.
6. **Minimal tokens.** The model never reasons about credentials, never
   retries on auth failure, never sees a secret. It calls a typed opcode and
   the harness handles auth transparently.

### Non-Goals
- Git operations other than clone/fetch/pull/push (e.g. `rebase`, `merge`,
  `cherry-pick`, `reset`) — these are local ops (no remote auth); they stay
  on `SHELL_EXEC`. The agent can run them directly in the sandbox.
- A git/GitHub MCP server. Considered and rejected for the
  credential-transparency goal (it duplicates the `SHELL_EXEC` git surface
  without removing it, and can *raise* token usage as the model learns a new
  tool surface). An MCP server is the right lever for *structured* GitHub ops
  (create PR, list reviews) — a separate, later design that can itself
  consume this same agent-forwarding machinery.
- HTTPS PAT parity with deploy keys. PATs are supported as a fallback but
  carry an inherent residual (token-in-untrusted-memory via `http.extraHeader`
  argv) that agent forwarding does not fix. The design documents this rather
  than pretends equivalence.
- Removing `SHELL_EXEC` git from the agent. Local git ops are unaffected; a
  question of whether to *restrict* raw `SHELL_EXEC git <remote-op>` for
  private-repo workdirs (so the agent can't bypass the opcodes) is
  **deferred** — see §5.6 (it's a policy question, not a credential mechanism
  question, and the opcodes work whether or not raw git is restricted).
- The local untrusted executor's trust residual. Agent forwarding's clean
  key-never-crosses separation is a property of the remote/SSH executor; the
  local executor degenerates to "same machine, shared PID namespace" (the
  existing local-sandbox trust boundary). The design calls this out but does
  not change the local executor.
- Migrating the W3 `Seal.SourceControl.Clone` seam's *public-repo* path
  (no credential) — that path writes nothing to disk and is unaffected. Only
  the *credential* paths (PAT/MachineUser/DeployKey) are revised to no-disk.

## 3. Existing Building Blocks (no re-invention)

| Concern | Existing module | Reuse |
|---|---|---|
| Encrypted vault, keyed by `Text` | `Seal.Security.Vault` (`vhGet`/`vhPut`) | credential *values* live here; deploy keys stored as base64 SSH private key bytes |
| Remote SSH executor | `Seal.Tools.Exec.Remote` (`sshExecArgv`, `RemoteRunner`) | the SSH channel the agent forwards over; `SshConfig` carries host/user/port/known-hosts |
| `SshConfig` (host/user/port/known-hosts/workspace) | `Seal.Tools.Exec.Types` | the validated SSH coordinates; `scWorkspace` anchors the workdir on the remote machine |
| Repo registry + lookup | `Seal.SourceControl.Registry` (`lookupRepo`, `upsertRepo`) | the registry the opcodes consult by URL |
| `SourceRepo`/`RepoCredential`/`VcsKind` | `Seal.SourceControl.Repo` | the types (W1); `CredDeployKey { cVaultKey }` already exists |
| The setup-repo combo box + UI history | `Seal.Gateway.API` `POST /api/sessions/:id/setup-repo`; `addRepoHistory` | the UX surface the new repo-create flow extends |
| BIN_EXEC (no-shell binary execution) | `Seal.Tools.Exec.Untrusted` (`uioBinExec`) / `Seal.Tools.Exec.Types` (`lehExecBin`) | the no-shell execution path for git (trusted plane for the new opcodes) |
| `SETUP_REPO` opcode | `Seal.ISA.Ops.Repo` (`setupRepoOp`, `cloneRepoIO`) | the opcode to revise to the no-disk seam + registry lookup |
| `age-keygen` for SSH key generation | (system) `ssh-keygen` | fresh per-repo deploy keys generated via `ssh-keygen -t ed25519 -f - -N ""` (key bytes to stdout, **no keyfile on disk**) |

## 4. Design

### 4.1 The no-disk credential mechanisms

Two mechanisms, both disk-free, one per credential family:

#### 4.1.1 SSH deploy keys (preferred) — harness ssh-agent + agent forwarding

**The key lifecycle (no disk anywhere):**
1. **Generation** (at repo-create time, frontend-initiated, on the harness):
   **In-process ed25519 keygen via `crypton`** (`Crypto.PubKey.Ed25519` —
   `generateSecretKey :: MonadRandom m => m SecretKey`, `toPublic :: SecretKey
   -> PublicKey`; `crypton` is already a cabal dep). The harness generates the
   keypair in memory, serializes both halves to the **OpenSSH key format**
   (the `ssh-add`/`ssh-agent`-compatible `-----BEGIN OPENSSH PRIVATE KEY-----`
   envelope + the `ssh-ed25519 AAAA...` public-key line) **in pure Haskell**
   (the openssh-key-v1 format is documented; a small serializer lands in
   `Seal.Tools.Ssh.Agent` or `Seal.SourceControl.GithubKeys`). The private key
   bytes go to the vault via `vhPut`; the public key returns to the frontend.
   **No `ssh-keygen` subprocess, no `-`/`-.pub` file on disk, fully portable.**
   (The earlier `ssh-keygen -f -` approach was rejected: on OpenSSH 9.x
   `-f -` writes the private key to a file literally named `-` on disk, not
   stdout — verified. The in-process path is the only truly no-disk option
   that produces OpenSSH-format keys `ssh-add` accepts.)
2. **Loading** (at git-op time, on the harness): the harness uses a
   **per-op ssh-agent** (see §4.6 for why per-op, not session-scoped): start
   `ssh-agent`, `ssh-add -` reads the private key bytes from `vhGet` via
   **stdin** (a pipe: `vhGet` → `BS.hPut stdin` → `ssh-add`). The key lives in
   the agent's memory; the vault's age-encrypted file is the only on-disk form
   (already encrypted-at-rest, satisfying the requirement). `SSH_AUTH_SOCK` +
   `SSH_AGENT_PID` captured. **Immediately after the git op, `ssh-add -D`
   (delete all identities) + kill the agent.** (See §4.6 — the per-op
   lifecycle is the security-critical scoping mechanism.)
3. **Use** (the git op, on the untrusted machine via the SSH executor):
   `ssh -A ... user@untrusted-host -- git ...` (the `-A` flag is **opt-in per
   git-op invocation**, NOT a blanket property of `sshExecArgv` — see §4.4).
   On the untrusted machine, `SSH_AUTH_SOCK` is set to a forwarded socket;
   when `git`/`ssh` (reaching github.com) needs to sign, the request tunnels
   back over the SSH channel to the harness agent, which signs with the
   in-memory key and returns the signature. **The private key never crosses
   to the untrusted machine** — not disk, not memory. After the git op
   returns, the harness deletes the identity + kills the agent, so the
   forwarded socket goes dead.

**Trust-boundary win:** a compromised `git`/`ssh` binary on the untrusted
machine, OR a co-resident malicious process on the untrusted machine (the
forwarded `SSH_AUTH_SOCK` is reachable by the untrusted user's processes),
gets a **signing oracle for the duration of ONE git op, scoped to that one
repo's deploy key** (the agent holds exactly one identity at forwarding
time — see §4.6). It can auth to that one GitHub repo for the seconds the
git op runs; when the op returns, the harness deletes the identity + kills
the agent, and the attacker has nothing. It cannot exfiltrate a persistent
credential (there is none), and it cannot auth to other repos/hosts (deploy
keys are repo-scoped AND only one identity is ever live). This is the core
security improvement, and the per-op + single-identity lifecycle is what
makes the scoping claim real.

#### 4.1.2 Host-key verification — pre-pinned GitHub host keys (not accept-new)

`StrictHostKeyChecking=accept-new` + `UserKnownHostsFile=/dev/null` is
**rejected** — it provides ZERO host-key verification on the
untrusted↔github.com channel (every connect is a "first connect" since
known_hosts is always empty), enabling a MITM to impersonate github.com for
the deploy-key signing session. This was a CRITICAL finding from the
security-design review.

**The fix: pre-pin GitHub's published host keys.** GitHub publishes its SSH
host keys (RSA/ECDSA/Ed25519 — public data, not secret; confirmed at
https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints).
The harness ships a read-only `known_hosts` file (embedded via
`file-embed` at compile time, or written once under `~/.seal/state/repos/`
at first use) containing:

```
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
```

`GIT_SSH_COMMAND` uses `-o StrictHostKeyChecking=yes -o
UserKnownHostsFile=<pinned-file>` — hard verification, never bypassed. A
host-key mismatch is a hard failure (`CloneGitFailed`), same as the
harness↔untrusted channel in `Seal.Tools.Exec.Remote`. **No `accept-new`,
no `/dev/null`.** The pinned file is public data, so the no-encrypted-secret
-on-disk rule is unaffected. For non-GitHub hosts (the `vcs_kind=git` case),
no pre-pinned keys exist → the op fails with "host-key pinning unavailable
for `<host>` (only github.com is supported in this pass)" rather than
falling back to `accept-new`. (Future: per-host pinning via operator config.)

#### 4.1.3 HTTPS PAT / machine-user (fallback) — `http.extraHeader` in argv

PATs fundamentally must be presented at every HTTPS request, so the token has
to be where git runs (the untrusted machine). The no-disk mechanism: pass
`git -c http.extraHeader='Authorization: Basic <base64(user:token)>'` as the
git argv (via BIN_EXEC — no shell). The token lives in the git process's
**argv** (kernel-owned memory), never a file. Residual: argv is visible to
co-resident processes via `/proc/<pid>/cmdline` (memory, not disk — satisfies
the no-disk rule, but the token *does* cross to untrusted memory and a
compromised `git` binary can log it from argv; additionally, argv can
transiently reach disk via swap/process-accounting/core-dumps — a narrow
edge the design documents). **Documented as the lesser path; deploy keys
preferred.** Machine-user uses the same path with `base64(cUsername:token)`.

**Note:** the W3 `GIT_ASKPASS`-helper-script-on-disk approach is **removed**
for both PAT and DeployKey. The `resolveCloneTarget` seam is replaced by the
no-disk seam in §4.4.

### 4.2 Trust level of the new opcodes

`SHELL_EXEC` is Untrusted (sandbox, interacts with the outside world). The
new git opcodes **execute git on the untrusted machine** (the workdir lives
there), so they must carry an `UntrustedIO` to reach it. By the ISA's
capability-scoping rule (`Seal.ISA.Opcode`: a `TrustedOpcode` has NO
`UntrustedIO` in scope — `toRun :: BackendExec -> Value -> App OpResult`
where `BackendExec` only offers `runLocal :: IO a -> App a`), an opcode that
runs git remotely **must be `UntrustedOpcode`** — there is no other way to
obtain the `UntrustedIO` the SSH executor / sandbox needs. So:

- **`SETUP_REPO`** (revised): stays **Untrusted** (as today). The credential
  resolution (vault read + ssh-agent lifecycle) happens via
  `BackendExec.runLocal` (the Trusted-IO seam available to `UntrustedOpcode`
  too — `uoRun` runs in `App`, which can `liftIO`) BEFORE the clone command is
  handed to `uioShellExecEnv`/`uioBinExecEnv`. The sandboxed `git clone` runs
  with the auth available (forwarded `SSH_AUTH_SOCK` + `GIT_SSH_COMMAND` env
  for deploy keys; `http.extraHeader` argv for PATs) but never reads the
  key/token itself.
- **`GIT_FETCH` / `GIT_PULL` / `GIT_PUSH`** (new): **Untrusted** (they execute
  git on the untrusted machine via `UntrustedIO`). Credential resolution in
  the trusted plane via `runLocal` (same as SETUP_REPO). **`GIT_PUSH` is
  Audited**: the `UntrustedOpcode` record has no `toTrust` field, BUT the
  dispatcher can be extended to recognize an Audited Untrusted opcode (record
  the audit entry via `runLocal` before/after the untrusted git run). The
  cleanest path: the `GIT_PUSH` `uoRun` writes the audit entry itself via
  `runLocal` (liftIO to the cross-session append-only log) before running the
  untrusted `git push` — the audit happens in the trusted plane, the git in
  the untrusted plane, within one opcode. (The design-gate CTO should confirm
  whether this per-opcode audit-write is acceptable vs a dispatcher-level
  `UntrustedAudited` variant; the recommendation is the per-opcode write —
  smaller blast radius than a new Opcode constructor.)

This is a genuine trust-model shift from "the agent runs git in the sandbox
without auth" to "the harness resolves the credential in the trusted plane +
injects auth into a sandboxed git run." The sandbox still runs git; the
sandbox never sees the credential (only the forwarded socket / argv). The
audit entry for `GIT_PUSH` records the push happened + the credential kind,
secret-free.

**The git opcodes need `VaultHandle` + `RepoRegistryHandle` at call time.**
These are NOT currently on `Env` (`Seal.Types.Env` carries only logger +
config). They ARE constructed in `Serve.hs` (the `VaultHandle` at line ~118;
the `RepoRegistryHandle` built in W4 of PR #80) and threaded into `ApiDeps` +
the channels. **W3 adds `VaultHandle` + `RepoRegistryHandle` to `Env`** (the
`setupRepoOp`/`gitFetchOp`/etc. constructors take them as params, closed over
at the wiring sites; `Env` is the clean way to make them available to `App`).
`Env` is built in exactly one place (`mkEnv` in `Seal.Types.Env`), so the
construction-site blast radius is small + contained. The `setupRepoOp`
signature gains a `CloneDeps`-equivalent param (the 5 call sites —
`Channels/Loop.hs:946,1112`; `Gateway/Send.hs:534,894`;
`Channel/Cli.hs:426,505` — are updated in W3).

### 4.3 The opcodes

#### `SETUP_REPO` (revised — `Seal.ISA.Ops.Repo.setupRepoOp`)
Input: `{url: Text}` (unchanged). Behavior:
1. **Registry lookup**: normalize the URL (reuse `Seal.ISA.Ops.Repo.normalizeRepoUrl`
   — see §4.5) and consult the `RepoRegistry`. If found → credential path. If
   not found → the existing bare-URL clone (public repos, backward-compatible —
   no auth injection).
2. **Credential path (deploy key)**: resolve via the per-op harness ssh-agent
   (§4.1.1, §4.6). The clone runs in the sandbox with
   `GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=yes -o
   UserKnownHostsFile=<pinned-github-keys> -o IdentitiesOnly=yes -o
   BatchMode=yes"` and the forwarded `SSH_AUTH_SOCK` env (threaded via the
   W2 env-override seam on `UntrustedIO`). **No keyfile anywhere.** The agent
   is killed (identity deleted) the instant the clone returns.
3. **Credential path (PAT / machine-user)**: rewrite the URL to HTTPS
   (token-free), clone via BIN_EXEC with `http.extraHeader` in argv (§4.1.3).
4. `orRecorded`: the url + target path + status (secret-free, as today).

`SETUP_REPO` stays **Untrusted** for the clone itself (filesystem-mutating in
the workdir); the credential resolution + agent lifecycle happen in the
trusted plane before the clone command is handed to the sandbox. The sandbox
inherits `SSH_AUTH_SOCK` but never reads the key.

#### `GIT_FETCH` / `GIT_PULL` (new — `Seal.ISA.Ops.Git`)
Input: `{workdir: Text, remote?: Text (default "origin"), ref?: Text}`. Behavior:
1. Resolve the workdir's origin URL: the harness reads it via the SSH executor
   (`git -C <workdir> config --get remote.origin.url`) — the **single, no-
   trust-the-sandbox path** (the architect's "don't leave an `or`" concern).
   (Local executor: same, via the local sandbox.)
2. `lookupRepoByUrl` → registry hit → resolve credential (§4.1) → run
   `git -C <workdir> fetch [--refspec]` (or `pull`) via the SSH executor with
   `-A` (deploy key) or `http.extraHeader` argv (PAT). Registry miss → the op
   fails with "no credential registered for `<host>` (origin: `<url>`); use
   SETUP_REPO or `/repo add" (the model can't silently fall back to an
   unauthenticated fetch that would leak whether the repo is public).
3. `orRecorded`: workdir + remote + ref + outcome.

#### `GIT_PUSH` (new — Audited)
Input: `{workdir: Text, remote?: Text, refspec: Text}`. Same credential path
as FETCH/PULL. The audit entry is secret-free and records, literally:
```json
{"workdir":"<path>","remote":"origin","url":"git@github.com:owner/repo.git","refspec":"refs/heads/main","outcome":"pushed 3 commits","credential_kind":"deploy_key"}
```
(The `credential_kind` is included for forensics — it's not secret; the audit
entry never includes the `GIT_SSH_COMMAND` value, the `http.extraHeader`
value, or any token/key. The `url` is host-bound + allow-listed.) The audit
write happens in the trusted plane (`App`) via the existing cross-session
append-only log (the same sink `CONFIG_UPDATE`/`SECRET_SAVE` use); the
Audited dispatcher records-then-runs per `Seal.ISA.Opcode`.

### 4.4 The no-disk clone/credential seam (replaces W3 `Seal.SourceControl.Clone`)

`Seal.SourceControl.Clone` is revised:
- **`resolveCloneTarget`** no longer writes a `GIT_ASKPASS` helper script or a
  keyfile. It returns a `CloneEnv` carrying:
  - **DeployKey**: `ceEnvExtras = [("SSH_AUTH_SOCK", <forwarded-socket>),
    ("GIT_SSH_COMMAND", "ssh -o StrictHostKeyChecking=yes -o
    UserKnownHostsFile=<pinned-github-keys> -o IdentitiesOnly=yes -o
    BatchMode=yes")]`. No keyfile. (The `BatchMode=yes` prevents an
    interactive prompt hang if the forwarded agent fails to auth — mirrors
    the harness↔untrusted channel in `Remote.hs`.)
  - **PAT/MachineUser**: `ceGitConfigArgs = ["-c",
    "http.extraHeader=Authorization: Basic <base64>"]`, `ceUrl` = token-free
    HTTPS URL. No helper script.
- **`withCloneTarget`** CPS bracket: the bracket kills the **per-op**
  ssh-agent (start → `ssh-add -` → run → `ssh-add -D` → kill) for deploy keys.
  There is no persistent file to clean up; the bracket only manages the
  agent process. (See §4.6 — per-op, not session-scoped.)
- The `escapeSingle` shell-escaping machinery is **removed** (no helper
  script generation → no shell-escaping surface). The §5.2 command-injection
  class is eliminated by construction.
- `cloneRepo` / `lsRemoteRepo` signatures gain a `CloneDeps` record to keep
  arity stable (the CTO's concern): `CloneDeps = CloneDeps { cdVault ::
  VaultHandle, cdSshAgent :: SshAgentHandle, cdPinnedKnownHosts :: FilePath }`.
  A `SshAgentHandle` seam (record of IO actions: `agentStart`, `agentAddKey`,
  `agentDeleteAll`, `agentKill`, `getAuthEnv`) is defined so W5 GitSpec can
  inject a **fake agent** (records the calls, no real process) — unit-test
  speed, no flaky `ssh-agent` spawning. Production wires a real-agent
  implementation; tests wire the fake. The existing `cloneRepoIO` callers
  (`Seal.ISA.Ops.Repo` for `SETUP_REPO`, `Seal.Gateway.API` for the setup-repo
  combo box, `Seal.Command.Repo` for `/repo test`) are all updated to build a
  `CloneDeps` from the session/Env (W4 enumerates these).

**Execution locus (clarification, per the security reviewer's question).**
Git always runs **on the untrusted machine** in the workdir (the workdir
lives there; the sandbox owns the filesystem). The harness does NOT run git
locally and sync. For deploy keys, the harness reaches the untrusted machine
via the SSH executor (`ssh -A user@untrusted -- git -C <workdir> ...`) with
the forwarded `SSH_AUTH_SOCK` — git on the untrusted machine signs via the
forwarded socket back to the harness agent. For PATs, the harness runs `ssh
user@untrusted -- git -C <workdir> -c http.extraHeader=... <url>` (no `-A` —
PAT auth is in git's argv, no agent needed). In both cases the git process
runs on the untrusted machine; the credential is injected from the trusted
plane (agent forwarding for deploy keys, argv for PATs). The pinned
`known_hosts` resolves **on the untrusted machine** (it's in
`GIT_SSH_COMMAND`, which git on the untrusted machine uses to reach
github.com) — so it must be reachable from the sandbox. **Decision: ship the
pinned keys embedded in `GIT_SSH_COMMAND` itself** (ssh's `-o
UserKnownHostsFile=<path>` accepts a path; for the untrusted machine the
path is under the sandbox workdir or `/tmp`, written once at session start
by the harness via the SSH executor's stdin-pipe file-write — OR, cleaner,
embed the keys via ssh's `@cert-authority`/`HostKeyAlias` + a here-doc; the
implementation W2 must pick one and the no-disk test confirms no secret
lands there since the pinned file is public data). The setup-repo combo box
(`/api/sessions/:id/setup-repo`) and `/repo test` use the same path.

**`-A` is opt-in per git-op invocation, NOT a blanket `sshExecArgv`
property.** `Seal.Tools.Exec.Remote.sshExecArgv` gains a `ForwardAgent` flag
(or a new `sshExecArgvForwarding` variant) so only the git opcodes pass `-A`;
`SHELL_EXEC`, `UntrustedIO` file-writes, and command opcodes do NOT. The
invariant test (`RemoteSpec`) asserts: non-credentialed remote ops' argv
contains no `-A`; git-credential ops' argv contains `-A`. This prevents the
"every remote op forwards the agent" regression the security reviewer flagged.

**UntrustedIO env-override prerequisite.** The current `uioShellExec` /
`uioBinExec` (`Seal.Tools.Exec.UntrustedIO`/`Untrusted`) do not thread
env-override extras to the sandboxed process. `SETUP_REPO`/`GIT_*`'s sandboxed
git must inherit `SSH_AUTH_SOCK` + `GIT_SSH_COMMAND` env. **W2 adds an
env-override seam to `UntrustedIO`** (`uioShellExecEnv :: [(String,String)] ->
ShellCommand -> Maybe RemotePath -> IO (...)` / `uioBinExecEnv`); existing
callers pass `[]` (no behavior change).
- **Local arm**: the extras are merged over `getEnvironment` on the
  `CreateProcess.env` field (the child inherits PATH/HOME + the extras).
- **Remote arm**: `ssh -A` forwards the AGENT SOCKET but does NOT forward
  arbitrary env to the remote shell (and `SendEnv`/`SetEnv` require the
  server's `sshd_config` `AcceptEnv`, which is `none` by default). The
  portable mechanism is an **`env VAR=val ...` prefix in the command string**
  the SSH executor sends: the remote `uioShellExecEnv`/`uioBinExecEnv`
  prepend `env SSH_AUTH_SOCK=$SSH_AUTH_SOCK GIT_SSH_COMMAND='...' git ...` to
  the command (the forwarded `SSH_AUTH_SOCK` from `-A` is referenced via
  `$SSH_AUTH_SOCK` in the remote shell; `GIT_SSH_COMMAND` is set inline). No
  `AcceptEnv` dependency. The recording fake captures the prefixed command
  string (assertable).

### 4.5 URL normalization + registry lookup

`lookupRepoByUrl :: Text -> RepoRegistry -> Maybe SourceRepo`:
- Normalize the query URL via the **existing** `Seal.ISA.Ops.Repo.normalizeRepoUrl`
  (the architect's "don't reimplement" concern — it already strips scheme,
  user@, SCP colon→slash, trailing `.git`, trailing slashes, and case-folds
  the host). **Move/share `normalizeRepoUrl` to `Seal.SourceControl.Repo`**
  (re-export from `Seal.ISA.Ops.Repo` to avoid the import cycle) so both the
  opcode path and the registry-lookup path use the SAME normalizer and can't
  diverge. `lookupRepoByUrl` calls it on both the query URL and `srUrl`.
- Returns the `SourceRepo` (with its credential) or `Nothing`.

This is needed because `SETUP_REPO`/`GIT_FETCH` receive a URL (from the model
or the workdir's `.git/config`) that may not string-match the registered
`srUrl`. Pure, QuickCheck-testable.

### 4.6 The ssh-agent lifecycle — PER-OP (not session-scoped)

**This is the security-critical decision the security-design review forced.**
The original draft proposed a session-scoped agent (lazy start, reuse across
ops, kill at session end). That breaks the per-repo oracle-scoping claim: a
session touching repo A then repo B leaves both keys loaded, so the forwarded
`SSH_AUTH_SOCK` on the untrusted machine exposes a signing oracle for BOTH
repos for the remainder of the session (and a co-resident malicious process
on the untrusted machine, which can reach the forwarded socket, can sign as
either). The "scoped to that one repo's deploy key" property — the design's
headline security claim — only holds if the agent holds **exactly one
identity at forwarding time**.

**The fix: a per-op agent lifecycle.** Each git op that needs a deploy key:
1. Start a fresh `ssh-agent` (child process).
2. `ssh-add -` loads the ONE repo's key from `vhGet` (stdin pipe).
3. Run the git op with `-A` forwarding (the agent holds exactly one identity).
4. `ssh-add -D` (delete all identities) + kill the agent the instant the op
   returns (bracket cleanup — `finally`).

The forwarded `SSH_AUTH_SOCK` is live for the duration of ONE git command
(seconds), holding ONE repo's key. After the op, the socket is dead. A
compromised binary / co-resident process gets a per-op, per-repo signing
oracle — the minimum practical exposure. This is more process spawning than
a session-scoped agent, but the security gate's verdict is that the scoping
property is non-negotiable, and the overhead is bounded (git ops are not
high-frequency). `ssh-agent -t <lifetime>` (key auto-expiry) is set as
defense-in-depth in case the harness's kill hook is skipped (crash/OOM/signal).

**The `SshAgentHandle` seam (for testability + the construction-site
question).** `SshAgentHandle` is a record of IO actions (mirrors
`RemoteRunner` / `VaultHandle`):
```haskell
data SshAgentHandle = SshAgentHandle
  { sahStart      :: IO (Maybe SshAgentEnv)   -- start agent → Just (authSock, agentPid) or Nothing on failure
  , sahAddKey     :: SshAgentEnv -> ByteString -> IO (Either Text ())  -- ssh-add - (stdin pipe)
  , sahDeleteAll  :: SshAgentEnv -> IO ()     -- ssh-add -D
  , sahKill       :: SshAgentEnv -> IO ()      -- kill the agent
  }
```
Production wires a real-agent implementation (`mkRealSshAgentHandle`);
**tests wire a fake** (`mkFakeSshAgentHandle`) that records
start/add/delete/kill calls — unit-test speed, no real `ssh-agent` spawning,
no flaky `make check`. This resolves the CTO's mockability blocker.

**Construction-site decision (zero blast radius).** The agent handle is
NOT a field on `Env` or `SessionRuntime` (avoiding PR #80's ApiDeps
construction-site blast radius). Instead, the per-op lifecycle is owned by
the credential seam (`Seal.SourceControl.Clone` + the new
`Seal.ISA.Ops.Git`): each git op builds a `CloneDeps` (carrying the
`SshAgentHandle` + `VaultHandle` + pinned-known-hosts path) at call time
from the `App Env` (the opcodes run in `App`, which already carries
`VaultHandle` via `AppEnv` — verify + extend `AppEnv` if needed; see
§4.4 on the wiring). No `Env`/`SessionRuntime` field addition → no
construction-site updates. The `SshAgentHandle` is a value passed per-op,
not a long-lived field. (If `AppEnv` needs `VaultHandle`/`RepoRegistryHandle`
added, that's a separate, smaller construction-site question — enumerate in
W4; `AppEnv`/`Env` construction is centralized in `mkEnv` per
`Seal.Types.Env.hs`, so the blast radius is small and contained.)

**Concurrency.** Per-op agents are independent (each op starts its own
agent) — no shared mutable state, no race. Two simultaneous `GIT_FETCH`
calls each start their own agent + load their own key; no MVar/IORef needed.
(This is another advantage of per-op over session-scoped, which would have
raced on the lazy-start.)

**`/repo test`** (out-of-session slash command) uses the same per-op
lifecycle — it builds a `CloneDeps` from the registry handle + vault the
command closes over (mirrors the W5 `RepoTestSeam` pattern from PR #80).

### 4.7 Frontend: auto-generate deploy key at repo-create

`ReposView` "New" flow (and the `/repo add` slash command, for parity):
- When the user selects `credential.kind = deploy_key`, the form
  **defaults to "Generate"** (the preferred path of least resistance — a
  subtle visual nudge toward the recommended flow without lecturing) and
  offers a "Generate" button prominently. The `vault_key` field is
  auto-filled with `seal-deploy-key:<repo-id>` and **disabled** (the backend
  is the source of truth for the vault key name on the generate path; the
  disabled field's value is submitted because the form is React-controlled
  state sent via JSON, not a native HTML form — a one-line note in the
  implementation).
- The create flow is split into two endpoints (the designer's blocker — a
  union-type `RepoInfo & {...}` would silently drop fields in the typed
  `createRepo` client):
  1. `POST /api/repos` with `generate_key: true` → creates the `SourceRepo`
     (with `CredDeployKey { cVaultKey = "seal-deploy-key:" <> repoId }`),
     generates the key, stores the private key in the vault, returns **201 +
     the `RepoInfo` descriptor** (no extra fields — the create response stays
     stable + typed).
  2. `GET /api/repos/:id/deploy-key` → returns `{ public_key: Text,
     setup_instructions: Text }` (the public key + host-aware instructions).
     The frontend calls this immediately after the 201 to display the key +
     instructions. Also used for later retrieval (rotation, lost-key
     re-display) — the public key is not secret.
- **Host-aware `setup_instructions`** (the designer's blocker): derive per
  known host:
  - `github.com` → `"Add this as a deploy key with read (and write, if you
    intend GIT_PUSH) permissions at https://github.com/<owner>/<repo>/settings/keys/new"`.
  - `gitlab.com` / `bitbucket.org` / `gitea` → per-host templates (ship
    github only in the first pass; add per-host templates later).
  - **Fallback for unknown/generic hosts** → `"Add this as a deploy key on
    your git host for the repository at <url>."` (the design supports
    `vcs_kind: git` with arbitrary SSH hosts; the instructions must not lie
    for those).
- **Rotation** (use case 4): `POST /api/repos/:id/deploy-key/generate`
  regenerates the key (new private key in the vault under the SAME
  `cVaultKey` name — the registry entry is unchanged, satisfying S3), returns
  the new public key. The operator re-pastes at GitHub.
- `ReposView` renders the public key in a `<pre>` block with a "Copy" button
  + the instructions. The private key is **never** rendered (no field for
  it); `GET /api/repos` / `GET /api/repos/:id` return only the descriptor
  (key NAME, never the private key — it's in the vault). A faint hint next
  to the `pat`/`machine_user` credential dropdown option ("Token is
  presented to the untrusted machine; deploy keys are preferred.") surfaces
  the PAT residual in the web UX (matches the CLI help).

### 4.8 Account-wide SSH key (rare, non-repo GitHub automation)

The user noted this infrastructure also supports a regular SSH key with
permissions for a whole GitHub account, for rare non-repo GitHub ops. The
design accommodates this with a new constructor `CredAccountKey { cVaultKey,
cHost }` — explicit, host-scoped, doesn't overload the URL field (a sentinel
URL `git@github.com:*` would break `validateRepoUrl`/`normalizeRepoUrl` and
every URL-based lookup). **Out of scope for the first implementation pass**
(only per-repo deploy keys + PAT fallback ship), BUT the codec is extended
now (not reserved) to **fail-closed** on an `account_key` kind: a stale TOML
with `credential_kind = "account_key"` decodes to a parse error (not a
crash), so a future PR can add the constructor + codec arm without a
breaking change. When the constructor lands, it requires updating in lock-
step: `RepoCredential` (the constructor), `repoCredentialKindText`,
`parseCredentialKind`, `credentialCodec`, `credentialToObject`,
`parseCredentialFromObject`, `credentialKindLabel` (5 sites in `Repo.hs`/
`Command/Repo.hs` — called out so the implementer doesn't miss one). An
account-wide key, if loaded into the per-op agent, MUST be the only identity
live (the per-op lifecycle guarantees this — §4.6); its broader blast
radius (a compromised binary gets an oracle scoped to the whole account) is
why per-repo deploy keys are the default and account keys are an explicit
opt-in.

## 5. Security Considerations

### 5.1 No un-encrypted secret on disk (the binding requirement)
- **Vault**: the only on-disk form of any credential; age-encrypted at rest
  (existing vault guarantees). Satisfies the requirement by construction.
- **Deploy key generation**: `ssh-keygen -f -` writes the private key to
  stdout (captured → `vhPut` → vault); the public key goes to `-.pub` in cwd,
  which is read then **immediately deleted** (bracket-`finally`). The no-disk
  test asserts `-.pub` does not exist after generation. No persistent keyfile.
- **Deploy key in use**: harness ssh-agent memory, loaded via `ssh-add -`
  (stdin pipe from `vhGet`). Never a keyfile on disk.
- **PAT in use**: git argv (memory). Never a helper script or env file on
  disk. **Edge**: argv can transiently reach disk via swap / process
  accounting / core dumps — a narrow edge the design documents (no secret
  FILE is written, but "no secret bytes ever paged out" is not 100%
  guaranteeable for argv). Deploy keys (agent memory, no argv) avoid this edge.
- **Pinned known_hosts**: GitHub's published host keys are public data (not
  secret) — embedding them is unaffected by the no-secret-on-disk rule.
- **Verification**: a test that runs `cloneRepo`/`lsRemoteRepo`/`SETUP_REPO`/
  `GIT_FETCH`/`GIT_PUSH` and asserts no new files appear under
  `repoCloneStateDir` or anywhere in `~/.seal/` except the vault's encrypted
  file (+ the public pinned-known_hosts, which carries no secret). The W3
  `writePrivateTempFile`/`escapeSingle` calls are removed; the test asserts
  no keyfile/helper-script is written on either machine.

### 5.2 The compromised-binary / co-resident-process threat on the untrusted machine (the user's core concern)
- **Deploy key + agent forwarding (per-op lifecycle)**: a compromised
  `git`/`ssh` binary on the untrusted machine, OR a co-resident malicious
  process (the forwarded `SSH_AUTH_SOCK` is reachable by the untrusted user's
  processes — `ssh-agent` does not authenticate requesters), gets a **signing
  oracle for the duration of ONE git op, scoped to that one repo's deploy
  key** (the per-op agent holds exactly one identity at forwarding time —
  §4.6). It can auth to that one GitHub repo for the seconds the git op runs;
  when the op returns, the harness `ssh-add -D` + kills the agent, and the
  attacker has nothing. It cannot exfiltrate a persistent credential (none
  exists), and it cannot auth to other repos/hosts (deploy keys are
  repo-scoped + only one identity is ever live). This is the core security
  improvement, and the per-op + single-identity lifecycle is what makes the
  scoping claim real (the session-scoped design was rejected by the security
  review precisely because it broke this scoping).
- **PAT + `http.extraHeader` argv**: a compromised `git` binary can read the
  token from argv and exfiltrate it. The token is a persistent credential
  (valid until revoked). This is the inherent, unavoidable residual of HTTPS
  credentials. **Mitigation: prefer deploy keys; document the PAT residual
  (in `/repo add --cred pat` help + a `ReposView` advisory); recommend
  short-lived, narrowly-scoped PATs if PATs are used.** The design does not
  pretend PATs are equivalent to deploy keys.
- **Account-wide SSH key** (§4.8): a compromised binary gets an oracle scoped
  to the *whole account* — broad. Hence per-repo deploy keys are the default;
  account keys are an explicit, rare opt-in. The per-op lifecycle ensures an
  account key is the only identity live when used.

### 5.3 Agent forwarding — opt-in `-A`, host-key pinning, execution locus
- **`-A` is opt-in per git-op invocation** (not a blanket `sshExecArgv`
  property): only the git opcodes pass `-A`; `SHELL_EXEC`, `UntrustedIO`
  file-writes, command opcodes do NOT. The invariant test (`RemoteSpec`)
  asserts non-credentialed remote ops' argv contains no `-A`. This prevents
  the "every remote op forwards the agent" regression that would widen the
  oracle surface from "git ops only" to "any remote op while a key is loaded."
- **Host-key verification (harness↔untrusted)**: the remote SSH executor
  already pins host keys (`StrictHostKeyChecking=yes`, pinned
  `UserKnownHostsFile`, `BatchMode=yes`). Adding opt-in `-A` does NOT weaken
  this (it forwards the auth socket, not the host-key policy). The
  harness↔untrusted channel's host-key pinning is unchanged.
- **Host-key verification (untrusted↔github)**: pre-pinned GitHub host keys
  (`StrictHostKeyChecking=yes` + the public pinned `UserKnownHostsFile`) —
  hard verification, never bypassed. NO `accept-new`, NO `/dev/null`. A MITM
  on the untrusted↔github channel is detected (hard failure). The pinned
  file is public data.
- **Local executor degeneration**: for the local untrusted executor, "the
  untrusted machine" is the same machine; "forwarding" degenerates to "the
  sandbox shares the harness's `SSH_AUTH_SOCK`" (same user, shared PID
  namespace). Still no-disk, but the clean key-never-crosses separation is a
  remote-executor property. **Surfaced as a `ReposView`/`/repo` advisory when
  the local executor is active** (use case 7). The `remote-only-untrusted`
  Cabal flag (the hardened path) gets the full benefit; the per-op lifecycle
  still applies (the local sandbox gets the socket for one op's duration, one
  identity).

### 5.4 Host allow-list + host-binding (carried from PR #80's design)
- `github.com` allow-list enforced at registry-write time (`/api/repos`
  validation) and at clone/credential-injection time (`planClone` →
  `CloneHostNotSupported`). A registry entry can't point a credential at an
  attacker host. (For account-wide keys, the `cHost` field binds the key to a
  host; the clone-time assertion checks `host == cHost`.)

### 5.5 No secret in logs/transcript/API response (carried from PR #80)
- `CloneTarget` opaque + redacted `Show`; `withCloneTarget` CPS; the opcodes'
  `orRecorded` payloads are secret-free (url, workdir, ref, outcome — never
  token/key). The audit log entry for `GIT_PUSH` (§4.3) records the push
  happened + the credential KIND (for forensics, not secret), never the
  `GIT_SSH_COMMAND`/`http.extraHeader` value. No `ToJSON` on any secret
  carrier. `GET /api/repos/:id/deploy-key` returns the PUBLIC key only;
  `GET /api/repos`/`:id` return only the descriptor (key NAME).
- `CloneGitFailed` carries exit code only (no stderr) — carried from W3.

### 5.6 Should raw `SHELL_EXEC git <remote-op>` be restricted for private-repo workdirs?
- **Recommendation: do NOT restrict in this pass.** The opcodes are the
  recommended path; raw `SHELL_EXEC git` for remote ops on a private repo
  simply fails (no credential available in the sandbox — the agent has no
  `SSH_AUTH_SOCK` for non-credentialed remote exec since `-A` is opt-in, and
  no token) — which is the correct fail-closed behavior. Restriction is a
  policy refinement for a later design (intersects the autonomy policy +
  `remote-only-untrusted` flag). **Add a telemetry/log line** when raw
  `SHELL_EXEC git <remote-op>` is attempted on a registered private repo so
  the bypass attempt is observable even though it fails. The design-gate
  should confirm.

### 5.7 Deploy-key public-key storage (forensics + retrieval)
- The PUBLIC key is retrievable via `GET /api/repos/:id/deploy-key` for
  re-display. **Decision: store the public key as a public field on
  `SourceRepo`** (e.g. `srDeployKeyPublic :: Maybe Text` — `Nothing` for
  non-deploy-key repos), NOT in the vault alongside the private key. This
  decouples public retrieval from a private vault read (the security
  reviewer's concern: coupling would risk surfacing the private key). The
  public key is not secret; storing it in the (public-readable-via-API)
  registry is correct. The private key stays vault-only.

## 6. Testing Plan (TDD, `make check` gate)

**Mock infrastructure.** `RemoteRunner` is already a record of IO actions
(`mkFakeRemoteRunnerRecording` records argv + stdin). `VaultHandle` is too
(`FakeVault`). The new `SshAgentHandle` is **also a record of IO actions**
(`mkFakeSshAgentHandle` records start/add/delete/kill, no real process) —
unit-test speed, no flaky `ssh-agent` spawning. `CloneDeps` carries these;
tests inject fakes. The recording fake's argv capture is extended to also
capture **env** (so the `SSH_AUTH_SOCK` forwarding + `GIT_SSH_COMMAND` are
assertable — verify the recording fake captures env, or extend it in W2).

### Security-invariant tests (executable, not just claimed)
- **No-disk**: snapshot `~/.seal/` + the untrusted workdir before, run a
  clone + a fetch + a push, snapshot after, assert the only new file is the
  vault's encrypted file (for a newly-stored key) + the public pinned
  `known_hosts` — no plaintext key, no helper script, no keyfile, no
  `-.pub`. (On the untrusted machine: assert the SSH executor's recorded argv
  carries no keyfile path, only `SSH_AUTH_SOCK`.)
- **No-private-key-in-API**: `GET /api/repos`, `GET /api/repos/:id`,
  `GET /api/repos/:id/deploy-key` — assert no field matches a planted
  private key; the public key IS returned by `/deploy-key`.
- **Per-op scoping**: in a multi-repo sequence (repo A then repo B), assert
  via the fake `SshAgentHandle` that exactly one `agentAddKey` is followed by
  one `agentDeleteAll` + `agentKill` per op — never two keys live at once.
- **Opt-in `-A`**: `RemoteSpec` asserts non-credentialed remote ops' argv
  contains no `-A`; git-credential ops' argv contains `-A`.

### Per-spec tests
- `Seal.SourceControl.CloneSpec` (revised) — no-disk assertion (above); the
  deploy-key path uses `SSH_AUTH_SOCK` env (no keyfile path in env); the PAT
  path uses `http.extraHeader` argv (no `GIT_ASKPASS`). The W3 `escapeSingle`
  + helper-script tests are **removed**.
- `Seal.SourceControl.RegistrySpec` — `lookupRepoByUrl` (reuses
  `normalizeRepoUrl`; SSH↔HTTPS, trailing `.git`, host case-fold); QuickCheck.
- `Seal.ISA.Ops.RepoSpec` (revised) — `SETUP_REPO` with a registered
  private repo (deploy key) clones successfully via the forwarded agent
  (fake SSH executor + fake SshAgentHandle); with a PAT clones via
  `http.extraHeader` argv; with an unregistered URL falls through to the
  bare-URL clone (backward-compat); the `-.pub` is deleted after generation.
- `Seal.ISA.Ops.GitSpec` (new) — `GIT_FETCH`/`GIT_PULL`/`GIT_PUSH` happy path
  (registered repo, credential resolved via the fake agent, git runs via the
  fake SSH executor); registry miss → clear error naming the origin URL;
  vault-locked → distinguishable error; `GIT_PUSH` audit entry recorded
  (secret-free, carries credential_kind); per-op scoping asserted (one
  add/delete/kill per op).
- `Seal.Gateway.ApiSpec` — `POST /api/repos` with `generate_key: true`
  returns the `RepoInfo` descriptor (stable); `GET /api/repos/:id/deploy-key`
  returns the public key + host-aware instructions; `POST
  /api/repos/:id/deploy-key/generate` rotates (new public key, same vault key
  name); `GET /api/repos` never returns a private key.
- Frontend `ReposView.test.tsx` — the "Generate deploy key" flow: selecting
  `deploy_key` defaults to Generate; the vault-key field is auto-filled +
  disabled; after create, `GET .../deploy-key` is fetched + the public key +
  instructions are shown (with a Copy button); the private key is never
  rendered (no field for it); a faint PAT advisory appears next to
  pat/machine_user.
- `Seal.Tools.Exec.RemoteSpec` — agent forwarding adds `-A` to the SSH argv
  **only when the caller passes the ForwardAgent flag** (verified by the
  recording fake runner); the forwarded env carries `SSH_AUTH_SOCK` (not a
  key); the `-A` invariant test (non-credentialed ops have no `-A`).

## 7. Implementation Order (work units)

**RED-GREEN-REFACTOR per unit; `make check` + frontend gate after each.**
New library modules are added to `exposed-modules` and new test specs to the
test-suite `other-modules` in the same WU that creates them. New modules
anticipated: `Seal.ISA.Ops.Git`, `Seal.Tools.Ssh.Agent` (the
`SshAgentHandle` seam + real/fake impls), possibly
`Seal.SourceControl.GithubKeys` (the embedded pinned known_hosts).

1. **W1 — URL normalization** (`Seal.SourceControl.Repo`): move/share
   `normalizeRepoUrl` from `Seal.ISA.Ops.Repo` (re-export to avoid the
   cycle); add `lookupRepoByUrl`.
   - RED: `RepoSpec` failing test (`lookupRepoByUrl` finds a repo across
     SSH↔HTTPS/trailing-`.git`/host-case variants).
   - GREEN: `lookupRepoByUrl` + the shared normalizer.
   - REFACTOR: update `Seal.ISA.Ops.Repo` to use the shared normalizer.
2. **W2 — No-disk clone seam revision + `SshAgentHandle` + env-override
   seam** (`Seal.SourceControl.Clone`, `Seal.Tools.Ssh.Agent` new,
   `Seal.Tools.Exec.Remote` opt-in `-A`, `Seal.Tools.Exec.UntrustedIO`/`
   Untrusted` env-override, pinned known_hosts).
   - RED: `CloneSpec` failing test — the no-disk assertion (snapshot
     `~/.seal/`, run `cloneRepo` deploy-key + PAT, assert no keyfile/helper/
     `-.pub`); the deploy-key path uses `SSH_AUTH_SOCK` env; PAT uses
     `http.extraHeader` argv. `RemoteSpec` failing test — `-A` only with the
     flag.
   - GREEN: remove `writePrivateTempFile`/`escapeSingle`/helper-script;
     `SshAgentHandle` seam + real + fake impls; per-op agent lifecycle
     (start → `ssh-add -` → run → `ssh-add -D` → kill); opt-in `-A` on
     `sshExecArgv` (a `ForwardAgent` flag); env-override seam on `UntrustedIO`
     (`uioShellExecEnv`/`uioBinExecEnv`, existing callers pass `[]`);
     embed/write the pinned GitHub `known_hosts`.
   - REFACTOR: remove now-unused imports (`-Werror`); `CloneDeps` record for
     stable arity.
   - **Human checkpoint: security review of the no-disk seam + per-op
     scoping + opt-in `-A` + pinned host keys.**
3. **W3 — `SETUP_REPO` revision + `Env` field additions** (`Seal.ISA.Ops.Repo`,
   `Seal.Types.Env`): registry lookup + credential injection (trusted plane,
   per-op agent) + the bare-URL fallthrough. **Add `VaultHandle` +
   `RepoRegistryHandle` to `Env`** (built in `mkEnv`, the single constructor —
   small blast radius; update the `Env {...}` literal there + thread the handles
   from `Serve.hs` where they're already constructed). **`setupRepoOp`'s
   signature gains a `CloneDeps`-equivalent param**; update the 5 call sites:
   `Channels/Loop.hs:946,1112`; `Gateway/Send.hs:534,894`;
   `Channel/Cli.hs:426,505`. Update the `cloneRepoIO` callers (the setup-repo
   combo box in `Seal.Gateway.API`, `/repo test` in `Seal.Command.Repo`) to
   build `CloneDeps`. Note: `SourceRepo` positional construction (the codec's
   `SourceRepo srId <$> ...` + `FromJSON`) is NOT caught by
   `-Wincomplete-record-updates` — a manual grep for `SourceRepo` construction
   sites is required when W5 adds `srDeployKeyPublic`.
   - RED: `RepoSpec` failing test — registered deploy-key repo clones via
     the forwarded fake agent; registered PAT via `http.extraHeader`;
     unregistered URL falls through.
   - GREEN: the revision + `Env` fields + caller updates. REFACTOR: share
     the `CloneDeps`-building helper.
4. **W4 — `GIT_FETCH`/`GIT_PULL`/`GIT_PUSH` opcodes** (`Seal.ISA.Ops.Git`
   new): trust level **Untrusted** (they execute git on the untrusted machine
   via `UntrustedIO` — a Trusted opcode has no `UntrustedIO` in scope, per
   §4.2); `GIT_PUSH` audit entry written via `runLocal` before the untrusted
   git run (secret-free, carries `credential_kind`); SSH-executor-`-A` (deploy
   key) / `http.extraHeader` argv (PAT); the origin-URL read via the SSH
   executor.
   - RED: `GitSpec` failing test — happy path (registered repo, one opcode
     call → success, no retry); registry miss → error naming origin URL;
     vault-locked → distinguishable; `GIT_PUSH` audit recorded secret-free +
     carries `credential_kind`; per-op scoping (one add/delete/kill per op).
   - GREEN: the opcodes. REFACTOR: share the credential-resolution helper
     with `SETUP_REPO`.
5. **W5 — Repo-create deploy-key generation + frontend** (`Seal.Gateway.API`
   `POST /api/repos` `generate_key`; `GET /api/repos/:id/deploy-key`;
   `POST /api/repos/:id/deploy-key/generate` rotation; `ReposView`):
   **in-process ed25519 keygen via `crypton` + OpenSSH-format serialization**
   (private→vault `vhPut`; public→`srDeployKeyPublic`); host-aware
   instructions; the frontend "Generate" flow. NO `ssh-keygen` subprocess
   (the `-f -` approach writes to disk — rejected).
   - RED: `ApiSpec` failing test — generate returns `RepoInfo`; `/deploy-key`
     returns public key + instructions; rotate returns new public key; no
     private key in any response. `ReposView.test.tsx` failing test — the
     Generate flow renders the public key + Copy + instructions; private key
     never rendered; PAT advisory present.
   - GREEN: the generation + endpoints + frontend. REFACTOR: share the
     `ssh-keygen` `-.pub` cleanup helper.
6. **W6 — `make check` + frontend gate + final review**: full `make check`
   + `npm run build` + `npm test` + `tsc --noEmit`; cross-unit integration
   (API contract consistency between W5 backend + W5 frontend); no
   leftover TODO/FIXME; commit history clean; **human checkpoint before PR**.

Dependencies: W1 → W2 → W3 → W4 → W5 → W6 (serial — W3/W4 both depend on W2's
seam; W5 depends on W4's opcode wiring; serial avoids PR #80's W4/W5-merge
situation).

## 8. Resolved Decisions (from the design-review gate)

1. **Per-op ssh-agent, NOT session-scoped** — the security review found
   session-scoped breaks the per-repo oracle-scoping claim (multi-repo
   sessions accumulate keys). Per-op (start → load one → run → delete+kill)
   guarantees exactly one identity live at forwarding time.
2. **Pre-pinned GitHub host keys, NOT `accept-new`/`/dev/null`** — the
   security review found `accept-new`+`/dev/null` provides zero host-key
   verification (MITM risk). Pre-pin GitHub's published keys (public data)
   with `StrictHostKeyChecking=yes`.
3. **Opt-in `-A` per git-op, NOT blanket `sshExecArgv`** — the security
   review found a blanket `-A` forwards the agent for every remote op,
   widening the oracle surface. Only git-credential ops pass `-A`.
4. **`ssh-keygen -f -` private→stdout, public→`-.pub` (read+delete)** —
   the architect found `ssh-keygen -f -` writes the public key to `-.pub`
   on disk, not stdout. The harness captures the private key from stdout,
   reads + deletes `-.pub` for the public key (bracket-`finally`).
5. **`SshAgentHandle` is a record-of-IO-actions seam** (real + fake) — the
   CTO found unit tests can't spawn a real `ssh-agent`; the fake enables
   unit-test-speed GitSpec.
6. **No `Env`/`SessionRuntime` field for the agent** — the CTO flagged the
   construction-site blast radius (PR #80's ApiDeps lesson). The per-op
   agent is a value passed per-op via `CloneDeps`, not a long-lived field →
   zero construction-site updates.
7. **`generate_key` split into a stable `POST` + a `GET /deploy-key`
   endpoint** — the designer found a union-type create response would
   silently drop fields in the typed `createRepo` client. Split keeps the
   create response stable.
8. **Host-aware `setup_instructions`** — the designer found the
   GitHub-only URL derivation is wrong for `vcs_kind=git`/arbitrary hosts;
   ship github-only with a generic-text fallback for unknown hosts.
9. **`normalizeRepoUrl` reused, not reimplemented** — the architect found
   `Seal.ISA.Ops.Repo.normalizeRepoUrl` already does the normalization; move/
   share it to avoid two normalizers diverging.
10. **Public key stored as `srDeployKeyPublic` on `SourceRepo`, not in the
    vault** — the security reviewer found coupling public retrieval to a
    private vault read risks surfacing the private key; decouple.
11. **`GIT_PUSH` is Audited** (records-then-runs; secret-free audit entry
    carrying `credential_kind` for forensics).
12. **Do NOT restrict raw `SHELL_EXEC git <remote-op>` this pass** — fail-
    closed naturally (no credential in the sandbox); add a telemetry/log
    line so bypass attempts are observable.
13. **`CredAccountKey` codec fails-closed now** (not reserved) — a stale
    TOML with `account_key` decodes to a parse error, not a crash; the
    constructor lands in a future PR with its 5-site update in lock-step.
14. **`BatchMode=yes` in `GIT_SSH_COMMAND`** — prevents an interactive
    prompt hang if the forwarded agent fails to auth (mirrors the
    harness↔untrusted channel).
15. **In-process ed25519 keygen via `crypton`, NOT `ssh-keygen -f -`** — the
    plan-gate feasibility review verified `ssh-keygen -f -` writes the
    private key to a file named `-` on disk (not stdout) on OpenSSH 9.x,
    which would violate the no-disk requirement. `crypton`'s
    `Crypto.PubKey.Ed25519.generateSecretKey` generates the keypair in
    memory; a pure-Haskell OpenSSH-format serializer produces the
    `ssh-add`-compatible bytes. No subprocess, no disk, fully portable.
16. **Git opcodes are Untrusted (NOT Trusted)** — the plan-gate found
    `TrustedOpcode.toRun` has NO `UntrustedIO` in scope (only `BackendExec.runLocal`),
    so an opcode that executes git on the untrusted machine MUST be
    `UntrustedOpcode`. `GIT_PUSH`'s audit entry is written via `runLocal`
    before the untrusted git run (per-opcode audit, not a new constructor).
17. **Remote-arm env via `env VAR=val` prefix in the command string** —
    `ssh -A` only forwards the agent socket (not arbitrary env); `SendEnv`/
    `SetEnv` need server `AcceptEnv` (default `none`). The `env` prefix is
    the portable, server-config-independent path.
18. **`Env` gains `VaultHandle` + `RepoRegistryHandle`** — the opcodes run
    in `App` (= `ReaderT Env`); `Env` is the clean way to expose them. `mkEnv`
    is the single constructor (small blast radius). `setupRepoOp` gains a
    `CloneDeps`-equivalent param; the 5 call sites enumerated (W3).

## 9. Acceptance Criteria

1. No un-encrypted secret on disk, either machine, for any git op — verified
   by the no-disk test (snapshot `~/.seal/` + untrusted workdir; assert no
   plaintext key/helper script/keyfile/`-.pub`; only the vault's encrypted
   file + the public pinned `known_hosts`).
2. Deploy keys are the preferred kind; a fresh per-repo key is auto-generated
   at repo-create with the public key + host-aware instructions shown; the
   private key is never rendered in the frontend.
3. SSH agent forwarding (per-op): the private key never crosses to the
   untrusted machine; a compromised binary / co-resident process gets only a
   per-op, per-repo signing oracle (exactly one identity live at forwarding
   time — verified by the per-op scoping test).
4. Host-key verification (untrusted↔github) via pre-pinned GitHub keys
   (`StrictHostKeyChecking=yes`, never `accept-new`/`/dev/null`) — no MITM.
5. `SETUP_REPO` clones a registered private repo (deploy key) successfully
   via the forwarded agent; a registered PAT repo via `http.extraHeader`
   argv; an unregistered URL falls through to the bare-URL clone.
6. `GIT_FETCH`/`GIT_PULL`/`GIT_PUSH` work first time for a registered repo,
   transparently to the model (one opcode call → success, no retry — S2).
7. `GIT_PUSH` is Audited with a secret-free audit entry (carries
   `credential_kind` for forensics, never the credential).
8. No `ToJSON` on any secret carrier; no secret in any API response, log, or
   transcript entry. `GET /api/repos/:id/deploy-key` returns the public key
   only; `GET /api/repos`/`:id` return only the descriptor (key NAME).
9. The PAT residual (token-in-untrusted-memory via argv + the swap edge) is
   documented in the design and in the `/repo add --cred pat` help text +
   a `ReposView` advisory; deploy keys are recommended.
10. `-A` is opt-in per git-op (non-credentialed remote ops have no `-A` —
    verified by `RemoteSpec`).
11. `make check` + frontend gate green; all new modules in
    `exposed-modules`/`other-modules`. `Env` gains `VaultHandle`/
    `RepoRegistryHandle` (centralized in `mkEnv`); no `SessionRuntime` field
    additions (per-op `CloneDeps`).
12. User-focused (S1-S3): register+generate+clone in one flow; push
    first-try with no retry; rotation under the same vault key name with
    zero registry edits.