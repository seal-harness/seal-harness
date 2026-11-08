{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
module Seal.Transcript.ConvSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.Text (Text)
import Test.Hspec
import Test.QuickCheck

import Seal.Providers.Class
  ( ContentBlock (..), Message (msgOrigin), pattern Message, MessageOrigin (..), Role (..) )
import Seal.TestHelpers.Arbitrary ()
import Seal.Transcript.Conv

-- | Encode one message as a conversation line (no trailing newline).
encodeMsg :: Message -> ByteString
encodeMsg m = encodeConvLine (ConvLine m)

-- | Write a list of messages as a conversation file body: one JSON line per
-- message, newline-terminated.
roundTripBody :: [Message] -> ByteString
roundTripBody msgs =
  BS8.intercalate "\n" (map ((<> "\n") . encodeMsg) msgs)

-- | Append @new@ to @written@, encode the full conversation, then read it back.
appendAndRead :: [Message] -> [Message] -> [Message]
appendAndRead written new =
  readConversation (roundTripBody (appendMessages written new))

textMsgSimple :: Text -> Message
textMsgSimple t = Message User [CbText t]

-- | Drop every origin, so a property can state "nothing to render, nothing
-- changes" over arbitrary messages.
stripOrigins :: [Message] -> [Message]
stripOrigins = map (\m -> m { msgOrigin = Nothing })

spec :: Spec
spec = describe "Seal.Transcript.Conv" $ do
  describe "diffNew" $ do
    it "returns the suffix beyond the written prefix" $
      property $ \written new ->
        diffNew (written <> new) written === new

    it "returns the whole incoming when written is empty" $
      property $ \incoming ->
        diffNew incoming [] === incoming

    it "returns the whole incoming when written is not a prefix (divergence fallback)" $
      property $ \m1 m2 ->
        m1 /= m2 ==>
          diffNew [m2] [m1] === [m2]

  describe "appendMessages" $
    it "concatenates written and new" $
      property $ \written new ->
        appendMessages written new === written <> new

  describe "readConversation . roundTripBody" $ do
    it "round-trips a message list" $
      property $ \msgs ->
        readConversation (roundTripBody msgs) === msgs

    it "skips malformed trailing lines (torn tail)" $ do
      let good = roundTripBody [textMsgSimple "hi"]
          body = good <> "{not json}\n"
      readConversation body `shouldBe` [textMsgSimple "hi"]

    it "reading an empty file yields no messages" $
      readConversation "" `shouldBe` []

  describe "message origin" $ do
    it "survives the round-trip through a conversation line" $ do
      -- The origin travels with the message: the writer encodes whatever
      -- 'Message' it is handed, so per-message provenance needs no extra
      -- column in entries.jsonl.
      let m = (textMsgSimple "hi")
                { msgOrigin = Just (MessageOrigin "signal" (Just "+15551234567")
                                     (Just "sig:+15551234567:abc") Nothing Nothing) }
      readConversation (roundTripBody [m]) `shouldBe` [m]

    it "keeps messages without an origin origin-less" $
      property $ \msgs ->
        readConversation (roundTripBody (stripOrigins msgs))
          === stripOrigins msgs

  describe "end-to-end write-then-read" $
    it "writing the diff then reading back equals the full conversation" $
      property $ \written new ->
        appendAndRead written new === (written <> new)
