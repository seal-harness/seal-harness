{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The code-level provider registry: the set of providers Seal knows how to
-- build, and the mapping from each to its display label, vault credential key,
-- default model and base URL. Credential resolution (reading the key from the
-- vault and constructing a live 'SomeProvider') is added on top of this
-- vocabulary.
--
-- OpenAI-compatible vendors are **data**: 'openAICompatSpecs' is the catalog,
-- and every family provider is an 'OpenAICompatProvider' row. Adding a vendor
-- with a known endpoint is one appended row — no change to the transport, the
-- CLI, the gateway or the frontend.
module Seal.Providers.Registry
  ( KnownProvider (..)
  , ProviderType (..)
  , providerTypes
  , typeId
  , providerTypeForId
  , legacyTypeIds
  , ProviderInstance (..)
  , providerInstances
  , toProviderType
  , OpenAICompatSpec (..)
  , knownProviders
  , openAICompatSpecs
  , genericOpenAICompat
  , catalogProblems
  , parseProviderIn
  , configuredProviders
  , configuredProvidersFor
  , providerLabel
  , providerDisplayName
  , providerAuthStatus
  , anthropicOAuthKey
  , providerId
  , parseProvider
  , legacyProviderHint
  , knownLabelList
  , vaultKeyName
  , defaultModelFor
  , resolveDefaultModel
  , resolveProvider
  , providerBaseUrlFor
  , missingBaseUrlMsgFor
  , legacyOpenRouterBaseUrl
  , legacyOpenRouterModel
  , completeSome
  , listSome
  , vaultErrText
  ) where

import Control.Applicative ((<|>))
import Control.Monad (void, filterM)
import Data.IORef (IORef, newIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Network.HTTP.Client (Manager)

import Seal.Config.File
  ( ProviderConfig (..), RuntimeConfig (..), emptyProviderConfig
  , providerBaseUrl )
import Seal.Core.Types (ModelId (..), ProviderId (..))
import Seal.Providers.Anthropic
  ( OAuthSession (..), ensureFresh, mkAnthropic, mkAnthropicOAuth )
import Seal.Providers.Anthropic.OAuth
  ( deserializeTokens, refreshTokens, serializeTokens )
import Seal.Providers.Class
  ( CompletionRequest, CompletionResponse, Provider (..), SomeProvider (..) )
import Seal.Providers.Ollama (defaultOllamaBaseUrl, mkOllama, ollamaNeedsKey)
import Seal.Providers.Name (ProviderName, mkProviderName)
import Seal.Providers.OpenAICompat
  ( OpenAICompatSpec (..), mkOpenAICompat, validateBaseUrl )
import Seal.Security.Secrets (ApiKey, mkApiKey)
import Seal.Security.Vault (VaultHandle (..))
import Seal.Security.Vault.Age (VaultError (..))

-- | The Anthropic OAuth token vault key (mirrors
-- 'Seal.Command.Provider.anthropicOAuthKey'; duplicated here to avoid a
-- circular import).
anthropicOAuthKey :: Text
anthropicOAuthKey = "ANTHROPIC_OAUTH_TOKENS"

-- | The Anthropic API endpoint. Fixed inside the provider; surfaced here only
-- so the editor can show what it talks to.
anthropicBaseUrl :: Text
anthropicBaseUrl = "https://api.anthropic.com"

-- | The generic OpenAI-compatible row: the user supplies both the base URL and
-- the model, and no API key is required (local servers usually have none).
-- Further compatible vendors are appended to 'openAICompatSpecs'.
genericOpenAICompat :: OpenAICompatSpec
genericOpenAICompat = OpenAICompatSpec
  { ocsId             = "openai-compat"
  , ocsDisplayName    = "OpenAI-compatible"
  , ocsVaultKey       = "OPENAI_COMPAT_API_KEY"
  , ocsBuiltinBaseUrl = Nothing
  , ocsDefaultModel   = Nothing
  , ocsKeyRequired    = False
  , ocsModels         = []
  , ocsExtraHeaders   = []
  }

-- | The endpoint and model Seal used to hardcode for OpenRouter. Kept here (not
-- duplicated as literals) for the boot-time config migration; step 3's preset
-- row reuses both.
legacyOpenRouterBaseUrl :: Text
legacyOpenRouterBaseUrl = "https://openrouter.ai/api/v1"

legacyOpenRouterModel :: Text
legacyOpenRouterModel = "deepseek/deepseek-v4.1-flash-1017"

-- | The OpenAI-compatible provider catalog. Append a row to ship a preset; the
-- row supplies the endpoint, key policy, model catalogue and static headers,
-- and the shared transport does the rest.
openAICompatSpecs :: [OpenAICompatSpec]
openAICompatSpecs = [genericOpenAICompat]

-- | Every provider Seal can build.
data KnownProvider
  = AnthropicProvider
  | OllamaProvider
  | OpenAICompatProvider !OpenAICompatSpec
  deriving stock (Eq, Show)

knownProviders :: [KnownProvider]
knownProviders = [AnthropicProvider, OllamaProvider]
              <> map OpenAICompatProvider openAICompatSpecs

-- | A provider *type*: the transport, credential policy and built-in defaults
-- of one kind of API. A closed set, extended by the catalog — a *type* is code,
-- an *instance* (below) is user data.
data ProviderType
  = AnthropicType
  | OllamaType
  | OpenAICompatType !OpenAICompatSpec
  deriving stock (Eq, Show)

providerTypes :: [ProviderType]
providerTypes = [AnthropicType, OllamaType] <> map OpenAICompatType openAICompatSpecs

-- | The id used for a type: its config-name stem and the default instance name.
typeId :: ProviderType -> Text
typeId AnthropicType           = "anthropic"
typeId OllamaType              = "ollama"
typeId (OpenAICompatType spec) = ocsId spec

-- | The ids that existed before named instances. A section with no @type@ whose
-- name is one of these resolves to that type (so every pre-#273 config keeps
-- working with no rewrite); a type-less section named anything else is a
-- problem row rather than a silent guess.
legacyTypeIds :: [Text]
legacyTypeIds = ["anthropic", "ollama", "openai-compat"]

-- | Look a type up by id (trimmed, case-folded).
providerTypeForId :: Text -> Maybe ProviderType
providerTypeForId raw =
  lookup (T.toCaseFold (T.strip raw))
         [(T.toCaseFold (typeId t), t) | t <- providerTypes]

-- | A provider instance: a user-named use of a type. Persisted as
-- @[providers.\<name\>]@ in @config.toml@ (with @type@), and the identity that
-- sessions, agent defs, the CLI and the API use.
data ProviderInstance = ProviderInstance
  { piName       :: !Text
    -- ^ The config table key / instance id (raw; see 'piNameValid').
  , piNameValid  :: !(Maybe ProviderName)
    -- ^ 'Nothing' for a hand-edited invalid or reserved name. Such a row is
    -- surfaced with a problem and never touches the vault.
  , piTypeId     :: !(Maybe Text)
    -- ^ The raw @type@ value, for display (resolution uses 'piType').
  , piType       :: !(Maybe ProviderType)
    -- ^ 'Nothing' ⇒ unresolvable (unknown or missing type); see 'piProblem'.
  , piConfig     :: !ProviderConfig
    -- ^ That instance's own @base_url@ / @default_model@.
  , piProblem    :: !(Maybe Text)
    -- ^ Human-readable reason the row is unusable; surfaced, never fatal.
  , piHasSection :: !Bool
    -- ^ An explicit @[providers.\<name\>]@ section exists.
  } deriving stock (Eq, Show)

-- | Every provider instance: one row per type (implicit, unconfigured, unless a
-- section claims that name) followed by the remaining sections by name. Never
-- empty, so the UI and the CLI always have something to show and the
-- pre-instances defaults (@\"anthropic\"@, @\"ollama\"@) keep resolving.
providerInstances :: RuntimeConfig -> [ProviderInstance]
providerInstances cfg = typeRows <> extraRows
  where
    provs = rcProviders cfg
    typeRows = map rowForType providerTypes
    claimedTypeIds = Set.fromList (map typeId providerTypes)
    extraRows =
      [ rowFromSection n sec
      | (n, sec) <- Map.toAscList provs
      , not (Set.member n claimedTypeIds)
      ]
    rowForType t =
      let n = typeId t
      in case Map.lookup n provs of
           Just sec -> rowFromSection n sec
           Nothing  -> ProviderInstance
             { piName       = n
             , piNameValid  = either (const Nothing) Just (mkProviderName n)
             , piTypeId     = Nothing
             , piType       = Just t
             , piConfig     = emptyProviderConfig
             , piProblem    = Nothing
             , piHasSection = False
             }

    rowFromSection n sec =
      let mRawType =
            pcType sec >>= \v -> if T.null (T.strip v) then Nothing else Just (T.strip v)
          (mType, typeProblem) = case mRawType of
            Just raw -> case providerTypeForId raw of
              Just t  -> (Just t, Nothing)
              Nothing -> (Nothing, Just ("unknown provider type: " <> raw))
            Nothing
              | n `elem` legacyTypeIds -> (providerTypeForId n, Nothing)
              | otherwise ->
                  (Nothing, Just "has no type and its name is not a provider type")
          nameProblem = case mkProviderName n of
            Left "reserved" ->
              Just ("section name \"" <> n <> "\" is reserved — rename the section")
            Left _ ->
              Just ("section name \"" <> n <> "\" is not a valid instance name"
                      <> " (1–32 characters of a–z, 0–9 and “-”)")
            Right _ -> Nothing
          mismatchProblem = case (mType, providerTypeForId n) of
            (Just t, Just nameType)
              | typeId t /= typeId nameType ->
                  Just ("section named \"" <> n <> "\" is not a "
                          <> typeId t <> " instance")
            _ -> Nothing
      in ProviderInstance
           { piName       = n
           , piNameValid  = either (const Nothing) Just (mkProviderName n)
           , piTypeId     = mRawType
           , piType       = mType
           , piConfig     = sec
           , piProblem    = nameProblem <|> typeProblem <|> mismatchProblem
           , piHasSection = True
           }

-- | Project an instance's type into the legacy view (the strangler bridge for
-- code that still speaks 'KnownProvider').
toProviderType :: KnownProvider -> ProviderType
toProviderType AnthropicProvider           = AnthropicType
toProviderType OllamaProvider              = OllamaType
toProviderType (OpenAICompatProvider spec) = OpenAICompatType spec

-- | Static problems with a catalog (blank or duplicate ids, blank labels/keys,
-- unusable built-in URLs). Exported so the invariant is testable and so a
-- future row cannot silently shadow another ('parseProviderIn' takes the first
-- match).
catalogProblems :: [OpenAICompatSpec] -> [Text]
catalogProblems specs =
  concatMap check specs
    <> [ "duplicate id: " <> i
       | i <- duplicates (map ocsId specs)
       ]
  where
    check s = concat
      [ [ "blank id" | T.null (T.strip (ocsId s)) ]
      , [ "blank display name for " <> ocsId s | T.null (T.strip (ocsDisplayName s)) ]
      , [ "blank vault key for " <> ocsId s | T.null (T.strip (ocsVaultKey s)) ]
      , [ ocsId s <> " built-in base URL is not usable: " <> reason
        | Just u <- [ocsBuiltinBaseUrl s]
        , Left reason <- [validateBaseUrl u]
        ]
      ]
    duplicates = go [] []
      where
        go _ dups [] = dups
        go seen dups (x:xs)
          | x `elem` seen = go seen (x : dups) xs
          | otherwise     = go (x : seen) dups xs

-- | The user-facing id typed at the @/provider@ prompt (and the TOML table key).
providerLabel :: KnownProvider -> Text
providerLabel AnthropicProvider              = "anthropic"
providerLabel OllamaProvider                 = "ollama"
providerLabel (OpenAICompatProvider spec)    = ocsId spec

-- | Human label used in prompts, error copy and the API.
providerDisplayName :: KnownProvider -> Text
providerDisplayName AnthropicProvider           = "Anthropic"
providerDisplayName OllamaProvider              = "Ollama"
providerDisplayName (OpenAICompatProvider spec) = ocsDisplayName spec

providerId :: KnownProvider -> ProviderId
providerId = ProviderId . providerLabel

-- | Parse a label (case-insensitive) back to a 'KnownProvider'.
parseProvider :: Text -> Maybe KnownProvider
parseProvider = parseProviderIn knownProviders

-- | 'parseProvider' over an explicit catalog (the seam that lets tests prove a
-- new row is reachable without editing the shipped catalog).
parseProviderIn :: [KnownProvider] -> Text -> Maybe KnownProvider
parseProviderIn kps t =
  let needle = T.toCaseFold (T.strip t)
  in lookup needle [(T.toCaseFold (providerLabel p), p) | p <- kps]

-- | Guidance for a provider id that Seal used to ship under another name.
-- 'Nothing' for ids that never existed. One place, three surfaces (session,
-- agent def, @new -p@).
legacyProviderHint :: Text -> Maybe Text
legacyProviderHint raw
  | T.toCaseFold (T.strip raw) == "openrouter" =
      Just "openrouter was renamed to openai-compat"
  | otherwise = Nothing

-- | The known provider ids, comma-separated (for \"known: …\" error tails).
knownLabelList :: Text
knownLabelList = T.intercalate ", " (map providerLabel knownProviders)

-- | The vault secret name under which this provider's API key is stored.
vaultKeyName :: KnownProvider -> Text
vaultKeyName AnthropicProvider           = "ANTHROPIC_API_KEY"
vaultKeyName OllamaProvider              = "OLLAMA_API_KEY"
vaultKeyName (OpenAICompatProvider spec) = ocsVaultKey spec

-- | The model a provider starts with when the user has not chosen one.
-- 'Nothing' means the provider has no sensible default (the generic
-- OpenAI-compatible row): the user must pick one, and the transport refuses to
-- send an empty model id.
defaultModelFor :: KnownProvider -> Maybe ModelId
defaultModelFor AnthropicProvider           = Just (ModelId "claude-opus-4-8")
defaultModelFor OllamaProvider              = Just (ModelId "llama3.2")
defaultModelFor (OpenAICompatProvider spec) = ocsDefaultModel spec

-- | A provider's default model: the configured value if given (an empty string
-- counts as unset), else the provider's own default (Anthropic's for an
-- unrecognized label).
resolveDefaultModel :: Maybe Text -> Text -> Maybe ModelId
resolveDefaultModel (Just m) _ | not (T.null (T.strip m)) = Just (ModelId m)
resolveDefaultModel _ lbl =
  maybe (defaultModelFor AnthropicProvider) defaultModelFor (parseProvider lbl)

-- | Build a live provider. For Anthropic, stored OAuth tokens take precedence
-- over an API key; a present-but-corrupt OAuth blob fails loudly (the user must
-- re-run @\/provider login@) rather than silently falling back. The @callCounter@
-- is shared across turns so Ollama-synthesized tool-call ids stay unique across
-- a whole session (Ollama responses carry no id, so Seal synthesizes
-- @call_<i>@; the counter must outlive any single 'Ollama' value, which is
-- rebuilt each turn — see 'ProviderRuntime.prCallCounter').
resolveProvider
  :: Maybe VaultHandle -> Manager -> RuntimeConfig -> KnownProvider -> ModelId
  -> IORef Int -> IO (Either Text SomeProvider)
resolveProvider Nothing _ _ AnthropicProvider _ _ =
  pure (Left "vault not configured \x2014 run /vault setup")
resolveProvider (Just vh) mgr _cfg AnthropicProvider model _ = do
  eOAuth <- vhGet vh "ANTHROPIC_OAUTH_TOKENS"
  case eOAuth of
    Right blob -> case deserializeTokens blob of
      Left e     -> pure (Left ("stored Anthropic OAuth tokens are unreadable ("
                                  <> e <> ") — run /provider login anthropic"))
      Right toks -> do
        ref <- newIORef toks
        let sess = OAuthSession
              { osTokens  = ref
              , osRefresh = refreshTokens mgr
              , osPersist = void . vhPut vh "ANTHROPIC_OAUTH_TOKENS" . serializeTokens
              }
        _ <- ensureFresh sess
        pure (Right (SomeProvider (mkAnthropicOAuth mgr sess model)))
    Left _ -> do
      eKey <- vhGet vh (vaultKeyName AnthropicProvider)
      pure $ case eKey of
        Left e         -> Left (credErr AnthropicProvider e)
        Right keyBytes -> Right (SomeProvider (mkAnthropic mgr (mkApiKey keyBytes) model))
resolveProvider mvh mgr cfg OllamaProvider model callCounter
  | not (ollamaNeedsKey baseUrl) =
      -- local/custom host: keyless, never touch the vault
      Right . SomeProvider <$> mkOllama mgr baseUrl Nothing model callCounter
  | otherwise = case mvh of
      Nothing ->
        pure (Left "Ollama Cloud needs an API key \x2014 run /vault setup then /provider add ollama")
      Just vh -> do
        eKey <- vhGet vh (vaultKeyName OllamaProvider)
        case eKey of
          Right kb -> Right . SomeProvider <$> mkOllama mgr baseUrl (Just (mkApiKey kb)) model callCounter
          Left VaultLocked -> pure (Left "Ollama Cloud needs an API key and the vault is locked — run /vault unlock")
          Left e   -> pure (Left (vaultErrText e))
  where
    baseUrl = fromMaybe defaultOllamaBaseUrl (providerBaseUrl cfg (providerLabel OllamaProvider))
resolveProvider mvh mgr cfg kp@(OpenAICompatProvider spec) model _ =
  -- Base-URL errors precede credential errors: an unreachable endpoint is a
  -- more useful first message than a missing key.
  case providerBaseUrlFor cfg kp of
    Left e -> pure (Left e)
    Right baseUrl
      | ocsKeyRequired spec -> case mvh of
          Nothing -> pure (Left (keyNoVaultMsg spec))
          Just vh -> do
            eKey <- vhGet vh (vaultKeyName kp)
            case eKey of
              Right kb -> pure (Right (SomeProvider
                (mkOpenAICompat mgr (Just (mkApiKey kb)) baseUrl model spec)))
              Left VaultLocked -> pure (Left (keyLockedMsg spec))
              Left (VaultKeyNotFound _) -> pure (Left (keyMissingMsg spec))
              Left e -> pure (Left (vaultErrText e))
      | otherwise -> do
          -- Keyless: a stored key is used when one is there, but its absence
          -- (or an unreadable vault) never blocks the request.
          mKey <- readKeyIfAny mvh (vaultKeyName kp)
          pure (Right (SomeProvider (mkOpenAICompat mgr mKey baseUrl model spec)))

-- | The effective base URL for a provider.
--
--   * A catalog row with a built-in URL is authoritative: a configured
--     @[providers.<id>] base_url@ is ignored, so the URL the UI shows is always
--     the URL Seal talks to.
--   * The generic row reads its own @[providers.<id>] base_url@ and validates
--     it; a missing or unusable value is an actionable 'Left'.
--   * Ollama keeps its configured value or its local default, unvalidated.
--   * Anthropic's endpoint is fixed.
providerBaseUrlFor :: RuntimeConfig -> KnownProvider -> Either Text Text
providerBaseUrlFor cfg kp = case kp of
  AnthropicProvider -> Right anthropicBaseUrl
  OllamaProvider ->
    Right (fromMaybe defaultOllamaBaseUrl (providerBaseUrl cfg (providerLabel kp)))
  OpenAICompatProvider spec -> case ocsBuiltinBaseUrl spec of
    Just u -> Right u
    Nothing -> case providerBaseUrl cfg (ocsId spec) of
      Nothing -> Left (missingBaseUrlMsgFor kp)
      Just raw -> case validateBaseUrl raw of
        Left reason -> Left (invalidBaseUrlMsg spec reason)
        Right u -> Right u

-- | Run a completion through an existentially-wrapped provider.
completeSome :: SomeProvider -> CompletionRequest -> IO (Either Text CompletionResponse)
completeSome (SomeProvider p) = complete p

-- | List a provider's models through an existentially-wrapped provider.
listSome :: SomeProvider -> IO (Either Text [ModelId])
listSome (SomeProvider p) = listModels p

-- -- User-facing copy (design §6) --------------------------------------------

missingBaseUrlMsgFor :: KnownProvider -> Text
missingBaseUrlMsgFor kp =
  providerDisplayName kp <> " needs a base URL — set it in the Providers view, or"
    <> " run /provider add " <> providerLabel kp

invalidBaseUrlMsg :: OpenAICompatSpec -> Text -> Text
invalidBaseUrlMsg spec reason =
  ocsDisplayName spec <> " base URL is not usable (" <> reason <> ") — it must be"
    <> " an http(s) URL like https://host/v1"

keyNoVaultMsg :: OpenAICompatSpec -> Text
keyNoVaultMsg spec =
  ocsDisplayName spec <> " needs an API key — run /vault setup, then /provider add "
    <> ocsId spec

keyLockedMsg :: OpenAICompatSpec -> Text
keyLockedMsg spec =
  ocsDisplayName spec <> " needs an API key and the vault is locked — run /vault unlock"

keyMissingMsg :: OpenAICompatSpec -> Text
keyMissingMsg spec =
  ocsDisplayName spec <> " needs an API key — run /provider add " <> ocsId spec
    <> " (add to an existing entry; no need to remove it first)"

-- | Provider-aware credential error: a missing key points the user at the
-- exact @/provider add@ they need.
credErr :: KnownProvider -> VaultError -> Text
credErr kp = \case
  VaultKeyNotFound _ ->
    "no credential for " <> providerLabel kp
      <> " — run /provider add " <> providerLabel kp
  e -> vaultErrText e

-- | Human-readable rendering of a vault error.
vaultErrText :: VaultError -> Text
vaultErrText = \case
  VaultLocked         -> "vault is locked — run /vault unlock"
  VaultNotFound       -> "vault not found — run /vault setup"
  VaultAlreadyExists  -> "vault already exists"
  VaultKeyNotFound k  -> "no such secret: " <> k
  VaultBackendError t -> "backend error: " <> t

-- -- Status ------------------------------------------------------------------

-- | What the UI shows for a provider. Kept next to 'configuredProviders' so the
-- two cannot disagree:
--
--   * anthropic: @oauth@ / @api-key@ / @none@ / @vault-locked@;
--   * ollama: @keyless@ for a local URL, otherwise the vault probe;
--   * family: no usable base URL ⇒ @none@; a readable key ⇒ @api-key@ (whether
--     or not the key is required); otherwise @keyless@ when a key is optional,
--     @none@ when it is required, and @vault-locked@ when the vault holding it
--     is locked (visible-but-not-configured, matching anthropic).
providerAuthStatus :: Maybe VaultHandle -> RuntimeConfig -> KnownProvider -> IO Text
providerAuthStatus mh cfg kp = case kp of
  AnthropicProvider -> case mh of
    Nothing -> pure "none"
    Just vh -> do
      eOAuth <- vhGet vh anthropicOAuthKey
      case eOAuth of
        Right _          -> pure "oauth"
        Left VaultLocked -> pure "vault-locked"
        Left _           -> probeVault vh (vaultKeyName AnthropicProvider)
  OllamaProvider -> do
    let baseUrl = fromMaybe defaultOllamaBaseUrl (providerBaseUrl cfg (providerLabel kp))
    if not (ollamaNeedsKey baseUrl)
      then pure "keyless"
      else case mh of
        Nothing -> pure "none"
        Just vh -> probeVault vh (vaultKeyName OllamaProvider)
  OpenAICompatProvider spec -> case providerBaseUrlFor cfg kp of
    Left _ -> pure "none"
    Right _ -> case mh of
      Nothing -> pure (if ocsKeyRequired spec then "none" else "keyless")
      Just vh -> do
        r <- vhGet vh (ocsVaultKey spec)
        pure $ case r of
          Right _ -> "api-key"
          Left VaultLocked
            | ocsKeyRequired spec -> "vault-locked"
            | otherwise           -> "keyless"
          Left _ -> if ocsKeyRequired spec then "none" else "keyless"

-- | Probe the vault for a single key and map the outcome to a status string.
probeVault :: VaultHandle -> Text -> IO Text
probeVault vh key = do
  r <- vhGet vh key
  pure $ case r of
    Right _                   -> "api-key"
    Left VaultLocked          -> "vault-locked"
    Left (VaultKeyNotFound _) -> "none"
    Left _                    -> "none"

-- -- Configuration -----------------------------------------------------------

-- | The providers that are *configured* (usable right now).
--
--   * __Anthropic__: an API key or an OAuth blob is stored.
--   * __Ollama__: a keyless local URL, or a key stored for a cloud URL.
--   * __family__: the base URL resolves, and either a key is not required or a
--     key is stored.
--
-- A missing vault ('Nothing') means no provider has credentials, so only
-- keyless providers (local Ollama, a keyless family row with a base URL)
-- survive the filter.
configuredProviders :: Maybe VaultHandle -> RuntimeConfig -> IO [KnownProvider]
configuredProviders = configuredProvidersFor knownProviders

-- | 'configuredProviders' over an explicit catalog (the injection seam for
-- tests: a synthetic preset row can be checked without shipping it).
configuredProvidersFor
  :: [KnownProvider] -> Maybe VaultHandle -> RuntimeConfig -> IO [KnownProvider]
configuredProvidersFor kps mvh cfg = filterM isConfigured kps
  where
    isConfigured kp = case kp of
      OllamaProvider -> do
        let baseUrl = fromMaybe defaultOllamaBaseUrl (providerBaseUrl cfg "ollama")
        if not (ollamaNeedsKey baseUrl)
          then pure True
          else hasVaultKey mvh (vaultKeyName OllamaProvider)
      AnthropicProvider ->
        hasVaultKey mvh (vaultKeyName AnthropicProvider)
          ||^ hasVaultKey mvh anthropicOAuthKey
      OpenAICompatProvider spec -> case providerBaseUrlFor cfg kp of
        Left _ -> pure False
        Right _ | not (ocsKeyRequired spec) -> pure True
                | otherwise -> hasVaultKey mvh (ocsVaultKey spec)

-- | Does the vault hold a value for @k@? 'Nothing' (no vault) or a vault error
-- (locked / key missing) → 'False'; a present key → 'True'.
hasVaultKey :: Maybe VaultHandle -> Text -> IO Bool
hasVaultKey Nothing _ = pure False
hasVaultKey (Just vh) k = do
  r <- vhGet vh k
  pure $ case r of
    Right _ -> True
    Left _  -> False

-- | Read a key only if it is available; a locked/absent vault is not an error.
readKeyIfAny :: Maybe VaultHandle -> Text -> IO (Maybe ApiKey)
readKeyIfAny Nothing _ = pure Nothing
readKeyIfAny (Just vh) k = do
  r <- vhGet vh k
  pure $ case r of
    Right kb -> Just (mkApiKey kb)
    Left _   -> Nothing

-- | Short-circuit OR for two 'IO' booleans (so the second is only run when the
-- first is 'False'). Avoids touching OAuth when an API key is already present.
infixr 2 ||^
(||^) :: IO Bool -> IO Bool -> IO Bool
a ||^ b = do
  x <- a
  if x then pure True else b
