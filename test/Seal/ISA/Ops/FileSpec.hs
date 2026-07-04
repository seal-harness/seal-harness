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
import Seal.ISA.Ops.File
import Seal.Providers.Class
import Seal.Security.Path
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env

runTestApp :: App a -> IO a
runTestApp act = do env <- mkEnv defaultConfig; runApp env act

spec :: Spec
spec = describe "Seal.ISA.Ops.File" $ do

  it "reads a small file inside the workspace root: windowed content + footer" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello"
      let op = fileReadOp (WorkspaceRoot root)
      r <- runTestApp (opRun op localBackend (object ["path" .= ("a.txt" :: String)]))
      orIsError r `shouldBe` False
      orParts r `shouldBe` [TrpText "hello\n\n[lines 1-1 of 1 (end of file)]"]

  it "orRecorded captures path + offset + limit (uniform in both branches)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello"
      let op = fileReadOp (WorkspaceRoot root)
      r <- runTestApp (opRun op localBackend (object ["path" .= ("a.txt" :: String)]))
      orRecorded r `shouldBe` object
        [ "path" .= ("a.txt" :: String)
        , "offset" .= (0 :: Int)
        , "limit" .= (Nothing :: Maybe Int)
        ]

  it "passes offset and limit through to the window and orRecorded" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      let ls = ["l" <> showN i | i <- [1..30 :: Int]]
          body = unlinesStr ls
      BS.writeFile (root </> "p.txt") body
      let op = fileReadOp (WorkspaceRoot root)
      r <- runTestApp (opRun op localBackend (object
              [ "path" .= ("p.txt" :: String)
              , "offset" .= (5 :: Int)
              , "limit" .= (3 :: Int)
              ]))
      orIsError r `shouldBe` False
      orRecorded r `shouldBe` object
        [ "path" .= ("p.txt" :: String)
        , "offset" .= (5 :: Int)
        , "limit" .= (Just 3 :: Maybe Int)
        ]
      -- The window should start at offset 5 (line "l6") and have 3 lines.
      orParts r `shouldBe` [TrpText
        "l6\nl7\nl8\n\n[lines 6-8 of 30; 22 more - read with offset=8 for the next window]"]

  it "lenient offset/limit: malformed values fall back to defaults (no throw)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello"
      let op = fileReadOp (WorkspaceRoot root)
      r <- runTestApp (opRun op localBackend (object
              [ "path" .= ("a.txt" :: String)
              , "offset" .= ("oops" :: String)
              , "limit" .= (2.5 :: Double)
              ]))
      orIsError r `shouldBe` False
      orRecorded r `shouldBe` object
        [ "path" .= ("a.txt" :: String)
        , "offset" .= (0 :: Int)
        , "limit" .= (Nothing :: Maybe Int)
        ]

  it "negative offset falls back to 0" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      BS.writeFile (root </> "a.txt") "hello"
      let op = fileReadOp (WorkspaceRoot root)
      r <- runTestApp (opRun op localBackend (object
              [ "path" .= ("a.txt" :: String)
              , "offset" .= (-5 :: Int)
              ]))
      orIsError r `shouldBe` False
      orRecorded r `shouldBe` object
        [ "path" .= ("a.txt" :: String)
        , "offset" .= (0 :: Int)
        , "limit" .= (Nothing :: Maybe Int)
        ]

  it "large file returns bounded content, not the whole file" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      -- 1000 short lines, much larger than the pager ceiling of 200.
      let ls = [showN i | i <- [1..1000 :: Int]]
          body = unlinesStr ls
      BS.writeFile (root </> "big.txt") body
      let op = fileReadOp (WorkspaceRoot root)
      r <- runTestApp (opRun op localBackend (object ["path" .= ("big.txt" :: String)]))
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
      let op = fileReadOp (WorkspaceRoot root)
      r <- runTestApp (opRun op localBackend (object ["path" .= ("empty.txt" :: String)]))
      orIsError r `shouldBe` False
      orParts r `shouldBe` [TrpText "[empty file (0 lines)]"]

  it "rejects a traversal escape with an error result (no read)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      let op = fileReadOp (WorkspaceRoot root)
      r <- runTestApp (opRun op localBackend (object ["path" .= ("../escape" :: String)]))
      orIsError r `shouldBe` True

  it "returns an error for a nonexistent file" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      let op = fileReadOp (WorkspaceRoot root)
      r <- runTestApp (opRun op localBackend (object ["path" .= ("nonexistent.txt" :: String)]))
      orIsError r `shouldBe` True

  it "returns an error result when the path is a directory (IOError caught)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      createDirectory (root </> "adir")
      let op = fileReadOp (WorkspaceRoot root)
      r <- runTestApp (opRun op localBackend (object ["path" .= ("adir" :: String)]))
      orIsError r `shouldBe` True

  where
    showN :: Int -> Text
    showN = T.pack . show
    unlinesStr :: [Text] -> ByteString
    unlinesStr xss = BS.intercalate "\n" (map TE.encodeUtf8 xss) <> "\n"