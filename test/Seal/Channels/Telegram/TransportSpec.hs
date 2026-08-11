{-# LANGUAGE OverloadedStrings #-}
module Seal.Channels.Telegram.TransportSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, chooseInt, elements, forAll, listOf1, (===))

import Seal.Channels.Telegram.Transport
  ( TelegramUpdate (..), chunkMessage, parseTelegramUpdate )
import Seal.Core.MessageSource (conversationIdText, userIdText)

spec :: Spec
spec = do
  describe "Seal.Channels.Telegram.Transport.parseTelegramUpdate" $ do
    it "parses a text message update" $ do
      let raw = object
            [ "update_id" .= (123 :: Int)
            , "message" .= object
                [ "chat" .= object [ "id" .= (123456789 :: Int) ]
                , "from" .= object [ "id" .= (111222333 :: Int) ]
                , "text" .= ("hello" :: Text)
                ]
            ]
      case parseTelegramUpdate raw of
        Right upd -> do
          tuChatId upd `shouldBe` "123456789"
          tuBody upd `shouldBe` "hello"
          conversationIdText (tuConversationId upd) `shouldBe` "tg:123456789"
          userIdText (tuSender upd) `shouldBe` "111222333"
        Left err -> expectationFailure ("unexpected Left: " <> T.unpack err)

    it "rejects an update with no message field" $ do
      let raw = object [ "update_id" .= (1 :: Int) ]
      parseTelegramUpdate raw `shouldSatisfy` isLeft

    it "rejects an update missing chat.id" $ do
      let raw = object
            [ "update_id" .= (1 :: Int)
            , "message" .= object
                [ "from" .= object [ "id" .= (1 :: Int) ]
                , "text" .= ("hi" :: Text)
                ]
            ]
      parseTelegramUpdate raw `shouldSatisfy` isLeft

    it "rejects an update missing from.id" $ do
      let raw = object
            [ "update_id" .= (1 :: Int)
            , "message" .= object
                [ "chat" .= object [ "id" .= (1 :: Int) ]
                , "text" .= ("hi" :: Text)
                ]
            ]
      parseTelegramUpdate raw `shouldSatisfy` isLeft

    it "yields empty body for a non-text message (sticker, photo)" $ do
      let raw = object
            [ "update_id" .= (1 :: Int)
            , "message" .= object
                [ "chat" .= object [ "id" .= (42 :: Int) ]
                , "from" .= object [ "id" .= (99 :: Int) ]
                ]
            ]
      case parseTelegramUpdate raw of
        Right upd -> tuBody upd `shouldBe` ""
        Left err  -> expectationFailure ("unexpected Left: " <> T.unpack err)

    it "parses a callback_query update with a String id" $ do
      -- Telegram's Bot API returns callback_query.id as a String (it can
      -- exceed Int64 range). This is the real-world shape.
      let raw = object
            [ "update_id" .= (100 :: Int)
            , "callback_query" .= object
                [ "id" .= ("371991640038127550" :: Text)
                , "from" .= object [ "id" .= (86611052 :: Int) ]
                , "message" .= object
                    [ "chat" .= object [ "id" .= (86611052 :: Int) ]
                    , "from" .= object [ "id" .= (8971756743 :: Int) ]
                    , "message_id" .= (1442 :: Int)
                    , "text" .= ("What's your favorite color?" :: Text)
                    ]
                , "data" .= ("ee457b5a:1" :: Text)
                ]
            ]
      case parseTelegramUpdate raw of
        Right upd -> do
          tuBody upd `shouldBe` "ee457b5a:1"
          tuCallbackData upd `shouldBe` Just "ee457b5a:1"
          tuCallbackId upd `shouldBe` Just "371991640038127550"
          tuCallbackMessageId upd `shouldBe` Just "1442"
          tuChatId upd `shouldBe` "86611052"
          conversationIdText (tuConversationId upd) `shouldBe` "tg:86611052"
          userIdText (tuSender upd) `shouldBe` "86611052"
        Left err -> expectationFailure ("unexpected Left: " <> T.unpack err)

    it "parses a callback_query update with a Number id (backward compat)" $ do
      let raw = object
            [ "update_id" .= (101 :: Int)
            , "callback_query" .= object
                [ "id" .= (37199164 :: Int)
                , "from" .= object [ "id" .= (86611052 :: Int) ]
                , "message" .= object
                    [ "chat" .= object [ "id" .= (86611052 :: Int) ]
                    , "from" .= object [ "id" .= (8971756743 :: Int) ]
                    , "message_id" .= (1442 :: Int)
                    ]
                , "data" .= ("deadbeef:0" :: Text)
                ]
            ]
      case parseTelegramUpdate raw of
        Right upd -> do
          tuCallbackId upd `shouldBe` Just "37199164"
          tuCallbackMessageId upd `shouldBe` Just "1442"
        Left err -> expectationFailure ("unexpected Left: " <> T.unpack err)

    it "rejects a callback_query missing the data field" $ do
      let raw = object
            [ "update_id" .= (102 :: Int)
            , "callback_query" .= object
                [ "id" .= ("123" :: Text)
                , "from" .= object [ "id" .= (86611052 :: Int) ]
                , "message" .= object
                    [ "chat" .= object [ "id" .= (86611052 :: Int) ]
                    , "from" .= object [ "id" .= (8971756743 :: Int) ]
                    ]
                ]
            ]
      parseTelegramUpdate raw `shouldSatisfy` isLeft

  describe "Seal.Channels.Telegram.Transport.chunkMessage" $ do
    it "empty input -> []" $
      chunkMessage 100 "" `shouldBe` []

    it "under-limit passes through as one chunk" $
      chunkMessage 100 "hello" `shouldBe` ["hello"]

    it "exact-limit passes through as one chunk" $
      chunkMessage 5 "hello" `shouldBe` ["hello"]

    it "hard-cuts a long line with no separators" $
      chunkMessage 3 "aaaaa" `shouldBe` ["aaa", "aa"]

    it "splits on paragraph boundary when \\n\\n fits within the limit" $
      chunkMessage 8 "hello\n\nworld" `shouldBe` ["hello\n\n", "world"]

    prop "concat . chunkMessage limit == id (chunks carry trailing sep, last has none)" $
      forAll (chooseInt (1, 40)) $ \limit ->
      forAll genChunkInput $ \t ->
        T.concat (chunkMessage limit t) === t

    prop "every chunk is non-empty and <= limit" $
      forAll (chooseInt (1, 40)) $ \limit ->
      forAll genChunkInput $ \t ->
        let chunks = chunkMessage limit t
        in all (\c -> not (T.null c) && T.length c <= limit) chunks

isLeft :: Either a b -> Bool
isLeft (Left _)  = True
isLeft (Right _) = False

genChunkInput :: Gen Text
genChunkInput = T.pack <$> listOf1 (elements (['a'..'z'] <> " \n"))