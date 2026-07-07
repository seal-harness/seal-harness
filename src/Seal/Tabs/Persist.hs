{-# LANGUAGE OverloadedStrings #-}
-- | Tab list persistence — the 'TabList' survives a restart; tabs are
-- re-resolved to their 'TabRef's at boot. **Stub for 6b** (persistence is a
-- follow-up that needs the session store + a boot-time re-resolve pass);
-- the module ships so the wiring compiles. Both functions are no-ops.
module Seal.Tabs.Persist
  ( saveTabList
  , loadTabList
  ) where

import Seal.Tabs (TabsHandle)
import Seal.Tabs.Types (TabList)

-- | Save the tab list to disk (stub — no-op in 6b).
saveTabList :: TabsHandle -> IO ()
saveTabList _h = pure ()

-- | Load the tab list from disk at boot (stub — returns 'Nothing' in 6b).
loadTabList :: IO (Maybe TabList)
loadTabList = pure Nothing