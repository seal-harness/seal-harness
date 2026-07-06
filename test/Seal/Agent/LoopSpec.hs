{-# LANGUAGE OverloadedStrings #-}
module Seal.Agent.LoopSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object)
import Data.IORef
import Data.Text (Text)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Core.Types
import Seal.Handles.Transcript (fakeTwoFileTranscript)
import Seal.ISA.Opcode
import Seal.ISA.Registry
import Seal.Providers.Class
import Seal.Transcript.Entries (EntryRecord (..))
import Seal.Types.App (App, runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)
import Seal.Agent.Env
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
        stubOp = Opcode (OpName "PING") Trusted "p" (object []) (object [])
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
                caps
                (either (error "sid") id (mkSessionId "s1"))
                8
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
                caps
                (either (error "sid") id (mkSessionId "s1"))
                8
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
