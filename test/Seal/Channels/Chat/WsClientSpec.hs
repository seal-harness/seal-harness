{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.WsClient' and the 'decodeServerEvent'
-- function from 'Seal.Gateway.Types.Stream'. Tests the pure decoding of
-- WS wire frames into 'ServerEvent' values — network-dependent tests
-- (real WS connections) are guarded with 'pendingWith'.
module Seal.Channels.Chat.WsClientSpec (spec) where

import Data.Aeson (Value, (.=))
import Data.Maybe (isNothing)
import Data.Aeson.Types (Pair)
import Data.Aeson qualified as A
import Data.ByteString.Lazy (ByteString)
import Data.Text (Text)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Seal.Gateway.Types.Core (SessionId, mkSessionId)
import Seal.Gateway.Types.Stream
  ( ServerEvent (..)
  , StreamErrorCode (..)
  , FocusOp (..)
  , decodeServerEvent
  )

-- | Helper: make a 'SessionId' for testing (crashes on invalid — test-only).
mkSid :: Text -> SessionId
mkSid t = case mkSessionId t of
  Right s -> s
  Left e  -> error ("test mkSid: " <> show e)

-- | Helper: encode a JSON object to lazy bytestring (simulates a WS frame).
encodeFrame :: [Pair] -> ByteString
encodeFrame = A.encode . A.object

spec :: Spec
spec = do
  describe "decodeServerEvent" $ do
    it "decodes a hello event" $
      decodeServerEvent (encodeFrame
        [ "type" .= ("hello" :: Text)
        , "protocolVersion" .= ("v1" :: Text)
        , "serverStartedAt" .= ("2024-01-01T00:00:00Z" :: Text)
        ]) `shouldBe` Just (SeHello "v1" "2024-01-01T00:00:00Z")

    it "decodes an entry event" $
      let sid = "mySession"
      in decodeServerEvent (encodeFrame
        [ "type" .= ("entry" :: Text)
        , "sessionId" .= sid
        , "entry" .= A.object ["id" .= ("0" :: Text)]
        ]) `shouldSatisfy` \case
        Just (SeEntry s _) -> s == mkSid sid
        _ -> False

    it "decodes an entry-update event" $
      let sid = "mySession"
      in decodeServerEvent (encodeFrame
        [ "type" .= ("entry-update" :: Text)
        , "sessionId" .= sid
        , "entry" .= A.object ["id" .= ("0" :: Text)]
        ]) `shouldSatisfy` \case
        Just (SeEntryUpdate s _) -> s == mkSid sid
        _ -> False

    it "decodes an activity event" $
      let sid = "mySession"
      in decodeServerEvent (encodeFrame
        [ "type" .= ("activity" :: Text)
        , "sessionId" .= sid
        , "activity" .= A.object ["kind" .= ("harness-status" :: Text)]
        ]) `shouldSatisfy` \case
        Just (SeActivity s _) -> s == mkSid sid
        _ -> False

    it "decodes a replay-end event" $
      let sid = "mySession"
      in decodeServerEvent (encodeFrame
        [ "type" .= ("replay-end" :: Text)
        , "sessionId" .= sid
        , "lastEntryId" .= ("42" :: Text)
        ]) `shouldSatisfy` \case
        Just (SeReplayEnd s mLast) -> s == mkSid sid && mLast == Just "42"
        _ -> False

    it "decodes a replay-end event without lastEntryId" $
      let sid = "mySession"
      in decodeServerEvent (encodeFrame
        [ "type" .= ("replay-end" :: Text)
        , "sessionId" .= sid
        ]) `shouldSatisfy` \case
        Just (SeReplayEnd s mLast) -> s == mkSid sid && isNothing mLast
        _ -> False

    it "decodes a lists event" $
      decodeServerEvent (encodeFrame
        [ "type" .= ("lists" :: Text)
        , "tabs" .= ([] :: [Value])
        ]) `shouldSatisfy` \case
        Just SeLists{} -> True
        _ -> False

    it "decodes an ask event" $
      let sid = "mySession"
      in decodeServerEvent (encodeFrame
        [ "type" .= ("ask" :: Text)
        , "sessionId" .= sid
        , "ask" .= A.object ["id" .= ("q1" :: Text)]
        ]) `shouldSatisfy` \case
        Just (SeAsk s _) -> s == mkSid sid
        _ -> False

    it "decodes an ask_resolved event" $
      let sid = "mySession"
      in decodeServerEvent (encodeFrame
        [ "type" .= ("ask_resolved" :: Text)
        , "sessionId" .= sid
        , "ask" .= A.object ["id" .= ("q1" :: Text)]
        ]) `shouldSatisfy` \case
        Just (SeAskResolved s _) -> s == mkSid sid
        _ -> False

    it "decodes agent-defs-changed" $
      decodeServerEvent (encodeFrame
        [ "type" .= ("agent-defs-changed" :: Text)
        ]) `shouldBe` Just SeAgentDefsChanged

    it "decodes skills-changed" $
      decodeServerEvent (encodeFrame
        [ "type" .= ("skills-changed" :: Text)
        ]) `shouldBe` Just SeSkillsChanged

    it "decodes repos-changed" $
      decodeServerEvent (encodeFrame
        [ "type" .= ("repos-changed" :: Text)
        ]) `shouldBe` Just SeReposChanged

    it "decodes an error event" $
      decodeServerEvent (encodeFrame
        [ "type" .= ("error" :: Text)
        , "code" .= ("invalid-op" :: Text)
        , "message" .= ("bad focus" :: Text)
        ]) `shouldBe` Just (SeError SecInvalidOp "bad focus")

    it "returns Nothing for unknown type" $
      decodeServerEvent (encodeFrame
        [ "type" .= ("unknown" :: Text)
        ]) `shouldBe` Nothing

    it "returns Nothing for invalid JSON" $
      decodeServerEvent "not json" `shouldBe` Nothing

  describe "FocusOp ToJSON" $ do
    it "encodes a focus op without since" $
      let op = FocusOp "mysession" Nothing
          encoded = A.encode op
      in encoded `shouldBe` "{\"op\":\"focus\",\"sessionId\":\"mysession\"}"

    it "encodes a focus op with since" $
      let op = FocusOp "mysession" (Just "42")
          encoded = A.encode op
      in encoded `shouldBe` "{\"op\":\"focus\",\"sessionId\":\"mysession\",\"since\":\"42\"}"
