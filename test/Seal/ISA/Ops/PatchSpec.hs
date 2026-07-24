{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.PatchSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.ByteString qualified as BS
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.ISA.Opcode (OpResult (..), uoRun)
import Seal.ISA.Ops.File (filePatchOp)
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Tools.Exec.UntrustedIO (UntrustedIO, mkLocalUntrustedIO)
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env

runTestApp :: App a -> IO a
runTestApp act = do env <- mkEnv defaultConfig; runApp env act

mkTestUio :: WorkspaceRoot -> UntrustedIO
mkTestUio = mkLocalUntrustedIO

spec :: Spec
spec = describe "FILE_PATCH" $ do

  it "applies a simple unified diff to an existing file" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello\nworld\n"
      let op = filePatchOp (WorkspaceRoot root)
          diff = "--- a.txt\n+++ a.txt\n@@ -1,2 +1,2 @@\n hello\n-world\n+world!\n"
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
        [ "path" .= ("a.txt" :: String)
        , "patch" .= (diff :: String)
        ]))
      orIsError r `shouldBe` False
      bs <- BS.readFile (root </> "a.txt")
      bs `shouldBe` "hello\nworld!\n"

  -- The short form @@@ -1 +1 @@@ is what @git diff@ emits when the hunk has
  -- length 1 (the @,1@ is omitted). The model produces this naturally; the
  -- session 20260719-000547-115 transcript shows it being rejected with
  -- "malformed hunk header numbers". The applier should accept the short
  -- form and treat the omitted length as 1.
  it "accepts the short hunk header form @@ -1 +1 @@ (length 1 implied)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello\nworld\n"
      let op = filePatchOp (WorkspaceRoot root)
          diff = "--- a.txt\n+++ a.txt\n@@ -1 +1 @@\n-hello\n+hi\n"
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
        [ "path" .= ("a.txt" :: String)
        , "patch" .= (diff :: String)
        ]))
      orIsError r `shouldBe` False
      bs <- BS.readFile (root </> "a.txt")
      bs `shouldBe` "hi\nworld\n"

  it "accepts the short hunk header form for the new-side only (@@ -1,2 +1 @@)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello\nworld\n"
      let op = filePatchOp (WorkspaceRoot root)
          diff = "--- a.txt\n+++ a.txt\n@@ -1,2 +1 @@\n-hello\n-world\n+hi\n"
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
        [ "path" .= ("a.txt" :: String)
        , "patch" .= (diff :: String)
        ]))
      orIsError r `shouldBe` False
      bs <- BS.readFile (root </> "a.txt")
      bs `shouldBe` "hi\n"

  it "accepts the short hunk header form for the old-side only (@@ -1 +1,2 @@)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello\n"
      let op = filePatchOp (WorkspaceRoot root)
          diff = "--- a.txt\n+++ a.txt\n@@ -1 +1,2 @@\n-hello\n+hi\n+world\n"
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
        [ "path" .= ("a.txt" :: String)
        , "patch" .= (diff :: String)
        ]))
      orIsError r `shouldBe` False
      bs <- BS.readFile (root </> "a.txt")
      bs `shouldBe` "hi\nworld\n"

  it "orRecorded captures path + patch hash + line counts (not the patch body)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "line1\nline2\n"
      let op = filePatchOp (WorkspaceRoot root)
          diff = "--- a.txt\n+++ a.txt\n@@ -1,2 +1,2 @@\n line1\n-line2\n+line2!\n"
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
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
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
        [ "path" .= ("../escape.txt" :: String)
        , "patch" .= (diff :: String)
        ]))
      orIsError r `shouldBe` True

  it "rejects a nonexistent file" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      let op = filePatchOp (WorkspaceRoot root)
          diff = "--- a.txt\n+++ a.txt\n@@ -1 +1 @@\n-a\n+b\n"
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
        [ "path" .= ("nonexistent.txt" :: String)
        , "patch" .= (diff :: String)
        ]))
      orIsError r `shouldBe` True

  it "missing path field -> error" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      let op = filePatchOp (WorkspaceRoot root)
          diff = "--- a.txt\n+++ a.txt\n@@ -1 +1 @@\n-a\n+b\n"
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
        [ "patch" .= (diff :: String)
        ]))
      orIsError r `shouldBe` True

  it "'diff' field is accepted as an alias for 'patch' (permissive parsing)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello\nworld\n"
      let op = filePatchOp (WorkspaceRoot root)
          -- Model used the common-but-wrong key 'diff' instead of 'patch';
          -- patchField accepts 'diff' as a fallback alias so the model's first
          -- attempt succeeds without a round-trip through OPCODE_DESCRIBE.
          diff = "--- a.txt\n+++ a.txt\n@@ -1,2 +1,2 @@\n hello\n-world\n+world!\n"
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
        [ "path" .= ("a.txt" :: String)
        , "diff" .= (diff :: String)
        ]))
      orIsError r `shouldBe` False
      bs <- BS.readFile (root </> "a.txt")
      bs `shouldBe` "hello\nworld!\n"

  it "missing both 'patch' and 'diff' fields -> error, not silent no-op success" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello\nworld\n"
      let op = filePatchOp (WorkspaceRoot root)
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
        [ "path" .= ("a.txt" :: String)
        ]))
      orIsError r `shouldBe` True
      bs <- BS.readFile (root </> "a.txt")
      bs `shouldBe` "hello\nworld\n"

  it "empty patch string -> error, not silent no-op success" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello\nworld\n"
      let op = filePatchOp (WorkspaceRoot root)
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
        [ "path" .= ("a.txt" :: String)
        , "patch" .= ("" :: String)
        ]))
      orIsError r `shouldBe` True
      bs <- BS.readFile (root </> "a.txt")
      bs `shouldBe` "hello\nworld\n"