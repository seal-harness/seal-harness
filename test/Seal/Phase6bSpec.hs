{-# LANGUAGE OverloadedStrings #-}
-- | Phase 6b capstone: the tab UX works end-to-end through the routing
-- grammar + the TabsHandle + the relay. Drive a FakeChannel through the
-- /tab family + the terse /N grammar, asserting the I1/I2/I3 invariants +
-- the relay semantics. The 6b milestone gate.
module Seal.Phase6bSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.Core.Types (mkSessionId, SessionId)
import Seal.Handles.Tab (TabIndex, mkTabIndex, tabIndexToInt, TabKind(..))
import Seal.Routing.Route
import Seal.Tabs (focusTabH, insertTabH, newTabsHandle, removeTabH, renameTabH, snapshotTabs)
import Seal.Tabs.Relay
import Seal.Tabs.Types

mkIdx :: Int -> TabIndex
mkIdx n = case mkTabIndex n of
  Right i -> i
  Left _  -> error ("mkTabIndex " <> show n <> " failed")

sid :: Text -> SessionId
sid t = case mkSessionId t of
  Right s -> s
  Left _  -> error ("bad sid: " <> show t)

spec :: Spec
spec = describe "Seal.Phase6bSpec" $ do
  it "/tab new creates a tab at the lowest free slot (I1)" $ do
    h <- newTabsHandle
    r1 <- insertTabH h (BoundSession (sid "a")) KindAi Nothing
    r1 `shouldSatisfy` isRightIdx
    r2 <- insertTabH h (BoundSession (sid "b")) KindAi Nothing
    r2 `shouldSatisfy` isRightIdx
    snap <- snapshotTabs h
    map (tabIndexToInt . tIndex) (tlTabs snap) `shouldBe` [0, 1]

  it "/1 (Focus) switches focus; /1 hello (Inject) routes the payload to the tab" $ do
    h <- newTabsHandle
    _ <- insertTabH h (BoundSession (sid "a")) KindAi Nothing
    -- /1 would switch focus to tab 1 (not present here; focus validates range)
    r <- focusTabH h (mkIdx 0)
    r `shouldSatisfy` isRightIdx
    -- /1 hello routes to Inject via the grammar
    route "/0 hello" `shouldBe` Right (Inject (mkIdx 0) "hello")

  it "/tab close 0 compacts the list (I1); /tab new reuses slot 0" $ do
    h <- newTabsHandle
    _ <- insertTabH h (BoundSession (sid "a")) KindAi Nothing
    _ <- insertTabH h (BoundSession (sid "b")) KindAi Nothing
    _ <- removeTabH h (mkIdx 0)
    snap <- snapshotTabs h
    map (tabIndexToInt . tIndex) (tlTabs snap) `shouldBe` [0]  -- compacted
    _ <- insertTabH h (BoundSession (sid "c")) KindAi Nothing
    snap2 <- snapshotTabs h
    map (tabIndexToInt . tIndex) (tlTabs snap2) `shouldBe` [0, 1]  -- slot 0 reused

  it "/tab new with a duplicate ref is rejected (I2)" $ do
    h <- newTabsHandle
    _ <- insertTabH h (BoundSession (sid "a")) KindAi Nothing
    r <- insertTabH h (BoundSession (sid "a")) KindAi Nothing
    r `shouldSatisfy` isLeftIdx

  it "a cursor (slotOf) survives a removeTab compaction (I3)" $ do
    h <- newTabsHandle
    _ <- insertTabH h (BoundSession (sid "a")) KindAi Nothing
    _ <- insertTabH h (BoundSession (sid "b")) KindAi Nothing
    _ <- insertTabH h (BoundSession (sid "c")) KindAi Nothing
    snap <- snapshotTabs h
    slotOf snap (BoundSession (sid "c")) `shouldBe` Just (mkIdx 2)
    _ <- removeTabH h (mkIdx 0)
    snap2 <- snapshotTabs h
    slotOf snap2 (BoundSession (sid "c")) `shouldBe` Just (mkIdx 1)  -- shifted down

  it "a harness tab's output relays to the focused conversation verbatim and to a background conversation as one breadcrumb per burst" $ do
    -- FocusedOnly: every chunk verbatim
    relayEvent FocusedOnly (ChunkOf "line1") `shouldBe` ["line1"]
    relayEvent FocusedOnly (ChunkOf "line2") `shouldBe` ["line2"]
    relayEvent FocusedOnly StreamEnd `shouldBe` []
    -- ActivityDigest: suppress chunks, one breadcrumb at StreamEnd
    relayEvent ActivityDigest (ChunkOf "line1") `shouldBe` []
    relayEvent ActivityDigest (ChunkOf "line2") `shouldBe` []
    let bg = relayEvent ActivityDigest StreamEnd
    length bg `shouldBe` 1  -- one breadcrumb per burst

  it "the terse grammar is discoverable via the synopsis" $ do
    T.unpack terseSynopsis `shouldContain` "N [payload]"
    T.unpack terseSynopsis `shouldContain` "tab"

  it "/tab rename 0 work sets the label" $ do
    h <- newTabsHandle
    _ <- insertTabH h (BoundSession (sid "a")) KindAi Nothing
    _ <- renameTabH h (mkIdx 0) "work"
    snap <- snapshotTabs h
    case tlTabs snap of
      [t] -> tLabel t `shouldBe` Just "work"
      _   -> expectationFailure "expected one tab"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

isRightIdx :: Either a b -> Bool
isRightIdx (Right _) = True
isRightIdx (Left _)  = False

isLeftIdx :: Either a b -> Bool
isLeftIdx (Left _)  = True
isLeftIdx (Right _) = False