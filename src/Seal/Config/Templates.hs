{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
-- | First-run scaffolding for the two operator-editable configuration files.
--
-- A fresh install has no @config.toml@ and no @security.toml@, and both loaders
-- treat an absent file as "use the built-in defaults". Seal works that way, but
-- the option surface is then invisible until someone reads the source. This
-- module ships the surface: each template lists the keys its codec accepts,
-- with the value Seal would use — written out where a written value resolves to
-- the same behaviour as an absent key, commented out where it does not (the
-- default is "unset", the value names something only the operator knows, or the
-- value is machine-absolute).
--
-- The templates are embedded with 'file-embed', the mechanism
-- 'Seal.Skills.Builtins' already uses for built-in skills, so a binary always
-- carries the version of the file it shipped with: no install-layout
-- dependency, no first-run download, no staleness across upgrades.
--
-- Two invariants, both load-bearing:
--
-- * __Never overwrite.__ An existing file is the operator's (or an earlier
--   run's, or a program's). A scaffold that clobbered it would undo hand edits
--   on every boot.
-- * __Never change behaviour.__ Writing a template has to resolve to exactly
--   the configuration of leaving both files absent.
--   @Seal.Config.TemplatesSpec@ asserts both. The @security.toml@ half is also
--   skipped while @config.toml@ still carries pre-split security fields:
--   creating the file there would make 'Seal.Config.Migrate' read the install as
--   already migrated — its "security.toml wins" branch — and drop the operator's
--   vault settings.
module Seal.Config.Templates
  ( configTomlTemplate
  , securityTomlTemplate
  , ensureConfigTemplates
  ) where

import Control.Exception (IOException, bracketOnError, displayException, try)
import Control.Monad (void)
import Data.ByteString qualified as BS
import Data.Either (lefts, rights)
import Data.Maybe (catMaybes)
import Data.FileEmbed (embedFile)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Language.Haskell.TH.Syntax (qAddDependentFile)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.FilePath (takeDirectory)
import System.IO (hClose)
import System.IO.Error (isAlreadyExistsError)
import System.Posix.Files (createLink, setFileMode)

import Seal.Config.Migrate (configHasLegacySecurityFields)
import Seal.Config.Paths
  ( SealPaths, configFilePath, securityFilePath )
import Seal.Config.Security (openUniqueTemp)

-- | The bytes of @config\/templates\/config.toml@, embedded at compile time.
configTomlTemplate :: Text
configTomlTemplate = TE.decodeUtf8 $(do
  qAddDependentFile "config/templates/config.toml"
  embedFile "config/templates/config.toml")

-- | The bytes of @config\/templates\/security.toml@, embedded at compile time.
securityTomlTemplate :: Text
securityTomlTemplate = TE.decodeUtf8 $(do
  qAddDependentFile "config/templates/security.toml"
  embedFile "config/templates/security.toml")

-- | How a template is written.
--
-- @security.toml@ holds boot-critical state, so it is created @0600@ with
-- @O_NOFOLLOW@ through 'writeSecretFile' — the same primitive its other writers
-- use. The runtime config is ordinary data and is written like
-- 'Seal.Config.File.saveRuntimeConfig' writes it.
data FileSensitivity = SecretFile | PlainFile
  deriving stock (Eq, Show)

-- | Write whichever of the two templates is missing.
--
-- Returns the files it created and the problems it hit. A failure is per-file:
-- an unwritable @config.toml@ does not stop @security.toml@ from being written,
-- and neither failure is thrown at the caller — a missing template must never
-- stop the harness from booting.
ensureConfigTemplates :: SealPaths -> IO ([FilePath], [Text])
ensureConfigTemplates paths = do
  cfgOutcome <- seedFile (configFilePath paths) configTomlTemplate PlainFile
  secOutcome <- seedSecurity paths
  let created = catMaybes (rights [cfgOutcome, secOutcome])
      problems = lefts [cfgOutcome, secOutcome]
  pure (created, problems)

-- | @security.toml@, unless a migration still owns the operator's settings.
seedSecurity :: SealPaths -> IO (Either Text (Maybe FilePath))
seedSecurity paths = do
  carries <- configCarriesLegacyFields (configFilePath paths)
  case carries of
    Left err -> pure (Left err)
    -- Defer. `seal serve` and `seal tui` run 'Seal.Config.Migrate.migrateSecurityConfig'
    -- before this, and the migration moves those fields into security.toml.
    -- Creating the file first would flip the migration's file-existence test to
    -- its "security.toml wins" branch and silently drop them.
    Right True  -> pure (Right Nothing)
    Right False -> seedFile (securityFilePath paths) securityTomlTemplate SecretFile

-- | Does the existing @config.toml@ still carry pre-split security fields?
configCarriesLegacyFields :: FilePath -> IO (Either Text Bool)
configCarriesLegacyFields path = do
  exists <- doesFileExist path
  if not exists
    then pure (Right False)
    else do
      read' <- try (TIO.readFile path) :: IO (Either IOException Text)
      pure $ case read' of
        Left err       -> Left (describeReadError path err)
        Right contents -> Right (configHasLegacySecurityFields contents)

-- | Create @path@ with @contents@ if nothing is there. 'Nothing' means there
-- was already a file; 'Left' means the write failed.
seedFile :: FilePath -> Text -> FileSensitivity -> IO (Either Text (Maybe FilePath))
seedFile path contents sensitivity = do
  outcome <- try go :: IO (Either IOException (Maybe FilePath))
  pure $ case outcome of
    Left err      -> Left (describeWriteError path err)
    Right created -> Right created
  where
    go :: IO (Maybe FilePath)
    go = do
      exists <- doesFileExist path
      if exists
        then pure Nothing
        else do
          -- The parent directory normally exists by now ('Seal.Config.Paths.ensureSealDirs'
          -- runs first at every call site); creating it here keeps the whole
          -- write inside one handler, so a missing directory is a reported
          -- failure rather than an exception.
          createDirectoryIfMissing True (takeDirectory path)
          -- Never rename over the destination: a file created between the
          -- existence check above and this install must survive. Write a
          -- unique temp, then hard-link it into place; EEXIST is a benign lost
          -- race, not a write failure.
          bracketOnError (openUniqueTemp path) cleanup $ \(tmp, h) -> do
            BS.hPutStr h (TE.encodeUtf8 contents)
            hClose h
            case sensitivity of
              SecretFile -> setFileMode tmp 0o600
              PlainFile  -> pure ()
            installed <- try (createLink tmp path) :: IO (Either IOException ())
            ignoreIO (removeFile tmp)
            case installed of
              Right () -> pure (Just path)
              Left err
                | isAlreadyExistsError err -> pure Nothing
                | otherwise               -> ioError err

    cleanup (tmp, h) = do
      ignoreIO (hClose h)
      ignoreIO (removeFile tmp)

    ignoreIO action = void (try action :: IO (Either IOException ()))

describeWriteError :: FilePath -> IOException -> Text
describeWriteError path err =
  "could not write " <> T.pack path <> ": " <> T.pack (displayException err)

describeReadError :: FilePath -> IOException -> Text
describeReadError path err =
  "could not read " <> T.pack path <> ": " <> T.pack (displayException err)
