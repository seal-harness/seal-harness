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
--
-- The /workdir-scoped/ discovery backend (for @.skills\/@ discovery from
-- cloned repos) operates over the 'WorkdirFs' handle via
-- 'workdirSkillBackendFs' (§3.6) — every workspace read goes through the
-- single SafePath-confined chokepoint. The user store
-- ('markdownSkillBackend', the @~\/.seal\/config\/skills\/@ reads) stays
-- local-FS (§3.9): it constructs a local-arm 'WorkdirFs' ('userDirFs') so
-- the read helpers share the single confined code path while remaining
-- local-FS. Writes ('writeSkill'\/'deleteSkill') are local-FS by design
-- (the user store is the model's write target).
module Seal.Skills.Backend
  ( SkillBackend (..)
  , noneBackend
  , markdownSkillBackend
  , unionSkillBackend
  , workdirSkillBackend
  , workdirSkillConventions
  , tripleUnionSkillBackend
  , encodeSkill
  , decodeSkill
  , listAgentSkillsDir
  , decodeAgentSkill
  , prefixWorkdirSkill
  ) where
import Control.Monad (forM, forM_, (<=<))
import Data.Either (fromRight)
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime (..))
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (secondsToDiffTime)
import System.Directory
  ( createDirectoryIfMissing, doesFileExist
  , removeFile, renameFile )
import System.FilePath (takeDirectory, (</>), (<.>))
import System.Posix.Files (setFileMode)

import Seal.Core.Types (mkSystemSessionId)
import Seal.Git.Repo (ConfigRepo, gitCommitAll)
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Skills.Codec (decodeSkill, encodeSkill)
import Seal.Skills.Builtins (builtinSkillMap)
import Seal.Skills.Types (Skill (..), SkillId (..), mkSkillId, skillIdText)
import Seal.Store.Markdown (decodeDoc, fmLookup)
import Seal.Text.LineFile (maxScanBytes)
import Seal.Tools.Exec.Types (RemotePath, mkRemotePath, getRemotePath)
import Seal.Tools.Exec.WorkdirFs (WorkdirFs (..), mkLocalWorkdirFs)
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
        let userMap = Map.fromList [(skId s, s) | s <- userSkills]
            merged = Map.union userMap builtinSkillMap
        pure (Map.elems merged)
    , sbUpdate = sbUpdate user
    , sbDelete = sbDelete user
    }

-- | The conventional skill directories a cloned repo may carry, checked in
-- order per repo. The first match per convention wins (a repo should only
-- use one). Top-level only — no recursion into the repo.
--
-- @.skills@ follows the [agentskills.io](https://agentskills.io)
-- specification: each subdirectory contains a @SKILL.md@ file with YAML
-- frontmatter (@name@, @description@) + Markdown body. The other
-- @.agents\/skills@ also uses the agentskills.io format (it is the skills
-- sub-directory of the [.agents Protocol](https://dotagentsprotocol.com)).
-- The other conventions use Seal's native flat/grouped @.md@ layout.
workdirSkillConventions :: [FilePath]
workdirSkillConventions = [ ".skills", ".agents/skills", ".seal/skills", ".claude/skills", "agents/skills" ]

-- | A local 'WorkdirFs' anchored at the user store's skills directory. The
-- read helpers ('listTopLevelSkills', 'listGroupedSkills', 'readAndStampGroup',
-- 'listSubdirs') operate over 'WorkdirFs'; the user store constructs a
-- local-arm 'WorkdirFs' at its @dir@ so the reads share the single confined
-- code path (§3.6) while remaining local-FS (§3.9). Mirrors
-- 'Seal.Agent.Def.Backend.userDirFs'.
userDirFs :: FilePath -> WorkdirFs
userDirFs dir = mkLocalWorkdirFs (WorkspaceRoot dir) maxScanBytes

-- | A read-only 'SkillBackend' that scans a session workdir for skills
-- shipped by cloned repositories. For each top-level directory in the
-- workdir (a cloned repo), it checks the conventional skill locations
-- (@.skills\/@, @.agents\/skills\/@, @.seal\/skills\/@,
-- @.claude\/skills\/@, @agents\/skills\/@)
-- and loads any skills there. The @.skills@ and @.agents\/skills@
-- conventions use the agentskills.io directory-based format
-- (@\<name\>\/SKILL.md@); the others
-- use Seal's native flat/grouped @.md@ layout.
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
--
-- Every workspace read goes through the 'WorkdirFs' handle (symlink-escape
-- confinement — §3.8; single chokepoint, §3.6) and is size-capped at
-- 'maxScanBytes'.
workdirSkillBackend :: WorkdirFs -> IO SkillBackend
workdirSkillBackend fs = pure SkillBackend
    { sbCreate = \_ -> pure ()
    , sbRead   = \sid -> do
        skills <- listWorkdirSkills fs
        pure (Map.lookup sid (Map.fromList [(skId s, s) | s <- skills]))
    , sbList   = listWorkdirSkills fs
    , sbUpdate = \_ -> pure ()
    , sbDelete = \_ -> pure ()
    }

-- | Enumerate every skill found under the conventional locations across
-- all top-level directories (cloned repos) in the workdir anchored at the
-- 'WorkdirFs'. The alphabetically-first repo wins on id collisions
-- (deterministic). Missing or empty workdirs yield @[]@.
--
-- For the @.skills@ and @.agents\/skills@ conventions, skills are loaded from the agentskills.io
-- directory format (each subdirectory contains a @SKILL.md@). For the
-- other conventions, skills are loaded from Seal's native flat/grouped
-- @.md@ layout.
listWorkdirSkills :: WorkdirFs -> IO [Skill]
listWorkdirSkills fs = do
  exists <- wfsDoesDirectoryExist fs =<< rpOrDie "."
  if not exists
    then pure []
    else do
      eDirs <- wfsListDirectory fs =<< rpOrDie "."
      let dirs = visibleSubdirs (fromRight [] eDirs)
      perRepo <- forM dirs $ \repo -> do
        raw <- concat <$> forM workdirSkillConventions (\conv -> do
          let convRp = repo <> "/" <> T.pack conv
          cExists <- wfsDoesDirectoryExist fs =<< rpOrDie convRp
          if not cExists
            then pure []
            else if conv `elem` [".skills", ".agents/skills"]
                   then do
                     -- agentskills.io format: subdirectories with SKILL.md
                     let subFs = reanchorFs fs convRp
                     agentSkills <- listAgentSkillsDir subFs
                     pure (catMaybes agentSkills)
                   else do
                     -- Seal native format: flat/grouped .md files
                     let subFs = reanchorFs fs convRp
                     x <- listTopLevelSkills subFs
                     y <- listGroupedSkills subFs
                     pure (catMaybes (x ++ y)))
        -- Stamp each repo-local skill with a group derived from the repo
        -- directory name so the <available_skills> catalog groups them
        -- under a "<repo> project skills" heading.
        pure (mapMaybe (prefixWorkdirSkill repo . stampProjectGroup repo) raw)
      let merge m [] = m
          merge m (s:ss) = merge (Map.insertWith (\_new old -> old) (skId s) s m) ss
          merged = merge Map.empty (concat perRepo)
      pure (Map.elems merged)

-- | The visible (non-hidden) immediate subdirectory names from a
-- 'wfsListDirectory' listing, sorted for deterministic output.
visibleSubdirs :: [Text] -> [Text]
visibleSubdirs = sortOn id . filter (not . T.isPrefixOf ".")

-- | Stamp a repo-local skill's 'skGroup' with @"\<repo\> project skills"@
-- so the @\<available_skills\>@ catalog groups them under a per-repo
-- heading. A skill that already has a group (e.g. from the native grouped
-- layout) keeps its existing group — only ungrouped skills are stamped.
-- This mirrors how 'readAndStampGroup' fills 'skGroup' from the on-disk
-- directory for user-store skills.
stampProjectGroup :: Text -> Skill -> Skill
stampProjectGroup repo s = case skGroup s of
  Just g | not (T.null (T.strip g)) -> s
  _ -> s { skGroup = Just (repo <> " project skills") }

-- | Prefix a workdir-discovered skill's id with @\<repo\>--\<id\>@ so it
-- never collides with a user-store skill of the same name (mirrors the
-- agent-def pattern in 'Seal.Agent.Def.Backend.prefixWorkdirDef'). The
-- @--@ separator is charset-safe per 'isValidSkillId'. If the prefixed id
-- fails validation (e.g. the repo dir has a char outside the charset),
-- the skill is dropped ('Nothing' — fail-closed).
prefixWorkdirSkill :: Text -> Skill -> Maybe Skill
prefixWorkdirSkill repo s =
  let prefixedIdText = repo <> "--" <> skillIdText (skId s)
  in case mkSkillId prefixedIdText of
       Left _ -> Nothing
       Right sid -> Just s { skId = sid }

-- | A three-way union of a workdir backend (repo-local skills), a user
-- backend, and the built-in skills. Workdir skill ids are namespaced
-- (@\<repo\>--\<id\>@) so they never collide with user skills by design.
-- On id collisions between user and built-in, user shadows built-in.
-- Reads check workdir first, then user, then the built-in map. Listing
-- merges all three with the same precedence. Writes go to the /user/
-- backend only (repo and built-in skills are immutable from the model's
-- perspective).
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
            merged = Map.union wdMap (Map.union userMap builtinSkillMap)
        pure (Map.elems merged)
    , sbUpdate = sbUpdate user
    , sbDelete = sbDelete user
    }

-- | The filename for a skill in the flat layout: @\<id\>.md@.
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

-- | Read one skill by id. Probes, in order: the native grouped layout
-- (@\<group\>\/\<id\>.md@), the agentskills.io grouped layout
-- (@\<group\>\/\<id\>\/SKILL.md@), the native flat layout
-- (@\<id\>.md@), then the agentskills.io top-level layout
-- (@\<id\>\/SKILL.md@). Returns 'Nothing' if no file is found or every
-- candidate is malformed. The returned skill's 'skGroup' is filled from the
-- directory when the frontmatter omitted it (the common case), so a grouped
-- file reads back as grouped regardless of whether its frontmatter
-- redundantly declares a group.
--
-- The reads go through the 'WorkdirFs' handle (via 'userDirFs') so they
-- share the single confined code path (§3.6) while remaining local-FS.
readSkill :: FilePath -> SkillId -> IO (Maybe Skill)
readSkill root sid = do
  let fs = userDirFs root
      base = skillIdText sid <> ".md"
      dir = skillIdText sid
  groups <- listSubdirs fs
  let nativeGrouped   = [ readAndStampGroup fs (g <> "/" <> base) (Just g) | g <- groups ]
      agentGrouped    = [ readAgentSkillAt fs (g <> "/" <> dir) (Just g) | g <- groups ]
      nativeFlat      = readAndStampGroup fs base Nothing
      agentTop        = readAgentSkillAt fs dir Nothing
  firstMatchM (nativeGrouped ++ agentGrouped ++ [nativeFlat, agentTop])

-- | Read a skill file at @\<anchor\>\/\<rel\>@ (via the 'WorkdirFs') and,
-- if it decodes, fill in 'skGroup' from the directory when the frontmatter
-- omitted one. @mGroup@ is the group implied by the file's location
-- ('Nothing' for the flat layout). @rel@ is a relative 'RemotePath' under
-- the 'WorkdirFs' anchor.
readAndStampGroup :: WorkdirFs -> Text -> Maybe Text -> IO (Maybe Skill)
readAndStampGroup fs rel mGroup = do
  eContent <- wfsReadFile fs =<< rpOrDie rel
  case eContent of
    Left _ -> pure Nothing
    Right content -> case decodeSkill content of
      Nothing -> pure Nothing
      Just s  -> pure (Just (stampGroup s))
  where
    stampGroup s = case skGroup s of
      Just _  -> s
      Nothing -> s { skGroup = mGroup }

-- | Enumerate the immediate sub-directories of the 'WorkdirFs' anchor
-- (non-recursive, no hidden dirs), sorted for deterministic output.
-- Returns the visible sub-directory names as 'Text' (suitable for building
-- relative 'RemotePath's). Missing anchor yields @[]@.
listSubdirs :: WorkdirFs -> IO [Text]
listSubdirs fs = do
  eEntries <- wfsListDirectory fs =<< rpOrDie "."
  let entries = fromRight [] eEntries
      visible = [e | e <- entries, not (T.isPrefixOf "." e)]
  filterM' (wfsDoesDirectoryExist fs <=< rpOrDie) (sortOn id visible)

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
-- back-compat) plus @.md@ files one directory down (grouped layout), plus
-- agentskills.io @\<name\>\/SKILL.md@ skills at both levels (top-level and
-- @\<group\>\/\<name\>\/SKILL.md@). Malformed files are skipped (a partial
-- write never breaks the list). Each skill's 'skGroup' is filled from its
-- directory when the frontmatter omitted one. Results are sorted by id for
-- deterministic output.
--
-- The reads go through the 'WorkdirFs' handle (via 'userDirFs') so they
-- share the single confined code path (§3.6) while remaining local-FS.
listSkills :: FilePath -> IO [Skill]
listSkills dir = do
  let fs = userDirFs dir
  topNative   <- listTopLevelSkills fs
  grouped     <- listGroupedSkills fs
  agentTop    <- listTopLevelAgentSkills fs
  agentGrouped <- listGroupedAgentSkills fs
  pure (sortOn (skillIdText . skId) (catMaybes (topNative ++ grouped ++ agentTop ++ agentGrouped)))

-- | Read the flat-layout skills: @.md@ files directly under the 'WorkdirFs'
-- anchor. Returns one 'Maybe Skill' per file (the outer list, not the inner
-- Maybe, is the collection; 'Nothing' marks a malformed file to be
-- 'catMaybes'-filtered).
listTopLevelSkills :: WorkdirFs -> IO [Maybe Skill]
listTopLevelSkills fs = do
  eEntries <- wfsListDirectory fs =<< rpOrDie "."
  let entries = fromRight [] eEntries
      mdFiles = [e | e <- entries, ".md" `T.isSuffixOf` e]
  forM mdFiles $ \e -> readAndStampGroup fs e Nothing

-- | Read the grouped-layout skills: for each subdirectory @g@, read the
-- @.md@ files under @g/@ and stamp 'skGroup' = @Just g@ when the
-- frontmatter omitted one. Results from all groups are concatenated.
listGroupedSkills :: WorkdirFs -> IO [Maybe Skill]
listGroupedSkills fs = do
  groups <- listSubdirs fs
  results <- forM groups $ \g -> do
    let subFs = reanchorFs fs g
    eEntries <- wfsListDirectory subFs =<< rpOrDie "."
    let entries = fromRight [] eEntries
        mdFiles = [e | e <- entries, ".md" `T.isSuffixOf` e]
    forM mdFiles $ \e -> readAndStampGroup fs (g <> "/" <> e) (Just g)
  pure (concat results)

-- | Read the agentskills.io skills at the top level: each immediate
-- subdirectory @\<name\>@ of the anchor that contains a @SKILL.md@. The
-- skill id comes from the @name@ frontmatter field (the spec requires it to
-- match the directory name); the group is 'Nothing' (top-level skills are
-- ungrouped, matching the flat native layout). Malformed skills are
-- skipped ('Nothing').
listTopLevelAgentSkills :: WorkdirFs -> IO [Maybe Skill]
listTopLevelAgentSkills fs = do
  subdirs <- listSubdirs fs
  forM subdirs $ \subdir -> readAgentSkillAt fs subdir Nothing

-- | Read the agentskills.io skills within Seal group directories: for each
-- group @g@, each immediate subdirectory @\<name\>@ under @g/@ that contains
-- a @SKILL.md@ is decoded and stamped with 'skGroup' = @'Just' g@ when the
-- frontmatter omitted one. Results from all groups are concatenated. This
-- composes the Seal grouped-layout convention with the agentskills.io
-- per-skill directory convention (@\<group\>\/\<name\>\/SKILL.md@).
listGroupedAgentSkills :: WorkdirFs -> IO [Maybe Skill]
listGroupedAgentSkills fs = do
  groups <- listSubdirs fs
  results <- forM groups $ \g -> do
    let subFs = reanchorFs fs g
    subdirs <- listSubdirs subFs
    forM subdirs $ \subdir -> readAgentSkillAt fs (g <> "/" <> subdir) (Just g)
  pure (concat results)

-- | Delete one skill file and auto-commit. Idempotent (no-op if the file is
-- absent). Searches both the grouped and flat layouts: a skill written
-- under a group is deleted from its group directory; a flat-layout skill
-- is deleted from the root. If a file exists in both, both are removed.
--
-- This is a user-store /write/ operation: it stays on local 'FilePath'
-- ('removeFile', 'doesFileExist') — 'WorkdirFs' is a read-only discovery
-- handle. The group enumeration ('listSubdirs') goes through the
-- 'WorkdirFs' handle (via 'userDirFs') so the read path stays unified.
deleteSkill :: FilePath -> ConfigRepo -> SkillId -> IO ()
deleteSkill dir repo sid = do
  let fs = userDirFs dir
      base = T.unpack (skillIdText sid) <.> "md"
  groups <- listSubdirs fs
  let groupedPaths = [ dir </> T.unpack g </> base | g <- groups ]
      flatPath     = skillFile dir sid
  candidates <- filterM' doesFileExist (groupedPaths ++ [flatPath])
  forM_ candidates $ \path -> do
    removeFile path
    let rel = "skills" </> fromMaybe base (stripRoot dir path)
    _ <- gitCommitAll repo rel ("seal: SKILL delete " <> skillIdText sid)
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

----------------------------------------------------------------------------
-- agentskills.io format support
----------------------------------------------------------------------------

-- | Enumerate skills in agentskills.io directory format: each subdirectory
-- of the 'WorkdirFs' anchor contains a @SKILL.md@ file with YAML frontmatter
-- (@name@, @description@) + Markdown body. Returns one 'Maybe Skill' per
-- subdirectory ('Nothing' for malformed/missing @SKILL.md@). The skill id
-- is taken from the @name@ frontmatter field (which the spec requires to
-- match the parent directory name). The skill group is set to 'Nothing'
-- (agentskills.io has no group concept; the directory name IS the id).
listAgentSkillsDir :: WorkdirFs -> IO [Maybe Skill]
listAgentSkillsDir fs = do
  subdirs <- listSubdirs fs
  forM subdirs $ \subdir -> readAgentSkillAt fs subdir Nothing

-- | Read a @\<dir\>\/SKILL.md@ agentskills.io skill relative to a
-- 'WorkdirFs' anchor, decoding it and stamping 'skGroup' = @mGroup@ when
-- the frontmatter omitted one (mirrors 'readAndStampGroup' for the native
-- codec). Returns 'Nothing' when the subdirectory has no @SKILL.md@ or the
-- file fails to decode. Used by both the workdir scanner
-- ('listAgentSkillsDir') and the user-store auto-detection
-- ('listTopLevelAgentSkills' \/ 'listGroupedAgentSkills').
readAgentSkillAt :: WorkdirFs -> Text -> Maybe Text -> IO (Maybe Skill)
readAgentSkillAt fs dir mGroup = do
  let subFs = reanchorFs fs dir
  mdExists <- wfsDoesFileExist subFs =<< rpOrDie "SKILL.md"
  if not mdExists
    then pure Nothing
    else do
      eContent <- wfsReadFile subFs =<< rpOrDie "SKILL.md"
      case eContent of
        Left _   -> pure Nothing
        Right c -> pure (stampGroup (decodeAgentSkillWithGroup mGroup c))
  where
    stampGroup (Just s) = case skGroup s of
      Just _  -> Just s
      Nothing -> Just s { skGroup = mGroup }
    stampGroup Nothing = Nothing

-- | Decode an agentskills.io @SKILL.md@ file into a 'Skill'. The frontmatter
-- uses @name@ (required, maps to 'skId') and @description@ (required, maps to
-- 'skDescription'). The body after the frontmatter becomes 'skBody'.
-- Timestamps default to epoch zero (repo-local skills have no provenance
-- timestamps). The session is set to a system "manual" session (matching
-- the DirScheme agent def pattern). The 'skGroup' is set to the supplied
-- stamp ('Nothing' for a top-level agentskills.io skill; @'Just' g@ for one
-- discovered under a Seal group directory).
decodeAgentSkill :: Text -> Maybe Skill
decodeAgentSkill = decodeAgentSkillWithGroup Nothing

-- | The general form of 'decodeAgentSkill' that pre-stamps 'skGroup'. Used
-- internally so the user-store grouped scanner can fill the group from the
-- on-disk directory (mirroring 'readAndStampGroup' for the native codec).
decodeAgentSkillWithGroup :: Maybe Text -> Text -> Maybe Skill
decodeAgentSkillWithGroup mGroup content =
  case decodeDoc content of
    (fm, body) -> do
      nameT <- fmLookup "name" fm
      sid  <- either (const Nothing) Just (mkSkillId nameT)
      Just Skill
        { skId = sid
        , skDescription = fromMaybe "" (fmLookup "description" fm)
        , skBody = body
        , skGroup = mGroup
        , skCreatedAt = agentSkillEpoch
        , skUpdatedAt = agentSkillEpoch
        , skSession = mkSystemSessionId "manual"
        }
  where
    agentSkillEpoch = UTCTime (fromGregorian 1970 1 1) (secondsToDiffTime 0)

----------------------------------------------------------------------------
-- WorkdirFs re-anchoring + RemotePath helpers (internal)
----------------------------------------------------------------------------

-- | Produce a 'WorkdirFs' "view" anchored at a sub-directory of the original
-- anchor. Every 'wfs*' call on the re-anchored handle prepends @prefix@ to
-- the supplied 'RemotePath'. Works for both the local and remote arms (no
-- new constructor — pure record wrapper). The prefix is a relative path
-- (e.g. @"my-repo\/.skills"@); the join uses @\/@ as the separator.
-- (Mirrors 'Seal.Agent.Def.Workdir.reanchorFs'.)
reanchorFs :: WorkdirFs -> Text -> WorkdirFs
reanchorFs fs prefix = WorkdirFs
  { wfsReadFile            = wfsReadFile fs            <=< joinRp prefix
  , wfsDoesFileExist       = wfsDoesFileExist fs       <=< joinRp prefix
  , wfsDoesDirectoryExist  = wfsDoesDirectoryExist fs  <=< joinRp prefix
  , wfsListDirectory       = wfsListDirectory fs       <=< joinRp prefix
  , wfsFileSize            = wfsFileSize fs            <=< joinRp prefix
  , wfsModificationTime    = wfsModificationTime fs    <=< joinRp prefix
  }

-- | Join a prefix and a (possibly @"\. "@) relative 'RemotePath' into a single
-- 'RemotePath'. A @"\. "@ suffix collapses to the prefix (so re-anchoring at
-- @"\. "@ is the identity). Crashes on invalid input — the prefix/suffix
-- are internally generated from validated components, never user/LLM input.
joinRp :: Text -> RemotePath -> IO RemotePath
joinRp prefix rp' =
  let suffix = getRemotePath rp'
      joined
        | T.null prefix            = suffix
        | suffix == "."            = prefix
        | T.isPrefixOf "./" suffix = prefix <> "/" <> T.drop 2 suffix
        | otherwise                = prefix <> "/" <> suffix
  in case mkRemotePath joined of
       Right r  -> pure r
       Left err -> error ("joinRp: invalid remote path: " <> T.unpack err
                          <> ": " <> T.unpack joined)

-- | Construct a 'RemotePath', crashing on invalid input. Used only for
-- internally-generated, validated path components (never user/LLM input).
rpOrDie :: Text -> IO RemotePath
rpOrDie t = case mkRemotePath t of
  Right r  -> pure r
  Left err -> error ("rpOrDie: invalid remote path: " <> T.unpack err
                     <> ": " <> T.unpack t)
