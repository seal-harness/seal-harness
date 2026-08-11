{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.HumanSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.Either (isLeft)
import Data.IORef
import Data.Text (pack)
import qualified Data.Text
import Test.Hspec

import Seal.Channel.Caps
import Data.Default (def)
import Seal.Handles.AskReply (QuestionOption (..))
import Seal.ISA.Opcode
import Seal.ISA.Ops.Human
import Seal.Providers.Class
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env
import Seal.Logging.Logger (testSealLogger)

runTestApp :: App a -> IO a
runTestApp act = do logger <- testSealLogger; env <- mkEnv logger defaultConfig; runApp env act

fakeCaps :: IORef [String] -> String -> ChannelCaps
fakeCaps sent reply = def
  { ccSend = \t -> modifyIORef' sent (++ [show t])
  , ccPrompt = \_ -> pure (pack reply)
  , ccPromptSecret = \_ -> pure ""
  , ccStreaming    = True  -- tests: streaming by default
  }

-- | A 'ChannelCaps' that captures the 'AskPrompt' into an 'IORef' so a test
-- can assert the options reached the channel, then returns the canned reply.
fakeCapsCapture :: IORef [AskPrompt] -> String -> ChannelCaps
fakeCapsCapture captured reply = def
  { ccSend = \_ -> pure ()
  , ccPrompt = \ap -> modifyIORef' captured (ap :) >> pure (pack reply)
  , ccPromptSecret = \_ -> pure ""
  , ccStreaming    = True
  }

spec :: Spec
spec = describe "Seal.ISA.Ops.Human" $ do
  it "SHOW_HUMAN emits the message and returns no error" $ do
    sent <- newIORef []
    let op = showHumanOp (fakeCaps sent "")
    r <- runTestApp (opRun op localBackend (object ["message" .= ("hello" :: String)]))
    orIsError r `shouldBe` False
    readIORef sent `shouldReturn` ["\"hello\""]

  it "ASK_HUMAN returns the human reply as a tool-result part" $ do
    sent <- newIORef []
    let op = askHumanOp (fakeCaps sent "42")
    r <- runTestApp (opRun op localBackend (object ["question" .= ("n?" :: String)]))
    orParts r `shouldBe` [TrpText "42"]

  describe "ASK_HUMAN with options" $ do
    let optsJson = [object ["label" .= ("main" :: String), "description" .= ("the default branch" :: String)]
                   ,object ["label" .= ("develop" :: String), "description" .= ("the integration branch" :: String)]
                   ]
        inputWithOpts = object
          [ "question" .= ("which branch?" :: String)
          , "options" .= optsJson
          ]
        expectedOpts =
          [ QuestionOption "main" "the default branch"
          , QuestionOption "develop" "the integration branch"
          ]

    it "authorizes + runs with valid options; ccPrompt receives the options" $ do
      captured <- newIORef []
      let op = askHumanOp (fakeCapsCapture captured "main")
      opAuthorize op inputWithOpts `shouldBe` Right ()
      r <- runTestApp (opRun op localBackend inputWithOpts)
      orParts r `shouldBe` [TrpText "main"]
      orIsError r `shouldBe` False
      capturedApis <- readIORef captured
      case capturedApis of
        ap : _ -> do
          apQuestion ap `shouldBe` "which branch?"
          apOptions ap `shouldBe` expectedOpts
        [] -> expectationFailure "ccPrompt was not called"

    it "still works without options (open-ended, today's behavior)" $ do
      let inputNoOpts = object ["question" .= ("open?" :: String)]
          op = askHumanOp (fakeCaps (undefined :: IORef [String]) "ok")
      opAuthorize op inputNoOpts `shouldBe` Right ()
      r <- runTestApp (opRun op localBackend inputNoOpts)
      orParts r `shouldBe` [TrpText "ok"]

    it "rejects an empty options array" $
      opAuthorize (askHumanOp (fakeCaps undefined ""))
        (object ["question" .= ("q?" :: String), "options" .= ([] :: [Value])])
        `shouldSatisfy` isLeft

    it "rejects more than 8 options" $ do
      let manyOpts = [object ["label" .= Data.Text.pack ("l" <> show n)] | n <- [1 :: Int .. 9]]
      opAuthorize (askHumanOp (fakeCaps undefined ""))
        (object ["question" .= ("q?" :: String), "options" .= manyOpts])
        `shouldSatisfy` isLeft

    it "rejects an empty label" $
      opAuthorize (askHumanOp (fakeCaps undefined ""))
        (object ["question" .= ("q?" :: String), "options" .= [object ["label" .= ("" :: String)]]])
        `shouldSatisfy` isLeft

    it "rejects a label exceeding 64 bytes" $ do
      let longLabel = Data.Text.replicate 65 "x"
      opAuthorize (askHumanOp (fakeCaps undefined ""))
        (object ["question" .= ("q?" :: String), "options" .= [object ["label" .= longLabel]]])
        `shouldSatisfy` isLeft

    it "rejects duplicate labels" $
      opAuthorize (askHumanOp (fakeCaps undefined ""))
        (object [ "question" .= ("q?" :: String)
                , "options" .= [ object ["label" .= ("dup" :: String)]
                               , object ["label" .= ("dup" :: String)]
                               ]
                ])
        `shouldSatisfy` isLeft
