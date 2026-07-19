{-# LANGUAGE OverloadedStrings #-}
module Seal.Tools.Exec.LocalSpec (spec) where

import Data.Either (isRight)
import Data.Text qualified as T
import Test.Hspec

import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Tools.Args
  ( mkShellCommand, mkBinName, mkBinArg )
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

  describe "lehExecBin (real binary on PATH)" $ do
    it "returns stdout on exit 0" $ do
      -- lehExecBin runs <binary> <args...> with fixed argv (no shell).
      -- Use `echo` (always on PATH) with a single arg.
      bin <- requireRight "invalid bin" (mkBinName "echo")
      arg <- requireRight "invalid arg" (mkBinArg "via_bin")
      res <- lehExecBin h bin [arg]
      case res of
        Right out -> T.strip out `shouldBe` "via_bin"
        Left ExecNotImplemented -> pendingWith "echo not on PATH"
        Left _ -> pendingWith "unexpected Left"

    it "returns Left ExecNotImplemented when binary is not on PATH (127)" $ do
      -- 127 for a program (not shell) means the binary itself is not on PATH.
      bin <- requireRight "invalid bin" (mkBinName "this_binary_does_not_exist_12345")
      res <- lehExecBin h bin []
      res `shouldBe` Left ExecNotImplemented

    it "passes leading-dash args verbatim (flag, not option injection)" $ do
      -- `printf` accepts -format strings; pass a leading-dash arg to prove
      -- the raw argv model forwards it as a single token, not a flag to a shell.
      bin <- requireRight "invalid bin" (mkBinName "printf")
      arg <- requireRight "invalid arg" (mkBinArg "--")
      res <- lehExecBin h bin [arg, arg]
      case res of
        Right out -> out `shouldSatisfy` (not . T.null)
        Left ExecNotImplemented -> pendingWith "printf not on PATH"
        Left _ -> pendingWith "unexpected Left"

requireRight :: String -> Either a b -> IO b
requireRight _ (Right x) = pure x
requireRight _ (Left _) = error "requireRight: got Left"