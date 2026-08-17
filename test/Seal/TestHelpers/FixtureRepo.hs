{-# LANGUAGE OverloadedStrings #-}
-- | A pure data structure describing a fixture workspace, seeded into BOTH
-- the local arm (materialized on a real temp dir) and the remote arm (seeded
-- into the fake runner's canned-output map). This is the shared substrate
-- that makes local/remote parity comparison meaningful — both arms see
-- \"the same workspace\".
module Seal.TestHelpers.FixtureRepo
  ( FixtureRepo (..)
  , materializeFixture
  , stubCloneDeps
  ) where

import Data.IORef (newIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

import Seal.Security.Path (WorkspaceRoot (..))
import Seal.SourceControl.AgentRegistry (mkAgentRegistryHandle)
import Seal.SourceControl.Clone (CloneDeps (..))
import Seal.SourceControl.GithubKeys (pinnedGithubKnownHosts)
import Seal.TestHelpers.FakeRegistry (fakeRepoRegistryHandle)
import Seal.TestHelpers.FakeVault (makeFakeVaultRuntime)
import Seal.Tools.Ssh.Agent (SshAgentEnv (..), mkFakeSshAgentHandle)

-- | A pure description of a fixture workspace. Seeded into both arms:
-- the local arm materializes it on a real temp dir; the remote arm seeds
-- it into the fake runner's canned-output map.
data FixtureRepo = FixtureRepo
  { frFiles :: Map Text Text           -- ^ file contents (workspace-relative path → content)
  , frDirs :: Set Text                 -- ^ directory structure (workspace-relative paths)
  , frSymlinks :: Map Text Text         -- ^ symlink map (workspace-relative path → target)
  , frFileSizes :: Map Text Integer     -- ^ file sizes (for stat parity)
  , frMtimes :: Map Text Text           -- ^ file mtimes as epoch seconds (for stat parity)
  }

-- | Materialize a 'FixtureRepo' on a real temp directory (the local arm's
-- substrate). Creates all directories + writes all files. Returns the
-- 'WorkspaceRoot' pointing at the temp dir. The caller is responsible for
-- cleaning up the temp dir (use 'withSystemTempDirectory' in the test).
materializeFixture :: FixtureRepo -> (WorkspaceRoot -> IO a) -> IO a
materializeFixture fixture inner =
  withSystemTempDirectory "seal-fixture" $ \dir -> do
    let root = WorkspaceRoot dir
    -- Create directories
    mapM_ (createDir dir) (Map.keys (frFiles fixture))
    -- Write files
    mapM_ (writeFile' dir) (Map.toList (frFiles fixture))
    inner root
  where
    createDir base path =
      createDirectoryIfMissing True (base </> dirOf (T.unpack path))
    writeFile' base (path, content) = do
      let fullPath = base </> T.unpack path
      writeFile fullPath (T.unpack content)

-- | A stub 'CloneDeps' for parity tests that don't exercise Git credential
-- resolution (non-Git opcodes). All fields are stubbed via the existing
-- test helpers.
stubCloneDeps :: IO CloneDeps
stubCloneDeps = do
  vault <- makeFakeVaultRuntime []
  agentRef <- newIORef []
  agentReg <- mkAgentRegistryHandle "/tmp/seal-test-agent-reg-unused"
  let agent = mkFakeSshAgentHandle agentRef
        (SshAgentEnv "/tmp/seal-fake-sock" "0")
  pure CloneDeps
    { cdVault = vault
    , cdRepoReg = fakeRepoRegistryHandle
    , cdSshAgent = agent
    , cdAgentRegistry = agentReg
    , cdPinnedKnownHosts = pinnedGithubKnownHosts
    , cdKeyfilesDir = "/tmp/seal-test-keyfiles-unused"
    , cdIsRemote = False
    }

-- | Extract the directory portion of a file path (drop the last component).
dirOf :: FilePath -> FilePath
dirOf path = case breakLast '/' path of
  Just (dir, _) -> dir
  Nothing -> "."

-- | Break a string at the last occurrence of a character.
breakLast :: Char -> String -> Maybe (String, String)
breakLast c = go []
  where
    go _ [] = Nothing
    go acc (x:xs)
      | x == c = Just (reverse acc, xs)
      | otherwise = go (x:acc) xs