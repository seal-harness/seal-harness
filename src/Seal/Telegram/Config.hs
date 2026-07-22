{-# LANGUAGE OverloadedStrings #-}
-- | The @[telegram]@ config section + the smart-constructed 'TelegramToken'
-- newtype (the option-injection defense for the bot token that reaches the
-- Telegram Bot API). Lives in its own module so "Seal.Config.File" can add
-- the section without a cycle: this module exports the codec;
-- Seal.Config.File imports it and wires the @[telegram]@ table. Resolution
-- takes the section directly (not the whole 'RuntimeConfig') to keep the
-- modules acyclic. Mirrors "Seal.Signal.Config".
module Seal.Telegram.Config
  ( TelegramToken (..)
  , mkTelegramToken
  , telegramTokenText
  , TelegramConfig (..)
  , defaultTelegramConfig
  , defaultTelegramChunkLimit
  , resolveTelegramConfig
  , telegramConfigCodec
  , telegramVaultKey
  ) where

import Control.Applicative ((<|>))
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Toml ((.=))
import Toml qualified

import Seal.Core.AllowList (AllowList (..))
import Seal.Core.MessageSource (UserId, mkUserId)

-- | The vault key under which the Telegram bot token is stored. The token
-- is NOT stored in @config.toml@ (cleartext) — the setup wizard writes it
-- to the vault, and channel startup reads it from the vault. The config
-- section carries only non-secret fields (chunk limit, allow_from).
telegramVaultKey :: Text
telegramVaultKey = "TELEGRAM_BOT_TOKEN"

-- ---------------------------------------------------------------------------
-- TelegramToken — the validated bot token for the Telegram Bot API
-- ---------------------------------------------------------------------------

-- | A Telegram bot token as issued by BotFather (@<digits>:<AA-xx>@). Smart-
-- constructed: non-empty, no leading dash (option-injection defense — a
-- leading-dash value would be interpreted as a flag by a subprocess if the
-- token ever reaches an argv), charset @[A-Za-z0-9+:-_@. The validated type
-- that reaches the Bot API URL path. Not a secret in the vault sense (it is
-- stored in @config.toml@); it is the channel credential, like the Signal
-- account label.
newtype TelegramToken = TelegramToken Text
  deriving stock (Eq, Show)

-- | Smart-construct a 'TelegramToken'. Accepts the BotFather format
-- (@<digits>:<rest>@) and rejects empty / leading-dash / invalid chars.
mkTelegramToken :: Text -> Either Text TelegramToken
mkTelegramToken t
  | T.null t        = Left "telegram token is empty"
  | T.head t == '-' = Left "telegram token must not start with '-' (option injection)"
  | not (T.all validTokenChar t)
                     = Left "telegram token has invalid characters"
  | otherwise       = Right (TelegramToken t)

validTokenChar :: Char -> Bool
validTokenChar c = c `Set.member` tokenChars
  where
    tokenChars :: Set Char
    tokenChars = Set.fromList
      $ ['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "+-:_"

telegramTokenText :: TelegramToken -> Text
telegramTokenText (TelegramToken t) = t

-- ---------------------------------------------------------------------------
-- TelegramConfig — the [telegram] config section
-- ---------------------------------------------------------------------------

-- | The @[telegram]@ config section. All fields optional at the file level;
-- @seal telegram@ fails fast via 'resolveTelegramConfig' if 'tcToken' is
-- unset (no config token AND no vault-supplied token).
data TelegramConfig = TelegramConfig
  { tcToken         :: Maybe Text       -- ^ BotFather bot token
  , tcTextChunkLimit :: Maybe Int        -- ^ default 'defaultTelegramChunkLimit'
  , tcAllowFrom     :: AllowList Text   -- ^ sender allow-list (Telegram user id)
  } deriving stock (Eq, Show)

-- | Telegram's text-message character limit. Replies longer than this are
-- chunked via 'Seal.Channels.Telegram.Transport.chunkMessage'. Telegram's
-- hard limit is 4096; we leave headroom for the @model> @ prefix.
defaultTelegramChunkLimit :: Int
defaultTelegramChunkLimit = 3900

defaultTelegramConfig :: TelegramConfig
defaultTelegramConfig = TelegramConfig
  { tcToken = Nothing
  , tcTextChunkLimit = Just defaultTelegramChunkLimit
  , tcAllowFrom = AllowAll
  }

-- ---------------------------------------------------------------------------
-- TOML codec (bidirectional, used by Seal.Config.File)
-- ---------------------------------------------------------------------------

-- | Bidirectional tomland codec for the @[telegram]@ section. 'tcAllowFrom'
-- is a TOML array of strings (@allow_from = ["12345", "67890"]@); an absent
-- array decodes as 'AllowAll'.
telegramConfigCodec :: Toml.TomlCodec TelegramConfig
telegramConfigCodec = TelegramConfig
  <$> Toml.dioptional (Toml.text "token")            .= tcToken
  <*> Toml.dioptional (Toml.int "text_chunk_limit")  .= tcTextChunkLimit
  <*> allowListCodec                                  .= tcAllowFrom

-- | Codec for the @allow_from@ array: 'AllowAll' when absent, 'AllowOnly'
-- of the listed strings when present.
allowListCodec :: Toml.TomlCodec (AllowList Text)
allowListCodec = Toml.dimap toList fromList (Toml.dioptional (Toml.arrayOf Toml._Text "allow_from"))
  where
    toList :: AllowList Text -> Maybe [Text]
    toList AllowAll       = Nothing
    toList (AllowOnly xs) = Just (Set.toList xs)
    fromList :: Maybe [Text] -> AllowList Text
    fromList Nothing   = AllowAll
    fromList (Just xs) = AllowOnly (Set.fromList xs)

-- ---------------------------------------------------------------------------
-- Resolution — config section + vault token -> validated (token, limit, allow)
-- ---------------------------------------------------------------------------

-- | Resolve the @[telegram]@ section + an optional vault-supplied token
-- into a validated 'TelegramToken', chunk limit, and 'AllowList UserId' for
-- the channel's sender check. The vault token (if supplied) overrides the
-- config token; either way it's smart-constructed here. A missing token (no
-- section, no vault token) is rejected. The @allow_from@ 'AllowList Text' is
-- mapped through 'mkUserId' to an 'AllowList UserId' — a malformed entry
-- fails the whole resolution with a clear error.
resolveTelegramConfig
  :: Maybe TelegramConfig -> Maybe Text
  -> Either Text (TelegramToken, Int, AllowList UserId)
resolveTelegramConfig mSection mVaultToken =
  case mVaultToken <|> (mSection >>= tcToken) of
    Nothing -> Left "telegram: no token configured (set [telegram].token or supply via vault)"
    Just tokenRaw -> do
      token <- mkTelegramToken tokenRaw
      let tgCfg = fromMaybe defaultTelegramConfig mSection
          limit  = fromMaybe defaultTelegramChunkLimit (tcTextChunkLimit tgCfg)
      allowUserId <- mapAllowUserId (tcAllowFrom tgCfg)
      Right (token, limit, allowUserId)

-- | Map an 'AllowList Text' through 'mkUserId' to an 'AllowList UserId'.
-- 'AllowAll' passes through; 'AllowOnly' maps each element (a malformed
-- entry fails the whole resolution).
mapAllowUserId :: AllowList Text -> Either Text (AllowList UserId)
mapAllowUserId AllowAll = Right AllowAll
mapAllowUserId (AllowOnly txts) = do
  uids <- traverse mkUserIdText (Set.toList txts)
  Right (AllowOnly (Set.fromList uids))
  where
    mkUserIdText t = case mkUserId t of
      Right u  -> Right u
      Left err -> Left ("telegram allow_from has invalid user id " <> T.pack (show t) <> ": " <> err)