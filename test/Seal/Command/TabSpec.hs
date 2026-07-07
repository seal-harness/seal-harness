{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.TabSpec (spec) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Help (renderHelpIndex)
import Seal.Command.Parse (parseSlash, ParseOutcome (..))
import Seal.Command.Spec (CommandAction(..), mkRegistry)
import Seal.Command.Tab (tabCommandSpec, terseGrammarSpec)
import Seal.Core.Types (mkSessionId, SessionId)
import Seal.Handles.Tab (tabIndexToChar, TabKind(..))
import Seal.Tabs (insertTabH, newTabsHandle, snapshotTabs)
import Seal.Tabs.Types (Tab (..), TabList(..), TabRef(..), tabCount)

-- | A recording ChannelCaps.
recordingCaps :: IO (IORef [Text], ChannelCaps)
recordingCaps = do
  ref <- newIORef []
  pure (ref, ChannelCaps
    { ccSend = \t -> modifyIORef' ref (t :)
    , ccPrompt = \_ -> pure ""
    , ccPromptSecret = \_ -> pure ""
    })

spec :: Spec
spec = describe "Seal.Command.Tab" $ do
  it "/tab list on an empty handle replies 'no tabs'" $ do
    h <- newTabsHandle
    let reg = mkRegistry [tabCommandSpec h]
    (ref, caps) <- recordingCaps
    case parseSlash reg "/tab list" of
      ParsedAction act -> runCommand act caps
      other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)
    sent <- readIORef ref
    sent `shouldSatisfy` ("no tabs" `elem`)

  it "/tab new creates a tab and replies with 'created'" $ do
    h <- newTabsHandle
    let reg = mkRegistry [tabCommandSpec h]
    (ref, caps) <- recordingCaps
    case parseSlash reg "/tab new" of
      ParsedAction act -> runCommand act caps
      other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)
    sent <- readIORef ref
    sent `shouldSatisfy` any ("created" `T.isInfixOf`)
    -- the handle now has one tab
    snap <- snapshotTabs h
    tabCount snap `shouldBe` 1

  it "/tab list after /tab new shows one tab" $ do
    h <- newTabsHandle
    let reg = mkRegistry [tabCommandSpec h]
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

  it "/tab close 0 closes the first tab" $ do
    h <- newTabsHandle
    let reg = mkRegistry [tabCommandSpec h]
    (ref, caps) <- recordingCaps
    _ <- insertTabH h (BoundSession (mkSid "a")) KindAi Nothing
    case parseSlash reg "/tab close 0" of
      ParsedAction act -> runCommand act caps
      other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)
    sent <- readIORef ref
    sent `shouldSatisfy` any ("closed" `T.isInfixOf`)
    snap <- snapshotTabs h
    tabCount snap `shouldBe` 0

  it "/tab rename 0 work sets the label" $ do
    h <- newTabsHandle
    let reg = mkRegistry [tabCommandSpec h]
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

  it "/help includes the tab family + the terse grammar synopsis" $ do
    h <- newTabsHandle
    let reg = mkRegistry [tabCommandSpec h, terseGrammarSpec]
        help = renderHelpIndex reg
    T.unpack help `shouldContain` "/tab"
    T.unpack help `shouldContain` "N [payload]"

  it "/tab focus 0 (with a tab present) replies 'focused'" $ do
    h <- newTabsHandle
    let reg = mkRegistry [tabCommandSpec h]
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
runCommand = runCommandAction

-- | Render a ParseOutcome for error messages (it has no Show instance).
showPO :: ParseOutcome -> String
showPO (ParsedAction _)   = "ParsedAction"
showPO (ParseHelp Nothing) = "ParseHelp Nothing"
showPO (ParseHelp (Just n)) = "ParseHelp " <> show n
showPO (ParseFailure t)   = "ParseFailure " <> T.unpack t