{-# LANGUAGE OverloadedStrings #-}
-- | Instance names for providers, and the vault-key names derived from them.
--
-- A provider is a *named instance of a type*: the name is the config table key
-- (@[providers.\<name\>]@), the identifier sessions/agent defs/the CLI and the
-- API use, and the stem of the instance's vault key. This module is a leaf: it
-- knows nothing about provider types or the catalog, so it cannot import
-- 'Seal.Providers.Registry' (which imports it) or 'Seal.Config.File'.
--
-- The grammar is an **allow-list applied to the raw text with no
-- normalisation** (casefolding then deriving would create collisions): 1–32
-- characters of @a–z@, @0–9@ and @-@, no leading/trailing @-@, no @--@, and not a
-- reserved word. That makes @SHOUTY_SNAKE@ injective, keeps TOML bare keys
-- valid, and makes the two derived vault-key namespaces disjoint from each other
-- and from the legacy @\<TYPE\>_API_KEY@ names:
--
--   * @PROVIDER_APIKEY_\<NAME\>@ — the instance's API key;
--   * @PROVIDER_OAUTH_\<NAME\>@  — the instance's OAuth blob (anthropic only).
--
-- The legacy carve-out (a type-named instance keeps @ANTHROPIC_API_KEY@ etc.) is
-- decided by the caller, which knows the type, and passed in as the legacy key.
module Seal.Providers.Name
  ( ProviderName
  , mkProviderName
  , providerNameText
  , shoutySnake
  , apiKeyNameFor
  , oauthKeyNameFor
  , checkNameForType
  , reservedProviderNames
  , providerNameRule
  , providerNameExample
  , apiKeyPrefix
  , oauthKeyPrefix
  ) where

import Data.Char (isAsciiLower, isDigit, toUpper)
import Data.Text (Text)
import Data.Text qualified as T

-- | A validated instance name. The constructor is not exported: the only way to
-- obtain one is 'mkProviderName' (or 'checkNameForType' on an existing one).
newtype ProviderName = ProviderName Text
  deriving stock (Eq, Ord, Show)

providerNameText :: ProviderName -> Text
providerNameText (ProviderName t) = t

-- | Words the gateway routes and the CLI parse as commands. @all@ and
-- @default@ are literal @/api/providers/…@ routes; a section named either
-- would be unreachable by name. (@openrouter@ is deliberately **not** reserved:
-- it is a provider id, so a type-named @openrouter@ instance must be legal.)
reservedProviderNames :: [Text]
reservedProviderNames = ["all", "default"]

-- | The grammar, as one sentence, for prompts and inline validation.
providerNameRule :: Text
providerNameRule =
  "1–32 characters of a–z, 0–9 and “-” (no leading/trailing “-”, no “--”)"

providerNameExample :: Text
providerNameExample = "local-vllm"

-- | Validate an instance name. The 'Left' is a short reason phrase; callers
-- compose the user-facing sentence (§4 of the design).
mkProviderName :: Text -> Either Text ProviderName
mkProviderName raw
  | T.null raw = Left "empty"
  | T.length raw > 32 = Left "too long"
  | raw `elem` reservedProviderNames = Left "reserved"
  | T.any badChar raw = Left "charset"
  | "-" `T.isPrefixOf` raw || "-" `T.isSuffixOf` raw = Left "leading or trailing dash"
  | "--" `T.isInfixOf` raw = Left "double dash"
  | otherwise = Right (ProviderName raw)
  where
    badChar c = not (isAsciiLower c || isDigit c || c == '-')

-- | Upper-case, @-@ to @_@. Injective over the grammar (which has no @_@).
shoutySnake :: ProviderName -> Text
shoutySnake = T.map (\c -> if c == '-' then '_' else toUpper c) . providerNameText

apiKeyPrefix :: Text
apiKeyPrefix = "PROVIDER_APIKEY_"

oauthKeyPrefix :: Text
oauthKeyPrefix = "PROVIDER_OAUTH_"

-- | The vault key holding an instance's API key: the type's legacy key when the
-- instance is named after its own type (so upgrading never moves a secret),
-- otherwise the prefixed, name-derived form.
apiKeyNameFor :: Maybe Text -> ProviderName -> Text -> Text
apiKeyNameFor (Just legacyKey) n ownTypeId
  | providerNameText n == ownTypeId = legacyKey
apiKeyNameFor _ n _ = apiKeyPrefix <> shoutySnake n

-- | The vault key holding an anthropic instance's OAuth blob, with the same
-- legacy carve-out.
oauthKeyNameFor :: Maybe Text -> ProviderName -> Text -> Text
oauthKeyNameFor (Just legacyKey) n ownTypeId
  | providerNameText n == ownTypeId = legacyKey
oauthKeyNameFor _ n _ = oauthKeyPrefix <> shoutySnake n

-- | A name may equal a type id only for *that* type. The leaf cannot know the
-- catalog, so the caller passes the known type ids (Registry:
-- @map typeId providerTypes@) and the instance's own type id.
checkNameForType :: [Text] -> ProviderName -> Text -> Either Text ()
checkNameForType knownTypeIds n ownTypeId
  | t `elem` knownTypeIds && t /= ownTypeId = Left "is another provider's type id"
  | otherwise = Right ()
  where
    t = providerNameText n
