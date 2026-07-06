{-# LANGUAGE OverloadedStrings #-}
module Seal.Tabs.RelaySpec (spec) where

import Test.Hspec

import Seal.Tabs.Relay
import Seal.Tabs.Types

spec :: Spec
spec = describe "Seal.Tabs.Relay.relayEvent" $ do
  describe "FocusedOnly" $ do
    it "StreamStart -> [] (no framing)" $
      relayEvent FocusedOnly (StreamStart "header") `shouldBe` []
    it "ChunkOf t -> [t] (verbatim)" $
      relayEvent FocusedOnly (ChunkOf "hi") `shouldBe` ["hi"]
    it "StreamEnd -> []" $
      relayEvent FocusedOnly StreamEnd `shouldBe` []

  describe "ActivityDigest" $ do
    it "StreamStart -> [] (suppress)" $
      relayEvent ActivityDigest (StreamStart "header") `shouldBe` []
    it "ChunkOf t -> [] (suppress)" $
      relayEvent ActivityDigest (ChunkOf "hi") `shouldBe` []
    it "StreamEnd -> [breadcrumb] (one ping per burst)" $ do
      let out = relayEvent ActivityDigest StreamEnd
      out `shouldSatisfy` (not . null)
      length out `shouldBe` 1

  describe "Firehose" $ do
    it "forwards every event (including framing)" $ do
      relayEvent Firehose (ChunkOf "hi") `shouldSatisfy` (not . null)
      relayEvent Firehose (StreamStart "h") `shouldSatisfy` (not . null)
      relayEvent Firehose StreamEnd `shouldSatisfy` (not . null)