{-# LANGUAGE OverloadedStrings #-}
-- | Load and save @config\/repos.toml@ — the source-control repo registry
-- ('RepoRegistry'), a keyed-by-id map of 'SourceRepo's the harness may clone
-- (design §4.3, §4.8). Absent file decodes as an empty registry. Writes are
-- atomic (write @.tmp@, rename). The load-decode path runs
-- 'normalizeReposTable' before 'Toml.runTomlCodec' so both the idiomatic
-- @[repos.\<id\>]@-only style and the encoder's explicit-@[repos]@-header
-- style decode correctly (the W2 DoD).
--
-- This module mirrors 'Seal.Config.File' (load/save/update) but with a
-- dedicated 'repoRegistryWriteLock' — it does NOT share 'configWriteLock',
-- so a slow repo write can never block a config read and vice-versa.
module Seal.SourceControl.Registry
  ( RepoRegistry(..)
  , loadRepoRegistry, saveRepoRegistry, updateRepoRegistry
  , upsertRepo, removeRepo, lookupRepo
  , RepoRegistryHandle(..), mkRepoRegistryHandle
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Data.Functor ((<&>))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist, renameFile)
import System.IO.Unsafe (unsafePerformIO)
import Validation (Validation (..))

import Toml qualified

import Seal.SourceControl.Repo
  ( RepoId, SourceRepo (..), RepoRegistry (..), normalizeReposTable, repoRegistryCodec )

----------------------------------------------------------------------------
-- Load / Save (mirror loadRuntimeConfig / saveRuntimeConfig)
----------------------------------------------------------------------------

-- | Load the repo registry at @path@.
--
-- * File absent  → @Right ('RepoRegistry' 'Map.empty')@
-- * Parse error  → @Left@ with the rendered tomland parser error
-- * Decode error → @Left@ with 'Toml.prettyTomlDecodeErrors'
loadRepoRegistry :: FilePath -> IO (Either Text RepoRegistry)
loadRepoRegistry path = do
  exists <- doesFileExist path
  if not exists
    then pure (Right (RepoRegistry Map.empty))
    else do
      contents <- TIO.readFile path
      pure $ case Toml.parse contents of
        Left err   -> Left (Toml.unTomlParseError err)
        Right toml -> case Toml.runTomlCodec repoRegistryCodec (normalizeReposTable toml) of
          Success m   -> Right (RepoRegistry m)
          Failure errs -> Left (Toml.prettyTomlDecodeErrors errs)

-- | Save @rr@ to @path@ atomically: write @path.tmp@, rename over @path@.
saveRepoRegistry :: FilePath -> RepoRegistry -> IO ()
saveRepoRegistry path rr = do
  let encoded = Toml.encode repoRegistryCodec (rrRepos rr)
      tmp     = path <> ".tmp"
  TIO.writeFile tmp encoded
  renameFile tmp path

----------------------------------------------------------------------------
-- Process-wide write lock (mirror configWriteLock — DEDICATED, not shared)
----------------------------------------------------------------------------

-- | Process-wide lock serializing repo-registry writes to prevent
-- lost-update races (design V7). Multiple concurrent 'updateRepoRegistry'
-- callers (e.g. REST PUT + a future REPO_UPDATE opcode) can silently
-- clobber each other without this lock. The MVar is initialized once via
-- 'unsafePerformIO' — idiomatic for a process-wide lock (mirrors
-- 'Seal.Config.File.configWriteLock' and 'Seal.Security.Vault.stWriteLock').
-- This lock is DEDICATED to the repo registry; it is NOT shared with
-- 'configWriteLock' so a slow repo write cannot block a config read.
{-# NOINLINE repoRegistryWriteLock #-}
repoRegistryWriteLock :: MVar ()
repoRegistryWriteLock = unsafePerformIO (newMVar ())

-- | Load the registry at @path@, apply @f@, save. Propagates any load error
-- as @Left Text@ without writing. The load-modify-save is serialized behind
-- 'repoRegistryWriteLock' to prevent lost-update races (design V7).
updateRepoRegistry :: FilePath -> (RepoRegistry -> RepoRegistry) -> IO (Either Text ())
updateRepoRegistry path f = withMVar repoRegistryWriteLock $ \_ -> do
  result <- loadRepoRegistry path
  case result of
    Left err  -> pure (Left err)
    Right rr  -> saveRepoRegistry path (f rr) >> pure (Right ())

----------------------------------------------------------------------------
-- Pure mutation helpers
----------------------------------------------------------------------------

-- | Insert or overwrite a 'SourceRepo' (keyed by its 'srId').
upsertRepo :: SourceRepo -> RepoRegistry -> RepoRegistry
upsertRepo r (RepoRegistry m) = RepoRegistry (Map.insert (srId r) r m)

-- | Delete the repo with the given 'RepoId' (no-op if absent).
removeRepo :: RepoId -> RepoRegistry -> RepoRegistry
removeRepo k (RepoRegistry m) = RepoRegistry (Map.delete k m)

-- | Look up the repo with the given 'RepoId'.
lookupRepo :: RepoId -> RepoRegistry -> Maybe SourceRepo
lookupRepo k (RepoRegistry m) = Map.lookup k m

----------------------------------------------------------------------------
-- Handle (closes over the path — used by the REST API in W4)
----------------------------------------------------------------------------

-- | A handle bundling the two operations the REST API (W4) needs against the
-- repo registry, with the registry path closed over. @rrhList@ returns
-- 'Either' 'Text' so a corrupt @repos.toml@ surfaces as HTTP 500 (the AC5/S2
-- mitigation), not a silent empty list. @rrhMutate@ wraps
-- 'updateRepoRegistry' (atomic, lock-serialized).
data RepoRegistryHandle = RepoRegistryHandle
  { rrhList   :: IO (Either Text [SourceRepo])
  , rrhMutate :: (RepoRegistry -> RepoRegistry) -> IO (Either Text ())
  }

-- | Build a 'RepoRegistryHandle' closing over @path@.
mkRepoRegistryHandle :: FilePath -> IO RepoRegistryHandle
mkRepoRegistryHandle path = pure RepoRegistryHandle
  { rrhList   = loadRepoRegistry path <&> fmap (Map.elems . rrRepos)
  , rrhMutate = updateRepoRegistry path
  }