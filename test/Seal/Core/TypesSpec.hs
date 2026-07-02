{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Seal.Core.TypesSpec (spec) where

import Data.Aeson (decode, encode)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Core.Types

spec :: Spec
spec = describe "Seal.Core.Types" $ do
  describe "TrustLevel JSON" $
    prop "round-trips" $ \tl ->
      decode (encode (tl :: TrustLevel)) === Just tl

  describe "isValidSessionId" $ do
    it "rejects empty" $ isValidSessionId "" `shouldBe` False
    it "rejects leading dot" $ isValidSessionId ".secret" `shouldBe` False
    it "rejects slash" $ isValidSessionId "a/b" `shouldBe` False
    it "accepts typical id" $ isValidSessionId "2026-06-30_sess-1" `shouldBe` True
    prop "accepts any nonempty [A-Za-z0-9_-] not starting with '.'" $
      forAll (listOf1 (elements (['A'..'Z']++['a'..'z']++['0'..'9']++['_','-']))) $ \s ->
        isValidSessionId (T.pack s) === True

  describe "mkSessionId" $ do
    it "rejects invalid" $ mkSessionId "a b" `shouldBe` Left "invalid session id: \"a b\""
    it "accepts and unwraps" $ fmap sessionIdText (mkSessionId "ok-1") `shouldBe` Right "ok-1"

instance Arbitrary TrustLevel where arbitrary = elements [minBound .. maxBound]
