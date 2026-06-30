{-# LANGUAGE OverloadedStrings #-}
-- | Load and save @config\/config.toml@. Absent file decodes as
-- 'defaultFileConfig'. Writes are atomic (write @.tmp@, rename). All vault
-- config fields are optional — a missing TOML key decodes as 'Nothing' and
-- a 'Nothing' value is omitted from the encoded output.
module Seal.Config.File
  ( FileConfig (..)
  , defaultFileConfig
  , loadFileConfig
  , saveFileConfig
  , updateFileConfig
  ) where

import Data.Text (Text)
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist, renameFile)

import Toml ((.=))
import Toml qualified

-- | All user-editable vault settings persisted in @config\/config.toml@.
-- Every field is optional; a missing key decodes as 'Nothing'.
data FileConfig = FileConfig
  { fcVaultPath :: Maybe Text
    -- ^ Absolute path to the vault file (default: @~\/.seal\/config\/vault\/vault.age@).
  , fcVaultRecipient :: Maybe Text
    -- ^ age public key: @age1…@ or @age1yubikey1…@.
  , fcVaultIdentity :: Maybe Text
    -- ^ Path to the identity file under @keys\/@, or a user-supplied path.
  , fcVaultUnlock :: Maybe Text
    -- ^ @\"startup\"@ | @\"on_demand\"@ | @\"per_access\"@.
  , fcVaultKeyType :: Maybe Text
    -- ^ Display label: @\"x25519\"@ | @\"yubikey\"@ | @\"user\"@.
  , fcDefaultProvider :: Maybe Text
    -- ^ Provider id used for new sessions (e.g. @\"anthropic\"@).
  , fcDefaultModel :: Maybe Text
    -- ^ Model id used for new sessions (e.g. @\"claude-opus-4-8\"@).
  } deriving stock (Eq, Show)

-- | Starting state: all fields absent, before @\/vault setup@ is run.
defaultFileConfig :: FileConfig
defaultFileConfig = FileConfig
  { fcVaultPath      = Nothing
  , fcVaultRecipient = Nothing
  , fcVaultIdentity  = Nothing
  , fcVaultUnlock    = Nothing
  , fcVaultKeyType   = Nothing
  , fcDefaultProvider = Nothing
  , fcDefaultModel    = Nothing
  }

-- ---------------------------------------------------------------------------
-- Codec
-- ---------------------------------------------------------------------------

-- | Bidirectional tomland codec for 'FileConfig'.
-- 'Toml.dioptional' wraps each key: absent → 'Nothing' on decode,
-- 'Nothing' → key omitted on encode.
fileConfigCodec :: Toml.TomlCodec FileConfig
fileConfigCodec = FileConfig
  <$> Toml.dioptional (Toml.text "vault_path")     .= fcVaultPath
  <*> Toml.dioptional (Toml.text "vault_recipient") .= fcVaultRecipient
  <*> Toml.dioptional (Toml.text "vault_identity")  .= fcVaultIdentity
  <*> Toml.dioptional (Toml.text "vault_unlock")    .= fcVaultUnlock
  <*> Toml.dioptional (Toml.text "vault_key_type")  .= fcVaultKeyType
  <*> Toml.dioptional (Toml.text "default_provider") .= fcDefaultProvider
  <*> Toml.dioptional (Toml.text "default_model")    .= fcDefaultModel

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- | Load the config file at @path@.
--
-- * File absent  → @Right 'defaultFileConfig'@
-- * Parse error  → @Left@ with the rendered tomland diagnostics
loadFileConfig :: FilePath -> IO (Either Text FileConfig)
loadFileConfig path = do
  exists <- doesFileExist path
  if not exists
    then pure (Right defaultFileConfig)
    else do
      contents <- TIO.readFile path
      pure $ case Toml.decode fileConfigCodec contents of
        Right cfg -> Right cfg
        Left errs -> Left (Toml.prettyTomlDecodeErrors errs)

-- | Save @cfg@ to @path@ atomically: write @path.tmp@, rename over @path@.
-- The file is not chmod-restricted (config.toml is not secret material;
-- unlike vault.age which is handled by Phase 1's atomic write with 0600).
saveFileConfig :: FilePath -> FileConfig -> IO ()
saveFileConfig path cfg = do
  let encoded = Toml.encode fileConfigCodec cfg
      tmp     = path <> ".tmp"
  TIO.writeFile tmp encoded
  renameFile tmp path

-- | Load the config at @path@, apply @f@, save. Propagates any load
-- error as @Left Text@ without writing.
updateFileConfig :: FilePath -> (FileConfig -> FileConfig) -> IO (Either Text ())
updateFileConfig path f = do
  result <- loadFileConfig path
  case result of
    Left err  -> pure (Left err)
    Right cfg -> saveFileConfig path (f cfg) >> pure (Right ())
