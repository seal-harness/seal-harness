{-# LANGUAGE OverloadedStrings #-}
module Seal.Agent.PromptPartsSpec (spec) where

import Data.Text qualified as T
import Test.Hspec

import Seal.Agent.PromptParts
  ( injectStaticGuidance, parallelToolGuidance, taskCompletionGuidance
  , toolUseEnforcement )

spec :: Spec
spec = describe "Seal.Agent.PromptParts" $ do
  describe "staticGuidanceBlock (via injectStaticGuidance)" $ do
    it "injects all three blocks when all are true" $ do
      let mOut = injectStaticGuidance True True True (Just "BASE")
      case mOut of
        Just out -> do
          T.isPrefixOf "BASE" out `shouldBe` True
          T.isInfixOf "Parallel tool calls" out `shouldBe` True
          T.isInfixOf "Tool use" out `shouldBe` True
          T.isInfixOf "Task completion" out `shouldBe` True
        Nothing -> expectationFailure "expected a prompt"

    it "injects only the enabled block when one is true" $ do
      let mOut = injectStaticGuidance True False False (Just "BASE")
      case mOut of
        Just out -> do
          T.isInfixOf "Parallel tool calls" out `shouldBe` True
          T.isInfixOf "Tool use" out `shouldBe` False
          T.isInfixOf "Task completion" out `shouldBe` False
        Nothing -> expectationFailure "expected a prompt"

    it "returns the prompt unchanged when no block is enabled" $ do
      injectStaticGuidance False False False (Just "BASE") `shouldBe` Just "BASE"

    it "returns Nothing when no block is enabled and there was no prompt" $ do
      injectStaticGuidance False False False Nothing `shouldBe` Nothing

    it "makes the guidance the entire prompt when there was none" $ do
      let mOut = injectStaticGuidance True False False Nothing
      case mOut of
        Just out -> T.isPrefixOf "## Parallel tool calls" out `shouldBe` True
        Nothing -> expectationFailure "expected a prompt"

  describe "block content" $ do
    it "parallelToolGuidance mentions batching independent calls" $
      T.isInfixOf "batch" parallelToolGuidance `shouldBe` True

    it "toolUseEnforcement mentions calling rather than describing" $ do
      T.isInfixOf "actually call" toolUseEnforcement `shouldBe` True
      T.isInfixOf "narrate" toolUseEnforcement `shouldBe` True

    it "taskCompletionGuidance mentions stubs and fabrication" $ do
      T.isInfixOf "stub" taskCompletionGuidance `shouldBe` True
      T.isInfixOf "fabricate" taskCompletionGuidance `shouldBe` True