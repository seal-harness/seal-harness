{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.AgentSpec (spec) where

import Data.Time (UTCTime (..), fromGregorian, getCurrentTime, secondsToDiffTime)
import Control.Concurrent (ThreadId, myThreadId, threadDelay)
import Control.Concurrent.MVar
  ( MVar, newMVar, modifyMVar, withMVar, newEmptyMVar, takeMVar, putMVar )
import Control.Exception (AsyncException (ThreadKilled), bracket, throwIO)
import Control.Monad (forM_, replicateM, replicateM_, void, when)
import Data.Aeson (Value, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Agent.Def.Backend
import Seal.Agent.Def.Types (AgentDef (..), AgentDefId (..), mkAgentDefId)
import Seal.Agent.Runtime.Delegation qualified as Del
import Seal.Agent.Runtime.Delegation
  ( ChildExitReason (..), ChildResult (..), ChildStatus (..)
  , ChildRunHooks (..)
  , ChildWorkerOutcome (..)
  , DelegateInput (..)
  , ToolTraceEntry (..)
  , runChildTask
  , runDelegate
  , SpawnInfo (..)
  , defaultDelegationConfig, dcChildTimeoutSeconds, dcMaxConcurrentChildren
  , newSpawnPauseFlag, setSpawnPaused
  , runDelegateAsync
  , spawnPausedMsg
  , subagentIdText
  )
import Seal.Agent.Runtime.Registry
import Seal.Config.Paths (SealPaths (..), agentSessionDir)
import Seal.Core.Types (SessionId, mkSystemSessionId, ModelId (..))
import Seal.ISA.Opcode
  ( OpResult (..), localBackend, opAuthorize, opRun )
import Seal.ISA.Ops.Agent
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Policy (AllowList (..))
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

-- | A minimal SealPaths fixture for tests that need it (the async
-- completion callback uses it for appendConversationMessage — IO errors
-- are swallowed so the paths don't need to point to real directories).
samplePaths :: SealPaths
samplePaths = SealPaths
  { spHome = "/tmp/seal-test"
  , spConfig = "/tmp/seal-test/config"
  , spState = "/tmp/seal-test/state"
  , spKeys = "/tmp/seal-test/keys"
  , spCache = "/tmp/seal-test/cache"
  }

-- | A worker that records it ran, returns a fixed summary, and completes
-- (synchronous semantics). The new AGENT_START blocks until the worker
-- returns, so this is the test analog of a child that runs to completion.
recordingWorker :: IORef Int -> Del.AgentWorkerBuilder
recordingWorker ref _ _ _ _ = do
  modifyIORef' ref (+1)
  pure (ChildWorkerOutcome (Just "done") CerCompleted 0 0 (Just (mkSystemSessionId "child")))

-- | A worker that returns a fixed summary string and completes. Used by
-- foreground mode tests where we want a specific summary text.
recordingWorker' :: Text -> Del.AgentWorkerBuilder
recordingWorker' summary _ _ _ _ =
  pure (ChildWorkerOutcome (Just summary) CerCompleted 0 0 (Just (mkSystemSessionId "child")))

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

-- | Wiring for the AGENT_MANAGE lifecycle tests: the standard test env with
-- one injectable worker and an optional idle-wake hook.
mkLifecycleWiring
  :: AgentDefBackend -> AgentRuntime -> Del.SpawnPauseFlag
  -> Del.AgentWorkerBuilder -> Maybe (IO ()) -> AgentStartWiring
mkLifecycleWiring = mkLifecycleWiringAt samplePaths

-- | 'mkLifecycleWiring' over an explicit 'SealPaths' — the @continue@ tests
-- need a real child directory to look for.
mkLifecycleWiringAt
  :: SealPaths -> AgentDefBackend -> AgentRuntime -> Del.SpawnPauseFlag
  -> Del.AgentWorkerBuilder -> Maybe (IO ()) -> AgentStartWiring
mkLifecycleWiringAt paths backend rt pauseFlag worker onIdle = AgentStartWiring
  { aswDefBackend = backend
  , aswRuntime = rt
  , aswConfig = pure defaultDelegationConfig
  , aswPauseFlag = pauseFlag
  , aswParentActivity = Nothing
  , aswMintSession = pure (mkSystemSessionId "fresh")
  , aswParentDepth = 0
  , aswWorker = worker
  , aswGate = gateOpen
  , aswPaths = paths
  , aswParentSession = sampleSession
  , aswRunRecords = Nothing
  , aswOnIdleCompletion = onIdle
  }

-- | Register the @a1@ def the lifecycle tests spawn.
defineGreeter :: AgentDefBackend -> IO ()
defineGreeter backend = void $ runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
  (object [ "id" .= ("a1" :: Text), "name" .= ("g" :: Text)
          , "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text) ]))

-- | A minimal 'AgentDef' for the 'runChildTask' tests. The child-run core
-- takes the def as a parameter, and the test workers ignore it.
sampleAgentDef :: AgentDef
sampleAgentDef = AgentDef
  { adId          = AgentDefId "a1"
  , adName        = "test-agent"
  , adProvider    = "ollama"
  , adModel       = ModelId "llama3"
  , adSystem      = Nothing
  , adTools       = AllowAll
  , adGroup       = Nothing
  , adRole        = Nothing
  , adDescription = Nothing
  , adAllowSpawn  = Nothing
  , adCreatedAt   = UTCTime (fromGregorian 1970 1 1) 0
  , adUpdatedAt   = UTCTime (fromGregorian 1970 1 1) 0
  , adSession     = sampleSession
  }

-- | A worker that sleeps for the given number of seconds, so a short
-- 'runChildTask' timeout can fire without waiting the 30 s config floor.
sleepingWorker :: Double -> Del.AgentWorkerBuilder
sleepingWorker secs _ _ _ _ = do
  threadDelay (round (secs * 1000000))
  pure (ChildWorkerOutcome (Just "slow") CerCompleted 0 0 (Just (mkSystemSessionId "child")))

-- | A worker that blocks until the gate MVar is filled — used to hold a
-- child inside the run body while another property is asserted.
gatedWorker :: MVar () -> Del.AgentWorkerBuilder
gatedWorker gate _ _ _ _ = do
  takeMVar gate
  pure (ChildWorkerOutcome (Just "released") CerCompleted 0 0 (Just (mkSystemSessionId "child")))

-- | A worker that captures the 'ChildTask' it received (so tests can assert
-- on parsed fields like 'ctIsolateWorkdir'). Returns a completed outcome.
taskCapturingWorker :: IORef (Maybe Del.ChildTask) -> Del.AgentWorkerBuilder
taskCapturingWorker ref _ _ task _ = do
  writeIORef ref (Just task)
  pure (ChildWorkerOutcome (Just "done") CerCompleted 0 0 (Just (mkSystemSessionId "child")))

-- | Paths rooted in a scratch dir, so a @continue@ test's child directory is
-- real without touching any other test's fixture.
scratchPaths :: FilePath -> SealPaths
scratchPaths root = SealPaths
  { spHome = root
  , spConfig = root </> "config"
  , spState = root </> "state"
  , spKeys = root </> "keys"
  , spCache = root </> "cache"
  }

-- | The child session every test spawn mints.
childSessionFixture :: SessionId
childSessionFixture = mkSystemSessionId "fresh"

-- | Create the child's session directory, with a conversation of the given
-- size (0 = "killed before the first request").
seedChildDir :: SealPaths -> SessionId -> Int -> IO ()
seedChildDir paths owner bytes = do
  let dir = agentSessionDir paths owner childSessionFixture
  createDirectoryIfMissing True dir
  writeFile (dir </> "conversation.jsonl") (replicate bytes 'x')

-- | The single text part of a tool result.
resultText :: OpResult -> Text
resultText r = case orParts r of
  [TrpText t] -> t
  _           -> ""

-- | The continue gate's refusal text (or a failure if it allowed the call).
gateRefusal :: AgentStartWiring -> Value -> IO Text
gateRefusal wiring v = case opAuthorize (agentManageOp wiring) v of
  Left e   -> pure e
  Right () -> expectationFailure "expected the gate to refuse" >> pure ""

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

  describe "AGENT_DEF_MANAGE read (ambiguous bare id)" $ do
    it "surfaces an ambiguity message with matching ids" $ do
      let mkAid t = case mkAgentDefId t of Right a -> a; Left _ -> AgentDefId "fallback"
          mkD t = AgentDef
            { adId = mkAid t, adName = t, adProvider = "ollama"
            , adModel = ModelId "llama3", adSystem = Just "be nice"
            , adTools = AllowAll, adGroup = Nothing, adRole = Nothing
            , adDescription = Nothing
    , adAllowSpawn = Nothing
            , adCreatedAt = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)
            , adUpdatedAt = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)
            , adSession = sampleSession
            }
      backend <- staticAgentDefBackend [mkD "repo1--foo", mkD "repo2--foo"]
      let op = agentDefManageOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["action" .= ("read" :: Text), "id" .= ("foo" :: Text)]))
      orIsError r `shouldBe` True
      case orParts r of
        [TrpText t] -> do
          "ambiguous" `T.isInfixOf` t `shouldBe` True
          "repo1--foo" `T.isInfixOf` t `shouldBe` True
          "repo2--foo" `T.isInfixOf` t `shouldBe` True
        _ -> expectationFailure "expected a single text part"

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

  describe "AGENT_START (async, goal-driven)" $ do
    it "returns immediately with SpawnInfo (status=running)" $ do
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
            , aswPaths = samplePaths
            , aswParentSession = sampleSession
            , aswRunRecords = Nothing
            , aswOnIdleCompletion = Nothing
            }
      r <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["id" .= ("a1" :: Text), "goal" .= ("do the thing" :: Text)]))
      orIsError r `shouldBe` False
      -- The result text contains "running" (async return — not the summary).
      case orParts r of
        [TrpText t] -> T.isInfixOf "running" t `shouldBe` True
        _           -> expectationFailure "expected a single text part"
      -- Wait for the async worker to finish.
      threadDelay 100000  -- 100ms
      readIORef ran `shouldReturn` 1

    it "AGENT_START does not truncate long summaries (verified via AGENT_STATUS)" $ do
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
            , aswPaths = samplePaths
            , aswParentSession = sampleSession
            , aswRunRecords = Nothing
            , aswOnIdleCompletion = Nothing
            }
      r <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["id" .= ("a1" :: Text), "goal" .= ("do the thing" :: Text)]))
      orIsError r `shouldBe` False
      -- Wait for the async worker to finish.
      threadDelay 100000  -- 100ms
      readIORef ran `shouldReturn` 1
      -- The full 500-char summary is stored in the registry via
      -- registerCompletedAgentResult; AGENT_STATUS returns it.
      insts <- listAgents rt
      case insts of
        (inst : _) -> case aiResult inst of
          Just result -> crSummary result `shouldBe` Just longSummary
          Nothing     -> expectationFailure "expected aiResult to be populated"
        [] -> expectationFailure "expected at least one agent in registry"

    it "AGENT_START resolve error surfaces via callback (def not found)" $ do
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
            , aswPaths = samplePaths
            , aswParentSession = sampleSession
            , aswRunRecords = Nothing
            , aswOnIdleCompletion = Nothing
            }
      r <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["id" .= ("nope" :: Text), "goal" .= ("x" :: Text)]))
      -- The opcode returns SpawnInfo (not an error — the resolve error
      -- is async, delivered via the callback).
      orIsError r `shouldBe` False
      -- Wait for the async resolve error to propagate.
      threadDelay 100000  -- 100ms
      -- The error child won't be in the registry (resolve errors don't
      -- register). But the SpawnInfo was returned.
      case orParts r of
        [TrpText t] -> T.isInfixOf "running" t `shouldBe` True
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
            , aswPaths = samplePaths
            , aswParentSession = sampleSession
            , aswRunRecords = Nothing
            , aswOnIdleCompletion = Nothing
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
            , aswPaths = samplePaths
            , aswParentSession = sampleSession
            , aswRunRecords = Nothing
            , aswOnIdleCompletion = Nothing
            }
      r <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["tasks" .= [ object ["id" .= ("a1" :: Text), "goal" .= ("task one" :: Text)]
                                                , object ["id" .= ("a1" :: Text), "goal" .= ("task two" :: Text)] ]]))
      orIsError r `shouldBe` False
      -- Both tasks spawned (batch mode fans out — 2 SpawnInfo returned).
      threadDelay 100000  -- 100ms for async workers
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
            , aswPaths = samplePaths
            , aswParentSession = sampleSession
            , aswRunRecords = Nothing
            , aswOnIdleCompletion = Nothing
            }
      r <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["tasks" .= [ object ["id" .= ("a1" :: Text), "goal" .= ("t1" :: Text)]
                                                , object ["id" .= ("a1" :: Text), "goal" .= ("t2" :: Text)]
                                                , object ["id" .= ("a1" :: Text), "goal" .= ("t3" :: Text)]
                                                , object ["id" .= ("a1" :: Text), "goal" .= ("t4" :: Text)]
                                                , object ["id" .= ("a1" :: Text), "goal" .= ("t5" :: Text)] ]]))
      orIsError r `shouldBe` False
      -- Wait for the async workers to finish (each sleeps 50ms, 5 tasks
      -- with max_concurrent=3 → ~100ms total).
      threadDelay 300000  -- 300ms
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
            , aswPaths = samplePaths
            , aswParentSession = sampleSession
            , aswRunRecords = Nothing
            , aswOnIdleCompletion = Nothing
            }
      r <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["id" .= ("a1" :: Text), "goal" .= ("x" :: Text)]))
      orIsError r `shouldBe` True
      readIORef ran `shouldReturn` 0
      _ <- setSpawnPaused pauseFlag False
      pure ()

    it "AGENT_START parses isolate_workdir=true (single-task mode)" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      taskRef <- newIORef (Nothing :: Maybe Del.ChildTask)
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
            , aswWorker = taskCapturingWorker taskRef
            , aswGate = gateOpen
            , aswPaths = samplePaths
            , aswParentSession = sampleSession
            , aswRunRecords = Nothing
            , aswOnIdleCompletion = Nothing
            }
      r <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["id" .= ("a1" :: Text), "goal" .= ("x" :: Text), "isolate_workdir" .= True]))
      orIsError r `shouldBe` False
      threadDelay 100000  -- 100ms for the async worker
      mt <- readIORef taskRef
      case mt of
        Just t  -> Del.ctIsolateWorkdir t `shouldBe` True
        Nothing -> expectationFailure "worker did not receive a ChildTask"

    it "AGENT_START defaults isolate_workdir to false when omitted (single-task mode)" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      taskRef <- newIORef (Nothing :: Maybe Del.ChildTask)
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
            , aswWorker = taskCapturingWorker taskRef
            , aswGate = gateOpen
            , aswPaths = samplePaths
            , aswParentSession = sampleSession
            , aswRunRecords = Nothing
            , aswOnIdleCompletion = Nothing
            }
      r <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["id" .= ("a1" :: Text), "goal" .= ("x" :: Text)]))
      orIsError r `shouldBe` False
      threadDelay 100000  -- 100ms for the async worker
      mt <- readIORef taskRef
      case mt of
        Just t  -> Del.ctIsolateWorkdir t `shouldBe` False
        Nothing -> expectationFailure "worker did not receive a ChildTask"

    it "AGENT_START parses isolate_workdir=true in batch mode (tasks array)" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      taskRef <- newIORef (Nothing :: Maybe Del.ChildTask)
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
            , aswWorker = taskCapturingWorker taskRef
            , aswGate = gateOpen
            , aswPaths = samplePaths
            , aswParentSession = sampleSession
            , aswRunRecords = Nothing
            , aswOnIdleCompletion = Nothing
            }
      r <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["tasks" .= [ object ["id" .= ("a1" :: Text), "goal" .= ("x" :: Text), "isolate_workdir" .= True] ]]))
      orIsError r `shouldBe` False
      threadDelay 100000  -- 100ms for the async worker
      mt <- readIORef taskRef
      case mt of
        Just t  -> Del.ctIsolateWorkdir t `shouldBe` True
        Nothing -> expectationFailure "worker did not receive a ChildTask"

  describe "AGENT_INSTANCES / STATUS / STOP / INTERRUPT (subagent-id keyed)" $ do
    it "AGENT_INSTANCES reports (no agents running) when the synchronous model has finished" $ do
      rt <- newAgentRuntime
      r <- runTestApp (opRun (agentInstancesOp sampleSession rt) localBackend (object []))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> t `shouldBe` "(no agents running)"
        _           -> expectationFailure "expected a single text part"

    it "AGENT_STATUS reports not running when absent" $ do
      rt <- newAgentRuntime
      r <- runTestApp (opRun (agentStatusOp sampleSession rt) localBackend (object ["subagent_id" .= ("sa-x-00000001" :: Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> T.isInfixOf "unknown subagent id" t `shouldBe` True
        _           -> expectationFailure "expected a single text part"

    it "AGENT_STOP is idempotent on a non-running subagent id" $ do
      rt <- newAgentRuntime
      r <- runTestApp (opRun (agentStopOp sampleSession rt) localBackend (object ["subagent_id" .= ("sa-x-00000001" :: Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> t `shouldBe` "stopped (resumable with AGENT_MANAGE continue)"
        _           -> expectationFailure "expected a single text part"

    it "AGENT_INTERRUPT returns 'subagent not running' when no match" $ do
      rt <- newAgentRuntime
      r <- runTestApp (opRun (agentInterruptOp sampleSession rt) localBackend (object ["subagent_id" .= ("sa-x-00000001" :: Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> t `shouldBe` "subagent not running"
        _           -> expectationFailure "expected a single text part"

  describe "run lifecycle through AGENT_START / STATUS / INSTANCES / STOP" $ do
    it "STATUS reports runs=, origin= and the resumable hint for a retained child" $ do
      backend <- noneBackend
      defineGreeter backend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      gate <- newEmptyMVar :: IO (MVar ())
      let wiring = mkLifecycleWiring backend rt pauseFlag (gatedWorker gate) Nothing
      _ <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["id" .= ("a1" :: Text), "goal" .= ("do the thing" :: Text)]))
      registered <- pollUntil 2000 (not . null <$> listAgentsFor rt sampleSession)
      registered `shouldBe` True
      putMVar gate ()
      finished <- pollUntil 2000 (any (isJust . aiResult) <$> listAgentsFor rt sampleSession)
      finished `shouldBe` True
      insts <- listAgentsFor rt sampleSession
      case insts of
        [inst] -> do
          r <- runTestApp (opRun (agentStatusOp sampleSession rt) localBackend
                                 (object ["subagent_id" .= subagentIdText (aiSubagentId inst)]))
          case orParts r of
            [TrpText t] -> do
              T.isInfixOf "status=stopped" t `shouldBe` True
              T.isInfixOf "runs=1" t `shouldBe` True
              T.isInfixOf "origin=start/background" t `shouldBe` True
              T.isInfixOf "resumable: AGENT_MANAGE continue with this subagent_id" t `shouldBe` True
            _ -> expectationFailure "expected a single text part"
        _ -> expectationFailure "expected exactly one instance"

    it "INSTANCES lists only live children and summarises the finished ones" $ do
      backend <- noneBackend
      defineGreeter backend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      let wiring = mkLifecycleWiring backend rt pauseFlag (recordingWorker' "done") Nothing
      _ <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["id" .= ("a1" :: Text), "goal" .= ("do the thing" :: Text)]))
      finished <- pollUntil 2000 (any (isJust . aiResult) <$> listAgentsFor rt sampleSession)
      finished `shouldBe` True
      r <- runTestApp (opRun (agentInstancesOp sampleSession rt) localBackend (object []))
      case orParts r of
        [TrpText t] -> do
          T.isInfixOf "(no agents running)" t `shouldBe` True
          T.isInfixOf "(1 finished child(ren) from this session, all resumable with AGENT_MANAGE continue)"
            t `shouldBe` True
        _ -> expectationFailure "expected a single text part"

    it "a stop suppresses the completion delivery (no wake) and keeps the entry stopped" $ do
      backend <- noneBackend
      defineGreeter backend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      gate <- newEmptyMVar :: IO (MVar ())
      wakes <- newIORef (0 :: Int)
      let wiring = mkLifecycleWiring backend rt pauseFlag (gatedWorker gate)
                     (Just (void (atomicModifyIORef' wakes (\n -> (n + 1, n + 1)))))
      _ <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["id" .= ("a1" :: Text), "goal" .= ("do the thing" :: Text)]))
      registered <- pollUntil 2000 (not . null <$> listAgentsFor rt sampleSession)
      registered `shouldBe` True
      insts <- listAgentsFor rt sampleSession
      case insts of
        [inst] -> do
          stopR <- runTestApp (opRun (agentStopOp sampleSession rt) localBackend
                                 (object ["subagent_id" .= subagentIdText (aiSubagentId inst)]))
          orIsError stopR `shouldBe` False
          -- The killed run still reports its (error) result to the registry —
          -- generation-guarded, so the entry keeps 'Stopped' — but nothing is
          -- delivered to the parent.
          settled <- pollUntil 2000 (any (isJust . aiResult) <$> listAgentsFor rt sampleSession)
          settled `shouldBe` True
          afterStop <- agentStatusFor rt sampleSession (aiSubagentId inst)
          case afterStop of
            Left e -> expectationFailure ("stopped child vanished: " <> T.unpack e)
            Right i -> aiStatus i `shouldBe` Stopped
          readIORef wakes `shouldReturn` 0
        _ -> expectationFailure "expected exactly one instance"

    -- The idle wake runs the PARENT's synthetic turn. If it ran on the child's
    -- worker thread, the parent's turn would be nested inside the child's run:
    -- the parent could not stop or continue the child without waiting for
    -- itself, and a `continue` issued from the wake (the flagship flow) would
    -- deadlock on the child's own handle. So the hook must be forked.
    it "fires the completion wake off the child's worker thread" $ do
      backend <- noneBackend
      defineGreeter backend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      workerTid <- newIORef (Nothing :: Maybe ThreadId)
      wakeTid <- newIORef (Nothing :: Maybe ThreadId)
      let worker _ _ _ _ = do
            tid <- myThreadId
            writeIORef workerTid (Just tid)
            pure (ChildWorkerOutcome (Just "done") CerCompleted 0 0
                   (Just childSessionFixture))
          hook = do
            tid <- myThreadId
            writeIORef wakeTid (Just tid)
          wiring = mkLifecycleWiring backend rt pauseFlag worker (Just hook)
      _ <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["id" .= ("a1" :: Text), "goal" .= ("do the thing" :: Text)]))
      woke <- pollUntil 2000 (isJust <$> readIORef wakeTid)
      woke `shouldBe` True
      mWorker <- readIORef workerTid
      mWake <- readIORef wakeTid
      case (mWorker, mWake) of
        (Just w, Just k) -> do
          w `shouldSatisfy` (/= k)
        _ -> expectationFailure
               ("expected both threads to be recorded, got worker=" <> show mWorker
                  <> " wake=" <> show mWake)

  describe "subagent_id validation" $ do
    let tooLong = T.replicate 257 "a"
        atTheCap = T.replicate 256 "a"
    it "rejects a 257-character id" $ do
      rt <- newAgentRuntime
      r <- runTestApp (opRun (agentStatusOp sampleSession rt) localBackend
                             (object ["subagent_id" .= tooLong]))
      orIsError r `shouldBe` True
    it "accepts a 256-character id (and reports it unknown)" $ do
      rt <- newAgentRuntime
      r <- runTestApp (opRun (agentStatusOp sampleSession rt) localBackend
                             (object ["subagent_id" .= atTheCap]))
      orIsError r `shouldBe` False
    it "rejects a control character in the id" $ do
      rt <- newAgentRuntime
      r <- runTestApp (opRun (agentStatusOp sampleSession rt) localBackend
                             (object ["subagent_id" .= ("sa-a1-\n00000001" :: Text)]))
      orIsError r `shouldBe` True

  describe "AGENT_MANAGE continue — pure gate" $ do
    let sidText = "sa-a1-00000001" :: Text
        base = ["action" .= ("continue" :: Text)]
    it "accepts action=continue with a well-formed subagent_id" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pf <- newSpawnPauseFlag
      let w = mkLifecycleWiring backend rt pf (recordingWorker' "x") Nothing
      opAuthorize (agentManageOp w) (object (base <> ["subagent_id" .= sidText]))
        `shouldBe` Right ()

    it "rejects a missing, over-long, or control-character subagent_id" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pf <- newSpawnPauseFlag
      let w = mkLifecycleWiring backend rt pf (recordingWorker' "x") Nothing
      e1 <- gateRefusal w (object base)
      T.isInfixOf "at most 256 characters" e1 `shouldBe` True
      e2 <- gateRefusal w (object (base <> ["subagent_id" .= T.replicate 257 "a"]))
      T.isInfixOf "at most 256 characters" e2 `shouldBe` True
      e3 <- gateRefusal w (object (base <> ["subagent_id" .= ("sa-a1\n00000001" :: Text)]))
      T.isInfixOf "at most 256 characters" e3 `shouldBe` True

    it "rejects an empty, oversized, or control-character prompt" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pf <- newSpawnPauseFlag
      let w = mkLifecycleWiring backend rt pf (recordingWorker' "x") Nothing
          withPrompt p = object (base <> ["subagent_id" .= sidText, "prompt" .= p])
      e1 <- gateRefusal w (withPrompt ("" :: Text))
      T.isInfixOf "must not be empty" e1 `shouldBe` True
      e2 <- gateRefusal w (withPrompt (T.replicate (32 * 1024 + 1) "x"))
      T.isInfixOf "the limit is 32768" e2 `shouldBe` True
      e3 <- gateRefusal w (withPrompt ("a\tb" :: Text))
      T.isInfixOf "control characters" e3 `shouldBe` True
      -- the boundary is allowed
      opAuthorize (agentManageOp w) (withPrompt (T.replicate (32 * 1024) "x"))
        `shouldBe` Right ()

    it "rejects each start-only field with the pinned text" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pf <- newSpawnPauseFlag
      let w = mkLifecycleWiring backend rt pf (recordingWorker' "x") Nothing
      forM_ (["id", "goal", "context", "role"] :: [Text]) $ \f -> do
        e <- gateRefusal w (object (base <> ["subagent_id" .= sidText, Key.fromText f .= ("x" :: Text)]))
        e `shouldBe` ("continue: \"" <> f
                        <> "\" is a start-only field; pass the instruction as \"prompt\".")
      e <- gateRefusal w (object (base <> ["subagent_id" .= sidText, "tasks" .= ([] :: [Value])]))
      e `shouldBe` "continue: \"tasks\" is a start-only field; pass the instruction as \"prompt\"."

    it "rejects an unknown mode but accepts foreground and background" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pf <- newSpawnPauseFlag
      let w = mkLifecycleWiring backend rt pf (recordingWorker' "x") Nothing
          withMode m = object (base <> ["subagent_id" .= sidText, "mode" .= m])
      e <- gateRefusal w (withMode ("Foreground" :: Text))
      T.isInfixOf "\"mode\" must be" e `shouldBe` True
      opAuthorize (agentManageOp w) (withMode ("foreground" :: Text)) `shouldBe` Right ()
      opAuthorize (agentManageOp w) (withMode ("background" :: Text)) `shouldBe` Right ()

  describe "AGENT_MANAGE continue — behaviour" $ do
    let spawnGreeter w =
          runTestApp (opRun (agentStartOp w) localBackend
            (object ["id" .= ("a1" :: Text), "goal" .= ("do the thing" :: Text)]))
        continueOn w fields =
          runTestApp (opRun (agentManageOp w) localBackend
            (object (["action" .= ("continue" :: Text)] <> fields)))
        onlySid rt = do
          insts <- listAgentsFor rt sampleSession
          case insts of
            [i] -> pure (aiSubagentId i)
            _   -> expectationFailure
                     ("expected exactly one instance, got " <> show (length insts))
                     >> pure (Del.SubagentId "sa-none-00000000")

    it "refuses an unknown subagent id with the pinned text" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pf <- newSpawnPauseFlag
      let w = mkLifecycleWiring backend rt pf (recordingWorker' "x") Nothing
      r <- continueOn w ["subagent_id" .= ("sa-nope-00000001" :: Text)]
      orIsError r `shouldBe` True
      resultText r `shouldBe`
        "continue: unknown subagent id \"sa-nope-00000001\". It was not spawned \
        \by this session, or was lost to a restart or to retention pruning. \
        \Start a new child."

    it "refuses another session's child and never echoes the owner" $ do
      backend <- noneBackend
      defineGreeter backend
      rt <- newAgentRuntime
      pf <- newSpawnPauseFlag
      let w = mkLifecycleWiring backend rt pf (recordingWorker' "done") Nothing
      _ <- spawnGreeter w
      finished <- pollUntil 2000 (any (isJust . aiResult) <$> listAgentsFor rt sampleSession)
      finished `shouldBe` True
      sid <- onlySid rt
      r <- continueOn w { aswParentSession = mkSystemSessionId "s2" }
             ["subagent_id" .= subagentIdText sid]
      orIsError r `shouldBe` True
      resultText r `shouldBe`
        "continue: that subagent belongs to a different session; a session may \
        \only continue the children it spawned."
      T.isInfixOf "s1" (resultText r) `shouldBe` False

    it "refuses while spawning is paused, with the shared pause text" $ do
      backend <- noneBackend
      defineGreeter backend
      rt <- newAgentRuntime
      pf <- newSpawnPauseFlag
      let w = mkLifecycleWiring backend rt pf (recordingWorker' "done") Nothing
      _ <- spawnGreeter w
      finished <- pollUntil 2000 (any (isJust . aiResult) <$> listAgentsFor rt sampleSession)
      finished `shouldBe` True
      sid <- onlySid rt
      _ <- setSpawnPaused pf True
      r <- continueOn w ["subagent_id" .= subagentIdText sid]
      _ <- setSpawnPaused pf False
      orIsError r `shouldBe` True
      resultText r `shouldBe` spawnPausedMsg

    it "refuses while the child is still running" $ do
      backend <- noneBackend
      defineGreeter backend
      rt <- newAgentRuntime
      pf <- newSpawnPauseFlag
      gate <- newEmptyMVar :: IO (MVar ())
      let w = mkLifecycleWiring backend rt pf (gatedWorker gate) Nothing
      _ <- spawnGreeter w
      registered <- pollUntil 2000 (not . null <$> listAgentsFor rt sampleSession)
      registered `shouldBe` True
      sid <- onlySid rt
      r <- continueOn w ["subagent_id" .= subagentIdText sid]
      orIsError r `shouldBe` True
      resultText r `shouldBe` ("continue: subagent " <> subagentIdText sid
        <> " is still running. Stop or interrupt it before continuing.")
      putMVar gate ()

    it "refuses when the child's session directory is gone" $
      withSystemTempDirectory "seal-continue" $ \root -> do
        let paths = scratchPaths root
        backend <- noneBackend
        defineGreeter backend
        rt <- newAgentRuntime
        pf <- newSpawnPauseFlag
        let w = mkLifecycleWiringAt paths backend rt pf (recordingWorker' "done") Nothing
        _ <- spawnGreeter w
        finished <- pollUntil 2000 (any (isJust . aiResult) <$> listAgentsFor rt sampleSession)
        finished `shouldBe` True
        sid <- onlySid rt
        r <- continueOn w ["subagent_id" .= subagentIdText sid]
        orIsError r `shouldBe` True
        resultText r `shouldBe` ("continue: subagent " <> subagentIdText sid
          <> " has no transcript on disk any more; start a new child.")

    it "foreground continue sends the prompt, returns the reply in-band, and does not wake" $
      withSystemTempDirectory "seal-continue" $ \root -> do
        let paths = scratchPaths root
        backend <- noneBackend
        defineGreeter backend
        rt <- newAgentRuntime
        pf <- newSpawnPauseFlag
        seen <- newIORef (Nothing :: Maybe Text)
        wakes <- newIORef (0 :: Int)
        let worker _ _ task _ = do
              writeIORef seen (Just (Del.ctGoal task))
              pure (ChildWorkerOutcome (Just "second answer") CerCompleted 0 0
                     (Just childSessionFixture))
            w = mkLifecycleWiringAt paths backend rt pf worker
                  (Just (void (atomicModifyIORef' wakes (\n -> (n + 1, n + 1)))))
        _ <- spawnGreeter w
        finished <- pollUntil 2000 (any (isJust . aiResult) <$> listAgentsFor rt sampleSession)
        finished `shouldBe` True
        -- the spawn's own completion already fired a wake; count the continue's
        writeIORef wakes 0
        seedChildDir paths sampleSession 8
        sid <- onlySid rt
        r <- continueOn w [ "subagent_id" .= subagentIdText sid
                          , "mode" .= ("foreground" :: Text)
                          , "prompt" .= ("the next step" :: Text) ]
        orIsError r `shouldBe` False
        let text = resultText r
        T.isInfixOf "replied (continue #2)" text `shouldBe` True
        T.isInfixOf "second answer" text `shouldBe` True
        T.isInfixOf continueHint text `shouldBe` True
        readIORef seen `shouldReturn` Just "the next step"
        -- in-band: no sidecar, no wake
        readIORef wakes `shouldReturn` 0
        settled <- agentStatusFor rt sampleSession sid
        case settled of
          Left e -> expectationFailure ("child vanished: " <> T.unpack e)
          Right i -> do
            aiRuns i `shouldBe` 2
            aiStatus i `shouldBe` Stopped
            aiOrigin i `shouldBe` SoContinueForeground

    it "sends the default nudge when the prompt is omitted" $
      withSystemTempDirectory "seal-continue" $ \root -> do
        let paths = scratchPaths root
        backend <- noneBackend
        defineGreeter backend
        rt <- newAgentRuntime
        pf <- newSpawnPauseFlag
        seen <- newIORef (Nothing :: Maybe Text)
        let worker _ _ task _ = do
              writeIORef seen (Just (Del.ctGoal task))
              pure (ChildWorkerOutcome (Just "ok") CerCompleted 0 0 (Just childSessionFixture))
            w = mkLifecycleWiringAt paths backend rt pf worker Nothing
        _ <- spawnGreeter w
        finished <- pollUntil 2000 (any (isJust . aiResult) <$> listAgentsFor rt sampleSession)
        finished `shouldBe` True
        seedChildDir paths sampleSession 8
        sid <- onlySid rt
        r <- continueOn w [ "subagent_id" .= subagentIdText sid
                          , "mode" .= ("foreground" :: Text) ]
        orIsError r `shouldBe` False
        readIORef seen `shouldReturn` Just continueNudge

    it "falls back to the stored goal when the conversation is empty" $
      withSystemTempDirectory "seal-continue" $ \root -> do
        let paths = scratchPaths root
        backend <- noneBackend
        defineGreeter backend
        rt <- newAgentRuntime
        pf <- newSpawnPauseFlag
        seen <- newIORef (Just ("not run" :: Text))
        let worker _ _ task _ = do
              writeIORef seen (Just (Del.ctGoal task))
              pure (ChildWorkerOutcome (Just "ok") CerCompleted 0 0 (Just childSessionFixture))
            w = mkLifecycleWiringAt paths backend rt pf worker Nothing
        _ <- spawnGreeter w
        finished <- pollUntil 2000 (any (isJust . aiResult) <$> listAgentsFor rt sampleSession)
        finished `shouldBe` True
        -- directory exists, conversation empty: the child was killed before its
        -- first request, so continuing it with a nudge would resume nothing
        seedChildDir paths sampleSession 0
        sid <- onlySid rt
        r <- continueOn w [ "subagent_id" .= subagentIdText sid
                          , "mode" .= ("foreground" :: Text) ]
        orIsError r `shouldBe` False
        readIORef seen `shouldReturn` Just "do the thing"

    it "refuses at the run budget and does not spend one on the refusal" $
      withSystemTempDirectory "seal-budget" $ \root -> do
        let paths = scratchPaths root
        backend <- noneBackend
        defineGreeter backend
        rt <- newAgentRuntime
        pf <- newSpawnPauseFlag
        let w = mkLifecycleWiringAt paths backend rt pf (recordingWorker' "ok") Nothing
        _ <- spawnGreeter w
        finished <- pollUntil 2000 (any (isJust . aiResult) <$> listAgentsFor rt sampleSession)
        finished `shouldBe` True
        seedChildDir paths sampleSession 8
        sid <- onlySid rt
        let continueOnce = continueOn w [ "subagent_id" .= subagentIdText sid
                                         , "mode" .= ("foreground" :: Text) ]
        -- runs 1 (the spawn) + 49 continues = the budget of 50
        allowed <- replicateM 49 continueOnce
        map orIsError allowed `shouldBe` replicate 49 False
        atCap <- agentStatusFor rt sampleSession sid
        case atCap of
          Left e -> expectationFailure ("child vanished: " <> T.unpack e)
          Right i -> aiRuns i `shouldBe` 50
        refused <- continueOnce
        orIsError refused `shouldBe` True
        resultText refused `shouldBe` ("continue: subagent " <> subagentIdText sid
          <> " has been continued 50 times; start a fresh child for new work.")
        -- the refusal consumed nothing
        still <- agentStatusFor rt sampleSession sid
        case still of
          Left _ -> pure ()
          Right i -> aiRuns i `shouldBe` 50

    it "registers a foreground-spawned child so it can be continued" $
      withSystemTempDirectory "seal-fg" $ \root -> do
        let paths = scratchPaths root
        backend <- noneBackend
        defineGreeter backend
        rt <- newAgentRuntime
        pf <- newSpawnPauseFlag
        runs <- newIORef (0 :: Int)
        let worker _ _ _ _ = do
              modifyIORef' runs (+ 1)
              pure (ChildWorkerOutcome (Just "fg reply") CerCompleted 0 0
                     (Just childSessionFixture))
            w = mkLifecycleWiringAt paths backend rt pf worker Nothing
        r0 <- runTestApp (opRun (agentStartOp w) localBackend
                (object [ "id" .= ("a1" :: Text), "goal" .= ("do the thing" :: Text)
                        , "mode" .= ("foreground" :: Text) ]))
        orIsError r0 `shouldBe` False
        readIORef runs `shouldReturn` 1
        insts <- listAgentsFor rt sampleSession
        case insts of
          [inst] -> do
            aiStatus inst `shouldBe` Stopped
            aiOrigin inst `shouldBe` SoStartForeground
            aiRuns inst `shouldBe` 1
            fmap adId (aiDef inst) `shouldBe` Just sampleDefId
            aiTask inst `shouldBe` Just (Del.ChildTask "a1" "do the thing" Nothing Nothing False)
            seedChildDir paths sampleSession 8
            r <- continueOn w [ "subagent_id" .= subagentIdText (aiSubagentId inst)
                              , "mode" .= ("foreground" :: Text) ]
            when (orIsError r) $
              expectationFailure ("continue refused: " <> T.unpack (resultText r))
            readIORef runs `shouldReturn` 2
            T.isInfixOf "replied (continue #2)" (resultText r) `shouldBe` True
          _ -> expectationFailure "expected exactly one registered child"

    it "background continue acks continued #2 and delivers the reply with one wake" $
      withSystemTempDirectory "seal-continue" $ \root -> do
        let paths = scratchPaths root
        backend <- noneBackend
        defineGreeter backend
        rt <- newAgentRuntime
        pf <- newSpawnPauseFlag
        wakes <- newIORef (0 :: Int)
        let w = mkLifecycleWiringAt paths backend rt pf (recordingWorker' "background reply")
                  (Just (void (atomicModifyIORef' wakes (\n -> (n + 1, n + 1)))))
        _ <- spawnGreeter w
        finished <- pollUntil 2000 (any (isJust . aiResult) <$> listAgentsFor rt sampleSession)
        finished `shouldBe` True
        writeIORef wakes 0
        seedChildDir paths sampleSession 8
        sid <- onlySid rt
        r <- continueOn w [ "subagent_id" .= subagentIdText sid ]
        when (orIsError r) $
          expectationFailure ("continue was refused: " <> T.unpack (resultText r))
        let text = resultText r
        T.isInfixOf "running (continued #2)" text `shouldBe` True
        T.isInfixOf "replied (continue #2)" text `shouldBe` True
        woke <- pollUntil 2000 ((== 1) <$> readIORef wakes)
        woke `shouldBe` True

  describe "runChildTask (one child-run core)" $ do
    let mkTask = Del.ChildTask "a1" "do the thing" Nothing Nothing False
        sid = Del.SubagentId "sa-a1-00000001"
        childSid = mkSystemSessionId "child"
    it "returns the worker's outcome with the caller's index and identity" $ do
      start <- getCurrentTime
      result <- runChildTask Nothing 5 start 4 sid childSid sampleAgentDef
                  (recordingWorker' "core done") mkTask
      crTaskIndex result `shouldBe` 4
      crSubagentId result `shouldBe` sid
      crStatus result `shouldBe` CsCompleted
      crSummary result `shouldBe` Just "core done"
      crExitReason result `shouldBe` CerCompleted
      crChildSession result `shouldBe` Just childSid

    it "aggregates the tool trace, files and tokens the worker recorded" $ do
      start <- getCurrentTime
      let tracingWorker _def _child _task hooks = do
            atomicModifyIORef' (crhToolTrace hooks) $ \ts ->
              (ToolTraceEntry "SHELL_EXEC" 10 20 False : ts, ())
            atomicModifyIORef' (crhFilesRead hooks) $ \fs -> ("src/a.hs" : fs, ())
            atomicModifyIORef' (crhFilesWritten hooks) $ \fs -> ("src/b.hs" : fs, ())
            pure (ChildWorkerOutcome (Just "traced") CerCompleted 3 4 (Just childSid))
      result <- runChildTask Nothing 5 start 0 sid childSid sampleAgentDef
                  tracingWorker mkTask
      crToolTrace result `shouldBe` [ToolTraceEntry "SHELL_EXEC" 10 20 False]
      crFilesRead result `shouldBe` ["src/a.hs"]
      crFilesWritten result `shouldBe` ["src/b.hs"]
      crTokensInput result `shouldBe` 3
      crTokensOutput result `shouldBe` 4

    it "turns a worker exception into CsError, keeping the child session" $ do
      start <- getCurrentTime
      let crashingWorker _ _ _ _ = ioError (userError "boom")
      result <- runChildTask Nothing 5 start 0 sid childSid sampleAgentDef
                  crashingWorker mkTask
      crStatus result `shouldBe` CsError
      crExitReason result `shouldBe` CerError
      -- The exception text lands in the summary (the rendering path the
      -- parent already sees for a crashed child).
      crSummary result `shouldSatisfy` maybe False (T.isInfixOf "boom")
      crChildSession result `shouldBe` Just childSid

    it "returns CsTimeout carrying the child session when the worker overruns" $ do
      start <- getCurrentTime
      result <- runChildTask Nothing 0.05 start 0 sid childSid sampleAgentDef
                  (sleepingWorker 0.3) mkTask
      crStatus result `shouldBe` CsTimeout
      crExitReason result `shouldBe` CerTimeout
      crChildSession result `shouldBe` Just childSid
      crDurationSeconds result `shouldSatisfy` (>= 0.05)

    -- A real foreground timeout cannot be run in-suite: 'resolveDelegationConfig'
    -- floors child_timeout_seconds at 30 s, so 'runDelegate' can only time out
    -- after half a minute. The assertion therefore sits on the shared core that
    -- now produces the foreground result, plus the foreground renderer.
    it "a timeout result renders child_session (the foreground renderer's shape)" $ do
      start <- getCurrentTime
      result <- runChildTask Nothing 0.05 start 0 sid childSid sampleAgentDef
                  (sleepingWorker 0.3) mkTask
      T.isInfixOf "child_session=child" (encodeForegroundResults [result])
        `shouldBe` True

  describe "spawn callback (run lifecycle through the opcode)" $ do
    it "registers the child with a live worker handle and its task snapshot" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      gate <- newEmptyMVar :: IO (MVar ())
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object [ "id" .= ("a1" :: Text), "name" .= ("g" :: Text)
                                     , "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text) ]))
      let wiring = AgentStartWiring
            { aswDefBackend = backend
            , aswRuntime = rt
            , aswConfig = pure defaultDelegationConfig
            , aswPauseFlag = pauseFlag
            , aswParentActivity = Nothing
            , aswMintSession = pure (mkSystemSessionId "fresh")
            , aswParentDepth = 0
            , aswWorker = gatedWorker gate
            , aswGate = gateOpen
            , aswPaths = samplePaths
            , aswParentSession = sampleSession
            , aswRunRecords = Nothing
            , aswOnIdleCompletion = Nothing
            }
      r <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["id" .= ("a1" :: Text), "goal" .= ("do the thing" :: Text)]))
      case orParts r of
        [TrpText t] -> T.isInfixOf "running" t `shouldBe` True
        _           -> expectationFailure "expected a single text part"
      -- The child is registered while it is still inside the run body, with a
      -- live control handle ('aiWorkerThread') and the spawn snapshot that
      -- makes it resumable.
      let hasInstance = not . null <$> listAgentsFor rt sampleSession
      registered <- pollUntil 2000 hasInstance
      registered `shouldBe` True
      insts <- listAgentsFor rt sampleSession
      case insts of
        [inst] -> do
          aiStatus inst `shouldBe` Running
          aiWorkerThread inst `shouldSatisfy` isJust
          aiTask inst `shouldBe` Just (Del.ChildTask "a1" "do the thing" Nothing Nothing False)
          fmap adId (aiDef inst) `shouldBe` Just sampleDefId
        _ -> expectationFailure ("expected exactly one instance, got " <> show (length insts))
      -- Release the child; it completes and the run's own thread clears the
      -- handle BEFORE reporting, so a completed child is continuable at once.
      putMVar gate ()
      let hasResult = any (isJust . aiResult) <$> listAgentsFor rt sampleSession
      reported <- pollUntil 2000 hasResult
      reported `shouldBe` True
      finished <- listAgentsFor rt sampleSession
      case finished of
        [inst] -> do
          aiStatus inst `shouldBe` Stopped
          aiWorkerThread inst `shouldBe` Nothing
        _ -> expectationFailure "expected exactly one instance"

    it "reports no completion when the spawn callback throws (killed before the body)" $ do
      pauseFlag <- newSpawnPauseFlag
      entered <- newIORef (0 :: Int)
      completed <- newIORef (0 :: Int)
      let cfg = defaultDelegationConfig
          callback _ = void (atomicModifyIORef' completed (\n -> (n + 1, n + 1)))
          killedSpawnCb _ _ _ _ _body = do
            void (atomicModifyIORef' entered (\n -> (n + 1, n + 1)))
            throwIO ThreadKilled
          resolver _task = pure (Right (undefined, recordingWorker' "done"))
      _ <- runDelegateAsync cfg pauseFlag Nothing 0
             (DiSingle (Del.ChildTask "a1" "do the thing" Nothing Nothing False))
             resolver callback killedSpawnCb (pure (mkSystemSessionId "child"))
      -- The callback ran, and its failure produced no completion.
      ran <- pollUntil 2000 ((== 1) <$> readIORef entered)
      ran `shouldBe` True
      threadDelay 100000
      readIORef completed `shouldReturn` 0

    it "stopping a child that is still queued for the cap reports no result" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      gate <- newEmptyMVar :: IO (MVar ())
      mintCount <- newIORef (0 :: Int)
      enteredBodies <- newIORef ([] :: [SessionId])
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object [ "id" .= ("a1" :: Text), "name" .= ("g" :: Text)
                                     , "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text) ]))
      let wiring = AgentStartWiring
            { aswDefBackend = backend
            , aswRuntime = rt
            -- One slot: the second child is registered but held in the
            -- semaphore's acquire, i.e. it is killed before its body starts.
            , aswConfig = pure defaultDelegationConfig { dcMaxConcurrentChildren = Just 1 }
            , aswPauseFlag = pauseFlag
            , aswParentActivity = Nothing
            , aswMintSession = do
                n <- atomicModifyIORef' mintCount (\k -> (k + 1, k + 1))
                pure (mkSystemSessionId ("c" <> T.pack (show n)))
            , aswParentDepth = 0
            , aswWorker = \_def childSid _task _hooks -> do
                void (atomicModifyIORef' enteredBodies (\ss -> (ss <> [childSid], ())))
                takeMVar gate
                pure (ChildWorkerOutcome (Just "released") CerCompleted 0 0 (Just childSid))
            , aswGate = gateOpen
            , aswPaths = samplePaths
            , aswParentSession = sampleSession
            , aswRunRecords = Nothing
            , aswOnIdleCompletion = Nothing
            }
      r <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["tasks" .=
                              [ object ["id" .= ("a1" :: Text), "goal" .= ("one" :: Text)]
                              , object ["id" .= ("a1" :: Text), "goal" .= ("two" :: Text)]
                              ]]))
      orIsError r `shouldBe` False
      bothRegistered <- pollUntil 2000 ((== 2) . length <$> listAgentsFor rt sampleSession)
      bothRegistered `shouldBe` True
      oneRunning <- pollUntil 2000 ((== 1) . length <$> readIORef enteredBodies)
      oneRunning `shouldBe` True
      -- The child that never entered its body is the one held by the cap.
      startedSids <- readIORef enteredBodies
      insts <- listAgentsFor rt sampleSession
      case filter (\i -> aiSession i `notElem` startedSids) insts of
        [queued] -> do
          stopR <- runTestApp (opRun (agentStopOp sampleSession rt) localBackend
                                 (object ["subagent_id" .= subagentIdText (aiSubagentId queued)]))
          orIsError stopR `shouldBe` False
          -- The dying run must not fabricate a result: before the fix it went
          -- through the completion callback, which flips the retained entry to
          -- 'Crashed' and stores an error 'ChildResult' in aiResult.
          threadDelay 200000
          afterStop <- agentStatusFor rt sampleSession (aiSubagentId queued)
          case afterStop of
            Left e -> expectationFailure ("queued child vanished: " <> T.unpack e)
            Right inst -> do
              aiStatus inst `shouldBe` Stopped
              aiResult inst `shouldBe` Nothing
              aiWorkerThread inst `shouldBe` Nothing
        other -> expectationFailure
                   ("expected exactly one queued child, got " <> show (length other))
      -- Release the running child so the suite finishes cleanly.
      putMVar gate ()
      done <- pollUntil 2000 $
                any (\i -> case aiResult i of { Just _ -> True; Nothing -> False })
                  <$> listAgentsFor rt sampleSession
      done `shouldBe` True

  describe "spawnPausedMsg" $ do
    it "is the single source of the pause refusal, shared by both runners" $ do
      pauseFlag <- newSpawnPauseFlag
      _ <- setSpawnPaused pauseFlag True
      let cfg = defaultDelegationConfig
          resolver _task = pure (Left "unused: the pause check runs first")
          input = DiSingle (Del.ChildTask "a1" "do the thing" Nothing Nothing False)
      eSync <- runDelegate cfg pauseFlag Nothing 0 input resolver
      eAsync <- runDelegateAsync cfg pauseFlag Nothing 0 input resolver
                  (const (pure ()))
                  (\_ _ _ _ body -> body)
                  (pure (mkSystemSessionId "child"))
      _ <- setSpawnPaused pauseFlag False
      eSync `shouldBe` Left spawnPausedMsg
      eAsync `shouldBe` Left spawnPausedMsg

  describe "runDelegateAsync (async core)" $ do
    it "returns immediately with SpawnInfo (does not block on worker completion)" $ do
      pauseFlag <- newSpawnPauseFlag
      ran <- newIORef (0 :: Int)
      resultMVar <- newEmptyMVar :: IO (MVar ChildResult)
      let cfg = defaultDelegationConfig
          callback = putMVar resultMVar
          resolver _task = pure (Right ( undefined
                                        , recordingWorker ran))
          input = DiSingle (Del.ChildTask "a1" "do the thing" Nothing Nothing False)
      eResult <- runDelegateAsync cfg pauseFlag Nothing 0 input resolver callback (\_ _ _ _ body -> body) (pure (mkSystemSessionId "child"))
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
                                        , recordingWorker ran))
          input = DiSingle (Del.ChildTask "a1" "do the thing" Nothing Nothing False)
      _ <- runDelegateAsync cfg pauseFlag Nothing 0 input resolver callback (\_ _ _ _ body -> body) (pure (mkSystemSessionId "child"))
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
          input = DiSingle (Del.ChildTask "nope" "do the thing" Nothing Nothing False)
      _ <- runDelegateAsync cfg pauseFlag Nothing 0 input resolver callback (\_ _ _ _ body -> body) (pure (mkSystemSessionId "child"))
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
          resolver _task = pure (Right (undefined, crashingWorker))
          input = DiSingle (Del.ChildTask "a1" "do the thing" Nothing Nothing False)
      _ <- runDelegateAsync cfg pauseFlag Nothing 0 input resolver callback (\_ _ _ _ body -> body) (pure (mkSystemSessionId "child"))
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
          resolver _task = pure (Right (undefined, slowWorker))
          input = DiSingle (Del.ChildTask "a1" "do the thing" Nothing Nothing False)
      _ <- runDelegateAsync cfg pauseFlag Nothing 0 input resolver callback (\_ _ _ _ body -> body) (pure (mkSystemSessionId "child"))
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
          resolver _task = pure (Right (undefined, dummyWorker))
          input = DiSingle (Del.ChildTask "a1" "do the thing" Nothing Nothing False)
      eResult <- runDelegateAsync cfg pauseFlag Nothing 0 input resolver callback (\_ _ _ _ body -> body) (pure (mkSystemSessionId "child"))
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
          mkTask i = Del.ChildTask "a1" ("task " <> T.pack (show i)) Nothing Nothing False
          tasks = [mkTask i | i <- [1..5 :: Int]]
          input = DiBatch tasks
          resolver _task = pure (Right (undefined, concurrencyTrackingWorker concurrencyState))
      _ <- runDelegateAsync cfg pauseFlag Nothing 0 input resolver callback (\_ _ _ _ body -> body) (pure (mkSystemSessionId "child"))
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
      _ <- startAgent rt sampleDefId sid (mkSystemSessionId "parent") childSid 0 (pure ())
      -- Then register the completed result
      registerCompletedAgentResult rt sid result
      rInst <- agentStatusFor rt (mkSystemSessionId "parent") sid
      case rInst of
        Right inst -> do
          aiStatus inst `shouldBe` Stopped
          aiResult inst `shouldBe` Just result
        Left e -> expectationFailure ("instance not found in registry: " <> T.unpack e)

    it "spawn callback receives the task, and its result reaches the completion callback" $ do
      pauseFlag <- newSpawnPauseFlag
      resultMVar <- newEmptyMVar :: IO (MVar ChildResult)
      captured <- newIORef (Nothing :: Maybe (Del.SubagentId, Del.ChildTask))
      let cfg = defaultDelegationConfig
          task = Del.ChildTask "a1" "do the thing" Nothing Nothing False
          callback = putMVar resultMVar
          resolver _task = pure (Right (undefined, recordingWorker' "done"))
          spawnCb sid _def _childSid t body = do
            writeIORef captured (Just (sid, t))
            body
      eSpawn <- runDelegateAsync cfg pauseFlag Nothing 0 (DiSingle task) resolver
                  callback spawnCb (pure (mkSystemSessionId "child"))
      result <- takeMVar resultMVar
      crSummary result `shouldBe` Just "done"
      mCaptured <- readIORef captured
      case (eSpawn, mCaptured) of
        (Right [info], Just (sid, t)) -> do
          sid `shouldBe` siSubagentId info
          t `shouldBe` task
        (Right _, Nothing) -> expectationFailure "the spawn callback never ran"
        _ -> expectationFailure "expected exactly one SpawnInfo"

    it "spawn callback runs first, then the child body, then the completion callback" $ do
      pauseFlag <- newSpawnPauseFlag
      order <- newIORef ([] :: [Text])
      done <- newEmptyMVar :: IO (MVar ())
      let cfg = defaultDelegationConfig
          note t = atomicModifyIORef' order (\ts -> (ts <> [t], ()))
          callback _ = do note "completion"; putMVar done ()
          spawnCb _ _ _ _ body = do note "spawn"; body
          worker _ _ _ _ = do
            note "body"
            pure (ChildWorkerOutcome (Just "done") CerCompleted 0 0 Nothing)
          resolver _task = pure (Right (undefined, worker))
      _ <- runDelegateAsync cfg pauseFlag Nothing 0
             (DiSingle (Del.ChildTask "a1" "do the thing" Nothing Nothing False))
             resolver callback spawnCb (pure (mkSystemSessionId "child"))
      takeMVar done
      readIORef order `shouldReturn` ["spawn", "body", "completion"]

    it "a child queued behind the concurrency cap is registered before it waits" $ do
      pauseFlag <- newSpawnPauseFlag
      registered <- newIORef (0 :: Int)
      completed <- newIORef (0 :: Int)
      gate <- newEmptyMVar :: IO (MVar ())
      let cfg = defaultDelegationConfig
          mkTask i = Del.ChildTask "a1" ("task " <> T.pack (show i)) Nothing Nothing False
          tasks = [mkTask i | i <- [1 .. 5 :: Int]]
          resolver _task = pure (Right (undefined, gatedWorker gate))
          callback _ = void (atomicModifyIORef' completed (\n -> (n + 1, n + 1)))
          spawnCb _ _ _ _ body = do
            void (atomicModifyIORef' registered (\n -> (n + 1, n + 1)))
            body
      eSpawn <- runDelegateAsync cfg pauseFlag Nothing 0 (DiBatch tasks) resolver
                  callback spawnCb (pure (mkSystemSessionId "child"))
      case eSpawn of
        Left err -> expectationFailure ("expected Right but got Left: " <> T.unpack err)
        Right infos -> length infos `shouldBe` 5
      -- max_concurrent_children is 3, yet all five children register
      -- immediately: registration must not wait behind the cap.
      allRegistered <- pollUntil 2000 ((== 5) <$> readIORef registered)
      allRegistered `shouldBe` True
      readIORef completed `shouldReturn` 0
      -- Release every child; the two that were queued acquire the slots the
      -- first three release.
      replicateM_ 5 (putMVar gate ())
      allDone <- pollUntil 5000 ((== 5) <$> readIORef completed)
      allDone `shouldBe` True

  describe "runDelegate (foreground/sync core)" $ do
    it "returns ChildResult with completed status for a successful worker" $ do
      pauseFlag <- newSpawnPauseFlag
      let cfg = defaultDelegationConfig
          resolver _task = pure (Right ( undefined
                                        , recordingWorker' "foreground done"
                                        , mkSystemSessionId "child"))
          input = DiSingle (Del.ChildTask "a1" "do the thing" Nothing Nothing False)
      eResult <- runDelegate cfg pauseFlag Nothing 0 input resolver
      case eResult of
        Left err -> expectationFailure ("expected Right but got Left: " <> T.unpack err)
        Right [result] -> do
          crStatus result `shouldBe` CsCompleted
          crSummary result `shouldBe` Just "foreground done"
          crExitReason result `shouldBe` CerCompleted
        Right _ -> expectationFailure "expected exactly one result"

    it "returns ChildResult with error status for a crashing worker" $ do
      pauseFlag <- newSpawnPauseFlag
      let cfg = defaultDelegationConfig
          crashingWorker :: Del.AgentWorkerBuilder
          crashingWorker _ _ _ _ = pure (ChildWorkerOutcome (Just "fail") CerError 0 0 Nothing)
          resolver _task = pure (Right (undefined, crashingWorker, mkSystemSessionId "child"))
          input = DiSingle (Del.ChildTask "a1" "do the thing" Nothing Nothing False)
      eResult <- runDelegate cfg pauseFlag Nothing 0 input resolver
      case eResult of
        Right [result] -> crStatus result `shouldBe` CsError
        _ -> expectationFailure "expected Right with one error result"

    it "batch foreground mode returns results for all children" $ do
      pauseFlag <- newSpawnPauseFlag
      let cfg = defaultDelegationConfig { dcChildTimeoutSeconds = Just 30 }
          mkTask i = Del.ChildTask "a1" ("task " <> T.pack (show i)) Nothing Nothing False
          tasks = [mkTask i | i <- [1..3 :: Int]]
          input = DiBatch tasks
          resolver _task = pure (Right ( undefined
                                        , recordingWorker' "done"
                                        , mkSystemSessionId "child"))
      eResult <- runDelegate cfg pauseFlag Nothing 0 input resolver
      case eResult of
        Right results -> length results `shouldBe` 3
        Left err -> expectationFailure ("expected Right but got Left: " <> T.unpack err)

    it "resolve error returns CsError" $ do
      pauseFlag <- newSpawnPauseFlag
      let cfg = defaultDelegationConfig
          resolver _task = pure (Left "agent def not found: nope")
          input = DiSingle (Del.ChildTask "nope" "do the thing" Nothing Nothing False)
      eResult <- runDelegate cfg pauseFlag Nothing 0 input resolver
      case eResult of
        Right [result] -> do
          crStatus result `shouldBe` CsError
          crError result `shouldBe` Just "agent def not found: nope"
        _ -> expectationFailure "expected Right with one error result"

  describe "parseSpawnMode" $ do
    it "defaults to background when mode field is absent" $ do
      parseSpawnMode (object ["action" .= ("start" :: Text)])
        `shouldBe` SpawnModeBackground
    it "parses foreground mode" $ do
      parseSpawnMode (object ["action" .= ("start" :: Text), "mode" .= ("foreground" :: Text)])
        `shouldBe` SpawnModeForeground
    it "parses background mode explicitly" $ do
      parseSpawnMode (object ["action" .= ("start" :: Text), "mode" .= ("background" :: Text)])
        `shouldBe` SpawnModeBackground
    it "defaults to background for unrecognized mode" $ do
      parseSpawnMode (object ["action" .= ("start" :: Text), "mode" .= ("bogus" :: Text)])
        `shouldBe` SpawnModeBackground

  describe "outcome vocabulary (one dialect)" $ do
    let mkResult st ex summary err = ChildResult
          { crTaskIndex = 0
          , crStatus = st
          , crSummary = summary
          , crExitReason = ex
          , crDurationSeconds = 1.0
          , crSubagentId = Del.SubagentId "sa-a1-00000001"
          , crTokensInput = 0
          , crTokensOutput = 0
          , crToolTrace = []
          , crError = err
          , crFilesRead = []
          , crFilesWritten = []
          , crChildSession = Just (mkSystemSessionId "child")
          }

    it "pins the status= and exit= tokens for every constructor" $ do
      map renderChildStatus [CsCompleted, CsFailed, CsTimeout, CsInterrupted, CsError]
        `shouldBe` ["completed", "failed", "timeout", "interrupted", "error"]
      map renderChildExit [CerCompleted, CerMaxIterations, CerTimeout, CerInterrupted, CerError]
        `shouldBe` ["completed", "max_iterations", "timeout", "interrupted", "error"]

    it "never leaks a Haskell constructor name" $ do
      let text = completionMessage (mkResult CsFailed CerMaxIterations Nothing Nothing)
      T.isInfixOf "CsFailed" text `shouldBe` False
      T.isInfixOf "CerMaxIterations" text `shouldBe` False
      T.isInfixOf "status=failed" text `shouldBe` True
      T.isInfixOf "exit=max_iterations" text `shouldBe` True

    it "falls back summary -> crError -> placeholder" $ do
      let withSummary = completionMessage (mkResult CsCompleted CerCompleted (Just "the answer") Nothing)
          withError = completionMessage (mkResult CsError CerError Nothing (Just "provider refused"))
          withNeither = completionMessage (mkResult CsFailed CerMaxIterations Nothing Nothing)
      T.isInfixOf "the answer" withSummary `shouldBe` True
      T.isInfixOf "provider refused" withError `shouldBe` True
      T.isInfixOf "(no final text from the child)" withNeither `shouldBe` True

    it "adds the timeout clause only for status=timeout" $ do
      let timedOut = completionMessage (mkResult CsTimeout CerTimeout Nothing Nothing)
          completed = completionMessage (mkResult CsCompleted CerCompleted (Just "ok") Nothing)
      T.isInfixOf timeoutContinuationClause timedOut `shouldBe` True
      T.isInfixOf timeoutContinuationClause completed `shouldBe` False

    it "uses the request-scoped NO_REPLY clause, not the conversation-scoped one" $ do
      let text = completionMessage (mkResult CsCompleted CerCompleted (Just "ok") Nothing)
      T.isInfixOf noReplyClause text `shouldBe` True
      T.isInfixOf "If you have already sent your final answer" text `shouldBe` False

  describe "encodeForegroundResults" $ do
    it "renders a completed result with status and summary" $ do
      let result = ChildResult
            { crTaskIndex = 0
            , crStatus = CsCompleted
            , crSummary = Just "task completed successfully"
            , crExitReason = CerCompleted
            , crDurationSeconds = 1.5
            , crSubagentId = Del.SubagentId "sa-a1-00000001"
            , crTokensInput = 100
            , crTokensOutput = 50
            , crToolTrace = []
            , crError = Nothing
            , crFilesRead = []
            , crFilesWritten = []
            , crChildSession = Just (mkSystemSessionId "child")
            }
          text = encodeForegroundResults [result]
      T.isInfixOf "sa-a1-00000001" text `shouldBe` True
      T.isInfixOf "status=completed" text `shouldBe` True
      T.isInfixOf "child_session=child" text `shouldBe` True
      T.isInfixOf "task completed successfully" text `shouldBe` True
      -- a foreground-spawned child is retained, so the reply says how to resume
      T.isInfixOf continueHint text `shouldBe` True
    it "renders empty list as no children" $ do
      encodeForegroundResults [] `shouldBe` "(no children spawned)"

  describe "adAllowSpawn enforcement (authorizeStart gate)" $ do
    let mkGate role orchEnabled allow = AgentStartGate
          { gEffectiveRole = role
          , gOrchEnabled = orchEnabled
          , gAllowSpawn = allow
          }
        mkWiring gate = AgentStartWiring
          { aswDefBackend = error "unused by authorize"
          , aswRuntime = error "unused by authorize"
          , aswConfig = error "unused by authorize"
          , aswPauseFlag = error "unused by authorize"
          , aswParentActivity = Nothing
          , aswMintSession = error "unused by authorize"
          , aswParentDepth = 0
          , aswWorker = error "unused by authorize"
          , aswGate = gate
          , aswPaths = samplePaths
          , aswParentSession = sampleSession
            , aswRunRecords = Nothing
            , aswOnIdleCompletion = Nothing
          }
        validInput = object ["id" .= ("a1" :: Text), "goal" .= ("g" :: Text)]
        auth gate = authorizeStart (mkWiring gate) validInput

    it "Nothing + orchestrator role + switch on ⇒ allowed" $
      auth (mkGate (Just "orchestrator") True Nothing) `shouldBe` Right ()
    it "Nothing + leaf role ⇒ leafMsg" $
      auth (mkGate (Just "leaf") True Nothing) `shouldBe` Left leafMsg
    it "Nothing + orchestrator role + switch off ⇒ killSwitchMsg" $
      auth (mkGate (Just "orchestrator") False Nothing) `shouldBe` Left killSwitchMsg
    it "Just False blocks an orchestrator even with switch on ⇒ allowSpawnBlockedMsg" $
      auth (mkGate (Just "orchestrator") True (Just False)) `shouldBe` Left allowSpawnBlockedMsg
    it "Just True allows a leaf role (escape hatch) ⇒ allowed" $
      auth (mkGate (Just "leaf") True (Just True)) `shouldBe` Right ()
    it "Just False takes precedence over switch-off (most-specific message)" $
      auth (mkGate (Just "orchestrator") False (Just False)) `shouldBe` Left allowSpawnBlockedMsg
    it "Just True takes precedence over switch-off (override wins) ⇒ allowed" $
      auth (mkGate (Just "orchestrator") False (Just True)) `shouldBe` Right ()
    it "Just True takes precedence over leaf role ⇒ allowed" $
      auth (mkGate (Just "leaf") False (Just True)) `shouldBe` Right ()

  describe "encodeSpawnInfos — anti-polling text" $ do
    it "includes the anti-polling instruction for background spawns" $ do
      let si = Del.SpawnInfo
            { Del.siSubagentId = Del.SubagentId "sa-a1-00000001"
            , Del.siChildSession = mkSystemSessionId "child"
            , Del.siTaskIndex = 0
            }
          text = encodeSpawnInfos [si]
      ("do NOT call AGENT_MANAGE status" `T.isInfixOf` text) `shouldBe` True
      ("NO_REPLY" `T.isInfixOf` text) `shouldBe` True
      ("ALL expected completions" `T.isInfixOf` text) `shouldBe` True
    it "renders the empty list without the anti-polling block" $ do
      encodeSpawnInfos [] `shouldBe` "(no children spawned)"

  describe "completionMessage — anti-polling text" $ do
    let mkResult = ChildResult
          { crTaskIndex = 0
          , crStatus = CsCompleted
          , crSummary = Just "done"
          , crExitReason = CerCompleted
          , crDurationSeconds = 1.0
          , crSubagentId = Del.SubagentId "sa-a1-00000001"
          , crTokensInput = 0
          , crTokensOutput = 0
          , crToolTrace = []
          , crError = Nothing
          , crFilesRead = []
          , crFilesWritten = []
          , crChildSession = Just (mkSystemSessionId "child")
          }
    it "includes the request-scoped NO_REPLY instruction" $ do
      let text = completionMessage mkResult
      ("NO_REPLY" `T.isInfixOf` text) `shouldBe` True
      (noReplyClause `T.isInfixOf` text) `shouldBe` True
    it "includes the subagent id and the pinned status vocabulary" $ do
      let text = completionMessage mkResult
      ("sa-a1-00000001" `T.isInfixOf` text) `shouldBe` True
      ("status=completed" `T.isInfixOf` text) `shouldBe` True

  describe "secret discipline" $
    it "orRecorded carries the def fields (agent-visible data, recorded in full, not a vault secret)" $ do
      backend <- noneBackend
      let op = agentDefWriteOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("p" :: Text), "model" .= ("m" :: Text), "system" .= ("not-a-secret" :: Text)]))
      let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
      T.isInfixOf "not-a-secret" recorded `shouldBe` True

