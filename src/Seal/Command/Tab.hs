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
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (saveSessionMeta)
import Seal.Tabs (TabsHandle, insertTabH, removeTabH, renameTabH, focusTabH, snapshotTabs)
import Seal.Tabs.Types (Tab (..), TabList (..), TabRef (..), tabCount)
import Seal.Util.StrictIO (decodeFileStrict)

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
tabCommandSpec :: SealPaths -> TabsHandle -> TabCloseNotifier
               -> IO SessionMeta -> CommandSpec
tabCommandSpec paths h closeNotifier mint = CommandSpec
  { csName         = CommandName "tab"
  , csAliases      = []
  , csGroup        = GroupGeneral
  , csSynopsis     = "Show current tab, or manage tabs (list/new/close/focus/resume/rename)"
  , csParserInfo   = tabParserInfo paths h closeNotifier mint
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

tabParserInfo :: SealPaths -> TabsHandle -> TabCloseNotifier
              -> IO SessionMeta -> ParserInfo CommandAction
tabParserInfo paths h closeNotifier mint =
  info (tabParser paths h closeNotifier mint <**> helper)
    (  progDesc "Manage tabs"
    <> header   "tab — manage tabs (new/list/close/focus/resume/rename)"
    )

tabParser :: SealPaths -> TabsHandle -> TabCloseNotifier
          -> IO SessionMeta -> Parser CommandAction
tabParser paths h closeNotifier mint = hsubparser
  $  command "list"   (info (pure (listCmd paths h))   (progDesc "List all tabs"))
  <> command "new"    (info (newCmd paths h mint <$> optional kindArg)
                                 (progDesc "Create a new tab bound to a fresh session"))
  <> command "close"  (info (closeCmd h closeNotifier <$> tabIndexArg <*> forceFlag)
                                 (progDesc "Close a tab by index (compacts the list)"))
  <> command "focus"  (info (focusCmd h <$> tabIndexArg)
                                 (progDesc "Focus a tab by index"))
  <> command "resume" (info (resumeCmd h <$> sessionArg)
                                 (progDesc "Resume a session into a new tab"))
  <> command "rename" (info (renameCmd h <$> tabIndexArg <*> nameArg)
                                 (progDesc "Rename a tab by index"))
  <> metavar "COMMAND"

-- | The /tab list subcommand. Resolves each tab's display name in priority
-- order: the tab's user-set label, the session's user-set description
-- (the web frontend's chat-header pencil), or the first user message
-- snippet (matching the web frontend's 'sessionDisplayTitle' cascade) for
-- session-backed tabs with no label or description.
listCmd :: SealPaths -> TabsHandle -> CommandAction
listCmd paths h = commandAction $ \caps -> do
  tl <- snapshotTabs h
  if tabCount tl == 0
    then ccSend caps "no tabs"
    else do
      names <- mapM (resolveTabName paths) (tlTabs tl)
      mapM_ (ccSend caps . uncurry renderTabLine) (zip names (tlTabs tl))

-- | Resolve a tab's display name in priority order:
--
-- 1. The tab's user-set label ('tLabel').
-- 2. The session's user-set description ('smDescription') — the web
--    frontend's chat-header pencil.
-- 3. The first user message snippet (for session-backed tabs with no
--    label and no description).
--
-- Returns 'Nothing' when no name is available (no label, no description,
-- no transcript, or a harness tab with no label).
resolveTabName :: SealPaths -> Tab -> IO (Maybe Text)
resolveTabName paths t
  | Just label <- tLabel t = pure (Just label)
  | BoundSession sid <- tRef t = do
      let mp = sessionMetaPath paths sid
      exists <- doesFileExist mp
      if not exists
        then pure Nothing
        else do
          mMeta <- decodeFileStrict mp :: IO (Maybe SessionMeta)
          case mMeta >>= smDescription of
            Just desc -> pure (Just desc)
            Nothing   -> firstUserMessageSnippet paths sid
  | otherwise = pure Nothing

-- | The /tab new subcommand. The kind argument is informational (a provider
-- tab is the only supported kind today; the wizard would be needed for a
-- harness tab).
--
-- The tab is bound to a /real/ session. Ordering matters and mirrors the
-- gateway's 'handleTabNew': mint an /unsaved/ 'SessionMeta', insert the tab,
-- and only then persist. A failed insert (full 36-slot list, or an I2
-- collision) therefore leaves no @session.json@ behind — an orphaned session
-- would otherwise surface in Recent Sessions with no tab to back it.
newCmd :: SealPaths -> TabsHandle -> IO SessionMeta -> Maybe Text -> CommandAction
newCmd paths h mint _mKind = commandAction $ \caps -> do
  meta <- mint
  r <- insertTabH h (BoundSession (smId meta)) KindProvider Nothing
  case r of
    Left e  -> ccSend caps ("tab new failed: " <> e)
    Right i -> do
      saveSessionMeta paths meta
      ccSend caps ("tab " <> T.singleton (tabIndexToChar i) <> " created")

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
        Right i -> ccSend caps ("tab " <> T.singleton (tabIndexToChar i) <> " resumed")

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

-- | One line per tab for /tab list. The display name (label, session
-- description, or snippet) is resolved by 'resolveTabName' and passed as
-- 'mName'. The tab kind is intentionally not shown — its constructor
-- names (e.g. @KindProvider@) carry no useful information for the user.
renderTabLine :: Maybe Text -> Tab -> Text
renderTabLine mName t =
  T.singleton (tabIndexToChar (tIndex t)) <> "  "
    <> maybe "" ("  " <>) mName
    <> "  " <> refText (tRef t)
  where
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
