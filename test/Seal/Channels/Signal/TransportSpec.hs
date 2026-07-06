{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Seal.Channels.Signal.TransportSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Aeson (Value (..))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Channels.Signal.Transport

-- ---------------------------------------------------------------------------
-- chunkMessage
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "Seal.Channels.Signal.Transport.chunkMessage" $ do
    it "empty input -> []" $ chunkMessage 10 "" `shouldBe` []
    it "under-limit passes through as one chunk" $ chunkMessage 5 "abc" `shouldBe` ["abc"]
    it "exact-limit passes through as one chunk" $ chunkMessage 3 "abc" `shouldBe` ["abc"]
    it "hard-cuts a long line with no separators" $
      chunkMessage 3 "abcdef" `shouldBe` ["abc", "def"]
    it "splits on paragraph boundary when the \\n\\n fits within the limit" $
      chunkMessage 8 "para1\n\npara2"
        `shouldBe` ["para1\n\n", "para2"]
    it "splits on line boundary when over-limit and no paragraph fits, chunk keeps trailing \\n (except last)" $
      chunkMessage 6 "line1\nline2"
        `shouldBe` ["line1\n", "line2"]
    it "prefers paragraph over line boundary when a split is forced and both fit within the limit" $
      chunkMessage 5 "a\n\nb\nc" `shouldBe` ["a\n\n", "b\nc"]
    it "hard-cut when a single paragraph exceeds the limit" $
      chunkMessage 4 "aaaaaa\n\nb" `shouldBe` ["aaaa", "aa\n\n", "b"]
    it "under-limit with separators stays as one chunk (no unnecessary split)" $
      chunkMessage 100 "para1\n\npara2" `shouldBe` ["para1\n\npara2"]

    prop "concat . chunkMessage limit == id (chunks carry trailing sep, last has none)" $
      forAll (chooseInt (1, 40)) $ \limit ->
      forAll genChunkInput $ \t ->
        T.concat (chunkMessage limit t) === t

    prop "every chunk is non-empty and <= limit" $
      forAll (chooseInt (1, 40)) $ \limit ->
      forAll genChunkInput $ \t ->
        let chunks = chunkMessage limit t
        in all (\c -> not (T.null c) && T.length c <= limit) chunks

    prop "covers every character (concat length == input length)" $
      forAll (chooseInt (1, 40)) $ \limit ->
      forAll genChunkInput $ \t ->
        sum (map T.length (chunkMessage limit t)) === T.length t

  describe "mkMockSignalTransport" $ do
    it "stReceive pops scripted values in order, then Left 'inbox empty'" $ do
      (t, _) <- mkMockSignalTransport [String "first", String "second"]
      r1 <- stReceive t
      r2 <- stReceive t
      r3 <- stReceive t
      r1 `shouldBe` Right (String "first")
      r2 `shouldBe` Right (String "second")
      case r3 of
        Left e  -> T.unpack e `shouldContain` "empty"
        Right _ -> expectationFailure "expected Left on empty inbox"

    it "stSend captures (recipient, body) pairs in order" $ do
      (t, getCaptured) <- mkMockSignalTransport []
      stSend t "+1" "hello"
      stSend t "+2" "world"
      cap <- getCaptured
      cap `shouldBe` [("+1", "hello"), ("+2", "world")]

    it "stClose is idempotent" $ do
      (t, _) <- mkMockSignalTransport []
      stClose t
      stClose t  -- must not throw

-- ---------------------------------------------------------------------------
-- Generators
-- ---------------------------------------------------------------------------

-- | Input with a mix of plain chars, line breaks, and paragraph breaks.
genChunkInput :: Gen Text
genChunkInput = T.pack <$> listOf1 (elements (['a'..'z'] <> " \n"))