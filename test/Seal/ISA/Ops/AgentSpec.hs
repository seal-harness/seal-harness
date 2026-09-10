{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.AgentSpec (spec) where

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
  ( ChildExitReason (..), ChildWorkerOutcome (..)
  , defaultDelegationConfig, dcChildTimeoutSeconds
  , newSpawnPauseFlag, setSpawnPaused )
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
            }
      r <- runTestApp (opRun (agentStartOp wiring) localBackend
                            (object ["tasks" .= [ object ["id" .= ("a1" :: Text), "goal" .= ("task one" :: Text)]
                                                , object ["id" .= ("a1" :: Text), "goal" .= ("task two" :: Text)] ]]))
      orIsError r `shouldBe` False
      -- Both tasks ran (batch mode fans out).
      readIORef ran `shouldReturn` 2

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

  describe "secret discipline" $
    it "orRecorded carries the def fields (agent-visible data, recorded in full, not a vault secret)" $ do
      backend <- noneBackend
      let op = agentDefWriteOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("p" :: Text), "model" .= ("m" :: Text), "system" .= ("not-a-secret" :: Text)]))
      let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
      T.isInfixOf "not-a-secret" recorded `shouldBe` True