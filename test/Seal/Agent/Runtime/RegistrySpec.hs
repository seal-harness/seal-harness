{-# LANGUAGE OverloadedStrings #-}
module Seal.Agent.Runtime.RegistrySpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Data.IORef
import Test.Hspec

import Seal.Agent.Def.Types (AgentDefId (..), mkAgentDefId)
import Seal.Agent.Runtime.Delegation (SubagentId (..))
import Seal.Agent.Runtime.Registry
import Seal.Core.Types (SessionId (..))

sampleDefId :: AgentDefId
sampleDefId = case mkAgentDefId "a1" of
  Right aid -> aid
  Left _    -> AgentDefId "fallback"

sampleSession :: SessionId
sampleSession = SessionId "s1"

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
      res <- startAgent rt sampleDefId sampleSubagentId sampleSession 0 (blockingWorker ran)
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
      _ <- startAgent rt sampleDefId sampleSubagentId sampleSession 0 (throwIO (userError "boom"))
      -- give the fork a moment to throw
      threadDelay 50000
      mStatus <- agentStatus rt sampleSubagentId
      mStatus `shouldSatisfy` maybe False isCrashed
      _ <- stopAgent rt sampleSubagentId
      pure ()

  describe "stopAgent" $ do
    it "removes the instance (a fresh start can proceed)" $ do
      rt <- newAgentRuntime
      ran <- newIORef False
      _ <- startAgent rt sampleDefId sampleSubagentId sampleSession 0 (blockingWorker ran)
      _ <- stopAgent rt sampleSubagentId
      agentStatus rt sampleSubagentId `shouldReturn` Nothing
      -- a fresh start succeeds after stop
      let sid2 = SubagentId "sa-a1-00000002"
      r2 <- startAgent rt sampleDefId sid2 sampleSession 0 (blockingWorker ran)
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
      _ <- startAgent rt sampleDefId sampleSubagentId sampleSession 0 (blockingWorker ran)
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
      _ <- startAgent rt sampleDefId sampleSubagentId sampleSession 0 (blockingWorker ran)
      threadDelay 50000
      insts <- listAgents rt
      length insts `shouldBe` 1
      case insts of
        [i] -> aiId i `shouldBe` sampleDefId
        _   -> expectationFailure "expected exactly one instance"
      _ <- stopAgent rt sampleSubagentId
      pure ()

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left _)  = False

isCrashed :: AgentStatus -> Bool
isCrashed (Crashed _) = True
isCrashed _            = False