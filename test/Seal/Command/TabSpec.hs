{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.TabSpec (spec) where

import Control.Monad (void)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Test.Hspec
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

import Seal.Channel.Caps (ChannelCaps (..))
import Data.Default (def)
import Seal.Command.Help (renderHelpIndex)
import Seal.Command.Parse (parseSlash, ParseOutcome (..))
import Seal.Command.Spec (CommandAction(..), mkRegistry)
import Seal.Command.Tab (tabCommandSpec, noTabCloseNotifier, terseGrammarSpec, TabCloseNotifier)
import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (mkSessionId, SessionId)
import Seal.Handles.Tab (tabIndexToChar, TabKind(..), mkTabIndex, TabIndex)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (saveSessionMeta)
import Seal.Tabs (insertTabH, newTabsHandle, snapshotTabs)
import Seal.Tabs.Types (Tab (..), TabList(..), TabRef(..), tabCount)

-- | A recording ChannelCaps.
recordingCaps :: IO (IORef [Text], ChannelCaps)
recordingCaps = do
  ref <- newIORef []
  pure (ref, def
    { ccSend = \t -> modifyIORef' ref (t :)
    , ccPrompt = \_ -> pure ""
    , ccPromptSecret = \_ -> pure ""
  , ccStreaming    = True  -- tests: streaming by default
    })

-- | A dummy SealPaths for tests that don't need real session resolution.
dummyPaths :: FilePath -> SealPaths
dummyPaths tmp = SealPaths
  { spHome = tmp, spConfig = tmp </> "config", spState = tmp </> "state"
  , spKeys = tmp </> "keys", spCache = tmp </> "cache" }

spec :: Spec
spec = describe "Seal.Command.Tab" $ do
  it "/tab list on an empty handle replies 'no tabs'" $
    withSystemTempDirectory "seal-tab" $ \tmp -> do
      h <- newTabsHandle
      let paths = dummyPaths tmp
          reg = mkRegistry [tabCommandSpec paths h noTabCloseNotifier]
      (ref, caps) <- recordingCaps
      case parseSlash reg "/tab list" of
        ParsedAction act -> runCommand act caps
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)
      sent <- readIORef ref
      sent `shouldSatisfy` ("no tabs" `elem`)

  it "/tab new creates a tab and replies with 'created'" $
    withSystemTempDirectory "seal-tab" $ \tmp -> do
      h <- newTabsHandle
      let paths = dummyPaths tmp
          reg = mkRegistry [tabCommandSpec paths h noTabCloseNotifier]
      (ref, caps) <- recordingCaps
      case parseSlash reg "/tab new" of
        ParsedAction act -> runCommand act caps
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)
      sent <- readIORef ref
      sent `shouldSatisfy` any ("created" `T.isInfixOf`)
      -- the handle now has one tab
      snap <- snapshotTabs h
      tabCount snap `shouldBe` 1

  it "/tab list after /tab new shows one tab" $
    withSystemTempDirectory "seal-tab" $ \tmp -> do
      h <- newTabsHandle
      let paths = dummyPaths tmp
          reg = mkRegistry [tabCommandSpec paths h noTabCloseNotifier]
      (ref, caps) <- recordingCaps
      case parseSlash reg "/tab new" of
        ParsedAction act -> runCommand act caps
        _ -> pure ()
      case parseSlash reg "/tab list" of
        ParsedAction act -> runCommand act caps
        _ -> pure ()
      sent <- readIORef ref
      snap <- snapshotTabs h
      case tlTabs snap of
        (t:_) -> sent `shouldSatisfy` any (T.singleton (tabIndexToChar (tIndex t)) `T.isInfixOf`)
        []    -> expectationFailure "expected at least one tab"

  it "/tab close 0 closes the first tab" $
    withSystemTempDirectory "seal-tab" $ \tmp -> do
      h <- newTabsHandle
      let paths = dummyPaths tmp
          reg = mkRegistry [tabCommandSpec paths h noTabCloseNotifier]
      (ref, caps) <- recordingCaps
      _ <- insertTabH h (BoundSession (mkSid "a")) KindAi Nothing
      case parseSlash reg "/tab close 0" of
        ParsedAction act -> runCommand act caps
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)
      sent <- readIORef ref
      sent `shouldSatisfy` any ("closed" `T.isInfixOf`)
      snap <- snapshotTabs h
      tabCount snap `shouldBe` 0

  it "/tab close invokes the TabCloseNotifier with the closed tab's TabRef" $
    withSystemTempDirectory "seal-tab" $ \tmp -> do
      h <- newTabsHandle
      notifiedRef <- newIORef ([] :: [TabRef])
      let notifier :: TabCloseNotifier
          notifier r = modifyIORef' notifiedRef (r :)
          paths = dummyPaths tmp
          reg = mkRegistry [tabCommandSpec paths h notifier]
      (ref, caps) <- recordingCaps
      let sid = mkSid "close-notify"
      _ <- insertTabH h (BoundSession sid) KindAi Nothing
      case parseSlash reg "/tab close 0" of
        ParsedAction act -> runCommand act caps
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)
      notified <- readIORef notifiedRef
      notified `shouldBe` [BoundSession sid]
      sent <- readIORef ref
      sent `shouldSatisfy` any ("closed" `T.isInfixOf`)

  it "/tab rename 0 work sets the label" $
    withSystemTempDirectory "seal-tab" $ \tmp -> do
      h <- newTabsHandle
      let paths = dummyPaths tmp
          reg = mkRegistry [tabCommandSpec paths h noTabCloseNotifier]
      (ref, caps) <- recordingCaps
      _ <- insertTabH h (BoundSession (mkSid "a")) KindAi Nothing
      case parseSlash reg "/tab rename 0 work" of
        ParsedAction act -> runCommand act caps
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)
      sent <- readIORef ref
      sent `shouldSatisfy` any ("work" `T.isInfixOf`)
      snap <- snapshotTabs h
      case tlTabs snap of
        [t] -> tLabel t `shouldBe` Just "work"
        _   -> expectationFailure "expected one tab"

  it "/tab list does not display the Kind (e.g. KindProvider)" $
    withSystemTempDirectory "seal-tab" $ \tmp -> do
      h <- newTabsHandle
      let paths = dummyPaths tmp
          reg = mkRegistry [tabCommandSpec paths h noTabCloseNotifier]
      (ref, caps) <- recordingCaps
      _ <- insertTabH h (BoundSession (mkSid "a")) KindProvider Nothing
      case parseSlash reg "/tab list" of
        ParsedAction act -> runCommand act caps
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)
      sent <- readIORef ref
      sent `shouldSatisfy` none (T.isInfixOf "KindProvider")
      sent `shouldSatisfy` none (T.isInfixOf "KindAi")

  it "/tab list shows the session description when set" $
    withSystemTempDirectory "seal-tab" $ \tmp -> do
      h <- newTabsHandle
      let paths = dummyPaths tmp
          reg = mkRegistry [tabCommandSpec paths h noTabCloseNotifier]
      (ref, caps) <- recordingCaps
      let sid = mkSid "desc-session"
      saveSessionMeta paths (metaWithDescription sid (Just "My Custom Name"))
      _ <- insertTabH h (BoundSession sid) KindProvider Nothing
      case parseSlash reg "/tab list" of
        ParsedAction act -> runCommand act caps
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)
      sent <- readIORef ref
      sent `shouldSatisfy` any ("My Custom Name" `T.isInfixOf`)

  it "/tab list falls back to first message snippet when no description and no label" $
    withSystemTempDirectory "seal-tab" $ \tmp -> do
      h <- newTabsHandle
      let paths = dummyPaths tmp
          reg = mkRegistry [tabCommandSpec paths h noTabCloseNotifier]
      (ref, caps) <- recordingCaps
      let sid = mkSid "no-desc"
      saveSessionMeta paths (metaWithDescription sid Nothing)
      _ <- insertTabH h (BoundSession sid) KindProvider Nothing
      case parseSlash reg "/tab list" of
        ParsedAction act -> runCommand act caps
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)
      sent <- readIORef ref
      -- No description and no transcript: the tab line should still show
      -- the session ref but no display name.
      sent `shouldSatisfy` any (T.isInfixOf (T.singleton (tabIndexToChar (mkIdx 0))))

  it "/tab list: tab label takes priority over session description" $
    withSystemTempDirectory "seal-tab" $ \tmp -> do
      h <- newTabsHandle
      let paths = dummyPaths tmp
          reg = mkRegistry [tabCommandSpec paths h noTabCloseNotifier]
      (ref, caps) <- recordingCaps
      let sid = mkSid "both"
      saveSessionMeta paths (metaWithDescription sid (Just "Session Description"))
      _ <- insertTabH h (BoundSession sid) KindAi (Just "Tab Label")
      case parseSlash reg "/tab list" of
        ParsedAction act -> runCommand act caps
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)
      sent <- readIORef ref
      sent `shouldSatisfy` any ("Tab Label" `T.isInfixOf`)
      sent `shouldSatisfy` none ("Session Description" `T.isInfixOf`)

  it "/help includes the tab family + the terse grammar synopsis" $
    withSystemTempDirectory "seal-tab" $ \tmp -> do
      h <- newTabsHandle
      let paths = dummyPaths tmp
          reg = mkRegistry [tabCommandSpec paths h noTabCloseNotifier, terseGrammarSpec]
          help = renderHelpIndex reg
      T.unpack help `shouldContain` "/tab"
      T.unpack help `shouldContain` "N [payload]"

  it "/tab focus 0 (with a tab present) replies 'focused'" $
    withSystemTempDirectory "seal-tab" $ \tmp -> do
      h <- newTabsHandle
      let paths = dummyPaths tmp
          reg = mkRegistry [tabCommandSpec paths h noTabCloseNotifier]
      (ref, caps) <- recordingCaps
      _ <- insertTabH h (BoundSession (mkSid "a")) KindAi Nothing
      case parseSlash reg "/tab focus 0" of
        ParsedAction act -> runCommand act caps
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)
      sent <- readIORef ref
      sent `shouldSatisfy` any ("focused" `T.isInfixOf`)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

mkSid :: Text -> SessionId
mkSid t = case mkSessionId t of Right s -> s; Left _ -> error "bad sid"

runCommand :: CommandAction -> ChannelCaps -> IO ()
runCommand act caps = void (runCommandAction act caps)

-- | Render a ParseOutcome for error messages (it has no Show instance).
showPO :: ParseOutcome -> String
showPO (ParseFailure t)    = "ParseFailure " <> show t
showPO (ParsedAction _)   = "ParsedAction"
showPO (ParseHelp Nothing) = "ParseHelp Nothing"
showPO (ParseHelp (Just n)) = "ParseHelp " <> show n

-- ---------------------------------------------------------------------------
-- Helpers for display-name tests
-- ---------------------------------------------------------------------------

none :: (a -> Bool) -> [a] -> Bool
none = all . (not .)

mkIdx :: Int -> TabIndex
mkIdx n = case mkTabIndex n of
  Right i -> i
  Left _  -> error "bad index"

metaWithDescription :: SessionId -> Maybe Text -> SessionMeta
metaWithDescription sid mDesc = SessionMeta
  { smId = sid, smProvider = "ollama", smModel = "llama3.2"
  , smChannel = "cli", smAgent = Nothing
  , smSystemOverride = Nothing, smAgentName = Nothing
  , smDescription = mDesc
  , smCreatedAt = testTime, smLastActive = testTime
  }
  where
    testTime = UTCTime (fromGregorian 2026 1 1) 0
