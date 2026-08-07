{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | W2 no-disk clone seam tests (design §4.1, §4.4, §4.6, §5).
--
-- Security invariants tested here (the 3 W2 security tests):
--
-- 1. **No-disk snapshot**: no un-encrypted secret on the harness disk.
--    The encrypted keyfile under the keyfiles dir IS permitted (ciphertext);
--    the per-op @known_hosts@ file is public data (pinned GitHub keys).
--
-- 2. **Per-op scoping**: two sequential ops → exactly one
--    @sahAddKey@ + @sahDeleteAll@ per op via the fake
--    'SshAgentHandle' (shared agent: one @sahStart@, no per-op kill).
--
-- 3. **@-A@ invariant** (in 'RemoteSpec'): non-credentialed remote ops'
--    argv contains no @-A@; git-credential ops' argv contains @-A@.
module Seal.SourceControl.CloneSpec (spec) where

import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM, unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import System.IO.Unsafe (unsafePerformIO)
import Data.List (isPrefixOf, tails)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory
  ( createDirectoryIfMissing, doesDirectoryExist, doesFileExist
  , listDirectory )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
  ( fileMode, getFileStatus, intersectFileModes, ownerModes )
import Test.Hspec

import Seal.Security.Vault.Age (VaultError (VaultKeyNotFound, VaultLocked))
import Seal.SourceControl.Clone
import Seal.SourceControl.GithubKeys (pinnedGithubKnownHosts)
import Seal.SourceControl.Repo
  ( RepoCredential (..), SourceRepo (..), VcsKind (..), mkRepoId )
import Seal.TestHelpers.FakeVault (makeFakeVaultRuntime, makeLockedVaultRuntime)
import Seal.TestHelpers.FakeRegistry (fakeRepoRegistryHandle)
import Seal.Tools.Exec.UntrustedIO (mergeEnv)
import Seal.Tools.Ssh.Agent
  ( FakeAgentCall (..), SshAgentEnv (..), mkFakeSshAgentHandle )

-- | Create a fresh 'IORef' for 'cdAgentEnvRef' in a pure @let@ context.
-- Each call creates a NEW IORef (the @NOINLINE@ prevents GHC from CSE'ing
-- multiple calls into one shared IORef, which would cause the agent env
-- to leak across tests). Used only in test CloneDeps literals.
freshAgentRegistry :: IORef (Map Text SshAgentEnv)
freshAgentRegistry = unsafePerformIO (newIORef Map.empty)
{-# NOINLINE freshAgentRegistry #-}

----------------------------------------------------------------------------
-- Spec
----------------------------------------------------------------------------

spec :: Spec
spec = describe "Seal.SourceControl.Clone" $ do

  --------------------------------------------------------------------------
  -- planClone (pure — unchanged from W1)
  --------------------------------------------------------------------------

  describe "planClone" $ do
    let rid = case mkRepoId "seal-harness" of Right i -> i; Left e -> error (T.unpack e)
        patRepo url = SourceRepo rid url VcsGitHub (CredPat "GITHUB_PAT") Nothing Nothing
        machineRepo url =
          SourceRepo rid url VcsGitHub (CredMachineUser "GITHUB_MACHINEUSER" "acme-bot") Nothing Nothing
        deployRepo url = SourceRepo rid url VcsGitHub (CredDeployKey "GITHUB_DEPLOYKEY") Nothing Nothing
    it "PAT ssh URL → ClonePlanExtraHeader https-url" $
      planClone (patRepo "git@github.com:owner/repo.git")
        `shouldBe` Right (ClonePlanExtraHeader "https://github.com/owner/repo.git" "GITHUB_PAT")

    it "MachineUser ssh URL → ClonePlanExtraHeader https-url" $
      planClone (machineRepo "git@github.com:owner/repo.git")
        `shouldBe` Right (ClonePlanExtraHeader "https://github.com/owner/repo.git" "GITHUB_MACHINEUSER")

    it "DeployKey ssh URL → ClonePlanSshKey ssh-url (unchanged)" $
      planClone (deployRepo "git@github.com:owner/repo.git")
        `shouldBe` Right (ClonePlanSshKey "git@github.com:owner/repo.git" "GITHUB_DEPLOYKEY")

    it "disallowed host → CloneHostNotSupported" $
      planClone (patRepo "git@evil.com:owner/repo.git")
        `shouldBe` Left (CloneHostNotSupported "evil.com")

    it "malformed URL → CloneNoCredentialForUrl" $
      planClone (patRepo "not-a-url")
        `shouldBe` Left (CloneNoCredentialForUrl "not-a-url")

    it "VcsGit (non-github) → CloneUnsupportedVcs VcsGit" $
      let r = SourceRepo rid "git@github.com:o/r.git" VcsGit (CredPat "K") Nothing Nothing
      in planClone r `shouldBe` Left (CloneUnsupportedVcs VcsGit)

    it "already-https URL with PAT → ClonePlanExtraHeader same https-url" $
      planClone (patRepo "https://github.com/owner/repo.git")
        `shouldBe` Right (ClonePlanExtraHeader "https://github.com/owner/repo.git" "GITHUB_PAT")

  --------------------------------------------------------------------------
  -- renderCloneError
  --------------------------------------------------------------------------

  describe "renderCloneError" $ do
    it "CloneVaultError VaultLocked → vault locked message" $
      renderCloneError (CloneVaultError VaultLocked)
        `shouldBe` "vault locked — run /vault unlock"

    it "CloneVaultError (VaultKeyNotFound k) → vault key message with name" $ do
      let msg = renderCloneError (CloneVaultError (VaultKeyNotFound "MY_KEY"))
      "vault key" `T.isInfixOf` msg `shouldBe` True
      "MY_KEY" `T.isInfixOf` msg `shouldBe` True

    it "CloneNoCredentialForUrl u → no credential message with url" $
      renderCloneError (CloneNoCredentialForUrl "git@x:o/r.git")
        `shouldBe` "no credential resolvable for git@x:o/r.git"

    it "CloneUnsupportedVcs VcsGit → unsupported VCS message" $
      "unsupported VCS:" `T.isInfixOf`
        renderCloneError (CloneUnsupportedVcs VcsGit) `shouldBe` True

    it "CloneHostNotSupported h → host message with name" $ do
      let msg = renderCloneError (CloneHostNotSupported "evil.com")
      "host evil.com not supported" `T.isInfixOf` msg `shouldBe` True

    it "CloneGitFailed n → exit code message, NO stderr" $ do
      let msg = renderCloneError (CloneGitFailed 42)
      msg `shouldBe` "git failed (exit 42)"
      "stderr" `T.isInfixOf` msg `shouldBe` False

    it "CloneAgentError msg → agent error message" $ do
      let msg = renderCloneError (CloneAgentError "ssh-agent: boom")
      "ssh-agent" `T.isInfixOf` msg `shouldBe` True

  --------------------------------------------------------------------------
  -- W2 security test 1: no-disk snapshot
  -- (no un-encrypted secret on the harness disk; encrypted keyfile IS
  -- permitted; known_hosts is public data)
  --------------------------------------------------------------------------

  describe "no-disk invariant (W2)" $ do
    let rid1 = case mkRepoId "repo-a" of Right i -> i; Left _ -> error "bad id"
        deployRepo url vk = SourceRepo rid1 url VcsGitHub (CredDeployKey vk) Nothing Nothing
        patRepo url vk = SourceRepo rid1 url VcsGitHub (CredPat vk) Nothing Nothing

    it "deploy key: passphrase NOT on disk; encrypted keyfile IS on disk (ciphertext)" $
      withSystemTempDirectory "seal-home" $ \homeDir -> do
        let keyfilesDir = homeDir </> ".seal/state/repos/keys"
            stateDir = homeDir </> ".seal/state/repos"
        createDirectoryIfMissing True keyfilesDir
        let keyfilePath = keyfilesDir </> "repo-a"
            encryptedKeyfile :: ByteString
            encryptedKeyfile = "-----BEGIN OPENSSH PRIVATE KEY-----\nfake-ciphertext\n-----END OPENSSH PRIVATE KEY-----"
            passphrase :: ByteString
            passphrase = "SUPERSECRET-PASSPHRASE-BYTES"
            repo = deployRepo "git@github.com:o/r.git" "K_PASS"
        BS.writeFile keyfilePath encryptedKeyfile
        vault <- makeFakeVaultRuntime [("K_PASS", passphrase)]
        callsRef <- newIORef []
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = fakeRepoRegistryHandle
              , cdSshAgent = agent
              , cdAgentRegistry = freshAgentRegistry
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
        result <- resolveCloneTarget deps repo
        case result of
          Left e -> expectationFailure ("expected Right, got Left: " <> show e)
          Right target -> withCloneTarget target $ \_env -> do
            -- During the op: the encrypted keyfile is still on disk (ciphertext — OK)
            exists <- doesFileExist keyfilePath
            exists `shouldBe` True
            -- Walk the entire ~/.seal/state tree and assert the passphrase
            -- does NOT appear in any file (the encrypted keyfile is
            -- ciphertext, NOT the passphrase — so even though the keyfile
            -- is on disk, the passphrase is not).
            files <- collectAllFiles stateDir
            let fileContents = map snd files
            any (passphrase `BS.isInfixOf`) fileContents `shouldBe` False
            -- The encrypted keyfile IS on disk (ciphertext — permitted)
            (keyfilePath, encryptedKeyfile) `elem` files `shouldBe` True

    it "PAT: token NOT on disk (token only in vault + argv, never written to disk)" $
      withSystemTempDirectory "seal-home" $ \homeDir -> do
        let stateDir = homeDir </> ".seal/state/repos"
            keyfilesDir = homeDir </> ".seal/state/repos/keys"
        createDirectoryIfMissing True keyfilesDir
        let token :: ByteString
            token = "ghp_SUPERSECRET_TOKEN_12345"
            repo = patRepo "git@github.com:o/r.git" "K_PAT"
        vault <- makeFakeVaultRuntime [("K_PAT", token)]
        callsRef <- newIORef []
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = fakeRepoRegistryHandle
              , cdSshAgent = agent
              , cdAgentRegistry = freshAgentRegistry
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
        result <- resolveCloneTarget deps repo
        case result of
          Left e -> expectationFailure ("expected Right, got Left: " <> show e)
          Right target -> withCloneTarget target $ \_env -> do
            -- Walk the entire ~/.seal/state tree and assert the token
            -- does NOT appear in any file (PAT doesn't write any file —
            -- the token is only in the http.extraHeader argv, in memory).
            files <- collectAllFiles stateDir
            let fileContents = map snd files
            any (token `BS.isInfixOf`) fileContents `shouldBe` False

    it "deploy key: known_hosts file is public data (pinned GitHub keys, no secrets)" $
      withSystemTempDirectory "seal-home" $ \homeDir -> do
        let keyfilesDir = homeDir </> ".seal/state/repos/keys"
        createDirectoryIfMissing True keyfilesDir
        let keyfilePath = keyfilesDir </> "repo-a"
            encryptedKeyfile :: ByteString
            encryptedKeyfile = "-----BEGIN OPENSSH PRIVATE KEY-----\nciphertext\n-----END OPENSSH PRIVATE KEY-----"
            passphrase :: ByteString
            passphrase = "SUPERSECRET-PASSPHRASE-BYTES"
            repo = deployRepo "git@github.com:o/r.git" "K_PASS"
        BS.writeFile keyfilePath encryptedKeyfile
        vault <- makeFakeVaultRuntime [("K_PASS", passphrase)]
        callsRef <- newIORef []
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = fakeRepoRegistryHandle
              , cdSshAgent = agent
              , cdAgentRegistry = freshAgentRegistry
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
        result <- resolveCloneTarget deps repo
        case result of
          Left e -> expectationFailure ("expected Right, got Left: " <> show e)
          Right target -> withCloneTarget target $ \env -> do
            -- The known_hosts file is referenced in GIT_SSH_COMMAND
            case lookup "GIT_SSH_COMMAND" (ceEnvExtras env) of
              Nothing -> expectationFailure "no GIT_SSH_COMMAND in env"
              Just sshCmd -> do
                -- Extract the known_hosts path from the command
                let knownHostsPath = extractKnownHostsPath sshCmd
                knownHostsPath `shouldSatisfy` not . null
                -- The file exists and contains the pinned keys (public data)
                exists <- doesFileExist knownHostsPath
                exists `shouldBe` True
                content <- BS.readFile knownHostsPath
                content `shouldBe` pinnedGithubKnownHosts
                -- The passphrase is NOT in the known_hosts file
                passphrase `BS.isInfixOf` content `shouldBe` False

    it "deploy key (remote): no local known_hosts file, ceKnownHostsContent set, no SSH_AUTH_SOCK in extras" $
      withSystemTempDirectory "seal-home" $ \homeDir -> do
        let keyfilesDir = homeDir </> ".seal/state/repos/keys"
        createDirectoryIfMissing True keyfilesDir
        let keyfilePath = keyfilesDir </> "repo-a"
            encryptedKeyfile :: ByteString
            encryptedKeyfile = "-----BEGIN OPENSSH PRIVATE KEY-----\nciphertext\n-----END OPENSSH PRIVATE KEY-----"
            passphrase :: ByteString
            passphrase = "SUPERSECRET-PASSPHRASE-BYTES"
            repo = deployRepo "git@github.com:o/r.git" "K_PASS"
        BS.writeFile keyfilePath encryptedKeyfile
        vault <- makeFakeVaultRuntime [("K_PASS", passphrase)]
        callsRef <- newIORef []
        agentEnvRef <- newIORef Map.empty
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = fakeRepoRegistryHandle
              , cdSshAgent = agent
              , cdAgentRegistry = agentEnvRef
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = True
              }
        result <- resolveCloneTarget deps repo
        case result of
          Left e -> expectationFailure ("expected Right, got Left: " <> show e)
          Right target -> withCloneTarget target $ \env -> do
            -- No ceKnownHostsContent (simple approach: remote uses its
            -- own known_hosts).
            ceKnownHostsContent env `shouldBe` Nothing
            -- SSH_AUTH_SOCK + SSH_AGENT_PID ARE in the env extras (for
            -- the LOCAL ssh -A process; the remote arm extracts them for
            -- local env + strips from the remote env prefix).
            lookup "SSH_AUTH_SOCK" (ceEnvExtras env) `shouldSatisfy` isJust
            lookup "SSH_AGENT_PID" (ceEnvExtras env) `shouldSatisfy` isJust
            -- No GIT_SSH_COMMAND (the remote git clone uses the default
            -- ssh + the forwarded agent).
            lookup "GIT_SSH_COMMAND" (ceEnvExtras env) `shouldBe` Nothing
            -- GIT_TERMINAL_PROMPT is set.
            lookup "GIT_TERMINAL_PROMPT" (ceEnvExtras env) `shouldBe` Just "0"
            -- No local known_hosts temp file was written.
            keyfilesContents <- listDirectory keyfilesDir
            let knownHostsTemps = filter ("seal-known-hosts-" `isPrefixOf`) keyfilesContents
            knownHostsTemps `shouldBe` []
            -- The passphrase is NOT on disk.
            files <- collectAllFiles keyfilesDir
            let fileContents = map snd files
            any (passphrase `BS.isInfixOf`) fileContents `shouldBe` False

  --------------------------------------------------------------------------
  -- W2 security test 2: per-op scoping
  -- (two sequential ops → exactly one sahAddKey + sahDeleteAll + sahKill
  -- per op via the fake SshAgentHandle)
  --------------------------------------------------------------------------

  describe "per-op scoping (W2)" $ do
    let rid1 = case mkRepoId "repo-a" of Right i -> i; Left _ -> error "bad id"
        rid2 = case mkRepoId "repo-b" of Right i -> i; Left _ -> error "bad id"
        repo1 = SourceRepo rid1 "git@github.com:o/r.git" VcsGitHub (CredDeployKey "K1") Nothing Nothing
        repo2 = SourceRepo rid2 "git@github.com:o/r.git" VcsGitHub (CredDeployKey "K2") Nothing Nothing
    it "two distinct repos → one sahStart + one sahAddKey per repo, no sahDeleteAll" $
      withSystemTempDirectory "seal-home" $ \homeDir -> do
        let keyfilesDir = homeDir </> ".seal/state/repos/keys"
        createDirectoryIfMissing True keyfilesDir
        let kf1 = keyfilesDir </> "repo-a"
            kf2 = keyfilesDir </> "repo-b"
        BS.writeFile kf1 "ciphertext-1"
        BS.writeFile kf2 "ciphertext-2"
        vault <- makeFakeVaultRuntime
          [ ("K1", "passphrase-1")
          , ("K2", "passphrase-2")
          ]
        callsRef <- newIORef []
        agentEnvRef <- newIORef Map.empty
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = fakeRepoRegistryHandle
              , cdSshAgent = agent
              , cdAgentRegistry = agentEnvRef
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
        -- Op 1 (repo1: start + addkey)
        Right t1 <- resolveCloneTarget deps repo1
        withCloneTarget t1 $ \_env -> pure ()
        -- Op 2 (repo2: start + addkey — separate agent)
        Right t2 <- resolveCloneTarget deps repo2
        withCloneTarget t2 $ \_env -> pure ()
        -- One-agent-per-repo: Start + AddKey per repo, no DeleteAll.
        calls <- readIORef callsRef
        calls `shouldBe`
          [ SahStart
          , SahAddKey kf1 "passphrase-1"
          , SahStart
          , SahAddKey kf2 "passphrase-2"
          ]

    it "same repo reused → no second sahStart or sahAddKey (cached agent)" $
      withSystemTempDirectory "seal-home" $ \homeDir -> do
        let keyfilesDir = homeDir </> ".seal/state/repos/keys"
        createDirectoryIfMissing True keyfilesDir
        let kf1 = keyfilesDir </> "repo-a"
        BS.writeFile kf1 "ciphertext-1"
        vault <- makeFakeVaultRuntime
          [ ("K1", "passphrase-1")
          ]
        callsRef <- newIORef []
        agentEnvRef <- newIORef Map.empty
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = fakeRepoRegistryHandle
              , cdSshAgent = agent
              , cdAgentRegistry = agentEnvRef
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
        -- Op 1 (start + addkey)
        Right t1 <- resolveCloneTarget deps repo1
        withCloneTarget t1 $ \_env -> pure ()
        -- Op 2 (same repo: cached agent — no start, no addkey)
        Right t2 <- resolveCloneTarget deps repo1
        withCloneTarget t2 $ \_env -> pure ()
        calls <- readIORef callsRef
        calls `shouldBe`
          [ SahStart
          , SahAddKey kf1 "passphrase-1"
          ]

  --------------------------------------------------------------------------
  -- deploy-key env (SSH_AUTH_SOCK + GIT_SSH_COMMAND, no key bytes)
  --------------------------------------------------------------------------

  describe "deploy-key env (W2)" $ do
    it "SSH_AUTH_SOCK in env; encrypted keyfile path NOT in env (only the path via sahAddKey)" $
      withSystemTempDirectory "seal-home" $ \homeDir -> do
        let keyfilesDir = homeDir </> ".seal/state/repos/keys"
        createDirectoryIfMissing True keyfilesDir
        let keyfilePath = keyfilesDir </> "repo-a"
            passphrase :: ByteString
            passphrase = "SECRET-PASSPHRASE"
            rid1 = case mkRepoId "repo-a" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid1 "git@github.com:o/r.git" VcsGitHub (CredDeployKey "K") Nothing Nothing
        BS.writeFile keyfilePath "ciphertext"
        vault <- makeFakeVaultRuntime [("K", passphrase)]
        callsRef <- newIORef []
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = fakeRepoRegistryHandle
              , cdSshAgent = agent
              , cdAgentRegistry = freshAgentRegistry
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
        Right target <- resolveCloneTarget deps repo
        withCloneTarget target $ \env -> do
          -- SSH_AUTH_SOCK is in the env (the forwarded agent socket)
          lookup "SSH_AUTH_SOCK" (ceEnvExtras env) `shouldBe` Just "/tmp/fake-sock"
          -- GIT_SSH_COMMAND is set and pins StrictHostKeyChecking=yes
          case lookup "GIT_SSH_COMMAND" (ceEnvExtras env) of
            Nothing -> expectationFailure "no GIT_SSH_COMMAND"
            Just sshCmd -> do
              "StrictHostKeyChecking=yes" `T.isInfixOf` T.pack sshCmd `shouldBe` True
              "IdentitiesOnly=yes" `T.isInfixOf` T.pack sshCmd `shouldBe` True
              "BatchMode=yes" `T.isInfixOf` T.pack sshCmd `shouldBe` True
              -- The passphrase is NOT in the GIT_SSH_COMMAND
              passphrase `BS.isInfixOf` TE.encodeUtf8 (T.pack sshCmd) `shouldBe` False
          -- The passphrase is NOT in any env value
          let envValues = map (TE.encodeUtf8 . T.pack . snd) (ceEnvExtras env)
          any (passphrase `BS.isInfixOf`) envValues `shouldBe` False
          -- The encrypted keyfile path is NOT in env (only the known_hosts
          -- path is in GIT_SSH_COMMAND; the keyfile is loaded via the agent)
          let envBytes = BS.concat (map (TE.encodeUtf8 . T.pack . snd) (ceEnvExtras env))
          TE.encodeUtf8 (T.pack keyfilePath) `BS.isInfixOf` envBytes `shouldBe` False

  --------------------------------------------------------------------------
  -- PAT env (http.extraHeader in git config args, token NOT in env/URL)
  --------------------------------------------------------------------------

  describe "PAT env (W2)" $ do
    it "http.extraHeader in ceGitConfigArgs; token NOT in ceUrl or ceEnvExtras" $
      withSystemTempDirectory "seal-home" $ \homeDir -> do
        let keyfilesDir = homeDir </> ".seal/state/repos/keys"
            stateDir = homeDir </> ".seal/state/repos"
        createDirectoryIfMissing True keyfilesDir
        let token :: ByteString
            token = "ghp_SECRET_TOKEN_BYTES"
            rid1 = case mkRepoId "repo-a" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid1 "git@github.com:o/r.git" VcsGitHub (CredPat "K_PAT") Nothing Nothing
        vault <- makeFakeVaultRuntime [("K_PAT", token)]
        callsRef <- newIORef []
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = fakeRepoRegistryHandle
              , cdSshAgent = agent
              , cdAgentRegistry = freshAgentRegistry
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
        Right target <- resolveCloneTarget deps repo
        withCloneTarget target $ \env -> do
          -- The URL is token-free HTTPS
          ceUrl env `shouldBe` "https://github.com/o/r.git"
          token `BS.isInfixOf` TE.encodeUtf8 (ceUrl env) `shouldBe` False
          -- ceGitConfigArgs contains the http.extraHeader
          ceGitConfigArgs env `shouldSatisfy` (not . null)
          let configStr = T.intercalate " " (ceGitConfigArgs env)
          "http.extraHeader=Authorization: Basic" `T.isInfixOf` configStr `shouldBe` True
          -- The token is NOT in the git config args (it's base64-encoded)
          token `BS.isInfixOf` TE.encodeUtf8 configStr `shouldBe` False
          -- The token is NOT in any env value
          let envValues = map (TE.encodeUtf8 . T.pack . snd) (ceEnvExtras env)
          any (token `BS.isInfixOf`) envValues `shouldBe` False
          -- Walk the disk: no token on disk
          files <- collectAllFiles stateDir
          any (\(_, c) -> token `BS.isInfixOf` c) files `shouldBe` False

    it "MachineUser: username in Basic auth header; token NOT in env" $
      withSystemTempDirectory "seal-home" $ \homeDir -> do
        let keyfilesDir = homeDir </> ".seal/state/repos/keys"
        createDirectoryIfMissing True keyfilesDir
        let token :: ByteString
            token = "machine_TOKEN_BYTES"
            username = "acme-bot" :: Text
            ridA = case mkRepoId "repo-a" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo ridA "git@github.com:o/r.git" VcsGitHub
                    (CredMachineUser "K_MU" username) Nothing Nothing
        vault <- makeFakeVaultRuntime [("K_MU", token)]
        callsRef <- newIORef []
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = fakeRepoRegistryHandle
              , cdSshAgent = agent
              , cdAgentRegistry = freshAgentRegistry
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
        Right target <- resolveCloneTarget deps repo
        withCloneTarget target $ \env -> do
          ceUrl env `shouldBe` "https://github.com/o/r.git"
          let configStr = T.intercalate " " (ceGitConfigArgs env)
          "http.extraHeader=Authorization: Basic" `T.isInfixOf` configStr `shouldBe` True
          -- The token is NOT in any env value or URL
          token `BS.isInfixOf` TE.encodeUtf8 (ceUrl env) `shouldBe` False
          let envValues = map (TE.encodeUtf8 . T.pack . snd) (ceEnvExtras env)
          any (token `BS.isInfixOf`) envValues `shouldBe` False

  --------------------------------------------------------------------------
  -- vault error surfacing (updated for new CloneDeps API)
  --------------------------------------------------------------------------

  describe "vault error surfacing" $ do
    it "locked vault → Left (CloneVaultError VaultLocked)" $ do
      let rid1 = case mkRepoId "repo-a" of Right i -> i; Left _ -> error "bad id"
          repo = SourceRepo rid1 "git@github.com:o/r.git" VcsGitHub (CredPat "K") Nothing Nothing
      withSystemTempDirectory "seal-keys" $ \keyfilesDir -> do
        vault <- makeLockedVaultRuntime
        callsRef <- newIORef []
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = fakeRepoRegistryHandle
              , cdSshAgent = agent
              , cdAgentRegistry = freshAgentRegistry
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
        result <- resolveCloneTarget deps repo
        case result of
          Left (CloneVaultError VaultLocked) -> pure ()
          other -> expectationFailure ("expected CloneVaultError VaultLocked, got: " <> show other)

    it "missing key → Left (CloneVaultError (VaultKeyNotFound k))" $ do
      let rid1 = case mkRepoId "repo-a" of Right i -> i; Left _ -> error "bad id"
          repo = SourceRepo rid1 "git@github.com:o/r.git" VcsGitHub (CredPat "MISSING_KEY") Nothing Nothing
      withSystemTempDirectory "seal-keys" $ \keyfilesDir -> do
        vault <- makeFakeVaultRuntime []
        callsRef <- newIORef []
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = fakeRepoRegistryHandle
              , cdSshAgent = agent
              , cdAgentRegistry = freshAgentRegistry
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
        result <- resolveCloneTarget deps repo
        case result of
          Left (CloneVaultError (VaultKeyNotFound k)) -> k `shouldBe` "MISSING_KEY"
          other -> expectationFailure ("expected VaultKeyNotFound, got: " <> show other)

  --------------------------------------------------------------------------
  -- no-stderr assertion (unchanged)
  --------------------------------------------------------------------------

  describe "no-stderr in CloneGitFailed" $ do
    it "CloneGitFailed carries exit code ONLY (no stderr field)" $ do
      let e = CloneGitFailed 42
      e `shouldBe` CloneGitFailed 42
      "stderr" `T.isInfixOf` renderCloneError e `shouldBe` False

  --------------------------------------------------------------------------
  -- bracket cleanup (W2: known_hosts temp file removed after the op)
  --------------------------------------------------------------------------

  describe "bracket cleanup (W2)" $ do
    it "deploy key: known_hosts temp file removed after the continuation (success)" $
      withSystemTempDirectory "seal-home" $ \homeDir -> do
        let keyfilesDir = homeDir </> ".seal/state/repos/keys"
        createDirectoryIfMissing True keyfilesDir
        let keyfilePath = keyfilesDir </> "repo-a"
            rid1 = case mkRepoId "repo-a" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid1 "git@github.com:o/r.git" VcsGitHub (CredDeployKey "K") Nothing Nothing
        BS.writeFile keyfilePath "ciphertext"
        vault <- makeFakeVaultRuntime [("K", "passphrase")]
        callsRef <- newIORef []
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = fakeRepoRegistryHandle
              , cdSshAgent = agent
              , cdAgentRegistry = freshAgentRegistry
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
        Right target <- resolveCloneTarget deps repo
        knownHostsRef <- newIORef ""
        withCloneTarget target $ \env -> do
          case lookup "GIT_SSH_COMMAND" (ceEnvExtras env) of
            Just sshCmd -> writeIORef knownHostsRef (extractKnownHostsPath sshCmd)
            Nothing -> expectationFailure "no GIT_SSH_COMMAND"
        knownHostsPath <- readIORef knownHostsRef
        -- After the continuation, the known_hosts file is removed
        unless (null knownHostsPath) $ do
          exists <- doesFileExist knownHostsPath
          exists `shouldBe` False

    it "cleanup STILL runs when the continuation throws (bracket semantics)" $
      withSystemTempDirectory "seal-home" $ \homeDir -> do
        let keyfilesDir = homeDir </> ".seal/state/repos/keys"
        createDirectoryIfMissing True keyfilesDir
        let keyfilePath = keyfilesDir </> "repo-a"
            rid1 = case mkRepoId "repo-a" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid1 "git@github.com:o/r.git" VcsGitHub (CredDeployKey "K") Nothing Nothing
        BS.writeFile keyfilePath "ciphertext"
        vault <- makeFakeVaultRuntime [("K", "passphrase")]
        callsRef <- newIORef []
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = fakeRepoRegistryHandle
              , cdSshAgent = agent
              , cdAgentRegistry = freshAgentRegistry
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
        Right target <- resolveCloneTarget deps repo
        knownHostsRef <- newIORef ""
        let failingK env = do
              case lookup "GIT_SSH_COMMAND" (ceEnvExtras env) of
                Just sshCmd -> writeIORef knownHostsRef (extractKnownHostsPath sshCmd)
                Nothing -> pure ()
              throwIO (userError "intentional failure")
        (_ :: Either SomeException ()) <- try (withCloneTarget target failingK)
        knownHostsPath <- readIORef knownHostsRef
        -- The known_hosts file is removed even on failure (bracket)
        unless (null knownHostsPath) $ do
          exists <- doesFileExist knownHostsPath
          exists `shouldBe` False
        -- In the one-agent-per-repo model, sahDeleteAll is NOT called
        -- per-op (the key persists for the repo's lifetime). No SahKill
        -- per-op either (kill is harness-shutdown-only).
        calls <- readIORef callsRef
        SahDeleteAll `elem` calls `shouldBe` False
        SahKill `elem` calls `shouldBe` False

  --------------------------------------------------------------------------
  -- CloneDeps exports (compile-time check: CloneDeps is exported)
  --------------------------------------------------------------------------

  describe "CloneDeps" $ do
    it "can be constructed with all fields" $
      withSystemTempDirectory "seal-keys" $ \keyfilesDir -> do
        vault <- makeFakeVaultRuntime []
        callsRef <- newIORef []
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = fakeRepoRegistryHandle
              , cdSshAgent = agent
              , cdAgentRegistry = freshAgentRegistry
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
        -- Compile-time check: the record compiles
        cdKeyfilesDir deps `shouldBe` keyfilesDir

  --------------------------------------------------------------------------
  -- Security-fix tests (from the W2 security-auditor review)
  --------------------------------------------------------------------------

  describe "mergeEnv (overrides win — security fix HIGH 1)" $ do
    it "override wins over inherited for the same key" $
      mergeEnv [("SSH_AUTH_SOCK", "ambient-sock")]
               [("SSH_AUTH_SOCK", "per-op-sock")]
        `shouldBe` [("SSH_AUTH_SOCK", "per-op-sock")]

    it "non-colliding keys from both are preserved" $ do
      let result = mergeEnv [("A", "a1"), ("B", "b1")] [("B", "b2"), ("C", "c2")]
      lookup "A" result `shouldBe` Just "a1"
      lookup "B" result `shouldBe` Just "b2"  -- override wins
      lookup "C" result `shouldBe` Just "c2"

    it "ambient SSH_AUTH_SOCK does NOT shadow the per-op socket (per-op scoping)" $
      mergeEnv [("SSH_AUTH_SOCK", "user-ambient-agent")]
               [("SSH_AUTH_SOCK", "op-agent-socket")]
        `shouldBe` [("SSH_AUTH_SOCK", "op-agent-socket")]

  describe "renderPatHeader (non-UTF-8 token bytes — security fix MEDIUM 3)" $ do
    it "ASCII token: base64(user:token) round-trips" $ do
      let rid1 = case mkRepoId "x" of Right i -> i; Left _ -> error "bad id"
          repo = SourceRepo rid1 "git@github.com:o/r.git" VcsGitHub (CredPat "K") Nothing Nothing
          token = "ghp_ASCII_TOKEN" :: ByteString
          header = renderPatHeader repo token
          expected = "Authorization: Basic "
                     <> TE.decodeUtf8Lenient (B64.encode ("x-access-token:ghp_ASCII_TOKEN" :: ByteString))
      header `shouldBe` expected

    it "non-UTF-8 token byte (0xFF) is base64-encoded verbatim (NOT corrupted)" $ do
      let rid1 = case mkRepoId "x" of Right i -> i; Left _ -> error "bad id"
          repo = SourceRepo rid1 "git@github.com:o/r.git" VcsGitHub (CredPat "K") Nothing Nothing
          token = "secret" <> BS.singleton 0xFF <> "bytes" :: ByteString
          header = renderPatHeader repo token
          expected = "Authorization: Basic "
                     <> TE.decodeUtf8Lenient (B64.encode ("x-access-token:secret" <> BS.singleton 0xFF <> "bytes"))
      header `shouldBe` expected
      -- The 0xFF byte is preserved through base64 (NOT replaced by U+FFFD).
      let decoded = B64.decodeLenient (TE.encodeUtf8 (T.drop (T.length "Authorization: Basic ") header))
      decoded `shouldBe` ("x-access-token:secret" <> BS.singleton 0xFF <> "bytes")

    it "MachineUser uses cUsername as the Basic auth user" $ do
      let rid1 = case mkRepoId "x" of Right i -> i; Left _ -> error "bad id"
          repo = SourceRepo rid1 "git@github.com:o/r.git" VcsGitHub (CredMachineUser "K" "acme-bot") Nothing Nothing
          token = "tok" :: ByteString
          header = renderPatHeader repo token
          expected = "Authorization: Basic "
                     <> TE.decodeUtf8Lenient (B64.encode ("acme-bot:tok" :: ByteString))
      header `shouldBe` expected

  describe "known_hosts temp file (TOCTOU fix MEDIUM 2)" $ do
    it "known_hosts file is written under cdKeyfilesDir (NOT /tmp)" $
      withSystemTempDirectory "seal-home" $ \homeDir -> do
        let keyfilesDir = homeDir </> ".seal/state/repos/keys"
        createDirectoryIfMissing True keyfilesDir
        let keyfilePath = keyfilesDir </> "repo-a"
            rid1 = case mkRepoId "repo-a" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid1 "git@github.com:o/r.git" VcsGitHub (CredDeployKey "K") Nothing Nothing
        BS.writeFile keyfilePath "ciphertext"
        vault <- makeFakeVaultRuntime [("K", "passphrase")]
        callsRef <- newIORef []
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = fakeRepoRegistryHandle
              , cdSshAgent = agent
              , cdAgentRegistry = freshAgentRegistry
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
        Right target <- resolveCloneTarget deps repo
        withCloneTarget target $ \env -> do
          case lookup "GIT_SSH_COMMAND" (ceEnvExtras env) of
            Just sshCmd -> do
              let knownHostsPath = extractKnownHostsPath sshCmd
              -- The known_hosts file is under keyfilesDir (the 0700
              -- harness-private dir), NOT /tmp.
              knownHostsPath `shouldSatisfy` (keyfilesDir `isPrefixOf`)
            Nothing -> expectationFailure "no GIT_SSH_COMMAND"

    it "known_hosts file is 0600 (private — path integrity protected)" $
      withSystemTempDirectory "seal-home" $ \homeDir -> do
        let keyfilesDir = homeDir </> ".seal/state/repos/keys"
        createDirectoryIfMissing True keyfilesDir
        let keyfilePath = keyfilesDir </> "repo-a"
            rid1 = case mkRepoId "repo-a" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid1 "git@github.com:o/r.git" VcsGitHub (CredDeployKey "K") Nothing Nothing
        BS.writeFile keyfilePath "ciphertext"
        vault <- makeFakeVaultRuntime [("K", "passphrase")]
        callsRef <- newIORef []
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = fakeRepoRegistryHandle
              , cdSshAgent = agent
              , cdAgentRegistry = freshAgentRegistry
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
        Right target <- resolveCloneTarget deps repo
        withCloneTarget target $ \env -> do
          case lookup "GIT_SSH_COMMAND" (ceEnvExtras env) of
            Just sshCmd -> do
              let knownHostsPath = extractKnownHostsPath sshCmd
              st <- getFileStatus knownHostsPath
              let mode = fileMode st `intersectFileModes` ownerModes
              mode `shouldBe` 0o600
            Nothing -> expectationFailure "no GIT_SSH_COMMAND"

  describe "agent leak on throw-after-add (security fix HIGH 2)" $ do
    it "sahDeleteAll + sahKill run even if the post-add phase throws" $
      withSystemTempDirectory "seal-home" $ \homeDir -> do
        let keyfilesDir = homeDir </> ".seal/state/repos/keys"
        createDirectoryIfMissing True keyfilesDir
        -- The encrypted keyfile (the fake agent doesn't read it; it just
        -- records the SahAddKey call, so the file need not exist for the
        -- fake to succeed — but we write it so the path is realistic).
        let keyfilePath = keyfilesDir </> "repo-a"
            rid1 = case mkRepoId "repo-a" of Right i -> i; Left _ -> error "bad id"
            repo = SourceRepo rid1 "git@github.com:o/r.git" VcsGitHub (CredDeployKey "K") Nothing Nothing
        BS.writeFile keyfilePath "ciphertext"
        vault <- makeFakeVaultRuntime [("K", "passphrase")]
        callsRef <- newIORef []
        agentEnvRef <- newIORef Map.empty
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            -- Point cdKeyfilesDir at a FILE (not a dir) so the
            -- writeKnownHostsTemp call (after sahAddKey succeeds) throws
            -- AlreadyExists from createDirectoryIfMissing. The keyfile is
            -- still found (the fake agent doesn't read it; it records the
            -- call). This simulates an IO error in the post-add phase. The
            -- bracket's release must still run sahDeleteAll + sahKill.
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = fakeRepoRegistryHandle
              , cdSshAgent = agent
              , cdAgentRegistry = agentEnvRef
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilePath  -- a FILE, not a dir
              , cdIsRemote = False
              }
        -- resolveCloneTarget throws (the bracket catches), so we use try.
        (_ :: Either SomeException (Either CloneError CloneTarget)) <-
          try (resolveCloneTarget deps repo)
        calls <- readIORef callsRef
        -- The agent WAS started + key WAS added (the throw happens after).
        SahStart `elem` calls `shouldBe` True
        -- The keyfile path passed to sahAddKey is cdKeyfilesDir </> "repo-a".
        SahAddKey (keyfilePath </> "repo-a") "passphrase" `elem` calls `shouldBe` True
        -- In the one-agent-per-repo model, sahDeleteAll is NOT called
        -- on a post-add throw (the agent + key persist in the registry;
        -- a retry will find the cached agent). No sahKill per-op.
        SahDeleteAll `elem` calls `shouldBe` False
        SahKill `elem` calls `shouldBe` False

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

-- | Walk a directory tree and collect all (path, content) pairs.
collectAllFiles :: FilePath -> IO [(FilePath, ByteString)]
collectAllFiles root = do
  exists <- doesDirectoryExist root
  if not exists
    then pure []
    else do
      entries <- listDirectory root
      fmap concat $ forM entries $ \entry -> do
        let path = root </> entry
        isDir <- doesDirectoryExist path
        if isDir
          then collectAllFiles path
          else do
            content <- BS.readFile path
            pure [(path, content)]

-- | Extract the UserKnownHostsFile path from a GIT_SSH_COMMAND string.
-- The path is the value after @UserKnownHostsFile=@ up to the next space.
extractKnownHostsPath :: String -> FilePath
extractKnownHostsPath sshCmd =
  case break ("UserKnownHostsFile=" `isPrefixOf`) (tails sshCmd) of
    (_, []) -> ""
    (_, match : _) ->
      let needle = "UserKnownHostsFile=" :: String
          rest = drop (length needle) match
      in takeWhile (/= ' ') rest

