-- | The pure partition step: given the current tab list and the on-disk
-- session lists (non-archived + archived), produce three mutually-exclusive
-- lists. The backend's source of truth for the sidebar's three sections.
--
-- Haddock note: Haskell record fields use the @ps@ prefix; the wire keys
-- (in 'Seal.Gateway.ListsSnapshot') drop the prefix
-- (@tabSessions@\/@recentSessions@\/@archivedSessions@).
module Seal.Tabs.Partition
  ( PartitionedSessions (..)
  , partitionSessions
  ) where

import Data.List (partition)
import Data.Set qualified as Set

import Seal.Session.Meta (SessionMeta (..))
import Seal.Tabs.Types (Tab (..), TabList (..), TabRef (..))

-- | The three mutually-exclusive session lists backing the sidebar sections.
data PartitionedSessions = PartitionedSessions
  { psTabSessions      :: [SessionMeta]
    -- ^ wire key: @tabSessions@ — sessions with an open tab.
  , psRecentSessions   :: [SessionMeta]
    -- ^ wire key: @recentSessions@ — non-archived, no open tab.
  , psArchivedSessions :: [SessionMeta]
    -- ^ wire key: @archivedSessions@ — archived, no open tab.
  } deriving stock (Eq, Show)

-- | Partition the session space into three mutually-exclusive lists.
--
-- A session @s@ goes into 'psTabSessions' iff some tab's 'tRef' is
-- @BoundSession (smId s)@; else into 'psRecentSessions' iff not archived;
-- else into 'psArchivedSessions'.
--
-- Harness tabs (@'BoundHarness'@) carry no session and pull nothing into
-- 'psTabSessions', so a harness's backing session (if it exists on disk)
-- stays in 'psRecentSessions' — the intentional harness dual-listing is
-- preserved.
--
-- An archived + tab-bound session goes into 'psTabSessions' (the tab wins;
-- the archive flag stays on disk and resurfaces when the tab closes). Both
-- the recent and archived lists are filtered by @tabSids@, and the
-- tab-bound entries from both are merged into 'psTabSessions'.
partitionSessions :: TabList -> [SessionMeta] -> [SessionMeta] -> PartitionedSessions
partitionSessions tl recent archived =
  let tabSids = Set.fromList [ sid | t <- tlTabs tl, BoundSession sid <- [tRef t] ]
      (tabbedFromRecent, recent') = partition (`belongsInTabs` tabSids) recent
      (tabbedFromArchived, archived') = partition (`belongsInTabs` tabSids) archived
  in PartitionedSessions
       { psTabSessions = tabbedFromRecent <> tabbedFromArchived
       , psRecentSessions = recent'
       , psArchivedSessions = archived'
       }
  where
    belongsInTabs s tabSids = smId s `Set.member` tabSids