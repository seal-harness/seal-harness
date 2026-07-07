-- | The per-tab runtime wiring: a session tab runs the agent loop, a harness
-- tab drives the harness handle. **Stub for 6b** (the per-tab runtime is the
-- 7a gateway's job; 6b delivers the view + the commands, not the live
-- per-tab execution). The module ships so the wiring compiles.
module Seal.Tabs.Runtimes
  ( TabRuntime (..)
  , runSessionTab
  , runHarnessTab
  ) where

import Data.Text (Text)

import Seal.Tabs (TabsHandle)

-- | A per-tab runtime (stub). The real runtime (7a) holds the agent loop
-- for a session tab or the harness handle for a harness tab.
data TabRuntime = TabRuntime  -- stub

-- | Run one turn against a session tab (stub — no-op in 6b).
runSessionTab :: TabsHandle -> Text -> IO ()
runSessionTab _h _input = pure ()

-- | Send input to a harness tab (stub — no-op in 6b).
runHarnessTab :: TabsHandle -> Text -> IO ()
runHarnessTab _h _input = pure ()