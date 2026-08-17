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
  , mkLocalWorkdirFs
  , mkRemoteWorkdirFs
  , mkInMemWorkdirFs
  , mkWorkdirFsStub
  , StubEntry (..)
  ) where

import Control.Exception (IOException, try)
import Data.Char (isDigit, isSpace)
import Data.Char qualified as Char
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime (..))
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (secondsToDiffTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import System.Directory
  ( doesDirectoryExist, doesFileExist, getFileSize, getModificationTime
  , listDirectory
  )

import Seal.Security.Path
  ( PathError (..), WorkspaceRoot (..), getSafePath, mkSafePath
  , mkSafePathRemote
  )
import Seal.Tools.Args (mkShellCommand)
import Seal.Tools.Exec.Types (RemotePath, SshConfig, getRemotePath)
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
  }

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
  }

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
  }

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
  }

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
  }

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- | The epoch zero timestamp, used as a fallback for the in-memory stub's
-- 'wfsModificationTime' (which has no real mtime).
epochZero :: UTCTime
epochZero = UTCTime (fromGregorian 1970 1 1) (secondsToDiffTime 0)