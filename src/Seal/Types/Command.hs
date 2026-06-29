module Seal.Types.Command
  ( Command(..)
  , pCommand
  ) where

import Options.Applicative

-- | The subcommand selected on the command line. 'CommandNoOp' is the
-- harmless placeholder carried by 'defaultConfig'; it is not exposed as a
-- subcommand (the only subcommand is @repl@) and is excluded from the
-- config-file 'FromJSON'/'ToJSON' instances.
data Command
  = CommandNoOp
  | CommandRepl
  deriving (Eq, Show)

pCommand :: Parser Command
pCommand = hsubparser
  $ command "repl" (info (pure CommandRepl)
                         (progDesc "Start the interactive REPL"))
