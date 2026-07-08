{-# LANGUAGE OverloadedStrings #-}
module Seal.Channel.WiringSpec (spec) where

import Data.IORef
import Test.Hspec

import Seal.Agent.Env
import Seal.Tools.Exec.Types (ExecBackend (..), mkLocalExecHandlePlaceholder)
import Seal.Channel.Cli
import Seal.Core.Types
import Seal.Handles.Transcript
import Seal.ISA.Opcode
import qualified Seal.ISA.Registry as ISA
import Seal.Providers.Class
import Seal.TestHelpers.FakeCaps
import Seal.Types.Config
import Seal.Types.Env

-- | A scripted provider: pops responses from the list in order;
-- returns a "done" sentinel when exhausted.
newtype ScriptProvider = ScriptProvider (IORef [CompletionResponse])

instance Provider ScriptProvider where
  listModels _ = pure (Right [])
  complete (ScriptProvider ref) _ = do
    rs <- readIORef ref
    case rs of
      (x:xs) -> writeIORef ref xs >> pure (Right x)
      []     -> pure (Right (CompletionResponse [CbText "done"] StopEnd (Usage 0 0)))

spec :: Spec
spec = describe "Seal.Channel.Cli.handlePlain" $
  it "routes a scripted provider response through runTurn to ccSend" $ do
    (fc, caps) <- makeFakeCaps []
    ref <- newIORef
             [ CompletionResponse [CbText "hello from model"] StopEnd (Usage 0 0) ]
    (h, _) <- fakeTwoFileTranscript
    let agentEnv = AgentEnv
          (SomeProvider (ScriptProvider ref))
          "ollama"
          (ModelId "test-model")
          Nothing
          (ISA.mkRegistry [])
          h
          localBackend
          (EbLocal mkLocalExecHandlePlaceholder)
          caps
          (either (error "sid") id (mkSessionId "cli"))
          4
          Nothing
    env <- mkEnv defaultConfig
    handlePlain agentEnv env "hi"
    sent <- getSent fc
    sent `shouldBe` ["ollama/test-model> hello from model"]
