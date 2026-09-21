{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.HttpClient' — the pure parsing functions.
-- Network-dependent tests (real HTTP requests) are guarded with
-- 'pendingWith' — they require a running gateway server.
module Seal.Channels.Chat.HttpClientSpec (spec) where

import Data.Aeson ((.=))
import Data.Aeson qualified as A
import Data.Text (Text)
import Test.Hspec (Spec, describe, it, shouldBe)

import Seal.Channels.Chat.HttpClient
  ( SendResult (..)
  , parseSendResult
  , TabJson (..)
  , parseJsonBody
  )

spec :: Spec
spec = do
  describe "parseSendResult" $ do
    it "parses an assistant response" $
      parseSendResult (A.encode (A.object
        [ "kind" .= ("assistant" :: Text)
        , "response" .= ("" :: Text)
        ])) `shouldBe` Right SendResult
          { srKind = "assistant"
          , srResponse = ""
          , srSessionId = Nothing
          , srError = Nothing
          }

    it "parses a slash response with text" $
      parseSendResult (A.encode (A.object
        [ "kind" .= ("slash" :: Text)
        , "response" .= ("tab 0  session:ai" :: Text)
        ])) `shouldBe` Right SendResult
          { srKind = "slash"
          , srResponse = "tab 0  session:ai"
          , srSessionId = Nothing
          , srError = Nothing
          }

    it "parses a slash response with session_id (from /new)" $
      parseSendResult (A.encode (A.object
        [ "kind" .= ("slash" :: Text)
        , "response" .= ("new session abc123" :: Text)
        , "session_id" .= ("abc123" :: Text)
        ])) `shouldBe` Right SendResult
          { srKind = "slash"
          , srResponse = "new session abc123"
          , srSessionId = Just "abc123"
          , srError = Nothing
          }

    it "parses an error response" $
      parseSendResult (A.encode (A.object
        [ "error" .= ("session not found" :: Text)
        ])) `shouldBe` Right SendResult
          { srKind = ""
          , srResponse = ""
          , srSessionId = Nothing
          , srError = Just "session not found"
          }

    it "returns Left for invalid JSON" $
      parseSendResult "not json" `shouldBe` Left "failed to parse send response JSON"

  describe "parseJsonBody" $ do
    it "parses valid JSON" $
      parseJsonBody "{\"key\": \"value\"}" `shouldBe`
        Right (A.object ["key" .= ("value" :: Text)])

    it "returns Left for invalid JSON" $
      parseJsonBody "not json" `shouldBe` Left "failed to parse JSON"

  describe "TabJson" $ do
    it "has the expected fields" $ do
      let tab = TabJson { tjIndex = 3, tjSessionId = Just "sess123", tjKind = "session:ai", tjLabel = Just "my tab" }
      tjIndex tab `shouldBe` 3
      tjSessionId tab `shouldBe` Just "sess123"
      tjKind tab `shouldBe` "session:ai"
      tjLabel tab `shouldBe` Just "my tab"
