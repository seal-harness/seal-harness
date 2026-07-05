module Seal.Command.Spec
  ( CommandName(..)
  , CommandGroup(..)
  , Availability(..)
  , CommandAction(..)
  , CommandSpec(..)
  , Registry(..)
  , mkRegistry
  , lookupSpec
  ) where

import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import Options.Applicative (ParserInfo)

import Seal.Channel.Caps (ChannelCaps)

newtype CommandName = CommandName Text
  deriving stock (Eq, Ord, Show)

data CommandGroup
  = GroupGeneral
  | GroupProvider
  | GroupSession
  | GroupModel
  | GroupVault
  | GroupSkills
  | GroupAgent
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data Availability
  = AlwaysAvailable
  | InteractiveOnly
  deriving stock (Eq, Show)

-- | The runnable action a successfully-parsed command performs on its channel.
newtype CommandAction = CommandAction { runCommandAction :: ChannelCaps -> IO () }

data CommandSpec = CommandSpec
  { csName :: CommandName
  , csAliases :: [CommandName]
  , csGroup :: CommandGroup
  , csSynopsis :: Text              -- ^ One line for /help index
  , csParserInfo :: ParserInfo CommandAction
  , csAvailability :: Availability
  }

-- | NOTE: /help is NOT a registered spec — it is a meta-operation handled by
-- Seal.Command.Help / Seal.Command.Parse over the Registry (avoids the
-- registry-needs-itself knot). Feature modules build their own CommandSpec
-- and the startup wiring assembles the Registry.
newtype Registry = Registry { registrySpecs :: [CommandSpec] }

mkRegistry :: [CommandSpec] -> Registry
mkRegistry = Registry

-- | Case-insensitive lookup by primary name or any alias.
lookupSpec :: Registry -> CommandName -> Maybe CommandSpec
lookupSpec (Registry specs) (CommandName needle) =
  find matchesAny specs
  where
    lower = T.toCaseFold needle
    nameEq (CommandName n) = T.toCaseFold n == lower
    matchesAny spec = nameEq (csName spec) || any nameEq (csAliases spec)
