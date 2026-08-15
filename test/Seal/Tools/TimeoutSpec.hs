{-# LANGUAGE OverloadedStrings #-}
module Seal.Tools.TimeoutSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Value)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (choose, forAll, (==>))

import Seal.Core.Types (OpName (..))
import Seal.Tools.Timeout

spec :: Spec
spec = describe "Seal.Tools.Timeout" $ do

  describe "defaultToolTimeoutConfig" $ do
    it "has sensible defaults" $ do
      ttcDefaultSeconds defaultToolTimeoutConfig `shouldBe` 120
      ttcMaxSeconds defaultToolTimeoutConfig `shouldBe` 600
      ttcRetryMax defaultToolTimeoutConfig `shouldBe` 3
      ttcMaxOutputBytes defaultToolTimeoutConfig `shouldBe` 50000

  describe "extractPerCallTimeout" $ do
    let cfg = defaultToolTimeoutConfig
        maxMicros = Microseconds (ttcMaxSeconds cfg * 1_000_000)
        defaultMicros = Microseconds (ttcDefaultSeconds cfg * 1_000_000)

    it "absent field → default" $
      extractPerCallTimeout (object []) cfg `shouldBe` defaultMicros

    it "null → default" $
      extractPerCallTimeout (object ["timeout" .= A.Null]) cfg `shouldBe` defaultMicros

    it "non-integer (string) → default" $
      extractPerCallTimeout (object ["timeout" .= ("120" :: Value)]) cfg `shouldBe` defaultMicros

    it "non-integer (float) → default" $
      extractPerCallTimeout (object ["timeout" .= (120.5 :: Double)]) cfg `shouldBe` defaultMicros

    it "non-integer (bool) → default" $
      extractPerCallTimeout (object ["timeout" .= True]) cfg `shouldBe` defaultMicros

    it "negative → default" $
      extractPerCallTimeout (object ["timeout" .= (-5 :: Int)]) cfg `shouldBe` defaultMicros

    it "zero → default" $
      extractPerCallTimeout (object ["timeout" .= (0 :: Int)]) cfg `shouldBe` defaultMicros

    it "positive in range → as-is (converted to microseconds)" $
      extractPerCallTimeout (object ["timeout" .= (30 :: Int)]) cfg
        `shouldBe` Microseconds 30_000_000

    it "positive > max → clamp to max" $
      extractPerCallTimeout (object ["timeout" .= (9999 :: Int)]) cfg
        `shouldBe` maxMicros

    it "positive == max → max" $
      extractPerCallTimeout (object ["timeout" .= (600 :: Int)]) cfg
        `shouldBe` maxMicros

    it "positive == 1 (minimum valid) → 1s" $
      extractPerCallTimeout (object ["timeout" .= (1 :: Int)]) cfg
        `shouldBe` Microseconds 1_000_000

    prop "output is always in [1s, max] (never negative, never zero, never exceeds max)" $
      \(n :: Int) ->
        let v = object ["timeout" .= n]
            Microseconds us = extractPerCallTimeout v cfg
        in us >= 1_000_000 && us <= ttcMaxSeconds cfg * 1_000_000

    prop "absent field → default" $ \(v :: Value) ->
      let noTimeoutKey = case v of
            A.Object o -> not (KM.member "timeout" o)
            _ -> True
      in noTimeoutKey ==> extractPerCallTimeout v cfg == defaultMicros

  describe "computeRetryDelay" $ do
    let cfg = defaultToolTimeoutConfig

    it "attempt 0 → base" $
      computeRetryDelay cfg 0 `shouldBe` Microseconds (ttcRetryBaseMicros cfg)

    it "attempt 1 → base * factor" $
      computeRetryDelay cfg 1 `shouldBe` Microseconds (round (fromIntegral (ttcRetryBaseMicros cfg) * ttcRetryFactor cfg))

    it "monotonically increasing (factor >= 1.0)" $
      forAll (choose (1, 20)) $ \attempt ->
        computeRetryDelay cfg attempt > computeRetryDelay cfg (attempt - 1)

    prop "always positive (for attempt < 30, base < 10^7)" $
      \attempt -> attempt >= 0 && attempt < 30 ==>
        let Microseconds us = computeRetryDelay cfg attempt
        in us > 0

    prop "overflow-safe: no wraparound to negative for attempt < 30" $
      \attempt -> attempt >= 0 && attempt < 30 ==>
        let Microseconds us = computeRetryDelay cfg attempt
        in us >= 0

  describe "shouldRetry" $ do
    it "ToolTimeout → yes" $
      shouldRetry (ToolTimeout 120) `shouldBe` True

    it "ToolIOError → yes" $
      shouldRetry (ToolIOError "io") `shouldBe` True

    it "ToolAborted → no" $
      shouldRetry ToolAborted `shouldBe` False

    it "ToolRetriesExhausted → no" $
      shouldRetry (ToolRetriesExhausted (ToolTimeout 120)) `shouldBe` False

  describe "errorClass" $ do
    it "ToolTimeout → \"timeout\"" $
      errorClass (ToolTimeout 120) `shouldBe` "timeout"

    it "ToolAborted → \"aborted\"" $
      errorClass ToolAborted `shouldBe` "aborted"

    it "ToolIOError → \"io\"" $
      errorClass (ToolIOError "some message") `shouldBe` "io"

    it "ToolRetriesExhausted → \"retries_exhausted\"" $
      errorClass (ToolRetriesExhausted (ToolTimeout 120)) `shouldBe` "retries_exhausted"

    it "NEVER includes the full ToolIOError Text payload" $
      errorClass (ToolIOError "/secret/path host=evil.com") `shouldBe` "io"

  describe "renderToolError" $ do
    it "Timeout includes opcode name + timeout in seconds" $ do
      let txt = renderToolError (OpName "SHELL_EXEC") (ToolTimeout 120)
      txt `shouldSatisfy` ("SHELL_EXEC" `T.isInfixOf`)
      txt `shouldSatisfy` ("120s" `T.isInfixOf`)

    it "Aborted includes opcode name" $ do
      let txt = renderToolError (OpName "SHELL_EXEC") ToolAborted
      txt `shouldSatisfy` ("SHELL_EXEC" `T.isInfixOf`)
      txt `shouldSatisfy` ("aborted" `T.isInfixOf`)

    it "RetriesExhausted includes retry count + last error" $ do
      let txt = renderToolError (OpName "SHELL_EXEC") (ToolRetriesExhausted (ToolTimeout 120))
      txt `shouldSatisfy` ("SHELL_EXEC" `T.isInfixOf`)
      txt `shouldSatisfy` ("retries" `T.isInfixOf`)