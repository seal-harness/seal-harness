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
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import System.Directory
  ( doesDirectoryExist, doesFileExist, getHomeDirectory, getFileSize
  , getModificationTime, listDirectory, pathIsSymbolicLink
  )
import System.FilePath (joinPath, splitDirectories, (</>))
import System.IO.Error (isDoesNotExistError, isPermissionError)
import Text.Read (readMaybe)

import Seal.Security.Path (blockedNames, lexicalCollapse)
import Seal.Tools.Args (mkShellCommand)
import Seal.Tools.Exec.Remote (RemoteRunner, runRemoteShell, runRemoteBytes, sshExecArgv)
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

-- ---------------------------------------------------------------------------
-- Handle
-- ---------------------------------------------------------------------------

-- | The file explorer capability handle. Abstracts local vs remote
-- execution machine access. The @Int@ parameter on construction is the
-- operator-configured byte ceiling for reads (same @maxScanBytes@ as
-- @FILE_READ@).
data FileExplorerHandle = FileExplorerHandle
  { feListDirectory :: FilePath -> IO (Either FileExplorerErr FileListing)
  , feReadFile :: FilePath -> IO (Either FileExplorerErr FileContent)
  , feReadFileBytes :: FilePath -> IO (Either FileExplorerErr (ByteString, Bool))
    -- ^ (bytes up to ceiling, truncated?) — for the download endpoint.
    -- Returns raw bytes so binary files are not corrupted by UTF-8
    -- decode/encode round-trip. The 'Bool' is whether the file exceeded
    -- the byte ceiling.
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
  , feReadFile = \_ -> pure (Left FeDisabled)
  , feReadFileBytes = \_ -> pure (Left FeDisabled)
  , feResolveHome = pure (Left FeDisabled)
  }

-- ---------------------------------------------------------------------------
-- Local arm
-- ---------------------------------------------------------------------------

-- | The local file explorer. Reads via 'System.Directory' on the harness
-- machine. The @Int@ is the operator-configured byte ceiling for reads,
-- captured at construction time.
mkLocalFileExplorer :: Int -> FileExplorerHandle
mkLocalFileExplorer ceilingBytes = FileExplorerHandle
  { feListDirectory = localListDirectory ceilingBytes
  , feReadFile = localReadFile ceilingBytes
  , feReadFileBytes = localReadFileBytes ceilingBytes
  , feResolveHome = localResolveHome
  }

-- | Read at most @maxBytes@ from a local file. Returns the bytes read and
-- a 'Bool' indicating whether the file was truncated (the file is larger
-- than @maxBytes@).
readBoundedFile :: FilePath -> Int -> IO (BS.ByteString, Bool)
readBoundedFile path maxBytes = do
  bs <- BS.readFile path
  let len = BS.length bs
  if len <= maxBytes
    then pure (bs, False)
    else pure (BS.take maxBytes bs, True)

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

-- ---------------------------------------------------------------------------
-- Remote arm
-- ---------------------------------------------------------------------------

-- | The remote file explorer. Reads via SSH through a 'RemoteRunner' to
-- the execution machine. The @Int@ is the operator-configured byte
-- ceiling for reads, captured at construction time.
--
-- The home-directory resolution is cached in an 'IORef' per handle
-- instance (per-process, never invalidated; if the SSH user's home
-- changes, a server restart refreshes it).
mkRemoteFileExplorer :: SshConfig -> RemoteRunner -> Int -> IO FileExplorerHandle
mkRemoteFileExplorer sshCfg runner ceilingBytes = do
  homeCache <- newIORef Nothing
  pure $ FileExplorerHandle
    { feListDirectory = remoteListDirectory sshCfg runner ceilingBytes
    , feReadFile = remoteReadFile sshCfg runner ceilingBytes
    , feReadFileBytes = remoteReadFileBytes sshCfg runner ceilingBytes
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

-- ---------------------------------------------------------------------------
-- Output parsing (pure)
-- ---------------------------------------------------------------------------

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
