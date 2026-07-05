{-# LANGUAGE OverloadedStrings #-}
module Seal.Core.PagingSpec (spec) where

import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Core.Paging
import Seal.TestHelpers.Arbitrary ()

spec :: Spec
spec = describe "Seal.Core.Paging" $ do

  describe "pageSize" $ do
    it "defaultPageParams on 320 lines = 72 (spec example)" $
      pageSize defaultPageParams 320 `shouldBe` 72

    it "defaultPageParams on 0 lines = floor (10)" $
      pageSize defaultPageParams 0 `shouldBe` 10

    it "defaultPageParams on 1 line = clamp 10 200 (round(4*1)=4 -> 10)" $
      pageSize defaultPageParams 1 `shouldBe` 10

    it "defaultPageParams on a huge total is capped at the ceiling (200)" $
      pageSize defaultPageParams 1000000 `shouldBe` 200

    prop "result is always within [ppFloor, ppCeiling]" $ \params n ->
      n >= 0 ==>
      let s = pageSize params n
      in s `shouldSatisfy` \x -> x >= ppFloor params && x <= ppCeiling params

    prop "monotonic non-decreasing in total" $ \params (Positive t) ->
      -- Compare pageSize at t and t+1; allow for banker's-rounding plateaus
      -- but never decrease.
      pageSize params (t + 1) `shouldSatisfy` (>= pageSize params t)

    it "round 2.5 == 2 (banker's rounding awareness)" $
      (round (2.5 :: Double) :: Int) `shouldBe` 2

  describe "windowSize" $ do

    it "Nothing -> pageSize" $
      windowSize defaultPageParams 100 Nothing `shouldBe` pageSize defaultPageParams 100

    it "Just n within [1,ceiling] is used as-is" $
      windowSize defaultPageParams 100 (Just 5) `shouldBe` 5

    it "Just n above ceiling is clamped to ceiling" $
      windowSize defaultPageParams 100 (Just 1000) `shouldBe` 200

    it "Just 0 is clamped up to 1" $
      windowSize defaultPageParams 100 (Just 0) `shouldBe` 1

    it "Just negative is clamped up to 1" $
      windowSize defaultPageParams 100 (Just (-5)) `shouldBe` 1

  describe "paginate" $ do

    it "first window of a 100-item list with defaultPageParams" $
      let p = paginate defaultPageParams 0 Nothing [1..100 :: Int]
      in do
        pgOffset p `shouldBe` 0
        pgTotal p `shouldBe` 100
        length (pgItems p) `shouldBe` pageSize defaultPageParams 100
        pgHasMore p `shouldBe` True

    it "explicit limit overrides the computed size" $
      let p = paginate defaultPageParams 0 (Just 5) [1..100 :: Int]
      in length (pgItems p) `shouldBe` 5

    it "explicit limit above ceiling is clamped to ceiling" $
      let p = paginate defaultPageParams 0 (Just 1000) [1..100 :: Int]
      in length (pgItems p) `shouldBe` 100   -- total is 100 < ceiling 200

    it "explicit limit above ceiling with large list clamps to ceiling" $
      let p = paginate defaultPageParams 0 (Just 1000) [1..1000 :: Int]
      in length (pgItems p) `shouldBe` 200

    it "offset past end yields empty window and pgHasMore False" $
      let p = paginate defaultPageParams 500 Nothing [1..10 :: Int]
      in do
        pgItems p `shouldBe` []
        pgOffset p `shouldBe` 10
        pgHasMore p `shouldBe` False

    it "negative offset is clamped to 0" $
      let p = paginate defaultPageParams (-5) Nothing [1..10 :: Int]
      in do
        pgOffset p `shouldBe` 0
        pgItems p `shouldSatisfy` not . null

    prop "pgOffset + length pgItems <= pgTotal" $ \params offset mLimit (xs :: [Int]) ->
      let p = paginate params offset mLimit xs
      in pgOffset p + length (pgItems p) <= pgTotal p

    prop "pgHasMore iff pgOffset + length pgItems < pgTotal" $ \params offset mLimit (xs :: [Int]) ->
      let p = paginate params offset mLimit xs
      in pgHasMore p == (pgOffset p + length (pgItems p) < pgTotal p)

    prop "pgItems is exactly take size (drop pgOffset items)" $ \params offset mLimit (xs :: [Int]) ->
      let p    = paginate params offset mLimit xs
          size = windowSize params (length xs) mLimit
      in pgItems p == take size (drop (pgOffset p) xs)

    -- The dedicated security-invariant case.
    prop "SECURITY: any offset/limit (incl. negative/huge) -> bounded, offset in [0,total]" $
      \params offset mLimit (xs :: [Int]) ->
        let p = paginate params offset (mLimit :: Maybe Int) xs
        in length (pgItems p) <= ppCeiling params
           .&&. pgOffset p >= 0
           .&&. pgOffset p <= pgTotal p