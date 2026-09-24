{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.Types' — the shared types for the
-- chat-channel package.
module Seal.Channels.Chat.TypesSpec (spec) where

import Data.Text (Text)
import Test.Hspec (Spec, describe, it, shouldBe)

import Seal.Channels.Chat.Types
  ( ConversationKey (..)
  , convKeyFromSource
  , newSessionMap
  , sessionLookup
  , sessionInsert
  , GatewayConfig (..)
  , defaultGatewayConfig
  )

import Seal.Gateway.Types.ChannelKind (ChannelKind (..))
import Seal.Gateway.Types.Core (SessionId, mkSessionId)
import Seal.Gateway.Types.MessageSource
  ( MessageSource
  , mkMessageSource
  , mkConversationId
  )

-- | Helper: make a 'MessageSource' for testing.
mkTestSource :: Text -> ChannelKind -> MessageSource
mkTestSource convId kind =
  case mkConversationId convId of
    Right cid -> case mkMessageSource cid kind Nothing mempty of
      Right ms -> ms
      Left e   -> error ("test mkTestSource: " <> show e)
    Left e    -> error ("test mkConversationId: " <> show e)

-- | Helper: make a 'SessionId' for testing (crashes on invalid — test-only).
mkSid :: Text -> SessionId
mkSid t = case mkSessionId t of
  Right s -> s
  Left e  -> error ("test mkSid: " <> show e)

spec :: Spec
spec = do
  describe "convKeyFromSource" $ do
    it "derives the key from channel kind + conversation id" $ do
      let ms = mkTestSource "conv123" Signal
      let key = convKeyFromSource ms
      ckChannel key `shouldBe` "signal"
      ckConv key `shouldBe` "conv123"

    it "derives the key for Telegram" $ do
      let ms = mkTestSource "chat456" Telegram
      let key = convKeyFromSource ms
      ckChannel key `shouldBe` "telegram"
      ckConv key `shouldBe` "chat456"

  describe "SessionMap" $ do
    it "starts empty — lookup returns Nothing" $ do
      sm <- newSessionMap
      let key = ConversationKey "signal" "conv1"
      result <- sessionLookup sm key
      result `shouldBe` Nothing

    it "insert then lookup returns the session id" $ do
      sm <- newSessionMap
      let key = ConversationKey "signal" "conv1"
          sid = mkSid "test-session"
      sessionInsert sm key sid
      result <- sessionLookup sm key
      result `shouldBe` Just sid

    it "insert replaces the session id for the same key" $ do
      sm <- newSessionMap
      let key = ConversationKey "telegram" "chat1"
          sid1 = mkSid "session1"
          sid2 = mkSid "session2"
      sessionInsert sm key sid1
      sessionInsert sm key sid2
      result <- sessionLookup sm key
      result `shouldBe` Just sid2

    it "different keys map to different sessions" $ do
      sm <- newSessionMap
      let key1 = ConversationKey "signal" "conv1"
          key2 = ConversationKey "signal" "conv2"
          sid1 = mkSid "session1"
          sid2 = mkSid "session2"
      sessionInsert sm key1 sid1
      sessionInsert sm key2 sid2
      r1 <- sessionLookup sm key1
      r2 <- sessionLookup sm key2
      r1 `shouldBe` Just sid1
      r2 `shouldBe` Just sid2

  describe "defaultGatewayConfig" $ do
    it "has localhost host" $
      gcHost defaultGatewayConfig `shouldBe` "127.0.0.1"

    it "has port 8080 for HTTP" $
      gcHttpPort defaultGatewayConfig `shouldBe` 8080

    it "has port 8081 for WS" $
      gcWsPort defaultGatewayConfig `shouldBe` 8081
