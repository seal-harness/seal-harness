{-# LANGUAGE OverloadedStrings #-}
-- | The @[channels.\<id\>]@ config model + bidirectional TOML codec + pure
-- channel resolution. This is the leaf module for multi-instance chat channel
-- management (design §3.1, §3.2, §3.4, §3.5).
--
-- It exports only the leaf types + codec + resolution — no 'RuntimeConfig'
-- import, keeping the module acyclic (migration lives in "Seal.Config.File").
module Seal.Channels.Config
  ( -- * Channel id
    ChannelId (..)
  , mkChannelId
  , channelIdText
  , isValidChannelId
    -- * Channel config
  , ChannelConfig (..)
    -- * Resolved channel
  , ResolvedChannel (..)
    -- * TOML codec
  , channelConfigCodec
  , keyChannelIdBiMap
  , restrictChannelKind
    -- * Vault keys
  , telegramVaultKeyFor
    -- * Resolution (pure)
  , resolveChannelConfig
    -- * Migration helpers
  , fromSignalConfig
  , fromTelegramConfig
  ) where
import Data.Bifunctor (first)

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Toml ((.=))
import Toml qualified
import Toml.Codec.BiMap (BiMap (..), TomlBiMap, TomlBiMapError (..))
import Toml.Parser (parseKey, unTomlParseError)
import Toml.Type.Key (Key)
import Toml.Type.Printer (prettyKey)

import Seal.Core.AllowList (AllowList (..), allowListCodec)
import Seal.Core.ChannelKind (ChannelKind (..), channelKindFromText, channelKindToText)
import Seal.Core.MessageSource (UserId)
import Seal.Signal.Config
  ( SignalAccount
  , SignalConfig (..)
  , defaultSignalConfig
  , resolveSignalConfig
  )
import Seal.Telegram.Config
  ( TelegramConfig (..)
  , TelegramToken
  , defaultTelegramConfig
  , resolveTelegramConfig
  )

-- ---------------------------------------------------------------------------
-- ChannelId — the validated [channels.<id>] key + URL capture + vault-key
-- component. Smart-constructed: non-empty, no leading dash (option-injection
-- defense), charset [A-Za-z0-9_-]. Constructor exported (like RepoId);
-- mkChannelId is used at trust boundaries (POST body, URL capture, TOML key
-- decode via keyChannelIdBiMap).
-- ---------------------------------------------------------------------------

newtype ChannelId = ChannelId Text
  deriving stock (Eq, Ord, Show)

-- | @[A-Za-z0-9_-]+@, non-empty, no leading dash. Mirrors the 'RepoId'
-- charset but forbids a leading @-@ (option-injection defense).
isValidChannelId :: Text -> Bool
isValidChannelId t =
  not (T.null t)
    && T.head t /= '-'
    && T.all validIdChar t
  where
    validIdChar :: Char -> Bool
    validIdChar c = c `Set.member` idChars
    idChars :: Set Char
    idChars = Set.fromList
      $ ['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "_-"

-- | Smart-construct a 'ChannelId'. Rejects empty, leading dash, and any
-- character outside @[A-Za-z0-9_-]@.
mkChannelId :: Text -> Either Text ChannelId
mkChannelId t
  | isValidChannelId t = Right (ChannelId t)
  | otherwise          = Left ("invalid channel id: " <> T.pack (show t))

channelIdText :: ChannelId -> Text
channelIdText (ChannelId t) = t

-- ---------------------------------------------------------------------------
-- ChannelConfig — the [channels.<id>] config section
-- ---------------------------------------------------------------------------

-- | The @[channels.\<id\>]@ config section. All fields optional at the file
-- level except 'ccKind' (required, restricted to Signal/Telegram by the
-- codec). 'ccAccount' is Signal-specific; 'ccToken' is the Telegram
-- config-level token fallback (mirrors 'tcToken' in the legacy
-- 'TelegramConfig'); the vault token takes precedence at resolution time.
data ChannelConfig = ChannelConfig
  { ccKind           :: ChannelKind
  , ccLabel          :: Maybe Text
  , ccAccount        :: Maybe Text
  , ccToken          :: Maybe Text
  , ccTextChunkLimit :: Maybe Int
  , ccAllowFrom      :: AllowList Text
  } deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- ResolvedChannel — the validated, ready-to-fork channel
-- ---------------------------------------------------------------------------

-- | A channel config that has been validated and smart-constructed into a
-- ready-to-fork form. 'ResolvedSignal' carries the validated 'SignalAccount';
-- 'ResolvedTelegram' carries the validated 'TelegramToken'. Both carry the
-- chunk limit and 'AllowList' 'UserId' for the sender check.
data ResolvedChannel
  = ResolvedSignal SignalAccount Int (AllowList UserId)
  | ResolvedTelegram TelegramToken Int (AllowList UserId)
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- TOML codec (bidirectional, restricted kind)
-- ---------------------------------------------------------------------------

-- | Restrict a TOML @kind@ text value to only @signal@ or @telegram@. All
-- other 'ChannelKind' constructors (Cli, Web, Background, Other) and unknown
-- strings are rejected — 'ResolvedChannel' only has Signal/Telegram arms.
restrictChannelKind :: Text -> Either Text ChannelKind
restrictChannelKind t = case channelKindFromText t of
  Just Signal   -> Right Signal
  Just Telegram -> Right Telegram
  Just _        -> Left ("invalid channel kind: " <> t <> " (only signal/telegram allowed)")
  Nothing       -> Left ("unknown channel kind: " <> t)

-- | Bidirectional tomland codec for a single @[channels.\<id\>]@ table. The
-- @kind@ field is restricted to @signal@/@telegram@ via 'restrictChannelKind'
-- (fail-closed on cli/web/background/other). @allow_from@ uses the shared
-- 'allowListCodec' from 'Seal.Core.AllowList'.
channelConfigCodec :: Toml.TomlCodec ChannelConfig
channelConfigCodec = ChannelConfig
  <$> Toml.textBy channelKindToText restrictChannelKind "kind"  .= ccKind
  <*> Toml.dioptional (Toml.text "label")                      .= ccLabel
  <*> Toml.dioptional (Toml.text "account")                    .= ccAccount
  <*> Toml.dioptional (Toml.text "token")                      .= ccToken
  <*> Toml.dioptional (Toml.int "text_chunk_limit")            .= ccTextChunkLimit
  <*> allowListCodec                                            .= ccAllowFrom

-- | Bidirectional 'TomlBiMap' between TOML 'Key's and 'ChannelId's. @forward@
-- (Key → ChannelId) runs 'mkChannelId' on the rendered key text; a bad id is
-- a 'Failure' (fail-closed). @backward@ (ChannelId → Key) re-parses the id
-- text (guaranteed valid by 'mkChannelId'). Mirrors 'keyRepoBiMap'.
keyChannelIdBiMap :: TomlBiMap Key ChannelId
keyChannelIdBiMap = BiMap
  { forward  = first (ArbitraryError . ("invalid channel id key: " <>) . T.pack . show)
                . mkChannelId . prettyKey
  , backward = first (ArbitraryError . unTomlParseError) . parseKey . channelIdText
  }

-- ---------------------------------------------------------------------------
-- Vault keys for multi-channel Telegram
-- ---------------------------------------------------------------------------

-- | The vault key for a Telegram channel's bot token. The legacy id
-- @telegram@ maps to the unsuffixed key @TELEGRAM_BOT_TOKEN@ (the key the
-- CLI wizard writes), preserving zero-migration. All other ids use the
-- suffixed form @TELEGRAM_BOT_TOKEN_\<id\>@.
telegramVaultKeyFor :: ChannelId -> Text
telegramVaultKeyFor cid =
  if channelIdText cid == "telegram"
    then "TELEGRAM_BOT_TOKEN"
    else "TELEGRAM_BOT_TOKEN_" <> channelIdText cid

-- ---------------------------------------------------------------------------
-- Resolution (pure) — config section + pre-fetched vault token -> ResolvedChannel
-- ---------------------------------------------------------------------------

-- | Resolve a 'ChannelConfig' into a 'ResolvedChannel'. Pure — takes a
-- pre-fetched vault token (if any) rather than a 'VaultHandle', so it is
-- unit-testable without vault I/O. The caller does the @vhGet@ and passes
-- the result here.
--
-- * Signal: delegates to 'resolveSignalConfig' with the account from
--   'ccAccount'. No vault (account is in config). Fails if 'ccAccount' is
--   unset.
-- * Telegram: the vault token (pre-fetched by the caller) takes precedence;
--   if absent, falls back to 'ccToken' (the config-level token, preserved
--   from legacy 'tcToken'); if both absent, fails. Delegates to
--   'resolveTelegramConfig'.
-- * Other kinds: rejected (only Signal/Telegram are valid channel types).
resolveChannelConfig
  :: ChannelId
  -> ChannelConfig
  -> Maybe Text
  -> Either Text ResolvedChannel
resolveChannelConfig _ cc mVaultToken =
  case ccKind cc of
    Signal -> do
      (acct, limit, allow) <- resolveSignalConfig (Just (signalConfigFromChannel cc)) Nothing
      Right (ResolvedSignal acct limit allow)
    Telegram -> do
      (token, limit, allow) <- resolveTelegramConfig (Just (telegramConfigFromChannel cc)) mVaultToken
      Right (ResolvedTelegram token limit allow)
    _ -> Left "unsupported channel kind (only signal/telegram allowed)"

-- | Build a 'SignalConfig' from a 'ChannelConfig' for delegation to
-- 'resolveSignalConfig'. Maps 'ccAccount'/'ccTextChunkLimit'/'ccAllowFrom'
-- onto the legacy section shape.
signalConfigFromChannel :: ChannelConfig -> SignalConfig
signalConfigFromChannel cc = defaultSignalConfig
  { scAccount        = ccAccount cc
  , scTextChunkLimit = ccTextChunkLimit cc
  , scAllowFrom      = ccAllowFrom cc
  }

-- | Build a 'TelegramConfig' from a 'ChannelConfig' for delegation to
-- 'resolveTelegramConfig'. Maps 'ccToken'/'ccTextChunkLimit'/'ccAllowFrom'
-- onto the legacy section shape.
telegramConfigFromChannel :: ChannelConfig -> TelegramConfig
telegramConfigFromChannel cc = defaultTelegramConfig
  { tcToken         = ccToken cc
  , tcTextChunkLimit = ccTextChunkLimit cc
  , tcAllowFrom     = ccAllowFrom cc
  }

-- ---------------------------------------------------------------------------
-- Migration helpers — legacy [signal]/[telegram] -> ChannelConfig
-- ---------------------------------------------------------------------------

-- | Convert a legacy 'SignalConfig' (@[signal]@ section) into a
-- 'ChannelConfig' with @kind=Signal@. 'ccToken' is 'Nothing' (Signal has no
-- token). Used by 'migrateLegacyChannels' in "Seal.Config.File".
fromSignalConfig :: SignalConfig -> ChannelConfig
fromSignalConfig sc = ChannelConfig
  { ccKind           = Signal
  , ccLabel          = Nothing
  , ccAccount        = scAccount sc
  , ccToken          = Nothing
  , ccTextChunkLimit = scTextChunkLimit sc
  , ccAllowFrom      = scAllowFrom sc
  }

-- | Convert a legacy 'TelegramConfig' (@[telegram]@ section) into a
-- 'ChannelConfig' with @kind=Telegram@. 'ccToken' preserves 'tcToken' so
-- token-in-config setups survive migration. Used by 'migrateLegacyChannels'
-- in "Seal.Config.File".
fromTelegramConfig :: TelegramConfig -> ChannelConfig
fromTelegramConfig tc = ChannelConfig
  { ccKind           = Telegram
  , ccLabel          = Nothing
  , ccAccount        = Nothing
  , ccToken          = tcToken tc
  , ccTextChunkLimit = tcTextChunkLimit tc
  , ccAllowFrom      = tcAllowFrom tc
  }
