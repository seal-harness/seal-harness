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
  ) where

import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (ModelId (..), ProviderId (..))

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
