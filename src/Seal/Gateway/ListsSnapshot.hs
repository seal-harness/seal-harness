{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The wire snapshot for the WS @lists@ frame and the REST @GET /api/lists@
-- endpoint. Carries the partitioned session lists (mutually exclusive by
-- construction via 'partitionSessions'). The WS frame wraps this with
-- @{"type": "lists", ...}@ (added by the broadcast path); the REST body is
-- the bare record (no @type@ field).
--
-- Takes 'TabsHandle' + 'SealPaths' directly (NOT 'ApiDeps') so this module
-- does NOT import 'Seal.Gateway.API' — avoids a source-level import cycle
-- ('Seal.Gateway.API' imports this module for the /api/lists route).
module Seal.Gateway.ListsSnapshot
  ( ListsSnapshotWire (..)
  , buildListsSnapshot
  ) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Aeson qualified as A
import GHC.Generics (Generic)

import Seal.Config.Paths (SealPaths)
import Seal.Gateway.SessionJson (sessionInfoJsonWithSnippet, tabToJson)
import Seal.Session.Store (listArchivedSessions, listSessions)
import Seal.Tabs (snapshotTabs, TabsHandle)
import Seal.Tabs.Partition (PartitionedSessions (..), partitionSessions)
import Seal.Tabs.Types (tlTabs)

-- | The partitioned snapshot. Haskell record fields use the @lsw@ prefix;
-- the 'ToJSON' instance drops it (wire keys: @tabs@, @recentSessions@,
-- @archivedSessions@, @tabSessions@).
data ListsSnapshotWire = ListsSnapshotWire
  { lswTabs             :: [A.Value]
  , lswRecentSessions   :: [A.Value]
  , lswArchivedSessions :: [A.Value]
  , lswTabSessions      :: [A.Value]
  } deriving stock (Eq, Show, Generic)

instance ToJSON ListsSnapshotWire where
  toJSON s = object
    [ "tabs"             .= lswTabs s
    , "recentSessions"   .= lswRecentSessions s
    , "archivedSessions" .= lswArchivedSessions s
    , "tabSessions"      .= lswTabSessions s
    ]

-- | Build the partitioned snapshot. Takes the components directly (not
-- 'ApiDeps') so this module stays free of a cycle with 'Seal.Gateway.API'.
buildListsSnapshot :: TabsHandle -> SealPaths -> IO ListsSnapshotWire
buildListsSnapshot tabsH paths = do
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
    }