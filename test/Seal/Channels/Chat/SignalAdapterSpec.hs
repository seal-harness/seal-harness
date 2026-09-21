{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.Signal' — the Signal chat-channel adapter.
module Seal.Channels.Chat.SignalAdapterSpec (spec) where

import Test.Hspec (Spec, describe, it, shouldBe)

import Seal.Channels.Chat.Class (ChatChannel (..))
import Seal.Channels.Chat.Signal
  ( withSignalChatChannel
  , mkMockSignalChatTransport
  , chunkMessage
  )
import Seal.Channels.Chat.Types (ChatMessageId (..))
import Seal.Gateway.Types.AllowList (AllowList (..))

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
      (transport, _) <- mkMockSignalChatTransport []
      withSignalChatChannel AllowAll 1000 transport $ \ch -> do
        ccLabel ch `shouldBe` "signal"

    it "sends messages via the transport" $ do
      (transport, getCaptured) <- mkMockSignalChatTransport []
      withSignalChatChannel AllowAll 1000 transport $ \ch -> do
        ccSend ch "hello world"
        captured <- getCaptured
        captured `shouldBe` ["hello world"]

    it "sends with id and returns a ChatMessageId" $ do
      (transport, _) <- mkMockSignalChatTransport []
      withSignalChatChannel AllowAll 1000 transport $ \ch -> do
        mId <- ccSendWithId ch "test"
        case mId of
          Just (ChatMessageId _) -> pure ()
          Nothing -> fail "expected a message id"

    it "edits messages via the transport" $ do
      (transport, _) <- mkMockSignalChatTransport []
      withSignalChatChannel AllowAll 1000 transport $ \ch -> do
        ok <- ccEditMessage ch (ChatMessageId "123") "new content"
        ok `shouldBe` True

    it "chunks long sends" $ do
      (transport, getCaptured) <- mkMockSignalChatTransport []
      withSignalChatChannel AllowAll 5 transport $ \ch -> do
        ccSend ch "abcdefghij"
        captured <- getCaptured
        captured `shouldBe` ["abcde", "fghij"]