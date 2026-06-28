{-# LANGUAGE OverloadedStrings #-}
module Seal.Types.Command
  ( Command(..)
  , pCommand
  ) where

import Data.Text (Text)

import Configuration.Utils
import Options.Applicative

-- | The subcommand selected on the command line. 'CommandNoOp' is the
-- harmless placeholder carried by 'defaultConfig'; it is not exposed as a
-- subcommand (the only subcommands are @greet@ and @tick@) and is excluded
-- from the config-file 'FromJSON'/'ToJSON' instances.
data Command
  = CommandNoOp
  | CommandGreet !Text
  | CommandTick !Int
  deriving (Eq, Show)

pCommand :: Parser Command
pCommand = hsubparser
  $ command "greet" (info pGreet (progDesc "Greet someone"))
  <> command "tick" (info pTick (progDesc "Increment the tick counter N times"))

pGreet :: Parser Command
pGreet = CommandGreet
  <$> strOption
      ( long "name"
      <> short 'n'
      <> help "Name of the person to greet" )

pTick :: Parser Command
pTick = CommandTick
  <$> option auto
      ( long "count"
      <> short 'c'
      <> metavar "N"
      <> help "Number of times to increment the counter" )