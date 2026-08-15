{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
-- | W-A1 UIO spec — tests the 'UIO' monad's basic operation:
--
-- 1. The 'uio*' functions round-trip on the local arm (read/write/shell).
-- 2. The stub arm ('mkUIOStub') is fail-closed (every op returns 'Left').
-- 3. 'runUIOWithEnv' round-trips a pre-built 'UIOEnv'.
module Seal.Tools.Exec.UIOSpec (spec) where

import Data.Either (isLeft, isRight)
import Data.Text (Text)
import Data.Text qualified as T
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Security.Path (WorkspaceRoot (..))
import Seal.TestHelpers.FixtureRepo (stubCloneDeps)
import Seal.Tools.Args (mkShellCommand)
import Seal.Tools.Exec.Types (mkRemotePath)
import Seal.Tools.Exec.UntrustedIO (mkLocalUntrustedIO)
import Seal.Tools.Exec.UIO
import Seal.Text.LineFile (LineWindow (..))

spec :: Spec
spec = describe "Seal.Tools.Exec.UIO" $ do

  --------------------------------------------------------------------------
  -- uio* round-trip on the local arm
  --------------------------------------------------------------------------

  describe "local arm (mkLocalUIO)" $ do
    it "uioRead reads a file written by uioWrite" $ do
      withSystemTempDirectory "seal-uio" $ \dir -> do
        deps <- stubCloneDeps
        let root = WorkspaceRoot dir
            content = "hello world\n" :: Text
        (wRes, rRes) <- mkLocalUIO root deps $ do
          case mkRemotePath "test.txt" of
            Left _ -> error "bad path"
            Right rp -> do
              w <- uioWrite rp content WMWrite 1048576
              r <- uioRead rp 1048576
              pure (w, r)
        wRes `shouldBe` Right 12
        lwLines <$> rRes `shouldBe` Right (T.lines content)

    it "uioShellExec runs a command" $ do
      withSystemTempDirectory "seal-uio" $ \dir -> do
        deps <- stubCloneDeps
        let root = WorkspaceRoot dir
        result <- mkLocalUIO root deps $ do
          case mkShellCommand "echo hello" of
            Left _ -> error "bad command"
            Right cmd -> uioShellExec cmd Nothing
        result `shouldSatisfy` \case
          Right out -> "hello" `T.isInfixOf` out
          Left _ -> False

  --------------------------------------------------------------------------
  -- stub arm (mkUIOStub) — fail-closed
  --------------------------------------------------------------------------

  describe "stub arm (mkUIOStub)" $ do
    it "uioRead returns Left" $ do
      deps <- stubCloneDeps
      result <- mkUIOStub deps $ do
        case mkRemotePath "anyfile.txt" of
          Left _ -> error "bad path"
          Right rp -> uioRead rp 1024
      result `shouldSatisfy` isLeft

    it "uioWrite returns Left" $ do
      deps <- stubCloneDeps
      result <- mkUIOStub deps $ do
        case mkRemotePath "anyfile.txt" of
          Left _ -> error "bad path"
          Right rp -> uioWrite rp "content" WMWrite 1024
      result `shouldSatisfy` isLeft

    it "uioShellExec returns Left" $ do
      deps <- stubCloneDeps
      result <- mkUIOStub deps $ do
        case mkShellCommand "echo hello" of
          Left _ -> error "bad command"
          Right cmd -> uioShellExec cmd Nothing
      result `shouldSatisfy` isLeft

  --------------------------------------------------------------------------
  -- runUIOWithEnv round-trip
  --------------------------------------------------------------------------

  describe "runUIOWithEnv" $ do
    it "round-trips a pre-built UIOEnv" $ do
      withSystemTempDirectory "seal-uio" $ \dir -> do
        deps <- stubCloneDeps
        let root = WorkspaceRoot dir
            uio = mkLocalUntrustedIO root
            env = mkTestUIOEnv uio deps
        result <- runUIOWithEnv env $ do
          case mkRemotePath "envtest.txt" of
            Left _ -> error "bad path"
            Right rp -> do
              _ <- uioWrite rp "env test\n" WMWrite 1024
              uioRead rp 1024
        result `shouldSatisfy` isRight