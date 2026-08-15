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
  , mkInMemWorkdirFs
  , mkWorkdirFsStub
  , StubEntry (..)
  ) where

import Control.Exception (IOException, try)
import Data.Char qualified as Char
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime (..))
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (secondsToDiffTime)
import System.Directory
  ( doesDirectoryExist, doesFileExist, getFileSize, getModificationTime
  , listDirectory
  )

import Seal.Security.Path
  ( PathError (..), WorkspaceRoot (..), getSafePath, mkSafePath
  , mkSafePathRemote
  )
import Seal.Tools.Exec.Types (RemotePath, getRemotePath)

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