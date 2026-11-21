{-# LANGUAGE OverloadedStrings #-}
-- | The reusable allow-list family used by sender allow-listing (channels)
-- and opcode-exposure gating (agent defs). Extracted from
-- 'Seal.Security.Policy' so the cross-channel layer can depend on this leaf
-- without pulling in the whole security policy.
--
-- This module is now a thin re-export from 'Seal.Gateway.Types.AllowList'
-- (the canonical home in the 'seal-gateway-types' library stanza), plus the
-- shared 'allowListCodec' used by 'Seal.Signal.Config', 'Seal.Telegram.Config',
-- and 'Seal.Channels.Config'.
module Seal.Core.AllowList
  ( AllowList (..)
  , isAllowed
  , allowListCodec
  ) where

import Data.Set qualified as Set
import Data.Text (Text)
import Toml qualified

import Seal.Gateway.Types.AllowList

-- | Codec for the @allow_from@ array: 'AllowAll' when absent, 'AllowOnly'
-- of the listed strings when present. Shared by all channel config codecs
-- (Signal, Telegram, Channels) to avoid triplication.
allowListCodec :: Toml.TomlCodec (AllowList Text)
allowListCodec = Toml.dimap toList fromList (Toml.dioptional (Toml.arrayOf Toml._Text "allow_from"))
  where
    toList :: AllowList Text -> Maybe [Text]
    toList AllowAll       = Nothing
    toList (AllowOnly xs) = Just (Set.toList xs)
    fromList :: Maybe [Text] -> AllowList Text
    fromList Nothing   = AllowAll
    fromList (Just xs) = AllowOnly (Set.fromList xs)
