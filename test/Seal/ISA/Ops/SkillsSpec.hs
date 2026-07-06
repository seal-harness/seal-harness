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
  describe "SKILL_CREATE" $ do
    it "creates a skill and returns 'created'" $ do
      backend <- noneBackend
      let op = skillCreateOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["id" .= ("s1" :: Text), "description" .= ("greet" :: Text), "body" .= ("say hi" :: Text)]))
      orIsError r `shouldBe` False
      orParts r `shouldBe` [TrpText "created"]
      m <- sbRead backend sampleSkillId
      case m of
        Just s  -> skBody s `shouldBe` "say hi"
        Nothing -> expectationFailure "skill not stored"

    it "rejects an invalid id" $ do
      backend <- noneBackend
      let op = skillCreateOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["id" .= ("bad/id" :: Text), "description" .= ("x" :: Text), "body" .= ("y" :: Text)]))
      orIsError r `shouldBe` True

  describe "SKILL_READ" $ do
    it "returns the skill body" $ do
      backend <- noneBackend
      _ <- runTestApp (opRun (skillCreateOp backend sampleSession) localBackend
                             (object ["id" .= ("s1" :: Text), "description" .= ("greet" :: Text), "body" .= ("say hi" :: Text)]))
      let read' = skillReadOp backend
      r <- runTestApp (opRun read' localBackend (object ["id" .= ("s1" :: Text)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText t] -> T.isInfixOf "say hi" t `shouldBe` True
        _           -> expectationFailure "expected a single text part"

    it "errors when the skill does not exist" $ do
      backend <- noneBackend
      let read' = skillReadOp backend
      r <- runTestApp (opRun read' localBackend (object ["id" .= ("nope" :: Text)]))
      orIsError r `shouldBe` True

    it "rejects an invalid id" $ do
      backend <- noneBackend
      let read' = skillReadOp backend
      r <- runTestApp (opRun read' localBackend (object ["id" .= ("bad/id" :: Text)]))
      orIsError r `shouldBe` True

  describe "SKILL_UPDATE" $ do
    it "updates an existing skill's body" $ do
      backend <- noneBackend
      _ <- runTestApp (opRun (skillCreateOp backend sampleSession) localBackend
                             (object ["id" .= ("s1" :: Text), "description" .= ("greet" :: Text), "body" .= ("old" :: Text)]))
      let update = skillUpdateOp backend
      r <- runTestApp (opRun update localBackend (object ["id" .= ("s1" :: Text), "body" .= ("new" :: Text)]))
      orIsError r `shouldBe` False
      m <- sbRead backend sampleSkillId
      case m of
        Just s  -> skBody s `shouldBe` "new"
        Nothing -> expectationFailure "skill not found after update"

    it "preserves the description when only body is updated" $ do
      backend <- noneBackend
      _ <- runTestApp (opRun (skillCreateOp backend sampleSession) localBackend
                             (object ["id" .= ("s1" :: Text), "description" .= ("greet" :: Text), "body" .= ("old" :: Text)]))
      _ <- runTestApp (opRun (skillUpdateOp backend) localBackend (object ["id" .= ("s1" :: Text), "body" .= ("new" :: Text)]))
      m <- sbRead backend sampleSkillId
      case m of
        Just s  -> skDescription s `shouldBe` "greet"
        Nothing -> expectationFailure "skill not found"

    it "errors when the skill does not exist" $ do
      backend <- noneBackend
      let update = skillUpdateOp backend
      r <- runTestApp (opRun update localBackend (object ["id" .= ("nope" :: Text), "body" .= ("x" :: Text)]))
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
      _ <- runTestApp (opRun (skillCreateOp backend sampleSession) localBackend
                             (object ["id" .= ("s1" :: Text), "description" .= ("greet" :: Text), "body" .= ("b" :: Text)]))
      _ <- runTestApp (opRun (skillCreateOp backend sampleSession) localBackend
                             (object ["id" .= ("s2" :: Text), "description" .= ("farewell" :: Text), "body" .= ("b2" :: Text)]))
      let list' = skillListOp backend
      r <- runTestApp (opRun list' localBackend (object []))
      case orParts r of
        [TrpText t] -> do
          T.isInfixOf "s1: greet" t `shouldBe` True
          T.isInfixOf "s2: farewell" t `shouldBe` True
        _ -> expectationFailure "expected a single text part"

  describe "secret discipline" $
    it "orRecorded carries the skill body (agent-visible data, recorded in full, not a vault secret)" $ do
      backend <- noneBackend
      let op = skillCreateOp backend sampleSession
      r <- runTestApp (opRun op localBackend (object ["id" .= ("s1" :: Text), "description" .= ("d" :: Text), "body" .= ("not-a-secret" :: Text)]))
      let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
      T.isInfixOf "not-a-secret" recorded `shouldBe` True