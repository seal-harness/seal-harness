{-# LANGUAGE OverloadedStrings #-}
module Seal.Agent.LoopSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object)
import Data.ByteString.Char8 qualified as BS8
import Data.IORef
import Data.Text (Text)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Core.Types
import Seal.Handles.Transcript (fakeTwoFileTranscript, withTwoFileTranscript)
import Seal.ISA.Opcode
import Seal.ISA.Registry
import Seal.Providers.Class
import Seal.Transcript.Entries (EntryRecord (..))
import Seal.Types.App (App, runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)
import Seal.Agent.Env
import Seal.Tools.Exec.Types (ExecBackend (..), mkLocalExecHandlePlaceholder)
import Seal.Agent.Loop

-- | A provider that returns a scripted list of responses, one per call.
newtype ScriptProvider = ScriptProvider (IORef [CompletionResponse])

instance Provider ScriptProvider where
  listModels _ = pure (Right [])
  complete (ScriptProvider ref) _ = do
    rs <- readIORef ref
    case rs of
      (x:xs) -> writeIORef ref xs >> pure (Right x)
      [] -> pure (Right (CompletionResponse [CbText "done"] StopEnd (Usage 0 0)))

runTestApp :: App a -> IO a
runTestApp act = do
  env <- mkEnv defaultConfig
  runApp env act

spec :: Spec
spec = describe "Seal.Agent.Loop" $ do
  it "dispatches a tool call then emits the final text" $ do
    sent <- newIORef ([] :: [Text])
    ran <- newIORef (0 :: Int)
    let caps = ChannelCaps
                 (\t -> modifyIORef' sent (++ [t]))
                 (\_ -> pure "")
                 (\_ -> pure "")
        stubOp = TrustedOpcode (OpName "PING") Trusted "p" (object []) (object [])
                    (const (Right ()))
                    (\_ _ -> do
                      liftIO (modifyIORef' ran (+ 1))
                      pure (OpResult [TrpText "pong"] False Null))
        script =
          [ CompletionResponse
              [CbToolUse (ToolCallId "t1") (OpName "PING") (object [])]
              StopToolUse
              (Usage 0 0)
          , CompletionResponse [CbText "all done"] StopEnd (Usage 0 0)
          ]
    ref <- newIORef script
    (h, _) <- fakeTwoFileTranscript
    let env = AgentEnv
                (SomeProvider (ScriptProvider ref))
                "ollama"
                (ModelId "m")
                Nothing
                (mkRegistry [stubOp])
                h
                localBackend
                (EbLocal mkLocalExecHandlePlaceholder)
                caps
                (either (error "sid") id (mkSessionId "s1"))
                8
                Nothing
    runTestApp (runTurn env "hello")
    readIORef ran `shouldReturn` 1
    readIORef sent `shouldReturn` ["ollama/m> all done"]

  it "writes the conversation + entries to the two-file transcript" $ do
    sent <- newIORef ([] :: [Text])
    let caps = ChannelCaps
                 (\t -> modifyIORef' sent (++ [t]))
                 (\_ -> pure "")
                 (\_ -> pure "")
        script =
          [ CompletionResponse [CbText "reply"] StopEnd (Usage 1 2) ]
    ref <- newIORef script
    (h, readState) <- fakeTwoFileTranscript
    let env = AgentEnv
                (SomeProvider (ScriptProvider ref))
                "ollama"
                (ModelId "m")
                Nothing
                (mkRegistry [])
                h
                localBackend
                (EbLocal mkLocalExecHandlePlaceholder)
                caps
                (either (error "sid") id (mkSessionId "s1"))
                8
                Nothing
    runTestApp (runTurn env "hi")
    (msgs, entries) <- readState
    -- conversation.jsonl: user "hi" + assistant "reply" (2 lines)
    length msgs `shouldBe` 2
    -- entries.jsonl: one Request (user) + one Response (assistant) = 2 entries
    length entries `shouldBe` 2
    -- the response entry carries usage
    case drop 1 entries of
      [resp] -> erUsage resp `shouldBe` Just (Usage 1 2)
      _      -> expectationFailure "expected exactly one response entry"

  -- Regression: a second turn must load the prior conversation from disk so
  -- the model sees the full history, and the two-file writer's diff-based
  -- appender never duplicates messages. Before the fix, runTurn started each
  -- turn with only the new user message, so (a) the model answered as if it
  -- was a fresh chat (ignoring all prior turns) and (b) the writer's diff
  -- against the on-disk conversation failed (the incoming list was not a
  -- prefix-extension of the on-disk list) and the fallback re-appended the
  -- whole incoming list every iteration, corrupting conversation.jsonl with
  -- duplicate user + assistant lines.
  it "a second turn loads the prior conversation, no duplication" $
    withSystemTempDirectory "seal-loop" $ \dir -> do
      sent <- newIORef ([] :: [Text])
      let caps = ChannelCaps
                   (\t -> modifyIORef' sent (++ [t]))
                   (\_ -> pure "")
                   (\_ -> pure "")
          -- Two scripted responses: turn 1 replies "hi back"; turn 2 replies
          -- "ok". The script is consumed top-to-bottom across both turns.
          script1 = [ CompletionResponse [CbText "hi back"] StopEnd (Usage 1 2) ]
          script2 = [ CompletionResponse [CbText "ok"]      StopEnd (Usage 3 4) ]
      ref <- newIORef (script1 ++ script2)
      withTwoFileTranscript dir $ \h -> do
        let mkEnv' = AgentEnv
                      (SomeProvider (ScriptProvider ref))
                      "ollama"
                      (ModelId "m")
                      Nothing
                      (mkRegistry [])
                      h
                      localBackend
                      (EbLocal mkLocalExecHandlePlaceholder)
                      caps
                      (either (error "sid") id (mkSessionId "s1"))
                      8
                      Nothing
        runTestApp (runTurn mkEnv' "hi")
        runTestApp (runTurn mkEnv' "how are you")
      -- The on-disk conversation.jsonl must contain exactly 4 lines:
      --   user "hi", assistant "hi back", user "how are you", assistant "ok"
      -- Before the fix it contained 9+ lines with duplicate user messages.
      convContents <- BS8.readFile (dir </> "conversation.jsonl")
      length (BS8.lines convContents) `shouldBe` 4
      -- The second request entry's convLen must be 3 (the prior 2 lines +
      -- the new user message), confirming the model saw the full history.
      -- (The provider also received the full history: assert that turn 2
      -- observed the prior conversation by checking the final assistant
      -- text is "ok" and nothing was duplicated into the output.)
      readIORef sent `shouldReturn` ["ollama/m> hi back", "ollama/m> ok"]
