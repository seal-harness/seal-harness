module Seal.Types.Command
  ( Command(..)
  , pCommand
  ) where

import Options.Applicative

-- | The subcommand selected on the command line. 'CommandNoOp' is the
-- harmless placeholder carried by 'defaultConfig'; it is not exposed as a
-- subcommand (the subcommands are @tui@ and @signal@) and is excluded from
-- the config-file 'FromJSON'/'ToJSON' instances.
data Command
  = CommandNoOp
  | CommandTui
  | CommandSignal
  deriving (Eq, Show)

pCommand :: Parser Command
pCommand = hsubparser
  $  command "tui" (info (pure CommandTui)
                         (progDesc "Start the interactive terminal UI (TUI)"))
  <> command "signal" (info (pure CommandSignal)
                            (progDesc "Run the agent over the Signal channel"))
