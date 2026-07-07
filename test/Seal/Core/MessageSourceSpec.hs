{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Seal.Core.MessageSourceSpec (spec) where

import Data.Aeson (decode, encode)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Core.ChannelKind
import Seal.Core.MessageSource

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "Seal.Core.MessageSource" $ do
  describe "mkConversationId" $ do
    it "accepts a typical id" $
      fmap conversationIdText (mkConversationId "sig:+15551234567")
        `shouldBe` Right "sig:+15551234567"
    it "rejects empty" $ mkConversationId "" `shouldSatisfy` isLeft
    it "rejects over-long (>256)" $
      mkConversationId (T.replicate 257 "a") `shouldSatisfy` isLeft
    it "rejects leading dot" $ mkConversationId ".hidden" `shouldSatisfy` isLeft
    it "rejects control chars" $ mkConversationId "a\NULb" `shouldSatisfy` isLeft
    prop "accepts [A-Za-z0-9_:-] up to 256" $ forAll genGoodConvId $ \t ->
      fmap conversationIdText (mkConversationId t) === Right t

  describe "mkUserId" $ do
    it "accepts a typical id" $
      fmap userIdText (mkUserId "+15551234567") `shouldBe` Right "+15551234567"
    it "rejects empty" $ mkUserId "" `shouldSatisfy` isLeft
    it "rejects over-long" $ mkUserId (T.replicate 257 "a") `shouldSatisfy` isLeft
    it "rejects control chars" $ mkUserId "a\ESCb" `shouldSatisfy` isLeft
    prop "accepts [A-Za-z0-9_+:-] up to 256" $ forAll genGoodUserId $ \t ->
      fmap userIdText (mkUserId t) === Right t

  describe "mkMessageSource" $ do
    let cid  = mkConversationId "sig:+1"
        kind = Signal
        uid  = mkUserId "+1"
    it "accepts a minimal source" $
      mkMessageSource (either (error "cid") id cid) kind Nothing mempty
        `shouldSatisfy` isRight
    it "accepts a user id + open map" $
      mkMessageSource (either (error "cid") id cid) kind (Just (either (error "uid") id uid))
                      (Map.fromList [("k","v")])
        `shouldSatisfy` isRight
    it "rejects a conversationId key in the open map" $
      mkMessageSource (either (error "cid") id cid) kind Nothing
                      (Map.fromList [("conversationId","forged")])
        `shouldBe` Left "open field key 'conversationId' is reserved"
    it "strips control chars from open-map values" $ do
      case mkMessageSource (either (error "cid") id cid) kind Nothing
                           (Map.fromList [("k","a\ESCb")]) of
        Left e  -> expectationFailure ("unexpected Left: " <> T.unpack e)
        Right ms -> Map.lookup "k" (msOpen ms) `shouldBe` Just "ab"
    it "strips control chars from open-map keys" $ do
      case mkMessageSource (either (error "cid") id cid) kind Nothing
                           (Map.fromList [("a\NULb","v")]) of
        Left e  -> expectationFailure ("unexpected Left: " <> T.unpack e)
        Right ms -> Map.keys (msOpen ms) `shouldBe` ["ab"]
    it "rejects >32 open entries" $ do
      let big = Map.fromList [(T.pack ("k" <> show n), "v") | n <- [0 :: Int .. 32]]
      mkMessageSource (either (error "cid") id cid) kind Nothing big
        `shouldSatisfy` isLeft
    prop "round-trips through JSON when constructed via mkMessageSource" $
      forAll genMessageSource $ \ms ->
        decode (encode ms) === Just ms

-- ---------------------------------------------------------------------------
-- Helpers / generators
-- ---------------------------------------------------------------------------

isLeft :: Either a b -> Bool
isLeft (Left _)  = True
isLeft (Right _) = False

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left _)  = False

goodConvChars :: String
goodConvChars = ['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "_-:"

genGoodConvId :: Gen Text
genGoodConvId = T.pack <$> listOf1 (elements goodConvChars) `suchThat` \s -> length s <= 256

goodUserChars :: String
goodUserChars = ['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "_+-:"

genGoodUserId :: Gen Text
genGoodUserId = T.pack <$> listOf1 (elements goodUserChars) `suchThat` \s -> length s <= 256

genMessageSource :: Gen MessageSource
genMessageSource = do
  cid  <- either (error "cid") id . mkConversationId <$> genGoodConvId
  kind <- elements [minBound .. maxBound :: ChannelKind]
  mUid <- oneof [pure Nothing, Just . either (error "uid") id . mkUserId <$> genGoodUserId]
  n   <- chooseInt (0, 16)
  kvs <- vectorOf n genOpenKv
  let m = Map.fromList kvs
  pure . either (error "mkMessageSource") id $ mkMessageSource cid kind mUid m

genOpenKv :: Gen (Text, Text)
genOpenKv = do
  k <- T.pack <$> listOf1 (elements goodUserChars)
  v <- T.pack <$> listOf1 (elements goodUserChars)
  pure (k, v)