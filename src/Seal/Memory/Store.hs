{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BlockArguments #-}
-- | The file-based memory store. Memory files live as plain text (no
-- frontmatter) under @\<root\>\/active\/\<path\>.md@. Archived memories live
-- under @\<root\>\/archived\/\<dir\>\/\<timestamp\>-\<filename\>.md@.
--
-- The store is write-once: 'msWrite' fails if the file already exists in
-- @active\/@. To update a fact, archive the old memory ('msArchive') then
-- write the new one. Files are never deleted — archive is a move.
--
-- No git auto-commit. The store manages its own immutability via the
-- write-once + archive model. The 'fileMemoryStore' is the production
-- backend; 'noneMemoryStore' is an in-memory backend for tests.
module Seal.Memory.Store
  ( MemoryStore (..)
  , fileMemoryStore
  , noneMemoryStore
  ) where

import Control.Monad (forM)
import Data.IORef
import Data.List (sortOn, isInfixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe, catMaybes)
import Data.Either (rights)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , doesDirectoryExist
  , listDirectory
  , renameFile
  )
import System.FilePath
  ( (</>)
  , (<.>)
  , takeDirectory
  , takeFileName
  )

import Seal.Memory.Path

-- | The memory store capability. Each operation is IO.
data MemoryStore = MemoryStore
  { msWrite   :: MemoryPath -> Text -> IO (Either Text ())
    -- ^ Write a new memory file. Fails if the path already exists in active/.
  , msRead    :: MemoryPath -> IO (Either Text (Text, Bool))
    -- ^ Read a memory by path. Returns (content, isArchived).
    --   Falls back to archived/ if not in active/.
  , msList    :: Text -> Bool -> IO [MemoryPath]
    -- ^ List memory paths matching a prefix. includeArchived flag.
  , msArchive :: MemoryPath -> IO (Either Text MemoryPath)
    -- ^ Move active/<path> to archived/<path>/<timestamp>-<filename>.
  , msSearch :: Text -> Bool -> IO [(MemoryPath, Text)]
    -- ^ Substring search over memory content. Returns (path, content) pairs.
    --   includeArchived flag.
  }

-- | The on-disk file extension for memory files.
mdExt :: FilePath
mdExt = ".md"

-- | Convert a 'MemoryPath' to a relative 'FilePath' with .md extension.
pathToFile :: MemoryPath -> FilePath
pathToFile mp =
  T.unpack (T.intercalate "/" (memoryPathSegments mp)) <.> mdExt

-- | Format a UTC timestamp as @YYYYMMDDThhmmssZ@.
formatTimestamp :: UTCTime -> String
formatTimestamp = formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ"

-- | The production disk-backed memory store. @root@ is the memory root
-- (e.g. @~\/.seal\/memory@). Files live under @root\/active\/@ and
-- @root\/archived\/@.
fileMemoryStore :: FilePath -> IO MemoryStore
fileMemoryStore root = do
  let activeDir   = root </> "active"
      archivedDir = root </> "archived"
  createDirectoryIfMissing True activeDir
  createDirectoryIfMissing True archivedDir
  pure MemoryStore
    { msWrite = \mp content -> do
        let relPath = pathToFile mp
            absPath = activeDir </> relPath
        exists <- doesFileExist absPath
        if exists
          then pure (Left ("memory already exists: " <> memoryPathText mp))
          else do
            let dir = takeDirectory absPath
            createDirectoryIfMissing True dir
            -- Atomic write: temp file in the same directory, then rename.
            let tmp = absPath <.> "tmp"
            TIO.writeFile tmp content
            renameFile tmp absPath
            pure (Right ())
    , msRead = \mp -> do
        let relPath = pathToFile mp
            activePath = activeDir </> relPath
        activeExists <- doesFileExist activePath
        if activeExists
          then do
            content <- TIO.readFile activePath
            pure (Right (content, False))
          else do
            -- Fall back to archived/: walk the archived tree for a file
            -- matching the path (by filename suffix, since archived files
            -- have a timestamp prefix).
            mArchived <- findArchived archivedDir mp
            case mArchived of
              Just archivedPath -> do
                content <- TIO.readFile archivedPath
                pure (Right (content, True))
              Nothing -> pure (Left ("memory not found: " <> memoryPathText mp))
    , msList = \prefix includeArchived -> do
        activeEntries <- listTree activeDir
        archivedEntries <-
          if includeArchived
            then listTree archivedDir
            else pure []
        -- For archived entries, strip the timestamp prefix from the filename
        -- so the path matches what the agent would use.
        let activePaths = mapMaybe (relPathToMemoryPath activeDir) activeEntries
            archivedPaths = mapMaybe (archivedRelPathToMemoryPath archivedDir) archivedEntries
            allPaths = activePaths <> archivedPaths
            filtered = filter (matchesPrefix prefix) allPaths
        pure (sortOn memoryPathText filtered)
    , msArchive = \mp -> do
        let relPath = pathToFile mp
            activePath = activeDir </> relPath
        exists <- doesFileExist activePath
        if not exists
          then pure (Left ("memory not found: " <> memoryPathText mp))
          else do
            now <- getCurrentTime
            let ts = formatTimestamp now
                filename = takeFileName relPath
                archivedFilename = ts <> "-" <> filename
                -- Preserve the directory hierarchy under archived/.
                dirPart = takeDirectory relPath
                archivedRelPath =
                  if dirPart == "."
                    then archivedFilename
                    else dirPart </> archivedFilename
                archivedAbsPath = archivedDir </> archivedRelPath
            createDirectoryIfMissing True (takeDirectory archivedAbsPath)
            renameFile activePath archivedAbsPath
            -- The archived path as a MemoryPath (with timestamp prefix).
            -- We construct it from the relative path under archived/.
            let archivedMP = case mkMemoryPath (T.pack archivedRelPath) of
                  Right p  -> p
                  Left _   -> mp  -- fallback (shouldn't happen)
            pure (Right archivedMP)
    , msSearch = \query includeArchived -> do
        activeEntries <- listTree activeDir
        archivedEntries <-
          if includeArchived
            then listTree archivedDir
            else pure []
        let activePaths = mapMaybe (relPathToMemoryPath activeDir) activeEntries
            archivedPaths = mapMaybe (archivedRelPathToMemoryPath archivedDir) archivedEntries
        activeResults <- mapM (readAndFilter activeDir query) activePaths
        archivedResults <-
          if includeArchived
            then mapM (readAndFilterArchived query) (zip (map (archivedDir </>) archivedEntries) archivedPaths)
            else pure []
        pure (catMaybes activeResults <> catMaybes archivedResults)
    }
  where
    -- Recursively list all files under a directory, returning relative paths.
    listTree :: FilePath -> IO [FilePath]
    listTree dir = do
      entries <- listDirectory dir
      concat <$> forM entries \entry -> do
        let absEntry = dir </> entry
        isFile <- doesFileExist absEntry
        if isFile
          then pure [entry]
          else do
            subEntries <- listTree absEntry
            pure (map (entry </>) subEntries)

    -- Convert a relative file path (from listTree) to a MemoryPath by
    -- stripping the .md extension.
    relPathToMemoryPath :: FilePath -> FilePath -> Maybe MemoryPath
    relPathToMemoryPath _baseDir relPath = do
      -- Strip .md extension
      let withoutExt = if mdExt `isInfixOf` relPath
                         then take (length relPath - length mdExt) relPath
                         else relPath
      either (const Nothing) Just (mkMemoryPath (T.pack withoutExt))

    -- Like relPathToMemoryPath but strips the timestamp prefix from the
    -- filename (e.g. "20260919T143000Z-tz.md" → "tz").
    archivedRelPathToMemoryPath :: FilePath -> FilePath -> Maybe MemoryPath
    archivedRelPathToMemoryPath _baseDir relPath = do
      let filename = takeFileName relPath
          dirPart = takeDirectory relPath
          -- Strip timestamp prefix: everything up to and including the first "-"
          strippedFilename = case dropWhile (/= '-') filename of
            ""       -> filename
            (_:rest)  -> rest  -- drop the '-' itself
          withoutExt = if mdExt `isInfixOf` strippedFilename
                         then take (length strippedFilename - length mdExt) strippedFilename
                         else strippedFilename
          -- Reconstruct the path without the timestamp
          newPath = if dirPart == "."
                      then withoutExt
                      else dirPart </> withoutExt
      either (const Nothing) Just (mkMemoryPath (T.pack newPath))

    -- Check if a MemoryPath matches a prefix.
    matchesPrefix :: Text -> MemoryPath -> Bool
    matchesPrefix prefix mp =
      T.null prefix || prefix `T.isPrefixOf` memoryPathText mp

    -- Read a memory file and return (path, content) if the query is a
    -- substring of the content (case-insensitive). 'Nothing' if no match.
    readAndFilter :: FilePath -> Text -> MemoryPath -> IO (Maybe (MemoryPath, Text))
    readAndFilter baseDir query mp = do
      let relPath = pathToFile mp
          absPath = baseDir </> relPath
      exists <- doesFileExist absPath
      if not exists
        then pure Nothing
        else do
          content <- TIO.readFile absPath
          if query `T.isInfixOf` T.toCaseFold content
            then pure (Just (mp, content))
            else pure Nothing

    -- Like 'readAndFilter' but reads from an explicit archived path.
    readAndFilterArchived :: Text -> (FilePath, MemoryPath) -> IO (Maybe (MemoryPath, Text))
    readAndFilterArchived query (absPath, mp) = do
      exists <- doesFileExist absPath
      if not exists
        then pure Nothing
        else do
          content <- TIO.readFile absPath
          if query `T.isInfixOf` T.toCaseFold content
            then pure (Just (mp, content))
            else pure Nothing

-- | Find an archived file matching the given memory path. Archived files
-- have a timestamp prefix, so we walk the directory tree and match by
-- filename suffix.
findArchived :: FilePath -> MemoryPath -> IO (Maybe FilePath)
findArchived archivedDir mp = do
  let relPath = pathToFile mp
      dirPart = takeDirectory relPath
      filename = takeFileName relPath
      searchDir = if dirPart == "."
                    then archivedDir
                    else archivedDir </> dirPart
  dirExists <- doesDirectoryExist searchDir
  if not dirExists
    then pure Nothing
    else do
      entries <- listDirectory searchDir
      let candidates = [e | e <- entries, e /= takeFileName relPath, matchArchived filename e]
      case candidates of
        (match:_) -> pure (Just (searchDir </> match))
        []        -> pure Nothing
  where
    -- Match an archived filename (with timestamp prefix) against the
    -- original filename. E.g. "20260919T143000Z-tz.md" matches "tz.md".
    matchArchived original archived =
      let stripped = case dropWhile (/= '-') archived of
            ""       -> archived
            (_:rest)  -> rest
      in stripped == original

-- | The in-memory store for tests. Uses IORefs to track active and
-- archived memories.
noneMemoryStore :: IO MemoryStore
noneMemoryStore = do
  activeRef   <- newIORef (Map.empty :: Map Text Text)
  archivedRef <- newIORef (Map.empty :: Map Text Text)
  pure MemoryStore
    { msWrite = \mp content -> do
        let key = memoryPathText mp
        active <- readIORef activeRef
        if Map.member key active
          then pure (Left ("memory already exists: " <> key))
          else do
            modifyIORef' activeRef (Map.insert key content)
            pure (Right ())
    , msRead = \mp -> do
        let key = memoryPathText mp
        active <- readIORef activeRef
        case Map.lookup key active of
          Just content -> pure (Right (content, False))
          Nothing -> do
            archived <- readIORef archivedRef
            case Map.lookup key archived of
              Just content -> pure (Right (content, True))
              Nothing      -> pure (Left ("memory not found: " <> key))
    , msList = \prefix includeArchived -> do
        active <- readIORef activeRef
        archived <- readIORef archivedRef
        let activePaths = map fst (Map.toAscList active)
            archivedPaths = map fst (Map.toAscList archived)
            allPaths = activePaths <> (if includeArchived then archivedPaths else [])
            filtered = filter (prefix `T.isPrefixOf`) allPaths
        pure (rights (map mkMemoryPath filtered))
    , msArchive = \mp -> do
        let key = memoryPathText mp
        active <- readIORef activeRef
        case Map.lookup key active of
          Nothing -> pure (Left ("memory not found: " <> key))
          Just content -> do
            modifyIORef' activeRef (Map.delete key)
            modifyIORef' archivedRef (Map.insert key content)
            pure (Right mp)
    , msSearch = \query includeArchived -> do
        active <- readIORef activeRef
        archived <- readIORef archivedRef
        let activeResults = [ (mp, c)
                            | (k, c) <- Map.toAscList active
                            , query `T.isInfixOf` T.toCaseFold c
                            , Right mp <- [mkMemoryPath k] ]
            archivedResults = [ (mp, c)
                              | includeArchived
                              , (k, c) <- Map.toAscList archived
                              , query `T.isInfixOf` T.toCaseFold c
                              , Right mp <- [mkMemoryPath k] ]
        pure (activeResults <> archivedResults)
    }
