{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The code-level provider registry: the set of providers Seal knows how to
-- build, and the mapping from each to its display label, vault credential key,
-- and default model. Credential resolution (reading the key from the vault and
-- constructing a live 'SomeProvider') is added on top of this vocabulary.
module Seal.Providers.Registry
  ( KnownProvider (..)
  , knownProviders
  , configuredProviders
  , providerLabel
  , anthropicOAuthKey
  , providerId
  , parseProvider
  , validateProviderName
  , isProviderName
  , providerTypeForName
  , vaultKeyName
  , vaultKeyNameForName
  , defaultModelFor
  , resolveDefaultModel
  , resolveDefaultModelForName
  , resolveProvider
  , resolveProviderByName
  , providerBaseUrlFor
  , providerBaseUrlForName
  , customProviderNames
  , configuredCustomProviderNames
  , configuredProviderNames
  , completeSome
  , listSome
  , vaultErrText
  ) where

import Control.Monad (void, filterM)
import Data.Char (isAsciiLower, isDigit, toUpper)
import Data.IORef (IORef, newIORef)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client (Manager)

import Seal.Config.File (RuntimeConfig (..), providerBaseUrl, providerDefaultModel)
import Seal.Core.Types (ModelId (..), ProviderId (..))
import Seal.Providers.Anthropic
  ( OAuthSession (..), ensureFresh, mkAnthropic, mkAnthropicOAuth )
import Seal.Providers.Anthropic.OAuth
  ( deserializeTokens, refreshTokens, serializeTokens )
import Seal.Providers.Class
  ( CompletionRequest, CompletionResponse, Provider (..), SomeProvider (..) )
import Seal.Providers.Ollama (defaultOllamaBaseUrl, mkOllama, ollamaNeedsKey)
import Seal.Providers.OpenRouter
  ( defaultOpenRouterBaseUrl, mkOpenAICompatible, mkOpenRouter )
import Seal.Security.Secrets (mkApiKey)
import Seal.Security.Vault (VaultHandle (..))
import Seal.Security.Vault.Age (VaultError (..))

-- | The Anthropic OAuth token vault key (mirrors
-- 'Seal.Command.Provider.anthropicOAuthKey'; duplicated here to avoid a
-- circular import).
anthropicOAuthKey :: Text
anthropicOAuthKey = "ANTHROPIC_OAUTH_TOKENS"

-- | Every provider Seal can build. M1 ships Anthropic only; later milestones
-- extend this sum (the totality of the functions below forces each addition to
-- be handled everywhere).
data KnownProvider
  = AnthropicProvider
  | OllamaProvider
  | OpenRouterProvider
  | OpenAICompatibleProvider
    -- ^ Any OpenAI-compatible @/v1/chat/completions@ endpoint the operator
    -- names (a self-hosted vLLM, LM Studio, api.openai.com, …). Same client as
    -- OpenRouter ('mkOpenAICompatible'); the difference is that it has **no**
    -- built-in base URL — the endpoint is required input, not a default.
  deriving stock (Eq, Show, Enum, Bounded)

knownProviders :: [KnownProvider]
knownProviders = [minBound .. maxBound]

-- | The user-facing id typed at the @/provider@ prompt.
providerLabel :: KnownProvider -> Text
providerLabel AnthropicProvider = "anthropic"
providerLabel OllamaProvider    = "ollama"
providerLabel OpenRouterProvider = "openrouter"
providerLabel OpenAICompatibleProvider = "openai"

providerId :: KnownProvider -> ProviderId
providerId = ProviderId . providerLabel

-- | Parse a label (case-insensitive) back to a 'KnownProvider'.
parseProvider :: Text -> Maybe KnownProvider
parseProvider t =
  let needle = T.toCaseFold (T.strip t)
  in lookup needle [(T.toCaseFold (providerLabel p), p) | p <- knownProviders]

-- | Validate a provider instance name. An instance name is the config table
-- key (@[providers.\<name\>]@), the value sessions and agent defs store, and
-- the stem of the instance's vault key. The grammar is an allow-list applied
-- to the raw text (no normalisation): 1-32 characters of @a-z@, @0-9@ and
-- @-@, no leading/trailing @-@, and no @--@. @all@ and @default@ are
-- reserved because they are literal @\/api\/providers\/...@ routes.
validateProviderName :: Text -> Either Text ()
validateProviderName name
  | T.null name = Left "provider name must not be empty"
  | T.length name > 32 =
      Left "provider name must be at most 32 characters"
  | name `elem` ["all", "default"] =
      Left "\"all\" and \"default\" are reserved provider names"
  | T.any badChar name =
      Left "provider names may contain only a-z, 0-9 and \"-\""
  | "-" `T.isPrefixOf` name || "-" `T.isSuffixOf` name =
      Left "provider name must not start or end with \"-\""
  | "--" `T.isInfixOf` name =
      Left "provider name must not contain \"--\""
  | name `elem` ["anthropic", "ollama", "openrouter"] =
      Left (name <> " is a built-in provider type; choose another name")
  | otherwise = Right ()
  where
    badChar c =
      not (isAsciiLower c || isDigit c || c == '-')

-- | Is @name@ either a built-in provider id or a syntactically valid custom
-- instance name?
isProviderName :: Text -> Bool
isProviderName name =
  isJust (parseProvider name)
    || either (const False) (const True) (validateProviderName name)

-- | The implementation a name resolves to. An unknown (custom) name is an
-- OpenAI-compatible endpoint: that is the only provider type whose endpoint
-- and name are operator-supplied.
providerTypeForName :: Text -> KnownProvider
providerTypeForName name = fromMaybe OpenAICompatibleProvider (parseProvider name)

-- | The vault secret name under which this provider's API key is stored.
vaultKeyName :: KnownProvider -> Text
vaultKeyName AnthropicProvider = "ANTHROPIC_API_KEY"
vaultKeyName OllamaProvider    = "OLLAMA_API_KEY"
vaultKeyName OpenRouterProvider = "OPENROUTER_API_KEY"
vaultKeyName OpenAICompatibleProvider = "OPENAI_API_KEY"

-- | The vault key for a provider name. Built-ins keep their legacy key; a
-- custom OpenAI-compatible instance uses a name-derived key so two instances
-- never share one secret.
vaultKeyNameForName :: Text -> Text
vaultKeyNameForName name = case parseProvider name of
  Just kp -> vaultKeyName kp
  Nothing -> "PROVIDER_APIKEY_" <> shoutySnake name
  where
    shoutySnake = T.map (\c -> if c == '-' then '_' else toUpper c)

-- | The model used when the user has not chosen one.
defaultModelFor :: KnownProvider -> ModelId
defaultModelFor AnthropicProvider = ModelId "claude-opus-4-8"
defaultModelFor OllamaProvider    = ModelId "llama3.2"
defaultModelFor OpenRouterProvider = ModelId "deepseek/deepseek-v4.1-flash-1017"
-- | A starting point only: a generic endpoint's real model ids are its own, so
-- the operator overrides this in @[providers.openai] default_model@ or in the
-- setup wizard.
defaultModelFor OpenAICompatibleProvider = ModelId "gpt-4o-mini"

-- | A provider's default model: the configured value if given, else the
-- provider's hardcoded default (Anthropic's for an unrecognized label).
resolveDefaultModel :: Maybe Text -> Text -> ModelId
resolveDefaultModel (Just m) _   = ModelId m
resolveDefaultModel Nothing  lbl =
  maybe (defaultModelFor AnthropicProvider) defaultModelFor (parseProvider lbl)

-- | The default model for a provider *name*: the configured value if given,
-- else the implementation's hardcoded default. Custom names are
-- OpenAI-compatible instances.
resolveDefaultModelForName :: RuntimeConfig -> Text -> ModelId
resolveDefaultModelForName cfg name =
  case providerDefaultModel cfg name of
    Just m  -> ModelId m
    Nothing -> defaultModelFor (providerTypeForName name)

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
          Left e   -> pure (Left (vaultErrText e))
  where
    baseUrl = providerBaseUrlFor cfg OllamaProvider
resolveProvider mvh mgr cfg OpenRouterProvider model _ =
  -- OpenRouter requires a vault-stored API key; no keyless mode.
  case mvh of
    Nothing ->
      pure (Left "OpenRouter needs an API key \x2014 run /vault setup then /provider add openrouter")
    Just vh -> do
      eKey <- vhGet vh (vaultKeyName OpenRouterProvider)
      case eKey of
        Left e -> pure (Left (credErr OpenRouterProvider e))
        Right kb ->
          pure (Right (SomeProvider (mkOpenRouter mgr (Just (mkApiKey kb)) baseUrl model)))
  where
    baseUrl = providerBaseUrlFor cfg OpenRouterProvider

resolveProvider mvh mgr cfg OpenAICompatibleProvider model _ =
  resolveOpenAICompatible mvh mgr "openai"
    (providerBaseUrlFor cfg OpenAICompatibleProvider)
    (vaultKeyName OpenAICompatibleProvider) model

-- | Build a provider for an operator-named instance. Built-ins resolve
-- exactly as before; an unknown name is an OpenAI-compatible endpoint whose
-- base URL and credential live under that instance's config/vault names.
resolveProviderByName
  :: Maybe VaultHandle -> Manager -> RuntimeConfig -> Text -> ModelId
  -> IORef Int -> IO (Either Text SomeProvider)
resolveProviderByName mvh mgr cfg name model counter =
  case parseProvider name of
    Just kp -> resolveProvider mvh mgr cfg kp model counter
    Nothing -> resolveOpenAICompatible mvh mgr name
      (fromMaybe "" (providerBaseUrl cfg name))
      (vaultKeyNameForName name) model

-- | The shared OpenAI-compatible resolution. No built-in endpoint: the
-- operator names it. Fail closed rather than silently reaching out to
-- api.openai.com on their behalf, which would send a key meant for a
-- self-hosted server to a third party.
resolveOpenAICompatible
  :: Maybe VaultHandle -> Manager -> Text -> Text -> Text -> ModelId
  -> IO (Either Text SomeProvider)
resolveOpenAICompatible mvh mgr name baseUrl keyName model
  | T.null baseUrl =
      pure (Left ("the OpenAI-compatible provider \"" <> name
        <> "\" needs a base URL — set [providers." <> name
        <> "] base_url (the setup wizard asks for it)"))
  | otherwise = case mvh of
      Nothing ->
        pure (Left ("the OpenAI-compatible provider \"" <> name
          <> "\" needs an API key — run /vault setup then /provider add "
          <> name))
      Just vh -> do
        eKey <- vhGet vh keyName
        case eKey of
          Left e -> pure (Left (credErrForName name e))
          Right kb ->
            -- The same client OpenRouter uses: that protocol is the whole
            -- point of the generic option.
            pure (Right (SomeProvider
              (mkOpenAICompatible mgr (Just (mkApiKey kb)) baseUrl model)))

-- | The effective base URL for a provider: the configured
-- @[providers.&lt;label&gt;] base_url@ when set, else that provider's own
-- built-in default. Each provider reads its OWN config section — Ollama's URL
-- is never used for another provider. Anthropic's endpoint is fixed inside the
-- provider, so its value here is only a placeholder.
providerBaseUrlFor :: RuntimeConfig -> KnownProvider -> Text
providerBaseUrlFor cfg kp =
  fromMaybe (builtInBaseUrl kp) (providerBaseUrl cfg (providerLabel kp))
  where
    builtInBaseUrl OllamaProvider     = defaultOllamaBaseUrl
    builtInBaseUrl OpenRouterProvider = defaultOpenRouterBaseUrl
    builtInBaseUrl AnthropicProvider  = "https://api.anthropic.com"
    -- Deliberately empty: a generic endpoint has no default (see
    -- 'resolveProvider'), and callers treat "" as "not configured".
    builtInBaseUrl OpenAICompatibleProvider = ""

-- | The effective base URL for a provider name. Custom names have no
-- built-in default: the empty string means "not configured".
providerBaseUrlForName :: RuntimeConfig -> Text -> Text
providerBaseUrlForName cfg name
  | Just kp <- parseProvider name = providerBaseUrlFor cfg kp
  | otherwise = fromMaybe "" (providerBaseUrl cfg name)

-- | Run a completion through an existentially-wrapped provider.
completeSome :: SomeProvider -> CompletionRequest -> IO (Either Text CompletionResponse)
completeSome (SomeProvider p) = complete p

-- | List a provider's models through an existentially-wrapped provider.
listSome :: SomeProvider -> IO (Either Text [ModelId])
listSome (SomeProvider p) = listModels p

-- | Provider-aware credential error: a missing key points the user at the
-- exact @/provider add@ they need.
credErr :: KnownProvider -> VaultError -> Text
credErr kp = \case
  VaultKeyNotFound _ ->
    "no credential for " <> providerLabel kp
      <> " — run /provider add " <> providerLabel kp
  e -> vaultErrText e

-- | Provider-aware credential error for an instance name.
credErrForName :: Text -> VaultError -> Text
credErrForName name = \case
  VaultKeyNotFound _ ->
    "no credential for " <> name <> " — run /provider add " <> name
  e -> vaultErrText e

-- | Human-readable rendering of a vault error.
vaultErrText :: VaultError -> Text
vaultErrText = \case
  VaultLocked         -> "vault is locked — run /vault unlock"
  VaultNotFound       -> "vault not found — run /vault setup"
  VaultAlreadyExists  -> "vault already exists"
  VaultKeyNotFound k  -> "no such secret: " <> k
  VaultBackendError t -> "backend error: " <> t

-- | The set of providers that are *configured* (have a usable credential or
-- are usable keyless). A provider appears in @/provider list@ and in the
-- frontend's provider select only when this returns 'True'. The rules mirror
-- the auth labels in 'Seal.Command.Provider.listCmd':
--
--   * __Ollama__ is configured when its base URL needs no key (local daemon)
--     OR an API key / OAuth blob is stored in the vault. A cloud URL
--     (@ollama.com@) without a key is NOT configured.
--   * __Anthropic__ is configured when either an OAuth blob or an API key is
--     stored in the vault.
--
-- A missing vault ('Nothing') means no provider has credentials, so only a
-- keyless local Ollama would survive the filter (and only when its base URL
-- is the default local URL).
configuredProviders :: Maybe VaultHandle -> RuntimeConfig -> IO [KnownProvider]
configuredProviders mvh cfg = filterM isConfigured knownProviders
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
      OpenRouterProvider ->
        hasVaultKey mvh (vaultKeyName OpenRouterProvider)
      OpenAICompatibleProvider -> do
        -- BOTH halves are required: a base URL with no credential fails on the
        -- first call, and a credential with no base URL has nowhere to go.
        keyed <- hasVaultKey mvh (vaultKeyName OpenAICompatibleProvider)
        pure (keyed && not (T.null
          (fromMaybe "" (providerBaseUrl cfg (providerLabel OpenAICompatibleProvider)))))

-- | Every custom (operator-named) provider instance in the config, sorted.
-- A custom instance is any @[providers.\<name\>]@ section whose key is not a
-- built-in provider id and passes the instance-name grammar.
customProviderNames :: RuntimeConfig -> [Text]
customProviderNames cfg =
  sort
    [ name
    | name <- Map.keys (rcProviders cfg)
    , isNothing (parseProvider name)
    , either (const False) (const True) (validateProviderName name)
    ]

-- | Custom OpenAI-compatible instances that are configured: they have both a
-- base URL and a stored credential.
configuredCustomProviderNames :: Maybe VaultHandle -> RuntimeConfig -> IO [Text]
configuredCustomProviderNames mvh cfg =
  filterM isConfigured (customProviderNames cfg)
  where
    isConfigured name = do
      keyed <- hasVaultKey mvh (vaultKeyNameForName name)
      pure (keyed && not (T.null
        (fromMaybe "" (providerBaseUrl cfg name))))

-- | Every configured provider, built-in and custom, as instance names.
configuredProviderNames :: Maybe VaultHandle -> RuntimeConfig -> IO [Text]
configuredProviderNames mvh cfg = do
  builtins <- map providerLabel <$> configuredProviders mvh cfg
  customs <- configuredCustomProviderNames mvh cfg
  pure (builtins <> customs)

-- | Does the vault hold a value for @k@? 'Nothing' (no vault) or a vault error
-- (locked / key missing) → 'False'; a present key → 'True'.
hasVaultKey :: Maybe VaultHandle -> Text -> IO Bool
hasVaultKey Nothing _ = pure False
hasVaultKey (Just vh) k = do
  r <- vhGet vh k
  pure $ case r of
    Right _ -> True
    Left _  -> False

-- | Short-circuit OR for two 'IO' booleans (so the second is only run when the
-- first is 'False'). Avoids touching OAuth when an API key is already present.
infixr 2 ||^
(||^) :: IO Bool -> IO Bool -> IO Bool
a ||^ b = do
  x <- a
  if x then pure True else b
