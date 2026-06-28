module Seal.Security.Path
  ( SafePath
  , getSafePath
  , WorkspaceRoot (..)
  , PathError (..)
  , mkSafePath
  ) where

import Control.Exception (IOException, try)
import Data.List (isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (canonicalizePath, doesPathExist)
import System.FilePath (isAbsolute, joinPath, splitDirectories, (</>))

newtype SafePath = SafePath FilePath
  deriving stock (Show)

getSafePath :: SafePath -> FilePath
getSafePath (SafePath p) = p

newtype WorkspaceRoot = WorkspaceRoot FilePath

data PathError
  = PathEscapesWorkspace FilePath
  | PathIsBlocked Text
  | PathDoesNotExist FilePath
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
