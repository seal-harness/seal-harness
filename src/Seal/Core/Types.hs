-- | Shared leaf vocabulary imported across the spine. Subset only: the types
-- the running CLI agent loop touches. (Harness/Tabs/MessageSource land later.)
--
-- This module is now a thin re-export from 'Seal.Gateway.Types.Core' (the
-- canonical home in the 'seal-gateway-types' library stanza). It preserves
-- the original import surface so existing imports (@import Seal.Core.Types@)
-- continue to work unchanged.
module Seal.Core.Types
  ( TrustLevel (..)
  , ProviderId (..)
  , ModelId (..)
  , ToolCallId (..)
  , OpName (..)
  , SessionId
  , mkSessionId
  , mkSystemSessionId
  , sessionIdText
  , isValidSessionId
  ) where

import Seal.Gateway.Types.Core
