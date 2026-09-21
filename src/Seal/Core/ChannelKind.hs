-- | The channel enumeration: the closed set of channels the runtime knows
-- about, plus an 'Other' escape hatch for future channels. The lowercase
-- tag from 'channelKindToText' is the value the transcript's @_te_metadata@
-- @channel@ field carries.
--
-- This module is now a thin re-export from 'Seal.Gateway.Types.ChannelKind'
-- (the canonical home in the 'seal-gateway-types' library stanza).
module Seal.Core.ChannelKind
  ( ChannelKind (..)
  , channelKindToText
  , channelKindFromText
  ) where

import Seal.Gateway.Types.ChannelKind
