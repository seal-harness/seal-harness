-- | The validated 'TabIndex' (0..35) — the single index type reused
-- everywhere (TabList slots, /N routing, /tab close <N>, /tab focus <N>).
-- Smart-constructed so an out-of-range index fails to compile into any path.
-- Plus 'TabKind', the closed enumeration of tab kinds.
--
-- This module is now a thin re-export from 'Seal.Gateway.Types.Tab' (the
-- canonical home in the 'seal-gateway-types' library stanza). It preserves
-- the original import surface so existing imports (@import Seal.Handles.Tab@)
-- continue to work unchanged.
module Seal.Handles.Tab
  ( TabIndex (..)
  , mkTabIndex
  , tabIndexToInt
  , tabIndexToChar
  , tabIndexFromChar
  , maxTabIndex
  , TabKind (..)
  ) where

import Seal.Gateway.Types.Tab
