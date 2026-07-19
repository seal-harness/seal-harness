{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.BinSpec (spec) where

import Data.Aeson (object, (.=))
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Set qualified as Set
import Test.Hspec

import Seal.Core.AllowList (AllowList (..))
import Seal.ISA.Opcode (OpResult (..), uoRun, uoAuthorize)
import Seal.ISA.Ops.Bin
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
fakeBackend seen canned = EbLocal (mkLocalExecHandleFromFns shellFn binFn)
  where
    shellFn _ _ = pure (Right "")
    binFn bin args = do
      modifyIORef' seen (++ [textBinName bin <> " " <> T.intercalate " " (map textBinArg args)])
      pure (Right canned)

spec :: Spec
spec = describe "Seal.ISA.Ops.Bin" $ do

  describe "BIN_EXEC" $ do

    it "runs a binary via an allow-listed name" $ do
      seen <- newIORef []
      let backend = fakeBackend seen "42\n"
          allowList = Just (Set.fromList ["python3", "node"])
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) allowList backend
      r <- runTestApp (uoRun op undefined backend (object
        [ "binary" .= ("python3" :: String)
        , "args" .= (["-c", "print(42)"] :: [String])
        ]))
      orIsError r `shouldBe` False
      orParts r `shouldBe` [TrpText "42\n"]
      readIORef seen `shouldReturn` ["python3 -c print(42)"]

    it "binary not in allow-list -> Denied" $ do
      let allowList = Just (Set.fromList ["python3"])
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) allowList undefined
      uoAuthorize op (object
        [ "binary" .= ("rm" :: String)
        , "args" .= (["-rf", "/"] :: [String])
        ]) `shouldBe` Left "BIN_EXEC: binary \"rm\" not in the allow-list"

    it "missing binary field -> error" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) (Just Set.empty) undefined
      uoAuthorize op (object ["args" .= (["x"] :: [String])])
        `shouldBe` Left "BIN_EXEC requires {binary:string, args:[string]}"

    it "args field is optional (defaults to [])" $ do
      seen <- newIORef []
      let backend = fakeBackend seen "ok\n"
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing backend
      r <- runTestApp (uoRun op undefined backend (object
        [ "binary" .= ("ls" :: String)
        ]))
      orIsError r `shouldBe` False
      readIORef seen `shouldReturn` ["ls "]

    it "binary with NUL -> Denied (validated BinName rejects NUL)" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing undefined
      uoAuthorize op (object
        [ "binary" .= ("ev\0il" :: String)
        ]) `shouldBe` Left "BIN_EXEC: invalid binary name"

    it "arg with NUL -> Denied (validated BinArg rejects NUL)" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing undefined
      uoAuthorize op (object
        [ "binary" .= ("ls" :: String)
        , "args" .= ["ok\0bad" :: String]
        ]) `shouldBe` Left "BIN_EXEC: invalid arg"

    it "leading-dash arg is permitted (flag, not option injection)" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) (Just (Set.fromList ["ls"])) undefined
      uoAuthorize op (object
        [ "binary" .= ("ls" :: String)
        , "args" .= (["-l", "-a"] :: [String])
        ]) `shouldBe` Right ()

    it "Nothing allow-list permits any binary (autonomy permitting)" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing undefined
      uoAuthorize op (object
        [ "binary" .= ("rm" :: String)
        , "args" .= (["-rf", "/"] :: [String])
        ]) `shouldBe` Right ()

    it "orRecorded captures the binary + arg count (secret-free, not the args)" $ do
      seen <- newIORef []
      let backend = fakeBackend seen ""
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing backend
      r <- runTestApp (uoRun op undefined backend (object
        [ "binary" .= ("node" :: String)
        , "args" .= (["-e", "console.log('hi')"] :: [String])
        ]))
      orRecorded r `shouldBe` object
        [ "binary" .= ("node" :: String)
        , "arg_count" .= (2 :: Int)
        ]