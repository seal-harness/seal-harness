{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The pure 'TabList' — the crown jewel. I1 (contiguous slots, removal
-- compacts tmux-window style), I2 (no two tabs share a 'TabRef'), and I3
-- (a cursor keys by 'TabRef' not slot, so it survives compaction) are all
-- enforced **by construction** (the smart constructors reject violations).
-- Plus the per-conversation routing types and the parsed @/tab@ command
-- ADTs.
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
  , slotOf
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

import Seal.Core.ChannelKind (ChannelKind)
import Seal.Core.MessageSource (ConversationId)
import Seal.Core.Types (SessionId)
import Seal.Handles.Tab (TabIndex (..), TabKind, mkTabIndex)
import Seal.Harness.Id (HarnessId)

-- | A tab's reference to ground truth: a live session OR a harness.
data TabRef = BoundSession SessionId | BoundHarness HarnessId
  deriving stock (Eq, Show)

-- | The liveness of a tab's backing ref.
data TabStatus = Live | Dead
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | One tab.
data Tab = Tab
  { tIndex  :: TabIndex
  , tRef    :: TabRef
  , tKind   :: TabKind
  , tLabel  :: Maybe Text     -- ^ optional user-set label
  , tStatus :: TabStatus
  } deriving stock (Eq, Show)

-- | The per-conversation routing key: ChannelKind × ConversationId.
data ConversationKey = ConversationKey ChannelKind ConversationId
  deriving stock (Eq, Ord, Show)

-- | How a conversation receives a tab's output.
data RelayMode = FocusedOnly | ActivityDigest | Firehose
  deriving stock (Eq, Show)

-- | A conversation's cursor + relay mode. The cursor keys by 'TabRef' (I3):
-- it names ground truth, resolved to a current slot at read time via
-- 'slotOf'.
data CursorState = CursorState
  { csFocused   :: TabRef           -- ^ which tab this conversation is focused on
  , csRelayMode :: RelayMode
  } deriving stock (Eq, Show)

-- | The tab list. I1 (contiguous 0..n-1, removal compacts) + I2 (no two tabs
-- share a 'TabRef') are enforced by the smart constructors. Hard 36-slot cap.
newtype TabList = TabList { tlTabs :: [Tab] }
  deriving stock (Eq, Show)

-- | Construct an empty 'TabList'.
emptyTabList :: TabList
emptyTabList = TabList []

-- | The number of tabs (also the next free slot under I1).
tabCount :: TabList -> Int
tabCount = length . tlTabs

-- | The maximum number of tabs (the hard 36-slot cap).
maxTabs :: Int
maxTabs = 36

-- | Insert a tab at the lowest free slot (I1). 'Left' if the 'TabRef' is
-- already present (I2) or the list is full (36).
insertTab :: TabRef -> TabKind -> Maybe Text -> TabList -> Either Text TabList
insertTab ref kind label (TabList ts)
  | ref `elem` map tRef ts = Left "tab ref already bound"
  | length ts >= maxTabs   = Left "tab list full (36 slots)"
  | otherwise =
      -- The index is the lowest free slot. Since the list is contiguous
      -- (I1), that's just `length ts` (the next slot after the last).
      let idx = mkTabIndex (length ts)
      in case idx of
           Right i -> Right (TabList (ts <> [Tab i ref kind label Live]))
           Left e  -> Left e  -- unreachable: length < 36 implies idx < 36

-- | Look up a tab by index. 'Nothing' if the index is out of range.
lookupTab :: TabList -> TabIndex -> Maybe Tab
lookupTab (TabList ts) i = go ts
  where
    go [] = Nothing
    go (t:rest)
      | tIndex t == i = Just t
      | otherwise     = go rest

-- | Look up a tab by its 'TabRef'. 'Nothing' if absent.
lookupByRef :: TabList -> TabRef -> Maybe Tab
lookupByRef (TabList ts) ref = go ts
  where
    go [] = Nothing
    go (t:rest)
      | tRef t == ref = Just t
      | otherwise    = go rest

-- | Remove a tab by index. Compacts the list (I1: slots renumber to 0..n-1).
-- 'Left' if the index is out of range.
removeTab :: TabList -> TabIndex -> Either Text TabList
removeTab (TabList ts) i =
  case break (\t -> tIndex t == i) ts of
    (_, []) -> Left "tab index out of range"
    (before, _t : after) ->
      -- Renumber the surviving tabs 0..n-2 (I1: contiguous after compaction).
      let survivors = before <> after
          renumbered = zipWith (\n t -> t { tIndex = mkIdx n }) [0..] survivors
      in Right (TabList renumbered)
  where
    mkIdx n = case mkTabIndex n of
      Right x -> x
      Left _  -> error ("removeTab: renumber out of range (unreachable, n=" <> show n <> ")")

-- | Rename a tab (set its label). 'Left' if the index is out of range.
renameTab :: TabList -> TabIndex -> Text -> Either Text TabList
renameTab (TabList ts) i name =
  case go ts of
    Nothing -> Left "tab index out of range"
    Just ts' -> Right (TabList ts')
  where
    go [] = Nothing
    go (t:rest)
      | tIndex t == i = Just (t { tLabel = Just name } : rest)
      | otherwise     = case go rest of
          Just rest' -> Just (t : rest')
          Nothing   -> Nothing

-- | The current slot of a 'TabRef' (I3: resolved at read time). 'Nothing' if
-- the ref is no longer in the list (the cursor is stale).
slotOf :: TabList -> TabRef -> Maybe TabIndex
slotOf tl ref = tIndex <$> lookupByRef tl ref

-- ---------------------------------------------------------------------------
-- The parsed /tab command ADTs
-- ---------------------------------------------------------------------------

-- | The tab-kind argument to @/tab new [<kind>]@.
data TabKindArg = TkaAi | TkaProvider | TkaHarness | TkaShell | TkaSsh | TkaTmux
  deriving stock (Eq, Show)

-- | The --force flag for @/tab close <N> [--force]@.
data ForceMode = Force | NoForce
  deriving stock (Eq, Show)

-- | The parsed @/tab@ command family.
data TabSlashCommand
  = TabNewCmd (Maybe TabKindArg)
  | TabListCmd
  | TabCloseCmd TabIndex ForceMode
  | TabFocusCmd TabIndex
  | TabResumeCmd SessionId
  | TabRenameCmd TabIndex Text
  deriving stock (Eq, Show)