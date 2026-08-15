{-# LANGUAGE OverloadedStrings #-}
module Seal.Tools.Exec.AbortSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (replicateM)
import Test.Hspec

import Seal.Core.Types (mkSystemSessionId)
import Seal.Tools.Exec.Abort

spec :: Spec
spec = describe "Seal.Tools.Exec.Abort" $ do

  describe "AbortFlag" $ do
    it "fresh flag is not aborted" $ do
      flag <- newAbortFlag
      isAborted flag `shouldReturn` False

    it "setAbort → isAborted True" $ do
      flag <- newAbortFlag
      setAbort flag
      isAborted flag `shouldReturn` True

    it "clearAbort after setAbort → isAborted False" $ do
      flag <- newAbortFlag
      setAbort flag
      clearAbort flag
      isAborted flag `shouldReturn` False

    it "setAbort is idempotent" $ do
      flag <- newAbortFlag
      setAbort flag
      setAbort flag
      isAborted flag `shouldReturn` True

    it "clearAbort on a fresh flag is a no-op" $ do
      flag <- newAbortFlag
      clearAbort flag
      isAborted flag `shouldReturn` False

    it "waitForAbort returns True after setAbort" $ do
      flag <- newAbortFlag
      setAbort flag
      r <- waitForAbort flag 1_000_000
      r `shouldBe` True

    it "waitForAbort returns True immediately if already aborted" $ do
      flag <- newAbortFlag
      setAbort flag
      r <- waitForAbort flag 10_000_000
      r `shouldBe` True

    it "waitForAbort polls and detects a delayed setAbort" $ do
      flag <- newAbortFlag
      -- Simulate a delayed abort: set the flag after 50ms.
      forkSetAbort flag 50_000
      -- waitForAbort polls every 10ms; should detect within ~60ms.
      r <- waitForAbort flag 10_000_000
      r `shouldBe` True

    it "multiple flags are independent" $ do
      f1 <- newAbortFlag
      f2 <- newAbortFlag
      setAbort f1
      isAborted f1 `shouldReturn` True
      isAborted f2 `shouldReturn` False
      setAbort f2
      isAborted f2 `shouldReturn` True
      clearAbort f1
      isAborted f1 `shouldReturn` False
      isAborted f2 `shouldReturn` True

  describe "SessionAbortRegistry" $ do
    it "lookupOrCreateAbortFlag twice for the same SessionId returns the same flag" $ do
      reg <- newSessionAbortRegistry
      let sid = mkSystemSessionId "sess-1"
      f1 <- lookupOrCreateAbortFlag reg sid
      f2 <- lookupOrCreateAbortFlag reg sid
      isAborted f1 `shouldReturn` False
      setAbort f1
      isAborted f2 `shouldReturn` True

    it "setSessionAbort makes isAborted True for that session" $ do
      reg <- newSessionAbortRegistry
      let sid = mkSystemSessionId "sess-2"
      setSessionAbort reg sid
      flag <- lookupOrCreateAbortFlag reg sid
      isAborted flag `shouldReturn` True

    it "clearSessionAbort resets the flag" $ do
      reg <- newSessionAbortRegistry
      let sid = mkSystemSessionId "sess-3"
      setSessionAbort reg sid
      clearSessionAbort reg sid
      flag <- lookupOrCreateAbortFlag reg sid
      isAborted flag `shouldReturn` False

    it "different sessions are independent" $ do
      reg <- newSessionAbortRegistry
      let sid1 = mkSystemSessionId "sess-a"
          sid2 = mkSystemSessionId "sess-b"
      setSessionAbort reg sid1
      f1 <- lookupOrCreateAbortFlag reg sid1
      f2 <- lookupOrCreateAbortFlag reg sid2
      isAborted f1 `shouldReturn` True
      isAborted f2 `shouldReturn` False
      clearSessionAbort reg sid1
      isAborted f1 `shouldReturn` False
      isAborted f2 `shouldReturn` False

    it "lookupOrCreateAbortFlag is atomic — sequential lookups yield the same flag" $ do
      reg <- newSessionAbortRegistry
      let sid = mkSystemSessionId "sess-concurrent"
      flags <- replicateM 5 (lookupOrCreateAbortFlag reg sid)
      -- (We can't compare IORef identity easily, but we can verify behavior:
      -- setting one affects all.)
      case flags of
        f : _ -> do
          setAbort f
          mapM isAborted flags `shouldReturn` [True, True, True, True, True]
        [] -> expectationFailure "replicateM 5 should never return []"

-- | Fork a thread that sets the abort flag after the given delay (microseconds).
forkSetAbort :: AbortFlag -> Int -> IO ()
forkSetAbort flag delayUs = do
  _ <- forkIO $ do
    threadDelay delayUs
    setAbort flag
  pure ()