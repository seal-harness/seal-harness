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

-- | A plain-text handler that never fires; used by the non-'PlainMessage' cases.
ignoredHandler :: Text -> IO ()
ignoredHandler _ = pure ()

spec :: Spec
spec = do
  describe "interpretDisposition" $ do
    it "ShowText routes the text to ccSend" $ do
      ref <- newIORef []
      interpretDisposition (recordingCaps ref) ignoredHandler (ShowText "hello world")
      sent <- readIORef ref
      sent `shouldBe` ["hello world"]

    it "PlainMessage routes the text to the injected handler" $ do
      capRef <- newIORef []
      seen   <- newIORef []
      let handler t = modifyIORef' seen (t :)
      interpretDisposition (recordingCaps capRef) handler (PlainMessage "ignored text")
      received <- readIORef seen
      sent     <- readIORef capRef
      received `shouldBe` ["ignored text"]
      sent `shouldBe` []   -- handler owns the message; ccSend is not touched

    it "Rejected emits the rejection message" $ do
      ref <- newIORef []
      interpretDisposition (recordingCaps ref) ignoredHandler (Rejected "input blocked")
      sent <- readIORef ref
      sent `shouldBe` ["input blocked"]

    it "DispatchAction runs the action through caps" $ do
      ref <- newIORef []
      let caps   = recordingCaps ref
          action = CommandAction $ \c -> ccSend c "from action"
      interpretDisposition caps ignoredHandler (DispatchAction action)
      sent <- readIORef ref
      sent `shouldBe` ["from action"]

  describe "seal tui smoke (interactive — manual)" $
    it "seal tui launches and shows the > prompt" $
      pendingWith
        "interactive: run `nix develop --command cabal run seal -- tui` \
        \and verify the '> ' prompt appears; Ctrl-D exits cleanly"
