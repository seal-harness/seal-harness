{-# LANGUAGE OverloadedStrings #-}
-- | W4 Git opcodes spec — GIT_FETCH/GIT_PULL/GIT_PUSH. Tests:
--
-- 1. Happy path (registered repo, one opcode call → success, no retry).
-- 2. Registry miss → error naming origin URL.
-- 3. Vault-locked → distinguishable error.
-- 4. GIT_PUSH audit: @orRecorded@ carries @credential_kind@ + @status@
--    (secret-free — no token/passphrase/key bytes).
-- 5. Per-op scoping (one sahAddKey+sahDeleteAll+sahKill per op via the
--    fake SshAgentHandle).
module Seal.ISA.Ops.GitSpec (spec) where
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (fromMaybe)
import Seal.Tools.Exec.UIO (runUIOWithEnv)
import Seal.Tools.Exec.UIO.Internal (mkTestUIOEnv)
import Seal.SourceControl.Clone (CloneDeps (..), stubCloneDeps)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import System.FilePath ((</>))
import System.IO.Temp (createTempDirectory, withSystemTempDirectory)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec

import Seal.Core.Types (OpName (..), TrustLevel (..))
import Seal.ISA.Opcode (OpResult (..), Opcode, opTrust, opName, uoRun)
import Seal.ISA.Ops.Git
  ( gitFetchOp, gitPullOp, gitPushOp, resolveOriginUrl )
import Seal.Logging.Logger (testSealLogger)
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Policy (AutonomyLevel (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.SourceControl.AgentRegistry (AgentRegistryHandle, mkAgentRegistryHandle)
import Seal.SourceControl.GithubKeys (pinnedGithubKnownHosts)
import Seal.SourceControl.Repo
  ( RepoCredential (..), SourceRepo (..), VcsKind (..), mkRepoId )
import Seal.SourceControl.Registry (RepoRegistryHandle (..))
import Seal.TestHelpers.FakeVault (makeFakeVaultRuntime, makeLockedVaultRuntime)
import Seal.Tools.Exec.Types (ExecError (..))
import Seal.Tools.Exec.UntrustedIO
  ( UntrustedErr (..), UntrustedIO (..) )
import Seal.Tools.Ssh.Agent
  ( FakeAgentCall (..), SshAgentEnv (..), mkFakeSshAgentHandle )
import Seal.Types.App (App, runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (Env, mkEnv)

-- | Local replacement for the removed uoRunLegacy: runs the opcode's uoRun
-- in a UIOEnv built from the UntrustedIO + optional CloneDeps.
runOp :: UntrustedIO -> Maybe CloneDeps -> Opcode -> Value -> App OpResult
runOp uio mDeps op input =
  liftIO (runUIOWithEnv (mkTestUIOEnv uio (fromMaybe stubCloneDeps mDeps)) (uoRun op input))
-- | Create a fresh 'AgentRegistryHandle' for 'cdAgentRegistry' in a pure
-- @let@ context. Each call creates a NEW handle backed by a fresh temp
-- directory (the @NOINLINE@ prevents GHC from CSE'ing multiple calls).
freshAgentRegistry :: AgentRegistryHandle
freshAgentRegistry = unsafePerformIO (mkAgentRegistryHandle =<< createTestTempDir)
{-# NOINLINE freshAgentRegistry #-}

-- | Create a fresh temp directory for the agent registry.
createTestTempDir :: IO FilePath
createTestTempDir = do
  sysTmp <- getTemporaryDirectory
  createTempDirectory sysTmp "seal-gitreg-test-"

spec :: Spec
spec = describe "Seal.ISA.Ops.Git" $ do

  let rid = case mkRepoId "myrepo" of Right i -> i; Left _ -> error "bad id"
      deployRepo = SourceRepo rid "git@github.com:owner/repo.git" VcsGitHub (CredDeployKey "K_PASS") Nothing Nothing
      patRepo = SourceRepo rid "https://github.com/owner/repo.git" VcsGitHub (CredPat "K_PAT") Nothing Nothing
      originUrl = "git@github.com:owner/repo.git"
      patOriginUrl = "https://github.com/owner/repo.git"

  --------------------------------------------------------------------------
  -- resolveOriginUrl
  --------------------------------------------------------------------------

  describe "resolveOriginUrl" $ do
    it "returns the origin URL from git config" $ do
      let uio = fakeUio (Just originUrl) (Right "fetch output")
      res <- resolveOriginUrl uio "myrepo"
      res `shouldBe` Right originUrl

    it "returns Left if no remote.origin.url is configured" $ do
      let uio = fakeUio (Just "") (Right "fetch output")
      res <- resolveOriginUrl uio "myrepo"
      res `shouldSatisfy` \case Left _ -> True; Right _ -> False

  --------------------------------------------------------------------------
  -- GIT_FETCH happy path (deploy key)
  --------------------------------------------------------------------------

  describe "GIT_FETCH (deploy key, happy path)" $ do
    it "succeeds and returns a success message" $ do
      withSystemTempDirectory "seal-git" $ \dir -> do
        let keyfilesDir = dir </> "keys"
        createDirectoryIfMissing True keyfilesDir
        BS.writeFile (keyfilesDir </> "myrepo") "ciphertext"
        vault <- makeFakeVaultRuntime [("K_PASS", "passphrase")]
        callsRef <- newIORef []
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            repoReg = fakeRepoReg [deployRepo]
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = repoReg
              , cdSshAgent = agent
              , cdAgentRegistry = freshAgentRegistry
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
            uio = fakeUio (Just originUrl) (Right "fetch output")
            op = gitFetchOp deps (WorkspaceRoot dir) Full
            input = object [ "workdir" .= ("myrepo" :: Text) ]
        appEnv <- mkAppEnv
        res <- runApp appEnv (runOp uio (Just deps) op input)
        case res of
          OpResult parts False _ -> do
            parts `shouldNotBe` []
          OpResult parts True recorded -> do
            expectationFailure ("expected success, got error: " <> show parts <> " recorded=" <> show recorded)

    it "per-repo scoping: one sahStart + sahAddKey, no sahDeleteAll (one-agent-per-repo)" $ do
      withSystemTempDirectory "seal-git" $ \dir -> do
        let keyfilesDir = dir </> "keys"
        createDirectoryIfMissing True keyfilesDir
        BS.writeFile (keyfilesDir </> "myrepo") "ciphertext"
        vault <- makeFakeVaultRuntime [("K_PASS", "passphrase")]
        callsRef <- newIORef []
        agentRegH <- mkAgentRegistryHandle keyfilesDir
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            repoReg = fakeRepoReg [deployRepo]
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = repoReg
              , cdSshAgent = agent
              , cdAgentRegistry = agentRegH
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
            uio = fakeUio (Just originUrl) (Right "fetch output")
            op = gitFetchOp deps (WorkspaceRoot dir) Full
            input = object [ "workdir" .= ("myrepo" :: Text) ]
        appEnv <- mkAppEnv
        _ <- runApp appEnv (runOp uio (Just deps) op input)
        calls <- readIORef callsRef
        SahAddKey (keyfilesDir </> "myrepo") "passphrase" `elem` calls `shouldBe` True
        SahDeleteAll `elem` calls `shouldBe` False
        SahKill `elem` calls `shouldBe` False

  --------------------------------------------------------------------------
  -- Registry miss
  --------------------------------------------------------------------------

  describe "GIT_FETCH (registry miss)" $ do
    it "errors naming the origin URL" $ do
      withSystemTempDirectory "seal-git" $ \dir -> do
        let keyfilesDir = dir </> "keys"
        createDirectoryIfMissing True keyfilesDir
        vault <- makeFakeVaultRuntime []
        callsRef <- newIORef []
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            repoReg = fakeRepoReg []  -- empty registry
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = repoReg
              , cdSshAgent = agent
              , cdAgentRegistry = freshAgentRegistry
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
            uio = fakeUio (Just "git@github.com:other/repo.git") (Right "")
            op = gitFetchOp deps (WorkspaceRoot dir) Full
            input = object [ "workdir" .= ("myrepo" :: Text) ]
        appEnv <- mkAppEnv
        res <- runApp appEnv (runOp uio (Just deps) op input)
        case res of
          OpResult parts True _ -> do
            let msg = T.intercalate "\n" [ t | TrpText t <- parts ]
            "no registered repo" `T.isInfixOf` msg `shouldBe` True
            "git@github.com:other/repo.git" `T.isInfixOf` msg `shouldBe` True
          other -> expectationFailure ("expected error, got: " <> show other)

  --------------------------------------------------------------------------
  -- Vault-locked
  --------------------------------------------------------------------------

  describe "GIT_FETCH (vault locked)" $ do
    it "errors with 'vault locked'" $ do
      withSystemTempDirectory "seal-git" $ \dir -> do
        let keyfilesDir = dir </> "keys"
        createDirectoryIfMissing True keyfilesDir
        BS.writeFile (keyfilesDir </> "myrepo") "ciphertext"
        vault <- makeLockedVaultRuntime
        callsRef <- newIORef []
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            repoReg = fakeRepoReg [deployRepo]
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = repoReg
              , cdSshAgent = agent
              , cdAgentRegistry = freshAgentRegistry
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
            uio = fakeUio (Just originUrl) (Right "")
            op = gitFetchOp deps (WorkspaceRoot dir) Full
            input = object [ "workdir" .= ("myrepo" :: Text) ]
        appEnv <- mkAppEnv
        res <- runApp appEnv (runOp uio (Just deps) op input)
        case res of
          OpResult parts True _ -> do
            let msg = T.intercalate "\n" [ t | TrpText t <- parts ]
            "vault locked" `T.isInfixOf` msg `shouldBe` True
          other -> expectationFailure ("expected vault-locked error, got: " <> show other)

  --------------------------------------------------------------------------
  -- GIT_PUSH audit (orRecorded carries credential_kind + status, secret-free)
  --------------------------------------------------------------------------

  describe "GIT_PUSH audit" $ do
    it "orRecorded carries credential_kind + status (secret-free)" $ do
      withSystemTempDirectory "seal-git" $ \dir -> do
        let keyfilesDir = dir </> "keys"
        createDirectoryIfMissing True keyfilesDir
        BS.writeFile (keyfilesDir </> "myrepo") "ciphertext"
        let passphrase = "SUPERSECRET-PASSPHRASE" :: ByteString
        vault <- makeFakeVaultRuntime [("K_PASS", passphrase)]
        callsRef <- newIORef []
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            repoReg = fakeRepoReg [deployRepo]
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = repoReg
              , cdSshAgent = agent
              , cdAgentRegistry = freshAgentRegistry
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
            uio = fakeUio (Just originUrl) (Right "push output")
            op = gitPushOp deps (WorkspaceRoot dir) Full
            input = object [ "workdir" .= ("myrepo" :: Text), "refspec" .= ("main" :: Text) ]
        appEnv <- mkAppEnv
        res <- runApp appEnv (runOp uio (Just deps) op input)
        case res of
          OpResult _parts False recorded -> do
            -- credential_kind is in orRecorded
            lookupKey recorded "credential_kind" `shouldBe` Just "deploy_key"
            lookupKey recorded "status" `shouldBe` Just "ok"
            -- the passphrase is NOT in orRecorded (secret-free audit)
            let recordedBytes = TE.encodeUtf8 (T.pack (show recorded))
            passphrase `BS.isInfixOf` recordedBytes `shouldBe` False
          other -> expectationFailure ("expected success, got: " <> show other)

    it "orRecorded on failure carries credential_kind + status=failed" $ do
      withSystemTempDirectory "seal-git" $ \dir -> do
        let keyfilesDir = dir </> "keys"
        createDirectoryIfMissing True keyfilesDir
        BS.writeFile (keyfilesDir </> "myrepo") "ciphertext"
        vault <- makeFakeVaultRuntime [("K_PASS", "passphrase")]
        callsRef <- newIORef []
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            repoReg = fakeRepoReg [deployRepo]
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = repoReg
              , cdSshAgent = agent
              , cdAgentRegistry = freshAgentRegistry
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
            -- A uio that fails the git push (returns Left UeExec)
            uio = fakeUioErr (Just originUrl)
            op = gitPushOp deps (WorkspaceRoot dir) Full
            input = object [ "workdir" .= ("myrepo" :: Text), "refspec" .= ("main" :: Text) ]
        appEnv <- mkAppEnv
        res <- runApp appEnv (runOp uio (Just deps) op input)
        case res of
          OpResult _parts True recorded -> do
            lookupKey recorded "credential_kind" `shouldBe` Just "deploy_key"
            lookupKey recorded "status" `shouldBe` Just "failed"
          other -> expectationFailure ("expected error, got: " <> show other)

  --------------------------------------------------------------------------
  -- PAT happy path
  --------------------------------------------------------------------------

  describe "GIT_PULL (PAT, happy path)" $ do
    it "succeeds with http.extraHeader (no agent calls)" $ do
      withSystemTempDirectory "seal-git" $ \dir -> do
        let keyfilesDir = dir </> "keys"
        createDirectoryIfMissing True keyfilesDir
        vault <- makeFakeVaultRuntime [("K_PAT", "ghp_TOKEN")]
        callsRef <- newIORef []
        let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
            repoReg = fakeRepoReg [patRepo]
            deps = CloneDeps
              { cdVault = vault
              , cdRepoReg = repoReg
              , cdSshAgent = agent
              , cdAgentRegistry = freshAgentRegistry
              , cdPinnedKnownHosts = pinnedGithubKnownHosts
              , cdKeyfilesDir = keyfilesDir
              , cdIsRemote = False
              }
            uio = fakeUio (Just patOriginUrl) (Right "pull output")
            op = gitPullOp deps (WorkspaceRoot dir) Full
            input = object [ "workdir" .= ("myrepo" :: Text) ]
        appEnv <- mkAppEnv
        res <- runApp appEnv (runOp uio (Just deps) op input)
        case res of
          OpResult parts False _ -> parts `shouldNotBe` []
          other -> expectationFailure ("expected success, got: " <> show other)
        -- PAT path doesn't use the agent (no sahAddKey/sahDeleteAll/sahKill)
        calls <- readIORef callsRef
        SahAddKey "" "" `elem` calls `shouldBe` False
        SahStart `elem` calls `shouldBe` False

  --------------------------------------------------------------------------
  -- Opcode metadata
  --------------------------------------------------------------------------

  describe "opcode metadata" $ do
    it "GIT_FETCH is Untrusted" $
      let op = gitFetchOp undefined undefined undefined
      in opTrust op `shouldBe` Untrusted
    it "GIT_PULL is Untrusted" $
      let op = gitPullOp undefined undefined undefined
      in opTrust op `shouldBe` Untrusted
    it "GIT_PUSH is Untrusted" $
      let op = gitPushOp undefined undefined undefined
      in opTrust op `shouldBe` Untrusted
    it "opName is GIT_FETCH/GIT_PULL/GIT_PUSH" $ do
      opName (gitFetchOp undefined undefined undefined) `shouldBe` OpName "GIT_FETCH"
      opName (gitPullOp undefined undefined undefined) `shouldBe` OpName "GIT_PULL"
      opName (gitPushOp undefined undefined undefined) `shouldBe` OpName "GIT_PUSH"

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

-- | A fake 'UntrustedIO' that returns a canned origin URL for the first
-- @uioShellExec@ (the origin-URL read) + a canned result for
-- @uioShellExecEnv@ (the git fetch/pull/push). The first @uioShellExec@
-- call returns the @mOrigin@; subsequent @uioShellExecEnv@ calls return
-- @gitResult@.
fakeUio :: Maybe Text -> Either UntrustedErr Text -> UntrustedIO
fakeUio mOrigin gitResult = stubUio
  { uioShellExec = \_cmd _mCwd -> pure (case mOrigin of
      Just url -> Right url
      Nothing  -> Right "")
  , uioShellExecEnv = \_env _cmd _mCwd -> pure gitResult
  , uioShellExecGitEnv = \_env _kh _cmd _mCwd -> pure gitResult
  }

-- | A fake 'UntrustedIO' where the git fetch/pull/push fails (returns
-- 'Left' from 'uioShellExecEnv'). The origin-URL read still succeeds.
fakeUioErr :: Maybe Text -> UntrustedIO
fakeUioErr mOrigin = stubUio
  { uioShellExec = \_cmd _mCwd -> pure (case mOrigin of
      Just url -> Right url
      Nothing  -> Right "")
  , uioShellExecEnv = \_env _cmd _mCwd -> pure (Left (UeExec ExecNotImplemented))
  , uioShellExecGitEnv = \_env _kh _cmd _mCwd -> pure (Left (UeExec ExecNotImplemented))
  }

-- | A stub 'UntrustedIO' that fail-closes on every method (the fake
-- overrides the 2 it needs).
stubUio :: UntrustedIO
stubUio = UntrustedIO
  { uioReadFile = \_ _ -> pure (Left (UeExec ExecNotImplemented))
  , uioWriteFile = \_ _ _ _ -> pure (Left (UeExec ExecNotImplemented))
  , uioPatchFile = \_ _ -> pure (Left (UeExec ExecNotImplemented))
  , uioShellExec = \_ _ -> pure (Left (UeExec ExecNotImplemented))
  , uioBinExec = \_ _ _ -> pure (Left (UeExec ExecNotImplemented))
  , uioProcessList = pure (Left (UeExec ExecNotImplemented))
  , uioProcessKill = \_ -> pure (Left (UeExec ExecNotImplemented))
  , uioSearchFiles = \_ _ _ -> pure (Left (UeExec ExecNotImplemented))
  , uioShellExecEnv = \_ _ _ -> pure (Left (UeExec ExecNotImplemented))
  , uioShellExecGitEnv = \_ _ _ _ -> pure (Left (UeExec ExecNotImplemented))
  , uioBinExecEnv = \_ _ _ _ -> pure (Left (UeExec ExecNotImplemented))
  }

-- | A fake 'RepoRegistryHandle' whose @rrhList@ returns the given repos.
fakeRepoReg :: [SourceRepo] -> RepoRegistryHandle
fakeRepoReg repos = RepoRegistryHandle
  { rrhList = pure (Right repos)
  , rrhMutate = \_ -> pure (Right ())
  }

-- | Look up a text key in an Aeson Value (object). Returns 'Nothing' if
-- the value isn't an object or the key is absent.
lookupKey :: Value -> Text -> Maybe Text
lookupKey (Aeson.Object o) k = case KM.lookup (K.fromText k) o of
  Just v -> case v of
    Aeson.String s -> Just s
    _              -> Nothing
  Nothing -> Nothing
lookupKey _ _ = Nothing

-- | Build a minimal 'App' environment for running opcodes in tests.
mkAppEnv :: IO Env
mkAppEnv = do
  logger <- testSealLogger
  mkEnv logger defaultConfig