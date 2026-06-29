module Seal.Config.Paths
  ( SealPaths (..)
  , resolveSealHome
  , getSealPaths
  , ensureSealDirs
  , configFilePath
  , vaultFilePath
  , keyFilePath
  ) where

import System.Directory (createDirectoryIfMissing, getHomeDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

-- | All paths derived from the seal home directory.
--
-- * 'spConfig' — version-controllable config tree; ordinary directory
-- * 'spState'  — mutable runtime state; ordinary directory
-- * 'spKeys'   — key material; created mode 0700, never version-controlled
data SealPaths = SealPaths
  { spHome   :: FilePath   -- ^ @SEAL_HOME@ env var or @~\/.seal@
  , spConfig :: FilePath   -- ^ @\<home\>\/config@
  , spState  :: FilePath   -- ^ @\<home\>\/state@
  , spKeys   :: FilePath   -- ^ @\<home\>\/keys@
  } deriving stock (Eq, Show)

-- | Resolve the seal home directory.
--
-- Returns the value of @SEAL_HOME@ when the variable is set; otherwise
-- returns @~\/.seal@ via 'getHomeDirectory'.
resolveSealHome :: IO FilePath
resolveSealHome = do
  mEnv <- lookupEnv "SEAL_HOME"
  case mEnv of
    Just h  -> pure h
    Nothing -> do
      home <- getHomeDirectory
      pure (home </> ".seal")

-- | Compute all sub-paths under the seal home directory without touching
-- the filesystem.
getSealPaths :: IO SealPaths
getSealPaths = do
  home <- resolveSealHome
  pure SealPaths
    { spHome   = home
    , spConfig = home </> "config"
    , spState  = home </> "state"
    , spKeys   = home </> "keys"
    }

-- | Create the seal directory tree, setting restrictive permissions on the
-- keys directory.
--
-- * @config\/@ and @state\/@ are created with default (umask-governed) mode.
-- * @keys\/@ is created and then explicitly set to mode @0700@.
--
-- Calling this function when the directories already exist is safe
-- ('createDirectoryIfMissing' is idempotent; 'setFileMode' is idempotent).
ensureSealDirs :: SealPaths -> IO ()
ensureSealDirs paths = do
  createDirectoryIfMissing True (spConfig paths)
  createDirectoryIfMissing True (spState  paths)
  createDirectoryIfMissing True (spKeys   paths)
  setFileMode (spKeys paths) 0o700

-- | Absolute path to the TOML config file: @\<config\>\/config.toml@.
configFilePath :: SealPaths -> FilePath
configFilePath paths = spConfig paths </> "config.toml"

-- | Absolute path to the encrypted vault file:
-- @\<config\>\/vault\/vault.age@.
vaultFilePath :: SealPaths -> FilePath
vaultFilePath paths = spConfig paths </> "vault" </> "vault.age"

-- | Absolute path to a named key file under @\<keys\>\/@.
keyFilePath :: SealPaths -> FilePath -> FilePath
keyFilePath paths name = spKeys paths </> name
