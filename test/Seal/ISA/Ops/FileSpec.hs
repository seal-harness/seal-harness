{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.FileSpec (spec) where

import Data.Aeson (object, (.=))
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
  it "reads a file inside the workspace root" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      writeFile (root </> "a.txt") "hello"
      let op = fileReadOp (WorkspaceRoot root)
      r <- runTestApp (opRun op localBackend (object ["path" .= ("a.txt" :: String)]))
      orIsError r `shouldBe` False
      orParts r `shouldBe` [TrpText "hello"]

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
