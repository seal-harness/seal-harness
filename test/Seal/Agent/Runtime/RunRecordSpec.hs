{-# LANGUAGE OverloadedStrings #-}
module Seal.Agent.Runtime.RunRecordSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Data.IORef
import Data.Maybe (isJust, fromJust)
import Data.Time.Clock (getCurrentTime)
import Test.Hspec

import Seal.Agent.Runtime.Delegation (SubagentId (..), ChildResult (..),
  ChildStatus (..), ChildExitReason (..))
import Seal.Agent.Runtime.RunRecord
import Seal.Core.Types (SessionId, mkSystemSessionId)

------------------------------------------------------------------------
-- Test helpers
------------------------------------------------------------------------


sampleParentSid :: SessionId
sampleParentSid = mkSystemSessionId "parent"

sampleChildSid :: SessionId
sampleChildSid = mkSystemSessionId "child"

sampleSubagentId :: SubagentId
sampleSubagentId = SubagentId "sa-a1-00000001"

sampleSubagentId2 :: SubagentId
sampleSubagentId2 = SubagentId "sa-a2-00000002"

mkSampleResult :: SubagentId -> ChildResult
mkSampleResult sid = ChildResult
  { crTaskIndex = 0
  , crStatus = CsCompleted
  , crSummary = Just "child finished successfully"
  , crExitReason = CerCompleted
  , crDurationSeconds = 1.5
  , crSubagentId = sid
  , crTokensInput = 100
  , crTokensOutput = 50
  , crToolTrace = []
  , crError = Nothing
  , crFilesRead = []
  , crFilesWritten = []
  , crChildSession = Just sampleChildSid
  }

spec :: Spec
spec = describe "Seal.Agent.Runtime.RunRecord" $ do
  describe "createRun" $ do
    it "creates a record with pending outcome and stores it" $ do
      reg <- newRunRecordRegistry
      rec <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      rrrOutcome rec `shouldBe` OutcomeUnknown
      rrrEndedAt rec `shouldBe` Nothing
      rrrExpectsCompletionMessage rec `shouldBe` True
      rrrSpawnMode rec `shouldBe` SpawnBackground
      rrrCleanup rec `shouldBe` CleanupDelete
      rrrCleanupHandled rec `shouldBe` False
      rrrEndedHookEmittedAt rec `shouldBe` Nothing
      rrrSuppressAnnounceReason rec `shouldBe` Nothing
      isJust (rrrGenerationToken rec) `shouldBe` True

    it "foreground mode does not expect completion message" $ do
      reg <- newRunRecordRegistry
      rec <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnForeground
      rrrExpectsCompletionMessage rec `shouldBe` False
      rrrSpawnMode rec `shouldBe` SpawnForeground

    it "stores the record keyed by run id in the registry" $ do
      reg <- newRunRecordRegistry
      rec <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      mFound <- findLatestRunForChild reg sampleChildSid
      mFound `shouldSatisfy` isJust
      rrrRunId (fromJust mFound) `shouldBe` rrrRunId rec

  describe "completeRun" $ do
    it "sets outcome, ended_at, and frozen result text" $ do
      reg <- newRunRecordRegistry
      rec <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      now <- getCurrentTime
      let result = mkSampleResult sampleSubagentId
      mCompleted <- completeRun reg (rrrRunId rec) (rrrGenerationToken rec) result now
      mCompleted `shouldSatisfy` isJust
      let completed = fromJust mCompleted
      rrrOutcome completed `shouldBe` OutcomeOk
      rrrEndedAt completed `shouldSatisfy` isJust
      rrrFrozenResultText completed `shouldSatisfy` isJust

    it "rejects stale generation tokens" $ do
      reg <- newRunRecordRegistry
      rec <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      -- Re-spawn: create a new record for the same subagent (new token)
      rec2 <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      rrrGenerationToken rec `shouldNotBe` rrrGenerationToken rec2
      -- Try to complete the OLD run with the OLD token
      now <- getCurrentTime
      let result = mkSampleResult sampleSubagentId
      mCompleted <- completeRun reg (rrrRunId rec) (rrrGenerationToken rec) result now
      mCompleted `shouldBe` Nothing  -- rejected: stale token

    it "accepts the current generation token" $ do
      reg <- newRunRecordRegistry
      _rec <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      rec2 <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      now <- getCurrentTime
      let result = mkSampleResult sampleSubagentId
      mCompleted <- completeRun reg (rrrRunId rec2) (rrrGenerationToken rec2) result now
      mCompleted `shouldSatisfy` isJust

    it "is idempotent — completing an already-completed run is a no-op" $ do
      reg <- newRunRecordRegistry
      rec <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      now <- getCurrentTime
      let result = mkSampleResult sampleSubagentId
      m1 <- completeRun reg (rrrRunId rec) (rrrGenerationToken rec) result now
      m1 `shouldSatisfy` isJust
      -- Second completion should be a no-op
      m2 <- completeRun reg (rrrRunId rec) (rrrGenerationToken rec) result now
      m2 `shouldBe` Nothing

    it "records error outcome for error results" $ do
      reg <- newRunRecordRegistry
      rec <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      now <- getCurrentTime
      let result = (mkSampleResult sampleSubagentId) { crStatus = CsError, crExitReason = CerError, crError = Just "boom" }
      mCompleted <- completeRun reg (rrrRunId rec) (rrrGenerationToken rec) result now
      rrrOutcome (fromJust mCompleted) `shouldBe` OutcomeError

    it "records timeout outcome for timeout results" $ do
      reg <- newRunRecordRegistry
      rec <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      now <- getCurrentTime
      let result = (mkSampleResult sampleSubagentId) { crStatus = CsTimeout, crExitReason = CerTimeout }
      mCompleted <- completeRun reg (rrrRunId rec) (rrrGenerationToken rec) result now
      rrrOutcome (fromJust mCompleted) `shouldBe` OutcomeTimeout

  describe "listRunsForParent" $ do
    it "returns all runs for a given parent session" $ do
      reg <- newRunRecordRegistry
      _r1 <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      _r2 <- createRun reg sampleSubagentId2 (mkSystemSessionId "child2") sampleParentSid 0 SpawnBackground
      _r3 <- createRun reg (SubagentId "sa-a3-00000003") (mkSystemSessionId "child3") (mkSystemSessionId "other-parent") 0 SpawnBackground
      runs <- listRunsForParent reg sampleParentSid
      length runs `shouldBe` 2

    it "returns empty list for a parent with no children" $ do
      reg <- newRunRecordRegistry
      runs <- listRunsForParent reg sampleParentSid
      runs `shouldBe` []

  describe "countPendingDescendants" $ do
    it "counts non-terminal runs for a given session as parent" $ do
      reg <- newRunRecordRegistry
      _r1 <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      _r2 <- createRun reg sampleSubagentId2 (mkSystemSessionId "child2") sampleParentSid 0 SpawnBackground
      count <- countPendingDescendants reg sampleParentSid
      count `shouldBe` 2

    it "excludes completed runs" $ do
      reg <- newRunRecordRegistry
      r1 <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      _r2 <- createRun reg sampleSubagentId2 (mkSystemSessionId "child2") sampleParentSid 0 SpawnBackground
      now <- getCurrentTime
      _ <- completeRun reg (rrrRunId r1) (rrrGenerationToken r1) (mkSampleResult sampleSubagentId) now
      count <- countPendingDescendants reg sampleParentSid
      count `shouldBe` 1

  describe "lifecycle hooks" $ do
    it "emits subagent_ended hook on completion (idempotent)" $ do
      reg <- newRunRecordRegistry
      hookFired <- newIORef (0 :: Int)
      registerEndedHook reg $ \_rec -> atomicModifyIORef' hookFired (\n -> (n + 1, ()))
      rec <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      now <- getCurrentTime
      _ <- completeRun reg (rrrRunId rec) (rrrGenerationToken rec) (mkSampleResult sampleSubagentId) now
      -- Hook should fire exactly once
      readIORef hookFired `shouldReturn` 1
      -- Second completion (no-op) should NOT fire the hook again
      _ <- completeRun reg (rrrRunId rec) (rrrGenerationToken rec) (mkSampleResult sampleSubagentId) now
      readIORef hookFired `shouldReturn` 1

  describe "cancelRunsForParent" $ do
    it "marks all pending runs for a parent as killed" $ do
      reg <- newRunRecordRegistry
      _r1 <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      _r2 <- createRun reg sampleSubagentId2 (mkSystemSessionId "child2") sampleParentSid 0 SpawnBackground
      now <- getCurrentTime
      cancelled <- cancelRunsForParent reg sampleParentSid now "killed"
      length cancelled `shouldBe` 2
      -- Verify they're all killed
      runs <- listRunsForParent reg sampleParentSid
      all (\r -> rrrOutcome r == OutcomeKilled) runs `shouldBe` True
      -- No more pending descendants
      count <- countPendingDescendants reg sampleParentSid
      count `shouldBe` 0

    it "does not affect already-completed runs" $ do
      reg <- newRunRecordRegistry
      r1 <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      _r2 <- createRun reg sampleSubagentId2 (mkSystemSessionId "child2") sampleParentSid 0 SpawnBackground
      now <- getCurrentTime
      _ <- completeRun reg (rrrRunId r1) (rrrGenerationToken r1) (mkSampleResult sampleSubagentId) now
      cancelled <- cancelRunsForParent reg sampleParentSid now "killed"
      length cancelled `shouldBe` 1  -- only r2 was pending

    it "cascade is recursive — grandchildren are also cancelled" $ do
      reg <- newRunRecordRegistry
      -- parent → child → grandchild linkage
      _child <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      let grandchildSid = mkSystemSessionId "grandchild"
      _grandchild <- createRun reg sampleSubagentId2 grandchildSid sampleChildSid 1 SpawnBackground
      now <- getCurrentTime
      cancelled <- cancelRunsForParent reg sampleParentSid now "killed"
      length cancelled `shouldBe` 2
      -- Both the child and the grandchild are killed
      all (\r -> rrrOutcome r == OutcomeKilled) cancelled `shouldBe` True
      -- The grandchild's run record is found via its parent (child) session
      mGrand <- findLatestRunForChild reg grandchildSid
      case mGrand of
        Just g -> rrrOutcome g `shouldBe` OutcomeKilled
        Nothing -> expectationFailure "grandchild record not found"

    it "suppression reason is recorded on all cancelled runs" $ do
      reg <- newRunRecordRegistry
      _child <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      let grandchildSid = mkSystemSessionId "grandchild"
      _grandchild <- createRun reg sampleSubagentId2 grandchildSid sampleChildSid 1 SpawnBackground
      now <- getCurrentTime
      cancelled <- cancelRunsForParent reg sampleParentSid now "killed"
      all (\r -> rrrSuppressAnnounceReason r == Just "killed") cancelled `shouldBe` True

    it "normal turn end does NOT cancel children (only explicit cancel does)" $ do
      -- This is a contract test: cancelRunsForParent is the ONLY function
      -- that marks runs as killed, and it must be called explicitly by the
      -- session-termination hook — never by the per-turn bracket. Here we
      -- verify that simply listing pending descendants after a "turn end"
      -- (simulated by doing nothing) leaves them all pending.
      reg <- newRunRecordRegistry
      _child <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      -- Simulate a turn end: no cancel call. Children must remain pending.
      nPending <- countPendingDescendants reg sampleParentSid
      nPending `shouldBe` 1

  describe "descendant settle (WU-5)" $ do
    it "shouldDeferDelivery returns True when the child has pending descendants" $ do
      reg <- newRunRecordRegistry
      -- parent → child → grandchild (pending)
      _child <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      let grandchildSid = mkSystemSessionId "grandchild"
      _grandchild <- createRun reg sampleSubagentId2 grandchildSid sampleChildSid 1 SpawnBackground
      -- The child has 1 pending descendant → defer
      n <- countPendingDescendants reg sampleChildSid
      n `shouldBe` 1
      shouldDeferDelivery reg sampleChildSid `shouldReturn` True

    it "shouldDeferDelivery returns False when the child has no pending descendants" $ do
      reg <- newRunRecordRegistry
      _child <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      -- No descendants → don't defer
      shouldDeferDelivery reg sampleChildSid `shouldReturn` False

    it "shouldDeferDelivery returns False after all descendants complete" $ do
      reg <- newRunRecordRegistry
      _child <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      let grandchildSid = mkSystemSessionId "grandchild"
      grandchild <- createRun reg sampleSubagentId2 grandchildSid sampleChildSid 1 SpawnBackground
      now <- getCurrentTime
      -- Initially defer (1 pending descendant)
      shouldDeferDelivery reg sampleChildSid `shouldReturn` True
      -- Complete the grandchild
      _ <- completeRun reg (rrrRunId grandchild) (rrrGenerationToken grandchild) (mkSampleResult sampleSubagentId2) now
      -- Now no pending descendants → don't defer
      shouldDeferDelivery reg sampleChildSid `shouldReturn` False

    it "descendantSettled returns True when a session has no pending descendants" $ do
      reg <- newRunRecordRegistry
      _child <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      descendantSettled reg sampleChildSid `shouldReturn` True

    it "descendantSettled returns False when a session has pending descendants" $ do
      reg <- newRunRecordRegistry
      _child <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      let grandchildSid = mkSystemSessionId "grandchild"
      _grandchild <- createRun reg sampleSubagentId2 grandchildSid sampleChildSid 1 SpawnBackground
      descendantSettled reg sampleChildSid `shouldReturn` False

  describe "announce retry (WU-6)" $ do
    it "recordAnnounceAttempt increments the retry count and records the timestamp" $ do
      reg <- newRunRecordRegistry
      rec <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      let runId = rrrRunId rec
      now1 <- getCurrentTime
      _ <- recordAnnounceAttempt reg runId now1
      mRec1 <- findLatestRunForChild reg sampleChildSid
      case mRec1 of
        Just r1 -> do
          rrrAnnounceRetryCount r1 `shouldBe` 1
          rrrLastAnnounceRetryAt r1 `shouldBe` Just now1
        Nothing -> expectationFailure "record not found"
      now2 <- getCurrentTime
      _ <- recordAnnounceAttempt reg runId now2
      mRec2 <- findLatestRunForChild reg sampleChildSid
      case mRec2 of
        Just r2 -> rrrAnnounceRetryCount r2 `shouldBe` 2
        Nothing -> expectationFailure "record not found"

    it "recordAnnounceAttempt is a no-op on a missing run id" $ do
      reg <- newRunRecordRegistry
      now <- getCurrentTime
      mR <- recordAnnounceAttempt reg "nonexistent-run" now
      mR `shouldBe` Nothing

    it "computeAnnounceBackoff returns the base delay at attempt 0" $
      computeAnnounceBackoff 0 `shouldBe` 1.0

    it "computeAnnounceBackoff grows exponentially with the attempt count" $ do
      computeAnnounceBackoff 1 `shouldBe` 2.0
      computeAnnounceBackoff 2 `shouldBe` 4.0
      computeAnnounceBackoff 3 `shouldBe` 8.0

    it "maxAnnounceRetries is 3" $
      maxAnnounceRetries `shouldBe` 3

    it "announceRetriesExhausted returns True when retry count >= max" $ do
      announceRetriesExhausted 3 `shouldBe` True
      announceRetriesExhausted 4 `shouldBe` True

    it "announceRetriesExhausted returns False when retry count < max" $ do
      announceRetriesExhausted 0 `shouldBe` False
      announceRetriesExhausted 2 `shouldBe` False

  describe "completion signal (WU-7 dual-path)" $ do
    it "awaitCompletion returns the record after completeRun fills the signal" $ do
      reg <- newRunRecordRegistry
      rec <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      let runId = rrrRunId rec
      -- Register a completion signal for this run
      mSignal <- registerCompletionSignal reg runId
      mSignal `shouldSatisfy` isJust
      case mSignal of
        Nothing -> expectationFailure "signal not registered"
        Just signal -> do
          -- Complete the run in a forked thread (simulates async completion)
          now <- getCurrentTime
          _ <- forkIO $ do
            threadDelay 100000  -- 100ms
            _ <- completeRun reg runId (rrrGenerationToken rec) (mkSampleResult sampleSubagentId) now
            pure ()
          -- awaitCompletion blocks until the signal is filled
          result <- awaitCompletion signal 1000000  -- 1s timeout
          case result of
            Just completedRec -> rrrRunId completedRec `shouldBe` runId
            Nothing -> expectationFailure "awaitCompletion timed out"

    it "awaitCompletion returns Nothing on timeout" $ do
      reg <- newRunRecordRegistry
      rec <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      let runId = rrrRunId rec
      mSignal <- registerCompletionSignal reg runId
      mSignal `shouldSatisfy` isJust
      case mSignal of
        Nothing -> expectationFailure "signal not registered"
        Just signal -> do
          -- Don't complete the run — awaitCompletion should time out
          result <- awaitCompletion signal 50000  -- 50ms timeout
          result `shouldBe` Nothing

    it "registerEndedHook fires on completion (Path B — event listener)" $ do
      reg <- newRunRecordRegistry
      hookFired <- newIORef (0 :: Int)
      registerEndedHook reg (\_ -> modifyIORef' hookFired (+1))
      rec <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      now <- getCurrentTime
      _ <- completeRun reg (rrrRunId rec) (rrrGenerationToken rec) (mkSampleResult sampleSubagentId) now
      readIORef hookFired `shouldReturn` 1

    it "stale generation token is rejected by completeRun" $ do
      reg <- newRunRecordRegistry
      rec <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      now <- getCurrentTime
      let staleToken = Just (GenerationToken 0)  -- wrong token
      mCompleted <- completeRun reg (rrrRunId rec) staleToken (mkSampleResult sampleSubagentId) now
      mCompleted `shouldBe` Nothing  -- rejected: stale token

  describe "persistence" $ do
    it "saveRunRecordToDisk writes a JSON file that loadRunRecord can read" $ do
      reg <- newRunRecordRegistry
      rec <- createRun reg sampleSubagentId sampleChildSid sampleParentSid 0 SpawnBackground
      let dir = "/tmp/seal-test-runrecord"
      saveRunRecordToDisk dir rec
      mLoaded <- loadRunRecord dir (rrrRunId rec)
      mLoaded `shouldSatisfy` isJust
      let loaded = fromJust mLoaded
      rrrRunId loaded `shouldBe` rrrRunId rec
      rrrOutcome loaded `shouldBe` rrrOutcome rec
      rrrSpawnMode loaded `shouldBe` rrrSpawnMode rec
      rrrExpectsCompletionMessage loaded `shouldBe` rrrExpectsCompletionMessage rec
