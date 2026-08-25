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
  , staticAgentDefBackend
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

import Control.Monad (filterM, forM, forM_, when)
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
  ( createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory
  , removeFile, renameFile )
import System.FilePath (takeDirectory, (</>), (<.>))
import System.Posix.Files (setFileMode)

import Seal.Agent.Def.Types
  ( AgentDef (..), AgentDefId (..), mkAgentDefId, agentDefIdText
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

-- | The filename for a def in the flat layout: @\<id\>.md@.
defFile :: FilePath -> AgentDefId -> FilePath
defFile dir aid = dir </> T.unpack (agentDefIdText aid) <.> "md"

-- | The directory for a def: @agents\/\<id\>@.
defDir :: FilePath -> AgentDefId -> FilePath
defDir dir aid = dir </> T.unpack (agentDefIdText aid)

-- | The full path for a def write, honoring its group. A grouped def lives
-- at @\<root\>\/\<group\>\/\<id\>.md@; an ungrouped def (or one whose group
-- is empty) lives at @\<root\>\/\<id\>.md@ (back-compat with the flat
-- layout). The group directory is created on write. Mirrors
-- 'Seal.Skills.Backend.skillPath'.
defPath :: FilePath -> AgentDef -> FilePath
defPath root d =
  case adGroup d of
    Just g | not (T.null (T.strip g)) ->
      root </> T.unpack (T.strip g) </> T.unpack (agentDefIdText (adId d)) <.> "md"
    _ -> defFile root (adId d)

-- | Write one def to disk (atomic) and auto-commit. Honors 'adGroup': a
-- grouped def is written under @\<root\>\/\<group\>\/\<id\>.md@ (the group
-- directory is created if absent); an ungrouped def is written flat at
-- @\<root\>\/\<id\>.md@. The git commit path is relative to the config repo
-- root and encodes the group when present.
writeAgentDef :: FilePath -> ConfigRepo -> AgentDef -> IO ()
writeAgentDef dir repo d = do
  let path = defPath dir d
      tmp  = path <.> "tmp"
      parent = takeDirectory path
  createDirectoryIfMissing True parent
  TIO.writeFile tmp (encodeAgentDef d)
  setFileMode tmp 0o600
  renameFile tmp path
  let rel = "agents" </> case adGroup d of
        Just g | not (T.null (T.strip g)) ->
          T.unpack (T.strip g) </> (T.unpack (agentDefIdText (adId d)) <.> "md")
        _ -> T.unpack (agentDefIdText (adId d)) <.> "md"
  _ <- gitCommitAll repo rel ("seal: AGENT_DEF write " <> agentDefIdText (adId d))
  pure ()

-- | Delete one def file and auto-commit. Idempotent (no-op if the file is
-- absent). Searches both the grouped and flat layouts: a def written under
-- a group is deleted from its group directory; a flat-layout def is deleted
-- from the root. If a file exists in both, both are removed. Does NOT remove
-- PureClaw-style subdirectories (a directory is a human-authored import
-- path; the model does not delete those).
deleteAgentDef :: FilePath -> ConfigRepo -> AgentDefId -> IO ()
deleteAgentDef dir repo aid = do
  let base = T.unpack (agentDefIdText aid) <.> "md"
  groups <- listGroupSubdirs dir
  let groupedPaths = [ dir </> T.unpack g </> base | g <- groups ]
      flatPath     = defFile dir aid
  candidates <- filterM doesFileExist (groupedPaths ++ [flatPath])
  forM_ candidates $ \path -> do
    removeFile path
    let rel = "agents" </> fromMaybe base (stripRoot dir path)
    _ <- gitCommitAll repo rel ("seal: AGENT_DEF delete " <> agentDefIdText aid)
    pure ()
  where
    stripRoot r p =
      let r' = dropTrailingSlash r
          p' = dropTrailingSlash p
      in if r' `isPrefixPath` p'
           then Just (drop (length r' + 1) p')
           else Nothing
    dropTrailingSlash = reverse . dropWhile (== '/') . reverse
    isPrefixPath pre s = take (length pre) s == pre

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

-- | Read one def by id. Probes, in order: the native grouped layout
-- (@\<group\>\/\<id\>.md@) for each group subdirectory, then the flat
-- layout (@\<id\>.md@). On the flat path, the DirScheme
-- (@agents\/\<id\>\/@) is the fallback when the flat file is absent. The
-- returned def's 'adGroup' is filled from the parent directory when the
-- frontmatter omitted it (the common case), so a grouped file reads back
-- as grouped regardless of whether its frontmatter redundantly declares a
-- group. Returns 'Nothing' if no candidate exists. Mirrors
-- 'Seal.Skills.Backend.readSkill'.
readAgentDef :: FilePath -> AgentDefId -> IO (Maybe AgentDef)
readAgentDef dir aid = do
  let flatPath = defFile dir aid
  groups <- listGroupSubdirs dir
  let base = T.unpack (agentDefIdText aid) <.> "md"
      groupedPaths = [ (g, dir </> T.unpack g </> base) | g <- groups ]
  mGrouped <- firstMatchGrouped groupedPaths
  case mGrouped of
    Just d  -> pure (Just d)
    Nothing -> do
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

-- | Enumerate all defs in the directory (flat + grouped + DirScheme),
-- sorted by id. Malformed flat files and malformed dirs are skipped. On
-- flat/dir collision for the same id, the flat file wins and the dir is
-- dropped. Grouped @.md@ files one directory down are stamped with their
-- group. A subdirectory is classified as a *group* when it contains at
-- least one @.md@ file that decodes as an 'AgentDef' (has an @id@
-- frontmatter); otherwise it is treated as a DirScheme
-- (@agents\/\<id\>\/@ with bootstrap files). Mirrors
-- 'Seal.Skills.Backend.listSkills'.
listAgentDefs :: FilePath -> IO [AgentDef]
listAgentDefs dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      entries <- listDirectory dir
      flatDefs <- collectFlat dir entries
      (groupDirs, dirSchemeDirs) <- classifySubdirs dir entries
      groupedDefs <- collectGrouped dir groupDirs
      let groupSet = Set.fromList groupDirs
      dirDefs  <- collectDirs dir dirSchemeDirs (map adId (flatDefs ++ groupedDefs)) groupSet
      pure (sortOn (agentDefIdText . adId) (flatDefs ++ groupedDefs ++ dirDefs))

-- | Classify immediate subdirectories of @dir@ into group dirs (contain at
-- least one decodable flat def @.md@) and DirScheme dirs (everything else
-- with a valid agent-def id). Hidden dirs are skipped.
classifySubdirs :: FilePath -> [FilePath] -> IO ([Text], [FilePath])
classifySubdirs dir entries = do
  let visible = [e | e <- entries, not (T.isPrefixOf "." (T.pack e))]
  isDirBools <- mapM (\e -> doesDirectoryExist (dir </> e)) visible
  let dirNames = [e | (e, b) <- zip visible isDirBools, b]
  go dirNames ([], [])
  where
    go [] acc = pure acc
    go (e:es) (gs, ds) = do
      let gDir = dir </> e
      subEntries <- listDirectory gDir
      let mdFiles = [f | f <- subEntries, ".md" `T.isSuffixOf` T.pack f]
      decoded <- mapM (\f -> decodeAgentDef <$> TIO.readFile (gDir </> f)) mdFiles
      if any isJust decoded
        then go es (T.pack e : gs, ds)
        else go es (gs, e : ds)

-- | Decode all flat @.md@ files in the directory (top-level only).
collectFlat :: FilePath -> [FilePath] -> IO [AgentDef]
collectFlat dir entries = do
  let mdFiles = [e | e <- entries, ".md" `T.isSuffixOf` T.pack e]
  defs <- forM mdFiles $ \e -> do
    content <- TIO.readFile (dir </> e)
    pure (decodeAgentDef content)
  pure (catMaybes defs)

-- | Decode all @.md@ files one directory down (grouped layout), stamping
-- 'adGroup' from the parent directory when the frontmatter omitted it.
collectGrouped :: FilePath -> [Text] -> IO [AgentDef]
collectGrouped dir groups = do
  results <- forM groups $ \g -> do
    let gDir = dir </> T.unpack g
    entries <- listDirectory gDir
    let mdFiles = [e | e <- entries, ".md" `T.isSuffixOf` T.pack e]
    forM mdFiles $ \e -> do
      content <- TIO.readFile (gDir </> e)
      pure (stampGroup g (decodeAgentDef content))
  pure (concatMap catMaybes results)

-- | Load DirScheme defs from subdirectories, skipping ids already
-- provided by the flat or grouped scheme (flat/grouped wins on conflict).
-- Emits a warning per collision. @dirSchemeDirs@ is the pre-classified list
-- of DirScheme candidate subdirectory names.
collectDirs :: FilePath -> [FilePath] -> [AgentDefId] -> Set.Set Text -> IO [AgentDef]
collectDirs dir dirSchemeDirs flatIds _groupSet = do
  let flatIdTexts = Set.fromList (map agentDefIdText flatIds)
  defs <- forM dirSchemeDirs $ \e -> do
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

-- | Enumerate the immediate sub-directories of @dir@ (non-recursive, no
-- hidden dirs), sorted for deterministic output. Returns the visible
-- sub-directory names as 'Text'. Missing @dir@ yields @[]@. Mirrors
-- 'Seal.Skills.Backend.listSubdirs' but on local 'FilePath'.
listGroupSubdirs :: FilePath -> IO [Text]
listGroupSubdirs dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      entries <- listDirectory dir
      let visible = [e | e <- entries, not (T.isPrefixOf "." (T.pack e))]
      ds <- filterM (\e -> doesDirectoryExist (dir </> e)) (sortOn id visible)
      pure (map T.pack ds)

-- | Stamp 'adGroup' from the parent directory when the frontmatter omitted
-- it. Mirrors 'Seal.Skills.Backend.readAndStampGroup' / 'stampGroup'.
stampGroup :: Text -> Maybe AgentDef -> Maybe AgentDef
stampGroup g (Just d) = case adGroup d of
  Just _  -> Just d
  Nothing -> Just d { adGroup = Just g }
stampGroup _ Nothing = Nothing

-- | Read the first grouped @.md@ file that decodes, stamping its group.
-- Short-circuits on the first match.
firstMatchGrouped :: [(Text, FilePath)] -> IO (Maybe AgentDef)
firstMatchGrouped []       = pure Nothing
firstMatchGrouped ((g, p):ps) = do
  exists <- doesFileExist p
  if not exists
    then firstMatchGrouped ps
    else do
      content <- TIO.readFile p
      case stampGroup g (decodeAgentDef content) of
        Just d  -> pure (Just d)
        Nothing -> firstMatchGrouped ps

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