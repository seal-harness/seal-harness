module Seal.Types.Command
  ( Command(..)
  , pCommand
  ) where

import Options.Applicative

import Seal.Security.Policy (AutonomyLevel (..))

-- | The subcommand selected on the command line. 'CommandNoOp' is the
-- harmless placeholder carried by 'defaultConfig'; it is not exposed as a
-- subcommand (the subcommands are @tui@, @signal@, and @serve@) and is
-- excluded from the config-file 'FromJSON'/'ToJSON' instances.
-- Each subcommand carries the autonomy level selected via @--yolo@
-- ('Full' — bypass the human-confirmation gate) vs the default
-- ('Supervised' — prompt before running any Untrusted opcode).
data Command
  = CommandNoOp
  | CommandTui AutonomyLevel
  | CommandSignal AutonomyLevel
  | CommandTelegram AutonomyLevel
  | CommandServe AutonomyLevel
  deriving (Eq, Show)

pCommand :: Parser Command
pCommand = hsubparser
  $  command "tui" (info (CommandTui <$> pAutonomy)
                         (progDesc "Start the interactive terminal UI (TUI)"))
  <> command "signal" (info (CommandSignal <$> pAutonomy)
                            (progDesc "Run the agent over the Signal channel"))
  <> command "telegram" (info (CommandTelegram <$> pAutonomy)
                              (progDesc "Run the agent over the Telegram channel"))
  <> command "serve" (info (CommandServe <$> pAutonomy)
                           (progDesc "Run the web gateway server"))

-- | @--yolo@ sets 'Full' autonomy (bypass the untrusted-opcode approval
-- gate); absent defaults to 'Supervised'.
pAutonomy :: Parser AutonomyLevel
pAutonomy = flag Supervised Full
  ( long "yolo"
  <> help "Bypass the approval gate so untrusted opcodes run without prompting (ACK audit still recorded)"
  )
