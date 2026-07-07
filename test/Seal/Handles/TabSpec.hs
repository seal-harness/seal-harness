{-# LANGUAGE OverloadedStrings #-}
module Seal.Handles.TabSpec (spec) where

import Data.Either (isLeft, isRight)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Handles.Tab

mk :: Int -> TabIndex
mk n = case mkTabIndex n of
  Right i -> i
  Left _  -> error ("mkTabIndex " <> show n <> " unexpectedly failed")

spec :: Spec
spec = describe "Seal.Handles.Tab" $ do
  describe "mkTabIndex" $ do
    it "accepts 0" $ mkTabIndex 0 `shouldSatisfy` isRight
    it "accepts 35" $ mkTabIndex 35 `shouldSatisfy` isRight
    it "rejects 36" $ mkTabIndex 36 `shouldSatisfy` isLeft
    it "rejects -1" $ mkTabIndex (-1) `shouldSatisfy` isLeft

  describe "tabIndexToChar / tabIndexFromChar" $ do
    it "0 -> '0'" $ tabIndexToChar (mk 0) `shouldBe` '0'
    it "9 -> '9'" $ tabIndexToChar (mk 9) `shouldBe` '9'
    it "10 -> 'a'" $ tabIndexToChar (mk 10) `shouldBe` 'a'
    it "35 -> 'z'" $ tabIndexToChar (mk 35) `shouldBe` 'z'
    it "fromChar '0' -> Right 0" $ tabIndexFromChar '0' `shouldBe` Right (mk 0)
    it "fromChar 'Z' (case-insensitive) -> Right 35" $ tabIndexFromChar 'Z' `shouldBe` Right (mk 35)
    it "fromChar '!' -> Left" $ tabIndexFromChar '!' `shouldSatisfy` isLeft
    prop "round-trips for 0..35" $ \n ->
      n >= 0 && n <= 35 ==>
        tabIndexFromChar (tabIndexToChar (mk n)) === Right (mk n)

  describe "TabKind" $ do
    it "has six constructors" $
      [minBound .. maxBound :: TabKind]
        `shouldBe` [KindAi, KindProvider, KindHarness, KindShell, KindSsh, KindTmux]