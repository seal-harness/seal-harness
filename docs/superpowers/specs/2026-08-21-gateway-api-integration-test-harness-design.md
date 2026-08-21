# Gateway API Integration Test Harness — Design

> **Status:** Design proposal. Implements a reusable `runApiTest` harness for
> writing high-level integration tests against the gateway API, with automatic
> local/remote parity, a mock LLM provider, and dummy repo setup.

## 1. Problem & goal

We need integration tests that exercise the full gateway API → agent loop →
ISA dispatch → untrusted execution → transcript path, asserting behavioral
parity across local and remote execution modes. The existing e2e test in
`test/Seal/Gateway/ApiSpec.hs:3367-3488` demonstrates the pattern but is
hand-wired with ~80 lines of setup per test. We need a reusable harness so a
new test is 5-10 lines, not 80.

The harness must:

1. **Run the same test twice** — once in `mode=local`, once in `mode=remote`
   — so a test author writes the test body once and gets parity for free.
2. **Mock the LLM** — tests script the provider responses
   (`[CompletionResponse]`) so no real LLM or API key is needed. The script
   can include tool-call round-trips (e.g. `CbToolUse FILE_WRITE` →
   `CbToolResult` → `CbText "done"`).
3. **Set up a dummy private repo** — a local bare git repo + SSH keypair +
   `authorized_keys` bracket, so git operations (clone/push/pull) work over
   SSH to localhost without GitHub.
4. **Expose clean helpers** — `callApiNewTab`, `sendMsgToSession`,
   `getTranscript`, `assertTranscriptContains`, etc.
5. **Guard with `pendingWith`** — when `sshd` / `ssh-keygen` / `ssh-agent` are
   unavailable, the remote-mode test skips (the local-mode test still runs).

## 2. Architecture

```
                    runApiTest
                   /           \
           runApiTestLocal    runApiTestRemote
                |                  |
         ApiDeps(local)      ApiDeps(remote)
          sdIsRemote=False    sdIsRemote=True
          mkLocalUntrustedIO  mkRemoteUntrustedIO(localhost)
                |                  |
                v                  v
          test body (same)  test body (same)
```

### 2.1 The `ApiTestEnv` record

The harness builds an `ApiTestEnv` carrying everything a test body needs:

```haskell
data ApiTestEnv = ApiTestEnv
  { ateApp      :: Application          -- the WAI app (apiApp deps)
  , ateDeps     :: ApiDeps             -- the full ApiDeps
  , atePaths    :: SealPaths           -- temp-dire paths
  , ateMode     :: Text                -- "local" | "remote"
  , ateRepo     :: Maybe DummyRepo     -- the dummy repo (Nothing if not set up)
  , ateProviderRef :: IORef [CompletionResponse]  -- the mock provider script
  }
```

### 2.2 The `runApiTest` entry point

```haskell
runApiTest
  :: Maybe DummyRepoConfig      -- ^ Nothing = no dummy repo needed
  -> [CompletionResponse]       -- ^ the mock LLM script
  -> (ApiTestEnv -> IO ())      -- ^ the test body
  -> Spec
```

This creates a `describe "local mode"` + `describe "remote mode"` and runs the
same test body in each. When `DummyRepoConfig` is `Just`, the harness sets up
the bare repo + SSH keys + `authorized_keys` bracket before running the body.

### 2.3 Local vs remote wiring

The only difference between local and remote `ApiDeps`:

| Field | Local | Remote |
|---|---|---|
| `sdIsRemote` | `False` | `True` |
| `adSecurityConfig` | `defaultSecurityConfig` (no `untrusted_execution`) | `SecurityConfig` with `mode=remote` + `SshConfig` pointing at localhost |
| `adMkSessionExec` | `Nothing` (uses `mkSessionExec` default → local) | `Nothing` (uses `mkSessionExec` default → remote via `SshConfig`) |
| `CloneDeps.cdIsRemote` | `False` | `True` |

Both modes share:
- The same `ScriptProvider` mock (via `sdResolve`)
- The same `SendDeps` structure (except `sdIsRemote`)
- The same temp dir layout (`SealPaths`)
- The same vault (fake, unlocked — holds the deploy key passphrase)
- The same repo registry (holds the dummy repo if configured)

### 2.4 Remote-mode SSH-to-localhost

For remote mode, the harness needs an `SshConfig` that targets localhost. The
infrastructure from `BinGitLocalIntegrationSpec` provides the pattern:

1. Generate a fresh SSH keypair (no passphrase — the test harness doesn't
   need the encrypted-keyfile path; the deploy-key credential injection is
   tested by `BinGitLocalIntegrationSpec`).
2. Add the public key to `~/.ssh/authorized_keys` (bracket cleanup).
3. `ssh-keyscan localhost` → `known_hosts` file (temp file, bracket cleanup).
4. Build `SshConfig` pointing at `localhost`, the current user, and the temp
   `known_hosts` file. The workspace is a temp directory.

The `SecurityConfig` for remote mode:
```haskell
SecurityConfig
  { scUntrustedExec = Just UntrustedExecFileConfig
      { uefcMode = "remote"
      , uefcRemote = Just UntrustedExecRemoteFileConfig
          { uerfcHost = "localhost"
          , uerfcUser = currentUser
          , uerfcKnownHosts = knownHostsPath
          , uerfcWorkspace = remoteWorkspaceDir
          , ...
          }
      }
  }
```

### 2.5 The dummy repo

```haskell
data DummyRepoConfig = DummyRepoConfig
  { drcRepoId    :: Text          -- the repo id (e.g. "test-repo")
  , drcUrl       :: Text          -- the SSH URL (e.g. "zoe@localhost:/tmp/.../bare.git")
  , drcCredential :: RepoCredential  -- CredDeployKey or CredPat
  }

data DummyRepo = DummyRepo
  { drBareRepoPath :: FilePath
  , drRepo         :: SourceRepo   -- the registered SourceRepo
  , drCleanup      :: IO ()
  }
```

When `DummyRepoConfig` is `Just`, the harness:
1. Creates a bare git repo at a temp path.
2. If `CredDeployKey`: generates an SSH keypair via `ssh-keygen`, adds the
   public key to `authorized_keys`, stores the passphrase in the fake vault,
   writes the encrypted keyfile, registers the `SourceRepo` with
   `CredDeployKey`.
3. If `CredPat`: stores a fake token in the vault, registers the `SourceRepo`
   with `CredPat`.
4. Returns `DummyRepo` with a cleanup action.

The `SourceRepo` is wired into the `RepoRegistryHandle` so the BIN_EXEC
credential injection path can find it.

## 3. The mock provider

The `ScriptProvider` pattern (from `SendSpec.hs:72-79`) is the canonical mock.
The harness centralizes it:

```haskell
newtype ScriptProvider = ScriptProvider (IORef [CompletionResponse])
instance Provider ScriptProvider where
  complete (ScriptProvider ref) _ = do
    responses <- readIORef ref
    case responses of
      (r : rest) -> writeIORef ref rest >> pure (Right r)
      []         -> pure (Right (CompletionResponse [CbText "done"] StopEnd (Usage 0 0)))
  listModels _ = pure (Right [ModelId "llama3.2"])
```

The harness injects it via `sdResolve`:
```haskell
resolveStub :: SessionMeta -> IO (Either Text (SomeProvider, ModelId))
resolveStub _ = pure (Right (SomeProvider (ScriptProvider ref), ModelId "llama3.2"))
```

### 3.1 Scripting a tool-call round-trip

A test that needs the agent to call `FILE_WRITE` then respond with text:

```haskell
script =
  [ CompletionResponse
      [ CbToolUse (ToolCallId "t1") (OpName "FILE_WRITE")
          (object ["path" .= ("foo.txt" :: Text), "content" .= ("hello" :: Text)]) ]
      StopToolUse (Usage 0 0)
  , CompletionResponse [CbText "Wrote foo.txt"] StopEnd (Usage 0 0)
  ]
```

The first `CompletionResponse` triggers the ISA dispatcher to run `FILE_WRITE`
via `UntrustedIO` (local or remote), then the loop feeds the `ToolResult` back
and pops the second `CompletionResponse` (the final text reply).

## 4. The test helper API

```haskell
-- | Create a provider tab via POST /api/tabs/new. Returns the session id.
callApiNewTab :: ApiTestEnv -> Text -> Text -> IO Text
-- e.g. callApiNewTab env "ollama" "llama3.2"

-- | Send a message to a session via POST /api/sessions/:id/send.
sendMsgToSession :: ApiTestEnv -> Text -> Text -> IO ()
-- e.g. sendMsgToSession env sid "write foo.txt with 'hello'"

-- | Get the transcript as a JSON array.
getTranscript :: ApiTestEnv -> Text -> IO [A.Value]

-- | Assert the transcript contains the given text substring.
assertTranscriptContains :: ApiTestEnv -> Text -> Text -> IO ()
-- e.g. assertTranscriptContains env sid "Wrote foo.txt"

-- | Assert a file exists in the workdir (local: on disk; remote: via SSH).
assertWorkdirFile :: ApiTestEnv -> Text -> Text -> IO ()
-- e.g. assertWorkdirFile env sid "foo.txt" "hello"

-- | Run a git command in the workdir (local: direct; remote: via SSH).
runGitInWorkdir :: ApiTestEnv -> Text -> [Text] -> IO ()
```

## 5. Example test

```haskell
spec :: Spec
spec = describe "BIN_EXEC git push with deploy key" $ do
  runApiTest (Just DummyRepoConfig { .. }) script $ \env -> do
    sid <- callApiNewTab env "ollama" "llama3.2"
    sendMsgToSession env sid "Add a new file foo.txt with contents 'this is a test'"
    sendMsgToSession env sid "Commit this to a new branch and push"
    assertTranscriptContains env sid "pushed"
  where
    script =
      [ CompletionResponse [CbToolUse (ToolCallId "t1") (OpName "FILE_WRITE")
          (object ["path" .= ("foo.txt" :: Text), "content" .= ("this is a test" :: Text)])]
          StopToolUse (Usage 0 0)
      , CompletionResponse [CbToolUse (ToolCallId "t2") (OpName "SHELL_EXEC")
          (object ["command" .= ("git checkout -b test-branch" :: Text)])]
          StopToolUse (Usage 0 0)
      , CompletionResponse [CbToolUse (ToolCallId "t3") (OpName "SHELL_EXEC")
          (object ["command" .= ("git add foo.txt && git commit -m 'add foo'" :: Text)])]
          StopToolUse (Usage 0 0)
      , CompletionResponse [CbToolUse (ToolCallId "t4") (OpName "BIN_EXEC")
          (object ["binary" .= ("git" :: Text), "args" .= (["push", "-u", "origin", "test-branch"] :: [Text])])]
          StopToolUse (Usage 0 0)
      , CompletionResponse [CbText "Pushed to origin"] StopEnd (Usage 0 0)
      ]
```

## 6. File layout

```
test/
  Seal/
    TestHelpers/
      ApiTestHarness.hs     -- runApiTest, ApiTestEnv, helpers
      ScriptProvider.hs      -- centralized ScriptProvider mock
      DummyRepo.hs           -- dummy repo setup (bare repo + SSH keys)
    Gateway/
      ApiIntegrationSpec.hs  -- the actual integration tests
```

## 7. Limitations & future work

- **Remote mode requires `sshd` on localhost.** Tests guard with `pendingWith`.
- **No parallel test runs.** The `authorized_keys` bracket is not
  concurrency-safe (two tests appending/removing keys simultaneously would
  corrupt the file). The harness serializes the remote-mode tests via an
  `MVar`.
- **The mock provider is single-threaded.** Each test gets its own
  `IORef [CompletionResponse]`; concurrent tests are fine as long as they
  don't share the ref.
- **`githubHosts` is still a constant.** TODO: make it configurable via
  `SecurityConfig` so the test harness can inject `localhost` without modifying
  production code. For now, `localhost` / `127.0.0.1` are in the allow-list
  (added in this work).

## 8. Channel invariant — the assumption that makes this work

### 8.1 The invariant

**Channels must be implemented exclusively in terms of the gateway API.** A
channel (CLI, Telegram, Signal, Web, future channels) must not import or call
any Seal Harness core function, module, or internal type. The only interface a
channel may use is the HTTP/WS gateway API — the same REST + WebSocket surface
the frontend SPA uses. This means:

- No importing `Seal.Agent.Loop`, `Seal.Core.TurnEngine`, `Seal.ISA.*`,
  `Seal.SourceControl.*`, `Seal.Security.*`, etc. in channel code.
- No direct access to the vault, transcript, session store, or repo registry.
- No calling `runSessionTurn`, `dispatch`, or any ISA opcode directly.
- The channel is a pure HTTP/WS client of the gateway, nothing more.

### 8.2 Why this invariant matters

The entire value proposition of the `runApiTest` harness is that tests written
against the gateway API are **channel-agnostic by construction**. If every
channel talks to the same API, then a test that exercises the API exercises
every channel's behavior. The local/remote parity test then becomes a
special case of the more general channel-parity property: if the API behaves
identically in local and remote mode (which the tests assert), and every
channel is a thin client of the API (which the invariant enforces), then every
channel behaves identically in local and remote mode.

If a channel bypasses the API and calls core functions directly, it creates a
**hidden code path** that the tests don't cover. That path may diverge between
local and remote mode, between configurations, or over time as the core
evolves. The invariant eliminates this class of bug by making the API the
sole integration surface.

### 8.3 Current state

This invariant is **not yet enforced**. Some channels may already import core
modules or call internal functions. Auditing and enforcing the invariant is
**out of scope for this work** — it would expand the scope significantly and
may require refactoring channels that have legitimate reasons for tight
coupling (e.g. the CLI's REPL may share process state with the gateway in
ways that are hard to decouple).

### 8.4 How we will establish the invariant going forward

1. **Document the invariant.** This section is the starting point. The
   invariant should be referenced in `AGENTS.md` and in the channel
   development guide so contributors are aware of it from the start.

2. **Add a CI grep check.** A script (similar to the existing
   `CapabilityScopingFail` compile-fail fixture) that greps channel source
   files for forbidden imports. The check would live in `.github/workflows/`
   and fail the build if a channel file imports a `Seal.*` module outside an
   allow-list (e.g. `Seal.Channel.*` modules may import `Seal.Core.ChannelKind`
   but not `Seal.Agent.Loop`). This is a gradual enforcement mechanism —
   existing violations are grandfathered with a allow-list file, and new
   violations fail CI.

3. **New channels must comply.** Any new channel (e.g. a Slack channel, an
   IRC channel) must be implemented as a pure gateway API client from day one.
   The `runApiTest` harness gives new channel authors a ready-made test suite:
   if their channel passes the API integration tests, it's compliant.

4. **Migrate existing channels incrementally.** Each existing channel that
   violates the invariant gets a tracked issue to decouple. The migration is
   done one channel at a time, with the `runApiTest` harness serving as the
   regression test that confirms the channel still works after decoupling.

5. **The gateway API is the contract.** The API surface is the integration
   contract between the harness core and all channels. Changes to the API
   (new endpoints, changed response shapes) are breaking changes that require
   updating all channels. The `runApiTest` harness makes these changes
   visible — a test that passes before the API change and fails after is a
   signal that channels need updating.