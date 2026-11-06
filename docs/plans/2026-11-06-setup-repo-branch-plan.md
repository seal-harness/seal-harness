# SETUP_REPO: optional `branch` (clone from / check out a specific branch)

Status: draft rev 4 (post plan-review-gate iteration 3; every blocking finding
from iterations 1–3 addressed — see "Gate history" at the end)
Branch: `repo/setup-repo-branch`

## User request

> Add a new optional field to the "Start a new tab" form that lets the user
> specify a specific branch to clone from / check out on clone. This will also
> require adding this parameter to the SETUP_REPO opcode in the backend.

Clarified scope (user, 2026-11-06):

- Do **everything**: opcode + web API + web forms + CLI/chat `-b` flag +
  branch switch when the repo is already cloned.
- Do **not** persist the last-used branch in `ui_state.json` (explicitly out of
  scope).

## Design

### Wire surface

| Surface | Shape |
|---|---|
| `SETUP_REPO` opcode input | `{url: string, branch?: string}` |
| `POST /api/sessions/:id/setup-repo` body | `{url: string, branch?: string}` |
| `ui_state.json` | unchanged (branch NOT persisted) |
| `/new` flags (slash command, `seal serve`) | `-b BRANCH` / `--branch BRANCH` alongside `-p/-m/-r` |
| Frontend `setupRepo(sid, url, branch?)` | body `{url}` or `{url, branch}` |

`branch` is omitted (never `null`) when the field is empty — backward
compatible with every existing caller; `parseNewArgs` already ignores
unknown/absent flags.

### Security

`branch` is user/LLM input that reaches a subprocess argv, so it is carried by
a validated, smart-constructed newtype — not raw `Text`:

- `Seal.Tools.Args` (the documented home for argv newtypes,
  `src/Seal/Tools/Args.hs:1-9`): `newtype BranchName`, `mkBranchName :: Text ->
  Either Text BranchName`, `branchNameText`. Validation after trimming:
  non-empty, **not `HEAD`** (it names a commit, not a branch), no leading `-`
  (option injection), no git-refname-invalid characters (space `~ ^ : ? * [ \`,
  control chars, NUL), no `..`, no `@{`, no leading/trailing `/`, no `//`, no
  trailing `.`, no `.lock` suffix.
- Call sites emit a single argv token `--branch=<shell-quoted>` (never
  `--branch <value>`); every interpolated value goes through the existing
  `shellQ` (`src/Seal/ISA/Ops/Repo.hs:347-351`).
- Branch names are not secrets; nothing here touches `~/.seal/`.

### Credential plumbing for the branch switch

Verified facts (rev 2 got this wrong and it is corrected here):

- `ceGitConfigArgs` is `[]` in **every** shape `resolveCloneTarget` builds — PAT
  (`src/Seal/SourceControl/Clone.hs:379-390`), remote deploy key (`:437-455`),
  local deploy key (`:475-497`). The doc comment at `Clone.hs:297-300` is stale;
  `CloneSpec.hs:588` pins `ceGitConfigArgs env shouldBe []` for PAT.
- PAT/machine-user auth rides in `ceEnvExtras` as
  `GIT_CONFIG_PARAMETERS='http.extraHeader=Authorization: Basic …'` (+
  `GIT_TERMINAL_PROMPT=0`), raw token in `ceRawToken` (`Clone.hs:379-390`).
- `GIT_CONFIG_PARAMETERS` ∈ `secretEnvKeys`
  (`src/Seal/Tools/Exec/UntrustedIO.hs:518-524`), so `uioShellExecEnv`'s remote
  arm pipes secret extras over SSH **stdin** (`:702-723` →
  `runRemoteShellStdinEnv`), never into the command string.
- `uioShellExecGitEnv`'s remote arm instead renders extras into the remote
  command prefix (`:724-750`) — using it for a PAT switch would put the
  `Authorization: Basic …` header on the remote argv.

`switchBranch` therefore dispatches exactly like `cloneWithCredential`
(`Repo.hs:265-300`), selected by a pure exported function
`switchTransport :: Maybe ByteString -> SwitchTransport`
(`SwitchTransport = SwitchViaShellEnv | SwitchViaGitEnv`), documented against
`secretEnvKeys`:

| credential | executor arm |
|---|---|
| PAT / machine-user (`ceRawToken` = `Just`) | `uioShellExecEnv uio (ceEnvExtras env) cmd mCwdPath` — header via `GIT_CONFIG_PARAMETERS` (stdin on remote) |
| deploy key (`ceRawToken` = `Nothing`) | `uioShellExecGitEnv uio (ceEnvExtras env) (ceKnownHostsContent env) cmd mCwdPath` (agent forwarding, as in the clone) |
| unregistered URL | plain `uioShellExec` (public repo) |

### Clone semantics

`cloneRepoIO deps uio url mBranch`:

- fresh clone, no branch → `git clone --depth 1 -- <url> <name>` (unchanged)
- fresh clone, branch → `git clone --depth 1 --branch='<ref>' -- <url> <name>`
- PAT / machine-user → `gh repo clone <url> <name> -- --depth 1 --branch=<ref>`
  (`gh` forwards everything after `--` to `git clone`; the repo's gh shims and
  `parseGhCloneCmd` — `test/Seal/TestHelpers/ApiTestHarness.hs:649-700` — parse
  only the URL, so trailing args are tolerated)
- deploy key → `git clone --depth 1 --branch='<ref>' -- <url> <name>` with the
  agent-forwarding env

Idempotency: the existing pre-clone probe (`Repo.hs:213-228`) grows a second
output line — `git -C <name> rev-parse --abbrev-ref HEAD` — parsed by a new
exported pure `parseRepoProbe :: Text -> (Text, Maybe Text)`. It must tolerate a
**one-line** response: the remote test fixture replies `"__NONE__\n"`
(`ApiTestHarness.hs:618-625`, keyed on the `remote.origin.url` substring); a
missing second line is `Nothing` = "current branch unknown".

| Existing dir | requested branch | Result |
|---|---|---|
| none | any | clone |
| same URL, no branch requested | — | `CloneNoop` (unchanged) |
| other URL | — | `CloneConflict` (unchanged) |
| same URL, current branch known and == requested | → `CloneNoop` |
| same URL, current branch differs / unknown / detached (`HEAD`) | → `switchBranch` → `CloneSwitched name ref` or `CloneFailed` |

`git rev-parse --abbrev-ref HEAD` prints the literal `HEAD` for a detached
checkout, so a detached repo always takes the switch path — the intended
recovery; `branch: "HEAD"` is rejected up front so the ambiguous input cannot
occur.

`switchBranch` command (one `uioShellExec*` string, user values `shellQ`'d):

```
if git -C '<name>' rev-parse --verify --quiet 'refs/heads/<ref>' >/dev/null
then git -C '<name>' checkout '<ref>'
else git -C '<name>' fetch --depth 1 origin 'refs/heads/<ref>:refs/heads/<ref>' \
     && git -C '<name>' checkout '<ref>'
fi
```

then verify with `git -C <name> rev-parse --abbrev-ref HEAD`; a mismatch is
`CloneFailed` with git's output (dir, checkout and any work preserved — the dir
is never deleted). On success re-run `tryCodegraphInit` (else the graph
describes the old branch) and return `CloneSwitched`.

The **fully-qualified `refs/heads/<ref>` refspec** (rev 2 used a bare `<ref>`)
means the fetch resolves branch refs only — no DWIM, no tag→branch surprise: a
tag name on the switch path fails with git's "couldn't find remote ref" message
(tags are supported on the initial clone via `--branch=<tag>`, which yields a
detached HEAD; a later branch switch recovers from it). The existing-local-branch
arm is a plain `checkout`, exact because the ref was just verified to exist.

User-facing text: a new exported pure
`renderCloneResult :: Text -> Maybe Text -> CloneResult -> Text`
(url, requested branch, result) — the branch is a parameter because
`CloneCloned`/`CloneNoop` carry only the repo name (`Repo.hs:189-193`; rev 2's
one-argument signature could not name the branch). It names the branch for
`cloned`/`noop`/`switched` and is tested for **all five** constructors, with and
without a branch. `CloneSwitched` maps to a **non-error** `OpResult`
(`orIsError = False`, status `"switched"`) so `TurnEngine`'s post-repo hooks
(`src/Seal/Core/TurnEngine.hs:1122-1145`) still run.

Audit: `orRecorded` stays `{target, status}` — no `recordWith` change. The
branch is audited via the opcode's raw `input`, recorded by
`recordSetupRepoResult` (`src/Seal/ISA/Dispatch.hs:270-274`), and that is also
the source the frontend reads (below).

### Opcode input parsing + run seam

`uoAuthorize` and `uoRun` share one exported pure parser,
`parseSetupRepoInput :: Value -> Either Text (Text, Maybe BranchName)`
(`validateRepoUrl` + `mkBranchName`). `uoRun` = `parseSetupRepoInput` →
`runSetupRepo`, and **`runSetupRepo` is exported** so the clone-through-the-opcode
path is testable without a network-valid URL (`file://` is rejected by
`validateRepoUrl`, as `RepoSpec.hs:179-184` documents — so the end-to-end test
drives `runSetupRepo` with a `file://` clone while `parseSetupRepoInput` covers
the URL/branch extraction it sits behind).

## Work units (TDD: failing test first, then minimal implementation)

Ordering note: the `handleSetupRepo`, `ndSetupRepo` and `newCmd` call-site
arity changes are mutually dependent, so they land in **one** compile unit
(WU-3, which now lists `src/Seal/Command/New.hs` and passes `Nothing` there;
WU-4 threads `naBranch`). Every work unit ends with a compiling, green tree.

### WU-1 — `BranchName` validated newtype

Files: `src/Seal/Tools/Args.hs`, `test/Seal/Tools/ArgsSpec.hs`.

- [ ] Tests: accepts `main`, `feature/foo-bar`, `release-1.2`, `v1.0.0`;
  rejects empty/whitespace, `HEAD`, `-x`/`--upload-pack=x`, `a b`, `a..b`,
  `a~b`, `a^b`, `a:b`, `a?b`, `a*b`, `a[b`, `a\b`, `a@{b`, `/a`, `a/`, `a//b`,
  `a.`, `a.lock`, NUL/control chars; trims surrounding whitespace.
- [ ] QuickCheck props (`ArgsSpec.hs:17-27` style): a `Right` never starts with
  `-`, never contains a refname-invalid char, round-trips through
  `branchNameText`.
- [ ] Implement + export `BranchName` / `mkBranchName` / `branchNameText`.

### WU-2 — SETUP_REPO opcode + clone plumbing

Files: `src/Seal/ISA/Ops/Repo.hs`, `test/Seal/ISA/Ops/RepoSpec.hs`.

- [ ] `parseSetupRepoInput`: `{url}` → `(url, Nothing)`; `{url, branch:"dev"}`
  → `(url, Just "dev")`; `{url, branch:""}` → `(url, Nothing)`; invalid branch
  → `Left`; missing url → `Left`.
- [ ] `parseRepoProbe`: two-line (url + branch), one-line (url only → `Nothing`),
  `__NONE__`, detached (`HEAD`).
- [ ] `renderCloneResult`: all five constructors × (branch `Nothing` / `Just`),
  pinning that the branch appears in `cloned`/`noop`/`switched`.
- [ ] **End-to-end through the opcode's run seam**:
  `runUIOWithEnv (mkTestUIOEnv uio deps) (runSetupRepo deps fileUrl (Just branch)
  (object []))` with `uio = mkLocalUntrustedIO (WorkspaceRoot wd)` and `deps`
  from `mkTestCloneDeps` — assert the result text names the branch,
  `orIsError = False`, the recorded status is `"cloned"`, and
  `git -C <name> rev-parse --abbrev-ref HEAD` == the branch.
  (`mkTestUIOEnv` from `Seal.Tools.Exec.UIO.Internal` + `runUIOWithEnv` from
  `Seal.Tools.Exec.UIO` are already used this way —
  `test/Seal/Gateway/PatIngestionSpec.hs:84-85`.)
- [ ] `cloneRepoIO` end-to-end (real git, `file://`): clone with branch →
  HEAD == branch and the branch tip's file content; clone with a tag → detached
  HEAD at the tag; clone with a nonexistent ref → `CloneFailed`.
- [ ] Switch path (real git, `file://`): different branch not local → `CloneSwitched`
  + HEAD moved (fetch arm); different branch **already local** → HEAD moved
  (checkout arm); same branch → `CloneNoop`; detached repo + branch →
  `CloneSwitched`; a **tag** name → `CloneFailed` (branch-only refspec);
  ref absent from the remote → `CloneFailed`, HEAD unchanged, tree intact.
- [ ] **Credentialed switch, hermetic** (closes "registered switch verified only
  by construction"): build a registry handle seeded with a PAT repo whose URL is
  `https://github.com/o/r.git` (`RepoRegistryHandle` is a two-field record —
  `src/Seal/SourceControl/Registry.hs:115`, precedent in
  `test/Seal/Command/NewSpec.hs:41-45`) + a fake vault holding the vault key
  (`makeFakeVaultRuntime`), and a **recording `UntrustedIO`** built as
  `mkRemoteUntrustedIOStub { uioShellExec = …, uioShellExecEnv = …,
  uioShellExecGitEnv = … }` (the constructor is exported and this exact
  record-update pattern already exists —
  `test/Seal/Gateway/PatIngestionSpec.hs:86-142` `ghFakeUio`). The fake answers
  the probe (`…\nmain`), the fetch/checkout, and the `rev-parse` verify (`dev`),
  recording each call. Assertions: `CloneSwitched`; the fetch went through
  `uioShellExecEnv` with `GIT_CONFIG_PARAMETERS` in the extras (i.e. the secret
  rides the stdin-capable arm) and **not** through `uioShellExecGitEnv`; a
  deploy-key repo (no `ceRawToken`) uses `uioShellExecGitEnv` instead. Plus
  `switchTransport` unit cases.
- [ ] `uoInSchema` gains the optional `branch` property; `uoAuthorize` rejects
  `branch: "-x"` / `branch: "HEAD"` and accepts `branch: "dev"`.
- [ ] Implement: `cloneRepoIO` / `cloneBareUrl` / `cloneWithCredential` take
  `Maybe BranchName`; branch-aware probe; `switchBranch` + `switchTransport`;
  `CloneSwitched`; `renderCloneResult`; `tryCodegraphInit` on switch; export
  `parseSetupRepoInput`, `parseRepoProbe`, `renderCloneResult`,
  `switchTransport`, `runSetupRepo`.

### WU-3 — Gateway wiring + arity changes (one compile unit)

Files: `src/Seal/Gateway/Send.hs`, `src/Seal/Gateway/API.hs`,
`src/Seal/Command/New.hs`, `src/Seal/Command/Serve.hs`,
`test/Seal/Gateway/ApiSpec.hs`, `test/Seal/Gateway/SendSpec.hs`.

- [ ] Tests:
  - `parseSetupRepoBody` (exported from `Seal.Gateway.API`, replacing
    `parseRepoUrl`): `{"url":u}` → `(u, Nothing)`; `{"url":u,"branch":"dev"}` →
    `(u, Just "dev")`; blank branch → `(u, Nothing)`; non-string branch →
    `(u, Nothing)`; missing/blank url → `Nothing`.
  - `validateSetupRepoArgs` + `setupRepoInput` (exported pure from
    `Seal.Gateway.Send`): invalid branch → `Left` containing `invalid branch`;
    blank branch → `Right (url, Nothing)`; dispatch payload is exactly
    `{"url":u}` or `{"url":u,"branch":b}`.
  - **`handleSetupRepo` rejects an invalid branch before touching disk**
    (SendSpec): `handleSetupRepo deps "any-sid" "https://github.com/o/r"
    (Just "bad;branch")` → `Left "invalid branch: …"` — no session, no
    dispatcher needed (validation precedes `loadSessionMeta`).
  - `handleSetupRepoResponse` (exported from `Seal.Gateway.API`): `Left` → 400,
    `Right msg` → 200 `{ok:true,message}`.
- [ ] `handleSetupRepo :: SendDeps -> SessionId -> Text -> Maybe Text -> IO
  (Either Text Text)` = `validateSetupRepoArgs` → dispatch `setupRepoInput`.
- [ ] API route parses `{url, branch?}` and forwards it.
- [ ] `ndSetupRepo :: Maybe (SessionId -> Text -> Maybe Text -> IO (Either Text
  Text))` in `src/Seal/Command/New.hs`; its one call site
  (`New.hs:161-164`) passes `Nothing` in this WU; `Serve.hs:256` keeps
  `ndSetupRepo = Just (handleSetupRepo sendDeps)`; `src/Seal/Tui.hs:176` and
  `test/Seal/Command/NewSpec.hs:57` keep `Nothing`.
- [ ] Run the existing PAT SETUP_REPO integration suite unchanged
  (`test/Seal/Gateway/ApiIntegrationSpec.hs`) as the regression proof that the
  two-line probe coexists with the one-line fixture response.

### WU-4 — Slash command `/new -b` (registry + `seal serve`)

Files: `src-gateway-types/Seal/Gateway/Types/NewArgs.hs`,
`src/Seal/Command/New.hs`, `test/Seal/Command/NewSpec.hs`.

Note: there is no `seal new` subcommand (`src/Seal/Types/Command.hs:15-19`);
`/new` is a slash command registered by `Serve.hs:288` and `Tui.hs:198`. In
`seal tui` the repo seam is unwired, so `-b` — like `-r` today — is parsed but
inert; in `seal serve` it dispatches. Pinned in tests.

- [ ] Tests: `parseNewArgs "-r seal -b dev"` → `naRepo = Just "seal"`,
  `naBranch = Just "dev"`; `--branch main`; absent → `Nothing`; all existing
  `-p/-m/-r` cases unchanged; `-b` without `-r` performs no repo setup.
  The seam assertion runs the action for real: parse with `execParserPure` over
  `csParserInfo (newCommandSpec deps)` and execute it with
  `runCommandAction` (`src/Seal/Command/Spec.hs:50`) against a `NewDeps` whose
  `ndSetupRepo = Just (recording seam)` — assert the seam receives
  `Just "dev"`.
- [ ] `NewArgs` gains `naBranch` (+ `emptyNewArgs`), `parseNewArgs` learns
  `-b`/`--branch`, `branchOpt` added to the optparse command, synopsis/help
  updated, `newCmd` threads it into `ndSetupRepo`.

### WU-5 — Chat-channel `/new -b`

Files: `src-chat-channels/Seal/Channels/Chat/HttpClient.hs`,
`src-chat-channels/Seal/Channels/Chat/Loop.hs`,
`test/Seal/Channels/Chat/HttpClientSpec.hs`,
`test/Seal/Channels/Chat/LoopSpec.hs`.

- [ ] Tests: `setupRepoBody u Nothing` → `{"url":u}` (unchanged shape);
  `setupRepoBody u (Just "dev")` → `{"url":u,"branch":"dev"}`;
  `handleInbound "/new -r seal -b dev"` dispatches that body to the NEW session.
- [ ] `setupRepoBody :: Text -> Maybe Text -> Value`; `setupRepoFor` takes the
  branch; `handleNewSession` threads `naBranch`.

### WU-6 — Frontend: form field + result rendering

Files: `frontend/src/hooks/useApi.ts`, `frontend/src/hooks/useNewTabSpec.ts`,
`frontend/src/hooks/useTranscriptMessages.ts`,
`frontend/src/components/NewTabComposer.tsx`,
`frontend/src/components/ChatArea.tsx`,
`frontend/src/hooks/__tests__/useNewTabSpec.test.ts`,
`frontend/src/hooks/__tests__/useApi.test.ts`,
`frontend/src/hooks/__tests__/transcriptRendererParity.test.ts`,
`frontend/src/hooks/__tests__/useTranscriptMessages.test.ts`,
`frontend/src/components/__tests__/NewTabComposer.test.tsx`,
`frontend/src/components/__tests__/ChatArea.test.tsx`.

- [ ] Tests: hook exposes `repoBranch`/`setRepoBranch`; composer renders the
  "Branch" field only when a repo URL is entered; submitting calls
  `setupRepo(sid, url, 'dev')`; empty branch → `setupRepo(sid, url, undefined)`;
  `setupRepo` sends `{url}` with no branch and `{url, branch}` with one;
  `makeSpec` in `NewTabComposer.test.tsx` gains `repoBranch: ''` +
  `setRepoBranch`; **negative persistence test**: the `putUiState`
  (`last_options`) payload contains no `branch`/`repoBranch` key.
- [ ] **Result rendering**: both SETUP_REPO summary mappers
  (`useTranscriptMessages.ts:128-141`, `ChatArea.tsx:2010-2035`) gain a
  `switched` case and append the branch — **read from
  `parsed.input.branch`** (the opcode input recorded by
  `recordSetupRepoResult`), *not* from `result` (which stays `{target,
  status}`). Pinned in `ChatArea.test.tsx` (the existing `'Cloned into bar'`
  case extended), `useTranscriptMessages.test.ts`, and
  `transcriptRendererParity.test.ts`. `toolCallSummary`
  (`ChatArea.tsx:800-816`) appends the branch to the inline arg preview.
- [ ] `setupRepo(sessionId, url, branch?, timeoutMs?)` — branch before
  `timeoutMs` (no caller passes `timeoutMs`).
- [ ] `useNewTabSpec`: `repoBranch` state + setter, **not** persisted (no
  `LastOptions`/`ui_state.json` change).
- [ ] `NewTabComposer`: optional "Branch" input under "Set up repo"
  (placeholder "branch or tag (optional — default branch)"), passed on submit.
  An invalid branch still creates the tab first and surfaces in the existing
  repo-warning banner + transcript — the same create-then-report ordering as
  today's clone failures.

### WU-7 — Docs + verification

Files: `README.md`, `config/skills/core/seal-usage.md`.

- [ ] `README.md:210-217` gains a `/new -r <repo-id> -b <branch>` example.
- [ ] `config/skills/core/seal-usage.md:183-206` — "SETUP_REPO does a shallow
  clone of the default branch only" is updated: `branch` is a SETUP_REPO
  argument and a re-clone switches branches.
- [ ] `make check` (build with `-Werror`, full suite, hlint) green.
- [ ] `cd frontend && npm test` and `npm run build` (tsc) green.
- [ ] Commit per work unit; ask the user whether to file an issue and open a
  draft PR (`Closes #NN`).

## Non-goals

- No `ui_state.json` persistence of the branch (user decision).
- **`NewSessionComposer` is left unchanged** — it has no mount site (only its
  own test imports it; `App.tsx:1062` mounts `NewTabComposer`), so adding a
  field there would be UI on dead code. The shared hook still exposes
  `repoBranch` if that composer is ever mounted.
- No branch field on the Repos-tab registration form.
- No multi-branch / `--single-branch` toggles, no depth configuration.
- No `branch_from` change (transcript branching) — unrelated field.

## Accepted behaviors (documented, tested)

- Branch on a fresh clone → `--branch=<ref>`; a tag ref yields a detached HEAD.
- Switch to a tag name → `CloneFailed` (branch-only refspec); switch back to a
  branch from a detached checkout works.
- Switch failure → `CloneFailed`, repo and working tree untouched.

## Risks / rollback

- `CloneResult` gains a constructor: exhaustive matches exist only in
  `ISA.Ops.Repo`; `RepoSpec` uses catch-alls.
- `cloneRepoIO` / `handleSetupRepo` / `ndSetupRepo` / `setupRepoBody` /
  `setupRepo` change arity → compile-time breakage, no silent behavior change.
- The pre-clone probe gains a second line and a new parser; the one-line remote
  fixture response is covered by `parseRepoProbe` tests and the existing PAT
  integration suite.
- Reverting = revert the single branch; the wire format is additive.

## Gate history

| Iter | Feasibility | Completeness | Scope | Blocking issues resolved in the next rev |
|---|---|---|---|---|
| 1 | FAIL | FAIL | PASS | WU-3/WU-4 compile cycle; phantom `seal new` CLI claim; no credential path for private-repo switch; `CloneSwitched` unspecified; no 400 test; unverifiable `recordWith` claim |
| 2 | FAIL | FAIL | FAIL | wrong `ceGitConfigArgs` claim (PAT header rides `ceEnvExtras`/`GIT_CONFIG_PARAMETERS` → must use `uioShellExecEnv`, not `uioShellExecGitEnv`); detached HEAD; tag-vs-branch on switch; one-line probe fixture; no opcode-input→clone test; no frontend rendering of `switched`/branch |
| 3 | FAIL | FAIL | FAIL | `file://` rejected by the opcode (→ test `runSetupRepo` + `parseSetupRepoInput` instead); `renderCloneResult` needs the branch parameter; frontend branch source is `input`, not `orRecorded`; `NewSessionComposer` dropped (unmounted); `New.hs` moved into WU-3; switch refspec made branch-explicit; hermetic credentialed-switch test via a recording `UntrustedIO`; WU-4 verification names `runCommandAction` |
