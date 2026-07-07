{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Seal.Harness.IdSpec (spec) where

import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Harness.Id

spec :: Spec
spec = describe "Seal.Harness.Id" $ do
  describe "newHarnessId / parseHarnessId / harnessIdToText" $ do
    it "parseHarnessId . harnessIdToText round-trips a minted id" $ do
      h <- newHarnessId
      parseHarnessId (harnessIdToText h) `shouldBe` Right h

    it "two minted ids are distinct (probabilistic)" $ do
      hs <- sequence [ newHarnessId | _ <- [1 :: Int .. 1000] ]
      length (distinct hs) `shouldBe` length hs

    it "rejects a non-UUID" $ parseHarnessId "not-a-uuid" `shouldSatisfy` isLeft
    it "rejects empty" $ parseHarnessId "" `shouldSatisfy` isLeft

    prop "parseHarnessId round-trips any valid UUID-shaped text" $
      forAll genUuidText $ \t ->
        parseHarnessId t === Right (HarnessId t)

-- | A generator for valid UUID v4 text (8-4-4-4-12 hex, lowercase).
genUuidText :: Gen Text
genUuidText = do
  a <- vectorOf 8 (elements "0123456789abcdef")
  b <- vectorOf 4 (elements "0123456789abcdef")
  c <- vectorOf 4 (elements "45")           -- version nibble = 4
  d <- vectorOf 4 (elements "89ab")          -- variant high bits = 10
  e <- vectorOf 12 (elements "0123456789abcdef")
  pure (T.pack (intercalate "-" [a,b,c,d,e]))
  where
    intercalate _ []      = []
    intercalate sep (x:xs) = x <> concatMap (sep <>) xs

-- | Compare by the underlying text (exposed for the distinctness test).
-- Reuses the IsString instance via the constructor.
distinct :: [HarnessId] -> [HarnessId]
distinct = go []
  where
    go seen []     = reverse seen
    go seen (x:xs)
      | x `elem` seen = go seen xs
      | otherwise     = go (x:seen) xs

-- Make HarnessId constructible from Text in tests via the public
-- constructor (re-exported). The property above uses the HarnessId
-- constructor directly; it's exported by the module.