{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Session.Lock' — the reply registry's accumulate-by-
-- channel-kind subscription model + the cross-channel message-mirroring
-- fanout ('replyFanoutMessage'). The reply registry is the core of the
-- cross-channel message mirroring feature: each append-only channel
-- subscribes to a session, and every user message is mirrored to all
-- OTHER subscribed channels with a [channel] prefix.
module Seal.Session.LockSpec (spec) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Test.Hspec

import Seal.Core.Types (SessionId, mkSessionId)
import Seal.Handles.Channel (ChannelHandle (..), Deferral (..))
import Seal.Session.Lock
  ( newReplyRegistry, replySubscribe, replyFanout, replyFanoutMessage
  , replySubscriberCount )

-- | A recording channel handle: every 'chSend' appends to the IORef
-- (reversed; read via 'getSent'). The 'chLabel' is the supplied channel
-- kind label.
recordingHandle :: Text -> IO (ChannelHandle, IO [Text])
recordingHandle label = do
  ref <- newIORef ([] :: [Text])
  let h = ChannelHandle
        { chLabel       = label
        , chSend         = \t -> modifyIORef' ref (t :)
        , chSendError    = \_ -> pure ()
        , chSendChunk    = \_ -> pure ()
        , chPrompt       = \_ -> pure (Left Deferred)
        , chPromptSecret = \_ -> pure (Left Deferred)
        , chStreaming    = False
        , chReadSecret   = pure Nothing
        , chReceive      = pure (Nothing, "")
        }
  pure (h, reverse <$> readIORef ref)

sid :: SessionId
sid = either (error "sid") id (mkSessionId "s1")

spec :: Spec
spec = describe "Seal.Session.Lock" $ do
  describe "replySubscribe (accumulate by channel kind)" $ do
    it "subscribes one handle per channel kind; different kinds accumulate" $ do
      reg <- newReplyRegistry
      (tg, _) <- recordingHandle "telegram"
      (sig, _) <- recordingHandle "signal"
      _ <- replySubscribe reg tg sid
      _ <- replySubscribe reg sig sid
      count <- replySubscriberCount reg sid
      count `shouldBe` 2

    it "re-subscribing the same channel kind replaces the old handle (no dup)" $ do
      reg <- newReplyRegistry
      (tg1, _) <- recordingHandle "telegram"
      (tg2, _) <- recordingHandle "telegram"
      _ <- replySubscribe reg tg1 sid
      _ <- replySubscribe reg tg2 sid
      count <- replySubscriberCount reg sid
      count `shouldBe` 1

    it "three distinct channel kinds all accumulate" $ do
      reg <- newReplyRegistry
      (a, _) <- recordingHandle "telegram"
      (b, _) <- recordingHandle "signal"
      (c, _) <- recordingHandle "cli"
      _ <- replySubscribe reg a sid
      _ <- replySubscribe reg b sid
      _ <- replySubscribe reg c sid
      count <- replySubscriberCount reg sid
      count `shouldBe` 3

  describe "replyFanoutMessage (cross-channel mirroring)" $ do
    it "mirrors a message to all OTHER channels, prefixed with [sender]" $ do
      reg <- newReplyRegistry
      (tg, getTg) <- recordingHandle "telegram"
      (sig, getSig) <- recordingHandle "signal"
      _ <- replySubscribe reg tg sid
      _ <- replySubscribe reg sig sid
      replyFanoutMessage reg sid "telegram" "hello there"
      -- The sender (telegram) gets nothing back.
      getTg `shouldReturn` []
      -- The other channel (signal) gets the prefixed message.
      getSig `shouldReturn` ["[telegram] hello there"]

    it "excludes the web frontend (sender label 'web' reaches all chat channels)" $ do
      reg <- newReplyRegistry
      (tg, getTg) <- recordingHandle "telegram"
      (sig, getSig) <- recordingHandle "signal"
      _ <- replySubscribe reg tg sid
      _ <- replySubscribe reg sig sid
      -- A web-originated message: "web" is the sender label, but no chat
      -- channel has label "web", so ALL subscribed channels receive it.
      replyFanoutMessage reg sid "web" "from the web UI"
      getTg `shouldReturn` ["[web] from the web UI"]
      getSig `shouldReturn` ["[web] from the web UI"]

    it "mirrors to N-1 channels when N are subscribed" $ do
      reg <- newReplyRegistry
      (a, getA) <- recordingHandle "telegram"
      (b, getB) <- recordingHandle "signal"
      (c, getC) <- recordingHandle "cli"
      _ <- replySubscribe reg a sid
      _ <- replySubscribe reg b sid
      _ <- replySubscribe reg c sid
      replyFanoutMessage reg sid "signal" "multi cast"
      -- Sender (signal) gets nothing.
      getB `shouldReturn` []
      -- The other two get the prefixed message.
      getA `shouldReturn` ["[signal] multi cast"]
      getC `shouldReturn` ["[signal] multi cast"]

    it "is a no-op when only the sender is subscribed" $ do
      reg <- newReplyRegistry
      (tg, getTg) <- recordingHandle "telegram"
      _ <- replySubscribe reg tg sid
      replyFanoutMessage reg sid "telegram" "lonely message"
      getTg `shouldReturn` []

  describe "replyFanout (assistant reply — goes to ALL subscribers)" $ do
    it "sends the reply to every subscribed channel (no exclusion)" $ do
      reg <- newReplyRegistry
      (tg, getTg) <- recordingHandle "telegram"
      (sig, getSig) <- recordingHandle "signal"
      _ <- replySubscribe reg tg sid
      _ <- replySubscribe reg sig sid
      replyFanout reg sid "assistant response"
      getTg `shouldReturn` ["assistant response"]
      getSig `shouldReturn` ["assistant response"]