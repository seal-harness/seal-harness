{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.ShellSpec (spec) where

import Data.Aeson (object, (.=))
import Data.IORef
import Data.Set qualified as Set
import Data.Text (Text)
import Test.Hspec

import Seal.Core.AllowList (AllowList (..))
import Seal.ISA.Opcode (OpResult (..), uoRun, uoAuthorize)
import Seal.ISA.Ops.Shell
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Tools.Args (textShellCommand)
import Seal.Tools.Exec.UntrustedIO
  ( UntrustedIO (..), UntrustedErr (..), mkRemoteUntrustedIOStub )
import Seal.Tools.Exec.Types (ExecError (..))
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env

runTestApp :: App a -> IO a
runTestApp act = do env <- mkEnv defaultConfig; runApp env act

-- | A fake 'UntrustedIO' that records the 'ShellCommand' its 'uioShellExec'
-- received and returns a canned stdout. Other methods are the fail-closed
-- stub.
fakeUio :: IORef [Text] -> Text -> UntrustedIO
fakeUio seen canned = mkRemoteUntrustedIOStub
  { uioShellExec = \cmd _cwd -> do
      modifyIORef' seen (++ [textShellCommand cmd])
      pure (Right canned)
  }

-- | A fake 'UntrustedIO' whose 'uioShellExec' returns a fixed 'ExecError'.
failUio :: ExecError -> UntrustedIO
failUio e = mkRemoteUntrustedIOStub
  { uioShellExec = \_ _ -> pure (Left (UeExec e))
  }

spec :: Spec
spec = describe "Seal.ISA.Ops.Shell" $ do

  describe "SHELL_EXEC" $ do

    it "runs a validated shell command via the executor and returns stdout" $ do
      seen <- newIORef []
      let uio = fakeUio seen "hello\n"
          op = shellExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full)
      r <- runTestApp (uoRun op uio (object ["command" .= ("echo hello" :: String)]))
      orIsError r `shouldBe` False
      orParts r `shouldBe` [TrpText "hello\n"]
      readIORef seen `shouldReturn` ["echo hello"]

    it "orRecorded captures the command (secret-free metadata)" $ do
      seen <- newIORef []
      let uio = fakeUio seen "out"
          op = shellExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full)
      r <- runTestApp (uoRun op uio (object ["command" .= ("ls /ws" :: String)]))
      orRecorded r `shouldBe` object ["command" .= ("ls /ws" :: String), "cwd" .= (Nothing :: Maybe String)]

    it "Deny policy -> Denied at the authorize gate (never runs the executor)" $ do
      let op = shellExecOp (WorkspaceRoot "/ws") (SecurityPolicy (AllowOnly Set.empty) Deny)
      -- The authorize gate rejects; the dispatcher would never call uoRun.
      uoAuthorize op (object ["command" .= ("rm -rf /" :: String)]) `shouldBe` Left "SHELL_EXEC denied by autonomy policy"

    it "missing command field -> error result, never runs" $ do
      seen <- newIORef []
      let uio = fakeUio seen "x"
          op = shellExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full)
      r <- runTestApp (uoRun op uio (object []))
      orIsError r `shouldBe` True
      readIORef seen `shouldReturn` []

    it "executor failure surfaces as an error result" $ do
      let uio = failUio ExecNotImplemented
          op = shellExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full)
      r <- runTestApp (uoRun op uio (object ["command" .= ("false" :: String)]))
      orIsError r `shouldBe` True