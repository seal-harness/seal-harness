{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.FileSpec (spec) where

import Data.Aeson (object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (createDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.ISA.Opcode
import Seal.Tools.Exec.UntrustedIO (UntrustedIO, mkLocalUntrustedIO)
import Seal.ISA.Ops.File
import Seal.Providers.Class
import Seal.Security.Path
import Seal.Text.LineFile (maxScanBytes)
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env

runTestApp :: App a -> IO a
runTestApp act = do env <- mkEnv defaultConfig; runApp env act

-- | The local 'UntrustedIO' handle for the test (real local FS IO via the
-- workspace root). Tests that need a temp workspace build this per-test
-- with the temp dir as the workspace root.
mkTestUio :: WorkspaceRoot -> UntrustedIO
mkTestUio = mkLocalUntrustedIO
spec :: Spec
spec = describe "Seal.ISA.Ops.File" $ do

  it "reads a small file inside the workspace root: windowed content + footer" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello"
      let op = fileReadOp (WorkspaceRoot root) maxScanBytes
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object ["path" .= ("a.txt" :: String)]))
      orIsError r `shouldBe` False
      orParts r `shouldBe` [TrpText "hello\n\n[lines 1-1 of 1 (end of file)]"]

  it "orRecorded captures path + offset + limit + resolved max_scan_bytes (uniform in both branches)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello"
      let op = fileReadOp (WorkspaceRoot root) maxScanBytes
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object ["path" .= ("a.txt" :: String)]))
      orRecorded r `shouldBe` object
        [ "path" .= ("a.txt" :: String)
        , "offset" .= (0 :: Int)
        , "limit" .= (Nothing :: Maybe Int)
        , "max_scan_bytes" .= (maxScanBytes :: Int)
        ]

  it "passes offset and limit through to the window and orRecorded" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      let ls = ["l" <> showN i | i <- [1..30 :: Int]]
          body = unlinesStr ls
      BS.writeFile (root </> "p.txt") body
      let op = fileReadOp (WorkspaceRoot root) maxScanBytes
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
              [ "path" .= ("p.txt" :: String)
              , "offset" .= (5 :: Int)
              , "limit" .= (3 :: Int)
              ]))
      orIsError r `shouldBe` False
      orRecorded r `shouldBe` object
        [ "path" .= ("p.txt" :: String)
        , "offset" .= (5 :: Int)
        , "limit" .= (Just 3 :: Maybe Int)
        , "max_scan_bytes" .= (maxScanBytes :: Int)
        ]
      -- The window should start at offset 5 (line "l6") and have 3 lines.
      orParts r `shouldBe` [TrpText
        "l6\nl7\nl8\n\n[lines 6-8 of 30; 22 more - read with offset=8 for the next window]"]

  it "lenient offset/limit/max_scan_bytes: malformed values fall back to defaults (no throw)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello"
      let op = fileReadOp (WorkspaceRoot root) maxScanBytes
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
              [ "path" .= ("a.txt" :: String)
              , "offset" .= ("oops" :: String)
              , "limit" .= (2.5 :: Double)
              , "max_scan_bytes" .= ("big" :: String)
              ]))
      orIsError r `shouldBe` False
      orRecorded r `shouldBe` object
        [ "path" .= ("a.txt" :: String)
        , "offset" .= (0 :: Int)
        , "limit" .= (Nothing :: Maybe Int)
        , "max_scan_bytes" .= (maxScanBytes :: Int)
        ]

  it "negative offset falls back to 0" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello"
      let op = fileReadOp (WorkspaceRoot root) maxScanBytes
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
              [ "path" .= ("a.txt" :: String)
              , "offset" .= (-5 :: Int)
              ]))
      orIsError r `shouldBe` False
      orRecorded r `shouldBe` object
        [ "path" .= ("a.txt" :: String)
        , "offset" .= (0 :: Int)
        , "limit" .= (Nothing :: Maybe Int)
        , "max_scan_bytes" .= (maxScanBytes :: Int)
        ]

  -- Regression: models in the wild emit `offset` as a JSON string (e.g.
  -- "72") even though the schema declares integer. The field parsers must
  -- coerce a numeric string instead of silently falling back to 0 (which
  -- returns the first window again, trapping the model in a loop). See
  -- session 20260724-133418-292.
  it "offset as a numeric string is coerced (not dropped to 0)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      let ls = ["l" <> showN i | i <- [1..30 :: Int]]
          body = unlinesStr ls
      BS.writeFile (root </> "p.txt") body
      let op = fileReadOp (WorkspaceRoot root) maxScanBytes
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
              [ "path" .= ("p.txt" :: String)
              , "offset" .= ("5" :: String)
              , "limit" .= (3 :: Int)
              ]))
      orIsError r `shouldBe` False
      orRecorded r `shouldBe` object
        [ "path" .= ("p.txt" :: String)
        , "offset" .= (5 :: Int)
        , "limit" .= (Just 3 :: Maybe Int)
        , "max_scan_bytes" .= (maxScanBytes :: Int)
        ]
      -- The window should start at offset 5 (line "l6") and have 3 lines.
      orParts r `shouldBe` [TrpText
        "l6\nl7\nl8\n\n[lines 6-8 of 30; 22 more - read with offset=8 for the next window]"]

  it "limit as a numeric string is coerced (not dropped to default)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      let ls = ["l" <> showN i | i <- [1..30 :: Int]]
          body = unlinesStr ls
      BS.writeFile (root </> "p.txt") body
      let op = fileReadOp (WorkspaceRoot root) maxScanBytes
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
              [ "path" .= ("p.txt" :: String)
              , "limit" .= ("3" :: String)
              ]))
      orIsError r `shouldBe` False
      orRecorded r `shouldBe` object
        [ "path" .= ("p.txt" :: String)
        , "offset" .= (0 :: Int)
        , "limit" .= (Just 3 :: Maybe Int)
        , "max_scan_bytes" .= (maxScanBytes :: Int)
        ]
      orParts r `shouldBe` [TrpText
        "l1\nl2\nl3\n\n[lines 1-3 of 30; 27 more - read with offset=3 for the next window]"]

  it "max_scan_bytes as a numeric string is coerced (not dropped to default)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello"
      let op = fileReadOp (WorkspaceRoot root) maxScanBytes
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
              [ "path" .= ("a.txt" :: String)
              , "max_scan_bytes" .= ("16" :: String)
              ]))
      orIsError r `shouldBe` False
      orRecorded r `shouldBe` object
        [ "path" .= ("a.txt" :: String)
        , "offset" .= (0 :: Int)
        , "limit" .= (Nothing :: Maybe Int)
        , "max_scan_bytes" .= (16 :: Int)
        ]

  it "offset as a non-numeric string still falls back to 0" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello"
      let op = fileReadOp (WorkspaceRoot root) maxScanBytes
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
              [ "path" .= ("a.txt" :: String)
              , "offset" .= ("banana" :: String)
              ]))
      orIsError r `shouldBe` False
      orRecorded r `shouldBe` object
        [ "path" .= ("a.txt" :: String)
        , "offset" .= (0 :: Int)
        , "limit" .= (Nothing :: Maybe Int)
        , "max_scan_bytes" .= (maxScanBytes :: Int)
        ]

  it "max_scan_bytes request below operator ceiling narrows the scan (clamp down)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      -- 10 lines of "x\n" = 20 bytes. Operator ceiling = maxScanBytes (large);
      -- model requests max_scan_bytes = 5 -> scans 2 lines, truncated.
      let body = BS.concat (replicate 10 "x\n")
      BS.writeFile (root </> "r.txt") body
      let op = fileReadOp (WorkspaceRoot root) maxScanBytes
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
              [ "path" .= ("r.txt" :: String)
              , "max_scan_bytes" .= (5 :: Int)
              ]))
      orIsError r `shouldBe` False
      -- The resolved (clamped-down) value is recorded.
      orRecorded r `shouldBe` object
        [ "path" .= ("r.txt" :: String)
        , "offset" .= (0 :: Int)
        , "limit" .= (Nothing :: Maybe Int)
        , "max_scan_bytes" .= (5 :: Int)
        ]
      case orParts r of
        [TrpText out] -> do
          -- 2 lines scanned ("x\nx"), then truncated; footer is guard 4.
          T.unpack out `shouldContain` "lines 1-2 of >=2"
          T.unpack out `shouldContain` "file exceeds scan limit"
        _ -> expectationFailure "expected a single TrpText part"

  it "max_scan_bytes request above operator ceiling clamps down to the operator bound" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello"
      -- Operator ceiling = 32 (small); model requests 999999 -> clamps to 32.
      let op = fileReadOp (WorkspaceRoot root) 32
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
              [ "path" .= ("a.txt" :: String)
              , "max_scan_bytes" .= (999999 :: Int)
              ]))
      orIsError r `shouldBe` False
      orRecorded r `shouldBe` object
        [ "path" .= ("a.txt" :: String)
        , "offset" .= (0 :: Int)
        , "limit" .= (Nothing :: Maybe Int)
        , "max_scan_bytes" .= (32 :: Int)
        ]

  it "max_scan_bytes = 0 (degenerate) falls back to the operator ceiling" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello"
      let op = fileReadOp (WorkspaceRoot root) maxScanBytes
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
              [ "path" .= ("a.txt" :: String)
              , "max_scan_bytes" .= (0 :: Int)
              ]))
      orIsError r `shouldBe` False
      orRecorded r `shouldBe` object
        [ "path" .= ("a.txt" :: String)
        , "offset" .= (0 :: Int)
        , "limit" .= (Nothing :: Maybe Int)
        , "max_scan_bytes" .= (maxScanBytes :: Int)
        ]

  it "large file returns bounded content, not the whole file" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      -- 1000 short lines, much larger than the pager ceiling of 200.
      let ls = [showN i | i <- [1..1000 :: Int]]
          body = unlinesStr ls
      BS.writeFile (root </> "big.txt") body
      let op = fileReadOp (WorkspaceRoot root) maxScanBytes
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object ["path" .= ("big.txt" :: String)]))
      orIsError r `shouldBe` False
      case orParts r of
        [TrpText out] -> do
          -- The body must NOT contain line 1000 as a content line (bounded,
          -- not the whole file). Split content from footer on "\n\n[".
          let (content, _footer) = T.breakOn "\n\n[" out
              contentLineCount = max 0 (length (filter (== '\n') (T.unpack content)))
          contentLineCount `shouldSatisfy` (< 1000)
          -- And the footer must indicate there is more to read.
          T.unpack out `shouldContain` " more - read with offset="
        _ -> expectationFailure "expected a single TrpText part"

  it "empty file returns the empty-file footer" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "empty.txt") ""
      let op = fileReadOp (WorkspaceRoot root) maxScanBytes
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object ["path" .= ("empty.txt" :: String)]))
      orIsError r `shouldBe` False
      orParts r `shouldBe` [TrpText "[empty file (0 lines)]"]

  it "rejects a traversal escape with an error result (no read)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      let op = fileReadOp (WorkspaceRoot root) maxScanBytes
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object ["path" .= ("../escape" :: String)]))
      orIsError r `shouldBe` True

  it "returns an error for a nonexistent file" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      let op = fileReadOp (WorkspaceRoot root) maxScanBytes
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object ["path" .= ("nonexistent.txt" :: String)]))
      orIsError r `shouldBe` True

  it "returns an error result when the path is a directory (IOError caught)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      createDirectory (root </> "adir")
      let op = fileReadOp (WorkspaceRoot root) maxScanBytes
      r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object ["path" .= ("adir" :: String)]))
      orIsError r `shouldBe` True

  describe "FILE_WRITE" $ do

    it "writes content to a file inside the workspace" $
      withSystemTempDirectory "seal-ws" $ \root -> do
        let op = fileWriteOp (WorkspaceRoot root) maxWriteBytes
        r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
          [ "path" .= ("out.txt" :: String)
          , "content" .= ("hello world" :: String)
          ]))
        orIsError r `shouldBe` False
        bs <- BS.readFile (root </> "out.txt")
        bs `shouldBe` "hello world"

    it "appends content when mode = append" $
      withSystemTempDirectory "seal-ws" $ \root -> do
        BS.writeFile (root </> "out.txt") "first "
        let op = fileWriteOp (WorkspaceRoot root) maxWriteBytes
        r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
          [ "path" .= ("out.txt" :: String)
          , "content" .= ("second" :: String)
          , "mode" .= ("append" :: String)
          ]))
        orIsError r `shouldBe` False
        bs <- BS.readFile (root </> "out.txt")
        bs `shouldBe` "first second"

    it "orRecorded captures path + mode + byte count (not the content)" $
      withSystemTempDirectory "seal-ws" $ \root -> do
        let op = fileWriteOp (WorkspaceRoot root) maxWriteBytes
        r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
          [ "path" .= ("out.txt" :: String)
          , "content" .= ("hi" :: String)
          ]))
        orRecorded r `shouldBe` object
          [ "path" .= ("out.txt" :: String)
          , "mode" .= ("write" :: String)
          , "bytes" .= (2 :: Int)
          ]

    it "rejects a path traversal escape (no write)" $
      withSystemTempDirectory "seal-ws" $ \root -> do
        let op = fileWriteOp (WorkspaceRoot root) maxWriteBytes
        r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
          [ "path" .= ("../escape.txt" :: String)
          , "content" .= ("bad" :: String)
          ]))
        orIsError r `shouldBe` True

    it "rejects oversized content (bounded write)" $
      withSystemTempDirectory "seal-ws" $ \root -> do
        let op = fileWriteOp (WorkspaceRoot root) 5  -- max 5 bytes
        r <- runTestApp (uoRun op (mkTestUio (WorkspaceRoot root)) (object
          [ "path" .= ("big.txt" :: String)
          , "content" .= ("this is way too long" :: String)
          ]))
        orIsError r `shouldBe` True

  where
    showN :: Int -> Text
    showN = T.pack . show
    unlinesStr :: [Text] -> ByteString
    unlinesStr xss = BS.intercalate "\n" (map TE.encodeUtf8 xss) <> "\n"

maxWriteBytes :: Int
maxWriteBytes = 65536   -- 64 KiB, mirrors the FILE_READ default