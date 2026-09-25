{-# LANGUAGE OverloadedStrings #-}
-- | Concurrent subagent tests for 'runDelegate'. The existing test suite
-- (Gateway.AgentIntegrationSpec, Phase5Spec) uses 'stubChildWorker' which
-- returns immediately — no real concurrency is ever exercised. This spec
-- tests the actual concurrent execution path with workers that introduce
-- delays, throw exceptions, and exceed timeouts to verify:
--
--   * parallel execution (wall time < serial time),
--   * result-order preservation despite completion-order differences,
--   * error isolation (one child throwing doesn't poison siblings),
--   * timeout isolation (one child timing out doesn't block siblings),
--   * unique subagent IDs across concurrent children,
--   * concurrency cap enforcement (max_concurrent_children).
--
-- These tests call 'runDelegate' directly — no gateway, no provider, no
-- disk. The resolver is a pure stub that returns a minimal 'AgentDef' and a
-- caller-supplied worker for every task.
module Seal.Agent.Runtime.Delegation.ConcurrentSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Data.IORef (newIORef, atomicModifyIORef')
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (fromGregorian)
import Data.Time.Clock (UTCTime (..), diffUTCTime, getCurrentTime)
import Test.Hspec

import Seal.Agent.Def.Types (AgentDef (..), AgentDefId (..))
import Seal.Agent.Runtime.Delegation
import Seal.Core.Types (ModelId (..), SessionId, mkSystemSessionId)
import Seal.Security.Policy (AllowList (..))

------------------------------------------------------------------------
-- Test helpers
------------------------------------------------------------------------

-- | A fixed timestamp for constructing 'AgentDef's.
fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 1 1) 0

-- | A minimal 'AgentDef' — fields the worker doesn't inspect are stubbed.
stubDef :: Text -> AgentDef
stubDef defId = AgentDef
  { adId          = AgentDefId defId
  , adName        = defId <> " Name"
  , adProvider    = "test"
  , adModel       = ModelId "test-model"
  , adSystem      = Nothing
  , adTools       = AllowAll
  , adGroup       = Nothing
  , adRole        = Nothing
  , adDescription = Nothing
  , adCreatedAt   = fixedTime
  , adUpdatedAt   = fixedTime
  , adSession     = mkSystemSessionId "test-session"
  }

-- | A counter-based session minter — each call returns a distinct 'SessionId'.
-- The 'runDelegate' resolver is called once per task, so this ensures each
-- child gets a unique session.
mkSessionMinter :: IO (IO SessionId)
mkSessionMinter = do
  ref <- newIORef (0 :: Int)
  pure $ do
    n <- atomicModifyIORef' ref (\x -> let y = x + 1 in (y, x))
    pure (mkSystemSessionId ("child-" <> T.pack (show n)))

-- | Build a resolver that always succeeds, returning the stub def + the
-- given worker + a fresh session per call.
mkResolver
  :: AgentWorkerBuilder      -- ^ the worker to inject for every task
  -> IO (ChildTask -> IO (Either Text (AgentDef, AgentWorkerBuilder, SessionId)))
mkResolver worker = do
  minter <- mkSessionMinter
  let defId = "test-def"
  pure $ \_task -> do
    sid <- minter
    pure (Right (stubDef defId, worker, sid))

-- | A worker that sleeps for a given number of milliseconds, then returns a
-- summary containing the task's goal text. This exercises the real timing
-- path — if children run concurrently, total wall time is less than the sum.
delayedWorker
  :: Int      -- ^ sleep duration in milliseconds
  -> AgentWorkerBuilder
delayedWorker ms _def sid task _hooks = do
  threadDelay (ms * 1000)
  pure (ChildWorkerOutcome
          (Just ("done: " <> ctGoal task))
          CerCompleted
          0 0 (Just sid))

-- | A worker that sleeps for a duration derived from the task goal, so
-- different tasks have different delays. The goal is parsed as an integer
-- (milliseconds).
variableDelayWorker :: AgentWorkerBuilder
variableDelayWorker _def sid task _hooks = do
  let ms = readGoalMs (ctGoal task)
  threadDelay (ms * 1000)
  pure (ChildWorkerOutcome
          (Just ("done: " <> ctGoal task))
          CerCompleted
          0 0 (Just sid))

-- | Parse the task goal as an integer (milliseconds). Falls back to 50ms.
readGoalMs :: Text -> Int
readGoalMs t = case reads (T.unpack t) of
  [(n, _)] -> n
  _        -> 50

-- | Safe head for test assertions (the caller has already asserted the
-- list's length, so this never actually fails).
safeHead :: [a] -> a
safeHead (x:_) = x
safeHead []    = error "safeHead: empty list (caller should have asserted length first)"

-- | Build a batch of N identical tasks with the given goal.
mkBatch :: Int -> Text -> DelegateInput
mkBatch n goal = DiBatch [ ChildTask "test-def" goal Nothing Nothing | _ <- [1..n] ]

-- | Build a batch of tasks with distinct goals (for variable-delay tests).
mkVariableBatch :: [Text] -> DelegateInput
mkVariableBatch goals = DiBatch [ ChildTask "test-def" g Nothing Nothing | g <- goals ]

-- | Run 'runDelegate' with default config (no concurrency cap override) and
-- the given input + worker. Returns the results.
runWith
  :: DelegateInput
  -> AgentWorkerBuilder
  -> IO (Either Text [ChildResult])
runWith input worker = do
  pauseFlag <- newSpawnPauseFlag
  resolver <- mkResolver worker
  runDelegate defaultDelegationConfig pauseFlag Nothing 0 input resolver

-- | Run 'runDelegate' with a custom max_concurrent_children.
runWithConcurrency
  :: Int      -- ^ max_concurrent_children
  -> DelegateInput
  -> AgentWorkerBuilder
  -> IO (Either Text [ChildResult])
runWithConcurrency maxConc input worker = do
  pauseFlag <- newSpawnPauseFlag
  resolver <- mkResolver worker
  let cfg = defaultDelegationConfig { dcMaxConcurrentChildren = Just maxConc }
  runDelegate cfg pauseFlag Nothing 0 input resolver

-- | Measure wall-clock time of an IO action in seconds.
timeIt :: IO a -> IO (a, Double)
timeIt act = do
  start <- getCurrentTime
  a <- act
  end <- getCurrentTime
  pure (a, realToFrac (end `diffUTCTime` start))

------------------------------------------------------------------------
-- Spec
------------------------------------------------------------------------

spec :: Spec
spec = describe "Seal.Agent.Runtime.Delegation.Concurrent" $ do

  ------------------------------------------------------------------
  -- 1. Basic batch: 3 concurrent children, all succeed
  ------------------------------------------------------------------
  describe "batch of 3 concurrent children — all succeed" $ do
    it "returns 3 results, all CsCompleted, with correct summaries" $ do
      let batch = mkBatch 3 "work"
      eResults <- runWith batch (delayedWorker 100)
      case eResults of
        Left err -> expectationFailure ("expected Right, got Left: " <> T.unpack err)
        Right results -> do
          length results `shouldBe` 3
          all ((== CsCompleted) . crStatus) results `shouldBe` True
          -- Each summary should contain the goal text
          all (\r -> case crSummary r of
                  Just s -> "done: work" `T.isInfixOf` s
                  Nothing -> False) results
            `shouldBe` True

  ------------------------------------------------------------------
  -- 2. Parallel execution: wall time < serial time
  ------------------------------------------------------------------
  describe "parallel execution — 3 children @100ms, total wall < 250ms" $ do
    it "completes in less than 250ms (proving concurrency, not serialization)" $ do
      let batch = mkBatch 3 "work"
      (eResults, elapsed) <- timeIt (runWith batch (delayedWorker 100))
      case eResults of
        Left err -> expectationFailure ("expected Right, got Left: " <> T.unpack err)
        Right results -> do
          length results `shouldBe` 3
          -- 3 × 100ms serial = 300ms; parallel should be ~100ms.
          -- Allow generous slack for CI scheduling (250ms < 300ms).
          elapsed `shouldSatisfy` (< 0.250)

  ------------------------------------------------------------------
  -- 3. Result order preservation despite different completion times
  ------------------------------------------------------------------
  describe "result order preservation — tasks complete out of order, results stay in task order" $ do
    it "task indices are 0,1,2 in order even though task 0 is slowest" $ do
      -- Task 0: 200ms, Task 1: 50ms, Task 2: 10ms
      -- Completion order: 2, 1, 0 — but results must be ordered [0, 1, 2]
      let batch = mkVariableBatch ["200", "50", "10"]
      eResults <- runWith batch variableDelayWorker
      case eResults of
        Left err -> expectationFailure ("expected Right, got Left: " <> T.unpack err)
        Right results -> do
          length results `shouldBe` 3
          map crTaskIndex results `shouldBe` [0, 1, 2]
          -- Verify the summaries map to the correct goals (no mixup)
          crSummary (safeHead results) `shouldBe` Just "done: 200"
          crSummary (results !! 1) `shouldBe` Just "done: 50"
          crSummary (results !! 2) `shouldBe` Just "done: 10"

  ------------------------------------------------------------------
  -- 4. Error isolation: one child throws, others succeed
  ------------------------------------------------------------------
  describe "error isolation — one child throws, siblings still complete" $ do
    it "task 1 throws, tasks 0 and 2 are CsCompleted, task 1 is CsError" $ do
      -- We need a worker that throws for one task and succeeds for others.
      -- Since the resolver returns the SAME worker for every task, we
      -- build a worker that inspects the goal to decide.
      let selectiveWorker _def sid task _hooks =
            case ctGoal task of
              "throw" -> throwIO (userError "kaboom")
              _       -> do
                threadDelay 50000  -- 50ms
                pure (ChildWorkerOutcome
                        (Just ("done: " <> ctGoal task))
                        CerCompleted 0 0 (Just sid))
          batch = mkVariableBatch ["normal-a", "throw", "normal-b"]
      eResults <- runWith batch selectiveWorker
      case eResults of
        Left err -> expectationFailure ("expected Right, got Left: " <> T.unpack err)
        Right results -> do
          length results `shouldBe` 3
          crStatus (safeHead results) `shouldBe` CsCompleted
          crStatus (results !! 1) `shouldBe` CsError
          crStatus (results !! 2) `shouldBe` CsCompleted
          -- The exception text goes into crSummary (runDelegate's catch
          -- handler puts show e there), not crError (that's for resolver
          -- failures only).
          crSummary (results !! 1) `shouldSatisfy` maybe False ("kaboom" `T.isInfixOf`)
          -- The successful children have correct summaries
          crSummary (safeHead results) `shouldBe` Just "done: normal-a"
          crSummary (results !! 2) `shouldBe` Just "done: normal-b"

  ------------------------------------------------------------------
  -- 5. Timeout isolation: one child reports timeout, others succeed
  ------------------------------------------------------------------
  describe "timeout isolation — one child reports CerTimeout, siblings still complete" $ do
    -- The child_timeout floor is 30s, so we can't use a short timeout to
    -- trigger the real System.Timeout path in a fast test. Instead, we
    -- verify that a worker returning CerTimeout maps to CsTimeout and
    -- doesn't poison siblings — the status mapping and isolation are the
    -- observable contract.
    it "task 1 returns CerTimeout, tasks 0 and 2 are CsCompleted" $ do
      let selectiveWorker _def sid task _hooks =
            case ctGoal task of
              "slow" -> pure (ChildWorkerOutcome
                               (Just "timed out")
                               CerTimeout 0 0 (Just sid))
              _      -> do
                threadDelay 50000  -- 50ms
                pure (ChildWorkerOutcome
                        (Just ("done: " <> ctGoal task))
                        CerCompleted 0 0 (Just sid))
          batch = mkVariableBatch ["fast-a", "slow", "fast-b"]
      eResults <- runWith batch selectiveWorker
      case eResults of
        Left err -> expectationFailure ("expected Right, got Left: " <> T.unpack err)
        Right results -> do
          length results `shouldBe` 3
          crStatus (safeHead results) `shouldBe` CsCompleted
          crStatus (results !! 1) `shouldBe` CsTimeout
          crStatus (results !! 2) `shouldBe` CsCompleted

  ------------------------------------------------------------------
  -- 6. Unique subagent IDs across concurrent children
  ------------------------------------------------------------------
  describe "unique subagent IDs — 5 concurrent children get distinct IDs" $ do
    it "all 5 subagent IDs are unique" $ do
      let batch = mkBatch 5 "work"
      eResults <- runWith batch (delayedWorker 50)
      case eResults of
        Left err -> expectationFailure ("expected Right, got Left: " <> T.unpack err)
        Right results -> do
          length results `shouldBe` 5
          let sids = map (subagentIdText . crSubagentId) results
          length (nub sids) `shouldBe` 5

  ------------------------------------------------------------------
  -- 7. Concurrency cap = 1 serializes execution
  ------------------------------------------------------------------
  describe "concurrency cap = 1 — 3 children @100ms serialize (~300ms total)" $ do
    it "total wall time >= 280ms (proving serialization)" $ do
      let batch = mkBatch 3 "work"
      (eResults, elapsed) <- timeIt (runWithConcurrency 1 batch (delayedWorker 100))
      case eResults of
        Left err -> expectationFailure ("expected Right, got Left: " <> T.unpack err)
        Right results -> do
          length results `shouldBe` 3
          all ((== CsCompleted) . crStatus) results `shouldBe` True
          -- 3 × 100ms = 300ms; allow 20ms slack for scheduling overhead
          elapsed `shouldSatisfy` (>= 0.280)

  ------------------------------------------------------------------
  -- 8. Concurrency cap = 2 parallelizes 4 tasks in 2 waves
  ------------------------------------------------------------------
  describe "concurrency cap = 2 — 4 children @100ms in 2 waves (~200ms total)" $ do
    it "total wall time < 350ms (2 waves of 2, not 4 × 100ms)" $ do
      let batch = mkBatch 4 "work"
      (eResults, elapsed) <- timeIt (runWithConcurrency 2 batch (delayedWorker 100))
      case eResults of
        Left err -> expectationFailure ("expected Right, got Left: " <> T.unpack err)
        Right results -> do
          length results `shouldBe` 4
          all ((== CsCompleted) . crStatus) results `shouldBe` True
          -- 2 waves × 100ms = 200ms; allow 100ms slack for scheduling
          -- (the semaphore acquire/release + forkIO adds overhead).
          -- Must be < 400ms (serial would be 400ms).
          elapsed `shouldSatisfy` (< 0.350)

  ------------------------------------------------------------------
  -- 9. Single-task fast path (no thread pool)
  ------------------------------------------------------------------
  describe "single-task — no thread pool, synchronous result" $ do
    it "returns 1 result with CsCompleted" $ do
      let input = DiSingle (ChildTask "test-def" "solo work" Nothing Nothing)
      eResults <- runWith input (delayedWorker 50)
      case eResults of
        Left err -> expectationFailure ("expected Right, got Left: " <> T.unpack err)
        Right results -> do
          length results `shouldBe` 1
          crStatus (safeHead results) `shouldBe` CsCompleted
          crSummary (safeHead results) `shouldBe` Just "done: solo work"
          crTaskIndex (safeHead results) `shouldBe` 0

  ------------------------------------------------------------------
  -- 10. Empty batch is rejected
  ------------------------------------------------------------------
  describe "empty batch — rejected with error" $ do
    it "returns Left \"No tasks provided.\"" $ do
      let input = DiBatch []
      eResults <- runWith input (delayedWorker 10)
      case eResults of
        Left err -> err `shouldBe` "No tasks provided."
        Right _ -> expectationFailure "expected Left, got Right"

  ------------------------------------------------------------------
  -- 11. Spawn-pause flag blocks delegation
  ------------------------------------------------------------------
  describe "spawn-pause flag — blocks new delegation" $ do
    it "returns Left when the pause flag is set" $ do
      pauseFlag <- newSpawnPauseFlag
      _ <- setSpawnPaused pauseFlag True
      resolver <- mkResolver (delayedWorker 10)
      let input = DiSingle (ChildTask "test-def" "work" Nothing Nothing)
      eResults <- runDelegate defaultDelegationConfig pauseFlag Nothing 0 input resolver
      case eResults of
        Left err -> err `shouldSatisfy` ("paused" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left (paused), got Right"
