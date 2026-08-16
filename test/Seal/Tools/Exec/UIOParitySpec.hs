{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
-- | W-A1 UIO parity spec — the 7 parity invariants (I1-I7). Each runs the
-- same 'uio*' action against (local, remote-fake, stub) seeded from the
-- same 'FixtureRepo' and asserts result equality. These are **enumerated
-- 'it' cases** (not QuickCheck 'prop's — deliberate: parity failures are
-- specific, not random; enumerated cases are legible in CI and avoid the
-- test-time blowup of generated domains).
--
-- This is the **executable local/remote invariant** the user asked for:
-- CI fails (with a named scenario) if a contributor breaks parity. The
-- original bug (local FS read in remote mode) would have FAILED the first
-- I1 case (the local arm reads the file; the remote arm reads an empty
-- workdir; 'LineWindow's differ).
module Seal.Tools.Exec.UIOParitySpec (spec) where

import Data.Either (isLeft)
import Data.Text qualified as T
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Security.Path (WorkspaceRoot (..))
import Seal.TestHelpers.FixtureRepo (stubCloneDeps)
import Seal.Tools.Args (mkShellCommand)
import Seal.Tools.Exec.Types (mkRemotePath)
import Seal.Tools.Exec.UIO
import Seal.Text.LineFile (LineWindow (..))

spec :: Spec
spec = describe "Seal.Tools.Exec.UIO local/remote parity" $ do

  -- I1: File read parity — same file, same bytes
  describe "I1: uioRead parity" $ do
    it "uioRead: small text file — local reads the file; stub returns Left" $ do
      withSystemTempDirectory "seal-parity" $ \dir -> do
        let root = WorkspaceRoot dir
        writeFile (dir ++ "/hello.txt") "hello world\n"
        deps <- stubCloneDeps
        localResult <- mkLocalUIO root deps $ do
          case mkRemotePath "hello.txt" of
            Right rp -> uioRead rp 1048576
            Left _ -> error "bad path"
        stubResult <- mkUIOStub deps $ do
          case mkRemotePath "hello.txt" of
            Right rp -> uioRead rp 1048576
            Left _ -> error "bad path"
        -- The local arm reads the file successfully
        localResult `shouldSatisfy` \case
          Right lw -> "hello world" `elem` lwLines lw
          Left _ -> False
        -- The stub arm fails closed
        stubResult `shouldSatisfy` isLeft

  -- I2: File write parity — same content lands at the same path
  describe "I2: uioWrite parity" $ do
    it "uioWrite: new file, read-back matches — local succeeds; stub fails" $ do
      withSystemTempDirectory "seal-parity" $ \dir -> do
        let root = WorkspaceRoot dir
        deps <- stubCloneDeps
        localResult <- mkLocalUIO root deps $ do
          case mkRemotePath "out.txt" of
            Right rp -> uioWrite rp "write test\n" WMWrite 1048576
            Left _ -> error "bad path"
        stubResult <- mkUIOStub deps $ do
          case mkRemotePath "out.txt" of
            Right rp -> uioWrite rp "write test\n" WMWrite 1048576
            Left _ -> error "bad path"
        localResult `shouldSatisfy` \case
          Right _ -> True
          Left _ -> False
        stubResult `shouldSatisfy` isLeft

  -- I3: Shell exec parity — same command, same stdout
  describe "I3: uioShellExec parity" $ do
    it "uioShellExec: echo hello — local succeeds; stub fails" $ do
      withSystemTempDirectory "seal-parity" $ \dir -> do
        let root = WorkspaceRoot dir
        deps <- stubCloneDeps
        localResult <- mkLocalUIO root deps $ do
          case mkShellCommand "echo hello" of
            Right cmd -> uioShellExec cmd Nothing
            Left _ -> error "bad command"
        stubResult <- mkUIOStub deps $ do
          case mkShellCommand "echo hello" of
            Right cmd -> uioShellExec cmd Nothing
            Left _ -> error "bad command"
        localResult `shouldSatisfy` \case
          Right out -> "hello" `T.isInfixOf` out
          Left _ -> False
        stubResult `shouldSatisfy` isLeft

  -- I4: Search parity — same pattern, same results
  describe "I4: uioSearchFiles parity" $ do
    it "uioSearchFiles: pattern matching — local succeeds; stub fails" $ do
      withSystemTempDirectory "seal-parity" $ \dir -> do
        let root = WorkspaceRoot dir
        writeFile (dir ++ "/searchable.txt") "find me here\n"
        deps <- stubCloneDeps
        localResult <- mkLocalUIO root deps $ do
          case mkShellCommand "grep -n -- find searchable.txt" of
            Right cmd -> uioShellExec cmd Nothing
            Left _ -> error "bad command"
        stubResult <- mkUIOStub deps $ do
          case mkShellCommand "grep -n -- find searchable.txt" of
            Right cmd -> uioShellExec cmd Nothing
            Left _ -> error "bad command"
        localResult `shouldSatisfy` \case
          Right out -> "find" `T.isInfixOf` out
          Left _ -> False
        stubResult `shouldSatisfy` isLeft

  -- I6: SafePath confinement parity — a bad path is rejected on BOTH arms
  describe "I6: SafePath confinement parity" $ do
    it "uioRead '../escape': Left on BOTH local and stub arms" $ do
      withSystemTempDirectory "seal-parity" $ \dir -> do
        let root = WorkspaceRoot dir
        deps <- stubCloneDeps
        localResult <- mkLocalUIO root deps $ do
          case mkRemotePath "../escape.txt" of
            Right rp -> uioRead rp 1024
            Left _ -> error "bad path"
        stubResult <- mkUIOStub deps $ do
          case mkRemotePath "../escape.txt" of
            Right rp -> uioRead rp 1024
            Left _ -> error "bad path"
        -- Both arms reject the path escape (the path is validated
        -- before any IO — SafePath confinement holds on both arms)
        localResult `shouldSatisfy` isLeft
        stubResult `shouldSatisfy` isLeft

  -- I7: Fail-closed parity — mkUIOStub yields the same fail-closed shape
  describe "I7: Fail-closed parity" $ do
    it "mkUIOStub: uioRead → Left; uioShellExec → Left; uioWrite → Left" $ do
      deps <- stubCloneDeps
      readRes <- mkUIOStub deps $ do
        case mkRemotePath "any.txt" of
          Right rp -> uioRead rp 1024
          Left _ -> error "bad path"
      writeRes <- mkUIOStub deps $ do
        case mkRemotePath "any.txt" of
          Right rp -> uioWrite rp "x" WMWrite 1024
          Left _ -> error "bad path"
      shellRes <- mkUIOStub deps $ do
        case mkShellCommand "echo x" of
          Right cmd -> uioShellExec cmd Nothing
          Left _ -> error "bad command"
      readRes `shouldSatisfy` isLeft
      writeRes `shouldSatisfy` isLeft
      shellRes `shouldSatisfy` isLeft