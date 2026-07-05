{-# LANGUAGE OverloadedStrings #-}
-- | The memory store backend. Disk is canonical: memory entries live as
-- Markdown files under @config\/memory\/\<id\>.md@ (frontmatter + body, where
-- the body is the memory content and tags/created/updated/session live in
-- frontmatter). 'markdownMemoryBackend' reads by enumerating the directory
-- and writes by atomic file replace + auto-commit; delete removes the file and
-- commits. 'noneBackend' (in-memory) is kept for tests.
--
-- The git repo is the versioning + audit layer; model-authored writes
-- (@MEMORY_STORE@ \/ @MEMORY_UPDATE@ \/ @MEMORY_DELETE@, which are Trusted
-- file writes) auto-commit.
module Seal.Memory.Backend
  ( MemoryBackend (..)
  , noneBackend
  , markdownMemoryBackend
  , encodeMemory
  , decodeMemory
  ) where

import Control.Monad (forM)
import Data.Aeson (Value (..), encode)
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime (..))
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (secondsToDiffTime)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import Data.Vector qualified as V
import System.Directory (doesFileExist, listDirectory, removeFile, renameFile)
import System.FilePath ((</>), (<.>))
import System.Posix.Files (setFileMode)

import Seal.Core.Types (SessionId (..))
import Seal.Git.Repo (ConfigRepo, gitCommitAll)
import Seal.Memory.Types (MemoryEntry (..), MemoryId (..), mkMemoryId, memoryIdText)
import Seal.Store.Markdown (decodeDoc, encodeDoc, fmLookup, fmLookupList)

-- | The memory store capability. Each operation is IO (the Markdown backend
-- writes to disk + git); 'mbList' returns all memories sorted by id.
data MemoryBackend = MemoryBackend
  { mbStore  :: MemoryEntry -> IO ()
  , mbRecall :: MemoryId -> IO (Maybe MemoryEntry)
  , mbList   :: IO [MemoryEntry]
  , mbUpdate :: MemoryEntry -> IO ()
  , mbDelete :: MemoryId -> IO ()
  }

-- | The in-memory backend: a single 'IORef' over a 'Map'. Used by tests.
noneBackend :: IO MemoryBackend
noneBackend = do
  ref <- newIORef (Map.empty :: Map MemoryId MemoryEntry)
  pure MemoryBackend
    { mbStore  = \e -> modifyIORef' ref (Map.insert (meId e) e)
    , mbRecall = \mid -> Map.lookup mid <$> readIORef ref
    , mbList   = Map.elems <$> readIORef ref
    , mbUpdate = \e -> modifyIORef' ref (Map.insert (meId e) e)
    , mbDelete = modifyIORef' ref . Map.delete
    }

-- | The Markdown backend. One file per memory under @dir@ (the
-- @config/memory@ directory); writes are atomic (tmp → chmod 0600 → rename)
-- and auto-committed to the config git repo; delete removes the file and
-- commits. Reads enumerate the directory. Malformed files are skipped.
markdownMemoryBackend :: FilePath -> ConfigRepo -> IO MemoryBackend
markdownMemoryBackend dir repo = pure MemoryBackend
  { mbStore  = writeMemory dir repo
  , mbRecall = readMemory dir
  , mbList   = listMemories dir
  , mbUpdate = writeMemory dir repo
  , mbDelete = deleteMemory dir repo
  }

-- | The filename for a memory: @\<id\>.md@.
memoryFile :: FilePath -> MemoryId -> FilePath
memoryFile dir mid = dir </> T.unpack (memoryIdText mid) <.> "md"

-- | Encode a 'MemoryEntry' as a Markdown document (frontmatter + body, where
-- the body is the memory content).
encodeMemory :: MemoryEntry -> Text
encodeMemory e = encodeDoc fm (meContent e)
  where
    fm = Map.fromList
      [ ("id", memoryIdText (meId e))
      , ("tags", renderTags (meTags e))
      , ("created_at", isoTime (meCreatedAt e))
      , ("updated_at", isoTime (meUpdatedAt e))
      , ("session", sessionIdText (meSession e))
      ]
    sessionIdText (SessionId t) = t

-- | Decode a Markdown document into a 'MemoryEntry'. Returns 'Nothing' if the
-- id field is missing or fails 'mkMemoryId'.
decodeMemory :: Text -> Maybe MemoryEntry
decodeMemory content =
  case decodeDoc content of
    (fm, body) -> do
      midT <- fmLookup "id" fm
      mid  <- either (const Nothing) Just (mkMemoryId midT)
      Just MemoryEntry
        { meId = mid
        , meContent = body
        , meTags = fromMaybe [] (fmLookupList "tags" fm)
        , meCreatedAt = parseTime (fmLookup "created_at" fm)
        , meUpdatedAt = parseTime (fmLookup "updated_at" fm)
        , meSession = SessionId (fromMaybe "unknown" (fmLookup "session" fm))
        }

-- | Write one memory to disk (atomic) and auto-commit.
writeMemory :: FilePath -> ConfigRepo -> MemoryEntry -> IO ()
writeMemory dir repo e = do
  let path = memoryFile dir (meId e)
      tmp  = path <.> "tmp"
  TIO.writeFile tmp (encodeMemory e)
  setFileMode tmp 0o600
  renameFile tmp path
  let rel = "memory" </> (T.unpack (memoryIdText (meId e)) <.> "md")
  _ <- gitCommitAll repo rel ("seal: MEMORY write " <> memoryIdText (meId e))
  pure ()

-- | Read one memory by id. Returns 'Nothing' if the file is absent or malformed.
readMemory :: FilePath -> MemoryId -> IO (Maybe MemoryEntry)
readMemory dir mid = do
  let path = memoryFile dir mid
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      content <- TIO.readFile path
      pure (decodeMemory content)

-- | Enumerate all memories in the directory, sorted by id. Malformed files
-- are skipped.
listMemories :: FilePath -> IO [MemoryEntry]
listMemories dir = do
  entries <- listDirectory dir
  let mdFiles = [e | e <- entries, ".md" `T.isSuffixOf` T.pack e]
  mems <- forM mdFiles $ \e -> do
    content <- TIO.readFile (dir </> e)
    pure (decodeMemory content)
  pure (sortOn (memoryIdText . meId) (catMaybes mems))

-- | Delete one memory file and auto-commit. Idempotent.
deleteMemory :: FilePath -> ConfigRepo -> MemoryId -> IO ()
deleteMemory dir repo mid = do
  let path = memoryFile dir mid
  exists <- doesFileExist path
  if not exists
    then pure ()
    else do
      removeFile path
      let rel = "memory" </> (T.unpack (memoryIdText mid) <.> "md")
      _ <- gitCommitAll repo rel ("seal: MEMORY delete " <> memoryIdText mid)
      pure ()

-- | Render the tags list as a JSON array string for the frontmatter line.
renderTags :: [Text] -> Text
renderTags ts = TE.decodeUtf8 (BL.toStrict (encode (V.fromList (map String ts))))

-- | Render a 'UTCTime' as an ISO-8601 string (UTC, with @Z@ suffix).
isoTime :: UTCTime -> Text
isoTime = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

-- | Parse an ISO-8601 'UTCTime' from a frontmatter value. Defaults to epoch 0
-- when absent or unparseable.
parseTime :: Maybe Text -> UTCTime
parseTime Nothing    = epochZero
parseTime (Just raw) = fromMaybe epochZero (parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (T.unpack raw))

-- | The epoch fallback for missing/unparseable timestamps.
epochZero :: UTCTime
epochZero = UTCTime (fromGregorian 1970 1 1) (secondsToDiffTime 0)