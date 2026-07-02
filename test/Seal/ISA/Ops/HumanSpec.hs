{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.HumanSpec (spec) where

import Data.Aeson (object, (.=))
import Data.IORef
import Data.Text (pack)
import Test.Hspec

import Seal.Channel.Caps
import Seal.ISA.Opcode
import Seal.ISA.Ops.Human
import Seal.Providers.Class
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env

runTestApp :: App a -> IO a
runTestApp act = do env <- mkEnv defaultConfig; runApp env act

fakeCaps :: IORef [String] -> String -> ChannelCaps
fakeCaps sent reply = ChannelCaps
  { ccSend = \t -> modifyIORef' sent (++ [show t])
  , ccPrompt = \_ -> pure (pack reply)
  , ccPromptSecret = \_ -> pure ""
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
