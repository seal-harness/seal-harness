{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.ProcessSpec (spec) where

import Data.Aeson (object, (.=))
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.ISA.Opcode (OpResult (..), uoRun, uoAuthorize)
import Seal.ISA.Ops.Process
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Core.AllowList (AllowList (..))
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Tools.Exec.UntrustedIO
  ( UntrustedIO (..), mkRemoteUntrustedIOStub )
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env

runTestApp :: App a -> IO a
runTestApp act = do env <- mkEnv defaultConfig; runApp env act

-- | A fake 'UntrustedIO' whose 'uioProcessList'/'uioProcessKill' record
-- into an 'IORef' and return canned output.
fakeUio :: IORef [Text] -> Text -> UntrustedIO
fakeUio seen canned = mkRemoteUntrustedIOStub
  { uioProcessList = do
      modifyIORef' seen (++ ["ps -o pid=,cmd="])
      pure (Right canned)
  , uioProcessKill = \pid -> do
      modifyIORef' seen (++ ["kill " <> T.pack (show pid)])
      pure (Right ())
  }

spec :: Spec
spec = describe "Seal.ISA.Ops.Process" $ do

  describe "PROCESS_MANAGE" $ do

    it "list action runs a shell command and returns bounded output" $ do
      seen <- newIORef []
      let uio = fakeUio seen "PID  CMD\n  1  init\n 42  myproc\n"
          op = processManageOp (WorkspaceRoot "/ws") (SecurityPolicy (AllowOnly mempty) Full)
      r <- runTestApp (uoRun op uio (object ["action" .= ("list" :: String)]))
      orIsError r `shouldBe` False
      orParts r `shouldSatisfy` \case [TrpText t] -> "myproc" `T.isInfixOf` t; _ -> False
      readIORef seen `shouldReturn` ["ps -o pid=,cmd="]

    it "kill action with a valid PID runs the kill command" $ do
      seen <- newIORef []
      let uio = fakeUio seen ""
          op = processManageOp (WorkspaceRoot "/ws") (SecurityPolicy (AllowOnly mempty) Full)
      r <- runTestApp (uoRun op uio (object ["action" .= ("kill" :: String), "pid" .= (123 :: Int)]))
      orIsError r `shouldBe` False
      readIORef seen `shouldReturn` ["kill 123"]

    it "kill action rejects a negative PID" $ do
      let op = processManageOp (WorkspaceRoot "/ws") (SecurityPolicy (AllowOnly mempty) Full)
      uoAuthorize op (object ["action" .= ("kill" :: String), "pid" .= (-1 :: Int)])
        `shouldBe` Left "PROCESS_MANAGE: pid must be a positive integer"

    it "kill action rejects a missing PID" $ do
      let op = processManageOp (WorkspaceRoot "/ws") (SecurityPolicy (AllowOnly mempty) Full)
      uoAuthorize op (object ["action" .= ("kill" :: String)])
        `shouldBe` Left "PROCESS_MANAGE: kill requires {pid:positive integer}"

    it "missing action field -> error" $ do
      let op = processManageOp (WorkspaceRoot "/ws") (SecurityPolicy (AllowOnly mempty) Full)
      uoAuthorize op (object []) `shouldBe` Left "PROCESS_MANAGE requires {action:string}"

    it "unknown action -> error" $ do
      let op = processManageOp (WorkspaceRoot "/ws") (SecurityPolicy (AllowOnly mempty) Full)
      uoAuthorize op (object ["action" .= ("frobnicate" :: String)])
        `shouldBe` Left "PROCESS_MANAGE: unknown action \"frobnicate\""

    it "orRecorded captures the action + pid (secret-free)" $ do
      seen <- newIORef []
      let uio = fakeUio seen ""
          op = processManageOp (WorkspaceRoot "/ws") (SecurityPolicy (AllowOnly mempty) Full)
      r <- runTestApp (uoRun op uio (object ["action" .= ("kill" :: String), "pid" .= (42 :: Int)]))
      orRecorded r `shouldBe` object ["action" .= ("kill" :: String), "pid" .= (42 :: Int)]