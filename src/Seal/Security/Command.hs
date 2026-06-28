{-# LANGUAGE OverloadedStrings #-}
module Seal.Security.Command
  ( AuthorizedCommand
  , authorizedProgram
  , CommandError (..)
  , authorize
  , authorizeShell
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath (takeFileName)

import Seal.Security.Policy

-- | Proof that a (program, args) pair passed policy. Constructor unexported:
-- the only way to obtain one is 'authorize' or 'authorizeShell', so an
-- executor that demands an 'AuthorizedCommand' cannot be handed an unchecked
-- command.
newtype AuthorizedCommand = AuthorizedCommand (FilePath, [Text])
  deriving stock (Eq, Show)

authorizedProgram :: AuthorizedCommand -> (FilePath, [Text])
authorizedProgram (AuthorizedCommand p) = p

data CommandError
  = CommandNotAllowed Text
  | CommandInAutonomyDeny
  deriving stock (Eq, Show)

authorize :: SecurityPolicy -> FilePath -> [Text] -> Either CommandError AuthorizedCommand
authorize policy program args
  | spAutonomy policy == Deny             = Left CommandInAutonomyDeny
  | isCommandAllowed policy (CommandName base) = Right (AuthorizedCommand (program, args))
  | otherwise                             = Left (CommandNotAllowed base)
  where
    base = T.pack (takeFileName program)

authorizeShell :: SecurityPolicy -> Text -> Either CommandError AuthorizedCommand
authorizeShell policy command
  | spAutonomy policy == Deny                       = Left CommandInAutonomyDeny
  | isCommandAllowed policy (CommandName "shell")   =
      Right (AuthorizedCommand ("/bin/sh", ["-c", command]))
  | otherwise                                       = Left (CommandNotAllowed "shell")
