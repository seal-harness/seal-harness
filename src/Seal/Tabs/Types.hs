-- | The pure 'TabList' — the crown jewel. I1 (contiguous slots, removal
-- compacts tmux-window style), I2 (no two tabs share a 'TabRef'), and I3
-- (a cursor keys by 'TabRef' not slot, so it survives compaction) are all
-- enforced **by construction** (the smart constructors reject violations).
-- Plus the per-conversation routing types and the parsed @/tab@ command
-- ADTs.
--
-- This module is now a thin re-export from 'Seal.Gateway.Types.TabList'
-- (the canonical home in the 'seal-gateway-types' library stanza). The
-- original imports from 'Seal.Core.ChannelKind', 'Seal.Core.MessageSource',
-- 'Seal.Core.Types', 'Seal.Handles.Tab', and 'Seal.Harness.Id' are
-- preserved because those modules are themselves re-exports from the types
-- package — but we import from the canonical source to avoid transitive
-- re-export ambiguity.
module Seal.Tabs.Types
  ( TabRef (..)
  , TabStatus (..)
  , Tab (..)
  , ConversationKey (..)
  , RelayMode (..)
  , CursorState (..)
  , TabList (..)
  , TabKindArg (..)
  , ForceMode (..)
  , TabSlashCommand (..)
  , emptyTabList
  , tabCount
  , insertTab
  , lookupTab
  , lookupByRef
  , removeTab
  , renameTab
  , rebindTab
  , slotOf
  ) where

import Seal.Gateway.Types.TabList
