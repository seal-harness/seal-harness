{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.Telegram' — the Telegram chat-channel adapter.
module Seal.Channels.Chat.TelegramAdapterSpec (spec) where

import Control.Concurrent (threadDelay)
import Data.IORef (newIORef, modifyIORef', readIORef)
import Data.Maybe (isJust)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Seal.Channels.Chat.Class (ChatChannel (..), ProgressStyle (..))
import Seal.Channels.Chat.Telegram
  ( TelegramChatTransport (..)
  , withTelegramChatChannel
  , mkMockTelegramChatTransport
  , chunkMessage
  )
import Seal.Channels.Chat.Types (InboundMessage (..), ChatMessageId (..), ReceivedMessage (..))
import Seal.Gateway.Types.MessageSource (mkConversationId)
import Seal.Gateway.Types.AllowList (AllowList (..))

-- | A dummy received message for seeding the last-chat id in tests.
dummyMsg :: ReceivedMessage
dummyMsg = ReceivedMessage
  { rmConversationId = case mkConversationId "tg:test" of Right c -> c; Left _ -> error "bad cid"
  , rmSender = Just "123"
  , rmReplyTo = "test-chat"
  , rmBody = "init"
  , rmCallbackData = Nothing
  , rmCallbackId = Nothing
  , rmCallbackMessageId = Nothing
  }

-- | Wait briefly for the reader thread to process the seed message.
waitForSeed :: IO ()
waitForSeed = threadDelay 50000  -- 50ms

-- | Test backoff: 1ms — keeps the retry test sub-second.
testBackoff :: Int
testBackoff = 1000

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
      (transport, _, _) <- mkMockTelegramChatTransport [dummyMsg]
      withTelegramChatChannel AllowAll 1000 testBackoff transport $ \ch -> do
        ccLabel ch `shouldBe` "telegram"

    it "opts into the single-edited-bubble style" $ do
      -- One message per turn, edited in place. On Telegram an edit does not
      -- notify, so this is what turns a 5-tool turn from ~6 pushes into one.
      (transport, _, _) <- mkMockTelegramChatTransport [dummyMsg]
      withTelegramChatChannel AllowAll 1000 testBackoff transport $ \ch ->
        ccProgressStyle ch `shouldBe` PsSingleBubble

    it "reports the configured chunk limit" $ do
      -- Without this the single-bubble path cannot tell when its body has
      -- outgrown one message, and keeps editing until the platform rejects it.
      (transport, _, _) <- mkMockTelegramChatTransport [dummyMsg]
      withTelegramChatChannel AllowAll 1234 testBackoff transport $ \ch ->
        ccChunkLimit ch `shouldBe` Just 1234

    it "sends a progress bubble silently, returning an editable id" $ do
      -- A progress bubble must not ping the human: that is what makes a tool
      -- turn notify exactly once (the answer).
      (transport, getCaptured, _) <- mkMockTelegramChatTransport [dummyMsg]
      withTelegramChatChannel AllowAll 1000 testBackoff transport $ \ch -> do
        waitForSeed
        -- Seed the last chat id via a normal send first.
        _ <- ccSendWithId ch "seed"
        sent <- getCaptured
        sent `shouldSatisfy` const True
        mId <- ccSendWithIdSilently ch "progress"
        case mId of
          Just (ChatMessageId _) -> pure ()
          Nothing -> fail "expected the silent send to return an id"

    it "sends messages via the transport" $ do
      (transport, getCaptured, _) <- mkMockTelegramChatTransport [dummyMsg]
      withTelegramChatChannel AllowAll 1000 testBackoff transport $ \ch -> do
        waitForSeed
        ccSend ch "hello world"
        captured <- getCaptured
        captured `shouldBe` ["hello world"]

    it "sends with id and returns a ChatMessageId" $ do
      (transport, _, _) <- mkMockTelegramChatTransport [dummyMsg]
      withTelegramChatChannel AllowAll 1000 testBackoff transport $ \ch -> do
        waitForSeed
        mId <- ccSendWithId ch "test"
        case mId of
          Just (ChatMessageId _) -> pure ()
          Nothing -> fail "expected a message id"

    it "edits messages via the transport" $ do
      (transport, _, _) <- mkMockTelegramChatTransport [dummyMsg]
      withTelegramChatChannel AllowAll 1000 testBackoff transport $ \ch -> do
        waitForSeed
        ok <- ccEditMessage ch (ChatMessageId "123") "new content"
        ok `shouldBe` True

    it "chunks long sends" $ do
      (transport, getCaptured, _) <- mkMockTelegramChatTransport [dummyMsg]
      withTelegramChatChannel AllowAll 5 testBackoff transport $ \ch -> do
        waitForSeed
        ccSend ch "abcdefghij"
        captured <- getCaptured
        captured `shouldBe` ["abcde", "fghij"]

  describe "reader loop retry" $ do
    it "retries after a transient error and delivers subsequent messages" $ do
      -- The reader loop must NOT die on a transient error (Left from
      -- tctReceive).  It should log, back off, and retry — eventually
      -- delivering messages that arrive after the error.
      callCount <- newIORef (0 :: Int)
      let transport = TelegramChatTransport
            { tctReceive = do
                n <- readIORef callCount
                modifyIORef' callCount (+1)
                case n of
                  0 -> pure (Left "transient network error")
                  1 -> pure (Right dummyMsg)
                  _ -> pure (Left "inbox empty")
            , tctSend = \_c _b -> pure ()
            , tctSendWithId = \_c _b -> pure (Just "1")
            , tctSendWithIdSilently = \_c _b -> pure (Just "1")
            , tctSendWithKeyboard = \_c _b _kb -> pure (Just "1")
            , tctAnswerCallback = \_ -> pure ()
            , tctEditReplyMarkup = \_c _mid -> pure ()
            , tctEditMessage = \_c _mid _content -> pure True
            , tctClose = pure ()
            }
      withTelegramChatChannel AllowAll 1000 testBackoff transport $ \ch -> do
        -- ccReceive blocks until a message arrives or the reader dies.
        -- With the fix, the reader retries after the transient error
        -- and pushes dummyMsg to the inbox.  Without the fix, the reader
        -- would set alive=False and ccReceive would return Nothing.
        mMsg <- ccReceive ch
        mMsg `shouldSatisfy` isJust
        case mMsg of
          Just (InboundMessage _ body _) -> body `shouldBe` "init"
          Nothing -> fail "expected a message after retry"

    it "does not die on repeated transient errors" $ do
      -- Even after multiple consecutive errors, the reader should still
      -- be alive and deliver a message once one becomes available.
      callCount <- newIORef (0 :: Int)
      let transport = TelegramChatTransport
            { tctReceive = do
                n <- readIORef callCount
                modifyIORef' callCount (+1)
                if n < 3
                  then pure (Left "transient error")
                  else if n == 3 then pure (Right dummyMsg) else pure (Left "inbox empty")
            , tctSend = \_c _b -> pure ()
            , tctSendWithId = \_c _b -> pure (Just "1")
            , tctSendWithIdSilently = \_c _b -> pure (Just "1")
            , tctSendWithKeyboard = \_c _b _kb -> pure (Just "1")
            , tctAnswerCallback = \_ -> pure ()
            , tctEditReplyMarkup = \_c _mid -> pure ()
            , tctEditMessage = \_c _mid _content -> pure True
            , tctClose = pure ()
            }
      withTelegramChatChannel AllowAll 1000 testBackoff transport $ \ch -> do
        mMsg <- ccReceive ch
        mMsg `shouldSatisfy` isJust
        case mMsg of
          Just (InboundMessage _ body _) -> body `shouldBe` "init"
          Nothing -> fail "expected a message after repeated retries"
