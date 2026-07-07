{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Seal.Core.ChannelKindSpec (spec) where

import Data.Aeson (decode, encode)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Core.ChannelKind

spec :: Spec
spec = describe "Seal.Core.ChannelKind" $ do
  describe "channelKindToText" $ do
    it "Cli -> cli"      $ channelKindToText Cli      `shouldBe` "cli"
    it "Web -> web"      $ channelKindToText Web      `shouldBe` "web"
    it "Signal -> signal" $ channelKindToText Signal  `shouldBe` "signal"
    it "Telegram -> telegram" $ channelKindToText Telegram `shouldBe` "telegram"
    it "Background -> background" $ channelKindToText Background `shouldBe` "background"
    it "Other -> other"  $ channelKindToText Other    `shouldBe` "other"

  describe "channelKindFromText" $ do
    it "parses lowercase" $ channelKindFromText "signal" `shouldBe` Just Signal
    it "parses uppercase (case-insensitive)" $ channelKindFromText "SIGNAL" `shouldBe` Just Signal
    it "rejects unknown" $ channelKindFromText "unknown" `shouldBe` Nothing

  describe "enumeration" $ do
    it "[minBound..maxBound] is exactly the six" $
      [minBound .. maxBound :: ChannelKind]
        `shouldBe` [Cli, Web, Signal, Telegram, Background, Other]

  describe "properties" $ do
    prop "channelKindFromText . channelKindToText round-trips" $ \k ->
      channelKindFromText (channelKindToText k) === Just k

    prop "channelKindToText never empty / control-char" $ \k ->
      let t = channelKindToText k
      in not (T.null t) && T.all (not . isControl) t

  describe "JSON" $
    prop "round-trips" $ \k ->
      decode (encode (k :: ChannelKind)) === Just k

-- ---------------------------------------------------------------------------
-- QuickCheck
-- ---------------------------------------------------------------------------

instance Arbitrary ChannelKind where arbitrary = elements [minBound .. maxBound]

isControl :: Char -> Bool
isControl c = c < ' ' || c == '\x7f'