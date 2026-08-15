{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.PatchSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.ByteString qualified as BS
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.ISA.Opcode (OpResult (..), uoRunLegacy)
import Seal.ISA.Ops.File (filePatchOp)
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Tools.Exec.UntrustedIO (UntrustedIO, mkLocalUntrustedIO)
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env
import Seal.Logging.Logger (testSealLogger)

runTestApp :: App a -> IO a
runTestApp act = do logger <- testSealLogger; env <- mkEnv logger defaultConfig; runApp env act

mkTestUio :: WorkspaceRoot -> UntrustedIO
mkTestUio = mkLocalUntrustedIO

spec :: Spec
spec = describe "FILE_PATCH" $ do

  it "applies a simple unified diff to an existing file" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello\nworld\n"
      let op = filePatchOp (WorkspaceRoot root)
          diff = "--- a.txt\n+++ a.txt\n@@ -1,2 +1,2 @@\n hello\n-world\n+world!\n"
      r <- runTestApp (uoRunLegacy (mkTestUio (WorkspaceRoot root)) Nothing op (object
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
      r <- runTestApp (uoRunLegacy (mkTestUio (WorkspaceRoot root)) Nothing op (object
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
      r <- runTestApp (uoRunLegacy (mkTestUio (WorkspaceRoot root)) Nothing op (object
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
      r <- runTestApp (uoRunLegacy (mkTestUio (WorkspaceRoot root)) Nothing op (object
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
      r <- runTestApp (uoRunLegacy (mkTestUio (WorkspaceRoot root)) Nothing op (object
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
      r <- runTestApp (uoRunLegacy (mkTestUio (WorkspaceRoot root)) Nothing op (object
        [ "path" .= ("../escape.txt" :: String)
        , "patch" .= (diff :: String)
        ]))
      orIsError r `shouldBe` True

  it "rejects a nonexistent file" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      let op = filePatchOp (WorkspaceRoot root)
          diff = "--- a.txt\n+++ a.txt\n@@ -1 +1 @@\n-a\n+b\n"
      r <- runTestApp (uoRunLegacy (mkTestUio (WorkspaceRoot root)) Nothing op (object
        [ "path" .= ("nonexistent.txt" :: String)
        , "patch" .= (diff :: String)
        ]))
      orIsError r `shouldBe` True

  it "missing path field -> error" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      let op = filePatchOp (WorkspaceRoot root)
          diff = "--- a.txt\n+++ a.txt\n@@ -1 +1 @@\n-a\n+b\n"
      r <- runTestApp (uoRunLegacy (mkTestUio (WorkspaceRoot root)) Nothing op (object
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
      r <- runTestApp (uoRunLegacy (mkTestUio (WorkspaceRoot root)) Nothing op (object
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
      r <- runTestApp (uoRunLegacy (mkTestUio (WorkspaceRoot root)) Nothing op (object
        [ "path" .= ("a.txt" :: String)
        ]))
      orIsError r `shouldBe` True
      bs <- BS.readFile (root </> "a.txt")
      bs `shouldBe` "hello\nworld\n"

  it "empty patch string -> error, not silent no-op success" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello\nworld\n"
      let op = filePatchOp (WorkspaceRoot root)
      r <- runTestApp (uoRunLegacy (mkTestUio (WorkspaceRoot root)) Nothing op (object
        [ "path" .= ("a.txt" :: String)
        , "patch" .= ("" :: String)
        ]))
      orIsError r `shouldBe` True
      bs <- BS.readFile (root </> "a.txt")
      bs `shouldBe` "hello\nworld\n"

  -- Regression: the production bug from session 20260810-123133-477 —
  -- "The patch is inserting lines at wrong positions." The applier was
  -- position-based: after hunk 1 inserts N lines, hunk 2's @@ -oldStart @@
  -- line number was interpreted against the ALREADY-EXTENDED file instead
  -- of the original, so hunk 2 landed N lines too late. A content-based
  -- applier (search for the old/context lines, like OpenCode's `seek` and
  -- Hermes' `fuzzy_find_and_replace`) does not depend on line numbers at
  -- all and is immune to this class of bug.
  describe "multi-hunk line-number shift (session 20260810-123133-477 regression)" $ do

    it "applies two hunks where hunk 1 inserts lines and hunk 2 edits a later region" $
      withSystemTempDirectory "seal-ws" $ \root -> do
        -- 10-line file; hunk 1 inserts 3 lines after line 2; hunk 2 changes
        -- line 8 (originally "l8") to "l8!". With the old position-based
        -- applier, hunk 2's @@ -8 +8 @@ would land at index 7 of the
        -- already-extended file (which is now "l5"), corrupting the file.
        BS.writeFile (root </> "a.txt") "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n"
        let op = filePatchOp (WorkspaceRoot root)
            diff = unlines
              [ "--- a.txt"
              , "+++ a.txt"
              , "@@ -2,0 +3,3 @@"
              , "+INS1"
              , "+INS2"
              , "+INS3"
              , "@@ -8 +11 @@"
              , "-l8"
              , "+l8!"
              ]
        r <- runTestApp (uoRunLegacy (mkTestUio (WorkspaceRoot root)) Nothing op (object
          [ "path" .= ("a.txt" :: String)
          , "patch" .= (diff :: String)
          ]))
        orIsError r `shouldBe` False
        bs <- BS.readFile (root </> "a.txt")
        bs `shouldBe` "l1\nl2\nINS1\nINS2\nINS3\nl3\nl4\nl5\nl6\nl7\nl8!\nl9\nl10\n"

    it "applies two hunks where hunk 1 DELETES lines and hunk 2 edits a later region" $
      withSystemTempDirectory "seal-ws" $ \root -> do
        -- Hunk 1 deletes l3 and l4 (line numbers after shift down by 2);
        -- hunk 2 edits l8 -> l8!. Position-based applier would land hunk 2
        -- 2 lines too early.
        BS.writeFile (root </> "a.txt") "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n"
        let op = filePatchOp (WorkspaceRoot root)
            diff = unlines
              [ "--- a.txt"
              , "+++ a.txt"
              , "@@ -3,2 +3,0 @@"
              , "-l3"
              , "-l4"
              , "@@ -8 +6 @@"
              , "-l8"
              , "+l8!"
              ]
        r <- runTestApp (uoRunLegacy (mkTestUio (WorkspaceRoot root)) Nothing op (object
          [ "path" .= ("a.txt" :: String)
          , "patch" .= (diff :: String)
          ]))
        orIsError r `shouldBe` False
        bs <- BS.readFile (root </> "a.txt")
        bs `shouldBe` "l1\nl2\nl5\nl6\nl7\nl8!\nl9\nl10\n"

  -- Regression: a stale line number in the hunk header must NOT cause the
  -- patch to silently apply at the wrong spot. The applier must verify the
  -- context lines actually match at the claimed location; if they don't,
  -- it should search for the context elsewhere (content-based) or fail
  -- loudly — never silently corrupt the file.
  describe "stale / wrong line numbers in hunk header" $ do

    it "applies correctly when the hunk header's oldStart is off by a few lines" $
      withSystemTempDirectory "seal-ws" $ \root -> do
        -- Real file has the "world" line at position 2, but the model's
        -- hunk header claims -3 (stale — it last saw the file before a
        -- line was inserted above). A content-based applier finds "world"
        -- regardless; a position-based one corrupts line 3.
        BS.writeFile (root </> "a.txt") "hello\nworld\nfoo\n"
        let op = filePatchOp (WorkspaceRoot root)
            diff = unlines
              [ "--- a.txt"
              , "+++ a.txt"
              , "@@ -3 +3 @@"
              , "-world"
              , "+WORLD"
              ]
        r <- runTestApp (uoRunLegacy (mkTestUio (WorkspaceRoot root)) Nothing op (object
          [ "path" .= ("a.txt" :: String)
          , "patch" .= (diff :: String)
          ]))
        orIsError r `shouldBe` False
        bs <- BS.readFile (root </> "a.txt")
        bs `shouldBe` "hello\nWORLD\nfoo\n"

    it "fails loudly (not silently corrupts) when context lines don't match anywhere" $
      withSystemTempDirectory "seal-ws" $ \root -> do
        BS.writeFile (root </> "a.txt") "hello\nworld\n"
        let op = filePatchOp (WorkspaceRoot root)
            diff = unlines
              [ "--- a.txt"
              , "+++ a.txt"
              , "@@ -1,2 +1,2 @@"
              , " context_that_does_not_exist"
              , "-hello"
              , "+HELLO"
              ]
        r <- runTestApp (uoRunLegacy (mkTestUio (WorkspaceRoot root)) Nothing op (object
          [ "path" .= ("a.txt" :: String)
          , "patch" .= (diff :: String)
          ]))
        orIsError r `shouldBe` True
        -- File must NOT be modified on a failed apply.
        bs <- BS.readFile (root </> "a.txt")
        bs `shouldBe` "hello\nworld\n"

  -- Regression: trailing whitespace differences between the patch's
  -- context lines and the file must not cause a hard failure. Models
  -- frequently emit context with slightly different trailing whitespace
  -- than the file actually has. OpenCode falls back through
  -- exact -> rstrip -> trim -> normalized; we should at least tolerate
  -- trailing-whitespace differences.
  describe "whitespace tolerance in context lines" $ do

    it "applies when the patch context has trailing whitespace the file lacks" $
      withSystemTempDirectory "seal-ws" $ \root -> do
        BS.writeFile (root </> "a.txt") "hello\nworld\n"
        let op = filePatchOp (WorkspaceRoot root)
            -- context line " hello " (trailing space) vs file "hello"
            diff = unlines
              [ "--- a.txt"
              , "+++ a.txt"
              , "@@ -1,2 +1,2 @@"
              , " hello "
              , "-world"
              , "+WORLD"
              ]
        r <- runTestApp (uoRunLegacy (mkTestUio (WorkspaceRoot root)) Nothing op (object
          [ "path" .= ("a.txt" :: String)
          , "patch" .= (diff :: String)
          ]))
        orIsError r `shouldBe` False
        bs <- BS.readFile (root </> "a.txt")
        bs `shouldBe` "hello\nWORLD\n"

  -- Regression: inserting at the very end of the file (no trailing
  -- context line) must work. The model frequently appends a new block
  -- after the last existing line; the @@ -N,0 +N,M @@ (or @@ -N +N,M @@)
  -- form with only "+" lines must land the insert at EOF.
  describe "insert at end of file" $ do

    it "appends new lines after the last existing line" $
      withSystemTempDirectory "seal-ws" $ \root -> do
        BS.writeFile (root </> "a.txt") "l1\nl2\nl3\n"
        let op = filePatchOp (WorkspaceRoot root)
            -- old length 0 means "insert after line 3"; only + lines.
            diff = unlines
              [ "--- a.txt"
              , "+++ a.txt"
              , "@@ -3,0 +4,2 @@"
              , "+appended1"
              , "+appended2"
              ]
        r <- runTestApp (uoRunLegacy (mkTestUio (WorkspaceRoot root)) Nothing op (object
          [ "path" .= ("a.txt" :: String)
          , "patch" .= (diff :: String)
          ]))
        orIsError r `shouldBe` False
        bs <- BS.readFile (root </> "a.txt")
        bs `shouldBe` "l1\nl2\nl3\nappended1\nappended2\n"

    it "appends to an empty file" $
      withSystemTempDirectory "seal-ws" $ \root -> do
        BS.writeFile (root </> "a.txt") ""
        let op = filePatchOp (WorkspaceRoot root)
            diff = unlines
              [ "--- a.txt"
              , "+++ a.txt"
              , "@@ -0,0 +1,2 @@"
              , "+first"
              , "+second"
              ]
        r <- runTestApp (uoRunLegacy (mkTestUio (WorkspaceRoot root)) Nothing op (object
          [ "path" .= ("a.txt" :: String)
          , "patch" .= (diff :: String)
          ]))
        orIsError r `shouldBe` False
        bs <- BS.readFile (root </> "a.txt")
        bs `shouldBe` "first\nsecond\n"

  -- Regression: duplicate context lines (the same context string appears
  -- multiple times in the file) must apply at the position indicated by
  -- the hunk header's line number (used as a hint to disambiguate), not at
  -- the first random match. This is the one place the line number still
  -- matters: content-based search constrained to start near the claimed
  -- line number.
  describe "duplicate context disambiguation" $ do

    it "uses context lines to disambiguate when the removed line is duplicated" $
      withSystemTempDirectory "seal-ws" $ \root -> do
        -- "target" appears on lines 1, 3, and 5. The hunk header claims
        -- -1 (stale — points at the FIRST "target"), but the context
        -- line " marker2" only appears before line 5's "target". A
        -- position-based applier blindly trusts -1 and changes line 1
        -- (corrupting the file); a content-based applier searches for
        -- "marker2\ntarget" and lands at line 5.
        BS.writeFile (root </> "a.txt") "target\nmarker1\ntarget\nmarker2\ntarget\n"
        let op = filePatchOp (WorkspaceRoot root)
            diff = unlines
              [ "--- a.txt"
              , "+++ a.txt"
              , "@@ -1,2 +1,2 @@"
              , " marker2"
              , "-target"
              , "+CHANGED"
              ]
        r <- runTestApp (uoRunLegacy (mkTestUio (WorkspaceRoot root)) Nothing op (object
          [ "path" .= ("a.txt" :: String)
          , "patch" .= (diff :: String)
          ]))
        orIsError r `shouldBe` False
        bs <- BS.readFile (root </> "a.txt")
        bs `shouldBe` "target\nmarker1\ntarget\nmarker2\nCHANGED\n"