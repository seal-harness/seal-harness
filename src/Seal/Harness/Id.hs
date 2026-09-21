-- | A UUID-backed durable harness identity (the registry key). Minted at
-- spawn time; stamped as a tmux @seal_id marker on the harness window so a
-- window can be re-identified after a rename or reconnect. The UUID is
-- generated in-repo from 'System.Random' (the repo has @uuid-types@ but
-- not the full @uuid@ package, so v4 generation is hand-rolled from two
-- random 'Word64's with the v4 version/variant bits set).
--
-- This module re-exports the type + pure functions from
-- 'Seal.Gateway.Types.HarnessId' (the canonical home in the
-- 'seal-gateway-types' library stanza). The 'newHarnessId' IO action
-- stays here because it requires 'System.Random' (a server-side concern).
module Seal.Harness.Id
  ( HarnessId (..)
  , newHarnessId
  , parseHarnessId
  , harnessIdToText
  , isValidHarnessIdText
  ) where

import Data.Bits ((.&.), (.|.), complement)
import Data.Text qualified as T
import Data.UUID.Types qualified as U
import Data.Word (Word64)
import System.Random (randomIO)

import Seal.Gateway.Types.HarnessId

-- | Mint a fresh random HarnessId (UUID v4). IO because it reads randomness.
newHarnessId :: IO HarnessId
newHarnessId = do
  w1 <- randomIO
  w2 <- randomIO
  -- Set version (4) in the high nibble of byte 6 (bits 48-51 of w1) and
  -- variant (10) in the high bits of byte 8 (bits 56-57 of w2).
  let v1 = (w1 .&. complement 0x0000F000) .|. (0x4000 :: Word64)   -- version 4
      v2 = (w2 .|. 0x8000000000000000) .&. complement 0x4000000000000000  -- variant 10
  pure (HarnessId (T.pack (U.toString (U.fromWords64 v1 v2))))
