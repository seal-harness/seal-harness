{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.Signal' — the Signal chat-channel adapter.
module Seal.Channels.Chat.SignalAdapterSpec (spec) where

import Control.Concurrent (threadDelay)
import Test.Hspec (Spec, describe, it, shouldBe)

import Seal.Channels.Chat.Class (ChatChannel (..))
import Seal.Channels.Chat.Signal
  ( withSignalChatChannel
  , mkMockSignalChatTransport
  , chunkMessage
  )
import Seal.Channels.Chat.Types (ChatMessageId (..), ReceivedMessage (..))
import Seal.Gateway.Types.MessageSource (mkConversationId)
import Seal.Gateway.Types.AllowList (AllowList (..))

-- | A dummy received message for seeding the last-sender in tests.
dummyMsg :: ReceivedMessage
dummyMsg = ReceivedMessage
  { rmConversationId = case mkConversationId "sig:+15551234567" of Right c -> c; Left _ -> error "bad cid"
  , rmSender = Just "+15551234567"
  , rmReplyTo = "+15551234567"
  , rmBody = "init"
  }

-- | Wait briefly for the reader thread to process the seed message.
waitForSeed :: IO ()
waitForSeed = threadDelay 50000  -- 50ms

spec :: Spec
spec = do
  describe "chunkMessage" $ do
    it "returns the message as-is when under the limit" $
      chunkMessage 100 "hello" `shouldBe` ["hello"]

    it "splits a long message at the limit" $
      chunkMessage 5 "abcdefghij" `shouldBe` ["abcde", "fghij"]

    it "handles empty string" $
      chunkMessage 5 "" `shouldBe` [""]

    it "handles exactly the limit" $
      chunkMessage 5 "abcde" `shouldBe` ["abcde"]

  describe "ChatChannel SignalChatChannel" $ do
    it "has label 'signal'" $ do
      (transport, _) <- mkMockSignalChatTransport [dummyMsg]
      withSignalChatChannel AllowAll 1000 transport $ \ch -> do
        ccLabel ch `shouldBe` "signal"

    it "sends messages via the transport" $ do
      (transport, getCaptured) <- mkMockSignalChatTransport [dummyMsg]
      withSignalChatChannel AllowAll 1000 transport $ \ch -> do
        waitForSeed
        ccSend ch "hello world"
        captured <- getCaptured
        captured `shouldBe` ["hello world"]

    it "sends with id and returns a ChatMessageId" $ do
      (transport, _) <- mkMockSignalChatTransport [dummyMsg]
      withSignalChatChannel AllowAll 1000 transport $ \ch -> do
        waitForSeed
        mId <- ccSendWithId ch "test"
        case mId of
          Just (ChatMessageId _) -> pure ()
          Nothing -> fail "expected a message id"

    it "edits messages via the transport" $ do
      (transport, _) <- mkMockSignalChatTransport [dummyMsg]
      withSignalChatChannel AllowAll 1000 transport $ \ch -> do
        waitForSeed
        ok <- ccEditMessage ch (ChatMessageId "123") "new content"
        ok `shouldBe` True

    it "chunks long sends" $ do
      (transport, getCaptured) <- mkMockSignalChatTransport [dummyMsg]
      withSignalChatChannel AllowAll 5 transport $ \ch -> do
        waitForSeed
        ccSend ch "abcdefghij"
        captured <- getCaptured
        captured `shouldBe` ["abcde", "fghij"]