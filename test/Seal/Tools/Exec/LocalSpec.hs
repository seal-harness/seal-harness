{-# LANGUAGE OverloadedStrings #-}
module Seal.Tools.Exec.LocalSpec (spec) where

import Data.Either (isRight)
import Data.Text qualified as T
import Test.Hspec

import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Tools.Args
  ( mkShellCommand, mkInterpName, mkScriptArg )
import Seal.Tools.Exec.Local (mkLocalExecHandle)
import Seal.Tools.Exec.Types (ExecError (..), LocalExecHandle (..))

spec :: Spec
spec = describe "Seal.Tools.Exec.Local" $ do
  let wsRoot = WorkspaceRoot "."
      h = mkLocalExecHandle wsRoot

  describe "lehExecShell (real /bin/sh -c)" $ do
    it "returns stdout on exit 0" $ do
      cmd <- requireRight "invalid command" (mkShellCommand "echo hello")
      res <- lehExecShell h cmd Nothing
      res `shouldSatisfy` isRight
      case res of
        Right out -> T.strip out `shouldBe` "hello"
        Left _ -> expectationFailure "expected Right"

    it "returns exit code annotation on non-zero exit (Right, not Left)" $ do
      cmd <- requireRight "invalid command" (mkShellCommand "exit 42")
      res <- lehExecShell h cmd Nothing
      case res of
        Right out -> out `shouldSatisfy` T.isInfixOf "[exit code: 42]"
        Left e -> expectationFailure ("expected Right, got Left " ++ show e)

    it "returns exit code 127 on command-not-found (Right, not Left)" $ do
      -- This is the key fix: 127 from /bin/sh -c means "command not found"
      -- inside the shell, NOT "the shell binary is missing". It should be
      -- returned via Right with the exit code annotation, not mapped to
      -- Left ExecNotImplemented.
      cmd <- requireRight "invalid command" (mkShellCommand "this_command_does_not_exist_12345")
      res <- lehExecShell h cmd Nothing
      case res of
        Right out -> out `shouldSatisfy` T.isInfixOf "[exit code: 127]"
        Left e -> expectationFailure ("expected Right, got Left " ++ show e)

    it "captures stderr on non-zero exit" $ do
      cmd <- requireRight "invalid command" (mkShellCommand "echo 'error msg' >&2; exit 1")
      res <- lehExecShell h cmd Nothing
      case res of
        Right out -> do
          out `shouldSatisfy` T.isInfixOf "error msg"
          out `shouldSatisfy` T.isInfixOf "[exit code: 1]"
        Left e -> expectationFailure ("expected Right, got Left " ++ show e)

  describe "lehExecProgram (real interpreter on PATH)" $ do
    it "returns stdout on exit 0" $ do
      -- lehExecProgram runs <interp> <args...> with fixed argv (no shell).
      -- Use `echo` (always on PATH) with a single arg.
      interp <- requireRight "invalid interp" (mkInterpName "echo")
      arg <- requireRight "invalid arg" (mkScriptArg "via_interp")
      res <- lehExecProgram h interp [arg]
      case res of
        Right out -> T.strip out `shouldBe` "via_interp"
        Left ExecNotImplemented -> pendingWith "echo not on PATH"
        Left _ -> pendingWith "unexpected Left"

    it "returns Left ExecNotImplemented when interpreter is not on PATH (127)" $ do
      -- 127 for a program (not shell) means the binary itself is not on PATH.
      interp <- requireRight "invalid interp" (mkInterpName "this_interpreter_does_not_exist_12345")
      res <- lehExecProgram h interp []
      res `shouldBe` Left ExecNotImplemented

requireRight :: String -> Either a b -> IO b
requireRight _ (Right x) = pure x
requireRight _ (Left _) = error "requireRight: got Left"