{-# LANGUAGE OverloadedStrings #-}
module Seal.Tools.Exec.TimeoutSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Test.Hspec

import Seal.Tools.Exec.Abort
import Seal.Tools.Exec.Timeout
import Seal.Tools.Timeout

spec :: Spec
spec = describe "Seal.Tools.Exec.Timeout" $ do

  let cfg = defaultToolTimeoutConfig

  describe "runWithTimeoutAbortRetry" $ do

    it "fast-completing action returns result immediately" $ do
      flag <- newAbortFlag
      let action = pure (Right ("done" :: String) :: Either ToolError String)
      r <- runWithTimeoutAbortRetry cfg flag (Microseconds 1_000_000) action
      r `shouldBe` Right "done"

    it "hanging action times out (retried then exhausted)" $ do
      flag <- newAbortFlag
      -- Use a tiny timeout + a long hang to keep the test fast. The action
      -- always hangs, so it times out, retries (3x with 1ms backoff), then
      -- surfaces ToolRetriesExhausted wrapping ToolTimeout.
      let cfg' = cfg { ttcDefaultSeconds = 1, ttcRetryMax = 3, ttcRetryBaseMicros = 1_000, ttcRetryFactor = 1.0 }
          tinyTimeout = Microseconds 50_000  -- 50ms
          action = do
            threadDelay 10_000_000  -- 10s — way longer than the timeout
            pure (Right "should not reach" :: Either ToolError String)
      r <- runWithTimeoutAbortRetry cfg' flag tinyTimeout action
      case r of
        Left (ToolRetriesExhausted (ToolTimeout _)) -> pure ()  -- expected
        _ -> expectationFailure ("expected ToolRetriesExhausted ToolTimeout, got " ++ show r)

    it "aborted action returns ToolAborted" $ do
      flag <- newAbortFlag
      setAbort flag
      let action = do
            threadDelay 10_000_000
            pure (Right "should not reach" :: Either ToolError String)
      r <- runWithTimeoutAbortRetry cfg flag (Microseconds 1_000_000) action
      r `shouldBe` Left ToolAborted

    it "aborted mid-action returns ToolAborted (detected during race)" $ do
      flag <- newAbortFlag
      -- Start a long action; set abort after 30ms; poll interval 10ms.
      let cfg' = cfg { ttcAbortPollMicros = 10_000, ttcDefaultSeconds = 10 }
          action = do
            threadDelay 5_000_000  -- 5s — long enough to detect the abort
            pure (Right "should not reach" :: Either ToolError String)
      -- Fork a delayed abort.
      _ <- forkSetAbort flag 30_000
      r <- runWithTimeoutAbortRetry cfg' flag (Microseconds 60_000_000) action
      case r of
        Left ToolAborted -> pure ()  -- expected
        _ -> expectationFailure ("expected ToolAborted, got " ++ show r)

    it "transient IO error retried 3x then ToolRetriesExhausted" $ do
      flag <- newAbortFlag
      -- An action that always fails with an IO error. Should retry 3x
      -- (with backoff) then surface ToolRetriesExhausted. Use a tiny
      -- base delay to keep the test fast.
      let cfg' = cfg { ttcRetryMax = 3, ttcRetryBaseMicros = 1_000, ttcRetryFactor = 1.0 }
          action = pure (Left (ToolIOError "transient") :: Either ToolError String)
      r <- runWithTimeoutAbortRetry cfg' flag (Microseconds 1_000_000) action
      case r of
        Left (ToolRetriesExhausted (ToolIOError _)) -> pure ()  -- expected
        _ -> expectationFailure ("expected ToolRetriesExhausted ToolIOError, got " ++ show r)

    it "successful action not retried (returns immediately)" $ do
      flag <- newAbortFlag
      -- An action that succeeds on the first attempt. Should NOT retry.
      let action = pure (Right ("ok" :: String) :: Either ToolError String)
      r <- runWithTimeoutAbortRetry cfg flag (Microseconds 1_000_000) action
      r `shouldBe` Right "ok"

    it "abort during retry sleep: detected before next attempt" $ do
      flag <- newAbortFlag
      -- An action that fails (so it'll retry), but we set abort during the
      -- retry sleep. The loop should check-before-sleep + check-after-sleep,
      -- detect the abort, and return ToolAborted (not retry again).
      let cfg' = cfg { ttcRetryMax = 5, ttcRetryBaseMicros = 500_000, ttcRetryFactor = 1.0 }
          -- 500ms sleep between retries; set abort at 100ms into the first sleep.
          action = pure (Left (ToolTimeout 1) :: Either ToolError String)
      _ <- forkSetAbort flag 100_000
      r <- runWithTimeoutAbortRetry cfg' flag (Microseconds 10_000_000) action
      case r of
        Left ToolAborted -> pure ()  -- expected: abort detected before next attempt
        _ -> expectationFailure ("expected ToolAborted (abort during sleep), got " ++ show r)

    it "ToolAborted is NOT retried (respects user cancellation immediately)" $ do
      flag <- newAbortFlag
      let action = pure (Left ToolAborted :: Either ToolError String)
      r <- runWithTimeoutAbortRetry cfg flag (Microseconds 1_000_000) action
      r `shouldBe` Left ToolAborted

    it "Right result with error semantics is NOT retried" $ do
      flag <- newAbortFlag
      -- A 'Right' result that's semantically an error (the opcode returned
      -- an error OpResult). This is NOT a transport failure — must NOT retry.
      let action = pure (Right ("semantic error" :: String) :: Either ToolError String)
      r <- runWithTimeoutAbortRetry cfg flag (Microseconds 1_000_000) action
      r `shouldBe` Right "semantic error"

-- | Fork a thread that sets the abort flag after the given delay (microseconds).
forkSetAbort :: AbortFlag -> Int -> IO ()
forkSetAbort flag delayUs = do
  _ <- forkIO $ do
    threadDelay delayUs
    setAbort flag
  pure ()