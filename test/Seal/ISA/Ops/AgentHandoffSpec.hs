{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.AgentHandoffSpec (spec) where

import Control.Concurrent (threadDelay)
import Data.Aeson (object, (.=))
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.Agent.Def.Backend
import Seal.Agent.Runtime.Delegation qualified as Del
import Seal.Agent.Runtime.Delegation
  ( ChildWorkerOutcome (..)
  , ChildExitReason (..)
  , defaultDelegationConfig
  , newSpawnPauseFlag
  , SpawnPauseFlag
  )
import Seal.Agent.Runtime.Registry
  ( AgentRuntime
  , newAgentRuntime
  , listAgents
  )
import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (SessionId, mkSystemSessionId)
import Seal.ISA.Opcode
  ( OpResult (..), localBackend, opAuthorize, opRun )
import Seal.ISA.Ops.Agent
  ( AgentStartWiring (..)
  , gateOpen
  , agentDefWriteOp
  , agentManageOp
  )
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Types.App (App, runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)
import Seal.Logging.Logger (testSealLogger)

runTestApp :: App a -> IO a
runTestApp act = do logger <- testSealLogger; env <- mkEnv logger defaultConfig; runApp env act

sampleSession :: SessionId
sampleSession = mkSystemSessionId "s1"

samplePaths :: SealPaths
samplePaths = SealPaths
  { spHome = "/tmp/seal-test"
  , spConfig = "/tmp/seal-test/config"
  , spState = "/tmp/seal-test/state"
  , spKeys = "/tmp/seal-test/keys"
  , spCache = "/tmp/seal-test/cache"
  }

-- | A worker that records it ran and returns a completed outcome.
recordingWorker :: IORef Int -> Del.AgentWorkerBuilder
recordingWorker ref _ _ _ _ = do
  modifyIORef' ref (+1)
  pure (ChildWorkerOutcome (Just "done") CerCompleted 0 0 (Just (mkSystemSessionId "handoff-child")))

-- | A stub worker that should never be called (used in authorize tests).
stubWorker :: Del.AgentWorkerBuilder
stubWorker _ _ _ _ = pure (ChildWorkerOutcome (Just "stub") CerCompleted 0 0 Nothing)

-- | Build a minimal AgentStartWiring for handoff tests.
mkWiring :: AgentDefBackend -> AgentRuntime -> SpawnPauseFlag -> AgentStartWiring
mkWiring backend rt pauseFlag = AgentStartWiring
  { aswDefBackend = backend
  , aswRuntime = rt
  , aswConfig = pure defaultDelegationConfig
  , aswPauseFlag = pauseFlag
  , aswParentActivity = Nothing
  , aswMintSession = pure (mkSystemSessionId "fresh-session")
  , aswParentDepth = 0
  , aswWorker = stubWorker
  , aswGate = gateOpen
  , aswPaths = samplePaths
  , aswParentSession = sampleSession
  , aswRunRecords = Nothing
  , aswOnIdleCompletion = Nothing
  }

spec :: Spec
spec = describe "Seal.ISA.Ops.AgentHandoff" $ do
  describe "AGENT_MANAGE action=handoff (authorize)" $ do
    it "accepts action=handoff with id + goal" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      let wiring = mkWiring backend rt pauseFlag
      case opAuthorize (agentManageOp wiring stubWorker)
                       (object ["action" .= ("handoff" :: Text), "id" .= ("a1" :: Text), "goal" .= ("do stuff" :: Text)]) of
        Right () -> pure ()
        Left e   -> expectationFailure ("expected authorize to pass, got: " <> T.unpack e)

    it "rejects missing goal" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      let wiring = mkWiring backend rt pauseFlag
      case opAuthorize (agentManageOp wiring stubWorker)
                       (object ["action" .= ("handoff" :: Text), "id" .= ("a1" :: Text)]) of
        Left e   -> T.isInfixOf "goal" e `shouldBe` True
        Right () -> expectationFailure "expected authorize to reject missing goal"

    it "rejects missing id" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      let wiring = mkWiring backend rt pauseFlag
      case opAuthorize (agentManageOp wiring stubWorker)
                       (object ["action" .= ("handoff" :: Text), "goal" .= ("do stuff" :: Text)]) of
        Left e   -> T.isInfixOf "id" e `shouldBe` True
        Right () -> expectationFailure "expected authorize to reject missing id"

    it "rejects batch mode (tasks array instead of id+goal)" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      let wiring = mkWiring backend rt pauseFlag
      -- tasks without top-level id → authorize rejects because 'id' is missing.
      case opAuthorize (agentManageOp wiring stubWorker)
                       (object ["action" .= ("handoff" :: Text)
                               , "tasks" .= [object ["id" .= ("a1" :: Text), "goal" .= ("go" :: Text)]]]) of
        Left e   -> T.isInfixOf "id" e `shouldBe` True
        Right () -> expectationFailure "expected authorize to reject batch mode (no top-level id)"

  describe "AGENT_MANAGE action=handoff (run)" $ do
    it "returns immediately with session_id + subagent_id (running)" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      ran <- newIORef (0 :: Int)
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text)
                                     , "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      let wiring = mkWiring backend rt pauseFlag
          worker = recordingWorker ran
      r <- runTestApp (opRun (agentManageOp wiring worker) localBackend
                            (object ["action" .= ("handoff" :: Text), "id" .= ("a1" :: Text)
                                    , "goal" .= ("do the thing" :: Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> do
          T.isInfixOf "running" t `shouldBe` True
          T.isInfixOf "handoff" t `shouldBe` True
        _ -> expectationFailure "expected a single text part"
      -- The async worker should have run.
      threadDelay 100000
      readIORef ran `shouldReturn` 1

    it "returns success immediately even for unknown def (error is async)" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      ran <- newIORef (0 :: Int)
      let wiring = mkWiring backend rt pauseFlag
          worker = recordingWorker ran
      r <- runTestApp (opRun (agentManageOp wiring worker) localBackend
                            (object ["action" .= ("handoff" :: Text), "id" .= ("nope" :: Text)
                                    , "goal" .= ("go" :: Text)]))
      -- The spawn returns immediately with SpawnInfo — the def resolution
      -- error is delivered async via the completion callback (which
      -- registers the error result in the runtime).
      orIsError r `shouldBe` False
      -- The worker should NOT have run (def resolution fails).
      threadDelay 100000
      readIORef ran `shouldReturn` 0

    it "registers the agent in the runtime after a delay (visible via listAgents)" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      ran <- newIORef (0 :: Int)
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text)
                                     , "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      let wiring = mkWiring backend rt pauseFlag
          worker = recordingWorker ran
      _ <- runTestApp (opRun (agentManageOp wiring worker) localBackend
                            (object ["action" .= ("handoff" :: Text), "id" .= ("a1" :: Text)
                                    , "goal" .= ("do the thing" :: Text)]))
      -- The spawn callback runs in a forked thread — wait for it.
      threadDelay 100000
      insts <- listAgents rt
      length insts `shouldBe` 1