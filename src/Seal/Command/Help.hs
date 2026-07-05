{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.Help
  ( renderHelpIndex
  , renderHelpFor
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
  ( ParserResult(..)
  , defaultPrefs
  , execParserPure
  , renderFailure
  )

import Seal.Command.Spec
  ( CommandGroup(..)
  , CommandName(..)
  , CommandSpec(..)
  , Registry(..)
  , csGroup
  , csName
  , csParserInfo
  , csSynopsis
  , lookupSpec
  , registrySpecs
  )

-- ---------------------------------------------------------------------------
-- Help index
-- ---------------------------------------------------------------------------

-- | Render the grouped \/help index.
--
-- Output format:
-- @
-- Available commands:
--
--   /help [command]   Show this help, or detailed help for a command
--
-- General
--   /ping             Check connectivity
--
-- Vault
--   /vault            Manage the encrypted secret vault
-- @
--
-- The synthetic @\/help@ entry is always present at the top even though
-- @\/help@ is not a registered 'CommandSpec' (to avoid a registry-knot).
renderHelpIndex :: Registry -> Text
renderHelpIndex reg =
  T.unlines $
    [ "Available commands:"
    , ""
    , syntheticHelpLine
    , ""
    ]
    ++ concatMap renderGroup (Map.toAscList grouped)
  where
    specs   = registrySpecs reg
    -- Group specs preserving original insertion order within each group.
    grouped :: Map CommandGroup [CommandSpec]
    grouped =
      Map.fromListWith (flip (++))
        [(csGroup s, [s]) | s <- specs]

    syntheticHelpLine :: Text
    syntheticHelpLine =
      "  " <> T.justifyLeft colWidth ' ' "/help [command]"
           <> "Show this help, or detailed help for a command"

    renderGroup :: (CommandGroup, [CommandSpec]) -> [Text]
    renderGroup (grp, grpSpecs) =
      [ groupHeader grp ]
      ++ map renderSpec grpSpecs
      ++ [ "" ]

    groupHeader :: CommandGroup -> Text
    groupHeader GroupGeneral  = "General"
    groupHeader GroupProvider = "Providers"
    groupHeader GroupSession  = "Sessions"
    groupHeader GroupModel    = "Model"
    groupHeader GroupVault    = "Vault"
    groupHeader GroupSkills   = "Skills"
    groupHeader GroupAgent    = "Agents"

    renderSpec :: CommandSpec -> Text
    renderSpec s =
      let CommandName n = csName s
          label         = "/" <> n
      in "  " <> T.justifyLeft colWidth ' ' label <> csSynopsis s

    -- Column width for the command label column (includes the leading slash).
    colWidth :: Int
    colWidth = 18

-- ---------------------------------------------------------------------------
-- Per-command help
-- ---------------------------------------------------------------------------

-- | Render a specific command's full optparse help by running its
-- 'ParserInfo' with @["--help"]@ via 'execParserPure'.
--
-- @execParserPure defaultPrefs info ["--help"]@ always returns
-- @Failure (ParserFailure ParserHelp)@ because @--help@ is optparse's
-- built-in action. 'renderFailure' converts that to @(String, ExitCode)@;
-- we take the 'String', pack it to 'Text', and discard the exit code
-- ('ExitSuccess' for @--help@).
--
-- This means the rendered text is 100% derived from the optparse parser
-- and cannot drift from the actual flags the command accepts.
renderHelpFor :: Registry -> CommandName -> Text
renderHelpFor reg name@(CommandName n) =
  case lookupSpec reg name of
    Nothing   -> "No such command: " <> n <> "\n"
    Just spec ->
      case execParserPure defaultPrefs (csParserInfo spec) ["--help"] of
        Failure f ->
          -- progName argument to renderFailure is used as the program name
          -- in the rendered usage line; we use the slash-command name.
          let (msg, _exitCode) = renderFailure f ("/" <> T.unpack n)
          in T.pack msg
        -- The following two branches are unreachable when the input is
        -- ["--help"] against a well-formed ParserInfo, but we must be
        -- total to satisfy -Wall -Werror.
        Success _           -> ""
        CompletionInvoked _ -> ""
