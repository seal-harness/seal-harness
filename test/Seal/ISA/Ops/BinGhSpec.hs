{-# LANGUAGE OverloadedStrings #-}
-- | BIN_EXEC gh credential injection integration spec — the WU-C
-- integration spec that exercises the @gh@ branch end-to-end through
-- the opcode. Mirrors 'BinGitSpec' in harness shape (a recording
-- 'UntrustedIO' fake + canned @remoteUrl@ / @finalOutput@) and covers
-- design §5.1 tests 1–14:
--
--   1.  PAT repo: @gh pr create@ injects @GH_TOKEN@ via 'uioBinExecEnv'.
--   2.  MachineUser repo: @gh pr merge@ injects @GH_TOKEN@ (raw token,
--       not the base64 header).
--   3.  Deploy-key repo: @gh pr create@ falls through to plain
--       'uioBinExec' (gh can't use SSH).
--   4.  Unregistered repo: @gh pr create@ falls through to plain exec.
--   5.  Not a git repo (no @origin@): @gh auth status@ falls through.
--   6.  @gh -R owner\/repo@ (space short) skips injection + NOTE.
--   7.  @--repo=owner\/repo@ (joined long) skips + NOTE.
--   8.  @-Rowner\/repo@ (joined short) skips + NOTE.
--   9.  @--repo owner\/repo@ (space long) skips + NOTE.
--   10. Locked vault → @credential resolution failed: vault locked@.
--   11. Missing vault key → @vault key <name> not found@.
--   12. Pre-flight @git config@ failure → surfacable error.
--   13. Transcript record is secret-free.
--   14. Local/remote parity (cases 1–9 in both modes).
--
-- Plus the cross-WU log-redaction integration assertion: a PAT-injection
-- @gh@ call's captured debug-log output contains @GH_TOKEN=<redacted>@
-- and NOT the raw token (ties WU-A log redaction to the WU-B gh branch).
module Seal.ISA.Ops.BinGhSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.ByteString qualified as BS
import Data.IORef
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath ((</>))
import System.Directory (createDirectoryIfMissing)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Core.AllowList (AllowList (..))
import Seal.ISA.Opcode (OpResult (..), Opcode, uoRun)
import Seal.ISA.Ops.Bin
import Seal.Logging.Global (setGlobalLogger, unsetGlobalLogger)
import Seal.Logging.Logger (closeSealLogger, newSealLoggerWithScribe)
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.Security.Vault.Age (VaultError (..))
import Seal.SourceControl.Clone (CloneDeps (..), CloneError (..), renderCloneError)
import Seal.SourceControl.GithubKeys (pinnedGithubKnownHosts)
import Seal.SourceControl.Repo
  ( RepoCredential (..), SourceRepo (..), VcsKind (..), mkRepoId )
import Seal.SourceControl.Registry (RepoRegistryHandle (..))
import Seal.SourceControl.AgentRegistry (mkAgentRegistryHandle)
import Seal.TestHelpers.FakeVault
  ( makeFakeVaultRuntime, makeLockedVaultRuntime )
import Seal.Tools.Args (textBinArg, textBinName)
import Seal.Tools.Exec.Types
  ( ExecError (..), SshConfig (..), getRemotePath, mkRemotePath, mkSshHost
  , mkSshUser )
import Seal.Tools.Exec.UIO (runUIOWithEnv)
import Seal.Tools.Exec.UIO.Internal (mkTestUIOEnv)
import Seal.Tools.Exec.UntrustedIO
  ( UntrustedIO (..), UntrustedErr (..), mkRemoteUntrustedIO
  , mkRemoteUntrustedIOStub )
import Seal.Tools.Exec.Remote (mkFakeRemoteRunner)
import Seal.Tools.Ssh.Agent
  ( SshAgentEnv (..), mkFakeSshAgentHandle )

import Katip (Severity (..), Scribe (..), Verbosity (V2), jsonFormat, permitItem)

----------------------------------------------------------------------
-- Harness (ported from BinGitSpec — self-contained, test-only)
----------------------------------------------------------------------

-- | A recorded exec call — captures which 'UntrustedIO' method was used
-- and the env extras passed. Used to assert the @gh@ path selects the
-- correct exec method ('uioBinExec' vs 'uioBinExecEnv' vs
-- 'uioBinExecGitEnv') and the right env extras.
data GhRecordedExec = GhRecordedExec
  { greBinary     :: Text
  , greArgs       :: [Text]
  , greCwd        :: Maybe Text
  , greEnvExtras  :: [(String, String)]
  , greUsedGitEnv :: Bool
  , greUsedEnv    :: Bool
  , greUsedPlain  :: Bool
  } deriving stock (Eq, Show)

-- | Build a fake 'UntrustedIO' that records exec calls. Works for both
-- local and remote modes (the recording logic is identical — the opcode
-- only sees the 'UntrustedIO' interface). The @remoteUrl@ is the canned
-- output for the pre-flight @git config --get remote.origin.url@; the
-- @finalOutput@ is the canned output for the actual @gh@ command.
ghFakeUio :: IORef [GhRecordedExec] -> Text -> Text -> UntrustedIO
ghFakeUio seen remoteUrl finalOutput =
  mkRemoteUntrustedIOStub
    { uioBinExec = \bin args mCwd -> do
        let binText = textBinName bin
            argTexts = map textBinArg args
            output = if binText == "git" && "config" `elem` argTexts
                       then remoteUrl
                       else finalOutput
        modifyIORef' seen (++ [GhRecordedExec binText argTexts (fmap getRemotePath mCwd) [] False False True])
        pure (Right output)
    , uioBinExecEnv = \extras bin args mCwd -> do
        let binText = textBinName bin
            argTexts = map textBinArg args
        modifyIORef' seen (++ [GhRecordedExec binText argTexts (fmap getRemotePath mCwd) extras False True False])
        pure (Right finalOutput)
    , uioBinExecGitEnv = \extras _mKnownHosts bin args mCwd -> do
        let binText = textBinName bin
            argTexts = map textBinArg args
        modifyIORef' seen (++ [GhRecordedExec binText argTexts (fmap getRemotePath mCwd) extras True True False])
        pure (Right finalOutput)
    }

-- | Build a fake 'UntrustedIO' whose pre-flight @git config@ (plain
-- 'uioBinExec' with @config@ in the args) returns 'Left' — for test 12
-- (pre-flight failure). The actual @gh@ call still returns 'Right'
-- (it should never be reached, but the stub is total).
ghFakeUioPreFlightFail :: IORef [GhRecordedExec] -> Text -> UntrustedIO
ghFakeUioPreFlightFail seen finalOutput =
  mkRemoteUntrustedIOStub
    { uioBinExec = \bin args mCwd -> do
        let binText = textBinName bin
            argTexts = map textBinArg args
        modifyIORef' seen (++ [GhRecordedExec binText argTexts (fmap getRemotePath mCwd) [] False False True])
        -- Pre-flight git config returns Left (a structured exec error).
        if binText == "git" && "config" `elem` argTexts
          then pure (Left (UeExec ExecRemoteUnreachable))
          else pure (Right finalOutput)
    , uioBinExecEnv = \extras bin args mCwd -> do
        let binText = textBinName bin
            argTexts = map textBinArg args
        modifyIORef' seen (++ [GhRecordedExec binText argTexts (fmap getRemotePath mCwd) extras False True False])
        pure (Right finalOutput)
    , uioBinExecGitEnv = \extras _mKnownHosts bin args mCwd -> do
        let binText = textBinName bin
            argTexts = map textBinArg args
        modifyIORef' seen (++ [GhRecordedExec binText argTexts (fmap getRemotePath mCwd) extras True True False])
        pure (Right finalOutput)
    }

-- | Build a fake 'RepoRegistryHandle' that returns the given repos.
ghFakeRepoReg :: [SourceRepo] -> RepoRegistryHandle
ghFakeRepoReg repos = RepoRegistryHandle
  { rrhList   = pure (Right repos)
  , rrhMutate = \_ -> pure (Right ())
  }

-- | Build 'CloneDeps' for a PAT repo test (local or remote).
mkPatDeps :: [SourceRepo] -> Bool -> IO CloneDeps
mkPatDeps repos isRemote = do
  vault <- makeFakeVaultRuntime [("K_PAT", "ghp_FAKE_TOKEN_12345")]
  agentRegH <- mkAgentRegistryHandle "/tmp/seal-test-agentreg-ghspec-pat"
  agentCallsRef <- newIORef []
  pure CloneDeps
    { cdVault = vault
    , cdRepoReg = ghFakeRepoReg repos
    , cdSshAgent = mkFakeSshAgentHandle agentCallsRef (SshAgentEnv "/tmp/fake" "0")
    , cdAgentRegistry = agentRegH
    , cdPinnedKnownHosts = pinnedGithubKnownHosts
    , cdKeyfilesDir = "/tmp/seal-test-keyfiles-ghspec-pat"
    , cdIsRemote = isRemote
    }

-- | Build 'CloneDeps' for a MachineUser repo test (local or remote).
mkMachineUserDeps :: [SourceRepo] -> Bool -> IO CloneDeps
mkMachineUserDeps repos isRemote = do
  vault <- makeFakeVaultRuntime [("K_MU", "mhp_MACHINEUSER_TOKEN_999")]
  agentRegH <- mkAgentRegistryHandle "/tmp/seal-test-agentreg-ghspec-mu"
  agentCallsRef <- newIORef []
  pure CloneDeps
    { cdVault = vault
    , cdRepoReg = ghFakeRepoReg repos
    , cdSshAgent = mkFakeSshAgentHandle agentCallsRef (SshAgentEnv "/tmp/fake" "0")
    , cdAgentRegistry = agentRegH
    , cdPinnedKnownHosts = pinnedGithubKnownHosts
    , cdKeyfilesDir = "/tmp/seal-test-keyfiles-ghspec-mu"
    , cdIsRemote = isRemote
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
    , cdRepoReg = ghFakeRepoReg repos
    , cdSshAgent = agent
    , cdAgentRegistry = agentRegH
    , cdPinnedKnownHosts = pinnedGithubKnownHosts
    , cdKeyfilesDir = keyfilesDir
    , cdIsRemote = isRemote
    }

-- | Build 'CloneDeps' with a LOCKED vault (the handle is 'Nothing' —
-- 'resolveVaultHandle' fails closed to 'CloneVaultError VaultLocked').
mkLockedVaultDeps :: [SourceRepo] -> Bool -> IO CloneDeps
mkLockedVaultDeps repos isRemote = do
  vault <- makeLockedVaultRuntime
  agentRegH <- mkAgentRegistryHandle "/tmp/seal-test-agentreg-ghspec-locked"
  agentCallsRef <- newIORef []
  pure CloneDeps
    { cdVault = vault
    , cdRepoReg = ghFakeRepoReg repos
    , cdSshAgent = mkFakeSshAgentHandle agentCallsRef (SshAgentEnv "/tmp/fake" "0")
    , cdAgentRegistry = agentRegH
    , cdPinnedKnownHosts = pinnedGithubKnownHosts
    , cdKeyfilesDir = "/tmp/seal-test-keyfiles-ghspec-locked"
    , cdIsRemote = isRemote
    }

-- | Build 'CloneDeps' with an UNLOCKED but EMPTY vault (the key the repo
-- references is absent — 'vhGet' returns 'VaultKeyNotFound').
mkMissingKeyDeps :: [SourceRepo] -> Bool -> IO CloneDeps
mkMissingKeyDeps repos isRemote = do
  vault <- makeFakeVaultRuntime []  -- unlocked, but no keys
  agentRegH <- mkAgentRegistryHandle "/tmp/seal-test-agentreg-ghspec-missing"
  agentCallsRef <- newIORef []
  pure CloneDeps
    { cdVault = vault
    , cdRepoReg = ghFakeRepoReg repos
    , cdSshAgent = mkFakeSshAgentHandle agentCallsRef (SshAgentEnv "/tmp/fake" "0")
    , cdAgentRegistry = agentRegH
    , cdPinnedKnownHosts = pinnedGithubKnownHosts
    , cdKeyfilesDir = "/tmp/seal-test-keyfiles-ghspec-missing"
    , cdIsRemote = isRemote
    }

----------------------------------------------------------------------
-- Test repos
----------------------------------------------------------------------

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

machineUserRepo :: SourceRepo
machineUserRepo =
  let rid = case mkRepoId "test-repo" of Right i -> i; Left e -> error (show e)
  in SourceRepo
    { srId = rid
    , srUrl = "git@github.com:owner/test-repo.git"
    , srVcsKind = VcsGitHub
    , srCredential = CredMachineUser "K_MU" "acme-bot"
    , srDeployKeyPublic = Nothing
    , srKeyfilePath = Nothing
    }

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

----------------------------------------------------------------------
-- Opcode + inputs
----------------------------------------------------------------------

testOp :: Opcode
testOp = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing

ghPrCreateInput :: Value
ghPrCreateInput = object
  [ "binary" .= ("gh" :: Text)
  , "args" .= (["pr", "create", "--title", "x"] :: [Text])
  ]

ghPrMergeInput :: Value
ghPrMergeInput = object
  [ "binary" .= ("gh" :: Text)
  , "args" .= (["pr", "merge", "--merge"] :: [Text])
  ]

ghAuthStatusInput :: Value
ghAuthStatusInput = object
  [ "binary" .= ("gh" :: Text)
  , "args" .= (["auth", "status"] :: [Text])
  ]

ghInputWithArgs :: [Text] -> Value
ghInputWithArgs args = object
  [ "binary" .= ("gh" :: Text)
  , "args" .= args
  ]

----------------------------------------------------------------------
-- Run helpers
----------------------------------------------------------------------

runOp :: UntrustedIO -> CloneDeps -> Opcode -> Value -> IO OpResult
runOp uio deps op input =
  runUIOWithEnv (mkTestUIOEnv uio deps) (uoRun op input)

-- | Assert the recorded list has exactly @n@ entries.
assertCount :: IORef [GhRecordedExec] -> Int -> IO ()
assertCount ref expectedLen = do
  recorded <- readIORef ref
  length recorded `shouldBe` expectedLen

-- | Get the @n@th recorded exec (0-indexed) after asserting there are at
-- least @n+1@ entries.
getExec :: IORef [GhRecordedExec] -> Int -> IO GhRecordedExec
getExec ref idx = do
  recorded <- readIORef ref
  case drop idx recorded of
    (e : _) -> pure e
    _       -> error ("getExec: expected at least " <> show (idx + 1) <> " entries (test invariant violation)")

-- | Extract the 'TrpText' parts from an 'OpResult'.
textParts :: OpResult -> [Text]
textParts r = [t | TrpText t <- orParts r]

-- | The canned remote URL all PAT/MachineUser/deploy-key tests use (the
-- registered repo's SSH URL — matches via 'lookupRepoByUrl').
registeredUrl :: Text
registeredUrl = "git@github.com:owner/test-repo.git\n"

-- | A URL not in the registry (for the unregistered-repo test).
unregisteredUrl :: Text
unregisteredUrl = "git@github.com:owner/other-repo.git\n"

----------------------------------------------------------------------
-- Cross-WU log-redaction helpers
----------------------------------------------------------------------

-- | A test scribe that captures log items into an 'IORef' for assertions.
-- Mirrors 'Seal.Tools.Exec.LogRedactionSpec.mkCaptureScribe'.
mkCaptureScribe :: IO (Scribe, IORef [Text])
mkCaptureScribe = do
  ref <- newIORef []
  let scribe = Scribe
        { liPush = \item -> do
            let rendered = jsonFormat False V2 item
            modifyIORef' ref (T.pack (show rendered) :)
        , scribePermitItem = permitItem DebugS
        , scribeFinalizer = pure ()
        }
  pure (scribe, ref)

-- | Install a capture scribe as the global logger, run an action, then
-- close the logger and return the captured lines. The global logger ref
-- is always restored to the no-op default (Nothing) after, via
-- 'unsetGlobalLogger', so subsequent tests are unaffected. Mirrors
-- 'Seal.Tools.Exec.LogRedactionSpec.withCaptureGlobalLogger'.
withCaptureGlobalLogger :: IO a -> IO (a, [Text])
withCaptureGlobalLogger action = do
  (scribe, ref) <- mkCaptureScribe
  logger <- newSealLoggerWithScribe scribe DebugS
  setGlobalLogger logger
  result <- action
  closeSealLogger logger
  lines_ <- readIORef ref
  unsetGlobalLogger
  pure (result, lines_)

-- | A placeholder 'SshConfig' for the remote-arm log-redaction test (the
-- fake runner ignores the connection details; only the workspace root
-- matters for SafePath confinement). Mirrors
-- 'Seal.Tools.Exec.LogRedactionSpec.sshCfg'.
sshCfg :: SshConfig
sshCfg = SshConfig
  { scHost       = either (error "fixture") id (mkSshHost "exec.internal")
  , scUser       = either (error "fixture") id (mkSshUser "agent")
  , scPort       = 22
  , scIdentity   = Nothing
  , scKnownHosts = "/home/agent/.ssh/known_hosts"
  , scWorkspace  = case mkRemotePath "/srv/agent-workspace" of
      Right rp -> rp
      Left e   -> error ("fixture: bad remote path: " <> T.unpack e)
  }

----------------------------------------------------------------------
-- Spec
----------------------------------------------------------------------

spec :: Spec
spec = describe "Seal.ISA.Ops.Bin (gh credential injection — BinGhSpec)" $ do

  --------------------------------------------------------------------
  -- Test 1: PAT repo — gh pr create injects GH_TOKEN via uioBinExecEnv
  --------------------------------------------------------------------

  describe "PAT repo" $ do
    it "gh pr create injects GH_TOKEN via uioBinExecEnv (pre-flight git config runs first)" $ do
      deps <- mkPatDeps [patRepo] False
      seen <- newIORef []
      let uio = ghFakeUio seen registeredUrl "done\n"
      result <- runOp uio deps testOp ghPrCreateInput
      orIsError result `shouldBe` False
      orParts result `shouldBe` [TrpText "done\n"]
      -- Two exec calls: pre-flight git config, then gh via uioBinExecEnv.
      assertCount seen 2
      preflight <- getExec seen 0
      greBinary preflight `shouldBe` "git"
      greArgs preflight `shouldBe` ["config", "--get", "remote.origin.url"]
      greUsedPlain preflight `shouldBe` True
      ghExec <- getExec seen 1
      greBinary ghExec `shouldBe` "gh"
      greArgs ghExec `shouldBe` ["pr", "create", "--title", "x"]
      greUsedEnv ghExec `shouldBe` True
      greUsedGitEnv ghExec `shouldBe` False
      greUsedPlain ghExec `shouldBe` False
      lookup "GH_TOKEN" (greEnvExtras ghExec) `shouldBe` Just "ghp_FAKE_TOKEN_12345"

  --------------------------------------------------------------------
  -- Test 2: MachineUser repo — gh pr merge injects GH_TOKEN (raw token)
  --------------------------------------------------------------------

  describe "MachineUser repo" $ do
    it "gh pr merge injects GH_TOKEN (raw MachineUser token, not the base64 header)" $ do
      deps <- mkMachineUserDeps [machineUserRepo] False
      seen <- newIORef []
      let uio = ghFakeUio seen registeredUrl "merged\n"
      result <- runOp uio deps testOp ghPrMergeInput
      orIsError result `shouldBe` False
      orParts result `shouldBe` [TrpText "merged\n"]
      assertCount seen 2
      ghExec <- getExec seen 1
      greBinary ghExec `shouldBe` "gh"
      greArgs ghExec `shouldBe` ["pr", "merge", "--merge"]
      greUsedEnv ghExec `shouldBe` True
      -- The token is the RAW MachineUser token bytes (not the base64
      -- http.extraHeader). ceRawToken carries the raw bytes; the gh
      -- path injects them verbatim via BS.unpack.
      lookup "GH_TOKEN" (greEnvExtras ghExec) `shouldBe` Just "mhp_MACHINEUSER_TOKEN_999"
      -- The base64 header (Authorization: Basic ...) is NOT in the env.
      let envVals = map snd (greEnvExtras ghExec)
      any ("Basic " `isInfixOf`) envVals `shouldBe` False

  --------------------------------------------------------------------
  -- Test 3: Deploy-key repo — falls through to plain uioBinExec
  --------------------------------------------------------------------

  describe "deploy-key repo" $ do
    it "gh pr create falls through to plain uioBinExec (gh can't use SSH)" $
      withSystemTempDirectory "seal-ghspec-keyfiles" $ \keyfilesDir -> do
        deps <- mkDeployKeyDeps [deployKeyRepo] False keyfilesDir
        seen <- newIORef []
        let uio = ghFakeUio seen registeredUrl "done\n"
        result <- runOp uio deps testOp ghPrCreateInput
        orIsError result `shouldBe` False
        orParts result `shouldBe` [TrpText "done\n"]
        assertCount seen 2
        ghExec <- getExec seen 1
        greBinary ghExec `shouldBe` "gh"
        greUsedPlain ghExec `shouldBe` True
        greUsedEnv ghExec `shouldBe` False
        greUsedGitEnv ghExec `shouldBe` False
        greEnvExtras ghExec `shouldBe` []
        lookup "GH_TOKEN" (greEnvExtras ghExec) `shouldBe` Nothing

  --------------------------------------------------------------------
  -- Test 4: Unregistered repo — falls through to plain uioBinExec
  --------------------------------------------------------------------

  describe "unregistered repo" $ do
    it "gh pr create falls through to plain uioBinExec (no injection)" $ do
      deps <- mkPatDeps [patRepo] False
      seen <- newIORef []
      let uio = ghFakeUio seen unregisteredUrl "done\n"
      result <- runOp uio deps testOp ghPrCreateInput
      orIsError result `shouldBe` False
      orParts result `shouldBe` [TrpText "done\n"]
      assertCount seen 2
      ghExec <- getExec seen 1
      greUsedPlain ghExec `shouldBe` True
      greEnvExtras ghExec `shouldBe` []
      lookup "GH_TOKEN" (greEnvExtras ghExec) `shouldBe` Nothing

  --------------------------------------------------------------------
  -- Test 5: Not a git repo (no origin) — falls through to plain exec
  --------------------------------------------------------------------

  describe "not a git repo (no origin)" $ do
    it "gh auth status falls through to plain uioBinExec (ambient gh auth)" $ do
      deps <- mkPatDeps [patRepo] False
      seen <- newIORef []
      let uio = ghFakeUio seen "" "done\n"
      result <- runOp uio deps testOp ghAuthStatusInput
      orIsError result `shouldBe` False
      orParts result `shouldBe` [TrpText "done\n"]
      assertCount seen 2
      ghExec <- getExec seen 1
      greUsedPlain ghExec `shouldBe` True
      greEnvExtras ghExec `shouldBe` []
      lookup "GH_TOKEN" (greEnvExtras ghExec) `shouldBe` Nothing

  --------------------------------------------------------------------
  -- Tests 6–9: -R/--repo skip injection + NOTE
  --------------------------------------------------------------------

  describe "-R/--repo flag skips injection" $ do

    it "gh -R owner/other pr create (space short) skips + NOTE" $ do
      deps <- mkPatDeps [patRepo] False
      seen <- newIORef []
      let uio = ghFakeUio seen registeredUrl "done\n"
          input = ghInputWithArgs ["-R", "owner/other", "pr", "create"]
      result <- runOp uio deps testOp input
      orIsError result `shouldBe` False
      let notes = textParts result
      any ("credential injection skipped" `T.isInfixOf`) notes `shouldBe` True
      any ("-R/--repo detected" `T.isInfixOf`) notes `shouldBe` True
      -- Only ONE exec call (no pre-flight — the -R skip happens first).
      assertCount seen 1
      ghExec <- getExec seen 0
      greBinary ghExec `shouldBe` "gh"
      greUsedPlain ghExec `shouldBe` True
      greEnvExtras ghExec `shouldBe` []
      lookup "GH_TOKEN" (greEnvExtras ghExec) `shouldBe` Nothing

    it "gh --repo=owner/other pr create (joined long) skips + NOTE" $ do
      deps <- mkPatDeps [patRepo] False
      seen <- newIORef []
      let uio = ghFakeUio seen registeredUrl "done\n"
          input = ghInputWithArgs ["--repo=owner/other", "pr", "create"]
      result <- runOp uio deps testOp input
      orIsError result `shouldBe` False
      let notes = textParts result
      any ("credential injection skipped" `T.isInfixOf`) notes `shouldBe` True
      any ("-R/--repo detected" `T.isInfixOf`) notes `shouldBe` True
      assertCount seen 1
      ghExec <- getExec seen 0
      greUsedPlain ghExec `shouldBe` True
      lookup "GH_TOKEN" (greEnvExtras ghExec) `shouldBe` Nothing

    it "gh -Rowner/other-repo pr create (joined short) skips + NOTE" $ do
      deps <- mkPatDeps [patRepo] False
      seen <- newIORef []
      let uio = ghFakeUio seen registeredUrl "done\n"
          input = ghInputWithArgs ["-Rowner/other-repo", "pr", "create"]
      result <- runOp uio deps testOp input
      orIsError result `shouldBe` False
      let notes = textParts result
      any ("credential injection skipped" `T.isInfixOf`) notes `shouldBe` True
      any ("-R/--repo detected" `T.isInfixOf`) notes `shouldBe` True
      assertCount seen 1
      ghExec <- getExec seen 0
      greUsedPlain ghExec `shouldBe` True
      lookup "GH_TOKEN" (greEnvExtras ghExec) `shouldBe` Nothing

    it "gh --repo owner/other pr create (space long) skips + NOTE" $ do
      deps <- mkPatDeps [patRepo] False
      seen <- newIORef []
      let uio = ghFakeUio seen registeredUrl "done\n"
          input = ghInputWithArgs ["--repo", "owner/other", "pr", "create"]
      result <- runOp uio deps testOp input
      orIsError result `shouldBe` False
      let notes = textParts result
      any ("credential injection skipped" `T.isInfixOf`) notes `shouldBe` True
      any ("-R/--repo detected" `T.isInfixOf`) notes `shouldBe` True
      assertCount seen 1
      ghExec <- getExec seen 0
      greUsedPlain ghExec `shouldBe` True
      lookup "GH_TOKEN" (greEnvExtras ghExec) `shouldBe` Nothing

  --------------------------------------------------------------------
  -- Test 10: Locked vault → credential resolution failed: vault locked
  --------------------------------------------------------------------

  describe "locked vault" $ do
    it "gh pr create surfaces 'credential resolution failed: vault locked — run /vault unlock'" $ do
      deps <- mkLockedVaultDeps [patRepo] False
      seen <- newIORef []
      let uio = ghFakeUio seen registeredUrl "done\n"
      result <- runOp uio deps testOp ghPrCreateInput
      orIsError result `shouldBe` True
      let notes = textParts result
      any ("credential resolution failed" `T.isInfixOf`) notes `shouldBe` True
      any ("vault locked" `T.isInfixOf`) notes `shouldBe` True
      any ("/vault unlock" `T.isInfixOf`) notes `shouldBe` True
      -- The expected message reuses renderCloneError (CloneVaultError VaultLocked).
      let expected = "BIN_EXEC: credential resolution failed: " <> renderCloneError (CloneVaultError VaultLocked)
      expected `elem` notes `shouldBe` True

  --------------------------------------------------------------------
  -- Test 11: Missing vault key → vault key <name> not found
  --------------------------------------------------------------------

  describe "missing vault key" $ do
    it "gh pr create surfaces 'vault key K_PAT not found'" $ do
      deps <- mkMissingKeyDeps [patRepo] False
      seen <- newIORef []
      let uio = ghFakeUio seen registeredUrl "done\n"
      result <- runOp uio deps testOp ghPrCreateInput
      orIsError result `shouldBe` True
      let notes = textParts result
      any ("credential resolution failed" `T.isInfixOf`) notes `shouldBe` True
      any ("vault key K_PAT not found" `T.isInfixOf`) notes `shouldBe` True

  --------------------------------------------------------------------
  -- Test 12: Pre-flight git config failure → surfacable error
  --------------------------------------------------------------------

  describe "pre-flight git config failure" $ do
    it "surfaces 'BIN_EXEC: pre-flight git config failed: ...'" $ do
      deps <- mkPatDeps [patRepo] False
      seen <- newIORef []
      let uio = ghFakeUioPreFlightFail seen "done\n"
      result <- runOp uio deps testOp ghPrCreateInput
      orIsError result `shouldBe` True
      let notes = textParts result
      any ("BIN_EXEC: pre-flight git config failed" `T.isInfixOf`) notes `shouldBe` True
      -- Only the pre-flight ran (the gh call was never reached).
      assertCount seen 1
      preflight <- getExec seen 0
      greBinary preflight `shouldBe` "git"
      greArgs preflight `shouldBe` ["config", "--get", "remote.origin.url"]

  --------------------------------------------------------------------
  -- Test 13: Transcript record is secret-free
  --------------------------------------------------------------------

  describe "transcript record (secret-free)" $ do
    it "orRecorded has no GH_TOKEN, no token, no env extras" $ do
      deps <- mkPatDeps [patRepo] False
      seen <- newIORef []
      let uio = ghFakeUio seen registeredUrl "done\n"
      result <- runOp uio deps testOp ghPrCreateInput
      orIsError result `shouldBe` False
      orRecorded result `shouldBe` object
        [ "binary" .= ("gh" :: Text)
        , "arg_count" .= (4 :: Int)
        , "cwd" .= (Nothing :: Maybe String)
        ]
      let recordedStr = T.pack (show (orRecorded result))
      "GH_TOKEN" `T.isInfixOf` recordedStr `shouldBe` False
      "ghp_FAKE_TOKEN_12345" `T.isInfixOf` recordedStr `shouldBe` False

  --------------------------------------------------------------------
  -- Test 14: Local/remote parity (cases 1–9 in both modes)
  --------------------------------------------------------------------

  describe "local/remote parity" $ do

    it "PAT repo: both modes inject GH_TOKEN via uioBinExecEnv" $ do
      depsL <- mkPatDeps [patRepo] False
      seenL <- newIORef []
      let uioL = ghFakeUio seenL registeredUrl "done\n"
      resultL <- runOp uioL depsL testOp ghPrCreateInput
      depsR <- mkPatDeps [patRepo] True
      seenR <- newIORef []
      let uioR = ghFakeUio seenR registeredUrl "done\n"
      resultR <- runOp uioR depsR testOp ghPrCreateInput
      orIsError resultL `shouldBe` orIsError resultR
      orParts resultL `shouldBe` orParts resultR
      ghL <- getExec seenL 1
      ghR <- getExec seenR 1
      greUsedEnv ghL `shouldBe` greUsedEnv ghR
      greUsedGitEnv ghL `shouldBe` greUsedGitEnv ghR
      greUsedPlain ghL `shouldBe` greUsedPlain ghR
      lookup "GH_TOKEN" (greEnvExtras ghL) `shouldBe` Just "ghp_FAKE_TOKEN_12345"
      lookup "GH_TOKEN" (greEnvExtras ghR) `shouldBe` Just "ghp_FAKE_TOKEN_12345"

    it "MachineUser repo: both modes inject the raw MachineUser token" $ do
      depsL <- mkMachineUserDeps [machineUserRepo] False
      seenL <- newIORef []
      let uioL = ghFakeUio seenL registeredUrl "merged\n"
      resultL <- runOp uioL depsL testOp ghPrMergeInput
      depsR <- mkMachineUserDeps [machineUserRepo] True
      seenR <- newIORef []
      let uioR = ghFakeUio seenR registeredUrl "merged\n"
      resultR <- runOp uioR depsR testOp ghPrMergeInput
      orIsError resultL `shouldBe` orIsError resultR
      orParts resultL `shouldBe` orParts resultR
      ghL <- getExec seenL 1
      ghR <- getExec seenR 1
      greUsedEnv ghL `shouldBe` greUsedEnv ghR
      lookup "GH_TOKEN" (greEnvExtras ghL) `shouldBe` Just "mhp_MACHINEUSER_TOKEN_999"
      lookup "GH_TOKEN" (greEnvExtras ghR) `shouldBe` Just "mhp_MACHINEUSER_TOKEN_999"

    it "deploy-key repo: both modes fall through to plain uioBinExec" $
      withSystemTempDirectory "seal-ghspec-parity-keyfiles" $ \keyfilesDir -> do
        depsL <- mkDeployKeyDeps [deployKeyRepo] False keyfilesDir
        seenL <- newIORef []
        let uioL = ghFakeUio seenL registeredUrl "done\n"
        resultL <- runOp uioL depsL testOp ghPrCreateInput
        depsR <- mkDeployKeyDeps [deployKeyRepo] True keyfilesDir
        seenR <- newIORef []
        let uioR = ghFakeUio seenR registeredUrl "done\n"
        resultR <- runOp uioR depsR testOp ghPrCreateInput
        orIsError resultL `shouldBe` orIsError resultR
        orParts resultL `shouldBe` orParts resultR
        ghL <- getExec seenL 1
        ghR <- getExec seenR 1
        greUsedPlain ghL `shouldBe` greUsedPlain ghR
        greEnvExtras ghL `shouldBe` greEnvExtras ghR

    it "unregistered repo: both modes fall through to plain uioBinExec" $ do
      depsL <- mkPatDeps [patRepo] False
      seenL <- newIORef []
      let uioL = ghFakeUio seenL unregisteredUrl "done\n"
      resultL <- runOp uioL depsL testOp ghPrCreateInput
      depsR <- mkPatDeps [patRepo] True
      seenR <- newIORef []
      let uioR = ghFakeUio seenR unregisteredUrl "done\n"
      resultR <- runOp uioR depsR testOp ghPrCreateInput
      orIsError resultL `shouldBe` orIsError resultR
      orParts resultL `shouldBe` orParts resultR
      ghL <- getExec seenL 1
      ghR <- getExec seenR 1
      greUsedPlain ghL `shouldBe` greUsedPlain ghR
      greEnvExtras ghL `shouldBe` greEnvExtras ghR

    it "no origin: both modes fall through to plain uioBinExec" $ do
      depsL <- mkPatDeps [patRepo] False
      seenL <- newIORef []
      let uioL = ghFakeUio seenL "" "done\n"
      resultL <- runOp uioL depsL testOp ghAuthStatusInput
      depsR <- mkPatDeps [patRepo] True
      seenR <- newIORef []
      let uioR = ghFakeUio seenR "" "done\n"
      resultR <- runOp uioR depsR testOp ghAuthStatusInput
      orIsError resultL `shouldBe` orIsError resultR
      orParts resultL `shouldBe` orParts resultR
      ghL <- getExec seenL 1
      ghR <- getExec seenR 1
      greUsedPlain ghL `shouldBe` greUsedPlain ghR
      greEnvExtras ghL `shouldBe` greEnvExtras ghR

    it "-R space short: both modes skip injection + NOTE" $ do
      let input = ghInputWithArgs ["-R", "owner/other", "pr", "create"]
      depsL <- mkPatDeps [patRepo] False
      seenL <- newIORef []
      let uioL = ghFakeUio seenL registeredUrl "done\n"
      resultL <- runOp uioL depsL testOp input
      depsR <- mkPatDeps [patRepo] True
      seenR <- newIORef []
      let uioR = ghFakeUio seenR registeredUrl "done\n"
      resultR <- runOp uioR depsR testOp input
      orIsError resultL `shouldBe` orIsError resultR
      orParts resultL `shouldBe` orParts resultR
      ghL <- getExec seenL 0
      ghR <- getExec seenR 0
      greUsedPlain ghL `shouldBe` greUsedPlain ghR
      greEnvExtras ghL `shouldBe` greEnvExtras ghR

    it "--repo= joined long: both modes skip injection + NOTE" $ do
      let input = ghInputWithArgs ["--repo=owner/other", "pr", "create"]
      depsL <- mkPatDeps [patRepo] False
      seenL <- newIORef []
      let uioL = ghFakeUio seenL registeredUrl "done\n"
      resultL <- runOp uioL depsL testOp input
      depsR <- mkPatDeps [patRepo] True
      seenR <- newIORef []
      let uioR = ghFakeUio seenR registeredUrl "done\n"
      resultR <- runOp uioR depsR testOp input
      orIsError resultL `shouldBe` orIsError resultR
      orParts resultL `shouldBe` orParts resultR
      ghL <- getExec seenL 0
      ghR <- getExec seenR 0
      greUsedPlain ghL `shouldBe` greUsedPlain ghR

    it "-R joined short: both modes skip injection + NOTE" $ do
      let input = ghInputWithArgs ["-Rowner/other-repo", "pr", "create"]
      depsL <- mkPatDeps [patRepo] False
      seenL <- newIORef []
      let uioL = ghFakeUio seenL registeredUrl "done\n"
      resultL <- runOp uioL depsL testOp input
      depsR <- mkPatDeps [patRepo] True
      seenR <- newIORef []
      let uioR = ghFakeUio seenR registeredUrl "done\n"
      resultR <- runOp uioR depsR testOp input
      orIsError resultL `shouldBe` orIsError resultR
      orParts resultL `shouldBe` orParts resultR
      ghL <- getExec seenL 0
      ghR <- getExec seenR 0
      greUsedPlain ghL `shouldBe` greUsedPlain ghR

    it "--repo space long: both modes skip injection + NOTE" $ do
      let input = ghInputWithArgs ["--repo", "owner/other", "pr", "create"]
      depsL <- mkPatDeps [patRepo] False
      seenL <- newIORef []
      let uioL = ghFakeUio seenL registeredUrl "done\n"
      resultL <- runOp uioL depsL testOp input
      depsR <- mkPatDeps [patRepo] True
      seenR <- newIORef []
      let uioR = ghFakeUio seenR registeredUrl "done\n"
      resultR <- runOp uioR depsR testOp input
      orIsError resultL `shouldBe` orIsError resultR
      orParts resultL `shouldBe` orParts resultR
      ghL <- getExec seenL 0
      ghR <- getExec seenR 0
      greUsedPlain ghL `shouldBe` greUsedPlain ghR

  --------------------------------------------------------------------
  -- Cross-WU integration: log redaction (WU-A × WU-B)
  --
  -- Asserts that a PAT-injection gh call's captured debug-log output
  -- contains GH_TOKEN=<redacted> and NOT the raw token. Uses the REAL
  -- remote arm (mkRemoteUntrustedIO + mkFakeRemoteRunner) so
  -- uioBinExecEnv routes through runRemoteShellTextEnv → logExecDebug
  -- "[remote ssh]" with the GH_TOKEN extra. The fake runner intercepts
  -- before any real SSH call; only the log path is exercised.
  --------------------------------------------------------------------

  describe "cross-WU: log redaction (WU-A × WU-B)" $ do
    it "a PAT-injection gh call logs GH_TOKEN=<redacted> (not the raw token)" $ do
      deps <- mkPatDeps [patRepo] True
      -- The fake runner returns the registered URL for EVERY call. The
      -- pre-flight @git config@ reads it as the remote URL (trimmed);
      -- the actual @gh@ call returns it as stdout (harmless — the test
      -- only asserts on the captured log, not the gh output). The key
      -- point: the pre-flight resolves the registered repo → the gh
      -- path injects GH_TOKEN via uioBinExecEnv → runRemoteShellTextEnv
      -- → logExecDebug "[remote ssh]" with the GH_TOKEN extra, which
      -- redactEnv redacts before rendering.
      let runner = mkFakeRemoteRunner (Right registeredUrl)
          uio = mkRemoteUntrustedIO sshCfg runner
      (result, lines_) <- withCaptureGlobalLogger $
        runOp uio deps testOp ghPrCreateInput
      orIsError result `shouldBe` False
      let allText = T.unlines lines_
      -- The GH_TOKEN key is preserved (so the reader sees an env override
      -- was applied), but the value is redacted.
      ("GH_TOKEN=<redacted>" `T.isInfixOf` allText) `shouldBe` True
      -- The raw token NEVER appears in the captured log output.
      ("ghp_FAKE_TOKEN_12345" `T.isInfixOf` allText) `shouldBe` False