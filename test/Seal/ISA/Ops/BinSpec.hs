{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.BinSpec (spec) where
import Control.Monad.IO.Class (liftIO)
import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe)
import Seal.Tools.Exec.UIO (runUIOWithEnv)
import Seal.Tools.Exec.UIO.Internal (mkTestUIOEnv)
import Seal.SourceControl.Clone (CloneDeps (..), stubCloneDeps)
import Data.Aeson (Value, object, (.=))
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Set qualified as Set
import System.IO.Temp (withSystemTempDirectory)
import System.FilePath ((</>))
import System.Directory (createDirectoryIfMissing)
import Test.Hspec
import Test.QuickCheck (property)

import Seal.Core.AllowList (AllowList (..))
import Seal.ISA.Opcode (OpResult (..), Opcode, uoRun, uoAuthorize)
import Seal.ISA.Ops.Bin
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.SourceControl.GithubKeys (pinnedGithubKnownHosts)
import Seal.SourceControl.Repo
  ( RepoCredential (..), SourceRepo (..), VcsKind (..)
  , mkRepoId )
import Seal.SourceControl.Registry (RepoRegistryHandle (..))
import Seal.SourceControl.AgentRegistry (mkAgentRegistryHandle)
import Seal.TestHelpers.FakeVault (makeFakeVaultRuntime)
import Seal.Tools.Args (textBinArg, textBinName)
import Seal.Tools.Exec.Types (getRemotePath)
import Seal.Tools.Exec.UntrustedIO
  ( UntrustedIO (..), mkRemoteUntrustedIOStub )
import Seal.Tools.Ssh.Agent
  ( SshAgentEnv (..), mkFakeSshAgentHandle )
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env
import Seal.Logging.Logger (testSealLogger)
import Seal.TestHelpers.Arbitrary ()  -- Arbitrary Text

-- | Local replacement for the removed uoRunLegacy: runs the opcode's uoRun
-- in a UIOEnv built from the UntrustedIO + optional CloneDeps.
runOp :: UntrustedIO -> Maybe CloneDeps -> Opcode -> Value -> App OpResult
runOp uio mDeps op input =
  liftIO (runUIOWithEnv (mkTestUIOEnv uio (fromMaybe stubCloneDeps mDeps)) (uoRun op input))
runTestApp :: App a -> IO a
runTestApp act = do logger <- testSealLogger; env <- mkEnv logger defaultConfig; runApp env act

-- | A fake 'UntrustedIO' that records the binary invocation (binary, args,
-- and the cwd 'RemotePath' the opcode resolved) and returns canned output.
-- Other methods are the fail-closed stub.
fakeUio :: IORef [(Text, [Text], Maybe Text)] -> Text -> UntrustedIO
fakeUio seen canned = mkRemoteUntrustedIOStub
  { uioBinExec = \bin args mCwd -> do
      modifyIORef' seen (++ [( textBinName bin
                             , map textBinArg args
                             , fmap getRemotePath mCwd )])
      pure (Right canned)
  }

-- | A fake 'UntrustedIO' that records the binary invocation as a flat
-- string (binary + args, no cwd) — for tests that only check the
-- command line.
fakeUioFlat :: IORef [Text] -> Text -> UntrustedIO
fakeUioFlat seen canned = mkRemoteUntrustedIOStub
  { uioBinExec = \bin args _mCwd -> do
      modifyIORef' seen (++ [textBinName bin <> " " <> T.intercalate " " (map textBinArg args)])
      pure (Right canned)
  }

----------------------------------------------------------------------------
-- gh credential-injection test harness (ported from BinGitSpec)
----------------------------------------------------------------------------

-- | A recorded exec call — captures which UntrustedIO method was used and
-- the env extras passed.
data GhRecordedExec = GhRecordedExec
  { greBinary     :: Text
  , greArgs       :: [Text]
  , greCwd        :: Maybe Text
  , greEnvExtras  :: [(String, String)]
  , greUsedGitEnv :: Bool
  , greUsedEnv    :: Bool
  , greUsedPlain  :: Bool
  } deriving stock (Eq, Show)

-- | Build a fake 'UntrustedIO' that records exec calls for the gh path.
-- The @remoteUrl@ is the canned output for the pre-flight @git config
-- --get remote.origin.url@. The @finalOutput@ is the canned output for
-- the actual gh command.
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

-- | Build a fake 'RepoRegistryHandle' that returns the given repos.
ghFakeRepoReg :: [SourceRepo] -> RepoRegistryHandle
ghFakeRepoReg repos = RepoRegistryHandle
  { rrhList   = pure (Right repos)
  , rrhMutate = \_ -> pure (Right ())
  }

-- | Build 'CloneDeps' for a deploy-key repo test (local).
ghMkDeployKeyDeps :: [SourceRepo] -> FilePath -> IO CloneDeps
ghMkDeployKeyDeps repos keyfilesDir = do
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
    , cdIsRemote = False
    }

-- | Build 'CloneDeps' for a PAT repo test (local).
ghMkPatDeps :: [SourceRepo] -> IO CloneDeps
ghMkPatDeps repos = do
  vault <- makeFakeVaultRuntime [("K_PAT", "ghp_FAKE_TOKEN_12345")]
  agentRegH <- mkAgentRegistryHandle "/tmp/seal-test-agentreg-gh-pat"
  agentCallsRef <- newIORef []
  pure CloneDeps
    { cdVault = vault
    , cdRepoReg = ghFakeRepoReg repos
    , cdSshAgent = mkFakeSshAgentHandle agentCallsRef (SshAgentEnv "/tmp/fake" "0")
    , cdAgentRegistry = agentRegH
    , cdPinnedKnownHosts = pinnedGithubKnownHosts
    , cdKeyfilesDir = "/tmp/seal-test-keyfiles-gh-pat"
    , cdIsRemote = False
    }

-- | Run the BIN_EXEC opcode's uoRun with the given UntrustedIO + CloneDeps
-- (direct IO — no App transformer, mirrors BinGitSpec's runOp).
ghRunOp :: UntrustedIO -> CloneDeps -> Opcode -> Value -> IO OpResult
ghRunOp uio deps op input =
  runUIOWithEnv (mkTestUIOEnv uio deps) (uoRun op input)

-- | A test repo with a deploy key credential.
ghDeployKeyRepo :: SourceRepo
ghDeployKeyRepo =
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
ghPatRepo :: SourceRepo
ghPatRepo =
  let rid = case mkRepoId "test-repo" of Right i -> i; Left e -> error (show e)
  in SourceRepo
    { srId = rid
    , srUrl = "git@github.com:owner/test-repo.git"
    , srVcsKind = VcsGitHub
    , srCredential = CredPat "K_PAT"
    , srDeployKeyPublic = Nothing
    , srKeyfilePath = Nothing
    }

-- | The standard op used in gh tests (no allow-list, full autonomy).
ghTestOp :: Opcode
ghTestOp = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing

-- | @gh pr create --title x@ input.
ghPrCreateInput :: Value
ghPrCreateInput = object
  [ "binary" .= ("gh" :: Text)
  , "args" .= (["pr", "create", "--title", "x"] :: [Text])
  ]

-- | Build a @gh@ input with the given args.
ghInputWithArgs :: [Text] -> Value
ghInputWithArgs args = object
  [ "binary" .= ("gh" :: Text)
  , "args" .= args
  ]

-- | Assert the recorded list has exactly @n@ entries, then extract the
-- nth (0-indexed) via pattern matching (no partial functions).
ghGetExec :: IORef [GhRecordedExec] -> Int -> IO GhRecordedExec
ghGetExec ref idx = do
  recorded <- readIORef ref
  case drop idx recorded of
    (e : _) -> pure e
    _       -> error ("ghGetExec: expected at least " <> show (idx + 1) <> " entries (test invariant violation)")

-- | Assert the recorded list has exactly @n@ entries.
ghAssertCount :: IORef [GhRecordedExec] -> Int -> IO ()
ghAssertCount ref expectedLen = do
  recorded <- readIORef ref
  length recorded `shouldBe` expectedLen

spec :: Spec
spec = describe "Seal.ISA.Ops.Bin" $ do

  describe "BIN_EXEC" $ do

    it "runs a binary via an allow-listed name" $ do
      seen <- newIORef []
      let uio = fakeUioFlat seen "42\n"
          allowList = Just (Set.fromList ["python3", "node"])
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) allowList
      r <- runTestApp (runOp uio Nothing op (object
        [ "binary" .= ("python3" :: String)
        , "args" .= (["-c", "print(42)"] :: [String])
        ]))
      orIsError r `shouldBe` False
      orParts r `shouldBe` [TrpText "42\n"]
      readIORef seen `shouldReturn` ["python3 -c print(42)"]

    it "binary not in allow-list -> Denied" $ do
      let allowList = Just (Set.fromList ["python3"])
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) allowList
      uoAuthorize op (object
        [ "binary" .= ("rm" :: String)
        , "args" .= (["-rf", "/"] :: [String])
        ]) `shouldBe` Left "BIN_EXEC: binary \"rm\" not in the allow-list"

    it "missing binary field -> error" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) (Just Set.empty)
      uoAuthorize op (object ["args" .= (["x"] :: [String])])
        `shouldBe` Left "BIN_EXEC requires {binary:string, args:[string]}"

    it "args field is optional (defaults to [])" $ do
      seen <- newIORef []
      let uio = fakeUioFlat seen "ok\n"
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      r <- runTestApp (runOp uio Nothing op (object
        [ "binary" .= ("ls" :: String)
        ]))
      orIsError r `shouldBe` False
      readIORef seen `shouldReturn` ["ls "]

    it "binary with NUL -> Denied (validated BinName rejects NUL)" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      uoAuthorize op (object
        [ "binary" .= ("ev\0il" :: String)
        ]) `shouldBe` Left "BIN_EXEC: invalid binary name"

    it "arg with NUL -> Denied (validated BinArg rejects NUL)" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      uoAuthorize op (object
        [ "binary" .= ("ls" :: String)
        , "args" .= ["ok\0bad" :: String]
        ]) `shouldBe` Left "BIN_EXEC: invalid arg"

    it "leading-dash arg is permitted (flag, not option injection)" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) (Just (Set.fromList ["ls"]))
      uoAuthorize op (object
        [ "binary" .= ("ls" :: String)
        , "args" .= (["-l", "-a"] :: [String])
        ]) `shouldBe` Right ()

    it "Nothing allow-list permits any binary (autonomy permitting)" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      uoAuthorize op (object
        [ "binary" .= ("rm" :: String)
        , "args" .= (["-rf", "/"] :: [String])
        ]) `shouldBe` Right ()

    it "orRecorded captures the binary + arg count (secret-free, not the args)" $ do
      seen <- newIORef []
      let uio = fakeUioFlat seen ""
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      r <- runTestApp (runOp uio Nothing op (object
        [ "binary" .= ("node" :: String)
        , "args" .= (["-e", "console.log('hi')"] :: [String])
        ]))
      orRecorded r `shouldBe` object
        [ "binary" .= ("node" :: String)
        , "arg_count" .= (2 :: Int)
        , "cwd" .= (Nothing :: Maybe String)
        ]

    it "gh auth is blocked (writes secrets to disk)" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      r <- runTestApp (runOp mkRemoteUntrustedIOStub Nothing op (object
        [ "binary" .= ("gh" :: String)
        , "args" .= (["auth", "login"] :: [String])
        ]))
      orIsError r `shouldBe` True
      let partsText = [t | TrpText t <- orParts r]
      partsText `shouldSatisfy` any (\t -> "gh auth" `T.isInfixOf` t && "blocked" `T.isInfixOf` t)

    it "gh auth token is blocked (prints secret to stdout)" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      r <- runTestApp (runOp mkRemoteUntrustedIOStub Nothing op (object
        [ "binary" .= ("gh" :: String)
        , "args" .= (["auth", "token"] :: [String])
        ]))
      orIsError r `shouldBe` True
      let partsText = [t | TrpText t <- orParts r]
      partsText `shouldSatisfy` any (\t -> "gh auth" `T.isInfixOf` t && "blocked" `T.isInfixOf` t)

    it "gh pr create is NOT blocked (authenticates via GH_TOKEN)" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      -- The authorize gate should pass (gh pr create is not blocked).
      uoAuthorize op (object
        [ "binary" .= ("gh" :: String)
        , "args" .= (["pr", "create", "--title", "test"] :: [String])
        ]) `shouldBe` Right ()

  describe "BIN_EXEC cwd" $ do

    it "defaults cwd to Nothing when omitted (the executor anchors it to the workdir)" $ do
      seen <- newIORef []
      let uio = fakeUio seen "ok\n"
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      _ <- runTestApp (runOp uio Nothing op (object
        [ "binary" .= ("pwd" :: String)
        ]))
      readIORef seen `shouldReturn` [("pwd", [], Nothing)]

    it "passes a relative cwd as a RemotePath (workspace-relative)" $ do
      seen <- newIORef []
      let uio = fakeUio seen "ok\n"
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      _ <- runTestApp (runOp uio Nothing op (object
        [ "binary" .= ("pwd" :: String)
        , "cwd" .= ("subdir" :: String)
        ]))
      readIORef seen `shouldReturn` [("pwd", [], Just "subdir")]

    it "passes an absolute cwd as a RemotePath (not workspace-confined)" $ do
      seen <- newIORef []
      let uio = fakeUio seen "ok\n"
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      _ <- runTestApp (runOp uio Nothing op (object
        [ "binary" .= ("pwd" :: String)
        , "cwd" .= ("/tmp/seal-test" :: String)
        ]))
      readIORef seen `shouldReturn` [("pwd", [], Just "/tmp/seal-test")]

    it "rejects a @..@ cwd at the authorize gate (escape before execution)" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      uoAuthorize op (object
        [ "binary" .= ("ls" :: String)
        , "cwd" .= ("../escape" :: String)
        ]) `shouldBe` Left "BIN_EXEC: cwd escapes the workspace"

    it "rejects a blocked-name cwd at the authorize gate" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      uoAuthorize op (object
        [ "binary" .= ("ls" :: String)
        , "cwd" .= (".ssh" :: String)
        ]) `shouldBe` Left "BIN_EXEC: cwd touches a blocked location"

    it "rejects a leading-dash cwd at the authorize gate (option injection)" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      uoAuthorize op (object
        [ "binary" .= ("ls" :: String)
        , "cwd" .= ("-evil" :: String)
        ]) `shouldBe` Left "BIN_EXEC: cwd must not start with '-'"

    it "orRecorded captures the cwd (secret-free metadata)" $ do
      seen <- newIORef []
      let uio = fakeUio seen ""
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      r <- runTestApp (runOp uio Nothing op (object
        [ "binary" .= ("pwd" :: String)
        , "cwd" .= ("subdir" :: String)
        ]))
      orRecorded r `shouldBe` object
        [ "binary" .= ("pwd" :: String)
        , "arg_count" .= (Nothing :: Maybe Int)
        , "cwd" .= ("subdir" :: String)
        ]

  describe "extractGhRepoFlag" $ do

    it "-R space-separated short: returns Just value" $
      extractGhRepoFlag ["-R", "owner/repo", "pr", "create"]
        `shouldBe` Just "owner/repo"

    it "-R joined short (-Rvalue): returns Just value" $
      extractGhRepoFlag ["-Rowner/repo", "pr", "create"]
        `shouldBe` Just "owner/repo"

    it "--repo space-separated long: returns Just value" $
      extractGhRepoFlag ["--repo", "owner/repo", "pr", "create"]
        `shouldBe` Just "owner/repo"

    it "--repo= joined long: returns Just value" $
      extractGhRepoFlag ["--repo=owner/repo", "pr", "create"]
        `shouldBe` Just "owner/repo"

    it "global flag AFTER subcommand: returns Just value" $
      extractGhRepoFlag ["pr", "create", "-R", "owner/repo"]
        `shouldBe` Just "owner/repo"

    it "no -R/--repo flag: returns Nothing" $
      extractGhRepoFlag ["pr", "create", "--title", "x"]
        `shouldBe` Nothing

    it "empty argv: returns Nothing" $
      extractGhRepoFlag [] `shouldBe` Nothing

    it "-R at end with no value: returns Nothing" $
      extractGhRepoFlag ["pr", "create", "-R"] `shouldBe` Nothing

    it "first -R value wins (when multiple -R flags)" $
      extractGhRepoFlag ["-R", "first/repo", "-R", "second/repo"]
        `shouldBe` Just "first/repo"

    it "QuickCheck: never crashes, returns Just first -R/--repo value or Nothing" $
      property $ \argv ->
        case extractGhRepoFlag argv of
          Just _  -> True
          Nothing -> not (hasAnyRepoFlag argv)

  --------------------------------------------------------------------
  -- gh credential injection (runGhWithCredentials)
  --------------------------------------------------------------------

  describe "gh credential injection" $ do

    it "PAT repo: gh pr create injects GH_TOKEN via uioBinExecEnv" $ do
      deps <- ghMkPatDeps [ghPatRepo]
      seen <- newIORef []
      let uio = ghFakeUio seen "git@github.com:owner/test-repo.git\n" "done\n"
      result <- ghRunOp uio deps ghTestOp ghPrCreateInput
      orIsError result `shouldBe` False
      orParts result `shouldBe` [TrpText "done\n"]
      -- Two exec calls: pre-flight git config, then gh via uioBinExecEnv.
      ghAssertCount seen 2
      preflight <- ghGetExec seen 0
      greBinary preflight `shouldBe` "git"
      greArgs preflight `shouldBe` ["config", "--get", "remote.origin.url"]
      greUsedPlain preflight `shouldBe` True
      ghExec <- ghGetExec seen 1
      greBinary ghExec `shouldBe` "gh"
      greArgs ghExec `shouldBe` ["pr", "create", "--title", "x"]
      greUsedEnv ghExec `shouldBe` True
      greUsedGitEnv ghExec `shouldBe` False
      greUsedPlain ghExec `shouldBe` False
      -- GH_TOKEN is in the env extras, byte-accurate (BS.unpack of the
      -- vault token "ghp_FAKE_TOKEN_12345").
      lookup "GH_TOKEN" (greEnvExtras ghExec) `shouldBe` Just "ghp_FAKE_TOKEN_12345"

    it "PAT repo: GH_TOKEN value is byte-accurate (BS.unpack, not decodeUtf8Lenient)" $ do
      -- Use a token with a non-UTF-8 byte (0xFF) to verify BS.unpack
      -- maps each byte 1:1 to a Char (no U+FFFD corruption).
      let nonUtf8Token = "secret" <> BS.singleton 0xFF <> "bytes"
      vault <- makeFakeVaultRuntime [("K_PAT", nonUtf8Token)]
      agentRegH <- mkAgentRegistryHandle "/tmp/seal-test-agentreg-gh-bytes"
      agentCallsRef <- newIORef []
      let deps = CloneDeps
            { cdVault = vault
            , cdRepoReg = ghFakeRepoReg [ghPatRepo]
            , cdSshAgent = mkFakeSshAgentHandle agentCallsRef (SshAgentEnv "/tmp/fake" "0")
            , cdAgentRegistry = agentRegH
            , cdPinnedKnownHosts = pinnedGithubKnownHosts
            , cdKeyfilesDir = "/tmp/seal-test-keyfiles-gh-bytes"
            , cdIsRemote = False
            }
      seen <- newIORef []
      let uio = ghFakeUio seen "git@github.com:owner/test-repo.git\n" "done\n"
      _result <- ghRunOp uio deps ghTestOp ghPrCreateInput
      ghExec <- ghGetExec seen 1
      -- BS.unpack maps 0xFF to the Char with codepoint 255 (NOT U+FFFD).
      lookup "GH_TOKEN" (greEnvExtras ghExec)
        `shouldBe` Just (map (toEnum . fromIntegral) (BS.unpack nonUtf8Token))

    it "deploy-key repo: gh pr create falls through to plain uioBinExec" $
      withSystemTempDirectory "seal-gh-keyfiles" $ \keyfilesDir -> do
        deps <- ghMkDeployKeyDeps [ghDeployKeyRepo] keyfilesDir
        seen <- newIORef []
        let uio = ghFakeUio seen "git@github.com:owner/test-repo.git\n" "done\n"
        result <- ghRunOp uio deps ghTestOp ghPrCreateInput
        orIsError result `shouldBe` False
        orParts result `shouldBe` [TrpText "done\n"]
        -- Two exec calls: pre-flight git config, then gh via plain
        -- uioBinExec (no injection — gh can't use SSH).
        ghAssertCount seen 2
        ghExec <- ghGetExec seen 1
        greBinary ghExec `shouldBe` "gh"
        greUsedPlain ghExec `shouldBe` True
        greUsedEnv ghExec `shouldBe` False
        greUsedGitEnv ghExec `shouldBe` False
        greEnvExtras ghExec `shouldBe` []
        -- No GH_TOKEN injected.
        lookup "GH_TOKEN" (greEnvExtras ghExec) `shouldBe` Nothing

    it "unregistered repo: gh pr create falls through to plain uioBinExec" $ do
      deps <- ghMkPatDeps [ghPatRepo]
      seen <- newIORef []
      let uio = ghFakeUio seen "git@github.com:owner/other-repo.git\n" "done\n"
      result <- ghRunOp uio deps ghTestOp ghPrCreateInput
      orIsError result `shouldBe` False
      orParts result `shouldBe` [TrpText "done\n"]
      ghAssertCount seen 2
      ghExec <- ghGetExec seen 1
      greUsedPlain ghExec `shouldBe` True
      greEnvExtras ghExec `shouldBe` []
      lookup "GH_TOKEN" (greEnvExtras ghExec) `shouldBe` Nothing

    it "no remote.origin.url: gh auth status falls through to plain uioBinExec" $ do
      deps <- ghMkPatDeps [ghPatRepo]
      seen <- newIORef []
      let uio = ghFakeUio seen "" "done\n"
          input = ghInputWithArgs ["auth", "status"]
      result <- ghRunOp uio deps ghTestOp input
      orIsError result `shouldBe` False
      orParts result `shouldBe` [TrpText "done\n"]
      ghAssertCount seen 2
      ghExec <- ghGetExec seen 1
      greUsedPlain ghExec `shouldBe` True
      greEnvExtras ghExec `shouldBe` []

    it "gh -R owner/repo (space short) skips injection + NOTE in orParts" $ do
      deps <- ghMkPatDeps [ghPatRepo]
      seen <- newIORef []
      let uio = ghFakeUio seen "git@github.com:owner/test-repo.git\n" "done\n"
          input = ghInputWithArgs ["-R", "owner/other", "pr", "create"]
      result <- ghRunOp uio deps ghTestOp input
      orIsError result `shouldBe` False
      -- orParts has the output + the NOTE (no injection, plain exec).
      length (orParts result) `shouldSatisfy` (>= 2)
      let noteTexts = [t | TrpText t <- orParts result]
      any ("credential injection skipped" `T.isInfixOf`) noteTexts `shouldBe` True
      any ("-R/--repo detected" `T.isInfixOf`) noteTexts `shouldBe` True
      -- Only ONE exec call (no pre-flight — the -R skip happens first).
      ghAssertCount seen 1
      ghExec <- ghGetExec seen 0
      greBinary ghExec `shouldBe` "gh"
      greUsedPlain ghExec `shouldBe` True
      greEnvExtras ghExec `shouldBe` []
      lookup "GH_TOKEN" (greEnvExtras ghExec) `shouldBe` Nothing

    it "gh -Rowner/repo (joined short) skips injection + NOTE" $ do
      deps <- ghMkPatDeps [ghPatRepo]
      seen <- newIORef []
      let uio = ghFakeUio seen "git@github.com:owner/test-repo.git\n" "done\n"
          input = ghInputWithArgs ["-Rowner/other", "pr", "create"]
      result <- ghRunOp uio deps ghTestOp input
      orIsError result `shouldBe` False
      let noteTexts = [t | TrpText t <- orParts result]
      any ("credential injection skipped" `T.isInfixOf`) noteTexts `shouldBe` True
      ghAssertCount seen 1
      ghExec <- ghGetExec seen 0
      greUsedPlain ghExec `shouldBe` True

    it "gh --repo owner/repo (space long) skips injection + NOTE" $ do
      deps <- ghMkPatDeps [ghPatRepo]
      seen <- newIORef []
      let uio = ghFakeUio seen "git@github.com:owner/test-repo.git\n" "done\n"
          input = ghInputWithArgs ["--repo", "owner/other", "pr", "create"]
      result <- ghRunOp uio deps ghTestOp input
      orIsError result `shouldBe` False
      let noteTexts = [t | TrpText t <- orParts result]
      any ("credential injection skipped" `T.isInfixOf`) noteTexts `shouldBe` True
      ghAssertCount seen 1
      ghExec <- ghGetExec seen 0
      greUsedPlain ghExec `shouldBe` True

    it "gh --repo=owner/repo (joined long) skips injection + NOTE" $ do
      deps <- ghMkPatDeps [ghPatRepo]
      seen <- newIORef []
      let uio = ghFakeUio seen "git@github.com:owner/test-repo.git\n" "done\n"
          input = ghInputWithArgs ["--repo=owner/other", "pr", "create"]
      result <- ghRunOp uio deps ghTestOp input
      orIsError result `shouldBe` False
      let noteTexts = [t | TrpText t <- orParts result]
      any ("credential injection skipped" `T.isInfixOf`) noteTexts `shouldBe` True
      ghAssertCount seen 1
      ghExec <- ghGetExec seen 0
      greUsedPlain ghExec `shouldBe` True

    it "transcript recorded is secret-free (no GH_TOKEN, no env, no token)" $ do
      deps <- ghMkPatDeps [ghPatRepo]
      seen <- newIORef []
      let uio = ghFakeUio seen "git@github.com:owner/test-repo.git\n" "done\n"
      result <- ghRunOp uio deps ghTestOp ghPrCreateInput
      orIsError result `shouldBe` False
      orRecorded result `shouldBe` object
        [ "binary" .= ("gh" :: Text)
        , "arg_count" .= (4 :: Int)
        , "cwd" .= (Nothing :: Maybe String)
        ]
      -- The token never appears in the recorded JSON (encoded as string).
      let recordedStr = T.pack (show (orRecorded result))
      "GH_TOKEN" `T.isInfixOf` recordedStr `shouldBe` False
      "ghp_FAKE_TOKEN_12345" `T.isInfixOf` recordedStr `shouldBe` False

----------------------------------------------------------------------------
-- QuickCheck helper (top-level — avoids where-clause layout issues)
----------------------------------------------------------------------------

-- | Check whether the argv contains any -R/--repo flag (any of the 4
-- cobra/pflag forms). Used by the QuickCheck property to verify
-- extractGhRepoFlag returns Nothing IFF no flag is present.
hasAnyRepoFlag :: [Text] -> Bool
hasAnyRepoFlag = go
  where
    go [] = False
    go (x : xs)
      | x == "-R" = case xs of
          (_ : _) -> True
          []      -> False
      | "-R" `T.isPrefixOf` x
      , x /= "-R"
      = True
      | x == "--repo" = case xs of
          (_ : _) -> True
          []      -> False
      | "--repo=" `T.isPrefixOf` x
      = True
      | otherwise = go xs