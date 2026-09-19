{-# LANGUAGE OverloadedStrings #-}
module Seal.Memory.EmbeddingSpec (spec) where

import Test.Hspec

import Seal.Memory.Embedding

spec :: Spec
spec = describe "Seal.Memory.Embedding" $ do
  describe "nullEmbeddingBackend" $ do
    it "search returns empty results" $ do
      results <- ebSearch nullEmbeddingBackend "query" 10
      results `shouldBe` []

    it "index is a no-op (does not throw)" $ do
      ebIndex nullEmbeddingBackend "/tmp/test.md" "content"
      pure ()

    it "unindex is a no-op (does not throw)" $ do
      ebUnindex nullEmbeddingBackend "/tmp/test.md"
      pure ()

    it "backendName is null" $ do
      ebBackendName nullEmbeddingBackend `shouldBe` "null"