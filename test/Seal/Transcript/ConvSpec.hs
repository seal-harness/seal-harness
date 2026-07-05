{-# LANGUAGE OverloadedStrings #-}
module Seal.Transcript.ConvSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.Text (Text)
import Test.Hspec
import Test.QuickCheck

import Seal.Providers.Class (ContentBlock (..), Message (..), Role (..))
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

  describe "end-to-end write-then-read" $
    it "writing the diff then reading back equals the full conversation" $
      property $ \written new ->
        appendAndRead written new === (written <> new)