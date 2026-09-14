{-# LANGUAGE OverloadedStrings #-}
module Seal.Channels.StreamProgressSpec (spec) where

import Data.Default (Default (..))
import Test.Hspec

import Seal.Channels.StreamProgress
  ( StreamProgressConfig (..)
  , resolveStreamProgressConfig
  )

spec :: Spec
spec = do
  describe "Seal.Channels.StreamProgress.defaultStreamProgressConfig" $ do
    it "is disabled by default" $
      spcEnabled def `shouldBe` False

    it "has tool_progress enabled when enabled" $
      spcToolProgress def `shouldBe` True

    it "has text_streaming enabled when enabled" $
      spcTextStreaming def `shouldBe` True

    it "has a 1500ms edit interval" $
      spcEditIntervalMs def `shouldBe` 1500

    it "has a buffer threshold of 80 codepoints" $
      spcBufferThreshold def `shouldBe` 80

    it "has a block cursor" $
      spcCursor def `shouldBe` "\x2589"

  describe "Seal.Channels.StreamProgress.resolveStreamProgressConfig" $ do
    it "returns disabled config when Nothing" $
      resolveStreamProgressConfig Nothing `shouldBe` def

    it "resolves a fully-populated config" $
      resolveStreamProgressConfig (Just def { spcEnabled = True, spcEditIntervalMs = 2000 })
        `shouldBe` def { spcEnabled = True, spcEditIntervalMs = 2000 }

    it "fills defaults for absent fields" $
      resolveStreamProgressConfig (Just def { spcEnabled = True })
        `shouldBe` def { spcEnabled = True }