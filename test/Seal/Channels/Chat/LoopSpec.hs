{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.Loop' — the generic chat-channel loop.
-- Tests the pure helper functions (extractEntryText, extractActivityKind,
-- etc.) and the loop behavior with a mock channel.
module Seal.Channels.Chat.LoopSpec (spec) where

import Data.Vector qualified as V
import Data.Aeson ((.=))
import Data.Aeson qualified as A
import Data.Text (Text)
import Test.Hspec (Spec, describe, it, shouldBe)

import Seal.Channels.Chat.Loop

spec :: Spec
spec = do
  describe "extractEntryText" $ do
    it "extracts text from a payload with content array" $ do
      let val = A.object
            [ "payload" .= A.object
                [ "content" .= A.Array (V.fromList
                    [ A.object ["text" .= ("hello " :: Text), "type" .= ("text" :: Text)]
                    , A.object ["text" .= ("world" :: Text), "type" .= ("text" :: Text)]
                ])
                ]
            ]
      extractEntryText val `shouldBe` "hello world"

    it "extracts text from a payload with string content" $ do
      let val = A.object
            [ "payload" .= A.object ["content" .= ("just text" :: Text)]
            ]
      extractEntryText val `shouldBe` "just text"

    it "returns empty for missing payload" $ do
      let val = A.object ["other" .= ("stuff" :: Text)]
      extractEntryText val `shouldBe` ""

    it "returns empty for non-object" $ do
      extractEntryText (A.String "not an object") `shouldBe` ""

  describe "extractActivityKind" $ do
    it "extracts the kind field" $ do
      let val = A.object ["kind" .= ("harness-status" :: Text), "status" .= ("idle" :: Text)]
      extractActivityKind val `shouldBe` "harness-status"

    it "returns empty for missing kind" $ do
      let val = A.object ["status" .= ("idle" :: Text)]
      extractActivityKind val `shouldBe` ""

  describe "extractActivityStatus" $ do
    it "extracts the status field" $ do
      let val = A.object ["kind" .= ("harness-status" :: Text), "status" .= ("thinking" :: Text)]
      extractActivityStatus val `shouldBe` "thinking"

    it "returns empty for missing status" $ do
      let val = A.object ["kind" .= ("harness-status" :: Text)]
      extractActivityStatus val `shouldBe` ""

  describe "extractAskQuestion" $ do
    it "extracts the question field" $ do
      let val = A.object ["id" .= ("q1" :: Text), "question" .= ("Do you want to proceed?" :: Text)]
      extractAskQuestion val `shouldBe` "Do you want to proceed?"

    it "returns empty for missing question" $ do
      let val = A.object ["id" .= ("q1" :: Text)]
      extractAskQuestion val `shouldBe` ""

  describe "lastAssistantText" $ do
    it "extracts the last response entry's text" $ do
      let entries =
            [ A.object ["direction" .= ("request" :: Text), "payload" .= A.object ["content" .= ("hi" :: Text)]]
            , A.object ["direction" .= ("response" :: Text), "payload" .= A.object ["content" .= ("hello!" :: Text)]]
            , A.object ["direction" .= ("request" :: Text), "payload" .= A.object ["content" .= ("bye" :: Text)]]
            ]
      lastAssistantText entries `shouldBe` Just "hello!"

    it "returns Nothing when no response entries" $ do
      let entries =
            [ A.object ["direction" .= ("request" :: Text), "payload" .= A.object ["content" .= ("hi" :: Text)]]
            ]
      lastAssistantText entries `shouldBe` (Nothing :: Maybe Text)

    it "returns Nothing for empty list" $ do
      lastAssistantText [] `shouldBe` (Nothing :: Maybe Text)
