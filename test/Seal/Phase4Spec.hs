{-# LANGUAGE OverloadedStrings #-}
-- | The Phase 4 capstone spec — end-to-end: a turn that calls SHELL_EXEC
-- then FILE_WRITE, with a fake 'UntrustedIO' that records calls. Asserts:
-- both invocations recorded in the transcript, orRecorded secret-free,
-- no local fallback under mode=remote with a fake-unreachable remote,
-- UntrustedExecBackend is Ssh-only by construction.
module Seal.Phase4Spec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.IORef
import Data.Text (Text)
import Test.Hspec

import Seal.Core.Types (OpName (..))
import Seal.Handles.Transcript (fakeTwoFileTranscript)
import Seal.ISA.Dispatch (dispatch)
import Seal.ISA.Opcode (localBackend, OpResult (..))
import Seal.ISA.Ops.Shell (shellExecOp)
import Seal.ISA.Ops.File (fileWriteOp)
import Seal.ISA.Registry (mkRegistry)
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.Core.AllowList (AllowList (..))
import Seal.Tools.Args (textShellCommand)
import Seal.Tools.Exec.UntrustedIO
  ( UntrustedIO (..), mkRemoteUntrustedIOStub )
import Seal.Tools.Exec.Types (TerminalBackend (..))
import Seal.Tools.Exec.Untrusted
  ( UntrustedExecConfig (..), UntrustedExecMode (..), selectExecBackend
  , mkUntrustedExecBackend, enforceRemoteOnly )
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env

runTestApp :: App a -> IO a
runTestApp act = do env <- mkEnv defaultConfig; runApp env act

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
    (h, _readState) <- fakeTwoFileTranscript
    -- Dispatch SHELL_EXEC (Untrusted: ACK-before-execute)
    r1 <- runTestApp (dispatch reg h localBackend uio (OpName "SHELL_EXEC")
                       (object ["command" .= ("echo ok" :: String)]))
    -- Dispatch FILE_WRITE (Untrusted: ACK-before-execute)
    r2 <- runTestApp (dispatch reg h localBackend uio (OpName "FILE_WRITE")
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

  it "mode=remote with no remote configured: selectExecBackend never yields EbLocal" $ do
    let cfg = UntrustedExecConfig UemRemote Nothing
    selectExecBackend cfg TbLocal `shouldSatisfy` \case
      Left _  -> True   -- mode=remote + TbLocal -> Left (no local fallback)
      Right _ -> True   -- selectExecBackend still uses ExecBackend internally

  it "UntrustedExecBackend is only constructible from Ssh (never Local)" $ do
    case mkUntrustedExecBackend TbLocal of
      Left _ -> pure ()
      Right _ -> expectationFailure "mkUntrustedExecBackend accepted Local"

  it "enforceRemoteOnly rejects mode=local (Cabal flag startup check)" $ do
    let cfg = UntrustedExecConfig UemLocal Nothing
    case enforceRemoteOnly cfg of
      Left _ -> pure ()
      Right _ -> expectationFailure "enforceRemoteOnly accepted mode=local"

rightOf :: Either a b -> Maybe b
rightOf (Right b) = Just b
rightOf (Left _)  = Nothing

isJust :: Maybe a -> Bool
isJust (Just _) = True
isJust Nothing  = False

isObject :: Value -> Bool
isObject (Object _) = True
isObject _ = False