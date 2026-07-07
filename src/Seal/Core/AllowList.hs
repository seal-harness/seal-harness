-- | The reusable allow-list family used by sender allow-listing (channels)
-- and opcode-exposure gating (agent defs). Extracted from
-- 'Seal.Security.Policy' so the cross-channel layer can depend on this leaf
-- without pulling in the whole security policy.
module Seal.Core.AllowList
  ( AllowList (..)
  , isAllowed
  ) where

import Data.Set (Set)
import Data.Set qualified as Set

-- | An allow-list: either admit everything ('AllowAll') or only the given
-- set ('AllowOnly').
data AllowList a = AllowAll | AllowOnly (Set a)
  deriving stock (Eq, Show)

-- | Membership test.
isAllowed :: Ord a => a -> AllowList a -> Bool
isAllowed _ AllowAll      = True
isAllowed x (AllowOnly s) = x `Set.member` s