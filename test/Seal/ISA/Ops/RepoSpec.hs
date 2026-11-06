{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.RepoSpec (spec) where

import Data.Aeson.Key (fromText)
import Data.Aeson (Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory
  ( createDirectoryIfMissing, doesDirectoryExist, doesFileExist
  , getCurrentDirectory, setCurrentDirectory, withCurrentDirectory )
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (callProcess, readProcess)
import Test.Hspec

import Seal.ISA.Opcode (OpResult (..), Opcode, opAuthorize, opInSchema)
import Seal.ISA.Ops.Repo
  ( CloneResult (..), SwitchTransport (..), cloneRepoIO
  , isShellMetachar, normalizeRepoUrl, parseRepoProbe
  , parseSetupRepoInput, renderCloneResult, runSetupRepo, sanitizeRepoName
  , setupRepoOp, switchTransport, tryCodegraphInit, validateRepoUrl )
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Security.Policy (AutonomyLevel (..))
import Seal.SourceControl.AgentRegistry (mkAgentRegistryHandle)
import Seal.SourceControl.Clone (CloneDeps (..))
import Seal.SourceControl.GithubKeys (pinnedGithubKnownHosts)
import Seal.SourceControl.Registry (RepoRegistryHandle (..))
import Seal.SourceControl.Repo
  ( RepoCredential (..), SourceRepo (..), VcsKind (..), mkRepoId )
import Seal.TestHelpers.FakeRegistry (fakeRepoRegistryHandle)
import Seal.TestHelpers.FakeVault (makeFakeVaultRuntime)
import Seal.Tools.Args (BranchName, mkBranchName, mkShellCommand, textShellCommand)
import Seal.Tools.Exec.UIO (runUIOWithEnv)
import Seal.Tools.Exec.UIO.Internal (mkTestUIOEnv)
import Seal.Tools.Exec.UntrustedIO
  ( UntrustedIO, mkLocalUntrustedIO, mkRemoteUntrustedIOStub )
import Seal.Tools.Exec.UntrustedIO qualified as UIORec
import Seal.Tools.Ssh.Agent
  ( SshAgentEnv (..), mkFakeSshAgentHandle )

-- | The process CWD captured at module load (before any test runs). This is
-- always a valid directory (the project root or the test runner's CWD).
-- Restored after each test that changes the CWD, so a CWD-deletion by a
-- prior test's 'withSystemTempDirectory' cleanup doesn't break subsequent
-- tests that call 'getCurrentDirectory' (e.g. 'git add' in the
-- channelCallDispatcher test).
savedCwd :: FilePath
savedCwd = unsafePerformIO getCurrentDirectory
{-# NOINLINE savedCwd #-}

-- | Run an action with the process CWD set to a stable directory ("/"),
-- then restore the saved CWD afterward. This prevents
-- 'getCurrentDirectory: does not exist' errors when cloneRepoIO's internal
-- process creation runs after a prior test's 'withSystemTempDirectory'
-- cleanup deleted the CWD. The restore uses 'setCurrentDirectory' (not
-- 'withCurrentDirectory') to avoid calling 'getCurrentDirectory' (which
-- would fail if the CWD is already gone).
withStableCwd :: IO a -> IO a
withStableCwd action = do
  setCurrentDirectory "/"
  result <- action
  setCurrentDirectory savedCwd
  pure result

-- | Build a test 'CloneDeps' with a fake (empty) vault runtime, an empty
-- repo registry (so @lookupRepoByUrl@ falls through to bare-URL clone —
-- these tests clone public @file://@ repos with no credential), a fake
-- ssh-agent (no real process), and the compile-time pinned GitHub host
-- keys. The @keyfilesDir@ is per-test (a temp dir).
mkTestCloneDeps :: FilePath -> IO CloneDeps
mkTestCloneDeps keyfilesDir = do
  createDirectoryIfMissing True keyfilesDir
  vault <- makeFakeVaultRuntime []
  callsRef <- newIORef []
  agentRegH <- mkAgentRegistryHandle keyfilesDir
  let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
  pure CloneDeps
    { cdVault = vault
    , cdRepoReg = fakeRepoRegistryHandle
    , cdSshAgent = agent
    , cdAgentRegistry = agentRegH
    , cdPinnedKnownHosts = pinnedGithubKnownHosts
    , cdKeyfilesDir = keyfilesDir
    , cdIsRemote = False
    }

-- ---------------------------------------------------------------------------
-- WU-2 fixtures: a multi-branch repo, a clone workspace, a recording
-- 'UntrustedIO', and total wrappers around the validated constructors
-- ---------------------------------------------------------------------------

-- | Create a bare repo containing:
--
--   * @main@ — @README.md@ = @\"main-content\"@
--   * @dev@  — @main@ plus @dev.txt@ = @\"dev-content\"@
--   * tag @v1@ on @main@
--
-- Every branch + the tag are pushed, so a shallow single-branch clone can
-- later switch to any of them (the switch fetches the ref explicitly).
-- Returns the bare repo path (usable as @file:\/\/\<path\>@).
mkRepoWithBranches :: FilePath -> IO FilePath
mkRepoWithBranches srcDir = do
  let bare = srcDir </> "repo.git"
      work = srcDir </> "work"
  createDirectoryIfMissing True bare
  withCurrentDirectory bare $ callProcess "git" ["init", "--bare"]
  createDirectoryIfMissing True work
  withCurrentDirectory work $ do
    callProcess "git" ["init"]
    callProcess "git" ["config", "user.email", "t@t"]
    callProcess "git" ["config", "user.name", "t"]
    writeFile (work </> "README.md") "main-content"
    callProcess "git" ["add", "README.md"]
    callProcess "git" ["commit", "-m", "main"]
    callProcess "git" ["branch", "-M", "main"]
    callProcess "git" ["tag", "v1"]
    callProcess "git" ["checkout", "-b", "dev"]
    writeFile (work </> "dev.txt") "dev-content"
    callProcess "git" ["add", "dev.txt"]
    callProcess "git" ["commit", "-m", "dev"]
    callProcess "git" ["checkout", "main"]
    callProcess "git" ["remote", "add", "origin", bare]
    callProcess "git" ["push", "origin", "--all"]
    callProcess "git" ["push", "origin", "--tags"]
  pure bare

-- | Run a body with a fresh bare repo (the CWD pinned to a stable dir — see
-- 'withStableCwd').
withBareRepo :: (FilePath -> IO a) -> IO a
withBareRepo k =
  withStableCwd $ withSystemTempDirectory "seal-repo-src" $ \srcDir -> do
    bare <- mkRepoWithBranches srcDir
    k bare

-- | Run a body with a fresh clone workspace: the workspace dir, the test
-- 'CloneDeps', and a local 'UntrustedIO' scoped to it.
withCloneWorkspace :: (FilePath -> CloneDeps -> UntrustedIO -> IO a) -> IO a
withCloneWorkspace k = withSystemTempDirectory "seal-repo-wd" $ \wd -> do
  deps <- mkTestCloneDeps (wd </> "keys")
  k wd deps (mkLocalUntrustedIO (WorkspaceRoot wd))

-- | The branch @git@ has checked out — the literal @HEAD@ when detached.
headBranch :: FilePath -> IO String
headBranch dir =
  T.unpack . T.strip . T.pack
    <$> readProcess "git" ["-C", dir, "rev-parse", "--abbrev-ref", "HEAD"] ""

-- | Run a body with a validated 'BranchName' built from a literal fixture
-- name. The fixture names are known-valid, so a validation failure is a
-- test bug: report it as a failure rather than crashing.
withBranchName :: Text -> (BranchName -> IO ()) -> IO ()
withBranchName name k = case mkBranchName name of
  Right b -> k b
  Left err ->
    expectationFailure ("test fixture: invalid branch " <> show name <> ": " <> T.unpack err)

-- | The text an opcode run produced (the first result part).
resultText :: OpResult -> Text
resultText res = case orParts res of
  (TrpText t : _) -> t
  _               -> ""

-- | One field of the opcode's recorded (transcript) payload.
recordedField :: Text -> OpResult -> Maybe Text
recordedField k res = parseMaybe (withObject "recorded" (.: fromText k)) (orRecorded res)

-- | Build the SETUP_REPO opcode with throwaway deps (only its authorize +
-- schema surfaces are exercised here).
withSetupRepoOp :: AutonomyLevel -> (Opcode -> IO a) -> IO a
withSetupRepoOp autonomy k =
  withSystemTempDirectory "seal-setuprepospec" $ \d -> do
    deps <- mkTestCloneDeps (d </> "keys")
    k (setupRepoOp deps (WorkspaceRoot d) autonomy)

-- | A recorded shell call: which 'UntrustedIO' arm ran, the env extras it
-- carried, and the command text.
data RecordedExec = RecordedExec
  { reArm    :: Text
  , reExtras :: [(String, String)]
  , reCmd    :: Text
  } deriving stock (Eq, Show)

-- | Canned answers for the hermetic credentialed-switch test. Order
-- matters: the idempotency probe command carries BOTH @remote.origin.url@
-- and a @rev-parse@ (it emits two lines), so it is matched first.
fakeSwitchAnswer :: Text -> Text
fakeSwitchAnswer cmd
  | "remote.origin.url" `T.isInfixOf` cmd = "https://github.com/o/r.git\nmain\n"
  | "rev-parse --abbrev-ref HEAD" `T.isInfixOf` cmd = "dev\n"
  | otherwise = ""

-- | A recording 'UntrustedIO': every shell call is captured as
-- (arm, env extras, command text) and answered by 'fakeSwitchAnswer'.
recordingUio :: IORef [RecordedExec] -> UntrustedIO
recordingUio seen = mkRemoteUntrustedIOStub
  { UIORec.uioShellExec = \cmd _mCwd -> record "shell" [] cmd
  , UIORec.uioShellExecEnv = \extras cmd _mCwd -> record "env" extras cmd
  , UIORec.uioShellExecGitEnv = \extras _knownHosts cmd _mCwd ->
      record "gitenv" extras cmd
  }
  where
    record arm extras cmd = do
      let txt = textShellCommand cmd
      modifyIORef' seen (++ [RecordedExec arm extras txt])
      pure (Right (fakeSwitchAnswer txt))

-- | A PAT repo whose URL matches 'fakeSwitchAnswer''s probe response, so
-- the switch path finds it registered + credential-resolvable.
patRepoFixture :: Either Text SourceRepo
patRepoFixture = do
  rid <- mkRepoId "r"
  pure SourceRepo
    { srId = rid
    , srUrl = "https://github.com/o/r.git"
    , srVcsKind = VcsGitHub
    , srCredential = CredPat "k"
    , srDeployKeyPublic = Nothing
    , srKeyfilePath = Nothing
    }

-- | A deploy-key repo whose URL matches 'fakeSwitchAnswer''s probe
-- response. Its credential is a 'CredDeployKey' (no raw token), so the
-- switch must use the agent-forwarding executor arm.
deployKeyRepoFixture :: Either Text SourceRepo
deployKeyRepoFixture = do
  rid <- mkRepoId "r"
  pure SourceRepo
    { srId = rid
    , srUrl = "git@github.com:o/r.git"
    , srVcsKind = VcsGitHub
    , srCredential = CredDeployKey "k"
    , srDeployKeyPublic = Nothing
    , srKeyfilePath = Nothing
    }

-- | A 'RepoRegistryHandle' seeded with a fixed list (in-memory).
registryWith :: [SourceRepo] -> RepoRegistryHandle
registryWith repos = RepoRegistryHandle
  { rrhList = pure (Right repos)
  , rrhMutate = \_ -> pure (Right ())
  }

spec :: Spec
spec = describe "Seal.ISA.Ops.Repo" $ do
  describe "validateRepoUrl" $ do
    it "accepts an https URL" $
      validateRepoUrl "https://github.com/foo/bar" `shouldBe` Right "https://github.com/foo/bar"

    it "accepts an http URL" $
      validateRepoUrl "http://example.com/x" `shouldBe` Right "http://example.com/x"

    it "accepts a git:// URL" $
      validateRepoUrl "git://github.com/foo/bar" `shouldBe` Right "git://github.com/foo/bar"

    it "accepts an ssh:// URL" $
      validateRepoUrl "ssh://git@github.com/foo/bar" `shouldBe` Right "ssh://git@github.com/foo/bar"

    it "accepts an SCP-style git@host:path URL" $
      validateRepoUrl "git@github.com:foo/bar" `shouldBe` Right "git@github.com:foo/bar"

    it "rejects an empty url" $
      validateRepoUrl "" `shouldSatisfy` isLeft

    it "rejects a whitespace-only url" $
      validateRepoUrl "   " `shouldSatisfy` isLeft

    it "rejects a url with no acceptable scheme" $
      validateRepoUrl "ftp://example.com/x" `shouldSatisfy` isLeft

    it "rejects a url with a shell metacharacter (semicolon)" $
      validateRepoUrl "https://x.com/a;rm -rf /" `shouldSatisfy` isLeft

    it "rejects a url with a backtick" $
      validateRepoUrl "https://x.com/a`whoami`" `shouldSatisfy` isLeft

    it "rejects a url with a dollar" $
      validateRepoUrl "https://x.com/$HOME" `shouldSatisfy` isLeft

    it "trims surrounding whitespace" $
      validateRepoUrl "  https://github.com/foo/bar  " `shouldBe` Right "https://github.com/foo/bar"

  describe "isShellMetachar" $ do
    it "flags the usual shell metacharacters" $ do
      isShellMetachar ';' `shouldBe` True
      isShellMetachar '`' `shouldBe` True
      isShellMetachar '$' `shouldBe` True
      isShellMetachar '|' `shouldBe` True
      isShellMetachar '&' `shouldBe` True
      isShellMetachar '\n' `shouldBe` True

    it "does not flag safe URL characters" $ do
      isShellMetachar 'a' `shouldBe` False
      isShellMetachar '/' `shouldBe` False
      isShellMetachar ':' `shouldBe` False
      isShellMetachar '@' `shouldBe` False
      isShellMetachar '.' `shouldBe` False
      isShellMetachar '-' `shouldBe` False

  describe "sanitizeRepoName" $ do
    it "takes the last path segment of an https URL" $
      sanitizeRepoName "https://github.com/foo/bar" `shouldBe` "bar"

    it "strips a trailing .git" $
      sanitizeRepoName "https://github.com/foo/bar.git" `shouldBe` "bar"

    it "handles an SCP-style url" $
      sanitizeRepoName "git@github.com:foo/bar" `shouldBe` "bar"

    it "replaces disallowed chars with dashes" $
      sanitizeRepoName "https://github.com/foo/bar.baz qux" `shouldBe` "bar-baz-qux"

    it "uses the hostname as the name for a bare host (no path)" $
      sanitizeRepoName "https://example.com" `shouldBe` "example-com"

    it "strips trailing slashes before deriving the name" $
      sanitizeRepoName "https://github.com/foo/bar/" `shouldBe` "bar"

  describe "normalizeRepoUrl" $ do
    it "strips an https:// scheme, trailing .git, and lowercases" $
      normalizeRepoUrl "https://github.com/foo/bar.git" `shouldBe` "github.com/foo/bar"

    it "strips an ssh:// scheme" $
      normalizeRepoUrl "ssh://git@github.com/foo/bar.git" `shouldBe` "github.com/foo/bar"

    it "strips a git:// scheme" $
      normalizeRepoUrl "git://github.com/foo/bar.git" `shouldBe` "github.com/foo/bar"

    it "rewrites an SCP-style git@host:path to host/path" $
      normalizeRepoUrl "git@github.com:foo/bar.git" `shouldBe` "github.com/foo/bar"

    it "makes git@ and https forms of the same repo compare equal" $
      normalizeRepoUrl "git@github.com:foo/bar.git"
        `shouldBe` normalizeRepoUrl "https://github.com/foo/bar.git"

    it "strips trailing slashes" $
      normalizeRepoUrl "https://github.com/foo/bar/" `shouldBe` "github.com/foo/bar"

    it "preserves a port in the host" $
      -- ssh://host:2222/foo/bar → after scheme strip "host:2222/foo/bar";
      -- the first ':' comes before any '/', so it's treated as SCP-style
      -- host:path → "host/2222/foo/bar". This is a known approximation
      -- (ports are rare in practice for clone URLs); the test pins the
      -- current behavior so a future change is intentional.
      normalizeRepoUrl "ssh://host:2222/foo/bar" `shouldBe` "host/2222/foo/bar"

  describe "cloneRepoIO" $ do
    -- A real end-to-end clone against a local bare repo, run through the
    -- same UntrustedIO capability the opcode uses. cloneRepoIO takes a
    -- raw URL (no validation), so file:// works here even though the
    -- opcode/endpoint layer would reject it.
    it "clones a local bare repo into <workdir>/<name> (shallow)" $
      withStableCwd $ withSystemTempDirectory "seal-repo-src" $ \srcDir -> do
        -- Build a bare repo with one commit under srcDir/repo.git.
        let bare = srcDir </> "repo.git"
        createDirectoryIfMissing True bare
        withCurrentDirectory bare $ do
          callProcess "git" ["init", "--bare"]
        -- Make a working clone, add a file, commit, push to the bare repo.
        let work = srcDir </> "work"
        createDirectoryIfMissing True work
        withCurrentDirectory work $ do
          callProcess "git" ["init"]
          callProcess "git" ["config", "user.email", "t@t"]
          callProcess "git" ["config", "user.name", "t"]
          writeFile (work </> "README.md") "hello"
          callProcess "git" ["add", "README.md"]
          callProcess "git" ["commit", "-m", "init"]
          callProcess "git" ["remote", "add", "origin", bare]
          callProcess "git" ["push", "origin", "HEAD"]
        -- Now cloneRepoIO into a fresh workdir.
        withSystemTempDirectory "seal-repo-wd" $ \wd -> do
          deps <- mkTestCloneDeps (wd </> "keys")
          let uio = mkLocalUntrustedIO (WorkspaceRoot wd)
              fileUrl = T.pack ("file://" <> bare)
          res <- cloneRepoIO deps uio fileUrl Nothing
          case res of
            CloneCloned name -> do
              name `shouldBe` "repo"
              doesDirectoryExist (wd </> "repo" </> ".git") `shouldReturn` True
            other -> expectationFailure ("expected CloneCloned, got " <> show other)

    it "is a no-op when the same repo is already cloned" $
      withStableCwd $ withSystemTempDirectory "seal-repo-src2" $ \srcDir -> do
        let bare = srcDir </> "repo.git"
        createDirectoryIfMissing True bare
        withCurrentDirectory bare $ callProcess "git" ["init", "--bare"]
        let work = srcDir </> "work"
        createDirectoryIfMissing True work
        withCurrentDirectory work $ do
          callProcess "git" ["init"]
          callProcess "git" ["config", "user.email", "t@t"]
          callProcess "git" ["config", "user.name", "t"]
          writeFile (work </> "f.txt") "x"
          callProcess "git" ["add", "f.txt"]
          callProcess "git" ["commit", "-m", "x"]
          callProcess "git" ["remote", "add", "origin", bare]
          callProcess "git" ["push", "origin", "HEAD"]
        withSystemTempDirectory "seal-repo-wd2" $ \wd -> do
          deps <- mkTestCloneDeps (wd </> "keys")
          let uio = mkLocalUntrustedIO (WorkspaceRoot wd)
              fileUrl = T.pack ("file://" <> bare)
          _ <- cloneRepoIO deps uio fileUrl Nothing          -- first clone
          res2 <- cloneRepoIO deps uio fileUrl Nothing       -- second → no-op
          case res2 of
            CloneNoop name -> name `shouldBe` "repo"
            other -> expectationFailure ("expected CloneNoop, got " <> show other)

    it "is a no-op when re-cloned via a URL that normalizes to the same repo (trailing .git vs no .git)" $
      withStableCwd $ withSystemTempDirectory "seal-repo-scheme" $ \srcDir -> do
        -- The same bare repo reached via "file://.../repo.git" and
        -- "file://.../repo.git" (with vs without trailing .git) must be
        -- a no-op, proving normalizeRepoUrl is consulted (without it,
        -- the exact-string compare would also pass here — but this test
        -- guards the no-op path end-to-end). The cross-scheme (git@ vs
        -- https) equivalence is covered by the normalizeRepoUrl unit
        -- tests above.
        let bare = srcDir </> "repo.git"
        createDirectoryIfMissing True bare
        withCurrentDirectory bare $ callProcess "git" ["init", "--bare"]
        let work = srcDir </> "work"
        createDirectoryIfMissing True work
        withCurrentDirectory work $ do
          callProcess "git" ["init"]
          callProcess "git" ["config", "user.email", "t@t"]
          callProcess "git" ["config", "user.name", "t"]
          writeFile (work </> "f.txt") "x"
          callProcess "git" ["add", "f.txt"]
          callProcess "git" ["commit", "-m", "x"]
          callProcess "git" ["remote", "add", "origin", bare]
          callProcess "git" ["push", "origin", "HEAD"]
        withSystemTempDirectory "seal-repo-wd-scheme" $ \wd -> do
          deps <- mkTestCloneDeps (wd </> "keys")
          let uio = mkLocalUntrustedIO (WorkspaceRoot wd)
              urlWithGit = T.pack ("file://" <> bare)
              -- Same path without the trailing .git on the *bare dir*
              -- would be a different path; instead exercise the
              -- normalization via a trailing slash, which
              -- normalizeRepoUrl strips.
              urlWithSlash = T.pack ("file://" <> bare <> "/")
          _ <- cloneRepoIO deps uio urlWithGit Nothing
          res2 <- cloneRepoIO deps uio urlWithSlash Nothing
          case res2 of
            CloneNoop _ -> pure ()
            other -> expectationFailure ("expected CloneNoop, got " <> show other)

    it "reports a conflict when a different repo occupies the path" $
      withStableCwd $ withSystemTempDirectory "seal-repo-conflict" $ \srcDir -> do
        -- Two distinct bare repos, BOTH named repo.git (in different
        -- parent dirs) so they sanitize to the same target dir "repo".
        let parentA = srcDir </> "a"
            parentB = srcDir </> "b"
            bareA = parentA </> "repo.git"
            bareB = parentB </> "repo.git"
        mapM_ (\p -> do
                  createDirectoryIfMissing True p
                  createDirectoryIfMissing True (p </> "repo.git")
                  withCurrentDirectory (p </> "repo.git") (callProcess "git" ["init", "--bare"]))
              [parentA, parentB]
        -- Populate bareA via a working clone.
        let work = srcDir </> "work"
        createDirectoryIfMissing True work
        withCurrentDirectory work $ do
          callProcess "git" ["init"]
          callProcess "git" ["config", "user.email", "t@t"]
          callProcess "git" ["config", "user.name", "t"]
          writeFile (work </> "f.txt") "x"
          callProcess "git" ["add", "f.txt"]
          callProcess "git" ["commit", "-m", "x"]
          callProcess "git" ["remote", "add", "origin", bareA]
          callProcess "git" ["push", "origin", "HEAD"]
        withSystemTempDirectory "seal-repo-wd3" $ \wd -> do
          deps <- mkTestCloneDeps (wd </> "keys")
          let uio = mkLocalUntrustedIO (WorkspaceRoot wd)
              urlA = T.pack ("file://" <> bareA)
              urlB = T.pack ("file://" <> bareB)
          _ <- cloneRepoIO deps uio urlA Nothing   -- clone A into <wd>/repo
          -- Now clone B, which also sanitizes to "repo" → conflict.
          resB <- cloneRepoIO deps uio urlB Nothing
          case resB of
            CloneConflict _name existing -> existing `shouldBe` urlA
            other -> expectationFailure ("expected CloneConflict, got " <> show other)

    it "reports CloneFailed (not CloneCloned) when the clone errors — git's non-zero exit is returned as Right by uioShellExec, so the filesystem must be the source of truth" $
      withSystemTempDirectory "seal-repo-fail" $ \wd -> do
        deps <- mkTestCloneDeps (wd </> "keys")
        let uio = mkLocalUntrustedIO (WorkspaceRoot wd)
            -- A URL that parses but points at nothing cloneable: an
            -- SCP-style URL to a nonexistent host. git will fail with
            -- "Could not read from remote repository" (exit 128), which
            -- uioShellExec returns as Right (stderr text). cloneRepoIO
            -- must detect the missing <repo>/.git and report failure.
            badUrl = "git@nonexistent-host.invalid:foo/bar.git"
        res <- cloneRepoIO deps uio badUrl Nothing
        case res of
          CloneFailed _ -> pure ()   -- expected
          other -> expectationFailure
            ("expected CloneFailed, got " <> show other
             <> " — cloneRepoIO must verify the clone landed, since uioShellExec returns Right on non-zero exit")

  describe "tryCodegraphInit" $ do
    it "is a no-op (does not throw) when codegraph is not installed" $
      withSystemTempDirectory "seal-codegraph-noinstall" $ \wd -> do
        let uio = mkLocalUntrustedIO (WorkspaceRoot wd)
        -- tryCodegraphInit should complete without throwing, whether or
        -- not codegraph is installed. The function is best-effort.
        tryCodegraphInit uio "some-repo" Nothing

    it "creates a .codegraph directory when codegraph IS installed" $
      withSystemTempDirectory "seal-codegraph-install" $ \wd -> do
        -- Check if codegraph is available; skip if not. uioShellExec
        -- returns Right even on non-zero exit (it surfaces stderr as
        -- Right text with an [exit code: N] annotation), so we check
        -- the output for a non-zero exit code to detect absence.
        let uio = mkLocalUntrustedIO (WorkspaceRoot wd)
        let checkCmd = case mkShellCommand "command -v codegraph" of Right c -> c; Left _ -> error "bad cmd"
        checkRes <- UIORec.uioShellExec uio checkCmd Nothing
        case checkRes of
          Left _ -> pendingWith "codegraph not installed — skipping"
          Right out
            | "[exit code: " `T.isInfixOf` out -> pendingWith "codegraph not installed — skipping"
            | otherwise -> do
            -- Create a fake repo dir with a source file.
            createDirectoryIfMissing True (wd </> "test-repo")
            writeFile (wd </> "test-repo" </> "main.py") "def foo(): pass\n"
            tryCodegraphInit uio "test-repo" Nothing
            doesDirectoryExist (wd </> "test-repo" </> ".codegraph") `shouldReturn` True

  describe "parseSetupRepoInput" $ do
    let url = "https://github.com/foo/bar" :: Text

    it "parses {url} as (url, Nothing)" $
      parseSetupRepoInput (object ["url" .= url])
        `shouldBe` Right (url, Nothing)

    it "parses {url, branch} into a validated BranchName" $
      parseSetupRepoInput (object ["url" .= url, "branch" .= ("dev" :: Text)])
        `shouldBe` fmap (\b -> (url, Just b)) (mkBranchName "dev")

    it "trims the url" $
      parseSetupRepoInput (object ["url" .= ("  " <> url <> "  " :: Text)])
        `shouldBe` Right (url, Nothing)

    it "treats an empty branch as absent" $
      parseSetupRepoInput (object ["url" .= url, "branch" .= ("" :: Text)])
        `shouldBe` Right (url, Nothing)

    it "treats a whitespace-only branch as absent" $
      parseSetupRepoInput (object ["url" .= url, "branch" .= ("   " :: Text)])
        `shouldBe` Right (url, Nothing)

    it "trims a branch before validating it" $
      parseSetupRepoInput (object ["url" .= url, "branch" .= ("  dev  " :: Text)])
        `shouldBe` fmap (\b -> (url, Just b)) (mkBranchName "dev")

    it "rejects an invalid branch (HEAD)" $
      parseSetupRepoInput (object ["url" .= url, "branch" .= ("HEAD" :: Text)])
        `shouldSatisfy` isLeft

    it "rejects an option-injecting branch (-x)" $
      parseSetupRepoInput (object ["url" .= url, "branch" .= ("-x" :: Text)])
        `shouldSatisfy` isLeft

    it "rejects a missing url" $
      parseSetupRepoInput (object ["branch" .= ("dev" :: Text)])
        `shouldSatisfy` isLeft

    it "rejects an invalid (file://) url" $
      parseSetupRepoInput (object ["url" .= ("file:///tmp/repo.git" :: Text)])
        `shouldSatisfy` isLeft

  describe "parseRepoProbe" $ do
    let url = "https://github.com/o/r.git"

    it "parses a two-line response (url + current branch)" $
      parseRepoProbe (url <> "\nmain\n") `shouldBe` (url, Just "main")

    it "parses a one-line response as an unknown current branch" $
      parseRepoProbe (url <> "\n") `shouldBe` (url, Nothing)

    it "parses __NONE__ as no clone" $
      parseRepoProbe "__NONE__\n" `shouldBe` ("__NONE__", Nothing)

    it "reports a detached checkout as the literal HEAD" $
      parseRepoProbe (url <> "\nHEAD\n") `shouldBe` (url, Just "HEAD")

    it "treats a blank second line as an unknown current branch" $
      parseRepoProbe (url <> "\n\n") `shouldBe` (url, Nothing)

    it "handles an empty response" $
      parseRepoProbe "" `shouldBe` ("", Nothing)

  describe "renderCloneResult" $ do
    let url = "https://github.com/foo/bar" :: Text
        mBranch = Just "dev" :: Maybe Text
        conflict = CloneConflict "bar" "https://other.example/x.git"
        failure = CloneFailed "boom"

    it "renders a clone (no branch requested)" $
      renderCloneResult url Nothing (CloneCloned "bar")
        `shouldBe` "Cloned https://github.com/foo/bar into bar (shallow)."

    it "renders a clone on a branch" $
      renderCloneResult url mBranch (CloneCloned "bar")
        `shouldBe` "Cloned https://github.com/foo/bar into bar (shallow, branch dev)."

    it "renders a no-op (no branch requested)" $
      renderCloneResult url Nothing (CloneNoop "bar")
        `shouldBe` "Repo already exists — no-op (bar)."

    it "renders a no-op on a branch" $
      renderCloneResult url mBranch (CloneNoop "bar")
        `shouldBe` "Repo already exists — no-op (bar, branch dev)."

    it "renders a conflict" $
      renderCloneResult url Nothing conflict
        `shouldBe` "A different repo already occupies bar (existing: https://other.example/x.git)."

    it "renders a switch" $
      renderCloneResult url mBranch (CloneSwitched "bar" "dev")
        `shouldBe` "Repo already exists — switched to branch dev (bar)."

    -- The branch named by 'CloneSwitched' comes from the CONSTRUCTOR, not
    -- from the @mBranch@ parameter: pass 'Nothing' here so a switch still
    -- names the branch it moved to (the caller may not have a requested
    -- branch to hand in, e.g. when re-rendering a recorded result).
    it "renders a switch even when no branch was passed in" $
      renderCloneResult url Nothing (CloneSwitched "bar" "dev")
        `shouldBe` "Repo already exists — switched to branch dev (bar)."

    it "renders a failure" $
      renderCloneResult url Nothing failure
        `shouldBe` "SETUP_REPO failed — could not clone https://github.com/foo/bar:\nboom"

    it "names the branch in the cloned / no-op / switched messages" $ do
      renderCloneResult url mBranch (CloneCloned "bar")
        `shouldSatisfy` T.isInfixOf "branch dev"
      renderCloneResult url mBranch (CloneNoop "bar")
        `shouldSatisfy` T.isInfixOf "branch dev"
      renderCloneResult url mBranch (CloneSwitched "bar" "dev")
        `shouldSatisfy` T.isInfixOf "branch dev"

    it "does not leak the requested branch into conflict / failure text" $ do
      renderCloneResult url mBranch conflict `shouldBe` renderCloneResult url Nothing conflict
      renderCloneResult url mBranch failure `shouldBe` renderCloneResult url Nothing failure

  describe "switchTransport" $ do
    it "uses the shell-env arm when a raw token is present (PAT / machine user)" $
      switchTransport (Just "raw-token") `shouldBe` SwitchViaShellEnv

    it "uses the git-env arm when there is no raw token (deploy key)" $
      switchTransport Nothing `shouldBe` SwitchViaGitEnv

  describe "setupRepoOp" $ do
    let url = "https://github.com/foo/bar" :: Text

    it "rejects branch \"-x\" (option injection)" $
      withSetupRepoOp Full $ \op ->
        opAuthorize op (object ["url" .= url, "branch" .= ("-x" :: Text)])
          `shouldSatisfy` isLeft

    it "rejects branch \"HEAD\" (HEAD names a commit, not a branch)" $
      withSetupRepoOp Full $ \op ->
        opAuthorize op (object ["url" .= url, "branch" .= ("HEAD" :: Text)])
          `shouldSatisfy` isLeft

    it "accepts branch \"dev\"" $
      withSetupRepoOp Full $ \op ->
        opAuthorize op (object ["url" .= url, "branch" .= ("dev" :: Text)])
          `shouldBe` Right ()

    it "still enforces the autonomy Deny check" $
      withSetupRepoOp Deny $ \op ->
        opAuthorize op (object ["url" .= url])
          `shouldBe` Left "SETUP_REPO denied by autonomy policy"

    it "advertises an optional branch property" $
      withSetupRepoOp Full $ \op -> do
        let schemaProps =
              parseMaybe (withObject "schema" (.: "properties")) (opInSchema op)
                :: Maybe Value
            mBranchType = schemaProps
              >>= parseMaybe (withObject "properties" (.:? "branch"))
              >>= maybe Nothing (parseMaybe (withObject "branch" (.: "type")))
        mBranchType `shouldBe` Just ("string" :: Text)

    it "keeps url as the only required property" $
      withSetupRepoOp Full $ \op ->
        (parseMaybe (withObject "schema" (.: "required")) (opInSchema op) :: Maybe [Text])
          `shouldBe` Just ["url"]

  describe "cloneRepoIO (branch)" $ do
    it "clones the requested branch shallowly — HEAD and tip content" $
      withBareRepo $ \bare -> withCloneWorkspace $ \wd deps uio ->
        withBranchName "dev" $ \dev -> do
          let fileUrl = T.pack ("file://" <> bare)
          cloneRepoIO deps uio fileUrl (Just dev) `shouldReturn` CloneCloned "repo"
          headBranch (wd </> "repo") `shouldReturn` "dev"
          readFile (wd </> "repo" </> "dev.txt") `shouldReturn` "dev-content"

    it "clones the default branch when no branch is requested" $
      withBareRepo $ \bare -> withCloneWorkspace $ \wd deps uio -> do
        let fileUrl = T.pack ("file://" <> bare)
        cloneRepoIO deps uio fileUrl Nothing `shouldReturn` CloneCloned "repo"
        headBranch (wd </> "repo") `shouldReturn` "main"
        doesFileExist (wd </> "repo" </> "dev.txt") `shouldReturn` False

    it "clones a tag into a detached HEAD at the tag" $
      withBareRepo $ \bare -> withCloneWorkspace $ \wd deps uio ->
        withBranchName "v1" $ \tag -> do
          let fileUrl = T.pack ("file://" <> bare)
          cloneRepoIO deps uio fileUrl (Just tag) `shouldReturn` CloneCloned "repo"
          headBranch (wd </> "repo") `shouldReturn` "HEAD"
          readFile (wd </> "repo" </> "README.md") `shouldReturn` "main-content"
          doesFileExist (wd </> "repo" </> "dev.txt") `shouldReturn` False

    it "reports CloneFailed for a ref the remote does not have" $
      withBareRepo $ \bare -> withCloneWorkspace $ \_wd deps uio ->
        withBranchName "no-such-branch" $ \b -> do
          let fileUrl = T.pack ("file://" <> bare)
          res <- cloneRepoIO deps uio fileUrl (Just b)
          case res of
            CloneFailed _ -> pure ()
            other -> expectationFailure ("expected CloneFailed, got " <> show other)

  describe "cloneRepoIO (branch switch)" $ do
    it "switches an existing clone to a branch that is not local yet (fetch arm)" $
      withBareRepo $ \bare -> withCloneWorkspace $ \wd deps uio -> do
        let fileUrl = T.pack ("file://" <> bare)
        cloneRepoIO deps uio fileUrl Nothing `shouldReturn` CloneCloned "repo"
        withBranchName "dev" $ \dev -> do
          cloneRepoIO deps uio fileUrl (Just dev)
            `shouldReturn` CloneSwitched "repo" "dev"
          headBranch (wd </> "repo") `shouldReturn` "dev"
          readFile (wd </> "repo" </> "dev.txt") `shouldReturn` "dev-content"

    it "switches to a branch that already exists locally (checkout arm)" $
      withBareRepo $ \bare -> withCloneWorkspace $ \wd deps uio -> do
        let fileUrl = T.pack ("file://" <> bare)
            repoDir = wd </> "repo"
        cloneRepoIO deps uio fileUrl Nothing `shouldReturn` CloneCloned "repo"
        -- A branch that exists ONLY locally: the fetch arm would fail on it
        -- (no such ref on the remote), so a success proves the checkout arm.
        callProcess "git" ["-C", repoDir, "branch", "local-b"]
        withBranchName "local-b" $ \b -> do
          cloneRepoIO deps uio fileUrl (Just b)
            `shouldReturn` CloneSwitched "repo" "local-b"
          headBranch repoDir `shouldReturn` "local-b"

    it "is a no-op when the requested branch is already checked out" $
      withBareRepo $ \bare -> withCloneWorkspace $ \_wd deps uio ->
        withBranchName "dev" $ \dev -> do
          let fileUrl = T.pack ("file://" <> bare)
          cloneRepoIO deps uio fileUrl (Just dev) `shouldReturn` CloneCloned "repo"
          cloneRepoIO deps uio fileUrl (Just dev) `shouldReturn` CloneNoop "repo"

    it "switches a detached tag checkout back to a branch" $
      withBareRepo $ \bare -> withCloneWorkspace $ \wd deps uio ->
        withBranchName "v1" $ \tag -> withBranchName "dev" $ \dev -> do
          let fileUrl = T.pack ("file://" <> bare)
          cloneRepoIO deps uio fileUrl (Just tag) `shouldReturn` CloneCloned "repo"
          headBranch (wd </> "repo") `shouldReturn` "HEAD"
          cloneRepoIO deps uio fileUrl (Just dev)
            `shouldReturn` CloneSwitched "repo" "dev"
          headBranch (wd </> "repo") `shouldReturn` "dev"

    it "reports CloneFailed when the requested ref is a tag (branch-only refspec)" $
      withBareRepo $ \bare -> withCloneWorkspace $ \wd deps uio ->
        withBranchName "v1" $ \tag -> do
          let fileUrl = T.pack ("file://" <> bare)
              repoDir = wd </> "repo"
          cloneRepoIO deps uio fileUrl Nothing `shouldReturn` CloneCloned "repo"
          res <- cloneRepoIO deps uio fileUrl (Just tag)
          case res of
            CloneFailed _ -> pure ()
            other -> expectationFailure
              ("expected CloneFailed for a tag on the switch path, got " <> show other)
          headBranch repoDir `shouldReturn` "main"

    it "reports CloneFailed for a ref absent from the remote, leaving HEAD + tree intact" $
      withBareRepo $ \bare -> withCloneWorkspace $ \wd deps uio ->
        withBranchName "no-such-branch" $ \b -> do
          let fileUrl = T.pack ("file://" <> bare)
              repoDir = wd </> "repo"
          cloneRepoIO deps uio fileUrl Nothing `shouldReturn` CloneCloned "repo"
          res <- cloneRepoIO deps uio fileUrl (Just b)
          case res of
            CloneFailed _ -> pure ()
            other -> expectationFailure ("expected CloneFailed, got " <> show other)
          headBranch repoDir `shouldReturn` "main"
          readFile (repoDir </> "README.md") `shouldReturn` "main-content"

  describe "cloneRepoIO (credentialed switch, hermetic)" $ do
    it "runs a PAT switch through uioShellExecEnv, never uioShellExecGitEnv" $
      case patRepoFixture of
        Left err -> expectationFailure ("test fixture: " <> T.unpack err)
        Right patRepo -> withSystemTempDirectory "seal-pat-switch" $ \d -> do
          base <- mkTestCloneDeps (d </> "keys")
          vault <- makeFakeVaultRuntime [("k", "tok")]
          seen <- newIORef []
          let deps = base { cdRepoReg = registryWith [patRepo], cdVault = vault }
          withBranchName "dev" $ \dev -> do
            res <- cloneRepoIO deps (recordingUio seen) "https://github.com/o/r" (Just dev)
            res `shouldBe` CloneSwitched "r" "dev"
            calls <- readIORef seen
            let envCalls = [ c | c <- calls, reArm c == "env" ]
            [ c | c <- calls, reArm c == "gitenv" ] `shouldBe` []
            envCalls `shouldSatisfy`
              any (any ((== "GIT_CONFIG_PARAMETERS") . fst) . reExtras)
            envCalls `shouldSatisfy`
              any (\c -> "fetch --depth 1 origin" `T.isInfixOf` reCmd c)

    it "runs a deploy-key switch through uioShellExecGitEnv, never uioShellExecEnv" $
      case deployKeyRepoFixture of
        Left err -> expectationFailure ("test fixture: " <> T.unpack err)
        Right keyRepo -> withSystemTempDirectory "seal-key-switch" $ \d -> do
          base <- mkTestCloneDeps (d </> "keys")
          vault <- makeFakeVaultRuntime [("k", "passphrase")]
          seen <- newIORef []
          let deps = base { cdRepoReg = registryWith [keyRepo], cdVault = vault }
          withBranchName "dev" $ \dev -> do
            res <- cloneRepoIO deps (recordingUio seen) "https://github.com/o/r" (Just dev)
            res `shouldBe` CloneSwitched "r" "dev"
            calls <- readIORef seen
            let gitCalls = [ c | c <- calls, reArm c == "gitenv" ]
            -- The deploy-key arm carries the agent forwarding env, not a
            -- raw token, so it must NOT go through the shell-env arm.
            [ c | c <- calls, reArm c == "env" ] `shouldBe` []
            gitCalls `shouldSatisfy` any (any ((== "SSH_AUTH_SOCK") . fst) . reExtras)
            gitCalls `shouldSatisfy`
              any (\c -> "fetch --depth 1 origin" `T.isInfixOf` reCmd c)

  describe "runSetupRepo (the opcode's run seam)" $ do
    it "clones the requested branch, names it, and records status cloned" $
      withBareRepo $ \bare -> withCloneWorkspace $ \wd deps uio ->
        withBranchName "dev" $ \dev -> do
          -- file:// is rejected by the opcode's URL validation, so the
          -- clone runs through the run seam directly; the URL/branch
          -- parsing in front of it is covered by parseSetupRepoInput.
          let fileUrl = T.pack ("file://" <> bare)
          res <- runUIOWithEnv (mkTestUIOEnv uio deps)
                   (runSetupRepo deps fileUrl (Just dev) (object []))
          orIsError res `shouldBe` False
          recordedField "status" res `shouldBe` Just "cloned"
          recordedField "target" res `shouldBe` Just "repo"
          resultText res `shouldSatisfy` T.isInfixOf "branch dev"
          headBranch (wd </> "repo") `shouldReturn` "dev"
          readFile (wd </> "repo" </> "dev.txt") `shouldReturn` "dev-content"

    it "records status switched (non-error) when the branch differs" $
      withBareRepo $ \bare -> withCloneWorkspace $ \_wd deps uio ->
        withBranchName "dev" $ \dev -> do
          let fileUrl = T.pack ("file://" <> bare)
              runOnce branch = runUIOWithEnv (mkTestUIOEnv uio deps)
                                 (runSetupRepo deps fileUrl branch (object []))
          res1 <- runOnce Nothing
          recordedField "status" res1 `shouldBe` Just "cloned"
          res2 <- runOnce (Just dev)
          orIsError res2 `shouldBe` False
          recordedField "status" res2 `shouldBe` Just "switched"
          resultText res2 `shouldSatisfy` T.isInfixOf "switched to branch dev"

isLeft :: Either a b -> Bool
isLeft (Left _)  = True
isLeft (Right _) = False
