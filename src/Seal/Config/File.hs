{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
-- | Load and save @config\/config.toml@. Absent file decodes as
-- 'defaultFileConfig'. Writes are atomic (write @.tmp@, rename). All vault
-- config fields are optional — a missing TOML key decodes as 'Nothing' and
-- a 'Nothing' value is omitted from the encoded output.
module Seal.Config.File
  ( FileConfig (..)
  , ProviderConfig (..)
  , RetrievalConfig (..)
  , defaultFileConfig
  , defaultRetrievalConfig
  , defaultRetrievalMaxScanBytes
  , emptyProviderConfig
  , loadFileConfig
  , providerBaseUrl
  , providerDefaultModel
  , retrievalMaxScanBytes
  , saveFileConfig
  , updateFileConfig
  , upsertProvider
  ) where

import Data.HashMap.Strict qualified as HashMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist, renameFile)
import Validation (Validation (..))

import Toml ((.=))
import Toml qualified
import Toml.Type.Key (pattern (:||))

import Seal.Signal.Config (SignalConfig (..), signalConfigCodec)

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
  , fcDefaultAgent :: Maybe Text
    -- ^ Agent def id used by default for agent-driven flows (set via
    -- @\/agent default@). 'Nothing' means no default agent is selected.
  , fcProviders :: Map Text ProviderConfig
    -- ^ Per-provider config sections (@[providers.<label>]@).
  , fcRetrieval :: Maybe RetrievalConfig
    -- ^ Optional @[retrieval]@ section (Dynamic Retrieval tuning). Absent
    -- means 'defaultRetrievalConfig' applies at resolution time.
  , fcSignal :: Maybe SignalConfig
    -- ^ Optional @[signal]@ section (Signal channel config). Absent means
    -- the Signal channel is not configured.
  } deriving stock (Eq, Show)

-- | One @[providers.<label>]@ section: per-provider overrides.
data ProviderConfig = ProviderConfig
  { pcDefaultModel :: Maybe Text
  , pcBaseUrl      :: Maybe Text
  } deriving stock (Eq, Show)

-- | The @[retrieval]@ section: Dynamic Retrieval tuning. Every field is
-- optional; a missing key decodes as 'Nothing' and the resolved default
-- applies at the call site.
newtype RetrievalConfig = RetrievalConfig
  { rcMaxScanBytes :: Maybe Int
    -- ^ Operator-configured upper bound on bytes scanned per 'FILE_READ'
    -- (and future retrieval opcodes). Absent → 'defaultRetrievalMaxScanBytes'.
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
  , fcDefaultAgent    = Nothing
  , fcProviders       = Map.empty
  , fcRetrieval       = Nothing
  , fcSignal          = Nothing
  }

-- | 'RetrievalConfig' with all fields absent (operator did not set them).
defaultRetrievalConfig :: RetrievalConfig
defaultRetrievalConfig = RetrievalConfig { rcMaxScanBytes = Nothing }

-- | The compiled-in default for the operator ceiling on bytes scanned per
-- retrieval (≥ the prior 'FILE_READ' 65536 bound). Used when the
-- @[retrieval]@ section is absent or its @max_scan_bytes@ key is missing.
defaultRetrievalMaxScanBytes :: Int
defaultRetrievalMaxScanBytes = 131072   -- 128 KiB

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
  <*> Toml.dioptional (Toml.text "default_agent")    .= fcDefaultAgent
  <*> Toml.tableMap Toml._KeyText (Toml.table providerConfigCodec) "providers" .= fcProviders
  <*> Toml.dioptional (Toml.table retrievalConfigCodec "retrieval") .= fcRetrieval
  <*> Toml.dioptional (Toml.table signalConfigCodec "signal")       .= fcSignal

-- | Bidirectional tomland codec for one @[providers.<label>]@ section.
providerConfigCodec :: Toml.TomlCodec ProviderConfig
providerConfigCodec = ProviderConfig
  <$> Toml.dioptional (Toml.text "default_model") .= pcDefaultModel
  <*> Toml.dioptional (Toml.text "base_url")      .= pcBaseUrl

-- | Bidirectional tomland codec for the @[retrieval]@ section.
retrievalConfigCodec :: Toml.TomlCodec RetrievalConfig
retrievalConfigCodec = RetrievalConfig
  <$> Toml.dioptional (Toml.int "max_scan_bytes") .= rcMaxScanBytes

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

-- | The resolved operator ceiling on bytes scanned per retrieval. Falls back
-- to 'defaultRetrievalMaxScanBytes' (128 KiB) when the @[retrieval]@ section
-- or its @max_scan_bytes@ key is absent. This is the hard upper bound the
-- model's per-call @max_scan_bytes@ request is clamped down to.
retrievalMaxScanBytes :: FileConfig -> Int
retrievalMaxScanBytes cfg =
  fromMaybe defaultRetrievalMaxScanBytes (fcRetrieval cfg >>= rcMaxScanBytes)

-- | Insert or update one provider section by applying @f@ to its current
-- config (or to an empty one if absent).
upsertProvider :: Text -> (ProviderConfig -> ProviderConfig) -> FileConfig -> FileConfig
upsertProvider lbl f cfg =
  cfg { fcProviders = Map.insertWith (\_ old -> f old) lbl (f emptyProviderConfig) (fcProviders cfg) }
