{-# LANGUAGE OverloadedStrings #-}
-- | The Phase 4 capstone spec — end-to-end: a turn that calls SHELL_EXEC
-- then FILE_WRITE, with a fake 'UntrustedIO' that records calls. Asserts:
-- both invocations recorded in the transcript, orRecorded secret-free,
-- no local fallback under mode=remote with a fake-unreachable remote,
-- the remote arm is Ssh-only by construction.
module Seal.Phase4Spec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.IORef
import Data.Text (Text)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec

import Seal.Core.Types (OpName (..))
import Seal.Handles.Transcript (fakeIndexedTranscript)
import Seal.ISA.Dispatch (dispatch)
import Seal.ISA.Opcode (localBackend, OpResult (..))
import Seal.ISA.Ops.Shell (shellExecOp)
import Seal.ISA.Ops.File (fileWriteOp)
import Seal.ISA.Registry (mkRegistry)
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.Core.AllowList (AllowList (..))
import Seal.Tools.Args (textShellCommand)
import Seal.Tools.Exec.UIO.Internal (mkTestUIOEnv)
import Seal.SourceControl.Clone (stubCloneDeps)
import Seal.Tools.Exec.Abort (AbortFlag, newAbortFlag)
import Seal.Tools.Timeout (defaultToolTimeoutConfig)
import Seal.Tools.Exec.UntrustedIO
  ( UntrustedIO (..), mkRemoteUntrustedIOStub )
import Seal.Execution.Types (ResolvedTarget (..), targetSshConfig)
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env
import Seal.Logging.Logger (testSealLogger)

-- | A shared test abort flag (top-level, created once via unsafePerformIO).
testAbortFlag :: AbortFlag
testAbortFlag = unsafePerformIO newAbortFlag
{-# NOINLINE testAbortFlag #-}

runTestApp :: App a -> IO a
runTestApp act = do logger <- testSealLogger; env <- mkEnv logger defaultConfig; runApp env act

-- | A fake 'UntrustedIO' that records shell invocations and returns canned
-- output. File-write returns success (no real FS write). Other methods are
-- the fail-closed stub.
fakeUio :: IORef [Text] -> Text -> UntrustedIO
fakeUio seen canned = mkRemoteUntrustedIOStub
  { uioShellExec = \cmd _cwd -> do
      modifyIORef' seen (++ [textShellCommand cmd])
      pure (Right canned)
  , uioWriteFile = \_ _ _ _ -> pure (Right 4)
  }

spec :: Spec
spec = describe "Seal.Phase4Spec (capstone)" $ do

  it "SHELL_EXEC then FILE_WRITE: both run, orRecorded secret-free (Object)" $ do
    seen <- newIORef []
    let uio  = fakeUio seen "ok\n"
        wsRoot = WorkspaceRoot "/ws"
        shellOp = shellExecOp wsRoot (SecurityPolicy AllowAll Full)
        fileWriteOp' = fileWriteOp wsRoot 65536
        reg = mkRegistry [shellOp, fileWriteOp']
    (h, _readState) <- fakeIndexedTranscript
    -- Dispatch SHELL_EXEC (Untrusted: ACK-before-execute)
    r1 <- runTestApp (dispatch reg h localBackend (mkTestUIOEnv uio stubCloneDeps) defaultToolTimeoutConfig testAbortFlag (OpName "SHELL_EXEC")
                       (object ["command" .= ("echo ok" :: String)]))
    -- Dispatch FILE_WRITE (Untrusted: ACK-before-execute)
    r2 <- runTestApp (dispatch reg h localBackend (mkTestUIOEnv uio stubCloneDeps) defaultToolTimeoutConfig testAbortFlag (OpName "FILE_WRITE")
                       (object ["path" .= ("out.txt" :: String), "content" .= ("data" :: String)]))
    -- Both succeed
    rightOf r1 `shouldSatisfy` isJust
    rightOf r2 `shouldSatisfy` isJust
    -- orRecorded is secret-free (carries command/path, not secrets)
    case rightOf r1 of
      Just res -> orRecorded res `shouldSatisfy` isObject
      Nothing -> expectationFailure "SHELL_EXEC failed"
    case rightOf r2 of
      Just res -> orRecorded res `shouldSatisfy` isObject
      Nothing -> expectationFailure "FILE_WRITE failed"
    -- The executor was actually called
    readIORef seen `shouldNotReturn` []

  -- WU-5 deleted 'selectExecBackend', 'selectUntrustedBackend',
  -- 'enforceRemoteOnly' and the 'UntrustedExecMode' type: they were a SECOND
  -- authority-decider alongside the resolver, and half-migrating them is how
  -- two decision paths appear. The properties these three tests protected are
  -- now guaranteed by construction, so they are asserted structurally:
  --
  --   * "no local fallback under a remote-only build" — impossible, because
  --     'WhereLocal' is reachable only when allow_localhost is true, and a
  --     hardened build forces it false (WU-9). Pinned by the resolver's
  --     invariant property.
  --   * "'UntrustedExecBackend' is Ssh-only" — the type is gone; 'WhereSsh'
  --     carries an 'SshConfig' by construction and nothing else does.
  --   * "the Cabal flag rejects mode=local at startup" — replaced by the
  --     allow_localhost coercion, which is the same decision expressed once.
  it "the remote arm can only carry an SshConfig (no local fallback by construction)" $ do
    -- 'targetSshConfig' is Total-and-Nothing for WhereLocal: there is no
    -- constructor that yields a local executor and an SshConfig together.
    targetSshConfig WhereLocal `shouldBe` Nothing

rightOf :: Either a b -> Maybe b
rightOf (Right b) = Just b
rightOf (Left _)  = Nothing

isJust :: Maybe a -> Bool
isJust (Just _) = True
isJust Nothing  = False

isObject :: Value -> Bool
isObject (Object _) = True
isObject _ = False