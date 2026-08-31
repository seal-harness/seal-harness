{-# LANGUAGE OverloadedStrings #-}
-- | The @/tab@ command family. Registered into the existing @\/@-command
-- registry so both the CLI TUI and the chat channels gain @\/tab@ driving.
-- Plus the terse-grammar synopsis entry for @\/help@.
module Seal.Command.Tab
  ( tabCommandSpec
  , TabCloseNotifier
  , noTabCloseNotifier
  , terseGrammarSpec
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
import System.Directory (doesFileExist)

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..), commandAction
  , CommandName (..), CommandSpec (..) )
import Seal.Config.Paths (SealPaths, sessionMetaPath)
import Seal.Core.Types (mkSessionId, sessionIdText)
import Seal.Gateway.Transcript (firstUserMessageSnippet)
import Seal.Handles.Tab (mkTabIndex, TabIndex, TabKind (..), tabIndexToChar)
import Seal.Routing.Route (terseSynopsis)
import Seal.Tabs (TabsHandle, insertTabH, removeTabH, renameTabH, focusTabH, snapshotTabs)
import Seal.Tabs.Types (Tab (..), TabList (..), TabRef (..), tabCount)

-- | A hook invoked after a tab is successfully closed. The 'TabRef' is the
-- closed tab's backing ref (e.g. @BoundSession sid@). Wiring sites build
-- this from the 'CursorStore' + 'ReplyRegistry' so conversations attached
-- to the closed tab are notified. The no-op identity is 'noTabCloseNotifier'
-- (used by tests + the standalone CLI which has no other channels).
type TabCloseNotifier = TabRef -> IO ()

-- | The identity 'TabCloseNotifier' — does nothing. Used when there are no
-- other channels to notify (tests, standalone CLI).
noTabCloseNotifier :: TabCloseNotifier
noTabCloseNotifier _ = pure ()

-- | The @/tab@ command spec. Bare @/tab@ is intercepted by
-- 'Seal.Routing.Route' as 'CurrentTab' (show the focused tab) BEFORE the
-- registry is consulted, so this spec's parser only runs when a subcommand
-- is present (@/tab list@, @/tab new@, etc.).
tabCommandSpec :: SealPaths -> TabsHandle -> TabCloseNotifier -> CommandSpec
tabCommandSpec paths h closeNotifier = CommandSpec
  { csName         = CommandName "tab"
  , csAliases      = []
  , csGroup        = GroupGeneral
  , csSynopsis     = "Show current tab, or manage tabs (list/new/close/focus/resume/rename)"
  , csParserInfo   = tabParserInfo paths h closeNotifier
  , csAvailability = AlwaysAvailable
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
  , csParserInfo   = info (pure (commandAction (const (pure ())))) (progDesc "Terse tab switching")
  , csAvailability = AlwaysAvailable
  }

tabParserInfo :: SealPaths -> TabsHandle -> TabCloseNotifier -> ParserInfo CommandAction
tabParserInfo paths h closeNotifier =
  info (tabParser paths h closeNotifier <**> helper)
    (  progDesc "Manage tabs"
    <> header   "tab — manage tabs (new/list/close/focus/resume/rename)"
    )

tabParser :: SealPaths -> TabsHandle -> TabCloseNotifier -> Parser CommandAction
tabParser paths h closeNotifier = hsubparser
  $  command "list"   (info (pure (listCmd paths h))   (progDesc "List all tabs"))
  <> command "new"    (info (newCmd h <$> optional kindArg)
                                 (progDesc "Create a new tab (default kind: ai)"))
  <> command "close"  (info (closeCmd h closeNotifier <$> tabIndexArg <*> forceFlag)
                                 (progDesc "Close a tab by index (compacts the list)"))
  <> command "focus"  (info (focusCmd h <$> tabIndexArg)
                                 (progDesc "Focus a tab by index"))
  <> command "resume" (info (resumeCmd h <$> sessionArg)
                                 (progDesc "Resume a session into a new tab"))
  <> command "rename" (info (renameCmd h <$> tabIndexArg <*> nameArg)
                                 (progDesc "Rename a tab by index"))
  <> metavar "COMMAND"

-- | The /tab list subcommand. Resolves each tab's display name: the
-- user-set label (if any), or the first user message snippet (matching
-- the web frontend's 'sessionDisplayTitle' cascade) for session-backed
-- tabs with no label.
listCmd :: SealPaths -> TabsHandle -> CommandAction
listCmd paths h = commandAction $ \caps -> do
  tl <- snapshotTabs h
  if tabCount tl == 0
    then ccSend caps "no tabs"
    else do
      names <- mapM (resolveTabName paths) (tlTabs tl)
      mapM_ (ccSend caps . uncurry renderTabLine) (zip names (tlTabs tl))

-- | Resolve a tab's display name. Returns 'Nothing' when no name is
-- available (no label, no transcript, or a harness tab with no label).
resolveTabName :: SealPaths -> Tab -> IO (Maybe Text)
resolveTabName paths t
  | Just label <- tLabel t = pure (Just label)
  | BoundSession sid <- tRef t = do
      let mp = sessionMetaPath paths sid
      exists <- doesFileExist mp
      if not exists
        then pure Nothing
        else firstUserMessageSnippet paths sid
  | otherwise = pure Nothing

-- | The /tab new subcommand. (For 6b the kind is informational; a session
-- tab is the default. A harness tab needs the wizard — deferred.)
newCmd :: TabsHandle -> Maybe Text -> CommandAction
newCmd h _mKind = commandAction $ \caps -> do
  let ref = BoundSession placeholder
  r <- insertTabH h ref KindAi Nothing
  case r of
    Left e  -> ccSend caps ("tab new failed: " <> e)
    Right i -> ccSend caps ("tab " <> T.singleton (tabIndexToChar i) <> " created")
  where
    placeholder = case mkSessionId "tab-session" of
      Right s -> s
      Left _  -> error "placeholder session id"

-- | The /tab close subcommand. Snapshots the tab's 'TabRef' before removing
-- it so the close notifier can tell attached channels which tab was closed.
closeCmd :: TabsHandle -> TabCloseNotifier -> Int -> Bool -> CommandAction
closeCmd h closeNotifier idx force = commandAction $ \caps -> do
  case mkTabIndex idx of
    Left e  -> ccSend caps ("invalid index: " <> e)
    Right i -> do
      mRef <- tabRefAtIndex h i
      r <- removeTabH h i
      case r of
        Left e  -> if force then ccSend caps ("force close: " <> e) else ccSend caps ("close failed: " <> e)
        Right _ -> do
          ccSend caps ("tab " <> T.singleton (tabIndexToChar i) <> " closed")
          maybe (pure ()) closeNotifier mRef

-- | Look up the 'TabRef' at a tab index ('Nothing' if out of range).
tabRefAtIndex :: TabsHandle -> Seal.Handles.Tab.TabIndex -> IO (Maybe TabRef)
tabRefAtIndex h i = do
  tl <- snapshotTabs h
  pure (tRef <$> lookupTab tl i)
  where
    lookupTab tl idx = go (tlTabs tl)
      where
        go [] = Nothing
        go (t:rest) | tIndex t == idx = Just t
                    | otherwise       = go rest

-- | The /tab focus subcommand.
focusCmd :: TabsHandle -> Int -> CommandAction
focusCmd h idx = commandAction $ \caps -> do
  case mkTabIndex idx of
    Left e  -> ccSend caps ("invalid index: " <> e)
    Right i -> do
      r <- focusTabH h i
      case r of
        Left e  -> ccSend caps ("focus failed: " <> e)
        Right _ -> ccSend caps ("focused tab " <> T.singleton (tabIndexToChar i))

-- | The /tab resume subcommand.
resumeCmd :: TabsHandle -> Text -> CommandAction
resumeCmd h sidText = commandAction $ \caps -> do
  case mkSessionId sidText of
    Left e  -> ccSend caps ("invalid session id: " <> e)
    Right s -> do
      r <- insertTabH h (BoundSession s) KindAi Nothing
      case r of
        Left e  -> ccSend caps ("resume failed: " <> e)
        Right i -> ccSend caps ("tab " <> T.singleton (tabIndexToChar i) <> " resumed " <> sessionIdText s)

-- | The /tab rename subcommand.
renameCmd :: TabsHandle -> Int -> Text -> CommandAction
renameCmd h idx name = commandAction $ \caps -> do
  case mkTabIndex idx of
    Left e  -> ccSend caps ("invalid index: " <> e)
    Right i -> do
      r <- renameTabH h i name
      case r of
        Left e  -> ccSend caps ("rename failed: " <> e)
        Right _ -> ccSend caps ("tab " <> T.singleton (tabIndexToChar i) <> " renamed to " <> name)

-- | One line per tab for /tab list. The display name (label or snippet) is
-- resolved by 'resolveTabName' and passed as 'mName'.
renderTabLine :: Maybe Text -> Tab -> Text
renderTabLine mName t =
  T.singleton (tabIndexToChar (tIndex t)) <> "  " <> kindText (tKind t)
    <> maybe "" ("  " <>) mName
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
