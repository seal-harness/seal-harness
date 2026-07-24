{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
-- | Load and save @config\/config.toml@ — the agent/operator-tunable runtime
-- configuration ('RuntimeConfig'). Absent file decodes as
-- 'defaultRuntimeConfig'. Writes are atomic (write @.tmp@, rename).
--
-- The security-critical, boot-only fields (vault settings + @untrusted_execution@)
-- have moved to 'Seal.Config.Security.SecurityConfig' (loaded from
-- @~\/.seal\/security.toml@). This split means a future @CONFIG_UPDATE@ opcode
-- (which operates on 'RuntimeConfig') and the HTTP Gateway's
-- @updateRuntimeConfig@ caller physically cannot express a change to the
-- security-critical fields — it is a compile error (design §4 Approach E).
module Seal.Config.File
  ( RuntimeConfig (..)
  , ProviderConfig (..)
  , RetrievalConfig (..)
  , DelegationFileConfig (..)
  , WebConfig (..)
  , WorkdirConfig (..)
  , defaultRuntimeConfig
  , defaultRetrievalConfig
  , defaultRetrievalMaxScanBytes
  , defaultDelegationConfig
  , defaultWebConfig
  , emptyProviderConfig
  , loadRuntimeConfig
  , providerBaseUrl
  , providerDefaultModel
  , retrievalMaxScanBytes
  , onDemandSchemas
  , saveRuntimeConfig
  , updateRuntimeConfig
  , upsertProvider
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Data.HashMap.Strict qualified as HashMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist, renameFile)
import System.IO.Unsafe (unsafePerformIO)
import Validation (Validation (..))

import Toml ((.=))
import Toml qualified
import Toml.Type.Key (pattern (:||))

import Seal.Signal.Config (SignalConfig (..), signalConfigCodec)
import Seal.Telegram.Config (TelegramConfig (..), telegramConfigCodec)
import Seal.Gateway.Config (PartialGatewayConfig (..), gatewayConfigCodec)

-- | The agent/operator-tunable runtime configuration persisted in
-- @config\/config.toml@. Every field is optional; a missing key decodes as
-- 'Nothing'. Security-critical boot-only fields (vault, untrusted_execution)
-- live in 'Seal.Config.Security.SecurityConfig' (loaded from
-- @security.toml@) and are NOT present here.
data RuntimeConfig = RuntimeConfig
  { rcDefaultProvider :: Maybe Text
    -- ^ Provider id used for new sessions (e.g. @\"anthropic\"@).
  , rcDefaultModel :: Maybe Text
    -- ^ Model id used for new sessions (e.g. @\"claude-opus-4-8\"@).
  , rcDefaultAgent :: Maybe Text
    -- ^ Agent def id used by default for agent-driven flows (set via
    -- @\/agent default@). 'Nothing' means no default agent is selected.
  , rcProviders :: Map Text ProviderConfig
    -- ^ Per-provider config sections (@[providers.<label>]@).
  , rcRetrieval :: Maybe RetrievalConfig
    -- ^ Optional @[retrieval]@ section (Dynamic Retrieval tuning). Absent
    -- means 'defaultRetrievalConfig' applies at resolution time.
  , rcSignal :: Maybe SignalConfig
    -- ^ Optional @[signal]@ section (Signal channel config). Absent means
    -- the Signal channel is not configured.
  , rcTelegram :: Maybe TelegramConfig
    -- ^ Optional @[telegram]@ section (Telegram channel config). Absent
    -- means the Telegram channel is not configured.
  , rcGateway :: Maybe PartialGatewayConfig
    -- ^ Optional @[gateway]@ section (web gateway config). Absent means the
    -- gateway is not configured. Each field inside is optional too; the
    -- call site merges with 'Seal.Gateway.Config.withGatewayDefaults'.
  , rcDebugSessionTranscript :: Maybe Bool
    -- ^ Optional @debug_session_transcript@ flag. When @true@, every
    -- 'CompletionRequest' sent to the LLM is also appended (redundantly,
    -- in full) to a @requests.jsonl@ file alongside the session's
    -- @conversation.jsonl@ / @entries.jsonl@. The contract: each line is
    -- the complete JSON-encoded 'CompletionRequest' exactly as passed to
    -- the provider, including the full @crMessages@ history. Used to
    -- debug whether the two-file storage format is correctly feeding the
    -- session history to the LLM. Absent (the default) means the file is
    -- not written.
  , rcOnDemandSchemas :: Maybe Bool
    -- ^ Optional @on_demand_schemas@ flag. When @true@, the full
    -- @input_schema@ JSON for every opcode is replaced with a minimal
    -- stub (@{\"type\":\"object\"}@) in the @tools@ field of each
    -- 'CompletionRequest' (saving tokens on every turn), and a
    -- read-only @OPCODE_DESCRIBE@ / @OPCODE_LIST@ pair is registered so
    -- the model can retrieve an opcode's full input/output schema
    -- on-demand before calling it. Absent (the default) preserves the
    -- existing behavior: full schemas are sent inline and the describe
    -- opcodes are not registered.
  , rcDelegation :: Maybe DelegationFileConfig
    -- ^ Optional @[delegation]@ section (subagent spawning tunables).
    -- Absent means 'defaultDelegationConfig' applies at resolution time.
  , rcWeb :: Maybe WebConfig
    -- ^ Optional @[web]@ section (web tool config: search endpoint +
    -- fetch/search allow-lists + max fetch bytes). Absent means the web
    -- tools are fail-closed (no endpoint configured).
  , rcWorkdir :: Maybe WorkdirConfig
    -- ^ Optional @[workdir]@ section (per-session workdir lifecycle).
    -- Absent means defaults apply (persist, no chroot — chroot is
    -- deferred). Per-session workdirs are always on regardless of this
    -- section; this config only controls cleanup-on-exit.
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

-- | The @[delegation]@ section (subagent spawning tunables). Every field is
-- optional; a missing key decodes as 'Nothing' and the resolver falls back to
-- the compiled-in default. Mirrors Hermes' @delegation.*@ config knobs.
data DelegationFileConfig = DelegationFileConfig
  { dfcMaxConcurrentChildren :: Maybe Int
    -- ^ Cap on parallel children per AGENT_START batch. Default 3, floor 1.
  , dfcChildTimeoutSeconds  :: Maybe Double
    -- ^ Hard per-child timeout in seconds. Default 600, floor 30.
  , dfcMaxSpawnDepth         :: Maybe Int
    -- ^ Max delegation tree depth. Default 1 (flat), clamped to [1,3].
  , dfcOrchestratorEnabled   :: Maybe Bool
    -- ^ Kill switch for the orchestrator role. Default True.
  , dfcProvider              :: Maybe Text
    -- ^ Per-child provider override (route subagents to a different provider).
  , dfcModel                 :: Maybe Text
    -- ^ Per-child model override.
  , dfcBaseUrl               :: Maybe Text
    -- ^ Per-child base URL override (OpenAI-compatible direct endpoint).
  , dfcApiKey                :: Maybe Text
    -- ^ Per-child API key override (used when @dfcBaseUrl@ is set).
  , dfcApiMode               :: Maybe Text
    -- ^ Per-child API mode override (@chat_completions@ /
    -- @anthropic_messages@).
  , dfcSubagentAutoApprove   :: Maybe Bool
    -- ^ Whether subagent dangerous-command approvals auto-approve. Default
    -- False (auto-deny). Not yet wired; reserved for future use.
  } deriving stock (Eq, Show)

emptyProviderConfig :: ProviderConfig
emptyProviderConfig = ProviderConfig Nothing Nothing

-- | The @[web]@ section: web tool configuration. Every field is optional;
-- a missing key decodes as 'Nothing' and the resolved default applies at
-- the call site.
data WebConfig = WebConfig
  { wcSearchEndpoint  :: Maybe Text
    -- ^ The search API endpoint URL (e.g.
    -- @https://api.tavily.com/search@). Absent → WEB_SEARCH is
    -- fail-closed (returns \"no search endpoint configured\").
  , wcSearchAllowList :: Maybe [Text]
    -- ^ Allowed domains for WEB_SEARCH results (empty = all allowed).
    -- Currently advisory (the search endpoint is operator-trusted); future
    -- filtering of result URLs would use this.
  , wcFetchAllowList  :: Maybe [Text]
    -- ^ Allowed domains for WEB_FETCH (empty = all allowed, subject to
    -- SSRF protection). Absent → all domains allowed.
  , wcMaxFetchBytes   :: Maybe Int
    -- ^ Operator-configured byte ceiling for WEB_FETCH. Absent →
    -- 'defaultRetrievalMaxScanBytes' (128 KiB).
  } deriving stock (Eq, Show)

-- | Starting state: all fields absent, before @\/vault setup@ is run.
defaultRuntimeConfig :: RuntimeConfig
defaultRuntimeConfig = RuntimeConfig
  { rcDefaultProvider = Nothing
  , rcDefaultModel    = Nothing
  , rcDefaultAgent    = Nothing
  , rcProviders       = Map.empty
  , rcRetrieval       = Nothing
  , rcSignal          = Nothing
  , rcTelegram        = Nothing
  , rcGateway         = Nothing
  , rcDebugSessionTranscript = Nothing
  , rcOnDemandSchemas = Nothing
  , rcDelegation      = Nothing
  , rcWeb             = Nothing
  , rcWorkdir          = Nothing
  }

-- | 'WebConfig' with all fields absent (operator did not set them).
defaultWebConfig :: WebConfig
defaultWebConfig = WebConfig
  { wcSearchEndpoint  = Nothing
  , wcSearchAllowList = Nothing
  , wcFetchAllowList  = Nothing
  , wcMaxFetchBytes   = Nothing
  }

-- | The @[workdir]@ section: per-session workdir lifecycle. Every field
-- is optional; a missing key decodes as 'Nothing' and the default applies.
data WorkdirConfig = WorkdirConfig
  { wdcCleanupOnExit :: Maybe Bool
    -- ^ Remove the workdir when the session ends. Absent = false
    -- (persist for inspection).
  } deriving stock (Eq, Show)

-- | 'RetrievalConfig' with all fields absent (operator did not set them).
defaultRetrievalConfig :: RetrievalConfig
defaultRetrievalConfig = RetrievalConfig { rcMaxScanBytes = Nothing }

-- | 'DelegationFileConfig' with all fields absent (operator did not set them).
-- The resolver ('Seal.Agent.Runtime.Delegation.resolveDelegationConfig')
-- fills in the compiled-in defaults.
defaultDelegationConfig :: DelegationFileConfig
defaultDelegationConfig = DelegationFileConfig
  { dfcMaxConcurrentChildren = Nothing
  , dfcChildTimeoutSeconds   = Nothing
  , dfcMaxSpawnDepth          = Nothing
  , dfcOrchestratorEnabled    = Nothing
  , dfcProvider               = Nothing
  , dfcModel                  = Nothing
  , dfcBaseUrl                 = Nothing
  , dfcApiKey                  = Nothing
  , dfcApiMode                 = Nothing
  , dfcSubagentAutoApprove    = Nothing
  }

-- | The compiled-in default for the operator ceiling on bytes scanned per
-- retrieval (≥ the prior 'FILE_READ' 65536 bound). Used when the
-- @[retrieval]@ section is absent or its @max_scan_bytes@ key is missing.
defaultRetrievalMaxScanBytes :: Int
defaultRetrievalMaxScanBytes = 131072   -- 128 KiB

-- ---------------------------------------------------------------------------
-- Codec
-- ---------------------------------------------------------------------------

-- | Bidirectional tomland codec for 'RuntimeConfig'.
-- 'Toml.dioptional' wraps each key: absent → 'Nothing' on decode,
-- 'Nothing' → key omitted on encode.
runtimeConfigCodec :: Toml.TomlCodec RuntimeConfig
runtimeConfigCodec = RuntimeConfig
  <$> Toml.dioptional (Toml.text "default_provider") .= rcDefaultProvider
  <*> Toml.dioptional (Toml.text "default_model")    .= rcDefaultModel
  <*> Toml.dioptional (Toml.text "default_agent")    .= rcDefaultAgent
  <*> Toml.tableMap Toml._KeyText (Toml.table providerConfigCodec) "providers" .= rcProviders
  <*> Toml.dioptional (Toml.table retrievalConfigCodec "retrieval") .= rcRetrieval
  <*> Toml.dioptional (Toml.table signalConfigCodec "signal")       .= rcSignal
  <*> Toml.dioptional (Toml.table telegramConfigCodec "telegram")   .= rcTelegram
  <*> Toml.dioptional (Toml.table gatewayConfigCodec "gateway")    .= rcGateway
  <*> Toml.dioptional (Toml.bool "debug_session_transcript") .= rcDebugSessionTranscript
  <*> Toml.dioptional (Toml.bool "on_demand_schemas") .= rcOnDemandSchemas
  <*> Toml.dioptional (Toml.table delegationConfigCodec "delegation") .= rcDelegation
  <*> Toml.dioptional (Toml.table webConfigCodec "web") .= rcWeb
  <*> Toml.dioptional (Toml.table workdirConfigCodec "workdir") .= rcWorkdir

-- | Bidirectional tomland codec for one @[providers.<label>]@ section.
providerConfigCodec :: Toml.TomlCodec ProviderConfig
providerConfigCodec = ProviderConfig
  <$> Toml.dioptional (Toml.text "default_model") .= pcDefaultModel
  <*> Toml.dioptional (Toml.text "base_url")      .= pcBaseUrl

-- | Bidirectional tomland codec for the @[retrieval]@ section.
retrievalConfigCodec :: Toml.TomlCodec RetrievalConfig
retrievalConfigCodec = RetrievalConfig
  <$> Toml.dioptional (Toml.int "max_scan_bytes") .= rcMaxScanBytes

-- | Bidirectional tomland codec for the @[delegation]@ section. Every field
-- is optional at the TOML layer. 'dfcChildTimeoutSeconds' uses 'Toml.double'
-- so fractional seconds (e.g. @30.5@) round-trip cleanly.
delegationConfigCodec :: Toml.TomlCodec DelegationFileConfig
delegationConfigCodec = DelegationFileConfig
  <$> Toml.dioptional (Toml.int    "max_concurrent_children") .= dfcMaxConcurrentChildren
  <*> Toml.dioptional (Toml.double "child_timeout_seconds")    .= dfcChildTimeoutSeconds
  <*> Toml.dioptional (Toml.int    "max_spawn_depth")          .= dfcMaxSpawnDepth
  <*> Toml.dioptional (Toml.bool   "orchestrator_enabled")    .= dfcOrchestratorEnabled
  <*> Toml.dioptional (Toml.text   "provider")                .= dfcProvider
  <*> Toml.dioptional (Toml.text   "model")                   .= dfcModel
  <*> Toml.dioptional (Toml.text   "base_url")                 .= dfcBaseUrl
  <*> Toml.dioptional (Toml.text   "api_key")                  .= dfcApiKey
  <*> Toml.dioptional (Toml.text   "api_mode")                 .= dfcApiMode
  <*> Toml.dioptional (Toml.bool   "subagent_auto_approve")    .= dfcSubagentAutoApprove

-- | Bidirectional tomland codec for the @[web]@ section. Every field is
-- optional. The allow-lists use an array-of-strings TOML key.
webConfigCodec :: Toml.TomlCodec WebConfig
webConfigCodec = WebConfig
  <$> Toml.dioptional (Toml.text  "search_endpoint")   .= wcSearchEndpoint
  <*> Toml.dioptional (arrayOfText "search_allow_list") .= wcSearchAllowList
  <*> Toml.dioptional (arrayOfText "fetch_allow_list")  .= wcFetchAllowList
  <*> Toml.dioptional (Toml.int    "max_fetch_bytes")   .= wcMaxFetchBytes

-- | TOML codec for an array-of-text. tomland doesn't export a direct
-- @[_Text]@ codec, so we use 'Toml.arrayOf' with 'Toml._Text'.
arrayOfText :: Toml.Key -> Toml.TomlCodec [Text]
arrayOfText = Toml.arrayOf Toml._Text

-- | Bidirectional tomland codec for the @[workdir]@ section.
workdirConfigCodec :: Toml.TomlCodec WorkdirConfig
workdirConfigCodec = WorkdirConfig
  <$> Toml.dioptional (Toml.bool "cleanup_on_exit") .= wdcCleanupOnExit

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
-- correctly. Round-tripped files (written by 'saveRuntimeConfig') already have
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
-- * File absent  → @Right 'defaultRuntimeConfig'@
-- * Parse error  → @Left@ with the rendered tomland diagnostics
loadRuntimeConfig :: FilePath -> IO (Either Text RuntimeConfig)
loadRuntimeConfig path = do
  exists <- doesFileExist path
  if not exists
    then pure (Right defaultRuntimeConfig)
    else do
      contents <- TIO.readFile path
      pure $ case Toml.parse contents of
        Left err   -> Left (Toml.unTomlParseError err)
        Right toml -> case Toml.runTomlCodec runtimeConfigCodec (normalizeProvidersTable toml) of
          Success cfg  -> Right cfg
          Failure errs -> Left (Toml.prettyTomlDecodeErrors errs)

-- | Save @cfg@ to @path@ atomically: write @path.tmp@, rename over @path@.
-- The file is not chmod-restricted (config.toml is not secret material;
-- unlike vault.age / security.toml which are handled with 0600).
saveRuntimeConfig :: FilePath -> RuntimeConfig -> IO ()
saveRuntimeConfig path cfg = do
  let encoded = Toml.encode runtimeConfigCodec cfg
      tmp     = path <> ".tmp"
  TIO.writeFile tmp encoded
  renameFile tmp path

-- | Process-wide lock serializing config writes to prevent lost-update
-- races (design V7). Multiple concurrent 'updateRuntimeConfig' callers
-- (e.g. Gateway PUT + a future CONFIG_UPDATE, or two sessions) can silently
-- clobber each other without this lock. The MVar is initialized once via
-- 'unsafePerformIO' — idiomatic for a process-wide lock (mirrors
-- 'Seal.Security.Vault.stWriteLock').
{-# NOINLINE configWriteLock #-}
configWriteLock :: MVar ()
configWriteLock = unsafePerformIO (newMVar ())

-- | Load the config at @path@, apply @f@, save. Propagates any load
-- error as @Left Text@ without writing. The update function operates on
-- 'RuntimeConfig' only — it physically cannot touch security-critical
-- fields (vault, untrusted_execution) because they live in
-- 'Seal.Config.Security.SecurityConfig', a different type (design §4 E).
-- The load-modify-save is serialized behind 'configWriteLock' to prevent
-- lost-update races (design V7).
updateRuntimeConfig :: FilePath -> (RuntimeConfig -> RuntimeConfig) -> IO (Either Text ())
updateRuntimeConfig path f = withMVar configWriteLock $ \_ -> do
  result <- loadRuntimeConfig path
  case result of
    Left err  -> pure (Left err)
    Right cfg -> saveRuntimeConfig path (f cfg) >> pure (Right ())

-- | The configured default model for provider @lbl@, if any.
providerDefaultModel :: RuntimeConfig -> Text -> Maybe Text
providerDefaultModel cfg lbl = pcDefaultModel =<< Map.lookup lbl (rcProviders cfg)

-- | The configured base URL for provider @lbl@, if any.
providerBaseUrl :: RuntimeConfig -> Text -> Maybe Text
providerBaseUrl cfg lbl = pcBaseUrl =<< Map.lookup lbl (rcProviders cfg)

-- | The resolved operator ceiling on bytes scanned per retrieval. Falls back
-- to 'defaultRetrievalMaxScanBytes' (128 KiB) when the @[retrieval]@ section
-- or its @max_scan_bytes@ key is absent. This is the hard upper bound the
-- model's per-call @max_scan_bytes@ request is clamped down to.
retrievalMaxScanBytes :: RuntimeConfig -> Int
retrievalMaxScanBytes cfg =
  fromMaybe defaultRetrievalMaxScanBytes (rcRetrieval cfg >>= rcMaxScanBytes)

-- | The resolved on-demand-schemas flag. 'True' means the registry should
-- emit stub @input_schema@s and register the @OPCODE_DESCRIBE@ /
-- @OPCODE_LIST@ opcodes so the model can fetch full schemas on demand.
-- Absent (the default) is 'False' — full schemas are sent inline, matching
-- the pre-flag behavior.
onDemandSchemas :: RuntimeConfig -> Bool
onDemandSchemas cfg = fromMaybe False (rcOnDemandSchemas cfg)

-- | Insert or update one provider section by applying @f@ to its current
-- config (or to an empty one if absent).
upsertProvider :: Text -> (ProviderConfig -> ProviderConfig) -> RuntimeConfig -> RuntimeConfig
upsertProvider lbl f cfg =
  cfg { rcProviders = Map.insertWith (\_ old -> f old) lbl (f emptyProviderConfig) (rcProviders cfg) }
