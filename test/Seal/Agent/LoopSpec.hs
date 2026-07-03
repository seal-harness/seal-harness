{-# LANGUAGE OverloadedStrings #-}
module Seal.Agent.LoopSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object)
import Data.IORef
import Data.Text (Text)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Core.Types
import Seal.Handles.Transcript (fakeTranscript)
import Seal.ISA.Opcode
import Seal.ISA.Registry
import Seal.Providers.Class
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
spec = describe "Seal.Agent.Loop" $
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
    (h, _) <- fakeTranscript
    let env = AgentEnv
                (SomeProvider (ScriptProvider ref))
                "ollama"
                (ModelId "m")
                (mkRegistry [stubOp])
                h
                localBackend
                caps
                (either (error "sid") id (mkSessionId "s1"))
                8
    runTestApp (runTurn env "hello")
    readIORef ran `shouldReturn` 1
    readIORef sent `shouldReturn` ["ollama/m> all done"]
