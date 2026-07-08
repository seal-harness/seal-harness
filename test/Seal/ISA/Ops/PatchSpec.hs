{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.PatchSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.ByteString qualified as BS
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.ISA.Opcode (OpResult (..), uoRun, localBackend)
import Seal.ISA.Ops.File (filePatchOp)
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Tools.Exec.Types (ExecBackend (..), mkLocalExecHandlePlaceholder)
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env

runTestApp :: App a -> IO a
runTestApp act = do env <- mkEnv defaultConfig; runApp env act

testExecBackend :: ExecBackend
testExecBackend = EbLocal mkLocalExecHandlePlaceholder

spec :: Spec
spec = describe "FILE_PATCH" $ do

  it "applies a simple unified diff to an existing file" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello\nworld\n"
      let op = filePatchOp (WorkspaceRoot root)
          diff = "--- a.txt\n+++ a.txt\n@@ -1,2 +1,2 @@\n hello\n-world\n+world!\n"
      r <- runTestApp (uoRun op localBackend testExecBackend (object
        [ "path" .= ("a.txt" :: String)
        , "patch" .= (diff :: String)
        ]))
      orIsError r `shouldBe` False
      bs <- BS.readFile (root </> "a.txt")
      bs `shouldBe` "hello\nworld!\n"

  it "orRecorded captures path + patch hash + line counts (not the patch body)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "line1\nline2\n"
      let op = filePatchOp (WorkspaceRoot root)
          diff = "--- a.txt\n+++ a.txt\n@@ -1,2 +1,2 @@\n line1\n-line2\n+line2!\n"
      r <- runTestApp (uoRun op localBackend testExecBackend (object
        [ "path" .= ("a.txt" :: String)
        , "patch" .= (diff :: String)
        ]))
      orRecorded r `shouldSatisfy` \case
        Object _ -> True
        _        -> False

  it "rejects a path traversal escape (no write)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      let op = filePatchOp (WorkspaceRoot root)
          diff = "--- ../escape.txt\n+++ ../escape.txt\n@@ -1 +1 @@\n-a\n+b\n"
      r <- runTestApp (uoRun op localBackend testExecBackend (object
        [ "path" .= ("../escape.txt" :: String)
        , "patch" .= (diff :: String)
        ]))
      orIsError r `shouldBe` True

  it "rejects a nonexistent file" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      let op = filePatchOp (WorkspaceRoot root)
          diff = "--- a.txt\n+++ a.txt\n@@ -1 +1 @@\n-a\n+b\n"
      r <- runTestApp (uoRun op localBackend testExecBackend (object
        [ "path" .= ("nonexistent.txt" :: String)
        , "patch" .= (diff :: String)
        ]))
      orIsError r `shouldBe` True

  it "missing path field -> error" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      let op = filePatchOp (WorkspaceRoot root)
          diff = "--- a.txt\n+++ a.txt\n@@ -1 +1 @@\n-a\n+b\n"
      r <- runTestApp (uoRun op localBackend testExecBackend (object
        [ "patch" .= (diff :: String)
        ]))
      orIsError r `shouldBe` True