{-# LANGUAGE OverloadedStrings #-}
module Seal.Core.PagingSpec (spec) where

import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Data.List (isInfixOf)

import Seal.Core.Paging
import Seal.TestHelpers.Arbitrary ()

spec :: Spec
spec = describe "Seal.Core.Paging" $ do

  describe "pageSize" $ do
    it "defaultPageParams on 320 lines = 500 (flat default, coeff=0)" $
      pageSize defaultPageParams 320 `shouldBe` 500

    it "defaultPageParams on 0 lines = floor (500)" $
      pageSize defaultPageParams 0 `shouldBe` 500

    it "defaultPageParams on 1 line = floor (500)" $
      pageSize defaultPageParams 1 `shouldBe` 500

    it "defaultPageParams on a huge total is still 500 (coeff=0, no scaling)" $
      pageSize defaultPageParams 1000000 `shouldBe` 500

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
      windowSize defaultPageParams 100 (Just 5000) `shouldBe` 2000

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
        -- pageSize = 500 but only 100 items exist, so all fit in one page.
        length (pgItems p) `shouldBe` 100
        pgHasMore p `shouldBe` False

    it "explicit limit overrides the computed size" $
      let p = paginate defaultPageParams 0 (Just 5) [1..100 :: Int]
      in length (pgItems p) `shouldBe` 5

    it "explicit limit above ceiling with small list returns all items" $
      let p = paginate defaultPageParams 0 (Just 5000) [1..100 :: Int]
      in length (pgItems p) `shouldBe` 100   -- total is 100 < ceiling 2000

    it "explicit limit above ceiling with large list clamps to ceiling" $
      let p = paginate defaultPageParams 0 (Just 5000) [1..10000 :: Int]
      in length (pgItems p) `shouldBe` 2000

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

  -- ---------------------------------------------------------------------
  -- paginateDesc — back-to-front pagination
  -- ---------------------------------------------------------------------
  describe "paginateDesc" $ do

    it "offset=0 returns the last window" $
      let p = paginateDesc defaultPageParams 0 (Just 20) [1..100 :: Int]
      in do
        pgItems p   `shouldBe` [81..100]
        pgOffset p  `shouldBe` 80
        pgTotal p   `shouldBe` 100
        pgHasMore p `shouldBe` True

    it "offset=20 returns the window before the last" $
      let p = paginateDesc defaultPageParams 20 (Just 20) [1..100 :: Int]
      in do
        pgItems p   `shouldBe` [61..80]
        pgOffset p  `shouldBe` 60
        pgHasMore p `shouldBe` True

    it "offset at the boundary returns the first window" $
      let p = paginateDesc defaultPageParams 80 (Just 20) [1..100 :: Int]
      in do
        pgItems p   `shouldBe` [1..20]
        pgOffset p  `shouldBe` 0
        pgHasMore p `shouldBe` False

    it "offset past total yields empty window and pgHasMore False" $
      let p = paginateDesc defaultPageParams 100 (Just 20) [1..100 :: Int]
      in do
        pgItems p   `shouldBe` []
        pgHasMore p `shouldBe` False

    it "limit larger than total returns all items from the start" $
      let p = paginateDesc defaultPageParams 0 (Just 50) [1..5 :: Int]
      in do
        pgItems p   `shouldBe` [1..5]
        pgOffset p  `shouldBe` 0
        pgHasMore p `shouldBe` False

    it "window is smaller when few items remain before offset point" $
      let p = paginateDesc defaultPageParams 10 (Just 50) [1..55 :: Int]
      in do
        -- Skip 10 from end (messages 46-55), take up to 50 before that.
        -- Only 45 messages remain (1-45).
        pgItems p   `shouldBe` [1..45]
        pgOffset p  `shouldBe` 0
        pgHasMore p `shouldBe` False

    it "items are in original (chronological) order within the window" $
      let p = paginateDesc defaultPageParams 0 (Just 3) [1..10 :: Int]
      in pgItems p `shouldBe` [8, 9, 10]

    it "negative offset is clamped to 0 (last window)" $
      let p = paginateDesc defaultPageParams (-5) (Just 3) [1..10 :: Int]
      in do
        pgItems p  `shouldBe` [8, 9, 10]
        pgOffset p `shouldBe` 7

    it "limit above ceiling is clamped to ceiling" $
      let p = paginateDesc defaultPageParams 0 (Just 5000) [1..10000 :: Int]
      in length (pgItems p) `shouldBe` 2000

    prop "pgOffset + length pgItems <= pgTotal" $ \params offset mLimit (xs :: [Int]) ->
      let p = paginateDesc params offset mLimit xs
      in pgOffset p + length (pgItems p) <= pgTotal p

    prop "pgItems is a contiguous slice of the input in original order" $ \params offset mLimit (xs :: [Int]) ->
      let p = paginateDesc params offset mLimit xs
      in pgItems p `shouldSatisfy` \win ->
           null win
             || win `isInfixOf` xs

    prop "SECURITY: window size never exceeds ceiling, offset in [0,total]" $
      \params offset mLimit (xs :: [Int]) ->
        let p = paginateDesc params offset (mLimit :: Maybe Int) xs
        in length (pgItems p) <= ppCeiling params
           .&&. pgOffset p >= 0
           .&&. pgOffset p <= pgTotal p
