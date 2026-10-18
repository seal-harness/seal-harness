module Seal.Types.Command
  ( Command(..)
  , pCommand
  ) where

import Options.Applicative

import Seal.Security.Policy (AutonomyLevel (..))

-- | The subcommand selected on the command line. 'CommandNoOp' is the
-- harmless placeholder carried by 'defaultConfig'; it is not exposed as a
-- subcommand (the subcommands are @tui@ and @serve@) and is excluded from
-- the config-file 'FromJSON'/'ToJSON' instances.
-- Each subcommand carries the autonomy level selected via @--yolo@
-- ('Full' — bypass the human-confirmation gate) vs the default
-- ('Supervised' — prompt before running any Untrusted opcode).
data Command
  = CommandNoOp
  | CommandTui AutonomyLevel
  | CommandServe AutonomyLevel (Maybe FilePath)
  | CommandGenOpenApi
  deriving (Eq, Show)

pCommand :: Parser Command
pCommand = hsubparser
  $  command "tui" (info (CommandTui <$> pAutonomy)
                         (progDesc "Start the interactive terminal UI (TUI)"))
  <> command "serve" (info (CommandServe <$> pAutonomy <*> pStaticDir)
                            (progDesc "Run the web gateway server"))
  <> command "gen-openapi" (info (pure CommandGenOpenApi)
                                  (progDesc "Print the OpenAPI 3.1 spec (JSON) to stdout"))

-- | @--yolo@ sets 'Full' autonomy (bypass the untrusted-opcode approval
-- gate); absent defaults to 'Supervised'.
pAutonomy :: Parser AutonomyLevel
pAutonomy = flag Supervised Full
  ( long "yolo"
  <> help "Bypass the approval gate so untrusted opcodes run without prompting (ACK audit still recorded)"
  )

-- | @--static-dir DIR@ overrides the @[gateway] static_dir@ from TOML config,
-- serving UI assets from DIR instead of the embedded bundle (dev mode).
-- Absent = @Nothing@ (use TOML config or embedded default).
pStaticDir :: Parser (Maybe FilePath)
pStaticDir = optional (strOption
  ( long "static-dir"
  <> metavar "DIR"
  <> help "Serve static UI assets from DIR instead of the embedded bundle (dev mode)"
  ))
