{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The code-level provider registry: the set of providers Seal knows how to
-- build, and the mapping from each to its display label, vault credential key,
-- and default model. Credential resolution (reading the key from the vault and
-- constructing a live 'SomeProvider') is added on top of this vocabulary.
module Seal.Providers.Registry
  ( KnownProvider (..)
  , knownProviders
  , providerLabel
  , providerId
  , parseProvider
  , vaultKeyName
  , defaultModelFor
  , resolveProvider
  , completeSome
  , listSome
  , vaultErrText
  ) where

import Control.Monad (void)
import Data.IORef (newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client (Manager)

import Seal.Core.Types (ModelId (..), ProviderId (..))
import Seal.Providers.Anthropic
  ( OAuthSession (..), ensureFresh, mkAnthropic, mkAnthropicOAuth )
import Seal.Providers.Anthropic.OAuth
  ( deserializeTokens, refreshTokens, serializeTokens )
import Seal.Providers.Class
  ( CompletionRequest, CompletionResponse, Provider (..), SomeProvider (..) )
import Seal.Providers.Ollama (mkOllama, ollamaNeedsKey)
import Seal.Security.Secrets (mkApiKey)
import Seal.Security.Vault (VaultHandle (..))
import Seal.Security.Vault.Age (VaultError (..))

-- | Every provider Seal can build. M1 ships Anthropic only; later milestones
-- extend this sum (the totality of the functions below forces each addition to
-- be handled everywhere).
data KnownProvider = AnthropicProvider | OllamaProvider
  deriving stock (Eq, Show, Enum, Bounded)

knownProviders :: [KnownProvider]
knownProviders = [minBound .. maxBound]

-- | The user-facing id typed at the @/provider@ prompt.
providerLabel :: KnownProvider -> Text
providerLabel AnthropicProvider = "anthropic"
providerLabel OllamaProvider    = "ollama"

providerId :: KnownProvider -> ProviderId
providerId = ProviderId . providerLabel

-- | Parse a label (case-insensitive) back to a 'KnownProvider'.
parseProvider :: Text -> Maybe KnownProvider
parseProvider t =
  let needle = T.toCaseFold (T.strip t)
  in lookup needle [(T.toCaseFold (providerLabel p), p) | p <- knownProviders]

-- | The vault secret name under which this provider's API key is stored.
vaultKeyName :: KnownProvider -> Text
vaultKeyName AnthropicProvider = "ANTHROPIC_API_KEY"
vaultKeyName OllamaProvider    = "OLLAMA_API_KEY"

-- | The model used when the user has not chosen one.
defaultModelFor :: KnownProvider -> ModelId
defaultModelFor AnthropicProvider = ModelId "claude-opus-4-8"
defaultModelFor OllamaProvider    = ModelId "llama3.2"

-- | Build a live provider. For Anthropic, stored OAuth tokens take precedence
-- over an API key; a present-but-corrupt OAuth blob fails loudly (the user must
-- re-run @\/provider login@) rather than silently falling back.
resolveProvider
  :: Maybe VaultHandle -> Manager -> Text -> KnownProvider -> ModelId
  -> IO (Either Text SomeProvider)
resolveProvider Nothing _ _ AnthropicProvider _ =
  pure (Left "vault not configured \x2014 run /vault setup")
resolveProvider (Just vh) mgr _baseUrl AnthropicProvider model = do
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
resolveProvider mvh mgr baseUrl OllamaProvider model
  | not (ollamaNeedsKey baseUrl) =
      -- local/custom host: keyless, never touch the vault
      pure (Right (SomeProvider (mkOllama mgr baseUrl Nothing model)))
  | otherwise = case mvh of
      Nothing ->
        pure (Left "Ollama Cloud needs an API key \x2014 run /vault setup then /provider add ollama")
      Just vh -> do
        eKey <- vhGet vh (vaultKeyName OllamaProvider)
        pure $ case eKey of
          Right kb -> Right (SomeProvider (mkOllama mgr baseUrl (Just (mkApiKey kb)) model))
          Left e   -> Left (vaultErrText e)

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

-- | Human-readable rendering of a vault error.
vaultErrText :: VaultError -> Text
vaultErrText = \case
  VaultLocked         -> "vault is locked — run /vault unlock"
  VaultNotFound       -> "vault not found — run /vault setup"
  VaultAlreadyExists  -> "vault already exists"
  VaultKeyNotFound k  -> "no such secret: " <> k
  VaultBackendError t -> "backend error: " <> t
