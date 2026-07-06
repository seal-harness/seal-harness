{-# LANGUAGE OverloadedStrings #-}
-- | The @[signal]@ config section + the smart-constructed 'SignalAccount'
-- newtype (the option-injection defense for the signal-cli argv). Lives in
-- its own module so "Seal.Config.File" can add the section without a cycle:
-- this module exports the codec; Seal.Config.File imports it and wires the
-- @[signal]@ table. Resolution takes the section directly (not the whole
-- 'FileConfig') to keep the modules acyclic.
module Seal.Signal.Config
  ( SignalAccount (..)
  , mkSignalAccount
  , signalAccountText
  , SignalConfig (..)
  , defaultSignalConfig
  , defaultSignalChunkLimit
  , resolveSignalConfig
  , signalConfigCodec
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

-- ---------------------------------------------------------------------------
-- SignalAccount — the validated account label for the signal-cli argv
-- ---------------------------------------------------------------------------

-- | The signal-cli account label (a phone number or UUID). Smart-constructed:
-- non-empty, no leading dash (option-injection defense — a leading-dash
-- value would be interpreted as a flag by signal-cli), charset
-- @[A-Za-z0-9+:-_@. The validated type that reaches the subprocess argv.
newtype SignalAccount = SignalAccount Text
  deriving stock (Eq, Show)

mkSignalAccount :: Text -> Either Text SignalAccount
mkSignalAccount t
  | T.null t        = Left "signal account is empty"
  | T.head t == '-' = Left "signal account must not start with '-' (option injection)"
  | not (T.all validAccountChar t)
                    = Left "signal account has invalid characters"
  | otherwise       = Right (SignalAccount t)

validAccountChar :: Char -> Bool
validAccountChar c = c `Set.member` accountChars
  where
    accountChars :: Set Char
    accountChars = Set.fromList
      $ ['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "+-:_"

signalAccountText :: SignalAccount -> Text
signalAccountText (SignalAccount t) = t

-- ---------------------------------------------------------------------------
-- SignalConfig — the [signal] config section
-- ---------------------------------------------------------------------------

-- | The @[signal]@ config section. All fields optional at the file level;
-- @seal signal@ fails fast via 'resolveSignalConfig' if 'scAccount' is
-- unset (no config account AND no vault-supplied account).
data SignalConfig = SignalConfig
  { scAccount        :: Maybe Text       -- ^ phone number or UUID
  , scTextChunkLimit :: Maybe Int        -- ^ default 'defaultSignalChunkLimit'
  , scAllowFrom      :: AllowList Text   -- ^ sender allow-list (phone or UUID)
  } deriving stock (Eq, Show)

-- | Signal's text-message character limit. Replies longer than this are
-- chunked via 'Seal.Channels.Signal.Transport.chunkMessage'.
defaultSignalChunkLimit :: Int
defaultSignalChunkLimit = 1998

defaultSignalConfig :: SignalConfig
defaultSignalConfig = SignalConfig
  { scAccount = Nothing
  , scTextChunkLimit = Just defaultSignalChunkLimit
  , scAllowFrom = AllowAll
  }

-- ---------------------------------------------------------------------------
-- TOML codec (bidirectional, used by Seal.Config.File)
-- ---------------------------------------------------------------------------

-- | Bidirectional tomland codec for the @[signal]@ section. 'scAllowFrom'
-- is a TOML array of strings (@allow_from = ["+1", "uuid:abc"]@); an absent
-- array decodes as 'AllowAll'.
signalConfigCodec :: Toml.TomlCodec SignalConfig
signalConfigCodec = SignalConfig
  <$> Toml.dioptional (Toml.text "account")         .= scAccount
  <*> Toml.dioptional (Toml.int "text_chunk_limit") .= scTextChunkLimit
  <*> allowListCodec                                 .= scAllowFrom

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
-- Resolution — config section + vault account -> validated (account, limit, allow)
-- ---------------------------------------------------------------------------

-- | Resolve the @[signal]@ section + an optional vault-supplied account
-- label into a validated 'SignalAccount', chunk limit, and
-- 'AllowList UserId' for the channel's sender check. The vault account (if
-- supplied) overrides the config account; either way it's smart-constructed
-- here. A missing account (no section, no vault account) is rejected. The
-- @allow_from@ 'AllowList Text' is mapped through 'mkUserId' to an
-- 'AllowList UserId' — a malformed entry fails the whole resolution with a
-- clear error.
resolveSignalConfig
  :: Maybe SignalConfig -> Maybe Text
  -> Either Text (SignalAccount, Int, AllowList UserId)
resolveSignalConfig mSection mVaultAccount =
  case mVaultAccount <|> (mSection >>= scAccount) of
    Nothing -> Left "signal: no account configured (set [signal].account or supply via vault)"
    Just acctRaw -> do
      acct <- mkSignalAccount acctRaw
      let sigCfg = fromMaybe defaultSignalConfig mSection
          limit  = fromMaybe defaultSignalChunkLimit (scTextChunkLimit sigCfg)
      allowUserId <- mapAllowUserId (scAllowFrom sigCfg)
      Right (acct, limit, allowUserId)

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
      Left err -> Left ("signal allow_from has invalid user id " <> T.pack (show t) <> ": " <> err)