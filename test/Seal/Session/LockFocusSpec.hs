{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the reply registry's at-most-one-session-per-handle
-- invariant (introduced to fix the "streaming continues after tab focus"
-- bug). When a channel handle subscribes to a new session, it is
-- automatically removed from any previous session it was subscribed to.
-- Also tests 'replyIsSubscribed' (used by the tool-call hook to gate
-- tool-progress messages on focus).
module Seal.Session.LockFocusSpec (spec) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Test.Hspec

import Seal.Core.Types (SessionId, mkSessionId)
import Seal.Handles.Channel (ChannelHandle (..), Deferral (..))
import Seal.Session.Lock

-- | A recording channel handle: every 'chSend' appends to the IORef
-- (reversed; read via 'getSent'). The 'chLabel' is the supplied channel
-- kind label.
recordingHandle :: Text -> IO (ChannelHandle, IO [Text])
recordingHandle label = do
  ref <- newIORef ([] :: [Text])
  let h = ChannelHandle
        { chLabel       = label
        , chSend         = \t -> modifyIORef' ref (t :)
        , chSendWithId   = \_ -> pure Nothing
        , chEditMessage  = Nothing
        , chDeleteMessage = Nothing
        , chSendError    = \_ -> pure ()
        , chSendChunk    = \_ -> pure ()
        , chPrompt       = \_ -> pure (Left Deferred)
        , chPromptSecret = \_ -> pure (Left Deferred)
        , chStreaming    = False
        , chReadSecret   = pure Nothing
        , chReceive      = pure (Nothing, "")
        , chLastChatId   = pure Nothing
        }
  pure (h, reverse <$> readIORef ref)

sidA :: SessionId
sidA = either (error "sidA") id (mkSessionId "session-a")

sidB :: SessionId
sidB = either (error "sidB") id (mkSessionId "session-b")

spec :: Spec
spec = describe "Seal.Session.Lock focus invariant" $ do
  describe "replySubscribe (at-most-one-session-per-handle)" $ do
    it "subscribing to a new session removes the handle from the old session" $ do
      reg <- newReplyRegistry
      (tg, _) <- recordingHandle "telegram"
      -- Subscribe to session A first.
      _ <- replySubscribe reg tg sidA
      countA <- replySubscriberCount reg sidA
      countA `shouldBe` 1
      -- Now subscribe to session B (simulating /tab focus).
      _ <- replySubscribe reg tg sidB
      -- The handle should be in session B, NOT in session A.
      countA' <- replySubscriberCount reg sidA
      countB <- replySubscriberCount reg sidB
      countA' `shouldBe` 0
      countB `shouldBe` 1

    it "re-subscribing to the same session is a no-op (still count 1)" $ do
      reg <- newReplyRegistry
      (tg, _) <- recordingHandle "telegram"
      _ <- replySubscribe reg tg sidA
      _ <- replySubscribe reg tg sidA
      count <- replySubscriberCount reg sidA
      count `shouldBe` 1

    it "different channel kinds can still subscribe to the same session" $ do
      reg <- newReplyRegistry
      (tg, _) <- recordingHandle "telegram"
      (sig, _) <- recordingHandle "signal"
      _ <- replySubscribe reg tg sidA
      _ <- replySubscribe reg sig sidA
      count <- replySubscriberCount reg sidA
      count `shouldBe` 2

    it "a handle that moves A→B does not receive fan-out from A" $ do
      reg <- newReplyRegistry
      (tg, getTg) <- recordingHandle "telegram"
      _ <- replySubscribe reg tg sidA
      -- Move to session B.
      _ <- replySubscribe reg tg sidB
      -- Fan out a reply on session A.
      replyFanout reg sidA "reply from A"
      -- The handle should NOT receive it (it's no longer subscribed to A).
      getTg `shouldReturn` []

    it "a handle that moves A→B receives fan-out from B" $ do
      reg <- newReplyRegistry
      (tg, getTg) <- recordingHandle "telegram"
      _ <- replySubscribe reg tg sidA
      _ <- replySubscribe reg tg sidB
      replyFanout reg sidB "reply from B"
      getTg `shouldReturn` ["reply from B"]

  describe "replyIsSubscribed" $ do
    it "returns True when the handle is subscribed to the session" $ do
      reg <- newReplyRegistry
      (tg, _) <- recordingHandle "telegram"
      _ <- replySubscribe reg tg sidA
      replyIsSubscribed reg "telegram" sidA `shouldReturn` True

    it "returns False when the handle is not subscribed to the session" $ do
      reg <- newReplyRegistry
      (tg, _) <- recordingHandle "telegram"
      _ <- replySubscribe reg tg sidA
      replyIsSubscribed reg "telegram" sidB `shouldReturn` False

    it "returns False after the handle moves to a different session" $ do
      reg <- newReplyRegistry
      (tg, _) <- recordingHandle "telegram"
      _ <- replySubscribe reg tg sidA
      _ <- replySubscribe reg tg sidB
      replyIsSubscribed reg "telegram" sidA `shouldReturn` False
      replyIsSubscribed reg "telegram" sidB `shouldReturn` True

    it "returns False when no handles are subscribed" $ do
      reg <- newReplyRegistry
      replyIsSubscribed reg "telegram" sidA `shouldReturn` False

    it "returns False for a different channel label" $ do
      reg <- newReplyRegistry
      (tg, _) <- recordingHandle "telegram"
      _ <- replySubscribe reg tg sidA
      replyIsSubscribed reg "signal" sidA `shouldReturn` False