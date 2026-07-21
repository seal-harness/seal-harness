{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.SkillsSpec (spec) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec

import Seal.Core.Types (SessionId (..))
import Seal.ISA.Opcode
import Seal.ISA.Ops.Skills
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Skills.Backend
import Seal.Skills.Types (Skill (..), SkillId (..), mkSkillId)
import Seal.Types.App (App, runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)

runTestApp :: App a -> IO a
runTestApp act = do env <- mkEnv defaultConfig; runApp env act

sampleSession :: SessionId
sampleSession = SessionId "s1"

sampleSkillId :: SkillId
sampleSkillId = case mkSkillId "s1" of
  Right sid -> sid
  Left _    -> SkillId "fallback"

spec :: Spec
spec = describe "Seal.ISA.Ops.Skills" $ do
  describe "SKILL_WRITE" $ do
    it "creates a new skill and returns 'created' with was_new=true" $ do
      backend <- noneBackend
      let op = skillWriteOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["id" .= ("s1" :: Text), "description" .= ("greet" :: Text), "body" .= ("say hi" :: Text)]))
      orIsError r `shouldBe` False
      orParts r `shouldBe` [TrpText "created"]
      m <- sbRead backend sampleSkillId
      case m of
        Just s  -> skBody s `shouldBe` "say hi"
        Nothing -> expectationFailure "skill not stored"

    it "rejects an invalid id" $ do
      backend <- noneBackend
      let op = skillWriteOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["id" .= ("bad/id" :: Text), "description" .= ("x" :: Text), "body" .= ("y" :: Text)]))
      orIsError r `shouldBe` True

    it "updates an existing skill and returns 'updated' with was_new=false (preserves provenance)" $ do
      backend <- noneBackend
      _ <- runTestApp (opRun (skillWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("s1" :: Text), "description" .= ("greet" :: Text), "body" .= ("old" :: Text)]))
      let op = skillWriteOp backend (SessionId "s2")
      r <- runTestApp (opRun op localBackend (object ["id" .= ("s1" :: Text), "description" .= ("greet2" :: Text), "body" .= ("new" :: Text)]))
      orIsError r `shouldBe` False
      orParts r `shouldBe` [TrpText "updated"]
      m <- sbRead backend sampleSkillId
      case m of
        Just s  -> do
          skBody s `shouldBe` "new"
          skDescription s `shouldBe` "greet2"
          -- provenance (original session) is preserved on update
          skSession s `shouldBe` sampleSession
        Nothing -> expectationFailure "skill not found after update"

  describe "SKILL_LOAD" $ do
    it "returns the skill body" $ do
      backend <- noneBackend
      _ <- runTestApp (opRun (skillWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("s1" :: Text), "description" .= ("greet" :: Text), "body" .= ("say hi" :: Text)]))
      let read' = skillLoadOp backend
      r <- runTestApp (opRun read' localBackend (object ["id" .= ("s1" :: Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> T.isInfixOf "say hi" t `shouldBe` True
        _           -> expectationFailure "expected a single text part"

    it "errors when the skill does not exist" $ do
      backend <- noneBackend
      let read' = skillLoadOp backend
      r <- runTestApp (opRun read' localBackend (object ["id" .= ("nope" :: Text)]))
      orIsError r `shouldBe` True

    it "rejects an invalid id" $ do
      backend <- noneBackend
      let read' = skillLoadOp backend
      r <- runTestApp (opRun read' localBackend (object ["id" .= ("bad/id" :: Text)]))
      orIsError r `shouldBe` True

  describe "SKILL_LIST" $ do
    it "returns an empty message when no skills" $ do
      backend <- noneBackend
      let list' = skillListOp backend
      r <- runTestApp (opRun list' localBackend (object []))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> t `shouldBe` "(no skills defined)"
        _           -> expectationFailure "expected a single text part"

    it "lists defined skills as id: description lines" $ do
      backend <- noneBackend
      _ <- runTestApp (opRun (skillWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("s1" :: Text), "description" .= ("greet" :: Text), "body" .= ("b" :: Text)]))
      _ <- runTestApp (opRun (skillWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("s2" :: Text), "description" .= ("farewell" :: Text), "body" .= ("b2" :: Text)]))
      let list' = skillListOp backend
      r <- runTestApp (opRun list' localBackend (object []))
      case orParts r of
        [TrpText t] -> do
          T.isInfixOf "s1: greet" t `shouldBe` True
          T.isInfixOf "s2: farewell" t `shouldBe` True
        _ -> expectationFailure "expected a single text part"

  describe "SKILL_DELETE" $ do
    it "deletes an existing skill" $ do
      backend <- noneBackend
      _ <- runTestApp (opRun (skillWriteOp backend sampleSession) localBackend
                             (object ["id" .= ("s1" :: Text), "description" .= ("g" :: Text), "body" .= ("b" :: Text)]))
      let delete = skillDeleteOp backend
      r <- runTestApp (opRun delete localBackend (object ["id" .= ("s1" :: Text)]))
      orIsError r `shouldBe` False
      sbRead backend sampleSkillId `shouldReturn` Nothing

    it "is idempotent on a missing id" $ do
      backend <- noneBackend
      let delete = skillDeleteOp backend
      r <- runTestApp (opRun delete localBackend (object ["id" .= ("nope" :: Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> T.isInfixOf "not present" t `shouldBe` True
        _           -> expectationFailure "expected a single text part"

  describe "secret discipline" $
    it "orRecorded carries the skill body (agent-visible data, recorded in full, not a vault secret)" $ do
      backend <- noneBackend
      let op = skillWriteOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["id" .= ("s1" :: Text), "description" .= ("d" :: Text), "body" .= ("not-a-secret" :: Text)]))
      let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
      T.isInfixOf "not-a-secret" recorded `shouldBe` True