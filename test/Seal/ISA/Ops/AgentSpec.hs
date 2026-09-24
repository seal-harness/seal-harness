{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.AgentSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
  ( MVar, newMVar, modifyMVar, withMVar, newEmptyMVar, takeMVar, putMVar )
import Control.Exception (bracket)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec

import Seal.Agent.Def.Backend
import Seal.Agent.Def.Types (AgentDef (..), AgentDefId (..), mkAgentDefId)
import Seal.Agent.Runtime.Delegation qualified as Del
import Seal.Agent.Runtime.Delegation
  ( ChildExitReason (..), ChildResult (..), ChildStatus (..)
  , ChildWorkerOutcome (..)
  , DelegateInput (..)
  , SpawnInfo (..)
  , defaultDelegationConfig, dcChildTimeoutSeconds
  , newSpawnPauseFlag, setSpawnPaused
  , runDelegateAsync
  )
import Seal.Agent.Runtime.Registry
import Seal.Core.Types (SessionId, mkSystemSessionId)
import Seal.ISA.Opcode
  ( OpResult (..), localBackend, opAuthorize, opRun )
import Seal.ISA.Ops.Agent
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Types.App (App, runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)
import Seal.Logging.Logger (testSealLogger)

runTestApp :: App a -> IO a
runTestApp act = do logger <- testSealLogger; env <- mkEnv logger defaultConfig; runApp env act

sampleSession :: SessionId
sampleSession = mkSystemSessionId "s1"

sampleDefId :: AgentDefId
sampleDefId = case mkAgentDefId "a1" of
  Right aid -> aid
  Left _    -> AgentDefId "fallback"

-- | A worker that records it ran, returns a fixed summary, and completes
-- (synchronous semantics). The new AGENT_START blocks until the worker
-- returns, so this is the test analog of a child that runs to completion.
recordingWorker :: IORef Int -> Del.AgentWorkerBuilder
recordingWorker ref _ _ _ _ = do
  modifyIORef' ref (+1)
  pure (ChildWorkerOutcome (Just "done") CerCompleted 0 0 (Just (mkSystemSessionId "child")))

-- | A worker that tracks the maximum number of concurrent executions.
-- Each child increments a counter on entry, sleeps briefly so overlaps are
-- observable, then decrements on exit. The max-concurrent value is tracked
-- in the MVar alongside the current count.
concurrencyTrackingWorker :: MVar (Int, Int) -> Del.AgentWorkerBuilder
concurrencyTrackingWorker state _ _ _ _ =
  bracket enter exit (\_ -> do
    threadDelay 50000  -- 50ms so concurrent workers overlap
    pure (ChildWorkerOutcome (Just "done") CerCompleted 0 0 (Just (mkSystemSessionId "child"))))
  where
    enter = modifyMVar state $ \(current, maxSeen) -> do
      let !newCurrent = current + 1
          !newMax = max maxSeen newCurrent
      pure ((newCurrent, newMax), ())
    exit _ = modifyMVar state $ \(current, maxSeen) ->
      pure ((current - 1, maxSeen), ())

-- | Read the max-concurrent value from the tracking state.
maxConcurrent :: MVar (Int, Int) -> IO Int
maxConcurrent state = withMVar state (\(_, m) -> pure m)

-- | A worker that simulates a def-not-found resolution error (returns an
-- error outcome).
errorWorker :: Del.AgentWorkerBuilder
errorWorker _ _ _ _ = pure (ChildWorkerOutcome (Just "fail") CerError 0 0 Nothing)

spec :: Spec
spec = describe "Seal.ISA.Ops.Agent" $ do
  describe "AGENT_DEF_WRITE" $ do
    it "creates a def and returns 'defined'" $ do
      backend <- noneBackend
      let op = agentDefWriteOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["id" .= ("a1" :: Text), "name" .= ("greeter" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      orIsError r `shouldBe` False
      orParts r `shouldBe` [TrpText "defined"]
      m <- adbRead backend sampleDefId
      case m of
        Just d  -> adName d `shouldBe` "greeter"
        Nothing -> expectationFailure "def not stored"

    it "rejects an invalid id" $ do
      backend <- noneBackend
      let op = agentDefWriteOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["id" .= ("bad/id" :: Text), "name" .= ("x" :: Text), "provider" .= ("p" :: Text), "model" .= ("m" :: Text)]))
      orIsError r `shouldBe` True

    it "accepts an optional system prompt and tools=all" $ do
      backend <- noneBackend
      let op = agentDefWriteOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text), "system" .= ("be nice" :: Text), "tools" .= ("all" :: Text)]))
      orIsError r `shouldBe` False
      m <- adbRead backend sampleDefId
      case m of
        Just d  -> adSystem d `shouldBe` Just "be nice"
        Nothing -> expectationFailure "def not stored"

    it "accepts an optional group and records it" $ do
      backend <- noneBackend
      let op = agentDefWriteOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text), "group" .= ("core" :: Text)]))
      orIsError r `shouldBe` False
      m <- adbRead backend sampleDefId
      case m of
        Just d  -> adGroup d `shouldBe` Just "core"
        Nothing -> expectationFailure "def not stored"
      let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
      T.isInfixOf "\"core\"" recorded `shouldBe` True

    it "preserves the existing group on update when the field is omitted" $ do
      backend <- noneBackend
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text), "group" .= ("core" :: Text)]))
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("g2" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      m <- adbRead backend sampleDefId
      case m of
        Just d  -> adGroup d `shouldBe` Just "core"
        Nothing -> expectationFailure "def not found after update"

  -- W1 (issue #154): role + description fields
  describe "AGENT_DEF_WRITE role/description" $ do
    it "accepts role=orchestrator and role=leaf, storing each" $ do
      backend <- noneBackend
      let op = agentDefWriteOp backend sampleSession
          mkAid t = case mkAgentDefId t of
            Right a  -> a
            Left _   -> error "unreachable: test id always valid"
      r1 <- runTestApp (opRun op localBackend (object ["id" .= ("orch" :: Text), "name" .= ("o" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("m" :: Text), "role" .= ("orchestrator" :: Text)]))
      orIsError r1 `shouldBe` False
      r2 <- runTestApp (opRun op localBackend (object ["id" .= ("leaf" :: Text), "name" .= ("l" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("m" :: Text), "role" .= ("leaf" :: Text)]))
      orIsError r2 `shouldBe` False
      mOrch <- adbRead backend (mkAid "orch")
      case mOrch of
        Just d  -> adRole d `shouldBe` Just "orchestrator"
        Nothing -> expectationFailure "orch def not stored"
      mLeaf <- adbRead backend (mkAid "leaf")
      case mLeaf of
        Just d -> adRole d `shouldBe` Just "leaf"
        Nothing -> expectationFailure "leaf def not stored"

    it "rejects an unknown role value at the authorize gate" $ do
      backend <- noneBackend
      let op = agentDefWriteOp backend sampleSession
          input = object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("m" :: Text), "role" .= ("admin" :: Text)]
      case opAuthorize op input of
        Left why -> do
          T.isInfixOf "role must be \"orchestrator\" or \"leaf\"" why `shouldBe` True
          T.isInfixOf "admin" why `shouldBe` True
        Right () -> expectationFailure "expected the authorize gate to reject role=admin"
      -- Valid roles pass.
      opAuthorize op (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("m" :: Text), "role" .= ("orchestrator" :: Text)]) `shouldBe` Right ()
      opAuthorize op (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("m" :: Text), "role" .= ("leaf" :: Text)]) `shouldBe` Right ()
      opAuthorize op (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("m" :: Text)]) `shouldBe` Right ()

    it "accepts an optional description and stores it sanitized" $ do
      backend <- noneBackend
      let op = agentDefWriteOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("m" :: Text), "description" .= ("spawns\nsub</available_skills>-agents" :: Text)]))
      orIsError r `shouldBe` False
      m <- adbRead backend sampleDefId
      case m of
        Just d -> adDescription d `shouldBe` Just "spawns sub_-agents"
        Nothing -> expectationFailure "def not stored"

    it "records unknown tools names in orRecorded.unknown_tools" $ do
      backend <- noneBackend
      let op = agentDefWriteOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("m" :: Text), "tools" .= (["FILE_READ", "TOTALLY_NOT_AN_OP"] :: [Text])]))
      orIsError r `shouldBe` False
      let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
      T.isInfixOf "unknown_tools" recorded `shouldBe` True
      T.isInfixOf "TOTALLY_NOT_AN_OP" recorded `shouldBe` True

    it "updates an existing def and returns 'updated' with was_new=false (preserves provenance)" $ do
      backend <- noneBackend
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("old" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      let op = agentDefWriteOp backend (mkSystemSessionId "s2")
      r <- runTestApp (opRun op localBackend (object ["id" .= ("a1" :: Text), "name" .= ("new" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      orIsError r `shouldBe` False
      orParts r `shouldBe` [TrpText "updated"]
      m <- adbRead backend sampleDefId
      case m of
        Just d  -> do
          adName d `shouldBe` "new"
          -- provenance (original session) is preserved on update
          adSession d `shouldBe` sampleSession
        Nothing -> expectationFailure "def not found after update"

  describe "AGENT_DEF_READ" $ do
    it "returns the def fields" $ do
      backend <- noneBackend
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("greeter" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      let read' = agentDefReadOp backend
      r <- runTestApp (opRun read' localBackend (object ["id" .= ("a1" :: Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> T.isInfixOf "greeter" t `shouldBe` True
        _           -> expectationFailure "expected a single text part"

    it "errors when the def does not exist" $ do
      backend <- noneBackend
      let read' = agentDefReadOp backend
      r <- runTestApp (opRun read' localBackend (object ["id" .= ("nope" :: Text)]))
      orIsError r `shouldBe` True

  describe "AGENT_DEF_LIST" $ do
    it "returns an empty message when no defs" $ do
      backend <- noneBackend
      let list' = agentDefListOp backend
      r <- runTestApp (opRun list' localBackend (object []))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> t `shouldBe` "(no agent definitions)"
        _           -> expectationFailure "expected a single text part"

    it "lists defined defs with id, name, and provider/model" $ do
      backend <- noneBackend
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("greeter" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      let list' = agentDefListOp backend
      r <- runTestApp (opRun list' localBackend (object []))
      case orParts r of
        [TrpText t] -> do
          T.isInfixOf "a1: greeter" t `shouldBe` True
          T.isInfixOf "ollama/llama3" t `shouldBe` True
        _           -> expectationFailure "expected a single text part"

    it "shows the [role] suffix for a role-carrying def" $ do
      backend <- noneBackend
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("greeter" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text), "role" .= ("orchestrator" :: Text)]))
      let list' = agentDefListOp backend
      r <- runTestApp (opRun list' localBackend (object []))
      case orParts r of
        [TrpText t] -> T.isInfixOf "[orchestrator]" t `shouldBe` True
        _           -> expectationFailure "expected a single text part"

  describe "AGENT_DEF_DELETE" $ do
    it "deletes an existing def" $ do
      backend <- noneBackend
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("p" :: Text), "model" .= ("m" :: Text)]))
      let delete = agentDefDeleteOp backend
      r <- runTestApp (opRun delete localBackend (object ["id" .= ("a1" :: Text)]))
      orIsError r `shouldBe` False
      adbRead backend sampleDefId `shouldReturn` Nothing

    it "is idempotent on a missing id" $ do
      backend <- noneBackend
      let delete = agentDefDeleteOp backend
      r <- runTestApp (opRun delete localBackend (object ["id" .= ("nope" :: Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> T.isInfixOf "not present" t `shouldBe` True
        _           -> expectationFailure "expected a single text part"

  describe "AGENT_START (synchronous, goal-driven)" $ do
    it "runs a child to completion and returns a summary" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      ran <- newIORef (0 :: Int)
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      let wiring = AgentStartWiring
            { aswDefBackend = backend
            , aswRuntime = rt
            , aswConfig = pure defaultDelegationConfig
            , aswPauseFlag = pauseFlag
            , aswParentActivity = Nothing
            , aswMintSession = pure (mkSystemSessionId "fresh")
            , aswParentDepth = 0
            , aswWorker = recordingWorker ran
            , aswGate = gateOpen
            }
      r <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["id" .= ("a1" :: Text), "goal" .= ("do the thing" :: Text)]))
      orIsError r `shouldBe` False
      -- The worker ran exactly once (synchronous, single-task mode).
      readIORef ran `shouldReturn` 1
      -- The result text contains the summary.
      case orParts r of
        [TrpText t] -> T.isInfixOf "done" t `shouldBe` True
        _           -> expectationFailure "expected a single text part"

    it "AGENT_START does not truncate long summaries" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      ran <- newIORef (0 :: Int)
      let longSummary = T.replicate 500 "x"
          longSummaryWorker :: IORef Int -> Del.AgentWorkerBuilder
          longSummaryWorker ref _ _ _ _ = do
            modifyIORef' ref (+1)
            pure (ChildWorkerOutcome (Just longSummary) CerCompleted 0 0 (Just (mkSystemSessionId "child")))
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      let wiring = AgentStartWiring
            { aswDefBackend = backend
            , aswRuntime = rt
            , aswConfig = pure defaultDelegationConfig
            , aswPauseFlag = pauseFlag
            , aswParentActivity = Nothing
            , aswMintSession = pure (mkSystemSessionId "fresh")
            , aswParentDepth = 0
            , aswWorker = longSummaryWorker ran
            , aswGate = gateOpen
            }
      r <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["id" .= ("a1" :: Text), "goal" .= ("do the thing" :: Text)]))
      orIsError r `shouldBe` False
      readIORef ran `shouldReturn` 1
      case orParts r of
        [TrpText t] ->
          -- The full 500-char summary must appear in the result, not
          -- truncated to 200 chars (the old T.take 200 cap).
          T.isInfixOf longSummary t `shouldBe` True
        _           -> expectationFailure "expected a single text part"

    it "AGENT_START errors when the def does not exist" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      let wiring = AgentStartWiring
            { aswDefBackend = backend
            , aswRuntime = rt
            , aswConfig = pure defaultDelegationConfig
            , aswPauseFlag = pauseFlag
            , aswParentActivity = Nothing
            , aswMintSession = pure (mkSystemSessionId "fresh")
            , aswParentDepth = 0
            , aswWorker = errorWorker
            , aswGate = gateOpen
            }
      r <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["id" .= ("nope" :: Text), "goal" .= ("x" :: Text)]))
      -- def-not-found surfaces as a per-child error result (the opcode does
      -- not reject the whole call; it returns a ChildResult with CsError).
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> T.isInfixOf "agent def not found" t `shouldBe` True
        _           -> expectationFailure "expected a single text part"

    it "AGENT_START requires a goal (single-task mode)" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      let wiring = AgentStartWiring
            { aswDefBackend = backend
            , aswRuntime = rt
            , aswConfig = pure defaultDelegationConfig
            , aswPauseFlag = pauseFlag
            , aswParentActivity = Nothing
            , aswMintSession = pure (mkSystemSessionId "fresh")
            , aswParentDepth = 0
            , aswWorker = errorWorker
            , aswGate = gateOpen
            }
      r <- runTestApp (opRun (agentStartOp wiring) localBackend (object ["id" .= ("a1" :: Text)]))
      orIsError r `shouldBe` True

    it "AGENT_START supports batch mode (tasks array)" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      ran <- newIORef (0 :: Int)
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      let wiring = AgentStartWiring
            { aswDefBackend = backend
            , aswRuntime = rt
            , aswConfig = pure defaultDelegationConfig { dcChildTimeoutSeconds = Just 30 }
            , aswPauseFlag = pauseFlag
            , aswParentActivity = Nothing
            , aswMintSession = pure (mkSystemSessionId "fresh")
            , aswParentDepth = 0
            , aswWorker = recordingWorker ran
            , aswGate = gateOpen
            }
      r <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["tasks" .= [ object ["id" .= ("a1" :: Text), "goal" .= ("task one" :: Text)]
                                                , object ["id" .= ("a1" :: Text), "goal" .= ("task two" :: Text)] ]]))
      orIsError r `shouldBe` False
      -- Both tasks ran (batch mode fans out).
      readIORef ran `shouldReturn` 2

    it "AGENT_START batch mode runs children concurrently (not serialized)" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      concurrencyState <- newMVar (0 :: Int, 0 :: Int)
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      let wiring = AgentStartWiring
            { aswDefBackend = backend
            , aswRuntime = rt
            , aswConfig = pure defaultDelegationConfig { dcChildTimeoutSeconds = Just 30 }
            , aswPauseFlag = pauseFlag
            , aswParentActivity = Nothing
            , aswMintSession = pure (mkSystemSessionId "fresh")
            , aswParentDepth = 0
            , aswWorker = concurrencyTrackingWorker concurrencyState
            , aswGate = gateOpen
            }
      r <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["tasks" .= [ object ["id" .= ("a1" :: Text), "goal" .= ("t1" :: Text)]
                                                , object ["id" .= ("a1" :: Text), "goal" .= ("t2" :: Text)]
                                                , object ["id" .= ("a1" :: Text), "goal" .= ("t3" :: Text)]
                                                , object ["id" .= ("a1" :: Text), "goal" .= ("t4" :: Text)]
                                                , object ["id" .= ("a1" :: Text), "goal" .= ("t5" :: Text)] ]]))
      orIsError r `shouldBe` False
      -- With default max_concurrent_children=3, at least 2 children should
      -- overlap (the old broken semaphore serialized everything to 1 at a
      -- time, so maxConcurrent would be 1).
      mc <- maxConcurrent concurrencyState
      mc `shouldSatisfy` (>= 2)

    it "AGENT_START rejects when spawn is paused" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      _ <- setSpawnPaused pauseFlag True
      ran <- newIORef (0 :: Int)
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      let wiring = AgentStartWiring
            { aswDefBackend = backend
            , aswRuntime = rt
            , aswConfig = pure defaultDelegationConfig
            , aswPauseFlag = pauseFlag
            , aswParentActivity = Nothing
            , aswMintSession = pure (mkSystemSessionId "fresh")
            , aswParentDepth = 0
            , aswWorker = recordingWorker ran
            , aswGate = gateOpen
            }
      r <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["id" .= ("a1" :: Text), "goal" .= ("x" :: Text)]))
      orIsError r `shouldBe` True
      readIORef ran `shouldReturn` 0
      _ <- setSpawnPaused pauseFlag False
      pure ()

  describe "AGENT_INSTANCES / STATUS / STOP / INTERRUPT (subagent-id keyed)" $ do
    it "AGENT_INSTANCES reports (no agents running) when the synchronous model has finished" $ do
      rt <- newAgentRuntime
      r <- runTestApp (opRun (agentInstancesOp rt) localBackend (object []))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> t `shouldBe` "(no agents running)"
        _           -> expectationFailure "expected a single text part"

    it "AGENT_STATUS reports not running when absent" $ do
      rt <- newAgentRuntime
      r <- runTestApp (opRun (agentStatusOp rt) localBackend (object ["subagent_id" .= ("sa-x-00000001" :: Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> t `shouldBe` "not running"
        _           -> expectationFailure "expected a single text part"

    it "AGENT_STOP is idempotent on a non-running subagent id" $ do
      rt <- newAgentRuntime
      r <- runTestApp (opRun (agentStopOp rt) localBackend (object ["subagent_id" .= ("sa-x-00000001" :: Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> t `shouldBe` "stopped"
        _           -> expectationFailure "expected a single text part"

    it "AGENT_INTERRUPT returns 'subagent not running' when no match" $ do
      rt <- newAgentRuntime
      r <- runTestApp (opRun (agentInterruptOp rt) localBackend (object ["subagent_id" .= ("sa-x-00000001" :: Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> t `shouldBe` "subagent not running"
        _           -> expectationFailure "expected a single text part"

  describe "runDelegateAsync (async core)" $ do
    it "returns immediately with SpawnInfo (does not block on worker completion)" $ do
      pauseFlag <- newSpawnPauseFlag
      ran <- newIORef (0 :: Int)
      resultMVar <- newEmptyMVar :: IO (MVar ChildResult)
      let cfg = defaultDelegationConfig
          callback = putMVar resultMVar
          resolver _task = pure (Right ( undefined
                                        , recordingWorker ran
                                        , mkSystemSessionId "child"))
          input = DiSingle (Del.ChildTask "a1" "do the thing" Nothing Nothing)
      eResult <- runDelegateAsync cfg pauseFlag Nothing 0 input resolver callback (pure (mkSystemSessionId "child"))
      case eResult of
        Left err -> expectationFailure ("expected Right but got Left: " <> T.unpack err)
        Right [info] -> do
          siTaskIndex info `shouldBe` 0
          siChildSession info `shouldBe` mkSystemSessionId "child"
        Right _ -> expectationFailure "expected exactly one SpawnInfo"
      -- The worker hasn't necessarily run yet — we just verify we got
      -- SpawnInfo back without blocking. Wait for the callback to verify
      -- the worker did eventually run.
      _result <- takeMVar resultMVar
      readIORef ran `shouldReturn` 1

    it "completion callback fires with ChildResult after worker finishes" $ do
      pauseFlag <- newSpawnPauseFlag
      resultMVar <- newEmptyMVar :: IO (MVar ChildResult)
      ran <- newIORef (0 :: Int)
      let cfg = defaultDelegationConfig
          callback = putMVar resultMVar
          resolver _task = pure (Right ( undefined
                                        , recordingWorker ran
                                        , mkSystemSessionId "child"))
          input = DiSingle (Del.ChildTask "a1" "do the thing" Nothing Nothing)
      _ <- runDelegateAsync cfg pauseFlag Nothing 0 input resolver callback (pure (mkSystemSessionId "child"))
      result <- takeMVar resultMVar
      crStatus result `shouldBe` CsCompleted
      crSummary result `shouldBe` Just "done"
      crChildSession result `shouldBe` Just (mkSystemSessionId "child")

    it "resolve error calls callback with CsError" $ do
      pauseFlag <- newSpawnPauseFlag
      resultMVar <- newEmptyMVar :: IO (MVar ChildResult)
      let cfg = defaultDelegationConfig
          callback = putMVar resultMVar
          resolver _task = pure (Left "agent def not found: nope")
          input = DiSingle (Del.ChildTask "nope" "do the thing" Nothing Nothing)
      _ <- runDelegateAsync cfg pauseFlag Nothing 0 input resolver callback (pure (mkSystemSessionId "child"))
      result <- takeMVar resultMVar
      crStatus result `shouldBe` CsError
      crError result `shouldBe` Just "agent def not found: nope"

    it "worker exception results in CsError" $ do
      pauseFlag <- newSpawnPauseFlag
      resultMVar <- newEmptyMVar :: IO (MVar ChildResult)
      let cfg = defaultDelegationConfig
          callback = putMVar resultMVar
          crashingWorker :: Del.AgentWorkerBuilder
          crashingWorker _ _ _ _ = ioError (userError "boom")
          resolver _task = pure (Right (undefined, crashingWorker, mkSystemSessionId "child"))
          input = DiSingle (Del.ChildTask "a1" "do the thing" Nothing Nothing)
      _ <- runDelegateAsync cfg pauseFlag Nothing 0 input resolver callback (pure (mkSystemSessionId "child"))
      result <- takeMVar resultMVar
      crStatus result `shouldBe` CsError
      crExitReason result `shouldBe` CerError

    it "worker timeout results in CsTimeout" $ do
      pendingWith "minChildTimeoutSeconds=30 makes a real timeout test take >30s; \
                  \needs a test seam to lower the floor"
      pauseFlag <- newSpawnPauseFlag
      resultMVar <- newEmptyMVar :: IO (MVar ChildResult)
      let cfg = defaultDelegationConfig { dcChildTimeoutSeconds = Just 30 }
          callback = putMVar resultMVar
          slowWorker :: Del.AgentWorkerBuilder
          slowWorker _ _ _ _ = do
            threadDelay 31000000  -- 31s, just over the 30s timeout
            pure (ChildWorkerOutcome (Just "done") CerCompleted 0 0 (Just (mkSystemSessionId "child")))
          resolver _task = pure (Right (undefined, slowWorker, mkSystemSessionId "child"))
          input = DiSingle (Del.ChildTask "a1" "do the thing" Nothing Nothing)
      _ <- runDelegateAsync cfg pauseFlag Nothing 0 input resolver callback (pure (mkSystemSessionId "child"))
      result <- takeMVar resultMVar
      crStatus result `shouldBe` CsTimeout
      crExitReason result `shouldBe` CerTimeout

    it "spawn paused returns Left immediately" $ do
      pauseFlag <- newSpawnPauseFlag
      _ <- setSpawnPaused pauseFlag True
      let cfg = defaultDelegationConfig
          callback = const (pure ())
          dummyWorker :: Del.AgentWorkerBuilder
          dummyWorker _ _ _ _ = pure (ChildWorkerOutcome (Just "done") CerCompleted 0 0 (Just (mkSystemSessionId "child")))
          resolver _task = pure (Right (undefined, dummyWorker, mkSystemSessionId "child"))
          input = DiSingle (Del.ChildTask "a1" "do the thing" Nothing Nothing)
      eResult <- runDelegateAsync cfg pauseFlag Nothing 0 input resolver callback (pure (mkSystemSessionId "child"))
      case eResult of
        Left err -> T.isInfixOf "paused" err `shouldBe` True
        Right _  -> expectationFailure "expected Left (paused)"
      _ <- setSpawnPaused pauseFlag False
      pure ()

    it "batch mode runs children concurrently (max_concurrent_children respected)" $ do
      pauseFlag <- newSpawnPauseFlag
      concurrencyState <- newMVar (0 :: Int, 0 :: Int)
      let cfg = defaultDelegationConfig { dcChildTimeoutSeconds = Just 30 }
          callback = const (pure ())
          mkTask i = Del.ChildTask "a1" ("task " <> T.pack (show i)) Nothing Nothing
          tasks = [mkTask i | i <- [1..5 :: Int]]
          input = DiBatch tasks
          resolver _task = pure (Right (undefined, concurrencyTrackingWorker concurrencyState, mkSystemSessionId "child"))
      _ <- runDelegateAsync cfg pauseFlag Nothing 0 input resolver callback (pure (mkSystemSessionId "child"))
      -- Wait a bit for all workers to finish
      threadDelay 500000  -- 500ms
      mc <- maxConcurrent concurrencyState
      mc `shouldSatisfy` (<= 3)  -- max_concurrent_children=3

    it "registerCompletedAgentResult stores the ChildResult in the registry" $ do
      rt <- newAgentRuntime
      let sid = Del.SubagentId "test-12345678"
          childSid = mkSystemSessionId "child"
          result = ChildResult
            { crTaskIndex = 0
            , crStatus = CsCompleted
            , crSummary = Just "done"
            , crExitReason = CerCompleted
            , crDurationSeconds = 1.0
            , crSubagentId = sid
            , crTokensInput = 0
            , crTokensOutput = 0
            , crToolTrace = []
            , crError = Nothing
            , crFilesRead = []
            , crFilesWritten = []
            , crChildSession = Just childSid
            }
      -- First register a running instance (simulates startAgent)
      _ <- startAgent rt sampleDefId sid childSid 0 (pure ())
      -- Then register the completed result
      registerCompletedAgentResult rt sid result
      mInst <- agentInstanceBySubagentId rt sid
      case mInst of
        Just inst -> do
          aiStatus inst `shouldBe` Stopped
          aiResult inst `shouldBe` Just result
        Nothing -> expectationFailure "instance not found in registry"

  describe "secret discipline" $
    it "orRecorded carries the def fields (agent-visible data, recorded in full, not a vault secret)" $ do
      backend <- noneBackend
      let op = agentDefWriteOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("p" :: Text), "model" .= ("m" :: Text), "system" .= ("not-a-secret" :: Text)]))
      let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
      T.isInfixOf "not-a-secret" recorded `shouldBe` True

