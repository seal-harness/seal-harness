{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.BackgroundSpec (spec) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Background (BgRunner (..), backgroundCommandSpec, runBackground)
import Seal.Command.Help (renderHelpIndex)
import Seal.Command.Parse (ParseOutcome (..), parseSlash)
import Seal.Command.Spec (CommandAction (..), mkRegistry)

-- | A recording ChannelCaps.
recordingCaps :: IO (IORef [Text], ChannelCaps)
recordingCaps = do
  ref <- newIORef []
  pure (ref, ChannelCaps
    { ccSend = \t -> modifyIORef' ref (t :)
    , ccPrompt = \_ -> pure ""
    , ccPromptSecret = \_ -> pure ""
    })

-- | A BgRunner that records the prompt it was given (no real turn). Used to
-- verify the /bg action delegates the prompt to the channel-supplied runner
-- without running a provider.
recordingRunner :: IO (IORef [Text], BgRunner)
recordingRunner = do
  ref <- newIORef []
  pure (ref, BgRunner (\p -> modifyIORef' ref (p :)))

spec :: Spec
spec = describe "Seal.Command.Background" $ do
  describe "parse" $ do
    it "/bg with a prompt parses to a ParsedAction" $ do
      (_, runner) <- recordingRunner
      let reg = mkRegistry [backgroundCommandSpec runner]
      case parseSlash reg "/bg tell me a joke" of
        ParsedAction _  -> pure ()
        other          -> expectationFailure ("expected ParsedAction, got: " <> showPO other)

    it "/bg with a quoted multi-word prompt parses to a ParsedAction" $ do
      (_, runner) <- recordingRunner
      let reg = mkRegistry [backgroundCommandSpec runner]
      case parseSlash reg "/bg \"hello world\"" of
        ParsedAction _  -> pure ()
        other          -> expectationFailure ("expected ParsedAction, got: " <> showPO other)

    it "/bg re-joins unquoted multi-word args with spaces" $ do
      (ref, runner) <- recordingRunner
      let reg = mkRegistry [backgroundCommandSpec runner]
      case parseSlash reg "/bg tell me a joke" of
        ParsedAction act -> do
          (capsRef, caps) <- recordingCaps
          runCommandAction act caps
          sent <- readIORef ref
          sent `shouldBe` ["tell me a joke"]
          -- the caps were not used to send (the runner owns delivery)
          capsSent <- readIORef capsRef
          capsSent `shouldBe` []
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)

    it "/bg with no argument parses then rejects as blank at run time" $ do
      (_, runner) <- recordingRunner
      let reg = mkRegistry [backgroundCommandSpec runner]
      case parseSlash reg "/bg" of
        ParsedAction act -> do
          (ref, caps) <- recordingCaps
          runCommandAction act caps
          sent <- readIORef ref
          sent `shouldBe` ["usage: /bg <prompt>"]
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)

    it "/bg is case-insensitive" $ do
      (_, runner) <- recordingRunner
      let reg = mkRegistry [backgroundCommandSpec runner]
      case parseSlash reg "/BG hello" of
        ParsedAction _  -> pure ()
        other          -> expectationFailure ("expected ParsedAction, got: " <> showPO other)

  describe "/help" $
    it "includes the /bg command in the index" $ do
      (_, runner) <- recordingRunner
      let reg = mkRegistry [backgroundCommandSpec runner]
          help = renderHelpIndex reg
      T.unpack help `shouldContain` "/bg"

  describe "runBackground (blank prompt)" $ do
    it "rejects a blank prompt with a usage line and never invokes the runner" $ do
      (runRef, runner) <- recordingRunner
      (ref, caps) <- recordingCaps
      runCommandAction (runBackground runner "") caps
      sent <- readIORef ref
      sent `shouldBe` ["usage: /bg <prompt>"]
      invoked <- readIORef runRef
      invoked `shouldBe` []

    it "rejects a whitespace-only prompt as blank" $ do
      (_, runner) <- recordingRunner
      (ref, caps) <- recordingCaps
      runCommandAction (runBackground runner "   ") caps
      sent <- readIORef ref
      sent `shouldBe` ["usage: /bg <prompt>"]

-- | Render a ParseOutcome for error messages (no Show instance).
showPO :: ParseOutcome -> String
showPO (ParsedAction _)    = "ParsedAction"
showPO (ParseHelp Nothing) = "ParseHelp Nothing"
showPO (ParseHelp (Just n)) = "ParseHelp " <> show n
showPO (ParseFailure t)    = "ParseFailure " <> T.unpack t