{-# LANGUAGE OverloadedStrings #-}
module Seal.Channel.CliSpec (spec) where

import Data.IORef
import Data.Text (Text)

import Test.Hspec

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Channel.Cli (interpretDisposition)
import Seal.Command.Spec (CommandAction (..))
import Seal.Ingest (Disposition (..))

-- | A 'ChannelCaps' that records every 'ccSend' call into @ref@ (prepended;
-- reverse for chronological order).  Prompt functions return the empty string.
recordingCaps :: IORef [Text] -> ChannelCaps
recordingCaps ref = ChannelCaps
  { ccSend         = \t -> modifyIORef' ref (t :)
  , ccPrompt       = \_ -> pure ""
  , ccPromptSecret = \_ -> pure ""
  }

spec :: Spec
spec = do
  describe "interpretDisposition" $ do
    it "ShowText routes the text to ccSend" $ do
      ref <- newIORef []
      interpretDisposition (recordingCaps ref) (ShowText "hello world")
      sent <- readIORef ref
      sent `shouldBe` ["hello world"]

    it "PlainMessage emits the MVP stub message" $ do
      ref <- newIORef []
      interpretDisposition (recordingCaps ref) (PlainMessage "ignored text")
      sent <- readIORef ref
      sent `shouldBe` ["(no agent configured yet)"]

    it "Rejected emits the rejection message" $ do
      ref <- newIORef []
      interpretDisposition (recordingCaps ref) (Rejected "input blocked")
      sent <- readIORef ref
      sent `shouldBe` ["input blocked"]

    it "DispatchAction runs the action through caps" $ do
      ref <- newIORef []
      let caps   = recordingCaps ref
          action = CommandAction $ \c -> ccSend c "from action"
      interpretDisposition caps (DispatchAction action)
      sent <- readIORef ref
      sent `shouldBe` ["from action"]

  describe "seal tui smoke (interactive — manual)" $
    it "seal tui launches and shows the > prompt" $
      pendingWith
        "interactive: run `nix develop --command cabal run seal -- tui` \
        \and verify the '> ' prompt appears; Ctrl-D exits cleanly"
