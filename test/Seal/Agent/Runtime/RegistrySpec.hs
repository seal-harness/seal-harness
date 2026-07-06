{-# LANGUAGE OverloadedStrings #-}
module Seal.Agent.Runtime.RegistrySpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Data.IORef
import Test.Hspec

import Seal.Agent.Def.Types (AgentDefId (..), mkAgentDefId)
import Seal.Agent.Runtime.Registry
import Seal.Core.Types (SessionId (..))
import Seal.TestHelpers.Arbitrary ()

sampleDefId :: AgentDefId
sampleDefId = case mkAgentDefId "a1" of
  Right aid -> aid
  Left _    -> AgentDefId "fallback"

sampleSession :: SessionId
sampleSession = SessionId "s1"

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
      res <- startAgent rt sampleDefId sampleSession (blockingWorker ran)
      res `shouldSatisfy` isRight
      -- give the fork a moment to run the worker
      threadDelay 50000
      readIORef ran `shouldReturn` True
      agentStatus rt sampleDefId `shouldReturn` Just Running
      -- cleanup
      _ <- stopAgent rt sampleDefId
      pure ()

    it "rejects a duplicate start (no two instances share a def id)" $ do
      rt <- newAgentRuntime
      ran <- newIORef False
      r1 <- startAgent rt sampleDefId sampleSession (blockingWorker ran)
      r2 <- startAgent rt sampleDefId sampleSession (blockingWorker ran)
      r1 `shouldSatisfy` isRight
      r2 `shouldSatisfy` isLeft
      _ <- stopAgent rt sampleDefId
      pure ()

  describe "agentStatus" $ do
    it "returns Nothing when not running" $ do
      rt <- newAgentRuntime
      agentStatus rt sampleDefId `shouldReturn` Nothing

    it "records Crashed when the worker throws" $ do
      rt <- newAgentRuntime
      _ <- startAgent rt sampleDefId sampleSession (throwIO (userError "boom"))
      -- give the fork a moment to throw
      threadDelay 50000
      mStatus <- agentStatus rt sampleDefId
      mStatus `shouldSatisfy` maybe False isCrashed
      _ <- stopAgent rt sampleDefId
      pure ()

  describe "stopAgent" $ do
    it "removes the instance (a fresh start can proceed)" $ do
      rt <- newAgentRuntime
      ran <- newIORef False
      _ <- startAgent rt sampleDefId sampleSession (blockingWorker ran)
      _ <- stopAgent rt sampleDefId
      agentStatus rt sampleDefId `shouldReturn` Nothing
      -- a fresh start succeeds after stop
      r2 <- startAgent rt sampleDefId sampleSession (blockingWorker ran)
      r2 `shouldSatisfy` isRight
      _ <- stopAgent rt sampleDefId
      pure ()

    it "is idempotent (stopping a non-running def id is a success)" $ do
      rt <- newAgentRuntime
      stopAgent rt sampleDefId `shouldReturn` Right ()

  describe "listAgents" $ do
    it "snapshots running instances" $ do
      rt <- newAgentRuntime
      ran <- newIORef False
      _ <- startAgent rt sampleDefId sampleSession (blockingWorker ran)
      threadDelay 50000
      insts <- listAgents rt
      length insts `shouldBe` 1
      case insts of
        [i] -> aiId i `shouldBe` sampleDefId
        _   -> expectationFailure "expected exactly one instance"
      _ <- stopAgent rt sampleDefId
      pure ()

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left _)  = False

isLeft :: Either a b -> Bool
isLeft (Left _)  = True
isLeft (Right _) = False

isCrashed :: AgentStatus -> Bool
isCrashed (Crashed _) = True
isCrashed _            = False