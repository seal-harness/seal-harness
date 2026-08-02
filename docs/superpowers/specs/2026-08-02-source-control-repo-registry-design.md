# Source Control Repo Registry + Credential-Backed Cloning

**Issue**: https://github.com/seal-harness/seal-harness/issues/78
**Branch**: `feat/source-control-repos`
**Date**: 2026-08-02
**Status**: Design — revision 1 (post design-review-gate round 1)

## 1. Problem

Seal Harness has no registry of the source-control repositories it operates on.
Today a GitHub SSH URL such as `git@github.com:seal-harness/seal-harness.git`
cannot be cloned from within the harness unless the host already happens to have
working SSH credentials or a configured credential helper. There is no way to
say "this repo is authenticated with *this* Seal vault key," so cloning fails
opaquely when credentials aren't available.

Issue #78's stated motivation (operator request): "Currently these [GitHub SSH
URLs] are not cloning properly if the credentials aren't available." The
existing `SETUP_REPO` opcode (`Seal.ISA.Ops.Repo.cloneRepoIO`) clones a bare URL
in the Untrusted sandbox and reports `CloneFailed` with raw git stderr on any
auth failure — no way to attach a credential, no operator-controlled registry,
opaque failure to the user.

We want a single, VCS-agnostic store of `(repo URL, credential reference)` pairs
where the credential reference points at a Seal vault key — never at a secret
value. The first concrete use case is GitHub SSH URLs, but the type must not be
Git-specific. We also want CRUD for these entries from both the web frontend
and a chat-channel slash command.

## 1a. Use Cases (WHO / WANTS / SO THAT / WHEN)

The primary persona is the **operator** — the human who runs `seal serve`,
unlocks the vault, and configures which repos the harness may clone. The
slash-command and REST surfaces are operator tools; the agent does **not** get
to mutate the registry (see §5 Security — the mutators are operator-only and
not reachable from the agent's tool plane).

1. **Operator registers a private repo** — *As* an operator, *I want* to record
   a private GitHub repo's URL together with the vault key holding its
   credential, *so that* the harness can clone it without me hand-configuring
   host SSH credentials, *when* I add a new project for the agent to work on.
2. **Operator clones a registered repo and it succeeds where it used to fail
   opaquely** — *As* an operator, *I want* a registered repo to clone
   successfully on a host with no pre-existing SSH keys, *so that* a fresh
   machine/CI runner can stand up a session workdir from just `seal serve` +
   `vault unlock`, *when* the agent (or a `/repo test` command) triggers a
   clone.
3. **Operator rotates a credential in the vault** — *As* an operator, *I want*
   to rotate a PAT or deploy key in the vault under the same key name, *so
   that* the registry needs no change and the next clone uses the new
   credential, *when* a token expires or is revoked.
4. **Operator hits a missing/locked vault key at clone time** — *As* an
   operator, *I want* a clear, actionable error naming the missing vault key or
   "vault locked", *so that* I can unlock the vault or store the key rather than
   seeing a generic git-auth failure, *when* a clone is attempted before the
   credential is available.
5. **Operator manages the registry from chat or web** — *As* an operator, *I
   want* to add/list/remove/inspect repos from either a chat channel
   (`/repo ...`) or the web UI (`ReposView`), *so that* I can manage the
   registry from wherever I am, *when* I'm on my phone (chat) or at my desk
   (web).
6. **Operator verifies a credential works** — *As* an operator, *I want* to run
   `/repo test <id>` (a `git ls-remote`, no full clone) against the resolved
   credential, *so that* I get a fast "credential works" signal at registration
   time rather than discovering a bad token on the first real clone, *when* I
   add or rotate a repo entry.

## 1b. User-Focused Success Criteria (in addition to the technical DoD in §9)

- **S1**: An operator can register a private GitHub repo and successfully
  `git clone` it via the credential-injection seam on a host with **no** host
  SSH credentials, within **one** `/repo add` + one clone invocation.
- **S2**: A clone failure caused by a missing vault key surfaces an error that
  names the missing key (e.g. `"vault key GITHUB_PAT_FOO not found"`) or
  reports `"vault locked"` — never a bare git stderr. Verified by a test that
  plants a missing key and asserts the error text contains the key name.
- **S3**: Rotating a vault key's value under the same name requires **zero**
  registry edits for the next clone to use the new value. Verified by a test
  that mutates the fake vault between two clones and asserts the second uses
  the new bytes.
- **Evaluation timeline**: one month after release, if no registered repo has
  been cloned via the credential-injection path, the registry is not earning
  its complexity and we revisit (remove or fold into `SETUP_REPO`).

## 2. Goals & Non-Goals

### Goals
1. Store a collection of repos (id + URL + VCS kind + credential reference) in a
   simple file under `config/`. No secret values in the file — only vault key
   names. **Must-have.**
2. VCS-agnostic type; first-class GitHub SSH support. **Must-have.**
3. Three credential kinds, all backed by the Seal vault:
   - **GitHub PAT** ("Personal Access Token") — vault key holds a token;
     inject via `git -c http.extraHeader='Authorization: Basic <base64>'` (token
     **never** in argv or URL; see §5).
   - **SSH deploy key** — vault key holds an SSH private key; inject via
     `GIT_SSH_COMMAND="ssh -i <keyfile> -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"`.
   - **Machine user** ("Bot account") — vault key holds a token + a plaintext
     `username`; inject via the same `http.extraHeader` path with
     `base64(username:token)`.
   **Must-have** for PAT + deploy key (cover the overwhelmingly common GitHub
   cases); **should-have** for machine user.
4. Cloning a registered GitHub SSH repo succeeds without any pre-existing host
   credentials, using the referenced vault key, and the token is **never**
   visible in `ps`/`/proc`/argv/URL. **Must-have.**
5. REST CRUD (`/api/repos`, **operator-only**) + a `/repo` slash command
   (**operator-only**) + a `ReposView` frontend view. **Must-have.**
6. No secret value is ever serialized to the transcript, logs, an API response,
   argv, or a process's environment that a co-resident untrusted process can
   observe. **Must-have.**

### Non-Goals
- Git operations other than clone (push/pull/fetch) — deferred.
- Providers other than GitHub (the type is VCS-agnostic; only GitHub credential
  injection is implemented in this pass).
- OAuth / GitHub App token rotation.
- Per-session workdir integration (repos are configured globally; wiring a repo
  into a session's clone-time workdir is a follow-up).
- Concurrent-clone orchestration, caching of resolved URLs, or a clone opcode
  in the ISA. This pass delivers the *registry + credential-injection seam*;
  the existing `SETUP_REPO` opcode and a future `CLONE`-into-workdir opcode are
  discussed in §4.9.

## 3. Existing Building Blocks (no re-invention)

| Concern | Existing module | Reuse |
|---|---|---|
| Encrypted vault, keyed by `Text` | `Seal.Security.Vault` (`vhGet`/`vhPut`/`vhList`) | credential *values* live here |
| Opaque secret carriers, redacted `Show`, CPS access | `Seal.Security.Secrets` (`withApiKey`, `withBearerToken`) | pattern for `withDeployKey` |
| TOML codec, atomic save, MVar write-lock | `Seal.Config.File` (`saveRuntimeConfig`, `updateRuntimeConfig`, `configWriteLock`) | mirror for `repos.toml` |
| "vault key name reference, no value" config field | `Seal.Config.File` `wcSearchAuthKey` | exact precedent for our credential shape |
| Config dir paths | `Seal.Config.Paths` (`spConfig`, `configFilePath`) | add `reposFilePath` |
| Slash command spec + parser | `Seal.Command.Spec` / `Seal.Command.Parse` / `Seal.Command.Skill` | `/repo` mirrors `/skill` |
| REST routing | `Seal.Gateway.API` (manual WAI router) | add `/api/repos` routes |
| Frontend CRUD view | `frontend/src/components/SkillsView.tsx` | `ReposView` mirrors it |
| Top-level SPA section | `frontend/src/components/TopBar.tsx` (`TopSection`) | add `'repos'` |

## 4. Design

### 4.1 Data model — `Seal.SourceControl.Repo`

```haskell
-- VCS-agnostic kind. Only GitHub credential injection is implemented in this
-- pass; future kinds (GitLab, Mercurial, ...) add constructors without breaking
-- the storage shape.
data VcsKind = VcsGit | VcsGitHub
  deriving stock (Eq, Show)

-- The credential shape. The toml carries ONLY the vault key name (and, for
-- MachineUser, the plaintext username + the bound host). Secret VALUES live in
-- the vault.
data RepoCredential
  = CredPat         { cVaultKey :: Text }              -- vault key → token bytes
  | CredDeployKey   { cVaultKey :: Text }              -- vault key → SSH private key bytes
  | CredMachineUser { cVaultKey :: Text, cUsername :: Text }
  deriving stock (Eq, Show)

data SourceRepo = SourceRepo
  { srId         :: RepoId          -- newtype Text, [A-Za-z0-9_-]+
  , srUrl        :: Text            -- e.g. git@github.com:owner/repo.git
  , srVcsKind    :: VcsKind
  , srCredential :: RepoCredential
  } deriving stock (Eq, Show)
```

**`RepoId` smart constructor.** Mirrors `mkSkillId` / `mkAgentDefId` /
`mkSessionId` (the established pattern):

```haskell
newtype RepoId = RepoId Text
mkRepoId :: Text -> Either Text RepoId   -- rejects empty / non-[A-Za-z0-9_-]+
repoIdText :: RepoId -> Text
```

The codec runs `mkRepoId` on decode so a hand-edited `repos.toml` with a bad id
fails load with a clear error (fail-closed). **Invariant (module comment):**
`RepoId` is never used to construct a `FilePath` — it is only a `Map` key. This
neutralizes path-traversal by construction.

**`Show` safety.** `RepoCredential`'s `Show` is derived; it contains only key
*names* and a plaintext username, so it is safe to log. The vault *values*
retrieved via `vhGet` are `ByteString` and are only ever observed inside the CPS
clone seam (`withCloneTarget`), mirroring `withApiKey`.

**JSON for the REST API.** `SourceRepo` gets a `ToJSON`/`FromJSON` that emits a
*descriptor* — `{id, url, vcs_kind, credential: {kind, vault_key, username?}}`.
The wire field names are snake_case to match the existing convention
(`skillInfoJson`/`agentInfoJson` use snake_case). There is no `ToJSON` for any
vault-value carrier.

### 4.2 Storage — `config/repos.toml` (keyed by id, mirrors `[providers.<label>]`)

A dedicated TOML file under the versioned `config/` dir (git-versioned for
audit, like `config.toml`). Shape: a **keyed-by-id** map using the *proven*
`Toml.tableMap` combinator (the same one `runtimeConfigCodec` uses for
`[providers.<label>]`). This avoids the unproven `[[repos]]` array-of-tables
codec (zero precedent in this codebase) and gives the `id` round-trip for free
from the table header. Shape:

```toml
[repos.seal-harness]
url = "git@github.com:seal-harness/seal-harness.git"
vcs_kind = "github"
credential_kind = "pat"
vault_key = "GITHUB_PAT_SEAL_HARNESS"

[repos.private-tool]
url = "git@github.com:acme/private-tool.git"
vcs_kind = "github"
credential_kind = "deploy_key"
vault_key = "GITHUB_DEPLOYKEY_PRIVATE_TOOL"

[repos.acme-infra]
url = "git@github.com:acme/infra.git"
vcs_kind = "github"
credential_kind = "machine_user"
vault_key = "GITHUB_MACHINEUSER_ACME"
username = "acme-bot"
```

Absent file → empty registry (mirrors `defaultRuntimeConfig`). Atomic save
(tmp → rename) serialized behind a **dedicated, separate** process-wide `MVar`
`repoRegistryWriteLock` (mirrors `configWriteLock` but is *not* shared with it,
to avoid serializing unrelated writes). The codec is bidirectional via
`Toml.tableMap Toml._KeyText (Toml.table repoCodec) "repos"`.

**Codec is fail-closed** on unknown `credential_kind` / `vcs_kind`, missing
`vault_key`, and `machine_user` without `username`: each is a decode `Error`,
not a silent default. Extra/unknown fields are ignored (tolmland default).

**Host binding (security).** The host is *derived from `srUrl` at registry
write time* and stored implicitly via the URL (the credential is bound to the
repo entry, and §4.4's `planClone` re-parses the URL host at clone time and
asserts it matches the credential's expected host — see §5). For the GitHub-
first pass, accepted URL hosts are restricted to a known allow-list
(`github.com`) unless a per-credential `cHost` is declared in a follow-up;
**this pass: `planClone` rejects any URL whose parsed host is not `github.com`
with `CloneHostNotSupported`**, and the REST `/api/repos` POST/PUT validation
rejects the same at write time (defense in depth).

### 4.3 Registry module — `Seal.SourceControl.Registry`

```haskell
data RepoRegistry = RepoRegistry { rrRepos :: Map RepoId SourceRepo }

loadRepoRegistry   :: FilePath -> IO (Either Text RepoRegistry)
saveRepoRegistry   :: FilePath -> RepoRegistry -> IO ()
updateRepoRegistry :: FilePath -> (RepoRegistry -> RepoRegistry) -> IO (Either Text ())
upsertRepo         :: SourceRepo -> RepoRegistry -> RepoRegistry
removeRepo         :: RepoId -> RepoRegistry -> RepoRegistry
lookupRepo         :: RepoId -> RepoRegistry -> Maybe SourceRepo
```

`updateRepoRegistry` is the load-modify-save under `repoRegistryWriteLock` —
exactly `updateRuntimeConfig`'s shape. REST handlers and the slash command both
go through it; nobody reads-writes the file directly.

**Handle for `ApiDeps`.** To match the `adAgentDefs`/`adSkills` handle shape
(and make `ApiSpec` fakes trivial), the file path is wrapped in a small handle:

```haskell
data RepoRegistryHandle = RepoRegistryHandle
  { rrhList   :: IO [SourceRepo]
  , rrhMutate :: (RepoRegistry -> RepoRegistry) -> IO (Either Text ())
  }
mkRepoRegistryHandle :: FilePath -> IO RepoRegistryHandle
```

`ApiDeps` gains **one** field: `adRepoRegistry :: RepoRegistryHandle` (not two
closures). All `ApiDeps {…}` construction sites are updated (see §7 W4 +
W0 cabal note): production wiring in `Serve.hs`/`Server.hs` and the
`ApiSpec` test scaffolding (the fake supplies `rrhList = pure []` and
`rrhMutate = \_ -> pure (Right ())`).

### 4.4 Credential injection seam — `Seal.SourceControl.Clone`

The security-sensitive module. **The token is never placed in `git clone`'s
argv or the URL.** Pure planning is separated from IO (vault access + temp
keyfile) so the pure half is unit-testable and the IO half is small and
auditable.

```haskell
data CloneError
  = CloneVaultError VaultError          -- carries VaultLocked / VaultKeyNotFound distinctly
  | CloneNoCredentialForUrl Text        -- URL has no resolvable auth path
  | CloneUnsupportedVcs VcsKind
  = CloneHostNotSupported Text          -- parsed host not in the allow-list (§5)
  | CloneGitFailed Int                  -- exit code ONLY; no stderr (§5)

-- | The resolved, ready-to-run clone. Constructors NOT exported; the only
-- observer is 'withCloneTarget'. Redacted 'Show'.
data CloneTarget

-- | CPS accessor — the authenticated bits live only inside the continuation,
-- never in a longer-lived binding (mirrors withApiKey).
withCloneTarget :: CloneTarget -> (CloneEnv -> IO r) -> IO r
data CloneEnv
  { ceUrl         :: Text            -- the TOKEN-FREE URL passed to `git clone`
  , ceGitConfigArgs :: [Text]        -- e.g. ["-c","http.extraHeader=Authorization: Basic <b64>"]
  , ceSshCommand  :: Maybe Text      -- GIT_SSH_COMMAND value (deploy key only)
  , ceEnvExtras   :: [(String, String)]
  , ceCleanup     :: IO ()           -- removes the temp keyfile (deploy key)
  }

-- Pure: classify the URL, bind the host, decide the auth strategy. No IO, no vault.
planClone :: SourceRepo -> Either CloneError ClonePlan
data ClonePlan
  = ClonePlanExtraHeader Text Text    -- token-free https url, vault key name (PAT / MachineUser)
  | ClonePlanSshKey    Text Text      -- ssh url (host-bound), vault key name (DeployKey)

-- IO: read the vault, materialize the authenticated target, return a
-- CPS-scoped CloneTarget that cleans up on exit.
resolveCloneTarget
  :: VaultHandle -> FilePath   -- ^ private state dir for the temp keyfile
  -> SourceRepo
  -> IO (Either CloneError CloneTarget)

-- Top-level: plan → resolve → run `git clone` → cleanup. Token / key bytes
-- never escape this function.
cloneRepo :: VaultHandle -> FilePath -> FilePath -> SourceRepo
          -> IO (Either CloneError ())
```

**Auth injection (pure plan, GitHub):**

- `git@github.com:owner/repo.git` with `CredPat { vaultKey }`:
  → `ClonePlanExtraHeader <https-url> vaultKey`. The https URL is
  `https://github.com/owner/repo.git` — **no token in it**. At clone time,
  `git` is invoked as:
  `git -c http.extraHeader="Authorization: Basic <base64(x-access-token:<TOKEN>)>" clone -- <https-url> <dest>`
  The token lives only in the `http.extraHeader` config arg, which is passed to
  git via the process's *config args* (not argv-as-URL, not the environment).
  **Wait — `http.extraHeader` IS passed as an argv element to `git`.** To keep
  the token fully out of argv, the header value is instead written to a
  per-clone git config file under the private state dir (0600, O_EXCL, bracket
  cleanup) and referenced via `GIT_CONFIG_GLOBAL=<file>` (an env var, which is
  visible to co-resident processes via `/proc/<pid>/environ` — see §5
  threat assessment). The strongest option is **`GIT_ASKPASS`**: a 0700 helper
  script under the private state dir that `echo`s the token to git's stdout on
  git's credential prompt. The token then appears only (a) in the helper
  script's bytes on disk (0700, private dir, bracket-deleted) and (b) on the
  pipe between the harness and `git` — never in argv, never in the URL, never
  in the environment. **Decision: use `GIT_ASKPASS` for PAT and MachineUser.**
  The clone command is:
  `git clone -- https://github.com/owner/repo.git <dest>`
  with env `GIT_ASKPASS=<helper-script> GIT_TERMINAL_PROMPT=0` and, for
  MachineUser, the helper echoes `<username>:<token>` (Basic auth) instead of
  just the token. The token-free URL means `ps`/`/proc/<pid>/cmdline` show no
  secret.

- `git@github.com:owner/repo.git` with `CredDeployKey { vaultKey }`:
  → `ClonePlanSshKey <ssh-url> vaultKey`. URL unchanged. At clone time:
  `git clone -- git@github.com:owner/repo.git <dest>` with
  `GIT_SSH_COMMAND="ssh -i <keyfile> -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=<private-known-hosts>"`.
  The keyfile path is in argv (via `GIT_SSH_COMMAND`'s env), but the *key bytes*
  are only in the 0600 keyfile. Host-key policy: `accept-new` + a managed
  `known_hosts` under the private state dir (so a MITM can't silently swap a
  host key after first-trust). Documented for a future pinning hardening.

**Deploy-key temp file location (security).** Written under the harness
private state dir, **not** the system `/tmp`:
`~/.seal/state/repos/.ssh-key-<random-suffix>` (parent `0700`, file created
with `O_EXCL` + immediate `fchmod 0600`, removed in `ceCleanup` via `bracket`).
This neutralizes symlink races and cross-user replacement. A `System.Random`
suffix prevents prediction.

**No secret in logs/transcript (committed).** `CloneGitFailed` carries **only**
the exit code — no stderr, no one-liner. Git frequently echoes the
token-bearing URL in stderr on auth failure (`fatal: Authentication failed for
https://<token>@...`); even with `GIT_ASKPASS` (token not in URL) git's stderr
can still leak metadata, and a "redacted one-liner" heuristic is fragile (URL-
encoding defeats literal substitution). **Decision: drop stderr entirely on
failure for this pass.** Full stderr is routed only to a future operator-only
structured log channel (`Seal.Logging.Logger`, post the unified-logging work)
that is provably never the session transcript. For now the operator can re-run
with `GIT_TRACE` manually if debugging is needed.

**Process runner reuse.** `cloneRepo` reuses the `Seal.Git.Repo` process-runner
pattern (`readProcessBinaryCwd`), but that runner does not accept an env
override. A small sibling `readProcessBinaryCwdEnv :: Maybe FilePath -> [(String,String)] -> FilePath -> [String] -> ByteString -> IO (ExitCode, ByteString, ByteString)` is added to `Seal.Git.Repo` so the clone seam
threads `GIT_ASKPASS`/`GIT_SSH_COMMAND`/`GIT_TERMINAL_PROMPT` without
re-implementing `withCreateProcess`. Stderr handling stays uniform.

**Vault-locked surfacing.** When `resolveCloneTarget` calls `vhGet` and the
vault is locked, `CloneVaultError VaultLocked` is returned. The slash command
and future ISA opcode map this to a distinguishable user-facing message
("vault locked — run `/vault unlock`") so the user is prompted to unlock rather
than seeing a generic clone failure. `VaultKeyNotFound` maps to
"vault key <name> not found".

### 4.5 REST API — `/api/repos` (operator-only)

Added to `Seal.Gateway.API` `apiApp`. `ApiDeps` gains `adRepoRegistry ::
RepoRegistryHandle`.

| Method | Path | Body / Result |
|---|---|---|
| GET | `/api/repos` | `[SourceRepo]` (descriptors only — no secret values by construction) |
| POST | `/api/repos` | `{id, url, vcs_kind, credential}` → **201 (idempotent upsert: an existing id is REPLACED, mirrors `/api/skills` and `/api/agents`)** |
| PUT | `/api/repos/:id` | same body → 200, or 404 if id absent. **No `new_id` rename field** (ids are stable references for the future `CLONE` opcode; rename is out of scope) |
| DELETE | `/api/repos/:id` | 204, or 404 |

**POST is idempotent upsert (201)**, aligning with `/api/skills` ("An existing
skill with the same id is REPLACED … Returns 201") and `/api/agents`. The
original 409-on-duplicate is retracted — it was an unexplained deviation from
the sibling CRUD routes.

**Validation (fail-closed):** `id` matches `^[A-Za-z0-9_-]+$` (via `mkRepoId`);
`url` is non-empty **and passes a light URL-shape check** (must match
`git@<host>:owner/repo.git` or `https://<host>/...`) so a typo is caught at
entry, not at first clone; `vcs_kind` ∈ `{git, github}`; **parsed URL host ∈
`{github.com}`** (the host allow-list, §5); `credential.kind` ∈ `{pat,
deploy_key, machine_user}` and `vault_key` is non-empty; `machine_user`
requires `username`. On success the registry file is rewritten via
`rrhMutate`, the rewrite is auto-committed to the config git repo via the
existing `gitCommitAll` seam (audit trail — `repos.toml` is in the versioned
`config/` tree), and a `broadcastReposChanged` WS frame is pushed.

**WS frame contract.** A new **`repos`** frame type (mirrors the `skills` /
`agent_defs` frame types): `{"type":"repos","repos":[<descriptor>,…]}`. The
frontend `useRepos` hook subscribes to it (with a REST `GET /api/repos` poll
fallback, mirroring `useSkills`'s pattern). This is wired in W4 (backend
broadcast) + W6 (frontend listener).

**Operator-only (§5 security).** The `/api/repos` mutators are **not** reachable
from the agent's tool plane: the agent's `WEB_FETCH`/HTTP tool allow-list
(`wcFetchAllowList`) is `UrlSafety.isSafeUrl`-gated, which **blocks loopback**
(`127.0.0.0/8`, `::1` — confirmed in `UrlSafety.isIpv4Private`/`isIpv6Private`),
so the agent cannot `curl` the gateway. `SHELL_EXEC` runs in the Untrusted
sandbox; the sandbox's network egress to loopback must be confirmed blocked (it
is, via the same `isSafeUrl` gate applied to the agent's web tools — `SHELL_EXEC`
itself is a shell, so see §5 for the residual `curl`/`ps` threat and its
mitigation). The mutators are operator tools surfaced via the web UI and the
`/repo` slash command (which is `InteractiveOnly` and dispatched on the channel
the operator is typing on, not by the agent).

**Read-side error semantics.** If `repos.toml` is corrupt, `rrhList` returns
an HTTP **500** with the tomland error text (not a silent empty list — a silent
empty list would mask a corrupt registry and let a re-POST silently overwrite
entries). `GET /api/repos` thus fails loud on corruption.

**Relationship to existing `/api/ui/repos` + `/api/sessions/:id/setup-repo`.**
The existing `/api/ui/repos` is a typed-URL **history** for the new-tab combo
box (UI recall, `addRepoHistory` in `UiState`); `/api/sessions/:id/setup-repo`
backs the combo box and delegates to the existing `cloneRepoIO`. The new
`/api/repos` is a separate **authenticated registry** (credential-backed
entries). The two are deliberately distinct: history = "URLs the operator has
typed"; registry = "URLs + credentials the harness can clone autonomously."
`SETUP_REPO`'s migration to the new seam is discussed in §4.9.

### 4.6 Slash command — `/repo`

`Seal.Command.Repo`, mirroring `Seal.Command.Skill`:

```
/repo list
/repo add <id> <url> [--vcs github|git] [--cred pat|deploy_key|machine_user]
                      [--vault-key KEY] [--username USER]
/repo remove <id>
/repo info <id>
/repo test <id>     # git ls-remote against the resolved credential (no full clone)
```

**Plain-language credential-kind help** (naming philosophy — the README mandates
descriptive terms). `/repo add --help` and the `--cred` metavar carry a
one-line plain explanation for each kind:

- `pat` — "Personal Access Token: a token stored in the vault, used to clone over HTTPS (token never appears in the URL or process list)."
- `deploy_key` — "SSH deploy key: a private key stored in the vault, used to clone over SSH."
- `machine_user` — "Bot account: a username + token stored in the vault, used to clone over HTTPS as the bot user."

`/repo list` reads the registry directly (no audit entry, like `/skill list`).
`/repo add` / `/repo remove` mutate via `rrhMutate` and echo the result via
`ccSend`. `/repo test <id>` runs `git ls-remote` against the resolved credential
(no full clone) — gives the operator a fast "credential works" signal at
registration time (use case 6). `/repo info <id>` shows id, url, vcs kind,
credential descriptor (kind + vault key name + username if any), and a
**non-blocking** "vault key <name> not found — clone will fail until it is
added" advisory if `vhList` doesn't contain the referenced key (lazy-verify
preserved, but the operator gets immediate feedback instead of a deferred
failure).

The credential *value* is never read by `add`/`info`/`list` — only the vault
key *name* is recorded. `/repo test` reads the value (via the clone seam) but
never echoes it.

`CommandGroup` gains `GroupRepos` (for `/help` grouping). `Seal.Command.Help`'s
`groupHeader` map gains `groupHeader GroupRepos = "Repos"` (else
`-Wincomplete-patterns` + `-Werror` fires — see W5).

**`/skill` vs `/repo` asymmetry (called out for contributors).** `/skill` has
`load` (dispatches an opcode) but no `add`; `/repo` has `add`/`remove`
(mutates a file directly) but no `load`. This is justified: there is no ISA
opcode for repos yet (§4.9). The shapes differ because the backing stores
differ (skills = transcript-materialized; repos = file-backed registry).

### 4.7 Frontend — `ReposView`

Mirror `SkillsView`: left list of repos (id + url + **human-readable credential
kind label**, not the raw enum), right editor (create/edit). `TopSection` gains
`'repos'`; `TopBar` gains a "Repos" button; `App.tsx` routes
`section === 'repos'` to `<ReposView />`. `useApi.ts` gains `useRepos` (WS
`repos`-frame-subscribed + REST poll fallback), `createRepo`, `updateRepo`,
`deleteRepo`. The credential form surfaces `kind` (select with the plain-
language labels from §4.6), `vault_key` (text), and `username` (text, shown
only for `machine_user`). No secret value field is ever rendered — the UI
explicitly states "Store the credential in the vault under this key name."
The list row's credential badge shows the human label
(`"Personal Access Token"`, `"SSH Deploy Key"`, `"Bot Account"`), not `pat`/
`deploy_key`/`machine_user`.

**Caller-update enumeration (TS).** `TopSection` is a closed union in
`TopBar.tsx` (`SECTION_LABELS` Record), `App.tsx` (`sectionFromPath`/
`pathFromSection` switches). All three sites must add `'repos'` together or the
TS build fails — listed in W6.

### 4.8 Paths

`Seal.Config.Paths` gains:

```haskell
reposFilePath :: SealPaths -> FilePath
reposFilePath paths = spConfig paths </> "repos.toml"

-- Private state dir for clone-time temp keyfiles + ASKPASS helpers + known_hosts.
-- Created 0700, never under /tmp, never version-controlled.
repoCloneStateDir :: SealPaths -> FilePath
repoCloneStateDir paths = spState paths </> "repos"
```

`repos.toml` is created lazily on the first write (load treats absent as empty,
like `config.toml`). `repoCloneStateDir` is created 0700 on first clone and
holds the deploy-key temp keyfiles, the `GIT_ASKPASS` helper scripts, and the
managed `known_hosts` — all bracket-cleaned per clone.

### 4.9 Relationship to the existing `SETUP_REPO` opcode

The existing `Seal.ISA.Ops.Repo.cloneRepoIO` (`SETUP_REPO`, Untrusted) clones a
bare URL in the sandbox with no credential injection and reports `CloneFailed`
with raw git stderr. **This pass does NOT migrate `SETUP_REPO` to the new seam**
— `SETUP_REPO` remains the bare-URL clone path for public repos. The new seam
(`Seal.SourceControl.Clone.cloneRepo`) is the **credential-backed** path.

**Intended end-state (out of this pass's scope, documented to avoid two
divergent clone paths):** a follow-up teaches `SETUP_REPO` to look up the
incoming URL in the `RepoRegistry` and, if present, delegate to the credential
seam (resolving the credential in the trusted plane, then handing the
token-free URL + ASKPASS env into the Untrusted sandbox). The seam is designed
so that delegation is a one-liner at the opcode boundary. A future `CLONE`
opcode (Audited) can also call `cloneRepo` directly. Until then, the two paths
coexist: `SETUP_REPO` for public repos, `/repo test` + the future `CLONE` for
private ones.

## 5. Security Considerations

This feature handles git credentials (PATs, SSH deploy keys, machine-user
tokens) — high-sensitivity. The design was threat-modeled by the security-design
reviewer; the mitigations below address every blocker they raised.

### 5.1 Threat: process-list token exposure (HIGH → mitigated)

**Threat:** placing the token in `git clone <url>`'s argv (e.g.
`https://<token>@host/...`) exposes it to any co-resident process via `ps` /
`/proc/<pid>/cmdline`. The harness's `UntrustedIO` sandbox shares the PID
namespace (it uses `ps -o pid=,cmd=` itself and `kill` — no
`unshare`/`chroot`/`pidns`), so any untrusted process the agent spawns
(`SHELL_EXEC`, a cloned repo's build script) can read the harness's own argv
and exfiltrate the token.

**Mitigation:** the token is **never** in argv or the URL.
- PAT / MachineUser: `GIT_ASKPASS=<helper-script>` (a 0700 script under
  `repoCloneStateDir`, bracket-deleted) echoes the token to git's stdout on
  git's credential prompt. `git clone -- https://github.com/owner/repo.git`
  (token-free URL). The token appears only (a) in the helper script's bytes on
  disk (0700, private dir, short-lived) and (b) on the pipe between the harness
  and git — never in argv, never in the URL, never in the environment.
- DeployKey: the *key bytes* are in a 0600 keyfile (path in `GIT_SSH_COMMAND`'s
  env, but the bytes are not in argv); the keyfile is under `repoCloneStateDir`
  (0700 parent, `O_EXCL` create, random suffix, bracket-deleted).

**Residual (accepted):** the helper-script bytes and keyfile bytes are briefly
on disk (0700, private dir). A co-resident process with the harness user's
privileges can read them — but such a process already has the user's privileges
and can read the vault's decrypted cache directly. The threat model is "no
*additional* exposure beyond what a same-user co-resident process already has";
argv/URL exposure would have been a *new* vector to *less-privileged* processes
(any process that can read `/proc/<pid>/cmdline` for the harness user, which on
some systems is broader than same-user file read). The `GIT_ASKPASS` path closes
that new vector.

**Verification:** `CloneSpec` includes a test that runs `git clone` via the seam
under a fake `ps` observer (a sibling process that reads `/proc/<pid>/cmdline`
on Linux or skips on macOS) and asserts the token does not appear in any
process's argv. (Skipped on platforms without `/proc`.)

### 5.2 Threat: credential injected into an attacker host (HIGH → mitigated)

**Threat:** the original URL-rewrite design parsed the host from `srUrl` purely
by string surgery and injected the credential into whatever host it found. A
registry entry with `url = git@evil.example.com:...` and a real GitHub PAT
would POST the PAT to `evil.example.com`.

**Mitigation (defense in depth, two layers):**
1. **Write-time validation** (`/api/repos` POST/PUT + `/repo add`): the parsed
   URL host must be in the host allow-list (`{github.com}` for this pass). A
   mismatch is rejected at registry-write time with a clear error.
2. **Clone-time assertion** (`planClone`, pure): re-parse the URL host and
   assert it is in the allow-list; return `CloneHostNotSupported` on mismatch.
   This catches a registry file hand-edited to bypass write-time validation.

Future passes can add a per-credential `cHost` field so a credential is bound to
a specific host (not just the allow-list); the type is designed to accommodate
it without a breaking change.

### 5.3 Threat: unauthenticated `/api/repos` mutators as a credential-exfiltration primitive (HIGH → mitigated)

**Threat:** `/api/repos` mutators are unauthenticated (the gateway is loopback
by default, no auth). Combined with 5.2's host-binding bug, an attacker who can
reach `127.0.0.1:<port>` could `POST {url: attacker-host, vault_key: <real
key>}` and the next clone would send a real vault token to the attacker host.
The design's original claim "no new tamper surface beyond `updateRuntimeConfig`"
was **incorrect** — this surface is strictly more dangerous because it can move
secret *values* off-box via the registry, which `updateRuntimeConfig` cannot.

**Mitigation:**
- 5.2's host allow-list removes the exfiltration destination: even if an
  attacker poisons a registry entry, the credential is only ever sent to
  `github.com`. The exfiltration primitive is closed.
- The mutators are **operator-only by surface**: the agent's `WEB_FETCH`/HTTP
  tool allow-list is `UrlSafety.isSafeUrl`-gated, which **blocks loopback**
  (`127.0.0.0/8`, `::1` — confirmed in `UrlSafety.isIpv4Private`/`isIpv6Private`),
  so the agent cannot `curl` the gateway via its web tools.
- **Residual (accepted, same as the rest of the gateway):** `SHELL_EXEC` runs a
  shell in the Untrusted sandbox, so the agent can run `curl 127.0.0.1:port` or
  `git clone` directly. This is the *existing* `SETUP_REPO` / `SHELL_EXEC` trust
  boundary, not a new one — the agent is already trusted to run shell commands,
  and the sandbox's network egress policy (which governs whether the sandbox can
  reach loopback) is the existing control. The registry does not widen that
  boundary. The host allow-list (5.2) ensures that even if the agent poisons a
  registry entry via `curl`, the credential can only reach `github.com`.
- **Audit trail:** `/api/repos` mutators auto-commit `repos.toml` to the
  config git repo via the existing `gitCommitAll` seam, so a poisoned entry
  leaves an auditable trail (who/when) in the config repo history.

### 5.4 Threat: secret in stderr/logs/transcript (MEDIUM → mitigated)

**Mitigation:** `CloneGitFailed` carries **only the exit code — no stderr**.
Git can echo the token-bearing URL in stderr on auth failure; a "redacted
one-liner" heuristic is fragile (URL-encoding defeats literal substitution).
Full stderr is routed only to a future operator-only structured log channel
(`Seal.Logging.Logger`, post the unified-logging work) that is provably never
the session transcript. For now the operator re-runs with `GIT_TRACE` manually
to debug.

`CloneTarget` is opaque with a redacted `Show`; `withCloneTarget` scopes the
authenticated bits to the clone subprocess. No `ToJSON` on any vault-value
carrier; the REST descriptor is `{kind, vault_key, username?}` by construction.

### 5.5 Threat: deploy-key temp file race / cross-user replacement (MEDIUM → mitigated)

**Mitigation:** the temp keyfile (and the `GIT_ASKPASS` helper script, and the
managed `known_hosts`) live under `repoCloneStateDir` (`~/.seal/state/repos/`,
parent `0700`, never `/tmp`). The keyfile is created with `O_EXCL` + immediate
`fchmod 0600` and a random suffix; `bracket` removes it on success or failure.
No symlink race (the parent is 0700 and not world-writable); no cross-user
replacement (only the harness user can write to the parent).

### 5.6 Threat: SSH host-key MITM on first deploy-key clone (MEDIUM → mitigated)

**Mitigation:** `GIT_SSH_COMMAND` passes
`-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=<private-known-hosts>`.
First clone trusts and pins the host key into the private `known_hosts`; later
clones fail loud if the host key changes (MITM detection). A future hardening
can pre-pin known GitHub host keys out of band.

### 5.7 Threat: TOML schema drift / unknown credential_kind (LOW → mitigated)

**Mitigation:** the codec is **fail-closed** on unknown `credential_kind` /
`vcs_kind`, missing `vault_key`, and `machine_user` without `username` — each is
a decode `Error`, not a silent default. A hand-edited `repos.toml` with a typo
fails load with a clear tomland error (and `GET /api/repos` returns 500, not a
silent empty list).

### 5.8 Threat: machine-user `username` treated as secret (LOW → documented)

`cUsername` is a **public handle** (a GitHub bot account name), not a credential.
It is stored in plaintext TOML and returned in API responses **intentionally**.
A module comment states this so a future contributor doesn't "harden" it into a
secret newtype (which would break the REST descriptor) or stop logging it. If a
deployment uses a personal username + scoped PAT, the username in the
git-versioned `config/` repo is a minor PII leak — operators can `.gitignore`
`repos.toml` if that matters (the file is still loadable; it just leaves the
versioned audit trail).

### 5.9 Standing invariants (carried from the original security contract)

- **CPS scoping.** Vault bytes are observed only inside `withCloneTarget`'s
  continuation, mirroring `withApiKey` — they cannot leak into a binding that
  outlives the clone.
- **No `ToJSON`/`FromJSON` on secret carriers.** Opaque newtypes, redacted
  `Show` (mirrors `Seal.Security.Secrets`).
- **`RepoId` never constructs a `FilePath`.** It is only a `Map` key. Path
  traversal is impossible by construction; a module comment asserts the
  invariant.
- **`IdentitiesOnly=yes`** on deploy-key ssh so the host's ssh-agent / `~/.ssh`
  identities are not offered (prevents accidental identity reuse).
- **URL-encoding** of any credential fragment that ever reaches a URL (none does
  in the `GIT_ASKPASS` design, but the helper is written defensively).

## 6. Testing Plan (TDD, `make check` gate)

**Mock infrastructure.** `VaultHandle` is already a record of `IO` actions
(`vhGet`/`vhPut`/`vhList`/`vhStatus` are plain `IO` fields), so fakes are
trivial. The test-suite already has `Seal.TestHelpers.FakeVault` (in
`other-modules`); `CloneSpec` reuses/augments it for the fake-vault harness.
`RepoRegistryHandle` is similarly a record of two `IO` actions — fakes for
`ApiSpec` are one-liners (`rrhList = pure []`, `rrhMutate = \_ -> pure (Right ())`).

**Per-spec test enumeration:**

- `Seal.SourceControl.RepoSpec` —
  - codec round-trip (all three credential kinds);
  - absent-file → empty;
  - `mkRepoId` rejection: empty, non-`[A-Za-z0-9_-]+`, path-traversal attempts (`../`, `a/b`);
  - **codec rejection edges:** unknown `credential_kind` → parse error; missing `vault_key` → parse error; `machine_user` without `username` → parse error; `vcs_kind` outside `{git,github}` → parse error; extra/unknown fields → ignored;
  - QuickCheck on `planClone`: all three kinds, host-allow-list acceptance/rejection, URL-shape validation, error paths.
- `Seal.SourceControl.RegistrySpec` —
  - load/save/upsert/remove/lookup;
  - concurrent `updateRepoRegistry` under `repoRegistryWriteLock` (no lost update — spawn N threads, assert final state is the union);
  - atomic-rename semantics (no `.tmp` left behind on exception);
  - `RepoRegistryHandle` fake wiring.
- `Seal.SourceControl.CloneSpec` —
  - `planClone` pure cases for each credential kind + each `CloneError` variant:
    - `CloneVaultError VaultLocked` (fake vault locked);
    - `CloneVaultError VaultKeyNotFound` (key absent);
    - `CloneNoCredentialForUrl` (URL with no resolvable auth path);
    - `CloneUnsupportedVcs VcsGit` (no credential injection for non-GitHub git);
    - `CloneHostNotSupported` (URL host not `github.com`);
    - `CloneGitFailed Int` (non-zero exit; **assert no stderr in the error value**);
  - **fake-`ps` argv-exposure test**: run `git clone` via the seam and assert the token does not appear in the clone subprocess's argv (Linux `/proc`; skip on macOS/CI without `/proc`);
  - **bracket-cleanup test**: fake-vault harness asserts the temp keyfile + ASKPASS helper are created `0600`/`0700` under `repoCloneStateDir` (not `/tmp`) and removed after both success and failure (inject a failing git);
  - **`git ls-remote` integration test**: against a local fixture repo, PAT path clones without host credentials (skip if `git` not on PATH);
  - **vault-locked surfacing**: assert `CloneVaultError VaultLocked` maps to a user-facing message containing "vault locked".
- `Seal.Command.RepoSpec` — parser + command-spec test harness (mirrors the existing `SkillSpec` shape); `list`/`add`/`remove`/`info`/`test` round-trips; the non-blocking "vault key not found" advisory on `/repo info`.
- `Seal.Gateway.ApiSpec` —
  - `GET/POST/PUT/DELETE /api/repos`;
  - POST idempotent-upsert (201, replaces existing id);
  - unknown-id 404 on PUT/DELETE;
  - **no secret value in any response body**: plant a known token in the fake vault, GET/POST/PUT, assert the response JSON has no field whose value matches the token;
  - host-allow-list rejection at POST/PUT;
  - corrupt `repos.toml` → GET returns 500 (not silent empty).
- Frontend `ReposView.test.tsx` — render, add, edit, remove (mirrors `SkillsView` test); **assert no secret-value field is ever rendered** (the credential form has only `kind`/`vault_key`/`username` — no value input).

## 7. Implementation Order (work units)

**RED-GREEN-REFACTOR per unit; `make check` gate after each.** Each WU starts
with a failing test (RED), implements to pass (GREEN), then cleans up
(REFACTOR). New library modules are added to `exposed-modules` and new test
specs to the test-suite `other-modules` in `seal-harness.cabal` **in the same
WU that creates them** (else `make build`/`make test` fail under `-Werror`).

### W0 — Cabal scaffolding (before W1)
- Add `Seal.SourceControl.Repo`, `.Registry`, `.Clone`, `Seal.Command.Repo` to
  `exposed-modules`; add the four `*Spec` modules to the test-suite
  `other-modules`. (The files are created empty/stub in their WU; the cabal
  edit happens alongside each WU's file creation to keep the build green at
  every commit.)
- Note: `-Wcompat`/`-Widentities`/`-Wincomplete-record-updates` are on — the
  new `ApiDeps` record fields will exercise `-Wincomplete-record-updates` at
  every construction site (see W4).

### W1 — Types + codec (`Seal.SourceControl.Repo`)
- RED: `RepoSpec` failing test (codec round-trip + `mkRepoId` rejection + a
  rejection-edge case).
- GREEN: `VcsKind`, `RepoCredential`, `SourceRepo`, `RepoId` + `mkRepoId`, the
  bidirectional `Toml.tableMap`-keyed-by-id codec (fail-closed on unknown
  kinds). Add to `exposed-modules`.
- REFACTOR: extract the URL-shape + host-allow-list pure helpers here (used by
  `planClone` and the REST/slash validation) so they're tested once.

### W2 — Paths + Registry (`Seal.Config.Paths.reposFilePath` + `repoCloneStateDir`, `Seal.SourceControl.Registry`)
- RED: `RegistrySpec` failing test (load absent → empty; upsert/remove; one
  concurrent-update assertion).
- GREEN: `reposFilePath`, `repoCloneStateDir`, `RepoRegistry`,
  `loadRepoRegistry`/`saveRepoRegistry`/`updateRepoRegistry` with the dedicated
  `repoRegistryWriteLock` `MVar`, `RepoRegistryHandle` (`rrhList`/`rrhMutate`).
  Add `Registry` to `exposed-modules`.
- REFACTOR: factor the atomic write into the existing pattern (don't duplicate
  `atomicWrite` if `Seal.Security.Vault`'s can be shared — or copy with a
  comment).

### W3 — Clone seam (`Seal.SourceControl.Clone`)
- RED: `CloneSpec` failing test (`planClone` pure cases for all three kinds +
  every `CloneError` variant; the fake-`ps` argv-exposure assertion).
- GREEN: `planClone` (pure), `resolveCloneTarget`, `withCloneTarget`,
  `cloneRepo`, `CloneError`. The `GIT_ASKPASS` helper-script writer
  (0700, `repoCloneStateDir`, bracket cleanup), the deploy-key keyfile writer
  (`O_EXCL`, `fchmod 0600`, random suffix, bracket cleanup), the env-passing
  `readProcessBinaryCwdEnv` in `Seal.Git.Repo`, the no-stderr `CloneGitFailed`.
  Add `Clone` to `exposed-modules`.
- REFACTOR: extract the `GIT_ASKPASS` script template + the helper-script
  lifecycle into a small internal module if it grows.
- **Human checkpoint: security review of the seam** (the credential-injection
  surface — confirm no secret in argv/URL/env, temp files under private dir,
  bracket cleanup, host allow-list).

### W4 — REST API (`Seal.Gateway.API` `/api/repos` + `ApiDeps` wiring + broadcast)
- RED: `ApiSpec` failing test (GET empty; POST idempotent-upsert 201; PUT 404;
  DELETE 404; no-secret-in-response assertion).
- GREEN: `ApiDeps` gains `adRepoRegistry :: RepoRegistryHandle`. **Enumerated
  construction-site updates:** production wiring in `Seal.Command.Serve.hs`
  (where `ApiDeps` is built) + the `ApiSpec` test scaffolding (the fake
  `ApiDeps` literal) — both get the new field or `-Wincomplete-record-updates`
  + `-Werror` fires. The `/api/repos` routes (GET/POST/PUT/DELETE), the
  `broadcastReposChanged` WS frame (mirrors `broadcastSkillsChanged`) + the
  `repos` frame type. Auto-commit `repos.toml` via `gitCommitAll` on mutate.
- REFACTOR: share the JSON descriptor encoding between GET/POST/PUT.

### W5 — Slash command (`Seal.Command.Repo` + `Spec` group + `Help` + `Serve` wiring)
- RED: `Seal.Command.RepoSpec` failing test (`list`/`add`/`remove`/`info`/`test`
  parse + round-trip).
- GREEN: `Command/Repo.hs`, `CommandGroup` gains `GroupRepos`,
  `Seal.Command.Help.groupHeader` gains `groupHeader GroupRepos = "Repos"` (else
  `-Wincomplete-patterns` + `-Werror`), the registry handle wired into the
  command registry in `Serve.hs`. Plain-language credential-kind help text. The
  `/repo test` `git ls-remote` path. Add `Command.Repo` to `exposed-modules`.
- REFACTOR: share the credential-kind label map between the slash command and
  the frontend (`ReposView`) — emit it from the backend as part of the
  descriptor or a small `/api/repos/kinds` endpoint (decision: a static const
  in both layers for this pass; a follow-up can serve it).

### W6 — Frontend (`ReposView.tsx`, `TopBar`, `App.tsx`, `useApi.ts`, `types.ts`)
- RED: `ReposView.test.tsx` failing test (render, add, edit, remove; no-secret-
  field assertion).
- GREEN: `ReposView.tsx`; `TopSection` gains `'repos'` (update
  `SECTION_LABELS` in `TopBar.tsx`, `sectionFromPath`/`pathFromSection` in
  `App.tsx` — all three together or the TS build fails); `App.tsx` routes
  `section === 'repos'` to `<ReposView />`; `useApi.ts` gains `useRepos`
  (WS `repos`-frame-subscribed + REST poll fallback), `createRepo`,
  `updateRepo`, `deleteRepo`; `types.ts` gains the `RepoInfo`/`RepoInput`
  types. Human-label credential badges.
- REFACTOR: share the credential-kind label const with W5's.

### W7 — `make check` gate
- Full `make check`: cabal test + hlint + `-Wall -Werror`. Fix any warnings
  introduced (unused imports, incomplete patterns). **Human checkpoint: full
  gate green before PR.**

**Dependencies:** W0 → W1 → W2 → W3 → (W4, W5 parallel) → W6 → W7.

**Breaking-change flags (caller updates):**
- `CommandGroup` enum (W5) — `Help.groupHeader` needs the new clause.
- `ApiDeps` record (W4) — every `ApiDeps {…}` literal updated (Serve.hs +
  ApiSpec).
- `TopSection` TS union (W6) — `TopBar.tsx` + `App.tsx` updated together.

## 8. Resolved Decisions (from the design-review gate)

1. **Storage codec shape** — keyed-by-id `[repos.<id>]` via the proven
   `Toml.tableMap`, not an unkeyed `[[repos]]` array-of-tables (no codebase
   precedent for array-of-tables; the keyed shape also gives `id` round-trip
   from the table header).
2. **`GroupRepos`** — added to `CommandGroup` for `/help` grouping; `Help.groupHeader`
   gets the matching clause.
3. **`/repo add` vault-key verification** — lazy at clone time (mirrors
   `wcSearchAuthKey`), but `/repo info` and `/repo test` surface a non-blocking
   "vault key not found" advisory for immediate feedback.
4. **Token injection mechanism** — `GIT_ASKPASS` (token out of argv/URL/env),
   not URL-rewrite-to-HTTPS. Closes the process-list exposure.
5. **Host binding** — write-time allow-list (`{github.com}`) + clone-time
   `CloneHostNotSupported` assertion. Closes the credential-to-attacker-host
   exfiltration.
6. **`/api/repos` mutators are operator-only** — not reachable from the agent's
   web tools (`UrlSafety` blocks loopback); the `SHELL_EXEC` residual is the
   existing trust boundary, not a new one; auto-commit to the config git repo
   for audit.
7. **`CloneGitFailed`** — exit code only, no stderr (committed).
8. **POST is idempotent upsert (201)** — mirrors `/api/skills` and `/api/agents`;
   the 409-on-duplicate is retracted.
9. **No PUT rename** — ids are stable references for the future `CLONE` opcode.
10. **`SETUP_REPO` not migrated this pass** — the new seam is the credential-
    backed path; `SETUP_REPO` remains the bare-URL public-repo path; a follow-up
    delegates.
11. **`cUsername` is a public handle, not a secret** — documented in a module
    comment.
12. **`RepoRegistryHandle`** (not two closures) for `ApiDeps` — matches the
    `adAgentDefs`/`adSkills` shape and makes `ApiSpec` fakes trivial.

## 9. Acceptance Criteria (from issue #78)

1. `config/repos.toml` round-trips via a bidirectional tomland codec (keyed by
   id); absent file → empty registry; fail-closed on unknown kinds.
2. `RepoRegistry` exposes load/save/upsert/remove/lookup with atomic writes
   under a dedicated `repoRegistryWriteLock` `MVar`.
3. Three credential kinds modeled; `resolveCloneTarget` never puts a secret in
   argv/URL/env, writes temp files only under `repoCloneStateDir` (0700 parent,
   0600/`O_EXCL` files, bracket cleanup).
4. A GitHub SSH repo with a stored PAT clones without pre-existing host
   credentials, and the token is not visible in `ps`/`/proc/<pid>/cmdline`
   (verified by the fake-`ps` argv-exposure test).
5. `GET/POST/PUT/DELETE /api/repos` (POST = idempotent upsert 201); no secret
   values in any response; host allow-list enforced at write and clone time.
6. `/repo list|add|remove|info|test` work from a chat channel; vault-locked and
   key-not-found surface distinguishable user-facing errors.
7. `ReposView` renders + supports add/edit/remove, reachable from `TopBar` as a
   new "Repos" section; no secret-value field is ever rendered.
8. `make check` passes (tests + hlint + `-Wall -Werror`); all new modules in
   `exposed-modules`/`other-modules`; `ApiDeps`/`CommandGroup`/`TopSection`
   construction sites updated.
9. No secret value serialized to transcript/logs/API response/argv.
10. User-focused (S1–S3): register-and-clone in one step; missing-key error
    names the key; credential rotation under the same name needs zero registry
    edits.