{-# LANGUAGE OverloadedStrings #-}
-- | A local/remote-agnostic, SafePath-confined filesystem vocabulary for
-- workspace-derived discovery (agent defs, skills). The constructor is
-- NOT exported; the three smart constructors ('mkLocalWorkdirFs',
-- 'mkInMemWorkdirFs', 'mkWorkdirFsStub') are the only way to obtain one.
--
-- The local arm reads via 'System.Directory' / 'Data.Text.IO'; every path
-- is run through 'mkSafePath' (anchored at the workdir root) first. The
-- in-memory stub arm resolves 'SymlinkTarget' chains (depth-bounded) and
-- re-checks containment on the resolved path so the symlink-escape test
-- is non-vacuous. The fail-closed stub yields 'Left WfsStub' / 'False' /
-- 'Right []' for every method.
module Seal.Tools.Exec.WorkdirFs
  ( WorkdirFs (..)
  , WorkdirFsErr (..)
  , SnapshotEntry (..)
  , WorkspaceSnapshot (..)
  , mkLocalWorkdirFs
  , mkRemoteWorkdirFs
  , mkInMemWorkdirFs
  , mkWorkdirFsStub
  , StubEntry (..)
  , snapshotMaxDepth
  , maxSnapshotEntries
    -- * Snapshot accessors (pure; consumed by the discovery scanners)
  , snapIsDirectoryAt
  , snapIsFileAt
  , snapTopDirs
  , snapChildDirsAt
  , snapChildFilesAt
  ) where

import Control.Exception (IOException, try)
import Data.Char (isDigit, isSpace)
import Data.Char qualified as Char
import Data.Either (fromRight)
import Data.List (sort, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime (..))
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (secondsToDiffTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import System.Directory
  ( doesDirectoryExist, doesFileExist, getFileSize, getModificationTime
  , listDirectory, pathIsSymbolicLink
  )
import System.FilePath ((</>))

import Seal.Security.Path
  ( PathError (..), WorkspaceRoot (..), getSafePath, mkSafePath
  , mkSafePathRemote
  )
import Seal.Tools.Args (mkShellCommand)
import Seal.Tools.Exec.Types (RemotePath, SshConfig, getRemotePath, mkRemotePath)
import Seal.Tools.Exec.UIO (runUIOWithEnv, uioShellExec)
import Seal.Tools.Exec.UIO.Internal (UIOEnv)
import Seal.Tools.Exec.UntrustedIO (UntrustedErr (..), shellQuote)

-- | A local/remote-agnostic, SafePath-confined filesystem vocabulary for
-- workspace-derived discovery. Each field is an IO action; the smart
-- constructors wire the local, in-memory-stub, or fail-closed-stub arm.
data WorkdirFs = WorkdirFs
  { wfsReadFile            :: RemotePath -> IO (Either WorkdirFsErr Text)
  , wfsDoesFileExist       :: RemotePath -> IO Bool
  , wfsDoesDirectoryExist  :: RemotePath -> IO Bool
  , wfsListDirectory       :: RemotePath -> IO (Either WorkdirFsErr [Text])
  , wfsFileSize            :: RemotePath -> IO (Either WorkdirFsErr Integer)
  , wfsModificationTime    :: RemotePath -> IO (Either WorkdirFsErr UTCTime)
  , wfsSnapshot            :: IO (Either WorkdirFsErr WorkspaceSnapshot)
    -- ^ A depth-limited structural snapshot of the whole workspace in ONE
    -- operation (one SSH round trip on the remote arm). Enumerates regular
    -- directories + files only — symlinks are never followed and never
    -- appear as structure. Consumed by the discovery scanners
    -- ("Seal.Agent.Def.Workdir", "Seal.Skills.Backend") to replace the
    -- per-probe round trips; file CONTENT is still read via 'wfsReadFile'
    -- (the symlink-containment chokepoint).
  }

-- | One entry of a 'WorkspaceSnapshot'. @snapRelPath@ is a @\/@-separated
-- path relative to the workspace root (@@"repo\/.agents"@@) — no leading
-- @.\/@, no @.@ component, root itself not included.
data SnapshotEntry = SnapshotEntry
  { snapRelPath :: !Text
  , snapIsDir   :: !Bool
  } deriving stock (Eq, Ord, Show)

-- | A depth-limited structural snapshot of the workspace: every regular
-- directory + file at depth ≤ 'snapshotMaxDepth', sorted by 'snapRelPath'.
newtype WorkspaceSnapshot = WorkspaceSnapshot
  { snapEntries :: [SnapshotEntry]
  } deriving stock (Eq, Show)

-- | The maximum path depth (components below the workspace root) the
-- snapshot enumerates. Covers every convention location the discovery
-- scanners need structurally: @\<repo\>\/.agents\/agents\/\<id\>\/@ (depth 4,
-- protocol sub-agent dirs), @\<repo\>\/\<conv\>\/\<group\>\/@ (depth 4, grouped
-- skills). File CONTENTS are never part of the snapshot.
snapshotMaxDepth :: Int
snapshotMaxDepth = 4

-- | The maximum number of entries a snapshot may carry before it is
-- rejected with 'WfsOversize' (a runaway tree must not be silently
-- truncated into wrong discovery results).
maxSnapshotEntries :: Int
maxSnapshotEntries = 8192

-- | The output marker separating the @find -type d@ section from the
-- @find -type f@ section of the remote snapshot command. A find line can
-- never collide with it (every find line starts with @./@).
snapshotFilesMarker :: Text
snapshotFilesMarker = "__SEAL_FILES__"

-- | The error ADT for 'WorkdirFs' methods. Pinned for exhaustive
-- pattern-match under @-Wall -Werror@.
data WorkdirFsErr
  = WfsPath !PathError
  | WfsNotFound
  | WfsOversize
  | WfsIo !Text
  | WfsExec !Text
  | WfsStub
  deriving stock (Eq, Show)

-- | An entry in the in-memory stub's seeded map. Models files, symlink
-- chains, directories, and missing paths so the symlink-escape test is
-- non-vacuous.
data StubEntry
  = FileContent Text
  | SymlinkTarget RemotePath
  | Directory [Text]
  | Missing
  deriving stock (Eq, Show)

-- | The per-file character limit applied after a successful read. Matches
-- 'defaultSectionCharLimit' in "Seal.Agent.Def.Backend".
defaultSectionCharLimit :: Int
defaultSectionCharLimit = 65536

-- | Truncate a body to @limit@ characters, appending the exact truncation
-- marker. Strings at or under the limit are returned as-is. Matches
-- 'truncateSection' in "Seal.Agent.Def.Backend".
truncateSection :: Int -> Text -> Text
truncateSection limit txt
  | T.length txt <= limit = txt
  | otherwise =
      T.take limit txt
        <> "\n[...truncated at " <> T.pack (show limit) <> " chars...]"

-- ---------------------------------------------------------------------------
-- Local arm
-- ---------------------------------------------------------------------------

-- | The local arm. Reads via 'System.Directory' / 'Data.Text.IO'; every
-- path is run through 'mkSafePath' (anchored at the workdir root) first.
-- The @Int@ is the operator scan-byte ceiling, captured at construction.
mkLocalWorkdirFs :: WorkspaceRoot -> Int -> WorkdirFs
mkLocalWorkdirFs wsRoot ceilingBytes = WorkdirFs
  { wfsReadFile = \rp -> do
      let rel = T.unpack (getRemotePath rp)
      eSafe <- mkSafePath wsRoot rel
      case eSafe of
        Left (PathDoesNotExist _) -> pure (Left WfsNotFound)
        Left pe -> pure (Left (WfsPath pe))
        Right sp -> readLocalBounded (getSafePath sp) ceilingBytes
  , wfsDoesFileExist = \rp -> do
      let rel = T.unpack (getRemotePath rp)
      eSafe <- mkSafePath wsRoot rel
      case eSafe of
        Left _  -> pure False
        Right sp -> doesFileExist (getSafePath sp)
  , wfsDoesDirectoryExist = \rp -> do
      let rel = T.unpack (getRemotePath rp)
      eSafe <- mkSafePath wsRoot rel
      case eSafe of
        Left _  -> pure False
        Right sp -> doesDirectoryExist (getSafePath sp)
  , wfsListDirectory = \rp -> do
      let rel = T.unpack (getRemotePath rp)
      eSafe <- mkSafePath wsRoot rel
      case eSafe of
        Left (PathDoesNotExist _) -> pure (Right [])
        Left pe -> pure (Left (WfsPath pe))
        Right sp -> do
          exists <- doesDirectoryExist (getSafePath sp)
          if not exists
            then pure (Right [])
            else do
              eNames <- try (listDirectory (getSafePath sp))
                        :: IO (Either IOException [FilePath])
              pure $ case eNames of
                Left ioErr -> Left (WfsIo (T.pack (show ioErr)))
                Right names -> Right (map T.pack names)
  , wfsFileSize = \rp -> do
      let rel = T.unpack (getRemotePath rp)
      eSafe <- mkSafePath wsRoot rel
      case eSafe of
        Left (PathDoesNotExist _) -> pure (Left WfsNotFound)
        Left pe -> pure (Left (WfsPath pe))
        Right sp -> do
          eSize <- try (getFileSize (getSafePath sp))
                    :: IO (Either IOException Integer)
          pure $ case eSize of
            Left _ -> Left WfsNotFound
            Right size -> Right size
  , wfsModificationTime = \rp -> do
      let rel = T.unpack (getRemotePath rp)
      eSafe <- mkSafePath wsRoot rel
      case eSafe of
        Left (PathDoesNotExist _) -> pure (Left WfsNotFound)
        Left pe -> pure (Left (WfsPath pe))
        Right sp -> do
          eMtime <- try (getModificationTime (getSafePath sp))
                     :: IO (Either IOException UTCTime)
          pure $ case eMtime of
            Left _ -> Left WfsNotFound
            Right mtime -> Right mtime
  , wfsSnapshot = localSnapshot wsRoot
  }

-- | The depth-limited structural walk for the local arm ('wfsSnapshot').
-- Enumerates regular dirs + files only; symlinks are skipped entirely
-- (never followed — mirrors the remote @find -P@ semantics so both arms
-- agree on structure). Depth- and count-bounded.
localSnapshot :: WorkspaceRoot -> IO (Either WorkdirFsErr WorkspaceSnapshot)
localSnapshot wsRoot = do
  entries <- walkDir root "" snapshotMaxDepth
  pure $!
    if length entries > maxSnapshotEntries
      then Left WfsOversize
      else Right (WorkspaceSnapshot (sortOn snapRelPath entries))
  where
    root = case wsRoot of WorkspaceRoot p -> p
    walkDir :: FilePath -> Text -> Int -> IO [SnapshotEntry]
    walkDir dir relPrefix remaining
      | remaining <= 0 = pure []
      | otherwise = do
          eNames <- try (listDirectory dir) :: IO (Either IOException [FilePath])
          case eNames of
            Left _     -> pure []   -- unreadable subtree: fail-soft
            Right names -> concat <$> mapM step (sort names)
      where
        step name = do
          let childRel = if T.null relPrefix
                           then T.pack name
                           else relPrefix <> "/" <> T.pack name
              fsPath = dir </> name
          eLink <- try (pathIsSymbolicLink fsPath)
                     :: IO (Either IOException Bool)
          if fromRight True eLink
            then pure []   -- symlink (or vanished): never followed
            else do
              isDir <- doesDirectoryExist fsPath
              if isDir
                then do
                  sub <- walkDir fsPath childRel (remaining - 1)
                  pure (SnapshotEntry childRel True : sub)
                else do
                  isFile <- doesFileExist fsPath
                  pure [SnapshotEntry childRel False | isFile]

-- | Stat-first (reject 'WfsOversize' if > ceiling), then read + decode to
-- 'Text', truncate to 'defaultSectionCharLimit'. Returns 'WfsNotFound' if
-- the file is missing.
readLocalBounded :: FilePath -> Int -> IO (Either WorkdirFsErr Text)
readLocalBounded path ceilingBytes = do
  eSize <- try (getFileSize path) :: IO (Either IOException Integer)
  case eSize of
    Left _ -> pure (Left WfsNotFound)
    Right size
      | size > fromIntegral ceilingBytes -> pure (Left WfsOversize)
      | otherwise -> do
          eTxt <- try (TIO.readFile path) :: IO (Either IOException Text)
          pure $ case eTxt of
            Left ioErr -> Left (WfsIo (T.pack (show ioErr)))
            Right txt ->
              let trimmed = T.dropWhileEnd Char.isSpace txt
              in if T.null (T.strip trimmed)
                   then Left WfsNotFound
                   else Right (truncateSection defaultSectionCharLimit trimmed)

-- ---------------------------------------------------------------------------
-- Remote arm
-- ---------------------------------------------------------------------------

-- | The remote arm. Reads via SSH through 'UIO'\'s 'uioShellExec' (the shared
-- 'RemoteRunner' lives in the 'UIOEnv'). Every path is run through
-- 'mkSafePathRemote' (anchored at the remote workspace root) BEFORE any
-- shell-exec call. 'wfsReadFile'/'wfsListDirectory'/'wfsFileSize'/
-- 'wfsModificationTime' additionally run @realpath -f -- <abspath>@ on the
-- remote OS and re-check containment on the resolved path, so a symlink
-- escaping the workspace is rejected before any content is read or any
-- directory is listed. The @Int@ is the operator scan-byte ceiling,
-- captured at construction.
mkRemoteWorkdirFs :: UIOEnv -> SshConfig -> WorkspaceRoot -> Int -> WorkdirFs
mkRemoteWorkdirFs uioEnv sshCfg wsRoot ceilingBytes = WorkdirFs
  { wfsReadFile = \rp -> do
      let rel = T.unpack (getRemotePath rp)
      case mkSafePathRemote wsRoot rel of
        Left pe -> pure (Left (WfsPath pe))
        Right sp -> remoteReadFile uioEnv sshCfg wsRoot ceilingBytes (getSafePath sp)
  , wfsDoesFileExist = \rp -> do
      let rel = T.unpack (getRemotePath rp)
      case mkSafePathRemote wsRoot rel of
        Left _  -> pure False
        Right sp -> remoteTestFlag uioEnv sshCfg "-f" (getSafePath sp)
  , wfsDoesDirectoryExist = \rp -> do
      let rel = T.unpack (getRemotePath rp)
      case mkSafePathRemote wsRoot rel of
        Left _  -> pure False
        Right sp -> remoteTestFlag uioEnv sshCfg "-d" (getSafePath sp)
  , wfsListDirectory = \rp -> do
      let rel = T.unpack (getRemotePath rp)
      case mkSafePathRemote wsRoot rel of
        Left pe -> pure (Left (WfsPath pe))
        Right sp -> remoteListDirectory uioEnv sshCfg wsRoot (getSafePath sp)
  , wfsFileSize = \rp -> do
      let rel = T.unpack (getRemotePath rp)
      case mkSafePathRemote wsRoot rel of
        Left pe -> pure (Left (WfsPath pe))
        Right sp ->
          remoteStatRechecked uioEnv sshCfg wsRoot "%s" "%z" (getSafePath sp) >>= \case
            Left e -> pure (Left e)
            Right txt -> case parseInteger txt of
              Nothing -> pure (Left (WfsIo "stat size: non-numeric stdout"))
              Just n  -> pure (Right n)
  , wfsModificationTime = \rp -> do
      let rel = T.unpack (getRemotePath rp)
      case mkSafePathRemote wsRoot rel of
        Left pe -> pure (Left (WfsPath pe))
        Right sp ->
          remoteStatRechecked uioEnv sshCfg wsRoot "%Y" "%m" (getSafePath sp) >>= \case
            Left e -> pure (Left e)
            Right txt -> case parseInteger txt of
              Nothing -> pure (Left (WfsIo "stat mtime: non-numeric stdout"))
              Just n  -> pure (Right (posixSecondsToUTCTime (fromIntegral n)))
  , wfsSnapshot = remoteSnapshot uioEnv ceilingBytes
  }

-- | The depth-limited structural snapshot for the remote arm
-- ('wfsSnapshot'): ONE shell command runs two @find@ passes (directories,
-- then files) over the workspace root, separated by a marker line, with
-- the total output bounded by @head -c <ceiling>@.
--
-- /Portability/: @-maxdepth@ is not POSIX but is supported by GNU findutils,
-- BSD find, macOS find, and busybox — same de-facto-universal status as the
-- @readlink -f@ choice above. Symlinks are never followed (the default
-- @-P@ mode matches neither @-type d@ nor @-type f@), so an escaping symlink
-- can never contribute structure. Names containing newlines cannot be
-- represented in the line-based output — the same limitation as the
-- line-splitting of @ls -1@ elsewhere in this module.
remoteSnapshot :: UIOEnv -> Int -> IO (Either WorkdirFsErr WorkspaceSnapshot)
remoteSnapshot uioEnv ceilingBytes = do
  let cmd = T.pack $
        "{ find . -maxdepth " <> show snapshotMaxDepth <> " -type d -print;"
          <> " printf '\\n" <> T.unpack snapshotFilesMarker <> "\\n';"
          <> " find . -maxdepth " <> show snapshotMaxDepth <> " -type f -print; }"
          <> " 2>/dev/null | head -c " <> show ceilingBytes
  res <- remoteExecText uioEnv cmd
  pure $ case res of
    Left e  -> Left e
    Right out -> fmap WorkspaceSnapshot (parseSnapshotOutput ceilingBytes out)

-- | Parse the remote snapshot output: @find -type d@ lines (@./@-prefixed),
-- the 'snapshotFilesMarker' line, then @find -type f@ lines. Output at or
-- over the byte ceiling is treated as truncated ('WfsOversize' — a silently
-- truncated tree would yield wrong discovery results); a missing marker is
-- malformed output ('WfsIo'). The @.@ root line and any non-@./@ line are
-- skipped. Entries are sorted by path.
parseSnapshotOutput :: Int -> Text -> Either WorkdirFsErr [SnapshotEntry]
parseSnapshotOutput ceilingBytes out
  | T.length out >= ceilingBytes = Left WfsOversize
  | otherwise = case break (== snapshotFilesMarker) (T.lines out) of
      (dirLines, _marker : fileLines) -> do
        let entries =
              mapMaybe pathEntry dirLines  -- dirs
                <>
              [ SnapshotEntry p False | Just p <- map pathLine fileLines ]
        if length entries > maxSnapshotEntries
          then Left WfsOversize
          else Right (sortOn snapRelPath entries)
      _ -> Left (WfsIo "snapshot output missing files marker")
  where
    -- A find output line "./a/b" → the relative path "a/b". The bare "."
    -- root line and anything unexpected are skipped.
    pathLine :: Text -> Maybe Text
    pathLine ln =
      case T.stripPrefix "./" ln of
        Just rest | not (T.null rest) -> Just rest
        _ -> Nothing
    pathEntry :: Text -> Maybe SnapshotEntry
    pathEntry ln = SnapshotEntry <$> pathLine ln <*> pure True

-- | Run a remote shell command (a 'Text' command string) via 'uioShellExec'
-- in the shared 'UIOEnv'. The command runs with no cwd override (the paths
-- are absolute, SafePath-validated). Lifts the 'UntrustedErr' to a
-- 'WorkdirFsErr'.
--
-- /Portability/: the remote commands in this module avoid GNU-coreutils-
-- only flags so they work on both GNU/Linux and BSD/macOS remotes:
--   * @readlink -f --@ (not @realpath -f --@, which is GNU-only).
--   * @test -<flag> <path>@ (no @--@; the shell-builtin @test@ on zsh/BSD
--     rejects @--@). Safe because every path passed here is absolute
--     (starts with @/@, from 'mkSafePathRemote' + the workspace root), so
--     it can never be mistaken for a @test@ flag.
--   * @head -c <n> --@ for bounded reads (portable).
--   * @ls -1 --@ for directory listings (portable).
remoteExecText :: UIOEnv -> Text -> IO (Either WorkdirFsErr Text)
remoteExecText uioEnv cmdText =
  case mkShellCommand cmdText of
    Left e -> pure (Left (WfsIo e))
    Right cmd ->
      runUIOWithEnv uioEnv (uioShellExec cmd Nothing) >>= \case
        Left (UePath pe) -> pure (Left (WfsPath pe))
        Left (UeExec _)  -> pure (Left (WfsExec "remote shell exec failed"))
        Left (UeIo msg)  -> pure (Left (WfsIo msg))
        Left (UeBounded n) -> pure (Left (WfsIo ("bounded: " <> T.pack (show n))))
        Right out -> pure (Right out)

-- | Resolve a remote absolute path with @readlink -f -- <abspath>@, then
-- re-check lexical containment of the resolved path against the workspace
-- root. @readlink -f@ is used instead of GNU-only @realpath -f@ so the
-- command works on BSD/macOS remotes as well as GNU/Linux. Returns:
--
--   * @Right (Just resolved)@ — the resolved absolute path, contained.
--   * @Right Nothing@ — the path is missing on the remote (@readlink -f@
--     exits non-zero for a non-existent / unresolvable path on both GNU
--     and BSD).
--   * @Left err@ — exec failure, OR the resolved path escapes the workspace
--     root ('WfsPath').
remoteRealpathRecheck
  :: UIOEnv -> SshConfig -> WorkspaceRoot -> FilePath
  -> IO (Either WorkdirFsErr (Maybe FilePath))
remoteRealpathRecheck uioEnv _sshCfg wsRoot absPath = do
  let cmd = T.pack ("readlink -f -- " <> shellQuote absPath)
  remoteExecText uioEnv cmd >>= \case
    Left e -> pure (Left e)
    Right out
      | T.null (T.strip out) -> pure (Right Nothing)
      | otherwise ->
          let resolved = T.unpack (T.strip out)
          in case mkSafePathRemote wsRoot resolved of
               Left pe -> pure (Left (WfsPath pe))
               Right _ -> pure (Right (Just resolved))

-- | @wfsReadFile@ on the remote arm: @readlink -f@ → re-check containment →
-- bounded read via @head -c <ceil> --@ → raw 'Text'. A missing path's
-- @readlink -f@ failure yields 'WfsNotFound'. The byte cap (@head -c@)
-- replaces a prior @stat -c %s@ oversize pre-check (which was GNU-only and
-- broke on BSD/macOS remotes); @head -c@ is portable and still bounds the
-- read to at most @ceilingBytes@, so an oversize file is read partially
-- rather than rejected outright — acceptable for discovery (the section
-- truncation downstream caps content regardless).
remoteReadFile
  :: UIOEnv -> SshConfig -> WorkspaceRoot -> Int -> FilePath
  -> IO (Either WorkdirFsErr Text)
remoteReadFile uioEnv sshCfg wsRoot ceilingBytes absPath =
  remoteRealpathRecheck uioEnv sshCfg wsRoot absPath >>= \case
    Left e -> pure (Left e)
    Right Nothing -> pure (Left WfsNotFound)
    Right (Just resolved) -> do
      readRes <- remoteExecText uioEnv
        (T.pack ( "head -c " <> show ceilingBytes <> " -- "
               <> shellQuote resolved))
      case readRes of
        Left e -> pure (Left e)
        Right raw ->
          let trimmed = T.dropWhileEnd Char.isSpace raw
          in if T.null (T.strip trimmed)
               then pure (Left WfsNotFound)
               else pure (Right (truncateSection defaultSectionCharLimit trimmed))

-- | @wfsDoesFileExist@ / @wfsDoesDirectoryExist@ on the remote arm:
-- @test -<flag> <abspath>@ → parse stdout. Exempt from the @readlink -f@
-- re-check (1-bit bool, no target identity). The path is NOT preceded by
-- @--@ because the shell-builtin @test@ on zsh/BSD rejects @--@; this is
-- safe because every path here is absolute (starts with @/@ via
-- 'mkSafePathRemote' + the workspace root) and 'shellQuote'-d, so it
-- cannot be parsed as a @test@ flag.
remoteTestFlag :: UIOEnv -> SshConfig -> String -> FilePath -> IO Bool
remoteTestFlag uioEnv _sshCfg flag absPath = do
  let cmd = T.pack ("test " <> flag <> " " <> shellQuote absPath
                    <> " && echo y")
  remoteExecText uioEnv cmd >>= \case
    Right out -> pure (T.strip out == "y")
    Left _ -> pure False

-- | @wfsListDirectory@ on the remote arm: @readlink -f@ → re-check
-- containment → @ls -1 -- <resolved>@ → split lines. A missing path's
-- @readlink -f@ failure (or a missing dir) yields @Right []@ (fail-soft-to-
-- empty).
remoteListDirectory
  :: UIOEnv -> SshConfig -> WorkspaceRoot -> FilePath
  -> IO (Either WorkdirFsErr [Text])
remoteListDirectory uioEnv sshCfg wsRoot absPath =
  remoteRealpathRecheck uioEnv sshCfg wsRoot absPath >>= \case
    Left e -> pure (Left e)
    Right Nothing -> pure (Right [])
    Right (Just resolved) -> do
      lsRes <- remoteExecText uioEnv
                 (T.pack ("ls -1 -- " <> shellQuote resolved))
      case lsRes of
        Left e -> pure (Left e)
        Right out -> pure (Right (filter (not . T.null) (T.lines out)))

-- | A portable remote @stat@ for one numeric field. Tries GNU
-- @stat -c <fmt> --@ first; on a non-numeric / empty result (the BSD
-- @stat@ rejects @-c@), retries with BSD @stat -f <fmt>@ (no @--@, which
-- BSD @stat@ also rejects). Returns the raw stdout 'Text' on success.
-- A missing path's @readlink -f@ failure yields 'WfsNotFound'.
remoteStatRechecked
  :: UIOEnv -> SshConfig -> WorkspaceRoot -> String -> String -> FilePath
  -> IO (Either WorkdirFsErr Text)
remoteStatRechecked uioEnv sshCfg wsRoot gnuFmt bsdFmt absPath =
  remoteRealpathRecheck uioEnv sshCfg wsRoot absPath >>= \case
    Left e -> pure (Left e)
    Right Nothing -> pure (Left WfsNotFound)
    Right (Just resolved) -> do
      gnuRes <- remoteExecText uioEnv
                  (T.pack ("stat -c " <> gnuFmt <> " -- " <> shellQuote resolved))
      case gnuRes of
        Right out
          | not (T.null (T.strip out))
          , T.all isDigit (T.strip (T.dropWhile isSpace out)) -> pure (Right out)
        _ -> do
          bsdRes <- remoteExecText uioEnv
                      (T.pack ("stat -f" <> bsdFmt <> " " <> shellQuote resolved))
          case bsdRes of
            Left e -> pure (Left e)
            Right out -> pure (Right out)

-- | Parse a non-negative integer from 'Text' stdout (the output of
-- @stat -c %s@ / @stat -c %Y@). Total — returns 'Nothing' on any
-- non-numeric input (including negative or empty).
parseInteger :: Text -> Maybe Integer
parseInteger txt =
  let t = T.dropWhile isSpace (T.strip txt)
  in if not (T.null t) && T.all isDigit t
       then Just (read (T.unpack t))
       else Nothing

-- ---------------------------------------------------------------------------
-- In-memory stub arm
-- ---------------------------------------------------------------------------

-- | The maximum symlink-chain depth the in-memory stub will resolve before
-- rejecting with 'WfsIo'. Bounds against symlink loops.
maxSymlinkDepth :: Int
maxSymlinkDepth = 16

-- | The in-memory stub. The stub's 'wfsReadFile' resolves 'SymlinkTarget'
-- chains (depth-bounded), re-checks containment on the resolved path, and
-- rejects on escape — mirroring the real remote arm's @realpath@ logic so
-- the symlink-escape test is non-vacuous.
mkInMemWorkdirFs :: Map RemotePath StubEntry -> WorkdirFs
mkInMemWorkdirFs seed = WorkdirFs
  { wfsReadFile = pure . stubReadFile seed
  , wfsDoesFileExist = pure . stubDoesFileExist seed
  , wfsDoesDirectoryExist = pure . stubDoesDirectoryExist seed
  , wfsListDirectory = pure . stubListDirectory seed
  , wfsFileSize = pure . stubFileSize seed
  , wfsModificationTime = \_ -> pure (Right epochZero)
  , wfsSnapshot = pure (stubSnapshot seed)
  }

-- | Derive the structural snapshot from the in-memory seed ('wfsSnapshot'
-- on the stub arm). Mirrors the real arms' semantics:
--
--   * 'Directory' entries become dir entries; their listed children are
--     classified by seed lookup — 'FileContent' or an absent key ⇒ file,
--     another 'Directory' ⇒ dir (recursed), 'Missing' or 'SymlinkTarget'
--     ⇒ skipped (structure never follows symlinks).
--   * Depth- and count-bounded like the local/remote arms.
stubSnapshot :: Map RemotePath StubEntry -> Either WorkdirFsErr WorkspaceSnapshot
stubSnapshot seed =
  let rootNames = case Map.lookup (stubKey ".") seed of
        Just (Directory ns) -> sort ns
        _ -> let comps = sort [ firstComp (getRemotePath k)
                              | k <- Map.keys seed, getRemotePath k /= "." ]
             in Set.toAscList (Set.fromList comps)   -- sorted-dedup
      walk prefix names remaining
        | remaining <= 0 = []
        | otherwise = concatMap (step prefix remaining) names
      step prefix remaining name =
        let childRel = joinRel prefix name
        in case Map.lookup (stubKey childRel) seed of
             Just (Directory ns) ->
               SnapshotEntry childRel True : walk childRel (sort ns) (remaining - 1)
             Just Missing -> []
             Just (SymlinkTarget _) -> []   -- structure never follows symlinks
             Just (FileContent _) -> [SnapshotEntry childRel False]
             Nothing -> [SnapshotEntry childRel False]  -- implicit child = file
      entries = walk "" rootNames snapshotMaxDepth
  in if length entries > maxSnapshotEntries
       then Left WfsOversize
       else Right (WorkspaceSnapshot (sortOn snapRelPath entries))
  where
    stubKey t = case mkRemotePath t of
      Right k  -> k
      Left err -> error ("stubSnapshot: invalid seeded path: " <> T.unpack err
                         <> ": " <> T.unpack t)
    firstComp = T.takeWhile (/= '/')
    joinRel prefix name
      | T.null prefix = name
      | otherwise     = prefix <> "/" <> name

-- | Resolve a 'RemotePath' through 'SymlinkTarget' chains, re-checking
-- containment on the resolved path at each step. Returns 'Right' with the
-- final 'RemotePath' pointing at a non-symlink entry, or 'Left' on
-- escape / loop / missing.
resolveSymlinkChain
  :: Map RemotePath StubEntry
  -> RemotePath
  -> Either WorkdirFsErr StubEntry
resolveSymlinkChain seed = go 0
  where
    go depth rp
      | depth > maxSymlinkDepth = Left (WfsIo "symlink chain too deep")
      | otherwise = case Map.lookup rp seed of
          Nothing -> Left WfsNotFound
          Just Missing -> Left WfsNotFound
          Just (SymlinkTarget target) ->
            case checkContainment target of
              Left pe -> Left (WfsPath pe)
              Right _ -> go (depth + 1) target
          Just entry -> Right entry

-- | Lexical containment check on a 'RemotePath' against the stub's
-- workspace root (@\/workspace@). Mirrors 'mkSafePathRemote' — a path
-- that lexically escapes the root (e.g. @\/etc\/shadow@, @..\/passwd@) is
-- rejected.
checkContainment :: RemotePath -> Either PathError ()
checkContainment rp =
  case mkSafePathRemote stubWorkspaceRoot (T.unpack (getRemotePath rp)) of
    Left pe -> Left pe
    Right _ -> Right ()

-- | The stub's workspace root. A fixed absolute path so that relative
-- seeded keys (e.g. @agents.md@) anchor under it and absolute escaping
-- paths (e.g. @\/etc\/shadow@) are rejected by 'mkSafePathRemote'.
stubWorkspaceRoot :: WorkspaceRoot
stubWorkspaceRoot = WorkspaceRoot "/workspace"

-- | Read a file from the in-memory stub. Resolves symlinks, re-checks
-- containment, returns the (truncated) content.
stubReadFile :: Map RemotePath StubEntry -> RemotePath -> Either WorkdirFsErr Text
stubReadFile seed rp = case checkContainment rp of
  Left pe -> Left (WfsPath pe)
  Right _ -> case resolveSymlinkChain seed rp of
      Left e -> Left e
      Right (FileContent txt) ->
        let trimmed = T.dropWhileEnd Char.isSpace txt
        in if T.null (T.strip trimmed)
             then Left WfsNotFound
             else Right (truncateSection defaultSectionCharLimit trimmed)
      Right (Directory _) -> Left (WfsIo "is a directory")
      Right Missing -> Left WfsNotFound
      Right (SymlinkTarget _) -> Left (WfsIo "unresolved symlink")

-- | Existence check for a file in the in-memory stub. Resolves symlinks.
stubDoesFileExist :: Map RemotePath StubEntry -> RemotePath -> Bool
stubDoesFileExist seed rp = case checkContainment rp of
  Left _ -> False
  Right _ -> case resolveSymlinkChain seed rp of
      Right (FileContent _) -> True
      _ -> False

-- | Existence check for a directory in the in-memory stub. Does NOT
-- resolve symlinks (a 'SymlinkTarget' is not a directory in the stub
-- model).
stubDoesDirectoryExist :: Map RemotePath StubEntry -> RemotePath -> Bool
stubDoesDirectoryExist seed rp = case checkContainment rp of
  Left _ -> False
  Right _ -> case Map.lookup rp seed of
      Just (Directory _) -> True
      _ -> False

-- | List the immediate children of a directory in the in-memory stub.
-- Returns @Right []@ on a missing directory (fail-soft-to-empty).
stubListDirectory :: Map RemotePath StubEntry -> RemotePath -> Either WorkdirFsErr [Text]
stubListDirectory seed rp = case checkContainment rp of
  Left pe -> Left (WfsPath pe)
  Right _ -> case Map.lookup rp seed of
      Nothing -> Right []
      Just Missing -> Right []
      Just (Directory names) -> Right names
      Just (FileContent _) -> Left (WfsIo "not a directory")
      Just (SymlinkTarget _) -> Left (WfsIo "not a directory")

-- | File size in the in-memory stub (byte length of the 'FileContent').
stubFileSize :: Map RemotePath StubEntry -> RemotePath -> Either WorkdirFsErr Integer
stubFileSize seed rp = case checkContainment rp of
  Left pe -> Left (WfsPath pe)
  Right _ -> case resolveSymlinkChain seed rp of
      Left e -> Left e
      Right (FileContent txt) -> Right (fromIntegral (T.length txt))
      Right (Directory _) -> Left (WfsIo "is a directory")
      Right Missing -> Left WfsNotFound
      Right (SymlinkTarget _) -> Left (WfsIo "unresolved symlink")

-- ---------------------------------------------------------------------------
-- Fail-closed stub
-- ---------------------------------------------------------------------------

-- | The fail-closed stub. Every read yields 'Left WfsStub', every
-- existence check yields 'False', 'wfsListDirectory' yields 'Right []'.
mkWorkdirFsStub :: WorkdirFs
mkWorkdirFsStub = WorkdirFs
  { wfsReadFile = \_ -> pure (Left WfsStub)
  , wfsDoesFileExist = \_ -> pure False
  , wfsDoesDirectoryExist = \_ -> pure False
  , wfsListDirectory = \_ -> pure (Right [])
  , wfsFileSize = \_ -> pure (Left WfsStub)
  , wfsModificationTime = \_ -> pure (Left WfsStub)
  , wfsSnapshot = pure (Left WfsStub)
  }

-- ---------------------------------------------------------------------------
-- Snapshot accessors (pure; consumed by the discovery scanners)
-- ---------------------------------------------------------------------------

-- | The workspace root-relative path of a direct child of @base@
-- (@""@ = the root itself).
snapJoin :: Text -> Text -> Text
snapJoin base name
  | T.null base = name
  | otherwise   = base <> "/" <> name

-- | Does @path@ exist in the snapshot as a directory? Convention dirs are
-- dot-dirs reached by DIRECT path (e.g. @@repo/.agents@@), so lookups are
-- unfiltered.
snapIsDirectoryAt :: WorkspaceSnapshot -> Text -> Bool
snapIsDirectoryAt snap path =
  any (\e -> snapRelPath e == path && snapIsDir e) (snapEntries snap)

-- | Does @path@ exist in the snapshot as a regular file?
snapIsFileAt :: WorkspaceSnapshot -> Text -> Bool
snapIsFileAt snap path =
  any (\e -> snapRelPath e == path && not (snapIsDir e)) (snapEntries snap)

-- | The immediate child NAMES (both kinds) of @base@ whose basename is
-- visible (non-hidden — parity with @ls -1@). Sorted.
snapChildNamesAt :: WorkspaceSnapshot -> Text -> [Text]
snapChildNamesAt snap base =
  sort
    [ name
    | e <- snapEntries snap
    , let rel = snapRelPath e
    , T.isPrefixOf prefix rel
    , T.length rel > T.length prefix
    , let name = T.drop (T.length prefix) rel
    , not (T.isInfixOf "/" name)
    , not ("." `T.isPrefixOf` name)
    ]
  where
    prefix = if T.null base then "" else base <> "/"

-- | The immediate visible child DIRECTORIES of @base@, as full relative
-- paths, sorted. Hidden children are excluded (parity with @ls -1@).
snapChildDirsAt :: WorkspaceSnapshot -> Text -> [Text]
snapChildDirsAt snap base =
  [ snapJoin base n | n <- snapChildNamesAt snap base, snapIsDirectoryAt snap (snapJoin base n) ]

-- | The immediate visible child FILES of @base@, as full relative paths,
-- sorted. Hidden children are excluded (parity with @ls -1@).
snapChildFilesAt :: WorkspaceSnapshot -> Text -> [Text]
snapChildFilesAt snap base =
  [ snapJoin base n | n <- snapChildNamesAt snap base, snapIsFileAt snap (snapJoin base n) ]

-- | The top-level visible directories of the snapshot (the cloned repo
-- names), sorted.
snapTopDirs :: WorkspaceSnapshot -> [Text]
snapTopDirs snap = snapChildDirsAt snap ""

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- | The epoch zero timestamp, used as a fallback for the in-memory stub's
-- 'wfsModificationTime' (which has no real mtime).
epochZero :: UTCTime
epochZero = UTCTime (fromGregorian 1970 1 1) (secondsToDiffTime 0)