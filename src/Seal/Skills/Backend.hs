{-# LANGUAGE OverloadedStrings #-}
-- | The skill store backend. Disk is canonical: skills live as Markdown files
-- under @config\/skills\/\<id\>.md@ (frontmatter + body). 'markdownSkillBackend'
-- reads by enumerating the directory and writes by atomic file replace +
-- auto-commit to the config git repo. 'noneBackend' (in-memory) is kept for
-- tests.
--
-- The git repo is the versioning + audit layer; model-authored writes
-- (@SKILL_CREATE@ \/ @SKILL_UPDATE@, which are Trusted file writes) auto-commit.
-- Human file-drops are committed by the human via @git -C ~/.seal/config@.
module Seal.Skills.Backend
  ( SkillBackend (..)
  , noneBackend
  , markdownSkillBackend
  , unionSkillBackend
  , workdirSkillBackend
  , tripleUnionSkillBackend
  , encodeSkill
  , decodeSkill
  ) where

import Control.Monad (forM, forM_)
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
  ( createDirectoryIfMissing, doesDirectoryExist, doesFileExist
  , listDirectory, removeFile, renameFile )
import System.FilePath (takeDirectory, (</>), (<.>))
import System.Posix.Files (setFileMode)

import Seal.Git.Repo (ConfigRepo, gitCommitAll)
import Seal.Skills.Builtins (builtinSkillMap)
import Seal.Skills.Codec (decodeSkill, encodeSkill)
import Seal.Skills.Types (Skill (..), SkillId (..), skillIdText)

-- | The skill store capability. Each operation is IO (the Markdown backend
-- writes to disk + git); 'sbList' returns all skills sorted by id.
data SkillBackend = SkillBackend
  { sbCreate :: Skill -> IO ()
  -- ^ Insert or replace a skill by id (writes the file + auto-commits).
  , sbRead   :: SkillId -> IO (Maybe Skill)
  -- ^ Fetch one skill by id (reads its file).
  , sbList   :: IO [Skill]
  -- ^ All skills, sorted by id (deterministic for tests + git diffs).
  , sbUpdate :: Skill -> IO ()
  -- ^ Update an existing skill (same as 'sbCreate' for both backends).
  , sbDelete :: SkillId -> IO ()
  -- ^ Remove a skill by id (delete the file + auto-commit; idempotent).
  }

-- | The in-memory backend: a single 'IORef' over a 'Map'. Used by tests.
-- Kept as a fallback when no config repo is available.
noneBackend :: IO SkillBackend
noneBackend = do
  ref <- newIORef (Map.empty :: Map SkillId Skill)
  pure SkillBackend
    { sbCreate = \s -> modifyIORef' ref (Map.insert (skId s) s)
    , sbRead   = \sid -> Map.lookup sid <$> readIORef ref
    , sbList   = Map.elems <$> readIORef ref
    , sbUpdate = \s -> modifyIORef' ref (Map.insert (skId s) s)
    , sbDelete = modifyIORef' ref . Map.delete
    }

-- | The Markdown backend. One file per skill under @dir@ (the @config/skills@
-- directory), either flat (@\<id\>.md@) or grouped (@\<group\>\/\<id\>.md@).
-- Writes are atomic (tmp → chmod 0600 → rename) and auto-committed to the
-- config git repo. Reads enumerate the directory (both layouts).
-- Malformed files are skipped (a partial write never breaks the list).
markdownSkillBackend :: FilePath -> ConfigRepo -> IO SkillBackend
markdownSkillBackend dir repo = pure SkillBackend
    { sbCreate = writeSkill dir repo
    , sbRead   = readSkill dir
    , sbList   = listSkills dir
    , sbUpdate = writeSkill dir repo
    , sbDelete = deleteSkill dir repo
    }

-- | A read-layer union of a user 'SkillBackend' (the on-disk
-- @~/.seal/config/skills/@ store) and the embedded built-in skills
-- ('Seal.Skills.Builtins.builtinSkills'). Reads check the user layer first
-- and fall back to the built-in; listing merges both, with the user copy
-- winning on id collisions (so a user override shadows the built-in).
-- Writes ('sbCreate'/'sbUpdate'/'sbDelete') go to the user layer only —
-- built-ins are immutable from the model's perspective.
--
-- This is what makes Seal self-contained: the @seal-usage@ orientation
-- skill is always present (shipped in the binary), and a user can override
-- it by dropping @~/.seal/config/skills/seal-usage.md@. After a Seal
-- upgrade, the user diffs their override against the new built-in (visible
-- via @sbList@) and merges manually — no forced overwrites, no staleness.
unionSkillBackend :: SkillBackend -> SkillBackend
unionSkillBackend user = SkillBackend
    { sbCreate = sbCreate user
    , sbRead   = \sid -> do
        mUser <- sbRead user sid
        case mUser of
          Just s  -> pure (Just s)
          Nothing -> pure (Map.lookup sid builtinSkillMap)
    , sbList   = do
        userSkills <- sbList user
        -- User skills keyed by id; built-in entries fill in the ids the
        -- user hasn't overridden. Sorted by id for deterministic output.
        let userMap = Map.fromList [(skId s, s) | s <- userSkills]
            merged = Map.union userMap builtinSkillMap
        pure (Map.elems merged)
    , sbUpdate = sbUpdate user
    , sbDelete = sbDelete user
    }

-- | The conventional skill directories a cloned repo may carry, checked in
-- order per repo. The first match per convention wins (a repo should only
-- use one). Top-level only — no recursion into the repo.
workdirSkillConventions :: [FilePath]
workdirSkillConventions = [ ".seal/skills", ".claude/skills", "agents/skills" ]

-- | A read-only 'SkillBackend' that scans a session workdir for skills
-- shipped by cloned repositories. For each top-level directory in the
-- workdir (a cloned repo), it checks the conventional skill locations
-- (@.seal\/skills\/@, @.claude\/skills\/@, @agents\/skills\/@) and loads
-- any skills there (using the grouped-layout enumeration from
-- 'listSkills'). Skills are stamped with 'skGroup' from their subdirectory
-- as usual.
--
-- This backend is /read-only/: 'sbCreate'/'sbUpdate'/'sbDelete' are no-ops
-- (repo-local skills are immutable from the model's perspective — the
-- model writes skills to its user store via 'SKILL_WRITE', never into a
-- cloned repo). 'sbRead' scans on every call (workdirs are small and the
-- catalog is built once per turn); a future optimization could cache per
-- session.
--
-- Within-workdir collisions (two repos ship a skill with the same id):
-- the alphabetically-first repo wins (deterministic; the operator can
-- control precedence by renaming a repo clone directory).
workdirSkillBackend :: FilePath -> IO SkillBackend
workdirSkillBackend workdir = pure SkillBackend
    { sbCreate = \_ -> pure ()
    , sbRead   = \sid -> do
        skills <- listWorkdirSkills workdir
        pure (Map.lookup sid (Map.fromList [(skId s, s) | s <- skills]))
    , sbList   = listWorkdirSkills workdir
    , sbUpdate = \_ -> pure ()
    , sbDelete = \_ -> pure ()
    }

-- | Enumerate every skill found under the conventional locations across
-- all top-level directories (cloned repos) in @workdir@. The
-- alphabetically-first repo wins on id collisions (deterministic). Missing
-- @workdir@ or empty workdirs yield @[]@.
listWorkdirSkills :: FilePath -> IO [Skill]
listWorkdirSkills workdir = do
  exists <- doesDirectoryExist workdir
  if not exists
    then pure []
    else do
      -- Top-level dirs only (each is a cloned repo); listSubdirs already
      -- filters hidden dirs and sorts, so the alphabetical-first repo
      -- wins on id collisions.
      dirs <- listSubdirs workdir
      -- For each repo dir, gather skills from every convention.
      perRepo <- forM dirs $ \repo -> do
        let repoDir = workdir </> repo
        concat <$> forM workdirSkillConventions (\conv -> do
          let convDir = repoDir </> conv
          cExists <- doesDirectoryExist convDir
          if not cExists
            then pure []
            else do
              x <- listTopLevelSkills convDir
              y <- listGroupedSkills convDir
              pure (catMaybes (x ++ y)))
      -- Merge with alphabetical-first-repo-wins: insert left-to-right,
      -- keeping the existing entry on collision (Map.insertWith const old).
      let merge m [] = m
          merge m (s:ss) = merge (Map.insertWith (\_new old -> old) (skId s) s m) ss
          merged = merge Map.empty (concat perRepo)
      pure (Map.elems merged)

-- | A three-way union of a workdir backend (repo-local skills), a user
-- backend, and the built-in skills. 'workdir-wins' on id collisions:
-- workdir shadows user, user shadows built-in. Reads check workdir first,
-- then user, then the built-in map. Listing merges all three with the
-- same precedence. Writes go to the /user/ backend only (repo and
-- built-in skills are immutable from the model's perspective).
--
-- This is the backend wired into per-turn prompt construction so the
-- @\<available_skills\>@ catalog and @SKILL_LOAD@ surface repo-local
-- skills discovered by 'SETUP_REPO' (and the user store, and built-ins).
tripleUnionSkillBackend :: SkillBackend -> SkillBackend -> SkillBackend
tripleUnionSkillBackend workdir user = SkillBackend
    { sbCreate = sbCreate user
    , sbRead   = \sid -> do
        mWd <- sbRead workdir sid
        case mWd of
          Just s  -> pure (Just s)
          Nothing -> do
            mUser <- sbRead user sid
            case mUser of
              Just s  -> pure (Just s)
              Nothing -> pure (Map.lookup sid builtinSkillMap)
    , sbList   = do
        wdSkills <- sbList workdir
        userSkills <- sbList user
        let wdMap   = Map.fromList [(skId s, s) | s <- wdSkills]
            userMap = Map.fromList [(skId s, s) | s <- userSkills]
            -- workdir wins (Map.union is left-biased), then user wins
            -- over built-in.
            merged = Map.union wdMap (Map.union userMap builtinSkillMap)
        pure (Map.elems merged)
    , sbUpdate = sbUpdate user
    , sbDelete = sbDelete user
    }

-- | The filename for a skill in the flat layout: @\<id\>.md@. Used for
-- 'sbRead' (which must probe both the flat and grouped layouts, since a
-- skill's group may not be known at read time).
skillFile :: FilePath -> SkillId -> FilePath
skillFile dir sid = dir </> T.unpack (skillIdText sid) <.> "md"

-- | The full path for a skill write, honoring its group. A grouped skill
-- lives at @\<root\>\/\<group\>\/\<id\>.md@; an ungrouped skill (or one
-- whose group is empty) lives at @\<root\>\/\<id\>.md@ (back-compat with
-- the flat layout). The group directory is created on write.
skillPath :: FilePath -> Skill -> FilePath
skillPath root skill =
  case skGroup skill of
    Just g | not (T.null (T.strip g)) ->
      root </> T.unpack (T.strip g) </> T.unpack (skillIdText (skId skill)) <.> "md"
    _ -> skillFile root (skId skill)

-- | Encode a 'Skill' as a Markdown document (frontmatter + body).
-- Re-exported from 'Seal.Skills.Codec' for backward compatibility.
-- (See 'Seal.Skills.Codec' for the implementation.)

-- | Decode a Markdown document into a 'Skill'.
-- Re-exported from 'Seal.Skills.Codec' for backward compatibility.
-- (See 'Seal.Skills.Codec' for the implementation.)

-- | Write one skill to disk (atomic) and auto-commit. Honors 'skGroup':
-- a grouped skill is written under @\<root\>\/\<group\>\/\<id\>.md@ (the
-- group directory is created if absent); an ungrouped skill is written
-- flat at @\<root\>\/\<id\>.md@. The git commit path is relative to the
-- config repo root and encodes the group when present.
writeSkill :: FilePath -> ConfigRepo -> Skill -> IO ()
writeSkill root repo s = do
  let path = skillPath root s
      tmp  = path <.> "tmp"
      parent = takeDirectory path
  createDirectoryIfMissing True parent
  TIO.writeFile tmp (encodeSkill s)
  setFileMode tmp 0o600
  renameFile tmp path
  let rel = "skills" </> case skGroup s of
        Just g | not (T.null (T.strip g)) ->
          T.unpack (T.strip g) </> (T.unpack (skillIdText (skId s)) <.> "md")
        _ -> T.unpack (skillIdText (skId s)) <.> "md"
  _ <- gitCommitAll repo rel ("seal: SKILL write " <> skillIdText (skId s))
  pure ()

-- | Read one skill by id. Probes the grouped layout first (searching each
-- group subdirectory), then falls back to the flat layout
-- (@\<root\>\/\<id\>.md@) for back-compat. Returns 'Nothing' if no file is
-- found or every candidate is malformed. The returned skill's 'skGroup' is
-- filled from the directory when the frontmatter omitted it (the common
-- case), so a grouped file reads back as grouped regardless of whether its
-- frontmatter redundantly declares a group.
readSkill :: FilePath -> SkillId -> IO (Maybe Skill)
readSkill root sid = do
  -- 1. Probe group subdirectories (grouped layout).
  groups <- listSubdirs root
  found <- firstMatchM [ readAndStampGroup root (g </> base) (Just (T.pack g))
                       | g <- groups ]
  -- 2. Fall back to the flat layout.
  case found of
    Just s  -> pure (Just s)
    Nothing -> readAndStampGroup root base Nothing
  where
    base = T.unpack (skillIdText sid) <.> "md"

-- | Read a skill file at @root/rel@ and, if it decodes, fill in 'skGroup'
-- from the directory when the frontmatter omitted one. @mGroup@ is the
-- group implied by the file's location ('Nothing' for the flat layout).
readAndStampGroup :: FilePath -> FilePath -> Maybe Text -> IO (Maybe Skill)
readAndStampGroup root rel mGroup = do
  let path = root </> rel
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      content <- TIO.readFile path
      case decodeSkill content of
        Nothing -> pure Nothing
        Just s  -> pure (Just (stampGroup s))
  where
    -- Fill skGroup from the directory when the frontmatter didn't set one.
    stampGroup s = case skGroup s of
      Just _  -> s                      -- frontmatter wins
      Nothing -> s { skGroup = mGroup }

-- | Enumerate the immediate subdirectories of @dir@ (non-recursive, no
-- hidden dirs), sorted for deterministic output.
listSubdirs :: FilePath -> IO [FilePath]
listSubdirs dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      entries <- listDirectory dir
      let visible = [e | e <- entries, not ("." `isPrefixOfStr` e)]
      filterM' (doesDirectoryExist . (dir </>)) (sortOn id visible)
  where
    isPrefixOfStr p s = take (length p) s == p

-- | Like 'Control.Monad.filterM' but without the import (kept local to
-- avoid widening the module's import surface for one call site).
filterM' :: (a -> IO Bool) -> [a] -> IO [a]
filterM' _ []     = pure []
filterM' f (x:xs) = do
  ok <- f x
  rest <- filterM' f xs
  pure (if ok then x : rest else rest)

-- | Return the first 'Just' in a list of IO actions, short-circuiting.
firstMatchM :: [IO (Maybe a)] -> IO (Maybe a)
firstMatchM []       = pure Nothing
firstMatchM (a:as)   = do
  m <- a
  case m of
    Just x  -> pure (Just x)
    Nothing -> firstMatchM as

-- | Enumerate all skills in @dir@: top-level @.md@ files (flat layout,
-- back-compat) plus @.md@ files one directory down (grouped layout).
-- Malformed files are skipped (a partial write never breaks the list).
-- Each skill's 'skGroup' is filled from its directory when the frontmatter
-- omitted one. Results are sorted by id for deterministic output.
listSkills :: FilePath -> IO [Skill]
listSkills dir = do
  topLevels <- listTopLevelSkills dir
  grouped   <- listGroupedSkills dir
  pure (sortOn (skillIdText . skId) (catMaybes (topLevels ++ grouped)))

-- | Read the flat-layout skills: @.md@ files directly under @dir@. Returns
-- one 'Maybe Skill' per file (the outer list, not the inner Maybe, is the
-- collection; 'Nothing' marks a malformed file to be 'catMaybes'-filtered).
listTopLevelSkills :: FilePath -> IO [Maybe Skill]
listTopLevelSkills dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      entries <- listDirectory dir
      let mdFiles = [e | e <- entries, ".md" `T.isSuffixOf` T.pack e]
      forM mdFiles $ \e -> readAndStampGroup dir e Nothing

-- | Read the grouped-layout skills: for each subdirectory @g@, read the
-- @.md@ files under @g/@ and stamp 'skGroup' = @Just g@ when the
-- frontmatter omitted one. Results from all groups are concatenated.
listGroupedSkills :: FilePath -> IO [Maybe Skill]
listGroupedSkills dir = do
  groups <- listSubdirs dir
  results <- forM groups $ \g -> do
    let gdir = dir </> g
    entries <- listDirectory gdir
    let mdFiles = [e | e <- entries, ".md" `T.isSuffixOf` T.pack e]
    forM mdFiles $ \e -> readAndStampGroup dir (g </> e) (Just (T.pack g))
  pure (concat results)

-- | Delete one skill file and auto-commit. Idempotent (no-op if the file is
-- absent). Searches both the grouped and flat layouts: a skill written
-- under a group is deleted from its group directory; a flat-layout skill
-- is deleted from the root. If a file exists in both, both are removed.
deleteSkill :: FilePath -> ConfigRepo -> SkillId -> IO ()
deleteSkill dir repo sid = do
  -- Search grouped subdirs first, then the flat path. Delete every match
  -- (a skill should only exist in one place, but we clean up any orphans).
  groups <- listSubdirs dir
  let groupedPaths = [ dir </> g </> base | g <- groups ]
      flatPath     = skillFile dir sid
      base         = T.unpack (skillIdText sid) <.> "md"
  candidates <- filterM' doesFileExist (groupedPaths ++ [flatPath])
  forM_ candidates $ \path -> do
    removeFile path
    -- Compute the repo-relative path for the commit message context.
    let rel = "skills" </> fromMaybe base (stripRoot dir path)
    _ <- gitCommitAll repo rel ("seal: SKILL delete " <> skillIdText sid)
    pure ()
  where
    -- Strip the skills-root prefix from a path for the git rel path.
    stripRoot r p =
      let r' = dropTrailingSlash r
          p' = dropTrailingSlash p
      in if r' `isPrefixPath` p'
           then Just (drop (length r' + 1) p')
           else Nothing
    dropTrailingSlash = reverse . dropWhile (== '/') . reverse
    isPrefixPath pre s = take (length pre) s == pre