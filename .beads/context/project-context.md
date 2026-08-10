# Project Context (Maintained by Orchestrator)

## Tooling
- Package manager: cabal (Nix dev shell via `make`)
- Test runner: hspec + QuickCheck (`make test`); frontend: Vitest (`npm test`)
- Linter: hlint (`make lint`)
- Build: cabal (`make build`); frontend: Vite (`npm run build`)
- Gate: `make check` (build + test + lint)
- Coverage: `.coverage-thresholds.json` enforcement command = `make test` (HPC instrumentation pending per AGENTS.md — command runs the suite; line/branch measurement not yet wired, documented as a project limitation, NOT a blocker for this PR)

## Spec / Plan
- Issue: https://github.com/seal-harness/seal-harness/issues/78
- Design: `docs/superpowers/specs/2026-08-02-source-control-repo-registry-design.md` (5/5 design-gate approved, round 2)
- Plan: `.beads/plans/active-plan.md` (3/3 plan-gate approved, round 2)
- Branch: `feat/source-control-repos`

## Completed Work Units
| WU | Title | Key Files | Services Created |
|----|-------|-----------|-----------------|
| W1 | Repo types + codec | `src/Seal/SourceControl/Repo.hs`, `test/Seal/SourceControl/RepoSpec.hs` | `mkRepoId`, `repoRegistryCodec`, `normalizeReposTable`, URL helpers, `SourceRepo` ToJSON/FromJSON |
| W2 | Registry + paths | `src/Seal/SourceControl/Registry.hs`, `src/Seal/Config/Paths.hs` (edit) | `RepoRegistry`, `loadRepoRegistry`/`saveRepoRegistry`/`updateRepoRegistry`, `RepoRegistryHandle` (`rrhList :: IO (Either Text [SourceRepo])`, `rrhMutate`), `mkRepoRegistryHandle`, `repoRegistryWriteLock`, `reposFilePath`, `repoCloneStateDir` |
| W3 | Clone seam | `src/Seal/SourceControl/Clone.hs`, `src/Seal/Git/Repo.hs` (edit) | `CloneError` (5 variants), `planClone`, `resolveCloneTarget`, `withCloneTarget` (CPS), `cloneRepo`, `lsRemoteRepo`, `renderCloneError`, `readProcessBinaryCwdEnv` (in Git.Repo) |
| W4 | REST API + broadcast | `src/Seal/Gateway/API.hs`, `StreamBroker.hs`, `Stream.hs`, `Broadcast.hs`, `Serve.hs` (edits) | `ApiDeps` `adRepoRegistry`/`adConfigRepo`, `handleRepoGet/Create/Update/Delete`, `repoInfoJson`, `BeReposChanged` + `broadcastReposChanged` end-to-end, `bestEffortCommitRepos` |
| W5 | Slash command | `src/Seal/Command/Repo.hs`, `Spec.hs`/`Help.hs`/`Serve.hs` (edits) | `repoCommandSpec`, `RepoTestSeam`, `GroupRepos`, `renderRepoLine`/`renderRepoInfo`/`credentialKindLabel`, `/repo test` error mapping (all 5 CloneError variants) |
| W6 | Frontend | `frontend/src/components/ReposView.tsx`, `types.ts`, `useApi.ts`, `streamClient.ts`, `types/stream.ts`, `TopBar.tsx`, `App.tsx` (new/edits) | `RepoInfo`/`RepoInput`/`REPO_CRED_LABELS`, `useRepos`+CRUD, `repos-changed` WS frame end-to-end, `ReposView` (list+editor, no-secret-value-field) |

## Established Patterns (for coder subagents)
- **TOML codec**: bidirectional via `Toml.dioptional`/`Toml.table`/`Toml.tableMap`; absent→`Nothing`; atomic save (tmp→rename); MVar write-lock. See `Seal.Config.File`. **CAUTION**: `Toml.tableMap` silently decodes empty for idiomatic `[<section>.<key>]`-only files (no bare `[<section>]` header) — requires a `normalizeXTable` AST walk before `runTomlCodec` (see `normalizeProvidersTable` in `Seal.Config.File`). W1 ships `normalizeReposTable`.
- **Smart constructor**: `mkRepoId` mirrors `mkSkillId`/`mkAgentDefId`/`mkSessionId` — `Text -> Either Text Newtype`, regex-validated, run in the codec (fail-closed).
- **Opaque secret + CPS**: `withCloneTarget` mirrors `withApiKey` (`Seal.Security.Secrets`); constructors NOT exported; redacted `Show`; no `ToJSON`.
- **Slash command**: `hsubparser` + `CommandSpec` + `CommandAction (ChannelCaps -> IO ())`; `execParserPure` in tests. See `Seal.Command.Skill` + `Seal.Command.SkillSpec`.
- **REST CRUD**: manual WAI router in `Seal.Gateway.API`; `ApiDeps` record injection; `handleSkill*` is the mirror for `handleRepo*`; idempotent-upsert POST (201). **ApiDeps has ~22 record literals across 4 files** (Serve.hs, ApiSpec.hs ~18 inline + mkDepsFor, Phase7aSpec.hs ×2, ServerSpec.hs) — `-Wincomplete-record-updates` + `-Werror` forces updating every one when a field is added.
- **WS invalidation frame**: `BrokerEvent` variant + `StreamBroker.broadcast*` + `Stream.hs` `sendEvent` emits `{"type":"X-changed"}` + `Broadcast.hs` `broadcastXChanged :: Maybe StreamBroker -> IO ()` + frontend `streamClient` case + `useX` hook re-fetches. See `skills-changed` end-to-end. (Plan uses `repos-changed` invalidation, NOT the design's literal `repos` payload frame — matches the real codebase pattern.)
- **Fake vault**: `Seal.TestHelpers.FakeVault` (`makeFakeVault`/`makeLockedVault`) — `VaultHandle` is a record of `IO` actions; `vhGet`/`vhList` are plain fields.
- **Process runner**: `Seal.Git.Repo.readProcessBinaryCwd` — the env-passing sibling `readProcessBinaryCwdEnv` is added in W3 (env = `getEnvironment` + extras merged; child inherits PATH/HOME).
- **GIT_ASKPASS protocol**: git calls `$GIT_ASKPASS <prompt>` TWICE for HTTPS (Username prompt, then Password prompt) — the helper MUST be prompt-aware (inspect `argv[1]`): PAT → `x-access-token`/token; MachineUser → cUsername/token. `GIT_TERMINAL_PROMPT=0` in env.
- **gitCommitAll**: `Seal.Git.Repo.gitCommitAll :: ConfigRepo -> FilePath -> Text -> IO Bool` — needs a `ConfigRepo` (built in `Serve.hs:109`); wrap in `try @SomeException` at the API handler (best-effort audit commit).
- **Frontend CRUD view**: `SkillsView.tsx` is the mirror (list + editor, empty/loading/error/submitting/confirming-delete states); `useSkills` + `streamClient` `skills-changed` for the WS hook; `TopBar.tsx` `TopSection` + `App.tsx` `sectionFromPath`/`pathFromSection` are the 3 closed-union sites for a new section.

## Security Invariants (must hold across all WUs)
- No secret value in `repos.toml` (vault key names only).
- No `ToJSON`/`FromJSON` on any secret carrier; redacted `Show` on `CloneTarget`.
- Token never in argv/URL/env (only the non-secret `GIT_ASKPASS` path is in env).
- Temp files (ASKPASS helper, deploy-key keyfile, known_hosts) under `repoCloneStateDir` (`spState </> "repos"`, 0700 parent), `O_EXCL` + `fchmod 0600/0700` + random suffix, `bracket` cleanup.
- Host allow-list (`github.com`) enforced at write (REST/slash validation) AND clone (`planClone` → `CloneHostNotSupported`).
- `CloneGitFailed Int` — exit code only, NO stderr.
- `RepoId` is never used to construct a `FilePath` (Map key only).
- `cUsername` is a public handle, not a secret.
- `/api/repos` mutators + `/repo` command are operator-only (gateway loopback; `UrlSafety` blocks the agent's web tools from loopback; `/repo` is `InteractiveOnly`).