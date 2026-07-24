{-# LANGUAGE OverloadedStrings #-}
module Seal.Config.WorkdirSpec (spec) where

import Data.Either (isRight)
import Data.Text qualified as T
import System.Directory
  ( doesDirectoryExist, doesFileExist, createDirectoryIfMissing )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import Test.Hspec

import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (mkSystemSessionId)
import Seal.Session.Workdir
  ( WorkdirError (..), ensureSessionWorkdir, cleanupSessionWorkdir
  , remoteSessionWorkdirPath, ensureRemoteSessionWorkdir )
import Seal.Tools.Exec.Remote (mkFakeRemoteRunner)
import Seal.Tools.Exec.Types
  ( SshConfig (..), ExecError (..), mkSshHost, mkSshUser, mkRemotePath )

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