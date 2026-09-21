{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The wire snapshot type for the WS @lists@ frame and the REST @GET
-- /api/lists@ endpoint. Carries the partitioned session lists plus the set
-- of sessions currently in a @thinking@ turn.
--
-- Only the data type + 'ToJSON' instance live here. The builder
-- ('buildListsSnapshot') stays in the server ('Seal.Gateway.ListsSnapshot')
-- because it depends on 'TabsHandle', 'SealPaths', and 'SessionStore' —
-- server-internal types.
--
-- Canonical home; 'Seal.Gateway.ListsSnapshot' in the server re-exports the
-- type from here.
module Seal.Gateway.Types.ListsSnapshot
  ( ListsSnapshotWire (..)
  ) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Aeson qualified as A
import Data.Text (Text)
import GHC.Generics (Generic)

-- | The partitioned snapshot. Haskell record fields use the @lsw@ prefix;
-- the 'ToJSON' instance drops it (wire keys: @tabs@, @recentSessions@,
-- @archivedSessions@, @tabSessions@, @thinkingSessionIds@).
data ListsSnapshotWire = ListsSnapshotWire
  { lswTabs             :: [A.Value]
  , lswRecentSessions   :: [A.Value]
  , lswArchivedSessions :: [A.Value]
  , lswTabSessions      :: [A.Value]
  , lswThinkingSessionIds :: [Text]
  } deriving stock (Eq, Show, Generic)

instance ToJSON ListsSnapshotWire where
  toJSON s = object
    [ "tabs"             .= lswTabs s
    , "recentSessions"   .= lswRecentSessions s
    , "archivedSessions" .= lswArchivedSessions s
    , "tabSessions"      .= lswTabSessions s
    , "thinkingSessionIds" .= lswThinkingSessionIds s
    ]