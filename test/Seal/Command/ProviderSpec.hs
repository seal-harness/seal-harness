{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.ProviderSpec (spec) where

import Data.Text qualified as T
import Test.Hspec

import Seal.Command.Provider (formatTestResult, pingRequest)
import Seal.Core.Types (ModelId (..))
import Seal.Providers.Class
  ( CompletionRequest (..), CompletionResponse (..)
  , StopReason (..), ToolChoice (..), Usage (..) )

spec :: Spec
spec = describe "Seal.Command.Provider helpers" $ do
  describe "pingRequest" $ do
    it "uses the given model, one message, no tools, a small token cap" $ do
      let req = pingRequest (ModelId "claude-opus-4-8")
      crModel req      `shouldBe` ModelId "claude-opus-4-8"
      length (crMessages req) `shouldBe` 1
      crTools req      `shouldBe` []
      crToolChoice req `shouldBe` ToolNone
      crMaxTokens req  `shouldSatisfy` (> 0)

  describe "formatTestResult" $ do
    it "reports success with the output-token count" $ do
      let r = formatTestResult "anthropic"
                (Right (CompletionResponse [] StopEnd (Usage 3 7)))
      r `shouldSatisfy` ("anthropic" `T.isInfixOf`)
      r `shouldSatisfy` ("OK" `T.isInfixOf`)
      r `shouldSatisfy` ("7" `T.isInfixOf`)

    it "reports failure with the error text" $ do
      let r = formatTestResult "anthropic" (Left "boom")
      r `shouldSatisfy` ("FAILED" `T.isInfixOf`)
      r `shouldSatisfy` ("boom" `T.isInfixOf`)
