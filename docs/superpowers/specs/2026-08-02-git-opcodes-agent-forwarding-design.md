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
   `ssh-keygen -t ed25519 -f - -N "" -C "seal-deploy-key:<repo-id>"` writes the
   private+public keypair to **stdout** (the `-f -` flag sends the key to
   stdout instead of a file; `-N ""` sets no passphrase). The harness captures
   both, stores the **private** key in the vault under a per-repo key name
   (e.g. `seal-deploy-key:<repo-id>`) via `vhPut`, and returns the **public**
   key to the frontend for display + copy-paste instructions. No keyfile on
   disk at any point.
2. **Loading** (at git-op time, on the harness): the harness starts a
   per-session `ssh-agent` (a child process), then `ssh-add -` reads the
   private key bytes from `vhGet` via **stdin** (a pipe: `vhGet` →
   `BS.hPut stdin` → `ssh-add`). The key lives in the agent's memory; the
   vault's age-encrypted file is the only on-disk form (already
   encrypted-at-rest, satisfying the requirement). `SSH_AUTH_SOCK` +
   `SSH_AGENT_PID` are captured.
3. **Use** (the git op, on the untrusted machine via the SSH executor):
   `ssh -A ... user@untrusted-host -- git ...` (the `-A` flag enables agent
   forwarding). On the untrusted machine, `SSH_AUTH_SOCK` is set to a
   forwarded socket; when `git`/`ssh` (reaching github.com) needs to sign, the
   request tunnels back over the SSH channel to the harness agent, which signs
   with the in-memory key and returns the signature. **The private key never
   crosses to the untrusted machine** — not disk, not memory.

**Trust-boundary win:** a compromised `git`/`ssh` binary on the untrusted
machine gets a **signing oracle for the session window, scoped to that one
repo's deploy key**. It can auth to that one GitHub repo while the session
lives; when the harness kills the agent at session end, the attacker has
nothing. It cannot exfiltrate a persistent credential (there is none to
exfiltrate), and it cannot auth to other repos/hosts (deploy keys are
repo-scoped). This is the core security improvement.

#### 4.1.2 HTTPS PAT / machine-user (fallback) — `http.extraHeader` in argv

PATs fundamentally must be presented at every HTTPS request, so the token has
to be where git runs (the untrusted machine). The no-disk mechanism: pass
`git -c http.extraHeader='Authorization: Basic <base64(user:token)>'` as the
git argv (via BIN_EXEC — no shell). The token lives in the git process's
**argv** (kernel-owned memory), never disk. Residual: argv is visible to
co-resident processes via `/proc/<pid>/cmdline` (memory, not disk — satisfies
the no-disk rule, but the token *does* cross to untrusted memory and a
compromised `git` binary can log it from argv). **Documented as the lesser
path; deploy keys preferred.** Machine-user uses the same path with
`base64(cUsername:token)`.

**Note:** the W3 `GIT_ASKPASS`-helper-script-on-disk approach is **removed**
for both PAT and DeployKey. The `resolveCloneTarget` seam is replaced by the
no-disk seam in §4.4.

### 4.2 Trust level of the new opcodes

`SHELL_EXEC` is Untrusted (sandbox, interacts with the outside world). The
new git opcodes run **in the trusted plane**: the harness resolves the
credential (via `vhGet` + the harness ssh-agent) and executes git itself (via
BIN_EXEC for PAT, via the SSH-executor for deploy-key-with-forwarding). This
is a genuine trust-model shift: git remote ops move from "the agent runs git
in the sandbox" to "the harness runs git, authenticating with a credential
the sandbox never sees."

- **`SETUP_REPO`** (revised): stays **Untrusted** for the clone itself (the
  clone is a filesystem-mutating op in the workdir), but the **credential
  resolution + the auth injection happen in the trusted plane** before the
  clone command is handed to the sandbox. Concretely: the harness looks up the
  URL in the registry, resolves the credential, and either (a) for deploy
  keys, sets `GIT_SSH_COMMAND` with a forwarded `SSH_AUTH_SOCK` env that the
  sandboxed clone inherits, or (b) for PATs, rewrites the URL to HTTPS and
  passes `http.extraHeader` via the clone's argv. The sandboxed `git clone`
  runs with the auth available but never reads the key/token itself.
- **`GIT_FETCH` / `GIT_PULL`**: **Trusted** (harness-internal, logged in the
  session transcript). These read from a remote but don't mutate the
  cross-session evolutionary state.
- **`GIT_PUSH`**: **Audited** (Trusted + the unified cross-session
  append-only log). `GIT_PUSH` mutates a remote repo, which transcends the
  session — the ISA philosophy says cross-session mutations are Audited so
  they're reconstructible from the global log. The push's audit entry records
  the workdir, the remote URL (host-bound, allow-listed), the ref, and the
  outcome (secret-free — never the token/key).

The design-gate security reviewer should weigh in on whether `GIT_PUSH` is
Audited vs Trusted; the recommendation is Audited on the "transcends the
session" principle, mirroring `CONFIG_UPDATE` / `SECRET_SAVE`.

### 4.3 The opcodes

#### `SETUP_REPO` (revised — `Seal.ISA.Ops.Repo.setupRepoOp`)
Input: `{url: Text}` (unchanged). Behavior:
1. **Registry lookup**: normalize the URL (SSH ↔ HTTPS, trailing `.git`,
   case-fold the host — see §4.5 `lookupRepoByUrl`) and consult the
   `RepoRegistry`. If found → credential path. If not found → the existing
   bare-URL clone (public repos, backward-compatible — no auth injection).
2. **Credential path (deploy key)**: resolve via the harness ssh-agent (§4.1.1).
   The clone runs in the sandbox with `GIT_SSH_COMMAND="ssh -o
   StrictHostKeyChecking=accept-new -o UserKnownHostsFile=<per-session-private-
   known-hosts>"` and the forwarded `SSH_AUTH_SOCK` env. **No keyfile
   anywhere.** (The `known_hosts` is a per-session file under
   `repoCloneStateDir` carrying only host-key fingerprints, not secrets —
   satisfies the no-disk rule; or, to avoid even that, use
   `StrictHostKeyChecking=accept-new` with a memory-only known_hosts via
   `UserKnownHostsFile=/dev/null` + `GlobalKnownHostsFile=/dev/null` —
   **decision: `/dev/null` for the no-disk invariant; accept-new prompts to
   the agent's stderr, which git handles non-interactively with
   `StrictHostKeyChecking=accept-new`**. Verify in W3-clone-tests that this
   doesn't hang on first connect.)
3. **Credential path (PAT / machine-user)**: rewrite the URL to HTTPS
   (token-free), clone via BIN_EXEC with `http.extraHeader` in argv (§4.1.2).
4. `orRecorded`: the url + target path + status (secret-free, as today).

#### `GIT_FETCH` / `GIT_PULL` (new — `Seal.ISA.Ops.Git`)
Input: `{workdir: Text, remote?: Text (default "origin"), ref?: Text}`. Behavior:
1. Resolve the workdir's origin URL (the sandbox reports it, or the harness
   reads it via the SSH executor: `git -C <workdir> config --get remote.origin.url`).
2. `lookupRepoByUrl` → registry hit → resolve credential (§4.1) → run
   `git -C <workdir> fetch [--refspec]` (or `pull`) via BIN_EXEC (PAT) or the
   SSH executor with `-A` (deploy key). Registry miss → the op fails with a
   clear "no credential registered for <host>; use SETUP_REPO or /repo add"
   (the model can't silently fall back to an unauthenticated fetch that would
   leak whether the repo is public; it must use the registered path).
3. `orRecorded`: workdir + remote + ref + outcome.

#### `GIT_PUSH` (new — Audited)
Input: `{workdir: Text, remote?: Text, refspec: Text}`. Same credential path
as FETCH/PULL. The audit entry records the push (cross-session, secret-free).

### 4.4 The no-disk clone/credential seam (replaces W3 `Seal.SourceControl.Clone`)

`Seal.SourceControl.Clone` is revised:
- **`resolveCloneTarget`** no longer writes a `GIT_ASKPASS` helper script or a
  keyfile. It returns a `CloneEnv` carrying:
  - **DeployKey**: `ceEnvExtras = [("SSH_AUTH_SOCK", <forwarded-socket>),
    ("GIT_SSH_COMMAND", "ssh -o StrictHostKeyChecking=accept-new -o
    UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes")]`. No keyfile.
  - **PAT/MachineUser**: `ceGitConfigArgs = ["-c",
    "http.extraHeader=Authorization: Basic <base64>"]`, `ceUrl` = token-free
    HTTPS URL. No helper script.
- **`withCloneTarget`** CPS bracket: no `ceCleanup` file removal (there's
  nothing to clean up). The bracket only kills the per-op ssh-agent if one
  was started for this op (for the standalone `cloneRepo`/`lsRemoteRepo`
  entrypoints used by `/repo test`; the session-scoped agent is managed
  elsewhere — see §4.6).
- The `escapeSingle` shell-escaping machinery is **removed** (no helper
  script generation → no shell-escaping surface). The §5.2 command-injection
  class is eliminated by construction.
- `cloneRepo` / `lsRemoteRepo` keep their signatures (used by `/repo test`)
  but now take a `VaultHandle` + a per-op ssh-agent lifecycle (start agent,
  `ssh-add -` from `vhGet`, run, kill agent) for deploy keys, or pure-argv
  for PATs.

### 4.5 URL normalization + registry lookup

`lookupRepoByUrl :: Text -> RepoRegistry -> Maybe SourceRepo`:
- Normalize the query URL: strip trailing `.git`, case-fold the host,
  canonicalize scheme (`git@github.com:o/r` ↔ `https://github.com/o/r` ↔
  `ssh://git@github.com/o/r`).
- Match against `srUrl` (similarly normalized) in the registry.
- Returns the `SourceRepo` (with its credential) or `Nothing`.

This is needed because `SETUP_REPO`/`GIT_FETCH` receive a URL (from the model
or the workdir's `.git/config`) that may not string-match the registered
`srUrl`. Pure, QuickCheck-testable.

### 4.6 The session-scoped ssh-agent lifecycle

For `GIT_FETCH`/`GIT_PULL`/`GIT_PUSH` (repeated remote ops over a session),
starting a per-op ssh-agent would be wasteful. Instead: a **session-scoped**
ssh-agent, started lazily on the first deploy-key op of the session, held in
the session's `Env` (or a per-session handle in `SessionRuntime`), killed at
session end. The first `GIT_FETCH` with a deploy key starts the agent +
`ssh-add`s the key (from the vault); subsequent ops reuse the agent. PATs
don't use the agent.

**Lifecycle hooks:** session start (no agent — lazy), first deploy-key op
(start + load), session end (kill agent, clear `SSH_AUTH_SOCK`/`SSH_AGENT_PID`).
The existing session teardown (`Seal.Session.Store`) gains an agent-cleanup
hook. `Env` (or `SessionRuntime`) gains a `Maybe SshAgentHandle` field.

### 4.7 Frontend: auto-generate deploy key at repo-create

`ReposView` "New" flow (and the `/repo add` slash command, for parity):
- When the user selects `credential.kind = deploy_key` and clicks "Generate"
  (or by default for the deploy-key kind), the frontend `POST /api/repos`
  with a flag `generate_key: true`.
- The backend handler, on `generate_key: true`:
  1. `ssh-keygen -t ed25519 -f - -N "" -C "seal-deploy-key:<repo-id>"` (stdout
     → private + public key bytes; no keyfile).
  2. `vhPut vaultHandle ("seal-deploy-key:" <> repoId) privateKeyBytes` (the
     vault is the encrypted-at-rest store).
  3. Store the `SourceRepo` with `CredDeployKey { cVaultKey =
     "seal-deploy-key:" <> repoId }`.
  4. Return the public key + copy-paste instructions in the 201 response: a
     `deploy_key_public` field + a `setup_instructions` field (the GitHub
     "Add new deploy key" URL for the repo's host, derived from the URL;
     e.g. `https://github.com/<owner>/<repo>/settings/keys/new`).
- `ReposView` renders the public key in a `<pre>` block with a "Copy" button
  + the instructions ("Add this as a deploy key with **read** (and **write**,
  if you intend to `GIT_PUSH`) permissions at the URL below. The harness will
  use it to clone/fetch/pull/push without ever writing the private key to
  disk."). The key is shown once at creation; later `GET /api/repos` returns
  only the key *name* (never the private key — it's in the vault).
- **Decision: the public key is also retrievable later** via `GET
  /api/repos/:id/deploy-key` (operators need to re-copy it if they lose it;
  the public key is not secret). The private key is never returned by any
  endpoint (no `ToJSON` for it; the vault is write/read via `vhGet` only
  inside the credential seam).

### 4.8 Account-wide SSH key (rare, non-repo GitHub automation)

The user noted this infrastructure also supports a regular SSH key with
permissions for a whole GitHub account, for rare non-repo GitHub ops. The
design accommodates this: a `SourceRepo` entry whose `srUrl` is a sentinel
like `git@github.com:*` (or a new `CredAccountKey { cVaultKey }` constructor
if the design-gate prefers explicitness) registers an account-wide key. The
opcodes consult the registry by URL; an account-wide key matches any
`github.com` URL that doesn't have a per-repo entry. The design-gate should
decide: sentinel URL vs new constructor. **Recommendation: a new constructor
`CredAccountKey { cVaultKey, cHost }`** — explicit, host-scoped, doesn't
overload the URL field. Out of scope for the first implementation pass (only
per-repo deploy keys + PAT fallback ship); the constructor is reserved.

## 5. Security Considerations

### 5.1 No un-encrypted secret on disk (the binding requirement)
- **Vault**: the only on-disk form of any credential; age-encrypted at rest
  (existing vault guarantees). Satisfies the requirement by construction.
- **Deploy key in use**: harness ssh-agent memory, loaded via `ssh-add -`
  (stdin pipe from `vhGet`). Never a keyfile on disk.
- **PAT in use**: git argv (memory). Never a helper script or env file on
  disk.
- **Verification**: a test that runs `cloneRepo`/`lsRemoteRepo`/`SETUP_REPO`/
  `GIT_FETCH` and asserts no new files appear under `repoCloneStateDir` (or
  anywhere in `~/.seal/` except the vault's encrypted file). The W3
  `writePrivateTempFile` calls are removed; the test asserts the
  `repoCloneStateDir` is empty (or contains only non-secret `known_hosts`
  if `/dev/null` proves unworkable — decision pending the W3-clone test).

### 5.2 The compromised-binary threat on the untrusted machine (the user's core concern)
- **Deploy key + agent forwarding**: a compromised `git`/`ssh` binary on the
  untrusted machine gets a **signing oracle for the session, scoped to the
  one repo's deploy key**. It can auth to that repo while the session lives;
  it cannot exfiltrate a persistent credential (none exists); when the
  harness kills the agent at session end, the attacker has nothing. It cannot
  auth to other repos/hosts (deploy keys are repo-scoped). This is the
  strongest practical answer to the injection concern.
- **PAT + `http.extraHeader` argv**: a compromised `git` binary can read the
  token from argv (`/proc/<pid>/cmdline` or its own argv) and exfiltrate it.
  The token is a persistent credential (valid until revoked). This is the
  inherent, unavoidable residual of HTTPS credentials. **Mitigation: prefer
  deploy keys; document the PAT residual; recommend short-lived,
  narrowly-scoped PATs if PATs are used.** The design does not pretend
  PATs are equivalent to deploy keys.
- **Account-wide SSH key** (§4.8, reserved): a compromised binary gets an
  oracle scoped to the *whole account* — broad. Hence per-repo deploy keys
  are the default; account keys are an explicit, rare opt-in.

### 5.3 Agent forwarding over the SSH executor (remote/SSH path)
- The remote SSH executor (`Seal.Tools.Exec.Remote`) already pins host keys
  (`StrictHostKeyChecking=yes`, pinned `UserKnownHostsFile`, `BatchMode=yes`).
  Agent forwarding adds `-A`. The forwarded `SSH_AUTH_SOCK` on the untrusted
  machine is an IPC channel (no key bytes); signing requests tunnel back to
  the harness agent. The host-key pinning on the harness↔untrusted channel
  is unchanged.
- **Local executor degeneration**: for the local untrusted executor, "the
  untrusted machine" is the same machine; "forwarding" degenerates to "the
  sandbox shares the harness's `SSH_AUTH_SOCK`" (same user, shared PID
  namespace). Still no-disk, but the clean key-never-crosses separation is a
  remote-executor property. The design calls this out; the local executor is
  not changed. The `remote-only-untrusted` Cabal flag (the hardened path)
  gets the full benefit.

### 5.4 Host allow-list + host-binding (carried from PR #80's design)
- `github.com` allow-list enforced at registry-write time (`/api/repos`
  validation) and at clone/credential-injection time (`planClone` →
  `CloneHostNotSupported`). A registry entry can't point a credential at an
  attacker host. (For account-wide keys, the `cHost` field binds the key to
  a host; the clone-time assertion checks `host == cHost`.)

### 5.5 No secret in logs/transcript/API response (carried from PR #80)
- `CloneTarget` opaque + redacted `Show`; `withCloneTarget` CPS; the
  opcodes' `orRecorded` payloads are secret-free (url, workdir, ref,
  outcome — never token/key). The audit log entry for `GIT_PUSH` records
  the push happened, not the credential. No `ToJSON` on any secret carrier.
- `CloneGitFailed` carries exit code only (no stderr) — carried from W3.

### 5.6 Should raw `SHELL_EXEC git <remote-op>` be restricted for private-repo workdirs?
- **Question for the design-gate**: now that typed opcodes exist for the
  remote ops, should the harness *deny* raw `SHELL_EXEC git fetch/pull/push`
  in a workdir whose origin URL is a registered private repo? Without
  restriction, the agent could bypass the opcodes and run `git push` itself —
  which would (a) fail without auth (no credential in the sandbox) for
  private repos, leaking nothing, but (b) succeed for *public* repos, and
  (c) for a registered repo with a *PAT* credential, the agent doesn't have
  the token in the sandbox so it can't auth anyway.
- **Recommendation: do NOT restrict in this pass.** The opcodes are the
  recommended path; raw `SHELL_EXEC git` for remote ops on a private repo
  simply fails (no credential available in the sandbox) — which is the
  correct fail-closed behavior. Restriction is a policy refinement for a
  later design (it intersects with the autonomy policy + the
  `remote-only-untrusted` flag). The design-gate should confirm.

### 5.7 The per-session known_hosts (if `/dev/null` is unworkable)
- If `StrictHostKeyChecking=accept-new` + `UserKnownHostsFile=/dev/null`
  proves to hang or misbehave on first connect (needs verification in
  implementation), the fallback is a per-session `known_hosts` file under
  `repoCloneStateDir` (0700 parent). This file carries **only host-key
  fingerprints** (public data, not secrets) — satisfies the no-disk rule
  (no *un-encrypted secret* on disk; a host fingerprint is not secret). The
  design-gate security reviewer should confirm a host fingerprint is
  acceptable under the requirement, or insist on `/dev/null`.

## 6. Testing Plan (TDD, `make check` gate)

- `Seal.SourceControl.CloneSpec` (revised) — **no-disk assertion**: run
  `cloneRepo`/`lsRemoteRepo` for a deploy-key repo and a PAT repo; assert
  `repoCloneStateDir` contains no keyfiles/helper-scripts (only possibly a
  `known_hosts` if §5.7 fallback); assert the deploy-key path uses
  `SSH_AUTH_SOCK` env (no keyfile path in env); assert the PAT path uses
  `http.extraHeader` argv (no `GIT_ASKPASS`). The W3 `escapeSingle` + helper-
  script tests are removed.
- `Seal.SourceControl.RegistrySpec` — `lookupRepoByUrl` (URL normalization:
  SSH↔HTTPS, trailing `.git`, host case-fold); QuickCheck.
- `Seal.ISA.Ops.RepoSpec` (revised) — `SETUP_REPO` with a registered
  private repo (deploy key) clones successfully via the forwarded agent (fake
  SSH executor); with a PAT clones via `http.extraHeader` argv; with an
  unregistered URL falls through to the bare-URL clone (backward-compat).
- `Seal.ISA.Ops.GitSpec` (new) — `GIT_FETCH`/`GIT_PULL`/`GIT_PUSH` happy path
  (registered repo, credential resolved, git runs via BIN_EXEC/SSH executor);
  registry miss → clear error; vault-locked → distinguishable error;
  `GIT_PUSH` audit entry recorded (secret-free).
- `Seal.Gateway.ApiSpec` — `POST /api/repos` with `generate_key: true`
  returns the public key + instructions; `GET /api/repos/:id/deploy-key`
  returns the public key; `GET /api/repos` never returns a private key.
- Frontend `ReposView.test.tsx` — the "Generate deploy key" flow shows the
  public key + copy button + instructions; the private key is never rendered
  (no field for it); the credential form for `deploy_key` offers "Generate"
  (and the vault-key field is auto-filled + disabled with the generated name).
- `Seal.Tools.Exec.RemoteSpec` — agent forwarding adds `-A` to the SSH argv
  (verified by the recording fake runner); the forwarded env carries
  `SSH_AUTH_SOCK` (not a key).

### Security-invariant tests (executable, not just claimed)
- **No-disk**: snapshot `~/.seal/` before, run a clone + a fetch + a push,
  snapshot after, assert the only new file is the vault's encrypted file
  (for a newly-stored key) — no plaintext key, no helper script, no
  keyfile. (On the untrusted machine: assert the SSH executor's recorded
  argv carries no keyfile path, only `SSH_AUTH_SOCK`.)
- **No-private-key-in-API**: `GET /api/repos`, `GET /api/repos/:id`,
  `GET /api/repos/:id/deploy-key` — assert no field matches a planted
  private key; the public key IS returned by `/deploy-key`.

## 7. Implementation Order (work units)

RED-GREEN-REFACTOR per unit; `make check` + frontend gate after each.

1. **W1 — URL normalization** (`Seal.SourceControl.Repo`):
   `lookupRepoByUrl` + the pure URL normalizer. `RepoSpec` additions.
2. **W2 — No-disk clone seam revision** (`Seal.SourceControl.Clone`):
   remove `writePrivateTempFile`/`escapeSingle`/helper-script; deploy-key
   path via `SSH_AUTH_SOCK` env; PAT path via `http.extraHeader` argv. The
   per-op ssh-agent lifecycle (start, `ssh-add -` from `vhGet`, run, kill).
   `CloneSpec` revision (the no-disk assertions). *(Human checkpoint:
   security review.)*
3. **W3 — Session-scoped ssh-agent handle** (`Seal.Session.Store` +
   `Env`/`SessionRuntime`): `Maybe SshAgentHandle` field; lazy start on first
   deploy-key op; kill at session end. `Session.StoreSpec` additions.
4. **W4 — `SETUP_REPO` revision** (`Seal.ISA.Ops.Repo`): registry lookup +
   credential injection (trusted plane) + the bare-URL fallthrough.
   `RepoSpec` revision.
5. **W5 — `GIT_FETCH`/`GIT_PULL`/`GIT_PUSH` opcodes** (`Seal.ISA.Ops.Git`):
   new module; trust levels (Trusted/Trusted/Audited); BIN_EXEC (PAT) /
   SSH-executor-`-A` (deploy key); audit entry for push. `GitSpec`.
6. **W6 — Repo-create deploy-key generation + frontend** (`Seal.Gateway.API`
   `/api/repos` `generate_key`; `/api/repos/:id/deploy-key`; `ReposView`):
   `ssh-keygen -f -`; vault `vhPut`; public-key + instructions in response;
   the frontend "Generate" flow. `ApiSpec` + `ReposView.test`.
7. **W7 — `make check` + frontend gate + final review**.

Dependencies: W1 → W2 → W3 → W4 → W5 → W6 → W7 (W4/W5 both depend on W2/W3;
W6 depends on W4's API contract; serial to avoid the W4/W5-merge situation
from PR #80).

## 8. Open Questions for the Design Gate

1. **`GIT_PUSH` trust level** — Audited (recommended, "transcends the
   session") vs Trusted?
2. **Account-wide SSH key representation** — sentinel URL `git@github.com:*`
   vs new `CredAccountKey { cVaultKey, cHost }` constructor (recommend the
   latter; out of scope for the first pass, constructor reserved)?
3. **`known_hosts` strategy** — `/dev/null` + `accept-new` (preferred,
   truly no-disk) vs per-session `known_hosts` under `repoCloneStateDir`
   (host fingerprints are public data, not secrets — acceptable, but
   `/dev/null` is cleaner)?
4. **Restrict raw `SHELL_EXEC git <remote-op>` for private-repo workdirs?**
   (recommend NO in this pass — fail-closed naturally; restriction is a later
   policy refinement).
5. **`SETUP_REPO` trust level after revision** — stays Untrusted for the
   clone (recommended) with trusted-plane credential resolution, or moves to
   Trusted?
6. **Does the local untrusted executor get agent forwarding at all?** (it
   degenerates to shared-`SSH_AUTH_SOCK`; the design documents this but the
   local path may need a different no-disk mechanism — confirm at the gate).

## 9. Acceptance Criteria

1. No un-encrypted secret on disk, either machine, for any git op — verified
   by the no-disk test (snapshot `~/.seal/` + assert no plaintext key/helper
   script/keyfile).
2. Deploy keys are the preferred kind; a fresh per-repo key is auto-generated
   at repo-create with the public key + instructions shown.
3. SSH agent forwarding: the private key never crosses to the untrusted
   machine; a compromised binary gets only a per-session, per-repo signing
   oracle.
4. `SETUP_REPO` clones a registered private repo (deploy key) successfully
   via the forwarded agent; a registered PAT repo via `http.extraHeader`
   argv; an unregistered URL falls through to the bare-URL clone.
5. `GIT_FETCH`/`GIT_PULL`/`GIT_PUSH` work first time for a registered repo,
   transparently to the model (no credential reasoning, no retry).
6. `GIT_PUSH` is Audited (or Trusted per gate decision) with a secret-free
   audit entry.
7. No `ToJSON` on any secret carrier; no secret in any API response, log, or
   transcript entry. `GET /api/repos/:id/deploy-key` returns the public key
   only.
8. `make check` + frontend gate green; all new modules in
   `exposed-modules`/`other-modules`.
9. The PAT residual (token-in-untrusted-memory via argv) is documented in the
   design and in the `/repo add --cred pat` help text; deploy keys are
   recommended.