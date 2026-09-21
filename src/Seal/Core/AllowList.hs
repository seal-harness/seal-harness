-- | The reusable allow-list family used by sender allow-listing (channels)
-- and opcode-exposure gating (agent defs). Extracted from
-- 'Seal.Security.Policy' so the cross-channel layer can depend on this leaf
-- without pulling in the whole security policy.
--
-- This module is now a thin re-export from 'Seal.Gateway.Types.AllowList'
-- (the canonical home in the 'seal-gateway-types' library stanza).
module Seal.Core.AllowList
  ( AllowList (..)
  , isAllowed
  ) where

import Seal.Gateway.Types.AllowList