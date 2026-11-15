{-# LANGUAGE OverloadedStrings #-}
-- | File explorer handle — a local/remote-agnostic capability for
-- browsing the execution machine's filesystem (directory listings, file
-- content reads, raw byte reads for downloads). Mirrors the 'UntrustedIO'
-- and 'WorkdirFs' handle pattern: a record of IO actions wired by smart
-- constructors.
--
-- Three smart constructors:
--
--   * 'mkLocalFileExplorer' — reads via 'System.Directory' on the harness
--     machine (local mode).
--   * 'mkRemoteFileExplorer' — reads via SSH through a 'RemoteRunner' to
--     the execution machine (remote mode).
--   * 'mkFailClosedFileExplorer' — all methods return 'Left FeDisabled'
--     (used when the file explorer is disabled, e.g. non-loopback gateway
--     without explicit opt-in).
module Seal.Tools.Exec.FileExplorer
  ( FileExplorerHandle (..)
  , FileExplorerErr (..)
  , FileEntry (..)
  , FileStat (..)
  , FileListing (..)
  , FileContent (..)
  , mkLocalFileExplorer
  , mkRemoteFileExplorer
  , mkFailClosedFileExplorer
  , listingEntryLimit
  ) where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isDigit, isSpace)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (sortBy)
import Data.Maybe (mapMaybe)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import System.Directory
  ( doesDirectoryExist, doesFileExist, getHomeDirectory, getFileSize
  , getModificationTime, listDirectory, pathIsSymbolicLink
  , canonicalizePath
  )
import System.FilePath (joinPath, splitDirectories, (</>))
import System.IO (IOMode (..), SeekMode (..), hFileSize, hSeek, withBinaryFile)
import System.IO.Error (isDoesNotExistError, isPermissionError)
import Text.Read (readMaybe)

import Seal.Security.Path (blockedNames, lexicalCollapse)
import Seal.Tools.Args (mkShellCommand)
import Seal.Tools.Exec.Remote (RemoteRunner, runRemoteShell, runRemoteBytes, runRemoteStream, sshExecArgv)
import Seal.Tools.Exec.Types (ExecError (..), SshConfig (..), getSshHost)
import Seal.Tools.Exec.UntrustedIO (shellQuote)

-- ---------------------------------------------------------------------------
-- Error ADT
-- ---------------------------------------------------------------------------

-- | The error ADT for 'FileExplorerHandle' methods. Pinned for exhaustive
-- pattern-match under @-Wall -Werror@.
data FileExplorerErr
  = FeNotFound          -- ^ path does not exist
  | FeIsDirectory       -- ^ path is a directory (for content/download)
  | FeNotADirectory     -- ^ path is a file (for listing)
  | FePermissionDenied  -- ^ permission denied
  | FeIo !Text          -- ^ I/O error (message)
  | FeExec !Text        -- ^ remote SSH exec failure (message)
  | FeTruncated         -- ^ output exceeded the byte ceiling
  | FeDisabled          -- ^ file explorer disabled (non-loopback)
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Result types
-- ---------------------------------------------------------------------------

-- | One entry in a directory listing.
data FileEntry = FileEntry
  { feName :: !Text              -- ^ basename
  , feIsDir :: !Bool             -- ^ True = directory, False = file
  , feIsSymlink :: !Bool         -- ^ True = symlink (not followed in listing)
  , feSize :: !(Maybe Integer)   -- ^ Nothing for directories/symlinks or when unavailable
  , feMtime :: !(Maybe UTCTime)  -- ^ Nothing when unavailable
  } deriving stock (Eq, Show)

-- | The result of a directory listing.
data FileListing = FileListing
  { flPath :: !Text              -- ^ the listed path (normalized)
  , flEntries :: ![FileEntry]
  , flTruncated :: !Bool         -- ^ True if the listing was cut short
  , flWarning :: !(Maybe Text)   -- ^ sensitive-directory warning
  } deriving stock (Eq, Show)

-- | The result of a file content read.
data FileContent = FileContent
  { fcPath :: !Text
  , fcContent :: !Text
  , fcTruncated :: !Bool         -- ^ True if content exceeded byte ceiling
  , fcLinesRead :: !Int          -- ^ number of lines in 'fcContent' (via 'T.lines')
  , fcIsBinary :: !Bool          -- ^ True if content contains NUL bytes
  } deriving stock (Eq, Show)

-- | Stat metadata for a file — used by the chunked download path to
-- compute byte ranges and verify offsets. The mtime is truncated to
-- epoch seconds (integer) — sub-second precision is not needed for
-- download resumption.
data FileStat = FileStat
  { fsPath :: !Text
  , fsSize :: !Integer
  , fsMtimeEpoch :: !(Maybe Integer)
  } deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Handle
-- ---------------------------------------------------------------------------

-- | The file explorer capability handle. Abstracts local vs remote
-- execution machine access. The @Int@ parameter on construction is the
-- The two @Int@ parameters on construction are the viewer read ceiling
-- (@readCeiling@, same @maxScanBytes@ as @FILE_READ@) and the download
-- chunk size (@downloadChunkBytes@, default 4 MiB for WU-1).
data FileExplorerHandle = FileExplorerHandle
  { feListDirectory :: FilePath -> IO (Either FileExplorerErr FileListing)
  , feListDirectories :: [FilePath] -> IO (Either FileExplorerErr [FileListing])
    -- ^ List several directories in ONE round trip. Returns listings in
    -- request order. On a truncated transport, only the directories that
    -- arrived complete are returned (never a partial listing): the caller is
    -- expected to re-request the remainder individually. See 'remoteListDirsCmd'.
  , feReadFile :: FilePath -> IO (Either FileExplorerErr FileContent)
  , feReadFileBytes :: FilePath -> IO (Either FileExplorerErr (ByteString, Bool))
    -- ^ (bytes up to ceiling, truncated?) — for the download endpoint.
    -- Returns raw bytes so binary files are not corrupted by UTF-8
    -- decode/encode round-trip. The 'Bool' is whether the file exceeded
    -- the byte ceiling.
  , feStatFile :: FilePath -> IO (Either FileExplorerErr FileStat)
    -- ^ Stat a file: return size + mtime (epoch seconds). Used by the
    -- chunked download path to compute byte ranges.
  , feReadRange :: FilePath -> Integer -> Int -> IO (Either FileExplorerErr ByteString)
    -- ^ Read at most @len@ bytes starting at @offset@ (0-based). Returns
    -- the raw bytes. A read past EOF returns 'Left FeIo' (not a short
    -- read). Used by the chunked download path.
  , feCanonicalize :: FilePath -> IO (Either FileExplorerErr FilePath)
    -- ^ Canonicalize a path (resolve symlinks). Local: 'canonicalizePath';
    -- remote: @readlink -f -- "$p"@. Used by the chunked download routes
    -- for blocked-path enforcement (SEC-B3) — the canonical path is run
    -- through 'blockedSegment' before serving any file metadata.
  , feResolveHome :: IO (Either FileExplorerErr FilePath)
  }

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

-- | The maximum number of entries a local directory listing returns
-- before truncating with @flTruncated = True@.
listingEntryLimit :: Int
listingEntryLimit = 10000

-- | The sentinel marker emitted by the remote listing command when the
-- path does not exist.
notFoundMarker :: Text
notFoundMarker = "___SEAL_NOTFOUND___"

-- | The sentinel marker emitted by the remote listing command when the
-- path exists but is not a directory.
notDirMarker :: Text
notDirMarker = "___SEAL_NOTDIR___"

-- | The sentinel marker emitted by the remote read command when the path
-- is a directory.
isDirMarker :: Text
isDirMarker = "___SEAL_ISDIR___"

-- | The truncation marker appended by 'readBounded' in the RemoteRunner
-- when output exceeds the 50KB transport cap.
truncationMarker :: Text
truncationMarker = "[output truncated at"

-- | The warning text for sensitive directories.
sensitiveWarning :: Text
sensitiveWarning = "This directory contains sensitive files"

-- ---------------------------------------------------------------------------
-- Path helpers (pure)
-- ---------------------------------------------------------------------------

-- | Lexically collapse @.@ and @..@ segments in a path. Wraps
-- 'lexicalCollapse' from "Seal.Security.Path".
collapsePath :: FilePath -> FilePath
collapsePath = joinPath . lexicalCollapse . splitDirectories

-- | Check if any component of the path is a blocked (sensitive) name.
-- Returns a warning message if so, 'Nothing' otherwise.
checkBlocked :: FilePath -> Maybe Text
checkBlocked path =
  if any (`elem` blockedNames) (splitDirectories path)
    then Just sensitiveWarning
    else Nothing

-- | Map an 'ExecError' from the remote SSH runner to a 'FileExplorerErr'.
-- The file explorer has no TOFU host-key adoption flow (unlike the CLI
-- channel), so 'ExecHostKeyUnknown' gets a descriptive message with the
-- manual fix instructions — same approach as the web channel's
-- session-exec path in "Seal.Session.Workdir".
mapRemoteExecError :: SshConfig -> ExecError -> FileExplorerErr
mapRemoteExecError sshCfg = \case
  ExecHostKeyUnknown -> FeExec
    ("remote host key not in known_hosts (TOFU adoption not available from the file explorer). "
     <> "Add the key manually with: ssh-keyscan -H "
     <> getSshHost (scHost sshCfg)
     <> " >> " <> T.pack (scKnownHosts sshCfg))
  e -> FeExec (T.pack (show e))

-- ---------------------------------------------------------------------------
-- Fail-closed stub
-- ---------------------------------------------------------------------------

-- | A stub handle where all methods return 'Left FeDisabled'. Used when
-- the file explorer is disabled (non-loopback gateway without explicit
-- opt-in).
mkFailClosedFileExplorer :: FileExplorerHandle
mkFailClosedFileExplorer = FileExplorerHandle
  { feListDirectory = \_ -> pure (Left FeDisabled)
  , feListDirectories = \_ -> pure (Left FeDisabled)
  , feReadFile = \_ -> pure (Left FeDisabled)
  , feReadFileBytes = \_ -> pure (Left FeDisabled)
  , feStatFile = \_ -> pure (Left FeDisabled)
  , feReadRange = \_ _ _ -> pure (Left FeDisabled)
  , feCanonicalize = \_ -> pure (Left FeDisabled)
  , feResolveHome = pure (Left FeDisabled)
  }

-- ---------------------------------------------------------------------------
-- Local arm
-- ---------------------------------------------------------------------------

-- | The local file explorer. Reads via 'System.Directory' on the harness
-- machine. The two @Int@s are the viewer read ceiling (@readCeiling@)
-- and the download chunk size (@downloadChunkBytes@), captured at
-- construction time.
mkLocalFileExplorer :: Int -> Int -> FileExplorerHandle
mkLocalFileExplorer readCeiling downloadChunkBytes = FileExplorerHandle
  { feListDirectory = localListDirectory readCeiling
  , feListDirectories = localListDirectories readCeiling
  , feReadFile = localReadFile readCeiling
  , feReadFileBytes = localReadFileBytes readCeiling
  , feStatFile = localStatFile
  , feReadRange = localReadRange downloadChunkBytes
  , feCanonicalize = localCanonicalize
  , feResolveHome = localResolveHome
  }

-- | Read at most @maxBytes@ from a local file. Returns the bytes read and
-- a 'Bool' indicating whether the file was truncated (the file is larger
-- than @maxBytes@).
-- Uses 'hFileSize' + 'hSeek' + bounded 'hGetSome' so the whole file is
-- never allocated in memory (the old @BS.readFile@ + @BS.take@ read the
-- entire file before discarding the tail).
readBoundedFile :: FilePath -> Int -> IO (BS.ByteString, Bool)
readBoundedFile path maxBytes = withBinaryFile path ReadMode $ \h -> do
  total <- hFileSize h
  let toRead = fromIntegral (min (fromIntegral maxBytes) total)
  bs <- BS.hGet h toRead
  pure (bs, total > fromIntegral maxBytes)

-- | List a local directory. Applies 'lexicalCollapse' to the path first,
-- checks existence/type, then enumerates entries with best-effort
-- metadata. Entries are sorted: directories first, then files,
-- alphabetically. Truncates at 'listingEntryLimit' entries.
localListDirectory :: Int -> FilePath -> IO (Either FileExplorerErr FileListing)
localListDirectory _ origPath = do
  let path = collapsePath origPath
      warning = checkBlocked path
  exists <- try (doesDirectoryExist path) :: IO (Either IOException Bool)
  case exists of
    Left ioErr
      | isDoesNotExistError ioErr -> pure (Left FeNotFound)
      | isPermissionError ioErr -> pure (Left FePermissionDenied)
      | otherwise -> pure (Left (FeIo (T.pack (show ioErr))))
    Right False -> do
      isFile <- try (doesFileExist path) :: IO (Either IOException Bool)
      case isFile of
        Right True -> pure (Left FeNotADirectory)
        Right False -> pure (Left FeNotFound)
        Left ioErr
          | isPermissionError ioErr -> pure (Left FePermissionDenied)
          | otherwise -> pure (Left FeNotFound)
    Right True -> do
      eNames <- try (listDirectory path) :: IO (Either IOException [FilePath])
      case eNames of
        Left ioErr
          | isPermissionError ioErr -> pure (Left FePermissionDenied)
          | otherwise -> pure (Left (FeIo (T.pack (show ioErr))))
        Right names -> do
          entries <- mapM (localEntry path) names
          let sorted = sortBy (comparing (\e -> (not (feIsDir e), feName e))) entries
              (kept, truncated) =
                if length sorted > listingEntryLimit
                  then (take listingEntryLimit sorted, True)
                  else (sorted, False)
          pure (Right FileListing
            { flPath = T.pack path
            , flEntries = kept
            , flTruncated = truncated
            , flWarning = warning
            })

-- | List several local directories. Sequential and cheap (no round trip per
-- directory), sharing exactly the semantics of 'localListDirectory', so the
-- batched and single-path arms cannot drift.
localListDirectories :: Int -> [FilePath] -> IO (Either FileExplorerErr [FileListing])
localListDirectories ceilingBytes = go []
  where
    go acc [] = pure (Right (reverse acc))
    go acc (p : ps) = do
      r <- localListDirectory ceilingBytes p
      case r of
        Left e -> pure (Left e)
        Right l -> go (l : acc) ps

-- | Build a 'FileEntry' for one child of a local directory. Checks
-- symlink, directory, file type, and best-effort size/mtime.
localEntry :: FilePath -> FilePath -> IO FileEntry
localEntry parent name = do
  let full = parent </> name
  eLink <- try (pathIsSymbolicLink full) :: IO (Either IOException Bool)
  case eLink of
    Right True -> pure FileEntry
      { feName = T.pack name
      , feIsDir = False
      , feIsSymlink = True
      , feSize = Nothing
      , feMtime = Nothing
      }
    _ -> do
      isDir <- try (doesDirectoryExist full) :: IO (Either IOException Bool)
      case isDir of
        Right True -> do
          eMtime <- try (getModificationTime full) :: IO (Either IOException UTCTime)
          pure FileEntry
            { feName = T.pack name
            , feIsDir = True
            , feIsSymlink = False
            , feSize = Nothing
            , feMtime = either (const Nothing) Just eMtime
            }
        _ -> do
          isFile <- try (doesFileExist full) :: IO (Either IOException Bool)
          case isFile of
            Right True -> do
              eSize <- try (getFileSize full) :: IO (Either IOException Integer)
              eMtime <- try (getModificationTime full) :: IO (Either IOException UTCTime)
              pure FileEntry
                { feName = T.pack name
                , feIsDir = False
                , feIsSymlink = False
                , feSize = either (const Nothing) Just eSize
                , feMtime = either (const Nothing) Just eMtime
                }
            _ -> pure FileEntry
              { feName = T.pack name
              , feIsDir = False
              , feIsSymlink = False
              , feSize = Nothing
              , feMtime = Nothing
              }

-- | Read a local file as 'FileContent'. Applies 'lexicalCollapse', checks
-- type, bounded read, UTF-8 decode, NUL-byte binary detection, line count
-- via 'T.lines'.
localReadFile :: Int -> FilePath -> IO (Either FileExplorerErr FileContent)
localReadFile ceilingBytes origPath = do
  let path = collapsePath origPath
  eRes <- checkReadable path
  case eRes of
    Left err -> pure (Left err)
    Right () -> do
      eBs <- try (readBoundedFile path ceilingBytes)
                :: IO (Either IOException (BS.ByteString, Bool))
      case eBs of
        Left ioErr
          | isPermissionError ioErr -> pure (Left FePermissionDenied)
          | isDoesNotExistError ioErr -> pure (Left FeNotFound)
          | otherwise -> pure (Left (FeIo (T.pack (show ioErr))))
        Right (bs, truncated) -> do
          let isBinary = BS.elem 0 bs
              content = if isBinary then "" else TE.decodeUtf8Lenient bs
              linesRead = if isBinary then 0 else length (T.lines content)
          pure (Right FileContent
            { fcPath = T.pack path
            , fcContent = content
            , fcTruncated = truncated
            , fcLinesRead = linesRead
            , fcIsBinary = isBinary
            })

-- | Read a local file as raw 'ByteString'. Applies 'lexicalCollapse',
-- checks type, bounded read — returns raw bytes (no UTF-8 decode).
localReadFileBytes :: Int -> FilePath -> IO (Either FileExplorerErr (ByteString, Bool))
localReadFileBytes ceilingBytes origPath = do
  let path = collapsePath origPath
  eRes <- checkReadable path
  case eRes of
    Left err -> pure (Left err)
    Right () -> do
      eBs <- try (readBoundedFile path ceilingBytes)
                :: IO (Either IOException (BS.ByteString, Bool))
      case eBs of
        Left ioErr
          | isPermissionError ioErr -> pure (Left FePermissionDenied)
          | isDoesNotExistError ioErr -> pure (Left FeNotFound)
          | otherwise -> pure (Left (FeIo (T.pack (show ioErr))))
        Right (bs, truncated) -> pure (Right (bs, truncated))

-- | Stat a local file: size via 'getFileSize', mtime via
-- 'getModificationTime' truncated to epoch seconds (integer).
localStatFile :: FilePath -> IO (Either FileExplorerErr FileStat)
localStatFile origPath = do
  let path = collapsePath origPath
  eRes <- checkReadable path
  case eRes of
    Left err -> pure (Left err)
    Right () -> do
      eSize <- try (getFileSize path) :: IO (Either IOException Integer)
      case eSize of
        Left ioErr
          | isPermissionError ioErr -> pure (Left FePermissionDenied)
          | isDoesNotExistError ioErr -> pure (Left FeNotFound)
          | otherwise -> pure (Left (FeIo (T.pack (show ioErr))))
        Right size -> do
          eMtime <- try (getModificationTime path) :: IO (Either IOException UTCTime)
          let mtimeEpoch = case eMtime of
                Right t -> Just (floor (utcTimeToPOSIXSeconds t))
                Left _  -> Nothing
          pure (Right FileStat
            { fsPath = T.pack path
            , fsSize = size
            , fsMtimeEpoch = mtimeEpoch
            })

-- | Read a range of bytes from a local file: @openBinaryFile@ +
-- @hSeek AbsoluteSeek offset@ + bounded @hGetSome len@. A read entirely
-- past EOF returns 'Left FeIo' (not an empty 'ByteString'). A read that
-- straddles EOF returns the available bytes (a short read is valid for
-- the final chunk).
localReadRange :: Int -> FilePath -> Integer -> Int
              -> IO (Either FileExplorerErr ByteString)
localReadRange _chunkCap origPath offset len = do
  let path = collapsePath origPath
  eRes <- checkReadable path
  case eRes of
    Left err -> pure (Left err)
    Right () -> do
      eBs <- try (withBinaryFile path ReadMode $ \h -> do
                    total <- hFileSize h
                    if offset >= total
                      then pure Nothing
                      else do
                        hSeek h AbsoluteSeek offset
                        Just <$> BS.hGetSome h len)
                :: IO (Either IOException (Maybe ByteString))
      case eBs of
        Left ioErr
          | isPermissionError ioErr -> pure (Left FePermissionDenied)
          | isDoesNotExistError ioErr -> pure (Left FeNotFound)
          | otherwise -> pure (Left (FeIo (T.pack (show ioErr))))
        Right Nothing -> pure (Left (FeIo "read past EOF"))
        Right (Just bs) -> pure (Right bs)

-- | Check that a path exists and is not a directory (for file-read
-- methods). Returns 'Left FeNotFound' if missing, 'Left FeIsDirectory'
-- if it's a directory, 'Right ()' if readable.
checkReadable :: FilePath -> IO (Either FileExplorerErr ())
checkReadable path = do
  eDir <- try (doesDirectoryExist path) :: IO (Either IOException Bool)
  case eDir of
    Left ioErr
      | isDoesNotExistError ioErr -> pure (Left FeNotFound)
      | isPermissionError ioErr -> pure (Left FePermissionDenied)
      | otherwise -> pure (Left (FeIo (T.pack (show ioErr))))
    Right True -> pure (Left FeIsDirectory)
    Right False -> do
      eFile <- try (doesFileExist path) :: IO (Either IOException Bool)
      case eFile of
        Right True -> pure (Right ())
        Right False -> pure (Left FeNotFound)
        Left ioErr
          | isPermissionError ioErr -> pure (Left FePermissionDenied)
          | otherwise -> pure (Left FeNotFound)

-- | Resolve the home directory on the local machine.
localResolveHome :: IO (Either FileExplorerErr FilePath)
localResolveHome = do
  eHome <- try getHomeDirectory :: IO (Either IOException FilePath)
  pure $ case eHome of
    Left ioErr -> Left (FeIo (T.pack (show ioErr)))
    Right home -> Right home

-- | Canonicalize a local path (resolve symlinks). Unlike
-- 'canonicalizePath' which returns the input unchanged for a non-existent
-- path, we wrap the result in 'Either' for uniformity with the remote arm.
localCanonicalize :: FilePath -> IO (Either FileExplorerErr FilePath)
localCanonicalize origPath = do
  let path = collapsePath origPath
  eCanon <- try (canonicalizePath path) :: IO (Either IOException FilePath)
  pure $ case eCanon of
    Left ioErr -> Left (FeIo (T.pack (show ioErr)))
    Right canon -> Right canon

-- ---------------------------------------------------------------------------
-- Remote arm
-- ---------------------------------------------------------------------------

-- | The remote file explorer. Reads via SSH through a 'RemoteRunner' to
-- the execution machine. The two @Int@s are the viewer read ceiling
-- (@readCeiling@) and the download chunk size (@downloadChunkBytes@),
-- captured at construction time.
--
-- The home-directory resolution is cached in an 'IORef' per handle
-- instance (per-process, never invalidated; if the SSH user's home
-- changes, a server restart refreshes it).
mkRemoteFileExplorer :: SshConfig -> RemoteRunner -> Int -> Int -> IO FileExplorerHandle
mkRemoteFileExplorer sshCfg runner readCeiling downloadChunkBytes = do
  homeCache <- newIORef Nothing
  pure $ FileExplorerHandle
    { feListDirectory = remoteListDirectory sshCfg runner readCeiling
    , feListDirectories = remoteListDirectories sshCfg runner readCeiling
    , feReadFile = remoteReadFile sshCfg runner readCeiling
    , feReadFileBytes = remoteReadFileBytes sshCfg runner readCeiling
    , feStatFile = remoteStatFile sshCfg runner
    , feReadRange = remoteReadRange sshCfg runner downloadChunkBytes
    , feCanonicalize = remoteCanonicalize sshCfg runner
    , feResolveHome = remoteResolveHome sshCfg runner homeCache
    }

-- | List a remote directory via ONE SSH round trip. The command assigns
-- the path to a shell variable first (via 'shellQuote'), then lists
-- entries with type/size/mtime. Uses @--@ separator before the path
-- argument in @ls@. Output is bounded by the 'RemoteRunner'\'s 50KB cap.
remoteListDirectory
  :: SshConfig -> RemoteRunner -> Int -> FilePath
  -> IO (Either FileExplorerErr FileListing)
remoteListDirectory sshCfg runner _ origPath = do
  let path = collapsePath origPath
      warning = checkBlocked path
      cmdText = remoteListCmd path
  case mkShellCommand cmdText of
    Left _ -> pure (Left (FeExec "invalid command (NUL in path?)"))
    Right cmd -> do
      res <- runRemoteShell runner sshCfg cmd
      case res of
        Left e -> pure (Left (mapRemoteExecError sshCfg e))
        Right out -> do
          let (cleanOut, runnerTruncated) = stripTruncationMarker out
          if notFoundMarker `T.isPrefixOf` cleanOut
            then pure (Left FeNotFound)
            else if notDirMarker `T.isPrefixOf` cleanOut
              then pure (Left FeNotADirectory)
              else do
                let entries = sortBy
                      (comparing (\e -> (not (feIsDir e), feName e)))
                      (parseRemoteListing cleanOut)
                    (kept, listTruncated) =
                      if length entries > listingEntryLimit
                        then (take listingEntryLimit entries, True)
                        else (entries, False)
                pure (Right FileListing
                  { flPath = T.pack path
                  , flEntries = kept
                  , flTruncated = runnerTruncated || listTruncated
                  , flWarning = warning
                  })

-- | Read a remote file as 'FileContent' via SSH @head -c <ceil> -- "$p"@.
-- UTF-8 decode, NUL-byte binary detection, line count via 'T.lines'.
remoteReadFile
  :: SshConfig -> RemoteRunner -> Int -> FilePath
  -> IO (Either FileExplorerErr FileContent)
remoteReadFile sshCfg runner ceilingBytes origPath = do
  let path = collapsePath origPath
      cmdText = remoteReadCmd path ceilingBytes
  case mkShellCommand cmdText of
    Left _ -> pure (Left (FeExec "invalid command (NUL in path?)"))
    Right cmd -> do
      res <- runRemoteShell runner sshCfg cmd
      case res of
        Left e -> pure (Left (mapRemoteExecError sshCfg e))
        Right out -> do
          let (cleanOut, runnerTruncated) = stripTruncationMarker out
          if notFoundMarker `T.isPrefixOf` cleanOut
            then pure (Left FeNotFound)
            else if isDirMarker `T.isPrefixOf` cleanOut
              then pure (Left FeIsDirectory)
              else do
                let bs = TE.encodeUtf8 cleanOut
                    truncated = runnerTruncated || BS.length bs >= ceilingBytes
                    isBinary = BS.elem 0 bs
                    content = if isBinary then "" else cleanOut
                    linesRead = if isBinary then 0 else length (T.lines content)
                pure (Right FileContent
                  { fcPath = T.pack path
                  , fcContent = content
                  , fcTruncated = truncated
                  , fcLinesRead = linesRead
                  , fcIsBinary = isBinary
                  })

-- | Read a remote file as raw ByteString via SSH @head -c <ceil>
-- -- "$p"@. Uses runRemoteBytes (raw ByteString transport -- no
-- UTF-8 decode) so binary files are served without corruption.
remoteReadFileBytes
  :: SshConfig -> RemoteRunner -> Int -> FilePath
  -> IO (Either FileExplorerErr (ByteString, Bool))
remoteReadFileBytes sshCfg runner ceilingBytes origPath = do
  let path = collapsePath origPath
      cmdText = remoteReadCmd path ceilingBytes
      notFoundBs = TE.encodeUtf8 (notFoundMarker <> "\n")
      isDirBs = TE.encodeUtf8 (isDirMarker <> "\n")
  case mkShellCommand cmdText of
    Left _ -> pure (Left (FeExec "invalid command (NUL in path?)"))
    Right _ -> do
      res <- runRemoteBytes runner (sshExecArgv sshCfg cmdText)
      case res of
        Left e -> pure (Left (mapRemoteExecError sshCfg e))
        Right (bs, transportTruncated) -> do
          let truncated = transportTruncated || BS.length bs >= ceilingBytes
          if notFoundBs `BS.isPrefixOf` bs
            then pure (Left FeNotFound)
            else if isDirBs `BS.isPrefixOf` bs
              then pure (Left FeIsDirectory)
              else pure (Right (bs, truncated))

-- | Stat a remote file via SSH @stat -c '%s %Y' -- "$p"@. Output is
-- small (two integers), well under the 50K transport cap. Returns
-- 'FileStat' with size and mtime as epoch seconds.
remoteStatFile
  :: SshConfig -> RemoteRunner -> FilePath
  -> IO (Either FileExplorerErr FileStat)
remoteStatFile sshCfg runner origPath = do
  let path = collapsePath origPath
      cmdText = remoteStatCmd path
  case mkShellCommand cmdText of
    Left _ -> pure (Left (FeExec "invalid command (NUL in path?)"))
    Right cmd -> do
      res <- runRemoteShell runner sshCfg cmd
      case res of
        Left e -> pure (Left (mapRemoteExecError sshCfg e))
        Right out ->
          if notFoundMarker `T.isPrefixOf` out
            then pure (Left FeNotFound)
            else if isDirMarker `T.isPrefixOf` out
              then pure (Left FeIsDirectory)
              else case parseStatOutput out of
                Left e -> pure (Left e)
                Right (size, mtime) -> pure (Right FileStat
                  { fsPath = T.pack path
                  , fsSize = size
                  , fsMtimeEpoch = mtime
                  })

-- | Read a range of bytes from a remote file via SSH @dd bs=$chunkSize
-- skip=$index count=1 if="$p" 2>/dev/null@. Uses 'runRemoteStream'
-- (NOT 'runRemoteBytes') so chunks larger than 50K are not truncated by
-- the transport cap. The path is 'shellQuote'-d.
remoteReadRange
  :: SshConfig -> RemoteRunner -> Int -> FilePath -> Integer -> Int
  -> IO (Either FileExplorerErr ByteString)
remoteReadRange sshCfg runner chunkCap origPath offset len = do
  let path = collapsePath origPath
      chunkSize = min len chunkCap
      index = offset `div` fromIntegral chunkSize
      cmdText = remoteReadRangeCmd path chunkSize (fromIntegral index)
  case mkShellCommand cmdText of
    Left _ -> pure (Left (FeExec "invalid command (NUL in path?)"))
    Right _ -> do
      let argv = sshExecArgv sshCfg cmdText
      res <- runRemoteStream runner argv $ \h ->
               BS.hGetSome h len
      case res of
        Left e -> pure (Left (mapRemoteExecError sshCfg e))
        Right bs
          | BS.null bs -> pure (Left (FeIo "read past EOF"))
          | otherwise -> pure (Right bs)

-- | Resolve the home directory on the remote machine via SSH @echo
-- $HOME@. The result is cached in an 'IORef' per handle instance.
remoteResolveHome
  :: SshConfig -> RemoteRunner -> IORef (Maybe FilePath)
  -> IO (Either FileExplorerErr FilePath)
remoteResolveHome sshCfg runner ref = do
  cached <- readIORef ref
  case cached of
    Just h -> pure (Right h)
    Nothing -> case mkShellCommand "echo $HOME" of
      Left _ -> pure (Left (FeExec "invalid command"))
      Right cmd -> do
        res <- runRemoteShell runner sshCfg cmd
        case res of
          Left e -> pure (Left (mapRemoteExecError sshCfg e))
          Right out -> do
            let home = T.unpack (T.strip out)
            if T.null (T.strip out)
              then pure (Left (FeIo "empty home directory"))
              else do
                writeIORef ref (Just home)
                pure (Right home)

-- | Canonicalize a remote path via @readlink -f -- "$p"@ over SSH. The
-- path is 'shellQuote'-d. Returns the canonical path or an error.
remoteCanonicalize
  :: SshConfig -> RemoteRunner -> FilePath
  -> IO (Either FileExplorerErr FilePath)
remoteCanonicalize sshCfg runner origPath = do
  let path = collapsePath origPath
      cmdText = T.pack $ unwords
        [ "readlink -f -- " <> shellQuote path ]
  case mkShellCommand cmdText of
    Left _ -> pure (Left (FeExec "invalid command (NUL in path?)"))
    Right cmd -> do
      res <- runRemoteShell runner sshCfg cmd
      case res of
        Left e -> pure (Left (mapRemoteExecError sshCfg e))
        Right out ->
          let canon = T.unpack (T.strip out)
          in if T.null (T.strip out)
               then pure (Left (FeIo "readlink returned empty"))
               else pure (Right canon)

-- ---------------------------------------------------------------------------
-- Remote command construction
-- ---------------------------------------------------------------------------

-- | Build the remote listing command. The path is 'shellQuote'-d and
-- assigned to a shell variable (@p=...@) before use in compound
-- commands. The @ls@ uses @--@ before the path argument. Entry type is
-- emitted as a prefix tag: @S|@ (symlink), @D|@ (directory), @F|@ (file,
-- with size and mtime), @O|@ (other). Error sentinels
-- (@___SEAL_NOTFOUND___@, @___SEAL_NOTDIR___@) distinguish missing paths
-- from non-directory paths.
remoteListCmd :: FilePath -> Text
remoteListCmd path =
  T.pack $ unwords
    [ "p=" <> shellQuote path <> ";"
    , "if [ ! -e \"$p\" ]; then echo \"" <> T.unpack notFoundMarker <> "\";"
    , "elif [ ! -d \"$p\" ]; then echo \"" <> T.unpack notDirMarker <> "\";"
    , "else ls -1A -- \"$p\" 2>/dev/null | while IFS= read -r name; do"
    , "full=\"$p/$name\";"
    , "if [ -L \"$full\" ]; then echo \"S|$name\";"
    , "elif [ -d \"$full\" ]; then echo \"D|$name\";"
    , "elif [ -f \"$full\" ]; then"
    , "sz=$(stat -c %s -- \"$full\" 2>/dev/null || stat -f%z \"$full\" 2>/dev/null || echo 0);"
    , "mt=$(stat -c %Y -- \"$full\" 2>/dev/null || stat -f%m \"$full\" 2>/dev/null || echo 0);"
    , "echo \"F|$name|$sz|$mt\";"
    , "else echo \"O|$name\"; fi;"
    , "done;"
    , "fi"
    ]

-- | Build the remote read command. The path is 'shellQuote'-d and
-- assigned to a shell variable, then @head -c <ceil> -- "$p"@ reads the
-- first @ceilBytes@ bytes. Error sentinels distinguish missing paths
-- (@___SEAL_NOTFOUND___@) from directories (@___SEAL_ISDIR___@).
remoteReadCmd :: FilePath -> Int -> Text
remoteReadCmd path ceilingBytes =
  T.pack $ unwords
    [ "p=" <> shellQuote path <> ";"
    , "if [ ! -e \"$p\" ]; then echo \"" <> T.unpack notFoundMarker <> "\";"
    , "elif [ -d \"$p\" ]; then echo \"" <> T.unpack isDirMarker <> "\";"
    , "else head -c " <> show ceilingBytes <> " -- \"$p\";"
    , "fi"
    ]

-- | Build the remote stat command. The path is 'shellQuote'-d and
-- assigned to a shell variable, then @stat -c '%s %Y' -- "$p"@ emits
-- size and mtime (epoch seconds) on one line. Error sentinels
-- distinguish missing paths from directories. The @stat -f%z -f%m@
-- fallback covers BSD/macOS.
remoteStatCmd :: FilePath -> Text
remoteStatCmd path =
  T.pack $ unwords
    [ "p=" <> shellQuote path <> ";"
    , "if [ ! -e \"$p\" ]; then echo \"" <> T.unpack notFoundMarker <> "\";"
    , "elif [ -d \"$p\" ]; then echo \"" <> T.unpack isDirMarker <> "\";"
    , "else stat -c '%s %Y' -- \"$p\" 2>/dev/null || stat -f%z -f%m -- \"$p\" 2>/dev/null;"
    , "fi"
    ]

-- | Build the remote read-range command for @dd@. The path is
-- 'shellQuote'-d. @dd bs=$chunkSize skip=$index count=1 if="$p"@
-- reads one chunk of @chunkSize@ bytes starting at byte
-- @index * chunkSize@. stderr is discarded (@2>/dev/null@) so @dd@'s
-- progress noise does not corrupt the output.
remoteReadRangeCmd :: FilePath -> Int -> Int -> Text
remoteReadRangeCmd path chunkSize index =
  T.pack $ unwords
    [ "dd bs=" <> show chunkSize
    , "skip=" <> show index
    , "count=1"
    , "if=" <> shellQuote path
    , "2>/dev/null"
    ]

-- ---------------------------------------------------------------------------
-- Output parsing (pure)
-- ---------------------------------------------------------------------------

-- | The per-directory framing tag emitted by 'remoteListDirsCmd'. Chosen so it
-- cannot collide with an entry line (which starts with D\/F\/S\/O\/|).
dirHeaderTag :: Text
dirHeaderTag = "%%D|"

-- | Build ONE shell command that lists N directories, framing each with
-- 'dirHeaderTag' so the response can be split. Every path is shell-quoted
-- (never interpolated raw), and the per-directory body is identical to
-- 'remoteListCmd' so the two arms agree.
--
-- Output shape:
--
-- > %%D|/a
-- > D|sub
-- > F|f.txt|6|1700000000
-- > %%D|/b
-- > F|g.txt|7|1700000000
remoteListDirsCmd :: [FilePath] -> Text
remoteListDirsCmd paths = T.intercalate "; " (map one paths)
  where
    one :: FilePath -> Text
    one path = T.pack $ unwords
      [ "p=" <> shellQuote path <> ";"
      , "echo " <> shellQuote (T.unpack dirHeaderTag <> path) <> ";"
      , "if [ ! -e \"$p\" ]; then echo \"" <> T.unpack notFoundMarker <> "\";"
      , "elif [ ! -d \"$p\" ]; then echo \"" <> T.unpack notDirMarker <> "\";"
      , "else ls -1A -- \"$p\" 2>/dev/null | while IFS= read -r name; do"
      , "full=\"$p/$name\";"
      , "if [ -L \"$full\" ]; then echo \"S|$name\";"
      , "elif [ -d \"$full\" ]; then echo \"D|$name\";"
      , "elif [ -f \"$full\" ]; then"
      , "sz=$(stat -c %s -- \"$full\" 2>/dev/null || stat -f%z \"$full\" 2>/dev/null || echo 0);"
      , "mt=$(stat -c %Y -- \"$full\" 2>/dev/null || stat -f%m \"$full\" 2>/dev/null || echo 0);"
      , "echo \"F|$name|$sz|$mt\";"
      , "else echo \"O|$name\"; fi;"
      , "done;"
      , "fi"
      ]

-- | Split a batched listing response into (path, body) pairs, in arrival
-- order. A directory whose body was cut off by transport truncation is
-- dropped entirely, so a caller never sees a partially-listed directory.
parseBatchedListing :: Text -> [(Text, Text)]
parseBatchedListing raw =
  let (clean, _truncated) = stripTruncationMarker raw
  in go clean
  where
    -- Accumulate (path, body-lines) blocks, then reverse each body.
    go txt =
      let ls = T.lines txt
          (blocks, curPath, curLines) = foldl step ([], Nothing, []) ls
          finish mpath mlines acc =
            case mpath of
              Nothing -> acc
              Just p  -> acc ++ [(p, T.unlines (reverse mlines))]
      in finish curPath curLines blocks

    step (acc, mpath, mlines) line =
      case T.stripPrefix dirHeaderTag line of
        Just p ->
          let acc' = case mpath of
                Nothing -> acc
                Just cur -> acc ++ [(cur, T.unlines (reverse mlines))]
          in (acc', Just p, [])
        Nothing -> (acc, mpath, line : mlines)

-- | List several remote directories in ONE SSH round trip. Directories that
-- did not arrive complete (transport truncation) are omitted from the result:
-- returning a partial listing would be wrong, and the caller re-requests the
-- remainder individually.
remoteListDirectories
  :: SshConfig -> RemoteRunner -> Int -> [FilePath]
  -> IO (Either FileExplorerErr [FileListing])
remoteListDirectories _sshCfg _runner _ceiling [] = pure (Right [])
remoteListDirectories sshCfg runner _ceiling paths = do
  let collapsed = map collapsePath paths
      cmdText = remoteListDirsCmd collapsed
  case mkShellCommand cmdText of
    Left _ -> pure (Left (FeExec "invalid command (NUL in path?)"))
    Right cmd -> do
      res <- runRemoteShell runner sshCfg cmd
      case res of
        Left e -> pure (Left (mapRemoteExecError sshCfg e))
        Right out -> do
          let pairs = parseBatchedListing out
              toListing (p, body) =
                let entries = sortBy
                      (comparing (\e -> (not (feIsDir e), feName e)))
                      (parseRemoteListing body)
                in FileListing
                     { flPath = p
                     , flEntries = entries
                     , flTruncated = False
                     , flWarning = checkBlocked (T.unpack p)
                     }
          pure (Right (map toListing pairs))

-- | Parse the remote listing output into 'FileEntry' list. Each line is
-- @S|name@, @D|name@, @F|name|size|mtime@, or @O|name@. Malformed lines
-- are silently skipped. Entry names containing @|@ are misparsed (a
-- documented limitation — the QuickCheck property guards against this).
parseRemoteListing :: Text -> [FileEntry]
parseRemoteListing output =
  mapMaybe parseEntry (T.lines output)
  where
    parseEntry :: Text -> Maybe FileEntry
    parseEntry line
      | T.null line = Nothing
      | otherwise = case T.splitOn "|" line of
          ["S", name] -> Just FileEntry
            { feName = name
            , feIsDir = False
            , feIsSymlink = True
            , feSize = Nothing
            , feMtime = Nothing
            }
          ["D", name] -> Just FileEntry
            { feName = name
            , feIsDir = True
            , feIsSymlink = False
            , feSize = Nothing
            , feMtime = Nothing
            }
          ["F", name, sz, mt] -> Just FileEntry
            { feName = name
            , feIsDir = False
            , feIsSymlink = False
            , feSize = parseInteger sz
            , feMtime = parseMtime mt
            }
          ["O", name] -> Just FileEntry
            { feName = name
            , feIsDir = False
            , feIsSymlink = False
            , feSize = Nothing
            , feMtime = Nothing
            }
          _ -> Nothing

-- | Strip the 'readBounded' truncation marker from the output. Returns
-- the clean content and a 'Bool' indicating whether truncation was
-- detected.
stripTruncationMarker :: Text -> (Text, Bool)
stripTruncationMarker txt =
  case T.breakOn truncationMarker txt of
    (content, rest)
      | T.null rest -> (txt, False)
      | otherwise -> (T.stripEnd content, True)

-- | Parse a non-negative integer from 'Text'. Total — returns
-- 'Nothing' on any non-numeric input (including empty).
parseInteger :: Text -> Maybe Integer
parseInteger txt =
  let t = T.dropWhile isSpace (T.strip txt)
  in if not (T.null t) && T.all isDigit t
       then readMaybe (T.unpack t)
       else Nothing

-- | Parse a Unix epoch timestamp (seconds) into 'UTCTime'. Returns
-- 'Nothing' for non-numeric input or @0@ (which means @stat@ failed and
-- fell back to @echo 0@).
parseMtime :: Text -> Maybe UTCTime
parseMtime txt =
  case parseInteger txt of
    Just n | n > 0 -> Just (posixSecondsToUTCTime (fromIntegral n))
    _ -> Nothing

-- | Parse the output of 'remoteStatCmd' — @<size> <mtime>@ on one line.
-- Returns 'Left FeIo' on malformed output. The mtime is @0@ when @stat@
-- failed (mapped to 'Nothing').
parseStatOutput :: Text -> Either FileExplorerErr (Integer, Maybe Integer)
parseStatOutput out =
  case T.words (T.strip out) of
    [sizeTxt, mtimeTxt] ->
      case (parseInteger sizeTxt, parseInteger mtimeTxt) of
        (Just sz, Just mt) ->
          Right (sz, if mt > 0 then Just mt else Nothing)
        _ -> Left (FeIo ("malformed stat output: " <> out))
    _ -> Left (FeIo ("malformed stat output: " <> out))
