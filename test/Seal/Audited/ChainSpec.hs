{-# LANGUAGE OverloadedStrings #-}
module Seal.Audited.ChainSpec (spec) where

import Test.Hspec
import Test.QuickCheck

import Seal.Audited.Chain
import Seal.Audited.Types (AuditedEntry (..))
import Seal.TestHelpers.Arbitrary ()

spec :: Spec
spec = describe "Seal.Audited.Chain" $ do
  describe "verifyOrder" $ do
    it "accepts a log with unique ids" $
      property $ \es ->
        allUniqueIds (es :: [AuditedEntry]) ==>
          verifyOrder es === Right ()

    it "rejects a log with a duplicated id" $
      property $ \e ->
        let entries = [e, e { aeOpcode = aeOpcode e }]  -- same id, different opcode
        in verifyOrder entries === Left (DuplicateId (aeId e))

  describe "sortEntries" $
    it "sorts by timestamp ascending" $
      property $ \es ->
        let sorted = sortEntries (es :: [AuditedEntry])
        in isTimestampAscending sorted

-- | True when all entry ids in the list are unique.
allUniqueIds :: [AuditedEntry] -> Bool
allUniqueIds = null . firstDuplicate . map aeId

-- | True when the list is in non-decreasing timestamp order.
isTimestampAscending :: [AuditedEntry] -> Bool
isTimestampAscending = go Nothing
  where
    go _        []     = True
    go Nothing (e:es) = go (Just (aeTimestamp e)) es
    go (Just p) (e:es)
      | aeTimestamp e >= p = go (Just (aeTimestamp e)) es
      | otherwise          = False

firstDuplicate :: Eq a => [a] -> [a]
firstDuplicate = go []
  where
    go _       []     = []
    go seen (x:xs)
      | x `elem` seen = x : go (x:seen) xs
      | otherwise     = go (x:seen) xs