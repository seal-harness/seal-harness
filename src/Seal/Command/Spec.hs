module Seal.Command.Spec
  ( CommandName(..)
  , CommandGroup(..)
  , Availability(..)
  , CommandAction(..)
  , CommandSpec(..)
  , Registry(..)
  , mkRegistry
  , lookupSpec
  , runCommandActionMaybe
  , commandAction
  ) where

import Control.Monad (void)
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
  | GroupTools
  | GroupRepos
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data Availability
  = AlwaysAvailable
  | InteractiveOnly
  deriving stock (Eq, Show)

-- | The runnable action a successfully-parsed command performs on its channel.
-- Returns an optional follow-up turn text: 'Nothing' for commands that do not
-- trigger a turn (the vast majority); @'Just' t@ when the command wants the
-- agent loop to run a turn with text @t@ immediately after the command
-- completes (e.g. @\/skill load@ after writing the skill body to
-- @conversation.jsonl@). The follow-up turn is forked by each channel's
-- dispatch site so the channel loop continues reading input while the LLM
-- runs.
newtype CommandAction = CommandAction { runCommandAction :: ChannelCaps -> IO (Maybe Text) }

-- | Construct a 'CommandAction' from an @IO ()@ action that never triggers a
-- follow-up turn. This is the common case — most commands produce output via
-- 'ccSend' and return 'Nothing'. Commands that DO want to trigger a turn
-- (e.g. @\/skill load@) construct 'CommandAction' directly and return
-- @'Just' text@.
commandAction :: (ChannelCaps -> IO ()) -> CommandAction
commandAction act = CommandAction (\caps -> void (act caps) >> pure Nothing)

-- | Run a 'CommandAction' and return the optional follow-up-turn signal.
-- Convenience alias for 'runCommandAction'.
runCommandActionMaybe :: CommandAction -> ChannelCaps -> IO (Maybe Text)
runCommandActionMaybe = runCommandAction

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