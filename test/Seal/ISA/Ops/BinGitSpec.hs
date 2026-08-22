{-# LANGUAGE OverloadedStrings #-}
-- | BIN_EXEC git credential injection tests — verifies that when the
-- binary is @git@ and the cwd is inside a registered repo, the opcode
-- resolves the repo's credential via the clone seam and injects the
-- appropriate auth env (@SSH_AUTH_SOCK@ + @GIT_SSH_COMMAND@ for deploy
-- keys, @GIT_TERMINAL_PROMPT=0@ for PATs). Tests run in BOTH local and
-- remote modes, asserting identical behavior (the local/remote parity
-- invariant — both arms use the same credential-resolution path via
-- 'UIOGit', differing only in the executor seam).
module Seal.ISA.Ops.BinGitSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.IORef
import Data.Text (Text)
import System.IO.Temp (withSystemTempDirectory)
import System.FilePath ((</>))
import System.Directory (createDirectoryIfMissing)
import Data.ByteString qualified as BS
import Test.Hspec

import Seal.Core.AllowList (AllowList (..))
import Seal.ISA.Opcode (OpResult (..), Opcode, uoRun)
import Seal.ISA.Ops.Bin
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.SourceControl.Clone (CloneDeps (..))
import Seal.SourceControl.GithubKeys (pinnedGithubKnownHosts)
import Seal.SourceControl.Repo
  ( RepoCredential (..), SourceRepo (..), VcsKind (..), mkRepoId )
import Seal.SourceControl.Registry (RepoRegistryHandle (..))
import Seal.SourceControl.AgentRegistry (mkAgentRegistryHandle)
import Seal.TestHelpers.FakeVault (makeFakeVaultRuntime)
import Seal.Tools.Args (textBinArg, textBinName)
import Seal.Tools.Exec.Types (getRemotePath)
import Seal.Tools.Exec.UIO (runUIOWithEnv)
import Seal.Tools.Exec.UIO.Internal (mkTestUIOEnv)
import Seal.Tools.Exec.UntrustedIO (UntrustedIO (..), mkRemoteUntrustedIOStub)
import Seal.Tools.Ssh.Agent
  ( SshAgentEnv (..), mkFakeSshAgentHandle )

-- | Run the BIN_EXEC opcode's uoRun with the given UntrustedIO + CloneDeps.
runOp :: UntrustedIO -> CloneDeps -> Opcode -> Value -> IO OpResult
runOp uio deps op input =
  runUIOWithEnv (mkTestUIOEnv uio deps) (uoRun op input)

-- | A recorded exec call — captures which UntrustedIO method was used and
-- the env extras passed.
data RecordedExec = RecordedExec
  { reBinary     :: Text
  , reArgs       :: [Text]
  , reCwd        :: Maybe Text
  , reEnvExtras  :: [(String, String)]
  , reUsedGitEnv :: Bool
  , reUsedEnv    :: Bool
  , reUsedPlain  :: Bool
  } deriving stock (Eq, Show)

-- | Build a fake 'UntrustedIO' that records exec calls. Works for both
-- local and remote modes (the recording logic is identical — the opcode
-- only sees the 'UntrustedIO' interface).
--
-- The @remoteUrl@ is the canned output for the pre-flight @git config
-- --get remote.origin.url@. The @finalOutput@ is the canned output for
-- the actual git command.
fakeUio :: IORef [RecordedExec] -> Text -> Text -> UntrustedIO
fakeUio seen remoteUrl finalOutput =
  mkRemoteUntrustedIOStub
    { uioBinExec = \bin args mCwd -> do
        let binText = textBinName bin
            argTexts = map textBinArg args
            output = if binText == "git" && "config" `elem` argTexts
                        then remoteUrl
                        else finalOutput
        modifyIORef' seen (++ [RecordedExec binText argTexts (fmap getRemotePath mCwd) [] False False True])
        pure (Right output)
    , uioBinExecEnv = \extras bin args mCwd -> do
        let binText = textBinName bin
            argTexts = map textBinArg args
        modifyIORef' seen (++ [RecordedExec binText argTexts (fmap getRemotePath mCwd) extras False True False])
        pure (Right finalOutput)
    , uioBinExecGitEnv = \extras _mKnownHosts bin args mCwd -> do
        let binText = textBinName bin
            argTexts = map textBinArg args
        modifyIORef' seen (++ [RecordedExec binText argTexts (fmap getRemotePath mCwd) extras True True False])
        pure (Right finalOutput)
    }

-- | Build a fake 'RepoRegistryHandle' that returns the given repos.
fakeRepoReg :: [SourceRepo] -> RepoRegistryHandle
fakeRepoReg repos = RepoRegistryHandle
  { rrhList   = pure (Right repos)
  , rrhMutate = \_ -> pure (Right ())
  }

-- | Build 'CloneDeps' for a deploy-key repo test (local or remote).
mkDeployKeyDeps :: [SourceRepo] -> Bool -> FilePath -> IO CloneDeps
mkDeployKeyDeps repos isRemote keyfilesDir = do
  let encryptedKeyfile = "-----BEGIN OPENSSH PRIVATE KEY-----\nfake-ciphertext\n-----END OPENSSH PRIVATE KEY-----"
      passphrase = "SUPERSECRET-PASSPHRASE"
      keyfilePath = keyfilesDir </> "test-repo"
  createDirectoryIfMissing True keyfilesDir
  BS.writeFile keyfilePath encryptedKeyfile
  vault <- makeFakeVaultRuntime [("K_DEPLOY", passphrase)]
  agentRegH <- mkAgentRegistryHandle keyfilesDir
  agentCallsRef <- newIORef []
  let agent = mkFakeSshAgentHandle agentCallsRef (SshAgentEnv "/tmp/fake-sock" "12345")
  pure CloneDeps
    { cdVault = vault
    , cdRepoReg = fakeRepoReg repos
    , cdSshAgent = agent
    , cdAgentRegistry = agentRegH
    , cdPinnedKnownHosts = pinnedGithubKnownHosts
    , cdKeyfilesDir = keyfilesDir
    , cdIsRemote = isRemote
    }

-- | Build 'CloneDeps' for a PAT repo test (local or remote).
mkPatDeps :: [SourceRepo] -> Bool -> IO CloneDeps
mkPatDeps repos isRemote = do
  vault <- makeFakeVaultRuntime [("K_PAT", "ghp_FAKE_TOKEN_12345")]
  agentRegH <- mkAgentRegistryHandle "/tmp/seal-test-agentreg-pat"
  agentCallsRef <- newIORef []
  pure CloneDeps
    { cdVault = vault
    , cdRepoReg = fakeRepoReg repos
    , cdSshAgent = mkFakeSshAgentHandle agentCallsRef (SshAgentEnv "/tmp/fake" "0")
    , cdAgentRegistry = agentRegH
    , cdPinnedKnownHosts = pinnedGithubKnownHosts
    , cdKeyfilesDir = "/tmp/seal-test-keyfiles-pat"
    , cdIsRemote = isRemote
    }

-- | A test repo with a deploy key credential.
deployKeyRepo :: SourceRepo
deployKeyRepo =
  let rid = case mkRepoId "test-repo" of Right i -> i; Left e -> error (show e)
  in SourceRepo
    { srId = rid
    , srUrl = "git@github.com:owner/test-repo.git"
    , srVcsKind = VcsGitHub
    , srCredential = CredDeployKey "K_DEPLOY"
    , srDeployKeyPublic = Nothing
    , srKeyfilePath = Nothing
    }

-- | A test repo with a PAT credential.
patRepo :: SourceRepo
patRepo =
  let rid = case mkRepoId "test-repo" of Right i -> i; Left e -> error (show e)
  in SourceRepo
    { srId = rid
    , srUrl = "git@github.com:owner/test-repo.git"
    , srVcsKind = VcsGitHub
    , srCredential = CredPat "K_PAT"
    , srDeployKeyPublic = Nothing
    , srKeyfilePath = Nothing
    }

-- | The standard op used in all tests.
testOp :: Opcode
testOp = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing

-- | The standard git fetch input.
gitFetchInput :: Value
gitFetchInput = object
  [ "binary" .= ("git" :: Text)
  , "args" .= (["fetch"] :: [Text])
  ]

-- | Assert the recorded list has exactly @n@ entries, then extract the
-- first and second via pattern matching (no partial functions).
getTwoExecs :: IORef [RecordedExec] -> Int -> IO (RecordedExec, RecordedExec)
getTwoExecs ref expectedLen = do
  recorded <- readIORef ref
  length recorded `shouldBe` expectedLen
  case recorded of
    [e1, e2] -> pure (e1, e2)
    _        -> error "getTwoExecs: expected exactly 2 entries (test invariant violation)"

-- | Assert the recorded list has exactly 1 entry, then extract it.
getOneExec :: IORef [RecordedExec] -> IO RecordedExec
getOneExec ref = do
  recorded <- readIORef ref
  length recorded `shouldBe` 1
  case recorded of
    [e] -> pure e
    _   -> error "getOneExec: expected exactly 1 entry (test invariant violation)"

spec :: Spec
spec = describe "Seal.ISA.Ops.Bin (git credential injection)" $ do

  --------------------------------------------------------------------
  -- Deploy-key repo
  --------------------------------------------------------------------

  describe "deploy-key repo — local mode" $ do
    it "injects SSH_AUTH_SOCK via uioBinExecGitEnv" $
      withSystemTempDirectory "seal-keyfiles" $ \keyfilesDir -> do
        deps <- mkDeployKeyDeps [deployKeyRepo] False keyfilesDir
        seen <- newIORef []
        let uio = fakeUio seen "git@github.com:owner/test-repo.git\n" "done\n"
        result <- runOp uio deps testOp gitFetchInput
        orIsError result `shouldBe` False
        orParts result `shouldBe` [TrpText "done\n"]
        (first, second) <- getTwoExecs seen 2
        reBinary first `shouldBe` "git"
        reArgs first `shouldBe` ["config", "--get", "remote.origin.url"]
        reUsedPlain first `shouldBe` True
        reBinary second `shouldBe` "git"
        reArgs second `shouldBe` ["fetch"]
        reUsedGitEnv second `shouldBe` True
        reEnvExtras second `shouldSatisfy` any (\(k, _) -> k == "SSH_AUTH_SOCK")

  describe "deploy-key repo — remote mode" $ do
    it "injects SSH_AUTH_SOCK via uioBinExecGitEnv (agent forwarding)" $
      withSystemTempDirectory "seal-keyfiles" $ \keyfilesDir -> do
        deps <- mkDeployKeyDeps [deployKeyRepo] True keyfilesDir
        seen <- newIORef []
        let uio = fakeUio seen "git@github.com:owner/test-repo.git\n" "done\n"
        result <- runOp uio deps testOp gitFetchInput
        orIsError result `shouldBe` False
        orParts result `shouldBe` [TrpText "done\n"]
        (first, second) <- getTwoExecs seen 2
        reBinary first `shouldBe` "git"
        reArgs first `shouldBe` ["config", "--get", "remote.origin.url"]
        reUsedPlain first `shouldBe` True
        reBinary second `shouldBe` "git"
        reArgs second `shouldBe` ["fetch"]
        reUsedGitEnv second `shouldBe` True
        reEnvExtras second `shouldSatisfy` any (\(k, _) -> k == "SSH_AUTH_SOCK")

  --------------------------------------------------------------------
  -- PAT repo
  --------------------------------------------------------------------

  describe "PAT repo — local mode" $ do
    it "injects GIT_TERMINAL_PROMPT via uioBinExecEnv" $ do
      deps <- mkPatDeps [patRepo] False
      seen <- newIORef []
      let uio = fakeUio seen "git@github.com:owner/test-repo.git\n" "done\n"
      result <- runOp uio deps testOp gitFetchInput
      orIsError result `shouldBe` False
      orParts result `shouldBe` [TrpText "done\n"]
      (_, second) <- getTwoExecs seen 2
      reBinary second `shouldBe` "git"
      reArgs second `shouldBe` ["fetch"]
      reUsedEnv second `shouldBe` True
      reUsedGitEnv second `shouldBe` False
      reEnvExtras second `shouldSatisfy` any (\(k, _) -> k == "GIT_TERMINAL_PROMPT")

  describe "PAT repo — remote mode" $ do
    it "injects GIT_TERMINAL_PROMPT via uioBinExecEnv" $ do
      deps <- mkPatDeps [patRepo] True
      seen <- newIORef []
      let uio = fakeUio seen "git@github.com:owner/test-repo.git\n" "done\n"
      result <- runOp uio deps testOp gitFetchInput
      orIsError result `shouldBe` False
      orParts result `shouldBe` [TrpText "done\n"]
      (_, second) <- getTwoExecs seen 2
      reBinary second `shouldBe` "git"
      reArgs second `shouldBe` ["fetch"]
      reUsedEnv second `shouldBe` True
      reUsedGitEnv second `shouldBe` False
      reEnvExtras second `shouldSatisfy` any (\(k, _) -> k == "GIT_TERMINAL_PROMPT")

  --------------------------------------------------------------------
  -- Unregistered repo (fall-through)
  --------------------------------------------------------------------

  describe "unregistered repo — local mode" $ do
    it "falls through to plain uioBinExec (no credential)" $ do
      deps <- mkPatDeps [] False
      seen <- newIORef []
      let uio = fakeUio seen "git@github.com:owner/other-repo.git\n" "done\n"
      result <- runOp uio deps testOp gitFetchInput
      orIsError result `shouldBe` False
      orParts result `shouldBe` [TrpText "done\n"]
      (_, second) <- getTwoExecs seen 2
      reUsedPlain second `shouldBe` True
      reEnvExtras second `shouldBe` []

  describe "unregistered repo — remote mode" $ do
    it "falls through to plain uioBinExec (no credential)" $ do
      deps <- mkPatDeps [] True
      seen <- newIORef []
      let uio = fakeUio seen "git@github.com:owner/other-repo.git\n" "done\n"
      result <- runOp uio deps testOp gitFetchInput
      orIsError result `shouldBe` False
      orParts result `shouldBe` [TrpText "done\n"]
      (_, second) <- getTwoExecs seen 2
      reUsedPlain second `shouldBe` True
      reEnvExtras second `shouldBe` []

  --------------------------------------------------------------------
  -- Non-git binary (no credential injection)
  --------------------------------------------------------------------

  describe "non-git binary — local mode" $ do
    it "does not inject credentials (plain uioBinExec)" $ do
      deps <- mkPatDeps [patRepo] False
      seen <- newIORef []
      let uio = fakeUio seen "" "42\n"
          input = object
            [ "binary" .= ("python3" :: Text)
            , "args" .= (["-c", "print(42)"] :: [Text])
            ]
      result <- runOp uio deps testOp input
      orIsError result `shouldBe` False
      orParts result `shouldBe` [TrpText "42\n"]
      only <- getOneExec seen
      reBinary only `shouldBe` "python3"
      reUsedPlain only `shouldBe` True

  describe "non-git binary — remote mode" $ do
    it "does not inject credentials (plain uioBinExec)" $ do
      deps <- mkPatDeps [patRepo] True
      seen <- newIORef []
      let uio = fakeUio seen "" "42\n"
          input = object
            [ "binary" .= ("python3" :: Text)
            , "args" .= (["-c", "print(42)"] :: [Text])
            ]
      result <- runOp uio deps testOp input
      orIsError result `shouldBe` False
      orParts result `shouldBe` [TrpText "42\n"]
      only <- getOneExec seen
      reBinary only `shouldBe` "python3"
      reUsedPlain only `shouldBe` True

  --------------------------------------------------------------------
  -- Not a git repo (no remote.origin.url)
  --------------------------------------------------------------------

  describe "no remote.origin.url — local mode" $ do
    it "falls through to plain uioBinExec" $ do
      deps <- mkPatDeps [patRepo] False
      seen <- newIORef []
      let uio = fakeUio seen "" "done\n"
          input = object
            [ "binary" .= ("git" :: Text)
            , "args" .= (["status"] :: [Text])
            ]
      result <- runOp uio deps testOp input
      orIsError result `shouldBe` False
      orParts result `shouldBe` [TrpText "done\n"]
      (_, second) <- getTwoExecs seen 2
      reUsedPlain second `shouldBe` True
      reEnvExtras second `shouldBe` []

  describe "no remote.origin.url — remote mode" $ do
    it "falls through to plain uioBinExec" $ do
      deps <- mkPatDeps [patRepo] True
      seen <- newIORef []
      let uio = fakeUio seen "" "done\n"
          input = object
            [ "binary" .= ("git" :: Text)
            , "args" .= (["status"] :: [Text])
            ]
      result <- runOp uio deps testOp input
      orIsError result `shouldBe` False
      orParts result `shouldBe` [TrpText "done\n"]
      (_, second) <- getTwoExecs seen 2
      reUsedPlain second `shouldBe` True
      reEnvExtras second `shouldBe` []

  --------------------------------------------------------------------
  -- Local/remote parity
  --------------------------------------------------------------------

  describe "local/remote parity" $ do
    it "deploy-key: both modes inject SSH_AUTH_SOCK via uioBinExecGitEnv" $
      withSystemTempDirectory "seal-keyfiles-parity" $ \keyfilesDir -> do
        -- Local
        depsL <- mkDeployKeyDeps [deployKeyRepo] False keyfilesDir
        seenL <- newIORef []
        let uioL = fakeUio seenL "git@github.com:owner/test-repo.git\n" "done\n"
        resultL <- runOp uioL depsL testOp gitFetchInput
        -- Remote
        depsR <- mkDeployKeyDeps [deployKeyRepo] True keyfilesDir
        seenR <- newIORef []
        let uioR = fakeUio seenR "git@github.com:owner/test-repo.git\n" "done\n"
        resultR <- runOp uioR depsR testOp gitFetchInput
        -- Assert identical behavior.
        orIsError resultL `shouldBe` orIsError resultR
        orParts resultL `shouldBe` orParts resultR
        (_, secondL) <- getTwoExecs seenL 2
        (_, secondR) <- getTwoExecs seenR 2
        reUsedGitEnv secondL `shouldBe` reUsedGitEnv secondR
        reUsedPlain secondL `shouldBe` reUsedPlain secondR
        reEnvExtras secondL `shouldSatisfy` any (\(k, _) -> k == "SSH_AUTH_SOCK")
        reEnvExtras secondR `shouldSatisfy` any (\(k, _) -> k == "SSH_AUTH_SOCK")

    it "PAT: both modes inject GIT_TERMINAL_PROMPT via uioBinExecEnv" $ do
      depsL <- mkPatDeps [patRepo] False
      seenL <- newIORef []
      let uioL = fakeUio seenL "git@github.com:owner/test-repo.git\n" "done\n"
      resultL <- runOp uioL depsL testOp gitFetchInput
      depsR <- mkPatDeps [patRepo] True
      seenR <- newIORef []
      let uioR = fakeUio seenR "git@github.com:owner/test-repo.git\n" "done\n"
      resultR <- runOp uioR depsR testOp gitFetchInput
      orIsError resultL `shouldBe` orIsError resultR
      orParts resultL `shouldBe` orParts resultR
      (_, secondL) <- getTwoExecs seenL 2
      (_, secondR) <- getTwoExecs seenR 2
      reUsedEnv secondL `shouldBe` reUsedEnv secondR
      reUsedGitEnv secondL `shouldBe` reUsedGitEnv secondR
      reEnvExtras secondL `shouldSatisfy` any (\(k, _) -> k == "GIT_TERMINAL_PROMPT")
      reEnvExtras secondR `shouldSatisfy` any (\(k, _) -> k == "GIT_TERMINAL_PROMPT")

    it "unregistered: both modes fall through to plain uioBinExec" $ do
      depsL <- mkPatDeps [] False
      seenL <- newIORef []
      let uioL = fakeUio seenL "git@github.com:owner/other.git\n" "done\n"
      resultL <- runOp uioL depsL testOp gitFetchInput
      depsR <- mkPatDeps [] True
      seenR <- newIORef []
      let uioR = fakeUio seenR "git@github.com:owner/other.git\n" "done\n"
      resultR <- runOp uioR depsR testOp gitFetchInput
      orIsError resultL `shouldBe` orIsError resultR
      orParts resultL `shouldBe` orParts resultR
      (_, secondL) <- getTwoExecs seenL 2
      (_, secondR) <- getTwoExecs seenR 2
      reUsedPlain secondL `shouldBe` reUsedPlain secondR
      reEnvExtras secondL `shouldBe` reEnvExtras secondR