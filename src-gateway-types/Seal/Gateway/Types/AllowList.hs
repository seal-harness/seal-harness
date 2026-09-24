{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
-- | The reusable allow-list family used by sender allow-listing (channels)
-- and opcode-exposure gating (agent defs). Extracted from
-- 'Seal.Security.Policy' so the cross-channel layer can depend on this leaf
-- without pulling in the whole security policy.
--
-- Canonical home; 'Seal.Core.AllowList' in the server re-exports from here.
module Seal.Gateway.Types.AllowList
  ( AllowList (..)
  , isAllowed
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Set (Set)
import Data.Set qualified as Set
import GHC.Generics (Generic)

-- | An allow-list: either admit everything ('AllowAll') or only the given
-- set ('AllowOnly').
data AllowList a = AllowAll | AllowOnly (Set a)
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Membership test.
isAllowed :: Ord a => a -> AllowList a -> Bool
isAllowed _ AllowAll      = True
isAllowed x (AllowOnly s) = x `Set.member` s