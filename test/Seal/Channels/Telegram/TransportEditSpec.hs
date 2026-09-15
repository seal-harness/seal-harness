{-# LANGUAGE OverloadedStrings #-}
module Seal.Channels.Telegram.TransportEditSpec (spec) where

import Test.Hspec

import Seal.Channels.Telegram.Transport
  ( TelegramTransport (..)
  , mkMockTelegramTransport
  )

spec :: Spec
spec = do
  describe "Seal.Channels.Telegram.Transport mock edit support" $ do
    it "tgSendWithId captures the send and returns a message id" $ do
      (t, _, _, _, _, getSendWithIds, _, _) <- mkMockTelegramTransport []
      mid <- tgSendWithId t "123" "hello"
      sendWithIds <- getSendWithIds
      mid `shouldBe` Just "1"
      sendWithIds `shouldBe` [("123", "hello")]

    it "tgSendWithId returns incrementing message ids" $ do
      (t, _, _, _, _, getSendWithIds, _, _) <- mkMockTelegramTransport []
      mid1 <- tgSendWithId t "123" "first"
      mid2 <- tgSendWithId t "123" "second"
      sendWithIds <- getSendWithIds
      mid1 `shouldBe` Just "1"
      mid2 `shouldBe` Just "2"
      sendWithIds `shouldBe` [("123", "first"), ("123", "second")]

    it "tgEditMessage captures the edit (chatId, messageId, content)" $ do
      (t, _, _, _, _, _, getEdits, _) <- mkMockTelegramTransport []
      ok <- tgEditMessage t "123" "1" "updated"
      edits <- getEdits
      ok `shouldBe` True
      edits `shouldBe` [("123", "1", "updated")]

    it "tgDeleteMessage captures the delete (chatId, messageId)" $ do
      (t, _, _, _, _, _, _, getDeletes) <- mkMockTelegramTransport []
      ok <- tgDeleteMessage t "123" "1"
      deletes <- getDeletes
      ok `shouldBe` True
      deletes `shouldBe` [("123", "1")]