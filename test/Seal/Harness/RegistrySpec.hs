{-# LANGUAGE OverloadedStrings #-}
module Seal.Harness.RegistrySpec (spec) where

import Control.Concurrent.STM (atomically)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Harness.Id
import Seal.Harness.Registry

spec :: Spec
spec = do
  describe "Seal.Harness.Registry CRUD" $ do
    it "insert then lookupById finds it" $ do
      reg <- newHarnessRegistry
      hid <- newHarnessId
      atomically (insert reg (testEntry hid))
      m <- atomically (lookupById reg hid)
      fmap heId m `shouldBe` Just hid

    it "lookupById misses uninserted" $ do
      reg <- newHarnessRegistry
      hid <- newHarnessId
      m <- atomically (lookupById reg hid)
      m `shouldBe` Nothing

    it "lookupByLabel finds by label" $ do
      reg <- newHarnessRegistry
      hid <- newHarnessId
      atomically (insert reg (testEntry hid) { heLabel = "claude-1" })
      m <- atomically (lookupByLabel reg "claude-1")
      fmap heId m `shouldBe` Just hid

    it "modify updates an entry" $ do
      reg <- newHarnessRegistry
      hid <- newHarnessId
      atomically (insert reg (testEntry hid))
      atomically (modify reg hid (\e -> e { heLiveness = LvThinking }))
      m <- atomically (lookupById reg hid)
      fmap heLiveness m `shouldBe` Just LvThinking

    it "delete removes an entry" $ do
      reg <- newHarnessRegistry
      hid <- newHarnessId
      atomically (insert reg (testEntry hid))
      atomically (delete reg hid)
      m <- atomically (lookupById reg hid)
      m `shouldBe` Nothing

    it "snapshot returns all entries sorted by id" $ do
      reg <- newHarnessRegistry
      h1 <- newHarnessId
      h2 <- newHarnessId
      atomically (insert reg (testEntry h1))
      atomically (insert reg (testEntry h2))
      snap <- snapshot reg
      length snap `shouldBe` 2
      snap `shouldSatisfy` (\xs -> xs == sortById xs)

  describe "Seal.Harness.Registry.mergeReconcile" $ do
    it "inserts a new observed id as HoDiscovered" $ do
      reg <- newHarnessRegistry
      hid <- newHarnessId
      _ <- atomically (mergeReconcile reg [ObservedHarness hid LvIdle Nothing Nothing])
      snap <- snapshot reg
      fmap heOrigin snap `shouldBe` [HoDiscovered]

    it "preserves origin + updates liveness for an existing id" $ do
      reg <- newHarnessRegistry
      hid <- newHarnessId
      atomically (insert reg (testEntry hid) { heOrigin = HoSpawned, heLiveness = LvIdle })
      _ <- atomically (mergeReconcile reg [ObservedHarness hid LvThinking Nothing Nothing])
      snap <- snapshot reg
      fmap (\e -> (heOrigin e, heLiveness e)) snap `shouldBe` [(HoSpawned, LvThinking)]

    it "resets orphan-ticks on a non-orphan observation" $ do
      reg <- newHarnessRegistry
      hid <- newHarnessId
      atomically (insert reg (testEntry hid) { heLiveness = LvOrphaned, heOrphanTicks = 3 })
      _ <- atomically (mergeReconcile reg [ObservedHarness hid LvIdle Nothing Nothing])
      snap <- snapshot reg
      fmap heOrphanTicks snap `shouldBe` [0]

    it "increments orphan-ticks on an orphan observation" $ do
      reg <- newHarnessRegistry
      hid <- newHarnessId
      atomically (insert reg (testEntry hid) { heLiveness = LvIdle, heOrphanTicks = 0 })
      _ <- atomically (mergeReconcile reg [ObservedHarness hid LvOrphaned Nothing Nothing])
      snap <- snapshot reg
      fmap heOrphanTicks snap `shouldBe` [1]

    it "does not touch an existing entry not in the observed list" $ do
      reg <- newHarnessRegistry
      h1 <- newHarnessId
      h2 <- newHarnessId
      atomically (insert reg (testEntry h1) { heLiveness = LvIdle })
      atomically (insert reg (testEntry h2) { heLiveness = LvThinking })
      _ <- atomically (mergeReconcile reg [ObservedHarness h1 LvThinking Nothing Nothing])
      snap <- snapshot reg
      let m = Map.fromList [(heId e, heLiveness e) | e <- snap]
      m `shouldBe` Map.fromList [(h1, LvThinking), (h2, LvThinking)]  -- h2 untouched

    prop "lost-update safe: two disjoint merges in one transaction both land" $
      \(xs :: [SmallId]) (ys :: [SmallId]) ->
        let observed1 = [ObservedHarness (smallId x) LvIdle Nothing Nothing | x <- xs]
            observed2 = [ObservedHarness (smallId y) LvThinking Nothing Nothing | y <- ys]
        in length xs + length ys <= 50 ==>
             collect (length xs + length ys) $ ioProperty $ do
               reg <- newHarnessRegistry
               _ <- atomically (mergeReconcile reg observed1 >> mergeReconcile reg observed2)
               snap <- snapshot reg
               -- every observed id is present
               let presentIds = Set.fromList (map heId snap)
                   expectedIds = Set.fromList ([smallId x | x <- xs] <> [smallId y | y <- ys])
               pure (presentIds === expectedIds)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

testEntry :: HarnessId -> HarnessEntry
testEntry hid = HarnessEntry
  { heId = hid
  , heLabel = "test"
  , heOrigin = HoSpawned
  , heLiveness = LvIdle
  , heTmuxCoord = Just "seal:0"
  , heFlavour = Just "claude-code"
  , heOrphanTicks = 0
  }

sortById :: [HarnessEntry] -> [HarnessEntry]
sortById = sortBy (compare `on` heId)
  where
    sortBy :: (a -> a -> Ordering) -> [a] -> [a]
    sortBy _ [] = []
    sortBy cmp (x:xs) = insert' cmp x (sortBy cmp xs)
    insert' cmp x ys = let (lt, gt) = span (\y -> cmp y x == LT) ys in lt <> [x] <> gt

on :: (b -> b -> c) -> (a -> b) -> a -> a -> c
on f g x y = f (g x) (g y)

-- | A small Int wrapper for QuickCheck — generates distinct ids via a counter.
newtype SmallId = SmallId Int deriving stock (Eq, Show)

instance Arbitrary SmallId where
  arbitrary = SmallId <$> chooseInt (0, 49)

smallId :: SmallId -> HarnessId
smallId (SmallId n) = HarnessId (T.pack (pad n <> "-0000-0000-0000-000000000000"))
  where
    -- Build a UUID-shaped string so isValidHarnessIdText passes... but
    -- HarnessId is a constructor that doesn't validate on construction
    -- (only parseHarnessId validates). For tests we use the constructor
    -- directly with a distinct text per n.
    pad k = let s = show k in replicate (8 - length s) '0' <> s