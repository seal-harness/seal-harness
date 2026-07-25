{-# LANGUAGE OverloadedStrings #-}
-- | The broadcast helper for the WS @lists@ frame. Builds the partitioned
-- snapshot, wraps it with the WS @{"type": "lists", ...}@ envelope, and
-- pushes it to every WS subscriber via 'broadcastLists'. Called after
-- every state change that affects the sidebar partition (tab
-- insert/remove/rebind/rename/acknowledge/release, archive/unarchive,
-- session create, auto-tab insert).
--
-- The REST @GET /api/lists@ returns the bare 'ListsSnapshotWire' (no
-- @type@ field); this wrapper adds the WS envelope for the broadcast path
-- (the frontend's @useListsStream@ discriminates on @type: "lists"@).
--
-- NOTE: the design's 50ms debounce/coalesce is deferred to a follow-up —
-- at the expected single-user scale, bursts are rare and the direct
-- broadcast is correct (if occasionally redundant). A debounce helper
-- can be layered in here without changing the call sites.
module Seal.Gateway.Broadcast
  ( broadcastListsSnapshot
  ) where

import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap

import Seal.Config.Paths (SealPaths)
import Seal.Gateway.ListsSnapshot (buildListsSnapshot)
import Seal.Gateway.StreamBroker (StreamBroker, broadcastLists)
import Seal.Tabs (TabsHandle)

-- | Build the WS @lists@ envelope (@{"type": "lists", ...}@) from the
-- current state and push it to every WS subscriber via 'broadcastLists'.
broadcastListsSnapshot :: StreamBroker -> TabsHandle -> SealPaths -> IO ()
broadcastListsSnapshot broker tabsH paths = do
  snap <- buildListsSnapshot tabsH paths
  -- Merge the "type": "lists" tag into the snapshot object so the WS frame
  -- carries the discriminator the frontend's useListsStream dispatches on.
  let snapObj = case A.toJSON snap of
        A.Object o -> o
        other      -> KeyMap.singleton (Key.fromText "snapshot") other
      envelope = A.Object (KeyMap.insert (Key.fromText "type") (A.String "lists") snapObj)
  broadcastLists broker envelope