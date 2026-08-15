{-# LANGUAGE OverloadedStrings #-}
-- | The agent-definition store backend. Disk is canonical. Two on-disk
-- schemes are discovered:
--
-- 1. **FlatScheme** — one Markdown file per def at @agents\/\<id\>.md@,
--    frontmatter (id\/name\/provider\/model\/tools\/timestamps\/session) +
--    body = system prompt. 'AGENT_DEF_CREATE' \/ 'AGENT_DEF_UPDATE' write
--    this form. This is the model-authored channel.
--
-- 2. **DirScheme** (PureClaw-compatible) — a subdirectory per agent at
--    @agents\/\<id\>\/@, with optional TOML frontmatter on @AGENTS.md@
--    (model\/provider\/tools) and the system prompt composed by reading
--    bootstrap files (@SOUL.md@, @USER.md@, @AGENTS.md@ body,
--    @MEMORY.md@, @IDENTITY.md@, @TOOLS.md@, @BOOTSTRAP.md@) in fixed
--    order with @--- SOUL ---@-style section markers. This is the
--    human-authored channel — drop a directory under @agents\/@ and it
--    is discovered.
--
-- **Conflict policy**: if both @agents\/\<id\>.md@ and @agents\/\<id\>\/@
-- exist, the flat file wins (it carries provenance and is the
-- model-authored form). The backend emits a warning on collision rather
-- than silently deduplicating.
--
-- **Directories are a one-time import path**: the first
-- 'AGENT_DEF_CREATE' \/ 'AGENT_DEF_UPDATE' for a DirScheme agent writes
-- @agents\/\<id\>.md@ (taking the composed prompt as the flat body),
-- after which the flat file takes precedence. The user can delete the
-- original directory at their leisure.
--
-- 'markdownAgentDefBackend' reads by enumerating the directory (both
-- schemes) and writes by atomic file replace + auto-commit.
-- 'noneBackend' (in-memory) is kept for tests.
--
-- The git repo is the versioning + audit layer; model-authored writes
-- (@AGENT_DEF_CREATE@ \/ @AGENT_DEF_UPDATE@, which are Trusted file writes)
-- auto-commit.
--
-- The /workdir-scoped/ discovery backend (for @.agents\/@ discovery from
-- cloned repos) lives in "Seal.Agent.Def.Workdir" and is re-exported here.
-- That module has NO direct @System.Directory@\/@Data.Text.IO@ access —
-- every workspace read goes through the 'WorkdirFs' handle (§3.6). This
-- module (the user store) is local-FS by design (§3.9).
module Seal.Agent.Def.Backend
  ( -- * Backend record (re-exported from Seal.Agent.Def.Workdir)
    AgentDefBackend (..)
  , noneBackend
  , unionAgentDefBackend
    -- * User store (local-FS, §3.9)
  , markdownAgentDefBackend
    -- * Workdir-scoped discovery (re-exported from Seal.Agent.Def.Workdir)
  , workdirAgentDefBackend
  , workdirAgentDefBackendFs
    -- * Codecs + DirScheme helpers (re-exported from Seal.Agent.Def.Workdir)
  , encodeAgentDef
  , decodeAgentDef
  , composeDirSystemPrompt
  , defaultSectionCharLimit
  , maxBootstrapFileBytes
  , DirAgentConfig (..)
  , defaultDirAgentConfig
  , dirAgentConfigCodec
  , parseDirAgentConfig
  , deriveAgentsMdId
  ) where

import Control.Monad (forM, when)
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
  ( doesDirectoryExist, doesFileExist, listDirectory, removeFile, renameFile
  )
import System.FilePath ((</>), (<.>))
import System.Posix.Files (setFileMode)

import Seal.Agent.Def.Types
  ( AgentDef (..), AgentDefId (..), mkAgentDefId, agentDefIdText
  , isValidAgentDefId
  )
import Seal.Git.Repo (ConfigRepo, gitCommitAll)
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Text.LineFile (maxScanBytes)
import Seal.Tools.Exec.WorkdirFs (WorkdirFs, mkLocalWorkdirFs)

import Seal.Agent.Def.Workdir

-- | The agent-definition store capability. Each operation is IO; 'adbList'
-- returns all defs sorted by id. (Defined in "Seal.Agent.Def.Workdir" to
-- avoid an import cycle; re-exported here.)

-- | The in-memory backend: a single 'IORef' over a 'Map'. Used by tests.
noneBackend :: IO AgentDefBackend
noneBackend = do
  ref <- newIORef (Map.empty :: Map AgentDefId AgentDef)
  pure AgentDefBackend
    { adbRead   = \aid -> Map.lookup aid <$> readIORef ref
    , adbUpdate = \d -> modifyIORef' ref (Map.insert (adId d) d)
    , adbList   = Map.elems <$> readIORef ref
    , adbDelete = modifyIORef' ref . Map.delete
    }

-- | The Markdown backend. Discovers both flat @agents\/\<id\>.md@ files and
-- PureClaw-style @agents\/\<id\>\/@ subdirectories. Writes are atomic
-- (tmp → chmod 0600 → rename) and auto-committed to the config git repo.
-- Malformed files / dirs are skipped.
markdownAgentDefBackend :: FilePath -> ConfigRepo -> IO AgentDefBackend
markdownAgentDefBackend dir repo = pure AgentDefBackend
  { adbRead   = readAgentDef dir
  , adbUpdate = writeAgentDef dir repo
  , adbList   = listAgentDefs dir
  , adbDelete = deleteAgentDef dir repo
  }

-- ---------------------------------------------------------------------------
-- FlatScheme (user store)
-- ---------------------------------------------------------------------------

-- | The filename for a def: @\<id\>.md@.
defFile :: FilePath -> AgentDefId -> FilePath
defFile dir aid = dir </> T.unpack (agentDefIdText aid) <.> "md"

-- | The directory for a def: @agents\/\<id\>@.
defDir :: FilePath -> AgentDefId -> FilePath
defDir dir aid = dir </> T.unpack (agentDefIdText aid)

-- | Write one def to disk (atomic) and auto-commit.
writeAgentDef :: FilePath -> ConfigRepo -> AgentDef -> IO ()
writeAgentDef dir repo d = do
  let path = defFile dir (adId d)
      tmp  = path <.> "tmp"
  TIO.writeFile tmp (encodeAgentDef d)
  setFileMode tmp 0o600
  renameFile tmp path
  let rel = "agents" </> (T.unpack (agentDefIdText (adId d)) <.> "md")
  _ <- gitCommitAll repo rel ("seal: AGENT_DEF write " <> agentDefIdText (adId d))
  pure ()

-- | Delete one def file and auto-commit. Idempotent (no-op if the file is
-- absent). Does NOT remove PureClaw-style subdirectories (a directory is a
-- human-authored import path; the model does not delete those).
deleteAgentDef :: FilePath -> ConfigRepo -> AgentDefId -> IO ()
deleteAgentDef dir repo aid = do
  let path = defFile dir aid
  exists <- doesFileExist path
  if not exists
    then pure ()
    else do
      removeFile path
      let rel = "agents" </> (T.unpack (agentDefIdText aid) <.> "md")
      _ <- gitCommitAll repo rel ("seal: AGENT_DEF delete " <> agentDefIdText aid)
      pure ()

-- ---------------------------------------------------------------------------
-- Hybrid discovery (flat + dir) — user store, local-FS
-- ---------------------------------------------------------------------------

-- | The local 'WorkdirFs' anchored at the user store's agents directory.
-- The DirScheme reads ('loadDirAgentDef' et al.) live in
-- "Seal.Agent.Def.Workdir" and operate over 'WorkdirFs'; the user store
-- constructs a local-arm 'WorkdirFs' at its @dir@ so the DirScheme reads
-- share the single confined code path (§3.6) while remaining local-FS
-- (§3.9).
userDirFs :: FilePath -> WorkdirFs
userDirFs dir = mkLocalWorkdirFs (WorkspaceRoot dir) maxScanBytes

-- | Read one def by id. Flat scheme takes precedence on conflict. Falls
-- back to the dir scheme if the flat file is absent. Returns 'Nothing' if
-- neither exists.
readAgentDef :: FilePath -> AgentDefId -> IO (Maybe AgentDef)
readAgentDef dir aid = do
  let flatPath = defFile dir aid
  flatExists <- doesFileExist flatPath
  if flatExists
    then do
      -- Conflict check: warn if a directory also exists.
      let dirPath = defDir dir aid
      dirExists <- doesDirectoryExist dirPath
      when dirExists $
        putStrLn ("warning: agent def " <> T.unpack (agentDefIdText aid)
                  <> " has both a flat file and a directory; flat file takes precedence")
      content <- TIO.readFile flatPath
      pure (decodeAgentDef content)
    else loadDirAgentDef (userDirFs dir) aid

-- | Enumerate all defs in the directory (both schemes), sorted by id.
-- Malformed flat files and malformed dirs are skipped. On flat/dir
-- collision for the same id, the flat file wins and the dir is dropped.
listAgentDefs :: FilePath -> IO [AgentDef]
listAgentDefs dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      entries <- listDirectory dir
      flatDefs <- collectFlat dir entries
      dirDefs  <- collectDirs dir entries (map adId flatDefs)
      pure (sortOn (agentDefIdText . adId) (flatDefs <> dirDefs))

-- | Decode all flat @.md@ files in the directory.
collectFlat :: FilePath -> [FilePath] -> IO [AgentDef]
collectFlat dir entries = do
  let mdFiles = [e | e <- entries, ".md" `T.isSuffixOf` T.pack e]
  defs <- forM mdFiles $ \e -> do
    content <- TIO.readFile (dir </> e)
    pure (decodeAgentDef content)
  pure (catMaybes defs)

-- | Load DirScheme defs from subdirectories, skipping ids already
-- provided by the flat scheme (flat wins on conflict). Emits a warning
-- per collision.
collectDirs :: FilePath -> [FilePath] -> [AgentDefId] -> IO [AgentDef]
collectDirs dir entries flatIds = do
  let flatIdTexts = Set.fromList (map agentDefIdText flatIds)
      candidate e = do
        let full = dir </> e
        isDir <- doesDirectoryExist full
        let validDir = isDir && isValidAgentDefId (T.pack e)
        pure (if validDir then Just e else Nothing)
  mEntries <- mapM candidate entries
  let dirNames = catMaybes mEntries
  defs <- forM dirNames $ \e -> do
    case mkAgentDefId (T.pack e) of
      Left _   -> pure Nothing
      Right aid -> do
        if agentDefIdText aid `Set.member` flatIdTexts
          then do
            putStrLn ("warning: agent def " <> e
                      <> " has both a flat file and a directory; flat file takes precedence")
            pure Nothing  -- skip the dir def; flat wins
          else loadDirAgentDef (userDirFs dir) aid
  pure (catMaybes defs)

-- | A union of a workdir 'AgentDefBackend' (repo-local agent defs) and a
-- user 'AgentDefBackend' (the on-disk @~/.seal/config/agents/@ store).
-- Workdir-wins on id collisions: workdir shadows user. Reads check
-- workdir first, then user. Listing merges both with workdir winning on
-- collision. Writes go to the /user/ backend only (repo-local defs are
-- immutable from the model's perspective).
unionAgentDefBackend :: AgentDefBackend -> AgentDefBackend -> AgentDefBackend
unionAgentDefBackend workdir user = AgentDefBackend
    { adbRead   = \aid -> do
        mWd <- adbRead workdir aid
        case mWd of
          Just d  -> pure (Just d)
          Nothing -> adbRead user aid
    , adbUpdate = adbUpdate user
    , adbList   = do
        wdDefs  <- adbList workdir
        userDefs <- adbList user
        let wdMap   = Map.fromList [(adId d, d) | d <- wdDefs]
            userMap = Map.fromList [(adId d, d) | d <- userDefs]
            merged  = Map.union wdMap userMap
        pure (Map.elems merged)
    , adbDelete = adbDelete user
    }