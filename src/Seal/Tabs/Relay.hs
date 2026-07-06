{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The streaming-aware per-conversation output relay. Focused
-- conversations receive every 'StreamStart'/'ChunkOf'/'StreamEnd' verbatim;
-- background 'ActivityDigest' conversations get at most one breadcrumb ping
-- per burst; 'Firehose' forwards everything.
module Seal.Tabs.Relay
  ( RelayEvent (..)
  , relayEvent
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

import Seal.Tabs.Types (RelayMode (..))

-- | One streaming event to relay.
data RelayEvent
  = StreamStart Text     -- ^ a stream began (carries a header/breadcrumb)
  | ChunkOf Text          -- ^ one chunk
  | StreamEnd             -- ^ the stream ended
  deriving stock (Eq, Show, Generic)

-- | Relay one event to one conversation. Returns the lines to send to that
-- conversation (0, 1, or many). Pure.
--
-- * 'FocusedOnly': 'StreamStart' → @[]@; 'ChunkOf' t → @[t]@;
--   'StreamEnd' → @[]@. The focused conversation sees the chunks verbatim,
--   no framing.
-- * 'ActivityDigest': 'StreamStart' → @[]@; 'ChunkOf' t → @[]@ (suppress);
--   'StreamEnd' → @[breadcrumb]@ (one ping per burst).
-- * 'Firehose': every event → @[show event]@ (forwards everything, including
--   framing — the firehose consumer wants the structure).
relayEvent :: RelayMode -> RelayEvent -> [Text]
relayEvent FocusedOnly (ChunkOf t) = [t]
relayEvent FocusedOnly _           = []
relayEvent ActivityDigest StreamEnd = ["[tab] activity"]
relayEvent ActivityDigest _         = []
relayEvent Firehose e                = [T.pack (show e)]