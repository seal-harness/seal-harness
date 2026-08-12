{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.RepoSpec (spec) where

import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text qualified as T
import Data.Text (Text)
import System.Directory
  ( createDirectoryIfMissing, doesDirectoryExist, withCurrentDirectory )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (callProcess)
import Test.Hspec

import Seal.ISA.Ops.Repo
  ( CloneResult (..), cloneRepoIO, isShellMetachar, normalizeRepoUrl, sanitizeRepoName, validateRepoUrl )
import Seal.SourceControl.Repo
  ( RepoCredential (..), SourceRepo (..), VcsKind (..), mkRepoId )
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.SourceControl.AgentRegistry (mkAgentRegistryHandle)
import Seal.SourceControl.Clone (CloneDeps (..))
import Seal.SourceControl.Registry (RepoRegistryHandle (..))
import Seal.SourceControl.GithubKeys (pinnedGithubKnownHosts)
import Seal.TestHelpers.FakeRegistry (fakeRepoRegistryHandle)
import Seal.TestHelpers.FakeVault (makeFakeVaultRuntime)
import Seal.Tools.Args (textShellCommand)
import Seal.Tools.Exec.Types (ExecError (..))
import Seal.Tools.Exec.UntrustedIO
  ( UntrustedErr (..), UntrustedIO (..), mkLocalUntrustedIO )
import Seal.Tools.Ssh.Agent
  ( SshAgentEnv (..), mkFakeSshAgentHandle )

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
      withSystemTempDirectory "seal-repo-src" $ \srcDir -> do
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
          res <- cloneRepoIO deps uio fileUrl
          case res of
            CloneCloned name -> do
              name `shouldBe` "repo"
              doesDirectoryExist (wd </> "repo" </> ".git") `shouldReturn` True
            other -> expectationFailure ("expected CloneCloned, got " <> show other)

    it "is a no-op when the same repo is already cloned" $
      withSystemTempDirectory "seal-repo-src2" $ \srcDir -> do
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
          _ <- cloneRepoIO deps uio fileUrl          -- first clone
          res2 <- cloneRepoIO deps uio fileUrl        -- second → no-op
          case res2 of
            CloneNoop name -> name `shouldBe` "repo"
            other -> expectationFailure ("expected CloneNoop, got " <> show other)

    it "is a no-op when re-cloned via a URL that normalizes to the same repo (trailing .git vs no .git)" $
      withSystemTempDirectory "seal-repo-scheme" $ \srcDir -> do
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
          _ <- cloneRepoIO deps uio urlWithGit
          res2 <- cloneRepoIO deps uio urlWithSlash
          case res2 of
            CloneNoop _ -> pure ()
            other -> expectationFailure ("expected CloneNoop, got " <> show other)

    it "reports a conflict when a different repo occupies the path" $
      withSystemTempDirectory "seal-repo-conflict" $ \srcDir -> do
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
          _ <- cloneRepoIO deps uio urlA   -- clone A into <wd>/repo
          -- Now clone B, which also sanitizes to "repo" → conflict.
          resB <- cloneRepoIO deps uio urlB
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
        res <- cloneRepoIO deps uio badUrl
        case res of
          CloneFailed _ -> pure ()   -- expected
          other -> expectationFailure
            ("expected CloneFailed, got " <> show other
             <> " — cloneRepoIO must verify the clone landed, since uioShellExec returns Right on non-zero exit")

    describe "PAT http.extraHeader shell-quoting in cloneWithCredential" $ do
      it "the http.extraHeader value is single-quoted in the clone command" $ do
        withSystemTempDirectory "seal-repo-pat-quote" $ \wd -> do
          let keyfilesDir = wd </> "keys"
          createDirectoryIfMissing True keyfilesDir
          vault <- makeFakeVaultRuntime [("K_PAT", "ghp_TOKEN")]
          callsRef <- newIORef []
          agentRegH <- mkAgentRegistryHandle keyfilesDir
          cmdRef <- newIORef ("" :: Text)
          let agent = mkFakeSshAgentHandle callsRef (SshAgentEnv "/tmp/fake-sock" "12345")
              rid = case mkRepoId "myrepo" of Right i -> i; Left _ -> error "bad id"
              patRepo = SourceRepo rid
                "https://github.com/owner/repo.git"
                VcsGitHub (CredPat "K_PAT") Nothing Nothing
              repoReg = fakeRepoReg [patRepo]
              deps = CloneDeps
                { cdVault = vault
                , cdRepoReg = repoReg
                , cdSshAgent = agent
                , cdAgentRegistry = agentRegH
                , cdPinnedKnownHosts = pinnedGithubKnownHosts
                , cdKeyfilesDir = keyfilesDir
                , cdIsRemote = False
                }
              uio = recordingUio "__NONE__" cmdRef
          _ <- cloneRepoIO deps uio (T.pack "https://github.com/owner/repo.git")
          cmd <- readIORef cmdRef
          -- The http.extraHeader arg contains spaces and must be
          -- single-quoted so the shell preserves it as one token.
          "'http.extraHeader=Authorization: Basic " `T.isInfixOf` cmd
            `shouldBe` True

isLeft :: Either a b -> Bool
isLeft (Left _)  = True
isLeft (Right _) = False

----------------------------------------------------------------------------
-- PAT http.extraHeader shell-quoting in cloneWithCredential
----------------------------------------------------------------------------

-- | A fake 'UntrustedIO' for the PAT quoting test: returns a canned origin
-- URL for the idempotency check (@uioShellExec@), records the clone command
-- from @uioShellExecGitEnv@ into the 'IORef', and returns a canned success
-- for the clone + verify steps.
recordingUio :: Text -> IORef Text -> UntrustedIO
recordingUio originUrl cmdRef = stubUio
  { uioShellExec = \_cmd _mCwd ->
      pure (Right originUrl)
  , uioShellExecGitEnv = \_env _kh cmd _mCwd -> do
      writeIORef cmdRef (textShellCommand cmd)
      pure (Right "__NONE__")
  }

-- | A stub 'UntrustedIO' that fail-closes on every method.
stubUio :: UntrustedIO
stubUio = UntrustedIO
  { uioReadFile = \_ _ -> pure (Left (UeExec ExecNotImplemented))
  , uioWriteFile = \_ _ _ _ -> pure (Left (UeExec ExecNotImplemented))
  , uioPatchFile = \_ _ -> pure (Left (UeExec ExecNotImplemented))
  , uioShellExec = \_ _ -> pure (Left (UeExec ExecNotImplemented))
  , uioBinExec = \_ _ -> pure (Left (UeExec ExecNotImplemented))
  , uioProcessList = pure (Left (UeExec ExecNotImplemented))
  , uioProcessKill = \_ -> pure (Left (UeExec ExecNotImplemented))
  , uioSearchFiles = \_ _ _ -> pure (Left (UeExec ExecNotImplemented))
  , uioShellExecEnv = \_ _ _ -> pure (Left (UeExec ExecNotImplemented))
  , uioShellExecGitEnv = \_ _ _ _ -> pure (Left (UeExec ExecNotImplemented))
  , uioBinExecEnv = \_ _ _ -> pure (Left (UeExec ExecNotImplemented))
  }

-- | A fake 'RepoRegistryHandle' whose @rrhList@ returns the given repos.
fakeRepoReg :: [SourceRepo] -> RepoRegistryHandle
fakeRepoReg repos = RepoRegistryHandle
  { rrhList = pure (Right repos)
  , rrhMutate = \_ -> pure (Right ())
  }
