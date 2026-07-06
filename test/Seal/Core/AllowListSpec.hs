{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Seal.Core.AllowListSpec (spec) where

import Data.Set qualified as Set
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Core.AllowList

spec :: Spec
spec = describe "Seal.Core.AllowList" $ do
  describe "isAllowed" $ do
    it "AllowAll admits anything" $ isAllowed (5 :: Int) AllowAll `shouldBe` True
    it "AllowOnly admits a member" $
      isAllowed 'a' (AllowOnly (Set.fromList "abc")) `shouldBe` True
    it "AllowOnly rejects a non-member" $
      isAllowed 'z' (AllowOnly (Set.fromList "abc")) `shouldBe` False

  describe "properties" $ do
    prop "AllowAll admits everything" $ \x ->
      isAllowed (x :: Int) AllowAll === True

    prop "AllowOnly s admits exactly the members of s" $ \s x ->
      isAllowed (x :: Char) (AllowOnly (Set.fromList s))
        === Set.member x (Set.fromList s)

    prop "AllowOnly never admits an absent element" $ \s x ->
      not (Set.member x (Set.fromList (s :: [Char]))) ==>
        isAllowed x (AllowOnly (Set.fromList s)) === False