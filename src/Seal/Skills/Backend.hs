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
  , encodeSkill
  , decodeSkill
  ) where

import Control.Monad (forM)
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist, listDirectory, removeFile, renameFile)
import System.FilePath ((</>), (<.>))
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
-- directory); writes are atomic (tmp → chmod 0600 → rename) and auto-committed
-- to the config git repo. Reads enumerate the directory. Malformed files are
-- skipped (a partial write never breaks the list).
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

-- | The filename for a skill: @\<id\>.md@.
skillFile :: FilePath -> SkillId -> FilePath
skillFile dir sid = dir </> T.unpack (skillIdText sid) <.> "md"

-- | Encode a 'Skill' as a Markdown document (frontmatter + body).
-- Re-exported from 'Seal.Skills.Codec' for backward compatibility.
-- (See 'Seal.Skills.Codec' for the implementation.)

-- | Decode a Markdown document into a 'Skill'.
-- Re-exported from 'Seal.Skills.Codec' for backward compatibility.
-- (See 'Seal.Skills.Codec' for the implementation.)

-- | Write one skill to disk (atomic) and auto-commit.
writeSkill :: FilePath -> ConfigRepo -> Skill -> IO ()
writeSkill dir repo s = do
  let path = skillFile dir (skId s)
      tmp  = path <.> "tmp"
  TIO.writeFile tmp (encodeSkill s)
  setFileMode tmp 0o600
  renameFile tmp path
  let rel = "skills" </> (T.unpack (skillIdText (skId s)) <.> "md")
  _ <- gitCommitAll repo rel ("seal: SKILL write " <> skillIdText (skId s))
  pure ()

-- | Read one skill by id. Returns 'Nothing' if the file is absent or malformed.
readSkill :: FilePath -> SkillId -> IO (Maybe Skill)
readSkill dir sid = do
  let path = skillFile dir sid
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      content <- TIO.readFile path
      pure (decodeSkill content)

-- | Enumerate all skills in the directory, sorted by id. Malformed files are
-- skipped.
listSkills :: FilePath -> IO [Skill]
listSkills dir = do
  entries <- listDirectory dir
  let mdFiles = [e | e <- entries, ".md" `T.isSuffixOf` T.pack e]
  skills <- forM mdFiles $ \e -> do
    content <- TIO.readFile (dir </> e)
    pure (decodeSkill content)
  pure (sortOn (skillIdText . skId) (catMaybes skills))

-- | Delete one skill file and auto-commit. Idempotent (no-op if the file is
-- absent).
deleteSkill :: FilePath -> ConfigRepo -> SkillId -> IO ()
deleteSkill dir repo sid = do
  let path = skillFile dir sid
  exists <- doesFileExist path
  if not exists
    then pure ()
    else do
      removeFile path
      let rel = "skills" </> (T.unpack (skillIdText sid) <.> "md")
      _ <- gitCommitAll repo rel ("seal: SKILL delete " <> skillIdText sid)
      pure ()