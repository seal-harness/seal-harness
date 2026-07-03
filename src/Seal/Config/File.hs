{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
-- | Load and save @config\/config.toml@. Absent file decodes as
-- 'defaultFileConfig'. Writes are atomic (write @.tmp@, rename). All vault
-- config fields are optional — a missing TOML key decodes as 'Nothing' and
-- a 'Nothing' value is omitted from the encoded output.
module Seal.Config.File
  ( FileConfig (..)
  , ProviderConfig (..)
  , defaultFileConfig
  , emptyProviderConfig
  , loadFileConfig
  , providerBaseUrl
  , providerDefaultModel
  , saveFileConfig
  , updateFileConfig
  , upsertProvider
  ) where

import Data.HashMap.Strict qualified as HashMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist, renameFile)
import Validation (Validation (..))

import Toml ((.=))
import Toml qualified
import Toml.Type.Key (pattern (:||))

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
  , fcProviders :: Map Text ProviderConfig
    -- ^ Per-provider config sections (@[providers.<label>]@).
  } deriving stock (Eq, Show)

-- | One @[providers.<label>]@ section: per-provider overrides.
data ProviderConfig = ProviderConfig
  { pcDefaultModel :: Maybe Text
  , pcBaseUrl      :: Maybe Text
  } deriving stock (Eq, Show)

emptyProviderConfig :: ProviderConfig
emptyProviderConfig = ProviderConfig Nothing Nothing

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
  , fcProviders       = Map.empty
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
  <*> Toml.tableMap Toml._KeyText (Toml.table providerConfigCodec) "providers" .= fcProviders

-- | Bidirectional tomland codec for one @[providers.<label>]@ section.
providerConfigCodec :: Toml.TomlCodec ProviderConfig
providerConfigCodec = ProviderConfig
  <$> Toml.dioptional (Toml.text "default_model") .= pcDefaultModel
  <*> Toml.dioptional (Toml.text "base_url")      .= pcBaseUrl

-- ---------------------------------------------------------------------------
-- @providers@ table normalization
-- ---------------------------------------------------------------------------

-- | tomland's 'Toml.tableMap' \/ 'Toml.table' combinators look up the
-- @providers@ node by requiring it to carry an explicit value in the parsed
-- AST. A TOML file that declares only @[providers.\<label\>]@ sub-tables
-- (the idiomatic style, and the one every hand-written config uses) never
-- writes a bare @[providers]@ header, so that node is /implicit/ in
-- tomland's prefix tree and the lookup silently returns an empty map
-- instead of the sub-tables' contents.
--
-- This walks the parsed AST once before decoding and makes that node
-- explicit — without disturbing anything else — so both styles decode
-- correctly. Round-tripped files (written by 'saveFileConfig') already have
-- an explicit node and pass through unchanged.
normalizeProvidersTable :: Toml.TOML -> Toml.TOML
normalizeProvidersTable t =
  t { Toml.tomlTables = HashMap.adjust explicitNode "providers" (Toml.tomlTables t) }
  where
    -- 'Toml.tableMap' only ever looks at the 'Just' value of a matching
    -- node, never its 'Toml.Branch' children — so an implicit @providers@
    -- 'Toml.Branch' must be collapsed into a single 'Toml.Leaf' whose value
    -- embeds those children as its own 'Toml.tomlTables', mirroring exactly
    -- what a bare @[providers]@ header would have produced.
    explicitNode :: Toml.PrefixTree Toml.TOML -> Toml.PrefixTree Toml.TOML
    explicitNode tree = case tree of
      Toml.Branch pref Nothing children ->
        Toml.Leaf pref (mempty { Toml.tomlTables = children })
      Toml.Branch _ (Just _) _ -> tree
      Toml.Leaf (_ :|| [])  _  -> tree
      Toml.Leaf (_ :|| (p : ps)) v ->
        Toml.Leaf ("providers" :|| []) (mempty { Toml.tomlTables = Toml.single (p :|| ps) v })

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
      pure $ case Toml.parse contents of
        Left err   -> Left (Toml.unTomlParseError err)
        Right toml -> case Toml.runTomlCodec fileConfigCodec (normalizeProvidersTable toml) of
          Success cfg  -> Right cfg
          Failure errs -> Left (Toml.prettyTomlDecodeErrors errs)

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

-- | The configured default model for provider @lbl@, if any.
providerDefaultModel :: FileConfig -> Text -> Maybe Text
providerDefaultModel cfg lbl = pcDefaultModel =<< Map.lookup lbl (fcProviders cfg)

-- | The configured base URL for provider @lbl@, if any.
providerBaseUrl :: FileConfig -> Text -> Maybe Text
providerBaseUrl cfg lbl = pcBaseUrl =<< Map.lookup lbl (fcProviders cfg)

-- | Insert or update one provider section by applying @f@ to its current
-- config (or to an empty one if absent).
upsertProvider :: Text -> (ProviderConfig -> ProviderConfig) -> FileConfig -> FileConfig
upsertProvider lbl f cfg =
  cfg { fcProviders = Map.insertWith (\_ old -> f old) lbl (f emptyProviderConfig) (fcProviders cfg) }
