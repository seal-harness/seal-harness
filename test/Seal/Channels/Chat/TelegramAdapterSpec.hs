{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.Telegram' — the Telegram chat-channel adapter.
module Seal.Channels.Chat.TelegramAdapterSpec (spec) where

import Test.Hspec (Spec, describe, it, shouldBe)

import Seal.Channels.Chat.Class (ChatChannel (..))
import Seal.Channels.Chat.Telegram
  ( withTelegramChatChannel
  , mkMockTelegramChatTransport
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

  describe "ChatChannel TelegramChatChannel" $ do
    it "has label 'telegram'" $ do
      (transport, _) <- mkMockTelegramChatTransport []
      withTelegramChatChannel AllowAll 1000 transport $ \ch -> do
        ccLabel ch `shouldBe` "telegram"

    it "sends messages via the transport" $ do
      (transport, getCaptured) <- mkMockTelegramChatTransport []
      withTelegramChatChannel AllowAll 1000 transport $ \ch -> do
        ccSend ch "hello world"
        captured <- getCaptured
        captured `shouldBe` ["hello world"]

    it "sends with id and returns a ChatMessageId" $ do
      (transport, _) <- mkMockTelegramChatTransport []
      withTelegramChatChannel AllowAll 1000 transport $ \ch -> do
        mId <- ccSendWithId ch "test"
        case mId of
          Just (ChatMessageId _) -> pure ()
          Nothing -> fail "expected a message id"

    it "edits messages via the transport" $ do
      (transport, _) <- mkMockTelegramChatTransport []
      withTelegramChatChannel AllowAll 1000 transport $ \ch -> do
        ok <- ccEditMessage ch (ChatMessageId "123") "new content"
        ok `shouldBe` True

    it "chunks long sends" $ do
      (transport, getCaptured) <- mkMockTelegramChatTransport []
      withTelegramChatChannel AllowAll 5 transport $ \ch -> do
        ccSend ch "abcdefghij"
        captured <- getCaptured
        captured `shouldBe` ["abcde", "fghij"]