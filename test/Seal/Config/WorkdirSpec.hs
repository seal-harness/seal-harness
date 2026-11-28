{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
module Seal.Config.WorkdirSpec (spec) where

import Data.Either (isRight)
import Data.IORef (newIORef, readIORef)
import Data.Text qualified as T
import System.Directory
  ( doesDirectoryExist, doesFileExist, createDirectoryIfMissing )
import System.FilePath ((</>), takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import Test.Hspec

import Seal.Config.Paths (SealPaths (..), machinesFilePath)
import Seal.Config.Security
  ( SecurityConfig (..), UntrustedExecFileConfig (..), defaultSecurityConfig )
import Seal.Core.Types (mkSystemSessionId)
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Session.Workdir
  ( WorkdirError (..), ensureSessionWorkdir, cleanupSessionWorkdir
  , remoteSessionWorkdirPath, ensureRemoteSessionWorkdir
  , mkSessionExec, mkSessionUntrustedIO, seUIOEnv, seWorkdirFs
  , seWorkspaceRoot )
import Data.Text.IO qualified as TIO
import Seal.SourceControl.Clone (stubCloneDeps)
import Seal.Tools.Args (mkShellCommand)
import Seal.Tools.Exec.Remote (mkFakeRemoteRunner, mkFakeRemoteRunnerRecording)
import Seal.Tools.Exec.Types
  ( SshConfig (..), ExecError (..), mkSshHost, mkSshUser, mkRemotePath )
import Seal.Tools.Exec.UIO.Internal (uieUntrustedIO)
-- Whole-module import (repo convention): the two CPP branches below each use a
-- different subset, and an explicit list would be unused in one of them.
import Seal.Tools.Exec.UntrustedIO
import Seal.Tools.Exec.WorkdirFs (WorkdirFs (..), WorkdirFsErr (..))

spec :: Spec
spec = describe "Seal.Session.Workdir" $ do

  describe "ensureSessionWorkdir" $ do

    it "creates the workdir at <cache>/workdirs/<sid>" $
      withSystemTempDirectory "seal-wd" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spConfig = tmp </> "config"
              , spState = tmp </> "state", spKeys = tmp </> "keys"
              , spCache = tmp </> "cache" }
            sid = mkSystemSessionId "test-001"
        createDirectoryIfMissing True (spCache paths)
        res <- ensureSessionWorkdir paths sid
        res `shouldSatisfy` isRight
        let expectedDir = tmp </> "cache" </> "workdirs" </> "test-001"
        doesDirectoryExist expectedDir `shouldReturn` True

    it "is idempotent (second call is a no-op)" $
      withSystemTempDirectory "seal-wd" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spConfig = tmp </> "config"
              , spState = tmp </> "state", spKeys = tmp </> "keys"
              , spCache = tmp </> "cache" }
            sid = mkSystemSessionId "test-002"
        createDirectoryIfMissing True (spCache paths)
        _ <- ensureSessionWorkdir paths sid
        res2 <- ensureSessionWorkdir paths sid
        res2 `shouldSatisfy` isRight

    it "returns the workdir path on success" $
      withSystemTempDirectory "seal-wd" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spConfig = tmp </> "config"
              , spState = tmp </> "state", spKeys = tmp </> "keys"
              , spCache = tmp </> "cache" }
            sid = mkSystemSessionId "test-003"
        createDirectoryIfMissing True (spCache paths)
        res <- ensureSessionWorkdir paths sid
        case res of
          Right wd -> wd `shouldBe` tmp </> "cache" </> "workdirs" </> "test-003"
          Left e   -> expectationFailure ("expected Right, got " <> show e)

    it "fails on permission denied (WdMkdirFailed)" $
      withSystemTempDirectory "seal-wd" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spConfig = tmp </> "config"
              , spState = tmp </> "state", spKeys = tmp </> "keys"
              , spCache = tmp </> "cache" }
            sid = mkSystemSessionId "test-004"
        -- Make cache read-only so mkdir fails
        createDirectoryIfMissing True (spCache paths)
        let cacheDir = spCache paths
        setFileMode cacheDir 0o444  -- read-only: mkdir inside fails
        res <- ensureSessionWorkdir paths sid
        -- Restore permissions so cleanup works
        setFileMode cacheDir 0o755
        res `shouldSatisfy` \case
          Left (WdMkdirFailed _ _) -> True
          _ -> False

    it "reuses a stale workdir (does NOT clear it)" $
      withSystemTempDirectory "seal-wd" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spConfig = tmp </> "config"
              , spState = tmp </> "state", spKeys = tmp </> "keys"
              , spCache = tmp </> "cache" }
            sid = mkSystemSessionId "test-005"
            wdPath = tmp </> "cache" </> "workdirs" </> "test-005"
        -- Pre-create the workdir with a marker file
        createDirectoryIfMissing True wdPath
        writeFile (wdPath </> "marker.txt") "stale"
        res <- ensureSessionWorkdir paths sid
        res `shouldSatisfy` isRight
        -- The marker file should still be there (not cleared)
        doesFileExist (wdPath </> "marker.txt") `shouldReturn` True

  describe "cleanupSessionWorkdir" $ do

    it "removes the workdir" $
      withSystemTempDirectory "seal-wd" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spConfig = tmp </> "config"
              , spState = tmp </> "state", spKeys = tmp </> "keys"
              , spCache = tmp </> "cache" }
            sid = mkSystemSessionId "test-006"
            wdPath = tmp </> "cache" </> "workdirs" </> "test-006"
        createDirectoryIfMissing True wdPath
        writeFile (wdPath </> "file.txt") "data"
        res <- cleanupSessionWorkdir paths sid
        res `shouldSatisfy` isRight
        doesDirectoryExist wdPath `shouldReturn` False

    it "is idempotent (no error if workdir is already gone)" $
      withSystemTempDirectory "seal-wd" $ \tmp -> do
        let paths = SealPaths
              { spHome = tmp, spConfig = tmp </> "config"
              , spState = tmp </> "state", spKeys = tmp </> "keys"
              , spCache = tmp </> "cache" }
            sid = mkSystemSessionId "test-007"
        res <- cleanupSessionWorkdir paths sid
        res `shouldSatisfy` isRight

  describe "remoteSessionWorkdirPath" $ do

    it "produces <scWorkspace>/workdirs/<sid>" $ do
      let sid = mkSystemSessionId "test-remote-001"
          remoteWd = remoteSessionWorkdirPath sshCfg sid
      remoteWd `shouldBe` "/srv/agent-workspace/workdirs/test-remote-001"

  describe "ensureRemoteSessionWorkdir" $ do

    it "returns the remote workdir path on success" $ do
      let sid = mkSystemSessionId "test-remote-004"
          runner = mkFakeRemoteRunner (Right "")
      res <- ensureRemoteSessionWorkdir sshCfg runner sid
      case res of
        Right path -> T.isSuffixOf "/workdirs/test-remote-004" path `shouldBe` True
        Left err   -> expectationFailure ("expected Right, got " <> show err)

    it "fails on SSH error (WdRemoteMkdirFailed)" $ do
      let sid = mkSystemSessionId "test-remote-005"
          runner = mkFakeRemoteRunner (Left ExecRemoteUnreachable)
      res <- ensureRemoteSessionWorkdir sshCfg runner sid
      res `shouldSatisfy` \case
        Left (WdRemoteMkdirFailed _) -> True
        _ -> False

  -- -------------------------------------------------------------------------
  -- W3: mkSessionExec
  -- -------------------------------------------------------------------------

  describe "mkSessionExec" $ do

    it "(a) local mode → local WorkdirFs + local seUIOEnv + local seWorkspaceRoot" $
#if defined(REMOTE_ONLY_UNTRUSTED)
      -- Inverted assertion under the hardened flag. The default build proves
      -- a local session gets a real local handle; this build must prove the
      -- opposite, because @allow_localhost = true@ is exactly the state the
      -- flag refuses. Asserting the fail-closed shape here rather than
      -- skipping keeps the property tested in the configuration where it
      -- matters (done-when 15) and keeps 'mkSessionExec' used.
      withSystemTempDirectory "seal-wd-exec" $ \tmp -> do
        let paths  = mkPaths tmp
            sid    = mkSystemSessionId "exec-local-001"
        createDirectoryIfMissing True (spCache paths)
        exec <- mkSessionExec paths defaultSecurityConfig sid stubCloneDeps
                   (mkFakeRemoteRunner (Right "")) Nothing
        -- No local workdir was created, and the root is the fail-closed one.
        -- The root is the sentinel, and the handle is a stub: those are the
        -- two things the flag guarantees. (A directory may still exist under
        -- cache/workdirs — the path is computed before the executor is
        -- selected, and asserting otherwise would pin an unrelated detail.)
        unWorkspaceRoot (seWorkspaceRoot exec)
          `shouldBe` "/nonexistent-workdir-fail-closed"
        -- The handle is the fail-closed stub, so a read fails rather than
        -- reaching the local FS.
        let markerRp = either (error "fixture") id (mkRemotePath "marker.txt")
            uio = uieUntrustedIO (seUIOEnv exec)
        res <- uioReadFile uio markerRp 65536
        res `shouldSatisfy` not . isRight
#else
      withSystemTempDirectory "seal-wd-exec" $ \tmp -> do
        let paths  = mkPaths tmp
            sid    = mkSystemSessionId "exec-local-001"
            secCfg = defaultSecurityConfig
        createDirectoryIfMissing True (spCache paths)
        exec <- mkSessionExec paths secCfg sid stubCloneDeps
                   (mkFakeRemoteRunner (Right "")) Nothing
        -- The workspace root is the local per-session workdir.
        let expectedWd = tmp </> "cache" </> "workdirs" </> "exec-local-001"
        unWorkspaceRoot (seWorkspaceRoot exec) `shouldBe` expectedWd
        -- The workdir exists on the local FS.
        doesDirectoryExist expectedWd `shouldReturn` True
        -- The local WorkdirFs reads the workdir (create a marker file).
        let markerRp = either (error "fixture") id (mkRemotePath "marker.txt")
        writeFile (expectedWd </> "marker.txt") "hello"
        wfsDoesFileExist (seWorkdirFs exec) markerRp `shouldReturn` True
        -- The UIOEnv's UntrustedIO is NOT the fail-closed stub: it can
        -- read a file the local arm would find. (We probe by checking
        -- the stub would fail-closed; here we just assert the handle
        -- is a distinct value from mkRemoteUntrustedIOStub by reading
        -- a file and confirming it succeeds.)
        let uio = uieUntrustedIO (seUIOEnv exec)
        res <- uioReadFile uio markerRp 65536
        res `shouldSatisfy` isRight
#endif

    it "(b) remote mode + configured → both remote-shaped, share scWorkspace, one runner" $
      withSystemTempDirectory "seal-wd-remote" $ \tmp -> do
      callsRef <- newIORef []
      let runner  = mkFakeRemoteRunnerRecording callsRef (Right "")
          sid     = mkSystemSessionId "exec-remote-001"
          secCfg  = remoteSecurityConfig
          paths   = mkPathsRemote tmp
      writeRemoteMachinesToml paths
      exec <- mkSessionExec paths secCfg sid stubCloneDeps runner Nothing
      -- The workspace root is the remote per-session workdir path.
      let expectedRemoteWd =
            "/srv/agent-workspace/workdirs/exec-remote-001"
      unWorkspaceRoot (seWorkspaceRoot exec) `shouldBe` expectedRemoteWd
      -- A remote WorkdirFs call goes through the shared runner (proves
      -- WorkdirFs-on-UIO, one transport). The existence check issues
      -- a `test -f` over SSH.
      let rp = either (error "fixture") id (mkRemotePath "anyfile.txt")
      _ <- wfsDoesFileExist (seWorkdirFs exec) rp
      -- A UIO operation (shell exec) also goes through the same runner.
      let uio = uieUntrustedIO (seUIOEnv exec)
          cmdShell = case mkShellCommand "echo hi" of
            Right c -> c
            Left _e -> error "fixture: mkShellCommand failed"
      _ <- uioShellExec uio cmdShell Nothing
      -- Both calls landed in the SAME IORef (one runner shared).
      recorded <- readIORef callsRef
      recorded `shouldNotBe` []
      length recorded `shouldSatisfy` (> 1)

    it "(c) no machine configured + local execution off → both stubs, runner NOT invoked" $
      withSystemTempDirectory "seal-wd-nomachine" $ \tmp -> do
      callsRef <- newIORef []
      let runner = mkFakeRemoteRunnerRecording callsRef (Right "")
          paths  = mkPathsRemote tmp
          sid    = mkSystemSessionId "exec-remote-misconfigured-001"
          -- allow_localhost = false and no machines.toml: there is nothing to
          -- run on, so this fail-closes rather than silently running locally.
          -- (Before this feature the equivalent state was "mode=remote with no
          -- [remote] block"; the coordinates moved to machines.toml, so the
          -- absent-block case is no longer representable here.)
          secCfg = defaultSecurityConfig
                     { scUntrustedExec = Just (UntrustedExecFileConfig False) }
      exec <- mkSessionExec paths secCfg sid stubCloneDeps runner Nothing
      -- Nothing was reached: the fail-closed path returns before any SSH.
      readIORef callsRef `shouldReturn` []
      -- Both handles are stubs: WorkdirFs yields WfsStub.
      let rp = either (error "fixture") id (mkRemotePath "anyfile.txt")
      wfsReadFile (seWorkdirFs exec) rp `shouldReturn` Left WfsStub
      -- The workspace root is fail-closed.
      unWorkspaceRoot (seWorkspaceRoot exec) `shouldBe` "/nonexistent-workdir-fail-closed"

    it "(c') remote mode + unreachable (mkdir fails) → both stubs" $
      withSystemTempDirectory "seal-wd-unreachable" $ \tmp -> do
      callsRef <- newIORef []
      let runner = mkFakeRemoteRunnerRecording callsRef (Left ExecRemoteUnreachable)
          sid    = mkSystemSessionId "exec-remote-unreachable-001"
          secCfg = remoteSecurityConfig
          paths  = mkPathsRemote tmp
      writeRemoteMachinesToml paths
      exec <- mkSessionExec paths secCfg sid stubCloneDeps runner Nothing
      -- The mkdir over SSH failed, so both handles are stubs.
      let rp = either (error "fixture") id (mkRemotePath "anyfile.txt")
      wfsReadFile (seWorkdirFs exec) rp `shouldReturn` Left WfsStub
      unWorkspaceRoot (seWorkspaceRoot exec) `shouldBe` "/nonexistent-workdir-fail-closed"

    it "(d) local mode + workdir mkdir fails → both stubs (fail-closed parity)" $
      withSystemTempDirectory "seal-wd-exec-fail" $ \tmp -> do
        let paths  = mkPaths tmp
            sid    = mkSystemSessionId "exec-local-fail-001"
            secCfg = defaultSecurityConfig
        createDirectoryIfMissing True (spCache paths)
        setFileMode (spCache paths) 0o444  -- read-only: mkdir inside fails
        exec <- mkSessionExec paths secCfg sid stubCloneDeps
                   (mkFakeRemoteRunner (Right "")) Nothing
        setFileMode (spCache paths) 0o755  -- restore for cleanup
        -- Both handles are stubs.
        let rp = either (error "fixture") id (mkRemotePath "anyfile.txt")
        wfsReadFile (seWorkdirFs exec) rp `shouldReturn` Left WfsStub
        unWorkspaceRoot (seWorkspaceRoot exec) `shouldBe` "/nonexistent-workdir-fail-closed"

    it "(e) mkSessionUntrustedIO ≡ uieUntrustedIO . seUIOEnv <$> mkSessionExec (back-compat)" $
#if defined(REMOTE_ONLY_UNTRUSTED)
      -- The equivalence still holds; what changes is that both sides are the
      -- fail-closed stub in this configuration. Asserting equality of the two
      -- construction paths is the actual claim, and it is configuration-
      -- independent — so it stays live rather than being skipped.
      withSystemTempDirectory "seal-wd-exec-bc" $ \tmp -> do
        let paths  = mkPaths tmp
            sid    = mkSystemSessionId "exec-bc-001"
        createDirectoryIfMissing True (spCache paths)
        uio1 <- mkSessionUntrustedIO paths defaultSecurityConfig sid
        exec <- mkSessionExec paths defaultSecurityConfig sid stubCloneDeps
                   (mkFakeRemoteRunner (Right "")) Nothing
        let uio2 = uieUntrustedIO (seUIOEnv exec)
            rp   = either (error "fixture") id (mkRemotePath "marker.txt")
        -- Both are the stub: both fail the read, identically.
        (e1, e2) <- (,) <$> uioReadFile uio1 rp 65536
                         <*> uioReadFile uio2 rp 65536
        e1 `shouldSatisfy` not . isRight
        e2 `shouldSatisfy` not . isRight
        e1 `shouldBe` e2
        -- Both sides fail with the SAME error, which is the equivalence being
        -- asserted. Comparing against 'mkRemoteUntrustedIOStub' directly would
        -- be wrong: 'mkSessionExec' fail-closes with a REASON (why local
        -- execution is unavailable), which is more informative than the bare
        -- stub and is what a caller sees.
        e1 `shouldSatisfy` \case
          Left (UeExec (ExecNotImplementedReason _)) -> True
          _                                          -> False
#else
      withSystemTempDirectory "seal-wd-exec-bc" $ \tmp -> do
        let paths  = mkPaths tmp
            sid    = mkSystemSessionId "exec-bc-001"
            secCfg = defaultSecurityConfig
        createDirectoryIfMissing True (spCache paths)
        uio1 <- mkSessionUntrustedIO paths secCfg sid
        exec <- mkSessionExec paths secCfg sid stubCloneDeps
                   (mkFakeRemoteRunner (Right "")) Nothing
        let uio2 = uieUntrustedIO (seUIOEnv exec)
        -- Both are local UntrustedIO handles (NOT the stub): they can
        -- read a marker file. The stub would fail-closed.
        let expectedWd = tmp </> "cache" </> "workdirs" </> "exec-bc-001"
        writeFile (expectedWd </> "marker.txt") "hi"
        let markerRp = either (error "fixture") id (mkRemotePath "marker.txt")
        r1 <- uioReadFile uio1 markerRp 65536
        r2 <- uioReadFile uio2 markerRp 65536
        r1 `shouldSatisfy` isRight
        r2 `shouldSatisfy` isRight
        -- And the stub would NOT read it (proves they are not the stub).
        rStub <- uioReadFile mkRemoteUntrustedIOStub markerRp 65536
        rStub `shouldSatisfy` \case Left _ -> True; Right _ -> False
#endif

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

sshCfg :: SshConfig
sshCfg = SshConfig
  { scHost       = either (error "fixture") id (mkSshHost "exec.internal")
  , scUser       = either (error "fixture") id (mkSshUser "agent")
  , scPort       = 22
  , scIdentity   = Nothing
  , scKnownHosts = "/home/agent/.ssh/known_hosts"
  , scWorkspace  = either (error "fixture") id (mkRemotePath "/srv/agent-workspace")
  }

-- | Build 'SealPaths' anchored at a temp dir (local mode). The cache dir
-- is created by the caller.
mkPaths :: FilePath -> SealPaths
mkPaths tmp = SealPaths
  { spHome = tmp, spConfig = tmp </> "config"
  , spState = tmp </> "state", spKeys = tmp </> "keys"
  , spCache = tmp </> "cache" }

-- | 'SealPaths' for a remote-mode fixture.
--
-- __Per-test, not a fixed shared path.__ The remote workdir itself is created
-- over the (fake) runner, but @machines.toml@ is read from @spHome@ on the local
-- filesystem — so a fixed path would let one test's machine list leak into the
-- next. A test asserting "no machine configured" would then find the machine
-- another test wrote and pass or fail depending on order.
mkPathsRemote :: FilePath -> SealPaths
mkPathsRemote tmp = SealPaths
  { spHome = tmp </> "remote-home"
  , spConfig = tmp </> "remote-home" </> "config"
  , spState = tmp </> "remote-state"
  , spKeys = tmp </> "remote-keys"
  , spCache = tmp </> "remote-cache" }

-- | Local execution off, so the resolver must take its machine from
-- @machines.toml@ — which 'writeRemoteMachinesToml' puts beside it.
remoteSecurityConfig :: SecurityConfig
remoteSecurityConfig = defaultSecurityConfig
  { scUntrustedExec = Just (UntrustedExecFileConfig False) }

-- | Write the @machines.toml@ naming one SSH machine whose workspace is the
-- fixture's. The exec's coordinates come from here now, not from
-- @security.toml@.
--
-- @host@ is deliberately not a loopback form: resolution refuses those, and
-- this fixture is about the exec, not the loopback guard.
writeRemoteMachinesToml :: SealPaths -> IO ()
writeRemoteMachinesToml paths = do
  let path = machinesFilePath paths
  createDirectoryIfMissing True (takeDirectory path)
  TIO.writeFile path (T.unlines
    [ "default = \"builder\""
    , "[machines.builder]"
    , "host = \"exec.internal\""
    , "user = \"agent\""
    , "port = 22"
    , "workspace = \"/srv/agent-workspace\""
    ])

-- | Unwrap a 'WorkspaceRoot' for test comparisons (the newtype has no
-- 'Show'/'Eq' instances by design).
unWorkspaceRoot :: WorkspaceRoot -> FilePath
unWorkspaceRoot (WorkspaceRoot p) = p
