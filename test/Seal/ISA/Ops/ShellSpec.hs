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
import Seal.Tools.Args
import Seal.Tools.Exec.Local (mkLocalExecHandleFromFns)
import Seal.Tools.Exec.Types (ExecBackend (..), ExecError (..))
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env

runTestApp :: App a -> IO a
runTestApp act = do env <- mkEnv defaultConfig; runApp env act

-- | A fake 'ExecBackend' that records the 'ShellCommand' it received and
-- returns a canned stdout. Mirrors the 'TmuxRunner' fake pattern.
fakeBackend :: IORef [Text] -> Text -> ExecBackend
fakeBackend seen canned = EbLocal (mkLocalExecHandleFromFns shellFn progFn)
  where
    shellFn cmd _cwd = do
      modifyIORef' seen (++ [textShellCommand cmd])
      pure (Right canned)
    progFn _ _ = pure (Right "")

spec :: Spec
spec = describe "Seal.ISA.Ops.Shell" $ do

  describe "SHELL_EXEC" $ do

    it "runs a validated shell command via the executor and returns stdout" $ do
      seen <- newIORef []
      let backend = fakeBackend seen "hello\n"
          op = shellExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) backend
      r <- runTestApp (uoRun op undefined backend (object ["command" .= ("echo hello" :: String)]))
      orIsError r `shouldBe` False
      orParts r `shouldBe` [TrpText "hello\n"]
      readIORef seen `shouldReturn` ["echo hello"]

    it "orRecorded captures the command (secret-free metadata)" $ do
      seen <- newIORef []
      let backend = fakeBackend seen "out"
          op = shellExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) backend
      r <- runTestApp (uoRun op undefined backend (object ["command" .= ("ls /ws" :: String)]))
      orRecorded r `shouldBe` object ["command" .= ("ls /ws" :: String), "cwd" .= (Nothing :: Maybe String)]

    it "Deny policy -> Denied at the authorize gate (never runs the executor)" $ do
      let op = shellExecOp (WorkspaceRoot "/ws") (SecurityPolicy (AllowOnly Set.empty) Deny) undefined
      -- The authorize gate rejects; the dispatcher would never call uoRun.
      uoAuthorize op (object ["command" .= ("rm -rf /" :: String)]) `shouldBe` Left "SHELL_EXEC denied by autonomy policy"

    it "missing command field -> error result, never runs" $ do
      seen <- newIORef []
      let backend = fakeBackend seen "x"
          op = shellExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) backend
      r <- runTestApp (uoRun op undefined backend (object []))
      orIsError r `shouldBe` True
      readIORef seen `shouldReturn` []

    it "executor failure surfaces as an error result" $ do
      let backend = EbLocal (mkLocalExecHandleFromFns (\_ _ -> pure (Left ExecNotImplemented)) (\_ _ -> pure (Right "")))
          op = shellExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) backend
      r <- runTestApp (uoRun op undefined backend (object ["command" .= ("false" :: String)]))
      orIsError r `shouldBe` True