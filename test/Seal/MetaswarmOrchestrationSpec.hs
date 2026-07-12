{-# LANGUAGE OverloadedStrings #-}
-- | High-level integration test: a complex orchestrated task causes the
-- orchestrator to define and start multiple sub-agents, read a skill, and
-- manage the sub-agent lifecycle — simulating the metaswarm 4-phase execution
-- loop (IMPLEMENT → VALIDATE → ADVERSARIAL REVIEW → COMMIT).
--
-- The test models the metaswarm "issue-orchestrator" pattern:
--
-- 1. The orchestrator reads the @orchestrated-execution@ skill to get the
--    4-phase workflow.
-- 2. It defines three sub-agent definitions: @architect-agent@ (planning),
--    @coder-agent@ (implementation), and @code-review-agent@ (adversarial
--    review) via @AGENT_DEF_WRITE@.
-- 3. It starts all three via @AGENT_START@ (they fork as workers).
-- 4. It verifies all three are @Running@ via @AGENT_STATUS@.
-- 5. It lists them via @AGENT_INSTANCES@.
-- 6. It stops all three via @AGENT_STOP@.
--
-- The workers are stub @IO ()@ actions that increment a counter and sleep,
-- proving the fork fired. The provider is a scripted list of responses that
-- emits the tool calls in the right order across one turn.
module Seal.MetaswarmOrchestrationSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Data.Aeson (object, (.=))
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.Directory (doesFileExist)
import System.FilePath ((</>), (<.>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Agent.Def.Backend qualified as Def
import Seal.Agent.Def.Types (AgentDef (..), mkAgentDefId, agentDefIdText)
import Seal.Agent.Env (AgentEnv (..))
import Seal.Agent.Loop (runTurn)
import Seal.Agent.Runtime.Registry
  ( agentStatus, newAgentRuntime )
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types (ModelId (..), OpName (..), SessionId (..), ToolCallId (..))
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo)
import Seal.Handles.Transcript (fakeTwoFileTranscript)
import Seal.ISA.Dispatch (dispatch)
import Seal.ISA.Opcode (localBackend, OpResult (..))
import Seal.ISA.Ops.Agent
  ( agentDefWriteOp, agentDefReadOp, agentDefListOp, agentDefDeleteOp
  , agentInstancesOp, agentStartOp, agentStatusOp, agentStopOp )
import Seal.ISA.Ops.Skills
  ( skillWriteOp, skillListOp, skillReadOp, skillDeleteOp )
import Seal.ISA.Ops.Memory
  ( memoryWriteOp, memoryRecallOp, memoryDeleteOp )
import Seal.ISA.Registry qualified as ISA
import Seal.Memory.Backend qualified as Mem
import Seal.Providers.Class
  ( CompletionResponse (..), ContentBlock (..), Provider (..)
  , StopReason (..), Usage (..), SomeProvider (..) )
import Seal.Skills.Backend qualified as Skill
import Seal.Skills.Types (Skill (..), mkSkillId)
import Seal.Tools.Exec.Types (ExecBackend (..), mkLocalExecHandlePlaceholder)
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
sampleSession = SessionId "orch-1"

-- | The three sub-agent ids the orchestrator will define + start.
subAgentIds :: [Text]
subAgentIds = ["architect-agent", "coder-agent", "code-review-agent"]

-- | Build the full ISA registry with agent-def, skill, and agent-lifecycle
-- opcodes, backed by disk + git. The worker-builder stubs fork a counter
-- increment + sleep so we can verify the fork fired.
buildRegistry :: FilePath -> IORef Int -> SessionId -> IO ISA.Registry
buildRegistry cfgRoot workerRan sid = do
  let repo = openConfigRepo cfgRoot
  memBackend   <- Mem.markdownMemoryBackend (cfgRoot </> "memory") repo
  skillBackend <- Skill.markdownSkillBackend (cfgRoot </> "skills") repo
  defBackend   <- Def.markdownAgentDefBackend (cfgRoot </> "agents") repo
  rt           <- newAgentRuntime
  pure $ ISA.mkRegistry
    [ memoryWriteOp memBackend sid
    , memoryRecallOp defaultPageParams memBackend
    , memoryDeleteOp memBackend
    , skillWriteOp skillBackend sid
    , skillReadOp skillBackend
    , skillDeleteOp skillBackend
    , skillListOp skillBackend
    , agentDefWriteOp defBackend sid
    , agentDefReadOp defBackend
    , agentDefListOp defBackend
    , agentDefDeleteOp defBackend
    , agentInstancesOp rt
    , agentStartOp defBackend rt (pure sid) (\_ _ -> modifyIORef' workerRan (+1) >> threadDelay 1000000)
    , agentStatusOp rt
    , agentStopOp rt
    ]

-- | Build the orchestrated-execution skill content (a representative excerpt).
orchestratedExecutionSkill :: Text
orchestratedExecutionSkill = T.unlines
  [ "# Orchestrated Execution Skill"
  , ""
  , "Core principle: Trust nothing. Verify everything. Review adversarially."
  , ""
  , "4-phase loop: IMPLEMENT -> VALIDATE -> ADVERSARIAL REVIEW -> COMMIT"
  ]

-- | The orchestrator's first-turn script: emit tool calls to
--
--   1. SKILL_READ the orchestrated-execution skill,
--   2. AGENT_DEF_WRITE for all three sub-agents,
--   3. AGENT_START for all three sub-agents,
--
--   then a second response with AGENT_STATUS for each, then a third response
--   with AGENT_INSTANCES, then a final text response.
orchestratorScript :: [CompletionResponse]
orchestratorScript =
  -- Response 1: read skill + define 3 agents
  [ CompletionResponse
      [ CbToolUse (ToolCallId "t1") (OpName "SKILL_READ")
          (object ["id" .= ("orchestrated-execution" :: Text)])
      , CbToolUse (ToolCallId "t2") (OpName "AGENT_DEF_WRITE")
          (object
            [ "id" .= ("architect-agent" :: Text)
            , "name" .= ("Architect Agent" :: Text)
            , "provider" .= ("ollama" :: Text)
            , "model" .= ("glm-5.2:cloud" :: Text)
            ])
      , CbToolUse (ToolCallId "t3") (OpName "AGENT_DEF_WRITE")
          (object
            [ "id" .= ("coder-agent" :: Text)
            , "name" .= ("Coder Agent" :: Text)
            , "provider" .= ("ollama" :: Text)
            , "model" .= ("glm-5.2:cloud" :: Text)
            ])
      , CbToolUse (ToolCallId "t4") (OpName "AGENT_DEF_WRITE")
          (object
            [ "id" .= ("code-review-agent" :: Text)
            , "name" .= ("Code Review Agent" :: Text)
            , "provider" .= ("ollama" :: Text)
            , "model" .= ("glm-5.2:cloud" :: Text)
            ])
      ]
      StopToolUse
      (Usage 0 0)
  -- Response 2: start all 3 agents
  , CompletionResponse
      [ CbToolUse (ToolCallId "t5") (OpName "AGENT_START")
          (object ["id" .= ("architect-agent" :: Text)])
      , CbToolUse (ToolCallId "t6") (OpName "AGENT_START")
          (object ["id" .= ("coder-agent" :: Text)])
      , CbToolUse (ToolCallId "t7") (OpName "AGENT_START")
          (object ["id" .= ("code-review-agent" :: Text)])
      ]
      StopToolUse
      (Usage 0 0)
  -- Response 3: check status of all 3 agents
  , CompletionResponse
      [ CbToolUse (ToolCallId "t8") (OpName "AGENT_STATUS")
          (object ["id" .= ("architect-agent" :: Text)])
      , CbToolUse (ToolCallId "t9") (OpName "AGENT_STATUS")
          (object ["id" .= ("coder-agent" :: Text)])
      , CbToolUse (ToolCallId "t10") (OpName "AGENT_STATUS")
          (object ["id" .= ("code-review-agent" :: Text)])
      ]
      StopToolUse
      (Usage 0 0)
  -- Response 4: list all running agents
  , CompletionResponse
      [ CbToolUse (ToolCallId "t11") (OpName "AGENT_INSTANCES") (object []) ]
      StopToolUse
      (Usage 0 0)
  -- Response 5: stop all 3 agents
  , CompletionResponse
      [ CbToolUse (ToolCallId "t12") (OpName "AGENT_STOP")
          (object ["id" .= ("architect-agent" :: Text)])
      , CbToolUse (ToolCallId "t13") (OpName "AGENT_STOP")
          (object ["id" .= ("coder-agent" :: Text)])
      , CbToolUse (ToolCallId "t14") (OpName "AGENT_STOP")
          (object ["id" .= ("code-review-agent" :: Text)])
      ]
      StopToolUse
      (Usage 0 0)
  -- Response 6: final summary text
  , CompletionResponse
      [CbText "Orchestration complete: 3 agents defined, started, reviewed, and stopped."]
      StopEnd
      (Usage 0 0)
  ]

spec :: Spec
spec = describe "Metaswarm orchestration integration" $ do
  it "a complex task: orchestrator reads skill, defines 3 sub-agents, starts all 3, checks status, lists, and stops them" $
    withSystemTempDirectory "seal-metaswarm" $ \root -> do
      let cfgRoot = root </> "config"
      ensureConfigRepo cfgRoot
      sent <- newIORef ([] :: [Text])
      workerRan <- newIORef (0 :: Int)
      let caps = ChannelCaps
                   (\t -> modifyIORef' sent (++ [t]))
                   (\_ -> pure "")
                   (\_ -> pure "")
      reg <- buildRegistry cfgRoot workerRan sampleSession

      -- Pre-populate the orchestrated-execution skill so SKILL_READ succeeds.
      let repo = openConfigRepo cfgRoot
      skillBackend <- Skill.markdownSkillBackend (cfgRoot </> "skills") repo
      let skillBody = orchestratedExecutionSkill
      case mkSkillId "orchestrated-execution" of
        Right sid -> do
          now <- getCurrentTime
          Skill.sbCreate skillBackend Skill
            { skId = sid
            , skDescription = "4-phase execution loop"
            , skBody = skillBody
            , skCreatedAt = now
            , skUpdatedAt = now
            , skSession = sampleSession
            }
        Left _ -> expectationFailure "invalid skill id"

      -- Run the orchestrator turn.
      ref <- newIORef orchestratorScript
      (tHandle, readTranscript) <- fakeTwoFileTranscript
      let env = AgentEnv
                  { aeProvider = SomeProvider (ScriptProvider ref)
                  , aeProviderLabel = "ollama"
                  , aeModel = ModelId "glm-5.2:cloud"
                  , aeSystem = Just "You are the issue-orchestrator. Coordinate sub-agents."
                  , aeRegistry = reg
                  , aeTranscript = tHandle
                  , aeBackend = localBackend
                  , aeExecBackend = EbLocal mkLocalExecHandlePlaceholder
                  , aeCaps = caps
                  , aeSession = sampleSession
                  , aeMaxTurns = 20
                  , aeMessageSource = Nothing
                  , aeDebugRequestsPath = Nothing
                  }
      runTestApp (runTurn env "Execute task #42: implement the feature following the 4-phase loop")

      -- 1. All three agent def files landed on disk.
      forM_ subAgentIds $ \aid -> do
        doesFileExist (cfgRoot </> "agents" </> T.unpack aid <.> "md") `shouldReturn` True

      -- 2. All three workers were forked (AGENT_START fired 3 times).
      readIORef workerRan `shouldReturn` 3

      -- 3. The orchestrator emitted the final summary text.
      sentMsgs <- readIORef sent
      last sentMsgs `shouldSatisfy` ("Orchestration complete" `T.isInfixOf`)

      -- 4. The session transcript recorded the full interaction.
      (msgs, entries) <- readTranscript
      length msgs `shouldSatisfy` (> 0)
      length entries `shouldSatisfy` (>= 8)

      -- 5. Verify the agent def files are readable and have the right names.
      defBackend <- Def.markdownAgentDefBackend (cfgRoot </> "agents") (openConfigRepo cfgRoot)
      defs <- Def.adbList defBackend
      length defs `shouldBe` 3
      let defIds = map (agentDefIdText . adId) defs
      forM_ subAgentIds $ \aid ->
        defIds `shouldSatisfy` (aid `elem`)

      -- 6. The skill file landed on disk and is readable.
      doesFileExist (cfgRoot </> "skills" </> "orchestrated-execution.md") `shouldReturn` True

  it "AGENT_START rejects a duplicate start for an already-running agent" $
    withSystemTempDirectory "seal-metaswarm-dup" $ \root -> do
      let cfgRoot = root </> "config"
      ensureConfigRepo cfgRoot
      workerRan <- newIORef (0 :: Int)
      defBackend <- Def.markdownAgentDefBackend (cfgRoot </> "agents") (openConfigRepo cfgRoot)
      rt <- newAgentRuntime
      let sid = sampleSession
          reg = ISA.mkRegistry
            [ agentDefWriteOp defBackend sid
            , agentStartOp defBackend rt (pure sid) (\_ _ -> modifyIORef' workerRan (+1) >> threadDelay 1000000)
            , agentStatusOp rt
            , agentStopOp rt
            ]
      (tHandle, _) <- fakeTwoFileTranscript
      -- Define the agent.
      _ <- runTestApp (dispatch reg tHandle localBackend (EbLocal mkLocalExecHandlePlaceholder)
                         (OpName "AGENT_DEF_WRITE")
                         (object
                           [ "id" .= ("coder-agent" :: Text)
                           , "name" .= ("Coder Agent" :: Text)
                           , "provider" .= ("ollama" :: Text)
                           , "model" .= ("glm-5.2:cloud" :: Text)
                           ]))
      -- Start it.
      r1 <- runTestApp (dispatch reg tHandle localBackend (EbLocal mkLocalExecHandlePlaceholder)
                          (OpName "AGENT_START")
                          (object ["id" .= ("coder-agent" :: Text)]))
      r1 `shouldSatisfy` isRight
      threadDelay 50000
      -- Start it again — should produce an error result ("agent already running").
      r2 <- runTestApp (dispatch reg tHandle localBackend (EbLocal mkLocalExecHandlePlaceholder)
                          (OpName "AGENT_START")
                          (object ["id" .= ("coder-agent" :: Text)]))
      r2 `shouldSatisfy` either (const True) orIsError
      -- Only one worker forked.
      readIORef workerRan `shouldReturn` 1
      -- Stop it.
      _ <- runTestApp (dispatch reg tHandle localBackend (EbLocal mkLocalExecHandlePlaceholder)
                          (OpName "AGENT_STOP")
                          (object ["id" .= ("coder-agent" :: Text)]))
      let coderDef = case mkAgentDefId "coder-agent" of
            Right aid -> aid
            Left _    -> error "unreachable"
      agentStatus rt coderDef `shouldReturn` Nothing

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left _)  = False