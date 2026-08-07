# Implementation Plan: Git Opcodes + SSH Agent Forwarding

**Issue**: https://github.com/seal-harness/seal-harness/issues/81
**Design**: `docs/superpowers/specs/2026-08-02-git-opcodes-agent-forwarding-design.md` (5/5 design-gate approved round 2; feasibility re-verified round 3; **rev 3** = encrypted-keyfile-on-harness-disk keygen per user decision)
**Branch**: `feat/git-opcodes-agent-forwarding` (base: `feat/source-control-repos`, PR #80 — open)
**Tooling**: cabal + Nix (`make`); tests = hspec + QuickCheck; lint = hlint; gate = `make check`; frontend = Vite + Vitest; coverage = `.coverage-thresholds.json` (`make test`; HPC pending).
**User directive**: proceed without stopping at user gates; the two scheduled checkpoints (after W2, before PR) are self-reviewed adversarially instead of pausing.

## Plan-gate iteration history

- **Iteration 1**: Feasibility FAIL (3 blockers), Completeness FAIL (1 blocker), Scope PASS. All 4 blockers traced to the codebase reality (verified by grep/read):
  1. `GIT_PUSH` audit via `runLocal` infeasible — `UntrustedOpcode.uoRun :: UntrustedIO -> Value -> App OpResult` (`Seal.ISA.Opcode.hs:85`) has NO `BackendExec`/`runLocal` in scope; `dispatch` (`Seal.ISA.Dispatch.hs:67`) discards `backend` for the Untrusted arm; `Env` does not carry `BackendExec`. **Fix (rev 2)**: the audit is written via `liftIO` inside `uoRun` to a `TwoFileHandle` param closed over at opcode construction.
  2. `Env`/`mkEnv` centralization claim false — `mkEnv` is called at 7 sites in 5 files; NONE in `Serve.hs`; the vault/registry handles live in `ChannelDeps`/`SendDeps`/`ApiDeps`. **Fix (rev 2)**: DROP the `Env` approach; thread `CloneDeps` as a closed-over param (mirrors `secretGetOp (cdVault deps)` at `Channels/Loop.hs:1094`).
  3. W4 registration sites omitted — `setupRepoOp` is wired into `baseOps` at 6 sites in 3 files. **Fix (rev 2)**: W4 file scope adds `Channels/Loop.hs`/`Gateway/Send.hs`/`Channel/Cli.hs`.
  4. `SourceRepo` positional construction site missing from W5's enumeration — `Command/Repo.hs:221`. **Fix (rev 2)**: W5 enumerates it.

- **Iteration 2**: Feasibility FAIL (3 new blockers), Completeness FAIL (2 blockers), Scope FAIL (2 blockers). All 5 blockers traced to the codebase:
  1. `TwoFileHandle` (`tHandle`) NOT in scope at any of the 6 `baseOps`/`childBaseOps` registration literals — `buildIsaRegistry` (`Loop.hs:906`, top-level, no `TwoFileHandle` param), `buildWebRegistry` (`Send.hs:494`, top-level), `cliIsaReg` (`Cli.hs:478`, let-binding BEFORE `withTwoFileTranscript` opens `tHandle` at line 552), `buildChildRegistry` (`Loop.hs:1086`/`Send.hs:868`, top-level). The rev-2 plan asserted `tHandle` was "already in scope" — fabricated. **Fix (rev 3)**: DROP the `TwoFileHandle` closed-over param on `gitPushOp` entirely. Use the EXISTING dispatcher audit mechanism: (a) the dispatcher's ACK-before-execute (`Dispatch.hs:66`, fires for ALL Untrusted opcodes) already records the invocation BEFORE the git run — this is the "records-then-runs" the design §4.3 line 399-401 cites ("the Audited dispatcher records-then-runs per `Seal.ISA.Opcode`"); (b) add a `recordGitPushResult :: TwoFileHandle -> OpName -> Value -> OpResult -> Maybe Text -> IO ()` (mirrors `recordSetupRepoResult` at `Dispatch.hs:192`), called at the 3 dispatch sites (`Send.hs:752`, `Loop.hs:899`, `Cli.hs:639`) AFTER `dispatch` returns — the `tHandle` is ALREADY in scope at these dispatch sites (they're inside `withTwoFileTranscript` brackets: `Send.hs:418/662/721`, `Loop.hs:684/876`, `Cli.hs:552/628`). The `credential_kind` is resolved inside `uoRun` and stashed in `orRecorded`; `recordGitPushResult` reads it from `orRecorded` + writes the result entry (secret-free, carrying `credential_kind` + outcome). `gitPushOp` now has the SAME signature as `gitFetchOp`/`gitPullOp` (`CloneDeps -> WorkspaceRoot -> AutonomyLevel -> Opcode`) — no arity asymmetry, no `TwoFileHandle` threading into `baseOps`. AC7 "Audited with a secret-free audit entry (carries credential_kind)" is satisfied: "Audited" = the dispatcher's pre-run ACK (Dispatch.hs:66); "secret-free audit entry carrying credential_kind" = the post-run `recordGitPushResult` entry. Design doc §4.3 line 321-330 updated to match (rev 3).
  2. `repoRegH` NOT a param of `runCliTui` (`Cli.hs:284-288`); caller `Tui.hs:176` has no registry handle. The rev-2 plan asserted `Cli` "already receives `repoRegH` at `Cli.hs:285`" — fabricated. **Fix (rev 3)**: W3 adds a `RepoRegistryHandle` param to `runCliTui`; `Tui.runTui` (`Tui.hs:72`, has `paths` in scope at line 74) constructs `mkRepoRegistryHandle (reposFilePath paths)` and passes it. `Tui.hs` ADDED to W3 file scope. (`AppMain.hs` dispatches `CommandTui` to `Seal.Tui.runTui autonomy logger` at line 42 — `runTui` builds `paths` internally, so no `AppMain` change.)
  3. `ChannelDeps`/`SendDeps` construction-site count wrong; `Cli` `baseOps` unreachable from `ChannelDeps`. **Fix (rev 3)**: W3 file scope corrected — `ChannelDeps` has 3 `newChannelDeps` call sites (`Serve.hs:158`, `Signal.Run:303`, `Telegram.Run:141`); `SendDeps` has 1 record-literal site (`Serve.hs:203`). The `cdRepoReg`/`sdRepoReg` field additions ripple to these 4 production sites + the test sites: `test/Seal/Channels/LoopSpec.hs` (8 `newChannelDeps` calls at lines 132,191,306,346,459,515,563,603), `test/Seal/Gateway/SendSpec.hs` (1 `SendDeps` literal at line 91-ish), `test/Seal/Gateway/ApiSpec.hs` (4 `SendDeps` literals at lines 2836,2925,3046,3152). All need a `fakeRepoRegistryHandle` stub (already exists at `ApiSpec.hs:211` — reuse). These 3 test files ADDED to W3 file scope.
  4. AC11 literal-text violation — AC11 (design §9:1031) literally says "`Env` gains `VaultHandle`/`RepoRegistryHandle`"; rev 2 drops it but the plan's Deviations section didn't commit to updating AC11. **Fix (rev 3)**: W6 DoD + Deviations section now explicitly commit to updating design §9 AC11 to read "`Env`/`mkEnv` UNCHANGED; the handles reach opcodes via a `CloneDeps` closed-over param (mirrors `secretGetOp (cdVault deps)`); no `SessionRuntime` field" (the constraint preserved; the vehicle corrected). Design §9 AC11 updated in W6 (the gate step, when the design doc is reconciled with the implemented reality).
  5. `SourceRepo` positional site — already fixed in rev 2; rev-2 W5 enumeration is complete (verified in iteration 2).

## The binding requirement

**No un-encrypted secret on disk, on either the trusted harness machine or the untrusted execution machine.** Encrypted-on-disk is permitted (same category as the age-encrypted vault file). The cleartext key exists only in: the vault (age-encrypted at rest) → harness process memory (`vhGet`) → ssh-agent memory (`ssh-add` decrypts the encrypted keyfile using the passphrase piped to its stdin) → signing requests over the forwarded agent socket. The untrusted machine only ever sees the forwarded `SSH_AUTH_SOCK`.

## The credential mechanism (rev 3 — encrypted keyfile on the harness disk)

**Deploy keys (preferred):**
- **Generate** (repo-create, on the harness): `ssh-keygen -t ed25519 -f <harness-keyfile-path> -N "<random-vault-passphrase>" -C "seal-deploy-key:<repo-id>"` → writes an **encrypted** (`aes256-ctr`/`bcrypt`) private key to `<harness-keyfile-path>` + a public key to `<harness-keyfile-path>.pub` under a 0700 harness-private dir (`~/.seal/state/repos/keys/`). The random passphrase is stored in the vault under `seal-deploy-key-passphrase:<repo-id>`. The encrypted keyfile stays on the harness disk (ciphertext — satisfies the rule). The public key is stored on `srDeployKeyPublic` (public data).
- **Use** (git-op, on the harness): per-op `ssh-agent` → `printf '<passphrase>\n' | SSH_ASKPASS_REQUIRE=never ssh-add <encrypted-keyfile>` (passphrase from `vhGet`, piped to `ssh-add`'s stdin — verified non-interactive) → agent decrypts the keyfile into memory → `ssh -A user@untrusted -- git ...` forwards the socket → after the op, `ssh-add -D` + kill the agent.
- **The untrusted machine never sees the keyfile** (encrypted or otherwise) — only the forwarded agent socket. The encrypted keyfile lives only on the harness disk.
- **Repo-remove cleanup**: delete the encrypted keyfile + `.pub` + the passphrase vault entry.

**PATs (fallback):** `git -c http.extraHeader='Authorization: Basic <base64(user:token)>'` in argv (memory, no file). Token-in-untrusted-memory residual (documented; deploy keys preferred).

**This eliminates the pure-Haskell OpenSSH serializer** (the biggest implementation risk from earlier plan revisions) — `ssh-keygen` produces the format, `ssh-add` consumes it. Verified: `printf '<pass>\n' | SSH_ASKPASS_REQUIRE=never ssh-add <enc-file>` works non-interactively.

## Pre-Flight Checklist (orchestrator-verified)

### Architecture
- [x] Service layer: the credential seam (`Seal.SourceControl.Clone` + `Seal.ISA.Ops.Git`) over the vault + ssh-agent + SSH executor; opcodes call it, never the vault directly. **Credential handles are passed as closed-over params to the opcode constructors (mirrors `secretGetOp (cdVault deps)` at `Channels/Loop.hs:1094`), NOT via `Env`/`mkEnv` — `Env` is untouched.**
- [x] Each WU ≤14 files: W1=3, W2=8, W3=14, W4=7, W5=11, W6=0. (W3 grew in rev 3 to cover the `ChannelDeps`/`SendDeps`/`runCliTui`/`Tui` threading + 3 test-site ripples — the rev-1/rev-2 plans under-counted this; the threading is mechanical but unavoidable. W5 is frontend-heavy; both are split-ready if they spill, but the file count is dominated by mechanical stubs + test updates.)
- [x] Error handling: `CloneError` (carried); `UntrustedErr` (existing); HTTP codes (carried); `ccSend` (carried).
- [x] No hard-coded config: paths via `Seal.Config.Paths`; pinned GitHub host keys via `file-embed` (compile-time, tamper-resistant). The `TwoFileHandle` for `GIT_PUSH` audit is a per-session transcript handle threaded from the dispatch site (already in scope where `setupRepoOp` is wired — `tHandle` at `Send.hs:742`, `tHandle` at `Loop.hs:899`, `tHandle` at `Cli.hs:639`).

### Dependency Graph
- [x] Serial: W1 → W2 → W3 → W4 → W5 → W6 (avoids PR #80's W4/W5-merge situation).
- [x] No circular deps: `ISA.Ops.Git` → `SourceControl.Clone` + `Registry` + `Tools.Ssh.Agent` + `Handles.Transcript` (for the `TwoFileHandle` audit write); `Clone` → `Vault` + `Ssh.Agent` + `GithubKeys`; `Repo` at the bottom.

### API Contract
- [x] `POST /api/repos` `{..., generate_key?: bool}` → 201 + `RepoInfo` (stable; the Generate flow calls `GET .../deploy-key` next).
- [x] `GET /api/repos/:id/deploy-key` → 200 `{public_key, setup_instructions}` | 404 | 400.
- [x] `POST /api/repos/:id/deploy-key/generate` → 200 `{public_key, setup_instructions}` (rotation; same vault key name, new encrypted keyfile overwriting the old) | 404 | 400.
- [x] `GIT_FETCH`/`GIT_PULL` `{workdir, remote?, ref?}` (Untrusted); `GIT_PUSH` `{workdir, remote?, refspec}` (Untrusted + Audited via `runLocal`).

### Security
- [x] Trust boundaries: `/api/repos` mutators operator-only (loopback + `UrlSafety`); git opcodes Untrusted (execute git on the untrusted machine via `UntrustedIO`) with credential resolution in the trusted plane via `runLocal`; the sandbox inherits only `SSH_AUTH_SOCK`/`GIT_SSH_COMMAND` env (no key bytes; the encrypted keyfile never leaves the harness).
- [x] Input validation: `mkRepoId`, URL-shape + host allow-list, `credential.kind` (carried); `CredAccountKey` codec fails-closed (W1).
- [x] Secrets: encrypted keyfile on the harness disk (ciphertext); passphrase in the vault (age-encrypted at rest); cleartext only in agent memory; `http.extraHeader` argv for PATs (memory); pinned `known_hosts` (public data).

### Completeness
- [x] All design §9 acceptance criteria (1–12) map to WU DoD items.
- [x] All design features have a WU.
- [x] No WU >8 files or >3 concerns.

## API Contract (detailed)

### POST /api/repos
- **Body**: `{id, url, vcs_kind, credential:{kind, vault_key, username?}, generate_key?: bool}`
- **Success**: `201` → `RepoInfo` (stable; no `deploy_key_public` field — the Generate flow calls `GET /api/repos/:id/deploy-key` next)
- **Errors**: `400` (validation) / `500` (corrupt registry)
- **On `generate_key: true`** (iff `credential.kind = deploy_key`): generate a random 32-byte passphrase → `vhPut vault ("seal-deploy-key-passphrase:" <> id) passphrase` → `ssh-keygen -t ed25519 -f <~/.seal/state/repos/keys/<id>> -N "<passphrase>" -C "seal-deploy-key:<id>"` → read the `.pub` → store `SourceRepo` with `CredDeployKey { cVaultKey = "seal-deploy-key-passphrase:" <> id }` + `srDeployKeyPublic = Just <pubkey>` + `srKeyfilePath = <path>`. The encrypted keyfile stays on disk (ciphertext).

### GET /api/repos/:id/deploy-key
- **Success**: `200` → `{public_key: string, setup_instructions: string}` (host-aware)
- **Errors**: `404` (id absent or not a deploy-key repo) / `400` (bad id)

### POST /api/repos/:id/deploy-key/generate
- **Success**: `200` → `{public_key, setup_instructions}` (rotation: new random passphrase → `vhPut` under the SAME vault key name; `ssh-keygen` overwrites the encrypted keyfile; new `srDeployKeyPublic` + `.pub`)
- **Errors**: `404` / `400`

### Opcodes
- `SETUP_REPO` `{url}` (Untrusted; credential resolution in the trusted plane via `liftIO` inside `uoRun` — `App = ReaderT Env (KatipContextT IO)`, so `liftIO` reaches IO; `runLocal` is NOT in `uoRun`'s scope per `Seal.ISA.Opcode.hs:85`) — unchanged input. **Constructor signature gains a `CloneDeps` param** (mirrors the existing `WorkspaceRoot`/`AutonomyLevel` closed-over params at `Repo.hs:61`); the 6 wiring sites build `CloneDeps` from their in-scope `cdVault`/`sdVault`/`rt` + `repoRegH`.
- `GIT_FETCH` `{workdir, remote?, ref?}` (Untrusted); registry-miss → error naming the origin URL.
- `GIT_PULL` `{workdir, remote?, ref?}` (Untrusted).
- `GIT_PUSH` `{workdir, remote?, refspec}` (Untrusted + Audited). **Audit mechanism (rev 3)**: NO `TwoFileHandle` closed-over param. The dispatcher's ACK-before-execute (`Dispatch.hs:66`, fires for ALL Untrusted opcodes) is the pre-run audit ("records-then-runs" per design §4.3 line 399-401). `uoRun` stashes `credential_kind` + outcome in `orRecorded`. A new `recordGitPushResult :: TwoFileHandle -> OpName -> Value -> OpResult -> Maybe Text -> IO ()` (mirrors `recordSetupRepoResult` at `Dispatch.hs:192`) is called at the 3 dispatch sites (`Send.hs:752`, `Loop.hs:899`, `Cli.hs:639`) AFTER `dispatch` returns — `tHandle` is ALREADY in scope at these sites (they're inside `withTwoFileTranscript` brackets). `recordGitPushResult` writes the result entry (secret-free, carrying `credential_kind`). `gitPushOp` has the SAME signature as `gitFetchOp`/`gitPullOp` (`CloneDeps -> WorkspaceRoot -> AutonomyLevel -> Opcode`).

## Security Considerations (input validation table)

| Endpoint/Op | Input | Validation |
|---|---|---|
| POST/PUT `/api/repos` | `id` | `mkRepoId` — `^[A-Za-z0-9_-]+$` (carried) |
| POST/PUT `/api/repos` | `url` | URL-shape + host allow-list `{github.com}` (carried) |
| POST `/api/repos` | `generate_key` | bool; iff `credential.kind = deploy_key`; `ssh-keygen -f <path> -N "<pass>"` writes the encrypted keyfile + `.pub` |
| `SETUP_REPO` | `url` | `validateRepoUrl` (carried) + `lookupRepoByUrl` (W1) |
| `GIT_FETCH/PULL/PUSH` | `workdir` | SafePath; origin URL read via the SSH executor |
| `GIT_*` | origin URL | `lookupRepoByUrl` → registry hit; miss → error naming origin URL |
| Clone (deploy key, IO) | encrypted keyfile + passphrase | `vhGet` the passphrase → `ssh-add` reads it from stdin → decrypts the on-disk encrypted keyfile into agent memory |
| Clone (PAT, IO) | git stderr | **dropped** — `CloneGitFailed Int` exit-code-only (carried) |

## Work Unit Decomposition

### W1 — URL normalization + `lookupRepoByUrl` + `CredAccountKey` codec fail-closed
**Spec**: design §4.5, §4.8. **Dependencies**: none. **Checkpoint**: no.
**DoD**:
- [ ] Move `normalizeRepoUrl` from `Seal.ISA.Ops.Repo` (line 157) to `Seal.SourceControl.Repo`; re-export from `ISA.Ops.Repo` (no import cycle — `SourceControl.Repo` doesn't import `ISA.Ops.Repo`). Both use the SAME normalizer.
- [ ] `lookupRepoByUrl :: Text -> RepoRegistry -> Maybe SourceRepo` — normalize the query + each `srUrl` via the shared `normalizeRepoUrl`, match. Pure.
- [ ] `CredAccountKey` codec fails-closed: extend `credentialCodec`/`parseCredentialKind` so `credential_kind = "account_key"` decodes to a parse error. Do NOT add the constructor (reserved). `RepoSpec` test: `account_key` decode fails.
- **RED**: `RepoSpec` failing test — `lookupRepoByUrl` finds a repo across `git@github.com:o/r.git` ↔ `https://github.com/o/r.git` ↔ `https://github.com/o/r`; `account_key` decode fails.
- **GREEN**: `lookupRepoByUrl` + shared normalizer + codec fail-closed.
- **REFACTOR**: `ISA.Ops.Repo` uses the shared `normalizeRepoUrl` (remove the local copy).
**File scope**: `src/Seal/SourceControl/Repo.hs`, `src/Seal/ISA/Ops/Repo.hs`, `test/Seal/SourceControl/RepoSpec.hs`.

### W2 — No-disk clone seam + `SshAgentHandle` + opt-in `-A` + env-override + pinned known_hosts
**Spec**: design §4.1, §4.4, §4.6, §5. **Dependencies**: W1. **Checkpoint**: **self-reviewed adversarially** (fresh security-auditor — user directive).
**DoD**:
- [ ] `Seal.Tools.Ssh.Agent` (NEW): `SshAgentHandle` record-of-IO-actions seam — `sahStart :: IO (Either Text SshAgentEnv)`, `sahAddKey :: SshAgentEnv -> FilePath -> ByteString -> IO (Either Text ())` (the `ssh-add` call: passphrase piped to stdin, encrypted keyfile path as the arg; `SSH_ASKPASS_REQUIRE=never`), `sahDeleteAll :: SshAgentEnv -> IO ()` (`ssh-add -D`), `sahKill :: SshAgentEnv -> IO ()` (`ssh-agent -k`), `sahGetAuthEnv :: SshAgentEnv -> [(String,String)]` (the `SSH_AUTH_SOCK`/`SSH_AGENT_PID` env). `mkRealSshAgentHandle` (spawns `ssh-agent -s`, parses `SSH_AUTH_SOCK`/`SSH_AGENT_PID` from its stdout, `ssh-add` with the passphrase on stdin, `ssh-add -D`, `ssh-agent -k`; `ssh-agent -t <lifetime>` for defense-in-depth); `mkFakeSshAgentHandle` (records calls in an `IORef`, no real process). `[add to exposed-modules] Seal.Tools.Ssh.Agent`.
- [ ] `Seal.SourceControl.GithubKeys` (NEW): the pinned GitHub host keys (RSA/ECDSA/Ed25519 — from `docs.github.com/.../githubs-ssh-key-fingerprints`) embedded via `file-embed` (compile-time, tamper-resistant). `pinnedGithubKnownHosts :: ByteString`. `[add to exposed-modules] Seal.SourceControl.GithubKeys`.
- [ ] `Seal.Tools.Exec.Remote`: `sshExecArgv` gains a `ForwardAgent` flag (a new `sshExecArgvForwarding` variant OR a `Bool` param — pick the variant to keep the existing `sshExecArgv` signature stable; existing callers pass `ForwardAgent False`). Git-op call sites pass `True`; `SHELL_EXEC`/`UntrustedIO` file-writes/command opcodes pass `False`. **Callers to update**: `runRemoteShell`, `runRemoteWithStdin`, the remote `uioWriteFile`/`uioPatchFile` arms, `RemoteSpec` (~13 sites).
- [ ] `Seal.Tools.Exec.UntrustedIO`: add `uioShellExecEnv :: [(String,String)] -> ShellCommand -> Maybe RemotePath -> IO (Either UntrustedErr Text)` + `uioBinExecEnv :: [(String,String)] -> BinName -> [BinArg] -> IO (Either UntrustedErr Text)`. Existing `uioShellExec`/`uioBinExec` keep signatures, delegate with `[]`. **Local arm**: extras merged over `getEnvironment` on `CreateProcess.env`. **Remote arm**: `env VAR=val ...` prefix in the command string (portable — `ssh -A` only forwards the agent socket; `SendEnv`/`SetEnv` need server `AcceptEnv` which is `none` by default).
- [ ] `RemoteRunner` recording fake (`mkFakeRemoteRunnerRecording`): extend to capture **env**. The recorded entry becomes `([(String,String)], [String], Maybe ByteString)` — env + argv + stdin. **Update all ~15 sites in `test/Seal/Tools/Exec/UntrustedIORemoteSpec.hs`** (manual sweep — `-Werror` does NOT catch tuple-pattern mismatches) + `RemoteSpec.hs`.
- [ ] `Seal.SourceControl.Clone` revised: remove `writePrivateTempFile`/`escapeSingle`/`renderAskpassHelper`/helper-script. `resolveCloneTarget` returns `CloneEnv` with: DeployKey → `ceEnvExtras = [("SSH_AUTH_SOCK", <socket>), ("GIT_SSH_COMMAND", "ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=<pinned-path> -o IdentitiesOnly=yes -o BatchMode=yes")]`; PAT → `ceGitConfigArgs = ["-c", "http.extraHeader=Authorization: Basic <base64>"]`, `ceUrl` token-free HTTPS. `CloneDeps = CloneDeps { cdVault :: VaultHandle, cdSshAgent :: SshAgentHandle, cdPinnedKnownHosts :: ByteString, cdKeyfilesDir :: FilePath }`. Per-op agent lifecycle: `withCloneTarget` bracket (start → `sahAddKey <enc-keyfile> <passphrase>` → run → `sahDeleteAll` + `sahKill`). `cloneRepo`/`lsRemoteRepo` take `CloneDeps`. **Pinned `known_hosts` placement**: write per-op to `<workdir>/.seal-known-hosts` via the SSH executor's stdin-pipe file-write (public data, 0644, cleaned up after the op) — simpler than `@cert-authority`; the no-disk test asserts no SECRET lands there.
- [ ] **No-disk test** (`CloneSpec`): snapshot `~/.seal/` + the untrusted workdir before; run `cloneRepo` (deploy key) + `cloneRepo` (PAT); snapshot after; assert no UN-ENCRYPTED secret appears — the encrypted keyfile under `~/.seal/state/repos/keys/` IS permitted (ciphertext); the `<workdir>/.seal-known-hosts` is public data. Assert the deploy-key path uses `SSH_AUTH_SOCK` env (the encrypted keyfile path is NOT in the untrusted env — only on the harness); PAT uses `http.extraHeader` argv.
- [ ] **Per-op scoping test** (`CloneSpec`): two sequential `cloneRepo` calls for different repos; assert via the fake `SshAgentHandle` that each op does exactly one `sahAddKey` + `sahDeleteAll` + `sahKill` — never two keys live at once.
- [ ] **`-A` invariant test** (`RemoteSpec`): non-credentialed remote ops' argv contains no `-A`; git-credential ops' argv contains `-A`.
- **RED**: `CloneSpec` no-disk + per-op-scoping; `RemoteSpec` `-A` invariant.
- **GREEN**: the seam + `SshAgentHandle` + `GithubKeys` + opt-in `-A` + env-override + recording-fake env capture.
- **REFACTOR**: remove now-unused imports (`escapeSingle`/`writePrivateTempFile`); `CloneDeps` for stable arity.
- **Self-reviewed checkpoint**: fresh `security-auditor-agent` review of W2. Proceed on PASS; fix on FAIL.
**File scope**: `src/Seal/SourceControl/Clone.hs`, `src/Seal/SourceControl/GithubKeys.hs` (new), `src/Seal/Tools/Ssh/Agent.hs` (new), `src/Seal/Tools/Exec/Remote.hs`, `src/Seal/Tools/Exec/UntrustedIO.hs`, `test/Seal/SourceControl/CloneSpec.hs`, `test/Seal/Tools/Exec/RemoteSpec.hs`, `test/Seal/Tools/Exec/UntrustedIORemoteSpec.hs` (the ~15 recording-fake sites).

### W3 — `SETUP_REPO` revision + `CloneDeps` param + caller updates
**Spec**: design §4.2, §4.3 (rev 3: `CloneDeps` closed-over param, NOT `Env` fields — the codebase proved `Env`/`mkEnv` is the wrong vehicle; `Tui.hs` + test ripples added). **Dependencies**: W2. **Checkpoint**: no.
**DoD**:
- [ ] **NO `Env`/`mkEnv` change.** The `VaultRuntime` (which yields `VaultHandle` via `withHandle`/`vrHandleRef`) + `RepoRegistryHandle` are passed as a `CloneDeps` record to `setupRepoOp` as a closed-over param (mirrors the existing `secretGetOp (cdVault deps)` pattern at `Channels/Loop.hs:1094` and `setupRepoOp wsRoot autonomy` at `Repo.hs:61`). `CloneDeps = CloneDeps { cdVault :: VaultRuntime, cdRepoReg :: RepoRegistryHandle, cdSshAgent :: SshAgentHandle, cdPinnedKnownHosts :: ByteString, cdKeyfilesDir :: FilePath }` (carried from W2; `Clone` already takes it).
- [ ] `Seal.ISA.Ops.Repo.setupRepoOp` revised: signature `setupRepoOp :: CloneDeps -> WorkspaceRoot -> AutonomyLevel -> Opcode`. `uoRun` does `lookupRepoByUrl` (W1) → credential path (resolve via the no-disk seam using `cdVault`/`cdSshAgent`; run `git clone` in the sandbox via `uioShellExecEnv` with `SSH_AUTH_SOCK` + `GIT_SSH_COMMAND` env for deploy keys, or `uioBinExecEnv` with `http.extraHeader` argv for PATs) → bare-URL fallthrough (public repos, backward-compat). Stays Untrusted; credential resolution via `liftIO` in the trusted plane. NO `runLocal`/`BackendExec`.
- [ ] **Update the 6 `setupRepoOp` call sites** (corrected count): `Channels/Loop.hs:946,1112`; `Gateway/Send.hs:534,894`; `Channel/Cli.hs:426,505` — each builds `CloneDeps` from its in-scope `cdVault` (`ChannelDeps`)/`sdVault` (`SendDeps`)/`rt` (`Cli`). **The `Cli` sites need `repoRegH` in scope — see the `runCliTui` signature change below.**
- [ ] **Thread `RepoRegistryHandle` to the `Cli` `baseOps` sites** (rev 3 — the rev-2 plan wrongly asserted `Cli` already had it):
  - Add a `cdRepoReg :: RepoRegistryHandle` field to `ChannelDeps` (`Channels/Loop.hs:169`) + thread it through `newChannelDeps` (`Channels/Loop.hs:211-219`); update the **3 production `newChannelDeps` call sites**: `Serve.hs:158`, `Signal.Run:303`, `Telegram.Run:141` (each already constructs `repoRegH` or can: `Serve.hs:118` already builds it; `Signal.Run`/`Telegram.Run` have `paths` in scope → `mkRepoRegistryHandle (reposFilePath paths)`).
  - Add a `sdRepoReg :: RepoRegistryHandle` field to `SendDeps` (`Gateway/Send.hs:~130`); update the **1 production `SendDeps` record-literal site**: `Serve.hs:203` (`repoRegH` already in scope at `Serve.hs:118`).
  - **`runCliTui` signature change** (`Channel/Cli.hs:284-288`): add a `RepoRegistryHandle` param. The sole caller `Seal.Tui.runTui` (`Tui.hs:72`, has `paths` in scope at line 74) constructs `mkRepoRegistryHandle (reposFilePath paths)` and passes it. **`Tui.hs` is ADDED to W3 file scope** (rev 3 — the rev-2 plan omitted it). `AppMain.hs` dispatches `CommandTui` to `Seal.Tui.runTui autonomy logger` (`AppMain.hs:42`); `runTui` builds `paths` internally, so NO `AppMain` change.
  - **Test-site ripples** (rev 3 — the rev-2 plan omitted them): `test/Seal/Channels/LoopSpec.hs` (8 `newChannelDeps` calls at lines 132,191,306,346,459,515,563,603), `test/Seal/Gateway/SendSpec.hs` (1 `SendDeps` literal ~line 91), `test/Seal/Gateway/ApiSpec.hs` (4 `SendDeps` literals at lines 2836,2925,3046,3152). Each needs a `fakeRepoRegistryHandle` stub (already exists at `ApiSpec.hs:211` — reuse it / factor to a shared helper). These 3 test files ADDED to W3 file scope.
- [ ] Update the `cloneRepoIO` callers: `Seal.Gateway.API` (the setup-repo combo box), `Seal.Command.Repo` (`/repo test`) — each builds `CloneDeps` (or the test stubs it).
- [ ] `RepoSpec` (the ISA.Ops.Repo one) revised: registered deploy-key repo clones via the forwarded fake agent (fake `SshAgentHandle` + fake `RemoteRunner` + fake `RepoRegistryHandle`); registered PAT via `http.extraHeader` argv; unregistered URL falls through.
- **RED**: `RepoSpec` failing test — registered deploy-key repo clones via the forwarded fake agent; PAT via `http.extraHeader`; unregistered falls through.
- **GREEN**: the revision + `CloneDeps` param + 6 caller updates + `ChannelDeps`/`SendDeps`/`runCliTui`/`Tui` threading + 3 test-site stubs.
- **REFACTOR**: share a `CloneDeps`-building helper across the 6 callers + the `cloneRepoIO` callers; factor `fakeRepoRegistryHandle` to a shared test helper.
**File scope**: `src/Seal/ISA/Ops/Repo.hs`, `src/Seal/Channels/Loop.hs` (`ChannelDeps` field + `newChannelDeps` sig + 2 call-site edits), `src/Seal/Gateway/Send.hs` (`SendDeps` field + 2 call-site edits), `src/Seal/Channel/Cli.hs` (`runCliTui` sig + 2 call-site edits), `src/Seal/Tui.hs` (construct `repoRegH` + pass to `runCliTui`), `src/Seal/Command/Serve.hs` (thread `repoRegH` into `ChannelDeps`/`SendDeps` construction at lines 158,203), `src/Seal/Channels/Signal/Run.hs` (`newChannelDeps` call at 303), `src/Seal/Channels/Telegram/Run.hs` (`newChannelDeps` call at 141), `src/Seal/Gateway/API.hs` (setup-repo handler), `src/Seal/Command/Repo.hs` (`/repo test`), `test/Seal/ISA/Ops/RepoSpec.hs`, `test/Seal/Channels/LoopSpec.hs` (8 `newChannelDeps` stubs), `test/Seal/Gateway/SendSpec.hs` (`SendDeps` stub), `test/Seal/Gateway/ApiSpec.hs` (4 `SendDeps` stubs). (14 files; the threading ripple is mechanical but unavoidable — the rev-1/rev-2 plans under-counted it.)

### W4 — `GIT_FETCH`/`GIT_PULL`/`GIT_PUSH` opcodes
**Spec**: design §4.2, §4.3 (rev 3: audit via dispatcher ACK + `recordGitPushResult` at dispatch sites, NOT `runLocal`/`TwoFileHandle` closed-over param; registration in `baseOps` at the 3 channel files). **Dependencies**: W2, W3. **Checkpoint**: no.
**DoD**:
- [ ] `Seal.ISA.Ops.Git` (NEW): `gitFetchOp`/`gitPullOp`/`gitPushOp` — all **Untrusted** (they execute git on the untrusted machine via `UntrustedIO`; a Trusted opcode has no `UntrustedIO` in scope per `Seal.ISA.Opcode`). **Constructor signatures** (uniform — no `TwoFileHandle` asymmetry in rev 3): `gitFetchOp :: CloneDeps -> WorkspaceRoot -> AutonomyLevel -> Opcode`, `gitPullOp :: CloneDeps -> WorkspaceRoot -> AutonomyLevel -> Opcode`, `gitPushOp :: CloneDeps -> WorkspaceRoot -> AutonomyLevel -> Opcode`. Each opcode: resolve the workdir's origin URL via the SSH executor (`git -C <workdir> config --get remote.origin.url` — the single no-trust-the-sandbox path); `lookupRepoByUrl` → registry hit → resolve credential (from `CloneDeps`) → run `git -C <workdir> fetch/pull/push <refspec>` via `uioShellExecEnv`/`uioBinExecEnv` with the forwarded agent (deploy key) or `http.extraHeader` argv (PAT). Registry miss → error naming the origin URL. Vault-locked → distinguishable. **`GIT_PUSH` audit** (rev 3 — NO `TwoFileHandle` closed-over param): `uoRun` stashes `credential_kind` + outcome in `orRecorded` (secret-free). The dispatcher's existing ACK-before-execute (`Dispatch.hs:66`, fires for ALL Untrusted opcodes) is the pre-run audit ("records-then-runs"). A new `recordGitPushResult :: TwoFileHandle -> OpName -> Value -> OpResult -> Maybe Text -> IO ()` (mirrors `recordSetupRepoResult` at `Dispatch.hs:192` — add to `Seal.ISA.Dispatch` exports) is called at the 3 dispatch sites AFTER `dispatch` returns: `Gateway/Send.hs:752`, `Channels/Loop.hs:899`, `Channel/Cli.hs:639` — `tHandle` is ALREADY in scope at these sites (inside `withTwoFileTranscript` brackets). `recordGitPushResult` reads `credential_kind` from `orRecorded` + writes the result entry (secret-free, carrying `credential_kind` + outcome). NOT via `runLocal`/`BackendExec` (not in `uoRun`'s scope). `[add to exposed-modules] Seal.ISA.Ops.Git`.
- [ ] **Register the opcodes in the `baseOps` list at the 3 channel files** (6 sites total — mirrors `setupRepoOp`'s registration): `src/Seal/Channels/Loop.hs` (`baseOps` at line 921 + `childBaseOps` at line 1091), `src/Seal/Gateway/Send.hs` (`baseOps` at line 509 + `buildChildRegistry` at ~874), `src/Seal/Channel/Cli.hs` (`baseOps` at line 480 + line ~500). Each builds `CloneDeps` from `cdVault`/`sdVault`/`rt` + `cdRepoReg`/`sdRepoReg`/`repoRegH` (W3 threads these). NO `TwoFileHandle` needed at the registration literals (rev 3 — the audit recorder is called at the dispatch site, not closed over the opcode). `Seal.ISA.Ops.Registry.hs` is NOT the registration list — do NOT edit it.
- [ ] **Add `recordGitPushResult` to `Seal.ISA.Dispatch`** (mirrors `recordSetupRepoResult`): a new exported function that writes an `EKHarness` result entry carrying `op.name` + `input` + `result.orRecorded` (which includes `credential_kind`) to the `TwoFileHandle`. Called at the 3 dispatch sites after a successful `GIT_PUSH` `dispatch` (branch on `opNm == "GIT_PUSH"` alongside the existing `SETUP_REPO`/`SKILL_LOAD` branches at `Send.hs:751-753`).
- [ ] `GitSpec` (NEW): happy path (registered repo, one opcode call → success, no retry); registry miss → error naming origin URL; vault-locked → distinguishable; `GIT_PUSH` audit recorded secret-free + carries `credential_kind` (assert via a fake `TwoFileHandle` that records writes, OR via asserting `orRecorded` contains `credential_kind` since `recordGitPushResult` is called at the dispatch site which the unit test can stub); per-op scoping (one add/delete/kill per op via the fake `SshAgentHandle`). `[add to other-modules] Seal.ISA.Ops.GitSpec`.
- [ ] `test/Main.hs`: wire `GitSpec`.
- **RED**: `GitSpec` failing tests.
- **GREEN**: the opcodes + 6-site registration + `recordGitPushResult` + 3 dispatch-site calls.
- **REFACTOR**: share the credential-resolution helper with `SETUP_REPO` (W3).
**File scope**: `src/Seal/ISA/Ops/Git.hs` (new), `src/Seal/ISA/Dispatch.hs` (`recordGitPushResult`), `src/Seal/Channels/Loop.hs` (registration, 2 sites + 1 dispatch-site recorder call at 899), `src/Seal/Gateway/Send.hs` (registration, 2 sites + 1 dispatch-site recorder call at 752), `src/Seal/Channel/Cli.hs` (registration, 2 sites + 1 dispatch-site recorder call at 639), `test/Seal/ISA/Ops/GitSpec.hs` (new), `test/Main.hs`. (7 files.)

### W5 — Deploy-key generation endpoints + frontend
**Spec**: design §4.7, §5.7. **Dependencies**: W4. **Checkpoint**: no.
**DoD**:
- [ ] `Seal.Config.Paths`: add `repoKeysDir :: SealPaths -> FilePath` (`spState </> "repos" </> "keys"`, 0700 parent).
- [ ] `Seal.SourceControl.Repo`: add `srDeployKeyPublic :: Maybe Text` + `srKeyfilePath :: Maybe FilePath` to `SourceRepo` + the codec (optional fields; `Nothing` for non-deploy-key repos). Update `ToJSON`/`FromJSON`. **Note: `SourceRepo` positional/record construction (the codec's `SourceRepo srId <$> ...` at `Repo.hs:161` + `FromJSON` at `Repo.hs:382`, AND the `validateAdd` `Right SourceRepo {...}` at `Command/Repo.hs:221`) is NOT caught by `-Wincomplete-record-updates` — a manual grep for `SourceRepo` construction sites is required.** Enumerated sites (verified via grep `rg -n "SourceRepo\s+" src/ test/`): `Repo.hs:161` (codec, positional `SourceRepo srId <$> ...`), `Repo.hs:382` (FromJSON, `SourceRepo i url vk <$> ...`), `Command/Repo.hs:221` (`validateAdd`, `Right SourceRepo { srId, srUrl, srVcsKind, srCredential }` — record construction, breaks arity), `Gateway/API.hs:1246` (record-pattern binding `SourceRepo { srId = rid, ... }` — safe, no arity break, but the field is absent from the pattern; decide whether to add the new fields to the pattern or use record-update). Test files: `RegistrySpec.hs:26`, `CloneSpec.hs` (21 sites), `RepoSpec.hs:29,383`, `Command/RepoSpec.hs:38,49`. ALL enumerated sites get updated in W5.
- [ ] `Seal.Gateway.API`: `POST /api/repos` handles `generate_key: true` — generate a random 32-byte passphrase (base64) → `vhPut vault ("seal-deploy-key-passphrase:" <> id) passphrase` → `ssh-keygen -t ed25519 -f <repoKeysDir </> id> -N "<passphrase>" -C "seal-deploy-key:<id>"` (writes the encrypted keyfile + `.pub` to the harness disk; 0600/0644) → read the `.pub` → store `SourceRepo` with `CredDeployKey { cVaultKey = "seal-deploy-key-passphrase:" <> id }` + `srDeployKeyPublic = Just <pubkey>` + `srKeyfilePath = Just <path>`. `GET /api/repos/:id/deploy-key` → `{public_key, setup_instructions}` (host-aware: github template + generic fallback interpolating `<url>` + `<host>`). `POST /api/repos/:id/deploy-key/generate` → rotation (new passphrase → `vhPut` under the SAME vault key name; `ssh-keygen` overwrites the encrypted keyfile; new `srDeployKeyPublic` + `.pub`). **`DELETE /api/repos/:id`**: if the repo has a `srKeyfilePath`, delete the encrypted keyfile + `.pub` + `vhDelete` the passphrase.
- [ ] `Seal.Command.Repo`: add a faint PAT advisory to the `/repo add --cred pat`/`machine_user` help text.
- [ ] Frontend `ReposView.tsx`: the Generate flow — selecting `deploy_key` defaults to Generate; `vault_key` auto-fills + disables; after `POST` 201, `GET .../deploy-key` → render the public key `<pre>` + Copy button + host-aware instructions. Rotation button on deploy-key rows. The faint PAT advisory next to `pat`/`machine_user`.
- [ ] `useApi.ts`: `fetchRepoDeployKey`, `regenerateDeployKey`. `types.ts`: `RepoInfo` gains `deploy_key_public?` (optional); `DeployKeyInfo { public_key, setup_instructions }`.
- [ ] `ApiSpec`: `generate_key: true` returns `RepoInfo` (stable); `/deploy-key` returns public key + instructions; rotate returns new public key; no private key in any response; the encrypted keyfile exists on the harness disk (ciphertext) + is deleted on repo-remove; no passphrase in any response.
- [ ] `ReposView.test.tsx`: the Generate flow renders the public key + Copy + instructions; private key never rendered (no field for it); the disabled `vault_key` value is submitted (React-controlled-state assertion); PAT advisory present.
- **RED**: `ApiSpec` + `ReposView.test.tsx` failing tests.
- **GREEN**: the endpoints + `SourceRepo` fields + frontend + repo-remove cleanup.
- **REFACTOR**: share the `ssh-keygen` invocation helper.
**File scope**: `src/Seal/Config/Paths.hs`, `src/Seal/SourceControl/Repo.hs`, `src/Seal/Gateway/API.hs`, `src/Seal/Command/Repo.hs`, `test/Seal/Gateway/ApiSpec.hs`, `test/Seal/SourceControl/RepoSpec.hs`, `frontend/src/components/ReposView.tsx`, `frontend/src/hooks/useApi.ts`, `frontend/src/types.ts`, `frontend/src/components/__tests__/ReposView.test.tsx`, `frontend/src/hooks/__tests__/useApi.test.ts`.

### W6 — `make check` gate + final review
**Spec**: design §7 W6. **Dependencies**: W1–W5. **Checkpoint**: **self-reviewed adversarially** (fresh code-review of the full diff before PR — user directive).
**DoD**:
- [ ] `make check` (build + test + lint) green.
- [ ] `npm run build` + `npm test` + `tsc --noEmit` green.
- [ ] Cross-unit: API contract consistent (W5 backend `RepoInfo` ↔ frontend `RepoInfo`); the `SourceRepo` field additions don't break W1–W4; no conflicting imports; no leftover TODO/FIXME; `Env`/`mkEnv` untouched (the `CloneDeps`-param pattern holds across W3/W4); the `GIT_PUSH` audit uses the dispatcher ACK + `recordGitPushResult` (not `runLocal`/`TwoFileHandle` closed-over param). **Design doc reconciliation**: update §4.2 line 321-330 (audit mechanism), §4.2 line 339-350 (CloneDeps not Env), §4.3 line 399-401 (dispatcher records-then-runs), handoff §6 #5 + #7, and §9 AC11 (the `Env` literal text → `CloneDeps` vehicle) to match the implemented rev-3 reality.
- [ ] Full `git diff main..HEAD` + `git log` review.
- [ ] `.coverage-thresholds.json` `make test` run (HPC pending — command runs the suite).
- [ ] **Self-reviewed checkpoint**: fresh `code-review-agent` of the full diff (the no-un-encrypted-secret-on-disk invariant across all WUs; the per-op scoping; the `-A` opt-in; the pinned host keys; the no-secret-in-API; the encrypted-keyfile lifecycle). Proceed on PASS; fix on FAIL.
- [ ] **End-to-end (issue #81 AC12)**: a registered `git@github.com:seal-harness/seal-harness.git` clones via `SETUP_REPO` first-try. (A test against a local fixture or a documented manual verification.)
- [ ] Final report + self-reflect + PR.
**File scope**: none (verification; fix-up commits to in-scope files if needed).

## Constructed Dependency DAG

```
W1 (URL norm) ──→ W2 (no-disk seam + SshAgent + -A + env-override + pinned keys) ──→ W3 (SETUP_REPO + Env fields + callers) ──→ W4 (GIT_FETCH/PULL/PUSH) ──→ W5 (gen + frontend) ──→ W6 (gate)
```

Serial (avoids PR #80's W4/W5-merge situation).

## Established Patterns (for coder subagents)

- **Encrypted keyfile on the harness disk** (W5): `ssh-keygen -f <path> -N "<vault-passphrase>"` writes the encrypted keyfile (ciphertext) + `.pub`; the passphrase lives in the vault; `ssh-add` decrypts at git-op time using the passphrase piped to its stdin. The encrypted keyfile is a per-repo artifact (create on register, overwrite on rotate, delete on remove).
- **Per-op ssh-agent lifecycle** (W2): start → `sahAddKey <enc-keyfile> <passphrase>` (passphrase on stdin) → run → `sahDeleteAll` + `sahKill`, via `bracket`. Exactly one identity live at forwarding time (the security-critical scoping).
- **`SshAgentHandle` record-of-IO-actions** (W2): real + fake (mirrors `RemoteRunner`/`VaultHandle`); unit-test-speed, no `ssh-agent` spawning.
- **Opt-in `-A`** (W2): a `ForwardAgent` flag on `sshExecArgv`; only git-credential ops pass `True`.
- **`normalizeRepoUrl` shared** (W1): one normalizer, used by both `ISA.Ops.Repo` and `lookupRepoByUrl`.
- **`file-embed` pinned keys** (W2): compile-time, tamper-resistant, public data.
- **`CloneDeps` record as closed-over opcode param** (W2/W3/W4): stable arity for `cloneRepo`/`lsRemoteRepo`/`setupRepoOp`/`gitFetchOp`/`gitPushOp`/etc.; carries `VaultRuntime` + `RepoRegistryHandle` + `SshAgentHandle` + pinned keys + keyfiles dir. **Passed as a param to the opcode constructor (mirrors `secretGetOp (cdVault deps)` at `Channels/Loop.hs:1094`), NOT via `Env`/`mkEnv`.** `Env`/`mkEnv` stay untouched. This deviates from handoff §6 #7 ("`Env` gains `VaultHandle`/`RepoRegistryHandle`") — the codebase proved `Env` is the wrong vehicle (`mkEnv` has 7 call sites in 5 files, none with handle access; the handles live in `ChannelDeps`/`SendDeps`/`ApiDeps`). Design doc §4.2 + handoff §6 #7 + design §9 AC11 updated to match (rev 3, in W6).
- **Git opcodes are Untrusted** (W4): they execute git on the untrusted machine via `UntrustedIO`. **`GIT_PUSH` audit via the existing dispatcher ACK-before-execute + a `recordGitPushResult` at the dispatch sites** (rev 3) — NOT via `runLocal`/`BackendExec` (not in `uoRun`'s scope per `Opcode.hs:85`+`Dispatch.hs:67`) and NOT via a `TwoFileHandle` closed-over param (rev 2's approach was infeasible — `tHandle` is not in scope at the `baseOps` registration literals). `uoRun` stashes `credential_kind`+outcome in `orRecorded`; the dispatcher's pre-run ACK (`Dispatch.hs:66`) is the "records-then-runs"; `recordGitPushResult` (mirrors `recordSetupRepoResult` at `Dispatch.hs:192`) is called at the 3 dispatch sites (`Send.hs:752`/`Loop.hs:899`/`Cli.hs:639`) where `tHandle` IS in scope. This preserves the §6 #5 intent (per-opcode audit, trusted-plane, before the untrusted git run, not a new constructor) with the minimal codebase-fitting mechanism. Design doc §4.2 + handoff §6 #5 updated to match (rev 3).
- **Registration in `baseOps`** (W4): the new `GIT_*` opcodes are added to the `baseOps` list literal in `Channels/Loop.hs`/`Gateway/Send.hs`/`Channel/Cli.hs` (6 sites), mirroring `setupRepoOp`. `Seal.ISA.Ops.Registry.hs` is NOT the registration list.

## Deviations from handoff §6 "Key Decisions & Rationale (do not undo)" (rev 3 — codebase-driven)

- **§6 #5** ("`GIT_PUSH`'s audit is written via `runLocal` before the untrusted git run (per-opcode audit, not a new constructor)"): the *intent* (per-opcode audit, trusted-plane, records-then-runs, not a new constructor) is preserved. The *mechanism* is corrected from `runLocal` to (a) the existing dispatcher ACK-before-execute (`Dispatch.hs:66`, fires for all Untrusted opcodes — this IS the "records-then-runs" the design §4.3 cites) + (b) a new `recordGitPushResult` (mirrors `recordSetupRepoResult`) called at the 3 dispatch sites after the run, carrying `credential_kind` from `orRecorded`. Rev 2 tried a `TwoFileHandle` closed-over param, but iteration-2 review proved `tHandle` is NOT in scope at any of the 6 `baseOps` registration literals (`buildIsaRegistry`/`buildWebRegistry`/`cliIsaReg`/`buildChildRegistry` are top-level/let functions with no `TwoFileHandle` param). Rev 3's dispatcher+recorder approach needs NO threading into `baseOps`. Design doc §4.2 line 321-330 + §4.3 line 399-401 updated in W6.
- **§6 #7** ("`Env` gains `VaultHandle`+`RepoRegistryHandle` (centralized in `mkEnv`); ... no `SessionRuntime` field"): the *constraint* (no `SessionRuntime` field) is preserved. The *vehicle* is corrected from `Env`/`mkEnv` to a `CloneDeps` closed-over opcode param because `mkEnv` has 7 call sites in 5 files, none with handle access, and the handles already live in `ChannelDeps`/`SendDeps`/`ApiDeps`. The per-opcode-param pattern is already established (`secretGetOp (cdVault deps)` at `Channels/Loop.hs:1094`). `Env`/`mkEnv` stay untouched. **Design §9 AC11 updated in W6** to read "`Env`/`mkEnv` UNCHANGED; the handles reach opcodes via a `CloneDeps` closed-over param; no `SessionRuntime` field" (the constraint preserved; the vehicle corrected). Design doc §4.2 line 339-350 updated in W6.

## Project Context (initial — written to `.beads/context/project-context.md` at execution start)

Carries: tooling (cabal/Nix/hspec/hlint; Vite/Vitest), the completed-WU table, and the security invariants (no un-encrypted secret on disk; per-op scoping; opt-in `-A`; pinned host keys; encrypted keyfile on harness disk only).

## Human Checkpoints (self-reviewed per user directive)

1. **After W2** — fresh `security-auditor-agent` review of the no-disk seam + per-op scoping + opt-in `-A` + pinned host keys + `known_hosts` placement + the encrypted-keyfile approach. Proceed on PASS; fix on FAIL.
2. **After W6 (before PR)** — fresh `code-review-agent` review of the full diff. Proceed on PASS; fix on FAIL.