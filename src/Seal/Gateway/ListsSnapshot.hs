-- | The wire snapshot for the WS @lists@ frame and the REST @GET /api/lists@
-- endpoint. Carries the partitioned session lists (mutually exclusive by
-- construction via 'partitionSessions') plus the set of sessions currently
-- in a @thinking@ turn (so a freshly-connected web client can hydrate its
-- sidebar without waiting for the next harness-status event). The WS frame
-- wraps this with @{"type": "lists", ...}@ (added by the broadcast path);
-- the REST body is the bare record (no @type@ field).
--
-- The 'ListsSnapshotWire' type lives in 'Seal.Gateway.Types.ListsSnapshot'
-- (the 'seal-gateway-types' library stanza). Only the builder
-- ('buildListsSnapshot') stays here — it depends on 'TabsHandle',
-- 'SealPaths', and 'SessionStore' (server-internal types).
--
-- Takes 'TabsHandle' + 'SealPaths' directly (NOT 'ApiDeps') so this module
-- does NOT import 'Seal.Gateway.API' — avoids a source-level import cycle
-- ('Seal.Gateway.API' imports this module for the /api/lists route).
module Seal.Gateway.ListsSnapshot
  ( ListsSnapshotWire (..)
  , buildListsSnapshot
  ) where

import Data.Set (Set)
import qualified Data.Set as Set

import Seal.Config.Paths (SealPaths)
import Seal.Gateway.Types.Core (SessionId, sessionIdText)
import Seal.Gateway.Types.ListsSnapshot (ListsSnapshotWire (..))
import Seal.Gateway.SessionJson (sessionInfoJsonWithSnippet, tabToJson)
import Seal.Session.Store (listArchivedSessions, listSessions)
import Seal.Tabs (snapshotTabs, TabsHandle)
import Seal.Tabs.Partition (PartitionedSessions (..), partitionSessions)
import Seal.Tabs.Types (tlTabs)

-- | Build the partitioned snapshot. Takes the components directly (not
-- 'ApiDeps') so this module stays free of a cycle with 'Seal.Gateway.API'.
-- The @thinking@ set is the broker's current in-memory view of which
-- sessions are mid-turn, so a freshly-connected web client can hydrate
-- its sidebar (the live activity stream only carries forward from here).
buildListsSnapshot :: TabsHandle -> SealPaths -> Set SessionId -> IO ListsSnapshotWire
buildListsSnapshot tabsH paths thinkingSids = do
  tl <- snapshotTabs tabsH
  let tabsJson = map tabToJson (tlTabs tl)
  recent   <- listSessions paths
  archived <- listArchivedSessions paths
  let ps = partitionSessions tl recent archived
  recentJson   <- mapM (sessionInfoJsonWithSnippet paths) (psRecentSessions ps)
  archivedJson <- mapM (sessionInfoJsonWithSnippet paths) (psArchivedSessions ps)
  tabbedJson   <- mapM (sessionInfoJsonWithSnippet paths) (psTabSessions ps)
  pure ListsSnapshotWire
    { lswTabs = tabsJson
    , lswRecentSessions = recentJson
    , lswArchivedSessions = archivedJson
    , lswTabSessions = tabbedJson
    , lswThinkingSessionIds = map sessionIdText (Set.toList thinkingSids)
    }
