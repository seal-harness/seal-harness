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
  , encodeSkill
  , decodeSkill
  ) where

import Control.Monad (forM)
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime (..))
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (secondsToDiffTime)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import System.Directory (doesFileExist, listDirectory, renameFile)
import System.FilePath ((</>), (<.>))
import System.Posix.Files (setFileMode)

import Seal.Core.Types (SessionId (..))
import Seal.Git.Repo (ConfigRepo, gitCommitAll)
import Seal.Skills.Types (Skill (..), SkillId (..), mkSkillId, skillIdText)
import Seal.Store.Markdown (decodeDoc, encodeDoc, fmLookup)

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
  }

-- | The filename for a skill: @\<id\>.md@.
skillFile :: FilePath -> SkillId -> FilePath
skillFile dir sid = dir </> T.unpack (skillIdText sid) <.> "md"

-- | Encode a 'Skill' as a Markdown document (frontmatter + body).
encodeSkill :: Skill -> Text
encodeSkill s = encodeDoc fm (skBody s)
  where
    fm = Map.fromList
      [ ("id", skillIdText (skId s))
      , ("description", skDescription s)
      , ("created_at", isoTime (skCreatedAt s))
      , ("updated_at", isoTime (skUpdatedAt s))
      , ("session", sessionIdText (skSession s))
      ]
    sessionIdText (SessionId t) = t

-- | Decode a Markdown document into a 'Skill'. Returns 'Nothing' if the id
-- field is missing or fails 'mkSkillId'. Timestamps default to epoch 0 when
-- absent or unparseable (the file was hand-edited without them).
decodeSkill :: Text -> Maybe Skill
decodeSkill content =
  case decodeDoc content of
    (fm, body) -> do
      sidT <- fmLookup "id" fm
      sid  <- either (const Nothing) Just (mkSkillId sidT)
      Just Skill
        { skId = sid
        , skDescription = fromMaybe "" (fmLookup "description" fm)
        , skBody = body
        , skCreatedAt = parseTime (fmLookup "created_at" fm)
        , skUpdatedAt = parseTime (fmLookup "updated_at" fm)
        , skSession = SessionId (fromMaybe "unknown" (fmLookup "session" fm))
        }

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

-- | Render a 'UTCTime' as an ISO-8601 string (UTC, with @Z@ suffix).
isoTime :: UTCTime -> Text
isoTime = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

-- | Parse an ISO-8601 'UTCTime' from a frontmatter value. Defaults to epoch 0
-- when absent or unparseable (hand-edited files).
parseTime :: Maybe Text -> UTCTime
parseTime Nothing    = epochZero
parseTime (Just raw) = fromMaybe epochZero (parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (T.unpack raw))

-- | The epoch fallback for missing/unparseable timestamps.
epochZero :: UTCTime
epochZero = UTCTime (fromGregorian 1970 1 1) (secondsToDiffTime 0)