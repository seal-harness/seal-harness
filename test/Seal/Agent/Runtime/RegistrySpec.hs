{-# LANGUAGE OverloadedStrings #-}
module Seal.Agent.Runtime.RegistrySpec (spec) where

import Control.Concurrent (myThreadId, threadDelay)
import Control.Exception (throwIO)
import Control.Monad (forM)
import Data.Text qualified as T
import Data.IORef
import Test.Hspec

import Seal.Agent.Def.Types (AgentDefId (..), mkAgentDefId)
import Seal.Agent.Runtime.Delegation
  ( SubagentId (..), ChildResult (..), ChildStatus (..), ChildExitReason (..) )
import Seal.Agent.Runtime.Registry
import Seal.Core.Types (SessionId, mkSystemSessionId)

sampleDefId :: AgentDefId
sampleDefId = case mkAgentDefId "a1" of
  Right aid -> aid
  Left _    -> AgentDefId "fallback"

sampleSession :: SessionId
sampleSession = mkSystemSessionId "s1"

sampleParentSession :: SessionId
sampleParentSession = mkSystemSessionId "parent"

sampleSubagentId :: SubagentId
sampleSubagentId = SubagentId "sa-a1-00000001"

-- | A worker that records it ran, then blocks (so the instance stays Running
-- for status assertions). The registry marks it Running once the fork succeeds.
blockingWorker :: IORef Bool -> IO ()
blockingWorker ref = do
  writeIORef ref True
  threadDelay 1000000  -- 1s; the test stops the agent before this elapses

spec :: Spec
spec = describe "Seal.Agent.Runtime.Registry" $ do
  describe "startAgent" $ do
    it "forks the worker and records the instance as Running" $ do
      rt <- newAgentRuntime
      ran <- newIORef False
      res <- startAgent rt sampleDefId sampleSubagentId sampleParentSession sampleSession 0 (blockingWorker ran)
      res `shouldSatisfy` isRight
      -- give the fork a moment to run the worker
      threadDelay 50000
      readIORef ran `shouldReturn` True
      agentStatus rt sampleSubagentId `shouldReturn` Just Running
      -- cleanup
      _ <- stopAgent rt sampleSubagentId
      pure ()

  describe "agentStatus" $ do
    it "returns Nothing when not running" $ do
      rt <- newAgentRuntime
      agentStatus rt sampleSubagentId `shouldReturn` Nothing

    it "records Crashed when the worker throws" $ do
      rt <- newAgentRuntime
      _ <- startAgent rt sampleDefId sampleSubagentId sampleParentSession sampleSession 0 (throwIO (userError "boom"))
      -- Poll for the async crash transition instead of one fixed sleep:
      -- under full-suite load a bare 50ms wait can observe Running and
      -- flake. Bounded at ~2s (200 × 10ms) so the suite stays fast.
      crashed <- pollUntilCrashed rt sampleSubagentId 200
      crashed `shouldBe` True
      _ <- stopAgent rt sampleSubagentId
      pure ()

  describe "startAgent crash handshake" $ do
    -- The worker must not be able to run before its registry entry exists: an
    -- agent that throws on its first line would report its crash (a Map.adjust
    -- keyed by subagent id) to a map that does not hold it yet, and the insert
    -- would then leave the instance Running forever. Repeated so that a lost
    -- update shows up even when the scheduler usually orders it the safe way.
    it "never loses a crash that happens immediately" $ do
      results <- forM [1 .. 50 :: Int] $ \n -> do
        rt <- newAgentRuntime
        let sid = SubagentId ("sa-a1-crash-" <> T.pack (show n))
        _ <- startAgent rt sampleDefId sid sampleParentSession sampleSession 0
               (throwIO (userError "boom"))
        crashed <- pollUntilCrashed rt sid 100
        _ <- stopAgent rt sid
        pure crashed
      results `shouldSatisfy` and

  describe "stopAgent" $ do
    it "removes the instance (a fresh start can proceed)" $ do
      rt <- newAgentRuntime
      ran <- newIORef False
      _ <- startAgent rt sampleDefId sampleSubagentId sampleParentSession sampleSession 0 (blockingWorker ran)
      _ <- stopAgent rt sampleSubagentId
      agentStatus rt sampleSubagentId `shouldReturn` Nothing
      -- a fresh start succeeds after stop
      let sid2 = SubagentId "sa-a1-00000002"
      r2 <- startAgent rt sampleDefId sid2 sampleParentSession sampleSession 0 (blockingWorker ran)
      r2 `shouldSatisfy` isRight
      _ <- stopAgent rt sid2
      pure ()

    it "is idempotent (stopping a non-running subagent id is a success)" $ do
      rt <- newAgentRuntime
      stopAgent rt sampleSubagentId `shouldReturn` Right ()

  describe "interruptAgent" $ do
    it "sets the status to Interrupted for a running instance" $ do
      rt <- newAgentRuntime
      ran <- newIORef False
      _ <- startAgent rt sampleDefId sampleSubagentId sampleParentSession sampleSession 0 (blockingWorker ran)
      found <- interruptAgent rt sampleSubagentId
      found `shouldBe` True
      agentStatus rt sampleSubagentId `shouldReturn` Just Interrupted
      _ <- stopAgent rt sampleSubagentId
      pure ()

    it "returns False when no instance matches the subagent id" $ do
      rt <- newAgentRuntime
      found <- interruptAgent rt sampleSubagentId
      found `shouldBe` False

  describe "listAgents" $ do
    it "snapshots running instances" $ do
      rt <- newAgentRuntime
      ran <- newIORef False
      _ <- startAgent rt sampleDefId sampleSubagentId sampleParentSession sampleSession 0 (blockingWorker ran)
      threadDelay 50000
      insts <- listAgents rt
      length insts `shouldBe` 1
      case insts of
        [i] -> aiId i `shouldBe` sampleDefId
        _   -> expectationFailure "expected exactly one instance"
      _ <- stopAgent rt sampleSubagentId
      pure ()

  describe "hasRunningChildren" $ do
    it "returns False when no agents are registered" $ do
      rt <- newAgentRuntime
      hasRunningChildren rt sampleParentSession `shouldReturn` False

    it "returns True when a running child is registered for the parent" $ do
      rt <- newAgentRuntime
      ran <- newIORef False
      _ <- startAgent rt sampleDefId sampleSubagentId sampleParentSession sampleSession 0 (blockingWorker ran)
      threadDelay 50000  -- let the fork record the instance
      hasRunningChildren rt sampleParentSession `shouldReturn` True
      _ <- stopAgent rt sampleSubagentId
      pure ()

    it "returns False after the child completes (status transitions to Stopped)" $ do
      rt <- newAgentRuntime
      let sid = SubagentId "sa-a1-00000003"
      registerRunningAgent rt sampleDefId sid sampleParentSession sampleSession 0 =<< myThreadId
      hasRunningChildren rt sampleParentSession `shouldReturn` True
      let result = ChildResult
            { crTaskIndex = 0
            , crStatus = CsCompleted
            , crSummary = Just "done"
            , crExitReason = CerCompleted
            , crDurationSeconds = 0.1
            , crSubagentId = sid
            , crTokensInput = 0
            , crTokensOutput = 0
            , crToolTrace = []
            , crError = Nothing
            , crFilesRead = []
            , crFilesWritten = []
            , crChildSession = Just sampleSession
            }
      registerCompletedAgentResult rt sid result
      hasRunningChildren rt sampleParentSession `shouldReturn` False

    it "returns False for a parent with no children even when another parent has running children" $ do
      rt <- newAgentRuntime
      ran <- newIORef False
      let otherParent = mkSystemSessionId "other-parent"
      _ <- startAgent rt sampleDefId sampleSubagentId otherParent sampleSession 0 (blockingWorker ran)
      threadDelay 50000
      hasRunningChildren rt sampleParentSession `shouldReturn` False
      hasRunningChildren rt otherParent `shouldReturn` True
      _ <- stopAgent rt sampleSubagentId
      pure ()

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left _)  = False

-- | Poll a subagent's status until it is 'Crashed', for at most @n * 10ms@.
pollUntilCrashed :: AgentRuntime -> SubagentId -> Int -> IO Bool
pollUntilCrashed rt sid n
  | n <= (0 :: Int) = pure False
  | otherwise = do
      mStatus <- agentStatus rt sid
      case mStatus of
        Just s | isCrashed s -> pure True
        _ -> threadDelay 10000 >> pollUntilCrashed rt sid (n - 1)

isCrashed :: AgentStatus -> Bool
isCrashed (Crashed _) = True
isCrashed _            = False
