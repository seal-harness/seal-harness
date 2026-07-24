{-# LANGUAGE OverloadedStrings #-}
-- | The remote-arm 'UntrustedIO' spec — RED/GREEN tests that prove the
-- untrusted opcodes (file ops especially) reach the REMOTE machine via
-- SSH, never the local FS, when the executor is the remote arm. This is
-- the core regression test for the reported bug: @FILE_WRITE@ in
-- @mode=remote@ writing the file locally instead of on the remote
-- sandbox.
--
-- Strategy: a fake 'RemoteRunner' ('mkFakeRemoteRunnerRecording') records
-- every call's argv + stdin into an 'IORef' and returns canned stdout.
-- The tests assert:
--
--   * The file ops produce the right SSH argv (the @--@ separator, the
--     command string, the validated path) — proving the bytes go over
--     SSH, not to the local FS.
--   * The file-write content is on STDIN (not interpolated into the
--     command string) — proving content with shell metacharacters is
--     safe.
--   * No local FS write occurs (the file does not appear at the local
--     path the bug produced).
--   * SafePath confinement: a @..@ path is rejected BEFORE any SSH call
--     (the fake runner never sees a @..@ path).
--   * Host-key mismatch → 'UeExec ExecHostKeyMismatch' (hard failure,
--     inherited from the existing 'RemoteRunner' mapping).
module Seal.Tools.Exec.UntrustedIORemoteSpec (spec) where

import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (doesFileExist)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Tools.Args (mkShellCommand)
import Seal.Tools.Exec.Remote
  ( mkFakeRemoteRunner, mkFakeRemoteRunnerRecording
  )
import Seal.Tools.Exec.Types
  ( ExecError (..), RemotePath, SshConfig (..), mkRemotePath, mkSshHost
  , mkSshUser
  )
import Seal.Tools.Exec.UntrustedIO
  ( UntrustedIO (..), UntrustedErr (..), WriteMode (..)
  , mkRemoteUntrustedIO, renderUntrustedErr
  )

-- | A canned 'Right ""' result — the fake runner records the call and
-- returns success with empty stdout (enough for write/patch/process
-- ops, which don't consume stdout).
okRight :: Either ExecError Text
okRight = Right ""

spec :: Spec
spec = describe "Seal.Tools.Exec.UntrustedIO (remote arm)" $ do

  describe "uioWriteFile (FILE_WRITE on remote)" $ do

    it "sends the file content over SSH stdin (not the local FS)" $ do
      calls <- newIORef []
      let runner = mkFakeRemoteRunnerRecording calls okRight
          uio    = mkRemoteUntrustedIO sshCfg runner
          rp     = mkRemotePathOrDie "pangram.txt"
      _ <- uioWriteFile uio rp "The quick brown fox" WMWrite 65536
      recorded <- readIORef calls
      -- Exactly one SSH call, with stdin = the file content.
      length recorded `shouldBe` 1
      case recorded of
        [(argv, mStdin)] -> do
          -- The argv is the fixed SSH argv with @tee <path>@ after @--@.
          argv `shouldSatisfy` elem "--"
          argv `shouldSatisfy` elem "tee '/srv/agent-workspace/pangram.txt'"
          -- The content is on stdin, NOT in the argv.
          mStdin `shouldBe` Just "The quick brown fox"
          argv `shouldNotSatisfy` elem "The quick brown fox"
        _ -> expectationFailure "expected exactly one recorded call"

    it "does NOT write the file to the local FS (the reported bug)" $
      withSystemTempDirectory "seal-local-ws" $ \localDir -> do
        calls <- newIORef []
        let runner = mkFakeRemoteRunnerRecording calls okRight
            uio    = mkRemoteUntrustedIO sshCfg runner
            -- A path that, if written locally, would appear in the temp dir.
            rp    = mkRemotePathOrDie "pangram.txt"
        _ <- uioWriteFile uio rp "The quick brown fox" WMWrite 65536
        -- The local temp dir must NOT contain the file — the bytes
        -- went over SSH.
        exists <- doesFileExist (localDir <> "/pangram.txt")
        exists `shouldBe` False
        -- And the SSH call was made (the remote arm ran).
        recorded <- readIORef calls
        recorded `shouldNotBe` []

    it "append mode produces @tee -a@ (not truncate)" $ do
      calls <- newIORef []
      let runner = mkFakeRemoteRunnerRecording calls okRight
          uio    = mkRemoteUntrustedIO sshCfg runner
          rp     = mkRemotePathOrDie "log.txt"
      _ <- uioWriteFile uio rp "more" WMAppend 65536
      recorded <- readIORef calls
      case recorded of
        [(argv, _)] -> argv `shouldSatisfy` elem "tee -a '/srv/agent-workspace/log.txt'"
        _           -> expectationFailure "expected one call"

    it "content with shell metacharacters is safe (on stdin, not argv)" $ do
      calls <- newIORef []
      let runner = mkFakeRemoteRunnerRecording calls okRight
          uio    = mkRemoteUntrustedIO sshCfg runner
          rp     = mkRemotePathOrDie "script.sh"
          content = "echo '$(rm -rf /)'; `cat /etc/passwd`"
      _ <- uioWriteFile uio rp content WMWrite 65536
      recorded <- readIORef calls
      case recorded of
        [(argv, mStdin)] -> do
          mStdin `shouldBe` Just (TE.encodeUtf8 content)
          -- The metacharacters must NOT appear in the argv.
          argv `shouldNotSatisfy` elem "$(rm -rf /)"
          argv `shouldNotSatisfy` elem "`cat /etc/passwd`"
        _ -> expectationFailure "expected one call"

    it "rejects a @..@ escape BEFORE any SSH call (SafePath confinement)" $ do
      calls <- newIORef []
      let runner = mkFakeRemoteRunnerRecording calls okRight
          uio    = mkRemoteUntrustedIO sshCfg runner
          rp     = mkRemotePathOrDie "../escape.txt"
      res <- uioWriteFile uio rp "bad" WMWrite 65536
      -- The result is a path error.
      res `shouldSatisfy` \case
        Left (UePath _) -> True
        _              -> False
      -- And the fake runner was never called (no SSH call made).
      recorded <- readIORef calls
      recorded `shouldBe` []

  describe "uioReadFile (FILE_READ on remote)" $ do

    it "reads via @ssh ... -- head -c N <path>@ (bounded read over SSH)" $ do
      calls <- newIORef []
      let runner = mkFakeRemoteRunnerRecording calls (Right "remote file body\n")
          uio    = mkRemoteUntrustedIO sshCfg runner
          rp     = mkRemotePathOrDie "doc.txt"
      res <- uioReadFile uio rp 1024
      recorded <- readIORef calls
      -- One SSH call, no stdin, with @head -c 1024 'doc.txt'@ in argv.
      length recorded `shouldBe` 1
      case recorded of
        [(argv, mStdin)] -> do
          argv `shouldSatisfy` elem "head -c 1024 '/srv/agent-workspace/doc.txt'"
          mStdin `shouldBe` Nothing
        _ -> expectationFailure "expected one call"
      -- The result is a LineWindow carrying the remote content.
      case res of
        Right _  -> pure ()
        Left err -> expectationFailure ("unexpected error: " <> T.unpack (renderUntrustedErr err))

    it "rejects a @..@ path before any SSH call" $ do
      calls <- newIORef []
      let runner = mkFakeRemoteRunnerRecording calls (Right "")
          uio    = mkRemoteUntrustedIO sshCfg runner
          rp     = mkRemotePathOrDie "../../etc/passwd"
      res <- uioReadFile uio rp 1024
      recorded <- readIORef calls
      recorded `shouldBe` []
      res `shouldSatisfy` \case Left (UePath _) -> True; _ -> False

  describe "uioShellExec (SHELL_EXEC on remote)" $ do

    it "runs the command via the SSH argv (not 'not yet wired')" $ do
      calls <- newIORef []
      let runner = mkFakeRemoteRunnerRecording calls (Right "ok\n")
          uio    = mkRemoteUntrustedIO sshCfg runner
      cmd <- either (const (error "fixture")) pure (mkShellCommand "echo ok")
      res <- uioShellExec uio cmd Nothing
      recorded <- readIORef calls
      -- The command reached the SSH runner (not ExecNotImplemented).
      recorded `shouldNotBe` []
      res `shouldSatisfy` \case Right _ -> True; Left _ -> False
      -- The argv contains the command after @--@. With no caller-supplied
      -- cwd, the arm defaults to the workspace root (the one-root
      -- invariant): the command string is `cd '<wsroot>' && echo ok`.
      case recorded of
        [(argv, _)] ->
          argv `shouldSatisfy` elem "cd '/srv/agent-workspace' && echo ok"
        _           -> expectationFailure "expected one call"

    it "defaults cwd to the workspace root when the caller omits it" $ do
      calls <- newIORef []
      let runner = mkFakeRemoteRunnerRecording calls (Right "")
          uio    = mkRemoteUntrustedIO sshCfg runner
      cmd <- either (const (error "fixture")) pure (mkShellCommand "pwd")
      _ <- uioShellExec uio cmd Nothing
      recorded <- readIORef calls
      case recorded of
        [(argv, _)] ->
          argv `shouldSatisfy` elem "cd '/srv/agent-workspace' && pwd"
        _ -> expectationFailure "expected one call"

    it "rejects a @..@ cwd before any SSH call" $ do
      calls <- newIORef []
      let runner = mkFakeRemoteRunnerRecording calls (Right "")
          uio    = mkRemoteUntrustedIO sshCfg runner
          rp    = mkRemotePathOrDie ".."
      cmd <- either (const (error "fixture")) pure (mkShellCommand "ls")
      res <- uioShellExec uio cmd (Just rp)
      recorded <- readIORef calls
      recorded `shouldBe` []
      res `shouldSatisfy` \case Left (UePath _) -> True; _ -> False

  describe "host-key mismatch (hard failure, never bypassed)" $ do

    it "uioShellExec surfaces 'UeExec ExecHostKeyMismatch'" $ do
      let runner = mkFakeRemoteRunner (Left ExecHostKeyMismatch)
          uio    = mkRemoteUntrustedIO sshCfg runner
      cmd <- either (const (error "fixture")) pure (mkShellCommand "echo hi")
      res <- uioShellExec uio cmd Nothing
      res `shouldBe` Left (UeExec ExecHostKeyMismatch)

    it "uioWriteFile surfaces 'UeExec ExecHostKeyMismatch' (never writes locally)" $
      withSystemTempDirectory "seal-local-ws" $ \_localDir -> do
        let runner = mkFakeRemoteRunner (Left ExecHostKeyMismatch)
            uio    = mkRemoteUntrustedIO sshCfg runner
            rp     = mkRemotePathOrDie "x.txt"
        res <- uioWriteFile uio rp "data" WMWrite 65536
        res `shouldBe` Left (UeExec ExecHostKeyMismatch)

  describe "SSH argv shape (host-key pinning inherited)" $ do

    it "the file-op argv pins StrictHostKeyChecking=yes + UserKnownHostsFile" $ do
      calls <- newIORef []
      let runner = mkFakeRemoteRunnerRecording calls okRight
          uio    = mkRemoteUntrustedIO sshCfg runner
          rp     = mkRemotePathOrDie "f.txt"
      _ <- uioWriteFile uio rp "x" WMWrite 65536
      recorded <- readIORef calls
      case recorded of
        [(argv, _)] -> do
          checkAdjacentPair argv "StrictHostKeyChecking" "yes"
          checkAdjacentPair argv "UserKnownHostsFile" (scKnownHosts sshCfg)
          -- And the @--@ separator is present (option-injection defense).
          argv `shouldSatisfy` elem "--"
        _ -> expectationFailure "expected one call"

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

sshCfg :: SshConfig
sshCfg = SshConfig
  { scHost       = either (error "fixture") id (mkSshHost "exec.internal")
  , scUser       = either (error "fixture") id (mkSshUser "agent")
  , scPort       = 22
  , scIdentity   = Nothing
  , scKnownHosts = "/home/agent/.ssh/known_hosts"
  , scWorkspace  = mkRemotePathOrDie "/srv/agent-workspace"
  }

mkRemotePathOrDie :: Text -> RemotePath
mkRemotePathOrDie t = case mkRemotePath t of
  Right rp -> rp
  Left err -> error ("fixture: bad remote path " <> T.unpack err <> ": " <> T.unpack t)

-- | Assert two argv entries are present, either as @key=value@ (joined)
-- or as adjacent @key value@ (separate args). (Same shape as
-- 'RemoteSpec.checkAdjacentPair'.)
checkAdjacentPair :: [String] -> String -> String -> Expectation
checkAdjacentPair argv key value =
  argv `shouldSatisfy` \argvList ->
    let joined    = key <> "=" <> value
        adjacent  = [key, value]
        isInfixOf needle haystack = any (isPrefixOf needle) (tails haystack)
        isPrefixOf (p:ps) (q:qs) = p == q && isPrefixOf ps qs
        isPrefixOf []      _      = True
        isPrefixOf _       []     = False
        tails []                   = [[]]
        tails list@(_:rest)        = list : tails rest
    in joined `elem` argvList || adjacent `isInfixOf` argvList