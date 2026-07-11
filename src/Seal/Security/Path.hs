module Seal.Security.Path
  ( SafePath
  , getSafePath
  , WorkspaceRoot (..)
  , PathError (..)
  , mkSafePath
  , mkSafePathForWrite
  , KeysRoot (..)
  , ensureKeysRoot
  , SafeKeyPath
  , getSafeKeyPath
  , mkSafeKeyPath
  ) where

import Control.Exception (IOException, try)
import Data.List (isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesPathExist)
import System.FilePath (isAbsolute, joinPath, splitDirectories, (</>))
import System.Posix.Files
  ( fileMode
  , fileOwner
  , getFileStatus
  , intersectFileModes
  , setFileMode
  )
import System.Posix.User (getEffectiveUserID)

newtype SafePath = SafePath FilePath
  deriving stock (Show)

getSafePath :: SafePath -> FilePath
getSafePath (SafePath p) = p

newtype WorkspaceRoot = WorkspaceRoot FilePath

data PathError
  = PathEscapesWorkspace FilePath
  | PathIsBlocked Text
  | PathDoesNotExist FilePath
  | PathInsecureMode FilePath
  deriving stock (Eq, Show)

blockedNames :: [FilePath]
blockedNames = [".env", ".ssh", ".gnupg", ".netrc", ".seal"]

-- | Lexically collapse @.@ and @..@ segments without touching the filesystem.
-- A @..@ removes the preceding ordinary segment; if there is none (or the
-- predecessor is itself an un-collapsible @..@) the @..@ is retained, so an
-- attempt to climb above the root survives into the containment check and is
-- rejected there rather than being silently normalised away.
lexicalCollapse :: [FilePath] -> [FilePath]
lexicalCollapse = reverse . foldl' step []
  where
    step acc "." = acc
    step (x : xs) ".." | x /= ".." = xs
    step acc seg = seg : acc

-- | Validate that a requested path is safely confined within the workspace.
--
-- Steps (in order):
--   1. Reject if any segment of the requested path is a blocked name.
--   2. Lexically collapse @..@/@.@ in the joined path (no filesystem access)
--      and reject with 'PathEscapesWorkspace' if it leaves the root. This is a
--      purely lexical determination, so a @..@ escape is caught BEFORE any
--      filesystem call — independent of whether the target exists.
--   3. Canonicalize the joined path (follows symlinks); a missing final
--      component makes @canonicalizePath@ throw, caught as 'PathDoesNotExist'.
--   4. Re-run the containment check on the canonical path to catch symlinks
--      that resolve outside the workspace.
--   5. Confirm the path exists; return 'SafePath' on success.
--
-- Containment check approach: component-wise prefix test via
-- @splitDirectories canonRoot \`isPrefixOf\` splitDirectories candidate@,
-- which correctly rejects @\/ws\/barbaz@ as not inside @\/ws\/bar@.
mkSafePath :: WorkspaceRoot -> FilePath -> IO (Either PathError SafePath)
mkSafePath (WorkspaceRoot root) requested = do
  canonRoot <- canonicalizePath root
  -- 1. Blocked-name check (pure, on the segments of the requested path).
  if any (`elem` blockedNames) (splitDirectories requested)
    then pure $ Left $ PathIsBlocked $ T.pack $ "path touches a blocked location: " <> requested
    else do
      let joined = if isAbsolute requested then requested else canonRoot </> requested
          rootDirs = splitDirectories canonRoot
          -- 2. Lexically resolve `..`/`.` and check containment, no filesystem access.
          lexicalDirs = lexicalCollapse (splitDirectories joined)
      if not (rootDirs `isPrefixOf` lexicalDirs)
        then pure $ Left $ PathEscapesWorkspace (joinPath lexicalDirs)
        else resolveAndCheck rootDirs joined (joinPath lexicalDirs)

  where
    resolveAndCheck rootDirs joined lexical = do
      -- 3. Canonicalize (follows symlinks). Throws IOException if path is missing.
      canonResult <- try (canonicalizePath joined) :: IO (Either IOException FilePath)
      case canonResult of
        Left _ -> pure $ Left $ PathDoesNotExist lexical
        Right canon ->
          -- 4. Post-canonicalization containment check: catches symlink escapes.
          if not (rootDirs `isPrefixOf` splitDirectories canon)
            then pure $ Left $ PathEscapesWorkspace canon
            else do
              exists <- doesPathExist canon
              if not exists
                then pure $ Left $ PathDoesNotExist canon
                else pure $ Right $ SafePath canon

-- | Like 'mkSafePath' but allows the final path component to NOT exist
-- (for FILE_WRITE: the file may be created fresh). Steps 1-2 (blocked-name
-- + lexical collapse + containment) are identical. Step 3 canonicalizes
-- the PARENT (which must exist), then re-joins the final component. Step 4
-- confirms the parent is contained; the final component's existence is
-- irrelevant (it may or may not exist).
mkSafePathForWrite :: WorkspaceRoot -> FilePath -> IO (Either PathError SafePath)
mkSafePathForWrite (WorkspaceRoot root) requested = do
  canonRoot <- canonicalizePath root
  if any (`elem` blockedNames) (splitDirectories requested)
    then pure $ Left $ PathIsBlocked $ T.pack $ "path touches a blocked location: " <> requested
    else do
      let joined = if isAbsolute requested then requested else canonRoot </> requested
          rootDirs = splitDirectories canonRoot
          lexicalDirs = lexicalCollapse (splitDirectories joined)
      if not (rootDirs `isPrefixOf` lexicalDirs)
        then pure $ Left $ PathEscapesWorkspace (joinPath lexicalDirs)
        else do
          -- Canonicalize the parent (must exist), then re-join the final
          -- component. If the parent doesn't exist, the canonicalization
          -- fails → PathDoesNotExist (the parent must exist for a write).
          let lexicalPath = joinPath lexicalDirs
          case splitDirectories lexicalPath of
            [] -> pure $ Left $ PathEscapesWorkspace lexicalPath
            [_] ->
              -- The path is a single component (the root itself); writing
              -- the root is not meaningful, but the root exists.
              resolveParentAndCheck rootDirs lexicalPath canonRoot
            segments ->
              let parentLex = joinPath (init segments)
              in resolveParentAndCheck rootDirs lexicalPath
                   =<< canonicalizePath parentLex
  where
    resolveParentAndCheck rootDirs lexicalPath canonParent = do
      -- Step 4: confirm the canonical parent is contained.
      if not (rootDirs `isPrefixOf` splitDirectories canonParent)
        then pure $ Left $ PathEscapesWorkspace canonParent
        else do
          parentExists <- doesPathExist canonParent
          if not parentExists
            then pure $ Left $ PathDoesNotExist canonParent
            else pure $ Right $ SafePath lexicalPath

-- ---------------------------------------------------------------------------
-- Key-material confinement
-- ---------------------------------------------------------------------------

newtype KeysRoot = KeysRoot FilePath
  deriving stock (Eq, Show)

-- | Create (mkdir -p) and harden (chmod 0700) a keys directory, returning a
-- typed 'KeysRoot'. Idempotent — safe to call on an already-existing directory.
ensureKeysRoot :: FilePath -> IO KeysRoot
ensureKeysRoot dir = do
  createDirectoryIfMissing True dir
  setFileMode dir 0o700
  pure (KeysRoot dir)

-- | An absolute path that has been verified to be safely confined within a
-- 'KeysRoot' directory (no @..@ escape, no symlink escape, and — if the file
-- already exists — owned by the effective user with mode 0600 or 0400). The
-- constructor is intentionally not exported; obtain a value via 'mkSafeKeyPath'.
newtype SafeKeyPath = SafeKeyPath FilePath

-- | The 'Show' instance deliberately omits the path to prevent accidental
-- disclosure in logs or error messages.
instance Show SafeKeyPath where
  show _ = "SafeKeyPath <redacted>"

getSafeKeyPath :: SafeKeyPath -> FilePath
getSafeKeyPath (SafeKeyPath p) = p

-- | Validate that a requested path is safely confined within the 'KeysRoot'.
--
-- Steps (in order):
--   1. Lexically collapse @..@\/@.@ and check containment under the root —
--      identical to 'mkSafePath' (reuses 'lexicalCollapse' + component-wise
--      @splitDirectories@ prefix check).
--   2. Canonicalize (follows symlinks); re-run the containment check to catch
--      symlink escapes.
--   3. If the target does not yet exist (key to be written later): return
--      @Right@ with the lexically-resolved path.
--   4. If the target exists: require @fileOwner == getEffectiveUserID@ and
--      @fileMode & 0o777 ∈ {0o600, 0o400}@; otherwise return
--      @Left (PathInsecureMode path)@.
mkSafeKeyPath :: KeysRoot -> FilePath -> IO (Either PathError SafeKeyPath)
mkSafeKeyPath (KeysRoot root) requested = do
  canonRoot <- canonicalizePath root
  let joined = if isAbsolute requested then requested else canonRoot </> requested
      rootDirs = splitDirectories canonRoot
      lexicalDirs = lexicalCollapse (splitDirectories joined)
  if not (rootDirs `isPrefixOf` lexicalDirs)
    then pure $ Left $ PathEscapesWorkspace (joinPath lexicalDirs)
    else do
      canonResult <- try (canonicalizePath joined) :: IO (Either IOException FilePath)
      case canonResult of
        Left _ ->
          -- Path does not exist yet — allowed; the caller will create it.
          pure $ Right $ SafeKeyPath (joinPath lexicalDirs)
        Right canon ->
          if not (rootDirs `isPrefixOf` splitDirectories canon)
            then pure $ Left $ PathEscapesWorkspace canon
            else do
              exists <- doesPathExist canon
              if not exists
                -- canonicalizePath resolved the parent but the file is absent —
                -- still allowed; the caller will create it.
                then pure $ Right $ SafeKeyPath canon
                else checkSecurity canon
  where
    checkSecurity canon = do
      status <- getFileStatus canon
      euid <- getEffectiveUserID
      let owner = fileOwner status
          mode = fileMode status `intersectFileModes` 0o777
      if (owner /= euid) || (mode `notElem` [0o600, 0o400])
        then pure $ Left $ PathInsecureMode canon
        else pure $ Right $ SafeKeyPath canon
