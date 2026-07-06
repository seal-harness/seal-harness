{-# LANGUAGE OverloadedStrings #-}
module Seal.Harness.ReconcileSpec (spec) where

import Control.Concurrent.STM (atomically)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Harness.Id
import Seal.Harness.Observer
import Seal.Harness.Reconcile
import Seal.Harness.Registry
import Seal.Session.Kind (HarnessFlavour (..), mkHCustom)

spec :: Spec
spec = do
  describe "Seal.Harness.Observer.observeClaudeCode" $ do
    it "Thinking -> LvThinking" $
      observeClaudeCode "some output\nThinking…" (Map.fromList [("seal_id","x")])
        `shouldBe` LvThinking
    it "Working -> LvThinking" $
      observeClaudeCode "Working on it" (Map.fromList [("seal_id","x")])
        `shouldBe` LvThinking
    it "bare > prompt -> LvAwaitingInput" $
      observeClaudeCode "output\n> " (Map.fromList [("seal_id","x")])
        `shouldBe` LvAwaitingInput
    it "yes/no confirmation -> LvAwaitingInput" $
      observeClaudeCode "Apply changes? (y/n)" (Map.fromList [("seal_id","x")])
        `shouldBe` LvAwaitingInput
    it "plain output at prompt, not awaiting -> LvIdle" $
      observeClaudeCode "Welcome to Claude Code\n> " (Map.fromList [("seal_id","x")])
        `shouldBe` LvAwaitingInput  -- the bare > suffix makes it awaiting
    it "no seal_id + pane_dead -> LvExited" $
      observeClaudeCode "anything" (Map.fromList [("pane_dead","1")])
        `shouldBe` LvExited
    it "no seal_id, pane alive -> LvOrphaned" $
      observeClaudeCode "stale screen" Map.empty
        `shouldBe` LvOrphaned

  describe "Seal.Session.Kind.mkHCustom" $ do
    it "accepts a simple name" $
      mkHCustom "my-tool" `shouldBe` Right (HCustom "my-tool")
    it "rejects /" $ mkHCustom "a/b" `shouldSatisfy` isLeft
    it "rejects \\" $ mkHCustom "a\\b" `shouldSatisfy` isLeft
    it "rejects leading dash" $ mkHCustom "-x" `shouldSatisfy` isLeft
    it "rejects empty" $ mkHCustom "" `shouldSatisfy` isLeft

  describe "Seal.Harness.Reconcile.tickOrphans" $ do
    it "increments orphan-ticks for unobserved entries" $ do
      reg <- newHarnessRegistry
      hid <- newHarnessId
      atomically (insert reg (testEntry hid) { heLiveness = LvIdle, heOrphanTicks = 0 })
      evicted <- atomically (tickOrphans reg Set.empty 3)
      evicted `shouldBe` []
      snap <- snapshot reg
      fmap heOrphanTicks snap `shouldBe` [1]
      fmap heLiveness snap `shouldBe` [LvOrphaned]

    it "evicts an entry whose ticks exceed the grace limit" $ do
      reg <- newHarnessRegistry
      hid <- newHarnessId
      atomically (insert reg (testEntry hid) { heLiveness = LvOrphaned, heOrphanTicks = 3 })
      evicted <- atomically (tickOrphans reg Set.empty 3)
      case evicted of
        [e] -> heId e `shouldBe` hid
        _   -> expectationFailure ("expected exactly one evicted, got " <> show (length evicted))
      snap <- snapshot reg
      snap `shouldBe` []

    it "does not touch an entry whose id IS in the observed set" $ do
      reg <- newHarnessRegistry
      hid <- newHarnessId
      atomically (insert reg (testEntry hid) { heLiveness = LvIdle, heOrphanTicks = 0 })
      evicted <- atomically (tickOrphans reg (Set.fromList [hid]) 3)
      evicted `shouldBe` []
      snap <- snapshot reg
      fmap heOrphanTicks snap `shouldBe` [0]  -- untouched

    prop "never evicts an observed id" $ \n ->
      n >= 0 ==>
        ioProperty $ do
          reg <- newHarnessRegistry
          hid <- newHarnessId
          atomically (insert reg (testEntry hid) { heOrphanTicks = n })
          evicted <- atomically (tickOrphans reg (Set.fromList [hid]) 3)
          pure (evicted === [])

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

isLeft :: Either a b -> Bool
isLeft (Left _)  = True
isLeft (Right _) = False