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
  , vaultErrText
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client (Manager)

import Seal.Core.Types (ModelId (..), ProviderId (..))
import Seal.Providers.Anthropic (mkAnthropic)
import Seal.Providers.Class
  ( CompletionRequest, CompletionResponse, Provider (..), SomeProvider (..) )
import Seal.Security.Secrets (mkApiKey)
import Seal.Security.Vault (VaultHandle (..))
import Seal.Security.Vault.Age (VaultError (..))

-- | Every provider Seal can build. M1 ships Anthropic only; later milestones
-- extend this sum (the totality of the functions below forces each addition to
-- be handled everywhere).
data KnownProvider = AnthropicProvider
  deriving stock (Eq, Show, Enum, Bounded)

knownProviders :: [KnownProvider]
knownProviders = [minBound .. maxBound]

-- | The user-facing id typed at the @/provider@ prompt.
providerLabel :: KnownProvider -> Text
providerLabel AnthropicProvider = "anthropic"

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

-- | The model used when the user has not chosen one.
defaultModelFor :: KnownProvider -> ModelId
defaultModelFor AnthropicProvider = ModelId "claude-opus-4-8"

-- | Build a live provider by reading its API key from the vault. The key
-- bytes flow straight into 'mkApiKey' (opaque) — never returned or logged.
resolveProvider
  :: VaultHandle -> Manager -> KnownProvider -> ModelId
  -> IO (Either Text SomeProvider)
resolveProvider vh mgr kp model = do
  eKey <- vhGet vh (vaultKeyName kp)
  pure $ case eKey of
    Left e         -> Left (credErr kp e)
    Right keyBytes -> Right (build kp mgr (mkApiKey keyBytes) model)
  where
    build AnthropicProvider m k md = SomeProvider (mkAnthropic m k md)

-- | Run a completion through an existentially-wrapped provider.
completeSome :: SomeProvider -> CompletionRequest -> IO (Either Text CompletionResponse)
completeSome (SomeProvider p) = complete p

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
