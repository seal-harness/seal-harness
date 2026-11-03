{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.AgentHandoffSpec (spec) where

import Control.Concurrent (threadDelay)
import Data.Aeson (object, (.=))
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
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
  ( OpResult (..), localBackend, opAuthorize, opRun, toDesc, toInSchema )
import Seal.ISA.Ops.Agent
  ( AgentStartWiring (..)
  , AgentHandoffDeps (..)
  , gateOpen
  , agentDefWriteOp
  , agentManageOp
  )
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (saveSessionMeta)
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

-- | Handoff deps with a stub worker and no tab callback (tests).
stubDeps :: Del.AgentWorkerBuilder -> AgentHandoffDeps
stubDeps worker = AgentHandoffDeps { ahdWorker = worker, ahdEnsureTab = Nothing }

-- | Handoff deps that track whether ensureTab was called.
tabTrackingDeps :: IORef Bool -> Del.AgentWorkerBuilder -> AgentHandoffDeps
tabTrackingDeps ref worker = AgentHandoffDeps
  { ahdWorker = worker
  , ahdEnsureTab = Just (\_ -> writeIORef ref True)
  }

spec :: Spec
spec = describe "Seal.ISA.Ops.AgentHandoff" $ do
  describe "AGENT_MANAGE action=handoff (authorize)" $ do
    it "accepts action=handoff with id + goal" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      let wiring = mkWiring backend rt pauseFlag
      case opAuthorize (agentManageOp wiring (stubDeps stubWorker))
                       (object ["action" .= ("handoff" :: Text), "id" .= ("a1" :: Text), "goal" .= ("do stuff" :: Text)]) of
        Right () -> pure ()
        Left e   -> expectationFailure ("expected authorize to pass, got: " <> T.unpack e)

    it "rejects missing goal" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      let wiring = mkWiring backend rt pauseFlag
      case opAuthorize (agentManageOp wiring (stubDeps stubWorker))
                       (object ["action" .= ("handoff" :: Text), "id" .= ("a1" :: Text)]) of
        Left e   -> T.isInfixOf "goal" e `shouldBe` True
        Right () -> expectationFailure "expected authorize to reject missing goal"

    it "rejects missing id" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      let wiring = mkWiring backend rt pauseFlag
      case opAuthorize (agentManageOp wiring (stubDeps stubWorker))
                       (object ["action" .= ("handoff" :: Text), "goal" .= ("do stuff" :: Text)]) of
        Left e   -> T.isInfixOf "id" e `shouldBe` True
        Right () -> expectationFailure "expected authorize to reject missing id"

    it "rejects batch mode (tasks array instead of id+goal)" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      let wiring = mkWiring backend rt pauseFlag
      case opAuthorize (agentManageOp wiring (stubDeps stubWorker))
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
          deps = stubDeps (recordingWorker ran)
      r <- runTestApp (opRun (agentManageOp wiring deps) localBackend
                            (object ["action" .= ("handoff" :: Text), "id" .= ("a1" :: Text)
                                    , "goal" .= ("do the thing" :: Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> do
          T.isInfixOf "running" t `shouldBe` True
          T.isInfixOf "handoff" t `shouldBe` True
        _ -> expectationFailure "expected a single text part"
      threadDelay 100000
      readIORef ran `shouldReturn` 1

    it "returns success immediately even for unknown def (error is async)" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      ran <- newIORef (0 :: Int)
      let wiring = mkWiring backend rt pauseFlag
          deps = stubDeps (recordingWorker ran)
      r <- runTestApp (opRun (agentManageOp wiring deps) localBackend
                            (object ["action" .= ("handoff" :: Text), "id" .= ("nope" :: Text)
                                    , "goal" .= ("go" :: Text)]))
      orIsError r `shouldBe` False
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
          deps = stubDeps (recordingWorker ran)
      _ <- runTestApp (opRun (agentManageOp wiring deps) localBackend
                            (object ["action" .= ("handoff" :: Text), "id" .= ("a1" :: Text)
                                    , "goal" .= ("do the thing" :: Text)]))
      threadDelay 100000
      insts <- listAgents rt
      length insts `shouldBe` 1

  describe "AGENT_MANAGE action=handoff (active_tab)" $ do
    it "calls ensureTab by default (active_tab not specified)" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      ran <- newIORef (0 :: Int)
      tabCalled <- newIORef False
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text)
                                     , "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      let wiring = mkWiring backend rt pauseFlag
          deps = tabTrackingDeps tabCalled (recordingWorker ran)
      _ <- runTestApp (opRun (agentManageOp wiring deps) localBackend
                            (object ["action" .= ("handoff" :: Text), "id" .= ("a1" :: Text)
                                    , "goal" .= ("do the thing" :: Text)]))
      readIORef tabCalled `shouldReturn` True

    it "calls ensureTab when active_tab=true" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      ran <- newIORef (0 :: Int)
      tabCalled <- newIORef False
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text)
                                     , "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      let wiring = mkWiring backend rt pauseFlag
          deps = tabTrackingDeps tabCalled (recordingWorker ran)
      _ <- runTestApp (opRun (agentManageOp wiring deps) localBackend
                            (object ["action" .= ("handoff" :: Text), "id" .= ("a1" :: Text)
                                    , "goal" .= ("do the thing" :: Text)
                                    , "active_tab" .= True]))
      readIORef tabCalled `shouldReturn` True

    it "does NOT call ensureTab when active_tab=false" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      ran <- newIORef (0 :: Int)
      tabCalled <- newIORef False
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text)
                                     , "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      let wiring = mkWiring backend rt pauseFlag
          deps = tabTrackingDeps tabCalled (recordingWorker ran)
      _ <- runTestApp (opRun (agentManageOp wiring deps) localBackend
                            (object ["action" .= ("handoff" :: Text), "id" .= ("a1" :: Text)
                                    , "goal" .= ("do the thing" :: Text)
                                    , "active_tab" .= False]))
      readIORef tabCalled `shouldReturn` False

  specHandoffRepo
-- ---------------------------------------------------------------------------
-- Handoff repo propagation (AGENT_MANAGE action=handoff, `repo` input)
-- ---------------------------------------------------------------------------

-- | A worker that captures the 'ChildTask' it was handed (and runs nothing),
-- so the opcode's task construction can be asserted.
taskRecordingWorker :: IORef (Maybe Del.ChildTask) -> Del.AgentWorkerBuilder
taskRecordingWorker ref _def _childSid task _hooks = do
  writeIORef ref (Just task)
  pure (ChildWorkerOutcome (Just "done") CerCompleted 0 0
         (Just (mkSystemSessionId "handoff-child")))

-- | 'AgentStartWiring' over an explicit 'SealPaths' (so the caller's
-- @session.json@ can be seeded in a temp dir).
mkWiringAt :: SealPaths -> AgentDefBackend -> AgentRuntime -> SpawnPauseFlag -> AgentStartWiring
mkWiringAt paths backend rt pauseFlag =
  (mkWiring backend rt pauseFlag) { aswPaths = paths }

-- | A caller session meta carrying the given repo.
callerMetaWithRepo :: Maybe Text -> SessionMeta
callerMetaWithRepo mRepo = SessionMeta
  { smId = sampleSession
  , smProvider = "ollama"
  , smModel = "llama3"
  , smChannel = "web"
  , smParent = Nothing
  , smAgent = Nothing
  , smSystemOverride = Nothing
  , smAgentName = Nothing
  , smDescription = Nothing
  , smSealFrontMatter = True
  , smRepoUrl = mRepo
  , smCreatedAt = t
  , smLastActive = t
  }
  where
    t = read "1970-01-01 00:00:00 UTC"

specHandoffRepo :: Spec
specHandoffRepo = describe "AGENT_MANAGE action=handoff (repo)" $ do
  it "passes an explicit repo through with an isolated workdir" $
    withSystemTempDirectory "seal-handoff-op" $ \tmp -> do
      let paths = samplePathsAt tmp
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text)
                                     , "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      taskRef <- newIORef Nothing
      let wiring = mkWiringAt paths backend rt pauseFlag
      r <- runTestApp (opRun (agentManageOp wiring (stubDeps (taskRecordingWorker taskRef))) localBackend
                            (object ["action" .= ("handoff" :: Text), "id" .= ("a1" :: Text)
                                    , "goal" .= ("go" :: Text)
                                    , "repo" .= ("https://explicit/x.git" :: Text)]))
      orIsError r `shouldBe` False
      threadDelay 100000
      mTask <- readIORef taskRef
      fmap Del.ctRepoUrl mTask `shouldBe` Just (Just "https://explicit/x.git")
      fmap Del.ctIsolateWorkdir mTask `shouldBe` Just True

  it "inherits the caller's repo when `repo` is absent, and says so" $
    withSystemTempDirectory "seal-handoff-inherit" $ \tmp -> do
      let paths = samplePathsAt tmp
      saveSessionMeta paths (callerMetaWithRepo (Just "https://caller/repo.git"))
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text)
                                     , "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      taskRef <- newIORef Nothing
      let wiring = mkWiringAt paths backend rt pauseFlag
      r <- runTestApp (opRun (agentManageOp wiring (stubDeps (taskRecordingWorker taskRef))) localBackend
                            (object ["action" .= ("handoff" :: Text), "id" .= ("a1" :: Text)
                                    , "goal" .= ("go" :: Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> T.isInfixOf "https://caller/repo.git" t `shouldBe` True
        _           -> expectationFailure "expected a single text part"
      threadDelay 100000
      mTask <- readIORef taskRef
      fmap Del.ctRepoUrl mTask `shouldBe` Just (Just "https://caller/repo.git")

  it "leaves ctRepoUrl Nothing (and reports none) when nobody has a repo" $
    withSystemTempDirectory "seal-handoff-none" $ \tmp -> do
      let paths = samplePathsAt tmp
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text)
                                     , "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      taskRef <- newIORef Nothing
      let wiring = mkWiringAt paths backend rt pauseFlag
      r <- runTestApp (opRun (agentManageOp wiring (stubDeps (taskRecordingWorker taskRef))) localBackend
                            (object ["action" .= ("handoff" :: Text), "id" .= ("a1" :: Text)
                                    , "goal" .= ("go" :: Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> T.isInfixOf "repo: none" t `shouldBe` True
        _           -> expectationFailure "expected a single text part"
      threadDelay 100000
      mTask <- readIORef taskRef
      fmap Del.ctRepoUrl mTask `shouldBe` Just Nothing

  it "rejects an invalid repo and does not spawn" $
    withSystemTempDirectory "seal-handoff-bad" $ \tmp -> do
      let paths = samplePathsAt tmp
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      ran <- newIORef (0 :: Int)
      let wiring = mkWiringAt paths backend rt pauseFlag
      r <- runTestApp (opRun (agentManageOp wiring (stubDeps (recordingWorker ran))) localBackend
                            (object ["action" .= ("handoff" :: Text), "id" .= ("a1" :: Text)
                                    , "goal" .= ("go" :: Text)
                                    , "repo" .= ("https://x/y.git; rm -rf /" :: Text)]))
      orIsError r `shouldBe` True
      case orParts r of
        [TrpText t] -> T.isInfixOf "repo" t `shouldBe` True
        _           -> expectationFailure "expected a single text part"
      threadDelay 100000
      readIORef ran `shouldReturn` 0

  it "exposes `repo` in the AGENT_MANAGE input schema and names it in toDesc" $ do
    backend <- noneBackend
    rt <- newAgentRuntime
    pauseFlag <- newSpawnPauseFlag
    let op = agentManageOp (mkWiring backend rt pauseFlag) (stubDeps stubWorker)
    T.isInfixOf "repo" (T.pack (show (toInSchema op))) `shouldBe` True
    T.isInfixOf "repo" (toDesc op) `shouldBe` True

-- | A 'SealPaths' fixture rooted at @tmp@.
samplePathsAt :: FilePath -> SealPaths
samplePathsAt tmp = SealPaths
  { spHome = tmp
  , spConfig = tmp </> "config"
  , spState = tmp </> "state"
  , spKeys = tmp </> "keys"
  , spCache = tmp </> "cache"
  }
