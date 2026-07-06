{-# LANGUAGE OverloadedStrings #-}
-- | Phase 5 capstone: the end-to-end Definition-of-Done scenario, rewritten
-- for the git-backed design. One chat session creates a memory, recalls it,
-- defines a skill, defines an agent, starts the agent in a forked session,
-- and stops it — with every mutation landing as a Markdown file under
-- @config\/@ (disk is canonical) and auto-committed to the config git repo.
-- The session transcript stays in the two-file format.
module Seal.Phase5Spec (spec) where

import Control.Concurrent (threadDelay)
import Data.Aeson (object, (.=))
import Data.IORef
import Data.Text (Text)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Agent.Def.Backend qualified as Def
import Seal.Agent.Def.Types (mkAgentDefId)
import Seal.Agent.Env (AgentEnv (..))
import Seal.Agent.Loop (runTurn)
import Seal.Agent.Runtime.Registry
  ( AgentStatus (..), agentStatus, newAgentRuntime )
import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types (ModelId (..), OpName (..), SessionId (..), ToolCallId (..))
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo, gitHasCommits)
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
-- a final text response.
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

-- | Build the full ISA registry the capstone turn uses, backed by disk + git.
buildRegistry :: FilePath -> IORef Int -> SessionId -> IO ISA.Registry
buildRegistry cfgRoot workerRan sid = do
  let repo = openConfigRepo cfgRoot
  memBackend    <- Mem.markdownMemoryBackend (cfgRoot </> "memory") repo
  skillBackend  <- Skill.markdownSkillBackend (cfgRoot </> "skills") repo
  defBackend    <- Def.markdownAgentDefBackend (cfgRoot </> "agents") repo
  rt            <- newAgentRuntime
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

spec :: Spec
spec = describe "Phase 5 capstone (DoD scenario, git-backed)" $ do
  it "one chat turn: MEMORY_STORE + RECALL + SKILL_CREATE + AGENT_DEF_CREATE — files land on disk + git, transcript in two-file format" $
    withSystemTempDirectory "seal-phase5" $ \root -> do
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
                  , aeCaps = caps
                  , aeSession = sampleSession
                  , aeMaxTurns = 8
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

  it "AGENT_START forks a worker; AGENT_STATUS reads Running; AGENT_STOP stops it (Trusted file-write, no Audited log)" $
    withSystemTempDirectory "seal-phase5" $ \root -> do
      let cfgRoot = root </> "config"
      ensureConfigRepo cfgRoot
      workerRan <- newIORef (0 :: Int)
      defBackend <- Def.markdownAgentDefBackend (cfgRoot </> "agents") (openConfigRepo cfgRoot)
      rt <- newAgentRuntime
      let sid = sampleSession
          reg = ISA.mkRegistry
            [ agentDefCreateOp defBackend sid
            , agentStartOp defBackend rt (pure sid) (\_ _ -> modifyIORef' workerRan (+1) >> threadDelay 1000000)
            , agentStatusOp rt
            , agentStopOp rt
            ]
      (tHandle, _) <- fakeTwoFileTranscript
      -- Define the agent via dispatch (writes the file + auto-commits).
      _ <- runTestApp (dispatch reg tHandle localBackend (OpName "AGENT_DEF_CREATE")
                         (object
                           [ "id" .= ("worker" :: Text)
                           , "name" .= ("worker" :: Text)
                           , "provider" .= ("ollama" :: Text)
                           , "model" .= ("llama3" :: Text)
                           ]))
      -- The def file landed on disk.
      doesFileExist (cfgRoot </> "agents" </> "worker.md") `shouldReturn` True
      -- Start it via dispatch (Trusted — no file write, just runtime).
      rStart <- runTestApp (dispatch reg tHandle localBackend (OpName "AGENT_START")
                              (object ["id" .= ("worker" :: Text)]))
      rStart `shouldSatisfy` isRight
      threadDelay 50000
      readIORef workerRan `shouldReturn` 1
      let workerDef = case mkAgentDefId "worker" of
            Right aid -> aid
            Left _    -> error "unreachable: worker always validates"
      mStatus <- agentStatus rt workerDef
      mStatus `shouldSatisfy` (Just Running ==)
      -- Stop it via dispatch (Trusted).
      rStop <- runTestApp (dispatch reg tHandle localBackend (OpName "AGENT_STOP")
                            (object ["id" .= ("worker" :: Text)]))
      rStop `shouldSatisfy` isRight
      agentStatus rt workerDef `shouldReturn` Nothing

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left _)  = False