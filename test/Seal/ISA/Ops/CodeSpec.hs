{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.CodeSpec (spec) where

import Data.Aeson (object, (.=))
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Set qualified as Set
import Test.Hspec

import Seal.Core.AllowList (AllowList (..))
import Seal.ISA.Opcode (OpResult (..), uoRun, uoAuthorize)
import Seal.ISA.Ops.Code
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Tools.Args
import Seal.Tools.Exec.Local (mkLocalExecHandleFromFns)
import Seal.Tools.Exec.Types (ExecBackend (..))
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env

runTestApp :: App a -> IO a
runTestApp act = do env <- mkEnv defaultConfig; runApp env act

-- | A fake backend that records the program invocation and returns canned output.
fakeBackend :: IORef [Text] -> Text -> ExecBackend
fakeBackend seen canned = EbLocal (mkLocalExecHandleFromFns shellFn progFn)
  where
    shellFn _ _ = pure (Right "")
    progFn interp args = do
      modifyIORef' seen (++ [textInterpName interp <> " " <> T.intercalate " " (map textScriptArg args)])
      pure (Right canned)

spec :: Spec
spec = describe "Seal.ISA.Ops.Code" $ do

  describe "CODE_EXEC" $ do

    it "runs a script via an allowed interpreter" $ do
      seen <- newIORef []
      let backend = fakeBackend seen "42\n"
          allowList = Set.fromList ["python3", "node"]
          op = codeExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) allowList backend
      r <- runTestApp (uoRun op undefined backend (object
        [ "interpreter" .= ("python3" :: String)
        , "script" .= ("print(42)" :: String)
        ]))
      orIsError r `shouldBe` False
      orParts r `shouldBe` [TrpText "42\n"]
      readIORef seen `shouldReturn` ["python3 print(42)"]

    it "interpreter not in allow-list -> Denied" $ do
      let allowList = Set.fromList ["python3"]
          op = codeExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) allowList undefined
      uoAuthorize op (object
        [ "interpreter" .= ("bash" :: String)
        , "script" .= ("echo hi" :: String)
        ]) `shouldBe` Left "CODE_EXEC: interpreter \"bash\" not in the allow-list"

    it "missing interpreter field -> error" $ do
      let op = codeExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Set.empty undefined
      uoAuthorize op (object ["script" .= ("print(1)" :: String)])
        `shouldBe` Left "CODE_EXEC requires {interpreter:string, script:string}"

    it "missing script field -> error" $ do
      let op = codeExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Set.empty undefined
      uoAuthorize op (object ["interpreter" .= ("python3" :: String)])
        `shouldBe` Left "CODE_EXEC requires {interpreter:string, script:string}"

    it "script with NUL -> Denied (validated ScriptArg rejects NUL)" $ do
      let op = codeExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) (Set.fromList ["python3"]) undefined
      uoAuthorize op (object
        [ "interpreter" .= ("python3" :: String)
        , "script" .= ("print\0bad" :: String)
        ]) `shouldBe` Left "CODE_EXEC: invalid script argument"

    it "orRecorded captures the interpreter + script hash (secret-free, not the script body)" $ do
      seen <- newIORef []
      let backend = fakeBackend seen ""
          allowList = Set.fromList ["node"]
          op = codeExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) allowList backend
      r <- runTestApp (uoRun op undefined backend (object
        [ "interpreter" .= ("node" :: String)
        , "script" .= ("console.log('hi')" :: String)
        ]))
      orRecorded r `shouldBe` object
        [ "interpreter" .= ("node" :: String)
        , "script_length" .= (17 :: Int)
        ]