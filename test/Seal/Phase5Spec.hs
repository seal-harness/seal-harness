{-# LANGUAGE OverloadedStrings #-}
-- | Phase 5 capstone: the end-to-end Definition-of-Done scenario. One chat
-- session creates a memory, recalls it, defines a skill, defines an agent,
-- starts the agent in a forked session, and stops it — with every mutation
-- landing in the Audited log (cross-session canonical) and every session
-- transcript in the two-file format. This is the whole-phase gate from
-- @docs/superpowers/plans/2026-07-05-phase-5-audited-stores.md@.
module Seal.Phase5Spec (spec) where

import Control.Concurrent (threadDelay)
import Data.Aeson (object, (.=))
import Data.IORef
import Data.Text (Text)
import Test.Hspec

import Seal.Agent.Def.Backend qualified as Def
import Seal.Agent.Def.Types (mkAgentDefId)
import Seal.Agent.Env (AgentEnv (..))
import Seal.Agent.Loop (runTurn)
import Seal.Agent.Runtime.Registry
  ( AgentStatus (..), agentStatus, newAgentRuntime )
import Seal.Audited.Types (AuditedEntry, AuditedKind (..), aeKind, aeOpcode)
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types (ModelId (..), OpName (..), SessionId (..), ToolCallId (..))
import Seal.Handles.Audited (fakeAuditedLog)
import Seal.Handles.Transcript (fakeTwoFileTranscript)
import Seal.ISA.Dispatch (dispatch)
import Seal.ISA.Opcode (localBackend)
import Seal.ISA.Ops.Agent
  ( agentDefCreateOp, agentDefReadOp, agentDefUpdateOp, agentListOp
  , agentStartOp, agentStatusOp, agentStopOp )
import Seal.ISA.Ops.Memory
  ( memoryDeleteOp, memoryRecallOp, memoryStoreOp, memoryUpdateOp )
import Seal.ISA.Ops.Skills
  ( skillCreateOp, skillListOp, skillReadOp, skillUpdateOp )
import Seal.ISA.Registry qualified as ISA
import Seal.Memory.Backend qualified as Mem
import Seal.Providers.Class
  ( CompletionResponse (..), ContentBlock (..), Provider (..)
  , StopReason (..), Usage (..), SomeProvider (..) )
import Seal.Skills.Backend qualified as Skill
import Seal.Types.App (App, runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)

-- | A provider that returns a scripted list of responses, one per call.
newtype ScriptProvider = ScriptProvider (IORef [CompletionResponse])

instance Provider ScriptProvider where
  listModels _ = pure (Right [])
  complete (ScriptProvider ref) _ = do
    rs <- readIORef ref
    case rs of
      (x:xs) -> writeIORef ref xs >> pure (Right x)
      []     -> pure (Right (CompletionResponse [CbText "done"] StopEnd (Usage 0 0)))

runTestApp :: App a -> IO a
runTestApp act = do env <- mkEnv defaultConfig; runApp env act

sampleSession :: SessionId
sampleSession = SessionId "s1"

-- | The script for the capstone turn: the model emits four tool calls in one
-- response (MEMORY_STORE, MEMORY_RECALL, SKILL_CREATE, AGENT_DEF_CREATE), then
-- a final text response. runTurn dispatches each tool call through 'dispatch'
-- (which writes BOTH the session transcript and the Audited log for Audited
-- opcodes), then loops with the tool results, then gets the final text.
capstoneScript :: [CompletionResponse]
capstoneScript =
  [ CompletionResponse
      [ CbToolUse (ToolCallId "t1") (OpName "MEMORY_STORE")
          (object
            [ "id" .= ("greeting" :: Text)
            , "content" .= ("hello world" :: Text)
            ])
      , CbToolUse (ToolCallId "t2") (OpName "MEMORY_RECALL") (object [])
      , CbToolUse (ToolCallId "t3") (OpName "SKILL_CREATE")
          (object
            [ "id" .= ("greet" :: Text)
            , "description" .= ("greeting skill" :: Text)
            , "body" .= ("say hello warmly" :: Text)
            ])
      , CbToolUse (ToolCallId "t4") (OpName "AGENT_DEF_CREATE")
          (object
            [ "id" .= ("worker" :: Text)
            , "name" .= ("worker" :: Text)
            , "provider" .= ("ollama" :: Text)
            , "model" .= ("llama3" :: Text)
            ])
      ]
      StopToolUse
      (Usage 0 0)
  , CompletionResponse [CbText "all four evolutionary mutations applied"] StopEnd (Usage 0 0)
  ]

-- | Build the full ISA registry the capstone turn uses. The AGENT_START worker
-- is a fake (records it ran, then blocks) so the test can assert lifecycle
-- without a live provider.
buildRegistry :: IORef Int -> SessionId -> IO ISA.Registry
buildRegistry workerRan sid = do
  memBackend <- Mem.noneBackend
  skillBackend <- Skill.noneBackend
  defBackend <- Def.noneBackend
  rt <- newAgentRuntime
  pure $ ISA.mkRegistry
    [ memoryStoreOp memBackend sid
    , memoryRecallOp defaultPageParams memBackend
    , memoryUpdateOp memBackend
    , memoryDeleteOp memBackend
    , skillCreateOp skillBackend sid
    , skillReadOp skillBackend
    , skillUpdateOp skillBackend
    , skillListOp skillBackend
    , agentDefCreateOp defBackend sid
    , agentDefReadOp defBackend
    , agentDefUpdateOp defBackend
    , agentListOp rt
    , agentStartOp defBackend rt (pure sid) (\_ _ -> modifyIORef' workerRan (+1) >> threadDelay 1000000)
    , agentStatusOp rt
    , agentStopOp rt
    ]

-- | The kinds/opcodes of the Audited entries written by a dispatch, in order.
auditedKinds :: [AuditedEntry] -> [(AuditedKind, OpName)]
auditedKinds = map (\e -> (aeKind e, aeOpcode e))

spec :: Spec
spec = describe "Phase 5 capstone (DoD scenario)" $ do
  it "one chat turn: MEMORY_STORE + RECALL + SKILL_CREATE + AGENT_DEF_CREATE — every mutation in the Audited log, transcript in two-file format" $ do
    sent <- newIORef ([] :: [Text])
    workerRan <- newIORef (0 :: Int)
    let caps = ChannelCaps
                 (\t -> modifyIORef' sent (++ [t]))
                 (\_ -> pure "")
                 (\_ -> pure "")
    reg <- buildRegistry workerRan sampleSession
    ref <- newIORef capstoneScript
    (tHandle, readTranscript) <- fakeTwoFileTranscript
    (audited, readAudited) <- fakeAuditedLog
    let env = AgentEnv
                { aeProvider = SomeProvider (ScriptProvider ref)
                , aeProviderLabel = "ollama"
                , aeModel = ModelId "llama3"
                , aeRegistry = reg
                , aeTranscript = tHandle
                , aeAudited = audited
                , aeBackend = localBackend
                , aeCaps = caps
                , aeSession = sampleSession
                , aeMaxTurns = 8
                }
    runTestApp (runTurn env "run the capstone")
    -- 1. The Audited log carries all four mutations, with the right kinds.
    auditedEntries <- readAudited
    auditedKinds auditedEntries `shouldBe`
      [ (AKMemory,   OpName "MEMORY_STORE")
      , (AKMemory,   OpName "MEMORY_RECALL")
      , (AKSkill,    OpName "SKILL_CREATE")
      , (AKAgentDef, OpName "AGENT_DEF_CREATE")
      ]
    -- 2. The session transcript (two-file) has the request + the responses.
    (msgs, entries) <- readTranscript
    length msgs `shouldSatisfy` (> 0)
    length entries `shouldSatisfy` (>= 2)  -- request + final response (tool turn adds entries too)
    -- 3. The model saw the final text.
    readIORef sent `shouldReturn` ["ollama/llama3> all four evolutionary mutations applied"]

  it "AGENT_START forks a worker in a fresh session; AGENT_STATUS reads Running; AGENT_STOP stops it (Trusted, not in Audited log)" $ do
    workerRan <- newIORef (0 :: Int)
    defBackend <- Def.noneBackend
    rt <- newAgentRuntime
    let sid = sampleSession
        reg = ISA.mkRegistry
          [ agentDefCreateOp defBackend sid
          , agentStartOp defBackend rt (pure sid) (\_ _ -> modifyIORef' workerRan (+1) >> threadDelay 1000000)
          , agentStatusOp rt
          , agentStopOp rt
          ]
        workerDef = case mkAgentDefId "worker" of
          Right aid -> aid
          Left _    -> error "unreachable: worker always validates"
    (tHandle, _) <- fakeTwoFileTranscript
    (audited, readAudited) <- fakeAuditedLog
    -- Define the agent via dispatch (Audited — lands in the Audited log).
    _ <- runTestApp (dispatch reg tHandle audited localBackend (OpName "AGENT_DEF_CREATE")
                       (object
                         [ "id" .= ("worker" :: Text)
                         , "name" .= ("worker" :: Text)
                         , "provider" .= ("ollama" :: Text)
                         , "model" .= ("llama3" :: Text)
                         ]))
    -- Start it via dispatch (Trusted — does NOT land in the Audited log).
    rStart <- runTestApp (dispatch reg tHandle audited localBackend (OpName "AGENT_START")
                            (object ["id" .= ("worker" :: Text)]))
    rStart `shouldSatisfy` isRight
    threadDelay 50000  -- let the fork run the worker
    readIORef workerRan `shouldReturn` 1
    mStatus <- agentStatus rt workerDef
    mStatus `shouldSatisfy` (Just Running ==)
    -- Stop it via dispatch (Trusted).
    rStop <- runTestApp (dispatch reg tHandle audited localBackend (OpName "AGENT_STOP")
                          (object ["id" .= ("worker" :: Text)]))
    rStop `shouldSatisfy` isRight
    agentStatus rt workerDef `shouldReturn` Nothing
    -- The Audited log has exactly ONE entry: the AGENT_DEF_CREATE. The two
    -- Trusted lifecycle ops (START/STOP) did NOT write to the Audited log.
    auditedEntries <- readAudited
    length auditedEntries `shouldBe` 1
    auditedKinds auditedEntries `shouldBe` [(AKAgentDef, OpName "AGENT_DEF_CREATE")]

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left _)  = False