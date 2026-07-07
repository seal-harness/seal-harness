{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The channel enumeration: the closed set of channels the runtime knows
-- about, plus an 'Other' escape hatch for future channels. The lowercase
-- tag from 'channelKindToText' is the value the transcript's @_te_metadata@
-- @channel@ field carries.
module Seal.Core.ChannelKind
  ( ChannelKind (..)
  , channelKindToText
  , channelKindFromText
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

data ChannelKind
  = Cli | Web | Signal | Telegram | Background | Other
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The lowercase tag for the transcript's metadata field.
channelKindToText :: ChannelKind -> Text
channelKindToText = \case
  Cli        -> "cli"
  Web        -> "web"
  Signal     -> "signal"
  Telegram   -> "telegram"
  Background -> "background"
  Other      -> "other"

-- | Inverse of 'channelKindToText', case-insensitive. 'Nothing' for unknown
-- tags (the caller decides whether to fall back to 'Other' or reject).
channelKindFromText :: Text -> Maybe ChannelKind
channelKindFromText t = case T.toCaseFold t of
  "cli"        -> Just Cli
  "web"        -> Just Web
  "signal"     -> Just Signal
  "telegram"   -> Just Telegram
  "background" -> Just Background
  "other"      -> Just Other
  _            -> Nothing