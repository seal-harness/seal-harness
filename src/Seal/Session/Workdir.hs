{-# LANGUAGE OverloadedStrings #-}
-- | Per-session workdir lifecycle: creation, cleanup, and validation.
-- Each session gets a fresh working directory at
-- @~/.seal/cache/workdirs/<session-id>@. The untrusted opcodes' workspace
-- root is this directory, not the cwd.
module Seal.Session.Workdir
  ( WorkdirError (..)
  , ensureSessionWorkdir
  , cleanupSessionWorkdir
  ) where

import Control.Exception (IOException, try)
import Data.List (isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory
  ( canonicalizePath, createDirectoryIfMissing, doesDirectoryExist
  , removeDirectoryRecursive )
import System.FilePath (splitDirectories)

import Seal.Config.Paths (SealPaths (..), sessionWorkdir, workdirsRoot)
import Seal.Core.Types (SessionId, sessionIdText, isValidSessionId)

-- | The error type for workdir lifecycle operations.
data WorkdirError
  = WdMkdirFailed FilePath Text      -- ^ local mkdir failed (path, reason)
  | WdRemoteMkdirFailed Text          -- ^ remote SSH mkdir failed (reason)
  | WdInvalidSessionId Text           -- ^ SessionId failed validation
  | WdNotUnderWorkdirsRoot FilePath    -- ^ cleanup path escaped workdirsRoot
  deriving stock (Eq, Show)

-- | Create the per-session workdir at @<cache>/workdirs/<sid>@.
-- Idempotent: if the workdir already exists, it is reused (NOT cleared —
-- the operator may want to resume or inspect). Returns the workdir path
-- on success. Fails closed on permission errors (does NOT fall back to
-- the cwd — that would reintroduce the cross-session clobber bug).
ensureSessionWorkdir :: SealPaths -> SessionId -> IO (Either WorkdirError FilePath)
ensureSessionWorkdir paths sid = do
  let sidText = sessionIdText sid
  if not (isValidSessionId sidText)
    then pure (Left (WdInvalidSessionId sidText))
    else do
      let wdPath = sessionWorkdir paths sid
      eResult <- try (createDirectoryIfMissing True wdPath) :: IO (Either IOException ())
      pure $ case eResult of
        Left ioErr -> Left (WdMkdirFailed wdPath (T.pack (show ioErr)))
        Right _   -> Right wdPath

-- | Remove the per-session workdir. Asserts the path is under
-- 'workdirsRoot' (canonicalize + prefix check — defeats symlink swap).
-- Idempotent: no error if the workdir is already gone. Returns
-- 'Either WorkdirError ()' so cleanup failures are not silently
-- swallowed.
cleanupSessionWorkdir :: SealPaths -> SessionId -> IO (Either WorkdirError ())
cleanupSessionWorkdir paths sid = do
  let sidText = sessionIdText sid
  if not (isValidSessionId sidText)
    then pure (Left (WdInvalidSessionId sidText))
    else do
      let wdPath = sessionWorkdir paths sid
          wdRoot = workdirsRoot paths
      exists <- doesDirectoryExist wdPath
      if not exists
        then pure (Right ())  -- already gone — idempotent
        else do
          -- Defense-in-depth: canonicalize and verify the path is under
          -- workdirsRoot before rm -rf (defeats symlink swap).
          canonWd <- canonicalizePath wdPath
          canonRoot <- canonicalizePath wdRoot
          if not (splitDirectories canonRoot `isPrefixOf` splitDirectories canonWd)
            then pure (Left (WdNotUnderWorkdirsRoot canonWd))
            else do
              eResult <- try (removeDirectoryRecursive canonWd) :: IO (Either IOException ())
              pure $ case eResult of
                Left ioErr -> Left (WdMkdirFailed canonWd (T.pack (show ioErr)))
                Right _   -> Right ()