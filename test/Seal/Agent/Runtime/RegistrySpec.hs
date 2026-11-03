{-# LANGUAGE OverloadedStrings #-}
module Seal.Agent.Runtime.RegistrySpec (spec) where

import Control.Concurrent (myThreadId, threadDelay)
import Control.Exception (throwIO)
import Data.List (isInfixOf)
import Data.IORef
import qualified Data.Text as T
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

-- | Status lookup through the owner-scoped API (Nothing = unknown/not owned).
statusOf :: AgentRuntime -> SubagentId -> IO (Maybe AgentStatus)
statusOf rt sid =
  either (const Nothing) (Just . aiStatus) <$> agentStatusFor rt sampleParentSession sid

-- | A worker that records it ran, then blocks (so the instance stays Running
-- for status assertions). The registry marks it Running once the fork succeeds.
blockingWorker :: IORef Bool -> IO ()
blockingWorker ref = do
  writeIORef ref True
  threadDelay 1000000  -- 1s; the test stops the agent before this elapses

spec :: Spec
spec = describe "Seal.Agent.Runtime.Registry" $ do
  describe "AgentInstance rendering" $ do
    it "elides the task, def, and result bodies in Show" $ do
      rt <- newAgentRuntime
      ran <- newIORef False
      _ <- startAgent rt sampleDefId sampleSubagentId sampleParentSession sampleSession 0 (blockingWorker ran)
      insts <- listAgents rt
      case insts of
        [i] -> do
          let rendered = show i
          -- a spawn has no snapshot yet, but the field names must be present
          "aiTask = Nothing" `isInfixOf` rendered `shouldBe` True
          "aiResult = Nothing" `isInfixOf` rendered `shouldBe` True
        _ -> expectationFailure "expected exactly one instance"
      _ <- stopAgent rt sampleParentSession sampleSubagentId
      pure ()

    it "records a fresh spawn as run 1 with its worker thread" $ do
      rt <- newAgentRuntime
      ran <- newIORef False
      tid <- myThreadId
      _ <- startAgent rt sampleDefId sampleSubagentId sampleParentSession sampleSession 0 (blockingWorker ran)
      insts <- listAgents rt
      case insts of
        [i] -> do
          aiRuns i `shouldBe` 1
          aiWorkerThread i `shouldSatisfy` (/= Just tid)
        _ -> expectationFailure "expected exactly one instance"
      _ <- stopAgent rt sampleParentSession sampleSubagentId
      pure ()

  describe "startAgent" $ do
    it "forks the worker and records the instance as Running" $ do
      rt <- newAgentRuntime
      ran <- newIORef False
      res <- startAgent rt sampleDefId sampleSubagentId sampleParentSession sampleSession 0 (blockingWorker ran)
      res `shouldSatisfy` isRight
      -- give the fork a moment to run the worker
      threadDelay 50000
      readIORef ran `shouldReturn` True
      statusOf rt sampleSubagentId `shouldReturn` Just Running
      -- cleanup
      _ <- stopAgent rt sampleParentSession sampleSubagentId
      pure ()

  describe "agentStatus" $ do
    it "returns Nothing when not running" $ do
      rt <- newAgentRuntime
      statusOf rt sampleSubagentId `shouldReturn` Nothing

    it "records Crashed when the worker throws" $ do
      rt <- newAgentRuntime
      _ <- startAgent rt sampleDefId sampleSubagentId sampleParentSession sampleSession 0 (throwIO (userError "boom"))
      -- Poll for the async crash transition instead of one fixed sleep:
      -- under full-suite load a bare 50ms wait can observe Running and
      -- flake. Bounded at ~2s (200 × 10ms) so the suite stays fast.
      let pollUntilCrashed :: Int -> IO Bool
          pollUntilCrashed n
            | n <= (0 :: Int) = pure False
            | otherwise = do
                mStatus <- statusOf rt sampleSubagentId
                case mStatus of
                  Just s | isCrashed s -> pure True
                  _ -> threadDelay 10000 >> pollUntilCrashed (n - 1)
      crashed <- pollUntilCrashed 200
      crashed `shouldBe` True
      _ <- stopAgent rt sampleParentSession sampleSubagentId
      pure ()

  describe "stopAgent" $ do
    it "retains the instance as Stopped so it stays resumable" $ do
      rt <- newAgentRuntime
      ran <- newIORef False
      _ <- startAgent rt sampleDefId sampleSubagentId sampleParentSession sampleSession 0 (blockingWorker ran)
      _ <- stopAgent rt sampleParentSession sampleSubagentId
      statusOf rt sampleSubagentId `shouldReturn` Just Stopped
      -- a fresh start with a new id still proceeds
      let sid2 = SubagentId "sa-a1-00000002"
      r2 <- startAgent rt sampleDefId sid2 sampleParentSession sampleSession 0 (blockingWorker ran)
      r2 `shouldSatisfy` isRight
      _ <- stopAgent rt sampleParentSession sid2
      pure ()

    it "is idempotent (stopping a non-running subagent id is a success)" $ do
      rt <- newAgentRuntime
      stopAgent rt sampleParentSession sampleSubagentId `shouldReturn` Right StopOk

  describe "interruptAgent" $ do
    it "sets the status to Interrupted for a running instance" $ do
      rt <- newAgentRuntime
      ran <- newIORef False
      _ <- startAgent rt sampleDefId sampleSubagentId sampleParentSession sampleSession 0 (blockingWorker ran)
      found <- interruptAgent rt sampleParentSession sampleSubagentId
      found `shouldBe` Right True
      statusOf rt sampleSubagentId `shouldReturn` Just Interrupted
      _ <- stopAgent rt sampleParentSession sampleSubagentId
      pure ()

    it "returns False when no instance matches the subagent id" $ do
      rt <- newAgentRuntime
      found <- interruptAgent rt sampleParentSession sampleSubagentId
      found `shouldBe` Right False

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
      _ <- stopAgent rt sampleParentSession sampleSubagentId
      pure ()

  describe "ownership" $ do
    it "refuses a child owned by another session" $ do
      rt <- newAgentRuntime
      ran <- newIORef False
      _ <- startAgent rt sampleDefId sampleSubagentId sampleParentSession sampleSession 0 (blockingWorker ran)
      let other = mkSystemSessionId "someone-else"
      otherStatus <- agentStatusFor rt other sampleSubagentId
      otherStatus `shouldSatisfy` isLeft
      stopAgent rt other sampleSubagentId
        `shouldReturn` Left
          "that subagent belongs to a different session; a session may only act on the children it spawned."
      mine <- agentStatusFor rt sampleParentSession sampleSubagentId
      mine `shouldSatisfy` isRight
      _ <- stopAgent rt sampleParentSession sampleSubagentId
      pure ()

    it "scopes listAgentsFor to the owning session" $ do
      rt <- newAgentRuntime
      ran <- newIORef False
      _ <- startAgent rt sampleDefId sampleSubagentId sampleParentSession sampleSession 0 (blockingWorker ran)
      mine <- listAgentsFor rt sampleParentSession
      theirs <- listAgentsFor rt (mkSystemSessionId "someone-else")
      length mine `shouldBe` 1
      length theirs `shouldBe` 0
      _ <- stopAgent rt sampleParentSession sampleSubagentId
      pure ()

  describe "resumeAgent" $ do
    it "refuses an id it does not know" $ do
      rt <- newAgentRuntime
      res <- resumeAgent rt sampleParentSession sampleSubagentId SoContinueBackground (error "must not run")
      isLeft res `shouldBe` True

    it "refuses a child with no task snapshot" $ do
      rt <- newAgentRuntime
      registerFinishedAgent rt sampleDefId sampleSubagentId sampleParentSession sampleSession 0
      res <- resumeAgent rt sampleParentSession sampleSubagentId SoContinueBackground (error "must not run")
      isLeft res `shouldBe` True

    it "refuses a child that is still running" $ do
      rt <- newAgentRuntime
      ran <- newIORef False
      _ <- startAgent rt sampleDefId sampleSubagentId sampleParentSession sampleSession 0 (blockingWorker ran)
      res <- resumeAgent rt sampleParentSession sampleSubagentId SoContinueBackground (error "must not run")
      isLeft res `shouldBe` True
      _ <- stopAgent rt sampleParentSession sampleSubagentId
      pure ()

  describe "retention" $ do
    it "prunes finished children beyond the cap, oldest first" $ do
      rt <- newAgentRuntime
      mapM_ (mkFinished rt) [1 .. 40 :: Int]
      countFinishedChildren rt sampleParentSession `shouldReturn` 40
      pruneRetained rt sampleParentSession
      countFinishedChildren rt sampleParentSession `shouldReturn` 32

    it "counts only running children as running" $ do
      rt <- newAgentRuntime
      registerFinishedAgent rt sampleDefId sampleSubagentId sampleParentSession sampleSession 0
      countRunningChildren rt sampleParentSession `shouldReturn` 0

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
      _ <- stopAgent rt sampleParentSession sampleSubagentId
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
      _ <- stopAgent rt sampleParentSession sampleSubagentId
      pure ()

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left _)  = False

isLeft :: Either a b -> Bool
isLeft = not . isRight

mkFinished :: AgentRuntime -> Int -> IO ()
mkFinished rt n =
  registerFinishedAgent rt sampleDefId
    (SubagentId ("sa-a1-" <> T.pack (show n))) sampleParentSession sampleSession 0

isCrashed :: AgentStatus -> Bool
isCrashed (Crashed _) = True
isCrashed _            = False
