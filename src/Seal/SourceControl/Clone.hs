{-# LANGUAGE OverloadedStrings #-}
-- | Source-control clone seam — the W2 no-disk design (design §4.1, §4.4,
-- §4.6, §5). The credential mechanism (rev 3): the encrypted keyfile lives
-- on the harness disk (ciphertext); the passphrase lives in the vault;
-- per-op @ssh-agent@ decrypts the keyfile into memory using the passphrase
-- piped to @ssh-add@'s stdin; @ssh -A@ forwards the @SSH_AUTH_SOCK@ to the
-- untrusted machine; after the op, @ssh-add -D@ + @ssh-agent -k@.
--
-- Security invariants (enforced by construction — the W2 self-reviewed
-- checkpoint audits these):
--
-- 1. **No un-encrypted secret on disk, on either machine.** The encrypted
--    keyfile under @cdKeyfilesDir@ IS permitted (ciphertext — same category
--    as the age-encrypted vault file). The cleartext key exists only in:
--    the vault (age-encrypted at rest) → harness process memory (@vhGet@)
--    → ssh-agent memory (@ssh-add@ decrypts the encrypted keyfile using the
--    passphrase piped to its stdin) → signing requests over the forwarded
--    agent socket. The untrusted machine only ever sees the forwarded
--    @SSH_AUTH_SOCK@.
--
-- 2. **Per-op agent lifecycle.** Each clone/git-op gets a fresh
--    @ssh-agent@ via 'withCloneTarget' (bracket semantics): start →
--    @sahAddKey <enc-keyfile> <passphrase>@ → run → @sahDeleteAll@ +
--    @sahKill@. Exactly one identity is live at forwarding time (the
--    security-critical scoping — design §4.6).
--
-- 3. **PAT (fallback) uses @http.extraHeader@ in argv (memory, no file).**
--    The token lives only in the git config args (in-memory argv); it is
--    NEVER written to disk. The token-in-untrusted-memory residual is
--    documented (deploy keys preferred).
--
-- 4. **Pinned @known_hosts@ (public data).** 'cdPinnedKnownHosts' is the
--    compile-time-embedded GitHub host keys (tamper-resistant via
--    'file-embed'). Per-op it is written to a temp @known_hosts@ file
--    (0644, public data, bracket-cleaned) and referenced by
--    @UserKnownHostsFile=@ in @GIT_SSH_COMMAND@. @StrictHostKeyChecking=yes@
--    (NOT @accept-new@ / @/dev/null@ — §5.3: MITM defense).
--
-- 5. **The encrypted keyfile never leaves the harness.** The untrusted
--    machine never sees the keyfile (encrypted or otherwise) — only the
--    forwarded @SSH_AUTH_SOCK@ via @ssh -A@.
--
-- 6. **'CloneGitFailed' carries the exit code ONLY — no stderr** (§5.4:
--    git can echo a token-bearing URL in stderr on auth failure).
--
-- 7. **'withCloneTarget' is CPS** (mirrors 'Seal.Security.Secrets.withApiKey'):
--    the authenticated bits are scoped to the continuation and the cleanup
--    always runs (bracket semantics).
module Seal.SourceControl.Clone
  ( CloneError (..)
  , ClonePlan (..)
  , CloneTarget
  , CloneEnv (..)
  , CloneDeps (..)
  , planClone
  , resolveCloneTarget
  , withCloneTarget
  , cloneRepo
  , lsRemoteRepo
  , renderCloneError
  , renderPatHeader
  , stubCloneDeps
  ) where

import Control.Exception (bracket, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.IORef (readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (createDirectoryIfMissing, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, openBinaryTempFile)
import System.Posix.Files (setFileMode)

import Seal.Git.Repo (readProcessBinaryCwdEnv)
import Seal.Security.Vault (VaultHandle (vhGet))
import Seal.Security.Vault.Age (VaultError (VaultKeyNotFound, VaultLocked))
import Seal.SourceControl.Repo
  ( RepoCredential (..), SourceRepo (..), VcsKind (..)
  , hostAllowed, parseRepoHost, repoIdText )
import Seal.SourceControl.AgentRegistry
  ( AgentRegistryHandle, arIsLive, arLoad, arRemove, arUpsert
  , probeAgent, AgentStatus (..) )
import Seal.SourceControl.Registry (RepoRegistryHandle)
import Seal.Tools.Ssh.Agent
  ( SshAgentEnv (..), SshAgentHandle (sahAddKey, sahDeleteAll, sahGetAuthEnv
                                      , sahStart) )
import Seal.Vault.Commands (VaultRuntime (vrHandleRef))

----------------------------------------------------------------------------
-- Errors
----------------------------------------------------------------------------

-- | The clone seam's error type. 'CloneGitFailed' carries the exit code ONLY
-- (no stderr — §5.4: git can echo a token-bearing URL in stderr on auth
-- failure; a "redacted one-liner" heuristic is fragile, so stderr is dropped
-- entirely for this pass).
data CloneError
  = CloneVaultError VaultError
    -- ^ A vault access failure. Preserves the 'VaultError' so the caller can
    -- distinguish 'VaultLocked' from 'VaultKeyNotFound'.
  | CloneNoCredentialForUrl Text
    -- ^ The URL is malformed (host unparseable) — no credential can be
    -- resolved.
  | CloneUnsupportedVcs VcsKind
    -- ^ The 'VcsKind' has no credential-injection path in this pass
    -- (only 'VcsGitHub' is supported).
  | CloneHostNotSupported Text
    -- ^ The parsed host is not in the allow-list (defense-in-depth on top of
    -- write-time validation).
  | CloneAgentError Text
    -- ^ The per-op ssh-agent lifecycle failed (start, add-key, etc.). The
    -- cleartext key never made it to the agent — fail closed.
  | CloneGitFailed Int
    -- ^ @git@ exited non-zero. Carries the exit code ONLY — NO stderr (§5.4).
  deriving stock (Eq, Show)

-- | Render a 'CloneError' to the exact user-facing message used by the slash
-- command (W5) and a future @CLONE@ opcode. The mapping is total and stable:
-- each variant maps to a distinct, actionable message.
renderCloneError :: CloneError -> Text
renderCloneError = \case
  CloneVaultError VaultLocked ->
    "vault locked — run /vault unlock"
  CloneVaultError (VaultKeyNotFound k) ->
    "vault key " <> k <> " not found"
  CloneVaultError v ->
    "vault error: " <> T.pack (show v)
  CloneNoCredentialForUrl u ->
    "no credential resolvable for " <> u
  CloneUnsupportedVcs v ->
    "unsupported VCS: " <> T.pack (show v)
  CloneHostNotSupported h ->
    "host " <> h <> " not supported (only github.com is supported in this pass)"
  CloneAgentError msg ->
    "ssh-agent error: " <> msg
  CloneGitFailed n ->
    "git failed (exit " <> T.pack (show n) <> ")"

----------------------------------------------------------------------------
-- ClonePlan (pure — no IO, no vault)
----------------------------------------------------------------------------

-- | The pure credential-injection strategy for a 'SourceRepo'. Carries only
-- public data (URLs + vault key /names/) — never secret bytes.
data ClonePlan
  = ClonePlanExtraHeader Text Text
    -- ^ Token-free HTTPS URL + the vault key name (PAT / MachineUser). The
    -- token is fetched at clone time and passed via @http.extraHeader@ in
    -- the git argv (memory, no file).
  | ClonePlanSshKey Text Text
    -- ^ SSH URL (host-bound) + the vault key name (DeployKey). The
    -- /passphrase/ is fetched at clone time and piped to @ssh-add@'s stdin;
    -- the encrypted keyfile is read from @cdKeyfilesDir@ by @ssh-add@.
  deriving stock (Eq, Show)

-- | Decide the clone strategy for a 'SourceRepo' (pure, no IO, no vault).
-- Re-parses the URL host and asserts the allow-list (§5.2 defense-in-depth),
-- then routes on 'srVcsKind' / 'srCredential'.
--
-- * Malformed URL (host unparseable) → 'CloneNoCredentialForUrl'.
-- * Parsed host not in the allow-list → 'CloneHostNotSupported'.
-- * 'VcsGit' (non-GitHub git) → 'CloneUnsupportedVcs' (no
--   credential-injection path this pass).
-- * 'CredPat' / 'CredMachineUser' → 'ClonePlanExtraHeader' (SSH URL
--   rewritten to token-free HTTPS).
-- * 'CredDeployKey' → 'ClonePlanSshKey' (URL unchanged, SSH).
planClone :: SourceRepo -> Either CloneError ClonePlan
planClone repo =
  case parseRepoHost (srUrl repo) of
    Left _err -> Left (CloneNoCredentialForUrl (srUrl repo))
    Right host
      | not (hostAllowed host) -> Left (CloneHostNotSupported host)
      | srVcsKind repo == VcsGit -> Left (CloneUnsupportedVcs VcsGit)
      | otherwise -> case srCredential repo of
          CredPat vaultKey ->
            Right (ClonePlanExtraHeader (sshToHttps (srUrl repo)) vaultKey)
          CredMachineUser vaultKey _username ->
            Right (ClonePlanExtraHeader (sshToHttps (srUrl repo)) vaultKey)
          CredDeployKey vaultKey ->
            Right (ClonePlanSshKey (srUrl repo) vaultKey)

-- | Rewrite an SSH GitHub URL (@git\@github.com:owner\/repo.git@) to a
-- token-free HTTPS URL (@https:\/\/github.com\/owner\/repo.git@). An
-- already-HTTPS URL is returned unchanged. The result NEVER contains a
-- credential fragment.
sshToHttps :: Text -> Text
sshToHttps url
  | "https://" `T.isPrefixOf` url = url
  | "http://" `T.isPrefixOf` url  = url
  | "git@" `T.isPrefixOf` url =
      let afterAt = T.drop (T.length "git@") url
      in case T.breakOn ":" afterAt of
           (host, rest)
             | T.null rest -> url
             | otherwise  ->
                 "https://" <> host <> "/" <> T.drop (T.length ":") rest
  | otherwise = url

----------------------------------------------------------------------------
-- CloneDeps — the closed-over opcode param (W2)
----------------------------------------------------------------------------

-- | The per-op credential dependencies, passed as a closed-over param to
-- 'resolveCloneTarget' / 'cloneRepo' / 'lsRemoteRepo' (mirrors
-- @secretGetOp (cdVault deps)@ at @Channels/Loop.hs:1094@ — NOT via
-- 'Env'/'mkEnv'; the codebase proved 'Env' is the wrong vehicle).
--
-- Carries:
--
-- * @cdVault@ — the 'VaultRuntime' (yields the live 'VaultHandle' via
--   'vrHandleRef' at runtime; fail-closed to 'CloneVaultError VaultLocked'
--   if the vault is unconfigured/locked). Mirrors @secretGetOp rt@ which
--   takes 'VaultRuntime', not the raw handle.
-- * @cdSshAgent@ — the 'SshAgentHandle' seam (real or fake). Shared agent:
--   started once (lazily on first use, cached in 'cdAgentEnvRef'),
--   reused across all ops. Per-op: @sahAddKey@ → run → @sahDeleteAll@
--   (the per-op key scoping — exactly one key live at forwarding time).
-- * @cdAgentEnvRef@ — caches the shared 'SshAgentEnv' (the socket + PID
--   from the first @sahStart@ call). 'Nothing' until the first deploy-key
--   op starts the agent. Subsequent ops reuse the cached env (no
--   re-start).
-- * @cdPinnedKnownHosts@ — compile-time-embedded GitHub host keys (public
--   data, tamper-resistant via 'file-embed'). Written per-op to a temp
--   @known_hosts@ file.
-- * @cdKeyfilesDir@ — the harness-private dir holding the encrypted
--   keyfiles (@~\/.seal\/state\/repos\/keys\/\<repo-id\>@). The encrypted
--   keyfile lives only on the harness disk (ciphertext).
data CloneDeps = CloneDeps
  { cdVault           :: VaultRuntime
  , cdRepoReg         :: RepoRegistryHandle
  , cdSshAgent        :: SshAgentHandle
  , cdAgentRegistry   :: AgentRegistryHandle
    -- ^ One-agent-per-repo registry, keyed by the repo's vault key. Each
    -- unique repo gets its own @ssh-agent@ process, started lazily on
    -- first use. The agent + key persist for the harness lifetime AND
    -- across @seal serve@ restarts (the registry is persisted to disk —
    -- #88). At startup, 'arProbeAndSweep' GCs dead agents from crashed
    -- processes; live agents are reused (the key is still loaded).
  , cdPinnedKnownHosts :: ByteString
  , cdKeyfilesDir     :: FilePath
  , cdIsRemote        :: Bool
    -- ^ Whether the untrusted executor runs commands over SSH (remote
    -- mode). When 'True', the deploy-key clone path uses @ssh -A@ agent
    -- forwarding with no @GIT_SSH_COMMAND@ (the remote @git clone@ uses
    -- the default @ssh@ + the forwarded agent + the remote machine's
    -- default @known_hosts@). When 'False', the local path writes a
    -- per-op @known_hosts@ temp file + uses @GIT_SSH_COMMAND@.
  }

-- | A stub 'CloneDeps' whose fields are all @error@ bottoms. Used by
-- 'uoRunLegacy' for non-Git opcodes (which never access 'CloneDeps' —
-- they don't call 'uioCd*'). Accessing any field of this stub is a
-- runtime error, which is the correct behavior: non-Git opcodes must
-- never touch the Git credential surface.
stubCloneDeps :: CloneDeps
stubCloneDeps = CloneDeps
  { cdVault = error "stubCloneDeps: cdVault (non-Git opcode must not access)"
  , cdRepoReg = error "stubCloneDeps: cdRepoReg (non-Git opcode must not access)"
  , cdSshAgent = error "stubCloneDeps: cdSshAgent (non-Git opcode must not access)"
  , cdAgentRegistry = error "stubCloneDeps: cdAgentRegistry (non-Git opcode must not access)"
  , cdPinnedKnownHosts = error "stubCloneDeps: cdPinnedKnownHosts (non-Git opcode must not access)"
  , cdKeyfilesDir = error "stubCloneDeps: cdKeyfilesDir (non-Git opcode must not access)"
  , cdIsRemote = False
  }

----------------------------------------------------------------------------
-- CloneTarget / CloneEnv (opaque, redacted Show, CPS-scoped)
----------------------------------------------------------------------------

-- | The authenticated bits for a single clone, scoped to 'withCloneTarget'.
-- The constructors are NOT exported — callers observe the bits only via the
-- CPS continuation, mirroring 'Seal.Security.Secrets.withApiKey'. 'Show' is
-- redacted so a stray log/exception cannot leak the env extras.
data CloneTarget = CloneTarget
  { ctEnv :: CloneEnv
  , ctCleanup :: IO ()
  }

instance Show CloneTarget where
  show _ = "CloneTarget <redacted>"

-- | The environment passed to @git@. 'ceUrl' is the TOKEN-FREE URL;
-- 'ceEnvExtras' carries only non-secret values (@SSH_AUTH_SOCK@ +
-- @GIT_SSH_COMMAND@ for deploy keys, @GIT_TERMINAL_PROMPT=0@ always). The
-- secret bytes (the passphrase for deploy keys, the token for PATs) live
-- only in the ssh-agent's memory (deploy keys) or the git argv
-- (@http.extraHeader@ for PATs — memory, no file).
data CloneEnv = CloneEnv
  { ceUrl :: Text
    -- ^ The token-free URL passed to @git clone@ / @git ls-remote@.
  , ceGitConfigArgs :: [Text]
    -- ^ Extra @-c@ config args. PAT/MachineUser: @["-c",
    -- "http.extraHeader=Authorization: Basic \<base64\>"]@ (memory, no
    -- file). DeployKey: @[]@ (uses the agent, not extraHeader).
  , ceSshCommand :: Maybe Text
    -- ^ @GIT_SSH_COMMAND@ value (deploy-key only). Carries the pinned
    -- @known_hosts@ PATH, not the key bytes (the key is in the agent).
  , ceEnvExtras :: [(String, String)]
    -- ^ Env overrides MERGED over the inherited environment. Carries
    -- @SSH_AUTH_SOCK@ / @GIT_SSH_COMMAND@ / @GIT_TERMINAL_PROMPT@ — only
    -- non-secret values (paths + "0"). On the remote executor (deploy
    -- key), @SSH_AUTH_SOCK@ / @SSH_AGENT_PID@ are OMITTED (the forwarded
    -- agent via @ssh -A@ replaces them) and @GIT_SSH_COMMAND@ carries no
    -- @UserKnownHostsFile=@ path (the remote arm writes the known_hosts
    -- to a remote temp file + rewrites the command).
  , ceKnownHostsContent :: Maybe ByteString
    -- ^ The pinned @known_hosts@ content (public data) for the REMOTE
    -- deploy-key path. 'Just' the bytes when @cdIsRemote@ + deploy key;
    -- 'Nothing' otherwise (the local arm writes its own temp file). The
    -- remote arm of 'uioShellExecGitEnv' writes this to a remote temp
    -- file + rewrites @GIT_SSH_COMMAND@ to reference it.
  , ceRawToken :: Maybe ByteString
    -- ^ The raw PAT/MachineUser token bytes for the @gh@ credential
    -- injection path (design §3.4 Option A). 'Just' the raw bytes for
    -- PAT/MachineUser (the @gh@ path injects @GH_TOKEN@ from these
    -- bytes); 'Nothing' for deploy keys (@gh@ can't use SSH, falls
    -- through to plain exec). The @git@ path ignores this field (it
    -- uses 'ceGitConfigArgs' for the base64 @http.extraHeader@). Same
    -- security category as 'ceGitConfigArgs' (which carries the
    -- base64-encoded header — trivially reversible); CPS-scoped via
    -- 'withCloneTarget' (the value is only obtainable inside the
    -- continuation). 'CloneEnv' has NO 'Show' instance by design — a
    -- stray @show@/log/exception cannot leak any field.
  , ceCleanup :: IO ()
    -- ^ Removes the per-op @known_hosts@ temp file + kills the agent. Run
    -- by 'withCloneTarget' after the continuation (bracket — on success AND
    -- failure).
  }

-- | Scope the authenticated bits + cleanup to the continuation (mirrors
-- 'Seal.Security.Secrets.withApiKey'). The cleanup ALWAYS runs, even if the
-- continuation throws — 'bracket' semantics.
withCloneTarget :: CloneTarget -> (CloneEnv -> IO r) -> IO r
withCloneTarget target k =
  bracket (pure target) ctCleanup (k . ctEnv)

----------------------------------------------------------------------------
-- resolveCloneTarget
----------------------------------------------------------------------------

-- | Resolve a 'SourceRepo' to a 'CloneTarget' — fetches the secret bytes
-- from the vault, runs the per-op ssh-agent lifecycle (deploy keys), and
-- writes the per-op @known_hosts@ temp file (public data, bracket-cleaned).
--
-- For deploy keys: @sahStart@ → @sahAddKey <enc-keyfile> <passphrase>@
-- (passphrase from the vault, piped to @ssh-add@'s stdin via the fake/real
-- 'SshAgentHandle'). The agent decrypts the encrypted keyfile into memory.
-- On any agent failure → 'CloneAgentError' (fail closed — the cleartext key
-- never made it to the agent).
--
-- For PAT/MachineUser: the token is fetched from the vault and base64-encoded
-- into @http.extraHeader=Authorization: Basic \<base64(user:token)\>@ (for
-- MachineUser, the username is the public @cUsername@). The header lives
-- only in 'ceGitConfigArgs' (memory, no file).
--
-- The per-op @known_hosts@ temp file is written under a random-suffix name
-- (§5.5) and @bracket@-cleaned via 'withCloneTarget'.
resolveCloneTarget
  :: CloneDeps -> SourceRepo -> IO (Either CloneError CloneTarget)
resolveCloneTarget deps repo =
  case planClone repo of
    Left e -> pure (Left e)
    Right plan -> case plan of
      ClonePlanExtraHeader httpsUrl vaultKey -> do
        eVault <- resolveVaultHandle deps
        case eVault of
          Left e -> pure (Left e)
          Right vault -> do
            mtoken <- vhGet vault vaultKey
            case mtoken of
              Left ve -> pure (Left (CloneVaultError ve))
              Right tokenBytes -> do
                let header = renderPatHeader repo tokenBytes
                    envExtras = [("GIT_TERMINAL_PROMPT", "0")]
                    env = CloneEnv
                      { ceUrl = httpsUrl
                      , ceGitConfigArgs = ["-c", "http.extraHeader=" <> header]
                      , ceSshCommand = Nothing
                      , ceEnvExtras = envExtras
                      , ceKnownHostsContent = Nothing
                      , ceRawToken = Just tokenBytes
                      , ceCleanup = pure ()
                      }
                pure (Right CloneTarget { ctEnv = env, ctCleanup = pure () })
      ClonePlanSshKey sshUrl _vaultKey -> do
        -- The encrypted keyfile path: <keyfilesDir>/<repo-id>.
        let keyfilePath = cdKeyfilesDir deps </> keyfileBaseName repo
            vaultKey = cVaultKey (srCredential repo)
        eVault <- resolveVaultHandle deps
        case eVault of
          Left e -> pure (Left e)
          Right vault -> do
            -- Fetch the passphrase from the vault (decrypts the keyfile).
            mpass <- vhGet vault vaultKey
            case mpass of
              Left ve -> pure (Left (CloneVaultError ve))
              Right passphrase -> do
                -- One-agent-per-repo: look up the persistent registry by
                -- vault key. If a live agent is cached (in this process or
                -- persisted from a prior seal process), reuse it — the key
                -- is still loaded. If the persisted agent is dead (crashed
                -- seal), remove the stale entry and start a fresh agent.
                -- If no entry exists, start a new agent + load the key
                -- once, then persist (#88).
                registry <- arLoad (cdAgentRegistry deps)
                agentEnv <- case Map.lookup vaultKey registry of
                  Just cachedEnv -> do
                    -- If the agent was started in THIS process, reuse it
                    -- directly (no probe — it's alive). If it was loaded
                    -- from a prior process's persisted registry, probe to
                    -- check liveness (#88).
                    isLive <- arIsLive (cdAgentRegistry deps) vaultKey
                    if isLive
                      then pure cachedEnv  -- reuse (key still loaded)
                      else do
                        status <- probeAgent cachedEnv
                        case status of
                          AgentAlive -> pure cachedEnv  -- reuse across restart
                          AgentDead -> do
                            -- GC the stale entry + start a fresh agent.
                            arRemove (cdAgentRegistry deps) vaultKey
                            startAndLoadAgent deps vaultKey keyfilePath passphrase
                  Nothing -> startAndLoadAgent deps vaultKey keyfilePath passphrase
                -- Build the CloneEnv. The key stays loaded (no per-op
                -- sahDeleteAll); the cleanup is a no-op (the agent is
                -- killed at harness shutdown, not per-op).
                if cdIsRemote deps
                  then do
                    -- REMOTE deploy-key path (simple approach matching the
                    -- verified working command): no GIT_SSH_COMMAND, no
                    -- remote known_hosts file. The remote git clone uses
                    -- the default ssh + the forwarded agent (via ssh -A)
                    -- + the remote machine's default known_hosts. The
                    -- SSH_AUTH_SOCK/SSH_AGENT_PID are in ceEnvExtras for
                    -- the LOCAL ssh -A process (the remote arm extracts
                    -- them for local env + strips from remote env prefix).
                    let authEnv = sahGetAuthEnv (cdSshAgent deps) agentEnv
                        envExtras =
                          authEnv ++
                          [ ("GIT_TERMINAL_PROMPT", "0")
                          ]
                        env = CloneEnv
                          { ceUrl = sshUrl
                          , ceGitConfigArgs = []
                          , ceSshCommand = Nothing
                          , ceEnvExtras = envExtras
                          , ceKnownHostsContent = Nothing
                          , ceRawToken = Nothing
                          , ceCleanup = pure ()
                          }
                    pure (Right CloneTarget { ctEnv = env, ctCleanup = pure () })
                  else do
                    -- LOCAL deploy-key path: write the per-op
                    -- @known_hosts@ temp file (public data) to the
                    -- harness-private @cdKeyfilesDir@.
                    (knownHostsPath, knownHostsCleanup) <-
                      writeKnownHostsTemp (cdKeyfilesDir deps)
                                           (cdPinnedKnownHosts deps)
                    -- NOTE: IdentitiesOnly is intentionally omitted from
                    -- GIT_SSH_COMMAND. On macOS, the bundled /usr/bin/ssh
                    -- suppresses agent-offered keys when
                    -- IdentitiesOnly=yes is set and no -i flag is passed
                    -- — it only tries identity files, not the agent.
                    -- Without this flag, ssh tries agent keys first (which
                    -- is what we want — the per-op agent holds exactly one
                    -- deploy key). The per-op agent scoping invariant
                    -- (exactly one key live at forwarding time) replaces
                    -- what IdentitiesOnly would enforce.
                    let authEnv = sahGetAuthEnv (cdSshAgent deps) agentEnv
                        sshCmd = T.pack
                          ( "ssh"
                          <> " -o StrictHostKeyChecking=yes"
                          <> " -o BatchMode=yes"
                          <> " -o UserKnownHostsFile=" <> knownHostsPath
                          )
                        envExtras =
                          [ ("SSH_AUTH_SOCK", saeAuthSock agentEnv)
                          , ("SSH_AGENT_PID", saeAgentPid agentEnv)
                          , ("GIT_SSH_COMMAND", T.unpack sshCmd)
                          , ("GIT_TERMINAL_PROMPT", "0")
                          ]
                        env = CloneEnv
                          { ceUrl = sshUrl
                          , ceGitConfigArgs = []
                          , ceSshCommand = Just sshCmd
                          , ceEnvExtras = authEnv ++ envExtras
                          , ceKnownHostsContent = Nothing
                          , ceRawToken = Nothing
                          , ceCleanup = knownHostsCleanup
                          }
                    pure (Right CloneTarget { ctEnv = env, ctCleanup = knownHostsCleanup })

-- | Start a fresh ssh-agent + load the deploy key once, then persist the
-- agent env to the registry so it's reused across ops (and across seal
-- restarts — #88). On failure, fail closed (delete-all + error).
startAndLoadAgent :: CloneDeps -> Text -> FilePath -> ByteString -> IO SshAgentEnv
startAndLoadAgent deps vaultKey keyfilePath passphrase = do
  eStart <- sahStart (cdSshAgent deps)
  case eStart of
    Left msg -> error (T.unpack msg)
    Right env -> do
      eAdd <- sahAddKey (cdSshAgent deps) env keyfilePath passphrase
      case eAdd of
        Left msg -> do
          -- Fail closed: delete-all even on add failure.
          sahDeleteAll (cdSshAgent deps) env
          error (T.unpack msg)
        Right () -> do
          -- Persist the agent env so a second seal process (or a restart)
          -- reuses this agent instead of spawning a new one (#88).
          arUpsert (cdAgentRegistry deps) vaultKey env
          pure env

-- | The base name of the encrypted keyfile for a 'SourceRepo' — the
-- 'repoIdText' (validated @[A-Za-z0-9_-]+@, no path separators — §5.2
-- defense-in-depth). The keyfile lives at
-- @\<cdKeyfilesDir\>\/\<repo-id\>@.
keyfileBaseName :: SourceRepo -> FilePath
keyfileBaseName repo = T.unpack (repoIdText (srId repo))

-- | Resolve the live 'VaultHandle' from the 'VaultRuntime' (mirrors
-- @secretGetOp@'s pattern at @Seal.ISA.Ops.Secret:73@). Fail-closed to
-- 'CloneVaultError VaultLocked' if the vault is unconfigured/locked (the
-- 'IORef' holds 'Nothing'). This is the W3 evolution: @cdVault@ is now
-- 'VaultRuntime' (not the raw 'VaultHandle') so the opcode can be built once
-- at startup and the vault-locked state is surfaced per-op at run time
-- (rather than crashing at startup or silently using a stale handle).
resolveVaultHandle :: CloneDeps -> IO (Either CloneError VaultHandle)
resolveVaultHandle deps = do
  mh <- readIORef (vrHandleRef (cdVault deps))
  pure $ case mh of
    Nothing -> Left (CloneVaultError VaultLocked)
    Just h  -> Right h

-- | Render the @http.extraHeader@ value for a PAT/MachineUser: @Authorization:
-- Basic \<base64(user:token)\>@. For 'CredPat' the "user" is
-- @x-access-token@; for 'CredMachineUser' it's the public @cUsername@. The
-- header lives only in the git argv (memory, no file).
--
-- The base64 is computed over the RAW @user:token@ bytes (NOT a UTF-8
-- round-trip through 'Text') — a vault token containing non-UTF-8 bytes
-- (rare for GitHub PATs which are ASCII, but possible for MachineUser
-- tokens or future cred types) is base64-encoded verbatim, avoiding the
-- U+FFFD corruption that 'TE.decodeUtf8Lenient' would introduce before
-- base64. The base64 output is pure ASCII, so the final
-- 'TE.decodeUtf8Lenient' is lossless.
renderPatHeader :: SourceRepo -> ByteString -> Text
renderPatHeader repo tokenBytes =
  let userBytes = case srCredential repo of
        CredPat _            -> "x-access-token"
        CredMachineUser _ u  -> TE.encodeUtf8 u
        CredDeployKey _       -> "x-access-token"
      basic = userBytes <> ":" <> tokenBytes
      encoded = B64.encode basic
  in "Authorization: Basic " <> TE.decodeUtf8Lenient encoded

----------------------------------------------------------------------------
-- Private temp file writer (random suffix + O_EXCL — §5.5)
----------------------------------------------------------------------------

-- | Write a temp @known_hosts@ file (public data — the pinned GitHub host
-- keys) under the harness-private @parentDir@ (the 0700 @cdKeyfilesDir@)
-- with a random-suffix name via 'openBinaryTempFile' (which uses @O_EXCL@
-- under the hood — prevents a symlink-race / TOCTOU attack on the path git
-- reads: an attacker cannot pre-plant a symlink at the chosen path because
-- @O_EXCL@ fails if the file already exists). The file is 0600 (private —
-- the content is public but the path git reads must be tamper-resistant, so
-- we don't make it world-readable). Returns the path + a cleanup action
-- (removes the file). 'bracket'-cleaned via the post-add bracket in
-- 'resolveCloneTarget'.
--
-- Security rationale: the path git reads via @UserKnownHostsFile=@ must be
-- integrity-protected, not just the content. A @/tmp@ location would be
-- world-writable + symlink-raceable; a local attacker could swap the file
-- between our write and git's read, planting an attacker-controlled host
-- key → MITM the next git SSH connection. The 0700 @cdKeyfilesDir@ closes
-- the race (only the harness user can write there) + @O_EXCL@ closes the
-- symlink plant (the open fails if the path already exists).
writeKnownHostsTemp :: FilePath -> ByteString -> IO (FilePath, IO ())
writeKnownHostsTemp parentDir contents = do
  createDirectoryIfMissing True parentDir
  (path, h) <- openBinaryTempFile parentDir "seal-known-hosts-"
  BS.hPutStr h contents
  hClose h
  setFileMode path 0o600
  -- Idempotent cleanup: the bracket release in 'resolveCloneTarget' AND
  -- 'withCloneTarget' both call this (the bracket release runs first on
  -- success, then 'ctCleanup' runs again — the second 'removeFile' would
  -- throw NoSuchThing). Swallow the IOException so double-cleanup is safe.
  let cleanup = do
        _ <- try @IOError (removeFile path)
        pure ()
  pure (path, cleanup)

----------------------------------------------------------------------------
-- cloneRepo / lsRemoteRepo
----------------------------------------------------------------------------

-- | @git clone@ a 'SourceRepo' into @destDir@ using the resolved credential.
-- The token/passphrase NEVER appears in argv, the URL, or the env (only
-- @SSH_AUTH_SOCK@ / @GIT_SSH_COMMAND@ / @http.extraHeader@ — non-secret
-- paths + the base64-encoded Basic header which is in argv, in memory). On
-- non-zero exit → 'CloneGitFailed' with the exit code ONLY (stderr is
-- DROPPED — §5.4). Cleanup runs via 'withCloneTarget' (bracket — on success
-- AND failure).
cloneRepo
  :: CloneDeps -> FilePath -> SourceRepo -> IO (Either CloneError ())
cloneRepo deps destDir repo =
  resolveCloneTarget deps repo >>= \case
    Left e -> pure (Left e)
    Right target -> withCloneTarget target $ \env -> do
      let gitArgs = ceGitConfigArgsList env
                     <> ["clone", "--", T.unpack (ceUrl env), destDir]
      (ec, _out, _err) <-
        readProcessBinaryCwdEnv Nothing (ceEnvExtras env) "git" gitArgs BS.empty
      pure $ case ec of
        ExitSuccess   -> Right ()
        ExitFailure n -> Left (CloneGitFailed n)

-- | @git ls-remote@ a 'SourceRepo' (for @/repo test@). Same seam as
-- 'cloneRepo'; on success returns the first line of stdout
-- (@<sha>\\t<ref>@ — W5 echoes it). On non-zero exit → 'CloneGitFailed' with
-- the exit code ONLY (no stderr).
lsRemoteRepo
  :: CloneDeps -> SourceRepo -> IO (Either CloneError Text)
lsRemoteRepo deps repo =
  resolveCloneTarget deps repo >>= \case
    Left e -> pure (Left e)
    Right target -> withCloneTarget target $ \env -> do
      let gitArgs = ceGitConfigArgsList env
                     <> ["ls-remote", "--", T.unpack (ceUrl env)]
      (ec, out, _err) <-
        readProcessBinaryCwdEnv Nothing (ceEnvExtras env) "git" gitArgs BS.empty
      pure $ case ec of
        ExitSuccess   -> Right (firstLine out)
        ExitFailure n -> Left (CloneGitFailed n)
  where
    firstLine bs =
      let l = BS.takeWhile (/= nl) bs
      in TE.decodeUtf8Lenient l
    nl = 10  -- '\n'

-- | Render 'ceGitConfigArgs' as a list of 'String' for the git argv. Each
-- element is already a complete argv token (@-c@ / @http.extraHeader=...@).
ceGitConfigArgsList :: CloneEnv -> [String]
ceGitConfigArgsList env = map T.unpack (ceGitConfigArgs env)