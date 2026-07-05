module Seal.Config.Paths
  ( SealPaths (..)
  , resolveSealHome
  , getSealPaths
  , ensureSealDirs
  , configFilePath
  , vaultFilePath
  , sessionsRoot
  , sessionDir
  , sessionMetaPath
  , sessionTranscriptPath
  , sessionConversationPath
  , sessionEntriesPath
  ) where

import System.Directory (createDirectoryIfMissing, getHomeDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>), takeDirectory)
import System.Posix.Files (setFileMode)

import Data.Text qualified as T

import Seal.Core.Types (SessionId, sessionIdText)

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
  -- The vault lives in a subdirectory of config/ ('vaultFilePath'); create it
  -- so the atomic vault write has an existing parent for its .tmp file.
  createDirectoryIfMissing True (takeDirectory (vaultFilePath paths))
  setFileMode (spKeys paths) 0o700

-- | Absolute path to the TOML config file: @\<config\>\/config.toml@.
configFilePath :: SealPaths -> FilePath
configFilePath paths = spConfig paths </> "config.toml"

-- | Absolute path to the encrypted vault file:
-- @\<config\>\/vault\/vault.age@.
vaultFilePath :: SealPaths -> FilePath
vaultFilePath paths = spConfig paths </> "vault" </> "vault.age"

-- | Root directory holding one subdirectory per session: @\<state\>\/sessions@.
sessionsRoot :: SealPaths -> FilePath
sessionsRoot paths = spState paths </> "sessions"

-- | Directory for one session: @\<state\>\/sessions\/\<id\>@.
sessionDir :: SealPaths -> SessionId -> FilePath
sessionDir paths sid = sessionsRoot paths </> T.unpack (sessionIdText sid)

-- | The session's metadata file: @\<sessionDir\>\/session.json@.
sessionMetaPath :: SealPaths -> SessionId -> FilePath
sessionMetaPath paths sid = sessionDir paths sid </> "session.json"

-- | The session's transcript: @\<sessionDir\>\/transcript.jsonl@.
sessionTranscriptPath :: SealPaths -> SessionId -> FilePath
sessionTranscriptPath paths sid = sessionDir paths sid </> "transcript.jsonl"

-- | The session's conversation file (new two-file format): @\<sessionDir\>\/conversation.jsonl@.
sessionConversationPath :: SealPaths -> SessionId -> FilePath
sessionConversationPath paths sid = sessionDir paths sid </> "conversation.jsonl"

-- | The session's entry log (new two-file format): @\<sessionDir\>\/entries.jsonl@.
sessionEntriesPath :: SealPaths -> SessionId -> FilePath
sessionEntriesPath paths sid = sessionDir paths sid </> "entries.jsonl"

