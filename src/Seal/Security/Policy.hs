module Seal.Security.Policy
  ( CommandName (..)
  , AllowList (..)
  , AutonomyLevel (..)
  , SecurityPolicy (..)
  , defaultPolicy
  , isCommandAllowed
  ) where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)

newtype CommandName = CommandName Text
  deriving stock (Eq, Ord, Show)

data AllowList a = AllowAll | AllowOnly (Set a)
  deriving stock (Eq, Show)

data AutonomyLevel = Full | Supervised | Deny
  deriving stock (Eq, Show)

data SecurityPolicy = SecurityPolicy
  { spAllowedCommands :: AllowList CommandName
  , spAutonomy :: AutonomyLevel
  } deriving stock (Eq, Show)

-- | Deny everything: the safe default a config must explicitly widen.
defaultPolicy :: SecurityPolicy
defaultPolicy = SecurityPolicy (AllowOnly Set.empty) Deny

isCommandAllowed :: SecurityPolicy -> CommandName -> Bool
isCommandAllowed p name = case spAllowedCommands p of
  AllowAll      -> True
  AllowOnly set -> name `Set.member` set
