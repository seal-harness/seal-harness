{-# LANGUAGE OverloadedStrings #-}
module Seal.Audit.LogSpec (spec) where

import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), Day (..), secondsToDiffTime)
import System.Directory (listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Audit.Log
import Seal.Audit.Predicate
import Seal.Core.Types (OpName (..), SessionId, mkSessionId)

-- | Helper: construct a valid SessionId from a string, assuming it's valid
-- (all test inputs are known-valid).
sid :: Text -> SessionId
sid s = case mkSessionId s of
  Right x  -> x
  Left _e -> error ("invalid session id in test: " <> T.unpack s)

spec :: Spec
spec = do
  describe "Seal.Audit.Predicate" $ do
    describe "shouldAudit" $ do
      it "logs SKILL_MANAGE write" $
        shouldAudit (OpName "SKILL_MANAGE") (Just "write") `shouldBe` True

      it "logs SKILL_MANAGE delete" $
        shouldAudit (OpName "SKILL_MANAGE") (Just "delete") `shouldBe` True

      it "does NOT log SKILL_MANAGE load (read-only)" $
        shouldAudit (OpName "SKILL_MANAGE") (Just "load") `shouldBe` False

      it "does NOT log SKILL_MANAGE list (read-only)" $
        shouldAudit (OpName "SKILL_MANAGE") (Just "list") `shouldBe` False

      it "logs AGENT_DEF_MANAGE write" $
        shouldAudit (OpName "AGENT_DEF_MANAGE") (Just "write") `shouldBe` True

      it "logs AGENT_DEF_MANAGE delete" $
        shouldAudit (OpName "AGENT_DEF_MANAGE") (Just "delete") `shouldBe` True

      it "does NOT log AGENT_DEF_MANAGE read (read-only)" $
        shouldAudit (OpName "AGENT_DEF_MANAGE") (Just "read") `shouldBe` False

      it "does NOT log AGENT_DEF_MANAGE list (read-only)" $
        shouldAudit (OpName "AGENT_DEF_MANAGE") (Just "list") `shouldBe` False

      it "logs SECRET_MANAGE put" $
        shouldAudit (OpName "SECRET_MANAGE") (Just "put") `shouldBe` True

      it "logs SECRET_MANAGE delete" $
        shouldAudit (OpName "SECRET_MANAGE") (Just "delete") `shouldBe` True

      it "does NOT log SECRET_MANAGE get (read-only)" $
        shouldAudit (OpName "SECRET_MANAGE") (Just "get") `shouldBe` False

      it "does NOT log SECRET_MANAGE list (read-only)" $
        shouldAudit (OpName "SECRET_MANAGE") (Just "list") `shouldBe` False

      it "logs MEMORY_MANAGE write" $
        shouldAudit (OpName "MEMORY_MANAGE") (Just "write") `shouldBe` True

      it "logs MEMORY_MANAGE archive" $
        shouldAudit (OpName "MEMORY_MANAGE") (Just "archive") `shouldBe` True

      it "does NOT log MEMORY_MANAGE read" $
        shouldAudit (OpName "MEMORY_MANAGE") (Just "read") `shouldBe` False

      it "does NOT log MEMORY_MANAGE list" $
        shouldAudit (OpName "MEMORY_MANAGE") (Just "list") `shouldBe` False

      it "does NOT log MEMORY_MANAGE search" $
        shouldAudit (OpName "MEMORY_MANAGE") (Just "search") `shouldBe` False

      it "does NOT log AGENT_MANAGE start" $
        shouldAudit (OpName "AGENT_MANAGE") (Just "start") `shouldBe` False

      it "does NOT log AGENT_MANAGE handoff" $
        shouldAudit (OpName "AGENT_MANAGE") (Just "handoff") `shouldBe` False

      it "does NOT log AGENT_MANAGE stop" $
        shouldAudit (OpName "AGENT_MANAGE") (Just "stop") `shouldBe` False

      it "does NOT log SESSION_MANAGE new" $
        shouldAudit (OpName "SESSION_MANAGE") (Just "new") `shouldBe` False

      it "does NOT log HARNESS_START" $
        shouldAudit (OpName "HARNESS_START") Nothing `shouldBe` False

      it "does NOT log SHOW_HUMAN" $
        shouldAudit (OpName "SHOW_HUMAN") Nothing `shouldBe` False

      it "does NOT log ASK_HUMAN" $
        shouldAudit (OpName "ASK_HUMAN") Nothing `shouldBe` False

      it "does NOT log FILE_WRITE" $
        shouldAudit (OpName "FILE_WRITE") Nothing `shouldBe` False

      it "does NOT log SHELL_EXEC" $
        shouldAudit (OpName "SHELL_EXEC") Nothing `shouldBe` False

      it "handles unknown opcode" $
        shouldAudit (OpName "UNKNOWN_OP") (Just "write") `shouldBe` False

      it "handles missing action field" $
        shouldAudit (OpName "SKILL_MANAGE") Nothing `shouldBe` False

  describe "Seal.Audit.Log" $ do
    describe "formatAuditLine" $ do
      let ts = UTCTime (ModifiedJulianDay 61359) (secondsToDiffTime 45015)
          s = sid "20261115-154047-abc"

      it "formats a line with all fields" $
        formatAuditLine ts (Just s) (OpName "SKILL_MANAGE") (Just "write")
          "my-skill" (Just "a1b2c3d")
          `shouldBe`
            "2026-11-15T12:30:15.000Z session=20261115-154047-abc op=SKILL_MANAGE action=write id=my-skill git=a1b2c3d"

      it "formats a line with no session id" $
        formatAuditLine ts Nothing (OpName "SECRET_MANAGE") (Just "put")
          "MY_KEY" (Just "deadbeef")
          `shouldBe`
            "2026-11-15T12:30:15.000Z session=- op=SECRET_MANAGE action=put id=MY_KEY git=deadbeef"

      it "formats a line with no git hash" $
        formatAuditLine ts (Just s) (OpName "MEMORY_MANAGE") (Just "archive")
          "projects/arch" Nothing
          `shouldBe`
            "2026-11-15T12:30:15.000Z session=20261115-154047-abc op=MEMORY_MANAGE action=archive id=projects/arch git=-"

      it "formats a line with no action" $
        formatAuditLine ts (Just s) (OpName "SHOW_HUMAN") Nothing
          "msg" Nothing
          `shouldBe`
            "2026-11-15T12:30:15.000Z session=20261115-154047-abc op=SHOW_HUMAN action=- id=msg git=-"

    describe "auditFileName" $ do
      it "generates monthly filename" $ do
        let t = UTCTime (ModifiedJulianDay 61359) (secondsToDiffTime 45015)
        auditFileName t `shouldBe` "audit-2026-11.log"

      it "generates January filename" $ do
        let t = UTCTime (ModifiedJulianDay 61041) (secondsToDiffTime 0)
        auditFileName t `shouldBe` "audit-2026-01.log"

    describe "withAuditLogger" $ do
      it "writes a line to the audit file" $
        withSystemTempDirectory "seal-audit" $ \dir -> do
          let t = UTCTime (ModifiedJulianDay 61359) (secondsToDiffTime 45015)
              s = sid "20261115-154047-abc"
              sink = fileAuditSink dir
          withAuditLogger sink $ \logger ->
            auditWrite logger t (Just s) (OpName "SKILL_MANAGE") (Just "write")
                       "my-skill" (Just "a1b2c3d")
          files <- listDirectory dir
          files `shouldSatisfy` any ("audit-2026-11" `isInfixOf`)
          let auditFiles = [f' | f' <- files, "audit-2026-11" `isInfixOf` f']
          case auditFiles of
            (f:_) -> do
              content <- readFile (dir </> f)
              content `shouldSatisfy` ("op=SKILL_MANAGE" `isInfixOf`)
              content `shouldSatisfy` ("action=write" `isInfixOf`)
              content `shouldSatisfy` ("id=my-skill" `isInfixOf`)
              content `shouldSatisfy` ("git=a1b2c3d" `isInfixOf`)
            [] -> expectationFailure "no audit file was created"

      it "writes nothing when only a no-op logger is set" $ do
        withSystemTempDirectory "seal-audit" $ \dir -> do
          let sink = fileAuditSink dir
          withAuditLogger sink $ \_ -> pure ()
          files <- listDirectory dir
          files `shouldBe` []

      it "skips writing when audit predicate is False" $
        withSystemTempDirectory "seal-audit" $ \dir -> do
          let t = UTCTime (ModifiedJulianDay 61359) (secondsToDiffTime 45015)
              s = sid "20261115-154047-abc"
              sink = fileAuditSink dir
          withAuditLogger sink $ \logger ->
            auditWriteIf logger shouldAudit t (Just s) (OpName "SKILL_MANAGE") (Just "load")
                         "my-skill" (Just "a1b2c3d")
          files <- listDirectory dir
          files `shouldBe` []

      it "writes when audit predicate is True" $
        withSystemTempDirectory "seal-audit" $ \dir -> do
          let t = UTCTime (ModifiedJulianDay 61359) (secondsToDiffTime 45015)
              s = sid "20261115-154047-abc"
              sink = fileAuditSink dir
          withAuditLogger sink $ \logger ->
            auditWriteIf logger shouldAudit t (Just s) (OpName "SECRET_MANAGE") (Just "delete")
                         "MY_KEY" (Just "deadbeef")
          files <- listDirectory dir
          files `shouldSatisfy` (not . null)
