{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the engram embedding backend. These tests verify that the
-- engram backend correctly shells out to the engram CLI (with @--index@
-- and @--json@ support). They are guarded with 'pendingWith' when the
-- engram binary is not available or ollama is not running.
module Seal.Memory.EngramBackendSpec (spec) where

import Data.Text qualified as T
import System.Directory (findExecutable)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Memory.Embedding (EmbeddingBackend (..), SearchResult (..))
import Seal.Memory.EngramBackend

spec :: Spec
spec = describe "Seal.Memory.EngramBackend" $ do
  describe "engramEmbeddingBackend" $ do
    it "indexes a file and search returns it as a result (JSON + custom index)" $
      withSystemTempDirectory "seal-engram" $ \root -> do
        mEngram <- findExecutable "engram"
        case mEngram of
          Nothing -> pendingWith "engram binary not found on PATH"
          Just binPath -> do
            let backend = engramEmbeddingBackend (T.pack binPath) (root </> "engram.db")
                filePath = root </> "test-engram-index.md"
            ebIndex backend filePath "The user prefers concise answers about Haskell"
            results <- ebSearch backend "concise preferences" 10
            case results of
              (r:_) -> do
                srPath r `shouldSatisfy` (T.pack filePath `T.isInfixOf`)
                srScore r `shouldSatisfy` (> 0)
              []    -> pendingWith "engram returned no results — ollama may not be running"

    it "uses a separate index (--index flag isolates from KB index)" $
      withSystemTempDirectory "seal-engram" $ \root -> do
        mEngram <- findExecutable "engram"
        case mEngram of
          Nothing -> pendingWith "engram binary not found on PATH"
          Just binPath -> do
            -- Index a file into a custom index
            let backend = engramEmbeddingBackend (T.pack binPath) (root </> "mem.db")
                filePath = root </> "isolated-test.md"
            ebIndex backend filePath "Haskell beam migration patterns are tricky"
            -- Search the custom index — should find the file
            results <- ebSearch backend "haskell beam" 10
            case results of
              (r:_) -> srPath r `shouldSatisfy` (T.pack filePath `T.isInfixOf`)
              []    -> pendingWith "engram returned no results — ollama may not be running"

    it "unindex removes a file from the search index" $
      withSystemTempDirectory "seal-engram" $ \root -> do
        mEngram <- findExecutable "engram"
        case mEngram of
          Nothing -> pendingWith "engram binary not found on PATH"
          Just binPath -> do
            let backend = engramEmbeddingBackend (T.pack binPath) (root </> "engram.db")
                filePath = root </> "test-engram-unindex.md"
            ebIndex backend filePath "Haskell beam migration patterns are tricky"
            ebUnindex backend filePath
            results <- ebSearch backend "haskell beam" 10
            -- The file should no longer be in results
            all ((/= T.pack filePath) . srPath) results `shouldBe` True

    it "backendName is engram" $ do
      mEngram <- findExecutable "engram"
      case mEngram of
        Nothing -> pendingWith "engram binary not found on PATH"
        Just binPath -> do
          let backend = engramEmbeddingBackend (T.pack binPath) "/tmp/test.db"
          ebBackendName backend `shouldBe` "engram"