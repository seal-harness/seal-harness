{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.ContextWindowSpec (spec) where

import Test.Hspec

import Seal.Providers.ContextWindow

spec :: Spec
spec = do
  describe "Seal.Providers.ContextWindow" $ do

    describe "modelContextWindow" $ do
      it "returns 1048576 for glm-5.2:cloud" $
        modelContextWindow "glm-5.2:cloud" `shouldBe` 1048576

      it "returns 1048576 for glm-5" $
        modelContextWindow "glm-5" `shouldBe` 1048576

      it "returns 1048576 for glm-5.1" $
        modelContextWindow "glm-5.1" `shouldBe` 1048576

      it "returns 200000 for claude-sonnet-*" $
        modelContextWindow "claude-sonnet-4-20250514" `shouldBe` 200000

      it "returns 200000 for claude-opus-*" $
        modelContextWindow "claude-opus-4-20250514" `shouldBe` 200000

      it "returns 200000 for claude-haiku-*" $
        modelContextWindow "claude-haiku-3-20240307" `shouldBe` 200000

      it "returns 128000 for gpt-4o-*" $
        modelContextWindow "gpt-4o-2024-08-06" `shouldBe` 128000

      it "returns 128000 for gpt-4-turbo*" $
        modelContextWindow "gpt-4-turbo-2024-04-09" `shouldBe` 128000

      it "returns 128000 for llama3.1*" $
        modelContextWindow "llama3.1-8b" `shouldBe` 128000

      it "returns 8192 for llama3*" $
        modelContextWindow "llama3-8b" `shouldBe` 8192

      it "returns 0 for unknown models" $
        modelContextWindow "some-unknown-model" `shouldBe` 0

      it "returns 0 for empty string" $
        modelContextWindow "" `shouldBe` 0

      it "glm-5 prefix matches all glm-5 variants" $
        mapM_ (\m -> modelContextWindow m `shouldBe` 1048576)
          [ "glm-5"
          , "glm-5.2:cloud"
          , "glm-5.1"
          , "glm-5.2"
          , "glm-5-32b"
          ]

    describe "modelMaxOutputTokens" $ do
      it "returns a positive value for glm-5 models" $
        modelMaxOutputTokens "glm-5.2:cloud" `shouldSatisfy` (> 0)

      it "returns 64000 for claude-*" $
        modelMaxOutputTokens "claude-sonnet-4-20250514" `shouldBe` 64000

      it "returns 16384 for gpt-4o-*" $
        modelMaxOutputTokens "gpt-4o-2024-08-06" `shouldBe` 16384

      it "returns 4096 for llama3*" $
        modelMaxOutputTokens "llama3-8b" `shouldBe` 4096

      it "returns 0 for unknown models" $
        modelMaxOutputTokens "some-unknown-model" `shouldBe` 0

      it "returns 0 for empty string" $
        modelMaxOutputTokens "" `shouldBe` 0
