{-# LANGUAGE OverloadedStrings #-}
module Seal.Channels.TelegramSpec (spec) where

import Control.Exception (catch)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.Channels.Class (Channel (..))
import Seal.Channels.Telegram (withTelegramChannel)
import Seal.Channels.Telegram.Transport
  ( TelegramUpdate (..), mkMockTelegramTransport )
import Seal.Core.AllowList (AllowList (..))
import Seal.Core.ChannelKind (ChannelKind (..))
import Seal.Core.MessageSource
  ( conversationIdText, mkConversationId, mkUserId
  , msChannelKind, msConversationId )
import Seal.Handles.Channel (ChannelHandle (..), Deferral (..))

chatId1 :: Text
chatId1 = "123456789"
senderId1 :: Text
senderId1 = "111222333"

mkTestUpdate :: Text -> Text -> Text -> TelegramUpdate
mkTestUpdate chatId senderId body =
  let cid = case mkConversationId ("tg:" <> chatId) of
        Right c -> c
        Left e  -> error ("mkConversationId: " <> T.unpack e)
      uid = case mkUserId senderId of
        Right u -> u
        Left e  -> error ("mkUserId: " <> T.unpack e)
  in TelegramUpdate
       { tuConversationId = cid
       , tuChatId          = chatId
       , tuSender          = uid
       , tuBody            = body
       }

spec :: Spec
spec = describe "Seal.Channels.Telegram" $ do
  it "withTelegramChannel + chReceive yields scripted updates with the right MessageSource" $ do
    let upd1 = mkTestUpdate chatId1 senderId1 "hello"
        upd2 = mkTestUpdate chatId1 senderId1 "/ping"
    (transport, _, _) <- mkMockTelegramTransport [upd1, upd2]
    withTelegramChannel (AllowAll, 3900) transport $ \ch -> do
      let h = toHandle ch
      (m1, t1) <- chReceive h
      (_, t2)  <- chReceive h
      t1 `shouldBe` "hello"
      t2 `shouldBe` "/ping"
      case m1 of
        Nothing -> expectationFailure "expected MessageSource for upd1"
        Just ms -> do
          msChannelKind ms `shouldBe` Telegram
          conversationIdText (msConversationId ms) `shouldBe` "tg:123456789"

  it "chSend chunks a long message to the configured limit and sends to the last chat" $ do
    let longMsg = T.replicate 25 "a"
        upd1 = mkTestUpdate chatId1 senderId1 "x"
    (transport, getCaptured, _) <- mkMockTelegramTransport [upd1]
    withTelegramChannel (AllowAll, 10) transport $ \ch -> do
      let h = toHandle ch
      _ <- chReceive h  -- primes the last-chat id
      chSend h longMsg
      sent <- getCaptured
      length sent `shouldBe` 3  -- 25 chars / 10 = 3 chunks
      all (\(_, b) -> T.length b <= 10) sent `shouldBe` True

  it "chSend with no last chat is dropped (capture empty)" $ do
    (transport, getCaptured, _) <- mkMockTelegramTransport []
    withTelegramChannel (AllowAll, 3900) transport $ \ch -> do
      let h = toHandle ch
      chSend h "hello"
      sent <- getCaptured
      sent `shouldBe` []

  it "a non-allow-listed sender is dropped (never reaches chReceive)" $ do
    let upd1 = mkTestUpdate chatId1 senderId1 "hello"
        blockedSender = case mkUserId "999" of
          Right u -> u
          Left _  -> error "mkUserId failed"
        allow = AllowOnly (Set.fromList [blockedSender])
    (transport, _, _) <- mkMockTelegramTransport [upd1]
    withTelegramChannel (allow, 3900) transport $ \ch -> do
      let h = toHandle ch
      -- The reader drops the non-allow-listed update; the mock queue
      -- drains and the reader exits. chReceive returns EOF.
      (mSrc, _) <- chReceive h `catch` \(_e :: IOError) -> pure (Nothing, "")
      mSrc `shouldBe` Nothing

  it "chPrompt returns Left Deferred (Telegram can't answer inline)" $ do
    (transport, _, _) <- mkMockTelegramTransport []
    withTelegramChannel (AllowAll, 3900) transport $ \ch -> do
      let h = toHandle ch
      result <- chPrompt h "question?"
      result `shouldBe` Left Deferred

  it "chStreaming is True for Telegram" $ do
    (transport, _, _) <- mkMockTelegramTransport []
    withTelegramChannel (AllowAll, 3900) transport $ \ch -> do
      let h = toHandle ch
      chStreaming h `shouldBe` True