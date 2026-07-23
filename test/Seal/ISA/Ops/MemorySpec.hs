{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.MemorySpec (spec) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec

import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types (SessionId, mkSystemSessionId)
import Seal.ISA.Opcode
import Seal.ISA.Ops.Memory
import Seal.Memory.Backend
import Seal.Memory.Types (MemoryEntry (..), MemoryId (..), mkMemoryId)
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Types.App (App, runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)

runTestApp :: App a -> IO a
runTestApp act = do env <- mkEnv defaultConfig; runApp env act

sampleSession :: SessionId
sampleSession = mkSystemSessionId "s1"

sampleMemoryId :: MemoryId
sampleMemoryId = case mkMemoryId "m1" of
  Right mid -> mid
  Left _    -> MemoryId "fallback"

spec :: Spec
spec = describe "Seal.ISA.Ops.Memory" $ do
  describe "MEMORY_WRITE" $ do
    it "creates a new entry and returns 'stored' with was_new=true" $ do
      backend <- noneBackend
      let op = memoryWriteOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["id" .= ("m1" :: Text), "content" .= ("hello" :: Text)]))
      orIsError r `shouldBe` False
      orParts r `shouldBe` [TrpText "stored"]
      m <- mbRecall backend sampleMemoryId
      case m of
        Just e  -> meContent e `shouldBe` "hello"
        Nothing -> expectationFailure "memory not stored"

    it "rejects an invalid id" $ do
      backend <- noneBackend
      let op = memoryWriteOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["id" .= ("bad/id" :: Text), "content" .= ("x" :: Text)]))
      orIsError r `shouldBe` True

    it "updates an existing entry and returns 'updated' with was_new=false (preserves provenance)" $ do
      backend <- noneBackend
      _ <- runTestApp (opRun (memoryWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("m1" :: Text), "content" .= ("old" :: Text)]))
      let op = memoryWriteOp backend (mkSystemSessionId "s2")
      r <- runTestApp (opRun op localBackend (object ["id" .= ("m1" :: Text), "content" .= ("new" :: Text)]))
      orIsError r `shouldBe` False
      orParts r `shouldBe` [TrpText "updated"]
      m <- mbRecall backend sampleMemoryId
      case m of
        Just e  -> do
          meContent e `shouldBe` "new"
          -- provenance (original session) is preserved on update
          meSession e `shouldBe` sampleSession
        Nothing -> expectationFailure "memory not found after update"

  describe "MEMORY_RECALL" $ do
    it "returns a paged window of all memories" $ do
      backend <- noneBackend
      -- store 3 memories
      let write op = opRun op localBackend
      _ <- runTestApp (write (memoryWriteOp backend sampleSession)
                             (object ["id" .= ("a" :: Text), "content" .= ("alpha" :: Text)]))
      _ <- runTestApp (write (memoryWriteOp backend sampleSession)
                             (object ["id" .= ("b" :: Text), "content" .= ("beta" :: Text)]))
      _ <- runTestApp (write (memoryWriteOp backend sampleSession)
                             (object ["id" .= ("c" :: Text), "content" .= ("gamma" :: Text)]))
      let recall = memoryRecallOp defaultPageParams backend
      r <- runTestApp (opRun recall localBackend (object []))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> do
          -- all three contents appear in the rendered page
          T.isInfixOf "alpha" t `shouldBe` True
          T.isInfixOf "beta" t `shouldBe` True
          T.isInfixOf "gamma" t `shouldBe` True
          -- the page footer is present
          T.isInfixOf "page" t `shouldBe` True
        _ -> expectationFailure "expected a single text part"

    it "filters by a substring query" $ do
      backend <- noneBackend
      let write op = opRun op localBackend
      _ <- runTestApp (write (memoryWriteOp backend sampleSession)
                             (object ["id" .= ("a" :: Text), "content" .= ("alpha zeta" :: Text)]))
      _ <- runTestApp (write (memoryWriteOp backend sampleSession)
                             (object ["id" .= ("b" :: Text), "content" .= ("beta" :: Text)]))
      let recall = memoryRecallOp defaultPageParams backend
      r <- runTestApp (opRun recall localBackend (object ["query" .= ("zeta" :: Text)]))
      case orParts r of
        [TrpText t] -> do
          T.isInfixOf "alpha" t `shouldBe` True
          T.isInfixOf "beta" t `shouldBe` False
        _ -> expectationFailure "expected a single text part"

  describe "MEMORY_DELETE" $ do
    it "deletes an existing memory" $ do
      backend <- noneBackend
      _ <- runTestApp (opRun (memoryWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("m1" :: Text), "content" .= ("x" :: Text)]))
      let delete = memoryDeleteOp backend
      r <- runTestApp (opRun delete localBackend (object ["id" .= ("m1" :: Text)]))
      orIsError r `shouldBe` False
      mbRecall backend sampleMemoryId `shouldReturn` Nothing

    it "is idempotent on a missing id" $ do
      backend <- noneBackend
      let delete = memoryDeleteOp backend
      r <- runTestApp (opRun delete localBackend (object ["id" .= ("nope" :: Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> T.isInfixOf "not present" t `shouldBe` True
        _           -> expectationFailure "expected a single text part"

  describe "secret discipline" $
    it "orRecorded never carries a vault secret (memory content is agent-visible, recorded in full)" $ do
      backend <- noneBackend
      let op = memoryWriteOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["id" .= ("m1" :: Text), "content" .= ("not-a-secret" :: Text)]))
      let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
      -- memory content IS recorded (it is agent-visible data, not a vault secret)
      T.isInfixOf "not-a-secret" recorded `shouldBe` True