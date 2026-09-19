{-# LANGUAGE OverloadedStrings #-}
module Seal.Memory.PathSpec (spec) where

import Data.Either (isLeft)
import Test.Hspec
import Test.QuickCheck

import Seal.Memory.Path
import Seal.TestHelpers.Arbitrary ()

spec :: Spec
spec = describe "Seal.Memory.Path" $ do
  describe "mkMemoryPath" $ do
    it "accepts a simple single-segment path" $ do
      mkMemoryPath "preferences" `shouldBe` Right (MemoryPath "preferences")

    it "accepts a multi-segment hierarchical path" $ do
      mkMemoryPath "projects/pureclaw/architecture"
        `shouldBe` Right (MemoryPath "projects/pureclaw/architecture")

    it "round-trips through memoryPathText" $
      property $ \case
        MemoryPath t -> mkMemoryPath t === Right (MemoryPath t)

    it "rejects an empty path" $
      mkMemoryPath "" `shouldSatisfy` isLeft

    it "rejects a path with .. segment" $
      mkMemoryPath "../etc" `shouldSatisfy` isLeft

    it "rejects a path with . segment" $
      mkMemoryPath "./foo" `shouldSatisfy` isLeft

    it "rejects a path with a leading-dot segment" $
      mkMemoryPath ".hidden" `shouldSatisfy` isLeft

    it "rejects an absolute path (leading slash)" $
      mkMemoryPath "/abs/path" `shouldSatisfy` isLeft

    it "rejects a path with a trailing slash" $
      mkMemoryPath "foo/" `shouldSatisfy` isLeft

    it "rejects a path with disallowed characters" $ do
      mkMemoryPath "foo bar" `shouldSatisfy` isLeft
      mkMemoryPath "foo:bar" `shouldSatisfy` isLeft

    it "rejects a path with double slashes" $
      mkMemoryPath "foo//bar" `shouldSatisfy` isLeft

  describe "memoryPathSegments" $ do
    it "splits a path into segments" $ do
      memoryPathSegments <$> mkMemoryPath "a/b/c"
        `shouldBe` Right ["a", "b", "c"]

    it "returns a single-element list for a bare path" $ do
      memoryPathSegments <$> mkMemoryPath "simple"
        `shouldBe` Right ["simple"]
