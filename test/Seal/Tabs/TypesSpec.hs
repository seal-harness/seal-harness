{-# LANGUAGE OverloadedStrings #-}
module Seal.Tabs.TypesSpec (spec) where

import Data.Either (isLeft, isRight, fromRight)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Core.Types (mkSessionId, SessionId)
import Seal.Handles.Tab
import Seal.Tabs.Types

spec :: Spec
spec = describe "Seal.Tabs.Types" $ do
  describe "I1 (contiguity)" $ do
    it "emptyTabList has 0 tabs" $ do
      tabCount emptyTabList `shouldBe` 0
      tlTabs emptyTabList `shouldBe` []

    it "insertTab places at slot 0 for an empty list" $
      case insertTab (BoundSession (sid "a")) KindAi Nothing emptyTabList of
        Right tl -> map (tabIndexToInt . tIndex) (tlTabs tl) `shouldBe` [0]
        Left e   -> expectationFailure ("unexpected Left: " <> show e)

    it "insertTab places at the lowest free slot (slot 1 after one insert)" $ do
      let eTl1 = insertTab (BoundSession (sid "a")) KindAi Nothing emptyTabList
      case eTl1 of
        Right tl1 -> case insertTab (BoundSession (sid "b")) KindAi Nothing tl1 of
          Right tl -> map (tabIndexToInt . tIndex) (tlTabs tl) `shouldBe` [0, 1]
          Left e   -> expectationFailure ("second insert Left: " <> show e)
        Left e   -> expectationFailure ("first insert Left: " <> show e)

    it "removeTab compacts: indices renumber to 0..n-2" $
      case ins3 of
        Right tl -> case removeTab tl (mkIdx 1) of
          Right tl' -> map (tabIndexToInt . tIndex) (tlTabs tl') `shouldBe` [0, 1]
          Left e    -> expectationFailure ("removeTab Left: " <> show e)
        Left e -> expectationFailure ("ins3 Left: " <> show e)

    it "removeTab out of range is Left" $
      removeTab emptyTabList (mkIdx 0) `shouldSatisfy` isLeft

  describe "I2 (no duplicate refs)" $ do
    it "insertTab with a duplicate ref is Left" $
      case insertTab (BoundSession (sid "a")) KindAi Nothing emptyTabList of
        Right tl -> insertTab (BoundSession (sid "a")) KindAi Nothing tl `shouldSatisfy` isLeft
        Left e   -> expectationFailure ("first insert Left: " <> show e)

    it "insertTab with a distinct ref is Right" $
      case insertTab (BoundSession (sid "a")) KindAi Nothing emptyTabList of
        Right tl -> insertTab (BoundSession (sid "b")) KindAi Nothing tl `shouldSatisfy` isRight
        Left e   -> expectationFailure ("first insert Left: " <> show e)

  describe "36-slot cap" $ do
    it "insertTab fails after 36 tabs" $ do
      let sids = [sid (T.pack (show (n :: Int))) | n <- [0..35]]
          tl  = foldl (\acc s -> fromRight acc (insertTab (BoundSession s) KindAi Nothing acc)) emptyTabList (take 36 sids)
      tabCount tl `shouldBe` 36
      insertTab (BoundSession (sid "overflow")) KindAi Nothing tl `shouldSatisfy` isLeft

  describe "I3 (cursor survives compaction)" $ do
    it "slotOf finds the slot" $
      case ins3 of
        Right tl -> slotOf tl (BoundSession (sid "c")) `shouldBe` Just (mkIdx 2)
        Left e   -> expectationFailure ("ins3 Left: " <> show e)

    it "removeTab j<i shifts the cursor's slot down by 1" $
      case ins3 of
        Right tl -> case removeTab tl (mkIdx 0) of
          Right tl' -> slotOf tl' (BoundSession (sid "c")) `shouldBe` Just (mkIdx 1)
          Left e    -> expectationFailure ("removeTab Left: " <> show e)
        Left e -> expectationFailure ("ins3 Left: " <> show e)

    it "slotOf returns Nothing for a stale ref" $
      slotOf emptyTabList (BoundSession (sid "x")) `shouldBe` Nothing

  describe "lookup" $ do
    it "lookupTab by index" $
      case ins3 of
        Right tl -> tRef <$> lookupTab tl (mkIdx 1) `shouldBe` Just (BoundSession (sid "b"))
        Left e   -> expectationFailure ("ins3 Left: " <> show e)

    it "lookupByRef" $
      case ins3 of
        Right tl -> tIndex <$> lookupByRef tl (BoundSession (sid "b")) `shouldBe` Just (mkIdx 1)
        Left e   -> expectationFailure ("ins3 Left: " <> show e)

  describe "renameTab" $ do
    it "sets the label" $
      case ins3 of
        Right tl -> case renameTab tl (mkIdx 0) "work" of
          Right tl' -> do
            let mTab = lookupTab tl' (mkIdx 0)
            tLabel <$> mTab `shouldBe` Just (Just "work")
          Left e    -> expectationFailure ("renameTab Left: " <> show e)
        Left e -> expectationFailure ("ins3 Left: " <> show e)

  -- Heavy QuickCheck on the invariants
  describe "QuickCheck invariants" $ do
    prop "I1: indices are contiguous 0..n-1 after any op sequence" $
      forAll genOps $ \ops ->
        let tl = applyOps ops emptyTabList
        in tabCount tl == length (tlTabs tl)
           && map (tabIndexToInt . tIndex) (tlTabs tl) == [0 .. tabCount tl - 1]

    prop "I2: no two tabs share a TabRef" $
      forAll genOps $ \ops ->
        let tl = applyOps ops emptyTabList
            refs = map tRef (tlTabs tl)
        in refs == nubEq refs

    prop "I3: slotOf . lookupByRef round-trips" $
      forAll genOps $ \ops ->
        let tl = applyOps ops emptyTabList
        in all (\t -> slotOf tl (tRef t) == Just (tIndex t)) (tlTabs tl)

    prop "lookupTab tl (tIndex t) == Just t for every tab t" $
      forAll genOps $ \ops ->
        let tl = applyOps ops emptyTabList
        in all (\t -> lookupTab tl (tIndex t) == Just t) (tlTabs tl)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

mkIdx :: Int -> TabIndex
mkIdx n = case mkTabIndex n of
  Right i -> i
  Left _  -> error ("mkTabIndex " <> show n <> " failed")

sid :: Text -> SessionId
sid t = case mkSessionId t of
  Right s -> s
  Left _  -> error ("invalid session id: " <> show t)

-- | Insert 3 tabs (a, b, c) at slots 0, 1, 2.
ins3 :: Either Text TabList
ins3 =
  insertTab (BoundSession (sid "a")) KindAi Nothing emptyTabList
    >>= insertTab (BoundSession (sid "b")) KindAi Nothing
    >>= insertTab (BoundSession (sid "c")) KindAi Nothing

-- | A generator of operations: insert one of N distinct refs / remove a slot.
data Op = OpInsert Int | OpRemove TabIndex deriving stock (Eq, Show)

genOps :: Gen [Op]
genOps = listOf1 (oneof [ OpInsert <$> chooseInt (0, 7), OpRemove . mkIdx <$> chooseInt (0, 5) ])

-- | Apply a sequence of operations, ignoring failures (Left).
applyOps :: [Op] -> TabList -> TabList
applyOps [] tl = tl
applyOps (OpInsert n : rest) tl =
  let ref = BoundSession (sid (T.pack ("s" <> show n)))
  in applyOps rest (fromRight tl (insertTab ref KindAi Nothing tl))
applyOps (OpRemove i : rest) tl =
  applyOps rest (fromRight tl (removeTab tl i))

-- | nub by equality (a local nub to avoid an import).
nubEq :: Eq a => [a] -> [a]
nubEq = go []
  where
    go _ []     = []
    go seen (x:xs)
      | x `elem` seen = go seen xs
      | otherwise     = x : go (x:seen) xs