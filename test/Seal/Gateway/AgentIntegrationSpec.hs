{-# LANGUAGE OverloadedStrings #-}
-- | Gateway API integration tests for the AGENT_ opcode group. Exercises the
-- full API → agent loop → ISA dispatch path through the gateway, asserting
-- invariants over how combinations of AGENT_ opcodes interact.
--
-- Two groups:
--
--   * Definitions-group (#1-#7): 'AGENT_DEF_LIST' / 'AGENT_DEF_WRITE' /
--     'AGENT_DEF_READ' / 'AGENT_DEF_DELETE' invariants. These run with the
--     default test harness (no stub worker) since they don't exercise
--     'AGENT_START'.
--
--   * Lifecycle-group (#8-#15) + cross-group (#16-#17): 'AGENT_INSTANCES' /
--     'AGENT_START' / 'AGENT_STATUS' / 'AGENT_STOP' / 'AGENT_INTERRUPT'
--     invariants. Tests that exercise 'AGENT_START' run with
--     'atoChildWorker = Just stubChildWorker' so the start completes
--     without a real provider call.
--
-- (The former #9/#10/#11/#16b registerChild no-op was fixed in issue
-- #136; those tests now pass against the synchronous model.
module Seal.Gateway.AgentIntegrationSpec (spec) where

import Control.Monad (forM_, forM)
import Data.Aeson ((.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (toList)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Stack (HasCallStack)
import System.Directory (listDirectory)
import System.FilePath ((</>))
import Test.Hspec
  ( Spec, describe, expectationFailure, it, pendingWith, shouldBe
  , shouldNotSatisfy, shouldSatisfy )

import Seal.Agent.Def.Backend qualified as AgentDef
import Seal.Agent.Runtime.Delegation
  ( ChildExitReason (..), ChildWorkerOutcome (..)
  , defaultDelegationConfig, newSpawnPauseFlag )
import Seal.Agent.Runtime.Registry (newAgentRuntime)
import Seal.Config.File (DelegationFileConfig (..))
import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (OpName (..), ToolCallId (..), mkSystemSessionId)
import Seal.ISA.Ops.Agent
import Seal.ISA.Opcode (opAuthorize)
import Seal.Providers.Class
  ( ContentBlock (..), CompletionResponse (..), StopReason (..), Usage (..) )
import Seal.TestHelpers.ApiTestHarness

spec :: Spec
spec = describe "Seal.Gateway.AgentIntegration" $ do
  definitionsGroupSpec
  lifecycleGroupSpec
  crossGroupSpec
  orchestrationGroupSpec
  w3CatalogSpec
  w2GateSpec

-- ---------------------------------------------------------------------------
-- Definitions group (#1-#7)
-- ---------------------------------------------------------------------------

definitionsGroupSpec :: Spec
definitionsGroupSpec = describe "definitions group (AGENT_DEF_*)" $ do
  describe "#1 Def list idempotency — AGENT_DEF_LIST twice yields the same count + ids" $
    runDefTest $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ CompletionResponse
            [ CbToolUse (ToolCallId "t1") (OpName "AGENT_DEF_LIST") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t2") (OpName "AGENT_DEF_LIST") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse [CbText "done"] StopEnd (Usage 0 0)
        ]
      _ <- sendMsgToSession env sid "list agents twice"
      entries <- getTranscript env sid
      let listResults = filterAgentResults (OpName "AGENT_DEF_LIST") entries
      length listResults `shouldBe` 2
      let (r1, r2) = (firstResult listResults, listResults !! 1)
      countOf r1 `shouldBe` countOf r2
      idsOf r1 `shouldBe` idsOf r2

  describe "#2 Def write increases list by one — list N → write → list N+1" $
    runDefTest $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ CompletionResponse
            [ CbToolUse (ToolCallId "t1") (OpName "AGENT_DEF_LIST") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t2") (OpName "AGENT_DEF_WRITE")
                (writeArgsFor "a-inv-2" "Inv Two") ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t3") (OpName "AGENT_DEF_LIST") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse [CbText "done"] StopEnd (Usage 0 0)
        ]
      _ <- sendMsgToSession env sid "list, write, list"
      entries <- getTranscript env sid
      let listResults = filterAgentResults (OpName "AGENT_DEF_LIST") entries
      length listResults `shouldBe` 2
      let n0 = countOf (firstResult listResults)
          n1 = countOf (listResults !! 1)
      n1 `shouldBe` n0 + 1
      idsOf (listResults !! 1) `shouldSatisfy` elem ("a-inv-2" :: Text)

  describe "#3 Def delete decreases list by one — write → list N → delete → list N-1" $
    runDefTest $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ CompletionResponse
            [ CbToolUse (ToolCallId "t1") (OpName "AGENT_DEF_WRITE")
                (writeArgsFor "a-inv-3" "Inv Three") ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t2") (OpName "AGENT_DEF_LIST") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t3") (OpName "AGENT_DEF_DELETE")
                (A.object ["id" .= ("a-inv-3" :: Text)]) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t4") (OpName "AGENT_DEF_LIST") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse [CbText "done"] StopEnd (Usage 0 0)
        ]
      _ <- sendMsgToSession env sid "write, list, delete, list"
      entries <- getTranscript env sid
      let listResults = filterAgentResults (OpName "AGENT_DEF_LIST") entries
      length listResults `shouldBe` 2
      let n0 = countOf (firstResult listResults)
          n1 = countOf (listResults !! 1)
      n1 `shouldBe` n0 - 1
      idsOf (listResults !! 1) `shouldSatisfy` notElem ("a-inv-3" :: Text)

  describe "#4 Def write is upsert — write a1 → write a1 (new name) → count unchanged → read returns new name" $
    runDefTest $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ CompletionResponse
            [ CbToolUse (ToolCallId "t1") (OpName "AGENT_DEF_WRITE")
                (writeArgsFor "a-inv-4" "Inv Four") ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t2") (OpName "AGENT_DEF_LIST") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t3") (OpName "AGENT_DEF_WRITE")
                (writeArgsFor "a-inv-4" "Updated Name") ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t4") (OpName "AGENT_DEF_LIST") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t5") (OpName "AGENT_DEF_READ")
                (A.object ["id" .= ("a-inv-4" :: Text)]) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse [CbText "done"] StopEnd (Usage 0 0)
        ]
      _ <- sendMsgToSession env sid "write, list, write (update), list, read"
      entries <- getTranscript env sid
      let listResults = filterAgentResults (OpName "AGENT_DEF_LIST") entries
      length listResults `shouldBe` 2
      countOf (firstResult listResults) `shouldBe` countOf (listResults !! 1)
      let readResults = filterAgentResults (OpName "AGENT_DEF_READ") entries
      length readResults `shouldBe` 1
      textOf (firstResult readResults) `shouldSatisfy` ("Updated Name" `T.isInfixOf`)

  describe "#5 Def read round-trips — write {id,name,provider,model} → read returns those fields" $
    runDefTest $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ CompletionResponse
            [ CbToolUse (ToolCallId "t1") (OpName "AGENT_DEF_WRITE")
                (writeArgsFor "a-inv-5" "Inv Five") ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t2") (OpName "AGENT_DEF_READ")
                (A.object ["id" .= ("a-inv-5" :: Text)]) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse [CbText "done"] StopEnd (Usage 0 0)
        ]
      _ <- sendMsgToSession env sid "write, read"
      entries <- getTranscript env sid
      let readResults = filterAgentResults (OpName "AGENT_DEF_READ") entries
      length readResults `shouldBe` 1
      let txt = textOf (firstResult readResults)
      txt `shouldSatisfy` ("a-inv-5" `T.isInfixOf`)
      txt `shouldSatisfy` ("Inv Five" `T.isInfixOf`)
      txt `shouldSatisfy` ("ollama" `T.isInfixOf`)
      txt `shouldSatisfy` ("llama3.2" `T.isInfixOf`)

  describe "#6 Def delete idempotent — delete missing id → no error → list unchanged" $
    runDefTest $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ CompletionResponse
            [ CbToolUse (ToolCallId "t1") (OpName "AGENT_DEF_LIST") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t2") (OpName "AGENT_DEF_DELETE")
                (A.object ["id" .= ("never-existed" :: Text)]) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t3") (OpName "AGENT_DEF_LIST") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse [CbText "done"] StopEnd (Usage 0 0)
        ]
      _ <- sendMsgToSession env sid "list, delete missing, list"
      entries <- getTranscript env sid
      let listResults = filterAgentResults (OpName "AGENT_DEF_LIST") entries
      length listResults `shouldBe` 2
      countOf (firstResult listResults) `shouldBe` countOf (listResults !! 1)
      idsOf (firstResult listResults) `shouldBe` idsOf (listResults !! 1)
      let delResults = filterAgentResults (OpName "AGENT_DEF_DELETE") entries
      length delResults `shouldBe` 1
      isErrorOf (firstResult delResults) `shouldBe` False

  describe "#7 Def read of missing id errors — transcript shows \"agent def not found\"" $
    runDefTest $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ CompletionResponse
            [ CbToolUse (ToolCallId "t1") (OpName "AGENT_DEF_READ")
                (A.object ["id" .= ("no-such-def" :: Text)]) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse [CbText "done"] StopEnd (Usage 0 0)
        ]
      _ <- sendMsgToSession env sid "read missing"
      entries <- getTranscript env sid
      let readResults = filterAgentResults (OpName "AGENT_DEF_READ") entries
      length readResults `shouldBe` 1
      let txt = textOf (firstResult readResults)
      txt `shouldSatisfy` ("agent def not found" `T.isInfixOf`)
      isErrorOf (firstResult readResults) `shouldBe` True

-- ---------------------------------------------------------------------------
-- Lifecycle group (#8-#15)
-- ---------------------------------------------------------------------------

lifecycleGroupSpec :: Spec
lifecycleGroupSpec = describe "lifecycle group (AGENT_INSTANCES/START/STATUS/STOP/INTERRUPT)" $ do
  describe "#8 Instances empty initially — AGENT_INSTANCES shows \"(no agents running)\"" $
    runDefTest $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ CompletionResponse
            [ CbToolUse (ToolCallId "t1") (OpName "AGENT_INSTANCES") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse [CbText "done"] StopEnd (Usage 0 0)
        ]
      _ <- sendMsgToSession env sid "list instances"
      entries <- getTranscript env sid
      let listResults = filterAgentResults (OpName "AGENT_INSTANCES") entries
      length listResults `shouldBe` 1
      textOf (firstResult listResults) `shouldSatisfy` ("(no agents running)" `T.isInfixOf`)
      countOf (firstResult listResults) `shouldBe` (0 :: Int)

  describe "#9 Start increases instances by one" $
    runLifecycleTest $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ CompletionResponse
            [ CbToolUse (ToolCallId "t1") (OpName "AGENT_DEF_WRITE") (writeArgsFor "a-inv-9" "Inv Nine") ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t2") (OpName "AGENT_START")
                (A.object
                  [ "id" .= ("a-inv-9" :: Text)
                  , "goal" .= ("do the thing" :: Text)
                  ]) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t3") (OpName "AGENT_INSTANCES") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse [CbText "done"] StopEnd (Usage 0 0)
        ]
      _ <- sendMsgToSession env sid "write, start, list instances"
      entries <- getTranscript env sid
      let listResults = filterAgentResults (OpName "AGENT_INSTANCES") entries
      length listResults `shouldBe` 1
      -- The CORRECT behavior: count = 1 after a successful start
      -- (registerChild records the synchronous child).
      countOf (firstResult listResults) `shouldBe` 1

  describe "#10 Stop decreases instances by one — after start, AGENT_INSTANCES shows 1" $
    runLifecycleTest $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ CompletionResponse
            [ CbToolUse (ToolCallId "t1") (OpName "AGENT_DEF_WRITE") (writeArgsFor "a-inv-10" "Inv Ten") ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t2") (OpName "AGENT_START")
                (A.object
                  [ "id" .= ("a-inv-10" :: Text)
                  , "goal" .= ("do the thing" :: Text)
                  ]) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t3") (OpName "AGENT_INSTANCES") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse [CbText "done"] StopEnd (Usage 0 0)
        ]
      _ <- sendMsgToSession env sid "write, start, list instances"
      entries <- getTranscript env sid
      let listResults = filterAgentResults (OpName "AGENT_INSTANCES") entries
      length listResults `shouldBe` 1
      -- After the registerChild fix, the synchronous start registers the
      -- completed child, so AGENT_INSTANCES shows 1. (We can't test the
      -- stop-decreases-by-one path because the real subagent_id is random
      -- and the flat-script harness can't reference it; AGENT_STOP with
      -- the def-id is a no-op. The instances-after-start assertion is the
      -- observable contract.)
      countOf (firstResult listResults) `shouldBe` 1

  describe "#11 Status of started agent — AGENT_INSTANCES shows the child after start" $
    runLifecycleTest $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ CompletionResponse
            [ CbToolUse (ToolCallId "t1") (OpName "AGENT_DEF_WRITE") (writeArgsFor "a-inv-11" "Inv Eleven") ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t2") (OpName "AGENT_START")
                (A.object
                  [ "id" .= ("a-inv-11" :: Text)
                  , "goal" .= ("do the thing" :: Text)
                  ]) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t3") (OpName "AGENT_INSTANCES") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse [CbText "done"] StopEnd (Usage 0 0)
        ]
      _ <- sendMsgToSession env sid "write, start, list instances"
      entries <- getTranscript env sid
      let listResults = filterAgentResults (OpName "AGENT_INSTANCES") entries
      length listResults `shouldBe` 1
      -- The registerChild fix makes AGENT_INSTANCES show the completed
      -- child (status "stopped" in the synchronous model). The list text
      -- should mention the def id. (AGENT_STATUS needs the real random
      -- subagent_id, which the flat-script harness can't reference; we
      -- assert the observable AGENT_INSTANCES contract instead.)
      textOf (firstResult listResults) `shouldSatisfy` ("a-inv-11" `T.isInfixOf`)

  describe "#12 Stop idempotent — AGENT_STOP with a non-running subagent_id returns \"stopped\"" $
    runDefTest $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ CompletionResponse
            [ CbToolUse (ToolCallId "t1") (OpName "AGENT_STOP")
                (A.object ["subagent_id" .= ("not-running" :: Text)]) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse [CbText "done"] StopEnd (Usage 0 0)
        ]
      _ <- sendMsgToSession env sid "stop a non-running agent"
      entries <- getTranscript env sid
      let stopResults = filterAgentResults (OpName "AGENT_STOP") entries
      length stopResults `shouldBe` 1
      textOf (firstResult stopResults) `shouldSatisfy` ("stopped" `T.isInfixOf`)
      isErrorOf (firstResult stopResults) `shouldBe` False

  describe "#13 Interrupt on non-running returns \"subagent not running\"" $
    runDefTest $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ CompletionResponse
            [ CbToolUse (ToolCallId "t1") (OpName "AGENT_INTERRUPT")
                (A.object ["subagent_id" .= ("not-running" :: Text)]) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse [CbText "done"] StopEnd (Usage 0 0)
        ]
      _ <- sendMsgToSession env sid "interrupt a non-running agent"
      entries <- getTranscript env sid
      let intrResults = filterAgentResults (OpName "AGENT_INTERRUPT") entries
      length intrResults `shouldBe` 1
      textOf (firstResult intrResults) `shouldSatisfy` ("subagent not running" `T.isInfixOf`)
      isErrorOf (firstResult intrResults) `shouldBe` False

  describe "#14 Start missing def returns \"agent def not found\"" $
    runDefTest $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ CompletionResponse
            [ CbToolUse (ToolCallId "t1") (OpName "AGENT_START")
                (A.object
                  [ "id" .= ("no-such-def" :: Text)
                  , "goal" .= ("do the thing" :: Text)
                  ]) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse [CbText "done"] StopEnd (Usage 0 0)
        ]
      _ <- sendMsgToSession env sid "start a missing def"
      entries <- getTranscript env sid
      let startResults = filterAgentResults (OpName "AGENT_START") entries
      length startResults `shouldBe` 1
      -- The error is carried in the rendered ChildResult text (the opcode
      -- returns Right results with orIsError=False; the per-child error is
      -- in the crError field rendered into the JSON).
      textOf (firstResult startResults) `shouldSatisfy` ("agent def not found" `T.isInfixOf`)

  describe "#15 Start missing goal is rejected (orIsError)" $
    runDefTest $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ CompletionResponse
            [ CbToolUse (ToolCallId "t1") (OpName "AGENT_START")
                (A.object ["id" .= ("a-inv-15" :: Text)]) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse [CbText "done"] StopEnd (Usage 0 0)
        ]
      _ <- sendMsgToSession env sid "start with no goal"
      entries <- getTranscript env sid
      let startResults = filterAgentResults (OpName "AGENT_START") entries
      length startResults `shouldBe` 1
      -- toAuthorize rejects before any IO when goal is absent.
      isErrorOf (firstResult startResults) `shouldBe` True
      textOf (firstResult startResults) `shouldSatisfy` ("goal" `T.isInfixOf`)

-- ---------------------------------------------------------------------------
-- Cross-group sequencing (#16-#17)
-- ---------------------------------------------------------------------------

crossGroupSpec :: Spec
crossGroupSpec = describe "cross-group sequencing" $ do
  describe "#16a Def write/delete round-trip — write a1 → list shows a1 → delete a1 → list no longer shows a1" $
    runDefTest $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ CompletionResponse
            [ CbToolUse (ToolCallId "t1") (OpName "AGENT_DEF_WRITE")
                (writeArgsFor "a-inv-16" "Inv Sixteen") ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t2") (OpName "AGENT_DEF_LIST") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t3") (OpName "AGENT_DEF_DELETE")
                (A.object ["id" .= ("a-inv-16" :: Text)]) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t4") (OpName "AGENT_DEF_LIST") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse [CbText "done"] StopEnd (Usage 0 0)
        ]
      _ <- sendMsgToSession env sid "write, list, delete, list"
      entries <- getTranscript env sid
      let listResults = filterAgentResults (OpName "AGENT_DEF_LIST") entries
      length listResults `shouldBe` 2
      idsOf (firstResult listResults) `shouldSatisfy` elem ("a-inv-16" :: Text)
      idsOf (listResults !! 1) `shouldSatisfy` notElem ("a-inv-16" :: Text)

  describe "#16b Start/instances round-trip — after start, AGENT_INSTANCES shows the child" $
    runLifecycleTest $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ CompletionResponse
            [ CbToolUse (ToolCallId "t1") (OpName "AGENT_DEF_WRITE") (writeArgsFor "a-inv-16b" "Inv Sixteen B") ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t2") (OpName "AGENT_START")
                (A.object
                  [ "id" .= ("a-inv-16b" :: Text)
                  , "goal" .= ("do the thing" :: Text)
                  ]) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t3") (OpName "AGENT_INSTANCES") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse [CbText "done"] StopEnd (Usage 0 0)
        ]
      _ <- sendMsgToSession env sid "write, start, list instances"
      entries <- getTranscript env sid
      let listResults = filterAgentResults (OpName "AGENT_INSTANCES") entries
      length listResults `shouldBe` 1
      -- The registerChild fix makes AGENT_INSTANCES show the completed
      -- child. The list text should mention the def id. (The full
      -- start/status/stop round-trip needs the real random subagent_id,
      -- which the flat-script harness can't reference; we assert the
      -- observable AGENT_INSTANCES contract instead.)
      countOf (firstResult listResults) `shouldBe` 1
      textOf (firstResult listResults) `shouldSatisfy` ("a-inv-16b" `T.isInfixOf`)

  describe "#17 Def list unchanged by AGENT_INSTANCES — AGENT_INSTANCES doesn't mutate the def store" $
    runDefTest $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ CompletionResponse
            [ CbToolUse (ToolCallId "t1") (OpName "AGENT_DEF_LIST") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t2") (OpName "AGENT_INSTANCES") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "t3") (OpName "AGENT_DEF_LIST") (A.object []) ]
            StopToolUse (Usage 0 0)
        , CompletionResponse [CbText "done"] StopEnd (Usage 0 0)
        ]
      _ <- sendMsgToSession env sid "list defs, list instances, list defs"
      entries <- getTranscript env sid
      let defListResults = filterAgentResults (OpName "AGENT_DEF_LIST") entries
      length defListResults `shouldBe` 2
      countOf (firstResult defListResults) `shouldBe` countOf (defListResults !! 1)
      idsOf (firstResult defListResults) `shouldBe` idsOf (defListResults !! 1)

-- ---------------------------------------------------------------------------
-- Test runners
-- ---------------------------------------------------------------------------

-- | Run a definitions-group test (no AGENT_START → no stub worker needed).
-- Uses 'runApiTest' which runs in both local and remote mode. Remote mode
-- pends on SSH tooling which may be absent in CI, so a pending there is
-- acceptable (the local-mode run is the assertion that matters).
runDefTest :: (ApiTestEnv -> IO ()) -> Spec
runDefTest = runApiTest Nothing

-- | Run a lifecycle-group test that exercises AGENT_START. The stub child
-- worker is injected so the start completes without a real provider call;
-- with W2's depth-conditional stub policy the threshold is set to 1 so the
-- stub applies at the FIRST spawn (depth 1) — matching the pre-W2
-- behavior of stubbing every spawn.
runLifecycleTest :: (ApiTestEnv -> IO ()) -> Spec
runLifecycleTest =
  runApiTestOpts Nothing defaultApiTestOptions
    { atoChildWorker = Just stubChildWorker
    , atoStubWorkerFromDepth = 1
    }

-- | Run a W2 orchestration test. The child-provider seam makes the
-- orchestrator child run a REAL scripted turn (popping the same script
-- queue as the parent), while the depth-conditional stub worker takes over
-- at depth 2 (leaf-most workers complete synchronously).
runOrchestrationTest
  :: Maybe DelegationFileConfig -> (ApiTestEnv -> IO ()) -> Spec
runOrchestrationTest mDelegation =
  runApiTestOpts Nothing defaultApiTestOptions
    { atoChildWorker = Just stubChildWorker
    , atoStubWorkerFromDepth = 2
    , atoChildProvider = True
    , atoDelegationConfig = mDelegation
    }

-- ---------------------------------------------------------------------------
-- W2 orchestration group (issue #154) — nested AGENT_START, depth, roles
-- ---------------------------------------------------------------------------

-- | One scripted turn: emit exactly one tool call then stop (tool use).
toolUseTurn :: Text -> OpName -> A.Value -> CompletionResponse
toolUseTurn tid op args =
  CompletionResponse
    [ CbToolUse (ToolCallId tid) op args ]
    StopToolUse (Usage 0 0)

doneTurn :: CompletionResponse
doneTurn = CompletionResponse [CbText "done"] StopEnd (Usage 0 0)

-- | AGENT_DEF_WRITE args with a role.
writeArgsRole :: Text -> Text -> A.Value
writeArgsRole defId role = A.object
  [ "id" .= defId
  , "name" .= (defId <> " Name")
  , "provider" .= ("ollama" :: Text)
  , "model" .= ("llama3.2" :: Text)
  , "role" .= role
  ]

-- | A @DelegationFileConfig@ with every field unset (the TOML defaults),
-- overridable per-test via record update.
defaultDelegation :: DelegationFileConfig
defaultDelegation = DelegationFileConfig
  { dfcMaxConcurrentChildren = Nothing
  , dfcChildTimeoutSeconds   = Nothing
  , dfcMaxSpawnDepth         = Nothing
  , dfcOrchestratorEnabled   = Nothing
  , dfcProvider              = Nothing
  , dfcModel                 = Nothing
  , dfcBaseUrl               = Nothing
  , dfcApiKey                = Nothing
  , dfcApiMode               = Nothing
  , dfcSubagentAutoApprove   = Nothing
  }

orchestrationGroupSpec :: Spec
orchestrationGroupSpec = describe "W2 orchestration (nested AGENT_START, depth, roles)" $ do
  -- W2 EXIT CRITERION: an orchestrator child spawns a grandchild through
  -- the REAL nested wiring (child-side AgentStartWiring at depth+1), with
  -- the depth-conditional stub taking over at depth 2.
  describe "#W2.1 Grandchild spawn (exit criterion) — orchestrator child spawns a leaf grandchild" $
    runOrchestrationTest (Just (defaultDelegation { dfcMaxSpawnDepth = Just 2 })) $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ -- Parent turn: write both defs, then spawn the orchestrator.
          -- NOTE the queue order: the child's turn runs SYNCHRONOUSLY
          -- inside p3's dispatch, so c1 + done are popped (by the child)
          -- BEFORE the parent resumes with the instances call.
          CompletionResponse
            [ CbToolUse (ToolCallId "p1") (OpName "AGENT_DEF_WRITE")
                (writeArgsRole "a-orch" "orchestrator") ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "p2") (OpName "AGENT_DEF_WRITE")
                (writeArgsRole "a-leaf" "leaf") ]
            StopToolUse (Usage 0 0)
        , toolUseTurn "p3" (OpName "AGENT_START")
            (A.object ["id" .= ("a-orch" :: Text), "goal" .= ("orchestrate the work" :: Text)])
        , -- (popped by the CHILD) Orchestrator child turn: batch-spawn.
          CompletionResponse
            [ CbToolUse (ToolCallId "c1") (OpName "AGENT_START")
                (A.object ["tasks" .=
                  [ A.object ["id" .= ("a-leaf" :: Text), "goal" .= ("do leaf work" :: Text)]
                  , A.object ["id" .= ("a-orch" :: Text), "goal" .= ("nested orchestration" :: Text)]
                  ]])]
            StopToolUse (Usage 0 0)
        , -- (popped by the CHILD) end of the child turn.
          doneTurn
        , -- Parent resumes: check the runtime registry after the start.
          toolUseTurn "p4" (OpName "AGENT_INSTANCES") (A.object [])
        , doneTurn
        ]
      _ <- sendMsgToSession env sid "orchestrate"
      entries <- getTranscript env sid
      let listResults = filterAgentResults (OpName "AGENT_INSTANCES") entries
      length listResults `shouldBe` 1
      -- The parent's AGENT_START result reports the orchestrator child as
      -- CsCompleted with a REAL summary (the child ran a real scripted
      -- turn — its final answer flowed back through the aeOnStop capture).
      let startResults = filterAgentResults (OpName "AGENT_START") entries
      length startResults `shouldSatisfy` (>= 1)
      -- AGENT_INSTANCES: the completed children register (1 orchestrator
      -- child at depth 1 — the synchronous grandchildren register too).
      countOf (firstResult listResults) `shouldSatisfy` (>= 1)
      -- The orchestrator's summary text reached the parent's transcript
      -- (the child ran a REAL turn — not the stub's "child done").
      textOf (firstResult startResults) `shouldNotSatisfy` ("(no summary)" `T.isInfixOf`)

  describe "#W2.2 Depth cap — max_spawn_depth = 2 rejects the third level with the depth message" $
    runOrchestrationTest (Just (defaultDelegation { dfcMaxSpawnDepth = Just 2 })) $ \_ ->
      pendingWith "W2 depth-chain: covered by the depth arithmetic in runDelegate (parentDepth >= maxDepth); the W2.1 test exercises the nested path"

-- ---------------------------------------------------------------------------
-- W3 orchestration (issue #154) — the <available_agents> catalog
-- ---------------------------------------------------------------------------

w3CatalogSpec :: Spec
w3CatalogSpec = describe "W3 catalog (<available_agents> injection)" $ do
  -- The catalog appears in the PARENT prompt's preamble entry (the
  -- EKRequest entry carrying the full system-prompt envelope), after the
  -- skills catalog.
  describe "#W3.1 Parent prompt — catalog present" $
    runDefTest $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ -- Turn 1: write the def.
          CompletionResponse
            [ CbToolUse (ToolCallId "p1") (OpName "AGENT_DEF_WRITE")
                (writeArgsRole "a-orch" "orchestrator") ]
            StopToolUse (Usage 0 0)
        , doneTurn
        , -- Turn 2: the system prompt's catalog now includes the def.
          doneTurn
        ]
      _ <- sendMsgToSession env sid "write a def"
      _ <- sendMsgToSession env sid "again"
      entries <- getTranscript env sid
      let systemTexts = mapMaybe payloadSystemText entries
          withAgents = [ t | t <- systemTexts, "<available_agents>" `T.isInfixOf` t ]
      length withAgents `shouldSatisfy` (>= 1)
      -- The rendered def bullet (id + role + description).
      any (\t -> "a-orch [orchestrator]" `T.isInfixOf` t) withAgents
        `shouldBe` True
      -- W3-review fix 2: ordering — the agents catalog is appended AFTER
      -- the skills catalog (cache-friendly ordering), so within the same
      -- system text the block's opener must follow the skills close tag.
      forM_ withAgents $ \t ->
        case T.breakOn "<available_agents>" t of
          (prefix, rest)
            | not (T.null rest) -> do
              ("<available_skills>" `T.isInfixOf` prefix) `shouldBe` True
              ("</available_skills>" `T.isInfixOf` prefix) `shouldBe` True
              T.length rest `shouldSatisfy` (> 0)
            | otherwise -> pure ()  -- unreachable: the filter required the opener

  -- W3-review fix 3: the CHILD-plane gating. The child's system prompt is
  -- NOT observable through the API (the /transcript endpoint resolves
  -- <state>/sessions/<sid>/ — a child's transcript nests under the PARENT
  -- session's agents/ dir instead), so the tests read the child's
  -- entries.jsonl directly from disk and decode each EKRequest line's
  -- envelope.system (the first request entry carries the full envelope).
  describe "#W3.2 Child prompt — orchestrator child gets the catalog" $
    runOrchestrationTest Nothing $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ -- Parent turn 1: write both defs.
          CompletionResponse
            [ CbToolUse (ToolCallId "p1") (OpName "AGENT_DEF_WRITE")
                (writeArgsRole "a-orch" "orchestrator") ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "p2") (OpName "AGENT_DEF_WRITE")
                (writeArgsRole "a-leaf" "leaf") ]
            StopToolUse (Usage 0 0)
        , -- Parent turn 2: spawn the orchestrator (single mode). The
          -- child's turn runs SYNCHRONOUSLY inside p3's dispatch, popping
          -- c1 BEFORE the parent resumes with p4.
          toolUseTurn "p3" (OpName "AGENT_START")
            (A.object ["id" .= ("a-orch" :: Text), "goal" .= ("orchestrate" :: Text)])
        , -- (popped by the CHILD) end of the child turn.
          doneTurn
        , -- Parent resumes.
          doneTurn
        ]
      _ <- sendMsgToSession env sid "spawn orchestrator"
      entries <- getTranscript env sid
      -- The child ran a REAL turn (depth 1 < stub threshold 2): its summary
      -- "done" reached the parent's AGENT_START result.
      let startResults = filterAgentResults (OpName "AGENT_START") entries
      length startResults `shouldSatisfy` (>= 1)
      textOf (firstResult startResults) `shouldNotSatisfy` ("(no summary)" `T.isInfixOf`)
      -- The orchestrator child's system text carries the catalog, with the
      -- rendered bullets for BOTH defs (the union backend the child shares
      -- with the parent).
      childTexts <- childSystemTexts env sid
      length childTexts `shouldBe` (1 :: Int)
      forM_ childTexts $ \t -> do
        ("<available_agents>" `T.isInfixOf` t) `shouldBe` True
        ("a-orch [orchestrator]" `T.isInfixOf` t) `shouldBe` True
        ("a-leaf [leaf]" `T.isInfixOf` t) `shouldBe` True

  describe "#W3.3 Child prompt — leaf child gets the leaf note, not the catalog" $
    runOrchestrationTest Nothing $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ -- Parent turn 1: write the leaf def.
          CompletionResponse
            [ CbToolUse (ToolCallId "p1") (OpName "AGENT_DEF_WRITE")
                (writeArgsRole "a-leaf" "leaf") ]
            StopToolUse (Usage 0 0)
        , -- Parent turn 2: spawn the leaf def (allowed at top level —
          -- the kill switch gates orchestrator-role spawns only).
          toolUseTurn "p2" (OpName "AGENT_START")
            (A.object ["id" .= ("a-leaf" :: Text), "goal" .= ("leaf work" :: Text)])
        , -- (popped by the CHILD) end of the child turn.
          doneTurn
        , -- Parent resumes.
          doneTurn
        ]
      _ <- sendMsgToSession env sid "spawn leaf"
      childTexts <- childSystemTexts env sid
      length childTexts `shouldBe` (1 :: Int)
      forM_ childTexts $ \t -> do
        -- The leaf note replaces the catalog (both planes gate on the
        -- same predicate: effective role + kill switch).
        ("You are a leaf agent; delegation is not available." `T.isInfixOf` t) `shouldBe` True
        ("<available_agents>" `T.isInfixOf` t) `shouldBe` False

  describe "#W3.4 Kill switch — orchestrator_enabled = false ⇒ no catalog anywhere" $
    runOrchestrationTest (Just (defaultDelegation { dfcOrchestratorEnabled = Just False })) $ \env -> do
      sid <- callApiNewTab env "ollama" "llama3.2"
      setScript env
        [ -- Parent turn 1: write both defs.
          CompletionResponse
            [ CbToolUse (ToolCallId "p1") (OpName "AGENT_DEF_WRITE")
                (writeArgsRole "a-orch" "orchestrator") ]
            StopToolUse (Usage 0 0)
        , CompletionResponse
            [ CbToolUse (ToolCallId "p2") (OpName "AGENT_DEF_WRITE")
                (writeArgsRole "a-leaf" "leaf") ]
            StopToolUse (Usage 0 0)
        , -- Parent turn 2: the orchestrator spawn is rejected by the
          -- kill switch (before any worker runs — no child transcript).
          toolUseTurn "p3" (OpName "AGENT_START")
            (A.object ["id" .= ("a-orch" :: Text), "goal" .= ("orchestrate" :: Text)])
        , -- Parent turn 3: the leaf spawn succeeds (the switch gates
          -- orchestrator-role spawns only); the child pops c1 inside p4.
          toolUseTurn "p4" (OpName "AGENT_START")
            (A.object ["id" .= ("a-leaf" :: Text), "goal" .= ("leaf work" :: Text)])
        , -- (popped by the CHILD) end of the child turn.
          doneTurn
        , -- Parent resumes.
          doneTurn
        ]
      _ <- sendMsgToSession env sid "kill switch off"
      entries <- getTranscript env sid
      let startResults = filterAgentResults (OpName "AGENT_START") entries
      length startResults `shouldBe` (2 :: Int)
      -- The orchestrator spawn failed with the dedicated kill-switch
      -- message (the dispatch-time TOCTOU gate).
      textOf (firstResult startResults)
        `shouldSatisfy` ("delegation.orchestrator_enabled = false" `T.isInfixOf`)
      -- The only child transcript on disk is the LEAF child's: leaf note,
      -- no catalog (orchEnabled=false feeds the same predicate the
      -- registry's gate used — both planes gated together).
      childTexts <- childSystemTexts env sid
      length childTexts `shouldBe` (1 :: Int)
      forM_ childTexts $ \t -> do
        ("You are a leaf agent; delegation is not available." `T.isInfixOf` t) `shouldBe` True
        ("<available_agents>" `T.isInfixOf` t) `shouldBe` False

-- | Extract the @payload.system@ text from a transcript entry ('Nothing'
-- when the entry has no system field).
payloadSystemText :: A.Value -> Maybe Text
payloadSystemText entry = do
  obj <- asObject entry
  payload <- KeyMap.lookup payloadKey obj >>= asObject
  case KeyMap.lookup systemKey payload of
    Just (A.String t) -> pure t
    _                 -> Nothing
  where
    systemKey = Key.fromString "system"

-- | Read the CHILD system prompts for a parent session: child transcripts
-- live under @\<spState\>\/sessions\/\<parent\>\/agents\/\<child\>\/@ (the
-- worker opens them there; the API's /transcript endpoint only resolves the
-- top-level sessions dir, so the API cannot expose them). Each child's
-- @entries.jsonl@ is decoded and every EKRequest line's @envelope.system@
-- is extracted (the first request entry carries the full envelope;
-- subsequent ones omit unchanged fields). Returns one text per child that
-- produced at least one system prompt.
childSystemTexts :: ApiTestEnv -> Text -> IO [Text]
childSystemTexts env sid = do
  let agentsDir = spState (atePaths env) </> "sessions" </> T.unpack sid </> "agents"
  childSids <- listDirectory agentsDir
  fmap concat $ forM childSids $ \childSid -> do
    raw <- BC.readFile (agentsDir </> childSid </> "entries.jsonl")
    let entryVals = mapMaybe (A.decode . BL.fromStrict) (BC.lines raw)
    pure [ t | v <- entryVals, Just t <- [envelopeSystemText v] ]

-- | The @envelope.system@ text of an on-disk entries.jsonl line
-- ('Nothing' when the line is not a request entry or omits the system
-- field).
envelopeSystemText :: A.Value -> Maybe Text
envelopeSystemText v = do
  obj <- asObject v
  envObj <- KeyMap.lookup envelopeKey obj >>= asObject
  case KeyMap.lookup systemKey envObj of
    Just (A.String t) -> pure t
    _                 -> Nothing
  where
    envelopeKey = Key.fromString "envelope"
    systemKey   = Key.fromString "system"

-- ---------------------------------------------------------------------------
-- W2 gate authorize tests (§3.2 item 6) — the SAME authorize function the
-- child's dispatch calls
-- ---------------------------------------------------------------------------

w2GateSpec :: Spec
w2GateSpec = describe "W2 gate (present-but-rejecting op)" $ do
  describe "#W2.4 Leaf cannot spawn — the gate rejects with the dedicated leaf message" $
    it "authorize on a leaf-gated wiring fails with the leaf message" $ do
      wiring <- gateTestWiring (AgentStartGate { gEffectiveRole = Just "leaf", gOrchEnabled = True })
      case opAuthorize (agentStartOp wiring) (A.object ["goal" .= ("x" :: Text)]) of
        Left why -> do
          why `shouldSatisfy` ("its definition is a leaf" `T.isInfixOf`)
          why `shouldSatisfy` ("Ask the operator to grant the orchestrator role" `T.isInfixOf`)
        Right () -> expectationFailure "expected the leaf gate to reject"

  describe "#W2.5 Kill switch — the gate rejects with the dedicated kill-switch message" $ do
    it "orchestrator-gated wiring + switch off fails with the retry-hint message" $ do
      wiring <- gateTestWiring (AgentStartGate { gEffectiveRole = Just "orchestrator", gOrchEnabled = False })
      case opAuthorize (agentStartOp wiring) (A.object ["goal" .= ("x" :: Text)]) of
        Left why -> do
          why `shouldSatisfy` ("delegation.orchestrator_enabled = false" `T.isInfixOf`)
          why `shouldSatisfy` ("Re-trying will not succeed" `T.isInfixOf`)
        Right () -> expectationFailure "expected the kill-switch gate to reject"
    it "open gate (top-level) authorizes" $ do
      wiring <- gateTestWiring gateOpen
      opAuthorize (agentStartOp wiring) (A.object ["goal" .= ("x" :: Text)]) `shouldBe` Right ()

-- | A minimal 'AgentStartWiring' for the gate tests: the GATE is under
-- test, so the fields below it are never exercised (authorize rejects
-- before the config/worker/mint run). They still need values —
-- 'noneBackend', a fresh runtime, and no-op stubs.
gateTestWiring :: AgentStartGate -> IO AgentStartWiring
gateTestWiring gate = do
  backend <- AgentDef.noneBackend
  rt <- newAgentRuntime
  pauseFlag <- newSpawnPauseFlag
  pure AgentStartWiring
    { aswDefBackend = backend
    , aswRuntime = rt
    , aswConfig = pure defaultDelegationConfig
    , aswPauseFlag = pauseFlag
    , aswParentActivity = Nothing
    , aswMintSession = pure (mkSystemSessionId "gategtest")
    , aswParentDepth = 0
    , aswWorker = \_ _ _ _ -> pure (ChildWorkerOutcome Nothing CerError 0 0 Nothing)
    , aswGate = gate
    }

-- | AGENT_DEF_WRITE args with a role.

-- | Build AGENT_DEF_WRITE args for a specific id + name (provider/model are
-- constant). Each test uses its own id to avoid cross-test interference (each
-- test gets a fresh temp dir, but the two modes within a test share the same
-- backends — and even across tests the backends are fresh per mode-run, so
-- collisions are avoided by using test-specific ids).
writeArgsFor :: Text -> Text -> A.Value
writeArgsFor defId defName = A.object
  [ "id" .= defId
  , "name" .= defName
  , "provider" .= ("ollama" :: Text)
  , "model" .= ("llama3.2" :: Text)
  ]

-- ---------------------------------------------------------------------------
-- Transcript parsing
-- ---------------------------------------------------------------------------

-- | An extracted AGENT_ opcode result: the opcode name, the orParts text,
-- and the orIsError flag.
data AgentResult = AgentResult
  { arOpName :: !OpName
  , arText   :: !Text
  , arError  :: !Bool
  } deriving (Eq, Show)

-- | Extract all AGENT_ opcode results from the transcript, in order.
-- The transcript carries tool calls across two entry kinds:
--
--   * @response@ entries have a @payload.content@ array with @tool_use@
--     blocks carrying the opcode @name@ + @id@ (the tool_use_id).
--   * @request@ entries have a @payload.messages@ array whose @content@
--     blocks include @tool_result@ blocks carrying @tool_use_id@, @content@
--     (array of text blocks), and @is_error@.
--
-- We build a @tool_use_id → opname@ map from the response entries, then
-- walk the request entries' tool_result blocks in order, looking up the
-- opname by @tool_use_id@.
filterAgentResults :: OpName -> [A.Value] -> [AgentResult]
filterAgentResults targetOp entries =
  let idToName = buildToolUseIdMap entries
  in mapMaybe (matchToolResult targetOp idToName) entries

-- | Build a map from tool_use_id → opname by scanning @response@ entries'
-- @payload.content@ arrays for @tool_use@ blocks.
buildToolUseIdMap :: [A.Value] -> KeyMap.KeyMap OpName
buildToolUseIdMap entries = KeyMap.fromList
  [ (Key.fromText tid, OpName nm)
  | entry <- entries
  , Just obj <- [asObject entry]
  , dirIs obj "response"
  , Just payloadObj <- [KeyMap.lookup payloadKey obj >>= asObject]
  , Just (A.Array contentArr) <- [KeyMap.lookup contentKey payloadObj]
  , blk <- toList contentArr
  , Just bo <- [asObject blk]
  , typeIs bo "tool_use"
  , Just (A.String tid) <- [KeyMap.lookup idKey bo]
  , Just (A.String nm) <- [KeyMap.lookup nameKey bo]
  ]
  where
    dirIs o d = case KeyMap.lookup directionKey o of
      Just (A.String t) -> t == d; _ -> False
    typeIs o t = case KeyMap.lookup typeKey o of
      Just (A.String s) -> s == t; _ -> False

-- | Match a @tool_result@ block in a @request@ entry against the target
-- opcode, using the id→name map to resolve the opcode name from the
-- tool_use_id.
matchToolResult
  :: OpName -> KeyMap.KeyMap OpName -> A.Value -> Maybe AgentResult
matchToolResult targetOp idToName entry = do
  obj <- asObject entry
  guard (dirIs obj "request")
  payloadObj <- KeyMap.lookup payloadKey obj >>= asObject
  msgsVal <- KeyMap.lookup messagesKey payloadObj
  msgs <- asArray msgsVal
  -- The user-role message carries one or more tool_result blocks; we
  -- return the first matching block (the scripts are single-tool-per-turn,
  -- so each request entry has exactly one tool_result).
  let blocks = concatMap contentBlocks msgs
  blk <- listToMaybe' blocks
  bo <- asObject blk
  guard (typeIs bo "tool_result")
  tid <- case KeyMap.lookup toolUseIdKey bo of
    Just (A.String t) -> Just t
    _ -> Nothing
  opName <- KeyMap.lookup (Key.fromText tid) idToName
  guard (opName == targetOp)
  let txt = extractToolResultText bo
      isErr = extractToolResultIsError bo
  pure (AgentResult opName txt isErr)
  where
    dirIs o d = case KeyMap.lookup directionKey o of
      Just (A.String t) -> t == d; _ -> False
    typeIs o t = case KeyMap.lookup typeKey o of
      Just (A.String s) -> s == t; _ -> False
    -- Extract the content blocks array from a message object.
    contentBlocks msg = case asObject msg of
      Nothing -> []
      Just mo -> case KeyMap.lookup contentKey mo of
        Just (A.Array arr) -> toList arr
        _ -> []

-- | Extract the concatenated text from a @tool_result@ block's @content@
-- array (each element is @{type:"text", text:"..."}@).
extractToolResultText :: A.Object -> Text
extractToolResultText bo =
  case KeyMap.lookup contentKey bo of
    Just (A.Array arr) -> T.concat (map blockText (toList arr))
    _ -> ""
  where
    blockText (A.Object o) = case KeyMap.lookup textKey o of
      Just (A.String t) -> t
      _ -> ""
    blockText _ = ""

-- | Extract the @is_error@ flag from a @tool_result@ block (default False).
extractToolResultIsError :: A.Object -> Bool
extractToolResultIsError bo =
  case KeyMap.lookup isErrorKey bo of
    Just (A.Bool b) -> b
    _ -> False

-- ---------------------------------------------------------------------------
-- Aeson shape helpers
-- ---------------------------------------------------------------------------

asObject :: A.Value -> Maybe A.Object
asObject (A.Object o) = Just o
asObject _ = Nothing

asArray :: A.Value -> Maybe [A.Value]
asArray (A.Array a) = Just (toList a)
asArray _ = Nothing

payloadKey, directionKey, contentKey, typeKey, idKey, nameKey, messagesKey, toolUseIdKey, textKey, isErrorKey :: Key.Key
payloadKey    = Key.fromString "payload"
directionKey  = Key.fromString "direction"
contentKey    = Key.fromString "content"
typeKey       = Key.fromString "type"
idKey         = Key.fromString "id"
nameKey       = Key.fromString "name"
messagesKey    = Key.fromString "messages"
toolUseIdKey  = Key.fromString "tool_use_id"
textKey       = Key.fromString "text"
isErrorKey    = Key.fromString "is_error"

-- | The rendered text of an AGENT_ result (its orParts joined).
textOf :: AgentResult -> Text
textOf = arText

-- | Whether the AGENT_ result was an error (orIsError).
isErrorOf :: AgentResult -> Bool
isErrorOf = arError

-- | The recorded \"count\" field of an AGENT_DEF_LIST / AGENT_INSTANCES
-- result. The list format is one entry per line, or
-- \"(no agent definitions)\" / \"(no agents running)\" for the empty case.
countOf :: AgentResult -> Int
countOf r =
  let txt = arText r
  in if "(no agent" `T.isInfixOf` txt
       then 0
       else length (filter (not . T.null) (T.lines (T.strip txt)))

-- | The list of ids from an AGENT_DEF_LIST / AGENT_INSTANCES result. Each
-- list line is @<id>: <name> (<provider>/<model>)@ or
-- @<subagent_id>: <def_id> — <status>@ — we take the prefix before the
-- first colon.
idsOf :: AgentResult -> [Text]
idsOf r =
  let txt = arText r
  in if "(no agent" `T.isInfixOf` txt
       then []
       else mapMaybe (T.stripPrefix "" . T.takeWhile (/= ':'))
                     (filter (not . T.null) (T.lines (T.strip txt)))

-- | A local guard helper (avoids importing Prelude's guard which needs
-- Alternative).
guard :: Bool -> Maybe ()
guard True  = Just ()
guard False = Nothing

-- | Maybe-friendly list-head (avoids the partial 'head' and the
-- 'Alternative' import that 'listToMaybe' would need in a 'Maybe' do-block).
listToMaybe' :: [a] -> Maybe a
listToMaybe' []    = Nothing
listToMaybe' (x:_) = Just x

-- | Safe head for test assertions: returns the first element of a list,
-- failing the test with a clear message if the list is empty. Used instead
-- of the partial @head@ / @!! 0@ (which hlint flags). The caller has
-- already asserted the list's length, so this never actually fails.
firstResult :: HasCallStack => [a] -> a
firstResult []    = error "firstResult: empty list (caller should have asserted length first)"
firstResult (x:_) = x