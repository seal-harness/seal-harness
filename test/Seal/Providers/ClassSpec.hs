{-# LANGUAGE OverloadedStrings #-}
-- | Round-trip properties for the provider-agnostic message model, plus the
-- on-disk shape of a message's origin (a @conversation.jsonl@ line).
module Seal.Providers.ClassSpec (spec) where

import Data.Aeson (Value (..), decode, encode, toJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck ((===))

import Seal.Providers.Class
import Seal.TestHelpers.Arbitrary ()

-- | A user message that arrived from Telegram user 12345.
telegramMessage :: Message
telegramMessage = (textMsg User "hi")
  { msgOrigin = Just (MessageOrigin "telegram" (Just "12345") (Just "tg:12345")) }

-- | Look up a key in a JSON object.
field :: Key.Key -> Value -> Maybe Value
field k (Object o) = KeyMap.lookup k o
field _ _          = Nothing

spec :: Spec
spec = describe "Seal.Providers.Class" $ do
  prop "Message round-trips" $ \m ->
    decode (encode (m :: Message)) === Just m
  prop "CompletionResponse round-trips" $ \r ->
    decode (encode (r :: CompletionResponse)) === Just r

  describe "Message origin on the wire" $ do
    it "adds no origin key when the message has none" $
      -- The on-disk shape for web/CLI turns is unchanged, so an older
      -- conversation.jsonl and a new one stay byte-compatible.
      field "origin" (toJSON (textMsg User "hi")) `shouldBe` Nothing

    it "carries channel, sender, and conversation id when present" $ do
      let origin = field "origin" (toJSON telegramMessage)
      field "channel" <$> origin `shouldBe` Just (Just (String "telegram"))
      field "userId" <$> origin `shouldBe` Just (Just (String "12345"))
      field "conversationId" <$> origin
        `shouldBe` Just (Just (String "tg:12345"))

    it "omits absent origin fields instead of emitting nulls" $ do
      let m = (textMsg User "hi") { msgOrigin = Just (MessageOrigin "signal" Nothing Nothing) }
          origin = field "origin" (toJSON m)
      field "userId" <$> origin `shouldBe` Just Nothing
      field "conversationId" <$> origin `shouldBe` Just Nothing

    it "decodes a conversation line written before origins existed" $
      decode "{\"role\":\"User\",\"content\":[{\"tag\":\"CbText\",\"contents\":\"hi\"}]}"
        `shouldBe` Just (textMsg User "hi")
