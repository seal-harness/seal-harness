{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.HttpClient' — the pure parsing functions.
-- Network-dependent tests (real HTTP requests) are guarded with
-- 'pendingWith' — they require a running gateway server.
module Seal.Channels.Chat.HttpClientSpec (spec) where

import Data.Aeson ((.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text (Text)
import Test.Hspec (Spec, describe, it, shouldBe, expectationFailure)

import Seal.Channels.Chat.HttpClient
  ( NewSessionResult (..)
  , SendResult (..)
  , answerBodyJson
  , mintBody
  , parseErrorBody
  , parseNewSessionResult
  , rebindBody
  , parseSendResult
  , setupRepoBody
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

  describe "answerBodyJson" $ do
    -- The server's parseAnswerBody rejects a body carrying BOTH answer and
    -- scope ("ambiguous"), so the request must send exactly one field.
    it "carries only the answer field" $
      answerBodyJson "green" `shouldBe` A.object ["answer" .= ("green" :: Text)]

    it "has no scope field" $
      case answerBodyJson "y" of
        A.Object o -> KeyMap.member (Key.fromText "scope") o `shouldBe` False
        _          -> expectationFailure "expected a JSON object"

  describe "TabJson" $ do
    it "has the expected fields" $ do
      let tab = TabJson { tjIndex = 3, tjSessionId = Just "sess123", tjKind = "session:ai", tjLabel = Just "my tab", tjStatus = Nothing }
      tjIndex tab `shouldBe` 3
      tjSessionId tab `shouldBe` Just "sess123"
      tjKind tab `shouldBe` "session:ai"
      tjLabel tab `shouldBe` Just "my tab"

  -- ── /new wire shapes (WU-7) ────────────────────────────────────────────
  describe "rebindBody" $ do
    it "sends every present override and omits absent ones (never null)" $
      rebindBody (Just "anthropic") (Just "claude") (Just "telegram")
        `shouldBe` A.object
          [ "provider" .= ("anthropic" :: Text)
          , "model" .= ("claude" :: Text)
          , "channel" .= ("telegram" :: Text) ]
    it "omits all three keys when there are no overrides" $
      rebindBody Nothing Nothing Nothing `shouldBe` A.object []

  describe "mintBody" $ do
    it "carries provider/model only — the gateway labels the session web" $
      mintBody (Just "anthropic") (Just "claude")
        `shouldBe` A.object
          [ "provider" .= ("anthropic" :: Text)
          , "model" .= ("claude" :: Text) ]
    it "is the empty object without overrides" $
      mintBody Nothing Nothing `shouldBe` A.object []

  describe "setupRepoBody" $ do
    it "is {url}" $
      setupRepoBody "git@github.com:o/r.git"
        `shouldBe` A.object ["url" .= ("git@github.com:o/r.git" :: Text)]

  describe "parseNewSessionResult" $ do
    it "parses the full gateway response" $
      parseNewSessionResult (A.encode (A.object
        [ "session_id" .= ("20260101-000000-001" :: Text)
        , "tab_index" .= (2 :: Int)
        , "rebound" .= True
        , "rebind_error" .= A.Null
        , "provider" .= ("anthropic" :: Text)
        , "model" .= ("claude" :: Text)
        ])) `shouldBe` Right NewSessionResult
          { nsrSessionId = "20260101-000000-001"
          , nsrTabIndex = Just 2
          , nsrRebound = True
          , nsrRebindError = Nothing
          , nsrProvider = "anthropic"
          , nsrModel = "claude"
          }
    it "reads a rebind_error string and a null tab_index" $
      parseNewSessionResult (A.encode (A.object
        [ "session_id" .= ("sid" :: Text)
        , "tab_index" .= A.Null
        , "rebound" .= False
        , "rebind_error" .= ("tab index out of range" :: Text)
        , "provider" .= ("p" :: Text)
        , "model" .= ("m" :: Text)
        ])) `shouldBe` Right NewSessionResult
          { nsrSessionId = "sid"
          , nsrTabIndex = Nothing
          , nsrRebound = False
          , nsrRebindError = Just "tab index out of range"
          , nsrProvider = "p"
          , nsrModel = "m"
          }
    it "rejects a response with no session_id" $
      parseNewSessionResult (A.encode (A.object []))
        `shouldBe` Left "new-session response missing 'session_id' field"
    it "rejects a non-object body" $
      parseNewSessionResult "[]"
        `shouldBe` Left "new-session response is not a JSON object"
    it "rejects an unparseable body" $
      parseNewSessionResult "not json"
        `shouldBe` Left "failed to parse new-session response JSON"

  describe "parseErrorBody" $ do
    it "prefers the gateway's {error} text" $
      parseErrorBody 409 (A.encode (A.object ["error" .= ("clone failed: denied" :: Text)]))
        `shouldBe` "clone failed: denied"
    it "falls back to HTTP <code> for a non-JSON body" $
      parseErrorBody 502 "bad gateway" `shouldBe` "HTTP 502"
    it "falls back to HTTP <code> for a JSON body without an error field" $
      parseErrorBody 404 (A.encode (A.object ["ok" .= False])) `shouldBe` "HTTP 404"
    it "falls back to HTTP <code> for an empty error string" $
      parseErrorBody 500 (A.encode (A.object ["error" .= ("" :: Text)]))
        `shouldBe` "HTTP 500"
