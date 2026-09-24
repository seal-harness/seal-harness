{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.RateLimit' — the pure rate-limiting
-- functions for streaming text edits.
module Seal.Channels.Chat.RateLimitSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Channels.Chat.RateLimit
  ( StreamProgressConfig (..)
  , defaultStreamProgressConfig
  , shouldEdit
  , addCursor
  , stripCursor
  )

-- | Arbitrary Text generator that avoids the cursor character.
genSafeText :: Gen Text
genSafeText = T.pack <$> listOf1 (elements ['a' .. 'z'])

spec :: Spec
spec = do
  let cfg = defaultStreamProgressConfig
      -- spcBufferThreshold = 80, spcEditIntervalMs = 1500
      t0 = read "2024-01-01 00:00:00 UTC" :: UTCTime

  describe "shouldEdit" $ do
    it "returns True when no previous edit (first delta)" $
      shouldEdit cfg t0 Nothing 0 `shouldBe` True

    it "returns True when buffer threshold is exceeded" $
      shouldEdit cfg t0 (Just t0) 100 `shouldBe` True

    it "returns False when buffer is small and time is short" $ do
      let t1 = read "2024-01-01 00:00:01 UTC" :: UTCTime
      shouldEdit cfg t1 (Just t0) 10 `shouldBe` False

    it "returns True when enough time has elapsed" $ do
      let t2 = read "2024-01-01 00:00:02 UTC" :: UTCTime
      shouldEdit cfg t2 (Just t0) 10 `shouldBe` True

    prop "returns True when accumLen >= bufferThreshold regardless of time" $
      \(n :: NonNegative Int) ->
        let cfg' = cfg { spcBufferThreshold = 50 }
            val = getNonNegative n + 50
        in shouldEdit cfg' t0 (Just t0) val

  describe "addCursor" $ do
    it "appends the cursor character to the text" $
      addCursor cfg "hello" `shouldBe` "hello\x2589"

    it "returns text unchanged when cursor is empty" $
      let c = cfg { spcCursor = "" } in addCursor c "hello" `shouldBe` "hello"

    prop "addCursor then stripCursor is identity" $
      forAll genSafeText $ \s ->
        stripCursor cfg (addCursor cfg s) == s

  describe "stripCursor" $ do
    it "removes the cursor from the end of text" $
      stripCursor cfg "hello\x2589" `shouldBe` "hello"

    it "returns text unchanged when cursor is empty" $
      let c = cfg { spcCursor = "" } in stripCursor c "hello" `shouldBe` "hello"

    it "returns text unchanged when cursor is not at the end" $
      stripCursor cfg "\x2589hello" `shouldBe` "\x2589hello"

  describe "defaultStreamProgressConfig" $ do
    it "has enabled = True" $
      spcEnabled defaultStreamProgressConfig `shouldBe` True

    it "has editIntervalMs = 1500" $
      spcEditIntervalMs defaultStreamProgressConfig `shouldBe` 1500

    it "has bufferThreshold = 80" $
      spcBufferThreshold defaultStreamProgressConfig `shouldBe` 80

    it "has a non-empty cursor" $
      spcCursor defaultStreamProgressConfig `shouldSatisfy` (not . T.null)
