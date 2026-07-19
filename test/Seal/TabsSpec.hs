{-# LANGUAGE OverloadedStrings #-}
module Seal.TabsSpec (spec) where

import Data.Either (isLeft, isRight)
import Data.Text (Text)
import Test.Hspec

import Seal.Core.Types (mkSessionId, SessionId)
import Seal.Handles.Tab
import Seal.Tabs
import Seal.Tabs.Types

mk :: Int -> TabIndex
mk n = case mkTabIndex n of
  Right i -> i
  Left _  -> error ("mkTabIndex " <> show n <> " failed")

sid :: Text -> SessionId
sid t = case mkSessionId t of
  Right s -> s
  Left _  -> error ("invalid session id: " <> show t)

spec :: Spec
spec = describe "Seal.Tabs.TabsHandle" $ do
  it "newTabsHandle is empty" $ do
    h <- newTabsHandle
    snap <- snapshotTabs h
    tabCount snap `shouldBe` 0

  it "insertTabH places at the lowest free slot" $ do
    h <- newTabsHandle
    r1 <- insertTabH h (BoundSession (sid "a")) KindAi Nothing
    r1 `shouldSatisfy` isRight
    r2 <- insertTabH h (BoundSession (sid "b")) KindAi Nothing
    r2 `shouldSatisfy` isRight
    snap <- snapshotTabs h
    map (tabIndexToInt . tIndex) (tlTabs snap) `shouldBe` [0, 1]

  it "insertTabH with a duplicate ref is Left (I2)" $ do
    h <- newTabsHandle
    _ <- insertTabH h (BoundSession (sid "a")) KindAi Nothing
    r <- insertTabH h (BoundSession (sid "a")) KindAi Nothing
    r `shouldSatisfy` isLeft

  it "removeTabH compacts (I1)" $ do
    h <- newTabsHandle
    _ <- insertTabH h (BoundSession (sid "a")) KindAi Nothing
    _ <- insertTabH h (BoundSession (sid "b")) KindAi Nothing
    _ <- insertTabH h (BoundSession (sid "c")) KindAi Nothing
    _ <- removeTabH h (mk 1)
    snap <- snapshotTabs h
    map (tabIndexToInt . tIndex) (tlTabs snap) `shouldBe` [0, 1]

  it "removeTabH out of range is Left" $ do
    h <- newTabsHandle
    r <- removeTabH h (mk 0)
    r `shouldSatisfy` isLeft

  it "renameTabH sets the label" $ do
    h <- newTabsHandle
    _ <- insertTabH h (BoundSession (sid "a")) KindAi Nothing
    _ <- renameTabH h (mk 0) "work"
    snap <- snapshotTabs h
    case tlTabs snap of
      [t] -> tLabel t `shouldBe` Just "work"
      _   -> expectationFailure "expected one tab"

  it "focusTabH validates the index is in range" $ do
    h <- newTabsHandle
    _ <- insertTabH h (BoundSession (sid "a")) KindAi Nothing
    r1 <- focusTabH h (mk 0)
    r1 `shouldSatisfy` isRight
    r2 <- focusTabH h (mk 5)
    r2 `shouldSatisfy` isLeft

  describe "rebindTabH" $ do
    it "swaps the tab's ref, preserving index/kind/label/status" $ do
      h <- newTabsHandle
      _ <- insertTabH h (BoundSession (sid "a")) KindAi (Just "work")
      r <- rebindTabH h (mk 0) (BoundSession (sid "b"))
      r `shouldSatisfy` isRight
      snap <- snapshotTabs h
      case tlTabs snap of
        [t] -> do
          tRef t   `shouldBe` BoundSession (sid "b")
          tIndex t `shouldBe` mk 0
          tKind t  `shouldBe` KindAi
          tLabel t `shouldBe` Just "work"
          tStatus t `shouldBe` Live
        _ -> expectationFailure "expected one tab"

    it "out-of-range index is Left" $ do
      h <- newTabsHandle
      _ <- insertTabH h (BoundSession (sid "a")) KindAi Nothing
      r <- rebindTabH h (mk 5) (BoundSession (sid "b"))
      r `shouldSatisfy` isLeft

    it "I2: new ref already bound to a different tab is Left" $ do
      h <- newTabsHandle
      _ <- insertTabH h (BoundSession (sid "a")) KindAi Nothing
      _ <- insertTabH h (BoundSession (sid "b")) KindAi Nothing
      -- rebinding tab 1 to sid "a" (already on tab 0) must fail
      r <- rebindTabH h (mk 1) (BoundSession (sid "a"))
      r `shouldSatisfy` isLeft
      -- and must not have mutated either tab
      snap <- snapshotTabs h
      map tRef (tlTabs snap) `shouldBe` [BoundSession (sid "a"), BoundSession (sid "b")]

    it "rebind-to-same-ref is a no-op Right" $ do
      h <- newTabsHandle
      _ <- insertTabH h (BoundSession (sid "a")) KindAi (Just "work")
      r <- rebindTabH h (mk 0) (BoundSession (sid "a"))
      r `shouldSatisfy` isRight
      snap <- snapshotTabs h
      case tlTabs snap of
        [t] -> tRef t `shouldBe` BoundSession (sid "a")
        _   -> expectationFailure "expected one tab"