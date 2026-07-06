-- | The 'Channel' type class — the seam a channel implements to be wired
-- into 'Seal.Ingest'. One method: 'toHandle' produces the 'ChannelHandle'
-- the ingress layer drives. Minimal on purpose; widen only when a real
-- consumer demands it. 'ChannelKind' is carried by the 'MessageSource' the
-- channel's 'chReceive' yields, so the class itself does not need it.
module Seal.Channels.Class
  ( Channel (..)
  ) where

import Seal.Handles.Channel (ChannelHandle)

class Channel h where
  toHandle :: h -> ChannelHandle