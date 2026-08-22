# `gh` CLI Credential Injection via BIN_EXEC

**Issue**: (to be filed)
**Branch**: `feat/gh-bin-exec-credential-injection`
**Date**: 2026-08-21
**Status**: Design — revised after review gate (v2)

## Review gate outcome (v1 → v2)

Three reviewers (Architect, Security, CTO) reviewed v1. The CTO passed
with non-blocking recs; the Architect and Security found one shared
**blocker** and two **required changes**, addressed below:

- **B1 (BLOCKER): `GH_TOKEN` would be logged in plaintext by
  `logExecDebug`.** `UntrustedIO.hs:506-528` renders env extras as
  `KEY=VAL` tokens at `DebugS` level. On the local arm
  (`UntrustedIO.hs:437`) the `extras` list includes `("GH_TOKEN",
  <token>)`; on the remote arm (`UntrustedIO.hs:679-687`) the token is
  baked into the SSH command string that becomes `logExecDebug`'s argv.
  Either path writes the raw token to the debug log → if a log shipper
  captures stderr or the operator redirects to a file, the token lands
  on disk un-encrypted, violating AGENTS.md rule 3 ("Never log secrets")
  and the "no un-encrypted secret on disk" invariant. **Fix:** §3.7
  (new) specifies a redaction seam in `logExecDebug`; §6 adds
  `UntrustedIO.hs` to the file scope.
- **C1 (REQUIRED): `extractGhRepoFlag` parser gaps.** v1's test plan
  covered `-R v` (test #6) and `--repo=v` (test #7) but missed
  `-Rv` (joined short) and `--repo v` (space long). Missing `-Rv` is a
  credential-scope bypass: the agent could craft `gh -Rowner/other pr
  create` from a workdir whose `origin` is registered repo A; the
  parser returns `Nothing` → repo A's token is injected → `gh` acts on
  `other` with repo A's credential. **Fix:** §3.2 enumerates all four
  forms; §5.1 adds red tests for `-Rv` and `--repo v`.
- **C2 (REQUIRED): File scope must include `UntrustedIO.hs`.** v1 §6
  said "No changes to `UntrustedIO`" — that claim was wrong (B1 requires
  it). **Fix:** §6 lists `UntrustedIO.hs`.

Additional non-blocking revisions adopted from the CTO and reviewers:
- §4.1 documents the credential-class trade-off (operators wanting `gh`
  must register a PAT/MachineUser; deploy-key repos are unaffected).
- §3.5 makes the `-R`/`--repo` skip **observable** via a non-secret
  NOTE in `orParts` (not `orRecorded`), so the agent learns the skip was
  deliberate rather than seeing an opaque `gh` auth error.
- §3.4 corrects the false claim that "`CloneEnv` is already redacted
  via `Show`" — `CloneEnv` has **no** `Show` instance (by design); the
  security property is CPS-scoping via `withCloneTarget`, not `Show`.
  The implementer must NOT add `deriving stock Show` to `CloneEnv`.
- §4.4 distinguishes "overwrite" (`GH_TOKEN`) from "shadow by
  precedence" (`GITHUB_TOKEN`), and notes the CI-runner edge.
- §5.1 adds a red test that the raw token never appears in `show` /
  serialized output of a `CloneEnv` (the CTO's `CloneSpec` redaction
  test).
- §3.5 uses byte-accurate env injection (`BS.unpack`) instead of
  `decodeUtf8Lenient` to avoid corrupting non-ASCII tokens.
- §9 (Open Questions) notes `gh` should NOT be in any curated default
  allow-list (it can create/merge PRs, delete branches, manage repo
  secrets, run Actions workflows).

## 1. Problem

SSH-key authentication now works for `git` operations in both remote and
local modes (the `BIN_EXEC` git-credential-injection path: pre-flight resolves
the cwd's `remote.origin.url`, looks it up in the repo registry, and injects
the registered credential — `SSH_AUTH_SOCK`/`GIT_SSH_COMMAND` for deploy
keys, `http.extraHeader` argv for PATs). The `gh` command-line tool,
however, still fails for operations that require auth (notably
`gh pr create`, `gh pr merge`, `gh pr edit`), because `gh` does not consume
the SSH agent or `http.extraHeader` — it authenticates via a token in
`GH_TOKEN`/`GITHUB_TOKEN`, the `~/.config/gh/hosts.yml` keyring file, or an
interactive `gh auth login` flow that is unavailable in an untrusted
sandbox.

The agent has no way today to make an authenticated `gh` call without the
operator pre-running `gh auth login` on the untrusted machine (which stores
a token in a keyring file on disk — a second secret-on-disk surface the
harness explicitly avoids), or the model itself fabricating a token (it
has none). The result: `gh pr create` fails opaquely with an auth error,
and the operator has no clean path to fix it.

The hard requirement (unchanged from the git design): **un-encrypted secrets
MUST NEVER be written to disk** — on either the untrusted execution machine
or the trusted harness machine. The vault holds the token (age-encrypted at
rest); `gh` receives it only in its process environment (memory), never in
argv, never in a keyring file, never in the transcript.

## 1a. Use Cases (WHO / WANTS / SO THAT / WHEN)

The primary personas are the **operator** (registers repos + credentials,
unlocks the vault) and the **agent** (calls `BIN_EXEC` with `binary="gh"`;
never sees credentials).

1. **Agent opens a PR via `gh`** — *As* an agent, *I want* to call
   `BIN_EXEC` with `binary="gh"` and `args=["pr","create",...]` from inside
   a registered repo's workdir and have it authenticate transparently using
   the repo's registered credential, *so that* I spend zero tokens on
   credential reasoning and the PR opens on the first try, *when* I finish
   work on a branch and need to publish it.
2. **Agent runs a `gh` op on a repo with a deploy-key credential** — *As*
   an agent, *I want* a clear, fast fall-through (plain exec, no credential
   injection) when the repo is registered with a deploy key, *so that*
   `gh` doesn't fail opaquely trying to use an SSH key it can't consume,
   and the operator learns that `gh` needs a PAT/MachineUser credential,
   *when* the repo's credential kind doesn't match what `gh` can use.
3. **Agent runs `gh` in an unregistered repo** — *As* an agent, *I want*
   `gh` to run via plain `BIN_EXEC` (no injection) and surface `gh`'s own
   auth error, *so that* the failure is honest and the operator can
   register a credential or run `gh auth login` on the untrusted machine
   intentionally, *when* the cwd is not inside a registered repo.
4. **Agent runs `gh` outside any git repo** — *As* an agent, *I want* the
   pre-flight `git config --get remote.origin.url` to return empty and
   `gh` to run via plain `BIN_EXEC`, *so that* operations like
   `gh auth status` or `gh repo view owner/name` still work with whatever
   ambient auth `gh` finds, *when* the cwd has no `origin` remote.
5. **Operator hits a locked vault during a `gh` op** — *As* an operator,
   *I want* a clear, actionable error ("vault locked — run /vault unlock"
   or "vault key `<name>` not found") when an agent's `gh` op fails at
   credential-resolution time, *so that* I can unlock the vault or store
   the key rather than seeing a generic `gh` auth failure, *when* the
   vault is locked or the key is missing.
6. **Operator registers a PAT/MachineUser for `gh` use** — *As* an
   operator, *I want* the same PAT/MachineUser credential that works for
   `git` HTTPS clone to also work for `gh` with no extra configuration,
   *so that* a single registered credential covers both `git push` and
   `gh pr create`, *when* I register a repo with a PAT or MachineUser
   credential.

## 2. Non-Goals

- **No new opcode.** This is a `BIN_EXEC` behavior extension, mirroring the
  existing `git` branch. There is no `GH_EXEC` opcode.
- **No `gh` allow-list policy.** Whether `gh` is permitted at all is the
  operator's existing allow-list decision (`sbAllowList` on `BIN_EXEC`).
  This design only adds credential injection when `gh` is already
  permitted and called.
- **No keyring-file path.** We do not write `~/.config/gh/hosts.yml` or
  run `gh auth login --with-token`. Both write a token to disk on the
  untrusted machine. The token lives only in the `gh` process env.
- **No deploy-key support for `gh`.** `gh` cannot consume an SSH agent.
  Deploy-key-registered repos fall through to plain exec. The operator
  who wants `gh` must register a PAT or MachineUser credential. This is
  documented, not silently worked around.
- **No remote-vs-local split in the credential path.** Unlike the git
  deploy-key path (which needs `ssh -A` agent forwarding on remote), the
  `gh` token-in-env injection is identical on local and remote — it's a
  single `[(String, String)]` env-override list passed to
  `uioBinExecEnv`, the same seam the `git` PAT path already uses.

## 3. Design

### 3.1 The `gh` branch in `BIN_EXEC.uoRun`

The opcode's `uoRun` already branches on `textBinName bin == "git"` →
`runGitWithCredentials`. Add a sibling branch:

```haskell
if textBinName bin == "git"
  then runGitWithCredentials bin args mCwdPath recorded
  else if textBinName bin == "gh"
    then runGhWithCredentials bin args mCwdPath recorded
    else do  -- plain exec
      ...
```

`runGhWithCredentials` mirrors `runGitWithCredentials` exactly in shape
(reuse the same pre-flight, registry lookup, and credential resolution)
but differs in the final exec step.

### 3.2 Pre-flight: resolve `remote.origin.url` (REUSED)

`gh` resolves the "current repo" from the cwd's `git` config the same way
`git` does — it shells out to `git config` internally. The existing
`resolveRemoteUrl` (Bin.hs:222) already runs `git config --get
remote.origin.url` via `uioBinExec` and parses `-C <path>` /
`--git-dir=<path>` from the argv. **Reuse it verbatim** — no new
pre-flight code. The `gh` branch passes the `gh` argv (which may contain
`-C <path>` for `gh`'s own repo-selection flag) to the same extractor.

Wait — `gh`'s repo-selection flag is `-R owner/repo` (or `--repo`), NOT
`-C`. `gh -R owner/repo pr create` does NOT consult the cwd's git config.
Two sub-cases:

- **No `-R`/`--repo` flag:** `gh` uses the cwd's `origin`. Pre-flight via
  `resolveRemoteUrl` (same as `git`) — correct.
- **`-R`/`--repo owner/repo` present:** `gh` ignores the cwd entirely. The
  pre-flight `git config` would return the cwd's `origin` (if any), which
  may be a *different* repo than the one `gh` will act on. Injecting the
  cwd-repo's credential for a `-R`-targeted `gh` call would authenticate
  `gh` to the wrong account/token — a confusing failure (token valid but
  no permission on the `-R` repo), not a leak.

  **Decision:** when `gh`'s argv contains `-R`/`--repo`, **skip credential
  injection** and fall through to plain `uioBinExec`, surfacing a
  non-secret NOTE in `orParts` so the agent learns the skip was
  deliberate (§3.5). The operator who wants `gh` to act on a different
  repo than the cwd's `origin` must either run `gh` from that repo's
  workdir (so cwd ≡ `-R` target) or accept that `gh` uses ambient auth.
  This is the conservative, honest choice: we inject a credential only
  when we're sure which repo `gh` is acting on.

  This is a **new pure helper**: `extractGhRepoFlag :: [Text] -> Maybe
  Text` — returns `Just "owner/repo"` if `-R`/`--repo` is present (so
  `runGhWithCredentials` can detect "skip injection"), `Nothing`
  otherwise. Mirrors `extractGitDir`'s shape and placement. **Must
  handle all four pflag/cobra forms** (verified against `gh`'s cobra
  flag parser):

  | Form | Example | Handled |
  |---|---|---|
  | `-R` space-separated short | `gh -R owner/repo pr create` | ✓ |
  | `-R` joined short (`-Rv`) | `gh -Rowner/repo pr create` | ✓ |
  | `--repo` space-separated long | `gh --repo owner/repo pr create` | ✓ |
  | `--repo=` joined long | `gh --repo=owner/repo pr create` | ✓ |

  The helper scans the **entire** argv (global flags may appear after
  the subcommand: `gh pr create -R owner/repo` is valid). It returns
  the **first** `-R`/`--repo` value (the return value is only used for
  the skip decision — "is `-R` present?" — not for credential lookup,
  so first-vs-last is irrelevant). Mirrors `extractGitDir`
  (`Bin.hs:310-323`) which handles both space and joined forms for
  `-C`/`--git-dir=`.

### 3.3 Registry lookup + credential resolution (REUSED)

Once the pre-flight yields a remote URL (and no `-R` flag was present),
the flow is identical to `git`'s:

1. `uioCdRepoRegList` → the repo registry.
2. `lookupRepoByUrl remoteUrl registry` → `Maybe SourceRepo`.
3. `Nothing` → fall through to plain `uioBinExec` (unregistered repo).
4. `Just repo` → `uioResolveClone repo` → `Either CloneError CloneEnv`.

The `CloneEnv` is the same credential-resolution result `git` uses. For
`gh`, we only care about one field: `ceEnvExtras` — and only for the
PAT/MachineUser case.

### 3.4 The credential-kind branch (NEW — this is the only real new logic)

`gh` authenticates via a token in `GH_TOKEN` (or `GITHUB_TOKEN`;
`GH_TOKEN` takes precedence per `gh`'s docs). The token must be the *raw*
PAT/MachineUser token, not the base64-encoded Basic-auth header that
`git`'s `http.extraHeader` uses. So `gh` cannot reuse `ceGitConfigArgs`
(the `http.extraHeader=Authorization: Basic ...` argv) — it needs the
*raw token bytes* in an env var.

The existing `resolveCloneTarget` returns a `CloneEnv` whose
`ceGitConfigArgs` carries the rendered header, but the raw token never
escapes `resolveCloneTarget` as a structured field — it's folded into the
header string. **We need the raw token.** Two options:

- **Option A:** Extend `CloneEnv` with a new field
  `ceRawToken :: Maybe ByteString` carrying the raw token for PAT /
  MachineUser (Nothing for deploy keys). `resolveCloneTarget` populates
  it. The `gh` path reads `ceRawToken` and injects `GH_TOKEN=<token>` into
  the env. The `git` path ignores it (it uses `ceGitConfigArgs`).
  Pros: minimal change, single resolution call, no double vault fetch.
  Cons: adds a secret-carrying field to `CloneEnv`.

  Note on the security argument (corrected after review): `CloneEnv`
  **already** carries secret-adjacent data — `ceGitConfigArgs` holds the
  base64 PAT header (trivially reversible to the raw token). So
  `ceRawToken` is the **same security category** as the existing
  fields. The security property is **CPS-scoping**: `CloneTarget`'s
  constructors are unexported, and the only way to obtain a `CloneEnv`
  is inside `withCloneTarget target $ \cloneEnv -> ...` (bracket). The
  `ceRawToken` *accessor* is exported (the field is exported with
  `CloneEnv(..)`), but the *value* is not obtainable outside the CPS
  continuation. `CloneEnv` has **no `Show` instance by design** (its
  `ceCleanup :: IO ()` field prevents derivation; the type is
  deliberately `Show`-less so a stray `show`/log/exception cannot leak
  any field). The implementer must NOT add `deriving stock Show` to
  `CloneEnv`.

- **Option B:** Add a new resolution seam
  `resolveGhToken :: CloneDeps -> SourceRepo -> IO (Either CloneError
  ByteString)` that fetches just the raw token. The `gh` path calls it
  instead of `uioResolveClone`/`uioWithClone`.
  Pros: no change to `CloneEnv`.
  Cons: duplicates the vault-fetch + plan logic; two code paths to keep
  in sync; `resolveGhToken` would re-run `planClone` and re-fetch from
  the vault (a second `vhGet`).

**Decision: Option A.** `CloneEnv` is already a redacted, CPS-scoped,
secret-adjacent type (it carries `ceSshCommand` which references a
temp-file path that *is* secret-protecting). Adding `ceRawToken` is the
same security category. Option A avoids a second vault fetch and keeps
one resolution path. The field is `Maybe` (deploy keys → `Nothing` → the
`gh` path sees "no token for this credential kind" and falls through to
plain exec, matching the non-goal).

### 3.5 The `gh` exec step (NEW)

```haskell
runGhWithCredentials bin args mCwdPath recorded = do
  -- If gh's argv contains -R/--repo, skip injection (gh acts on a
  -- different repo than the cwd's origin). Surface a non-secret NOTE
  -- so the agent learns the skip was deliberate, not an opaque auth
  -- failure.
  case extractGhRepoFlag (map textBinArg args) of
    Just _ -> do
      res <- uioBinExec bin args mCwdPath
      pure $ case res of
        Left err -> OpResult [TrpText (renderUntrustedErr err)] True recorded
        Right out -> OpResult
          [ TrpText out
          , TrpText "BIN_EXEC: gh -R/--repo detected — credential injection skipped (gh uses ambient auth). Run gh from the target repo's workdir for credential injection."
          ] False recorded
    Nothing -> do
      mRemoteUrl <- resolveRemoteUrl gitBin args mCwdPath
      case mRemoteUrl of
        Left err -> pure (OpResult [TrpText err] True recorded)
        Right Nothing -> do  -- not a git repo / no origin
          res <- uioBinExec bin args mCwdPath
          pure $ case res of ...
        Right (Just remoteUrl) -> do
          eRepos <- uioCdRepoRegList
          case eRepos of
            Left err -> pure (OpResult [TrpText ("BIN_EXEC: repo registry error: " <> err)] True recorded)
            Right repos -> do
              let registry = RepoRegistry (Map.fromList [(srId r, r) | r <- repos])
                  mRepo = lookupRepoByUrl remoteUrl registry
              case mRepo of
                Nothing -> do  -- unregistered → plain exec
                  res <- uioBinExec bin args mCwdPath
                  pure $ case res of ...
                Just repo -> do
                  eTarget <- uioResolveClone repo
                  case eTarget of
                    Left cloneErr -> pure (OpResult [TrpText ("BIN_EXEC: credential resolution failed: " <> renderCloneError cloneErr)] True recorded)
                    Right target -> uioWithClone target $ \cloneEnv ->
                      case ceRawToken cloneEnv of
                        Nothing -> do
                          -- Deploy key: gh can't use SSH. Fall through
                          -- to plain exec (gh surfaces its own auth error).
                          res <- uioBinExec bin args mCwdPath
                          pure $ case res of ...
                        Just tokenBytes -> do
                          -- Byte-accurate env injection: map each byte
                          -- 1:1 to a Char via BS.unpack (avoids the
                          -- U+FFFD corruption of decodeUtf8Lenient on
                          -- non-UTF-8 tokens — mirrors renderPatHeader's
                          -- raw-bytes discipline).
                          let token = BS.unpack tokenBytes
                              envExtras = ("GH_TOKEN", token)
                                        : ceEnvExtras cloneEnv
                          res <- uioBinExecEnv envExtras bin args mCwdPath
                          pure $ case res of ...
```

where `gitBin` is `mkBinName "git"` (the pre-flight always runs `git`,
never `gh` — `gh` doesn't expose `git config`). `mkBinName` returns
`Either Text BinName`; at the call site pattern-match `Right bin` once
and reuse, or define `gitBin = either (error "unreachable") id
(mkBinName "git")` (the literal `"git"` is always a valid `BinName`).

### 3.7 Debug-log redaction (NEW — addresses review blocker B1)

`logExecDebug` (`UntrustedIO.hs:506-528`) renders env extras as
`KEY=VAL` tokens at `DebugS` level. Without redaction, the `gh` path
writes the raw `GH_TOKEN` to the debug log on both arms (local:
`extras` includes `("GH_TOKEN", <token>)`; remote: the token is baked
into the SSH command string that becomes `logExecDebug`'s argv). If a
log shipper captures stderr or the operator redirects to a file, the
token lands on disk un-encrypted — violating AGENTS.md rule 3 ("Never
log secrets") and the "no un-encrypted secret on disk" invariant.

**Fix:** add a redaction seam to `logExecDebug`. A known set of
secret-bearing env keys is redacted (value replaced with
`<redacted>`) before the log message is rendered:

```haskell
-- | Env keys whose values are redacted in debug logs. These carry
-- raw secrets injected by credential-injection paths (gh: GH_TOKEN;
-- the git PAT path's http.extraHeader is in argv, not env, but is
-- listed for defense-in-depth). Add to this set as new
-- credential-injection paths introduce new secret env keys.
secretEnvKeys :: Set String
secretEnvKeys = Set.fromList
  [ "GH_TOKEN"
  , "GITHUB_TOKEN"
  , "http.extraHeader"  -- defense-in-depth (argv, not env)
  ]

redactEnv :: [(String, String)] -> [(String, String)]
redactEnv = map (\(k, v) ->
  if k `Set.member` secretEnvKeys then (k, "<redacted>") else (k, v))

logExecDebug :: String -> [String] -> Maybe String -> [(String, String)] -> IO ()
logExecDebug tag argv mCwd extras =
  globalLogIO DebugS (K.ls msg)
  where
    msg = T.pack (unwords (filter (not . null) parts))
    parts =
      [ tag ]
      <> envPart
      <> cwdPart
      <> [ unwords (map shellQuoteArgv argv) ]
    envPart = case redactEnv extras of
      [] -> []
      xs -> [ unwords (map (\(k, v) -> k <> "=" <> v) xs) ]
    cwdPart = ...
    shellQuoteArgv s = ...
```

**Why a key-set, not a per-call flag:** the redaction is a
defense-in-depth invariant on `logExecDebug` itself, not a caller
discipline. Future credential-injection paths (a future `gh`-like
binary with a different env key) add their key to `secretEnvKeys` and
get redaction for free; a per-call flag would require every caller to
remember to set it, which is the failure mode that created the
blocker.

**Remote arm:** the token is in the SSH command string (argv), not
`extras`. The `redactEnv` change covers the `extras` surface. For the
remote arm's argv-baked token, the redaction must also apply to the
argv rendering — but the remote arm's `uioBinExecEnv` builds the
command as `env GH_TOKEN='<token>' gh ...` and passes it as a single
argv element to `logExecDebug`. The cleanest fix: the remote arm's
`uioBinExecEnv` passes the secret-bearing extras separately so
`logExecDebug` redacts them and renders the command without the
`env` prefix (the prefix is applied at subprocess-spawn time, not at
log time). This is a small refactor to `runRemoteShellText`
(`UntrustedIO.hs:826`): split the `env` prefix out of the logged argv
and into a redactable extras list. The exact shape is an
implementation detail; the invariant is: **the rendered log message
must not contain any value from a key in `secretEnvKeys`**.

**Test:** a new spec `test/Seal/Tools/Exec/LogRedactionSpec.hs` asserts
that for a `logExecDebug` call with `extras = [("GH_TOKEN", "ghp_secret")]`,
the logged message contains `GH_TOKEN=<redacted>` and NOT `ghp_secret`.
The test captures the log scribe output (the project's `globalLogIO`
seam is already capturable in tests via a test scribe). This closes
the blocker with a test, not just a comment.

### 3.6 The transcript record (UNCHANGED)

`recorded` is the same for the `gh` branch as for `git` and plain exec:
`{ "binary": ..., "arg_count": ..., "cwd": ... }`. The token is NEVER in
`recorded` (it's in the env, not argv). `BIN_EXEC` is not in
`secretOpcodes` (the `git` branch isn't either — neither returns secret
values in `orParts`).

## 4. Security Analysis

### 4.1 Threat model (same as git, one addition)

The existing git-injection threat model (design
`2026-08-02-git-opcodes-agent-forwarding-design.md` §5) covers: (a) the
untrusted `git`/`ssh` binary is compromised and tries to exfiltrate the
credential; (b) stderr may echo a token-bearing URL; (c) the
encrypted-keyfile must never leave the harness; (d) per-op agent
lifecycle. The `gh` path inherits (b)–(d) verbatim and changes (a):

- **(a) Compromised `gh` binary.** The `gh` token crosses to untrusted
  memory via `GH_TOKEN` env, exactly as the PAT crosses to untrusted
  memory via `http.extraHeader` argv in the git-PAT path. The residual
  is the same: a replaced `gh` binary can read `GH_TOKEN` from its own
  env and exfiltrate it. This is the documented PAT residual, restated
  for `gh`: **`gh` with a PAT/MachineUser credential has the same
  token-in-untrusted-memory residual as `git` with a PAT. Deploy keys
  (the preferred credential) cannot be used with `gh` at all — `gh`
  falls through to plain exec, incurring no residual.** Operators who
  want zero residual should use deploy keys for `git` and accept that
  `gh` requires a separate PAT-registered repo (or no `gh` use).

  **Credential-class trade-off (CTO rec):** `gh` cannot use deploy
  keys. Adopting `gh` operationally pushes operators toward
  PAT/MachineUser credentials, which carry a token-in-untrusted-memory
  residual that deploy keys avoid. An operator who currently uses a
  deploy key for `git` and wants `gh` must register a **second** repo
  entry with a PAT/MachineUser credential (the same repo URL, a
  different `RepoId`), accepting the token-in-untrusted-memory residual
  for that repo. Deploy-key-only repos are unaffected (`gh` falls
  through to plain exec).

### 4.2 Invariants preserved

- **No un-encrypted secret on disk.** The token is fetched from the
  vault (age-encrypted at rest) → harness process memory (`vhGet`) →
  `gh` process env (memory). No keyring file, no `hosts.yml`, no
  `--with-token` stdin pipe to a file-storing `gh auth login`.
- **No secret in debug logs (NEW, §3.7).** `logExecDebug` redacts
  known-secret env keys (`GH_TOKEN`, `GITHUB_TOKEN`,
  `http.extraHeader`) — the rendered log message contains
  `GH_TOKEN=<redacted>`, never the raw token. This closes the v1
  blocker on both the local and remote arms.
- **CPS-scoped credential.** The token lives only inside the
  `uioWithClone target $ \cloneEnv -> ...` continuation. The `CloneEnv`
  (and its new `ceRawToken` field) is not obtainable outside the CPS
  boundary (`CloneTarget` constructors unexported; `CloneEnv` has no
  `Show` instance by design — the implementer must NOT add one).
- **Type-guaranteed argv sanitization.** `gh`'s argv is still
  `BinArg`-validated (reject empty, NUL, leading-dash via
  `mkBinArg`). The token is in the env, not argv, so argv-injection is
  not even a concern for the credential — but the existing `BinArg`
  guards still apply to the user-supplied `gh` args.
- **`BIN_EXEC` is Untrusted.** The `gh` call runs on the untrusted
  plane via `uioBinExec`/`uioBinExecEnv`, never in-process. The
  capability-scoping compile-fail fixture still holds: `gh` injection
  is in the `UntrustedOpcode`'s `uoRun`, which has `UntrustedIO` in
  scope. No new `System.Process` import.
- **No secret in the transcript.** `recorded` carries binary name, arg
  count, and cwd — no token, no env. The `gh` path uses the same
  `recorded` value as the plain path.

### 4.3 The `-R`/`--repo` skip (new subtle point)

If the agent passes `gh -R owner/repo pr create` from a workdir whose
`origin` is a *different* registered repo, the pre-flight would resolve
the cwd-repo's token and inject it — authenticating `gh` to the cwd
account, not the `-R` account. This is not a leak (the token is still
scoped to one repo's registered credential), but it's a confusing
failure (token valid, `gh` gets 404/403 on the `-R` repo). The
`extractGhRepoFlag` skip (§3.4) prevents this by refusing to inject when
`gh`'s own argv says "act on a different repo." The operator who wants
`gh` to act on a `-R` target must run `gh` from that repo's workdir.

### 4.4 `GH_TOKEN` vs `GITHUB_TOKEN` precedence

`gh`'s docs: `GH_TOKEN` takes precedence over `GITHUB_TOKEN`, and both
override the keyring. We inject `GH_TOKEN` only (not both). A pre-set
`GITHUB_TOKEN` in the untrusted env would be **shadowed by `gh`'s
precedence rule** (we don't overwrite it; `gh` simply prefers
`GH_TOKEN`). A pre-set `GH_TOKEN` in the inherited env would be
**overwritten** by our `envExtras` entry (env-override merge semantics
in `uioBinExecEnv` — the extras list is merged over the inherited env,
last-write-wins). This is correct: the registered credential is
authoritative.

**CI-runner edge (CTO rec):** if the untrusted machine is a GitHub
Actions runner, the ambient env may contain a CI-provided
`GITHUB_TOKEN` (ephemeral, runner-injected). Our injected `GH_TOKEN`
shadows it — the registered credential is authoritative by design. An
operator who *wants* the ambient CI auth to win must simply not
register a credential for that repo (the unregistered-repo path falls
through to plain exec, where `gh` uses the ambient `GITHUB_TOKEN`).

## 5. Testing (TDD)

New spec file: `test/Seal/ISA/Ops/BinGhSpec.hs`, wired in
`seal-harness.cabal` (test-suite `other-modules`) and `test/Main.hs`.
The spec mirrors `BinGitSpec.hs`'s harness (`fakeUio` recording exec
calls, `fakeRepoReg`, `mkDeployKeyDeps`/`mkPatDeps`).

### 5.1 Red tests (written first, watched fail, committed)

1. **PAT repo: `gh pr create` injects `GH_TOKEN` via `uioBinExecEnv`.**
   Fake a PAT-registered repo, cwd inside it, `gh` argv
   `["pr","create","--title","x"]`. Assert: the recorded exec used
   `uioBinExecEnv` (not plain `uioBinExec`, not `uioBinExecGitEnv`),
   the env extras contain `("GH_TOKEN", <token>)`, and the pre-flight
   `git config` ran first.
2. **MachineUser repo: `gh pr merge` injects `GH_TOKEN`.** Same as #1
   with a `CredMachineUser` credential. Assert the token is the raw
   MachineUser token (not the base64 header).
3. **Deploy-key repo: `gh pr create` falls through to plain
   `uioBinExec`.** Fake a deploy-key repo, cwd inside it. Assert: the
   recorded exec used plain `uioBinExec` (no env extras), no
   `GH_TOKEN` injected, `uioBinExecGitEnv` NOT called. (Documents the
   non-goal: `gh` can't use SSH.)
4. **Unregistered repo: `gh pr create` falls through to plain
   `uioBinExec`.** Pre-flight returns a remote URL not in the registry.
   Assert plain exec, no injection.
5. **Not a git repo (no `origin`): `gh auth status` falls through to
   plain `uioBinExec`.** Pre-flight `git config` returns empty. Assert
   plain exec (ambient `gh` auth).
6. **`gh -R owner/repo pr create` skips injection.** Argv contains
   `-R other/repo` (space form). Assert plain `uioBinExec` regardless
   of cwd's `origin`, plus the non-secret NOTE in `orParts`
   ("credential injection skipped ... Run gh from the target repo's
   workdir"). (The `extractGhRepoFlag` skip.)
7. **`--repo=owner/repo` long joined form also skips.** Same as #6
   with the `--repo=` joined form. Assert the NOTE.
8. **`-Rowner/repo` joined short form also skips (REQUIRED after
   review).** `gh -Rowner/other-repo pr create` — the joined short
   form. Assert plain `uioBinExec` + the NOTE. This closes the
   credential-scope bypass the Security reviewer flagged (without
   this case, the agent could craft `-Rowner/other` to evade the
   skip and inject repo A's token for `other`).
9. **`--repo owner/repo` long space form also skips.** `gh --repo
   other/repo pr create`. Assert plain `uioBinExec` + the NOTE.
10. **Locked vault → `BIN_EXEC: credential resolution failed: vault
    locked — run /vault unlock`.** PAT repo, vault locked. Assert the
    OpResult is an error with the vault-locked message (reuses
    `renderCloneError`).
11. **Missing vault key → `... vault key <name> not found`.** PAT
    repo, vault key absent. Assert the OpResult error names the key.
12. **Pre-flight `git config` failure → surfacable error.** Fake
    `uioBinExec` returns `Left` for the pre-flight. Assert the
    OpResult surfaces the `BIN_EXEC: pre-flight git config failed:
    ...` message (reuses the git path's error).
13. **Transcript record is secret-free.** Assert `orRecorded` is
    `{ "binary": "gh", "arg_count": ..., "cwd": ... }` — no
    `GH_TOKEN`, no token, no env extras.
14. **Local/remote parity.** Run cases 1–9 in both local and remote
    modes (the `fakeUio` recording is mode-agnostic). Assert identical
    behavior. (The token-in-env path is the same on both planes.)
15. **Debug-log redaction (NEW — addresses blocker B1).** Assert that
    `logExecDebug` with `extras = [("GH_TOKEN", "ghp_secret")]`
    renders `GH_TOKEN=<redacted>` in the captured log scribe output,
    and `ghp_secret` does NOT appear. Assert the same for
    `GITHUB_TOKEN`. This test lives in a new
    `test/Seal/Tools/Exec/LogRedactionSpec.hs`.
16. **`CloneEnv` redaction (CTO rec).** In `CloneSpec.hs`, assert
    that a PAT-resolved `CloneEnv`'s fields do not contain the raw
    token bytes in any serialized form (mirror the existing
    `ceUrl`-is-token-free assertions at `CloneSpec.hs:461-529`).
    Specifically: `ceRawToken` is `Just <tokenBytes>` (the secret is
    *there*, by design — it's the injection payload), but the token
    bytes do NOT appear in `ceUrl`, `ceGitConfigArgs`'s non-header
    parts, or `ceEnvExtras` (which carries only
    `GIT_TERMINAL_PROMPT=0`). And `CloneEnv` has no `Show` instance
    (compile-fail if anyone adds `deriving stock Show`).

### 5.2 Green

Implement `runGhWithCredentials`, `extractGhRepoFlag`, and the
`ceRawToken` field on `CloneEnv` + populate it in `resolveCloneTarget`.
Re-run the spec; all red tests turn green. Run `BinGitSpec` to confirm
the `git` path is unaffected (the `git` path ignores `ceRawToken`).

### 5.3 Properties (QuickCheck, if the pure helpers warrant)

`extractGhRepoFlag` is a pure parser — QuickCheck it: for any argv,
`extractGhRepoFlag` returns `Just` the first `-R`/`--repo` value or
`Nothing`, and never crashes on arbitrary `Text` (including empty,
NUL-stripped, unicode). Mirror the `extractGitDir` property shape if
one exists; otherwise add a small property.

## 6. File Scope

| File | Change |
|---|---|
| `src/Seal/SourceControl/Clone.hs` | Add `ceRawToken :: Maybe ByteString` to `CloneEnv`; populate in `resolveCloneTarget` at all three construction sites (PAT/MachineUser path ~line 369 → `Just tokenBytes`; both deploy-key paths ~lines 435 and 474 → `Nothing`). Do NOT add `deriving stock Show` (the type is `Show`-less by design). |
| `src/Seal/ISA/Ops/Bin.hs` | Add `gh` branch in `uoRun` → `runGhWithCredentials`; add `runGhWithCredentials`, `extractGhRepoFlag` (handle all 4 forms: `-R v`, `-Rv`, `--repo v`, `--repo=v`); update module doc + `binExecOp` `uoDesc`. |
| `src/Seal/Tools/Exec/UntrustedIO.hs` (NEW in scope — addresses blocker B1) | Add `secretEnvKeys` + `redactEnv`; apply `redactEnv` to the `envPart` in `logExecDebug` (~line 516). Refactor `runRemoteShellText` (~line 826) so the `env GH_TOKEN=...` prefix is redactable (split the secret extras out of the logged argv). |
| `test/Seal/ISA/Ops/BinGhSpec.hs` | New spec — red tests 1–14 (above). |
| `test/Seal/Tools/Exec/LogRedactionSpec.hs` (NEW — addresses blocker B1) | New spec — red test 15 (log redaction). Captures the `globalLogIO` scribe. |
| `test/Seal/SourceControl/CloneSpec.hs` | Add red test 16 (`CloneEnv` redaction: `ceRawToken` is `Just` the secret, but the secret bytes don't leak into other fields; no `Show` instance). |
| `seal-harness.cabal` | Add `test/Seal/ISA/Ops/BinGhSpec.hs` + `test/Seal/Tools/Exec/LogRedactionSpec.hs` to test-suite `other-modules`. |
| `test/Main.hs` | Import + run `Seal.ISA.Ops.BinGhSpec`, `Seal.Tools.Exec.LogRedactionSpec`. |

No changes to: `UIO`/`UIO/Internal`, `Dispatch`, `Registry`,
`Security/*`, the frontend, the gateway, or any other opcode. The
`git` path's behavior is unchanged (it ignores `ceRawToken`).

## 7. Human Checkpoints

1. **After the design review gate approves** — pause for the user to
   review the design doc and the `ceRawToken` decision (Option A vs
   Option B) before any code is written.
2. **After the red tests commit** — pause for the user to see the
   failing tests before implementation.
3. **After the green tests + `make check`** — pause for the user to
   review the diff before opening a PR.

## 8. Definition of Done

- [ ] `gh pr create` from inside a PAT/MachineUser-registered repo
      authenticates via `GH_TOKEN` injected from the vault, on both
      local and remote executors.
- [ ] `gh` in a deploy-key-registered repo falls through to plain exec
      (no injection, no `uioBinExecGitEnv`).
- [ ] `gh` in an unregistered repo falls through to plain exec.
- [ ] `gh -R owner/repo ...` skips injection (plain exec) — all 4 forms
      (`-R v`, `-Rv`, `--repo v`, `--repo=v`) — with a non-secret NOTE
      in `orParts`.
- [ ] Locked / missing vault yields the existing actionable error
      (reuses `renderCloneError`).
- [ ] Transcript record is secret-free (no token, no env).
- [ ] **Debug logs are secret-free (blocker B1):** `logExecDebug`
      renders `GH_TOKEN=<redacted>` / `GITHUB_TOKEN=<redacted>`; the
      raw token never appears in captured log output (local + remote).
- [ ] `CloneEnv` has no `Show` instance (compile-fail if added); the
      raw token lives only in `ceRawToken` (the injection payload) and
      does not leak into `ceUrl`/`ceGitConfigArgs`-non-header/
      `ceEnvExtras`.
- [ ] `BinGitSpec` unchanged (the `git` path ignores `ceRawToken`).
- [ ] `make check` green (build + test + lint, `-Werror` clean).
- [ ] New specs wired in `seal-harness.cabal` + `test/Main.hs`
      (`BinGhSpec`, `LogRedactionSpec`; `CloneSpec` extended).
- [ ] Design review gate passed (Architect + Security: NEEDS-CHANGES
      → v2; CTO: PASS).

## 9. Open Questions for the Review Gate

1. **`ceRawToken` on `CloneEnv` (Option A) vs a separate
   `resolveGhToken` seam (Option B).** I chose A (one resolution path,
   one vault fetch, `CloneEnv` is already redacted/CPS-scoped). The
   Security reviewer should confirm the secret-carrying field is
   acceptable given `CloneEnv`'s existing threat surface.
2. **`-R`/`--repo` skip vs credential-rewrite.** I chose "skip
   injection" (conservative). Alternative: parse `-R owner/repo`, look
   *that* up in the registry, inject the matching repo's token. More
   convenient, but adds `gh`-specific repo-URL parsing
   (`owner/repo` → `https://github.com/owner/repo`) and assumes
   github.com. The reviewer should decide if the convenience is worth
   the parsing.
3. **`GH_TOKEN` vs `GITHUB_TOKEN`.** I inject `GH_TOKEN` only. The
   reviewer should confirm precedence is correct and we don't need to
   also set `GITHUB_TOKEN` (or `unset` a pre-existing one).
4. **Should `gh` be added to the default allow-list?** Out of scope
   here (operator policy), but the CTO reviewer's note is worth
   recording in the filed issue: `gh` is high-leverage — it can
   create/merge PRs, edit PRs, delete branches, invite collaborators,
   create/manage repo secrets, and run arbitrary Actions workflows. A
   default allow-list that includes `gh` grants significant GitHub
   power to any agent. **Recommend NOT adding `gh` to any curated
   default allow-list**; let the operator opt in explicitly. If the
   project later ships "safe-ish defaults," `gh` should be absent or
   behind a separate flag.