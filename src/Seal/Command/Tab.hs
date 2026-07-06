{-# LANGUAGE OverloadedStrings #-}
-- | The @/tab@ + @/tabs@ command family. Registered into the existing
-- @\/@-command registry so both the CLI TUI and the Signal channel gain
-- @\/tabs@ and @\/tab@ driving. Plus the terse-grammar synopsis entry for
-- @\/help@.
module Seal.Command.Tab
  ( tabCommandSpec
  , tabsCommandSpec
  , terseGrammarSpec
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Core.Types (mkSessionId, sessionIdText)
import Seal.Handles.Tab (mkTabIndex, TabKind (..), tabIndexToChar)
import Seal.Routing.Route (terseSynopsis)
import Seal.Tabs (TabsHandle, insertTabH, removeTabH, renameTabH, focusTabH, snapshotTabs)
import Seal.Tabs.Types (Tab (..), TabList (..), TabRef (..), tabCount)

-- | The @/tab@ command spec (one hsubparser with the six subcommands).
tabCommandSpec :: TabsHandle -> CommandSpec
tabCommandSpec h = CommandSpec
  { csName         = CommandName "tab"
  , csAliases      = [CommandName "tabs"]  -- /tabs is an alias for /tab list
  , csGroup        = GroupGeneral
  , csSynopsis     = "Manage tabs (new/list/close/focus/resume/rename)"
  , csParserInfo   = tabParserInfo h
  , csAvailability = AlwaysAvailable
  }

-- | The @/tabs@ alias spec. (An explicit alias entry so @/help@ shows it
-- distinctly; @/tab@ already lists @tabs@ as an alias, so this is redundant
-- but harmless — the registry's lookup-by-alias handles both.)
tabsCommandSpec :: TabsHandle -> CommandSpec
tabsCommandSpec h = (tabCommandSpec h)
  { csName     = CommandName "tabs"
  , csAliases  = []
  , csSynopsis = "List tabs (alias for /tab list)"
  }

-- | The terse-grammar synopsis entry for @/help@. A synthetic spec (no
-- parser — it's handled by 'Seal.Routing.Route' before the registry); the
-- synopsis is registered so @/help@ shows the @/N@ grammar.
terseGrammarSpec :: CommandSpec
terseGrammarSpec = CommandSpec
  { csName         = CommandName "N"
  , csAliases      = []
  , csGroup        = GroupGeneral
  , csSynopsis     = terseSynopsis
  , csParserInfo   = info (pure (CommandAction (const (pure ())))) (progDesc "Terse tab switching")
  , csAvailability = AlwaysAvailable
  }

tabParserInfo :: TabsHandle -> ParserInfo CommandAction
tabParserInfo h =
  info (tabParser h <**> helper)
    (  progDesc "Manage tabs"
    <> header   "tab — manage tabs (new/list/close/focus/resume/rename)"
    )

tabParser :: TabsHandle -> Parser CommandAction
tabParser h = hsubparser
  $  command "list"   (info (pure (listCmd h))   (progDesc "List all tabs"))
  <> command "new"    (info (newCmd h <$> optional kindArg)
                                 (progDesc "Create a new tab (default kind: ai)"))
  <> command "close"  (info (closeCmd h <$> tabIndexArg <*> forceFlag)
                                 (progDesc "Close a tab by index (compacts the list)"))
  <> command "focus"  (info (focusCmd h <$> tabIndexArg)
                                 (progDesc "Focus a tab by index"))
  <> command "resume" (info (resumeCmd h <$> sessionArg)
                                 (progDesc "Resume a session into a new tab"))
  <> command "rename" (info (renameCmd h <$> tabIndexArg <*> nameArg)
                                 (progDesc "Rename a tab by index"))
  <> metavar "COMMAND"

-- | The /tab list subcommand.
listCmd :: TabsHandle -> CommandAction
listCmd h = CommandAction $ \caps -> do
  tl <- snapshotTabs h
  if tabCount tl == 0
    then ccSend caps "no tabs"
    else mapM_ (ccSend caps . renderTabLine) (tlTabs tl)

-- | The /tab new subcommand. (For 6b the kind is informational; a session
-- tab is the default. A harness tab needs the wizard — deferred.)
newCmd :: TabsHandle -> Maybe Text -> CommandAction
newCmd h _mKind = CommandAction $ \caps -> do
  let ref = BoundSession placeholder
  r <- insertTabH h ref KindAi Nothing
  case r of
    Left e  -> ccSend caps ("tab new failed: " <> e)
    Right i -> ccSend caps ("tab " <> T.singleton (tabIndexToChar i) <> " created")
  where
    placeholder = case mkSessionId "tab-session" of
      Right s -> s
      Left _  -> error "placeholder session id"

-- | The /tab close subcommand.
closeCmd :: TabsHandle -> Int -> Bool -> CommandAction
closeCmd h idx force = CommandAction $ \caps -> do
  case mkTabIndex idx of
    Left e  -> ccSend caps ("invalid index: " <> e)
    Right i -> do
      r <- removeTabH h i
      case r of
        Left e  -> if force then ccSend caps ("force close: " <> e) else ccSend caps ("close failed: " <> e)
        Right _ -> ccSend caps ("tab " <> T.singleton (tabIndexToChar i) <> " closed")

-- | The /tab focus subcommand.
focusCmd :: TabsHandle -> Int -> CommandAction
focusCmd h idx = CommandAction $ \caps -> do
  case mkTabIndex idx of
    Left e  -> ccSend caps ("invalid index: " <> e)
    Right i -> do
      r <- focusTabH h i
      case r of
        Left e  -> ccSend caps ("focus failed: " <> e)
        Right _ -> ccSend caps ("focused tab " <> T.singleton (tabIndexToChar i))

-- | The /tab resume subcommand.
resumeCmd :: TabsHandle -> Text -> CommandAction
resumeCmd h sidText = CommandAction $ \caps -> do
  case mkSessionId sidText of
    Left e  -> ccSend caps ("invalid session id: " <> e)
    Right s -> do
      r <- insertTabH h (BoundSession s) KindAi Nothing
      case r of
        Left e  -> ccSend caps ("resume failed: " <> e)
        Right i -> ccSend caps ("tab " <> T.singleton (tabIndexToChar i) <> " resumed " <> sessionIdText s)

-- | The /tab rename subcommand.
renameCmd :: TabsHandle -> Int -> Text -> CommandAction
renameCmd h idx name = CommandAction $ \caps -> do
  case mkTabIndex idx of
    Left e  -> ccSend caps ("invalid index: " <> e)
    Right i -> do
      r <- renameTabH h i name
      case r of
        Left e  -> ccSend caps ("rename failed: " <> e)
        Right _ -> ccSend caps ("tab " <> T.singleton (tabIndexToChar i) <> " renamed to " <> name)

-- | One line per tab for /tab list.
renderTabLine :: Tab -> Text
renderTabLine t =
  T.singleton (tabIndexToChar (tIndex t)) <> "  " <> kindText (tKind t)
    <> maybe "" ("  " <>) (tLabel t)
    <> "  " <> refText (tRef t)
  where
    kindText = T.pack . show
    refText (BoundSession s)  = "session:" <> sessionIdText s
    refText (BoundHarness _)  = "harness:<id>"

-- ---------------------------------------------------------------------------
-- optparse helpers
-- ---------------------------------------------------------------------------

kindArg :: Parser Text
kindArg = strArgument (metavar "KIND" <> help "Tab kind (ai|provider|harness|shell|ssh|tmux)")

tabIndexArg :: Parser Int
tabIndexArg = argument auto (metavar "N" <> help "Tab index (0-35)")

sessionArg :: Parser Text
sessionArg = strArgument (metavar "SESSION_ID" <> help "Session id to resume")

nameArg :: Parser Text
nameArg = strArgument (metavar "NAME" <> help "New tab name")

forceFlag :: Parser Bool
forceFlag = switch (long "force" <> help "Force the operation even if it would fail")