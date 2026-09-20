{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.MemorySpec (spec) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.ISA.Opcode
import Seal.ISA.Ops.Memory
import Seal.Memory.Embedding
import Seal.Memory.Store
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Types.App (App, runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)
import Seal.Logging.Logger (testSealLogger)

runTestApp :: App a -> IO a
runTestApp act = do logger <- testSealLogger; env <- mkEnv logger defaultConfig; runApp env act

spec :: Spec
spec = describe "Seal.ISA.Ops.Memory" $ do
  describe "MEMORY_WRITE" $ do
    it "creates a new memory and returns success" $
      withSystemTempDirectory "seal-mem-ops" $ \root -> do
        store <- fileMemoryStore root
        let op = memoryWriteOp store nullEmbeddingBackend
        r <- runTestApp (opRun op localBackend (object ["path" .= ("user/tz" :: Text), "content" .= ("UTC-5" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> "stored" `T.isInfixOf` t `shouldBe` True
          _           -> expectationFailure "expected a single text part"

    it "rejects an invalid path" $
      withSystemTempDirectory "seal-mem-ops" $ \root -> do
        store <- fileMemoryStore root
        let op = memoryWriteOp store nullEmbeddingBackend
        r <- runTestApp (opRun op localBackend (object ["path" .= ("../etc" :: Text), "content" .= ("x" :: Text)]))
        orIsError r `shouldBe` True

    it "fails on an existing path (write-once)" $
      withSystemTempDirectory "seal-mem-ops" $ \root -> do
        store <- fileMemoryStore root
        let op = memoryWriteOp store nullEmbeddingBackend
        _ <- runTestApp (opRun op localBackend (object ["path" .= ("tz" :: Text), "content" .= ("old" :: Text)]))
        r <- runTestApp (opRun op localBackend (object ["path" .= ("tz" :: Text), "content" .= ("new" :: Text)]))
        orIsError r `shouldBe` True

  describe "MEMORY_READ" $ do
    it "returns content for an existing memory" $
      withSystemTempDirectory "seal-mem-ops" $ \root -> do
        store <- fileMemoryStore root
        let writeOp = memoryWriteOp store nullEmbeddingBackend
            readOp  = memoryReadOp store
        _ <- runTestApp (opRun writeOp localBackend (object ["path" .= ("user/tz" :: Text), "content" .= ("UTC-5" :: Text)]))
        r <- runTestApp (opRun readOp localBackend (object ["path" .= ("user/tz" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> "UTC-5" `T.isInfixOf` t `shouldBe` True
          _           -> expectationFailure "expected a single text part"

    it "returns exists=false for a non-existent path" $
      withSystemTempDirectory "seal-mem-ops" $ \root -> do
        store <- fileMemoryStore root
        let readOp = memoryReadOp store
        r <- runTestApp (opRun readOp localBackend (object ["path" .= ("nope" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> "not found" `T.isInfixOf` t `shouldBe` True
          _           -> expectationFailure "expected a single text part"

    it "falls back to archived and returns archived=true" $
      withSystemTempDirectory "seal-mem-ops" $ \root -> do
        store <- fileMemoryStore root
        let writeOp = memoryWriteOp store nullEmbeddingBackend
            readOp  = memoryReadOp store
            archOp  = memoryArchiveOp store nullEmbeddingBackend
        _ <- runTestApp (opRun writeOp localBackend (object ["path" .= ("old" :: Text), "content" .= ("original" :: Text)]))
        _ <- runTestApp (opRun archOp localBackend (object ["path" .= ("old" :: Text)]))
        r <- runTestApp (opRun readOp localBackend (object ["path" .= ("old" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            "original" `T.isInfixOf` t `shouldBe` True
            "archived" `T.isInfixOf` t `shouldBe` True
          _ -> expectationFailure "expected a single text part"

  describe "MEMORY_LIST" $ do
    it "returns paths matching a prefix" $
      withSystemTempDirectory "seal-mem-ops" $ \root -> do
        store <- fileMemoryStore root
        let writeOp = memoryWriteOp store nullEmbeddingBackend
            listOp  = memoryListOp store
        _ <- runTestApp (opRun writeOp localBackend (object ["path" .= ("projects/a/arch" :: Text), "content" .= ("a" :: Text)]))
        _ <- runTestApp (opRun writeOp localBackend (object ["path" .= ("projects/b/arch" :: Text), "content" .= ("b" :: Text)]))
        _ <- runTestApp (opRun writeOp localBackend (object ["path" .= ("user/tz" :: Text), "content" .= ("UTC" :: Text)]))
        r <- runTestApp (opRun listOp localBackend (object ["prefix" .= ("projects/" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            "projects/a/arch" `T.isInfixOf` t `shouldBe` True
            "projects/b/arch" `T.isInfixOf` t `shouldBe` True
            "user/tz" `T.isInfixOf` t `shouldBe` False
          _ -> expectationFailure "expected a single text part"

  describe "MEMORY_SEARCH" $ do
    it "returns empty results with null backend (not an error)" $
      withSystemTempDirectory "seal-mem-ops" $ \root -> do
        store <- fileMemoryStore root
        let searchOp = memorySearchOp nullEmbeddingBackend store
        r <- runTestApp (opRun searchOp localBackend (object ["query" .= ("haskell" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> T.isInfixOf "No results" t `shouldBe` True
          _           -> expectationFailure "expected a single text part"

    it "returns matching memories by substring when using null backend" $
      withSystemTempDirectory "seal-mem-ops" $ \root -> do
        store <- fileMemoryStore root
        let writeOp = memoryWriteOp store nullEmbeddingBackend
            searchOp = memorySearchOp nullEmbeddingBackend store
        _ <- runTestApp (opRun writeOp localBackend (object ["path" .= ("haskell/beam" :: Text), "content" .= ("Beam has quirks with monadic joins" :: Text)]))
        _ <- runTestApp (opRun writeOp localBackend (object ["path" .= ("user/tz" :: Text), "content" .= ("User is UTC-5" :: Text)]))
        r <- runTestApp (opRun searchOp localBackend (object ["query" .= ("beam" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            "beam" `T.isInfixOf` t `shouldBe` True
            "UTC-5" `T.isInfixOf` t `shouldBe` False
          _ -> expectationFailure "expected a single text part"

    it "returns empty results for a query with no matches" $
      withSystemTempDirectory "seal-mem-ops" $ \root -> do
        store <- fileMemoryStore root
        let writeOp = memoryWriteOp store nullEmbeddingBackend
            searchOp = memorySearchOp nullEmbeddingBackend store
        _ <- runTestApp (opRun writeOp localBackend (object ["path" .= ("a" :: Text), "content" .= ("hello" :: Text)]))
        r <- runTestApp (opRun searchOp localBackend (object ["query" .= ("nonexistent" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> T.isInfixOf "No results" t `shouldBe` True
          _           -> expectationFailure "expected a single text part"

  describe "MEMORY_ARCHIVE" $ do
    it "moves the file and subsequent read returns archived=true" $
      withSystemTempDirectory "seal-mem-ops" $ \root -> do
        store <- fileMemoryStore root
        let writeOp = memoryWriteOp store nullEmbeddingBackend
            archOp  = memoryArchiveOp store nullEmbeddingBackend
            readOp  = memoryReadOp store
        _ <- runTestApp (opRun writeOp localBackend (object ["path" .= ("tz" :: Text), "content" .= ("UTC-5" :: Text)]))
        r <- runTestApp (opRun archOp localBackend (object ["path" .= ("tz" :: Text)]))
        orIsError r `shouldBe` False
        readResult <- runTestApp (opRun readOp localBackend (object ["path" .= ("tz" :: Text)]))
        case orParts readResult of
          [TrpText t] -> "archived" `T.isInfixOf` t `shouldBe` True
          _           -> expectationFailure "expected a single text part"

    it "returns an error for a non-existent path" $
      withSystemTempDirectory "seal-mem-ops" $ \root -> do
        store <- fileMemoryStore root
        let archOp = memoryArchiveOp store nullEmbeddingBackend
        r <- runTestApp (opRun archOp localBackend (object ["path" .= ("nope" :: Text)]))
        orIsError r `shouldBe` True

  describe "secret discipline" $
    it "orRecorded never carries a vault secret (memory content is agent-visible, recorded in full)" $
      withSystemTempDirectory "seal-mem-ops" $ \root -> do
        store <- fileMemoryStore root
        let op = memoryWriteOp store nullEmbeddingBackend
        r <- runTestApp (opRun op localBackend (object ["path" .= ("m1" :: Text), "content" .= ("not-a-secret" :: Text)]))
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "not-a-secret" recorded `shouldBe` True
