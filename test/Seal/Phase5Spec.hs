{-# LANGUAGE OverloadedStrings #-}
-- | Phase 5 capstone: the end-to-end Definition-of-Done scenario, rewritten
-- for the git-backed design. One chat session creates a memory, recalls it,
-- defines a skill, defines an agent, starts the agent in a forked session,
-- and stops it — with every mutation landing as a Markdown file under
-- @config\/@ (disk is canonical) and auto-committed to the config git repo.
-- The session transcript stays in the two-file format.
module Seal.Phase5Spec (spec) where

import Data.Aeson (object, (.=))
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Agent.Def.Backend qualified as Def
import Seal.Agent.Env (AgentEnv (..))
import Seal.Agent.Loop (runTurn)
import Seal.Agent.Runtime.Delegation
  ( ChildWorkerOutcome (..), ChildExitReason (..)
  , defaultDelegationConfig, newSpawnPauseFlag )
import Seal.Agent.Runtime.Registry
  ( newAgentRuntime )
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types (ModelId (..), OpName (..), SessionId, mkSystemSessionId, ToolCallId (..))
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo, gitHasCommits)
import Seal.Handles.AskReply (newApprovalCache)
import Seal.Handles.Transcript (fakeTwoFileTranscript)
import Seal.ISA.Dispatch (dispatch)
import Seal.ISA.Opcode (localBackend, OpResult (..))
import Seal.Tools.Exec.UntrustedIO (mkRemoteUntrustedIOStub)
import Seal.ISA.Ops.Agent
  ( agentDefWriteOp, agentDefReadOp, agentInstancesOp
  , agentStartOp, agentStatusOp, agentStopOp, agentInterruptOp
  , AgentStartWiring (..) )
import Seal.ISA.Ops.Memory
  ( memoryDeleteOp, memoryRecallOp, memoryWriteOp )
import Seal.ISA.Ops.Skills
  ( skillDeleteOp, skillListOp, skillLoadOp, skillWriteOp )
import Seal.ISA.Registry qualified as ISA
import Seal.Memory.Backend qualified as Mem
import Seal.Providers.Class
  ( ToolResultPart (..), CompletionResponse (..), ContentBlock (..), Provider (..)
  , StopReason (..), Usage (..), SomeProvider (..) )
import Seal.Skills.Backend qualified as Skill
import Seal.Security.Policy (AutonomyLevel (..))
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
sampleSession = mkSystemSessionId "s1"

-- | The script for the capstone turn: the model emits four tool calls in one
-- response (MEMORY_WRITE, MEMORY_RECALL, SKILL_WRITE, AGENT_DEF_WRITE), then
-- a final text response.
capstoneScript :: [CompletionResponse]
capstoneScript =
  [ CompletionResponse
      [ CbToolUse (ToolCallId "t1") (OpName "MEMORY_WRITE")
          (object
            [ "id" .= ("greeting" :: Text)
            , "content" .= ("hello world" :: Text)
            ])
      , CbToolUse (ToolCallId "t2") (OpName "MEMORY_RECALL") (object [])
      , CbToolUse (ToolCallId "t3") (OpName "SKILL_WRITE")
          (object
            [ "id" .= ("greet" :: Text)
            , "description" .= ("greeting skill" :: Text)
            , "body" .= ("say hello warmly" :: Text)
            ])
      , CbToolUse (ToolCallId "t4") (OpName "AGENT_DEF_WRITE")
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

-- | Build the full ISA registry the capstone turn uses, backed by disk + git.
buildRegistry :: FilePath -> IORef Int -> SessionId -> IO ISA.Registry
buildRegistry cfgRoot workerRan sid = do
  let repo = openConfigRepo cfgRoot
  memBackend    <- Mem.markdownMemoryBackend (cfgRoot </> "memory") repo
  skillBackend  <- Skill.markdownSkillBackend (cfgRoot </> "skills") repo
  defBackend    <- Def.markdownAgentDefBackend (cfgRoot </> "agents") repo
  rt            <- newAgentRuntime
  pauseFlag     <- newSpawnPauseFlag
  let worker _ _ _ _ = do
        modifyIORef' workerRan (+1)
        pure (ChildWorkerOutcome (Just "worker done") CerCompleted 0 0 (Just sid))
      startWiring = AgentStartWiring
        { aswDefBackend = defBackend
        , aswRuntime = rt
        , aswConfig = pure defaultDelegationConfig
        , aswPauseFlag = pauseFlag
        , aswParentActivity = Nothing
        , aswMintSession = pure sid
        , aswParentDepth = 0
        , aswWorker = worker
        }
  pure $ ISA.mkRegistry
    [ memoryWriteOp memBackend sid
    , memoryRecallOp defaultPageParams memBackend
    , memoryDeleteOp memBackend
    , skillWriteOp skillBackend sid
    , skillLoadOp skillBackend
    , skillListOp skillBackend
    , skillDeleteOp skillBackend
    , agentDefWriteOp defBackend sid
    , agentDefReadOp defBackend
    , agentInstancesOp rt
    , agentStartOp startWiring
    , agentStatusOp rt
    , agentStopOp rt
    , agentInterruptOp rt
    ]

spec :: Spec
spec = describe "Phase 5 capstone (DoD scenario, git-backed)" $ do
  it "one chat turn: MEMORY_WRITE + RECALL + SKILL_WRITE + AGENT_DEF_WRITE — files land on disk + git, transcript in two-file format" $
    withSystemTempDirectory "seal-phase5" $ \root -> do
      approvals <- newApprovalCache
      let cfgRoot = root </> "config"
      ensureConfigRepo cfgRoot
      sent <- newIORef ([] :: [Text])
      workerRan <- newIORef (0 :: Int)
      let caps = ChannelCaps
                   (\t -> modifyIORef' sent (++ [t]))
                   (\_ -> pure "")
                   (\_ -> pure "")
      reg <- buildRegistry cfgRoot workerRan sampleSession
      ref <- newIORef capstoneScript
      (tHandle, readTranscript) <- fakeTwoFileTranscript
      let env = AgentEnv
                  { aeProvider = SomeProvider (ScriptProvider ref)
                  , aeProviderLabel = "ollama"
                  , aeModel = ModelId "llama3"
                  , aeSystem = Nothing
                  , aeRegistry = reg
                  , aeTranscript = tHandle
                  , aeBackend = localBackend
                  , aeUntrustedIO = mkRemoteUntrustedIOStub
                  , aeCaps = caps
                  , aeSession = sampleSession
                  , aeMaxTurns = 8
                  , aeMessageSource = Nothing
                  , aeAutonomy = Full
                , aeApprovals = approvals
                  , aeDebugRequestsPath = Nothing
                  , aeOnEntry = pure ()
                  , aeOnDemandSchemas = False
                  , aeLogPath = Nothing
                  }
      runTestApp (runTurn env "run the capstone")
      -- 1. Each mutation landed as a Markdown file under config/.
      doesFileExist (cfgRoot </> "memory" </> "greeting.md") `shouldReturn` True
      doesFileExist (cfgRoot </> "skills" </> "greet.md") `shouldReturn` True
      doesFileExist (cfgRoot </> "agents" </> "worker.md") `shouldReturn` True
      -- 2. The config git repo has commits (the auto-commits fired).
      gitHasCommits (openConfigRepo cfgRoot) `shouldReturn` True
      -- 3. The session transcript (two-file) has the request + responses.
      (msgs, entries) <- readTranscript
      length msgs `shouldSatisfy` (> 0)
      length entries `shouldSatisfy` (>= 2)
      -- 4. The model saw the final text.
      readIORef sent `shouldReturn` ["ollama/llama3> all four evolutionary mutations applied"]

  it "AGENT_START runs synchronously and returns a summary (Trusted, no Audited log)" $
    withSystemTempDirectory "seal-phase5" $ \root -> do
      let cfgRoot = root </> "config"
      ensureConfigRepo cfgRoot
      workerRan <- newIORef (0 :: Int)
      defBackend <- Def.markdownAgentDefBackend (cfgRoot </> "agents") (openConfigRepo cfgRoot)
      rt <- newAgentRuntime
      pauseFlag <- newSpawnPauseFlag
      let sid = sampleSession
          worker _ _ _ _ = do
            modifyIORef' workerRan (+1)
            pure (ChildWorkerOutcome (Just "worker done") CerCompleted 0 0 (Just sid))
          startWiring = AgentStartWiring
            { aswDefBackend = defBackend
            , aswRuntime = rt
            , aswConfig = pure defaultDelegationConfig
            , aswPauseFlag = pauseFlag
            , aswParentActivity = Nothing
            , aswMintSession = pure sid
            , aswParentDepth = 0
            , aswWorker = worker
            }
          reg = ISA.mkRegistry
            [ agentDefWriteOp defBackend sid
            , agentStartOp startWiring
            , agentStatusOp rt
            , agentStopOp rt
            , agentInterruptOp rt
            ]
      (tHandle, _) <- fakeTwoFileTranscript
      -- Define the agent via dispatch (writes the file + auto-commits).
      _ <- runTestApp (dispatch reg tHandle localBackend mkRemoteUntrustedIOStub (OpName "AGENT_DEF_WRITE")
                         (object
                           [ "id" .= ("worker" :: Text)
                           , "name" .= ("worker" :: Text)
                           , "provider" .= ("ollama" :: Text)
                           , "model" .= ("llama3" :: Text)
                           ]))
      -- The def file landed on disk.
      doesFileExist (cfgRoot </> "agents" </> "worker.md") `shouldReturn` True
      -- Start it via dispatch (synchronous — the worker runs to completion
      -- before dispatch returns; no AGENT_STATUS Running state to observe).
      rStart <- runTestApp (dispatch reg tHandle localBackend mkRemoteUntrustedIOStub (OpName "AGENT_START")
                            (object ["id" .= ("worker" :: Text), "goal" .= ("do work" :: Text)]))
      rStart `shouldSatisfy` isRight
      -- Synchronous: the worker has already run exactly once.
      readIORef workerRan `shouldReturn` 1
      -- The result text carries the summary.
      case rStart of
        Right res -> case orParts res of
          [TrpText t] -> T.isInfixOf "worker done" t `shouldBe` True
          _           -> expectationFailure "expected a single text part"
        Left _ -> expectationFailure "dispatch failed"

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left _)  = False