{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.AgentSpec (spec) where

import Control.Concurrent (threadDelay)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec

import Seal.Agent.Def.Backend
import Seal.Agent.Def.Types (AgentDef (..), AgentDefId (..), mkAgentDefId)
import Seal.Agent.Runtime.Registry
import Seal.Core.Types (SessionId (..))
import Seal.ISA.Opcode
import Seal.ISA.Ops.Agent
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Types.App (App, runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)

runTestApp :: App a -> IO a
runTestApp act = do env <- mkEnv defaultConfig; runApp env act

sampleSession :: SessionId
sampleSession = SessionId "s1"

sampleDefId :: AgentDefId
sampleDefId = case mkAgentDefId "a1" of
  Right aid -> aid
  Left _    -> AgentDefId "fallback"

-- | A worker that records it ran, then blocks so the instance stays Running
-- for status assertions. The test stops the agent before the delay elapses.
blockingWorker :: IORef Int -> AgentDef -> SessionId -> IO ()
blockingWorker ref _ _ = do
  modifyIORef' ref (+ 1)
  threadDelay 1000000

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

    it "updates an existing def and returns 'updated' with was_new=false (preserves provenance)" $ do
      backend <- noneBackend
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("old" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      let op = agentDefWriteOp backend (SessionId "s2")
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

  describe "AGENT_START / STATUS / INSTANCES / STOP" $ do
    it "starts an agent, status Running, then stops it" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      ran <- newIORef (0 :: Int)
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      let start = agentStartOp backend rt (pure (SessionId "fresh")) (blockingWorker ran)
      rStart <- runTestApp (opRun start localBackend (object ["id" .= ("a1" :: Text)]))
      orIsError rStart `shouldBe` False
      threadDelay 50000
      readIORef ran `shouldReturn` 1
      mStatus <- agentStatus rt sampleDefId
      mStatus `shouldSatisfy` (Just Running ==)
      let stop = agentStopOp rt
      rStop <- runTestApp (opRun stop localBackend (object ["id" .= ("a1" :: Text)]))
      orIsError rStop `shouldBe` False
      agentStatus rt sampleDefId `shouldReturn` Nothing

    it "AGENT_START errors when the def does not exist" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      let start = agentStartOp backend rt (pure (SessionId "fresh")) (\_ _ -> pure ())
      r <- runTestApp (opRun start localBackend (object ["id" .= ("nope" :: Text)]))
      orIsError r `shouldBe` True

    it "AGENT_INSTANCES reports running instances" $ do
      backend <- noneBackend
      rt <- newAgentRuntime
      _ <- runTestApp (opRun (agentDefWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("ollama" :: Text), "model" .= ("llama3" :: Text)]))
      let worker _ _ = threadDelay 1000000
          start = agentStartOp backend rt (pure (SessionId "fresh")) worker
      _ <- runTestApp (opRun start localBackend (object ["id" .= ("a1" :: Text)]))
      threadDelay 50000
      r <- runTestApp (opRun (agentInstancesOp rt) localBackend (object []))
      case orParts r of
        [TrpText t] -> T.isInfixOf "a1:" t `shouldBe` True
        _           -> expectationFailure "expected a single text part"
      _ <- stopAgent rt sampleDefId
      pure ()

    it "AGENT_STATUS reports not running when absent" $ do
      rt <- newAgentRuntime
      r <- runTestApp (opRun (agentStatusOp rt) localBackend (object ["id" .= ("a1" :: Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> t `shouldBe` "not running"
        _           -> expectationFailure "expected a single text part"

    it "AGENT_STOP is idempotent on a non-running def id" $ do
      rt <- newAgentRuntime
      r <- runTestApp (opRun (agentStopOp rt) localBackend (object ["id" .= ("nope" :: Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> t `shouldBe` "stopped"
        _           -> expectationFailure "expected a single text part"

  describe "secret discipline" $
    it "orRecorded carries the def fields (agent-visible data, recorded in full, not a vault secret)" $ do
      backend <- noneBackend
      let op = agentDefWriteOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["id" .= ("a1" :: Text), "name" .= ("g" :: Text), "provider" .= ("p" :: Text), "model" .= ("m" :: Text), "system" .= ("not-a-secret" :: Text)]))
      let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
      T.isInfixOf "not-a-secret" recorded `shouldBe` True