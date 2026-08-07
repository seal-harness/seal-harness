# Implementation Plan: Source Control Repo Registry + Credential-Backed Cloning

**Issue**: https://github.com/seal-harness/seal-harness/issues/78
**Design**: `docs/superpowers/specs/2026-08-02-source-control-repo-registry-design.md` (5/5 design-gate approved, round 2)
**Branch**: `feat/source-control-repos`
**Tooling**: cabal + Nix dev shell (`make` recipes); tests = hspec + QuickCheck; lint = hlint; gate = `make check` (build + test + lint); frontend = Vite + Vitest; coverage enforcement = `.coverage-thresholds.json` (command `make test`; HPC instrumentation pending per AGENTS.md).

## Pre-Flight Checklist (orchestrator-verified)

### Architecture
- [x] Every data access through a service layer: `RepoRegistryHandle` (`rrhList`/`rrhMutate`) is the service layer over `config/repos.toml`; REST + slash command both go through it — no direct file reads from routes/handlers.
- [x] Each WU single responsibility, ≤5 files: W1=2, W2=3, W3=2+1(Git.Repo edit), W4=2, W5=3, W6=5, W0=1, W7=0.
- [x] Error handling: typed `CloneError` hierarchy (5 variants); `Either Text` at the registry/codec boundary; HTTP status codes (400/404/500) at the REST boundary; `ccSend`-echoed errors at the slash boundary.
- [x] No hard-coded config: paths via `Seal.Config.Paths`; vault keys are user-supplied names; host allow-list is a single const (`githubHosts = ["github.com"]`) in `Seal.SourceControl.Repo` (documented as the GitHub-first restriction).

### Dependency Graph
- [x] Minimal deps: W1 depends on nothing; W2 depends on W1 (types) + Paths; W3 depends on W2 + Vault + Git.Repo; W4 depends on W2 + API + Broadcast; W5 depends on W4 (both edit `Serve.hs` — serialized, not parallel); W6 depends on W4 (API contract); W7 depends on all.
- [x] Parallelizable: W6's frontend work is independent of W5's slash command once W4 lands. W4→W5 are serialized (shared `Serve.hs`).
- [x] No circular deps.
- [x] Integration WUs: W4 wires REST into the app shell (Serve.hs `ApiDeps`); W5 wires the slash command into the registry (Serve.hs command list); W6 wires `ReposView` into the SPA shell (TopBar/App).

### API Contract
- [x] Every endpoint specifies method/path/request/all response codes/error shapes — see §API Contract below.
- [x] WS protocol: new `repos-changed` invalidation frame (mirrors `skills-changed`/`agent-defs-changed`) + the frontend re-fetches `GET /api/repos` on receipt.
- [x] Protocol concerns: existing heartbeat/reconnection (30s ping thread in `Stream.hs`) covers the new frame; no new protocol concerns.
- [x] Response codes explicit (201 upsert / 200 update / 204 delete / 400 validation / 404 unknown / 500 corrupt-registry).

### Security
- [x] Trust boundaries: `/api/repos` mutators = operator-only (gateway loopback, `UrlSafety` blocks agent web tools from loopback); `SHELL_EXEC` residual = existing trust boundary; registry file is operator-trusted.
- [x] Input validation per endpoint: `mkRepoId` regex, URL-shape + host-allow-list, `credential.kind`/`vault_key`/`username` — see §Security table.
- [x] Rate limiting: NOT added this pass (single-user loopback; the existing gateway mutators have none — consistent). Non-blocking suggestion noted for follow-up.
- [x] AuthN/AuthZ: operator-only by network surface (loopback + `UrlSafety`); no new auth wall (consistent with existing `/api/skills`/`/api/agents`).
- [x] Secrets: no secret in `repos.toml` (vault key names only); no `ToJSON` on secret carriers; `GIT_ASKPASS` helper 0700 + bracket-deleted; deploy-key keyfile 0600 `O_EXCL` under `repoCloneStateDir`; `.gitignore` not modified (`repos.toml` is versioned for audit; a machine-user `username` is a public handle — §5.8).

### UI/UX
- [x] User flows documented (§User Flows below) with trigger/steps/visible outcome.
- [x] Text wireframes for `ReposView` (list + editor panes).
- [x] Empty/loading/error states defined.
- [x] Integration WU (W6) wires `ReposView` into the app shell.
- [x] Component hierarchy: `TopBar` → `App` routes `section==='repos'` → `ReposView` (list + editor).

### External Dependencies
- [x] External services: `git` (already a hard dep — `Seal.Git.Repo` uses it), `ssh` (for deploy-key clones — system ssh), `age`/`age-keygen` (vault, already a dep). No new external services.
- [x] Required credentials: the operator stores PAT/deploy-key/machine-user tokens in the vault via existing `/vault` commands (out of scope for this PR). The PR does not provision credentials.
- [x] Human checkpoint BEFORE W3 (the credential-injection seam, security-sensitive) — see §Human Checkpoints.
- [x] Graceful degradation: `CloneGitFailed` / `CloneVaultError VaultLocked` / `CloneVaultError VaultKeyNotFound` surface actionable errors; `git`-not-on-PATH tests skip.

### Completeness
- [x] All human checkpoints from the spec included (after W3 clone seam; before PR after W7).
- [x] All spec features have a WU.
- [x] Tooling consistent (cabal/Nix/hspec/hlint; Vite/Vitest).
- [x] No WU >5 files or >3 concerns.
- [x] Large WUs split (W4=W4a routes+W4b handlers if needed; W6 split by file).

## API Contract

### GET /api/repos
- **Response**: `200 OK` → `[{id, url, vcs_kind, credential: {kind, vault_key, username?}}]` (descriptors; no secret values by construction)
- **Errors**: `500` (corrupt `repos.toml` — the tomland error text, NOT a silent empty list)

### POST /api/repos
- **Request Body**: `{id: string, url: string, vcs_kind: "git"|"github", credential: {kind: "pat"|"deploy_key"|"machine_user", vault_key: string, username?: string}}`
- **Success**: `201 Created` → the created/updated `SourceRepo` descriptor (idempotent upsert: an existing id is REPLACED, mirrors `/api/skills`)
- **Errors**: `400` (invalid JSON / invalid id / bad url / unsupported vcs_kind / unknown credential.kind / missing vault_key / machine_user without username / host not in allow-list)

### PUT /api/repos/:id
- **Request Body**: same as POST (id from path; no `new_id` rename field — ids are stable)
- **Success**: `200 OK` → the updated `SourceRepo` descriptor
- **Errors**: `400` (validation) / `404` (id absent) / `500` (corrupt registry)

### DELETE /api/repos/:id
- **Success**: `204 No Content` (idempotent — 204 whether or not the id existed)
- **Errors**: `400` (malformed id)

### WS frame: `repos-changed`
- **Shape**: `{"type":"repos-changed"}` (invalidation signal — the frontend re-fetches `GET /api/repos` on receipt, mirroring `skills-changed`)
- **Trigger**: every successful POST/PUT/DELETE on `/api/repos`

## Security Considerations (input validation table)

| Endpoint | Input | Validation |
|---|---|---|
| POST/PUT `/api/repos` | `id` | `mkRepoId` — `^[A-Za-z0-9_-]+$`, non-empty; else 400 |
| POST/PUT `/api/repos` | `url` | non-empty + URL-shape (`git@<host>:...` or `https://<host>/...`) + parsed host ∈ `{github.com}`; else 400 |
| POST/PUT `/api/repos` | `vcs_kind` | ∈ `{git, github}`; else 400 |
| POST/PUT `/api/repos` | `credential.kind` | ∈ `{pat, deploy_key, machine_user}`; else 400 |
| POST/PUT `/api/repos` | `credential.vault_key` | non-empty string; else 400 |
| POST/PUT `/api/repos` | `credential.username` | required iff `kind=machine_user`; else 400 |
| Clone (`planClone`) | URL host | re-parsed and asserted ∈ allow-list; else `CloneHostNotSupported` (defense in depth) |
| Clone (IO) | vault key | `vhGet` → `CloneVaultError VaultLocked` / `CloneVaultError VaultKeyNotFound` |
| Clone (IO) | git stderr | **dropped** — `CloneGitFailed Int` carries exit code only (no stderr) |

**Secrets management:** no secret value in `repos.toml`; vault values accessed only via CPS `withCloneTarget`; `GIT_ASKPASS` helper + deploy-key keyfile under `repoCloneStateDir` (0700 parent, `O_EXCL` + `fchmod 0600`, random suffix, bracket cleanup); token never in argv/URL/env (only the non-secret `GIT_ASKPASS` path is in env).

## User Flows (ReposView)

**Flow 1 — Register a repo (operator at desk, web UI):**
1. Trigger: operator clicks "Repos" in `TopBar` → `section='repos'` → `ReposView` renders.
2. Steps: click "New" → right-pane editor opens empty → enter `id`, `url`, select `vcs_kind` (default `github`), select `credential.kind` (with plain-language labels: "Personal Access Token" / "SSH Deploy Key" / "Bot Account"), enter `vault_key`, enter `username` (only if Bot Account) → click "Save".
3. Visible outcome: `POST /api/repos` → 201; list refreshes (via `repos-changed` WS frame); new row appears with a human-readable credential badge. The editor shows "Store the credential in the vault under this key name." (no value field).

**Flow 2 — Edit a repo:**
1. Trigger: click a row in the list.
2. Steps: right-pane editor populates with the repo's fields → edit → "Save".
3. Visible outcome: `PUT /api/repos/:id` → 200; list refreshes; row updates.

**Flow 3 — Remove a repo:**
1. Trigger: click trash icon on a row.
2. Steps: confirm dialog → "Delete".
3. Visible outcome: `DELETE /api/repos/:id` → 204; list refreshes; row disappears.

**Flow 4 — Verify a credential works (slash, chat):**
1. Trigger: operator types `/repo test <id>` in a chat channel.
2. Steps: command dispatches `git ls-remote` against the resolved credential (no full clone).
3. Visible outcome: `ccSend` echoes success (`credential verified — <head-sha>`) or a distinguishable error (`vault locked — run /vault unlock` / `vault key <name> not found` / `git ls-remote failed (exit N)`).

**Wireframe (ReposView):**
```
┌─ TopBar ────────────────────────────────────────────────┐
│ Seal Harness   [Sessions] [Agents] [Skills] [Repos]     │
├─────────────────────────────────────────────────────────┤
│ ┌─ list (left) ──────┐ ┌─ editor (right) ─────────────┐ │
│ │ seal-harness       │ │ id:        [____________]    │ │
│ │   git@github.com…  │ │ url:       [____________]    │ │
│ │   [Personal Access │ │ vcs:       [github ▾]        │ │
│ │    Token]          │ │ credential:                  │ │
│ │ private-tool       │ │   kind: [Personal Access… ▾] │ │
│ │   git@github.com…  │ │   vault_key: [____________]  │ │
│ │   [SSH Deploy Key] │ │   username: (hidden unless   │ │
│ │ acme-infra         │ │             Bot Account)     │ │
│ │   git@github.com…  │ │                              │ │
│ │   [Bot Account]    │ │ "Store the credential in the │ │
│ │                    │ │  vault under this key name." │ │
│ │ [+ New]            │ │              [Save] [Cancel] │ │
│ └────────────────────┘ └──────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

**States:**
- **Empty**: list shows "No repos registered. Click 'New' to add one."
- **Loading**: list shows skeleton rows (`useRepos` `loaded` flag).
- **Error**: list shows "Failed to load repos" + retry button (`useRepos` `error` flag).
- **Submitting**: Save button disabled + spinner (`submitting` state, mirrors `SkillsView`).
- **Confirming delete**: inline confirm on the row (mirrors `SkillsView`'s `confirmingDelete`).

## Work Unit Decomposition

### W0 — Cabal scaffolding
**Spec**: design §7 W0. **Dependencies**: none. **Human checkpoint**: no.
**DoD**:
- [ ] `Seal.SourceControl.Repo`, `Seal.SourceControl.Registry`, `Seal.SourceControl.Clone`, `Seal.Command.Repo` added to `exposed-modules` in `seal-harness.cabal`.
- [ ] `Seal.SourceControl.RepoSpec`, `Seal.SourceControl.RegistrySpec`, `Seal.SourceControl.CloneSpec`, `Seal.Command.RepoSpec` added to the test-suite `other-modules`.
- [ ] `make build` succeeds (modules can be empty stubs with minimal exports; `-Werror` clean — no unused-import warnings).
**File scope**: `seal-harness.cabal` (only).

### W1 — Types + codec (`Seal.SourceControl.Repo`)
**Spec**: design §4.1, §4.2. **Dependencies**: W0. **Human checkpoint**: no.
**DoD**:
- [ ] `VcsKind` (`VcsGit | VcsGitHub`), `RepoCredential` (`CredPat`/`CredDeployKey`/`CredMachineUser`), `SourceRepo`, `RepoId` newtype defined.
- [ ] `mkRepoId :: Text -> Either Text RepoId` (rejects empty / non-`[A-Za-z0-9_-]+`) + `repoIdText`; codec runs `mkRepoId` on decode (fail-closed).
- [ ] Bidirectional tomland codec: keyed-by-id `[repos.<id>]` via `Toml.tableMap Toml._KeyText (Toml.table repoCodec) "repos"`.
- [ ] **`normalizeReposTable` AST walk** — a sibling of `Seal.Config.File.normalizeProvidersTable` (which see). `Toml.tableMap` silently decodes an empty map when a hand-written file uses only `[repos.<id>]` sub-tables with no bare `[repos]` header (the idiomatic style — the §4.2 example). `loadRepoRegistry` runs `normalizeReposTable` on the parsed `TOML` before `runTomlCodec`, exactly mirroring `loadRuntimeConfig`'s `normalizeProvidersTable` call. Without this, a hand-edited `repos.toml` decodes as empty (silent data loss — the §5.7 mitigation would be defeated). Exported from `Repo.hs` so `RepoSpec` can unit-test it directly.
- [ ] Codec fail-closed on unknown `credential_kind` / `vcs_kind`, missing `vault_key`, `machine_user` without `username`; extra fields ignored.
- [ ] `ToJSON`/`FromJSON` for `SourceRepo` emitting the descriptor `{id, url, vcs_kind, credential:{kind, vault_key, username?}}` (snake_case); no instance for any secret carrier.
- [ ] Pure URL helpers: `parseRepoHost :: Text -> Either CloneError Text`, `hostAllowed :: Text -> Bool` (the `github.com` allow-list), `urlShapeValid :: Text -> Bool`.
- [ ] Module comment: "RepoId is never used to construct a FilePath — it is only a Map key" + "cUsername is a public handle, not a secret."
- [ ] `RepoSpec`: round-trip (all 3 kinds); absent→empty; `mkRepoId` rejection (empty, `bad/id`, `../`, `a/b`); codec rejection edges (unknown kind, missing vault_key, machine_user without username, unknown vcs_kind); **`normalizeReposTable` unit test** (idiomatic `[repos.<id>]`-only file decodes to the non-empty map, not empty); QuickCheck on `parseRepoHost`/`hostAllowed`/`urlShapeValid`.
- [ ] `make build` + the `RepoSpec` tests green.
**File scope**: `src/Seal/SourceControl/Repo.hs`, `test/Seal/SourceControl/RepoSpec.hs` (new files).

### W2 — Paths + Registry (`Seal.SourceControl.Registry` + `Seal.Config.Paths`)
**Spec**: design §4.3, §4.8. **Dependencies**: W1. **Human checkpoint**: no.
**DoD**:
- [ ] `Seal.Config.Paths` gains `reposFilePath :: SealPaths -> FilePath` (`spConfig </> "repos.toml"`) and `repoCloneStateDir :: SealPaths -> FilePath` (`spState </> "repos"`).
- [ ] `PathsSpec` updated to cover both new paths.
- [ ] `RepoRegistry` (`rrRepos :: Map RepoId SourceRepo`), `loadRepoRegistry`/`saveRepoRegistry`/`updateRepoRegistry`/`upsertRepo`/`removeRepo`/`lookupRepo`.
- [ ] `repoRegistryWriteLock` — a dedicated, separate `MVar ()` (NOT shared with `configWriteLock`); `unsafePerformIO`-initialized with `{-# NOINLINE #-}` (mirrors `configWriteLock`).
- [ ] `saveRepoRegistry` atomic (tmp → rename).
- [ ] `RepoRegistryHandle` (`rrhList :: IO (Either Text [SourceRepo])`, `rrhMutate :: (RepoRegistry -> RepoRegistry) -> IO (Either Text ())`) + `mkRepoRegistryHandle :: FilePath -> IO RepoRegistryHandle`. (The `Either` on `rrhList` is required so a corrupt `repos.toml` surfaces as HTTP 500 — see W4.)
- [ ] `RegistrySpec`: load absent→empty; save/load round-trip; upsert/remove/lookup; concurrent `updateRepoRegistry` (N threads, no lost update — assert final state = union); atomic-rename (no `.tmp` left on exception); `RepoRegistryHandle` fake wiring (`rrhList = pure (Right [])`, `rrhMutate = \_ -> pure (Right ())`); **corrupt-file → `rrhList` returns `Left`** (the tomland error text propagates).
- [ ] `make build` + `RegistrySpec` + `PathsSpec` green.
**File scope**: `src/Seal/SourceControl/Registry.hs`, `src/Seal/Config/Paths.hs`, `test/Seal/SourceControl/RegistrySpec.hs`, `test/Seal/Config/PathsSpec.hs` (edit).

### W3 — Clone seam (`Seal.SourceControl.Clone` + `Seal.Git.Repo` env variant)
**Spec**: design §4.4, §5. **Dependencies**: W2. **Human checkpoint**: **YES** (security-sensitive — review that no secret leaks via argv/URL/env, temp files under private dir, bracket cleanup, host allow-list).
**DoD**:
- [ ] `CloneError` (5 variants: `CloneVaultError VaultError`, `CloneNoCredentialForUrl Text`, `CloneUnsupportedVcs VcsKind`, `CloneHostNotSupported Text`, `CloneGitFailed Int` — exit code only, no stderr).
- [ ] `ClonePlan` (`ClonePlanExtraHeader Text Text` | `ClonePlanSshKey Text Text`); `planClone :: SourceRepo -> Either CloneError ClonePlan` (pure; re-parses host, asserts allow-list; routes PAT/MachineUser→ExtraHeader, DeployKey→SshKey).
- [ ] `CloneTarget` (opaque, constructors NOT exported, redacted `Show`); `CloneEnv` (`ceUrl`, `ceGitConfigArgs`, `ceSshCommand`, `ceEnvExtras`, `ceCleanup`); `withCloneTarget :: CloneTarget -> (CloneEnv -> IO r) -> IO r` (CPS, mirrors `withApiKey`).
- [ ] `resolveCloneTarget :: VaultHandle -> FilePath -> SourceRepo -> IO (Either CloneError CloneTarget)` — reads vault via `vhGet`; writes the `GIT_ASKPASS` helper script (0700, `repoCloneStateDir`, `O_EXCL` + random suffix, bracket-deleted) for PAT/MachineUser; writes deploy-key keyfile (0600, `O_EXCL` + random suffix, bracket-deleted) for DeployKey.
- [ ] **`GIT_ASKPASS` helper is prompt-aware (correct protocol).** git invokes `$GIT_ASKPASS <prompt>` **twice** for an HTTPS credential challenge: once with `Username for 'https://github.com': ` and once with `Password for 'https://github.com': ` (the prompt text is `argv[1]`). A single-value "echo the token" helper FAILS (leaves the username prompt unanswered; `GIT_TERMINAL_PROMPT=0` prevents fallback). The helper script inspects `argv[1]`:
    - **PAT**: returns `x-access-token` for the `Username` prompt, the PAT bytes for the `Password` prompt. (GitHub's documented PAT-over-HTTPS convention: username `x-access-token`, password = the token.)
    - **MachineUser**: returns `cUsername` for the `Username` prompt, the token bytes for the `Password` prompt.
    The helper is generated per-clone with the resolved bytes embedded (0700, bracket-deleted); it writes its answer to stdout and exits 0. `cloneRepo`/`lsRemoteRepo` invoke git with `GIT_ASKPASS=<helper> GIT_TERMINAL_PROMPT=0` in the (merged) env.
- [ ] `cloneRepo :: VaultHandle -> FilePath -> FilePath -> SourceRepo -> IO (Either CloneError ())` — plan → resolve → `withCloneTarget` (bracket) → `git clone` via `readProcessBinaryCwdEnv` → cleanup; `CloneGitFailed Int` on non-zero exit (stderr dropped).
- [ ] `Seal.Git.Repo` gains `readProcessBinaryCwdEnv :: Maybe FilePath -> [(String,String)] -> FilePath -> [String] -> ByteString -> IO (ExitCode, ByteString, ByteString)` — env is **merge** (child inherits `getEnvironment` + the extras unioned in; PATH/HOME preserved); invariant comment.
- [ ] `lsRemoteRepo :: VaultHandle -> FilePath -> SourceRepo -> IO (Either CloneError Text)` — same seam, `git ls-remote` instead of `git clone` (for `/repo test`).
- [ ] `CloneSpec`: `planClone` pure cases (all 3 kinds + every `CloneError` variant); fake-`ps` argv-exposure test (skip on macOS/no-`/proc`); bracket-cleanup test (assert temp files created 0600/0700 under `repoCloneStateDir`, not `/tmp`, removed after success AND failure); `git ls-remote` integration test against a local fixture repo, PAT path (skip if `git` not on PATH); vault-locked surfacing (`CloneVaultError VaultLocked` → message contains "vault locked"; `CloneVaultError VaultKeyNotFound k` → message contains "vault key" AND the key name); **no-stderr assertion** (`CloneGitFailed` carries no stderr bytes); **rotation test** (S3/AC10: mutate the fake vault between two `lsRemoteRepo` calls and assert the second resolves the new bytes — verified by capturing the helper-script content or the env across the two calls); **ASKPASS prompt-awareness test** (assert the generated helper script branches on `argv[1]` `Username`/`Password` and returns `x-access-token`/token for PAT, `cUsername`/token for MachineUser).
- [ ] Reuses `Seal.TestHelpers.FakeVault` (`makeFakeVault`/`makeLockedVault`) for the fake vault.
- [ ] `make build` + `CloneSpec` green.
**File scope**: `src/Seal/SourceControl/Clone.hs`, `src/Seal/Git/Repo.hs` (edit — add `readProcessBinaryCwdEnv`), `test/Seal/SourceControl/CloneSpec.hs` (new).

### W4 — REST API (`/api/repos` + `ApiDeps` + broadcast)
**Spec**: design §4.5. **Dependencies**: W2. **Human checkpoint**: no. **NOTE: serialized before W5** (W4 and W5 both edit `Seal.Command.Serve.hs` — see the corrected DAG below; they are NOT parallel).
**DoD**:
- [ ] `ApiDeps` gains `adRepoRegistry :: RepoRegistryHandle` AND `adConfigRepo :: Seal.Git.Repo.ConfigRepo` (the latter for `gitCommitAll` auto-commit of `repos.toml`; design §8.12's "one field" decision referred to the *registry* closures — `adConfigRepo` is a separate, pre-existing handle type already constructed in `Serve.hs:109` for `SendDeps.sdConfigRepo`, now also threaded to `ApiDeps`; this is the minimal mechanism, not a second registry closure). **Every `ApiDeps` record literal across the in-scope files must be updated** — the compiler enforces this (`-Wincomplete-record-updates` + `-Werror`). The literals span **4 files** (verified by grep): (1) production wiring `src/Seal/Command/Serve.hs` (~line 212); (2) `test/Seal/Gateway/ApiSpec.hs` — `mkDepsFor` (~line 183) **plus ~18 inline full-construction literals** (lines ~1513, 1582, 1643, 1707, 1794, 1846, 1897, 1929, 2013, 2063, 2112, 2155, 2199, 2424, 2511, 2630, 2734 — `rg 'ApiDeps \{' test/Seal/Gateway/ApiSpec.hs` finds them all; update every one); (3) `test/Seal/Phase7aSpec.hs` **TWO** literals (~line 63 and ~line 112); (4) `test/Seal/Gateway/ServerSpec.hs` `mkDeps` (~line 54). Test fakes: `adRepoRegistry = mkFakeRepoRegistryHandle` (`rrhList = pure (Right [])`, `rrhMutate = \_ -> pure (Right ())`); `adConfigRepo = openConfigRepo "/tmp/nonexistent"` (the auto-commit is best-effort; the handler wraps `gitCommitAll` in `try @SomeException` so a missing-repo-path ioError is caught and logged, never failing the HTTP request — see W4 handler note below).
- [ ] `RepoRegistryHandle.rrhList` error channel: **`rrhList :: IO (Either Text [SourceRepo])`** (NOT `IO [SourceRepo]`) so a corrupt `repos.toml` propagates the tomland error to the GET handler → HTTP 500 (not a silent empty list). `rrhMutate` stays `IO (Either Text ())`. The W2 DoD is amended accordingly (the fake's `rrhList = pure (Right [])`).
- [ ] `apiApp` routes: `GET /api/repos` (200 + descriptors; **500 on corrupt registry** via the `Left` from `rrhList`), `POST /api/repos` (201 idempotent upsert; 400 validation), `PUT /api/repos/:id` (200; 400/404), `DELETE /api/repos/:id` (204 idempotent; 400 malformed id).
- [ ] `handleRepoCreate`/`Update`/`Delete`/`Get`/`List` handlers mirroring `handleSkill*` (validation: `mkRepoId`, URL-shape + host allow-list, `credential.kind`/`vault_key`/`username`).
- [ ] On successful POST/PUT/DELETE: `rrhMutate` rewrites the file, **`gitCommitAll adConfigRepo "repos.toml" "seal: update repo registry"`** auto-commits (audit trail — **best-effort, wrapped in `try @SomeException`** so a commit failure / missing-repo-path ioError is logged but does NOT fail the HTTP request, since the registry write already succeeded), and `broadcastReposChanged (adBroker deps)` is called.
- [ ] `BrokerEvent` gains `BeReposChanged`; `StreamBroker` gains `broadcastReposChanged :: StreamBroker -> IO ()` (exported); `Stream.hs` `sendEvent` emits `{"type":"repos-changed"}`; `Broadcast.hs` gains `broadcastReposChanged :: Maybe StreamBroker -> IO ()` (mirrors `broadcastSkillsChanged`, exported).
- [ ] **No-secret-in-response test**: `ApiSpec` plants a known token in the fake vault, GET/POST/PUT, asserts the response JSON has no field whose value matches the token.
- [ ] `ApiSpec`: GET empty; POST idempotent-upsert (201, replaces existing id); PUT 404; DELETE 404 + 204 idempotent; host-allow-list rejection at POST/PUT; corrupt `repos.toml` → GET 500 (not silent empty).
- [ ] `make build` + `ApiSpec` + `Phase7aSpec` + `ServerSpec` green (all four `ApiDeps` literals compile under `-Wincomplete-record-updates` + `-Werror`).
**File scope**: `src/Seal/Gateway/API.hs`, `src/Seal/Gateway/Broadcast.hs`, `src/Seal/Gateway/StreamBroker.hs`, `src/Seal/Gateway/Stream.hs`, `src/Seal/Command/Serve.hs`, `test/Seal/Gateway/ApiSpec.hs`, `test/Seal/Phase7aSpec.hs`, `test/Seal/Gateway/ServerSpec.hs`.

### W5 — Slash command (`/repo` + `GroupRepos` + `Help` + `Serve` wiring)
**Spec**: design §4.6. **Dependencies**: W4 (both edit `Serve.hs`; W5 also reuses the `RepoRegistryHandle` from W2 and the `lsRemoteRepo` seam from W3). **Human checkpoint**: no.
**DoD**:
- [ ] `Seal.Command.Repo` exports `repoCommandSpec :: RepoRegistryHandle -> VaultHandle -> SealPaths -> CommandSpec` (closes over the registry handle, vault handle for `/repo test`, and paths for `repoCloneStateDir`).
- [ ] `hsubparser` commands: `list`, `add`, `remove`, `info`, `test` (mirrors `skillParser`).
- [ ] `add` parses `<id> <url>` + `--vcs` (default `github`), `--cred` (`pat`|`deploy_key`|`machine_user`, default `pat`), `--vault-key`, `--username`; plain-language help text for each credential kind.
- [ ] `list` renders `id  url  <human-credential-label>`; `info` renders full descriptor + a **non-blocking** "vault key <name> not found — clone will fail until it's added" advisory (queries `vhList`); `test` runs `lsRemoteRepo` and echoes success/failure; `remove` removes.
- [ ] **`/repo test` error-message mapping** (AC6): `CloneVaultError VaultLocked` → `"vault locked — run /vault unlock"`; `CloneVaultError (VaultKeyNotFound k)` → `"vault key <k> not found"`; `CloneHostNotSupported h` → `"host <h> not supported (only github.com is supported in this pass)"`; `CloneUnsupportedVcs v` → `"unsupported VCS: <v>"`; `CloneGitFailed n` → `"git ls-remote failed (exit <n>)"` (no stderr); `CloneNoCredentialForUrl u` → `"no credential resolvable for <u>"`. Success → `"credential verified — <head-sha>"`. The command is `InteractiveOnly` (mirrors `/skill`), so it dispatches only on the channel the operator is typing on — not reachable by the agent's tool surface.
- [ ] All mutations go through `rrhMutate`; the credential value is never read by `add`/`info`/`list` (only the vault key name).
- [ ] `CommandGroup` gains `GroupRepos`; `Seal.Command.Help.groupHeader` gains `groupHeader GroupRepos = "Repos"` (else `-Wincomplete-patterns` + `-Werror`).
- [ ] `Serve.hs` wires `repoCommandSpec` into the command registry (`mkRegistry`).
- [ ] `Seal.Command.RepoSpec`: parser + `list`/`add`/`remove`/`info`/`test` round-trips (mirrors `SkillSpec`'s `execParserPure` + `runCommandAction` + `FakeCaps` shape); the non-blocking vault-key advisory on `/repo info`; **`/repo test` error-message tests** (assert each `CloneError` variant maps to the exact user-facing message above, via a fake vault + a stubbed `lsRemoteRepo` seam the spec injects).
- [ ] `make build` + `RepoSpec` (command) + `HelpSpec` green.
**File scope**: `src/Seal/Command/Repo.hs`, `src/Seal/Command/Spec.hs` (edit — add `GroupRepos`), `src/Seal/Command/Help.hs` (edit — add `groupHeader` clause), `src/Seal/Command/Serve.hs` (edit — wire registry), `test/Seal/Command/RepoSpec.hs` (new).

### W6 — Frontend (`ReposView` + `TopBar` + `App` + `useApi` + `types`)
**Spec**: design §4.7. **Dependencies**: W4 (API contract). **Human checkpoint**: no.
**DoD**:
- [ ] `frontend/src/types.ts` gains `RepoInfo` (`{id, url, vcs_kind, credential: {kind, vault_key, username?}}`) + `RepoInput` + `RepoCredentialKind` union + the credential-kind label map (`pat`→"Personal Access Token", `deploy_key`→"SSH Deploy Key", `machine_user`→"Bot Account").
- [ ] `frontend/src/hooks/useApi.ts` gains `fetchRepos`, `createRepo`, `updateRepo`, `deleteRepo`, and `useRepos` (WS `repos-changed`-subscribed via `streamClient` + REST poll fallback, mirrors `useSkills`).
- [ ] `frontend/src/lib/streamClient.ts` gains a `repos-changed` case (re-fetch `/api/repos`) + `reposChangedListeners` + `onReposChanged` subscribe API (mirrors `skills-changed`).
- [ ] `frontend/src/types/stream.ts` gains the `repos-changed` frame type.
- [ ] `frontend/src/components/ReposView.tsx` — list (left) + editor (right), mirrors `SkillsView.tsx`; human-readable credential-kind badges; `username` field shown only for `machine_user`; "Store the credential in the vault under this key name." note; empty/loading/error/submitting/confirming-delete states.
- [ ] `TopBar.tsx` `TopSection` gains `'repos'`; `SECTION_LABELS` gains `repos: "Repos"`.
- [ ] `App.tsx` `sectionFromPath`/`pathFromSection` gain `'repos'`; routes `section === 'repos'` → `<ReposView />`.
- [ ] `frontend/src/components/__tests__/ReposView.test.tsx` (or `ReposView.test.tsx` next to the component — match the existing convention): render, add, edit, remove (mirrors `SkillsView` test); **assert no secret-value field is ever rendered** (the credential form has only `kind`/`vault_key`/`username` — no value input).
- [ ] `useApi` test (`frontend/src/hooks/__tests__/useApi.test.ts`) updated: `useRepos` fetch + `repos-changed` refresh.
- [ ] `npm run build` + `npm test` (Vitest) green.
**File scope**: `frontend/src/types.ts`, `frontend/src/types/stream.ts`, `frontend/src/hooks/useApi.ts`, `frontend/src/lib/streamClient.ts`, `frontend/src/components/ReposView.tsx` (new), `frontend/src/components/TopBar.tsx`, `frontend/src/App.tsx`, `frontend/src/components/__tests__/ReposView.test.tsx` (new), `frontend/src/hooks/__tests__/useApi.test.ts` (edit).

### W7 — `make check` gate + final comprehensive review
**Spec**: design §7 W7. **Dependencies**: W0–W6. **Human checkpoint**: **YES** (before PR).
**DoD**:
- [ ] `make check` (build + test + lint) green.
- [ ] `hlint src/ test/` reports "No hints" (including the new `SourceControl.*` + `Command.Repo` modules).
- [ ] `npm run build` + `npm test` (frontend) green.
- [ ] Cross-unit integration: no duplicate/conflicting imports; no conflicting type definitions; API contracts between W4 (backend) and W6 (frontend) consistent (`RepoInfo` shape matches the backend descriptor); no leftover TODO/FIXME; file scopes respected.
- [ ] Full `git diff main..HEAD` review; `git log main..HEAD --oneline` clean logical commits.
- [ ] `.coverage-thresholds.json` enforcement command (`make test`) run (HPC instrumentation pending per AGENTS.md — the command runs the suite; coverage measurement is noted as pending and NOT a blocker for this PR per the project's documented limitation).
- [ ] Final report produced.
**File scope**: none (verification only; fix-up commits to in-scope files if needed).

## Human Checkpoints

1. **After W3 (clone seam)** — security-sensitive. Review criteria: (a) token/key bytes never in argv/URL/env (only the non-secret `GIT_ASKPASS` path is in env); (b) temp files (helper script + keyfile + `known_hosts`) under `repoCloneStateDir` (0700 parent), `O_EXCL` + `fchmod 0600/0700` + random suffix, bracket cleanup on success AND failure; (c) host allow-list enforced at `planClone` (clone-time); (d) `CloneGitFailed` carries exit code only (no stderr); (e) CPS `withCloneTarget` scopes the authenticated bits. Pause and present the W3 checkpoint report; do NOT proceed to W4 until approved.

2. **After W7 (before PR)** — final gate. Review criteria: full `make check` + frontend green; cross-unit integration clean; no secret leaks. Pause and present the final report.

## Constructed Dependency DAG

```
W0 (cabal) ──→ W1 (types+codec) ──→ W2 (paths+registry) ──→ W3 (clone seam) ──┐
                                                                                │
                                          ┌── W4 (REST API) ──→ W5 (slash cmd) ─┼── W6 (frontend) ──→ W7 (gate)
                                          │                                     │
                                          └─────────────────────────────────────┘
```

**W4 → W5 is serialized** (NOT parallel): both edit `src/Seal/Command/Serve.hs` (W4 adds `adRepoRegistry`/`adConfigRepo` to the `ApiDeps` literal ~line 212; W5 adds `repoCommandSpec` to the `mkRegistry` literal ~line 176). Running them concurrently would conflict on `Serve.hs`. W5 depends on W4. W6 depends on W4's API contract. W7 depends on all.

*(The design doc §7's "W4, W5 parallel" note is retracted — the feasibility review found the shared `Serve.hs` file. The serialization is the only change to the decomposition.)*

## Established Patterns (for coder subagents)

- **TOML codec**: bidirectional via `Toml.dioptional`/`Toml.table`/`Toml.tableMap`; absent→`Nothing`; atomic save (tmp→rename); MVar write-lock. See `Seal.Config.File`.
- **Smart constructor**: `mkRepoId` mirrors `mkSkillId`/`mkAgentDefId`/`mkSessionId` — `Text -> Either Text Newtype`, regex-validated, run in the codec.
- **Opaque secret + CPS**: `withCloneTarget` mirrors `withApiKey` (`Seal.Security.Secrets`); constructors NOT exported; redacted `Show`; no `ToJSON`.
- **Slash command**: `hsubparser` + `CommandSpec` + `CommandAction (ChannelCaps -> IO ())`; `execParserPure` in tests. See `Seal.Command.Skill` + `Seal.Command.SkillSpec`.
- **REST CRUD**: manual WAI router in `Seal.Gateway.API`; `ApiDeps` record injection; `handleSkill*` is the mirror for `handleRepo*`; idempotent-upsert POST (201).
- **WS invalidation frame**: `BrokerEvent` variant + `StreamBroker.broadcast*` + `Stream.hs` `sendEvent` emits `{"type":"X-changed"}` + `Broadcast.hs` `broadcastXChanged :: Maybe StreamBroker -> IO ()` + frontend `streamClient` case + `useX` hook re-fetches. See `skills-changed` end-to-end.
- **Fake vault**: `Seal.TestHelpers.FakeVault` (`makeFakeVault`/`makeLockedVault`) — `VaultHandle` is a record of `IO` actions.
- **Process runner**: `Seal.Git.Repo.readProcessBinaryCwd` — the env-passing sibling `readProcessBinaryCwdEnv` is added in W3 (env = merge, child inherits PATH/HOME).
- **Frontend CRUD view**: `SkillsView.tsx` is the mirror (list + editor, empty/loading/error/submitting/confirming-delete states); `useSkills` + `streamClient` `skills-changed` for the WS hook.
- **`-Werror`**: every `ApiDeps`/`CommandGroup`/`TopSection` construction site must be updated when the record/enum gains a field/constructor (else `-Wincomplete-record-updates`/`-Wincomplete-patterns` fires).

## Project Context (initial — written to `.beads/context/project-context.md`)

```markdown
# Project Context (Maintained by Orchestrator)

## Tooling
- Package manager: cabal (Nix dev shell via `make`)
- Test runner: hspec + QuickCheck (`make test`); frontend: Vitest (`npm test`)
- Linter: hlint (`make lint`)
- Build: cabal (`make build`); frontend: Vite (`npm run build`)
- Gate: `make check` (build + test + lint)

## Completed Work Units
| WU | Title | Key Files | Services Created |
|----|-------|-----------|-----------------|
(none yet)

## Established Patterns
- See "Established Patterns" above.
```